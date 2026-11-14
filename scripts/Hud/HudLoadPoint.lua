-- ============================================================================================================
-- FarmPilot : HudLoadPoint.lua
-- Modes « Chargement et livraison » et « Chargement » : produits du point de chargement, puis remorque adaptée.
--
-- (13/11) Quand le point de chargement est choisi, la liste des produits doit déjà montrer ce qu'on peut y
-- charger ; ensuite une remorque compatible ; pas de remorque compatible : « Pas de remorque adaptée » et pas de
-- départ ; remorque compatible : le départ se fait.
--
-- Règle :
-- - Ligne des produits (3e ligne) : point de chargement choisi (1re ligne) avec des zones de chargement à moins de
--   RADIUS m qui ont du stock pour la ferme (silos, stockages, points d'achat) : la liste montre ces produits,
--   remorque attelée ou pas. Sinon (point sans zone connue, remorque Autoload) : la liste d'avant (produits que
--   la remorque attelée prend). La liste est refaite à chaque ouverture.
-- - Remorque adaptée = qui prend chacun des produits choisis.
-- - Ligne « Remorque » (produit choisi) :
--   remorque choisie adaptée : « Remorque : <nom> » ; pas adaptée : « Pas de remorque adaptée » ;
--   rien de choisi : véhicule ou remorque attelée adaptés = comme avant ; remorque attelée pas adaptée : « Pas de
--   remorque adaptée » ; rien d'attelé : la plus proche des remorques dételées adaptées,
--   attelée au départ : « Remorque : <nom> (adaptée, à atteler) » ; aucune : « Pas de remorque adaptée ».
--   La liste de la ligne ne montre que les remorques adaptées.
-- - Départ (Go) : pas de remorque adaptée = départ refusé, message ; la plus proche adaptée = le tracteur va
--   l'atteler (TrailerHitch.lua), puis le mode démarre.
-- - Aucun produit choisi, ou remorque Autoload (palettes, balles) : rien ne change.
--
-- - Choix du produit : le jeu n'acceptait que les produits de la remorque attelée ; ceux du point sont acceptés.
--
-- Branché par une ligne chacune : PullDownList.lua (createSelection_FillType, expand, createSelection_FpTool,
-- getNewState_FillType), StateModule.lua (setFillType, setSelectedFillTypes) et TrailerHitch.lua (beforeStart). Chargé par register.lua après TrailerHitch.lua.
-- ============================================================================================================

ADLoadPoint = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADLoadPoint.RADIUS = 50          -- m entre le marqueur et la zone de chargement
ADLoadPoint.MODES = {            -- modes qui chargent
    [AutoDrive.MODE_PICKUPANDDELIVER] = true,
    [AutoDrive.MODE_LOAD] = true
}

local function safe(f, ...)
    if f == nil then
        return nil
    end
    local ok, a, b, c = FarmPilotCall(f, ...)
    if ok then
        return a, b, c
    end
    return nil
end

local function farmOf(vehicle)
    local f = vehicle ~= nil and vehicle.getOwnerFarmId ~= nil and safe(vehicle.getOwnerFarmId, vehicle) or nil
    if f == nil or f == 0 then
        f = g_currentMission ~= nil and g_currentMission.getFarmId ~= nil and safe(g_currentMission.getFarmId, g_currentMission) or nil
    end
    return f
end

local function isLoadMode(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    return sm ~= nil and ADLoadPoint.MODES[sm:getMode()] == true
end

-- ------------------------------------------------------------------------------------------------------------
-- Produits du point de chargement
-- ------------------------------------------------------------------------------------------------------------
-- produits de cette zone avec du stock pour la ferme : { [ft] = true }
local function triggerProducts(trigger, farmId, out)
    local source = trigger ~= nil and trigger.source or nil
    local levels = source ~= nil and safe(source.getAllFillLevels, source, farmId) or nil
    if trigger.fillTypes ~= nil then
        for ft, on in pairs(trigger.fillTypes) do
            if on and type(ft) == "number" then
                local level = type(levels) == "table" and levels[ft] or nil
                if levels == nil or (type(level) == "number" and level > 0) then
                    out[ft] = true
                end
            end
        end
    elseif type(levels) == "table" then
        for ft, level in pairs(levels) do
            if type(level) == "number" and level > 0 then
                out[ft] = true
            end
        end
    end
end

-- liste des produits (index) qu'on peut charger au marqueur ; vide si aucune zone connue
function ADLoadPoint.productsAt(marker, farmId)
    local list = {}
    local wp = marker ~= nil and marker.id ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp == nil or wp.x == nil or ADTriggerManager == nil or ADTriggerManager.getLoadTriggers == nil then
        return list
    end
    local set = {}
    for _, trigger in pairs(safe(ADTriggerManager.getLoadTriggers) or {}) do
        local x, _, z = safe(ADTriggerManager.getTriggerPos, trigger)
        if x ~= nil and (x ~= 0 or z ~= 0) and (x - wp.x) ^ 2 + (z - wp.z) ^ 2 <= ADLoadPoint.RADIUS ^ 2 then
            FarmPilotCall(triggerProducts, trigger, farmId, set)
        end
    end
    for ft, _ in pairs(set) do
        if ft ~= (FillType ~= nil and FillType.UNKNOWN or 0) then
            list[#list + 1] = ft
        end
    end
    table.sort(list)
    return list
end

-- produits du point de chargement choisi (1re ligne), ou nil (pas un mode qui charge, pas de point, aucune zone)
function ADLoadPoint.productsOfVehicle(vehicle)
    if not isLoadMode(vehicle) then
        return nil
    end
    local marker = vehicle.ad.stateModule:getFirstMarker()
    if marker == nil or marker == 0 then
        return nil
    end
    local list = ADLoadPoint.productsAt(marker, farmOf(vehicle))
    if #list == 0 then
        return nil
    end
    return list
end

-- ------------------------------------------------------------------------------------------------------------
-- Remorque adaptée
-- ------------------------------------------------------------------------------------------------------------
-- produits choisis (index), vide si aucun
function ADLoadPoint.selected(vehicle)
    local sm = vehicle.ad.stateModule
    local out = {}
    local all = AutoDrive.UAL_FILLTYPE_ALL
    for _, ft in ipairs(sm.getSelectedFillTypes ~= nil and sm:getSelectedFillTypes() or {}) do
        if type(ft) == "number" and ft > 0 and ft ~= all then
            out[#out + 1] = ft
        end
    end
    if #out == 0 then
        local ft = sm:getFillType()
        if type(ft) == "number" and ft > 0 and ft ~= all and ft ~= (FillType ~= nil and FillType.UNKNOWN or 0) then
            out[1] = ft
        end
    end
    return out
end

local function supports(o, ft)
    if o == nil or o.getFillUnits == nil then
        return false
    end
    for i, _ in ipairs(safe(o.getFillUnits, o) or {}) do
        if o.getFillUnitSupportsFillType ~= nil and safe(o.getFillUnitSupportsFillType, o, i, ft) then
            return true
        end
        local s = o.getFillUnitSupportedFillTypes ~= nil and safe(o.getFillUnitSupportedFillTypes, o, i) or nil
        if type(s) == "table" and s[ft] then
            return true
        end
    end
    return false
end

-- la remorque (ou l'une des remorques de la liste) prend-elle chacun des produits ?
function ADLoadPoint.fits(objects, fts)
    for _, ft in ipairs(fts) do
        local ok = false
        for _, o in ipairs(objects) do
            if supports(o, ft) then
                ok = true
                break
            end
        end
        if not ok then
            return false
        end
    end
    return true
end

local function attachedObjects(vehicle)
    local list = {}
    if ADTrailerHitch ~= nil and ADTrailerHitch.attachedTrailers ~= nil then
        list = safe(ADTrailerHitch.attachedTrailers, vehicle) or {}
    end
    return list
end

-- remorques dételées adaptées, la plus proche d'abord ({ tool, name, distance })
function ADLoadPoint.fittingTrailers(vehicle, fts)
    local out = {}
    for _, e in ipairs(safe(ADTrailerHitch.fetchableTrailers, vehicle) or {}) do
        if ADLoadPoint.fits({ e.tool }, fts) then
            out[#out + 1] = e
        end
    end
    return out
end

-- nil (rien à contrôler) ou { ok, how = "chosen" | "attached" | "nearest", trailer, why = "chosenUnfit" | "attachedUnfit" | "none", fts }
function ADLoadPoint.verdict(vehicle)
    if not isLoadMode(vehicle) or ADTrailerHitch == nil then
        return nil
    end
    local fts = ADLoadPoint.selected(vehicle)
    if #fts == 0 then
        return nil
    end
    local sm = vehicle.ad.stateModule
    local chosen = sm.getFpTrailer ~= nil and sm:getFpTrailer() or nil
    -- remorque Autoload (palettes, balles) : ses produits ne sont pas des cuves, rien à contrôler
    if vehicle.ad.hasAL or (chosen ~= nil and AutoDrive.hasAL ~= nil and safe(AutoDrive.hasAL, AutoDrive, chosen)) then
        return nil
    end
    if chosen ~= nil then
        if ADLoadPoint.fits({ chosen }, fts) then
            return { ok = true, how = "chosen", trailer = chosen, fts = fts }
        end
        return { ok = false, why = "chosenUnfit", trailer = chosen, fts = fts }
    end
    -- le véhicule lui-même (camion, automoteur) et tout ce qui est attelé, remorques derrière remorques comprises
    local carriers = { vehicle }
    for _, o in ipairs(safe(AutoDrive.getAllImplements, vehicle, false) or {}) do
        if o ~= vehicle then
            carriers[#carriers + 1] = o
        end
    end
    if ADLoadPoint.fits(carriers, fts) then
        return { ok = true, how = "attached", fts = fts }
    end
    local attached = attachedObjects(vehicle)
    if #attached > 0 then
        return { ok = false, why = "attachedUnfit", trailer = attached[1], fts = fts }
    end
    local list = ADLoadPoint.fittingTrailers(vehicle, fts)
    if #list > 0 then
        return { ok = true, how = "nearest", trailer = list[1].tool, fts = fts }
    end
    return { ok = false, why = "none", fts = fts }
end

local function productNames(fts)
    local names = {}
    for _, ft in ipairs(fts or {}) do
        local t = g_fillTypeManager:getFillTypeByIndex(ft)
        names[#names + 1] = t ~= nil and t.title or tostring(ft)
    end
    return table.concat(names, ", ")
end

-- ------------------------------------------------------------------------------------------------------------
-- HUD
-- ------------------------------------------------------------------------------------------------------------
-- PullDownList.lua, createSelection_FillType : produits du point au lieu de ceux de la remorque (nil = comme avant)
function ADLoadPoint.fillTypeOptions(vehicle)
    local ok, list = FarmPilotCall(ADLoadPoint.productsOfVehicle, vehicle)
    if ok then
        return list
    end
    return nil
end

-- StateModule.lua, setFillType et setSelectedFillTypes : le jeu n'acceptait que les produits de la remorque attelée
-- (rien d'attelé = aucun produit) ; les produits du point de chargement sont acceptés aussi
function ADLoadPoint.allowedFillTypes(vehicle, supported)
    local ok, list = FarmPilotCall(ADLoadPoint.productsOfVehicle, vehicle)
    if not ok or list == nil then
        return supported
    end
    local out = {}
    for _, ft in ipairs(supported or {}) do
        out[#out + 1] = ft
    end
    for _, ft in ipairs(list) do
        if not table.contains(out, ft) then
            out[#out + 1] = ft
        end
    end
    return out
end

-- PullDownList.lua, createSelection_FpTool (ligne « Remorque ») : seulement les remorques adaptées (nil = comme avant)
function ADLoadPoint.trailerOptions(vehicle)
    if not isLoadMode(vehicle) or ADTrailerHitch == nil then
        return nil
    end
    local fts = ADLoadPoint.selected(vehicle)
    if #fts == 0 then
        return nil
    end
    return ADLoadPoint.fittingTrailers(vehicle, fts)
end

-- PullDownList.lua, getNewState_FillType (ligne « Remorque » repliée) : texte, ou nil = comme avant.
-- Appelée à chaque image : recalculée au plus toutes les REFRESH ms par véhicule (liste des remorques de la carte).
ADLoadPoint.REFRESH = 1000
ADLoadPoint.rowCache = setmetatable({}, { __mode = "k" }) -- véhicule -> { t, text }
function ADLoadPoint.trailerRowText(vehicle)
    if vehicle == nil then
        return nil
    end
    local now = g_time or 0
    local c = ADLoadPoint.rowCache[vehicle]
    if c ~= nil and now >= c.t and now - c.t < ADLoadPoint.REFRESH then
        return c.text
    end
    local text = nil
    local ok, v = FarmPilotCall(ADLoadPoint.verdict, vehicle)
    if ok and v ~= nil then
        if v.ok and v.how == "nearest" then
            text = string.format(g_i18n:getText("AD_trailer_rowNearest"), ADTrailerHitch.label(v.trailer))
        elseif not v.ok then
            text = g_i18n:getText("AD_trailer_rowNoFit")
        end
    end
    ADLoadPoint.rowCache[vehicle] = { t = now, text = text }
    return text
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ (TrailerHitch.lua, beforeStart) : true = départ pris en charge ici (refusé, ou remorque à atteler)
-- ------------------------------------------------------------------------------------------------------------
function ADLoadPoint.beforeStart(mode, user)
    local vehicle = mode ~= nil and mode.vehicle or nil
    local ok, v = FarmPilotCall(ADLoadPoint.verdict, vehicle)
    if not ok or v == nil or (v.ok and v.how ~= "nearest") then
        return false
    end
    local name = tostring(vehicle.ad.stateModule:getName())
    local products = productNames(v.fts)
    if v.ok then
        ADTrailerHitch.log("%s : remorque adaptée à %s la plus proche : « %s », va l'atteler", name, products, ADTrailerHitch.label(v.trailer))
        if not vehicle.ad.stateModule:isActive() then
            vehicle:startAutoDrive()
        end
        ADTrailerHitch.startFetch(mode, v.trailer, user)
        return true
    end
    local key = v.why == "attachedUnfit" and "AD_trailer_noFitAttached" or "AD_trailer_noFitStart"
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 12000, key, products)
    ADTrailerHitch.log("%s : départ refusé, pas de remorque adaptée à %s (%s%s)", name, products, tostring(v.why),
        v.trailer ~= nil and (" : " .. ADTrailerHitch.label(v.trailer)) or "")
    if vehicle.ad.stateModule:isActive() then
        vehicle:stopAutoDrive()
    end
    return true
end
