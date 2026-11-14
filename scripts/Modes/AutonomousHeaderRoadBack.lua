-- ============================================================================================================
-- FarmPilot : AutonomousHeaderRoadBack.lua
-- Mode Autonome, moissonneuse équipée seule : la remorque porte-barre est RECULÉE TOUT DROIT le long du chemin du
-- champ jusqu'à la route, la barre en travers du croisement. La moissonneuse, qui arrive par cette route, prend sa
-- barre de face, recule un peu, puis va au champ par le chemin.
--
-- Règle (13/11) :
-- - Quand : au départ, côté du cadre de la barre encombré au bout de la route du champ et rien de dégagé à moins de
--   BACKIN_PREFER m avant (culture des deux côtés du chemin). Essayé AVANT la marche arrière en biais dans l'entrée
--   du champ (AutonomousHeaderBackIn.lua), qui reste pour les endroits sans croisement.
-- - Le croisement est lu sur la route du tracteur, rien n'est écrit pour un endroit : le dernier tronçon droit de sa
--   route est le chemin du champ ; juste avant, la route le rejoint à peu près à angle droit (ROADBACK_SKEW). Le
--   croisement est le point où l'axe du chemin coupe l'axe de la route.
-- - Il faut : le cadre de la barre tourné vers la route d'où vient la moissonneuse (remorque dans l'axe du chemin,
--   l'avant vers le champ) ; la moissonneuse qui arrive par cette route, dans le même sens que le tracteur ; assez
--   de chemin droit après le croisement pour s'arrêter ROADBACK_BACK m plus loin que la place finale (au moins
--   ROADBACK_BACK_MIN) ; de l'autre côté de la route, la place de l'arrière de la remorque (ni culture, ni eau, ni
--   fossé, ni obstacle) ; devant le cadre, la route libre pour la moissonneuse (roues hors culture, pas d'obstacle
--   sur la largeur de la barre là où elle recule avec) ; et la route du croisement au champ assez large pour la
--   barre (AutonomousHeaderEntry.lua : roadFits).
-- - Le tracteur passe le croisement, suit le chemin, s'arrête dans son axe, puis recule tout droit
--   (Tasks/HeaderRoadBackTask.lua) jusqu'à ce que le cadre de la barre soit sur l'axe de la route.
-- - La moissonneuse s'arrête sur la route en face du cadre, son attelage à ROADBACK_KEEP m du croisement (au lieu de
--   l'arrêt habituel avant le chemin). Remorque en place : elle avance droit sur le cadre, sans détour par le réseau
--   ni recherche de chemin. Si elle n'est pas encore en face du cadre à ce moment-là (retenue plus tôt derrière la
--   remorque, encore en route), elle finit d'abord sa route jusqu'à cet arrêt.
-- - (13/11 soir) Elle n'arrive JAMAIS sur la barre par l'autre bout de la route (côté rabatteur) :
--   encore en route quand la remorque est en place, elle GARDE sa route jusqu'à son arrêt (rien n'est recalculé) ;
--   arrêtée plus tôt, sa nouvelle route repart du point qu'elle suivait (AutonomousHeaderFollow.lua : resumeStart)
--   et son arrivée est contrôlée (roadBackArrives : ses derniers points sont avant le croisement, sur l'axe de la
--   route). Route qui arrive par l'autre bout : les autres départs devant elle sont essayés (roadBackRouteStart) ;
--   aucun ne va : elle ne part pas, la remorque est déplacée (comme « pas de chemin jusqu'à la barre »).
-- - Barre prise : elle recule juste de la profondeur de la barre plus ROADBACK_EXIT_MARGIN m (pas la longue sortie
--   en marche arrière), attend que le tracteur soit reparti par le chemin, puis va au champ par le réseau.
-- - Recul pas réussi (bloqué, trop de travers, un coin dans la culture au bord du chemin, pas fini), ou cadre pas
--   tourné vers la route à la fin : endroit suivant, comme un endroit encombré (AutonomousHeaderSpot.lua : moveOn).
--   Remorque pas assez droite à l'arrêt : rien ne bouge, l'endroit est jugé comme d'habitude.
-- - Réglage ROADBACK = false : comme avant.
--
-- Branché par : Modes/AutonomousHeaderBackIn.lua (backInTry et startBackIn, enveloppés ici),
-- Modes/AutonomousHeader.lua (tractorStage « roadBack », monitor, goToHeader, AutonomousMode:reset et
-- startFetchAttach, enveloppés ici), Modes/AutonomousHeaderSpot.lua (moveOn, enveloppé ici), Modes/AutonomousHeaderFollow.lua
-- (followMonitor et followStopIndex, enveloppés ici), Modes/AutonomousFront.lua (afterFetch et fetchRoutePoint,
-- enveloppés ici), Modules/TrafficYieldModuleObstacles.lua (overlapCallback, enveloppé ici). Chargé par
-- register.lua après AutonomousHeaderEntry.lua et avant AutonomousHeaderHookup.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.ROADBACK = true               -- false : jamais de recul de la remorque jusqu'à la route
ADHeaderFlow.ROADBACK_SPAN = 60            -- m du bout de la route du tracteur : le chemin droit finit avant
ADHeaderFlow.ROADBACK_BASE = 8             -- m de route droite au moins pour y voir le chemin du champ
ADHeaderFlow.ROADBACK_CHORD_DEV = 0.75     -- m d'écart au plus à la ligne, sur cette longueur
ADHeaderFlow.ROADBACK_LANE_MAX = 80        -- m de chemin au plus du croisement au bout de la route
ADHeaderFlow.ROADBACK_SKEW = 25            -- ° d'écart à l'angle droit, au plus, entre la route et le chemin
ADHeaderFlow.ROADBACK_ROAD_STRAIGHT = 15   -- ° : route droite avant le croisement
ADHeaderFlow.ROADBACK_CORNER = 15          -- m du croisement au plus pour le dernier point de la route et le premier du chemin
ADHeaderFlow.ROADBACK_FACE = 25            -- ° au plus entre le cadre de la barre et la route d'où vient la moissonneuse
ADHeaderFlow.ROADBACK_ARRIVE = 30          -- ° au plus entre la route de la moissonneuse et celle du tracteur, au croisement
ADHeaderFlow.ROADBACK_FRAME_AT = 0         -- m après le croisement où le cadre de la barre s'arrête (0 = sur l'axe de la route)
ADHeaderFlow.ROADBACK_BACK = 20            -- m de recul : le tracteur s'arrête ça plus loin que sa place finale (la remorque a le temps de se remettre droite après le virage)
ADHeaderFlow.ROADBACK_BACK_MIN = 8         -- m de recul au moins (chemin court)
ADHeaderFlow.ROADBACK_END_MARGIN = 1       -- m de chemin gardés devant le tracteur arrêté
ADHeaderFlow.ROADBACK_ALIGN = 3            -- m de chemin au moins entre le virage et l'essieu de la remorque, à l'arrêt
ADHeaderFlow.ROADBACK_ROUTE_STEP = 5       -- m entre les points de la route ajoutés sur le chemin
ADHeaderFlow.ROADBACK_SPEED = 5            -- km/h
ADHeaderFlow.ROADBACK_SLOW = 2             -- km/h sur les derniers mètres
ADHeaderFlow.ROADBACK_SLOW_DISTANCE = 2.5  -- m
ADHeaderFlow.ROADBACK_STOP_LEAD = 0.3      -- m : l'arrêt est demandé ça avant la fin (le temps de freiner)
ADHeaderFlow.ROADBACK_START_SIDE = 2.3     -- m d'écart au milieu du chemin, au plus, pour l'essieu de la remorque au départ
ADHeaderFlow.ROADBACK_START_ANGLE = 12     -- ° d'écart au chemin, au plus, pour la remorque au départ
ADHeaderFlow.ROADBACK_MAX_HITCH = 40       -- ° entre tracteur et remorque : au-delà, arrêt (recul droit : ils restent presque alignés)
ADHeaderFlow.ROADBACK_CROP_CHECK = 250     -- ms entre deux contrôles des coins du tracteur et de la remorque (culture au bord du chemin)
ADHeaderFlow.ROADBACK_CROP_SHRINK = 0.3    -- m : les coins sont pris ça en dedans
ADHeaderFlow.ROADBACK_REAR_MARGIN = 1.5    -- m dégagés derrière la remorque, de l'autre côté de la route
ADHeaderFlow.ROADBACK_REAR_SIDE = 0.6      -- m dégagés de chaque côté de la remorque là où elle traverse
ADHeaderFlow.ROADBACK_WHEEL_MARGIN = 0.75  -- m de chaque côté de la moissonneuse (sol : culture, eau, fossé)
ADHeaderFlow.ROADBACK_APPROACH = 8         -- m devant l'attelage de la moissonneuse, contrôlés devant le cadre
ADHeaderFlow.ROADBACK_HEADER_MARGIN = 0.7  -- m de chaque côté de la barre (obstacles), là où la moissonneuse recule avec elle
ADHeaderFlow.ROADBACK_PREDICT = 0.5        -- m en plus de chaque côté pour un contrôle fait de loin
ADHeaderFlow.ROADBACK_KEEP = 12            -- m entre l'attelage de la moissonneuse arrêtée et le croisement (la place de se mettre dans l'axe du cadre)
ADHeaderFlow.ROADBACK_KEEP_MIN = 9         -- m au moins, quand la route tourne trop plus loin
ADHeaderFlow.ROADBACK_ROAD_SIDE = 4        -- m de l'axe de la route au plus, pour l'arrêt de la moissonneuse
ADHeaderFlow.ROADBACK_STOP_ANGLE = 20      -- ° au plus entre la route à cet arrêt et la route au croisement
ADHeaderFlow.ROADBACK_ROAD_FROM = 8        -- m avant le croisement : la route de la barre est contrôlée à partir de là
ADHeaderFlow.ROADBACK_EXIT_MARGIN = 2      -- m de recul après l'attelage, en plus de la profondeur de la barre
ADHeaderFlow.ROADBACK_FINAL = 3            -- m entre l'attelage de la moissonneuse et le cadre, au bout de son approche
ADHeaderFlow.ROADBACK_END_STRAIGHT = 5     -- m tout droit dans l'axe du cadre, au bout de son approche
ADHeaderFlow.ROADBACK_END_STRAIGHT_MIN = 2 -- m tout droit au moins, quand elle part de près
ADHeaderFlow.ROADBACK_JOIN_ANGLE = 25      -- ° au plus entre l'axe du cadre et la ligne par laquelle elle le rejoint
ADHeaderFlow.ROADBACK_APPROACH_MAX = 30    -- m devant le cadre au plus pour cette approche en ligne droite
ADHeaderFlow.ROADBACK_APPROACH_ANGLE = 35  -- ° au plus entre la moissonneuse et l'axe du cadre pour cette approche
ADHeaderFlow.ROADBACK_HANDOVER = 3         -- m avant son arrêt : venue de loin par le réseau, elle lâche la route là

-- ------------------------------------------------------------------------------------------------------------
-- Petits outils
-- ------------------------------------------------------------------------------------------------------------
local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function label(o)
    return o ~= nil and ADAutonomousManager.toolLabel ~= nil and ADAutonomousManager.toolLabel(o) or "?"
end

local function unit(x, z)
    local l = MathUtil.vector2Length(x, z)
    if l < 0.001 then
        return nil
    end
    return x / l, z / l
end

local function dist(a, b)
    return MathUtil.vector2Length(a.x - b.x, a.z - b.z)
end

local function groundY(x, z)
    if getTerrainHeightAtWorldPos == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return 0
    end
    return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
end

local function hasCrop(x, z)
    return ADFieldPark ~= nil and ADFieldPark.hasGrowingCrop ~= nil and ADFieldPark.hasGrowingCrop(x, z) == true
end

-- profondeur et envergure de la barre
local function headerDims(header)
    if ADHeaderFlow.headerBox ~= nil then
        return ADHeaderFlow.headerBox(header)
    end
    local size = header ~= nil and header.size or nil
    local w, l = size ~= nil and size.width or 9, size ~= nil and size.length or 3
    return math.min(w, l), math.max(w, l)
end

-- m du repère de la moissonneuse à son attelage avant
local function jointAhead(combine, header)
    local ahead = ((combine.size ~= nil and combine.size.length) or ADHeaderFlow.DEFAULT_COMBINE_LENGTH) / 2
    local _, joint = ADAutonomousManager.matchFrontJoints(combine, header, false)
    if joint ~= nil and joint.jointTransform ~= nil then
        local jx, jy, jz = getWorldTranslation(joint.jointTransform)
        local _, _, z = worldToLocal(combine.components[1].node, jx, jy, jz)
        if z > 0.5 then
            ahead = z
        end
    end
    return ahead
end

-- sens du tronçon de route qui arrive au point i
local function heading(points, i)
    local k = i - 1
    while k >= 1 do
        local dx, dz = unit(points[i].x - points[k].x, points[i].z - points[k].z)
        if dx ~= nil then
            return dx, dz
        end
        k = k - 1
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Obstacles : la moissonneuse qui attend sur la route n'en est pas un
-- ------------------------------------------------------------------------------------------------------------
-- (le véhicule mis de côté par overlapIgnoreVehicle est la barre ; overlapIgnoreAlso en met un deuxième de côté)
if ADTrafficYieldModule ~= nil and ADTrafficYieldModule.overlapCallback ~= nil then
    local baseCallback = ADTrafficYieldModule.overlapCallback
    function ADTrafficYieldModule:overlapCallback(transformId)
        local also = self.overlapIgnoreAlso
        if also ~= nil and transformId ~= nil and transformId ~= 0 and g_currentMission ~= nil and g_currentMission.getNodeObject ~= nil then
            local object = g_currentMission:getNodeObject(transformId)
            if object == nil and getParent ~= nil then
                local parent = getParent(transformId)
                if parent ~= nil and parent ~= 0 then
                    object = g_currentMission:getNodeObject(parent)
                end
            end
            if object ~= nil and (object == also or (also.getRootVehicle ~= nil and AutoDrive:checkIsConnected(also:getRootVehicle(), object))) then
                return true
            end
        end
        return baseCallback(self, transformId)
    end
end

-- boîte (centre, sens, demi-largeur, demi-longueur), de 0,3 m à 3,3 m au-dessus du sol : quelque chose dedans ?
-- full = tout compte (véhicules aussi, sauf l'attelage du tracteur, la barre et la moissonneuse) ; sinon les
-- obstacles fixes seulement. 2e valeur : son nom
local function boxHit(t, job, cx, cz, dx, dz, halfWidth, halfLength, full)
    local yield = t.ad ~= nil and t.ad.trafficYieldModule or nil
    if yield == nil then
        return false
    end
    local y, ry = groundY(cx, cz) + 1.8, MathUtil.getYRotationFromDirection(dx, dz)
    if not full and yield.overlapHitStatic ~= nil then
        return yield:overlapHitStatic(cx, y, cz, ry, halfWidth, 1.5, halfLength) == true, yield.overlapHitName
    end
    if yield.overlapHit == nil then
        return false
    end
    local ignored, also = yield.overlapIgnoreVehicle, yield.overlapIgnoreAlso
    yield.overlapIgnoreVehicle, yield.overlapIgnoreAlso = job.header, job.combine
    local hit = yield:overlapHit(cx, y, cz, ry, halfWidth, 1.5, halfLength) == true
    yield.overlapIgnoreVehicle, yield.overlapIgnoreAlso = ignored, also
    return hit, yield.overlapHitName
end

-- ------------------------------------------------------------------------------------------------------------
-- Devant le cadre de la barre, sur la route : la place de la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- hitch : le cadre (place, et dirX, dirZ vers la moissonneuse). ok, raison (« culture », « eau », « fossé ou
-- talus », « obstacle (nom) »). predicted : contrôle fait de loin (un peu plus large, obstacles fixes seulement)
function ADHeaderFlow.roadSideFree(t, job, hitch, predicted)
    if hitch == nil or hitch.dirX == nil then
        return false, "cadre de la barre introuvable"
    end
    local combine, header = job.combine, job.header
    local cw = (combine.size ~= nil and combine.size.width) or ADHeaderFlow.DEFAULT_COMBINE_WIDTH
    local dj = jointAhead(combine, header)
    local depth, span = headerDims(header)
    local extra = predicted and ADHeaderFlow.ROADBACK_PREDICT or 0
    local fx, fz = hitch.dirX, hitch.dirZ
    -- sol sous les roues de la moissonneuse : GIANTS, la gauche du cap (fx, fz) = (fz, -fx)
    local halfWheels = cw / 2 + ADHeaderFlow.ROADBACK_WHEEL_MARGIN + extra
    local reach = dj + ADHeaderFlow.ROADBACK_APPROACH
    local previous = nil
    local along = 1
    while along <= reach + 0.001 do
        local row = {}
        for i, across in ipairs({ -halfWheels, -halfWheels / 2, 0, halfWheels / 2, halfWheels }) do
            local x, z = hitch.x + fx * along + fz * across, hitch.z + fz * along - fx * across
            if hasCrop(x, z) then
                return false, "culture"
            end
            local h = groundY(x, z)
            if ADHeaderFlow.isWater(x, z, h) then
                return false, "eau"
            end
            if (row[i - 1] ~= nil and math.abs(h - row[i - 1]) > ADHeaderFlow.MAX_STEP_RISE)
                or (previous ~= nil and math.abs(h - previous[i]) > ADHeaderFlow.MAX_STEP_RISE) then
                return false, "fossé ou talus"
            end
            row[i] = h
        end
        previous = row
        along = along + ADHeaderFlow.SAMPLE_STEP
    end
    -- obstacles : la largeur de la barre là où la moissonneuse recule avec elle, puis sa propre largeur
    local headerReach = depth + ADHeaderFlow.ROADBACK_EXIT_MARGIN + 1.5
    local mid = (0.5 + headerReach) / 2
    local hit, name = boxHit(t, job, hitch.x + fx * mid, hitch.z + fz * mid, fx, fz, span / 2 + ADHeaderFlow.ROADBACK_HEADER_MARGIN + extra,
        (headerReach - 0.5) / 2, not predicted)
    if not hit and reach > headerReach then
        mid = (headerReach + reach) / 2
        hit, name = boxHit(t, job, hitch.x + fx * mid, hitch.z + fz * mid, fx, fz, halfWheels, (reach - headerReach) / 2, not predicted)
    end
    if hit then
        return false, string.format("obstacle (%s)", tostring(name or "?"))
    end
    return true, nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Le plan : le croisement, où la remorque finit, d'où le tracteur recule
-- ------------------------------------------------------------------------------------------------------------
-- dernier tronçon droit de la route (ROADBACK_BASE m au moins), qui finit à moins de ROADBACK_SPAN m du bout :
-- index de sa fin, index de son début, sens
local function lastStraight(points, current)
    local fromEnd = 0
    local j = #points
    while j >= 3 and j > (current or 1) and fromEnd <= ADHeaderFlow.ROADBACK_SPAN do
        local length = 0
        local k = j
        while k > 1 and length < ADHeaderFlow.ROADBACK_BASE do
            length = length + dist(points[k], points[k - 1])
            k = k - 1
        end
        if length >= ADHeaderFlow.ROADBACK_BASE then
            local ux, uz = unit(points[j].x - points[k].x, points[j].z - points[k].z)
            local straight = ux ~= nil
            if straight then
                for i = k + 1, j - 1 do
                    local ox, oz = points[i].x - points[j].x, points[i].z - points[j].z
                    if math.abs(ox * uz - oz * ux) > ADHeaderFlow.ROADBACK_CHORD_DEV then
                        straight = false
                        break
                    end
                end
            end
            if straight then
                return j, k, ux, uz
            end
        end
        fromEnd = fromEnd + dist(points[j], points[j - 1])
        j = j - 1
    end
    return nil
end

-- m de chemin droit après le point J de la route (le réseau qui continue dans l'axe), comptés depuis J
local function laneBeyond(J, prevId, ux, uz)
    local net = J.id ~= nil and ADGraphManager:getWayPointById(J.id) or nil
    if net == nil or ADHeaderFlow.backInLaneAhead == nil then
        return 0
    end
    local first, bestDot = nil, math.cos(math.rad(ADHeaderFlow.BACKIN_STRAIGHT))
    for _, id in ipairs(net.out or {}) do
        if id ~= prevId then
            local o = ADGraphManager:getWayPointById(id)
            local ox, oz
            if o ~= nil then
                ox, oz = unit(o.x - J.x, o.z - J.z)
            end
            if ox ~= nil and ox * ux + oz * uz >= bestDot then
                first, bestDot = o, ox * ux + oz * uz
            end
        end
    end
    if first == nil then
        return 0
    end
    local beyond = 0
    for _, p in ipairs(ADHeaderFlow.backInLaneAhead(net, first, ux, uz)) do
        local ox, oz = p.x - J.x, p.z - J.z
        if math.abs(ox * uz - oz * ux) > ADHeaderFlow.BACKIN_LANE_DEV then
            break
        end
        beyond = math.max(beyond, ox * ux + oz * uz)
    end
    return beyond
end

-- sur une route qui passe par le croisement : index du point où la moissonneuse s'arrête, en face du cadre (son
-- attelage à ROADBACK_KEEP m du croisement ; si la route tourne trop à cet endroit, le point droit le plus loin
-- qui la laisse à ROADBACK_KEEP_MIN m au moins) ; nil : la route n'y passe pas, ou elle n'y est pas droite
function ADHeaderFlow.roadBackCombineStop(plan, wayPoints, current)
    local n = wayPoints ~= nil and #wayPoints or 0
    local first = math.max(current or 1, 1)
    local best, bestD = nil, ADHeaderFlow.ROADBACK_CORNER
    for k = first, n do
        local d = MathUtil.vector2Length(wayPoints[k].x - plan.x, wayPoints[k].z - plan.z)
        if d < bestD then
            best, bestD = k, d
        end
    end
    if best == nil then
        return nil
    end
    local keepMin = plan.keep - ADHeaderFlow.ROADBACK_KEEP + ADHeaderFlow.ROADBACK_KEEP_MIN
    local closer = nil
    for k = best, first + 1, -1 do
        local p = wayPoints[k]
        local ox, oz = plan.x - p.x, plan.z - p.z
        local before = ox * plan.rx + oz * plan.rz
        if before >= keepMin then
            local dx, dz = heading(wayPoints, k)
            local straight = math.abs(ox * plan.rz - oz * plan.rx) <= ADHeaderFlow.ROADBACK_ROAD_SIDE and dx ~= nil
                and dx * plan.rx + dz * plan.rz >= math.cos(math.rad(ADHeaderFlow.ROADBACK_STOP_ANGLE))
            if before >= plan.keep then
                return straight and k or closer
            end
            if not straight then
                return closer
            end
            closer = k
        end
    end
    return closer
end

-- wayPoints : la route du tracteur vers le point du champ ; nil, raison quand le recul ne se fait pas ici
function ADHeaderFlow.roadBackPlan(t, job, wayPoints, current)
    local n = wayPoints ~= nil and #wayPoints or 0
    if n < 4 then
        return nil, "route trop courte"
    end
    local rig, why = ADHeaderFlow.backInRig(t, job)
    if rig == nil then
        return nil, why
    end
    -- 1) le chemin du champ : dernier tronçon droit de la route, remonté tant qu'elle reste dans son axe
    local j, a, ux, uz = lastStraight(wayPoints, current)
    if j == nil then
        return nil, "pas de chemin droit avant le champ"
    end
    local J = wayPoints[j]
    while a > 1 do
        local p = wayPoints[a - 1]
        local ox, oz = p.x - J.x, p.z - J.z
        if math.abs(ox * uz - oz * ux) > ADHeaderFlow.BACKIN_LANE_DEV or ox * ux + oz * uz > 0 then
            break
        end
        a = a - 1
    end
    local m = a - 1
    if m < 2 then
        return nil, "pas de croisement avant le chemin du champ"
    end
    if (current or 1) > a then
        return nil, "tracteur déjà sur le chemin du champ"
    end
    -- 2) la route avant le croisement : son sens là où elle est droite
    local rx, rz = heading(wayPoints, m)
    if rx == nil then
        return nil, "route inconnue avant le chemin"
    end
    local cosStraight = math.cos(math.rad(ADHeaderFlow.ROADBACK_ROAD_STRAIGHT))
    local steps = 0
    while m > 2 and steps < 4 do
        local px, pz = heading(wayPoints, m - 1)
        if px == nil or px * rx + pz * rz >= cosStraight then
            break
        end
        m = m - 1
        rx, rz = px, pz
        steps = steps + 1
    end
    local dot = rx * ux + rz * uz
    if math.abs(dot) > math.sin(math.rad(ADHeaderFlow.ROADBACK_SKEW)) then
        return nil, string.format("le chemin quitte la route à %.0f°", math.deg(math.acos(math.max(-1, math.min(1, dot)))))
    end
    -- 3) le croisement : l'axe du chemin coupe l'axe de la route
    local R = wayPoints[m]
    local s = ((R.x - J.x) * rz - (R.z - J.z) * rx) / (ux * rz - uz * rx)
    local X = { x = J.x + ux * s, z = J.z + uz * s }
    local laneJ = -s -- m du croisement au bout du tronçon droit, le long du chemin
    if laneJ <= 0 or dist(X, R) > ADHeaderFlow.ROADBACK_CORNER or dist(X, wayPoints[a]) > ADHeaderFlow.ROADBACK_CORNER then
        return nil, "virage trop large entre la route et le chemin"
    end
    local function along(p)
        return (p.x - X.x) * ux + (p.z - X.z) * uz
    end
    local toEnd = 0
    for k = a + 1, n do
        toEnd = toEnd + dist(wayPoints[k], wayPoints[k - 1])
    end
    if toEnd > ADHeaderFlow.ROADBACK_LANE_MAX then
        return nil, string.format("croisement trop loin du champ (%.0f m)", toEnd)
    end
    -- 4) le cadre de la barre regarde la route d'où vient la moissonneuse (remorque dans l'axe du chemin, l'avant
    -- vers le champ ; GIANTS : sa gauche = (uz, -ux))
    local lx, lz = uz, -ux
    local fx, fz = unit(rig.fdx * lx + rig.fdz * ux, rig.fdx * lz + rig.fdz * uz)
    if fx == nil or -(fx * rx + fz * rz) < math.cos(math.rad(ADHeaderFlow.ROADBACK_FACE)) then
        return nil, "le cadre de la barre ne regarde pas la route d'où vient la moissonneuse"
    end
    -- 5) la moissonneuse arrive par cette route, dans le même sens
    -- (le dernier point de la route avant le croisement peut être un point de virage redessiné, sans numéro : le
    -- point du réseau juste avant)
    local roadPoint = R
    local q = m
    while roadPoint.id == nil and q > 1 and m - q < 4 do
        q = q - 1
        roadPoint = wayPoints[q]
    end
    local route = roadPoint.id ~= nil and ADGraphManager:getPathTo(job.combine, roadPoint.id) or nil
    local rn = route ~= nil and #route or 0
    if rn < 2 or route[rn].id ~= roadPoint.id then
        return nil, "pas de route de la moissonneuse jusqu'au croisement"
    end
    local cx, cz = heading(route, rn)
    if cx == nil or cx * rx + cz * rz < math.cos(math.rad(ADHeaderFlow.ROADBACK_ARRIVE)) then
        return nil, "la moissonneuse arrive par un autre côté"
    end
    -- 6) où la remorque finit (le cadre sur l'axe de la route), d'où le tracteur recule
    local frameAt = ADHeaderFlow.ROADBACK_FRAME_AT
    local final = rig.dra + rig.rz - rig.hz + frameAt -- point suivi du tracteur, m après le croisement
    local laneEnd = laneJ + laneBeyond(J, wayPoints[j - 1].id, ux, uz)
    local back = math.min(ADHeaderFlow.ROADBACK_BACK, laneEnd - ADHeaderFlow.ROADBACK_END_MARGIN - final)
    if back < ADHeaderFlow.ROADBACK_BACK_MIN then
        return nil, string.format("chemin trop court après le croisement (%.0f m, il en faut %.0f)", laneEnd,
            final + ADHeaderFlow.ROADBACK_BACK_MIN + ADHeaderFlow.ROADBACK_END_MARGIN)
    end
    local stop = final + back
    local axleStop, axleEnd = stop - rig.dra, final - rig.dra
    if axleStop - along(wayPoints[a]) < ADHeaderFlow.ROADBACK_ALIGN then
        return nil, "virage trop près de l'endroit où le tracteur s'arrête"
    end
    local frame = { x = X.x + lx * rig.hx + ux * frameAt, z = X.z + lz * rig.hx + uz * frameAt, dirX = fx, dirZ = fz }
    frame.y = groundY(frame.x, frame.z)
    local plan = { x = X.x, z = X.z, ux = ux, uz = uz, rx = rx, rz = rz, m = m, a = a, j = j, stop = stop, final = final, back = back,
        axleStop = axleStop, axleEnd = axleEnd, frame = frame, rig = rig, keep = rig.dj + ADHeaderFlow.ROADBACK_KEEP,
        entrance = { x = wayPoints[n].x, z = wayPoints[n].z },
        roadId = roadPoint.id, -- dernier point du réseau avant le croisement (la moissonneuse y vient par le réseau : goToHeader)
        -- pour la tâche (Tasks/HeaderRoadBackTask.lua)
        qx = X.x, qz = X.z, start = axleStop, reach = back, frameAt = frameAt }
    -- 7) la moissonneuse s'arrêtera en face du cadre : la route y est droite
    local stopIndex = ADHeaderFlow.roadBackCombineStop(plan, wayPoints, 1)
    if stopIndex == nil then
        return nil, "route pas droite avant le croisement (la moissonneuse ne serait pas en face du cadre)"
    end
    -- 8) de l'autre côté de la route : la place de l'arrière de la remorque (et de la barre, aussi longue qu'elle)
    local trailer = job.trailer
    local trailerLength = (trailer.size ~= nil and trailer.size.length) or 12
    local trailerWidth = (trailer.size ~= nil and trailer.size.width) or 3
    local depth, span = headerDims(job.header)
    local rear = math.min(axleEnd - rig.rz - trailerLength / 2, frameAt - span / 2) - ADHeaderFlow.ROADBACK_REAR_MARGIN
    local half = math.max(trailerWidth / 2, math.abs(rig.hx), depth - math.abs(rig.hx)) + ADHeaderFlow.ROADBACK_REAR_SIDE
    local previous = nil
    local d = 1
    while d >= rear - 0.001 do
        local row = {}
        for i, across in ipairs({ -half, 0, half }) do
            local x, z = X.x + ux * d + lx * across, X.z + uz * d + lz * across
            if hasCrop(x, z) then
                return nil, "culture de l'autre côté de la route, là où la remorque recule"
            end
            local h = groundY(x, z)
            if ADHeaderFlow.isWater(x, z, h) then
                return nil, "eau de l'autre côté de la route, là où la remorque recule"
            end
            if previous ~= nil and math.abs(h - previous[i]) > ADHeaderFlow.MAX_STEP_RISE then
                return nil, "fossé ou talus de l'autre côté de la route, là où la remorque recule"
            end
            row[i] = h
        end
        previous = row
        d = d - 1
    end
    local mid = (1 + rear) / 2
    local hit, name = boxHit(t, job, X.x + ux * mid, X.z + uz * mid, ux, uz, half, (1 - rear) / 2, false)
    if hit then
        return nil, string.format("obstacle de l'autre côté de la route, là où la remorque recule (%s)", tostring(name or "?"))
    end
    -- 9) devant le cadre : la route libre pour la moissonneuse
    local ok, sideWhy = ADHeaderFlow.roadSideFree(t, job, frame, true)
    if not ok then
        return nil, string.format("devant le cadre de la barre, sur la route : %s", tostring(sideWhy))
    end
    -- 10) la route avec la barre, du croisement au champ
    if ADHeaderFlow.ROAD_CHECK and ADHeaderFlow.roadFits ~= nil and span > (ADHeaderFlow.ROAD_MIN_WIDTH or 4.5) then
        local from = m
        while from > 1 and (X.x - wayPoints[from - 1].x) * rx + (X.z - wayPoints[from - 1].z) * rz <= ADHeaderFlow.ROADBACK_ROAD_FROM do
            from = from - 1
        end
        local fits, ox, oz, obstacle = ADHeaderFlow.roadFits(t, job, wayPoints, from, n)
        if not fits then
            return nil, string.format("route trop étroite pour la barre du croisement au champ : %s en (%.0f, %.0f)", tostring(obstacle or "obstacle"), ox, oz)
        end
    end
    plan.rear = rear
    return plan
end

-- ------------------------------------------------------------------------------------------------------------
-- Tracteur : la route passe le croisement et suit le chemin jusqu'au point d'arrêt, puis le recul
-- ------------------------------------------------------------------------------------------------------------
-- la route du tracteur est coupée sur le chemin et prolongée dans son axe jusqu'au point d'où il recule
function ADHeaderFlow.roadBackRoute(plan, wayPoints)
    local function along(p)
        return (p.x - plan.x) * plan.ux + (p.z - plan.z) * plan.uz
    end
    local keep = plan.a
    for k = plan.a, plan.j do
        if along(wayPoints[k]) <= plan.stop - 2 then
            keep = k
        end
    end
    for k = #wayPoints, keep + 1, -1 do
        wayPoints[k] = nil
    end
    local function add(d)
        local x, z = plan.x + plan.ux * d, plan.z + plan.uz * d
        wayPoints[#wayPoints + 1] = { x = x, y = groundY(x, z), z = z, isPathFinderPoint = true }
    end
    local d = along(wayPoints[keep]) + ADHeaderFlow.ROADBACK_ROUTE_STEP
    while d < plan.stop - 2 do
        add(d)
        d = d + ADHeaderFlow.ROADBACK_ROUTE_STEP
    end
    add(plan.stop)
end

-- en route vers le champ, rien de dégagé près du bout : le recul jusqu'à la route d'abord, sinon la marche arrière
-- en biais dans l'entrée du champ ; true = route changée
local baseBackInTry = ADHeaderFlow.backInTry
function ADHeaderFlow.backInTry(mode, job, wayPoints, current)
    if ADHeaderFlow.ROADBACK and ADHeaderRoadBackTask ~= nil then
        local t = mode.vehicle
        local ok, plan, why = FarmPilotCall(ADHeaderFlow.roadBackPlan, t, job, wayPoints, current)
        if not ok then
            log("ERREUR recul de la remorque jusqu'à la route : %s", tostring(plan))
        elseif plan == nil then
            log("%s : pas de recul de la remorque jusqu'à la route (%s)", nameOf(t), tostring(why))
        else
            ADHeaderFlow.roadBackRoute(plan, wayPoints)
            mode.headerRoadBack = plan
            job.roadBack = plan -- la moissonneuse s'arrêtera en face du cadre (followStopIndex)
            job.fieldSpot = { x = plan.entrance.x, z = plan.entrance.z } -- les autres endroits sont cherchés autour de l'entrée
            log("%s : bout de la route encombré côté barre, la remorque sera reculée tout droit jusqu'à la route, la barre en travers du croisement (%.0f, %.0f) face à la moissonneuse ; arrêt %.0f m après le croisement, recul de %.0f m",
                nameOf(t), plan.x, plan.z, plan.stop, plan.back)
            return true
        end
    end
    if baseBackInTry ~= nil then
        return baseBackInTry(mode, job, wayPoints, current)
    end
    return false
end

-- au bout de sa route : true = le recul est lancé
local baseStartBackIn = ADHeaderFlow.startBackIn
function ADHeaderFlow.startBackIn(mode, job)
    local plan = mode.headerRoadBack
    mode.headerRoadBack = nil
    if plan == nil or job.phase ~= "deliver" or ADHeaderRoadBackTask == nil then
        return baseStartBackIn ~= nil and baseStartBackIn(mode, job) or false
    end
    local t = mode.vehicle
    mode.headerBackIn = nil
    job.roadBackPlan = plan
    mode.headerStage = "roadBack"
    mode.headerTask = ADHeaderRoadBackTask:new(t, job.trailer, plan, job)
    t.ad.taskModule:addTask(mode.headerTask)
    AutonomousMode.message(t, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerRoadBack")
    return true
end

local REASONS = { noTrailer = "pas de remorque à pousser", jackknife = "tracteur et remorque trop de travers",
    blocked = "quelque chose derrière la remorque", timeout = "pas fini à temps", badStart = "tracteur pas en place sur le chemin",
    offLane = "tracteur ou remorque dans la culture au bord du chemin" }

-- recul fini (result : voir Tasks/HeaderRoadBackTask.lua)
function ADHeaderFlow.roadBackDone(mode, job, result)
    local t = mode.vehicle
    local plan = job.roadBackPlan
    job.roadBackPlan = nil
    if t.ad.isStoppingWithError or plan == nil then
        job.cancelled = true
        job.roadBack = nil
        ADHeaderFlow.stopHere(mode, nil)
        return
    end
    local why = nil
    if result ~= "ok" then
        why = REASONS[result] or tostring(result)
    else
        local hitch = ADAutonomousManager.frontHitch(job.combine, job.header, true)
        if hitch == nil then
            why = "cadre de la barre introuvable"
        else
            local cosF = -(hitch.dirX * plan.rx + hitch.dirZ * plan.rz)
            local off = (hitch.x - plan.x) * plan.ux + (hitch.z - plan.z) * plan.uz
            local ok, sideWhy = true, nil
            if cosF < math.cos(math.rad(ADHeaderFlow.ROADBACK_FACE + 10)) then
                ok, sideWhy = false, string.format("cadre de la barre à %.0f° de la route", math.deg(math.acos(math.max(-1, math.min(1, cosF)))))
            else
                ok, sideWhy = ADHeaderFlow.roadSideFree(t, job, hitch, false)
                if not ok then
                    sideWhy = string.format("devant le cadre de la barre, sur la route : %s", tostring(sideWhy))
                end
            end
            if ok then
                job.roadPickup = { x = plan.x, z = plan.z, rx = plan.rx, rz = plan.rz, keep = plan.keep, roadId = plan.roadId }
                job.sideBlocked = nil
                log("%s : remorque reculée jusqu'à la route, cadre de la barre à %.1f m de son axe et à %.0f° ; la moissonneuse la prend par la route",
                    nameOf(t), math.abs(off), math.deg(math.acos(math.max(-1, math.min(1, cosF)))))
            else
                why = sideWhy
            end
        end
    end
    if why ~= nil then
        job.roadBack = nil
        log("%s : recul de la remorque jusqu'à la route pas réussi (%s)", nameOf(t), why)
        if result == "badStart" then
            -- rien n'a bougé : l'endroit est jugé comme d'habitude
            if ADHeaderFlow.onArrival(mode, job) then
                return
            end
        elseif ADHeaderFlow.moveOn(mode, job, "recul de la remorque jusqu'à la route pas réussi", true) then
            return
        end
    end
    ADHeaderFlow.tractorWait(mode, job)
end

local baseTractorStage = ADHeaderFlow.tractorStage
function ADHeaderFlow.tractorStage(mode, job, stage, result)
    if stage == "roadBack" then
        ADHeaderFlow.roadBackDone(mode, job, result)
        return
    end
    return baseTractorStage(mode, job, stage, result)
end

-- la remorque va ailleurs : plus de prise par la route
local baseMoveOn = ADHeaderFlow.moveOn
function ADHeaderFlow.moveOn(mode, job, why, plain)
    job.roadPickup = nil
    job.roadBack = nil
    return baseMoveOn(mode, job, why, plain)
end

if AutonomousMode ~= nil and AutonomousMode.reset ~= nil then
    local baseReset = AutonomousMode.reset
    function AutonomousMode:reset()
        baseReset(self)
        self.headerRoadBack = nil
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse : arrêt en face du cadre, approche tout droit, petit recul après l'attelage
-- ------------------------------------------------------------------------------------------------------------
-- pendant qu'elle suit la remorque : son arrêt est sur la route, en face du cadre (au lieu de l'arrêt habituel avant
-- le chemin du champ)
if ADHeaderFlow.followMonitor ~= nil and ADHeaderFlow.followStopIndex ~= nil then
    local followJob, followMode = nil, nil
    local baseFollowMonitor = ADHeaderFlow.followMonitor
    function ADHeaderFlow.followMonitor(mode, job, dt)
        local v = mode.vehicle
        local task = mode.driveToDestinationTask
        local pick = job.roadPickup
        -- (13/11) remorque en place sur la route pendant qu'elle roule encore : elle garde sa route jusqu'à son
        -- arrêt en face du cadre. Lâchée là, une route recalculée d'où elle est pouvait partir par une autre
        -- branche et arriver par l'autre bout de la route, côté rabatteur (essai du 13/11 21:44).
        if pick ~= nil and job.trailerReady and not job.cancelled and task ~= nil and v.ad.taskModule:getActiveTask() == task then
            if not task.fpRoadStop and not mode.followCut and not task.routeIsPartial
                and (task.state == nil or task.state == DriveToDestinationTask.STATE_DRIVING) then
                -- route pas encore coupée : elle l'est maintenant, à son arrêt en face du cadre
                local dpm = v.ad.drivePathModule
                local wayPoints = dpm.wayPoints
                if wayPoints ~= nil and #wayPoints >= 2 then
                    local current = dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1
                    local k = ADHeaderFlow.roadBackCombineStop(pick, wayPoints, current)
                    if k ~= nil and k > current + 1 then
                        if ADHeaderFlow.noteRouteAhead ~= nil then ADHeaderFlow.noteRouteAhead(mode, wayPoints, k) end
                        for q = #wayPoints, k + 1, -1 do
                            wayPoints[q] = nil
                        end
                        mode.followCut = true
                        task.fpRoadStop = true
                        job.combineStop = { x = wayPoints[k].x, z = wayPoints[k].z }
                    end
                end
            end
            if task.fpRoadStop then
                if not task.fpRoadStopSaid then
                    task.fpRoadStopSaid = true
                    local x, _, z = getWorldTranslation(v.components[1].node)
                    log("%s : remorque en place sur la route, elle finit sa route jusqu'à son arrêt en face du cadre de la barre (encore %.0f m avant le croisement)",
                        nameOf(v), (pick.x - x) * pick.rx + (pick.z - z) * pick.rz)
                end
                return
            end
        end
        followJob, followMode = job, mode
        baseFollowMonitor(mode, job, dt)
        followJob, followMode = nil, nil
    end

    local baseStopIndex = ADHeaderFlow.followStopIndex
    function ADHeaderFlow.followStopIndex(wayPoints, current)
        local i, fromEnd, lane = baseStopIndex(wayPoints, current)
        local job = followJob
        local plan = job ~= nil and job.roadBack or nil
        if plan == nil then
            return i, fromEnd, lane
        end
        local k = ADHeaderFlow.roadBackCombineStop(plan, wayPoints, current)
        if k == nil then
            log("%s : sa route ne passe pas en face du cadre de la barre, arrêt habituel", nameOf(job.combine))
            return i, fromEnd, lane
        end
        local length = 0
        for q = k + 1, #wayPoints do
            length = length + dist(wayPoints[q], wayPoints[q - 1])
        end
        log("%s : la barre sera en travers du croisement, arrêt sur la route en face d'elle (%.0f m avant le croisement)", nameOf(job.combine),
            (plan.x - wayPoints[k].x) * plan.rx + (plan.z - wayPoints[k].z) * plan.rz)
        local task = followMode ~= nil and followMode.driveToDestinationTask or nil
        if task ~= nil then
            task.fpRoadStop = true -- sa route finit en face du cadre : gardée quand la remorque est en place (followMonitor)
        end
        return k, length, true
    end
end

-- venue de loin par le réseau (elle n'était pas arrêtée en face du cadre) : la route est lâchée à son arrêt, sur la
-- route, pas à DROP_HANDOVER m de la barre
if ADHeaderFlow.monitor ~= nil then
    local baseMonitor = ADHeaderFlow.monitor
    function ADHeaderFlow.monitor(mode, dt)
        local v = mode.vehicle
        local job = v.ad.fpHeaderJob
        local pick = job ~= nil and job.combine == v and job.roadPickup or nil
        if pick == nil or mode.headerStage ~= "toHeader" then
            return baseMonitor(mode, dt)
        end
        local task = mode.driveToDestinationTask
        if task == nil or v.ad.taskModule:getActiveTask() ~= task then
            return
        end
        local x, _, z = getWorldTranslation(v.components[1].node)
        local ox, oz = pick.x - x, pick.z - z
        local before = ox * pick.rx + oz * pick.rz
        local side = math.abs(ox * pick.rz - oz * pick.rx)
        if before > 0 and before <= pick.keep + ADHeaderFlow.ROADBACK_HANDOVER and side <= ADHeaderFlow.ROADBACK_ROAD_SIDE then
            log("%s : sur la route en face de la barre (%.0f m avant le croisement), on lâche la route", nameOf(v), before)
            task:finished()
            return
        end
        if math.abs(v.lastSpeedReal or 0) < 0.0003 and MathUtil.vector2Length(ox, oz) <= ADHeaderFlow.DROP_STUCK_RANGE then
            mode.dropStuck = (mode.dropStuck or 0) + dt
            if mode.dropStuck >= ADHeaderFlow.DROP_STUCK_TIME then
                log("%s : arrêtée près de la barre (%.0f m), on lâche la route", nameOf(v), MathUtil.vector2Length(ox, oz))
                task:finished()
            end
        else
            mode.dropStuck = 0
        end
    end
end

-- chemin tout prêt de la tâche d'attelage (FetchToolTask.lua : presetPath), quand elle n'est pas déjà dans l'axe du
-- cadre : en ligne droite jusque dans cet axe, puis tout droit jusque devant le cadre ; nil : la suite habituelle.
-- probe : seulement dire si cette approche existe d'où elle est (true), sans rien écrire dans le journal
function ADHeaderFlow.roadBackApproach(vehicle, job, hitch, probe)
    if hitch == nil or hitch.dirX == nil then
        return nil
    end
    local node = vehicle.components[1].node
    local x, _, z = getWorldTranslation(node)
    local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
    fx, fz = unit(fx, fz)
    local ox, oz = x - hitch.x, z - hitch.z
    local ahead = ox * hitch.dirX + oz * hitch.dirZ
    local side = math.abs(ox * hitch.dirZ - oz * hitch.dirX)
    local stopAt = jointAhead(vehicle, job.header) + ADHeaderFlow.ROADBACK_FINAL
    if fx == nil or ahead < stopAt + 1 or ahead > ADHeaderFlow.ROADBACK_APPROACH_MAX or side > ADHeaderFlow.ROADBACK_ROAD_SIDE
        or -(fx * hitch.dirX + fz * hitch.dirZ) < math.cos(math.rad(ADHeaderFlow.ROADBACK_APPROACH_ANGLE)) then
        if not probe then
            log("%s : pas en face du cadre de la barre (%.0f m devant, %.1f m de côté), approche habituelle", nameOf(vehicle), ahead, side)
        end
        return nil
    end
    local points = {}
    local function add(px, pz)
        points[#points + 1] = { x = px, y = groundY(px, pz), z = pz, isPathFinderPoint = true }
    end
    -- où elle rejoint l'axe du cadre : ROADBACK_END_STRAIGHT m avant le bout, plus près quand elle part de près ou
    -- de côté (la ligne qui l'y mène ne fait pas plus de ROADBACK_JOIN_ANGLE ° avec l'axe)
    local join = math.min(ahead - 1, stopAt + ADHeaderFlow.ROADBACK_END_STRAIGHT, ahead - side / math.tan(math.rad(ADHeaderFlow.ROADBACK_JOIN_ANGLE)))
    if join < stopAt + ADHeaderFlow.ROADBACK_END_STRAIGHT_MIN then
        if not probe then
            log("%s : trop près du cadre de la barre pour se mettre dans son axe (%.0f m devant, %.1f m de côté), approche habituelle", nameOf(vehicle), ahead - stopAt, side)
        end
        return nil
    end
    if probe then
        return true
    end
    add(x, z)
    local jx, jz = hitch.x + hitch.dirX * join, hitch.z + hitch.dirZ * join
    local count = math.max(1, math.ceil(MathUtil.vector2Length(jx - x, jz - z) / 2))
    for k = 1, count do
        add(x + (jx - x) * k / count, z + (jz - z) * k / count)
    end
    local d = join - 2
    while d > stopAt + 0.5 do
        add(hitch.x + hitch.dirX * d, hitch.z + hitch.dirZ * d)
        d = d - 2
    end
    add(hitch.x + hitch.dirX * stopAt, hitch.z + hitch.dirZ * stopAt)
    log("%s : barre sur la route à %.0f m devant, approche tout droit (%.1f m de côté à reprendre)", nameOf(vehicle), ahead - stopAt, side)
    return points
end

-- remorque en place alors que la moissonneuse n'est pas encore en face du cadre (retenue plus tôt derrière la
-- remorque, route lâchée avant son arrêt, route qui tourne, remorque un peu de travers) : elle finit sa route
-- jusqu'à son arrêt en face du cadre, où la route est lâchée (monitor) ; l'approche tout droit part de là. Sans ça
-- l'attelage chercherait un chemin d'où elle est.
-- (13/11) une route qui finit au point de route avant le croisement arrive-t-elle par la route d'où le cadre se voit ?
-- Ses derniers points, jusqu'à l'arrêt de la moissonneuse, sont avant le croisement et sur l'axe de la route. Une
-- route qui arrive par l'autre bout traverse le croisement, là où est la remorque.
function ADHeaderFlow.roadBackArrives(pick, route)
    local n = route ~= nil and #route or 0
    if n < 1 or route[n].id ~= pick.roadId then
        return false
    end
    local keepMin = pick.keep - ADHeaderFlow.ROADBACK_KEEP + ADHeaderFlow.ROADBACK_KEEP_MIN
    for k = n, 1, -1 do
        local ox, oz = pick.x - route[k].x, pick.z - route[k].z
        local before = ox * pick.rx + oz * pick.rz
        if before < 0 or math.abs(ox * pick.rz - oz * pick.rx) > ADHeaderFlow.ROADBACK_ROAD_SIDE then
            return false
        end
        if before >= keepMin then
            return true
        end
    end
    return true -- route courte : elle est déjà sur la route, avant le croisement
end

-- la route de la moissonneuse jusqu'à son arrêt en face du cadre, d'où elle est : true si elle arrive du bon côté.
-- Sinon les autres points de départ devant elle sont essayés (ceux d'AutoDrive, GraphManagerStart.lua) : le
-- premier dont la route arrive du bon côté, la plus courte, est noté comme départ de la route qui suit.
function ADHeaderFlow.roadBackRouteStart(v, pick)
    local route = ADGraphManager:getPathTo(v, pick.roadId)
    if ADHeaderFlow.roadBackArrives(pick, route) then
        return true
    end
    if ADGraphManager.matchingWayPoints == nil or ADGraphManager.setJoinedWayPoint == nil or ADGraphManager.pathFromTo == nil
        or v.ad.frontNode == nil or v.getWayPointIdsInRange == nil then
        return false
    end
    local x, _, z = getWorldTranslation(v.ad.frontNode)
    local dx, _, dz = localDirectionToWorld(v.ad.frontNode, 0, 0, 1)
    local range = ADGraphManager.START_RANGE_MAX or 20
    local ids = v:getWayPointIdsInRange(ADGraphManager.START_RANGE_MIN or 1, range)
    local best, bestCost = nil, math.huge
    local tries = 0
    for _, candidate in ipairs(ADGraphManager:matchingWayPoints({ x = x, z = z }, { x = dx, z = dz }, ids)) do
        if tries >= (ADGraphManager.START_MAX_TRIES or 12) then
            break
        end
        tries = tries + 1
        local out = ADGraphManager.getBestOutPoints ~= nil and ADGraphManager:getBestOutPoints(v, candidate.id) or nil
        local wp = ADGraphManager:pathFromTo(candidate.id, pick.roadId, out, v)
        if ADHeaderFlow.roadBackArrives(pick, wp) then
            local cost = MathUtil.vector2Length(wp[1].x - x, wp[1].z - z)
            for q = 2, #wp do
                cost = cost + dist(wp[q], wp[q - 1])
            end
            if cost < bestCost then
                best, bestCost = candidate.id, cost
            end
        end
    end
    if best == nil then
        return false
    end
    ADGraphManager.setJoinedWayPoint(v, best, range + 10, "le seul devant elle d'où la route arrive en face du cadre de la barre")
    return true
end

if ADHeaderFlow.goToHeader ~= nil then
    local baseGoToHeader = ADHeaderFlow.goToHeader
    function ADHeaderFlow.goToHeader(mode, header)
        local v = mode.vehicle
        local job = v.ad.fpHeaderJob
        local pick = job ~= nil and job.combine == v and job.header == header and job.roadPickup or nil
        local road = pick ~= nil and pick.roadId ~= nil and ADGraphManager:getWayPointById(pick.roadId) or nil
        if road ~= nil then
            local x, _, z = getWorldTranslation(v.components[1].node)
            local before = (pick.x - x) * pick.rx + (pick.z - z) * pick.rz
            if before > pick.keep + ADHeaderFlow.ROADBACK_HANDOVER
                and MathUtil.vector2Length(road.x - x, road.z - z) > (AutonomousMode.FETCH_NEAR_START or 3)
                and not ADHeaderFlow.roadBackApproach(v, job, ADAutonomousManager.frontHitch(v, header, true), true) then
                -- (13/11) la route repart du point qu'elle suivait, et son sens d'arrivée est contrôlé
                if ADHeaderFlow.resumeStart ~= nil then ADHeaderFlow.resumeStart(mode) end
                if not ADHeaderFlow.roadBackRouteStart(v, pick) then
                    log("%s : barre sur la route, mais d'où elle est aucune route ne l'amène en face de son cadre (elle arriverait par l'autre côté du croisement)", nameOf(v))
                    if (job.spotMoves or 0) < ADHeaderFlow.SPOT_MOVES then
                        job.trailerReady = false
                        job.moveRequested = true
                        job.fetchNoPath = true
                        log("%s : « %s » doit déplacer la remorque", nameOf(v), nameOf(job.tractor))
                        AutonomousMode.message(v, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerWaitTrailer", nameOf(job.tractor))
                        ADHeaderFlow.startWait(mode, "waitTrailer", function() return job.trailerReady or job.cancelled end)
                        return
                    end
                    return baseGoToHeader(mode, header)
                end
                log("%s : barre sur la route, pas encore en face de son cadre (%.0f m avant le croisement), finit sa route jusqu'à son arrêt en face de lui", nameOf(v), before)
                mode.headerStage = "toHeader"
                mode.headerGoal = header
                mode.dropStuck = 0
                mode.driveToDestinationTask = DriveToDestinationTask:new(v, pick.roadId)
                if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_fetch", label(header)) end
                v.ad.taskModule:addTask(mode.driveToDestinationTask)
                return
            end
        end
        return baseGoToHeader(mode, header)
    end
end

if AutonomousMode ~= nil and AutonomousMode.startFetchAttach ~= nil then
    local baseFetchAttach = AutonomousMode.startFetchAttach
    function AutonomousMode:startFetchAttach()
        baseFetchAttach(self)
        local v = self.vehicle
        local job = v.ad.fpHeaderJob
        local task = self.fetchTask
        if job ~= nil and job.roadPickup ~= nil and job.combine == v and task ~= nil and task.tool == job.header and task.presetPath == nil then
            task.presetPath = function(vehicle, hitch)
                return ADHeaderFlow.roadBackApproach(vehicle, job, hitch)
            end
        end
    end
end

if ADFrontFlow ~= nil and ADFrontFlow.fetchRoutePoint ~= nil then
    -- barre sur la route, la moissonneuse en face : pas de détour par le point du réseau « devant l'outil »
    local baseRoutePoint = ADFrontFlow.fetchRoutePoint
    function ADFrontFlow.fetchRoutePoint(vehicle, tool)
        local job = vehicle.ad ~= nil and vehicle.ad.fpHeaderJob or nil
        if job ~= nil and job.roadPickup ~= nil and job.combine == vehicle and job.header == tool then
            return nil
        end
        return baseRoutePoint(vehicle, tool)
    end
end

if ADFrontFlow ~= nil and ADFrontFlow.afterFetch ~= nil and ADFrontBackOffTask ~= nil then
    -- barre prise sur la route : petit recul (la longue sortie en marche arrière remonterait la route avec la barre),
    -- puis le tracteur dégage par le chemin et elle va au champ par le réseau
    local baseAfterFetch = ADFrontFlow.afterFetch
    function ADFrontFlow.afterFetch(mode, tool)
        local v = mode.vehicle
        local job = v.ad.fpHeaderJob
        if job ~= nil and job.roadPickup ~= nil and job.combine == v and job.header == tool and tool ~= nil and mode.fpQueue == nil
            and mode.fetchSide == "front" then
            mode.fetchSide = nil
            job.roadPickup = nil
            job.roadBack = nil
            local back = headerDims(tool) + ADHeaderFlow.ROADBACK_EXIT_MARGIN
            log("%s : « %s » attelée sur la route, recule de %.0f m pour laisser repartir la remorque, puis va au champ par le chemin", nameOf(v), label(tool), back)
            mode.parkStage = "backoff"
            mode.parkThen = "restart"
            mode.backOffTask = ADFrontBackOffTask:new(v, back, false, tool)
            v.ad.taskModule:addTask(mode.backOffTask)
            return true
        end
        return baseAfterFetch(mode, tool)
    end
end
