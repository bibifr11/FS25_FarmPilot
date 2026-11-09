-- ============================================================================================================
-- FarmPilot : FieldParkModule.lua
-- Places au champ des bennes qui attendent l'appel d'une machine (ADFieldPark). Moissonneuse et ensileuse ; les
-- parties marquées (ensileuse) ne servent qu'aux bennes d'ensileuse (benne qui roule à côté d'elle).
--
-- Évolution séparée (2e pull request, après celle du croisement de face) : une benne qui attend l'appel d'une
-- machine (CombineUnloaderMode -> WaitForCallTask) se gare dans le champ, le long de la bordure, sur un sol sans
-- culture debout et loin des routes, au lieu de bloquer la route à l'entrée du champ.
-- Dépend d'ADTrafficYieldModule (1re pull request) pour les outils partagés : dimensions de l'attelage
-- (measureTrain, getWidth, getTrainExtents) et le test exact d'obstacle (overlapHit).
--
-- Règles (dates des commentaires) :
-- - la place est le long du bord, à cheval sur la bordure (moitié sur l'herbe), parallèle au bord, le nez dans le
--   sens où la machine fait sa 1re fourrière (sens mesuré une fois, ou lu dans la course Courseplay, gardé pour tout
--   le champ), du côté où elle est partie à l'entrée ; sens inconnu et rien de mémorisé : attente au bord de la
--   route, pas de place au hasard ;
-- - la 1re place trouvée dans un champ est mémorisée avec son chemin (savegame AutoDrive_fieldPark.xml) : les bennes
--   suivantes y vont directement ; la fin du chemin suit le bord du champ ;
-- - 25/10 : file derrière une benne garée, sur la même bande ; place au-delà d'une benne garée refusée ; la benne qui
--   entre cède le passage à la benne pleine qui sort par la même entrée ; dernier passage des deux côtés, plus loin et
--   plus près de l'entrée (19:06) ;
-- - 26/10 : place avec du dégagement devant le nez (RUN_OUT) ; une benne pleine coincée dans le champ ne prend pas
--   de place ;
-- - 27/10 : les places dans le mauvais sens ne comptent pas, les passes suivantes sont faites ; (ensileuse) seule la
--   bande étroite le long du bord est coupée : file dans cette bande sans place pour doubler ;
-- - FIELD_CAPACITY bennes au champ par machine, les suivantes attendent au bord de la route.
--
-- Ce fichier : la table, l'état partagé, les réglages communs, les contrôles du sol et de l'emprise de l'attelage
-- garé, le bord du champ, les places prises, et « déjà bien garé ? ». Le reste, par sujet, dans des fichiers chargés
-- juste après celui-ci (register.lua) :
--   FieldParkModuleHarvester.lua  sens de marche de la machine et de sa 1re fourrière
--   FieldParkModuleMemo.lua       place mémorisée de chaque champ (sauvegarde)
--   FieldParkModuleSearch.lua     recherche des places le long du bord (parties ensileuse marquées)
--   FieldParkModulePath.lua       chemin jusqu'à la place : fin le long du bord, courbe directe, contrôle
--   FieldParkModuleEntrance.lua   entrée du champ : champ complet (bord de la route), sortie d'une benne pleine
--
-- Branché par : WaitForCallTaskFieldPark.lua et DriveToVehicleTaskFieldPark.lua (se garer au champ),
-- WaitForCallTaskRoadside.lua et DriveToDestinationTaskFieldEntrance.lua (champ complet, attente à l'entrée),
-- CatchCombinePipeTask:update (holdForExit), ExitFieldTaskExitPoints.lua (setFieldExit, isExitPointTaken),
-- ADHarvestManager:update (trackHarvester), PathFinderModulePark.lua et CombineUnloaderModeTracks.lua (getPassWidth,
-- isInHarvesterWay). Réglage général « fieldParkWhileWaiting » (isEnabled).
-- ============================================================================================================

ADFieldPark = {}

-- ------------------------------------------------------------------------------------------------------------
-- État partagé (une seule table pour tous les fichiers FieldParkModule*)
-- ------------------------------------------------------------------------------------------------------------
ADFieldPark.parked = {}                             -- vehicle -> spot where it is parked, waiting for a call
ADFieldPark.harvesterMotion = {}                    -- harvester -> {x, z, t, dx, dz, tDir, sense...}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages communs
-- ------------------------------------------------------------------------------------------------------------
ADFieldPark.ROAD_CLEARANCE = 4                      -- m between the parked train and any AutoDrive waypoint
ADFieldPark.HARVESTER_RANGE = 400                   -- m around the unloader where its harvester is looked for
ADFieldPark.PLANNING_TIMEOUT = 20000                -- ms given to the pathfinder search for one spot
ADFieldPark.SMOOTHING_TIMEOUT = 20000               -- ms more for the smoothing once the path is found
ADFieldPark.RETRY_DELAY = 30000                     -- ms before looking again when no spot could be reached
ADFieldPark.FIELD_MARGIN = 0.5                      -- m kept between the footprint (already 0.5 m wider than the train) and the field border
ADFieldPark.BORDER_SEARCH = 25                      -- m looked at around a ring position to find the field border
ADFieldPark.BORDER_RAY_STEP = 15                    -- degrees between two rays cast to find the border
ADFieldPark.BORDER_BASE = 12                        -- m between the two border points that give its direction
ADFieldPark.HARVESTER_CLEARANCE = 20                -- m kept between the parked train and the standing crop: room for the harvester to turn on the headland
ADFieldPark.CLEARANCE_STEP = 4                      -- m between two crop samples around the train
ADFieldPark.PARALLEL_TOLERANCE_PARKED = 10       -- degrees, a train found parked (loaded savegame) within this angle of the border counts as parallel: the border curves a little along it
--[==[ Mis de côté (09/11) : inutilisé
ADFieldPark.PARALLEL_TOLERANCE = 5                  -- degrees, a parked train within this angle of the border counts as parallel
]==]
ADFieldPark.BORDER_GAPS = {-0.5, 0, 0.5, 1, 1.5, 2, 3, 4} -- m tried between the footprint (0.5 m wider than the train) and the border: as close to the grass as possible
--[==[ Mis de côté (09/11) : inutilisé
ADFieldPark.GRASS_MARGIN = 1.1                      -- m: the margin around the parked train may lie on the grass this close to the field
]==]
ADFieldPark.ISLAND_MAX_AREA = 10                    -- m2: a crop patch this small, forgotten by the harvester, may be driven over
ADFieldPark.ISLAND_STEP = 0.5                       -- m between two samples of a crop patch
ADFieldPark.FRINGE = 3                              -- m: crop left by the harvester along the field edge, may be driven over
--[==[ Mis de côté (09/11) : inutilisé
ADFieldPark.STRADDLE_GAPS = {0.5, 1, 1.5, 2, 3, 4, 0, -1, -2, -3} -- second pass: astride the border, half on the grass
]==]
ADFieldPark.SAMPLE_STEP = 2                         -- m between two ground samples
ADFieldPark.QUEUE_GAP = 3                           -- m between two unloaders parked one behind the other
ADFieldPark.MAX_TRIES = 3                           -- spots tried in turn when no clean path leads to the previous one
ADFieldPark.ROADSIDE_RANGE = 100                    -- m from the entrance where a roadside place is looked for
ADFieldPark.ROAD_HALF_WIDTH = 2.5                   -- m between an AutoDrive road line and a train parked beside it
ADFieldPark.RUN_OUT = 15                            -- m of free ground needed ahead of the nose to drive away again
ADFieldPark.RUN_OUT_STEP = 2.5

-- ------------------------------------------------------------------------------------------------------------
-- Réglage du jeu
-- ------------------------------------------------------------------------------------------------------------
function ADFieldPark.isEnabled()
    local value = AutoDrive.getSetting("fieldParkWhileWaiting")
    return value == true or value == 1
end

-- ------------------------------------------------------------------------------------------------------------
-- Sol : culture debout, petite plaque oubliée, bande laissée au bord, champ de la machine
-- ------------------------------------------------------------------------------------------------------------
-- growing crop at a world position (cut, withered, grass and meadow do not count)
function ADFieldPark.hasGrowingCrop(x, z)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then
        return false
    end
    local fruitTypeIndex, growthState = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)
    if fruitTypeIndex == nil or fruitTypeIndex == 0 or growthState == nil then
        return false
    end
    if fruitTypeIndex == FruitType.MEADOW or fruitTypeIndex == FruitType.GRASS then
        return false
    end
    local fruit = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruit == nil then
        return false
    end
    return not (fruit:getIsCut(growthState) or fruit:getIsWithered(growthState)), fruitTypeIndex
end

-- crop strip the harvester left along the field edge (its header does not reach the edge): off field within
-- ADFieldPark.FRINGE in some direction
function ADFieldPark.isBorderFringe(x, z)
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
    for _, d in ipairs({1, 2, ADFieldPark.FRINGE}) do
        for i = 0, 7 do
            local a = i * math.pi / 4
            if not AutoDrive.checkIsOnField(x + math.sin(a) * d, y, z + math.cos(a) * d) then
                return true
            end
        end
    end
    return false
end

-- field ground within distance of (x, z)
function ADFieldPark.isNearField(x, z, distance)
    -- 16 directions: a border seen at an angle is found within 2 % of the distance
    for _, d in ipairs({distance / 2, distance}) do
        for i = 0, 15 do
            local a = i * math.pi / 8
            if AutoDrive.checkIsOnField(x + math.sin(a) * d, 0, z + math.cos(a) * d) then
                return true
            end
        end
    end
    return false
end

-- crop patch of at most ADFieldPark.ISLAND_MAX_AREA, forgotten by the harvester: its connected crop ground is
-- filled on a grid of ADFieldPark.ISLAND_STEP, stopped as soon as it is bigger
function ADFieldPark.isCropIsland(fruitTypeIndex, x, z, cache)
    local step = ADFieldPark.ISLAND_STEP
    local maxCells = ADFieldPark.ISLAND_MAX_AREA / (step * step)
    local i0, j0 = math.floor(x / step + 0.5), math.floor(z / step + 0.5)
    local key0 = i0 .. "_" .. j0
    if cache[key0] ~= nil then
        return cache[key0]
    end
    local seen, queue, head = {[key0] = true}, {{i0, j0}}, 1
    local count = 0
    while head <= #queue do
        local c = queue[head]
        head = head + 1
        count = count + 1
        if count > maxCells then
            break
        end
        for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
            local i, j = c[1] + d[1], c[2] + d[2]
            local key = i .. "_" .. j
            if not seen[key] then
                seen[key] = true
                if ADFieldPark.hasGrowingCrop(i * step, j * step) then
                    table.insert(queue, {i, j})
                end
            end
        end
    end
    local island = count <= maxCells
    -- every crop sample reached belongs to the same patch
    for k = 1, #queue do
        cache[queue[k][1] .. "_" .. queue[k][2]] = island
    end
    return island
end

-- field ground of the harvester: the ground connected to it, as the AutoDrive pathfinder sees it, so that a
-- neighbouring field (another number, behind a hedge or a grass strip) never counts as this field
function ADFieldPark.getHarvesterArea(hx, hz)
    if PathFinderModule ~= nil and PathFinderModule.getConnectedFieldArea ~= nil and PathFinderModule.isInFieldArea ~= nil then
        return PathFinderModule.getConnectedFieldArea(hx, hz)
    end
    return nil
end

-- on the field of the harvester being looked at (ADFieldPark.area), or on any field when it is not known
function ADFieldPark.isOnField(x, y, z)
    if not AutoDrive.checkIsOnField(x, y, z) then
        return false
    end
    local area = ADFieldPark.area
    return area == nil or area.capped or PathFinderModule.isInFieldArea(area, x, z)
end

-- AutoDrive waypoints around a position (computed once per search)
function ADFieldPark.getWayPointsAround(x, z, radius)
    local result = {}
    local wayPoints = ADGraphManager:getWayPoints()
    if wayPoints == nil then
        return result
    end
    for _, wp in pairs(wayPoints) do
        if math.abs(wp.x - x) < radius and math.abs(wp.z - z) < radius then
            table.insert(result, wp)
        end
    end
    return result
end

-- ------------------------------------------------------------------------------------------------------------
-- Emprise de l'attelage garé : sur le champ, sans culture, à plat, loin des routes, dégagement devant
-- ------------------------------------------------------------------------------------------------------------
-- distance from (px, pz) to the footprint rectangle centred at (cx, cz) heading (dx, dz)
function ADFieldPark.distanceToFootprint(px, pz, cx, cz, dx, dz, halfW, halfL)
    local along = (px - cx) * dx + (pz - cz) * dz
    local side = (px - cx) * dz - (pz - cz) * dx
    local outAlong = math.max(math.abs(along) - halfL, 0)
    local outSide = math.max(math.abs(side) - halfW, 0)
    return math.sqrt(outAlong * outAlong + outSide * outSide)
end

-- points every ADFieldPark.SAMPLE_STEP on the outline of a footprint, plus its centre line
function ADFieldPark.getOutline(cx, cz, dx, dz, halfW, halfL)
    local points = {}
    local function add(across, along)
        -- GIANTS local +x (left) of the heading is (dz, -dx)
        table.insert(points, {cx + dz * across + dx * along, cz - dx * across + dz * along})
    end
    local n = math.max(1, math.ceil(2 * halfL / ADFieldPark.SAMPLE_STEP))
    for i = 0, n do
        local along = -halfL + 2 * halfL * i / n
        add(-halfW, along)
        add(0, along)
        add(halfW, along)
    end
    local m = math.max(1, math.ceil(2 * halfW / ADFieldPark.SAMPLE_STEP))
    for i = 1, m - 1 do
        local across = -halfW + 2 * halfW * i / m
        add(across, -halfL)
        add(across, halfL)
    end
    return points
end

-- standing crop within ADFieldPark.HARVESTER_CLEARANCE around the footprint: the harvester still works there and
-- turns on the harvested ground next to it. Small forgotten patches do not count
function ADFieldPark.hasCropNearby(cx, cz, dx, dz, halfW, halfL)
    if ADFieldPark.relaxed then
        -- second pass: no place away from the crop, the harvested headland strip is better than the road
        return false
    end
    local clearance, step = ADFieldPark.HARVESTER_CLEARANCE, ADFieldPark.CLEARANCE_STEP
    local cache = {}
    for along = -(halfL + clearance), halfL + clearance, step do
        for across = -(halfW + clearance), halfW + clearance, step do
            -- GIANTS local +x (left) of the heading is (dz, -dx)
            local x, z = cx + dz * across + dx * along, cz - dx * across + dz * along
            local crop, fruitTypeIndex = ADFieldPark.hasGrowingCrop(x, z)
            if crop and not ADFieldPark.isCropIsland(fruitTypeIndex, x, z, cache) then
                return true
            end
        end
    end
    return false
end

-- ground under the footprint of the train centred at (cx, cz) heading (dx, dz): on the field, no crop, flat,
-- away from the roads. Returns the highest terrain height, or nil when the ground does not fit
function ADFieldPark.isGroundFree(cx, cz, dx, dz, halfW, halfL, nearbyWayPoints, py)
    local minH, maxH = math.huge, -math.huge
    -- the whole outline on the field with a margin, on harvested ground (no crop of any kind)
    local margin = ADFieldPark.FIELD_MARGIN
    for _, p in ipairs(ADFieldPark.getOutline(cx, cz, dx, dz, halfW + margin, halfL + margin)) do
        local h = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p[1], py, p[2])
        minH, maxH = math.min(minH, h), math.max(maxH, h)
        local onField = ADFieldPark.isOnField(p[1], h, p[2])
        -- second pass: the grass along the border is fine too, never another field
        -- and the margin of a train parked right against the grass
        local onGrass = not onField and not AutoDrive.checkIsOnField(p[1], h, p[2])
            and (ADFieldPark.relaxed or ADFieldPark.isNearField(p[1], p[2], halfW + margin + 0.2))
        if not onField and not onGrass then
            ADFieldPark.reject = AutoDrive.checkIsOnField(p[1], h, p[2]) and "other field" or "off field"
            return nil
        end
        local crop, fruitTypeIndex = ADFieldPark.hasGrowingCrop(p[1], p[2])
        if crop and not ADFieldPark.isCropIsland(fruitTypeIndex, p[1], p[2], {}) and not (ADFieldPark.relaxed and ADFieldPark.isBorderFringe(p[1], p[2])) then
            ADFieldPark.reject = "crop"
            return nil
        end
    end
    if maxH - minH > ADTrafficYieldModule.MAX_SLOPE_DIFF then
        ADFieldPark.reject = "slope"
        return nil
    end
    -- the whole train, trailers included, away from the road network
    for _, wp in ipairs(nearbyWayPoints) do
        if ADFieldPark.distanceToFootprint(wp.x, wp.z, cx, cz, dx, dz, halfW, halfL) < ADFieldPark.ROAD_CLEARANCE then
            ADFieldPark.reject = "road"
            return nil
        end
    end
    if ADFieldPark.hasCropNearby(cx, cz, dx, dz, halfW, halfL) then
        ADFieldPark.reject = "crop within 20 m"
        return nil
    end
    if not ADFieldPark.hasRunOut(cx, cz, dx, dz, halfW, halfL, py) then
        ADFieldPark.reject = "no run-out"
        return nil
    end
    return maxH
end

-- the train must be able to leave its place straight ahead (26/10: the 942 parked with its nose in the corner
-- of the field, against the border): the ground ahead of the nose, over the width of the train, is field or the grass
-- along the border, with no standing crop
function ADFieldPark.hasRunOut(cx, cz, dx, dz, halfW, halfL, py)
    local nx, nz = cx + dx * halfL, cz + dz * halfL
    local d = ADFieldPark.RUN_OUT_STEP
    while d <= ADFieldPark.RUN_OUT do
        for _, side in ipairs({0, -1, 1}) do
            -- GIANTS local +x (left) of the heading is (dz, -dx)
            local x, z = nx + dx * d + dz * side * halfW, nz + dz * d - dx * side * halfW
            local h = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, py, z)
            local onField = ADFieldPark.isOnField(x, h, z)
            local onGrass = not onField and not AutoDrive.checkIsOnField(x, h, z) and ADFieldPark.isNearField(x, z, halfW + 1)
            if not onField and not onGrass then
                return false
            end
            local crop, fruitTypeIndex = ADFieldPark.hasGrowingCrop(x, z)
            if crop and not ADFieldPark.isCropIsland(fruitTypeIndex, x, z, {}) and not ADFieldPark.isBorderFringe(x, z) then
                return false
            end
        end
        d = d + ADFieldPark.RUN_OUT_STEP
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Bord du champ (point, direction, normale vers l'extérieur)
-- ------------------------------------------------------------------------------------------------------------
-- distance from (x, z) to the field border along (nx, nz), nil when the border is farther than maxDistance
function ADFieldPark.castToBorder(x, z, nx, nz, maxDistance, py)
    for d = 0.5, maxDistance, 0.5 do
        if not ADFieldPark.isOnField(x + nx * d, py, z + nz * d) then
            -- narrowed down to a few centimeters, the direction of the border depends on it
            local inside, outside = d - 0.5, d
            for _ = 1, 4 do
                local mid = (inside + outside) / 2
                if ADFieldPark.isOnField(x + nx * mid, py, z + nz * mid) then
                    inside = mid
                else
                    outside = mid
                end
            end
            return (inside + outside) / 2
        end
    end
    return nil
end

-- border of the field near (cx, cz): a point on it, its direction (tx, tz) and the normal (nx, nz) pointing out
-- of the field, measured on the ground so that the train can be parked exactly parallel to it
function ADFieldPark.findBorder(cx, cz, py)
    local best, nx, nz = nil, 0, 0
    for a = 0, 345, ADFieldPark.BORDER_RAY_STEP do
        local rx, rz = math.sin(math.rad(a)), math.cos(math.rad(a))
        local d = ADFieldPark.castToBorder(cx, cz, rx, rz, ADFieldPark.BORDER_SEARCH, py)
        if d ~= nil and (best == nil or d < best) then
            best, nx, nz = d, rx, rz
        end
    end
    if best == nil then
        return nil
    end
    -- two points of the border, on each side, give its direction; done twice to settle on the real normal
    local half = ADFieldPark.BORDER_BASE / 2
    local px, pz, tx, tz
    for _ = 1, 2 do
        tx, tz = nz, -nx
        local d1 = ADFieldPark.castToBorder(cx + tx * half, cz + tz * half, nx, nz, ADFieldPark.BORDER_SEARCH * 2, py)
        local d2 = ADFieldPark.castToBorder(cx - tx * half, cz - tz * half, nx, nz, ADFieldPark.BORDER_SEARCH * 2, py)
        if d1 == nil or d2 == nil then
            return nil
        end
        local x1, z1 = cx + tx * half + nx * d1, cz + tz * half + nz * d1
        local x2, z2 = cx - tx * half + nx * d2, cz - tz * half + nz * d2
        local length = MathUtil.vector2Length(x1 - x2, z1 - z2)
        if length < 0.1 then
            return nil
        end
        tx, tz = (x1 - x2) / length, (z1 - z2) / length
        -- normal pointing out of the field (same side as the first ray)
        local mx, mz = -tz, tx
        if mx * nx + mz * nz < 0 then
            mx, mz = -mx, -mz
        end
        nx, nz = mx, mz
        px, pz = (x1 + x2) / 2, (z1 + z2) / 2
    end
    return px, pz, tx, tz, nx, nz
end

-- ------------------------------------------------------------------------------------------------------------
-- Machine de la benne et places prises par les autres bennes
-- ------------------------------------------------------------------------------------------------------------
-- harvester the unloader works with: same field marker first, otherwise the closest registered harvester
-- (driven by a helper or another mod), within ADFieldPark.HARVESTER_RANGE
function ADFieldPark.findHarvester(vehicle, x, z)
    local best, bestDistance = nil, ADFieldPark.HARVESTER_RANGE
    local marker = vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:getFirstMarker() or nil
    for _, list in ipairs({ADHarvestManager.harvesters or {}, ADHarvestManager.idleHarvesters or {}}) do
        for _, harvester in pairs(list) do
            if harvester.components ~= nil then
                local hx, _, hz = getWorldTranslation(harvester.components[1].node)
                local distance = MathUtil.vector2Length(hx - x, hz - z)
                local sameMarker = marker ~= nil and harvester.ad ~= nil and harvester.ad.stateModule ~= nil
                    and harvester.ad.stateModule:getFirstMarker() == marker
                if sameMarker then
                    distance = 0
                end
                if distance < bestDistance or (best == nil and distance <= bestDistance) then
                    best, bestDistance = harvester, distance
                end
            end
        end
    end
    return best
end

-- an unloader reached its spot / left it. reserved: on its way there, the spot is already taken for the others
function ADFieldPark.setParked(vehicle, spot, reserved)
    if spot ~= nil then
        spot.reserved = reserved == true
    end
    ADFieldPark.parked[vehicle] = spot
end

-- the footprint overlaps the spot of another unloader, parked there or on its way to it
function ADFieldPark.overlapsTakenSpot(search, cx, cz, dx, dz)
    for other, spot in pairs(ADFieldPark.parked) do
        if other ~= search.vehicle and spot ~= nil and spot.cx ~= nil then
            local ox, oz = cx - spot.cx, cz - spot.cz
            local along = math.abs(ox * dx + oz * dz)
            local across = math.abs(ox * dz - oz * dx)
            if along < search.halfL + (spot.halfL or search.halfL) + ADFieldPark.QUEUE_GAP - 0.5 and across < search.halfW * 2 + 0.5 then
                return true
            end
        end
    end
    return false
end

-- unloaders parked in the field (or driving to their spot there) for this harvester, the vehicle itself excluded
function ADFieldPark.countInField(vehicle, harvester)
    local count = 0
    for other, spot in pairs(ADFieldPark.parked) do
        -- a full unloader stuck in the field (no clean way out, ExitFieldTask) does not take a place: the next one may
        -- come in so that the harvester goes on and opens the way (26/10 14:43)
        if other ~= vehicle and spot ~= nil and not spot.roadside and other.isDeleted ~= true
            and (spot.harvester == nil or spot.harvester == harvester)
            and not (other.ad ~= nil and other.ad.exitStuckFull ~= nil) then
            count = count + 1
        end
    end
    return count
end

-- ------------------------------------------------------------------------------------------------------------
-- Déjà bien garé ? (place gardée après un chargement de partie)
-- ------------------------------------------------------------------------------------------------------------
-- true when the current position is already a good waiting place: on harvested ground along the border, away from
-- the road network. Same rules as a spot of the second pass (crop beyond the train allowed), so that a train parked
-- there by the field park, then saved and loaded again, stays where it is. Returns true and the spot (footprint), or
-- false and the reason
function ADFieldPark.isGoodWaitingPlace(vehicle)
    local x, py, z = ADTrafficYieldModule.getPosition(vehicle)
    ADFieldPark.area = nil
    local harvester = ADFieldPark.findHarvester(vehicle, x, z)
    if harvester ~= nil then
        local hx, _, hz = getWorldTranslation(harvester.components[1].node)
        ADFieldPark.area = ADFieldPark.getHarvesterArea(hx, hz)
    end
    local dx, dz = ADTrafficYieldModule.getDirection(vehicle)
    local front, rear = ADTrafficYieldModule.getTrainExtents(vehicle)
    local length = front + rear
    -- centre of the whole train
    local cx, cz = x + dx * (front - length / 2), z + dz * (front - length / 2)
    local halfW = ADTrafficYieldModule.getWidth(vehicle) / 2 + 0.5
    local halfL = length / 2 + 0.5
    local nearby = ADFieldPark.getWayPointsAround(x, z, 60)
    for _, wp in ipairs(nearby) do
        if ADFieldPark.distanceToFootprint(wp.x, wp.z, cx, cz, dx, dz, halfW, halfL) < ADFieldPark.ROAD_CLEARANCE then
            return false, "road"
        end
    end
    for _, p in ipairs(ADFieldPark.getOutline(cx, cz, dx, dz, halfW, halfL)) do
        if not ADFieldPark.isOnField(p[1], py, p[2]) and AutoDrive.checkIsOnField(p[1], py, p[2]) then
            return false, "other field"
        end
        if not ADFieldPark.isOnField(p[1], py, p[2]) and not ADFieldPark.isNearField(p[1], p[2], halfW + 0.7) then
            return false, "off field"
        end
        local crop, fruitTypeIndex = ADFieldPark.hasGrowingCrop(p[1], p[2])
        if crop and not ADFieldPark.isCropIsland(fruitTypeIndex, p[1], p[2], {}) and not ADFieldPark.isBorderFringe(p[1], p[2]) then
            return false, "crop"
        end
    end
    if not ADFieldPark.hasRunOut(cx, cz, dx, dz, halfW, halfL, py) then
        return false, "no run-out"
    end
    -- and parked parallel to the border, close to it
    local bx, bz, tx, tz, nx, nz = ADFieldPark.findBorder(cx, cz, py)
    if bx == nil then
        return false, "no border"
    end
    if math.abs(dx * tx + dz * tz) < math.cos(math.rad(ADFieldPark.PARALLEL_TOLERANCE_PARKED)) then
        return false, string.format("not parallel to the border (%.0f�)", math.deg(math.acos(math.min(1, math.abs(dx * tx + dz * tz)))))
    end
    if (bx - cx) * nx + (bz - cz) * nz - halfW >= ADFieldPark.BORDER_GAPS[#ADFieldPark.BORDER_GAPS] + 0.5 then
        return false, "too far from the border"
    end
    return true, {x = x, y = py, z = z, dirX = dx, dirZ = dz, cx = cx, cz = cz, halfL = halfL, harvester = harvester}
end
