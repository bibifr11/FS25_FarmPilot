-- ============================================================================================================
-- FarmPilot : PathFinderModuleLog.lua
-- Complément de PathFinderModule : le journal de la recherche de trajet.
-- - une ligne par trajet trouvé (grille ou courbe directe), et en strict ce qui a été contrôlé ;
-- - pour chaque case de la recherche, la raison du refus (champ, culture, obstacle/pente, véhicule) ou « libre »,
--   gardée pour l'affichage (PathFinderModuleFieldScan.lua) et pour le diagnostic ;
-- - sans trajet : une ligne de diagnostic, et une carte texte de ce que la recherche a vu (une par véhicule toutes
--   les 2 min au plus, balises [AD-Carte]).
--
-- Règle : le journal n'a aucun effet sur le trajet.
--
-- Branché par PathFinderModule.lua : update (logGridPathFound, getDiagText, dumpSearchMap), isDriveableAstar
-- (recordSearchCell), getDubinsPath (printStrictSummary, printTrip) ; getLogName par presque tous les fichiers.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Noms et trajets
-- ------------------------------------------------------------------------------------------------------------
function PathFinderModule:printTrip(kind)
    print(string.format("[AD-Fin] %s: trajet (%s, cases %.1f m) depart %.0f,%.0f -> arrivee %.0f,%.0f", self:getLogName(), kind, self.minTurnRadius or 0,
        self.startX or 0, self.startZ or 0, self.target ~= nil and self.target.x or 0, self.target ~= nil and self.target.z or 0))
end

function PathFinderModule:getLogName()
    return self.vehicle ~= nil and self.vehicle.getName ~= nil and self.vehicle:getName() or "?"
end

-- ------------------------------------------------------------------------------------------------------------
-- Résumé du mode strict
-- ------------------------------------------------------------------------------------------------------------
-- one line in the log for each route found in strict mode, to see what was checked when a route crosses a crop
function PathFinderModule:printStrictSummary(kind)
    if not (self.strictFruit or self.strictField) then
        return
    end
    local fruitName = "toutes"
    if self.fruitToCheck ~= nil and not self.strictFruit then
        local fruitType = g_fruitTypeManager:getFruitTypeByIndex(self.fruitToCheck)
        fruitName = fruitType ~= nil and fruitType.name or tostring(self.fruitToCheck)
    end
    local name = self.vehicle ~= nil and self.vehicle.getName ~= nil and self.vehicle:getName() or "?"
    print(string.format("[AD-Strict] %s: chemin trouve (%s) vers %.0f,%.0f, culture controlee %s, cases refusees culture %d, eviter culture %s, champ %s, secours culture %s, vers moissonneuse %s, carte %d cases (%d lues pour ce calcul)",
        tostring(name), kind, self.target ~= nil and self.target.x or 0, self.target ~= nil and self.target.z or 0, fruitName, self.strictFruitRefusals or 0,
        tostring(self.avoidFruitSetting), tostring(AutoDrive.getSetting("restrictToField", self.vehicle)),
        tostring(self.fallBackMode3), tostring(self.goingToPipe), PathFinderModule.fieldMapCount, PathFinderModule.fieldMapReads - (self.mapReadsAtStart or 0)))
end

-- ------------------------------------------------------------------------------------------------------------
-- Cases de la recherche
-- ------------------------------------------------------------------------------------------------------------
-- accroche de isDriveableAstar : pourquoi la case est refusée (ou libre)
function PathFinderModule:recordSearchCell(cell, worldPos)
    if cell.isRestricted then
        local diag = self.diag or {}
        self.diag = diag
        local reason = "vehicule"
        if cell.isOnField ~= nil and self.restrictToField and not (self.fallBackMode1 or self.fallBackMode2) and not self:isFieldPositionAllowed(worldPos.x, worldPos.z, cell.isOnField) then
            reason = "champ"
        elseif cell.hasFruit then
            reason = "culture"
        elseif cell.hasCollision then
            reason = "obstacle/pente"
        end
        diag[reason] = (diag[reason] or 0) + 1
        PathFinderModule.addSearchCell(worldPos.x, worldPos.z, reason)
    else
        self.diagFree = (self.diagFree or 0) + 1
        PathFinderModule.addSearchCell(worldPos.x, worldPos.z, "libre")
    end
end

-- accroche de PathFinderModule:update (trajet trouvé sur la grille)
function PathFinderModule:logGridPathFound()
    self:printStrictSummary("grille")
    self:printTrip("grille")
    if self.gridScaleStep ~= nil and self.gridScaleStep > 1 then
        print(string.format("[AD-Fin] %s: chemin trouve avec des cases de %.1f m", self:getLogName(), self.minTurnRadius))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Carte texte de la dernière recherche
-- ------------------------------------------------------------------------------------------------------------
-- TEST diagnostic: text map of what the last search saw, written to the log (one per vehicle every DUMP_INTERVAL).
-- One character per cell: ' ' off field, '.' field without crop, 'm' crop, search cells over it: 'o' free,
-- 'F' refused field, 'C' refused crop, 'X' refused obstacle/slope, 'V' refused vehicle; '*' route, '!' where the
-- route was refused, 'S' start, 'T' target. North (lower z) at the top, x grows to the right.
PathFinderModule.DUMP_INTERVAL = 120000
PathFinderModule.DUMP_MAX_CELLS = 150
PathFinderModule.DUMP_MARGIN = 20
PathFinderModule.DUMP_CHARS = {["libre"] = "o", ["champ"] = "F", ["culture"] = "C", ["obstacle/pente"] = "X", ["vehicule"] = "V"}
function PathFinderModule:dumpSearchMap(tag, path, badPoint)
    local ok, err = pcall(function()
        local now = g_time or 0
        if self.lastDumpTime ~= nil and now - self.lastDumpTime < PathFinderModule.DUMP_INTERVAL then
            return
        end
        if self.startX == nil or self.target == nil then
            return
        end
        self.lastDumpTime = now
        local minX, maxX = math.min(self.startX, self.target.x), math.max(self.startX, self.target.x)
        local minZ, maxZ = math.min(self.startZ, self.target.z), math.max(self.startZ, self.target.z)
        for _, wp in ipairs(path or {}) do
            minX, maxX, minZ, maxZ = math.min(minX, wp.x), math.max(maxX, wp.x), math.min(minZ, wp.z), math.max(maxZ, wp.z)
        end
        -- the whole explored area: where the search went and where it stopped
        for _, cell in ipairs(PathFinderModule.searchCells) do
            minX, maxX, minZ, maxZ = math.min(minX, cell.x), math.max(maxX, cell.x), math.min(minZ, cell.z), math.max(maxZ, cell.z)
        end
        local m = PathFinderModule.DUMP_MARGIN
        minX, maxX, minZ, maxZ = minX - m, maxX + m, minZ - m, maxZ + m
        local size = PathFinderModule.MAP_CELL
        while (maxX - minX) / size > PathFinderModule.DUMP_MAX_CELLS or (maxZ - minZ) / size > PathFinderModule.DUMP_MAX_CELLS do
            size = size * 2
        end
        local cols, rows = math.floor((maxX - minX) / size) + 1, math.floor((maxZ - minZ) / size) + 1
        local grid = {}
        for r = 1, rows do
            local line = {}
            for c = 1, cols do
                local x, z = minX + (c - 0.5) * size, minZ + (r - 0.5) * size
                local ch = " "
                if AutoDrive.checkIsOnField(x, 0, z) then
                    local crop = PathFinderModule.getMapCropAt(x, z)
                    ch = (crop ~= nil and crop ~= 0) and "m" or "."
                end
                line[c] = ch
            end
            grid[r] = line
        end
        local function put(x, z, ch)
            local c, r = math.floor((x - minX) / size) + 1, math.floor((z - minZ) / size) + 1
            if r >= 1 and r <= rows and c >= 1 and c <= cols then
                grid[r][c] = ch
            end
        end
        for _, cell in ipairs(PathFinderModule.searchCells) do
            put(cell.x, cell.z, PathFinderModule.DUMP_CHARS[cell.reason] or "?")
        end
        for _, wp in ipairs(path or {}) do
            put(wp.x, wp.z, "*")
        end
        if badPoint ~= nil then
            put(badPoint.x, badPoint.z, "!")
        end
        put(self.startX, self.startZ, "S")
        put(self.target.x, self.target.z, "T")
        print(string.format("[AD-Carte] %s: %s, cases %.0f m, x %.0f a %.0f, z %.0f a %.0f (%d x %d), legende : ' ' hors champ, '.' champ, 'm' culture, o libre, F/C/X/V refusee champ/culture/obstacle/vehicule, * trajet, ! refus, S depart, T cible",
            self:getLogName(), tag, size, minX, maxX, minZ, maxZ, cols, rows))
        for r = 1, rows do
            print(string.format("[AD-Carte] %4d |%s|", r, table.concat(grid[r])))
        end
        print(string.format("[AD-Carte] %s: fin", self:getLogName()))
    end)
    if not ok then
        print(string.format("[AD-Carte] %s: erreur %s", self:getLogName(), tostring(err)))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Diagnostic d'une recherche sans trajet
-- ------------------------------------------------------------------------------------------------------------
-- one line: why the cells of the last search were refused
function PathFinderModule:getDiagText()
    local diag = self.diag or {}
    local best = math.huge
    if self.closedset ~= nil and self.nodeGoal ~= nil then
        for node, _ in pairs(self.closedset) do
            if node.x ~= nil and node.z ~= nil then
                best = math.min(best, MathUtil.vector2Length(node.x - self.nodeGoal.x, node.z - self.nodeGoal.z))
            end
        end
    end
    local targetCrop = -1
    if self.target ~= nil then
        targetCrop = PathFinderModule.getMapCropRatio(nil, self.target.x - 5, self.target.z - 5, self.target.x + 5, self.target.z - 5, self.target.x - 5, self.target.z + 5)
    end
    local text = string.format("libres %d, refusees : champ %d, culture %d, obstacle/pente %d, vehicule %d, carte %d cases, pas %d/%d, cible %.0f,%.0f culture autour %.0f %%, case la plus proche a %.0f cases, bloque %s",
        self.diagFree or 0, diag["champ"] or 0, diag["culture"] or 0, diag["obstacle/pente"] or 0, diag["vehicule"] or 0, PathFinderModule.fieldMapCount,
        self.steps or 0, self.max_pathfinder_steps or 0, self.target ~= nil and self.target.x or 0, self.target ~= nil and self.target.z or 0, targetCrop * 100, best, tostring(self.completelyBlocked))
    self.diag = {}
    self.diagFree = 0
    return text
end
