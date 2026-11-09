DriveToVehicleTask = ADInheritsFrom(AbstractTask)

DriveToVehicleTask.TARGET_DISTANCE = 35        -- m behind the 1st unloader, only when it has no crumbs

DriveToVehicleTask.STATE_PATHPLANNING = 1
DriveToVehicleTask.STATE_DRIVING = 2

-- FarmPilot : why = raison de l'appel (pour le log) ; la tâche commence par attendre la 1re benne, voir DriveToVehicleTaskFollow.lua
function DriveToVehicleTask:new(vehicle, targetVehicle, why)
    local o = DriveToVehicleTask:create()
    o.vehicle = vehicle
    o.targetVehicle = targetVehicle
    o.why = why or "appel"
    o.state = DriveToVehicleTask.STATE_WAIT_FOR_FIRST
    o.wayPoints = nil
    o.trailers = nil
    o.failures = 0
    o.arrivals = 0
    o.retryDelay = DriveToVehicleTask.RETRY_WAIT
    o.retryTime = 0
    o.waitStart = nil
    o.lastLog = nil
    o.taskType = "DriveToVehicleTask"
    return o
end

function DriveToVehicleTask:setUp()
    self.trailers, _ = AutoDrive.getAllUnits(self.vehicle)
    AutoDrive.setTrailerCoverOpen(self.vehicle, self.trailers, false)
    self:setUpFollowFirst() -- FarmPilot : attendre la 1re en place, puis aller vers ses miettes, voir DriveToVehicleTaskFollow.lua
end

function DriveToVehicleTask:update(dt)
    -- FarmPilot : rejoindre la 1re benne et ses miettes (attente, trace, bande coupée, ligne droite), voir DriveToVehicleTaskFollow.lua
    self:updateFollowFirst(dt)
end

function DriveToVehicleTask:abort()
    self:abortFollowFirst() -- FarmPilot : calcul de trajet arrêté, place rendue, voir DriveToVehicleTaskFollow.lua
    -- (09/11) même garde que finished : la benne visée a pu être vendue ou supprimée entre-temps
    if self.targetVehicle ~= nil and self.targetVehicle.ad ~= nil and self.targetVehicle.ad.modes ~= nil then
        self.targetVehicle.ad.modes[AutoDrive.MODE_UNLOAD]:unregisterFollowingUnloader()
    end
end

-- FarmPilot : suivre les miettes de la 1re ou attendre se décide à l'arrivée (DriveToVehicleTask:arrived, voir
-- DriveToVehicleTaskFollow.lua) ; ici la place dans le champ est rendue (DriveToVehicleTaskFieldPark.lua)
function DriveToVehicleTask:finished(propagate)
    self:leaveParkSpot()
    if self.targetVehicle ~= nil and self.targetVehicle.ad ~= nil and self.targetVehicle.ad.modes ~= nil then
        self.targetVehicle.ad.modes[AutoDrive.MODE_UNLOAD]:unregisterFollowingUnloader()
    end
    self.vehicle.ad.taskModule:setCurrentTaskFinished(propagate)
end

function DriveToVehicleTask:getInfoText()
    if self.state == DriveToVehicleTask.STATE_PATHPLANNING then
        local actualState, maxStates = self.vehicle.ad.pathFinderModule:getCurrentState()
        return g_i18n:getText("AD_task_pathfinding") .. string.format(" %d / %d ", actualState, maxStates)
    else
        return g_i18n:getText("AD_task_drive_to_vehicle")
    end
end

function DriveToVehicleTask:getI18nInfo()
    if self.state == DriveToVehicleTask.STATE_PATHPLANNING then
        return self:getPlanningI18n()
    else
        return "$l10n_AD_task_drive_to_vehicle;"
    end
end
