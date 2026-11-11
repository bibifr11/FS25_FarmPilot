-- ============================================================================================================
-- FarmPilot : CombineUnloaderModeTracks.lua
-- Complément de CombineUnloaderMode : les traces au champ, pour l'ENSILEUSE (benne qui roule à côté). Ne concerne
-- pas la moissonneuse.
--
-- - traces de la benne : le sol où elle a roulé en avant dans le champ (donc sans culture), pour reculer dedans et
--   laisser passer l'ensileuse ou une autre benne (ExitFieldTask, CatchCombinePipeTask, FollowCombineTask,
--   HandleHarvesterTurnTask) ;
-- - trace de l'ensileuse : le sol où elle a roulé (son demi-tour Courseplay sort du champ en bout de rang) : la
--   ligne de poursuite et le demi-tour peuvent y passer ;
-- - trace gardée pour les bennes suivantes : le chemin de la benne jusqu'à l'ensileuse, propre et praticable.
--
-- Historique : 23/10 (poteau électrique : un petit bout hors champ garde
-- les traces), 24/10 (au moins 15 m de recul ; 11:57 points de trace devant le tracteur après un recul), 25/10
-- 08:03 (point de trace devant le tracteur : pas de recul), 25/10 14:21 (trace gardée seulement si elle finit à
-- l'ensileuse), 25/10 22:34 (Puma reculé 6 fois dans une courbe le long du maïs : pas de recul avec de la culture
-- à côté de la trace, arrêt si la culture passe sous l'arrière de la remorque, 25 m au plus sans se rapprocher).
--
-- Branché par : CombineUnloaderMode.lua, deux lignes dans monitorTasks (enregistrement) et une dans getNextTask
-- (trace gardée pour les suivantes) ; les reculs sont lancés par les tâches citées plus haut.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester: the ground this unloader drove on in the field (driven forward, so free of crop), newest last.
-- It can back off along it to let the harvester or another unloader pass
CombineUnloaderMode.TRACK_STEP = 3
CombineUnloaderMode.TRACK_MAX_POINTS = 80
CombineUnloaderMode.TRACK_LOOK_BEHIND = 5       -- m between the reversing node and the point it aims at (25/10 22:34: 6 cut the inside of the curve into the maize)
CombineUnloaderMode.TRACK_STOP_DISTANCE = 2.5   -- m between the tractor and its parking point to stop
CombineUnloaderMode.TRACK_BLOCKED_TIME = 8000   -- ms without moving while reversing: something behind, stop there
CombineUnloaderMode.TRACK_TIMEOUT = 150000

CombineUnloaderMode.TRACK_OFF_FIELD_KEEP = 15 -- m off the field before the track is wiped

-- ground the harvester drove on (sim 24/10: its CP turn leaves the field at the row end, the tractor behind it
-- stopped on "hors du champ"): the chase line may cross the field border there
CombineUnloaderMode.COMBINE_TRAIL_STEP = 2
CombineUnloaderMode.COMBINE_TRAIL_MAX_POINTS = 60
CombineUnloaderMode.COMBINE_TRAIL_RADIUS = 2.5

CombineUnloaderMode.LANE_KEEP_DISTANCE = 25 -- m: the way of an unloader is kept for the next ones only when it ends this close to the harvester (25/10 14:21)

-- ------------------------------------------------------------------------------------------------------------
-- Trace de l'ensileuse
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:recordCombineTrail()
    local combine = self.combine
    if combine == nil or combine.components == nil or combine.ad == nil or not combine.ad.isChopper then
        self.combineTrail = nil
        return
    end
    if self.combineTrail == nil or self.combineTrail.combine ~= combine then
        self.combineTrail = {combine = combine, points = {}}
    end
    local points = self.combineTrail.points
    local x, _, z = getWorldTranslation(combine.components[1].node)
    local last = points[#points]
    if last == nil or MathUtil.vector2Length(x - last.x, z - last.z) >= CombineUnloaderMode.COMBINE_TRAIL_STEP then
        table.insert(points, {x = x, z = z})
        while #points > CombineUnloaderMode.COMBINE_TRAIL_MAX_POINTS do
            table.remove(points, 1)
        end
    end
end

function CombineUnloaderMode:isOnCombineTrail(x, z, radius)
    if self.combineTrail == nil then
        return false
    end
    radius = radius or CombineUnloaderMode.COMBINE_TRAIL_RADIUS
    for _, p in ipairs(self.combineTrail.points) do
        if MathUtil.vector2Length(x - p.x, z - p.z) <= radius then
            return true
        end
    end
    return false
end

-- the harvester's trail from the point closest to (x, z) up to keepBehind m before its newest point: the way it
-- drove through its own U-turn. nil when the start is not on the trail or too little is left
function CombineUnloaderMode:getCombineTrailFrom(x, z, maxStartDistance, keepBehind)
    local points = self.combineTrail ~= nil and self.combineTrail.points or nil
    if points == nil or #points < 5 then
        return nil
    end
    local first, best = nil, math.huge
    for i, p in ipairs(points) do
        local d = MathUtil.vector2Length(x - p.x, z - p.z)
        if d < best then
            first, best = i, d
        end
    end
    if first == nil or best > maxStartDistance then
        return nil, string.format("tracteur a %.0f m de la trace", best)
    end
    if best < 3 and first < #points then
        -- standing on it: aim at the next point, never back at the one under the tractor
        first = first + 1
    end
    local last, behind = #points, 0
    while last > first and behind < keepBehind do
        behind = behind + MathUtil.vector2Length(points[last].x - points[last - 1].x, points[last].z - points[last - 1].z)
        last = last - 1
    end
    if last - first < 3 then
        return nil, "trace trop courte devant moi"
    end
    local out = {}
    for i = first, last do
        local p = points[i]
        table.insert(out, {x = p.x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p.x, 1, p.z), z = p.z})
    end
    return out
end

-- ------------------------------------------------------------------------------------------------------------
-- Traces de la benne : enregistrement
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:recordTrack()
    if self.trackReverse ~= nil then
        -- backing off along the track: its indices must not move
        return
    end
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    if not AutoDrive.isChopperUnloading(self.vehicle) or not AutoDrive.checkIsOnField(x, y, z) then
        -- a small patch off the field (power pole, 23/10) keeps the track: only leaving the field wipes it
        local last = self.track ~= nil and self.track[#self.track] or nil
        if last ~= nil and not AutoDrive.checkIsOnField(x, y, z) and MathUtil.vector2Length(x - last.x, z - last.z) > CombineUnloaderMode.TRACK_OFF_FIELD_KEEP then
            self.track = {}
        end
        return
    end
    self.track = self.track or {}
    local speed = (self.vehicle.lastSpeedReal or 0) * (self.vehicle.movingDirection or 1)
    if speed <= 0.0005 then
        return
    end
    local last = self.track[#self.track]
    if last == nil or MathUtil.vector2Length(x - last.x, z - last.z) >= CombineUnloaderMode.TRACK_STEP then
        table.insert(self.track, {x = x, y = y, z = z})
        while #self.track > CombineUnloaderMode.TRACK_MAX_POINTS do
            table.remove(self.track, 1)
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Recul dans les traces pour laisser passer
-- ------------------------------------------------------------------------------------------------------------
-- point of the track where the tractor can stand with room beside it for another trailer to pass, out of the
-- harvester's way, the whole train on the track; walking back from the newest point, up to maxDistance
-- 24/10 11:57: after a reverse the newest track points lie AHEAD of the tractor. Distances back along the
-- track are counted from the point closest to the tractor: returns per index the m behind the tractor, and that index
CombineUnloaderMode.TRACK_REVERSE_MIN = 15 -- m at least when backing off to get free (24/10)
-- 25/10 22:34 (Puma backed 6 times along a track curving along the maize, the trailer ended in the crop):
CombineUnloaderMode.TRACK_CROP_MARGIN = 0.3        -- m beyond the train half width checked for standing crop along the track
CombineUnloaderMode.TRACK_CROP_STEP = 1.5          -- m between the crop samples along the track
CombineUnloaderMode.TRACK_CROP_CHECK_INTERVAL = 400 -- ms between the crop checks under the rear of the train while backing
CombineUnloaderMode.TRACK_REVERSE_TOTAL_MAX = 25   -- m backed off in a row without getting closer to the harvester: no more
CombineUnloaderMode.TRACK_REVERSE_PROGRESS = 5     -- m closer to the harvester than at the first back-off: the count restarts

-- standing crop at x, z (map reading, isolated plants ignored), nil when nothing can be read
function CombineUnloaderMode.cropAt(x, z)
    if PathFinderModule == nil then
        return nil
    end
    if PathFinderModule.getMapCropAt ~= nil then
        local ok, crop = FarmPilotCall(PathFinderModule.getMapCropAt, x, z)
        if ok then
            return crop
        end
    end
    if PathFinderModule.readCropAt ~= nil then
        local ok, crop = FarmPilotCall(PathFinderModule.readCropAt, x, z)
        if ok then
            return crop
        end
    end
    return nil
end

-- the track between two of its points (newer index first) runs clear of standing crop over the train width:
-- true, or false and the first point with crop beside it
function CombineUnloaderMode:isTrackStretchCropFree(fromIndex, toIndex)
    local track = self.track
    if track == nil or fromIndex == nil or toIndex == nil or fromIndex <= toIndex then
        return true
    end
    local halfW = self.vehicle.ad.pathFinderModule:getTrainWidth() / 2 + CombineUnloaderMode.TRACK_CROP_MARGIN
    for i = fromIndex, toIndex + 1, -1 do
        local a, b = track[i], track[i - 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 0.1 then
            dx, dz = dx / l, dz / l
            local nx, nz = -dz, dx
            local d = 0
            while d <= l do
                local px, pz = a.x + dx * d, a.z + dz * d
                for _, side in ipairs({-1, 0, 1}) do
                    local crop = CombineUnloaderMode.cropAt(px + nx * halfW * side, pz + nz * halfW * side)
                    if crop ~= nil and crop ~= 0 then
                        return false, px + nx * halfW * side, pz + nz * halfW * side
                    end
                end
                d = d + CombineUnloaderMode.TRACK_CROP_STEP
            end
        end
    end
    return true
end

-- standing crop under the rear of the train while backing toward tx, tz: the trailer left the track (inside of a curve)
function CombineUnloaderMode:isTrainRearInCrop(tx, tz)
    local reverseNode = self.vehicle.ad.specialDrivingModule:getReverseNode()
    if reverseNode == nil then
        return false
    end
    local rx, _, rz = getWorldTranslation(reverseNode)
    local dx, dz = tx - rx, tz - rz
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 0.1 then
        return false
    end
    dx, dz = dx / l, dz / l
    local nx, nz = -dz, dx
    local halfW = self.vehicle.ad.pathFinderModule:getTrainWidth() / 2
    -- the rear corners of the trailer, 1 m behind the reversing node
    for _, side in ipairs({-1, 1}) do
        local px, pz = rx + dx * 1 + nx * halfW * side, rz + dz * 1 + nz * halfW * side
        local crop = CombineUnloaderMode.cropAt(px, pz)
        if crop ~= nil and crop ~= 0 then
            return true, px, pz
        end
    end
    return false
end

-- m backed off along the track in a row (several back-offs without getting closer to the harvester than at the first
-- one): more than TRACK_REVERSE_TOTAL_MAX and a new back-off is refused (the same curve backed into 6 times, 22:34)
function CombineUnloaderMode:trackReverseAllowed(harvester, distance)
    local d = nil
    if harvester ~= nil and harvester.components ~= nil then
        d = AutoDrive.getDistanceBetween(self.vehicle, harvester)
    end
    local run = self.trackReverseRun
    if run == nil or d == nil or run.ref == nil or d < run.ref - CombineUnloaderMode.TRACK_REVERSE_PROGRESS then
        run = {ref = d, total = 0}
        self.trackReverseRun = run
    end
    if run.total + distance > CombineUnloaderMode.TRACK_REVERSE_TOTAL_MAX then
        return false, run.total
    end
    run.total = run.total + distance
    return true, run.total
end

function CombineUnloaderMode:getTrackBehind()
    local track = self.track
    if track == nil or #track < 2 then
        return nil, nil
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local closest, best = #track, math.huge
    for i = #track, 1, -1 do
        local d = MathUtil.vector2Length(track[i].x - x, track[i].z - z)
        if d < best then
            best, closest = d, i
        end
    end
    local behind = {}
    behind[closest] = best
    for k = closest - 1, 1, -1 do
        behind[k] = behind[k + 1] + MathUtil.vector2Length(track[k + 1].x - track[k].x, track[k + 1].z - track[k].z)
    end
    return behind, closest
end

-- track index about distance m behind the tractor (the oldest one when shorter), nil without track
function CombineUnloaderMode:getTrackIndexBehind(distance)
    local behind, closest = self:getTrackBehind()
    if behind == nil then
        return nil, 0
    end
    for k = closest, 1, -1 do
        if behind[k] >= distance then
            return k, behind[k]
        end
    end
    return 1, behind[1]
end

function CombineUnloaderMode:findTrackParkIndex(harvester, maxDistance)
    local track = self.track
    if track == nil or #track < 3 then
        return nil, "pas de traces"
    end
    local pf = self.vehicle.ad.pathFinderModule
    local halfW = pf:getTrainWidth() / 2 + 0.5
    local trainLength = math.max(AutoDrive.getTractorTrainLength(self.vehicle, true, false), 8)
    local halfL = trainLength / 2 + 0.5
    -- distance from each point back to the oldest one: the train must stand on the track
    local fromStart = {0}
    for i = 2, #track do
        fromStart[i] = fromStart[i - 1] + MathUtil.vector2Length(track[i].x - track[i - 1].x, track[i].z - track[i - 1].z)
    end
    local behind, closest = self:getTrackBehind()
    local fallback = nil
    for k = math.min(closest, #track - 1), 2, -1 do
        local walked = behind[k]
        if walked > maxDistance then
            if fallback ~= nil then
                return fallback, behind[fallback]
            end
            return nil, string.format("rien sur %.0f m de traces", maxDistance)
        end
        if fromStart[k] >= trainLength then
            local dx, dz = track[k].x - track[k - 1].x, track[k].z - track[k - 1].z
            local l = math.sqrt(dx * dx + dz * dz)
            if l > 0.1 then
                dx, dz = dx / l, dz / l
                local cx, cz = track[k].x - dx * trainLength / 2, track[k].z - dz * trainLength / 2
                if ADFieldPark.getPassWidth(cx, cz, dx, dz, halfW, halfL) >= ADFieldPark.PASS_MIN_WIDTH
                    and not ADFieldPark.isInHarvesterWay(harvester, cx, cz, halfW, halfL) then
                    -- 24/10: a bit more room when backing off, at least TRACK_REVERSE_MIN
                    if walked >= CombineUnloaderMode.TRACK_REVERSE_MIN then
                        return k, walked
                    end
                    fallback = fallback or k
                end
            end
        end
    end
    if fallback ~= nil then
        return fallback, behind[fallback]
    end
    return nil, "aucune place sur les traces"
end

-- backs off along the track to its parking point. Returns true when started
function CombineUnloaderMode:startTrackReverse(harvester, maxDistance, parkIndex)
    local name = tostring(self.vehicle:getName())
    local k, info = parkIndex, nil
    if k ~= nil and self.track ~= nil and self.track[k] ~= nil then
        local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
        info = MathUtil.vector2Length(self.track[k].x - x, self.track[k].z - z)
    else
        k, info = self:findTrackParkIndex(harvester, maxDistance)
    end
    if k == nil then
        print(string.format("[AD-Exit] %s: recul dans les traces impossible (%s)", name, tostring(info)))
        return false
    end
    local reverseNode = self.vehicle.ad.specialDrivingModule:getReverseNode()
    if reverseNode == nil then
        print(string.format("[AD-Exit] %s: recul dans les traces impossible (pas de point de recul)", name))
        return false
    end
    -- the reversing node aims at the track point closest to it, then further back
    local rx, _, rz = getWorldTranslation(reverseNode)
    local j, best = #self.track, math.huge
    for i = #self.track, 1, -1 do
        local d = MathUtil.vector2Length(self.track[i].x - rx, self.track[i].z - rz)
        if d < best then
            best, j = d, i
        end
    end
    -- 25/10 08:03: after a reverse and a new approach along the same line, older track points lie ahead of
    -- the tractor: a parking point ahead cannot be reached backwards
    local vx, vy, vz = getWorldTranslation(self.vehicle.components[1].node)
    local _, _, parkAhead = AutoDrive.worldToLocal(self.vehicle, self.track[k].x, self.track[k].y or vy, self.track[k].z)
    if parkAhead > 0 then
        print(string.format("[AD-Exit] %s: recul dans les traces impossible (point de trace %.0f m devant moi)", name, parkAhead))
        return false
    end
    -- 25/10 22:34: the track may hug the crop (recorded 0.5 m from the maize): backing along it the trailer cuts
    -- the inside of each curve into the crop. No back-off along a track with crop within the train width
    local cropFree, cropX, cropZ = self:isTrackStretchCropFree(j, k)
    if not cropFree then
        print(string.format("[AD-Exit] %s: recul dans les traces impossible (culture a cote de la trace vers %.0f,%.0f, la remorque y entrerait)", name, cropX, cropZ))
        return false
    end
    local allowed, total = self:trackReverseAllowed(harvester, info)
    if not allowed then
        print(string.format("[AD-Exit] %s: recul dans les traces refuse, deja %.0f m recules sans me rapprocher de l'ensileuse (%d m au plus)", name, total, CombineUnloaderMode.TRACK_REVERSE_TOTAL_MAX))
        return false
    end
    self.trackReverse = {park = k, target = j, time = 0, stillTime = 0, minDistance = math.huge, sx = vx, sz = vz, cropCheck = 0}
    self.trackReverseMoved = 0
    print(string.format("[AD-Exit] %s: recul dans ses traces sur %.0f m pour laisser passer", name, info))
    return true
end

-- "running", "done" or "blocked"
function CombineUnloaderMode:updateTrackReverse(dt)
    local tr = self.trackReverse
    local sdm = self.vehicle.ad.specialDrivingModule
    if tr == nil or self.track == nil then
        return "done"
    end
    local name = tostring(self.vehicle:getName())
    local park = self.track[tr.park]
    if park == nil or (tr.target ~= nil and self.track[tr.target] == nil) then
        print(string.format("[AD-Exit] %s: traces perdues pendant le recul, arret", name))
        self:endTrackReverse()
        sdm:stopVehicle()
        sdm:update(dt)
        return "blocked"
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    if tr.sx ~= nil then
        self.trackReverseMoved = MathUtil.vector2Length(x - tr.sx, z - tr.sz)
    end
    local toPark = MathUtil.vector2Length(park.x - x, park.z - z)
    tr.minDistance = math.min(tr.minDistance, toPark)
    if toPark < CombineUnloaderMode.TRACK_STOP_DISTANCE or (tr.minDistance < 6 and toPark > tr.minDistance + 1) then
        print(string.format("[AD-Exit] %s: rangee dans ses traces, la voie est libre a cote", name))
        self:endTrackReverse()
        sdm:stopVehicle()
        sdm:update(dt)
        return "done"
    end
    tr.time = tr.time + dt
    if math.abs(self.vehicle.lastSpeedReal or 0) < 0.0003 then
        tr.stillTime = tr.stillTime + dt
    else
        tr.stillTime = 0
    end
    if tr.stillTime > CombineUnloaderMode.TRACK_BLOCKED_TIME or tr.time > CombineUnloaderMode.TRACK_TIMEOUT then
        print(string.format("[AD-Exit] %s: recul dans les traces arrete (%s), %.0f m avant la place, %.0f m recules", name, tr.stillTime > CombineUnloaderMode.TRACK_BLOCKED_TIME and "quelque chose derriere" or "trop long", toPark, self.trackReverseMoved or 0))
        self:endTrackReverse()
        sdm:stopVehicle()
        sdm:update(dt)
        return "blocked"
    end
    local reverseNode = sdm:getReverseNode()
    if reverseNode == nil then
        self:endTrackReverse()
        return "blocked"
    end
    local rx, _, rz = getWorldTranslation(reverseNode)
    while tr.target > 1 and MathUtil.vector2Length(self.track[tr.target].x - rx, self.track[tr.target].z - rz) < CombineUnloaderMode.TRACK_LOOK_BEHIND do
        tr.target = tr.target - 1
    end
    local t = self.track[tr.target]
    -- 25/10 22:34: the trailer leaves the track on the inside of a curve: standing crop under its rear ends the back-off
    tr.cropCheck = (tr.cropCheck or 0) + dt
    if tr.cropCheck >= CombineUnloaderMode.TRACK_CROP_CHECK_INTERVAL then
        tr.cropCheck = 0
        local inCrop, cropX, cropZ = self:isTrainRearInCrop(t.x, t.z)
        if inCrop then
            print(string.format("[AD-Exit] %s: recul dans les traces arrete, culture sous l'arriere de la remorque vers %.0f,%.0f, %.0f m recules", name, cropX, cropZ, self.trackReverseMoved or 0))
            self:endTrackReverse()
            sdm:stopVehicle()
            sdm:update(dt)
            return "blocked"
        end
    end
    sdm:reverseToTargetLocation(dt, {x = t.x, y = t.y, z = t.z}, 6)
    return "running"
end

-- end of a track reverse: the points newer than the one the tractor stands at now lie ahead of it, they are dropped
-- (25/10 08:03: kept, a later back-off could aim at a point ahead and never move)
function CombineUnloaderMode:endTrackReverse()
    self.trackReverse = nil
    local track = self.track
    if track == nil or #track < 2 then
        return
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local closest, best = #track, math.huge
    for i = #track, 1, -1 do
        local d = MathUtil.vector2Length(track[i].x - x, track[i].z - z)
        if d < best then
            best, closest = d, i
        end
    end
    for i = #track, closest + 1, -1 do
        table.remove(track, i)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Trace gardée pour les bennes suivantes (accroche dans getNextTask, arrivée à l'ensileuse)
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:keepLaneForNextUnloaders()
    -- forage harvester: the way this unloader came is clean and drivable, the next ones reuse it
    if self.combine ~= nil and self.combine.ad ~= nil and self.combine.ad.isChopper and self.track ~= nil and #self.track >= 5 then
        -- 25/10 14:21 (6205 TTV: its own loops, U-turn and 43 m reverse kept as "the way to the harvester",
        -- ending 56 m aside of it, then followed in circles): kept only when it really ends at the harvester
        local laneEnd = AutoDrive.getDistanceBetween(self.vehicle, self.combine)
        if laneEnd <= CombineUnloaderMode.LANE_KEEP_DISTANCE then
            local lane = {}
            for i, p in ipairs(self.track) do
                lane[i] = {x = p.x, y = p.y, z = p.z}
            end
            self.combine.ad.sharedLane = {points = lane, time = g_time}
            print(string.format("[AD-Fin] %s: trace jusqu'a l'ensileuse gardee pour les suivants (%d points)", tostring(self.vehicle:getName()), #lane))
        else
            print(string.format("[AD-Fin] %s: trace non gardee pour les suivants (elle finit a %.0f m de l'ensileuse)", tostring(self.vehicle:getName()), laneEnd))
        end
    end
end
