-- ============================================================================================================
-- FarmPilot : AvoidModuleSensor.lua
-- Complément de AvoidModule.lua (écart) : le capteur avant arrête le véhicule sur un obstacle fixe du réseau de
-- routes. Un écart d'abord, le contournement (ObstacleDetourModule) seulement si l'écart est impossible.
--
-- Historique : 16/11 18:59 (Patriot 4450 sur une route de village étroite : coin d'un muret et bord d'un toit à
-- côté de la ligne suivie, pas dessus. Le balayage de route ne l'a pas vu, le capteur avant court l'a arrêté, puis
-- contournement calculé alors qu'un décalage de la ligne suffisait).
--
-- Règle, au moment où ObstacleDetourModule allait lancer le contournement (obstacle fixe, capteur avant) :
-- - Seulement sur le réseau de routes : jamais dans un champ ni sur un trajet calculé, jamais pendant un
--   face-à-face (TrafficYield) ni à l'arrêt d'une intersection, jamais pour un véhicule devant (on attend, file).
-- - Côté de l'obstacle : les cinq boîtes du capteur avant court (frontSensorDynamicShort, largeur du véhicule) sont
--   testées une à une, mêmes boîtes, mêmes masques et même tri des objets que le capteur. Les boîtes touchées
--   donnent le côté (gauche ou droite de l'axe) et le bord de l'obstacle le plus près de l'axe. Deux morceaux de
--   part et d'autre de l'axe, toute la largeur, ou le milieu seulement : pas d'écart.
-- - Écart de l'autre côté, de 1 à 2,5 m (ADAvoidModule.OFFSETS), le plus petit qui dégage le bord de l'obstacle et
--   dont le couloir décalé est libre, véhicules compris (comme tryStart).
-- - Le véhicule recule d'abord ce qu'il faut pour se décaler avant l'obstacle (startBacking, sorte « sensor »),
--   puis le couloir est testé de nouveau et l'écart se fait comme les autres.
-- - Un écart par endroit : arrêté de nouveau par le capteur avant pendant l'écart (BLOCKED_TIME), ou couloir plus
--   libre après le recul, ou de nouveau bloqué au même endroit : contournement comme avant.
-- - Le journal dit ce qui est choisi : « capteur avant : obstacle à gauche, écart ... » ou « capteur avant : écart
--   impossible (raison), contournement ».
--
-- Branché par : ObstacleDetourModule.lua (handle : startFromFrontSensor, checkSensorShift) ; AvoidModule.lua (handle :
-- retargetAfterSensorBacking après le recul).
-- ============================================================================================================

ADAvoidModuleSensor = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAvoidModuleSensor.BOXES = 5                  -- boîtes du capteur avant court (ADCollSensorSplit:getBoxShapes)
ADAvoidModuleSensor.PROBE_LENGTH = 1.5         -- m : 2e essai, boîtes plus longues si l'obstacle n'est plus dans les 0,2 m
ADAvoidModuleSensor.SIDE_MARGIN = 0.3          -- m gardés entre le flanc décalé et le bord de l'obstacle
ADAvoidModuleSensor.SAME_PLACE = 15            -- m : un écart par endroit
ADAvoidModuleSensor.RETRY_TIME = 120000        -- ms : l'endroit est oublié après ce temps
ADAvoidModuleSensor.BLOCKED_TIME = 3000        -- ms arrêté par le capteur avant pendant l'écart : abandonné, contournement
ADAvoidModuleSensor.STOPPED_KMH = 0.5          -- km/h
ADAvoidModuleSensor.MIN_BACK = 0.5             -- m reculés au moins
ADAvoidModuleSensor.APPROACH_HIT_DISTANCE = 6  -- m : obstacle fixe vu par le balayage, à défaut du capteur court

-- ------------------------------------------------------------------------------------------------------------
-- Calculs purs (testés hors jeu)
-- ------------------------------------------------------------------------------------------------------------
-- décalage latéral (m, +x = gauche en GIANTS) du centre de la boîte i du capteur court
function ADAvoidModuleSensor.boxOffset(i, width)
    local boxWidth = width / ADAvoidModuleSensor.BOXES
    return -width / 2 + (i - 0.5) * boxWidth
end

-- offsets : centres des boîtes touchées. Renvoie side (1 gauche, -1 droite, 0 aucun), le bord de l'obstacle le plus
-- près de l'axe (m, côté obstacle), et la raison quand side vaut 0. Des boîtes touchées d'un seul tenant donnent le
-- côté de leur milieu (le bord intérieur peut dépasser l'axe : l'écart nécessaire le dira) ; deux morceaux de part et
-- d'autre de l'axe, ou toute la largeur : pas de côté
function ADAvoidModuleSensor.sideOf(offsets, width)
    if offsets == nil or #offsets == 0 then
        return 0, nil, "obstacle non retrouvé dans le capteur"
    end
    local boxWidth = width / ADAvoidModuleSensor.BOXES
    local half = boxWidth / 2
    local eps = half * 0.1
    local sorted = {}
    for _, x in ipairs(offsets) do
        table.insert(sorted, x)
    end
    table.sort(sorted)
    local left, right, contiguous, sum = false, false, true, 0
    for k, x in ipairs(sorted) do
        if x > eps then
            left = true
        elseif x < -eps then
            right = true
        end
        if k > 1 and sorted[k] - sorted[k - 1] > boxWidth + eps then
            contiguous = false
        end
        sum = sum + x
    end
    local minEdge, maxEdge = sorted[1] - half, sorted[#sorted] + half
    if left and right and not contiguous then
        return 0, nil, "obstacle des deux côtés"
    end
    if minEdge <= -width / 2 + eps and maxEdge >= width / 2 - eps then
        return 0, nil, "obstacle sur toute la largeur"
    end
    local mean = sum / #sorted
    if mean > eps then
        return 1, minEdge, nil
    elseif mean < -eps then
        return -1, maxEdge, nil
    end
    return 0, nil, "obstacle au milieu"
end

-- écart nécessaire (m, positif) pour que le flanc du véhicule passe le bord de l'obstacle avec la marge
function ADAvoidModuleSensor.requiredShift(side, innerEdge, width)
    if side == 0 or innerEdge == nil then
        return math.huge
    end
    return width / 2 + ADAvoidModuleSensor.SIDE_MARGIN - side * innerEdge
end

-- premier écart (ADAvoidModule.OFFSETS) assez grand dont le couloir est libre ; isClear(target) -> clear, reason.
-- Renvoie la cible (signée : de l'autre côté de l'obstacle) ou nil et la raison
function ADAvoidModuleSensor.chooseShift(side, required, isClear, offsets)
    offsets = offsets or ADAvoidModule.OFFSETS
    local lastReason = nil
    local tried = false
    for _, e in ipairs(offsets) do
        if e >= required - 0.001 then
            tried = true
            local target = -side * e
            local clear, reason = isClear(target)
            if clear then
                return target, nil
            end
            lastReason = reason
        end
    end
    if not tried then
        return nil, string.format("il faudrait %.1f m, %.1f m au plus", required, offsets[#offsets])
    end
    return nil, string.format("pas de couloir libre : %s", tostring(lastReason))
end

function ADAvoidModuleSensor.sideName(side)
    if side > 0 then
        return "à gauche"
    elseif side < 0 then
        return "à droite"
    end
    return "au milieu"
end

-- ------------------------------------------------------------------------------------------------------------
-- Côté de l'obstacle : les boîtes du capteur avant court, une à une
-- ------------------------------------------------------------------------------------------------------------
-- même tri que le capteur (ADCollSensorSplit:collisionTestCallbackSplit), plus le nom du premier objet touché
local function probeCallback(proxy, transformId)
    local before = proxy.newHit
    ADCollSensorSplit.collisionTestCallbackSplit(proxy, transformId)
    if proxy.newHit and not before and proxy.hitName == nil then
        local object = g_currentMission.nodeToObject[transformId]
        if object ~= nil and object.getName ~= nil then
            proxy.hitName = object:getName()
        elseif getName ~= nil then
            proxy.hitName = getName(transformId)
        end
    end
end

local function overlapOne(sensor, proxy, box, mask)
    local offsetCompensation = math.max(-math.tan(box.rx) * box.size[3], 0)
    local y = math.max(getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, box.x, 300, box.z), box.y) + offsetCompensation
    proxy.newHit = false
    overlapBox(box.x, y, box.z, box.rx, box.ry, 0, box.size[1], box.size[2], box.size[3], "probeCallback", proxy, mask, true, true, true, true)
    return proxy.newHit
end

-- renvoie {vehicle = bool, offsets = {centres des boîtes touchées}, width, length, name}, nil sans capteur
function ADAvoidModuleSensor.probe(vehicle)
    local sensors = vehicle.ad ~= nil and vehicle.ad.sensors or nil
    local sensor = sensors ~= nil and sensors.frontSensorDynamicShort or nil
    if sensor == nil or sensor.getBoxShapes == nil or ADCollSensorSplit == nil then
        return nil
    end
    local width = AutoDrive.getVehicleDimensions(vehicle, false)
    local params = sensor.sensorParameters or {}
    local proxy = setmetatable({vehicle = vehicle, newHit = false, probeCallback = probeCallback}, {__index = sensor})
    local result = {vehicle = false, offsets = {}, width = width, length = 0}
    -- véhicules : boîtes comme le capteur (2 m au moins)
    for _, box in pairs(sensor:getBoxShapes(params.minDynamicLengthForVehicles or 2)) do
        if overlapOne(sensor, proxy, box, ADCollSensorSplit.maskVehicles) then
            result.vehicle = true
            result.name = proxy.hitName
            return result
        end
    end
    -- objets : boîtes du capteur (0,2 m à l'arrêt), puis un peu plus longues
    for _, length in ipairs({params.minDynamicLength or 0.2, ADAvoidModuleSensor.PROBE_LENGTH}) do
        for i, box in pairs(sensor:getBoxShapes(length)) do
            if overlapOne(sensor, proxy, box, ADCollSensorSplit.maskObjects) then
                table.insert(result.offsets, ADAvoidModuleSensor.boxOffset(i, width))
            end
        end
        if #result.offsets > 0 then
            result.length = length
            result.name = proxy.hitName
            return result
        end
    end
    return result
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ de l'écart (appelé par ADObstacleDetourModule:handle au lieu du contournement)
-- ------------------------------------------------------------------------------------------------------------
-- true : écart lancé ; false, raison : écart impossible (raison nil : cas hors règle, rien n'est écrit)
function ADAvoidModule:startFromFrontSensor()
    local ad = self.vehicle.ad
    if not self.vehicle.isServer or not ADAvoidModule.isEnabled() or ad.approachModule == nil then
        return false, nil
    end
    -- hors règle : champ, trajet calculé, face-à-face, intersection, autre manœuvre
    if ad.drivePathModule:getIsReversing() or not ad.drivePathModule:isOnRoadNetwork() or self:isOnField() then
        return false, nil
    end
    if ad.trafficYieldModule ~= nil and ad.trafficYieldModule.isBusy ~= nil and ad.trafficYieldModule:isBusy() then
        return false, nil
    end
    if ADIntersectionModule ~= nil and ADIntersectionModule.isWaiting ~= nil and ADIntersectionModule.isWaiting(self.vehicle) then
        return false, nil
    end
    if ad.obstacleDetourModule ~= nil and ad.obstacleDetourModule:isControlling() then
        return false, nil
    end
    if self.state ~= ADAvoidModule.STATE_IDLE or self.offset ~= 0 then
        return false, "écart déjà en cours"
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local try = self.sensorTry
    if try ~= nil and g_time - try.time < ADAvoidModuleSensor.RETRY_TIME and MathUtil.vector2Length(x - try.x, z - try.z) < ADAvoidModuleSensor.SAME_PLACE then
        return false, "écart déjà essayé ici"
    end

    -- côté de l'obstacle
    local side, required, name, distance = 0, nil, nil, 0
    local probe = ADAvoidModuleSensor.probe(self.vehicle)
    local reason = "capteur avant absent"
    if probe ~= nil then
        if probe.vehicle then
            return false, string.format("véhicule devant ('%s')", tostring(probe.name))
        end
        local edge
        side, edge, reason = ADAvoidModuleSensor.sideOf(probe.offsets, probe.width)
        required = ADAvoidModuleSensor.requiredShift(side, edge, probe.width)
        name, distance = probe.name, probe.length
    end
    if side == 0 and probe ~= nil and #probe.offsets == 0 then
        -- rien dans le capteur court : l'obstacle fixe vu par le balayage de route tout près, s'il donne un côté
        local hit = ad.approachModule:getHit()
        local hitDistance = ad.approachModule:getEstimatedDistance()
        if hit ~= nil and not hit.isVehicle and not hit.isTraffic and hit.side ~= nil and hit.side ~= 0
            and hitDistance ~= nil and hitDistance < ADAvoidModuleSensor.APPROACH_HIT_DISTANCE then
            side, required, name, distance = hit.side, ADAvoidModule.OFFSETS[1], hit.name, hitDistance
        end
    end
    if side == 0 then
        return false, reason or "côté de l'obstacle inconnu"
    end

    -- écart de l'autre côté, couloir décalé libre, véhicules compris
    local approach = ad.approachModule
    local range = math.max(ADAvoidModule.CLEAR_RANGE, distance + self:getTrainLength() + ADAvoidModule.PASS_MARGIN)
    local target, why = ADAvoidModuleSensor.chooseShift(side, required, function(t)
        return approach:isCorridorClear(t, range)
    end)
    if target == nil then
        self.sensorTry = {x = x, z = z, time = g_time}
        return false, string.format("obstacle %s, %s", ADAvoidModuleSensor.sideName(side), why)
    end

    -- recul : de quoi amener le décalage avant le nez de l'obstacle
    self.sensorTry = {x = x, z = z, time = g_time}
    self.sensorShift = true
    self.sensorSide = side
    self.sensorRequired = required
    self.sensorBlockedTime = 0
    self.target = target
    self.rate = ADAvoidModule.LANE_RATE
    self.passerShift = false
    self.passTravel = nil
    local needed = math.abs(target) / ADAvoidModule.LANE_RATE + ADAvoidModule.SHIFT_LAG
    local back = math.min(ADAvoidModule.BACK_MAX, math.max(ADAvoidModuleSensor.MIN_BACK, needed - distance))
    self:startBacking("sensor", back, distance, name)
    self:log("capteur avant : obstacle %s ('%s'), écart %.1f m vers la %s (il faut %.1f m), recul %.1f m d'abord",
        ADAvoidModuleSensor.sideName(side), tostring(name), math.abs(target), target < 0 and "droite" or "gauche", required, back)
    return true
end

-- après le recul (ADAvoidModule:handle, sorte « sensor ») : le même écart s'il est encore libre, sinon un plus grand
-- du même côté ; jamais du côté de l'obstacle
function ADAvoidModule:retargetAfterSensorBacking(range)
    local approach = self.vehicle.ad.approachModule
    if approach:isCorridorClear(self.target, range) then
        return self.target
    end
    local side = self.sensorSide or (self.target > 0 and -1 or 1)
    local target, why = ADAvoidModuleSensor.chooseShift(side, math.abs(self.target), function(t)
        return approach:isCorridorClear(t, range)
    end)
    if target == nil then
        self:log("capteur avant : écart impossible après le recul (%s), contournement", tostring(why))
        self.sensorShift = nil
    end
    return target
end

-- ------------------------------------------------------------------------------------------------------------
-- Suivi de l'écart (appelé à chaque image par ADObstacleDetourModule:handle)
-- ------------------------------------------------------------------------------------------------------------
-- blocked : arrêté par un obstacle fixe. L'écart lancé par le capteur avant est abandonné s'il reste arrêté
-- BLOCKED_TIME ms (le contournement prend la suite) ; obstacle passé : l'endroit n'est plus retenu
function ADAvoidModule:checkSensorShift(dt, blocked)
    if not self.sensorShift then
        return
    end
    if not self:isActive() then
        -- fin de l'écart : réussi quand tout le train a passé l'obstacle
        if self.passTravel ~= nil and (self.travelled or 0) >= self.passTravel then
            self.sensorTry = nil
        end
        self.sensorShift = nil
        return
    end
    if self.state == ADAvoidModule.STATE_BACKING then
        self.sensorBlockedTime = 0
        return
    end
    local stopped = math.abs(self.vehicle.lastSpeedReal or 0) * 3600 < ADAvoidModuleSensor.STOPPED_KMH
    if blocked and stopped then
        self.sensorBlockedTime = (self.sensorBlockedTime or 0) + dt
    else
        self.sensorBlockedTime = 0
    end
    if self.sensorBlockedTime >= ADAvoidModuleSensor.BLOCKED_TIME then
        self:log("capteur avant : arrêté de nouveau pendant l'écart (%.1f m), écart abandonné, contournement", self.offset or 0)
        self.sensorShift = nil
        self:reset()
        self.cooldownUntil = g_time + ADAvoidModule.COOLDOWN
    end
end
