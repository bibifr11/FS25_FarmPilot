ExitFieldTask = ADInheritsFrom(AbstractTask)
ExitFieldTask.debug = false

ExitFieldTask.STATE_PATHPLANNING = 1
ExitFieldTask.STATE_DRIVING = 2
ExitFieldTask.STATE_DELAY_PATHPLANNING = 3
ExitFieldTask.STATE_FINISHED = 9 -- FarmPilot : sortie finie (jamais définie chez AutoDrive, valait nil ; 4 à 8 : ExitFieldTaskStuck.lua)

--[==[ Mis de côté (09/11) : inutilisé : stratégies de sortie d'AutoDrive, remplacées par ExitFieldTaskExitPoints.lua
ExitFieldTask.STRATEGY_START = 0
ExitFieldTask.STRATEGY_BEHIND_START = 1
ExitFieldTask.STRATEGY_CLOSEST = 2
]==]

function ExitFieldTask:new(vehicle)
    local o = ExitFieldTask:create()
    o.vehicle = vehicle
    o.trailers = nil
    --[==[ Mis de côté (09/11) : inutilisé o.failedPathFinder = 0 ]==]
    o.waitForCheckTimer = AutoDriveTON:new()
    return o
end

function ExitFieldTask:setUp()
    self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
    --[==[ Mis de côté (09/11) : inutilisé self.nextExitStrategy = AutoDrive.getSetting("exitField", self.vehicle) ]==]
    self.trailers, _ = AutoDrive.getAllUnits(self.vehicle)
    AutoDrive.setTrailerCoverOpen(self.vehicle, self.trailers, false)
end

function ExitFieldTask:update(dt)
    self:publishFieldExit() -- FarmPilot : point de sortie publié pour les bennes vides qui arrivent, voir ExitFieldTaskExitPoints.lua
    -- FarmPilot : pleine et coincée (ensileuse) : rangée sur le côté, recul, suivi de la bande, demi-tour, voir ExitFieldTaskStuck.lua
    if self:updateFullStuck(dt) then
        return
    end
    if self.state == ExitFieldTask.STATE_PATHPLANNING then
        if self.vehicle.ad.pathFinderModule:hasFinished() then
            self.wayPoints = self.vehicle.ad.pathFinderModule:getPath()
            if self.wayPoints == nil or #self.wayPoints == 0 then
                self:handleNoExitRoute() -- FarmPilot : bande coupée, puis point de sortie suivant, voir ExitFieldTaskExitPoints.lua
            else
                self.vehicle.ad.drivePathModule:setWayPoints(self.wayPoints)
                self:onExitRouteSet() -- FarmPilot : trajet partiel, heure de départ, voir ExitFieldTaskExitPoints.lua
                self.state = ExitFieldTask.STATE_DRIVING
            end
        else
            self.vehicle.ad.pathFinderModule:update(dt)
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
        end
    elseif self.state == ExitFieldTask.STATE_DELAY_PATHPLANNING then
        ExitFieldTask.debugMsg(self.vehicle, "ExitFieldTask:update - STATE_DELAY_PATHPLANNING")
        if self.waitForCheckTimer:timer(true, self.retryDelay or 1000, dt) then
            self.waitForCheckTimer:timer(false)
            self.retryDelay = nil
            if self:startPathPlanning() then
                self.vehicle.ad.pathFinderModule:addDelayTimer(6000)
                self.state = ExitFieldTask.STATE_PATHPLANNING
                return
            end
        end
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return
    elseif self.state == ExitFieldTask.STATE_DRIVING then
        if self:updateExitDriving(dt) then -- FarmPilot : trajet partiel, point occupé, obstacle, voir ExitFieldTaskExitPoints.lua
            return
        end
        if self.vehicle.ad.drivePathModule:isTargetReached() then
            self.state = ExitFieldTask.STATE_FINISHED
        else
            self.vehicle.ad.drivePathModule:update(dt)
        end
    elseif self.state == ExitFieldTask.STATE_FINISHED then
        self:finished()
    end
end

function ExitFieldTask:abort()
    self:abortFieldExit() -- FarmPilot : demi-tour arrêté, point de sortie effacé, voir ExitFieldTaskExitPoints.lua
end

function ExitFieldTask:finished()
    self:finishFieldExit() -- FarmPilot : point de sortie effacé, voir ExitFieldTaskExitPoints.lua
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

-- returns true when a path planning was started, false when the task ended
function ExitFieldTask:startPathPlanning()
    ExitFieldTask.debugMsg(self.vehicle, "ExitFieldTask:startPathPlanning")
    -- FarmPilot : l'entrée du champ d'abord, puis les points du réseau les plus proches, voir ExitFieldTaskExitPoints.lua
    return self:startExitPlanning()
end

function ExitFieldTask:continue()
end

function ExitFieldTask:getInfoText()
    if self.state == ExitFieldTask.STATE_PATHPLANNING then
        local actualState, maxStates = self.vehicle.ad.pathFinderModule:getCurrentState()
        return g_i18n:getText("AD_task_pathfinding") .. string.format(" %d / %d ", actualState, maxStates)
    else
        return g_i18n:getText("AD_task_exiting_field")
    end
end

function ExitFieldTask:getI18nInfo()
    local text = self:getExitI18nInfo() -- FarmPilot : texte de chaque étape de la sortie, voir ExitFieldTaskExitPoints.lua
    if text ~= nil then
        return text
    end
    return "$l10n_AD_task_exiting_field;"
end

function ExitFieldTask.debugMsg(vehicle, debugText, ...)
    if ExitFieldTask.debug == true then
        AutoDrive.debugMsg(vehicle, debugText, ...)
    else
        AutoDrive.debugPrint(vehicle, AutoDrive.DC_COMBINEINFO, debugText, ...)
    end
end
