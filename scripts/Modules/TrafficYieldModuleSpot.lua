-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleSpot.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : chercher une place au bord de la route, le long de
-- mon trajet (virages suivis).
--
-- Règle :
-- - un trajet parallèle au trajet AutoDrive, décalé du côté de conduite (getSides) assez pour que l'autre passe
--   (largeur de toute sa file, S7) ; décalage progressif (smoothstep), puis ligne droite pour aligner la remorque ;
-- - terrain et obstacles contrôlés sur tout le trajet (isPathFree, TrafficYieldModuleObstacles.lua) ; place en herbe
--   d'abord, sinon en partie sur un champ de ce côté ;
-- - la remorque suit son attelage (elle coupe le virage) : là où le tracteur s'arrête elle doit être hors de la route,
--   le trajet s'allonge de TOW_EXTRA m au plus, sinon la place est refusée (30/10) ;
-- - place gardée seulement si tout l'autre attelage (et sa file) passe à côté, et jamais à moins de SPOT_MOUTH_CLEAR m
--   de l'entrée d'un chemin unique (S7, 28/10) ; croisement prévu dans le chemin : la place doit y être (28/10) ;
-- - toutes les raisons de refus d'une recherche dans une seule ligne du journal (28/10).
--
-- Branché par : updateYielderApproach, searchCrossingSpot, searchParkingSpot (TrafficYieldModuleParker.lua),
-- resolveStuckInMouth (searchSpotBehind).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Trajet parallèle à la route
-- ------------------------------------------------------------------------------------------------------------
-- builds a path parallel to the route, starting at route index 'startIndex' (point sx, sz on the route):
-- the lateral offset grows smoothly from 0 to 'lateral' over 'swerve' metres, then stays constant.
-- One point every PATH_STEP metres, 'length' metres long. Each point: x, z, dirX, dirZ (road direction), s, offset
function ADTrafficYieldModule.buildOffsetPath(wayPoints, startIndex, lateral, swerve, length)
    local step = ADTrafficYieldModule.PATH_STEP
    local points = {}
    local s = 0
    local index = startIndex
    local ax, az = wayPoints[index].x, wayPoints[index].z
    local nextS = 0
    while index < #wayPoints and s <= length do
        local b = wayPoints[index + 1]
        local segLength = MathUtil.vector2Length(b.x - ax, b.z - az)
        if segLength > 0.01 then
            local dx, dz = (b.x - ax) / segLength, (b.z - az) / segLength
            while nextS <= s + segLength and nextS <= length do
                local t = nextS - s
                local px, pz = ax + dx * t, az + dz * t
                local ramp = math.min(1, nextS / swerve)
                ramp = ramp * ramp * (3 - 2 * ramp) -- smoothstep: soft leaving of the road
                local offset = lateral * ramp
                -- GIANTS local +x (left) of the road direction is (dz, -dx)
                table.insert(points, {x = px + dz * offset, z = pz - dx * offset, dirX = dx, dirZ = dz, s = nextS, offset = offset})
                nextS = nextS + step
            end
            s = s + segLength
        end
        ax, az = b.x, b.z
        index = index + 1
    end
    if #points < 2 or points[#points].s < length - step then
        return nil -- route too short
    end
    return points
end

-- point of the path at 's' (interpolated; before its start / after its end along the first / last road direction)
function ADTrafficYieldModule.pathPointAt(path, s)
    local n = #path
    local first, last = path[1], path[n]
    if s <= first.s then
        return first.x + first.dirX * (s - first.s), first.z + first.dirZ * (s - first.s)
    elseif s >= last.s then
        return last.x + last.dirX * (s - last.s), last.z + last.dirZ * (s - last.s)
    end
    local step = path[2].s - first.s
    local k = math.max(1, math.min(n - 1, math.floor((s - first.s) / step) + 1))
    while k > 1 and path[k].s > s do
        k = k - 1
    end
    while k < n - 1 and path[k + 1].s < s do
        k = k + 1
    end
    local a, b = path[k], path[k + 1]
    local t = (b.s - a.s) > 0.001 and (s - a.s) / (b.s - a.s) or 0
    return a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
end

-- the road under a roadside path (offset taken off), 30 m more before its start; kept in the path
function ADTrafficYieldModule.getPathRoad(path)
    if path.road == nil then
        local first = path[1]
        local road = {{x = first.x - first.dirX * 30 - first.dirZ * first.offset, z = first.z - first.dirZ * 30 + first.dirX * first.offset}}
        for _, p in ipairs(path) do
            table.insert(road, {x = p.x - p.dirZ * p.offset, z = p.z + p.dirX * p.offset})
        end
        path.road = road
    end
    return path.road
end

-- a point lies off the road, on the full offset of the path
function ADTrafficYieldModule.isOffRoad(path, x, z)
    local full = math.abs(path[#path].offset)
    return ADTrafficYieldModule.distanceToPolyline(ADTrafficYieldModule.getPathRoad(path), x, z) >= full - ADTrafficYieldModule.TOW_ROAD_TOLERANCE
end

-- the path up to 'length' (points after it dropped)
function ADTrafficYieldModule.trimPath(path, length)
    local trimmed = {}
    for _, p in ipairs(path) do
        if p.s > length then
            break
        end
        table.insert(trimmed, p)
    end
    return #trimmed >= 2 and trimmed or path
end

function ADTrafficYieldModule.makePathSpot(path, wp, distance, sideName, lat, swerve, runOut, onField, y)
    local function pointAt(s)
        local best = path[#path]
        for _, p in ipairs(path) do
            if p.s >= s then
                best = p
                break
            end
        end
        return best
    end
    local entry = path[1]
    local swervePoint = pointAt(swerve)
    local finalPoint = pointAt(swerve + runOut)
    local last = path[#path]
    return {
        path = path,
        finalS = swerve + runOut,
        entryX = entry.x, entryZ = entry.z, entryDistance = distance,
        onField = onField,
        side = sideName,
        forward = swerve,
        lateral = lat,
        lateralAbs = math.abs(lat),
        x = swervePoint.x, y = y, z = swervePoint.z,
        finalX = finalPoint.x, finalZ = finalPoint.z,
        aimX = last.x, aimZ = last.z,
        originX = wp.x, originZ = wp.z,
        dirX = finalPoint.dirX, dirZ = finalPoint.dirZ
    }
end

-- ------------------------------------------------------------------------------------------------------------
-- La remorque suit son attelage
-- ------------------------------------------------------------------------------------------------------------
-- towed units follow the hitch (tractrix), the tractor drives on the path. Returns the first tractor 's' (minS at least,
-- untilS at most) where the towed rear and its centre are off the road, with the towed points there (nil: never)
function ADTrafficYieldModule.simulateTowed(path, hitchBack, towedLength, minS, untilS)
    local step = ADTrafficYieldModule.TOW_STEP
    local axleDist = towedLength * 0.7
    local function tractorAt(s)
        local x, z = ADTrafficYieldModule.pathPointAt(path, s)
        local bx, bz = ADTrafficYieldModule.pathPointAt(path, s - 1)
        local dx, dz = x - bx, z - bz
        local l = math.max(0.001, MathUtil.vector2Length(dx, dz))
        return x, z, dx / l, dz / l
    end
    -- the train comes straight along the road
    local x, z, dx, dz = tractorAt(0)
    local hx, hz = x - dx * hitchBack, z - dz * hitchBack
    local ax, az = hx - dx * axleDist, hz - dz * axleDist
    local s = 0
    while s <= untilS do
        s = s + step
        x, z, dx, dz = tractorAt(s)
        hx, hz = x - dx * hitchBack, z - dz * hitchBack
        local ux, uz = ax - hx, az - hz
        local l = math.max(0.001, MathUtil.vector2Length(ux, uz))
        ux, uz = ux / l, uz / l
        ax, az = hx + ux * axleDist, hz + uz * axleDist
        if s >= minS then
            local rx, rz = hx + ux * towedLength, hz + uz * towedLength
            local mx, mz = hx + ux * towedLength / 2, hz + uz * towedLength / 2
            if ADTrafficYieldModule.isOffRoad(path, rx, rz) and ADTrafficYieldModule.isOffRoad(path, mx, mz) then
                return s, {{x = hx, z = hz}, {x = mx, z = mz}, {x = rx, z = rz}}
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Recherche le long du trajet (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
-- the whole stretch on the driving side (see getSides)
function ADTrafficYieldModule:searchSpotBySides(maxAhead, keepClearOfPartner, fromIndex)
    for _, side in ipairs(ADTrafficYieldModule.getSides()) do
        local spot = self:searchSpotAlongRoute(maxAhead, side.name, keepClearOfPartner, fromIndex)
        if spot ~= nil then
            return spot
        end
    end
    return nil
end

-- searches, along my route ahead, a point where I can leave the road and follow a path parallel to the
-- route on the roadside, before reaching maxAhead metres. sideFilter: "right" / "left" / nil
-- keepClearOfPartner: the partner is still driving towards me (early plan), the end of the path must stay
-- out of its way, braking distance included (otherwise I would stop half way with my trailer on the road)
-- fromIndex: search from that route point instead of my position (a place I would reach by reversing).
-- 28/10: for a crossing planned in a two-way track (spotTwoWayOnly) the spot must be in the track itself
function ADTrafficYieldModule:searchSpotAlongRoute(maxAhead, sideFilter, keepClearOfPartner, fromIndex)
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return nil
    end
    if fromIndex ~= nil and wayPoints[fromIndex] == nil then
        return nil
    end
    local startIndex = fromIndex or currentIndex
    local twoWayOnly = self.spotTwoWayOnly or (self.plan ~= nil and self.plan.spotTwoWayOnly)
    local parker = self.vehicle
    local reverser = self.partner
    local parkerWidth = ADTrafficYieldModule.getWidth(parker)
    local reverserWidth = ADTrafficYieldModule.getWidth(reverser)
    -- 28/10 (S7): far enough aside for the widest vehicle of the oncoming queue
    if reverser ~= nil then
        for _, v in ipairs(ADTrafficYieldModule.getQueueBehind(reverser, parker)) do
            reverserWidth = math.max(reverserWidth, ADTrafficYieldModule.getWidth(v))
        end
    end
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(parker)
    local parkerFront, parkerRear = ADTrafficYieldModule.getTrainExtents(parker)
    local margin = AutoDrive.getSetting("trafficYieldMargin") or ADTrafficYieldModule.LATERAL_MARGIN
    local baseLateral = (parkerWidth + reverserWidth) / 2 + margin
    local trailLength = math.max(0, parkerRear - tractorLength / 2)
    local towedLength = ADTrafficYieldModule.getTowedLength(parker)
    local runOut = ADTrafficYieldModule.getRunOut(trailLength)
    local swerve = math.max(8, tractorLength * 1.5, baseLateral * 2.5, trailLength)
    -- the tractor stops at swerve + runOut; the path continues a bit for the alignment and the aim point
    local pathLength = swerve + runOut + ADTrafficYieldModule.PATH_EXTRA
    local needed = swerve + runOut + parkerFront
    local laterals = {baseLateral, baseLateral + 1.0}
    local sides = ADTrafficYieldModule.getSides()

    local lastX, py, lastZ = ADTrafficYieldModule.getPosition(parker)
    if fromIndex ~= nil then
        lastX, lastZ = wayPoints[fromIndex].x, wayPoints[fromIndex].z
    end
    local roadY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, lastX, py, lastZ)

    local partnerX, partnerZ, partnerClearance
    if keepClearOfPartner and reverser ~= nil then
        local px, _, pz = ADTrafficYieldModule.getPosition(reverser)
        local partnerFront = ADTrafficYieldModule.getTrainExtents(reverser)
        local v = ADTrafficYieldModule.getSpeedKmh(reverser) / 3.6
        partnerX, partnerZ = px, pz
        partnerClearance = partnerFront + ADTrafficYieldModule.SPOT_CLEARANCE + v * v / (2 * ADTrafficYieldModule.ANTICIPATION_DECEL)
    end

    -- 28/10: every refusal reason of the search goes in one log line
    local refused, tried = {}, 0
    local function refuse(why)
        local key = why
        if string.sub(why, 1, 5) ~= "objet" then
            key = string.match(why, "^([^%(]-)%s*%(") or why
        end
        refused[key] = (refused[key] or 0) + 1
    end
    for _, side in ipairs(sides) do
        if sideFilter == nil or side.name == sideFilter then
            local fieldCandidate = nil
            local distance = 0
            local lastCheckedDistance = -math.huge
            lastX, _, lastZ = ADTrafficYieldModule.getPosition(parker)
            if fromIndex ~= nil then
                lastX, lastZ = wayPoints[fromIndex].x, wayPoints[fromIndex].z
            end
            for i = startIndex, #wayPoints - 1 do
                local wp = wayPoints[i]
                if wp == nil then
                    break
                end
                distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
                lastX, lastZ = wp.x, wp.z
                if distance + needed > maxAhead then
                    break
                end
                if distance >= 5 and distance - lastCheckedDistance >= ADTrafficYieldModule.CANDIDATE_STEP then
                    lastCheckedDistance = distance
                    local onTrack = not twoWayOnly or ADTrafficYieldModule.isTwoWayStretch(wayPoints, i, needed)
                    for _, lateral in ipairs(onTrack and laterals or {}) do
                        local lat = side.sign * lateral
                        local path = ADTrafficYieldModule.buildOffsetPath(wayPoints, i, lat, swerve, pathLength)
                        local tooCloseToPartner = false
                        if path ~= nil and partnerX ~= nil then
                            local last = path[#path]
                            tooCloseToPartner = MathUtil.vector2Length(last.x - partnerX, last.z - partnerZ) < partnerClearance
                        end
                        if path == nil then
                            refuse("trajet trop court")
                        elseif tooCloseToPartner then
                            refuse("trop pres de l'autre")
                        end
                        if path ~= nil and not tooCloseToPartner then
                            tried = tried + 1
                            local free, onField, why = self:isPathFree(path, parkerWidth, roadY, py)
                            if not free then
                                refuse(why or "?")
                            end
                            -- 30/10 (A): where the tractor stops, the trailer must be off the road. In a bend it cuts
                            -- inside: the path gets up to TOW_EXTRA m longer, otherwise the spot is refused
                            local finalS, towPoints = swerve + runOut, nil
                            if free and towedLength > 1 then
                                local alignedS, points = ADTrafficYieldModule.simulateTowed(path, tractorLength / 2, towedLength, finalS, path[#path].s - 4)
                                if alignedS == nil then
                                    local longPath = ADTrafficYieldModule.buildOffsetPath(wayPoints, i, lat, swerve, pathLength + ADTrafficYieldModule.TOW_EXTRA)
                                    local longFree, longField, longWhy = false, false, "trajet trop court"
                                    if longPath ~= nil then
                                        longFree, longField, longWhy = self:isPathFree(longPath, parkerWidth, roadY, py)
                                    end
                                    if longFree and partnerX ~= nil then
                                        local last = longPath[#longPath]
                                        if MathUtil.vector2Length(last.x - partnerX, last.z - partnerZ) < partnerClearance then
                                            longFree, longWhy = false, "trop pres de l'autre"
                                        end
                                    end
                                    if longFree then
                                        alignedS, points = ADTrafficYieldModule.simulateTowed(longPath, tractorLength / 2, towedLength, finalS, longPath[#longPath].s - 4)
                                        if alignedS ~= nil then
                                            path = ADTrafficYieldModule.trimPath(longPath, alignedS + ADTrafficYieldModule.PATH_EXTRA)
                                            onField = onField or longField
                                        end
                                    end
                                    if alignedS == nil then
                                        free = false
                                        refuse(longFree and "remorque pas hors de la route" or ("remorque pas hors de la route, plus loin " .. tostring(longWhy or "?")))
                                    end
                                end
                                if alignedS ~= nil then
                                    finalS, towPoints = alignedS, points
                                end
                            end
                            if free and not self:isSpotClearForPartner(path, finalS, parkerFront, parkerRear, parkerWidth, towPoints) then
                                free = false
                                refuse("l'autre ne passe pas")
                            end
                            if free then
                                local spot = ADTrafficYieldModule.makePathSpot(path, wp, distance, side.name, lat, swerve, finalS - swerve, onField, roadY)
                                if not onField then
                                    return spot
                                end
                                fieldCandidate = fieldCandidate or spot
                            end
                        end
                    end
                end
            end
            -- no grass spot on this side: a spot partly on a field of this side before trying the other side
            if fieldCandidate ~= nil then
                return fieldCandidate
            end
        end
    end
    if tried > 0 or next(refused) ~= nil then
        local parts = {}
        for key, count in pairs(refused) do
            table.insert(parts, string.format("%s x%d", key, count))
        end
        table.sort(parts)
        if g_time - (self.spotSummaryTime or -math.huge) > 10000 then
            self.spotSummaryTime = g_time
            print(string.format("[AD-Croise] %s: aucune place %s sur %.0f m (%d essais) : %s", ADTrafficYieldModule.getName(parker),
                tostring(sideFilter or "des deux cotes"), maxAhead, tried, table.concat(parts, ", ")))
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- L'autre passe-t-il à côté ?
-- ------------------------------------------------------------------------------------------------------------
-- S7 (28/10: the 6205 TTV parked in the mouth of the farm track, the Magnum 7220 with its cultivator
-- could not get past and each one waited for the other): a roadside spot is kept only when the whole other train (as its
-- sensors see it, implements included) passes beside the parked train, and never within SPOT_MOUTH_CLEAR m of the mouth
-- of a single track
function ADTrafficYieldModule:isSpotClearForPartner(path, finalS, parkerFront, parkerRear, parkerWidth, towPoints)
    local partner = self.partner
    if partner == nil or path == nil or #path < 2 or partner.ad == nil or partner.ad.drivePathModule == nil then
        return true
    end
    local final = path[#path]
    for _, p in ipairs(path) do
        if p.s >= finalS then
            final = p
            break
        end
    end
    local dx, dz = final.dirX or 0, final.dirZ or 0
    local points = {}
    -- 30/10: with a trailer, its simulated points (it cuts inside a bend) instead of the rear straight behind
    for _, s in ipairs(towPoints ~= nil and {parkerFront or 0, 0} or {parkerFront or 0, 0, -(parkerRear or 0)}) do
        table.insert(points, {x = final.x + dx * s, z = final.z + dz * s})
    end
    for _, p in ipairs(towPoints or {}) do
        table.insert(points, p)
    end
    local route = ADTrafficYieldModule.getRoutePolyline(partner, 150)
    local partnerWidth = 0
    local widest = partner
    -- every vehicle of the oncoming queue must pass beside me, the widest one counts
    local cache = self.queueCache
    if cache == nil or cache.loop ~= g_updateLoopIndex or cache.partner ~= partner then
        local queue = ADTrafficYieldModule.getQueueBehind(partner, self.vehicle)
        table.insert(queue, 1, partner)
        cache = {loop = g_updateLoopIndex, partner = partner, queue = queue}
        self.queueCache = cache
    end
    for _, v in ipairs(cache.queue) do
        local w = ADTrafficYieldModule.getWidth(v)
        if v.ad.approachModule ~= nil and v.ad.approachModule.getTrainWidth ~= nil then
            local sideMargin = ADApproachModule ~= nil and ADApproachModule.SIDE_MARGIN or 0.3
            w = math.max(w, v.ad.approachModule:getTrainWidth() + 2 * sideMargin)
        end
        if w > partnerWidth then
            partnerWidth, widest = w, v
        end
    end
    local needed = partnerWidth / 2 + (parkerWidth or 0) / 2 + ADTrafficYieldModule.SPOT_PASS_MARGIN
    for _, p in ipairs(points) do
        local d = ADTrafficYieldModule.distanceToPolyline(route, p.x, p.z)
        if d < needed then
            self:logSpotRefused(string.format("%s would not pass (%.1f m from its route, %.1f m needed)", ADTrafficYieldModule.getName(widest), d, needed),
                string.format("place refusee : %s ne passerait pas a cote (%.1f m de son trajet, il faut %.1f m)", ADTrafficYieldModule.getName(widest), d, needed))
            return false
        end
    end
    -- mouth of a single track on my route or on its route near the parked train
    local ids = {}
    local function collect(vehicle, maxDistance)
        local wps, idx = vehicle.ad.drivePathModule:getWayPoints()
        if wps == nil or idx == nil then
            return
        end
        local qx, _, qz = ADTrafficYieldModule.getPosition(vehicle)
        local distance = 0
        for i = math.max(1, idx - 1), #wps do
            local wp = wps[i]
            if wp == nil then
                break
            end
            distance = distance + MathUtil.vector2Length(wp.x - qx, wp.z - qz)
            qx, qz = wp.x, wp.z
            if distance > maxDistance then
                break
            end
            if wp.id ~= nil then
                ids[wp.id] = wp
            end
        end
    end
    collect(self.vehicle, 200)
    collect(partner, 150)
    for id, wp in pairs(ids) do
        local close = false
        for _, p in ipairs(points) do
            if MathUtil.vector2Length(wp.x - p.x, wp.z - p.z) < ADTrafficYieldModule.SPOT_MOUTH_CLEAR then
                close = true
                break
            end
        end
        if close and ADTrafficYieldModule.isSingleTrackMouth(id) then
            self:logSpotRefused("within the mouth of a single track", string.format("place refusee : a moins de %d m de l'entree d'un chemin unique", ADTrafficYieldModule.SPOT_MOUTH_CLEAR))
            return false
        end
    end
    return true
end

function ADTrafficYieldModule:logSpotRefused(text, textFr)
    if self.spotRefusedLog ~= nil and self.spotRefusedLog == textFr and g_time - (self.spotRefusedTime or 0) < 10000 then
        return
    end
    self.spotRefusedLog, self.spotRefusedTime = textFr, g_time
    self:log("spot refused: %s", text)
    print(string.format("[AD-Croise] %s: %s", ADTrafficYieldModule.getName(self.vehicle), textFr))
end

-- ------------------------------------------------------------------------------------------------------------
-- Place derrière moi, dans le chemin à double sens
-- ------------------------------------------------------------------------------------------------------------
-- a spot in the two-way track that I (the one inside) reach by backing up along my route, REVERSE_SEARCH_MAX m at most,
-- for 'other' to pass (driving side, SPOT_MOUTH_CLEAR m from the mouths, the other whole train passes beside).
-- Returns the spot and the length I would reverse (0 when it is in front of me), nil without one
function ADTrafficYieldModule:searchSpotBehind(other)
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return nil
    end
    -- as far back as the two-way track goes, REVERSE_SEARCH_MAX m at most
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local fromIndex, behind = nil, 0
    local lastX, lastZ = x, z
    for i = currentIndex - 1, 1, -1 do
        local wp, nextWp = wayPoints[i], wayPoints[i + 1]
        if wp == nil or nextWp == nil or wp.id == nil or nextWp.id == nil or not ADTrafficYieldModule.isTwoWay(wp.id, nextWp.id) then
            break
        end
        local d = MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        if behind + d > ADTrafficYieldModule.REVERSE_SEARCH_MAX then
            break
        end
        behind = behind + d
        lastX, lastZ = wp.x, wp.z
        fromIndex = i
    end
    if fromIndex == nil then
        fromIndex, behind = currentIndex, 0
    end
    local ox, _, oz = ADTrafficYieldModule.getPosition(other)
    local gap = MathUtil.vector2Length(ox - x, oz - z)
    local savedPartner = self.partner
    self.partner = other
    self.spotTwoWayOnly = true
    local ok, spot = FarmPilotCall(self.searchSpotBySides, self, behind + gap, true, fromIndex)
    self.spotTwoWayOnly = nil
    self.partner = savedPartner
    if not ok then
        Logging.error("[AD] ADTrafficYieldModule: spot search behind failed: %s", tostring(spot))
        return nil
    end
    if spot == nil then
        return nil
    end
    return spot, math.max(0, behind - (spot.entryDistance or 0) + 5)
end
