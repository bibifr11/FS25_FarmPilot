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
-- Branché par PathFinderModuleVerify.lua (checkSmoothedPath : roundCornersToTurnRadius).
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
    return self:isChopperWork() and (self.strictFruit or self.strictField)
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
