ADDrivePathModule = {}

ADDrivePathModule.LOOKAHEADDISTANCE = 20
ADDrivePathModule.MAXLOOKAHEADPOINTS = 20
ADDrivePathModule.MAX_SPEED_DEVIATION = 6
ADDrivePathModule.MAX_STEERING_ANGLE = 30
ADDrivePathModule.PAUSE_TIMEOUT = 3000
ADDrivePathModule.BLINK_TIMEOUT = 1000

function ADDrivePathModule:new(vehicle)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.vehicle = vehicle
    o.min_distance = AutoDrive.defineMinDistanceByVehicleType(vehicle)
    o.minDistanceTimer = AutoDriveTON:new()
    o.waitTimer = AutoDriveTON:new()
    o.blinkTimer = AutoDriveTON:new()
    o.brakeHysteresisActive = false
    o.lastUsedWayPoint = nil
    ADDrivePathModule.reset(o)
    return o
end

function ADDrivePathModule:reset(retainLastUsedWaypoint)
    if self.vehicle.spec_locomotive and self.vehicle.ad and self.vehicle.ad.trainModule then
        -- train
        self.vehicle.ad.trainModule:reset()
        return
    end
    self.turnAngle = 0
    self.isPaused = false
    self.atTarget = false
    self.wayPoints = nil
    self.currentWayPoint = 0
    if ADIntersectionModule ~= nil and self.vehicle.ad ~= nil then
        ADIntersectionModule.reset(self.vehicle)
    end
    self.onRoadNetwork = true
    self.minDistanceToNextWp = math.huge
    self.minDistanceTimer:timer(false, 5000, 0)
    self.waitTimer:timer(false, ADDrivePathModule.PAUSE_TIMEOUT, 0)
    self.blinkTimer:timer(false, ADDrivePathModule.BLINK_TIMEOUT, 0)
    self.vehicle.ad.stateModule:setCurrentWayPointId(-1)
    self.vehicle.ad.stateModule:setNextWayPointId(-1)
    self.isReversing = false
    self.vehicle:setTurnLightState(Lights.TURNLIGHT_OFF)
    self.distanceToTarget = math.huge
    self.speedLimit = 0
    -- skip resetting last used waypoint to resume looping courses from prior destination
    if not retainLastUsedWaypoint then
        self.lastUsedWayPoint = nil
    end
    -- increase steering speed
    if self.vehicle.spec_aiJobVehicle ~= nil then
        self.vehicle.spec_aiJobVehicle.aiSteeringSpeed = 0.004
    end
    self.min_lookAhead = AutoDrive.getMinLookaheadByVehicleType(self.vehicle)
    if self.vehicle.ad ~= nil and self.vehicle.ad.obstacleDetourModule ~= nil then
        self.vehicle.ad.obstacleDetourModule:reset()
    end
    if self.vehicle.ad ~= nil and self.vehicle.ad.approachModule ~= nil then
        self.vehicle.ad.approachModule:reset()
    end
    if self.vehicle.ad ~= nil and self.vehicle.ad.avoidModule ~= nil then
        self.vehicle.ad.avoidModule:reset()
    end
    if self.vehicle.ad ~= nil and self.vehicle.ad.cornerModule ~= nil then
        self.vehicle.ad.cornerModule:reset()
    end
    self.lateralOffset = 0
    self.pushX = nil
end

function ADDrivePathModule:setPathTo(wayPointId)
    self:reset(self.atTarget)
    self.wayPoints = ADGraphManager:getPathTo(self.vehicle, wayPointId, self.lastUsedWayPoint)
    -- sharp corners replaced by arcs of the real turning radius (ADCornerModule); the first points stay as they are
    if self.wayPoints ~= nil and #self.wayPoints >= 3 and self.vehicle.ad.cornerModule ~= nil then
        self.wayPoints = self.vehicle.ad.cornerModule:smoothRoute(self.wayPoints, 3)
    end
    self.wayPoints = ADDrivePathModule.shiftAroundObstacles(self.vehicle, self.wayPoints, 2)
    local destination = ADGraphManager:getMapMarkerByWayPointId(self:getLastWayPointId())
    self.vehicle.ad.stateModule:setCurrentDestination(destination)
    self:setDirtyFlag()
    self.minDistanceToNextWp = math.huge

    if self.wayPoints == nil or (self.wayPoints[2] == nil and (self.wayPoints[1] == nil or (self.wayPoints[1] ~= nil and self.wayPoints[1].id ~= wayPointId))) then
        self.vehicle.ad.isStoppingWithError = true
        Logging.devError("[AutoDrive] Encountered a problem during initialization 'setPathTo'")

        local target = self.vehicle.ad.stateModule:getFirstMarker().name
        local mapMarker = ADGraphManager:getMapMarkerByWayPointId(wayPointId)
        if mapMarker ~= nil and mapMarker.name ~= nil then
            target = mapMarker.name
        end

        AutoDriveMessageEvent.sendMessageOrNotification(self.vehicle, ADMessagesManager.messageTypes.ERROR, "$l10n_AD_Driver_of; %s $l10n_AD_cannot_reach; %s", 5000, self.vehicle.ad.stateModule:getName(), target)
        self.vehicle.ad.taskModule:abortAllTasks()
        self.vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(self.vehicle))
    else
        --skip first wp for a smoother start
        if self.wayPoints[2] ~= nil then
            self:setCurrentWayPointIndex(2)
        else
            self:setCurrentWayPointIndex(1)
        end

        if not self.vehicle.ad.trailerModule:isActiveAtTrigger() then
            self:setUnPaused()
        end

        self.atTarget = false
    end
    self:resetIsReversing()
end

function ADDrivePathModule:appendPathTo(startWayPointId, wayPointId)
    local appendWayPoints = ADGraphManager:getPathTo(self.vehicle, wayPointId)
    if appendWayPoints ~= nil and #appendWayPoints >= 3 and self.vehicle.ad.cornerModule ~= nil then
        appendWayPoints = self.vehicle.ad.cornerModule:smoothRoute(appendWayPoints, 2)
    end
    appendWayPoints = ADDrivePathModule.shiftAroundObstacles(self.vehicle, appendWayPoints, 2)

    if appendWayPoints == nil or (appendWayPoints[2] == nil and (appendWayPoints[1] == nil or (appendWayPoints[1] ~= nil and appendWayPoints[1].id ~= wayPointId))) then
        self.vehicle.ad.isStoppingWithError = true
        Logging.devError("[AutoDrive] Encountered a problem during initialization 'appendPathTo'")

        local target = self.vehicle.ad.stateModule:getFirstMarker().name
        local mapMarker = ADGraphManager:getMapMarkerByWayPointId(wayPointId)
        if mapMarker ~= nil and mapMarker.name ~= nil then
            target = mapMarker.name
        end

        AutoDriveMessageEvent.sendMessageOrNotification(self.vehicle, ADMessagesManager.messageTypes.ERROR, "$l10n_AD_Driver_of; %s $l10n_AD_cannot_reach; %s", 5000, self.vehicle.ad.stateModule:getName(), target)
        self.vehicle.ad.taskModule:abortAllTasks()
        self.vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(self.vehicle))
    else
        --skip first wp for a smoother start
        for _, wp in ipairs(appendWayPoints) do
            table.insert(self.wayPoints, wp)
        end
    end
    self:resetIsReversing()
end

-- (08/11) a pole or a post on the network line: the route is moved beside it when it is set
-- (ADPathCalculator.shiftAroundObstacles); any error leaves the route as it was
function ADDrivePathModule.shiftAroundObstacles(vehicle, wayPoints, firstIndex)
    if wayPoints == nil or #wayPoints < 3 or ADPathCalculator.shiftAroundObstacles == nil then
        return wayPoints
    end
    local ok, shifted = pcall(ADPathCalculator.shiftAroundObstacles, vehicle, wayPoints, firstIndex)
    if not ok then
        print(string.format("[AD-Poteau] %s: error %s, route kept", tostring(vehicle.getName ~= nil and vehicle:getName() or "?"), tostring(shifted)))
        return wayPoints
    end
    return shifted or wayPoints
end

function ADDrivePathModule:setWayPoints(wayPoints)
    self:reset()
    self.wayPoints = wayPoints
    local destination = ADGraphManager:getMapMarkerByWayPointId(self:getLastWayPointId())
    self.vehicle.ad.stateModule:setCurrentDestination(destination)
    self.minDistanceToNextWp = math.huge
    self.atTarget = false
    if self.wayPoints[2] ~= nil then
        self:setCurrentWayPointIndex(2)
    else
        self:setCurrentWayPointIndex(1)
    end
    self:resetIsReversing()
    if self.wayPoints == nil or #self.wayPoints < 0 then
        self.atTarget = true
    end
    self.speedLimit = self.vehicle.ad.stateModule:getSpeedLimit()
    self.distanceToTarget = self:getDistanceToLastWaypoint(40)
end

function ADDrivePathModule:setPaused()
    self.isPaused = true
    self.waitTimer:timer(false)
end

function ADDrivePathModule:setUnPaused()
    self.isPaused = false
end

function ADDrivePathModule:setDirtyFlag()
    self.wayPointsDirtyFlag = true
end

function ADDrivePathModule:resetDirtyFlag()
    self.wayPointsDirtyFlag = false
end

function ADDrivePathModule:update(dt)
    if self.vehicle.spec_locomotive and self.vehicle.ad and self.vehicle.ad.trainModule then
        -- train new
        self.vehicle.ad.trainModule:update(dt)
        return
    end
    if self.waitTimer:timer(self.isPaused, ADDrivePathModule.PAUSE_TIMEOUT, dt) then        -- used to wait for the CP silo compacter
        self:setUnPaused()
    end
    if self.isPaused then
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return
    end

    if self.wayPoints ~= nil and self:getCurrentWayPointIndex() <= #self.wayPoints then
        if self.isReversing then
            self.vehicle.ad.specialDrivingModule:handleReverseDriving(dt)
        else
            self:followWaypoints(dt)
            if (self.vehicle.ad.trafficYieldModule == nil or not self.vehicle.ad.trafficYieldModule:isControlling())
                and (self.vehicle.ad.obstacleDetourModule == nil or not self.vehicle.ad.obstacleDetourModule:isControlling())
                and (self.vehicle.ad.intersection == nil or self.vehicle.ad.intersection.retreat == nil) then
                self:checkIfStuck(dt)
            end

            if self:isCloseToWaypoint() then
                self:handleReachedWayPoint()
            end
        end

        self:checkActiveAttributesSet(dt)
    else
        --keep calling the reverse function as it is also handling the bunkersilo unload, even after reaching the target
        if self.isReversing then
            self.vehicle.ad.specialDrivingModule:handleReverseDriving(dt)
        end
    end
end

function ADDrivePathModule:getIsReversing()
    return self.isReversing
end

function ADDrivePathModule:resetIsReversing()
    self.isReversing = false
    self.vehicle.ad.specialDrivingModule:reset()
end

function ADDrivePathModule:isCloseToWaypoint()
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    if self.vehicle.getAISteeringNode ~= nil then
        x, _, z = getWorldTranslation(self.vehicle:getAISteeringNode())
    end

    local maxSkipWayPoints = 1
    local wp_ahead = self:getNextWayPoint()
    local wp_current = self:getCurrentWayPoint()
    local _, isLastForward, isLastReverse = self:checkForReverseSection()
    if isLastForward or isLastReverse or (wp_ahead ~= nil and (wp_ahead.cornerReverse ~= nil or wp_ahead.endManoeuvre ~= nil)) then
        maxSkipWayPoints = 0
    end
    -- manoeuvre at the end of the route (ADCornerModule): the module itself goes on to the destination when done
    if wp_current ~= nil and wp_current.endManoeuvre ~= nil and not wp_current.endManoeuvreDone then
        return false
    end

    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:isCloseToWaypoint - start, wpIdx=%d, maxSkip=%d"
        , self:getCurrentWayPointIndex(), maxSkipWayPoints)
    end
    -- the followed line is shifted while avoiding: the waypoint itself stays as far as the offset
    local min_distance = self.min_distance + math.abs(self.lateralOffset or 0)
    if self.vehicle:getLastSpeed() > 100 then
        min_distance = min_distance * 3
    elseif self.vehicle:getLastSpeed() > 60 then
        min_distance = min_distance * 2
    end

    for i = 0, maxSkipWayPoints do
        if self.wayPoints[self:getCurrentWayPointIndex() + i] ~= nil then
            local distanceToCurrentWp = MathUtil.vector2Length(x - self.wayPoints[self:getCurrentWayPointIndex() + i].x, z - self.wayPoints[self:getCurrentWayPointIndex() + i].z)
            if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:isCloseToWaypoint(%d/%d) distanceToCurrentWp=%.1f min_distance=%.1f"
                , i, maxSkipWayPoints, distanceToCurrentWp, min_distance)
            end
            if distanceToCurrentWp < min_distance then --and i == 0
                if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
                    AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:isCloseToWaypoint return true")
                end
                return true
            end
            -- Check if the angle between vehicle and current wp and current wp to next wp is over 90° - then we should already make the switch
            if i == 1 and wp_current and wp_ahead then
                local angle = AutoDrive.angleBetween({x = wp_ahead.x - wp_current.x, z = wp_ahead.z - wp_current.z}, {x = wp_current.x - x, z = wp_current.z - z})
                angle = math.abs(angle)

                if angle >= 135 then
                    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
                        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:isCloseToWaypoint(%d/%d) - true angle=%.1f"
                        , i, maxSkipWayPoints+1, angle)
                    end
                    return true
                else
                    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
                        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:isCloseToWaypoint angle < 135")
                    end
                end
            else
                if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
                    AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:isCloseToWaypoint i %d  wp_ahead %s wp_ahead %s"
                    , i, tostring(wp_ahead), tostring(wp_current))
                end
            end
        else
            if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:isCloseToWaypoint self.wayPoints[self:getCurrentWayPointIndex() + i] %s"
                , tostring(self.wayPoints[self:getCurrentWayPointIndex() + i]))
            end
        end
    end
    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:isCloseToWaypoint end - false")
    end
    return false
end

function ADDrivePathModule:followWaypoints(dt)
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    if self.vehicle.getAISteeringNode ~= nil then
        x, y, z = getWorldTranslation(self.vehicle:getAISteeringNode())
    end

    local maxSpeedDiff = ADDrivePathModule.MAX_SPEED_DEVIATION
    self.acceleration = 1
    self.distanceToLookAhead = 8

    self.speedLimit = self.vehicle.ad.stateModule:getSpeedLimit()
    -- (07/11) limite calculée une image sur 4 (virages, champ, fin de route, silo) : gardée pour les 3 autres images.
    -- Avant, ces 3 images repartaient à la vitesse maxi de la route : le tracteur réaccélérait dans les virages.
    local perfFrame = ((g_updateLoopIndex + self.vehicle.id) % AutoDrive.PERF_FRAMES_HIGH == 0) or self.heldSpeedLimit == nil
        or self.heldSpeedLimitPath ~= self.wayPoints
    if not perfFrame then
        self.speedLimit = self.heldSpeedLimit
        maxSpeedDiff = self.heldMaxSpeedDiff or maxSpeedDiff
    end
    if perfFrame then
        self.speedLimit = self.vehicle.ad.stateModule:getSpeedLimit()
        if AutoDrive.checkIsOnField(x, y, z) then
            self.speedLimit = self.vehicle.ad.stateModule:getFieldSpeedLimit() --math.min(self.vehicle.ad.stateModule:getFieldSpeedLimit(), self.speedLimit)
        end
        if self.wayPoints[self:getCurrentWayPointIndex() - 1] ~= nil and self:getNextWayPoint() ~= nil then
            local highestAngle = self:getHighestApproachingAngle()

            if self:isOnRoadNetwork() then
                self.speedLimit = math.min(self.speedLimit, self:getMaxSpeedForAngle(highestAngle))
                -- (07/11, Fabien : « vitesse trop haute et pas proportionnelle au virage ») : selon le rayon réel du virage
                local curveLimit = self:getCurveSpeedLimit()
                if curveLimit < self.speedLimit then
                    self.speedLimit = curveLimit
                    -- virage : on freine dès 2 km/h de trop (6 km/h ailleurs), sinon il entre trop vite
                    maxSpeedDiff = math.min(maxSpeedDiff, ADDrivePathModule.CURVE_SPEED_DEVIATION)
                end
            else
                -- Let's increase the cornering speed for paths generated with the pathfinder module. There are many 45° angles in there that slow the process down otherwise.
                self.speedLimit = math.min(self.speedLimit, math.max(12, self:getMaxSpeedForAngle(highestAngle) * 2))
            end
        end

        self.distanceToTarget = self:getDistanceToLastWaypoint(40)
        if self.distanceToTarget < self.distanceToLookAhead then
            local currentTask = self.vehicle.ad.taskModule:getActiveTask()
            local isCatchingCombine = currentTask.taskType ~= nil and self.vehicle.ad.taskModule:getActiveTask().taskType == "CatchCombinePipeTask"
            if not isCatchingCombine then
                local min_speed = math.min(8, 2 + self.distanceToTarget)
                local max_speed = math.max(8, 2 + self.distanceToTarget)
                self.speedLimit = math.clamp(self.speedLimit, min_speed, max_speed)
            end
        end

        if self:isOnRoadNetwork() then
            self.speedLimit = math.min(self.speedLimit, self:getSpeedLimitBySteeringAngle())
        else
            -- Let's increase the cornering speed for paths generated with the pathfinder module. There are many 45° angles in there that slow the process down otherwise.
            self.speedLimit = math.min(self.speedLimit, self:getSpeedLimitBySteeringAngle() * 1.5)
        end

        -- portion Intersection devant : on ralentit pour regarder / s'arrêter avant
        self.speedLimit = math.min(self.speedLimit, ADIntersectionModule.getSpeedLimit(self.vehicle))

        if self.vehicle.ad.trailerModule:isUnloadingToBunkerSilo() then
            -- drive through bunker silo
            self.speedLimit = math.min(self.vehicle.ad.trailerModule:getBunkerSiloSpeed(), self.speedLimit)
            maxSpeedDiff = 1
        else
            if self.distanceToTarget < (ADTriggerManager.getMaxBunkerSiloLength() + AutoDrive.getMaxTriggerDistance(self.vehicle)) and AutoDrive.isVehicleInBunkerSiloArea(self.vehicle) then
                -- vehicle enters drive through bunker silo
                self.speedLimit = math.min(12, self.speedLimit)
                maxSpeedDiff = 3
            else
                local isInRangeToLoadUnloadTarget = AutoDrive.isInRangeToLoadUnloadTarget(self.vehicle) and self.distanceToTarget <= AutoDrive.getMaxTriggerDistance(self.vehicle)
                if isInRangeToLoadUnloadTarget == true then
                    self.speedLimit = math.min(5, self.speedLimit)
                end
            end
        end
        self.heldSpeedLimit = self.speedLimit
        self.heldMaxSpeedDiff = maxSpeedDiff
        self.heldSpeedLimitPath = self.wayPoints
    end

    -- anticipated slow-down in front of an obstacle further on the route (ADApproachModule)
    if self.vehicle.ad.approachModule ~= nil then
        self.speedLimit = math.min(self.speedLimit, self.vehicle.ad.approachModule:getSpeedLimit(dt))
    end
    -- light obstacle on one side: lateral offset of the followed line, without stopping (ADAvoidModule)
    if self.vehicle.ad.avoidModule ~= nil then
        self.speedLimit = math.min(self.speedLimit, self.vehicle.ad.avoidModule:update(dt))
    end

    local maxAngle = 60
    if self.vehicle.maxRotation then
        if self.vehicle.maxRotation > (2 * math.pi) then
            maxAngle = self.vehicle.maxRotation
        else
            maxAngle = math.deg(self.vehicle.maxRotation)
        end
    end

    self.targetX, self.targetZ = self:getLookAheadTarget()
    local lx, lz = AutoDrive.getDriveDirection(self.vehicle, self.targetX, y, self.targetZ)
    if self.vehicle.getAISteeringNode ~= nil then
        lx, lz = AutoDrive.getDriveDirection(self.vehicle, self.targetX, y, self.targetZ, self.vehicle:getAISteeringNode())
    end

    local obstacleDetected = self.vehicle.ad.collisionDetectionModule:hasDetectedObstable(dt)
    -- head-on deadlock resolution between two AD vehicles: the module takes control while active
    if self.vehicle.ad.trafficYieldModule ~= nil and self.vehicle.ad.trafficYieldModule:handle(dt, obstacleDetected) then
        return
    end
    -- portion Intersection : arrêt avant de traverser si un véhicule arrive sur la route
    if ADIntersectionModule.handle(self.vehicle, dt) then
        return
    end
    -- traffic car stopped nose to nose: the lane change backs up first and drives meanwhile (ADAvoidModule)
    if self.vehicle.ad.avoidModule ~= nil and self.vehicle.ad.avoidModule:handle(dt) then
        return
    end
    -- bend too tight for the train: backing up a few metres before taking it (ADCornerModule)
    if self.vehicle.ad.cornerModule ~= nil and self.vehicle.ad.cornerModule:handle(dt) then
        return
    end
    self:learnBlockedPlace(dt, obstacleDetected)
    -- static obstacle blocking the route forever: reverse and compute a route around it
    if self.vehicle.ad.obstacleDetourModule ~= nil and self.vehicle.ad.obstacleDetourModule:handle(dt, obstacleDetected) then
        return
    end

    -- another AutoDrive vehicle closer than the gap on the route: stop here, like the sensors would
    if not obstacleDetected and self.vehicle.ad.approachModule ~= nil and self.vehicle.ad.approachModule:shouldStop() then
        obstacleDetected = true
    end
    if obstacleDetected then
        if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:followWaypoints - stopVehicle")
        end
        self.vehicle.ad.specialDrivingModule:stopVehicle((not self:isOnRoadNetwork()), lx, lz)
        self.vehicle.ad.specialDrivingModule:update(dt)
        self.pushX = nil
    else
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        local speedDiff = (self.vehicle.lastSpeedReal * 3600) - self.speedLimit
        -- Allow active braking if vehicle is not 'following' targetSpeed precise enough
        if speedDiff <= 0.25 then
            self.brakeHysteresisActive = false
        end
        if (speedDiff > maxSpeedDiff) or self.brakeHysteresisActive then
            self.brakeHysteresisActive = true
            
            self.acceleration = -math.min(0.6, speedDiff * 0.05)
        end
        
        -- if self.vehicle.getAISteeringNode ~= nil then
        --     local aix, aiy, aiz = getWorldTranslation(self.vehicle:getAISteeringNode())            
        --     ADDrawingManager:addLineTask(aix, aiy+3, aiz, self.targetX, y+3, self.targetZ, 1, 1, 0, 0)
        -- else            
        --     ADDrawingManager:addLineTask(x, y+3, z, self.targetX, y+3, self.targetZ, 1, 1, 0, 0)
        -- end
        if self.vehicle.startMotor then
            if not self.vehicle:getIsMotorStarted() and self.vehicle:getCanMotorRun() and not self.vehicle.ad.specialDrivingModule:shouldStopMotor() then
                self.vehicle:startMotor()
            end
        end
        self.vehicle.ad.trailerModule:handleTrailerReversing(false)
        AutoDrive.driveInDirection(self.vehicle, dt, maxAngle, self.acceleration, 0.8, maxAngle, true, true, lx, lz, self.speedLimit, 1)
        self:checkIfPushing(dt)
        --local worldX, _, worldZ = AutoDrive.worldToLocal(self.vehicle, self.targetX, y, self.targetZ)
        --print("dt: " .. dt .. " acc: " .. self.acceleration .. " x: " .. worldX .. " z: " .. worldZ .. " speedLimit: " .. self.speedLimit)
        --AIVehicleUtil.driveToPoint(self.vehicle, dt, self.acceleration, true, true, worldX, worldZ, self.speedLimit)

        -- local tX, _, tZ = worldToLocal(self.vehicle:getAISteeringNode(), self.targetX, y, self.targetZ)
        -- AIVehicleUtil.driveToPoint(self.vehicle, dt, self.acceleration, true, true, tX, tZ, self.speedLimit)
    end
end

function ADDrivePathModule:handleReachedWayPoint()
    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:handleReachedWayPoint")
    end
    -- while driving forward the lastUsedWayPoint could be used to continue in next drive
    self.lastUsedWayPoint = self:getCurrentWayPoint()
    if self:getNextWayPoint() ~= nil then
        self:switchToNextWayPoint()
    else
        self:reachedTarget()
    end
end

function ADDrivePathModule:reachedTarget()
    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:reachedTarget")
    end
    if self:getIsReversing() then
        -- while driving reverse the lastUsedWayPoint might be far away or not feasable to continue, so do not use it
        self.lastUsedWayPoint = nil
    end
    self.atTarget = true
    self.wayPoints = nil
    self.currentWayPoint = 0
end

function ADDrivePathModule:isTargetReached()
    if self.vehicle.spec_locomotive and self.vehicle.ad and self.vehicle.ad.trainModule then
        -- train
        return self.vehicle.ad.trainModule:isTargetReached()
    end
    return self.atTarget
end

-- To differentiate between waypoints on the road and ones created from pathfinder
function ADDrivePathModule:isOnRoadNetwork()
    return (self.wayPoints ~= nil and self:getCurrentWayPoint() ~= nil and not self:getCurrentWayPoint().isPathFinderPoint)
end

function ADDrivePathModule:getWayPoints()
    return self.wayPoints, self:getCurrentWayPointIndex()
end

function ADDrivePathModule:getLastWayPoint()
    if self.wayPoints ~= nil then
        return self.wayPoints[#self.wayPoints]
    end
    return nil
end

function ADDrivePathModule:getLastWayPointId()
    local lastWp = self:getLastWayPoint()
    if lastWp ~= nil then
        return lastWp.id
    end
    return -1
end

function ADDrivePathModule:getCurrentLookAheadDistance()
    local totalMass = self.vehicle:getTotalMass(false)
    local massFactor = math.max(1, math.min(3, (totalMass + 20) / 30))
    local speedFactor = math.max(0.25, math.min(4, (((self.vehicle.lastSpeedReal * 3600) + 10) / 20.0)))
    if speedFactor <= 1 then
        massFactor = math.min(speedFactor, massFactor)
    end
    return math.min(ADDrivePathModule.LOOKAHEADDISTANCE * massFactor * speedFactor, 150)
end

function ADDrivePathModule:getHighestApproachingAngle()
    self.turnAngle = 0
    self.distanceToLookAhead = self:getCurrentLookAheadDistance()
    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_DEVINFO, "ADDrivePathModule:getHighestApproachingAngle -> Lookahead distance: " .. self.distanceToLookAhead)
    end
    local pointsToLookAhead = ADDrivePathModule.MAXLOOKAHEADPOINTS
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)

    if self:getCurrentWayPointIndex() + 2 >= #self.wayPoints then
        return 0
    end

    local baseDistance = MathUtil.vector2Length(self:getCurrentWayPoint().x - x, self:getCurrentWayPoint().z - z)

    local highestAngle = 0
    local doneCheckingRoute = false
    local currentLookAheadPoint = 1
    while not doneCheckingRoute and currentLookAheadPoint <= pointsToLookAhead do
        if self.wayPoints[self:getCurrentWayPointIndex() + currentLookAheadPoint] ~= nil then
            local wp_ahead = self.wayPoints[self:getCurrentWayPointIndex() + currentLookAheadPoint]
            local wp_current = self.wayPoints[self:getCurrentWayPointIndex() + currentLookAheadPoint - 1]
            local wp_ref = self.wayPoints[self:getCurrentWayPointIndex() + currentLookAheadPoint - 2]
            if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_DEVINFO, "ADDrivePathModule:getHighestApproachingAngle -> wp_ahead: " .. wp_ahead.x .. " / " .. wp_ahead.z)
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_DEVINFO, "ADDrivePathModule:getHighestApproachingAngle -> wp_current: " .. wp_current.x .. " / " .. wp_current.z)
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_DEVINFO, "ADDrivePathModule:getHighestApproachingAngle -> wp_ref: " .. wp_ref.x .. " / " .. wp_ref.z)
            end
            local angle = AutoDrive.angleBetween({x = wp_ahead.x - wp_current.x, z = wp_ahead.z - wp_current.z}, {x = wp_current.x - wp_ref.x, z = wp_current.z - wp_ref.z})

            if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_DEVINFO, "ADDrivePathModule:getHighestApproachingAngle -> angle: " .. angle)
            end

            self.turnAngle = self.turnAngle + math.clamp(angle, -90, 90)

            angle = math.abs(angle)

            if MathUtil.vector2Length(self:getCurrentWayPoint().x - wp_ahead.x, self:getCurrentWayPoint().z - wp_ahead.z) <= (self.distanceToLookAhead - baseDistance) then
                if angle < 180 then
                    highestAngle = math.max(highestAngle, angle)
                end
            else
                doneCheckingRoute = true
            end
        else
            doneCheckingRoute = true
        end
        currentLookAheadPoint = currentLookAheadPoint + 1
    end

    return highestAngle

    --new function. Take the angle of the current ref node and then go through x-points until the distance (not geometric but pathwise) is bigger than y-
    -- 1.) Take the angle of the current ref node and then go through x-points until the distance (not geometric but pathwise) is bigger than y
    -- 2.) Increase ref node index
    -- 3.) Repeat until either index > ADDrivePathModule.MAXLOOKAHEADPOINTS or ref node distance (geometric) > distanceToLookAhead
    --[[
    local refNodeIndex = self:getCurrentWayPointIndex()
    local lookAheadIndex = 1
    local wp_ref = self.wayPoints[refNodeIndex]
    local refNodeDistance = MathUtil.vector2Length(wp_ref.x - x, wp_ref.z - z)
    local wp_current = self.wayPoints[refNodeIndex + lookAheadIndex]
    local wp_ahead = self.wayPoints[refNodeIndex + lookAheadIndex + 1]
    local refVector = {x = wp_current.x - wp_ref.x, z = wp_current.z - wp_ref.z}
    local nextVector = {x = wp_ahead.x - wp_current.x, z = wp_ahead.z - wp_current.z}
    local maxAngle = math.abs(AutoDrive.angleBetween(nextVector, refVector))

    while refNodeIndex < (self:getCurrentWayPointIndex() + self.MAXLOOKAHEADPOINTS) and refNodeDistance < self.distanceToLookAhead and (refNodeIndex + 1) < #self.wayPoints do
        lookAheadIndex = 1
        while self:getDistanceBetweenWayPoints(refNodeIndex, refNodeIndex + lookAheadIndex) < 15 and (refNodeIndex + lookAheadIndex + 1) < #self.wayPoints do
            wp_current = self.wayPoints[refNodeIndex + lookAheadIndex]
            wp_ahead = self.wayPoints[refNodeIndex + lookAheadIndex + 1]
            nextVector = {x = wp_ahead.x - wp_current.x, z = wp_ahead.z - wp_current.z}
            maxAngle = math.max(maxAngle, math.abs(AutoDrive.angleBetween(nextVector, refVector)))
            
            lookAheadIndex = lookAheadIndex + 1
        end
        refNodeIndex = refNodeIndex + 1
        wp_ref = self.wayPoints[refNodeIndex]
        refNodeDistance = self:getDistanceBetweenWayPoints(self:getCurrentWayPointIndex(), refNodeIndex)
        wp_current = self.wayPoints[refNodeIndex + 1]
        refVector = {x = wp_current.x - wp_ref.x, z = wp_current.z - wp_ref.z}
    end
    --print("MaxAngle: " .. maxAngle)
    return maxAngle
    --]]
end

function ADDrivePathModule:getDistanceBetweenWayPoints(indexStart, indexTarget)
    local distance = 0
    while indexStart < indexTarget do
        local wpStart = self.wayPoints[indexStart]
        local wpNext = self.wayPoints[indexStart + 1]
        distance = distance + MathUtil.vector2Length(wpStart.x - wpNext.x, wpStart.z - wpNext.z)
        indexStart = indexStart + 1
    end

    return distance
end

function ADDrivePathModule:getApproachingHeightDiff()
    local heightDiff = 0
    local maxLookAhead = 10
    local maxLookAheadDistance = 20
    local lookAhead = 1
    for i = 1, maxLookAhead do
        if self.wayPoints ~= nil and self:getCurrentWayPointIndex() ~= nil and self:getCurrentWayPoint() ~= nil and (self:getCurrentWayPointIndex() + lookAhead) <= #self.wayPoints then
            local p1 = self.wayPoints[self:getCurrentWayPointIndex()]
            local p2 = self.wayPoints[self:getCurrentWayPointIndex() + lookAhead]
            local refNodeDistance = self:getDistanceBetweenWayPoints(self:getCurrentWayPointIndex(), self:getCurrentWayPointIndex() + lookAhead)
            if refNodeDistance <= maxLookAheadDistance then
                heightDiff = heightDiff + (p2.y - p1.y)
            end
            lookAhead = lookAhead + 1
        end
    end
    return heightDiff
end

function ADDrivePathModule:getMaxSpeedForAngle(angle)
    local maxSpeed = math.huge

    if angle < 5 then
        maxSpeed = math.huge
    elseif angle < 50 then
        maxSpeed = 12 + 48 * (1 - math.clamp((angle - 5), 0, 25) / (30 - 5))
    elseif angle >= 50 then
        maxSpeed = 3
    end

    self.maxAngle = angle
    self.maxAngleSpeed = maxSpeed * 1.0 * AutoDrive.getSetting("cornerSpeed", self.vehicle)

    return self.maxAngleSpeed
end

-- (07/11, Fabien : « dans les virages la vitesse est souvent trop haute et pas proportionnelle au virage ») :
-- l'angle entre deux points voisins ne dit pas si le virage est serré (un virage dessiné ou redessiné avec un point
-- tous les 2,5 m n'a que des petits angles). Ici : rayon réel du virage = changement de cap / longueur de route sur
-- une fenêtre de quelques mètres ; vitesse du virage = racine(accélération latérale x rayon) x réglage « Vitesse en
-- virage » ; et on freine assez tôt pour l'atteindre à l'entrée (décélération CURVE_BRAKE).
ADDrivePathModule.CURVE_WINDOW = 6          -- m de route (entre milieux de segments) pour mesurer le rayon
ADDrivePathModule.CURVE_LATERAL = 1.5       -- m/s² d'accélération latérale dans le virage
ADDrivePathModule.CURVE_BRAKE = 0.6         -- m/s² de décélération prévue avant le virage (freinage doux, commencé tôt)
ADDrivePathModule.CURVE_SPEED_DEVIATION = 2 -- km/h de trop tolérés avant de freiner quand un virage limite
ADDrivePathModule.CURVE_MIN_SPEED = 5       -- km/h
ADDrivePathModule.CURVE_RADIUS_MAX = 300    -- m : plus large = ligne droite
ADDrivePathModule.CURVE_LOOK_MIN = 40       -- m de route regardés au moins
ADDrivePathModule.CURVE_LOOK_MAX = 150      -- m au plus
ADDrivePathModule.CURVE_POINTS_MAX = 150    -- points regardés au plus
ADDrivePathModule.CURVE_BACK = 12           -- m de route regardés derrière le point visé
ADDrivePathModule.CURVE_REVERSAL = math.rad(135) -- changement de sens (marche arrière) : on s'arrête là

-- rayon (m) et début (m de route depuis le 1er point regardé) du virage le plus contraignant ; limite en km/h
function ADDrivePathModule:getCurveSpeedLimit()
    local wps = self.wayPoints
    local idx = self:getCurrentWayPointIndex()
    if wps == nil or idx == nil or wps[idx] == nil or self.isReversing then
        return math.huge
    end
    -- on part quelques points derrière : avec des points serrés, le point visé est souvent déjà après la fin du
    -- virage alors que le tracteur y est encore
    local first, back = idx, 0
    while first > 1 and idx - first < 10 do
        local a, b = wps[first - 1], wps[first]
        back = back + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        if back > ADDrivePathModule.CURVE_BACK then
            break
        end
        first = first - 1
    end
    first = math.max(1, math.min(first, idx - 1))
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local v = math.abs(self.vehicle.lastSpeedReal or 0) * 1000
    local look = math.min(ADDrivePathModule.CURVE_LOOK_MAX, math.max(ADDrivePathModule.CURVE_LOOK_MIN, v * v / (2 * ADDrivePathModule.CURVE_BRAKE) + 30))
    -- segments k (wps[k] -> wps[k+1]) : cap cumulé (sans saut à ±180°), position de leur milieu sur la route
    local cum, mid, s = {}, {}, 0
    local lastHeading = nil
    local vehAt = nil
    for k = first, math.min(#wps - 1, first + ADDrivePathModule.CURVE_POINTS_MAX) do
        local a, b = wps[k], wps[k + 1]
        if k == idx then
            -- position du véhicule sur la route : un peu avant le point visé
            vehAt = s - math.sqrt((a.x - x) ^ 2 + (a.z - z) ^ 2)
        end
        local dx, dz = b.x - a.x, b.z - a.z
        local len = math.sqrt(dx * dx + dz * dz)
        if len > 0.05 then
            local h = math.atan2(dx, dz)
            local c = 0
            if lastHeading ~= nil then
                local turn = (h - lastHeading + math.pi) % (2 * math.pi) - math.pi
                if math.abs(turn) >= ADDrivePathModule.CURVE_REVERSAL then
                    break
                end
                c = cum[#cum] + turn
            end
            lastHeading = h
            cum[#cum + 1] = c
            mid[#mid + 1] = s + len / 2
            s = s + len
            if vehAt ~= nil and s - vehAt > look then
                break
            end
        end
    end
    if #cum < 2 then
        return math.huge
    end
    vehAt = vehAt or 0
    local factor = AutoDrive.getSetting("cornerSpeed", self.vehicle) or 1
    local best = math.huge
    local m = 2
    for j = 1, #cum - 1 do
        if m <= j then
            m = j + 1
        end
        while m < #cum and mid[m] - mid[j] < ADDrivePathModule.CURVE_WINDOW do
            m = m + 1
        end
        local turn = math.abs(cum[m] - cum[j])
        local length = mid[m] - mid[j]
        -- fenêtre déjà derrière le tracteur : ne compte plus
        if turn > 0.001 and length > 0.5 and mid[m] >= vehAt - 1 then
            local radius = length / turn
            if radius < ADDrivePathModule.CURVE_RADIUS_MAX then
                local vb = math.sqrt(ADDrivePathModule.CURVE_LATERAL * radius) * factor
                local d = math.max(0, mid[j] - vehAt)
                local allowed = math.sqrt(vb * vb + 2 * ADDrivePathModule.CURVE_BRAKE * d) * 3.6
                if allowed < best then
                    best = allowed
                    self.curveRadius = radius
                    self.curveDistance = d
                end
            end
        end
    end
    if best == math.huge then
        self.curveRadius = nil
        return best
    end
    return math.max(ADDrivePathModule.CURVE_MIN_SPEED, best)
end

function ADDrivePathModule:getSpeedLimitBySteeringAngle()
    local steeringAngle = math.deg(math.abs(self.vehicle.rotatedTime))

    local maxSpeed = math.huge

    local maxAngle = 60
    if self.vehicle.maxRotation then
        if self.vehicle.maxRotation > (2 * math.pi) then
            maxAngle = self.vehicle.maxRotation
        else
            maxAngle = math.deg(self.vehicle.maxRotation)
        end
    end

    if steeringAngle > maxAngle * 0.95 then
        maxSpeed = 10
    end
    return maxSpeed
end

function ADDrivePathModule:getDistanceToLastWaypoint(maxLookAheadPar)
    local distance = math.huge
    local maxLookAhead = maxLookAheadPar
    if maxLookAhead == nil then
        maxLookAhead = 10
    end

    if self.wayPoints ~= nil and self:getCurrentWayPointIndex() ~= nil and self:getCurrentWayPoint() ~= nil and (self:getCurrentWayPointIndex() + maxLookAheadPar) >= #self.wayPoints then
        distance = 0
        local lookAhead = 1
        while self.wayPoints[self:getCurrentWayPointIndex() + lookAhead] ~= nil and lookAhead < maxLookAhead do
            local p1 = self.wayPoints[self:getCurrentWayPointIndex() + lookAhead]
            local p2 = self.wayPoints[self:getCurrentWayPointIndex() + lookAhead - 1]
            local pointDistance = MathUtil.vector2Length(p2.x - p1.x, p2.z - p1.z)
            if pointDistance ~= nil then
                distance = distance + pointDistance
            end
            lookAhead = lookAhead + 1
        end
    end

    return distance
end

function ADDrivePathModule:getNextWayPoint()
    return self.wayPoints[self:getNextWayPointIndex()]
end

function ADDrivePathModule:getNextWayPointId()
    local nWp = self:getNextWayPoint()
    if nWp ~= nil and nWp.id ~= nil then
        return nWp.id
    end
    return -1
end

function ADDrivePathModule:getNextWayPoints()
    local cId = self:getCurrentWayPointIndex()
    return self.wayPoints[cId + 1], self.wayPoints[cId + 2], self.wayPoints[cId + 3], self.wayPoints[cId + 4], self.wayPoints[cId + 5]
end

function ADDrivePathModule:setCurrentWayPointIndex(waypointId)
    self.currentWayPoint = waypointId
    self.vehicle.ad.stateModule:setCurrentWayPointId(self:getCurrentWayPointId())
    self.vehicle.ad.stateModule:setNextWayPointId(self:getNextWayPointId())
end

function ADDrivePathModule:getCurrentWayPointIndex()
    return self.currentWayPoint
end

function ADDrivePathModule:getCurrentWayPoint()
    if self.wayPoints ~= nil then
        return self.wayPoints[self:getCurrentWayPointIndex()]
    end

    return nil
end

function ADDrivePathModule:getCurrentWayPointId()
    local nWp = self:getCurrentWayPoint()
    if nWp ~= nil and nWp.id ~= nil then
        return nWp.id
    end
    return -1
end

function ADDrivePathModule:getNextWayPointIndex()
    return self:getCurrentWayPointIndex() + 1
end

function ADDrivePathModule:switchToNextWayPoint()
    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:switchToNextWayPoint")
    end
    self:setCurrentWayPointIndex(self:getNextWayPointIndex())
    self.minDistanceToNextWp = math.huge

    local isReverse, _, _ = self:checkForReverseSection()
    if isReverse ~= self.isReversing then
        self.isReversing = isReverse
        self.vehicle.ad.specialDrivingModule:reset()
        self.vehicle.ad.specialDrivingModule.currentWayPointIndex = self:getCurrentWayPointIndex()
    end
end

function ADDrivePathModule:getLookAheadTarget()
    --start driving to the nextWayPoint when closing in on current waypoint in order to avoid harsh steering angles and oversteering

    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    if self.vehicle.getAISteeringNode ~= nil then
        x, _, z = getWorldTranslation(self.vehicle:getAISteeringNode())
    end

    local wp_current = self:getCurrentWayPoint()
    if wp_current == nil then
        return x, z
    end

    local distanceToCurrentTarget = MathUtil.vector2Length(x - wp_current.x, z - wp_current.z)
    local lookAheadDistance = self.min_lookAhead
    local lookAheadRemaining = lookAheadDistance - distanceToCurrentTarget

    local lookAheadID = 0
    local wp_ahead = wp_current
    local distanceToNextTarget = 0

    while lookAheadRemaining > distanceToNextTarget do
        lookAheadRemaining = lookAheadRemaining - distanceToNextTarget
        lookAheadID = lookAheadID + 1

        local wp_next = self.wayPoints[self:getCurrentWayPointIndex() + lookAheadID]
        -- the point where a bend manoeuvre backs up lies behind: the line ends here
        if wp_next == nil or wp_next.cornerReverse ~= nil or ADGraphManager:isReverseRoad(wp_ahead, wp_next) then
            break
        end
        wp_current, wp_ahead = wp_ahead, wp_next
        distanceToNextTarget = MathUtil.vector2Length(wp_current.x - wp_ahead.x, wp_current.z - wp_ahead.z)
    end

    local targetX, targetZ = wp_current.x, wp_current.z
    if lookAheadRemaining > 0.1 and distanceToNextTarget > 0.1 then
        local length = math.min(lookAheadRemaining, distanceToNextTarget)
        local addX, addZ = MathUtil.vector2SetLength(wp_ahead.x - wp_current.x, wp_ahead.z - wp_current.z, length)
        targetX = targetX + addX
        targetZ = targetZ + addZ
    end
    -- lateral offset while avoiding a light obstacle (ADAvoidModule): along the left normal of the stretch
    local offset = self.lateralOffset or 0
    if offset ~= 0 then
        local dx, dz = wp_ahead.x - wp_current.x, wp_ahead.z - wp_current.z
        if distanceToNextTarget <= 0.1 then
            dx, dz = wp_current.x - x, wp_current.z - z
        end
        local l = MathUtil.vector2Length(dx, dz)
        if l > 0.1 then
            targetX = targetX + dz / l * offset
            targetZ = targetZ - dx / l * offset
        end
    end

    if AutoDrive.isEditorModeEnabled() and AutoDrive.getDebugChannelIsSet(AutoDrive.DC_VEHICLEINFO) then
        ADDrawingManager:addLineTask(x, y+2.2, z, wp_current.x, y+2.2, wp_current.z, 1.5, 0, 0, 1)
        ADDrawingManager:addLineTask(x, y+2.3, z, wp_ahead.x, y+2.4, wp_ahead.z, 1.5, 1, 0, 0)
        ADDrawingManager:addLineTask(x, y+2.4, z, targetX, y+2.6, targetZ, 1.5, 0, 1, 0)
        ADDrawingManager:addLineTask(targetX, y+2.4, targetZ, targetX, y+5, targetZ, 1.5, 0, 1, 0)
    end
    return targetX, targetZ
end

function ADDrivePathModule:checkActiveAttributesSet(dt)
    if self.vehicle.isServer then
        self.vehicle.forceIsActive = true
        self.vehicle.spec_motorized.stopMotorOnLeave = false
        self.vehicle.spec_enterable.disableCharacterOnLeave = false

        if self.vehicle.spec_aiVehicle ~= nil and self.vehicle.spec_aiVehicle.aiTrafficCollisionTranslation ~= nil then
            self.vehicle.spec_aiVehicle.aiTrafficCollisionTranslation[2] = -1000
        end

        if ((g_updateLoopIndex + self.vehicle.id) % AutoDrive.PERF_FRAMES == 0) then
            if self.vehicle.setBeaconLightsVisibility ~= nil and AutoDrive.getSetting("useBeaconLights", self.vehicle) then
                local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
                if not AutoDrive.checkIsOnField(x, y, z) and self.vehicle:getIsMotorStarted() then
                    self.vehicle:setBeaconLightsVisibility(true)
                else
                    self.vehicle:setBeaconLightsVisibility(false)
                end
            end
            local blinkangle = AutoDrive.getSetting("blinkValue") or 0

            if blinkangle > 0 then
                if self.blinkTimer:timer(math.abs(self.turnAngle) < blinkangle, ADDrivePathModule.BLINK_TIMEOUT, dt * AutoDrive.PERF_FRAMES) then -- Rough estimate for the dt time. But should be fine
                    self.vehicle:setTurnLightState(Lights.TURNLIGHT_OFF)
                else
                    if self.turnAngle > blinkangle and self:isOnRoadNetwork() then
                        self.vehicle:setTurnLightState(Lights.TURNLIGHT_LEFT)
                    elseif self.turnAngle < - blinkangle and self:isOnRoadNetwork() then
                        self.vehicle:setTurnLightState(Lights.TURNLIGHT_RIGHT)
                    end
                end
            end
        end

    end
end

function ADDrivePathModule:checkIfStuck(dt)
    if self.vehicle.isServer then
        local wp = self:getCurrentWayPoint()
        local manoeuvre = (self.vehicle.ad.obstacleDetourModule ~= nil and self.vehicle.ad.obstacleDetourModule:isControlling())
            or (self.vehicle.ad.avoidModule ~= nil and self.vehicle.ad.avoidModule:isControlling())
            or (self.vehicle.ad.cornerModule ~= nil and self.vehicle.ad.cornerModule:isControlling())
        if not self.vehicle.ad.specialDrivingModule:isStoppingVehicle() and wp ~= nil and not manoeuvre then
            local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
            local distanceToNextWayPoint = MathUtil.vector2Length(x - wp.x, z - wp.z)
            self.minDistanceTimer:timer(distanceToNextWayPoint >= self.minDistanceToNextWp, 8000, dt)
            self.minDistanceToNextWp = math.min(self.minDistanceToNextWp, distanceToNextWayPoint)
            if self.minDistanceTimer:done() then
                self:handleBeingStuck()
            end
        else
            self.minDistanceTimer:timer(false)
        end
    end
end

-- (08/11, Fabien : « il a essayé de partir », « il ne l'a pas vu ») 7R 350 against a pole beside the line: 1 min 40
-- pushing at 0 km/h, sensors free, and the 8 s safety above never fired. Pushing = told to drive on (no stop asked,
-- speed limit at least PUSH_MIN_LIMIT, engine running, on the road network) without moving PUSH_MOVE metres for
-- PUSH_TIME. Then: back up and pass beside it (ADAvoidModule:startFromPush); pushing again at the same place (twice): back up
-- and compute a way around (ADObstacleDetourModule:startFromStuck); after that the 8 s safety as before
ADDrivePathModule.PUSH_TIME = 3000          -- ms
ADDrivePathModule.PUSH_MOVE = 0.5           -- m
ADDrivePathModule.PUSH_MIN_LIMIT = 3        -- km/h
ADDrivePathModule.PUSH_SAME_PLACE = 10      -- m
ADDrivePathModule.PUSH_GAP = 500            -- ms without a check: the watch starts again

function ADDrivePathModule:checkIfPushing(dt)
    if not self.vehicle.isServer then
        return
    end
    local ad = self.vehicle.ad
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local now = g_time or 0
    local idle = (self.speedLimit or 0) < ADDrivePathModule.PUSH_MIN_LIMIT or (self.acceleration or 1) <= 0 or not self:isOnRoadNetwork()
        or (self.vehicle.getIsMotorStarted ~= nil and not self.vehicle:getIsMotorStarted())
        or (ad.trailerModule ~= nil and ad.trailerModule.isActiveAtTrigger ~= nil and ad.trailerModule:isActiveAtTrigger())
        or (ad.specialDrivingModule ~= nil and ad.specialDrivingModule:isStoppingVehicle())
    if idle or self.pushX == nil or self.pushCheckTime == nil or now - self.pushCheckTime > ADDrivePathModule.PUSH_GAP
        or MathUtil.vector2Length(x - self.pushX, z - self.pushZ) > ADDrivePathModule.PUSH_MOVE then
        self.pushX, self.pushZ = x, z
        self.pushTime = 0
        self.pushCheckTime = now
        return
    end
    self.pushCheckTime = now
    self.pushTime = (self.pushTime or 0) + dt
    if self.pushTime < ADDrivePathModule.PUSH_TIME then
        return
    end
    self.pushX = nil
    self:handlePushing(x, z)
end

function ADDrivePathModule:handlePushing(x, z)
    local ad = self.vehicle.ad
    if self.pushPlaceX ~= nil and MathUtil.vector2Length(x - self.pushPlaceX, z - self.pushPlaceZ) < ADDrivePathModule.PUSH_SAME_PLACE then
        self.pushCount = (self.pushCount or 0) + 1
    else
        self.pushPlaceX, self.pushPlaceZ = x, z
        self.pushCount = 1
    end
    local name = ad.stateModule ~= nil and ad.stateModule:getName() or tostring(self.vehicle.id)
    local info = string.format("pousse sans avancer depuis %.0f s (limite %.0f km/h, point %d/%d, decalage %.1f m, fois %d ici)",
        ADDrivePathModule.PUSH_TIME / 1000, self.speedLimit or 0, self.currentWayPoint or 0, self.wayPoints ~= nil and #self.wayPoints or 0,
        self.lateralOffset or 0, self.pushCount)
    if self.pushCount == 1 and ad.avoidModule ~= nil and ad.avoidModule.startFromPush ~= nil and ad.avoidModule:startFromPush() then
        print(string.format("[AD-Pousse] %s: %s : recul puis passage a cote", tostring(name), info))
        return
    end
    if self.pushCount <= 3 and ad.obstacleDetourModule ~= nil and ad.obstacleDetourModule.startFromStuck ~= nil and ad.obstacleDetourModule:startFromStuck() then
        print(string.format("[AD-Pousse] %s: %s : recul puis contournement calcule", tostring(name), info))
        return
    end
    print(string.format("[AD-Pousse] %s: %s : rien de possible ici, la securite coince (8 s) prend la suite", tostring(name), info))
end

function ADDrivePathModule:handleBeingStuck()
    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_VEHICLEINFO, "handleBeingStuck")
    end
    if self.vehicle.isServer then
        -- owner 25/10 14:10: this safety (8 s without getting closer to the next waypoint) reset the unloaders of the
        -- forage harvester (stop + restart): queue place, harvester and follow lost, the next unloader called from far
        -- away (MF 7S.210 14:08, 6205 TTV 13:55 and 14:02). Logged, and the mode may recover on its own instead
        local wp = self:getCurrentWayPoint()
        local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
        local distance = wp ~= nil and MathUtil.vector2Length(x - wp.x, z - wp.z) or -1
        local task = self.vehicle.ad.taskModule ~= nil and self.vehicle.ad.taskModule.activeTask or nil
        local taskName = "aucune"
        if task ~= nil then
            taskName = task.taskType or (task.getI18nInfo ~= nil and task:getI18nInfo()) or "?"
        end
        local info = string.format("coince : 8 s sans approcher le point suivant (a %.1f m, au plus pres %.1f m, point %d/%d, vitesse %.1f km/h, marche arriere %s, tache %s)",
            distance, self.minDistanceToNextWp ~= math.huge and self.minDistanceToNextWp or -1, self.currentWayPoint or 0, self.wayPoints ~= nil and #self.wayPoints or 0,
            math.abs(self.vehicle.lastSpeedReal or 0) * 3600, tostring(self.isReversing), tostring(taskName))
        local mode = self.vehicle.ad.stateModule ~= nil and self.vehicle.ad.stateModule:getCurrentMode() or nil
        if mode ~= nil and mode.onDriveStuck ~= nil and mode:onDriveStuck(info) then
            self.minDistanceTimer:timer(false)
            self.minDistanceToNextWp = math.huge
            return
        end
        -- stuck against something (wall, house corner): a plain restart puts the vehicle back on the same
        -- route from the same spot. Reversing first and planning a way around (ADObstacleDetourModule) is tried before
        local detour = self.vehicle.ad.obstacleDetourModule
        if detour ~= nil and detour.startFromStuck ~= nil and detour:startFromStuck() then
            print(string.format("[AD-Coince] %s: %s : recul puis contournement avant la remise a zero", tostring(self.vehicle:getName()), info))
            self.minDistanceTimer:timer(false)
            self.minDistanceToNextWp = math.huge
            return
        end
        print(string.format("[AD-Coince] %s: %s : AutoDrive remis a zero (arret puis redemarrage)", tostring(self.vehicle:getName()), info))
        AutoDriveMessageEvent.sendMessageOrNotification(self.vehicle, ADMessagesManager.messageTypes.ERROR, "$l10n_AD_Driver_of; %s $l10n_AD_got_stuck;", 5000, self.vehicle.ad.stateModule:getName())
        self.vehicle.ad.taskModule:stopAndRestartAD()
    end
end

function ADDrivePathModule:checkForReverseSection()
    -- returns [current segment is reversed], [current segment is the last forward segment], [current segment is the last reverse segment]
    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_VEHICLEINFO, "checkForReverseSection start")
    end

    if self.wayPoints == nil or self:getCurrentWayPointIndex() < 1 or #self.wayPoints <= self:getCurrentWayPointIndex() + 1 then
        if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_PATHINFO, "ADDrivePathModule:checkForReverseSection wpIdx=%d - first or last segment"
            , self:getCurrentWayPointIndex())
        end
        return self.isReversing, false, false
    end

    -- check current segment (required either way)
    local wp_ref = self.wayPoints[self:getCurrentWayPointIndex() - 1]
    local wp_current = self.wayPoints[self:getCurrentWayPointIndex() - 0]
    local wp_ahead = self.wayPoints[self:getCurrentWayPointIndex() + 1]

    local isReverse = ADGraphManager:isReverseRoad(wp_ref, wp_current)
    local aheadIsReverse = ADGraphManager:isReverseRoad(wp_current, wp_ahead)

    if self.isReversing then
        -- we're allowed to continue reversing on dual segments
        isReverse = isReverse or ADGraphManager:isDualRoad(wp_ref, wp_current)
        aheadIsReverse = aheadIsReverse or ADGraphManager:isDualRoad(wp_current, wp_ahead)
    end

    -- special case for harvester-task reversed sections
    isReverse = isReverse or Utils.getNoNil(wp_current.isReverse, false)
    isReverse = isReverse and not Utils.getNoNil(wp_current.isForward, false)
    aheadIsReverse = aheadIsReverse or Utils.getNoNil(wp_ahead.isReverse, false)
    aheadIsReverse = aheadIsReverse and not Utils.getNoNil(wp_ahead.isForward, false)

    local angle = AutoDrive.angleBetween({x = wp_ahead.x - wp_current.x, z = wp_ahead.z - wp_current.z}, {x = wp_current.x - wp_ref.x, z = wp_current.z - wp_ref.z})
    local isSteepTurn = math.abs(angle) > 100

    local isLastForwardSection = not isReverse and aheadIsReverse and isSteepTurn
    local isLastReverseSection = isReverse and not aheadIsReverse and isSteepTurn

    if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_VEHICLEINFO, "checkForReverseSection end - isReverse %s isLastForwardSection %s isLastReverseSection %s"
        , tostring(isReverse), tostring(isLastForwardSection), tostring(isLastReverseSection))
    end
    return isReverse, isLastForwardSection, isLastReverseSection
end

-- front sensor keeps the vehicle stopped on a calculated route: the place becomes a forbidden zone for all later route searches
function ADDrivePathModule:learnBlockedPlace(dt, obstacleDetected)
    local wp = self:getCurrentWayPoint()
    local odm = self.vehicle.ad.obstacleDetourModule
    local blocked = obstacleDetected and self.vehicle.isServer and wp ~= nil and wp.isPathFinderPoint and odm ~= nil and odm:isBlockedByStaticObstacle()
    if not blocked then
        self.learnZoneTimer = 0
        return
    end
    if self.learnZoneTimer ~= nil and self.learnZoneTimer < 0 then
        return
    end
    self.learnZoneTimer = (self.learnZoneTimer or 0) + dt
    if self.learnZoneTimer < PathFinderModule.LEARNED_ZONE_DELAY then
        return
    end
    -- once per stop
    self.learnZoneTimer = -1
    if odm:isVehicleInFront() then
        return
    end
    local length = self.vehicle.size ~= nil and self.vehicle.size.length or 5
    local bx, _, bz = AutoDrive.localToWorld(self.vehicle, 0, 0, length / 2 + 1)
    -- the task driving this route may plan again around the zone (ExitFieldTask)
    self.vehicle.ad.routeBlockedTime = g_time
    PathFinderModule.addLearnedZone(bx, bz, self.vehicle:getName())
end
