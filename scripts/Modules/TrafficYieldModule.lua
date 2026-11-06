--[[
    ADTrafficYieldModule
    --------------------
    Resolves head-on deadlocks between two AutoDrive vehicles on two-way roads.

    Situation: two AD vehicles meet face to face on a dual road. Both detect each other with
    their collision sensors and stop forever (detectAdTrafficOnRoute() is skipped on dual roads).

    Resolution:
      1. After both vehicles are blocked for <trafficYieldDelay> seconds, a shared plan is created.
      2. Roles are chosen deterministically (same result whichever vehicle detects first):
           - REVERSER : the vehicle easiest to reverse (empty first, then no trailer, then lowest id).
                        It backs up along its own route to make room.
           - PARKER   : the other vehicle. It searches a free spot on the roadside (right side first,
                        then left), drives into it and waits.
      3. Once the parker is parked, the reverser drives on and passes. When it has passed,
         the parker returns to its route.
    Everything runs on the server (AutoDrive:onUpdate is server side), so it is multiplayer safe.
]]

ADTrafficYieldModule = {}

ADTrafficYieldModule.DEBUG = true -- temporary diagnostic logs for the tests

function ADTrafficYieldModule:log(text, ...)
    if ADTrafficYieldModule.DEBUG then
        print(string.format("[AD-Yield] %s (%s) [%s]: " .. text, ADTrafficYieldModule.getName(self.vehicle), tostring(self.vehicle.id),
            ADTrafficYieldModule.STATE_NAMES[self.state] or tostring(self.state), ...))
    end
end

ADTrafficYieldModule.STATE_IDLE = 0
ADTrafficYieldModule.STATE_REVERSER_RETREAT = 1
ADTrafficYieldModule.STATE_REVERSER_WAIT = 2
ADTrafficYieldModule.STATE_REVERSER_PASS = 3
ADTrafficYieldModule.STATE_REVERSER_BRANCH = 4
ADTrafficYieldModule.STATE_REVERSER_HIDE = 5
ADTrafficYieldModule.STATE_PARKER_SEARCH = 11
ADTrafficYieldModule.STATE_PARKER_MOVE = 12
ADTrafficYieldModule.STATE_PARKER_WAIT = 13
ADTrafficYieldModule.STATE_PARKER_PASS = 14
ADTrafficYieldModule.STATE_YIELDER_APPROACH = 21
ADTrafficYieldModule.STATE_PRIORITY_APPROACH = 22
ADTrafficYieldModule.STATE_WAIT_DETACHED = 31
-- gap between two vehicles of the same oncoming queue (rear of one to the front of the next)
ADTrafficYieldModule.QUEUE_GAP = 40
ADTrafficYieldModule.STATE_SECTION_CLEAR = 41

ADTrafficYieldModule.STATE_NAMES = {
    [0] = "IDLE",
    [1] = "REVERSER_RETREAT",
    [2] = "REVERSER_WAIT",
    [3] = "REVERSER_PASS",
    [4] = "REVERSER_BRANCH",
    [5] = "REVERSER_HIDE",
    [11] = "PARKER_SEARCH",
    [12] = "PARKER_MOVE",
    [13] = "PARKER_WAIT",
    [14] = "PARKER_PASS",
    [21] = "YIELDER_APPROACH",
    [22] = "PRIORITY_APPROACH",
    [31] = "WAIT_DETACHED",
    [41] = "SECTION_CLEAR"
}

ADTrafficYieldModule.ANTICIPATION_DISTANCE = 250 -- m of route looked ahead to find an oncoming AD vehicle
ADTrafficYieldModule.ANTICIPATION_INTERVAL = 250 -- ms between two route comparisons
ADTrafficYieldModule.ANTICIPATION_DECEL = 1.2    -- m/s2 comfortable deceleration used to compute the speed limit
ADTrafficYieldModule.ANTICIPATION_GAP = 10       -- m free between both fronts when stopped
ADTrafficYieldModule.ANTICIPATION_START_DELAY = 1500 -- ms both stopped before the manoeuvre starts
ADTrafficYieldModule.PLAN_TIMEOUT = 180000      -- ms, whole manoeuvre
ADTrafficYieldModule.COOLDOWN = 20000           -- ms, no new detection after a plan ended
ADTrafficYieldModule.PATH_STEP = 2               -- m between two points of the parallel path
ADTrafficYieldModule.PATH_EXTRA = 8              -- m of parallel path after the parking point (alignment, aim)
ADTrafficYieldModule.CANDIDATE_STEP = 5          -- m between two leaving points tested along the route
ADTrafficYieldModule.SECTION_WAIT_CLEAR = 15     -- m kept free before the start of a single track when the yielder waits there (owner 25/10 19:01)
ADTrafficYieldModule.SECTION_BACKOFF_MAX = 50    -- m, longest reverse of a yielder already in the mouth of the single track (owner 25/10 21:20)
ADTrafficYieldModule.JUNCTION_GAP = 5           -- m between my front and the node where my route leaves the road, when I wait before the turn-off (owner 26/10 17:23)
ADTrafficYieldModule.SECTION_BACKOFF_MIN = 6     -- m, a back-off stopped before (vehicle queue behind) falls back to the standard manoeuvre
ADTrafficYieldModule.SECTION_CLEAR_MAX = 150     -- m, longest reverse of the vehicle in the single track that gives way to one stuck in the mouth
ADTrafficYieldModule.SECTION_BACKOFF_INSIDE = 8  -- m, front already this far inside the single track: too deep, no back-off
ADTrafficYieldModule.YIELDER_STOPPED_FALLBACK = 10000 -- ms stopped without a spot nor a hold of its own: standard manoeuvre
ADTrafficYieldModule.YIELDER_SHARE = 0.65        -- part of the free distance given to the vehicle that pulls over
ADTrafficYieldModule.DETOUR_MAX = 400            -- m, longest detour taken to avoid meeting an oncoming vehicle
ADTrafficYieldModule.DETOUR_MIN_AHEAD = 5        -- m, the detour must leave the route before the head-on section (27/10: 15 m refused the 7R 350 at 13 m of the junction)
ADTrafficYieldModule.DETOUR_PENALTY = 1000000    -- added weight of the head-on section waypoints when looking for a detour
ADTrafficYieldModule.SPOT_CLEARANCE = 6          -- m kept free between the oncoming vehicle and the end of the roadside path
ADTrafficYieldModule.COOLDOWN_SUCCESS = 3000    -- ms, after a successful plan (another conflict may follow at once)
ADTrafficYieldModule.GIVE_UP_TIME = 300000      -- ms, after two failed attempts the pair is left alone this long
ADTrafficYieldModule.HISTORY_TIMEOUT = 600000   -- ms, a failure older than this is forgotten
-- owner 27/10 20:19-20:23 (942 Vario + header trailer waiting 11 m before the turn-off, the 7R 350 + Big Body coming out
-- of the single track drove into it, the plan ended "partner out" too early, the 942 reversed, its trailer swung against
-- the shed and nothing moved for 3 min), go 28/10:
ADTrafficYieldModule.EXIT_ROOM = 10              -- S1: m added to the length of the train coming out, between the junction and my front
ADTrafficYieldModule.REVERSE_STUCK_MS = 10000    -- S3: ms reversing without moving REVERSE_STUCK_M: stuck, even if the rear sensor sees nothing
ADTrafficYieldModule.REVERSE_STUCK_M = 1
ADTrafficYieldModule.PLAN_STUCK_MS = 90000       -- S3: ms without any of both moving PLAN_STUCK_M: the roles are swapped
ADTrafficYieldModule.PLAN_STUCK_M = 2
ADTrafficYieldModule.S4_MIN_SPEED = 12         -- km/h counted for a slow or stopped vehicle (it restarts)
ADTrafficYieldModule.S6_LOOK_AHEAD = 400       -- m of the partner's route searched for the entrance point it still has to pass
ADTrafficYieldModule.SPOT_MOUTH_CLEAR = 25     -- m: no roadside spot this close to the mouth of a single track (owner 28/10 18:15: 25 m)
ADTrafficYieldModule.SPOT_PASS_MARGIN = 0.5    -- m between a parked train and the other train passing beside it
-- owner 30/10 16:29-16:37 (MF 7S.210 + Cargos 750 parked in a bend, trailer still across the road, the 8510 let through at once):
-- the trailer follows its hitch (it cuts inside the bend), not the path
ADTrafficYieldModule.TOW_STEP = 0.5             -- m of tractor travel per step of the trailer simulation
ADTrafficYieldModule.TOW_EXTRA = 30             -- m added to the roadside path when the trailer is not off the road at its end
ADTrafficYieldModule.TOW_ROAD_TOLERANCE = 0.6   -- m: the trailer is off the road once its rear and centre are this close to the full offset
ADTrafficYieldModule.PASS_GAP = 10              -- m kept by the other train while the parked one finishes lining up
-- owner 30/10 16:59-17:04 (942 Vario + Bergmann parked twice for the 7R 350, nose against the railing of the bridge, stuck)
ADTrafficYieldModule.PASSED_ROUTE_WIDTH = 8     -- m: a vehicle this close to my route ahead of me is not passed yet
ADTrafficYieldModule.PARK_TRACE_TTL = 300000    -- ms the roadside path driven stays known (way back to the route)
ADTrafficYieldModule.REJOIN_STUCK_MS = 3000     -- ms stopped with an obstacle against the nose, off my route, before backing out
ADTrafficYieldModule.REJOIN_TIMEOUT = 60000     -- ms at most for backing out along the roadside path
ADTrafficYieldModule.ENTRY_INSIDE = 3           -- m past the start of the two-way track before a vehicle counts as inside
-- owner 28/10 18:11-18:29, traffic rules of the two-way track (go 18:29):
ADTrafficYieldModule.EXIT_PRIORITY_DISTANCE = 120 -- m from the one in the two-way track to its exit: closer, the one on the road waits before entering
ADTrafficYieldModule.REVERSE_SEARCH_MAX = 70      -- m reversed at most while looking for a spot behind (18:22: "on peut aller a 70 m")
ADTrafficYieldModule.DETOUR_ROAD_SPEED = 25       -- km/h at least counted on a detour (time lost by a detour against time lost waiting)
ADTrafficYieldModule.RADIUS_TIE = 0.5             -- m: turning radii of both trains closer than this are a tie (the shorter train parks)
ADTrafficYieldModule.MANOEUVRE_TIE = 15           -- deg: reverse manoeuvres closer than this are a tie (the shorter reverse decides)
ADTrafficYieldModule.RED_LINE_BEFORE_TRACK = 40   -- m: a red section ending this close before the two-way track is its crossing

-- failed attempts per pair of vehicles: key "idA-idB" -> {failures, time}
ADTrafficYieldModule.pairHistory = {}
ADTrafficYieldModule.SEARCH_INTERVAL = 500      -- ms between two roadside searches
ADTrafficYieldModule.MAX_DETECTION_DISTANCE = 45 -- m between the two vehicle centres
ADTrafficYieldModule.REVERSE_STEP = 5           -- m between two reverse targets
ADTrafficYieldModule.REVERSE_SPEED = 7          -- km/h
ADTrafficYieldModule.PARK_SPEED = 7             -- km/h
ADTrafficYieldModule.LATERAL_MARGIN = 0.6       -- m free space between the two vehicles when passing
ADTrafficYieldModule.MAX_SLOPE_DIFF = 1.2       -- m height difference allowed inside the parking footprint
-- map collision shapes that never block a vehicle in practice (field border collisions of the maps)
ADTrafficYieldModule.IGNORED_SHAPE_NAMES = {
    borderCol = true
}
ADTrafficYieldModule.MAX_ROAD_HEIGHT_DIFF = 1.0 -- m height difference allowed between road and parking spot

function ADTrafficYieldModule:new(vehicle)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.vehicle = vehicle
    o.blockedTimer = AutoDriveTON:new()
    o.rejoinTimer = AutoDriveTON:new()
    ADTrafficYieldModule.reset(o)
    o.cooldownUntil = 0
    return o
end

function ADTrafficYieldModule:reset()
    self.state = ADTrafficYieldModule.STATE_IDLE
    self.plan = nil
    self.partner = nil
    self.reverseTargets = nil
    self.reverseTargetIndex = 0
    self.reverseStart = nil
    self.escapeBranch = nil
    self.branchTargetIndex = 0
    self.reachedRouteIndex = nil
    self.pathIndex = nil
    self.reverseBlockedTimer = AutoDriveTON:new()
    self.stateTimer = AutoDriveTON:new()
    self.yielderStoppedTimer = AutoDriveTON:new()
    self.noOncomingTimer = AutoDriveTON:new()
    self.lastSearchTime = 0
    self.alignmentDone = nil
    self.alignmentTime = 0
    self.reverseProgress = nil
    self.comingAtMeLogged = nil
    self.blockedTimer:timer(false)
end

------------------------------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------------------------------

function ADTrafficYieldModule.getName(vehicle)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
        return vehicle.ad.stateModule:getName()
    end
    return "?"
end

-- side used when pulling over: the driving side only (never against the traffic; without a free spot on that
-- side, the vehicle reverses or the other one pulls over instead).
-- Local +x is left in GIANTS, so right is negative x. Setting trafficYieldDriveSide: 1 = right-hand traffic, 2 = left-hand
function ADTrafficYieldModule.getSides()
    if AutoDrive.getSetting("trafficYieldDriveSide") == 2 then
        return {{name = "left", sign = 1}}
    end
    return {{name = "right", sign = -1}}
end

-- straight run along the roadside after the swerve, for the towed units to line up behind the tractor:
-- a trailer only converges onto the tractor's track after about twice its own length
function ADTrafficYieldModule.getRunOut(trailLength)
    if trailLength <= 0 then
        return 2
    end
    return trailLength * 2 + 4
end

function ADTrafficYieldModule.isEnabled()
    return AutoDrive.getSetting("trafficYieldEnabled") == true or AutoDrive.getSetting("trafficYieldEnabled") == 1
end

function ADTrafficYieldModule.getPosition(vehicle)
    return getWorldTranslation(vehicle.components[1].node)
end

function ADTrafficYieldModule.getDirection(vehicle)
    local dx, _, dz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local length = MathUtil.vector2Length(dx, dz)
    if length < 0.0001 then
        return 0, 1
    end
    return dx / length, dz / length
end

function ADTrafficYieldModule.getSpeedKmh(vehicle)
    return math.abs(vehicle.lastSpeedReal or 0) * 3600
end

-- measures the real dimensions of every unit of the train in its current (transport) state, with the
-- AutoDrive dimension sensor; done once when a plan starts, the results are cached in vehicle.ad.adDimensions
function ADTrafficYieldModule.measureTrain(vehicle)
    local ok = pcall(function()
        AutoDrive.getAllVehicleDimensions(vehicle, true)
    end)
    if not ok then
        Logging.error("[AD] ADTrafficYieldModule: could not measure the dimensions of %s", ADTrafficYieldModule.getName(vehicle))
    end
end

-- real width / length of one unit: measured values when available, otherwise the vehicle xml values
function ADTrafficYieldModule.getUnitDimensions(unit)
    local width = (unit.size ~= nil and unit.size.width) or 3
    local length = (unit.size ~= nil and unit.size.length) or 5
    local dims = unit.ad ~= nil and unit.ad.adDimensions or nil
    if dims ~= nil then
        if dims.maxWidthLeft ~= nil and dims.maxWidthRight ~= nil and (dims.maxWidthLeft + dims.maxWidthRight) > 0.5 then
            width = dims.maxWidthLeft + dims.maxWidthRight
        elseif dims.width ~= nil and dims.width > 0.5 then
            width = dims.width
        end
        if dims.maxLengthFront ~= nil and dims.maxLengthBack ~= nil and (dims.maxLengthFront + dims.maxLengthBack) > 0.5 then
            length = dims.maxLengthFront + dims.maxLengthBack
        elseif dims.length ~= nil and dims.length > 0.5 then
            length = dims.length
        end
    end
    return width, length
end

-- widest unit of the train (tractor, front / rear implements, trailers)
function ADTrafficYieldModule.getWidth(vehicle)
    local maxWidth = ADTrafficYieldModule.getUnitDimensions(vehicle)
    local units, _ = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            local width = ADTrafficYieldModule.getUnitDimensions(unit)
            maxWidth = math.max(maxWidth, width)
        end
    end
    return math.min(maxWidth, 8)
end

-- distances from the vehicle origin to the front-most and rear-most points of the train
-- (front implements included, e.g. a front cultivator or a front weight)
function ADTrafficYieldModule.getTrainExtents(vehicle)
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(vehicle)
    local front, rear = tractorLength / 2, tractorLength / 2
    local units, _ = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit ~= vehicle and unit.components ~= nil then
                local _, unitLength = ADTrafficYieldModule.getUnitDimensions(unit)
                local ux, uy, uz = getWorldTranslation(unit.components[1].node)
                local _, _, localZ = AutoDrive.worldToLocal(vehicle, ux, uy, uz)
                front = math.max(front, localZ + unitLength / 2)
                rear = math.max(rear, -(localZ - unitLength / 2))
            end
        end
    end
    return front, rear
end

-- length of the whole train (sum of all units)
function ADTrafficYieldModule.getTotalLength(vehicle)
    local length = 0
    local units, count = AutoDrive.getAllUnits(vehicle)
    if units ~= nil and count ~= nil and count > 0 then
        for _, unit in pairs(units) do
            local _, unitLength = ADTrafficYieldModule.getUnitDimensions(unit)
            length = length + unitLength
        end
    end
    if length <= 0 then
        local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(vehicle)
        length = tractorLength
    end
    return length
end

function ADTrafficYieldModule.hasTrailer(vehicle)
    local _, trailerCount = AutoDrive.getAllUnits(vehicle)
    return trailerCount ~= nil and trailerCount > 1
end

function ADTrafficYieldModule.isLoaded(vehicle)
    local trailers, _ = AutoDrive.getAllUnits(vehicle)
    if trailers == nil or #trailers == 0 then
        return false
    end
    local fillLevel, fillCapacity = AutoDrive.getAllFillLevels(trailers)
    if fillCapacity == nil or fillCapacity <= 0 then
        return false
    end
    return (fillLevel / fillCapacity) > 0.1
end

-- the lower the score, the more the vehicle should be the one reversing
function ADTrafficYieldModule.getPriorityScore(vehicle)
    local score = 0
    if ADTrafficYieldModule.isLoaded(vehicle) then
        score = score + 2
    end
    if ADTrafficYieldModule.hasTrailer(vehicle) then
        score = score + 1
    end
    return score
end

-- reverse distance of the standard manoeuvre: the AutoDrive setting, at least REVERSE_SEARCH_MAX (owner 28/10 18:22)
function ADTrafficYieldModule.getMaxReverse()
    return math.max(AutoDrive.getSetting("trafficYieldMaxReverse") or 50, ADTrafficYieldModule.REVERSE_SEARCH_MAX)
end

-- a unit pulled on its own wheels behind its attacher (trailer, dolly, trailed implement), not a mounted implement
function ADTrafficYieldModule.isTowedUnit(root, unit)
    if unit == nil or unit == root or unit.spec_attachable == nil then
        return false
    end
    if AutoDrive.isImplementAllowedForReverseDriving ~= nil then
        local ok, towed = pcall(AutoDrive.isImplementAllowedForReverseDriving, root, unit)
        if ok and towed then
            return true
        end
    end
    return string.find(string.lower(tostring(unit.typeName or "")), "trailer", 1, true) ~= nil
end

-- front axle pivoting with the drawbar (turntable): a component joint turning around the vertical axis only
-- (AutoDrive locks it while reversing, ADTrailerModule keeps the original limit in unit.ad.rotLimitBackup)
function ADTrafficYieldModule.hasPivotingFrontAxle(unit)
    if unit.ad ~= nil and unit.ad.rotLimitBackup ~= nil and math.abs(unit.ad.rotLimitBackup) > math.rad(5) then
        return true
    end
    if unit.components == nil or #unit.components < 2 or unit.componentJoints == nil then
        return false
    end
    for _, joint in pairs(unit.componentJoints) do
        local limit = joint.rotLimit
        if limit ~= nil and limit[2] ~= nil and math.abs(limit[2]) > math.rad(5)
            and math.abs(limit[1] or 0) <= math.abs(limit[2]) / 2 and math.abs(limit[3] or 0) <= math.abs(limit[2]) / 2 then
            return true
        end
    end
    return false
end

-- owner 28/10 18:20-18:26 ("la remorque d'ensilage peut reculer, mais pas une remorque articulee", "c bien ca"): an
-- articulated train never reverses: front axle pivoting with the drawbar (two-axle turntable tipper, header trailer),
-- a trailer on a dolly, or two trailers in a row; a single rigid trailer (silage trailer) reverses.
-- A1 (27/10): a header carried on a trailer. Returns true, the name of the unit and what it is
ADTrafficYieldModule.ARTICULATED_FR = {header = "remorque de coupe", dolly = "dolly", two = "deux remorques a la suite", turntable = "avant-train pivotant"}
function ADTrafficYieldModule.cannotReverse(vehicle)
    if vehicle == nil or vehicle.getRootVehicle == nil then
        return false
    end
    local root = vehicle:getRootVehicle()
    if root == nil then
        return false
    end
    local children = root.childVehicles
    if children == nil and root.getChildVehicles ~= nil then
        children = root:getChildVehicles()
    end
    if children == nil then
        return false
    end
    for _, unit in pairs(children) do
        if unit ~= root then
            local typeName = string.lower(tostring(unit.typeName or ""))
            local name = (unit.getFullName ~= nil and unit:getFullName()) or typeName
            local attacher = unit.getAttacherVehicle ~= nil and unit:getAttacherVehicle() or nil
            -- a harvester with its own header reverses normally
            if root.spec_combine == nil and (unit.spec_cutter ~= nil or string.find(typeName, "cutter", 1, true) ~= nil) then
                if attacher ~= root or string.find(typeName, "trailer", 1, true) ~= nil then
                    return true, name, "header"
                end
            end
            if ADTrafficYieldModule.isTowedUnit(root, unit) then
                if string.find(typeName, "dolly", 1, true) ~= nil then
                    return true, name, "dolly"
                end
                if attacher ~= nil and attacher ~= root and ADTrafficYieldModule.isTowedUnit(root, attacher) then
                    return true, name, "two"
                end
                if ADTrafficYieldModule.hasPivotingFrontAxle(unit) then
                    return true, name, "turntable"
                end
            end
        end
    end
    return false
end

-- text of the articulated unit for the log: "avant-train pivotant (name)"
function ADTrafficYieldModule.describeArticulated(vehicle)
    local articulated, name, kind = ADTrafficYieldModule.cannotReverse(vehicle)
    if not articulated then
        return nil
    end
    return string.format("%s (%s)", ADTrafficYieldModule.ARTICULATED_FR[kind] or tostring(kind), tostring(name))
end

-- owner 28/10 18:11 / 18:22 ("le plus manoeuvrant, avec un rayon de braquage plus petit", "attelage complet"): turning
-- radius of the whole train: the radius of the tractor (vehicle file or steering geometry, as ADCornerModule) plus what
-- the towed units cut inside its arc (towed length squared / twice the radius)
function ADTrafficYieldModule.getTrainRadius(vehicle)
    local fileRadius = AutoDrive.getDriverRadius ~= nil and AutoDrive.getDriverRadius(vehicle, true) or 0
    local wheelRadius = ADCornerModule ~= nil and ADCornerModule.getWheelRadius ~= nil and ADCornerModule.getWheelRadius(vehicle) or nil
    local radius = math.max(fileRadius or 0, wheelRadius or 0)
    if radius < 3 then
        radius = 6
    end
    radius = math.min(radius, 14)
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(vehicle)
    local towed = math.max(0, ADTrafficYieldModule.getTotalLength(vehicle) - tractorLength)
    return radius + towed * towed / (2 * radius), radius, towed
end

-- owner 28/10 18:16 ("recule celui qui manoeuvrera le moins, meme si plus long"): the reverse a vehicle would have to drive
-- along its own route to get out of the two-way track (up to SECTION_CLEAR_MAX m, plus its length once out of it): the
-- sum of the turns of that path (degrees), counted double with a trailer, and its length
function ADTrafficYieldModule.getReverseManoeuvre(vehicle)
    local trailer = ADTrafficYieldModule.hasTrailer(vehicle)
    local result = {angle = 0, length = 0, trailer = trailer, score = 0}
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return result
    end
    local x, _, z = ADTrafficYieldModule.getPosition(vehicle)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(vehicle)
    local heading = math.atan2(-dirX, -dirZ)
    local lastX, lastZ = x, z
    local outLength = nil
    local trainLength = ADTrafficYieldModule.getTotalLength(vehicle)
    for i = currentIndex - 1, 1, -1 do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        local d = MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        if d > 0.5 then
            local h = math.atan2(wp.x - lastX, wp.z - lastZ)
            local turn = h - heading
            while turn > math.pi do
                turn = turn - 2 * math.pi
            end
            while turn < -math.pi do
                turn = turn + 2 * math.pi
            end
            result.angle = result.angle + math.abs(math.deg(turn))
            result.length = result.length + d
            heading = h
            lastX, lastZ = wp.x, wp.z
        end
        local nextWp = wayPoints[i + 1]
        if outLength == nil and (wp.id == nil or nextWp == nil or nextWp.id == nil or not ADTrafficYieldModule.isTwoWay(wp.id, nextWp.id)) then
            outLength = result.length -- out of the two-way track: its length more
        end
        if outLength ~= nil and result.length >= outLength + trainLength then
            break
        end
        if result.length >= ADTrafficYieldModule.SECTION_CLEAR_MAX then
            -- still in the two-way track after the longest reverse: I cannot clear the way backwards
            result.tooLong = outLength == nil
            break
        end
    end
    result.score = result.angle * (trailer and 2 or 1)
    if result.tooLong then
        result.score = result.score + 100000 -- the other one reverses when it can get out
    end
    -- something right behind me (a car, a wall): I cannot reverse at all
    if vehicle.ad.collisionDetectionModule ~= nil and vehicle.ad.collisionDetectionModule:checkReverseCollision() then
        result.blocked = true
        result.score = math.huge
    end
    return result
end

-- A1: logged once per plan and vehicle
function ADTrafficYieldModule:logCannotReverse(other)
    local plan = self.plan
    if plan ~= nil then
        plan.a1Logged = plan.a1Logged or {}
        if plan.a1Logged[self.vehicle] then
            return
        end
        plan.a1Logged[self.vehicle] = true
    end
    local what = ADTrafficYieldModule.describeArticulated(self.vehicle)
    self:log("articulated train (%s): I never reverse, %s reverses", tostring(what), ADTrafficYieldModule.getName(other))
    print(string.format("[AD-Croise] %s: remorque articulee, %s, je ne recule pas : %s recule", ADTrafficYieldModule.getName(self.vehicle), tostring(what),
        ADTrafficYieldModule.getName(other)))
end

-- S3: asked to reverse, I have not moved REVERSE_STUCK_M in REVERSE_STUCK_MS (trailer jackknifed against a wall, soft
-- ground, object the rear sensor does not see). Call it every frame while reversing
function ADTrafficYieldModule:isReverseStuck()
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local p = self.reverseProgress
    if p == nil or g_time - p.lastSeen > 1000 then
        self.reverseProgress = {x = x, z = z, time = g_time, lastSeen = g_time}
        return false
    end
    p.lastSeen = g_time
    if MathUtil.vector2Length(x - p.x, z - p.z) >= ADTrafficYieldModule.REVERSE_STUCK_M then
        p.x, p.z, p.time = x, z, g_time
        return false
    end
    if g_time - p.time >= ADTrafficYieldModule.REVERSE_STUCK_MS then
        if not p.logged then
            p.logged = true
            self:log("I do not move backwards (less than %d m in %d s): stuck", ADTrafficYieldModule.REVERSE_STUCK_M, ADTrafficYieldModule.REVERSE_STUCK_MS / 1000)
            print(string.format("[AD-Croise] %s: je n'arrive pas a reculer (moins de %d m en %d s), je m'arrete la", ADTrafficYieldModule.getName(self.vehicle),
                ADTrafficYieldModule.REVERSE_STUCK_M, ADTrafficYieldModule.REVERSE_STUCK_MS / 1000))
        end
        return true
    end
    return false
end

-- S2 (owner 27/10 20:20): the partner is not done with me while its next metres run over my train (network lanes
-- included: the 7R 350 came out of the single track on other nodes and drove on into the 942 Vario), or, with routeOnly
-- false, while it drives straight at me
function ADTrafficYieldModule:isPartnerComingAtMe(routeOnly)
    local partner = self.partner
    if partner == nil or partner.ad == nil or partner.ad.drivePathModule == nil then
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local px, _, pz = ADTrafficYieldModule.getPosition(partner)
    local dist = MathUtil.vector2Length(px - x, pz - z)
    if dist > 80 then
        return false
    end
    local dirX, dirZ = ADTrafficYieldModule.getDirection(self.vehicle)
    local myFront, myRear = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local needed = (ADTrafficYieldModule.getWidth(self.vehicle) + ADTrafficYieldModule.getWidth(partner)) / 2
    local wayPoints, currentIndex = partner.ad.drivePathModule:getWayPoints()
    if wayPoints ~= nil and currentIndex ~= nil then
        local line = {{x = px, z = pz}}
        local distance = 0
        for i = math.max(1, currentIndex), #wayPoints do
            local wp = wayPoints[i]
            if wp == nil then
                break
            end
            local last = line[#line]
            distance = distance + MathUtil.vector2Length(wp.x - last.x, wp.z - last.z)
            table.insert(line, {x = wp.x, z = wp.z})
            if distance > 60 then
                break
            end
        end
        if #line >= 2 then
            for _, f in ipairs({myFront, 0, -myRear}) do
                if ADTrafficYieldModule.distanceToPolyline(line, x + dirX * f, z + dirZ * f) < needed then
                    return true, "route"
                end
            end
        end
    end
    if not routeOnly and dist < 30 and ADTrafficYieldModule.getSpeedKmh(partner) > 1 then
        local pdx, pdz = ADTrafficYieldModule.getDirection(partner)
        for _, f in ipairs({myFront, 0, -myRear}) do
            local tx, tz = x + dirX * f, z + dirZ * f
            local ahead = (tx - px) * pdx + (tz - pz) * pdz
            local lateral = math.abs((tx - px) * pdz - (tz - pz) * pdx)
            if ahead > 0 and ahead < 30 and lateral < needed then
                return true, "heading"
            end
        end
    end
    return false
end

-- S3: the plan is stuck (or a reverser cannot reverse): end it and start the standard manoeuvre again with the roles
-- swapped (the pair history says who reversed last; A1 still applies; 2 failures = the pair is left alone)
function ADTrafficYieldModule:restartWithRolesSwapped(reason, reasonFr)
    local plan = self.plan
    local partner = self.partner
    local vehicle = self.vehicle
    local early = plan ~= nil and plan.mode == "early"
    self:log("%s: the roles are swapped", reason)
    print(string.format("[AD-Croise] %s: %s, %s", ADTrafficYieldModule.getName(vehicle), reasonFr,
        early and "fin du plan d'attente, manoeuvre classique ensuite" or ("j'inverse les roles avec " .. ADTrafficYieldModule.getName(partner))))
    self:endPlan(reason, false)
    if not early and ADTrafficYieldModule.isAdVehicleUsable(partner) and ADTrafficYieldModule.isAdVehicleUsable(vehicle) then
        ADTrafficYieldModule.startPlan(vehicle, partner)
    end
end

function ADTrafficYieldModule.isAdVehicleUsable(vehicle)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.components ~= nil and vehicle.ad.stateModule ~= nil
        and vehicle.ad.stateModule:isActive() and vehicle.ad.trafficYieldModule ~= nil and vehicle.ad.drivePathModule ~= nil
end

function ADTrafficYieldModule:isControlling()
    if self.rejoin ~= nil then
        return true
    end
    if self.state == ADTrafficYieldModule.STATE_YIELDER_APPROACH then
        -- backing off from the mouth of a single track or holding before it: the module drives (owner 26/10 17:23,
        -- the "stuck" safety of DrivePathModule reset the 7R 350 in the middle of its back-off)
        local plan = self.plan
        return plan ~= nil and (plan.sectionBackOff ~= nil or (plan.parked == true and not plan.straightOn))
    end
    return self.state ~= ADTrafficYieldModule.STATE_IDLE and self.state ~= ADTrafficYieldModule.STATE_REVERSER_PASS and self.state ~= ADTrafficYieldModule.STATE_PARKER_PASS
        and self.state ~= ADTrafficYieldModule.STATE_PRIORITY_APPROACH
end

function ADTrafficYieldModule:isBusy()
    return self.state ~= ADTrafficYieldModule.STATE_IDLE or g_time < self.cooldownUntil
end

function ADTrafficYieldModule:setState(newState)
    if newState ~= self.state then
        self:log("-> %s (partner %s)", ADTrafficYieldModule.STATE_NAMES[newState] or tostring(newState), ADTrafficYieldModule.getName(self.partner))
        local oldName = ADTrafficYieldModule.STATE_NAMES[self.state] or "?"
        self.state = newState
        self.stateTimer:timer(false)
    end
end

function ADTrafficYieldModule:ensureMotorStarted()
    if self.vehicle.startMotor ~= nil and not self.vehicle:getIsMotorStarted() and self.vehicle:getCanMotorRun() then
        self.vehicle:startMotor()
    end
end

function ADTrafficYieldModule:holdVehicle(dt)
    -- a planned hold, not a blocked vehicle: isBlocked would make the unloader mode think it is stuck
    -- after 10 s and reverse out of the road (CombineUnloaderMode:monitorTasks)
    self.vehicle.ad.specialDrivingModule:stopVehicle(false)
    self.vehicle.ad.specialDrivingModule:update(dt)
end

------------------------------------------------------------------------------------------------
-- entry point, called every frame from ADDrivePathModule:followWaypoints (server)
-- returns true when this module controls the vehicle for this frame
------------------------------------------------------------------------------------------------

-- my position is more than 'limit' m from my route (the segment I drive and the next ones)
function ADTrafficYieldModule:isOffMyRoute(limit)
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return false
    end
    local points = {}
    for i = math.max(1, currentIndex - 2), math.min(#wayPoints, currentIndex + 4) do
        if wayPoints[i] ~= nil then
            table.insert(points, {x = wayPoints[i].x, z = wayPoints[i].z})
        end
    end
    if #points < 2 then
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    return ADTrafficYieldModule.distanceToPolyline(points, x, z) > limit
end

-- owner 30/10 (D): off my route after pulling over, stopped with an obstacle against the nose (942 Vario against the railing of
-- the bridge, no lane beside it, no detour): I back out along the roadside path I drove, back onto my route, then drive on
-- Returns true while backing out
function ADTrafficYieldModule:updateRejoin(dt)
    local trace = self.parkTrace
    if trace == nil or g_time - trace.time > ADTrafficYieldModule.PARK_TRACE_TTL then
        self.parkTrace, self.rejoin = nil, nil
        return false
    end
    if self.rejoin == nil then
        if self.state ~= ADTrafficYieldModule.STATE_IDLE and self.state ~= ADTrafficYieldModule.STATE_REVERSER_PASS
            and self.state ~= ADTrafficYieldModule.STATE_PRIORITY_APPROACH and self.state ~= ADTrafficYieldModule.STATE_PARKER_PASS then
            self.rejoinTimer:timer(false)
            return false
        end
        local approach = self.vehicle.ad.approachModule
        local hit = approach ~= nil and approach.getHit ~= nil and approach:getHit() or nil
        local stuck = hit ~= nil and not hit.isVehicle and (hit.distance or math.huge) <= 1 and ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1
        if not self.rejoinTimer:timer(stuck, ADTrafficYieldModule.REJOIN_STUCK_MS, dt) then
            if not stuck and not self:isOffMyRoute(1.5) then
                self.parkTrace = nil -- back on my route: the trace is no longer needed
            end
            return false
        end
        self.rejoinTimer:timer(false)
        if not self:isOffMyRoute(1.5) then
            return false
        end
        if ADTrafficYieldModule.cannotReverse(self.vehicle) then
            self:log("blocked off my route, articulated trailer: I do not back out")
            self.parkTrace = nil
            return false
        end
        -- the path points behind me, nearest first, down to the start of the path (on the road)
        local path = trace.path
        local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
        local index, distance = ADTrafficYieldModule.getClosestPathIndex(path, x, z, 1)
        if distance > 4 then
            self:log("blocked off my route but %.1f m from my roadside path: no way back known", distance)
            self.parkTrace = nil
            return false
        end
        local targets = {}
        for k = index - 2, 1, -2 do
            table.insert(targets, {x = path[k].x, y = trace.spot.y or 0, z = path[k].z})
        end
        if #targets == 0 then
            return false
        end
        self.rejoin = {targets = targets, index = 1, startTime = g_time, name = tostring(hit.name)}
        self:log("blocked by '%s' off my route: backing out along my roadside path (%d points)", tostring(hit.name), #targets)
        print(string.format("[AD-Croise] %s: bloque par '%s' hors de mon trajet, je recule sur ma trace jusqu'a mon chemin",
            ADTrafficYieldModule.getName(self.vehicle), tostring(hit.name)))
    end
    local rejoin = self.rejoin
    if g_time - rejoin.startTime > ADTrafficYieldModule.REJOIN_TIMEOUT then
        self:log("backing out: timeout")
        print(string.format("[AD-Croise] %s: recul sur ma trace abandonne apres %d s", ADTrafficYieldModule.getName(self.vehicle), ADTrafficYieldModule.REJOIN_TIMEOUT / 1000))
        self.rejoin, self.parkTrace = nil, nil
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        return false
    end
    local target = rejoin.targets[rejoin.index]
    if self:reverseTowards(dt, target, 1.5) then
        rejoin.index = rejoin.index + 1
        if rejoin.index > #rejoin.targets or not self:isOffMyRoute(0.8) then
            self:log("back on my route")
            print(string.format("[AD-Croise] %s: revenu sur mon chemin, je repars", ADTrafficYieldModule.getName(self.vehicle)))
            self.rejoin, self.parkTrace = nil, nil
            self.vehicle.ad.specialDrivingModule:releaseVehicle()
            ADTrafficYieldModule.resyncWayPoints(self.vehicle)
            return false
        end
    end
    return true
end

function ADTrafficYieldModule:handle(dt, obstacleDetected)
    if not self.vehicle.isServer then
        return false
    end
    if self.parkTrace ~= nil and self:updateRejoin(dt) then
        return true
    end
    -- 26/10 (obstacles thread): the vehicle now stops 3 m behind an AD vehicle on its route, before the front sensors see it:
    -- that stop counts as "blocked by a vehicle" for the face to face detection
    if not obstacleDetected then
        local approach = self.vehicle.ad.approachModule
        if approach ~= nil and approach.shouldStop ~= nil and approach:shouldStop() then
            obstacleDetected = true
        end
    end

    -- parked / hidden vehicle waiting for a given vehicle to pass, no longer linked to a plan
    if self.state == ADTrafficYieldModule.STATE_WAIT_DETACHED then
        return self:updateDetachedWait(dt)
    end

    if self.state == ADTrafficYieldModule.STATE_IDLE then
        if not ADTrafficYieldModule.isEnabled() then
            self.blockedTimer:timer(false)
            return false
        end
        -- anticipation: oncoming AD vehicle on my route -> slow down and stop at a safe distance
        local holding = self:updateAnticipation(dt)
        if self.state == ADTrafficYieldModule.STATE_IDLE then
            if holding then
                return true
            end
            self:checkForHeadOnDeadlock(dt, obstacleDetected)
        end
        -- a plan may have just started
        if self.state == ADTrafficYieldModule.STATE_IDLE then
            return false
        end
    end

    if not self:checkPlanStillValid() then
        return false
    end

    if self.state == ADTrafficYieldModule.STATE_REVERSER_RETREAT then
        self:updateReverserRetreat(dt)
    elseif self.state == ADTrafficYieldModule.STATE_REVERSER_WAIT then
        self:updateReverserWait(dt)
    elseif self.state == ADTrafficYieldModule.STATE_REVERSER_PASS then
        self:updateReverserPass(dt)
    elseif self.state == ADTrafficYieldModule.STATE_YIELDER_APPROACH then
        -- holding at the stop point while still approaching: the module drives this frame
        if self:updateYielderApproach(dt) and self.state == ADTrafficYieldModule.STATE_YIELDER_APPROACH then
            return true
        end
    elseif self.state == ADTrafficYieldModule.STATE_PRIORITY_APPROACH then
        if self:updatePriorityApproach(dt) and self.state == ADTrafficYieldModule.STATE_PRIORITY_APPROACH then
            return true
        end
    elseif self.state == ADTrafficYieldModule.STATE_REVERSER_BRANCH then
        self:updateReverserBranch(dt)
    elseif self.state == ADTrafficYieldModule.STATE_REVERSER_HIDE then
        self:updateReverserHide(dt)
    elseif self.state == ADTrafficYieldModule.STATE_PARKER_PASS then
        self:updateParkerPass(dt)
    elseif self.state == ADTrafficYieldModule.STATE_PARKER_SEARCH then
        self:updateParkerSearch(dt)
    elseif self.state == ADTrafficYieldModule.STATE_PARKER_MOVE then
        self:updateParkerMove(dt)
    elseif self.state == ADTrafficYieldModule.STATE_PARKER_WAIT then
        self:updateParkerWait(dt)
    elseif self.state == ADTrafficYieldModule.STATE_SECTION_CLEAR then
        self:updateSectionClear(dt)
    end

    -- while driving inside a plan (passing / approaching), keep anticipating any OTHER oncoming vehicle
    if self:holdForOtherOncoming(dt) then
        return true
    end

    -- stopped face to face by a vehicle that the route comparison could not see
    if self:checkBlockedWhilePassing(dt, obstacleDetected) then
        return self:isControlling()
    end

    return self:isControlling()
end

-- a vehicle passing inside a plan is stopped by its sensor face to face with another AD vehicle that is
-- not part of the plan (e.g. started between both vehicles, already too close to be seen on the route):
-- hand over to it with a standard plan instead of waiting for the pass timeout
function ADTrafficYieldModule:checkBlockedWhilePassing(dt, obstacleDetected)
    local passing = self.state == ADTrafficYieldModule.STATE_REVERSER_PASS or self.state == ADTrafficYieldModule.STATE_PARKER_PASS
    local isStopped = ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1
    local delay = (AutoDrive.getSetting("trafficYieldDelay") or 5) * 1000
    if not self.blockedTimer:timer(passing and obstacleDetected and isStopped, delay, dt) then
        return false
    end
    if (g_updateLoopIndex % AutoDrive.PERF_FRAMES) ~= 0 then
        return false
    end
    local other = self:findHeadOnPartner(self.partner)
    if other == nil then
        return false
    end
    self:log("blocked face to face by %s while passing", ADTrafficYieldModule.getName(other))
    self:handOverTo(other, true)
    return true
end

-- a vehicle that drives during a plan (passing or approaching its partner) must still slow down and stop
-- for a third oncoming vehicle; returns true while held
function ADTrafficYieldModule:holdForOtherOncoming(dt)
    -- only once passing: during the approach both already brake for each other, and the partner must be
    -- allowed to finish pulling over before a third vehicle is dealt with (else it is left half parked)
    local drivingStates = {
        [ADTrafficYieldModule.STATE_REVERSER_PASS] = true,
        [ADTrafficYieldModule.STATE_PARKER_PASS] = true
    }
    if not drivingStates[self.state] then
        self.otherConflict = nil
        return false
    end
    if g_time >= (self.nextOtherCheck or 0) then
        self.nextOtherCheck = g_time + ADTrafficYieldModule.ANTICIPATION_INTERVAL
        self.otherConflict, self.otherGap = self:findOncomingConflict(self.partner)
        self.otherGapTime = g_time
        if self.otherConflict ~= nil then
            local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
            local otherFront = ADTrafficYieldModule.getTrainExtents(self.otherConflict)
            self.otherStopGap = myFront + otherFront + ADTrafficYieldModule.ANTICIPATION_GAP
        end
    end
    local other = self.otherConflict
    if other == nil or not ADTrafficYieldModule.isAdVehicleUsable(other) then
        self.otherHoldTimer = 0
        return false
    end
    local elapsed = (g_time - (self.otherGapTime or g_time)) / 1000
    local closing = (ADTrafficYieldModule.getSpeedKmh(self.vehicle) + ADTrafficYieldModule.getSpeedKmh(other)) / 3.6 * elapsed
    local stopDistance = (self.otherGap - closing - self.otherStopGap) / 2
    if stopDistance > 0.5 then
        local allowedSpeed = math.sqrt(2 * ADTrafficYieldModule.ANTICIPATION_DECEL * stopDistance) * 3.6
        local drivePathModule = self.vehicle.ad.drivePathModule
        if drivePathModule.speedLimit ~= nil then
            drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, math.max(allowedSpeed, 3))
        end
        self.otherHoldTimer = 0
        return false
    end
    self:holdVehicle(dt)

    -- held for a third vehicle while still inside a plan: hand over, so a new plan can start with it
    self.otherHoldTimer = (self.otherHoldTimer or 0) + dt
    local otherModule = other.ad.trafficYieldModule
    if self.otherHoldTimer >= ADTrafficYieldModule.ANTICIPATION_START_DELAY and otherModule.state == ADTrafficYieldModule.STATE_IDLE
        and ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1 then
        self.otherHoldTimer = 0
        self:handOverTo(other)
    end
    return true
end

-- leaves the current plan to start a new one with another oncoming vehicle; the partner of the current
-- plan, if parked or hidden, keeps waiting on its own until this vehicle has passed it
function ADTrafficYieldModule:handOverTo(other, faceToFace)
    local partner = self.partner
    if partner ~= nil and partner.ad ~= nil and partner.ad.trafficYieldModule ~= nil then
        local partnerModule = partner.ad.trafficYieldModule
        if partnerModule.plan == self.plan then
            local waiting = partnerModule.state == ADTrafficYieldModule.STATE_PARKER_WAIT or partnerModule.state == ADTrafficYieldModule.STATE_PARKER_MOVE
                or partnerModule.state == ADTrafficYieldModule.STATE_REVERSER_HIDE or partnerModule.state == ADTrafficYieldModule.STATE_REVERSER_BRANCH
            local reachedRouteIndex = partnerModule.reachedRouteIndex
            partnerModule:reset()
            if waiting then
                local partnerSpot = self.plan ~= nil and self.plan.parkSpot or nil
                partnerModule.waitDirX = partnerSpot and partnerSpot.dirX
                partnerModule.waitDirZ = partnerSpot and partnerSpot.dirZ
                partnerModule.waitFor = self.vehicle
                partnerModule.waitSpot = partnerSpot
                partnerModule.waitRouteIndex = reachedRouteIndex
                partnerModule:setState(ADTrafficYieldModule.STATE_WAIT_DETACHED)
            else
                partnerModule.cooldownUntil = g_time + ADTrafficYieldModule.COOLDOWN_SUCCESS
                if partner.ad.specialDrivingModule ~= nil then
                    partner.ad.specialDrivingModule:releaseVehicle()
                end
                ADTrafficYieldModule.resyncWayPoints(partner, reachedRouteIndex)
            end
        end
    end
    self:log("hand over to %s", ADTrafficYieldModule.getName(other))
    local myRouteIndex = self.reachedRouteIndex
    self:reset()
    ADTrafficYieldModule.resyncWayPoints(self.vehicle, myRouteIndex)
    if faceToFace then
        -- already nose to nose: no room left to pull over in advance
        ADTrafficYieldModule.startPlan(self.vehicle, other)
    else
        ADTrafficYieldModule.startEarlyPlan(self.vehicle, other)
    end
end

function ADTrafficYieldModule:updateDetachedWait(dt)
    if not self:finishAlignment(dt, self.waitSpot, self.waitFor) then
        self:holdVehicle(dt)
    end
    local done = self:hasPassedMe(self.waitFor, self.waitDirX, self.waitDirZ)
    if done then
        -- owner 28/10 (S7): then the next one of its queue, until the last has passed
        local nextInQueue = ADTrafficYieldModule.findFollowerBehind(self.waitFor, ADTrafficYieldModule.QUEUE_GAP, self.vehicle)
        if nextInQueue ~= nil and nextInQueue ~= self.waitFor and not self:hasPassedMe(nextInQueue, self.waitDirX, self.waitDirZ) then
            print(string.format("[AD-Croise] %s: %s est passe, je reste gare pour la file : %s", ADTrafficYieldModule.getName(self.vehicle),
                ADTrafficYieldModule.getName(self.waitFor), ADTrafficYieldModule.getName(nextInQueue)))
            self.waitFor = nextInQueue
            done = false
        end
    end
    if done or self.stateTimer:timer(true, 180000, dt) then
        local routeIndex = self.waitRouteIndex
        self:reset()
        self.waitFor = nil
        self.waitSpot = nil
        self.waitRouteIndex = nil
        self.cooldownUntil = g_time + ADTrafficYieldModule.COOLDOWN_SUCCESS
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        ADTrafficYieldModule.resyncWayPoints(self.vehicle, routeIndex)
        return false
    end
    return true
end

------------------------------------------------------------------------------------------------
-- anticipation: compare the routes of the AD vehicles to see an oncoming one long before the sensors
------------------------------------------------------------------------------------------------

-- route ahead of each vehicle computed once per frame and shared by every vehicle that looks at it
-- (the tables returned are only read, never changed)
ADTrafficYieldModule.routeCache = setmetatable({}, {__mode = "k"})

-- graph ids of the next waypoints of a route with the distance along the route to each of them

function ADTrafficYieldModule.collectRouteAhead(vehicle, maxDistance)
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    local cached = ADTrafficYieldModule.routeCache[vehicle]
    if cached ~= nil and cached.loop == g_updateLoopIndex and cached.maxDistance == maxDistance
        and cached.wayPoints == wayPoints and cached.currentIndex == currentIndex then
        return cached.list, cached.distById
    end
    local list, distById = ADTrafficYieldModule.buildRouteAhead(vehicle, wayPoints, currentIndex, maxDistance)
    ADTrafficYieldModule.routeCache[vehicle] = {loop = g_updateLoopIndex, maxDistance = maxDistance, wayPoints = wayPoints,
                                                currentIndex = currentIndex, list = list, distById = distById}
    return list, distById
end

function ADTrafficYieldModule.buildRouteAhead(vehicle, wayPoints, currentIndex, maxDistance)
    local list, distById = {}, {}
    if wayPoints == nil or currentIndex == nil then
        return list, distById
    end
    local lastX, _, lastZ = ADTrafficYieldModule.getPosition(vehicle)
    local distance = 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if distance > maxDistance then
            break
        end
        if wp.id ~= nil and distById[wp.id] == nil then
            table.insert(list, wp.id)
            distById[wp.id] = distance
        end
    end
    return list, distById
end

-- returns the oncoming AD vehicle that will use a segment of my route in the opposite direction,
-- and the distance between both vehicles along the route
-- another AD vehicle drives ahead of me on my route, in my direction, before 'beforeDistance' metres:
-- I am not the head of the convoy, the leader deals with the oncoming vehicle first
ADTrafficYieldModule.ON_ROUTE_STATES = {
    [ADTrafficYieldModule.STATE_IDLE] = true,
    [ADTrafficYieldModule.STATE_YIELDER_APPROACH] = true,
    [ADTrafficYieldModule.STATE_PRIORITY_APPROACH] = true,
    [ADTrafficYieldModule.STATE_REVERSER_PASS] = true,
    [ADTrafficYieldModule.STATE_PARKER_PASS] = true
}

function ADTrafficYieldModule:hasLeaderAhead(myDist, beforeDistance, excluded)
    for _, other in pairs(AutoDrive.getAllVehicles()) do
        if other ~= self.vehicle and other ~= excluded and other.ad ~= self.vehicle.ad and ADTrafficYieldModule.isAdVehicleUsable(other)
            and ADTrafficYieldModule.ON_ROUTE_STATES[other.ad.trafficYieldModule.state] -- a parked vehicle is not in the way
            and not AutoDrive:checkIsConnected(self.vehicle, other) then
            local wayPoints, currentIndex = other.ad.drivePathModule:getWayPoints()
            if wayPoints ~= nil and currentIndex ~= nil and wayPoints[currentIndex] ~= nil and wayPoints[currentIndex + 1] ~= nil then
                local here, nextId = wayPoints[currentIndex].id, wayPoints[currentIndex + 1].id
                local dHere, dNext = myDist[here], myDist[nextId]
                if dHere ~= nil and dNext ~= nil and dNext > dHere and dHere < beforeDistance then
                    return true
                end
            end
        end
    end
    return false
end

-- another AD vehicle follows me closely on my route, in my direction (it would be in the way if I reversed).
-- Owner 28/10 20:16 (the MF 7S 3 m behind the trailer of the 7R 350 was not seen: the 20 m were counted from the MF to a
-- point ahead of the 7R, shorter than the 7R and its trailer): maxDistance is the gap between the rear of my train
-- (trailer included) and the front of the follower; any vehicle of the queue that close counts
function ADTrafficYieldModule.hasFollowerBehind(vehicle, maxDistance, excluded)
    return ADTrafficYieldModule.findFollowerBehind(vehicle, maxDistance, excluded) ~= nil
end

-- the closest such follower (nil when none); excluded: a vehicle left out (the partner, or the parked one)
function ADTrafficYieldModule.findFollowerBehind(vehicle, maxDistance, excluded)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.drivePathModule == nil then
        return nil
    end
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil or wayPoints[currentIndex] == nil or wayPoints[currentIndex + 1] == nil then
        return nil
    end
    local myId, myNextId = wayPoints[currentIndex].id, wayPoints[currentIndex + 1].id
    if myId == nil or myNextId == nil then
        return nil
    end
    local best, bestGap = nil, math.huge
    local x, _, z = ADTrafficYieldModule.getPosition(vehicle)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(vehicle)
    local _, myRear = ADTrafficYieldModule.getTrainExtents(vehicle)
    local rearX, rearZ = x - dirX * myRear, z - dirZ * myRear
    for _, other in pairs(AutoDrive.getAllVehicles()) do
        if other ~= vehicle and other ~= excluded and other.ad ~= vehicle.ad and ADTrafficYieldModule.isAdVehicleUsable(other)
            and not AutoDrive:checkIsConnected(vehicle, other) then
            local ox, _, oz = ADTrafficYieldModule.getPosition(other)
            local odirX, odirZ = ADTrafficYieldModule.getDirection(other)
            local otherFront = ADTrafficYieldModule.getTrainExtents(other)
            local gap = MathUtil.vector2Length(ox + odirX * otherFront - rearX, oz + odirZ * otherFront - rearZ)
            if gap <= maxDistance and gap < bestGap then
                -- it drives my way: my next points are on its route ahead, past my whole train
                local _, otherDist = ADTrafficYieldModule.collectRouteAhead(other, maxDistance + myRear + otherFront + 40)
                if otherDist[myId] ~= nil and otherDist[myNextId] ~= nil and otherDist[myNextId] > otherDist[myId] then
                    best, bestGap = other, gap
                end
            end
        end
    end
    return best
end

-- owner 28/10 (S7, "c'est ce que j'ai demande il y a plusieurs heures"): the whole oncoming queue behind 'leader'
-- (AD vehicles following it on its route, 40 m gaps at most, 4 at most), leader not included
function ADTrafficYieldModule.getQueueBehind(leader, excluded)
    local queue = {}
    local current = leader
    for _ = 1, 4 do
        local follower = ADTrafficYieldModule.findFollowerBehind(current, ADTrafficYieldModule.QUEUE_GAP, excluded)
        if follower == nil or follower == leader then
            break
        end
        for _, v in ipairs(queue) do
            if v == follower then
                return queue
            end
        end
        table.insert(queue, follower)
        current = follower
    end
    return queue
end

-- head-on section between my route and the route of another vehicle: the consecutive segments I drive a -> b
-- that it drives b -> a (a two-way road, the other one really drives that same segment backwards).
-- Returns the distance along my route to the start of the section and along its route to the same point,
-- nil when there is no such section or when one of them leaves it before the other one enters it
-- (the first one simply goes first, nobody has to give way)
function ADTrafficYieldModule.findHeadOnSection(vehicle, myList, myDist, other, otherList, otherDist)
    local otherNext = {}
    for k = 1, #otherList - 1 do
        otherNext[otherList[k]] = otherList[k + 1]
    end
    for i = 1, #myList - 1 do
        local a, b = myList[i], myList[i + 1]
        if otherNext[b] == a then
            -- extend the section as long as the other one drives my next segments backwards
            local j = i + 1
            while j < #myList and otherNext[myList[j + 1]] == myList[j] do
                j = j + 1
            end
            local last = myList[j]
            local myFront, myRear = ADTrafficYieldModule.getTrainExtents(vehicle)
            local otherFront, otherRear = ADTrafficYieldModule.getTrainExtents(other)
            local margin = ADTrafficYieldModule.ANTICIPATION_GAP
            -- travel times at the current speeds (at least 2 m/s, a vehicle held for the other one restarts)
            local mySpeed = math.max(ADTrafficYieldModule.getSpeedKmh(vehicle) / 3.6, 2)
            local otherSpeed = math.max(ADTrafficYieldModule.getSpeedKmh(other) / 3.6, 2)
            -- the other one is out of the section (its rear past a) before my front reaches a
            if (otherDist[a] + otherRear + margin) / otherSpeed < (myDist[a] - myFront) / mySpeed then
                return nil, nil
            end
            -- I am out of the section (my rear past 'last') before its front reaches 'last'
            if (myDist[last] + myRear + margin) / mySpeed < (otherDist[last] - otherFront) / otherSpeed then
                return nil, nil
            end
            local section = {}
            for k = i, j do
                table.insert(section, myList[k])
            end
            return myDist[a], otherDist[a], section
        end
    end
    return nil, nil
end

function ADTrafficYieldModule:findOncomingConflict(excluded)
    if not self.vehicle.ad.drivePathModule:isOnRoadNetwork() then
        return nil, nil
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local myList, myDist = ADTrafficYieldModule.collectRouteAhead(self.vehicle, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    if #myList < 2 then
        return nil, nil
    end

    local bestOther, bestGap = nil, math.huge
    for _, other in pairs(AutoDrive.getAllVehicles()) do
        if other ~= self.vehicle and other ~= excluded and other.ad ~= self.vehicle.ad and ADTrafficYieldModule.isAdVehicleUsable(other)
            and other.ad.drivePathModule:isOnRoadNetwork() and not AutoDrive:checkIsConnected(self.vehicle, other) then
            local ox, _, oz = ADTrafficYieldModule.getPosition(other)
            if MathUtil.vector2Length(ox - x, oz - z) < 2 * ADTrafficYieldModule.ANTICIPATION_DISTANCE then
                local otherList, otherDist = ADTrafficYieldModule.collectRouteAhead(other, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
                local mine, da = ADTrafficYieldModule.findHeadOnSection(self.vehicle, myList, myDist, other, otherList, otherDist)
                if mine ~= nil then
                    local gap = mine + da
                    -- only the heads of the convoys: nobody of mine in front of me, nobody of its own in front of it
                    if gap < bestGap and not self:hasLeaderAhead(myDist, mine, other)
                        and not other.ad.trafficYieldModule:hasLeaderAhead(otherDist, da, self.vehicle) then
                        bestGap = gap
                        bestOther = other
                    end
                end
            end
        end
    end
    if bestOther == nil then
        return nil, nil
    end
    return bestOther, bestGap
end

-- slows the vehicle down so that both oncoming vehicles stop at a safe distance, then starts the
-- passing manoeuvre. Returns true while the vehicle is held at the stop point.
-- owner 26/10 21:46 (7R 350 "between two procedures", crossing and face to face, rebooting from one to the other): the
-- crossing has priority: a vehicle committed on a red section (or backing out of it) either waits or goes, no face to face
-- plan starts for it or with it until it is through
function ADTrafficYieldModule.intersectionHasPriority(vehicle)
    local c = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.intersection or nil
    return c ~= nil and (c.committed ~= nil or c.retreat ~= nil)
end

function ADTrafficYieldModule:updateAnticipation(dt)
    self.anticipationHoldFor = nil
    if g_time >= (self.nextAnticipationCheck or 0) then
        -- every vehicle checks in the same frame, so each route ahead is computed once and shared (routeCache)
        self.nextAnticipationCheck = (math.floor(g_time / ADTrafficYieldModule.ANTICIPATION_INTERVAL) + 1) * ADTrafficYieldModule.ANTICIPATION_INTERVAL
        self.conflictPartner, self.conflictGap = self:findOncomingConflict()
        if self.conflictPartner ~= nil then
            local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
            local otherFront = ADTrafficYieldModule.getTrainExtents(self.conflictPartner)
            self.conflictStopGap = myFront + otherFront + ADTrafficYieldModule.ANTICIPATION_GAP
            self.conflictGapTime = g_time
        end
    end

    local partner = self.conflictPartner
    if partner == nil or not ADTrafficYieldModule.isAdVehicleUsable(partner) then
        self.anticipationTimer = nil
        return false
    end

    -- the crossing first (owner 26/10 21:46): no plan while one of us is engaged on a red section
    if ADTrafficYieldModule.intersectionHasPriority(self.vehicle) or ADTrafficYieldModule.intersectionHasPriority(partner) then
        self.anticipationTimer = nil
        return false
    end
    -- first choice: one of them pulls over in advance on its own route (early yield)
    local partnerModuleEarly = partner.ad.trafficYieldModule
    if not self:isBusy() and not partnerModuleEarly:isBusy() then
        -- owner 28/10 18:19 / 18:25: a detour only for the one on the road waiting for the one coming out of the two-way track,
        -- when it loses less time than waiting (startEarlyPlan); not for a crossing planned inside the track
        local history = ADTrafficYieldModule.pairHistory[ADTrafficYieldModule.getPairKey(self.vehicle, partner)]
        local earlyRecentlyFailed = history ~= nil and history.earlyTried ~= nil and g_time - history.earlyTried < 60000
        if not earlyRecentlyFailed then
            ADTrafficYieldModule.startEarlyPlan(self.vehicle, partner)
            self.conflictPartner = nil
            return false
        end
    end

    -- distance driven by both since the last route comparison (both approach each other)
    local elapsed = (g_time - (self.conflictGapTime or g_time)) / 1000
    local closing = (ADTrafficYieldModule.getSpeedKmh(self.vehicle) + ADTrafficYieldModule.getSpeedKmh(partner)) / 3.6 * elapsed
    local gap = self.conflictGap - closing

    -- each vehicle brakes for its half of the remaining free distance
    local stopDistance = (gap - self.conflictStopGap) / 2
    if stopDistance > 0.5 then
        local allowedSpeed = math.sqrt(2 * ADTrafficYieldModule.ANTICIPATION_DECEL * stopDistance) * 3.6
        local drivePathModule = self.vehicle.ad.drivePathModule
        if drivePathModule.speedLimit ~= nil then
            drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, math.max(allowedSpeed, 3))
        end
        self.anticipationTimer = nil
        return false
    end

    -- at the stop point: hold, and start the manoeuvre once both are stopped
    self:holdVehicle(dt)
    self.anticipationHoldFor = partner
    local partnerModule = partner.ad.trafficYieldModule
    local bothStopped = ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1 and ADTrafficYieldModule.getSpeedKmh(partner) < 1
    if bothStopped and not self:isBusy() and not partnerModule:isBusy() then
        self.anticipationTimer = (self.anticipationTimer or 0) + dt
        if self.anticipationTimer >= ADTrafficYieldModule.ANTICIPATION_START_DELAY then
            self.anticipationTimer = nil
            self.conflictPartner = nil
            ADTrafficYieldModule.startPlan(self.vehicle, partner)
        end
    else
        self.anticipationTimer = nil
    end
    return true
end

------------------------------------------------------------------------------------------------
-- early yield: as soon as an oncoming vehicle is seen on the route, the yielding vehicle looks for a
-- roadside spot ahead on its own route and pulls over there in advance; the other one does not stop
------------------------------------------------------------------------------------------------

-- length of a list of waypoints from index 'from'
function ADTrafficYieldModule.getPathLength(points, from)
    local length = 0
    for k = math.max(from, 1), #points - 1 do
        length = length + MathUtil.vector2Length(points[k + 1].x - points[k].x, points[k + 1].z - points[k].z)
    end
    return length
end

-- looks for another way to my destination that avoids the head-on section with 'partner'; when one exists and
-- is at most DETOUR_MAX longer, my route is changed to it and the passing is not needed. Tried once per partner
-- maxExtra (owner 28/10 18:25): the detour must also lose less time than waiting, at most maxExtra m longer.
-- probe: nothing is changed, returns true, the extra length and a function that takes the detour
function ADTrafficYieldModule:tryDetour(partner, maxExtra, probe)
    if not probe then
        if self.detourPartner == partner and g_time < (self.detourRetryTime or 0) then
            return false
        end
        self.detourPartner = partner
        self.detourRetryTime = g_time + 20000
    end
    local drivePathModule = self.vehicle.ad.drivePathModule
    local wayPoints, currentIndex = drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil or wayPoints[currentIndex] == nil or wayPoints[currentIndex + 1] == nil then
        return false
    end
    local startWp, nextWp, lastWp = wayPoints[currentIndex], wayPoints[currentIndex + 1], wayPoints[#wayPoints]
    if startWp.id == nil or nextWp.id == nil or lastWp.id == nil or ADPathCalculator == nil then
        return false
    end
    local myList, myDist = ADTrafficYieldModule.collectRouteAhead(self.vehicle, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    local otherList, otherDist = ADTrafficYieldModule.collectRouteAhead(partner, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    local mine, _, section = ADTrafficYieldModule.findHeadOnSection(self.vehicle, myList, myDist, partner, otherList, otherDist)
    if mine == nil then
        return false
    end
    if mine < ADTrafficYieldModule.DETOUR_MIN_AHEAD then
        self:log("no other way to avoid %s: the shared section starts %.0f m ahead", ADTrafficYieldModule.getName(partner), mine)
        return false
    end
    local avoid = {}
    for _, id in ipairs(section) do
        avoid[id] = true
    end
    if avoid[startWp.id] then
        self:log("no other way to avoid %s: I am already on the shared section", ADTrafficYieldModule.getName(partner))
        return false
    end

    -- AutoDrive route calculation with the head-on section made very expensive
    local originalWeights = ADPathCalculator.getDetourWeights
    ADPathCalculator.getDetourWeights = function(calculator)
        local weights = originalWeights(calculator)
        for id in pairs(avoid) do
            weights[id] = (weights[id] or 0) + ADTrafficYieldModule.DETOUR_PENALTY
        end
        return weights
    end
    local ok, path = pcall(ADGraphManager.pathFromTo, ADGraphManager, startWp.id, lastWp.id, {nextWp.id})
    ADPathCalculator.getDetourWeights = originalWeights
    if not ok or path == nil or #path < 2 or path[1].id ~= startWp.id or path[#path].id ~= lastWp.id then
        self:log("no other way to avoid %s: no route found", ADTrafficYieldModule.getName(partner))
        return false
    end
    for _, wp in ipairs(path) do
        if avoid[wp.id] then
            self:log("no other way to avoid %s", ADTrafficYieldModule.getName(partner))
            return false
        end
    end
    local detour = ADTrafficYieldModule.getPathLength(path, 1) - ADTrafficYieldModule.getPathLength(wayPoints, currentIndex)
    if detour > ADTrafficYieldModule.DETOUR_MAX then
        self:log("other way to avoid %s is %.0f m longer, too long", ADTrafficYieldModule.getName(partner), detour)
        return false
    end
    if maxExtra ~= nil and detour > maxExtra then
        self:log("other way to avoid %s is %.0f m longer, it would lose more time than waiting (%.0f m)", ADTrafficYieldModule.getName(partner), detour, maxExtra)
        print(string.format("[AD-Croise] %s: detour de %.0f m possible pour eviter %s, mais plus long que l'attente (%.0f m au plus) : j'attends",
            ADTrafficYieldModule.getName(self.vehicle), detour, ADTrafficYieldModule.getName(partner), math.max(maxExtra, 0)))
        return false
    end

    local function apply()
        -- keep the waypoints already driven, then the new way from the current waypoint on
        local newWayPoints = {}
        for k = 1, currentIndex - 1 do
            newWayPoints[k] = wayPoints[k]
        end
        for _, wp in ipairs(path) do
            table.insert(newWayPoints, wp)
        end
        drivePathModule.wayPoints = newWayPoints
        drivePathModule:setCurrentWayPointIndex(currentIndex)
        self:log("detour of %.0f m to avoid meeting %s", math.max(detour, 0), ADTrafficYieldModule.getName(partner))
    end
    if probe then
        return true, math.max(detour, 0), apply
    end
    apply()
    return true, math.max(detour, 0)
end

-- two-way links (single track) of the route of a vehicle, from the link it is on up to maxDistance m ahead,
-- as keys "small id-large id"
function ADTrafficYieldModule.getTwoWayLinks(vehicle, maxDistance)
    local links = {}
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return links
    end
    local lastX, _, lastZ = ADTrafficYieldModule.getPosition(vehicle)
    local distance = 0
    for i = math.max(2, currentIndex), #wayPoints do
        local a, b = wayPoints[i - 1], wayPoints[i]
        if a == nil or b == nil then
            break
        end
        distance = distance + MathUtil.vector2Length(b.x - lastX, b.z - lastZ)
        lastX, lastZ = b.x, b.z
        if distance > maxDistance then
            break
        end
        if a.id ~= nil and b.id ~= nil and ADTrafficYieldModule.isTwoWay(a.id, b.id) then
            links[math.min(a.id, b.id) .. "-" .. math.max(a.id, b.id)] = true
        end
    end
    return links
end

-- owner 28/10 18:27-18:28 ("the procedure only if both routes share a two-way stretch"): true when the routes of both
-- vehicles, from where they are, use the same two-way link
function ADTrafficYieldModule.shareTwoWayStretch(vehicleA, vehicleB)
    local maxDistance = 2 * ADTrafficYieldModule.MAX_DETECTION_DISTANCE + 20
    local linksA = ADTrafficYieldModule.getTwoWayLinks(vehicleA, maxDistance)
    if next(linksA) == nil then
        return false
    end
    for key, _ in pairs(ADTrafficYieldModule.getTwoWayLinks(vehicleB, maxDistance)) do
        if linksA[key] then
            return true
        end
    end
    return false
end

-- two-way link between two network points: the same lane is driven both ways (single track)
function ADTrafficYieldModule.isTwoWay(idA, idB)
    if ADGraphManager == nil or idA == nil or idB == nil then
        return false
    end
    local a = ADGraphManager:getWayPointById(idA)
    local b = ADGraphManager:getWayPointById(idB)
    if a == nil or b == nil or a.out == nil or b.out == nil then
        return false
    end
    local ab, ba = false, false
    for _, id in ipairs(a.out) do
        if id == idB then
            ab = true
        end
    end
    for _, id in ipairs(b.out) do
        if id == idA then
            ba = true
        end
    end
    return ab and ba
end

-- mouth of a single track: a junction point (3 neighbours or more) with a two-way link
function ADTrafficYieldModule.isSingleTrackMouth(id)
    if ADGraphManager == nil or id == nil then
        return false
    end
    local node = ADGraphManager:getWayPointById(id)
    if node == nil then
        return false
    end
    local neighbours, count = {}, 0
    for _, list in ipairs({node.out or {}, node.incoming or {}}) do
        for _, n in ipairs(list) do
            if neighbours[n] == nil then
                neighbours[n] = true
                count = count + 1
            end
        end
    end
    if count < 3 then
        return false
    end
    for n, _ in pairs(neighbours) do
        if ADTrafficYieldModule.isTwoWay(id, n) then
            return true
        end
    end
    return false
end

-- S4/S6 (owner 28/10 17:41, Magnum 7220 / 6205 TTV on the 270 m farm track): the head-on section is only searched in the
-- first ANTICIPATION_DISTANCE m of both routes, so on a long single track it began in the middle of the track (the 6205
-- had just left the farm): the wait line, the turn-off and "partner out of the single track" were all measured from
-- there (the plan ended while the 6205 was still 100 m up the track). The section is extended backwards along my route
-- to the real entrance of the single track (two-way links), never behind me
function ADTrafficYieldModule:extendSectionToEntrance(mine, section)
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if mine == nil or section == nil or section[1] == nil or wayPoints == nil or currentIndex == nil then
        return mine, section, false
    end
    local first = nil
    for i = math.max(1, currentIndex), #wayPoints do
        if wayPoints[i] ~= nil and wayPoints[i].id == section[1] then
            first = i
            break
        end
    end
    if first == nil then
        return mine, section, false
    end
    local k = first
    while k - 1 >= math.max(1, currentIndex - 1) and wayPoints[k - 1] ~= nil and wayPoints[k - 1].id ~= nil
        and ADTrafficYieldModule.isTwoWay(wayPoints[k - 1].id, wayPoints[k].id) do
        k = k - 1
    end
    -- the two-way stretch reaches the point behind me: I am already on the single track
    local inside = k < currentIndex
    -- owner 30/10 17:02-17:03 (7R 350 held at its red line counted inside, the 942 Vario 75 m from the exit had to pull over;
    -- rules: within 120 m the one in the track comes out first, the road one checks the track before the red line):
    -- held at my line, on the red portion, or less than ENTRY_INSIDE m past the start of the track = still outside
    if inside then
        local c = self.vehicle.ad.intersection
        if c ~= nil and c.committed == nil and (c.holding or c.waited) then
            inside = false
        elseif ADIntersectionModule ~= nil and ADIntersectionModule.isIntersectionPoint ~= nil
            and (ADIntersectionModule.isIntersectionPoint(wayPoints[currentIndex]) or ADIntersectionModule.isIntersectionPoint(wayPoints[currentIndex - 1])) then
            inside = false
        else
            -- the real start of the two-way stretch behind me (further back than the previous point)
            local start = k
            while start - 1 >= 1 and start > currentIndex - 30 and wayPoints[start - 1] ~= nil and wayPoints[start - 1].id ~= nil
                and wayPoints[start].id ~= nil and ADTrafficYieldModule.isTwoWay(wayPoints[start - 1].id, wayPoints[start].id) do
                start = start - 1
            end
            if start > 1 and start >= currentIndex - 30 then
                local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
                local past = 0
                for i = start, currentIndex - 2 do
                    past = past + MathUtil.vector2Length(wayPoints[i + 1].x - wayPoints[i].x, wayPoints[i + 1].z - wayPoints[i].z)
                    if past >= ADTrafficYieldModule.ENTRY_INSIDE then
                        break
                    end
                end
                local last = wayPoints[currentIndex - 1]
                if past < ADTrafficYieldModule.ENTRY_INSIDE and last ~= nil then
                    past = past + MathUtil.vector2Length(x - last.x, z - last.z)
                end
                if past < ADTrafficYieldModule.ENTRY_INSIDE then
                    inside = false
                end
            end
        end
    end
    k = math.max(k, currentIndex)
    if k == first then
        return mine, section, inside
    end
    local extended = {}
    for i = k, first - 1 do
        table.insert(extended, wayPoints[i].id)
    end
    for _, id in ipairs(section) do
        table.insert(extended, id)
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local distance, lastX, lastZ = 0, x, z
    for i = math.max(1, currentIndex), k do
        local wp = wayPoints[i]
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
    end
    return distance, extended, inside
end

-- S4: seconds before my front reaches the single track (0 when already inside), nil without head-on section
function ADTrafficYieldModule:getSingleTrackArrival(other)
    local _, mine, section, inside = self:getOncomingGap(other)
    if mine == nil then
        return nil, false, nil
    end
    local front = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local speed = math.max(ADTrafficYieldModule.getSpeedKmh(self.vehicle), ADTrafficYieldModule.S4_MIN_SPEED) / 3.6
    if inside then
        return 0, true, mine
    end
    return math.max(0, mine - front) / speed, false, mine
end

function ADTrafficYieldModule:getOncomingGap(other)
    if not ADTrafficYieldModule.isAdVehicleUsable(other) then
        return nil
    end
    local myList, myDist = ADTrafficYieldModule.collectRouteAhead(self.vehicle, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    local otherList, otherDist = ADTrafficYieldModule.collectRouteAhead(other, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    local mine, da, section = ADTrafficYieldModule.findHeadOnSection(self.vehicle, myList, myDist, other, otherList, otherDist)
    if mine == nil then
        return nil
    end
    local gap = mine + da
    local inside
    mine, section, inside = self:extendSectionToEntrance(mine, section)
    return gap, mine, section, inside
end

-- speed limit / hold to stop before the oncoming partner (same rule as the anticipation)
-- returns true while held at the stop point
-- share: part of the free distance this vehicle may drive (the other one drives the rest)
function ADTrafficYieldModule:limitSpeedTowards(dt, partner, share)
    share = share or 0.5
    if g_time >= (self.nextGapCheck or 0) then
        self.nextGapCheck = g_time + ADTrafficYieldModule.ANTICIPATION_INTERVAL
        self.earlyGap, self.earlySectionMine, self.earlySection = self:getOncomingGap(partner)
        self.earlyGapTime = g_time
        local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        local otherFront = ADTrafficYieldModule.getTrainExtents(partner)
        self.earlyStopGap = myFront + otherFront + ADTrafficYieldModule.ANTICIPATION_GAP
    end
    if self.earlyGap == nil then
        return false, nil
    end
    local elapsed = (g_time - (self.earlyGapTime or g_time)) / 1000
    local closing = (ADTrafficYieldModule.getSpeedKmh(self.vehicle) + ADTrafficYieldModule.getSpeedKmh(partner)) / 3.6 * elapsed
    local stopDistance = (self.earlyGap - closing - self.earlyStopGap) * share
    if stopDistance > 0.5 then
        local allowedSpeed = math.sqrt(2 * ADTrafficYieldModule.ANTICIPATION_DECEL * stopDistance) * 3.6
        local drivePathModule = self.vehicle.ad.drivePathModule
        if drivePathModule.speedLimit ~= nil then
            drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, math.max(allowedSpeed, 3))
        end
        return false, stopDistance
    end
    self:holdVehicle(dt)
    return true, stopDistance
end

-- distance along the route of a vehicle from its position to the network point 'id', nil when not within maxDistance
function ADTrafficYieldModule.getRouteDistanceTo(vehicle, id, maxDistance)
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    if id == nil or wayPoints == nil or currentIndex == nil then
        return nil
    end
    local lastX, _, lastZ = ADTrafficYieldModule.getPosition(vehicle)
    local distance = 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if distance > maxDistance then
            return nil
        end
        if wp.id == id then
            return distance
        end
    end
    return nil
end

-- where I am against the two-way track I share with 'other': distance to its entrance on my route, inside or not,
-- distance of the other one to that entrance along its route (its exit), my arrival time at the track
function ADTrafficYieldModule:getTrackSituation(other)
    local gap, mine, section, inside = self:getOncomingGap(other)
    if gap == nil or mine == nil or section == nil or section[1] == nil then
        return nil
    end
    local otherToEntrance = ADTrafficYieldModule.getRouteDistanceTo(other, section[1], 600) or math.max(0, gap - mine)
    local front = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local speed = math.max(ADTrafficYieldModule.getSpeedKmh(self.vehicle), ADTrafficYieldModule.S4_MIN_SPEED) / 3.6
    return {
        gap = gap,
        mine = mine,
        section = section,
        inside = inside == true,
        otherToEntrance = otherToEntrance,
        arrival = inside and 0 or math.max(0, mine - front) / speed
    }
end

-- owner 28/10 18:16 ("avant de s'engager sur la ligne rouge il doit avoir verifie la route, s'il y a quelque chose il
-- s'arrete au point precedent la ligne rouge"): distance along my route to the first point of the red (Intersection)
-- section that leads into the two-way track 'sectionDistance' m ahead (it ends at most RED_LINE_BEFORE_TRACK m before
-- the track, or overlaps it), nil without one. Also returns true when my front is already on it
function ADTrafficYieldModule:findRedLineBefore(sectionDistance)
    if ADIntersectionModule == nil or ADIntersectionModule.isIntersectionPoint == nil or sectionDistance == nil then
        return nil
    end
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return nil
    end
    local lastX, _, lastZ = ADTrafficYieldModule.getPosition(self.vehicle)
    local distance = 0
    local redStart, redEnd = nil, nil
    -- a red section already begun behind me
    if wayPoints[currentIndex - 1] ~= nil and ADIntersectionModule.isIntersectionPoint(wayPoints[currentIndex - 1]) then
        redStart = -1
    end
    local found = nil
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if distance > sectionDistance + 15 then
            break
        end
        if ADIntersectionModule.isIntersectionPoint(wp) then
            redStart = redStart or distance
            redEnd = distance
        elseif redStart ~= nil then
            -- end of a red section: keep the last one before the track
            if redEnd >= sectionDistance - ADTrafficYieldModule.RED_LINE_BEFORE_TRACK then
                found = redStart
            end
            redStart, redEnd = nil, nil
        end
    end
    if redStart ~= nil and redEnd >= sectionDistance - ADTrafficYieldModule.RED_LINE_BEFORE_TRACK then
        found = redStart
    end
    return found
end

-- a spot in my part of the two-way track for the planned crossing with 'other' (driving side, SPOT_MOUTH_CLEAR m from the
-- mouths, the other whole train passes beside), searched ahead of me up to the other one (owner 28/10 18:17: "devant,
-- jusqu'a l'autre"; it stops before the end of my spot if needed); nil without one
function ADTrafficYieldModule:searchCrossingSpot(other, situation)
    local savedPartner = self.partner
    self.partner = other
    self.spotTwoWayOnly = true
    local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local otherFront = ADTrafficYieldModule.getTrainExtents(other)
    local maxAhead = situation.gap - myFront - otherFront - ADTrafficYieldModule.SPOT_CLEARANCE
    local spot = nil
    if maxAhead > 10 then
        local ok, result = pcall(self.searchSpotBySides, self, maxAhead, true)
        if ok then
            spot = result
        else
            Logging.error("[AD] ADTrafficYieldModule: crossing spot search failed: %s", tostring(result))
        end
    end
    self.spotTwoWayOnly = nil
    self.partner = savedPartner
    return spot
end

-- the plan in which 'yielder' gives way (waits at its end or pulls over in the track) and 'priority' drives on
function ADTrafficYieldModule.createEarlyPlan(yielder, priority, options)
    options = options or {}
    ADTrafficYieldModule.measureTrain(yielder)
    ADTrafficYieldModule.measureTrain(priority)

    local plan = {
        mode = "early",
        pairKey = ADTrafficYieldModule.getPairKey(yielder, priority),
        firstReverser = priority,
        reverser = priority, -- the vehicle that drives on (same role as the reverser once the other is parked)
        parker = yielder,
        startTime = g_time,
        parkSpot = options.parkSpot,
        reverserMayStop = true,
        reverserAtLimit = false,
        parked = false,
        passed = false,
        hidden = false,
        exitWait = options.exitWait, -- owner 28/10: I wait before the two-way track (red line, wait line)
        crossing = options.crossing, -- owner 28/10: crossing planned inside the two-way track, I pull over in my spot
        spotTwoWayOnly = options.crossing
    }
    if options.crossing then
        plan.waitBeforeSection = false -- I drive into the track to my spot
    end
    local yModule = yielder.ad.trafficYieldModule
    local pModule = priority.ad.trafficYieldModule
    yModule:log("EARLY plan: I %s for %s", options.crossing and "pull over in the two-way track" or "wait before the two-way track", ADTrafficYieldModule.getName(priority))
    -- owner 30/10 (B): already parked aside for this same vehicle (the plan ended too early): I stay where I am
    local trace = yModule.parkTrace
    local stayParked = options.crossing and trace ~= nil and trace.partner == priority and g_time - trace.time < 60000
        and yModule:isOffMyRoute(1.5)
    yModule:reset()
    pModule:reset()
    yModule.plan, yModule.partner = plan, priority
    pModule.plan, pModule.partner = plan, yielder
    if stayParked then
        plan.parkSpot = trace.spot
        plan.parked = true
        yModule.alignmentDone = true
        print(string.format("[AD-Croise] %s: deja gare pour %s, je reste a ma place", ADTrafficYieldModule.getName(yielder), ADTrafficYieldModule.getName(priority)))
        yModule:setState(ADTrafficYieldModule.STATE_PARKER_WAIT)
    else
        yModule:setState(ADTrafficYieldModule.STATE_YIELDER_APPROACH)
    end
    pModule:setState(ADTrafficYieldModule.STATE_PRIORITY_APPROACH)
    return plan
end

-- owner 28/10 18:11-18:29 (traffic rules of the two-way track, go 18:29):
-- 1. the two-way track has priority to come out: the one inside, less than EXIT_PRIORITY_DISTANCE m from its exit, comes
--    out first; the one on the road waits before the red line (else at its wait line), or takes a detour if it loses less
--    time than waiting
-- 2. farther, or nobody inside yet: both drive in, the crossing is planned: each one looks for a spot in its part of the
--    track; one spot: that one pulls over, the other one drives on; two: the smaller turning radius of the whole train
--    pulls over. No spot at all: the one still outside waits at its end (no manoeuvre at all); both inside: they stop and
--    the one that manoeuvres the least reverses (standard plan). No detour in this case (18:19)
-- (the first one at the track no longer goes first: S4 of 28/10 17:01 is replaced by these rules)
-- Returns true when a plan started or a detour was taken
function ADTrafficYieldModule.startEarlyPlan(vehicleA, vehicleB)
    local mA, mB = vehicleA.ad.trafficYieldModule, vehicleB.ad.trafficYieldModule
    local nameA, nameB = ADTrafficYieldModule.getName(vehicleA), ADTrafficYieldModule.getName(vehicleB)
    local sA = mA:getTrackSituation(vehicleB)
    local sB = mB:getTrackSituation(vehicleA)
    if sA == nil or sB == nil then
        -- one of both no longer sees the shared stretch: the one with no trailer gives way, as before
        local scoreA = ADTrafficYieldModule.getPriorityScore(vehicleA)
        local scoreB = ADTrafficYieldModule.getPriorityScore(vehicleB)
        local yielder = (scoreA < scoreB or (scoreA == scoreB and (vehicleA.id or 0) < (vehicleB.id or 0))) and vehicleA or vehicleB
        ADTrafficYieldModule.createEarlyPlan(yielder, yielder == vehicleA and vehicleB or vehicleA, {})
        return true
    end

    -- rule 1: the one inside comes out first when it is close to its exit
    local outside, inside, sOut, sIn = nil, nil, nil, nil
    if sB.inside and not sA.inside then
        outside, inside, sOut, sIn = vehicleA, vehicleB, sA, sB
    elseif sA.inside and not sB.inside then
        outside, inside, sOut, sIn = vehicleB, vehicleA, sB, sA
    end
    if outside ~= nil and sOut.otherToEntrance <= ADTrafficYieldModule.EXIT_PRIORITY_DISTANCE then
        local outName, inName = ADTrafficYieldModule.getName(outside), ADTrafficYieldModule.getName(inside)
        -- time I would lose waiting: until the whole train coming out is past the entrance, minus my own way to it
        local inSpeed = math.max(ADTrafficYieldModule.getSpeedKmh(inside) / 3.6, 2)
        local clearTime = (sOut.otherToEntrance + ADTrafficYieldModule.getTotalLength(inside) + ADTrafficYieldModule.EXIT_ROOM) / inSpeed
        local lost = math.max(0, clearTime - sOut.arrival)
        local roadSpeed = math.max(ADTrafficYieldModule.getSpeedKmh(outside), ADTrafficYieldModule.DETOUR_ROAD_SPEED) / 3.6
        print(string.format("[AD-Croise] %s: %s sort du chemin a double sens dans %.0f m (moins de %d m) : j'attends avant d'entrer (environ %.0f s d'attente)",
            outName, inName, sOut.otherToEntrance, ADTrafficYieldModule.EXIT_PRIORITY_DISTANCE, lost))
        local maxExtra = lost * roadSpeed
        if maxExtra > 5 then
            local ok, extra = outside.ad.trafficYieldModule:tryDetour(inside, maxExtra)
            if ok then
                print(string.format("[AD-Croise] %s: detour de %.0f m, moins de temps perdu que d'attendre %.0f s que %s sorte du chemin",
                    outName, extra or 0, lost, inName))
                return true
            end
        end
        ADTrafficYieldModule.createEarlyPlan(outside, inside, {exitWait = true})
        return true
    end

    -- rule 2: crossing planned inside the two-way track
    ADTrafficYieldModule.measureTrain(vehicleA)
    ADTrafficYieldModule.measureTrain(vehicleB)
    local spotA = mA:searchCrossingSpot(vehicleB, sA)
    local spotB = mB:searchCrossingSpot(vehicleA, sB)
    local yielder, spot, why
    if spotA ~= nil and spotB ~= nil then
        local rA = ADTrafficYieldModule.getTrainRadius(vehicleA)
        local rB = ADTrafficYieldModule.getTrainRadius(vehicleB)
        if math.abs(rA - rB) > ADTrafficYieldModule.RADIUS_TIE then
            yielder = rA < rB and vehicleA or vehicleB
        else
            local lA, lB = ADTrafficYieldModule.getTotalLength(vehicleA), ADTrafficYieldModule.getTotalLength(vehicleB)
            if math.abs(lA - lB) > 1 then
                yielder = lA < lB and vehicleA or vehicleB
            else
                yielder = (vehicleA.id or 0) < (vehicleB.id or 0) and vehicleA or vehicleB
            end
        end
        spot = yielder == vehicleA and spotA or spotB
        why = string.format("place des deux cotes, %s se gare (attelage : rayon %.1f m contre %.1f m)", ADTrafficYieldModule.getName(yielder),
            yielder == vehicleA and rA or rB, yielder == vehicleA and rB or rA)
    elseif spotA ~= nil or spotB ~= nil then
        yielder = spotA ~= nil and vehicleA or vehicleB
        spot = spotA or spotB
        why = string.format("place pour %s seulement", ADTrafficYieldModule.getName(yielder))
    end
    if yielder ~= nil then
        local priority = yielder == vehicleA and vehicleB or vehicleA
        print(string.format("[AD-Croise] %s et %s : croisement prevu dans le chemin a double sens, %s a %.0f m (%s) : %s se gare, %s passe",
            nameA, nameB, why, spot.entryDistance or 0, spot.side == "left" and "gauche" or "droite", ADTrafficYieldModule.getName(yielder),
            ADTrafficYieldModule.getName(priority)))
        -- 30/10: who counted as inside, distances to the exit, where the spot is (to check a log line against the map)
        print(string.format("[AD-Croise]   %s dedans=%s (l'autre a %.0f m de l'entree), %s dedans=%s (l'autre a %.0f m), place entree %.0f,%.0f fin %.0f,%.0f decalage %.1f m",
            nameA, tostring(sA.inside), sA.otherToEntrance or -1, nameB, tostring(sB.inside), sB.otherToEntrance or -1,
            spot.entryX or 0, spot.entryZ or 0, spot.finalX or 0, spot.finalZ or 0, spot.lateral or 0))
        ADTrafficYieldModule.createEarlyPlan(yielder, priority, {crossing = true, parkSpot = spot})
        return true
    end

    -- no spot in the track for either
    if not sA.inside or not sB.inside then
        local waiter
        if not sA.inside and sB.inside then
            waiter = vehicleA
        elseif not sB.inside and sA.inside then
            waiter = vehicleB
        else
            waiter = sA.arrival > sB.arrival and vehicleA or vehicleB -- both outside: the later one at the track
        end
        local other = waiter == vehicleA and vehicleB or vehicleA
        print(string.format("[AD-Croise] %s et %s : aucune place dans le chemin a double sens : %s attend a son bout (aucune manoeuvre), %s passe",
            nameA, nameB, ADTrafficYieldModule.getName(waiter), ADTrafficYieldModule.getName(other)))
        ADTrafficYieldModule.createEarlyPlan(waiter, other, {exitWait = true})
        return true
    end
    -- both inside without any spot: both stop at the safe distance (anticipation), then the standard plan makes the one
    -- that manoeuvres the least reverse (rule 7)
    print(string.format("[AD-Croise] %s et %s : tous deux dans le chemin a double sens, aucune place devant : ils s'arretent, celui qui manoeuvre le moins recule",
        nameA, nameB))
    local key = ADTrafficYieldModule.getPairKey(vehicleA, vehicleB)
    local history = ADTrafficYieldModule.pairHistory[key] or {failures = 0, time = g_time}
    history.earlyTried = g_time
    ADTrafficYieldModule.pairHistory[key] = history
    return false
end

-- builds a path parallel to the route, starting at route index 'startIndex' (point sx, sz on the route):
-- the lateral offset grows smoothly from 0 to 'lateral' over 'swerve' metres, then stays constant.
-- One point every PATH_STEP metres, 'length' metres long. Each point: x, z, dirX, dirZ (road direction), s, offset
function ADTrafficYieldModule.buildOffsetPath(wayPoints, startIndex, lateral, swerve, length)
    local step = ADTrafficYieldModule.PATH_STEP
    local points = {}
    local s = 0
    local index = startIndex
    local ax, az = wayPoints[index].x, wayPoints[index].z
    local nextS = 0
    while index < #wayPoints and s <= length do
        local b = wayPoints[index + 1]
        local segLength = MathUtil.vector2Length(b.x - ax, b.z - az)
        if segLength > 0.01 then
            local dx, dz = (b.x - ax) / segLength, (b.z - az) / segLength
            while nextS <= s + segLength and nextS <= length do
                local t = nextS - s
                local px, pz = ax + dx * t, az + dz * t
                local ramp = math.min(1, nextS / swerve)
                ramp = ramp * ramp * (3 - 2 * ramp) -- smoothstep: soft leaving of the road
                local offset = lateral * ramp
                -- GIANTS local +x (left) of the road direction is (dz, -dx)
                table.insert(points, {x = px + dz * offset, z = pz - dx * offset, dirX = dx, dirZ = dz, s = nextS, offset = offset})
                nextS = nextS + step
            end
            s = s + segLength
        end
        ax, az = b.x, b.z
        index = index + 1
    end
    if #points < 2 or points[#points].s < length - step then
        return nil -- route too short
    end
    return points
end

-- checks a parallel path: terrain, water, field and obstacles along it (the vehicle body width)
-- returns free, onField, why (refusal reason: "hauteur", "pente", "eau", "objet <name>")
function ADTrafficYieldModule:isPathFree(points, width, roadY, py)
    local halfW = width / 2 + 0.2
    local onField = false
    -- terrain / water / field on the points first (cheap)
    for _, p in ipairs(points) do
        local h = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p.x, py, p.z)
        -- owner 28/10 20:13 (Patriot on the 7 % farm track): compared with the road right beside the point, not with
        -- the height where I stand (12 m further on a 7 % slope is already 0.9 m)
        local roadH = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p.x - p.dirZ * p.offset, py, p.z + p.dirX * p.offset)
        if math.abs(h - roadH) > ADTrafficYieldModule.MAX_ROAD_HEIGHT_DIFF then
            return false, false, string.format("hauteur (%.1f m)", h - roadH)
        end
        -- lateral slope of the strip
        local lx, lz = p.x + p.dirZ * halfW, p.z - p.dirX * halfW
        local rx, rz = p.x - p.dirZ * halfW, p.z + p.dirX * halfW
        local hl = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, lx, py, lz)
        local hr = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, rx, py, rz)
        if math.abs(hl - hr) > ADTrafficYieldModule.MAX_SLOPE_DIFF then
            return false, false, string.format("pente (%.1f m)", math.abs(hl - hr))
        end
        if g_currentMission.environmentAreaSystem ~= nil and g_currentMission.environmentAreaSystem.getWaterYAtWorldPosition ~= nil then
            local waterY = g_currentMission.environmentAreaSystem:getWaterYAtWorldPosition(p.x, h, p.z)
            if waterY ~= nil and waterY > h - 0.2 then
                return false, false, "eau"
            end
        end
        if p.offset ~= 0 and AutoDrive.checkIsOnField(p.x, h, p.z) then
            onField = true
        end
    end
    -- obstacles: one box per path segment, oriented along it
    -- owner 30/10 (C, 942 Vario against the railing of a bridge): the whole path, also its part still over the road;
    -- there only fixed objects count (vehicles on the road are the traffic, checked apart)
    for k = 1, #points - 1 do
        local a, b = points[k], points[k + 1]
        local onRoad = math.abs(b.offset) <= halfW
        local dx, dz = b.x - a.x, b.z - a.z
        local segLength = math.max(0.1, MathUtil.vector2Length(dx, dz))
        local mx, mz = (a.x + b.x) / 2, (a.z + b.z) / 2
        local h = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, mx, py, mz)
        if self:overlapHit(mx, h + 1.9, mz, math.atan2(dx, dz), halfW, 1.3, segLength / 2 + 0.2) and not (onRoad and self.overlapHitVehicle) then
            return false, onField, "objet " .. tostring(self.overlapHitName)
        end
    end
    return true, onField
end

-- the route from startIndex on runs on two-way links (the single track) for 'length' m
function ADTrafficYieldModule.isTwoWayStretch(wayPoints, startIndex, length)
    local covered = 0
    local k = startIndex
    while covered < length do
        local a, b = wayPoints[k], wayPoints[k + 1]
        if a == nil or b == nil or a.id == nil or b.id == nil or not ADTrafficYieldModule.isTwoWay(a.id, b.id) then
            return false
        end
        covered = covered + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        k = k + 1
    end
    return true
end

-- the whole stretch on the driving side (see getSides)
function ADTrafficYieldModule:searchSpotBySides(maxAhead, keepClearOfPartner, fromIndex)
    for _, side in ipairs(ADTrafficYieldModule.getSides()) do
        local spot = self:searchSpotAlongRoute(maxAhead, side.name, keepClearOfPartner, fromIndex)
        if spot ~= nil then
            return spot
        end
    end
    return nil
end

-- searches, along my route ahead, a point where I can leave the road and follow a path parallel to the
-- route on the roadside, before reaching maxAhead metres. sideFilter: "right" / "left" / nil
-- keepClearOfPartner: the partner is still driving towards me (early plan), the end of the path must stay
-- out of its way, braking distance included (otherwise I would stop half way with my trailer on the road)
-- fromIndex: search from that route point instead of my position (a place I would reach by reversing).
-- Owner 28/10 18:11: for a crossing planned in a two-way track (spotTwoWayOnly) the spot must be in the track itself
-- length towed behind the hitch of the tractor (0: nothing towed, mounted implements are rigid)
function ADTrafficYieldModule.getTowedLength(vehicle)
    local units, count = AutoDrive.getAllUnits(vehicle)
    if units == nil or count == nil or count < 2 then
        return 0
    end
    local towed = false
    for _, unit in pairs(units) do
        if ADTrafficYieldModule.isTowedUnit(vehicle, unit) then
            towed = true
            break
        end
    end
    if not towed then
        return 0
    end
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(vehicle)
    local _, rear = ADTrafficYieldModule.getTrainExtents(vehicle)
    return math.max(0, rear - tractorLength / 2)
end

-- point of the path at 's' (interpolated; before its start / after its end along the first / last road direction)
function ADTrafficYieldModule.pathPointAt(path, s)
    local n = #path
    local first, last = path[1], path[n]
    if s <= first.s then
        return first.x + first.dirX * (s - first.s), first.z + first.dirZ * (s - first.s)
    elseif s >= last.s then
        return last.x + last.dirX * (s - last.s), last.z + last.dirZ * (s - last.s)
    end
    local step = path[2].s - first.s
    local k = math.max(1, math.min(n - 1, math.floor((s - first.s) / step) + 1))
    while k > 1 and path[k].s > s do
        k = k - 1
    end
    while k < n - 1 and path[k + 1].s < s do
        k = k + 1
    end
    local a, b = path[k], path[k + 1]
    local t = (b.s - a.s) > 0.001 and (s - a.s) / (b.s - a.s) or 0
    return a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
end

-- the road under a roadside path (offset taken off), 30 m more before its start; kept in the path
function ADTrafficYieldModule.getPathRoad(path)
    if path.road == nil then
        local first = path[1]
        local road = {{x = first.x - first.dirX * 30 - first.dirZ * first.offset, z = first.z - first.dirZ * 30 + first.dirX * first.offset}}
        for _, p in ipairs(path) do
            table.insert(road, {x = p.x - p.dirZ * p.offset, z = p.z + p.dirX * p.offset})
        end
        path.road = road
    end
    return path.road
end

-- a point lies off the road, on the full offset of the path
function ADTrafficYieldModule.isOffRoad(path, x, z)
    local full = math.abs(path[#path].offset)
    return ADTrafficYieldModule.distanceToPolyline(ADTrafficYieldModule.getPathRoad(path), x, z) >= full - ADTrafficYieldModule.TOW_ROAD_TOLERANCE
end

-- towed units follow the hitch (tractrix), the tractor drives on the path. Returns the first tractor 's' (minS at least,
-- untilS at most) where the towed rear and its centre are off the road, with the towed points there (nil: never)
function ADTrafficYieldModule.simulateTowed(path, hitchBack, towedLength, minS, untilS)
    local step = ADTrafficYieldModule.TOW_STEP
    local axleDist = towedLength * 0.7
    local function tractorAt(s)
        local x, z = ADTrafficYieldModule.pathPointAt(path, s)
        local bx, bz = ADTrafficYieldModule.pathPointAt(path, s - 1)
        local dx, dz = x - bx, z - bz
        local l = math.max(0.001, MathUtil.vector2Length(dx, dz))
        return x, z, dx / l, dz / l
    end
    -- the train comes straight along the road
    local x, z, dx, dz = tractorAt(0)
    local hx, hz = x - dx * hitchBack, z - dz * hitchBack
    local ax, az = hx - dx * axleDist, hz - dz * axleDist
    local s = 0
    while s <= untilS do
        s = s + step
        x, z, dx, dz = tractorAt(s)
        hx, hz = x - dx * hitchBack, z - dz * hitchBack
        local ux, uz = ax - hx, az - hz
        local l = math.max(0.001, MathUtil.vector2Length(ux, uz))
        ux, uz = ux / l, uz / l
        ax, az = hx + ux * axleDist, hz + uz * axleDist
        if s >= minS then
            local rx, rz = hx + ux * towedLength, hz + uz * towedLength
            local mx, mz = hx + ux * towedLength / 2, hz + uz * towedLength / 2
            if ADTrafficYieldModule.isOffRoad(path, rx, rz) and ADTrafficYieldModule.isOffRoad(path, mx, mz) then
                return s, {{x = hx, z = hz}, {x = mx, z = mz}, {x = rx, z = rz}}
            end
        end
    end
    return nil
end

-- the path up to 'length' (points after it dropped)
function ADTrafficYieldModule.trimPath(path, length)
    local trimmed = {}
    for _, p in ipairs(path) do
        if p.s > length then
            break
        end
        table.insert(trimmed, p)
    end
    return #trimmed >= 2 and trimmed or path
end

function ADTrafficYieldModule:searchSpotAlongRoute(maxAhead, sideFilter, keepClearOfPartner, fromIndex)
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return nil
    end
    if fromIndex ~= nil and wayPoints[fromIndex] == nil then
        return nil
    end
    local startIndex = fromIndex or currentIndex
    local twoWayOnly = self.spotTwoWayOnly or (self.plan ~= nil and self.plan.spotTwoWayOnly)
    local parker = self.vehicle
    local reverser = self.partner
    local parkerWidth = ADTrafficYieldModule.getWidth(parker)
    local reverserWidth = ADTrafficYieldModule.getWidth(reverser)
    -- owner 28/10 (S7): far enough aside for the widest vehicle of the oncoming queue
    if reverser ~= nil then
        for _, v in ipairs(ADTrafficYieldModule.getQueueBehind(reverser, parker)) do
            reverserWidth = math.max(reverserWidth, ADTrafficYieldModule.getWidth(v))
        end
    end
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(parker)
    local parkerFront, parkerRear = ADTrafficYieldModule.getTrainExtents(parker)
    local margin = AutoDrive.getSetting("trafficYieldMargin") or ADTrafficYieldModule.LATERAL_MARGIN
    local baseLateral = (parkerWidth + reverserWidth) / 2 + margin
    local trailLength = math.max(0, parkerRear - tractorLength / 2)
    local towedLength = ADTrafficYieldModule.getTowedLength(parker)
    local runOut = ADTrafficYieldModule.getRunOut(trailLength)
    local swerve = math.max(8, tractorLength * 1.5, baseLateral * 2.5, trailLength)
    -- the tractor stops at swerve + runOut; the path continues a bit for the alignment and the aim point
    local pathLength = swerve + runOut + ADTrafficYieldModule.PATH_EXTRA
    local needed = swerve + runOut + parkerFront
    local laterals = {baseLateral, baseLateral + 1.0}
    local sides = ADTrafficYieldModule.getSides()

    local lastX, py, lastZ = ADTrafficYieldModule.getPosition(parker)
    if fromIndex ~= nil then
        lastX, lastZ = wayPoints[fromIndex].x, wayPoints[fromIndex].z
    end
    local roadY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, lastX, py, lastZ)

    local partnerX, partnerZ, partnerClearance
    if keepClearOfPartner and reverser ~= nil then
        local px, _, pz = ADTrafficYieldModule.getPosition(reverser)
        local partnerFront = ADTrafficYieldModule.getTrainExtents(reverser)
        local v = ADTrafficYieldModule.getSpeedKmh(reverser) / 3.6
        partnerX, partnerZ = px, pz
        partnerClearance = partnerFront + ADTrafficYieldModule.SPOT_CLEARANCE + v * v / (2 * ADTrafficYieldModule.ANTICIPATION_DECEL)
    end

    -- owner 28/10 20:13: every refusal reason of the search goes in one log line
    local refused, tried = {}, 0
    local function refuse(why)
        local key = why
        if string.sub(why, 1, 5) ~= "objet" then
            key = string.match(why, "^([^%(]-)%s*%(") or why
        end
        refused[key] = (refused[key] or 0) + 1
    end
    for _, side in ipairs(sides) do
        if sideFilter == nil or side.name == sideFilter then
            local fieldCandidate = nil
            local distance = 0
            local lastCheckedDistance = -math.huge
            lastX, _, lastZ = ADTrafficYieldModule.getPosition(parker)
            if fromIndex ~= nil then
                lastX, lastZ = wayPoints[fromIndex].x, wayPoints[fromIndex].z
            end
            for i = startIndex, #wayPoints - 1 do
                local wp = wayPoints[i]
                if wp == nil then
                    break
                end
                distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
                lastX, lastZ = wp.x, wp.z
                if distance + needed > maxAhead then
                    break
                end
                if distance >= 5 and distance - lastCheckedDistance >= ADTrafficYieldModule.CANDIDATE_STEP then
                    lastCheckedDistance = distance
                    local onTrack = not twoWayOnly or ADTrafficYieldModule.isTwoWayStretch(wayPoints, i, needed)
                    for _, lateral in ipairs(onTrack and laterals or {}) do
                        local lat = side.sign * lateral
                        local path = ADTrafficYieldModule.buildOffsetPath(wayPoints, i, lat, swerve, pathLength)
                        local tooCloseToPartner = false
                        if path ~= nil and partnerX ~= nil then
                            local last = path[#path]
                            tooCloseToPartner = MathUtil.vector2Length(last.x - partnerX, last.z - partnerZ) < partnerClearance
                        end
                        if path == nil then
                            refuse("trajet trop court")
                        elseif tooCloseToPartner then
                            refuse("trop pres de l'autre")
                        end
                        if path ~= nil and not tooCloseToPartner then
                            tried = tried + 1
                            local free, onField, why = self:isPathFree(path, parkerWidth, roadY, py)
                            if not free then
                                refuse(why or "?")
                            end
                            -- owner 30/10 16:37 (A): where the tractor stops, the trailer must be off the road. In a bend it cuts
                            -- inside: the path gets up to TOW_EXTRA m longer, otherwise the spot is refused
                            local finalS, towPoints = swerve + runOut, nil
                            if free and towedLength > 1 then
                                local alignedS, points = ADTrafficYieldModule.simulateTowed(path, tractorLength / 2, towedLength, finalS, path[#path].s - 4)
                                if alignedS == nil then
                                    local longPath = ADTrafficYieldModule.buildOffsetPath(wayPoints, i, lat, swerve, pathLength + ADTrafficYieldModule.TOW_EXTRA)
                                    local longFree, longField, longWhy = false, false, "trajet trop court"
                                    if longPath ~= nil then
                                        longFree, longField, longWhy = self:isPathFree(longPath, parkerWidth, roadY, py)
                                    end
                                    if longFree and partnerX ~= nil then
                                        local last = longPath[#longPath]
                                        if MathUtil.vector2Length(last.x - partnerX, last.z - partnerZ) < partnerClearance then
                                            longFree, longWhy = false, "trop pres de l'autre"
                                        end
                                    end
                                    if longFree then
                                        alignedS, points = ADTrafficYieldModule.simulateTowed(longPath, tractorLength / 2, towedLength, finalS, longPath[#longPath].s - 4)
                                        if alignedS ~= nil then
                                            path = ADTrafficYieldModule.trimPath(longPath, alignedS + ADTrafficYieldModule.PATH_EXTRA)
                                            onField = onField or longField
                                        end
                                    end
                                    if alignedS == nil then
                                        free = false
                                        refuse(longFree and "remorque pas hors de la route" or ("remorque pas hors de la route, plus loin " .. tostring(longWhy or "?")))
                                    end
                                end
                                if alignedS ~= nil then
                                    finalS, towPoints = alignedS, points
                                end
                            end
                            if free and not self:isSpotClearForPartner(path, finalS, parkerFront, parkerRear, parkerWidth, towPoints) then
                                free = false
                                refuse("l'autre ne passe pas")
                            end
                            if free then
                                local spot = ADTrafficYieldModule.makePathSpot(path, wp, distance, side.name, lat, swerve, finalS - swerve, onField, roadY)
                                if not onField then
                                    return spot
                                end
                                fieldCandidate = fieldCandidate or spot
                            end
                        end
                    end
                end
            end
            -- no grass spot on this side: a spot partly on a field of this side before trying the other side
            if fieldCandidate ~= nil then
                return fieldCandidate
            end
        end
    end
    if tried > 0 or next(refused) ~= nil then
        local parts = {}
        for key, count in pairs(refused) do
            table.insert(parts, string.format("%s x%d", key, count))
        end
        table.sort(parts)
        if g_time - (self.spotSummaryTime or -math.huge) > 10000 then
            self.spotSummaryTime = g_time
            print(string.format("[AD-Croise] %s: aucune place %s sur %.0f m (%d essais) : %s", ADTrafficYieldModule.getName(parker),
                tostring(sideFilter or "des deux cotes"), maxAhead, tried, table.concat(parts, ", ")))
        end
    end
    return nil
end

-- S7 (owner 28/10 17:42, go 17:01: the 6205 TTV parked in the mouth of the farm track, the Magnum 7220 with its cultivator
-- could not get past and each one waited for the other): a roadside spot is kept only when the whole other train (as its
-- sensors see it, implements included) passes beside the parked train, and never within SPOT_MOUTH_CLEAR m of the mouth
-- of a single track
function ADTrafficYieldModule:isSpotClearForPartner(path, finalS, parkerFront, parkerRear, parkerWidth, towPoints)
    local partner = self.partner
    if partner == nil or path == nil or #path < 2 or partner.ad == nil or partner.ad.drivePathModule == nil then
        return true
    end
    local final = path[#path]
    for _, p in ipairs(path) do
        if p.s >= finalS then
            final = p
            break
        end
    end
    local dx, dz = final.dirX or 0, final.dirZ or 0
    local points = {}
    -- 30/10: with a trailer, its simulated points (it cuts inside a bend) instead of the rear straight behind
    for _, s in ipairs(towPoints ~= nil and {parkerFront or 0, 0} or {parkerFront or 0, 0, -(parkerRear or 0)}) do
        table.insert(points, {x = final.x + dx * s, z = final.z + dz * s})
    end
    for _, p in ipairs(towPoints or {}) do
        table.insert(points, p)
    end
    local route = ADTrafficYieldModule.getRoutePolyline(partner, 150)
    local partnerWidth = 0
    local widest = partner
    -- every vehicle of the oncoming queue must pass beside me, the widest one counts
    local cache = self.queueCache
    if cache == nil or cache.loop ~= g_updateLoopIndex or cache.partner ~= partner then
        local queue = ADTrafficYieldModule.getQueueBehind(partner, self.vehicle)
        table.insert(queue, 1, partner)
        cache = {loop = g_updateLoopIndex, partner = partner, queue = queue}
        self.queueCache = cache
    end
    for _, v in ipairs(cache.queue) do
        local w = ADTrafficYieldModule.getWidth(v)
        if v.ad.approachModule ~= nil and v.ad.approachModule.getTrainWidth ~= nil then
            local sideMargin = ADApproachModule ~= nil and ADApproachModule.SIDE_MARGIN or 0.3
            w = math.max(w, v.ad.approachModule:getTrainWidth() + 2 * sideMargin)
        end
        if w > partnerWidth then
            partnerWidth, widest = w, v
        end
    end
    local needed = partnerWidth / 2 + (parkerWidth or 0) / 2 + ADTrafficYieldModule.SPOT_PASS_MARGIN
    for _, p in ipairs(points) do
        local d = ADTrafficYieldModule.distanceToPolyline(route, p.x, p.z)
        if d < needed then
            self:logSpotRefused(string.format("%s would not pass (%.1f m from its route, %.1f m needed)", ADTrafficYieldModule.getName(widest), d, needed),
                string.format("place refusee : %s ne passerait pas a cote (%.1f m de son trajet, il faut %.1f m)", ADTrafficYieldModule.getName(widest), d, needed))
            return false
        end
    end
    -- mouth of a single track on my route or on its route near the parked train
    local ids = {}
    local function collect(vehicle, maxDistance)
        local wps, idx = vehicle.ad.drivePathModule:getWayPoints()
        if wps == nil or idx == nil then
            return
        end
        local qx, _, qz = ADTrafficYieldModule.getPosition(vehicle)
        local distance = 0
        for i = math.max(1, idx - 1), #wps do
            local wp = wps[i]
            if wp == nil then
                break
            end
            distance = distance + MathUtil.vector2Length(wp.x - qx, wp.z - qz)
            qx, qz = wp.x, wp.z
            if distance > maxDistance then
                break
            end
            if wp.id ~= nil then
                ids[wp.id] = wp
            end
        end
    end
    collect(self.vehicle, 200)
    collect(partner, 150)
    for id, wp in pairs(ids) do
        local close = false
        for _, p in ipairs(points) do
            if MathUtil.vector2Length(wp.x - p.x, wp.z - p.z) < ADTrafficYieldModule.SPOT_MOUTH_CLEAR then
                close = true
                break
            end
        end
        if close and ADTrafficYieldModule.isSingleTrackMouth(id) then
            self:logSpotRefused("within the mouth of a single track", string.format("place refusee : a moins de %d m de l'entree d'un chemin unique", ADTrafficYieldModule.SPOT_MOUTH_CLEAR))
            return false
        end
    end
    return true
end

function ADTrafficYieldModule:logSpotRefused(text, textFr)
    if self.spotRefusedLog ~= nil and self.spotRefusedLog == textFr and g_time - (self.spotRefusedTime or 0) < 10000 then
        return
    end
    self.spotRefusedLog, self.spotRefusedTime = textFr, g_time
    self:log("spot refused: %s", text)
    print(string.format("[AD-Croise] %s: %s", ADTrafficYieldModule.getName(self.vehicle), textFr))
end

function ADTrafficYieldModule.makePathSpot(path, wp, distance, sideName, lat, swerve, runOut, onField, y)
    local function pointAt(s)
        local best = path[#path]
        for _, p in ipairs(path) do
            if p.s >= s then
                best = p
                break
            end
        end
        return best
    end
    local entry = path[1]
    local swervePoint = pointAt(swerve)
    local finalPoint = pointAt(swerve + runOut)
    local last = path[#path]
    return {
        path = path,
        finalS = swerve + runOut,
        entryX = entry.x, entryZ = entry.z, entryDistance = distance,
        onField = onField,
        side = sideName,
        forward = swerve,
        lateral = lat,
        lateralAbs = math.abs(lat),
        x = swervePoint.x, y = y, z = swervePoint.z,
        finalX = finalPoint.x, finalZ = finalPoint.z,
        aimX = last.x, aimZ = last.z,
        originX = wp.x, originZ = wp.z,
        dirX = finalPoint.dirX, dirZ = finalPoint.dirZ
    }
end

-- index of the path point closest to a world position, searching from 'fromIndex'
function ADTrafficYieldModule.getClosestPathIndex(path, x, z, fromIndex)
    local bestIndex, bestDistance = fromIndex or 1, math.huge
    for k = math.max(1, (fromIndex or 1) - 2), #path do
        local d = MathUtil.vector2Length(path[k].x - x, path[k].z - z)
        if d < bestDistance then
            bestIndex, bestDistance = k, d
        end
    end
    return bestIndex, bestDistance
end

-- rear of the last towed unit lies on the parallel path (close to it and parallel)
function ADTrafficYieldModule:isRearOnPath(path)
    local units, count = AutoDrive.getAllUnits(self.vehicle)
    local unit = self.vehicle
    if units ~= nil and count ~= nil and count > 1 and units[count] ~= nil then
        unit = units[count]
    end
    local _, length = ADTrafficYieldModule.getUnitDimensions(unit)
    local rx, _, rz = localToWorld(unit.components[1].node, 0, 0, -length / 2)
    -- 30/10 (B): the last unit is off the road, rear and centre (in a bend it is not parallel to the path)
    local mx, _, mz = getWorldTranslation(unit.components[1].node)
    if #path >= 2 and ADTrafficYieldModule.isOffRoad(path, rx, rz) and ADTrafficYieldModule.isOffRoad(path, mx, mz) then
        return true
    end
    local index, distance = ADTrafficYieldModule.getClosestPathIndex(path, rx, rz, 1)
    -- 30/10: distance to the path line, not to its points (2 m apart: a rear 0.3 m from the line could be 1 m from a point)
    local segment = math.huge
    for k = math.max(1, index - 1), math.min(#path - 1, index) do
        local a, b = path[k], path[k + 1]
        local sx, sz = b.x - a.x, b.z - a.z
        local l2 = sx * sx + sz * sz
        local t = l2 > 0.0001 and math.max(0, math.min(1, ((rx - a.x) * sx + (rz - a.z) * sz) / l2)) or 0
        segment = math.min(segment, MathUtil.vector2Length(rx - (a.x + sx * t), rz - (a.z + sz * t)))
    end
    distance = math.min(distance, segment)
    if distance > 0.6 then
        return false
    end
    -- the rear must be on the constant offset part of the path, not on the ramp
    local p = path[index]
    if math.abs(p.offset) < math.abs(path[#path].offset) - 0.3 then
        return false
    end
    local ux, _, uz = localDirectionToWorld(unit.components[1].node, 0, 0, 1)
    local l = MathUtil.vector2Length(ux, uz)
    return l < 0.01 or (ux * p.dirX + uz * p.dirZ) / l > 0.985
end

-- follows the parallel path with a look-ahead point; returns true when the train is parked
function ADTrafficYieldModule:followParkPath(dt, spot)
    local path = spot.path
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    self.pathIndex = ADTrafficYieldModule.getClosestPathIndex(path, x, z, self.pathIndex or 1)
    local current = path[self.pathIndex]

    local reachedFinal = current.s >= spot.finalS
    local atPathEnd = self.pathIndex >= #path - 1
    if (reachedFinal and self:isRearOnPath(path)) or atPathEnd then
        self.pathIndex = nil
        return true
    end

    -- look-ahead target on the path
    local lookAhead = 5 + ADTrafficYieldModule.getSpeedKmh(self.vehicle) / 3.6
    local target = path[#path]
    for k = self.pathIndex, #path do
        if MathUtil.vector2Length(path[k].x - x, path[k].z - z) >= lookAhead then
            target = path[k]
            break
        end
    end
    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    self:ensureMotorStarted()
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, {x = target.x, y = spot.y, z = target.z}, ADTrafficYieldModule.PARK_SPEED, false, 0.5, ADTrafficYieldModule.PARK_SPEED)
    return false
end


-- the yielder is already in the mouth of the single track (closer than SECTION_WAIT_CLEAR): it reverses along its
-- own route until its front is SECTION_WAIT_CLEAR m before the start of the track, then waits there.
-- Returns true while the module drives the vehicle
function ADTrafficYieldModule:updateSectionBackOff(dt)
    local plan = self.plan
    local backOff = plan.sectionBackOff
    if self.reverseTargets == nil then
        self.reverseTargets = self:buildReverseTargets()
        self.reverseTargetIndex = 1
        local x, y, z = ADTrafficYieldModule.getPosition(self.vehicle)
        self.reverseStart = {x = x, y = y, z = z}
        -- owner 26/10 18:58 (7R 350 + trailer just started its route, backed off 12 m + 10 m "straight" and ended in the grass):
        -- the back-off follows my own route behind me, never a straight line into the unknown
        self.backOffLine = {{x = x, z = z}}
        for _, t in ipairs(self.reverseTargets) do
            if t.straight then
                break
            end
            table.insert(self.backOffLine, {x = t.x, z = t.z})
        end
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local reversed = MathUtil.vector2Length(x - self.reverseStart.x, z - self.reverseStart.z)
    local blockedBehind = self.vehicle.ad.collisionDetectionModule:checkReverseCollision()
    local blockedTooLong = self.reverseBlockedTimer:timer(blockedBehind, 8000, dt)
    local target = self.reverseTargets[self.reverseTargetIndex]
    if target ~= nil and target.straight then
        target = nil -- end of my route behind me: no further
    end
    -- drifted off my route (trailer): stop here
    local offRoute = #self.backOffLine >= 2 and ADTrafficYieldModule.distanceToPolyline(self.backOffLine, x, z) > 3.5
    if offRoute and not backOff.offRouteLogged then
        backOff.offRouteLogged = true
        self:log("back-off left my route (%.1f m aside), I stop here", ADTrafficYieldModule.distanceToPolyline(self.backOffLine, x, z))
        print(string.format("[AD-Croise] %s: le recul s'ecarte de mon trace, j'arrete la", ADTrafficYieldModule.getName(self.vehicle)))
    end
    if #self.backOffLine < 2 and not backOff.noRouteLogged then
        backOff.noRouteLogged = true
        self:log("no route behind me to back off along")
        print(string.format("[AD-Croise] %s: pas de trace derriere moi, je ne recule pas", ADTrafficYieldModule.getName(self.vehicle)))
    end
    backOff.time = backOff.time or g_time
    -- owner 26/10 18:00 (Puma 240 CVX backed off 18 m "before the single track" and stayed nose to nose with the 6205 TTV
    -- coming out of the field): the way of the other one may run along my own route before its first network point
    -- (pathfinder lead-in, field entrance, same dirt track): the wait line is only good once my whole train is off its
    -- remaining route, else I keep reversing up to SECTION_BACKOFF_MAX
    if g_time >= (backOff.nextClearCheck or 0) then
        backOff.nextClearCheck = g_time + 500
        backOff.clear = not self:isOnPartnerOffNetworkWay()
    end
    local reached = reversed >= backOff.distance
    if reached and not backOff.clear and not backOff.extended and not backOff.extra and reversed < ADTrafficYieldModule.SECTION_BACKOFF_MAX and target ~= nil then
        backOff.extended = true
        self:log("backed off %.0f m but still on the way of %s, I keep reversing (%d m at most)", reversed, ADTrafficYieldModule.getName(self.partner), ADTrafficYieldModule.SECTION_BACKOFF_MAX)
        print(string.format("[AD-Croise] %s: recule de %.0f m mais toujours sur le trajet de %s, je continue a reculer (%d m au plus)", ADTrafficYieldModule.getName(self.vehicle),
            reversed, ADTrafficYieldModule.getName(self.partner), ADTrafficYieldModule.SECTION_BACKOFF_MAX))
    end
    local stuck = backOff.stopped and self:isReverseStuck()
    local done = (reached and (backOff.clear or reversed >= ADTrafficYieldModule.SECTION_BACKOFF_MAX)) or target == nil or blockedTooLong or stuck or offRoute or g_time - backOff.time > 60000
    if done then
        plan.sectionBackOff = nil
        self.backOffLine = nil
        -- far enough: at the wait line (3 m), or, when the wait line is only the single track itself, at least 8 m
        -- before it, and off the way of the other one; still in the mouth, across the turn-off or on its way: the other
        -- one gives way instead (owner 25/10 21:35)
        local remaining = backOff.distance - reversed
        local farEnough = (remaining <= 3 or (backOff.where ~= "route" and remaining <= ADTrafficYieldModule.SECTION_WAIT_CLEAR - 8)) and backOff.clear == true
        if not farEnough and backOff.clear ~= true then
            self:log("back-off stopped after %.0f m, still on the way of %s", reversed, ADTrafficYieldModule.getName(self.partner))
            print(string.format("[AD-Croise] %s: recul arrete apres %.0f m, toujours sur le trajet de %s", ADTrafficYieldModule.getName(self.vehicle), reversed, ADTrafficYieldModule.getName(self.partner)))
        end
        if not farEnough then
            -- blocked behind (vehicle queue) before getting out of the mouth: classic manoeuvre, I park on the roadside
            self:log("back-off before the single track stopped after %.0f m of %.0f m", reversed, backOff.distance)
            -- owner 25/10 21:35: "if a car is right behind it, it goes first and the other one gives way":
            -- the vehicle in the single track backs out of my way, I drive in first
            if self:resolveStuckInMouth() then
                return true
            end
            print(string.format("[AD-Croise] %s: recul bloque apres %.0f m sur %.0f m, manoeuvre classique (je me range)", ADTrafficYieldModule.getName(self.vehicle), reversed, backOff.distance))
            local history = ADTrafficYieldModule.pairHistory[plan.pairKey] or {failures = 0, time = g_time}
            history.earlyTried = g_time
            ADTrafficYieldModule.pairHistory[plan.pairKey] = history
            self:endPlan("back-off blocked, fall back to the standard manoeuvre", nil)
            return false
        end
        -- off the shared way: wait here like a yielder that stopped before the single track
        plan.waitBeforeSection = true
        plan.parked = true
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:log("backed off %.0f m of %.0f m before the single track%s, %s may come out", reversed, backOff.distance,
            blockedTooLong and " (blocked behind)" or "", ADTrafficYieldModule.getName(self.partner))
        print(string.format("[AD-Croise] %s: recule de %.0f m sur %.0f m avant le chemin unique%s, %s peut sortir", ADTrafficYieldModule.getName(self.vehicle),
            reversed, backOff.distance, blockedTooLong and " (bloque derriere)" or "", ADTrafficYieldModule.getName(self.partner)))
        self:holdVehicle(dt)
        return true
    end
    -- stop first (it may still roll into the mouth), then reverse
    if not backOff.stopped then
        self:holdVehicle(dt)
        if ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1 then
            backOff.stopped = true
        end
        return true
    end
    if self:reverseTowards(dt, target) then
        if target.routeIndex ~= nil then
            self.reachedRouteIndex = target.routeIndex
        end
        self.reverseTargetIndex = self.reverseTargetIndex + 1
    end
    return true
end

-- the node where my route turns off (a node with two ways out) last before the single track, as a signed
-- distance along my route from my position (negative: already behind me, searched up to 40 m back), nil if none
function ADTrafficYieldModule:findTurnOffBeforeSection()
    local section = self.earlySection
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if section == nil or section[1] == nil or wayPoints == nil or currentIndex == nil or ADGraphManager == nil then
        return nil
    end
    -- 28/10: on a two-way track every point has two outs (on and back): only a way other than my previous and next
    -- point makes a branch (the turn-off was found 4 m before the section, inside the farm track)
    local function isBranch(wp, i)
        if wp == nil or wp.id == nil or wp.id == section[1] then
            return false
        end
        local node = ADGraphManager:getWayPointById(wp.id)
        if node == nil or node.out == nil or #node.out < 2 then
            return false
        end
        local prevId = wayPoints[i - 1] ~= nil and wayPoints[i - 1].id or nil
        local nextId = wayPoints[i + 1] ~= nil and wayPoints[i + 1].id or nil
        for _, id in ipairs(node.out) do
            if id ~= prevId and id ~= nextId then
                return true
            end
        end
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    -- ahead, up to the start of the single track
    local found, foundIndex = nil, nil
    local lastX, lastZ, distance = x, z, 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if wp.id == section[1] then
            break
        end
        if isBranch(wp, i) then
            found, foundIndex = distance, i
        end
        if distance > ADTrafficYieldModule.ANTICIPATION_DISTANCE then
            break
        end
    end
    if found ~= nil then
        return found, foundIndex
    end
    -- behind me (I am already in the turn)
    lastX, lastZ, distance = x, z, 0
    for i = currentIndex - 1, 1, -1 do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if distance > 40 then
            break
        end
        if isBranch(wp, i) then
            return -distance, i
        end
    end
    return nil
end

-- owner 26/10 17:28 ("instead of reversing it should have gone on along the way in front of it, if possible"):
-- the yielder is at the turn-off into the single track and cannot wait before it: it drives straight on along the
-- other branch of the junction, AutoDrive brings it back to its destination afterwards. Returns true when the route
-- was changed. probe: nothing is changed, returns true, the extra length and a function that takes that way
-- allowBehind (owner 28/10 20:18, only when I cannot reverse: "s'il ne peut pas reculer il va ailleurs et revient plus tard"):
-- also when the junction is already under me
function ADTrafficYieldModule:tryStraightOn(turnOffIndex, probe, allowBehind)
    local drivePathModule = self.vehicle.ad.drivePathModule
    local wayPoints, currentIndex = drivePathModule:getWayPoints()
    if turnOffIndex == nil or wayPoints == nil or currentIndex == nil or ADGraphManager == nil or self.partner == nil then
        return false
    end
    local junction, towardsTrack, before, lastWp = wayPoints[turnOffIndex], wayPoints[turnOffIndex + 1], wayPoints[turnOffIndex - 1], wayPoints[#wayPoints]
    if junction == nil or junction.id == nil or towardsTrack == nil or lastWp == nil or lastWp.id == nil then
        return false
    end
    -- owner 28/10 20:18: also when the junction is already under me (Jaguar at 1672, junction 9 m behind): I take the
    -- way straight on as long as a point of it lies ahead of my front within reach of the steering
    local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local _, _, junctionLocalZ = AutoDrive.worldToLocal(self.vehicle, junction.x, junction.y, junction.z)
    local junctionAhead = junctionLocalZ >= myFront - 1
    if not junctionAhead and not allowBehind then
        return false
    end
    local node = ADGraphManager:getWayPointById(junction.id)
    if node == nil or node.out == nil then
        return false
    end
    local _, otherDist = ADTrafficYieldModule.collectRouteAhead(self.partner, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    if otherDist[junction.id] ~= nil then
        self:log("straight on at the junction: %s drives through that junction", ADTrafficYieldModule.getName(self.partner))
        return false
    end
    -- a step a -> b is refused only when the partner drives it the other way (b before a on its route): following
    -- the partner on the same one-way lane is no head-on (28/10: 7R out of the track by 6993 joins the road at 1675)
    local function against(a, b)
        return otherDist[b] ~= nil and (otherDist[a] == nil or otherDist[b] < otherDist[a])
    end
    -- incoming direction at the junction
    local inX, inZ
    if before ~= nil then
        local l = math.max(0.01, MathUtil.vector2Length(junction.x - before.x, junction.z - before.z))
        inX, inZ = (junction.x - before.x) / l, (junction.z - before.z) / l
    else
        inX, inZ = ADTrafficYieldModule.getDirection(self.vehicle)
    end
    -- the most straight-on branch that is neither the track nor the way I came from nor against the partner
    local best, bestDot = nil, -math.huge
    for _, outId in pairs(node.out) do
        local candidate = ADGraphManager:getWayPointById(outId)
        if candidate ~= nil and outId ~= towardsTrack.id and (before == nil or outId ~= before.id) and not against(junction.id, outId) then
            local l = math.max(0.01, MathUtil.vector2Length(candidate.x - junction.x, candidate.z - junction.z))
            local dot = ((candidate.x - junction.x) * inX + (candidate.z - junction.z) * inZ) / l
            if dot > bestDot then
                best, bestDot = candidate, dot
            end
        end
    end
    if best == nil or bestDot < 0.3 then
        self:log("straight on at the junction: no branch straight on")
        return false
    end
    -- follow that branch (first way out at each step), never against the partner; from 40 m on, the first point
    -- with a way back to my destination ends it (owner: "il va ailleurs et revient plus tard"), 400 m at most
    local chain = {best}
    local length = MathUtil.vector2Length(best.x - junction.x, best.z - junction.z)
    local current = best
    local path = nil
    local nextTry = 40
    local tries = 0
    while length < 400 and tries < 16 do
        if length >= nextTry then
            tries = tries + 1
            nextTry = length + 25
            local ok, result = pcall(ADGraphManager.pathFromTo, ADGraphManager, current.id, lastWp.id, {})
            if ok and result ~= nil and #result >= 2 and result[1].id == current.id and result[#result].id == lastWp.id then
                path = result
                break
            end
        end
        local graphNode = ADGraphManager:getWayPointById(current.id)
        if graphNode == nil or graphNode.out == nil or #graphNode.out < 1 then
            break
        end
        local nextWp = ADGraphManager:getWayPointById(graphNode.out[1])
        if nextWp == nil or against(current.id, nextWp.id) or nextWp.id == junction.id then
            break
        end
        table.insert(chain, nextWp)
        length = length + MathUtil.vector2Length(nextWp.x - current.x, nextWp.z - current.z)
        current = nextWp
    end
    if path == nil and length >= 15 then
        local ok, result = pcall(ADGraphManager.pathFromTo, ADGraphManager, current.id, lastWp.id, {})
        if ok and result ~= nil and #result >= 2 and result[1].id == current.id and result[#result].id == lastWp.id then
            path = result
        end
    end
    if path == nil then
        self:log("straight on at the junction: no way back to my destination within %.0f m", length)
        return false
    end
    -- where I start on the new route: unchanged when the junction is still ahead, otherwise the first point of the
    -- straight-on way ahead of my front that I reach turning no tighter than my train can (radius of the arc from me
    -- to the point: distance / (2 sin angle)), 80 deg off my heading at most
    local startIndex = currentIndex
    if not junctionAhead then
        startIndex = nil
        local radius = math.max(8, ADTrafficYieldModule.getTrainRadius(self.vehicle) or 0)
        for k, wp in ipairs(chain) do
            local lx, _, lz = AutoDrive.worldToLocal(self.vehicle, wp.x, wp.y, wp.z)
            local angle = math.abs(math.atan2(lx, lz))
            local d = MathUtil.vector2Length(lx, lz)
            if lz >= myFront + 2 and angle <= math.rad(80) and (angle < 0.01 or d / (2 * math.sin(angle)) >= radius) then
                startIndex = turnOffIndex + k
                break
            end
        end
        if startIndex == nil then
            self:log("straight on at the junction: the junction is behind me and the way straight on is out of reach")
            return false
        end
    end
    local newWayPoints = {}
    for k = 1, turnOffIndex do
        newWayPoints[k] = wayPoints[k]
    end
    for _, wp in ipairs(chain) do
        table.insert(newWayPoints, wp)
    end
    for k = 2, #path do
        table.insert(newWayPoints, path[k])
    end
    local extra = ADTrafficYieldModule.getPathLength(newWayPoints, startIndex) - ADTrafficYieldModule.getPathLength(wayPoints, currentIndex)
    local function apply()
        drivePathModule.wayPoints = newWayPoints
        drivePathModule:setCurrentWayPointIndex(startIndex)
        drivePathModule.minDistanceToNextWp = math.huge
        self:log("at the turn-off into the single track: I drive straight on and come back later (%.0f m more), %s comes out first", math.max(extra, 0), ADTrafficYieldModule.getName(self.partner))
        print(string.format("[AD-Croise] %s: a l'embranchement du chemin unique, je continue tout droit et je reviens apres (%.0f m de plus), %s sort d'abord",
            ADTrafficYieldModule.getName(self.vehicle), math.max(extra, 0), ADTrafficYieldModule.getName(self.partner)))
    end
    if probe then
        return true, math.max(extra, 0), apply
    end
    apply()
    return true, math.max(extra, 0)
end

-- point of my route 'distance' metres ahead of my position (world x, z), nil when the route is shorter
function ADTrafficYieldModule:getRoutePointAhead(distance)
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return nil
    end
    local lastX, _, lastZ = ADTrafficYieldModule.getPosition(self.vehicle)
    local travelled = 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        local seg = MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        if travelled + seg >= distance and seg > 0.01 then
            local t = (distance - travelled) / seg
            return {x = lastX + (wp.x - lastX) * t, y = wp.y, z = lastZ + (wp.z - lastZ) * t}
        end
        travelled = travelled + seg
        lastX, lastZ = wp.x, wp.z
    end
    return nil
end

-- first node of the head-on section on my route (world position), nil when not found
function ADTrafficYieldModule:findSectionStart()
    local section = self.earlySection
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if section == nil or section[1] == nil or wayPoints == nil or currentIndex == nil then
        return nil
    end
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp ~= nil and wp.id == section[1] then
            return {x = wp.x, z = wp.z, id = wp.id}
        end
    end
    return nil
end

-- I already drive on the way of the partner (the two waypoints behind me are on its route): I am inside the
-- single track, not in its mouth, a short reverse would not get me out of it
function ADTrafficYieldModule:isInsideSection()
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil or self.partner == nil then
        return false
    end
    local _, otherDist = ADTrafficYieldModule.collectRouteAhead(self.partner, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    local behind1, behind2 = wayPoints[currentIndex - 1], wayPoints[currentIndex - 2]
    return behind1 ~= nil and behind2 ~= nil and behind1.id ~= nil and behind2.id ~= nil and otherDist[behind1.id] ~= nil and otherDist[behind2.id] ~= nil
end

-- the partner (the vehicle coming out of the single track) is clear of its entrance, trailer included
function ADTrafficYieldModule:isPartnerClearOfSection()
    local start = self.plan.sectionStart
    if start == nil or self.partner == nil then
        return true
    end
    -- S6 (owner 28/10 17:42, go 17:01: "partner out" while the 6205 TTV was still 100 m up the farm track): out only once
    -- the partner has passed the entrance point on its own route
    if start.id ~= nil and self.partner.ad ~= nil and self.partner.ad.drivePathModule ~= nil then
        local wps, idx = self.partner.ad.drivePathModule:getWayPoints()
        if wps ~= nil and idx ~= nil then
            local qx, _, qz = ADTrafficYieldModule.getPosition(self.partner)
            local distance = 0
            for i = math.max(1, idx), #wps do
                local wp = wps[i]
                if wp == nil then
                    break
                end
                distance = distance + MathUtil.vector2Length(wp.x - qx, wp.z - qz)
                qx, qz = wp.x, wp.z
                if distance > ADTrafficYieldModule.S6_LOOK_AHEAD then
                    break
                end
                if wp.id == start.id then
                    return false
                end
            end
        end
    end
    local px, _, pz = ADTrafficYieldModule.getPosition(self.partner)
    local _, partnerRear = ADTrafficYieldModule.getTrainExtents(self.partner)
    -- past the entrance in its own direction of travel (still inside the track: the entrance is ahead of it)
    local dx, dz = ADTrafficYieldModule.getDirection(self.partner)
    return (px - start.x) * dx + (pz - start.z) * dz > partnerRear + 8
end

-- the part of the remaining route of the partner that is off the network (pathfinder lead-in: exit of a field, detour):
-- those points have no id, the route comparison cannot see them, the single track may begin before its first network
-- point and run over the place where I wait (owner 26/10 18:00, Puma 240 CVX nose to nose with the 6205 TTV leaving its
-- field). True when my train (front, centre, rear) is within passing distance of one of those segments.
-- (network lanes side by side are never compared here: two lanes of a road are closer than that and are fine)
-- extra: more room asked (m), e.g. before ending the plan (the sensors stop both earlier than the routes touch)
function ADTrafficYieldModule:isOnPartnerOffNetworkWay(extra)
    local partner = self.partner
    if partner == nil or partner.ad == nil or partner.ad.drivePathModule == nil then
        return false
    end
    local wayPoints, currentIndex = partner.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return false
    end
    local px, _, pz = ADTrafficYieldModule.getPosition(partner)
    local points = {{x = px, z = pz, off = not partner.ad.drivePathModule:isOnRoadNetwork()}}
    local distance = 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        local last = points[#points]
        distance = distance + MathUtil.vector2Length(wp.x - last.x, wp.z - last.z)
        table.insert(points, {x = wp.x, z = wp.z, off = wp.id == nil})
        if distance > 150 then
            break
        end
    end
    local segments = {}
    for k = 1, #points - 1 do
        if points[k].off or points[k + 1].off then
            table.insert(segments, {points[k], points[k + 1]})
        end
    end
    if #segments == 0 then
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(self.vehicle)
    local myFront, myRear = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local margin = AutoDrive.getSetting("trafficYieldMargin") or ADTrafficYieldModule.LATERAL_MARGIN
    local needed = (ADTrafficYieldModule.getWidth(self.vehicle) + ADTrafficYieldModule.getWidth(partner)) / 2 + margin + 1 + (extra or 0)
    for _, f in ipairs({myFront, 0, -myRear}) do
        local tx, tz = x + dirX * f, z + dirZ * f
        for _, seg in ipairs(segments) do
            if ADTrafficYieldModule.distanceToPolyline(seg, tx, tz) < needed then
                return true
            end
        end
    end
    return false
end

-- the partner came out and stopped right in front of me (its sensor sees me): I am on its way, whatever the routes say
function ADTrafficYieldModule:isPartnerStoppedInFront(dt)
    local partner = self.partner
    if partner == nil then
        return false
    end
    local px, py, pz = ADTrafficYieldModule.getPosition(partner)
    local localX, _, localZ = AutoDrive.worldToLocal(self.vehicle, px, py, pz)
    local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local partnerFront = ADTrafficYieldModule.getTrainExtents(partner)
    -- 26/10 20:00 (7R 350 in a bend, MT635 stopped against it at an angle: not seen as "in front"): a cone ahead of me,
    -- not a corridor
    local gap = MathUtil.vector2Length(localX, localZ) - myFront - partnerFront
    local inFront = localZ > 0 and gap < 12 and math.abs(localX) < math.max(4, localZ * 0.7) and ADTrafficYieldModule.getSpeedKmh(partner) < 1
    self.partnerStoppedTimer = self.partnerStoppedTimer or AutoDriveTON:new()
    return self.partnerStoppedTimer:timer(inFront, 3000, dt)
end

-- S2: out of the single track but still coming at me: not done (logged once)
function ADTrafficYieldModule:isPartnerStillComing()
    local coming, how = self:isPartnerComingAtMe(false)
    if coming and not self.comingAtMeLogged then
        self.comingAtMeLogged = true
        self:log("%s is out of the single track but %s: not done yet", ADTrafficYieldModule.getName(self.partner),
            how == "route" and "its route runs over me" or "it drives at me")
        print(string.format("[AD-Croise] %s: %s est sorti du chemin unique mais %s, le croisement n'est pas fini", ADTrafficYieldModule.getName(self.vehicle),
            ADTrafficYieldModule.getName(self.partner), how == "route" and "son trajet passe sur moi" or "il vient droit sur moi"))
    end
    return coming
end

-- the yielder waits on its road SECTION_WAIT_CLEAR m before the single track until the other one is out of it
function ADTrafficYieldModule:updateSectionWait(dt)
    local plan = self.plan
    local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local remaining
    if plan.waitPoint ~= nil then
        local _, _, localZ = AutoDrive.worldToLocal(self.vehicle, plan.waitPoint.x, plan.waitPoint.y or 0, plan.waitPoint.z)
        remaining = localZ - myFront
        -- (its way out may still run over my place after its last network point of the single track: wait until it is past)
        if self.earlyGap == nil and self:isPartnerClearOfSection() and not self:isOnPartnerOffNetworkWay(8) and not self:isPartnerStillComing() then
            self:endPlan("partner out of the single track", true)
            return false
        end
    elseif self.earlyGap ~= nil then
        local elapsed = (g_time - (self.earlyGapTime or g_time)) / 1000
        remaining = (self.earlySectionMine or 0) - myFront - ADTrafficYieldModule.SECTION_WAIT_CLEAR - ADTrafficYieldModule.getSpeedKmh(self.vehicle) / 3.6 * elapsed
    else
        local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
        remaining = MathUtil.vector2Length(plan.sectionStart.x - x, plan.sectionStart.z - z) - myFront - ADTrafficYieldModule.SECTION_WAIT_CLEAR
        if self:isPartnerClearOfSection() and not self:isOnPartnerOffNetworkWay(8) and not self:isPartnerStillComing() then
            self:endPlan("partner out of the single track", true)
            return false
        end
    end
    -- stopped short of the wait line by something else (sensor: the other one already at the mouth, 26/10 18:00):
    -- I am waiting anyway, go on as if parked (the nose to nose rule below may back me off)
    self.waitStoppedTimer = self.waitStoppedTimer or AutoDriveTON:new()
    local stoppedShort = self.waitStoppedTimer:timer(not plan.parked and remaining > 0.5 and ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1, 3000, dt)
    if remaining > 0.5 and not plan.parked and not stoppedShort then
        local allowedSpeed = math.sqrt(2 * ADTrafficYieldModule.ANTICIPATION_DECEL * remaining) * 3.6
        local drivePathModule = self.vehicle.ad.drivePathModule
        if drivePathModule.speedLimit ~= nil then
            drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, math.max(allowedSpeed, 3))
        end
        return false
    end
    -- stopped before the single track: off the shared way, the other one may drive through
    if not plan.parked then
        self:log("waiting before the single track%s (%.1f m to the wait point%s), %s may come out", stoppedShort and string.format(" (stopped %.0f m short of the line)", remaining) or "",
            remaining, plan.waitPoint ~= nil and "" or ", no wait point", ADTrafficYieldModule.getName(self.partner))
    end
    plan.parked = true
    -- owner 26/10 18:00: the wait line comes from the network points, the other one may still have to drive over my place
    -- (pathfinder lead-in before its first network point): once it is close, check that my train is off its remaining route,
    -- else back off some more (once)
    do
        local reason = nil
        -- nose to nose: at most twice (it may be stopped by something else, a crossing, a third vehicle)
        if self:isPartnerStoppedInFront(dt) then
            if (plan.noseBackOffs or 0) < 2 then
                plan.noseBackOffs = (plan.noseBackOffs or 0) + 1
                reason = "stopped nose to nose with me"
            end
        elseif g_time >= (plan.nextWaitClearCheck or 0) then
            plan.nextWaitClearCheck = g_time + 1000
            local px, _, pz = ADTrafficYieldModule.getPosition(self.partner)
            local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
            if MathUtil.vector2Length(px - x, pz - z) < 60 and (self:isOnPartnerOffNetworkWay() or self:isPartnerComingAtMe(true)) then
                reason = "its way out runs over my place"
            end
        end
        if reason ~= nil and ADTrafficYieldModule.cannotReverse(self.vehicle) then
            -- A1: I never reverse: the other one backs out of my way, else the standard manoeuvre (it reverses, I park)
            self:logCannotReverse(self.partner)
            if self:resolveStuckInMouth("articulated trailer, I do not back off", "remorque articulee, je ne recule pas") then
                return true
            end
            local history = ADTrafficYieldModule.pairHistory[plan.pairKey] or {failures = 0, time = g_time}
            history.earlyTried = g_time
            ADTrafficYieldModule.pairHistory[plan.pairKey] = history
            self:endPlan("header trailer on the way of the partner, fall back to the standard manoeuvre", nil)
            return false
        end
        if reason ~= nil then
            plan.extraBackOff = (plan.extraBackOff or 0) + 10
            if plan.extraBackOff > ADTrafficYieldModule.SECTION_BACKOFF_MAX then
                -- reversing does not get me off its way: it backs out of the single track instead, or the standard manoeuvre
                self:log("still on the way of %s after %d m more: I give up backing off", ADTrafficYieldModule.getName(self.partner), plan.extraBackOff - 10)
                print(string.format("[AD-Croise] %s: toujours sur le trajet de %s apres %d m de recul en plus, j'arrete de reculer", ADTrafficYieldModule.getName(self.vehicle),
                    ADTrafficYieldModule.getName(self.partner), plan.extraBackOff - 10))
                if self:resolveStuckInMouth("still on its way after backing off", "toujours sur son trajet apres le recul") then
                    return true
                end
                local history = ADTrafficYieldModule.pairHistory[plan.pairKey] or {failures = 0, time = g_time}
                history.earlyTried = g_time
                ADTrafficYieldModule.pairHistory[plan.pairKey] = history
                self:endPlan("still on the way of the partner after backing off, fall back to the standard manoeuvre", nil)
                return false
            end
            plan.sectionBackOff = {distance = 10, where = plan.waitWhere or "chemin", extra = true}
            self.reverseTargets = nil
            self:log("%s %s: I back off 10 m more", ADTrafficYieldModule.getName(self.partner), reason)
            print(string.format("[AD-Croise] %s: %s, je recule encore de 10 m", ADTrafficYieldModule.getName(self.vehicle),
                reason == "stopped nose to nose with me" and (ADTrafficYieldModule.getName(self.partner) .. " s'est arrete nez a nez avec moi") or ("le trajet de sortie de " .. ADTrafficYieldModule.getName(self.partner) .. " passe sur ma place")))
            return self:updateSectionBackOff(dt)
        end
    end
    self:holdVehicle(dt)
    if self.stateTimer:timer(true, 120000, dt) then
        self:endPlan("wait before the single track: timeout", false)
    end
    return true
end

-- a spot in the two-way track that I (the one inside) reach by backing up along my route, REVERSE_SEARCH_MAX m at most,
-- for 'other' to pass (driving side, SPOT_MOUTH_CLEAR m from the mouths, the other whole train passes beside).
-- Returns the spot and the length I would reverse (0 when it is in front of me), nil without one
function ADTrafficYieldModule:searchSpotBehind(other)
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return nil
    end
    -- as far back as the two-way track goes, REVERSE_SEARCH_MAX m at most
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local fromIndex, behind = nil, 0
    local lastX, lastZ = x, z
    for i = currentIndex - 1, 1, -1 do
        local wp, nextWp = wayPoints[i], wayPoints[i + 1]
        if wp == nil or nextWp == nil or wp.id == nil or nextWp.id == nil or not ADTrafficYieldModule.isTwoWay(wp.id, nextWp.id) then
            break
        end
        local d = MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        if behind + d > ADTrafficYieldModule.REVERSE_SEARCH_MAX then
            break
        end
        behind = behind + d
        lastX, lastZ = wp.x, wp.z
        fromIndex = i
    end
    if fromIndex == nil then
        fromIndex, behind = currentIndex, 0
    end
    local ox, _, oz = ADTrafficYieldModule.getPosition(other)
    local gap = MathUtil.vector2Length(ox - x, oz - z)
    local savedPartner = self.partner
    self.partner = other
    self.spotTwoWayOnly = true
    local ok, spot = pcall(self.searchSpotBySides, self, behind + gap, true, fromIndex)
    self.spotTwoWayOnly = nil
    self.partner = savedPartner
    if not ok then
        Logging.error("[AD] ADTrafficYieldModule: spot search behind failed: %s", tostring(spot))
        return nil
    end
    if spot == nil then
        return nil
    end
    return spot, math.max(0, behind - (spot.entryDistance or 0) + 5)
end

-- owner 25/10 21:35, kept by the owner 28/10 18:14 as the exceptional last resort, and 18:13 ("la regle vaut si on est sur
-- de pouvoir se stationner dans la double voie ; si un detour est possible on peut l'emprunter aussi ; plusieurs calculs
-- en simultane"): I am in the mouth of the two-way track and cannot back off (vehicle right behind me, articulated train).
-- Both ways out are computed: a sure spot in the track for the other one (it backs up and pulls over, I go first) and a
-- detour for me (straight on at the turn-off, or another way); the one that loses the least time is taken.
-- Returns true when one of them started, false: standard manoeuvre
function ADTrafficYieldModule:resolveStuckInMouth(why, whyFr)
    local plan = self.plan
    local other = self.partner
    if other == nil or plan == nil or plan.sectionCleared or other.ad == nil or other.ad.trafficYieldModule == nil then
        return false
    end
    local myName, otherName = ADTrafficYieldModule.getName(self.vehicle), ADTrafficYieldModule.getName(other)
    local otherModule = other.ad.trafficYieldModule
    local spot, reverseLength = nil, nil
    local spotWhy = nil
    if ADTrafficYieldModule.cannotReverse(other) then
        spotWhy = "remorque articulee"
    elseif ADTrafficYieldModule.hasFollowerBehind(other, 20, self.vehicle) then
        spotWhy = "vehicule derriere lui"
    else
        spot, reverseLength = otherModule:searchSpotBehind(self.vehicle)
        if spot == nil then
            spotWhy = "aucune place sure"
        end
    end
    local detourExtra, applyDetour = nil, nil
    local _, turnOffIndex = self:findTurnOffBeforeSection()
    local okStraight, extraStraight, applyStraight = self:tryStraightOn(turnOffIndex, true, true)
    if okStraight then
        detourExtra, applyDetour = extraStraight, applyStraight
    end
    local okDetour, extraDetour, applyOther = self:tryDetour(other, nil, true)
    if okDetour and (detourExtra == nil or extraDetour < detourExtra) then
        detourExtra, applyDetour = extraDetour, applyOther
    end
    local clearTime = spot ~= nil and (reverseLength / (ADTrafficYieldModule.REVERSE_SPEED / 3.6) + 20) or nil
    local detourTime = detourExtra ~= nil and detourExtra / (ADTrafficYieldModule.DETOUR_ROAD_SPEED / 3.6) or nil
    print(string.format("[AD-Croise] %s: %s : place sure pour %s dans le chemin : %s ; detour pour moi : %s",
        myName, whyFr or "recul impossible (vehicule colle derriere)", otherName,
        spot ~= nil and string.format("oui, %.0f m de recul (%.0f s)", reverseLength, clearTime) or ("non, " .. tostring(spotWhy)),
        detourTime ~= nil and string.format("oui, %.0f m de plus (%.0f s)", detourExtra, detourTime) or "non"))
    if clearTime ~= nil and (detourTime == nil or clearTime <= detourTime) then
        return self:startSectionClear(why, whyFr)
    end
    if detourTime ~= nil then
        applyDetour()
        plan.sectionBackOff = nil
        self.backOffLine = nil
        self.reverseTargets = nil
        plan.straightOn = true
        plan.waitBeforeSection = false
        plan.parked = true -- the other one drives on
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        print(string.format("[AD-Croise] %s: je prends le detour (%.0f m de plus), %s sort du chemin", myName, detourExtra, otherName))
        return true
    end
    -- neither: owner 28/10 20:18 (rule 8), the one in the track never reverses without a sure spot, I wait
    print(string.format("[AD-Croise] %s: ni place sure pour %s ni detour : j'attends, %s ne recule pas sans place sure", myName, otherName, otherName))
    return false
end

-- I am stuck in the mouth of the single track (vehicle queue behind me): roles swapped, the partner in the
-- single track reverses along its own route until it is off my way (or parks beside the track), I drive in first
function ADTrafficYieldModule:startSectionClear(why, whyFr)
    local plan = self.plan
    local other = self.partner
    if other == nil or plan == nil or plan.sectionCleared then
        return false
    end
    if ADTrafficYieldModule.hasFollowerBehind(other, 20, self.vehicle) then
        return false
    end
    plan.sectionCleared = true
    plan.mode = "sectionClear"
    plan.reverser, plan.parker = self.vehicle, other -- I drive on (REVERSER_PASS), it gets off the way
    plan.parked = false
    plan.waitBeforeSection = nil
    plan.reverserMayStop = true
    self:log("%s: %s backs out of the single track, I go first", why or "back-off blocked behind me", ADTrafficYieldModule.getName(other))
    print(string.format("[AD-Croise] %s: %s : je passe d'abord, %s recule dans le chemin", ADTrafficYieldModule.getName(self.vehicle),
        whyFr or "recul impossible (vehicule colle derriere)", ADTrafficYieldModule.getName(other)))
    local otherModule = other.ad.trafficYieldModule
    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    other.ad.specialDrivingModule:releaseVehicle()
    otherModule.reverseTargets = nil
    self:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
    self:holdVehicle(0)
    otherModule:setState(ADTrafficYieldModule.STATE_SECTION_CLEAR)
    return true
end

-- the remaining route of a vehicle as a polyline (its position first), at most maxDistance metres
function ADTrafficYieldModule.getRoutePolyline(vehicle, maxDistance)
    local x, _, z = ADTrafficYieldModule.getPosition(vehicle)
    local points = {{x = x, z = z}}
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return points
    end
    local distance = 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        local last = points[#points]
        distance = distance + MathUtil.vector2Length(wp.x - last.x, wp.z - last.z)
        table.insert(points, {x = wp.x, z = wp.z})
        if distance > maxDistance then
            break
        end
    end
    return points
end

function ADTrafficYieldModule.distanceToPolyline(points, x, z)
    local best = math.huge
    for k = 1, #points - 1 do
        local a, b = points[k], points[k + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l2 = dx * dx + dz * dz
        local t = 0
        if l2 > 0.0001 then
            t = math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / l2))
        end
        best = math.min(best, MathUtil.vector2Length(x - (a.x + dx * t), z - (a.z + dz * t)))
    end
    if #points == 1 then
        best = MathUtil.vector2Length(x - points[1].x, z - points[1].z)
    end
    return best
end

-- my whole train (front, centre, rear) is far enough from the route the partner still has to drive
function ADTrafficYieldModule:isClearOfPartnerRoute()
    local partner = self.partner
    local route = ADTrafficYieldModule.getRoutePolyline(partner, ADTrafficYieldModule.SECTION_CLEAR_MAX + 100)
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(self.vehicle)
    local myFront, myRear = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local margin = AutoDrive.getSetting("trafficYieldMargin") or ADTrafficYieldModule.LATERAL_MARGIN
    local needed = (ADTrafficYieldModule.getWidth(self.vehicle) + ADTrafficYieldModule.getWidth(partner)) / 2 + margin + 1
    -- its route may end at the field entrance and go on into the field: keep 20 m more around that end
    local last = route[#route]
    for _, f in ipairs({myFront, 0, -myRear}) do
        local px, pz = x + dirX * f, z + dirZ * f
        if ADTrafficYieldModule.distanceToPolyline(route, px, pz) < needed or MathUtil.vector2Length(px - last.x, pz - last.z) < needed + 20 then
            return false
        end
    end
    return true
end

-- the vehicle in the single track backs out of the way of the one stuck in the mouth, then waits until it passed
function ADTrafficYieldModule:updateSectionClear(dt)
    local plan = self.plan
    if plan.parked then
        self:holdVehicle(dt)
        local partner = self.partner
        if self:hasPassedMe(partner) or not partner.ad.drivePathModule:isOnRoadNetwork() then
            plan.passed = true
            self:endPlan("the other one went through the single track", true)
            return
        end
        if self.stateTimer:timer(true, 120000, dt) then
            self:endPlan("single track clear: wait timeout", false)
        end
        return
    end
    if self.reverseTargets == nil then
        self.reverseTargets = self:buildReverseTargets(ADTrafficYieldModule.SECTION_CLEAR_MAX)
        self.reverseTargetIndex = 1
        local x, y, z = ADTrafficYieldModule.getPosition(self.vehicle)
        self.reverseStart = {x = x, y = y, z = z}
        self.clearStartTime = g_time
    end
    -- a free place beside the track (field): park there, the other one passes (roles of the standard plan)
    if self:tryOwnParkingSpot(dt) then
        return
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local reversed = MathUtil.vector2Length(x - self.reverseStart.x, z - self.reverseStart.z)
    local blockedBehind = self.vehicle.ad.collisionDetectionModule:checkReverseCollision()
    local blockedTooLong = self.reverseBlockedTimer:timer(blockedBehind, 8000, dt)
    if self:isReverseStuck() then
        blockedTooLong = true -- S3
    end
    local target = self.reverseTargets[self.reverseTargetIndex]
    local clear = self:isClearOfPartnerRoute()
    if clear or target == nil or blockedTooLong or reversed >= ADTrafficYieldModule.SECTION_CLEAR_MAX or g_time - self.clearStartTime > 150000 then
        plan.parked = true
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:holdVehicle(dt)
        self:log("backed %.0f m out of the single track (%s), %s goes through", reversed, clear and "off its way" or (blockedTooLong and "blocked behind" or "limit"),
            ADTrafficYieldModule.getName(self.partner))
        print(string.format("[AD-Croise] %s: recule de %.0f m dans le chemin (%s), %s passe", ADTrafficYieldModule.getName(self.vehicle), reversed,
            clear and "hors de son chemin" or (blockedTooLong and "bloque derriere" or "limite"), ADTrafficYieldModule.getName(self.partner)))
        return
    end
    if self:reverseTowards(dt, target) then
        if target.routeIndex ~= nil then
            self.reachedRouteIndex = target.routeIndex
        end
        self.reverseTargetIndex = self.reverseTargetIndex + 1
    end
end

function ADTrafficYieldModule:updateYielderApproach(dt)
    local plan = self.plan
    if plan.sectionBackOff ~= nil then
        return self:updateSectionBackOff(dt)
    end
    if plan.straightOn then
        -- driving away along the road: done once the other one is out of the single track (or no longer oncoming)
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        if self:isPartnerClearOfSection() then
            self:endPlan("partner out of the single track (straight on)", true)
        elseif self.stateTimer:timer(true, 120000, dt) then
            self:endPlan("straight on: timeout", true)
        end
        return false
    end
    -- the yielder gets most of the free distance to find a spot (the other one stops earlier)
    local holding, stopDistance = self:limitSpeedTowards(dt, self.partner, ADTrafficYieldModule.YIELDER_SHARE)
    if self.earlyGap == nil then
        -- waiting before the single track: the partner may still be in the mouth (its last node passed but its trailer
        -- not out yet, 25/10 21:00 and 21:08): keep waiting until it is clear of the entrance
        if plan.waitBeforeSection and plan.sectionStart ~= nil then
            return self:updateSectionWait(dt)
        end
        -- not oncoming any more (route changed): nothing to do. 28/10: the plan goes on through a single route comparison
        -- without the shared stretch (speeds changing, end of the 250 m look-ahead: the plan started again 4 times), 2 s in a
        -- row end it
        if self.noOncomingTimer:timer(true, 2000, dt) then
            self:endPlan("no more oncoming", nil)
            return false
        end
    else
        self.noOncomingTimer:timer(false)
    end

    -- owner 28/10 18:16 / 18:29: before driving onto the red line (Intersection) that leads into the two-way track I check the
    -- track; someone coming out, I stop at the point before the red line, no back-off. Without a red line: the wait line below
    if plan.waitBeforeSection == nil and self.earlySectionMine ~= nil then
        local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        local redLine = self:findRedLineBefore(self.earlySectionMine)
        local stopBefore = ADIntersectionModule ~= nil and ADIntersectionModule.STOP_BEFORE or 1
        if redLine ~= nil and redLine - stopBefore - myFront > -0.5 then
            local stopAt = math.max(redLine - stopBefore, myFront)
            plan.sectionStart = self:findSectionStart()
            plan.waitBeforeSection = true
            plan.redLine = true
            plan.waitWhere = "route"
            plan.waitPoint = self:getRoutePointAhead(stopAt)
            self:log("two-way track %.0f m ahead, red line at %.0f m: I wait before it, %s comes out first", self.earlySectionMine, redLine,
                ADTrafficYieldModule.getName(self.partner))
            print(string.format("[AD-Croise] %s: chemin a double sens %.0f m devant, ligne rouge a %.0f m : j'attends au point avant la ligne rouge, %s sort d'abord",
                ADTrafficYieldModule.getName(self.vehicle), self.earlySectionMine, redLine - myFront, ADTrafficYieldModule.getName(self.partner)))
        end
    end

    -- owner 25/10 19:01 (Puma 240 CVX waiting with its nose in the mouth of a single track, on the crossing, the 6205 TTV
    -- coming out of it held by the crossing): the single track starts ahead of me, I wait on my road
    -- SECTION_WAIT_CLEAR m before it, the other one comes out first, then I go
    if plan.waitBeforeSection == nil and self.earlySectionMine ~= nil then
        local myFront, myRear = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        plan.sectionStart = self:findSectionStart()
        -- where my front stops: SECTION_WAIT_CLEAR m before the single track; owner 26/10 17:23 (7R 350 stopped across the
        -- turn-off, trailer on the road "in the middle of the traffic": the single track started 15 m after the turn-off):
        -- when my whole train cannot wait between the turn-off and the single track, I wait on my road before the turn-off
        -- S1 (owner 27/10, go 28/10: the 942 Vario waited 11 m before the turn-off, the 7R 350 + Big Body turning out of the
        -- single track drove into it): the room left between the junction and my front is the length of the train coming
        -- out + EXIT_ROOM (at least SECTION_WAIT_CLEAR)
        local exitRoom = math.max(ADTrafficYieldModule.SECTION_WAIT_CLEAR, ADTrafficYieldModule.getTotalLength(self.partner) + ADTrafficYieldModule.EXIT_ROOM)
        plan.exitRoom = exitRoom
        local waitLine = self.earlySectionMine - exitRoom
        local turnOff, turnOffIndex = self:findTurnOffBeforeSection()
        local where = "chemin"
        -- the former line (15 m before the single track, 5 m before the turn-off), kept when the room asked would need a
        -- back-off longer than SECTION_BACKOFF_MAX (then no back-off at all would happen)
        local oldWaitLine = self.earlySectionMine - ADTrafficYieldModule.SECTION_WAIT_CLEAR
        local oldWhere = "chemin"
        if turnOff ~= nil and self.earlySectionMine - turnOff < myFront + myRear + ADTrafficYieldModule.SECTION_WAIT_CLEAR + 3 then
            local beforeTurnOff = turnOff - ADTrafficYieldModule.JUNCTION_GAP
            if beforeTurnOff < oldWaitLine then
                oldWaitLine = beforeTurnOff
                oldWhere = "route"
            end
        end
        if turnOff ~= nil and self.earlySectionMine - turnOff < myFront + myRear + exitRoom + 3 then
            local beforeTurnOff = turnOff - math.max(ADTrafficYieldModule.JUNCTION_GAP, exitRoom)
            if beforeTurnOff < waitLine then
                waitLine = beforeTurnOff
                where = "route"
            end
        end
        if waitLine - myFront <= 2 and myFront - waitLine > ADTrafficYieldModule.SECTION_BACKOFF_MAX then
            local capped = math.max(waitLine, math.min(oldWaitLine, myFront - ADTrafficYieldModule.SECTION_BACKOFF_MAX))
            if capped ~= waitLine then
                self:log("room of %.0f m for %s would need a back-off over %d m: wait line moved %.0f m forward", exitRoom,
                    ADTrafficYieldModule.getName(self.partner), ADTrafficYieldModule.SECTION_BACKOFF_MAX, capped - waitLine)
                waitLine = capped
                where = (turnOff ~= nil and waitLine < turnOff) and "route" or oldWhere
            end
        end
        plan.waitBeforeSection = waitLine - myFront > 2
        -- cannot wait before the turn-off any more: straight on along the road rather than reversing (owner 26/10 17:28)
        if not plan.waitBeforeSection and where == "route" and self:tryStraightOn(turnOffIndex) then
            plan.straightOn = true
            plan.waitBeforeSection = false
            plan.parked = true -- the other one drives on
            self.vehicle.ad.specialDrivingModule:releaseVehicle()
            return false
        end
        plan.waitWhere = where
        if plan.waitBeforeSection then
            plan.waitPoint = self:getRoutePointAhead(waitLine)
            self:log("single track %.0f m ahead (turn-off %s m): I wait with my front %.0f m ahead (%s), %s comes out first", self.earlySectionMine,
                turnOff ~= nil and string.format("%.0f", turnOff) or "-", waitLine, where, ADTrafficYieldModule.getName(self.partner))
            print(string.format("[AD-Croise] %s: chemin unique %.0f m devant (embranchement a %s m), j'attends l'avant a %.0f m (%s, %.0f m de place pour la sortie de %s), %s sort d'abord",
                ADTrafficYieldModule.getName(self.vehicle), self.earlySectionMine, turnOff ~= nil and string.format("%.0f", turnOff) or "-", waitLine,
                where == "route" and "sur ma route avant l'embranchement" or "avant le chemin unique", exitRoom, ADTrafficYieldModule.getName(self.partner),
                ADTrafficYieldModule.getName(self.partner)))
        else
            -- owner 25/10 21:20 (942 Vario stopped across the mouth of the single track, the Puma 240 CVX coming out of it,
            -- "it waits too close, back it up"): already in the mouth, I back off along my route to the wait line
            local frontDistance = self.earlySectionMine - myFront
            local distance = myFront - waitLine
            if plan.sectionStart ~= nil and frontDistance > -ADTrafficYieldModule.SECTION_BACKOFF_INSIDE and distance <= ADTrafficYieldModule.SECTION_BACKOFF_MAX
                and not self:isInsideSection() and ADTrafficYieldModule.cannotReverse(self.vehicle) then
                -- A1: too close but I never reverse: the other one backs out of the single track, I go first
                self:logCannotReverse(self.partner)
                if self:resolveStuckInMouth("articulated trailer, I do not back off", "remorque articulee, je ne recule pas") then
                    return true
                end
            elseif plan.sectionStart ~= nil and frontDistance > -ADTrafficYieldModule.SECTION_BACKOFF_INSIDE and distance <= ADTrafficYieldModule.SECTION_BACKOFF_MAX
                and not self:isInsideSection() then
                plan.sectionBackOff = {distance = math.max(distance, 3), where = where}
                print(string.format("[AD-Croise] %s: embranchement a %s m, ligne d'attente a %.0f m", ADTrafficYieldModule.getName(self.vehicle),
                    turnOff ~= nil and string.format("%.0f", turnOff) or "-", waitLine))
                self:log("single track %.0f m ahead (front at %.0f m): too close, I back off %.0f m, %s comes out first", self.earlySectionMine, frontDistance,
                    plan.sectionBackOff.distance, ADTrafficYieldModule.getName(self.partner))
                print(string.format("[AD-Croise] %s: chemin unique a %.0f m (avant a %.0f m), trop pres : je recule de %.0f m, %s sort d'abord", ADTrafficYieldModule.getName(self.vehicle),
                    self.earlySectionMine, frontDistance, plan.sectionBackOff.distance, ADTrafficYieldModule.getName(self.partner)))
                return self:updateSectionBackOff(dt)
            end
        end
    end
    if plan.waitBeforeSection and plan.parkSpot == nil then
        return self:updateSectionWait(dt)
    end

    if plan.parkSpot == nil then
        if g_time - self.lastSearchTime >= ADTrafficYieldModule.SEARCH_INTERVAL and stopDistance ~= nil then
            self.lastSearchTime = g_time
            -- the whole stretch on the right first, the left side only as a last resort
            plan.parkSpot = self:searchSpotBySides(stopDistance + 2, true)
            if plan.parkSpot ~= nil then
                self:log("early spot found: side=%s at %.0f m, field=%s", plan.parkSpot.side, plan.parkSpot.entryDistance, tostring(plan.parkSpot.onField))
            end
        end
        -- stopped by something else (sensor, crossing) without any spot ahead: waiting for the plan timeout
        -- would block both for 3 min (owner 25/10 21:20)
        local stoppedTooLong = self.yielderStoppedTimer:timer(ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1, ADTrafficYieldModule.YIELDER_STOPPED_FALLBACK, dt)
        if plan.parkSpot == nil and (holding or stoppedTooLong) then
            -- stopped without any spot ahead: classic manoeuvre (reverse + roadside / side branch)
            local history = ADTrafficYieldModule.pairHistory[plan.pairKey] or {failures = 0, time = g_time}
            history.earlyTried = g_time
            ADTrafficYieldModule.pairHistory[plan.pairKey] = history
            self:endPlan("no spot ahead, fall back to the standard manoeuvre", nil)
            return false
        end
        return holding
    end

    -- drive normally along the route until the leaving point, then swerve into the spot
    local spot = plan.parkSpot
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local _, _, entryLocalZ = AutoDrive.worldToLocal(self.vehicle, spot.entryX, spot.y, spot.entryZ)
    if entryLocalZ < 2 or MathUtil.vector2Length(spot.entryX - x, spot.entryZ - z) < 3 then
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:setState(ADTrafficYieldModule.STATE_PARKER_MOVE)
        return false
    end
    -- slow down so the swerve starts at park speed (no skid into the ditch at full speed)
    local parkSpeed = ADTrafficYieldModule.PARK_SPEED / 3.6
    local allowedSpeed = math.sqrt(parkSpeed * parkSpeed + 2 * ADTrafficYieldModule.ANTICIPATION_DECEL * math.max(entryLocalZ - 2, 0)) * 3.6
    local drivePathModule = self.vehicle.ad.drivePathModule
    if drivePathModule.speedLimit ~= nil then
        drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, allowedSpeed)
    end
    if holding then
        -- the spot is known and the partner waits until we are parked: never stop before reaching it
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:ensureMotorStarted()
    end
    return false
end

function ADTrafficYieldModule:updatePriorityApproach(dt)
    local plan = self.plan
    if plan.parked then
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:setState(ADTrafficYieldModule.STATE_REVERSER_PASS)
        return false
    end
    -- owner 30/10 16:37 (C): while the other one finishes lining up, I stay PASS_GAP m from its front
    local parker = self.partner
    if plan.parkSpot ~= nil and parker ~= nil and parker.components ~= nil then
        local px, py, pz = ADTrafficYieldModule.getPosition(parker)
        local _, _, parkerLocalZ = AutoDrive.worldToLocal(self.vehicle, px, py, pz)
        local parkerFront = ADTrafficYieldModule.getTrainExtents(parker)
        local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        if parkerLocalZ > 0 and parkerLocalZ - parkerFront - myFront <= ADTrafficYieldModule.PASS_GAP then
            if not plan.passGapLogged then
                plan.passGapLogged = true
                self:log("%s not lined up yet: I wait %d m from it", ADTrafficYieldModule.getName(parker), ADTrafficYieldModule.PASS_GAP)
            end
            self:holdVehicle(dt)
            return true
        end
    end
    -- keep the safe stopping distance until the other one has pulled over
    local holding = self:limitSpeedTowards(dt, self.partner, 1 - ADTrafficYieldModule.YIELDER_SHARE)
    -- once the roadside spot is known, stop before the end of its path so the other train can line up completely
    local spot = plan.parkSpot
    if not holding and spot ~= nil and spot.aimX ~= nil then
        local _, _, aimLocalZ = AutoDrive.worldToLocal(self.vehicle, spot.aimX, spot.y, spot.aimZ)
        local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        local free = aimLocalZ - myFront - ADTrafficYieldModule.SPOT_CLEARANCE
        if aimLocalZ > 0 and free <= 0.5 then
            self:holdVehicle(dt)
            return true
        elseif aimLocalZ > 0 then
            local allowedSpeed = math.sqrt(2 * ADTrafficYieldModule.ANTICIPATION_DECEL * free) * 3.6
            local drivePathModule = self.vehicle.ad.drivePathModule
            if drivePathModule.speedLimit ~= nil then
                drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, math.max(allowedSpeed, 3))
            end
        end
    end
    return holding
end

------------------------------------------------------------------------------------------------
-- detection
------------------------------------------------------------------------------------------------

function ADTrafficYieldModule:checkForHeadOnDeadlock(dt, obstacleDetected)
    local isStopped = ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1
    local onRoad = self.vehicle.ad.drivePathModule:isOnRoadNetwork()
    local delay = (AutoDrive.getSetting("trafficYieldDelay") or 5) * 1000

    local blockedLongEnough = self.blockedTimer:timer(obstacleDetected and isStopped and onRoad and g_time >= self.cooldownUntil, delay, dt)
    if not blockedLongEnough then
        return
    end
    if (g_updateLoopIndex % AutoDrive.PERF_FRAMES) ~= 0 then
        return
    end

    if ADTrafficYieldModule.intersectionHasPriority(self.vehicle) then
        return -- engaged on a red section: the crossing decides (wait or go), owner 26/10 21:46
    end
    local other = self:findHeadOnPartner()
    if other ~= nil and not ADTrafficYieldModule.intersectionHasPriority(other) then
        -- 27/10 06:49 (owner): nose to nose, before anybody reverses, either of us takes another lane when there is one
        local otherModule = other.ad.trafficYieldModule
        if self:tryDetour(other) or (otherModule ~= nil and otherModule.tryDetour ~= nil and otherModule:tryDetour(self.vehicle)) then
            self.blockedTimer:timer(false)
            return
        end
        ADTrafficYieldModule.startPlan(self.vehicle, other)
    end
end

function ADTrafficYieldModule:findHeadOnPartner(excluded)
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(self.vehicle)
    local myLength = ADTrafficYieldModule.getTotalLength(self.vehicle)

    local bestOther = nil
    local bestDistance = math.huge

    for _, other in pairs(AutoDrive.getAllVehicles()) do
        if other ~= self.vehicle and other ~= excluded and other.ad ~= self.vehicle.ad and ADTrafficYieldModule.isAdVehicleUsable(other)
            and not AutoDrive:checkIsConnected(self.vehicle, other) then
            local ox, _, oz = ADTrafficYieldModule.getPosition(other)
            local distance = MathUtil.vector2Length(ox - x, oz - z)
            local maxDistance = ADTrafficYieldModule.MAX_DETECTION_DISTANCE + myLength / 2

            if distance < maxDistance and distance < bestDistance then
                local odirX, odirZ = ADTrafficYieldModule.getDirection(other)
                local headingDot = dirX * odirX + dirZ * odirZ
                -- other in front of me and me in front of other
                local _, _, otherLocalZ = AutoDrive.worldToLocal(self.vehicle, ox, 0, oz)
                local myX, myY, myZ = ADTrafficYieldModule.getPosition(self.vehicle)
                local _, _, meLocalZInOther = AutoDrive.worldToLocal(other, myX, myY, myZ)

                local otherModule = other.ad.trafficYieldModule
                local otherBlocked = other.ad.specialDrivingModule ~= nil and other.ad.specialDrivingModule:isStoppingVehicle()
                local otherStopped = ADTrafficYieldModule.getSpeedKmh(other) < 1
                local otherOnRoad = other.ad.drivePathModule:isOnRoadNetwork()


                if headingDot < -0.5 and otherLocalZ > 0 and meLocalZInOther > 0 and otherBlocked and otherStopped and otherOnRoad and not otherModule:isBusy() then
                    -- owner 28/10 18:27 (8510 and Patriot face to face on the two one-way lanes of a road, a crossing manoeuvre
                    -- started): only two vehicles whose routes share a two-way stretch (one lane driven both ways) are face to face
                    if ADTrafficYieldModule.shareTwoWayStretch(self.vehicle, other) then
                        bestOther = other
                        bestDistance = distance
                    elseif self.notTwoWayLogged ~= other or g_time - (self.notTwoWayTime or 0) > 30000 then
                        self.notTwoWayLogged, self.notTwoWayTime = other, g_time
                        self:log("face to face with %s but no shared two-way stretch (one-way lanes): no crossing manoeuvre", ADTrafficYieldModule.getName(other))
                        print(string.format("[AD-Croise] %s: face a %s mais pas de troncon a double sens commun (voies a sens unique) : pas de procedure de croisement",
                            ADTrafficYieldModule.getName(self.vehicle), ADTrafficYieldModule.getName(other)))
                    end
                end
            end
        end
    end
    return bestOther
end

------------------------------------------------------------------------------------------------
-- plan handling
------------------------------------------------------------------------------------------------

function ADTrafficYieldModule.getPairKey(vehicleA, vehicleB)
    local a, b = vehicleA.id or 0, vehicleB.id or 0
    if a > b then
        a, b = b, a
    end
    return tostring(a) .. "-" .. tostring(b)
end

-- owner 28/10 18:16 / 18:29: the one that will manoeuvre the least reverses, even if its reverse is longer (turns of its
-- way back out of the two-way track, double with a trailer; the length only breaks a tie). Load and weight no longer count
function ADTrafficYieldModule.pickReverser(vehicleA, vehicleB)
    local manA = ADTrafficYieldModule.getReverseManoeuvre(vehicleA)
    local manB = ADTrafficYieldModule.getReverseManoeuvre(vehicleB)
    local reverser, parker
    if math.abs(manA.score - manB.score) > ADTrafficYieldModule.MANOEUVRE_TIE then
        if manA.score < manB.score then
            reverser, parker = vehicleA, vehicleB
        else
            reverser, parker = vehicleB, vehicleA
        end
    elseif math.abs(manA.length - manB.length) > 5 then
        if manA.length < manB.length then
            reverser, parker = vehicleA, vehicleB
        else
            reverser, parker = vehicleB, vehicleA
        end
    elseif (vehicleA.id or 0) < (vehicleB.id or 0) then
        reverser, parker = vehicleA, vehicleB
    else
        reverser, parker = vehicleB, vehicleA
    end
    return reverser, parker, manA, manB
end

function ADTrafficYieldModule.startPlan(vehicleA, vehicleB)
    local reverser, parker, manA, manB = ADTrafficYieldModule.pickReverser(vehicleA, vehicleB)
    do
        local manR = reverser == vehicleA and manA or manB
        local manP = reverser == vehicleA and manB or manA
        local tooLong = string.format(", ne sort pas du chemin en %d m de recul", ADTrafficYieldModule.SECTION_CLEAR_MAX)
        print(string.format("[AD-Croise] face a face %s / %s : %s recule (virages %.0f deg sur %.0f m%s, contre %.0f deg sur %.0f m%s pour %s)",
            ADTrafficYieldModule.getName(vehicleA), ADTrafficYieldModule.getName(vehicleB), ADTrafficYieldModule.getName(reverser),
            manR.angle, manR.length, (manR.trailer and " avec remorque, comptes double" or "") .. (manR.tooLong and tooLong or ""), manP.angle, manP.length,
            (manP.trailer and " avec remorque, comptes double" or "") .. (manP.blocked and ", bloque derriere" or "") .. (manP.tooLong and tooLong or ""),
            ADTrafficYieldModule.getName(parker)))
    end

    -- previous failed attempts of this pair: 1 failure -> swap the roles (the other one reverses along
    -- its own route, where there may be a free roadside or a junction), 2 failures -> give up for a while
    local key = ADTrafficYieldModule.getPairKey(vehicleA, vehicleB)
    local history = ADTrafficYieldModule.pairHistory[key]
    if history ~= nil and g_time - history.time > ADTrafficYieldModule.HISTORY_TIMEOUT then
        ADTrafficYieldModule.pairHistory[key] = nil
        history = nil
    end
    if history ~= nil then
        if history.failures >= 2 then
            for _, vehicle in pairs({vehicleA, vehicleB}) do
                vehicle.ad.trafficYieldModule.cooldownUntil = g_time + ADTrafficYieldModule.GIVE_UP_TIME
                vehicle.ad.trafficYieldModule.blockedTimer:timer(false)
            end
            AutoDriveMessageEvent.sendMessageOrNotification(vehicleA, ADMessagesManager.messageTypes.ERROR, "$l10n_AD_Driver_of; %s $l10n_AD_trafficYield_giveUp;", 10000, ADTrafficYieldModule.getName(vehicleA))
            return
        end
        if history.failures == 1 and history.lastReverser == reverser then
            reverser, parker = parker, reverser
        end
    end

    -- A1 (owner 27/10, go 28/10), owner 28/10 18:20: an articulated train never reverses, the other one does
    local a1 = false
    if ADTrafficYieldModule.cannotReverse(reverser) and not ADTrafficYieldModule.cannotReverse(parker) then
        local what = ADTrafficYieldModule.describeArticulated(reverser)
        reverser.ad.trafficYieldModule:log("articulated train (%s): I never reverse, %s reverses", tostring(what), ADTrafficYieldModule.getName(parker))
        print(string.format("[AD-Croise] %s: remorque articulee, %s, je ne recule pas : %s recule", ADTrafficYieldModule.getName(reverser), tostring(what),
            ADTrafficYieldModule.getName(parker)))
        reverser, parker = parker, reverser
        a1 = true
    elseif ADTrafficYieldModule.cannotReverse(parker) then
        a1 = true
    end

    -- a vehicle with another one right behind it cannot reverse: it parks, the other one reverses (never onto a header trailer)
    local maxReverse = ADTrafficYieldModule.getMaxReverse() + 10
    if not a1 and ADTrafficYieldModule.hasFollowerBehind(reverser, maxReverse, parker) and not ADTrafficYieldModule.hasFollowerBehind(parker, maxReverse, reverser) then
        reverser.ad.trafficYieldModule:log("a vehicle follows me, %s reverses instead", ADTrafficYieldModule.getName(parker))
        reverser, parker = parker, reverser
    end

    local plan = {
        pairKey = key,
        firstReverser = reverser, -- roles may be swapped during the plan, keep the initial one for the history
        reverser = reverser,
        parker = parker,
        startTime = g_time,
        parkSpot = nil,      -- set by parker when a free roadside spot is found
        reverserMayStop = false,
        reverserAtLimit = false,
        parked = false,
        passed = false,
        mode = "park",       -- "park": parker parks on the roadside / "branch": reverser hides in a side branch
        hidden = false
    }

    local rModule = reverser.ad.trafficYieldModule
    local pModule = parker.ad.trafficYieldModule
    rModule:log("STANDARD plan: I reverse, %s parks", ADTrafficYieldModule.getName(parker))

    -- measure both trains in their current state so the roadside spot fits them exactly
    ADTrafficYieldModule.measureTrain(reverser)
    ADTrafficYieldModule.measureTrain(parker)

    rModule:reset()
    pModule:reset()
    rModule.plan, rModule.partner = plan, parker
    pModule.plan, pModule.partner = plan, reverser


    rModule:setState(ADTrafficYieldModule.STATE_REVERSER_RETREAT)
    pModule:setState(ADTrafficYieldModule.STATE_PARKER_SEARCH)

    AutoDriveMessageEvent.sendMessageOrNotification(reverser, ADMessagesManager.messageTypes.INFO, "$l10n_AD_Driver_of; %s $l10n_AD_trafficYield_giveWay;", 5000, ADTrafficYieldModule.getName(reverser))
end

-- ends the plan for both vehicles
function ADTrafficYieldModule:endPlan(reason, success)
    local plan = self.plan
    self:log("end of plan: %s (success=%s)", tostring(reason), tostring(success))

    if plan ~= nil and plan.pairKey ~= nil and success ~= nil then
        if success then
            ADTrafficYieldModule.pairHistory[plan.pairKey] = nil
        else
            local history = ADTrafficYieldModule.pairHistory[plan.pairKey] or {failures = 0}
            history.failures = history.failures + 1
            history.time = g_time
            history.lastReverser = plan.firstReverser or plan.reverser
            if plan.mode == "early" then
                -- the same early plan would start again at once and block both again (21:08-21:20: 3 timeouts in a row)
                history.earlyTried = g_time
            end
            ADTrafficYieldModule.pairHistory[plan.pairKey] = history
        end
    end

    local vehicles = {self.vehicle}
    if plan ~= nil then
        vehicles = {plan.reverser, plan.parker}
    end

    for _, vehicle in pairs(vehicles) do
        if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.trafficYieldModule ~= nil then
            local module = vehicle.ad.trafficYieldModule
            if module.plan == plan then
                local wasControlling = module.state ~= ADTrafficYieldModule.STATE_IDLE
                local reachedRouteIndex = module.reachedRouteIndex
                -- owner 28/10 (S7): the parked one stays parked until the last vehicle of the oncoming queue has passed
                local parkedWaiting = success == true and (module.state == ADTrafficYieldModule.STATE_PARKER_WAIT or module.state == ADTrafficYieldModule.STATE_REVERSER_HIDE)
                local passer = plan ~= nil and (vehicle == plan.parker and plan.reverser or plan.parker) or nil
                local spot = plan ~= nil and plan.parkSpot or nil
                -- 30/10 (B, D): the roadside path I drove stays known: same partner again = I stay, blocked off my route = way back
                if plan ~= nil and vehicle == plan.parker and spot ~= nil and spot.path ~= nil
                    and (module.state == ADTrafficYieldModule.STATE_PARKER_WAIT or module.state == ADTrafficYieldModule.STATE_PARKER_MOVE) then
                    module.parkTrace = {path = spot.path, spot = spot, partner = passer, time = g_time}
                end
                module:reset()
                local nextInQueue = nil
                if parkedWaiting and passer ~= nil then
                    nextInQueue = ADTrafficYieldModule.findFollowerBehind(passer, ADTrafficYieldModule.QUEUE_GAP, vehicle)
                    if nextInQueue ~= nil and module:hasPassedMe(nextInQueue, spot and spot.dirX, spot and spot.dirZ) then
                        nextInQueue = nil
                    end
                end
                if nextInQueue ~= nil then
                    module.waitDirX = spot and spot.dirX
                    module.waitDirZ = spot and spot.dirZ
                    module.waitFor = nextInQueue
                    module.waitSpot = spot
                    module.waitRouteIndex = reachedRouteIndex
                    module:setState(ADTrafficYieldModule.STATE_WAIT_DETACHED)
                    print(string.format("[AD-Croise] %s: %s est passe, je reste gare pour la file : %s", ADTrafficYieldModule.getName(vehicle),
                        ADTrafficYieldModule.getName(passer), ADTrafficYieldModule.getName(nextInQueue)))
                    wasControlling = false
                end
                if success == true then
                    module.cooldownUntil = g_time + ADTrafficYieldModule.COOLDOWN_SUCCESS
                elseif success == false then
                    module.cooldownUntil = g_time + ADTrafficYieldModule.COOLDOWN
                end
                if wasControlling and vehicle.ad.specialDrivingModule ~= nil then
                    vehicle.ad.specialDrivingModule:releaseVehicle()
                end
                if nextInQueue == nil then
                    ADTrafficYieldModule.resyncWayPoints(vehicle, reachedRouteIndex)
                end
            end
        end
    end

    if success == false and plan ~= nil and plan.reverser ~= nil then
        AutoDriveMessageEvent.sendMessageOrNotification(plan.reverser, ADMessagesManager.messageTypes.WARN, "$l10n_AD_Driver_of; %s $l10n_AD_trafficYield_failed;", 5000, ADTrafficYieldModule.getName(plan.reverser))
    end
end

function ADTrafficYieldModule:checkPlanStillValid()
    local plan = self.plan
    if plan == nil then
        self:reset()
        return false
    end
    local partner = self.partner
    if not ADTrafficYieldModule.isAdVehicleUsable(partner) or partner.ad.trafficYieldModule.plan ~= plan then
        self:endPlan("partner not available any more", false)
        return false
    end
    if plan.mode == "sectionClear" and plan.parked and not self.vehicle.ad.drivePathModule:isOnRoadNetwork() and self.state == ADTrafficYieldModule.STATE_REVERSER_PASS then
        -- through the single track and into the field: done
        plan.passed = true
        self:endPlan("through the single track", true)
        return false
    end
    if not self.vehicle.ad.drivePathModule:isOnRoadNetwork() and self.state ~= ADTrafficYieldModule.STATE_PARKER_MOVE and self.state ~= ADTrafficYieldModule.STATE_PARKER_WAIT
        and self.state ~= ADTrafficYieldModule.STATE_SECTION_CLEAR then
        self:endPlan("vehicle left the road network", false)
        return false
    end
    if g_time - plan.startTime > ADTrafficYieldModule.PLAN_TIMEOUT then
        self:endPlan("timeout", false)
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local px, _, pz = ADTrafficYieldModule.getPosition(partner)
    -- S3 (owner 27/10, go 28/10): neither of both moved PLAN_STUCK_M in PLAN_STUCK_MS: the roles are swapped
    local progress = plan.progress
    if progress == nil then
        progress = {time = g_time, pos = {}}
        plan.progress = progress
    end
    for _, item in ipairs({{self.vehicle, x, z}, {partner, px, pz}}) do
        local last = progress.pos[item[1]]
        if last == nil then
            progress.pos[item[1]] = {x = item[2], z = item[3]}
        elseif MathUtil.vector2Length(item[2] - last.x, item[3] - last.z) >= ADTrafficYieldModule.PLAN_STUCK_M then
            progress.pos[item[1]] = {x = item[2], z = item[3]}
            progress.time = g_time
        end
    end
    if g_time - progress.time > ADTrafficYieldModule.PLAN_STUCK_MS then
        self:restartWithRolesSwapped(string.format("nobody moved for %d s", ADTrafficYieldModule.PLAN_STUCK_MS / 1000),
            string.format("personne n'a bouge depuis %d s", ADTrafficYieldModule.PLAN_STUCK_MS / 1000))
        return false
    end
    local maxApart = 120
    if plan.mode == "early" then
        maxApart = 3 * ADTrafficYieldModule.ANTICIPATION_DISTANCE
    elseif plan.mode == "sectionClear" then
        maxApart = ADTrafficYieldModule.SECTION_CLEAR_MAX + 100
    end
    if MathUtil.vector2Length(px - x, pz - z) > maxApart then
        self:endPlan("vehicles too far apart", plan.passed)
        return false
    end
    return true
end

-- after a manoeuvre the current waypoint may be behind the vehicle (parker drove past it on the roadside)
-- skip every waypoint that is no longer in front of the vehicle
function ADTrafficYieldModule.resyncWayPoints(vehicle, restartRouteIndex)
    local drivePathModule = vehicle.ad.drivePathModule
    if drivePathModule == nil then
        return
    end
    -- the reverser went back along its route: restart from the last route waypoint it reversed past
    local wps, idx = drivePathModule:getWayPoints()
    -- AutoDrive never drives with index 1 (it always needs the previous waypoint), so clamp to 2
    if restartRouteIndex ~= nil and wps ~= nil and idx ~= nil then
        restartRouteIndex = math.max(2, restartRouteIndex)
        if restartRouteIndex < idx and wps[restartRouteIndex] ~= nil and wps[restartRouteIndex - 1] ~= nil then
            drivePathModule:setCurrentWayPointIndex(restartRouteIndex)
        end
    end
    local wayPoints, currentIndex = drivePathModule:getWayPoints()
    local skipped = 0
    if wayPoints ~= nil and currentIndex ~= nil then
        while skipped < 30 do
            local wp = drivePathModule:getCurrentWayPoint()
            if wp == nil or drivePathModule:getNextWayPoint() == nil then
                break
            end
            local _, _, localZ = AutoDrive.worldToLocal(vehicle, wp.x, wp.y, wp.z)
            if localZ > 2 then
                break
            end
            drivePathModule:switchToNextWayPoint()
            skipped = skipped + 1
        end
    end
    drivePathModule.minDistanceToNextWp = math.huge
    if drivePathModule.minDistanceTimer ~= nil then
        drivePathModule.minDistanceTimer:timer(false)
    end
end

------------------------------------------------------------------------------------------------
-- REVERSER
------------------------------------------------------------------------------------------------

function ADTrafficYieldModule:buildReverseTargets(maxDistance)
    local targets = {}
    local x, y, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local maxReverse = maxDistance or ADTrafficYieldModule.getMaxReverse() + 5
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()

    local lastX, lastZ = x, z
    local travelled = 0
    if wayPoints ~= nil and currentIndex ~= nil then
        local index = currentIndex - 1
        while index >= 1 and travelled < maxReverse do
            local wp = wayPoints[index]
            if wp == nil then
                break
            end
            local _, _, localZ = AutoDrive.worldToLocal(self.vehicle, wp.x, wp.y, wp.z)
            if localZ < -1 then
                local d = MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
                local isJunction = self.escapeBranch ~= nil and self.escapeBranch.routeIndex == index
                if d >= ADTrafficYieldModule.REVERSE_STEP or (#targets == 0 and d >= 3) or (isJunction and d >= 1) then
                    travelled = travelled + d
                    table.insert(targets, {x = wp.x, y = wp.y, z = wp.z, routeIndex = index, isJunction = isJunction})
                    lastX, lastZ = wp.x, wp.z
                end
            end
            index = index - 1
        end
    end

    -- no route behind (start of the route): reverse straight
    if travelled < maxReverse then
        local dirX, dirZ
        if #targets >= 2 then
            local a, b = targets[#targets - 1], targets[#targets]
            local l = math.max(0.01, MathUtil.vector2Length(b.x - a.x, b.z - a.z))
            dirX, dirZ = (b.x - a.x) / l, (b.z - a.z) / l
        else
            local fx, fz = ADTrafficYieldModule.getDirection(self.vehicle)
            dirX, dirZ = -fx, -fz
        end
        while travelled < maxReverse do
            lastX = lastX + dirX * ADTrafficYieldModule.REVERSE_STEP
            lastZ = lastZ + dirZ * ADTrafficYieldModule.REVERSE_STEP
            travelled = travelled + ADTrafficYieldModule.REVERSE_STEP
            local ty = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, lastX, y, lastZ)
            table.insert(targets, {x = lastX, y = ty, z = lastZ, straight = true})
        end
    end

    return targets
end

-- collects the graph ids of the next waypoints of a vehicle route
function ADTrafficYieldModule.getUpcomingIds(vehicle, fromOffset, count)
    local ids = {}
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints ~= nil and currentIndex ~= nil then
        for i = math.max(1, currentIndex + fromOffset), currentIndex + fromOffset + count do
            local wp = wayPoints[i]
            if wp ~= nil and wp.id ~= nil then
                ids[wp.id] = true
            end
        end
    end
    return ids
end

-- searches, behind the reverser on its own route, a junction with a side branch that is not used by
-- the parker: the reverser can back into it and let the parker pass
function ADTrafficYieldModule:findEscapeBranch()
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil or ADGraphManager == nil then
        return nil
    end
    local maxReverse = ADTrafficYieldModule.getMaxReverse()
    local myLength = ADTrafficYieldModule.getTotalLength(self.vehicle)
    local neededDepth = myLength + 4

    -- nodes that must stay free: route of the parker ahead, and my own route around me
    local forbidden = ADTrafficYieldModule.getUpcomingIds(self.partner, -5, 150)
    for id, _ in pairs(ADTrafficYieldModule.getUpcomingIds(self.vehicle, -80, 160)) do
        forbidden[id] = true
    end

    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local lastX, lastZ = x, z
    local travelled = 0
    local index = currentIndex - 1
    -- a waiting lane (dead end of the AutoDrive network) anywhere within reach is preferred to the
    -- first ordinary side branch
    local firstBranch = nil
    while index >= 2 and travelled < maxReverse do
        local wp = wayPoints[index]
        if wp == nil then
            break
        end
        travelled = travelled + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if wp.id ~= nil then
            local node = ADGraphManager:getWayPointById(wp.id)
            if node ~= nil then
                local neighbours = {}
                for _, id in pairs(node.out or {}) do neighbours[id] = true end
                for _, id in pairs(node.incoming or {}) do neighbours[id] = true end
                for neighbourId, _ in pairs(neighbours) do
                    if not forbidden[neighbourId] then
                        local branch = self:walkBranch(node, neighbourId, forbidden, neededDepth)
                        if branch ~= nil then
                            branch.routeIndex = index
                            branch.junctionId = wp.id
                            branch.isWaitingLane = ADTrafficYieldModule.isDeadEnd(node, neighbourId, forbidden)
                            if branch.isWaitingLane then
                                return branch
                            end
                            firstBranch = firstBranch or branch
                        end
                    end
                end
            end
        end
        index = index - 1
    end
    return firstBranch
end

ADTrafficYieldModule.WAITING_LANE_MAX_LENGTH = 80 -- m, a dead end longer than this is a road, not a waiting lane

-- waiting lane: the side branch starting at junction -> firstId ends in a dead end (no other way out)
-- within WAITING_LANE_MAX_LENGTH metres
function ADTrafficYieldModule.isDeadEnd(junction, firstId, forbidden)
    local visited = {[junction.id] = true}
    local current = ADGraphManager:getWayPointById(firstId)
    local length = 0
    local previous = junction
    while current ~= nil do
        if visited[current.id] or forbidden[current.id] then
            return false -- loop back or back to the route: it is a way through
        end
        visited[current.id] = true
        length = length + MathUtil.vector2Length(current.x - previous.x, current.z - previous.z)
        if length > ADTrafficYieldModule.WAITING_LANE_MAX_LENGTH then
            return false
        end
        local nextIds = {}
        for _, id in pairs(current.out or {}) do
            if not visited[id] then nextIds[id] = true end
        end
        for _, id in pairs(current.incoming or {}) do
            if not visited[id] then nextIds[id] = true end
        end
        local nextId, count = nil, 0
        for id, _ in pairs(nextIds) do
            nextId, count = id, count + 1
        end
        if count == 0 then
            return true
        end
        if count > 1 then
            return false -- the branch forks: a small network, not a simple waiting lane
        end
        previous = current
        current = ADGraphManager:getWayPointById(nextId)
    end
    return false
end

function ADTrafficYieldModule:walkBranch(junction, firstId, forbidden, neededDepth)
    local nodes = {}
    local visited = {[junction.id] = true}
    local current = ADGraphManager:getWayPointById(firstId)
    local previous = junction
    local depth = 0
    while current ~= nil and #nodes < 12 do
        if forbidden[current.id] or visited[current.id] then
            return nil
        end
        visited[current.id] = true
        depth = MathUtil.vector2Length(current.x - junction.x, current.z - junction.z)
        table.insert(nodes, {x = current.x, y = current.y, z = current.z, id = current.id})
        if depth >= neededDepth then
            return {nodes = nodes, depth = depth}
        end
        -- continue with the straightest following node
        local dirX, dirZ = current.x - previous.x, current.z - previous.z
        local best, bestDot = nil, -2
        local candidates = {}
        for _, id in pairs(current.out or {}) do candidates[id] = true end
        for _, id in pairs(current.incoming or {}) do candidates[id] = true end
        for id, _ in pairs(candidates) do
            if not visited[id] then
                local n = ADGraphManager:getWayPointById(id)
                if n ~= nil then
                    local vx, vz = n.x - current.x, n.z - current.z
                    local l1 = math.max(0.01, MathUtil.vector2Length(dirX, dirZ))
                    local l2 = math.max(0.01, MathUtil.vector2Length(vx, vz))
                    local dot = (dirX * vx + dirZ * vz) / (l1 * l2)
                    if dot > bestDot then
                        best, bestDot = n, dot
                    end
                end
            end
        end
        previous = current
        current = best
    end
    -- dead end: accept it if deep enough to hide most of the vehicle
    if depth >= neededDepth * 0.8 then
        return {nodes = nodes, depth = depth}
    end
    return nil
end

-- reverse towards a world point; own reached check (distance only) so sharp turns into a branch are possible
function ADTrafficYieldModule:reverseTowards(dt, target, reachedDistance)
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm:releaseVehicle()
    self:ensureMotorStarted()
    sdm.reverseNode = sdm:getReverseNode()
    if sdm.reverseNode == nil then
        return true
    end
    sdm.reverseTarget = target
    sdm.currentWayPointIndex = 0
    sdm.wayPoints = {}
    sdm:getBasicStates()
    local distance = MathUtil.vector2Length(target.x - sdm.rNx, target.z - sdm.rNz)
    if distance < (reachedDistance or 2.5) then
        return true
    end
    -- target already in front of the reverse node: consider it reached
    local _, _, localZ = worldToLocal(sdm.reverseNode, target.x, target.y, target.z)
    if localZ > 1 and distance < 6 then
        return true
    end
    if self.vehicle.ad.collisionDetectionModule:checkReverseCollision() then
        sdm:stopAndHoldVehicle(dt)
    else
        sdm:reverseToPoint(dt, ADTrafficYieldModule.REVERSE_SPEED)
    end
    return false
end

function ADTrafficYieldModule:updateReverserRetreat(dt)
    local plan = self.plan
    if self.reverseTargets == nil then
        self.escapeBranch = self:findEscapeBranch()
        if self.escapeBranch ~= nil and self.escapeBranch.isWaitingLane then
            -- a waiting lane behind me: I back into it, the other one does not look for a roadside spot
            plan.mode = "branch"
            self:log("waiting lane (dead end) behind me, I back into it")
        end
        self.reverseTargets = self:buildReverseTargets()
        self.reverseTargetIndex = 1
        local x, y, z = ADTrafficYieldModule.getPosition(self.vehicle)
        self.reverseStart = {x = x, y = y, z = z}
    end

    local room = plan.moreRoom
    local extra = room ~= nil and room.pending and room.started
    if plan.reverserMayStop and not extra then
        self:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
        self:holdVehicle(dt)
        return
    end

    -- the reverser may have a free roadside spot next to it: if so it parks itself and the other one passes
    if self:tryOwnParkingSpot(dt) then
        return
    end

    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local reversed = MathUtil.vector2Length(x - self.reverseStart.x, z - self.reverseStart.z)
    local maxReverse = ADTrafficYieldModule.getMaxReverse()

    local blockedBehind = self.vehicle.ad.collisionDetectionModule:checkReverseCollision()
    local blockedTooLong = self.reverseBlockedTimer:timer(blockedBehind, 8000, dt)
    -- S3: not moving backwards although asked to (trailer swung against a wall: 942 Vario 27/10 20:20, 3 min)
    if self:isReverseStuck() then
        plan.reverserStuck = true
        blockedTooLong = true
    end

    local target = self.reverseTargets[self.reverseTargetIndex]
    if extra then
        local more = MathUtil.vector2Length(x - room.x, z - room.z)
        if more >= ADTrafficYieldModule.MORE_ROOM or target == nil or blockedTooLong or reversed >= maxReverse + 5 then
            room.pending = false
            room.failed = more < ADTrafficYieldModule.MORE_ROOM_MIN
            self:log("backed off %.0f m more%s", more, room.failed and " (no room behind me)" or "")
            self:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
            self:holdVehicle(dt)
            return
        end
    end
    if reversed >= maxReverse + 5 or target == nil or blockedTooLong then
        plan.reverserAtLimit = true
        self:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
        self:holdVehicle(dt)
        return
    end

    if self:reverseTowards(dt, target) then
        if target.routeIndex ~= nil then
            self.reachedRouteIndex = target.routeIndex
        end
        self.reverseTargetIndex = self.reverseTargetIndex + 1
        -- at the junction and still no roadside spot for the parker: hide in the side branch
        if target.isJunction and self.escapeBranch ~= nil and (plan.parkSpot == nil or self.escapeBranch.isWaitingLane) then
            plan.mode = "branch"
            self.branchTargetIndex = 1
            self:setState(ADTrafficYieldModule.STATE_REVERSER_BRANCH)
        end
    end
end

function ADTrafficYieldModule:updateReverserBranch(dt)
    local plan = self.plan
    local blockedBehind = self.vehicle.ad.collisionDetectionModule:checkReverseCollision()
    local blockedTooLong = self.reverseBlockedTimer:timer(blockedBehind, 8000, dt)
    if self:isReverseStuck() then
        blockedTooLong = true -- S3
    end
    local timedOut = self.stateTimer:timer(true, 45000, dt)
    local target = self.escapeBranch.nodes[self.branchTargetIndex]

    if target == nil or blockedTooLong or timedOut then
        plan.hidden = true
        self:setState(ADTrafficYieldModule.STATE_REVERSER_HIDE)
        self:holdVehicle(dt)
        return
    end
    if self:reverseTowards(dt, target, 2) then
        self.branchTargetIndex = self.branchTargetIndex + 1
    end
end

function ADTrafficYieldModule:updateReverserHide(dt)
    self:holdVehicle(dt)
    -- the parker ends the plan once it has passed the junction
    if self.stateTimer:timer(true, 120000, dt) then
        self:endPlan("hide timeout", false)
    end
end

function ADTrafficYieldModule:updateReverserWait(dt)
    local plan = self.plan
    self:holdVehicle(dt)
    if plan.moreRoom ~= nil and plan.moreRoom.pending and not plan.moreRoom.started and not plan.parked then
        local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
        plan.moreRoom.started = true
        plan.moreRoom.x, plan.moreRoom.z = x, z
        self:log("backing off %d m more for %s", ADTrafficYieldModule.MORE_ROOM, ADTrafficYieldModule.getName(self.partner))
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:setState(ADTrafficYieldModule.STATE_REVERSER_RETREAT)
        return
    end
    if plan.parked then
        self:setState(ADTrafficYieldModule.STATE_REVERSER_PASS)
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        ADTrafficYieldModule.resyncWayPoints(self.vehicle, self.reachedRouteIndex)
        return
    end
    -- reverser stopped before the parker had a spot (limit reached): give both a last chance, then give up
    if plan.reverserAtLimit and plan.parkSpot == nil then
        if self:tryOwnParkingSpot(dt) then
            return
        end
        if plan.reverserStuck and self.stateTimer:timer(true, 6000, dt) then
            -- S3: I cannot reverse at all: the other one reverses instead
            self:restartWithRolesSwapped("reverser stuck, no roadside spot", "je n'arrive pas a reculer et pas de place pour " .. ADTrafficYieldModule.getName(self.partner))
            return
        end
        if not plan.reverserStuck and self.stateTimer:timer(true, 6000, dt) then
            -- owner 26/10 19:02 (Jaguar / 942 Vario nose to nose on a single track, no roadside spot on 50 m either way, both
            -- plans given up, both stayed there): rather than giving up, I keep reversing along my route until I am off the
            -- way of the other one (junction, end of the single track, up to SECTION_CLEAR_MAX), it follows and passes
            if self:startClearAsReverser() then
                return
            end
            self:endPlan("no free roadside spot found", false)
        end
    end
end

-- the reverser of the standard plan reached its limit and the parker found no spot: the plan goes on as a
-- "single track clear" (the reverser backs until it is off the way of the other one, which then drives on)
function ADTrafficYieldModule:startClearAsReverser()
    local plan = self.plan
    local other = self.partner
    if other == nil or plan == nil or plan.sectionCleared or plan.mode == "branch" then
        return false
    end
    if ADTrafficYieldModule.hasFollowerBehind(self.vehicle, 20, other) then
        return false
    end
    plan.sectionCleared = true
    plan.mode = "sectionClear"
    plan.reverser, plan.parker = other, self.vehicle -- it drives on (REVERSER_PASS), I get off its way
    plan.parked = false
    plan.waitBeforeSection = nil
    plan.reverserMayStop = true
    plan.reverserAtLimit = false
    self:log("no roadside spot on either side: I keep reversing until I am off the way of %s (%d m at most)", ADTrafficYieldModule.getName(other), ADTrafficYieldModule.SECTION_CLEAR_MAX)
    print(string.format("[AD-Croise] %s: pas de place pour se garer de part et d'autre, je continue a reculer jusqu'a etre hors du chemin de %s (%d m au plus)",
        ADTrafficYieldModule.getName(self.vehicle), ADTrafficYieldModule.getName(other), ADTrafficYieldModule.SECTION_CLEAR_MAX))
    local otherModule = other.ad.trafficYieldModule
    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    other.ad.specialDrivingModule:releaseVehicle()
    self.reverseTargets = nil
    otherModule:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
    otherModule:holdVehicle(0)
    self:setState(ADTrafficYieldModule.STATE_SECTION_CLEAR)
    return true
end

-- the reverser searches a roadside spot from its own position (towards the other vehicle). When it
-- finds one first, the roles are swapped: the reverser parks there and the other vehicle drives on.
function ADTrafficYieldModule:tryOwnParkingSpot(dt)
    local plan = self.plan
    if plan.parkSpot ~= nil or plan.mode == "branch" then
        return false
    end
    if g_time - self.lastSearchTime < ADTrafficYieldModule.SEARCH_INTERVAL then
        return false
    end
    self.lastSearchTime = g_time

    local spot = self:searchParkingSpot()
    if spot == nil then
        return false
    end

    -- swap the roles in the running plan
    self:log("own spot found (side=%s) -> roles swapped, I park", tostring(spot.side))
    local other = self.partner
    local otherModule = other.ad.trafficYieldModule
    plan.reverser, plan.parker = other, self.vehicle
    plan.parkSpot = spot
    plan.reverserMayStop = true
    plan.reverserAtLimit = false

    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    self:setState(ADTrafficYieldModule.STATE_PARKER_MOVE)
    otherModule:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
    return true
end

-- 'other' lies on my route ahead of me (PASSED_ROUTE_WIDTH m at most from it): not passed yet, whatever my own axis says
-- (owner 30/10 17:56 PC: the 7R 350 at the road junction, turned along the road, the track leaving behind it: the 942 Vario
-- 75 m away in the track was "behind" it and the plan ended as passed after 30 ms)
function ADTrafficYieldModule.isAheadOnMyRoute(vehicle, other, maxDistance)
    if other == nil or other.components == nil or vehicle.ad == nil or vehicle.ad.drivePathModule == nil then
        return false
    end
    local route = ADTrafficYieldModule.getRoutePolyline(vehicle, maxDistance or 200)
    if #route < 2 then
        return false
    end
    local ox, _, oz = ADTrafficYieldModule.getPosition(other)
    local along, best, bestAlong = 0, math.huge, 0
    for k = 1, #route - 1 do
        local a, b = route[k], route[k + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = MathUtil.vector2Length(dx, dz)
        if l > 0.01 then
            local t = math.max(0, math.min(1, ((ox - a.x) * dx + (oz - a.z) * dz) / (l * l)))
            local d = MathUtil.vector2Length(ox - (a.x + dx * t), oz - (a.z + dz * t))
            if d < best then
                best, bestAlong = d, along + t * l
            end
            along = along + l
        end
    end
    return best <= ADTrafficYieldModule.PASSED_ROUTE_WIDTH and bestAlong > 1
end

function ADTrafficYieldModule:updateReverserPass(dt)
    -- normal driving (module does not control the vehicle), only watch when we have passed the parker
    local plan = self.plan
    local parker = self.partner
    local px, py, pz = ADTrafficYieldModule.getPosition(parker)
    local _, _, parkerLocalZ = AutoDrive.worldToLocal(self.vehicle, px, py, pz)
    local parkerLength = ADTrafficYieldModule.getTotalLength(parker)
    local myLength = ADTrafficYieldModule.getTotalLength(self.vehicle)

    -- the parker centre is behind us by more than the length of both trains, and no longer ahead on my route
    if parkerLocalZ < -(parkerLength + myLength / 2 + 2) and not ADTrafficYieldModule.isAheadOnMyRoute(self.vehicle, parker) then
        plan.passed = true
        self:endPlan("passed", true)
        return
    end
    if self.stateTimer:timer(true, 90000, dt) then
        self:endPlan("pass timeout", false)
    end
end

------------------------------------------------------------------------------------------------
-- PARKER
------------------------------------------------------------------------------------------------

function ADTrafficYieldModule:updateParkerSearch(dt)
    local plan = self.plan
    self:holdVehicle(dt)

    if plan.mode == "branch" then
        if plan.hidden then
            self.vehicle.ad.specialDrivingModule:releaseVehicle()
            ADTrafficYieldModule.resyncWayPoints(self.vehicle)
            self:setState(ADTrafficYieldModule.STATE_PARKER_PASS)
        end
        return
    end

    if g_time - self.lastSearchTime < ADTrafficYieldModule.SEARCH_INTERVAL then
        return
    end
    self.lastSearchTime = g_time

    local spot = self:searchParkingSpot()
    if spot ~= nil then
        self:log("spot found: side=%s field=%s", tostring(spot.side), tostring(spot.onField))
        plan.parkSpot = spot
        plan.reverserMayStop = true
        self:setState(ADTrafficYieldModule.STATE_PARKER_MOVE)
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        return
    end

    -- if the reverser cannot make more room, it ends the plan itself after a last search delay
end

-- searches a free spot on the roadside in front of the parker, inside the gap left by the reverser.
-- The road geometry of the route is followed (curves), the right side first, the left side as a last resort;
-- the straight search from the vehicle axis is only used when the route ahead is too short.
function ADTrafficYieldModule:searchParkingSpot()
    local rx, ry, rz = ADTrafficYieldModule.getPosition(self.partner)
    local _, _, reverserLocalZ = AutoDrive.worldToLocal(self.vehicle, rx, ry, rz)
    local reverserFront = ADTrafficYieldModule.getTrainExtents(self.partner)
    local gapEnd = reverserLocalZ - reverserFront - 2
    if gapEnd <= 0 then
        return nil
    end
    return self:searchSpotBySides(gapEnd, false) or self:searchParkingSpotStraight()
end

function ADTrafficYieldModule:searchParkingSpotStraight()
    local parker = self.vehicle
    local reverser = self.partner

    local px, py, pz = ADTrafficYieldModule.getPosition(parker)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(parker)

    local parkerWidth = ADTrafficYieldModule.getWidth(parker)
    local reverserWidth = ADTrafficYieldModule.getWidth(reverser)
    for _, v in ipairs(ADTrafficYieldModule.getQueueBehind(reverser, parker)) do
        reverserWidth = math.max(reverserWidth, ADTrafficYieldModule.getWidth(v))
    end
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(parker)
    local parkerFront, parkerRear = ADTrafficYieldModule.getTrainExtents(parker)
    local totalLength = parkerFront + parkerRear
    local reverserFront = ADTrafficYieldModule.getTrainExtents(reverser)

    -- free gap in front of the parker up to the front of the reverser (front implements included)
    local rx, ry, rz = ADTrafficYieldModule.getPosition(reverser)
    local _, _, reverserLocalZ = AutoDrive.worldToLocal(parker, rx, ry, rz)
    local gapEnd = reverserLocalZ - reverserFront - 2

    local margin = AutoDrive.getSetting("trafficYieldMargin") or ADTrafficYieldModule.LATERAL_MARGIN
    local baseLateral = (parkerWidth + reverserWidth) / 2 + margin
    -- towed units need a straight run along the roadside after the swerve to line up behind the tractor
    local trailLength = math.max(0, parkerRear - tractorLength / 2)
    local runOut = ADTrafficYieldModule.getRunOut(trailLength)
    local minForward = math.max(8, tractorLength * 1.5, baseLateral * 2.5, trailLength)
    local maxForward = gapEnd - parkerFront - runOut

    if maxForward < minForward then
        return nil
    end

    -- local +x is left in GIANTS, so right side is negative x
    -- driving side only (see getSides)
    local sides = ADTrafficYieldModule.getSides()
    local laterals = {baseLateral, baseLateral + 1.0, baseLateral + 2.0}
    -- first pass: spot outside the fields (grass strip), second pass: spot may overlap a field
    -- every option on the driving side: grass first, then field
    for _, side in ipairs(sides) do
    for pass = 1, 2 do
    local allowField = pass == 2
        for _, lateral in ipairs(laterals) do
            local forward = minForward
            while forward <= maxForward do
                if self:isSpotFree(px, py, pz, dirX, dirZ, forward, side.sign * lateral, parkerWidth, parkerFront, totalLength, allowField, runOut) then
                    local wx, wy, wz = AutoDrive.localToWorld(parker, side.sign * lateral, 0, forward)
                    local finalX, _, finalZ = AutoDrive.localToWorld(parker, side.sign * lateral, 0, forward + runOut)
                    local ax, _, az = AutoDrive.localToWorld(parker, side.sign * lateral, 0, forward + runOut + 8)
                    return {
                        finalX = finalX, finalZ = finalZ,
                        originX = px, originZ = pz,
                        lateralAbs = lateral,
                        onField = allowField,
                        side = side.name,
                        forward = forward,
                        lateral = side.sign * lateral,
                        x = wx, y = wy, z = wz,
                        aimX = ax, aimZ = az,
                        dirX = dirX, dirZ = dirZ
                    }
                end
                forward = forward + 2
            end
        end
    end
    end
    return nil
end

function ADTrafficYieldModule:isSpotFree(px, py, pz, dirX, dirZ, forward, lateral, width, frontExtent, totalLength, allowField, runOut)
    local ry = math.atan2(dirX, dirZ)
    -- frame of the road at (px, pz) heading (dirX, dirZ); GIANTS local +x is left = (dirZ, -dirX)
    local function toWorld(lateralOffset, forwardOffset)
        return px + dirX * forwardOffset + dirZ * lateralOffset, py, pz + dirZ * forwardOffset - dirX * lateralOffset
    end
    local sign = lateral >= 0 and 1 or -1

    -- 1. final footprint of the whole train (tractor front at forward + tractorLength / 2)
    -- final position: tractor at the end of the straight run, whole train lined up behind it
    local frontZ = forward + (runOut or 0) + frontExtent
    local centerZ = frontZ - totalLength / 2
    local fx, _, fz = toWorld(lateral, centerZ)
    local roadY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, px, py, pz)

    -- terrain check on the footprint corners
    local minH, maxH = math.huge, -math.huge
    local halfW = width / 2 + 0.2
    local halfL = totalLength / 2 + 0.3
    local onField = false
    local roadDiff = 0
    local slopeDiff = 0
    for _, corner in ipairs({{-1, -1}, {-1, 1}, {1, -1}, {1, 1}, {0, 0}}) do
        local cx, _, cz = toWorld(lateral + corner[1] * halfW, centerZ + corner[2] * halfL)
        local h = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, py, cz)
        minH = math.min(minH, h)
        maxH = math.max(maxH, h)
        -- owner 28/10 20:13: each corner against the road right beside it (on a slope the road itself rises)
        local bx, _, bz = toWorld(0, centerZ + corner[2] * halfL)
        roadDiff = math.max(roadDiff, math.abs(h - getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, bx, py, bz)))
        if not allowField and AutoDrive.checkIsOnField(cx, h, cz) then
            onField = true
        end
    end
    if onField then
        return false
    end
    -- lateral slope of the footprint: left against right corners, the slope along the road does not count
    for _, f in ipairs({-1, 1}) do
        local ax, _, az = toWorld(lateral - halfW, centerZ + f * halfL)
        local bx, _, bz = toWorld(lateral + halfW, centerZ + f * halfL)
        slopeDiff = math.max(slopeDiff, math.abs(getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, ax, py, az) - getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, bx, py, bz)))
    end
    if slopeDiff > ADTrafficYieldModule.MAX_SLOPE_DIFF or roadDiff > ADTrafficYieldModule.MAX_ROAD_HEIGHT_DIFF then
        return false
    end

    -- water check
    if g_currentMission.environmentAreaSystem ~= nil and g_currentMission.environmentAreaSystem.getWaterYAtWorldPosition ~= nil then
        local waterY = g_currentMission.environmentAreaSystem:getWaterYAtWorldPosition(fx, roadY, fz)
        if waterY ~= nil and waterY > minH - 0.2 then
            return false
        end
    end

    -- box from 0.6 m to 3.2 m above the ground: low road borders / curbs are ignored
    local fy = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, fx, py, fz) + 1.9
    if self:overlapHit(fx, fy, fz, ry, halfW, 1.3, halfL) then
        return false
    end

    -- 2. swerve corridor, roadside part only (from the side of my own lane to the spot)
    local corridorStart = frontExtent
    local corridorEnd = frontZ
    local corridorHalfL = (corridorEnd - corridorStart) / 2
    local innerEdge = width / 2 + 0.2
    local outerEdge = math.abs(lateral) + width / 2
    if corridorHalfL > 0.5 and outerEdge > innerEdge then
        local corridorCenterX = sign * (innerEdge + outerEdge) / 2
        local corridorHalfW = (outerEdge - innerEdge) / 2
        local cx, _, cz = toWorld(corridorCenterX, corridorStart + corridorHalfL)
        if self:overlapHit(cx, fy, cz, ry, corridorHalfW, 1.3, corridorHalfL) then
            return false
        end
    end
    return true
end

function ADTrafficYieldModule:overlapHit(x, y, z, ry, halfX, halfY, halfZ)
    self.overlapHitCount = 0
    self.overlapHitName = nil
    self.overlapHitVehicle = nil
    local mask = CollisionFlag.STATIC_OBJECT + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.VEHICLE + CollisionFlag.TREE + CollisionFlag.BUILDING + CollisionFlag.TRAFFIC_VEHICLE + CollisionFlag.TRAFFIC_VEHICLE_BLOCKING
    overlapBox(x, y, z, 0, ry, 0, halfX, halfY, halfZ, "overlapCallback", self, mask, true, true, true, true) -- dynamics, kinematics, statics, exactTest (real geometry, not the bounding box)
    return self.overlapHitCount > 0
end

function ADTrafficYieldModule:overlapCallback(transformId)
    if transformId == nil or transformId == 0 or transformId == g_currentMission.terrainRootNode then
        return true
    end
    local object = g_currentMission:getNodeObject(transformId)
    if object == nil then
        local parent = getParent(transformId)
        if parent ~= nil and parent ~= 0 then
            object = g_currentMission:getNodeObject(parent)
        end
    end
    if object ~= nil and (object == self.vehicle or AutoDrive:checkIsConnected(self.vehicle:getRootVehicle(), object)) then
        return true -- ignore myself
    end
    local ignored = self.overlapIgnoreVehicle
    if object ~= nil and ignored ~= nil and (object == ignored or (ignored.getRootVehicle ~= nil and AutoDrive:checkIsConnected(ignored:getRootVehicle(), object))) then
        return true -- vehicle left out of this reading (end-of-row U-turn: the harvester, owner 23/10)
    end
    if object == nil then
        if ADTrafficYieldModule.IGNORED_SHAPE_NAMES[getName(transformId)] then
            return true -- field border
        end
        if ADSensor ~= nil and ADSensor.isElementBlockingVehicle ~= nil and not ADSensor:isElementBlockingVehicle(transformId) then
            return true -- traffic sign etc.
        end
        -- only keep the shapes the vehicle would physically collide with
        if not self:isShapeBlockingVehicle(transformId) then
            return true
        end
    end

    self.overlapHitCount = self.overlapHitCount + 1
    self.overlapHitName = object ~= nil and object.getName ~= nil and object:getName() or getName(transformId)
    self.overlapHitVehicle = object ~= nil and object.getRootVehicle ~= nil
    return false -- blocked, no need to look further
end

-- compares the collision filter of the shape with the one of the vehicle (FS25 physics rule:
-- two shapes collide when groupA & maskB ~= 0 and groupB & maskA ~= 0)
function ADTrafficYieldModule:isShapeBlockingVehicle(shapeId)
    if getCollisionFilterGroup == nil or getCollisionFilterMask == nil or bitAND == nil then
        return true
    end
    local ok, shapeGroup, shapeMask, vehGroup, vehMask = pcall(function()
        local vehicleNode = self.vehicle.components[1].node
        return getCollisionFilterGroup(shapeId), getCollisionFilterMask(shapeId), getCollisionFilterGroup(vehicleNode), getCollisionFilterMask(vehicleNode)
    end)
    if not ok or shapeGroup == nil or shapeMask == nil or vehGroup == nil or vehMask == nil then
        return true
    end
    return bitAND(shapeGroup, vehMask) ~= 0 and bitAND(vehGroup, shapeMask) ~= 0
end

-- lateral distance of the rear of the last towed unit from the original road line
-- last towed unit heading close to the road direction (less than about 10 degrees)
function ADTrafficYieldModule:isLastUnitParallel(spot)
    local units, count = AutoDrive.getAllUnits(self.vehicle)
    local unit = self.vehicle
    if units ~= nil and count ~= nil and count > 1 and units[count] ~= nil then
        unit = units[count]
    end
    local ux, _, uz = localDirectionToWorld(unit.components[1].node, 0, 0, 1)
    local l = MathUtil.vector2Length(ux, uz)
    if l < 0.01 then
        return true
    end
    return (ux * spot.dirX + uz * spot.dirZ) / l > 0.985
end

function ADTrafficYieldModule:getRearLateralOffset(spot)
    local units, count = AutoDrive.getAllUnits(self.vehicle)
    local unit = self.vehicle
    if units ~= nil and count ~= nil and count > 1 and units[count] ~= nil then
        unit = units[count]
    end
    local _, length = ADTrafficYieldModule.getUnitDimensions(unit)
    local rx, _, rz = localToWorld(unit.components[1].node, 0, 0, -length / 2)
    return math.abs((rx - spot.originX) * spot.dirZ - (rz - spot.originZ) * spot.dirX)
end

-- owner 25/10 (7R and 942 nose to nose by the sheds): the parker reached the reverser before being off the road and
-- called itself parked, the reverser could not pass. Now the reverser backs off ADTrafficYieldModule.MORE_ROOM
-- more meters (twice at most), the parker waits meanwhile, then finishes pulling over.
ADTrafficYieldModule.MORE_ROOM = 20           -- m backed off once more by the reverser
ADTrafficYieldModule.MORE_ROOM_TRIES = 2
ADTrafficYieldModule.MORE_ROOM_MIN = 5        -- m: backed off less than this, no room behind it, the parker stays where it is

-- true while the parker waits for the reverser to make room (the caller returns)
function ADTrafficYieldModule:requestMoreRoom(dt)
    local plan = self.plan
    local room = plan.moreRoom
    if room ~= nil and room.pending then
        self:holdVehicle(dt)
        return true
    end
    if room ~= nil and room.failed then
        return false
    end
    if (plan.moreRoomCount or 0) >= ADTrafficYieldModule.MORE_ROOM_TRIES or plan.mode == "branch" then
        return false
    end
    plan.moreRoomCount = (plan.moreRoomCount or 0) + 1
    plan.moreRoom = {pending = true}
    self:log("%s too close in front before I am off the road: it backs off %d m more (%d/%d)", ADTrafficYieldModule.getName(self.partner),
        ADTrafficYieldModule.MORE_ROOM, plan.moreRoomCount, ADTrafficYieldModule.MORE_ROOM_TRIES)
    self:holdVehicle(dt)
    return true
end

-- the move timer does not run while the parker waits for room
function ADTrafficYieldModule:parkTimeout(dt, limit)
    local room = self.plan.moreRoom
    return self.stateTimer:timer(true, limit, room ~= nil and room.pending and 0 or dt)
end

function ADTrafficYieldModule:updateParkerMove(dt)
    local plan = self.plan
    local spot = plan.parkSpot
    local _, _, spotLocalZ = AutoDrive.worldToLocal(self.vehicle, spot.x, spot.y, spot.z)
    local _, _, finalLocalZ = AutoDrive.worldToLocal(self.vehicle, spot.finalX, spot.y, spot.finalZ)

    -- keep a safety distance to the waiting reverser
    local reverser = self.partner
    local rx, ry, rz = ADTrafficYieldModule.getPosition(reverser)
    local reverserLocalX, _, reverserLocalZ = AutoDrive.worldToLocal(self.vehicle, rx, ry, rz)
    local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local reverserFrontExtent = ADTrafficYieldModule.getTrainExtents(reverser)
    local sideBySide = math.abs(reverserLocalX) > (ADTrafficYieldModule.getWidth(self.vehicle) + ADTrafficYieldModule.getWidth(reverser)) / 2
    local tooCloseToReverser = not sideBySide and (reverserLocalZ - reverserFrontExtent) - myFront < 3

    -- parallel path along the route (curves followed)
    if spot.path ~= nil then
        if tooCloseToReverser and self:requestMoreRoom(dt) then
            return
        end
        if tooCloseToReverser then
            self:log("parked early: %s too close in front, the train may not be aligned", ADTrafficYieldModule.getName(reverser))
        end
        if tooCloseToReverser or self:followParkPath(dt, spot) or self:parkTimeout(dt, 60000) then
            self.pathIndex = nil
            -- owner 30/10 16:37 (B): the other one goes once my whole train, trailer included, is off the road
            if tooCloseToReverser or self:isRearOnPath(spot.path) then
                plan.parked = true
            else
                self:log("at the end of the roadside path, trailer still on the road: %s waits", ADTrafficYieldModule.getName(reverser))
                print(string.format("[AD-Croise] %s: remorque pas encore hors du chemin, %s attend", ADTrafficYieldModule.getName(self.vehicle),
                    ADTrafficYieldModule.getName(reverser)))
            end
            self:setState(ADTrafficYieldModule.STATE_PARKER_WAIT)
            self:holdVehicle(dt)
        end
        return
    end

    local rearAligned = self:getRearLateralOffset(spot) >= math.abs(spot.lateralAbs) - 0.2 and self:isLastUnitParallel(spot)
    local reachedFinal = finalLocalZ <= 0.5

    if tooCloseToReverser and not (reachedFinal and rearAligned) and self:requestMoreRoom(dt) then
        return
    end
    if (reachedFinal and rearAligned) or finalLocalZ <= -6 or tooCloseToReverser then
        self:log("parked: %s", (reachedFinal and rearAligned) and "aligned on the spot" or (finalLocalZ <= -6 and "spot passed")
            or string.format("%s too close in front, may still be on the road", ADTrafficYieldModule.getName(reverser)))
        plan.parked = true
        self:setState(ADTrafficYieldModule.STATE_PARKER_WAIT)
        self:holdVehicle(dt)
        return
    end

    if self:parkTimeout(dt, 45000) then
        self:log("parked: 45 s timeout, may still be on the road")
        plan.parked = true
        self:setState(ADTrafficYieldModule.STATE_PARKER_WAIT)
        self:holdVehicle(dt)
        return
    end

    -- obstacle in front while moving to the spot (pedestrian, AI traffic...)
    if self.vehicle.ad.sensors ~= nil and self.vehicle.ad.sensors.frontSensor ~= nil and self.vehicle.ad.sensors.frontSensor:pollInfo() and spotLocalZ > 4 then
        self:holdVehicle(dt)
        return
    end

    -- first swerve to the roadside line, then follow it straight so the towed units line up
    local aimTarget
    if spotLocalZ > 6 then
        aimTarget = {x = spot.x, y = spot.y, z = spot.z}
    else
        aimTarget = {x = spot.aimX, y = spot.y, z = spot.aimZ}
    end
    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    self:ensureMotorStarted()
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, aimTarget, ADTrafficYieldModule.PARK_SPEED, false, 0.5, ADTrafficYieldModule.PARK_SPEED)
end

-- true when 'watched' has driven past me. Measured along the road direction (not my own axis, which can
-- be turned after pulling over), plus a fallback: it no longer comes towards me and is far enough.
function ADTrafficYieldModule:hasPassedMe(watched, dirX, dirZ)
    if watched == nil or watched.components == nil then
        return true
    end
    local px, _, pz = ADTrafficYieldModule.getPosition(self.vehicle)
    local wx, _, wz = ADTrafficYieldModule.getPosition(watched)
    if dirX == nil or dirZ == nil then
        dirX, dirZ = ADTrafficYieldModule.getDirection(self.vehicle)
    end
    local myFront, myRear = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local _, watchedRear = ADTrafficYieldModule.getTrainExtents(watched)
    local along = (wx - px) * dirX + (wz - pz) * dirZ
    if along < -(myRear + watchedRear + 2) then
        return true
    end
    -- the watched vehicle drives away from me and is past my front
    local distance = MathUtil.vector2Length(wx - px, wz - pz)
    if along < -myFront and distance > myFront + myRear + watchedRear + 5 then
        local wdx, wdz = ADTrafficYieldModule.getDirection(watched)
        if (wdx * (wx - px) + wdz * (wz - pz)) > 0 then
            return true
        end
    end
    return false
end

-- a train stopped before being lined up on its roadside path (other vehicle too close in front) still blocks
-- the road with its trailer: as soon as the way ahead is clear, it drives on along the path until aligned.
-- Returns true while it drives (the caller must not hold the vehicle)
function ADTrafficYieldModule:finishAlignment(dt, spot, watched)
    if spot == nil or spot.path == nil or self.alignmentDone then
        return false
    end
    if self:isRearOnPath(spot.path) then
        self.alignmentDone = true
        self.pathIndex = nil
        return false
    end
    if watched ~= nil and watched.components ~= nil then
        local wx, wy, wz = ADTrafficYieldModule.getPosition(watched)
        local watchedLocalX, _, watchedLocalZ = AutoDrive.worldToLocal(self.vehicle, wx, wy, wz)
        local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        local watchedFront = ADTrafficYieldModule.getTrainExtents(watched)
        local sideBySide = math.abs(watchedLocalX) > (ADTrafficYieldModule.getWidth(self.vehicle) + ADTrafficYieldModule.getWidth(watched)) / 2
        if not sideBySide and watchedLocalZ > 0 and (watchedLocalZ - watchedFront) - myFront < 3 then
            return false
        end
    end
    if self.vehicle.ad.sensors ~= nil and self.vehicle.ad.sensors.frontSensor ~= nil and self.vehicle.ad.sensors.frontSensor:pollInfo() then
        return false
    end
    if (self.alignmentTime or 0) == 0 then
        self:log("finishing the alignment on the roadside path")
    end
    self.alignmentTime = (self.alignmentTime or 0) + dt
    if self.alignmentTime > 30000 or self:followParkPath(dt, spot) then
        self.alignmentDone = true
        self.pathIndex = nil
        return false
    end
    return true
end

function ADTrafficYieldModule:updateParkerWait(dt)
    local plan = self.plan
    if not self:finishAlignment(dt, plan.parkSpot, self.partner) then
        self:holdVehicle(dt)
    end
    -- B: the other one waits until the trailer is off the road (or the alignment gave up after 30 s)
    if not plan.parked and (self.alignmentDone or plan.parkSpot == nil or plan.parkSpot.path == nil) then
        plan.parked = true
        local off = plan.parkSpot == nil or plan.parkSpot.path == nil or self:isRearOnPath(plan.parkSpot.path)
        self:log("trailer %s, %s may pass", off and "off the road" or "maybe still on the road", ADTrafficYieldModule.getName(self.partner))
        print(string.format("[AD-Croise] %s: %s, %s peut passer", ADTrafficYieldModule.getName(self.vehicle),
            off and "remorque hors du chemin" or "remorque peut-etre encore sur le chemin (alignement abandonne apres 30 s)", ADTrafficYieldModule.getName(self.partner)))
    end
    if plan.passed then
        self:endPlan("reverser passed", true)
        return
    end
    -- double check from parker side: the reverser is behind us (along the road)
    local spot = plan.parkSpot
    if self:hasPassedMe(self.partner, spot and spot.dirX, spot and spot.dirZ) then
        plan.passed = true
        self:endPlan("reverser passed", true)
        return
    end
    if self.stateTimer:timer(true, 120000, dt) then
        self:endPlan("parker wait timeout", false)
    end
end

function ADTrafficYieldModule:updateParkerPass(dt)
    -- normal driving, watch until the hidden reverser is behind us
    local reverser = self.partner
    local rx, ry, rz = ADTrafficYieldModule.getPosition(reverser)
    local _, _, reverserLocalZ = AutoDrive.worldToLocal(self.vehicle, rx, ry, rz)
    local myLength = ADTrafficYieldModule.getTotalLength(self.vehicle)
    if reverserLocalZ < -(myLength + 3) and not ADTrafficYieldModule.isAheadOnMyRoute(self.vehicle, reverser) then
        self.plan.passed = true
        self:endPlan("parker passed the side branch", true)
        return
    end
    if self.stateTimer:timer(true, 90000, dt) then
        self:endPlan("parker pass timeout", false)
    end
end


------------------------------------------------------------------------------------------------
-- status text (owner 28/10 18:01 "dans les textes d'etat je veux qu'on me dise qui il attend", 18:28 "dans le HUD,
-- 'Attend que le tracteur XXX arrive' au lieu de 'Conduit jusqu'au point'", go 18:29)
------------------------------------------------------------------------------------------------

-- what the vehicle waits for, or the manoeuvre it drives for another one, as an AutoDrive text ($l10n_ keys and names);
-- nil when it just drives. ADTaskModule shows it instead of the text of the task while it lasts
function ADTrafficYieldModule.getWaitInfo(vehicle)
    if vehicle == nil or vehicle.ad == nil then
        return nil
    end
    local getName = ADTrafficYieldModule.getName
    local stopped = ADTrafficYieldModule.getSpeedKmh(vehicle) < 1
    local function waitFor(other, what)
        return "$l10n_AD_ty_waitFor; " .. getName(other) .. " $l10n_AD_ty_" .. what .. ";"
    end
    local function doing(what, other)
        return "$l10n_AD_ty_" .. what .. "; " .. getName(other)
    end
    local m = vehicle.ad.trafficYieldModule
    if m ~= nil then
        local state, plan, partner = m.state, m.plan, m.partner
        if state == ADTrafficYieldModule.STATE_WAIT_DETACHED and m.waitFor ~= nil then
            return waitFor(m.waitFor, "toPass")
        end
        if partner ~= nil and plan ~= nil then
            if state == ADTrafficYieldModule.STATE_REVERSER_RETREAT or state == ADTrafficYieldModule.STATE_REVERSER_BRANCH then
                return doing("reverseFor", partner)
            elseif state == ADTrafficYieldModule.STATE_SECTION_CLEAR then
                return plan.parked and waitFor(partner, "toPass") or doing("reverseFor", partner)
            elseif state == ADTrafficYieldModule.STATE_REVERSER_HIDE or state == ADTrafficYieldModule.STATE_PARKER_WAIT then
                return waitFor(partner, "toPass")
            elseif state == ADTrafficYieldModule.STATE_PARKER_MOVE then
                return doing("parkFor", partner)
            elseif state == ADTrafficYieldModule.STATE_PARKER_SEARCH then
                return waitFor(partner, "toReverse")
            elseif state == ADTrafficYieldModule.STATE_REVERSER_WAIT then
                return waitFor(partner, plan.mode == "sectionClear" and "toClear" or "toPark")
            elseif state == ADTrafficYieldModule.STATE_YIELDER_APPROACH then
                if plan.sectionBackOff ~= nil then
                    return doing("reverseFor", partner)
                elseif plan.straightOn then
                    -- drives on along another way
                elseif plan.waitBeforeSection and (plan.parked or stopped) then
                    return waitFor(partner, "leaveTrack")
                elseif plan.parkSpot ~= nil then
                    return doing("parkFor", partner)
                elseif stopped then
                    return waitFor(partner, "toPass")
                end
            elseif state == ADTrafficYieldModule.STATE_PRIORITY_APPROACH and stopped then
                return waitFor(partner, "toPark")
            end
        end
        if m.anticipationHoldFor ~= nil and stopped then
            return waitFor(m.anticipationHoldFor, "toPass")
        end
    end
    -- red points (Intersection): what it waits for there
    local c = vehicle.ad.intersection
    if c ~= nil and c.holding and c.lastReason ~= nil then
        return "$l10n_AD_ty_crossing; " .. tostring(c.lastReason)
    end
    -- queue behind another AutoDrive vehicle
    local am = vehicle.ad.approachModule
    if stopped and am ~= nil and am.shouldStop ~= nil and am:shouldStop() then
        local hit = am:getHit()
        local root = hit ~= nil and hit.object ~= nil and hit.object.getRootVehicle ~= nil and hit.object:getRootVehicle() or nil
        local name = root ~= nil and getName(root) or "?"
        if name == "?" and hit ~= nil and hit.name ~= nil then
            name = tostring(hit.name)
        end
        return "$l10n_AD_ty_queue; " .. name
    end
    return nil
end
