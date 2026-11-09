-- ============================================================================================================
-- FarmPilot : AutonomousCoursesGUI.lua
-- Fenêtre « Parcours Autonome » (mode Autonome).
--
-- Règle : pour l'outil attelé au véhicule où l'on est, un champ par ligne (ou un groupe de champs AutoSwitch, ou un
-- parcours sur plusieurs champs), avec le parcours Courseplay (de la même largeur) que le mode Autonome lancera sur
-- ce champ. « Automatique » = FarmPilot prend le seul parcours possible, ou s'arrête s'il y en a plusieurs.
-- « Changer » (ou double clic) : Automatique -> 1er parcours -> 2e ... -> Automatique. Le choix va dans la mémoire
-- champ + outil (AutonomousManager.lua).
--
-- Branché par : Gui.lua (création, gui/autonomousCoursesGUI.xml, AutoDrive.onOpenAutonomousCourses), InputManager.lua
-- (input_autonomousCourses, bouton du HUD).
-- ============================================================================================================

ADAutonomousCoursesGui = {}
ADAutonomousCoursesGui.debug = false

local ADAutonomousCoursesGui_mt = Class(ADAutonomousCoursesGui, DialogElement)

-- ------------------------------------------------------------------------------------------------------------
-- Création et ouverture
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousCoursesGui.new(target)
    local self = DialogElement.new(target, ADAutonomousCoursesGui_mt)
    self:include(ADGuiDebugMixin)
    self.rows = {}
    return self
end

function ADAutonomousCoursesGui:onOpen()
    ADAutonomousCoursesGui:superClass().onOpen(self)
    self.courseList:setDataSource(self)
    self:refreshItems()
end

-- ------------------------------------------------------------------------------------------------------------
-- Liste des champs
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousCoursesGui:getNumberOfItemsInSection(list, section)
    if list == self.courseList then
        return #self.rows
    end
    return 0
end

local function rowValue(row)
    if row.chosen ~= nil then
        return ADAutonomousManager.courseLabel(row.chosen)
    end
    if #row.list == 1 then
        return string.format(g_i18n:getText("gui_ad_autonomous_autoOne"), ADAutonomousManager.courseLabel(row.list[1]))
    end
    return string.format(g_i18n:getText("gui_ad_autonomous_autoSeveral"), tostring(#row.list))
end

function ADAutonomousCoursesGui:populateCellForItemInSection(list, section, index, cell)
    if list == self.courseList then
        local row = self.rows[index]
        cell.attributes.listItemText:setText(ADAutonomousManager.fieldsLabel(row.nums))
        cell.attributes.listItemValue:setText(rowValue(row))
        cell.target = self
    end
end

function ADAutonomousCoursesGui:refreshItems()
    self.rows = {}
    self.vehicle = AutoDrive.getControlledVehicle ~= nil and AutoDrive.getControlledVehicle() or nil
    local info
    local v = self.vehicle
    if v == nil or v.ad == nil then
        info = g_i18n:getText("gui_ad_autonomous_noVehicle")
    elseif not ADAutonomousManager.hasCp(v) then
        info = g_i18n:getText("gui_ad_autonomous_noCp")
    else
        self.width = ADAutonomousManager.toolWidth(v)
        self.tool = ADAutonomousManager.toolIdentity(v)
        if self.width == nil then
            info = g_i18n:getText("gui_ad_autonomous_noWidth")
        else
            ADAutonomousManager.cache = {}
            local courses = ADAutonomousManager.listCourses() or {}
            local byField = {}
            -- une ligne par champ, ou par groupe de champs (AutoSwitch) / parcours sur plusieurs champs
            for _, e in ipairs(courses) do
                if e.rowKey ~= nil and ADAutonomousManager.sameWidth(e.w, self.width) then
                    local r = byField[e.rowKey]
                    if r == nil then
                        r = {fieldNum = e.rowKey, nums = e.fieldNums, list = {}}
                        byField[e.rowKey] = r
                        self.rows[#self.rows + 1] = r
                    end
                    r.list[#r.list + 1] = e
                end
            end
            for _, r in ipairs(self.rows) do
                local a = ADAutonomousManager:getAssignment(r.fieldNum, self.tool.key, self.tool.legacyKey)
                if a ~= nil then
                    for _, e in ipairs(r.list) do
                        if e.path == a.path then
                            r.chosen = e
                        end
                    end
                end
            end
            table.sort(self.rows, function(a, b)
                local na, nb = tonumber(a.nums[1]), tonumber(b.nums[1])
                if na ~= nil and nb ~= nil and na ~= nb then
                    return na < nb
                end
                return tostring(a.fieldNum) < tostring(b.fieldNum)
            end)
            info = string.format(g_i18n:getText("gui_ad_autonomous_tool"), tostring(self.tool.name), string.format("%.1f", self.width))
            if #self.rows == 0 then
                info = info .. "\n" .. string.format(g_i18n:getText("gui_ad_autonomous_noCourse"), string.format("%.1f", self.width))
            end
        end
    end
    self.infoText:setText(info or "")
    self.courseList:reloadData()
end

-- ------------------------------------------------------------------------------------------------------------
-- Boutons
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousCoursesGui:selectedRow()
    if #self.rows == 0 then
        return nil
    end
    return self.rows[self.courseList:getSelectedIndexInSection()]
end

-- Automatique -> 1er parcours -> 2e ... -> Automatique
function ADAutonomousCoursesGui:cycle(row)
    if row == nil or self.tool == nil then
        return
    end
    local nextE = nil
    if row.chosen == nil then
        nextE = row.list[1]
    else
        for i, e in ipairs(row.list) do
            if e == row.chosen then
                nextE = row.list[i + 1]
            end
        end
    end
    row.chosen = nextE
    ADAutonomousManager:setAssignment(row.fieldNum, self.tool, self.width, nextE, true)
    self.courseList:reloadData()
end

function ADAutonomousCoursesGui:onDoubleClick(list, section, index, cell)
    self:cycle(self.rows[index])
end

function ADAutonomousCoursesGui:onClickChange()
    self:cycle(self:selectedRow())
end

function ADAutonomousCoursesGui:onClickAuto()
    local row = self:selectedRow()
    if row == nil or self.tool == nil then
        return
    end
    row.chosen = nil
    ADAutonomousManager:setAssignment(row.fieldNum, self.tool, self.width, nil, true)
    self.courseList:reloadData()
end
