-- ============================================================================================================
-- FarmPilot : CornerModuleBends.lua
-- Complément de CornerModule.lua : les virages serrés d'une route du réseau. Commun à tous les attelages.
--
-- Chaque virage serré de la route donnée (un point aigu, ou des points proches qui tournent du même côté, angles
-- additionnés, au moins BEND_MIN_ANGLE, rayon dessiné plus petit que le rayon de l'attelage) :
--   1. la route dessinée est conduite en simulation : l'attelage passe = virage gardé tel quel (08/11 : seulement
--      quand c'est nécessaire) ;
--   2. sinon, candidats arc-droite-arc d'un point avant le virage à un point après, le plus grand rayon d'abord
--      (08/11 : le plus large qui passe, gain de temps), le vrai rayon en dernier ; le premier qui passe remplace le
--      virage ;
--   3. sinon, manœuvre : arrêt à un point avant le virage, recul tout droit de REVERSE_DISTANCES m, virage pris de là
--      (point marqué cornerReverse, conduit par ADCornerModule:handle) ; (18/11) avec un outil traîné, la place pour
--      reculer est contrôlée avec REVERSE_TRAILER_MARGIN m de plus de chaque côté : il peut partir de côté ;
--   4. (15/11, portail du champ 38) « prendre large quand ça ne passe pas » : le virage est repris en débordant
--      sur l'herbe à l'extérieur du virage (SWING_DEVIATION_MAX m au plus de la route dessinée, jamais dans une
--      culture), pour entrer bien droit. Quand la route finit sur un champ juste après le virage (entrée de champ
--      par un portail), la sortie peut être prise plus loin dans le champ, dans l'axe d'arrivée : l'attelage entier
--      passe le portail avant la fin de la route (l'outil ne se déplie pas dans le portail).
--      (15/11, sortie du même portail) En miroir pour un virage à moins de FIELD_END_NEAR m du DÉBUT de la route
--      quand l'attelage part d'un champ : le virage est repris large (tout droit hors de l'entrée, à travers le
--      chemin, sur l'herbe en face, puis le virage) ; là, le champ qu'il quitte ne refuse plus ses roues (« field
--      (trailer) ») et aucune culture d'un autre champ n'est touchée ;
--   5. rien ne passe : virage gardé tel quel (log « nothing fits »).
--
-- Branché par : DrivePathModuleObstacles.lua (prepareRoute -> ADCornerModule:smoothRoute).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADCornerModule.BEND_MIN_ANGLE = math.rad(35)   -- total angle of a bend
ADCornerModule.BEND_MAX_ANGLE = math.rad(200)  -- a bend stops growing beyond (U-turn and a bit more)
ADCornerModule.POINT_MIN_ANGLE = math.rad(3)   -- a point turning less is straight
ADCornerModule.GROUP_SEGMENT_MAX = 8           -- m: points of one drawn curve are closer than this
ADCornerModule.RADIUS_FACTORS = {1.15, 1.5, 2} -- turning radius of the candidates, times the radius of the train
ADCornerModule.ENTRY_MAX = 30                  -- m of route looked at before the bend
ADCornerModule.EXIT_MAX = 30                   -- m of route looked at after the bend
ADCornerModule.POSE_SPACING = 3                -- m at least between two entry / exit points tried
ADCornerModule.POSES_MAX = 7                   -- entry / exit points tried at most
ADCornerModule.DEVIATION_MAX = 15              -- m a candidate may move away from the drawn route
ADCornerModule.DEVIATION_MAX_UTURN = 20        -- m for a U-turn (its diameter is twice the radius of the train)
ADCornerModule.UTURN_ANGLE = math.rad(150)     -- a bend turning more is a U-turn
ADCornerModule.EXTRA_TURN_MAX = math.rad(150)  -- rad a candidate may turn more than the bend
ADCornerModule.TURN_COST = 3                   -- m of cost per radian turned more than the bend
ADCornerModule.DEVIATION_COST = 2              -- m of cost per metre away from the drawn route (no short cut across the grass)
ADCornerModule.TESTS_MAX = 24                  -- candidates simulated at most per bend (and per reverse distance) at the real radius
ADCornerModule.TESTS_MAX_WIDE = 8              -- ... and at each larger radius (tried first)
ADCornerModule.WIDE_DEVIATION_MAX = 3          -- m a larger radius bend may move away from the drawn route (stays on the road)
ADCornerModule.ARC_STEP = 2.5                  -- m between two inserted points on an arc
ADCornerModule.LINE_STEP = 5                   -- m between two inserted points on a straight
ADCornerModule.SIM_TAIL = 12                   -- m simulated after the end of the bend (the trailer comes through)
ADCornerModule.REVERSE_DISTANCES = {8, 14, 20} -- m backed up before the bend (manoeuvre)
ADCornerModule.REVERSE_TRAILER_MARGIN = 1.5    -- (18/11) m de plus de chaque côté du train pour reculer avec un outil traîné
ADCornerModule.SWING_DEVIATION_MAX = 16        -- (15/11) m a wide swing may move away from the drawn route (verge, grass)
ADCornerModule.SWING_TESTS_MAX = 40            -- candidates simulated at most for the wide swing
ADCornerModule.FIELD_EXTEND_MAX = 30           -- m the end of the route may be continued into the field, in its axis
ADCornerModule.FIELD_EXTEND_STEP = 3           -- m between two points of that continuation (and of the approach)
ADCornerModule.FIELD_END_NEAR = 30             -- m: the bend ends closer than this to the end of the route (entrance)
ADCornerModule.FIELD_CLEAR_MARGIN = 3          -- m beyond the length of the train: the whole train is past the gate
ADCornerModule.SWING_APPROACH_MAX = 15         -- m before the entrance where the train may come straight into its axis

-- ------------------------------------------------------------------------------------------------------------
-- Outils (points insérés, distances à la route dessinée)
-- ------------------------------------------------------------------------------------------------------------
local function newPoint(x, z)
    return {x = x, z = z, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 300, z), isPathFinderPoint = true, isCornerPoint = true}
end

-- points of a path (start excluded, end excluded)
local function pathPoints(p, path)
    local points = {}
    local function arc(cx, cz, from, angle, s)
        local steps = math.max(1, math.ceil(angle * path.r / ADCornerModule.ARC_STEP))
        for n = 1, steps do
            local h = from + s * angle * n / steps
            points[#points + 1] = newPoint(cx - path.r * math.cos(h) * s, cz + path.r * math.sin(h) * s)
        end
    end
    if path.a1 > 1e-3 then
        arc(path.c1.x, path.c1.z, p.a, path.a1, path.s1)
    end
    if path.straight > 0.5 then
        local steps = math.max(1, math.ceil(path.straight / ADCornerModule.LINE_STEP))
        for n = 1, steps do
            local f = n / steps
            points[#points + 1] = newPoint(path.t1.x + (path.t2.x - path.t1.x) * f, path.t1.z + (path.t2.z - path.t1.z) * f)
        end
    end
    if path.a2 > 1e-3 then
        arc(path.c2.x, path.c2.z, path.heading, path.a2, path.s2)
    end
    -- the last point is the end pose itself (a route point): drop it
    if #points > 0 then
        points[#points] = nil
    end
    return points
end

-- distance from a point to a polyline
local function distanceToLine(line, x, z)
    local best = math.huge
    for n = 1, #line - 1 do
        local a, b = line[n], line[n + 1]
        local vx, vz = b.x - a.x, b.z - a.z
        local l2 = vx * vx + vz * vz
        local t = l2 > 1e-6 and math.max(0, math.min(1, ((x - a.x) * vx + (z - a.z) * vz) / l2)) or 0
        best = math.min(best, MathUtil.vector2Length(x - a.x - vx * t, z - a.z - vz * t))
    end
    return best
end

-- the route after point k of wayPoints, SIM_TAIL metres (the trailer comes through)
local function tail(wayPoints, k)
    local points, length = {}, 0
    local n = k
    while wayPoints[n + 1] ~= nil and length < ADCornerModule.SIM_TAIL do
        length = length + ADCornerModule.dist(wayPoints[n], wayPoints[n + 1])
        n = n + 1
        points[#points + 1] = wayPoints[n]
    end
    return points
end

local function append(list, items)
    for _, item in ipairs(items) do
        list[#list + 1] = item
    end
    return list
end

-- ------------------------------------------------------------------------------------------------------------
-- Repérer un virage, points d'entrée et de sortie
-- ------------------------------------------------------------------------------------------------------------
-- the bend starting at wayPoints[i] (out[#out] is the point before it): last index and total angle, nil if none
function ADCornerModule:findBend(wayPoints, i, prev)
    local list = {prev}
    local first = i
    local total, sign, last = 0, 0, nil
    local k = i
    while wayPoints[k + 1] ~= nil do
        local p, n = wayPoints[k], wayPoints[k + 1]
        local before = k == i and prev or wayPoints[k - 1]
        if not ADCornerModule.isNetworkPoint(p) or not ADCornerModule.isNetworkPoint(n) or not ADCornerModule.isNetworkPoint(before)
            or ADGraphManager:isReverseRoad(before, p) or ADGraphManager:isReverseRoad(p, n) then
            break
        end
        local turn = ADCornerModule.turnAt({before, p, n}, 2)
        if math.abs(turn) < ADCornerModule.POINT_MIN_ANGLE then
            break
        end
        local s = turn > 0 and 1 or -1
        if sign ~= 0 and s ~= sign then
            break
        end
        -- points of one curve are close together (the first one may be a single sharp point)
        if k > first and ADCornerModule.dist(before, p) > ADCornerModule.GROUP_SEGMENT_MAX then
            break
        end
        if math.abs(total + turn) > ADCornerModule.BEND_MAX_ANGLE then
            break
        end
        sign = s
        total = total + turn
        last = k
        k = k + 1
    end
    if last == nil or math.abs(total) < ADCornerModule.BEND_MIN_ANGLE then
        return nil
    end
    -- drawn radius: length of the curve (inside, plus half of the legs, 3 m at most each) / angle
    local length = math.min(3, ADCornerModule.dist(prev, wayPoints[first]) / 2) + math.min(3, ADCornerModule.dist(wayPoints[last], wayPoints[last + 1]) / 2)
    for n = first, last - 1 do
        length = length + ADCornerModule.dist(wayPoints[n], wayPoints[n + 1])
    end
    return last, total, length / math.abs(total)
end

-- entry points: indices in out (from the end), at most ENTRY_MAX metres back, spaced POSE_SPACING
function ADCornerModule:entryIndices(out, minIndex)
    local list = {#out}
    local length, sinceLast = 0, 0
    local k = #out
    while k > minIndex + 1 and #list < ADCornerModule.POSES_MAX do
        local a, b = out[k - 1], out[k]
        if not ADCornerModule.isNetworkPoint(a) or not ADCornerModule.isNetworkPoint(b) or b.isCornerPoint or ADGraphManager:isReverseRoad(a, b) then
            break
        end
        local l = ADCornerModule.dist(a, b)
        length = length + l
        sinceLast = sinceLast + l
        if length > ADCornerModule.ENTRY_MAX then
            break
        end
        k = k - 1
        if sinceLast >= ADCornerModule.POSE_SPACING and k > minIndex then
            list[#list + 1] = k
            sinceLast = 0
        end
    end
    return list
end

-- exit points: indices in wayPoints after the bend
function ADCornerModule:exitIndices(wayPoints, last)
    local list = {}
    local length, sinceLast = 0, ADCornerModule.POSE_SPACING
    local k = last
    while wayPoints[k + 2] ~= nil and #list < ADCornerModule.POSES_MAX do
        local a, b = wayPoints[k], wayPoints[k + 1]
        if not ADCornerModule.isNetworkPoint(a) or not ADCornerModule.isNetworkPoint(b) or ADGraphManager:isReverseRoad(a, b) or ADGraphManager:isReverseRoad(b, wayPoints[k + 2]) then
            break
        end
        local l = ADCornerModule.dist(a, b)
        length = length + l
        sinceLast = sinceLast + l
        if length > ADCornerModule.EXIT_MAX then
            break
        end
        k = k + 1
        if sinceLast >= ADCornerModule.POSE_SPACING then
            list[#list + 1] = k
            sinceLast = 0
        end
    end
    return list
end

-- ------------------------------------------------------------------------------------------------------------
-- Chercher un tracé qui passe (plus grand rayon d'abord), place pour reculer
-- ------------------------------------------------------------------------------------------------------------
-- distance to the drawn route of a few points of a path: tangent points, middle of the straight and of the arcs
function ADCornerModule.roughDeviation(path, drawn)
    local samples = {path.t1, path.t2, {x = (path.t1.x + path.t2.x) / 2, z = (path.t1.z + path.t2.z) / 2}}
    local function arcMiddle(c, from, angle, s)
        local h = from + s * angle / 2
        samples[#samples + 1] = {x = c.x - path.r * math.cos(h) * s, z = c.z + path.r * math.sin(h) * s}
    end
    if path.a1 > 0.1 then
        arcMiddle(path.c1, path.heading - path.s1 * path.a1, path.a1, path.s1)
    end
    if path.a2 > 0.1 then
        arcMiddle(path.c2, path.heading, path.a2, path.s2)
    end
    local deviation = 0
    for _, q in ipairs(samples) do
        deviation = math.max(deviation, distanceToLine(drawn, q.x, q.z))
    end
    return deviation
end

-- candidates from the start poses to the exit points, all together, tested by radius then by cost (added length
-- compared with the drawn route, plus the turning added, plus the distance from it); the first clear one is returned: {points, exit, start, path}
-- starts: {p = pose, point = route point at the pose, drawnBefore = metres of drawn route from it to the bend, extraCost}
-- drawnAfter[m]: metres of drawn route from the bend to the exit point m
function ADCornerModule:bestPath(starts, wayPoints, exits, drawnAfter, drawn, bendAngle, reference, swing)
    local candidates = {}
    for _, st in ipairs(starts) do
        for _, m in ipairs(exits) do
            local q = {x = wayPoints[m].x, z = wayPoints[m].z, a = ADCornerModule.segHeading(wayPoints[m], wayPoints[m + 1])}
            for rank, factor in ipairs(ADCornerModule.RADIUS_FACTORS) do
                local r = self.radius * factor
                for _, t in ipairs(ADCornerModule.TYPES) do
                    local path = ADCornerModule.arcLineArc(st.p, q, r, t[1], t[2])
                    if path ~= nil and path.turn <= math.abs(bendAngle) + ADCornerModule.EXTRA_TURN_MAX then
                        local cost = path.length - (st.drawnBefore + drawnAfter[m]) + ADCornerModule.TURN_COST * math.max(0, path.turn - math.abs(bendAngle))
                            + ADCornerModule.DEVIATION_COST * ADCornerModule.roughDeviation(path, drawn) + (st.extraCost or 0)
                        candidates[#candidates + 1] = {path = path, exit = m, start = st, cost = cost, rank = rank}
                    end
                end
            end
        end
    end
    -- 08/11 (Patriot 4450, the widest radius that fits, time saved): the widest radius first (smoother and
    -- faster bend, swinging from the outside), smaller ones when it does not fit, the real radius of the train last.
    -- Each radius has its own budget of simulations so the tight one is still tried
    local deviationMax = math.abs(bendAngle) > ADCornerModule.UTURN_ANGLE and ADCornerModule.DEVIATION_MAX_UTURN or ADCornerModule.DEVIATION_MAX
    if swing ~= nil then
        deviationMax = ADCornerModule.SWING_DEVIATION_MAX
    end
    -- (15/11) prendre large : d'abord les tracés qui s'écartent à l'extérieur du virage (1er arc dans l'autre sens),
    -- puis le reste ; chaque fois le plus grand rayon d'abord
    local bendSide = bendAngle > 0 and 1 or -1
    table.sort(candidates, function(a, b)
        if swing ~= nil and swing.preferOutward then
            local aw, bw = a.path.s1 ~= bendSide, b.path.s1 ~= bendSide
            if aw ~= bw then
                return aw
            end
        end
        if a.rank ~= b.rank then
            return a.rank > b.rank
        end
        return a.cost < b.cost
    end)
    local tested, lastReason = 0, "no path at this radius"
    local testedByRank = {}
    local wideReference = nil
    for _, c in ipairs(candidates) do
        local budget = c.rank == 1 and ADCornerModule.TESTS_MAX or ADCornerModule.TESTS_MAX_WIDE
        if swing ~= nil then
            budget = ADCornerModule.SWING_TESTS_MAX
        end
        if (testedByRank[c.rank] or 0) < budget then
            local points = pathPoints(c.start.p, c.path)
            local deviation = 0
            for _, pt in ipairs(points) do
                deviation = math.max(deviation, distanceToLine(drawn, pt.x, pt.z))
            end
            -- a larger radius than the train needs: only when it stays on the road (close to the drawn route)
            local maxDeviation = c.rank > 1 and math.min(deviationMax, ADCornerModule.WIDE_DEVIATION_MAX) or deviationMax
            local cropAt = nil
            if swing ~= nil then
                -- (15/11) prendre large : hors de la route permis, jamais dans une culture
                maxDeviation = deviationMax
                cropAt = swing.cropAt(points)
            end
            if cropAt ~= nil then
                lastReason = string.format("crop at %.0f,%.0f", cropAt.x, cropAt.z)
            elseif deviation <= maxDeviation then
                tested = tested + 1
                testedByRank[c.rank] = (testedByRank[c.rank] or 0) + 1
                local line = append(append(append({c.start.point}, points), {wayPoints[c.exit]}), tail(wayPoints, c.exit))
                local simStart = self:straightPose(c.start.p.x, c.start.p.z, c.start.p.a)
                if c.start.origin ~= nil then
                    -- (15/11) straight out of the entrance first: simulated from the entrance itself
                    line = append(append({c.start.origin}, c.start.prefix), line)
                    simStart = self:straightPose(c.start.origin.x, c.start.origin.z, c.start.p.a)
                end
                local ref = reference
                if c.rank > 1 and swing == nil then
                    wideReference = wideReference or {onField = reference.onField, onRoad = reference.onRoad, wideLine = drawn}
                    ref = wideReference
                end
                local clear, reason = self:simulate(line, simStart, ref)
                if ADCornerModule.TRACE then
                    self:log("  try r %.1f %d/%d exit %d len %.0f cost %.1f dev %.1f: %s", c.path.r, c.path.s1, c.path.s2, c.exit, c.path.length, c.cost, deviation, clear and "clear" or tostring(reason))
                end
                if clear then
                    c.points = points
                    c.deviation = deviation
                    return c, tested
                end
                lastReason = reason
            else
                lastReason = string.format("too far from the route (%.0f m)", deviation)
            end
        end
    end
    return nil, tested, lastReason
end

-- straight back from x, z (heading a) over distance: room for the whole train
-- (18/11) outil traîné : en reculant il part de côté (broyeur traîné coincé contre un lampadaire) ; ses caisses et
-- celle du tracteur sont contrôlées avec REVERSE_TRAILER_MARGIN m de plus de chaque côté. Un poteau, une clôture trop
-- près de la ligne de recul : ce recul est refusé (autre distance, sinon virage gardé). Outil porté : inchangé.
function ADCornerModule:isReverseClear(x, z, a, distance, reference)
    local s, c = math.sin(a), math.cos(a)
    local start = self:straightPose(x, z, a)
    local extra = nil
    if self.geo ~= nil and self.geo.trailer > 0 then
        extra = ADCornerModule.REVERSE_TRAILER_MARGIN
    end
    for d = 0, distance, ADCornerModule.CHECK_STEP do
        local pose = {x = start.x - s * d, z = start.z - c * d, a = a, tx = start.tx - s * d, tz = start.tz - c * d}
        local ok, reason = self:checkPose(pose, reference, true, extra)
        if not ok then
            if extra ~= nil then
                reason = string.format("%s, %.0f m back (implement: %.1f m more each side)", tostring(reason), d, extra)
            end
            return false, reason
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale : la route avec ses virages serrés remplacés
-- ------------------------------------------------------------------------------------------------------------
-- returns the route with its tight bends replaced; firstIndex: first point that may be changed
function ADCornerModule:smoothRoute(wayPoints, firstIndex)
    if not self.vehicle.isServer or wayPoints == nil or #wayPoints < 3 or not ADCornerModule.isEnabled() then
        return wayPoints
    end
    self:readTrain()
    local minOut = math.max(1, (firstIndex or 3) - 1)
    local out = {}
    for i = 1, minOut do
        out[#out + 1] = wayPoints[i]
    end
    local i = #out + 1
    local changed, manoeuvres, kept = 0, 0, 0
    while i <= #wayPoints do
        local done = false
        local prev = out[#out]
        if ADCornerModule.isNetworkPoint(prev) and not prev.isCornerPoint and wayPoints[i + 1] ~= nil then
            local last, angle, drawnRadius = self:findBend(wayPoints, i, prev)
            if last ~= nil and drawnRadius < self.radius * ADCornerModule.RADIUS_FACTORS[1] then
                local result, nextIndex = self:handleBend(wayPoints, out, i, last, angle, drawnRadius, minOut)
                if result == "path" then
                    changed = changed + 1
                elseif result == "reverse" then
                    manoeuvres = manoeuvres + 1
                else
                    kept = kept + 1
                    -- the bend stays as drawn: its points are not looked at again one by one
                    for k = i, last do
                        out[#out + 1] = wayPoints[k]
                    end
                    nextIndex = last + 1
                end
                i = nextIndex
                done = true
            end
        end
        if not done then
            out[#out + 1] = wayPoints[i]
            i = i + 1
        end
    end
    if changed > 0 or kept > 0 or manoeuvres > 0 then
        self:log("route of %d points: %d bend(s) redrawn, %d manoeuvre(s), %d kept, radius %.1f m (vehicle file %.1f, wheels %s, steering %.1f), train %.1f m wide, trailer %.1f m (%s: hitch %.1f, axle %.1f), look ahead %.1f m",
            #wayPoints, changed, manoeuvres, kept, self.radius, self.fileRadius or -1, self.wheelRadius ~= nil and string.format("%.1f", self.wheelRadius) or "?",
            self.steerRadius or self.radius, self.width, self.trailerLength, self.geoSource, self.geo.hitch, self.geo.trailer, self.lookAhead)
    end
    return out
end

-- one bend wayPoints[first .. last] after out[#out]. Returns the result ("path", "reverse" or false) and the next
-- index of wayPoints to read; out is completed when the bend is replaced
function ADCornerModule:handleBend(wayPoints, out, first, last, angle, drawnRadius, minOut)
    local prev = out[#out]
    local where = string.format("bend %d-%d (%s-%s) %.0f deg, drawn radius %.1f m at %.0f,%.0f", first, last,
        tostring(wayPoints[first].id), tostring(wayPoints[last].id), math.deg(math.abs(angle)), drawnRadius, wayPoints[first].x, wayPoints[first].z)
    local exits = self:exitIndices(wayPoints, last)
    if #exits == 0 then
        local swung, nextIndex = self:swingBend(wayPoints, out, first, last, angle, minOut, where, "no room after it")
        if swung then
            return "path", nextIndex
        end
        self:log("%s: kept as it is (no room after it)", where)
        return false, first
    end
    local entries = self:entryIndices(out, minOut)
    local exitPoint = wayPoints[exits[#exits]]
    -- (15/11) leaving a field by its entrance: the field it leaves is allowed in the wide swing only (crop checked
    -- there, swingOut), not here
    local reference = {onField = self:isOnField(prev.x, prev.z) or self:isOnField(exitPoint.x, exitPoint.z),
                       onRoad = self:isOnRoadMesh(prev.x, prev.z) and self:isOnRoadMesh(exitPoint.x, exitPoint.z)}
    -- the drawn route, from the furthest entry point to the furthest exit point
    local drawn = {}
    for k = entries[#entries], #out do
        drawn[#drawn + 1] = out[k]
    end
    for k = first, exits[#exits] do
        drawn[#drawn + 1] = wayPoints[k]
    end
    -- 1. the drawn route as the train would drive it
    local beforePrev = out[#out - 1]
    local a0 = beforePrev ~= nil and ADCornerModule.segHeading(beforePrev, prev) or ADCornerModule.segHeading(prev, wayPoints[first])
    local original = append({prev}, {})
    for k = first, exits[1] do
        original[#original + 1] = wayPoints[k]
    end
    append(original, tail(wayPoints, exits[1]))
    -- (11/11) le tracteur peut tourner le virage dessiné (rayon dessiné >= son braquage) : il suit la ligne comme
    -- AutoDrive l'a toujours fait, seul l'outil ou la remorque derrière est contrôlé (voir checkPose)
    reference.tractorFollowsLine = ADCornerModule.FOLLOW_LINE and drawnRadius >= (self.steerRadius or self.radius)
    local originalClear, originalReason = self:simulate(original, self:straightPose(prev.x, prev.z, a0), reference)
    reference.tractorFollowsLine = nil
    -- (08/11 10:13) seulement quand c'est nécessaire, pas partout ; virage gardé si son angle est bon :
    -- l'attelage passe la route dessinée = virage gardé tel quel, pas de route coupée
    if originalClear then
        self:log("%s: kept as it is (the train passes as drawn)", where)
        return false, first
    end

    -- 2. forward candidates from the entry points
    local drawnAfter = {}
    local length, k = ADCornerModule.dist(prev, wayPoints[first]), first
    for _, m in ipairs(exits) do
        while k < m do
            length = length + ADCornerModule.dist(wayPoints[k], wayPoints[k + 1])
            k = k + 1
        end
        drawnAfter[m] = length
    end
    local starts = {}
    for _, e in ipairs(entries) do
        local ep, before = out[e], out[e - 1]
        if before ~= nil then
            starts[#starts + 1] = {p = {x = ep.x, z = ep.z, a = ADCornerModule.segHeading(before, ep)}, point = ep, index = e, drawnBefore = self:lengthBack(out, e, #out)}
        end
    end
    local best, tests, lastReason = self:bestPath(starts, wayPoints, exits, drawnAfter, drawn, angle, reference)
    if best ~= nil then
        local back = best.start.drawnBefore
        self:replace(out, best.start.index, best.points)
        self:log("%s: redrawn at radius %.1f m from %.0f m before (%d points, %.0f m from the drawn line at most, %d tested; drawn route: %s)",
            where, best.path.r, back, #best.points, best.deviation, tests,
            originalClear and "would pass" or tostring(originalReason))
        return "path", best.exit
    end
    if originalClear then
        self:log("%s: kept as it is (the train passes; no smoother path: %s)", where, tostring(lastReason))
        return false, first
    end

    -- 3. (15/11) prendre large quand ça ne passe pas (avant une marche arrière)
    local swung, swingNext = self:swingBend(wayPoints, out, first, last, angle, minOut, where, originalReason)
    if swung then
        return "path", swingNext
    end

    -- 4. manoeuvre: stop at an entry point, back up straight, take the bend from there
    for _, distance in ipairs(ADCornerModule.REVERSE_DISTANCES) do
        local starts = {}
        for _, e in ipairs(entries) do
            local g, before = out[e], out[e - 1]
            if before ~= nil then
                local a = ADCornerModule.segHeading(before, g)
                local fx, fz = g.x - math.sin(a) * distance, g.z - math.cos(a) * distance
                -- backing up is useful only off the route already driven (the route before turns away)
                local behind = {}
                for k2 = math.max(1, e - 12), e do
                    behind[#behind + 1] = out[k2]
                end
                if #behind >= 2 and distanceToLine(behind, fx, fz) > 3 then
                    local clear, reason = self:isReverseClear(g.x, g.z, a, distance, reference)
                    if clear then
                        starts[#starts + 1] = {p = {x = fx, z = fz, a = a}, point = newPoint(fx, fz), index = e, g = g,
                                               drawnBefore = self:lengthBack(out, e, #out), extraCost = distance * 2}
                    else
                        lastReason = "no room to back up: " .. tostring(reason)
                    end
                end
            end
        end
        if #starts > 0 then
            local c, _, reason = self:bestPath(starts, wayPoints, exits, drawnAfter, drawn, angle, reference)
            if c ~= nil then
                local g, a = c.start.g, c.start.p.a
                local start = c.start.point
                start.cornerReverse = {gx = g.x, gz = g.z, hx = math.sin(a), hz = math.cos(a), distance = distance}
                self:replace(out, c.start.index, append({start}, c.points))
                self:log("%s: manoeuvre, stop at %s (%.0f,%.0f), back up %.0f m, then radius %.1f m (%d points; drawn route: %s)",
                    where, tostring(g.id), g.x, g.z, distance, c.path.r, #c.points, tostring(originalReason))
                return "reverse", c.exit
            end
            lastReason = reason or lastReason
        end
    end
    self:log("%s: nothing fits, kept as it is (drawn route: %s; last candidate: %s)", where, tostring(originalReason), tostring(lastReason))
    return false, first
end

-- ------------------------------------------------------------------------------------------------------------
-- (15/11) Prendre large : déborder à l'extérieur du virage, entrer droit, attelage entier dans le champ
-- ------------------------------------------------------------------------------------------------------------
-- growing crop at a point outside the field of the destination (that field is worked by the vehicle anyway)
local function cropOutside(point, ownArea)
    if ADFieldPark == nil or ADFieldPark.hasGrowingCrop == nil or not ADFieldPark.hasGrowingCrop(point.x, point.z) then
        return false
    end
    if ownArea ~= nil and PathFinderModule ~= nil and PathFinderModule.isInFieldArea ~= nil and PathFinderModule.isInFieldArea(ownArea, point.x, point.z) then
        return false
    end
    return true
end

-- (15/11) the axis of the entrance: from the end of the bend to the end of the route (unit vector), nil if too short
local function entranceAxis(wayPoints, last)
    local n = #wayPoints
    local p, e = wayPoints[last], wayPoints[n]
    if last >= n then
        p = wayPoints[n - 1]
    end
    local dx, dz = e.x - p.x, e.z - p.z
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 1 then
        return nil
    end
    return dx / l, dz / l
end

-- the bend wayPoints[first .. last] did not pass: wide swing to come straight into the axis of the end of the
-- route (the gate), then straight through it and, when the route ends on a field, on into the field until the
-- whole train is past it. Returns true and the next index of wayPoints to read
function ADCornerModule:swingBend(wayPoints, out, first, last, angle, minOut, where, originalReason)
    local prev = out[#out]
    local n = #wayPoints
    local toEnd = 0
    for k = last, n - 1 do
        toEnd = toEnd + ADCornerModule.dist(wayPoints[k], wayPoints[k + 1])
    end
    -- only an entrance at the end of the route (field gate, yard gate): the bend ends close to it ; or the way out
    -- of a field at the start of the route (the same gate the other way)
    if self:isLeavingField(wayPoints, first) then
        return self:swingOut(wayPoints, out, first, last, angle, minOut, where, originalReason)
    end
    if toEnd > ADCornerModule.FIELD_END_NEAR or n < 2 then
        return false
    end
    local ux, uz = entranceAxis(wayPoints, last)
    if ux == nil then
        return false
    end
    local p, e = wayPoints[last], wayPoints[n]
    if last >= n then
        p = wayPoints[n - 1]
    end
    local trainLength = (self.geo ~= nil and (self.geo.hitch + self.geo.trailer) or 0) + ((self.geo ~= nil and self.geo.tractorBox ~= nil and self.geo.tractorBox.front) or 3)
    -- the new end of the route: approach points on the axis before the entrance, the entrance, the end, then on into
    -- the field (on field ground) until the whole train is past the entrance
    local route = {}
    local step = ADCornerModule.FIELD_EXTEND_STEP
    local approach = {}
    local d = ADCornerModule.SWING_APPROACH_MAX
    while d >= step do
        approach[#approach + 1] = newPoint(p.x - ux * d, p.z - uz * d)
        d = d - step
    end
    for k = 1, first - 1 do
        route[k] = wayPoints[k]
    end
    local firstApproach = #route + 1
    append(route, approach)
    route[#route + 1] = p
    if e ~= p then
        route[#route + 1] = e
    end
    local endIndex = #route
    local onField = self:isOnField(e.x, e.z)
    local passed = 0
    local need = trainLength + ADCornerModule.FIELD_CLEAR_MARGIN - ADCornerModule.dist(p, e)
    if onField then
        local dd = step
        while dd <= ADCornerModule.FIELD_EXTEND_MAX and passed < need do
            local x, z = e.x + ux * dd, e.z + uz * dd
            if not self:isOnField(x, z) then
                break
            end
            route[#route + 1] = newPoint(x, z)
            passed = dd
            dd = dd + step
        end
    end
    -- exits: the approach points (the train comes straight into the axis there)
    local exits = {}
    for k = firstApproach, firstApproach + #approach - 1 do
        exits[#exits + 1] = k
    end
    local entries = self:entryIndices(out, minOut)
    local reference = {onField = self:isOnField(prev.x, prev.z) or onField, onRoad = false}
    local drawn = {}
    for k = entries[#entries], #out do
        drawn[#drawn + 1] = out[k]
    end
    for k = first, last do
        drawn[#drawn + 1] = wayPoints[k]
    end
    append(drawn, approach)
    local drawnAfter = {}
    local dl = ADCornerModule.dist(prev, wayPoints[first])
    for k = first, last - 1 do
        dl = dl + ADCornerModule.dist(wayPoints[k], wayPoints[k + 1])
    end
    for _, m in ipairs(exits) do
        drawnAfter[m] = math.max(0, dl - ADCornerModule.dist(route[m], p))
    end
    local starts = {}
    for _, en in ipairs(entries) do
        local ep, before = out[en], out[en - 1]
        if before ~= nil then
            starts[#starts + 1] = {p = {x = ep.x, z = ep.z, a = ADCornerModule.segHeading(before, ep)}, point = ep, index = en, drawnBefore = self:lengthBack(out, en, #out)}
        end
    end
    local ownArea = nil
    if onField and PathFinderModule ~= nil and PathFinderModule.getConnectedFieldArea ~= nil then
        ownArea = PathFinderModule.getConnectedFieldArea(e.x, e.z)
    end
    local swing = {preferOutward = true, cropAt = function(points)
        for _, q in ipairs(points) do
            if cropOutside(q, ownArea) then
                return q
            end
        end
        return nil
    end}
    -- the whole train goes through the entrance in the simulation
    local savedTail = ADCornerModule.SIM_TAIL
    ADCornerModule.SIM_TAIL = math.max(savedTail, ADCornerModule.SWING_APPROACH_MAX + trainLength + ADCornerModule.FIELD_CLEAR_MARGIN)
    local ok, best, tests, lastReason = pcall(self.bestPath, self, starts, route, exits, drawnAfter, drawn, angle, reference, swing)
    ADCornerModule.SIM_TAIL = savedTail
    if not ok then
        self:log("%s: wide swing error %s", where, tostring(best))
        return false
    end
    if best == nil then
        self:log("%s: wide swing tried, nothing fits (%d tested; last candidate: %s)", where, tests or 0, tostring(lastReason))
        return false
    end
    self:replace(out, best.start.index, best.points)
    for m = best.exit, #route do
        out[#out + 1] = route[m]
    end
    local tip = out[#out]
    if tip ~= e then
        -- the destination stays the same (map marker of the last point, AutoDrive reads it by its id)
        tip.id = e.id
        tip.fieldExtendedEnd = true
    end
    self:log("%s: wide swing, radius %.1f m from %.0f m before, straight into the entrance %.0f m before it (%d points, %.0f m from the drawn line at most, %d tested; drawn route: %s)%s",
        where, best.path.r, best.start.drawnBefore, ADCornerModule.dist(route[best.exit], p), #best.points, best.deviation, tests, tostring(originalReason),
        passed > 0 and string.format(", route continued %.0f m into the field (train %.0f m, all past the entrance)", passed, trainLength) or "")
    return true, n + 1
end

-- (15/11) the route starts on a field (or the vehicle stands on one) and the bend wayPoints[first] comes less than
-- FIELD_END_NEAR m after the start: the train is leaving the field through its entrance
function ADCornerModule:isLeavingField(wayPoints, first)
    local length = 0
    for k = 1, first - 1 do
        length = length + ADCornerModule.dist(wayPoints[k], wayPoints[k + 1])
    end
    if length > ADCornerModule.FIELD_END_NEAR then
        return false
    end
    for k = 1, first - 1 do
        if self:isOnField(wayPoints[k].x, wayPoints[k].z) then
            return true
        end
    end
    local v = self.vehicle
    if v ~= nil and v.components ~= nil and v.components[1] ~= nil and v.components[1].node ~= nil and getWorldTranslation ~= nil then
        local x, _, z = getWorldTranslation(v.components[1].node)
        return self:isOnField(x, z)
    end
    return false
end

-- (15/11) way out of a field by its entrance, the bend just after it does not pass: wide swing (straight across the
-- track, on the grass opposite, then the bend), never in a crop of another field. Returns true and the next index
function ADCornerModule:swingOut(wayPoints, out, first, last, angle, minOut, where, originalReason)
    local prev = out[#out]
    local exits = self:exitIndices(wayPoints, last)
    if #exits == 0 then
        return false
    end
    local entries = self:entryIndices(out, minOut)
    local reference = {onField = true, onRoad = false}
    local drawn = {}
    for k = entries[#entries], #out do
        drawn[#drawn + 1] = out[k]
    end
    for k = first, exits[#exits] do
        drawn[#drawn + 1] = wayPoints[k]
    end
    local drawnAfter = {}
    local dl, k = ADCornerModule.dist(prev, wayPoints[first]), first
    for _, m in ipairs(exits) do
        while k < m do
            dl = dl + ADCornerModule.dist(wayPoints[k], wayPoints[k + 1])
            k = k + 1
        end
        drawnAfter[m] = dl
    end
    local starts = {}
    for _, en in ipairs(entries) do
        local ep, before = out[en], out[en - 1]
        if before ~= nil then
            starts[#starts + 1] = {p = {x = ep.x, z = ep.z, a = ADCornerModule.segHeading(before, ep)}, point = ep, index = en, drawnBefore = self:lengthBack(out, en, #out)}
        end
    end
    -- straight on out of the entrance first, in its axis (across the track, onto the grass opposite), then the bend
    local before = out[#out - 1]
    if before ~= nil then
        local a = ADCornerModule.segHeading(before, prev)
        local sx, sz = math.sin(a), math.cos(a)
        local prefix = {}
        local d = ADCornerModule.FIELD_EXTEND_STEP
        while d <= ADCornerModule.SWING_APPROACH_MAX do
            local q = newPoint(prev.x + sx * d, prev.z + sz * d)
            prefix[#prefix + 1] = q
            local copy = {}
            for i2, item in ipairs(prefix) do
                copy[i2] = item
            end
            starts[#starts + 1] = {p = {x = q.x, z = q.z, a = a}, point = q, index = #out, prefix = copy, origin = prev, drawnBefore = -d}
            drawn[#drawn + 1] = q
            d = d + ADCornerModule.FIELD_EXTEND_STEP
        end
    end
    if #starts == 0 then
        return false
    end
    -- the field it leaves: its crop does not count (it was just worked there)
    local ownArea = nil
    local origin = wayPoints[1]
    if PathFinderModule ~= nil and PathFinderModule.getConnectedFieldArea ~= nil and self:isOnField(origin.x, origin.z) then
        ownArea = PathFinderModule.getConnectedFieldArea(origin.x, origin.z)
    end
    local swing = {preferOutward = false, cropAt = function(points)
        for _, q in ipairs(points) do
            if cropOutside(q, ownArea) then
                return q
            end
        end
        return nil
    end}
    local best, tests, lastReason = self:bestPath(starts, wayPoints, exits, drawnAfter, drawn, angle, reference, swing)
    if best == nil then
        self:log("%s: leaving the field, wide swing tried, nothing fits (%d tested; last candidate: %s)", where, tests or 0, tostring(lastReason))
        return false
    end
    self:replace(out, best.start.index, append(append({}, best.start.prefix or {}), best.points))
    self:log("%s: leaving the field, wide swing, %.0f m straight out first, then radius %.1f m (%d points, %.0f m from the drawn line at most, %d tested; drawn route: %s)",
        where, best.start.prefix ~= nil and ADCornerModule.dist(prev, best.start.point) or 0, best.path.r, #best.points, best.deviation, tests, tostring(originalReason))
    return true, best.exit
end

-- keeps out[1 .. keep] and adds the points
function ADCornerModule:replace(out, keep, points)
    for k = #out, keep + 1, -1 do
        out[k] = nil
    end
    append(out, points)
end

function ADCornerModule:lengthBack(out, from, to)
    local length = 0
    for k = from, math.min(to, #out) - 1 do
        length = length + ADCornerModule.dist(out[k], out[k + 1])
    end
    return length
end
