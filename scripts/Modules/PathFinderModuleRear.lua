-- ============================================================================================================
-- FarmPilot : PathFinderModuleRear.lua
-- Complément de PathFinderModule : derrière la moissonneuse, sur sa propre trace coupée.
-- Sans trajet propre vers la goulotte (et d'office loin de la moissonneuse, ou toujours pour l'ensileuse), le
-- déchargeur vise un point derrière elle, sur la trace qu'elle a vraiment roulée ; la poursuite prend le relais là.
-- - sens de travail : l'avant fait face à la culture debout, l'arrière au sol coupé (vérifié sur la carte) ;
-- - place du train : sur le champ, sans culture sur sa demi-largeur, sans obstacle fixe (haie, arbres, mur, zone
--   interdite) sous le train entier ;
-- - point sur la trace : la trace enregistrée d'abord, puis le sol coupé mètre par mètre derrière elle.
--
-- Historique :
-- - 23/10 : dans une courbe la ligne droite derrière elle tombe dans la culture ; demi-tour de fin de rang (trace
--   d'avant son dernier virage, entrée du rang suivant lue sur la course Courseplay, tracteur tourné dans l'autre sens) ;
-- - sens de travail de la moissonneuse, reconnu sur la carte du champ ;
-- - 25/10 11:53 : le Puma renvoyé 20 m en arrière sur l'arc du demi-tour (moissonneuse arrêtée : seul compte son axe) ;
-- - 25/10 16:35 : plus de place à chaque arrivée à contresens au même endroit (CatchCombinePipeTask.tryWrongWayTurn) ;
-- - 25/10 19:14 : la place derrière une moissonneuse dos à une haie était dans la
--   haie ; la marche s'arrête au premier obstacle fixe ;
-- - ensileuse : toujours par derrière, à toute distance, même arrêtée.
--
-- Règle : rien n'est visé au-delà d'un obstacle fixe ni hors du champ.
--
-- Branché par PathFinderModule.lua : startPathPlanningToPipe (startRearFirst), update (startRearFallback) ;
-- getWorkingDirection, isCombineStanding, getTrailDirectionAt et startRearFallback aussi par CatchCombinePipeTask.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- behind the harvester: on its own cut track, the chase takes over from there
PathFinderModule.REAR_FALLBACK_GAP = 8
PathFinderModule.REAR_FIRST_DISTANCE = 40

-- ------------------------------------------------------------------------------------------------------------
-- Sens de travail de la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- working direction of a harvester (recognised): its front faces the standing crop, its back the cut ground.
-- The node direction is checked against the field map: crop on the back side only means the node points backwards
PathFinderModule.WORK_DIR_SCAN = {2, 4, 6, 8} -- m beyond its half length
function PathFinderModule:getWorkingDirection(combine)
    local x, _, z = getWorldTranslation(combine.components[1].node)
    local rx, _, rz = AutoDrive.localDirectionToWorld(combine, 0, 0, 1, combine.ad ~= nil and combine.ad.ADRootNode or nil)
    local half = (combine.size ~= nil and combine.size.length or 10) / 2
    local function cropCount(sign)
        local n = 0
        for _, d in ipairs(PathFinderModule.WORK_DIR_SCAN) do
            for _, w in ipairs({-2, 0, 2}) do
                local px, pz = x + rx * sign * (half + d) - rz * w, z + rz * sign * (half + d) + rx * w
                local crop = PathFinderModule.getMapCropAt(px, pz)
                if crop ~= nil and crop ~= 0 then
                    n = n + 1
                end
            end
        end
        return n
    end
    -- during a Courseplay turn (end of row) the crop around it says nothing about its direction: node direction
    if AutoDrive.combineIsTurning(combine) then
        return rx, rz
    end
    local ahead, behind = cropCount(1), cropCount(-1)
    if behind > ahead then
        print(string.format("[AD-Fin] %s: sens de travail de la moissonneuse retourne (culture derriere %d, devant %d)", self:getLogName(), behind, ahead))
        return -rx, -rz
    end
    return rx, rz
end

-- ------------------------------------------------------------------------------------------------------------
-- Place du train derrière la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- fixed obstacle (hedge, trees, wall, learned blocked zone) in a slice of the train's width at x, z along hx, hz
-- (25/10 19:14: the place behind a harvester standing with its back to a hedge was in the hedge)
PathFinderModule.REAR_PROBE_HALF_LENGTH = 1 -- m
function PathFinderModule:isRearPointObstructed(x, z, hx, hz)
    if g_currentMission == nil or g_currentMission.terrainRootNode == nil or FollowCombineTask == nil or overlapBox == nil then
        return false
    end
    local halfWidth = self:getTrainWidth() / 2 + 0.3
    local height = PathFinderModule.getTrainHeight(self.vehicle) + PathFinderModule.OBSTACLE_HEIGHT_MARGIN
    local angleRad = AutoDrive.normalizeAngle(math.atan2(-hz, hx))
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z)
    local probe = {hits = 0, callback = FollowCombineTask.lineCollisionCallback}
    overlapBox(x, y + height / 2, z, 0, angleRad, 0, PathFinderModule.REAR_PROBE_HALF_LENGTH, height / 2, halfWidth, "callback", probe, AutoDrive.collisionMaskTerrain, true, true, true, true)
    if probe.hits > 0 then
        return true
    end
    return self:boxHitsBlockedZone(x, z, angleRad, PathFinderModule.REAR_PROBE_HALF_LENGTH, halfWidth)
end

-- the whole train standing at x, z heading hx, hz (tractor at the point, the trailer behind it): no fixed obstacle
function PathFinderModule:isRearTrainBoxFree(x, z, hx, hz)
    if g_currentMission == nil or g_currentMission.terrainRootNode == nil or FollowCombineTask == nil or overlapBox == nil then
        return true
    end
    local length = math.max(6, AutoDrive.getTractorTrainLength(self.vehicle, true, false))
    local halfWidth = self:getTrainWidth() / 2 + 0.3
    local height = PathFinderModule.getTrainHeight(self.vehicle) + PathFinderModule.OBSTACLE_HEIGHT_MARGIN
    local angleRad = AutoDrive.normalizeAngle(math.atan2(-hz, hx))
    local cx, cz = x - hx * (length / 2 - 3), z - hz * (length / 2 - 3)
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 1, cz)
    local probe = {hits = 0, callback = FollowCombineTask.lineCollisionCallback}
    overlapBox(cx, y + height / 2, cz, 0, angleRad, 0, length / 2, height / 2, halfWidth, "callback", probe, AutoDrive.collisionMaskTerrain, true, true, true, true)
    if probe.hits > 0 then
        return false
    end
    return not self:boxHitsBlockedZone(cx, cz, angleRad, length / 2, halfWidth)
end

-- the train fits at x, z: centre on the field, no crop over its half width
function PathFinderModule:isRearPointFree(x, z, half)
    if PathFinderModule.getMapOnFieldAt(x, z) ~= true then
        return false
    end
    local n = math.ceil(half / 0.5)
    for j = -n, n do
        for i = -n, n do
            local dx, dz = i * 0.5, j * 0.5
            if dx * dx + dz * dz <= half * half + 0.001 then
                local crop = PathFinderModule.getMapCropAt(x + dx, z + dz)
                if crop ~= nil and crop ~= 0 then
                    return false
                end
            end
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Point sur la trace de la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- the point behind a forage harvester on the track it really drove (23/10: in a curve the straight line
-- behind it falls in the crop). Its recorded track first, then the cut ground behind it meter by meter.
-- Returns x, z, the harvester direction there, the distance along the track and where it comes from; nil if none

PathFinderModule.REAR_TRAIL_SEARCH = 25 -- m further back when the point is in crop
PathFinderModule.REAR_WALK_ANGLES = {0, 10, -10, 20, -20, 30, -30, 45, -45}
PathFinderModule.REAR_TRAIL_MAX_COS = math.cos(math.rad(45))
-- forage harvester standing (full, it waits): its trail counts only while it stays on its heading axis. Stopped right
-- after its U-turn the last 20 m of trail are the end of the arc (25/10 11:53: the Puma was sent 20 m back on
-- that arc, 13 m beside the axis and 41 deg off, arrived on the wrong side and planned the same point for ever)
PathFinderModule.REAR_TRAIL_MAX_COS_STANDING = math.cos(math.rad(15))
PathFinderModule.REAR_TRAIL_MAX_LATERAL_STANDING = 3 -- m from its heading axis
PathFinderModule.REAR_WALK_ANGLES_STANDING = {0, 10, -10} -- deg from its heading axis, not from the previous step
PathFinderModule.STANDING_SPEED = 0.0003 -- lastSpeedReal (m/ms) under which the harvester stands
function PathFinderModule.isCombineStanding(combine)
    if combine == nil then
        return false
    end
    if math.abs(combine.lastSpeedReal or 0) < PathFinderModule.STANDING_SPEED then
        return true
    end
    return combine.ad ~= nil and combine.ad.noMovementTimer ~= nil and (combine.ad.noMovementTimer.elapsedTime or 0) > 1000
end
function PathFinderModule:getRearTarget(combine, back, rx, rz)
    local x, _, z = getWorldTranslation(combine.components[1].node)
    local half = self:getCropHalfWidth()
    local maxD = back + PathFinderModule.REAR_TRAIL_SEARCH
    local points = {}
    local px, pz, d, hx, hz = x, z, 0, rx, rz
    local trail = combine.ad ~= nil and combine.ad.chopperTrail or {}
    local fromTrail = 0
    local standing = PathFinderModule.isCombineStanding(combine)
    local maxCos = standing and PathFinderModule.REAR_TRAIL_MAX_COS_STANDING or PathFinderModule.REAR_TRAIL_MAX_COS
    local trailCut = false
    local first = #trail
    while first > 0 and (trail[first].x - x) * rx + (trail[first].z - z) * rz > -1 do
        first = first - 1
    end
    for i = first, 1, -1 do
        local t = trail[i]
        local seg = MathUtil.vector2Length(px - t.x, pz - t.z)
        if seg > 0.01 then
            local sx, sz = (px - t.x) / seg, (pz - t.z) / seg
            -- the trail before its last turn (end-of-row U-turn, 23/10): not the row it works now, stop there
            -- standing (25/10): off its heading axis is the end of its U-turn arc, stop there, straight on behind
            if sx * rx + sz * rz < maxCos
                or (standing and math.abs((t.x - x) * rz - (t.z - z) * rx) > PathFinderModule.REAR_TRAIL_MAX_LATERAL_STANDING) then
                if standing then
                    trailCut = true
                    hx, hz = rx, rz
                end
                break
            end
            hx, hz = sx, sz
            local n = math.ceil(seg)
            for k = 1, n do
                local f = k / n
                points[#points + 1] = {x = px + (t.x - px) * f, z = pz + (t.z - pz) * f, hx = hx, hz = hz, d = d + seg * f}
            end
            d = d + seg
            px, pz = t.x, t.z
            fromTrail = d
            if d >= maxD then
                break
            end
        end
    end
    -- short track (just started, game loaded): on over the cut ground behind
    -- standing harvester (25/10): the walk keeps its heading axis, no curve back onto its U-turn arc
    local angles = standing and PathFinderModule.REAR_WALK_ANGLES_STANDING or PathFinderModule.REAR_WALK_ANGLES
    -- 25/10 19:14: the walk stops at the first fixed obstacle (hedge, trees, wall), nothing is aimed beyond it
    local obstacleD, offFieldD = nil, nil
    while d < maxD do
        local found, obstacle, offField = false, false, false
        local bhx, bhz = hx, hz
        if standing then
            bhx, bhz = rx, rz
        end
        for _, a in ipairs(angles) do
            local c, s = math.cos(math.rad(a)), math.sin(math.rad(a))
            local bx, bz = -bhx * c - -bhz * s, -bhx * s + -bhz * c
            local qx, qz = px + bx, pz + bz
            if self:isRearPointFree(qx, qz, half) then
                if self:isRearPointObstructed(qx, qz, -bx, -bz) then
                    obstacle = true
                else
                    hx, hz = -bx, -bz
                    px, pz, d = qx, qz, d + 1
                    points[#points + 1] = {x = px, z = pz, hx = hx, hz = hz, d = d}
                    found = true
                    break
                end
            elseif a == 0 and PathFinderModule.getMapOnFieldAt(qx, qz) ~= true then
                offField = true
            end
        end
        if not found then
            if obstacle then
                obstacleD = d + 1
            elseif offField then
                offFieldD = d + 1
            end
            break
        end
    end
    local minD = (combine.size ~= nil and combine.size.length or 10) / 2 + 4
    local best = nil
    for _, p in ipairs(points) do
        if p.d >= back and self:isRearPointFree(p.x, p.z, half) and self:isRearTrainBoxFree(p.x, p.z, p.hx, p.hz) then
            best = p
            break
        end
    end
    if best == nil then
        for i = #points, 1, -1 do
            local p = points[i]
            if p.d < back and p.d >= minD and self:isRearPointFree(p.x, p.z, half) and self:isRearTrainBoxFree(p.x, p.z, p.hx, p.hz) then
                best = p
                break
            end
        end
    end
    local limit = nil
    if obstacleD ~= nil then
        limit = string.format("obstacle a %.0f m derriere elle", obstacleD)
    elseif offFieldD ~= nil then
        limit = string.format("bord du champ a %.0f m derriere elle", offFieldD)
    end
    if best == nil then
        return nil, nil, nil, nil, nil, limit or string.format("aucun point libre sur %.0f m (culture ou attelage gene)", d)
    end
    local source = fromTrail >= best.d and "sur sa trace" or (fromTrail > 0 and "trace puis sol coupe" or "sol coupe derriere elle")
    if trailCut then
        source = source .. " (ensileuse arretee, sa trace finit en virage : dans l'axe de son cap)"
    end
    if best.d < back and limit ~= nil then
        source = source .. string.format(" (%s, place rapprochee)", limit)
    end
    return best.x, best.z, best.hx, best.hz, best.d, source
end

PathFinderModule.TRAIL_ON_DISTANCE = 4
function PathFinderModule.getTrailDirectionAt(combine, x, z)
    local trail = combine.ad ~= nil and combine.ad.chopperTrail or nil
    if trail == nil or #trail < 2 then
        return nil
    end
    local best, bestD = nil, PathFinderModule.TRAIL_ON_DISTANCE
    for i = 2, #trail do
        local d = MathUtil.vector2Length(trail[i].x - x, trail[i].z - z)
        if d < bestD then
            best, bestD = i, d
        end
    end
    if best == nil then
        return nil
    end
    local a, b = trail[best - 1], trail[best]
    local l = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
    if l < 0.01 then
        return nil
    end
    return (b.x - a.x) / l, (b.z - a.z) / l
end

-- ------------------------------------------------------------------------------------------------------------
-- Secours : derrière la moissonneuse (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.REAR_UTURN_EXTRA = 5 -- m
PathFinderModule.ANTICIPATED_MAX_AGE = 60000 -- ms
function PathFinderModule:startRearFallback()
    local combine = self.pipeCombine
    if self.rearFallbackDone or not self.goingToPipe or combine == nil or combine.components == nil or not (self.strictFruit or self.strictField) then
        return false
    end
    -- only to catch a harvester that drives: behind a stopped one the trailer cannot reach the pipe, nothing takes over there
    local stopped = (combine.lastSpeedReal or 0) < 0.0002
        or (combine.ad ~= nil and combine.ad.noMovementTimer ~= nil and combine.ad.noMovementTimer.elapsedTime > 1000)
    -- forage harvester: behind it even when it stands, it drives on once its unloader is there
    if stopped and not (combine.ad ~= nil and combine.ad.isChopper) then
        if not self.rearFallbackSkippedPrinted then
            self.rearFallbackSkippedPrinted = true
            print(string.format("[AD-Fin] %s: moissonneuse arretee, je vise directement la buse (pas derriere)", self:getLogName()))
        end
        return false
    end
    local x, y, z = getWorldTranslation(combine.components[1].node)
    local rx, rz = self:getWorkingDirection(combine)
    local back = (combine.size ~= nil and combine.size.length or 10) / 2 + PathFinderModule.REAR_FALLBACK_GAP + AutoDrive.getTractorTrainLength(self.vehicle, true, false) / 2
    local wrongWayNeed = nil
    -- tractor facing the other way (after the harvester's end-of-row U-turn, 23/10): the target leaves room for
    -- its own U-turn beyond where it stands, so it arrives the right way round the first time
    if combine.ad ~= nil and combine.ad.isChopper then
        -- from where this piece starts (end of the piece being driven, 23/10: the next piece began 12 m from the
        -- target and had no room to turn)
        local vx, _, vz, hx, hz = self:getStartPose()
        if hx * rx + hz * rz < 0 then
            local behind = (x - vx) * rx + (z - vz) * rz
            local radius = AutoDrive.getDriverRadius(self.vehicle) or 8
            -- 25/10 16:35: more room each time the train arrived the wrong way round at the same place (CatchCombinePipeTask.tryWrongWayTurn)
            local extra = self.vehicle.ad.turnRoomExtra or 0
            local need = behind + 2 * radius + PathFinderModule.REAR_UTURN_EXTRA + extra
            if need > back then
                print(string.format("[AD-Fin] %s: tracteur a contresens, point vise recule a %.0f m (place pour son demi-tour, rayon %.0f m%s)", self:getLogName(), need, radius, extra > 0 and string.format(", %.0f m de plus apres des arrivees a l'envers", extra) or ""))
                back = need
                wrongWayNeed = need
            end
        end
    end
    local target = {x = x - rx * back, y = y, z = z - rz * back}
    local arrive = {x = rx, z = rz}
    local where = "ligne droite (aucun point libre sur sa trace)"
    -- end-of-row U-turn anticipated (23/10): behind the entry of the next row read on the Courseplay course,
    -- the nearest free place on the cut ground going back from the wanted distance
    local anticipated = false
    local ant = self.vehicle.ad.anticipatedRear
    if ant ~= nil and (g_time or 0) - ant.t < PathFinderModule.ANTICIPATED_MAX_AGE and combine.ad ~= nil and combine.ad.isChopper then
        local half = self:getCropHalfWidth()
        local minD = (combine.size ~= nil and combine.size.length or 10) / 2 + 4
        for d = ant.back, minD, -1 do
            local px, pz = ant.ex - ant.dx * d, ant.ez - ant.dz * d
            if self:isRearPointFree(px, pz, half) then
                target = {x = px, y = y, z = pz}
                arrive = {x = ant.dx, z = ant.dz}
                back = d
                where = string.format("demi-tour anticipe, %.0f m derriere l'entree du nouveau rang", d)
                anticipated = true
                break
            end
        end
        if not anticipated then
            print(string.format("[AD-Fin] %s: demi-tour anticipe : aucune place libre derriere l'entree du rang, place derriere l'ensileuse", self:getLogName()))
            self.vehicle.ad.anticipatedRear = nil
        end
    end
    if combine.ad ~= nil and combine.ad.isChopper and not anticipated then
        local tx, tz, thx, thz, td, source = self:getRearTarget(combine, back, rx, rz)
        -- (25/10) behind a harvester standing with its back to a hedge there
        -- is no place. The 7R aimed 20 m behind it, in the hedge, for 8 minutes: without a place the side place is aimed
        if tx == nil then
            self.rearPlaceNone = true
            if not self.rearNonePrinted then
                self.rearNonePrinted = true
                print(string.format("[AD-Fin] %s: aucune place libre derriere l'ensileuse (%s, %.0f m voulus) : je vise la place a cote d'elle", self:getLogName(), tostring(source), back))
            end
            return false
        end
        -- facing the other way with less room behind her than the U-turn needs: not aimed either (the turn comes first)
        if wrongWayNeed ~= nil and td < wrongWayNeed - 2 then
            self.rearPlaceNone = true
            if not self.rearNonePrinted then
                self.rearNonePrinted = true
                print(string.format("[AD-Fin] %s: tracteur a contresens, place derriere l'ensileuse a %.0f m seulement (%.0f m voulus pour mon demi-tour, %s) : je vise la place a cote d'elle, demi-tour d'abord", self:getLogName(), td, wrongWayNeed, tostring(source)))
            end
            return false
        end
        self.rearPlaceNone = nil
        target = {x = tx, y = y, z = tz}
        arrive = {x = thx, z = thz}
        where = string.format("%s, %.0f m", source, td)
    end
    local allowPartial = self.allowPartialPath
    local fruitToCheck = self.fruitToCheck
    print(string.format("[AD-Fin] %s: je vais derriere la moissonneuse (%.0f,%.0f, cap %.0f deg) : moissonneuse en %.0f,%.0f cap %.0f deg, %.0f m derriere, %s", self:getLogName(), target.x, target.z, math.deg(math.atan2(arrive.x, arrive.z)), x, z, math.deg(math.atan2(rx, rz)), back, where))
    self:startPathPlanningTo(target, arrive)
    -- behind the harvester is cut ground: no crop allowed near the target, the whole route judged
    self.goingBehind = true
    self.goingToPipe = true
    self.pipeCombine = combine
    self.fruitToCheck = fruitToCheck
    self.allowPartialPath = allowPartial
    self.rearFallbackDone = true
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Au départ vers la goulotte : loin d'elle, derrière elle d'abord
-- ------------------------------------------------------------------------------------------------------------
-- far from the harvester: aim at its rear first, its own cut track always leads there; the chase takes over close to it
-- forage harvester: always from behind, at any distance, the chase takes over there
-- accroche de startPathPlanningToPipe
function PathFinderModule:startRearFirst(combine, chasing)
    if not chasing and combine.ad ~= nil and (self.strictFruit or self.strictField)
        and (combine.ad.isChopper or AutoDrive.getDistanceBetween(self.vehicle, combine) > PathFinderModule.REAR_FIRST_DISTANCE) then
        self:startRearFallback()
    end
end
