-- ============================================================================================================
-- FarmPilot : RoadTypesGUI.lua
-- Fenêtre « types de véhicules » des routes secondaires ou tertiaires (12/11).
--
-- Règle :
-- - Ouverte par la roue dentée à côté de « Routes secondaires » ou de « Routes tertiaires » (réglages généraux
--   depuis le 14/11, avant : réglages véhicule).
-- - Une ligne par type de véhicule (RoadTypesVehicles.lua) : Oui / Non. « Changer » (ou double clic) bascule la
--   ligne ; « Valider » enregistre pour tous les véhicules (réglages généraux, envoyés aux joueurs) ; « Retour »
--   ferme sans enregistrer.
-- - Le haut de la fenêtre dit ce que Oui / Non veulent dire et le type du véhicule où l'on est.
--
-- Branché par une ligne chacune : Gui.lua (ADRoadTypesGui.load, gui/roadTypesGUI.xml) et
-- gui/globalSettingsPage.xml (boutons « gearSecondary » / « gearTertiary », ADSettingsPage:onClickRoadTypes ; dans
-- gui/vehicleSettingsPage.xml jusqu'au 13/11).
-- ============================================================================================================

ADRoadTypesGui = {}
ADRoadTypesGui.context = nil -- { kind = "secondary" / "tertiary", vehicle }

local ADRoadTypesGui_mt = Class(ADRoadTypesGui, DialogElement)

-- ------------------------------------------------------------------------------------------------------------
-- Chargement et ouverture
-- ------------------------------------------------------------------------------------------------------------
function ADRoadTypesGui.load()
    AutoDrive.gui.ADRoadTypesGui = ADRoadTypesGui.new()
    local result = g_gui:loadGui(AutoDrive.directory .. "gui/roadTypesGUI.xml", "ADRoadTypesGui", AutoDrive.gui.ADRoadTypesGui)
    if result == nil then
        AutoDrive.debugMsg(nil, "AutoDrive:loadGUI failed roadTypesGUI")
    end
end

function ADRoadTypesGui.open(kind, vehicle)
    local gui = AutoDrive.gui ~= nil and AutoDrive.gui.ADRoadTypesGui or nil
    if gui ~= nil and not gui.isOpen then
        ADRoadTypesGui.context = { kind = kind, vehicle = vehicle }
        g_gui:showDialog("ADRoadTypesGui")
    end
end

-- roue dentée d'une ligne des réglages véhicule (gui/vehicleSettingsPage.xml)
function ADSettingsPage:onClickRoadTypes(element)
    local kind = (element ~= nil and element.name == "gearTertiary") and "tertiary" or "secondary"
    ADRoadTypesGui.open(kind, AutoDrive.getControlledVehicle())
end

function ADRoadTypesGui.new(target)
    local self = DialogElement.new(target, ADRoadTypesGui_mt)
    self.rows = {}
    self.draft = {}
    return self
end

function ADRoadTypesGui:onOpen()
    ADRoadTypesGui:superClass().onOpen(self)
    self.settingsList:setDataSource(self)
    local c = ADRoadTypesGui.context or {}
    self.kind = c.kind == "tertiary" and "tertiary" or "secondary"
    self.vehicle = c.vehicle
    -- brouillon = réglages enregistrés
    self.draft = {}
    for _, t in ipairs(ADRoadTypes.TYPES) do
        self.draft[t.key] = ADRoadTypes.get(self.kind, t.key)
    end
    self:refreshItems()
    FarmPilotCall(self.settingsList.setSelectedIndex, self.settingsList, 1)
end

-- ------------------------------------------------------------------------------------------------------------
-- Lignes de la fenêtre
-- ------------------------------------------------------------------------------------------------------------
function ADRoadTypesGui:getNumberOfItemsInSection(list, section)
    if list == self.settingsList then
        return #self.rows
    end
    return 0
end

function ADRoadTypesGui:populateCellForItemInSection(list, section, index, cell)
    if list == self.settingsList then
        local row = self.rows[index]
        cell.attributes.listItemText:setText(row.text or "")
        cell.attributes.listItemValue:setText(row.value or "")
        cell.target = self
    end
end

function ADRoadTypesGui:isChanged()
    for _, t in ipairs(ADRoadTypes.TYPES) do
        if self.draft[t.key] ~= ADRoadTypes.get(self.kind, t.key) then
            return true
        end
    end
    return false
end

function ADRoadTypesGui:refreshItems()
    self.rows = {}
    local vehicleType = self.vehicle ~= nil and ADRoadTypes.vehicleType(self.vehicle) or nil
    for _, t in ipairs(ADRoadTypes.TYPES) do
        local text = g_i18n:getText(t.text)
        if t.key == vehicleType then
            text = text .. "  " .. g_i18n:getText("gui_ad_roadTypes_thisVehicle")
        end
        self.rows[#self.rows + 1] = { key = t.key, text = text, value = g_i18n:getText(self.draft[t.key] and "gui_ad_yes" or "gui_ad_no") }
    end
    if self.titleText ~= nil then
        self.titleText:setText(g_i18n:getText("gui_ad_roadTypes_title_" .. self.kind))
    end
    local info = g_i18n:getText("gui_ad_roadTypes_info_" .. self.kind)
    if self:isChanged() then
        info = info .. "\n" .. g_i18n:getText("gui_ad_roadTypes_todo")
    end
    self.infoText:setText(info)
    self.settingsList:reloadData()
end

-- ------------------------------------------------------------------------------------------------------------
-- Boutons
-- ------------------------------------------------------------------------------------------------------------
function ADRoadTypesGui:act(row)
    if row == nil then
        return
    end
    self.draft[row.key] = not self.draft[row.key]
    local index = self.settingsList:getSelectedIndexInSection()
    self:refreshItems()
    FarmPilotCall(self.settingsList.setSelectedIndex, self.settingsList, index)
end

function ADRoadTypesGui:onDoubleClick(list, section, index, cell)
    self:act(self.rows[index])
end

function ADRoadTypesGui:onClickChange()
    if #self.rows == 0 then
        return
    end
    self:act(self.rows[self.settingsList:getSelectedIndexInSection()])
end

function ADRoadTypesGui:onClickValidate()
    ADRoadTypes.set(self.kind, self.draft)
    self:close()
end
