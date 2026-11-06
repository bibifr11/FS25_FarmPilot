ExitFieldTask = ADInheritsFrom(AbstractTask)
ExitFieldTask.debug = false

ExitFieldTask.STATE_PATHPLANNING = 1
ExitFieldTask.STATE_DRIVING = 2
ExitFieldTask.STATE_DELAY_PATHPLANNING = 3
ExitFieldTask.STATE_PARKING = 4 -- forage harvester: moving aside to let the next unloader pass
ExitFieldTask.STATE_TRACK_REVERSE = 5 -- forage harvester: backing off along its own track to let the next unloader pass
ExitFieldTask.STATE_PARK_BACK = 6 -- forage harvester: backing off a few meters along its track before driving to its spot
ExitFieldTask.STATE_BAND_TURN = 7 -- forage harvester: U-turn in the strip, the field exit is behind
ExitFieldTask.WAIT_OTHER_TIME = 120000 -- ms, parked aside: waits for the next unloader to be in place at the harvester
-- owner 26/10 14:43 ("il suit le 2e qui passe en 1er jusqu'au bout ou il peut sortir"): full, parked aside and the next
-- unloader in place: follows the harvester's own track (cut ground) at a distance and looks for an exit on the way,
-- instead of waiting at its spot until a passage opens right there
ExitFieldTask.STATE_FOLLOW_STRIP = 8
ExitFieldTask.FOLLOW_BEHIND = 60             -- m of harvester track kept between the train and the harvester
ExitFieldTask.FOLLOW_ATTACH = 20             -- m: the track must pass this close ahead of the tractor to be followed
ExitFieldTask.FOLLOW_OTHER_GAP = 30          -- m kept behind another unloader standing on the track ahead
ExitFieldTask.FOLLOW_STEP = 3                -- m between the waypoints taken from the track
ExitFieldTask.FOLLOW_EXIT_CHECK = 10000      -- ms between two looks for a crop free straight line to a network point
ExitFieldTask.FOLLOW_EXIT_FULL_RETRY = 60000 -- ms between two full route attempts while following

ExitFieldTask.STRATEGY_START = 0
ExitFieldTask.STRATEGY_BEHIND_START = 1
ExitFieldTask.STRATEGY_CLOSEST = 2

function ExitFieldTask:new(vehicle)
    local o = ExitFieldTask:create()
    o.vehicle = vehicle
    o.trailers = nil
    o.failedPathFinder = 0
    o.waitForCheckTimer = AutoDriveTON:new()
    return o
end

function ExitFieldTask:setUp()
    self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
    self.nextExitStrategy = AutoDrive.getSetting("exitField", self.vehicle)
    self.trailers, _ = AutoDrive.getAllUnits(self.vehicle)
    AutoDrive.setTrailerCoverOpen(self.vehicle, self.trailers, false)
end

function ExitFieldTask:update(dt)
    -- owner 25/10: the point it drives out to is published, an empty unloader coming in waits before the entrance
    if self.state == ExitFieldTask.STATE_DRIVING and self.exitPoint ~= nil then
        ADFieldPark.setFieldExit(self.vehicle, self.exitPoint.x, self.exitPoint.z)
    else
        ADFieldPark.setFieldExit(self.vehicle, nil)
    end
    if self.state == ExitFieldTask.STATE_PATHPLANNING then
        if self.vehicle.ad.pathFinderModule:hasFinished() then
            self.wayPoints = self.vehicle.ad.pathFinderModule:getPath()
            if self.wayPoints == nil or #self.wayPoints == 0 then
                -- 27/10 17:18 (field 13): the grid found nothing toward the entrance three times while a 343 m route
                -- along the cut strip existed: that route is taken, as the second unloader does on its way to the first
                if self:tryBandExit() then
                    return
                end
                -- no clean path to this network point: try the next one right away
                if not self:startPathPlanning() then
                    return
                end
            else
                self.vehicle.ad.drivePathModule:setWayPoints(self.wayPoints)
                self.vehicle.ad.exitStuckFull = nil
                -- partial route (guided departure, part of the way): not out of the field at its end
                self.routeIsPartial = self.vehicle.ad.pathFinderModule.partialPath == true
                self.routeStart = g_time
                self.state = ExitFieldTask.STATE_DRIVING
            end
        else
            self.vehicle.ad.pathFinderModule:update(dt)
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
        end
    elseif self.state == ExitFieldTask.STATE_DELAY_PATHPLANNING and self.parkedAside ~= nil
        and g_time - self.parkedAside < ExitFieldTask.WAIT_OTHER_TIME and ExitFieldTask.isOtherApproaching(self.vehicle) then
        -- parked aside: the next unloader is still on its way to the harvester, let it pass first
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return
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
    elseif self.state == ExitFieldTask.STATE_FOLLOW_STRIP then
        self:updateFollowStrip(dt)
        return
    elseif self.state == ExitFieldTask.STATE_BAND_TURN then
        if ADBandTurn.update(self.vehicle, dt) ~= "running" then
            -- turned (or not): the exit points are sorted again from the new heading
            self.candidates = nil
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        end
        return
    elseif self.state == ExitFieldTask.STATE_DRIVING then
        if self.vehicle.ad.drivePathModule:isTargetReached() and self.routeIsPartial then
            -- end of a partial route: still in the field, plan the rest from here
            print(string.format("[AD-Fin] %s: bout du trajet partiel atteint, calcul de la suite", tostring(self.vehicle:getName())))
            self.routeIsPartial = false
            self.candidates = nil
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        elseif self.vehicle.ad.drivePathModule:isTargetReached() then
            self.state = ExitFieldTask.STATE_FINISHED
        elseif self:isExitPointBlocked(dt) then
            -- an unloader waits on the point: the next point instead
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        elseif self.vehicle.ad.routeBlockedTime ~= nil and self.routeStart ~= nil and self.vehicle.ad.routeBlockedTime > self.routeStart then
            -- owner 25/10: the front sensor kept it stopped on this route (wall, post): the place is a forbidden zone now,
            -- the exit is planned again around it instead of waiting there
            print(string.format("[AD-Exit] %s: bloque par un obstacle sur le trajet vers le point %s, nouveau calcul en l'evitant", tostring(self.vehicle:getName()), self.exitPoint ~= nil and tostring(self.exitPoint.id) or "?"))
            self.routeStart = nil
            self.candidates = nil
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        else
            self.vehicle.ad.drivePathModule:update(dt)
        end
    elseif self.state == ExitFieldTask.STATE_PARK_BACK then
        local result = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:updateTrackReverse(dt)
        if result == "done" then
            self.vehicle.ad.drivePathModule:setWayPoints(self.parkPath)
            self.state = ExitFieldTask.STATE_PARKING
        elseif result == "blocked" then
            self.parkedAside = g_time
            self.candidates = nil
            self.retryDelay = ExitFieldTask.RETRY_DELAY
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        end
    elseif self.state == ExitFieldTask.STATE_PARKING then
        if self.vehicle.ad.drivePathModule:isTargetReached() then
            print(string.format("[AD-Exit] %s: rangee sur le cote, la benne suivante peut passer ; sortie quand elle sera en place, essai toutes les %d s", tostring(self.vehicle:getName()), ExitFieldTask.RETRY_DELAY / 1000))
            self.parkedAside = g_time
            self.candidates = nil
            self.retryDelay = ExitFieldTask.RETRY_DELAY
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        else
            self.vehicle.ad.drivePathModule:update(dt)
        end
    elseif self.state == ExitFieldTask.STATE_TRACK_REVERSE then
        local result = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:updateTrackReverse(dt)
        if result ~= "running" then
            -- still on its own track, in the middle of the strip: move onto the grass or to the side of the strip
            local path = self.vehicle.ad.pathFinderModule:findParkAside(self.vehicle.ad.lastHarvester, true)
            if path ~= nil then
                self.vehicle.ad.drivePathModule:setWayPoints(path)
                self.state = ExitFieldTask.STATE_PARKING
                return
            end
            print(string.format("[AD-Exit] %s: nouvel essai de sortie toutes les %d s", tostring(self.vehicle:getName()), ExitFieldTask.RETRY_DELAY / 1000))
            self.parkedAside = g_time
            self.candidates = nil
            self.retryDelay = ExitFieldTask.RETRY_DELAY
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        end
    elseif self.state == ExitFieldTask.STATE_FINISHED then
        self:finished()
    end
end

-- the grid found no route to the current exit point: the route along the cut strip (band flood of that search),
-- then the approach points to the network point as the grid route would have had them
function ExitFieldTask:tryBandExit()
    local pf = self.vehicle.ad.pathFinderModule
    local candidate = self.candidates ~= nil and self.candidates[self.candidateIndex] or nil
    if candidate == nil or pf == nil or pf.getBandPath == nil or self.directExit then
        return false
    end
    local path, why = pf:getBandPath()
    if path == nil or #path < 2 then
        print(string.format("[AD-Exit] %s: pas de trajet par la grille vers le point %s, ni par la bande coupee (%s)", tostring(self.vehicle:getName()), tostring(candidate.wp.id), tostring(why)))
        return false
    end
    if pf.appendWayPoints ~= nil then
        for _, p in ipairs(pf.appendWayPoints) do
            path[#path + 1] = p
        end
    end
    local length = 0
    for i = 2, #path do
        length = length + MathUtil.vector2Length(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z)
    end
    print(string.format("[AD-Exit] %s: pas de trajet par la grille vers le point %s, trajet dans la bande coupee (%d points, %.0f m), en route", tostring(self.vehicle:getName()), tostring(candidate.wp.id), #path, length))
    self.wayPoints = path
    self.vehicle.ad.drivePathModule:setWayPoints(path)
    self.vehicle.ad.exitStuckFull = nil
    self.routeIsPartial = false
    self.routeStart = g_time
    self.state = ExitFieldTask.STATE_DRIVING
    return true
end

function ExitFieldTask:abort()
    ADBandTurn.abort(self.vehicle)
    ADFieldPark.setFieldExit(self.vehicle, nil)
    self.vehicle.ad.exitStuckFull = nil
end

function ExitFieldTask:finished()
    ADFieldPark.setFieldExit(self.vehicle, nil)
    self.vehicle.ad.exitStuckFull = nil
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

-- ---------------------------------------------------------------- full and stuck in the field (owner 26/10 14:43)

-- published on the vehicle while it is full with no clean way out: the field park count leaves it out (a third
-- unloader may come in), and the other stuck one compares the crop it would have to cross
function ExitFieldTask:publishStuck()
    local crop = self:getLeastCropCrossing()
    self.vehicle.ad.exitStuckFull = {t = g_time or 0, crop = crop}
end

-- metres of crop on the straight line to the nearest network points, the smallest
function ExitFieldTask:getLeastCropCrossing()
    local candidates = self.candidates
    if candidates == nil or #candidates == 0 then
        candidates = self:buildCandidates()
    end
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local halfWidth = self.vehicle.ad.pathFinderModule:getTrainWidth() / 2
    local least = nil
    for _, c in ipairs(candidates) do
        local crop = ExitFieldTask.getCropCrossing(vx, vz, c.wp.x, c.wp.z, halfWidth)
        if least == nil or crop < least then
            least = crop
        end
    end
    return least or math.huge
end

-- a straight, crop free line from here to one of the network points: worth a full route attempt
function ExitFieldTask:isStraightExitOpen()
    local candidates = self:buildCandidates()
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local halfWidth = self.vehicle.ad.pathFinderModule:getTrainWidth() / 2
    for _, c in ipairs(candidates) do
        if ExitFieldTask.getCropCrossing(vx, vz, c.wp.x, c.wp.z, halfWidth) < 0.5 then
            return true, c
        end
    end
    return false
end

-- the other stuck full unloader with less crop ahead of it leaves first (owner 26/10: "la pleine qui a le moins de
-- mais devant elle sort directement"); returns that vehicle, or nil when this one goes
function ExitFieldTask:getStuckWithLessCrop()
    local mine = self.vehicle.ad.exitStuckFull ~= nil and self.vehicle.ad.exitStuckFull.crop or math.huge
    local others = ExitFieldTask.getOtherUnloaders(self.vehicle)
    for _, other in ipairs(others) do
        local st = other.ad.exitStuckFull
        if st ~= nil then
            local theirs = st.crop or math.huge
            if theirs < mine - 0.5 or (math.abs(theirs - mine) <= 0.5 and (other.id or 0) < (self.vehicle.id or 0)) then
                return other, theirs, mine
            end
        end
    end
    return nil
end

-- the harvester's own track (CombineUtil.recordChopperTrail, 1 m points), and the harvester
function ExitFieldTask:getHarvesterTrail()
    local harvester = self.vehicle.ad.lastHarvester
    local trail = harvester ~= nil and harvester.ad ~= nil and harvester.ad.chopperTrail or nil
    if trail == nil or #trail < 10 then
        return nil
    end
    return trail, harvester
end

-- waypoints along the harvester's track, from its point nearest ahead of the tractor up to FOLLOW_BEHIND m before
-- its newest point, cut FOLLOW_OTHER_GAP m before another unloader standing on it. nil and the reason when nothing
-- can be followed from here
function ExitFieldTask:buildFollowPath()
    local trail = self:getHarvesterTrail()
    if trail == nil then
        return nil, "pas de trace de l'ensileuse"
    end
    local vx, vy, vz = getWorldTranslation(self.vehicle.components[1].node)
    local start, best = nil, math.huge
    for i, p in ipairs(trail) do
        local d = MathUtil.vector2Length(p.x - vx, p.z - vz)
        if d < best then
            local _, _, ahead = AutoDrive.worldToLocal(self.vehicle, p.x, vy, p.z)
            if ahead > 1 then
                start, best = i, d
            end
        end
    end
    if start == nil or best > ExitFieldTask.FOLLOW_ATTACH then
        return nil, string.format("trace de l'ensileuse a %.0f m devant moi", best)
    end
    local last, behind = #trail, 0
    while last > start and behind < ExitFieldTask.FOLLOW_BEHIND do
        behind = behind + MathUtil.vector2Length(trail[last].x - trail[last - 1].x, trail[last].z - trail[last - 1].z)
        last = last - 1
    end
    if last - start < 3 then
        return nil, string.format("deja a %.0f m de l'ensileuse", ExitFieldTask.FOLLOW_BEHIND)
    end
    local others = ExitFieldTask.getOtherUnloaders(self.vehicle)
    local positions = {}
    for _, other in ipairs(others) do
        if other.components ~= nil and other.components[1] ~= nil then
            local ox, _, oz = getWorldTranslation(other.components[1].node)
            table.insert(positions, {x = ox, z = oz, vehicle = other})
        end
    end
    -- the stretch, cut FOLLOW_OTHER_GAP before another unloader standing on the track (on the stretch or just after it)
    local points, dist, lastP = {}, {}, nil
    local acc = 0
    for i = start, #trail do
        local p = trail[i]
        if lastP ~= nil then
            acc = acc + MathUtil.vector2Length(p.x - lastP.x, p.z - lastP.z)
        end
        for _, o in ipairs(positions) do
            if MathUtil.vector2Length(o.x - p.x, o.z - p.z) < 6 then
                local cut = acc - ExitFieldTask.FOLLOW_OTHER_GAP
                local kept = {}
                for k, q in ipairs(points) do
                    if dist[k] <= cut then
                        table.insert(kept, q)
                    end
                end
                if #kept < 2 then
                    return nil, string.format("%s a %.0f m devant moi sur la trace", tostring(o.vehicle:getName()), acc)
                end
                return kept
            end
        end
        if i <= last and (lastP == nil or acc - (dist[#dist] or 0) >= ExitFieldTask.FOLLOW_STEP or i == last) then
            table.insert(points, {x = p.x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p.x, 1, p.z), z = p.z})
            table.insert(dist, acc)
        end
        lastP = p
    end
    return points
end

function ExitFieldTask:startFollowStrip()
    local path, why = self:buildFollowPath()
    if path == nil then
        if not self.followImpossibleLogged then
            self.followImpossibleLogged = true
            print(string.format("[AD-Exit] %s: pleine, pas de suivi de la bande possible (%s), j'attends ici", tostring(self.vehicle:getName()), tostring(why)))
        end
        return false
    end
    self.followImpossibleLogged = false
    print(string.format("[AD-Exit] %s: pleine et rangee, la suivante est en place : je suis la trace de l'ensileuse a %d m derriere elle (%d points) et je cherche une sortie en route", tostring(self.vehicle:getName()), ExitFieldTask.FOLLOW_BEHIND, #path))
    self.vehicle.ad.drivePathModule:setWayPoints(path)
    self.followTime = 0
    self.followCheck = 0
    self.followWaitLogged = false
    self.state = ExitFieldTask.STATE_FOLLOW_STRIP
    return true
end

function ExitFieldTask:updateFollowStrip(dt)
    self.followTime = (self.followTime or 0) + dt
    self.followCheck = (self.followCheck or 0) + dt
    if ExitFieldTask.isOtherApproaching(self.vehicle) then
        -- an empty unloader comes in behind: aside again so that it can pass, the follow resumes after
        print(string.format("[AD-Exit] %s: une benne vide arrive, je me range de nouveau sur le cote", tostring(self.vehicle:getName())))
        self.parkTried = false
        self.candidates = nil
        self.retryDelay = 1000
        self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        return
    end
    if self.followCheck >= ExitFieldTask.FOLLOW_EXIT_CHECK then
        self.followCheck = 0
        local open, candidate = self:isStraightExitOpen()
        if open or self.followTime >= ExitFieldTask.FOLLOW_EXIT_FULL_RETRY then
            print(string.format("[AD-Exit] %s: %s, essai de sortie", tostring(self.vehicle:getName()),
                open and string.format("ligne droite sans culture vers le point %s", tostring(candidate.wp.id)) or string.format("%d s de suivi", ExitFieldTask.FOLLOW_EXIT_FULL_RETRY / 1000)))
            self.followTime = 0
            self.candidates = nil
            self.retryDelay = 1000
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
            return
        end
    end
    local wayPoints = self.vehicle.ad.drivePathModule:getWayPoints()
    if self.vehicle.ad.drivePathModule:isTargetReached() or wayPoints == nil or #wayPoints == 0 then
        local path, why = self:buildFollowPath()
        if path ~= nil then
            self.followWaitLogged = false
            self.vehicle.ad.drivePathModule:setWayPoints(path)
        else
            if not self.followWaitLogged then
                self.followWaitLogged = true
                print(string.format("[AD-Exit] %s: suivi de la bande : j'attends (%s)", tostring(self.vehicle:getName()), tostring(why)))
            end
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
        end
        return
    end
    self.vehicle.ad.drivePathModule:update(dt)
end

ExitFieldTask.POINT_CHECK_INTERVAL = 2000 -- ms between two looks at the exit point
ExitFieldTask.POINT_CHECK_MIN_DISTANCE = 20 -- m: closer to the point, it goes on (the other one sees it coming)

-- owner 25/10: an empty unloader stands on the network point this one drives out to (it waits for its call there):
-- the next point of the list is tried, if there is one
function ExitFieldTask:isExitPointBlocked(dt)
    self.pointCheckTime = (self.pointCheckTime or 0) + dt
    if self.exitPoint == nil or self.pointCheckTime < ExitFieldTask.POINT_CHECK_INTERVAL then
        return false
    end
    self.pointCheckTime = 0
    if self.candidates == nil or self.candidateIndex == nil or self.candidateIndex >= #self.candidates then
        return false
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    if MathUtil.vector2Length(x - self.exitPoint.x, z - self.exitPoint.z) < ExitFieldTask.POINT_CHECK_MIN_DISTANCE then
        return false
    end
    local other = ADFieldPark.isExitPointTaken(self.vehicle, self.exitPoint.x, self.exitPoint.z)
    if other == nil then
        return false
    end
    print(string.format("[AD-Exit] %s: %s attend sur le point de sortie %s, point suivant", tostring(self.vehicle:getName()), tostring(other:getName()), tostring(self.exitPoint.id)))
    return true
end

ExitFieldTask.CANDIDATE_MAX_DISTANCE = 200   -- m, network points considered to leave the field
ExitFieldTask.CANDIDATE_SPACING = 15         -- m between two tried points
ExitFieldTask.CANDIDATE_COUNT = 6
ExitFieldTask.FIELD_POINT_MAX_DISTANCE = 2000 -- m, field entrance point tried first
-- owner 26/10 20:32 ("la sortie du champ doit se faire a l'entree ! c'est un cas exceptionnel s'il sort ailleurs"):
-- the entrance (the field's own network point) is tried again this many times, RETRY_DELAY apart, before any other
-- network point is considered; in a direct exit through the crop it is still preferred unless it costs much more crop
-- owner 27/10 20:48 (942 full, 40 s stopped: 3 tries on the entrance 116 m behind through the crop, the exit 13 m
-- away found at once): the entrance is tried once, then every other point, the nearest clean one wins (never through
-- crop, never off the field: the restrictions stay, pf.noFallback)
ExitFieldTask.ENTRANCE_TRIES = 1
ExitFieldTask.ENTRANCE_CROP_BONUS = 15 -- m of crop forgiven to the entrance when sorting the direct exit points
ExitFieldTask.BEHIND_PENALTY = 60            -- m added to points behind the vehicle

-- network points that lead to the destination, easiest first: the closest ones in front of the vehicle,
-- then the others, the field entrance (route start) included. Each is tried without ever driving
-- through crops; the first clean path wins, even if it is further away.
function ExitFieldTask:buildCandidates()
    local candidates = {}
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local dx, _, dz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local minDistance = AutoDrive.getDriverRadius(self.vehicle)
    local destination = self.vehicle.ad.stateModule:getSecondWayPoint()
    local routes = {}
    local closest = self.vehicle:getClosestWayPoint()
    if closest ~= nil then
        table.insert(routes, ADGraphManager:pathFromTo(closest, destination, nil, self.vehicle))
    end
    local fieldRoute = ADGraphManager:pathFromTo(self.vehicle.ad.stateModule:getFirstWayPoint(), destination, nil, self.vehicle)
    table.insert(routes, fieldRoute)
    -- the field's own network point (where the vehicle came in) is tried first, whatever its distance
    if fieldRoute ~= nil and #fieldRoute > 1 then
        local fieldWp, nextWp = fieldRoute[1], fieldRoute[2]
        local distance = MathUtil.vector2Length(fieldWp.x - vx, fieldWp.z - vz)
        if distance >= minDistance and distance <= ExitFieldTask.FIELD_POINT_MAX_DISTANCE then
            table.insert(candidates, {wp = fieldWp, vector = {x = nextWp.x - fieldWp.x, z = nextWp.z - fieldWp.z}, score = 0, distance = distance, entrance = true})
        end
    end

    local pool = {}
    local seen = {}
    for _, route in ipairs(routes) do
        if route ~= nil and #route > 1 then
            for i = 1, #route - 1 do
                local wp, nextWp = route[i], route[i + 1]
                if wp.id ~= nil and not seen[wp.id] then
                    seen[wp.id] = true
                    local distance = MathUtil.vector2Length(wp.x - vx, wp.z - vz)
                    if distance >= minDistance and distance <= ExitFieldTask.CANDIDATE_MAX_DISTANCE then
                        local score = distance
                        if (wp.x - vx) * dx + (wp.z - vz) * dz < 0 then
                            score = score + ExitFieldTask.BEHIND_PENALTY
                        end
                        table.insert(pool, {wp = wp, vector = {x = nextWp.x - wp.x, z = nextWp.z - wp.z}, score = score, distance = distance})
                    end
                end
            end
        end
    end
    table.sort(pool, function(a, b) return a.score < b.score end)
    for _, c in ipairs(pool) do
        local farEnough = true
        for _, chosen in ipairs(candidates) do
            if MathUtil.vector2Length(c.wp.x - chosen.wp.x, c.wp.z - chosen.wp.z) < ExitFieldTask.CANDIDATE_SPACING then
                farEnough = false
                break
            end
        end
        if farEnough then
            table.insert(candidates, c)
            if #candidates >= ExitFieldTask.CANDIDATE_COUNT then
                break
            end
        end
    end
    return candidates
end

-- returns true when a path planning was started, false when the task ended
function ExitFieldTask:startPathPlanning()
    ExitFieldTask.debugMsg(self.vehicle, "ExitFieldTask:startPathPlanning")
    if self.candidates == nil then
        local _, closestDistance = self.vehicle:getClosestWayPoint()
        if closestDistance ~= nil and closestDistance <= AutoDrive.getDriverRadius(self.vehicle) then
            -- close to network, set task finished
            self:finished()
            return false
        end
        self.candidates = self:buildCandidates()
        self.candidateIndex = 0
    end
    self.candidateIndex = self.candidateIndex + 1
    local candidate = self.candidates[self.candidateIndex]
    -- owner 26/10 20:32: the entrance gave no route (or an unloader waits on it): it is tried again before any other
    -- point; another exit is the exception, after ENTRANCE_TRIES failures in a row
    if not self.directExit and self.candidateIndex == 2 and self.candidates[1] ~= nil and self.candidates[1].entrance then
        self.entranceTries = (self.entranceTries or 0) + 1
        if self.entranceTries < ExitFieldTask.ENTRANCE_TRIES then
            print(string.format("[AD-Exit] %s: pas de trajet par l'entree du champ (point %s) pour l'instant, essai %d/%d, nouvel essai dans %d s avant d'envisager un autre point", tostring(self.vehicle:getName()), tostring(self.candidates[1].wp.id), self.entranceTries, ExitFieldTask.ENTRANCE_TRIES, ExitFieldTask.RETRY_DELAY / 1000))
            self.candidates = nil
            self.retryDelay = ExitFieldTask.RETRY_DELAY
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
            return false
        end
        print(string.format("[AD-Exit] %s: exception : l'entree du champ (point %s) n'a donne aucun trajet (%d essai(s)), les autres points de sortie sont essayes du plus proche au plus loin, sans culture ni sortie du champ", tostring(self.vehicle:getName()), tostring(self.candidates[1].wp.id), self.entranceTries))
    end
    if candidate == nil and not self.directExit and AutoDrive.isChopperUnloading(self.vehicle) then
        -- forage harvester only (opening a field: a narrow cut strip, no turning, no passing)
        -- fallback: no forward route found and the field exit is behind, U-turn in the strip first
        if self:startBandTurn() then
            return false
        end
        local others, stuck = ExitFieldTask.countOtherUnloaders(self.vehicle)
        if others > 0 then
            -- other unloaders: never through the crop. Move aside once so the next one can pass, then retry
            self:publishStuck()
            if not self.parkTried then
                self.parkTried = true
                local path, alreadyClear, backIndex = self.vehicle.ad.pathFinderModule:findParkAside(self.vehicle.ad.lastHarvester)
                if path ~= nil and backIndex ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:startTrackReverse(self.vehicle.ad.lastHarvester, ExitFieldTask.TRACK_REVERSE_DISTANCE, backIndex) then
                    -- back off a few meters first, then forward to the spot
                    self.parkPath = path
                    self.state = ExitFieldTask.STATE_PARK_BACK
                    return false
                elseif path ~= nil and backIndex == nil then
                    self.vehicle.ad.drivePathModule:setWayPoints(path)
                    self.state = ExitFieldTask.STATE_PARKING
                    return false
                end
                if alreadyClear then
                    self.parkedAside = g_time
                end
                -- nothing ahead: back off along its own track (crop free) to a place where the next one can pass
                if not alreadyClear and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:startTrackReverse(self.vehicle.ad.lastHarvester, ExitFieldTask.TRACK_REVERSE_DISTANCE) then
                    self.state = ExitFieldTask.STATE_TRACK_REVERSE
                    return false
                end
            end
            -- parked aside and the next one in place: follow the harvester's track and look for an exit on the way
            if self.parkedAside ~= nil and not ExitFieldTask.isOtherApproaching(self.vehicle) and self:startFollowStrip() then
                self.candidates = nil
                return false
            end
            print(string.format("[AD-Exit] %s: no clean path to the network (%d point(s) tried), %d other unloader(s): wait, retry in %d s", tostring(self.vehicle:getName()), #self.candidates, others, ExitFieldTask.RETRY_DELAY / 1000))
            self.candidates = nil
            self.retryDelay = ExitFieldTask.RETRY_DELAY
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
            return false
        end
        if stuck > 0 then
            -- owner 26/10 14:43: every other unloader is full and stuck too, no empty one to come: the one with the
            -- least crop ahead leaves through the crop, the other waits for it to be gone
            self:publishStuck()
            local first, theirs, mine = self:getStuckWithLessCrop()
            if first ~= nil then
                print(string.format("[AD-Exit] %s: toutes les bennes sont pleines et coincees, %s a moins de culture devant elle (%.0f m contre %.0f m), elle sort d'abord, nouvel essai dans %d s", tostring(self.vehicle:getName()), tostring(first:getName()), theirs, mine, ExitFieldTask.RETRY_DELAY / 1000))
                self.candidates = nil
                self.retryDelay = ExitFieldTask.RETRY_DELAY
                self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
                return false
            end
            print(string.format("[AD-Exit] %s: toutes les bennes sont pleines et coincees, aucune vide a venir : sortie directe par le moins de culture (%.0f m)", tostring(self.vehicle:getName()), mine or self:getLeastCropCrossing()))
        else
            -- alone (the others left to unload): direct exit, the point crossing the least crop first
            print(string.format("[AD-Exit] %s: no clean path to the network, no other unloader: direct exit, least crop first", tostring(self.vehicle:getName())))
        end
        self.directExit = true
        self.candidates = self:buildCandidates()
        local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
        local halfWidth = self.vehicle.ad.pathFinderModule:getTrainWidth() / 2
        for _, c in ipairs(self.candidates) do
            c.crop = ExitFieldTask.getCropCrossing(vx, vz, c.wp.x, c.wp.z, halfWidth)
        end
        table.sort(self.candidates, function(a, b)
            -- the entrance keeps the first place unless another point crosses much less crop
            local ca = a.crop - (a.entrance and ExitFieldTask.ENTRANCE_CROP_BONUS or 0)
            local cb = b.crop - (b.entrance and ExitFieldTask.ENTRANCE_CROP_BONUS or 0)
            if math.abs(ca - cb) > 0.5 then
                return ca < cb
            end
            return a.distance < b.distance
        end)
        self.candidateIndex = 1
        candidate = self.candidates[1]
        if candidate ~= nil then
            print(string.format("[AD-Exit] %s: direct exit toward network point %s, about %.0f m of crop on the straight line", tostring(self.vehicle:getName()), tostring(candidate.wp.id), candidate.crop))
        end
    end
    if candidate == nil then
        print(string.format("[AD-Exit] %s: no clean path to the network (%d point(s) tried), stopping", tostring(self.vehicle:getName()), #self.candidates))
        AutoDriveMessageEvent.sendMessageOrNotification(self.vehicle, ADMessagesManager.messageTypes.WARN, "$l10n_AD_Driver_of; %s $l10n_AD_cannot_find_path;", 5000, self.vehicle.ad.stateModule:getName())
        self.vehicle.ad.taskModule:abortAllTasks()
        self.vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(self.vehicle))
        return false
    end
    print(string.format("[AD-Exit] %s: trying network point %s (%d/%d, %.0f m)", tostring(self.vehicle:getName()), tostring(candidate.wp.id), self.candidateIndex, #self.candidates, candidate.distance))
    local pf = self.vehicle.ad.pathFinderModule
    pf:reset()
    -- direct exit: crop avoided where possible, crossed only when nothing else is left (fallback 3)
    pf.noFallback = self.directExit ~= true
    pf.allowCrop = self.directExit == true
    -- the end of the route is judged for obstacles too (a wall between the field and the road)
    pf.exitToNetwork = true
    local approach, appended = self:buildApproach(candidate)
    if approach ~= nil then
        -- owner 25/10: the point is reached along the axis of the network (the gate), the grid only has to
        -- bring the train to an approach point in the open field, aligned with that axis
        print(string.format("[AD-Exit] %s: point %s atteint par l'axe du reseau : approche a %.0f m avant (%.0f,%.0f), puis tout droit", tostring(self.vehicle:getName()), tostring(candidate.wp.id), approach.distance, approach.x, approach.z))
        pf:startPathPlanningTo(approach, {x = candidate.vector.x, z = candidate.vector.z})
        pf.appendWayPoints = appended
    else
        pf:startPathPlanningTo(candidate.wp, {x = candidate.vector.x, z = candidate.vector.z})
    end
    self.exitPoint = {x = candidate.wp.x, z = candidate.wp.z, id = candidate.wp.id}
    self.state = ExitFieldTask.STATE_PATHPLANNING
    return true
end

-- forage harvester, full, no forward route to any field exit (fallback only): U-turn in the strip once (owner: the
-- trailer may be backed into the crop), whatever the heading of the exit and the other unloaders (it is blocked anyway)
function ExitFieldTask:startBandTurn()
    if self.bandTurnTried or not AutoDrive.isChopperUnloading(self.vehicle) then
        return false
    end
    self.bandTurnTried = true
    if not ADBandTurn.canTry(self.vehicle) then
        print(string.format("[AD-DemiTour] %s: pas de demi-tour de secours ici (deja echoue a moins de %d m il y a moins de %d s)", tostring(self.vehicle:getName()), ADBandTurn.RETRY_DISTANCE, ADBandTurn.RETRY_TIME / 1000))
        return false
    end
    local angle = 0
    local first = self.candidates ~= nil and self.candidates[1] or nil
    if first ~= nil then
        local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
        local dx, _, dz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
        angle = math.abs(AutoDrive.angleBetween({x = dx, z = dz}, {x = first.wp.x - vx, z = first.wp.z - vz}))
    end
    if ADBandTurn.start(self.vehicle, string.format("secours, pleine, aucun chemin en marche avant (sortie a %.0f deg, autre benne en approche %s)", angle, tostring(ExitFieldTask.isOtherApproaching(self.vehicle))), nil) then
        self.state = ExitFieldTask.STATE_BAND_TURN
        return true
    end
    return false
end

ExitFieldTask.RETRY_DELAY = 10000
ExitFieldTask.TRACK_REVERSE_DISTANCE = 150 -- m backed off along its own track at most

-- meters of standing crop on the straight band (train width) from the vehicle to a point, from the field map
ExitFieldTask.APPROACH_DISTANCES = {20, 12} -- m before the network point, along the axis of the network, tried in this order
ExitFieldTask.APPROACH_STEP = 3             -- m between the points of the straight stretch to the network point
ExitFieldTask.APPROACH_MIN_VEHICLE_DISTANCE = 12 -- m: closer than approach + this, the point is driven to directly

-- owner 25/10: a field gate is a lane between a post and a wall, narrower than the train plus the margins of the
-- fine grids: the grid cannot find it, or finds it with a corner too sharp. The network does go through it,
-- so the point is reached along the axis of the network: an approach point in the open field, on that axis,
-- then straight on. Returns the approach point (target of the grid) and the points appended after it, or nil
-- when the axis does not fit here (approach point off the field, crop on the straight stretch, vehicle too close).
function ExitFieldTask:buildApproach(candidate)
    local wp, vector = candidate.wp, candidate.vector
    if wp == nil or vector == nil then
        return nil
    end
    local length = MathUtil.vector2Length(vector.x, vector.z)
    if length < 0.5 then
        return nil
    end
    local ux, uz = vector.x / length, vector.z / length
    local halfWidth = self.vehicle.ad.pathFinderModule:getTrainWidth() / 2
    local wy = wp.y or getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, wp.x, 1, wp.z)
    for _, distance in ipairs(ExitFieldTask.APPROACH_DISTANCES) do
        if (candidate.distance or 0) >= distance + ExitFieldTask.APPROACH_MIN_VEHICLE_DISTANCE then
            local ax, az = wp.x - ux * distance, wp.z - uz * distance
            local ay = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, ax, 1, az)
            if AutoDrive.checkIsOnField(ax, ay, az) and ExitFieldTask.getCropCrossing(ax, az, wp.x, wp.z, halfWidth) < 0.5 then
                local approach = {x = ax, y = ay, z = az, distance = distance}
                local appended = {approach}
                local d = ExitFieldTask.APPROACH_STEP
                while d < distance - ExitFieldTask.APPROACH_STEP / 2 do
                    local px, pz = ax + ux * d, az + uz * d
                    table.insert(appended, {x = px, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, px, 1, pz), z = pz})
                    d = d + ExitFieldTask.APPROACH_STEP
                end
                table.insert(appended, {x = wp.x, y = wy, z = wp.z})
                return approach, appended
            end
        end
    end
    return nil
end

function ExitFieldTask.getCropCrossing(x1, z1, x2, z2, halfWidth)
    local dx, dz = x2 - x1, z2 - z1
    local length = math.sqrt(dx * dx + dz * dz)
    if length < 0.5 then
        return 0
    end
    dx, dz = dx / length, dz / length
    local meters = 0
    local step = 1
    local d = 0
    while d <= length do
        local w = -halfWidth
        local hit = false
        while w <= halfWidth and not hit do
            local crop = PathFinderModule.getMapCropAt(x1 + dx * d - dz * w, z1 + dz * d + dx * w)
            if crop ~= nil and crop ~= 0 then
                hit = true
            end
            w = w + 0.5
        end
        if hit then
            meters = meters + step
        end
        d = d + step
    end
    return meters
end

-- another unloader is on its way to the harvester this one worked for (not yet unloading it)
function ExitFieldTask.isOtherApproaching(vehicle)
    local harvester = vehicle.ad.lastHarvester
    for _, other in pairs(ADHarvestManager.activeUnloaders or {}) do
        local mode = other ~= vehicle and other.ad ~= nil and other.ad.modes ~= nil and other.ad.modes[AutoDrive.MODE_UNLOAD] or nil
        if mode ~= nil and mode.combine == harvester and (mode.state == mode.STATE_DRIVE_TO_COMBINE or mode.state == mode.STATE_DRIVE_TO_PIPE) then
            return true
        end
    end
    return false
end

-- other unloaders working for the same destination (idle or busy), this one left out
function ExitFieldTask.getOtherUnloaders(vehicle)
    local others = {}
    local marker = vehicle.ad.stateModule:getFirstMarker()
    local seen = {}
    -- every AutoDrive unloader working this field counts, also one briefly unregistered (restarted, going to park)
    local all = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, list in ipairs({ADHarvestManager.idleUnloaders or {}, ADHarvestManager.activeUnloaders or {}, all}) do
        for _, other in pairs(list) do
            if other ~= vehicle and not seen[other] and other.ad ~= nil and other.ad.stateModule ~= nil and other.ad.stateModule:getFirstMarker() == marker
                and other.ad.stateModule:isActive() and other.ad.stateModule:getMode() == AutoDrive.MODE_UNLOAD then
                seen[other] = true
                table.insert(others, other)
            end
        end
    end
    return others
end

-- the others that can still come and unload (not full and stuck themselves), and the stuck full ones apart
function ExitFieldTask.countOtherUnloaders(vehicle)
    local free, stuck = 0, 0
    for _, other in ipairs(ExitFieldTask.getOtherUnloaders(vehicle)) do
        if other.ad.exitStuckFull ~= nil then
            stuck = stuck + 1
        else
            free = free + 1
        end
    end
    return free, stuck
end

function ExitFieldTask:selectNextStrategy()
    self.nextExitStrategy = (self.nextExitStrategy + 1) % (ExitFieldTask.STRATEGY_CLOSEST + 1)
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
    if self.state == ExitFieldTask.STATE_PATHPLANNING then
        return "$l10n_AD_task_plan_field_exit;" .. string.format(" (%d s)", self:getStateSeconds())
    elseif self.state == ExitFieldTask.STATE_DELAY_PATHPLANNING then
        if self.parkedAside ~= nil then
            return "$l10n_AD_task_full_parked_aside;"
        end
        local delay = self.retryDelay or 1000
        if delay > 1000 then
            local left = math.max(0, delay - (self.waitForCheckTimer.elapsedTime or 0))
            return "$l10n_AD_task_no_exit_retry;" .. string.format(" %d s", math.ceil(left / 1000))
        end
        return "$l10n_AD_task_plan_field_exit;" .. string.format(" (%d s)", self:getStateSeconds())
    elseif self.state == ExitFieldTask.STATE_PARKING then
        return "$l10n_AD_task_full_parked_aside;"
    elseif self.state == ExitFieldTask.STATE_FOLLOW_STRIP then
        return "$l10n_AD_task_full_follow_strip;"
    elseif self.state == ExitFieldTask.STATE_TRACK_REVERSE or self.state == ExitFieldTask.STATE_PARK_BACK then
        return "$l10n_AD_task_full_reverse_tracks;"
    elseif self.state == ExitFieldTask.STATE_BAND_TURN then
        return "$l10n_AD_task_band_turn_exit;"
    else
        return "$l10n_AD_task_exiting_field;"
    end
end

function ExitFieldTask.debugMsg(vehicle, debugText, ...)
    if ExitFieldTask.debug == true then
        AutoDrive.debugMsg(vehicle, debugText, ...)
    else
        AutoDrive.debugPrint(vehicle, AutoDrive.DC_COMBINEINFO, debugText, ...)
    end
end
