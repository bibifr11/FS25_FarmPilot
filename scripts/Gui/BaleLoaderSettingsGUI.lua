-- ============================================================================================================
-- FarmPilot : BaleLoaderSettingsGUI.lua
-- Fenêtre « Réglages de la remorque à balles » (mode Autonome, roue dentée de la ligne « Outil » ou « Outil
-- suivant »).
--
-- (09/11) même fenêtre que celles du semoir et de l'épandeur : balles à ramasser (toutes, enrubannées seulement,
-- non enrubannées seulement) et zone de dépôt (marqueurs de la carte : ceux près d'un point de vente qui prend les
-- balles d'abord, marqués « vente », puis tous les autres pour stocker). « Valider » enregistre ; tant que ce n'est
-- pas validé, le départ est refusé (voir BaleLoaderManager.lua).
--
-- Branché par une ligne chacune dans Gui.lua : ADBaleLoaderSettingsGui.load (création, gui/baleLoaderSettingsGUI.xml)
-- et ADBaleLoaderSettingsGui.open (roue dentée).
-- ============================================================================================================

ADBaleLoaderSettingsGui = {}
ADBaleLoaderSettingsGui.context = nil   -- { vehicle, isNext }

local ADBaleLoaderSettingsGui_mt = Class(ADBaleLoaderSettingsGui, DialogElement)

-- ------------------------------------------------------------------------------------------------------------
-- Chargement et ouverture (hooks Gui.lua)
-- ------------------------------------------------------------------------------------------------------------
function ADBaleLoaderSettingsGui.load()
    AutoDrive.gui.ADBaleLoaderSettingsGui = ADBaleLoaderSettingsGui.new()
    local result = g_gui:loadGui(AutoDrive.directory .. "gui/baleLoaderSettingsGUI.xml", "ADBaleLoaderSettingsGui", AutoDrive.gui.ADBaleLoaderSettingsGui)
    if result == nil then
        AutoDrive.debugMsg(nil, "AutoDrive:loadGUI failed baleLoaderSettingsGUI")
    end
end

-- true si la ligne a une remorque à balles (fenêtre ouverte) ; false = fenêtre du semoir ou de l'épandeur comme avant
function ADBaleLoaderSettingsGui.open(vehicle, isNext)
    local okC, ctx = pcall(ADBaleLoaderManager.context, vehicle, isNext == true)
    if not okC or ctx == nil then
        return false
    end
    local gui = AutoDrive.gui ~= nil and AutoDrive.gui.ADBaleLoaderSettingsGui or nil
    if gui ~= nil and not gui.isOpen then
        ADBaleLoaderSettingsGui.context = { vehicle = vehicle, isNext = isNext == true }
        g_gui:showDialog("ADBaleLoaderSettingsGui")
    end
    return true
end

function ADBaleLoaderSettingsGui.new(target)
    local self = DialogElement.new(target, ADBaleLoaderSettingsGui_mt)
    self.rows = {}
    self.mode = "settings"
    return self
end

function ADBaleLoaderSettingsGui:onOpen()
    ADBaleLoaderSettingsGui:superClass().onOpen(self)
    self.settingsList:setDataSource(self)
    self.mode = "settings"
    self.message = nil
    self:loadContext()
    self:refreshItems()
end

-- ------------------------------------------------------------------------------------------------------------
-- Brouillon : les réglages affichés à l'ouverture
-- ------------------------------------------------------------------------------------------------------------
-- brouillon = réglages enregistrés, sinon ceux de la même machine sur un autre champ, sinon : toutes les balles,
-- zone à choisir
function ADBaleLoaderSettingsGui:loadContext()
    self.ctx = nil
    self.draft = nil
    local c = ADBaleLoaderSettingsGui.context
    if c == nil or c.vehicle == nil then
        return
    end
    local ctx = ADBaleLoaderManager.context(c.vehicle, c.isNext == true)
    if ctx == nil then
        return
    end
    self.ctx = ctx
    local saved = ADBaleLoaderManager:get(ctx.field, ctx.toolKey)
    self.saved = saved
    local base = saved or ADBaleLoaderManager:lastFor(ctx.toolKey)
    local draft = { wrap = ADBaleLoaderManager.WRAP_ALL, deposit = nil }
    if base ~= nil then
        draft.wrap = ADBaleLoaderManager.validWrap(base.wrap)
        draft.deposit = base.deposit
        if draft.deposit ~= nil and ADGraphManager:getMapMarkerByName(draft.deposit) == nil then
            draft.deposit = nil
        end
    end
    self.draft = draft
end

-- ------------------------------------------------------------------------------------------------------------
-- Lignes de la fenêtre
-- ------------------------------------------------------------------------------------------------------------
function ADBaleLoaderSettingsGui:getNumberOfItemsInSection(list, section)
    if list == self.settingsList then
        return #self.rows
    end
    return 0
end

function ADBaleLoaderSettingsGui:populateCellForItemInSection(list, section, index, cell)
    if list == self.settingsList then
        local row = self.rows[index]
        cell.attributes.listItemText:setText(row.text or "")
        cell.attributes.listItemValue:setText(row.value or "")
        cell.target = self
    end
end

local WRAP_TEXT = {
    all = "gui_ad_baleLoader_wrapAll",
    wrapped = "gui_ad_baleLoader_wrapWrapped",
    unwrapped = "gui_ad_baleLoader_wrapUnwrapped"
}

local KIND_TEXT = {
    round = "gui_ad_baleLoader_round",
    square = "gui_ad_baleLoader_square",
    both = "gui_ad_baleLoader_both"
}

-- marqueurs de dépôt : près d'un point de vente des balles d'abord (« vente »), puis tous les autres
function ADBaleLoaderSettingsGui:depositRows()
    local okS, sale = pcall(ADBaleLoaderManager.saleMarkers, self.ctx.tool)
    sale = okS and sale or {}
    local markers = {}
    for _, m in pairs(ADGraphManager:getMapMarkers()) do
        if m ~= nil and m.name ~= nil then
            markers[#markers + 1] = m
        end
    end
    table.sort(markers, function(a, b)
        local sa, sb = sale[a.name] ~= nil, sale[b.name] ~= nil
        if sa ~= sb then
            return sa
        end
        return string.lower(tostring(a.name)) < string.lower(tostring(b.name))
    end)
    local rows, nSale = {}, 0
    for _, m in ipairs(markers) do
        local value
        if sale[m.name] ~= nil then
            nSale = nSale + 1
            value = g_i18n:getText("gui_ad_baleLoader_sale") .. (sale[m.name] ~= "" and (" · " .. sale[m.name]) or "")
        else
            value = (m.group ~= nil and m.group ~= "All") and m.group or ""
        end
        if m.name == self.draft.deposit then
            value = g_i18n:getText("gui_ad_seeder_current") .. (value ~= "" and (" · " .. value) or "")
        end
        rows[#rows + 1] = { kind = "marker", name = m.name, text = m.name, value = value }
    end
    return rows, nSale
end

function ADBaleLoaderSettingsGui:refreshItems()
    self.rows = {}
    local info
    if self.ctx == nil or self.draft == nil then
        info = g_i18n:getText("gui_ad_baleLoader_noLoader")
    elseif self.mode == "markers" then
        local rows, nSale = self:depositRows()
        self.rows = rows
        info = g_i18n:getText(nSale > 0 and "gui_ad_baleLoader_pickDeposit" or "gui_ad_baleLoader_pickDepositNoSale")
    else
        local okL, label = pcall(ADAutonomousManager.toolShortLabel, self.ctx.tool)
        local okK, kind = pcall(ADBaleLoaderManager.baleKinds, self.ctx.tool)
        local kindText = okK and KIND_TEXT[kind or ""] ~= nil and g_i18n:getText(KIND_TEXT[kind]) or "?"
        info = string.format(g_i18n:getText("gui_ad_baleLoader_head"), okL and label or ADAutonomousManager.toolLabel(self.ctx.tool), tostring(self.ctx.field), kindText)
        local d = self.draft
        self.rows[#self.rows + 1] = {
            kind = "wrap", text = g_i18n:getText("gui_ad_baleLoader_wrap"), value = g_i18n:getText(WRAP_TEXT[d.wrap] or WRAP_TEXT.all)
        }
        self.rows[#self.rows + 1] = {
            kind = "deposit", text = g_i18n:getText("gui_ad_baleLoader_deposit"),
            value = (d.deposit or g_i18n:getText("gui_ad_seeder_refillNone")) .. "  >"
        }
        local status
        if self.message ~= nil then
            status = self.message
        elseif self.saved ~= nil and ADBaleLoaderManager.isValid(self.saved) and self:draftEqualsSaved() then
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
    local current = self.draft ~= nil and self.mode == "markers" and self.draft.deposit or nil
    if current ~= nil then
        for i, r in ipairs(self.rows) do
            if r.name == current then
                pcall(self.settingsList.setSelectedIndex, self.settingsList, i)
                if self.settingsList.makeCellVisible ~= nil then
                    pcall(self.settingsList.makeCellVisible, self.settingsList, 1, i)
                end
                break
            end
        end
    end
end

function ADBaleLoaderSettingsGui:draftEqualsSaved()
    local a, b = self.draft, self.saved
    return a ~= nil and b ~= nil and a.deposit == b.deposit and ADBaleLoaderManager.validWrap(a.wrap) == ADBaleLoaderManager.validWrap(b.wrap)
end

-- ------------------------------------------------------------------------------------------------------------
-- Boutons
-- ------------------------------------------------------------------------------------------------------------
function ADBaleLoaderSettingsGui:selectedRow()
    if #self.rows == 0 then
        return nil
    end
    return self.rows[self.settingsList:getSelectedIndexInSection()]
end

function ADBaleLoaderSettingsGui:act(row)
    if row == nil or self.draft == nil then
        return
    end
    self.message = nil
    local d = self.draft
    if row.kind == "wrap" then
        -- toutes -> enrubannées -> non enrubannées -> toutes
        local order = ADBaleLoaderManager.WRAP_ORDER
        local i = 1
        for k, w in ipairs(order) do
            if w == d.wrap then
                i = k
            end
        end
        d.wrap = order[i % #order + 1]
    elseif row.kind == "deposit" then
        self.mode = "markers"
        self:refreshItems()
        return
    elseif row.kind == "marker" then
        d.deposit = row.name
        self.mode = "settings"
        self:refreshItems()
        pcall(self.settingsList.setSelectedIndex, self.settingsList, #self.rows)
        return
    end
    local index = self.settingsList:getSelectedIndexInSection()
    self:refreshItems()
    pcall(self.settingsList.setSelectedIndex, self.settingsList, index)
end

function ADBaleLoaderSettingsGui:onDoubleClick(list, section, index, cell)
    self:act(self.rows[index])
end

function ADBaleLoaderSettingsGui:onClickChange()
    self:act(self:selectedRow())
end

function ADBaleLoaderSettingsGui:onClickValidate()
    if self.mode ~= "settings" or self.ctx == nil or self.draft == nil then
        return
    end
    if ADBaleLoaderManager.missing(self.draft) ~= nil then
        self.message = g_i18n:getText("gui_ad_baleLoader_needDeposit")
        self:refreshItems()
        return
    end
    ADBaleLoaderManager:set(self.ctx.field, self.ctx.tool, self.draft)
    self.saved = ADBaleLoaderManager:get(self.ctx.field, self.ctx.toolKey)
    self:close()
end

function ADBaleLoaderSettingsGui:onClickBack(forceBack, usedMenuButton)
    if self.mode ~= "settings" then
        self.mode = "settings"
        self:refreshItems()
        return false
    end
    return ADBaleLoaderSettingsGui:superClass().onClickBack(self, forceBack, usedMenuButton)
end
