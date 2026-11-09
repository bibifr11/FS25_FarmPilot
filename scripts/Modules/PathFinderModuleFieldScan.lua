-- ============================================================================================================
-- FarmPilot : PathFinderModuleFieldScan.lua
-- Complément de PathFinderModule : relevé du champ entier et affichage de la carte des cultures.
-- - Relevé : quand un déchargeur part vers une moissonneuse, tout le champ est lu d'un coup dans la carte
--   (PathFinderModuleCropMap.lua) par remplissage sur le sol du champ depuis la moissonneuse, avec un anneau de
--   cases autour du champ, réparti sur les images (MAP_SCAN_BUDGET ms par image) ; puis la bordure est relue tous
--   les 0,5 m (23/10, voir PathFinderModuleCropMap.lua).
-- - Affichage (commande console adCarte) : autour du joueur, croix vertes = libre, rouges = culture ; poteaux =
--   cases de la dernière recherche, colorés selon la raison (libre, champ, culture, obstacle/pente, véhicule).
--
-- Règle : le relevé ne prend que quelques ms par image, la partie fine est lue après le champ.
--
-- Branché par PathFinderModule.lua (startPathPlanningToPipe : startFieldScan), AutoDrive.lua (updateFieldScan et
-- drawFieldMap à chaque image, commande adCarte : toggleFieldMap) ; addSearchCell par PathFinderModuleLog.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Relevé du champ entier
-- ------------------------------------------------------------------------------------------------------------
-- whole field recorded at once when an unloader goes to a harvester: flood fill over the field ground from the
-- harvester, a ring of cells around the field included, spread over the frames (MAP_SCAN_BUDGET ms each)
PathFinderModule.MAP_SCAN_BUDGET = 3
PathFinderModule.MAP_SCAN_MAX_CELLS = 400000
PathFinderModule.MAP_DRAW_RADIUS = 40
PathFinderModule.showFieldMap = false
PathFinderModule.fieldScan = nil
PathFinderModule.scannedCells = {}
PathFinderModule.searchCells = {}

local function mapClock()
    if getTimeSec ~= nil then
        return getTimeSec() * 1000
    end
    return os.clock() * 1000
end

function PathFinderModule.startFieldScan(x, z)
    local size = PathFinderModule.MAP_CELL
    local ix, iz = math.floor(x / size + 0.5), math.floor(z / size + 0.5)
    local key = (ix + 50000) * 100000 + (iz + 50000)
    local scannedAt = PathFinderModule.scannedCells[key]
    local now = g_time or 0
    if PathFinderModule.fieldScan ~= nil and PathFinderModule.fieldScan.visited[key] then
        return
    end
    if scannedAt ~= nil and now >= scannedAt and now - scannedAt < PathFinderModule.MAP_TTL then
        return
    end
    local scan = {visited = {[key] = true}, queue = {{ix, iz}}, head = 1, tail = 1, count = 0, startTime = mapClock(), startX = x, startZ = z}
    PathFinderModule.fieldScan = scan
    print(string.format("AutoDrive : [carte] enregistrement du champ a %.0f,%.0f", x, z))
end

function PathFinderModule.updateFieldScan()
    local scan = PathFinderModule.fieldScan
    if scan == nil then
        return
    end
    local now = g_time or 0
    local stopAt = mapClock() + PathFinderModule.MAP_SCAN_BUDGET
    local done = 0
    while scan.head <= scan.tail do
        local item = scan.queue[scan.head]
        scan.queue[scan.head] = nil
        scan.head = scan.head + 1
        local ix, iz = item[1], item[2]
        local key = (ix + 50000) * 100000 + (iz + 50000)
        local cell = PathFinderModule.fieldMap[key]
        if cell ~= nil and (now < cell.t or now - cell.t >= PathFinderModule.MAP_TTL or cell.field == nil) then
            cell.t = -math.huge
        end
        cell = PathFinderModule.getMapCell(ix, iz)
        PathFinderModule.scannedCells[key] = now
        scan.count = scan.count + 1
        if cell.onField and scan.count < PathFinderModule.MAP_SCAN_MAX_CELLS then
            for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                local nx, nz = ix + d[1], iz + d[2]
                local nkey = (nx + 50000) * 100000 + (nz + 50000)
                if not scan.visited[nkey] then
                    scan.visited[nkey] = true
                    scan.tail = scan.tail + 1
                    scan.queue[scan.tail] = {nx, nz}
                end
            end
        end
        done = done + 1
        if done % 20 == 0 and mapClock() >= stopAt then
            return
        end
    end
    if scan.fineKeys == nil then
        scan.bandCells = PathFinderModule.markFineBand(scan.visited)
        scan.fineKeys, scan.fineIndex = {}, 1
        for key, _ in pairs(scan.visited) do
            if PathFinderModule.fineBand[key] then
                scan.fineKeys[#scan.fineKeys + 1] = key
            end
        end
    end
    while scan.fineIndex <= #scan.fineKeys do
        local key = scan.fineKeys[scan.fineIndex]
        scan.fineIndex = scan.fineIndex + 1
        local ix, iz = math.floor(key / 100000) - 50000, key % 100000 - 50000
        PathFinderModule.getFineCell(PathFinderModule.getMapCell(ix, iz), ix, iz)
        if scan.fineIndex % 10 == 0 and mapClock() >= stopAt then
            return
        end
    end
    local bandCells = scan.bandCells
    local crop = 0
    for key, _ in pairs(scan.visited) do
        local cell = PathFinderModule.fieldMap[key]
        if cell ~= nil and (cell[1] ~= 0 or cell[2] ~= 0 or cell[3] ~= 0 or cell[4] ~= 0) then
            crop = crop + 1
        end
    end
    print(string.format("AutoDrive : [carte] champ enregistre : %d cases de 2 m (%.1f ha), culture %d cases, bordure %d cases en 0,5 m (%.0f m), en %.1f s", scan.count, scan.count * 4 / 10000, crop, bandCells, PathFinderModule.FINE_BAND_WIDTH, (mapClock() - scan.startTime) / 1000))
    PathFinderModule.fieldScan = nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Bordure relue tous les 0,5 m
-- ------------------------------------------------------------------------------------------------------------
-- border band of a scanned field: from the cells off the field next to it (the ring read by the scan), over the
-- field cells, up to FINE_BAND_WIDTH toward the middle. Returns the number of cells in the band
function PathFinderModule.markFineBand(visited)
    local map = PathFinderModule.fieldMap
    local function decode(key)
        return math.floor(key / 100000) - 50000, key % 100000 - 50000
    end
    local function keyOf(ix, iz)
        return (ix + 50000) * 100000 + (iz + 50000)
    end
    local maxSteps = math.ceil(PathFinderModule.FINE_BAND_WIDTH / PathFinderModule.MAP_CELL)
    local dist, queue, head = {}, {}, 1
    for key, _ in pairs(visited) do
        local cell = map[key]
        if cell ~= nil and not cell.onField then
            local ix, iz = decode(key)
            for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                local n = map[keyOf(ix + d[1], iz + d[2])]
                if n ~= nil and n.onField then
                    dist[key] = 0
                    queue[#queue + 1] = key
                    break
                end
            end
        end
    end
    while head <= #queue do
        local key = queue[head]
        head = head + 1
        local ix, iz = decode(key)
        if dist[key] < maxSteps then
            for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                local nkey = keyOf(ix + d[1], iz + d[2])
                local n = map[nkey]
                if dist[nkey] == nil and n ~= nil and n.onField then
                    dist[nkey] = dist[key] + 1
                    queue[#queue + 1] = nkey
                end
            end
        end
    end
    local count = 0
    for key, _ in pairs(dist) do
        if not PathFinderModule.fineBand[key] then
            PathFinderModule.fineBand[key] = true
        end
        count = count + 1
    end
    return count
end

-- ------------------------------------------------------------------------------------------------------------
-- Affichage de la carte et des cases de la dernière recherche
-- ------------------------------------------------------------------------------------------------------------
-- cells looked at by the last search, kept for the display (reason: libre, champ, culture, obstacle/pente, vehicule)
function PathFinderModule.addSearchCell(x, z, reason)
    local cells = PathFinderModule.searchCells
    if #cells < 8000 then
        cells[#cells + 1] = {x = x, z = z, reason = reason, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)}
    end
end

PathFinderModule.SEARCH_COLORS = {
    ["libre"] = {0, 1, 1},
    ["champ"] = {0, 0, 1},
    ["culture"] = {1, 0, 1},
    ["obstacle/pente"] = {1, 1, 0},
    ["vehicule"] = {1, 0.5, 0}
}

function PathFinderModule.toggleFieldMap()
    PathFinderModule.showFieldMap = not PathFinderModule.showFieldMap
    return "AutoDrive carte du champ : " .. (PathFinderModule.showFieldMap and "affichee" or "cachee")
end

-- the map around the player: on field, green crosses = free, red = crop; posts = cells of the last search
function PathFinderModule.drawFieldMap()
    if not PathFinderModule.showFieldMap or drawDebugLine == nil or PathFinderModule.fieldMapCount == 0 then
        return
    end
    local node = nil
    local vehicle = AutoDrive.getControlledVehicle and AutoDrive.getControlledVehicle()
    if vehicle ~= nil and vehicle.rootNode ~= nil then
        node = vehicle.rootNode
    elseif g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        node = g_localPlayer.rootNode
    end
    if node == nil then
        return
    end
    local px, _, pz = getWorldTranslation(node)
    local size = PathFinderModule.MAP_CELL
    local r = math.floor(PathFinderModule.MAP_DRAW_RADIUS / size)
    local cx, cz = math.floor(px / size + 0.5), math.floor(pz / size + 0.5)
    local h = size * 0.35
    for ix = cx - r, cx + r do
        for iz = cz - r, cz + r do
            local cell = PathFinderModule.fieldMap[(ix + 50000) * 100000 + (iz + 50000)]
            if cell ~= nil and cell.y ~= nil and cell.fine ~= nil then
                -- border band: one small cross every 0.5 m
                local fine, step = cell.fine, PathFinderModule.FINE_STEP
                local x0, z0, y = ix * size - size / 2 + step / 2, iz * size - size / 2 + step / 2, cell.y + 0.15
                local hh = step * 0.35
                for j = 0, fine.n - 1 do
                    for i = 0, fine.n - 1 do
                        local k = j * fine.n + i + 1
                        if fine.field[k] then
                            local x, z = x0 + i * step, z0 + j * step
                            local red, green = 0, 1
                            if fine.crop[k] ~= 0 then
                                red, green = 1, 0
                            end
                            drawDebugLine(x - hh, y, z - hh, red, green, 0, x + hh, y, z + hh, red, green, 0, false)
                            drawDebugLine(x - hh, y, z + hh, red, green, 0, x + hh, y, z - hh, red, green, 0, false)
                        end
                    end
                end
            elseif cell ~= nil and cell.onField and cell.y ~= nil then
                local x, z, y = ix * size, iz * size, cell.y + 0.15
                local red, green = 0, 1
                if cell[1] ~= 0 or cell[2] ~= 0 or cell[3] ~= 0 or cell[4] ~= 0 then
                    red, green = 1, 0
                end
                drawDebugLine(x - h, y, z - h, red, green, 0, x + h, y, z + h, red, green, 0, false)
                drawDebugLine(x - h, y, z + h, red, green, 0, x + h, y, z - h, red, green, 0, false)
            end
        end
    end
    local radius = PathFinderModule.MAP_DRAW_RADIUS
    for _, c in ipairs(PathFinderModule.searchCells) do
        if math.abs(c.x - px) < radius and math.abs(c.z - pz) < radius then
            local color = PathFinderModule.SEARCH_COLORS[c.reason] or {1, 1, 1}
            local y = c.y
            drawDebugLine(c.x, y, c.z, color[1], color[2], color[3], c.x, y + 1.5, c.z, color[1], color[2], color[3], false)
        end
    end
end
