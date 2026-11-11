-- ============================================================================================================
-- FarmPilot : RefillSources.lua
-- Fenêtres « Réglages du semoir » et « Réglages de l'épandeur » : la liste des zones de ravitaillement ne montre
-- que les marqueurs où l'on peut prendre le produit choisi.
--
-- (08/11) Les points de remplissage proposés dans le menu : soit sauvegardés par outil, soit cherchés avant d'être
-- proposés, pour ne montrer que ceux où l'outil peut prendre le produit demandé. Choix retenu : la recherche
-- (voir la règle ci-dessous).
--
-- Règle :
-- - Sources du produit : zones de chargement du jeu (stations, silos, magasins, stockages qui le fournissent et
--   en ont en stock), et big bags / IBC / palettes posés qui en contiennent (on s'y remplit comme le joueur).
-- - Un marqueur est proposé s'il est à moins de RADIUS m d'une source d'au moins un des produits choisis.
-- - Le marqueur déjà choisi reste toujours dans la liste.
-- - Aucun marqueur trouvé : la liste montre tout, comme avant, et le dit.
-- - Le dernier choix de l'outil est déjà proposé en premier (SeederManager / SprayerManager : lastFor).
-- Branché par deux lignes dans SeederSettingsGUI.lua et SprayerSettingsGUI.lua (refreshItems, mode « markers »).
-- ============================================================================================================

ADRefillSources = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADRefillSources.RADIUS = 50          -- m entre le marqueur et la zone de chargement / le big bag

local function safe(f, ...)
    local ok, a, b, c = FarmPilotCall(f, ...)
    if ok then
        return a, b, c
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Sources : zones de chargement du jeu
-- ------------------------------------------------------------------------------------------------------------
--[==[ Mis de côté (09/11) : remplacé par triggerCheck (stock lu par getAllFillLevels, raison du rejet pour le log)
local function triggerProvides(trigger, ft, farmId)
    if trigger == nil then
        return false
    end
    if trigger.fillTypes ~= nil and not trigger.fillTypes[ft] then
        return false
    end
    local source = trigger.source
    if source == nil then
        return trigger.fillTypes ~= nil and trigger.fillTypes[ft] == true
    end
    if source.getProvidedFillTypes ~= nil then
        local provided = safe(source.getProvidedFillTypes, source)
        if type(provided) == "table" and not provided[ft] then
            return false
        end
    end
    if source.getFillLevel ~= nil then
        local level = safe(source.getFillLevel, source, ft, farmId)
        if type(level) == "number" and level <= 0 then
            return false
        end
    end
    return true
end
]==]

-- (09/11) true, ou false et la raison. Stock lu comme le jeu (LoadTrigger:toggleLoading) : getAllFillLevels(farmId).
-- FS25 : LoadingStation n'a pas getProvidedFillTypes ; un point d'achat (BuyingStation) n'a pas de stockage,
-- son getFillLevel vaut 0 et son getAllFillLevels donne 1 par produit vendu.
local function triggerCheck(trigger, ft, farmId)
    if trigger == nil then
        return false, "zone absente"
    end
    if trigger.fillTypes ~= nil and not trigger.fillTypes[ft] then
        return false, "non chargé ici"
    end
    local source = trigger.source
    if source == nil then
        if trigger.fillTypes ~= nil and trigger.fillTypes[ft] == true then
            return true
        end
        return false, "sans source"
    end
    -- sources de mods qui donnent la liste de leurs produits
    if source.getProvidedFillTypes ~= nil then
        local provided = safe(source.getProvidedFillTypes, source)
        if type(provided) == "table" and not provided[ft] then
            return false, "non fourni"
        end
    end
    if source.getAllFillLevels ~= nil then
        local levels = safe(source.getAllFillLevels, source, farmId)
        if type(levels) == "table" then
            local level = levels[ft]
            if level == nil then
                return false, next(levels) == nil and "aucun stock pour la ferme" or "pas dans le stock"
            end
            if type(level) == "number" and level <= 0 then
                return false, "stock vide"
            end
            return true
        end
    end
    if source.getFillLevel ~= nil then
        local level = safe(source.getFillLevel, source, ft, farmId)
        if type(level) == "number" and level <= 0 then
            return false, "stock vide"
        end
    end
    return true
end

-- { {x, z, kind} } pour ces produits (index), vus par cette ferme
function ADRefillSources.find(fillTypes, farmId)
    local out = {}
    if ADTriggerManager ~= nil and ADTriggerManager.getLoadTriggers ~= nil then
        for _, trigger in pairs(safe(ADTriggerManager.getLoadTriggers) or {}) do
            for _, ft in ipairs(fillTypes) do
                if triggerCheck(trigger, ft, farmId) then
                    local x, _, z = safe(ADTriggerManager.getTriggerPos, trigger)
                    if x ~= nil and (x ~= 0 or z ~= 0) then
                        out[#out + 1] = { x = x, z = z, kind = "station" }
                    end
                    break
                end
            end
        end
    end
    -- big bags, IBC, palettes : objets à remplissage (FillTriggerVehicle) qui contiennent le produit
    local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    for _, v in pairs(vs ~= nil and vs.vehicles or {}) do
        if v ~= nil and not v.isDeleted and v.spec_fillTriggerVehicle ~= nil and v.getFillUnits ~= nil and v.rootNode ~= nil then
            local mine = farmId == nil or v.getOwnerFarmId == nil or v:getOwnerFarmId() == farmId or v:getOwnerFarmId() == 0
            if mine then
                for i, _ in ipairs(safe(v.getFillUnits, v) or {}) do
                    local ft = safe(v.getFillUnitFillType, v, i)
                    local level = safe(v.getFillUnitFillLevel, v, i) or 0
                    local wanted = false
                    for _, f in ipairs(fillTypes) do
                        if f == ft then
                            wanted = true
                        end
                    end
                    if wanted and level > 0 then
                        local x, _, z = getWorldTranslation(v.rootNode)
                        out[#out + 1] = { x = x, z = z, kind = "bigbag" }
                        break
                    end
                end
            end
        end
    end
    return out
end

-- ------------------------------------------------------------------------------------------------------------
-- Marqueurs proches d'une source
-- ------------------------------------------------------------------------------------------------------------
-- { [nom du marqueur] = true }
function ADRefillSources.markersNear(sources)
    local allowed = {}
    if #sources == 0 then
        return allowed
    end
    local r2 = ADRefillSources.RADIUS * ADRefillSources.RADIUS
    for _, m in pairs(ADGraphManager:getMapMarkers() or {}) do
        local wp = m ~= nil and m.name ~= nil and ADGraphManager:getWayPointById(m.id) or nil
        if wp ~= nil and wp.x ~= nil then
            for _, s in ipairs(sources) do
                local dx, dz = wp.x - s.x, wp.z - s.z
                if dx * dx + dz * dz <= r2 then
                    allowed[m.name] = true
                    break
                end
            end
        end
    end
    return allowed
end

-- ------------------------------------------------------------------------------------------------------------
-- (09/11) Log de contrôle : une ligne par ouverture de fenêtre, zones de chargement proches des marqueurs
-- ------------------------------------------------------------------------------------------------------------
ADRefillSources.LOG_RADIUS = 60      -- m : zones écrites dans le log
ADRefillSources.LOG_MAX = 12         -- zones au plus dans la ligne
ADRefillSources.LOG_MARKERS = 3      -- marqueurs nommés au plus par zone

local loggedCtx = nil                -- contexte de fenêtre déjà écrit dans le log

-- names : noms des produits, dans l'ordre de fillTypes ; nAllowed : marqueurs proposés (0 = liste complète)
function ADRefillSources.report(fillTypes, names, farmId, nAllowed)
    local r2 = ADRefillSources.LOG_RADIUS * ADRefillSources.LOG_RADIUS
    local marks = {}
    for _, m in pairs(ADGraphManager:getMapMarkers() or {}) do
        local wp = m ~= nil and m.name ~= nil and ADGraphManager:getWayPointById(m.id) or nil
        if wp ~= nil and wp.x ~= nil then
            marks[#marks + 1] = { name = m.name, x = wp.x, z = wp.z }
        end
    end
    local zones, nTriggers = {}, 0
    for _, trigger in pairs(safe(ADTriggerManager.getLoadTriggers) or {}) do
        nTriggers = nTriggers + 1
        local x, _, z = safe(ADTriggerManager.getTriggerPos, trigger)
        if x ~= nil and (x ~= 0 or z ~= 0) then
            -- marqueurs à moins de LOG_RADIUS, du plus proche au plus loin
            local near = {}
            for _, mk in ipairs(marks) do
                local dx, dz = mk.x - x, mk.z - z
                local d2 = dx * dx + dz * dz
                if d2 <= r2 then
                    near[#near + 1] = { name = tostring(mk.name), d = math.sqrt(d2) }
                end
            end
            if #near > 0 then
                table.sort(near, function(a, b)
                    if a.d ~= b.d then
                        return a.d < b.d
                    end
                    return a.name < b.name
                end)
                local d = near[1].d
                local named = {}
                for i = 1, math.min(#near, ADRefillSources.LOG_MARKERS) do
                    named[#named + 1] = string.format("%s %d m", near[i].name, math.floor(near[i].d + 0.5))
                end
                if #near > ADRefillSources.LOG_MARKERS then
                    named[#named + 1] = string.format("+%d", #near - ADRefillSources.LOG_MARKERS)
                end
                local kept, parts = false, {}
                for i, ft in ipairs(fillTypes) do
                    local ok, why = triggerCheck(trigger, ft, farmId)
                    if ok and d > ADRefillSources.RADIUS then
                        ok, why = false, string.format("marqueur à plus de %d m", ADRefillSources.RADIUS)
                    end
                    kept = kept or ok
                    parts[#parts + 1] = tostring(names[i]) .. (ok and " gardée" or (" rejetée (" .. tostring(why) .. ")"))
                end
                local source = trigger.source
                local zoneName = source ~= nil and source.getName ~= nil and safe(source.getName, source) or nil
                zones[#zones + 1] = { kept = kept, d = d, text = string.format("%s%s : %s", table.concat(named, ", "),
                    zoneName ~= nil and (" (" .. tostring(zoneName) .. ")") or "", table.concat(parts, ", ")) }
            end
        end
    end
    -- zones gardées d'abord, puis les plus proches
    table.sort(zones, function(a, b)
        if a.kept ~= b.kept then
            return a.kept
        end
        return a.d < b.d
    end)
    local out = {}
    for i = 1, math.min(#zones, ADRefillSources.LOG_MAX) do
        out[#out + 1] = zones[i].text
    end
    if #zones > ADRefillSources.LOG_MAX then
        out[#out + 1] = string.format("+%d autres", #zones - ADRefillSources.LOG_MAX)
    end
    local body = #out > 0 and table.concat(out, " | ") or string.format("aucune à moins de %d m d'un marqueur", ADRefillSources.LOG_RADIUS)
    local result = nAllowed > 0 and string.format("%d marqueur(s) proposé(s)", nAllowed) or "liste complète"
    return string.format("[FarmPilot Plein] %s, ferme %s, %d zones de chargement : %s => %s",
        table.concat(names, ", "), tostring(farmId), nTriggers, body, result)
end

-- ------------------------------------------------------------------------------------------------------------
-- Hook des fenêtres : liste filtrée et texte d'info
-- ------------------------------------------------------------------------------------------------------------
-- noms des produits choisis dans la fenêtre (semoir : plusieurs ; épandeur : un)
local function draftProducts(gui)
    local d = gui.draft
    if d == nil then
        return {}
    end
    if d.fillType ~= nil then
        return { d.fillType }
    end
    return d.fillTypes or {}
end

local function farmOf(object)
    if object ~= nil and object.getOwnerFarmId ~= nil then
        local id = safe(object.getOwnerFarmId, object)
        if id ~= nil and id ~= 0 then
            return id
        end
    end
    return nil
end

-- (09/11) ferme de l'outil. Le contexte du semoir n'a pas de « vehicle » (ADSeederManager.context), celui de
-- l'épandeur en a un : farmId restait nil pour le semoir, et le jeu (AccessHandler:canFarmAccess) ne compte alors
-- que les stockages de tout le monde. Les silos achetés par la ferme étaient donc vus vides.
local function ownerFarm(gui)
    local ctx = gui.ctx or {}
    local id = farmOf(ctx.vehicle) or farmOf(ctx.tool)
    if id == nil and g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        id = safe(g_currentMission.getFarmId, g_currentMission)
    end
    return id
end

-- allowed (nil = tout montrer), texte à ajouter à l'info
function ADRefillSources.filter(gui)
    local names = draftProducts(gui)
    local indexes, titles, ftNames = {}, {}, {}
    for _, n in ipairs(names) do
        local idx = g_fillTypeManager:getFillTypeIndexByName(n)
        if idx ~= nil then
            indexes[#indexes + 1] = idx
            ftNames[#ftNames + 1] = n
            local ft = g_fillTypeManager:getFillTypeByIndex(idx)
            titles[#titles + 1] = (ft ~= nil and ft.title) or n
        end
    end
    if #indexes == 0 then
        return nil, nil
    end
    --[==[ Mis de côté (09/11) : ctx.vehicle n'existe que pour l'épandeur, voir ownerFarm
    local vehicle = gui.ctx ~= nil and gui.ctx.vehicle or nil
    local farmId = vehicle ~= nil and vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
    ]==]
    local farmId = ownerFarm(gui)
    local okF, sources = FarmPilotCall(ADRefillSources.find, indexes, farmId)
    if not okF then
        print("[FarmPilot Plein] ERREUR recherche des zones : " .. tostring(sources))
        return nil, nil
    end
    local allowed = ADRefillSources.markersNear(sources)
    -- (09/11) log de contrôle : à la première liste de chaque ouverture (le contexte est refait à chaque ouverture)
    local key = gui.ctx or gui
    if loggedCtx ~= key then
        loggedCtx = key
        local nAllowed = 0
        for _ in pairs(allowed) do
            nAllowed = nAllowed + 1
        end
        local okR, line = FarmPilotCall(ADRefillSources.report, indexes, ftNames, farmId, nAllowed)
        if okR and line ~= nil then
            print(line)
        end
    end
    local label = table.concat(titles, ", ")
    if next(allowed) == nil then
        return nil, string.format(g_i18n:getText("gui_ad_refill_noneFound"), label)
    end
    if gui.draft ~= nil and gui.draft.refill ~= nil then
        allowed[gui.draft.refill] = true
    end
    return allowed, string.format(g_i18n:getText("gui_ad_refill_filtered"), label)
end
