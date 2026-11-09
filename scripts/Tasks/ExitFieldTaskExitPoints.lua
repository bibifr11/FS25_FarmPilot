-- ============================================================================================================
-- FarmPilot : ExitFieldTaskExitPoints.lua
-- Complément de ExitFieldTask (tâche AutoDrive d'origine) : par où la benne pleine sort du champ.
--
-- Historique : 25/10 (point de sortie publié pour les bennes vides qui arrivent ;
-- un point occupé par une benne qui attend : point suivant ; bloquée par un obstacle sur le trajet : zone interdite et
-- nouveau calcul ; barrière du champ : point atteint dans l'axe du réseau), 26/10 20:32 (la sortie du champ se fait
-- à l'entrée, sortir ailleurs reste l'exception), 27/10 17:18 (champ 13 : trajet par la bande
-- coupée), 27/10 20:48 (942 plein, 40 s arrêté : l'entrée essayée une fois, puis le point propre le plus proche).
--
-- Règle : à la place des « stratégies » d'AutoDrive, une liste de points du réseau qui mènent à la destination :
-- l'entrée du champ (point du champ) d'abord, puis les plus proches devant le véhicule ; chacun est essayé sans jamais
-- traverser la culture ni sortir du champ (pf.noFallback), le premier trajet propre gagne. Approche dans l'axe du réseau
-- quand elle tient. Pas de trajet par la grille : la bande coupée. Plus aucun point : la benne s'arrête (ou, avec une
-- ensileuse, ExitFieldTaskStuck.lua : se ranger, demi-tour, sortie directe par le moins de culture).
--
-- Branché par une ligne dans ExitFieldTask.lua : update (4 accroches), abort, finished, startPathPlanning, getI18nInfo.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
ExitFieldTask.RETRY_DELAY = 10000

ExitFieldTask.POINT_CHECK_INTERVAL = 2000 -- ms between two looks at the exit point
ExitFieldTask.POINT_CHECK_MIN_DISTANCE = 20 -- m: closer to the point, it goes on (the other one sees it coming)

ExitFieldTask.CANDIDATE_MAX_DISTANCE = 200   -- m, network points considered to leave the field
ExitFieldTask.CANDIDATE_SPACING = 15         -- m between two tried points
ExitFieldTask.CANDIDATE_COUNT = 6
ExitFieldTask.FIELD_POINT_MAX_DISTANCE = 2000 -- m, field entrance point tried first
-- 26/10 20:32 (the field is left by its entrance, another exit is the exception):
-- the entrance (the field's own network point) is tried again this many times, RETRY_DELAY apart, before any other
-- network point is considered; in a direct exit through the crop it is still preferred unless it costs much more crop
-- 27/10 20:48 (942 full, 40 s stopped: 3 tries on the entrance 116 m behind through the crop, the exit 13 m
-- away found at once): the entrance is tried once, then every other point, the nearest clean one wins (never through
-- crop, never off the field: the restrictions stay, pf.noFallback)
ExitFieldTask.ENTRANCE_TRIES = 1
ExitFieldTask.ENTRANCE_CROP_BONUS = 15 -- m of crop forgiven to the entrance when sorting the direct exit points
ExitFieldTask.BEHIND_PENALTY = 60            -- m added to points behind the vehicle

ExitFieldTask.APPROACH_DISTANCES = {20, 12} -- m before the network point, along the axis of the network, tried in this order
ExitFieldTask.APPROACH_STEP = 3             -- m between the points of the straight stretch to the network point
ExitFieldTask.APPROACH_MIN_VEHICLE_DISTANCE = 12 -- m: closer than approach + this, the point is driven to directly

-- ------------------------------------------------------------------------------------------------------------
-- Point de sortie publié (ExitFieldTask:update)
-- ------------------------------------------------------------------------------------------------------------
function ExitFieldTask:publishFieldExit()
    -- 25/10: the point it drives out to is published, an empty unloader coming in waits before the entrance
    if self.state == ExitFieldTask.STATE_DRIVING and self.exitPoint ~= nil then
        ADFieldPark.setFieldExit(self.vehicle, self.exitPoint.x, self.exitPoint.z)
    else
        ADFieldPark.setFieldExit(self.vehicle, nil)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Calcul du trajet vers le point de sortie (ExitFieldTask:startPathPlanning)
-- ------------------------------------------------------------------------------------------------------------
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

function ExitFieldTask:startExitPlanning()
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
    -- 26/10 20:32: the entrance gave no route (or an unloader waits on it): it is tried again before any other
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
            -- 26/10 14:43: every other unloader is full and stuck too, no empty one to come: the one with the
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
        -- 25/10: the point is reached along the axis of the network (the gate), the grid only has to
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

-- 25/10: a field gate is a lane between a post and a wall, narrower than the train plus the margins of the
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

-- meters of standing crop on the straight band (train width) from the vehicle to a point, from the field map
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

-- ------------------------------------------------------------------------------------------------------------
-- Résultat du calcul (ExitFieldTask:update, STATE_PATHPLANNING)
-- ------------------------------------------------------------------------------------------------------------
-- aucun trajet trouvé par la grille
function ExitFieldTask:handleNoExitRoute()
    -- 27/10 17:18 (field 13): the grid found nothing toward the entrance three times while a 343 m route
    -- along the cut strip existed: that route is taken, as the second unloader does on its way to the first
    if self:tryBandExit() then
        return
    end
    -- no clean path to this network point: try the next one right away
    if not self:startPathPlanning() then
        return
    end
end

-- trajet trouvé, donné au conducteur
function ExitFieldTask:onExitRouteSet()
    self.vehicle.ad.exitStuckFull = nil
    -- partial route (guided departure, part of the way): not out of the field at its end
    self.routeIsPartial = self.vehicle.ad.pathFinderModule.partialPath == true
    self.routeStart = g_time
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

-- ------------------------------------------------------------------------------------------------------------
-- En route vers le point de sortie (ExitFieldTask:update, STATE_DRIVING)
-- ------------------------------------------------------------------------------------------------------------
-- true : traité ici (l'étape a pu changer) ; false : le code d'AutoDrive continue (arrivé, sinon rouler)
function ExitFieldTask:updateExitDriving(dt)
    if self.vehicle.ad.drivePathModule:isTargetReached() and self.routeIsPartial then
        -- end of a partial route: still in the field, plan the rest from here
        print(string.format("[AD-Fin] %s: bout du trajet partiel atteint, calcul de la suite", tostring(self.vehicle:getName())))
        self.routeIsPartial = false
        self.candidates = nil
        self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        return true
    elseif self.vehicle.ad.drivePathModule:isTargetReached() then
        return false
    elseif self:isExitPointBlocked(dt) then
        -- an unloader waits on the point: the next point instead
        self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        return true
    elseif self.vehicle.ad.routeBlockedTime ~= nil and self.routeStart ~= nil and self.vehicle.ad.routeBlockedTime > self.routeStart then
        -- 25/10: the front sensor kept it stopped on this route (wall, post): the place is a forbidden zone now,
        -- the exit is planned again around it instead of waiting there
        print(string.format("[AD-Exit] %s: bloque par un obstacle sur le trajet vers le point %s, nouveau calcul en l'evitant", tostring(self.vehicle:getName()), self.exitPoint ~= nil and tostring(self.exitPoint.id) or "?"))
        self.routeStart = nil
        self.candidates = nil
        self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        return true
    end
    return false
end

-- 25/10: an empty unloader stands on the network point this one drives out to (it waits for its call there):
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

-- ------------------------------------------------------------------------------------------------------------
-- Fin de la tâche (ExitFieldTask:abort, ExitFieldTask:finished)
-- ------------------------------------------------------------------------------------------------------------
function ExitFieldTask:abortFieldExit()
    ADBandTurn.abort(self.vehicle)
    ADFieldPark.setFieldExit(self.vehicle, nil)
    self.vehicle.ad.exitStuckFull = nil
end

function ExitFieldTask:finishFieldExit()
    ADFieldPark.setFieldExit(self.vehicle, nil)
    self.vehicle.ad.exitStuckFull = nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Textes du HUD (ExitFieldTask:getI18nInfo)
-- ------------------------------------------------------------------------------------------------------------
-- nil : le texte d'origine d'AutoDrive (sortie du champ)
function ExitFieldTask:getExitI18nInfo()
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
    end
    return nil
end
