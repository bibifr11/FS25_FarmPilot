-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleDetour.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : éviter le face à face par un autre chemin.
--
-- Règle :
-- - détour : calcul de route AutoDrive avec la portion face à face rendue très chère (DETOUR_PENALTY) ; pris s'il est
--   au plus DETOUR_MAX m plus long, et s'il fait perdre moins de temps qu'attendre (28/10) ; une fois par partenaire ;
-- - tout droit à l'embranchement (26/10) : celui qui cède, à l'embranchement du chemin unique sans pouvoir attendre
--   avant, continue sur l'autre branche, AutoDrive le ramène ensuite à sa destination ; aussi quand l'embranchement
--   est déjà sous lui, s'il ne peut pas reculer (28/10) ;
-- - probe : rien n'est changé, rend la longueur en plus et une fonction qui prend ce chemin.
--
-- Branché par : checkForHeadOnDeadlock (TrafficYieldModuleDeadlock.lua), startEarlyPlan, updateYielderApproach,
-- resolveStuckInMouth.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Autre chemin vers ma destination
-- ------------------------------------------------------------------------------------------------------------
-- looks for another way to my destination that avoids the head-on section with 'partner'; when one exists and
-- is at most DETOUR_MAX longer, my route is changed to it and the passing is not needed. Tried once per partner
-- maxExtra (28/10): the detour must also lose less time than waiting, at most maxExtra m longer.
-- probe: nothing is changed, returns true, the extra length and a function that takes the detour
function ADTrafficYieldModule:tryDetour(partner, maxExtra, probe)
    if not probe then
        if self.detourPartner == partner and g_time < (self.detourRetryTime or 0) then
            return false
        end
        self.detourPartner = partner
        self.detourRetryTime = g_time + 20000
    end
    local drivePathModule = self.vehicle.ad.drivePathModule
    local wayPoints, currentIndex = drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil or wayPoints[currentIndex] == nil or wayPoints[currentIndex + 1] == nil then
        return false
    end
    local startWp, nextWp, lastWp = wayPoints[currentIndex], wayPoints[currentIndex + 1], wayPoints[#wayPoints]
    if startWp.id == nil or nextWp.id == nil or lastWp.id == nil or ADPathCalculator == nil then
        return false
    end
    local myList, myDist = ADTrafficYieldModule.collectRouteAhead(self.vehicle, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    local otherList, otherDist = ADTrafficYieldModule.collectRouteAhead(partner, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    local mine, _, section = ADTrafficYieldModule.findHeadOnSection(self.vehicle, myList, myDist, partner, otherList, otherDist)
    if mine == nil then
        return false
    end
    if mine < ADTrafficYieldModule.DETOUR_MIN_AHEAD then
        self:log("no other way to avoid %s: the shared section starts %.0f m ahead", ADTrafficYieldModule.getName(partner), mine)
        return false
    end
    local avoid = {}
    for _, id in ipairs(section) do
        avoid[id] = true
    end
    if avoid[startWp.id] then
        self:log("no other way to avoid %s: I am already on the shared section", ADTrafficYieldModule.getName(partner))
        return false
    end

    -- AutoDrive route calculation with the head-on section made very expensive
    local originalWeights = ADPathCalculator.getDetourWeights
    ADPathCalculator.getDetourWeights = function(calculator)
        local weights = originalWeights(calculator)
        for id in pairs(avoid) do
            weights[id] = (weights[id] or 0) + ADTrafficYieldModule.DETOUR_PENALTY
        end
        return weights
    end
    local ok, path = FarmPilotCall(ADGraphManager.pathFromTo, ADGraphManager, startWp.id, lastWp.id, {nextWp.id})
    ADPathCalculator.getDetourWeights = originalWeights
    if not ok or path == nil or #path < 2 or path[1].id ~= startWp.id or path[#path].id ~= lastWp.id then
        self:log("no other way to avoid %s: no route found", ADTrafficYieldModule.getName(partner))
        return false
    end
    for _, wp in ipairs(path) do
        if avoid[wp.id] then
            self:log("no other way to avoid %s", ADTrafficYieldModule.getName(partner))
            return false
        end
    end
    local detour = ADTrafficYieldModule.getPathLength(path, 1) - ADTrafficYieldModule.getPathLength(wayPoints, currentIndex)
    if detour > ADTrafficYieldModule.DETOUR_MAX then
        self:log("other way to avoid %s is %.0f m longer, too long", ADTrafficYieldModule.getName(partner), detour)
        return false
    end
    if maxExtra ~= nil and detour > maxExtra then
        self:log("other way to avoid %s is %.0f m longer, it would lose more time than waiting (%.0f m)", ADTrafficYieldModule.getName(partner), detour, maxExtra)
        print(string.format("[AD-Croise] %s: detour de %.0f m possible pour eviter %s, mais plus long que l'attente (%.0f m au plus) : j'attends",
            ADTrafficYieldModule.getName(self.vehicle), detour, ADTrafficYieldModule.getName(partner), math.max(maxExtra, 0)))
        return false
    end

    local function apply()
        -- keep the waypoints already driven, then the new way from the current waypoint on
        local newWayPoints = {}
        for k = 1, currentIndex - 1 do
            newWayPoints[k] = wayPoints[k]
        end
        for _, wp in ipairs(path) do
            table.insert(newWayPoints, wp)
        end
        drivePathModule.wayPoints = newWayPoints
        drivePathModule:setCurrentWayPointIndex(currentIndex)
        self:log("detour of %.0f m to avoid meeting %s", math.max(detour, 0), ADTrafficYieldModule.getName(partner))
    end
    if probe then
        return true, math.max(detour, 0), apply
    end
    apply()
    return true, math.max(detour, 0)
end

-- ------------------------------------------------------------------------------------------------------------
-- Tout droit à l'embranchement du chemin unique
-- ------------------------------------------------------------------------------------------------------------
-- the node where my route turns off (a node with two ways out) last before the single track, as a signed
-- distance along my route from my position (negative: already behind me, searched up to 40 m back), nil if none
function ADTrafficYieldModule:findTurnOffBeforeSection()
    local section = self.earlySection
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if section == nil or section[1] == nil or wayPoints == nil or currentIndex == nil or ADGraphManager == nil then
        return nil
    end
    -- 28/10: on a two-way track every point has two outs (on and back): only a way other than my previous and next
    -- point makes a branch (the turn-off was found 4 m before the section, inside the farm track)
    local function isBranch(wp, i)
        if wp == nil or wp.id == nil or wp.id == section[1] then
            return false
        end
        local node = ADGraphManager:getWayPointById(wp.id)
        if node == nil or node.out == nil or #node.out < 2 then
            return false
        end
        local prevId = wayPoints[i - 1] ~= nil and wayPoints[i - 1].id or nil
        local nextId = wayPoints[i + 1] ~= nil and wayPoints[i + 1].id or nil
        for _, id in ipairs(node.out) do
            if id ~= prevId and id ~= nextId then
                return true
            end
        end
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    -- ahead, up to the start of the single track
    local found, foundIndex = nil, nil
    local lastX, lastZ, distance = x, z, 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if wp.id == section[1] then
            break
        end
        if isBranch(wp, i) then
            found, foundIndex = distance, i
        end
        if distance > ADTrafficYieldModule.ANTICIPATION_DISTANCE then
            break
        end
    end
    if found ~= nil then
        return found, foundIndex
    end
    -- behind me (I am already in the turn)
    lastX, lastZ, distance = x, z, 0
    for i = currentIndex - 1, 1, -1 do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if distance > 40 then
            break
        end
        if isBranch(wp, i) then
            return -distance, i
        end
    end
    return nil
end

-- 26/10 (rather than reversing, drive on along the way in front, when possible):
-- the yielder is at the turn-off into the single track and cannot wait before it: it drives straight on along the
-- other branch of the junction, AutoDrive brings it back to its destination afterwards. Returns true when the route
-- was changed. probe: nothing is changed, returns true, the extra length and a function that takes that way
-- allowBehind (28/10, only when I cannot reverse: then I go elsewhere and come back later):
-- also when the junction is already under me
function ADTrafficYieldModule:tryStraightOn(turnOffIndex, probe, allowBehind)
    local drivePathModule = self.vehicle.ad.drivePathModule
    local wayPoints, currentIndex = drivePathModule:getWayPoints()
    if turnOffIndex == nil or wayPoints == nil or currentIndex == nil or ADGraphManager == nil or self.partner == nil then
        return false
    end
    local junction, towardsTrack, before, lastWp = wayPoints[turnOffIndex], wayPoints[turnOffIndex + 1], wayPoints[turnOffIndex - 1], wayPoints[#wayPoints]
    if junction == nil or junction.id == nil or towardsTrack == nil or lastWp == nil or lastWp.id == nil then
        return false
    end
    -- 28/10: also when the junction is already under me (Jaguar at 1672, junction 9 m behind): I take the
    -- way straight on as long as a point of it lies ahead of my front within reach of the steering
    local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local _, _, junctionLocalZ = AutoDrive.worldToLocal(self.vehicle, junction.x, junction.y, junction.z)
    local junctionAhead = junctionLocalZ >= myFront - 1
    if not junctionAhead and not allowBehind then
        return false
    end
    local node = ADGraphManager:getWayPointById(junction.id)
    if node == nil or node.out == nil then
        return false
    end
    local _, otherDist = ADTrafficYieldModule.collectRouteAhead(self.partner, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    if otherDist[junction.id] ~= nil then
        self:log("straight on at the junction: %s drives through that junction", ADTrafficYieldModule.getName(self.partner))
        return false
    end
    -- a step a -> b is refused only when the partner drives it the other way (b before a on its route): following
    -- the partner on the same one-way lane is no head-on (28/10: 7R out of the track by 6993 joins the road at 1675)
    local function against(a, b)
        return otherDist[b] ~= nil and (otherDist[a] == nil or otherDist[b] < otherDist[a])
    end
    -- incoming direction at the junction
    local inX, inZ
    if before ~= nil then
        local l = math.max(0.01, MathUtil.vector2Length(junction.x - before.x, junction.z - before.z))
        inX, inZ = (junction.x - before.x) / l, (junction.z - before.z) / l
    else
        inX, inZ = ADTrafficYieldModule.getDirection(self.vehicle)
    end
    -- the most straight-on branch that is neither the track nor the way I came from nor against the partner
    local best, bestDot = nil, -math.huge
    for _, outId in pairs(node.out) do
        local candidate = ADGraphManager:getWayPointById(outId)
        if candidate ~= nil and outId ~= towardsTrack.id and (before == nil or outId ~= before.id) and not against(junction.id, outId) then
            local l = math.max(0.01, MathUtil.vector2Length(candidate.x - junction.x, candidate.z - junction.z))
            local dot = ((candidate.x - junction.x) * inX + (candidate.z - junction.z) * inZ) / l
            if dot > bestDot then
                best, bestDot = candidate, dot
            end
        end
    end
    if best == nil or bestDot < 0.3 then
        self:log("straight on at the junction: no branch straight on")
        return false
    end
    -- follow that branch (first way out at each step), never against the partner; from 40 m on, the first point
    -- with a way back to my destination ends it (I go elsewhere and come back later), 400 m at most
    local chain = {best}
    local length = MathUtil.vector2Length(best.x - junction.x, best.z - junction.z)
    local current = best
    local path = nil
    local nextTry = 40
    local tries = 0
    while length < 400 and tries < 16 do
        if length >= nextTry then
            tries = tries + 1
            nextTry = length + 25
            local ok, result = FarmPilotCall(ADGraphManager.pathFromTo, ADGraphManager, current.id, lastWp.id, {})
            if ok and result ~= nil and #result >= 2 and result[1].id == current.id and result[#result].id == lastWp.id then
                path = result
                break
            end
        end
        local graphNode = ADGraphManager:getWayPointById(current.id)
        if graphNode == nil or graphNode.out == nil or #graphNode.out < 1 then
            break
        end
        local nextWp = ADGraphManager:getWayPointById(graphNode.out[1])
        if nextWp == nil or against(current.id, nextWp.id) or nextWp.id == junction.id then
            break
        end
        table.insert(chain, nextWp)
        length = length + MathUtil.vector2Length(nextWp.x - current.x, nextWp.z - current.z)
        current = nextWp
    end
    if path == nil and length >= 15 then
        local ok, result = FarmPilotCall(ADGraphManager.pathFromTo, ADGraphManager, current.id, lastWp.id, {})
        if ok and result ~= nil and #result >= 2 and result[1].id == current.id and result[#result].id == lastWp.id then
            path = result
        end
    end
    if path == nil then
        self:log("straight on at the junction: no way back to my destination within %.0f m", length)
        return false
    end
    -- where I start on the new route: unchanged when the junction is still ahead, otherwise the first point of the
    -- straight-on way ahead of my front that I reach turning no tighter than my train can (radius of the arc from me
    -- to the point: distance / (2 sin angle)), 80 deg off my heading at most
    local startIndex = currentIndex
    if not junctionAhead then
        startIndex = nil
        local radius = math.max(8, ADTrafficYieldModule.getTrainRadius(self.vehicle) or 0)
        for k, wp in ipairs(chain) do
            local lx, _, lz = AutoDrive.worldToLocal(self.vehicle, wp.x, wp.y, wp.z)
            local angle = math.abs(math.atan2(lx, lz))
            local d = MathUtil.vector2Length(lx, lz)
            if lz >= myFront + 2 and angle <= math.rad(80) and (angle < 0.01 or d / (2 * math.sin(angle)) >= radius) then
                startIndex = turnOffIndex + k
                break
            end
        end
        if startIndex == nil then
            self:log("straight on at the junction: the junction is behind me and the way straight on is out of reach")
            return false
        end
    end
    local newWayPoints = {}
    for k = 1, turnOffIndex do
        newWayPoints[k] = wayPoints[k]
    end
    for _, wp in ipairs(chain) do
        table.insert(newWayPoints, wp)
    end
    for k = 2, #path do
        table.insert(newWayPoints, path[k])
    end
    local extra = ADTrafficYieldModule.getPathLength(newWayPoints, startIndex) - ADTrafficYieldModule.getPathLength(wayPoints, currentIndex)
    local function apply()
        drivePathModule.wayPoints = newWayPoints
        drivePathModule:setCurrentWayPointIndex(startIndex)
        drivePathModule.minDistanceToNextWp = math.huge
        self:log("at the turn-off into the single track: I drive straight on and come back later (%.0f m more), %s comes out first", math.max(extra, 0), ADTrafficYieldModule.getName(self.partner))
        print(string.format("[AD-Croise] %s: a l'embranchement du chemin unique, je continue tout droit et je reviens apres (%.0f m de plus), %s sort d'abord",
            ADTrafficYieldModule.getName(self.vehicle), math.max(extra, 0), ADTrafficYieldModule.getName(self.partner)))
    end
    if probe then
        return true, math.max(extra, 0), apply
    end
    apply()
    return true, math.max(extra, 0)
end
