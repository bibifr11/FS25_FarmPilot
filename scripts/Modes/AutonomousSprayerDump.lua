-- ============================================================================================================
-- FarmPilot : AutonomousSprayerDump.lua
-- Mode Autonome, épandeurs et pulvés : « vider le trop » en fin de champ.
--
-- (08/11) Retourner vider le trop à la fin du champ (si pas de suivant ou si pas de changement de
-- produit).
-- Choix retenu : garder le reste, sinon le vider en big bags / IBC.
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
--
-- Bouton « Envoyer au parking » (08/11 : sur un épandeur, le parking ne vidait pas ; s'il a du produit, il
-- doit vider) : tout mode, automoteur ou outil attelé.
-- - Produit dans la cuve (plus de MIN_LITERS) : pas de champ suivant à garder, on vide toujours. Zone : celle du
--   champ en cours (mode Autonome), sinon la dernière réglée pour cette machine et ce produit, sinon la dernière
--   réglée pour cette machine, sinon le marqueur le plus proche d'une zone qui a ce produit (RefillSources.lua).
-- - Vidange (mêmes étapes qu'en fin de champ), puis le bouton parking comme avant (outil posé à sa place si elle
--   existe, puis tracteur garé), même si la vidange n'a pas pu se faire.
-- - La machine ne sait pas vider en big bags, ou aucune zone : message, parking comme avant.
--
-- Branché par une ligne dans : ExternalInterface.lua (2 fins de champ), AutonomousMode.lua (reset,
-- handleFinishedTask), Specialization.lua (stopAutoDrive), AutonomousParkButton.lua (bouton parking).
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
    local ok, s = FarmPilotCall(string.format, fmt, ...)
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
-- Départ vers la zone (fin de champ et bouton parking) ; after = nil (suite de fin de champ) ou "park"
-- ------------------------------------------------------------------------------------------------------------
function ADSprayerDump.start(vehicle, d, after)
    local sm = vehicle.ad.stateModule
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.onRouteToPark = false
    vehicle.ad.restartCP = false
    vehicle.ad.fpDumpThen = after
    sm:setStartHelper(false)
    vehicle:startAutoDrive()
    if not sm:isActive() then
        vehicle.ad.fpDumpThen = nil
        return false
    end
    local mode = vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    mode:reset()
    mode.dumpStage = "drive"
    mode.dumpTool = d.tool
    mode.dumpMarker = d.marker
    mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, d.marker.id)
    vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
    return true
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
    local okD, d = FarmPilotCall(ADSprayerDump.decide, vehicle)
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
    if not ADSprayerDump.start(vehicle, d, nil) then
        return false
    end
    log("%s : « %s » fini, %.0f L de %s dans la cuve (%s) : va les vider en big bags à « %s »", name, tostring(d.field), d.level, tostring(title),
        tostring(d.why), tostring(d.marker.name))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_dumpGo", tostring(d.marker.name))
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Bouton parking : où vider ?
-- ------------------------------------------------------------------------------------------------------------
-- marqueur, d'où vient le choix (pour le log) ; nil si aucun
function ADSprayerDump.parkMarker(vehicle, tool, ft)
    local function valid(name)
        return name ~= nil and ADGraphManager:getMapMarkerByName(name) or nil
    end
    local product = g_fillTypeManager:getFillTypeNameByIndex(ft)
    -- 1) zone de plein du champ en cours (mode Autonome)
    local ctx = vehicle.ad.stateModule:getMode() == AutoDrive.MODE_AUTONOMOUS and ADSprayerManager.context(vehicle, false) or nil
    if ctx ~= nil and ctx.tool == tool then
        local s = ADSprayerManager:get(ctx.field, ctx.toolKey)
        local m = s ~= nil and valid(s.refill) or nil
        if m ~= nil then
            return m, string.format("zone de plein du champ « %s »", tostring(ctx.field))
        end
    end
    -- 2) dernier réglage de cette machine avec ce produit, 3) dernier réglage de cette machine
    local toolKey = ADSeederManager.toolKey(tool)
    ADSprayerManager:loadFromXml()
    local same, any = nil, nil
    for _, s in pairs(ADSprayerManager.settings or {}) do
        if s.tool == toolKey and valid(s.refill) ~= nil then
            if s.fillType == product and (same == nil or (s.stamp or 0) > (same.stamp or 0)) then
                same = s
            end
            if any == nil or (s.stamp or 0) > (any.stamp or 0) then
                any = s
            end
        end
    end
    if same ~= nil then
        return valid(same.refill), string.format("zone de plein réglée pour ce produit (champ « %s »)", tostring(same.field))
    end
    if any ~= nil then
        return valid(any.refill), string.format("dernière zone de plein réglée pour cette machine (champ « %s »)", tostring(any.field))
    end
    -- 4) marqueur le plus proche d'une zone qui a ce produit
    if ADRefillSources ~= nil then
        local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
        local allowed = ADRefillSources.markersNear(ADRefillSources.find({ ft }, farmId))
        local node = vehicle.rootNode or (vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node) or nil
        local x, z = 0, 0
        if node ~= nil then
            local px, _, pz = getWorldTranslation(node)
            x, z = px, pz
        end
        local best, bestD = nil, math.huge
        for name, _ in pairs(allowed) do
            local m = valid(name)
            local wp = m ~= nil and ADGraphManager:getWayPointById(m.id) or nil
            if wp ~= nil then
                local dist = (wp.x - x) ^ 2 + (wp.z - z) ^ 2
                if dist < bestD then
                    best, bestD = m, dist
                end
            end
        end
        if best ~= nil then
            return best, "marqueur le plus proche d'une zone qui a ce produit"
        end
    end
    return nil
end

-- nil (rien à vider), ou { action = "keep" | "dump", why, tool, marker, level, fillType }
function ADSprayerDump.decideForPark(vehicle)
    if ADSprayerManager == nil or vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.modes == nil
        or vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS] == nil then
        return nil
    end
    local tool = nil
    if vehicle.ad.stateModule:getMode() == AutoDrive.MODE_AUTONOMOUS then
        local ctx = ADSprayerManager.context(vehicle, false)
        if ctx ~= nil and ADSprayerManager.isAttached(ctx.tool, vehicle) then
            tool = ctx.tool
        end
    end
    tool = tool or ADSprayerManager.attachedSprayer(vehicle)
    if tool == nil then
        return nil
    end
    local level, ft = ADSprayerManager.content(tool)
    if ft == nil or level < ADSprayerDump.MIN_LITERS then
        return nil
    end
    local d = { tool = tool, level = level, fillType = ft }
    local ok, why = ADSprayerDump.canUnload(tool, ADSprayerManager.fillUnit(tool))
    if not ok then
        d.action, d.why = "keep", tostring(why)
        return d
    end
    local marker, from = ADSprayerDump.parkMarker(vehicle, tool, ft)
    if marker == nil then
        d.action, d.why = "keep", "aucune zone de plein réglée ni trouvée pour ce produit"
        return d
    end
    d.action, d.marker, d.why = "dump", marker, from
    return d
end

-- ------------------------------------------------------------------------------------------------------------
-- Hook ADInputManager:input_parkVehicle (AutonomousParkButton.lua) : true si le chauffeur part vider d'abord
-- ------------------------------------------------------------------------------------------------------------
function ADSprayerDump.onParkButton(input, vehicle, farmId)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.fpSkipParkDump then
        return false
    end
    local okD, d = FarmPilotCall(ADSprayerDump.decideForPark, vehicle)
    if not okD then
        log("ERREUR bouton parking, vider le reste : %s", tostring(d))
        return false
    end
    if d == nil then
        return false
    end
    local name = nameOf(vehicle)
    local title = ADSprayerManager.productTitle(g_fillTypeManager:getFillTypeNameByIndex(d.fillType))
    if d.action ~= "dump" then
        log("%s : bouton parking, %.0f L de %s dans la cuve, pas vidé (%s) : parking comme avant", name, d.level, tostring(title), tostring(d.why))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 12000, "AD_autonomous_dumpKept", tostring(title), tostring(d.why))
        return false
    end
    -- comme le bouton d'origine : Courseplay arrêté, FarmPilot arrêté s'il roulait
    AutoDrive:StopCP(vehicle)
    if vehicle.ad.stateModule:isActive() then
        input:input_start_stop(vehicle, farmId)
    end
    if ADParkButton ~= nil then ADParkButton.rememberMode(vehicle) end -- mode d'avant rendu à l'arrêt, voir AutonomousParkButton.lua
    vehicle.ad.stateModule:setMode(AutoDrive.MODE_AUTONOMOUS)
    if not ADSprayerDump.start(vehicle, d, "park") then
        log("%s : bouton parking, vidange pas lancée : parking comme avant", name)
        if ADParkButton ~= nil then ADParkButton.restoreMode(vehicle) end
        return false
    end
    log("%s : bouton parking, %.0f L de %s dans la cuve : va les vider en big bags à « %s » (%s), puis au parking", name, d.level, tostring(title),
        tostring(d.marker.name), tostring(d.why))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_dumpParkGo", tostring(d.marker.name))
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
    if vehicle.ad.fpDumpThen == "park" then
        -- bouton parking : le bouton comme avant (outil posé à sa place s'il y en a une, puis tracteur garé)
        vehicle.ad.fpDumpThen = nil
        vehicle.ad.fpSkipParkDump = true
        local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
        local okP, errP = FarmPilotCall(ADInputManager.input_parkVehicle, ADInputManager, vehicle, farmId)
        vehicle.ad.fpSkipParkDump = nil
        if not okP then
            log("ERREUR parking après la vidange : %s", tostring(errP))
        end
        return
    end
    vehicle.ad.fpDumpDone = true
    local ok, err = FarmPilotCall(AutoDrive.onCpFinished, vehicle)
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
        vehicle.ad.fpDumpThen = nil
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
            local ok, err = FarmPilotCall(self.tool.unloadFillUnits, self.tool, true)
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
