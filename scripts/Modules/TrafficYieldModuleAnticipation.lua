-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleAnticipation.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : anticipation. Les trajets des véhicules AutoDrive
-- sont comparés pour voir un véhicule en face bien avant les capteurs.
--
-- Règle :
-- - toutes les ANTICIPATION_INTERVAL ms, sur ANTICIPATION_DISTANCE m de trajet : portion que l'autre parcourt en sens
--   inverse (findHeadOnSection) ; seules les têtes de file comptent, celui qui sort de la portion avant que l'autre
--   y entre passe simplement le premier ;
-- - d'abord le plan d'avance (startEarlyPlan, TrafficYieldModuleEarlyPlan.lua) ; sinon chacun freine pour sa moitié
--   de la distance libre, s'arrête à ANTICIPATION_GAP m, puis le plan classique démarre (startPlan) ;
-- - le croisement (portion rouge, Intersection) passe d'abord (26/10) ;
-- - file de véhicules (S7, 28/10) : toute la file en face, 4 au plus, QUEUE_GAP m entre deux ;
-- - pendant un plan, un 3e véhicule en face fait aussi ralentir et s'arrêter (holdForOtherOncoming).
-- Le trajet devant chaque véhicule est calculé une fois par image et partagé : ADTrafficYieldModule.routeCache, un
-- seul cache pour tous les véhicules (champ de la table, modifié pendant le jeu).
--
-- Branché par : TrafficYieldModule:handle (updateAnticipation, holdForOtherOncoming) ; les files et la portion face à
-- face servent aussi aux autres fichiers TrafficYieldModule*.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Trajet devant chaque véhicule (cache partagé)
-- ------------------------------------------------------------------------------------------------------------
-- route ahead of each vehicle computed once per frame and shared by every vehicle that looks at it
-- (the tables returned are only read, never changed)
ADTrafficYieldModule.routeCache = setmetatable({}, {__mode = "k"})

-- graph ids of the next waypoints of a route with the distance along the route to each of them
function ADTrafficYieldModule.collectRouteAhead(vehicle, maxDistance)
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    local cached = ADTrafficYieldModule.routeCache[vehicle]
    if cached ~= nil and cached.loop == g_updateLoopIndex and cached.maxDistance == maxDistance
        and cached.wayPoints == wayPoints and cached.currentIndex == currentIndex then
        return cached.list, cached.distById
    end
    local list, distById = ADTrafficYieldModule.buildRouteAhead(vehicle, wayPoints, currentIndex, maxDistance)
    ADTrafficYieldModule.routeCache[vehicle] = {loop = g_updateLoopIndex, maxDistance = maxDistance, wayPoints = wayPoints,
                                                currentIndex = currentIndex, list = list, distById = distById}
    return list, distById
end

function ADTrafficYieldModule.buildRouteAhead(vehicle, wayPoints, currentIndex, maxDistance)
    local list, distById = {}, {}
    if wayPoints == nil or currentIndex == nil then
        return list, distById
    end
    local lastX, _, lastZ = ADTrafficYieldModule.getPosition(vehicle)
    local distance = 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if distance > maxDistance then
            break
        end
        if wp.id ~= nil and distById[wp.id] == nil then
            table.insert(list, wp.id)
            distById[wp.id] = distance
        end
    end
    return list, distById
end

-- ------------------------------------------------------------------------------------------------------------
-- File de véhicules
-- ------------------------------------------------------------------------------------------------------------
-- états où le véhicule roule sur son trajet (un véhicule garé ou en manœuvre ne gêne pas)
ADTrafficYieldModule.ON_ROUTE_STATES = {
    [ADTrafficYieldModule.STATE_IDLE] = true,
    [ADTrafficYieldModule.STATE_YIELDER_APPROACH] = true,
    [ADTrafficYieldModule.STATE_PRIORITY_APPROACH] = true,
    [ADTrafficYieldModule.STATE_REVERSER_PASS] = true,
    [ADTrafficYieldModule.STATE_PARKER_PASS] = true
}

-- another AD vehicle drives ahead of me on my route, in my direction, before 'beforeDistance' metres:
-- I am not the head of the convoy, the leader deals with the oncoming vehicle first
function ADTrafficYieldModule:hasLeaderAhead(myDist, beforeDistance, excluded)
    for _, other in pairs(AutoDrive.getAllVehicles()) do
        if other ~= self.vehicle and other ~= excluded and other.ad ~= self.vehicle.ad and ADTrafficYieldModule.isAdVehicleUsable(other)
            and ADTrafficYieldModule.ON_ROUTE_STATES[other.ad.trafficYieldModule.state] -- a parked vehicle is not in the way
            and not AutoDrive:checkIsConnected(self.vehicle, other) then
            local wayPoints, currentIndex = other.ad.drivePathModule:getWayPoints()
            if wayPoints ~= nil and currentIndex ~= nil and wayPoints[currentIndex] ~= nil and wayPoints[currentIndex + 1] ~= nil then
                local here, nextId = wayPoints[currentIndex].id, wayPoints[currentIndex + 1].id
                local dHere, dNext = myDist[here], myDist[nextId]
                if dHere ~= nil and dNext ~= nil and dNext > dHere and dHere < beforeDistance then
                    return true
                end
            end
        end
    end
    return false
end

-- another AD vehicle follows me closely on my route, in my direction (it would be in the way if I reversed).
-- 28/10 (the MF 7S 3 m behind the trailer of the 7R 350 was not seen: the 20 m were counted from the MF to a
-- point ahead of the 7R, shorter than the 7R and its trailer): maxDistance is the gap between the rear of my train
-- (trailer included) and the front of the follower; any vehicle of the queue that close counts
function ADTrafficYieldModule.hasFollowerBehind(vehicle, maxDistance, excluded)
    return ADTrafficYieldModule.findFollowerBehind(vehicle, maxDistance, excluded) ~= nil
end

-- the closest such follower (nil when none); excluded: a vehicle left out (the partner, or the parked one)
function ADTrafficYieldModule.findFollowerBehind(vehicle, maxDistance, excluded)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.drivePathModule == nil then
        return nil
    end
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil or wayPoints[currentIndex] == nil or wayPoints[currentIndex + 1] == nil then
        return nil
    end
    local myId, myNextId = wayPoints[currentIndex].id, wayPoints[currentIndex + 1].id
    if myId == nil or myNextId == nil then
        return nil
    end
    local best, bestGap = nil, math.huge
    local x, _, z = ADTrafficYieldModule.getPosition(vehicle)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(vehicle)
    local _, myRear = ADTrafficYieldModule.getTrainExtents(vehicle)
    local rearX, rearZ = x - dirX * myRear, z - dirZ * myRear
    for _, other in pairs(AutoDrive.getAllVehicles()) do
        if other ~= vehicle and other ~= excluded and other.ad ~= vehicle.ad and ADTrafficYieldModule.isAdVehicleUsable(other)
            and not AutoDrive:checkIsConnected(vehicle, other) then
            local ox, _, oz = ADTrafficYieldModule.getPosition(other)
            local odirX, odirZ = ADTrafficYieldModule.getDirection(other)
            local otherFront = ADTrafficYieldModule.getTrainExtents(other)
            local gap = MathUtil.vector2Length(ox + odirX * otherFront - rearX, oz + odirZ * otherFront - rearZ)
            if gap <= maxDistance and gap < bestGap then
                -- it drives my way: my next points are on its route ahead, past my whole train
                local _, otherDist = ADTrafficYieldModule.collectRouteAhead(other, maxDistance + myRear + otherFront + 40)
                if otherDist[myId] ~= nil and otherDist[myNextId] ~= nil and otherDist[myNextId] > otherDist[myId] then
                    best, bestGap = other, gap
                end
            end
        end
    end
    return best
end

-- 28/10 (S7): the whole oncoming queue behind 'leader'
-- (AD vehicles following it on its route, 40 m gaps at most, 4 at most), leader not included
function ADTrafficYieldModule.getQueueBehind(leader, excluded)
    local queue = {}
    local current = leader
    for _ = 1, 4 do
        local follower = ADTrafficYieldModule.findFollowerBehind(current, ADTrafficYieldModule.QUEUE_GAP, excluded)
        if follower == nil or follower == leader then
            break
        end
        for _, v in ipairs(queue) do
            if v == follower then
                return queue
            end
        end
        table.insert(queue, follower)
        current = follower
    end
    return queue
end

-- ------------------------------------------------------------------------------------------------------------
-- Portion face à face
-- ------------------------------------------------------------------------------------------------------------
-- head-on section between my route and the route of another vehicle: the consecutive segments I drive a -> b
-- that it drives b -> a (a two-way road, the other one really drives that same segment backwards).
-- Returns the distance along my route to the start of the section and along its route to the same point,
-- nil when there is no such section or when one of them leaves it before the other one enters it
-- (the first one simply goes first, nobody has to give way)
function ADTrafficYieldModule.findHeadOnSection(vehicle, myList, myDist, other, otherList, otherDist)
    local otherNext = {}
    for k = 1, #otherList - 1 do
        otherNext[otherList[k]] = otherList[k + 1]
    end
    for i = 1, #myList - 1 do
        local a, b = myList[i], myList[i + 1]
        if otherNext[b] == a then
            -- extend the section as long as the other one drives my next segments backwards
            local j = i + 1
            while j < #myList and otherNext[myList[j + 1]] == myList[j] do
                j = j + 1
            end
            local last = myList[j]
            local myFront, myRear = ADTrafficYieldModule.getTrainExtents(vehicle)
            local otherFront, otherRear = ADTrafficYieldModule.getTrainExtents(other)
            local margin = ADTrafficYieldModule.ANTICIPATION_GAP
            -- travel times at the current speeds (at least 2 m/s, a vehicle held for the other one restarts)
            local mySpeed = math.max(ADTrafficYieldModule.getSpeedKmh(vehicle) / 3.6, 2)
            local otherSpeed = math.max(ADTrafficYieldModule.getSpeedKmh(other) / 3.6, 2)
            -- the other one is out of the section (its rear past a) before my front reaches a
            if (otherDist[a] + otherRear + margin) / otherSpeed < (myDist[a] - myFront) / mySpeed then
                return nil, nil
            end
            -- I am out of the section (my rear past 'last') before its front reaches 'last'
            if (myDist[last] + myRear + margin) / mySpeed < (otherDist[last] - otherFront) / otherSpeed then
                return nil, nil
            end
            local section = {}
            for k = i, j do
                table.insert(section, myList[k])
            end
            return myDist[a], otherDist[a], section
        end
    end
    return nil, nil
end

-- returns the oncoming AD vehicle that will use a segment of my route in the opposite direction,
-- and the distance between both vehicles along the route
function ADTrafficYieldModule:findOncomingConflict(excluded)
    if not self.vehicle.ad.drivePathModule:isOnRoadNetwork() then
        return nil, nil
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local myList, myDist = ADTrafficYieldModule.collectRouteAhead(self.vehicle, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    if #myList < 2 then
        return nil, nil
    end

    local bestOther, bestGap = nil, math.huge
    for _, other in pairs(AutoDrive.getAllVehicles()) do
        if other ~= self.vehicle and other ~= excluded and other.ad ~= self.vehicle.ad and ADTrafficYieldModule.isAdVehicleUsable(other)
            and other.ad.drivePathModule:isOnRoadNetwork() and not AutoDrive:checkIsConnected(self.vehicle, other) then
            local ox, _, oz = ADTrafficYieldModule.getPosition(other)
            if MathUtil.vector2Length(ox - x, oz - z) < 2 * ADTrafficYieldModule.ANTICIPATION_DISTANCE then
                local otherList, otherDist = ADTrafficYieldModule.collectRouteAhead(other, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
                local mine, da = ADTrafficYieldModule.findHeadOnSection(self.vehicle, myList, myDist, other, otherList, otherDist)
                if mine ~= nil then
                    local gap = mine + da
                    -- only the heads of the convoys: nobody of mine in front of me, nobody of its own in front of it
                    if gap < bestGap and not self:hasLeaderAhead(myDist, mine, other)
                        and not other.ad.trafficYieldModule:hasLeaderAhead(otherDist, da, self.vehicle) then
                        bestGap = gap
                        bestOther = other
                    end
                end
            end
        end
    end
    if bestOther == nil then
        return nil, nil
    end
    return bestOther, bestGap
end

-- ------------------------------------------------------------------------------------------------------------
-- Ralentir et s'arrêter avant le véhicule en face
-- ------------------------------------------------------------------------------------------------------------
-- 26/10 (7R 350 caught between both procedures, crossing and face to face, rebooting from one to the other): the
-- crossing has priority: a vehicle committed on a red section (or backing out of it) either waits or goes, no face to face
-- plan starts for it or with it until it is through
function ADTrafficYieldModule.intersectionHasPriority(vehicle)
    local c = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.intersection or nil
    return c ~= nil and (c.committed ~= nil or c.retreat ~= nil)
end

-- slows the vehicle down so that both oncoming vehicles stop at a safe distance, then starts the
-- passing manoeuvre. Returns true while the vehicle is held at the stop point.
function ADTrafficYieldModule:updateAnticipation(dt)
    self.anticipationHoldFor = nil
    if g_time >= (self.nextAnticipationCheck or 0) then
        -- every vehicle checks in the same frame, so each route ahead is computed once and shared (routeCache)
        self.nextAnticipationCheck = (math.floor(g_time / ADTrafficYieldModule.ANTICIPATION_INTERVAL) + 1) * ADTrafficYieldModule.ANTICIPATION_INTERVAL
        self.conflictPartner, self.conflictGap = self:findOncomingConflict()
        if self.conflictPartner ~= nil then
            local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
            local otherFront = ADTrafficYieldModule.getTrainExtents(self.conflictPartner)
            self.conflictStopGap = myFront + otherFront + ADTrafficYieldModule.ANTICIPATION_GAP
            self.conflictGapTime = g_time
        end
    end

    local partner = self.conflictPartner
    if partner == nil or not ADTrafficYieldModule.isAdVehicleUsable(partner) then
        self.anticipationTimer = nil
        return false
    end

    -- the crossing first (26/10): no plan while one of us is engaged on a red section
    if ADTrafficYieldModule.intersectionHasPriority(self.vehicle) or ADTrafficYieldModule.intersectionHasPriority(partner) then
        self.anticipationTimer = nil
        return false
    end
    -- first choice: one of them pulls over in advance on its own route (early yield)
    local partnerModuleEarly = partner.ad.trafficYieldModule
    if not self:isBusy() and not partnerModuleEarly:isBusy() then
        -- 28/10: a detour only for the one on the road waiting for the one coming out of the two-way track,
        -- when it loses less time than waiting (startEarlyPlan); not for a crossing planned inside the track
        local history = ADTrafficYieldModule.pairHistory[ADTrafficYieldModule.getPairKey(self.vehicle, partner)]
        local earlyRecentlyFailed = history ~= nil and history.earlyTried ~= nil and g_time - history.earlyTried < 60000
        if not earlyRecentlyFailed then
            ADTrafficYieldModule.startEarlyPlan(self.vehicle, partner)
            self.conflictPartner = nil
            return false
        end
    end

    -- distance driven by both since the last route comparison (both approach each other)
    local elapsed = (g_time - (self.conflictGapTime or g_time)) / 1000
    local closing = (ADTrafficYieldModule.getSpeedKmh(self.vehicle) + ADTrafficYieldModule.getSpeedKmh(partner)) / 3.6 * elapsed
    local gap = self.conflictGap - closing

    -- each vehicle brakes for its half of the remaining free distance
    local stopDistance = (gap - self.conflictStopGap) / 2
    if stopDistance > 0.5 then
        local allowedSpeed = math.sqrt(2 * ADTrafficYieldModule.ANTICIPATION_DECEL * stopDistance) * 3.6
        local drivePathModule = self.vehicle.ad.drivePathModule
        if drivePathModule.speedLimit ~= nil then
            drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, math.max(allowedSpeed, 3))
        end
        self.anticipationTimer = nil
        return false
    end

    -- at the stop point: hold, and start the manoeuvre once both are stopped
    self:holdVehicle(dt)
    self.anticipationHoldFor = partner
    local partnerModule = partner.ad.trafficYieldModule
    local bothStopped = ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1 and ADTrafficYieldModule.getSpeedKmh(partner) < 1
    if bothStopped and not self:isBusy() and not partnerModule:isBusy() then
        self.anticipationTimer = (self.anticipationTimer or 0) + dt
        if self.anticipationTimer >= ADTrafficYieldModule.ANTICIPATION_START_DELAY then
            self.anticipationTimer = nil
            self.conflictPartner = nil
            ADTrafficYieldModule.startPlan(self.vehicle, partner)
        end
    else
        self.anticipationTimer = nil
    end
    return true
end

-- a vehicle that drives during a plan (passing or approaching its partner) must still slow down and stop
-- for a third oncoming vehicle; returns true while held
function ADTrafficYieldModule:holdForOtherOncoming(dt)
    -- only once passing: during the approach both already brake for each other, and the partner must be
    -- allowed to finish pulling over before a third vehicle is dealt with (else it is left half parked)
    local drivingStates = {
        [ADTrafficYieldModule.STATE_REVERSER_PASS] = true,
        [ADTrafficYieldModule.STATE_PARKER_PASS] = true
    }
    if not drivingStates[self.state] then
        self.otherConflict = nil
        return false
    end
    if g_time >= (self.nextOtherCheck or 0) then
        self.nextOtherCheck = g_time + ADTrafficYieldModule.ANTICIPATION_INTERVAL
        self.otherConflict, self.otherGap = self:findOncomingConflict(self.partner)
        self.otherGapTime = g_time
        if self.otherConflict ~= nil then
            local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
            local otherFront = ADTrafficYieldModule.getTrainExtents(self.otherConflict)
            self.otherStopGap = myFront + otherFront + ADTrafficYieldModule.ANTICIPATION_GAP
        end
    end
    local other = self.otherConflict
    if other == nil or not ADTrafficYieldModule.isAdVehicleUsable(other) then
        self.otherHoldTimer = 0
        return false
    end
    local elapsed = (g_time - (self.otherGapTime or g_time)) / 1000
    local closing = (ADTrafficYieldModule.getSpeedKmh(self.vehicle) + ADTrafficYieldModule.getSpeedKmh(other)) / 3.6 * elapsed
    local stopDistance = (self.otherGap - closing - self.otherStopGap) / 2
    if stopDistance > 0.5 then
        local allowedSpeed = math.sqrt(2 * ADTrafficYieldModule.ANTICIPATION_DECEL * stopDistance) * 3.6
        local drivePathModule = self.vehicle.ad.drivePathModule
        if drivePathModule.speedLimit ~= nil then
            drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, math.max(allowedSpeed, 3))
        end
        self.otherHoldTimer = 0
        return false
    end
    self:holdVehicle(dt)

    -- held for a third vehicle while still inside a plan: hand over, so a new plan can start with it
    self.otherHoldTimer = (self.otherHoldTimer or 0) + dt
    local otherModule = other.ad.trafficYieldModule
    if self.otherHoldTimer >= ADTrafficYieldModule.ANTICIPATION_START_DELAY and otherModule.state == ADTrafficYieldModule.STATE_IDLE
        and ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1 then
        self.otherHoldTimer = 0
        self:handOverTo(other)
    end
    return true
end
