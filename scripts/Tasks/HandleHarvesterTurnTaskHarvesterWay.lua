-- ============================================================================================================
-- FarmPilot : HandleHarvesterTurnTaskHarvesterWay.lua
-- Complément de HandleHarvesterTurnTask : en bout de rang, la benne et l'ENSILEUSE qui finit son propre virage
-- (benne qui roule à côté). Ne concerne pas la moissonneuse.
--
-- 30/10 20:48-20:54 : le 942 et le Bergmann nez à nez avec la coupe de la Jaguar en bout de rang,
-- tous deux en attente pendant des minutes.
--
-- Règles (lettres des commentaires) :
-- - A : l'ensileuse est exclue du contrôle d'obstacles du demi-tour ; son chemin (son corps, l'entrée de son
--   nouveau rang lue sur Courseplay et SWEEP_AHEAD m de parcours après) ne doit pas croiser le demi-tour, sinon la
--   benne attend qu'elle soit entrée dans son rang et passée ;
-- - B : nez à nez FACE_BACK_OFF_TIME : la benne recule dans ses traces (CombineUnloaderModeTracks.lua) et la laisse
--   passer ;
-- - C : pas d'attente sans fin devant elle : demi-tour abandonné, recherche de route ;
-- - D : un demi-tour immobile dit pourquoi dans le log toutes les STILL_LOG_TIME.
--
-- Branché par des lignes dans HandleHarvesterTurnTask.lua : update (checkTurnStill pendant le demi-tour, états
-- STATE_WAIT_HARVESTER_PASS et STATE_BACK_OFF_HARVESTER), abort (endBackOffOnAbort) ; le croisement est
-- vérifié dans HandleHarvesterTurnTaskTurns.lua (acceptOrDropTurn).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- 30/10 20:48-20:54 (942 + Bergmann nose to nose with the Jaguar's header at the row end, both waiting for
-- minutes): the U-turn is checked against the rest of the harvester's turn, a face to face is solved by backing off,
-- no endless wait, and a still U-turn says why in the log
HandleHarvesterTurnTask.STATE_WAIT_HARVESTER_PASS = 14
HandleHarvesterTurnTask.STATE_BACK_OFF_HARVESTER = 15
HandleHarvesterTurnTask.SWEEP_AHEAD = 25          -- m of the harvester's course after its new row entry
HandleHarvesterTurnTask.SWEEP_MARGIN = 1.5        -- m kept between the harvester (header) and the train
HandleHarvesterTurnTask.SWEEP_REAR_GAP = 2        -- m behind its rear: it drives away, no lateral margin there
HandleHarvesterTurnTask.PASS_CHECK_INTERVAL = 500 -- ms
HandleHarvesterTurnTask.PASS_STANDING = 5000      -- ms the harvester stands on my way: it waits for me, route search
HandleHarvesterTurnTask.PASS_WAIT_MAX = 60000     -- ms waiting for it to pass at most
HandleHarvesterTurnTask.PASS_MOVED = 10           -- m the harvester drives after my back-off: passed
HandleHarvesterTurnTask.FACE_DISTANCE = 12        -- m from my nose: the harvester in front blocks me
HandleHarvesterTurnTask.FACE_ANGLE = 60           -- deg off my heading at most
HandleHarvesterTurnTask.FACE_BACK_OFF_TIME = 5000 -- ms face to face before backing off (B)
HandleHarvesterTurnTask.FACE_GIVE_UP_TIME = 15000 -- ms still with the harvester close: U-turn dropped (C)
HandleHarvesterTurnTask.FACE_GIVE_UP_RANGE = 20   -- m
HandleHarvesterTurnTask.BACK_OFF_MAX = 25         -- m backed off in the tracks at most
HandleHarvesterTurnTask.STILL_LOG_TIME = 10000    -- ms between two "still" log lines (D)

-- ------------------------------------------------------------------------------------------------------------
-- Chemin de l'ensileuse et croisement
-- ------------------------------------------------------------------------------------------------------------
-- the Courseplay fieldwork course of the harvester, nil if none
function HandleHarvesterTurnTask:getCpCourse()
    local combine = self.combine
    local strategy = combine ~= nil and combine.getCpDriveStrategy ~= nil and combine:getCpDriveStrategy() or nil
    if strategy == nil then
        return nil
    end
    local course = strategy.getFieldworkCourse ~= nil and strategy:getFieldworkCourse() or nil
    course = course or strategy.fieldWorkCourse
    if course == nil or course.getNumberOfWaypoints == nil or course.getWaypointPosition == nil or course.getCurrentWaypointIx == nil then
        return nil
    end
    return course
end

-- where the harvester is and goes (30/10, A): its body (rear to front), then its new row entry (green point,
-- while it turns) and SWEEP_AHEAD m of its course after it; without a readable course its lane straight ahead.
-- Returns the points (x, z), the half width swept (header included) and its body {x, z, dx, dz, rear}
function HandleHarvesterTurnTask:getHarvesterSweep()
    local c = self.combine
    local hx, _, hz = getWorldTranslation(c.components[1].node)
    local dx, _, dz = AutoDrive.localDirectionToWorld(c, 0, 0, 1)
    local len = c.size ~= nil and c.size.length or 10
    local pts = {{x = hx - dx * len / 2, z = hz - dz * len / 2}, {x = hx + dx * len / 2, z = hz + dz * len / 2}}
    local course = self:getCpCourse()
    local n = course ~= nil and course:getNumberOfWaypoints() or 0
    local ix = course ~= nil and course:getCurrentWaypointIx() or nil
    if course ~= nil and ix ~= nil and n > 1 then
        local from = ix
        local row = CombineUnloaderMode ~= nil and CombineUnloaderMode.getCpRowTurn ~= nil and CombineUnloaderMode.getCpRowTurn(c) or nil
        if row ~= nil and row.turning and row.endIx ~= nil and row.endIx > ix then
            from = row.endIx
        end
        local walked, last = 0, nil
        for i = math.max(1, from), n do
            local x, _, z = course:getWaypointPosition(i)
            if last ~= nil then
                walked = walked + MathUtil.vector2Length(x - last.x, z - last.z)
            end
            pts[#pts + 1] = {x = x, z = z}
            last = {x = x, z = z}
            if walked >= HandleHarvesterTurnTask.SWEEP_AHEAD then
                break
            end
        end
    else
        local fx, fz = pts[2].x, pts[2].z
        pts[#pts + 1] = {x = fx + dx * HandleHarvesterTurnTask.SWEEP_AHEAD, z = fz + dz * HandleHarvesterTurnTask.SWEEP_AHEAD}
    end
    local width = math.max(AutoDrive.getFrontToolWidth(c) or 0, c.size ~= nil and c.size.width or 4)
    return pts, width / 2 + HandleHarvesterTurnTask.SWEEP_MARGIN, {x = hx, z = hz, dx = dx, dz = dz, rear = len / 2}
end

local function segmentDistance(px, pz, a, b)
    local vx, vz = b.x - a.x, b.z - a.z
    local l2 = vx * vx + vz * vz
    local t = 0
    if l2 > 1e-6 then
        t = math.max(0, math.min(1, ((px - a.x) * vx + (pz - a.z) * vz) / l2))
    end
    local qx, qz = a.x + vx * t, a.z + vz * t
    return math.sqrt((px - qx) ^ 2 + (pz - qz) ^ 2)
end

-- true, x, z, gap when a point of my path from index `from` comes within the harvester's sweep
function HandleHarvesterTurnTask:crossesHarvesterWay(points, from)
    local sweep, half, body = self:getHarvesterSweep()
    local train = self.vehicle.ad.pathFinderModule ~= nil and self.vehicle.ad.pathFinderModule:getTrainWidth() / 2 or 1.5
    local limit = half + train
    for i = math.max(1, from or 1), #points do
        local p = points[i]
        -- behind its rear (it drives away from there): only its course ahead counts, not its body
        local along = (p.x - body.x) * body.dx + (p.z - body.z) * body.dz
        local first = along < -body.rear - HandleHarvesterTurnTask.SWEEP_REAR_GAP and 3 or 2
        for k = first, #sweep do
            local d = segmentDistance(p.x, p.z, sweep[k - 1], sweep[k])
            if d < limit then
                return true, p.x, p.z, d
            end
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Attendre qu'elle soit passée, ou abandonner pour la recherche de route
-- ------------------------------------------------------------------------------------------------------------
function HandleHarvesterTurnTask:startWaitHarvesterPass(points, why)
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    self.passWait = {points = points, time = 0, check = 0, cx = cx, cz = cz, why = why}
    self.state = HandleHarvesterTurnTask.STATE_WAIT_HARVESTER_PASS
end

-- the U-turn is dropped, AutoDrive plans a route to the harvester (as when no fixed turn fits)
function HandleHarvesterTurnTask:giveUpToRoute(why)
    print(string.format("[AD-DemiTour] %s: %s : demi-tour abandonne, recherche de route", tostring(self.vehicle:getName()), why))
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if mode.trackReverse ~= nil and mode.endTrackReverse ~= nil then
        mode:endTrackReverse()
    end
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.endRowUTurn = nil
    self.endRowGaveUp = true
    self:finished(ADTaskModule.DONT_PROPAGATE)
    mode:setToWaitForCall(true)
end

-- A / after B: stopped until the harvester has passed (U-turn then started), or it stands on my way (route search)
function HandleHarvesterTurnTask:updateWaitHarvesterPass(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    local w = self.passWait
    w.time = w.time + dt
    w.check = w.check + dt
    if w.check < HandleHarvesterTurnTask.PASS_CHECK_INTERVAL then
        return
    end
    w.check = 0
    local name = tostring(self.vehicle:getName())
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    local moved = MathUtil.vector2Length(cx - w.cx, cz - w.cz)
    if w.points ~= nil then
        if not self:crossesHarvesterWay(w.points, 1) then
            print(string.format("[AD-DemiTour] %s: l'ensileuse est passee (%.0f s), je lance mon demi-tour derriere elle", name, w.time / 1000))
            self:continueWith(w.points)
            self.passWait = nil
            return
        end
    elseif moved >= HandleHarvesterTurnTask.PASS_MOVED then
        self:giveUpToRoute(string.format("l'ensileuse est passee (%.0f m), je repars derriere elle", moved))
        return
    end
    local standing = self.combine.ad ~= nil and self.combine.ad.noMovementTimer ~= nil and self.combine.ad.noMovementTimer.elapsedTime or 0
    if w.time >= HandleHarvesterTurnTask.PASS_STANDING and standing >= HandleHarvesterTurnTask.PASS_STANDING then
        self:giveUpToRoute(string.format("l'ensileuse est arretee depuis %.0f s sur mon chemin, elle m'attend", standing / 1000))
    elseif w.time >= HandleHarvesterTurnTask.PASS_WAIT_MAX then
        self:giveUpToRoute(string.format("l'ensileuse n'est pas passee en %.0f s", w.time / 1000))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Demi-tour immobile : face à face, recul dans les traces, log
-- ------------------------------------------------------------------------------------------------------------
-- the harvester in front of my nose: distance (m) or nil
function HandleHarvesterTurnTask:getHarvesterInFront()
    local approach = self.vehicle.ad.approachModule
    if approach ~= nil and approach.getHit ~= nil then
        local hit = approach:getHit()
        if hit ~= nil and hit.object ~= nil then
            local object = hit.object.getRootVehicle ~= nil and hit.object:getRootVehicle() or hit.object
            if object == self.combine or AutoDrive:checkIsConnected(self.combine, hit.object) then
                return approach.getEstimatedDistance ~= nil and approach:getEstimatedDistance() or 0
            end
        end
    end
    local hx, hy, hz = getWorldTranslation(self.combine.components[1].node)
    local lx, _, lz = AutoDrive.worldToLocal(self.vehicle, hx, hy, hz)
    local front = (self.vehicle.size ~= nil and self.vehicle.size.length or 5) / 2
    local back = (self.combine.size ~= nil and self.combine.size.length or 10) / 2
    local d = math.sqrt(lx * lx + lz * lz) - back - front
    if lz > 0 and math.deg(math.abs(math.atan2(lx, lz))) <= HandleHarvesterTurnTask.FACE_ANGLE and d <= HandleHarvesterTurnTask.FACE_DISTANCE then
        return math.max(0, d)
    end
    return nil
end

-- B, C, D while the U-turn is driven. true when the state changed
function HandleHarvesterTurnTask:checkTurnStill(dt)
    local still = math.abs(self.vehicle.lastSpeedReal or 0) < 0.0003
    local st = self.turnStill
    if not still then
        self.turnStill = nil
        return false
    end
    if st == nil then
        st = {time = 0, face = 0, logAt = HandleHarvesterTurnTask.STILL_LOG_TIME}
        self.turnStill = st
    end
    st.time = st.time + dt
    local name = tostring(self.vehicle:getName())
    local faceDistance = self.endRow and self:getHarvesterInFront() or nil
    if faceDistance ~= nil then
        st.face = st.face + dt
    else
        st.face = 0
    end
    local harvesterDistance = AutoDrive.getDistanceBetween(self.vehicle, self.combine)
    -- D: say why every STILL_LOG_TIME
    if st.time >= st.logAt then
        st.logAt = st.logAt + HandleHarvesterTurnTask.STILL_LOG_TIME
        local what = "rien de detecte devant"
        local approach = self.vehicle.ad.approachModule
        local hit = approach ~= nil and approach.getHit ~= nil and approach:getHit() or nil
        if hit ~= nil and hit.object ~= nil then
            local object = hit.object.getRootVehicle ~= nil and hit.object:getRootVehicle() or hit.object
            what = string.format("'%s' a %.1f m devant", tostring(object.getName ~= nil and object:getName() or "objet"), approach.getEstimatedDistance ~= nil and approach:getEstimatedDistance() or -1)
        end
        local index = self.vehicle.ad.drivePathModule:getCurrentWayPointIndex() or 0
        local speed = (self.combine.lastSpeedReal or 0) * 3600
        print(string.format("[AD-DemiTour] %s: demi-tour immobile depuis %.0f s (point %d/%d) : %s, ensileuse a %.0f m%s (%.0f km/h)",
            name, st.time / 1000, index, self.points ~= nil and #self.points or 0, what, harvesterDistance, faceDistance ~= nil and string.format(", face a moi a %.1f m", faceDistance) or "", speed))
    end
    if not self.endRow then
        return false
    end
    -- B: face to face 5 s: back off in my tracks out of its way, then let it pass
    if st.face >= HandleHarvesterTurnTask.FACE_BACK_OFF_TIME and not st.backOffTried then
        st.backOffTried = true
        local articulated = ADTrafficYieldModule ~= nil and ADTrafficYieldModule.cannotReverse ~= nil and ADTrafficYieldModule.cannotReverse(self.vehicle)
        if articulated then
            print(string.format("[AD-DemiTour] %s: nez a nez avec l'ensileuse depuis %.0f s, remorque articulee : pas de recul", name, st.face / 1000))
        else
            print(string.format("[AD-DemiTour] %s: nez a nez avec l'ensileuse depuis %.0f s (%.1f m), je recule dans mes traces pour lui laisser le passage", name, st.face / 1000, faceDistance or -1))
            local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
            if mode:startTrackReverse(self.combine, HandleHarvesterTurnTask.BACK_OFF_MAX) then
                self.turnStill = nil
                self.state = HandleHarvesterTurnTask.STATE_BACK_OFF_HARVESTER
                return true
            end
        end
    end
    -- C: no endless wait in front of it
    if st.time >= HandleHarvesterTurnTask.FACE_GIVE_UP_TIME and harvesterDistance <= HandleHarvesterTurnTask.FACE_GIVE_UP_RANGE then
        self.turnStill = nil
        self:giveUpToRoute(string.format("immobile depuis %.0f s avec l'ensileuse a %.0f m", st.time / 1000, harvesterDistance))
        return true
    end
    return false
end

-- B: backing off in the tracks, then waiting for the harvester to pass
function HandleHarvesterTurnTask:updateBackOffHarvester(dt)
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    local result = mode:updateTrackReverse(dt)
    if result == "running" then
        return
    end
    print(string.format("[AD-DemiTour] %s: recul pour l'ensileuse fini (%s, %.0f m), j'attends qu'elle passe", tostring(self.vehicle:getName()), result, mode.trackReverseMoved or 0))
    self:startWaitHarvesterPass(nil, "recul")
end

-- ------------------------------------------------------------------------------------------------------------
-- Tâche interrompue pendant le recul (accroche dans abort)
-- ------------------------------------------------------------------------------------------------------------
function HandleHarvesterTurnTask:endBackOffOnAbort()
    local mode = self.vehicle ~= nil and self.vehicle.ad ~= nil and self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if self.state == HandleHarvesterTurnTask.STATE_BACK_OFF_HARVESTER and mode ~= nil and mode.trackReverse ~= nil and mode.endTrackReverse ~= nil then
        mode:endTrackReverse()
    end
end
