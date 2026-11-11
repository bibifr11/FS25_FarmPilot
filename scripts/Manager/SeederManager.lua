-- ============================================================================================================
-- FarmPilot : SeederManager.lua
-- Mode Autonome : le semoir (08/11).
--
-- Règle :
-- - Semoir sur la ligne « Outil » (ou « Outil suivant ») : une roue dentée apparaît à gauche de la ligne. Elle ouvre
--   la fenêtre « Réglages du semoir » (SeederSettingsGUI.lua) : culture à semer (de saison seulement), produits à
--   charger (semence, engrais : choix multiple comme le mode Chargement) et zone de ravitaillement (un marqueur de la
--   carte). Choix retenu par champ (nom du marqueur de la ligne « Champ ») et par semoir (modèle).
-- - Tant que ce n'est pas validé, le départ est refusé (roue dentée orange, verte une fois validé).
-- - Le plein se fait comme dans le mode Chargement (LoadAtDestinationTask) : au départ si le semoir n'est pas plein,
--   et quand Courseplay s'arrête semoir vide (il sort du champ, fait le plein, revient, et Courseplay repart au
--   dernier point).
--
-- Branché par : AutonomousMode.lua (start : startBlock et prepare ; plein : setLoadFillTypes, productsFull,
-- fillText ; onCpEmpty : prepare), HudButton.lua (status : roue dentée), AutoDrive.lua (saveToXml),
-- SeederSettingsGUI.lua. AutonomousRefill.lua, chargé après ce fichier, remplace productsFull (et lit fillUnits,
-- context) ; SprayerManager.lua et AutonomousSprayerDump.lua reprennent toolKey, attachedTo, rowField, key et
-- EXCLUDED_FILLTYPES.
-- ============================================================================================================

ADSeederManager = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADSeederManager.FILE_NAME = "FarmPilot_Semoirs.xml"
ADSeederManager.settings = {}   -- [nom du champ .. "|" .. clé du semoir] = { field, tool, toolName, fruit, fillTypes = {noms}, refill, stamp }
ADSeederManager.loaded = false
ADSeederManager.stamp = 0
-- jamais proposés au chargement (carburants, air, inconnu)
ADSeederManager.EXCLUDED_FILLTYPES = { "UNKNOWN", "AIR", "DIESEL", "DEF", "ELECTRICCHARGE", "METHANE" }

local function log(fmt, ...)
    print("[FarmPilot Semoir] " .. string.format(fmt, ...))
end
ADSeederManager.log = log

-- ------------------------------------------------------------------------------------------------------------
-- Quel semoir, quel champ (lignes « Outil » et « Champ » du HUD)
-- ------------------------------------------------------------------------------------------------------------
function ADSeederManager.isSeeder(tool)
    return tool ~= nil and tool.spec_sowingMachine ~= nil and not tool.isDeleted and not tool.isDeleting
end

function ADSeederManager.toolKey(tool)
    local k = ADAutonomousManager.shortConfigName ~= nil and ADAutonomousManager.shortConfigName(tool) or nil
    return k or "?"
end

local function attachedTo(tool, vehicle)
    if tool == nil or vehicle == nil or tool.getAttacherVehicle == nil then
        return false
    end
    local attacher = tool:getAttacherVehicle()
    if attacher == nil then
        return false
    end
    local root = tool.getRootVehicle ~= nil and tool:getRootVehicle() or attacher
    return root == vehicle or attacher == vehicle
end
ADSeederManager.attachedTo = attachedTo

-- outil de la ligne « Outil » : celui choisi, sinon celui attelé (un seul outil de travail) ;
-- ligne « Outil suivant » : celui choisi, sinon le même que la ligne « Outil »
function ADSeederManager.rowTool(vehicle, isNext)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or sm.getFpTool == nil then
        return nil
    end
    if isNext then
        local nextTool = sm.getFpNextTool ~= nil and sm:getFpNextTool() or nil
        if nextTool ~= nil then
            return nextTool
        end
    end
    local tool = sm:getFpTool()
    if tool ~= nil then
        return tool
    end
    local tools = ADAutonomousManager.workTools(vehicle)
    if #tools == 1 then
        return tools[1]
    end
    return nil
end

-- marqueur de la ligne « Champ » (ou « Champ suivant »)
function ADSeederManager.rowField(vehicle, isNext)
    local sm = vehicle.ad.stateModule
    if isNext then
        return sm.getFpNextField ~= nil and sm:getFpNextField() or nil
    end
    return sm:getFirstMarker()
end

-- { tool, toolKey, field (nom du marqueur), marker } si la ligne a un semoir et un champ ; sinon nil
function ADSeederManager.context(vehicle, isNext)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil then
        return nil
    end
    if vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return nil
    end
    local tool = ADSeederManager.rowTool(vehicle, isNext)
    if not ADSeederManager.isSeeder(tool) then
        return nil
    end
    local marker = ADSeederManager.rowField(vehicle, isNext)
    if marker == nil or marker.name == nil then
        return nil
    end
    return { tool = tool, toolKey = ADSeederManager.toolKey(tool), field = marker.name, marker = marker }
end

-- ------------------------------------------------------------------------------------------------------------
-- Ce que le semoir sait faire
-- ------------------------------------------------------------------------------------------------------------
-- cultures que le semoir sait semer : { {index, name, title} }, et si le joueur peut en changer
function ADSeederManager.fruitChoices(tool)
    local out = {}
    local spec = tool ~= nil and tool.spec_sowingMachine or nil
    if spec == nil or spec.seeds == nil or g_fruitTypeManager == nil then
        return out, false
    end
    for _, fruitIndex in ipairs(spec.seeds) do
        local ft = g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
        local fill = g_fruitTypeManager.getFillTypeByFruitTypeIndex ~= nil and g_fruitTypeManager:getFillTypeByFruitTypeIndex(fruitIndex) or nil
        if ft ~= nil and ft.name ~= nil then
            out[#out + 1] = { index = fruitIndex, name = ft.name, title = (fill ~= nil and fill.title) or ft.name }
        end
    end
    -- (08/11) cultures de saison seulement : semable maintenant, d'après le calendrier du jeu
    -- (celui que le semoir lui-même vérifie : FruitTypeDesc:getIsPlantableInPeriod)
    local outside = false
    if tool.getCanPlantOutsideSeason ~= nil then
        local okO, o = FarmPilotCall(tool.getCanPlantOutsideSeason, tool)
        outside = okO and o == true
    end
    for _, e in ipairs(out) do
        e.inSeason = outside or ADSeederManager.isPlantableNow(e.index)
    end
    local allowed = spec.allowsSeedChanging ~= false
    if tool.getIsSeedChangeAllowed ~= nil then
        local ok, a = FarmPilotCall(tool.getIsSeedChangeAllowed, tool)
        if ok and a ~= nil then
            allowed = a
        end
    end
    return out, allowed and #out > 1
end

function ADSeederManager.isPlantableNow(fruitIndex)
    local mission = g_currentMission
    local ft = g_fruitTypeManager ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex) or nil
    if ft == nil or ft.getIsPlantableInPeriod == nil or mission == nil or mission.missionInfo == nil or mission.environment == nil then
        return true
    end
    local ok, r = FarmPilotCall(ft.getIsPlantableInPeriod, ft, mission.missionInfo.growthMode, mission.environment.currentPeriod)
    return not ok or r == true
end

function ADSeederManager.currentFruit(tool)
    local spec = tool ~= nil and tool.spec_sowingMachine or nil
    if spec == nil or spec.seeds == nil then
        return nil
    end
    local fruitIndex = spec.seeds[spec.currentSeed or 1]
    local ft = fruitIndex ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex) or nil
    return ft ~= nil and ft.name or nil
end

-- cuves du semoir à remplir : celle de la semence et celle de l'engrais (semoir-fertiliseur)
function ADSeederManager.fillUnits(tool)
    local units = {}
    local function add(i)
        if type(i) == "number" and i > 0 and tool.getFillUnitByIndex ~= nil and tool:getFillUnitByIndex(i) ~= nil then
            for _, u in ipairs(units) do
                if u == i then
                    return
                end
            end
            units[#units + 1] = i
        end
    end
    if tool.getSowingMachineFillUnitIndex ~= nil then
        add(tool:getSowingMachineFillUnitIndex())
    elseif tool.spec_sowingMachine ~= nil then
        add(tool.spec_sowingMachine.fillUnitIndex)
    end
    if tool.spec_sprayer ~= nil and tool.getSprayerFillUnitIndex ~= nil then
        add(tool:getSprayerFillUnitIndex())
    end
    return units
end

local function isExcluded(name)
    for _, n in ipairs(ADSeederManager.EXCLUDED_FILLTYPES) do
        if n == name then
            return true
        end
    end
    return false
end

-- produits que les cuves du semoir acceptent : { {index, name, title} } (semence d'abord)
function ADSeederManager.loadChoices(tool)
    local out, seen = {}, {}
    if tool == nil or tool.getFillUnitSupportedFillTypes == nil then
        return out
    end
    for _, unit in ipairs(ADSeederManager.fillUnits(tool)) do
        local supported = tool:getFillUnitSupportedFillTypes(unit) or {}
        local list = {}
        for fillTypeIndex, ok in pairs(supported) do
            if ok and not seen[fillTypeIndex] then
                local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
                if name ~= nil and not isExcluded(name) then
                    local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                    list[#list + 1] = { index = fillTypeIndex, name = name, title = (ft ~= nil and ft.title) or name }
                    seen[fillTypeIndex] = true
                end
            end
        end
        table.sort(list, function(a, b)
            if (a.name == "SEEDS") ~= (b.name == "SEEDS") then
                return a.name == "SEEDS"
            end
            return tostring(a.title) < tostring(b.title)
        end)
        for _, e in ipairs(list) do
            out[#out + 1] = e
        end
    end
    return out
end

-- ------------------------------------------------------------------------------------------------------------
-- Mémoire champ + semoir
-- ------------------------------------------------------------------------------------------------------------
function ADSeederManager.key(field, toolKey)
    return tostring(field) .. "|" .. tostring(toolKey)
end

function ADSeederManager:get(field, toolKey)
    self:loadFromXml()
    return self.settings[ADSeederManager.key(field, toolKey)]
end

-- derniers réglages de ce semoir (n'importe quel champ), pour préremplir la fenêtre
function ADSeederManager:lastFor(toolKey)
    self:loadFromXml()
    local best = nil
    for _, s in pairs(self.settings) do
        if s.tool == toolKey and (best == nil or (s.stamp or 0) > (best.stamp or 0)) then
            best = s
        end
    end
    return best
end

function ADSeederManager:set(field, tool, s)
    self:loadFromXml()
    self.stamp = self.stamp + 1
    local toolKey = ADSeederManager.toolKey(tool)
    local entry = {
        field = field, tool = toolKey, toolName = ADAutonomousManager.toolLabel(tool), fruit = s.fruit,
        fillTypes = { unpack(s.fillTypes or {}) }, refill = s.refill, stamp = self.stamp
    }
    self.settings[ADSeederManager.key(field, toolKey)] = entry
    log("« %s », semoir %s : culture %s, charge %s, ravitaillement « %s »", tostring(field), toolKey, tostring(entry.fruit or "-"),
        table.concat(entry.fillTypes, "+"), tostring(entry.refill))
    return entry
end

-- ce qui manque : nil si c'est bon, sinon « fill » (aucun produit) ou « refill » (zone absente ou effacée)
function ADSeederManager.missing(s)
    if s == nil then
        return "none"
    end
    if s.fillTypes == nil or #s.fillTypes == 0 then
        return "fill"
    end
    if s.refill == nil or ADGraphManager:getMapMarkerByName(s.refill) == nil then
        return "refill"
    end
    return nil
end

function ADSeederManager.isValid(s)
    return ADSeederManager.missing(s) == nil
end

-- roue dentée du HUD : « none » (pas de semoir sur la ligne), « ok » (validé), « todo » (à régler)
function ADSeederManager.status(vehicle, isNext)
    local ctx = ADSeederManager.context(vehicle, isNext)
    if ctx == nil then
        return "none"
    end
    if ADSeederManager.isValid(ADSeederManager:get(ctx.field, ctx.toolKey)) then
        return "ok"
    end
    return "todo"
end

-- départ refusé ? { label, field, isNext } si un semoir des lignes Outil / Outil suivant n'est pas réglé pour son champ
function ADSeederManager.startBlock(vehicle)
    for _, isNext in ipairs({ false, true }) do
        local ctx = ADSeederManager.context(vehicle, isNext)
        if ctx ~= nil and not ADSeederManager.isValid(ADSeederManager:get(ctx.field, ctx.toolKey)) then
            local okL, label = FarmPilotCall(ADAutonomousManager.toolShortLabel, ctx.tool)
            return { label = okL and label or ADAutonomousManager.toolLabel(ctx.tool), field = ctx.field, isNext = isNext }
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Plein
-- ------------------------------------------------------------------------------------------------------------
function ADSeederManager.fillTypeIndices(s)
    local out = {}
    for _, name in ipairs(s.fillTypes or {}) do
        local idx = g_fillTypeManager:getFillTypeIndexByName(name)
        if idx ~= nil then
            out[#out + 1] = idx
        end
    end
    return out
end

-- toutes les cuves qui prennent un des produits choisis sont pleines (réglage « niveau de remplissage » du mode Chargement)
function ADSeederManager.productsFull(tool, fillTypes, rootVehicle)
    local level = AutoDrive.getSetting("unloadFillLevel", rootVehicle) or 1
    local found = false
    for fillUnitIndex, _ in pairs(tool:getFillUnits()) do
        local supported = tool:getFillUnitSupportedFillTypes(fillUnitIndex) or {}
        local wanted = false
        for _, ft in ipairs(fillTypes) do
            if supported[ft] then
                wanted = true
            end
        end
        if wanted then
            local cap = tool:getFillUnitCapacity(fillUnitIndex) or 0
            if cap > 0 then
                found = true
                if tool:getFillUnitFillLevel(fillUnitIndex) < cap * level * 0.999 - 0.01 then
                    return false
                end
            end
        end
    end
    return found
end

-- remplissage en cours des cuves choisies (pour le log)
function ADSeederManager.fillText(tool, fillTypes)
    local parts = {}
    for fillUnitIndex, _ in pairs(tool:getFillUnits()) do
        local supported = tool:getFillUnitSupportedFillTypes(fillUnitIndex) or {}
        for _, ft in ipairs(fillTypes) do
            if supported[ft] then
                local cap = tool:getFillUnitCapacity(fillUnitIndex) or 0
                parts[#parts + 1] = string.format("cuve %d %.0f/%.0f", fillUnitIndex, tool:getFillUnitFillLevel(fillUnitIndex) or 0, cap)
                break
            end
        end
    end
    return table.concat(parts, ", ")
end

-- produits choisis = produits du mode Chargement (le plein suit la liste, comme le mode Chargement)
function ADSeederManager.setLoadFillTypes(vehicle, fillTypes)
    local sm = vehicle.ad.stateModule
    if #fillTypes == 0 then
        return
    end
    sm.fillType = fillTypes[1]
    sm.selectedFillTypes = { unpack(fillTypes) }
    sm:raiseDirtyFlag()
end

-- Courseplay suit le choix : engrais chargé = semoir fertiliseur actif ; semoir vide = Courseplay s'arrête et le
-- signale (FarmPilot va remplir), au lieu d'attendre sur place
function ADSeederManager.applyCpSettings(vehicle, s, fillTypes)
    if vehicle.getCpSettings == nil then
        return
    end
    local okS, settings = FarmPilotCall(vehicle.getCpSettings, vehicle)
    if not okS or settings == nil then
        return
    end
    local refill = settings.refillOnTheField
    if refill ~= nil and refill.getValue ~= nil and refill:getValue() ~= 0 then
        FarmPilotCall(refill.setValue, refill, 0)
        log("Courseplay : « plein dans le champ » remis sur désactivé (FarmPilot va remplir à la zone)")
    end
    local fert = settings.sowingMachineFertilizerEnabled
    if fert ~= nil and fert.getValue ~= nil then
        local wantFert = false
        for _, name in ipairs(s.fillTypes or {}) do
            if name == "FERTILIZER" or name == "LIQUIDFERTILIZER" then
                wantFert = true
            end
        end
        if fert:getValue() ~= wantFert then
            FarmPilotCall(fert.setValue, fert, wantFert)
            log("Courseplay : engrais du semoir %s", wantFert and "activé" or "désactivé")
        end
    end
end

-- semoir attelé et réglé : culture mise sur le semoir, réglages Courseplay ; renvoie le plan de plein
-- { tool, settings, marker, fillTypes, needsFill } ou nil (pas de semoir réglé attelé)
function ADSeederManager.prepare(vehicle)
    local ctx = ADSeederManager.context(vehicle, false)
    if ctx == nil or not attachedTo(ctx.tool, vehicle) then
        return nil
    end
    local s = ADSeederManager:get(ctx.field, ctx.toolKey)
    if not ADSeederManager.isValid(s) then
        return nil
    end
    local tool = ctx.tool
    if s.fruit ~= nil and tool.setSeedFruitType ~= nil and g_fruitTypeManager ~= nil then
        local ft = g_fruitTypeManager:getFruitTypeByName(s.fruit)
        if ft ~= nil and ADSeederManager.currentFruit(tool) ~= s.fruit then
            FarmPilotCall(tool.setSeedFruitType, tool, ft.index)
            log("culture « %s » mise sur le semoir", tostring(s.fruit))
        end
    end
    local fillTypes = ADSeederManager.fillTypeIndices(s)
    FarmPilotCall(ADSeederManager.applyCpSettings, vehicle, s, fillTypes)
    local marker = ADGraphManager:getMapMarkerByName(s.refill)
    return {
        tool = tool, settings = s, marker = marker, fillTypes = fillTypes, field = ctx.field,
        needsFill = not ADSeederManager.productsFull(tool, fillTypes, vehicle)
    }
end

-- ------------------------------------------------------------------------------------------------------------
-- Sauvegarde (FarmPilot_Semoirs.xml dans la sauvegarde)
-- ------------------------------------------------------------------------------------------------------------
local function savegameFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local path = g_currentMission.missionInfo.savegameDirectory
    if path == nil then
        return nil
    end
    return path .. "/" .. ADSeederManager.FILE_NAME
end

function ADSeederManager:loadFromXml()
    if self.loaded then
        return
    end
    self.loaded = true
    self.settings = {}
    local file = savegameFile()
    if file == nil or not fileExists(file) then
        return
    end
    local xml = loadXMLFile("fpSemoirs", file)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while true do
        local key = string.format("farmPilotSemoirs.entry(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local s = {
            field = getXMLString(xml, key .. "#field"),
            tool = getXMLString(xml, key .. "#tool"),
            toolName = getXMLString(xml, key .. "#toolName"),
            fruit = getXMLString(xml, key .. "#fruit"),
            refill = getXMLString(xml, key .. "#refill"),
            stamp = getXMLInt(xml, key .. "#stamp") or 0,
            fillTypes = {}
        }
        local list = getXMLString(xml, key .. "#fillTypes")
        if list ~= nil then
            for name in list:gmatch("[^,%s]+") do
                s.fillTypes[#s.fillTypes + 1] = name
            end
        end
        if s.fruit == "" then
            s.fruit = nil
        end
        if s.refill == "" then
            s.refill = nil
        end
        if s.field ~= nil and s.tool ~= nil then
            self.settings[ADSeederManager.key(s.field, s.tool)] = s
            self.stamp = math.max(self.stamp, s.stamp)
        end
        i = i + 1
    end
    delete(xml)
    log("%d réglages de semoir chargés", i)
end

function ADSeederManager:saveToXml()
    if not self.loaded then
        return
    end
    local file = savegameFile()
    if file == nil then
        return
    end
    local xml = createXMLFile("fpSemoirs", file, "farmPilotSemoirs")
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
        local key = string.format("farmPilotSemoirs.entry(%d)", i - 1)
        setXMLString(xml, key .. "#field", tostring(s.field))
        setXMLString(xml, key .. "#tool", s.tool)
        setXMLString(xml, key .. "#toolName", s.toolName or "")
        setXMLString(xml, key .. "#fruit", s.fruit or "")
        setXMLString(xml, key .. "#fillTypes", table.concat(s.fillTypes or {}, ","))
        setXMLString(xml, key .. "#refill", s.refill or "")
        setXMLInt(xml, key .. "#stamp", s.stamp or 0)
    end
    saveXMLFile(xml)
    delete(xml)
end
