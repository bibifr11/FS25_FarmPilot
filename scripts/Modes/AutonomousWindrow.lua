-- ============================================================================================================
-- FarmPilot : AutonomousWindrow.lua
-- Mode Autonome, presse à balles : FarmPilot presse les andains lui-même, sans Courseplay (15/11).
--
-- Règle (15/11) :
-- - Presse attelée (ou automotrice) en mode Autonome = jamais Courseplay : ni choix de parcours (AutonomousManager.lua),
--   ni lecture des parcours pendant le trajet, ni démarrage, ni « Courseplay au dernier point » après la recharge.
--   Moissonneuse avec une presse (coton) : pas concernée (ADBalerManager.windrowBaler).
-- - Arrivée au champ : recherche des andains sur le champ et son groupe AutoSwitch (ADWindrowScan, par morceaux,
--   SCAN_BUDGET lectures du sol par image, tracteur arrêté : ADWindrowScanTask), puis la tâche de pressage (ADWindrowBaleTask),
--   presse mise au travail (ADBalerControl.prepare).
-- - Fin de la tâche :
--   « done » (plus d'andain) : s'il en reste quand même (ADWindrowScan.anyLeft), une nouvelle recherche, une fois ;
--   sinon presse repliée pour la route, puis la suite d'un champ fini (champ suivant, sinon garage : finishField) ;
--   « refill » (plus de ficelle / filet) : presse repliée, trajet de recharge existant (ADBalerManager.preparePlan
--   « back », AutonomousMode:startRefill), retour au champ, puis nouvelle recherche et NOUVELLE tâche (afterRefill) ;
--   « blocked » (rien de faisable) ou autre : presse arrêtée, message, arrêt et attente ;
--   « detached » (presse dételée) : message, arrêt et attente.
-- - (15/11) Avant la route (champ fini, recharge) : balle finie encore dans la presse = tracteur arrêté le temps que
--   la presse la pose (ADWindrowEmptyTask, ADBalerControl.emptyStep, 30 s au plus), sinon le jeu refuse le repli et
--   AutoDrive attend sans fin ; puis la suite.
-- - Aucun andain à la première arrivée : message « noWindrow », arrêt et attente, comme avant. Après une recharge ou
--   une reprise (le pressage avait commencé) : plus d'andain = champ fini.
-- - Arrêt pendant le pressage (bouton Marche/Arrêt, erreur) : la presse est arrêtée, pick-up relevé (abort de la tâche).
-- - (17/11) Carburant pendant le pressage (règle 9 : jamais de plein pendant une tâche, sauf sous le seuil) : lecture
--   toutes les FUEL_CHECK ms ; sous le réglage du tracteur « Plein pendant le travail sous » (ADFuelRun.workThreshold,
--   5 % par défaut, Jamais possible) : tâche finie « fuel », presse repliée (balle finie posée d'abord), plein à la
--   pompe la plus proche (ADFuelRun.start « back »), retour au champ, puis nouvelle recherche et NOUVELLE tâche
--   (afterFuel), jamais Courseplay. Plein incomplet au retour (pompe sans AdBlue...) : pas d'autre plein sur ce champ.
-- - Reprise (partie rechargée, bouton Marche/Arrêt, relance d'AutoDrive) : étape « windrow » (AutonomousResumeStage.lua) ;
--   on cherche de nouveau les andains sur place (ce qui est pressé a disparu) et la tâche repart. Pendant le trajet de
--   recharge : étape « refill » existante, puis afterRefill au retour.
-- - Journal : « [FarmPilot Presse] … » (arrivée, andains trouvés, fin de tâche et suite, recharge, retour).
--
-- Branché par une ligne dans : AutonomousMode.lua (reset ; handleFinishedTask : étapes et arrivée au champ ;
-- handleRefillStage : afterRefill au retour au champ ; departToField : pas de lecture des parcours Courseplay),
-- AutonomousResumeStage.lua (étape « windrow »), AutonomousBalerRefill.lua (journal du retour). Chargé par register.lua
-- après WindrowBaleTask.lua.
-- ============================================================================================================

ADWindrowMode = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADWindrowMode.SCAN_BUDGET = 300         -- lectures du sol par image pendant la recherche des andains (petits PC ; ADWindrowScan.BUDGET)
ADWindrowMode.SCAN_TIMEOUT = 180000     -- ms au plus pour la recherche : ce qui est trouvé est pris
ADWindrowMode.SCAN_OPTS = { step = 1, minLength = 5, gap = 3, edge = 10 } -- voir WindrowScan.lua
ADWindrowMode.RESCAN_MAX = 1            -- tâche finie « done » mais il reste des andains : nouvelles recherches au plus
ADWindrowMode.FUEL_CHECK = 2000         -- ms entre deux lectures du carburant pendant le pressage

local function log(fmt, ...)
    if ADBalerManager ~= nil and ADBalerManager.log ~= nil then
        ADBalerManager.log(fmt, ...)
        return
    end
    local ok, s = FarmPilotCall(string.format, fmt, ...)
    print("[FarmPilot Presse] " .. (ok and s or tostring(fmt)))
end

local function nameOf(vehicle)
    return tostring(vehicle.ad.stateModule:getName())
end

local function message(vehicle, kind, key, ...)
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes[kind], kind == "ERROR" and 15000 or 8000, key, ...)
end

local function toolName(baler)
    local ok, n = FarmPilotCall(ADAutonomousManager.toolLabel, baler)
    return ok and tostring(n) or "?"
end

local function percent(level)
    if level == nil then
        return "?"
    end
    return string.format("%d %%", math.floor(level * 100 + 0.5))
end

-- ------------------------------------------------------------------------------------------------------------
-- Remise à zéro (hook AutonomousMode:reset)
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowMode.reset(mode)
    mode.windrowStage = nil   -- « scan » (recherche des andains), « bale » (pressage), « empty » (balle posée avant la route) ; pendant la recharge : étapes refillStage
    mode.windrowCtx = nil
    mode.windrowTask = nil
    mode.windrowAfterEmpty = nil -- (15/11) après « empty » : « finish » (champ fini), { refill = plan } ou { fuel = true }
end

-- ------------------------------------------------------------------------------------------------------------
-- Presse, champ
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowMode.balerOf(vehicle)
    if vehicle == nil or ADBalerManager == nil or ADBalerManager.windrowBaler == nil then
        return nil
    end
    local ok, baler = FarmPilotCall(ADBalerManager.windrowBaler, vehicle)
    return ok and baler or nil
end

function ADWindrowMode.isBaler(vehicle)
    return ADWindrowMode.balerOf(vehicle) ~= nil
end

-- numéros du champ et de son groupe AutoSwitch : { [n] = true } (même forme que BaleCollectTask), et le texte « 52 + 60 »
function ADWindrowMode.fieldNumbers(fieldNum)
    local set, list = {}, {}
    if fieldNum == nil then
        return set, nil
    end
    local okG, g = FarmPilotCall(ADAutonomousManager.groupOf, fieldNum)
    for _, n in ipairs(okG and g ~= nil and g.members or { fieldNum }) do
        local k = tonumber(n) or n
        if not set[k] then
            set[k] = true
            list[#list + 1] = tostring(n)
        end
    end
    local k = tonumber(fieldNum) or fieldNum
    if not set[k] then
        set[k] = true
        list[#list + 1] = tostring(fieldNum)
    end
    return set, table.concat(list, " + ")
end

-- { baler, fillTypes, fieldNum, fieldNums, fieldText, fieldMarker, started, rescans } ou nil (pas de presse)
function ADWindrowMode.makeContext(vehicle)
    local baler = ADWindrowMode.balerOf(vehicle)
    if baler == nil then
        return nil
    end
    local ctx = { baler = baler, fillTypes = ADBalerManager.windrowTypes(baler), started = false, rescans = 0, prepared = false }
    local f = ADAutonomousManager.nearField(vehicle)
    ctx.fieldNum = f ~= nil and ADAutonomousManager.fieldNumber(f) or nil
    ctx.fieldNums, ctx.fieldText = ADWindrowMode.fieldNumbers(ctx.fieldNum)
    ctx.fieldText = ctx.fieldText or tostring(ctx.fieldNum or "?")
    ctx.fieldMarker = vehicle.ad.stateModule:getFirstMarker()
    return ctx
end

local function typesText(types)
    local names = {}
    for _, ft in ipairs(types or {}) do
        local n = g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeNameByIndex ~= nil and g_fillTypeManager:getFillTypeNameByIndex(ft) or nil
        names[#names + 1] = tostring(n or ft)
    end
    return #names > 0 and table.concat(names, ", ") or "aucun produit"
end

-- ------------------------------------------------------------------------------------------------------------
-- Arrivée au champ (hook AutonomousMode:handleFinishedTask) : true si la presse prend la main
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowMode.onArrival(mode)
    local vehicle = mode.vehicle
    local ok, ctx = FarmPilotCall(ADWindrowMode.makeContext, vehicle)
    if not ok then
        log("ERREUR presse à l'arrivée au champ : %s", tostring(ctx))
        return false
    end
    if ctx == nil then
        return false
    end
    mode.windrowCtx = ctx
    if ctx.fieldNum == nil then
        log("%s : arrivée à « %s » avec la presse « %s », pas de champ ici : arrêt et attente", nameOf(vehicle),
            tostring(ctx.fieldMarker ~= nil and ctx.fieldMarker.name or "?"), toolName(ctx.baler))
        message(vehicle, "ERROR", "AD_autonomous_noField")
        ADWindrowMode.stopAndWait(mode)
        return true
    end
    log("%s : arrivée au champ %s avec la presse « %s » (sans Courseplay) : recherche des andains (%s)", nameOf(vehicle), ctx.fieldText,
        toolName(ctx.baler), typesText(ctx.fillTypes))
    ADWindrowMode.startScan(mode)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Recherche des andains
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowMode.scanOpts()
    local o = {}
    for k, v in pairs(ADWindrowMode.SCAN_OPTS) do
        o[k] = v
    end
    return o
end

function ADWindrowMode.startScan(mode)
    local vehicle, ctx = mode.vehicle, mode.windrowCtx
    if ADWindrowScan == nil or ADWindrowScan.newScan == nil then
        log("%s : recherche des andains introuvable (WindrowScan.lua) : arrêt et attente", nameOf(vehicle))
        message(vehicle, "ERROR", "AD_autonomous_noWindrow", ctx.fieldText)
        ADWindrowMode.stopAndWait(mode)
        return
    end
    local ok, scan = FarmPilotCall(ADWindrowScan.newScan, ctx.fieldNums, ctx.fillTypes, ADWindrowMode.scanOpts())
    if not ok or scan == nil then
        log("ERREUR recherche des andains du champ %s : %s", ctx.fieldText, tostring(scan))
        message(vehicle, "ERROR", "AD_autonomous_noWindrow", ctx.fieldText)
        ADWindrowMode.stopAndWait(mode)
        return
    end
    ctx.scan = scan
    mode.windrowStage = "scan"
    mode.windrowTask = ADWindrowScanTask:new(vehicle, scan, ctx)
    vehicle.ad.taskModule:addTask(mode.windrowTask)
end

local function windrowsText(windrows)
    local length, liters = 0, 0
    for _, w in ipairs(windrows) do
        length = length + (tonumber(w.length) or 0)
        liters = liters + (tonumber(w.liters) or 0)
    end
    return string.format("%d andain(s), %.0f m, %.0f L", #windrows, length, liters)
end

function ADWindrowMode.afterScan(mode, task)
    local vehicle, ctx = mode.vehicle, mode.windrowCtx
    local scan = ctx.scan
    local windrows = scan ~= nil and type(scan.windrows) == "table" and scan.windrows or {}
    local result = task ~= nil and task.result or "?"
    if result ~= "ok" then
        log("%s : recherche des andains du champ %s arrêtée (%s) : %d trouvé(s) jusque-là", nameOf(vehicle), ctx.fieldText,
            result == "timeout" and string.format("plus de %.0f s", ADWindrowMode.SCAN_TIMEOUT / 1000) or tostring(result), #windrows)
    end
    if #windrows == 0 then
        if ctx.started then
            log("%s : champ %s : plus d'andain à presser, champ fini", nameOf(vehicle), ctx.fieldText)
            message(vehicle, "INFO", "AD_autonomous_windrowDone", ctx.fieldText)
            ADWindrowMode.finishField(mode)
        else
            log("%s : champ %s : aucun andain (%s) : arrêt et attente", nameOf(vehicle), ctx.fieldText, typesText(ctx.fillTypes))
            message(vehicle, "ERROR", "AD_autonomous_noWindrow", ctx.fieldText)
            ADWindrowMode.stopAndWait(mode)
        end
        return
    end
    log("%s : champ %s : %s trouvé(s) en %.1f s", nameOf(vehicle), ctx.fieldText, windrowsText(windrows), (task ~= nil and task.timer or 0) / 1000)
    if not ctx.started then
        message(vehicle, "INFO", "AD_autonomous_windrowStart", ctx.fieldText, #windrows)
    end
    ADWindrowMode.startBale(mode, windrows)
end

-- ------------------------------------------------------------------------------------------------------------
-- Pressage
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowMode.startBale(mode, windrows)
    local vehicle, ctx = mode.vehicle, mode.windrowCtx
    if ADWindrowBaleTask == nil or ADWindrowBaleTask.new == nil then
        log("%s : tâche de pressage introuvable (WindrowBaleTask.lua) : arrêt et attente", nameOf(vehicle))
        message(vehicle, "ERROR", "AD_autonomous_windrowBlocked", ctx.fieldText)
        ADWindrowMode.stopAndWait(mode)
        return
    end
    local okP, ready = FarmPilotCall(ADBalerControl.prepare, ctx.baler)
    if not okP then
        log("ERREUR mise au travail de la presse : %s", tostring(ready))
    end
    ctx.prepared = true
    ctx.started = true
    local taskCtx = { fieldNums = ctx.fieldNums, fillTypes = ctx.fillTypes, baler = ctx.baler, windrows = windrows, scan = ctx.scan }
    local ok, task = FarmPilotCall(ADWindrowBaleTask.new, ADWindrowBaleTask, vehicle, taskCtx)
    if not ok or task == nil then
        log("ERREUR tâche de pressage : %s", tostring(task))
        message(vehicle, "ERROR", "AD_autonomous_windrowBlocked", ctx.fieldText)
        ADWindrowMode.stopAndWait(mode)
        return
    end
    -- arrêt pendant le pressage (bouton, erreur, relance) : presse arrêtée et pick-up relevé
    local baseAbort = task.abort
    task.abort = function(t, ...)
        if baseAbort ~= nil then
            baseAbort(t, ...)
        end
        if ctx.baler ~= nil then
            log("%s : pressage interrompu : presse arrêtée", nameOf(vehicle))
            FarmPilotCall(ADBalerControl.release, ctx.baler, false)
        end
    end
    ADWindrowMode.watchFuel(mode, task)
    mode.windrowStage = "bale"
    mode.windrowTask = task
    log("%s : champ %s : la presse « %s » part sur les andains (%s, presse %s)", nameOf(vehicle), ctx.fieldText, toolName(ctx.baler),
        windrowsText(windrows), okP and ready and "prête" or "en préparation")
    vehicle.ad.taskModule:addTask(task)
end

local function progressText(task)
    if task == nil or task.getProgress == nil then
        return "?"
    end
    local ok, p = FarmPilotCall(task.getProgress, task)
    if not ok or type(p) ~= "table" then
        return "?"
    end
    return string.format("%s / %s andain(s)", tostring(p.done or "?"), tostring(p.total or "?"))
end

function ADWindrowMode.afterBale(mode, task)
    local vehicle, ctx = mode.vehicle, mode.windrowCtx
    local result = task ~= nil and task.result or nil
    log("%s : pressage au champ %s fini : « %s » (%s faits)", nameOf(vehicle), ctx.fieldText, tostring(result), progressText(task))
    if result == "done" then
        if ADWindrowScan ~= nil and ADWindrowScan.anyLeft ~= nil and ctx.rescans < ADWindrowMode.RESCAN_MAX then
            local okL, left = FarmPilotCall(ADWindrowScan.anyLeft, ctx.fieldNums, ctx.fillTypes)
            if okL and left == true then
                ctx.rescans = ctx.rescans + 1
                log("%s : champ %s : il reste des andains au sol : nouvelle recherche", nameOf(vehicle), ctx.fieldText)
                ADWindrowMode.startScan(mode)
                return
            end
        end
        message(vehicle, "INFO", "AD_autonomous_windrowDone", ctx.fieldText)
        ADWindrowMode.finishField(mode)
    elseif result == "refill" then
        ADWindrowMode.goRefill(mode)
    elseif result == "fuel" then
        ADWindrowMode.goFuel(mode)
    elseif result == "detached" then
        log("%s : presse dételée : arrêt et attente", nameOf(vehicle))
        message(vehicle, "ERROR", "AD_autonomous_windrowDetached")
        ADWindrowMode.stopAndWait(mode)
    else
        log("%s : pressage arrêté (%s) : arrêt et attente", nameOf(vehicle), tostring(result))
        message(vehicle, "ERROR", "AD_autonomous_windrowBlocked", ctx.fieldText)
        ADWindrowMode.stopAndWait(mode)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Recharge de la ficelle / du filet : trajet existant (AutonomousMode:startRefill), puis retour (afterRefill)
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowMode.goRefill(mode)
    local vehicle, ctx = mode.vehicle, mode.windrowCtx
    local plan = ADBalerManager.preparePlan(vehicle, "back")
    local info = ADBalerManager.consumable(ctx.baler)
    if plan == nil or plan.marker == nil then
        log("%s : plus de ficelle / filet (%s) et zone de recharge introuvable : arrêt et attente", nameOf(vehicle), ADBalerManager.levelText(info))
        message(vehicle, "ERROR", "AD_autonomous_windrowNoRefill")
        ADWindrowMode.stopAndWait(mode)
        return
    end
    if not plan.needsFill then
        log("%s : la tâche dit « plus de ficelle / filet » mais la presse est pleine (%s) : arrêt et attente", nameOf(vehicle), ADBalerManager.levelText(info))
        message(vehicle, "ERROR", "AD_autonomous_windrowBlocked", ctx.fieldText)
        ADWindrowMode.stopAndWait(mode)
        return
    end
    FarmPilotCall(ADBalerControl.release, ctx.baler, true)
    ctx.prepared = false
    log("%s : plus de ficelle / filet au champ %s (%s) : presse repliée, recharge à « %s », puis retour et nouvelle tâche", nameOf(vehicle),
        ctx.fieldText, ADBalerManager.levelText(info), tostring(plan.marker.name))
    if ADWindrowMode.waitEmpty(mode, ctx.baler, { refill = plan }) then
        return
    end
    ADWindrowMode.refillGo(mode, plan)
end

function ADWindrowMode.refillGo(mode, plan)
    mode.windrowStage = nil -- la recharge passe par les étapes du plein (refillStage), puis afterRefill au retour
    mode.windrowTask = nil
    mode.windrowAfterEmpty = nil
    mode:startRefill(plan, "back")
end

-- (15/11) balle finie encore dans la presse avant la route : tracteur arrêté le temps qu'elle la pose (ADWindrowEmptyTask),
-- puis la suite (after : « finish » ou { refill = plan }) ; false = rien à poser, la suite tout de suite
function ADWindrowMode.waitEmpty(mode, baler, after)
    if baler == nil or ADBalerControl.isEmptying == nil then
        return false
    end
    local okE, emptying = FarmPilotCall(ADBalerControl.isEmptying, baler)
    if not okE or emptying ~= true then
        return false
    end
    log("%s : balle finie encore dans la presse « %s » : arrêt le temps qu'elle la pose, puis %s", nameOf(mode.vehicle), toolName(baler),
        after == "finish" and "la suite du champ fini" or (type(after) == "table" and after.fuel and "le plein de carburant") or "la recharge")
    mode.windrowStage = "empty"
    mode.windrowAfterEmpty = after
    mode.windrowTask = ADWindrowEmptyTask:new(mode.vehicle, baler)
    mode.vehicle.ad.taskModule:addTask(mode.windrowTask)
    return true
end

-- (hook AutonomousMode:handleRefillStage, fin de l'étape « back ») revenu au champ après la recharge : nouvelle
-- recherche des andains et nouvelle tâche, jamais Courseplay ; true = pris ici (presse attelée)
function ADWindrowMode.afterRefill(mode)
    return ADWindrowMode.backToWork(mode, "refill")
end

-- (17/11, hook ADFuelRun.handleStage, fin de l'étape « back ») revenu au champ après le plein de carburant : comme
-- après la recharge ; true = pris ici (presse attelée)
function ADWindrowMode.afterFuel(mode)
    return ADWindrowMode.backToWork(mode, "fuel")
end

function ADWindrowMode.backToWork(mode, why)
    local vehicle = mode.vehicle
    local what = why == "fuel" and "du plein de carburant" or "de la recharge"
    local ok, ctx = FarmPilotCall(ADWindrowMode.makeContext, vehicle)
    if not ok then
        log("ERREUR presse au retour %s : %s", what, tostring(ctx))
        return false
    end
    if ctx == nil then
        return false
    end
    ctx.started = true
    mode.windrowCtx = ctx
    if ctx.fieldNum == nil then
        log("%s : de retour %s, pas de champ ici : arrêt et attente", nameOf(vehicle), what)
        message(vehicle, "ERROR", "AD_autonomous_noField")
        ADWindrowMode.stopAndWait(mode)
        return true
    end
    local state
    if why == "fuel" then
        local level = ADFuelRun ~= nil and ADFuelRun.fuelLevel ~= nil and ADFuelRun.fuelLevel(vehicle) or nil
        local low = ADWindrowMode.fuelThreshold(vehicle)
        state = "carburant " .. percent(level)
        if level ~= nil and low ~= nil and level < low then
            -- pompe sans AdBlue, plus d'argent... : pas d'aller-retour sans fin, le pressage continue sans autre plein ici
            ctx.fuelSkip = true
            state = state .. ", plein incomplet : pas d'autre plein sur ce champ"
        end
    else
        state = ADBalerManager.levelText(ADBalerManager.consumable(ctx.baler))
    end
    log("%s : de retour au champ %s après %s (%s) : nouvelle recherche des andains, puis nouvelle tâche (sans Courseplay)", nameOf(vehicle),
        ctx.fieldText, why == "fuel" and "le plein de carburant" or "la recharge", state)
    ADWindrowMode.startScan(mode)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- (17/11) Carburant pendant le pressage : plein seulement sous le seuil du tracteur, puis retour et nouvelle tâche
-- ------------------------------------------------------------------------------------------------------------
-- seuil du réglage du tracteur (0 à 1) ; nil = Jamais
function ADWindrowMode.fuelThreshold(vehicle)
    if ADFuelRun == nil then
        return nil
    end
    if ADFuelRun.workThreshold == nil then
        return ADFuelRun.WORK_LOW or 0.05
    end
    local ok, low = FarmPilotCall(ADFuelRun.workThreshold, vehicle)
    if not ok then
        return ADFuelRun.WORK_LOW or 0.05
    end
    return low
end

-- true = plein à faire maintenant (sous le seuil) ; au-dessus mais bas (sous FUEL_LOW) : noté une fois, plein à la fin du champ
function ADWindrowMode.fuelLow(mode)
    local vehicle, ctx = mode.vehicle, mode.windrowCtx
    if ctx == nil or ctx.fuelSkip or ADFuelRun == nil or ADFuelRun.fuelLevel == nil then
        return false
    end
    local okL, level = FarmPilotCall(ADFuelRun.fuelLevel, vehicle)
    if not okL or type(level) ~= "number" then
        return false
    end
    local low = ADWindrowMode.fuelThreshold(vehicle)
    if low ~= nil and level < low then
        log("%s : champ %s : carburant à %s (seuil du tracteur %s) : arrêt du pressage pour le plein", nameOf(vehicle), ctx.fieldText,
            percent(level), percent(low))
        return true
    end
    if level < (ADFuelRun.FUEL_LOW or 0.20) and not ctx.fuelNoted then
        ctx.fuelNoted = true
        log("%s : champ %s : carburant à %s : pas de plein pendant le pressage (%s), plein à la fin du champ s'il y a un champ suivant",
            nameOf(vehicle), ctx.fieldText, percent(level), low ~= nil and ("seulement sous " .. percent(low)) or "réglage du tracteur : Jamais")
    end
    return false
end

-- lecture du carburant pendant la tâche de pressage (sa fonction update enveloppée) : sous le seuil, fin « fuel »
function ADWindrowMode.watchFuel(mode, task)
    local baseUpdate = task.update
    local timer = 0
    task.update = function(t, dt, ...)
        if t.result == nil then
            timer = timer + (dt or 0)
            if timer >= ADWindrowMode.FUEL_CHECK then
                timer = 0
                local ok, low = FarmPilotCall(ADWindrowMode.fuelLow, mode)
                if ok and low == true then
                    if t.holdVehicle ~= nil then
                        FarmPilotCall(t.holdVehicle, t, dt)
                    end
                    t:finish("fuel")
                    return
                end
            end
        end
        return baseUpdate(t, dt, ...)
    end
end

-- tâche finie « fuel » : presse repliée pour la route (balle finie posée d'abord), plein, retour (afterFuel)
function ADWindrowMode.goFuel(mode)
    local vehicle, ctx = mode.vehicle, mode.windrowCtx
    FarmPilotCall(ADBalerControl.release, ctx.baler, true)
    ctx.prepared = false
    log("%s : carburant bas au champ %s : presse repliée, plein à la pompe la plus proche, puis retour et nouvelle tâche", nameOf(vehicle),
        ctx.fieldText)
    if ADWindrowMode.waitEmpty(mode, ctx.baler, { fuel = true }) then
        return
    end
    ADWindrowMode.fuelGo(mode)
end

function ADWindrowMode.fuelGo(mode)
    local vehicle, ctx = mode.vehicle, mode.windrowCtx
    local fieldText = ctx ~= nil and ctx.fieldText or "?"
    mode.windrowStage = nil -- le plein passe par les étapes de ADFuelRun (fuelStage), puis afterFuel au retour
    mode.windrowTask = nil
    mode.windrowAfterEmpty = nil
    local level = ADFuelRun ~= nil and ADFuelRun.fuelLevel ~= nil and ADFuelRun.fuelLevel(vehicle) or nil
    local why = string.format("presse au champ %s, carburant à %s", fieldText, percent(level))
    local ok, started = false, nil
    if ADFuelRun ~= nil and ADFuelRun.start ~= nil then
        ok, started = FarmPilotCall(ADFuelRun.start, vehicle, "back", why)
    end
    if not ok or started ~= true then
        -- pas de pompe connue : message déjà donné par ADFuelRun.start
        log("%s : %s : pas de plein possible (%s) : arrêt et attente", nameOf(vehicle), why, ok and "pas de pompe" or tostring(started))
        if mode.windrowCtx == nil then
            mode.windrowCtx = ctx
        end
        ADWindrowMode.stopAndWait(mode)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Reprise sur place (étape « windrow » d'AutonomousResumeStage.lua) : AutoDrive déjà en marche, mode remis à zéro
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowMode.resumeAt(mode, ctx, started)
    local vehicle = mode.vehicle
    ctx.started = started == true
    mode.windrowCtx = ctx
    if ctx.started and ADWindrowScan ~= nil and ADWindrowScan.anyLeft ~= nil then
        local okL, left = FarmPilotCall(ADWindrowScan.anyLeft, ctx.fieldNums, ctx.fillTypes)
        if okL and left == false then
            log("%s : reprise au champ %s : plus d'andain au sol, champ fini", nameOf(vehicle), ctx.fieldText)
            message(vehicle, "INFO", "AD_autonomous_windrowDone", ctx.fieldText)
            ADWindrowMode.finishField(mode)
            return
        end
    end
    log("%s : reprise au champ %s avec la presse « %s » : nouvelle recherche des andains sur place (%s)", nameOf(vehicle), ctx.fieldText,
        toolName(ctx.baler), ctx.started and "pressage commencé" or "pressage pas encore commencé")
    ADWindrowMode.startScan(mode)
end

-- ------------------------------------------------------------------------------------------------------------
-- Étapes (hook AutonomousMode:handleFinishedTask), fin
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowMode.handleStage(mode)
    local vehicle = mode.vehicle
    if vehicle.ad.isStoppingWithError then
        ADWindrowMode.stopAndWait(mode)
        return
    end
    local stage, task = mode.windrowStage, mode.windrowTask
    mode.windrowTask = nil
    if stage == "empty" then
        local after = mode.windrowAfterEmpty
        mode.windrowAfterEmpty = nil
        if after == "finish" then
            ADWindrowMode.finishFieldGo(mode)
        elseif type(after) == "table" and after.refill ~= nil then
            ADWindrowMode.refillGo(mode, after.refill)
        elseif type(after) == "table" and after.fuel then
            ADWindrowMode.fuelGo(mode)
        else
            ADWindrowMode.stopAndWait(mode)
        end
        return
    end
    if mode.windrowCtx == nil then
        ADWindrowMode.stopAndWait(mode)
    elseif stage == "scan" then
        ADWindrowMode.afterScan(mode, task)
    elseif stage == "bale" then
        ADWindrowMode.afterBale(mode, task)
    else
        log("%s : étape « %s » de la presse inattendue : arrêt et attente", nameOf(vehicle), tostring(stage))
        ADWindrowMode.stopAndWait(mode)
    end
end

local function releaseIfPrepared(mode, forRoad)
    local ctx = mode.windrowCtx
    if ctx ~= nil and ctx.baler ~= nil and ctx.prepared then
        ctx.prepared = false
        FarmPilotCall(ADBalerControl.release, ctx.baler, forRoad)
    end
end

function ADWindrowMode.stopAndWait(mode)
    local vehicle = mode.vehicle
    releaseIfPrepared(mode, false)
    ADWindrowMode.reset(mode)
    mode.driveToDestinationTask = nil
    vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
end

-- champ fini : presse repliée pour la route, puis la suite d'un champ fini (champ suivant, garage), comme la remorque à
-- balles (AutonomousBales.lua : finishField, afterStop)
function ADWindrowMode.finishField(mode)
    local vehicle = mode.vehicle
    local ctx = mode.windrowCtx
    if ctx ~= nil and ctx.baler ~= nil then
        ctx.prepared = false
        FarmPilotCall(ADBalerControl.release, ctx.baler, true)
        if ADWindrowMode.waitEmpty(mode, ctx.baler, "finish") then
            return
        end
    end
    ADWindrowMode.finishFieldGo(mode)
end

function ADWindrowMode.finishFieldGo(mode)
    local vehicle = mode.vehicle
    local ctx = mode.windrowCtx
    log("%s : champ %s fini : la suite (champ suivant, sinon garage)", nameOf(vehicle), tostring(ctx ~= nil and ctx.fieldText or "?"))
    ADWindrowMode.reset(mode)
    if ADBaleCollect ~= nil and ADBaleCollect.finishField ~= nil then
        ADBaleCollect.finishField(mode)
        return
    end
    mode.driveToDestinationTask = nil
    vehicle.ad.fpBaleContinue = true
    vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
end

-- ------------------------------------------------------------------------------------------------------------
-- Tâche : recherche des andains, tracteur arrêté (ADWindrowScan par morceaux)
-- ------------------------------------------------------------------------------------------------------------
ADWindrowScanTask = ADInheritsFrom(AbstractTask)

function ADWindrowScanTask:new(vehicle, scan, ctx)
    local o = ADWindrowScanTask:create()
    o.taskType = "ADWindrowScanTask"
    o.vehicle = vehicle
    o.scan = scan
    o.ctx = ctx
    o.result = nil
    o.timer = 0
    return o
end

function ADWindrowScanTask:setUp()
    self.timer = 0
    self.frames = 0
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

function ADWindrowScanTask:update(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    if self.result ~= nil then
        return
    end
    self.timer = self.timer + (dt or 0)
    self.frames = (self.frames or 0) + 1
    local ok, done = FarmPilotCall(self.scan.update, self.scan, ADWindrowMode.SCAN_BUDGET)
    if not ok then
        log("ERREUR recherche des andains : %s", tostring(done))
        self:finish("erreur")
    elseif done == true then
        self:finish("ok")
    elseif self.timer >= ADWindrowMode.SCAN_TIMEOUT then
        self:finish("timeout")
    end
end

function ADWindrowScanTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self:finished()
end

-- arrêt pendant une nouvelle recherche (presse déjà au travail) : presse arrêtée et pick-up relevé
function ADWindrowScanTask:abort()
    local ctx = self.ctx
    if ctx ~= nil and ctx.baler ~= nil and ctx.prepared then
        ctx.prepared = false
        log("%s : recherche des andains interrompue : presse arrêtée", nameOf(self.vehicle))
        FarmPilotCall(ADBalerControl.release, ctx.baler, false)
    end
end

function ADWindrowScanTask:finished()
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADWindrowScanTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_windrowScan;" .. string.format(" (%d s)", math.floor((self.timer or 0) / 1000))
end

-- ------------------------------------------------------------------------------------------------------------
-- (15/11) Tâche : tracteur arrêté le temps que la presse pose la balle finie qu'elle contient encore avant la route
-- (ADBalerControl.emptyStep : 30 s au plus), puis repli et réglages rendus
-- ------------------------------------------------------------------------------------------------------------
ADWindrowEmptyTask = ADInheritsFrom(AbstractTask)

function ADWindrowEmptyTask:new(vehicle, baler)
    local o = ADWindrowEmptyTask:create()
    o.taskType = "ADWindrowEmptyTask"
    o.vehicle = vehicle
    o.baler = baler
    o.done = false
    o.timer = 0
    return o
end

function ADWindrowEmptyTask:setUp()
    self.timer = 0
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

function ADWindrowEmptyTask:update(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    if self.done then
        return
    end
    self.timer = self.timer + (dt or 0)
    local ok, finished = FarmPilotCall(ADBalerControl.emptyStep, self.baler)
    if not ok then
        log("ERREUR balle posée avant la route : %s", tostring(finished))
        FarmPilotCall(ADBalerControl.release, self.baler, true, true)
        finished = true
    end
    if finished == true then
        self.done = true
        self:finished()
    end
end

-- arrêt pendant ce temps : réglages rendus tout de suite, presse arrêtée
function ADWindrowEmptyTask:abort()
    if not self.done and self.baler ~= nil then
        self.done = true
        FarmPilotCall(ADBalerControl.release, self.baler, false)
    end
end

function ADWindrowEmptyTask:finished()
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADWindrowEmptyTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_windrowEmpty;" .. string.format(" (%d s)", math.floor((self.timer or 0) / 1000))
end
