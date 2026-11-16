-- ============================================================================================================
-- FarmPilot : SiloCompactGUI.lua
-- Fenêtre « Tassage du silo » (16/11) : roue dentée « Tassage » du HUD, mode « Conduire vers », tracteur sans benne
-- (lame ou rouleau acceptés).
--
-- Même forme que la fenêtre de la presse. Lignes :
-- - Silo (le plus proche d'abord ; « Changer » passe au suivant) : à fond / traversant, taille, distance ;
-- - Tassage : % du silo (affichage) ;
-- - Entrée dans le silo : marche avant / marche arrière ;
-- - Largeur de travail : Auto (largeur calculée) / 2 à 6 m ;
-- - Hauteur de la lame : 0 à 0,5 m (seulement si une lame est attelée) ;
-- - Attente quand une benne arrive : sur le côté de l'entrée / un marqueur proche du silo (liste) ;
-- - À 100 % de tassage : continuer / s'arrêter (le message « bâchage possible » s'affiche dans les deux cas).
-- Boutons : Changer (ligne choisie), Démarrer / Arrêter, Retour. Les réglages partent au serveur à la fermeture,
-- à Démarrer et à Arrêter (SiloCompactEvent.lua).
--
-- Branché par une ligne chacune : Gui.lua (ADSiloCompactGui.load, gui/siloCompactGUI.xml) et la roue dentée
-- (SiloCompactorTask.lua : ADSiloJob.onGear).
-- ============================================================================================================

ADSiloCompactGui = {}
ADSiloCompactGui.context = nil -- { vehicle }
ADSiloCompactGui.SILO_RANGE = 1000 -- m, silos proposés

local ADSiloCompactGui_mt = Class(ADSiloCompactGui, DialogElement)

function ADSiloCompactGui.load()
    AutoDrive.gui.ADSiloCompactGui = ADSiloCompactGui.new()
    local result = g_gui:loadGui(AutoDrive.directory .. "gui/siloCompactGUI.xml", "ADSiloCompactGui", AutoDrive.gui.ADSiloCompactGui)
    if result == nil then
        AutoDrive.debugMsg(nil, "AutoDrive:loadGUI failed siloCompactGUI")
    end
end

function ADSiloCompactGui.open(vehicle)
    local gui = AutoDrive.gui ~= nil and AutoDrive.gui.ADSiloCompactGui or nil
    if gui ~= nil and not gui.isOpen and vehicle ~= nil and vehicle.ad ~= nil then
        ADSiloCompactGui.context = { vehicle = vehicle }
        g_gui:showDialog("ADSiloCompactGui")
    end
end

function ADSiloCompactGui.new(target)
    local self = DialogElement.new(target, ADSiloCompactGui_mt)
    self.rows = {}
    self.mode = "settings"
    return self
end

local function text(key)
    return g_i18n:getText(key)
end

local function meters(value)
    return string.format("%.2f m", value)
end

function ADSiloCompactGui:onOpen()
    ADSiloCompactGui:superClass().onOpen(self)
    self.settingsList:setDataSource(self)
    self.mode = "settings"
    self.message = nil
    self.vehicle = ADSiloCompactGui.context ~= nil and ADSiloCompactGui.context.vehicle or nil
    self.cfg = nil
    self.silos = {}
    self.siloIdx = 1
    if self.vehicle ~= nil then
        local base = ADSiloJob.getCfg(self.vehicle)
        self.cfg = ADSiloJob.textToCfg(ADSiloJob.cfgToText(base)) -- brouillon
        self.silos = ADSiloJob.silosNear(self.vehicle, ADSiloCompactGui.SILO_RANGE)
        -- silo en cours de tassage en premier
        local job = self.vehicle.ad.fpSiloJob
        local current = job ~= nil and ADSiloJob.findSilo(job.x, job.z) or nil
        if current == nil then
            local task = self.vehicle.ad.taskModule ~= nil and self.vehicle.ad.taskModule:getActiveTask() or nil
            current = task ~= nil and task.fpSiloCompact and task.silo or nil
        end
        for i, s in ipairs(self.silos) do
            if s.silo == current then
                self.siloIdx = i
            end
        end
    end
    self:refreshItems()
end

function ADSiloCompactGui:onClose()
    self:sendCfg(ADSiloCompactEvent.SAVE)
    ADSiloCompactGui:superClass().onClose(self)
end

function ADSiloCompactGui:selectedSilo()
    local s = self.silos[self.siloIdx]
    return s ~= nil and s.silo or nil, s
end

function ADSiloCompactGui:sendCfg(action)
    if self.vehicle == nil or self.cfg == nil then
        return
    end
    ADSiloJob.setCfg(self.vehicle, self.cfg) -- copie locale (le serveur reçoit la même)
    local x, z = 0, 0
    local silo = self:selectedSilo()
    if silo ~= nil then
        x, z = ADSiloJob.center(silo)
    end
    ADSiloCompactEvent.send(self.vehicle, action, ADSiloJob.cfgToText(self.cfg), x, z)
    self.cfg = ADSiloJob.textToCfg(ADSiloJob.cfgToText(self.cfg))
end

-- ------------------------------------------------------------------------------------------------------------
-- Lignes
-- ------------------------------------------------------------------------------------------------------------
function ADSiloCompactGui:getNumberOfItemsInSection(list, section)
    if list == self.settingsList then
        return #self.rows
    end
    return 0
end

function ADSiloCompactGui:populateCellForItemInSection(list, section, index, cell)
    if list == self.settingsList then
        local row = self.rows[index]
        cell.attributes.listItemText:setText(row.text or "")
        cell.attributes.listItemValue:setText(row.value or "")
        cell.target = self
    end
end

function ADSiloCompactGui:siloText(entry)
    if entry == nil then
        return text("gui_ad_silo_none")
    end
    local kind = ADSiloCompactor.hasBackWall(entry.silo) and text("gui_ad_silo_typeWall") or text("gui_ad_silo_typeThrough")
    if not ADSiloCompactor.isFilling(entry.silo) then
        kind = kind .. " · " .. text("gui_ad_silo_closed")
    end
    return string.format(text("gui_ad_silo_desc"), kind, entry.g.length, entry.g.width, entry.dist)
end

function ADSiloCompactGui:refreshItems()
    self.rows = {}
    local info
    local v = self.vehicle
    if v == nil or self.cfg == nil then
        info = text("gui_ad_silo_noVehicle")
    elseif self.mode == "markers" then
        info = text("gui_ad_silo_pickMarker")
        self.rows[#self.rows + 1] = { kind = "waitSide", text = text("gui_ad_silo_waitSide"), value = self.cfg.wait == ADSiloJob.WAIT_SIDE and text("gui_ad_seeder_current") or "" }
        local silo, entry = self:selectedSilo()
        local markers = {}
        for _, m in pairs(ADGraphManager:getMapMarkers()) do
            local wp = m ~= nil and m.name ~= nil and ADGraphManager:getWayPointById(m.id) or nil
            if wp ~= nil then
                local d = entry ~= nil and ADSiloCompactor.distanceTo(entry.g, wp.x, wp.z) or 0
                if entry == nil or (d > 3 and d < ADSiloJob.WAIT_MARKER_RANGE) then
                    markers[#markers + 1] = { m = m, d = d }
                end
            end
        end
        table.sort(markers, function(a, b) return a.d < b.d end)
        for _, e in ipairs(markers) do
            local value = string.format("%.0f m", e.d)
            if self.cfg.wait == ADSiloJob.WAIT_MARKER and e.m.name == self.cfg.marker then
                value = text("gui_ad_seeder_current") .. " · " .. value
            end
            self.rows[#self.rows + 1] = { kind = "marker", name = e.m.name, text = e.m.name, value = value }
        end
    else
        local running = ADSiloJob.isRunning(v)
        info = string.format(text("gui_ad_silo_head"), tostring(v.ad.stateModule:getName()), running and text("gui_ad_silo_running") or text("gui_ad_silo_stopped"))
        if not ADSiloCompactor.isCompactorCandidate(v) then
            info = info .. "\n" .. text("gui_ad_silo_hasTrailer")
        end
        if self.message ~= nil then
            info = info .. "\n" .. self.message
        end
        local silo, entry = self:selectedSilo()
        self.rows[#self.rows + 1] = { kind = "silo", text = text("gui_ad_silo_silo"), value = self:siloText(entry) .. (#self.silos > 1 and "  >" or "") }
        self.rows[#self.rows + 1] = { kind = "info", text = text("gui_ad_silo_compaction"), value = silo ~= nil and string.format("%d %%", ADSiloCompactor.getCompactedPercent(silo)) or "-" }
        self.rows[#self.rows + 1] = { kind = "dir", text = text("gui_ad_silo_dir"), value = text(self.cfg.dir == ADSiloJob.DIR_REVERSE and "gui_ad_silo_dirRev" or "gui_ad_silo_dirFwd") }
        local widthValue
        if self.cfg.width > 0 then
            widthValue = meters(self.cfg.width)
        else
            widthValue = text("gui_ad_silo_auto") .. string.format(" (%.1f m)", ADSiloTools.workWidth(v, nil))
        end
        self.rows[#self.rows + 1] = { kind = "width", text = text("gui_ad_silo_width"), value = widthValue }
        if ADSiloTools.hasBlade(v) then
            local pushKey = ({ [ADSiloJob.PUSH_AUTO] = "gui_ad_silo_pushAuto", [ADSiloJob.PUSH_WALL] = "gui_ad_silo_pushWall", [ADSiloJob.PUSH_NONE] = "gui_ad_silo_pushNone" })[self.cfg.push or 0]
            self.rows[#self.rows + 1] = { kind = "push", text = text("gui_ad_silo_push"), value = text(pushKey or "gui_ad_silo_pushAuto") }
            if self.cfg.push ~= ADSiloJob.PUSH_NONE then
                self.rows[#self.rows + 1] = { kind = "blade", text = text("gui_ad_silo_blade"), value = meters(self.cfg.blade) }
            end
        end
        local waitValue = text("gui_ad_silo_waitSide")
        if self.cfg.wait == ADSiloJob.WAIT_MARKER and self.cfg.marker ~= nil then
            waitValue = self.cfg.marker
        end
        self.rows[#self.rows + 1] = { kind = "wait", text = text("gui_ad_silo_wait"), value = waitValue .. "  >" }
        self.rows[#self.rows + 1] = { kind = "stop", text = text("gui_ad_silo_full"), value = text(self.cfg.stop and "gui_ad_silo_fullStop" or "gui_ad_silo_fullGo") }
    end
    self.infoText:setText(info or "")
    if self.changeButton ~= nil then
        self.changeButton:setText(text(self.mode ~= "settings" and "gui_ad_seeder_choose" or "gui_ad_autonomous_change"))
    end
    if self.validateButton ~= nil then
        local running = v ~= nil and ADSiloJob.isRunning(v)
        self.validateButton:setText(text(running and "gui_ad_silo_stop" or "gui_ad_silo_start"))
        self.validateButton:setDisabled(self.mode ~= "settings" or v == nil or (not running and self:selectedSilo() == nil))
    end
    self.settingsList:reloadData()
end

-- ------------------------------------------------------------------------------------------------------------
-- Boutons
-- ------------------------------------------------------------------------------------------------------------
local function nextIn(list, value)
    for i, x in ipairs(list) do
        if math.abs(x - value) < 0.001 then
            return list[(i % #list) + 1]
        end
    end
    return list[1]
end

function ADSiloCompactGui:selectedRow()
    if #self.rows == 0 then
        return nil
    end
    return self.rows[self.settingsList:getSelectedIndexInSection()]
end

function ADSiloCompactGui:act(row)
    if row == nil or self.cfg == nil then
        return
    end
    self.message = nil
    local keep = self.settingsList:getSelectedIndexInSection()
    if row.kind == "silo" then
        if #self.silos > 0 then
            self.siloIdx = (self.siloIdx % #self.silos) + 1
        end
    elseif row.kind == "dir" then
        self.cfg.dir = self.cfg.dir == ADSiloJob.DIR_REVERSE and ADSiloJob.DIR_FORWARD or ADSiloJob.DIR_REVERSE
    elseif row.kind == "width" then
        self.cfg.width = nextIn(ADSiloJob.WIDTHS, self.cfg.width)
    elseif row.kind == "push" then
        self.cfg.push = ((self.cfg.push or 0) + 1) % 3
    elseif row.kind == "blade" then
        self.cfg.blade = nextIn(ADSiloJob.BLADES, self.cfg.blade)
    elseif row.kind == "stop" then
        self.cfg.stop = not self.cfg.stop
    elseif row.kind == "wait" then
        self.mode = "markers"
        keep = 1
    elseif row.kind == "waitSide" then
        self.cfg.wait = ADSiloJob.WAIT_SIDE
        self.mode = "settings"
    elseif row.kind == "marker" then
        self.cfg.wait = ADSiloJob.WAIT_MARKER
        self.cfg.marker = row.name
        self.mode = "settings"
    else
        return
    end
    if row.kind == "waitSide" or row.kind == "marker" then
        for i, r in ipairs(self.rows) do
            if r.kind == "wait" then keep = i end
        end
    end
    self:refreshItems()
    if keep ~= nil and keep >= 1 and keep <= #self.rows then
        FarmPilotCall(self.settingsList.setSelectedIndex, self.settingsList, keep)
    end
end

function ADSiloCompactGui:onDoubleClick(list, section, index, cell)
    self:act(self.rows[index])
end

function ADSiloCompactGui:onClickChange()
    self:act(self:selectedRow())
end

function ADSiloCompactGui:onClickValidate()
    if self.mode ~= "settings" or self.vehicle == nil then
        return
    end
    if ADSiloJob.isRunning(self.vehicle) then
        self:sendCfg(ADSiloCompactEvent.STOP)
        self:close()
        return
    end
    local silo = self:selectedSilo()
    local why = ADSiloJob.refusal(self.vehicle, silo)
    if why ~= nil then
        self.message = text(why)
        self:refreshItems()
        return
    end
    self:sendCfg(ADSiloCompactEvent.START)
    self:close()
end

function ADSiloCompactGui:onClickBack(forceBack, usedMenuButton)
    if self.mode ~= "settings" then
        self.mode = "settings"
        self:refreshItems()
        return false
    end
    return ADSiloCompactGui:superClass().onClickBack(self, forceBack, usedMenuButton)
end
