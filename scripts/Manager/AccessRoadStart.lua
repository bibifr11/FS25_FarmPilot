-- ============================================================================================================
-- FarmPilot : AccessRoadStart.lua
-- Route d'accès (AccessRoadManager.lua) et point de départ d'une route.
--
-- (15/11) Une route d'accès n'est prise que pour aller à son point. Mais quand le point de départ choisi devant le
-- véhicule était sur une route d'accès (véhicule garé à côté, cour de ferme), toute la route d'accès devenait libre
-- pour lui (zone d'accès du départ, DirtRoadManager.lua accessPoints) et il partait par là.
--
-- Règles :
-- - Un point de route d'accès n'est jamais choisi comme départ.
-- - Seule exception (15/11) : aucun autre point du réseau (pas route d'accès) à FREE_RANGE m (20 m) ou moins du
--   véhicule, par exemple garé au bout de la route d'accès : il en sort par elle. Sinon le départ se fait par l'autre
--   point (avant : véhicule à 5 m ou moins de la route d'accès). Le journal le dit.
-- - Le départ remplaçant est choisi comme d'habitude (près, dans l'axe du véhicule, findMatchingWayPoint) parmi les
--   autres points, sinon le point le plus proche qui n'est pas une route d'accès. Le journal le dit.
--
-- Branché par : ADGraphManager:getPathTo (GraphManager.lua) et ADGraphManager:pathFromOtherStart
-- (GraphManagerStart.lua), une ligne chacun ; register.lua (chargé après AccessRoadManager.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAccessRoads.FREE_RANGE = 20       -- m (15/11) : départ sur la route d'accès permis sans aucun autre point à cette distance
ADAccessRoads.START_RANGE_MIN = 1   -- m : mêmes distances que findMatchingWayPointForVehicle
ADAccessRoads.START_RANGE_MAX = 20

-- ------------------------------------------------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------------------------------------------------
-- (15/11) départ sur une route d'accès permis : aucun autre point du réseau (pas route d'accès) à FREE_RANGE m ou
-- moins du véhicule ; rend aussi le point le plus proche qui n'est pas une route d'accès et sa distance (journal)
function ADAccessRoads.isAccessStartAllowed(vehicle)
    if vehicle == nil or vehicle.components == nil or vehicle.components[1] == nil or ADGraphManager.getWayPoints == nil then
        return false
    end
    local network = ADGraphManager:getWayPoints()
    if network == nil then
        return false
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local closestId, closestDistance = nil, math.huge
    for id, wp in pairs(network) do
        if not ADAccessRoads.isAccess(wp) then
            local distance = MathUtil.vector2Length(wp.x - x, wp.z - z)
            if distance < closestDistance then
                closestId, closestDistance = id, distance
            end
        end
    end
    return closestDistance > ADAccessRoads.FREE_RANGE, closestId, closestDistance
end

-- liste d'ids de départ possibles, sans les points de route d'accès (sauf aucun autre point à 20 m)
function ADAccessRoads.filterStartIds(vehicle, ids)
    if ids == nil or ADAccessRoads.isAccessStartAllowed(vehicle) then
        return ids
    end
    local kept = {}
    for _, id in ipairs(ids) do
        if not ADAccessRoads.isAccessId(id) then
            kept[#kept + 1] = id
        end
    end
    return kept
end

local function log(vehicle, fmt, ...)
    local name = (vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.getName ~= nil)
        and vehicle.ad.stateModule:getName() or "?"
    print(string.format("[FarmPilot Routes] %s : " .. fmt, tostring(name), ...))
end

-- ------------------------------------------------------------------------------------------------------------
-- Hook ADGraphManager:getPathTo : point de départ sur une route d'accès -> autre point (ou nil = garder)
-- ------------------------------------------------------------------------------------------------------------
function ADAccessRoads.fixStart(graph, vehicle, startId)
    if vehicle == nil or startId == nil or not ADAccessRoads.isAccessId(startId) then
        return nil
    end
    local allowed, _, otherDistance = ADAccessRoads.isAccessStartAllowed(vehicle)
    if allowed then
        -- (15/11) aucun autre point à 20 m : le départ reste sur la route d'accès (une ligne par départ)
        if vehicle.fpAccessStartLog ~= startId then
            vehicle.fpAccessStartLog = startId
            log(vehicle, "départ %s sur une route d'accès permis : aucun autre point à %d m du véhicule (le plus proche à %s)", tostring(startId),
                ADAccessRoads.FREE_RANGE, otherDistance < math.huge and string.format("%.0f m", otherDistance) or "aucun")
        end
        return nil
    end
    vehicle.fpAccessStartLog = nil
    local best = -1
    if vehicle.ad.frontNode ~= nil and vehicle.getWayPointIdsInRange ~= nil then
        local x, _, z = getWorldTranslation(vehicle.ad.frontNode)
        local rx, _, rz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1, vehicle.ad.frontNode)
        local ids = ADAccessRoads.filterStartIds(vehicle,
            vehicle:getWayPointIdsInRange(ADAccessRoads.START_RANGE_MIN, ADAccessRoads.START_RANGE_MAX))
        best = graph:findMatchingWayPoint({ x = x, z = z }, { x = rx, z = rz }, ids)
    end
    if best == nil or best == -1 then
        -- le plus proche qui n'est ni une route d'accès ni en marche arrière seule
        if vehicle.updateWayPointsDistance ~= nil then
            vehicle:updateWayPointsDistance()
        end
        local bestDistance = math.huge
        for _, elem in pairs(vehicle.ad.distances.wayPoints or {}) do
            local wp = elem.wayPoint
            if elem.distance < bestDistance and wp.id > 0 and not ADAccessRoads.isAccess(wp)
                and (wp.incoming == nil or #wp.incoming > 0) then
                best, bestDistance = wp.id, elem.distance
            end
        end
    end
    if best == nil or best == -1 then
        return nil
    end
    log(vehicle, "départ %s sur une route d'accès, un autre point est à %s du véhicule (%d m au plus pour partir par la route d'accès) : la route part du point %s",
        tostring(startId), otherDistance ~= nil and string.format("%.0f m", otherDistance) or "? m (distance inconnue)", ADAccessRoads.FREE_RANGE, tostring(best))
    return best
end
