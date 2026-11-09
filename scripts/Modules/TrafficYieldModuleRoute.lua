-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleRoute.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : lecture des trajets et du réseau AutoDrive.
--
-- Règle :
-- - trajet restant d'un véhicule : longueur, polyligne, distance jusqu'à un point du réseau, point à N m devant,
--   véhicule encore devant moi sur mon trajet (pas encore croisé), hors de mon trajet ;
-- - réseau à double sens (chemin unique) : un lien parcouru dans les deux sens ; entrée d'un chemin unique = point à 3
--   voisins ou plus avec un lien à double sens ; la procédure de croisement ne vaut que si les deux trajets ont un
--   tronçon à double sens en commun (28/10).
--
-- Branché par : les autres fichiers TrafficYieldModule*.lua ; getRoutePolyline sert aussi à AvoidModule.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Le long d'un trajet
-- ------------------------------------------------------------------------------------------------------------
-- length of a list of waypoints from index 'from'
function ADTrafficYieldModule.getPathLength(points, from)
    local length = 0
    for k = math.max(from, 1), #points - 1 do
        length = length + MathUtil.vector2Length(points[k + 1].x - points[k].x, points[k + 1].z - points[k].z)
    end
    return length
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

-- 'other' lies on my route ahead of me (PASSED_ROUTE_WIDTH m at most from it): not passed yet, whatever my own axis says
-- (30/10: the 7R 350 at the road junction, turned along the road, the track leaving behind it: the 942 Vario
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

-- ------------------------------------------------------------------------------------------------------------
-- Réseau à double sens (chemin unique)
-- ------------------------------------------------------------------------------------------------------------
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

-- 28/10 (the procedure only when both routes share a two-way stretch): true when the routes of both
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
