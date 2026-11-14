-- ============================================================================================================
-- FarmPilot : HeaderTractorGUI.lua
-- Fenêtre « Transport de la barre » (roue dentée de la ligne « Outil » d'une moissonneuse en Autonome).
--
-- (11/11) même forme que la fenêtre « Échange de bennes » : 1re ligne « Tracteur libre le plus proche », puis les
-- véhicules FarmPilot de la ferme qui ont un attelage arrière (pas les moissonneuses ni les autres automoteurs), le
-- plus proche d'abord, avec ce qui y est attelé (une masse ne compte pas : « libre »).
-- « Choisir » (ou double clic) enregistre le choix (HeaderTractorEvent.lua) et ferme. Le travail est fait par
-- Modes/AutonomousHeader.lua.
--
-- Branché par une ligne chacune : Gui.lua (ADHeaderTractorGui.load, gui/headerTractorGUI.xml) et
-- AutonomousHeader.lua (onGear : ADHeaderTractorGui.open).
-- ============================================================================================================

ADHeaderTractorGui = {}
ADHeaderTractorGui.context = nil -- { vehicle }

local ADHeaderTractorGui_mt = Class(ADHeaderTractorGui, DialogElement)

-- ------------------------------------------------------------------------------------------------------------
-- Chargement et ouverture
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderTractorGui.load()
    AutoDrive.gui.ADHeaderTractorGui = ADHeaderTractorGui.new()
    local result = g_gui:loadGui(AutoDrive.directory .. "gui/headerTractorGUI.xml", "ADHeaderTractorGui", AutoDrive.gui.ADHeaderTractorGui)
    if result == nil then
        AutoDrive.debugMsg(nil, "AutoDrive:loadGUI failed headerTractorGUI")
    end
end

function ADHeaderTractorGui.open(vehicle)
    local gui = AutoDrive.gui ~= nil and AutoDrive.gui.ADHeaderTractorGui or nil
    if gui ~= nil and not gui.isOpen then
        ADHeaderTractorGui.context = { vehicle = vehicle }
        g_gui:showDialog("ADHeaderTractorGui")
    end
end

function ADHeaderTractorGui.new(target)
    local self = DialogElement.new(target, ADHeaderTractorGui_mt)
    self.rows = {}
    return self
end

function ADHeaderTractorGui:onOpen()
    ADHeaderTractorGui:superClass().onOpen(self)
    self.settingsList:setDataSource(self)
    self:refreshItems()
end

-- ------------------------------------------------------------------------------------------------------------
-- Lignes de la fenêtre
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderTractorGui:getNumberOfItemsInSection(list, section)
    if list == self.settingsList then
        return #self.rows
    end
    return 0
end

function ADHeaderTractorGui:populateCellForItemInSection(list, section, index, cell)
    if list == self.settingsList then
        local row = self.rows[index]
        cell.attributes.listItemText:setText(row.text or "")
        cell.attributes.listItemValue:setText(row.value or "")
        cell.target = self
    end
end

function ADHeaderTractorGui:vehicle()
    local c = ADHeaderTractorGui.context
    return c ~= nil and c.vehicle or nil
end

function ADHeaderTractorGui:refreshItems()
    self.rows = {}
    local vehicle = self:vehicle()
    local current = vehicle ~= nil and vehicle.ad.stateModule:getFpHeaderTractor() or nil
    local currentText = g_i18n:getText("gui_ad_trailerSwap_current")
    self.rows[1] = { tractor = nil, text = g_i18n:getText("gui_ad_headerTractor_auto"), value = current == nil and currentText or "" }
    local ok, list = FarmPilotCall(ADHeaderFlow.choosableVehicles, vehicle)
    if ok and type(list) == "table" then
        for _, e in ipairs(list) do
            local value = e.info
            if e.vehicle == current then
                value = currentText .. (value ~= "" and (" · " .. value) or "")
            end
            self.rows[#self.rows + 1] = { tractor = e.vehicle, text = e.name, value = value }
        end
    end
    local name = current ~= nil and ADHeaderFlow.vehicleName(current) or g_i18n:getText("gui_ad_headerTractor_auto")
    self.infoText:setText(string.format(g_i18n:getText("gui_ad_headerTractor_info"), name))
    self.settingsList:reloadData()
    for i, r in ipairs(self.rows) do
        if r.tractor == current then
            FarmPilotCall(self.settingsList.setSelectedIndex, self.settingsList, i)
            break
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Boutons
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderTractorGui:act(row)
    local vehicle = self:vehicle()
    if row == nil or vehicle == nil then
        return
    end
    ADHeaderTractorEvent.send(vehicle, row.tractor)
    self:close()
end

function ADHeaderTractorGui:onDoubleClick(list, section, index, cell)
    self:act(self.rows[index])
end

function ADHeaderTractorGui:onClickChoose()
    if #self.rows == 0 then
        return
    end
    self:act(self.rows[self.settingsList:getSelectedIndexInSection()])
end
