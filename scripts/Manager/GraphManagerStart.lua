-- ============================================================================================================
-- FarmPilot : GraphManagerStart.lua
-- Point de départ d'une route (complément d'ADGraphManager:getPathTo).
--
-- (11/11) Le point de départ est le point du réseau le mieux placé devant le véhicule (findMatchingWayPoint :
-- près, dans l'axe, route qui part dans le sens du véhicule). Ce point peut être l'entrée d'un bout de route qui
-- ne mène qu'à une place prise en marche arrière (la travée voisine) : aucune route n'en sort vers la destination,
-- le chauffeur s'arrêtait (« ne peut pas rejoindre… ») alors que d'autres points devant lui y mènent.
--
-- Règle : sans route depuis le point choisi, les autres points devant le véhicule sont essayés (mêmes conditions
-- et même note que le 1er), puis le point le plus proche qui n'est pas en marche arrière. Entre ceux qui donnent
-- une route, le mieux placé est gardé, sauf si un autre donne une route nettement plus courte (START_COST_MARGIN,
-- distance jusqu'au point comprise) ; une route qui commence par une marche arrière (retour au fond d'une place,
-- outil attelé derrière) ne passe qu'en dernier. Aucun : comme avant (message, arrêt).
--
-- (11/11 midi) Après une courbe calculée qui ramène le véhicule sur une route (sortie d'une place après avoir posé
-- ou attelé un outil avant), le tracteur est sur le point de route visé, mais son nez l'a déjà dépassé : le point
-- cherché devant le nez était celui d'une autre route, de l'autre côté de la cour, et le tracteur y allait tout
-- droit. Règle : les routes calculées ensuite partent du point rejoint (setJoinedWayPoint, noté par la tâche qui
-- suit la courbe), tant que le véhicule n'a pas bougé de plus de JOINED_MOVED depuis la fin de la courbe (point à
-- JOINED_RANGE au plus, noté depuis moins de JOINED_TIME). Toutes les routes, pas seulement la première : avant de
-- repartir, le mode en calcule plusieurs pour choisir par où reprendre un outil (AutonomousNoseIn.lua), et la
-- première de ces routes d'essai prenait le point pour elle seule (essai du 11/11 12:47).
--
-- Branché par : ADGraphManager:getPathTo (GraphManager.lua) ; ADFrontBackOffTask (FrontPlaceTask.lua) ;
-- register.lua (chargé après GraphManager.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADGraphManager.START_RANGE_MIN = 1      -- m : mêmes distances que findMatchingWayPointForVehicle
ADGraphManager.START_RANGE_MAX = 20
ADGraphManager.START_MAX_TRIES = 12     -- points essayés au plus (un calcul de route chacun)
ADGraphManager.START_REVERSE_SPAN = 50  -- m : une marche arrière dans ce début de route…
ADGraphManager.START_REVERSE_COST = 1000 -- m : …compte comme autant de route en plus
ADGraphManager.START_COST_MARGIN = 20   -- m : un point moins bien placé n'est pris que s'il fait gagner plus que ça
ADGraphManager.JOINED_RANGE = 8         -- m : le point rejoint par une courbe sert de départ s'il est à moins que ça…
ADGraphManager.JOINED_MOVED = 3         -- m : …tant que le véhicule n'a pas bougé de plus que ça depuis la fin de la courbe…
ADGraphManager.JOINED_TIME = 60000      -- ms : …et s'il a été noté depuis moins que ça

-- ------------------------------------------------------------------------------------------------------------
-- Points de départ possibles
-- ------------------------------------------------------------------------------------------------------------
-- les points devant le véhicule qui peuvent servir de départ, du mieux placé au moins bien placé
-- (mêmes conditions et même note que findMatchingWayPoint) : { { id, score }, … }
function ADGraphManager:matchingWayPoints(point, direction, candidates)
    local best = {}
    for _, id in pairs(candidates or {}) do
        local toCheck = self.wayPoints[id]
        if toCheck ~= nil and toCheck.out ~= nil and toCheck.incoming ~= nil and #toCheck.incoming > 0 then
            for _, outId in ipairs(toCheck.out) do
                local nextP = self.wayPoints[outId]
                if nextP ~= nil then
                    local vecToNextPoint = { x = nextP.x - toCheck.x, z = nextP.z - toCheck.z }
                    local vecToVehicle = { x = toCheck.x - point.x, z = toCheck.z - point.z }
                    local angleToNextPoint = math.abs(AutoDrive.angleBetween(direction, vecToNextPoint))
                    local angleToVehicle = math.abs(AutoDrive.angleBetween(direction, vecToVehicle))
                    if angleToNextPoint < 60 and angleToVehicle < 30 then
                        local dis = MathUtil.vector2Length(vecToVehicle.x, vecToVehicle.z)
                        local score = angleToNextPoint + angleToVehicle + 45 * (dis / 20)
                        if best[id] == nil or score < best[id] then
                            best[id] = score
                        end
                    end
                end
            end
        end
    end
    local list = {}
    for id, score in pairs(best) do
        list[#list + 1] = { id = id, score = score }
    end
    table.sort(list, function(a, b)
        if a.score ~= b.score then
            return a.score < b.score
        end
        return a.id < b.id
    end)
    return list
end

-- une route qui mène à targetId (même contrôle que ADDrivePathModule:setPathTo)
function ADGraphManager.isRouteTo(wp, targetId)
    return wp ~= nil and (wp[2] ~= nil or (wp[1] ~= nil and wp[1].id == targetId))
end

local function logOtherStart(vehicle, failedId, startId, targetId)
    local marker = ADGraphManager.getMapMarkerByWayPointId ~= nil and ADGraphManager:getMapMarkerByWayPointId(targetId) or nil
    local target = marker ~= nil and marker.name ~= nil and string.format("« %s »", tostring(marker.name)) or string.format("le point %s", tostring(targetId))
    local name = vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.getName ~= nil and vehicle.ad.stateModule:getName() or "?"
    if ADAutonomousManager ~= nil and ADAutonomousManager.log ~= nil then
        ADAutonomousManager.log("%s : aucune route vers %s depuis le point %s devant lui, départ par le point %s", tostring(name), target, tostring(failedId), tostring(startId))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Route depuis un autre point de départ
-- ------------------------------------------------------------------------------------------------------------
-- longueur de la route (m), marche arrière dans son début comptée START_REVERSE_COST
local function routeCost(wp)
    local length, cost = 0, 0
    for i = 1, #wp - 1 do
        if length < ADGraphManager.START_REVERSE_SPAN and cost == 0 and ADGraphManager:isReverseRoad(wp[i], wp[i + 1]) then
            cost = ADGraphManager.START_REVERSE_COST
        end
        length = length + MathUtil.vector2Length(wp[i + 1].x - wp[i].x, wp[i + 1].z - wp[i].z)
    end
    return length + cost
end

-- route vers targetId depuis un autre point de départ que failedId (celui qui ne mène nulle part), et ce point ;
-- nil s'il n'y en a pas
function ADGraphManager:pathFromOtherStart(vehicle, targetId, failedId)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.frontNode == nil or vehicle.getWayPointIdsInRange == nil
        or self.wayPoints[targetId] == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(vehicle.ad.frontNode)
    local rx, _, rz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1, vehicle.ad.frontNode)
    local inRange = vehicle:getWayPointIdsInRange(ADGraphManager.START_RANGE_MIN, ADGraphManager.START_RANGE_MAX)
    local ids = {}
    for _, candidate in ipairs(self:matchingWayPoints({ x = x, z = z }, { x = rx, z = rz }, inRange)) do
        ids[#ids + 1] = candidate.id
    end
    if vehicle.getClosestNotReversedWayPoint ~= nil then
        local closest = vehicle:getClosestNotReversedWayPoint()
        if closest ~= nil and closest > 0 then
            ids[#ids + 1] = closest
        end
    end
    local tried = {}
    if failedId ~= nil then
        tried[failedId] = true
    end
    local tries = 0
    local best, bestCost, bestId = nil, math.huge, nil
    for _, id in ipairs(ids) do
        if not tried[id] then
            if tries >= ADGraphManager.START_MAX_TRIES then
                break
            end
            tried[id] = true
            tries = tries + 1
            local wp = self:pathFromTo(id, targetId, self:getBestOutPoints(vehicle, id), vehicle)
            if ADGraphManager.isRouteTo(wp, targetId) then
                local cost = routeCost(wp) + MathUtil.vector2Length(wp[1].x - x, wp[1].z - z)
                if cost < bestCost - ADGraphManager.START_COST_MARGIN then
                    best, bestCost, bestId = wp, cost, id
                end
            end
        end
    end
    if best ~= nil then
        logOtherStart(vehicle, failedId, bestId, targetId)
    end
    return best, bestId
end

-- ------------------------------------------------------------------------------------------------------------
-- Point de route rejoint par une courbe calculée : départ de la route qui suit
-- ------------------------------------------------------------------------------------------------------------
-- à appeler quand le véhicule arrive au point id par une courbe (pas par le réseau)
function ADGraphManager.setJoinedWayPoint(vehicle, id)
    if vehicle ~= nil and vehicle.ad ~= nil and id ~= nil then
        local x, z = nil, nil
        if vehicle.components ~= nil and vehicle.components[1] ~= nil then
            local px, _, pz = getWorldTranslation(vehicle.components[1].node)
            x, z = px, pz
        end
        vehicle.ad.fpJoinedWayPoint = { id = id, time = g_time or 0, x = x, z = z }
    end
end

-- Hook ADGraphManager:getPathTo : le point rejoint, s'il vaut encore comme départ (véhicule resté sur place) ; sinon
-- nil, et il est oublié
function ADGraphManager:joinedStart(vehicle, x, z)
    local joined = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.fpJoinedWayPoint or nil
    if joined == nil then
        return nil
    end
    local wp = self.wayPoints[joined.id]
    local now = g_time or 0
    local distance = wp ~= nil and wp.x ~= nil and MathUtil.vector2Length(wp.x - x, wp.z - z) or nil
    local moved = joined.x ~= nil and MathUtil.vector2Length(joined.x - x, joined.z - z) or 0
    if distance == nil or now < joined.time or now - joined.time > ADGraphManager.JOINED_TIME or distance > ADGraphManager.JOINED_RANGE
        or moved > ADGraphManager.JOINED_MOVED then
        vehicle.ad.fpJoinedWayPoint = nil
        if ADTraces ~= nil then -- traces privées
            ADTraces.log("[AD-Route] point %s rejoint par la courbe : ne vaut plus comme départ (à %s m, véhicule déplacé de %.1f m, noté depuis %d ms)",
                tostring(joined.id), distance ~= nil and string.format("%.1f", distance) or "?", moved, now - joined.time)
        end
        return nil
    end
    if not joined.logged and ADAutonomousManager ~= nil and ADAutonomousManager.log ~= nil then
        joined.logged = true -- une ligne au journal, pas une par route
        local name = vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.getName ~= nil and vehicle.ad.stateModule:getName() or "?"
        ADAutonomousManager.log("%s : la route repart du point %s, rejoint par la courbe (à %.1f m)", tostring(name), tostring(joined.id), distance)
    end
    return joined.id
end

-- ------------------------------------------------------------------------------------------------------------
-- Traces privées : d'où part chaque route (FarmPilotTraces.lua)
-- ------------------------------------------------------------------------------------------------------------
-- Hook ADGraphManager:getPathTo. how : comment le point de départ a été choisi
function ADGraphManager.traceRoute(vehicle, targetId, startId, how, wp)
    if ADTraces == nil or not ADTraces.isOn() or vehicle == nil or vehicle.ad == nil then
        return
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local name = vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.getName ~= nil and vehicle.ad.stateModule:getName() or "?"
    local start = startId ~= nil and ADGraphManager.wayPoints[startId] or nil
    local length, ids, reverse = 0, {}, ""
    for i = 1, #wp do
        if i <= 8 then
            ids[#ids + 1] = tostring(wp[i].id)
        end
        if wp[i + 1] ~= nil then
            length = length + MathUtil.vector2Length(wp[i + 1].x - wp[i].x, wp[i + 1].z - wp[i].z)
            if reverse == "" and ADGraphManager:isReverseRoad(wp[i], wp[i + 1]) then
                reverse = string.format(", marche arrière après %.0f m (point %s)", length, tostring(wp[i + 1].id))
            end
        end
    end
    local heading = "?"
    if vehicle.ad.frontNode ~= nil and AutoDrive.localDirectionToWorld ~= nil then
        local rx, _, rz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1, vehicle.ad.frontNode)
        heading = string.format("%.0f", math.deg(math.atan2(rx, rz)))
    end
    ADTraces.log("[AD-Route] %s (x %.1f z %.1f, cap %s°) vers le point %s : départ %s (%s%s), %d points, %.0f m%s, début %s", tostring(name), x, z, heading,
        tostring(targetId), tostring(startId), tostring(how), start ~= nil and string.format(", à %.1f m", MathUtil.vector2Length(start.x - x, start.z - z)) or "",
        #wp, length, reverse, table.concat(ids, " "))
end
