-- ============================================================================================================
-- FarmPilot : TrailerHitch.lua
-- Modes avec benne (Chargement / Livraison, Chargement, Livrer à, Décharger la moissonneuse) : remorque à aller
-- atteler au départ, et reposée à sa place à la fin du travail.
--
-- (09/11) 4e ligne du HUD « Remorque » dans ces modes (StateModuleTrailer.lua : fpTrailer) :
-- - au départ, si la remorque choisie n'est pas attelée : le tracteur va la chercher et l'attelle comme l'outil du
--   mode Autonome (route du réseau jusque devant elle, puis FetchToolTask : marche arrière, attelage, flexibles),
--   puis le mode démarre normalement ;
-- - à la fin du travail (tâche de parking des modes d'origine, ou fin de chantier de l'ensileuse) : si cette remorque
--   est attelée et qu'elle a sa place de parking, et le tracteur la sienne, elle est posée à sa place puis le
--   tracteur va se garer (même suite que le bouton parking, AutonomousParkButton.lua : parkWithToolDrop).
-- Rien de choisi (« Celle attelée ») : rien ne change.
-- Échange de bennes à la livraison (pleine posée sur une place, vide attelée) : TrailerSwap.lua, qui reprend
-- l'attelage d'ici (startFetch, after = "swap").
--
-- Branché par une ligne chacune : start, handleFinishedTask et monitorTasks de PickupAndDeliverMode, LoadMode,
-- UnloadAtMode et CombineUnloaderMode ; ParkTask:setUp ; CombineUnloaderMode:getParkAfterJobTask
-- (CombineUnloaderModeJobDone.lua) ; Specialization.lua (après l'arrêt) ; HUD : Hud.lua, PullDownList.lua ;
-- choix envoyé au serveur par AutonomousToolEvent.lua.
-- ============================================================================================================

ADTrailerHitch = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- modes où la ligne « Remorque » existe
ADTrailerHitch.MODES = {
    [AutoDrive.MODE_PICKUPANDDELIVER] = true,
    [AutoDrive.MODE_DELIVERTO] = true,
    [AutoDrive.MODE_LOAD] = true,
    [AutoDrive.MODE_UNLOAD] = true
}

ADTrailerHitch.FAIL_KEYS = {
    noPath = "AD_trailer_fetchNoPath",
    missed = "AD_trailer_fetchMissed",
    timeout = "AD_trailer_fetchMissed",
    busy = "AD_trailer_fetchBusy",
    noJoint = "AD_trailer_fetchNoJoint",
    other = "AD_trailer_fetchOther"
}

function ADTrailerHitch.log(fmt, ...)
    local ok, txt = pcall(string.format, fmt, ...)
    print("[FarmPilot Remorque] " .. (ok and txt or tostring(fmt)))
end

local function nameOf(vehicle)
    return tostring(vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:getName() or "?")
end

-- ------------------------------------------------------------------------------------------------------------
-- Remorques
-- ------------------------------------------------------------------------------------------------------------
function ADTrailerHitch.isTrailerMode(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    return sm ~= nil and sm.getFpTrailer ~= nil and ADTrailerHitch.MODES[sm:getMode()] == true
end

-- benne, plateau, citerne, transbordeur… : attelable, se remplit et se vide ; pas un outil de travail ni un engin
function ADTrailerHitch.isTrailerObject(o)
    if o == nil or o.spec_attachable == nil or o.spec_fillUnit == nil or o.spec_motorized ~= nil then
        return false
    end
    if o.spec_trailer == nil and o.spec_dischargeable == nil then
        return false
    end
    if ADAutonomousManager.isWorkObject(o) then
        return false
    end
    return true
end

local function farmOf(v)
    if v ~= nil and v.getOwnerFarmId ~= nil then
        local ok, farm = pcall(v.getOwnerFarmId, v)
        if ok then
            return farm
        end
    end
    return nil
end

-- remorque possédée, dételée, qui s'attelle à l'arrière de ce tracteur
function ADTrailerHitch.isFetchableTrailer(vehicle, trailer)
    if trailer == nil or trailer == vehicle or trailer.isDeleted or trailer.isDeleting then
        return false
    end
    if not ADTrailerHitch.isTrailerObject(trailer) then
        return false
    end
    local farm = farmOf(vehicle)
    if farm ~= nil and farmOf(trailer) ~= farm then
        return false
    end
    if trailer.getAttacherVehicle ~= nil and trailer:getAttacherVehicle() ~= nil then
        return false
    end
    return ADAutonomousManager.matchJoints(vehicle, trailer, false) ~= nil
end

-- « 30 000 »
local function thousands(n)
    local s = tostring(math.floor(n + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^ ", ""))
end

-- nom de la remorque et sa capacité : « Bandit SB 30/60 · 30 000 L »
function ADTrailerHitch.label(trailer)
    if trailer == nil then
        return "?"
    end
    local name = trailer.getName ~= nil and trailer:getName() or nil
    if name == nil or name == "" then
        name = ADAutonomousManager.toolLabel(trailer)
    end
    local okC, _, capacity = pcall(AutoDrive.getObjectFillLevels, trailer)
    if okC and type(capacity) == "number" and capacity > 0 then
        return string.format("%s · %s L", tostring(name), thousands(capacity))
    end
    return tostring(name)
end

-- liste du HUD : { tool, name, distance }, la plus proche d'abord ; deux pareilles : la distance s'ajoute
function ADTrailerHitch.fetchableTrailers(vehicle)
    local out = {}
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system == nil or system.vehicles == nil or vehicle == nil then
        return out
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    for _, v in pairs(system.vehicles) do
        local ok, fetchable = pcall(ADTrailerHitch.isFetchableTrailer, vehicle, v)
        if ok and fetchable then
            local tx, _, tz = getWorldTranslation(v.components[1].node)
            out[#out + 1] = { tool = v, name = ADTrailerHitch.label(v), distance = MathUtil.vector2Length(tx - vx, tz - vz) }
        end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    local count = {}
    for _, e in ipairs(out) do
        count[e.name] = (count[e.name] or 0) + 1
    end
    for _, e in ipairs(out) do
        if count[e.name] > 1 then
            e.name = string.format(g_i18n:getText("AD_autonomous_toolListEntry"), e.name, math.floor(e.distance + 0.5))
        end
    end
    return out
end

-- remorques et outils attelés directement au tracteur (les masses n'ont pas de remplissage et ne comptent pas)
local function attachedTrailers(vehicle)
    local list = {}
    if vehicle == nil or vehicle.getAttachedImplements == nil then
        return list
    end
    local ok, implements = pcall(vehicle.getAttachedImplements, vehicle)
    if ok and type(implements) == "table" then
        for _, impl in ipairs(implements) do
            local o = impl.object
            if o ~= nil and (ADTrailerHitch.isTrailerObject(o) or ADAutonomousManager.isWorkObject(o)) then
                list[#list + 1] = o
            end
        end
    end
    return list
end

ADTrailerHitch.attachedTrailers = attachedTrailers

-- la remorque choisie à aller atteler, ou nil (rien de choisi, ou déjà attelée) ; err si on ne peut pas y aller
function ADTrailerHitch.trailerToFetch(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or sm.getFpTrailer == nil then
        return nil
    end
    local trailer = sm:getFpTrailer()
    if trailer == nil then
        return nil
    end
    local attacher = trailer.getAttacherVehicle ~= nil and trailer:getAttacherVehicle() or nil
    if attacher ~= nil then
        local root = trailer.getRootVehicle ~= nil and trailer:getRootVehicle() or attacher
        if root == vehicle or attacher == vehicle then
            return nil -- déjà attelée
        end
        return nil, "busy", trailer
    end
    if #attachedTrailers(vehicle) > 0 then
        return nil, "other", trailer
    end
    if ADAutonomousManager.matchJoints(vehicle, trailer, true) == nil then
        return nil, "noJoint", trailer
    end
    return trailer
end

local function message(vehicle, messageType, duration, key, ...)
    AutonomousMode.message(vehicle, messageType, duration, key, ...)
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ : aller atteler la remorque choisie (crochet en tête de start des modes)
-- ------------------------------------------------------------------------------------------------------------
-- true = le départ est pris en charge ici (remorque à aller chercher, ou départ refusé)
function ADTrailerHitch.beforeStart(mode, user)
    local vehicle = mode ~= nil and mode.vehicle or nil
    if vehicle == nil or vehicle.ad == nil then
        return false
    end
    mode.fpHitch = nil
    if ADTrailerSwap ~= nil then
        ADTrailerSwap.cancel(mode)
    end
    if not ADTrailerHitch.isTrailerMode(vehicle) then
        return false
    end
    local ok, trailer, err, wanted = pcall(ADTrailerHitch.trailerToFetch, vehicle)
    if not ok then
        ADTrailerHitch.log("ERREUR remorque à atteler : %s", tostring(trailer))
        return false
    end
    if err ~= nil then
        message(vehicle, ADMessagesManager.messageTypes.ERROR, 12000, ADTrailerHitch.FAIL_KEYS[err] or "AD_trailer_fetchFailed", wanted ~= nil and ADTrailerHitch.label(wanted) or "?")
        ADTrailerHitch.log("%s : départ refusé, remorque choisie : %s", nameOf(vehicle), tostring(err))
        if vehicle.ad.stateModule:isActive() then
            vehicle:stopAutoDrive()
        end
        return true
    end
    if trailer == nil then
        return false
    end
    if not vehicle.ad.stateModule:isActive() then
        vehicle:startAutoDrive()
    end
    ADTrailerHitch.startFetch(mode, trailer, user)
    return true
end

-- aller atteler la remorque : par le réseau jusque devant elle, puis marche arrière et attelage.
-- after = nil : le mode démarre ensuite ; "swap" : échange de bennes, le mode reprend (TrailerSwap.lua : resume)
function ADTrailerHitch.startFetch(mode, trailer, user, after)
    local vehicle = mode.vehicle
    vehicle.ad.onRouteToPark = false
    mode.fpHitch = { trailer = trailer, user = user, stage = nil, stuck = 0, after = after }
    message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_trailer_fetchGo", ADTrailerHitch.label(trailer))
    local okR, wp, kind, markerName = pcall(AutonomousMode.fetchRoutePoint, vehicle, trailer)
    if not okR then
        ADTrailerHitch.log("ERREUR route vers la remorque : %s", tostring(wp))
        wp = nil
    end
    if wp ~= nil then
        ADTrailerHitch.log("%s : va chercher « %s » par le réseau (%s %s)", nameOf(vehicle), ADTrailerHitch.label(trailer),
            kind == "marker" and "sa place" or "point devant la remorque", tostring(kind == "marker" and markerName or wp.id))
        mode.fpHitch.stage = "route"
        mode.fpHitch.task = DriveToDestinationTask:new(vehicle, wp.id)
        vehicle.ad.taskModule:addTask(mode.fpHitch.task)
    else
        ADTrailerHitch.log("%s : va chercher « %s »", nameOf(vehicle), ADTrailerHitch.label(trailer))
        ADTrailerHitch.startAttach(mode)
    end
end

function ADTrailerHitch.startAttach(mode)
    local h = mode.fpHitch
    h.stage = "attach"
    h.task = ADFetchToolTask:new(mode.vehicle, h.trailer)
    mode.vehicle.ad.taskModule:addTask(h.task)
end

-- sur la route : dans l'axe de la remorque et assez près (ou arrêté devant elle) -> attelage (comme l'outil)
function ADTrailerHitch.monitor(mode, dt)
    local h = mode ~= nil and mode.fpHitch or nil
    if h == nil or h.stage ~= "route" or h.task == nil or mode.vehicle.ad.taskModule:getActiveTask() ~= h.task then
        return
    end
    local ok, ready, distance = pcall(ADFetchToolTask.readyFor, mode.vehicle, h.trailer)
    if not ok or distance == nil then
        return
    end
    if ready and distance <= AutonomousMode.FETCH_HANDOVER then
        ADTrailerHitch.log("%s : devant la remorque par le réseau (%.1f m), marche arrière", nameOf(mode.vehicle), distance)
        h.task:finished()
        return
    end
    if math.abs(mode.vehicle.lastSpeedReal or 0) < 0.0003 and distance <= AutonomousMode.FETCH_STUCK_RANGE then
        h.stuck = (h.stuck or 0) + dt
        if h.stuck >= AutonomousMode.FETCH_STUCK_TIME then
            ADTrailerHitch.log("%s : arrêté près de la remorque sur le réseau (%.1f m), on finit sans la route", nameOf(mode.vehicle), distance)
            h.task:finished()
        end
    else
        h.stuck = 0
    end
end

-- true = la fin de tâche était celle de l'attelage (crochet en tête de handleFinishedTask des modes)
function ADTrailerHitch.handleFinishedTask(mode)
    local h = mode ~= nil and mode.fpHitch or nil
    if h == nil then
        -- échange de bennes en cours : route vers la place, dételage (TrailerSwap.lua)
        if mode ~= nil and mode.fpSwap ~= nil and ADTrailerSwap ~= nil then
            return ADTrailerSwap.handleFinishedTask(mode)
        end
        return false
    end
    local vehicle = mode.vehicle
    if h.task ~= nil and vehicle.ad.taskModule.getActiveTask ~= nil and vehicle.ad.taskModule:getActiveTask() ~= h.task then
        -- une autre tâche s'est terminée (recul pour se dégager…) : l'attelage est abandonné, le mode reprend la main
        ADTrailerHitch.log("%s : attelage de « %s » interrompu par une autre tâche", nameOf(vehicle), ADTrailerHitch.label(h.trailer))
        mode.fpHitch = nil
        if h.after == "swap" and ADTrailerSwap ~= nil then
            ADTrailerSwap.cancel(mode)
        end
        return false
    end
    if h.stage == "route" then
        if vehicle.ad.isStoppingWithError then
            mode.fpHitch = nil
            if h.after == "swap" and ADTrailerSwap ~= nil then
                ADTrailerSwap.cancel(mode)
            end
            vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
            return true
        end
        ADTrailerHitch.startAttach(mode)
        return true
    end
    local result = h.task ~= nil and h.task.result or "?"
    local label = ADTrailerHitch.label(h.trailer)
    mode.fpHitch = nil
    if result == "ok" then
        if h.after == "swap" and ADTrailerSwap ~= nil then
            -- échange de bennes : le mode reprend comme après un déchargement
            ADTrailerSwap.resume(mode, h.trailer)
            return true
        end
        ADTrailerHitch.log("%s : remorque « %s » attelée, départ du mode", nameOf(vehicle), label)
        message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_trailer_fetchDone", label)
        -- départ normal du mode (la remorque choisie est maintenant attelée)
        mode:start(h.user)
    else
        ADTrailerHitch.log("%s : remorque « %s » pas attelée (%s), arrêt", nameOf(vehicle), label, tostring(result))
        if h.after == "swap" and ADTrailerSwap ~= nil then
            ADTrailerSwap.cancel(mode)
        end
        message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, ADTrailerHitch.FAIL_KEYS[result] or "AD_trailer_fetchFailed", label)
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin du travail : la remorque à sa place, puis le tracteur à la sienne
-- ------------------------------------------------------------------------------------------------------------
-- la remorque choisie, attelée, qui a sa place (et le tracteur la sienne) ; sinon nil
function ADTrailerHitch.trailerToDrop(vehicle)
    if not ADTrailerHitch.isTrailerMode(vehicle) then
        return nil
    end
    local trailer = vehicle.ad.stateModule:getFpTrailer()
    if trailer == nil or trailer.getAttacherVehicle == nil or trailer:getAttacherVehicle() ~= vehicle then
        return nil
    end
    if ADParkButton == nil or ADParkButton.toolToDrop == nil then
        return nil
    end
    local okD, tool = pcall(ADParkButton.toolToDrop, vehicle)
    if okD and tool == trailer then
        return trailer
    end
    return nil
end

-- tâche de parking des modes d'origine (crochet en tête de ParkTask:setUp) : true = pas de route vers le parking,
-- AutoDrive s'arrête et la remorque va à sa place juste après
function ADTrailerHitch.onParkTask(task)
    local vehicle = task ~= nil and task.vehicle or nil
    local trailer = ADTrailerHitch.trailerToDrop(vehicle)
    if trailer == nil then
        return false
    end
    vehicle.ad.fpTrailerDrop = trailer
    ADTrailerHitch.log("%s : travail fini, la remorque « %s » d'abord à sa place, puis le tracteur à la sienne", nameOf(vehicle), ADTrailerHitch.label(trailer))
    task:finished()
    return true
end

-- fin de chantier de l'ensileuse (crochet de getParkAfterJobTask) : arrêt, puis la même suite ; nil = comme avant
function ADTrailerHitch.parkAfterJobTask(mode)
    local vehicle = mode ~= nil and mode.vehicle or nil
    local trailer = ADTrailerHitch.trailerToDrop(vehicle)
    if trailer == nil then
        return nil
    end
    vehicle.ad.fpTrailerDrop = trailer
    vehicle.ad.harvestJobDone = nil
    ADTrailerHitch.log("%s : chantier fini, la remorque « %s » d'abord à sa place, puis le tracteur à la sienne", nameOf(vehicle), ADTrailerHitch.label(trailer))
    return StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE)
end

-- après l'arrêt d'AutoDrive (crochet dans Specialization.lua) : à l'image suivante, même suite que le bouton parking
function ADTrailerHitch.afterStop(vehicle)
    if ADTrailerSwap ~= nil and vehicle ~= nil and vehicle.ad ~= nil then
        ADTrailerSwap.release(vehicle) -- échange de bennes : places et benne vide libérées
    end
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.fpTrailerDrop == nil then
        return
    end
    local trailer = vehicle.ad.fpTrailerDrop
    vehicle.ad.fpTrailerDrop = nil
    if vehicle.ad.isStoppingWithError then
        return
    end
    local function go()
        if vehicle.ad.stateModule:isActive() then
            return
        end
        message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_trailer_dropGo", ADTrailerHitch.label(trailer))
        vehicle.ad.stateModule:setMode(AutoDrive.MODE_AUTONOMOUS)
        local ok, started = pcall(AutonomousMode.parkWithToolDrop, vehicle, trailer)
        if not ok or not started then
            ADTrailerHitch.log("%s : dépose de la remorque pas lancée (%s)", nameOf(vehicle), ok and "refusée" or tostring(started))
        end
    end
    local mission = g_currentMission
    if mission ~= nil and mission.addUpdateable ~= nil and mission.removeUpdateable ~= nil then
        local once = {}
        once.update = function(self, dt)
            mission:removeUpdateable(self)
            go()
        end
        mission:addUpdateable(once)
    else
        go()
    end
end
