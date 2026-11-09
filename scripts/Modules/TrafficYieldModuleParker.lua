-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleParker.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : le véhicule qui se gare (PARKER), puis son retour
-- sur le trajet.
--
-- Règle :
-- - il cherche une place au bord de la route devant lui, dans l'espace laissé par celui qui recule (le long du trajet,
--   sinon tout droit depuis son axe quand le trajet devant est trop court) ;
-- - il suit le trajet parallèle jusqu'à ce que tout l'attelage, remorque comprise, soit hors de la route ; l'autre passe
--   ensuite (30/10) ; arrêté trop tôt, il finit de s'aligner dès que la voie est libre ;
-- - l'autre trop près devant avant d'être hors de la route (25/10) : l'autre recule de MORE_ROOM m de plus (deux fois au
--   plus) pendant qu'il attend ;
-- - garé, bloqué ensuite par un obstacle contre le nez hors de mon trajet (30/10) : il recule sur sa trace jusqu'à son
--   trajet, puis repart (updateRejoin).
--
-- Branché par : TrafficYieldModule:handle (états PARKER_*, updateRejoin), updateYielderApproach (PARKER_MOVE),
-- updateDetachedWait et endPlan (hasPassedMe, finishAlignment).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- 25/10 (7R and 942 nose to nose by the sheds): the parker reached the reverser before being off the road and
-- called itself parked, the reverser could not pass. Now the reverser backs off ADTrafficYieldModule.MORE_ROOM
-- more meters (twice at most), the parker waits meanwhile, then finishes pulling over.
ADTrafficYieldModule.MORE_ROOM = 20           -- m backed off once more by the reverser
ADTrafficYieldModule.MORE_ROOM_TRIES = 2
ADTrafficYieldModule.MORE_ROOM_MIN = 5        -- m: backed off less than this, no room behind it, the parker stays where it is

-- ------------------------------------------------------------------------------------------------------------
-- Recherche d'une place
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:updateParkerSearch(dt)
    local plan = self.plan
    self:holdVehicle(dt)

    if plan.mode == "branch" then
        if plan.hidden then
            self.vehicle.ad.specialDrivingModule:releaseVehicle()
            ADTrafficYieldModule.resyncWayPoints(self.vehicle)
            self:setState(ADTrafficYieldModule.STATE_PARKER_PASS)
        end
        return
    end

    if g_time - self.lastSearchTime < ADTrafficYieldModule.SEARCH_INTERVAL then
        return
    end
    self.lastSearchTime = g_time

    local spot = self:searchParkingSpot()
    if spot ~= nil then
        self:log("spot found: side=%s field=%s", tostring(spot.side), tostring(spot.onField))
        plan.parkSpot = spot
        plan.reverserMayStop = true
        self:setState(ADTrafficYieldModule.STATE_PARKER_MOVE)
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        return
    end

    -- if the reverser cannot make more room, it ends the plan itself after a last search delay
end

-- searches a free spot on the roadside in front of the parker, inside the gap left by the reverser.
-- The road geometry of the route is followed (curves), the right side first, the left side as a last resort;
-- the straight search from the vehicle axis is only used when the route ahead is too short.
function ADTrafficYieldModule:searchParkingSpot()
    local rx, ry, rz = ADTrafficYieldModule.getPosition(self.partner)
    local _, _, reverserLocalZ = AutoDrive.worldToLocal(self.vehicle, rx, ry, rz)
    local reverserFront = ADTrafficYieldModule.getTrainExtents(self.partner)
    local gapEnd = reverserLocalZ - reverserFront - 2
    if gapEnd <= 0 then
        return nil
    end
    return self:searchSpotBySides(gapEnd, false) or self:searchParkingSpotStraight()
end

function ADTrafficYieldModule:searchParkingSpotStraight()
    local parker = self.vehicle
    local reverser = self.partner

    local px, py, pz = ADTrafficYieldModule.getPosition(parker)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(parker)

    local parkerWidth = ADTrafficYieldModule.getWidth(parker)
    local reverserWidth = ADTrafficYieldModule.getWidth(reverser)
    for _, v in ipairs(ADTrafficYieldModule.getQueueBehind(reverser, parker)) do
        reverserWidth = math.max(reverserWidth, ADTrafficYieldModule.getWidth(v))
    end
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(parker)
    local parkerFront, parkerRear = ADTrafficYieldModule.getTrainExtents(parker)
    local totalLength = parkerFront + parkerRear
    local reverserFront = ADTrafficYieldModule.getTrainExtents(reverser)

    -- free gap in front of the parker up to the front of the reverser (front implements included)
    local rx, ry, rz = ADTrafficYieldModule.getPosition(reverser)
    local _, _, reverserLocalZ = AutoDrive.worldToLocal(parker, rx, ry, rz)
    local gapEnd = reverserLocalZ - reverserFront - 2

    local margin = AutoDrive.getSetting("trafficYieldMargin") or ADTrafficYieldModule.LATERAL_MARGIN
    local baseLateral = (parkerWidth + reverserWidth) / 2 + margin
    -- towed units need a straight run along the roadside after the swerve to line up behind the tractor
    local trailLength = math.max(0, parkerRear - tractorLength / 2)
    local runOut = ADTrafficYieldModule.getRunOut(trailLength)
    local minForward = math.max(8, tractorLength * 1.5, baseLateral * 2.5, trailLength)
    local maxForward = gapEnd - parkerFront - runOut

    if maxForward < minForward then
        return nil
    end

    -- local +x is left in GIANTS, so right side is negative x
    -- driving side only (see getSides)
    local sides = ADTrafficYieldModule.getSides()
    local laterals = {baseLateral, baseLateral + 1.0, baseLateral + 2.0}
    -- first pass: spot outside the fields (grass strip), second pass: spot may overlap a field
    -- every option on the driving side: grass first, then field
    for _, side in ipairs(sides) do
    for pass = 1, 2 do
    local allowField = pass == 2
        for _, lateral in ipairs(laterals) do
            local forward = minForward
            while forward <= maxForward do
                if self:isSpotFree(px, py, pz, dirX, dirZ, forward, side.sign * lateral, parkerWidth, parkerFront, totalLength, allowField, runOut) then
                    local wx, wy, wz = AutoDrive.localToWorld(parker, side.sign * lateral, 0, forward)
                    local finalX, _, finalZ = AutoDrive.localToWorld(parker, side.sign * lateral, 0, forward + runOut)
                    local ax, _, az = AutoDrive.localToWorld(parker, side.sign * lateral, 0, forward + runOut + 8)
                    return {
                        finalX = finalX, finalZ = finalZ,
                        originX = px, originZ = pz,
                        lateralAbs = lateral,
                        onField = allowField,
                        side = side.name,
                        forward = forward,
                        lateral = side.sign * lateral,
                        x = wx, y = wy, z = wz,
                        aimX = ax, aimZ = az,
                        dirX = dirX, dirZ = dirZ
                    }
                end
                forward = forward + 2
            end
        end
    end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Rangement sur la place
-- ------------------------------------------------------------------------------------------------------------
-- index of the path point closest to a world position, searching from 'fromIndex'
function ADTrafficYieldModule.getClosestPathIndex(path, x, z, fromIndex)
    local bestIndex, bestDistance = fromIndex or 1, math.huge
    for k = math.max(1, (fromIndex or 1) - 2), #path do
        local d = MathUtil.vector2Length(path[k].x - x, path[k].z - z)
        if d < bestDistance then
            bestIndex, bestDistance = k, d
        end
    end
    return bestIndex, bestDistance
end

-- rear of the last towed unit lies on the parallel path (close to it and parallel)
function ADTrafficYieldModule:isRearOnPath(path)
    local units, count = AutoDrive.getAllUnits(self.vehicle)
    local unit = self.vehicle
    if units ~= nil and count ~= nil and count > 1 and units[count] ~= nil then
        unit = units[count]
    end
    local _, length = ADTrafficYieldModule.getUnitDimensions(unit)
    local rx, _, rz = localToWorld(unit.components[1].node, 0, 0, -length / 2)
    -- 30/10 (B): the last unit is off the road, rear and centre (in a bend it is not parallel to the path)
    local mx, _, mz = getWorldTranslation(unit.components[1].node)
    if #path >= 2 and ADTrafficYieldModule.isOffRoad(path, rx, rz) and ADTrafficYieldModule.isOffRoad(path, mx, mz) then
        return true
    end
    local index, distance = ADTrafficYieldModule.getClosestPathIndex(path, rx, rz, 1)
    -- 30/10: distance to the path line, not to its points (2 m apart: a rear 0.3 m from the line could be 1 m from a point)
    local segment = math.huge
    for k = math.max(1, index - 1), math.min(#path - 1, index) do
        local a, b = path[k], path[k + 1]
        local sx, sz = b.x - a.x, b.z - a.z
        local l2 = sx * sx + sz * sz
        local t = l2 > 0.0001 and math.max(0, math.min(1, ((rx - a.x) * sx + (rz - a.z) * sz) / l2)) or 0
        segment = math.min(segment, MathUtil.vector2Length(rx - (a.x + sx * t), rz - (a.z + sz * t)))
    end
    distance = math.min(distance, segment)
    if distance > 0.6 then
        return false
    end
    -- the rear must be on the constant offset part of the path, not on the ramp
    local p = path[index]
    if math.abs(p.offset) < math.abs(path[#path].offset) - 0.3 then
        return false
    end
    local ux, _, uz = localDirectionToWorld(unit.components[1].node, 0, 0, 1)
    local l = MathUtil.vector2Length(ux, uz)
    return l < 0.01 or (ux * p.dirX + uz * p.dirZ) / l > 0.985
end

-- follows the parallel path with a look-ahead point; returns true when the train is parked
function ADTrafficYieldModule:followParkPath(dt, spot)
    local path = spot.path
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    self.pathIndex = ADTrafficYieldModule.getClosestPathIndex(path, x, z, self.pathIndex or 1)
    local current = path[self.pathIndex]

    local reachedFinal = current.s >= spot.finalS
    local atPathEnd = self.pathIndex >= #path - 1
    if (reachedFinal and self:isRearOnPath(path)) or atPathEnd then
        self.pathIndex = nil
        return true
    end

    -- look-ahead target on the path
    local lookAhead = 5 + ADTrafficYieldModule.getSpeedKmh(self.vehicle) / 3.6
    local target = path[#path]
    for k = self.pathIndex, #path do
        if MathUtil.vector2Length(path[k].x - x, path[k].z - z) >= lookAhead then
            target = path[k]
            break
        end
    end
    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    self:ensureMotorStarted()
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, {x = target.x, y = spot.y, z = target.z}, ADTrafficYieldModule.PARK_SPEED, false, 0.5, ADTrafficYieldModule.PARK_SPEED)
    return false
end

-- last towed unit heading close to the road direction (less than about 10 degrees)
function ADTrafficYieldModule:isLastUnitParallel(spot)
    local units, count = AutoDrive.getAllUnits(self.vehicle)
    local unit = self.vehicle
    if units ~= nil and count ~= nil and count > 1 and units[count] ~= nil then
        unit = units[count]
    end
    local ux, _, uz = localDirectionToWorld(unit.components[1].node, 0, 0, 1)
    local l = MathUtil.vector2Length(ux, uz)
    if l < 0.01 then
        return true
    end
    return (ux * spot.dirX + uz * spot.dirZ) / l > 0.985
end

-- lateral distance of the rear of the last towed unit from the original road line
function ADTrafficYieldModule:getRearLateralOffset(spot)
    local units, count = AutoDrive.getAllUnits(self.vehicle)
    local unit = self.vehicle
    if units ~= nil and count ~= nil and count > 1 and units[count] ~= nil then
        unit = units[count]
    end
    local _, length = ADTrafficYieldModule.getUnitDimensions(unit)
    local rx, _, rz = localToWorld(unit.components[1].node, 0, 0, -length / 2)
    return math.abs((rx - spot.originX) * spot.dirZ - (rz - spot.originZ) * spot.dirX)
end

-- true while the parker waits for the reverser to make room (the caller returns)
function ADTrafficYieldModule:requestMoreRoom(dt)
    local plan = self.plan
    local room = plan.moreRoom
    if room ~= nil and room.pending then
        self:holdVehicle(dt)
        return true
    end
    if room ~= nil and room.failed then
        return false
    end
    if (plan.moreRoomCount or 0) >= ADTrafficYieldModule.MORE_ROOM_TRIES or plan.mode == "branch" then
        return false
    end
    plan.moreRoomCount = (plan.moreRoomCount or 0) + 1
    plan.moreRoom = {pending = true}
    self:log("%s too close in front before I am off the road: it backs off %d m more (%d/%d)", ADTrafficYieldModule.getName(self.partner),
        ADTrafficYieldModule.MORE_ROOM, plan.moreRoomCount, ADTrafficYieldModule.MORE_ROOM_TRIES)
    self:holdVehicle(dt)
    return true
end

-- the move timer does not run while the parker waits for room
function ADTrafficYieldModule:parkTimeout(dt, limit)
    local room = self.plan.moreRoom
    return self.stateTimer:timer(true, limit, room ~= nil and room.pending and 0 or dt)
end

function ADTrafficYieldModule:updateParkerMove(dt)
    local plan = self.plan
    local spot = plan.parkSpot
    local _, _, spotLocalZ = AutoDrive.worldToLocal(self.vehicle, spot.x, spot.y, spot.z)
    local _, _, finalLocalZ = AutoDrive.worldToLocal(self.vehicle, spot.finalX, spot.y, spot.finalZ)

    -- keep a safety distance to the waiting reverser
    local reverser = self.partner
    local rx, ry, rz = ADTrafficYieldModule.getPosition(reverser)
    local reverserLocalX, _, reverserLocalZ = AutoDrive.worldToLocal(self.vehicle, rx, ry, rz)
    local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local reverserFrontExtent = ADTrafficYieldModule.getTrainExtents(reverser)
    local sideBySide = math.abs(reverserLocalX) > (ADTrafficYieldModule.getWidth(self.vehicle) + ADTrafficYieldModule.getWidth(reverser)) / 2
    local tooCloseToReverser = not sideBySide and (reverserLocalZ - reverserFrontExtent) - myFront < 3

    -- parallel path along the route (curves followed)
    if spot.path ~= nil then
        if tooCloseToReverser and self:requestMoreRoom(dt) then
            return
        end
        if tooCloseToReverser then
            self:log("parked early: %s too close in front, the train may not be aligned", ADTrafficYieldModule.getName(reverser))
        end
        if tooCloseToReverser or self:followParkPath(dt, spot) or self:parkTimeout(dt, 60000) then
            self.pathIndex = nil
            -- 30/10 (B): the other one goes once my whole train, trailer included, is off the road
            if tooCloseToReverser or self:isRearOnPath(spot.path) then
                plan.parked = true
            else
                self:log("at the end of the roadside path, trailer still on the road: %s waits", ADTrafficYieldModule.getName(reverser))
                print(string.format("[AD-Croise] %s: remorque pas encore hors du chemin, %s attend", ADTrafficYieldModule.getName(self.vehicle),
                    ADTrafficYieldModule.getName(reverser)))
            end
            self:setState(ADTrafficYieldModule.STATE_PARKER_WAIT)
            self:holdVehicle(dt)
        end
        return
    end

    local rearAligned = self:getRearLateralOffset(spot) >= math.abs(spot.lateralAbs) - 0.2 and self:isLastUnitParallel(spot)
    local reachedFinal = finalLocalZ <= 0.5

    if tooCloseToReverser and not (reachedFinal and rearAligned) and self:requestMoreRoom(dt) then
        return
    end
    if (reachedFinal and rearAligned) or finalLocalZ <= -6 or tooCloseToReverser then
        self:log("parked: %s", (reachedFinal and rearAligned) and "aligned on the spot" or (finalLocalZ <= -6 and "spot passed")
            or string.format("%s too close in front, may still be on the road", ADTrafficYieldModule.getName(reverser)))
        plan.parked = true
        self:setState(ADTrafficYieldModule.STATE_PARKER_WAIT)
        self:holdVehicle(dt)
        return
    end

    if self:parkTimeout(dt, 45000) then
        self:log("parked: 45 s timeout, may still be on the road")
        plan.parked = true
        self:setState(ADTrafficYieldModule.STATE_PARKER_WAIT)
        self:holdVehicle(dt)
        return
    end

    -- obstacle in front while moving to the spot (pedestrian, AI traffic...)
    if self.vehicle.ad.sensors ~= nil and self.vehicle.ad.sensors.frontSensor ~= nil and self.vehicle.ad.sensors.frontSensor:pollInfo() and spotLocalZ > 4 then
        self:holdVehicle(dt)
        return
    end

    -- first swerve to the roadside line, then follow it straight so the towed units line up
    local aimTarget
    if spotLocalZ > 6 then
        aimTarget = {x = spot.x, y = spot.y, z = spot.z}
    else
        aimTarget = {x = spot.aimX, y = spot.y, z = spot.aimZ}
    end
    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    self:ensureMotorStarted()
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, aimTarget, ADTrafficYieldModule.PARK_SPEED, false, 0.5, ADTrafficYieldModule.PARK_SPEED)
end

-- ------------------------------------------------------------------------------------------------------------
-- Garé : attendre que l'autre soit passé
-- ------------------------------------------------------------------------------------------------------------
-- true when 'watched' has driven past me. Measured along the road direction (not my own axis, which can
-- be turned after pulling over), plus a fallback: it no longer comes towards me and is far enough.
function ADTrafficYieldModule:hasPassedMe(watched, dirX, dirZ)
    if watched == nil or watched.components == nil then
        return true
    end
    local px, _, pz = ADTrafficYieldModule.getPosition(self.vehicle)
    local wx, _, wz = ADTrafficYieldModule.getPosition(watched)
    if dirX == nil or dirZ == nil then
        dirX, dirZ = ADTrafficYieldModule.getDirection(self.vehicle)
    end
    local myFront, myRear = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local _, watchedRear = ADTrafficYieldModule.getTrainExtents(watched)
    local along = (wx - px) * dirX + (wz - pz) * dirZ
    if along < -(myRear + watchedRear + 2) then
        return true
    end
    -- the watched vehicle drives away from me and is past my front
    local distance = MathUtil.vector2Length(wx - px, wz - pz)
    if along < -myFront and distance > myFront + myRear + watchedRear + 5 then
        local wdx, wdz = ADTrafficYieldModule.getDirection(watched)
        if (wdx * (wx - px) + wdz * (wz - pz)) > 0 then
            return true
        end
    end
    return false
end

-- a train stopped before being lined up on its roadside path (other vehicle too close in front) still blocks
-- the road with its trailer: as soon as the way ahead is clear, it drives on along the path until aligned.
-- Returns true while it drives (the caller must not hold the vehicle)
function ADTrafficYieldModule:finishAlignment(dt, spot, watched)
    if spot == nil or spot.path == nil or self.alignmentDone then
        return false
    end
    if self:isRearOnPath(spot.path) then
        self.alignmentDone = true
        self.pathIndex = nil
        return false
    end
    if watched ~= nil and watched.components ~= nil then
        local wx, wy, wz = ADTrafficYieldModule.getPosition(watched)
        local watchedLocalX, _, watchedLocalZ = AutoDrive.worldToLocal(self.vehicle, wx, wy, wz)
        local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        local watchedFront = ADTrafficYieldModule.getTrainExtents(watched)
        local sideBySide = math.abs(watchedLocalX) > (ADTrafficYieldModule.getWidth(self.vehicle) + ADTrafficYieldModule.getWidth(watched)) / 2
        if not sideBySide and watchedLocalZ > 0 and (watchedLocalZ - watchedFront) - myFront < 3 then
            return false
        end
    end
    if self.vehicle.ad.sensors ~= nil and self.vehicle.ad.sensors.frontSensor ~= nil and self.vehicle.ad.sensors.frontSensor:pollInfo() then
        return false
    end
    if (self.alignmentTime or 0) == 0 then
        self:log("finishing the alignment on the roadside path")
    end
    self.alignmentTime = (self.alignmentTime or 0) + dt
    if self.alignmentTime > 30000 or self:followParkPath(dt, spot) then
        self.alignmentDone = true
        self.pathIndex = nil
        return false
    end
    return true
end

function ADTrafficYieldModule:updateParkerWait(dt)
    local plan = self.plan
    if not self:finishAlignment(dt, plan.parkSpot, self.partner) then
        self:holdVehicle(dt)
    end
    -- B: the other one waits until the trailer is off the road (or the alignment gave up after 30 s)
    if not plan.parked and (self.alignmentDone or plan.parkSpot == nil or plan.parkSpot.path == nil) then
        plan.parked = true
        local off = plan.parkSpot == nil or plan.parkSpot.path == nil or self:isRearOnPath(plan.parkSpot.path)
        self:log("trailer %s, %s may pass", off and "off the road" or "maybe still on the road", ADTrafficYieldModule.getName(self.partner))
        print(string.format("[AD-Croise] %s: %s, %s peut passer", ADTrafficYieldModule.getName(self.vehicle),
            off and "remorque hors du chemin" or "remorque peut-etre encore sur le chemin (alignement abandonne apres 30 s)", ADTrafficYieldModule.getName(self.partner)))
    end
    if plan.passed then
        self:endPlan("reverser passed", true)
        return
    end
    -- double check from parker side: the reverser is behind us (along the road)
    local spot = plan.parkSpot
    if self:hasPassedMe(self.partner, spot and spot.dirX, spot and spot.dirZ) then
        plan.passed = true
        self:endPlan("reverser passed", true)
        return
    end
    if self.stateTimer:timer(true, 120000, dt) then
        self:endPlan("parker wait timeout", false)
    end
end

function ADTrafficYieldModule:updateParkerPass(dt)
    -- normal driving, watch until the hidden reverser is behind us
    local reverser = self.partner
    local rx, ry, rz = ADTrafficYieldModule.getPosition(reverser)
    local _, _, reverserLocalZ = AutoDrive.worldToLocal(self.vehicle, rx, ry, rz)
    local myLength = ADTrafficYieldModule.getTotalLength(self.vehicle)
    if reverserLocalZ < -(myLength + 3) and not ADTrafficYieldModule.isAheadOnMyRoute(self.vehicle, reverser) then
        self.plan.passed = true
        self:endPlan("parker passed the side branch", true)
        return
    end
    if self.stateTimer:timer(true, 90000, dt) then
        self:endPlan("parker pass timeout", false)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Retour sur mon trajet par ma trace
-- ------------------------------------------------------------------------------------------------------------
-- 30/10 (D): off my route after pulling over, stopped with an obstacle against the nose (942 Vario against the railing of
-- the bridge, no lane beside it, no detour): I back out along the roadside path I drove, back onto my route, then drive on
-- Returns true while backing out
function ADTrafficYieldModule:updateRejoin(dt)
    local trace = self.parkTrace
    if trace == nil or g_time - trace.time > ADTrafficYieldModule.PARK_TRACE_TTL then
        self.parkTrace, self.rejoin = nil, nil
        return false
    end
    if self.rejoin == nil then
        if self.state ~= ADTrafficYieldModule.STATE_IDLE and self.state ~= ADTrafficYieldModule.STATE_REVERSER_PASS
            and self.state ~= ADTrafficYieldModule.STATE_PRIORITY_APPROACH and self.state ~= ADTrafficYieldModule.STATE_PARKER_PASS then
            self.rejoinTimer:timer(false)
            return false
        end
        local approach = self.vehicle.ad.approachModule
        local hit = approach ~= nil and approach.getHit ~= nil and approach:getHit() or nil
        local stuck = hit ~= nil and not hit.isVehicle and (hit.distance or math.huge) <= 1 and ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1
        if not self.rejoinTimer:timer(stuck, ADTrafficYieldModule.REJOIN_STUCK_MS, dt) then
            if not stuck and not self:isOffMyRoute(1.5) then
                self.parkTrace = nil -- back on my route: the trace is no longer needed
            end
            return false
        end
        self.rejoinTimer:timer(false)
        if not self:isOffMyRoute(1.5) then
            return false
        end
        if ADTrafficYieldModule.cannotReverse(self.vehicle) then
            self:log("blocked off my route, articulated trailer: I do not back out")
            self.parkTrace = nil
            return false
        end
        -- the path points behind me, nearest first, down to the start of the path (on the road)
        local path = trace.path
        local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
        local index, distance = ADTrafficYieldModule.getClosestPathIndex(path, x, z, 1)
        if distance > 4 then
            self:log("blocked off my route but %.1f m from my roadside path: no way back known", distance)
            self.parkTrace = nil
            return false
        end
        local targets = {}
        for k = index - 2, 1, -2 do
            table.insert(targets, {x = path[k].x, y = trace.spot.y or 0, z = path[k].z})
        end
        if #targets == 0 then
            return false
        end
        self.rejoin = {targets = targets, index = 1, startTime = g_time, name = tostring(hit.name)}
        self:log("blocked by '%s' off my route: backing out along my roadside path (%d points)", tostring(hit.name), #targets)
        print(string.format("[AD-Croise] %s: bloque par '%s' hors de mon trajet, je recule sur ma trace jusqu'a mon chemin",
            ADTrafficYieldModule.getName(self.vehicle), tostring(hit.name)))
    end
    local rejoin = self.rejoin
    if g_time - rejoin.startTime > ADTrafficYieldModule.REJOIN_TIMEOUT then
        self:log("backing out: timeout")
        print(string.format("[AD-Croise] %s: recul sur ma trace abandonne apres %d s", ADTrafficYieldModule.getName(self.vehicle), ADTrafficYieldModule.REJOIN_TIMEOUT / 1000))
        self.rejoin, self.parkTrace = nil, nil
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        return false
    end
    local target = rejoin.targets[rejoin.index]
    if self:reverseTowards(dt, target, 1.5) then
        rejoin.index = rejoin.index + 1
        if rejoin.index > #rejoin.targets or not self:isOffMyRoute(0.8) then
            self:log("back on my route")
            print(string.format("[AD-Croise] %s: revenu sur mon chemin, je repars", ADTrafficYieldModule.getName(self.vehicle)))
            self.rejoin, self.parkTrace = nil, nil
            self.vehicle.ad.specialDrivingModule:releaseVehicle()
            ADTrafficYieldModule.resyncWayPoints(self.vehicle)
            return false
        end
    end
    return true
end
