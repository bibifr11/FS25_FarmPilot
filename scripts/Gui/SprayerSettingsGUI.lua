-------------------------------------------------------------------------------
-- FarmPilot : fenêtre « Réglages de l'épandeur » (mode Autonome, roue dentée de la ligne « Outil » ou « Outil suivant »)
--   Même fenêtre que celle du semoir (SeederSettingsGUI), pour les épandeurs et pulvés, traînés ou automoteurs :
--   produit à charger (liste de ce que la cuve accepte), quantité (« Plein » ou « Juste ce qu'il faut pour le
--   champ », avec l'estimation en litres) et zone de ravitaillement (marqueurs de la carte). « Valider » enregistre ;
--   tant que ce n'est pas validé, le départ est refusé (voir SprayerManager.lua).
--
-- Demande de Fabien (08/11, 14:05) : « Choisir le produit et la quantité à prendre »
-- Demande de Fabien (08/11, 20:39) : « L'automoteur comme le pulvé, ils doivent être fonctionnels sur Autonome »
--
-- Règle : même roue dentée et même façon de faire que le semoir ; la roue ouvre cette fenêtre quand la ligne a un
--   épandeur et pas de semoir (AutoDrive.onOpenSeederSettings -> ADSprayerSettingsGui.open).
-------------------------------------------------------------------------------
ADSprayerSettingsGui = {}
ADSprayerSettingsGui.context = nil   -- { vehicle, isNext }

local ADSprayerSettingsGui_mt = Class(ADSprayerSettingsGui, DialogElement)

-- ------------------------------------------------------------
-- Chargement et ouverture (hooks Gui.lua)
-- ------------------------------------------------------------
function ADSprayerSettingsGui.load()
    AutoDrive.gui.ADSprayerSettingsGui = ADSprayerSettingsGui.new()
    local result = g_gui:loadGui(AutoDrive.directory .. "gui/sprayerSettingsGUI.xml", "ADSprayerSettingsGui", AutoDrive.gui.ADSprayerSettingsGui)
    if result == nil then
        AutoDrive.debugMsg(nil, "AutoDrive:loadGUI failed sprayerSettingsGUI")
    end
end

-- true si c'est un épandeur (fenêtre ouverte) ; false = la ligne a un semoir ou rien (fenêtre du semoir comme avant)
function ADSprayerSettingsGui.open(vehicle, isNext)
    local okS, seeder = pcall(ADSeederManager.context, vehicle, isNext == true)
    if okS and seeder ~= nil then
        return false
    end
    local okC, ctx = pcall(ADSprayerManager.context, vehicle, isNext == true)
    if not okC or ctx == nil then
        return false
    end
    local gui = AutoDrive.gui ~= nil and AutoDrive.gui.ADSprayerSettingsGui or nil
    if gui ~= nil and not gui.isOpen then
        ADSprayerSettingsGui.context = { vehicle = vehicle, isNext = isNext == true }
        g_gui:showDialog("ADSprayerSettingsGui")
    end
    return true
end

function ADSprayerSettingsGui.new(target)
    local self = DialogElement.new(target, ADSprayerSettingsGui_mt)
    self.rows = {}
    self.mode = "settings"
    return self
end

function ADSprayerSettingsGui:onOpen()
    ADSprayerSettingsGui:superClass().onOpen(self)
    self.settingsList:setDataSource(self)
    self.mode = "settings"
    self.message = nil
    self:loadContext()
    self:refreshItems()
end

-- brouillon = réglages enregistrés, sinon ceux de la même machine sur un autre champ, sinon : produit dans la cuve
-- (ou le seul possible), plein, zone à choisir
function ADSprayerSettingsGui:loadContext()
    self.ctx = nil
    self.draft = nil
    local c = ADSprayerSettingsGui.context
    if c == nil or c.vehicle == nil then
        return
    end
    local ctx = ADSprayerManager.context(c.vehicle, c.isNext == true)
    if ctx == nil then
        return
    end
    self.ctx = ctx
    self.products = ADSprayerManager.productChoices(ctx.tool)
    local saved = ADSprayerManager:get(ctx.field, ctx.toolKey)
    self.saved = saved
    local base = saved or ADSprayerManager:lastFor(ctx.toolKey)
    local draft = { fillType = nil, quantity = ADSprayerManager.QUANTITY_FULL, refill = nil }
    if base ~= nil then
        draft.fillType = base.fillType
        draft.quantity = base.quantity or ADSprayerManager.QUANTITY_FULL
        draft.refill = base.refill
        if draft.refill ~= nil and ADGraphManager:getMapMarkerByName(draft.refill) == nil then
            draft.refill = nil
        end
    end
    local known = false
    for _, p in ipairs(self.products) do
        if p.name == draft.fillType then
            known = true
        end
    end
    if not known then
        draft.fillType = nil
        local _, inTank = ADSprayerManager.content(ctx.tool)
        if inTank ~= nil then
            draft.fillType = g_fillTypeManager:getFillTypeNameByIndex(inTank)
        elseif #self.products == 1 then
            draft.fillType = self.products[1].name
        end
    end
    self.draft = draft
end

function ADSprayerSettingsGui:getNumberOfItemsInSection(list, section)
    if list == self.settingsList then
        return #self.rows
    end
    return 0
end

function ADSprayerSettingsGui:populateCellForItemInSection(list, section, index, cell)
    if list == self.settingsList then
        local row = self.rows[index]
        cell.attributes.listItemText:setText(row.text or "")
        cell.attributes.listItemValue:setText(row.value or "")
        cell.target = self
    end
end

-- ------------------------------------------------------------
-- Lignes de la fenêtre
-- ------------------------------------------------------------
-- texte de la quantité « juste ce qu'il faut » : « ~1 230 L (150 L/ha, 7,4 ha) » ou « estimation impossible »
function ADSprayerSettingsGui:fieldQuantityText()
    local d = self.draft
    local ftIndex = d.fillType ~= nil and g_fillTypeManager:getFillTypeIndexByName(d.fillType) or nil
    if ftIndex == nil then
        return g_i18n:getText("gui_ad_sprayer_quantityField")
    end
    local okE, est = pcall(ADSprayerManager.estimate, self.ctx.vehicle, self.ctx.tool, ftIndex, self.ctx.marker, 1)
    if not okE or est == nil then
        return string.format("%s (%s)", g_i18n:getText("gui_ad_sprayer_quantityField"), g_i18n:getText("gui_ad_sprayer_noEstimate"))
    end
    local _, cap = ADSprayerManager.fillUnit(self.ctx.tool)
    local txt = string.format(g_i18n:getText("gui_ad_sprayer_estimate"), est.liters, est.lha, est.area)
    if cap ~= nil and est.liters >= cap then
        txt = txt .. " · " .. g_i18n:getText("gui_ad_sprayer_moreThanTank")
    end
    return string.format("%s (%s)", g_i18n:getText("gui_ad_sprayer_quantityField"), txt)
end

function ADSprayerSettingsGui:refreshItems()
    self.rows = {}
    local info
    if self.ctx == nil or self.draft == nil then
        info = g_i18n:getText("gui_ad_sprayer_noSprayer")
    elseif self.mode == "products" then
        info = g_i18n:getText("gui_ad_sprayer_pickProduct")
        for _, p in ipairs(self.products or {}) do
            self.rows[#self.rows + 1] = { kind = "productPick", name = p.name, text = p.title, value = p.name == self.draft.fillType and g_i18n:getText("gui_ad_seeder_current") or "" }
        end
    elseif self.mode == "markers" then
        info = g_i18n:getText("gui_ad_seeder_pickRefill")
        local allowed, filterInfo = nil, nil
        if ADRefillSources ~= nil then allowed, filterInfo = ADRefillSources.filter(self) if filterInfo ~= nil then info = info .. "\n" .. filterInfo end end -- (Fabien 21:24) zones où l'on trouve le produit, voir RefillSources.lua
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
        local okL, label = pcall(ADAutonomousManager.toolShortLabel, self.ctx.tool)
        info = string.format(g_i18n:getText("gui_ad_sprayer_head"), okL and label or ADAutonomousManager.toolLabel(self.ctx.tool), tostring(self.ctx.field))
        local d = self.draft
        -- produit
        local productValue = d.fillType ~= nil and ADSprayerManager.productTitle(d.fillType) or g_i18n:getText("gui_ad_seeder_refillNone")
        if #(self.products or {}) > 1 or d.fillType == nil then
            productValue = productValue .. "  >"
        end
        self.rows[#self.rows + 1] = { kind = "product", text = g_i18n:getText("gui_ad_sprayer_product"), value = productValue }
        -- quantité
        local quantityValue
        if d.quantity == ADSprayerManager.QUANTITY_FIELD then
            quantityValue = self:fieldQuantityText()
        else
            quantityValue = g_i18n:getText("gui_ad_sprayer_quantityFull")
        end
        self.rows[#self.rows + 1] = { kind = "quantity", text = g_i18n:getText("gui_ad_sprayer_quantity"), value = quantityValue }
        -- zone de ravitaillement
        self.rows[#self.rows + 1] = {
            kind = "refill", text = g_i18n:getText("gui_ad_seeder_refill"),
            value = (d.refill or g_i18n:getText("gui_ad_seeder_refillNone")) .. "  >"
        }
        local status
        if self.message ~= nil then
            status = self.message
        elseif self.saved ~= nil and ADSprayerManager.isValid(self.saved) and self:draftEqualsSaved() then
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
    local current = self.draft ~= nil and ((self.mode == "markers" and self.draft.refill) or (self.mode == "products" and self.draft.fillType)) or nil
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

function ADSprayerSettingsGui:draftEqualsSaved()
    local a, b = self.draft, self.saved
    return a ~= nil and b ~= nil and a.fillType == b.fillType and a.refill == b.refill and (a.quantity or "full") == (b.quantity or "full")
end

-- ------------------------------------------------------------
-- Boutons
-- ------------------------------------------------------------
function ADSprayerSettingsGui:selectedRow()
    if #self.rows == 0 then
        return nil
    end
    return self.rows[self.settingsList:getSelectedIndexInSection()]
end

function ADSprayerSettingsGui:act(row)
    if row == nil or self.draft == nil then
        return
    end
    self.message = nil
    local d = self.draft
    if row.kind == "product" then
        if #(self.products or {}) > 0 then
            self.mode = "products"
            self:refreshItems()
        end
        return
    elseif row.kind == "productPick" then
        d.fillType = row.name
        self.mode = "settings"
        self:refreshItems()
        pcall(self.settingsList.setSelectedIndex, self.settingsList, 1)
        return
    elseif row.kind == "quantity" then
        d.quantity = d.quantity == ADSprayerManager.QUANTITY_FIELD and ADSprayerManager.QUANTITY_FULL or ADSprayerManager.QUANTITY_FIELD
    elseif row.kind == "refill" then
        self.mode = "markers"
        self:refreshItems()
        return
    elseif row.kind == "marker" then
        d.refill = row.name
        self.mode = "settings"
        self:refreshItems()
        pcall(self.settingsList.setSelectedIndex, self.settingsList, #self.rows)
        return
    end
    local index = self.settingsList:getSelectedIndexInSection()
    self:refreshItems()
    pcall(self.settingsList.setSelectedIndex, self.settingsList, index)
end

function ADSprayerSettingsGui:onDoubleClick(list, section, index, cell)
    self:act(self.rows[index])
end

function ADSprayerSettingsGui:onClickChange()
    self:act(self:selectedRow())
end

function ADSprayerSettingsGui:onClickValidate()
    if self.mode ~= "settings" or self.ctx == nil or self.draft == nil then
        return
    end
    local missing = ADSprayerManager.missing(self.draft)
    if missing == "product" or missing == "none" then
        self.message = g_i18n:getText("gui_ad_sprayer_needProduct")
        self:refreshItems()
        return
    elseif missing == "refill" then
        self.message = g_i18n:getText("gui_ad_seeder_needRefill")
        self:refreshItems()
        return
    end
    ADSprayerManager:set(self.ctx.field, self.ctx.tool, self.draft)
    self.saved = ADSprayerManager:get(self.ctx.field, self.ctx.toolKey)
    self:close()
end

function ADSprayerSettingsGui:onClickBack(forceBack, usedMenuButton)
    if self.mode ~= "settings" then
        self.mode = "settings"
        self:refreshItems()
        return false
    end
    return ADSprayerSettingsGui:superClass().onClickBack(self, forceBack, usedMenuButton)
end
