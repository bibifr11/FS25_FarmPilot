-- ============================================================================================================
-- FarmPilot : CornerModule.lua
-- Virages serrés d'une route du réseau : prendre large, petit recul avant le virage, fin de route trop serrée.
-- Commun à tous les attelages (rien de propre à la moissonneuse ni à l'ensileuse).
--
-- Les virages serrés d'une route du réseau sont conduits « de point en point » : le tracteur braque aux points,
-- arrive en butée de direction, et la remorque coupe l'intérieur : l'attelage sort du chemin ou touche un bâtiment au
-- passage. Un vrai chauffeur prend large, et quand même cela ne passe pas, recule un peu pour prendre le virage plus
-- large.
--
-- Quand une route du réseau est donnée, chaque virage serré est examiné. Un virage est un seul point aigu, ou plusieurs
-- points proches qui tournent du même côté (une courbe dessinée avec beaucoup de points, un demi-tour autour d'une
-- place de parking) : leurs angles s'additionnent. Un virage compte quand il tourne d'au moins BEND_MIN_ANGLE et que
-- son rayon dessiné est plus petit que le rayon de braquage de l'attelage.
--
-- Pour chaque virage :
--   1. candidats : les plus courts chemins au vrai rayon de braquage (arc, droite, arc) d'un point de la route avant
--      le virage à un point de la route après, pour que prendre large à l'entrée ou à la sortie vienne tout seul ;
--   2. la route dessinée est conduite d'abord dans une simulation de tout l'attelage (le tracteur suit la ligne comme
--      AutoDrive, braquage limité à son rayon, la remorque suit son point d'attelage). Les caisses du tracteur et de
--      la remorque sont contrôlées chaque mètre contre les obstacles fixes, les champs (sauf si la route est déjà sur
--      un champ) et le maillage de la route (quand la route est dessus). L'attelage passe : virage gardé tel quel
--      (08/11) ;
--   3. sinon, chaque candidat est simulé de la même façon, le plus grand rayon d'abord ; le premier qui passe
--      remplace le virage ;
--   4. sinon, manœuvre : l'attelage s'arrête à un point avant le virage, recule tout droit de quelques mètres (la
--      place derrière est contrôlée) et prend le virage de là ;
--   5. quand rien ne passe, le virage reste tel quel (log « nothing fits »).
-- Les points insérés sont des points de type pathfinder (sans id), comme le fait déjà le contournement d'obstacle.
--
-- Règles :
-- - 08/11 : le virage n'est touché que si c'est nécessaire : l'attelage passe la route dessinée = virage gardé tel
--   quel ;
-- - 08/11 : le plus grand rayon qui passe d'abord (virage plus doux et plus rapide), le vrai rayon en dernier ;
-- - 07/11 et 08/11 : fin de route trop serrée : manœuvre avant d'arriver ou autre chemin d'arrivée, le plus rapide.
--
-- Ce fichier : la table, les réglages communs, les outils partagés, la géométrie de l'attelage, les contrôles du
-- terrain, la simulation de l'attelage le long d'une ligne, les plus courts chemins arc-droite-arc, et la conduite à
-- chaque image (recul avant un virage, appel de la manœuvre de fin de route). Le reste, par sujet, dans des fichiers
-- chargés juste après celui-ci (register.lua) :
--   CornerModuleBends.lua         virages de la route : repérer, redessiner plus large, sinon reculer avant
--   CornerModuleEndRoute.lua      fin de route trop serrée : simulation de l'arrivée, autre chemin d'arrivée (détour)
--   CornerModuleEndManoeuvre.lua  manœuvre de fin de route : calcul, puis conduite
--
-- Branché par : Specialization.lua (ADCornerModule:new -> vehicle.ad.cornerModule) ; DrivePathModuleObstacles.lua
-- (prepareRoute -> smoothRoute, handleDrivingModules -> handle, resetDrivingModules -> reset) ;
-- DrivePathModuleStuck.lua (isModuleManoeuvring -> isControlling) ; GraphManager.lua (pathFromTo -> avoidTightEnd,
-- markChanges vide endCache) ; TrafficYieldModule.lua (getTrainRadius -> getWheelRadius).
-- ============================================================================================================

ADCornerModule = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages communs
-- ------------------------------------------------------------------------------------------------------------
ADCornerModule.DEBUG = true -- temporary diagnostic logs for the tests
ADCornerModule.TRACE = false -- (09/11) chaque essai de virage dans le journal (bestPath, CornerModuleBends.lua) : coupé

local atan2 = math.atan2 or math.atan
local PI, TWO_PI = math.pi, 2 * math.pi

ADCornerModule.RADIUS_MAX = 14                 -- m, a larger estimate is a wheel data oddity
ADCornerModule.GROUND_CLEARANCE = 0.4          -- m above the ground where obstacles start (slabs, kerbs, plates do not count)
ADCornerModule.SIM_STEP = 0.5                  -- m per simulated step
ADCornerModule.CHECK_STEP = 1                  -- m between two body checks
ADCornerModule.GROUND_STEP = 2                 -- m between two field / road checks
ADCornerModule.BODY_MARGIN = 0.3               -- m added on each side of the bodies
ADCornerModule.REVERSE_SPEED = 6               -- km/h
ADCornerModule.REVERSE_TIMEOUT = 40000         -- ms
ADCornerModule.REAR_BLOCKED_TIME = 1500        -- ms the rear sensor must stay blocked to stop backing
ADCornerModule.ROAD_RAY_HEIGHT = 3             -- m above the terrain for the road mesh raycast
ADCornerModule.TYPES = {{1, 1}, {-1, -1}, {1, -1}, {-1, 1}} -- arc, straight, arc: turning sides (+1 = increasing angle)

-- ------------------------------------------------------------------------------------------------------------
-- Outils partagés (angles, distances, points du réseau)
-- Publiés dans la table (ADCornerModule.wrap...) pour les fichiers CornerModuleBends, EndRoute et EndManoeuvre.
-- ------------------------------------------------------------------------------------------------------------
local function wrap(a)
    a = (a + PI) % TWO_PI
    if a < 0 then
        a = a + TWO_PI
    end
    return a - PI
end
ADCornerModule.wrap = wrap

local function headingOf(dx, dz)
    return atan2(dx, dz)
end
ADCornerModule.headingOf = headingOf

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
ADCornerModule.bodyBox = bodyBox

local function isNetworkPoint(wp)
    return wp ~= nil and wp.id ~= nil and not wp.isPathFinderPoint
end
ADCornerModule.isNetworkPoint = isNetworkPoint

local function segHeading(a, b)
    return headingOf(b.x - a.x, b.z - a.z)
end
ADCornerModule.segHeading = segHeading

local function dist(a, b)
    return MathUtil.vector2Length(b.x - a.x, b.z - a.z)
end
ADCornerModule.dist = dist

-- signed turn at point i of a list (from i-1 -> i to i -> i+1)
local function turnAt(list, i)
    local a, b, c = list[i - 1], list[i], list[i + 1]
    if a == nil or b == nil or c == nil or dist(a, b) < 0.05 or dist(b, c) < 0.05 then
        return 0
    end
    return wrap(segHeading(b, c) - segHeading(a, b))
end
ADCornerModule.turnAt = turnAt

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place
-- ------------------------------------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------------------------------------
-- Géométrie de l'attelage (rayon de braquage, attelage, caisses)
-- ------------------------------------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------------------------------------
-- Contrôles du terrain (obstacles fixes, champ, maillage de la route)
-- ------------------------------------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------------------------------------
-- Simulation de l'attelage le long d'une ligne de points
-- ------------------------------------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------------------------------------
-- Plus courts chemins arc, droite, arc à un rayon donné (pose : x, z, cap a ; direction sin a, cos a)
-- ------------------------------------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------------------------------------
-- Conduite, à chaque image (appelée par followWaypoints, rend true tant que ce module conduit) :
-- recul avant un virage ; la manœuvre de fin de route est dans CornerModuleEndManoeuvre.lua
-- ------------------------------------------------------------------------------------------------------------
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
