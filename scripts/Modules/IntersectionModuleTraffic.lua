-- ============================================================================================================
-- FarmPilot : IntersectionModuleTraffic.lua
-- Complément de IntersectionModule.lua : les véhicules qui arrivent sur les voies surveillées, et la sortie occupée.
--
-- Règle : les boîtes de la zone sont testées (véhicules et trafic du jeu) ; chaque véhicule vu a sa trace par
-- véhicule qui regarde (27/10), d'où sa vitesse d'approche. Danger : véhicule sur le croisement, ou qui arrive
-- dans le temps de traversée de l'attelage. Pas un danger : le véhicule qui m'attend (plan de face à face), un
-- véhicule AutoDrive arrêté qui attend lui-même à sa ligne, un véhicule devant moi dans mon sens (file).
-- Sortie occupée : un véhicule arrêté sur la voie après la portion rouge, je ne m'engage pas.
--
-- Branché par : IntersectionModule.lua (handle : isTrafficComing, isExitBlocked).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local function getMask()
    local m = 0
    for _, name in ipairs({ "VEHICLE", "TRAFFIC_VEHICLE", "TRAFFIC_VEHICLE_BLOCKING" }) do
        if CollisionFlag[name] ~= nil then
            m = m + CollisionFlag[name]
        end
    end
    return m
end

function ADIntersectionModule:overlapCallback(node)
    if node == nil or node == 0 or node == g_currentMission.terrainRootNode then
        return true
    end
    local object = g_currentMission:getNodeObject(node)
    if object == nil then
        local parent = getParent(node)
        if parent ~= nil and parent ~= 0 then
            object = g_currentMission:getNodeObject(parent)
        end
    end
    local me = self.scanVehicle
    if object ~= nil and me ~= nil then
        local root = me:getRootVehicle()
        if object == me or object == root or AutoDrive:checkIsConnected(root, object) then
            return true
        end
    end
    local key = object ~= nil and object or node
    if not self.scanSeen[key] then
        self.scanSeen[key] = true
        table.insert(self.scanHits, { key = key, node = node, object = object })
    end
    return true
end

function ADIntersectionModule.getTracks(vehicle)
    local c = vehicle.ad ~= nil and vehicle.ad.intersection or nil
    if c == nil then
        return ADIntersectionModule.tracks
    end
    if c.tracks == nil then
        c.tracks = {}
    end
    return c.tracks
end

-- ------------------------------------------------------------------------------------------------------------
-- Véhicule devant moi, dans mon sens, sur ma route (file)
-- ------------------------------------------------------------------------------------------------------------
-- 'other' (a vehicle) is ahead of me on my route (2.5 m at most from it, 80 m ahead at most) and drives my way
function ADIntersectionModule.isAheadMyWay(vehicle, other)
    if other == nil or other.components == nil or other.components[1] == nil or vehicle.ad == nil or vehicle.ad.drivePathModule == nil then
        return false
    end
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return false
    end
    local ox, _, oz = getWorldTranslation(other.components[1].node)
    local odx, _, odz = localDirectionToWorld(other.components[1].node, 0, 0, 1)
    local lastX, _, lastZ = getWorldTranslation(vehicle.components[1].node)
    local travelled = 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        local dx, dz = wp.x - lastX, wp.z - lastZ
        local l = MathUtil.vector2Length(dx, dz)
        if l > 0.01 then
            local t = math.max(0, math.min(1, ((ox - lastX) * dx + (oz - lastZ) * dz) / (l * l)))
            local px, pz = lastX + dx * t, lastZ + dz * t
            if MathUtil.vector2Length(ox - px, oz - pz) <= 2.5 then
                local ol = math.max(0.01, MathUtil.vector2Length(odx, odz))
                return travelled + t * l > 0.5 and (odx * dx + odz * dz) / (ol * l) > 0.5
            end
            travelled = travelled + l
            if travelled > 80 then
                break
            end
        end
        lastX, lastZ = wp.x, wp.z
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Trafic qui arrive sur les voies surveillées
-- ------------------------------------------------------------------------------------------------------------
function ADIntersectionModule.isTrafficComing(vehicle, zone, horizon)
    local self = ADIntersectionModule
    local arrival = horizon or self.ARRIVAL_S
    self.scanVehicle = vehicle
    self.scanHits = {}
    self.scanSeen = {}
    local mask = getMask()
    for _, b in ipairs(zone.boxes) do
        overlapBox(b.x, b.y + self.BOX_HALF_HEIGHT + 0.2, b.z, 0, b.ry, 0, self.BOX_HALF_WIDTH, self.BOX_HALF_HEIGHT, b.half,
            "overlapCallback", self, mask, true, true, true, true)
        if ADIntersectionModule.DEBUG then
            DebugUtil.drawOverlapBox(b.x, b.y + self.BOX_HALF_HEIGHT + 0.2, b.z, 0, b.ry, 0, self.BOX_HALF_WIDTH, self.BOX_HALF_HEIGHT, b.half, 1, 0, 0)
        end
    end
    self.scanVehicle = nil

    local now = g_time
    -- 27/10 : traces PAR VÉHICULE. Elles étaient partagées : deux véhicules au même croisement (C15 D + 7R derrière, Magnum + MF)
    -- rafraîchissaient la même trace à 50 ms d'écart, le second n'en tirait jamais de vitesse et voyait une voiture
    -- arrêtée comme « voiture à 20 m » (danger) pendant des minutes
    local tracks = ADIntersectionModule.getTracks(vehicle)
    local c = vehicle.ad ~= nil and vehicle.ad.intersection or nil
    local danger, reason = false, nil
    -- the vehicle that waits for me before a single track (TrafficYield plan, stopped on purpose): not a danger,
    -- waiting for it would block us both (25/10 21:08-21:20, Puma 240 CVX held by the 942 Vario waiting for it)
    local yieldModule = vehicle.ad ~= nil and vehicle.ad.trafficYieldModule or nil
    local waitingForMe = nil
    if yieldModule ~= nil and yieldModule.plan ~= nil and yieldModule.plan.parked and yieldModule.plan.waitBeforeSection then
        waitingForMe = yieldModule.partner
    end
    for _, h in ipairs(self.scanHits) do
      local isWaitingForMe = waitingForMe ~= nil and h.object ~= nil and (h.object == waitingForMe
            or (h.object.getRootVehicle ~= nil and h.object:getRootVehicle() == waitingForMe) or AutoDrive:checkIsConnected(waitingForMe, h.object))
      if not isWaitingForMe then
        local hx, _hy, hz
        if h.object ~= nil and h.object.rootNode ~= nil then
            hx, _hy, hz = getWorldTranslation(h.object.rootNode)
        else
            hx, _hy, hz = getWorldTranslation(h.node)
        end
        local d = math.huge
        for _, p in ipairs(zone.points) do
            d = math.min(d, MathUtil.vector2Length(hx - p.x, hz - p.z))
        end
        local speed
        if h.object ~= nil and h.object.lastSpeedReal ~= nil then
            speed = h.object.lastSpeedReal * 1000
        end
        local t = tracks[h.key]
        local closing = nil
        -- 27/10 : une trace jusqu'à 5 s (une voiture arrêtée vue par intermittence donnait « voiture à 36 m » sans vitesse)
        if t ~= nil and now - t.time > 100 and now - t.time < self.TRACK_MAX_MS then
            closing = (t.d - d) / ((now - t.time) / 1000)
        end
        if t == nil or now - t.time >= 100 then
            tracks[h.key] = { d = d, time = now }
        end
        if speed == nil and closing ~= nil then
            speed = math.abs(closing)
        end

        local name = h.object ~= nil and h.object.getFullName ~= nil and h.object:getFullName() or "voiture"
        -- 26/10 18:46 (Patriot bloqué par la remorque du 942 qui attendait, arrêté, avant sa propre ligne, à 4 m des points
        -- rouges ; derrière : Jaguar puis MT635) : un véhicule AutoDrive arrêté qui attend lui-même à sa ligne (ou recule)
        -- n'occupe pas le croisement, sauf s'il est vraiment sur les points (3 m) ; mon capteur me garde de son attelage
        local root = h.object ~= nil and h.object.getRootVehicle ~= nil and h.object:getRootVehicle() or h.object
        local stopped = (speed == nil or speed < self.MOVING_MS) and (closing == nil or math.abs(closing) < self.MOVING_MS)
        local waitingAtItsLine = root ~= nil and root.ad ~= nil and root.ad.intersection ~= nil and stopped
            and (root.ad.intersection.holding or root.ad.intersection.retreat ~= nil)
        -- 27/10 06:49 (7R 350 reculé dans une entrée de maison, à 4 m d'un point du croisement, qui attendait que le MT635 passe ;
        -- le MT635 attendait à sa ligne « 7R sur le croisement (4 m) ») : un véhicule AutoDrive arrêté que son plan de face à face
        -- tient (garé, reculé, en attente) attend que quelqu'un passe : pas un danger
        local parkedByYield = root ~= nil and root.ad ~= nil and root.ad.trafficYieldModule ~= nil and stopped
            and root.ad.trafficYieldModule.isControlling ~= nil and root.ad.trafficYieldModule:isControlling()
        -- 27/10 06:48 (Magnum à sa ligne, le MF à la sienne à 3 m d'un point, chacun attendant l'autre ; règle :
        -- priorité à celui qui sort du chemin à double sens, l'autre s'engage ensuite) : la limite de 3 m devient 1,5 m,
        -- un véhicule qui attend à sa ligne n'est pas sur le croisement
        -- 27/10 : toutes les traces sont mises à jour à chaque passage (plus de « break » au premier danger), sinon une voiture
        -- vue derrière une autre gardait une trace périmée et repassait pour « inconnue »
        if danger then
            -- déjà un danger : trace mise à jour, rien d'autre
        elseif ADIntersectionModule.isAheadMyWay(vehicle, root) then
            -- 30/10 16:34 (Puma 240 CVX à sa ligne, « Patriot 4450 sur le croisement (1 m) » alors que le Patriot était devant lui,
            -- dans son sens, sur sa route) : une file, pas un danger ; mon capteur me tient derrière lui
            if c ~= nil and c.queueAheadLogged ~= root then
                c.queueAheadLogged = root
                ADIntersectionModule.log("%s : %s devant moi dans mon sens sur ma route, je le suis (file, pas un danger)",
                    tostring(vehicle:getFullName()), name)
            end
        elseif (waitingAtItsLine or parkedByYield) and d > 1.5 then
            -- pas un danger
        elseif d <= self.CLOSE_DIST and (d <= self.PARKED_DIST or not (stopped and (speed ~= nil or closing ~= nil))) then
            -- 27/10 06:50 (942, MT635 : « Krampe sur le croisement (8 m) », « 7R sur le croisement (4 m) », véhicules arrêtés par
            -- le joueur à côté du croisement) : un véhicule arrêté (vitesse connue) à plus de 4 m d'un point du croisement est à côté,
            -- mon capteur s'en occupe ; un véhicule qui bouge reste un danger jusqu'à 8 m
            danger, reason = true, string.format("%s sur le croisement (%.0f m)", name, d)
        elseif closing == nil then
            -- première vue (pas encore de vitesse d'approche) : on la suppose venant vers le croisement à 50 km/h (ou à sa
            -- vitesse connue), revu 250 ms plus tard. 27/10 : avant, une voiture vue pour la première fois à 120 m ne comptait
            -- pas, et un véhicule à sa ligne pouvait s'engager juste devant elle
            local assumed = speed or self.ASSUMED_MS
            if (speed == nil or speed > self.MOVING_MS) and (d < self.NEAR_DIST or d / assumed < arrival) then
                danger, reason = true, string.format("%s à %.0f m (vitesse inconnue)", name, d)
            end
        elseif closing > self.MOVING_MS and (d / closing < arrival or d < self.NEAR_DIST) then
            danger, reason = true, string.format("%s arrive (%.0f m, %.0f km/h)", name, d, closing * 3.6)
        end
      end
    end

    for k, t in pairs(tracks) do
        if now - t.time > 5000 then
            tracks[k] = nil
        end
    end
    return danger, reason
end

-- ------------------------------------------------------------------------------------------------------------
-- Voie de sortie occupée
-- ------------------------------------------------------------------------------------------------------------
-- un véhicule arrêté (ou presque) sur la voie de sortie : si je m'engage, je reste en travers du croisement
-- (26/10 17:24 : 942 Vario engagé alors que des voitures faisaient la queue sur la route derrière le 7R 350 arrêté)
function ADIntersectionModule.isExitBlocked(vehicle, wayPoints, lastIndex)
    local self = ADIntersectionModule
    local length = math.max(self.EXIT_MIN_LENGTH, ADIntersectionModule.getTrainLength(vehicle) + 8)
    local boxes, exitPoint = ADIntersectionModule.buildExitBoxes(wayPoints, lastIndex, length)
    if #boxes == 0 or exitPoint == nil then
        return false
    end
    self.scanVehicle = vehicle
    self.scanHits = {}
    self.scanSeen = {}
    local mask = getMask()
    for _, b in ipairs(boxes) do
        overlapBox(b.x, b.y + self.BOX_HALF_HEIGHT + 0.2, b.z, 0, b.ry, 0, self.BOX_HALF_WIDTH, self.BOX_HALF_HEIGHT, b.half,
            "overlapCallback", self, mask, true, true, true, true)
    end
    self.scanVehicle = nil
    local now = g_time
    local tracks = ADIntersectionModule.getTracks(vehicle)
    -- 26/10 20:00 (MT635 « sortie occupée : Tenwinkel B2500 » = la masse du 7R 350 qui attendait exprès pour lui 9 m avant le
    -- chemin) : le véhicule qui attend pour moi (plan de croisement) n'occupe pas ma sortie, je le vois avec mon capteur
    local yieldModule = vehicle.ad ~= nil and vehicle.ad.trafficYieldModule or nil
    local waitingForMe = nil
    if yieldModule ~= nil and yieldModule.plan ~= nil and yieldModule.plan.parked and yieldModule.plan.waitBeforeSection then
        waitingForMe = yieldModule.partner
    end
    for _, h in ipairs(self.scanHits) do
      local isWaitingForMe = waitingForMe ~= nil and h.object ~= nil and (h.object == waitingForMe
            or (h.object.getRootVehicle ~= nil and h.object:getRootVehicle() == waitingForMe) or AutoDrive:checkIsConnected(waitingForMe, h.object))
      if not isWaitingForMe then
        local hx, _hy, hz
        if h.object ~= nil and h.object.rootNode ~= nil then
            hx, _hy, hz = getWorldTranslation(h.object.rootNode)
        else
            hx, _hy, hz = getWorldTranslation(h.node)
        end
        local d = MathUtil.vector2Length(hx - exitPoint.x, hz - exitPoint.z)
        local speed
        if h.object ~= nil and h.object.lastSpeedReal ~= nil then
            speed = math.abs(h.object.lastSpeedReal) * 1000
        end
        local key = "exit:" .. tostring(h.key)
        local t = tracks[key]
        if speed == nil and t ~= nil and now - t.time > 100 and now - t.time < 2000 then
            speed = math.abs(d - t.d) / ((now - t.time) / 1000)
        end
        if t == nil or now - t.time >= 100 then
            tracks[key] = { d = d, time = now }
        end
        -- vitesse inconnue (première vue d'une voiture du trafic) : on la considère arrêtée, revu 250 ms plus tard
        if speed == nil or speed < self.MOVING_MS then
            local name = h.object ~= nil and h.object.getFullName ~= nil and h.object:getFullName() or "voiture"
            return true, string.format("sortie occupée : %s arrêté à %.0f m après le croisement", name, d)
        end
      end
    end
    return false
end
