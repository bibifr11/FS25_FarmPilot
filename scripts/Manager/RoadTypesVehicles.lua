-- ============================================================================================================
-- FarmPilot : RoadTypesVehicles.lua
-- Routes secondaires et tertiaires selon le type de véhicule (12/11).
--
-- Règles :
-- - Une roue dentée à côté des réglages véhicule « Routes secondaires » et « Routes tertiaires » ouvre une fenêtre
--   (RoadTypesGUI.lua) : Oui / Non pour chaque type de véhicule. Valable pour tous les véhicules, sauvegardé avec la
--   partie (réglages généraux, XML.lua) et envoyé aux joueurs (AutoDriveUpdateSettingsEvent).
-- - Types : tracteurs ; camions et semis ; voitures et pick-up ; chargeurs et télescopiques ; automoteurs
--   (moissonneuses, ensileuses, pulvérisateurs automoteurs…).
-- - Par défaut : Oui partout sauf camions et semis, voitures et pick-up.
-- - Ce réglage décide du « Auto » de chaque véhicule (DirtRoadManager.lua) :
--   secondaires : Oui = prises dès qu'elles font gagner du temps ; Non = seulement s'il n'y a pas d'autre route (x100).
--   tertiaires : Oui = permises pour accéder à une destination (vitesse limitée) ; Non = seulement s'il n'y a pas
--   d'autre route.
--   Le réglage de chaque véhicule reste pour forcer : Jamais ou Autorisées.
-- - Type d'un véhicule : catégorie du magasin (TRACTORS…, TRUCKS, CARS, chargeurs, récolte…), sinon par la vitesse
--   maxi (plus de 75 km/h : camion), sinon tracteur.
--
-- Branché par une ligne chacune : DirtRoadManager.lua (isAllowed, secondaryFactor) ; la fenêtre :
-- scripts/Gui/RoadTypesGUI.lua, gui/roadTypesGUI.xml, gui/vehicleSettingsPage.xml (roues dentées).
-- ============================================================================================================

ADRoadTypes = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADRoadTypes.KINDS = { "secondary", "tertiary" }

-- ordre des lignes de la fenêtre ; default = Oui / Non
ADRoadTypes.TYPES = {
    { key = "tractor", text = "gui_ad_roadTypes_tractor", default = true },
    { key = "truck", text = "gui_ad_roadTypes_truck", default = false },
    { key = "car", text = "gui_ad_roadTypes_car", default = false },
    { key = "loader", text = "gui_ad_roadTypes_loader", default = true },
    { key = "selfPropelled", text = "gui_ad_roadTypes_selfPropelled", default = true },
}

-- mots des catégories du magasin (catégorie en majuscules)
ADRoadTypes.LOADER_WORDS = { "LOADER", "SKIDSTEER", "FORKLIFT", "TELEHANDLER" }
ADRoadTypes.SELF_PROPELLED_WORDS = { "HARVEST", "SPRAYER", "MOWER", "WOOD", "FORESTRY", "SPREADER" }

-- nom du réglage général : secondaryRoads_tractor, dirtRoads_truck…
function ADRoadTypes.settingName(kind, typeKey)
    return (kind == "secondary" and "secondaryRoads_" or "dirtRoads_") .. typeKey
end

-- 10 réglages généraux (2 sortes de routes x 5 types), non affichés dans les pages de réglages
for _, kind in ipairs(ADRoadTypes.KINDS) do
    for _, t in ipairs(ADRoadTypes.TYPES) do
        AutoDrive.settings[ADRoadTypes.settingName(kind, t.key)] = {
            values = { false, true },
            texts = { "gui_ad_no", "gui_ad_yes" },
            default = t.default and 2 or 1,
            current = t.default and 2 or 1,
            text = t.text,
            tooltip = t.text,
            translate = true,
            isVehicleSpecific = false,
            isUserSpecific = false
        }
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Type d'un véhicule
-- ------------------------------------------------------------------------------------------------------------
local function hasWord(category, words)
    for _, w in ipairs(words) do
        if string.find(category, w, 1, true) ~= nil then
            return true
        end
    end
    return false
end

function ADRoadTypes.category(root)
    if g_storeManager == nil or root == nil or root.configFileName == nil then
        return ""
    end
    local ok, item = FarmPilotCall(g_storeManager.getItemByXMLFilename, g_storeManager, root.configFileName)
    if ok and item ~= nil and type(item.categoryName) == "string" then
        return string.upper(item.categoryName)
    end
    return ""
end

-- « tractor », « truck », « car », « loader » ou « selfPropelled » (gardé sur le véhicule)
function ADRoadTypes.vehicleType(vehicle)
    if vehicle == nil then
        return nil
    end
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if root.fpRoadType ~= nil then
        return root.fpRoadType
    end
    local category = ADRoadTypes.category(root)
    local t
    if string.find(category, "TRACTOR", 1, true) ~= nil then
        t = "tractor"
    elseif string.find(category, "TRUCK", 1, true) ~= nil then
        t = "truck"
    elseif category == "CARS" or string.find(category, "PICKUP", 1, true) ~= nil then
        t = "car"
    elseif hasWord(category, ADRoadTypes.LOADER_WORDS) then
        t = "loader"
    elseif root.spec_combine ~= nil or hasWord(category, ADRoadTypes.SELF_PROPELLED_WORDS) then
        t = "selfPropelled"
    elseif ADDirtRoads.isTruck(root) then
        t = "truck"                     -- autre catégorie, plus de 75 km/h
    elseif category ~= "" then
        t = "selfPropelled"             -- autre catégorie, véhicule lent
    else
        t = "tractor"                   -- sans catégorie
    end
    root.fpRoadType = t
    return t
end

function ADRoadTypes.typeEntry(typeKey)
    for _, t in ipairs(ADRoadTypes.TYPES) do
        if t.key == typeKey then
            return t
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Oui / Non
-- ------------------------------------------------------------------------------------------------------------
function ADRoadTypes.get(kind, typeKey)
    local value = AutoDrive.getSetting(ADRoadTypes.settingName(kind, typeKey))
    if value == nil then
        local t = ADRoadTypes.typeEntry(typeKey)
        return t == nil or t.default
    end
    return value == true
end

-- « Auto » du véhicule : permis ? et pourquoi (pour le journal)
function ADRoadTypes.allowed(kind, vehicle)
    local typeKey = ADRoadTypes.vehicleType(vehicle) or "tractor"
    local yes = ADRoadTypes.get(kind, typeKey)
    return yes, string.format("Auto, %s : %s", typeKey, yes and "Oui" or "Non")
end

-- enregistre les choix de la fenêtre : { [typeKey] = true / false } ; envoyé aux joueurs
function ADRoadTypes.set(kind, choices)
    for typeKey, yes in pairs(choices) do
        local setting = AutoDrive.settings[ADRoadTypes.settingName(kind, typeKey)]
        if setting ~= nil then
            setting.current = yes and 2 or 1
            setting.new = setting.current
        end
    end
    if AutoDriveUpdateSettingsEvent ~= nil then
        FarmPilotCall(AutoDriveUpdateSettingsEvent.sendEvent, nil)
    end
    print(string.format("[FarmPilot Routes] %s : %s", kind == "secondary" and "routes secondaires" or "routes tertiaires", ADRoadTypes.describe(kind)))
end

-- « tractor Oui, truck Non… » pour le journal
function ADRoadTypes.describe(kind)
    local parts = {}
    for _, t in ipairs(ADRoadTypes.TYPES) do
        parts[#parts + 1] = t.key .. " " .. (ADRoadTypes.get(kind, t.key) and "Oui" or "Non")
    end
    return table.concat(parts, ", ")
end
