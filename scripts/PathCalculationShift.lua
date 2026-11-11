-- ============================================================================================================
-- FarmPilot : PathCalculationShift.lua
-- Complément de PathCalculation.lua : route décalée à côté d'un obstacle fin sur la ligne (poteau).
--
-- (08/11) Le 7R 350 sortait d'un champ, la ligne du réseau passe entre deux
-- poteaux (tronçons 6282 -> 6281 -> 6280) ; pas d'autre route, le décalage d'ADAvoidModule commençait 4 m avant le
-- poteau et d'1 m seulement : le pneu a touché le poteau sans que les capteurs le voient.
--
-- Règle : quand une route est posée, chaque suite de tronçons trop étroits (PathCalculationWidth.lua) est décalée
-- d'un bloc, du plus petit écart (0,5 à 3 m, des deux côtés, le côté opposé à l'objet touché d'abord) dont le couloir
-- (train entier + marge) est libre et dont le sol reste à la hauteur de la ligne (pas de fossé, de talus, de bord de
-- pont), avec une sortie douce avant l'obstacle et un retour après. Aucun écart possible (portail, pont, mur, route
-- étroite) : la route reste telle quelle. Rien près de la destination (l'obstacle peut être le but).
--
-- Branché par DrivePathModule.lua (ADDrivePathModule.shiftAroundObstacles, sous pcall).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- route moved beside a thin obstacle on the line --------------------------------------------------
-- (08/11) 7R 350 leaving a field: the network line runs through two poles (sections
-- 6282 -> 6281 -> 6280, "too narrow ... hit 'collision/col'"). There was no other way, so the route kept them; the
-- sideways shift of ADAvoidModule started 4 m before the pole and only 1 m: the tyre hit the pole, and the sensors
-- (75 % of the width for static objects) never saw it. It pushed against it until the player came.
-- Now, when a route is set, each run of too narrow network sections is moved sideways as a whole, by the smallest
-- offset whose corridor (whole train width + margin, same heights as the width check) is free and whose ground stays
-- at the height of the line (no ditch, no bank, no bridge edge), with a gentle way out before and back after the
-- obstacle. When no offset fits (gate, bridge, wall, narrow road) the route stays as it was.
ADPathCalculator.SHIFT_OFFSETS = {0.5, 1.0, 1.5, 2.0, 2.5, 3.0} -- m, tried in this order, on both sides
ADPathCalculator.SHIFT_MARGIN = 0.3            -- m free beside the train where it is moved
ADPathCalculator.SHIFT_RATE = 0.25             -- m of offset per metre of route on the way out and back
ADPathCalculator.SHIFT_RAMP_MIN = 6            -- m
ADPathCalculator.SHIFT_RAMP_SHORT = 3          -- m, way out at least when the route starts close to the obstacle
ADPathCalculator.SHIFT_STEP = 2                -- m between two points of the moved part
ADPathCalculator.SHIFT_GROUND_DIFF = 0.6       -- m between the ground beside and the line at most
ADPathCalculator.SHIFT_MAX_TURN = math.rad(30) -- a moved part may not hold a sharper turn than this (bends: ADCornerModule)
ADPathCalculator.SHIFT_END_DISTANCE = 15       -- m, a run this close to the destination stays (the obstacle may be the goal)
ADPathCalculator.SHIFT_JOIN = 20               -- m, two runs closer than this are moved together
ADPathCalculator.SHIFT_RUN_MAX = 120           -- m, a longer run is a narrow road, not an obstacle
ADPathCalculator.SHIFT_FRONT_MARGIN = 2        -- m moved before the nose reaches the obstacle
ADPathCalculator.SHIFT_REAR_MARGIN = 2         -- m moved after the end of the train passed it

ADPathCalculator.SHIFT_DEBUG = true

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
function ADPathCalculator.shiftLog(text, ...)
    if ADPathCalculator.SHIFT_DEBUG then
        print(string.format("[AD-Poteau] " .. text, ...))
    end
end

local function isPlainNetworkPoint(wp)
    return wp ~= nil and wp.id ~= nil and not wp.isPathFinderPoint and not wp.isCornerPoint and not wp.isShiftPoint
end

-- nose and tail of the train, measured from the vehicle (route points are where the vehicle is)
function ADPathCalculator.getShiftTrain(vehicle)
    local front
    if vehicle.ad ~= nil and vehicle.ad.adDimensions ~= nil and vehicle.ad.adDimensions.maxLengthFront ~= nil and vehicle.ad.adDimensions.maxLengthFront > 0 then
        front = vehicle.ad.adDimensions.maxLengthFront
    else
        front = (vehicle.size ~= nil and vehicle.size.length or 6) / 2 + 0.5
    end
    local length = vehicle.size ~= nil and vehicle.size.length or 6
    local units = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit ~= vehicle and unit.size ~= nil and unit.size.length ~= nil then
                length = length + unit.size.length
            end
        end
    end
    return front, math.max(2, length - front)
end

local function terrainY(x, z)
    return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 300, z)
end

local function lineY(wp)
    if type(wp.y) == "number" and wp.y ~= -1 then
        return wp.y
    end
    return terrainY(wp.x, wp.z)
end

-- ------------------------------------------------------------------------------------------------------------
-- Partie de route déplacée
-- ------------------------------------------------------------------------------------------------------------
-- the moved part of the route between path distances s0 and s1 (offset 0 there), at full offset between sA and sB.
-- Returns the new points and the first / last index of wayPoints they replace, or nil and the reason
function ADPathCalculator.buildShift(wayPoints, s, sA, sB, offset, rampIn, rampOut)
    local n = #wayPoints
    local s0, s1 = sA - rampIn, sB + rampOut
    if s0 < s[1] or s1 > s[n] then
        return nil, "no room"
    end
    local from, to = nil, nil
    for i = 1, n do
        if s[i] > s0 + 0.01 and s[i] < s1 - 0.01 then
            from = from or i
            to = i
        end
    end
    if from == nil then
        return nil, "nothing to move"
    end
    -- no reverse section, no point of a redrawn bend or of the pathfinder inside, no sharp turn
    for i = math.max(2, from - 1), math.min(n, to + 1) do
        local a, b = wayPoints[i - 1], wayPoints[i]
        if b.isPathFinderPoint or b.isCornerPoint or b.isShiftPoint or b.cornerReverse ~= nil or ADGraphManager:isReverseRoad(a, b) then
            return nil, "reverse, bend or pathfinder points"
        end
        if i < n then
            local c = wayPoints[i + 1]
            local h1 = math.atan2(b.x - a.x, b.z - a.z)
            local h2 = math.atan2(c.x - b.x, c.z - b.z)
            local turn = math.abs((h2 - h1 + math.pi) % (2 * math.pi) - math.pi)
            if turn > ADPathCalculator.SHIFT_MAX_TURN and s[i] > s0 - 1 and s[i] < s1 + 1 then
                return nil, string.format("turn of %.0f deg", math.deg(turn))
            end
        end
    end
    -- path distances of the new points: the original points (they keep their id) and a point every SHIFT_STEP
    local list = {}
    for i = from, to do
        list[#list + 1] = {s = s[i], index = i}
    end
    local step = ADPathCalculator.SHIFT_STEP
    local k = s0 + step
    while k < s1 - 0.5 do
        local near = false
        for i = from, to do
            if math.abs(s[i] - k) < step * 0.4 then
                near = true
                break
            end
        end
        if not near then
            list[#list + 1] = {s = k}
        end
        k = k + step
    end
    -- the ends of the moved part, on the line, unless an original point is there already (no point twice)
    if s0 - s[from - 1] > 0.3 then
        list[#list + 1] = {s = s0, edge = true}
    end
    if to + 1 > n or s[to + 1] - s1 > 0.3 then
        list[#list + 1] = {s = s1, edge = true}
    end
    table.sort(list, function(p, q) return p.s < q.s end)
    local function amount(v)
        local t
        if v <= sA then
            t = rampIn > 0 and (v - s0) / rampIn or 1
        elseif v >= sB then
            t = rampOut > 0 and (s1 - v) / rampOut or 1
        else
            return 1
        end
        t = math.max(0, math.min(1, t))
        return t * t * (3 - 2 * t)
    end
    local points = {}
    local j = 1
    for _, item in ipairs(list) do
        while j < n - 1 and s[j + 1] < item.s do
            j = j + 1
        end
        local a, b = wayPoints[j], wayPoints[j + 1]
        local len = math.max(0.001, s[j + 1] - s[j])
        local f = math.max(0, math.min(1, (item.s - s[j]) / len))
        local bx, bz = a.x + (b.x - a.x) * f, a.z + (b.z - a.z) * f
        local by = lineY(a) + (lineY(b) - lineY(a)) * f
        local dx, dz = (b.x - a.x) / len, (b.z - a.z) / len
        if item.index ~= nil then
            -- an original point: the normal is the mean of the stretches before and after it
            local i = item.index
            local p, q = wayPoints[i - 1], wayPoints[i + 1]
            local d1x, d1z, d2x, d2z = 0, 0, 0, 0
            if p ~= nil then
                local l1 = math.max(0.001, MathUtil.vector2Length(wayPoints[i].x - p.x, wayPoints[i].z - p.z))
                d1x, d1z = (wayPoints[i].x - p.x) / l1, (wayPoints[i].z - p.z) / l1
            end
            if q ~= nil then
                local l2 = math.max(0.001, MathUtil.vector2Length(q.x - wayPoints[i].x, q.z - wayPoints[i].z))
                d2x, d2z = (q.x - wayPoints[i].x) / l2, (q.z - wayPoints[i].z) / l2
            end
            local l = MathUtil.vector2Length(d1x + d2x, d1z + d2z)
            if l > 0.001 then
                dx, dz = (d1x + d2x) / l, (d1z + d2z) / l
            end
            bx, bz, by = wayPoints[i].x, wayPoints[i].z, lineY(wayPoints[i])
        end
        local o = offset * amount(item.s)
        local x, z = bx + dz * o, bz - dx * o
        local point
        if item.index ~= nil then
            point = {}
            for key, value in pairs(wayPoints[item.index]) do
                point[key] = value
            end
        else
            point = {}
        end
        point.x, point.z = x, z
        point.y = terrainY(x, z)
        point.isShiftPoint = true
        point.shiftOffset = o
        point.lineY = by
        points[#points + 1] = point
    end
    return points, from, to
end

-- the moved part is clear: whole train width + margin (growing with the offset), same heights as the width check,
-- ground at the height of the line. Returns clear, reason
function ADPathCalculator.isShiftClear(points, halfWidth, offset)
    local low, high = ADPathCalculator.WIDTH_CHECK_LOW, ADPathCalculator.WIDTH_CHECK_HIGH
    for k, p in ipairs(points) do
        if math.abs(p.y - p.lineY) > ADPathCalculator.SHIFT_GROUND_DIFF then
            return false, string.format("ground %.1f m %s the line", math.abs(p.y - p.lineY), p.y < p.lineY and "below" or "above")
        end
        local q = points[k + 1]
        if q ~= nil then
            local dx, dz = q.x - p.x, q.z - p.z
            local length = math.sqrt(dx * dx + dz * dz)
            if length > 0.05 then
                local share = math.min(1, math.max(math.abs(p.shiftOffset), math.abs(q.shiftOffset)) / math.max(0.01, math.abs(offset)))
                local half = halfWidth + ADPathCalculator.SHIFT_MARGIN * share
                local cx, cz = (p.x + q.x) / 2, (p.z + q.z) / 2
                local y = math.max(terrainY(cx, cz), (p.lineY + q.lineY) / 2)
                ADPathCalculator.widthHits = 0
                ADPathCalculator.widthHitNode = nil
                overlapBox(cx, y + (low + high) / 2, cz, 0, math.atan2(dx, dz), 0, half, (high - low) / 2, length / 2, "widthCheckCallback", ADPathCalculator, ADPathCalculator.widthMask, true, true, true, true)
                if ADPathCalculator.widthHits > 0 then
                    local name = "?"
                    if ADPathCalculator.widthHitNode ~= nil and getName ~= nil then
                        local ok, hitName = FarmPilotCall(getName, ADPathCalculator.widthHitNode)
                        if ok and hitName ~= nil then
                            name = hitName
                        end
                    end
                    return false, string.format("'%s' %.0f m into the moved part", name, k * ADPathCalculator.SHIFT_STEP)
                end
            end
        end
    end
    return true
end

-- where the obstacles of a run lie along the route: the sections are cut in slices of SHIFT_STEP metres tested like
-- the width check. Returns the path distances of the start of the first and of the end of the last slice hit
function ADPathCalculator.locateShiftHits(wayPoints, s, run, halfWidth)
    local low, high = ADPathCalculator.WIDTH_CHECK_LOW, ADPathCalculator.WIDTH_CHECK_HIGH
    local first, last = nil, nil
    for i = run.first, run.last do
        local a, b = wayPoints[i], wayPoints[i + 1]
        local length = s[i + 1] - s[i]
        if length > 0.05 then
            local slices = math.max(1, math.ceil(length / ADPathCalculator.SHIFT_STEP))
            local ry = math.atan2(b.x - a.x, b.z - a.z)
            for k = 0, slices - 1 do
                local f0, f1 = k / slices, (k + 1) / slices
                local fm = (f0 + f1) / 2
                local cx, cz = a.x + (b.x - a.x) * fm, a.z + (b.z - a.z) * fm
                local y = lineY(a) + (lineY(b) - lineY(a)) * fm
                ADPathCalculator.widthHits = 0
                overlapBox(cx, y + (low + high) / 2, cz, 0, ry, 0, halfWidth, (high - low) / 2, length / slices / 2, "widthCheckCallback", ADPathCalculator, ADPathCalculator.widthMask, true, true, true, true)
                if ADPathCalculator.widthHits > 0 then
                    first = first or (s[i] + length * f0)
                    last = s[i] + length * f1
                end
            end
        end
    end
    return first, last
end

-- ------------------------------------------------------------------------------------------------------------
-- Plan d'un passage (une suite de tronçons trop étroits)
-- ------------------------------------------------------------------------------------------------------------
-- one run of too narrow sections wayPoints[first] -> wayPoints[last + 1]: the moved part, or nil
function ADPathCalculator.planShift(vehicle, wayPoints, s, run, halfWidth, front, rear, startS)
    local n = #wayPoints
    local sStart, sEnd = s[run.first], s[run.last + 1]
    -- only around the obstacles themselves, not along the whole sections
    local hitStart, hitEnd = ADPathCalculator.locateShiftHits(wayPoints, s, run, halfWidth)
    if hitStart ~= nil then
        sStart, sEnd = hitStart, hitEnd
    end
    local a, b = wayPoints[run.first], wayPoints[run.last + 1]
    local label = string.format("%s: sections %s -> %s (%.0f m)", tostring(vehicle:getName()), tostring(a.id), tostring(b.id), sEnd - sStart)
    if sEnd - sStart > ADPathCalculator.SHIFT_RUN_MAX then
        ADPathCalculator.shiftLog("%s: long narrow stretch (narrow road), route kept", label)
        return nil
    end
    if s[n] - sEnd < ADPathCalculator.SHIFT_END_DISTANCE then
        ADPathCalculator.shiftLog("%s: next to the destination, route kept", label)
        return nil
    end
    -- side of the line where the hit object was seen: the other side is tried first (+1 = left normal)
    local sides = {-1, 1}
    for i = run.first, run.last do
        local info = ADPathCalculator.narrowInfo[tostring(wayPoints[i].id) .. ">" .. tostring(wayPoints[i + 1].id)]
        if info ~= nil and info.hx ~= nil then
            local p, q = wayPoints[i], wayPoints[i + 1]
            local dx, dz = q.x - p.x, q.z - p.z
            local side = (info.hx - p.x) * dz - (info.hz - p.z) * dx
            if side > 0.05 then
                sides = {-1, 1}
            elseif side < -0.05 then
                sides = {1, -1}
            end
            break
        end
    end
    local lastReason = nil
    for _, margins in ipairs({{front + ADPathCalculator.SHIFT_FRONT_MARGIN, rear + ADPathCalculator.SHIFT_REAR_MARGIN}, {ADPathCalculator.SHIFT_FRONT_MARGIN, ADPathCalculator.SHIFT_REAR_MARGIN}}) do
        local sA = math.max(startS, sStart - margins[1])
        local sB = sEnd + margins[2]
        for _, e in ipairs(ADPathCalculator.SHIFT_OFFSETS) do
            local ramp = math.max(ADPathCalculator.SHIFT_RAMP_MIN, e / ADPathCalculator.SHIFT_RATE)
            local rampIn = math.min(ramp, sA - startS)
            if rampIn >= ADPathCalculator.SHIFT_RAMP_SHORT or rampIn >= ramp then
                for _, sign in ipairs(sides) do
                    local points, from, to = ADPathCalculator.buildShift(wayPoints, s, sA, sB, sign * e, rampIn, ramp)
                    if points == nil then
                        lastReason = from
                    else
                        local clear, reason = ADPathCalculator.isShiftClear(points, halfWidth, sign * e)
                        if clear then
                            ADPathCalculator.shiftLog("%s, hit '%s': route moved %.1f m to the %s over %.0f m (way out %.0f m, back %.0f m)",
                                label, tostring(run.hitName or "?"), e, sign > 0 and "left" or "right", sB - sA, rampIn, ramp)
                            return {from = from, to = to, points = points, endS = sB + ramp}
                        end
                        lastReason = reason
                    end
                end
            else
                lastReason = "too close to the start of the route"
            end
        end
    end
    ADPathCalculator.shiftLog("%s, hit '%s': no free offset beside it (%s), route kept", label, tostring(run.hitName or "?"), tostring(lastReason))
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale
-- ------------------------------------------------------------------------------------------------------------
-- wayPoints: route set for the vehicle (after ADCornerModule:smoothRoute); firstIndex: first point it drives to
function ADPathCalculator.shiftAroundObstacles(vehicle, wayPoints, firstIndex)
    if vehicle == nil or not vehicle.isServer or wayPoints == nil or #wayPoints < 3 or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return wayPoints
    end
    local enabled = AutoDrive.getSetting("avoidEnabled")
    if enabled == false or enabled == 0 then
        return wayPoints
    end
    local narrow = ADPathCalculator:getNarrowWeightFunc(vehicle)
    local halfWidth = (ADPathCalculator.lastNeededWidth or 3) / 2
    local n = #wayPoints
    local s = {0}
    for i = 2, n do
        s[i] = s[i - 1] + MathUtil.vector2Length(wayPoints[i].x - wayPoints[i - 1].x, wayPoints[i].z - wayPoints[i - 1].z)
    end
    local startIndex = math.max(1, math.min(n, (firstIndex or 2) - 1))
    local runs = {}
    for i = startIndex, n - 1 do
        local a, b = wayPoints[i], wayPoints[i + 1]
        if isPlainNetworkPoint(a) and isPlainNetworkPoint(b) and narrow(a, b) > 0 then
            local info = ADPathCalculator.narrowInfo[tostring(a.id) .. ">" .. tostring(b.id)]
            local last = runs[#runs]
            if last ~= nil and s[i] - s[last.last + 1] <= ADPathCalculator.SHIFT_JOIN then
                last.last = i
            else
                runs[#runs + 1] = {first = i, last = i, hitName = info ~= nil and info.hitName or nil}
            end
        end
    end
    if #runs == 0 then
        return wayPoints
    end
    local front, rear = ADPathCalculator.getShiftTrain(vehicle)
    local out = {}
    local copied = 0
    local moved = 0
    local freeFrom = s[startIndex] -- the next moved part starts after the end of the previous one
    for _, run in ipairs(runs) do
        if run.first > copied and s[run.first + 1] > freeFrom then
            local plan = ADPathCalculator.planShift(vehicle, wayPoints, s, run, halfWidth, front, rear, freeFrom)
            if plan ~= nil and plan.from > copied then
                freeFrom = plan.endS
                for i = copied + 1, plan.from - 1 do
                    out[#out + 1] = wayPoints[i]
                end
                for _, point in ipairs(plan.points) do
                    out[#out + 1] = point
                end
                copied = plan.to
                moved = moved + 1
            end
        end
    end
    if moved == 0 then
        return wayPoints
    end
    for i = copied + 1, n do
        out[#out + 1] = wayPoints[i]
    end
    return out
end
