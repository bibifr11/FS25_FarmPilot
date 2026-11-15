-- ============================================================================================================
-- FarmPilot : BalerSettingsGUI.lua
-- Fenêtre « Réglages de la presse » (mode Autonome, roue dentée de la ligne « Outil » ou « Outil suivant »).
--
-- (15/11) même fenêtre que celles du semoir et de l'épandeur, avec un seul choix : « Zone de recharge (ficelle /
-- filet) » (marqueurs de la carte, ceux près d'une palette de la ficelle ou du filet de la presse : RefillSources.lua ;
-- aucun trouvé : tous). L'info en haut donne la presse, le champ et la ficelle / le filet sur la presse.
--
-- Règle : même roue dentée et même façon de faire que le semoir ; « Valider » enregistre (par champ et par presse) ;
-- tant que ce n'est pas validé, le départ est refusé (voir BalerManager.lua). La roue ouvre cette fenêtre quand la
-- ligne a une presse à ficelle / filet (AutoDrive.onOpenSeederSettings -> ADBalerSettingsGui.open).
--
-- Branché par une ligne chacune dans Gui.lua : ADBalerSettingsGui.load (création, gui/balerSettingsGUI.xml) et
-- ADBalerSettingsGui.open (roue dentée).
-- ============================================================================================================

ADBalerSettingsGui = {}
ADBalerSettingsGui.context = nil   -- { vehicle, isNext }

local ADBalerSettingsGui_mt = Class(ADBalerSettingsGui, DialogElement)

-- ------------------------------------------------------------------------------------------------------------
-- Chargement et ouverture (hooks Gui.lua)
-- ------------------------------------------------------------------------------------------------------------
function ADBalerSettingsGui.load()
    AutoDrive.gui.ADBalerSettingsGui = ADBalerSettingsGui.new()
    local result = g_gui:loadGui(AutoDrive.directory .. "gui/balerSettingsGUI.xml", "ADBalerSettingsGui", AutoDrive.gui.ADBalerSettingsGui)
    if result == nil then
        AutoDrive.debugMsg(nil, "AutoDrive:loadGUI failed balerSettingsGUI")
    end
end

-- true si la ligne a une presse à ficelle / filet (fenêtre ouverte) ; false = fenêtre d'un autre outil comme avant
function ADBalerSettingsGui.open(vehicle, isNext)
    local okC, ctx = FarmPilotCall(ADBalerManager.context, vehicle, isNext == true)
    if not okC or ctx == nil then
        return false
    end
    local gui = AutoDrive.gui ~= nil and AutoDrive.gui.ADBalerSettingsGui or nil
    if gui ~= nil and not gui.isOpen then
        ADBalerSettingsGui.context = { vehicle = vehicle, isNext = isNext == true }
        g_gui:showDialog("ADBalerSettingsGui")
    end
    return true
end

function ADBalerSettingsGui.new(target)
    local self = DialogElement.new(target, ADBalerSettingsGui_mt)
    self.rows = {}
    self.mode = "settings"
    return self
end

function ADBalerSettingsGui:onOpen()
    ADBalerSettingsGui:superClass().onOpen(self)
    self.settingsList:setDataSource(self)
    self.mode = "settings"
    self.message = nil
    self:loadContext()
    self:refreshItems()
end

-- ------------------------------------------------------------------------------------------------------------
-- Brouillon : les réglages affichés à l'ouverture
-- ------------------------------------------------------------------------------------------------------------
-- brouillon = réglages enregistrés, sinon ceux de la même presse sur un autre champ, sinon zone à choisir ;
-- fillType = produit de la ficelle / du filet de la presse (pour la liste des zones, RefillSources.lua)
function ADBalerSettingsGui:loadContext()
    self.ctx = nil
    self.draft = nil
    self.info = nil
    local c = ADBalerSettingsGui.context
    if c == nil or c.vehicle == nil then
        return
    end
    local ctx = ADBalerManager.context(c.vehicle, c.isNext == true)
    if ctx == nil then
        return
    end
    self.ctx = ctx
    self.info = ADBalerManager.consumable(ctx.tool)
    local saved = ADBalerManager:get(ctx.field, ctx.toolKey)
    self.saved = saved
    local base = saved or ADBalerManager:lastFor(ctx.toolKey)
    local draft = { refill = nil, fillType = nil }
    if base ~= nil and base.refill ~= nil and ADGraphManager:getMapMarkerByName(base.refill) ~= nil then
        draft.refill = base.refill
    end
    if self.info ~= nil and self.info.fillType ~= nil then
        draft.fillType = g_fillTypeManager:getFillTypeNameByIndex(self.info.fillType)
    end
    self.draft = draft
end

-- « filet » ou « ficelle » (nom du produit du jeu, sinon notre texte)
function ADBalerSettingsGui:consumableTitle()
    local info = self.info
    if info == nil then
        return g_i18n:getText("gui_ad_baler_twineOrNet")
    end
    local ft = info.fillType ~= nil and g_fillTypeManager:getFillTypeByIndex(info.fillType) or nil
    if ft ~= nil and ft.title ~= nil and ft.title ~= "" then
        return tostring(ft.title)
    end
    return g_i18n:getText(info.typeName == "BALE_NET" and "gui_ad_baler_net" or "gui_ad_baler_twine")
end

-- ------------------------------------------------------------------------------------------------------------
-- Lignes de la fenêtre
-- ------------------------------------------------------------------------------------------------------------
function ADBalerSettingsGui:getNumberOfItemsInSection(list, section)
    if list == self.settingsList then
        return #self.rows
    end
    return 0
end

function ADBalerSettingsGui:populateCellForItemInSection(list, section, index, cell)
    if list == self.settingsList then
        local row = self.rows[index]
        cell.attributes.listItemText:setText(row.text or "")
        cell.attributes.listItemValue:setText(row.value or "")
        cell.target = self
    end
end

function ADBalerSettingsGui:refreshItems()
    self.rows = {}
    local info
    if self.ctx == nil or self.draft == nil then
        info = g_i18n:getText("gui_ad_baler_noBaler")
    elseif self.mode == "markers" then
        info = g_i18n:getText("gui_ad_baler_pickRefill")
        local allowed, filterInfo = nil, nil
        if ADRefillSources ~= nil then allowed, filterInfo = ADRefillSources.filter(self) if filterInfo ~= nil then info = info .. "\n" .. filterInfo end end -- zones où l'on trouve la ficelle / le filet, voir RefillSources.lua
        local markers = {}
        for _, m in pairs(ADGraphManager:getMapMarkers()) do
            if m ~= nil and m.name ~= nil and (allowed == nil or allowed[m.name]) then
                markers[#markers + 1] = m
            end
        end
        table.sort(markers, function(a, b)
            return string.lower(tostring(a.name)) < string.lower(tostring(b.name))
        end)
        for _, m in ipairs(markers) do
            local value = (m.group ~= nil and m.group ~= "All") and m.group or ""
            if m.name == self.draft.refill then
                value = g_i18n:getText("gui_ad_seeder_current") .. (value ~= "" and (" · " .. value) or "")
            end
            self.rows[#self.rows + 1] = { kind = "marker", name = m.name, text = m.name, value = value }
        end
    else
        local okL, label = FarmPilotCall(ADAutonomousManager.toolShortLabel, self.ctx.tool)
        local level = "-"
        if self.info ~= nil then
            level = string.format("%.1f / %.0f", self.info.level, self.info.capacity)
        end
        info = string.format(g_i18n:getText("gui_ad_baler_head"), okL and label or ADAutonomousManager.toolLabel(self.ctx.tool), tostring(self.ctx.field),
            self:consumableTitle(), level)
        -- zone de recharge (le seul choix)
        self.rows[#self.rows + 1] = {
            kind = "refill", text = g_i18n:getText("gui_ad_baler_refill"),
            value = (self.draft.refill or g_i18n:getText("gui_ad_seeder_refillNone")) .. "  >"
        }
        local status
        if self.message ~= nil then
            status = self.message
        elseif self.saved ~= nil and ADBalerManager.isValid(self.saved) and self.draft.refill == self.saved.refill then
            status = g_i18n:getText("gui_ad_seeder_statusOk")
        else
            status = g_i18n:getText("gui_ad_seeder_statusTodo")
        end
        info = info .. "\n" .. status
    end
    self.infoText:setText(info or "")
    if self.changeButton ~= nil then
        self.changeButton:setText(g_i18n:getText(self.mode ~= "settings" and "gui_ad_seeder_choose" or "gui_ad_autonomous_change"))
    end
    if self.validateButton ~= nil then
        self.validateButton:setDisabled(self.mode ~= "settings" or self.ctx == nil)
    end
    self.settingsList:reloadData()
    local current = (self.draft ~= nil and self.mode == "markers") and self.draft.refill or nil
    if current ~= nil then
        for i, r in ipairs(self.rows) do
            if r.name == current then
                FarmPilotCall(self.settingsList.setSelectedIndex, self.settingsList, i)
                if self.settingsList.makeCellVisible ~= nil then
                    FarmPilotCall(self.settingsList.makeCellVisible, self.settingsList, 1, i)
                end
                break
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Boutons
-- ------------------------------------------------------------------------------------------------------------
function ADBalerSettingsGui:selectedRow()
    if #self.rows == 0 then
        return nil
    end
    return self.rows[self.settingsList:getSelectedIndexInSection()]
end

function ADBalerSettingsGui:act(row)
    if row == nil or self.draft == nil then
        return
    end
    self.message = nil
    if row.kind == "refill" then
        self.mode = "markers"
        self:refreshItems()
    elseif row.kind == "marker" then
        self.draft.refill = row.name
        self.mode = "settings"
        self:refreshItems()
        FarmPilotCall(self.settingsList.setSelectedIndex, self.settingsList, 1)
    end
end

function ADBalerSettingsGui:onDoubleClick(list, section, index, cell)
    self:act(self.rows[index])
end

function ADBalerSettingsGui:onClickChange()
    self:act(self:selectedRow())
end

function ADBalerSettingsGui:onClickValidate()
    if self.mode ~= "settings" or self.ctx == nil or self.draft == nil then
        return
    end
    if ADBalerManager.missing(self.draft) ~= nil then
        self.message = g_i18n:getText("gui_ad_baler_needRefill")
        self:refreshItems()
        return
    end
    ADBalerManager:set(self.ctx.field, self.ctx.tool, self.draft)
    self.saved = ADBalerManager:get(self.ctx.field, self.ctx.toolKey)
    self:close()
end

function ADBalerSettingsGui:onClickBack(forceBack, usedMenuButton)
    if self.mode ~= "settings" then
        self.mode = "settings"
        self:refreshItems()
        return false
    end
    return ADBalerSettingsGui:superClass().onClickBack(self, forceBack, usedMenuButton)
end
