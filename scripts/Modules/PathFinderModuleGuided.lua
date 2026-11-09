-- ============================================================================================================
-- FarmPilot : PathFinderModuleGuided.lua
-- Complément de PathFinderModule : le départ guidé (ensileuse, strict).
-- Quand aucun trajet propre ne part de là où le train se trouve (virages trop serrés pour lui, culture à une entrée
-- de champ étroite), de courtes courbes sont essayées depuis la vraie position et le vrai cap du tracteur, d'abord
-- à son vrai rayon de braquage puis plus serré. Toute la bande balayée par le train doit être libre de culture
-- (côté intérieur élargi dans les courbes, la remorque les coupe) et d'obstacles, et le train doit être dégagé à
-- l'arrêt, jamais dans le chemin de la moissonneuse.
--
-- Historique :
-- - comportements ensileuse du 21/10 (départ guidé, trajets partiels courts, contrôle de la courbe directe) : seulement
--   quand on décharge une ensileuse, une moissonneuse garde l'ancien comportement (isChopperWork) ;
-- - règle : pas de trajet et un virage trop serré -> rouler jusqu'à un arrêt propre plus loin ;
-- - échecs répétés au même endroit : niveau 2 = la 2e ligne de culture aussi (1er rang permis) ;
-- - 24/10 : la remorque coupait l'intérieur de la courbe dans les tracteurs en attente ; 24/10 07:06 : la courbe
--   s'arrêtait nez contre un tracteur en attente (seul son centre était contrôlé) ; 24/10 : nez sur l'herbe contre
--   le mur (le nez et ses coins restent sur le champ).
--
-- Règle : la zone d'arrêt reste toujours entièrement propre, à tous les niveaux.
--
-- Branché par PathFinderModuleVerify.lua (tryGuidedDeparture) et CatchCombinePipeTask.lua ; isChopperWork est
-- utilisé par presque tous les fichiers PathFinderModule*.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Ensileuse : quand ces règles s'appliquent
-- ------------------------------------------------------------------------------------------------------------
-- the forage harvester behaviours of 21/10 (guided departure, short partial routes, direct curve checks...)
-- only apply when unloading a forage harvester: a combine harvester keeps the former behaviour
function PathFinderModule:isChopperWork()
    return AutoDrive.isChopperUnloading(self.vehicle)
end

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- guided departure (strict): when no clean route leaves from where the train stands (corners too sharp for it,
-- crop at a tight field entrance), short curves are tried from the real position and heading of the tractor,
-- first with its real turning radius, then tighter. The whole band swept by the train must be free of crop
-- (inner side widened in curves, the trailer cuts them) and of obstacles, and the train must stand clear at the stop
PathFinderModule.GUIDED_DISTANCES = {15, 20, 25, 30, 35, 40}
PathFinderModule.GUIDED_BEARING_MAX = 90 -- deg, stop points ahead and beside the tractor (parked askew)
PathFinderModule.GUIDED_BEARING_STEP = 15
PathFinderModule.GUIDED_HEADING_MAX = 90 -- deg, heading at the stop relative to the tractor
PathFinderModule.GUIDED_HEADING_STEP = 15
PathFinderModule.GUIDED_RADIUS_FACTORS = {1, 0.8, 0.7}
PathFinderModule.GUIDED_MIN_GAIN = 5
-- no route but with a corner too sharp, no clean stop closer: drive on to a clean stop further, up to
-- GUIDED_MAX_LOSS farther from the target, the one with the most room of the strips around it, then plan again.
-- Once per place (GUIDED_LOSS_PLACE m, GUIDED_LOSS_TIME ms), GUIDED_LOSS_MAX_IN_ROW in a row, then the task's U-turn
PathFinderModule.GUIDED_MAX_LOSS = 30
PathFinderModule.GUIDED_LOSS_PLACE = 15
PathFinderModule.GUIDED_LOSS_TIME = 120000
PathFinderModule.GUIDED_LOSS_MAX_IN_ROW = 2
PathFinderModule.GUIDED_ROOM_RADIUS = 10
PathFinderModule.GUIDED_MAX_CURVES = 60 -- curves checked per radius, keeps the frame time low
PathFinderModule.GUIDED_MAX_IN_ROW = 3 -- guided departures in a row without a normal route
PathFinderModule.GUIDED_TRAILER_LENGTH = 6 -- for the cut of the trailer inside the curves
PathFinderModule.GUIDED_STOP_AHEAD = 4 -- clear ground in front of the stop (the train overruns ~3 m)
PathFinderModule.GUIDED_EXIT_AHEAD = 10 -- m ahead of the stop free of crop at the train width: never stop nose against the crop
PathFinderModule.GUIDED_POINT_SPACING = 2
PathFinderModule.GUIDED_EXACT_LENGTH = 15 -- m at the start of a guided curve checked at the exact train width (no margin)
PathFinderModule.GUIDED_START_TOLERANCE = 4 -- first meters where the train already stands: exact width, as the grid search
PathFinderModule.GUIDED_RETRY_TIME = 15000 -- no new search from the same place before this delay (ms)
-- repeated failure from the same place: the crop border lines of the map are ignored on the first meters,
-- level 1 = first line (the map spills onto the cut strip), level 2 = second line too (first crop row, allowed).
-- The stop zone stays fully clean at every level
PathFinderModule.GUIDED_BORDER_LENGTH = 30
PathFinderModule.GUIDED_BORDER_LINE = 2 -- m, one map cell
PathFinderModule.GUIDED_MAX_LEVEL = 2
PathFinderModule.GUIDED_FAILS_PER_LEVEL = 2
-- never stop in the way of the harvester: not in its lane ahead, not too close, not facing it
PathFinderModule.GUIDED_LANE_LENGTH = 60
PathFinderModule.GUIDED_LANE_MARGIN = 2
PathFinderModule.GUIDED_MIN_HARVESTER_DISTANCE = 15 -- failed searches at a level before the next one (extreme case only)

-- ------------------------------------------------------------------------------------------------------------
-- Arrêt et bande balayée par le train
-- ------------------------------------------------------------------------------------------------------------
-- stop point in the way of the harvester the route goes to (nil: no harvester, nothing in the way)
function PathFinderModule:isGuidedStopInHarvesterWay(x, z, heading)
    local combine = self.pipeCombine
    if not self.goingToPipe or combine == nil or combine.components == nil then
        return false
    end
    local cx, _, cz = getWorldTranslation(combine.components[1].node)
    local rx, _, rz = AutoDrive.localDirectionToWorld(combine, 0, 0, 1)
    local dx, dz = x - cx, z - cz
    local distance = math.sqrt(dx * dx + dz * dz)
    if distance < PathFinderModule.GUIDED_MIN_HARVESTER_DISTANCE then
        return true
    end
    local ahead = dx * rx + dz * rz
    local side = math.abs(dx * rz - dz * rx)
    local width = (combine.size ~= nil and combine.size.width or 4) / 2 + (self.trainHalfWidth or 2) + PathFinderModule.GUIDED_LANE_MARGIN
    if ahead > 0 and ahead < PathFinderModule.GUIDED_LANE_LENGTH and side < width then
        return true
    end
    if distance < PathFinderModule.PARTIAL_FACING_MAX_DISTANCE
        and (math.sin(heading) * rx + math.cos(heading) * rz) < math.cos(PathFinderModule.PARTIAL_MAX_HEADING_ANGLE) then
        return true
    end
    return false
end

-- crop sample within level lines of clean cut field ground
function PathFinderModule.isGuidedBorderCrop(x, z, level)
    local maxR = level * PathFinderModule.GUIDED_BORDER_LINE
    for r = 1, maxR do
        for k = 0, 7 do
            local a = k * math.pi / 4
            local px, pz = x + math.sin(a) * r, z + math.cos(a) * r
            if PathFinderModule.getMapCropAt(px, pz) == 0 and PathFinderModule.getMapOnFieldAt(px, pz) then
                return true
            end
        end
    end
    return false
end

-- returns clear, distance along the curve of the first crop met
function PathFinderModule:isGuidedBandClear(path, radius, level)
    level = level or 0
    local along = 0
    -- crop band at the outer tyre edges (forage harvester only uses the guided departure)
    local half = self:getCropHalfWidth()
    local exactHalf = math.min(half, self:getTrainWidth() / 2)
    local cut = PathFinderModule.GUIDED_TRAILER_LENGTH
    cut = math.min(radius - math.sqrt(math.max(radius * radius - cut * cut, 0)), 3)
    for i = 2, #path do
        local a, b = path[i - 1], path[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        along = along + l
        if l > 0.05 then
            dx, dz = dx / l, dz / l
            local tolerant = level > 0 and along <= PathFinderModule.GUIDED_BORDER_LENGTH
            -- first GUIDED_EXACT_LENGTH meters (leaving a strip along the crop): exact train width, no comfort margin;
            -- the trailer cut inside the curves is still added after the first meters
            local base = along <= PathFinderModule.GUIDED_EXACT_LENGTH and exactHalf or half
            local left, right = base, base
            local c = path[i + 1]
            if i > PathFinderModule.GUIDED_START_TOLERANCE + 1 and c ~= nil then
                local cross = dx * (c.z - b.z) - dz * (c.x - b.x)
                if cross > 0.02 then
                    left = base + cut
                elseif cross < -0.02 then
                    right = base + cut
                end
            end
            local nx, nz = -dz, dx
            local w = -right
            while w <= left do
                for _, back in ipairs({0, 0.5}) do
                    local px, pz = b.x - dx * back + nx * w, b.z - dz * back + nz * w
                    local crop = PathFinderModule.getMapCropAt(px, pz)
                    if crop ~= nil and crop ~= 0 and not (tolerant and PathFinderModule.isGuidedBorderCrop(px, pz, level)) then
                        return false, along
                    end
                end
                w = w + 0.5
            end
        end
    end
    return true, nil
end

-- the stopped train stands on the last meters of the curve: that strip (and the overrun ahead) must be fully clean.
-- The first meters, where the train already stands, are left out as for the band
function PathFinderModule:isGuidedStopClear(path, hx, hz)
    local half = self:getCropHalfWidth()
    local trainLength = math.max(AutoDrive.getTractorTrainLength(self.vehicle, true, false), 8)
    local last = path[#path]
    -- overrun ahead of the stop, then room to drive on: a stop nose against the crop has no way out but reversing
    local ahead = math.max(PathFinderModule.GUIDED_STOP_AHEAD, PathFinderModule.GUIDED_EXIT_AHEAD)
    for f = 0.5, ahead, 0.5 do
        local w = -half
        while w <= half do
            local crop = PathFinderModule.getMapCropAt(last.x + hx * f - hz * w, last.z + hz * f + hx * w)
            if crop ~= nil and crop ~= 0 then
                return false
            end
            w = w + 0.5
        end
    end
    local covered = 0
    for i = #path, 2, -1 do
        if i <= PathFinderModule.GUIDED_START_TOLERANCE + 1 or covered >= trainLength then
            break
        end
        local a, b = path[i - 1], path[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 0.05 then
            dx, dz = dx / l, dz / l
            for _, back in ipairs({0, 0.5}) do
                local w = -half
                while w <= half do
                    local crop = PathFinderModule.getMapCropAt(b.x - dx * back - dz * w, b.z - dz * back + dx * w)
                    if crop ~= nil and crop ~= 0 then
                        return false
                    end
                    w = w + 0.5
                end
            end
            covered = covered + l
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ guidé (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function PathFinderModule:tryGuidedDepartureFurther()
    local node = self.vehicle.components[1].node
    local vx, _, vz = getWorldTranslation(node)
    local now = g_time or 0
    if (self.guidedLossInRow or 0) >= PathFinderModule.GUIDED_LOSS_MAX_IN_ROW then
        print(string.format("[AD-Fin] %s: depart guide plus loin : %d de suite, attente (demi-tour)", self:getLogName(), self.guidedLossInRow))
        return false
    end
    if self.guidedLossX ~= nil and now - (self.guidedLossTime or 0) < PathFinderModule.GUIDED_LOSS_TIME
        and MathUtil.vector2Length(vx - self.guidedLossX, vz - self.guidedLossZ) < PathFinderModule.GUIDED_LOSS_PLACE then
        print(string.format("[AD-Fin] %s: depart guide plus loin : deja essaye a moins de %d m, attente (demi-tour)", self:getLogName(), PathFinderModule.GUIDED_LOSS_PLACE))
        return false
    end
    -- once per place, found or not
    self.guidedLossX, self.guidedLossZ, self.guidedLossTime = vx, vz, now
    -- the usual search with its limits lifted: no retry delay, no count in a row
    local failX, inRow = self.guidedFailX, self.guidedInRow
    self.guidedFailX, self.guidedInRow = nil, 0
    local level, levelFails = self.guidedLevel, self.guidedLevelFails
    self.guidedFurther = true
    local ok = self:tryGuidedDeparture()
    self.guidedFurther = false
    self.guidedFailX, self.guidedInRow = failX, inRow
    self.guidedLevel, self.guidedLevelFails = level, levelFails
    if ok then
        self.guidedLossInRow = (self.guidedLossInRow or 0) + 1
    end
    return ok
end

-- points of the strips within GUIDED_ROOM_RADIUS (2 m steps): room to turn there
function PathFinderModule:getGuidedRoom(x, z)
    if not self:isBandFloodReady() then
        return 0
    end
    local room, r = 0, PathFinderModule.GUIDED_ROOM_RADIUS
    for dz = -r, r, 2 do
        for dx = -r, r, 2 do
            if dx * dx + dz * dz <= r * r and ADBandRoute.getDistance(self.bandFlood, x + dx, z + dz, 1) ~= nil then
                room = room + 1
            end
        end
    end
    return room
end

function PathFinderModule:tryGuidedDeparture(allowLoss)
    if self.startPose ~= nil or not self:isChopperWork() or not (self.strictFruit or self.strictField) or self.target == nil or self.startX == nil then
        return false
    end
    if allowLoss then
        return self:tryGuidedDepartureFurther()
    end
    if (self.guidedInRow or 0) >= PathFinderModule.GUIDED_MAX_IN_ROW then
        if not self.guidedLimitPrinted then
            self.guidedLimitPrinted = true
            print(string.format("[AD-Fin] %s: depart guide : %d de suite sans trajet normal, attente", self:getLogName(), self.guidedInRow))
        end
        return false
    end
    local node = self.vehicle.components[1].node
    local vx, _, vz = getWorldTranslation(node)
    -- nothing found from this very place a moment ago: no new search yet (it costs frame time)
    local now = g_time or 0
    if self.guidedFailX ~= nil and MathUtil.vector2Length(vx - self.guidedFailX, vz - self.guidedFailZ) < 1 then
        if now - (self.guidedFailTime or 0) < PathFinderModule.GUIDED_RETRY_TIME then
            return false
        end
    else
        -- another place: back to the clean search
        self.guidedLevel = 0
        self.guidedLevelFails = 0
    end
    local level = self.guidedLevel or 0
    local further = self.guidedFurther == true
    if further then
        level = 0
    end
    local rx, _, rz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local heading = math.atan2(rx, rz)
    local q0 = {vx, -vz, AutoDrive.normalizeAngle(heading + math.pi + math.pi / 2)}

    -- stop points on clean field ground ahead, best gain toward the target first
    local candidates = {}
    local inWay = 0
    for _, d in ipairs(PathFinderModule.GUIDED_DISTANCES) do
        for b = -PathFinderModule.GUIDED_BEARING_MAX, PathFinderModule.GUIDED_BEARING_MAX, PathFinderModule.GUIDED_BEARING_STEP do
            local a = heading + math.rad(b)
            local x, z = vx + math.sin(a) * d, vz + math.cos(a) * d
            local gain = self:partialGain({x = x, z = z})
            local crop = PathFinderModule.getMapCropAt(x, z)
            local minGain = further and -PathFinderModule.GUIDED_MAX_LOSS or PathFinderModule.GUIDED_MIN_GAIN
            if gain >= minGain and (crop == nil or crop == 0) and PathFinderModule.getMapOnFieldAt(x, z) then
                local room = further and self:getGuidedRoom(x, z) or 0
                for h = -PathFinderModule.GUIDED_HEADING_MAX, PathFinderModule.GUIDED_HEADING_MAX, PathFinderModule.GUIDED_HEADING_STEP do
                    local endHeading = heading + math.rad(h)
                    if self:isGuidedStopInHarvesterWay(x, z, endHeading) then
                        inWay = inWay + 1
                    else
                        candidates[#candidates + 1] = {x = x, z = z, d = d, heading = endHeading, gain = gain - math.abs(h) * 0.02, room = room}
                    end
                end
            end
        end
    end
    if further then
        -- the most room to turn first, then the smallest loss
        table.sort(candidates, function(c1, c2)
            if c1.room ~= c2.room then
                return c1.room > c2.room
            end
            return c1.gain > c2.gain
        end)
    else
        table.sort(candidates, function(c1, c2) return c1.gain > c2.gain end)
    end

    local tried, refusedBand, refusedStop, refusedObstacle, firstCrop = 0, 0, 0, 0, nil
    for _, factor in ipairs(PathFinderModule.GUIDED_RADIUS_FACTORS) do
        local radius = (self.realTurnRadius or self.minTurnRadius) * factor
        local checked = 0
        for _, cand in ipairs(candidates) do
            if checked >= PathFinderModule.GUIDED_MAX_CURVES then
                break
            end
            local hx, hz = math.sin(cand.heading), math.cos(cand.heading)
            local q1 = {cand.x, -cand.z, AutoDrive.normalizeAngle(cand.heading + math.pi + math.pi / 2)}
            self.dubins.outPath = {}
            if self.dubins:dubins_shortest_path(ADDubins.DubinsPath, q0, q1, radius) == ADDubins.EDUBOK
                and self.dubins:dubins_path_length(ADDubins.DubinsPath) <= cand.d * 1.6 then
                checked = checked + 1
                tried = tried + 1
                local length = self.dubins:dubins_path_length(ADDubins.DubinsPath)
                if self.dubins:dubins_path_sample_many(ADDubins.DubinsPath, 1, self.dubins.createWayPoints) == ADDubins.EDUBOK
                    and #self.dubins.outPath > 2 then
                    local path = self.dubins.outPath
                    path[#path + 1] = {x = cand.x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cand.x, 1, cand.z), z = cand.z, t = q1[3]}
                    local ok, cropAt = self:isGuidedBandClear(path, radius, level)
                    if not ok then
                        refusedBand = refusedBand + 1
                        if cropAt ~= nil and (firstCrop == nil or cropAt > firstCrop) then
                            firstCrop = cropAt
                        end
                    elseif not self:isGuidedStopClear(path, hx, hz) then
                        ok = false
                        refusedStop = refusedStop + 1
                    end
                    if ok then
                        -- level 2 drives over the first crop row on the first meters: the tractor's own crop check is left out there
                        local avoidFruit = self.avoidFruitSetting
                        -- obstacles, slope, field and the usual crop check of the tractor, as for any curve
                        local cells = {}
                        for i, wp in ipairs(path) do
                            local cell = {x = i, z = 0, t = wp.t, height = self.vehicleMinHeight}
                            cell.worldPos = {x = wp.x, y = wp.y, z = wp.z}
                            cell.incoming = cells[i - 5]
                            cells[i] = cell
                            -- the first meters are where the train already stands
                            if level >= 2 then
                                self.avoidFruitSetting = avoidFruit and i > PathFinderModule.GUIDED_BORDER_LENGTH
                            end
                            if i > PathFinderModule.GUIDED_START_TOLERANCE + 1 and not self:isDriveableDubins(cell) then
                                ok = false
                                refusedObstacle = refusedObstacle + 1
                                break
                            end
                        end
                        self.avoidFruitSetting = avoidFruit
                    end
                    if ok and not self:isGuidedTrailerClear(path) then
                        -- 24/10: the trailer cut inside the curve into the waiting tractors
                        ok = false
                        refusedObstacle = refusedObstacle + 1
                    end
                    if ok then
                        local points = {}
                        local spacing = PathFinderModule.GUIDED_POINT_SPACING
                        for i, wp in ipairs(path) do
                            if i == 1 or i == #path or (i - 1) % spacing == 0 then
                                points[#points + 1] = {x = wp.x, y = wp.y, z = wp.z}
                            end
                        end
                        self.wayPoints = points
                        self.partialPath = true
                        if further then
                            print(string.format("[AD-Fin] %s: depart guide plus loin : courbe de %.0f m (rayon %.1f m) vers %.0f,%.0f, %.0f m plus loin de la cible, place %d, nouveau calcul de la", self:getLogName(), length, radius, cand.x, cand.z, -cand.gain, cand.room))
                            return true
                        end
                        self.guidedInRow = (self.guidedInRow or 0) + 1
                        self.guidedFailPrinted = false
                        self.guidedLevel = 0
                        self.guidedLevelFails = 0
                        print(string.format("[AD-Fin] %s: depart guide niveau %d : courbe de %.0f m (rayon %.1f m) vers %.0f,%.0f, %.0f m plus pres, %d courbes essayees", self:getLogName(), level, length, radius, cand.x, cand.z, cand.gain, tried))
                        return true
                    end
                end
            end
        end
    end
    if further then
        print(string.format("[AD-Fin] %s: depart guide plus loin : aucune courbe propre (%d points d'arret, %d genant l'ensileuse, %d courbes : bande %d, arret %d, obstacle %d), attente", self:getLogName(), #candidates, inWay, tried, refusedBand, refusedStop, refusedObstacle))
        return false
    end
    self.guidedFailX, self.guidedFailZ, self.guidedFailTime = vx, vz, now
    self.guidedLevelFails = (self.guidedLevelFails or 0) + 1
    local raise = level < PathFinderModule.GUIDED_MAX_LEVEL and self.guidedLevelFails >= PathFinderModule.GUIDED_FAILS_PER_LEVEL
    print(string.format("[AD-Fin] %s: depart guide niveau %d (echec %d) : aucune courbe propre (%d points d'arret, %d genant l'ensileuse, %d courbes : bande %d, arret %d, obstacle %d ; culture la plus loin a %s m), %s", self:getLogName(), level, self.guidedLevelFails, #candidates, inWay, tried, refusedBand, refusedStop, refusedObstacle, firstCrop ~= nil and string.format("%.0f", firstCrop) or "-", raise and string.format("niveau %d au prochain essai", level + 1) or "attente"))
    if raise then
        self.guidedLevel = level + 1
        self.guidedLevelFails = 0
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Remorque dans les courbes
-- ------------------------------------------------------------------------------------------------------------
-- the trailer cuts inside a curve (about L^2 / 2R): its axle is followed along the path (hitch behind the
-- tractor, axle pulled toward the hitch) and its body checked for obstacles and vehicles every meter
PathFinderModule.GUIDED_TRAILER_MARGIN = 0.3
PathFinderModule.GUIDED_FRONT_ROOM = 3 -- m free ahead of the tractor nose at the stop
function PathFinderModule:isGuidedTrailerClear(path)
    local module = self.vehicle.ad.trafficYieldModule
    if module == nil or module.overlapHit == nil or #path < 3 then
        return true
    end
    local tractorLength = (self.vehicle.size ~= nil and self.vehicle.size.length) or 6
    local trailerLength = AutoDrive.getTractorTrainLength(self.vehicle, true, false) - tractorLength
    local halfW = self:getTrainWidth() / 2 + PathFinderModule.GUIDED_TRAILER_MARGIN
    local function hitchAt(i)
        local a, b = path[math.max(1, i - 1)], path[math.min(#path, i + 1)]
        local hx, hz = b.x - a.x, b.z - a.z
        local len = math.sqrt(hx * hx + hz * hz)
        if len < 0.01 then
            return nil
        end
        hx, hz = hx / len, hz / len
        return path[i].x - hx * tractorLength / 2, path[i].z - hz * tractorLength / 2, hx, hz
    end
    -- the whole tractor body (its nose reaches well ahead of the path point) and the room ahead of the stop
    -- (24/10 07:06: the curve stopped nose against a waiting tractor, only its centre had been checked)
    local size = self.vehicle.size or {}
    local halfL = (size.length or 6) / 2
    local offset = size.lengthOffset or 0
    local name = self:getLogName()
    local strictField = AutoDrive.getSetting("restrictToField", self.vehicle) == "strict"
    local indices = {}
    for i = PathFinderModule.GUIDED_START_TOLERANCE + 2, #path - 1, 2 do
        indices[#indices + 1] = i
    end
    indices[#indices + 1] = #path
    for _, i in ipairs(indices) do
        local _, _, dx, dz = hitchAt(i)
        if dx ~= nil then
            local cx, cz = path[i].x + dx * offset, path[i].z + dz * offset
            local ahead = 0
            if i == #path then
                ahead = PathFinderModule.GUIDED_FRONT_ROOM
            end
            cx, cz = cx + dx * ahead / 2, cz + dz * ahead / 2
            -- the nose and its corners stay on the field ground (24/10: nose on the grass against the wall)
            if strictField then
                local nose = halfL + ahead / 2
                for _, w in ipairs({-halfW, 0, halfW}) do
                    local nx, nz = cx + dx * nose - dz * w, cz + dz * nose + dx * w
                    if not PathFinderModule.getMapOnFieldAt(nx, nz) then
                        print(string.format("[AD-Fin] %s: depart guide : le nez du tracteur sortirait du champ vers %.0f,%.0f", name, nx, nz))
                        return false
                    end
                end
            end
            local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 0, cz)
            if module:overlapHit(cx, y + 2, cz, math.atan2(dx, dz), halfW, 1.5, halfL + ahead / 2) then
                print(string.format("[AD-Fin] %s: depart guide : le tracteur %s toucherait un obstacle ou un vehicule vers %.0f,%.0f", name,
                    ahead > 0 and "(nez + place devant l'arret)" or "", cx, cz))
                return false
            end
        end
    end
    local hx0, hz0, dx0, dz0 = hitchAt(1)
    if hx0 == nil or trailerLength < 3 then
        return true
    end
    local tx, tz = hx0 - dx0 * trailerLength, hz0 - dz0 * trailerLength
    for i = 2, #path do
        local hx, hz = hitchAt(i)
        if hx ~= nil then
            local vx, vz = hx - tx, hz - tz
            local len = math.sqrt(vx * vx + vz * vz)
            if len > 0.01 then
                tx, tz = hx - vx / len * trailerLength, hz - vz / len * trailerLength
                -- the first meters are where the train already stands
                if i > PathFinderModule.GUIDED_START_TOLERANCE + 1 then
                    local cx, cz = (hx + tx) / 2, (hz + tz) / 2
                    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 0, cz)
                    if module:overlapHit(cx, y + 2, cz, math.atan2(vx, vz), halfW, 1.5, trailerLength / 2) then
                        print(string.format("[AD-Fin] %s: depart guide : la remorque toucherait un obstacle ou un vehicule vers %.0f,%.0f (coupe l'interieur du virage)", self:getLogName(), cx, cz))
                        return false
                    end
                end
            end
        end
    end
    return true
end
