-- ============================================================================================================
-- FarmPilot : CombineUnloaderModeCourseplay.lua
-- Complément de CombineUnloaderMode : lecture du parcours Courseplay de l'ENSILEUSE (benne qui roule à côté),
-- pour que la benne anticipe ses virages. Ne concerne pas la moissonneuse.
--
-- Historique :
-- - 23/10 : l'ensileuse roule droit, virage, droit, virage : le virage à venir et son côté sont lus sur le parcours ;
--   l'entrée du rang suivant après le demi-tour de bout de rang (pour lancer notre demi-tour en même temps) ;
-- - 24/10 : un décrochement (coude franc puis retour au cap) n'est pas un demi-tour ;
-- - 24/10 : point rouge = début du demi-tour de bout de rang, point vert = sa fin, lus
--   avec les fonctions de Courseplay (isTurnStartAtIx, isHeadlandTurnAtIx, contexte du virage en cours).
--
-- Règle : lecture seule, protégée par pcall ; nil (et la raison) quand le parcours ne se lit pas.
--
-- Utilisé par : CombineUnloaderModeChopperChase.lua, FollowCombineTask.lua, CatchCombinePipeTask.lua,
-- HandleHarvesterTurnTaskHarvesterWay.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Entrée du rang suivant
-- ------------------------------------------------------------------------------------------------------------
-- Courseplay course: where the next row starts after the end-of-row U-turn (23/10: start our own U-turn at the
-- same time). First waypoint whose heading is reversed from the current row and stays so for ROW_ENTRY_STRAIGHT m.
-- Returns x, z of that waypoint and the new row direction, or nil
CombineUnloaderMode.ROW_ENTRY_REVERSED = 165 -- deg from the current row
CombineUnloaderMode.ROW_ENTRY_STRAIGHT = 10 -- m
CombineUnloaderMode.ROW_ENTRY_MAX = 150 -- m of course read
function CombineUnloaderMode.getCpRowEntry(combine)
    CombineUnloaderMode.cpRowEntryWhy = nil
    local ok, ex, ez, dx, dz = pcall(function()
        local strategy = combine.getCpDriveStrategy ~= nil and combine:getCpDriveStrategy() or nil
        if strategy == nil or strategy.getCurrentCourse == nil or strategy.ppc == nil then
            return nil
        end
        local course = strategy:getCurrentCourse()
        local ix = strategy.ppc:getCurrentWaypointIx()
        if course == nil or ix == nil then
            return nil
        end
        local n = course:getNumberOfWaypoints()
        local px, _, pz = course:getWaypointPosition(ix)
        local h0, dist, maxD = nil, 0, 0
        local cand, candDist = nil, 0
        for i = ix + 1, n do
            local x, _, z = course:getWaypointPosition(i)
            local seg = MathUtil.vector2Length(x - px, z - pz)
            if seg > 0.1 then
                local h = math.atan2(x - px, z - pz)
                if h0 == nil then
                    h0 = h
                end
                local d = math.abs(math.deg(AutoDrive.normalizeAngle(h - h0)))
                if d > 180 then
                    d = 360 - d
                end
                maxD = math.max(maxD, d)
                if d >= CombineUnloaderMode.ROW_ENTRY_REVERSED then
                    if cand == nil then
                        cand = {x = px, z = pz, dx = (x - px) / seg, dz = (z - pz) / seg}
                        candDist = 0
                    end
                    candDist = candDist + seg
                    if candDist >= CombineUnloaderMode.ROW_ENTRY_STRAIGHT then
                        return cand.x, cand.z, cand.dx, cand.dz
                    end
                else
                    cand = nil
                end
                dist = dist + seg
                px, pz = x, z
                if dist > CombineUnloaderMode.ROW_ENTRY_MAX then
                    break
                end
            end
        end
        if cand ~= nil and (dist <= CombineUnloaderMode.ROW_ENTRY_MAX) then
            -- the course (Courseplay turn course) ends already reversed: its end is the row entry
            return cand.x, cand.z, cand.dx, cand.dz
        end
        CombineUnloaderMode.cpRowEntryWhy = string.format("aucune entree de rang trouvee (point %d/%d, %.0f m lus, ecart max %.0f deg)", ix, n, dist, maxD)
        return nil
    end)
    if not ok then
        CombineUnloaderMode.cpRowEntryWhy = "erreur de lecture du parcours : " .. tostring(ex)
        return nil
    end
    return ex, ez, dx, dz
end

-- ------------------------------------------------------------------------------------------------------------
-- Virage à venir sur le parcours
-- ------------------------------------------------------------------------------------------------------------
-- Courseplay's own course ahead of the harvester (23/10: it drives straight, turn, straight, turn): heading change
-- over the next `ahead` m and the side (1 left, -1 right in the harvester frame), distance to the first bend. nil if unknown
function CombineUnloaderMode.getCpTurnAhead(combine, ahead)
    local ok, angle, side, bendAt = pcall(function()
        local strategy = combine.getCpDriveStrategy ~= nil and combine:getCpDriveStrategy() or nil
        if strategy == nil or strategy.getCurrentCourse == nil or strategy.ppc == nil then
            return nil
        end
        local course = strategy:getCurrentCourse()
        local ix = strategy.ppc:getCurrentWaypointIx()
        if course == nil or ix == nil then
            return nil
        end
        local n = course:getNumberOfWaypoints()
        local x0, _, z0 = course:getWaypointPosition(ix)
        local px, pz, dist = x0, z0, 0
        local h0 = nil
        local maxTurn, firstBend = 0, nil
        local endX, endZ = x0, z0
        for i = ix + 1, n do
            local x, _, z = course:getWaypointPosition(i)
            local seg = MathUtil.vector2Length(x - px, z - pz)
            if seg > 0.1 then
                local h = math.atan2(x - px, z - pz)
                if h0 == nil then
                    h0 = h
                end
                local d = math.abs(math.deg(AutoDrive.normalizeAngle(h - h0)))
                if d > 180 then
                    d = 360 - d
                end
                if d > maxTurn then
                    maxTurn = d
                end
                if firstBend == nil and d >= 20 then
                    firstBend = dist
                end
                dist = dist + seg
                px, pz = x, z
                endX, endZ = x, z
                if dist >= ahead then
                    break
                end
            end
        end
        local cx, cy, cz = getWorldTranslation(combine.components[1].node)
        local lx = AutoDrive.worldToLocal(combine, endX, cy, endZ, combine.ad.ADRootNode)
        return maxTurn, lx >= 0 and 1 or -1, firstBend
    end)
    if not ok then
        return nil
    end
    return angle, side, bendAt
end

-- ------------------------------------------------------------------------------------------------------------
-- Décrochement du parcours
-- ------------------------------------------------------------------------------------------------------------
-- jog in the course (24/10, a small odd-shaped jog): Courseplay bends hard and comes back to its
-- heading within JOG_AHEAD m. Not a U-turn: the unloader goes behind the harvester until the course is straight
CombineUnloaderMode.JOG_AHEAD = 50 -- m of course read
CombineUnloaderMode.JOG_MIN_DEG = 45 -- deviation from the harvester heading that makes a jog
CombineUnloaderMode.JOG_END_DEG = 35 -- end of the read course back within this of the harvester heading
CombineUnloaderMode.JOG_WITHIN = 20 -- m: first bend that close
CombineUnloaderMode.JOG_STRAIGHT_AHEAD = 15 -- m straight ahead again: back beside it
CombineUnloaderMode.JOG_STRAIGHT_DEG = 15
CombineUnloaderMode.JOG_MIN_TIME = 4000 -- ms behind at least

-- max deviation and end deviation (deg) of the course ahead from the harvester heading, distance to the first bend
function CombineUnloaderMode.getCpCourseShape(combine, ahead)
    local ok, maxDev, endDev, bendAt = pcall(function()
        local strategy = combine.getCpDriveStrategy ~= nil and combine:getCpDriveStrategy() or nil
        if strategy == nil or strategy.getCurrentCourse == nil or strategy.ppc == nil then
            return nil
        end
        local course = strategy:getCurrentCourse()
        local ix = strategy.ppc:getCurrentWaypointIx()
        if course == nil or ix == nil then
            return nil
        end
        local hx, _, hz = AutoDrive.localDirectionToWorld(combine, 0, 0, 1, combine.ad.ADRootNode)
        local hc = math.atan2(hx, hz)
        local n = course:getNumberOfWaypoints()
        local px, _, pz = course:getWaypointPosition(ix)
        local dist, maxD, lastD, firstBend = 0, 0, 0, nil
        for i = ix + 1, n do
            local x, _, z = course:getWaypointPosition(i)
            local seg = MathUtil.vector2Length(x - px, z - pz)
            if seg > 0.1 then
                local d = math.abs(math.deg(AutoDrive.normalizeAngle(math.atan2(x - px, z - pz) - hc)))
                if d > 180 then
                    d = 360 - d
                end
                maxD = math.max(maxD, d)
                lastD = d
                if firstBend == nil and d >= 20 then
                    firstBend = dist
                end
                dist = dist + seg
                px, pz = x, z
                if dist >= ahead then
                    break
                end
            end
        end
        return maxD, lastD, firstBend
    end)
    if not ok then
        return nil
    end
    return maxDev, endDev, bendAt
end

function CombineUnloaderMode.isCpJogAhead(combine)
    local maxDev, endDev, bendAt = CombineUnloaderMode.getCpCourseShape(combine, CombineUnloaderMode.JOG_AHEAD)
    return maxDev ~= nil and maxDev >= CombineUnloaderMode.JOG_MIN_DEG and endDev <= CombineUnloaderMode.JOG_END_DEG
        and bendAt ~= nil and bendAt <= CombineUnloaderMode.JOG_WITHIN, maxDev, endDev, bendAt
end

-- ------------------------------------------------------------------------------------------------------------
-- Points rouge et vert du demi-tour de bout de rang
-- ------------------------------------------------------------------------------------------------------------
-- Courseplay turn points (24/10: red point = start of the end-of-row U-turn, green
-- point = its end), read on its fieldwork course with its own functions (isTurnStartAtIx, isHeadlandTurnAtIx, the
-- turn context while it turns). A jog or a loop around a power pole has none. nil and the reason when they cannot be
-- read (the course shape is used then), else a table: ix (current waypoint), turning (Courseplay in a turn), startIx
-- and endIx (red and green points of the next turn or of the one being driven), dist (m of course before the red
-- point, 0 in the turn), deg (heading change of that turn), headland (headland corner), uTurn (end-of-row U-turn)
CombineUnloaderMode.CP_ROW_TURN_READ = 120 -- m of course read for the next red point
CombineUnloaderMode.CP_ROW_TURN_UTURN_DEG = 150 -- heading change of a turn counted as an end-of-row U-turn
function CombineUnloaderMode.getCpRowTurn(combine)
    if combine == nil or combine.ad == nil then
        return nil, "pas d'ensileuse"
    end
    local now = g_time or 0
    local cache = combine.ad.cpRowTurnCache
    if cache ~= nil and cache.t == now then
        return cache.res, cache.why
    end
    local ok, res, why = pcall(CombineUnloaderMode.readCpRowTurn, combine)
    if not ok then
        why = "erreur de lecture des points Courseplay : " .. tostring(res)
        res = nil
    end
    combine.ad.cpRowTurnCache = {t = now, res = res, why = why}
    return res, why
end

-- heading (rad) of the course next to waypoint i: arriving at it (step -1) or leaving it (step 1), measured over
-- CP_ROW_TURN_BASE m of course (the row before the red point, the row after the green point)
CombineUnloaderMode.CP_ROW_TURN_BASE = 8
function CombineUnloaderMode.getCpHeadingAt(course, i, step, n)
    local x0, _, z0 = course:getWaypointPosition(i)
    local lx, lz = nil, nil
    for k = 1, 10 do
        local j = i + step * k
        if j < 1 or j > n then
            break
        end
        local x, _, z = course:getWaypointPosition(j)
        if MathUtil.vector2Length(x - x0, z - z0) > 0.5 then
            lx, lz = x, z
        end
        if MathUtil.vector2Length(x - x0, z - z0) >= CombineUnloaderMode.CP_ROW_TURN_BASE then
            break
        end
    end
    if lx == nil then
        return nil
    end
    if step < 0 then
        return math.atan2(x0 - lx, z0 - lz)
    end
    return math.atan2(lx - x0, lz - z0)
end

function CombineUnloaderMode.isCpRowEndAt(course, i)
    if course.getWaypoint == nil then
        return false
    end
    local wp = course:getWaypoint(i)
    return wp ~= nil and wp.isRowEnd ~= nil and wp:isRowEnd() == true
end

function CombineUnloaderMode.readCpRowTurn(combine)
    local strategy = combine.getCpDriveStrategy ~= nil and combine:getCpDriveStrategy() or nil
    if strategy == nil then
        return nil, "pas de conduite Courseplay"
    end
    local course = strategy.getFieldworkCourse ~= nil and strategy:getFieldworkCourse() or nil
    course = course or strategy.fieldWorkCourse
    if course == nil or course.isTurnStartAtIx == nil or course.getNumberOfWaypoints == nil or course.getWaypointPosition == nil
        or course.getCurrentWaypointIx == nil then
        return nil, "parcours Courseplay sans points de demi-tour"
    end
    local n = course:getNumberOfWaypoints()
    local ix = course:getCurrentWaypointIx()
    if n == nil or n < 3 or ix == nil then
        return nil, "point courant du parcours Courseplay inconnu"
    end
    local res = {ix = ix, turning = strategy.isTurning ~= nil and strategy:isTurning() == true, uTurn = false}
    local tc = strategy.turnContext
    if res.turning and tc ~= nil and tc.turnStartWpIx ~= nil and tc.turnEndWpIx ~= nil then
        -- in its turn: the points of that turn (a row finish only has start = end, no U-turn)
        res.startIx, res.endIx, res.dist = tc.turnStartWpIx, tc.turnEndWpIx, 0
    else
        local px, _, pz = course:getWaypointPosition(ix)
        local dist = 0
        for i = math.max(1, ix), n - 1 do
            if i > ix then
                local x, _, z = course:getWaypointPosition(i)
                dist = dist + MathUtil.vector2Length(x - px, z - pz)
                px, pz = x, z
            end
            if dist > CombineUnloaderMode.CP_ROW_TURN_READ then
                break
            end
            -- red point; or a row end handed to its pathfinder (next row starting at an island): the same U-turn
            local rowEnd = not course:isTurnStartAtIx(i) and CombineUnloaderMode.isCpRowEndAt(course, i)
            if rowEnd or course:isTurnStartAtIx(i) then
                res.startIx, res.endIx, res.dist, res.byPathfinder = i, i + 1, dist, rowEnd
                break
            end
        end
    end
    if res.startIx == nil then
        res.why = string.format("pas de point rouge sur %d m (point %d/%d)", CombineUnloaderMode.CP_ROW_TURN_READ, ix, n)
        return res
    end
    if res.endIx <= res.startIx and res.startIx < n and CombineUnloaderMode.isCpRowEndAt(course, res.startIx) then
        -- row finish before its pathfinder: the turn goes to the next waypoint (next row start)
        res.endIx, res.byPathfinder = res.startIx + 1, true
    end
    if res.endIx <= res.startIx or res.endIx > n then
        res.why = string.format("fin de rang sans demi-tour (point %d)", res.startIx)
        return res
    end
    res.headland = course.isHeadlandTurnAtIx ~= nil and course:isHeadlandTurnAtIx(res.endIx) == true
    local hIn = CombineUnloaderMode.getCpHeadingAt(course, res.startIx, -1, n)
    local hOut = CombineUnloaderMode.getCpHeadingAt(course, res.endIx, 1, n)
    if hIn ~= nil and hOut ~= nil then
        local d = math.abs(math.deg(hOut - hIn)) % 360
        if d > 180 then
            d = 360 - d
        end
        res.deg = d
    end
    res.uTurn = not res.headland and res.deg ~= nil and res.deg >= CombineUnloaderMode.CP_ROW_TURN_UTURN_DEG
    res.sx, _, res.sz = course:getWaypointPosition(res.startIx)
    res.ex, _, res.ez = course:getWaypointPosition(res.endIx)
    res.why = string.format("point rouge %d %s, point vert %d, %s%s%s", res.startIx, res.turning and "passe (virage en cours)" or string.format("a %.0f m", res.dist),
        res.endIx, res.deg ~= nil and string.format("%.0f deg", res.deg) or "cap inconnu", res.headland and ", angle de fourriere" or "",
        res.byPathfinder and ", fin de rang par chemin calcule" or "")
    return res
end
