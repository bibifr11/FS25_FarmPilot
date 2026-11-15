-- ============================================================================================================
-- FarmPilot : PathFinderModuleCorners.lua
-- Complément de PathFinderModule : les virages du trajet trouvé sur une grille plus fine.
-- La grille fine fait des angles plus serrés que le véhicule ne peut tourner : ils sont remplacés par des arcs du
-- vrai rayon. Un angle trop court pour son arc est fusionné avec les suivants qui tournent du même côté ; sans place,
-- l'angle est gardé (et compté « trop serré » au-delà de CORNER_SHARP_ANGLE).
-- Ensileuse en strict : un angle sans place sur la ligne du trajet est pris comme un chauffeur, extérieur, intérieur,
-- extérieur (avant un virage à droite le train s'écarte à gauche, coupe l'angle au rayon et revient sur la ligne).
--
-- Historique : virage large (extérieur, intérieur, extérieur) ;
-- pour l'ensileuse : un angle gardé jusqu'à 60° est roulé, le train peut le couper.
--
-- Règle : chaque arc est contrôlé (obstacles, culture dans les bandes) avant d'être pris.
--
-- (15/11) bande étroite en biais (champ 58, benne de moissonneuse) : en cases de 2 m la grille fait un escalier de pas
-- à 45/90 deg que le lissage ne redresse pas ; ces « virages » n'existent pas. Le trajet est d'abord lissé par une
-- moyenne glissante le long du couloir (chaque tronçon contrôlé comme le trajet final, sinon le tracé d'origine est
-- gardé là), puis les virages sont jugés sur la courbure réelle (cap gagné sur une longueur) et non sur les pas.
--
-- Branché par PathFinderModuleVerify.lua (checkSmoothedPath : roundCornersToTurnRadius, smoothAlongCorridor,
-- findTightCurves).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.CORNER_MIN_ANGLE = math.rad(8)
PathFinderModule.CORNER_MAX_ANGLE = math.rad(150)
PathFinderModule.CORNER_MAX_MERGE = 4
PathFinderModule.CORNER_ARC_STEP = 2.5
PathFinderModule.CORNER_INNER_MARGIN = 1.5
-- a corner that could not be rounded to the real turn radius and turns more than this cannot be driven by the train
PathFinderModule.CORNER_SHARP_ANGLE = math.rad(30)
-- forage harvester: a corner kept up to this angle is driven, the train may cut it
PathFinderModule.CORNER_SHARP_ANGLE_CHOPPER = math.rad(60)

-- forage harvester, strict: a corner without room on the route line is driven as a driver would, outside, inside,
-- outside: before a right turn the train first swings left, cuts the corner at the turn radius, ends
-- on the left of the next line and comes back to it. The swing angles before and after are tried from the smallest.
PathFinderModule.WIDE_SWING_ANGLES = {0, 8, 16, 24} -- deg away from the turn
PathFinderModule.WIDE_SWING_LEADS = {6, 12} -- m of the line used for the swing, before and after the normal arc
PathFinderModule.WIDE_MAX_ANGLE = math.rad(170) -- whole turn of the wide arc
PathFinderModule.WIDE_MAX_CHECKS = 40 -- full checks (obstacles) per corner, keeps the frame time low
PathFinderModule.WIDE_BAND_LOOKUP = 1.5 -- m: a point of the wide corner must have a point of the strips this close

-- ------------------------------------------------------------------------------------------------------------
-- Virage large (extérieur, intérieur, extérieur)
-- ------------------------------------------------------------------------------------------------------------
function PathFinderModule:useWideCorners()
    -- (15/11) aussi pour la benne de moissonneuse en strict, grille fine (tour de la pointe d'un champ, champ 58)
    return (self:isChopperWork() or self.partialAlongRoute == true) and (self.strictFruit or self.strictField)
end

-- cheap check before the obstacle boxes: the point is in the cut strips the whole train fits in
function PathFinderModule:isWidePointInBand(x, z)
    if not self:isBandFloodReady() or self.startX == nil then
        return true
    end
    if MathUtil.vector2Length(x - self.startX, z - self.startZ) < PathFinderModule.VERIFY_SKIP_START then
        return true
    end
    return ADBandRoute.getDistance(self.bandFlood, x, z, PathFinderModule.WIDE_BAND_LOOKUP) ~= nil
end

function PathFinderModule:isWideLineInBand(a, b)
    local l = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
    local n = math.max(1, math.ceil(l / 2))
    for j = 0, n do
        if not self:isWidePointInBand(a.x + (b.x - a.x) * j / n, a.z + (b.z - a.z) * j / n) then
            return false
        end
    end
    return true
end

-- corner between the line from last through pi (d1) and the line through pk to nextPoint (d2), turning theta.
-- Returns the arc points, the swing start and the swing end (points to add to the route), nil when none is clean
function PathFinderModule:findWideCorner(last, pi, pk, nextPoint, d1, d2, theta, cross, radius, moreCorners, newPoint)
    local sign = cross > 0 and 1 or -1
    local function inside(d)
        if sign > 0 then
            return {x = -d.z, z = d.x}
        end
        return {x = d.z, z = -d.x}
    end
    local n1, n2 = inside(d1), inside(d2)
    local denom = d1.x * d2.z - d1.z * d2.x
    if math.abs(denom) < 0.001 then
        return nil
    end
    local s = ((pk.x - pi.x) * d2.z - (pk.z - pi.z) * d2.x) / denom
    local vx, vz = pi.x + d1.x * s, pi.z + d1.z * s
    local baseTangent = radius * math.tan(theta / 2)
    -- room on the lines: from the last kept point to the corner, from the corner to the next point
    local inRoom = (vx - last.x) * d1.x + (vz - last.z) * d1.z
    local outRoom = (nextPoint.x - vx) * d2.x + (nextPoint.z - vz) * d2.z
    if moreCorners then
        outRoom = outRoom * 0.5
    end
    if inRoom < 1 or outRoom < 1 then
        return nil
    end
    local options = {}
    for _, a1 in ipairs(PathFinderModule.WIDE_SWING_ANGLES) do
        for _, a2 in ipairs(PathFinderModule.WIDE_SWING_ANGLES) do
            if (a1 > 0 or a2 > 0) and theta + math.rad(a1 + a2) <= PathFinderModule.WIDE_MAX_ANGLE then
                for n, l1 in ipairs(PathFinderModule.WIDE_SWING_LEADS) do
                    for m, l2 in ipairs(PathFinderModule.WIDE_SWING_LEADS) do
                        -- no swing on a side: its lead does not matter
                        if (a1 > 0 or n == 1) and (a2 > 0 or m == 1) then
                            options[#options + 1] = {a1 = a1, a2 = a2, l1 = l1, l2 = l2, cost = a1 + a2 + (l1 + l2) * 0.1}
                        end
                    end
                end
            end
        end
    end
    table.sort(options, function(o1, o2) return o1.cost < o2.cost end)
    local checks = 0
    for _, o in ipairs(options) do
        if checks >= PathFinderModule.WIDE_MAX_CHECKS then
            break
        end
        local a1, a2 = math.rad(o.a1), math.rad(o.a2)
        local back = math.min(baseTangent + o.l1, inRoom)
        local ahead = math.min(baseTangent + o.l2, outRoom)
        local q1 = {x = vx - d1.x * back, z = vz - d1.z * back}
        local q2 = {x = vx + d2.x * ahead, z = vz + d2.z * ahead}
        -- swing out before the corner (away from the turn), come back from outside after it
        local e1 = {x = d1.x * math.cos(a1) - n1.x * math.sin(a1), z = d1.z * math.cos(a1) - n1.z * math.sin(a1)}
        local e2 = {x = d2.x * math.cos(a2) + n2.x * math.sin(a2), z = d2.z * math.cos(a2) + n2.z * math.sin(a2)}
        local denomE = e1.x * e2.z - e1.z * e2.x
        if math.abs(denomE) > 0.001 then
            local t = ((q2.x - q1.x) * e2.z - (q2.z - q1.z) * e2.x) / denomE
            local wx, wz = q1.x + e1.x * t, q1.z + e1.z * t
            local theta2 = math.acos(math.max(-1, math.min(1, e1.x * e2.x + e1.z * e2.z)))
            local tangent = radius * math.tan(theta2 / 2)
            local t1 = {x = wx - e1.x * tangent, z = wz - e1.z * tangent}
            local t2 = {x = wx + e2.x * tangent, z = wz + e2.z * tangent}
            local geometryOk = t > 0 and math.abs(theta2 - (theta + a1 + a2)) < 0.05
                and ((t1.x - q1.x) * e1.x + (t1.z - q1.z) * e1.z) >= 0
                and ((q2.x - t2.x) * e2.x + (q2.z - t2.z) * e2.z) >= 0
            local arc = nil
            if geometryOk then
                local p = inside(e1)
                local cx, cz = t1.x + p.x * radius, t1.z + p.z * radius
                local a0 = math.atan2(t1.z - cz, t1.x - cx)
                local sweep = sign * theta2
                local steps = math.max(2, math.ceil(theta2 * radius / PathFinderModule.CORNER_ARC_STEP))
                arc = {newPoint(t1.x, t1.z, pi)}
                for j = 1, steps do
                    local a = a0 + sweep * j / steps
                    arc[#arc + 1] = newPoint(cx + math.cos(a) * radius, cz + math.sin(a) * radius, pk)
                end
                local inBand = self:isWideLineInBand(q1, t1) and self:isWideLineInBand(arc[#arc], q2)
                for j = 1, #arc do
                    if not inBand then
                        break
                    end
                    inBand = self:isWidePointInBand(arc[j].x, arc[j].z)
                end
                if inBand then
                    checks = checks + 1
                    local qp1, qp2 = newPoint(q1.x, q1.z, pi), newPoint(q2.x, q2.z, pk)
                    local clear = self:isStretchClear(last, qp1) and self:isStretchClear(qp1, arc[1])
                        and self:isStretchClear(arc[#arc], qp2) and self:isStretchClear(qp2, nextPoint)
                    for j = 2, #arc do
                        if not clear then
                            break
                        end
                        local midX, midZ = (arc[j - 1].x + arc[j].x) / 2, (arc[j - 1].z + arc[j].z) / 2
                        local l = math.max(0.01, MathUtil.vector2Length(cx - midX, cz - midZ))
                        clear = self:isStretchClear(arc[j - 1], arc[j], {x = (cx - midX) / l, z = (cz - midZ) / l})
                    end
                    if clear then
                        print(string.format("[AD-Fin] %s: virage exterieur-interieur-exterieur vers %.0f,%.0f (%.0f deg) : ecart %d deg avant, %d deg apres", self:getLogName(), vx, vz, math.deg(theta), o.a1, o.a2))
                        return arc, qp1, qp2
                    end
                end
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Virages arrondis au rayon réel (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function PathFinderModule:getSharpCornerAngle()
    return self:isChopperWork() and PathFinderModule.CORNER_SHARP_ANGLE_CHOPPER or PathFinderModule.CORNER_SHARP_ANGLE
end

-- the finer grid makes corners tighter than the vehicle can turn: replace them by arcs of the real radius
-- a corner too short for its arc is merged with the next corners turning the same way; no room -> corner kept
function PathFinderModule:roundCornersToTurnRadius()
    local wps = self.wayPoints
    if wps == nil or #wps < 3 then
        return
    end
    local radius = self.realTurnRadius or self.minTurnRadius
    local function unit(from, to)
        local dx, dz = to.x - from.x, to.z - from.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 0.01 then
            return nil
        end
        return {x = dx / l, z = dz / l}, l
    end
    local function newPoint(x, z, template)
        local p = {x = x, z = z, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z)}
        if template ~= nil then
            p.direction = template.direction
        end
        return p
    end

    local out = {wps[1]}
    local last = wps[1]
    local rounded, kept, sharp = 0, 0, 0
    local wide = 0
    local useWide = self:useWideCorners()
    self.firstSharpIndex = nil
    local i = 2
    while i <= #wps - 1 do
        local d1 = unit(wps[i - 1], wps[i])
        local done = false
        if d1 ~= nil then
            local turnSign = nil
            local wideCandidates = {}
            for k = i, math.min(i + PathFinderModule.CORNER_MAX_MERGE - 1, #wps - 1) do
                local d2 = unit(wps[k], wps[k + 1])
                if d2 == nil then
                    break
                end
                local cross = d1.x * d2.z - d1.z * d2.x
                local dot = math.max(-1, math.min(1, d1.x * d2.x + d1.z * d2.z))
                local theta = math.acos(dot)
                -- every merged corner must turn the same way
                local localCross = 0
                local dPrev = unit(wps[k - 1], wps[k])
                if dPrev ~= nil then
                    localCross = dPrev.x * d2.z - dPrev.z * d2.x
                end
                if math.abs(localCross) > 0.01 then
                    local sign = localCross > 0 and 1 or -1
                    if turnSign == nil then
                        turnSign = sign
                    elseif sign ~= turnSign then
                        break
                    end
                end
                if theta < PathFinderModule.CORNER_MIN_ANGLE then
                    if k == i then
                        break
                    end
                elseif theta > PathFinderModule.CORNER_MAX_ANGLE then
                    break
                else
                    -- virtual corner: incoming line through wps[i] (d1) crosses the outgoing line through wps[k] (d2)
                    local denom = d1.x * d2.z - d1.z * d2.x
                    if math.abs(denom) > 0.001 then
                        local wx, wz = wps[k].x - wps[i].x, wps[k].z - wps[i].z
                        local s = (wx * d2.z - wz * d2.x) / denom
                        local vx, vz = wps[i].x + d1.x * s, wps[i].z + d1.z * s
                        wideCandidates[#wideCandidates + 1] = {k = k, theta = theta, cross = cross, d2 = d2}
                        local tangent = radius * math.tan(theta / 2)
                        local t1 = {x = vx - d1.x * tangent, z = vz - d1.z * tangent}
                        local t2 = {x = vx + d2.x * tangent, z = vz + d2.z * tangent}
                        local nextPoint = wps[k + 1]
                        -- the arc must start after the last kept point and end before the next point (half way if more corners follow)
                        local beforeOk = ((t1.x - last.x) * d1.x + (t1.z - last.z) * d1.z) >= 0
                        local _, outLength = unit({x = vx, z = vz}, nextPoint)
                        local outRoom = outLength or 0
                        if k + 1 < #wps then
                            outRoom = outRoom * 0.5
                        end
                        local afterOk = ((nextPoint.x - vx) * d2.x + (nextPoint.z - vz) * d2.z) > 0 and tangent <= outRoom
                        if beforeOk and afterOk then
                            local perpX, perpZ = -d1.z, d1.x
                            if cross < 0 then
                                perpX, perpZ = d1.z, -d1.x
                            end
                            local cx, cz = t1.x + perpX * radius, t1.z + perpZ * radius
                            local a0 = math.atan2(t1.z - cz, t1.x - cx)
                            local sweep = (cross > 0 and 1 or -1) * theta
                            local steps = math.max(2, math.ceil(theta * radius / PathFinderModule.CORNER_ARC_STEP))
                            local arc = {newPoint(t1.x, t1.z, wps[i])}
                            for n = 1, steps do
                                local a = a0 + sweep * n / steps
                                arc[#arc + 1] = newPoint(cx + math.cos(a) * radius, cz + math.sin(a) * radius, wps[k])
                            end
                            local clear = self:isStretchClear(last, arc[1]) and self:isStretchClear(arc[#arc], nextPoint)
                            for n = 2, #arc do
                                if not clear then
                                    break
                                end
                                local midX, midZ = (arc[n - 1].x + arc[n].x) / 2, (arc[n - 1].z + arc[n].z) / 2
                                local toCentreX, toCentreZ = cx - midX, cz - midZ
                                local toCentreLength = math.sqrt(toCentreX * toCentreX + toCentreZ * toCentreZ)
                                local inner = {x = toCentreX / toCentreLength, z = toCentreZ / toCentreLength}
                                clear = self:isStretchClear(arc[n - 1], arc[n], inner)
                            end
                            if clear then
                                for _, p in ipairs(arc) do
                                    out[#out + 1] = p
                                end
                                last = arc[#arc]
                                rounded = rounded + 1
                                i = k + 1
                                done = true
                                break
                            end
                        end
                    end
                end
            end
            -- no room for the arc on the route line: outside, inside, outside
            if not done and useWide then
                for _, c in ipairs(wideCandidates) do
                    local arc, q1, q2 = self:findWideCorner(last, wps[i], wps[c.k], wps[c.k + 1], d1, c.d2, c.theta, c.cross, radius, c.k + 1 < #wps, newPoint)
                    if arc ~= nil then
                        -- no double point where the swing starts at the last point or ends at the next one
                        if MathUtil.vector2Length(q1.x - last.x, q1.z - last.z) > 0.5 then
                            out[#out + 1] = q1
                        end
                        for _, p in ipairs(arc) do
                            out[#out + 1] = p
                        end
                        last = arc[#arc]
                        if MathUtil.vector2Length(q2.x - wps[c.k + 1].x, q2.z - wps[c.k + 1].z) > 0.5 then
                            out[#out + 1] = q2
                            last = q2
                        end
                        rounded = rounded + 1
                        wide = wide + 1
                        i = c.k + 1
                        done = true
                        break
                    end
                end
            end
        end
        if not done then
            local d2 = unit(wps[i], wps[i + 1])
            if d1 ~= nil and d2 ~= nil then
                local theta = math.acos(math.max(-1, math.min(1, d1.x * d2.x + d1.z * d2.z)))
                if theta >= PathFinderModule.CORNER_MIN_ANGLE then
                    kept = kept + 1
                end
                if theta > self:getSharpCornerAngle() then
                    sharp = sharp + 1
                    if self.firstSharpIndex == nil then
                        self.firstSharpIndex = #out + 1
                    end
                end
            end
            out[#out + 1] = wps[i]
            last = wps[i]
            i = i + 1
        end
    end
    out[#out + 1] = wps[#wps]
    self.wayPoints = out
    print(string.format("[AD-Fin] %s: virages arrondis a %.1f m : %d (dont %d exterieur-interieur-exterieur), angles gardes (pas la place) : %d, dont trop serres (> %.0f deg) : %d", self:getLogName(), radius, rounded, wide, kept, math.deg(self:getSharpCornerAngle()), sharp))
    return kept, sharp
end

-- ------------------------------------------------------------------------------------------------------------
-- (15/11) Lissage le long du couloir et courbure réelle (benne de moissonneuse, strict)
-- ------------------------------------------------------------------------------------------------------------
-- en cases fines, une bande en biais donne un escalier de pas de grille (45/90 deg tous les 2 m) : moyenne glissante
-- sur CORRIDOR_SMOOTH_HALF m de chaque côté (CORRIDOR_SMOOTH_PASSES fois), chaque tronçon lissé contrôlé comme le trajet
-- final (obstacles, culture, bord du champ) ; là où il ne passe pas, le tracé d'origine est gardé
PathFinderModule.CORRIDOR_SMOOTH_STEP = 1 -- m entre deux points du trajet lissé
PathFinderModule.CORRIDOR_SMOOTH_HALF = 4 -- m de chaque côté (fenêtre de 8 m)
PathFinderModule.CORRIDOR_SMOOTH_PASSES = 2
PathFinderModule.CORRIDOR_SMOOTH_ROUNDS = 4 -- reprises locales vers le tracé d'origine quand un tronçon ne passe pas
-- courbure réelle : sur toute longueur L du trajet, le cap ne tourne pas plus que L / rayon + TIGHT_CURVE_SLACK (un
-- angle seul jusqu'à 30 deg se coupe de moins de 0,5 m au rayon de 9 m, comme CORNER_SHARP_ANGLE)
PathFinderModule.TIGHT_CURVE_SLACK = math.rad(30)

-- benne de moissonneuse (pas l'ensileuse : ses règles restent celles du 21/10), strict, grille fine
function PathFinderModule:useCorridorSmoothing()
    return self.goingToPipe == true and not self:isChopperWork() and (self.strictFruit or self.strictField)
        and self.gridScaleStep ~= nil and self.gridScaleStep > 1
end

function PathFinderModule:smoothAlongCorridor()
    local wps = self.wayPoints
    if wps == nil or #wps < 4 then
        return false
    end
    -- le couloir est celui des cases trouvées (self.path) : les raccourcis du lissage précédent jugent la culture sur
    -- une largeur plus grande (une pointe de culture fine y passe, refusée ensuite par le contrôle du trajet)
    if self.isNewPF and self.path ~= nil and #self.path >= 4 then
        local cells = {}
        for i, cell in ipairs(self.path) do
            local p = self:gridLocationToWorldLocation(cell)
            cells[i] = {x = p.x, z = p.z, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p.x, 1, p.z), direction = cell.direction}
        end
        -- même départ et même arrivée que le trajet lissé
        cells[1] = wps[1]
        if MathUtil.vector2Length(cells[#cells].x - wps[#wps].x, cells[#cells].z - wps[#wps].z) > 0.5 then
            cells[#cells + 1] = wps[#wps]
        else
            cells[#cells] = wps[#wps]
        end
        wps = cells
    end
    local step = PathFinderModule.CORRIDOR_SMOOTH_STEP
    -- points tous les STEP m le long du trajet ; le départ (2 premiers points) et l'approche (2 derniers) ne bougent pas
    local dense = {}
    local fixedTo, fixedFrom = 0, math.huge
    for i = 1, #wps - 1 do
        local a, b = wps[i], wps[i + 1]
        if i == 2 then
            fixedTo = #dense + 1
        end
        if i == #wps - 1 then
            fixedFrom = #dense + 1
        end
        local l = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        local n = math.max(1, math.floor(l / step + 0.5))
        for k = 0, n - 1 do
            dense[#dense + 1] = {x = a.x + (b.x - a.x) * k / n, z = a.z + (b.z - a.z) * k / n, template = k == 0 and a or b}
        end
    end
    dense[#dense + 1] = {x = wps[#wps].x, z = wps[#wps].z, template = wps[#wps]}
    -- seule l'arrivée est fixe : la case de grille avant elle fait souvent un crochet
    fixedFrom = #dense
    local n = #dense
    if fixedFrom - fixedTo < 4 then
        return false
    end
    -- le chemin de la grille longe le bord intérieur de la bande (plus court) : chaque point est d'abord ramené vers
    -- le milieu de la place libre en travers (culture, autre champ, obstacles), comme un chauffeur
    local centred = self:centreInCorridor(dense, fixedTo, fixedFrom)
    -- moyenne glissante (fenêtre raccourcie près des bouts fixes pour rester centrée)
    local half = math.max(1, math.floor(PathFinderModule.CORRIDOR_SMOOTH_HALF / step + 0.5))
    local sx, sz = {}, {}
    for i = 1, n do
        sx[i], sz[i] = dense[i].x, dense[i].z
    end
    for _ = 1, PathFinderModule.CORRIDOR_SMOOTH_PASSES do
        local nx, nz = {}, {}
        for i = 1, n do
            if i <= fixedTo or i >= fixedFrom then
                nx[i], nz[i] = sx[i], sz[i]
            else
                local h = math.min(half, i - fixedTo, fixedFrom - i)
                local ax, az = 0, 0
                for k = i - h, i + h do
                    ax, az = ax + sx[k], az + sz[k]
                end
                nx[i], nz[i] = ax / (2 * h + 1), az / (2 * h + 1)
            end
        end
        sx, sz = nx, nz
    end
    -- part du lissage gardée par point : 1, puis vers le tracé d'origine là où un tronçon ne passe pas
    local share = {}
    for i = 1, n do
        share[i] = 1
    end
    local function pointAt(i)
        local p = dense[i]
        local f = share[i]
        local x, z = p.x + (sx[i] - p.x) * f, p.z + (sz[i] - p.z) * f
        return {x = x, z = z, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z), direction = p.template.direction}
    end
    local points = {}
    local reverted = 0
    for round = 1, PathFinderModule.CORRIDOR_SMOOTH_ROUNDS + 1 do
        for i = 1, n do
            points[i] = pointAt(i)
        end
        if round > PathFinderModule.CORRIDOR_SMOOTH_ROUNDS then
            break
        end
        local changed = false
        for i = 2, n do
            local moved = (share[i - 1] > 0 and i - 1 > fixedTo and i - 1 < fixedFrom) or (share[i] > 0 and i > fixedTo and i < fixedFrom)
            if moved and not self:isStretchClear(points[i - 1], points[i], nil, true) then
                -- vers le tracé d'origine autour de ce tronçon (la moitié, puis tout)
                for k = math.max(1, i - half), math.min(n, i + half - 1) do
                    if share[k] > 0 then
                        share[k] = share[k] > 0.5 and 0.5 or 0
                        changed = true
                    end
                end
                reverted = reverted + 1
            end
        end
        if not changed then
            break
        end
    end
    -- points presque alignés retirés (écart < 0,1 m), le reste du trajet est contrôlé ensuite comme avant
    local out = {points[1]}
    local kept = 1
    for i = 2, n - 1 do
        local a, c = points[kept], points[i + 1]
        local abx, abz = c.x - a.x, c.z - a.z
        local l = math.sqrt(abx * abx + abz * abz)
        local keep = l > 10 or i <= fixedTo or i >= fixedFrom
        -- la corde doit passer le même contrôle que les tronçons qu'elle remplace
        if not keep and i > kept + 1 and not self:isStretchClear(a, c, nil, true) then
            keep = true
        end
        for k = kept + 1, i do
            if keep then
                break
            end
            local b = points[k]
            keep = l < 0.01 or math.abs((b.x - a.x) * abz - (b.z - a.z) * abx) / l > 0.1
        end
        if keep then
            out[#out + 1] = points[i]
            kept = i
        end
    end
    out[#out + 1] = wps[#wps]
    -- départ inchangé : le 1er point est celui du véhicule
    out[1] = wps[1]
    self.wayPoints = out
    print(string.format("[AD-Fin] %s: trajet lisse le long du couloir (moyenne sur %.0f m, %d passes, %d point(s) recentre(s) dans la bande) : %d -> %d points, %d troncon(s) repris sur le trace d'origine",
        self:getLogName(), 2 * PathFinderModule.CORRIDOR_SMOOTH_HALF, PathFinderModule.CORRIDOR_SMOOTH_PASSES, centred, #wps, #out, reverted))
    return true
end

-- place libre en travers d'un point : distance au premier bord (culture, autre champ, obstacle) de chaque côté, jusqu'à
-- CORRIDOR_PROBE m ; le point est déplacé vers le milieu de la place où le train tient (au plus CORRIDOR_CENTRE_MAX m),
-- un point sur deux (les autres suivent par la moyenne glissante). Les points déplacés dont les tronçons ne passent pas
-- le contrôle du trajet reviennent sur la grille. Retourne le nombre de points déplacés
PathFinderModule.CORRIDOR_PROBE = 8
PathFinderModule.CORRIDOR_PROBE_STEP = 0.5
PathFinderModule.CORRIDOR_CENTRE_MAX = 4
PathFinderModule.CORRIDOR_CENTRE_EVERY = 2
PathFinderModule.CORRIDOR_CENTRE_RAMP = 10 -- m : déplacement ramené à zéro vers le départ et l'arrivée
function PathFinderModule:centreInCorridor(dense, fixedTo, fixedFrom)
    local n = #dense
    local cropHalf = self:getCropHalfWidth()
    local bodyHalf = (self.trainHalfWidth or 2) + 0.5
    local function wallDistance(p, nx, nz, sign)
        -- culture et autre champ : le long de la normale, échantillons tous les CORRIDOR_PROBE_STEP m
        local probe = PathFinderModule.CORRIDOR_PROBE
        local free = probe
        local k = PathFinderModule.CORRIDOR_PROBE_STEP
        while k <= probe do
            local x, z = p.x + nx * k * sign, p.z + nz * k * sign
            if PathFinderModule.getMapCropAt(x, z) ~= 0 or not self:isTrainSideAllowed(x, z) then
                free = k - PathFinderModule.CORRIDOR_PROBE_STEP
                break
            end
            k = k + PathFinderModule.CORRIDOR_PROBE_STEP
        end
        local cropLimit = free - cropHalf
        -- obstacles : boîte fine de p vers le côté, plus longue tant qu'elle ne touche rien (recherche par moitiés)
        local lo, hi = 0, probe
        local angle = AutoDrive.normalizeAngle(math.atan2(-nz * sign, nx * sign))
        local y = 0
        for _ = 1, 4 do
            local mid = (lo + hi) / 2
            local cx, cz = p.x + nx * sign * mid / 2, p.z + nz * sign * mid / 2
            self.collisionhits = 0
            overlapBox(cx, y + (self.vehicleMinHeight or 2) / 2, cz, 0, angle, 0, mid / 2, (self.vehicleMinHeight or 2) / 2, 0.5, "collisionTestCallback", self, self.mask, true, true, true, true)
            if self.collisionhits > 0 or self:boxHitsBlockedZone(cx, cz, angle, mid / 2, 0.5) then
                hi = mid
            else
                lo = mid
            end
        end
        local obstacleLimit = lo >= probe * 0.9 and probe or lo - bodyHalf
        if self:isOffFieldReduced(p.x + nx * sign * lo, p.z + nz * sign * lo) and lo < probe * 0.9 then
            obstacleLimit = obstacleLimit - PathFinderModule.OFF_FIELD_EXTRA_MARGIN
        end
        return math.min(cropLimit, obstacleLimit)
    end
    local moved = 0
    local offsets = {}
    for i = 1, n do
        offsets[i] = 0
    end
    for i = fixedTo + 1, fixedFrom - 1, PathFinderModule.CORRIDOR_CENTRE_EVERY do
        local a, b = dense[math.max(1, i - 1)], dense[math.min(n, i + 1)]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 0.01 then
            local nx, nz = -dz / l, dx / l
            local left = wallDistance(dense[i], nx, nz, 1)
            local right = wallDistance(dense[i], nx, nz, -1)
            -- place du centre du train : de -right à +left ; son milieu, si le train y tient
            if left >= 0 and right >= 0 then
                local shift = math.max(-PathFinderModule.CORRIDOR_CENTRE_MAX, math.min(PathFinderModule.CORRIDOR_CENTRE_MAX, (left - right) / 2))
                if math.abs(shift) > 0.25 then
                    offsets[i] = {x = nx * shift, z = nz * shift}
                end
            end
        end
    end
    -- déplacements lissés le long du trajet (moyenne sur CORRIDOR_SMOOTH_HALF m de chaque côté) et ramenés à zéro près
    -- du départ et de l'arrivée (sur CORRIDOR_CENTRE_RAMP m) : pas de crochet là où le trajet est fixé
    local step = PathFinderModule.CORRIDOR_SMOOTH_STEP
    local half = math.max(1, math.floor(PathFinderModule.CORRIDOR_SMOOTH_HALF / step + 0.5))
    local shifted = {}
    for i = 1, n do
        local o = 0
        if i > fixedTo and i < fixedFrom then
            local ax, az, count = 0, 0, 0
            for k = math.max(1, i - half), math.min(n, i + half) do
                local ok = offsets[k]
                if ok ~= 0 then
                    ax, az = ax + ok.x, az + ok.z
                end
                count = count + 1
            end
            local ramp = math.min(1, (i - fixedTo) * step / PathFinderModule.CORRIDOR_CENTRE_RAMP, (fixedFrom - i) * step / PathFinderModule.CORRIDOR_CENTRE_RAMP)
            -- un point sur CORRIDOR_CENTRE_EVERY a été mesuré
            local f = ramp * PathFinderModule.CORRIDOR_CENTRE_EVERY / count
            if math.abs(ax * f) + math.abs(az * f) > 0.05 then
                o = {x = ax * f, z = az * f}
            end
        end
        shifted[i] = o
    end
    local base = {}
    for i = 1, n do
        local o = shifted[i]
        base[i] = o ~= 0 and {x = dense[i].x + o.x, z = dense[i].z + o.z} or {x = dense[i].x, z = dense[i].z}
    end
    -- un point déplacé dont un tronçon ne passe pas revient sur la grille
    for i = 2, n do
        if (shifted[i - 1] ~= 0 or shifted[i] ~= 0) and not self:isStretchClear(base[i - 1], base[i], nil, true) then
            shifted[i - 1], shifted[i] = 0, 0
            base[i - 1] = {x = dense[i - 1].x, z = dense[i - 1].z}
            base[i] = {x = dense[i].x, z = dense[i].z}
        end
    end
    for i = 1, n do
        if shifted[i] ~= 0 then
            moved = moved + 1
            dense[i].x, dense[i].z = base[i].x, base[i].z
        end
    end
    return moved
end

-- vrais virages trop serrés : sur une longueur L, le cap tourne de plus que L / rayon + TIGHT_CURVE_SLACK.
-- Retourne le nombre de virages et l'indice du point où commence le premier, l'angle et la longueur du pire
function PathFinderModule:findTightCurves()
    local wps = self.wayPoints
    if wps == nil or #wps < 3 then
        return 0, nil
    end
    local radius = self.realTurnRadius or self.minTurnRadius
    local slack = PathFinderModule.TIGHT_CURVE_SLACK
    -- segments : cap déroulé, début et fin le long du trajet
    local segs = {}
    local s = 0
    local heading = nil
    for i = 1, #wps - 1 do
        local dx, dz = wps[i + 1].x - wps[i].x, wps[i + 1].z - wps[i].z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 0.05 then
            local h = math.atan2(dz, dx)
            if heading ~= nil then
                local d = h - heading
                while d > math.pi do d = d - 2 * math.pi end
                while d < -math.pi do d = d + 2 * math.pi end
                h = heading + d
            end
            heading = h
            segs[#segs + 1] = {h = h, from = s, to = s + l, index = i}
        end
        s = s + l
    end
    -- les derniers mètres (approche de la cible, jugés à part comme dans findBlockedStretch) ne comptent pas, sauf au
    -- bout d'un trajet partiel (la benne s'y arrête)
    local skipTo = s - PathFinderModule.VERIFY_SKIP_END
    if self.partialPath or self.goingBehind then
        skipTo = s
    end
    local count, first, worstAngle, worstLength = 0, nil, 0, 0
    local firstEnd = nil
    local places = {}
    local a = 1
    while a < #segs and segs[a].to < skipTo do
        local found = nil
        for b = a + 1, #segs do
            local between = segs[b].from - segs[a].to
            if between > math.pi * radius then
                break
            end
            local turn = math.abs(segs[b].h - segs[a].h)
            if turn > between / radius + slack then
                found = b
                if turn > worstAngle then
                    worstAngle, worstLength = turn, between
                end
                break
            end
        end
        if found ~= nil then
            count = count + 1
            if first == nil then
                first = segs[a].index + 1
                firstEnd = segs[found].index
            end
            if #places < 3 then
                local p = wps[segs[a].index + 1]
                places[#places + 1] = string.format("%.0f,%.0f", p.x, p.z)
            end
            -- le même virage n'est compté qu'une fois
            local stop = segs[found].to
            a = found
            while a < #segs and segs[a].from < stop do
                a = a + 1
            end
        else
            a = a + 1
        end
    end
    return count, first, math.deg(worstAngle), worstLength, table.concat(places, " "), firstEnd
end

-- ------------------------------------------------------------------------------------------------------------
-- (15/11) Vrai virage serré : virage au rayon du train, élargi dans l'espace libre
-- ------------------------------------------------------------------------------------------------------------
-- tour de la pointe d'une culture (champ 58, vers -145,-68 : 87 deg sur 9 m) : le chemin de la grille colle à la
-- pointe. Le morceau serré est remplacé par une courbe de Dubins au rayon du train (marche avant seulement), entre un
-- point pris avant le virage et un point pris après (de plus en plus loin, WIDE_TURN_LEADS m), les 6 formes essayées
-- de la plus courte à la plus longue. La courbe est contrôlée comme le trajet (isStretchClear : culture, autre champ,
-- obstacles) ; sans place, le virage reste refusé (au plus près, puis nouveau calcul).
PathFinderModule.WIDE_TURN_LEADS = {0, 4, 8, 12, 16, 24, 32} -- m pris avant et après le virage serré
PathFinderModule.WIDE_TURN_STEP = 2 -- m entre deux points de la courbe
PathFinderModule.WIDE_TURN_MAX_CHECKS = 60 -- courbes contrôlées entièrement (obstacles), par virage
PathFinderModule.WIDE_TURN_MAX_ROUNDS = 6 -- virages remplacés au plus par trajet
PathFinderModule.WIDE_TURN_HEADING_LENGTH = 3 -- m du trajet pour lire le cap à un bout de la courbe

-- point du trajet à la distance d (le long du trajet) avant (sign -1) ou après (sign 1) l'indice i
local function walkIndex(wps, i, d, sign)
    local done = 0
    local j = i
    while done < d do
        local k = j + sign
        if k < 1 or k > #wps then
            return nil
        end
        done = done + MathUtil.vector2Length(wps[k].x - wps[j].x, wps[k].z - wps[j].z)
        j = k
    end
    return j
end

-- cap du trajet en wps[i] (vers l'avant), lu sur WIDE_TURN_HEADING_LENGTH m avant (sign -1) ou après (sign 1)
local function headingAt(wps, i, sign)
    local j = walkIndex(wps, i, PathFinderModule.WIDE_TURN_HEADING_LENGTH, sign) or (sign < 0 and 1 or #wps)
    local a, b = wps[i], wps[j]
    if sign < 0 then
        a, b = wps[j], wps[i]
    end
    local dx, dz = b.x - a.x, b.z - a.z
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 0.5 then
        return nil
    end
    return dx / l, dz / l
end

-- courbe de Dubins de wps[i0] (cap h0) à wps[i1] (cap h1), forme pathType ; points tous les WIDE_TURN_STEP m ou nil
function PathFinderModule:wideTurnPoints(p0, h0x, h0z, p1, h1x, h1z, radius, pathType, maxLength)
    if self.dubins == nil then
        return nil
    end
    -- plan de Dubins : X = x, Y = -z
    local q0 = {p0.x, -p0.z, math.atan2(-h0z, h0x)}
    local q1 = {p1.x, -p1.z, math.atan2(-h1z, h1x)}
    if self.dubins:dubins_path(ADDubins.DubinsPath, q0, q1, radius, pathType) ~= ADDubins.EDUBOK then
        return nil
    end
    local length = self.dubins:dubins_path_length(ADDubins.DubinsPath)
    if length > maxLength then
        return nil
    end
    self.dubins.outPath = {}
    if self.dubins:dubins_path_sample_many(ADDubins.DubinsPath, PathFinderModule.WIDE_TURN_STEP, ADDubins.createWayPoints) ~= ADDubins.EDUBOK then
        return nil
    end
    local points = {}
    for k, q in ipairs(self.dubins.outPath) do
        if k > 1 then
            points[#points + 1] = {x = q.x, y = q.y, z = q.z}
        end
    end
    return points, length
end

-- remplace les vrais virages serrés qui ont la place ; retourne le nombre de virages remplacés
function PathFinderModule:widenTightCurves()
    local radius = self.realTurnRadius or self.minTurnRadius
    local replaced = 0
    local triedAt = {}
    for _ = 1, PathFinderModule.WIDE_TURN_MAX_ROUNDS do
        local wps = self.wayPoints
        local tight, first, _, _, _, firstEnd = self:findTightCurves()
        if tight == 0 or first == nil or firstEnd == nil then
            break
        end
        local corner = wps[first]
        local key = string.format("%.0f,%.0f", corner.x, corner.z)
        if triedAt[key] then
            break
        end
        triedAt[key] = true
        -- longueurs avant/après, les plus courtes d'abord
        local options = {}
        for _, dIn in ipairs(PathFinderModule.WIDE_TURN_LEADS) do
            for _, dOut in ipairs(PathFinderModule.WIDE_TURN_LEADS) do
                options[#options + 1] = {dIn = dIn, dOut = dOut}
            end
        end
        table.sort(options, function(o1, o2)
            if o1.dIn + o1.dOut ~= o2.dIn + o2.dOut then
                return o1.dIn + o1.dOut < o2.dIn + o2.dOut
            end
            return o1.dIn < o2.dIn
        end)
        local checks = 0
        local done = nil
        for _, o in ipairs(options) do
            if done ~= nil or checks >= PathFinderModule.WIDE_TURN_MAX_CHECKS then
                break
            end
            -- jamais le départ du véhicule ni l'arrivée elle-même
            local i0 = walkIndex(wps, math.max(2, first - 1), o.dIn, -1)
            local i1 = walkIndex(wps, math.min(#wps - 1, firstEnd + 1), o.dOut, 1)
            if i0 ~= nil and i1 ~= nil and i0 >= 2 and i1 <= #wps - 1 and i1 > i0 then
                local h0x, h0z = headingAt(wps, i0, -1)
                local h1x, h1z = headingAt(wps, i1, 1)
                if h0x ~= nil and h1x ~= nil then
                    local along = 0
                    for k = i0 + 1, i1 do
                        along = along + MathUtil.vector2Length(wps[k].x - wps[k - 1].x, wps[k].z - wps[k - 1].z)
                    end
                    -- une courbe bien plus longue que le morceau remplacé ferait une boucle. (15/11) avant : jusqu'à
                    -- + 2πR (56 m au rayon de 9 m), d'où des ronds en jeu (63 m au lieu de 7 m) : plus jamais de boucle,
                    -- au plus 30 % ou 6 m de plus que le morceau remplacé
                    local maxLength = math.max(along * 1.3, along + 6)
                    local candidates = {}
                    for pathType = 1, 6 do
                        local points, length = self:wideTurnPoints(wps[i0], h0x, h0z, wps[i1], h1x, h1z, radius, pathType, maxLength)
                        if points ~= nil then
                            candidates[#candidates + 1] = {points = points, length = length, pathType = pathType}
                        end
                    end
                    table.sort(candidates, function(c1, c2) return c1.length < c2.length end)
                    for _, c in ipairs(candidates) do
                        if checks >= PathFinderModule.WIDE_TURN_MAX_CHECKS then
                            break
                        end
                        -- contrôle rapide d'abord : culture et autre champ sous les points
                        local quick = true
                        for _, p in ipairs(c.points) do
                            if PathFinderModule.getMapCropAt(p.x, p.z) ~= 0 or not self:isFieldPositionAllowed(p.x, p.z) then
                                quick = false
                                break
                            end
                        end
                        if quick then
                            checks = checks + 1
                            local chain = {wps[i0]}
                            for _, p in ipairs(c.points) do
                                chain[#chain + 1] = p
                            end
                            chain[#chain + 1] = wps[i1]
                            local clear = true
                            for k = 2, #chain do
                                if not self:isStretchClear(chain[k - 1], chain[k], nil, true) then
                                    clear = false
                                    break
                                end
                            end
                            if clear then
                                done = {i0 = i0, i1 = i1, points = c.points, length = c.length, along = along, dIn = o.dIn, dOut = o.dOut}
                                break
                            end
                        end
                    end
                end
            end
        end
        if done == nil then
            print(string.format("[AD-Fin] %s: virage serre vers %s : pas de place pour un virage au rayon de %.1f m (%d courbes controlees)", self:getLogName(), key, radius, checks))
            break
        end
        local out = {}
        for k = 1, done.i0 do
            out[#out + 1] = wps[k]
        end
        for _, p in ipairs(done.points) do
            p.direction = wps[done.i0].direction
            out[#out + 1] = p
        end
        for k = done.i1, #wps do
            out[#out + 1] = wps[k]
        end
        self.wayPoints = out
        replaced = replaced + 1
        print(string.format("[AD-Fin] %s: virage serre vers %s remplace par un virage au rayon de %.1f m (%.0f m au lieu de %.0f m, pris %.0f m avant et %.0f m apres)",
            self:getLogName(), key, radius, done.length, done.along, done.dIn, done.dOut))
    end
    return replaced
end
