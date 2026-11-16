-- ============================================================================================================
-- FarmPilot : LoaderJob.lua
-- Mode « Chargeur » (16/11) : réglages du chargeur, sources (silos couloirs et tas au sol), points de vidage du jeu,
-- sauvegarde.
--
-- Règles :
-- - Véhicules : télescopique, chargeuse, tracteur à chargeur frontal ; outil : godet ou fourche (tout outil à
--   spec_shovel). Le godet peut être déjà attelé, ou choisi dételé dans la ligne « Outil » (il va l'atteler).
-- - « Prendre » : TOUS les silos couloirs de la carte, et les tas au sol trouvés autour du chargeur et autour des
--   marqueurs de la carte. Silo bâché pas encore ouvert : refusé avec un message.
-- - « Vider » : « Benne » (une benne FarmPilot qui vient se mettre près de la source et attend, OU une benne garée
--   ou dételée près de la source : les deux) ou un point du jeu (mélangeuse, biogaz, point de vente...) qui prend
--   le produit de la source. Point loin de la source : le chargeur y va par le réseau, godet en position route.
-- - « Quantité » : Tout, ou 2 000 à 100 000 L. Fin (quantité vidée, ou source vide) : godet ramené à sa place
--   s'il en a une et s'il a été attelé par FarmPilot, puis le chargeur se garde à sa place.
-- Réglages du véhicule : « src;sx:sz;dst;px:pz;qty » (#fpLoaderCfg) ; travail en cours : #fpLoaderJob.
--
-- Branché par : register.lua (après SiloCompactMode.lua), Modes/LoaderMode.lua, Tasks/LoaderTask.lua,
-- Hud/HudLoader.lua, Events/LoaderEvent.lua.
-- ============================================================================================================

ADLoaderJob = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADLoaderJob.SRC_SILO = 1
ADLoaderJob.SRC_HEAP = 2
ADLoaderJob.DST_TRAILER = 1
ADLoaderJob.DST_POINT = 2
ADLoaderJob.QUANTITIES = { 0, 2000, 5000, 10000, 20000, 50000, 100000 } -- 0 = tout
ADLoaderJob.TRAILER_RANGE = 60          -- m autour de la source : benne prise en compte
ADLoaderJob.DIRECT_RANGE = 80           -- m entre la source et le point de vidage : en direct ; au-delà, par la route
ADLoaderJob.NEAR_START = 40             -- m de la source : travaille sans trajet
ADLoaderJob.ENTRY_WP_RANGE = 80         -- m, point du réseau accepté près de la source ou du point de vidage
ADLoaderJob.HEAP_CELL = 4               -- m, maille de la recherche des tas
ADLoaderJob.HEAP_SCAN_RADIUS = 200      -- m autour du chargeur
ADLoaderJob.HEAP_MARKER_RADIUS = 40     -- m autour de chaque marqueur
ADLoaderJob.HEAP_MIN_LITERS = 500       -- tas plus petit : ignoré
ADLoaderJob.HEAP_FIND_RADIUS = 30       -- m : tas retrouvé autour de sa position enregistrée

local function log(fmt, ...)
    print("[FP-Chargeur] " .. string.format(fmt, ...))
end
ADLoaderJob.log = log

local function call(f, ...)
    if f == nil then
        return false
    end
    if FarmPilotCall ~= nil then
        return FarmPilotCall(f, ...)
    end
    return pcall(f, ...)
end

-- ------------------------------------------------------------------------------------------------------------
-- Réglages du véhicule
-- ------------------------------------------------------------------------------------------------------------
function ADLoaderJob.defaultCfg()
    return { src = ADLoaderJob.SRC_SILO, sx = nil, sz = nil, dst = ADLoaderJob.DST_TRAILER, px = nil, pz = nil, qty = 0 }
end

function ADLoaderJob.cfgToText(cfg)
    local s = cfg.sx ~= nil and cfg.sz ~= nil and string.format("%.2f:%.2f", cfg.sx, cfg.sz) or ""
    local p = cfg.px ~= nil and cfg.pz ~= nil and string.format("%.2f:%.2f", cfg.px, cfg.pz) or ""
    return string.format("%d;%s;%d;%s;%d", cfg.src, s, cfg.dst, p, cfg.qty or 0)
end

function ADLoaderJob.textToCfg(text)
    local cfg = ADLoaderJob.defaultCfg()
    if type(text) ~= "string" or text == "" then
        return cfg
    end
    local parts = {}
    for p in string.gmatch(text .. ";", "([^;]*);") do
        parts[#parts + 1] = p
    end
    cfg.src = tonumber(parts[1]) == ADLoaderJob.SRC_HEAP and ADLoaderJob.SRC_HEAP or ADLoaderJob.SRC_SILO
    local sx, sz = string.match(parts[2] or "", "^([%-%d%.]+):([%-%d%.]+)$")
    cfg.sx, cfg.sz = tonumber(sx), tonumber(sz)
    cfg.dst = tonumber(parts[3]) == ADLoaderJob.DST_POINT and ADLoaderJob.DST_POINT or ADLoaderJob.DST_TRAILER
    local px, pz = string.match(parts[4] or "", "^([%-%d%.]+):([%-%d%.]+)$")
    cfg.px, cfg.pz = tonumber(px), tonumber(pz)
    cfg.qty = math.max(0, tonumber(parts[5]) or 0)
    return cfg
end

function ADLoaderJob.getCfg(vehicle)
    if vehicle.ad.fpLoaderCfg == nil then
        local sm = vehicle.ad.stateModule
        vehicle.ad.fpLoaderCfg = ADLoaderJob.textToCfg(sm ~= nil and sm.fpLoaderCfgText or nil)
    end
    return vehicle.ad.fpLoaderCfg
end

function ADLoaderJob.setCfg(vehicle, cfg)
    vehicle.ad.fpLoaderCfg = cfg
end

-- ------------------------------------------------------------------------------------------------------------
-- Outils : godet, fourche
-- ------------------------------------------------------------------------------------------------------------
function ADLoaderJob.isLoaderTool(o)
    return o ~= nil and o.spec_shovel ~= nil and o.spec_trailer == nil
end

-- godet attelé au véhicule (directement ou par le chargeur frontal), ou nil
function ADLoaderJob.attachedShovel(vehicle)
    if vehicle == nil or AutoDrive == nil or AutoDrive.getAllImplements == nil then
        return nil
    end
    local ok, list = call(AutoDrive.getAllImplements, vehicle, true)
    if not ok or type(list) ~= "table" then
        return nil
    end
    for _, impl in pairs(list) do
        if ADLoaderJob.isLoaderTool(impl) then
            return impl
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Produit
-- ------------------------------------------------------------------------------------------------------------
function ADLoaderJob.fillTypeTitle(ft)
    local desc = ft ~= nil and g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByIndex(ft) or nil
    return desc ~= nil and desc.title or "?"
end

local function litersText(l)
    l = math.floor((l or 0) + 0.5)
    if l >= 1000 then
        return string.format("%d %03d L", math.floor(l / 1000), l % 1000)
    end
    return string.format("%d L", l)
end
ADLoaderJob.litersText = litersText

local function distanceText(d)
    if d >= 1000 then
        return string.format("%.1f km", d / 1000)
    end
    return string.format("%d m", math.floor(d + 0.5))
end
ADLoaderJob.distanceText = distanceText

-- ------------------------------------------------------------------------------------------------------------
-- Silos couloirs
-- ------------------------------------------------------------------------------------------------------------
local function areaOf(silo)
    return silo ~= nil and silo.bunkerSiloArea or nil
end

function ADLoaderJob.areaCenter(area)
    return area.sx + 0.5 * ((area.wx - area.sx) + (area.hx - area.sx)), area.sz + 0.5 * ((area.wz - area.sz) + (area.hz - area.sz))
end

-- produits possibles dans le silo : produit fermenté et produit d'entrée
function ADLoaderJob.siloFillTypes(silo)
    local out = {}
    if silo.outputFillType ~= nil and silo.outputFillType > 0 then
        out[#out + 1] = silo.outputFillType
    end
    if silo.inputFillType ~= nil and silo.inputFillType > 0 and silo.inputFillType ~= silo.outputFillType then
        out[#out + 1] = silo.inputFillType
    end
    return out
end

-- litres dans la zone (parallélogramme), tous les produits donnés
function ADLoaderJob.litersInArea(area, fillTypes)
    local total = 0
    if DensityMapHeightUtil == nil or DensityMapHeightUtil.getFillLevelAtArea == nil then
        return 0
    end
    for _, ft in ipairs(fillTypes) do
        local ok, l = call(DensityMapHeightUtil.getFillLevelAtArea, ft, area.sx, area.sz, area.wx, area.wz, area.hx, area.hz)
        if ok and type(l) == "number" then
            total = total + l
        end
    end
    return total
end

-- silo bâché pas encore ouvert : on ne prend pas dedans
function ADLoaderJob.siloClosed(silo)
    if BunkerSilo == nil or silo.state == nil then
        return false
    end
    return (BunkerSilo.STATE_CLOSED ~= nil and silo.state == BunkerSilo.STATE_CLOSED)
        or (BunkerSilo.STATE_FERMENTED ~= nil and silo.state == BunkerSilo.STATE_FERMENTED)
end

-- produit actuel du silo (celui qui y est vraiment), ou nil
function ADLoaderJob.siloFillType(silo)
    local area = areaOf(silo)
    if area == nil then
        return nil
    end
    for _, ft in ipairs(ADLoaderJob.siloFillTypes(silo)) do
        if ADLoaderJob.litersInArea(area, { ft }) > 0 then
            return ft
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Tas au sol : mailles de HEAP_CELL m qui ont un produit, regroupées en tas ; un tas = un faux silo (zone
-- rectangulaire « bunkerSiloArea » autour du tas, son produit en outputFillType) pour la tâche du chargeur
-- ------------------------------------------------------------------------------------------------------------
local function cellFillType(x, z)
    if DensityMapHeightUtil == nil or DensityMapHeightUtil.getFillTypeAtArea == nil then
        return 0
    end
    local h = ADLoaderJob.HEAP_CELL / 2
    local ok, ft = call(DensityMapHeightUtil.getFillTypeAtArea, x - h, z - h, x + h, z - h, x - h, z + h)
    if ok and type(ft) == "number" then
        return ft
    end
    return 0
end

local function insideBunker(x, z)
    if ADTriggerManager == nil then
        return false
    end
    for _, silo in pairs(ADTriggerManager.getBunkerSilos()) do
        local a = areaOf(silo)
        if a ~= nil and MathUtil.hasRectangleLineIntersection2D ~= nil then
            local ok, hit = call(MathUtil.hasRectangleLineIntersection2D, a.sx, a.sz, a.wx - a.sx, a.wz - a.sz, a.hx - a.sx, a.hz - a.sz, x, z, 0.01, 0.01)
            if ok and hit then
                return true
            end
        end
    end
    return false
end

-- mailles occupées dans un carré centré sur (cx, cz) : cells[i][j] = produit
local function scanCells(cells, cx, cz, radius)
    local c = ADLoaderJob.HEAP_CELL
    local n = math.floor(radius / c)
    local i0, j0 = math.floor(cx / c), math.floor(cz / c)
    for i = i0 - n, i0 + n do
        for j = j0 - n, j0 + n do
            cells[i] = cells[i] or {}
            if cells[i][j] == nil then
                local x, z = (i + 0.5) * c, (j + 0.5) * c
                local ft = cellFillType(x, z)
                if ft ~= nil and ft > 0 and not insideBunker(x, z) then
                    cells[i][j] = ft
                else
                    cells[i][j] = false
                end
            end
        end
    end
end

-- mailles voisines de même produit -> tas { fillType, area, x, z, liters }
local function groupHeaps(cells)
    local c = ADLoaderJob.HEAP_CELL
    local seen, heaps = {}, {}
    for i, row in pairs(cells) do
        for j, ft in pairs(row) do
            local key = i .. ":" .. j
            if ft and not seen[key] then
                local minI, maxI, minJ, maxJ = i, i, j, j
                local stack = { { i, j } }
                seen[key] = true
                while #stack > 0 do
                    local p = table.remove(stack)
                    minI, maxI = math.min(minI, p[1]), math.max(maxI, p[1])
                    minJ, maxJ = math.min(minJ, p[2]), math.max(maxJ, p[2])
                    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                        local ni, nj = p[1] + d[1], p[2] + d[2]
                        local k = ni .. ":" .. nj
                        if not seen[k] and cells[ni] ~= nil and cells[ni][nj] == ft then
                            seen[k] = true
                            stack[#stack + 1] = { ni, nj }
                        end
                    end
                end
                local m = 1 -- marge d'1 m autour du tas
                local area = { sx = minI * c - m, sz = minJ * c - m, wx = (maxI + 1) * c + m, wz = minJ * c - m, hx = minI * c - m, hz = (maxJ + 1) * c + m }
                local liters = ADLoaderJob.litersInArea(area, { ft })
                if liters >= ADLoaderJob.HEAP_MIN_LITERS then
                    local x, z = ADLoaderJob.areaCenter(area)
                    heaps[#heaps + 1] = { fillType = ft, area = area, x = x, z = z, liters = liters }
                end
            end
        end
    end
    return heaps
end

-- tas autour du véhicule et des marqueurs
function ADLoaderJob.scanHeaps(vehicle)
    local cells = {}
    if vehicle ~= nil and vehicle.components ~= nil then
        local x, _, z = getWorldTranslation(vehicle.components[1].node)
        scanCells(cells, x, z, ADLoaderJob.HEAP_SCAN_RADIUS)
    end
    if ADGraphManager ~= nil then
        for _, m in pairs(ADGraphManager:getMapMarkers() or {}) do
            local wp = m ~= nil and ADGraphManager:getWayPointById(m.id) or nil
            if wp ~= nil then
                scanCells(cells, wp.x, wp.z, ADLoaderJob.HEAP_MARKER_RADIUS)
            end
        end
    end
    return groupHeaps(cells)
end

-- tas retrouvé autour de (x, z), le plus proche
function ADLoaderJob.findHeap(x, z)
    if x == nil or z == nil then
        return nil
    end
    local cells = {}
    scanCells(cells, x, z, ADLoaderJob.HEAP_FIND_RADIUS)
    local best, bestD = nil, math.huge
    for _, h in ipairs(groupHeaps(cells)) do
        local d = MathUtil.vector2Length(h.x - x, h.z - z)
        if d < bestD then
            best, bestD = h, d
        end
    end
    return best
end

-- faux silo pour la tâche (Tasks/LoaderTask.lua)
function ADLoaderJob.heapBunker(heap)
    return { bunkerSiloArea = heap.area, outputFillType = heap.fillType, inputFillType = heap.fillType, fpHeap = true }
end

-- ------------------------------------------------------------------------------------------------------------
-- Sources : { kind, silo|heap, x, z, fillType, liters, number }
-- ------------------------------------------------------------------------------------------------------------
function ADLoaderJob.siloSource(silo)
    local area = areaOf(silo)
    if area == nil then
        return nil
    end
    local x, z = ADLoaderJob.areaCenter(area)
    local ft = ADLoaderJob.siloFillType(silo) or silo.outputFillType
    local liters = ADLoaderJob.litersInArea(area, ADLoaderJob.siloFillTypes(silo))
    local number = ADSiloJob ~= nil and ADSiloJob.siloNumber ~= nil and ADSiloJob.siloNumber(silo) or 0
    return { kind = ADLoaderJob.SRC_SILO, silo = silo, bunker = silo, x = x, z = z, fillType = ft, liters = liters, number = number }
end

function ADLoaderJob.heapSource(heap)
    return { kind = ADLoaderJob.SRC_HEAP, heap = heap, bunker = ADLoaderJob.heapBunker(heap), x = heap.x, z = heap.z, fillType = heap.fillType, liters = heap.liters }
end

function ADLoaderJob.sources(vehicle)
    local out = {}
    if ADTriggerManager ~= nil then
        for _, silo in pairs(ADTriggerManager.getBunkerSilos()) do
            local s = ADLoaderJob.siloSource(silo)
            if s ~= nil then
                out[#out + 1] = s
            end
        end
    end
    for _, h in ipairs(ADLoaderJob.scanHeaps(vehicle)) do
        out[#out + 1] = ADLoaderJob.heapSource(h)
    end
    local vx, vz = 0, 0
    if vehicle ~= nil and vehicle.components ~= nil then
        local x, _, z = getWorldTranslation(vehicle.components[1].node)
        vx, vz = x, z
    end
    for _, s in ipairs(out) do
        s.dist = MathUtil.vector2Length(s.x - vx, s.z - vz)
    end
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then
            return a.kind < b.kind
        end
        if a.kind == ADLoaderJob.SRC_SILO then
            return a.number < b.number
        end
        return a.dist < b.dist
    end)
    return out
end

-- source enregistrée (réglage), retrouvée sur la carte ; nil si elle n'existe plus
function ADLoaderJob.selectedSource(vehicle)
    local cfg = ADLoaderJob.getCfg(vehicle)
    if cfg.sx == nil or cfg.sz == nil then
        return nil
    end
    if cfg.src == ADLoaderJob.SRC_SILO then
        if ADTriggerManager == nil then
            return nil
        end
        for _, silo in pairs(ADTriggerManager.getBunkerSilos()) do
            local a = areaOf(silo)
            if a ~= nil then
                local x, z = ADLoaderJob.areaCenter(a)
                if MathUtil.vector2Length(x - cfg.sx, z - cfg.sz) < 1 then
                    return ADLoaderJob.siloSource(silo)
                end
            end
        end
        return nil
    end
    local heap = ADLoaderJob.findHeap(cfg.sx, cfg.sz)
    return heap ~= nil and ADLoaderJob.heapSource(heap) or nil
end

function ADLoaderJob.sourceLabel(s, withDist)
    local label
    if s.kind == ADLoaderJob.SRC_SILO then
        label = string.format(g_i18n:getText("gui_ad_loader_srcSilo"), s.number, ADLoaderJob.fillTypeTitle(s.fillType), litersText(s.liters))
    else
        label = string.format(g_i18n:getText("gui_ad_loader_srcHeap"), ADLoaderJob.fillTypeTitle(s.fillType), litersText(s.liters))
    end
    if withDist and s.dist ~= nil then
        label = label .. " - " .. distanceText(s.dist)
    end
    return label
end

-- ------------------------------------------------------------------------------------------------------------
-- Points de vidage du jeu (pas les silos couloirs) qui prennent le produit
-- ------------------------------------------------------------------------------------------------------------
function ADLoaderJob.pointName(trigger)
    local names = {
        function() return trigger.target ~= nil and trigger.target.getName ~= nil and trigger.target:getName() or nil end,
        function() return trigger.owningPlaceable ~= nil and trigger.owningPlaceable.getName ~= nil and trigger.owningPlaceable:getName() or nil end,
        function() return trigger.getName ~= nil and trigger:getName() or nil end,
        function() return trigger.stationName end,
    }
    for _, f in ipairs(names) do
        local ok, n = call(f)
        if ok and type(n) == "string" and n ~= "" then
            return n
        end
    end
    local x, _, z = ADTriggerManager.getTriggerPos(trigger)
    return string.format("%s (%d, %d)", g_i18n:getText("gui_ad_loader_point"), math.floor(x), math.floor(z))
end

-- { trigger, x, z, name, dist (à la source) }
function ADLoaderJob.points(fillType, sx, sz)
    local out = {}
    if ADTriggerManager == nil or fillType == nil or fillType <= 0 then
        return out
    end
    for _, t in pairs(ADTriggerManager.getAllTriggersForFillType(fillType)) do
        if t.bunkerSiloArea == nil then
            local x, _, z = ADTriggerManager.getTriggerPos(t)
            if x ~= 0 or z ~= 0 then
                out[#out + 1] = { trigger = t, x = x, z = z, name = ADLoaderJob.pointName(t), dist = (sx ~= nil and MathUtil.vector2Length(x - sx, z - sz) or 0) }
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

function ADLoaderJob.findPoint(px, pz)
    if px == nil or pz == nil or ADTriggerManager == nil then
        return nil
    end
    for _, t in pairs(ADTriggerManager.getUnloadTriggers()) do
        if t.bunkerSiloArea == nil then
            local x, _, z = ADTriggerManager.getTriggerPos(t)
            if MathUtil.vector2Length(x - px, z - pz) < 1 then
                return t
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Réseau : point le plus proche d'une position (source, point de vidage)
-- ------------------------------------------------------------------------------------------------------------
function ADLoaderJob.nearestWayPoint(x, z, range)
    local best, bestD = nil, range or ADLoaderJob.ENTRY_WP_RANGE
    if ADGraphManager == nil then
        return nil
    end
    for id, wp in pairs(ADGraphManager:getWayPoints()) do
        if wp ~= nil and wp.x ~= nil then
            local d = MathUtil.vector2Length(wp.x - x, wp.z - z)
            if d < bestD then
                best, bestD = wp.id or id, d
            end
        end
    end
    return best, bestD
end

-- ------------------------------------------------------------------------------------------------------------
-- Raison du refus au départ, ou nil
-- ------------------------------------------------------------------------------------------------------------
function ADLoaderJob.refusal(vehicle, source)
    local cfg = ADLoaderJob.getCfg(vehicle)
    if source == nil then
        return "gui_ad_loader_noSource"
    end
    if source.kind == ADLoaderJob.SRC_SILO and ADLoaderJob.siloClosed(source.silo) then
        return "gui_ad_loader_siloClosed"
    end
    if (source.liters or 0) <= 0 then
        return "gui_ad_loader_empty"
    end
    if cfg.dst == ADLoaderJob.DST_POINT and ADLoaderJob.findPoint(cfg.px, cfg.pz) == nil then
        return "gui_ad_loader_noPoint"
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Sauvegarde : réglages (#fpLoaderCfg) et travail en cours (#fpLoaderJob = litres déjà vidés)
-- ------------------------------------------------------------------------------------------------------------
if ADSavegameResume ~= nil then
    local baseSave = ADSavegameResume.save
    function ADSavegameResume.save(stateModule, xmlFile, key, ...)
        if baseSave ~= nil then
            baseSave(stateModule, xmlFile, key, ...)
        end
        call(function()
            local v = stateModule.vehicle
            if v == nil or v.ad == nil then
                return
            end
            if v.ad.fpLoaderCfg ~= nil then
                xmlFile:setValue(key .. "#fpLoaderCfg", ADLoaderJob.cfgToText(v.ad.fpLoaderCfg))
            elseif stateModule.fpLoaderCfgText ~= nil then
                xmlFile:setValue(key .. "#fpLoaderCfg", stateModule.fpLoaderCfgText)
            end
            local job = v.ad.fpLoaderJob
            if job ~= nil and stateModule.active then
                xmlFile:setValue(key .. "#fpLoaderJob", string.format("%d", math.floor(job.done or 0)))
            elseif stateModule.fpLoaderJobText ~= nil then
                xmlFile:setValue(key .. "#fpLoaderJob", stateModule.fpLoaderJobText) -- pas encore reparti depuis le chargement
            end
        end)
    end

    local baseLoad = ADSavegameResume.load
    function ADSavegameResume.load(stateModule, xmlFile, key, ...)
        if baseLoad ~= nil then
            baseLoad(stateModule, xmlFile, key, ...)
        end
        local function read(name)
            local ok, value = call(xmlFile.getValue, xmlFile, key .. "#" .. name)
            if ok and type(value) == "string" and value ~= "" then
                return value
            end
            return nil
        end
        stateModule.fpLoaderCfgText = read("fpLoaderCfg")
        stateModule.fpLoaderJobText = read("fpLoaderJob")
    end
end
