HandleHarvesterTurnTask = ADInheritsFrom(AbstractTask)

HandleHarvesterTurnTask.STATE_INITIAL_REVERSING = 1
HandleHarvesterTurnTask.STATE_GENERATE_U_TURN = 2
HandleHarvesterTurnTask.STATE_EXECUTE_U_TURN = 3
HandleHarvesterTurnTask.STATE_STRAIGHTEN_TRAILER = 4
HandleHarvesterTurnTask.REVERSE_TO_COMBINE = 5
HandleHarvesterTurnTask.STATE_FINISHED = 6

HandleHarvesterTurnTask.STATE_GENERATE_TURN = 10
HandleHarvesterTurnTask.STATE_EXECUTE_TURN = 11

HandleHarvesterTurnTask.MAX_INITIAL_REVERSING_DISTANCE = 18

function HandleHarvesterTurnTask:new(vehicle, combine)
    local o = HandleHarvesterTurnTask:create()
    o.vehicle = vehicle
    o.combine = combine
    o:ensureFillNode() -- point de remplissage de la remorque lu d'abord, voir HandleHarvesterTurnTaskTurns.lua
    o.state = HandleHarvesterTurnTask.STATE_GENERATE_TURN
    o.taskType = "HandleHarvesterTurnTask"
    o.nextTurnToTry = 0
    o.turnGenerated = false
    o.triedAllTurnsAfterTurnEnded = false
    o:initEndRow() -- bout de rang derrière l'ensileuse, voir HandleHarvesterTurnTaskEndRow.lua

    local x, y, z = getWorldTranslation(vehicle.components[1].node)
    local diffX, _, diffZ = AutoDrive.worldToLocal(combine, x, y, z, combine.ad.ADRootNode)
    local turnLeft = AutoDrive.sign(diffX) >= 0
    local targetPosition = o:getHarvesterEndTurnPosition()

    if targetPosition == nil then
        AutoDrive.debugPrint(vehicle, AutoDrive.DC_COMBINEINFO, "HandleHarvesterTurnTask:new - Could not determine end position - aborting")
        o.aborting = true
        return o
    end

    if AutoDrive.combineIsTurning(o.combine) or o.cpRow ~= nil then
        diffX, _, diffZ = AutoDrive.worldToLocal(vehicle, targetPosition.x, targetPosition.y, targetPosition.z)
        turnLeft = AutoDrive.sign(diffX) >= 0
    end

    local dirX, _, dirZ =  AutoDrive.localDirectionToWorld(combine, 0, 0, -1)
    local targetDirZ = {x=dirX, z=dirZ}
    dirX, _, dirZ =  AutoDrive.localDirectionToWorld(combine, -1, 0, 0)
    local targetDirX = {x=dirX, z=dirZ}
    if o.cpRow ~= nil then targetDirX, targetDirZ = o:getCpRowTargetDirs() end -- Courseplay : cap du nouveau rang, voir HandleHarvesterTurnTaskEndRow.lua

    local startPosX, startPosY, startPosZ = AutoDrive.localToWorld(vehicle, 0, 0, 0.5 + vehicle.size.length / 2)
    local startPos = { x=startPosX, y=startPosY, z=startPosZ}
    dirX, _, dirZ =  AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local startDirZ = {x=dirX, z=dirZ}
    dirX, _, dirZ =  AutoDrive.localDirectionToWorld(vehicle, 1, 0, 0)
    local startDirX = {x=dirX, z=dirZ}

    o.turnParameters = {
        vehicle = vehicle,
        combine = combine,
        targetLeft = turnLeft,
        targetPosition = targetPosition,
        startPosition = startPos, -- ~0.5m ahead of vehicle,
        targetDir = { x= targetDirX, z = targetDirZ},
        startDir = { x = startDirX, z = startDirZ },
        minRadius = o:getTurnRadius(),
        handleHarvesterTask = o,
        angle = math.abs(AutoDrive.angleBetween({x = startDirZ.x, z = startDirZ.z}, {x = targetDirZ.x, z = targetDirZ.z}))
    }

    o.currentTurn = nil

    AutoDrive.debugPrint(vehicle, AutoDrive.DC_COMBINEINFO, "HandleHarvesterTurnTask  - turnleft: " .. tostring(turnLeft) .. " angle: " .. o.turnParameters.angle)
    if o.endRow then o:logEndRowStart(turnLeft, targetPosition) end -- voir HandleHarvesterTurnTaskEndRow.lua
    return o
end

function HandleHarvesterTurnTask:setUp()
    AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "HandleHarvesterTurnTask:setUp()")
    AutoDrive.setTrailerCoverOpen(self.vehicle, self.trailers, true)
end

function HandleHarvesterTurnTask:reset()
    self.state = HandleHarvesterTurnTask.STATE_GENERATE_TURN
    self.generationStep = 0
    self.turnGenerated = false
end

function HandleHarvesterTurnTask:update(dt)
    if self.aborting then
        self:finished(ADTaskModule.DONT_PROPAGATE)
        self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:setToWaitForCall(true)
        return
    end
    if self.combine ~= nil and g_currentMission.nodeToObject[self.combine.components[1].node] == nil then
        self:finished()
        return
    end
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)

    if self.state == HandleHarvesterTurnTask.STATE_GENERATE_TURN then
        if self.currentTurn == nil then
            self:tryNextTurn()
            if self.endRowGaveUp then
                return
            end
        end
        if self:updateCurrentTurn() then -- erreur Lua ou génération impossible : demi-tour suivant, voir HandleHarvesterTurnTaskTurns.lua
            local points = self.currentTurn:getWayPoints()
            if points ~= nil and #points > 0 then
                self:cleanPoints(points)
                local finished, foundCollision = self:doCollisionCheck(points)
                if finished then
                    self:acceptOrDropTurn(points, foundCollision) -- sol, croisement avec l'ensileuse, voir HandleHarvesterTurnTaskTurns.lua
                end
            else
                self.currentTurn = nil
            end
        end
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
    elseif self.state == HandleHarvesterTurnTask.STATE_EXECUTE_TURN then
        local allowedToSkip = self.vehicle.ad.drivePathModule:getCurrentWayPoint() ~= nil and self.vehicle.ad.drivePathModule:getCurrentWayPoint().allowedToSkip
        local movingDirection = self.combine.movingDirection
        if self.combine.ad.isReverseAttached then
            movingDirection = -self.combine.movingDirection
        end
        local combineMovingAgain = ((self.combine.lastSpeedReal * movingDirection) >= 0.0004)

        if self.vehicle.ad.drivePathModule:isTargetReached() or (allowedToSkip and combineMovingAgain) then
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "Turn finished")
            self.state = HandleHarvesterTurnTask.STATE_FINISHED
            if self.endRow then self:startWaitCombineTurn() end -- bout de rang : attendre la fin de son virage, voir HandleHarvesterTurnTaskReverseToPipe.lua
        else
            self.vehicle.ad.drivePathModule:update(dt)
            -- 30/10 (B, C, D): face to face with the harvester, endless wait, silent stop
            if self:checkTurnStill(dt) then return end -- voir HandleHarvesterTurnTaskHarvesterWay.lua
        end

        if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_COMBINEINFO) then
            local r,g,b = 0,1,0
            if self.colliFound then
                r = 1
                g = 0
            end

            for i, p in ipairs(self.points) do
                if i > 1 then
                    ADDrawingManager:addLineTask(self.points[i-1].x, self.points[i-1].y, self.points[i-1].z, p.x, p.y, p.z, 1, r, g, b)
                    ADDrawingManager:addArrowTask(self.points[i-1].x, self.points[i-1].y, self.points[i-1].z, p.x, p.y, p.z, 1, ADDrawingManager.arrows.position.middle, unpack(AutoDrive.currentColors.ad_color_subPrioSingleConnection))
                end
            end
        end
    elseif self.state == HandleHarvesterTurnTask.STATE_WAIT_HARVESTER_PASS then -- états ajoutés : voir HandleHarvesterTurnTaskHarvesterWay.lua
        self:updateWaitHarvesterPass(dt)
    elseif self.state == HandleHarvesterTurnTask.STATE_BACK_OFF_HARVESTER then
        self:updateBackOffHarvester(dt)
    elseif self.state == HandleHarvesterTurnTask.STATE_WAIT_COMBINE_TURN then -- états ajoutés : voir HandleHarvesterTurnTaskReverseToPipe.lua
        self:updateWaitCombineTurn(dt)
    elseif self.state == HandleHarvesterTurnTask.STATE_REVERSE_TO_PIPE then
        if self:updateReverseToPipe(dt) then
            self.state = HandleHarvesterTurnTask.STATE_FINISHED
        end
    elseif self.state == HandleHarvesterTurnTask.STATE_FINISHED then
        self:finished()
        return
    end
end

function HandleHarvesterTurnTask:continueWith(points)
    self.points = points
    self.vehicle.ad.drivePathModule:setWayPoints(self.points)
    self.state = HandleHarvesterTurnTask.STATE_EXECUTE_TURN
end

function HandleHarvesterTurnTask:tryNextTurn()
    if self:prepareEndRowTurn() then return end -- bout de rang : trace de l'ensileuse, puis recherche de route, voir HandleHarvesterTurnTaskEndRow.lua
    -- 5 turns: the Y manoeuvre (25/10 19:14) and the square manoeuvre (27/10 18:53, coded the same way as the
    -- AutoDrive U-turns) added to the AutoDrive list
    self.nextTurnToTry = (self.nextTurnToTry + 1) % 5
    if self.nextTurnToTry == 0 and self.endRow then
        self.currentTurn = OffsetTurn:new(self.turnParameters)
    elseif self.nextTurnToTry == 0 then
        self.currentTurn = OffsetTurn:new(self.turnParameters)
        if not AutoDrive.combineIsTurning(self.combine) then
            if self.triedAllTurnsAfterTurnEnded == true then
                self:finished(ADTaskModule.DONT_PROPAGATE)
                self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:setToWaitForCall()
            else
                self.triedAllTurnsAfterTurnEnded = true
            end
        end
    elseif self.nextTurnToTry == 1 then
        self.currentTurn = ReverseOffsetTurn:new(self.turnParameters)
    elseif self.nextTurnToTry == 2 then
        self.currentTurn = ForwardOffsetTurn:new(self.turnParameters)
    elseif self.nextTurnToTry == 3 then
        self.currentTurn = SquareTurn:new(self.turnParameters)
    elseif self.nextTurnToTry == 4 then
        self.currentTurn = YTurn:new(self.turnParameters)
    end

    if not self:checkTurnValidity() then -- bout de rang : écart de cap 150-210 (90-270 pour l'équerre et le Y), voir HandleHarvesterTurnTaskTurns.lua
        self.currentTurn = nil
    end

    self.lastCollisionCheckIndex = nil
    self.expectedColliCallbacks = 0
    self.colliFound = false
end

function HandleHarvesterTurnTask:abort()
    self:endBackOffOnAbort() -- recul pour l'ensileuse interrompu, voir HandleHarvesterTurnTaskHarvesterWay.lua
end

function HandleHarvesterTurnTask:finished(propagate)
    AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "HandleHarvesterTurnTask:finished()")
    self.vehicle.ad.taskModule:setCurrentTaskFinished(propagate)
end

function HandleHarvesterTurnTask:cleanPoints(points)
    for i, point in pairs(points) do
        point.y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, point.x,point.y,point.z)
    end
end

function HandleHarvesterTurnTask:getUturnOffsetValues(left)
    local radius = self:getTurnRadius()
    local offsetTurn = (radius*2) > (AutoDrive.getFrontToolWidth(self.combine) + 2)
    if offsetTurn then
        local offset = (radius*2) - AutoDrive.getFrontToolWidth(self.combine)

        local offsetX = offset
        local offsetZ = 5 + ((offset - 3)/1.5) * 1
        if left then
            offsetX = -offsetX
        end
        return offsetX, offsetZ
    end

    return 0, 0
end

function HandleHarvesterTurnTask:generateUTurn(startPos, startDirX, startDirZ, left, offsetValues)
    local radius = self:getTurnRadius()
    local vehX, vehY, vehZ = getWorldTranslation(self.vehicle.components[1].node)
    local resolution = 20

    local offsetX, offsetZ = self:getUturnOffsetValues(left)
    if offsetValues ~= nil then
        offsetX, offsetZ = offsetValues[1], offsetValues[2]
    end
    local points = {}

    if math.abs(offsetX) > 0 then
        local endPoint = { x = startPos.x + offsetX * startDirX.x + offsetZ * startDirZ.x, y=vehY, z = startPos.z + offsetX * startDirX.z + offsetZ * startDirZ.z}

        offsetZ = offsetZ + 2
        local p3 = { x = startPos.x + offsetX * startDirX.x + offsetZ * startDirZ.x, y=vehY, z = startPos.z + offsetX * startDirX.z + offsetZ * startDirZ.z}
        local p0 = { x = startPos.x - 1 * startDirZ.x, y=vehY, z = startPos.z -1 * startDirZ.z}

        AutoDrive.splineInterpolationUserCurvature = 5
        local splinePoints = AutoDrive:createSplineWithControlPoints(startPos, p0, endPoint, p3)
        AutoDrive.splineInterpolation = {
            valid = false
        }

        if splinePoints ~= nil and #splinePoints > 2 then
            for _, wp in pairs(splinePoints) do
                wp.isForward = true
                table.insert(points, wp)
                startPos = wp
            end
        end
    end

    if left then
        for i = 3, (resolution + 1) do
            local circlePoint = {   x = -math.cos((i-1) * math.pi / resolution) * radius + radius,
                                    y = math.sin((i-1) * math.pi / resolution) * radius }

            local point = { x = startPos.x + circlePoint.x * startDirX.x + circlePoint.y * startDirZ.x, y=vehY, z = startPos.z + circlePoint.x * startDirX.z + circlePoint.y * startDirZ.z}
            local rayCastResult = AutoDrive:getTerrainHeightAtWorldPos(point.x, point.z)
            point.y = rayCastResult or point.y
            local dummy = 1
            for i = 1, 1000 do
                dummy = dummy + i
            end
            point.y = AutoDrive.raycastHeight or point.y
            point.isForward = true

            table.insert(points, point)
        end
    else
        for i = 3, (resolution + 1) do
            local circlePoint = {   x = math.cos((i-1) * math.pi / resolution) * radius - radius,
                                    y = math.sin((i-1) * math.pi / resolution) * radius }

            local point = { x = startPos.x + circlePoint.x * startDirX.x + circlePoint.y * startDirZ.x, y=vehY, z = startPos.z + circlePoint.x * startDirX.z + circlePoint.y * startDirZ.z}
            local rayCastResult = AutoDrive:getTerrainHeightAtWorldPos(point.x, point.z)
            point.y = rayCastResult or point.y
            local dummy = 1
            for i = 1, 1000 do
                dummy = dummy + i
            end
            point.y = AutoDrive.raycastHeight or point.y
            point.isForward = true

            table.insert(points, point)
        end
    end

    return points
end

function HandleHarvesterTurnTask:generateStraight(startPos, startDir, length, isReverse)
    local nodes = {}
    local stepLength = 1
    local currentLength = 1
    while currentLength < length do
        local pos = { x = startPos.x + currentLength * startDir.x, z = startPos.z + currentLength * startDir.z}
        local rayCastResult = AutoDrive:getTerrainHeightAtWorldPos(pos.x, pos.z)
        pos.y = rayCastResult or startPos.y
        local dummy = 1
        for i = 1, 1000 do
            dummy = dummy + i
        end
        pos.y = AutoDrive.raycastHeight or pos.y
        if isReverse then
            pos.isReverse = true
        else
            pos.isForward = true
        end
        table.insert(nodes, pos)
        currentLength = currentLength + stepLength
    end

    return nodes
end

function HandleHarvesterTurnTask:generateReverseToCombineSection(measureOnly)
    if self.endRow and measureOnly ~= true then
        return {}
    end
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local diffX, _, diffZ = AutoDrive.worldToLocal(self.combine, x, y, z, self.combine.ad.ADRootNode)

    local nodes = {}

    local sideChaseTermX = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getSideChaseOffsetX()
    local sideChaseTermZ = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getSideChaseOffsetZ(AutoDrive.dynamicChaseDistance or not self.combine.ad.isChopper)

    if not AutoDrive.combineIsTurning(self.combine) and not self.endRow then
        local chasePos = AutoDrive.createWayPointRelativeToVehicle(self.combine, -(sideChaseTermX + self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getPipeSlopeCorrection()), sideChaseTermZ - 2)
        local chasePosFar = AutoDrive.createWayPointRelativeToVehicle(self.combine, -(sideChaseTermX + self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getPipeSlopeCorrection()), sideChaseTermZ - 2 - 20)

        if self.turnParameters.targetLeft then --left
            chasePos = AutoDrive.createWayPointRelativeToVehicle(self.combine, sideChaseTermX + self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getPipeSlopeCorrection(), sideChaseTermZ - 2)
            chasePosFar = AutoDrive.createWayPointRelativeToVehicle(self.combine, sideChaseTermX + self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getPipeSlopeCorrection(), sideChaseTermZ - 2 - 20)
        end

        chasePos.isReverse = true
        chasePosFar.isReverse = true
        chasePos.allowedToSkip = true
        chasePosFar.allowedToSkip = true

        table.insert(nodes, chasePos)
        table.insert(nodes, chasePosFar)

    else
        -- For now, assume this position is 180° reversed to combines start position
        local harvesterTargetPosition = self:getHarvesterEndTurnPosition()
        local nearPosZ = 2
        local farPosZ = 5 + nearPosZ + AutoDrive.getTractorTrainLength(self.vehicle, true, false)
        if harvesterTargetPosition ~= nil then
            local chasePos =    {   x = harvesterTargetPosition.x - self.turnParameters.targetDir.x.x * sideChaseTermX + self.turnParameters.targetDir.z.x * (sideChaseTermZ - nearPosZ),
                                    z = harvesterTargetPosition.z - self.turnParameters.targetDir.x.z * sideChaseTermX + self.turnParameters.targetDir.z.z * (sideChaseTermZ - nearPosZ) }
            local chasePosFar = {   x = harvesterTargetPosition.x - self.turnParameters.targetDir.x.x * sideChaseTermX + self.turnParameters.targetDir.z.x * (sideChaseTermZ - farPosZ),
                                    z = harvesterTargetPosition.z - self.turnParameters.targetDir.x.z * sideChaseTermX + self.turnParameters.targetDir.z.z * (sideChaseTermZ - farPosZ) }

            if self.turnParameters.targetLeft then
                chasePos =    {     x = harvesterTargetPosition.x + self.turnParameters.targetDir.x.x * sideChaseTermX + self.turnParameters.targetDir.z.x * (sideChaseTermZ - nearPosZ),
                                    z = harvesterTargetPosition.z + self.turnParameters.targetDir.x.z * sideChaseTermX + self.turnParameters.targetDir.z.z * (sideChaseTermZ - nearPosZ) }
                chasePosFar =    {  x = harvesterTargetPosition.x + self.turnParameters.targetDir.x.x * sideChaseTermX + self.turnParameters.targetDir.z.x * (sideChaseTermZ - farPosZ),
                                    z = harvesterTargetPosition.z + self.turnParameters.targetDir.x.z * sideChaseTermX + self.turnParameters.targetDir.z.z * (sideChaseTermZ - farPosZ) }
            end

            chasePos.y = AutoDrive:getTerrainHeightAtWorldPos(chasePos.x, chasePos.z)
            chasePosFar.y = AutoDrive:getTerrainHeightAtWorldPos(chasePosFar.x, chasePosFar.z)

            chasePos.isReverse = true
            chasePosFar.isReverse = true
            chasePos.allowedToSkip = true
            chasePosFar.allowedToSkip = true

            table.insert(nodes, chasePos)
            table.insert(nodes, chasePosFar)
        end
    end

    return nodes
end

-- Returns bool finished, bool foundCollision
function HandleHarvesterTurnTask:doCollisionCheck(waypoints)
    if self.lastCollisionCheckIndex == nil then
        self.lastCollisionCheckIndex = 1
    end

    --print("HandleHarvesterTurnTask:doCollisionCheck: index: " .. self.lastCollisionCheckIndex .. " / " .. #waypoints)

    --- Coll check:
    local widthX = self.vehicle.size.width / 1.75
    local height = 2.3
    local mask = AutoDrive.collisionMaskTerrain

    for i, wp in pairs(waypoints) do
        if i > self.lastCollisionCheckIndex and i <= (#waypoints - 1) and self.expectedColliCallbacks == 0 then
            local wpLast = waypoints[i - 1]
            local deltaX, deltaY, deltaZ = wp.x - wpLast.x, wp.y - wpLast.y, wp.z - wpLast.z
            local centerX, centerY, centerZ = wpLast.x + deltaX/2,  wpLast.y + deltaY/2,  wpLast.z + deltaZ/2
            local angleRad = math.atan2(deltaX, deltaZ)
            angleRad = AutoDrive.normalizeAngle(angleRad)
            local length = MathUtil.vector2Length(deltaX, deltaZ) / 2

            local angleX = -MathUtil.getYRotationFromDirection(deltaY, length*2)

            local shapes = overlapBox(centerX, centerY+3, centerZ, angleX, angleRad, 0, widthX, height, length, "collisionTestCallback", self, mask, true, true, true, true)
            if shapes > 0 then
                self.expectedColliCallbacks = self.expectedColliCallbacks + 1
                --print("Expecting collisionTestCallbacks: " .. self.expectedColliCallbacks)
            end
            if AutoDrive.getDebugChannelIsSet(AutoDrive.DC_COMBINEINFO) then
                local r,g,b = 0,1,0
                if shapes > 0 then
                    r = 1
                    g = 0
                    DebugUtil.drawOverlapBox(centerX, centerY+3, centerZ, angleX, angleRad, 0, widthX, height, length, r, g, b)
                end
                DebugUtil.drawOverlapBox(centerX, centerY+3, centerZ, angleX, angleRad, 0, widthX, height, length, r, g, b)
            end
            self.lastCollisionCheckIndex = i
        end
    end

    return (self.lastCollisionCheckIndex == (#waypoints - 1) and self.expectedColliCallbacks == 0) or self.colliFound, self.colliFound
end

function HandleHarvesterTurnTask:collisionTestCallback(transformId, x, y, z, distance)
    self.expectedColliCallbacks = math.max(-1, self.expectedColliCallbacks - 1)
    --print("Received collisionTestCallback. Outstanding: " .. self.expectedColliCallbacks)
    if transformId ~= 0 and transformId ~= g_currentMission.terrainRootNode then
        if g_currentMission.nodeToObject[transformId] ~= nil then
            local object = g_currentMission.nodeToObject[transformId]
            local isHarvester = self.endRow and self.combine ~= nil and (object == self.combine or AutoDrive:checkIsConnected(self.combine, object))
            if object ~= self.vehicle and not AutoDrive:checkIsConnected(self.vehicle, object) and not isHarvester then
                self.colliFound = true
            end
        else
            self.colliFound = true
        end
    end
end

function HandleHarvesterTurnTask:getHarvesterEndTurnPosition()
    if self.combine.spec_aiFieldWorker ~= nil then
        local spec = self.combine.spec_aiFieldWorker
        if spec.lastTurnStrategy ~= nil then
            if spec.lastTurnStrategy.turnSegments ~= nil then
                local segments = spec.lastTurnStrategy.turnSegments
                if segments[#segments] ~= nil then
                    if segments[#segments].endPoint ~= nil then
                        local endPoint = segments[#segments].endPoint
                        local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
                        return {x = endPoint[1], y = endPoint[2], z = endPoint[3]}
                    end
                end
            end
        end
    end
    local cpRowEntry = self:getCpRowEntryPosition() if cpRowEntry ~= nil then return cpRowEntry end -- Courseplay : entrée du nouveau rang, voir HandleHarvesterTurnTaskEndRow.lua
    return nil
end

function HandleHarvesterTurnTask:getI18nInfo()
    local harvester = AbstractTask.getHarvesterI18n(self.combine)
    if self.state == HandleHarvesterTurnTask.STATE_WAIT_COMBINE_TURN then
        return "$l10n_AD_task_waiting_comma; " .. harvester .. " $l10n_AD_task_is_turning;"
    elseif self.state == HandleHarvesterTurnTask.STATE_REVERSE_TO_PIPE then
        return "$l10n_AD_task_reverse_to; " .. harvester
    elseif self.endRow then
        return "$l10n_AD_task_end_row_turn;"
    end
    return "$l10n_AD_task_uturn;"
end