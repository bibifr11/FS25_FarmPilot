-- ============================================================================================================
-- FarmPilot : PathFinderModulePark.lua
-- Complément de PathFinderModule : se ranger de côté (ensileuse, déchargeur plein).
-- Déchargeur plein sans sortie propre pendant que d'autres déchargeurs travaillent le champ : il se range pour
-- laisser passer le suivant (vers l'ensileuse). Courtes courbes en marche avant (comme le départ guidé) depuis la
-- vraie pose, ou depuis une pose quelques mètres en arrière sur sa propre trace (recul d'abord, puis avant). La
-- place est sur la bande coupée en laissant PARK_PASS_MIN_WIDTH m libres à côté du train entier, ou sur l'herbe à
-- côté du champ.
--
-- Exception stricte admise : l'herbe seulement pour se garer,
-- aucun obstacle sous le train entier, jamais un autre champ.
--
-- Règle : pas de place = on reste ; déjà hors du chemin = rien à faire.
--
-- Branché par ExitFieldTask.lua (findParkAside) ; getPassWidth aussi par CombineUnloaderMode.lua et
-- FieldParkModule.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester, full unloader without a clean way out while other unloaders work the field: move aside so the
-- next unloader can pass (to the harvester). Short forward curves (as the guided departure) from the real pose, or
-- from a pose a few meters back on its own track (reverse first, then forward: angle to leave the strip). The spot is
-- on the cut strip leaving PARK_PASS_MIN_WIDTH free beside the whole train, or on the grass beside the field (strict
-- exception: only to park, no obstacle under the whole train, never another field).
-- Returns waypoints and the track index to back off to first (nil: drive from here); nil, true when already out of
-- the way; nil when no spot
PathFinderModule.PARK_DISTANCES = {6, 10, 14, 18, 22, 26, 30}
PathFinderModule.PARK_LATERAL_MAX = 12 -- m sideways from the start line
PathFinderModule.PARK_LATERAL_STEP = 1
PathFinderModule.PARK_HEADING_MAX = 30
PathFinderModule.PARK_ANGLE_STEP = 15
PathFinderModule.PARK_HARVESTER_MIN_DISTANCE = 25 -- m between a parked full trailer and the harvester
PathFinderModule.PARK_PASS_MIN_WIDTH = 4 -- m free beside the parked train for another one to pass
PathFinderModule.PARK_MAX_CURVES = 40 -- per start pose
PathFinderModule.PARK_BACK_DISTANCES = {6, 10, 15, 20} -- m backed off along the own track before the forward curve
PathFinderModule.PARK_STRAIGHT = 10 -- m driven straight after the curve: the trailer lines up behind the tractor
PathFinderModule.PARK_FIELD_TOLERANCE = 0.5 -- m of the parked train that may stay on the field ground when on the grass

-- ------------------------------------------------------------------------------------------------------------
-- Emprise du train garé
-- ------------------------------------------------------------------------------------------------------------
-- footprint of a train whose tractor stands at x, z heading hx, hz: centre and half sizes
function PathFinderModule:getParkFootprint(x, z, hx, hz)
    local trainLength = math.max(AutoDrive.getTractorTrainLength(self.vehicle, true, false), 8)
    local halfW = self:getTrainWidth() / 2 + 0.5
    return x - hx * trainLength / 2, z - hz * trainLength / 2, halfW, trainLength / 2 + 0.5
end

-- free cut ground beside the whole train (m); a train standing entirely on the grass leaves the strip free
function PathFinderModule:getPassWidth(x, z, hx, hz)
    local cx, cz, halfW, halfL = self:getParkFootprint(x, z, hx, hz)
    if self:isFootprintOffField(cx, cz, hx, hz, halfW - PathFinderModule.PARK_FIELD_TOLERANCE, halfL) then
        return math.huge, true
    end
    return ADFieldPark.getPassWidth(cx, cz, hx, hz, halfW, halfL), false
end

-- samples every ~1 m across a footprint, edges included: fn(x, z) returns true to stop
function PathFinderModule.forEachFootprintSample(cx, cz, hx, hz, halfW, halfL, fn)
    local nl = math.max(1, math.ceil(halfL * 2))
    local nw = math.max(1, math.ceil(halfW * 2))
    for i = 0, nl do
        local l = -halfL + 2 * halfL * i / nl
        for j = 0, nw do
            local w = -halfW + 2 * halfW * j / nw
            if fn(cx + hx * l + hz * w, cz + hz * l - hx * w) then
                return true
            end
        end
    end
    return false
end

-- every 1 m sample of the footprint off the field ground (grass)
function PathFinderModule:isFootprintOffField(cx, cz, hx, hz, halfW, halfL)
    return not PathFinderModule.forEachFootprintSample(cx, cz, hx, hz, halfW, halfL, function(x, z)
        return PathFinderModule.getMapOnFieldAt(x, z)
    end)
end

-- the whole parked train: no obstacle (trees, walls, fences, vehicles), no other field, no crop
function PathFinderModule:isParkFootprintClear(x, z, hx, hz)
    local cx, cz, halfW, halfL = self:getParkFootprint(x, z, hx, hz)
    local bad = PathFinderModule.forEachFootprintSample(cx, cz, hx, hz, halfW, halfL, function(px, pz)
        local crop = PathFinderModule.getMapCropAt(px, pz)
        if crop ~= nil and crop ~= 0 then
            return true
        end
        -- another field
        return PathFinderModule.getMapOnFieldAt(px, pz) and not self:isFieldPositionAllowed(px, pz, true)
    end)
    if bad then
        return false
    end
    local module = self.vehicle.ad.trafficYieldModule
    if module ~= nil and module.overlapHit ~= nil then
        local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 0, cz)
        if module:overlapHit(cx, y + 2, cz, math.atan2(hx, hz), halfW, 1.5, halfL) then
            return false
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Recherche d'une place (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
-- one forward curve from a pose to a parking spot; waypoints or nil
function PathFinderModule:tryParkCurve(px, pz, heading, cand, radius)
    local hx, hz = math.sin(cand.heading), math.cos(cand.heading)
    local q0 = {px, -pz, AutoDrive.normalizeAngle(heading + math.pi + math.pi / 2)}
    local q1 = {cand.x, -cand.z, AutoDrive.normalizeAngle(cand.heading + math.pi + math.pi / 2)}
    self.dubins.outPath = {}
    if self.dubins:dubins_shortest_path(ADDubins.DubinsPath, q0, q1, radius) ~= ADDubins.EDUBOK
        or self.dubins:dubins_path_length(ADDubins.DubinsPath) > cand.d * 1.6 + 2 then
        return nil, false
    end
    if self.dubins:dubins_path_sample_many(ADDubins.DubinsPath, 1, self.dubins.createWayPoints) ~= ADDubins.EDUBOK or #self.dubins.outPath <= 2 then
        return nil, true
    end
    local path = self.dubins.outPath
    path[#path + 1] = {x = cand.x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cand.x, 1, cand.z), z = cand.z, t = q1[3]}
    -- then straight on to the stop: the trailer lines up behind the tractor (the spot is checked for a straight train)
    local straight = PathFinderModule.PARK_STRAIGHT
    for m = 1, straight do
        local x, z = cand.x + hx * m, cand.z + hz * m
        path[#path + 1] = {x = x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z), z = z, t = q1[3]}
    end
    if not self:isGuidedBandClear(path, radius, 0) then
        return nil, true
    end
    local cells = {}
    for i, wp in ipairs(path) do
        local cell = {x = i, z = 0, t = wp.t, height = self.vehicleMinHeight or 3}
        cell.worldPos = {x = wp.x, y = wp.y, z = wp.z}
        cell.incoming = cells[i - 5]
        cells[i] = cell
        if i > PathFinderModule.GUIDED_START_TOLERANCE + 1 and not self:isDriveableDubins(cell) then
            return nil, true
        end
    end
    local points = {}
    for i, wp in ipairs(path) do
        if i == 1 or i == #path or (i - 1) % PathFinderModule.GUIDED_POINT_SPACING == 0 then
            points[#points + 1] = {x = wp.x, y = wp.y, z = wp.z}
        end
    end
    return points, true
end

-- fromHere: after backing off along its track, a real spot is wanted (grass or side of the strip), from where
-- the train stands only, even if the lane beside it is already wide enough
function PathFinderModule:findParkAside(harvester, fromHere)
    if not self:isChopperWork() then
        return nil
    end
    local name = self:getLogName()
    self.trainHalfWidth = self.trainHalfWidth or (self:getTrainWidth() / 2 + PathFinderModule.FRUIT_CHECK_CORRIDOR_MARGIN)
    self:updateCropHalfWidth()
    local radius = self.realTurnRadius or self.minTurnRadius or 10
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local rx, _, rz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local savedGoing, savedCombine = self.goingToPipe, self.pipeCombine
    self.goingToPipe, self.pipeCombine = harvester ~= nil, harvester
    local here = self:getPassWidth(vx, vz, rx, rz)
    local hereNear = false
    if harvester ~= nil and harvester.components ~= nil then
        local hvx, _, hvz = getWorldTranslation(harvester.components[1].node)
        hereNear = MathUtil.vector2Length(vx - hvx, vz - hvz) < PathFinderModule.PARK_HARVESTER_MIN_DISTANCE
    end
    if not hereNear and (here == math.huge or not fromHere) and here >= PathFinderModule.PARK_PASS_MIN_WIDTH and not self:isGuidedStopInHarvesterWay(vx, vz, math.atan2(rx, rz)) then
        self.goingToPipe, self.pipeCombine = savedGoing, savedCombine
        print(string.format("[AD-Exit] %s: deja hors du passage (%s libres a cote), attente sur place", name, here == math.huge and "bande entiere" or string.format("%.1f m", here)))
        return nil, true
    end
    -- start poses: here, then a few meters back on the own track
    local poses = {{x = vx, z = vz, heading = math.atan2(rx, rz), back = 0}}
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    local track = mode ~= nil and mode.track or nil
    if track ~= nil and #track > 2 and not fromHere then
        local walked = MathUtil.vector2Length(track[#track].x - vx, track[#track].z - vz)
        local wanted = 1
        for k = #track - 1, 2, -1 do
            walked = walked + MathUtil.vector2Length(track[k + 1].x - track[k].x, track[k + 1].z - track[k].z)
            local d = PathFinderModule.PARK_BACK_DISTANCES[wanted]
            if d == nil then
                break
            end
            if walked >= d then
                local dx, dz = track[k].x - track[k - 1].x, track[k].z - track[k - 1].z
                if dx * dx + dz * dz > 0.01 then
                    poses[#poses + 1] = {x = track[k].x, z = track[k].z, heading = math.atan2(dx, dz), back = walked, index = k}
                end
                wanted = wanted + 1
            end
        end
    end
    self.parkOnGrass = true
    local inWay, narrow, blocked, checked = 0, 0, 0, 0
    local result, resultIndex, info = nil, nil, nil
    for _, pose in ipairs(poses) do
        local candidates = {}
        local fx, fz = math.sin(pose.heading), math.cos(pose.heading)
        for _, d in ipairs(PathFinderModule.PARK_DISTANCES) do
            -- spots d meters ahead, shifted sideways every meter (strips run along the border)
            for lateral = -PathFinderModule.PARK_LATERAL_MAX, PathFinderModule.PARK_LATERAL_MAX, PathFinderModule.PARK_LATERAL_STEP do
                local x, z = pose.x + fx * d + fz * lateral, pose.z + fz * d - fx * lateral
                for h = -PathFinderModule.PARK_HEADING_MAX, PathFinderModule.PARK_HEADING_MAX, PathFinderModule.PARK_ANGLE_STEP do
                    local endHeading = pose.heading + math.rad(h)
                    local hx, hz = math.sin(endHeading), math.cos(endHeading)
                    -- where the tractor stops, after the straight part
                    local sx, sz = x + hx * PathFinderModule.PARK_STRAIGHT, z + hz * PathFinderModule.PARK_STRAIGHT
                    -- a train standing on the grass is out of everybody's way (they all drive on the field)
                    local pass, onGrass = self:getPassWidth(sx, sz, hx, hz)
                    -- never next to the harvester, grass included: Courseplay would take the full trailer for its
                    -- unloader and wait for it (the whole train, tractor and trailer, kept away)
                    local nearHarvester = false
                    if harvester ~= nil and harvester.components ~= nil then
                        local hvx, _, hvz = getWorldTranslation(harvester.components[1].node)
                        local trainLength = math.max(AutoDrive.getTractorTrainLength(self.vehicle, true, false), 8)
                        for _, back in ipairs({0, trainLength / 2, trainLength}) do
                            if MathUtil.vector2Length(sx - hx * back - hvx, sz - hz * back - hvz) < PathFinderModule.PARK_HARVESTER_MIN_DISTANCE then
                                nearHarvester = true
                            end
                        end
                    end
                    if nearHarvester or (not onGrass and self:isGuidedStopInHarvesterWay(sx, sz, endHeading)) then
                        inWay = inWay + 1
                    else
                        if pass < PathFinderModule.PARK_PASS_MIN_WIDTH then
                            narrow = narrow + 1
                        else
                            -- grass first (whole strip left free), then the widest lane, short manoeuvres
                            local score = (onGrass and 100 or math.min(pass, 20)) - d * 0.05 - math.abs(h) * 0.01 - pose.back * 0.2
                            candidates[#candidates + 1] = {x = x, z = z, stopX = sx, stopZ = sz, d = d, heading = endHeading, score = score, onGrass = onGrass, pass = pass}
                        end
                    end
                end
            end
        end
        table.sort(candidates, function(c1, c2) return c1.score > c2.score end)
        local checkedHere = 0
        for _, cand in ipairs(candidates) do
            if checkedHere >= PathFinderModule.PARK_MAX_CURVES then
                break
            end
            local points, tried = nil, false
            -- the whole parked train (obstacles, crop, other field), only for the spots actually tried
            if self:isParkFootprintClear(cand.stopX, cand.stopZ, math.sin(cand.heading), math.cos(cand.heading)) then
                points, tried = self:tryParkCurve(pose.x, pose.z, pose.heading, cand, radius)
            else
                blocked = blocked + 1
            end
            if tried then
                checked = checked + 1
                checkedHere = checkedHere + 1
            end
            if points ~= nil then
                result, resultIndex = points, pose.index
                info = string.format("%s, recul %.0f m puis %.0f m en avant (dont %d m droit) vers %.0f,%.0f", cand.onGrass and "sur l'herbe" or string.format("%.1f m libres a cote", cand.pass), pose.back, cand.d + PathFinderModule.PARK_STRAIGHT, PathFinderModule.PARK_STRAIGHT, cand.stopX, cand.stopZ)
                break
            end
        end
        if result ~= nil then
            break
        end
    end
    self.parkOnGrass = false
    self.goingToPipe, self.pipeCombine = savedGoing, savedCombine
    if result ~= nil then
        print(string.format("[AD-Exit] %s: se range pour laisser passer : %s (%d courbes)", name, info, checked))
        return result, false, resultIndex
    end
    print(string.format("[AD-Exit] %s: aucune place pour se ranger (%d dans le passage de l'ensileuse, %d trop etroites, %d obstacle/culture/autre champ, %d courbes)", name, inWay, narrow, blocked, checked))
    return nil
end
