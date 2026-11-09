-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleReverser.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : le véhicule qui recule (REVERSER) dans le plan
-- classique.
--
-- Règle :
-- - il recule le long de son propre trajet (getMaxReverse m), en ligne droite seulement au début du trajet ;
-- - une voie d'attente (impasse de moins de WAITING_LANE_MAX_LENGTH m) derrière lui : il y entre, l'autre ne cherche
--   pas de place ; sinon une branche latérale au carrefour si l'autre n'a pas encore de place ;
-- - il trouve une place à côté de lui le premier : les rôles s'inversent, il se gare et l'autre passe ;
-- - il n'arrive pas à reculer (REVERSE_STUCK_MS, S3) : rôles inversés ; au bout du recul sans place pour l'autre : il
--   continue à reculer jusqu'à être hors de son chemin (26/10, startClearAsReverser) ;
-- - passé : l'autre est derrière lui de plus que les deux attelages et plus devant sur son trajet (30/10).
--
-- Branché par : TrafficYieldModule:handle (états REVERSER_*), updateSectionBackOff et updateSectionClear
-- (buildReverseTargets, reverseTowards), updateRejoin (reverseTowards) ; reverseTowards sert aussi à
-- WaitForCallTaskFieldPark, buildReverseTargets à WaitForCallTaskRoadside (avec le module du véhicule).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADTrafficYieldModule.WAITING_LANE_MAX_LENGTH = 80 -- m, a dead end longer than this is a road, not a waiting lane

-- ------------------------------------------------------------------------------------------------------------
-- Recul le long de mon trajet
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:buildReverseTargets(maxDistance)
    local targets = {}
    local x, y, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local maxReverse = maxDistance or ADTrafficYieldModule.getMaxReverse() + 5
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()

    local lastX, lastZ = x, z
    local travelled = 0
    if wayPoints ~= nil and currentIndex ~= nil then
        local index = currentIndex - 1
        while index >= 1 and travelled < maxReverse do
            local wp = wayPoints[index]
            if wp == nil then
                break
            end
            local _, _, localZ = AutoDrive.worldToLocal(self.vehicle, wp.x, wp.y, wp.z)
            if localZ < -1 then
                local d = MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
                local isJunction = self.escapeBranch ~= nil and self.escapeBranch.routeIndex == index
                if d >= ADTrafficYieldModule.REVERSE_STEP or (#targets == 0 and d >= 3) or (isJunction and d >= 1) then
                    travelled = travelled + d
                    table.insert(targets, {x = wp.x, y = wp.y, z = wp.z, routeIndex = index, isJunction = isJunction})
                    lastX, lastZ = wp.x, wp.z
                end
            end
            index = index - 1
        end
    end

    -- no route behind (start of the route): reverse straight
    if travelled < maxReverse then
        local dirX, dirZ
        if #targets >= 2 then
            local a, b = targets[#targets - 1], targets[#targets]
            local l = math.max(0.01, MathUtil.vector2Length(b.x - a.x, b.z - a.z))
            dirX, dirZ = (b.x - a.x) / l, (b.z - a.z) / l
        else
            local fx, fz = ADTrafficYieldModule.getDirection(self.vehicle)
            dirX, dirZ = -fx, -fz
        end
        while travelled < maxReverse do
            lastX = lastX + dirX * ADTrafficYieldModule.REVERSE_STEP
            lastZ = lastZ + dirZ * ADTrafficYieldModule.REVERSE_STEP
            travelled = travelled + ADTrafficYieldModule.REVERSE_STEP
            local ty = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, lastX, y, lastZ)
            table.insert(targets, {x = lastX, y = ty, z = lastZ, straight = true})
        end
    end

    return targets
end

-- reverse towards a world point; own reached check (distance only) so sharp turns into a branch are possible
function ADTrafficYieldModule:reverseTowards(dt, target, reachedDistance)
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm:releaseVehicle()
    self:ensureMotorStarted()
    sdm.reverseNode = sdm:getReverseNode()
    if sdm.reverseNode == nil then
        return true
    end
    sdm.reverseTarget = target
    sdm.currentWayPointIndex = 0
    sdm.wayPoints = {}
    sdm:getBasicStates()
    local distance = MathUtil.vector2Length(target.x - sdm.rNx, target.z - sdm.rNz)
    if distance < (reachedDistance or 2.5) then
        return true
    end
    -- target already in front of the reverse node: consider it reached
    local _, _, localZ = worldToLocal(sdm.reverseNode, target.x, target.y, target.z)
    if localZ > 1 and distance < 6 then
        return true
    end
    if self.vehicle.ad.collisionDetectionModule:checkReverseCollision() then
        sdm:stopAndHoldVehicle(dt)
    else
        sdm:reverseToPoint(dt, ADTrafficYieldModule.REVERSE_SPEED)
    end
    return false
end

-- S3: asked to reverse, I have not moved REVERSE_STUCK_M in REVERSE_STUCK_MS (trailer jackknifed against a wall, soft
-- ground, object the rear sensor does not see). Call it every frame while reversing
function ADTrafficYieldModule:isReverseStuck()
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local p = self.reverseProgress
    if p == nil or g_time - p.lastSeen > 1000 then
        self.reverseProgress = {x = x, z = z, time = g_time, lastSeen = g_time}
        return false
    end
    p.lastSeen = g_time
    if MathUtil.vector2Length(x - p.x, z - p.z) >= ADTrafficYieldModule.REVERSE_STUCK_M then
        p.x, p.z, p.time = x, z, g_time
        return false
    end
    if g_time - p.time >= ADTrafficYieldModule.REVERSE_STUCK_MS then
        if not p.logged then
            p.logged = true
            self:log("I do not move backwards (less than %d m in %d s): stuck", ADTrafficYieldModule.REVERSE_STUCK_M, ADTrafficYieldModule.REVERSE_STUCK_MS / 1000)
            print(string.format("[AD-Croise] %s: je n'arrive pas a reculer (moins de %d m en %d s), je m'arrete la", ADTrafficYieldModule.getName(self.vehicle),
                ADTrafficYieldModule.REVERSE_STUCK_M, ADTrafficYieldModule.REVERSE_STUCK_MS / 1000))
        end
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Voie d'attente ou branche latérale derrière moi
-- ------------------------------------------------------------------------------------------------------------
-- searches, behind the reverser on its own route, a junction with a side branch that is not used by
-- the parker: the reverser can back into it and let the parker pass
function ADTrafficYieldModule:findEscapeBranch()
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil or ADGraphManager == nil then
        return nil
    end
    local maxReverse = ADTrafficYieldModule.getMaxReverse()
    local myLength = ADTrafficYieldModule.getTotalLength(self.vehicle)
    local neededDepth = myLength + 4

    -- nodes that must stay free: route of the parker ahead, and my own route around me
    local forbidden = ADTrafficYieldModule.getUpcomingIds(self.partner, -5, 150)
    for id, _ in pairs(ADTrafficYieldModule.getUpcomingIds(self.vehicle, -80, 160)) do
        forbidden[id] = true
    end

    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local lastX, lastZ = x, z
    local travelled = 0
    local index = currentIndex - 1
    -- a waiting lane (dead end of the AutoDrive network) anywhere within reach is preferred to the
    -- first ordinary side branch
    local firstBranch = nil
    while index >= 2 and travelled < maxReverse do
        local wp = wayPoints[index]
        if wp == nil then
            break
        end
        travelled = travelled + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if wp.id ~= nil then
            local node = ADGraphManager:getWayPointById(wp.id)
            if node ~= nil then
                local neighbours = {}
                for _, id in pairs(node.out or {}) do neighbours[id] = true end
                for _, id in pairs(node.incoming or {}) do neighbours[id] = true end
                for neighbourId, _ in pairs(neighbours) do
                    if not forbidden[neighbourId] then
                        local branch = self:walkBranch(node, neighbourId, forbidden, neededDepth)
                        if branch ~= nil then
                            branch.routeIndex = index
                            branch.junctionId = wp.id
                            branch.isWaitingLane = ADTrafficYieldModule.isDeadEnd(node, neighbourId, forbidden)
                            if branch.isWaitingLane then
                                return branch
                            end
                            firstBranch = firstBranch or branch
                        end
                    end
                end
            end
        end
        index = index - 1
    end
    return firstBranch
end

-- waiting lane: the side branch starting at junction -> firstId ends in a dead end (no other way out)
-- within WAITING_LANE_MAX_LENGTH metres
function ADTrafficYieldModule.isDeadEnd(junction, firstId, forbidden)
    local visited = {[junction.id] = true}
    local current = ADGraphManager:getWayPointById(firstId)
    local length = 0
    local previous = junction
    while current ~= nil do
        if visited[current.id] or forbidden[current.id] then
            return false -- loop back or back to the route: it is a way through
        end
        visited[current.id] = true
        length = length + MathUtil.vector2Length(current.x - previous.x, current.z - previous.z)
        if length > ADTrafficYieldModule.WAITING_LANE_MAX_LENGTH then
            return false
        end
        local nextIds = {}
        for _, id in pairs(current.out or {}) do
            if not visited[id] then nextIds[id] = true end
        end
        for _, id in pairs(current.incoming or {}) do
            if not visited[id] then nextIds[id] = true end
        end
        local nextId, count = nil, 0
        for id, _ in pairs(nextIds) do
            nextId, count = id, count + 1
        end
        if count == 0 then
            return true
        end
        if count > 1 then
            return false -- the branch forks: a small network, not a simple waiting lane
        end
        previous = current
        current = ADGraphManager:getWayPointById(nextId)
    end
    return false
end

function ADTrafficYieldModule:walkBranch(junction, firstId, forbidden, neededDepth)
    local nodes = {}
    local visited = {[junction.id] = true}
    local current = ADGraphManager:getWayPointById(firstId)
    local previous = junction
    local depth = 0
    while current ~= nil and #nodes < 12 do
        if forbidden[current.id] or visited[current.id] then
            return nil
        end
        visited[current.id] = true
        depth = MathUtil.vector2Length(current.x - junction.x, current.z - junction.z)
        table.insert(nodes, {x = current.x, y = current.y, z = current.z, id = current.id})
        if depth >= neededDepth then
            return {nodes = nodes, depth = depth}
        end
        -- continue with the straightest following node
        local dirX, dirZ = current.x - previous.x, current.z - previous.z
        local best, bestDot = nil, -2
        local candidates = {}
        for _, id in pairs(current.out or {}) do candidates[id] = true end
        for _, id in pairs(current.incoming or {}) do candidates[id] = true end
        for id, _ in pairs(candidates) do
            if not visited[id] then
                local n = ADGraphManager:getWayPointById(id)
                if n ~= nil then
                    local vx, vz = n.x - current.x, n.z - current.z
                    local l1 = math.max(0.01, MathUtil.vector2Length(dirX, dirZ))
                    local l2 = math.max(0.01, MathUtil.vector2Length(vx, vz))
                    local dot = (dirX * vx + dirZ * vz) / (l1 * l2)
                    if dot > bestDot then
                        best, bestDot = n, dot
                    end
                end
            end
        end
        previous = current
        current = best
    end
    -- dead end: accept it if deep enough to hide most of the vehicle
    if depth >= neededDepth * 0.8 then
        return {nodes = nodes, depth = depth}
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- États REVERSER
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:updateReverserRetreat(dt)
    local plan = self.plan
    if self.reverseTargets == nil then
        self.escapeBranch = self:findEscapeBranch()
        if self.escapeBranch ~= nil and self.escapeBranch.isWaitingLane then
            -- a waiting lane behind me: I back into it, the other one does not look for a roadside spot
            plan.mode = "branch"
            self:log("waiting lane (dead end) behind me, I back into it")
        end
        self.reverseTargets = self:buildReverseTargets()
        self.reverseTargetIndex = 1
        local x, y, z = ADTrafficYieldModule.getPosition(self.vehicle)
        self.reverseStart = {x = x, y = y, z = z}
    end

    local room = plan.moreRoom
    local extra = room ~= nil and room.pending and room.started
    if plan.reverserMayStop and not extra then
        self:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
        self:holdVehicle(dt)
        return
    end

    -- the reverser may have a free roadside spot next to it: if so it parks itself and the other one passes
    if self:tryOwnParkingSpot(dt) then
        return
    end

    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local reversed = MathUtil.vector2Length(x - self.reverseStart.x, z - self.reverseStart.z)
    local maxReverse = ADTrafficYieldModule.getMaxReverse()

    local blockedBehind = self.vehicle.ad.collisionDetectionModule:checkReverseCollision()
    local blockedTooLong = self.reverseBlockedTimer:timer(blockedBehind, 8000, dt)
    -- S3: not moving backwards although asked to (trailer swung against a wall: 942 Vario 27/10 20:20, 3 min)
    if self:isReverseStuck() then
        plan.reverserStuck = true
        blockedTooLong = true
    end

    local target = self.reverseTargets[self.reverseTargetIndex]
    if extra then
        local more = MathUtil.vector2Length(x - room.x, z - room.z)
        if more >= ADTrafficYieldModule.MORE_ROOM or target == nil or blockedTooLong or reversed >= maxReverse + 5 then
            room.pending = false
            room.failed = more < ADTrafficYieldModule.MORE_ROOM_MIN
            self:log("backed off %.0f m more%s", more, room.failed and " (no room behind me)" or "")
            self:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
            self:holdVehicle(dt)
            return
        end
    end
    if reversed >= maxReverse + 5 or target == nil or blockedTooLong then
        plan.reverserAtLimit = true
        self:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
        self:holdVehicle(dt)
        return
    end

    if self:reverseTowards(dt, target) then
        if target.routeIndex ~= nil then
            self.reachedRouteIndex = target.routeIndex
        end
        self.reverseTargetIndex = self.reverseTargetIndex + 1
        -- at the junction and still no roadside spot for the parker: hide in the side branch
        if target.isJunction and self.escapeBranch ~= nil and (plan.parkSpot == nil or self.escapeBranch.isWaitingLane) then
            plan.mode = "branch"
            self.branchTargetIndex = 1
            self:setState(ADTrafficYieldModule.STATE_REVERSER_BRANCH)
        end
    end
end

function ADTrafficYieldModule:updateReverserBranch(dt)
    local plan = self.plan
    local blockedBehind = self.vehicle.ad.collisionDetectionModule:checkReverseCollision()
    local blockedTooLong = self.reverseBlockedTimer:timer(blockedBehind, 8000, dt)
    if self:isReverseStuck() then
        blockedTooLong = true -- S3
    end
    local timedOut = self.stateTimer:timer(true, 45000, dt)
    local target = self.escapeBranch.nodes[self.branchTargetIndex]

    if target == nil or blockedTooLong or timedOut then
        plan.hidden = true
        self:setState(ADTrafficYieldModule.STATE_REVERSER_HIDE)
        self:holdVehicle(dt)
        return
    end
    if self:reverseTowards(dt, target, 2) then
        self.branchTargetIndex = self.branchTargetIndex + 1
    end
end

function ADTrafficYieldModule:updateReverserHide(dt)
    self:holdVehicle(dt)
    -- the parker ends the plan once it has passed the junction
    if self.stateTimer:timer(true, 120000, dt) then
        self:endPlan("hide timeout", false)
    end
end

function ADTrafficYieldModule:updateReverserWait(dt)
    local plan = self.plan
    self:holdVehicle(dt)
    if plan.moreRoom ~= nil and plan.moreRoom.pending and not plan.moreRoom.started and not plan.parked then
        local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
        plan.moreRoom.started = true
        plan.moreRoom.x, plan.moreRoom.z = x, z
        self:log("backing off %d m more for %s", ADTrafficYieldModule.MORE_ROOM, ADTrafficYieldModule.getName(self.partner))
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:setState(ADTrafficYieldModule.STATE_REVERSER_RETREAT)
        return
    end
    if plan.parked then
        self:setState(ADTrafficYieldModule.STATE_REVERSER_PASS)
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        ADTrafficYieldModule.resyncWayPoints(self.vehicle, self.reachedRouteIndex)
        return
    end
    -- reverser stopped before the parker had a spot (limit reached): give both a last chance, then give up
    if plan.reverserAtLimit and plan.parkSpot == nil then
        if self:tryOwnParkingSpot(dt) then
            return
        end
        if plan.reverserStuck and self.stateTimer:timer(true, 6000, dt) then
            -- S3: I cannot reverse at all: the other one reverses instead
            self:restartWithRolesSwapped("reverser stuck, no roadside spot", "je n'arrive pas a reculer et pas de place pour " .. ADTrafficYieldModule.getName(self.partner))
            return
        end
        if not plan.reverserStuck and self.stateTimer:timer(true, 6000, dt) then
            -- 26/10 (Jaguar / 942 Vario nose to nose on a single track, no roadside spot on 50 m either way, both
            -- plans given up, both stayed there): rather than giving up, I keep reversing along my route until I am off the
            -- way of the other one (junction, end of the single track, up to SECTION_CLEAR_MAX), it follows and passes
            if self:startClearAsReverser() then
                return
            end
            self:endPlan("no free roadside spot found", false)
        end
    end
end

-- the reverser of the standard plan reached its limit and the parker found no spot: the plan goes on as a
-- "single track clear" (the reverser backs until it is off the way of the other one, which then drives on)
function ADTrafficYieldModule:startClearAsReverser()
    local plan = self.plan
    local other = self.partner
    if other == nil or plan == nil or plan.sectionCleared or plan.mode == "branch" then
        return false
    end
    if ADTrafficYieldModule.hasFollowerBehind(self.vehicle, 20, other) then
        return false
    end
    plan.sectionCleared = true
    plan.mode = "sectionClear"
    plan.reverser, plan.parker = other, self.vehicle -- it drives on (REVERSER_PASS), I get off its way
    plan.parked = false
    plan.waitBeforeSection = nil
    plan.reverserMayStop = true
    plan.reverserAtLimit = false
    self:log("no roadside spot on either side: I keep reversing until I am off the way of %s (%d m at most)", ADTrafficYieldModule.getName(other), ADTrafficYieldModule.SECTION_CLEAR_MAX)
    print(string.format("[AD-Croise] %s: pas de place pour se garer de part et d'autre, je continue a reculer jusqu'a etre hors du chemin de %s (%d m au plus)",
        ADTrafficYieldModule.getName(self.vehicle), ADTrafficYieldModule.getName(other), ADTrafficYieldModule.SECTION_CLEAR_MAX))
    local otherModule = other.ad.trafficYieldModule
    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    other.ad.specialDrivingModule:releaseVehicle()
    self.reverseTargets = nil
    otherModule:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
    otherModule:holdVehicle(0)
    self:setState(ADTrafficYieldModule.STATE_SECTION_CLEAR)
    return true
end

-- the reverser searches a roadside spot from its own position (towards the other vehicle). When it
-- finds one first, the roles are swapped: the reverser parks there and the other vehicle drives on.
function ADTrafficYieldModule:tryOwnParkingSpot(dt)
    local plan = self.plan
    if plan.parkSpot ~= nil or plan.mode == "branch" then
        return false
    end
    if g_time - self.lastSearchTime < ADTrafficYieldModule.SEARCH_INTERVAL then
        return false
    end
    self.lastSearchTime = g_time

    local spot = self:searchParkingSpot()
    if spot == nil then
        return false
    end

    -- swap the roles in the running plan
    self:log("own spot found (side=%s) -> roles swapped, I park", tostring(spot.side))
    local other = self.partner
    local otherModule = other.ad.trafficYieldModule
    plan.reverser, plan.parker = other, self.vehicle
    plan.parkSpot = spot
    plan.reverserMayStop = true
    plan.reverserAtLimit = false

    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    self:setState(ADTrafficYieldModule.STATE_PARKER_MOVE)
    otherModule:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
    return true
end

function ADTrafficYieldModule:updateReverserPass(dt)
    -- normal driving (module does not control the vehicle), only watch when we have passed the parker
    local plan = self.plan
    local parker = self.partner
    local px, py, pz = ADTrafficYieldModule.getPosition(parker)
    local _, _, parkerLocalZ = AutoDrive.worldToLocal(self.vehicle, px, py, pz)
    local parkerLength = ADTrafficYieldModule.getTotalLength(parker)
    local myLength = ADTrafficYieldModule.getTotalLength(self.vehicle)

    -- the parker centre is behind us by more than the length of both trains, and no longer ahead on my route
    if parkerLocalZ < -(parkerLength + myLength / 2 + 2) and not ADTrafficYieldModule.isAheadOnMyRoute(self.vehicle, parker) then
        plan.passed = true
        self:endPlan("passed", true)
        return
    end
    if self.stateTimer:timer(true, 90000, dt) then
        self:endPlan("pass timeout", false)
    end
end
