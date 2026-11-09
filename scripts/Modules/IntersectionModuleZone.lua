-- ============================================================================================================
-- FarmPilot : IntersectionModuleZone.lua
-- Complément de IntersectionModule.lua : la portion rouge et les voies à surveiller.
--
-- Règle : les voies coupées par la portion rouge (et la voie rejointe à son bout) sont remontées sur WATCH_DIST m,
-- double sens compris, et découpées en boîtes de BOX_MAX_LENGTH m au plus ; la zone est gardée en cache par
-- 1er point rouge (ADIntersectionModule.zones, vidé par clearCache). Voie de sortie : boîtes le long de MON trajet
-- après le dernier point rouge.
--
-- Branché par : IntersectionModule.lua (findIntersection : buildZone) et IntersectionModuleTraffic.lua
-- (isExitBlocked : buildExitBoxes).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Outils géométriques
-- ------------------------------------------------------------------------------------------------------------
-- intersection de deux segments 2D : renvoie x, z ou nil
local function segmentsCross(ax, az, bx, bz, cx, cz, dx, dz)
    local rx, rz = bx - ax, bz - az
    local sx, sz = dx - cx, dz - cz
    local den = rx * sz - rz * sx
    if math.abs(den) < 1e-6 then
        return nil
    end
    local qx, qz = cx - ax, cz - az
    local t = (qx * sz - qz * sx) / den
    local u = (qx * rz - qz * rx) / den
    if t < 0 or t > 1 or u < 0 or u > 1 then
        return nil
    end
    return ax + t * rx, az + t * rz
end

-- ------------------------------------------------------------------------------------------------------------
-- Voies à surveiller
-- ------------------------------------------------------------------------------------------------------------
-- segments de voie en amont d'un point, jusqu'à WATCH_DIST (voies non rouges)
local function collectUpstream(startId, boxes, seen)
    local queue = { { id = startId, dist = 0 } }
    local head = 1
    while queue[head] ~= nil do
        local item = queue[head]
        head = head + 1
        local wp = ADGraphManager:getWayPointById(item.id)
        if wp ~= nil and wp.incoming ~= nil then
            for _, inId in pairs(wp.incoming) do
                local prev = ADGraphManager:getWayPointById(inId)
                if prev ~= nil and not ADIntersectionModule.isIntersectionPoint(prev) then
                    local key = inId .. ">" .. item.id
                    if not seen[key] then
                        seen[key] = true
                        local len = MathUtil.vector2Length(wp.x - prev.x, wp.z - prev.z)
                        table.insert(boxes, { ax = prev.x, ay = prev.y, az = prev.z, bx = wp.x, by = wp.y, bz = wp.z })
                        if item.dist + len < ADIntersectionModule.WATCH_DIST then
                            table.insert(queue, { id = inId, dist = item.dist + len })
                        end
                    end
                end
            end
        end
    end
end

-- découpe les segments en boîtes de BOX_MAX_LENGTH au plus
local function makeBoxes(segments)
    local out = {}
    for _, s in ipairs(segments) do
        local len = MathUtil.vector2Length(s.bx - s.ax, s.bz - s.az)
        if len > 0.1 then
            local n = math.max(1, math.ceil(len / ADIntersectionModule.BOX_MAX_LENGTH))
            local ry = math.atan2(s.bx - s.ax, s.bz - s.az)
            for k = 0, n - 1 do
                local t0, t1 = k / n, (k + 1) / n
                local tm = (t0 + t1) * 0.5
                table.insert(out, {
                    x = s.ax + (s.bx - s.ax) * tm,
                    y = s.ay + (s.by - s.ay) * tm,
                    z = s.az + (s.bz - s.az) * tm,
                    ry = ry,
                    half = len / n * 0.5 + 0.5
                })
            end
        end
    end
    return out
end

-- construit la zone à partir des points rouges du trajet (ids du graphe), firstIndex..lastIndex
function ADIntersectionModule.buildZone(wayPoints, firstIndex, lastIndex)
    local red = {}
    for i = math.max(1, firstIndex - 1), math.min(#wayPoints, lastIndex + 1) do
        table.insert(red, wayPoints[i])
    end
    local endPoint = wayPoints[lastIndex + 1]

    local cx, cz = 0, 0
    for _, p in ipairs(red) do
        cx, cz = cx + p.x, cz + p.z
    end
    cx, cz = cx / #red, cz / #red

    local points = {}      -- points de croisement / jonction (x, z)
    local segments = {}
    local seen = {}
    local r2 = ADIntersectionModule.SEARCH_RADIUS ^ 2

    -- voies coupées par la portion rouge
    for _, p in pairs(ADGraphManager:getWayPoints()) do
        if p.out ~= nil and (p.x - cx) ^ 2 + (p.z - cz) ^ 2 < r2 and not ADIntersectionModule.isIntersectionPoint(p) then
            for _, outId in pairs(p.out) do
                local q = ADGraphManager:getWayPointById(outId)
                if q ~= nil and not ADIntersectionModule.isIntersectionPoint(q) then
                    for i = 1, #red - 1 do
                        local a, b = red[i], red[i + 1]
                        -- les segments qui partent du même point que la portion rouge ne sont pas des voies coupées
                        if p.id ~= a.id and p.id ~= b.id and q.id ~= a.id and q.id ~= b.id then
                            local x, z = segmentsCross(a.x, a.z, b.x, b.z, p.x, p.z, q.x, q.z)
                            if x ~= nil then
                                table.insert(points, { x = x, z = z })
                                local key = p.id .. ">" .. q.id
                                if not seen[key] then
                                    seen[key] = true
                                    table.insert(segments, { ax = p.x, ay = p.y, az = p.z, bx = q.x, by = q.y, bz = q.z })
                                end
                                collectUpstream(p.id, segments, seen)
                                -- voie à double sens : la circulation vient aussi de l'autre côté
                                if q.out ~= nil and table.contains(q.out, p.id) then
                                    collectUpstream(q.id, segments, seen)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- voie rejointe au bout de la portion rouge
    if endPoint ~= nil and endPoint.id ~= nil and not ADIntersectionModule.isIntersectionPoint(endPoint) then
        table.insert(points, { x = endPoint.x, z = endPoint.z })
        collectUpstream(endPoint.id, segments, seen)
    end

    local zone = {
        boxes = makeBoxes(segments),
        points = points,
        lanes = #segments
    }
    return zone
end

-- ------------------------------------------------------------------------------------------------------------
-- Voie de sortie
-- ------------------------------------------------------------------------------------------------------------
-- la voie après la portion rouge : boîtes le long de MON trajet après le dernier point rouge, sur 'length' m
function ADIntersectionModule.buildExitBoxes(wayPoints, lastIndex, length)
    local segments = {}
    local cum = 0
    local i = lastIndex + 1
    while wayPoints[i] ~= nil and wayPoints[i + 1] ~= nil and cum < length do
        local a, b = wayPoints[i], wayPoints[i + 1]
        table.insert(segments, { ax = a.x, ay = a.y, az = a.z, bx = b.x, by = b.y, bz = b.z })
        cum = cum + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        i = i + 1
    end
    return makeBoxes(segments), wayPoints[lastIndex + 1]
end
