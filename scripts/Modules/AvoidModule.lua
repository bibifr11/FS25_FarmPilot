-- ============================================================================================================
-- FarmPilot : AvoidModule.lua
-- Écart : obstacle léger sur un côté de la route (poteau, balle, panneau, voiture garée...) : le véhicule décale un
-- peu sa ligne suivie de l'autre côté et passe sans s'arrêter, puis revient.
--
-- Règle :
-- - Le balayage de route d'ADApproachModule donne l'obstacle devant, sa distance et le côté du couloir où il est.
--   Les décalages candidats (1 à 2,5 m à l'écart de l'obstacle) sont testés sur un couloir décalé sur CLEAR_RANGE m,
--   véhicules compris (rien ne doit venir en face). Le premier libre devient ADDrivePathModule.lateralOffset, amené
--   et retiré progressivement avec la distance roulée, tenu jusqu'à ce que tout l'attelage ait passé l'obstacle.
--   Vitesse limitée pendant ce temps.
-- - Seulement sur le réseau de routes : jamais dans un champ, jamais pendant un plan de face à face (TrafficYield)
--   ni pendant un contournement d'obstacle. Un véhicule ne compte comme obstacle qu'après VEHICLE_STILL_TIME à
--   l'arrêt.
-- - Voiture du trafic arrêtée devant, en travers du couloir (nez à nez : elle nous attend et on l'attend) :
--   changement de voie. Le véhicule recule juste ce qu'il faut (STATE_BACKING, comme le contournement), se décale
--   d'une voie entière (LANE_OFFSETS, côté droit d'abord) et passe ; la voiture repart une fois sa voie libre.
-- - Voiture ou véhicule arrêté dans MON sens (S5, 28/10) : une file, j'attends derrière, sans écart (une voiture
--   seule, sans rien devant elle, est doublée après QUEUE_TIMEOUT).
-- - Attelage qui pousse sans avancer contre un obstacle que les capteurs ne voient pas (08/11) : recul, puis
--   passage à côté (startFromPush).
-- Tout tourne sur le serveur, appelé à chaque image depuis ADDrivePathModule:followWaypoints.
--
-- Branché par : Specialization.lua (new) ; DrivePathModuleObstacles.lua (reset, update, handle, lateralOffset) ;
-- DrivePathModuleStuck.lua (isControlling, startFromPush) ; lu par ApproachModule.lua (getOffset, getScanRange,
-- isActive) et ObstacleDetourModule.lua (isActive, isQueuing). ObstacleDetourQueue.lua (chargé avant) enveloppe
-- isWaitingMyWay : dernière ligne de ce fichier.
-- ============================================================================================================

ADAvoidModule = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAvoidModule.DEBUG = true -- temporary diagnostic logs for the tests

ADAvoidModule.STATE_IDLE = 0
ADAvoidModule.STATE_SHIFTING = 1
ADAvoidModule.STATE_RETURNING = 2
ADAvoidModule.STATE_BACKING = 3
ADAvoidModule.STATE_NAMES = {[0] = "IDLE", [1] = "SHIFTING", [2] = "RETURNING", [3] = "BACKING"}

ADAvoidModule.OFFSETS = {1.0, 1.5, 2.0, 2.5}  -- m, tried in this order
ADAvoidModule.LANE_OFFSETS = {2.5, 3.0, 3.5}  -- m, lane change beside a stopped traffic car
ADAvoidModule.TRIGGER_DISTANCE = 25           -- m, obstacle closer than this: start the manoeuvre
ADAvoidModule.MIN_DISTANCE = 2                -- m, closer than this: too late, the sensors stop the vehicle
ADAvoidModule.CLEAR_RANGE = 60                -- m, the shifted corridor must be free that far (oncoming traffic)
ADAvoidModule.HOLD_RANGE = 15                 -- m, the shifted corridor is watched that far while passing
ADAvoidModule.RATE = 0.3                      -- m of offset per metre driven
ADAvoidModule.LANE_RATE = 0.5                 -- m of offset per metre driven for a lane change
ADAvoidModule.PASS_MARGIN = 4                 -- m driven past the obstacle before coming back
ADAvoidModule.SPEED = 12                      -- km/h cap while shifted
ADAvoidModule.START_SPEED = 20                -- km/h, the manoeuvre starts only below this
ADAvoidModule.VEHICLE_STILL_TIME = 5000       -- ms a vehicle must stand still to be avoided
ADAvoidModule.VEHICLE_STILL_SPEED = 0.5       -- km/h
ADAvoidModule.TRAFFIC_STILL_TIME = 2000       -- ms a traffic car must stand still (it only waits for us)
ADAvoidModule.TRAFFIC_STILL_MOVE = 0.3        -- m, a traffic car that moved more than this is driving
ADAvoidModule.BACK_MARGIN = 3                 -- m of room kept in front of the car after the lane change
ADAvoidModule.BACK_MAX = 15                   -- m, never back up more than this
ADAvoidModule.BACK_TIMEOUT = 20000            -- ms
ADAvoidModule.REAR_BLOCKED_TIME = 1500        -- ms the rear sensor must stay blocked to stop backing
ADAvoidModule.REVERSE_SPEED = 6               -- km/h
ADAvoidModule.CHECK_FRAMES = 8
ADAvoidModule.LOG_INTERVAL = 5000             -- ms between two "cannot avoid" logs for the same obstacle
ADAvoidModule.COOLDOWN = 2000                 -- ms after a manoeuvre before the next
ADAvoidModule.QUEUE_DOT = 0.5                 -- cos: a car or a vehicle heading this close to my direction drives my way
ADAvoidModule.QUEUE_LOOK = 30                 -- m beyond the stopped car searched for the vehicle it queues behind
ADAvoidModule.QUEUE_LATERAL = 3               -- m from my route (plus half the width of that vehicle)
ADAvoidModule.QUEUE_TIMEOUT = 45000           -- ms: a car standing my way with nothing in front of it may be passed after this
ADAvoidModule.QUEUE_HOLD = 4000               -- ms: the queue decision stays valid this long (it is renewed at each check)
ADAvoidModule.SHIFT_LAG = 2                   -- m: the train reaches the shifted line this much later than the line itself
ADAvoidModule.PUSH_OFFSETS = {1.5, 2.0, 2.5, 3.0} -- m, tried when the train pushes against something it does not see
ADAvoidModule.PUSH_BACK_MARGIN = 2            -- m backed up on top of what the shift needs

-- ------------------------------------------------------------------------------------------------------------
-- Création et état (lus par DrivePathModuleObstacles, ApproachModule, ObstacleDetourModule)
-- ------------------------------------------------------------------------------------------------------------
function ADAvoidModule:new(vehicle)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.vehicle = vehicle
    o.state = ADAvoidModule.STATE_IDLE
    o.offset = 0
    o.target = 0
    o.rate = ADAvoidModule.RATE
    o.stillObject = nil
    o.stillSince = nil
    o.trafficDirNode = nil    -- S5: the traffic car whose driving direction was seen, and that direction
    o.trafficDirX, o.trafficDirZ = nil, nil
    o.lastLogTime = -math.huge
    o.cooldownUntil = 0
    o.backTimer = AutoDriveTON:new()
    o.rearBlockedTimer = AutoDriveTON:new()
    return o
end

function ADAvoidModule:reset()
    if self.state == ADAvoidModule.STATE_BACKING and self.vehicle.ad ~= nil and self.vehicle.ad.specialDrivingModule ~= nil then
        self.vehicle.ad.specialDrivingModule:reset()
    end
    self.state = ADAvoidModule.STATE_IDLE
    self.offset = 0
    self.target = 0
    self.rate = ADAvoidModule.RATE
    self.travelled = 0
    self.passTravel = nil
    self.passerShift = nil
    self.passerLogged = nil
    self.stillObject = nil
    self.stillSince = nil
    self.backNeeded = nil
    self.backKind = nil
    self.backTimer:timer(false)
    self.rearBlockedTimer:timer(false)
    if self.vehicle.ad ~= nil and self.vehicle.ad.drivePathModule ~= nil then
        self.vehicle.ad.drivePathModule.lateralOffset = 0
    end
end

function ADAvoidModule.isEnabled()
    local enabled = AutoDrive.getSetting("avoidEnabled")
    return (enabled == nil or enabled == true or enabled == 1) and (AutoDrive.getSetting("enableTrafficDetection") or 0) >= 1
end

-- a stopped car in front of me queues behind another vehicle (or has not stood alone long enough): I wait behind it
function ADAvoidModule:isQueuing()
    return self.queueUntil ~= nil and g_time < self.queueUntil
end

function ADAvoidModule:isActive()
    return self.state ~= ADAvoidModule.STATE_IDLE or self.offset ~= 0
end

function ADAvoidModule:isControlling()
    return self.state == ADAvoidModule.STATE_BACKING
end

function ADAvoidModule:getOffset()
    return self.offset
end

-- how far ADApproachModule must scan while a manoeuvre runs
function ADAvoidModule:getScanRange()
    if self:isActive() then
        return ADAvoidModule.HOLD_RANGE
    end
    return 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
function ADAvoidModule:log(text, ...)
    if ADAvoidModule.DEBUG then
        local name = self.vehicle.ad ~= nil and self.vehicle.ad.stateModule ~= nil and self.vehicle.ad.stateModule:getName() or "?"
        print(string.format("[AD-Ecart] %s (%s) [%s]: " .. text, tostring(name), tostring(self.vehicle.id),
            ADAvoidModule.STATE_NAMES[self.state] or tostring(self.state), ...))
    end
end

function ADAvoidModule:logLimited(hit, text)
    if g_time - self.lastLogTime > ADAvoidModule.LOG_INTERVAL then
        self.lastLogTime = g_time
        self:log("'%s' %.1f m ahead: %s", tostring(hit.name), hit.distance or -1, text)
    end
end

function ADAvoidModule:getTrainLength()
    local length = self.vehicle.size ~= nil and self.vehicle.size.length or 6
    local units = AutoDrive.getAllUnits(self.vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit ~= self.vehicle and unit.size ~= nil and unit.size.length ~= nil then
                length = length + unit.size.length
            end
        end
    end
    return length
end

-- ------------------------------------------------------------------------------------------------------------
-- L'obstacle peut-il être contourné ?
-- ------------------------------------------------------------------------------------------------------------
function ADAvoidModule:isOnField()
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    return AutoDrive.checkIsOnField(x, y, z) == true
end

-- 31/10 08:24 PC (942 stopped on a row of cones while it was the one passing in a head-on plan with the
-- MF 7S.210): the vehicle that drives through a plan may still go round a fixed object; never the one that waits
function ADAvoidModule:isPasserInPlan()
    local tym = self.vehicle.ad.trafficYieldModule
    if tym == nil or tym.state == nil or ADTrafficYieldModule == nil then
        return false
    end
    local s = tym.state
    if s ~= ADTrafficYieldModule.STATE_REVERSER_PASS and s ~= ADTrafficYieldModule.STATE_PARKER_PASS
        and s ~= ADTrafficYieldModule.STATE_PRIORITY_APPROACH then
        return false
    end
    if tym.isControlling ~= nil and tym:isControlling() then
        return false
    end
    return true
end

-- hit: the obstacle the shift is for; a fixed object (not a vehicle, not a traffic car) lets the passer of a
-- head-on plan shift, the 60 m corridor test still keeps it in lane when someone comes the other way
function ADAvoidModule:isBusyElsewhere(hit)
    local ad = self.vehicle.ad
    if ad.drivePathModule:getIsReversing() or not ad.drivePathModule:isOnRoadNetwork() then
        return true
    end
    if ad.trafficYieldModule ~= nil and ad.trafficYieldModule.isBusy ~= nil and ad.trafficYieldModule:isBusy() then
        local fixed = (hit ~= nil and not hit.isVehicle and not hit.isTraffic) or (hit == nil and self.passerShift == true)
        -- a shift already under way for a fixed object goes on when the plan just ended (only its cooldown left)
        local planEnded = hit == nil and self.passerShift == true and ad.trafficYieldModule.state == ADTrafficYieldModule.STATE_IDLE
        if not (fixed and (self:isPasserInPlan() or planEnded)) then
            return true
        end
        if hit ~= nil and not self.passerLogged then
            self.passerLogged = true
            print(string.format("[AD-Ecart] %s: croisement en cours, je suis celui qui passe : je contourne l'objet fixe '%s'",
                ADTrafficYieldModule.getName(self.vehicle), tostring(hit.name or hit.objectName or "?")))
        end
    end
    if ad.obstacleDetourModule ~= nil and ad.obstacleDetourModule:isControlling() then
        return true
    end
    -- waiting at an intersection: the stopped car in front is the one we wait for (27/10)
    if ADIntersectionModule ~= nil and ADIntersectionModule.isWaiting ~= nil and ADIntersectionModule.isWaiting(self.vehicle) then
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Véhicule ou voiture arrêté devant
-- ------------------------------------------------------------------------------------------------------------
-- a vehicle is an obstacle once it stood still long enough and is not waiting for me in a head-on plan
function ADAvoidModule:isVehicleStill(hit, dt)
    local object = hit.object
    if object == nil then
        return self:isTrafficStill(hit)
    end
    local root = object.getRootVehicle ~= nil and object:getRootVehicle() or object
    local speed = math.abs(root.lastSpeedReal or 0) * 3600
    local still = speed < ADAvoidModule.VEHICLE_STILL_SPEED
    if root.ad ~= nil and root.ad.trafficYieldModule ~= nil and root.ad.trafficYieldModule.partner == self.vehicle then
        still = false
    end
    -- S5 (28/10 17:42): an AutoDrive vehicle that waits its turn my way (single track, crossing) is the head of
    -- the queue: I stay behind it, never around it
    if still and self:isWaitingMyWay(root) then
        self:logLimited(hit, "attend son tour dans mon sens, je reste derriere")
        still = false
    end
    if object ~= self.stillObject or not still then
        self.stillObject = object
        self.stillSince = still and g_time or nil
        return false
    end
    return self.stillSince ~= nil and (g_time - self.stillSince) >= ADAvoidModule.VEHICLE_STILL_TIME
end

-- an AI traffic car has no game object: it stands still when its node no longer moves
function ADAvoidModule:isTrafficStill(hit)
    local node = hit.node
    if node == nil or node == 0 or not hit.isTraffic then
        return false
    end
    local x, _, z = getWorldTranslation(node)
    -- S5: the way the car drove while I saw it (traffic cars do not reverse)
    if node == self.stillObject and self.stillX ~= nil then
        local mx, mz = x - self.stillX, z - self.stillZ
        local moved = MathUtil.vector2Length(mx, mz)
        if moved > ADAvoidModule.TRAFFIC_STILL_MOVE then
            self.trafficDirNode = node
            self.trafficDirX, self.trafficDirZ = mx / moved, mz / moved
        end
    end
    if node ~= self.stillObject or self.stillX == nil or MathUtil.vector2Length(x - self.stillX, z - self.stillZ) > ADAvoidModule.TRAFFIC_STILL_MOVE then
        self.stillObject = node
        self.stillX, self.stillZ = x, z
        self.stillSince = g_time
        return false
    end
    return (g_time - self.stillSince) >= ADAvoidModule.TRAFFIC_STILL_TIME
end

-- ------------------------------------------------------------------------------------------------------------
-- File : véhicule ou voiture arrêté dans mon sens (S5)
-- ------------------------------------------------------------------------------------------------------------
-- S5: my driving direction (world, normalised), nil when unknown
function ADAvoidModule:getMyDirection()
    local dx, _, dz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local length = MathUtil.vector2Length(dx or 0, dz or 0)
    if length < 0.0001 then
        return nil, nil
    end
    return dx / length, dz / length
end

-- S5: a stopped AutoDrive vehicle heading my way that waits for its turn (head-on plan, crossing)
function ADAvoidModule:isWaitingMyWay(root)
    if root == nil or root.ad == nil or root == self.vehicle then
        return false
    end
    local waiting = false
    local yieldModule = root.ad.trafficYieldModule
    if yieldModule ~= nil and ADTrafficYieldModule ~= nil and yieldModule.state ~= nil and yieldModule.state ~= ADTrafficYieldModule.STATE_IDLE then
        waiting = true
    end
    if not waiting and ADIntersectionModule ~= nil and ADIntersectionModule.isWaiting ~= nil and ADIntersectionModule.isWaiting(root) then
        waiting = true
    end
    if not waiting or root.components == nil or root.components[1] == nil then
        return false
    end
    local mx, mz = self:getMyDirection()
    if mx == nil then
        return false
    end
    local dx, _, dz = localDirectionToWorld(root.components[1].node, 0, 0, 1)
    local length = MathUtil.vector2Length(dx or 0, dz or 0)
    return length > 0.0001 and (dx * mx + dz * mz) / length > ADAvoidModule.QUEUE_DOT
end

-- S5: a vehicle (tractor, implement, AutoDrive or not) standing still on my route up to QUEUE_LOOK m beyond the car,
-- heading my way: the car queues behind it. Returns its name
function ADAvoidModule:findStoppedBeyond(hit, mx, mz)
    if ADTrafficYieldModule == nil or ADTrafficYieldModule.getRoutePolyline == nil then
        return nil
    end
    local front = 0
    if self.vehicle.ad.adDimensions ~= nil and self.vehicle.ad.adDimensions.maxLengthFront ~= nil then
        front = self.vehicle.ad.adDimensions.maxLengthFront
    elseif self.vehicle.size ~= nil and self.vehicle.size.length ~= nil then
        front = self.vehicle.size.length / 2
    end
    local carAlong = front + (hit.distance or 0)
    local points = ADTrafficYieldModule.getRoutePolyline(self.vehicle, carAlong + ADAvoidModule.QUEUE_LOOK + 20)
    if #points < 2 then
        return nil
    end
    local myRoot = self.vehicle:getRootVehicle()
    for _, other in pairs(AutoDrive.getAllVehicles()) do
        if other ~= nil and other.components ~= nil and other.components[1] ~= nil then
            local root = other.getRootVehicle ~= nil and other:getRootVehicle() or other
            if root ~= nil and root ~= myRoot and not AutoDrive:checkIsConnected(myRoot, other)
                and math.abs(root.lastSpeedReal or 0) * 3600 < 1 and root.components ~= nil and root.components[1] ~= nil then
                local ox, _, oz = getWorldTranslation(other.components[1].node)
                -- position along my route and distance from it
                local along, lateral, walked = nil, math.huge, 0
                for k = 1, #points - 1 do
                    local a, b = points[k], points[k + 1]
                    local dx, dz = b.x - a.x, b.z - a.z
                    local l = MathUtil.vector2Length(dx, dz)
                    if l > 0.01 then
                        local t = math.max(0, math.min(1, ((ox - a.x) * dx + (oz - a.z) * dz) / (l * l)))
                        local d = MathUtil.vector2Length(ox - (a.x + dx * t), oz - (a.z + dz * t))
                        if d < lateral then
                            lateral, along = d, walked + l * t
                        end
                    end
                    walked = walked + l
                end
                local halfWidth = ((other.size ~= nil and other.size.width) or 3) / 2
                if along ~= nil and lateral < ADAvoidModule.QUEUE_LATERAL + halfWidth
                    and along > carAlong + 1 and along < carAlong + ADAvoidModule.QUEUE_LOOK + 15 then
                    local dx, _, dz = localDirectionToWorld(root.components[1].node, 0, 0, 1)
                    local length = MathUtil.vector2Length(dx or 0, dz or 0)
                    if length > 0.0001 and (dx * mx + dz * mz) / length > ADAvoidModule.QUEUE_DOT then
                        return root.getName ~= nil and root:getName() or tostring(root.id)
                    end
                end
            end
        end
    end
    return nil
end

-- S5 (28/10 17:42, the MT635 changed lanes around a car that queued behind the Magnum waiting before the farm
-- track, then got stuck 2 m behind its cultivator): a traffic car stopped in MY direction queues, I wait behind it;
-- only a car nose to nose (it waits for me) is passed. Returns queuing, reason, and whether a vehicle in front of it
-- was seen (then the wait has no timeout)
function ADAvoidModule:isQueuingCar(hit)
    local mx, mz = self:getMyDirection()
    if mx == nil then
        return false, nil, false
    end
    -- 1. something it queues behind
    local name = self:findStoppedBeyond(hit, mx, mz)
    if name ~= nil then
        return true, string.format("derriere '%s' arrete", tostring(name)), true
    end
    -- 2. the way it drove while I saw it
    if self.trafficDirNode ~= nil and self.trafficDirNode == hit.node and self.trafficDirX ~= nil then
        local dot = self.trafficDirX * mx + self.trafficDirZ * mz
        if dot > ADAvoidModule.QUEUE_DOT then
            return true, string.format("elle roulait dans mon sens (%.2f)", dot), false
        elseif dot < -ADAvoidModule.QUEUE_DOT then
            return false, nil, false
        end
    end
    -- 3. its own heading
    if hit.node ~= nil and hit.node ~= 0 then
        local dx, _, dz = localDirectionToWorld(hit.node, 0, 0, 1)
        local length = MathUtil.vector2Length(dx or 0, dz or 0)
        if length > 0.0001 then
            local dot = (dx * mx + dz * mz) / length
            if dot > ADAvoidModule.QUEUE_DOT then
                return true, string.format("elle est tournee dans mon sens (%.2f)", dot), false
            end
        end
    end
    return false, nil, false
end

-- ------------------------------------------------------------------------------------------------------------
-- Décision : écart à côté de l'obstacle ou changement de voie
-- ------------------------------------------------------------------------------------------------------------
function ADAvoidModule:tryStart(dt)
    local approach = self.vehicle.ad.approachModule
    if approach == nil then
        return
    end
    local hit = approach:getHit()
    local distance = approach:getEstimatedDistance()
    if hit == nil or distance == nil then
        -- the scan may lose the obstacle for a moment: the "stands still" clock is kept for 2 s
        if self.lastHitTime ~= nil and g_time - self.lastHitTime > 2000 then
            self.stillObject = nil
            self.stillSince = nil
        end
        return
    end
    self.lastHitTime = g_time
    if hit.isVehicle and not self:isVehicleStill(hit, dt) then
        return
    end
    if distance > ADAvoidModule.TRIGGER_DISTANCE then
        return
    end
    local speed = math.abs(self.vehicle.lastSpeedReal or 0) * 3600
    if speed > ADAvoidModule.START_SPEED then
        return
    end
    if hit.isTraffic then
        local queuing, why, behindVehicle = self:isQueuingCar(hit)
        if queuing then
            -- a car standing alone my way (parked, broken down) may still be passed after QUEUE_TIMEOUT
            local standing = self.stillSince ~= nil and (g_time - self.stillSince) or 0
            if behindVehicle or standing < ADAvoidModule.QUEUE_TIMEOUT then
                self:logLimited(hit, string.format("voiture arretee dans mon sens (file, %s), j'attends derriere", why))
                -- 30/10 16:34 (942 behind a car queuing behind the Puma: the detour reversed 9 m to go round it):
                -- a queue is a normal wait, the obstacle detour leaves it alone
                self.queueUntil = g_time + ADAvoidModule.QUEUE_HOLD
                return
            end
            self:logLimited(hit, string.format("voiture arretee dans mon sens depuis %.0f s, rien devant elle : je la double", standing / 1000))
        end
    end
    if hit.side == 0 and (hit.isTraffic or not hit.isVehicle) then
        -- traffic car stopped across my line (it waits for me), or an object across the corridor (service kit,
        -- pallet, bale on the road): a lane change, after backing up when too close. A wall or a gate across the
        -- road fails the corridor test and goes to the detour as before
        if not self:isBusyElsewhere(hit) and not self:isOnField() then
            self.passerShift = not hit.isVehicle and not hit.isTraffic and self:isPasserInPlan()
            self:tryLaneChange(hit, distance, speed)
        end
        return
    end
    if distance < ADAvoidModule.MIN_DISTANCE then
        return
    end
    if hit.side == 0 then
        if not hit.isVehicle then
            self:logLimited(hit, "obstacle across the corridor, cannot pass beside it")
        end
        return
    end
    if self:isBusyElsewhere(hit) or self:isOnField() then
        return
    end
    self.passerShift = not hit.isVehicle and not hit.isTraffic and self:isPasserInPlan()
    local sign = -hit.side
    local range = math.max(ADAvoidModule.CLEAR_RANGE, distance + self:getTrainLength() + ADAvoidModule.PASS_MARGIN)
    for _, e in ipairs(ADAvoidModule.OFFSETS) do
        local clear, reason = approach:isCorridorClear(sign * e, range)
        if clear then
            self.target = sign * e
            self.rate = ADAvoidModule.RATE
            self.travelled = 0
            self.passTravel = distance + self:getTrainLength() + ADAvoidModule.PASS_MARGIN
            -- (08/11, 7R 350: a 1 m shift started 4 m before a pole, the tyre hit it) the shift must be done when the
            -- nose reaches the obstacle: quicker when it is close, after backing up when it is too close
            if distance < e / ADAvoidModule.RATE + ADAvoidModule.SHIFT_LAG then
                self.rate = ADAvoidModule.LANE_RATE
                local needed = e / ADAvoidModule.LANE_RATE + ADAvoidModule.SHIFT_LAG
                if distance < needed then
                    self:startBacking("side", math.min(ADAvoidModule.BACK_MAX, needed - distance), distance, hit.name)
                    self:log("'%s' %.1f m ahead on side %d, too close to swing out: backing up %.1f m, then shifting %.1f m",
                        tostring(hit.name), distance, hit.side, self.backNeeded, self.target)
                    return
                end
            end
            self.state = ADAvoidModule.STATE_SHIFTING
            self:log("'%s' %.1f m ahead on side %d: shifting %.1f m to the other side, back after %.0f m (%.0f km/h)",
                tostring(hit.name), distance, hit.side, self.target, self.passTravel, speed)
            return
        else
            self.lastReason = reason
        end
    end
    self:logLimited(hit, string.format("no free corridor beside it (%s)", tostring(self.lastReason)))
end

-- lane change beside a stopped traffic car: right side first (local +x is left in GIANTS: right is a negative offset)
function ADAvoidModule:findLane(hit, distance)
    local approach = self.vehicle.ad.approachModule
    local range = math.max(ADAvoidModule.CLEAR_RANGE, distance + self:getTrainLength() + ADAvoidModule.PASS_MARGIN)
    for _, sign in ipairs({-1, 1}) do
        for _, e in ipairs(ADAvoidModule.LANE_OFFSETS) do
            local clear, reason = approach:isCorridorClear(sign * e, range)
            if clear then
                return sign * e
            end
            self.lastReason = reason
        end
    end
    return nil
end

function ADAvoidModule:tryLaneChange(hit, distance, speed)
    local target = self:findLane(hit, distance)
    if target == nil then
        self:logLimited(hit, string.format("%s across my line, no free lane beside it (%s)", hit.isTraffic and "traffic car" or "obstacle", tostring(self.lastReason)))
        return
    end
    -- room needed in front of the car to reach the offset: offset / rate, plus a margin
    local needed = math.abs(target) / ADAvoidModule.LANE_RATE + ADAvoidModule.BACK_MARGIN
    self.target = target
    self.rate = ADAvoidModule.LANE_RATE
    self.travelled = 0
    self.hitDistance = distance
    self.hitName = hit.name
    self.passTravel = distance + self:getTrainLength() + ADAvoidModule.PASS_MARGIN
    if distance >= needed then
        self.state = ADAvoidModule.STATE_SHIFTING
        self:log("%s '%s' %.1f m ahead across my line: lane change %.1f m, back after %.0f m (%.0f km/h)",
            hit.isTraffic and "traffic car stopped" or "obstacle", tostring(hit.name), distance, self.target, self.passTravel, speed)
        return
    end
    self:startBacking("lane", math.min(ADAvoidModule.BACK_MAX, needed - distance), distance, hit.name)
    self:log("%s '%s' %.1f m ahead across my line: backing up %.1f m, then lane change %.1f m",
        hit.isTraffic and "traffic car stopped" or "obstacle", tostring(hit.name), distance, self.backNeeded, self.target)
end

-- ------------------------------------------------------------------------------------------------------------
-- Attelage qui pousse contre un obstacle que les capteurs ne voient pas (08/11)
-- ------------------------------------------------------------------------------------------------------------
-- a side offset whose corridor is free, at least 0.5 m away from the line followed now: further on the side the
-- train was already moving to first, then the other side
function ADAvoidModule:findPushOffset(range)
    local approach = self.vehicle.ad.approachModule
    local current = self.offset or 0
    local sides = {-1, 1}
    if current > 0.05 then
        sides = {1, -1}
    end
    for _, sign in ipairs(sides) do
        for _, e in ipairs(ADAvoidModule.PUSH_OFFSETS) do
            local target = sign * e
            if math.abs(target - current) >= 0.5 then
                local clear, reason = approach:isCorridorClear(target, range)
                if clear then
                    return target
                end
                self.lastReason = reason
            end
        end
    end
    return nil
end

-- (08/11) the train pushes against something the sensors do not see (pole beside
-- the line, 7R 350 at Champ 56): back up, then pass beside it (called by ADDrivePathModule:handlePushing)
function ADAvoidModule:startFromPush()
    if not self.vehicle.isServer or not ADAvoidModule.isEnabled() or self.state == ADAvoidModule.STATE_BACKING then
        return false
    end
    if self.vehicle.ad.approachModule == nil or self:isBusyElsewhere() or self:isOnField() then
        return false
    end
    local range = math.max(ADAvoidModule.HOLD_RANGE, self:getTrainLength() + 10)
    local target = self:findPushOffset(range)
    if target == nil then
        self:log("pushing without moving: no free side to pass (%s)", tostring(self.lastReason))
        return false
    end
    local current = self.offset or 0
    self.target = target
    self.rate = ADAvoidModule.LANE_RATE
    self:startBacking("push", math.min(ADAvoidModule.BACK_MAX, math.abs(target - current) / ADAvoidModule.LANE_RATE + ADAvoidModule.PUSH_BACK_MARGIN), 0.5, "?")
    self:log("pushing without moving (obstacle not seen by the sensors): backing up %.1f m, then passing %.1f m beside (was %.1f m)",
        self.backNeeded, target, current)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Recul avant l'écart : le module prend la main (appelé par followWaypoints,
-- renvoie true tant que ce module conduit)
-- ------------------------------------------------------------------------------------------------------------
-- kind: "lane" (lane change beside a stopped car: the lane is chosen again after backing up), "side" (shift beside an
-- object seen too late: the same shift if still free, another one otherwise), "push" (pushing against something unseen)
function ADAvoidModule:startBacking(kind, backNeeded, hitDistance, hitName)
    self.backKind = kind
    self.backNeeded = backNeeded
    self.hitDistance = hitDistance
    self.hitName = hitName
    self.travelled = 0
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    self.startPos = {x = x, z = z}
    local tx, ty, tz = AutoDrive.localToWorld(self.vehicle, 0, 0, -100)
    self.reverseTarget = {x = tx, y = ty, z = tz}
    self.backTimer:timer(false)
    self.rearBlockedTimer:timer(false)
    self.vehicle.ad.specialDrivingModule:reset()
    self.state = ADAvoidModule.STATE_BACKING
end

function ADAvoidModule:handle(dt)
    if self.state ~= ADAvoidModule.STATE_BACKING then
        return false
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local reversed = MathUtil.vector2Length(x - self.startPos.x, z - self.startPos.z)
    local timedOut = self.backTimer:timer(true, ADAvoidModule.BACK_TIMEOUT, dt)
    local cdm = self.vehicle.ad.collisionDetectionModule
    local rearBlocked = cdm ~= nil and cdm.checkReverseCollision ~= nil and cdm:checkReverseCollision() == true
    local rearStop = self.rearBlockedTimer:timer(rearBlocked, ADAvoidModule.REAR_BLOCKED_TIME, dt)
    local sdm = self.vehicle.ad.specialDrivingModule

    if reversed >= self.backNeeded or rearStop or timedOut then
        sdm:reset()
        local distance = (self.hitDistance or 0) + reversed
        -- the lane must still be free from here
        local target
        if self.backKind == "side" or self.backKind == "push" then
            local range = math.max(ADAvoidModule.CLEAR_RANGE, distance + self:getTrainLength() + ADAvoidModule.PASS_MARGIN)
            if self.backKind == "side" and self.vehicle.ad.approachModule:isCorridorClear(self.target, range) then
                target = self.target
            else
                target = self:findPushOffset(range)
            end
        else
            target = self:findLane({name = self.hitName}, distance)
        end
        self.backKind = nil
        if target == nil then
            self:log("backed up %.1f m (rear blocked %s, timeout %s): no free lane any more, giving up", reversed, tostring(rearStop), tostring(timedOut))
            self:reset()
            self.cooldownUntil = g_time + ADAvoidModule.COOLDOWN
            return false
        end
        self.target = target
        self.travelled = 0
        self.passTravel = distance + self:getTrainLength() + ADAvoidModule.PASS_MARGIN
        self.state = ADAvoidModule.STATE_SHIFTING
        self:log("backed up %.1f m (rear blocked %s, timeout %s): lane change %.1f m, car %.1f m ahead, back after %.0f m",
            reversed, tostring(rearStop), tostring(timedOut), self.target, distance, self.passTravel)
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
    sdm:reverseToTargetLocation(dt, self.reverseTarget, ADAvoidModule.REVERSE_SPEED)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale, appelée à chaque image par ADDrivePathModule:followWaypoints (serveur)
-- renvoie la vitesse maxi (km/h) pendant une manœuvre, math.huge sinon
-- ------------------------------------------------------------------------------------------------------------
function ADAvoidModule:update(dt)
    if not self.vehicle.isServer or not ADAvoidModule.isEnabled() then
        if self.offset ~= 0 or self.state ~= ADAvoidModule.STATE_IDLE then
            self:reset()
        end
        return math.huge
    end
    local dpm = self.vehicle.ad.drivePathModule
    if self.state == ADAvoidModule.STATE_BACKING then
        dpm.lateralOffset = 0
        return math.huge -- handle() drives
    end
    local step = math.abs(self.vehicle.lastSpeedReal or 0) * dt -- metres driven this frame
    self.travelled = (self.travelled or 0) + step

    if self.state == ADAvoidModule.STATE_IDLE then
        if g_time >= self.cooldownUntil and ((g_updateLoopIndex + self.vehicle.id) % ADAvoidModule.CHECK_FRAMES) == 0 then
            self:tryStart(dt)
        end
        if self.state == ADAvoidModule.STATE_IDLE or self.state == ADAvoidModule.STATE_BACKING then
            dpm.lateralOffset = 0
            return math.huge
        end
    end

    -- the detour or a head-on plan took over: back on the line at once
    if self:isBusyElsewhere() then
        self:log("another manoeuvre took over, offset dropped")
        self:reset()
        self.cooldownUntil = g_time + ADAvoidModule.COOLDOWN
        return math.huge
    end

    if self.state == ADAvoidModule.STATE_SHIFTING then
        if ((g_updateLoopIndex + self.vehicle.id) % ADAvoidModule.CHECK_FRAMES) == 0 then
            local clear, reason = self.vehicle.ad.approachModule:isCorridorClear(self.target, ADAvoidModule.HOLD_RANGE)
            if not clear then
                self:log("shifted corridor no longer free (%s): coming back", tostring(reason))
                self.target = 0
                self.state = ADAvoidModule.STATE_RETURNING
            end
        end
        if self.passTravel ~= nil and self.travelled >= self.passTravel then
            self:log("obstacle passed (%.0f m driven): coming back on the line", self.travelled)
            self.target = 0
            self.state = ADAvoidModule.STATE_RETURNING
        end
    end

    -- ramp the offset with the distance driven
    local maxChange = step * (self.rate or ADAvoidModule.RATE)
    if self.offset < self.target then
        self.offset = math.min(self.target, self.offset + maxChange)
    elseif self.offset > self.target then
        self.offset = math.max(self.target, self.offset - maxChange)
    end
    dpm.lateralOffset = self.offset

    if self.state == ADAvoidModule.STATE_RETURNING and math.abs(self.offset) < 0.05 then
        self.offset = 0
        dpm.lateralOffset = 0
        self.state = ADAvoidModule.STATE_IDLE
        self.rate = ADAvoidModule.RATE
        self.cooldownUntil = g_time + ADAvoidModule.COOLDOWN
        self:log("back on the line")
        return math.huge
    end
    return ADAvoidModule.SPEED
end

-- ------------------------------------------------------------------------------------------------------------
-- Véhicule arrêté devant en file (pont-bascule) : ObstacleDetourQueue.lua (chargé avant ce fichier)
-- ------------------------------------------------------------------------------------------------------------
if ADObstacleDetourQueue ~= nil then ADObstacleDetourQueue.installAvoid(ADAvoidModule) end -- 08/11 vehicule arrete devant en file (pont-bascule) : ObstacleDetourQueue.lua
