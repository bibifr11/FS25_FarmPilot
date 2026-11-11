-- ============================================================================================================
-- FarmPilot : AutonomousFuel.lua
-- Mode Autonome : plein de carburant.
--
-- Règle (09/11) :
-- - Courseplay s'arrête faute de carburant (événement onCpFuelEmpty) : sortie du champ si on est loin de son
--   marqueur, plein à la pompe la plus proche (RefuelTask d'AutoDrive), retour au champ, puis Courseplay repart au
--   dernier point (fpRestartCp, comme le plein du semoir).
-- - Champ fini avec un champ suivant : moins de FUEL_LOW de carburant (réservoir le plus bas : gazole, AdBlue...)
--   = plein d'abord, puis le champ suivant.
-- - Pas de pompe connue : message, comme avant (Courseplay arrêté).
-- - Pendant ce plein, le plein automatique d'AutoDrive entre deux tâches ne s'en mêle pas (fpFuelRun, lu par
--   TaskModule.lua hasToRefuel).
-- - Courseplay ne s'arrête que si son réglage « attendre le plein » est sur non ; sinon il attend sur place.
--
-- Branché par une ligne dans : ExternalInterface.lua (onCpFuelEmpty), AutonomousMode.lua (reset ;
-- handleFinishedTask ; goToNextField), TaskModule.lua (hasToRefuel), Specialization.lua (stopAutoDrive : afterStop).
-- ============================================================================================================

ADFuelRun = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFuelRun.FUEL_LOW = 0.20          -- part du réservoir : en dessous, plein avant le champ suivant
ADFuelRun.EXIT_DISTANCE = 30       -- m : au champ et plus loin que ça de son marqueur = sortie du champ d'abord

local function log(fmt, ...)
    ADAutonomousManager.log(fmt, ...)
end

local function nameOf(vehicle)
    return tostring(vehicle.ad.stateModule:getName())
end

local function percent(level)
    return string.format("%d %%", math.floor((level or 0) * 100 + 0.5))
end

-- ------------------------------------------------------------------------------------------------------------
-- Carburant, pompe
-- ------------------------------------------------------------------------------------------------------------
-- réservoir le plus bas (gazole, AdBlue, électricité, méthane), part de 0 à 1 ; nil sans moteur
function ADFuelRun.fuelLevel(vehicle)
    local spec = vehicle ~= nil and vehicle.spec_motorized or nil
    if spec == nil or spec.consumersByFillTypeName == nil or vehicle.getFillUnitFillLevelPercentage == nil then
        return nil
    end
    local low = nil
    for fillTypeName, consumer in pairs(spec.consumersByFillTypeName) do
        if not table.contains(AutoDrive.nonFillableFillTypes or {}, fillTypeName) then
            local p = vehicle:getFillUnitFillLevelPercentage(consumer.fillUnitIndex)
            if p ~= nil and (low == nil or p < low) then
                low = p
            end
        end
    end
    return low
end

-- marqueur de la pompe la plus proche ; nil s'il n'y en a pas
local function pumpMarker(vehicle)
    local id = ADTriggerManager.getClosestRefuelDestination(vehicle, true)
    if id == nil or id < 1 then
        return nil
    end
    return ADGraphManager:getMapMarkerById(id)
end

-- ------------------------------------------------------------------------------------------------------------
-- Remise à zéro (hook AutonomousMode:reset)
-- ------------------------------------------------------------------------------------------------------------
function ADFuelRun.reset(mode)
    mode.fuelStage = nil
    mode.fuelTask = nil
    mode.fuelThen = nil
    mode.fuelMarker = nil
    if mode.vehicle ~= nil and mode.vehicle.ad ~= nil then
        mode.vehicle.ad.fpFuelRun = nil
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ : after = « back » (retour au champ, Courseplay repart) ou « next » (champ suivant)
-- ------------------------------------------------------------------------------------------------------------
function ADFuelRun.start(vehicle, after, why)
    local sm = vehicle.ad.stateModule
    local marker = pumpMarker(vehicle)
    if marker == nil then
        log("%s : %s, pas de pompe connue : pas de plein", nameOf(vehicle), why)
        AutoDriveMessageEvent.sendMessageOrNotification(vehicle, ADMessagesManager.messageTypes.ERROR, "$l10n_AD_Driver_of; %s $l10n_AD_No_Refuel_Station;", 5000, sm:getName())
        return false
    end
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.onRouteToPark = false
    vehicle.ad.restartCP = false
    vehicle:startAutoDrive()
    if not sm:isActive() then
        return false
    end
    local mode = vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    mode:reset()
    vehicle.ad.fpFuelRun = true
    mode.fuelThen = after
    mode.fuelMarker = marker
    log("%s : %s, plein à « %s »%s", nameOf(vehicle), why, tostring(marker.name), after == "back" and ", puis retour au champ" or ", puis le champ suivant")
    if after == "back" then
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_fuelBack", tostring(marker.name))
        local x, y, z = getWorldTranslation(vehicle.components[1].node)
        local fieldMarker = sm:getFirstMarker()
        local wp = fieldMarker ~= nil and ADGraphManager:getWayPointById(fieldMarker.id) or nil
        local dist = wp ~= nil and MathUtil.vector2Length(x - wp.x, z - wp.z) or 0
        if AutoDrive.checkIsOnField(x, y, z) and dist > ADFuelRun.EXIT_DISTANCE then
            mode.fuelStage = "exit"
            mode.fuelTask = ExitFieldTask:new(vehicle)
            vehicle.ad.taskModule:addTask(mode.fuelTask)
            return true
        end
    else
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_fuelNext", percent(ADFuelRun.fuelLevel(vehicle)), tostring(marker.name))
    end
    ADFuelRun.startPump(mode)
    return true
end

-- la pompe : RefuelTask d'AutoDrive, sa fin rendue au mode (au lieu de relancer le mode depuis le début)
function ADFuelRun.startPump(mode)
    local vehicle = mode.vehicle
    mode.fuelStage = "pump"
    local task = RefuelTask:new(vehicle, mode.fuelMarker.id)
    local baseSetUp = task.setUp
    task.setUp = function(t)
        vehicle.ad.onRouteToRefuel = true -- plein complet (RefuelTask : getRequiredRefuels)
        baseSetUp(t)
    end
    task.finished = function(t)
        t.refuelTrigger = nil
        t.wasRefuelling = false
        vehicle.ad.onRouteToRefuel = false
        vehicle.ad.taskModule:setCurrentTaskFinished()
    end
    mode.fuelTask = task
    vehicle.ad.taskModule:addTask(task)
end

-- ------------------------------------------------------------------------------------------------------------
-- Étapes (hook AutonomousMode:handleFinishedTask) : « exit » -> « pump » -> « back » ou champ suivant
-- ------------------------------------------------------------------------------------------------------------
function ADFuelRun.handleStage(mode)
    local vehicle = mode.vehicle
    local stage = mode.fuelStage
    mode.fuelTask = nil
    if vehicle.ad.isStoppingWithError then
        ADFuelRun.reset(mode)
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
        return
    end
    if stage == "exit" then
        ADFuelRun.startPump(mode)
    elseif stage == "pump" then
        log("%s : plein de carburant fait (%s)", nameOf(vehicle), percent(ADFuelRun.fuelLevel(vehicle)))
        local fieldMarker = vehicle.ad.stateModule:getFirstMarker()
        if mode.fuelThen == "back" and fieldMarker ~= nil then
            mode.fuelStage = "back"
            mode.fuelTask = DriveToDestinationTask:new(vehicle, fieldMarker.id)
            vehicle.ad.taskModule:addTask(mode.fuelTask)
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_seederBack", tostring(fieldMarker.name))
        else
            -- champ suivant, une fois FarmPilot arrêté (afterStop)
            ADFuelRun.reset(mode)
            vehicle.ad.fpFuelNext = true
            vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
        end
    else
        -- « back » : revenu au champ, Courseplay repart au dernier point (voir stopAutoDrive, fpRestartCp)
        ADFuelRun.reset(mode)
        log("%s : de retour au champ après le plein, Courseplay repart où il s'était arrêté", nameOf(vehicle))
        vehicle.ad.fpRestartCp = true
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Déclencheurs
-- ------------------------------------------------------------------------------------------------------------
-- (hook AutoDrive:onCpFuelEmpty) Courseplay arrêté faute de carburant en Autonome : true si c'est pris ici
function ADFuelRun.onCpFuelEmpty(vehicle)
    if vehicle == nil or not vehicle.isServer or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.modes == nil then
        return false
    end
    local sm = vehicle.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS or sm:isActive() then
        return false
    end
    local why = string.format("Courseplay arrêté faute de carburant (%s)", percent(ADFuelRun.fuelLevel(vehicle)))
    local ok, started = FarmPilotCall(ADFuelRun.start, vehicle, "back", why)
    if not ok then
        log("ERREUR plein de carburant : %s", tostring(started))
        return false
    end
    -- pas de pompe : le message est déjà donné, rien d'autre (comme avant, Courseplay reste arrêté)
    return true
end

-- (hook AutonomousMode.goToNextField) champ fini, champ suivant prévu : true si le plein passe d'abord
function ADFuelRun.beforeNextField(vehicle)
    if vehicle.ad.fpFuelDone then
        vehicle.ad.fpFuelDone = nil
        return false
    end
    local level = ADFuelRun.fuelLevel(vehicle)
    if level == nil or level >= ADFuelRun.FUEL_LOW then
        return false
    end
    local why = string.format("champ fini, carburant à %s", percent(level))
    local ok, started = FarmPilotCall(ADFuelRun.start, vehicle, "next", why)
    if not ok then
        log("ERREUR plein de carburant : %s", tostring(started))
        return false
    end
    return started == true
end

-- (hook AutoDrive:stopAutoDrive) plein fait avant le champ suivant : on y va, à l'image suivante
function ADFuelRun.afterStop(vehicle)
    if vehicle == nil or vehicle.ad == nil then
        return
    end
    vehicle.ad.fpFuelRun = nil
    if not vehicle.ad.fpFuelNext then
        return
    end
    vehicle.ad.fpFuelNext = nil
    if vehicle.ad.isStoppingWithError then
        return
    end
    local function goOn()
        if vehicle.ad.stateModule:isActive() then
            return
        end
        vehicle.ad.fpFuelDone = true
        local ok, err = FarmPilotCall(AutoDrive.onCpFinished, vehicle)
        if not ok then
            log("ERREUR champ suivant après le plein : %s", tostring(err))
        end
        vehicle.ad.fpFuelDone = nil
    end
    local mission = g_currentMission
    if mission ~= nil and mission.addUpdateable ~= nil and mission.removeUpdateable ~= nil then
        local once = {}
        once.update = function(self, dt)
            mission:removeUpdateable(self)
            goOn()
        end
        mission:addUpdateable(once)
    else
        goOn()
    end
end
