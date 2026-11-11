-- ============================================================================================================
-- FarmPilot : AutonomousParkUnload.lua
-- Bouton « Envoyer au parking » avec une benne pas vide : aller la vider d'abord là où le mode le prévoyait.
--
-- (11/11) Tracteur en « Décharger la moissonneuse » (1re destination « Champ 27 », déchargement « Stock Ferme »),
-- benne pleine : le bouton l'envoyait droit au parking, sans passer vider. La benne restait pleine à sa place.
--
-- Règle :
-- - une benne (ou remorque à vidage) attelée avec au moins MIN_LITERS dedans, et une destination de déchargement
--   réglée dans le HUD du mode en cours (2e destination de « Chargement / Livraison » et de « Décharger la
--   moissonneuse », 1re destination de « Livrer à ») : le tracteur y va et vide comme le fait ce mode
--   (UnloadAtDestinationTask, déchargement aux déclencheurs par ADTrailerModule), puis le bouton reprend sa suite
--   habituelle (benne posée à sa place, tracteur garé : AutonomousParkButton.lua) ;
-- - pas de destination de déchargement dans ce mode, ou elle n'est pas réglée : une ligne au journal, parking comme
--   avant ;
-- - arrêté sur place sans que le niveau baisse pendant NO_CHANGE_TIME : une ligne au journal, parking comme avant
--   avec ce qui reste dans la benne ;
-- - le bouton une 2e fois pendant ce trajet : parking tout de suite, sans vider.
-- Le trajet se fait en mode Autonome (étape « parkUnloadStage ») ; le mode d'avant est noté et rendu à l'arrêt
-- (ADParkButton.rememberMode / restoreMode), comme pour la vidange de l'épandeur (AutonomousSprayerDump.lua).
-- Épandeurs, pulvés, semoirs, presses, remorques à balles : pas concernés (ce ne sont pas des bennes, voir
-- ADTrailerHitch.isTrailerObject).
--
-- Branché par une ligne chacune : ADInputManager:input_parkVehicle (AutonomousParkButton.lua) ; reset, monitorTasks
-- et handleFinishedTask d'AutonomousMode.lua ; AutoDrive.getDistanceToUnloadPosition (TrailerUtil.lua) ;
-- Specialization.lua (après l'arrêt) ; register.lua.
-- ============================================================================================================

ADParkUnload = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADParkUnload.MIN_LITERS = 50        -- L : en dessous, la benne compte comme vide (comme la fin de chantier de la moissonneuse)
ADParkUnload.NO_CHANGE_TIME = 45000 -- ms arrêté sur place sans que le niveau baisse : on n'attend plus
ADParkUnload.LEVEL_STEP = 1         -- L : baisse du niveau qui compte

-- destination de déchargement du HUD selon le mode ; les autres modes n'en ont pas
ADParkUnload.MARKER_OF_MODE = {
    [AutoDrive.MODE_PICKUPANDDELIVER] = "second",
    [AutoDrive.MODE_UNLOAD] = "second",
    [AutoDrive.MODE_DELIVERTO] = "first"
}

local function log(fmt, ...)
    ADAutonomousManager.log(fmt, ...)
end

local function nameOf(vehicle)
    return tostring(vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:getName() or "?")
end

local function autonomousMode(vehicle)
    local ad = vehicle ~= nil and vehicle.ad or nil
    return ad ~= nil and ad.modes ~= nil and ad.modes[AutoDrive.MODE_AUTONOMOUS] or nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Ce que portent les bennes attelées (toute la file) : litres, capacité, nom du produit, nombre de bennes
-- ------------------------------------------------------------------------------------------------------------
local function productOf(trailer)
    local spec = trailer.spec_fillUnit
    if spec == nil or spec.fillUnits == nil or g_fillTypeManager == nil then
        return nil
    end
    for _, unit in ipairs(spec.fillUnits) do
        if (unit.fillLevel or 0) > 0.01 and unit.fillType ~= nil then
            local ft = g_fillTypeManager:getFillTypeByIndex(unit.fillType)
            if ft ~= nil and ft.title ~= nil and ft.title ~= "" then
                return tostring(ft.title)
            end
        end
    end
    return nil
end

function ADParkUnload.load(vehicle)
    local level, capacity, product, count = 0, 0, nil, 0
    local okU, units = FarmPilotCall(AutoDrive.getAllUnits, vehicle)
    if not okU or type(units) ~= "table" then
        return level, capacity, product, count
    end
    for _, unit in ipairs(units) do
        if ADTrailerHitch.isTrailerObject(unit) then
            local ok, l, c = FarmPilotCall(AutoDrive.getObjectFillLevels, unit)
            if ok and type(l) == "number" then
                count = count + 1
                level = level + l
                capacity = capacity + (type(c) == "number" and c or 0)
                if product == nil and l > 0.01 then
                    local okP, p = FarmPilotCall(productOf, unit)
                    product = okP and p or nil
                end
            end
        end
    end
    return level, capacity, product, count
end

-- ------------------------------------------------------------------------------------------------------------
-- Faut-il vider avant le parking ? nil = rien à vider (bouton comme avant) ; sinon { level, capacity, product,
-- marker } ou { level, capacity, product, why } quand il n'y a nulle part où vider
-- ------------------------------------------------------------------------------------------------------------
function ADParkUnload.decide(vehicle)
    local sm = vehicle.ad.stateModule
    if autonomousMode(vehicle) == nil or ADTrailerHitch == nil then
        return nil
    end
    local level, capacity, product, count = ADParkUnload.load(vehicle)
    if count == 0 or level < ADParkUnload.MIN_LITERS then
        return nil
    end
    local d = { level = level, capacity = capacity, product = product or "?" }
    local which = ADParkUnload.MARKER_OF_MODE[sm:getMode()]
    if which == nil then
        d.why = "pas de destination de déchargement dans ce mode"
        d.quiet = true -- mode sans déchargement : le journal suffit
        return d
    end
    local marker
    if which == "first" then
        marker = sm:getFirstMarker()
    else
        marker = sm:getSecondMarker()
    end
    if marker == nil or marker.id == nil or ADGraphManager:getWayPointById(marker.id) == nil then
        d.why = "pas de destination de déchargement réglée"
        return d
    end
    d.marker = marker
    return d
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ vers la destination de déchargement
-- ------------------------------------------------------------------------------------------------------------
function ADParkUnload.start(vehicle, d)
    local sm = vehicle.ad.stateModule
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.onRouteToPark = false
    vehicle.ad.restartCP = false
    sm:setStartHelper(false)
    vehicle:startAutoDrive()
    if not sm:isActive() then
        return false
    end
    local mode = autonomousMode(vehicle)
    mode:reset()
    mode.parkUnloadStage = "unload"
    mode.parkUnloadMarker = d.marker
    mode.parkUnloadStart = d.level
    mode.parkUnloadLast = d.level
    mode.parkUnloadTimer = 0
    mode.parkUnloadTask = UnloadAtDestinationTask:new(vehicle, d.marker.id)
    vehicle.ad.taskModule:addTask(mode.parkUnloadTask)
    vehicle.ad.fpParkUnloadPlace = tostring(d.marker.name) -- trajet en cours (pour le journal si on l'arrête en route)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Hook ADInputManager:input_parkVehicle (AutonomousParkButton.lua) : true si le tracteur part vider d'abord
-- ------------------------------------------------------------------------------------------------------------
function ADParkUnload.onParkButton(input, vehicle, farmId)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.fpSkipParkUnload then
        return false
    end
    local sm = vehicle.ad.stateModule
    local name = nameOf(vehicle)
    local mode = autonomousMode(vehicle)
    if mode ~= nil and mode.parkUnloadStage ~= nil and sm:isActive() and sm:getMode() == AutoDrive.MODE_AUTONOMOUS then
        -- le bouton une 2e fois pendant le trajet : parking tout de suite
        log("%s : bouton parking de nouveau pendant le trajet vers le déchargement : parking sans vider", name)
        return false
    end
    local okD, d = FarmPilotCall(ADParkUnload.decide, vehicle)
    if not okD then
        log("ERREUR bouton parking, benne à vider : %s", tostring(d))
        return false
    end
    if d == nil then
        return false
    end
    if d.marker == nil then
        log("%s : bouton parking : benne pas vide (%.0f L de %s), mais %s : parking comme avant", name, d.level, d.product, tostring(d.why))
        if not d.quiet then
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 12000, "AD_autonomous_parkUnloadNone", string.format("%.0f", d.level), d.product)
        end
        return false
    end
    -- comme le bouton d'origine : Courseplay arrêté, FarmPilot arrêté s'il roulait
    AutoDrive:StopCP(vehicle)
    if sm:isActive() then
        input:input_start_stop(vehicle, farmId)
    end
    if ADParkButton ~= nil then ADParkButton.rememberMode(vehicle) end -- mode d'avant rendu à l'arrêt, voir AutonomousParkButton.lua
    sm:setMode(AutoDrive.MODE_AUTONOMOUS)
    local okS, started = false, nil
    if sm:getMode() == AutoDrive.MODE_AUTONOMOUS then
        okS, started = FarmPilotCall(ADParkUnload.start, vehicle, d)
    end
    if not okS or not started then
        log("%s : bouton parking : benne pas vide (%.0f L de %s), trajet vers « %s » pas lancé (%s) : parking comme avant", name, d.level, d.product,
            tostring(d.marker.name), okS and "refusé" or tostring(started))
        if sm:isActive() then
            vehicle:stopAutoDrive()
        end
        if ADParkButton ~= nil then ADParkButton.restoreMode(vehicle) end
        return false
    end
    log("%s : bouton parking : benne pas vide (%.0f L de %s) : va vider à « %s » d'abord, puis au parking", name, d.level, d.product, tostring(d.marker.name))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_parkUnloadGo", tostring(d.marker.name))
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Pendant le trajet (AutonomousMode)
-- ------------------------------------------------------------------------------------------------------------
-- le déchargement aux déclencheurs marche pendant cette étape (ADTrailerModule:update)
function AutonomousMode:shouldUnloadAtTrigger()
    return self.parkUnloadStage ~= nil
end

-- Hook AutoDrive.getDistanceToUnloadPosition : la destination notée au départ (nil hors de cette étape)
function ADParkUnload.unloadMarker(rootVehicle)
    local ad = rootVehicle ~= nil and rootVehicle.ad or nil
    if ad == nil or ad.stateModule == nil or ad.stateModule:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return nil
    end
    local mode = autonomousMode(rootVehicle)
    if mode == nil or mode.parkUnloadStage == nil then
        return nil
    end
    return mode.parkUnloadMarker
end

-- Hook AutonomousMode:reset
function ADParkUnload.reset(mode)
    mode.parkUnloadStage = nil
    mode.parkUnloadMarker = nil
    mode.parkUnloadTask = nil
    mode.parkUnloadStart = nil
    mode.parkUnloadLast = nil
    mode.parkUnloadTimer = nil
    mode.parkUnloadGaveUp = nil
end

-- Hook AutonomousMode:monitorTasks : arrêté sur place et le niveau ne baisse pas -> on n'attend plus
function ADParkUnload.monitor(mode, dt)
    if mode.parkUnloadStage == nil then
        return
    end
    local vehicle = mode.vehicle
    local task = mode.parkUnloadTask
    if task == nil or task.isContinued or vehicle.ad.taskModule:getActiveTask() ~= task then
        return
    end
    local level = ADParkUnload.load(vehicle)
    if mode.parkUnloadLast == nil or level < mode.parkUnloadLast - ADParkUnload.LEVEL_STEP then
        mode.parkUnloadLast = level
        mode.parkUnloadTimer = 0
        return
    end
    local onTheSpot = task.state == UnloadAtDestinationTask.STATE_DRIVING
        and (vehicle.ad.drivePathModule:isTargetReached() or vehicle.ad.trailerModule:isActiveAtTrigger())
    if not onTheSpot then
        mode.parkUnloadTimer = 0
        return
    end
    mode.parkUnloadTimer = (mode.parkUnloadTimer or 0) + dt
    if mode.parkUnloadTimer >= ADParkUnload.NO_CHANGE_TIME then
        mode.parkUnloadGaveUp = true
        log("%s : bouton parking : rien ne se vide à « %s » depuis %.0f s (reste %.0f L) : on n'attend plus", nameOf(vehicle),
            tostring(mode.parkUnloadMarker ~= nil and mode.parkUnloadMarker.name or "?"), ADParkUnload.NO_CHANGE_TIME / 1000, level)
        task:continue()
    end
end

-- Hook AutonomousMode:handleFinishedTask : la tâche de déchargement est finie (benne vide, ou attente abandonnée)
function ADParkUnload.handleStage(mode)
    local vehicle = mode.vehicle
    local name = nameOf(vehicle)
    local place = tostring(mode.parkUnloadMarker ~= nil and mode.parkUnloadMarker.name or "?")
    local startLevel = mode.parkUnloadStart or 0
    ADParkUnload.reset(mode)
    vehicle.ad.fpParkUnloadPlace = nil
    if vehicle.ad.isStoppingWithError then
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
        return
    end
    local level = ADParkUnload.load(vehicle)
    if level < ADParkUnload.MIN_LITERS then
        log("%s : bouton parking : benne vidée à « %s » (%.0f L), maintenant le parking", name, place, math.max(0, startLevel - level))
    else
        log("%s : bouton parking : benne pas vidée à « %s » (reste %.0f L sur %.0f) : parking comme avant", name, place, level, startLevel)
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 12000, "AD_autonomous_parkUnloadFailed", place, string.format("%.0f", level))
    end
    -- la suite du bouton une fois FarmPilot arrêté : afterStop
    vehicle.ad.fpParkUnloadContinue = true
    vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
end

-- ------------------------------------------------------------------------------------------------------------
-- Hook AutoDrive:stopAutoDrive : après le déchargement, la suite habituelle du bouton (à l'image suivante)
-- ------------------------------------------------------------------------------------------------------------
function ADParkUnload.continueToPark(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.stateModule:isActive() then
        return
    end
    vehicle.ad.fpSkipParkUnload = true
    local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
    local ok, err = FarmPilotCall(ADInputManager.input_parkVehicle, ADInputManager, vehicle, farmId)
    vehicle.ad.fpSkipParkUnload = nil
    if not ok then
        log("ERREUR parking après le déchargement : %s", tostring(err))
    end
end

function ADParkUnload.afterStop(vehicle)
    if vehicle == nil or vehicle.ad == nil then
        return
    end
    if vehicle.ad.fpParkUnloadPlace ~= nil then
        -- arrêté en route (à la main, pas de chemin…) : rien de plus
        log("%s : bouton parking : trajet vers « %s » arrêté avant la fin, benne pas vidée", nameOf(vehicle), tostring(vehicle.ad.fpParkUnloadPlace))
        vehicle.ad.fpParkUnloadPlace = nil
    end
    if not vehicle.ad.fpParkUnloadContinue then
        return
    end
    vehicle.ad.fpParkUnloadContinue = nil
    if vehicle.ad.isStoppingWithError then
        return
    end
    -- à l'image suivante : FarmPilot doit être complètement arrêté avant de repartir
    local mission = g_currentMission
    if mission ~= nil and mission.addUpdateable ~= nil and mission.removeUpdateable ~= nil then
        local once = {}
        once.update = function(self, dt)
            mission:removeUpdateable(self)
            ADParkUnload.continueToPark(vehicle)
        end
        mission:addUpdateable(once)
    else
        ADParkUnload.continueToPark(vehicle)
    end
end
