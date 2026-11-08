--[[
    ADCornerModule
    --------------
    Tight bends of a road network route are driven "point to point": the tractor steers at the points, saturates
    its steering, and the trailer cuts the inside: the train leaves the path or touches a building on the way.
    A real driver swings wide, and when even that does not fit, backs up a little to take the bend wider.

    When a network route is set, every tight bend is looked at. A bend is a single sharp point, or several close
    points turning the same way (a curve drawn with many points, a U-turn around a parking place): their angles
    add up. A bend counts when it turns at least BEND_MIN_ANGLE and its drawn radius is below the turning radius
    of the train.

    For each bend:
      1. candidates: the shortest paths at the real turning radius (arc, straight, arc) from a point of the route
         before the bend to a point of the route after it, so swinging wide on entry or exit comes naturally;
      2. every candidate, and the drawn route itself, is driven in a simulation of the whole train (the tractor
         follows the line like AutoDrive does, steering limited to its radius, the trailer follows its hitch).
         Tractor and trailer bodies are checked every metre against static obstacles, fields (unless the route is
         already on one) and the road mesh (when the route is on one);
      3. the first candidate that passes replaces the bend. When none passes but the drawn route does, the route
         stays as it is. When neither passes: manoeuvre, the train stops at a point before the bend, backs up
         straight a few metres (the room behind is checked) and takes the bend from there;
      4. when nothing fits, the bend stays as it is (log "nothing fits").
    The inserted points are pathfinder-like points (no id), as the obstacle detour already does.
]]

ADCornerModule = {}

ADCornerModule.DEBUG = true -- temporary diagnostic logs for the tests

local atan2 = math.atan2 or math.atan
local PI, TWO_PI = math.pi, 2 * math.pi

ADCornerModule.BEND_MIN_ANGLE = math.rad(35)   -- total angle of a bend
ADCornerModule.BEND_MAX_ANGLE = math.rad(200)  -- a bend stops growing beyond (U-turn and a bit more)
ADCornerModule.POINT_MIN_ANGLE = math.rad(3)   -- a point turning less is straight
ADCornerModule.GROUP_SEGMENT_MAX = 8           -- m: points of one drawn curve are closer than this
ADCornerModule.RADIUS_MAX = 14                 -- m, a larger estimate is a wheel data oddity
ADCornerModule.RADIUS_FACTORS = {1.15, 1.5, 2} -- turning radius of the candidates, times the radius of the train
ADCornerModule.ENTRY_MAX = 30                  -- m of route looked at before the bend
ADCornerModule.EXIT_MAX = 30                   -- m of route looked at after the bend
ADCornerModule.POSE_SPACING = 3                -- m at least between two entry / exit points tried
ADCornerModule.POSES_MAX = 7                   -- entry / exit points tried at most
ADCornerModule.DEVIATION_MAX = 15              -- m a candidate may move away from the drawn route
ADCornerModule.DEVIATION_MAX_UTURN = 20        -- m for a U-turn (its diameter is twice the radius of the train)
ADCornerModule.UTURN_ANGLE = math.rad(150)     -- a bend turning more is a U-turn
ADCornerModule.GROUND_CLEARANCE = 0.4          -- m above the ground where obstacles start (slabs, kerbs, plates do not count)
ADCornerModule.EXTRA_TURN_MAX = math.rad(150)  -- rad a candidate may turn more than the bend
ADCornerModule.TURN_COST = 3                   -- m of cost per radian turned more than the bend
ADCornerModule.DEVIATION_COST = 2              -- m of cost per metre away from the drawn route (no short cut across the grass)
ADCornerModule.TESTS_MAX = 24                  -- candidates simulated at most per bend (and per reverse distance) at the real radius
ADCornerModule.TESTS_MAX_WIDE = 8              -- ... and at each larger radius (tried first)
ADCornerModule.WIDE_DEVIATION_MAX = 3          -- m a larger radius bend may move away from the drawn route (stays on the road)
ADCornerModule.ARC_STEP = 2.5                  -- m between two inserted points on an arc
ADCornerModule.LINE_STEP = 5                   -- m between two inserted points on a straight
ADCornerModule.SIM_STEP = 0.5                  -- m per simulated step
ADCornerModule.CHECK_STEP = 1                  -- m between two body checks
ADCornerModule.GROUND_STEP = 2                 -- m between two field / road checks
ADCornerModule.SIM_TAIL = 12                   -- m simulated after the end of the bend (the trailer comes through)
ADCornerModule.BODY_MARGIN = 0.3               -- m added on each side of the bodies
ADCornerModule.REVERSE_DISTANCES = {8, 14, 20} -- m backed up before the bend (manoeuvre)
ADCornerModule.REVERSE_SPEED = 6               -- km/h
ADCornerModule.REVERSE_TIMEOUT = 40000         -- ms
ADCornerModule.REAR_BLOCKED_TIME = 1500        -- ms the rear sensor must stay blocked to stop backing
ADCornerModule.ROAD_RAY_HEIGHT = 3             -- m above the terrain for the road mesh raycast
ADCornerModule.TYPES = {{1, 1}, {-1, -1}, {1, -1}, {-1, 1}} -- arc, straight, arc: turning sides (+1 = increasing angle)

function ADCornerModule:log(text, ...)
    if ADCornerModule.DEBUG then
        local name = self.vehicle.ad ~= nil and self.vehicle.ad.stateModule ~= nil and self.vehicle.ad.stateModule:getName() or "?"
        print(string.format("[AD-Virage] %s (%s): " .. text, tostring(name), tostring(self.vehicle.id), ...))
    end
end

function ADCornerModule:new(vehicle)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.vehicle = vehicle
    o.reversing = false
    o.backTimer = AutoDriveTON:new()
    o.rearBlockedTimer = AutoDriveTON:new()
    return o
end

function ADCornerModule.isEnabled()
    local enabled = AutoDrive.getSetting("cornerSwingEnabled")
    return enabled == nil or enabled == true or enabled == 1
end

------------------------------------------------------------------------------------------------
-- train geometry
------------------------------------------------------------------------------------------------
local function wrap(a)
    a = (a + PI) % TWO_PI
    if a < 0 then
        a = a + TWO_PI
    end
    return a - PI
end

local function headingOf(dx, dz)
    return atan2(dx, dz)
end

-- body box of one unit seen from its reference point (x, z, heading a): front / rear along the heading, half width
local function bodyBox(unit, x, z, a)
    local root = unit.components[1].node
    local length = unit.size ~= nil and unit.size.length or 6
    local width = unit.size ~= nil and unit.size.width or 3
    local offset = unit.size ~= nil and unit.size.lengthOffset or 0
    local cx, _, cz = localToWorld(root, 0, 0, offset)
    local c = (cx - x) * math.sin(a) + (cz - z) * math.cos(a)
    return {front = c + length / 2, rear = c - length / 2, half = width / 2}
end

function ADCornerModule:readTrain()
    local width = self.vehicle.size ~= nil and self.vehicle.size.width or 3
    local trailerLength = 0
    local units = AutoDrive.getAllUnits(self.vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit.size ~= nil then
                if unit.size.width ~= nil then
                    width = math.max(width, unit.size.width)
                end
                if unit ~= self.vehicle and unit.size.length ~= nil then
                    trailerLength = math.max(trailerLength, unit.size.length)
                end
            end
        end
    end
    self.width = width
    self.trailerLength = trailerLength
    -- turning radius: the vehicle file value (AutoDrive.getDriverRadius) is sometimes far too small
    -- (Patriot 4450: 3.9 m). The steering geometry of the wheels gives a second estimate: the larger one wins.
    self.fileRadius = AutoDrive.getDriverRadius(self.vehicle)
    self.wheelRadius = ADCornerModule.getWheelRadius(self.vehicle)
    self.radius = math.max(self.fileRadius or 0, self.wheelRadius or 0)
    if self.radius < 3 then
        self.radius = 6
    end
    self.radius = math.min(self.radius, ADCornerModule.RADIUS_MAX)
    self.height = PathFinderModule.getTrainHeight ~= nil and PathFinderModule.getTrainHeight(self.vehicle) or 3
    local dpm = self.vehicle.ad ~= nil and self.vehicle.ad.drivePathModule or nil
    self.lookAhead = dpm ~= nil and dpm.min_lookAhead or nil
    if self.lookAhead == nil and AutoDrive.getMinLookaheadByVehicleType ~= nil then
        self.lookAhead = AutoDrive.getMinLookaheadByVehicleType(self.vehicle)
    end
    self.lookAhead = math.max(3, self.lookAhead or 5)
    self:readGeometry()
end

-- hitch, trailer axle distance and bodies: the exact geometry of the band turn when a trailer is hitched,
-- else the tractor alone. Reference point: the axle of the tractor (AI direction node)
function ADCornerModule:readGeometry()
    self.geo = nil
    self.geoSource = "tractor alone"
    self.geoWhy = nil
    if self.trailerLength > 0 and ADBandTurn ~= nil and ADBandTurn.getGeometry ~= nil then
        local ok, geo, why = pcall(ADBandTurn.getGeometry, self.vehicle)
        if ok and geo == nil then
            self.geoWhy = why -- "pas de remorque a roues": mounted tools only (end manoeuvre: part of the tractor)
        end
        if ok and geo ~= nil and geo.tractorBox ~= nil and geo.trailerBox ~= nil then
            self.geo = {hitch = geo.hitch, trailer = geo.trailer, tractorBox = geo.tractorBox, trailerBox = geo.trailerBox}
            self.geoSource = "measured"
        end
    end
    if self.geo == nil then
        local node = self.vehicle.getAIDirectionNode ~= nil and self.vehicle:getAIDirectionNode() or self.vehicle.components[1].node
        local x, _, z = getWorldTranslation(node)
        local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
        local box = bodyBox(self.vehicle, x, z, headingOf(dx, dz))
        self.geo = {hitch = 0, trailer = 0, tractorBox = box}
        if self.trailerLength > 0 then
            -- trailer seen but not measured: usual proportions (hitch behind the axle, axle at 60 % of the length)
            local L = self.trailerLength
            self.geo.hitch = math.max(0.5, -box.rear - 0.3)
            self.geo.trailer = 0.6 * L
            self.geo.trailerBox = {front = 0.6 * L, rear = -0.4 * L, half = self.width / 2}
            self.geoSource = "estimated"
        end
    end
end

-- turning radius from the wheels: wheelbase / tan(max steering angle) + half track (bicycle model),
-- nil when the wheel data is not available. All wheels steered (4WS): half the wheelbase counts.
function ADCornerModule.getWheelRadius(vehicle)
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil or vehicle.components == nil or vehicle.components[1] == nil then
        return nil
    end
    local root = vehicle.components[1].node
    local steerMax, steerZ, steerCount, fixedZ, fixedCount = 0, 0, 0, 0, 0
    local xMin, xMax = math.huge, -math.huge
    for _, wheel in pairs(spec.wheels) do
        local physics = wheel.physics or wheel
        if wheel.node ~= nil and physics.positionX ~= nil then
            local x, _, z = localToLocal(wheel.node, root, physics.positionX, physics.positionY or 0, physics.positionZ or 0)
            local rot = math.max(math.abs(physics.rotMax or 0), math.abs(physics.rotMin or 0))
            if rot > 0.05 then
                steerMax = math.max(steerMax, rot)
                steerZ, steerCount = steerZ + z, steerCount + 1
            else
                fixedZ, fixedCount = fixedZ + z, fixedCount + 1
            end
            xMin, xMax = math.min(xMin, x), math.max(xMax, x)
        end
    end
    if steerCount == 0 or steerMax <= 0.05 or steerMax >= math.rad(80) then
        return nil
    end
    local wheelbase
    if fixedCount > 0 then
        wheelbase = math.abs(steerZ / steerCount - fixedZ / fixedCount)
    else
        wheelbase = (vehicle.size ~= nil and vehicle.size.length or 4) * 0.3
    end
    if wheelbase < 1 then
        return nil
    end
    return wheelbase / math.tan(steerMax) + (xMax - xMin) / 2
end

------------------------------------------------------------------------------------------------
-- terrain tests
------------------------------------------------------------------------------------------------
function ADCornerModule:collisionCallback(node)
    if node == nil or node == 0 or node == g_currentMission.terrainRootNode then
        return true
    end
    local object = g_currentMission.nodeToObject[node]
    if object == nil then
        local parent = getParent(node)
        if parent ~= nil and parent ~= 0 then
            object = g_currentMission.nodeToObject[parent]
        end
    end
    if object ~= nil then
        local root = self.vehicle:getRootVehicle()
        if object == self.vehicle or object == root or AutoDrive:checkIsConnected(root, object) then
            return true
        end
        -- vehicles move: they are not a reason to refuse a bend
        if object.ad ~= nil or object.spec_motorized ~= nil or object.spec_attachable ~= nil then
            return true
        end
    elseif not ADSensor.isElementBlockingVehicle(self, node) then
        return true
    end
    self.hits = self.hits + 1
    if self.hitName == nil then
        self.hitName = getName ~= nil and getName(node) or tostring(node)
    end
    return false
end

function ADCornerModule:roadCallback(hitObjectId, x, y, z, distance)
    if hitObjectId ~= nil and hitObjectId ~= 0 then
        self.roadHit = true
    end
    return false
end

-- true when a road mesh (CollisionFlag.ROAD) lies under the point
function ADCornerModule:isOnRoadMesh(x, z)
    if raycastClosest == nil or CollisionFlag == nil or CollisionFlag.ROAD == nil then
        return false
    end
    self.roadHit = false
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 300, z)
    raycastClosest(x, y + ADCornerModule.ROAD_RAY_HEIGHT, z, 0, -1, 0, ADCornerModule.ROAD_RAY_HEIGHT * 2, "roadCallback", self, CollisionFlag.ROAD)
    return self.roadHit
end

function ADCornerModule:isOnField(x, z)
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 300, z)
    return AutoDrive.checkIsOnField(x, y, z) == true
end

-- one body (box seen from x, z, heading a) against static obstacles
function ADCornerModule:isBodyClear(x, z, a, box)
    local s, c = math.sin(a), math.cos(a)
    local mid = (box.front + box.rear) / 2
    local cx, cz = x + s * mid, z + c * mid
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 300, cz)
    self.hits = 0
    self.hitName = nil
    local halfHeight = math.max(0.5, self.height - ADCornerModule.GROUND_CLEARANCE) / 2
    overlapBox(cx, y + ADCornerModule.GROUND_CLEARANCE + halfHeight, cz, 0, a, 0, box.half + ADCornerModule.BODY_MARGIN, halfHeight, (box.front - box.rear) / 2,
        "collisionCallback", self, AutoDrive.collisionMaskTerrain, true, true, true, true)
    return self.hits == 0
end

-- wide bend: true when the drawn route next to x, z lies on the road mesh (its points are looked at once)
function ADCornerModule:isLineOnRoad(reference, x, z)
    local line = reference.wideLine
    local best, bestD = nil, math.huge
    for k, q in ipairs(line) do
        local d = MathUtil.vector2Length(q.x - x, q.z - z)
        if d < bestD then
            best, bestD = k, d
        end
    end
    if best == nil then
        return false
    end
    reference.wideRoad = reference.wideRoad or {}
    if reference.wideRoad[best] == nil then
        reference.wideRoad[best] = self:isOnRoadMesh(line[best].x, line[best].z)
    end
    return reference.wideRoad[best]
end

-- wheels of one axle (x, z, heading a): on a field / off the road mesh
function ADCornerModule:isAxleGroundOk(x, z, a, half, reference)
    local nx, nz = math.cos(a), -math.sin(a)
    for _, side in ipairs({-1, 1}) do
        local px, pz = x + nx * half * side, z + nz * half * side
        if not reference.onField and self:isOnField(px, pz) then
            return false, "field"
        end
        if reference.onRoad and not self:isOnRoadMesh(px, pz) then
            return false, "off the road"
        end
        -- a wide bend stays on the road: no wheel off the road mesh where the drawn route is on it
        if reference.wideLine ~= nil and not reference.onRoad and not self:isOnRoadMesh(px, pz) and self:isLineOnRoad(reference, px, pz) then
            return false, "off the road (wide bend)"
        end
    end
    return true
end

------------------------------------------------------------------------------------------------
-- simulation of the train along a line of points
------------------------------------------------------------------------------------------------
-- one step of ds metres with curvature k: the trailer axle follows the hitch
function ADCornerModule:move(pose, ds, k)
    local x, z, a = pose.x, pose.z, pose.a
    if math.abs(k) < 1e-6 then
        x, z = x + math.sin(a) * ds, z + math.cos(a) * ds
    else
        local na = a + k * ds
        x = x + (math.cos(a) - math.cos(na)) / k
        z = z + (math.sin(na) - math.sin(a)) / k
        a = na
    end
    local tx, tz = pose.tx, pose.tz
    if self.geo.trailer > 0 then
        local hx, hz = x - math.sin(a) * self.geo.hitch, z - math.cos(a) * self.geo.hitch
        local vx, vz = hx - tx, hz - tz
        local l = math.sqrt(vx * vx + vz * vz)
        if l > 1e-6 then
            tx, tz = hx - vx / l * self.geo.trailer, hz - vz / l * self.geo.trailer
        end
    end
    return {x = x, z = z, a = wrap(a), tx = tx, tz = tz}
end

-- train standing straight at x, z, heading a
function ADCornerModule:straightPose(x, z, a)
    local back = self.geo.hitch + self.geo.trailer
    return {x = x, z = z, a = a, tx = x - math.sin(a) * back, tz = z - math.cos(a) * back}
end

function ADCornerModule:trailerHeading(pose)
    local hx, hz = pose.x - math.sin(pose.a) * self.geo.hitch, pose.z - math.cos(pose.a) * self.geo.hitch
    return headingOf(hx - pose.tx, hz - pose.tz)
end

-- checks one simulated pose: bodies against obstacles, axles on the ground allowed
function ADCornerModule:checkPose(pose, reference, ground)
    local geo = self.geo
    if not self:isBodyClear(pose.x, pose.z, pose.a, geo.tractorBox) then
        return false, "obstacle '" .. tostring(self.hitName) .. "' (tractor)"
    end
    local b = nil
    if geo.trailer > 0 and geo.trailerBox ~= nil then
        b = self:trailerHeading(pose)
        if not self:isBodyClear(pose.tx, pose.tz, b, geo.trailerBox) then
            return false, "obstacle '" .. tostring(self.hitName) .. "' (trailer)"
        end
    end
    if ground then
        local ok, reason = self:isAxleGroundOk(pose.x, pose.z, pose.a, geo.tractorBox.half, reference)
        if not ok then
            return false, reason .. " (tractor)"
        end
        if b ~= nil then
            ok, reason = self:isAxleGroundOk(pose.tx, pose.tz, b, geo.trailerBox.half, reference)
            if not ok then
                return false, reason .. " (trailer)"
            end
        end
    end
    return true
end

-- drives the train along the points like AutoDrive does (target LOOKAHEAD ahead on the line, steering limited
-- to the turning radius) and checks it every CHECK_STEP metres. Returns clear, reason
function ADCornerModule:simulate(points, start, reference)
    local pose = start
    local kMax = 1 / self.radius
    local index = 1 -- segment points[index] -> points[index + 1] the tractor is on
    local total = 0
    for n = 2, #points do
        total = total + MathUtil.vector2Length(points[n].x - points[n - 1].x, points[n].z - points[n - 1].z)
    end
    local maxSteps = math.ceil((total * 1.6 + 20) / ADCornerModule.SIM_STEP)
    local sinceCheck, sinceGround = ADCornerModule.CHECK_STEP, ADCornerModule.GROUND_STEP
    local last = points[#points]
    self.simEnd = nil
    for _ = 1, maxSteps do
        -- progress: projection on the current segment
        while index < #points - 1 do
            local a, b = points[index], points[index + 1]
            local vx, vz = b.x - a.x, b.z - a.z
            local l2 = vx * vx + vz * vz
            if l2 > 1e-6 and ((pose.x - a.x) * vx + (pose.z - a.z) * vz) / l2 < 1 then
                break
            end
            index = index + 1
        end
        local a, b = points[index], points[index + 1]
        local vx, vz = b.x - a.x, b.z - a.z
        local l = math.sqrt(vx * vx + vz * vz)
        if index >= #points - 1 and (pose.x - last.x) * vx + (pose.z - last.z) * vz >= 0 then
            break -- past the last point
        end
        -- target: the point of the line LOOKAHEAD metres from the tractor
        local tx, tz = last.x, last.z
        local remaining = self.lookAhead
        local px, pz = pose.x, pose.z
        if l > 1e-6 then
            local t = math.max(0, math.min(1, ((pose.x - a.x) * vx + (pose.z - a.z) * vz) / (l * l)))
            px, pz = a.x + vx * t, a.z + vz * t
        end
        for n = index + 1, #points do
            local q = points[n]
            local d = MathUtil.vector2Length(q.x - px, q.z - pz)
            if d >= remaining then
                tx, tz = px + (q.x - px) / d * remaining, pz + (q.z - pz) / d * remaining
                break
            end
            remaining = remaining - d
            px, pz = q.x, q.z
        end
        local dx, dz = tx - pose.x, tz - pose.z
        local dist = math.sqrt(dx * dx + dz * dz)
        local k = 0
        if dist > 0.1 then
            local alpha = wrap(headingOf(dx, dz) - pose.a)
            k = 2 * math.sin(alpha) / math.max(dist, 1)
            if math.abs(alpha) > PI / 2 then
                k = (alpha > 0 and 1 or -1) * kMax
            end
        end
        k = math.max(-kMax, math.min(kMax, k))
        pose = self:move(pose, ADCornerModule.SIM_STEP, k)
        if self.traceSink ~= nil then
            self.traceSink[#self.traceSink + 1] = pose
        end
        sinceCheck = sinceCheck + ADCornerModule.SIM_STEP
        sinceGround = sinceGround + ADCornerModule.SIM_STEP
        if sinceCheck >= ADCornerModule.CHECK_STEP then
            sinceCheck = 0
            local ground = sinceGround >= ADCornerModule.GROUND_STEP
            if ground then
                sinceGround = 0
            end
            local ok, reason = self:checkPose(pose, reference, ground)
            if not ok then
                return false, string.format("%s at %.0f,%.0f", reason, pose.x, pose.z)
            end
        end
    end
    -- the tractor must end up on the line: far off = steering could not follow
    local off = MathUtil.vector2Length(pose.x - last.x, pose.z - last.z)
    self.simEnd = pose
    if off > 3 then
        return false, string.format("cannot follow the line (%.1f m off)", off)
    end
    return true
end

------------------------------------------------------------------------------------------------
-- shortest paths arc, straight, arc at a given radius (pose: x, z, heading a; direction sin a, cos a)
------------------------------------------------------------------------------------------------
-- centre of the turn on side s (+1: the heading increases)
local function turnCentre(x, z, a, s, r)
    -- left of the direction (sin a, cos a) seen with increasing heading: (cos a, -sin a) * -s ... worked out:
    -- moving on a circle with heading increasing, the centre is at (x + r cos a * s, z - r sin a * s)
    return x + r * math.cos(a) * s, z - r * math.sin(a) * s
end

local function arcAngle(from, to, s)
    -- angle turned from heading 'from' to heading 'to' turning on side s, in [0, 2 pi)
    local d = (to - from) * s
    d = d % TWO_PI
    if d < 0 then
        d = d + TWO_PI
    end
    if d > TWO_PI - 1e-6 then
        d = 0
    end
    return d
end

-- returns {length, turn, s1, s2, a1, a2, c1, c2, t1, t2, straight, heading} or nil
function ADCornerModule.arcLineArc(p, q, r, s1, s2)
    local c1x, c1z = turnCentre(p.x, p.z, p.a, s1, r)
    local c2x, c2z = turnCentre(q.x, q.z, q.a, s2, r)
    local vx, vz = c2x - c1x, c2z - c1z
    local d = math.sqrt(vx * vx + vz * vz)
    local heading
    if s1 == s2 then
        if d < 1e-3 then
            return nil
        end
        heading = headingOf(vx, vz)
    else
        if d < 2 * r then
            return nil
        end
        -- inner tangent: the straight leaves circle 1 and touches circle 2 on the other side
        local phi = headingOf(vx, vz)
        heading = phi + s1 * math.asin(2 * r / d)
    end
    -- tangent points: on circle s, the point where the heading is h lies at centre - r * (cos h * s, -sin h * s)
    local t1x, t1z = c1x - r * math.cos(heading) * s1, c1z + r * math.sin(heading) * s1
    local t2x, t2z = c2x - r * math.cos(heading) * s2, c2z + r * math.sin(heading) * s2
    local straight = (t2x - t1x) * math.sin(heading) + (t2z - t1z) * math.cos(heading)
    if straight < -0.01 then
        return nil
    end
    local a1 = arcAngle(p.a, heading, s1)
    local a2 = arcAngle(heading, q.a, s2)
    return {length = r * (a1 + a2) + math.max(0, straight), turn = a1 + a2, s1 = s1, s2 = s2, a1 = a1, a2 = a2, r = r,
            c1 = {x = c1x, z = c1z}, c2 = {x = c2x, z = c2z}, t1 = {x = t1x, z = t1z}, t2 = {x = t2x, z = t2z},
            straight = math.max(0, straight), heading = heading}
end

local function newPoint(x, z)
    return {x = x, z = z, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 300, z), isPathFinderPoint = true, isCornerPoint = true}
end

-- points of a path (start excluded, end excluded)
local function pathPoints(p, path)
    local points = {}
    local function arc(cx, cz, from, angle, s)
        local steps = math.max(1, math.ceil(angle * path.r / ADCornerModule.ARC_STEP))
        for n = 1, steps do
            local h = from + s * angle * n / steps
            points[#points + 1] = newPoint(cx - path.r * math.cos(h) * s, cz + path.r * math.sin(h) * s)
        end
    end
    if path.a1 > 1e-3 then
        arc(path.c1.x, path.c1.z, p.a, path.a1, path.s1)
    end
    if path.straight > 0.5 then
        local steps = math.max(1, math.ceil(path.straight / ADCornerModule.LINE_STEP))
        for n = 1, steps do
            local f = n / steps
            points[#points + 1] = newPoint(path.t1.x + (path.t2.x - path.t1.x) * f, path.t1.z + (path.t2.z - path.t1.z) * f)
        end
    end
    if path.a2 > 1e-3 then
        arc(path.c2.x, path.c2.z, path.heading, path.a2, path.s2)
    end
    -- the last point is the end pose itself (a route point): drop it
    if #points > 0 then
        points[#points] = nil
    end
    return points
end

------------------------------------------------------------------------------------------------
-- route processing
------------------------------------------------------------------------------------------------
local function isNetworkPoint(wp)
    return wp ~= nil and wp.id ~= nil and not wp.isPathFinderPoint
end

local function segHeading(a, b)
    return headingOf(b.x - a.x, b.z - a.z)
end

local function dist(a, b)
    return MathUtil.vector2Length(b.x - a.x, b.z - a.z)
end

-- signed turn at point i of a list (from i-1 -> i to i -> i+1)
local function turnAt(list, i)
    local a, b, c = list[i - 1], list[i], list[i + 1]
    if a == nil or b == nil or c == nil or dist(a, b) < 0.05 or dist(b, c) < 0.05 then
        return 0
    end
    return wrap(segHeading(b, c) - segHeading(a, b))
end

-- distance from a point to a polyline
local function distanceToLine(line, x, z)
    local best = math.huge
    for n = 1, #line - 1 do
        local a, b = line[n], line[n + 1]
        local vx, vz = b.x - a.x, b.z - a.z
        local l2 = vx * vx + vz * vz
        local t = l2 > 1e-6 and math.max(0, math.min(1, ((x - a.x) * vx + (z - a.z) * vz) / l2)) or 0
        best = math.min(best, MathUtil.vector2Length(x - a.x - vx * t, z - a.z - vz * t))
    end
    return best
end

-- the bend starting at wayPoints[i] (out[#out] is the point before it): last index and total angle, nil if none
function ADCornerModule:findBend(wayPoints, i, prev)
    local list = {prev}
    local first = i
    local total, sign, last = 0, 0, nil
    local k = i
    while wayPoints[k + 1] ~= nil do
        local p, n = wayPoints[k], wayPoints[k + 1]
        local before = k == i and prev or wayPoints[k - 1]
        if not isNetworkPoint(p) or not isNetworkPoint(n) or not isNetworkPoint(before)
            or ADGraphManager:isReverseRoad(before, p) or ADGraphManager:isReverseRoad(p, n) then
            break
        end
        local turn = turnAt({before, p, n}, 2)
        if math.abs(turn) < ADCornerModule.POINT_MIN_ANGLE then
            break
        end
        local s = turn > 0 and 1 or -1
        if sign ~= 0 and s ~= sign then
            break
        end
        -- points of one curve are close together (the first one may be a single sharp point)
        if k > first and dist(before, p) > ADCornerModule.GROUP_SEGMENT_MAX then
            break
        end
        if math.abs(total + turn) > ADCornerModule.BEND_MAX_ANGLE then
            break
        end
        sign = s
        total = total + turn
        last = k
        k = k + 1
    end
    if last == nil or math.abs(total) < ADCornerModule.BEND_MIN_ANGLE then
        return nil
    end
    -- drawn radius: length of the curve (inside, plus half of the legs, 3 m at most each) / angle
    local length = math.min(3, dist(prev, wayPoints[first]) / 2) + math.min(3, dist(wayPoints[last], wayPoints[last + 1]) / 2)
    for n = first, last - 1 do
        length = length + dist(wayPoints[n], wayPoints[n + 1])
    end
    return last, total, length / math.abs(total)
end

-- entry points: indices in out (from the end), at most ENTRY_MAX metres back, spaced POSE_SPACING
function ADCornerModule:entryIndices(out, minIndex)
    local list = {#out}
    local length, sinceLast = 0, 0
    local k = #out
    while k > minIndex + 1 and #list < ADCornerModule.POSES_MAX do
        local a, b = out[k - 1], out[k]
        if not isNetworkPoint(a) or not isNetworkPoint(b) or b.isCornerPoint or ADGraphManager:isReverseRoad(a, b) then
            break
        end
        local l = dist(a, b)
        length = length + l
        sinceLast = sinceLast + l
        if length > ADCornerModule.ENTRY_MAX then
            break
        end
        k = k - 1
        if sinceLast >= ADCornerModule.POSE_SPACING and k > minIndex then
            list[#list + 1] = k
            sinceLast = 0
        end
    end
    return list
end

-- exit points: indices in wayPoints after the bend
function ADCornerModule:exitIndices(wayPoints, last)
    local list = {}
    local length, sinceLast = 0, ADCornerModule.POSE_SPACING
    local k = last
    while wayPoints[k + 2] ~= nil and #list < ADCornerModule.POSES_MAX do
        local a, b = wayPoints[k], wayPoints[k + 1]
        if not isNetworkPoint(a) or not isNetworkPoint(b) or ADGraphManager:isReverseRoad(a, b) or ADGraphManager:isReverseRoad(b, wayPoints[k + 2]) then
            break
        end
        local l = dist(a, b)
        length = length + l
        sinceLast = sinceLast + l
        if length > ADCornerModule.EXIT_MAX then
            break
        end
        k = k + 1
        if sinceLast >= ADCornerModule.POSE_SPACING then
            list[#list + 1] = k
            sinceLast = 0
        end
    end
    return list
end

-- the route after point k of wayPoints, SIM_TAIL metres (the trailer comes through)
local function tail(wayPoints, k)
    local points, length = {}, 0
    local n = k
    while wayPoints[n + 1] ~= nil and length < ADCornerModule.SIM_TAIL do
        length = length + dist(wayPoints[n], wayPoints[n + 1])
        n = n + 1
        points[#points + 1] = wayPoints[n]
    end
    return points
end

local function append(list, items)
    for _, item in ipairs(items) do
        list[#list + 1] = item
    end
    return list
end

-- distance to the drawn route of a few points of a path: tangent points, middle of the straight and of the arcs
function ADCornerModule.roughDeviation(path, drawn)
    local samples = {path.t1, path.t2, {x = (path.t1.x + path.t2.x) / 2, z = (path.t1.z + path.t2.z) / 2}}
    local function arcMiddle(c, from, angle, s)
        local h = from + s * angle / 2
        samples[#samples + 1] = {x = c.x - path.r * math.cos(h) * s, z = c.z + path.r * math.sin(h) * s}
    end
    if path.a1 > 0.1 then
        arcMiddle(path.c1, path.heading - path.s1 * path.a1, path.a1, path.s1)
    end
    if path.a2 > 0.1 then
        arcMiddle(path.c2, path.heading, path.a2, path.s2)
    end
    local deviation = 0
    for _, q in ipairs(samples) do
        deviation = math.max(deviation, distanceToLine(drawn, q.x, q.z))
    end
    return deviation
end

-- candidates from the start poses to the exit points, all together, tested by radius then by cost (added length
-- compared with the drawn route, plus the turning added, plus the distance from it); the first clear one is returned: {points, exit, start, path}
-- starts: {p = pose, point = route point at the pose, drawnBefore = metres of drawn route from it to the bend, extraCost}
-- drawnAfter[m]: metres of drawn route from the bend to the exit point m
function ADCornerModule:bestPath(starts, wayPoints, exits, drawnAfter, drawn, bendAngle, reference)
    local candidates = {}
    for _, st in ipairs(starts) do
        for _, m in ipairs(exits) do
            local q = {x = wayPoints[m].x, z = wayPoints[m].z, a = segHeading(wayPoints[m], wayPoints[m + 1])}
            for rank, factor in ipairs(ADCornerModule.RADIUS_FACTORS) do
                local r = self.radius * factor
                for _, t in ipairs(ADCornerModule.TYPES) do
                    local path = ADCornerModule.arcLineArc(st.p, q, r, t[1], t[2])
                    if path ~= nil and path.turn <= math.abs(bendAngle) + ADCornerModule.EXTRA_TURN_MAX then
                        local cost = path.length - (st.drawnBefore + drawnAfter[m]) + ADCornerModule.TURN_COST * math.max(0, path.turn - math.abs(bendAngle))
                            + ADCornerModule.DEVIATION_COST * ADCornerModule.roughDeviation(path, drawn) + (st.extraCost or 0)
                        candidates[#candidates + 1] = {path = path, exit = m, start = st, cost = cost, rank = rank}
                    end
                end
            end
        end
    end
    -- 08/11 (Fabien, Patriot 4450: « le plus large qui passe », gain de temps): the widest radius first (smoother and
    -- faster bend, swinging from the outside), smaller ones when it does not fit, the real radius of the train last.
    -- Each radius has its own budget of simulations so the tight one is still tried
    local deviationMax = math.abs(bendAngle) > ADCornerModule.UTURN_ANGLE and ADCornerModule.DEVIATION_MAX_UTURN or ADCornerModule.DEVIATION_MAX
    table.sort(candidates, function(a, b)
        if a.rank ~= b.rank then
            return a.rank > b.rank
        end
        return a.cost < b.cost
    end)
    local tested, lastReason = 0, "no path at this radius"
    local testedByRank = {}
    local wideReference = nil
    for _, c in ipairs(candidates) do
        local budget = c.rank == 1 and ADCornerModule.TESTS_MAX or ADCornerModule.TESTS_MAX_WIDE
        if (testedByRank[c.rank] or 0) < budget then
            local points = pathPoints(c.start.p, c.path)
            local deviation = 0
            for _, pt in ipairs(points) do
                deviation = math.max(deviation, distanceToLine(drawn, pt.x, pt.z))
            end
            -- a larger radius than the train needs: only when it stays on the road (close to the drawn route)
            local maxDeviation = c.rank > 1 and math.min(deviationMax, ADCornerModule.WIDE_DEVIATION_MAX) or deviationMax
            if deviation <= maxDeviation then
                tested = tested + 1
                testedByRank[c.rank] = (testedByRank[c.rank] or 0) + 1
                local line = append(append(append({c.start.point}, points), {wayPoints[c.exit]}), tail(wayPoints, c.exit))
                local ref = reference
                if c.rank > 1 then
                    wideReference = wideReference or {onField = reference.onField, onRoad = reference.onRoad, wideLine = drawn}
                    ref = wideReference
                end
                local clear, reason = self:simulate(line, self:straightPose(c.start.p.x, c.start.p.z, c.start.p.a), ref)
                if ADCornerModule.TRACE then
                    self:log("  try r %.1f %d/%d exit %d len %.0f cost %.1f dev %.1f: %s", c.path.r, c.path.s1, c.path.s2, c.exit, c.path.length, c.cost, deviation, clear and "clear" or tostring(reason))
                end
                if clear then
                    c.points = points
                    c.deviation = deviation
                    return c, tested
                end
                lastReason = reason
            else
                lastReason = string.format("too far from the route (%.0f m)", deviation)
            end
        end
    end
    return nil, tested, lastReason
end

-- straight back from x, z (heading a) over distance: room for the whole train
function ADCornerModule:isReverseClear(x, z, a, distance, reference)
    local s, c = math.sin(a), math.cos(a)
    local start = self:straightPose(x, z, a)
    for d = 0, distance, ADCornerModule.CHECK_STEP do
        local pose = {x = start.x - s * d, z = start.z - c * d, a = a, tx = start.tx - s * d, tz = start.tz - c * d}
        local ok, reason = self:checkPose(pose, reference, true)
        if not ok then
            return false, reason
        end
    end
    return true
end

-- returns the route with its tight bends replaced; firstIndex: first point that may be changed
function ADCornerModule:smoothRoute(wayPoints, firstIndex)
    if not self.vehicle.isServer or wayPoints == nil or #wayPoints < 3 or not ADCornerModule.isEnabled() then
        return wayPoints
    end
    self:readTrain()
    local minOut = math.max(1, (firstIndex or 3) - 1)
    local out = {}
    for i = 1, minOut do
        out[#out + 1] = wayPoints[i]
    end
    local i = #out + 1
    local changed, manoeuvres, kept = 0, 0, 0
    while i <= #wayPoints do
        local done = false
        local prev = out[#out]
        if isNetworkPoint(prev) and not prev.isCornerPoint and wayPoints[i + 1] ~= nil then
            local last, angle, drawnRadius = self:findBend(wayPoints, i, prev)
            if last ~= nil and drawnRadius < self.radius * ADCornerModule.RADIUS_FACTORS[1] then
                local result, nextIndex = self:handleBend(wayPoints, out, i, last, angle, drawnRadius, minOut)
                if result == "path" then
                    changed = changed + 1
                elseif result == "reverse" then
                    manoeuvres = manoeuvres + 1
                else
                    kept = kept + 1
                    -- the bend stays as drawn: its points are not looked at again one by one
                    for k = i, last do
                        out[#out + 1] = wayPoints[k]
                    end
                    nextIndex = last + 1
                end
                i = nextIndex
                done = true
            end
        end
        if not done then
            out[#out + 1] = wayPoints[i]
            i = i + 1
        end
    end
    if changed > 0 or kept > 0 or manoeuvres > 0 then
        self:log("route of %d points: %d bend(s) redrawn, %d manoeuvre(s), %d kept, radius %.1f m (vehicle file %.1f, wheels %s), train %.1f m wide, trailer %.1f m (%s: hitch %.1f, axle %.1f), look ahead %.1f m",
            #wayPoints, changed, manoeuvres, kept, self.radius, self.fileRadius or -1, self.wheelRadius ~= nil and string.format("%.1f", self.wheelRadius) or "?",
            self.width, self.trailerLength, self.geoSource, self.geo.hitch, self.geo.trailer, self.lookAhead)
    end
    return out
end

-- one bend wayPoints[first .. last] after out[#out]. Returns the result ("path", "reverse" or false) and the next
-- index of wayPoints to read; out is completed when the bend is replaced
function ADCornerModule:handleBend(wayPoints, out, first, last, angle, drawnRadius, minOut)
    local prev = out[#out]
    local where = string.format("bend %d-%d (%s-%s) %.0f deg, drawn radius %.1f m at %.0f,%.0f", first, last,
        tostring(wayPoints[first].id), tostring(wayPoints[last].id), math.deg(math.abs(angle)), drawnRadius, wayPoints[first].x, wayPoints[first].z)
    local exits = self:exitIndices(wayPoints, last)
    if #exits == 0 then
        self:log("%s: kept as it is (no room after it)", where)
        return false, first
    end
    local entries = self:entryIndices(out, minOut)
    local exitPoint = wayPoints[exits[#exits]]
    local reference = {onField = self:isOnField(prev.x, prev.z) or self:isOnField(exitPoint.x, exitPoint.z),
                       onRoad = self:isOnRoadMesh(prev.x, prev.z) and self:isOnRoadMesh(exitPoint.x, exitPoint.z)}
    -- the drawn route, from the furthest entry point to the furthest exit point
    local drawn = {}
    for k = entries[#entries], #out do
        drawn[#drawn + 1] = out[k]
    end
    for k = first, exits[#exits] do
        drawn[#drawn + 1] = wayPoints[k]
    end
    -- 1. the drawn route as the train would drive it
    local beforePrev = out[#out - 1]
    local a0 = beforePrev ~= nil and segHeading(beforePrev, prev) or segHeading(prev, wayPoints[first])
    local original = append({prev}, {})
    for k = first, exits[1] do
        original[#original + 1] = wayPoints[k]
    end
    append(original, tail(wayPoints, exits[1]))
    local originalClear, originalReason = self:simulate(original, self:straightPose(prev.x, prev.z, a0), reference)

    -- 2. forward candidates from the entry points
    local drawnAfter = {}
    local length, k = dist(prev, wayPoints[first]), first
    for _, m in ipairs(exits) do
        while k < m do
            length = length + dist(wayPoints[k], wayPoints[k + 1])
            k = k + 1
        end
        drawnAfter[m] = length
    end
    local starts = {}
    for _, e in ipairs(entries) do
        local ep, before = out[e], out[e - 1]
        if before ~= nil then
            starts[#starts + 1] = {p = {x = ep.x, z = ep.z, a = segHeading(before, ep)}, point = ep, index = e, drawnBefore = self:lengthBack(out, e, #out)}
        end
    end
    local best, tests, lastReason = self:bestPath(starts, wayPoints, exits, drawnAfter, drawn, angle, reference)
    if best ~= nil then
        local back = best.start.drawnBefore
        self:replace(out, best.start.index, best.points)
        self:log("%s: redrawn at radius %.1f m from %.0f m before (%d points, %.0f m from the drawn line at most, %d tested; drawn route: %s)",
            where, best.path.r, back, #best.points, best.deviation, tests,
            originalClear and "would pass" or tostring(originalReason))
        return "path", best.exit
    end
    if originalClear then
        self:log("%s: kept as it is (the train passes; no smoother path: %s)", where, tostring(lastReason))
        return false, first
    end

    -- 3. manoeuvre: stop at an entry point, back up straight, take the bend from there
    for _, distance in ipairs(ADCornerModule.REVERSE_DISTANCES) do
        local starts = {}
        for _, e in ipairs(entries) do
            local g, before = out[e], out[e - 1]
            if before ~= nil then
                local a = segHeading(before, g)
                local fx, fz = g.x - math.sin(a) * distance, g.z - math.cos(a) * distance
                -- backing up is useful only off the route already driven (the route before turns away)
                local behind = {}
                for k2 = math.max(1, e - 12), e do
                    behind[#behind + 1] = out[k2]
                end
                if #behind >= 2 and distanceToLine(behind, fx, fz) > 3 then
                    local clear, reason = self:isReverseClear(g.x, g.z, a, distance, reference)
                    if clear then
                        starts[#starts + 1] = {p = {x = fx, z = fz, a = a}, point = newPoint(fx, fz), index = e, g = g,
                                               drawnBefore = self:lengthBack(out, e, #out), extraCost = distance * 2}
                    else
                        lastReason = "no room to back up: " .. tostring(reason)
                    end
                end
            end
        end
        if #starts > 0 then
            local c, _, reason = self:bestPath(starts, wayPoints, exits, drawnAfter, drawn, angle, reference)
            if c ~= nil then
                local g, a = c.start.g, c.start.p.a
                local start = c.start.point
                start.cornerReverse = {gx = g.x, gz = g.z, hx = math.sin(a), hz = math.cos(a), distance = distance}
                self:replace(out, c.start.index, append({start}, c.points))
                self:log("%s: manoeuvre, stop at %s (%.0f,%.0f), back up %.0f m, then radius %.1f m (%d points; drawn route: %s)",
                    where, tostring(g.id), g.x, g.z, distance, c.path.r, #c.points, tostring(originalReason))
                return "reverse", c.exit
            end
            lastReason = reason or lastReason
        end
    end
    self:log("%s: nothing fits, kept as it is (drawn route: %s; last candidate: %s)", where, tostring(originalReason), tostring(lastReason))
    return false, first
end

-- keeps out[1 .. keep] and adds the points
function ADCornerModule:replace(out, keep, points)
    for k = #out, keep + 1, -1 do
        out[k] = nil
    end
    append(out, points)
end

function ADCornerModule:lengthBack(out, from, to)
    local length = 0
    for k = from, math.min(to, #out) - 1 do
        length = length + dist(out[k], out[k + 1])
    end
    return length
end

------------------------------------------------------------------------------------------------
-- end of the route (07/11, Fabien: « il faut reprendre un itinéraire qui lui permet de prendre ce virage plus
-- facilement, quitte à aller faire un détour »): a destination behind a U-turn tighter than the tractor can steer
-- (« Champ 56 », 170 deg on 5 m) is never reached: the tractor circles around the point, the stuck safety restarts
-- it and the same route brings it back. Before driving, the end of the route is driven in a simulation (AutoDrive
-- steering, limited to the turning radius); when the last point is not reached, the sharpest turn of the end is
-- banned and another route is searched (another way into the destination, detour accepted up to DETOUR_MAX m).
------------------------------------------------------------------------------------------------
ADCornerModule.END_SIM_BACK = 30       -- m of route before the destination driven in the simulation
ADCornerModule.END_SIM_EXTRA = 25      -- m driven at most beyond the length of that route
ADCornerModule.END_SIM_STEP = 0.25     -- m per simulated step
ADCornerModule.END_TRIES = 4           -- other routes tried at most
ADCornerModule.DETOUR_MAX = 3000       -- m a route may be longer than the first one
ADCornerModule.endCache = {}           -- [start:target:radius] = turns banned for the route found, false when none (cleared when the network changes)

local function routeLength(path)
    local length = 0
    for i = 1, #path - 1 do
        length = length + dist(path[i], path[i + 1])
    end
    return length
end

-- true when the train reaches the last point of path; else false, the closest distance and the sharpest turn of the
-- end of the route as "from:at:to" (waypoint ids), nil when there is none to ban
function ADCornerModule:canReachEnd(path)
    local n = #path
    if n < 3 then
        return true
    end
    -- a reverse section near the end (parking backwards into a shed): driven by AutoDrive's reversing, not judged here
    local reverseLength = 0
    for i = n - 1, 1, -1 do
        if ADGraphManager:isReverseRoad(path[i], path[i + 1]) or path[i].isPathFinderPoint or path[i + 1].isPathFinderPoint then
            return true
        end
        reverseLength = reverseLength + dist(path[i], path[i + 1])
        if reverseLength > ADCornerModule.END_SIM_BACK + 10 then
            break
        end
    end
    local radius = self.radius or 6
    local lookAhead = self.lookAhead or 5
    local dpm = self.vehicle.ad ~= nil and self.vehicle.ad.drivePathModule or nil
    local reach = math.max(1.5, math.min(5, dpm ~= nil and dpm.min_distance or 3))
    -- start END_SIM_BACK m before the end, on the route, along it
    local s, back = n, 0
    while s > 1 and back < ADCornerModule.END_SIM_BACK do
        back = back + dist(path[s - 1], path[s])
        s = s - 1
    end
    s = math.max(s, 1)
    local x, z = path[s].x, path[s].z
    local h = segHeading(path[s], path[s + 1])
    if s > 1 then
        h = segHeading(path[s - 1], path[s])
    end
    local current = s + 1
    local step = ADCornerModule.END_SIM_STEP
    local budget = back + ADCornerModule.END_SIM_EXTRA
    local travelled, closest = 0, math.huge
    local last = path[n]
    while travelled < budget do
        -- a point counts as passed within reach, the next one may be taken instead (AutoDrive skips one at most)
        local moved = true
        while moved and current <= n do
            moved = false
            for skip = 0, 1 do
                local p = path[current + skip]
                if p ~= nil and MathUtil.vector2Length(p.x - x, p.z - z) < reach then
                    current = current + skip + 1
                    moved = true
                    break
                end
            end
        end
        closest = math.min(closest, MathUtil.vector2Length(last.x - x, last.z - z))
        if current > n then
            return true
        end
        local k = current
        while k < n and MathUtil.vector2Length(path[k].x - x, path[k].z - z) < lookAhead do
            k = k + 1
        end
        local tx, tz = path[k].x, path[k].z
        local alpha = wrap(headingOf(tx - x, tz - z) - h)
        local ld = math.max(1, MathUtil.vector2Length(tx - x, tz - z))
        local curvature = math.max(-1 / radius, math.min(1 / radius, 2 * math.sin(alpha) / ld))
        h = h + curvature * step
        x, z = x + math.sin(h) * step, z + math.cos(h) * step
        travelled = travelled + step
    end
    -- sharpest turn between network points in the end of the route
    local worst, key = 0, nil
    local length = 0
    for i = n - 1, 2, -1 do
        length = length + dist(path[i], path[i + 1])
        if length > ADCornerModule.END_SIM_BACK then
            break
        end
        local a, b, c = path[i - 1], path[i], path[i + 1]
        if isNetworkPoint(a) and isNetworkPoint(b) and isNetworkPoint(c) then
            local turn = math.abs(turnAt(path, i))
            if turn > worst then
                worst, key = turn, a.id .. ":" .. b.id .. ":" .. c.id
            end
        end
    end
    return false, closest, key
end

-- another way into the destination: the sharpest turn of the end (key) is banned and the route searched again.
-- Returns the route, the turns banned and the metres added, or nil
function ADCornerModule:findOtherWayIn(path, startId, targetId, preferredNeighbors, key, where, length0)
    if key == nil then
        self:log("%s: no turn to avoid, no other way in", where)
        return nil
    end
    local banned = {}
    for try = 1, ADCornerModule.END_TRIES do
        banned[key] = true
        local other = ADPathCalculator:GetPath(startId, targetId, preferredNeighbors or {}, self.vehicle, banned)
        if other == nil or #other < 2 then
            self:log("%s: no other route (try %d)", where, try)
            return nil
        end
        local length = routeLength(other)
        if length > length0 + ADCornerModule.DETOUR_MAX then
            self:log("%s: the other route is %.0f m longer (%.0f m at most)", where, length - length0, ADCornerModule.DETOUR_MAX)
            return nil
        end
        local ok2, closest2, key2 = self:canReachEnd(other)
        if ok2 then
            local before = other[#other - 2]
            self:log("%s: other route of %.0f m instead of %.0f m (+%.0f m), coming in by %s", where, length, length0, length - length0, tostring(before ~= nil and before.id or "?"))
            return other, banned, length - length0
        end
        if key2 == nil or banned[key2] then
            self:log("%s: the other route ends as tight (%.1f m at best)", where, closest2)
            return nil
        end
        key = key2
    end
    self:log("%s: no other route the train can end", where)
    return nil
end

-- seconds to drive the metres added by a detour (average share of the speed limit)
function ADCornerModule:detourSeconds(extra)
    local limit = 40
    local sm = self.vehicle.ad ~= nil and self.vehicle.ad.stateModule or nil
    if sm ~= nil and sm.getSpeedLimit ~= nil then
        limit = sm:getSpeedLimit() or limit
    end
    return extra / math.max(1, limit * ADCornerModule.EM_ROAD_SHARE / 3.6)
end

-- path: network route from startId to targetId (ADPathCalculator:GetPath). Returns it, or a route ending with a
-- manoeuvre (08/11), or another route the train can drive to the end, whichever is faster
function ADCornerModule:avoidTightEnd(path, startId, targetId, preferredNeighbors)
    if path == nil or #path < 3 or not self.vehicle.isServer or not ADCornerModule.isEnabled() then
        return path
    end
    self:readTrain()
    local cacheKey = string.format("%s:%s:%.0f", tostring(startId), tostring(targetId), (self.radius or 0) * 10)
    local cached = ADCornerModule.endCache[cacheKey]
    if cached == false then
        return path
    end
    if cached == "manoeuvre" then
        local route = self:endManoeuvreRoute(path, targetId, "same route as before")
        if route ~= nil then
            return route
        end
    elseif cached ~= nil then
        local other = ADPathCalculator:GetPath(startId, targetId, preferredNeighbors or {}, self.vehicle, cached)
        if other ~= nil and #other >= 2 and self:canReachEnd(other) then
            return other
        end
    end
    local ok, closest, key = self:canReachEnd(path)
    if ok then
        return path
    end
    ADCornerModule.endCache[cacheKey] = false
    local marker = ADGraphManager.getMapMarkerByWayPointId ~= nil and ADGraphManager:getMapMarkerByWayPointId(targetId) or nil
    local where = string.format("end of the route to %s (%s)", marker ~= nil and tostring(marker.name) or "?", tostring(targetId))
    local length0 = routeLength(path)
    self:log("%s: radius %.1f m, the last point is not reached (%.1f m at best, turn %s too tight): manoeuvre or another way in", where, self.radius, closest, tostring(key))
    local manoeuvre, manoeuvreTime = self:endManoeuvreRoute(path, targetId, where)
    local other, banned, extra = self:findOtherWayIn(path, startId, targetId, preferredNeighbors, key, where, length0)
    if manoeuvre ~= nil then
        local detourTime = other ~= nil and self:detourSeconds(extra) or math.huge
        if other == nil or manoeuvreTime + ADCornerModule.EM_GAIN_MIN < detourTime then
            ADCornerModule.endCache[cacheKey] = "manoeuvre"
            self:log("%s: manoeuvre kept (%.0f s; other way in: %s)", where, manoeuvreTime,
                other ~= nil and string.format("+%.0f m, about %.0f s more", extra, detourTime) or "none")
            return manoeuvre
        end
        self:log("%s: the other way in is faster (+%.0f m, about %.0f s, manoeuvre %.0f s)", where, extra, detourTime, manoeuvreTime)
    end
    if other ~= nil then
        ADCornerModule.endCache[cacheKey] = banned
        return other
    end
    self:log("%s: route kept", where)
    return path
end

------------------------------------------------------------------------------------------------
-- manoeuvre at the end of the route (08/11, Fabien: « sur une fin de parcours il peut faire une manœuvre plutôt que
-- faire un détour ? avant de partir ? »). When the last point is out of reach, before leaving, a manoeuvre is looked
-- for like a driver does it: from a point of the route before the bend, forward turning into the bend, back up
-- (turning the other way; straight and short with a trailed tool), then forward to the destination. Every half
-- metre the train is checked (static obstacles, ditch or bank, field ground when the route is not on a field). The
-- fastest one is compared with the other way in (detour): the faster is driven. Driven with the legs of ADBandTurn.
------------------------------------------------------------------------------------------------
ADCornerModule.EM_STOP_BACK = 24          -- m of route before the destination where the manoeuvre may start ...
ADCornerModule.EM_STOP_MIN = 3            -- m ... but not closer
ADCornerModule.EM_STOP_STEP = 3           -- m between two starts tried
ADCornerModule.EM_LEAD_IN = 8             -- m of route before the start driven in the first leg (joins it smoothly)
ADCornerModule.EM_STEP = 0.5              -- m per simulated step
ADCornerModule.EM_TURN_STEP = math.rad(15) -- first leg, forward turning into the bend: tried by steps of ...
ADCornerModule.EM_TURN_MAX = math.rad(135) -- ... up to
ADCornerModule.EM_BACK_MAX = 16           -- m backed up at most
ADCornerModule.EM_BACK_STEP = 2           -- m between two lengths tried
ADCornerModule.EM_TRAILER_BACK_MAX = 8    -- m: trailed tool, straight back only ...
ADCornerModule.EM_TRAILER_ARTICULATION = math.rad(30) -- ... and never more bent than this
ADCornerModule.EM_LAST_MAX = 45           -- m of the last forward leg at most
ADCornerModule.EM_RADIUS_MARGIN = 1.1     -- planned radius = turning radius * margin (some steering left to correct)
ADCornerModule.EM_HEADINGS = {{0}, {math.rad(20), -math.rad(20)}} -- arrival heading: the last road direction, else close
ADCornerModule.EM_HEADING_COST = 6        -- s per radian away from the last road direction
ADCornerModule.EM_SPEED = 5               -- km/h during the manoeuvre (ADBandTurn.SPEED)
ADCornerModule.EM_APPROACH_SPEED = 3      -- m/s on the route before a later start
ADCornerModule.EM_STOP_TIME = 4           -- s per stop (change of direction)
ADCornerModule.EM_TILT_MAX = 0.6          -- m between left and right wheels: more = ditch, bank
ADCornerModule.EM_PITCH_MAX = 1.5         -- m between front and rear of a body
ADCornerModule.EM_TESTS_MAX = 200         -- candidates checked at most ...
ADCornerModule.EM_CHECKS_MAX = 3000       -- ... and poses checked at most (one frame of route calculation)
ADCornerModule.EM_ROAD_SHARE = 0.6        -- average share of the speed limit driven on a detour
ADCornerModule.EM_GAIN_MIN = 10           -- s the manoeuvre must save to be preferred to the other way in
ADCornerModule.EM_FAILED_TIME = 600000    -- ms the other way in is used for a destination after a failed manoeuvre
ADCornerModule.EM_TIMEOUT = 150000        -- ms for the whole manoeuvre (waiting for traffic excluded)
ADCornerModule.EM_WAIT_MAX = 30000        -- ms waiting for a vehicle in the way
ADCornerModule.EM_REPLANS = 1             -- new plans from where the train stands when it goes off the line
ADCornerModule.endFailed = {}             -- [targetId] = g_time of a failed manoeuvre

local function nowMs()
    return g_time or (g_currentMission ~= nil and g_currentMission.time) or 0
end

-- the train for the manoeuvre: a wheeled trailer keeps its geometry (hitch, axle); mounted tools (no wheels on the
-- ground) belong to the tractor body
function ADCornerModule:manoeuvreGeometry()
    if self.geoSource == "measured" or (self.geoSource == "estimated" and self.geoWhy ~= "pas de remorque a roues") then
        return self.geo, "trailed tool"
    end
    if self.trailerLength <= 0 or self.vehicle.components == nil then
        return self.geo, "tractor alone"
    end
    local node = self.vehicle.getAIDirectionNode ~= nil and self.vehicle:getAIDirectionNode() or self.vehicle.components[1].node
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local a = headingOf(dx, dz)
    local box = {front = self.geo.tractorBox.front, rear = self.geo.tractorBox.rear, half = self.geo.tractorBox.half}
    local units = AutoDrive.getAllUnits(self.vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit ~= self.vehicle and unit.components ~= nil and unit.components[1] ~= nil then
                local b = bodyBox(unit, x, z, a)
                box.front, box.rear, box.half = math.max(box.front, b.front), math.min(box.rear, b.rear), math.max(box.half, b.half)
            end
        end
    end
    return {hitch = 0, trailer = 0, tractorBox = box}, string.format("mounted tool (body %.1f m ahead, %.1f m behind the axle)", box.front, -box.rear)
end

-- one body standing level enough: left / right wheels (ditch, bank) and front / rear
function ADCornerModule:isBodyLevel(x, z, a, box)
    local s, c = math.sin(a), math.cos(a)
    local root = g_currentMission.terrainRootNode
    local h = {}
    for i, f in ipairs({box.front, box.rear}) do
        for j, side in ipairs({-1, 1}) do
            local px, pz = x + s * f + c * box.half * side, z + c * f - s * box.half * side
            h[i * 2 + j - 2] = getTerrainHeightAtWorldPos(root, px, 300, pz)
        end
    end
    if math.abs(h[1] - h[2]) > ADCornerModule.EM_TILT_MAX or math.abs(h[3] - h[4]) > ADCornerModule.EM_TILT_MAX then
        return false, "ditch or bank"
    end
    if math.abs((h[1] + h[2]) - (h[3] + h[4])) / 2 > ADCornerModule.EM_PITCH_MAX then
        return false, "slope"
    end
    return true
end

local function farmlandAt(x, z)
    if g_farmlandManager ~= nil and g_farmlandManager.getFarmlandIdAtWorldPosition ~= nil then
        return g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    end
    return nil
end

-- wheels of one axle on a field of another farmland than the destination one (the field allowed is its own)
function ADCornerModule:isOtherField(x, z, a, half, farmland)
    local nx, nz = math.cos(a), -math.sin(a)
    for _, side in ipairs({-1, 1}) do
        local px, pz = x + nx * half * side, z + nz * half * side
        if self:isOnField(px, pz) and farmlandAt(px, pz) ~= farmland then
            return true
        end
    end
    return false
end

function ADCornerModule:emCheckPose(pose, reference)
    local ok, reason = self:checkPose(pose, reference, true)
    if not ok then
        return false, reason
    end
    if reference.farmland ~= nil then
        if self:isOtherField(pose.x, pose.z, pose.a, self.geo.tractorBox.half, reference.farmland) then
            return false, "other field (tractor)"
        end
        if self.geo.trailer > 0 and self.geo.trailerBox ~= nil and self:isOtherField(pose.tx, pose.tz, self:trailerHeading(pose), self.geo.trailerBox.half, reference.farmland) then
            return false, "other field (trailer)"
        end
    end
    local level, why = self:isBodyLevel(pose.x, pose.z, pose.a, self.geo.tractorBox)
    if not level then
        return false, why .. " (tractor)"
    end
    if self.geo.trailer > 0 and self.geo.trailerBox ~= nil then
        level, why = self:isBodyLevel(pose.tx, pose.tz, self:trailerHeading(pose), self.geo.trailerBox)
        if not level then
            return false, why .. " (trailer)"
        end
    end
    return true
end

-- poses every EM_STEP from pose driving dir (1 forward, -1 back) at curvature k over length
function ADCornerModule:emIntegrate(pose, dir, k, length)
    local poses = {}
    for i = 1, math.floor(length / ADCornerModule.EM_STEP + 0.5) do
        pose = self:move(pose, dir * ADCornerModule.EM_STEP, k)
        poses[i] = pose
    end
    return poses
end

-- a chain of poses checked lazily (shared by the candidates): true when poses[1 .. upTo] are clear
function ADCornerModule:emClear(chain, upTo, reference)
    if chain.blocked ~= nil and upTo >= chain.blocked then
        return false, chain.reason
    end
    while chain.checked < upTo do
        local i = chain.checked + 1
        if i % 2 == 0 or i == upTo then
            self.emChecks = self.emChecks + 1
            local ok, reason = self:emCheckPose(chain.poses[i], reference)
            if ok and chain.trailed and math.abs(wrap(chain.poses[i].a - self:trailerHeading(chain.poses[i]))) > ADCornerModule.EM_TRAILER_ARTICULATION then
                ok, reason = false, "tool too bent"
            end
            if not ok then
                chain.blocked, chain.reason = i, reason
                return false, reason
            end
        end
        chain.checked = i
    end
    return true
end

-- poses of an arc, straight, arc path from pose (exact geometry)
function ADCornerModule:emPathPoses(pose, path)
    local poses = {}
    local function add(list)
        for _, p in ipairs(list) do
            poses[#poses + 1] = p
        end
        pose = poses[#poses] or pose
    end
    if path.a1 > 1e-3 then
        add(self:emIntegrate(pose, 1, path.s1 / path.r, path.r * path.a1))
    end
    if path.straight > 0.25 then
        add(self:emIntegrate(pose, 1, 0, path.straight))
    end
    if path.a2 > 1e-3 then
        add(self:emIntegrate(pose, 1, path.s2 / path.r, path.r * path.a2))
    end
    return poses
end

-- sample of a pose for ADBandTurn.driveLeg: tractor axle, and the line followed backwards (trailer axle, or the
-- tractor itself)
function ADCornerModule:emSample(pose)
    if self.geo.trailer > 0 then
        return {x = pose.x, z = pose.z, tx = pose.tx, tz = pose.tz}
    end
    return {x = pose.x, z = pose.z, tx = pose.x, tz = pose.z}
end

function ADCornerModule:emLeg(dir, first, poses, from, to)
    local leg = {dir = dir, points = {}, length = 0}
    if first ~= nil then
        leg.points[1] = self:emSample(first)
    end
    for i = from or 1, to or #poses do
        leg.points[#leg.points + 1] = self:emSample(poses[i])
        leg.length = leg.length + ADCornerModule.EM_STEP
    end
    return leg
end

-- the manoeuvre from one of the starts to the target pose (x, z, a). starts: {pose, lead (points before), approach (s)}.
-- side: +1 when the bend turns with increasing heading. Returns {legs, time, text} or nil, reason
function ADCornerModule:planManoeuvre(starts, target, side, reference)
    local R = self.radius * ADCornerModule.EM_RADIUS_MARGIN
    local K = 1 / R
    local trailed = self.geo.trailer > 0
    local speed = ADCornerModule.EM_SPEED / 3.6
    local turnSteps = math.floor(ADCornerModule.EM_TURN_MAX / ADCornerModule.EM_TURN_STEP + 0.5)
    local backMax = trailed and ADCornerModule.EM_TRAILER_BACK_MAX or ADCornerModule.EM_BACK_MAX
    local backCurves = trailed and {0} or {-side * K, 0}
    self.emChecks = 0
    local reasons = {}
    local function note(reason)
        reason = string.gsub(tostring(reason), " at %-?%d+,%-?%d+", "")
        reasons[reason] = (reasons[reason] or 0) + 1
    end
    for pass, headings in ipairs(ADCornerModule.EM_HEADINGS) do
        local candidates = {}
        for si, st in ipairs(starts) do
            st.leg1 = st.leg1 or {poses = self:emIntegrate(st.pose, 1, side * K, R * ADCornerModule.EM_TURN_MAX), checked = 0, trailed = false}
            st.leg2 = st.leg2 or {}
            for j = 0, turnSteps do
                local n1 = math.floor(R * ADCornerModule.EM_TURN_STEP * j / ADCornerModule.EM_STEP + 0.5)
                local pose1 = n1 > 0 and st.leg1.poses[n1] or st.pose
                if pose1 == nil then
                    break
                end
                -- forward only (the end redrawn wider), then with a reverse
                local backs = {}
                if j == 0 then
                    backs[#backs + 1] = {k = 0, length = 0}
                end
                for ci, kr in ipairs(backCurves) do
                    local key = j * 10 + ci
                    st.leg2[key] = st.leg2[key] or {poses = self:emIntegrate(pose1, -1, kr, backMax), checked = 0, trailed = trailed}
                    for L = ADCornerModule.EM_BACK_STEP, backMax, ADCornerModule.EM_BACK_STEP do
                        backs[#backs + 1] = {k = kr, length = L, key = key}
                    end
                end
                for _, b in ipairs(backs) do
                    local n2 = math.floor(b.length / ADCornerModule.EM_STEP + 0.5)
                    local pose2 = n2 > 0 and st.leg2[b.key].poses[n2] or pose1
                    for _, dh in ipairs(headings) do
                        local q = {x = target.x, z = target.z, a = target.a + dh}
                        for _, t in ipairs(ADCornerModule.TYPES) do
                            local path = ADCornerModule.arcLineArc(pose2, q, R, t[1], t[2])
                            if path ~= nil and path.length <= ADCornerModule.EM_LAST_MAX then
                                local stops = n2 > 0 and 2 or 0
                                local length = st.leadLength + n1 * ADCornerModule.EM_STEP + b.length + path.length
                                local time = (st.approach or 0) + length / speed + stops * ADCornerModule.EM_STOP_TIME + math.abs(dh) * ADCornerModule.EM_HEADING_COST
                                candidates[#candidates + 1] = {st = st, j = j, n1 = n1, back = b, n2 = n2, path = path, pose2 = pose2, time = time, dh = dh, length = length}
                            end
                        end
                    end
                end
            end
        end
        table.sort(candidates, function(a, b)
            return a.time < b.time
        end)
        local tested = 0
        for _, c in ipairs(candidates) do
            if tested >= ADCornerModule.EM_TESTS_MAX or self.emChecks >= ADCornerModule.EM_CHECKS_MAX then
                note("search limit reached")
                break
            end
            local ok, reason = true, nil
            if c.n1 > 0 then
                ok, reason = self:emClear(c.st.leg1, c.n1, reference)
                if not ok then
                    reason = "forward: " .. tostring(reason)
                end
            end
            if ok and c.n2 > 0 then
                ok, reason = self:emClear(c.st.leg2[c.back.key], c.n2, reference)
                if not ok then
                    reason = "back: " .. tostring(reason)
                end
            end
            if ok then
                tested = tested + 1
                local poses = self:emPathPoses(c.pose2, c.path)
                local chain = {poses = poses, checked = 0, trailed = false}
                ok, reason = self:emClear(chain, #poses, reference)
                if not ok then
                    reason = "last leg: " .. tostring(reason)
                else
                    -- legs for ADBandTurn.driveLeg
                    local legs = {}
                    local first = self:emLeg(1, nil, c.st.lead or {}, 1, #(c.st.lead or {}))
                    if c.n2 == 0 then
                        -- forward only: lead in, then the path
                        for _, p in ipairs(poses) do
                            first.points[#first.points + 1] = self:emSample(p)
                            first.length = first.length + ADCornerModule.EM_STEP
                        end
                        legs[1] = first
                    else
                        for i = 1, c.n1 do
                            first.points[#first.points + 1] = self:emSample(c.st.leg1.poses[i])
                            first.length = first.length + ADCornerModule.EM_STEP
                        end
                        if #first.points >= 2 then
                            legs[#legs + 1] = first
                        end
                        local pose1 = c.n1 > 0 and c.st.leg1.poses[c.n1] or c.st.pose
                        legs[#legs + 1] = self:emLeg(-1, pose1, c.st.leg2[c.back.key].poses, 1, c.n2)
                        legs[#legs + 1] = self:emLeg(1, c.pose2, poses, 1, #poses)
                    end
                    local text
                    if c.n2 == 0 then
                        text = string.format("forward only, %.0f m", c.path.length)
                    else
                        text = string.format("forward %.0f m turning %.0f deg, back %.0f m %s, forward %.0f m", c.n1 * ADCornerModule.EM_STEP,
                            math.deg(ADCornerModule.EM_TURN_STEP * c.j), c.back.length, c.back.k == 0 and "straight" or "turning", c.path.length)
                    end
                    if math.abs(c.dh) > 1e-3 then
                        text = text .. string.format(", arriving %.0f deg off the road", math.deg(c.dh))
                    end
                    return {legs = legs, time = c.time, text = text, start = c.st, tested = tested, checks = self.emChecks, pass = pass}
                end
            end
            note(reason)
        end
    end
    local worst, count = "nothing possible", 0
    for r, n in pairs(reasons) do
        if n > count then
            worst, count = r, n
        end
    end
    return nil, string.format("%s (x%d, %d checks)", worst, count, self.emChecks)
end

-- starts of the manoeuvre on the route: every EM_STOP_STEP metres between EM_STOP_MIN and EM_STOP_BACK before the
-- destination, where the route runs straight (the train arrives there straight)
function ADCornerModule:manoeuvreStarts(path)
    local starts = {}
    local n = #path
    local back = 0
    local nextAt = ADCornerModule.EM_STOP_MIN
    for i = n - 1, 1, -1 do
        local a, b = path[i], path[i + 1]
        local l = dist(a, b)
        while l > 0.01 and nextAt <= back + l and nextAt <= ADCornerModule.EM_STOP_BACK do
            local f = (back + l - nextAt) / l -- from a toward b
            local x, z = a.x + (b.x - a.x) * f, a.z + (b.z - a.z) * f
            local h = segHeading(a, b)
            -- straight: the route 4 m before runs the same way (15 deg)
            local before = path[i - 1]
            if before == nil or dist(a, {x = x, z = z}) >= 4 or math.abs(wrap(segHeading(before, a) - h)) < math.rad(15) then
                -- lead in: the route from EM_LEAD_IN metres before up to the start
                local lead, leadLength = {}, 0
                local px, pz, k = x, z, i
                local pts = {}
                while k >= 1 and leadLength < ADCornerModule.EM_LEAD_IN do
                    local q = path[k]
                    local d = MathUtil.vector2Length(q.x - px, q.z - pz)
                    leadLength = leadLength + d
                    pts[#pts + 1] = {x = q.x, z = q.z}
                    px, pz = q.x, q.z
                    k = k - 1
                end
                -- every EM_STEP along the lead in, oldest first
                local line = {}
                for m = #pts, 1, -1 do
                    line[#line + 1] = pts[m]
                end
                line[#line + 1] = {x = x, z = z}
                for m = 1, #line - 1 do
                    local p, q = line[m], line[m + 1]
                    local d = dist(p, q)
                    local steps = math.max(1, math.floor(d / ADCornerModule.EM_STEP))
                    local hh = segHeading(p, q)
                    for s2 = 0, steps - 1 do
                        local f2 = s2 / steps
                        lead[#lead + 1] = self:straightPose(p.x + (q.x - p.x) * f2, p.z + (q.z - p.z) * f2, hh)
                    end
                end
                starts[#starts + 1] = {pose = self:straightPose(x, z, h), index = i, lead = lead, leadLength = #lead * ADCornerModule.EM_STEP,
                                       approach = 0, back = nextAt}
            end
            nextAt = nextAt + ADCornerModule.EM_STOP_STEP
        end
        back = back + l
        if nextAt > ADCornerModule.EM_STOP_BACK then
            break
        end
    end
    -- the route from the furthest start to a later one is driven at the approach speed, not in the manoeuvre
    local furthest = 0
    for _, st in ipairs(starts) do
        furthest = math.max(furthest, st.back)
    end
    for _, st in ipairs(starts) do
        st.approach = (furthest - st.back) / ADCornerModule.EM_APPROACH_SPEED
    end
    return starts
end

-- turning side of the end of the route: sum of the turns of its last metres
local function endSide(path)
    local total, length = 0, 0
    for i = #path - 1, 2, -1 do
        total = total + turnAt(path, i)
        length = length + dist(path[i], path[i + 1])
        if length > ADCornerModule.EM_STOP_BACK + 10 then
            break
        end
    end
    return total >= 0 and 1 or -1
end

-- the route cut at the start of the manoeuvre, then the manoeuvre point, then the destination. Returns it and the
-- time of the manoeuvre, or nil
function ADCornerModule:endManoeuvreRoute(path, targetId, where)
    if ADBandTurn == nil or ADBandTurn.driveLeg == nil or #path < 2 then
        return nil
    end
    local failed = ADCornerModule.endFailed[targetId]
    if failed ~= nil and nowMs() - failed < ADCornerModule.EM_FAILED_TIME then
        self:log("%s: the manoeuvre failed here %.0f s ago, not tried again", where, (nowMs() - failed) / 1000)
        return nil
    end
    local n = #path
    local P = path[n]
    local target = {x = P.x, z = P.z, a = segHeading(path[n - 1], P)}
    local side = endSide(path)
    local saved = self.geo
    local geo, what = self:manoeuvreGeometry()
    self.geo = geo
    local starts = self:manoeuvreStarts(path)
    -- field ground: allowed when the destination (or the route just before it) is on a field, that field only
    local reference = {onField = false, onRoad = false}
    for _, q in ipairs({P, starts[1] ~= nil and starts[1].pose or nil}) do
        if q ~= nil and not reference.onField and self:isOnField(q.x, q.z) then
            reference.onField, reference.farmland = true, farmlandAt(q.x, q.z)
        end
    end
    local plan, reason = nil, "no straight route before the bend"
    if #starts > 0 then
        plan, reason = self:planManoeuvre(starts, target, side, reference)
    end
    self.geo = saved
    if plan == nil then
        self:log("%s: no manoeuvre (%s; %s, radius %.1f m, %d starts)", where, tostring(reason), what, self.radius, #starts)
        return nil
    end
    local st = plan.start
    local route = {}
    for k = 1, st.index do
        route[k] = path[k]
    end
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, st.pose.x, 300, st.pose.z)
    route[#route + 1] = {x = st.pose.x, y = y, z = st.pose.z, isManoeuvrePoint = true,
                         endManoeuvre = {legs = plan.legs, target = target, targetId = targetId, side = side, reference = reference, geo = geo, text = plan.text}}
    local last = {}
    for key, value in pairs(P) do
        last[key] = value
    end
    route[#route + 1] = last
    self:log("%s: manoeuvre %.0f m before it: %s (about %.0f s, %s, radius %.1f m, %d tried, %d checks)", where, st.back, plan.text, plan.time, what,
        self.radius * ADCornerModule.EM_RADIUS_MARGIN, plan.tested, plan.checks)
    return route, plan.time
end

------------------------------------------------------------------------------------------------
-- manoeuvre: backing up before a bend (called from followWaypoints, returns true while this module drives)
------------------------------------------------------------------------------------------------
function ADCornerModule:isControlling()
    return self.reversing or self.endRun ~= nil
end

function ADCornerModule:stopReversing()
    if self.reversing then
        self.reversing = false
        if self.vehicle.ad ~= nil and self.vehicle.ad.specialDrivingModule ~= nil then
            self.vehicle.ad.specialDrivingModule:reset()
        end
    end
end

function ADCornerModule:reset()
    self:stopReversing()
    self:stopEndManoeuvre()
end

function ADCornerModule:handle(dt)
    local dpm = self.vehicle.ad.drivePathModule
    local wp = dpm:getCurrentWayPoint()
    if wp ~= nil and wp.endManoeuvre ~= nil and not wp.endManoeuvreDone then
        return self:driveEndManoeuvre(dt, wp)
    end
    self:stopEndManoeuvre()
    if wp == nil or wp.cornerReverse == nil or wp.cornerReverseDone then
        self:stopReversing()
        return false
    end
    local r = wp.cornerReverse
    local sdm = self.vehicle.ad.specialDrivingModule
    if not self.reversing then
        self.reversing = true
        self.backTimer:timer(false)
        self.rearBlockedTimer:timer(false)
        sdm:reset()
        local tx, tz = r.gx - r.hx * (r.distance + 100), r.gz - r.hz * (r.distance + 100)
        self.reverseTarget = {x = tx, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, tx, 300, tz), z = tz}
        self:log("manoeuvre: backing up %.0f m before the bend", r.distance)
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local back = (r.gx - x) * r.hx + (r.gz - z) * r.hz
    local timedOut = self.backTimer:timer(true, ADCornerModule.REVERSE_TIMEOUT, dt)
    local cdm = self.vehicle.ad.collisionDetectionModule
    local rearBlocked = cdm ~= nil and cdm.checkReverseCollision ~= nil and cdm:checkReverseCollision() == true
    local rearStop = self.rearBlockedTimer:timer(rearBlocked, ADCornerModule.REAR_BLOCKED_TIME, dt)
    if back >= r.distance - 0.5 or rearStop or timedOut then
        self:log("manoeuvre: backed up %.1f m (rear blocked %s, timeout %s), taking the bend", back, tostring(rearStop), tostring(timedOut))
        wp.cornerReverseDone = true
        self:stopReversing()
        dpm:switchToNextWayPoint()
        return false
    end
    if rearBlocked then
        sdm:stopAndHoldVehicle(dt)
        return true
    end
    sdm:releaseVehicle()
    if self.vehicle.startMotor ~= nil and not self.vehicle:getIsMotorStarted() and self.vehicle:getCanMotorRun() then
        self.vehicle:startMotor()
    end
    sdm:reverseToTargetLocation(dt, self.reverseTarget, ADCornerModule.REVERSE_SPEED)
    return true
end

------------------------------------------------------------------------------------------------
-- driving the manoeuvre at the end of the route (current waypoint: the manoeuvre point, the destination after it)
------------------------------------------------------------------------------------------------
function ADCornerModule:stopEndManoeuvre()
    if self.endRun ~= nil then
        self.endRun = nil
        if self.vehicle.ad ~= nil and self.vehicle.ad.specialDrivingModule ~= nil then
            self.vehicle.ad.specialDrivingModule:reset()
        end
    end
end

function ADCornerModule:driveEndManoeuvre(dt, wp)
    local m = wp.endManoeuvre
    local sdm = self.vehicle.ad.specialDrivingModule
    local run = self.endRun
    if run == nil or run.wp ~= wp then
        run = {wp = wp, legs = m.legs, legIndex = 1, pointIndex = 1, pause = 0, stillTime = 0, time = 0, wait = 0, replans = 0}
        self.endRun = run
        sdm:reset()
        self:log("end manoeuvre: %s", tostring(m.text))
    end
    if run.time > ADCornerModule.EM_TIMEOUT then
        return self:failEndManoeuvre(dt, wp, "too long")
    end
    local leg = run.legs[run.legIndex]
    -- a vehicle in the way while driving forward (the plan does not see vehicles): wait for it
    if leg ~= nil and leg.dir > 0 and run.pause <= 0 then
        local cdm = self.vehicle.ad.collisionDetectionModule
        if cdm ~= nil and cdm.detectObstacle ~= nil and cdm:detectObstacle() then
            run.wait = run.wait + dt
            if run.wait > ADCornerModule.EM_WAIT_MAX then
                return self:failEndManoeuvre(dt, wp, "vehicle in the way")
            end
            sdm:stopVehicle()
            sdm:update(dt)
            run.stillPos = nil
            return true
        end
    end
    run.time = run.time + dt
    local state = leg ~= nil and ADBandTurn.driveLeg(self.vehicle, run, dt) or "done"
    if state == "running" then
        return true
    end
    if state ~= "done" then
        if run.replans < ADCornerModule.EM_REPLANS and self:replanEndManoeuvre(run, m, state) then
            sdm:stopVehicle()
            sdm:update(dt)
            return true
        end
        return self:failEndManoeuvre(dt, wp, state)
    end
    run.legIndex = run.legIndex + 1
    run.pointIndex, run.pause, run.stillTime, run.stillPos = 1, ADBandTurn.LEG_PAUSE, 0, nil
    if run.legIndex <= #run.legs then
        return true
    end
    self:log("end manoeuvre done in %.0f s", run.time / 1000)
    wp.endManoeuvreDone = true
    self:stopEndManoeuvre()
    self.vehicle.ad.drivePathModule:switchToNextWayPoint()
    return true
end

-- off the planned line or held: a new plan from where the train stands, same destination
function ADCornerModule:replanEndManoeuvre(run, m, why)
    run.replans = run.replans + 1
    local node = self.vehicle.getAIDirectionNode ~= nil and self.vehicle:getAIDirectionNode() or self.vehicle.components[1].node
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local saved = self.geo
    self.geo = m.geo
    local pose = self:straightPose(x, z, headingOf(dx, dz))
    if m.geo.trailer > 0 then
        local reverseNode = self.vehicle.ad.specialDrivingModule:getReverseNode()
        if reverseNode ~= nil then
            pose.tx, _, pose.tz = getWorldTranslation(reverseNode)
        end
    end
    local plan, reason = self:planManoeuvre({{pose = pose, index = 0, leadLength = 0, approach = 0, back = 0}}, m.target, m.side, m.reference)
    self.geo = saved
    if plan == nil then
        self:log("end manoeuvre: %s, no new plan from here (%s)", tostring(why), tostring(reason))
        return false
    end
    run.legs, run.legIndex, run.pointIndex, run.pause, run.stillTime, run.stillPos, run.loggedLeg = plan.legs, 1, 1, ADBandTurn.LEG_PAUSE, 0, nil, nil
    self:log("end manoeuvre: %s, planned again from here: %s", tostring(why), plan.text)
    return true
end

-- given up: this destination is reached by the other way in for a while, the route is computed again from here
function ADCornerModule:failEndManoeuvre(dt, wp, why)
    local m = wp.endManoeuvre
    self:log("end manoeuvre given up (%s), route computed again (other way in)", tostring(why))
    ADCornerModule.endFailed[m.targetId] = nowMs()
    wp.endManoeuvreDone = true
    self:stopEndManoeuvre()
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm:stopVehicle()
    sdm:update(dt)
    self.vehicle.ad.drivePathModule:setPathTo(m.targetId)
    return true
end
