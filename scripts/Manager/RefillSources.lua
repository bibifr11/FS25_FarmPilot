-- ============================================================================================================
-- FarmPilot : RefillSources.lua
-- Fenêtres « Réglages du semoir » et « Réglages de l'épandeur » : la liste des zones de ravitaillement ne montre
-- que les marqueurs où l'on peut prendre le produit choisi.
--
-- Demande Fabien 08/11 21:24 : « Les points de sélection dans le menu pour remplir doivent soit être sauvegardés
-- par outil, soit cherchés avant de proposer les points où il peut prendre le matériau demandé. À toi de voir le
-- plus facile à mettre en place. »
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
    local ok, a, b, c = pcall(f, ...)
    if ok then
        return a, b, c
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Sources : zones de chargement du jeu
-- ------------------------------------------------------------------------------------------------------------
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

-- { {x, z, kind} } pour ces produits (index), vus par cette ferme
function ADRefillSources.find(fillTypes, farmId)
    local out = {}
    if ADTriggerManager ~= nil and ADTriggerManager.getLoadTriggers ~= nil then
        for _, trigger in pairs(safe(ADTriggerManager.getLoadTriggers) or {}) do
            for _, ft in ipairs(fillTypes) do
                if triggerProvides(trigger, ft, farmId) then
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

-- allowed (nil = tout montrer), texte à ajouter à l'info
function ADRefillSources.filter(gui)
    local names = draftProducts(gui)
    local indexes, titles = {}, {}
    for _, n in ipairs(names) do
        local idx = g_fillTypeManager:getFillTypeIndexByName(n)
        if idx ~= nil then
            indexes[#indexes + 1] = idx
            local ft = g_fillTypeManager:getFillTypeByIndex(idx)
            titles[#titles + 1] = (ft ~= nil and ft.title) or n
        end
    end
    if #indexes == 0 then
        return nil, nil
    end
    local vehicle = gui.ctx ~= nil and gui.ctx.vehicle or nil
    local farmId = vehicle ~= nil and vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
    local okF, sources = pcall(ADRefillSources.find, indexes, farmId)
    if not okF then
        print("[FarmPilot Plein] ERREUR recherche des zones : " .. tostring(sources))
        return nil, nil
    end
    local allowed = ADRefillSources.markersNear(sources)
    local label = table.concat(titles, ", ")
    if next(allowed) == nil then
        return nil, string.format(g_i18n:getText("gui_ad_refill_noneFound"), label)
    end
    if gui.draft ~= nil and gui.draft.refill ~= nil then
        allowed[gui.draft.refill] = true
    end
    return allowed, string.format(g_i18n:getText("gui_ad_refill_filtered"), label)
end
