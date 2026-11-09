-- ============================================================================================================
-- FarmPilot : FieldParkModulePath.lua
-- Complément de FieldParkModule.lua : le chemin jusqu'à la place (moissonneuse et ensileuse).
--
-- Règles : la fin du chemin suit le bord du champ (une longueur d'attelage + LEAD_EXTRA, à la même distance du bord
-- que la place : un bord courbe donne une courbe) ; le chemin direct est une courbe de Dubins contrôlée chaque mètre
-- sur la largeur de l'attelage (culture debout, autre champ, herbe loin du bord, obstacles) ; le pathfinder
-- d'AutoDrive, trop grossier pour une bande le long du bord, ne sert que si elle échoue. Vers une place au bord de la
-- route : aucun champ, sauf à l'entrée (pas de demi-tour dans le champ).
--
-- Branché par : WaitForCallTaskFieldPark.lua et DriveToVehicleTaskFieldPark.lua (getLeadIn, findDirectPath,
-- appendLeadIn ; isPathClear aussi pour contrôler un trajet du pathfinder).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFieldPark.MIN_TURN_RADIUS = 6                     -- m, tightest turn tried for the direct path
ADFieldPark.CROP_MARGIN = 0.7                       -- m added on each side of the train when checking the crop
ADFieldPark.START_FREE = 15                         -- m from the unloader where the path may leave the road over the grass
ADFieldPark.START_ANY_FIELD = 12                    -- m from the unloader never refused for another field (entrance)
ADFieldPark.LEAD_EXTRA = 4                          -- m added to the train length for the end of the path along the border
ADFieldPark.LEAD_MIN = 8                            -- m, shortest end along the border (near a field corner)
ADFieldPark.LEAD_STEP = 2                           -- m between two points of the end along the border
ADFieldPark.LEAD_ACROSS = 8                         -- m looked at on each side to find the border at each point

-- ------------------------------------------------------------------------------------------------------------
-- Fin du chemin le long du bord du champ
-- ------------------------------------------------------------------------------------------------------------
-- the end of the path follows the field border: its points, a train length (+ ADFieldPark.LEAD_EXTRA) back
-- from the spot, at the same distance from the border as the spot, every ADFieldPark.LEAD_STEP m. A curved border
-- gives a curve, a straight one a straight line. The point where it starts and the points to the spot; the spot
-- itself and nil when no part of it is clear (crop, obstacle, another field, a road)
function ADFieldPark.getLeadIn(vehicle, spot)
    local front, rear = ADTrafficYieldModule.getTrainExtents(vehicle)
    local full = front + rear + ADFieldPark.LEAD_EXTRA
    local halfW = ADTrafficYieldModule.getWidth(vehicle) / 2 + 0.3
    -- the field of the harvester: the border is looked for on it, the trace never on another field nor a road
    local area = nil
    local m = spot.harvester ~= nil and ADFieldPark.harvesterMotion[spot.harvester] or nil
    if m ~= nil and m.area ~= nil then
        area = m.area
    elseif spot.harvester ~= nil and spot.harvester.components ~= nil then
        local hx, _, hz = getWorldTranslation(spot.harvester.components[1].node)
        area = ADFieldPark.getHarvesterArea(hx, hz)
    end
    local savedArea, savedRelaxed = ADFieldPark.area, ADFieldPark.relaxed
    ADFieldPark.area, ADFieldPark.relaxed = area, false
    local py = spot.y or 0
    -- distance of the spot from the border (along the normal pointing out of the field)
    local trace = {{x = spot.x, z = spot.z}}
    -- normal of the train pointing out of the field, and the distance of the spot from the border along it
    local nx, nz = spot.dirZ, -spot.dirX
    local offset = ADFieldPark.borderAcross(spot.x, spot.z, nx, nz, py)
    local back = ADFieldPark.borderAcross(spot.x, spot.z, -nx, -nz, py)
    if offset == nil or (back ~= nil and math.abs(back) < math.abs(offset)) then
        nx, nz, offset = -nx, -nz, back
    end
    if offset ~= nil then
        local x, z, hx, hz = spot.x, spot.z, -spot.dirX, -spot.dirZ
        local travelled = 0
        while travelled < full do
            -- one step back, then across to the border (same side), at the same distance from it
            local cx, cz = x + hx * ADFieldPark.LEAD_STEP, z + hz * ADFieldPark.LEAD_STEP
            local d = ADFieldPark.borderAcross(cx, cz, nx, nz, py)
            if d == nil then
                break
            end
            local px, pz = cx + nx * (d - offset), cz + nz * (d - offset)
            local step = MathUtil.vector2Length(px - x, pz - z)
            if step < 0.5 or ((px - x) * hx + (pz - z) * hz) / step < 0.7 then
                -- the border turns too much here (field corner)
                break
            end
            local ohx, ohz = hx, hz
            hx, hz = (px - x) / step, (pz - z) / step
            -- the normal turns with the border, same side
            local mx, mz = hz, -hx
            if mx * nx + mz * nz < 0 then
                mx, mz = -mx, -mz
            end
            nx, nz = mx, mz
            x, z = px, pz
            travelled = travelled + step
            table.insert(trace, 1, {x = x, z = z})
        end
    end
    ADFieldPark.area, ADFieldPark.relaxed = savedArea, savedRelaxed
    local roads = ADFieldPark.getWayPointsAround(spot.x, spot.z, full + 20)
    local reason = "no border"
    -- shortened from its far end until it is clear
    while #trace >= 2 and (#trace - 1) * ADFieldPark.LEAD_STEP >= ADFieldPark.LEAD_MIN do
        local points = {}
        for _, t in ipairs(trace) do
            table.insert(points, {x = t.x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, t.x, py, t.z), z = t.z})
        end
        local blocked, ox, oz = ADFieldPark.isPathClear(vehicle, points, halfW, nil, spot.roadside == true)
        for k = 1, #points - 1 do
            local p, n = points[k], points[k + 1]
            local l = math.max(MathUtil.vector2Length(n.x - p.x, n.z - p.z), 0.01)
            local dx, dz = (n.x - p.x) / l, (n.z - p.z) / l
            for _, side in ipairs({0, -1, 1}) do
                local x, z = p.x + dz * side * halfW, p.z - dx * side * halfW
                if blocked == nil and area ~= nil and not area.capped and AutoDrive.checkIsOnField(x, 0, z) and not PathFinderModule.isInFieldArea(area, x, z) then
                    blocked, ox, oz = "other field", x, z
                end
            end
            for _, wp in ipairs(roads) do
                if blocked == nil and MathUtil.vector2Length(wp.x - p.x, wp.z - p.z) < halfW + 1 then
                    blocked, ox, oz = "road", p.x, p.z
                end
            end
        end
        if blocked == nil then
            local l = math.max(MathUtil.vector2Length(points[2].x - points[1].x, points[2].z - points[1].z), 0.01)
            local target = {x = points[1].x, y = points[1].y, z = points[1].z,
                dirX = (points[2].x - points[1].x) / l, dirZ = (points[2].z - points[1].z) / l, roadside = spot.roadside}
            table.remove(points, 1)
            return target, points
        end
        reason = string.format("%s at x=%.0f z=%.0f", blocked, ox, oz)
        table.remove(trace, 1)
    end
    vehicle.ad.trafficYieldModule:log("field park: no lead-in along the border (%s), straight to the spot", reason)
    return spot, nil
end

-- distance from (x, z) to the field border along (nx, nz) (pointing out of the field), negative when (x, z) is off the
-- field; nil when no border within ADFieldPark.LEAD_ACROSS m
function ADFieldPark.borderAcross(x, z, nx, nz, py)
    local step = 0.25
    local wasOn = nil
    for t = -ADFieldPark.LEAD_ACROSS, ADFieldPark.LEAD_ACROSS, step do
        local on = ADFieldPark.isOnField(x + nx * t, py, z + nz * t)
        if wasOn == true and not on then
            return t - step / 2
        end
        wasOn = on
    end
    return nil
end

-- the path to the lead-in point, then the part along the border
function ADFieldPark.appendLeadIn(path, leadIn)
    if leadIn == nil then
        return path
    end
    local result = {}
    for _, p in ipairs(path) do
        table.insert(result, p)
    end
    for _, p in ipairs(leadIn) do
        table.insert(result, {x = p.x, y = p.y, z = p.z})
    end
    return result
end

-- ------------------------------------------------------------------------------------------------------------
-- Chemin direct (courbe de Dubins) et contrôle d'un chemin
-- ------------------------------------------------------------------------------------------------------------
-- direct path to a spot: a Dubins curve from the unloader to the spot, checked every meter with the width of the
-- train against growing crop and every few meters against obstacles. The AutoDrive pathfinder works on a grid of
-- the turn radius size, too coarse for a harvested strip along the border, so it is only used when this fails
function ADFieldPark.findDirectPath(vehicle, spot)
    if ADDubins == nil then
        return nil
    end
    local x, _, z = ADTrafficYieldModule.getPosition(vehicle)
    local rx, rz = ADTrafficYieldModule.getDirection(vehicle)
    local q0 = {x, -z, AutoDrive.normalizeAngle(math.atan2(rx, rz) + math.pi * 1.5)}
    local q1 = {spot.x, -spot.z, AutoDrive.normalizeAngle(math.atan2(spot.dirX, spot.dirZ) + math.pi * 1.5)}
    -- the crop is checked with the real width of the train plus a small margin
    local halfW = ADTrafficYieldModule.getWidth(vehicle) / 2 + ADFieldPark.CROP_MARGIN
    -- turn radius: the AutoDrive one first (often a default of 9 m with a trailer), then the tighter one of the
    -- tractor itself, as a driver would do to enter a harvested strip along the border
    local radii = {}
    for _, radius in ipairs({AutoDrive.getDriverRadius(vehicle), AutoDrive.getDriverRadius(vehicle, true), ADFieldPark.MIN_TURN_RADIUS}) do
        if radius ~= nil and radius >= ADFieldPark.MIN_TURN_RADIUS and (#radii == 0 or radius < radii[#radii] - 0.5) then
            table.insert(radii, radius)
        end
    end
    -- fields the path may cross: the one of the spot and the one the unloader stands on, identified like the
    -- AutoDrive pathfinder does in strict mode (connected field ground, then map field outline, then farmland)
    local fieldRule = nil
    if g_farmlandManager ~= nil and PathFinderModule ~= nil and PathFinderModule.isFieldPositionAllowed ~= nil and PathFinderModule.getFieldAtPosition ~= nil then
        fieldRule = {strictField = true, allowedFields = {}, allowedFarmlands = {}, allowedAreas = {}}
        for _, pos in ipairs({{x = spot.x, z = spot.z}, {x = x, z = z}}) do
            if AutoDrive.checkIsOnField(pos.x, 0, pos.z) then
                local area = ADFieldPark.getHarvesterArea(pos.x, pos.z)
                if area ~= nil then
                    fieldRule.allowedAreas[area] = true
                end
                local field = PathFinderModule.getFieldAtPosition(pos.x, pos.z)
                if field ~= nil then
                    fieldRule.allowedFields[field] = true
                end
                fieldRule.allowedFarmlands[g_farmlandManager:getFarmlandIdAtWorldPosition(pos.x, pos.z)] = true
            end
        end
    end
    local dubins = ADDubins:new()
    local reasons = nil
    for _, radius in ipairs(radii) do
        -- 0: shortest path, then each path type in turn
        for pathType = 0, 6 do
            dubins.outPath = {}
            local result
            if pathType == 0 then
                result = dubins:dubins_shortest_path(ADDubins.DubinsPath, q0, q1, radius)
            else
                result = dubins:dubins_path(ADDubins.DubinsPath, q0, q1, radius, pathType)
            end
            if result == ADDubins.EDUBOK
                and dubins:dubins_path_sample_many(ADDubins.DubinsPath, 1, dubins.createWayPoints) == ADDubins.EDUBOK
                and #dubins.outPath > 1 then
                local blocked, bx, bz, index = ADFieldPark.isPathClear(vehicle, dubins.outPath, halfW, fieldRule, spot.roadside == true)
                if blocked == nil then
                    vehicle.ad.trafficYieldModule:log("field park: direct path with a turn radius of %.1f m", radius)
                    return dubins.outPath
                end
                if pathType == 0 then
                    reasons = (reasons or "") .. string.format(" [radius %.1f: %s at x=%.0f z=%.0f, point %d/%d]", radius, blocked, bx, bz, index, #dubins.outPath)
                end
            end
        end
    end
    vehicle.ad.trafficYieldModule:log("field park: no direct path from x=%.0f z=%.0f heading %.0f°:%s",
        x, z, math.deg(math.atan2(rx, rz)), reasons or " no curve")
    return nil
end

function ADFieldPark.isPathClear(vehicle, path, halfW, fieldRule, anyGrass)
    local islandCache = {}
    -- the roads around (from beside the road into the field, the path follows the road to the entrance)
    local roads = ADFieldPark.getWayPointsAround(path[1].x, path[1].z, ADFieldPark.ROADSIDE_RANGE + 60)
    for i = 1, #path - 1 do
        local p, n = path[i], path[i + 1]
        local dx, dz = n.x - p.x, n.z - p.z
        local length = MathUtil.vector2Length(dx, dz)
        if length > 0.01 then
            dx, dz = dx / length, dz / length
            -- across the whole width of the train (GIANTS local +x (left) of the heading is (dz, -dx))
            for _, side in ipairs({0, -0.5, 0.5, -1, 1}) do
                local x, z = p.x + dz * side * halfW, p.z - dx * side * halfW
                local crop, fruitTypeIndex = ADFieldPark.hasGrowingCrop(x, z)
                -- small patches forgotten by the harvester may be driven over, like the AutoDrive pathfinder does
                if crop and not ADFieldPark.isCropIsland(fruitTypeIndex, x, z, islandCache) and not ADFieldPark.isBorderFringe(x, z) then
                    return "crop", x, z, i
                end
                if AutoDrive.checkIsOnField(x, 0, z) then
                    -- to a place beside the road: no field at all, except at the entrance (no U-turn in the field)
                    if anyGrass and MathUtil.vector2Length(x - path[1].x, z - path[1].z) >= ADFieldPark.START_ANY_FIELD then
                        return "field", x, z, i
                    end
                    -- another field is not allowed
                    if fieldRule ~= nil and MathUtil.vector2Length(x - path[1].x, z - path[1].z) >= ADFieldPark.START_ANY_FIELD
                        and not PathFinderModule.isFieldPositionAllowed(fieldRule, x, z) then
                        return "other field", x, z, i
                    end
                elseif not anyGrass and MathUtil.vector2Length(x - path[1].x, z - path[1].z) > ADFieldPark.START_FREE
                    and not ADFieldPark.isNearField(x, z, halfW + 0.1) and not ADFieldPark.isOnRoad(roads, x, z) then
                    -- the grass only along the border, the train at most half on it (trees, ditches beyond),
                    -- except when leaving the road at the entrance
                    return "grass", x, z, i
                end
            end
            -- obstacles (hedges, walls, poles, trees...) under the tractor, every 2 m
            if i > 2 and i % 2 == 0 and vehicle.ad.trafficYieldModule:overlapHit(p.x, (p.y or 0) + 1.9, p.z, math.atan2(dx, dz), halfW, 1.3, 2.5) then
                return "obstacle", p.x, p.z, i
            end
        end
    end
    -- nil when the path is clear, otherwise what blocks it and where
    return nil
end

-- on an AutoDrive road (within ADFieldPark.ROAD_HALF_WIDTH + 1 m of its line)
function ADFieldPark.isOnRoad(roads, x, z)
    local limit = ADFieldPark.ROAD_HALF_WIDTH + 1
    for _, wp in ipairs(roads) do
        if math.abs(wp.x - x) < 30 and math.abs(wp.z - z) < 30 then
            for _, id in pairs(wp.out or {}) do
                local nb = ADGraphManager:getWayPointById(id)
                if nb ~= nil then
                    local sx, sz = nb.x - wp.x, nb.z - wp.z
                    local l2 = sx * sx + sz * sz
                    local t = l2 > 0 and math.max(0, math.min(1, ((x - wp.x) * sx + (z - wp.z) * sz) / l2)) or 0
                    if MathUtil.vector2Length(wp.x + sx * t - x, wp.z + sz * t - z) < limit then
                        return true
                    end
                end
            end
        end
    end
    return false
end
