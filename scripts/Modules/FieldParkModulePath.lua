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
-- appendLeadIn ; isPathClear aussi pour contrôler un trajet du pathfinder) ; findWayFromEntrance :
-- DriveToDestinationTaskFieldEntrance.lua et WaitForCallTaskFieldPark.lua (11/11).
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
ADFieldPark.LEAD_ACROSS = 12                        -- m looked at on each side to find the border at each point
-- 10/11, combine: way along the border to a place on the strip it has cut (findApproach)
ADFieldPark.APPROACH_MAX = 170                      -- m of border followed back from the place
ADFieldPark.APPROACH_ENTRIES = {6, 10, 14, 18, 24, 32} -- m ahead of the unloader, along the border, where it may join the line
ADFieldPark.NARROW_STRIP = 16                       -- m: cut ground narrower than this beside a place leaves no room for the AutoDrive pathfinder
ADFieldPark.TURN_BACK_OFF = {3, 6}                  -- m backed off straight when the turn into the cut strip is too wide from where the unloader stands

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
    local trace, area = ADFieldPark.traceBorder(spot, full)
    local py = spot.y or 0
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

-- points along the field border back from the spot, at the same distance from the border as the spot, every
-- ADFieldPark.LEAD_STEP m over length m at most (it stops where the border turns too much, a field corner). The first
-- point is the farthest from the spot, the last one the spot itself. Returns the points and the field of the harvester
function ADFieldPark.traceBorder(spot, length)
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
        while travelled < length do
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
    return trace, area
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
-- start (optional): {x, z, dx, dz} the curve starts from instead of where the unloader stands
function ADFieldPark.findDirectPath(vehicle, spot, start)
    if ADDubins == nil then
        return nil
    end
    local path, reasons, x, z, rx, rz = ADFieldPark.findDubins(vehicle, spot, false, start)
    if path == nil then
        vehicle.ad.trafficYieldModule:log("field park: no direct path from x=%.0f z=%.0f heading %.0f°:%s",
            x, z, math.deg(math.atan2(rx, rz)), reasons or " no curve")
    end
    return path
end

-- the Dubins curve itself; shortestOnly: only the shortest curve of each turn radius (no detour by another curve type)
function ADFieldPark.findDubins(vehicle, spot, shortestOnly, start)
    local x, _, z = ADTrafficYieldModule.getPosition(vehicle)
    local rx, rz = ADTrafficYieldModule.getDirection(vehicle)
    if start ~= nil then
        x, z, rx, rz = start.x, start.z, start.dx, start.dz
    end
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
        for pathType = 0, shortestOnly and 0 or 6 do
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
    return nil, reasons, x, z, rx, rz
end

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse : chemin le long du bord jusqu'à une place sur la bande coupée (10/11)
-- ------------------------------------------------------------------------------------------------------------
-- the way to a place on the strip the combine has cut follows the border from where the unloader stands: a short
-- curve onto the line along the border (same distance from it as the place), then that line to the place. The single
-- curve to the last meters before the place (findDirectPath) cuts across the grass, a hedge or the standing crop
-- beside a narrow strip. Returns the path; nil when the border cannot be followed (corner, crop, obstacle, road) or
-- joined from here
function ADFieldPark.findApproach(vehicle, spot, start)
    if ADDubins == nil or spot.roadside then
        return nil
    end
    local trace, area = ADFieldPark.traceBorder(spot, ADFieldPark.APPROACH_MAX)
    local minPoints = math.ceil(ADFieldPark.LEAD_MIN / ADFieldPark.LEAD_STEP) + 1
    if #trace < minPoints then
        return nil
    end
    local py = spot.y or 0
    local halfW = ADTrafficYieldModule.getWidth(vehicle) / 2 + 0.3
    -- from the place back: the part of the line that is clear (crop, obstacle, grass far from the border)
    local back = {}
    for i = #trace, 1, -1 do
        local t = trace[i]
        table.insert(back, {x = t.x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, t.x, py, t.z), z = t.z})
    end
    local blocked, _, _, index = ADFieldPark.isPathClear(vehicle, back, halfW, nil, false)
    local count = blocked ~= nil and index - 1 or #back
    -- never on another field, never across a road
    local roads = ADFieldPark.getWayPointsAround(spot.x, spot.z, ADFieldPark.APPROACH_MAX + 20)
    for k = 1, count do
        local p = back[k]
        local stop = area ~= nil and not area.capped and AutoDrive.checkIsOnField(p.x, 0, p.z) and not PathFinderModule.isInFieldArea(area, p.x, p.z)
        for _, wp in ipairs(roads) do
            if not stop and MathUtil.vector2Length(wp.x - p.x, wp.z - p.z) < halfW + 1 then
                stop = true
            end
        end
        if stop then
            count = k - 1
            break
        end
    end
    if count < minPoints then
        return nil
    end
    -- in driving order: the farthest clear point first, the place last
    local line = {}
    for k = count, 1, -1 do
        table.insert(line, back[k])
    end
    local x, _, z = ADTrafficYieldModule.getPosition(vehicle)
    if start ~= nil then
        x, z = start.x, start.z
    end
    local nearest, nearestDistance = 1, math.huge
    for k, p in ipairs(line) do
        local d = MathUtil.vector2Length(p.x - x, p.z - z)
        if d < nearestDistance then
            nearest, nearestDistance = k, d
        end
    end
    -- the line is joined a few meters ahead of the unloader, a little farther when the curve does not fit
    local tried = {}
    for _, ahead in ipairs(ADFieldPark.APPROACH_ENTRIES) do
        local k = math.min(nearest + math.ceil(ahead / ADFieldPark.LEAD_STEP), #line - minPoints + 1)
        if not tried[k] then
            tried[k] = true
            local p, n = line[k], line[k + 1]
            local l = math.max(MathUtil.vector2Length(n.x - p.x, n.z - p.z), 0.01)
            local target = {x = p.x, y = p.y, z = p.z, dirX = (n.x - p.x) / l, dirZ = (n.z - p.z) / l}
            local path = ADFieldPark.findDubins(vehicle, target, true, start)
            if path ~= nil then
                for i = k + 1, #line do
                    table.insert(path, {x = line[i].x, y = line[i].y, z = line[i].z})
                end
                vehicle.ad.trafficYieldModule:log("field park: way along the border, joined %d m ahead, %d points", ahead, #path)
                return path
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse : un trajet existe-t-il depuis l'entrée ? (11/11, champ 56)
-- ------------------------------------------------------------------------------------------------------------
-- 11/11 (champ 56 : la benne est allée au point du champ, aucun trajet propre vers les places trouvées, la culture du
-- coin juste devant le nez ; elle a attendu là, en plein sur la fourrière de la moissonneuse) : avant d'aller à
-- l'entrée, la benne vérifie depuis le chemin qu'un trajet propre part de l'entrée (start = {x, z, dx, dz}, la pose
-- au point du champ) vers une des places : trajet mémorisé, le long du bord, courbe directe, ou petit recul puis le
-- long du bord ; le pathfinder d'AutoDrive seulement où la bande coupée est large (comme à l'entrée).
-- Rend l'index de la place et la façon, nil quand aucune.
function ADFieldPark.findWayFromEntrance(vehicle, spots, start)
    for i = 1, math.min(#spots, ADFieldPark.MAX_TRIES) do
        local spot = spots[i]
        if not spot.roadside then
            local memo = spot.memo
            if memo ~= nil and memo.path ~= nil and memo.start ~= nil and memo.target ~= nil
                and MathUtil.vector2Length(start.x - memo.start.x, start.z - memo.start.z) <= ADFieldPark.MEMO_START_DISTANCE
                and start.dx * memo.start.dx + start.dz * memo.start.dz >= math.cos(math.rad(ADFieldPark.MEMO_START_ANGLE))
                and MathUtil.vector2Length(spot.x - memo.target.x, spot.z - memo.target.z) <= 1 then
                return i, "remembered"
            end
            if ADFieldPark.findApproach(vehicle, spot, start) ~= nil then
                return i, "along the border"
            end
            local target = ADFieldPark.getLeadIn(vehicle, spot)
            if ADFieldPark.findDirectPath(vehicle, target, start) ~= nil then
                return i, "direct"
            end
            for _, d in ipairs(ADFieldPark.TURN_BACK_OFF) do
                if ADFieldPark.findApproach(vehicle, spot, {x = start.x - start.dx * d, z = start.z - start.dz * d, dx = start.dx, dz = start.dz}) ~= nil then
                    return i, string.format("backing off %d m, then along the border", d)
                end
            end
            if ADFieldPark.getCutWidth(spot, ADFieldPark.NARROW_STRIP) >= ADFieldPark.NARROW_STRIP then
                return i, "pathfinder (wide cut strip)"
            end
        end
    end
    return nil
end

-- the turn into the cut strip is too wide from where the unloader stands (its nose is already in the field): m to
-- back off straight so that the way along the border fits; nil when backing off does not help, or something stands
-- behind the train
function ADFieldPark.findTurnBackOff(vehicle, spot)
    local x, y, z = ADTrafficYieldModule.getPosition(vehicle)
    local dx, dz = ADTrafficYieldModule.getDirection(vehicle)
    local _, rear = ADTrafficYieldModule.getTrainExtents(vehicle)
    local halfW = ADTrafficYieldModule.getWidth(vehicle) / 2 + 0.3
    for _, d in ipairs(ADFieldPark.TURN_BACK_OFF) do
        local bx, bz = x - dx * (rear + d / 2), z - dz * (rear + d / 2)
        if vehicle.ad.trafficYieldModule:overlapHit(bx, (y or 0) + 1.9, bz, math.atan2(dx, dz), halfW, 1.3, d / 2) then
            return nil
        end
        if ADFieldPark.findApproach(vehicle, spot, {x = x - dx * d, z = z - dz * d, dx = dx, dz = dz}) ~= nil then
            return d
        end
    end
    return nil
end

-- cut field ground beside a place, from its centre line into the field (the narrowest of rear, middle and nose), in m
-- up to maxWidth: how wide the strip cut by the combine is there
function ADFieldPark.getCutWidth(spot, maxWidth)
    local best = 0
    for _, side in ipairs({1, -1}) do
        -- GIANTS local +x (left) of the heading is (dz, -dx)
        local nx, nz = spot.dirZ * side, -spot.dirX * side
        local width = math.huge
        for _, f in ipairs({-1, 0, 1}) do
            local px, pz = spot.cx + spot.dirX * spot.halfL * f, spot.cz + spot.dirZ * spot.halfL * f
            local w, entered = 0, false
            for o = 0.5, maxWidth, 0.5 do
                local x, z = px + nx * o, pz + nz * o
                if AutoDrive.checkIsOnField(x, 0, z) then
                    entered = true
                    if ADFieldPark.hasGrowingCrop(x, z) and not ADFieldPark.isBorderFringe(x, z) then
                        break
                    end
                    w = o
                elseif entered or o > 4 then
                    -- off the field again, or the grass side of the place
                    break
                end
            end
            width = math.min(width, w)
        end
        best = math.max(best, width)
    end
    return best
end

function ADFieldPark.isPathClear(vehicle, path, halfW, fieldRule, anyGrass)
    local islandCache = {}
    -- combine: the uncut headland along the edge is not a fringe (see isBorderFringe)
    ADFieldPark.cutOnly = ADFieldPark.isCombineJob(vehicle)
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
