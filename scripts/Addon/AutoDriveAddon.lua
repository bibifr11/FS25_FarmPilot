-- ============================================================================================================
-- FarmPilot : AutoDriveAddon.lua
-- Fonctions de l'ancien « AutoDrive Addon », intégrées à FarmPilot (même environnement Lua) : socle commun des
-- fichiers de scripts/Addon.
--
-- Règle : chaque addon s'inscrit par ADAddon.addModule à la fin de son fichier ; au chargement de la carte
-- (loadMap), leurs install sont appelés dans l'ordre d'inscription, donc dans l'ordre de register.lua : LightsOff,
-- TurnLights, TurnLightsBends, EngineStop, Weighing, SiloEmpty, RearTool. Deux enveloppent la même fonction
-- d'AutoDrive (updateAutoDriveLights : LightsOff puis TurnLightsBends) : cet ordre compte.
-- Les réglages des addons sont ajoutés à AutoDrive.settings (sauvegarde et multijoueur par AutoDrive) au chargement
-- de leur fichier, et leur ligne est copiée de « Clignotant automatique » dans la page de réglages d'AutoDrive.
-- L'ancien mod FS25_AutoDriveAddon encore activé : il fait déjà tout, rien n'est installé en double.
--
-- Branché par : register.lua (chargé avant les autres fichiers de scripts/Addon) ; addModEventListener (loadMap).
-- ============================================================================================================

ADAddon = {}

-- ------------------------------------------------------------------------------------------------------------
-- État
-- ------------------------------------------------------------------------------------------------------------
ADAddon.modName = g_currentModName
ADAddon.modules = {}
ADAddon.settingRows = {}

-- L'ancien mod FS25_AutoDriveAddon encore activé : il fait déjà tout, on ne double pas
ADAddon.disabled = g_modIsLoaded ~= nil and g_modIsLoaded["FS25_AutoDriveAddon"] == true

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
-- Classes de FarmPilot : même environnement, lues au moment de l'appel
local function farmPilotGlobals()
    return {
        AutoDrive = AutoDrive,
        ADSettingsPage = ADSettingsPage,
        ADSpecialDrivingModule = ADSpecialDrivingModule,
        LoadAtDestinationTask = LoadAtDestinationTask,
        ADDrivePathModule = ADDrivePathModule,
        ADTaskModule = ADTaskModule,
        ADStateModule = ADStateModule,
    }
end

function ADAddon.getAutoDriveGlobal(name)
    local v = farmPilotGlobals()[name]
    if v ~= nil then
        return v
    end
    return _G[name]
end

-- Seuls les problèmes vont dans le log
function ADAddon.warning(text)
    print("FarmPilot: " .. tostring(text))
end

-- Textes des fichiers translations/translation_xx.xml de l'addon
function ADAddon.getText(key)
    if g_i18n ~= nil then
        local ok, text = FarmPilotCall(g_i18n.getText, g_i18n, key)
        if ok and type(text) == "string" and text ~= "" and not text:find("^Missing") then
            return text
        end
    end
    return key
end

-- ------------------------------------------------------------------------------------------------------------
-- Modules (un par fichier de scripts/Addon)
-- ------------------------------------------------------------------------------------------------------------
function ADAddon.addModule(module)
    if ADAddon.disabled then
        return
    end
    table.insert(ADAddon.modules, module)
end

-- ------------------------------------------------------------------------------------------------------------
-- Réglages de l'addon dans les réglages d'AutoDrive
-- Le réglage est ajouté à AutoDrive.settings (sauvegarde et multijoueur par AutoDrive)
-- et sa ligne est copiée de « Clignotant automatique » dans la page d'AutoDrive.
-- ------------------------------------------------------------------------------------------------------------
-- Doit être appelé au chargement du fichier, avant qu'AutoDrive lise sa configuration
function ADAddon.addSetting(name, setting, afterName, labelKey, tooltipKey)
    if ADAddon.disabled then
        return
    end
    local autoDrive = ADAddon.getAutoDriveGlobal("AutoDrive")
    if autoDrive == nil or autoDrive.settings == nil then
        return
    end
    if autoDrive.settings[name] == nil then
        setting.current = setting.default
        setting.translate = false
        setting.isVehicleSpecific = false
        autoDrive.settings[name] = setting
    end
    table.insert(ADAddon.settingRows, { name = name, after = afterName, label = labelKey, tooltip = tooltipKey })
end

local function findFirst(el, pred)
    if el == nil or el.elements == nil then return nil end
    for _, c in ipairs(el.elements) do
        if pred(c) then return c end
        local r = findFirst(c, pred)
        if r ~= nil then return r end
    end
    return nil
end

local function profileContains(c, word)
    return c.profile ~= nil and string.find(string.lower(tostring(c.profile)), word, 1, true) ~= nil
end

local function isTextElement(c)
    return c.isa ~= nil and c:isa(TextElement)
end

function ADAddon.addSettingRow(page, info)
    local autoDrive = ADAddon.getAutoDriveGlobal("AutoDrive")
    local setting = autoDrive.settings[info.name]
    local source = page.settingElements.blinkValue
    local after = page.settingElements[info.after]
    if source == nil or after == nil or setting == nil or page.settingElements[info.name] ~= nil then
        return
    end
    local row = source.parent
    local afterRow = after.parent
    local layout = row.parent
    -- suppressOnCreate : sinon la copie s'enregistrerait à la place de « Clignotant automatique »
    local newRow = row:clone(layout, false, true)
    local option = findFirst(newRow, function(c) return c.isa ~= nil and c:isa(MultiTextOptionElement) end)
    if option == nil then
        newRow:delete()
        ADAddon.warning("setting option not found for " .. info.name)
        return
    end

    -- la copie est ajoutée en fin de page : on la remonte juste sous la ligne voulue
    for i, c in ipairs(layout.elements) do
        if c == newRow then
            table.remove(layout.elements, i)
            break
        end
    end
    for i, c in ipairs(layout.elements) do
        if c == afterRow then
            table.insert(layout.elements, i + 1, newRow)
            break
        end
    end

    option.name = info.name
    option.id = info.name
    option:setTexts(setting.texts)
    local tip = findFirst(newRow, function(c) return isTextElement(c) and profileContains(c, "tooltip") end)
    if tip ~= nil then
        tip:setText(ADAddon.getText(info.tooltip))
    end
    for _, c in ipairs(newRow.elements) do
        if c ~= option and isTextElement(c) and not profileContains(c, "tooltip") then
            c:setText(ADAddon.getText(info.label))
            break
        end
    end
    page.settingElements[info.name] = option

    -- couleurs alternées des lignes après l'ajout
    local even = false
    for _, c in ipairs(layout.elements) do
        if c.setImageColor ~= nil and c.profile == row.profile then
            c:setImageColor(nil, table.unpack(InGameMenuSettingsFrame.COLOR_ALTERNATING[even]))
            even = not even
        end
    end
    if layout.invalidateLayout ~= nil then layout:invalidateLayout() end
end

local function installSettingRows()
    local settingsPage = ADAddon.getAutoDriveGlobal("ADSettingsPage")
    if settingsPage == nil or settingsPage.onFrameOpen == nil then
        ADAddon.warning("AutoDrive settings page not found, addon settings not shown")
        return
    end
    local originalOpen = settingsPage.onFrameOpen
    settingsPage.onFrameOpen = function(page, ...)
        if page.settingElements ~= nil and page.settingElements.blinkValue ~= nil and not page.adAddonRowsAdded then
            page.adAddonRowsAdded = true
            for _, info in ipairs(ADAddon.settingRows) do
                local ok, err = FarmPilotCall(ADAddon.addSettingRow, page, info)
                if not ok then
                    ADAddon.warning("error adding setting " .. info.name .. ": " .. tostring(err))
                end
            end
        end
        return originalOpen(page, ...)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place, au chargement de la carte
-- ------------------------------------------------------------------------------------------------------------
function ADAddon:loadMap(name)
    if ADAddon.disabled then
        print("FarmPilot: FS25_AutoDriveAddon is active, its functions are now part of FarmPilot (disable FS25_AutoDriveAddon)")
        return
    end
    local autoDrive = ADAddon.getAutoDriveGlobal("AutoDrive")
    if autoDrive == nil or autoDrive.currentModName == nil then
        ADAddon.warning("AutoDrive not found, addon inactive")
        return
    end
    for _, module in ipairs(ADAddon.modules) do
        local ok, err = FarmPilotCall(module.install, autoDrive)
        if not ok then
            ADAddon.warning("error: " .. tostring(err))
        end
    end
    installSettingRows()
end

-- ------------------------------------------------------------------------------------------------------------
-- Enregistrement
-- ------------------------------------------------------------------------------------------------------------
addModEventListener(ADAddon)
