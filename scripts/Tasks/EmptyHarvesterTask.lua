EmptyHarvesterTask = ADInheritsFrom(AbstractTask)
EmptyHarvesterTask.debug = false

EmptyHarvesterTask.STATE_PATHPLANNING = {}
EmptyHarvesterTask.STATE_DRIVING = {}
EmptyHarvesterTask.STATE_UNLOADING = {}
EmptyHarvesterTask.STATE_REVERSING = {}
EmptyHarvesterTask.STATE_WAITING = {}
EmptyHarvesterTask.STATE_UNLOADING_FINISHED = {}

EmptyHarvesterTask.REVERSE_TIME = 30000
EmptyHarvesterTask.MAX_STUCK_TIME = 60000
EmptyHarvesterTask.WAITING_TIME = 7000
EmptyHarvesterTask.WAITING_FOR_PIPE = 1000
-- stop retrying the path to the pipe after this many failures in a row
EmptyHarvesterTask.MAX_PATHFINDER_FAILURES = 6
-- (15/11) mode Strict : après MAX_PATHFINDER_FAILURES, nouvel essai toutes les STRICT_RETRY_DELAY ms au lieu de l'arrêt
EmptyHarvesterTask.STRICT_RETRY_DELAY = 15000

function EmptyHarvesterTask:new(vehicle, combine)
    local o = EmptyHarvesterTask:create()
    o.vehicle = vehicle
    o.combine = combine
    o.state = EmptyHarvesterTask.STATE_PATHPLANNING
    o.wayPoints = nil
    o.reverseStartLocation = nil
    o.stuckTimer = AutoDriveTON:new()
    o.reverseTimer = AutoDriveTON:new()
    o.waitTimer = AutoDriveTON:new()
    o.holdCPCombineTimer = AutoDriveTON:new()
    o.trailers = nil
    o.trailerCount = 0
    o.tractorTrainLength = 0
    o.pathFinderFailures = 0
    EmptyHarvesterTask.setStateNames(o)
    return o
end

-- (15/11) pas de trajet complet vers la moissonneuse arrêtée : rouler au plus près (dernier point propre), puis
-- recalculer au bout. Le trajet partiel n'existe qu'en mode Strict (PathFinderModule:partialAllowed).
function EmptyHarvesterTask.allowPartial(vehicle)
    vehicle.ad.pathFinderModule.allowPartialPath = true
end

-- (15/11) mode Strict, aucun trajet vers la moissonneuse : la benne va d'abord se garer dans le champ (sa place
-- d'attente, WaitForCallTaskFieldPark.lua), puis elle est rappelée et recalcule depuis cette place. Une fois toutes
-- les PARK_RETRY_INTERVAL au plus ; entre deux, elle attend sur place et recalcule (STRICT_RETRY_DELAY).
EmptyHarvesterTask.PARK_RETRY_INTERVAL = 300000

function EmptyHarvesterTask.parkBeforeRetry(task)
    local vehicle = task.vehicle
    local mode = vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or mode.setToWaitForCall == nil then
        return false
    end
    local last = vehicle.ad.fpParkBeforeRetry
    local now = g_time or 0
    if last ~= nil and last.combine == task.combine and now - last.time < EmptyHarvesterTask.PARK_RETRY_INTERVAL then
        return false
    end
    vehicle.ad.fpParkBeforeRetry = {combine = task.combine, time = now}
    print(string.format("[AD-Fin] %s: pas de trajet vers %s apres %d essais, il va d'abord se garer dans le champ puis recalcule",
        tostring(vehicle:getName()), tostring(task.combine:getName()), task.pathFinderFailures))
    mode:notifyAboutFailedPathfinder()
    task:finished(ADTaskModule.DONT_PROPAGATE)
    mode:setToWaitForCall()
    return true
end

function EmptyHarvesterTask:setUp()
    EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:setUp")
    self.vehicle.ad.pathFinderModule:reset()
    self.vehicle.ad.pathFinderModule:startPathPlanningToPipe(self.combine, false)
    EmptyHarvesterTask.allowPartial(self.vehicle)
    self.trailers, self.trailerCount = AutoDrive.getAllUnits(self.vehicle)
    self.tractorTrainLength = AutoDrive.getTractorTrainLength(self.vehicle, true, false)
    AutoDrive.setTrailerCoverOpen(self.vehicle, self.trailers, true)
end

function EmptyHarvesterTask:update(dt)
    if self.combine ~= nil and g_currentMission.nodeToObject[self.combine.components[1].node] == nil then
        self:finished()
        return
    end
    if self.lastState ~= self.state then
        EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update %s -> %s", tostring(self:getStateName(self.lastState)), tostring(self:getStateName()))
        self.lastState = self.state
        self:resetAllTimers()
    end

    local checkForStuck = (self.vehicle.lastSpeedReal <= 0.0002) and (
        self.state == EmptyHarvesterTask.STATE_DRIVING
        or self.state == EmptyHarvesterTask.STATE_UNLOADING
    )

    self.stuckTimer:timer(checkForStuck, self.MAX_STUCK_TIME, dt)
    if self.stuckTimer:done()
        -- or AutoDrive.getDistanceBetween(self.vehicle, self.combine) < self.MIN_COMBINE_DISTANCE 
        then
        -- got stuck or to close to combine -> reverse
        EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update - STATE_DRIVING stuck")
        local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
        self.reverseStartLocation = {x = x, y = y, z = z}
        self.state = EmptyHarvesterTask.STATE_REVERSING
    end

    if self.state == EmptyHarvesterTask.STATE_PATHPLANNING then
        if self.vehicle.ad.pathFinderModule:hasFinished() then
            self.wayPoints = self.vehicle.ad.pathFinderModule:getPath()
            self.vehicle.ad.drivePathModule:setWayPoints(self.wayPoints)
            if self.wayPoints == nil or #self.wayPoints == 0 then
                -- If the target/pipe location is blocked, we can issue a notification and stop the task - Otherwise we pause a moment and retry
                self.pathFinderFailures = self.pathFinderFailures + 1
                local pfm = self.vehicle.ad.pathFinderModule
                -- (15/11) mode Strict : pas de trajet = on n'arrête jamais le chauffeur. Pas même un trajet partiel :
                -- il attend sur place et recalcule (la moissonneuse avance, un passage s'ouvre)
                local keepTrying = pfm.strictField or pfm.strictFruit
                if keepTrying and (pfm:isTargetBlocked() or self.pathFinderFailures >= EmptyHarvesterTask.MAX_PATHFINDER_FAILURES)
                    and EmptyHarvesterTask.parkBeforeRetry(self) then
                    return
                elseif keepTrying and (pfm:isTargetBlocked() or self.pathFinderFailures >= EmptyHarvesterTask.MAX_PATHFINDER_FAILURES) then
                    if self.pathFinderFailures == EmptyHarvesterTask.MAX_PATHFINDER_FAILURES or self.pathFinderFailures % 30 == 0 then
                        print(string.format("[AD-Fin] %s: pas de trajet vers %s apres %d essais, il attend la et recalcule (mode Strict : jamais arrete)",
                            tostring(self.vehicle:getName()), tostring(self.combine:getName()), self.pathFinderFailures))
                    end
                    self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:notifyAboutFailedPathfinder()
                    pfm:reset()
                    pfm:startPathPlanningToPipe(self.combine, false)
                    EmptyHarvesterTask.allowPartial(self.vehicle)
                    pfm:addDelayTimer(EmptyHarvesterTask.STRICT_RETRY_DELAY)
                elseif pfm:isTargetBlocked() or self.pathFinderFailures >= EmptyHarvesterTask.MAX_PATHFINDER_FAILURES then
                    self:finished(ADTaskModule.DONT_PROPAGATE)
                    self.vehicle:stopAutoDrive()
                    AutoDriveMessageEvent.sendMessageOrNotification(self.vehicle, ADMessagesManager.messageTypes.WARN, "$l10n_AD_Driver_of; %s $l10n_AD_cannot_find_path; %s", 5000, self.vehicle.ad.stateModule:getName(), self.combine.ad.stateModule:getName())
                    return
                else
                    self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:notifyAboutFailedPathfinder()
                    self.vehicle.ad.pathFinderModule:reset()
                    self.vehicle.ad.pathFinderModule:startPathPlanningToPipe(self.combine, false)
                    EmptyHarvesterTask.allowPartial(self.vehicle)
                    self.vehicle.ad.pathFinderModule:addDelayTimer(10000)
                end
            else
                self.routeIsPartial = self.vehicle.ad.pathFinderModule.partialPath == true
                if not self.routeIsPartial then
                    self.vehicle.ad.fpParkBeforeRetry = nil
                end
                self.state = EmptyHarvesterTask.STATE_DRIVING
                return
            end
        else
            self.vehicle.ad.pathFinderModule:update(dt)
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
            return
        end
    elseif self.state == EmptyHarvesterTask.STATE_DRIVING then
        if self.routeIsPartial and self.vehicle.ad.drivePathModule:isTargetReached() then
            -- (15/11) bout du trajet partiel : on est au plus près, nouveau calcul vers la goulotte depuis ici
            self.routeIsPartial = false
            print(string.format("[AD-Fin] %s: au bout du trajet partiel, nouveau calcul vers %s",
                tostring(self.vehicle:getName()), tostring(self.combine:getName())))
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
            self.vehicle.ad.pathFinderModule:reset()
            self.vehicle.ad.pathFinderModule:startPathPlanningToPipe(self.combine, false)
            EmptyHarvesterTask.allowPartial(self.vehicle)
            self.state = EmptyHarvesterTask.STATE_PATHPLANNING
            return
        end
        if self.vehicle.ad.drivePathModule:isTargetReached() then
            if AutoDrive:getIsCPActive(self.combine) then
                self.vehicle.ad.specialDrivingModule:stopVehicle()
                self.vehicle.ad.specialDrivingModule:update(dt)
                self.waitTimer:timer(self.combine:getDischargeState() ~= Dischargeable.DISCHARGE_STATE_OFF, EmptyHarvesterTask.WAITING_FOR_PIPE, dt)
                if self.waitTimer:done() then
                    self.waitTimer:timer(false)
                    self.state = EmptyHarvesterTask.STATE_UNLOADING
                end
            else
                self.state = EmptyHarvesterTask.STATE_UNLOADING
            end
            return
        else
            self.vehicle.ad.drivePathModule:update(dt)
        end
    elseif self.state == EmptyHarvesterTask.STATE_UNLOADING then
        self.vehicle.ad.specialDrivingModule.motorShouldNotBeStopped = true
        -- Stopping CP drivers for now
        AutoDrive:holdCPCombine(self.combine)
        --Check if the combine is moving / has already moved away and we are supposed to actively unload
        if self.combine.ad.driveForwardTimer.elapsedTime > 100 then
            EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update driveForwardTimer.elapsedTime > 100")
            if AutoDrive.isVehicleOrTrailerInCrop(self.vehicle, true) then
                EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update isVehicleOrTrailerInCrop")
                self:finished()
                return
            elseif self.combine.ad.driveForwardTimer.elapsedTime > 4000 then
                EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update driveForwardTimer.elapsedTime > 4000")
                self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD].state = CombineUnloaderMode.STATE_ACTIVE_UNLOAD_COMBINE
                self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD].breadCrumbs = Queue:new()
                self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD].lastBreadCrumb = nil
                self.vehicle.ad.taskModule:addTask(FollowCombineTask:new(self.vehicle, self.combine))
                self.vehicle.ad.taskModule:setCurrentTaskFinished(ADTaskModule.DONT_PROPAGATE)
            end
        end

        local combineFillLevel, _, _ = AutoDrive.getObjectFillLevels(self.combine)

        EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update getDischargeState %s"
        , tostring(self.combine:getDischargeState())
        )
        if combineFillLevel > 0.1 and self.combine.getDischargeState ~= nil and self.combine:getDischargeState() ~= Dischargeable.DISCHARGE_STATE_OFF then
            EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update stopVehicle")
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
        else
            --Is the current trailer filled or is the combine empty?
            local _, _, filledToUnload = AutoDrive.getAllFillLevels(self.trailers)
            local distanceToCombine = AutoDrive.getDistanceBetween(self.vehicle, self.combine)

            if combineFillLevel <= 0.1 or filledToUnload then
                EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update STATE_UNLOADING_FINISHED")
                self.state = EmptyHarvesterTask.STATE_UNLOADING_FINISHED
                return
            else
                -- Drive forward with collision checks active and only for a limited distance
                if distanceToCombine > 30 then
                    EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update distanceToCombine > 30")
                    self:finished()
                    return
                elseif self.stopAtCutLine ~= nil and self:stopAtCutLine(dt) then
                    -- (16/11) moissonneuse : nez à la ligne de coupe, culture debout devant, il n'avance plus
                    -- (remplissage moins régulier accepté), voir CombineUnloaderModeCutLine.lua
                    return
                else
                    EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update driveForward")
                    self.vehicle.ad.specialDrivingModule:driveForward(dt)
                end
            end
        end
    elseif self.state == EmptyHarvesterTask.STATE_UNLOADING_FINISHED then
        EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:update - STATE_UNLOADING_FINISHED getIsCPCombineInPocket %s", tostring(AutoDrive:getIsCPCombineInPocket(self.combine)))
        if AutoDrive:getIsCPCombineInPocket(self.combine) or AutoDrive.combineIsTurning(self.combine) then
            -- reverse if CP unload in a pocket or pullback position
            -- reverse if combine is turning
            local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
            self.reverseStartLocation = {x = x, y = y, z = z}
            self.state = EmptyHarvesterTask.STATE_REVERSING
            return
        else
            self.state = EmptyHarvesterTask.STATE_WAITING
            return
        end
    elseif self.state == EmptyHarvesterTask.STATE_REVERSING then
        self.vehicle.ad.specialDrivingModule.motorShouldNotBeStopped = false
        local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
        local distanceToReversStart = MathUtil.vector2Length(x - self.reverseStartLocation.x, z - self.reverseStartLocation.z)
        local overallLength
        if self.trailerCount <= 1 then
            overallLength = math.max(self.vehicle.size.length * 2, 15) -- 2x tractor length, min. 15m
        else
            overallLength = self.tractorTrainLength -- complete train length
        end
        if AutoDrive:getIsCPActive(self.combine) or self.combine:getIsAIActive() then
            -- if CP harvester
            overallLength = overallLength + AutoDrive.getFrontToolWidth(self.combine)
        end
        if self.combine.trailingVehicle ~= nil then
            -- if the harvester is trailed reverse 5m more
            -- overallLength = overallLength + 5
        end
        self.holdCPCombineTimer:timer(true, EmptyHarvesterTask.REVERSE_TIME, dt)
        if not self.holdCPCombineTimer:done() then
            -- Stopping CP drivers while reverse driving
            AutoDrive:holdCPCombine(self.combine)
        end
        self.reverseTimer:timer(true, EmptyHarvesterTask.REVERSE_TIME, dt)
        if (distanceToReversStart > overallLength) or self.reverseTimer:done() then
            self.state = EmptyHarvesterTask.STATE_WAITING
            return
        else
            self.vehicle.ad.specialDrivingModule:driveReverse(dt, 10, 1, self.vehicle.ad.trailerModule:canBeHandledInReverse())
        end
    elseif self.state == EmptyHarvesterTask.STATE_WAITING then
        local waitTime = EmptyHarvesterTask.WAITING_TIME
        if AutoDrive:getIsCPActive(self.combine) or self.combine:getIsAIActive() then
            -- wait some more time to let CP combine move away
            waitTime = 3 * EmptyHarvesterTask.WAITING_TIME
        end
        self.waitTimer:timer(true, waitTime, dt)
        if self.waitTimer:done() or AutoDrive.isVehicleOrTrailerInCrop(self.vehicle, true) then
            self:finished()
            return
        else
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
            return
        end
    end
end

function EmptyHarvesterTask:abort()
end

function EmptyHarvesterTask:finished(propagate)
    EmptyHarvesterTask.debugMsg(self.vehicle, "EmptyHarvesterTask:finished()")
    self.vehicle.ad.specialDrivingModule.motorShouldNotBeStopped = false
    self.vehicle.ad.taskModule:setCurrentTaskFinished(propagate)
end

function EmptyHarvesterTask:getExcludedVehiclesForCollisionCheck()
    local excludedVehicles = {}
    if self.state == EmptyHarvesterTask.STATE_DRIVING then
        table.insert(excludedVehicles, self.combine:getRootVehicle())
    end
    return excludedVehicles
end

function EmptyHarvesterTask:setStateNames()
    if self.statesToNames == nil then
        self.statesToNames = {}
        for name, id in pairs(EmptyHarvesterTask) do
            if string.sub(name, 1, 6) == "STATE_" then
                self.statesToNames[id] = name
            end
        end
    end
end

function EmptyHarvesterTask:getStateName(state)
    local requestedState = state
    if requestedState == nil then
        requestedState = self.state
    end
    if requestedState == nil then
        Logging.error("[AD] EmptyHarvesterTask: Could not find name for state ->%s<- !", tostring(requestedState))
    end
    return self.statesToNames[requestedState] or ""
end

function EmptyHarvesterTask:resetAllTimers()
    -- self.stuckTimer:timer(false) -- stuckTimer reset by speed changes
    self.reverseTimer:timer(false)
    self.waitTimer:timer(false)
    self.holdCPCombineTimer:timer(false)
end

function EmptyHarvesterTask:getI18nInfo()
    local text = "$l10n_AD_task_unloading_combine;"
    if self.state == EmptyHarvesterTask.STATE_PATHPLANNING then
        text = text .. " - " .. self:getPlanningI18n()
    elseif self.state == EmptyHarvesterTask.STATE_DRIVING then
        text = text .. " - " .. "$l10n_AD_task_drive_to_combine_pipe;"
    elseif self.state == EmptyHarvesterTask.STATE_UNLOADING then
        text = text .. " - " .. "$l10n_AD_task_unloading_combine;"
    elseif self.state == EmptyHarvesterTask.STATE_REVERSING then
        text = text .. " - " .. "$l10n_AD_task_reversing_from_combine;"
    elseif self.state == EmptyHarvesterTask.STATE_WAITING then
        text = text .. " - " .. "$l10n_AD_task_waiting_for_room;"
    end
    return text 
end

function EmptyHarvesterTask.debugMsg(vehicle, debugText, ...)
    if EmptyHarvesterTask.debug == true then
        AutoDrive.debugMsg(vehicle, debugText, ...)
    else
        AutoDrive.debugPrint(vehicle, AutoDrive.DC_COMBINEINFO, debugText, ...)
    end
end
