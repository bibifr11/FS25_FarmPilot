-- ============================================================================================================
-- FarmPilot : AutonomousHeaderGate.lua
-- Mode Autonome, moissonneuse équipée seule : la moissonneuse ATTEND EN FACE DE L'ENTRÉE DU CHAMP, de l'autre côté
-- de la route, le nez vers le champ ; le tracteur reste sur la route et arrête la remorque porte-barre devant elle,
-- le cadre de la barre de son côté. Elle prend la barre droit devant, recule un peu, laisse repartir le tracteur
-- par la route, puis entre tout droit dans le champ (AutonomousHeaderEntry.lua). Aucune marche arrière de la
-- remorque, aucune recherche de chemin.
--
-- Règle (13/11) :
-- - Quand : au départ, la route du tracteur passe DEVANT l'entrée du champ (route droite sur GATE_BASE m au moins,
--   le point du champ sur son côté, la route qui continue tout droit après l'entrée). Essayé AVANT tout le reste
--   (arrêt avant le bout, recul jusqu'au croisement, marche arrière en biais) : rien n'est écrit pour un endroit,
--   tout est lu sur les routes et sur le terrain.
-- - Par où passe le tracteur : la remorque est sur la route, dans son sens ; le cadre de la barre doit regarder
--   l'autre côté de la route (pas le champ). Si le tracteur arrive par le mauvais bout, la manœuvre n'est pas
--   faite ici (la suite habituelle).
-- - Il faut aussi : le champ à récolter droit devant le cadre, à moins d'ENTRY_RANGE m, le couloir praticable sur
--   la largeur de la barre (AutonomousHeaderEntry.lua : entryCorridor) ; en face de l'entrée, la place de la
--   moissonneuse (ni culture debout, ni eau, ni fossé, ni obstacle) : là où elle se range, là où elle attend, là
--   où elle recule avec la barre.
-- - La moissonneuse part DEVANT le tracteur, sans attendre la remorque. Elle suit sa route, dépasse l'entrée du
--   rayon de sa marche arrière, puis recule en quart de cercle de l'autre côté de la route jusque dans l'axe de
--   l'entrée, le nez vers le champ (Tasks/HeaderGateTask.lua). Elle attend là, son attelage à GATE_GAP m de la
--   place du cadre. Déjà garée en face de l'entrée au départ : elle n'en bouge pas.
-- - Le tracteur ne part pas avant que la moissonneuse soit devant lui sur la route (GATE_LEAD m d'avance). Il
--   s'arrête GATE_HOLD m avant l'entrée tant qu'elle n'est pas en place, puis avance tout droit, décalé de
--   GATE_OFFSET m vers le champ quand le bord de la route est libre, et s'arrête quand le cadre de la barre est
--   dans l'axe de la moissonneuse, là où elle est vraiment (Tasks/HeaderGateTask.lua).
-- - Barre prise : petit recul, le tracteur repart par la route, entrée directe dans le champ (inchangé :
--   AutonomousHeaderEntry.lua, AutonomousHeaderClear.lua).
-- - Pas possible ou pas réussi (la raison est dans le journal) : la suite habituelle reprend d'où chacun est.
-- - Réglage GATE = false : comme avant.
--
-- Branché par : Modes/AutonomousHeaderFollow.lua (startWaitLeave, enveloppé ici), Modes/AutonomousHeader.lua
-- (tractorStart, tractorStage, combineStage, monitor, AutonomousMode:reset, enveloppés ici),
-- Modes/AutonomousHeaderSpot.lua (checkRouteStop, moveOn, enveloppés ici), Modes/AutonomousHeaderBackIn.lua
-- (startBackIn, enveloppé ici), Modes/AutonomousFront.lua (afterFetch et fetchRoutePoint, enveloppés ici). Chargé
-- par register.lua après AutonomousHeaderRoadBack.lua et avant AutonomousHeaderHookup.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.GATE = true                 -- false : jamais de barre amenée devant la moissonneuse en face de l'entrée
ADHeaderFlow.GATE_SPAN = 40              -- m du bout de la route du tracteur : la route droite devant l'entrée finit avant
ADHeaderFlow.GATE_BASE = 12              -- m de route droite au moins avant l'entrée
ADHeaderFlow.GATE_CHORD_DEV = 0.75       -- m d'écart au plus à la ligne, sur cette longueur
ADHeaderFlow.GATE_SIDE_MIN = 3           -- m du point du champ à l'axe de la route, au moins (sinon le champ est au bout de la route)
ADHeaderFlow.GATE_SIDE_MAX = 25          -- m au plus
ADHeaderFlow.GATE_BEHIND = 3             -- m : l'entrée est au plus ça avant le dernier point droit de la route
ADHeaderFlow.GATE_AHEAD = 25             -- m après ce point, au plus
ADHeaderFlow.GATE_STRAIGHT = 12          -- ° : route droite après l'entrée
ADHeaderFlow.GATE_ROAD_DEV = 1.5         -- m d'écart à l'axe de la route, au plus, après l'entrée
ADHeaderFlow.GATE_BEYOND_MAX = 80        -- m de route regardés après l'entrée
ADHeaderFlow.GATE_ROAD_SIDE = 4          -- m de l'axe de la route, au plus, pour un point de route de la moissonneuse
ADHeaderFlow.GATE_ROAD_ANGLE = 15        -- ° au plus entre sa route et la route, là
ADHeaderFlow.GATE_REACH = 40             -- m de part et d'autre de l'entrée où sa route est cherchée
ADHeaderFlow.GATE_FACE = 25              -- ° au plus entre le cadre de la barre et la perpendiculaire à la route
ADHeaderFlow.GATE_GAP = 3                -- m entre l'attelage de la moissonneuse qui attend et le cadre de la barre
ADHeaderFlow.GATE_GAP_MAX = 12           -- m au plus (moissonneuse déjà garée en face)
ADHeaderFlow.GATE_PASS = 1.5             -- m entre le nez de la moissonneuse et le flanc du tracteur qui passe
ADHeaderFlow.GATE_OFFSET = 1             -- m : le tracteur passe décalé d'autant vers le champ, bord de route libre
ADHeaderFlow.GATE_VERGE = 0.3            -- m de bord libre en plus des roues du tracteur décalé
ADHeaderFlow.GATE_RADIUS = 1.15          -- rayon de la marche arrière de la moissonneuse = son rayon de braquage x ça
ADHeaderFlow.GATE_PAST = 1               -- m : sa route dépasse d'autant le début de sa marche arrière
ADHeaderFlow.GATE_ALIGN_RUN = 4          -- m de recul en plus dans l'axe de l'entrée, pour finir droite
ADHeaderFlow.GATE_STEP = 0.5             -- m entre deux points du chemin de sa marche arrière
ADHeaderFlow.GATE_ROAD_EDGE = 1          -- m de l'axe de la route : plus près, le sol n'est pas contrôlé (la route)
ADHeaderFlow.GATE_WHEEL_MARGIN = 0.5     -- m de chaque côté de la moissonneuse (sol : culture, eau, fossé)
ADHeaderFlow.GATE_OBSTACLE_MARGIN = 0.4  -- m de chaque côté (arbres, clôtures...)
ADHeaderFlow.GATE_HOLD_GAP = 4           -- m entre le tracteur arrêté avant l'entrée et la moissonneuse qui manœuvre
ADHeaderFlow.GATE_LEAD = 20              -- m d'avance de la moissonneuse, par la route, pour que le tracteur parte
ADHeaderFlow.GATE_POSE_ANGLE = 15        -- ° au plus entre la moissonneuse en place et la perpendiculaire à la route
ADHeaderFlow.GATE_PLACE_ALONG = 8        -- m de l'axe de l'entrée, au plus, pour une moissonneuse déjà garée en face
ADHeaderFlow.GATE_PLACE_MAX = 25         -- m de la route, au plus
ADHeaderFlow.GATE_WAIT = 600000          -- ms d'attente du tracteur avant l'entrée, au plus
ADHeaderFlow.GATE_ROUTE_STEP = 5         -- m entre les points ajoutés à la route de la moissonneuse

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

local function isWater(x, z, h)
    return ADHeaderFlow.isWater ~= nil and ADHeaderFlow.isWater(x, z, h) == true
end

local function headerDims(header)
    if ADHeaderFlow.headerBox ~= nil then
        return ADHeaderFlow.headerBox(header)
    end
    local size = header ~= nil and header.size or nil
    local w, l = size ~= nil and size.width or 9, size ~= nil and size.length or 3
    return math.min(w, l), math.max(w, l)
end

local function routeLength(route, from)
    local l = 0
    for k = math.max(from or 1, 1) + 1, #route do
        l = l + dist(route[k], route[k - 1])
    end
    return l
end

-- repère de l'entrée : a = m le long de la route (dans le sens du tracteur) depuis l'axe de l'entrée, q = m de
-- l'axe de la route vers l'autre côté (à l'opposé du champ)
local function coords(site, x, z)
    local ox, oz = x - site.x, z - site.z
    return ox * site.rx + oz * site.rz, ox * site.nx + oz * site.nz
end

local function world(site, a, q)
    return site.x + site.rx * a + site.nx * q, site.z + site.rz * a + site.nz * q
end

-- place et cap d'un véhicule dans ce repère : a, q, cosinus avec le sens de la route, cosinus avec le sens « vers
-- le champ », x, z
local function poseOf(site, vehicle)
    local node = vehicle.components[1].node
    local x, _, z = getWorldTranslation(node)
    local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
    fx, fz = unit(fx, fz)
    if fx == nil then
        fx, fz = site.rx, site.rz
    end
    local a, q = coords(site, x, z)
    return a, q, fx * site.rx + fz * site.rz, -(fx * site.nx + fz * site.nz), x, z, fx, fz
end
ADHeaderFlow.gatePose = poseOf
ADHeaderFlow.gateCoords = coords
ADHeaderFlow.gateWorld = world

-- boîte (centre, sens, demi-largeur, demi-longueur), de 0,3 m à 3,3 m au-dessus du sol : un obstacle fixe dedans ?
local function boxHit(t, cx, cz, dx, dz, halfWidth, halfLength)
    local yield = t ~= nil and t.ad ~= nil and t.ad.trafficYieldModule or nil
    if yield == nil or yield.overlapHitStatic == nil then
        return false
    end
    return yield:overlapHitStatic(cx, groundY(cx, cz) + 1.8, cz, MathUtil.getYRotationFromDirection(dx, dz), halfWidth, 1.5, halfLength) == true,
        yield.overlapHitName
end

local function attachedTo(trailer, t)
    local attacher = trailer ~= nil and trailer.getAttacherVehicle ~= nil and trailer:getAttacherVehicle() or nil
    if attacher == nil then
        return false
    end
    local root = attacher.getRootVehicle ~= nil and attacher:getRootVehicle() or attacher
    return root == t or attacher == t
end

-- ------------------------------------------------------------------------------------------------------------
-- L'attelage : de quel côté de la remorque est le cadre, la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- { hx, hz (cadre de la barre, repère de la caisse de la remorque), fdx, fdz (vers où il regarde), side (+1 cadre à
-- gauche), cw, cl, dj (moissonneuse : largeur, longueur, m de son repère à son attelage avant), rc (son rayon), tw
-- (largeur du tracteur), tl (longueur de la remorque), depth, span (barre) } ; nil, raison
local function gateRig(job)
    local t, trailer, header, combine = job.tractor, job.trailer, job.header, job.combine
    if t == nil or trailer == nil or header == nil or combine == nil or trailer.components == nil then
        return nil, "attelage inconnu"
    end
    local hitch = ADAutonomousManager.frontHitch(combine, header, true)
    if hitch == nil then
        return nil, "cadre de la barre introuvable"
    end
    local root = trailer.components[1].node
    local hx, _, hz = worldToLocal(root, hitch.x, hitch.y, hitch.z)
    local fdx, _, fdz = worldDirectionToLocal(root, hitch.dirX, 0, hitch.dirZ)
    if math.abs(fdx) < 0.7 then
        return nil, "barre posée dans l'axe de la remorque"
    end
    local cw = (combine.size ~= nil and combine.size.width) or ADHeaderFlow.DEFAULT_COMBINE_WIDTH
    local cl = (combine.size ~= nil and combine.size.length) or ADHeaderFlow.DEFAULT_COMBINE_LENGTH
    local dj = cl / 2
    local _, cj = ADAutonomousManager.matchFrontJoints(combine, header, false)
    if cj ~= nil and cj.jointTransform ~= nil then
        local jx, jy, jz = getWorldTranslation(cj.jointTransform)
        local _, _, ahead = worldToLocal(combine.components[1].node, jx, jy, jz)
        if ahead > 0.5 then
            dj = ahead
        end
    end
    local rc = (ADNoseIn ~= nil and ADNoseIn.radius ~= nil) and ADNoseIn.radius(combine) or 9
    local depth, span = headerDims(header)
    return { hx = hx, hz = hz, fdx = fdx, fdz = fdz, side = fdx > 0 and 1 or -1, cw = cw, cl = cl, dj = dj, rc = rc,
        tw = (t.size ~= nil and t.size.width) or 2.8, tf = ((t.size ~= nil and t.size.length) or 6) / 2 + 1,
        tl = (trailer.size ~= nil and trailer.size.length) or 12, depth = depth, span = span }
end

-- ------------------------------------------------------------------------------------------------------------
-- L'entrée : la route qui passe devant, où elle est par rapport au point du champ
-- ------------------------------------------------------------------------------------------------------------
-- route : la route du tracteur vers le point du champ. { x, z (l'entrée : le point du champ ramené sur l'axe de la
-- route), rx, rz (sens du tracteur sur la route), nx, nz (vers l'autre côté de la route), fieldLeft, j, k (dernier
-- tronçon droit de la route : fin, début), side (m du point du champ à la route), entrance } ; nil, raison
function ADHeaderFlow.gateSite(route, current)
    local n = route ~= nil and #route or 0
    if n < 4 then
        return nil, "route trop courte"
    end
    local E = route[n]
    local first = math.max(current or 1, 1)
    local fromEnd = 0
    local j = n - 1
    while j > first + 1 and fromEnd <= ADHeaderFlow.GATE_SPAN do
        fromEnd = fromEnd + dist(route[j + 1], route[j])
        local k, length = j, 0
        while k > first and length < ADHeaderFlow.GATE_BASE do
            length = length + dist(route[k], route[k - 1])
            k = k - 1
        end
        if length >= ADHeaderFlow.GATE_BASE then
            local rx, rz = unit(route[j].x - route[k].x, route[j].z - route[k].z)
            local straight = rx ~= nil
            if straight then
                for i = k + 1, j - 1 do
                    local ox, oz = route[i].x - route[j].x, route[i].z - route[j].z
                    if math.abs(ox * rz - oz * rx) > ADHeaderFlow.GATE_CHORD_DEV then
                        straight = false
                        break
                    end
                end
            end
            if straight then
                local ox, oz = E.x - route[j].x, E.z - route[j].z
                local along = ox * rx + oz * rz
                local left = ox * rz - oz * rx -- GIANTS : la gauche du cap (rx, rz) = (rz, -rx)
                if math.abs(left) >= ADHeaderFlow.GATE_SIDE_MIN then
                    if math.abs(left) > ADHeaderFlow.GATE_SIDE_MAX then
                        return nil, string.format("point du champ à %.0f m de la route", math.abs(left))
                    end
                    if along < -ADHeaderFlow.GATE_BEHIND or along > ADHeaderFlow.GATE_AHEAD then
                        return nil, "l'entrée du champ n'est pas au bord de la route droite"
                    end
                    local s = left > 0 and 1 or -1
                    return { x = route[j].x + rx * along, z = route[j].z + rz * along, rx = rx, rz = rz, nx = -s * rz, nz = s * rx,
                        fieldLeft = s > 0, j = j, k = k, side = math.abs(left), entrance = { x = E.x, z = E.z } }
                end
            end
        end
        j = j - 1
    end
    return nil, "pas de route droite qui passe devant l'entrée du champ"
end

-- m de route droite après l'entrée (le réseau qui continue dans l'axe), comptés depuis l'axe de l'entrée
local function roadBeyond(site, route)
    local q = site.j
    local wp = route[q].id ~= nil and ADGraphManager:getWayPointById(route[q].id) or nil
    while wp == nil and q > site.k do
        q = q - 1
        wp = route[q].id ~= nil and ADGraphManager:getWayPointById(route[q].id) or nil
    end
    if wp == nil then
        return 0
    end
    local cosMax = math.cos(math.rad(ADHeaderFlow.GATE_STRAIGHT))
    local prevId = route[q - 1] ~= nil and route[q - 1].id or nil
    local best = coords(site, wp.x, wp.z)
    local guard = 0
    while guard < 200 and best <= ADHeaderFlow.GATE_BEYOND_MAX do
        guard = guard + 1
        local nextWp, nextDot = nil, cosMax
        for _, id in pairs(wp.out or {}) do
            if id ~= prevId then
                local o = ADGraphManager:getWayPointById(id)
                local dx, dz
                if o ~= nil then
                    dx, dz = unit(o.x - wp.x, o.z - wp.z)
                end
                if dx ~= nil and dx * site.rx + dz * site.rz >= nextDot then
                    nextWp, nextDot = o, dx * site.rx + dz * site.rz
                end
            end
        end
        if nextWp == nil then
            break
        end
        local a, side = coords(site, nextWp.x, nextWp.z)
        if math.abs(side) > ADHeaderFlow.GATE_ROAD_DEV then
            break
        end
        best = math.max(best, a)
        prevId, wp = wp.id, nextWp
    end
    return best
end

-- sur une route de la moissonneuse : index de son dernier point sur la route qui passe devant l'entrée, et son sens
-- (+1 : comme le tracteur, -1 : en face) ; nil : elle n'y passe pas
local function roadIndex(site, route, current)
    local cosA = math.cos(math.rad(ADHeaderFlow.GATE_ROAD_ANGLE))
    local best, sigma = nil, nil
    for k = math.max(current or 1, 1) + 1, #route do
        local p = route[k]
        local a, q = coords(site, p.x, p.z)
        local dx, dz = unit(p.x - route[k - 1].x, p.z - route[k - 1].z)
        local d = dx ~= nil and dx * site.rx + dz * site.rz or 0
        if math.abs(q) <= ADHeaderFlow.GATE_ROAD_SIDE and math.abs(a) <= ADHeaderFlow.GATE_REACH and math.abs(d) >= cosA
            and (sigma == nil or (d > 0) == (sigma > 0)) then
            best, sigma = k, d > 0 and 1 or -1
        elseif best ~= nil then
            break
        end
    end
    if best == nil then
        return nil
    end
    local a = coords(site, route[best].x, route[best].z)
    if sigma * a < -ADHeaderFlow.GATE_AHEAD then
        return nil -- elle quitte la route bien avant l'entrée
    end
    return best, sigma
end

-- ------------------------------------------------------------------------------------------------------------
-- La marche arrière de la moissonneuse : de la route jusque dans l'axe de l'entrée, de l'autre côté
-- ------------------------------------------------------------------------------------------------------------
-- (a0, q0) : où elle est sur la route, sigma : son sens. Points du chemin (du départ vers le fond), m à avancer
-- d'abord si elle n'a pas assez dépassé l'entrée, m de la route où le chemin finit
function ADHeaderFlow.gateBackPath(plan, a0, q0, sigma)
    local rho, step = plan.rho, ADHeaderFlow.GATE_STEP
    local points = {}
    local function add(a, q)
        local x, z = world(plan, a, q)
        points[#points + 1] = { x = x, y = groundY(x, z), z = z, a = a, q = q }
    end
    -- 1) tout droit en arrière jusqu'au début du quart de cercle
    local s = math.max(sigma * a0, rho)
    while s > rho + 0.001 do
        add(sigma * s, q0)
        s = s - step
    end
    -- 2) le quart de cercle : de la route à l'axe de l'entrée
    local count = math.max(2, math.ceil(rho * math.pi / 2 / step))
    for i = 0, count do
        local th = (math.pi / 2) * i / count
        add(sigma * rho * (1 - math.sin(th)), q0 + rho * (1 - math.cos(th)))
    end
    -- 3) tout droit dans l'axe de l'entrée
    local backTo = math.max(plan.depth, q0 + rho) + ADHeaderFlow.GATE_ALIGN_RUN
    local q = q0 + rho + step
    while q <= backTo + 0.001 do
        add(0, q)
        q = q + step
    end
    return points, math.max(rho - sigma * a0, 0), backTo
end

-- le sol sous la moissonneuse le long de ce chemin (elle recule : son avant regarde d'où elle vient) : true ; false,
-- raison (« culture », « eau », « fossé ou talus », « obstacle (nom) »)
local CORNERS = { { -1, 1 }, { 1, 1 }, { -1, 0 }, { 1, 0 }, { -1, -1 }, { 1, -1 }, { 0, -1 } }
function ADHeaderFlow.gateGround(t, plan, points)
    local rig = plan.rig
    local halfW, half = rig.cw / 2 + ADHeaderFlow.GATE_WHEEL_MARGIN, rig.cl / 2
    local every = math.max(1, math.floor(1.5 / ADHeaderFlow.GATE_STEP + 0.5))
    local previous = nil
    local i = 1
    while i <= #points do
        local p = points[i]
        local tx, tz = unit(points[math.min(i + 1, #points)].x - points[math.max(i - 1, 1)].x,
            points[math.min(i + 1, #points)].z - points[math.max(i - 1, 1)].z)
        if tx ~= nil then
            local fx, fz = -tx, -tz
            local lx, lz = fz, -fx
            local row = {}
            for c, corner in ipairs(CORNERS) do
                local x = p.x + lx * halfW * corner[1] + fx * half * corner[2]
                local z = p.z + lz * halfW * corner[1] + fz * half * corner[2]
                local _, q = coords(plan, x, z)
                local h = groundY(x, z)
                if q >= ADHeaderFlow.GATE_ROAD_EDGE then
                    if hasCrop(x, z) then
                        return false, "culture"
                    end
                    if isWater(x, z, h) then
                        return false, "eau"
                    end
                end
                if previous ~= nil and previous[c] ~= nil and math.abs(h - previous[c]) > ADHeaderFlow.MAX_STEP_RISE then
                    return false, "fossé ou talus"
                end
                row[c] = h
            end
            previous = row
            local hit, name = boxHit(t, p.x, p.z, fx, fz, rig.cw / 2 + ADHeaderFlow.GATE_OBSTACLE_MARGIN, half)
            if hit then
                return false, string.format("obstacle (%s)", tostring(name or "?"))
            end
        end
        if i == #points then
            break
        end
        i = math.min(i + every, #points)
    end
    return true, nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Le plan
-- ------------------------------------------------------------------------------------------------------------
-- route prévue du tracteur avec la remorque jusqu'au point du champ (remorque pas encore attelée : depuis le point
-- du réseau le plus proche d'elle)
local function tractorRoute(job, markerId)
    local t, trailer = job.tractor, job.trailer
    if attachedTo(trailer, t) then
        return ADGraphManager:getPathTo(t, markerId)
    end
    local x, _, z = getWorldTranslation(trailer.components[1].node)
    local best, bestD = nil, math.huge
    local all = ADGraphManager.getWayPoints ~= nil and ADGraphManager:getWayPoints() or nil
    for _, wp in pairs(all or {}) do
        if wp.x ~= nil and wp.id ~= nil then
            local d = MathUtil.vector2Length(wp.x - x, wp.z - z)
            if d < bestD then
                best, bestD = wp, d
            end
        end
    end
    if best == nil or ADGraphManager.pathFromTo == nil then
        return ADGraphManager:getPathTo(t, markerId)
    end
    return ADGraphManager:pathFromTo(best.id, markerId)
end

-- la moissonneuse est déjà garée en face de l'entrée, le nez vers le champ
local function inPlace(plan, combine)
    local a, q, _, cosField = poseOf(plan, combine)
    return math.abs(a) <= ADHeaderFlow.GATE_PLACE_ALONG and q <= ADHeaderFlow.GATE_PLACE_MAX
        and q - plan.rig.dj >= plan.rig.tw / 2 - plan.offset + ADHeaderFlow.GATE_PASS
        and cosField >= math.cos(math.rad(ADHeaderFlow.GATE_POSE_ANGLE))
end

-- le bord de la route côté champ, là où le tracteur et la remorque s'arrêtent décalés : libre ?
local function vergeFree(site, rig, shift, ahead)
    local side = -(rig.tw / 2 + shift + ADHeaderFlow.GATE_VERGE)
    local a = -rig.tl - 2
    while a <= ahead do
        local x, z = world(site, a, side)
        local h = groundY(x, z)
        local cx, cz = world(site, a, 0)
        if hasCrop(x, z) or isWater(x, z, h) or math.abs(h - groundY(cx, cz)) > ADHeaderFlow.MAX_STEP_RISE then
            return false
        end
        a = a + 2
    end
    return true
end

-- plan de la manœuvre, fait au départ de la moissonneuse ; nil, raison
function ADHeaderFlow.gatePlan(job)
    local t, combine, header = job.tractor, job.combine, job.header
    local marker = ADGraphManager:getMapMarkerById(job.fieldId)
    if marker == nil or marker.id == nil then
        return nil, "pas de point du champ"
    end
    if not ADHeaderFlow.ENTRY or ADHeaderFlow.entryCorridor == nil or ADHeaderFlow.roadSideFree == nil then
        return nil, "entrée directe dans le champ coupée"
    end
    local rig, why = gateRig(job)
    if rig == nil then
        return nil, why
    end
    -- 1) la route du tracteur passe devant l'entrée
    local route = tractorRoute(job, marker.id)
    if route == nil or #route < 4 then
        return nil, "route du tracteur inconnue"
    end
    local plan
    plan, why = ADHeaderFlow.gateSite(route, 1)
    if plan == nil then
        return nil, why
    end
    plan.rig = rig
    plan.tractorLength = routeLength(route, 1)
    -- 2) par où passe le tracteur : remorque dans le sens de la route, le cadre regarde l'autre côté (pas le champ)
    local lx, lz = plan.rz, -plan.rx
    local fx, fz = unit(rig.fdx * lx + rig.fdz * plan.rx, rig.fdx * lz + rig.fdz * plan.rz)
    if fx == nil or fx * plan.nx + fz * plan.nz < math.cos(math.rad(ADHeaderFlow.GATE_FACE)) then
        return nil, "le cadre de la barre regarderait le champ : il faudrait arriver par l'autre bout de la route"
    end
    -- 3) la route continue tout droit après l'entrée : la place du tracteur arrêté
    local ahead = rig.tl / 2 - rig.hz + 5 -- m du cadre au point suivi du tracteur, à peu près (remorque pas encore attelée)
    local beyond = roadBeyond(plan, route)
    local need = ahead + rig.tf + 2
    -- 4) décalage vers le champ, où la moissonneuse attend
    plan.offset = (ADHeaderFlow.GATE_OFFSET > 0 and vergeFree(plan, rig, ADHeaderFlow.GATE_OFFSET, ahead + rig.tf)) and ADHeaderFlow.GATE_OFFSET or 0
    plan.frameQ = math.abs(rig.hx) - plan.offset
    plan.depth = rig.dj + math.max(plan.frameQ + ADHeaderFlow.GATE_GAP, rig.tw / 2 - plan.offset + ADHeaderFlow.GATE_PASS + 0.5)
    plan.rho = rig.rc * ADHeaderFlow.GATE_RADIUS
    plan.hold = plan.rho + ADHeaderFlow.GATE_PAST + rig.cl / 2 + ADHeaderFlow.GATE_HOLD_GAP + rig.tf
    -- 5) le champ droit devant le cadre, le couloir praticable sur la largeur de la barre
    local frameX, frameZ = world(plan, 0, plan.frameQ)
    local corridor
    corridor, why = ADHeaderFlow.entryCorridor(t, job, header, frameX, frameZ, -plan.nx, -plan.nz, 0, ADHeaderFlow.ENTRY_RANGE,
        ADHeaderFlow.PREDICT_MARGIN, false)
    if corridor == nil then
        return nil, string.format("pas d'entrée directe depuis la route (%s)", tostring(why))
    end
    -- 6) en face de l'entrée : là où la moissonneuse attend et recule avec la barre
    local ok
    ok, why = ADHeaderFlow.roadSideFree(t, job, { x = frameX, y = groundY(frameX, frameZ), z = frameZ, dirX = plan.nx, dirZ = plan.nz }, true)
    if not ok then
        return nil, string.format("en face de l'entrée, pas la place de la moissonneuse (%s)", tostring(why))
    end
    -- 7) la moissonneuse : déjà en face, ou sa route passe par là et elle a la place de se ranger
    if inPlace(plan, combine) then
        plan.inPlace = true
    else
        local own = ADGraphManager:getPathTo(combine, marker.id)
        local k, sigma = nil, nil
        if own ~= nil and #own >= 2 then
            k, sigma = roadIndex(plan, own, 1)
        end
        if k == nil then
            return nil, "la moissonneuse n'arrive pas par la route qui passe devant l'entrée"
        end
        local _, q0 = coords(plan, own[k].x, own[k].z)
        local points = ADHeaderFlow.gateBackPath(plan, sigma * (plan.rho + ADHeaderFlow.GATE_PAST), q0, sigma)
        ok, why = ADHeaderFlow.gateGround(t, plan, points)
        if not ok then
            return nil, string.format("en face de l'entrée, pas la place de se ranger en marche arrière (%s)", tostring(why))
        end
        if sigma > 0 then
            need = math.max(need, plan.rho + ADHeaderFlow.GATE_PAST + rig.cl / 2 + 1)
        end
        plan.sigma = sigma
        plan.ownLength = routeLength(own, 1)
    end
    if beyond < need then
        return nil, string.format("la route ne continue pas assez loin après l'entrée (%.0f m, il en faut %.0f)", beyond, need)
    end
    plan.beyond = beyond
    return plan
end

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse : elle part devant, se range en face de l'entrée, attend la barre
-- ------------------------------------------------------------------------------------------------------------
local function waitTrailer(mode, job)
    ADHeaderFlow.startWait(mode, "waitTrailer", function() return job.trailerReady or job.cancelled end)
end

-- au départ (au lieu d'attendre que la remorque soit partie devant) : true = la manœuvre est lancée
function ADHeaderFlow.gateStart(mode, job)
    local v = mode.vehicle
    local plan, why = ADHeaderFlow.gatePlan(job)
    if plan == nil then
        log("%s : pas de barre amenée devant elle en face de l'entrée (%s)", nameOf(v), tostring(why))
        return false
    end
    local marker = ADGraphManager:getMapMarkerById(job.fieldId)
    job.gate = plan
    job.gateReady = nil
    job.fieldSpot = { x = plan.entrance.x, z = plan.entrance.z } -- les autres endroits sont cherchés autour de l'entrée
    AutonomousMode.message(v, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerGate", nameOf(job.tractor))
    if plan.inPlace then
        job.gateReady = true
        log("%s : déjà en face de l'entrée du champ (%.0f, %.0f), le nez vers le champ : elle attend là, « %s » arrêtera la barre devant elle",
            nameOf(v), plan.x, plan.z, nameOf(job.tractor))
        waitTrailer(mode, job)
        return true
    end
    log("%s : la route passe devant l'entrée du champ (%.0f, %.0f), champ à %s : elle part devant, se range en face de l'entrée (à %.1f m de la route, marche arrière de %.1f m de rayon), « %s » arrêtera la barre devant elle%s",
        nameOf(v), plan.x, plan.z, plan.fieldLeft and "gauche" or "droite", plan.depth, plan.rho, nameOf(job.tractor),
        plan.offset > 0 and string.format(", décalé de %.1f m vers le champ", plan.offset) or "")
    mode.headerStage = "gateDrive"
    mode.gateCut = nil
    mode.gatePlaced = nil
    mode.driveToDestinationTask = DriveToDestinationTask:new(v, marker.id)
    if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_fetch", label(job.header)) end
    v.ad.taskModule:addTask(mode.driveToDestinationTask)
    return true
end

if ADHeaderFlow.startWaitLeave ~= nil then
    local baseWaitLeave = ADHeaderFlow.startWaitLeave
    function ADHeaderFlow.startWaitLeave(mode, job)
        if ADHeaderFlow.GATE and job ~= nil and job.phase == "deliver" and ADHeaderGateBackTask ~= nil and ADHeaderGateInTask ~= nil then
            local ok, started = FarmPilotCall(ADHeaderFlow.gateStart, mode, job)
            if not ok then
                log("ERREUR barre amenée devant la moissonneuse : %s", tostring(started))
                job.gate = nil
            elseif started then
                return
            end
        end
        return baseWaitLeave(mode, job)
    end
end

-- sa route est coupée sur la route devant l'entrée et prolongée tout droit jusqu'au départ de sa marche arrière ;
-- true ; false, raison
function ADHeaderFlow.gateCombineRoute(plan, wayPoints, current)
    local k, sigma = roadIndex(plan, wayPoints, current)
    if k == nil then
        return false, "sa route ne passe pas devant l'entrée"
    end
    local target = plan.rho + ADHeaderFlow.GATE_PAST
    local keep = nil
    for i = k, math.max(current or 1, 1) + 1, -1 do
        local a = coords(plan, wayPoints[i].x, wayPoints[i].z)
        if sigma * a <= target - 2 then
            keep = i
            break
        end
    end
    if keep == nil then
        return false, "déjà trop près de l'entrée"
    end
    for i = #wayPoints, keep + 1, -1 do
        wayPoints[i] = nil
    end
    local a0, q0 = coords(plan, wayPoints[keep].x, wayPoints[keep].z)
    local function add(s)
        local x, z = world(plan, sigma * s, q0)
        wayPoints[#wayPoints + 1] = { x = x, y = groundY(x, z), z = z, isPathFinderPoint = true }
    end
    local s = sigma * a0 + ADHeaderFlow.GATE_ROUTE_STEP
    while s < target - 2 do
        add(s)
        s = s + ADHeaderFlow.GATE_ROUTE_STEP
    end
    add(target)
    plan.sigma = sigma
    return true, sigma
end

-- à chaque image pendant qu'elle va à l'entrée : route connue = coupée devant l'entrée
function ADHeaderFlow.gateMonitor(mode, job, dt)
    local v = mode.vehicle
    local task = mode.driveToDestinationTask
    if task == nil or v.ad.taskModule:getActiveTask() ~= task then
        return
    end
    if job.cancelled then
        task:finished()
        return
    end
    if mode.gateCut or task.routeIsPartial or (task.state ~= nil and task.state ~= DriveToDestinationTask.STATE_DRIVING) then
        return
    end
    local dpm = v.ad.drivePathModule
    local wayPoints = dpm.wayPoints
    if wayPoints == nil or #wayPoints < 2 then
        return
    end
    mode.gateCut = true
    local plan = job.gate
    local current = dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1
    local ok, done, why = false, false, "plus de barre amenée devant elle"
    if plan ~= nil then
        ok, done, why = FarmPilotCall(ADHeaderFlow.gateCombineRoute, plan, wayPoints, current)
    end
    if ok and done then
        mode.gatePlaced = true
        log("%s : s'arrêtera sur la route %.0f m après l'entrée du champ, puis se rangera en face d'elle en marche arrière", nameOf(v),
            plan.rho + ADHeaderFlow.GATE_PAST)
        return
    end
    log("%s : ne se range pas en face de l'entrée (%s), suit la remorque comme d'habitude", nameOf(v), tostring(ok and why or done))
    job.gate = nil
    job.gateReady = nil
    mode.headerStage = "follow"
    mode.followCut = nil
    mode.followHold = nil
end

if ADHeaderFlow.monitor ~= nil then
    local baseMonitor = ADHeaderFlow.monitor
    function ADHeaderFlow.monitor(mode, dt)
        local v = mode.vehicle
        local job = v.ad.fpHeaderJob
        if mode.headerStage == "gateDrive" and job ~= nil and job.combine == v then
            ADHeaderFlow.gateMonitor(mode, job, dt)
            return
        end
        return baseMonitor(mode, dt)
    end
end

local BACK_REASONS = { badStart = "pas dans l'axe de la route au départ", ground = "le sol n'est pas libre en face de l'entrée",
    blocked = "quelque chose derrière elle", timeout = "pas fini à temps", offGround = "un coin dans une culture", noReverse = "pas de marche arrière",
    badPose = "pas assez droite en face de l'entrée" }

if ADHeaderFlow.combineStage ~= nil then
    local baseCombineStage = ADHeaderFlow.combineStage
    function ADHeaderFlow.combineStage(mode, job, stage, result)
        local v = mode.vehicle
        if stage == "gateDrive" then
            mode.driveToDestinationTask = nil
            local placed = mode.gatePlaced
            mode.gatePlaced = nil
            mode.gateCut = nil
            if job.cancelled or v.ad.isStoppingWithError then
                local why = job.cancelled and "la remorque ne vient plus" or "pas de route vers le champ"
                job.cancelled = true
                log("%s : %s, arrêt", nameOf(v), why)
                ADHeaderFlow.stopHere(mode, "AD_autonomous_headerTimeout")
                return
            end
            local plan = job.gate
            if plan == nil or not placed or ADHeaderGateBackTask == nil then
                job.gate = nil
                log("%s : arrêtée avant l'entrée du champ, attend que la remorque soit en place", nameOf(v))
                waitTrailer(mode, job)
                return
            end
            job.gateArrived = true
            mode.headerStage = "gateBack"
            mode.headerTask = ADHeaderGateBackTask:new(v, plan, job)
            v.ad.taskModule:addTask(mode.headerTask)
            return
        end
        if stage == "gateBack" then
            local plan = job.gate
            if job.cancelled or v.ad.isStoppingWithError then
                job.cancelled = true
                ADHeaderFlow.stopHere(mode, "AD_autonomous_headerTimeout")
                return
            end
            if result == "ok" and plan ~= nil then
                local a, q, _, cosField = poseOf(plan, v)
                job.gateReady = true
                log("%s : en place en face de l'entrée du champ (à %.1f m de la route, %.1f m de son axe, à %.0f° de lui), attend la barre", nameOf(v), q, math.abs(a),
                    math.deg(math.acos(math.max(-1, math.min(1, cosField)))))
            else
                log("%s : pas en place en face de l'entrée (%s), attend là que la remorque soit en place", nameOf(v), tostring(BACK_REASONS[result] or result))
                job.gate = nil
                job.gateReady = nil
            end
            waitTrailer(mode, job)
            return
        end
        return baseCombineStage(mode, job, stage, result)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Tracteur : il part derrière la moissonneuse, attend avant l'entrée, arrête le cadre devant elle
-- ------------------------------------------------------------------------------------------------------------
-- la moissonneuse est devant lui sur la route (ou déjà à l'entrée)
local function combineAhead(job)
    local plan = job.gate
    if plan == nil or job.gateReady or job.gateArrived or job.cancelled then
        return true
    end
    local c = job.combine
    local cm = c.ad ~= nil and c.ad.modes ~= nil and c.ad.modes[AutoDrive.MODE_AUTONOMOUS] or nil
    if cm == nil or cm.headerStage ~= "gateDrive" then
        return true -- elle ne va plus à l'entrée : la suite habituelle
    end
    if not cm.gateCut then
        return false -- sa route n'est pas encore connue
    end
    local dpm = c.ad.drivePathModule
    local wayPoints = dpm ~= nil and dpm.wayPoints or nil
    if wayPoints == nil or #wayPoints < 2 then
        return false
    end
    local current = dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1
    return routeLength(wayPoints, current) + ADHeaderFlow.GATE_LEAD <= plan.tractorLength
end

if ADHeaderFlow.tractorStart ~= nil then
    local baseTractorStart = ADHeaderFlow.tractorStart
    function ADHeaderFlow.tractorStart(mode, job)
        local t = mode.vehicle
        if ADHeaderFlow.GATE and job.gate ~= nil and job.phase == "deliver" and not job.cancelled and not job.gateGo
            and attachedTo(job.trailer, t) and not combineAhead(job) then
            local sm = t.ad.stateModule
            if not sm:isActive() then
                t:startAutoDrive()
                if not sm:isActive() then
                    return true
                end
            end
            mode:reset()
            log("%s : remorque attelée, attend que « %s » soit devant lui sur la route (elle se range en face de l'entrée avant qu'il arrive)", nameOf(t),
                nameOf(job.combine))
            ADHeaderFlow.startWait(mode, "gateLeave", function() return combineAhead(job) end)
            return true
        end
        return baseTractorStart(mode, job)
    end
end

-- sur la route réelle du tracteur : index du point où il attend avant l'entrée ; nil, raison
function ADHeaderFlow.gateTractorRoute(plan, wayPoints, current)
    local site, why = ADHeaderFlow.gateSite(wayPoints, current)
    if site == nil then
        return nil, why
    end
    if MathUtil.vector2Length(site.x - plan.x, site.z - plan.z) > 3 or site.rx * plan.rx + site.rz * plan.rz < 0.95 then
        return nil, "il n'arrive pas par le côté prévu"
    end
    for i = site.j, math.max(current or 1, 1) + 1, -1 do
        local a, q = coords(plan, wayPoints[i].x, wayPoints[i].z)
        if -a >= plan.hold then
            if math.abs(q) > ADHeaderFlow.GATE_ROAD_SIDE then
                return nil, "route pas droite avant l'entrée"
            end
            return i
        end
    end
    return nil, "déjà trop près de l'entrée"
end

if ADHeaderFlow.checkRouteStop ~= nil then
    local baseCheckRouteStop = ADHeaderFlow.checkRouteStop
    function ADHeaderFlow.checkRouteStop(mode, job)
        local plan = job.gate
        if plan == nil or mode.headerStopChecked or job.phase ~= "deliver" then
            return baseCheckRouteStop(mode, job)
        end
        local t = mode.vehicle
        local task = mode.driveToDestinationTask
        if task == nil or t.ad.taskModule:getActiveTask() ~= task or task.routeIsPartial
            or (task.state ~= nil and task.state ~= DriveToDestinationTask.STATE_DRIVING) then
            return
        end
        local dpm = t.ad.drivePathModule
        local wayPoints = dpm.wayPoints
        if wayPoints == nil or #wayPoints < 2 then
            return
        end
        local current = dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1
        local ok, index, why = FarmPilotCall(ADHeaderFlow.gateTractorRoute, plan, wayPoints, current)
        if ok and index ~= nil then
            for k = #wayPoints, index + 1, -1 do
                wayPoints[k] = nil
            end
            mode.headerStopChecked = true
            mode.headerGate = plan
            local a = coords(plan, wayPoints[index].x, wayPoints[index].z)
            log("%s : la barre sera prise devant l'entrée du champ, par la moissonneuse rangée en face : il s'arrête %.0f m avant l'entrée tant qu'elle n'est pas en place",
                nameOf(t), -a)
            return
        end
        log("%s : pas de barre amenée devant la moissonneuse (%s), la suite habituelle", nameOf(t), tostring(ok and why or index))
        job.gate = nil
        return baseCheckRouteStop(mode, job)
    end
end

-- où le tracteur s'arrête : le cadre de la barre dans l'axe de la moissonneuse, là où elle est vraiment.
-- { cx, cz (moissonneuse), wx, wz (le long de la route, perpendiculaire à son axe), offset } ; nil, raison
function ADHeaderFlow.gateStop(plan, t, job)
    local combine, rig = job.combine, plan.rig
    local a, q, _, cosField, cx, cz, hx, hz = poseOf(plan, combine)
    if cosField < math.cos(math.rad(ADHeaderFlow.GATE_POSE_ANGLE)) then
        return nil, string.format("la moissonneuse est à %.0f° de l'axe de l'entrée", math.deg(math.acos(math.max(-1, math.min(1, cosField)))))
    end
    if math.abs(a) > ADHeaderFlow.GATE_PLACE_ALONG + 2 then
        return nil, string.format("la moissonneuse est à %.0f m de l'axe de l'entrée", math.abs(a))
    end
    local _, jointQ = coords(plan, cx + hx * rig.dj, cz + hz * rig.dj)
    if jointQ < rig.tw / 2 - plan.offset + ADHeaderFlow.GATE_PASS - 0.3 then
        return nil, string.format("le nez de la moissonneuse est trop près de la route (%.1f m de son axe)", jointQ)
    end
    if jointQ - plan.frameQ > ADHeaderFlow.GATE_GAP_MAX then
        return nil, string.format("la moissonneuse est trop loin de la route (%.0f m)", q)
    end
    -- place prévue du cadre : sur l'axe de la moissonneuse, à plan.frameQ de la route
    local toRoad = -(hx * plan.nx + hz * plan.nz)
    local g = (q - plan.frameQ) / toRoad
    local fx, fz = cx + hx * g, cz + hz * g
    local corridor, why = ADHeaderFlow.entryCorridor(t, job, job.header, fx, fz, hx, hz, 0, ADHeaderFlow.ENTRY_RANGE, 0, false)
    if corridor == nil then
        return nil, string.format("pas d'entrée directe dans l'axe de la moissonneuse (%s)", tostring(why))
    end
    local wx, wz = unit(plan.rx - (plan.rx * hx + plan.rz * hz) * hx, plan.rz - (plan.rx * hx + plan.rz * hz) * hz)
    if wx == nil then
        return nil, "axe de la moissonneuse inconnu"
    end
    return { cx = cx, cz = cz, wx = wx, wz = wz, offset = plan.offset, gap = jointQ - plan.frameQ }
end

-- au bout de sa route (arrêt avant l'entrée) : true = il attend la moissonneuse puis avance jusque devant elle
if ADHeaderFlow.startBackIn ~= nil then
    local baseStartBackIn = ADHeaderFlow.startBackIn
    function ADHeaderFlow.startBackIn(mode, job)
        local plan = mode.headerGate
        mode.headerGate = nil
        if plan == nil or job.phase ~= "deliver" or ADHeaderGateInTask == nil then
            return baseStartBackIn(mode, job)
        end
        local t = mode.vehicle
        mode.headerBackIn = nil
        mode.headerRoadBack = nil
        mode.headerStage = "gateIn"
        mode.headerTask = ADHeaderGateInTask:new(t, job, plan)
        t.ad.taskModule:addTask(mode.headerTask)
        AutonomousMode.message(t, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerGateIn", nameOf(job.combine))
        return true
    end
end

local IN_REASONS = { cancelled = "la moissonneuse n'est pas en place en face de l'entrée", blocked = "quelque chose devant lui", timeout = "pas fini à temps",
    noFrame = "cadre de la barre introuvable" }

-- le tracteur a fini (result : voir Tasks/HeaderGateTask.lua)
function ADHeaderFlow.gateInDone(mode, job, result)
    local t = mode.vehicle
    if t.ad.isStoppingWithError then
        job.cancelled = true
        job.gate = nil
        ADHeaderFlow.stopHere(mode, nil)
        return
    end
    if result == "ok" then
        local hitch = ADAutonomousManager.frontHitch(job.combine, job.header, true)
        local side, angle = 0, 0
        if hitch ~= nil then
            local x, _, z = getWorldTranslation(job.combine.components[1].node)
            local fx, _, fz = localDirectionToWorld(job.combine.components[1].node, 0, 0, 1)
            fx, fz = unit(fx, fz)
            side = math.abs((x - hitch.x) * hitch.dirZ - (z - hitch.z) * hitch.dirX)
            angle = fx ~= nil and math.deg(math.acos(math.max(-1, math.min(1, -(fx * hitch.dirX + fz * hitch.dirZ))))) or 0
        end
        job.gatePickup = true
        job.sideBlocked = nil
        log("%s : barre arrêtée devant la moissonneuse (cadre à %.1f m de son axe, à %.0f°), elle la prend droit devant", nameOf(t), side, angle)
        ADHeaderFlow.tractorWait(mode, job)
        return
    end
    job.gate = nil
    job.gatePickup = nil
    log("%s : barre pas amenée devant la moissonneuse (%s), la suite habituelle", nameOf(t), tostring(IN_REASONS[result] or result))
    if ADHeaderFlow.onArrival(mode, job) then
        return
    end
    ADHeaderFlow.tractorWait(mode, job)
end

if ADHeaderFlow.tractorStage ~= nil then
    local baseTractorStage = ADHeaderFlow.tractorStage
    function ADHeaderFlow.tractorStage(mode, job, stage, result)
        if stage == "gateLeave" then
            local t = mode.vehicle
            job.gateGo = true
            if job.cancelled then
                ADHeaderFlow.stopHere(mode, nil)
                return
            end
            if result ~= "ok" then
                log("%s : la moissonneuse n'est pas passée devant lui (%s), part quand même, la suite habituelle", nameOf(t), tostring(result))
                job.gate = nil
            end
            ADHeaderFlow.tractorStart(mode, job)
            return
        end
        if stage == "gateIn" then
            ADHeaderFlow.gateInDone(mode, job, result)
            return
        end
        return baseTractorStage(mode, job, stage, result)
    end
end

-- la remorque va ailleurs : plus de barre amenée devant la moissonneuse
if ADHeaderFlow.moveOn ~= nil then
    local baseMoveOn = ADHeaderFlow.moveOn
    function ADHeaderFlow.moveOn(mode, job, why, plain)
        job.gate = nil
        job.gatePickup = nil
        return baseMoveOn(mode, job, why, plain)
    end
end

if AutonomousMode ~= nil and AutonomousMode.reset ~= nil then
    local baseReset = AutonomousMode.reset
    function AutonomousMode:reset()
        baseReset(self)
        self.headerGate = nil
        self.gateCut = nil
        self.gatePlaced = nil
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse : la barre est devant elle
-- ------------------------------------------------------------------------------------------------------------
if ADFrontFlow ~= nil and ADFrontFlow.fetchRoutePoint ~= nil then
    -- pas de détour par le point du réseau « devant l'outil »
    local baseRoutePoint = ADFrontFlow.fetchRoutePoint
    function ADFrontFlow.fetchRoutePoint(vehicle, tool)
        local job = vehicle.ad ~= nil and vehicle.ad.fpHeaderJob or nil
        if job ~= nil and job.gatePickup and job.combine == vehicle and job.header == tool then
            return nil
        end
        return baseRoutePoint(vehicle, tool)
    end
end

if ADFrontFlow ~= nil and ADFrontFlow.afterFetch ~= nil then
    -- barre prise : la suite est l'entrée directe (petit recul, le tracteur dégage, tout droit dans le champ)
    local baseAfterFetch = ADFrontFlow.afterFetch
    function ADFrontFlow.afterFetch(mode, tool)
        local v = mode.vehicle
        local job = v.ad.fpHeaderJob
        if job ~= nil and job.combine == v and job.header == tool and (job.gate ~= nil or job.gatePickup) then
            if job.gatePickup then
                log("%s : « %s » attelée en face de l'entrée du champ", nameOf(v), label(tool))
            end
            job.gate = nil
            job.gatePickup = nil
            job.gateReady = nil
        end
        return baseAfterFetch(mode, tool)
    end
end
