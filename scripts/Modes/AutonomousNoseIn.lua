-- ============================================================================================================
-- FarmPilot : AutonomousNoseIn.lua
-- Mode Autonome : entrer LE NEZ EN AVANT dans une place de parking qui se prend en marche arrière (outil avant ou
-- masse à poser au fond, ou à y reprendre), sans recherche de chemin.
--
-- Règle (10/11) :
-- - La recherche de chemin faisait faire au tracteur son demi-tour hors des routes : il a buté contre un bâtiment.
--   Maintenant le demi-tour se fait PAR LES ROUTES : le tracteur va par le réseau jusqu'à un point de la route en
--   marche avant qui passe devant la place (avant le point où la marche arrière commence). Garé dans la place, il
--   en sort donc par sa sortie, fait le tour par le réseau et revient devant.
-- - De ce point, il suit une courbe calculée (arc, ligne droite, arc, au rayon de braquage du tracteur) jusqu'à
--   l'entrée de la place, dans son axe, puis il avance tout droit (FrontPlaceTask.lua, FetchToolTask.lua).
-- - Le point choisi est celui d'où la courbe est la plus courte et tourne le moins.
-- - La courbe ne regarde pas les obstacles : elle doit rester sur le sol que le réseau connaît, à moins de
--   MAX_OFF_NETWORK m d'une route (une courbe qui coupe à travers une cour inconnue est refusée).
-- - Pas de courbe possible (pas de route en marche avant devant la place, courbe en boucle, trop longue ou trop loin
--   des routes) : comme avant, recherche de chemin.
-- - (10/11 soir) Le point de départ de la courbe est cherché aussi sur les autres routes en marche avant qui passent
--   près de l'entrée de la place (la route de la place tourne souvent le dos à son entrée). La courbe évite les
--   véhicules et les outils posés.
-- - (10/11 soir) Sortie : après un attelage ou une pose le nez dans la place, le tracteur est face au fond. Il
--   ne fait plus demi-tour sur place : il recule dans l'axe (plus loin s'il le faut), puis une courbe calculée le
--   mène sur une route en marche avant ; la suite se fait par les routes (ADNoseIn.exitPlan, exitPath).
--
-- Branché par : Modes/AutonomousFront.lua (startDropAt, handleParkStage, fetchRoutePoint), Tasks/FrontPlaceTask.lua
-- (étape « chemin » : la courbe à la place de la recherche de chemin ; recul puis sortie en courbe) et
-- Tasks/FetchToolTask.lua.
-- ============================================================================================================

ADNoseIn = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADNoseIn.RADIUS_MARGIN = 1.2          -- rayon de la courbe = rayon de braquage du tracteur x ça
ADNoseIn.RADIUS_MIN = 6               -- m
ADNoseIn.RADIUS_DEFAULT = 7           -- m : rayon de braquage inconnu
ADNoseIn.ALIGN_TOLERANCE = 0.5        -- m : la ligne de la place est droite tant que ses points sont à moins de ça de l'axe
ADNoseIn.NOSE_REFERENCE = 2           -- m : porte-à-faux arrière d'un tracteur (la ligne de la place est tracée pour lui)
ADNoseIn.ROUTE_BACK = 60              -- m de route remontés avant le début de la marche arrière
ADNoseIn.MAX_ARC = math.rad(135)      -- un arc plus long = boucle, refusé
ADNoseIn.MAX_LENGTH = 45              -- m de courbe au plus
ADNoseIn.TURN_WEIGHT = 1              -- coût d'une courbe = longueur + rayon x angle tourné x ça
ADNoseIn.STEP = 1                     -- m entre deux points de la courbe
ADNoseIn.END_STRAIGHT = 4             -- m tout droit dans l'axe après la courbe (le suivi de chemin dit « arrivé » une
                                      -- demi-longueur de tracteur avant le dernier point : il doit déjà être dans l'axe)
ADNoseIn.MIN_STRAIGHT = 3             -- m au moins entre la fin de ce chemin et l'endroit où le nez s'arrête
ADNoseIn.WIDE_STRAIGHT = 4            -- m de ligne droite en plus avant la place quand l'outil avant est plus large que le
                                      -- tracteur (faucheuse frontale) : son bout doit être dans l'axe en passant l'entrée
ADNoseIn.ROUTE_MARGIN = 2             -- m : à moins de ADGraphManager.MIN_START_DISTANCE + ça d'un point, le tracteur
                                      -- n'y va pas par les routes (il irait en ligne droite, tourné n'importe comment)
ADNoseIn.OVERSHOOT = 1.5              -- m : la courbe doit aussi exister si le tracteur s'arrête ça plus loin que le point
ADNoseIn.UNDERSHOOT = 3               -- m : ... ou ça avant le point
ADNoseIn.MAX_OFF_NETWORK = 3          -- m : la courbe choisie ne s'écarte pas plus que ça d'une route du réseau
ADNoseIn.OFF_NETWORK_SLACK = 1.5      -- m de plus tolérés pour la courbe refaite d'où le tracteur s'est vraiment arrêté
ADNoseIn.NETWORK_RANGE = 80           -- m autour de la place : les routes regardées
ADNoseIn.NETWORK_AGE = 5000           -- ms : la liste de ces routes est gardée ça
ADNoseIn.SEARCH_RANGE = 40            -- m autour de l'entrée de la place : routes en marche avant d'où la courbe peut partir
ADNoseIn.CLEAR_MARGIN = 0.5           -- m entre le côté du tracteur (ou de l'outil avant) et un véhicule ou un outil posé
ADNoseIn.EXIT_EXTRA = 20              -- m de recul en plus, au plus, pour trouver une sortie en courbe
ADNoseIn.EXIT_STEP = 2                -- m entre deux reculs essayés
ADNoseIn.EXIT_RANGE = 35              -- m autour du tracteur : routes en marche avant qu'il peut rejoindre
ADNoseIn.EXIT_REVERSE_WEIGHT = 2      -- coût d'un mètre de recul en plus (la marche arrière est lente)
ADNoseIn.EXIT_ROAD_AHEAD = 60         -- m de route en marche avant qu'il doit y avoir après le point rejoint
ADNoseIn.EXIT_BEHIND = 4              -- m : le point rejoint est au moins ça derrière l'endroit où le tracteur était entré
ADNoseIn.EXIT_TRIES = 20              -- courbes de sortie vérifiées au plus pour chaque recul (les moins chères d'abord)

-- ------------------------------------------------------------------------------------------------------------
-- Courbe arc - ligne droite - arc
-- ------------------------------------------------------------------------------------------------------------
-- cap : angle a tel que la direction = (sin a, cos a) ; sens d'un arc : +1 = le cap augmente, -1 = il diminue
local TWO_PI = 2 * math.pi

local function mod2pi(a)
    a = a % TWO_PI
    if a < 0 then
        a = a + TWO_PI
    end
    -- un tour complet à 1e-6 près = pas d'arc
    if TWO_PI - a < 1e-6 then
        a = 0
    end
    return a
end

local function headingOf(dx, dz)
    return math.atan2(dx, dz)
end

-- centre du cercle de rayon r pris depuis (x, z, cap a) dans le sens s
local function center(x, z, a, s, r)
    return x + s * r * math.cos(a), z - s * r * math.sin(a)
end

-- une des 4 courbes (s1 = sens du 1er arc, s2 = sens du 2e) ; nil si elle n'existe pas
local function curve(x0, z0, a0, x1, z1, a1, r, s1, s2)
    local c1x, c1z = center(x0, z0, a0, s1, r)
    local c2x, c2z = center(x1, z1, a1, s2, r)
    local dx, dz = c2x - c1x, c2z - c1z
    local d = math.sqrt(dx * dx + dz * dz)
    local beta = headingOf(dx, dz)
    local alpha, straight
    if s1 == s2 then
        if d < 1e-6 then
            return nil
        end
        alpha, straight = beta, d
    else
        if d < 2 * r then
            return nil
        end
        alpha = beta + math.asin(math.min(1, 2 * s1 * r / d))
        straight = math.sqrt(math.max(0, d * d - 4 * r * r))
    end
    local arc1 = mod2pi(s1 * (alpha - a0))
    local arc2 = mod2pi(s2 * (a1 - alpha))
    return { s1 = s1, s2 = s2, arc1 = arc1, arc2 = arc2, straight = straight, alpha = alpha, radius = r,
        length = r * (arc1 + arc2) + straight, x0 = x0, z0 = z0, a0 = a0, x1 = x1, z1 = z1, a1 = a1 }
end

-- la meilleure des 4 courbes de (x0, z0, cap a0) à (x1, z1, cap a1) au rayon r : sans boucle, pas trop longue, et
-- acceptée par accept(courbe) s'il est donné ; nil s'il n'y en a pas. cost = longueur + rayon x angle tourné
function ADNoseIn.bestCurve(x0, z0, a0, x1, z1, a1, r, accept)
    local best = nil
    for _, s1 in ipairs({ 1, -1 }) do
        for _, s2 in ipairs({ 1, -1 }) do
            local c = curve(x0, z0, a0, x1, z1, a1, r, s1, s2)
            if c ~= nil and c.arc1 <= ADNoseIn.MAX_ARC and c.arc2 <= ADNoseIn.MAX_ARC and c.length <= ADNoseIn.MAX_LENGTH then
                c.cost = c.length + ADNoseIn.TURN_WEIGHT * r * (c.arc1 + c.arc2)
                if (best == nil or c.cost < best.cost) and (accept == nil or accept(c)) then
                    best = c
                end
            end
        end
    end
    return best
end

-- points de la courbe tous les STEP m (le 1er point, où est le tracteur, n'y est pas), puis END_STRAIGHT m tout droit ;
-- arc = true pour les points pris en virage
function ADNoseIn.samplePoints(c, y)
    local points = {}
    local r = c.radius
    local function add(x, z, onArc)
        points[#points + 1] = { x = x, y = y or 0, z = z, arc = onArc }
    end
    local function arc(x, z, a, s, angle)
        local cx, cz = center(x, z, a, s, r)
        local n = math.max(1, math.ceil(angle * r / ADNoseIn.STEP))
        if angle <= 1e-6 then
            return x, z, a
        end
        for i = 1, n do
            local b = a + s * angle * i / n
            add(cx - s * r * math.cos(b), cz + s * r * math.sin(b), true) -- (en virage le nez déborde, voir swing)
        end
        local last = points[#points]
        return last.x, last.z, a + s * angle
    end
    local function line(x, z, a, length)
        if length <= 1e-6 then
            return x, z
        end
        local n = math.max(1, math.ceil(length / ADNoseIn.STEP))
        for i = 1, n do
            add(x + math.sin(a) * length * i / n, z + math.cos(a) * length * i / n)
        end
        local last = points[#points]
        return last.x, last.z
    end
    local x, z, a = arc(c.x0, c.z0, c.a0, c.s1, c.arc1)
    x, z = line(x, z, c.alpha, c.straight)
    x, z, a = arc(x, z, c.alpha, c.s2, c.arc2)
    line(x, z, c.a1, ADNoseIn.END_STRAIGHT)
    return points
end

-- ------------------------------------------------------------------------------------------------------------
-- Rester sur le sol que le réseau connaît
-- ------------------------------------------------------------------------------------------------------------
-- les bouts de route du réseau (d'un point à un de ses suivants) à moins de NETWORK_RANGE m de (x, z) :
-- liste de { ax, az, bx, bz } ; gardée NETWORK_AGE ms tant que le réseau a le même nombre de points
function ADNoseIn.nearSegments(x, z)
    local cache = ADNoseIn.segments
    local count = ADGraphManager.getWayPointsCount ~= nil and ADGraphManager:getWayPointsCount() or nil
    local now = g_time or 0
    if cache ~= nil and cache.count == count and now >= cache.time and now - cache.time <= ADNoseIn.NETWORK_AGE
        and math.abs(cache.x - x) < 1 and math.abs(cache.z - z) < 1 then
        return cache.list
    end
    local list = {}
    local range2 = ADNoseIn.NETWORK_RANGE * ADNoseIn.NETWORK_RANGE
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w.x ~= nil and w.z ~= nil and w.out ~= nil then
            local dx, dz = w.x - x, w.z - z
            if dx * dx + dz * dz <= range2 then
                for _, outId in pairs(w.out) do
                    local t = ADGraphManager:getWayPointById(outId)
                    if t ~= nil and t.x ~= nil and t.z ~= nil then
                        list[#list + 1] = { ax = w.x, az = w.z, bx = t.x, bz = t.z }
                    end
                end
            end
        end
    end
    ADNoseIn.segments = { count = count, time = now, x = x, z = z, list = list }
    return list
end

-- true si chaque point de la liste est à moins de limit m d'un bout de route
function ADNoseIn.pointsOnNetwork(points, segments, limit)
    local limit2 = limit * limit
    local n = #segments
    local last = 1
    for _, p in ipairs(points) do
        local found = false
        -- le bout de route du point d'avant est souvent encore le bon : commencer par lui
        for k = 0, n - 1 do
            local i = (last + k - 1) % n + 1
            local s = segments[i]
            local ux, uz = s.bx - s.ax, s.bz - s.az
            local l2 = ux * ux + uz * uz
            local t = 0
            if l2 > 0 then
                t = math.max(0, math.min(1, ((p.x - s.ax) * ux + (p.z - s.az) * uz) / l2))
            end
            local ex, ez = s.ax + ux * t - p.x, s.az + uz * t - p.z
            if ex * ex + ez * ez <= limit2 then
                found, last = true, i
                break
            end
        end
        if not found then
            return false
        end
    end
    return true
end

-- true si chaque point de la courbe est à moins de limit m d'un bout de route
function ADNoseIn.staysOnNetwork(c, segments, limit)
    return ADNoseIn.pointsOnNetwork(ADNoseIn.samplePoints(c, 0), segments, limit)
end

-- ------------------------------------------------------------------------------------------------------------
-- Éviter les véhicules et les outils posés
-- ------------------------------------------------------------------------------------------------------------
-- les véhicules et outils à moins de range m de (x, z), sauf le tracteur, ce qu'il porte et ceux de ignore :
-- liste de rectangles { x, z, dx, dz, hl, hw } (centre, axe, demi-longueur, demi-largeur)
function ADNoseIn.obstacles(vehicle, ignore, x, z, range)
    local list = {}
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system == nil or system.vehicles == nil then
        return list
    end
    local own = {}
    own[vehicle] = true
    if AutoDrive.getAllImplements ~= nil then
        for _, o in pairs(AutoDrive.getAllImplements(vehicle, true) or {}) do
            own[o] = true
        end
    end
    for _, o in pairs(ignore or {}) do
        own[o] = true
    end
    for _, v in pairs(system.vehicles) do
        local node = v.components ~= nil and v.components[1] ~= nil and v.components[1].node or nil
        if not own[v] and not v.isDeleted and node ~= nil then
            local vx, _, vz = getWorldTranslation(node)
            if MathUtil.vector2Length(vx - x, vz - z) <= range then
                local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
                local len = MathUtil.vector2Length(dx, dz)
                if len > 0.001 then
                    dx, dz = dx / len, dz / len
                    local size = v.size or {}
                    local offset = size.lengthOffset or 0
                    list[#list + 1] = { x = vx + dx * offset, z = vz + dz * offset, dx = dx, dz = dz,
                        hl = (size.length or 3) / 2, hw = (size.width or 3) / 2 }
                end
            end
        end
    end
    return list
end

-- demi-largeur à garder libre de chaque côté du chemin : le plus large du tracteur et de l'outil avant, plus la marge
function ADNoseIn.clearance(vehicle, tool)
    local w = (vehicle.size ~= nil and vehicle.size.width) or 3
    local tw = (tool ~= nil and tool.size ~= nil and tool.size.width) or 0
    return math.max(w, tw) / 2 + ADNoseIn.CLEAR_MARGIN
end

-- en virage, le coin avant du tracteur (ou de l'outil avant) passe à l'extérieur du couloir : de combien (m), au
-- rayon r
function ADNoseIn.swing(vehicle, tool, r)
    local w = (vehicle.size ~= nil and vehicle.size.width) or 3
    local tw = (tool ~= nil and tool.size ~= nil and tool.size.width) or 0
    local half = math.max(w, tw) / 2
    local nose = ADNoseIn.noseLength(vehicle, tool)
    return math.sqrt((r + half) * (r + half) + nose * nose) - (r + half)
end

-- true si aucun point de la liste n'est à moins de clearance m d'un des rectangles (clearance + swing m pour les
-- points pris en virage)
function ADNoseIn.pointsClear(points, obstacles, clearance, swing)
    if obstacles == nil or #obstacles == 0 then
        return true
    end
    local straight2 = clearance * clearance
    local turn2 = (clearance + (swing or 0)) * (clearance + (swing or 0))
    for _, p in ipairs(points) do
        local c2 = p.arc and turn2 or straight2
        for _, o in ipairs(obstacles) do
            local ox, oz = p.x - o.x, p.z - o.z
            local along = math.max(0, math.abs(ox * o.dx + oz * o.dz) - o.hl)
            local side = math.max(0, math.abs(ox * o.dz - oz * o.dx) - o.hw)
            if along * along + side * side < c2 then
                return false
            end
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- La place : où le tracteur doit être dans l'axe, le nez vers le fond
-- ------------------------------------------------------------------------------------------------------------
-- rayon de la courbe pour ce tracteur
function ADNoseIn.radius(vehicle)
    local r = nil
    if AutoDrive.getDriverRadius ~= nil then
        local ok, value = FarmPilotCall(AutoDrive.getDriverRadius, vehicle, true)
        if ok and type(value) == "number" and value > 0 then
            r = value
        end
    end
    if r == nil then
        r = ADNoseIn.RADIUS_DEFAULT
    end
    return math.max(ADNoseIn.RADIUS_MIN, r * ADNoseIn.RADIUS_MARGIN)
end

-- longueur devant le point de repère du tracteur : la moitié du tracteur, plus l'outil attelé à l'avant
function ADNoseIn.noseLength(vehicle, tool)
    local len = (vehicle.size ~= nil and vehicle.size.length) or 6
    local tl = (tool ~= nil and tool.size ~= nil and tool.size.length) or 0
    return len / 2 + tl
end

-- { x, y, z, a, hx, hz } : le point de l'axe de la place où le tracteur doit être aligné, le nez vers le fond.
-- C'est là où la ligne de la place devient droite (elle est tracée pour l'arrière d'un tracteur qui recule), reculé
-- de ce que le nez dépasse en plus ; jamais plus près du fond que le nez + le bout de chemin tout droit + MIN_STRAIGHT
-- (ligne de place courbe jusqu'au bout : le chemin finirait sur l'outil ou au-delà du fond). tool : l'outil attelé à
-- l'avant, ou celui à reprendre au fond. ahead : m entre le fond de la place et le bout de cet outil (un outil arrière
-- est rangé au fond, l'outil avant devant lui) ; rien = 0. Outil plus large que le tracteur : WIDE_STRAIGHT m plus tôt.
-- nil si la place ne se prend pas en marche arrière
function ADNoseIn.target(vehicle, mwp, tool, ahead)
    local hx, hz, reverse = AutonomousMode.placeAxis(mwp)
    if hx == nil or not reverse then
        return nil
    end
    local depth, cur = 0, mwp
    for _ = 1, 30 do
        local p = AutonomousMode.reversePrevious(cur)
        if p == nil or p == mwp then
            break
        end
        local ox, oz = p.x - mwp.x, p.z - mwp.z
        local lateral = math.abs(ox * hz - oz * hx)
        local along = -(ox * hx + oz * hz)
        if lateral > ADNoseIn.ALIGN_TOLERANCE or along < depth then
            break
        end
        depth, cur = along, p
    end
    local nose = ADNoseIn.noseLength(vehicle, tool)
    local back = math.max(depth + math.max(0, nose - ADNoseIn.NOSE_REFERENCE), (ahead or 0) + nose + ADNoseIn.END_STRAIGHT + ADNoseIn.MIN_STRAIGHT)
    local width = (vehicle.size ~= nil and vehicle.size.width) or 3
    if tool ~= nil and tool.size ~= nil and (tool.size.width or 0) > width then
        back = back + ADNoseIn.WIDE_STRAIGHT
    end
    return { x = mwp.x - hx * back, y = mwp.y, z = mwp.z - hz * back, a = headingOf(hx, hz), hx = hx, hz = hz }
end

-- ------------------------------------------------------------------------------------------------------------
-- Le point du réseau d'où partir
-- ------------------------------------------------------------------------------------------------------------
ADNoseIn.ROUTE_WEIGHT = 0.1           -- 10 m de route en plus coûtent autant qu'un mètre de courbe
ADNoseIn.ROUTE_TRIES = 8              -- points de départ dont la route est calculée, au plus

-- les points d'une route en marche avant d'où une courbe entre dans la place, du meilleur au moins bon : liste de
-- { wp, prev (le point d'avant sur la route : le tracteur arrive par là), curve, target, radius }.
-- D'abord la route qui mène à la place (avant le point où la marche arrière commence) ; si elle n'en donne aucun,
-- les autres routes en marche avant qui passent près de l'entrée (points où une seule route arrive : le tracteur
-- y est toujours tourné pareil). allow(point) : false = ce point-là n'est pas pris. ahead : voir target. ignore :
-- véhicules qui ne gênent pas (l'outil à reprendre).
function ADNoseIn.approaches(vehicle, mwp, tool, allow, ahead, ignore)
    local found = {}
    local target = ADNoseIn.target(vehicle, mwp, tool, ahead)
    local start = target ~= nil and AutonomousMode.placeReverseStart(mwp) or nil
    if start == nil then
        return found
    end
    local r = ADNoseIn.radius(vehicle)
    local segments = ADNoseIn.nearSegments(target.x, target.z)
    local obstacles = ADNoseIn.obstacles(vehicle, ignore, target.x, target.z, ADNoseIn.NETWORK_RANGE)
    local clearance = ADNoseIn.clearance(vehicle, tool)
    local swing = ADNoseIn.swing(vehicle, tool, r)
    local function free(c)
        return ADNoseIn.pointsClear(ADNoseIn.samplePoints(c, 0), obstacles, clearance, swing)
    end
    local function accept(c)
        return ADNoseIn.staysOnNetwork(c, segments, ADNoseIn.MAX_OFF_NETWORK) and free(c)
    end
    local function acceptLate(c)
        return ADNoseIn.staysOnNetwork(c, segments, ADNoseIn.MAX_OFF_NETWORK + ADNoseIn.OFF_NETWORK_SLACK) and free(c)
    end
    local seen = {}
    -- la courbe depuis cur, où le tracteur arrive de p
    local function try(cur, p)
        seen[cur.id] = true
        local dx, dz = cur.x - p.x, cur.z - p.z
        local len = math.sqrt(dx * dx + dz * dz)
        if len <= 0.01 or (allow ~= nil and not allow(cur)) then
            return len
        end
        local a = headingOf(dx, dz)
        local c = ADNoseIn.bestCurve(cur.x, cur.z, a, target.x, target.z, target.a, r, accept)
        -- le tracteur ne s'arrête pas pile sur le point : la courbe doit exister aussi un peu plus loin et un peu avant
        local late = c ~= nil and ADNoseIn.bestCurve(cur.x + math.sin(a) * ADNoseIn.OVERSHOOT, cur.z + math.cos(a) * ADNoseIn.OVERSHOOT, a, target.x, target.z, target.a, r, acceptLate) or nil
        local early = late ~= nil and ADNoseIn.bestCurve(cur.x - math.sin(a) * ADNoseIn.UNDERSHOOT, cur.z - math.cos(a) * ADNoseIn.UNDERSHOOT, a, target.x, target.z, target.a, r, acceptLate) or nil
        if c ~= nil and late ~= nil and early ~= nil then
            found[#found + 1] = { wp = cur, prev = p, curve = c, target = target, radius = r }
        end
        return len
    end
    -- 1) la route qui mène à la place
    local cur, done = start, 0
    for _ = 1, 40 do
        local inc = cur.incoming ~= nil and cur.incoming[1] or nil
        local p = inc ~= nil and ADGraphManager:getWayPointById(inc) or nil
        if p == nil or p.x == nil or p == start then
            break
        end
        done = done + try(cur, p)
        if done > ADNoseIn.ROUTE_BACK then
            break
        end
        cur = p
    end
    -- 2) aucune : les autres routes en marche avant près de l'entrée
    if #found == 0 then
        for _, wp in pairs(ADGraphManager:getWayPoints()) do
            if wp.x ~= nil and wp.z ~= nil and seen[wp.id] == nil and wp.incoming ~= nil and #wp.incoming == 1
                and MathUtil.vector2Length(wp.x - target.x, wp.z - target.z) <= ADNoseIn.SEARCH_RANGE then
                local p = ADGraphManager:getWayPointById(wp.incoming[1])
                if p ~= nil and p.x ~= nil then
                    try(wp, p)
                end
            end
        end
    end
    table.sort(found, function(a, b)
        if a.curve.cost ~= b.curve.cost then
            return a.curve.cost < b.curve.cost
        end
        return a.wp.id < b.wp.id
    end)
    return found
end

-- le meilleur de ces points ; nil s'il n'y en a pas
function ADNoseIn.approach(vehicle, mwp, tool, allow, ahead, ignore)
    return ADNoseIn.approaches(vehicle, mwp, tool, allow, ahead, ignore)[1]
end

-- où est le tracteur et son cap ; nil si inconnu
local function poseOf(vehicle)
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local fx, _, fz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    if fx == nil then
        return nil
    end
    local len = math.sqrt(fx * fx + fz * fz)
    if len < 1e-6 then
        return nil
    end
    return x, z, fx / len, fz / len
end

-- longueur (m) de la route du tracteur jusqu'au point de départ, s'il y arrive bien par le point prévu ; nil sinon
function ADNoseIn.routeLength(vehicle, candidate)
    if ADGraphManager.getPathTo == nil then
        return 0
    end
    local ok, path = FarmPilotCall(ADGraphManager.getPathTo, ADGraphManager, vehicle, candidate.wp.id)
    if not ok or path == nil or #path < 1 or path[#path].id ~= candidate.wp.id then
        return nil
    end
    local x, z, fx, fz = poseOf(vehicle)
    if x == nil then
        return nil
    end
    local prev = candidate.prev
    if #path >= 2 then
        if prev ~= nil and path[#path - 1].id ~= prev.id then
            return nil
        end
    else
        -- le point juste avant n'est pas dans la liste (le trajet part de lui) : seulement si le tracteur est déjà sur
        -- la route qui arrive au point, dans son sens
        if prev == nil then
            return nil
        end
        local dx, dz = candidate.wp.x - prev.x, candidate.wp.z - prev.z
        local len = math.sqrt(dx * dx + dz * dz)
        if len < 0.01 then
            return nil
        end
        dx, dz = dx / len, dz / len
        local side = math.abs((x - prev.x) * dz - (z - prev.z) * dx)
        if fx * dx + fz * dz < math.cos(math.rad(30)) or (candidate.wp.x - x) * dx + (candidate.wp.z - z) * dz <= 0 or side > ADNoseIn.MAX_OFF_NETWORK then
            return nil
        end
    end
    -- du tracteur au 1er point, puis de point en point ; un trajet qui passe par une marche arrière (une autre place,
    -- peut-être occupée) est refusé
    local length = MathUtil.vector2Length(path[1].x - x, path[1].z - z)
    for i = 2, #path do
        if ADGraphManager.isReverseRoad ~= nil and ADGraphManager:isReverseRoad(path[i - 1], path[i]) then
            return nil
        end
        length = length + MathUtil.vector2Length(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z)
    end
    return length
end

local function heightAt(x, z, default)
    if getTerrainHeightAtWorldPos ~= nil and g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z)
    end
    return default
end

-- les points d'une courbe pour drivePathModule:setWayPoints (points hors réseau, comme ceux de la recherche de
-- chemin ; le 1er est le tracteur)
local function pathOf(c, x, z, y)
    local points = ADNoseIn.samplePoints(c, y)
    table.insert(points, 1, { x = x, y = y, z = z })
    for _, p in ipairs(points) do
        p.y = heightAt(p.x, p.z, y)
        p.isPathFinderPoint = true
    end
    return points
end

-- la courbe du tracteur (où il est, comme il est tourné) jusqu'à l'axe de la place : liste de points, et la
-- courbe ; nil s'il n'y en a pas (boucle, trop long, trop loin des routes, véhicule sur le passage)
function ADNoseIn.pathFromVehicle(vehicle, mwp, tool, ahead, ignore)
    local target = ADNoseIn.target(vehicle, mwp, tool, ahead)
    local x, z, fx, fz = poseOf(vehicle)
    if target == nil or x == nil then
        return nil
    end
    local segments = ADNoseIn.nearSegments(target.x, target.z)
    local obstacles = ADNoseIn.obstacles(vehicle, ignore, target.x, target.z, ADNoseIn.NETWORK_RANGE)
    local clearance = ADNoseIn.clearance(vehicle, tool)
    local r = ADNoseIn.radius(vehicle)
    local swing = ADNoseIn.swing(vehicle, tool, r)
    local c = ADNoseIn.bestCurve(x, z, headingOf(fx, fz), target.x, target.z, target.a, r, function(candidate)
        return ADNoseIn.staysOnNetwork(candidate, segments, ADNoseIn.MAX_OFF_NETWORK + ADNoseIn.OFF_NETWORK_SLACK)
            and ADNoseIn.pointsClear(ADNoseIn.samplePoints(candidate, 0), obstacles, clearance, swing)
    end)
    if c == nil then
        return nil
    end
    return pathOf(c, x, z, target.y), c
end

-- { wp, ready } : par où passer avant d'entrer le nez en avant dans la place. ready = la courbe part d'où est le
-- tracteur (pas de route à faire) ; sinon wp = le point du réseau où aller d'abord. nil : pas de courbe possible.
-- Tracteur trop près du point pour y aller par les routes (il irait en ligne droite et arriverait tourné n'importe
-- comment) : la courbe d'où il est si elle existe, sinon un point de départ plus loin (il fait le tour).
-- Entre plusieurs points de départ : la courbe la plus courte, 10 m de route en plus comptant pour 1 m de courbe.
function ADNoseIn.plan(vehicle, mwp, tool, ahead, ignore)
    local list = ADNoseIn.approaches(vehicle, mwp, tool, nil, ahead, ignore)
    if #list == 0 then
        return nil
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local minRoute = (ADGraphManager.MIN_START_DISTANCE or 8) + ADNoseIn.ROUTE_MARGIN
    local function far(wp)
        return MathUtil.vector2Length(wp.x - x, wp.z - z) > minRoute
    end
    if not far(list[1].wp) and ADNoseIn.pathFromVehicle(vehicle, mwp, tool, ahead, ignore) ~= nil then
        return { wp = list[1].wp, ready = true, approach = list[1] }
    end
    local best, bestScore, tries = nil, math.huge, 0
    for _, candidate in ipairs(list) do
        if candidate.curve.cost >= bestScore then
            break -- (liste triée par courbe : les suivants ne peuvent plus faire mieux)
        end
        if far(candidate.wp) then
            tries = tries + 1
            local length = ADNoseIn.routeLength(vehicle, candidate)
            if length ~= nil then
                local score = candidate.curve.cost + length * ADNoseIn.ROUTE_WEIGHT
                if score < bestScore then
                    best, bestScore = candidate, score
                    best.route = length
                end
            end
            if tries >= ADNoseIn.ROUTE_TRIES then
                break
            end
        end
    end
    if best == nil then
        return nil
    end
    return { wp = best.wp, ready = false, approach = best }
end

-- ------------------------------------------------------------------------------------------------------------
-- Sortie : rejoindre une route en marche avant après un attelage ou une pose le nez dans la place
-- ------------------------------------------------------------------------------------------------------------
-- la route continue en marche avant au moins EXIT_ROAD_AHEAD m après wp (pas l'entrée d'une place, qui finit en
-- marche arrière, ni une impasse)
local function roadContinues(wp, already)
    local visited = {}
    local function walk(cur, done, depth)
        if done >= ADNoseIn.EXIT_ROAD_AHEAD then
            return true
        end
        if depth > 80 or cur.out == nil or visited[cur.id] then
            return false
        end
        visited[cur.id] = true
        for _, outId in pairs(cur.out) do
            local n = ADGraphManager:getWayPointById(outId)
            if n ~= nil and n.x ~= nil and n.incoming ~= nil and table.contains(n.incoming, cur.id) then
                if walk(n, done + MathUtil.vector2Length(n.x - cur.x, n.z - cur.z), depth + 1) then
                    return true
                end
            end
        end
        return false
    end
    return walk(wp, already or 0, 0)
end

-- { back, wp, a, curve, cost } : de combien reculer tout droit (au moins minBack m), puis la courbe en marche avant
-- jusqu'au point wp d'une route, au cap a de cette route ; nil s'il n'y en a pas (le recul de minBack suffit alors,
-- comme avant). Le recul en plus et la courbe restent près des routes du réseau et loin des véhicules posés.
-- tool : l'outil attelé à l'avant (largeur) ; ignore : véhicules qui ne gênent pas
function ADNoseIn.exitPlan(vehicle, minBack, tool, ignore)
    local x, z, fx, fz = poseOf(vehicle)
    if x == nil then
        return nil
    end
    local a0 = headingOf(fx, fz)
    local r = ADNoseIn.radius(vehicle)
    local segments = ADNoseIn.nearSegments(x, z)
    local obstacles = ADNoseIn.obstacles(vehicle, ignore, x, z, ADNoseIn.NETWORK_RANGE)
    local clearance = ADNoseIn.clearance(vehicle, tool)
    local swing = ADNoseIn.swing(vehicle, tool, r)
    -- les routes en marche avant autour : { wp, next, a = cap en quittant wp vers next }. Seulement derrière l'endroit
    -- où le tracteur est entré (une route qui continue devant lui le ramènerait vers l'outil ou le fond de la place)
    local roads = {}
    local reach = ADNoseIn.EXIT_RANGE + minBack + ADNoseIn.EXIT_EXTRA
    for _, cur in pairs(ADGraphManager:getWayPoints()) do
        if cur.x ~= nil and cur.z ~= nil and cur.out ~= nil and cur.incoming ~= nil and #cur.incoming > 0
            and MathUtil.vector2Length(cur.x - x, cur.z - z) <= reach then
            for _, outId in pairs(cur.out) do
                local n = ADGraphManager:getWayPointById(outId)
                if n ~= nil and n.x ~= nil and n.incoming ~= nil and table.contains(n.incoming, cur.id) then
                    local dx, dz = n.x - cur.x, n.z - cur.z
                    if dx * dx + dz * dz > 0.0001 and (cur.x - x) * fx + (cur.z - z) * fz <= -ADNoseIn.EXIT_BEHIND then
                        roads[#roads + 1] = { wp = cur, next = n, a = headingOf(dx, dz), key = cur.id .. ">" .. n.id }
                    end
                end
            end
        end
    end
    -- pour chaque recul : les courbes possibles de la moins chère à la plus chère (calcul léger), puis la première
    -- qui reste près des routes et loin des véhicules posés (calcul lourd : EXIT_TRIES essais au plus par recul).
    -- Une courbe qui ne peut pas faire mieux que la meilleure déjà trouvée n'est pas calculée.
    local best = nil
    local continues = {}
    local back = minBack
    while back <= minBack + ADNoseIn.EXIT_EXTRA do
        local px, pz = x - fx * back, z - fz * back
        if back > minBack then
            -- le recul en plus : sur le sol connu, rien dessus
            local point = { { x = px, z = pz } }
            if not ADNoseIn.pointsOnNetwork(point, segments, ADNoseIn.MAX_OFF_NETWORK + ADNoseIn.OFF_NETWORK_SLACK)
                or not ADNoseIn.pointsClear(point, obstacles, clearance) then
                break
            end
        end
        local extra = (back - minBack) * ADNoseIn.EXIT_REVERSE_WEIGHT
        local list = {}
        for _, road in ipairs(roads) do
            local d = MathUtil.vector2Length(road.wp.x - px, road.wp.z - pz)
            -- (une courbe est au moins aussi longue que la ligne droite, et tourne au moins de l'écart de cap)
            local turn = math.abs((road.a - a0 + math.pi) % TWO_PI - math.pi)
            if d <= ADNoseIn.EXIT_RANGE and (best == nil or d + ADNoseIn.TURN_WEIGHT * r * turn + extra < best.cost) then
                if continues[road.key] == nil then
                    continues[road.key] = roadContinues(road.next, MathUtil.vector2Length(road.next.x - road.wp.x, road.next.z - road.wp.z))
                end
                if continues[road.key] then
                    for _, s1 in ipairs({ 1, -1 }) do
                        for _, s2 in ipairs({ 1, -1 }) do
                            local c = curve(px, pz, a0, road.wp.x, road.wp.z, road.a, r, s1, s2)
                            if c ~= nil and c.arc1 <= ADNoseIn.MAX_ARC and c.arc2 <= ADNoseIn.MAX_ARC and c.length <= ADNoseIn.MAX_LENGTH then
                                c.cost = c.length + ADNoseIn.TURN_WEIGHT * r * (c.arc1 + c.arc2)
                                if best == nil or c.cost + extra < best.cost then
                                    list[#list + 1] = { back = back, wp = road.wp, a = road.a, curve = c, cost = c.cost + extra }
                                end
                            end
                        end
                    end
                end
            end
        end
        table.sort(list, function(c1, c2)
            if c1.cost ~= c2.cost then
                return c1.cost < c2.cost
            end
            return c1.wp.id < c2.wp.id
        end)
        for i = 1, math.min(#list, ADNoseIn.EXIT_TRIES) do
            local candidate = list[i]
            if ADNoseIn.pointsClear(ADNoseIn.samplePoints(candidate.curve, 0), obstacles, clearance, swing)
                and ADNoseIn.staysOnNetwork(candidate.curve, segments, ADNoseIn.MAX_OFF_NETWORK) then
                best = candidate
                break
            end
        end
        back = back + ADNoseIn.EXIT_STEP
    end
    return best
end

-- après le recul : la courbe d'où est vraiment le tracteur jusqu'au point de la route prévu (liste de points, et la
-- courbe) ; nil s'il n'y en a plus
function ADNoseIn.exitPath(vehicle, plan, tool, ignore)
    local x, z, fx, fz = poseOf(vehicle)
    if x == nil or plan == nil or plan.wp == nil then
        return nil
    end
    local segments = ADNoseIn.nearSegments(x, z)
    local obstacles = ADNoseIn.obstacles(vehicle, ignore, x, z, ADNoseIn.NETWORK_RANGE)
    local clearance = ADNoseIn.clearance(vehicle, tool)
    local r = ADNoseIn.radius(vehicle)
    local swing = ADNoseIn.swing(vehicle, tool, r)
    local c = ADNoseIn.bestCurve(x, z, headingOf(fx, fz), plan.wp.x, plan.wp.z, plan.a, r, function(candidate)
        return ADNoseIn.staysOnNetwork(candidate, segments, ADNoseIn.MAX_OFF_NETWORK + ADNoseIn.OFF_NETWORK_SLACK)
            and ADNoseIn.pointsClear(ADNoseIn.samplePoints(candidate, 0), obstacles, clearance, swing)
    end)
    if c == nil then
        return nil
    end
    return pathOf(c, x, z, plan.wp.y or 0), c
end
