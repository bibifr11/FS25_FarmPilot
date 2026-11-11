-- ============================================================================================================
-- FarmPilot : TrailerSwapGUI.lua
-- Fenêtre « Échange de bennes » (roue dentée de la ligne « Remorque », modes Chargement / Livraison et
-- Décharger la moissonneuse).
--
-- (09/11) même forme que la fenêtre de la remorque à balles : 1re ligne « Non (livraison normale) », puis les
-- dossiers de marqueurs avec leurs places, places libres et bennes vides. « Choisir » (ou double clic) enregistre
-- le dossier (TrailerSwapEvent.lua) et ferme. Le travail est fait par Modes/TrailerSwap.lua.
--
-- Branché par une ligne chacune : Gui.lua (ADTrailerSwapGui.load, gui/trailerSwapGUI.xml) et
-- TrailerSwap.lua (onGear : ADTrailerSwapGui.open).
-- ============================================================================================================

ADTrailerSwapGui = {}
ADTrailerSwapGui.context = nil -- { vehicle }

local ADTrailerSwapGui_mt = Class(ADTrailerSwapGui, DialogElement)

-- ------------------------------------------------------------------------------------------------------------
-- Chargement et ouverture
-- ------------------------------------------------------------------------------------------------------------
function ADTrailerSwapGui.load()
    AutoDrive.gui.ADTrailerSwapGui = ADTrailerSwapGui.new()
    local result = g_gui:loadGui(AutoDrive.directory .. "gui/trailerSwapGUI.xml", "ADTrailerSwapGui", AutoDrive.gui.ADTrailerSwapGui)
    if result == nil then
        AutoDrive.debugMsg(nil, "AutoDrive:loadGUI failed trailerSwapGUI")
    end
end

function ADTrailerSwapGui.open(vehicle)
    local gui = AutoDrive.gui ~= nil and AutoDrive.gui.ADTrailerSwapGui or nil
    if gui ~= nil and not gui.isOpen then
        ADTrailerSwapGui.context = { vehicle = vehicle }
        g_gui:showDialog("ADTrailerSwapGui")
    end
end

function ADTrailerSwapGui.new(target)
    local self = DialogElement.new(target, ADTrailerSwapGui_mt)
    self.rows = {}
    return self
end

function ADTrailerSwapGui:onOpen()
    ADTrailerSwapGui:superClass().onOpen(self)
    self.settingsList:setDataSource(self)
    self:refreshItems()
end

-- ------------------------------------------------------------------------------------------------------------
-- Lignes de la fenêtre
-- ------------------------------------------------------------------------------------------------------------
function ADTrailerSwapGui:getNumberOfItemsInSection(list, section)
    if list == self.settingsList then
        return #self.rows
    end
    return 0
end

function ADTrailerSwapGui:populateCellForItemInSection(list, section, index, cell)
    if list == self.settingsList then
        local row = self.rows[index]
        cell.attributes.listItemText:setText(row.text or "")
        cell.attributes.listItemValue:setText(row.value or "")
        cell.target = self
    end
end

function ADTrailerSwapGui:vehicle()
    local c = ADTrailerSwapGui.context
    return c ~= nil and c.vehicle or nil
end

function ADTrailerSwapGui:refreshItems()
    self.rows = {}
    local vehicle = self:vehicle()
    local current = vehicle ~= nil and ADTrailerSwap.folder(vehicle) or nil
    local currentText = g_i18n:getText("gui_ad_trailerSwap_current")
    self.rows[1] = { folder = "", text = g_i18n:getText("gui_ad_trailerSwap_off"), value = current == nil and currentText or "" }
    local folders = ADTrailerSwap.folders()
    for _, folder in ipairs(folders) do
        local value = ""
        if vehicle ~= nil then
            local ok, nPlaces, nFree, nEmpty = FarmPilotCall(ADTrailerSwap.folderInfo, vehicle, folder)
            if ok then
                value = string.format(g_i18n:getText("gui_ad_trailerSwap_folderValue"), nPlaces, nFree, nEmpty)
            end
        end
        if folder == current then
            value = currentText .. (value ~= "" and (" · " .. value) or "")
        end
        self.rows[#self.rows + 1] = { folder = folder, text = folder, value = value }
    end
    local info = string.format(g_i18n:getText("gui_ad_trailerSwap_info"), current or g_i18n:getText("gui_ad_trailerSwap_off"))
    if #folders == 0 then
        info = info .. "\n" .. g_i18n:getText("gui_ad_trailerSwap_noFolder")
    end
    self.infoText:setText(info)
    self.settingsList:reloadData()
    for i, r in ipairs(self.rows) do
        if r.folder == (current or "") then
            FarmPilotCall(self.settingsList.setSelectedIndex, self.settingsList, i)
            break
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Boutons
-- ------------------------------------------------------------------------------------------------------------
function ADTrailerSwapGui:act(row)
    local vehicle = self:vehicle()
    if row == nil or vehicle == nil then
        return
    end
    ADTrailerSwapEvent.send(vehicle, row.folder)
    self:close()
end

function ADTrailerSwapGui:onDoubleClick(list, section, index, cell)
    self:act(self.rows[index])
end

function ADTrailerSwapGui:onClickChoose()
    if #self.rows == 0 then
        return
    end
    self:act(self.rows[self.settingsList:getSelectedIndexInSection()])
end
