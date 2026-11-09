-- ============================================================================================================
-- FarmPilot : PathFinderModuleCrop.lua
-- Complément de PathFinderModule : la culture le long du trajet.
-- - Largeur prise pour la culture : le train entier (+ marge) ; pour l'ensileuse, aux bords extérieurs des pneus,
--   sans marge (la culture n'est écrasée que par les roues).
-- - A* : la culture est cherchée le long du couloir réellement roulé entre deux cases, à la largeur du train, et non
--   dans un carré de la taille du rayon de braquage (les bandes récoltées plus étroites que ce rayon restent utilisables).
-- - Îlots : de petits restes de culture dans un champ récolté sont ignorés.
-- - Culture d'une case de la grille : lue dans la carte des cultures (une part pour toutes les cultures à la fois).
-- - Raccourcis du lissage : même couloir que la recherche, avec une marge à la culture.
--
-- Historique : 24/10 13:34, même en poursuite les îlots sont ignorés (getFruitRatio :
-- seule compte une culture qui n'est ni un plant isolé ni une bande étroite).
--
-- Règle : en strict, toute culture debout compte, pas seulement celle trouvée dans la trémie ; la case de départ
-- (où le train est déjà) ne bloque pas la sortie.
--
-- Branché par PathFinderModule.lua : startPathPlanningTo (getTrainWidth, updateCropHalfWidth), isDriveableAstar
-- (getCorridorCorners, checkForFruitInArea), smoothResultingPPPath_Refined (getShortcutFruitCorners) ; getTrainWidth
-- et getFruitRatio aussi par les tâches (FollowCombineTask, CatchCombinePipeTask, ExitFieldTask, demi-tours…).
-- checkForFruitInArea (fonction d'AutoDrive) est remplacée ici ; l'ancienne lecture, checkForFruitInAreaDensity,
-- est mise de côté entre crochets --[==[ ]==] avec PathFinderModule:checkForFruitTypeInArea (09/11, inutilisées).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- A*: check fruit along the segment really driven between two cells, with the width of the train,
-- instead of a square of the turn radius size, so harvested strips narrower than the turn radius stay usable
PathFinderModule.FRUIT_CHECK_TRAIN_CORRIDOR = true
PathFinderModule.FRUIT_CHECK_CORRIDOR_MARGIN = 0.7

PathFinderModule.FRUIT_MAX_RATIO = 0.10
PathFinderModule.SMOOTH_FRUIT_MARGIN = 1

-- ------------------------------------------------------------------------------------------------------------
-- Largeur du train pour la culture
-- ------------------------------------------------------------------------------------------------------------
function PathFinderModule:getTrainWidth()
    local width = 3
    local units = AutoDrive.getAllUnits(self.vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit.size ~= nil and unit.size.width ~= nil then
                width = math.max(width, unit.size.width)
            end
        end
    end
    return width
end

-- half width over the outer tyre edges of the whole train (crop is only run over by the wheels), nil if unknown
function PathFinderModule:getWheelHalfWidth()
    local units = AutoDrive.getAllUnits(self.vehicle)
    local half = nil
    for _, unit in pairs(units or {}) do
        local spec = unit.spec_wheels
        local root = unit.components ~= nil and unit.components[1] ~= nil and unit.components[1].node or nil
        if spec ~= nil and spec.wheels ~= nil and root ~= nil then
            for _, wheel in pairs(spec.wheels) do
                local physics = wheel.physics
                if physics ~= nil and wheel.node ~= nil and physics.positionX ~= nil then
                    local x = localToLocal(wheel.node, root, physics.positionX, physics.positionY or 0, physics.positionZ or 0)
                    local edge = math.abs(x) + (physics.width or PathFinderModule.WHEEL_DEFAULT_WIDTH) / 2
                    half = math.max(half or 0, edge)
                end
            end
        end
    end
    return half
end

-- half width used by the crop checks: forage harvester at the outer tyre edges, no margin; otherwise train width + margin
PathFinderModule.WHEEL_DEFAULT_WIDTH = 0.6
function PathFinderModule:updateCropHalfWidth()
    self.cropHalfWidth = self.trainHalfWidth
    if not self:isChopperWork() then
        return
    end
    local wheelHalf = self:getWheelHalfWidth()
    if wheelHalf ~= nil and wheelHalf > 0.5 then
        self.cropHalfWidth = math.min(wheelHalf, self.trainHalfWidth)
    end
    if self.cropHalfWidthLogged ~= self.cropHalfWidth then
        self.cropHalfWidthLogged = self.cropHalfWidth
        print(string.format("[AD-Strict] %s: largeur controlee culture %.2f m (essieux, sans marge), obstacles %.2f m (carrosserie + marge)",
            self:getLogName(), self.cropHalfWidth * 2, self.trainHalfWidth * 2))
    end
end

function PathFinderModule:getCropHalfWidth()
    return self.cropHalfWidth or self.trainHalfWidth or 2
end

-- corners of the corridor driven from fromCell to cell, same layout as getCorners (start, width, height, opposite)
function PathFinderModule:getCorridorCorners(fromCell, cell)
    local a = self:gridLocationToWorldLocation(fromCell)
    local b = self:gridLocationToWorldLocation(cell)
    local dx, dz = b.x - a.x, b.z - a.z
    local length = math.sqrt(dx * dx + dz * dz)
    if length < 0.01 then
        return nil
    end
    local half = self:getCropHalfWidth()
    local nx, nz = -dz / length * half, dx / length * half
    return {
        {x = a.x - nx, z = a.z - nz},
        {x = a.x + nx, z = a.z + nz},
        {x = b.x - nx, z = b.z - nz},
        {x = b.x + nx, z = b.z + nz}
    }
end

-- ------------------------------------------------------------------------------------------------------------
-- Îlots de culture
-- ------------------------------------------------------------------------------------------------------------
-- small patches of standing crop left in a harvested field are ignored: a fruit hit only counts
-- if at least PathFinderModule.ISLAND_MIN_RATIO of the area around the cell holds this fruit too
PathFinderModule.ISLAND_CHECK_HALF_SIZE = 10
PathFinderModule.ISLAND_CHECK_SAMPLES = 10
PathFinderModule.ISLAND_MIN_RATIO = 0.08

function PathFinderModule:isFruitIsland(fruitTypeIndex, x, z)
    local key = string.format("%s_%d_%d", tostring(fruitTypeIndex), math.floor(x / 8), math.floor(z / 8))
    if self.islandCache ~= nil and self.islandCache[key] ~= nil then
        return self.islandCache[key]
    end
    -- from the field map: share of this crop in the square around the position
    if true then
        local half = PathFinderModule.ISLAND_CHECK_HALF_SIZE
        local ratio = PathFinderModule.getMapCropRatio(fruitTypeIndex, x - half, z - half, x + half, z - half, x - half, z + half)
        local isIslandMap = ratio < PathFinderModule.ISLAND_MIN_RATIO
        if self.islandCache ~= nil then
            self.islandCache[key] = isIslandMap
        end
        return isIslandMap
    end
    local half = PathFinderModule.ISLAND_CHECK_HALF_SIZE
    local samples = PathFinderModule.ISLAND_CHECK_SAMPLES
    local step = 2 * half / samples
    local hits = 0
    for i = 0, samples - 1 do
        for j = 0, samples - 1 do
            local sx = x - half + i * step
            local sz = z - half + j * step
            if AutoDrive.getFruitValue(fruitTypeIndex, sx, sz, sx + step, sz, sx, sz + step) > 0 then
                hits = hits + 1
            end
        end
    end
    local isIsland = hits < samples * samples * PathFinderModule.ISLAND_MIN_RATIO
    if self.islandCache ~= nil then
        self.islandCache[key] = isIsland
    end
    return isIsland
end

-- ------------------------------------------------------------------------------------------------------------
-- Part de culture (plants isolés et bandes étroites ignorés)
-- ------------------------------------------------------------------------------------------------------------
-- share of the area covered by standing crop (cut or withered crop counts as none)
-- 24/10 13:34, islands ignored in the chase too: crop read from the density map over a
-- parallelogram, kept only if one of its samples is crop that is neither an isolated plant nor a narrow strip
PathFinderModule.ISLAND_SAMPLE = 1 -- m between samples
function PathFinderModule.isOnlyIsolatedCropIn(c1X, c1Z, c2X, c2Z, c3X, c3Z)
    local ux, uz = c2X - c1X, c2Z - c1Z
    local vx, vz = c3X - c1X, c3Z - c1Z
    local nu = math.max(1, math.ceil(math.sqrt(ux * ux + uz * uz) / PathFinderModule.ISLAND_SAMPLE))
    local nv = math.max(1, math.ceil(math.sqrt(vx * vx + vz * vz) / PathFinderModule.ISLAND_SAMPLE))
    local seen = false
    for i = 0, nu do
        for j = 0, nv do
            local x, z = c1X + ux * i / nu + vx * j / nv, c1Z + uz * i / nu + vz * j / nv
            if PathFinderModule.getMapCropRawAt(x, z) ~= 0 then
                seen = true
                if not PathFinderModule.isIsolatedCrop(x, z) then
                    return false
                end
            end
        end
    end
    return seen
end

function PathFinderModule.getFruitRatio(fruitTypeIndex, c1X, c1Z, c2X, c2Z, c3X, c3Z)
    if fruitTypeIndex == FruitType.GRASS or fruitTypeIndex == FruitType.MEADOW then
        return 0
    end
    local fruitValue, _, totalPixels, growthState = FSDensityMapUtil.getFruitArea(fruitTypeIndex, c1X, c1Z, c2X, c2Z, c3X, c3Z, true, true)
    local fruit = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruit ~= nil and growthState ~= nil and (fruit:getIsCut(growthState) or fruit:getIsWithered(growthState)) then
        return 0
    end
    if fruitValue == nil or totalPixels == nil or totalPixels <= 0 then
        return 0
    end
    return fruitValue / totalPixels
end

-- ------------------------------------------------------------------------------------------------------------
-- Culture d'une case de la grille
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.CELL_MAX_RATIO = 0.10

-- crop of a grid cell, read from the field map: one share for every crop at once
function PathFinderModule:checkForFruitInArea(cell, corners)
    if self.goingToNetwork then
        -- on the way to network, check all fruit types
        self.fruitToCheck = nil
    end
    local filter = self.fruitToCheck
    if self.strictFruit then
        filter = nil
    end
    local ratio, found = PathFinderModule.getMapCropRatio(filter, corners[1].x, corners[1].z, corners[2].x, corners[2].z, corners[3].x, corners[3].z)
    if found ~= nil and (self.fruitToCheck == nil or self.fruitToCheck < 1) and not self.goingToNetwork then
        self.fruitToCheck = found
    end
    local hasFruit = ratio > PathFinderModule.CELL_MAX_RATIO
    if hasFruit and self.isNewPF then
        local center = cell.worldPos or self:gridLocationToWorldLocation(cell)
        if self:isFruitIsland(filter, center.x, center.z) then
            hasFruit = false
        end
    end
    local wasRestricted = cell.isRestricted
    cell.isRestricted = cell.isRestricted or hasFruit
    if not wasRestricted and cell.isRestricted then
        self.strictFruitRefusals = (self.strictFruitRefusals or 0) + 1
    end
    cell.hasFruit = hasFruit
    cell.fruitValue = ratio
    --Allow fruit in the last few grid cells (not behind the harvester: cut ground there)
    if (self:cellDistance(cell) <= 3 and self.goingToPipe and not self.goingBehind) then
        cell.isRestricted = false or wasRestricted
    end
    -- the vehicle already stands there: crop in the start cell (or within START_CROP_RADIUS) does not block the way out,
    -- any further the search has to follow the cut strip
    local nearStart = false
    if hasFruit and not wasRestricted and self.startX ~= nil then
        local center = cell.worldPos or self:gridLocationToWorldLocation(cell)
        nearStart = MathUtil.vector2Length(center.x - self.startX, center.z - self.startZ) < PathFinderModule.START_CROP_RADIUS
        if nearStart and self:isChopperWork() and (self.strictFruit or self.strictField) then
            -- strict: only where the train stands, a turn through the crop ahead of the tractor is no way out
            local _, _, _, hx, hz = self:getStartPose()
            nearStart = (center.x - self.startX) * hx + (center.z - self.startZ) * hz < PathFinderModule.START_CROP_AHEAD
        end
    end
    if hasFruit and not wasRestricted and (nearStart or (self.startCell ~= nil and cell.x ~= nil and cell.z ~= nil
        and cell.x == self.startCell.x and cell.z == self.startCell.z)) then
        cell.isRestricted = false
        cell.hasFruit = false
    end
end

--[==[ Mis de côté (09/11) : inutilisé
-- previous check, density map read for each crop type (kept for reference, not used)
function PathFinderModule:checkForFruitInAreaDensity(cell, corners)

    if self.goingToNetwork then
        -- on the way to network, check all fruit types
        self.fruitToCheck = nil
    end
    if self.fruitToCheck == nil or self.strictFruit then
        -- strict: every standing crop counts, not only the one found in the combine tank
        for _, fruitType in pairs(g_fruitTypeManager:getFruitTypes()) do
            if not (fruitType == g_fruitTypeManager:getFruitTypeByName("MEADOW")) then
                local fruitTypeIndex = fruitType.index
                self:checkForFruitTypeInArea(cell, fruitTypeIndex, corners)
            end
            --stop if cell is already restricted and/or fruit type is now known
            if cell.isRestricted ~= false or (self.fruitToCheck ~= nil and not self.strictFruit) then
                break
            end
        end
    else
        self:checkForFruitTypeInArea(cell, self.fruitToCheck, corners)
    end
end
]==]

-- ------------------------------------------------------------------------------------------------------------
-- Raccourci du lissage : couloir de culture
-- ------------------------------------------------------------------------------------------------------------
-- fruit check of the shortcut: same corridor as the grid search (train width + margin), not the whole cell,
-- or a strip along standing crop is never straightened and the route zigzags
-- accroche de smoothResultingPPPath_Refined : côté du couloir et ses coins (c1, c2, c4)
function PathFinderModule:getShortcutFruitCorners(node, nodeAhead, leftAngle, rightAngle, sideLength)
    local fruitSide = self.trainHalfWidth or sideLength
    -- shortcuts keep a margin from the crop: the vehicle drives in the free strip, not along the crop edge
    if self.trainHalfWidth ~= nil then
        fruitSide = self.trainHalfWidth + PathFinderModule.SMOOTH_FRUIT_MARGIN
        if self:isChopperWork() then
            -- forage harvester: the shortcut is judged as the final check, at the tyre edges
            fruitSide = self:getCropHalfWidth()
        end
    end
    local fruitCornerX = node.x - math.cos(leftAngle) * fruitSide
    local fruitCornerZ = node.z + math.sin(leftAngle) * fruitSide
    local fruitCorner2X = nodeAhead.x - math.cos(leftAngle) * fruitSide
    local fruitCorner2Z = nodeAhead.z + math.sin(leftAngle) * fruitSide
    local fruitCorner4X = node.x - math.cos(rightAngle) * fruitSide
    local fruitCorner4Z = node.z + math.sin(rightAngle) * fruitSide
    return fruitSide, fruitCornerX, fruitCornerZ, fruitCorner2X, fruitCorner2Z, fruitCorner4X, fruitCorner4Z
end
