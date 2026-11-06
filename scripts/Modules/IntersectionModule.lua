-- Type de route « Intersection » (points rouges, AutoDrive.FLAG_INTERSECTION) :
-- avant d'entrer sur une portion Intersection, AutoDrive regarde les voies AutoDrive
-- que cette portion coupe ou rejoint, en remontant chaque voie sur 80 m.
-- Si un véhicule arrive (voiture du jeu, tracteur, joueur), il s'arrête juste avant
-- le premier point rouge, attend que ce soit libre depuis 2 s, puis traverse sans s'arrêter.
-- Pour le calcul des trajets, un point Intersection compte comme un point normal.

ADIntersectionModule = {}

ADIntersectionModule.DEBUG = false

ADIntersectionModule.WATCH_DIST = 120         -- m de voie regardés en amont (26/10 18:01 : 80 m = 4 s à 73 km/h, trop court pour un attelage qui démarre)
ADIntersectionModule.LOOK_AHEAD = 60          -- m de trajet examinés devant le tracteur
ADIntersectionModule.STOP_BEFORE = 1          -- m : arrêt de l'avant du tracteur avant le 1er point rouge
ADIntersectionModule.APPROACH_DIST = 25       -- m avant l'arrêt : vitesse limitée pour bien regarder
ADIntersectionModule.APPROACH_KMH = 20
ADIntersectionModule.LOOK_KMH = 8              -- km/h au bord de la portion rouge, même route libre (le temps de regarder)
ADIntersectionModule.BRAKE_DECEL = 1.5        -- m/s²
ADIntersectionModule.COMMIT_DIST = 2          -- m avant l'arrêt : si libre, il s'engage
ADIntersectionModule.CLEAR_MS = 2000          -- libre depuis 2 s après une attente
ADIntersectionModule.CHECK_MS = 250
ADIntersectionModule.CLOSE_DIST = 8           -- m : véhicule sur le croisement, même arrêté
ADIntersectionModule.PARKED_DIST = 4          -- m : au-delà, un véhicule arrêté est à côté du croisement, pas dessus (27/10)
ADIntersectionModule.ARRIVAL_S = 8            -- s : véhicule qui arrive dans moins de 8 s (minimum)
ADIntersectionModule.ARRIVAL_MAX_S = 14       -- s : horizon maximal, selon le temps que met l'attelage à traverser
ADIntersectionModule.CROSS_MS = 2.5           -- m/s : vitesse moyenne d'un attelage qui démarre pour traverser (plus utilisé, gardé pour mémoire)
-- 27/10 (C15 D resté 140 s à sa ligne, « voiture arrive (124 m, 48 km/h) » toutes les 15 s : l'horizon de 14 s d'un gros
-- attelage était demandé à une camionnette) : le temps de traversée dépend de l'attelage, puis la patience baisse l'exigence
ADIntersectionModule.LIGHT_TRAIN_M = 8        -- m : véhicule seul et court = léger
ADIntersectionModule.ACCEL_LIGHT = 1.5        -- m/s² depuis l'arrêt
ADIntersectionModule.VMAX_LIGHT = 10          -- m/s (36 km/h) en traversant
ADIntersectionModule.ACCEL_TRAIN = 0.7
ADIntersectionModule.VMAX_TRAIN = 8
ADIntersectionModule.PATIENCE_MS = 30000      -- ms d'attente à la ligne avant de se contenter d'un trou plus court
ADIntersectionModule.PATIENCE_STEP_MS = 10000 -- ms : 1 s de moins par palier
ADIntersectionModule.PATIENCE_MIN_S = 5       -- s : trou minimal accepté (les voitures du jeu freinent devant un véhicule)
ADIntersectionModule.TRACK_MAX_MS = 5000      -- ms : âge maximal d'une trace pour en tirer une vitesse d'approche
ADIntersectionModule.NEAR_DIST = 40           -- m : véhicule qui roule vers le croisement
ADIntersectionModule.ASSUMED_MS = 14          -- m/s (50 km/h) supposés pour un véhicule vu pour la première fois (27/10)
ADIntersectionModule.MOVING_MS = 0.5          -- m/s
ADIntersectionModule.SEARCH_RADIUS = 40       -- m autour de la portion rouge pour trouver les voies
ADIntersectionModule.BOX_HALF_WIDTH = 2.0
ADIntersectionModule.BOX_HALF_HEIGHT = 1.5
ADIntersectionModule.BOX_MAX_LENGTH = 10
ADIntersectionModule.RETREAT_STUCK_MS = 1500   -- ms à l'arrêt sur la portion rouge avant de reculer (26/10 17:55 « s'il se rate il recule immédiatement »)
ADIntersectionModule.RETREAT_TIMEOUT_MS = 40000
ADIntersectionModule.RETREAT_BLOCKED_MS = 6000
ADIntersectionModule.COMMIT_STUCK_MS = 20000  -- ms engagé à l'arrêt sans recul possible : le croisement rend la main (26/10 21:46)  -- ms bloqué derrière pendant le recul : on abandonne le recul (26/10 18:48)
ADIntersectionModule.EXIT_MIN_LENGTH = 25     -- m de voie libre exigés après la portion rouge (au moins l'attelage + 8 m) (26/10 17:24)

ADIntersectionModule.zones = {}               -- cache : id du 1er point rouge -> zone
ADIntersectionModule.tracks = {}

function ADIntersectionModule.log(text, ...)
    print("AutoDrive : [intersection] " .. string.format(text, ...))
end

function ADIntersectionModule.isIntersectionPoint(wp)
    if wp == nil then
        return false
    end
    local flags = wp.flags
    if wp.id ~= nil then
        local g = ADGraphManager:getWayPointById(wp.id)
        if g ~= nil then
            flags = g.flags
        end
    end
    return flags ~= nil and bit32.band(flags, AutoDrive.FLAG_INTERSECTION) > 0
end

-------------------------------------------------------------------------------
-- Zone : la portion rouge et les voies à surveiller
-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- Trafic
-------------------------------------------------------------------------------

local function getMask()
    local m = 0
    for _, name in ipairs({ "VEHICLE", "TRAFFIC_VEHICLE", "TRAFFIC_VEHICLE_BLOCKING" }) do
        if CollisionFlag[name] ~= nil then
            m = m + CollisionFlag[name]
        end
    end
    return m
end

function ADIntersectionModule:overlapCallback(node)
    if node == nil or node == 0 or node == g_currentMission.terrainRootNode then
        return true
    end
    local object = g_currentMission:getNodeObject(node)
    if object == nil then
        local parent = getParent(node)
        if parent ~= nil and parent ~= 0 then
            object = g_currentMission:getNodeObject(parent)
        end
    end
    local me = self.scanVehicle
    if object ~= nil and me ~= nil then
        local root = me:getRootVehicle()
        if object == me or object == root or AutoDrive:checkIsConnected(root, object) then
            return true
        end
    end
    local key = object ~= nil and object or node
    if not self.scanSeen[key] then
        self.scanSeen[key] = true
        table.insert(self.scanHits, { key = key, node = node, object = object })
    end
    return true
end

function ADIntersectionModule.getTracks(vehicle)
    local c = vehicle.ad ~= nil and vehicle.ad.intersection or nil
    if c == nil then
        return ADIntersectionModule.tracks
    end
    if c.tracks == nil then
        c.tracks = {}
    end
    return c.tracks
end

-- 'other' (a vehicle) is ahead of me on my route (2.5 m at most from it, 80 m ahead at most) and drives my way
function ADIntersectionModule.isAheadMyWay(vehicle, other)
    if other == nil or other.components == nil or other.components[1] == nil or vehicle.ad == nil or vehicle.ad.drivePathModule == nil then
        return false
    end
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return false
    end
    local ox, _, oz = getWorldTranslation(other.components[1].node)
    local odx, _, odz = localDirectionToWorld(other.components[1].node, 0, 0, 1)
    local lastX, _, lastZ = getWorldTranslation(vehicle.components[1].node)
    local travelled = 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        local dx, dz = wp.x - lastX, wp.z - lastZ
        local l = MathUtil.vector2Length(dx, dz)
        if l > 0.01 then
            local t = math.max(0, math.min(1, ((ox - lastX) * dx + (oz - lastZ) * dz) / (l * l)))
            local px, pz = lastX + dx * t, lastZ + dz * t
            if MathUtil.vector2Length(ox - px, oz - pz) <= 2.5 then
                local ol = math.max(0.01, MathUtil.vector2Length(odx, odz))
                return travelled + t * l > 0.5 and (odx * dx + odz * dz) / (ol * l) > 0.5
            end
            travelled = travelled + l
            if travelled > 80 then
                break
            end
        end
        lastX, lastZ = wp.x, wp.z
    end
    return false
end

function ADIntersectionModule.isTrafficComing(vehicle, zone, horizon)
    local self = ADIntersectionModule
    local arrival = horizon or self.ARRIVAL_S
    self.scanVehicle = vehicle
    self.scanHits = {}
    self.scanSeen = {}
    local mask = getMask()
    for _, b in ipairs(zone.boxes) do
        overlapBox(b.x, b.y + self.BOX_HALF_HEIGHT + 0.2, b.z, 0, b.ry, 0, self.BOX_HALF_WIDTH, self.BOX_HALF_HEIGHT, b.half,
            "overlapCallback", self, mask, true, true, true, true)
        if ADIntersectionModule.DEBUG then
            DebugUtil.drawOverlapBox(b.x, b.y + self.BOX_HALF_HEIGHT + 0.2, b.z, 0, b.ry, 0, self.BOX_HALF_WIDTH, self.BOX_HALF_HEIGHT, b.half, 1, 0, 0)
        end
    end
    self.scanVehicle = nil

    local now = g_time
    -- 27/10 : traces PAR VÉHICULE. Elles étaient partagées : deux véhicules au même croisement (C15 D + 7R derrière, Magnum + MF)
    -- rafraîchissaient la même trace à 50 ms d'écart, le second n'en tirait jamais de vitesse et voyait une voiture
    -- arrêtée comme « voiture à 20 m » (danger) pendant des minutes
    local tracks = ADIntersectionModule.getTracks(vehicle)
    local c = vehicle.ad ~= nil and vehicle.ad.intersection or nil
    local danger, reason = false, nil
    -- the vehicle that waits for me before a single track (TrafficYield plan, stopped on purpose): not a danger,
    -- waiting for it would block us both (owner 25/10 21:08-21:20, Puma 240 CVX held by the 942 Vario waiting for it)
    local yieldModule = vehicle.ad ~= nil and vehicle.ad.trafficYieldModule or nil
    local waitingForMe = nil
    if yieldModule ~= nil and yieldModule.plan ~= nil and yieldModule.plan.parked and yieldModule.plan.waitBeforeSection then
        waitingForMe = yieldModule.partner
    end
    for _, h in ipairs(self.scanHits) do
      local isWaitingForMe = waitingForMe ~= nil and h.object ~= nil and (h.object == waitingForMe
            or (h.object.getRootVehicle ~= nil and h.object:getRootVehicle() == waitingForMe) or AutoDrive:checkIsConnected(waitingForMe, h.object))
      if not isWaitingForMe then
        local hx, _hy, hz
        if h.object ~= nil and h.object.rootNode ~= nil then
            hx, _hy, hz = getWorldTranslation(h.object.rootNode)
        else
            hx, _hy, hz = getWorldTranslation(h.node)
        end
        local d = math.huge
        for _, p in ipairs(zone.points) do
            d = math.min(d, MathUtil.vector2Length(hx - p.x, hz - p.z))
        end
        local speed
        if h.object ~= nil and h.object.lastSpeedReal ~= nil then
            speed = h.object.lastSpeedReal * 1000
        end
        local t = tracks[h.key]
        local closing = nil
        -- 27/10 : une trace jusqu'à 5 s (une voiture arrêtée vue par intermittence donnait « voiture à 36 m » sans vitesse)
        if t ~= nil and now - t.time > 100 and now - t.time < self.TRACK_MAX_MS then
            closing = (t.d - d) / ((now - t.time) / 1000)
        end
        if t == nil or now - t.time >= 100 then
            tracks[h.key] = { d = d, time = now }
        end
        if speed == nil and closing ~= nil then
            speed = math.abs(closing)
        end

        local name = h.object ~= nil and h.object.getFullName ~= nil and h.object:getFullName() or "voiture"
        -- 26/10 18:46 (Patriot bloqué par la remorque du 942 qui attendait, arrêté, avant sa propre ligne, à 4 m des points
        -- rouges ; derrière : Jaguar puis MT635) : un véhicule AutoDrive arrêté qui attend lui-même à sa ligne (ou recule)
        -- n'occupe pas le croisement, sauf s'il est vraiment sur les points (3 m) ; mon capteur me garde de son attelage
        local root = h.object ~= nil and h.object.getRootVehicle ~= nil and h.object:getRootVehicle() or h.object
        local stopped = (speed == nil or speed < self.MOVING_MS) and (closing == nil or math.abs(closing) < self.MOVING_MS)
        local waitingAtItsLine = root ~= nil and root.ad ~= nil and root.ad.intersection ~= nil and stopped
            and (root.ad.intersection.holding or root.ad.intersection.retreat ~= nil)
        -- 27/10 06:49 (7R 350 reculé dans une entrée de maison, à 4 m d'un point du croisement, qui attendait que le MT635 passe ;
        -- le MT635 attendait à sa ligne « 7R sur le croisement (4 m) ») : un véhicule AutoDrive arrêté que son plan de face à face
        -- tient (garé, reculé, en attente) attend que quelqu'un passe : pas un danger
        local parkedByYield = root ~= nil and root.ad ~= nil and root.ad.trafficYieldModule ~= nil and stopped
            and root.ad.trafficYieldModule.isControlling ~= nil and root.ad.trafficYieldModule:isControlling()
        -- 27/10 06:48 (Magnum à sa ligne, le MF à la sienne à 3 m d'un point, chacun attendant l'autre ; règle de Fabien :
        -- priorité à celui qui sort du chemin à double sens, l'autre s'engage ensuite) : la limite de 3 m devient 1,5 m,
        -- un véhicule qui attend à sa ligne n'est pas sur le croisement
        -- 27/10 : toutes les traces sont mises à jour à chaque passage (plus de « break » au premier danger), sinon une voiture
        -- vue derrière une autre gardait une trace périmée et repassait pour « inconnue »
        if danger then
            -- déjà un danger : trace mise à jour, rien d'autre
        elseif ADIntersectionModule.isAheadMyWay(vehicle, root) then
            -- 30/10 16:34 (Puma 240 CVX à sa ligne, « Patriot 4450 sur le croisement (1 m) » alors que le Patriot était devant lui,
            -- dans son sens, sur sa route) : une file, pas un danger ; mon capteur me tient derrière lui
            if c ~= nil and c.queueAheadLogged ~= root then
                c.queueAheadLogged = root
                ADIntersectionModule.log("%s : %s devant moi dans mon sens sur ma route, je le suis (file, pas un danger)",
                    tostring(vehicle:getFullName()), name)
            end
        elseif (waitingAtItsLine or parkedByYield) and d > 1.5 then
            -- pas un danger
        elseif d <= self.CLOSE_DIST and (d <= self.PARKED_DIST or not (stopped and (speed ~= nil or closing ~= nil))) then
            -- 27/10 06:50 (942, MT635 : « Krampe sur le croisement (8 m) », « 7R sur le croisement (4 m) », véhicules arrêtés par
            -- le joueur à côté du croisement) : un véhicule arrêté (vitesse connue) à plus de 4 m d'un point du croisement est à côté,
            -- mon capteur s'en occupe ; un véhicule qui bouge reste un danger jusqu'à 8 m
            danger, reason = true, string.format("%s sur le croisement (%.0f m)", name, d)
        elseif closing == nil then
            -- première vue (pas encore de vitesse d'approche) : on la suppose venant vers le croisement à 50 km/h (ou à sa
            -- vitesse connue), revu 250 ms plus tard. 27/10 : avant, une voiture vue pour la première fois à 120 m ne comptait
            -- pas, et un véhicule à sa ligne pouvait s'engager juste devant elle
            local assumed = speed or self.ASSUMED_MS
            if (speed == nil or speed > self.MOVING_MS) and (d < self.NEAR_DIST or d / assumed < arrival) then
                danger, reason = true, string.format("%s à %.0f m (vitesse inconnue)", name, d)
            end
        elseif closing > self.MOVING_MS and (d / closing < arrival or d < self.NEAR_DIST) then
            danger, reason = true, string.format("%s arrive (%.0f m, %.0f km/h)", name, d, closing * 3.6)
        end
      end
    end

    for k, t in pairs(tracks) do
        if now - t.time > 5000 then
            tracks[k] = nil
        end
    end
    return danger, reason
end

-------------------------------------------------------------------------------
-- Conduite
-------------------------------------------------------------------------------

local function getFrontOffset(vehicle)
    local size = vehicle.size
    if size == nil then
        return 3
    end
    return size.length * 0.5 + (size.lengthOffset or 0)
end

local function getTrainLength(vehicle)
    local total = 0
    local root = vehicle:getRootVehicle()
    if root.childVehicles ~= nil then
        for _, v in pairs(root.childVehicles) do
            if v.size ~= nil then
                total = total + v.size.length
            end
        end
    end
    if total <= 0 then
        total = vehicle.size ~= nil and vehicle.size.length or 6
    end
    return total
end

-- 27/10 : temps (s) pour traverser 'span' m depuis l'arrêt, d'après l'attelage : un véhicule seul et court démarre vite,
-- un attelage (remorque, outil) lentement
local function crossingTime(vehicle, span)
    local self = ADIntersectionModule
    local root = vehicle:getRootVehicle()
    local count = 0
    if root.childVehicles ~= nil then
        for _ in pairs(root.childVehicles) do
            count = count + 1
        end
    end
    local light = count <= 1 and getTrainLength(vehicle) <= self.LIGHT_TRAIN_M
    local accel = light and self.ACCEL_LIGHT or self.ACCEL_TRAIN
    local vmax = light and self.VMAX_LIGHT or self.VMAX_TRAIN
    local accelDist = vmax * vmax / (2 * accel)
    if span <= accelDist then
        return math.sqrt(2 * span / accel), light
    end
    return vmax / accel + (span - accelDist) / vmax, light
end

-- la voie après la portion rouge : boîtes le long de MON trajet après le dernier point rouge, sur 'length' m
local function buildExitBoxes(wayPoints, lastIndex, length)
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

-- un véhicule arrêté (ou presque) sur la voie de sortie : si je m'engage, je reste en travers du croisement
-- (26/10 17:24 : 942 Vario engagé alors que des voitures faisaient la queue sur la route derrière le 7R 350 arrêté)
function ADIntersectionModule.isExitBlocked(vehicle, wayPoints, lastIndex)
    local self = ADIntersectionModule
    local length = math.max(self.EXIT_MIN_LENGTH, getTrainLength(vehicle) + 8)
    local boxes, exitPoint = buildExitBoxes(wayPoints, lastIndex, length)
    if #boxes == 0 or exitPoint == nil then
        return false
    end
    self.scanVehicle = vehicle
    self.scanHits = {}
    self.scanSeen = {}
    local mask = getMask()
    for _, b in ipairs(boxes) do
        overlapBox(b.x, b.y + self.BOX_HALF_HEIGHT + 0.2, b.z, 0, b.ry, 0, self.BOX_HALF_WIDTH, self.BOX_HALF_HEIGHT, b.half,
            "overlapCallback", self, mask, true, true, true, true)
    end
    self.scanVehicle = nil
    local now = g_time
    local tracks = ADIntersectionModule.getTracks(vehicle)
    -- 26/10 20:00 (MT635 « sortie occupée : Tenwinkel B2500 » = la masse du 7R 350 qui attendait exprès pour lui 9 m avant le
    -- chemin) : le véhicule qui attend pour moi (plan de croisement) n'occupe pas ma sortie, je le vois avec mon capteur
    local yieldModule = vehicle.ad ~= nil and vehicle.ad.trafficYieldModule or nil
    local waitingForMe = nil
    if yieldModule ~= nil and yieldModule.plan ~= nil and yieldModule.plan.parked and yieldModule.plan.waitBeforeSection then
        waitingForMe = yieldModule.partner
    end
    for _, h in ipairs(self.scanHits) do
      local isWaitingForMe = waitingForMe ~= nil and h.object ~= nil and (h.object == waitingForMe
            or (h.object.getRootVehicle ~= nil and h.object:getRootVehicle() == waitingForMe) or AutoDrive:checkIsConnected(waitingForMe, h.object))
      if not isWaitingForMe then
        local hx, _hy, hz
        if h.object ~= nil and h.object.rootNode ~= nil then
            hx, _hy, hz = getWorldTranslation(h.object.rootNode)
        else
            hx, _hy, hz = getWorldTranslation(h.node)
        end
        local d = MathUtil.vector2Length(hx - exitPoint.x, hz - exitPoint.z)
        local speed
        if h.object ~= nil and h.object.lastSpeedReal ~= nil then
            speed = math.abs(h.object.lastSpeedReal) * 1000
        end
        local key = "exit:" .. tostring(h.key)
        local t = tracks[key]
        if speed == nil and t ~= nil and now - t.time > 100 and now - t.time < 2000 then
            speed = math.abs(d - t.d) / ((now - t.time) / 1000)
        end
        if t == nil or now - t.time >= 100 then
            tracks[key] = { d = d, time = now }
        end
        -- vitesse inconnue (première vue d'une voiture du trafic) : on la considère arrêtée, revu 250 ms plus tard
        if speed == nil or speed < self.MOVING_MS then
            local name = h.object ~= nil and h.object.getFullName ~= nil and h.object:getFullName() or "voiture"
            return true, string.format("sortie occupée : %s arrêté à %.0f m après le croisement", name, d)
        end
      end
    end
    return false
end

-- première portion rouge sur le trajet devant : {dist = m de l'avant au 1er point rouge, endDist, key, zone}
local function findIntersection(vehicle)
    local dpm = vehicle.ad.drivePathModule
    local wayPoints, index = dpm:getWayPoints()
    if wayPoints == nil or index == nil or wayPoints[index] == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local front = getFrontOffset(vehicle)
    local cum = -front
    local px, pz = x, z
    local i = index
    while wayPoints[i] ~= nil and cum < ADIntersectionModule.LOOK_AHEAD do
        local wp = wayPoints[i]
        cum = cum + MathUtil.vector2Length(wp.x - px, wp.z - pz)
        if ADIntersectionModule.isIntersectionPoint(wp) then
            -- la portion rouge peut déjà être commencée : on remonte au premier point rouge
            local first = i
            while first > 1 and ADIntersectionModule.isIntersectionPoint(wayPoints[first - 1]) do
                first = first - 1
            end
            local last = i
            local endDist = cum
            local lx, lz = wp.x, wp.z
            while wayPoints[last + 1] ~= nil and ADIntersectionModule.isIntersectionPoint(wayPoints[last + 1]) do
                last = last + 1
                endDist = endDist + MathUtil.vector2Length(wayPoints[last].x - lx, wayPoints[last].z - lz)
                lx, lz = wayPoints[last].x, wayPoints[last].z
            end
            if wayPoints[last + 1] ~= nil then
                endDist = endDist + MathUtil.vector2Length(wayPoints[last + 1].x - lx, wayPoints[last + 1].z - lz)
            end
            local key = tostring(wayPoints[first].id or (math.floor(wayPoints[first].x) .. ":" .. math.floor(wayPoints[first].z)))
            local zone = ADIntersectionModule.zones[key]
            if zone == nil then
                zone = ADIntersectionModule.buildZone(wayPoints, first, last)
                ADIntersectionModule.zones[key] = zone
                ADIntersectionModule.log("portion %s : %d segments de voie surveillés, %d boîtes", key, zone.lanes, #zone.boxes)
            end
            local dist = first < index and -1 or cum
            return { dist = dist, endDist = endDist, key = key, zone = zone, lastIndex = last, wayPoints = wayPoints }
        end
        px, pz = wp.x, wp.z
        i = i + 1
    end
    return nil
end

function ADIntersectionModule.reset(vehicle)
    local c = vehicle.ad.intersection
    if c ~= nil and (c.holding or c.retreat ~= nil) and vehicle.ad.specialDrivingModule ~= nil then
        vehicle.ad.specialDrivingModule:releaseVehicle()
    end
    vehicle.ad.intersection = nil
end

-- true tant que le croisement tient le véhicule : approche ralentie, arrêt avant la ligne ou recul raté
-- (27/10 06:47, Patriot : le capteur voyait la voiture arrêtée devant lui pendant qu'il attendait,
-- le contournement l'a fait reculer de 8 m et chercher une route autour de la voiture)
function ADIntersectionModule.isWaiting(vehicle)
    local c = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.intersection or nil
    if c == nil then
        return false
    end
    return c.holding == true or c.retreat ~= nil or c.speed ~= nil
end

-- vitesse maxi demandée (km/h) ou math.huge
function ADIntersectionModule.getSpeedLimit(vehicle)
    local c = vehicle.ad ~= nil and vehicle.ad.intersection or nil
    if c == nil or c.speed == nil then
        return math.huge
    end
    return c.speed
end

local function hold(vehicle, dt)
    -- owner 30/10 16:38 (Puma 240 CVX held 80 s at its line without any word in the log): every 10 s while held, why
    local c = vehicle.ad.intersection
    if c ~= nil then
        c.heldSince = c.heldSince or g_time
        if g_time - (c.heldLogTime or 0) >= 10000 then
            c.heldLogTime = g_time
            ADIntersectionModule.log("%s retenu a sa ligne depuis %.0f s : %s (ligne a %s m, attente %s)", tostring(vehicle:getFullName()),
                (g_time - c.heldSince) / 1000, tostring(c.heldWhy or c.lastReason), c.lastToStop ~= nil and string.format("%.1f", c.lastToStop) or "?",
                c.waited and "oui" or "non")
        end
    end
    local sdm = vehicle.ad.specialDrivingModule
    sdm.motorShouldNotBeStopped = true
    sdm:stopVehicle()
    sdm:update(dt)
    sdm.motorShouldNotBeStopped = false
end

-- appelé à chaque image par ADDrivePathModule:followWaypoints ; renvoie true si le véhicule doit rester à l'arrêt
function ADIntersectionModule.handle(vehicle, dt)
    if vehicle == nil or vehicle.ad == nil or not vehicle.isServer then
        return false
    end
    local dpm = vehicle.ad.drivePathModule
    if dpm == nil or dpm:getIsReversing() then
        return false
    end
    local c = vehicle.ad.intersection
    if c == nil then
        c = { nextCheck = 0, clearTime = 0 }
        vehicle.ad.intersection = c
    end

    -- raté : arrêté sur la portion rouge, il recule jusqu'à être de nouveau avant la ligne, puis attend
    if c.retreat ~= nil then
        return ADIntersectionModule.updateRetreat(vehicle, c, dt)
    end

    -- 26/10 21:46 (7R 350 « entre deux procédures ») : pendant que le module de croisement face à face conduit le véhicule
    -- (recul, attente avant un chemin unique), le croisement ne décide rien (ni « libre, il traverse », ni recul raté)
    local yieldModule = vehicle.ad.trafficYieldModule
    if yieldModule ~= nil and yieldModule.isControlling ~= nil and yieldModule:isControlling() and c.committed == nil then
        return false
    end

    -- engagé : on traverse sans regarder jusqu'à ce que tout l'attelage soit passé
    if c.committed ~= nil then
        c.travel = c.travel + (vehicle.lastMovedDistance or 0)
        if c.travel > c.committed.span then
            c.done = { key = c.committed.key, time = g_time }
            c.committed = nil
            c.stuckMs = 0
            c.speed = nil
            c.noRetreat = nil
            c.queuedLogged = nil
            return false
        end
        -- 26/10 17:55 (7R 350 arrêté en plein croisement, voitures derrière) : « il n'est pas supposé attendre en plein milieu,
        -- s'il se rate il doit immédiatement reculer sans attendre » : arrêté sur la portion rouge (capteur, véhicule devant)
        -- sans en être sorti -> recul immédiat jusqu'avant la ligne
        local kmh = math.abs(vehicle.lastSpeedReal or 0) * 3600
        if kmh < 0.5 and c.travel > 0.5 then
            c.stuckMs = (c.stuckMs or 0) + dt
            if c.stuckMs >= ADIntersectionModule.RETREAT_STUCK_MS then
                -- 26/10 18:55 (MT635 au rond-point, arrêté dans une file derrière une voiture qui attendait, reculé vers la voiture
                -- de derrière) : « il s'était simplement arrêté dans une file » : un véhicule juste devant moi, dans mon sens,
                -- n'est pas un raté, j'attends qu'il reparte. Pas non plus de recul quand il est impossible ou déjà fait 2 fois ici.
                local queued, queuedName = ADIntersectionModule.isQueuedBehindVehicle(vehicle)
                c.retreatCount = c.retreatCount or {}
                -- engagé et bloqué depuis longtemps sans recul possible : je rends la main (le face à face peut se négocier)
                if c.stuckMs >= ADIntersectionModule.COMMIT_STUCK_MS and (queued or c.noRetreat == c.committed.key or (c.retreatCount[c.committed.key] or 0) >= 2) then
                    ADIntersectionModule.log("%s engagé mais bloqué depuis %d s, le croisement rend la main", tostring(vehicle:getFullName()), math.floor(c.stuckMs / 1000))
                    c.done = { key = c.committed.key, time = g_time }
                    c.committed = nil
                    c.stuckMs = 0
                    c.speed = nil
                    c.noRetreat = nil
                    c.queuedLogged = nil
                    return false
                end
                if queued then
                    if not c.queuedLogged then
                        c.queuedLogged = true
                        ADIntersectionModule.log("%s arrêté derrière %s sur la portion rouge (même sens), il attend qu'il reparte", tostring(vehicle:getFullName()), tostring(queuedName))
                    end
                elseif c.noRetreat ~= c.committed.key and (c.retreatCount[c.committed.key] or 0) < 2 then
                    c.retreatCount[c.committed.key] = (c.retreatCount[c.committed.key] or 0) + 1
                    ADIntersectionModule.startRetreat(vehicle, c)
                    return true
                end
            end
        else
            c.stuckMs = 0
            c.queuedLogged = nil
        end
        c.speed = nil
        return false
    end

    if g_time < c.nextCheck then
        if c.holding then
            hold(vehicle, dt)
            return true
        end
        return false
    end
    c.nextCheck = g_time + ADIntersectionModule.CHECK_MS

    local inter = findIntersection(vehicle)
    if c.done ~= nil and g_time - c.done.time > 60000 then
        c.done = nil
    end
    if inter ~= nil and c.done ~= nil and c.done.key == inter.key then
        inter = nil
    end
    if inter == nil then
        if c.holding then
            vehicle.ad.specialDrivingModule:releaseVehicle()
        end
        c.holding, c.waited, c.clearTime, c.speed = false, false, 0, nil
        c.waitStart, c.patienceLogged = nil, nil
        c.heldSince, c.heldLogTime = nil, nil
        return false
    end

    local toStop = inter.dist - ADIntersectionModule.STOP_BEFORE
    c.lastToStop = toStop
    -- 26/10 18:01 (942 Vario engagé, une voiture arrivée 8 s plus tard s'est arrêtée devant son nez dans l'entrée du chemin) :
    -- l'horizon dépend du temps que met l'attelage à traverser toute la portion rouge en partant de l'arrêt
    local crossSpan = math.max(0, inter.endDist) + getTrainLength(vehicle) + 2
    -- 27/10 : temps de traversée d'après l'attelage (accélération, vitesse), 8 à 14 s
    local horizon = math.min(ADIntersectionModule.ARRIVAL_MAX_S, math.max(ADIntersectionModule.ARRIVAL_S, crossingTime(vehicle, crossSpan) + 2))
    -- 27/10 : patience. Après 45 s à la ligne, le trou exigé dans le trafic baisse de 1 s toutes les 15 s, jusqu'à 5 s :
    -- sur une route au trafic régulier (C15 D : une voiture toutes les 15 s à 48 km/h), un trou de 14 s ne vient jamais
    if c.waited and c.waitStart ~= nil and g_time - c.waitStart > ADIntersectionModule.PATIENCE_MS then
        local relaxed = math.max(ADIntersectionModule.PATIENCE_MIN_S,
            horizon - math.floor((g_time - c.waitStart - ADIntersectionModule.PATIENCE_MS) / ADIntersectionModule.PATIENCE_STEP_MS) - 1)
        if relaxed < horizon then
            if c.patienceLogged ~= relaxed then
                c.patienceLogged = relaxed
                ADIntersectionModule.log("%s attend depuis %.0f s, il se contente d'un trou de %.0f s dans le trafic (au lieu de %.0f s)",
                    tostring(vehicle:getFullName()), (g_time - c.waitStart) / 1000, relaxed, horizon)
            end
            horizon = relaxed
        end
    end
    local danger, reason = ADIntersectionModule.isTrafficComing(vehicle, inter.zone, horizon)
    if not danger and toStop > -1 then
        danger, reason = ADIntersectionModule.isExitBlocked(vehicle, inter.wayPoints, inter.lastIndex)
    end
    local name = tostring(vehicle:getFullName())
    -- what the 10 s log says while held: the danger seen right now, or how long it has been clear
    if danger then
        c.heldWhy = tostring(reason)
    elseif c.waited and c.clearTime ~= 0 then
        c.heldWhy = string.format("plus de danger depuis %.1f s (motif d'avant : %s)", (g_time - c.clearTime) / 1000, tostring(c.lastReason))
    else
        c.heldWhy = "plus de danger (motif d'avant : " .. tostring(c.lastReason) .. ")"
    end

    local function commit()
        if c.holding then
            vehicle.ad.specialDrivingModule:releaseVehicle()
        end
        c.committed = { key = inter.key, span = math.max(0, inter.endDist) + getTrainLength(vehicle) + 2 }
        c.travel = 0
        c.holding, c.waited, c.clearTime, c.speed = false, false, 0, nil
        c.waitStart, c.patienceLogged = nil, nil
        c.heldSince, c.heldLogTime = nil, nil
    end

    if danger then
        c.clearTime = 0
        if not c.waited then
            c.waited = true
            c.waitStart, c.patienceLogged = g_time, nil
            ADIntersectionModule.log("%s attend : %s", name, tostring(reason))
            c.lastReason, c.lastReasonTime = reason, g_time
        elseif reason ~= c.lastReason and g_time - (c.lastReasonTime or 0) > 5000 then
            -- le motif change pendant l'attente : dit lequel (26/10 : 942 resté 1 min « en attente » sans motif dans le log)
            ADIntersectionModule.log("%s attend toujours : %s", name, tostring(reason))
            c.lastReason, c.lastReasonTime = reason, g_time
        end
        if toStop <= 1 then
            if toStop < -1 and not c.holding then
                -- déjà sur la portion rouge : trop tard pour s'arrêter, il passe
                ADIntersectionModule.log("%s déjà engagé, il passe", name)
                commit()
                return false
            end
            c.holding = true
        end
        local v = math.sqrt(2 * ADIntersectionModule.BRAKE_DECEL * math.max(0, toStop)) * 3.6
        c.speed = math.max(3, math.min(ADIntersectionModule.APPROACH_KMH, v))
    else
        if c.waited and c.clearTime == 0 then
            c.clearTime = g_time
        end
        local clearLongEnough = not c.waited or g_time - c.clearTime >= ADIntersectionModule.CLEAR_MS
        if toStop <= ADIntersectionModule.COMMIT_DIST and clearLongEnough then
            if c.waited then
                ADIntersectionModule.log("%s libre, il traverse", name)
            end
            commit()
            return false
        end
        if c.waited and toStop <= 1 then
            c.holding = true
        end
        if toStop < ADIntersectionModule.APPROACH_DIST then
            local look = ADIntersectionModule.LOOK_KMH / 3.6
            local v = math.sqrt(look * look + 2 * ADIntersectionModule.BRAKE_DECEL * math.max(0, toStop - ADIntersectionModule.COMMIT_DIST)) * 3.6
            c.speed = math.min(ADIntersectionModule.APPROACH_KMH, v)
        else
            c.speed = nil
        end
    end

    if c.holding then
        hold(vehicle, dt)
        return true
    end
    return false
end

-- recul hors de la portion rouge (le module croisement n'a pas de marche arrière à lui : celle du module de croisement
-- face à face, le long de ma propre route)
-- arrêté juste derrière un véhicule (à moins de 8 m sur ma route) qui va dans mon sens, ou dont le sens est inconnu :
-- une file, pas un raté. Renvoie aussi le nom du véhicule.
function ADIntersectionModule.isQueuedBehindVehicle(vehicle)
    local am = vehicle.ad ~= nil and vehicle.ad.approachModule or nil
    if am == nil or am.getHit == nil then
        return false
    end
    local hit = am:getHit()
    if hit == nil or not hit.isVehicle or (hit.distance or 99) > 8 then
        return false
    end
    local node = nil
    if hit.object ~= nil then
        node = hit.object.rootNode or hit.object.node
    end
    if node ~= nil and entityExists ~= nil and entityExists(node) and localDirectionToWorld ~= nil then
        local ox, _, oz = localDirectionToWorld(node, 0, 0, 1)
        local mx, _, mz = localDirectionToWorld(vehicle.components[1].node, 0, 0, 1)
        local sameWay = ox * mx + oz * mz > 0.5
        return sameWay, hit.name
    end
    return true, hit.name
end

function ADIntersectionModule.startRetreat(vehicle, c)
    local yieldModule = vehicle.ad.trafficYieldModule
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local needed = c.travel + ADIntersectionModule.STOP_BEFORE + 1
    local targets = {}
    if yieldModule ~= nil and yieldModule.buildReverseTargets ~= nil then
        targets = yieldModule:buildReverseTargets(needed + 10)
    end
    ADIntersectionModule.log("%s raté : arrêté %.0f m après le début de la portion rouge, il recule de %.0f m pour attendre avant la ligne (%d points)",
        tostring(vehicle:getFullName()), c.travel, needed, #targets)
    c.retreat = { needed = needed, targets = targets, index = 1, startX = x, startZ = z, startTime = g_time, blockedMs = 0, key = c.committed.key, span = c.committed.span, travel = c.travel }
    c.committed = nil
    c.stuckMs = 0
    c.speed = nil
    if vehicle.ad.specialDrivingModule ~= nil then
        vehicle.ad.specialDrivingModule:releaseVehicle()
    end
end

function ADIntersectionModule.updateRetreat(vehicle, c, dt)
    local r = c.retreat
    local yieldModule = vehicle.ad.trafficYieldModule
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local reversed = MathUtil.vector2Length(x - r.startX, z - r.startZ)
    local target = r.targets[r.index]
    local blocked = vehicle.ad.collisionDetectionModule ~= nil and vehicle.ad.collisionDetectionModule:checkReverseCollision()
    if blocked then
        r.blockedMs = r.blockedMs + dt
    else
        r.blockedMs = 0
    end
    local finished = reversed >= r.needed or target == nil or yieldModule == nil or yieldModule.reverseTowards == nil
        or g_time - r.startTime > ADIntersectionModule.RETREAT_TIMEOUT_MS
    -- 26/10 18:48 (Jaguar : 40 s pour 7 m, le MT635 collé derrière ; 942 : 40 s pour 9 m, le MF 7S derrière) : reculer est
    -- impossible, inutile d'attendre le délai puis de faire comme si j'étais avant la ligne : je reste engagé et j'attends
    -- que ça se libère devant (pas de nouveau recul à ce croisement)
    if not finished and r.blockedMs >= ADIntersectionModule.RETREAT_BLOCKED_MS then
        ADIntersectionModule.log("%s recul impossible (véhicule derrière) après %.0f m sur %.0f m, il reste engagé et attend", tostring(vehicle:getFullName()), reversed, r.needed)
        c.retreat = nil
        c.committed = { key = r.key, span = r.span }
        c.travel = math.max(0, r.travel - reversed)
        c.noRetreat = r.key
        c.stuckMs = 0
        c.speed = nil
        if ADTrafficYieldModule ~= nil and ADTrafficYieldModule.resyncWayPoints ~= nil then
            ADTrafficYieldModule.resyncWayPoints(vehicle, r.reachedRouteIndex)
        end
        if vehicle.ad.specialDrivingModule ~= nil then
            vehicle.ad.specialDrivingModule:releaseVehicle()
        end
        return false
    end
    if finished then
        ADIntersectionModule.log("%s reculé de %.0f m sur %.0f m%s, il attend avant la ligne", tostring(vehicle:getFullName()), reversed, r.needed,
            (target == nil and " (plus de route derrière)") or (g_time - r.startTime > ADIntersectionModule.RETREAT_TIMEOUT_MS and " (délai)") or "")
        c.retreat = nil
        c.done = nil
        c.holding, c.waited, c.clearTime, c.speed = true, true, 0, nil
        c.waitStart, c.patienceLogged = g_time, nil
        c.nextCheck = 0
        if ADTrafficYieldModule ~= nil and ADTrafficYieldModule.resyncWayPoints ~= nil then
            ADTrafficYieldModule.resyncWayPoints(vehicle, r.reachedRouteIndex)
        end
        hold(vehicle, dt)
        return true
    end
    if blocked then
        -- une voiture collée derrière : on la laisse partir (le trafic du jeu finit par contourner ou reculer), on retente
        local sdm = vehicle.ad.specialDrivingModule
        sdm:stopAndHoldVehicle(dt)
        return true
    end
    if yieldModule:reverseTowards(dt, target) then
        if target.routeIndex ~= nil then
            r.reachedRouteIndex = target.routeIndex
        end
        r.index = r.index + 1
    end
    return true
end

-- le réseau a changé (éditeur) : zones à recalculer
function ADIntersectionModule.clearCache()
    ADIntersectionModule.zones = {}
end
