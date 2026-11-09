CatchCombinePipeTask = ADInheritsFrom(AbstractTask)
CatchCombinePipeTask.debug = false

CatchCombinePipeTask.TARGET_DISTANCE = 15

CatchCombinePipeTask.STATE_PATHPLANNING = {}
CatchCombinePipeTask.STATE_DRIVING = {}
CatchCombinePipeTask.STATE_REVERSING = {}
CatchCombinePipeTask.STATE_DELAY_PATHPLANNING = {}
CatchCombinePipeTask.STATE_WAIT_BEFORE_FINISH = {}
CatchCombinePipeTask.STATE_FINISHED = {}

CatchCombinePipeTask.MAX_REVERSE_DISTANCE = 18
CatchCombinePipeTask.MIN_COMBINE_DISTANCE = 25
CatchCombinePipeTask.MAX_REVERSE_TIME = 5000
CatchCombinePipeTask.MAX_STUCK_TIME = 60000
CatchCombinePipeTask.MAX_COUNT_NEW_PATHFINDING = 20

-- ------------------------------------------------------------------------------------------------------------
-- FarmPilot : ce fichier reste celui d'AutoDrive, avec des lignes d'accroche (commentées « voir … »).
-- Les ajouts sont rangés par sujet dans des fichiers chargés juste après celui-ci (register.lua) :
--   commun (moissonneuse et ensileuse) :
--     CatchCombinePipeTaskClear.lua         laisser passer la machine, aucun trajet : solutions de repli, reculer
--     CatchCombinePipeTaskHandover.lua      la poursuite prend la main (départ direct : commun ; le reste : ensileuse)
--   ensileuse (la benne roule à côté d'elle en continu) :
--     CatchCombinePipeTaskChopperRoute.lua  trajet en morceaux, attente entre deux calculs, sa trace, reculs
--     CatchCombinePipeTaskChopperUTurn.lua  demi-tours : bande, bout de rang, à l'envers, trajet court inutile
-- Lignes d'origine modifiées sur place : départ direct (setUp), attente variable entre deux calculs
-- (STATE_DELAY_PATHPLANNING, addDelayTimer(6000) retiré), arrivée (angle maxAngle, derrière l'ensileuse) ; textes
-- d'état réécrits (getI18nInfo) ; startNewPathFinding garde ses lignes FarmPilot commentées.
-- ------------------------------------------------------------------------------------------------------------

function CatchCombinePipeTask:new(vehicle, combine)
    local o = CatchCombinePipeTask:create()
    o.vehicle = vehicle
    o.combine = combine
    o.state = CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
    o.wayPoints = nil
    o.stuckTimer = AutoDriveTON:new()
    o.reverseTimer = AutoDriveTON:new()
    o.waitTimer = AutoDriveTON:new()
    o.waitForCheckTimer = AutoDriveTON:new()
    o.waitForCheckTimer.elapsedTime = 4000
    o.taskType = "CatchCombinePipeTask"
    o.newPathFindingCounter = 0
    o.retryDelay = CatchCombinePipeTask.RETRY_DELAY_MIN -- ensileuse : attente entre deux calculs, voir CatchCombinePipeTaskChopperRoute.lua
    o.trailers = nil
    CatchCombinePipeTask.setStateNames(o)
    return o
end

function CatchCombinePipeTask:setUp()
    CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:setUp()")
    local angleToCombineHeading = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombineHeading()
    local angleToCombine = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombine()

    if angleToCombineHeading < 35 and angleToCombine < 90 and AutoDrive.getDistanceBetween(self.vehicle, self.combine) < 60
        and not self.combine.ad.isFixedPipeChopper then
        if self:isStraightLineFree() then self:finished() end -- seulement si la ligne droite est libre, voir CatchCombinePipeTaskHandover.lua
    end
    self.trailers, _ = AutoDrive.getAllUnits(self.vehicle)
    AutoDrive.setTrailerCoverOpen(self.vehicle, self.trailers, true)
end

function CatchCombinePipeTask:update(dt)
    if self.combine ~= nil and g_currentMission.nodeToObject[self.combine.components[1].node] == nil then
        self:finished()
        return
    end
    if self.lastState ~= self.state then
        CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update %s -> %s", tostring(self:getStateName(self.lastState)), tostring(self:getStateName()))
        self.lastState = self.state
        self:resetAllTimers()
    end
    self:sampleCombineHeading() -- ensileuse : cap de la machine, voir CatchCombinePipeTaskChopperUTurn.lua

    if self:updateBandTurnState(dt) then return end -- ensileuse : demi-tour dans la bande, voir CatchCombinePipeTaskChopperUTurn.lua

    -- 25/10: called while a full unloader drives out by the entrance where this one waited: it lets it out first
    if (self.state == CatchCombinePipeTask.STATE_DELAY_PATHPLANNING or self.state == CatchCombinePipeTask.STATE_DRIVING)
        and ADFieldPark.holdForExit(self.vehicle, dt, "a l'entree") then
        return
    end

    local checkForStuck = (self.vehicle.lastSpeedReal <= 0.0002) and (
        self.state == CatchCombinePipeTask.STATE_DRIVING
    )

    if self:updateVehicleBlocked(dt, checkForStuck) then return end -- ensileuse : arrêté contre un véhicule, voir CatchCombinePipeTaskChopperRoute.lua

    self.stuckTimer:timer(checkForStuck, self.MAX_STUCK_TIME, dt)
    if self.stuckTimer:done()
        -- or AutoDrive.getDistanceBetween(self.vehicle, self.combine) < self.MIN_COMBINE_DISTANCE 
        then
        -- got stuck or to close to combine -> reverse
        CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update - STATE_DRIVING stuck")
        self.stuckTimer:timer(false)
        local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
        self.reverseStartLocation = {x = x, y = y, z = z}
        self.state = CatchCombinePipeTask.STATE_REVERSING
        return
    end

    if self:checkClearWay() then return end -- dans la voie de la machine : se dégager, voir CatchCombinePipeTaskClear.lua

    if self:checkBesideInPlace() then return end -- ensileuse : déjà à côté d'elle, voir CatchCombinePipeTaskHandover.lua

    if self:checkEndRowUTurn() then return end -- ensileuse : demi-tour de bout de rang, voir CatchCombinePipeTaskChopperUTurn.lua

    if self:updateClearWayStates(dt) then return end -- se dégager, laisser passer, voir CatchCombinePipeTaskClear.lua

    if self:checkCloseRangeBandTurn() then return end -- ensileuse : poursuite bloquée, demi-tour dans la bande, voir CatchCombinePipeTaskChopperUTurn.lua

    if self:checkCloseRange() then return end -- ensileuse proche : la poursuite prend la main, voir CatchCombinePipeTaskHandover.lua
    -- états ajoutés, retirés de la machine à états ci-dessous :
    if self:updateNoRouteStates(dt) then return end -- reculer tout droit, arrêt sans issue, voir CatchCombinePipeTaskClear.lua
    if self:updateOpenReverseState(dt) then return end -- ensileuse : recul pour ouvrir l'angle, voir CatchCombinePipeTaskChopperRoute.lua

    if self.state == CatchCombinePipeTask.STATE_PATHPLANNING then
        if self.vehicle.ad.pathFinderModule:hasFinished() then
            CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update - STATE_PATHPLANNING finished")
            self.newPathFindingCounter = 0
            self.wayPoints = self.vehicle.ad.pathFinderModule:getPath()
            self:checkGuidedDeparture() -- ensileuse : aucun chemin, départ guidé, voir CatchCombinePipeTaskChopperRoute.lua
            if self.wayPoints == nil or #self.wayPoints < 1 then
                --restart
                self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:notifyAboutFailedPathfinder()
                if self:tryNoRouteFallbacks() then return end -- aucun trajet : solutions de repli, voir CatchCombinePipeTaskClear.lua
                --AutoDriveMessageEvent.sendMessageOrNotification(self.vehicle, ADMessagesManager.messageTypes.WARN, "$l10n_AD_Driver_of; %s $l10n_AD_cannot_find_path; %s", 5000, self.vehicle.ad.stateModule:getName(), self.combine.ad.stateModule:getName())
                CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update - STATE_PATHPLANNING restarting path finder - with delay")
                self.state = CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
                return
            else
                if self:refuseUselessRoute() then return end -- ensileuse : trajet court inutile refusé, voir CatchCombinePipeTaskChopperUTurn.lua
                self:onRouteFound() -- trajet trouvé : compteurs remis à zéro, voir CatchCombinePipeTaskClear.lua
                self.vehicle.ad.drivePathModule:setWayPoints(self.wayPoints)
                self.state = CatchCombinePipeTask.STATE_DRIVING
                return
            end
        else
            self.vehicle.ad.pathFinderModule:update(dt)
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
            return
        end
    elseif self.state == CatchCombinePipeTask.STATE_DELAY_PATHPLANNING then
        CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update - STATE_DELAY_PATHPLANNING")
        if self.waitForCheckTimer:timer(true, self.retryDelay or CatchCombinePipeTask.RETRY_DELAY_MIN, dt) then -- attente variable (ensileuse), voir CatchCombinePipeTaskChopperRoute.lua
            if self.newPathFindingCounter > self.MAX_COUNT_NEW_PATHFINDING then
                -- prevent deadlock
                self.state = CatchCombinePipeTask.STATE_FINISHED
                return
            end
            if self:startNewPathFinding() then
                -- FarmPilot : l'appel d'origine pathFinderModule:addDelayTimer(6000) a été retiré ici
                self.state = CatchCombinePipeTask.STATE_PATHPLANNING
                return
            end
        end        
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return
    elseif self.state == CatchCombinePipeTask.STATE_DRIVING then
        -- check if this is still a clever path to follow
        -- do this by distance of the combine to the last location pathfinder started at
        local x, y, z = getWorldTranslation(self.combine.components[1].node)
        local combineTravelDistance = MathUtil.vector2Length(x - self.combinesStartLocation.x, z - self.combinesStartLocation.z)

        if combineTravelDistance > 85 then
            CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update - combine travelled - recalculate path")
            self.preplanning = false -- ensileuse : morceau suivant abandonné, voir CatchCombinePipeTaskChopperRoute.lua
            self.waitForCheckTimer.elapsedTime = 4000
            self.state = CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
            return
        else
            if self:checkPreplannedEnd() then return end -- ensileuse : fin d'un morceau, le suivant en calcul, voir CatchCombinePipeTaskChopperRoute.lua
            if self.vehicle.ad.drivePathModule:isTargetReached() then
                -- check if we have actually reached the target or not
                -- accept current location if we are in a good position to start chasing: distance and angle are important here
                CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update - STATE_DRIVING TargetReached")
                local angleToCombine = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombineHeading()
                local isCorrectSide = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:isUnloaderOnCorrectSide()
                -- ensileuse : sur sa trace en courbe, angle admis plus grand, côté libre derrière elle : voir CatchCombinePipeTaskHandover.lua
                local maxAngle
                angleToCombine, isCorrectSide, maxAngle = self:checkChopperArrival(angleToCombine, isCorrectSide)
                if angleToCombine < maxAngle and AutoDrive.getDistanceBetween(self.vehicle, self.combine) < 80 and isCorrectSide and self:isBehindChopper() then
                    CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update - STATE_DRIVING -> STATE_FINISHED")
                    self:noteHandover() -- ensileuse : passages de main au même endroit, voir CatchCombinePipeTaskHandover.lua
                    self.state = CatchCombinePipeTask.STATE_FINISHED
                    return
                else
                    if self:onArrivalNotHandedOver(dt, angleToCombine, isCorrectSide) then return end -- ensileuse : attente, demi-tour, essais, voir CatchCombinePipeTaskHandover.lua
                    CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update - angle or distance to combine too high - recalculate path now")
                    self.state = CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
                    return
                end
            else
                self.vehicle.ad.drivePathModule:update(dt)
                self:updatePreplanning(dt) -- ensileuse : morceau suivant du trajet, voir CatchCombinePipeTaskChopperRoute.lua
            end
        end
    elseif self.state == CatchCombinePipeTask.STATE_REVERSING then
        local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
        local distanceToReverseStart = MathUtil.vector2Length(x - self.reverseStartLocation.x, z - self.reverseStartLocation.z)
        self.reverseTimer:timer(true, self.MAX_REVERSE_TIME, dt)
        if distanceToReverseStart > self.MAX_REVERSE_DISTANCE or self.reverseTimer:done() then
            self.state = CatchCombinePipeTask.STATE_WAIT_BEFORE_FINISH
            return
        else
            self.vehicle.ad.specialDrivingModule:driveReverse(dt, 15, 1, self.vehicle.ad.trailerModule:canBeHandledInReverse())
        end
    elseif self.state == CatchCombinePipeTask.STATE_WAIT_BEFORE_FINISH then
        CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update - STATE_WAIT_BEFORE_FINISH")
        self.waitTimer:timer(true, self.MAX_REVERSE_TIME, dt)
        if self.waitTimer:done() then
            self.state = CatchCombinePipeTask.STATE_FINISHED
            return
        else
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
            return
        end
    elseif self.state == CatchCombinePipeTask.STATE_FINISHED then
        CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:update - STATE_FINISHED")
        self:finished()
        return
    end
end

function CatchCombinePipeTask:abort()
    ADBandTurn.abort(self.vehicle) -- demi-tour dans la bande arrêté (BandTurnModule.lua)
end

function CatchCombinePipeTask:finished(propagate)
    CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:finished()")
    self.vehicle.ad.taskModule:setCurrentTaskFinished(propagate)
end

function CatchCombinePipeTask:startNewPathFinding()
    self.infoOnTrail = false -- status text
    CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:startNewPathFinding()")
    local pipeChasePos, pipeChaseSide = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getPipeChasePosition(true)
    local x, _, z = getWorldTranslation(self.combine.components[1].node)
    local targetFieldId = g_farmlandManager:getFarmlandIdAtWorldPosition(pipeChasePos.x, pipeChasePos.z)
    local combineFieldId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)

    -- Only chase the rear on low fill levels of the combine. This should prevent getting into unneccessarily tight spots for the final approach to the pipe.
    -- Also for small fields, there is often no purpose in chasing so far behind the combine as it will already start a turn soon

    local cfillLevel, cfillCapacity, _, cfillFreeCapacity = AutoDrive.getObjectFillLevels(self.combine)
    local cFillRatio = cfillCapacity > 0 and cfillLevel / cfillCapacity or 0

    if cFillRatio > 0.91 or cfillFreeCapacity < 0.1 then
        CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:startNewPathFinding() - Combine is almost full - dont chase for active unloading anymore")
        self:finished(ADTaskModule.DONT_PROPAGATE)
        self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:setToWaitForCall()
        return false
    end

    self.newPathFindingCounter = self.newPathFindingCounter + 1 -- used to prevent deadlock

    if self.combine.ad.isChopper or (pipeChaseSide ~= AutoDrive.CHASEPOS_REAR or (targetFieldId == combineFieldId and cFillRatio <= 0.85)) then
    -- if self.combine:getIsBufferCombine() or (pipeChaseSide ~= AutoDrive.CHASEPOS_REAR and targetFieldId == combineFieldId and cFillRatio <= 0.85) then
        -- is chopper or chase not rear and harvester on correct field and filled < 85% - i.e. combine pipe not in fruit
        CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:startNewPathFinding() - chase pos looks good - calculate path to it...")
        self.vehicle.ad.pathFinderModule:reset()
        -- next piece of a route: planned from the end of the piece being driven
        self.vehicle.ad.pathFinderModule.startPose = self.nextStartPose
        self.vehicle.ad.pathFinderModule.edgeOnly = self.edgeOnly == true
        self.vehicle.ad.pathFinderModule:startPathPlanningToPipe(self.combine, false)
        -- use false to enable pathfinder fallback
        -- no clean route in strict: drive part of the way, this task plans again on arrival
        self.vehicle.ad.pathFinderModule.allowPartialPath = true
        self.combinesStartLocation = {}
        self.combinesStartLocation.x, self.combinesStartLocation.y, self.combinesStartLocation.z = getWorldTranslation(self.combine.components[1].node)
        return true
    else
        CatchCombinePipeTask.debugMsg(self.vehicle, "CatchCombinePipeTask:startNewPathFinding() - chase pos looks bad, is not on the same field or combine's fill level is approaching limit - aborting for now")
        self.waitForCheckTimer:timer(false)
    end
    return false
end

function CatchCombinePipeTask:getExcludedVehiclesForCollisionCheck()
    local excludedVehicles = {}
    if self.state == CatchCombinePipeTask.STATE_DRIVING then
        table.insert(excludedVehicles, self.combine:getRootVehicle())
    end
    return excludedVehicles
end

function CatchCombinePipeTask:setStateNames()
    if self.statesToNames == nil then
        self.statesToNames = {}
        for name, id in pairs(CatchCombinePipeTask) do
            if string.sub(name, 1, 6) == "STATE_" then
                self.statesToNames[id] = name
            end
        end
    end
end

function CatchCombinePipeTask:getStateName(state)
    local requestedState = state
    if requestedState == nil then
        requestedState = self.state
    end
    if requestedState == nil then
        Logging.error("[AD] CatchCombinePipeTask: Could not find name for state ->%s<- !", tostring(requestedState))
    end
    return self.statesToNames[requestedState] or ""
end

function CatchCombinePipeTask:resetAllTimers()
    -- self.stuckTimer:timer(false) -- stuckTimer reset by speed changes
    self.reverseTimer:timer(false)
    self.waitTimer:timer(false)
    self.waitForCheckTimer:timer(false)
end

-- textes d'état : réécrits par FarmPilot (machine nommée, attentes, reculs, demi-tours)
function CatchCombinePipeTask:getI18nInfo()
    local harvester = AbstractTask.getHarvesterI18n(self.combine)
    if self.state == CatchCombinePipeTask.STATE_PATHPLANNING then
        return "$l10n_AD_task_plan_to; " .. harvester
    elseif self.state == CatchCombinePipeTask.STATE_DELAY_PATHPLANNING then
        if self.handoverWaitPrinted and (self.handoverTries or 0) >= CatchCombinePipeTask.HANDOVER_TRIES
            and AutoDrive.getDistanceBetween(self.vehicle, self.combine) < CatchCombinePipeTask.HANDOVER_DISTANCE then
            return "$l10n_AD_task_near; " .. harvester .. ", $l10n_AD_task_wait_behind;"
        elseif self.infoNoPath then
            local left = math.max(0, (self.retryDelay or CatchCombinePipeTask.RETRY_DELAY_MIN) - (self.waitForCheckTimer.elapsedTime or 0))
            return "$l10n_AD_task_no_path_retry;" .. string.format(" %d s", math.ceil(left / 1000))
        end
        return "$l10n_AD_task_plan_to; " .. harvester
    elseif self.state == CatchCombinePipeTask.STATE_DRIVING then
        if self.infoAnticipatedWaitAt ~= nil and (g_time or 0) - self.infoAnticipatedWaitAt < 1000 then
            return "$l10n_AD_task_wait_row_entry; " .. harvester
        elseif self.infoOnTrail then
            return "$l10n_AD_task_follow_trail; " .. harvester
        elseif self.preplanning then
            return "$l10n_AD_task_drive_to; " .. harvester .. ", $l10n_AD_task_plan_next;"
        end
        return "$l10n_AD_task_drive_to; " .. harvester .. string.format(" (%d m)", math.floor(AutoDrive.getDistanceBetween(self.vehicle, self.combine)))
    elseif self.state == CatchCombinePipeTask.STATE_OPEN_REVERSE then
        local info = self.infoReverse or {distance = CatchCombinePipeTask.OPEN_REVERSE_DISTANCE}
        if info.blocked then
            return "$l10n_AD_task_blocked_reverse;" .. string.format(" %d m", math.floor(info.distance + 0.5))
        end
        return "$l10n_AD_task_reverse_by;" .. string.format(" %d m ", math.floor(info.distance + 0.5)) .. "$l10n_AD_task_tracks_open_angle;"
    elseif self.state == CatchCombinePipeTask.STATE_BAND_TURN then
        if self.infoEndRowTurn then
            return "$l10n_AD_task_end_row_turn;"
        end
        return "$l10n_AD_task_band_turn_rescue;"
    elseif self.state == CatchCombinePipeTask.STATE_CLEAR_BACK then
        local cb = self.vehicle.ad.clearBack
        return "$l10n_AD_task_clear_back;" .. string.format(" (%d m)", math.floor((cb ~= nil and cb.total or 0) + (self.clearBackLeg or 0) + 0.5))
    elseif self.state == CatchCombinePipeTask.STATE_NO_WAY_WAIT then
        return "$l10n_AD_task_no_way_stopped;"
    elseif self.state == CatchCombinePipeTask.STATE_CLEAR_WAY then
        return "$l10n_AD_task_clear_way_for; " .. harvester
    elseif self.state == CatchCombinePipeTask.STATE_WAIT_PASS_BY then
        return "$l10n_AD_task_let_pass; " .. harvester
    elseif self.state == CatchCombinePipeTask.STATE_REVERSING then
        return "$l10n_AD_task_stuck_reverse;"
    elseif self.state == CatchCombinePipeTask.STATE_WAIT_BEFORE_FINISH then
        return "$l10n_AD_task_waiting_for_room;"
    end
    return "$l10n_AD_task_drive_to; " .. harvester
end

function CatchCombinePipeTask.debugMsg(vehicle, debugText, ...)
    if CatchCombinePipeTask.debug == true then
        AutoDrive.debugMsg(vehicle, debugText, ...)
    else
        AutoDrive.debugPrint(vehicle, AutoDrive.DC_COMBINEINFO, debugText, ...)
    end
end
