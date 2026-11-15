-- ============================================================================================================
-- FarmPilot : SprayerRestReturn.lua
-- Mode Autonome, épandeurs et pulvés : le reste de la cuve est rendu ou revendu, jamais vidé en big bags ni en IBC
-- (ni nouveaux, ni déjà posés).
--
-- (13/11) Le reste ne doit plus créer de big bags ni d'IBC (chaux, engrais, phyto ou autre) : s'il ne peut pas
-- être vidé sans ça, il n'est pas vidé. Il est vidé dans une zone de vente ou là où il a été pris ; s'il ne peut
-- être vendu nulle part, il est revendu au prix d'achat là où il a été acheté, sans objet ajouté sur la carte.
-- Remplace la vidange en big bags du 08/11 (AutonomousSprayerDump.lua : décision, trajet et suite inchangés).
--
-- Règle (dans l'ordre, au moment de la décision puis à l'arrêt sur place) :
-- 1. Zone de plein (là où le produit a été pris), zones de chargement à moins de RADIUS m du marqueur :
--    a) stock (silo, stockage, cuve de la ferme) qui accepte le produit et a de la place : le reste y est remis ;
--    b) point d'achat qui vend ce produit : le reste y est revendu au prix d'achat de ce point (argent ajouté).
--    (15/11) Plus d'étape « big bags / IBC déjà posés » : interdit de remplir un big bag ou un IBC, même posé.
-- 2. Sinon, point de vente du jeu qui prend ce produit (le mieux payé, avec un marqueur du réseau à moins de
--    RADIUS m) : le chauffeur y va et le vend, comme une benne qui vide.
-- 3. Sinon : le reste est gardé dans la cuve, message et log disent pourquoi.
-- Le transfert se fait à l'arrêt, machine coupée : la cuve baisse, le stock monte (ou l'argent arrive).
--
-- Branché par AutonomousSprayerDump.lua (ADSprayerDump.decide, decideForPark, ADDumpRestTask). Chargé par
-- register.lua avant AutonomousSprayerDump.lua.
-- ============================================================================================================

ADRestReturn = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADRestReturn.RADIUS = 50          -- m entre le marqueur et la zone de chargement / le point de vente
ADRestReturn.MIN_LITERS = 0.5     -- L : en dessous, rien n'a bougé

ADRestReturn.KIND_TEXT = {        -- textes du message (traductions) et du log
    stock = { key = "AD_rest_how_stock", log = "remis au stock" },
    buy = { key = "AD_rest_how_buy", log = "revendu au prix d'achat" },
    -- (15/11) « bag » retiré : plus jamais de big bags ni d'IBC remplis, même déjà posés
    sell = { key = "AD_rest_how_sell", log = "vendu" },
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

local function markerPos(marker)
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp == nil then
        return nil
    end
    return wp.x, wp.z
end

local function farmOf(vehicle, tool)
    for _, o in ipairs({ tool, vehicle }) do
        if o ~= nil and o.getOwnerFarmId ~= nil then
            local f = safe(o.getOwnerFarmId, o)
            if f ~= nil and f ~= 0 then
                return f
            end
        end
    end
    return 1
end

-- texte du message (« remet le reste de la cuve au stock »…)
function ADRestReturn.howText(kind)
    local k = ADRestReturn.KIND_TEXT[kind]
    if k == nil then
        return tostring(kind)
    end
    if g_i18n ~= nil and g_i18n.getText ~= nil then
        local ok, s = FarmPilotCall(g_i18n.getText, g_i18n, k.key)
        if ok and type(s) == "string" and s ~= "" then
            return s
        end
    end
    return k.log
end

function ADRestReturn.logText(kind)
    local k = ADRestReturn.KIND_TEXT[kind]
    return k ~= nil and k.log or tostring(kind)
end

-- ------------------------------------------------------------------------------------------------------------
-- 1. Zone de plein : stock, point d'achat
-- ------------------------------------------------------------------------------------------------------------
-- point d'achat (pas de stockage, quantité infinie) ?
function ADRestReturn.isBuyingPoint(trigger, source)
    if source == nil then
        return false
    end
    if BuyingStation ~= nil and source.isa ~= nil then
        local is = safe(source.isa, source, BuyingStation)
        if is then
            return true
        end
    end
    if trigger ~= nil and trigger.hasInfiniteCapacity and (source.sourceStorages == nil or next(source.sourceStorages) == nil) then
        return true
    end
    return false
end

-- le point d'achat vend-il ce produit ?
local function buyingPointSells(trigger, source, ft, farmId)
    if trigger.fillTypes ~= nil and trigger.fillTypes[ft] then
        return true
    end
    if source.providedFillTypes ~= nil and source.providedFillTypes[ft] then
        return true
    end
    local levels = safe(source.getAllFillLevels, source, farmId)
    return type(levels) == "table" and levels[ft] ~= nil
end

-- prix d'achat au litre de ce point (comme le jeu le fait payer)
function ADRestReturn.buyPrice(source, ft)
    local p = nil
    if source ~= nil and source.getEffectiveFillTypePrice ~= nil then
        p = safe(source.getEffectiveFillTypePrice, source, ft)
    end
    if type(p) ~= "number" or p <= 0 then
        local eco = g_currentMission ~= nil and g_currentMission.economyManager or nil
        local base = eco ~= nil and safe(eco.getCostPerLiter, eco, ft, false) or nil
        local scale = source ~= nil and source.fillTypePricesScale ~= nil and source.fillTypePricesScale[ft] or 1
        p = type(base) == "number" and base * scale or 0
    end
    return p
end

-- stockages de la zone qui acceptent ce produit : { {storage, free} }, place libre totale
local function storagesOf(source, ft, farmId)
    local list, total = {}, 0
    for storage, _ in pairs(source.sourceStorages or {}) do
        local access = source.hasFarmAccessToStorage == nil or safe(source.hasFarmAccessToStorage, source, farmId, storage)
        if access and storage.getIsFillTypeSupported ~= nil and safe(storage.getIsFillTypeSupported, storage, ft) then
            local free = safe(storage.getFreeCapacity, storage, ft) or 0
            if free > ADRestReturn.MIN_LITERS then
                list[#list + 1] = { storage = storage, free = free }
                total = total + free
            end
        end
    end
    return list, total
end

--[==[ Mis de côté (15/11) : remplir les big bags / IBC déjà posés, interdit
-- big bags / IBC du même produit, pas pleins, près de (x, z)
local function bagsNear(x, z, ft, farmId)
    local list, total = {}, 0
    local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    for _, v in pairs(vs ~= nil and vs.vehicles or {}) do
        if v ~= nil and not v.isDeleted and v.spec_fillTriggerVehicle ~= nil and v.getFillUnits ~= nil and v.rootNode ~= nil then
            local owner = v.getOwnerFarmId ~= nil and safe(v.getOwnerFarmId, v) or nil
            if owner == nil or owner == farmId or owner == 0 then
                local vx, _, vz = getWorldTranslation(v.rootNode)
                if (vx - x) ^ 2 + (vz - z) ^ 2 <= ADRestReturn.RADIUS ^ 2 then
                    for i, _ in ipairs(safe(v.getFillUnits, v) or {}) do
                        local level = safe(v.getFillUnitFillLevel, v, i) or 0
                        if level > 0 and safe(v.getFillUnitFillType, v, i) == ft then
                            local free = safe(v.getFillUnitFreeCapacity, v, i, ft, farmId) or 0
                            if free > ADRestReturn.MIN_LITERS then
                                list[#list + 1] = { pallet = v, unit = i, free = free }
                                total = total + free
                            end
                        end
                    end
                end
            end
        end
    end
    return list, total
end
]==]

-- place à la zone de plein : { kind = "stock" | "buy", marker, trigger, source, free, price } ou nil, raison
function ADRestReturn.placeAt(marker, ft, farmId)
    local mx, mz = markerPos(marker)
    if mx == nil then
        return nil, "zone de plein absente du réseau"
    end
    local stock, buy = nil, nil
    if ADTriggerManager ~= nil and ADTriggerManager.getLoadTriggers ~= nil then
        for _, trigger in pairs(safe(ADTriggerManager.getLoadTriggers) or {}) do
            local source = trigger ~= nil and trigger.source or nil
            if source ~= nil and (trigger.fillTypes == nil or trigger.fillTypes[ft]) then
                local x, _, z = safe(ADTriggerManager.getTriggerPos, trigger)
                if x ~= nil and (x ~= 0 or z ~= 0) then
                    local d2 = (x - mx) ^ 2 + (z - mz) ^ 2
                    if d2 <= ADRestReturn.RADIUS ^ 2 then
                        if ADRestReturn.isBuyingPoint(trigger, source) then
                            if buyingPointSells(trigger, source, ft, farmId) and (buy == nil or d2 < buy.d2) then
                                buy = { kind = "buy", marker = marker, trigger = trigger, source = source, d2 = d2, price = ADRestReturn.buyPrice(source, ft) }
                            end
                        else
                            local _, free = storagesOf(source, ft, farmId)
                            if free > ADRestReturn.MIN_LITERS and (stock == nil or d2 < stock.d2) then
                                stock = { kind = "stock", marker = marker, trigger = trigger, source = source, d2 = d2, free = free }
                            end
                        end
                    end
                end
            end
        end
    end
    if stock ~= nil then
        return stock
    end
    if buy ~= nil then
        return buy
    end
    -- (15/11) plus d'étape big bags / IBC déjà posés : la suite est le point de vente (plan), sinon le reste est gardé
    return nil, "ni stock qui l'accepte, ni point d'achat de ce produit à cette zone"
end

-- ------------------------------------------------------------------------------------------------------------
-- 2. Point de vente du jeu qui prend ce produit
-- ------------------------------------------------------------------------------------------------------------
local function toolTypeOf()
    if ToolType ~= nil then
        return ToolType.DISCHARGEABLE or ToolType.UNDEFINED
    end
    return nil
end

local function sellTriggerOk(trigger, ft, farmId)
    local station = trigger ~= nil and trigger.target or nil
    if station == nil or SellingStation == nil or station.isa == nil or not safe(station.isa, station, SellingStation) then
        return false
    end
    if station.isSellingPoint == false or trigger.addFillUnitFillLevel == nil then
        return false
    end
    if trigger.getIsFillTypeAllowed ~= nil and not safe(trigger.getIsFillTypeAllowed, trigger, ft) then
        return false
    end
    local tt = toolTypeOf()
    if tt ~= nil and trigger.getIsToolTypeAllowed ~= nil and not safe(trigger.getIsToolTypeAllowed, trigger, tt) then
        return false
    end
    if station.getIsFillAllowedFromFarm ~= nil and not safe(station.getIsFillAllowedFromFarm, station, farmId) then
        return false
    end
    return true
end

-- { kind = "sell", marker, trigger, station, price } ou nil, raison
function ADRestReturn.saleFor(vehicle, ft, farmId)
    if ADTriggerManager == nil or ADTriggerManager.getUnloadTriggers == nil then
        return nil, "aucun point de vente"
    end
    local vx, vz = 0, 0
    local node = vehicle ~= nil and (vehicle.rootNode or (vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node)) or nil
    if node ~= nil then
        local x, _, z = getWorldTranslation(node)
        vx, vz = x, z
    end
    local best = nil
    local anyStation = false
    for _, trigger in pairs(safe(ADTriggerManager.getUnloadTriggers) or {}) do
        if sellTriggerOk(trigger, ft, farmId) then
            anyStation = true
            local x, _, z = safe(ADTriggerManager.getTriggerPos, trigger)
            if x ~= nil and (x ~= 0 or z ~= 0) then
                -- marqueur du réseau le plus proche du point de vente
                local marker, md2 = nil, ADRestReturn.RADIUS ^ 2
                for _, m in pairs(ADGraphManager:getMapMarkers() or {}) do
                    local px, pz = markerPos(m)
                    if px ~= nil then
                        local d2 = (px - x) ^ 2 + (pz - z) ^ 2
                        if d2 <= md2 then
                            marker, md2 = m, d2
                        end
                    end
                end
                if marker ~= nil then
                    local station = trigger.target
                    local price = safe(station.getEffectiveFillTypePrice, station, ft) or 0
                    local dist2 = (x - vx) ^ 2 + (z - vz) ^ 2
                    if best == nil or price > best.price + 0.0001 or (math.abs(price - best.price) <= 0.0001 and dist2 < best.dist2) then
                        best = { kind = "sell", marker = marker, trigger = trigger, station = station, price = price, dist2 = dist2 }
                    end
                end
            end
        end
    end
    if best ~= nil then
        return best
    end
    return nil, anyStation and "point de vente sans marqueur du réseau à côté" or "aucun point de vente ne prend ce produit"
end

-- ------------------------------------------------------------------------------------------------------------
-- Choix (décision) : zone de plein d'abord, puis point de vente
-- ------------------------------------------------------------------------------------------------------------
-- place, ou nil et la raison
function ADRestReturn.plan(vehicle, tool, ft, refillMarker)
    local farmId = farmOf(vehicle, tool)
    local why1 = "pas de zone de plein"
    if refillMarker ~= nil then
        local place, why = ADRestReturn.placeAt(refillMarker, ft, farmId)
        if place ~= nil then
            return place
        end
        why1 = string.format("« %s » : %s", tostring(refillMarker.name), tostring(why))
    end
    local sale, why2 = ADRestReturn.saleFor(vehicle, ft, farmId)
    if sale ~= nil then
        return sale
    end
    return nil, string.format("%s ; %s", why1, tostring(why2))
end

-- ------------------------------------------------------------------------------------------------------------
-- Transfert, à l'arrêt sur place (ADDumpRestTask)
-- ------------------------------------------------------------------------------------------------------------
-- retire au plus amount L de la cuve, rend ce qui a été retiré
local function takeFromTool(tool, unit, ft, farmId, amount)
    if amount <= ADRestReturn.MIN_LITERS then
        return 0
    end
    local tt = ToolType ~= nil and ToolType.UNDEFINED or nil
    local applied = safe(tool.addFillUnitFillLevel, tool, farmId, unit, -amount, ft, tt, nil) or 0
    return math.max(0, -applied)
end

-- litres, argent (nil si pas d'argent), ou nil et la raison
function ADRestReturn.apply(vehicle, tool, place)
    if place == nil or tool == nil then
        return nil, "rien de prévu"
    end
    local unit = ADSprayerManager.fillUnit(tool)
    local level, ft = ADSprayerManager.content(tool)
    if unit == nil or ft == nil or level <= ADRestReturn.MIN_LITERS then
        return 0
    end
    local farmId = farmOf(vehicle, tool)
    if place.kind == "stock" then
        local list, free = storagesOf(place.source, ft, farmId)
        local moved = takeFromTool(tool, unit, ft, farmId, math.min(level, free))
        if moved <= 0 then
            return nil, "stock plein ou refusé"
        end
        local rest = moved
        for _, e in ipairs(list) do
            if rest <= 0 then
                break
            end
            local add = math.min(rest, e.free)
            local cur = safe(e.storage.getFillLevel, e.storage, ft) or 0
            safe(e.storage.setFillLevel, e.storage, cur + add, ft)
            rest = rest - add
        end
        return moved
    elseif place.kind == "buy" then
        local price = place.price or ADRestReturn.buyPrice(place.source, ft)
        local moved = takeFromTool(tool, unit, ft, farmId, level)
        if moved <= 0 then
            return nil, "cuve pas vidée"
        end
        local money = moved * price
        if money > 0 and g_currentMission ~= nil and g_currentMission.addMoney ~= nil then
            local mt = MoneyType ~= nil and (MoneyType.SOLD_PRODUCTS or MoneyType.OTHER) or nil
            safe(g_currentMission.addMoney, g_currentMission, money, farmId, mt, true, true)
        end
        return moved, money
    --[==[ Mis de côté (15/11) : remplir les big bags / IBC déjà posés, interdit
    elseif place.kind == "bag" then
        local mx, mz = markerPos(place.marker)
        if mx == nil then
            return nil, "zone de plein absente du réseau"
        end
        local list = bagsNear(mx, mz, ft, farmId)
        local total = 0
        local tt = ToolType ~= nil and ToolType.UNDEFINED or nil
        for _, e in ipairs(list) do
            local left = (ADSprayerManager.content(tool))
            if left <= ADRestReturn.MIN_LITERS then
                break
            end
            local added = safe(e.pallet.addFillUnitFillLevel, e.pallet, farmId, e.unit, math.min(left, e.free), ft, tt, nil) or 0
            if added > 0 then
                total = total + takeFromTool(tool, unit, ft, farmId, added)
            end
        end
        if total <= 0 then
            return nil, "big bags pleins ou partis"
        end
        return total
    ]==]
    elseif place.kind == "sell" then
        local trigger = place.trigger
        if not sellTriggerOk(trigger, ft, farmId) then
            return nil, "le point de vente ne prend plus ce produit"
        end
        local free = trigger.getFillUnitFreeCapacity ~= nil and safe(trigger.getFillUnitFreeCapacity, trigger, 1, ft, farmId) or nil
        local amount = level
        if type(free) == "number" then
            amount = math.min(amount, free)
        end
        if amount <= ADRestReturn.MIN_LITERS then
            return nil, "point de vente plein"
        end
        local sold = safe(trigger.addFillUnitFillLevel, trigger, farmId, 1, amount, ft, toolTypeOf(), nil) or 0
        if sold <= ADRestReturn.MIN_LITERS then
            return nil, "vente refusée"
        end
        local moved = takeFromTool(tool, unit, ft, farmId, sold)
        local price = place.price or 0
        return moved, price > 0 and moved * price or nil
    end
    return nil, "type de place inconnu"
end
