-- ============================================================================================================
-- FarmPilot : ApproachModule.lua
-- Ralentissement anticipé devant un obstacle.
--
-- Les capteurs avant répondent seulement « quelque chose est dans la boîte », et AutoDrive freine alors fort
-- (stopVehicle). Ce module balaie la route devant avec des boîtes posées le long des prochains points du trajet
-- (un virage ne touche donc pas le bord de la route), jusqu'à la distance de freinage à la vitesse du moment, et
-- mesure la distance au véhicule ou à l'objet fixe le plus proche.
--
-- Règle : la vitesse maxi baisse progressivement, v = sqrt(2 * DECEL * (d - STOP_DISTANCE)) : le véhicule arrive
-- lentement là où les capteurs avant font encore l'arrêt final. Un véhicule plus lent devant est suivi à sa propre
-- vitesse, sans arrêts et redémarrages. Derrière un autre véhicule AutoDrive, arrêt à VEHICLE_GAP m (shouldStop).
-- Couloir décalé (écart, S8 28/10) : véhicules cherchés sur toute la hauteur (roues, plateaux bas).
-- Tout tourne sur le serveur, appelé à chaque image depuis ADDrivePathModule:followWaypoints.
--
-- Branché par : Specialization.lua (new) ; DrivePathModuleObstacles.lua (reset, getSpeedLimit, shouldStop) ; lu par
-- AvoidModule.lua (getHit, getEstimatedDistance, isCorridorClear), ObstacleDetourModule.lua (getHit,
-- getEstimatedDistance, shouldStop), IntersectionModule.lua (getHit) et TrafficYieldModule.lua (getTrainWidth,
-- SIDE_MARGIN).
-- ============================================================================================================

ADApproachModule = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADApproachModule.DEBUG = true -- temporary diagnostic logs for the tests

ADApproachModule.DECEL = 1.8             -- m/s², comfortable deceleration
ADApproachModule.STOP_DISTANCE = 4       -- m kept in front of the obstacle (the front sensors stop earlier if needed)
ADApproachModule.VEHICLE_GAP = 3             -- m kept behind another AutoDrive vehicle (room to manoeuvre)
ADApproachModule.MIN_SPEED = 4           -- km/h, floor while approaching: the vehicle creeps to the stop sensors
ADApproachModule.MIN_RANGE = 12          -- m scanned at least
ADApproachModule.MAX_RANGE = 60          -- m scanned at most
ADApproachModule.RANGE_MARGIN = 5        -- m added to the braking distance
ADApproachModule.BOX_MAX_LENGTH = 4      -- m, length of one scan box along the route
ADApproachModule.BOX_HALF_HEIGHT = 0.4   -- m
-- S8 (28/10 17:43, the 8510 with its low loader shifted 1.5 m beside the Patriot 4450 and wedged against it: the
-- boxes only cover the collision height band, 2.0 .. 2.8 m above the ground, and missed its wheels and low parts): a
-- shifted corridor is tested for vehicles from TALL_BOX_BOTTOM to TALL_BOX_TOP m above the ground
ADApproachModule.TALL_BOX_BOTTOM = 0.4   -- m
ADApproachModule.TALL_BOX_TOP = 3.6      -- m
ADApproachModule.SIDE_MARGIN = 0.3       -- m added on each side of the train width (vehicles)
ADApproachModule.OBJECT_WIDTH_FACTOR = 0.75 -- static objects: same corridor as the front sensor (vehicle width * 0.75),
                                            -- a wider one would crawl along every pylon or hedge close to the road
ADApproachModule.SCAN_FRAMES = 8         -- one scan every n frames
ADApproachModule.SLOW_SCAN_FRAMES = 24   -- one scan every n frames when stopped or creeping (multiple of SCAN_FRAMES)
ADApproachModule.SLOW_SPEED = 3          -- km/h, below this the slow scan rate is used
ADApproachModule.LOG_INTERVAL = 3000     -- ms between two logs of the same state

ADApproachModule.STATE_FREE = 0
ADApproachModule.STATE_SLOWING = 1
ADApproachModule.STATE_NAMES = {[0] = "FREE", [1] = "SLOWING"}

-- ------------------------------------------------------------------------------------------------------------
-- Création et état (lus par AvoidModule, ObstacleDetourModule, IntersectionModule)
-- ------------------------------------------------------------------------------------------------------------
function ADApproachModule:new(vehicle)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.vehicle = vehicle
    o.state = ADApproachModule.STATE_FREE
    o.distance = nil          -- m to the nearest obstacle along the route, nil = nothing in range
    o.hitName = nil
    o.scanX, o.scanZ = nil, nil
    o.boxes = {}
    o.lastLogTime = -math.huge
    return o
end

function ADApproachModule:reset()
    self.state = ADApproachModule.STATE_FREE
    self.distance = nil
    self.hitName = nil
    self.hit = nil
    self.boxes = {}
end

function ADApproachModule.isEnabled()
    return (AutoDrive.getSetting("enableTrafficDetection") or 0) >= 1
end

-- last obstacle seen on the route (table: distance, name, object, isVehicle, isTraffic, node, x, z, nx, nz, side, time), nil when free
function ADApproachModule:getHit()
    return self.hit
end

function ADApproachModule:getDistance()
    return self.distance
end

-- true when the vehicle must stop now: another AutoDrive vehicle closer than VEHICLE_GAP on the route
-- (the sensors alone stop at 0.6 m, too close to back off or to let it reverse)
function ADApproachModule:shouldStop()
    local hit = self.hit
    if hit == nil or not hit.isVehicle or hit.object == nil or not self.vehicle.isServer or not ADApproachModule.isEnabled() then
        return false
    end
    local root = hit.object.getRootVehicle ~= nil and hit.object:getRootVehicle() or hit.object
    if root == nil or root.ad == nil then
        return false
    end
    if self.vehicle.ad.avoidModule ~= nil and self.vehicle.ad.avoidModule:isActive() then
        return false
    end
    local distance = self:getEstimatedDistance()
    return distance ~= nil and distance < ADApproachModule.VEHICLE_GAP
end

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
function ADApproachModule:log(text, ...)
    if ADApproachModule.DEBUG then
        local name = self.vehicle.ad ~= nil and self.vehicle.ad.stateModule ~= nil and self.vehicle.ad.stateModule:getName() or "?"
        print(string.format("[AD-Obst] %s (%s) [%s]: " .. text, tostring(name), tostring(self.vehicle.id),
            ADApproachModule.STATE_NAMES[self.state] or tostring(self.state), ...))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Géométrie de l'attelage
-- ------------------------------------------------------------------------------------------------------------
function ADApproachModule:getTrainWidth()
    local width = self.vehicle.size ~= nil and self.vehicle.size.width or 3
    local implements = AutoDrive.getAllImplements(self.vehicle, false)
    if implements ~= nil then
        for _, implement in pairs(implements) do
            if implement ~= nil and implement.size ~= nil and implement.size.width ~= nil then
                width = math.max(width, implement.size.width)
            end
        end
    end
    return width
end

function ADApproachModule:getFrontPosition()
    local front = 0
    if self.vehicle.ad ~= nil and self.vehicle.ad.adDimensions ~= nil and self.vehicle.ad.adDimensions.maxLengthFront ~= nil and self.vehicle.ad.adDimensions.maxLengthFront > 0 then
        front = self.vehicle.ad.adDimensions.maxLengthFront
    elseif self.vehicle.size ~= nil and self.vehicle.size.length ~= nil then
        front = self.vehicle.size.length / 2 + 0.5
    end
    local x, y, z = AutoDrive.localToWorld(self.vehicle, 0, 0, front)
    return x, y, z
end

-- braking distance at the current speed, plus a margin
function ADApproachModule:getRange()
    local speed = math.abs(self.vehicle.lastSpeedReal or 0) * 3600 / 3.6 -- m/s
    local range = speed * speed / (2 * ADApproachModule.DECEL) + ADApproachModule.STOP_DISTANCE + ADApproachModule.RANGE_MARGIN
    return math.clamp(range, ADApproachModule.MIN_RANGE, ADApproachModule.MAX_RANGE)
end

-- ------------------------------------------------------------------------------------------------------------
-- Boîtes le long de la route, du nez du véhicule à <range> m plus loin
-- ------------------------------------------------------------------------------------------------------------
-- offset: lateral shift of the corridor (m, along the left normal of each stretch), used while avoiding
function ADApproachModule:buildBoxes(range, offset)
    offset = offset or 0
    local boxes = {}
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil or wayPoints[currentIndex] == nil then
        return boxes
    end
    local halfWidth = self:getTrainWidth() * 0.5 + ADApproachModule.SIDE_MARGIN
    local halfWidthObjects = (self.vehicle.size ~= nil and self.vehicle.size.width or 3) * ADApproachModule.OBJECT_WIDTH_FACTOR * 0.5
    local heightOffset = (AutoDrive.getSetting("collisionHeigth", self.vehicle) or 1) + ADApproachModule.BOX_HALF_HEIGHT

    local ax, ay, az = self:getFrontPosition()
    local travelled = 0
    local index = currentIndex
    local previous = nil
    -- shifted corridor: every route point is moved along the left normal of the route at that point,
    -- so the first stretch (vehicle nose -> next point) stays parallel to the route
    local function shiftedPoint(i)
        local wp = wayPoints[i]
        if offset == 0 then
            return wp.x, wp.y or ay, wp.z
        end
        local a = wayPoints[i - 1] or wp
        local b = wayPoints[i + 1] or wp
        local dx, dz = b.x - a.x, b.z - a.z
        local l = MathUtil.vector2Length(dx, dz)
        if l < 0.1 then
            return wp.x, wp.y or ay, wp.z
        end
        return wp.x + dz / l * offset, wp.y or ay, wp.z - dx / l * offset
    end
    if offset ~= 0 then
        -- the shifted corridor starts beside the nose, parallel to the route (is the lane next to me free ?):
        -- from the foot of the nose on the current stretch, moved by the offset, wherever the vehicle already is
        local b = wayPoints[currentIndex]
        local a = wayPoints[currentIndex - 1]
        local dx, dz = 0, 0
        if a ~= nil then
            dx, dz = b.x - a.x, b.z - a.z
        else
            local c = wayPoints[currentIndex + 1]
            if c ~= nil then
                dx, dz = c.x - b.x, c.z - b.z
            end
        end
        local l = MathUtil.vector2Length(dx, dz)
        if l > 0.1 then
            dx, dz = dx / l, dz / l
            local t = (ax - b.x) * dx + (az - b.z) * dz
            ax, az = b.x + dx * t + dz * offset, b.z + dz * t - dx * offset
        end
    end
    while travelled < range do
        local wp = wayPoints[index]
        if wp == nil then
            break
        end
        if previous ~= nil and ADGraphManager:isReverseRoad(previous, wp) then
            break
        end
        local bx, by, bz = shiftedPoint(index)
        local len = MathUtil.vector2Length(bx - ax, bz - az)
        if len > 0.5 then
            local usable = math.min(len, range - travelled)
            local n = math.max(1, math.ceil(usable / ADApproachModule.BOX_MAX_LENGTH))
            local ry = math.atan2(bx - ax, bz - az)
            local dirX, dirZ = (bx - ax) / len, (bz - az) / len
            for k = 0, n - 1 do
                local d0 = usable * k / n
                local d1 = usable * (k + 1) / n
                local mid = (d0 + d1) * 0.5
                -- left normal of the stretch: (dirZ, -dirX)
                local cx, cz = ax + dirX * mid, az + dirZ * mid
                -- route height (bridges) or terrain, whichever is higher, like the front sensors
                local routeY = ay + (by - ay) * (mid / len)
                local cy = math.max(getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 300, cz), routeY) + heightOffset
                table.insert(boxes, {
                    x = cx, y = cy, z = cz, ry = ry, nx = dirZ, nz = -dirX, groundY = cy - heightOffset,
                    halfWidth = halfWidth, halfWidthObjects = halfWidthObjects, halfLength = (d1 - d0) * 0.5,
                    distance = travelled + d0
                })
            end
            travelled = travelled + usable
        end
        ax, ay, az = bx, by, bz
        previous = wp
        index = index + 1
    end
    return boxes
end

-- S8: centre height and half height of the tall vehicle box over a scan box
function ADApproachModule.getTallBox(b)
    local ground = b.groundY or (b.y - ADApproachModule.BOX_HALF_HEIGHT - 1)
    local half = (ADApproachModule.TALL_BOX_TOP - ADApproachModule.TALL_BOX_BOTTOM) * 0.5
    return ground + ADApproachModule.TALL_BOX_BOTTOM + half, half
end

-- ------------------------------------------------------------------------------------------------------------
-- Test de chevauchement
-- ------------------------------------------------------------------------------------------------------------
function ADApproachModule:isIgnored(object, node)
    if object == nil then
        -- unknown shape (traffic sign...) ignored the same way the sensors do
        return not ADSensor.isElementBlockingVehicle(self, node)
    end
    local root = self.vehicle:getRootVehicle()
    if object == self.vehicle or object == root or AutoDrive:checkIsConnected(root, object) then
        return true
    end
    -- the unloader assigned to me (I am the harvester) or the harvester I serve
    local unloadDriver = ADHarvestManager:getAssignedUnloader(self.vehicle.ad.attachableCombine or self.vehicle)
    if unloadDriver ~= nil and (object == unloadDriver or AutoDrive:checkIsConnected(unloadDriver:getRootVehicle(), object)) then
        return true
    end
    for _, excluded in pairs(self.excluded or {}) do
        if excluded ~= nil and (object == excluded or AutoDrive:checkIsConnected(excluded, object)) then
            return true
        end
    end
    -- the vehicle that waits for me on purpose before a single track (TrafficYield plan)
    local yieldModule = self.vehicle.ad.trafficYieldModule
    if yieldModule ~= nil and yieldModule.plan ~= nil and yieldModule.plan.parked and yieldModule.plan.waitBeforeSection and yieldModule.partner ~= nil then
        local partner = yieldModule.partner
        if object == partner or (object.getRootVehicle ~= nil and object:getRootVehicle() == partner) or AutoDrive:checkIsConnected(partner, object) then
            return true
        end
    end
    return false
end

function ADApproachModule:overlapCallback(node)
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
    if self:isIgnored(object, node) then
        return true
    end
    self.scanHit = true
    self.scanHitObject = object
    self.scanHitNode = node
    if object ~= nil and object.getName ~= nil then
        self.scanHitName = object:getName()
    elseif getName ~= nil then
        self.scanHitName = getName(node)
    else
        self.scanHitName = "?"
    end
    return false -- first hit is enough
end

-- which half of the box holds the obstacle: -1 (side of -normal), 1 (side of +normal), 0 (both or unknown)
function ADApproachModule:findSide(b, halfWidth, mask)
    local sides = {}
    for _, sign in ipairs({-1, 1}) do
        self.scanHit = false
        local cx, cz = b.x + b.nx * sign * halfWidth * 0.5, b.z + b.nz * sign * halfWidth * 0.5
        overlapBox(cx, b.y, cz, 0, b.ry, 0, halfWidth * 0.5, ADApproachModule.BOX_HALF_HEIGHT, b.halfLength, "overlapCallback", self, mask, true, true, true, true)
        sides[sign] = self.scanHit
    end
    if sides[-1] and not sides[1] then
        return -1
    elseif sides[1] and not sides[-1] then
        return 1
    end
    return 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Balayage de la route, couloir décalé libre ?
-- ------------------------------------------------------------------------------------------------------------
function ADApproachModule:scan()
    local range = self:getRange()
    local offset = 0
    if self.vehicle.ad.avoidModule ~= nil then
        offset = self.vehicle.ad.avoidModule:getOffset()
        range = math.max(range, self.vehicle.ad.avoidModule:getScanRange())
    end
    self.boxes = self:buildBoxes(range, offset)
    local task = self.vehicle.ad.taskModule ~= nil and self.vehicle.ad.taskModule:getActiveTask() or nil
    self.excluded = (task ~= nil and task.getExcludedVehiclesForCollisionCheck ~= nil) and task:getExcludedVehiclesForCollisionCheck() or {}
    local found = nil
    self.hit = nil
    for _, b in ipairs(self.boxes) do
        self.scanHit = false
        self.scanHitName = nil
        self.scanHitObject = nil
        self.scanHitNode = nil
        -- vehicles: the whole train width; static objects: the narrower corridor of the front sensor
        local isVehicle, halfWidth, mask = true, b.halfWidth, ADCollSensorSplit.maskVehicles
        if offset ~= 0 then
            -- S8: while shifted beside an obstacle, vehicles are watched over the whole height
            local tallY, tallHalf = ADApproachModule.getTallBox(b)
            overlapBox(b.x, tallY, b.z, 0, b.ry, 0, b.halfWidth, tallHalf, b.halfLength, "overlapCallback", self, mask, true, true, true, true)
        else
            overlapBox(b.x, b.y, b.z, 0, b.ry, 0, b.halfWidth, ADApproachModule.BOX_HALF_HEIGHT, b.halfLength, "overlapCallback", self, mask, true, true, true, true)
        end
        if not self.scanHit then
            isVehicle, halfWidth, mask = false, b.halfWidthObjects, ADCollSensorSplit.maskObjects
            overlapBox(b.x, b.y, b.z, 0, b.ry, 0, b.halfWidthObjects, ADApproachModule.BOX_HALF_HEIGHT, b.halfLength, "overlapCallback", self, mask, true, true, true, true)
        end
        if self.scanHit then
            found = b.distance
            self.hitName = self.scanHitName
            b.hit = true
            local object = self.scanHitObject
            -- a vehicle node without a game object is an AI traffic car (it only waits for us, never for long)
            self.hit = {distance = b.distance, name = self.scanHitName, object = object, isVehicle = isVehicle,
                        isTraffic = isVehicle and object == nil, node = self.scanHitNode,
                        x = b.x, z = b.z, nx = b.nx, nz = b.nz, side = self:findSide(b, halfWidth, mask), time = g_time}
            break
        end
    end
    self.excluded = nil
    self.distance = found
    self.scanX, _, self.scanZ = getWorldTranslation(self.vehicle.components[1].node)
    self.scanRange = range
end

-- true when the corridor shifted by <offset> is free of vehicles and static objects over <range> metres
function ADApproachModule:isCorridorClear(offset, range)
    local boxes = self:buildBoxes(range, offset)
    local task = self.vehicle.ad.taskModule ~= nil and self.vehicle.ad.taskModule:getActiveTask() or nil
    self.excluded = (task ~= nil and task.getExcludedVehiclesForCollisionCheck ~= nil) and task:getExcludedVehiclesForCollisionCheck() or {}
    local clear, reason = true, nil
    for _, b in ipairs(boxes) do
        self.scanHit = false
        if offset ~= nil and offset ~= 0 then
            -- S8: vehicles over the whole height (wheels, decks, ramps), static objects in the usual band
            local tallY, tallHalf = ADApproachModule.getTallBox(b)
            overlapBox(b.x, tallY, b.z, 0, b.ry, 0, b.halfWidth, tallHalf, b.halfLength, "overlapCallback", self, ADCollSensorSplit.maskVehicles, true, true, true, true)
            if not self.scanHit then
                overlapBox(b.x, b.y, b.z, 0, b.ry, 0, b.halfWidth, ADApproachModule.BOX_HALF_HEIGHT, b.halfLength, "overlapCallback", self, ADCollSensorSplit.maskObjects, true, true, true, true)
            end
        else
            overlapBox(b.x, b.y, b.z, 0, b.ry, 0, b.halfWidth, ADApproachModule.BOX_HALF_HEIGHT, b.halfLength, "overlapCallback", self, ADCollSensorSplit.maskVehicles + ADCollSensorSplit.maskObjects, true, true, true, true)
        end
        if self.scanHit then
            clear, reason = false, string.format("'%s' at %.0f m", tostring(self.scanHitName), b.distance)
            break
        end
    end
    self.excluded = nil
    return clear, reason
end

-- ------------------------------------------------------------------------------------------------------------
-- Loi de vitesse
-- ------------------------------------------------------------------------------------------------------------
function ADApproachModule.speedForDistance(distance)
    local free = distance - ADApproachModule.STOP_DISTANCE
    if free <= 0 then
        return ADApproachModule.MIN_SPEED
    end
    local speed = math.sqrt(2 * ADApproachModule.DECEL * free) * 3.6
    return math.max(ADApproachModule.MIN_SPEED, speed)
end

-- distance corrected by the way driven since the last scan (the obstacle is taken as standing still)
function ADApproachModule:getEstimatedDistance()
    if self.distance == nil then
        return nil
    end
    if self.scanX ~= nil then
        local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
        local moved = MathUtil.vector2Length(x - self.scanX, z - self.scanZ)
        return math.max(0, self.distance - moved)
    end
    return self.distance
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale, appelée à chaque image par ADDrivePathModule:followWaypoints (serveur)
-- renvoie la vitesse maxi (km/h) permise par les obstacles devant, math.huge quand la route est libre
-- ------------------------------------------------------------------------------------------------------------
function ADApproachModule:getSpeedLimit(dt)
    if not self.vehicle.isServer or not ADApproachModule.isEnabled() then
        return math.huge
    end
    -- stopped or creeping: the route ahead hardly changes, fewer scans (the distance is still estimated every frame)
    local frames = ADApproachModule.SCAN_FRAMES
    if math.abs(self.vehicle.lastSpeedReal or 0) * 3600 < ADApproachModule.SLOW_SPEED then
        frames = ADApproachModule.SLOW_SCAN_FRAMES
    end
    if ((g_updateLoopIndex + self.vehicle.id) % frames) == 0 then
        self:scan()
    end
    self:drawDebug()

    local distance = self:getEstimatedDistance()
    if distance == nil then
        if self.state ~= ADApproachModule.STATE_FREE then
            self.state = ADApproachModule.STATE_FREE
            self:log("route free again")
        end
        return math.huge
    end

    local limit = ADApproachModule.speedForDistance(distance)
    if self.state ~= ADApproachModule.STATE_SLOWING then
        self.state = ADApproachModule.STATE_SLOWING
        self.lastLogTime = g_time
        self:log("'%s' %.1f m ahead on the route (range %.0f m): speed limited to %.0f km/h (driving %.0f km/h)",
            tostring(self.hitName), distance, self.scanRange or 0, limit, math.abs(self.vehicle.lastSpeedReal or 0) * 3600)
    elseif g_time - self.lastLogTime > ADApproachModule.LOG_INTERVAL then
        self.lastLogTime = g_time
        self:log("'%s' %.1f m ahead: speed limited to %.0f km/h (driving %.0f km/h)",
            tostring(self.hitName), distance, limit, math.abs(self.vehicle.lastSpeedReal or 0) * 3600)
    end
    return limit
end

-- ------------------------------------------------------------------------------------------------------------
-- Dessin de débogage (canal capteurs)
-- ------------------------------------------------------------------------------------------------------------
function ADApproachModule:drawDebug()
    if not AutoDrive.getDebugChannelIsSet(AutoDrive.DC_SENSORINFO) then
        return
    end
    for _, b in ipairs(self.boxes or {}) do
        if b.hit then
            DebugUtil.drawOverlapBox(b.x, b.y, b.z, 0, b.ry, 0, b.halfWidth, ADApproachModule.BOX_HALF_HEIGHT, b.halfLength, 1, 0.5, 0)
        else
            DebugUtil.drawOverlapBox(b.x, b.y, b.z, 0, b.ry, 0, b.halfWidth, ADApproachModule.BOX_HALF_HEIGHT, b.halfLength, 0, 1, 1)
            DebugUtil.drawOverlapBox(b.x, b.y, b.z, 0, b.ry, 0, b.halfWidthObjects, ADApproachModule.BOX_HALF_HEIGHT, b.halfLength, 0, 0.6, 0.6)
        end
    end
end
