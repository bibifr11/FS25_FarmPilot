-- ============================================================================================================
-- FarmPilot : PathFinderModuleCropMap.lua
-- Complément de PathFinderModule : la carte des cultures, gardée en mémoire et partagée par tous les véhicules.
-- Cases de 2 m (4 relevés à 1 m) lues une fois dans la carte de densité du jeu puis gardées (relues au bout de
-- 30 min) ; autour d'une moissonneuse au travail, oubliées chaque seconde et relues au besoin. Dans la bordure d'un
-- champ relevé (PathFinderModuleFieldScan.lua), chaque case est relue tous les 0,5 m (16 relevés).
--
-- Historique :
-- - 23/10 : les passages de roues dans la culture ressemblaient à un chemin en relevés de 2 m (bordure relue à
--   0,5 m, plus large que tout champ = tout le champ).
-- - 24/10 13:34, îlots ignorés même en poursuite : plants isolés et bandes étroites restées debout
--   oubliés ; deux bandes à 2-3 m l'une de l'autre étaient vues comme un bloc (1 m dégagé à côté d'une bande
--   suffit) ; 13:41 : épaisseur de la bande mesurée en travers.
-- - 25/10 19:14 : le 7R a contourné la haie par la bande d'herbe derrière (sol de
--   champ pour le jeu, sans culture) : pendant que l'ensileuse récolte, l'herbe, la prairie ou un autre numéro de
--   champ ne sont pas son champ.
--
-- Règle : culture coupée ou fanée, herbe et prairie comptent comme « pas de culture ».
--
-- Branché par PathFinderModule.lua (startPathPlanningToPipe : setHarvestField ; cases de la grille :
-- getMapOnFieldAt ; lissage : getMapCropRatio, getCropFilter) et AutoDrive.lua (refreshFieldMap à chaque image).
-- Lu aussi par les tâches et modules de l'ensileuse (getMapCropAt, getMapOnFieldAt, readCropAt, isIsolatedCrop).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages et mémoire de la carte
-- ------------------------------------------------------------------------------------------------------------
-- field map: standing crop kept in memory in 2 m cells (4 samples each, 1 m apart), shared by all vehicles.
-- A cell is read once from the density map, then kept; around a working harvester the cells are forgotten
-- every second and read again when needed. Every cell is read again after MAP_TTL anyway.
PathFinderModule.MAP_CELL = 2
PathFinderModule.MAP_TTL = 1800000
PathFinderModule.MAP_REFRESH_INTERVAL = 1000
PathFinderModule.MAP_HARVESTER_MARGIN = 8
PathFinderModule.MAP_SAMPLE_OFFSETS = {{-0.5, -0.5}, {0.5, -0.5}, {-0.5, 0.5}, {0.5, 0.5}}
PathFinderModule.fieldMap = {}
PathFinderModule.fieldMapCount = 0
PathFinderModule.fieldMapReads = 0
PathFinderModule.fieldMapRefreshTime = -math.huge
-- the 2 m cells of a recorded field are read again every 0.5 m (16 samples): FINE_BAND_WIDTH from the outer
-- border toward the middle, wider than any field = the whole field (23/10: wheel lanes through the crop
-- looked like a way in 2 m samples). The scan reads them after the field, spread over the frames as well
PathFinderModule.FINE_BAND_WIDTH = 2000
PathFinderModule.FINE_STEP = 0.5
PathFinderModule.fineBand = {}       -- key of a 2 m cell -> true when it lies in the band (set by the field scan)
PathFinderModule.fineReads = 0

-- ------------------------------------------------------------------------------------------------------------
-- Lecture d'une case
-- ------------------------------------------------------------------------------------------------------------
-- standing crop at one position: fruit type index, 0 if none (cut, withered, grass and meadow count as none)
function PathFinderModule.readCropAt(x, z)
    local fruitTypeIndex, growthState = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)
    if fruitTypeIndex == nil or fruitTypeIndex == 0 or growthState == nil or growthState == 0 then
        return 0
    end
    if fruitTypeIndex == FruitType.MEADOW or fruitTypeIndex == FruitType.GRASS then
        -- second value (25/10 19:14): grass ground, not the field of a harvester working another crop
        return 0, true
    end
    local fruit = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruit == nil or fruit:getIsCut(growthState) or fruit:getIsWithered(growthState) then
        return 0
    end
    -- the stubble behind the harvester can still answer with the crop above: confirm with the same reading as
    -- the checks of this morning (fruit area of a 0.5 m square, cut or withered counts as none)
    if PathFinderModule.getFruitRatio(fruitTypeIndex, x - 0.25, z - 0.25, x + 0.25, z - 0.25, x - 0.25, z + 0.25) <= 0 then
        return 0
    end
    return fruitTypeIndex
end

function PathFinderModule.getMapCell(ix, iz)
    local key = (ix + 50000) * 100000 + (iz + 50000)
    local cell = PathFinderModule.fieldMap[key]
    local now = g_time or 0
    if cell ~= nil and now >= cell.t and now - cell.t < PathFinderModule.MAP_TTL then
        return cell
    end
    if cell == nil then
        PathFinderModule.fieldMapCount = PathFinderModule.fieldMapCount + 1
    end
    cell = {t = now, field = {}, grass = {}}
    local cx, cz = ix * PathFinderModule.MAP_CELL, iz * PathFinderModule.MAP_CELL
    for k, offset in ipairs(PathFinderModule.MAP_SAMPLE_OFFSETS) do
        local crop, grass = PathFinderModule.readCropAt(cx + offset[1], cz + offset[2])
        cell[k] = crop
        cell.grass[k] = grass == true
        cell.field[k] = AutoDrive.checkIsOnField(cx + offset[1], 0, cz + offset[2]) == true
        cell.onField = cell.onField or cell.field[k]
    end
    -- field number at the cell centre (25/10 19:14: the grass strip behind the hedge is field ground for the game)
    if cell.onField then
        cell.fieldId = PathFinderModule.getFieldIdAt(cx, cz)
    end
    if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        cell.y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 0, cz)
    end
    PathFinderModule.fieldMapReads = PathFinderModule.fieldMapReads + 1
    PathFinderModule.fieldMap[key] = cell
    return cell
end

-- the 16 samples (0.5 m apart) of a cell in the border band, read once per cell reading
function PathFinderModule.getFineCell(cell, ix, iz)
    if cell.fine ~= nil then
        return cell.fine
    end
    local size, step = PathFinderModule.MAP_CELL, PathFinderModule.FINE_STEP
    local n = math.floor(size / step + 0.5)
    local x0, z0 = ix * size - size / 2 + step / 2, iz * size - size / 2 + step / 2
    local fine = {crop = {}, field = {}, grass = {}, n = n}
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            local k = j * n + i + 1
            local x, z = x0 + i * step, z0 + j * step
            local crop, grass = PathFinderModule.readCropAt(x, z)
            fine.crop[k] = crop
            fine.grass[k] = grass == true
            fine.field[k] = AutoDrive.checkIsOnField(x, 0, z) == true
        end
    end
    PathFinderModule.fineReads = PathFinderModule.fineReads + 1
    cell.fine = fine
    return fine
end

-- index of the fine sample at a position, nil when the cell is not in the border band
function PathFinderModule.getFineIndex(ix, iz, x, z)
    if not PathFinderModule.fineBand[(ix + 50000) * 100000 + (iz + 50000)] then
        return nil
    end
    local size, step = PathFinderModule.MAP_CELL, PathFinderModule.FINE_STEP
    local n = math.floor(size / step + 0.5)
    local i = math.min(n - 1, math.max(0, math.floor((x - (ix * size - size / 2)) / step)))
    local j = math.min(n - 1, math.max(0, math.floor((z - (iz * size - size / 2)) / step)))
    return j * n + i + 1
end

-- ------------------------------------------------------------------------------------------------------------
-- Plants isolés et bandes étroites
-- ------------------------------------------------------------------------------------------------------------
-- isolated plants (forage harvester only, strict checks): a crop patch at most ISOLATED_PATCH_SIZE wide,
-- with no other crop within ISOLATED_CLEARANCE around it, is forgotten. A crop sample is isolated when no crop
-- is found in the ring between ISOLATED_PATCH_SIZE + 0.5 m and ISOLATED_PATCH_SIZE + ISOLATED_CLEARANCE around it
-- (sampled every 0.5 m): every point of a patch that small lies inside the ring, any standing crop edge or row
-- reaches into it. Results are kept ISOLATED_TTL ms (the harvester keeps cutting)
PathFinderModule.ISOLATED_PATCH_SIZE = 2
PathFinderModule.ISOLATED_CLEARANCE = 2.5
PathFinderModule.ISOLATED_STEP = 0.5
PathFinderModule.ISOLATED_TTL = 3000
PathFinderModule.ISOLATED_CACHE_MAX = 50000
PathFinderModule.isolatedCache = {}
PathFinderModule.isolatedCacheCount = 0
PathFinderModule.ignoreIsolatedCrop = false -- set while a forage harvester unloader searches or checks a route

function PathFinderModule.isIsolatedCrop(x, z)
    local step = PathFinderModule.ISOLATED_STEP
    local ix, iz = math.floor(x / step + 0.5), math.floor(z / step + 0.5)
    local key = (ix + 500000) * 1000000 + (iz + 500000)
    local now = g_time or 0
    local cached = PathFinderModule.isolatedCache[key]
    if cached ~= nil and now >= cached.t and now - cached.t < PathFinderModule.ISOLATED_TTL then
        return cached.v
    end
    if PathFinderModule.isolatedCacheCount > PathFinderModule.ISOLATED_CACHE_MAX then
        PathFinderModule.isolatedCache = {}
        PathFinderModule.isolatedCacheCount = 0
    end
    local cx, cz = ix * step, iz * step
    local inner = PathFinderModule.ISOLATED_PATCH_SIZE + step
    local outer = PathFinderModule.ISOLATED_PATCH_SIZE + PathFinderModule.ISOLATED_CLEARANCE
    local n = math.floor(outer / step + 0.5)
    local isolated = true
    for j = -n, n do
        local oz = j * step
        for i = -n, n do
            local ox = i * step
            if math.max(math.abs(ox), math.abs(oz)) >= inner - 0.01 and PathFinderModule.getMapCropRawAt(cx + ox, cz + oz) ~= 0 then
                isolated = false
                break
            end
        end
        if not isolated then
            break
        end
    end
    if not isolated then
        -- 24/10: a long narrow strip left standing (one or two rows) counts as isolated too
        isolated = PathFinderModule.isCropStrip(cx, cz)
    end
    if cached == nil then
        PathFinderModule.isolatedCacheCount = PathFinderModule.isolatedCacheCount + 1
    end
    PathFinderModule.isolatedCache[key] = {t = now, v = isolated}
    return isolated
end

-- narrow strip: in one of the directions across it, no crop between STRIP_HALF_WIDTH + 0.5 and
-- STRIP_HALF_WIDTH + ISOLATED_CLEARANCE on both sides, here and STRIP_ALONG, 2 x STRIP_ALONG m further each way along it
-- (a single gap in a crop block is not a strip)
PathFinderModule.STRIP_HALF_WIDTH = 1.5 -- m: strips up to about 3 m wide
PathFinderModule.STRIP_DIRECTIONS = 8
PathFinderModule.STRIP_ALONG = 1.5
-- 24/10 13:34: two leftover strips 2-3 m apart were seen as a crop block; 1 m clear beside a strip is enough
PathFinderModule.STRIP_CLEARANCE = 2.5 -- m clear on both sides (24/10: less and a field counts as a strip)
PathFinderModule.STRIP_MAX_WIDTH = 4 -- m of crop across a strip at most
function PathFinderModule.isCropStrip(cx, cz)
    -- 24/10 13:41: thickness across the strip measured (crop run until 1 m clear on each side), up to
    -- STRIP_MAX_WIDTH, here and along it: a strip 2-3 m wide seen from its edge was not one with the old rule
    local step = PathFinderModule.ISOLATED_STEP
    local maxWidth = PathFinderModule.STRIP_MAX_WIDTH
    local clearNeed = PathFinderModule.STRIP_CLEARANCE
    local along = PathFinderModule.STRIP_ALONG
    local function run(bx, bz, px, pz)
        -- distance of crop from (bx,bz) toward p before clearNeed m without crop, nil when wider than maxWidth
        local last, r, free = 0, step, 0
        while r <= maxWidth + clearNeed + 0.01 do
            if PathFinderModule.getMapCropRawAt(bx + px * r, bz + pz * r) ~= 0 then
                last, free = r, 0
            else
                free = free + step
                if free >= clearNeed - 0.01 then
                    return last
                end
            end
            r = r + step
        end
        return nil
    end
    for k = 0, PathFinderModule.STRIP_DIRECTIONS - 1 do
        local a = math.pi * k / PathFinderModule.STRIP_DIRECTIONS
        local dx, dz = math.sin(a), math.cos(a)
        local px, pz = dz, -dx
        local ok = true
        -- the same across line here and twice along each way: a field corner seen diagonally is no strip
        for _, l in ipairs({0, -along, along, -2 * along, 2 * along}) do
            local bx, bz = cx + dx * l, cz + dz * l
            local plus = run(bx, bz, px, pz)
            local minus = plus ~= nil and run(bx, bz, -px, -pz) or nil
            if plus == nil or minus == nil or plus + minus > maxWidth then
                ok = false
                break
            end
        end
        if ok then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Culture et sol de champ à une position
-- ------------------------------------------------------------------------------------------------------------
-- crop at a position from the map; isolated plants count as none while a forage harvester unloader checks
function PathFinderModule.getMapCropAt(x, z)
    local crop = PathFinderModule.getMapCropRawAt(x, z)
    if crop ~= 0 and PathFinderModule.ignoreIsolatedCrop and PathFinderModule.isIsolatedCrop(x, z) then
        return 0
    end
    return crop
end

-- crop at a position from the map (nearest of the 4 samples of its cell, 0.5 m sample in the border band)
function PathFinderModule.getMapCropRawAt(x, z)
    local size = PathFinderModule.MAP_CELL
    local ix, iz = math.floor(x / size + 0.5), math.floor(z / size + 0.5)
    local cell = PathFinderModule.getMapCell(ix, iz)
    local fk = PathFinderModule.getFineIndex(ix, iz, x, z)
    if fk ~= nil then
        return PathFinderModule.getFineCell(cell, ix, iz).crop[fk]
    end
    local k = 1
    if x >= ix * size then
        k = k + 1
    end
    if z >= iz * size then
        k = k + 2
    end
    return cell[k]
end

-- field ground at a position from the map (nearest of the 4 samples of its cell, 0.5 m sample in the border band)
function PathFinderModule.getMapOnFieldAt(x, z)
    local size = PathFinderModule.MAP_CELL
    local ix, iz = math.floor(x / size + 0.5), math.floor(z / size + 0.5)
    local cell = PathFinderModule.getMapCell(ix, iz)
    local fk = PathFinderModule.getFineIndex(ix, iz, x, z)
    local onField, grass
    if fk ~= nil then
        local fine = PathFinderModule.getFineCell(cell, ix, iz)
        onField, grass = fine.field[fk], fine.grass ~= nil and fine.grass[fk]
    else
        local k = 1
        if x >= ix * size then
            k = k + 1
        end
        if z >= iz * size then
            k = k + 2
        end
        onField, grass = cell.field[k], cell.grass ~= nil and cell.grass[k]
    end
    if onField and not PathFinderModule.isHarvestFieldGround(cell, grass) then
        return false
    end
    return onField
end

-- ------------------------------------------------------------------------------------------------------------
-- Champ en cours de récolte
-- ------------------------------------------------------------------------------------------------------------
-- the field being harvested (25/10 19:14: the 7R drove round the hedge onto the
-- grass strip behind it, field ground for the game with no crop on it). While a forage harvester works another crop,
-- grass or meadow ground is not its field; ground of another field number is not its field either
PathFinderModule.HARVEST_FIELD_TTL = 60000 -- ms between two readings of the harvester's field
PathFinderModule.harvestField = nil
function PathFinderModule.getFieldIdAt(x, z)
    if g_fieldManager == nil or g_fieldManager.getFieldAtWorldPosition == nil then
        return nil
    end
    local ok, field = pcall(g_fieldManager.getFieldAtWorldPosition, g_fieldManager, x, z)
    if ok and type(field) == "table" then
        return field.fieldId or field.id
    end
    return nil
end
function PathFinderModule.setHarvestField(combine)
    if combine == nil or combine.components == nil or combine.ad == nil or not combine.ad.isChopper then
        return
    end
    local now = g_time or 0
    local hf = PathFinderModule.harvestField
    if hf ~= nil and hf.combine == combine and now - hf.t < PathFinderModule.HARVEST_FIELD_TTL then
        return
    end
    local x, _, z = getWorldTranslation(combine.components[1].node)
    local _, grass = PathFinderModule.readCropAt(x, z)
    -- grass is its field when it picks grass up (its tank says so), or when it stands on grass and nothing said otherwise yet
    local grassIsField = false
    if combine.spec_combine ~= nil and combine.spec_combine.fillUnitIndex ~= nil and combine.getFillUnitFillType ~= nil then
        local fillType = combine:getFillUnitFillType(combine.spec_combine.fillUnitIndex)
        if fillType ~= nil and FillType ~= nil and (fillType == FillType.GRASS_WINDROW or fillType == FillType.DRYGRASS_WINDROW) then
            grassIsField = true
        end
    end
    if not grassIsField and grass == true and (hf == nil or hf.combine ~= combine or hf.grassIsField) then
        grassIsField = true
    end
    local id = PathFinderModule.getFieldIdAt(x, z)
    local changed = hf == nil or hf.combine ~= combine or hf.id ~= id or hf.grassIsField ~= grassIsField
    PathFinderModule.harvestField = {combine = combine, id = id, grassIsField = grassIsField, t = now}
    if changed then
        print(string.format("[AD-Carte] champ de %s : numero %s, herbe et prairie %s", tostring(combine:getName()), tostring(id or "inconnu"),
            grassIsField and "comptees comme son champ" or "comptees hors champ"))
    end
end
function PathFinderModule.isHarvestFieldGround(cell, grass)
    local hf = PathFinderModule.harvestField
    if hf == nil then
        return true
    end
    if grass and not hf.grassIsField then
        return false
    end
    if hf.id ~= nil and cell.fieldId ~= nil and cell.fieldId ~= hf.id then
        return false
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Part de culture dans une surface
-- ------------------------------------------------------------------------------------------------------------
-- share of standing crop in the parallelogram c1, c2 = c1 + u, c4 = c1 + v, sampled every meter.
-- fruitFilter nil: every crop counts. Returns ratio and the crop found most
function PathFinderModule.getMapCropRatio(fruitFilter, c1X, c1Z, c2X, c2Z, c4X, c4Z)
    local uX, uZ = c2X - c1X, c2Z - c1Z
    local vX, vZ = c4X - c1X, c4Z - c1Z
    local nu = math.max(1, math.ceil(math.sqrt(uX * uX + uZ * uZ)))
    local nv = math.max(1, math.ceil(math.sqrt(vX * vX + vZ * vZ)))
    local hits, found = 0, nil
    for i = 0, nu - 1 do
        local fu = (i + 0.5) / nu
        for j = 0, nv - 1 do
            local fv = (j + 0.5) / nv
            local crop = PathFinderModule.getMapCropAt(c1X + uX * fu + vX * fv, c1Z + uZ * fu + vZ * fv)
            if crop ~= 0 and (fruitFilter == nil or crop == fruitFilter) then
                hits = hits + 1
                found = crop
            end
        end
    end
    return hits / (nu * nv), found
end

-- crop filter of this search: every crop in strict mode or to the network, else the crop of the field
function PathFinderModule:getCropFilter()
    if self.goingToNetwork or self.strictFruit then
        return nil
    end
    return self.fruitToCheck
end

-- ------------------------------------------------------------------------------------------------------------
-- Carte relue autour des moissonneuses
-- ------------------------------------------------------------------------------------------------------------
-- the harvesters cut the crop: read the map again around each one working (every MAP_REFRESH_INTERVAL)
function PathFinderModule.refreshFieldMap()
    local now = g_time or 0
    if now - PathFinderModule.fieldMapRefreshTime < PathFinderModule.MAP_REFRESH_INTERVAL and now >= PathFinderModule.fieldMapRefreshTime then
        return
    end
    PathFinderModule.fieldMapRefreshTime = now
    if PathFinderModule.fieldMapCount == 0 or g_currentMission == nil or g_currentMission.vehicleSystem == nil then
        return
    end
    local size = PathFinderModule.MAP_CELL
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.spec_combine ~= nil and vehicle.components ~= nil and vehicle.rootNode ~= nil and vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() > 0.5 then
            local x, _, z = getWorldTranslation(vehicle.rootNode)
            local vehicleSize = vehicle.size or {}
            local radius = math.max(vehicleSize.width or 6, vehicleSize.length or 10, 12) / 2 + PathFinderModule.MAP_HARVESTER_MARGIN
            local r = math.ceil(radius / size)
            local cx, cz = math.floor(x / size + 0.5), math.floor(z / size + 0.5)
            for ix = cx - r, cx + r do
                for iz = cz - r, cz + r do
                    local key = (ix + 50000) * 100000 + (iz + 50000)
                    local cell = PathFinderModule.fieldMap[key]
                    if cell ~= nil then
                        cell.t = -math.huge
                        PathFinderModule.getMapCell(ix, iz)
                    end
                end
            end
        end
    end
end
