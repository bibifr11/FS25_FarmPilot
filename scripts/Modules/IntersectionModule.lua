-- ============================================================================================================
-- FarmPilot : IntersectionModule.lua
-- Type de route « Intersection » (points rouges, AutoDrive.FLAG_INTERSECTION) : attendre un trou dans la
-- circulation avant d'entrer sur une portion rouge, puis traverser d'un trait.
--
-- Règle : avant d'entrer sur une portion Intersection, AutoDrive regarde les voies AutoDrive que cette portion
-- coupe ou rejoint, en remontant chaque voie sur 80 m (WATCH_DIST, porté à 120 m le 26/10). Si un véhicule arrive
-- (voiture du jeu, tracteur, joueur), il s'arrête juste avant le premier point rouge, attend que ce soit libre
-- depuis 2 s, puis traverse sans s'arrêter. Pour le calcul des trajets, un point Intersection compte comme un
-- point normal.
-- - Arrêté sur la portion rouge après s'être engagé (raté) : recul immédiat jusqu'avant la ligne, sauf derrière
--   un véhicule qui va dans mon sens (file) (26/10).
-- - Le trou exigé dans le trafic dépend du temps que met l'attelage à traverser, puis baisse avec l'attente
--   (patience) (27/10).
--
-- Fichiers : celui-ci (réglages, portion rouge devant, attente à la ligne, traversée, recul après un raté) ;
-- IntersectionModuleZone.lua (voies à surveiller, voie de sortie) ; IntersectionModuleTraffic.lua (véhicules qui
-- arrivent, sortie occupée). Chargés dans cet ordre par register.lua.
-- IntersectionHold.lua (chargé avant) enveloppe handle, startRetreat et log : appelé par la dernière ligne de ce
-- fichier.
--
-- Branché par : DrivePathModuleObstacles.lua (handle), DrivePathModule.lua (reset, getSpeedLimit), GraphManager.lua
-- (clearCache) ; isWaiting lu par ObstacleDetourModule.lua et AvoidModule.lua, isIntersectionPoint par
-- TrafficYieldModule.lua.
-- ============================================================================================================

ADIntersectionModule = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADIntersectionModule.DEBUG = false

ADIntersectionModule.WATCH_DIST = 120         -- m de voie regardés en amont (26/10 18:01 : 80 m = 4 s à 73 km/h, trop court pour un attelage qui démarre)
ADIntersectionModule.LOOK_AHEAD = 60          -- m de trajet examinés devant le tracteur
ADIntersectionModule.STOP_BEFORE = 1          -- m : arrêt de l'avant du tracteur avant le 1er point rouge
ADIntersectionModule.APPROACH_DIST = 25       -- m avant l'arrêt : vitesse limitée pour bien regarder
ADIntersectionModule.APPROACH_KMH = 20
ADIntersectionModule.LOOK_KMH = 8              -- km/h au bord de la portion rouge, même route libre (le temps de regarder)
ADIntersectionModule.BRAKE_DECEL = 1.5        -- m/s²
ADIntersectionModule.COMMIT_DIST = 2          -- m avant l'arrêt : si libre, il s'engage
ADIntersectionModule.CLEAR_MS = 2000          -- libre depuis 2 s après une attente
ADIntersectionModule.CHECK_MS = 250
ADIntersectionModule.CLOSE_DIST = 8           -- m : véhicule sur le croisement, même arrêté
ADIntersectionModule.PARKED_DIST = 4          -- m : au-delà, un véhicule arrêté est à côté du croisement, pas dessus (27/10)
ADIntersectionModule.ARRIVAL_S = 8            -- s : véhicule qui arrive dans moins de 8 s (minimum)
ADIntersectionModule.ARRIVAL_MAX_S = 14       -- s : horizon maximal, selon le temps que met l'attelage à traverser
ADIntersectionModule.CROSS_MS = 2.5           -- m/s : vitesse moyenne d'un attelage qui démarre pour traverser (plus utilisé, gardé pour mémoire)
-- 27/10 (C15 D resté 140 s à sa ligne, « voiture arrive (124 m, 48 km/h) » toutes les 15 s : l'horizon de 14 s d'un gros
-- attelage était demandé à une camionnette) : le temps de traversée dépend de l'attelage, puis la patience baisse l'exigence
ADIntersectionModule.LIGHT_TRAIN_M = 8        -- m : véhicule seul et court = léger
ADIntersectionModule.ACCEL_LIGHT = 1.5        -- m/s² depuis l'arrêt
ADIntersectionModule.VMAX_LIGHT = 10          -- m/s (36 km/h) en traversant
ADIntersectionModule.ACCEL_TRAIN = 0.7
ADIntersectionModule.VMAX_TRAIN = 8
ADIntersectionModule.PATIENCE_MS = 30000      -- ms d'attente à la ligne avant de se contenter d'un trou plus court
ADIntersectionModule.PATIENCE_STEP_MS = 10000 -- ms : 1 s de moins par palier
ADIntersectionModule.PATIENCE_MIN_S = 5       -- s : trou minimal accepté (les voitures du jeu freinent devant un véhicule)
ADIntersectionModule.TRACK_MAX_MS = 5000      -- ms : âge maximal d'une trace pour en tirer une vitesse d'approche
ADIntersectionModule.NEAR_DIST = 40           -- m : véhicule qui roule vers le croisement
ADIntersectionModule.ASSUMED_MS = 14          -- m/s (50 km/h) supposés pour un véhicule vu pour la première fois (27/10)
ADIntersectionModule.MOVING_MS = 0.5          -- m/s
ADIntersectionModule.SEARCH_RADIUS = 40       -- m autour de la portion rouge pour trouver les voies
ADIntersectionModule.BOX_HALF_WIDTH = 2.0
ADIntersectionModule.BOX_HALF_HEIGHT = 1.5
ADIntersectionModule.BOX_MAX_LENGTH = 10
ADIntersectionModule.RETREAT_STUCK_MS = 1500   -- ms à l'arrêt sur la portion rouge avant de reculer (26/10 17:55 : raté = recul immédiat)
ADIntersectionModule.RETREAT_TIMEOUT_MS = 40000
ADIntersectionModule.RETREAT_BLOCKED_MS = 6000 -- ms bloqué derrière pendant le recul : on abandonne le recul (26/10 18:48)
ADIntersectionModule.COMMIT_STUCK_MS = 20000  -- ms engagé à l'arrêt sans recul possible : le croisement rend la main (26/10 21:46)
ADIntersectionModule.EXIT_MIN_LENGTH = 25     -- m de voie libre exigés après la portion rouge (au moins l'attelage + 8 m) (26/10 17:24)

-- ------------------------------------------------------------------------------------------------------------
-- Caches
-- ------------------------------------------------------------------------------------------------------------
ADIntersectionModule.zones = {}               -- cache : id du 1er point rouge -> zone
ADIntersectionModule.tracks = {}

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
function ADIntersectionModule.log(text, ...)
    print("AutoDrive : [intersection] " .. string.format(text, ...))
end

function ADIntersectionModule.isIntersectionPoint(wp)
    if wp == nil then
        return false
    end
    local flags = wp.flags
    if wp.id ~= nil then
        local g = ADGraphManager:getWayPointById(wp.id)
        if g ~= nil then
            flags = g.flags
        end
    end
    return flags ~= nil and bit32.band(flags, AutoDrive.FLAG_INTERSECTION) > 0
end

local function getFrontOffset(vehicle)
    local size = vehicle.size
    if size == nil then
        return 3
    end
    return size.length * 0.5 + (size.lengthOffset or 0)
end

-- longueur de l'attelage (m) ; aussi lue par IntersectionModuleTraffic.lua (isExitBlocked)
function ADIntersectionModule.getTrainLength(vehicle)
    local total = 0
    local root = vehicle:getRootVehicle()
    if root.childVehicles ~= nil then
        for _, v in pairs(root.childVehicles) do
            if v.size ~= nil then
                total = total + v.size.length
            end
        end
    end
    if total <= 0 then
        total = vehicle.size ~= nil and vehicle.size.length or 6
    end
    return total
end

-- 27/10 : temps (s) pour traverser 'span' m depuis l'arrêt, d'après l'attelage : un véhicule seul et court démarre vite,
-- un attelage (remorque, outil) lentement
local function crossingTime(vehicle, span)
    local self = ADIntersectionModule
    local root = vehicle:getRootVehicle()
    local count = 0
    if root.childVehicles ~= nil then
        for _ in pairs(root.childVehicles) do
            count = count + 1
        end
    end
    local light = count <= 1 and ADIntersectionModule.getTrainLength(vehicle) <= self.LIGHT_TRAIN_M
    local accel = light and self.ACCEL_LIGHT or self.ACCEL_TRAIN
    local vmax = light and self.VMAX_LIGHT or self.VMAX_TRAIN
    local accelDist = vmax * vmax / (2 * accel)
    if span <= accelDist then
        return math.sqrt(2 * span / accel), light
    end
    return vmax / accel + (span - accelDist) / vmax, light
end

-- ------------------------------------------------------------------------------------------------------------
-- Portion rouge devant le véhicule
-- ------------------------------------------------------------------------------------------------------------
-- première portion rouge sur le trajet devant : {dist = m de l'avant au 1er point rouge, endDist, key, zone}
local function findIntersection(vehicle)
    local dpm = vehicle.ad.drivePathModule
    local wayPoints, index = dpm:getWayPoints()
    if wayPoints == nil or index == nil or wayPoints[index] == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local front = getFrontOffset(vehicle)
    local cum = -front
    local px, pz = x, z
    local i = index
    while wayPoints[i] ~= nil and cum < ADIntersectionModule.LOOK_AHEAD do
        local wp = wayPoints[i]
        cum = cum + MathUtil.vector2Length(wp.x - px, wp.z - pz)
        if ADIntersectionModule.isIntersectionPoint(wp) then
            -- la portion rouge peut déjà être commencée : on remonte au premier point rouge
            local first = i
            while first > 1 and ADIntersectionModule.isIntersectionPoint(wayPoints[first - 1]) do
                first = first - 1
            end
            local last = i
            local endDist = cum
            local lx, lz = wp.x, wp.z
            while wayPoints[last + 1] ~= nil and ADIntersectionModule.isIntersectionPoint(wayPoints[last + 1]) do
                last = last + 1
                endDist = endDist + MathUtil.vector2Length(wayPoints[last].x - lx, wayPoints[last].z - lz)
                lx, lz = wayPoints[last].x, wayPoints[last].z
            end
            if wayPoints[last + 1] ~= nil then
                endDist = endDist + MathUtil.vector2Length(wayPoints[last + 1].x - lx, wayPoints[last + 1].z - lz)
            end
            local key = tostring(wayPoints[first].id or (math.floor(wayPoints[first].x) .. ":" .. math.floor(wayPoints[first].z)))
            local zone = ADIntersectionModule.zones[key]
            if zone == nil then
                zone = ADIntersectionModule.buildZone(wayPoints, first, last)
                ADIntersectionModule.zones[key] = zone
                ADIntersectionModule.log("portion %s : %d segments de voie surveillés, %d boîtes", key, zone.lanes, #zone.boxes)
            end
            local dist = first < index and -1 or cum
            return { dist = dist, endDist = endDist, key = key, zone = zone, lastIndex = last, wayPoints = wayPoints }
        end
        px, pz = wp.x, wp.z
        i = i + 1
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- État du véhicule (lu par DrivePathModule, ObstacleDetourModule, AvoidModule)
-- ------------------------------------------------------------------------------------------------------------
function ADIntersectionModule.reset(vehicle)
    local c = vehicle.ad.intersection
    if c ~= nil and (c.holding or c.retreat ~= nil) and vehicle.ad.specialDrivingModule ~= nil then
        vehicle.ad.specialDrivingModule:releaseVehicle()
    end
    vehicle.ad.intersection = nil
end

-- true tant que le croisement tient le véhicule : approche ralentie, arrêt avant la ligne ou recul raté
-- (27/10 06:47, Patriot : le capteur voyait la voiture arrêtée devant lui pendant qu'il attendait,
-- le contournement l'a fait reculer de 8 m et chercher une route autour de la voiture)
function ADIntersectionModule.isWaiting(vehicle)
    local c = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.intersection or nil
    if c == nil then
        return false
    end
    return c.holding == true or c.retreat ~= nil or c.speed ~= nil
end

-- vitesse maxi demandée (km/h) ou math.huge
function ADIntersectionModule.getSpeedLimit(vehicle)
    local c = vehicle.ad ~= nil and vehicle.ad.intersection or nil
    if c == nil or c.speed == nil then
        return math.huge
    end
    return c.speed
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale : approche, attente à la ligne, traversée
-- ------------------------------------------------------------------------------------------------------------
local function hold(vehicle, dt)
    -- 30/10 16:38 (Puma 240 CVX held 80 s at its line without any word in the log): every 10 s while held, why
    local c = vehicle.ad.intersection
    if c ~= nil then
        c.heldSince = c.heldSince or g_time
        if g_time - (c.heldLogTime or 0) >= 10000 then
            c.heldLogTime = g_time
            ADIntersectionModule.log("%s retenu a sa ligne depuis %.0f s : %s (ligne a %s m, attente %s)", tostring(vehicle:getFullName()),
                (g_time - c.heldSince) / 1000, tostring(c.heldWhy or c.lastReason), c.lastToStop ~= nil and string.format("%.1f", c.lastToStop) or "?",
                c.waited and "oui" or "non")
        end
    end
    local sdm = vehicle.ad.specialDrivingModule
    sdm.motorShouldNotBeStopped = true
    sdm:stopVehicle()
    sdm:update(dt)
    sdm.motorShouldNotBeStopped = false
end

-- appelé à chaque image par ADDrivePathModule:followWaypoints ; renvoie true si le véhicule doit rester à l'arrêt
function ADIntersectionModule.handle(vehicle, dt)
    if vehicle == nil or vehicle.ad == nil or not vehicle.isServer then
        return false
    end
    local dpm = vehicle.ad.drivePathModule
    if dpm == nil or dpm:getIsReversing() then
        return false
    end
    local c = vehicle.ad.intersection
    if c == nil then
        c = { nextCheck = 0, clearTime = 0 }
        vehicle.ad.intersection = c
    end

    -- raté : arrêté sur la portion rouge, il recule jusqu'à être de nouveau avant la ligne, puis attend
    if c.retreat ~= nil then
        return ADIntersectionModule.updateRetreat(vehicle, c, dt)
    end

    -- 26/10 21:46 (7R 350 pris entre deux procédures) : pendant que le module de croisement face à face conduit le véhicule
    -- (recul, attente avant un chemin unique), le croisement ne décide rien (ni « libre, il traverse », ni recul raté)
    local yieldModule = vehicle.ad.trafficYieldModule
    if yieldModule ~= nil and yieldModule.isControlling ~= nil and yieldModule:isControlling() and c.committed == nil then
        return false
    end

    -- engagé : on traverse sans regarder jusqu'à ce que tout l'attelage soit passé
    if c.committed ~= nil then
        c.travel = c.travel + (vehicle.lastMovedDistance or 0)
        if c.travel > c.committed.span then
            c.done = { key = c.committed.key, time = g_time }
            c.committed = nil
            c.stuckMs = 0
            c.speed = nil
            c.noRetreat = nil
            c.queuedLogged = nil
            return false
        end
        -- 26/10 17:55 (7R 350 arrêté en plein croisement, voitures derrière) : pas d'attente en plein milieu, un raté recule
        -- tout de suite, sans attendre : arrêté sur la portion rouge (capteur, véhicule devant)
        -- sans en être sorti -> recul immédiat jusqu'avant la ligne
        local kmh = math.abs(vehicle.lastSpeedReal or 0) * 3600
        if kmh < 0.5 and c.travel > 0.5 then
            c.stuckMs = (c.stuckMs or 0) + dt
            if c.stuckMs >= ADIntersectionModule.RETREAT_STUCK_MS then
                -- 26/10 18:55 (MT635 au rond-point, arrêté dans une file derrière une voiture qui attendait, reculé vers la voiture
                -- de derrière) : il s'était simplement arrêté dans une file : un véhicule juste devant moi, dans mon sens,
                -- n'est pas un raté, j'attends qu'il reparte. Pas non plus de recul quand il est impossible ou déjà fait 2 fois ici.
                local queued, queuedName = ADIntersectionModule.isQueuedBehindVehicle(vehicle)
                c.retreatCount = c.retreatCount or {}
                -- engagé et bloqué depuis longtemps sans recul possible : je rends la main (le face à face peut se négocier)
                if c.stuckMs >= ADIntersectionModule.COMMIT_STUCK_MS and (queued or c.noRetreat == c.committed.key or (c.retreatCount[c.committed.key] or 0) >= 2) then
                    ADIntersectionModule.log("%s engagé mais bloqué depuis %d s, le croisement rend la main", tostring(vehicle:getFullName()), math.floor(c.stuckMs / 1000))
                    c.done = { key = c.committed.key, time = g_time }
                    c.committed = nil
                    c.stuckMs = 0
                    c.speed = nil
                    c.noRetreat = nil
                    c.queuedLogged = nil
                    return false
                end
                if queued then
                    if not c.queuedLogged then
                        c.queuedLogged = true
                        ADIntersectionModule.log("%s arrêté derrière %s sur la portion rouge (même sens), il attend qu'il reparte", tostring(vehicle:getFullName()), tostring(queuedName))
                    end
                elseif c.noRetreat ~= c.committed.key and (c.retreatCount[c.committed.key] or 0) < 2 then
                    c.retreatCount[c.committed.key] = (c.retreatCount[c.committed.key] or 0) + 1
                    ADIntersectionModule.startRetreat(vehicle, c)
                    return true
                end
            end
        else
            c.stuckMs = 0
            c.queuedLogged = nil
        end
        c.speed = nil
        return false
    end

    if g_time < c.nextCheck then
        if c.holding then
            hold(vehicle, dt)
            return true
        end
        return false
    end
    c.nextCheck = g_time + ADIntersectionModule.CHECK_MS

    local inter = findIntersection(vehicle)
    if c.done ~= nil and g_time - c.done.time > 60000 then
        c.done = nil
    end
    if inter ~= nil and c.done ~= nil and c.done.key == inter.key then
        inter = nil
    end
    if inter == nil then
        if c.holding then
            vehicle.ad.specialDrivingModule:releaseVehicle()
        end
        c.holding, c.waited, c.clearTime, c.speed = false, false, 0, nil
        c.waitStart, c.patienceLogged = nil, nil
        c.heldSince, c.heldLogTime = nil, nil
        return false
    end

    local toStop = inter.dist - ADIntersectionModule.STOP_BEFORE
    c.lastToStop = toStop
    -- 26/10 18:01 (942 Vario engagé, une voiture arrivée 8 s plus tard s'est arrêtée devant son nez dans l'entrée du chemin) :
    -- l'horizon dépend du temps que met l'attelage à traverser toute la portion rouge en partant de l'arrêt
    local crossSpan = math.max(0, inter.endDist) + ADIntersectionModule.getTrainLength(vehicle) + 2
    -- 27/10 : temps de traversée d'après l'attelage (accélération, vitesse), 8 à 14 s
    local horizon = math.min(ADIntersectionModule.ARRIVAL_MAX_S, math.max(ADIntersectionModule.ARRIVAL_S, crossingTime(vehicle, crossSpan) + 2))
    -- 27/10 : patience. Après 30 s à la ligne (PATIENCE_MS), le trou exigé dans le trafic baisse de 1 s, puis de 1 s
    -- de plus toutes les 10 s (PATIENCE_STEP_MS), jusqu'à 5 s (PATIENCE_MIN_S) :
    -- sur une route au trafic régulier (C15 D : une voiture toutes les 15 s à 48 km/h), un trou de 14 s ne vient jamais
    if c.waited and c.waitStart ~= nil and g_time - c.waitStart > ADIntersectionModule.PATIENCE_MS then
        local relaxed = math.max(ADIntersectionModule.PATIENCE_MIN_S,
            horizon - math.floor((g_time - c.waitStart - ADIntersectionModule.PATIENCE_MS) / ADIntersectionModule.PATIENCE_STEP_MS) - 1)
        if relaxed < horizon then
            if c.patienceLogged ~= relaxed then
                c.patienceLogged = relaxed
                ADIntersectionModule.log("%s attend depuis %.0f s, il se contente d'un trou de %.0f s dans le trafic (au lieu de %.0f s)",
                    tostring(vehicle:getFullName()), (g_time - c.waitStart) / 1000, relaxed, horizon)
            end
            horizon = relaxed
        end
    end
    local danger, reason = ADIntersectionModule.isTrafficComing(vehicle, inter.zone, horizon)
    if not danger and toStop > -1 then
        danger, reason = ADIntersectionModule.isExitBlocked(vehicle, inter.wayPoints, inter.lastIndex)
    end
    local name = tostring(vehicle:getFullName())
    -- what the 10 s log says while held: the danger seen right now, or how long it has been clear
    if danger then
        c.heldWhy = tostring(reason)
    elseif c.waited and c.clearTime ~= 0 then
        c.heldWhy = string.format("plus de danger depuis %.1f s (motif d'avant : %s)", (g_time - c.clearTime) / 1000, tostring(c.lastReason))
    else
        c.heldWhy = "plus de danger (motif d'avant : " .. tostring(c.lastReason) .. ")"
    end

    local function commit()
        if c.holding then
            vehicle.ad.specialDrivingModule:releaseVehicle()
        end
        c.committed = { key = inter.key, span = math.max(0, inter.endDist) + ADIntersectionModule.getTrainLength(vehicle) + 2 }
        c.travel = 0
        c.holding, c.waited, c.clearTime, c.speed = false, false, 0, nil
        c.waitStart, c.patienceLogged = nil, nil
        c.heldSince, c.heldLogTime = nil, nil
    end

    if danger then
        c.clearTime = 0
        if not c.waited then
            c.waited = true
            c.waitStart, c.patienceLogged = g_time, nil
            ADIntersectionModule.log("%s attend : %s", name, tostring(reason))
            c.lastReason, c.lastReasonTime = reason, g_time
        elseif reason ~= c.lastReason and g_time - (c.lastReasonTime or 0) > 5000 then
            -- le motif change pendant l'attente : dit lequel (26/10 : 942 resté 1 min « en attente » sans motif dans le log)
            ADIntersectionModule.log("%s attend toujours : %s", name, tostring(reason))
            c.lastReason, c.lastReasonTime = reason, g_time
        end
        if toStop <= 1 then
            if toStop < -1 and not c.holding then
                -- déjà sur la portion rouge : trop tard pour s'arrêter, il passe
                ADIntersectionModule.log("%s déjà engagé, il passe", name)
                commit()
                return false
            end
            c.holding = true
        end
        local v = math.sqrt(2 * ADIntersectionModule.BRAKE_DECEL * math.max(0, toStop)) * 3.6
        c.speed = math.max(3, math.min(ADIntersectionModule.APPROACH_KMH, v))
    else
        if c.waited and c.clearTime == 0 then
            c.clearTime = g_time
        end
        local clearLongEnough = not c.waited or g_time - c.clearTime >= ADIntersectionModule.CLEAR_MS
        if toStop <= ADIntersectionModule.COMMIT_DIST and clearLongEnough then
            if c.waited then
                ADIntersectionModule.log("%s libre, il traverse", name)
            end
            commit()
            return false
        end
        if c.waited and toStop <= 1 then
            c.holding = true
        end
        if toStop < ADIntersectionModule.APPROACH_DIST then
            local look = ADIntersectionModule.LOOK_KMH / 3.6
            local v = math.sqrt(look * look + 2 * ADIntersectionModule.BRAKE_DECEL * math.max(0, toStop - ADIntersectionModule.COMMIT_DIST)) * 3.6
            c.speed = math.min(ADIntersectionModule.APPROACH_KMH, v)
        else
            c.speed = nil
        end
    end

    if c.holding then
        hold(vehicle, dt)
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Raté : recul hors de la portion rouge
-- ------------------------------------------------------------------------------------------------------------
-- recul hors de la portion rouge (le module croisement n'a pas de marche arrière à lui : celle du module de croisement
-- face à face, le long de ma propre route)
-- arrêté juste derrière un véhicule (à moins de 8 m sur ma route) qui va dans mon sens, ou dont le sens est inconnu :
-- une file, pas un raté. Renvoie aussi le nom du véhicule.
function ADIntersectionModule.isQueuedBehindVehicle(vehicle)
    local am = vehicle.ad ~= nil and vehicle.ad.approachModule or nil
    if am == nil or am.getHit == nil then
        return false
    end
    local hit = am:getHit()
    if hit == nil or not hit.isVehicle or (hit.distance or 99) > 8 then
        return false
    end
    local node = nil
    if hit.object ~= nil then
        node = hit.object.rootNode or hit.object.node
    end
    if node ~= nil and entityExists ~= nil and entityExists(node) and localDirectionToWorld ~= nil then
        local ox, _, oz = localDirectionToWorld(node, 0, 0, 1)
        local mx, _, mz = localDirectionToWorld(vehicle.components[1].node, 0, 0, 1)
        local sameWay = ox * mx + oz * mz > 0.5
        return sameWay, hit.name
    end
    return true, hit.name
end

function ADIntersectionModule.startRetreat(vehicle, c)
    local yieldModule = vehicle.ad.trafficYieldModule
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local needed = c.travel + ADIntersectionModule.STOP_BEFORE + 1
    local targets = {}
    if yieldModule ~= nil and yieldModule.buildReverseTargets ~= nil then
        targets = yieldModule:buildReverseTargets(needed + 10)
    end
    ADIntersectionModule.log("%s raté : arrêté %.0f m après le début de la portion rouge, il recule de %.0f m pour attendre avant la ligne (%d points)",
        tostring(vehicle:getFullName()), c.travel, needed, #targets)
    c.retreat = { needed = needed, targets = targets, index = 1, startX = x, startZ = z, startTime = g_time, blockedMs = 0, key = c.committed.key, span = c.committed.span, travel = c.travel }
    c.committed = nil
    c.stuckMs = 0
    c.speed = nil
    if vehicle.ad.specialDrivingModule ~= nil then
        vehicle.ad.specialDrivingModule:releaseVehicle()
    end
end

function ADIntersectionModule.updateRetreat(vehicle, c, dt)
    local r = c.retreat
    local yieldModule = vehicle.ad.trafficYieldModule
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local reversed = MathUtil.vector2Length(x - r.startX, z - r.startZ)
    local target = r.targets[r.index]
    local blocked = vehicle.ad.collisionDetectionModule ~= nil and vehicle.ad.collisionDetectionModule:checkReverseCollision()
    if blocked then
        r.blockedMs = r.blockedMs + dt
    else
        r.blockedMs = 0
    end
    local finished = reversed >= r.needed or target == nil or yieldModule == nil or yieldModule.reverseTowards == nil
        or g_time - r.startTime > ADIntersectionModule.RETREAT_TIMEOUT_MS
    -- 26/10 18:48 (Jaguar : 40 s pour 7 m, le MT635 collé derrière ; 942 : 40 s pour 9 m, le MF 7S derrière) : reculer est
    -- impossible, inutile d'attendre le délai puis de faire comme si j'étais avant la ligne : je reste engagé et j'attends
    -- que ça se libère devant (pas de nouveau recul à ce croisement)
    if not finished and r.blockedMs >= ADIntersectionModule.RETREAT_BLOCKED_MS then
        ADIntersectionModule.log("%s recul impossible (véhicule derrière) après %.0f m sur %.0f m, il reste engagé et attend", tostring(vehicle:getFullName()), reversed, r.needed)
        c.retreat = nil
        c.committed = { key = r.key, span = r.span }
        c.travel = math.max(0, r.travel - reversed)
        c.noRetreat = r.key
        c.stuckMs = 0
        c.speed = nil
        if ADTrafficYieldModule ~= nil and ADTrafficYieldModule.resyncWayPoints ~= nil then
            ADTrafficYieldModule.resyncWayPoints(vehicle, r.reachedRouteIndex)
        end
        if vehicle.ad.specialDrivingModule ~= nil then
            vehicle.ad.specialDrivingModule:releaseVehicle()
        end
        return false
    end
    if finished then
        ADIntersectionModule.log("%s reculé de %.0f m sur %.0f m%s, il attend avant la ligne", tostring(vehicle:getFullName()), reversed, r.needed,
            (target == nil and " (plus de route derrière)") or (g_time - r.startTime > ADIntersectionModule.RETREAT_TIMEOUT_MS and " (délai)") or "")
        c.retreat = nil
        c.done = nil
        c.holding, c.waited, c.clearTime, c.speed = true, true, 0, nil
        c.waitStart, c.patienceLogged = g_time, nil
        c.nextCheck = 0
        if ADTrafficYieldModule ~= nil and ADTrafficYieldModule.resyncWayPoints ~= nil then
            ADTrafficYieldModule.resyncWayPoints(vehicle, r.reachedRouteIndex)
        end
        hold(vehicle, dt)
        return true
    end
    if blocked then
        -- une voiture collée derrière : on la laisse partir (le trafic du jeu finit par contourner ou reculer), on retente
        local sdm = vehicle.ad.specialDrivingModule
        sdm:stopAndHoldVehicle(dt)
        return true
    end
    if yieldModule:reverseTowards(dt, target) then
        if target.routeIndex ~= nil then
            r.reachedRouteIndex = target.routeIndex
        end
        r.index = r.index + 1
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Réseau modifié (éditeur)
-- ------------------------------------------------------------------------------------------------------------
-- le réseau a changé (éditeur) : zones à recalculer
function ADIntersectionModule.clearCache()
    ADIntersectionModule.zones = {}
end

-- ------------------------------------------------------------------------------------------------------------
-- Attente à la ligne, recul, patience : IntersectionHold.lua (chargé avant ce fichier)
-- ------------------------------------------------------------------------------------------------------------
if ADIntersectionHold ~= nil then ADIntersectionHold.install(ADIntersectionModule) end -- 08/11 attente a la ligne, recul, patience : IntersectionHold.lua
