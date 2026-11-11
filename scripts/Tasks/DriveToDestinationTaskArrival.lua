-- ============================================================================================================
-- FarmPilot : DriveToDestinationTaskArrival.lua
-- Complément de DriveToDestinationTask (tâche AutoDrive d'origine) : ce qui se passe en route et à l'arrivée.
--
-- Historique : S8, 28/10 17:43 (Patriot 4450 à « Champ 40 », départ 17:01 : le
-- point de destination est à 6 m du chemin de gravier, le véhicule s'y est arrêté la carrosserie encore sur le
-- chemin et le 8510 s'est coincé à côté).
--
-- Règle :
-- - trajet partiel (départ guidé, une partie du chemin) : à son bout, la suite est calculée de là (setUp) ;
-- - en mode « Conduire vers », un véhicule dont l'attelage est encore sur le chemin à sa destination continue tout
--   droit dans le champ (ou quelques mètres sur le bord, sans fossé ni talus) jusqu'à avoir l'arrière à ROAD_CLEAR m
--   du chemin ; une fois par trajet, jamais en marche arrière ; s'arrête là après ROAD_CLEAR_TIMEOUT ;
-- - benne vide qui revient au champ : attentes avant l'entrée (DriveToDestinationTaskFieldEntrance.lua).
--
-- Branché par une ligne dans DriveToDestinationTask.lua : update (étape « en route »).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
DriveToDestinationTask.ROAD_CLEAR = 3.5          -- m between the road line and the nearest rear corner of the train
DriveToDestinationTask.ROAD_CLEAR_MAX = 15       -- m driven on at most
DriveToDestinationTask.ROAD_CLEAR_SHOULDER = 4   -- m at most when the ground ahead is not a field (roadside)
DriveToDestinationTask.ROAD_CLEAR_SLOPE = 0.5    -- m of height change per metre refused (ditch, bank)
DriveToDestinationTask.ROAD_CLEAR_STEP = 2       -- m between the added points
DriveToDestinationTask.ROAD_CLEAR_TIMEOUT = 25000 -- ms, then it stops where it is

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale : en route et à l'arrivée (DriveToDestinationTask:update)
-- ------------------------------------------------------------------------------------------------------------
-- true : traité ici (fin de l'update) ; false : le code d'AutoDrive continue (arrivé : fin de la tâche, sinon rouler)
function DriveToDestinationTask:updateArrival(dt)
    if self.vehicle.ad.drivePathModule:isTargetReached() and self.routeIsPartial then
        -- end of a partial route, not the destination: plan the rest from here
        print(string.format("[AD-Fin] %s: bout du trajet partiel atteint, calcul de la suite", tostring(self.vehicle:getName())))
        self.routeIsPartial = false
        self:setUp()
        return true
    elseif self.vehicle.ad.drivePathModule:isTargetReached() then
        if self.roadClear == nil and self:startRoadClear() then
            return true
        end
        return false
    elseif type(self.roadClear) == "table" and g_time - self.roadClear.start > DriveToDestinationTask.ROAD_CLEAR_TIMEOUT then
        print(string.format("[AD-Fin] %s: pas arrive a degager le chemin en %d s, je m'arrete la", tostring(self.vehicle:getName()), DriveToDestinationTask.ROAD_CLEAR_TIMEOUT / 1000))
        self:finished()
        return true
    elseif self:isEntranceHold(dt) then
        return true
    elseif self:isZoneBusyHold(dt) then
        return true
    elseif self:isFieldFullStop(dt) then
        return true
    elseif self:isNoPlaceStop(dt) then
        return true
    end
    -- S8: the last link of the route, still known when the target is reached (the route is cleared then)
    local wayPoints = self.vehicle.ad.drivePathModule.wayPoints
    if self.roadClear == nil and wayPoints ~= nil and #wayPoints >= 2 then
        self.endWayPoints = wayPoints
        self.endPrevious, self.endLast = wayPoints[#wayPoints - 1], wayPoints[#wayPoints]
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Dégager le chemin à l'arrivée (S8)
-- ------------------------------------------------------------------------------------------------------------
-- S8 (28/10 17:43, Patriot 4450 at "Champ 40", go 17:01): the destination point is 6 m off the gravel road, the
-- vehicle stopped there with its body still on the road and the 8510 got wedged beside it. In "drive to", a vehicle
-- whose train still stands on the road at its destination drives on straight ahead into the field (or a few metres
-- onto the roadside) until its rear is ROAD_CLEAR m from the road. Once per drive, never when reversing
function DriveToDestinationTask:startRoadClear()
    self.roadClear = false
    local vehicle = self.vehicle
    if vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_DRIVETO or vehicle.spec_locomotive ~= nil or self.routeIsPartial
        or ADTrafficYieldModule == nil or self.endLast == nil or self.endPrevious == nil or self.endLast.id == nil then
        return false
    end
    local last, previous = self.endLast, self.endPrevious
    local dest = ADGraphManager:getWayPointById(last.id)
    if dest == nil then
        return false
    end
    -- the road around the destination: the links of its neighbours, the destination itself left out
    local segments, seen, neighbours = {}, {}, {}
    for _, list in ipairs({dest.out or {}, dest.incoming or {}}) do
        for _, id in ipairs(list) do
            neighbours[id] = true
        end
    end
    for id, _ in pairs(neighbours) do
        local node = ADGraphManager:getWayPointById(id)
        if node ~= nil then
            for _, list in ipairs({node.out or {}, node.incoming or {}}) do
                for _, otherId in ipairs(list) do
                    local key = math.min(id, otherId) .. "-" .. math.max(id, otherId)
                    local other = otherId ~= dest.id and ADGraphManager:getWayPointById(otherId) or nil
                    if other ~= nil and not seen[key] then
                        seen[key] = true
                        table.insert(segments, {node, other})
                    end
                end
            end
        end
    end
    if #segments == 0 then
        return false
    end
    local function roadDistance(x, z)
        local best = math.huge
        for _, segment in ipairs(segments) do
            local a, b = segment[1], segment[2]
            local dx, dz = b.x - a.x, b.z - a.z
            local l2 = dx * dx + dz * dz
            local t = l2 > 0.0001 and math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / l2)) or 0
            best = math.min(best, MathUtil.vector2Length(x - (a.x + dx * t), z - (a.z + dz * t)))
        end
        return best
    end
    -- the last link leads away from the road (the destination is not a point on the road itself), driven forwards
    local dx, dz = last.x - previous.x, last.z - previous.z
    local length = MathUtil.vector2Length(dx, dz)
    if length < 0.5 then
        return false
    end
    dx, dz = dx / length, dz / length
    if roadDistance(last.x + dx * 5, last.z + dz * 5) < roadDistance(last.x, last.z) + 2 then
        return false
    end
    local fx, fz = ADTrafficYieldModule.getDirection(vehicle)
    if fx * dx + fz * dz < 0.7 then
        return false
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local front, rear = ADTrafficYieldModule.getTrainExtents(vehicle)
    local half = ADTrafficYieldModule.getWidth(vehicle) / 2
    -- length of the train behind the vehicle origin along its path: the tractor rear, plus every unit behind it
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(vehicle)
    local dims = vehicle.ad.adDimensions
    local behind = (dims ~= nil and dims.maxLengthBack ~= nil and dims.maxLengthBack > 0.1) and dims.maxLengthBack or tractorLength / 2
    local units = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit ~= vehicle and unit.components ~= nil and unit.components[1] ~= nil then
                local ux, uy, uz = getWorldTranslation(unit.components[1].node)
                local _, _, localZ = AutoDrive.worldToLocal(vehicle, ux, uy, uz)
                if localZ < 0 then
                    local _, unitLength = ADTrafficYieldModule.getUnitDimensions(unit)
                    behind = behind + unitLength
                end
            end
        end
    end
    behind = math.max(behind, rear)
    -- the path the train stands on: from the vehicle origin back along the route it drove (the trailers follow it)
    local path = {{x = x, z = z}}
    local wayPoints = self.endWayPoints or {previous}
    local walked = 0
    for i = #wayPoints - 1, 1, -1 do
        local wp = wayPoints[i]
        if wp ~= nil and (wp.x - x) * fx + (wp.z - z) * fz < 0 then
            local p = path[#path]
            walked = walked + MathUtil.vector2Length(wp.x - p.x, wp.z - p.z)
            table.insert(path, {x = wp.x, z = wp.z})
            if walked > behind + 1 then
                break
            end
        end
    end
    if walked < behind then
        -- route too short: straight on behind the last known point
        local p, q = path[#path], path[#path - 1] or {x = x + fx, z = z + fz}
        local bx, bz = p.x - q.x, p.z - q.z
        local bl = MathUtil.vector2Length(bx, bz)
        if bl < 0.01 then
            bx, bz, bl = -fx, -fz, 1
        end
        table.insert(path, {x = p.x + bx / bl * (behind - walked + 1), z = p.z + bz / bl * (behind - walked + 1)})
    end
    -- point of the train <a> metres behind the origin once the vehicle drove <s> metres on along the last link
    local function pointAt(a, s)
        if a <= s then
            return x + dx * (s - a), z + dz * (s - a), dx, dz
        end
        local remaining = a - s
        for k = 1, #path - 1 do
            local p, q = path[k], path[k + 1]
            local l = MathUtil.vector2Length(q.x - p.x, q.z - p.z)
            if l > 0.01 and (remaining <= l or k == #path - 1) then
                local t = remaining / l
                return p.x + (q.x - p.x) * t, p.z + (q.z - p.z) * t, (p.x - q.x) / l, (p.z - q.z) / l
            end
            remaining = remaining - l
        end
        return path[#path].x, path[#path].z, fx, fz
    end
    local function clearance(s)
        local best = math.huge
        local a = 0
        while true do
            local px, pz, ux, uz = pointAt(a, s)
            best = math.min(best, roadDistance(px, pz), roadDistance(px + uz * half, pz - ux * half), roadDistance(px - uz * half, pz + ux * half))
            if a >= behind then
                break
            end
            a = math.min(behind, a + 1)
        end
        return best
    end
    local now = clearance(0)
    if now >= DriveToDestinationTask.ROAD_CLEAR then
        return false
    end
    local needed = DriveToDestinationTask.ROAD_CLEAR_MAX
    for s = 1, DriveToDestinationTask.ROAD_CLEAR_MAX do
        if clearance(s) >= DriveToDestinationTask.ROAD_CLEAR then
            needed = math.min(s + 1, DriveToDestinationTask.ROAD_CLEAR_MAX)
            break
        end
    end
    -- the ground in front of the train: a field all the way, or a few metres of roadside without a ditch or a bank
    local nx, nz = x + fx * front, z + fz * front
    local lastHeight = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, nx, 300, nz)
    local allowed, where = 0, "dans le champ"
    for s = 1, needed do
        local px, pz = nx + dx * s, nz + dz * s
        local height = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, px, 300, pz)
        if math.abs(height - lastHeight) > DriveToDestinationTask.ROAD_CLEAR_SLOPE then
            break
        end
        lastHeight = height
        if not AutoDrive.checkIsOnField(px, height, pz) then
            if s > DriveToDestinationTask.ROAD_CLEAR_SHOULDER then
                break
            end
            where = "sur le bord"
        end
        allowed = s
    end
    local name = tostring(vehicle:getName())
    if allowed < 1 then
        print(string.format("[AD-Fin] %s: arrive, l'arriere est a %.1f m du chemin, mais pas de place devant (ni champ ni bord plat)", name, now))
        return false
    end
    -- points along the last link; the route ends when the steering node is within min_distance of the last one
    local sx, sz = x, z
    if vehicle.getAISteeringNode ~= nil then
        sx, _, sz = getWorldTranslation(vehicle:getAISteeringNode())
    end
    local startAlong = (sx - last.x) * dx + (sz - last.z) * dz
    local endAlong = startAlong + allowed + (vehicle.ad.drivePathModule.min_distance or 1)
    local y = last.y or getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, last.x, 300, last.z)
    local points = {{x = sx, y = y, z = sz}}
    local along = startAlong + DriveToDestinationTask.ROAD_CLEAR_STEP
    while along < endAlong do
        table.insert(points, {x = last.x + dx * along, y = y, z = last.z + dz * along})
        along = along + DriveToDestinationTask.ROAD_CLEAR_STEP
    end
    table.insert(points, {x = last.x + dx * endAlong, y = y, z = last.z + dz * endAlong})
    local destination = vehicle.ad.stateModule:getCurrentDestination()
    vehicle.ad.drivePathModule:setWayPoints(points)
    vehicle.ad.stateModule:setCurrentDestination(destination)
    self.roadClear = {start = g_time}
    print(string.format("[AD-Fin] %s: arrive avec l'arriere a %.1f m du chemin, je degage le chemin de %d m (%s)", name, now, allowed, where))
    return true
end
