-------------------------------------------------------------------------------
-- FarmPilot - mode Autonome : épandeurs et pulvérisateurs, traînés ou automoteurs
--   Engrais, chaux, fumier, lisier, digestat, phyto : même roue dentée que le semoir, à gauche de la ligne
--   « Outil » (ou « Outil suivant »). Elle ouvre la fenêtre « Réglages de l'épandeur » : produit à charger (ce
--   que la cuve accepte), quantité (« Plein » ou « Juste ce qu'il faut pour le champ ») et zone de ravitaillement
--   (un marqueur de la carte). Choix retenu par champ (marqueur de la ligne « Champ ») et par machine (modèle).
--   Tant que ce n'est pas validé, le départ est refusé (roue dentée orange, verte une fois validé).
--   Le plein passe par le même chemin que le semoir (AutonomousMode:startRefill, LoadAtDestinationTask) : au départ
--   si la cuve n'a pas ce qu'il faut, et quand Courseplay s'arrête cuve vide (sortie du champ, plein, retour,
--   Courseplay repart au dernier point). Automoteur : la machine elle-même est l'« outil ».
--
-- Demande de Fabien (08/11, 14:05) : « pour les épandeurs automoteurs ou classiques : * Retourner vider le trop à
--   la fin du champ (si pas de suivant ou si pas de changement de produit) * Choisir le produit et la quantité à
--   prendre »
-- Demande de Fabien (08/11, 20:39) : « L'automoteur comme le pulvé, ils doivent être fonctionnels sur Autonome »
--
-- Règle : pas de système à part. Mêmes étapes de plein que le semoir (startRefill / monitorRefill /
--   handleRefillStage) ; ce fichier ne fait que le réglage, le plan de plein et l'arrêt du chargement à la quantité
--   voulue. « Vider le trop » : pas fait ici (question posée à Fabien) ; une cuve qui contient un autre produit
--   que celui choisi refuse le départ avec un message.
-------------------------------------------------------------------------------
ADSprayerManager = {}
ADSprayerManager.FILE_NAME = "FarmPilot_Epandeurs.xml"
ADSprayerManager.settings = {}   -- [nom du champ .. "|" .. clé de la machine] = { field, tool, toolName, fillType, quantity, refill, stamp }
ADSprayerManager.loaded = false
ADSprayerManager.stamp = 0
ADSprayerManager.MARGIN = 0.10          -- « juste ce qu'il faut » : +10 % (dosage variable de Precision Farming, recouvrements)
ADSprayerManager.MIN_TARGET = 100       -- L : plus petit plein demandé en « juste ce qu'il faut »
ADSprayerManager.QUANTITY_FULL = "full"
ADSprayerManager.QUANTITY_FIELD = "field"

local function log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print("[FarmPilot Épandeur] " .. (ok and s or tostring(fmt)))
end
ADSprayerManager.log = log

-- ------------------------------------------------------------
-- Quelle machine
-- ------------------------------------------------------------
-- cuve de pulvérisation / d'épandage de l'outil (nil si l'outil n'en a pas, ex. injecteur seul d'une tonne)
function ADSprayerManager.fillUnit(tool)
    if tool == nil or tool.spec_sprayer == nil then
        return nil
    end
    local unit = nil
    if tool.getSprayerFillUnitIndex ~= nil then
        local ok, u = pcall(tool.getSprayerFillUnitIndex, tool)
        unit = ok and u or nil
    end
    unit = unit or tool.spec_sprayer.fillUnitIndex
    if type(unit) ~= "number" or tool.getFillUnitCapacity == nil then
        return nil
    end
    local okC, cap = pcall(tool.getFillUnitCapacity, tool, unit)
    if not okC or type(cap) ~= "number" or cap <= 0 then
        return nil
    end
    return unit, cap
end

-- épandeur / pulvé avec sa cuve ; un semoir (même fertiliseur) reste au semoir (SeederManager)
function ADSprayerManager.isSprayer(tool)
    if tool == nil or tool.spec_sprayer == nil or tool.spec_sowingMachine ~= nil or tool.isDeleted or tool.isDeleting then
        return false
    end
    return ADSprayerManager.fillUnit(tool) ~= nil
end

-- machine qui épand pour ce véhicule : l'automoteur lui-même, sinon l'outil attelé qui a la plus grande cuve
-- (tonne + injecteur : la tonne)
function ADSprayerManager.attachedSprayer(vehicle)
    if vehicle == nil then
        return nil
    end
    if ADSprayerManager.isSprayer(vehicle) then
        return vehicle
    end
    local best, bestCap = nil, 0
    local okT, tools = pcall(ADAutonomousManager.workTools, vehicle)
    for _, t in ipairs(okT and tools or {}) do
        if ADSprayerManager.isSprayer(t) then
            local _, cap = ADSprayerManager.fillUnit(t)
            if cap > bestCap then
                best, bestCap = t, cap
            end
        end
    end
    return best
end

-- outil de la ligne « Outil » (ou « Outil suivant ») : celui choisi s'il épand, sinon la machine attelée qui épand
function ADSprayerManager.rowTool(vehicle, isNext)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil then
        return nil
    end
    if isNext and sm.getFpNextTool ~= nil then
        local nextTool = sm:getFpNextTool()
        if nextTool ~= nil then
            return ADSprayerManager.isSprayer(nextTool) and nextTool or nil
        end
    end
    local tool = sm.getFpTool ~= nil and sm:getFpTool() or nil
    if tool ~= nil then
        if ADSprayerManager.isSprayer(tool) then
            return tool
        end
        -- outil choisi = injecteur d'une tonne attelée : la tonne
        if tool.spec_sprayer == nil or not ADSeederManager.attachedTo(tool, vehicle) then
            return nil
        end
    end
    return ADSprayerManager.attachedSprayer(vehicle)
end

function ADSprayerManager.isAttached(tool, vehicle)
    return tool ~= nil and (tool == vehicle or ADSeederManager.attachedTo(tool, vehicle))
end

-- { tool, toolKey, field (nom du marqueur), marker } si la ligne a un épandeur / pulvé et un champ ; sinon nil
function ADSprayerManager.context(vehicle, isNext)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil then
        return nil
    end
    if vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return nil
    end
    local tool = ADSprayerManager.rowTool(vehicle, isNext)
    if tool == nil then
        return nil
    end
    local marker = ADSeederManager.rowField(vehicle, isNext)
    if marker == nil or marker.name == nil then
        return nil
    end
    return { tool = tool, toolKey = ADSeederManager.toolKey(tool), field = marker.name, marker = marker, vehicle = vehicle }
end

-- ------------------------------------------------------------
-- Produits que la cuve accepte
-- ------------------------------------------------------------
-- { {index, name, title} } triés par nom (mêmes exclusions que le semoir : carburants, air, inconnu)
function ADSprayerManager.productChoices(tool)
    local out = {}
    local unit = ADSprayerManager.fillUnit(tool)
    if unit == nil or tool.getFillUnitSupportedFillTypes == nil then
        return out
    end
    local excluded = {}
    for _, n in ipairs(ADSeederManager.EXCLUDED_FILLTYPES) do
        excluded[n] = true
    end
    for fillTypeIndex, ok in pairs(tool:getFillUnitSupportedFillTypes(unit) or {}) do
        if ok then
            local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
            if name ~= nil and not excluded[name] then
                local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                out[#out + 1] = { index = fillTypeIndex, name = name, title = (ft ~= nil and ft.title) or name }
            end
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.title) < tostring(b.title)
    end)
    return out
end

function ADSprayerManager.productTitle(name)
    local idx = name ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
    local ft = idx ~= nil and g_fillTypeManager:getFillTypeByIndex(idx) or nil
    return (ft ~= nil and ft.title) or tostring(name or "-")
end

-- contenu de la cuve : niveau (L), index du produit (nil si vide), capacité
function ADSprayerManager.content(tool)
    local unit, cap = ADSprayerManager.fillUnit(tool)
    if unit == nil then
        return 0, nil, 0
    end
    local level = tool:getFillUnitFillLevel(unit) or 0
    local ft = tool.getFillUnitFillType ~= nil and tool:getFillUnitFillType(unit) or nil
    if level <= 0.01 or ft == FillType.UNKNOWN then
        ft = nil
    end
    return level, ft, cap
end

-- ------------------------------------------------------------
-- Quantité : dose réelle (Sprayer.lua) x surface du champ
-- ------------------------------------------------------------
-- Sprayer:getSprayerUsage : scale x litersPerSecond x speedLimit x largeur d'usage x dt x 0,001 (L par image, en
-- continu tant que l'outil est en marche). À la vitesse de travail v (km/h) et largeur réelle W (m), l'outil couvre
-- W x v / 3,6 m²/s, d'où L/ha = 36000 x scale x litersPerSecond x (speedLimit / v) x (largeur d'usage / W).
function ADSprayerManager.usageScaleFor(tool, fillTypeIndex)
    local spec = tool.spec_sprayer
    local usageScale = spec.usageScale
    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    for _, st in ipairs(spec.sprayTypes or {}) do
        local match = st.fillTypes == nil
        for _, n in ipairs(st.fillTypes or {}) do
            if n == name then
                match = true
            end
        end
        if match and st.usageScale ~= nil then
            usageScale = st.usageScale
            break
        end
    end
    return usageScale
end

-- vitesse de travail de Courseplay : sa vitesse au champ, limitée par celle de l'outil
function ADSprayerManager.workSpeed(tool, vehicle)
    local spec = tool.spec_sprayer
    local limit = tool.speedLimit
    if spec.doubledAmountIsActive and (spec.isSlurryTanker or spec.isManureSpreader) and type(spec.doubledAmountSpeed) == "number" then
        limit = spec.doubledAmountSpeed
    end
    local cpSpeed = nil
    if vehicle ~= nil and vehicle.getCpSettings ~= nil then
        local ok, s = pcall(vehicle.getCpSettings, vehicle)
        if ok and s ~= nil and s.fieldWorkSpeed ~= nil and s.fieldWorkSpeed.getValue ~= nil then
            local okV, v = pcall(s.fieldWorkSpeed.getValue, s.fieldWorkSpeed)
            cpSpeed = okV and tonumber(v) or nil
        end
    end
    if type(limit) ~= "number" or limit <= 0 or limit == math.huge then
        limit = nil
    end
    if limit ~= nil and cpSpeed ~= nil and cpSpeed > 0 then
        return math.min(limit, cpSpeed)
    end
    return limit or cpSpeed
end

-- litres par hectare pour ce produit, ou nil (dose inconnue)
function ADSprayerManager.litersPerHa(tool, fillTypeIndex, vehicle)
    if tool == nil or tool.spec_sprayer == nil or fillTypeIndex == nil or g_sprayTypeManager == nil then
        return nil
    end
    local sprayType = g_sprayTypeManager:getSprayTypeByFillTypeIndex(fillTypeIndex)
    local lps = sprayType ~= nil and sprayType.litersPerSecond or nil
    if type(lps) ~= "number" or lps <= 0 then
        return nil
    end
    local spec = tool.spec_sprayer
    local scale = (spec.usageScale.fillTypeScales or {})[fillTypeIndex] or spec.usageScale.default or 1
    local usageScale = ADSprayerManager.usageScaleFor(tool, fillTypeIndex)
    local usageWidth = usageScale.workingWidth
    if usageScale.workAreaIndex ~= nil and tool.getWorkAreaWidth ~= nil then
        local ok, w = pcall(tool.getWorkAreaWidth, tool, usageScale.workAreaIndex)
        usageWidth = ok and w or usageWidth
    end
    local okW, realWidth = pcall(ADAutonomousManager.toolWorkWidth, tool)
    realWidth = okW and realWidth or nil
    if type(usageWidth) ~= "number" or usageWidth <= 0 then
        return nil
    end
    if type(realWidth) ~= "number" or realWidth <= 0 then
        realWidth = usageWidth
    end
    local speed = ADSprayerManager.workSpeed(tool, vehicle)
    local rawLimit = tool.speedLimit
    if type(speed) ~= "number" or speed <= 0 or type(rawLimit) ~= "number" or rawLimit <= 0 or rawLimit == math.huge then
        return nil
    end
    return 36000 * scale * lps * (rawLimit / speed) * (usageWidth / realWidth)
end

-- champ par son numéro (gestionnaire de champs du jeu)
local function fieldByNumber(n)
    if g_fieldManager == nil or n == nil then
        return nil
    end
    if g_fieldManager.getFieldById ~= nil then
        local ok, f = pcall(g_fieldManager.getFieldById, g_fieldManager, n)
        if ok and f ~= nil and tonumber(ADAutonomousManager.fieldNumber(f)) == tonumber(n) then
            return f
        end
    end
    local fields = g_fieldManager.getFields ~= nil and g_fieldManager:getFields() or g_fieldManager.fields
    for _, f in pairs(fields or {}) do
        if tonumber(ADAutonomousManager.fieldNumber(f)) == tonumber(n) then
            return f
        end
    end
    return nil
end

local function areaOf(f)
    if f == nil then
        return 0
    end
    if f.getAreaHa ~= nil then
        local ok, a = pcall(f.getAreaHa, f)
        if ok and type(a) == "number" then
            return a
        end
    end
    return tonumber(f.areaHa) or 0
end

-- surface (ha) du champ d'un marqueur : numéros écrits dans son nom (« Champ 52 - 53 »), groupes AutoSwitch
-- compris ; sinon le champ sous le marqueur. Renvoie aussi la liste des champs comptés.
function ADSprayerManager.markerArea(marker)
    if marker == nil then
        return nil
    end
    local nums, seen = {}, {}
    local function add(n)
        n = tonumber(n)
        if n ~= nil and not seen[n] then
            seen[n] = true
            nums[#nums + 1] = n
        end
    end
    for n in tostring(marker.name or ""):gmatch("%d+") do
        local okG, g = pcall(ADAutonomousManager.groupOf, tonumber(n))
        if okG and g ~= nil then
            for _, m in ipairs(g.members or { n }) do
                add(m)
            end
        else
            add(n)
        end
    end
    local total = 0
    for _, n in ipairs(nums) do
        total = total + areaOf(fieldByNumber(n))
    end
    if total <= 0 then
        nums = {}
        local wp = marker.id ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
        local f = wp ~= nil and wp.x ~= nil and ADAutonomousManager.fieldAt(wp.x, wp.z) or nil
        total = areaOf(f)
        if f ~= nil then
            nums[1] = ADAutonomousManager.fieldNumber(f)
        end
    end
    if total <= 0 then
        return nil
    end
    return total, nums
end

-- part du parcours Courseplay qui reste à faire (1 = tout), d'après le dernier point retenu par Courseplay
function ADSprayerManager.remainingShare(vehicle)
    if vehicle == nil or vehicle.getFieldWorkCourse == nil or vehicle.getCpLastRememberedWaypointIx == nil then
        return 1
    end
    local okC, course = pcall(vehicle.getFieldWorkCourse, vehicle)
    local okI, ix = pcall(vehicle.getCpLastRememberedWaypointIx, vehicle)
    if not okC or not okI or course == nil or ix == nil or course.getProgress == nil then
        return 1
    end
    local okP, progress = pcall(course.getProgress, course, ix)
    if not okP or type(progress) ~= "number" then
        return 1
    end
    return math.max(0, math.min(1, 1 - progress))
end

-- litres à prendre pour finir le champ : { liters, lha, area, share } ou nil si la dose ou la surface manque
function ADSprayerManager.estimate(vehicle, tool, fillTypeIndex, marker, share)
    local lha = ADSprayerManager.litersPerHa(tool, fillTypeIndex, vehicle)
    local area = ADSprayerManager.markerArea(marker)
    if lha == nil or area == nil then
        return nil, lha, area
    end
    share = share or 1
    local liters = lha * area * share * (1 + ADSprayerManager.MARGIN)
    liters = math.ceil(liters / 10) * 10
    return { liters = liters, lha = lha, area = area, share = share }
end

-- ------------------------------------------------------------
-- Mémoire champ + machine
-- ------------------------------------------------------------
function ADSprayerManager:get(field, toolKey)
    self:loadFromXml()
    return self.settings[ADSeederManager.key(field, toolKey)]
end

-- derniers réglages de cette machine (n'importe quel champ), pour préremplir la fenêtre
function ADSprayerManager:lastFor(toolKey)
    self:loadFromXml()
    local best = nil
    for _, s in pairs(self.settings) do
        if s.tool == toolKey and (best == nil or (s.stamp or 0) > (best.stamp or 0)) then
            best = s
        end
    end
    return best
end

function ADSprayerManager:set(field, tool, s)
    self:loadFromXml()
    self.stamp = self.stamp + 1
    local toolKey = ADSeederManager.toolKey(tool)
    local entry = {
        field = field, tool = toolKey, toolName = ADAutonomousManager.toolLabel(tool), fillType = s.fillType,
        quantity = s.quantity == ADSprayerManager.QUANTITY_FIELD and ADSprayerManager.QUANTITY_FIELD or ADSprayerManager.QUANTITY_FULL,
        refill = s.refill, stamp = self.stamp
    }
    self.settings[ADSeederManager.key(field, toolKey)] = entry
    log("« %s », machine %s : produit %s, quantité %s, ravitaillement « %s »", tostring(field), toolKey, tostring(entry.fillType),
        entry.quantity == ADSprayerManager.QUANTITY_FIELD and "juste ce qu'il faut" or "plein", tostring(entry.refill))
    return entry
end

-- ce qui manque : nil si c'est bon, sinon « none », « product » (aucun produit) ou « refill » (zone absente ou effacée)
function ADSprayerManager.missing(s)
    if s == nil then
        return "none"
    end
    if s.fillType == nil or g_fillTypeManager:getFillTypeIndexByName(s.fillType) == nil then
        return "product"
    end
    if s.refill == nil or ADGraphManager:getMapMarkerByName(s.refill) == nil then
        return "refill"
    end
    return nil
end

function ADSprayerManager.isValid(s)
    return ADSprayerManager.missing(s) == nil
end

-- roue dentée : « none » (pas d'épandeur sur la ligne), « ok » (validé), « todo » (à régler)
function ADSprayerManager.status(vehicle, isNext)
    local ctx = ADSprayerManager.context(vehicle, isNext)
    if ctx == nil then
        return "none"
    end
    if ADSprayerManager.isValid(ADSprayerManager:get(ctx.field, ctx.toolKey)) then
        return "ok"
    end
    return "todo"
end

-- (hook HudButton) même roue dentée que le semoir : le semoir d'abord, sinon l'épandeur ; renvoie l'état et la bulle
function ADSprayerManager.hudGear(vehicle, isNext, seederStatus)
    if seederStatus ~= nil and seederStatus ~= "none" then
        return seederStatus, isNext and "gui_ad_seeder_tooltipNext" or "gui_ad_seeder_tooltip"
    end
    local ok, status = pcall(ADSprayerManager.status, vehicle, isNext)
    status = ok and status or "none"
    return status, isNext and "gui_ad_sprayer_tooltipNext" or "gui_ad_sprayer_tooltip"
end

-- { label, field, isNext } si un épandeur des lignes Outil / Outil suivant n'est pas réglé pour son champ
function ADSprayerManager.startBlock(vehicle)
    for _, isNext in ipairs({ false, true }) do
        local ctx = ADSprayerManager.context(vehicle, isNext)
        if ctx ~= nil and not ADSprayerManager.isValid(ADSprayerManager:get(ctx.field, ctx.toolKey)) then
            local okL, label = pcall(ADAutonomousManager.toolShortLabel, ctx.tool)
            return { label = okL and label or ADAutonomousManager.toolLabel(ctx.tool), field = ctx.field, isNext = isNext }
        end
    end
    return nil
end

-- ------------------------------------------------------------
-- Départ (hook AutonomousMode:start) : refusé tant que ce n'est pas validé
-- ------------------------------------------------------------
local function refuse(vehicle, key, ...)
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 12000, key, ...)
    if vehicle.ad.stateModule:isActive() then
        vehicle:stopAutoDrive()
    end
    return true
end

function ADSprayerManager.checkStart(vehicle)
    local name = tostring(vehicle.ad.stateModule:getName())
    local block = ADSprayerManager.startBlock(vehicle)
    if block ~= nil then
        log("%s : départ refusé, réglages de « %s » à valider pour « %s »", name, tostring(block.label), tostring(block.field))
        return refuse(vehicle, "AD_autonomous_sprayerTodo", tostring(block.label), tostring(block.field))
    end
    -- cuve avec un autre produit que celui choisi : le chargement n'irait pas (et « vider le trop » n'est pas fait)
    local ctx = ADSprayerManager.context(vehicle, false)
    if ctx ~= nil and ADSprayerManager.isAttached(ctx.tool, vehicle) then
        local s = ADSprayerManager:get(ctx.field, ctx.toolKey)
        local level, ft, cap = ADSprayerManager.content(ctx.tool)
        local wanted = s ~= nil and g_fillTypeManager:getFillTypeIndexByName(s.fillType) or nil
        if ft ~= nil and wanted ~= nil and ft ~= wanted and level > math.max(1, cap * 0.005) then
            local inTank = g_fillTypeManager:getFillTypeNameByIndex(ft)
            log("%s : départ refusé, la cuve contient encore %s (%.0f L), produit choisi %s", name, tostring(inTank), level, tostring(s.fillType))
            return refuse(vehicle, "AD_autonomous_sprayerOtherProduct", ADSprayerManager.productTitle(inTank), level, ADSprayerManager.productTitle(s.fillType))
        end
    end
    return false
end

-- true = départ refusé (message et log faits)
function ADSprayerManager.refuseStart(mode)
    local ok, refused = pcall(ADSprayerManager.checkStart, mode.vehicle)
    if not ok then
        log("ERREUR réglages de l'épandeur : %s", tostring(refused))
        return false
    end
    return refused == true
end

-- ------------------------------------------------------------
-- Plan de plein (hooks AutonomousMode:start et onCpEmpty), même forme que celui du semoir
-- ------------------------------------------------------------
-- Courseplay : cuve vide = il s'arrête et le signale (FarmPilot va remplir), au lieu d'attendre sur place
function ADSprayerManager.applyCpSettings(vehicle)
    if vehicle.getCpSettings == nil then
        return
    end
    local okS, settings = pcall(vehicle.getCpSettings, vehicle)
    local refill = okS and settings ~= nil and settings.refillOnTheField or nil
    if refill ~= nil and refill.getValue ~= nil and refill:getValue() ~= 0 then
        pcall(refill.setValue, refill, 0)
        log("Courseplay : « plein dans le champ » remis sur désactivé (FarmPilot va remplir à la zone)")
    end
end

-- le jeu achète le produit pour l'ouvrier (options du jeu) : la cuve ne se vide pas pendant le travail
function ADSprayerManager.helperBuys(tool)
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local spec = tool.spec_sprayer
    if mi == nil or spec == nil then
        return false
    end
    return (spec.isSlurryTanker and (mi.helperSlurrySource or 1) > 1) or (spec.isManureSpreader and (mi.helperManureSource or 1) > 1)
        or (spec.isFertilizerSprayer and mi.helperBuyFertilizer == true) or false
end

-- after = « field » (départ) ou « back » (Courseplay arrêté cuve vide) ;
-- renvoie { kind, tool, settings, marker, fillTypes, field, needsFill, target, fillUnit, fillKey, emptyKey } ou nil
function ADSprayerManager.plan(vehicle, after)
    local ctx = ADSprayerManager.context(vehicle, false)
    if ctx == nil or not ADSprayerManager.isAttached(ctx.tool, vehicle) then
        return nil
    end
    local s = ADSprayerManager:get(ctx.field, ctx.toolKey)
    if not ADSprayerManager.isValid(s) then
        return nil
    end
    local name = tostring(vehicle.ad.stateModule:getName())
    local tool = ctx.tool
    local ftIndex = g_fillTypeManager:getFillTypeIndexByName(s.fillType)
    local unit, cap = ADSprayerManager.fillUnit(tool)
    pcall(ADSprayerManager.applyCpSettings, vehicle)
    if ADSprayerManager.helperBuys(tool) then
        log("%s : le jeu achète le produit pour l'ouvrier (options du jeu) : la cuve ne se videra pas au champ", name)
    end
    local level, inTank = ADSprayerManager.content(tool)
    if inTank ~= nil and inTank ~= ftIndex then
        level = 0
    end
    local target = nil
    if s.quantity == ADSprayerManager.QUANTITY_FIELD then
        local share = after == "back" and ADSprayerManager.remainingShare(vehicle) or 1
        local est, lha, area = ADSprayerManager.estimate(vehicle, tool, ftIndex, ctx.marker, share)
        if est == nil then
            log("%s : « juste ce qu'il faut » impossible (dose %s, surface %s) : plein", name, lha ~= nil and string.format("%.0f L/ha", lha) or "inconnue",
                area ~= nil and string.format("%.2f ha", area) or "inconnue")
        else
            target = math.max(est.liters, math.min(cap, ADSprayerManager.MIN_TARGET))
            log("%s : « %s » %.2f ha x %.0f %% à faire x %.0f L/ha + %.0f %% = %.0f L (cuve %.0f L)", name, tostring(ctx.field), est.area, est.share * 100,
                est.lha, ADSprayerManager.MARGIN * 100, est.liters, cap)
            if target >= cap * 0.999 then
                log("%s : il faut plus qu'une cuve, plein (il reviendra en prendre)", name)
                target = nil
            end
        end
    end
    local needsFill
    if target ~= nil then
        needsFill = level < target - math.max(5, cap * 0.005)
    else
        needsFill = not ADSeederManager.productsFull(tool, { ftIndex }, vehicle)
    end
    return {
        kind = "sprayer", tool = tool, settings = { fillTypes = { s.fillType } }, marker = ADGraphManager:getMapMarkerByName(s.refill),
        fillTypes = { ftIndex }, field = ctx.field, needsFill = needsFill, target = target, fillUnit = unit,
        fillKey = "AD_autonomous_sprayerFill", emptyKey = "AD_autonomous_sprayerEmpty"
    }
end

function ADSprayerManager.preparePlan(vehicle, after)
    local ok, plan = pcall(ADSprayerManager.plan, vehicle, after or "field")
    if not ok then
        log("ERREUR plan de plein : %s", tostring(plan))
        return nil
    end
    return plan
end

-- ------------------------------------------------------------
-- Arrêt du chargement à la quantité voulue (hook AutonomousMode:monitorTasks)
-- ------------------------------------------------------------
-- Le LoadTrigger du jeu charge jusqu'à cuve pleine (pas de quantité). On le coupe nous-mêmes : setIsLoading(false)
-- (station, silo, fosse) ou setFillUnitIsFilling(false) (big bag, cuve IBC, citerne) ; puis l'étape de plein est
-- finie tout de suite, sinon AutoDrive relancerait le chargement (cuve pas pleine).
function ADSprayerManager.stopLoading(vehicle)
    local tm = vehicle.ad.trailerModule
    local trigger = tm.trigger
    if trigger ~= nil and trigger ~= tm and trigger.setIsLoading ~= nil and trigger.isLoading then
        trigger:setIsLoading(false)
    end
    local filling = tm.isFillingToTrailer
    if filling ~= nil and filling.setFillUnitIsFilling ~= nil then
        filling:setFillUnitIsFilling(false)
    end
    tm.isLoading = false
    tm.trigger = nil
    tm.isLoadingToTrailer = nil
    tm.isLoadingToFillUnitIndex = nil
    tm.isFillingToTrailer = nil
end

function ADSprayerManager.monitorTarget(mode, dt)
    local plan = mode.refillPlan
    if mode.refillStage ~= "load" or plan == nil or plan.kind ~= "sprayer" or plan.target == nil then
        return false
    end
    local vehicle = mode.vehicle
    local task = mode.refillTask
    if task == nil or vehicle.ad.taskModule:getActiveTask() ~= task then
        return false
    end
    local level = ADSprayerManager.content(plan.tool)
    if level < plan.target then
        return false
    end
    ADSprayerManager.stopLoading(vehicle)
    log("%s : quantité voulue atteinte (%.0f / %.0f L), chargement arrêté", tostring(vehicle.ad.stateModule:getName()), level, plan.target)
    -- raison de fin lue par le suivi du plein du semoir quand il est là (AutonomousRefill.lua, V1.0.1.16)
    task.fpEndReason = string.format("quantité voulue atteinte, %.0f L", plan.target)
    if task.continue ~= nil then
        task:continue()
    end
    task:finished()
    return true
end

-- ------------------------------------------------------------
-- Sauvegarde (FarmPilot_Epandeurs.xml dans la sauvegarde)
-- ------------------------------------------------------------
local function savegameFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local path = g_currentMission.missionInfo.savegameDirectory
    if path == nil then
        return nil
    end
    return path .. "/" .. ADSprayerManager.FILE_NAME
end

function ADSprayerManager:loadFromXml()
    if self.loaded then
        return
    end
    self.loaded = true
    self.settings = {}
    local file = savegameFile()
    if file == nil or not fileExists(file) then
        return
    end
    local xml = loadXMLFile("fpEpandeurs", file)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while true do
        local key = string.format("farmPilotEpandeurs.entry(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local s = {
            field = getXMLString(xml, key .. "#field"),
            tool = getXMLString(xml, key .. "#tool"),
            toolName = getXMLString(xml, key .. "#toolName"),
            fillType = getXMLString(xml, key .. "#fillType"),
            quantity = getXMLString(xml, key .. "#quantity"),
            refill = getXMLString(xml, key .. "#refill"),
            stamp = getXMLInt(xml, key .. "#stamp") or 0
        }
        if s.fillType == "" then
            s.fillType = nil
        end
        if s.refill == "" then
            s.refill = nil
        end
        if s.quantity ~= ADSprayerManager.QUANTITY_FIELD then
            s.quantity = ADSprayerManager.QUANTITY_FULL
        end
        if s.field ~= nil and s.tool ~= nil then
            self.settings[ADSeederManager.key(s.field, s.tool)] = s
            self.stamp = math.max(self.stamp, s.stamp)
        end
        i = i + 1
    end
    delete(xml)
    log("%d réglages d'épandeur chargés", i)
end

function ADSprayerManager:saveToXml()
    if not self.loaded then
        return
    end
    local file = savegameFile()
    if file == nil then
        return
    end
    local xml = createXMLFile("fpEpandeurs", file, "farmPilotEpandeurs")
    if xml == nil or xml == 0 then
        return
    end
    local keys = {}
    for k, _ in pairs(self.settings) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local s = self.settings[k]
        local key = string.format("farmPilotEpandeurs.entry(%d)", i - 1)
        setXMLString(xml, key .. "#field", tostring(s.field))
        setXMLString(xml, key .. "#tool", s.tool)
        setXMLString(xml, key .. "#toolName", s.toolName or "")
        setXMLString(xml, key .. "#fillType", s.fillType or "")
        setXMLString(xml, key .. "#quantity", s.quantity or ADSprayerManager.QUANTITY_FULL)
        setXMLString(xml, key .. "#refill", s.refill or "")
        setXMLInt(xml, key .. "#stamp", s.stamp or 0)
    end
    saveXMLFile(xml)
    delete(xml)
end
