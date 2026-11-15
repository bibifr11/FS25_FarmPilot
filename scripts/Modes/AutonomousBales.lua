-- ============================================================================================================
-- FarmPilot : AutonomousBales.lua
-- Mode Autonome, remorque à balles : du champ au dépôt, et retour.
--
-- Règle (09/11) :
-- - À l'arrivée au champ avec une remorque à balles réglée (roue dentée, BaleLoaderManager.lua) : pas de parcours
--   Courseplay, notre ramassage (BaleCollectTask.lua) sur le champ du marqueur.
-- - Remorque pleine : route vers la zone de dépôt réglée, déchargement (le pousseur du jeu, comme la touche
--   « Décharger » : au point de vente les balles tombent dans sa zone et sont vendues, ailleurs elles restent
--   posées), puis retour au champ s'il reste des balles.
-- - Plus de balle à ramasser : s'il y en a sur la remorque, dépôt d'abord ; puis la suite habituelle d'un champ fini
--   (champ suivant, sinon remorque posée à sa place et tracteur garé : AutoDrive:onCpFinished).
-- - Aucune balle au champ à l'arrivée et remorque vide : message, puis la même suite.
-- - Erreur (bras qui ne sort pas, remorque dételée, déchargement refusé) : message, arrêt et attente.
-- - (09/11) Bouton >> (Continuer) avec des balles chargées : dépôt tout de suite (après la balle en cours), puis
--   retour au champ s'il en reste. Remorque vide : champ laissé, la suite habituelle d'un champ fini. Pareil
--   sur le 1er trajet vers le champ.
-- - (15/11) Enrubanneuse (BaleWrapperManager.lua) : même arrivée, même tâche (BaleCollectTask.lua), pas de dépôt :
--   les balles enrubannées restent où la machine les pose. Étapes : « collect » (enrubannage), « refill » (plus de
--   film : route vers la zone de recharge du film, plein aux palettes, AutonomousMode.startRefill comme le semoir),
--   « toField » (retour au champ, l'enrubannage reprend). Plus de balle à enrubanner : la suite d'un champ fini
--   (finishField). >> : champ laissé après la balle en cours. Erreur (machine qui ne se déplie pas, balle pas finie,
--   machine dételée, zone de recharge introuvable, film pas rechargé) : message, arrêt et attente.
--
-- Branché par une ligne dans : AutonomousMode.lua (reset ; handleFinishedTask : étapes et arrivée au champ ;
-- continue : bouton >> ; handleRefillStage : afterRefill, film rechargé),
-- Specialization.lua (stopAutoDrive : afterStop).
-- ============================================================================================================

ADBaleCollect = {}

local function log(fmt, ...)
    ADBaleLoaderManager.log(fmt, ...)
end

local function nameOf(vehicle)
    return tostring(vehicle.ad.stateModule:getName())
end

local function message(vehicle, kind, key, ...)
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes[kind], kind == "ERROR" and 15000 or 8000, key, ...)
end

-- ------------------------------------------------------------------------------------------------------------
-- Remise à zéro (hook AutonomousMode:reset)
-- ------------------------------------------------------------------------------------------------------------
function ADBaleCollect.reset(mode)
    mode.baleStage = nil
    mode.baleTask = nil
    mode.baleCtx = nil
    mode.baleBack = nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Arrivée au champ (hook AutonomousMode:handleFinishedTask) : true si le ramassage prend la main
-- ------------------------------------------------------------------------------------------------------------
-- { tool, toolKey, field, marker, settings, fieldNum, fieldNums, fieldMarker, kind, wrapped } ou nil (pas de remorque
-- réglée attelée) ; (15/11) kind = « wrapper » : enrubanneuse, wrapped = balles enrubannées au champ (titre)
function ADBaleCollect.makeContext(vehicle)
    local c = ADBaleLoaderManager.context(vehicle, false)
    if c == nil or not ADBaleLoaderManager.isAttached(c.tool, vehicle) then
        return nil
    end
    local s = ADBaleLoaderManager:get(c.field, c.toolKey)
    if not ADBaleLoaderManager.isValid(s, c.kind) then
        return nil
    end
    c.settings = s
    c.wrapped = 0
    c.fieldMarker = vehicle.ad.stateModule:getFirstMarker()
    local f = ADAutonomousManager.nearField(vehicle)
    c.fieldNum = f ~= nil and ADAutonomousManager.fieldNumber(f) or nil
    c.fieldNums = ADBaleLoaderManager.fieldNumbers(c.fieldNum)
    return c
end

function ADBaleCollect.onArrival(mode)
    local vehicle = mode.vehicle
    local ok, ctx = FarmPilotCall(ADBaleCollect.makeContext, vehicle)
    if not ok then
        log("ERREUR remorque à balles : %s", tostring(ctx))
        return false
    end
    if ctx == nil then
        return false
    end
    mode.baleCtx = ctx
    if ctx.fieldNum == nil then
        log("%s : arrivée à « %s », pas de champ ici : arrêt et attente", nameOf(vehicle), tostring(ctx.field))
        message(vehicle, "ERROR", "AD_autonomous_noField")
        ADBaleCollect.stopAndWait(mode)
        return true
    end
    ADBaleCollect.startCollect(mode, true)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Étapes
-- ------------------------------------------------------------------------------------------------------------
function ADBaleCollect.startCollect(mode, first)
    local vehicle, ctx = mode.vehicle, mode.baleCtx
    if ctx.kind == "wrapper" then
        ADBaleCollect.startWrap(mode, first)
        return
    end
    local list, onField = ADBaleLoaderManager.findBales(ctx.tool, ctx.fieldNums, ctx.settings.wrap, nil)
    local loaded = ADBaleLoaderManager.loadedCount(ctx.tool)
    local f = tostring(ctx.fieldNum)
    log("%s : champ %s, %d balle(s) à ramasser (%d sur le champ, balles %s), %d sur la remorque", nameOf(vehicle), f, #list, onField,
        tostring(ctx.settings.wrap), loaded)
    -- (15/11) balles autour pas comptées, et pourquoi
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    FarmPilotCall(ADBaleLoaderManager.reportMissed, nameOf(vehicle), ctx.tool, ctx.fieldNums, ctx.settings.wrap, nil, vx, vz)
    if #list == 0 or ADBaleLoaderManager.isFull(ctx.tool) then
        if loaded > 0 then
            ADBaleCollect.goDeposit(mode, #list > 0)
            return
        end
        message(vehicle, "INFO", "AD_autonomous_balesNone", f)
        ADBaleCollect.finishField(mode)
        return
    end
    if first then
        message(vehicle, "INFO", "AD_autonomous_balesStart", f, #list)
    end
    mode.baleStage = "collect"
    mode.baleTask = ADBaleCollectTask:new(vehicle, ctx)
    vehicle.ad.taskModule:addTask(mode.baleTask)
end

-- (15/11) enrubanneuse au champ : balles à enrubanner ; aucune (et pas de balle en cours sur la machine) = suite d'un
-- champ fini. Sans film, la tâche replie la machine et rend « noFilm » (recharge, voir goRefill)
function ADBaleCollect.startWrap(mode, first)
    local vehicle, ctx = mode.vehicle, mode.baleCtx
    local list, onField = ADBaleLoaderManager.findBales(ctx.tool, ctx.fieldNums, nil, nil)
    local f = tostring(ctx.fieldNum)
    local film = ADBaleWrapper.filmAvailable(ctx.tool)
    log("%s : champ %s, %d balle(s) à enrubanner (%d sur le champ), film : %s", nameOf(vehicle), f, #list, onField, ADBaleWrapper.filmText(ctx.tool))
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    FarmPilotCall(ADBaleLoaderManager.reportMissed, nameOf(vehicle), ctx.tool, ctx.fieldNums, nil, nil, vx, vz)
    if #list == 0 and not ADBaleLoaderManager.isBusy(ctx.tool) then
        log("%s : champ %s fini, plus de balle à enrubanner (%d enrubannée(s))", nameOf(vehicle), f, ctx.wrapped or 0)
        message(vehicle, "INFO", "AD_autonomous_wrapNone", f)
        ADBaleCollect.finishField(mode)
        return
    end
    if first and film then
        message(vehicle, "INFO", "AD_autonomous_wrapStart", f, #list)
    end
    mode.baleStage = "collect"
    mode.baleTask = ADBaleCollectTask:new(vehicle, ctx)
    vehicle.ad.taskModule:addTask(mode.baleTask)
end

-- (15/11) plus de film : route vers la zone de recharge du film, plein aux palettes près du marqueur (même plein que le
-- semoir : AutonomousMode.startRefill, la tâche de plein sort du champ), puis retour au champ (afterRefill)
function ADBaleCollect.goRefill(mode)
    local vehicle, ctx = mode.vehicle, mode.baleCtx
    local zone = ctx.settings ~= nil and ctx.settings.refill or nil
    local okP, plan = FarmPilotCall(ADBaleWrapper.refillPlan, ctx)
    plan = okP and plan or nil
    if plan == nil or plan.marker == nil or #plan.fillTypes == 0 then
        log("%s : plus de film et zone de recharge « %s » introuvable (ou film inconnu sur la machine) : arrêt et attente", nameOf(vehicle), tostring(zone))
        message(vehicle, "ERROR", "AD_autonomous_wrapFilmNoZone", tostring(zone))
        ADBaleCollect.stopAndWait(mode)
        return
    end
    plan.needsFill = true
    mode.baleStage = "refill"
    mode.baleTask = nil
    log("%s : plus de film (%s) : route vers la zone de recharge « %s » (%s), puis retour au champ %s", nameOf(vehicle), ADBaleWrapper.filmText(ctx.tool),
        tostring(plan.marker.name), table.concat(plan.settings.fillTypes or {}, "+"), tostring(ctx.fieldNum))
    mode:startRefill(plan, "back")
end

-- (hook AutonomousMode:handleRefillStage, fin de l'étape « load ») recharge du film finie : retour au champ, où
-- l'enrubannage reprend ; true = pris ici (plan d'une enrubanneuse)
function ADBaleCollect.afterRefill(mode)
    local plan = mode.refillPlan
    if plan == nil or plan.kind ~= "wrapper" or mode.baleStage ~= "refill" or mode.baleCtx == nil then
        return false
    end
    mode.refillStage = nil
    mode.refillPlan = nil
    mode.refillThen = nil
    mode.refillTask = nil
    local vehicle, ctx = mode.vehicle, mode.baleCtx
    local zone = plan.marker ~= nil and plan.marker.name or plan.refillName
    if not ADBaleWrapper.filmAvailable(ctx.tool) then
        log("%s : recharge du film à « %s » finie sans film (%s) : arrêt et attente", nameOf(vehicle), tostring(zone), ADBaleWrapper.filmText(ctx.tool))
        message(vehicle, "ERROR", "AD_autonomous_wrapFilmFailed", tostring(zone))
        ADBaleCollect.stopAndWait(mode)
        return true
    end
    log("%s : recharge du film faite à « %s » (%s)", nameOf(vehicle), tostring(zone), ADBaleWrapper.filmText(ctx.tool))
    ADBaleCollect.backToField(mode, "AD_autonomous_wrapFilmBack")
    return true
end

-- (15/11) retour au champ du ramassage (étape « toField », à l'arrivée : startCollect)
function ADBaleCollect.backToField(mode, msgKey)
    local vehicle, ctx = mode.vehicle, mode.baleCtx
    local fieldMarker = ctx.fieldMarker or vehicle.ad.stateModule:getFirstMarker()
    if fieldMarker == nil then
        log("%s : pas de point du champ pour le retour : arrêt et attente", nameOf(vehicle))
        ADBaleCollect.stopAndWait(mode)
        return
    end
    ctx.fieldMarker = fieldMarker
    mode.baleStage = "toField"
    mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, fieldMarker.id)
    if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_back", fieldMarker.name) end -- but affiché dans l'ATH, voir DriveGoal.lua
    vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
    log("%s : retour au champ « %s »", nameOf(vehicle), tostring(fieldMarker.name))
    message(vehicle, "INFO", msgKey, tostring(fieldMarker.name))
end

-- back = true : il reste des balles, retour au champ après le dépôt ; msgKey : message à la place de « pleine »
function ADBaleCollect.goDeposit(mode, back, msgKey)
    local vehicle, ctx = mode.vehicle, mode.baleCtx
    local deposit = ctx.settings.deposit ~= nil and ADGraphManager:getMapMarkerByName(ctx.settings.deposit) or nil
    if deposit == nil then
        log("%s : zone de dépôt « %s » introuvable : arrêt et attente", nameOf(vehicle), tostring(ctx.settings.deposit))
        message(vehicle, "ERROR", "AD_autonomous_baleLoaderTodo", ADAutonomousManager.toolLabel(ctx.tool), tostring(ctx.field))
        ADBaleCollect.stopAndWait(mode)
        return
    end
    local loaded = ADBaleLoaderManager.loadedCount(ctx.tool)
    mode.baleBack = back == true
    mode.baleStage = "toDeposit"
    mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, deposit.id)
    if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_bales", deposit.name) end -- but affiché dans l'ATH, voir DriveGoal.lua
    vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
    log("%s : %d balle(s) sur la remorque, dépôt à « %s »%s", nameOf(vehicle), loaded, tostring(deposit.name), back and ", puis retour au champ" or "")
    message(vehicle, "INFO", msgKey or (back and "AD_autonomous_balesFull" or "AD_autonomous_balesLast"), loaded, tostring(deposit.name))
end

-- 1er trajet vers le champ (départ du mode) avec une remorque à balles réglée attelée : comme le retour au champ
local function firstTrip(mode)
    local vehicle = mode.vehicle
    local sm = vehicle.ad.stateModule
    local first = sm:getFirstMarker()
    if mode.driveToDestinationTask == nil or vehicle.ad.taskModule:getActiveTask() ~= mode.driveToDestinationTask
        or first == nil or mode.destinationID ~= first.id or mode.refillStage ~= nil or mode.fetchStage ~= nil
        or mode.parkStage ~= nil or mode.dumpStage ~= nil or mode.fuelStage ~= nil then
        return false
    end
    local ok, ctx = FarmPilotCall(ADBaleCollect.makeContext, vehicle)
    if not ok or ctx == nil then
        return false
    end
    mode.baleCtx = ctx
    mode.baleStage = "toField"
    return true
end

-- (09/11) bouton >> (Continuer) : dépôt tout de suite avec les balles chargées, retour au champ s'il en reste.
-- Remorque vide : champ laissé, suite d'un champ fini (champ suivant, parking). true = bouton pris ici.
function ADBaleCollect.onContinue(mode)
    if mode.baleStage == nil and not firstTrip(mode) then
        return false
    end
    local vehicle, ctx, stage = mode.vehicle, mode.baleCtx, mode.baleStage
    if ctx == nil or ctx.tool == nil then
        return false
    end
    if ctx.kind == "wrapper" then
        return ADBaleCollect.onContinueWrap(mode)
    end
    local loaded = ADBaleLoaderManager.loadedCount(ctx.tool)
    if stage == "toDeposit" or stage == "unload" then
        log("%s : >> : déjà en route vers le dépôt", nameOf(vehicle))
        return true
    end
    if stage == "collect" and mode.baleTask ~= nil and mode.baleTask.result == nil then
        -- fin du ramassage après la balle en cours ; la suite (dépôt ou champ laissé) selon la remorque, voir handleStage
        if loaded > 0 then
            log("%s : >> : dépôt demandé avec %d balle(s), après la balle en cours", nameOf(vehicle), loaded)
        else
            log("%s : >> : aucune balle sur la remorque, champ %s laissé", nameOf(vehicle), tostring(ctx.fieldNum))
        end
        mode.baleTask.depositRequested = true
        return true
    end
    if stage == "toField" and loaded == 0 then
        log("%s : >> : aucune balle sur la remorque, champ %s laissé avant d'y aller", nameOf(vehicle), tostring(ctx.fieldNum))
        vehicle.ad.taskModule:abortCurrentTask()
        message(vehicle, "INFO", "AD_autonomous_balesContinueEmpty", tostring(ctx.fieldNum))
        ADBaleCollect.finishField(mode)
        return true
    end
    if stage == "toField" then
        -- balles restées sur la remorque au retour : demi-tour vers le dépôt
        log("%s : >> : %d balle(s) sur la remorque, dépôt tout de suite au lieu d'aller au champ", nameOf(vehicle), loaded)
        vehicle.ad.taskModule:abortCurrentTask()
        mode.driveToDestinationTask = nil
        ADBaleCollect.goDeposit(mode, true, "AD_autonomous_balesContinue")
        return true
    end
    return false
end

-- (15/11) >> avec l'enrubanneuse : au champ, fin après la balle en cours puis champ laissé ; en route vers le champ :
-- champ laissé ; pendant la recharge du film : le « Continuer » du plein (AutonomousMode:continue)
function ADBaleCollect.onContinueWrap(mode)
    local vehicle, ctx, stage = mode.vehicle, mode.baleCtx, mode.baleStage
    if stage == "collect" and mode.baleTask ~= nil and mode.baleTask.result == nil then
        log("%s : >> : enrubannage arrêté après la balle en cours, champ %s laissé", nameOf(vehicle), tostring(ctx.fieldNum))
        mode.baleTask.depositRequested = true
        return true
    end
    if stage == "toField" then
        log("%s : >> : champ %s laissé avant d'y enrubanner", nameOf(vehicle), tostring(ctx.fieldNum))
        vehicle.ad.taskModule:abortCurrentTask()
        message(vehicle, "INFO", "AD_autonomous_wrapContinue", tostring(ctx.fieldNum))
        ADBaleCollect.finishField(mode)
        return true
    end
    return false
end

-- (15/11) fin de la tâche de l'enrubanneuse
function ADBaleCollect.wrapDone(mode, task)
    local vehicle, ctx = mode.vehicle, mode.baleCtx
    local result = task ~= nil and task.result or "?"
    local f = tostring(ctx.fieldNum)
    if result == "noFilm" then
        ADBaleCollect.goRefill(mode)
    elseif result == "noBales" then
        log("%s : champ %s fini, plus de balle à enrubanner (%d enrubannée(s))", nameOf(vehicle), f, ctx.wrapped or 0)
        message(vehicle, "INFO", "AD_autonomous_wrapNone", f)
        ADBaleCollect.finishField(mode)
    elseif result == "continue" then
        message(vehicle, "INFO", "AD_autonomous_wrapContinue", f)
        ADBaleCollect.finishField(mode)
    else
        local key = ({ noWork = "AD_autonomous_wrapNoWork", noWrap = "AD_autonomous_wrapStuck" })[result] or "AD_autonomous_wrapDetached"
        log("%s : enrubannage arrêté (%s) : arrêt et attente", nameOf(vehicle), tostring(result))
        message(vehicle, "ERROR", key)
        ADBaleCollect.stopAndWait(mode)
    end
end

-- (hook AutonomousMode:handleFinishedTask) fin d'une étape
function ADBaleCollect.handleStage(mode)
    local vehicle = mode.vehicle
    if vehicle.ad.isStoppingWithError then
        ADBaleCollect.reset(mode)
        mode.driveToDestinationTask = nil
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
        return
    end
    local ctx = mode.baleCtx
    local stage = mode.baleStage
    local task = mode.baleTask
    mode.baleTask = nil
    if stage == "collect" and ctx ~= nil and ctx.kind == "wrapper" then
        ADBaleCollect.wrapDone(mode, task)
    elseif stage == "collect" then
        local result = task ~= nil and task.result or "?"
        local loaded = ADBaleLoaderManager.loadedCount(ctx.tool)
        if result == "continue" then
            -- >> : dépôt tout de suite, retour s'il reste des balles ; remorque vide : champ laissé
            local list = loaded > 0 and ADBaleLoaderManager.findBales(ctx.tool, ctx.fieldNums, ctx.settings.wrap, task ~= nil and task.left or nil) or {}
            if loaded > 0 then
                ADBaleCollect.goDeposit(mode, #list > 0, "AD_autonomous_balesContinue")
            else
                -- remorque vide : champ laissé, suite d'un champ fini
                message(vehicle, "INFO", "AD_autonomous_balesContinueEmpty", tostring(ctx.fieldNum))
                ADBaleCollect.finishField(mode)
            end
        elseif result == "full" or (result == "noBales" and loaded > 0) then
            local back = false
            if result == "full" then
                local list = ADBaleLoaderManager.findBales(ctx.tool, ctx.fieldNums, ctx.settings.wrap, task ~= nil and task.left or nil)
                back = #list > 0
            end
            ADBaleCollect.goDeposit(mode, back)
        elseif result == "noBales" then
            log("%s : champ %s fini, plus de balle à ramasser", nameOf(vehicle), tostring(ctx.fieldNum))
            message(vehicle, "INFO", "AD_autonomous_balesNone", tostring(ctx.fieldNum))
            ADBaleCollect.finishField(mode)
        else
            local key = result == "noWork" and "AD_autonomous_balesNoWork" or "AD_autonomous_balesNoLoader"
            log("%s : ramassage arrêté (%s) : arrêt et attente", nameOf(vehicle), tostring(result))
            message(vehicle, "ERROR", key)
            ADBaleCollect.stopAndWait(mode)
        end
    elseif stage == "toDeposit" then
        mode.driveToDestinationTask = nil
        mode.baleStage = "unload"
        mode.baleTask = ADBaleUnloadTask:new(vehicle, ctx.tool)
        vehicle.ad.taskModule:addTask(mode.baleTask)
    elseif stage == "unload" then
        local result = task ~= nil and task.result or "?"
        local deposit = tostring(ctx.settings.deposit)
        if result ~= "ok" then
            log("%s : déchargement à « %s » pas fait (%s) : arrêt et attente", nameOf(vehicle), deposit, tostring(result))
            message(vehicle, "ERROR", "AD_autonomous_balesUnloadFailed", deposit)
            ADBaleCollect.stopAndWait(mode)
            return
        end
        log("%s : %d balle(s) déchargée(s) à « %s »", nameOf(vehicle), task.unloaded or 0, deposit)
        if mode.baleBack and ctx.fieldMarker ~= nil then
            mode.baleStage = "toField"
            mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, ctx.fieldMarker.id)
            if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_back", ctx.fieldMarker.name) end -- but affiché dans l'ATH, voir DriveGoal.lua
            vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
            message(vehicle, "INFO", "AD_autonomous_balesBack", tostring(ctx.fieldMarker.name))
        else
            ADBaleCollect.finishField(mode)
        end
    elseif stage == "toField" then
        mode.driveToDestinationTask = nil
        ADBaleCollect.startCollect(mode, false)
    else
        ADBaleCollect.stopAndWait(mode)
    end
end

function ADBaleCollect.stopAndWait(mode)
    local vehicle = mode.vehicle
    ADBaleCollect.reset(mode)
    mode.driveToDestinationTask = nil
    vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
end

-- champ fini : la suite (champ suivant / parking) une fois FarmPilot arrêté, voir afterStop
function ADBaleCollect.finishField(mode)
    local vehicle = mode.vehicle
    ADBaleCollect.reset(mode)
    mode.driveToDestinationTask = nil
    vehicle.ad.fpBaleContinue = true
    vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
end

-- ------------------------------------------------------------------------------------------------------------
-- Hook AutoDrive:stopAutoDrive : après le champ, la suite habituelle de fin de champ (à l'image suivante)
-- ------------------------------------------------------------------------------------------------------------
function ADBaleCollect.continueAfterField(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.stateModule:isActive() then
        return
    end
    local ok, err = FarmPilotCall(AutoDrive.onCpFinished, vehicle)
    if not ok then
        log("ERREUR suite après le ramassage : %s", tostring(err))
    end
end

function ADBaleCollect.afterStop(vehicle)
    if vehicle == nil or vehicle.ad == nil or not vehicle.ad.fpBaleContinue then
        return
    end
    vehicle.ad.fpBaleContinue = nil
    if vehicle.ad.isStoppingWithError then
        return
    end
    -- à l'image suivante : FarmPilot doit être complètement arrêté avant de repartir
    local mission = g_currentMission
    if mission ~= nil and mission.addUpdateable ~= nil and mission.removeUpdateable ~= nil then
        local once = {}
        once.update = function(self, dt)
            mission:removeUpdateable(self)
            ADBaleCollect.continueAfterField(vehicle)
        end
        mission:addUpdateable(once)
    else
        ADBaleCollect.continueAfterField(vehicle)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Tâche : déchargement de la remorque à balles à la zone de dépôt
-- ------------------------------------------------------------------------------------------------------------
-- Même suite que le mode « Décharger à » d'AutoDrive (UnloadAtDestinationTask:isBaleUnloadFinished) : arrêt,
-- déchargement automatique du jeu, au bout de WAIT_PUSHER ms quelques mètres en avant pour dégager la pile, puis
-- remorque remise en position transport.
ADBaleUnloadTask = ADInheritsFrom(AbstractTask)

ADBaleUnloadTask.STOP_TIMEOUT = 15000       -- ms pour s'arrêter
ADBaleUnloadTask.START_TIMEOUT = 15000      -- ms pour que le jeu accepte de décharger (bras au repos)
ADBaleUnloadTask.WAIT_PUSHER = 20000        -- ms avant d'avancer (pousseur, plateau)
ADBaleUnloadTask.FORWARD_DISTANCE = 5       -- m en avant après le dépôt
ADBaleUnloadTask.UNLOAD_TIMEOUT = 120000    -- ms au plus

function ADBaleUnloadTask:new(vehicle, loader)
    local o = ADBaleUnloadTask:create()
    o.taskType = "ADBaleUnloadTask"
    o.vehicle = vehicle
    o.loader = loader
    o.result = nil
    return o
end

function ADBaleUnloadTask:setUp()
    self.timer = 0
    self.requested = false
    self.requestTime = nil
    self.forwardTarget = nil
    self.resetStep = 0
    self.startCount = ADBaleLoaderManager.loadedCount(self.loader)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

function ADBaleUnloadTask:holdVehicle(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
end

function ADBaleUnloadTask:update(dt)
    self.timer = self.timer + dt
    local loader = self.loader
    if loader == nil or loader.isDeleted then
        self:holdVehicle(dt)
        self:finish("remorque disparue")
        return
    end
    if not self.requested then
        self:holdVehicle(dt)
        if ADBaleLoaderManager.loadedCount(loader) == 0 then
            self:finish("ok")
            return
        end
        local stopped = math.abs(self.vehicle.lastSpeedReal or 0) < 0.0015 or self.timer >= ADBaleUnloadTask.STOP_TIMEOUT
        if stopped and not ADBaleLoaderManager.isBusy(loader) and not ADBaleLoaderManager.isUnloading(loader) and loader.startAutomaticBaleUnloading ~= nil then
            local ok, err = FarmPilotCall(loader.startAutomaticBaleUnloading, loader)
            if not ok then
                self:finish("erreur du jeu : " .. tostring(err))
                return
            end
            self.requested = true
            self.requestTime = self.timer
            ADBaleLoaderManager.log("%s : déchargement de %d balle(s)", tostring(self.vehicle.ad.stateModule:getName()), self.startCount)
        elseif self.timer >= ADBaleUnloadTask.STOP_TIMEOUT + ADBaleUnloadTask.START_TIMEOUT then
            self:finish("le jeu refuse de décharger")
        end
        return
    end
    if self.timer >= ADBaleUnloadTask.UNLOAD_TIMEOUT then
        self:holdVehicle(dt)
        self:finish(ADBaleLoaderManager.loadedCount(loader) == 0 and "ok" or "délai dépassé")
        return
    end
    local unloading = ADBaleLoaderManager.isUnloading(loader)
    if self.forwardTarget == nil then
        local x, y, z = AutoDrive.localToWorld(self.vehicle, 0, 0, ADBaleUnloadTask.FORWARD_DISTANCE)
        self.forwardTarget = { x = x, y = y, z = z }
    end
    if self.timer - self.requestTime >= ADBaleUnloadTask.WAIT_PUSHER then
        local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
        if MathUtil.vector2Length(x - self.forwardTarget.x, z - self.forwardTarget.z) >= 1 then
            self.vehicle.ad.specialDrivingModule:driveToPoint(dt, self.forwardTarget, 1, false, 0.5, 1)
            return
        end
    end
    if not unloading then
        -- comme AutoDrive : position travail puis transport, pour remettre la remorque d'aplomb
        local spec = ADBaleLoaderManager.spec(loader)
        if spec ~= nil and BaleLoader ~= nil and loader.doStateChange ~= nil then
            if not spec.isInWorkPosition and self.resetStep == 0 then
                FarmPilotCall(loader.doStateChange, loader, BaleLoader.CHANGE_BUTTON_WORK_TRANSPORT)
                self.resetStep = 1
                self:holdVehicle(dt)
                return
            end
            if spec.isInWorkPosition then
                FarmPilotCall(loader.doStateChange, loader, BaleLoader.CHANGE_BUTTON_WORK_TRANSPORT)
            end
        end
        self:holdVehicle(dt)
        local left = ADBaleLoaderManager.loadedCount(loader)
        self.unloaded = math.max(0, self.startCount - left)
        self:finish(left == 0 and "ok" or string.format("%d balle(s) restée(s) sur la remorque", left))
        return
    end
    self:holdVehicle(dt)
end

function ADBaleUnloadTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self:finished()
end

function ADBaleUnloadTask:abort()
end

function ADBaleUnloadTask:finished()
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADBaleUnloadTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_baleUnload;"
end
