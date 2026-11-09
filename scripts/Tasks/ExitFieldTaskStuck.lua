-- ============================================================================================================
-- FarmPilot : ExitFieldTaskStuck.lua
-- Complément de ExitFieldTask (tâche AutoDrive d'origine) : benne pleine d'une ensileuse sans sortie propre.
--
-- Historique : 26/10 14:43 (elle suit la 2e, passée en 1re, jusqu'au bout ou jusqu'à pouvoir
-- sortir ; la pleine qui a le moins de maïs devant elle sort directement).
--
-- Règle (ensileuse seulement, ouverture de champ : bande étroite, pas de demi-tour ni de dépassement) :
-- - aucun trajet en marche avant vers la sortie : demi-tour de secours dans la bande, une fois (ADBandTurn) ;
-- - d'autres bennes travaillent : jamais à travers la culture ; la pleine se range sur le côté (ou recule sur sa
--   propre trace) pour laisser passer la suivante, attend qu'elle soit en place, puis suit la trace de l'ensileuse à
--   distance en cherchant une sortie en route ;
-- - toutes les bennes sont pleines et coincées : celle qui a le moins de culture devant elle sort directement,
--   les autres attendent ; seule : sortie directe par le moins de culture.
--
-- Branché par : ExitFieldTask:update (une ligne, voir ExitFieldTask.lua) et ExitFieldTask:startExitPlanning
-- (ExitFieldTaskExitPoints.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
ExitFieldTask.STATE_PARKING = 4 -- forage harvester: moving aside to let the next unloader pass
ExitFieldTask.STATE_TRACK_REVERSE = 5 -- forage harvester: backing off along its own track to let the next unloader pass
ExitFieldTask.STATE_PARK_BACK = 6 -- forage harvester: backing off a few meters along its track before driving to its spot
ExitFieldTask.STATE_BAND_TURN = 7 -- forage harvester: U-turn in the strip, the field exit is behind
ExitFieldTask.WAIT_OTHER_TIME = 120000 -- ms, parked aside: waits for the next unloader to be in place at the harvester
-- 26/10 14:43 (it follows the 2nd, now 1st, to the end or until it can get out): full, parked aside and the next
-- unloader in place: follows the harvester's own track (cut ground) at a distance and looks for an exit on the way,
-- instead of waiting at its spot until a passage opens right there
ExitFieldTask.STATE_FOLLOW_STRIP = 8
ExitFieldTask.FOLLOW_BEHIND = 60             -- m of harvester track kept between the train and the harvester
ExitFieldTask.FOLLOW_ATTACH = 20             -- m: the track must pass this close ahead of the tractor to be followed
ExitFieldTask.FOLLOW_OTHER_GAP = 30          -- m kept behind another unloader standing on the track ahead
ExitFieldTask.FOLLOW_STEP = 3                -- m between the waypoints taken from the track
ExitFieldTask.FOLLOW_EXIT_CHECK = 10000      -- ms between two looks for a crop free straight line to a network point
ExitFieldTask.FOLLOW_EXIT_FULL_RETRY = 60000 -- ms between two full route attempts while following
ExitFieldTask.TRACK_REVERSE_DISTANCE = 150 -- m backed off along its own track at most

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale : étapes propres à la benne coincée (ExitFieldTask:update)
-- ------------------------------------------------------------------------------------------------------------
-- true : étape traitée ici (fin de l'update) ; false : les étapes d'AutoDrive continuent
function ExitFieldTask:updateFullStuck(dt)
    if self.state == ExitFieldTask.STATE_DELAY_PATHPLANNING and self.parkedAside ~= nil
        and g_time - self.parkedAside < ExitFieldTask.WAIT_OTHER_TIME and ExitFieldTask.isOtherApproaching(self.vehicle) then
        -- parked aside: the next unloader is still on its way to the harvester, let it pass first
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return true
    elseif self.state == ExitFieldTask.STATE_FOLLOW_STRIP then
        self:updateFollowStrip(dt)
        return true
    elseif self.state == ExitFieldTask.STATE_BAND_TURN then
        if ADBandTurn.update(self.vehicle, dt) ~= "running" then
            -- turned (or not): the exit points are sorted again from the new heading
            self.candidates = nil
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        end
        return true
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
                return true
            end
            print(string.format("[AD-Exit] %s: nouvel essai de sortie toutes les %d s", tostring(self.vehicle:getName()), ExitFieldTask.RETRY_DELAY / 1000))
            self.parkedAside = g_time
            self.candidates = nil
            self.retryDelay = ExitFieldTask.RETRY_DELAY
            self.state = ExitFieldTask.STATE_DELAY_PATHPLANNING
        end
    else
        return false
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Pleine et coincée dans le champ (full and stuck in the field, 26/10 14:43)
-- ------------------------------------------------------------------------------------------------------------
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

-- the other stuck full unloader with less crop ahead of it leaves first (26/10: the full one with the least
-- maize ahead of it drives straight out); returns that vehicle, or nil when this one goes
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

-- ------------------------------------------------------------------------------------------------------------
-- Suivre la trace de l'ensileuse et chercher une sortie en route
-- ------------------------------------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------------------------------------
-- Demi-tour de secours dans la bande
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester, full, no forward route to any field exit (fallback only): U-turn in the strip once (the
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

-- ------------------------------------------------------------------------------------------------------------
-- Les autres bennes de ce champ
-- ------------------------------------------------------------------------------------------------------------
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
