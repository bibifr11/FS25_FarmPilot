-- ============================================================================================================
-- FarmPilot : PathFinderModuleEdge.lua
-- Complément de PathFinderModule : ensileuse, voie du déchargeur précédent et suivi du bord de la culture.
-- - Voie du précédent : la trace roulée par le déchargeur précédent jusqu'à l'ensileuse (gardée par l'ensileuse) est
--   reprise là où elle passe près du train, chaque tronçon recontrôlé (culture aux pneus, champ, obstacles).
-- - Suivi du bord : dans les endroits très étroits (une bande coupée où un seul train passe), le trajet suit le bord
--   de la culture à écart fixe au lieu de la grille (les cases coupent une bande en biais en escalier) ; il finit
--   près de l'ensileuse (la poursuite prend le relais), là où le bord est perdu ou la bande bouchée.
-- - 2e déchargeur : vise une miette du 1er (le point et le sens de la trace) au lieu d'un point derrière lui.
--
-- Historique :
-- - 23/10 (strict) : un virage que le train ne peut pas prendre n'est jamais coupé, le trajet s'arrête avant ;
-- - 25/10 14:21 (6205 TTV : 194 m de voie suivie en rond, sa fin à 77 m de l'ensileuse) : la fin de la voie à 40 m
--   au plus de l'ensileuse ;
-- - 25/10 16:30 : le 2e déchargeur vise une miette du 1er ;
-- - 25/10 19:14 (7R : morceaux de bord jusqu'à 135 m de l'ensileuse) : un morceau doit rapprocher de la cible ;
-- - 27/10 20:46 (MF 7S.210, 9 échecs en 2 min dans l'entrée, grille bloquée à 8 m dans une bande de 9 m) : le
--   suiveur affine la grille comme tout trajet et suit d'abord le bord vers sa miette ;
-- - virages : aucun seuil de largeur, anticiper davantage, côté extérieur avant le virage
--   (extérieur, intérieur, extérieur), pas plus d'écart que nécessaire, aussi loin que le champ le permet.
--
-- Règle : seulement pour l'ensileuse en strict ; sinon la grille d'AutoDrive.
--
-- Branché par PathFinderModule.lua : startPathPlanningToPipe (tryLaneOrEdge) ; startPathPlanningToFollow et
-- edgeCropAt par DriveToVehicleTask.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- 2e déchargeur : vers les miettes du 1er
-- ------------------------------------------------------------------------------------------------------------
-- 25/10 16:30: the 2nd unloader aims a crumb of the 1st (the point and the trail direction there) instead of a
-- point behind the 1st (DriveToVehicleTask)
function PathFinderModule:startPathPlanningToFollow(targetVehicle, targetPoint, targetVector)
    PathFinderModule.debugMsg(self.vehicle, "PathFinderModule:startPathPlanningToFollow %s", tostring(targetVehicle:getName()))
    self:startPathPlanningTo({x = targetPoint.x, y = targetPoint.y, z = targetPoint.z}, {x = targetVector.x, z = targetVector.z})
    self.goingToPipe = false
    self.pipeCombine = nil
    self.chasingVehicle = true
    self.isSecondChasingVehicle = true
    if targetVehicle.ad ~= nil and targetVehicle.ad.pathFinderModule ~= nil and targetVehicle.ad.pathFinderModule.fruitToCheck ~= nil then
        self.fruitToCheck = targetVehicle.ad.pathFinderModule.fruitToCheck
    end
    -- 27/10 20:46 (MF 7S.210, 9 failures in 2 min in the entrance, grid stuck at 8 m cells in a 9 m strip):
    -- the follower may refine the grid like any other trip, and follows the crop edge first (toward its crumb)
    self.followingTrack = true
    self.edgeGoal = {x = targetPoint.x, z = targetPoint.z}
    self:tryEdgeFollow()
end

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester, very narrow places only (a cut strip where a single train fits): the route follows the crop edge
-- at a fixed gap instead of the grid (cells cut a diagonal strip into stairs, the route zigzags or finds no way).
-- Line by line every EDGE_STEP meters: the crop edge is searched beside the line (0.5 m map), the route point is put
-- EDGE_GAP + half the tyre width away from it on the free side, turning no sharper than the train can. It ends close
-- to the harvester (the chase takes over), where the edge is lost or the strip blocked; the grid is used otherwise.
PathFinderModule.EDGE_STEP = 2
PathFinderModule.EDGE_GAP = 0.5            -- m between the tyres and the first crop row
PathFinderModule.EDGE_SCAN = 8             -- m beside the line where the crop edge is searched
PathFinderModule.EDGE_FREE_SCAN = 15       -- m on the free side to measure the strip
PathFinderModule.EDGE_NARROW_FACTOR = 2    -- narrow: strip narrower than this many trains (body width + margin)
PathFinderModule.EDGE_MAX_LENGTH = 300
PathFinderModule.EDGE_MIN_LENGTH = 10
PathFinderModule.EDGE_NO_GAIN_LENGTH = 20  -- m driven without getting closer to the harvester: stop
PathFinderModule.EDGE_STOP_OVERRUN = 4
PathFinderModule.EDGE_CORNER_MARGIN = 1 -- m added to the gap around a corner
PathFinderModule.EDGE_CORNER_MIN_ROOM = 6 -- m of cut ground behind a corner, else it is no way for the train
PathFinderModule.EDGE_TURN_MIN_DEG = 20 -- turn of a corner before the edge is looked for along the train
PathFinderModule.EDGE_TURN_FOUND = 2 -- m beyond the gap where the edge counts as found again
PathFinderModule.EDGE_BEND_EXTRA = 10 -- m looked ahead beyond the turn radius for a bend toward the crop
PathFinderModule.EDGE_BEND_MARGIN = 0.7 -- start turning away before the last moment

PathFinderModule.EDGE_MIN_GAIN = 2 -- m closer to the target at least at the end of an edge piece (25/10 19:14)

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
function PathFinderModule:edgeCropAt(x, z)
    local crop = PathFinderModule.getMapCropAt(x, z)
    return crop ~= nil and crop ~= 0
end

-- distance (0.5 m steps) from x, z along nx, nz to the first crop sample, nil if none within maxDistance
function PathFinderModule:edgeFindCrop(x, z, nx, nz, fromDistance, maxDistance)
    local w = fromDistance
    while w <= maxDistance do
        if self:edgeCropAt(x + nx * w, z + nz * w) then
            return w
        end
        w = w + 0.5
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Voie du déchargeur précédent
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester: the track driven by the previous unloader up to the harvester (shared by the harvester), reused
-- from where it passes the train, every stretch checked again (crop at the tyres, field, obstacles such as parked trailers)
PathFinderModule.LANE_MAX_AGE = 1200000 -- ms
PathFinderModule.LANE_JOIN_DISTANCE = 6 -- m from the train to the lane
PathFinderModule.LANE_END_DISTANCE = 40 -- m: the end of the lane at most this far from the harvester (25/10 14:21)

function PathFinderModule:laneStretchClear(a, b, cropHalf)
    local dx, dz = b.x - a.x, b.z - a.z
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 0.05 then
        return true
    end
    local nx, nz = -dz / l, dx / l
    local n = math.max(1, math.ceil(l / 0.5))
    local samples = math.ceil(cropHalf * 4)
    for i = 0, n do
        local px, pz = a.x + dx * i / n, a.z + dz * i / n
        if not PathFinderModule.getMapOnFieldAt(px, pz) then
            return false
        end
        for k = 0, samples do
            local w = -cropHalf + 2 * cropHalf * k / samples
            if self:edgeCropAt(px + nx * w, pz + nz * w) then
                return false
            end
        end
    end
    return self:isStretchClear(a, b, nil, true, true)
end

function PathFinderModule:tryLane()
    if not self:isChopperWork() or not (self.strictFruit or self.strictField) or self.pipeCombine == nil or self.startX == nil then
        return false
    end
    local shared = self.pipeCombine.ad ~= nil and self.pipeCombine.ad.sharedLane or nil
    if shared == nil or (g_time or 0) - shared.time > PathFinderModule.LANE_MAX_AGE then
        return false
    end
    local lane = shared.points
    local x, _, z, hx, hz = self:getStartPose()
    local best, bestD = nil, PathFinderModule.LANE_JOIN_DISTANCE
    for i = 1, #lane - 1 do
        local d = MathUtil.vector2Length(lane[i].x - x, lane[i].z - z)
        local ldx, ldz = lane[i + 1].x - lane[i].x, lane[i + 1].z - lane[i].z
        local ll = math.sqrt(ldx * ldx + ldz * ldz)
        if d < bestD and ll > 0.1 and (ldx * hx + ldz * hz) / ll > 0.7 then
            best, bestD = i, d
        end
    end
    if best == nil then
        return false
    end
    local name = self:getLogName()
    local cropHalf = self:getCropHalfWidth()
    local cx, _, cz = getWorldTranslation(self.pipeCombine.components[1].node)
    local closeRange = CatchCombinePipeTask ~= nil and type(CatchCombinePipeTask.CLOSE_RANGE) == "number" and CatchCombinePipeTask.CLOSE_RANGE or 30
    local target = self.target or {x = cx, z = cz}
    local points = {{x = x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z), z = z}}
    -- join the lane a few meters ahead (not behind the tractor)
    local i = best
    while i < #lane and ((lane[i].x - x) * hx + (lane[i].z - z) * hz) < 3 do
        i = i + 1
    end
    local length, reason = 0, "fin de la trace"
    while i <= #lane do
        local a, b = points[#points], lane[i]
        if not self:laneStretchClear(a, b, cropHalf) then
            reason = "trace bouchee ou culture"
            break
        end
        length = length + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        points[#points + 1] = {x = b.x, y = b.y, z = b.z}
        if MathUtil.vector2Length(cx - b.x, cz - b.z) < closeRange and self:isFruitStretchClear(b, target, cropHalf) then
            reason = "ensileuse a portee, ligne droite propre"
            break
        end
        i = i + 1
    end
    if reason == "trace bouchee ou culture" then
        local cut = 0
        while #points > 2 and cut < PathFinderModule.EDGE_STOP_OVERRUN do
            local p1, p2 = points[#points - 1], points[#points]
            local l = MathUtil.vector2Length(p2.x - p1.x, p2.z - p1.z)
            cut = cut + l
            length = length - l
            table.remove(points, #points)
        end
    end
    if length < PathFinderModule.EDGE_MIN_LENGTH then
        print(string.format("[AD-Fin] %s: trace du precedent trop courte d'ici (%.0f m, %s)", name, length, reason))
        return false
    end
    -- 25/10 14:21 (6205 TTV: 194 m of lane followed in circles, its end 77 m from the harvester): the lane must
    -- lead to the harvester, its end nearer to it than the start and, when the whole lane is taken, close to it
    local last = points[#points]
    local endDistance = MathUtil.vector2Length(cx - last.x, cz - last.z)
    local startDistance = MathUtil.vector2Length(cx - x, cz - z)
    if reason ~= "ensileuse a portee, ligne droite propre"
        and (endDistance > startDistance - 5 or (reason == "fin de la trace" and endDistance > PathFinderModule.LANE_END_DISTANCE)) then
        print(string.format("[AD-Fin] %s: trace du precedent ignoree, elle ne mene pas a l'ensileuse (fin a %.0f m d'elle, depart a %.0f m, %s)", name, endDistance, startDistance, reason))
        return false
    end
    self.wayPoints = points
    self.partialPath = true
    self.isFinished = true
    self.smoothDone = true
    self.dubinsDone = true
    ADScheduler:removePathfinderVehicle(self.vehicle)
    print(string.format("[AD-Fin] %s: reprend la trace du precedent sur %.0f m (%d points, fin : %s)", name, length, #points, reason))
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Suivi du bord de la culture (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function PathFinderModule:tryEdgeFollow()
    if not self:isChopperWork() or not (self.strictFruit or self.strictField) or (self.pipeCombine == nil and self.edgeGoal == nil) or self.startX == nil then
        return false
    end
    local name = self:getLogName()
    local x, _, z, hx, hz = self:getStartPose()
    local l = math.sqrt(hx * hx + hz * hz)
    if l < 0.01 then
        return false
    end
    hx, hz = hx / l, hz / l
    local nx, nz = hz, -hx
    -- crop side: the nearer crop edge beside the train
    local cropSide, cropDistance = nil, math.huge
    for _, side in ipairs({1, -1}) do
        local d = self:edgeFindCrop(x, z, nx * side, nz * side, 0, PathFinderModule.EDGE_SCAN)
        if d ~= nil and d < cropDistance then
            cropSide, cropDistance = side, d
        end
    end
    if cropSide == nil then
        return false
    end
    -- free width of the strip: from the crop edge to the field border (or other crop) on the other side
    local sx, sz = -nx * cropSide, -nz * cropSide
    local free = 0
    while free < PathFinderModule.EDGE_FREE_SCAN do
        local px, pz = x + sx * (free + 0.5), z + sz * (free + 0.5)
        if not PathFinderModule.getMapOnFieldAt(px, pz) or self:edgeCropAt(px, pz) then
            break
        end
        free = free + 0.5
    end
    -- no width threshold: a crop edge beside the train is followed, the grid cuts strips into stairs.
    -- Never from inside the crop: every piece (also the ones planned ahead while driving) is checked in full
    local width = cropDistance + free
    if cropDistance < self:getCropHalfWidth() or free < 0.5 then
        return false
    end
    local cropHalf = self:getCropHalfWidth()
    local gap = cropHalf + PathFinderModule.EDGE_GAP
    local radius = self.realTurnRadius or self.minTurnRadius or 8
    local step = PathFinderModule.EDGE_STEP
    local maxShift = step * math.tan(math.min(step / radius, math.rad(30)))
    -- the goal: the harvester, or the follower's crumb (edgeGoal)
    local cx, cz = self.edgeGoal ~= nil and self.edgeGoal.x or 0, self.edgeGoal ~= nil and self.edgeGoal.z or 0
    if self.pipeCombine ~= nil then
        cx, _, cz = getWorldTranslation(self.pipeCombine.components[1].node)
    end
    local closeRange = CatchCombinePipeTask ~= nil and type(CatchCombinePipeTask.CLOSE_RANGE) == "number" and CatchCombinePipeTask.CLOSE_RANGE or 30
    local points = {{x = x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z), z = z}}
    local px, pz, dx, dz = x, z, hx, hz
    local length, best, sinceBest = 0, MathUtil.vector2Length(cx - x, cz - z), 0
    local reason = "longueur max"
    -- the route ends where the chase can take over: close to the harvester and a clean straight line to its target
    local target = self.target or {x = cx, z = cz}
    -- corner of the crop ahead (the edge turns away, ~90 deg): swing wide to the outer side of the strip first, then
    -- turn as tight as the train can around the corner until the edge is found again
    -- anticipate more: the train runs on the crop side all along, it must be on the outer side well before
    local lookAhead = radius + 30
    local cdx, cdz, clx, clz = nil, nil, nil, nil -- strip direction when the corner was first seen
    local cornerX, cornerZ, wideV, cornerQX, cornerQZ, cornerReach = nil, nil, nil, nil, nil, nil
    local cornerEndIndex, cutCorner = nil, false
    local corner, turned, corners = nil, 0, 0
    local bendTurns = 0
    while length < PathFinderModule.EDGE_MAX_LENGTH do
        local bx, bz = px + dx * step, pz + dz * step
        local lx, lz = dz * cropSide, -dx * cropSide -- toward the crop
        local edge = self:edgeFindCrop(bx, bz, lx, lz, -2, PathFinderModule.EDGE_SCAN)
        local shift
        if corner == nil and edge ~= nil then
            -- corner ahead: the crop edge beside the strip ends within lookAhead. The strip direction is taken over
            -- the last 10 m (one step only swings a few degrees with the 0.5 m map, far ahead that is meters)
            local sdx, sdz = dx, dz
            local back = points[math.max(cornerEndIndex or 1, #points - 5)]
            local sl = MathUtil.vector2Length(px - back.x, pz - back.z)
            if sl > 4 then
                sdx, sdz = (px - back.x) / sl, (pz - back.z) / sl
            end
            local slx, slz = sdz * cropSide, -sdx * cropSide
            local toCorner = nil
            if self:edgeFindCrop(bx + sdx * lookAhead, bz + sdz * lookAhead, slx, slz, -2, PathFinderModule.EDGE_SCAN + 4) == nil then
                for k = 1, math.ceil(lookAhead) do
                    if self:edgeFindCrop(bx + sdx * k, bz + sdz * k, slx, slz, -2, PathFinderModule.EDGE_SCAN + 4) == nil then
                        toCorner = k
                        break
                    end
                end
            end
            if toCorner ~= nil then
                corners = corners + 1
                corner = "large"
                -- corner frame: cd along the strip, cl toward the crop; the corner point lies on the crop edge
                cdx, cdz, clx, clz = sdx, sdz, slx, slz
                dx, dz, lx, lz = sdx, sdz, slx, slz
                local free = 0
                while free < PathFinderModule.EDGE_FREE_SCAN do
                    local fx, fz = bx - lx * (free + 0.5), bz - lz * (free + 0.5)
                    if not PathFinderModule.getMapOnFieldAt(fx, fz) or self:edgeCropAt(fx, fz) then
                        break
                    end
                    free = free + 0.5
                end
                cornerX, cornerZ = bx + dx * toCorner + lx * (edge - 0.5), bz + dz * toCorner + lz * (edge - 0.5)
                -- room after the corner: depth of the strip beyond it (field, no crop), measured 3 m on the far side
                local depth = 0
                while depth < 30 do
                    local fx, fz = cornerX + dx * (depth + 0.5) + lx * 3, cornerZ + dz * (depth + 0.5) + lz * 3
                    if not PathFinderModule.getMapOnFieldAt(fx, fz) or self:edgeCropAt(fx, fz) then
                        break
                    end
                    depth = depth + 0.5
                end
                cornerReach = depth - cropHalf - 0.5
                if depth < PathFinderModule.EDGE_CORNER_MIN_ROOM then
                    -- no cut ground behind the corner for the train (a narrowing gap in the crop): not a way
                    print(string.format("[AD-Fin] %s: angle dans %d m sans place apres (%.1f m), pas de virage, arret avant", name, toCorner, depth))
                    reason = "angle sans place apres"
                    break
                end
                -- swing out only as much as needed for the arc to end inside that room (not more), at most to
                -- the outer border (wheels 0.5 m inside it)
                local outer = -(free - cropHalf - 1.0) - (edge - 0.5) -- tyres 1 m inside the border (map read to 0.5 m)
                -- 1 m more than the gap: the map edge is only known to 0.5 m and the train swings a little in the arc
                local needed = -gap - PathFinderModule.EDGE_CORNER_MARGIN
                if cornerReach < radius then
                    local r2 = (radius - gap) * (radius - gap) - (radius - cornerReach) * (radius - cornerReach)
                    needed = r2 >= 0 and math.min(-gap - PathFinderModule.EDGE_CORNER_MARGIN, -radius + math.sqrt(r2)) or outer
                end
                -- on the outer side, as far as the field allows (not only what the geometry needs)
                -- (no use beyond one turn radius from the crop edge: the arc has all its room there)
                wideV = math.min(math.max(outer, -radius), -gap - PathFinderModule.EDGE_CORNER_MARGIN)
                print(string.format("[AD-Fin] %s: angle dans %d m, place apres l'angle %.1f m, ecart vers l'exterieur %.1f m", name, toCorner, depth, -wideV - gap))
            end
        end
        if corner ~= nil then
            local u = (px - cornerX) * cdx + (pz - cornerZ) * cdz
            local v = (px - cornerX) * clx + (pz - cornerZ) * clz
            if corner == "large" then
                -- turn centre beside the train toward the crop: the crop corner must stay inside the inner tyre arc
                -- (radius - gap); start halfway between the earliest and the latest start that keep it there
                -- earliest start keeping the corner inside the inner tyre arc, so the train ends close to the new edge
                local cv = v + radius
                local inner = radius - gap - PathFinderModule.EDGE_CORNER_MARGIN / 2
                local room = inner * inner - cv * cv
                if room >= 0 and u >= math.max(-math.sqrt(room), gap - radius) then
                    corner = "virage"
                end
            end
            local maxTurn = step / radius
            local function steer(tx, tz)
                -- new heading toward tx, tz, turning at most maxTurn: the point step meters ahead
                local want = math.atan2(tx, tz)
                local cur = math.atan2(dx, dz)
                local diff = want - cur
                while diff > math.pi do diff = diff - 2 * math.pi end
                while diff < -math.pi do diff = diff + 2 * math.pi end
                diff = math.max(-maxTurn, math.min(maxTurn, diff))
                local h = cur + diff
                return px + math.sin(h) * step, pz + math.cos(h) * step, math.abs(diff)
            end
            if corner == "large" then
                -- out to the wide line, back along the strip direction: aim 6 m ahead on the wide line
                local ax, az = cornerX + cdx * (u + 12) + clx * wideV, cornerZ + cdz * (u + 12) + clz * wideV
                -- the crop edge is not straight: keep the aim point the gap (plus margin) away from the crop there
                local e2 = self:edgeFindCrop(ax, az, clx, clz, -6, PathFinderModule.EDGE_SCAN)
                if e2 ~= nil and e2 - 0.5 < gap + PathFinderModule.EDGE_CORNER_MARGIN then
                    local back = gap + PathFinderModule.EDGE_CORNER_MARGIN - (e2 - 0.5)
                    ax, az = ax - clx * back, az - clz * back
                end
                cornerQX, cornerQZ = steer(ax - px, az - pz)
            else
                -- turn toward the crop as tight as the train can, until heading along cl (the other side of the corner)
                local d
                cornerQX, cornerQZ, d = steer(clx, clz)
                turned = turned + d
                -- the crop edge runs along the train again (beside it here and 4 m ahead): a bend, not a right angle
                local along = false
                if turned >= math.rad(PathFinderModule.EDGE_TURN_MIN_DEG) then
                    local e1 = self:edgeFindCrop(px, pz, dz * cropSide, -dx * cropSide, 0, gap + PathFinderModule.EDGE_TURN_FOUND)
                    local e2 = self:edgeFindCrop(px + dx * 4, pz + dz * 4, dz * cropSide, -dx * cropSide, 0, gap + PathFinderModule.EDGE_TURN_FOUND)
                    along = e1 ~= nil and e2 ~= nil and e1 - 0.5 >= gap - 0.5 and e2 - 0.5 >= gap - 0.5
                end
                if along then
                    print(string.format("[AD-Fin] %s: bord du mais retrouve le long du train apres %.0f deg, fin du virage", name, math.deg(turned)))
                end
                if along or dx * clx + dz * clz > 0.995 or turned > math.rad(120) then
                    print(string.format("[AD-Fin] %s: angle passe (%.0f deg)%s", name, math.deg(turned), cutCorner and ", coin coupe" or ""))
                    corner, turned, cutCorner = nil, 0, false
                    cornerEndIndex = #points
                    if edge == nil then
                        edge = self:edgeFindCrop(bx, bz, lx, lz, -2, PathFinderModule.EDGE_SCAN)
                    end
                    if edge ~= nil then
                        shift = math.max(-maxShift, math.min(maxShift, edge - 0.5 - gap))
                    else
                        shift = 0
                    end
                    cornerQX = nil
                end
            end
        elseif edge ~= nil then
            -- the first crop sample is up to one map sample (0.5 m) beyond the real edge: count from the sample before
            shift = math.max(-maxShift, math.min(maxShift, edge - 0.5 - gap))
            -- bend ahead with the crop on its outer side (outside, inside, outside): the edge comes closer
            -- faster than the train can turn by hugging it. Looking one turn radius ahead, the train leaves the edge
            -- in time toward the inner side of the bend, never closer to the crop meanwhile, and follows it again after
            local k = step * 2
            while k <= radius + PathFinderModule.EDGE_BEND_EXTRA do
                local ek = self:edgeFindCrop(bx + dx * k, bz + dz * k, lx, lz, -2, PathFinderModule.EDGE_SCAN)
                if ek ~= nil then
                    -- one map sample (0.5 m) of tolerance: a straight edge read on the map is not straight
                    local need = ek - 0.5 - gap + 0.5
                    if need < 0 then
                        shift = math.min(shift, 0)
                        -- side shift reachable in k meters turning at the radius, with a margin
                        if -need >= k * k / (2 * radius) * PathFinderModule.EDGE_BEND_MARGIN then
                            shift = -maxShift
                            bendTurns = bendTurns + 1
                            break
                        end
                    end
                end
                k = k + step
            end
        else
            reason = "bord du mais perdu"
            break
        end
        local qx, qz
        if corner ~= nil and cornerQX ~= nil then
            qx, qz, shift = cornerQX, cornerQZ, 0
        else
            qx, qz = bx + lx * shift, bz + lz * shift
        end
        cornerQX = nil
        -- the train at the tyres: no crop across, centre on the field, body side allowed, no obstacle
        local ok = PathFinderModule.getMapOnFieldAt(qx, qz)
        local why = ok and nil or "centre hors du champ"
        local samples = math.ceil(cropHalf * 4)
        for k = 0, samples do
            if not ok then
                break
            end
            local w = -cropHalf + 2 * cropHalf * k / samples
            for _, t in ipairs({0, 0.5}) do
                local mx, mz = qx - dx * step * t + lx * w, qz - dz * step * t + lz * w
                if self:edgeCropAt(mx, mz) then
                    if corner == "virage" and not (self.strictFruit or self.strictField) then
                        -- a corner the train cannot take is cut (crop under the inner tyres in the turn only);
                        -- strict (23/10): never, the route stops before
                        cutCorner = true
                    else
                        ok = false
                        why = string.format("mais sous le pneu en %.1f,%.1f", mx, mz)
                        break
                    end
                end
            end
        end
        if ok and self.strictField then
            local side = (self.trainHalfWidth or 2) - PathFinderModule.FRUIT_CHECK_CORRIDOR_MARGIN
            ok = self:isTrainSideAllowed(qx - lx * side, qz - lz * side) and self:isTrainSideAllowed(qx + lx * side, qz + lz * side)
            if not ok then
                why = "carrosserie hors du champ"
            end
        end
        if ok and not self:isStretchClear({x = px, z = pz}, {x = qx, z = qz}, nil, true, true) then
            ok = false
            reason = "obstacle"
        elseif not ok then
            reason = string.format("%s, %s, point %.0f,%.0f", corner ~= nil and "angle trop serre pour le train" or "bande bouchee", why or "?", qx, qz)
        end
        if PathFinderModule.EDGE_DEBUG then
            print(string.format("edge q=%.1f,%.1f corner=%s shift=%.2f edge=%s ok=%s turned=%.0f", qx, qz, tostring(corner), shift, tostring(edge), tostring(ok), math.deg(turned)))
        end
        if not ok then
            break
        end
        local sl = MathUtil.vector2Length(qx - px, qz - pz)
        dx, dz = (qx - px) / sl, (qz - pz) / sl
        px, pz = qx, qz
        length = length + sl
        points[#points + 1] = {x = qx, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, qx, 1, qz), z = qz}
        local distance = MathUtil.vector2Length(cx - qx, cz - qz)
        if distance < closeRange and corner == nil and self:isFruitStretchClear({x = qx, z = qz}, target, cropHalf) then
            reason = "ensileuse a portee, ligne droite propre"
            break
        end
        if distance < best - 0.5 or corner ~= nil then
            best, sinceBest = math.min(best, distance), 0
        else
            sinceBest = sinceBest + sl
            if sinceBest >= PathFinderModule.EDGE_NO_GAIN_LENGTH then
                reason = "ne se rapproche plus"
                break
            end
        end
    end
    if reason ~= "ensileuse a portee, ligne droite propre" and reason ~= "longueur max" then
        -- stopped short of a blocked spot: the train overruns its last point
        local cut = 0
        while #points > 2 and cut < PathFinderModule.EDGE_STOP_OVERRUN do
            local a, b = points[#points - 1], points[#points]
            cut = cut + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
            table.remove(points, #points)
            length = length - MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        end
        -- never a stop nose against the crop (same rule as the guided departure): the stop is put earlier on the
        -- route, where the train still has clean ground ahead
        local trimmed = 0
        while #points > 2 do
            local a, b = points[#points - 1], points[#points]
            local sl = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
            if sl > 0.05 and self:isGuidedStopClear(points, (b.x - a.x) / sl, (b.z - a.z) / sl) then
                break
            end
            trimmed = trimmed + sl
            table.remove(points, #points)
            length = length - sl
        end
        if trimmed > 0 then
            print(string.format("[AD-Fin] %s: suivi du bord : arret avance de %.0f m (%d m libres devant)", name, trimmed, PathFinderModule.GUIDED_EXIT_AHEAD))
        end
    end
    if length < PathFinderModule.EDGE_MIN_LENGTH then
        print(string.format("[AD-Fin] %s: bande de %.1f m, suivi du bord trop court (%.0f m, %s), grille", name, width, length, reason))
        return false
    end
    -- 25/10 19:14 (7R: edge pieces up to 135 m from the harvester): a piece that ends farther from the target
    -- than it starts leads away, it is refused
    if reason ~= "ensileuse a portee, ligne droite propre" then
        local lastP = points[#points]
        local startD = MathUtil.vector2Length(target.x - x, target.z - z)
        local endD = MathUtil.vector2Length(target.x - lastP.x, target.z - lastP.z)
        if endD > startD - PathFinderModule.EDGE_MIN_GAIN then
            print(string.format("[AD-Fin] %s: suivi du bord refuse, il m'eloigne de la cible (%.0f m au depart, %.0f m a la fin, %s), grille", name, startD, endD, reason))
            return false
        end
    end
    self.wayPoints = points
    self.partialPath = true
    self.isFinished = true
    self.smoothDone = true
    self.dubinsDone = true
    ADScheduler:removePathfinderVehicle(self.vehicle)
    print(string.format("[AD-Fin] %s: bande de %.1f m, suivi du bord du mais a %.1f m du pneu sur %.0f m (%d points, fin : %s, %d pas vers l'interieur des courbes)", name, width, PathFinderModule.EDGE_GAP, length, #points, reason, bendTurns))
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Au départ vers la goulotte : voie, sinon bord
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester: the lane of the previous unloader first, else follow the crop edge, else the grid
-- accroche de startPathPlanningToPipe
function PathFinderModule:tryLaneOrEdge(chasing)
    if not chasing and not self:tryLane() and not self:tryEdgeFollow() and self.edgeOnly then
        -- close to the harvester: no grid route there (it loops), wait and let the chase try again
        print(string.format("[AD-Fin] %s: pres de l'ensileuse, pas de suivi du bord possible, pas de grille, attente", self:getLogName()))
        self:abort()
    end
end
