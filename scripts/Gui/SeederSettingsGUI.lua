-- FarmPilot : fenêtre « Réglages du semoir » (mode Autonome, roue dentée de la ligne « Outil » ou « Outil suivant »)
-- Pour le semoir et le champ de la ligne : culture à semer, produits à charger (choix multiple, comme le mode
-- Chargement) et zone de ravitaillement. « Valider » enregistre ; tant que ce n'est pas validé, le départ est refusé.
-- « Changer » (ou double clic) sur une ligne : culture suivante, produit chargé oui/non, ou liste des marqueurs.
ADSeederSettingsGui = {}
ADSeederSettingsGui.debug = false
ADSeederSettingsGui.context = nil   -- { vehicle, isNext } donné par AutoDrive.onOpenSeederSettings

local ADSeederSettingsGui_mt = Class(ADSeederSettingsGui, DialogElement)

function ADSeederSettingsGui.new(target)
    local self = DialogElement.new(target, ADSeederSettingsGui_mt)
    self:include(ADGuiDebugMixin)
    self.rows = {}
    self.mode = "settings"
    return self
end

function ADSeederSettingsGui:onOpen()
    ADSeederSettingsGui:superClass().onOpen(self)
    self.settingsList:setDataSource(self)
    self.mode = "settings"
    self.message = nil
    self:loadContext()
    self:refreshItems()
end

-- semoir et champ de la ligne cliquée ; brouillon = réglages enregistrés, sinon ceux du même semoir sur un autre
-- champ, sinon : culture actuelle du semoir, tous les produits, zone à choisir
function ADSeederSettingsGui:loadContext()
    self.ctx = nil
    self.draft = nil
    local c = ADSeederSettingsGui.context
    if c == nil or c.vehicle == nil then
        return
    end
    local ctx = ADSeederManager.context(c.vehicle, c.isNext == true)
    if ctx == nil then
        return
    end
    self.ctx = ctx
    self.fruits, self.fruitChangeable = ADSeederManager.fruitChoices(ctx.tool)
    self.loads = ADSeederManager.loadChoices(ctx.tool)
    local saved = ADSeederManager:get(ctx.field, ctx.toolKey)
    self.saved = saved
    local base = saved or ADSeederManager:lastFor(ctx.toolKey)
    local draft = { fruit = nil, fillTypes = {}, refill = nil }
    if base ~= nil then
        draft.fruit = base.fruit
        draft.fillTypes = { unpack(base.fillTypes or {}) }
        draft.refill = base.refill
        if draft.refill ~= nil and ADGraphManager:getMapMarkerByName(draft.refill) == nil then
            draft.refill = nil
        end
    else
        for _, e in ipairs(self.loads) do
            draft.fillTypes[#draft.fillTypes + 1] = e.name
        end
    end
    -- produits que ce semoir ne prend pas : retirés
    local kept = {}
    for _, name in ipairs(draft.fillTypes) do
        for _, e in ipairs(self.loads) do
            if e.name == name then
                kept[#kept + 1] = name
            end
        end
    end
    draft.fillTypes = kept
    -- culture : celle enregistrée si le semoir la connaît, sinon celle réglée sur le semoir
    local known = false
    for _, f in ipairs(self.fruits) do
        if f.name == draft.fruit then
            known = true
        end
    end
    if not known then
        draft.fruit = ADSeederManager.currentFruit(ctx.tool)
        -- culture du semoir hors saison : la première de saison à la place
        for _, f in ipairs(self.fruits) do
            if f.name == draft.fruit and not f.inSeason and self.fruitChangeable then
                for _, g in ipairs(self.fruits) do
                    if g.inSeason then
                        draft.fruit = g.name
                        break
                    end
                end
                break
            end
        end
    end
    self.draft = draft
end

function ADSeederSettingsGui:getNumberOfItemsInSection(list, section)
    if list == self.settingsList then
        return #self.rows
    end
    return 0
end

function ADSeederSettingsGui:populateCellForItemInSection(list, section, index, cell)
    if list == self.settingsList then
        local row = self.rows[index]
        cell.attributes.listItemText:setText(row.text or "")
        cell.attributes.listItemValue:setText(row.value or "")
        cell.target = self
    end
end

local function fruitTitle(self, name)
    for _, f in ipairs(self.fruits or {}) do
        if f.name == name then
            return f.title
        end
    end
    return name or "-"
end

local function hasFill(draft, name)
    for _, n in ipairs(draft.fillTypes) do
        if n == name then
            return true
        end
    end
    return false
end

function ADSeederSettingsGui:refreshItems()
    self.rows = {}
    local info
    if self.ctx == nil or self.draft == nil then
        info = g_i18n:getText("gui_ad_seeder_noSeeder")
    elseif self.mode == "fruits" then
        -- (08/11, Fabien) liste déroulante : cultures semables en cette saison seulement
        info = g_i18n:getText("gui_ad_seeder_pickFruit")
        for _, f in ipairs(self.fruits or {}) do
            if f.inSeason then
                self.rows[#self.rows + 1] = { kind = "fruitPick", name = f.name, text = f.title, value = f.name == self.draft.fruit and g_i18n:getText("gui_ad_seeder_current") or "" }
            end
        end
        if #self.rows == 0 then
            info = g_i18n:getText("gui_ad_seeder_noFruitInSeason")
        end
    elseif self.mode == "markers" then
        info = g_i18n:getText("gui_ad_seeder_pickRefill")
        local markers = {}
        for _, m in pairs(ADGraphManager:getMapMarkers()) do
            if m ~= nil and m.name ~= nil then
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
        info = string.format(g_i18n:getText("gui_ad_seeder_head"), okL and label or ADAutonomousManager.toolLabel(self.ctx.tool), tostring(self.ctx.field))
        local d = self.draft
        -- culture
        local fruitValue = fruitTitle(self, d.fruit)
        for _, f in ipairs(self.fruits or {}) do
            if f.name == d.fruit and not f.inSeason then
                fruitValue = string.format(g_i18n:getText("gui_ad_seeder_outOfSeason"), fruitValue)
            end
        end
        if not self.fruitChangeable then
            fruitValue = string.format(g_i18n:getText("gui_ad_seeder_fixed"), fruitValue)
        else
            fruitValue = fruitValue .. "  >"
        end
        self.rows[#self.rows + 1] = { kind = "fruit", text = g_i18n:getText("gui_ad_seeder_fruit"), value = fruitValue }
        -- produits à charger (choix multiple)
        for _, e in ipairs(self.loads or {}) do
            self.rows[#self.rows + 1] = {
                kind = "fill", name = e.name, text = string.format(g_i18n:getText("gui_ad_seeder_load"), tostring(e.title)),
                value = g_i18n:getText(hasFill(d, e.name) and "gui_ad_seeder_yes" or "gui_ad_seeder_no")
            }
        end
        -- zone de ravitaillement
        self.rows[#self.rows + 1] = {
            kind = "refill", text = g_i18n:getText("gui_ad_seeder_refill"),
            value = (d.refill or g_i18n:getText("gui_ad_seeder_refillNone")) .. "  >"
        }
        local status
        if self.message ~= nil then
            status = self.message
        elseif self.saved ~= nil and ADSeederManager.isValid(self.saved) and self:draftEqualsSaved() then
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
    local current = self.draft ~= nil and ((self.mode == "markers" and self.draft.refill) or (self.mode == "fruits" and self.draft.fruit)) or nil
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

function ADSeederSettingsGui:draftEqualsSaved()
    local a, b = self.draft, self.saved
    if a == nil or b == nil or a.fruit ~= b.fruit or a.refill ~= b.refill or #a.fillTypes ~= #(b.fillTypes or {}) then
        return false
    end
    for _, n in ipairs(a.fillTypes) do
        if not hasFill(b, n) then
            return false
        end
    end
    return true
end

function ADSeederSettingsGui:selectedRow()
    if #self.rows == 0 then
        return nil
    end
    return self.rows[self.settingsList:getSelectedIndexInSection()]
end

function ADSeederSettingsGui:act(row)
    if row == nil or self.draft == nil then
        return
    end
    self.message = nil
    local d = self.draft
    if row.kind == "fruit" then
        if self.fruitChangeable and #self.fruits > 0 then
            self.mode = "fruits"
            self:refreshItems()
        end
        return
    elseif row.kind == "fruitPick" then
        d.fruit = row.name
        self.mode = "settings"
        self:refreshItems()
        pcall(self.settingsList.setSelectedIndex, self.settingsList, 1)
        return
    elseif row.kind == "fill" then
        if hasFill(d, row.name) then
            local kept = {}
            for _, n in ipairs(d.fillTypes) do
                if n ~= row.name then
                    kept[#kept + 1] = n
                end
            end
            d.fillTypes = kept
        else
            -- même ordre que la fenêtre (semence d'abord)
            local list = {}
            for _, e in ipairs(self.loads) do
                if e.name == row.name or hasFill(d, e.name) then
                    list[#list + 1] = e.name
                end
            end
            d.fillTypes = list
        end
    elseif row.kind == "refill" then
        self.mode = "markers"
        self:refreshItems()
        return
    elseif row.kind == "marker" then
        d.refill = row.name
        self.mode = "settings"
        self:refreshItems()
        -- retour sur la ligne « Zone de ravitaillement »
        pcall(self.settingsList.setSelectedIndex, self.settingsList, #self.rows)
        return
    end
    local index = self.settingsList:getSelectedIndexInSection()
    self:refreshItems()
    pcall(self.settingsList.setSelectedIndex, self.settingsList, index)
end

function ADSeederSettingsGui:onDoubleClick(list, section, index, cell)
    self:act(self.rows[index])
end

function ADSeederSettingsGui:onClickChange()
    self:act(self:selectedRow())
end

function ADSeederSettingsGui:onClickValidate()
    if self.mode ~= "settings" or self.ctx == nil or self.draft == nil then
        return
    end
    local missing = ADSeederManager.missing(self.draft)
    if missing == "fill" then
        self.message = g_i18n:getText("gui_ad_seeder_needFill")
        self:refreshItems()
        return
    elseif missing == "refill" then
        self.message = g_i18n:getText("gui_ad_seeder_needRefill")
        self:refreshItems()
        return
    end
    ADSeederManager:set(self.ctx.field, self.ctx.tool, self.draft)
    self.saved = ADSeederManager:get(self.ctx.field, self.ctx.toolKey)
    self:close()
end

function ADSeederSettingsGui:onClickBack(forceBack, usedMenuButton)
    if self.mode ~= "settings" then
        self.mode = "settings"
        self:refreshItems()
        return false
    end
    return ADSeederSettingsGui:superClass().onClickBack(self, forceBack, usedMenuButton)
end
