-- ============================================================================================================
-- FarmPilot : AutonomousSprayerDump.lua
-- Mode Autonome, épandeurs et pulvés : « vider le trop » en fin de champ.
--
-- Demande Fabien 08/11 14:05 : « Retourner vider le trop à la fin du champ (si pas de suivant ou si pas de
-- changement de produit) ».
-- Choix de Fabien 08/11 21:22 (carte) : « Garder, sinon big bags/IBC ».
--
-- Règle :
-- - Champ fini (Courseplay ou ouvrier du jeu), avec un épandeur / pulvé réglé (SprayerManager.lua) qui a encore du
--   produit dans sa cuve :
--   - champ suivant avec la même machine et le même produit réglé : le reste est gardé (il servira là-bas, le plein
--     suivant ne prend que ce qui manque) ;
--   - sinon (pas de champ suivant, autre produit, autre outil) : le chauffeur va à la zone de plein de ce champ et y
--     vide la cuve en big bags / IBC, comme la touche « Décharger » du jeu (FillUnit:unloadFillUnits) ;
--   - la machine ne sait pas vider en big bags (pas de section <unloading> dans son xml, ou produit sans palette :
--     lisier, fumier, digestat), ou pas de zone de plein : le reste est gardé, le log dit pourquoi.
-- - Ensuite, la suite habituelle : champ suivant, sinon outil posé et tracteur garé (AutoDrive:onCpFinished).
-- Branché par une ligne dans : ExternalInterface.lua (2 fins de champ), AutonomousMode.lua (reset,
-- handleFinishedTask), Specialization.lua (stopAutoDrive).
-- ============================================================================================================

ADSprayerDump = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADSprayerDump.MIN_LITERS = 20           -- L : en dessous, rien à vider
ADSprayerDump.MIN_SHARE = 0.01          -- part de la cuve : en dessous, rien à vider
ADSprayerDump.STOP_TIMEOUT = 15000      -- ms pour s'arrêter avant de vider
ADSprayerDump.NO_CHANGE_TIME = 10000    -- ms sans baisse du niveau après la demande : pas de place / refusé
ADSprayerDump.UNLOAD_TIMEOUT = 60000    -- ms au plus pour vider

local function log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print("[FarmPilot Épandeur] " .. (ok and s or tostring(fmt)))
end

local function nameOf(vehicle)
    return tostring(vehicle.ad.stateModule:getName())
end

-- ------------------------------------------------------------------------------------------------------------
-- La machine sait-elle vider en big bags / IBC ?
-- ------------------------------------------------------------------------------------------------------------
-- true, ou false et la raison (pour le log)
function ADSprayerDump.canUnload(tool, fillUnitIndex)
    local spec = tool ~= nil and tool.spec_fillUnit or nil
    if spec == nil or tool.unloadFillUnits == nil then
        return false, "pas de cuve"
    end
    if spec.unloading == nil or #spec.unloading == 0 then
        return false, "la machine ne sait pas vider en big bags (pas de point de déchargement dans son fichier)"
    end
    local fillUnit = tool.getFillUnitByIndex ~= nil and tool:getFillUnitByIndex(fillUnitIndex) or (spec.fillUnits ~= nil and spec.fillUnits[fillUnitIndex]) or nil
    if fillUnit == nil or not fillUnit.canBeUnloaded then
        return false, "cette cuve ne se vide pas en big bags"
    end
    local palletFile = tool.getFillUnitUnloadPalletFilename ~= nil and tool:getFillUnitUnloadPalletFilename(fillUnitIndex) or nil
    if palletFile == nil then
        return false, "pas de big bag ni d'IBC pour ce produit"
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Décision en fin de champ
-- ------------------------------------------------------------------------------------------------------------
-- nil (rien à faire : pas d'épandeur, cuve presque vide), ou { action = "keep" | "dump", why, tool, marker, level, fillType }
function ADSprayerDump.decide(vehicle)
    if ADSprayerManager == nil or vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil then
        return nil
    end
    local sm = vehicle.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return nil
    end
    local ctx = ADSprayerManager.context(vehicle, false)
    if ctx == nil or not ADSprayerManager.isAttached(ctx.tool, vehicle) then
        return nil
    end
    local tool = ctx.tool
    local level, ft, cap = ADSprayerManager.content(tool)
    if ft == nil or level < math.max(ADSprayerDump.MIN_LITERS, (cap or 0) * ADSprayerDump.MIN_SHARE) then
        return nil
    end
    local d = { tool = tool, level = level, fillType = ft, field = ctx.field }
    local product = g_fillTypeManager:getFillTypeNameByIndex(ft)
    -- champ suivant : même machine et même produit = on garde
    local nextField = sm.getFpNextField ~= nil and sm:getFpNextField() or nil
    if nextField ~= nil and nextField.name ~= nil then
        local nextTool = sm.getFpNextTool ~= nil and sm:getFpNextTool() or nil
        if nextTool == nil or nextTool == tool then
            local s = ADSprayerManager:get(nextField.name, ctx.toolKey)
            if s == nil or s.fillType == nil then
                d.action, d.why = "keep", string.format("champ suivant « %s » pas encore réglé, reste gardé", tostring(nextField.name))
                return d
            end
            if s.fillType == product then
                d.action, d.why = "keep", string.format("même produit (%s) au champ suivant « %s »", tostring(product), tostring(nextField.name))
                return d
            end
            d.why = string.format("autre produit au champ suivant (%s -> %s)", tostring(product), tostring(s.fillType))
        else
            d.why = "autre outil au champ suivant"
        end
    else
        d.why = "pas de champ suivant"
    end
    local unit = ADSprayerManager.fillUnit(tool)
    local ok, why = ADSprayerDump.canUnload(tool, unit)
    if not ok then
        d.action, d.why = "keep", d.why .. ", mais " .. tostring(why) .. " : reste gardé"
        return d
    end
    local s = ADSprayerManager:get(ctx.field, ctx.toolKey)
    local marker = s ~= nil and s.refill ~= nil and ADGraphManager:getMapMarkerByName(s.refill) or nil
    if marker == nil then
        d.action, d.why = "keep", d.why .. ", mais pas de zone de plein réglée : reste gardé"
        return d
    end
    d.action, d.marker = "dump", marker
    return d
end

-- ------------------------------------------------------------------------------------------------------------
-- Hook ExternalInterface (fin de champ) : true si le chauffeur part vider (la suite viendra après)
-- ------------------------------------------------------------------------------------------------------------
function ADSprayerDump.onFieldFinished(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.modes == nil then
        return false
    end
    if vehicle.ad.fpDumpDone then
        -- revenu de la vidange : la suite habituelle (champ suivant / parking)
        vehicle.ad.fpDumpDone = nil
        return false
    end
    local sm = vehicle.ad.stateModule
    if sm:isActive() then
        return false
    end
    local okD, d = pcall(ADSprayerDump.decide, vehicle)
    if not okD then
        log("ERREUR vider le reste : %s", tostring(d))
        return false
    end
    if d == nil then
        return false
    end
    local name = nameOf(vehicle)
    local title = ADSprayerManager.productTitle(g_fillTypeManager:getFillTypeNameByIndex(d.fillType))
    if d.action ~= "dump" then
        log("%s : « %s » fini, %.0f L de %s dans la cuve : %s", name, tostring(d.field), d.level, tostring(title), tostring(d.why))
        return false
    end
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.onRouteToPark = false
    vehicle.ad.restartCP = false
    sm:setStartHelper(false)
    vehicle:startAutoDrive()
    if not sm:isActive() then
        return false
    end
    local mode = vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    mode:reset()
    mode.dumpStage = "drive"
    mode.dumpTool = d.tool
    mode.dumpMarker = d.marker
    mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, d.marker.id)
    vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
    log("%s : « %s » fini, %.0f L de %s dans la cuve (%s) : va les vider en big bags à « %s »", name, tostring(d.field), d.level, tostring(title),
        tostring(d.why), tostring(d.marker.name))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_dumpGo", tostring(d.marker.name))
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Hook AutonomousMode:handleFinishedTask : étapes « drive » (route vers la zone) -> « unload » (vidange)
-- ------------------------------------------------------------------------------------------------------------
function ADSprayerDump.handleStage(mode)
    local vehicle = mode.vehicle
    local name = nameOf(vehicle)
    if vehicle.ad.isStoppingWithError then
        mode.dumpStage = nil
        mode.driveToDestinationTask = nil
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
        return
    end
    if mode.dumpStage == "drive" then
        mode.driveToDestinationTask = nil
        mode.dumpStage = "unload"
        mode.dumpTask = ADDumpRestTask:new(vehicle, mode.dumpTool)
        vehicle.ad.taskModule:addTask(mode.dumpTask)
        return
    end
    -- « unload » fini
    local task = mode.dumpTask
    local result = task ~= nil and task.result or "?"
    local marker = mode.dumpMarker
    mode.dumpStage = nil
    mode.dumpTask = nil
    mode.dumpTool = nil
    mode.dumpMarker = nil
    if result == "ok" then
        log("%s : reste vidé en big bags à « %s » (%.0f L)", name, tostring(marker ~= nil and marker.name), task.unloaded or 0)
    else
        log("%s : vidange en big bags pas faite (%s), reste gardé", name, tostring(result))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 12000, "AD_autonomous_dumpFailed", tostring(marker ~= nil and marker.name or "?"))
    end
    -- la suite (champ suivant / parking) une fois FarmPilot arrêté : afterStop
    vehicle.ad.fpDumpContinue = true
    vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
end

-- ------------------------------------------------------------------------------------------------------------
-- Hook AutoDrive:stopAutoDrive : après la vidange, la suite habituelle de fin de champ (à l'image suivante)
-- ------------------------------------------------------------------------------------------------------------
function ADSprayerDump.continueAfterDump(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.stateModule:isActive() then
        return
    end
    vehicle.ad.fpDumpDone = true
    local ok, err = pcall(AutoDrive.onCpFinished, vehicle)
    if not ok then
        log("ERREUR suite après la vidange : %s", tostring(err))
    end
    vehicle.ad.fpDumpDone = nil
end

function ADSprayerDump.afterStop(vehicle)
    if vehicle == nil or vehicle.ad == nil or not vehicle.ad.fpDumpContinue then
        return
    end
    vehicle.ad.fpDumpContinue = nil
    if vehicle.ad.isStoppingWithError then
        return
    end
    -- à l'image suivante : FarmPilot doit être complètement arrêté avant de repartir
    local mission = g_currentMission
    if mission ~= nil and mission.addUpdateable ~= nil and mission.removeUpdateable ~= nil then
        local once = {}
        once.update = function(self, dt)
            mission:removeUpdateable(self)
            ADSprayerDump.continueAfterDump(vehicle)
        end
        mission:addUpdateable(once)
    else
        ADSprayerDump.continueAfterDump(vehicle)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Tâche : arrêt, outil coupé, puis « Décharger » du jeu (big bags / IBC posés à côté de la machine)
-- ------------------------------------------------------------------------------------------------------------
ADDumpRestTask = ADInheritsFrom(AbstractTask)

function ADDumpRestTask:new(vehicle, tool)
    local o = ADDumpRestTask:create()
    o.vehicle = vehicle
    o.tool = tool
    o.result = nil
    return o
end

function ADDumpRestTask:setUp()
    self.timer = 0
    self.requested = false
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

function ADDumpRestTask:level()
    local level = ADSprayerManager.content(self.tool)
    return level or 0
end

function ADDumpRestTask:update(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    self.timer = self.timer + dt
    if self.tool == nil or self.tool.isDeleted then
        self:finish("machine disparue")
        return
    end
    if not self.requested then
        if math.abs(self.vehicle.lastSpeedReal or 0) < 0.0015 then
            if self.tool.getIsTurnedOn ~= nil and self.tool:getIsTurnedOn() and self.tool.setIsTurnedOn ~= nil then
                self.tool:setIsTurnedOn(false)
            end
            self.startLevel = self:level()
            self.lastLevel = self.startLevel
            self.lastChange = self.timer
            self.requested = true
            local ok, err = pcall(self.tool.unloadFillUnits, self.tool, true)
            if not ok then
                self:finish("erreur du jeu : " .. tostring(err))
            end
        elseif self.timer >= ADSprayerDump.STOP_TIMEOUT then
            self:finish("pas arrêté")
        end
        return
    end
    local level = self:level()
    if level < self.lastLevel - 0.5 then
        self.lastLevel = level
        self.lastChange = self.timer
    end
    if level < ADSprayerDump.MIN_LITERS then
        self.unloaded = (self.startLevel or 0) - level
        self:finish("ok")
    elseif self.timer - self.lastChange >= ADSprayerDump.NO_CHANGE_TIME then
        self.unloaded = (self.startLevel or 0) - level
        if self.unloaded > 0.5 then
            self:finish("ok")
        else
            self:finish("pas de place pour poser les big bags")
        end
    elseif self.timer >= ADSprayerDump.UNLOAD_TIMEOUT then
        self.unloaded = (self.startLevel or 0) - level
        self:finish(self.unloaded > 0.5 and "ok" or "délai dépassé")
    end
end

function ADDumpRestTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self:finished()
end

function ADDumpRestTask:abort()
end

function ADDumpRestTask:finished()
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADDumpRestTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_dump;"
end
