-- ============================================================================================================
-- FarmPilot : AutonomousHeaderBackIn.lua
-- Mode Autonome, moissonneuse équipée seule : la remorque porte-barre est RECULÉE dans l'entrée du champ, en biais,
-- pour que la moissonneuse arrive par le chemin et prenne sa barre sans aller plus loin.
--
-- Règle (12/11) :
-- - Quand : au départ, côté du cadre de la barre encombré au bout de la route du champ, et rien de dégagé à moins
--   de BACKIN_PREFER m avant (culture des deux côtés du chemin, étang...). Il faut : le champ d'un côté du chemin et
--   le cadre de la barre de l'autre côté de la remorque ; le chemin qui continue tout droit après l'entrée ; la
--   moissonneuse qui arrive par le même chemin, dans le même sens.
-- - Le tracteur ne tourne pas dans l'entrée : il la dépasse sur le chemin, s'arrête, puis recule en poussant la
--   remorque dans le champ, à BACKIN_ANGLE ° du chemin (Tasks/HeaderBackInTask.lua).
-- - Où : le cadre de la barre regarde le chemin, juste assez loin dans le champ pour que la moissonneuse, qui roule
--   au milieu du chemin, n'ait qu'un virage de (90 - BACKIN_ANGLE) ° puis une ligne droite jusqu'au cadre. Le chemin
--   doit être droit BACKIN_ALIGN m avant ce virage (la moissonneuse y est alignée) : quand le chemin est court avant
--   le point du champ, la remorque entre dans le champ un peu plus loin que ce point.
-- - Remorque en place : la moissonneuse vient par le réseau, lâche la route avant ce virage et suit une courbe
--   calculée jusque devant le cadre (pas de recherche de chemin). Pas de courbe d'où elle est : recherche de chemin,
--   comme avant.
-- - Marche arrière ratée (bloquée, trop de travers, pas finie), ou cadre pas tourné vers le chemin à la fin :
--   endroit suivant, comme un endroit encombré (AutonomousHeaderSpot.lua : moveOn).
-- - La culture sous la remorque et devant le cadre est celle du champ à récolter ; de l'autre côté du chemin, rien
--   ne roule dans la culture : le tracteur s'arrête décalé de BACKIN_BIAS m vers le champ (son nez passe en face
--   pendant la marche arrière), et BACKIN_OTHER_MIN m doivent y être dégagés.
-- - Pas de marche arrière si un obstacle (arbre, clôture, bâtiment, véhicule) est là où la remorque recule et
--   finit, ou devant le cadre.
-- - La remorque finit un peu moins tournée que l'axe de la marche arrière (BACKIN_AXIS_EXTRA). La courbe de la
--   moissonneuse est calculée sur le vrai cadre : si la place manque pour arriver dans son axe, elle arrive jusqu'à
--   10° moins tournée (BACKIN_SLANTS) ou plus près (BACKIN_FINAL_MIN) et finit de s'aligner en avançant dessus.
-- - La moissonneuse lâche sa route dès que cette courbe existe d'où elle est (au plus tôt BACKIN_LEAD m avant le
--   virage, recalculée toutes les BACKIN_RETRY ms), au plus tard au début du virage.
--
-- Règle (16/11, champ 52 : muret en pierre bas le long d'un chemin à une voie, le MF décalé de 1,5 m vers le champ
-- s'est collé au muret et y est resté) : les objets fixes (muret, clôture, poteau, arbre, bâtiment) sont vus AVANT,
-- pas seulement la culture (fixedHit : le masque des objets du capteur avant, qui voit un muret bas) :
-- - Bande où le tracteur et la remorque roulent décalés de BACKIN_BIAS m après l'entrée : un objet fixe dessus
--   (largeur de l'attelage plus BACKIN_BAND_MARGIN m de chaque côté), pas de décalage, le tracteur reste au milieu
--   du chemin. Un objet fixe au milieu du chemin aussi : pas de marche arrière.
-- - Entre le chemin et la place de la remorque reculée (la caisse de la remorque pendant la marche arrière, aux
--   BACKIN_SWEEP de son trajet, et l'axe de la marche arrière) : un objet fixe là, le champ est FERMÉ (muret,
--   clôture entre le chemin et le champ) : pas de marche arrière dans le champ, la barre est reculée en travers du
--   chemin quand c'est possible (AutonomousHeaderCross.lua : crossTry), sinon l'endroit suivant.
-- - De l'autre côté du chemin, là où le nez du tracteur passe pendant la marche arrière : pas d'objet fixe non plus.
-- - Au début de la marche arrière le nez du tracteur part d'abord vers le champ (jusqu'à BACKIN_COUNTER_SWING m
--   au-delà de sa largeur, mesuré hors jeu) : un objet fixe là (muret qui longe le chemin jusqu'à l'arrêt), le
--   champ est fermé aussi.
-- - Le cadre de la barre du côté du champ : pas de marche arrière dans le champ non plus, la barre en travers du
--   chemin est essayée (c'est l'attelage qui convient pour elle).
-- - Marche arrière bloquée BACKIN_STUCK ms sans avancer (objet fixe que le capteur arrière ne voit pas) : arrêt
--   (« stuck »), endroit suivant (Tasks/HeaderBackInTask.lua).
-- - La même marche arrière sert à la barre en travers du chemin (plan.cross : textes et contrôles de la courbe de la
--   moissonneuse, culture des deux côtés).
--
-- Branché par : Modes/AutonomousHeaderSpot.lua (checkRouteStop : backInTry ; moveOn), Modes/AutonomousHeader.lua
-- (tractorStage « toField » : startBackIn, « backIn » : backInDone ; goToHeader et monitor « toHeader » :
-- backInBefore, backInHandover ; startFetchAttach : backInCurve), Tasks/FetchToolTask.lua (chemin tout prêt :
-- presetPath), Modes/AutonomousHeaderCross.lua (backInRig, backInLaneInfo, backInStop, backInTrainHalf, fixedHit,
-- backInBandHit, backInSweepHit, backInBoxHit, backInStraightBefore, backInLane, backInPath, backInRoute ; crossTry
-- appelé ici). Chargé par register.lua après AutonomousHeaderFollow.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.BACKIN = true               -- false : jamais de marche arrière dans l'entrée du champ
ADHeaderFlow.BACKIN_ANGLE = 55           -- ° entre la remorque reculée et le chemin
ADHeaderFlow.BACKIN_START = 9            -- m : au départ, l'essieu de la remorque a dépassé d'autant le point où elle quittera le chemin
ADHeaderFlow.BACKIN_LOOK = 8             -- m : point visé en reculant, sur l'axe, devant l'essieu de la remorque
ADHeaderFlow.BACKIN_SPEED = 5            -- km/h
ADHeaderFlow.BACKIN_MAX_HITCH = 65       -- ° entre tracteur et remorque : au-delà, arrêt
ADHeaderFlow.BACKIN_TIMEOUT = 90000      -- ms de marche arrière au plus
ADHeaderFlow.BACKIN_BLOCKED = 10000      -- ms avec quelque chose derrière : arrêt
ADHeaderFlow.BACKIN_PREFER = 40          -- m : un endroit dégagé à moins de ça du bout de la route passe avant
ADHeaderFlow.BACKIN_JUNCTION_SPAN = 40   -- m du bout de la route : le chemin doit continuer tout droit depuis là
ADHeaderFlow.BACKIN_STRAIGHT = 12        -- ° : chemin droit
ADHeaderFlow.BACKIN_LANE_DEV = 1.5         -- m d'écart à la ligne du chemin, au plus
ADHeaderFlow.BACKIN_LANE_MAX = 120       -- m de chemin regardés après l'entrée
ADHeaderFlow.BACKIN_EDGE_SCAN = 12       -- m : bord du champ cherché jusque-là du milieu du chemin
ADHeaderFlow.BACKIN_EDGE_DEFAULT = 5     -- m : bord pas trouvé
ADHeaderFlow.BACKIN_EDGE_IN = 0.5        -- m : le cadre de la barre est au moins ça après le bord du champ
ADHeaderFlow.BACKIN_OTHER_EXTRA = 1.0    -- (17/11) m de plus en face (le nez passe plus loin que BACKIN_OTHER_MIN, mesuré hors jeu)
ADHeaderFlow.BACKIN_OTHER_MIN = 4.5      -- m dégagés de l'autre côté du chemin (le tracteur y passe le nez)
ADHeaderFlow.BACKIN_BIAS = 1.5           -- m : le tracteur s'arrête décalé d'autant du milieu du chemin, vers le champ (son nez déborde moins en face)
ADHeaderFlow.BACKIN_BIAS_EDGE = 0.5      -- m gardés entre la remorque décalée et la culture du champ
ADHeaderFlow.BACKIN_BIAS_WIDE = true     -- (17/11) décalage jusqu'à la culture quand 1,5 m ne passe pas (false : comme avant)
ADHeaderFlow.BACKIN_BIAS_BEFORE = 15     -- (17/11) m avant l'entrée où le décalage large peut commencer
ADHeaderFlow.BACKIN_BIAS_SLOPE = 5      -- (17/11) m de chemin par m de décalage, au moins
ADHeaderFlow.BACKIN_BIAS_SHIFT = 10      -- m de chemin pour se décaler
ADHeaderFlow.BACKIN_BIAS_FROM = 3        -- m après l'entrée : pas de décalage avant
ADHeaderFlow.BACKIN_ROUTE_STEP = 5       -- m entre les points de la route après l'entrée
ADHeaderFlow.BACKIN_LANE_FIT = 45        -- m après l'entrée : le sens du chemin est pris sur cette longueur
ADHeaderFlow.BACKIN_PAST = 2             -- m : le cadre est au moins ça après le point du champ
ADHeaderFlow.BACKIN_SHIFT_MAX = 30       -- m après le point du champ, au plus
ADHeaderFlow.BACKIN_SLIDE_STEP = 5      -- m entre deux endroits essayés plus loin le long du champ (17/11)
ADHeaderFlow.BACKIN_SLIDE_MAX = 60       -- m plus loin au plus (0 : seulement juste après l'entrée)
ADHeaderFlow.BACKIN_ALIGN = 8            -- m de chemin droit avant le virage de la moissonneuse
ADHeaderFlow.BACKIN_FINAL = 3            -- m entre l'attelage de la moissonneuse et le cadre, au bout de la courbe
ADHeaderFlow.BACKIN_LEAD = 6             -- m : la moissonneuse lâche la route ça avant le début du virage, dès qu'elle a sa courbe
ADHeaderFlow.BACKIN_RETRY = 250          -- ms entre deux calculs de courbe tant qu'elle n'en a pas
ADHeaderFlow.BACKIN_MAX_TURN = 50        -- ° au plus entre le chemin et l'axe d'arrivée sur le cadre
ADHeaderFlow.BACKIN_MAX_REACH = 18       -- m de l'essieu sur l'axe, au plus
ADHeaderFlow.BACKIN_HANDOVER_SIDE = 3    -- m du milieu du chemin, au plus, pour lâcher la route
ADHeaderFlow.BACKIN_OBSTACLE_MARGIN = 0.4 -- m dégagés de chaque côté de la remorque et de la moissonneuse (arbres, clôtures...)
ADHeaderFlow.BACKIN_FINAL_MIN = 1.5      -- m entre l'attelage de la moissonneuse et le cadre quand la place manque pour BACKIN_FINAL
ADHeaderFlow.BACKIN_AXIS_EXTRA = 6       -- ° de plus pour l'axe de la marche arrière : la remorque finit un peu moins tournée que lui
ADHeaderFlow.BACKIN_SLANTS = { 0, 5, 10 } -- ° : la moissonneuse arrive dans l'axe du cadre, sinon moins tournée de ça (l'approche accepte 15°)
ADHeaderFlow.BACKIN_END_STRAIGHT = 4     -- m tout droit au bout de la courbe (ADNoseIn.END_STRAIGHT)
ADHeaderFlow.BACKIN_BAND_MARGIN = 0.15   -- (16/11) m de chaque côté de l'attelage sur la bande où il roule après l'entrée (comme le balayage de la route)
ADHeaderFlow.BACKIN_TRACTOR_FRONT = 4    -- (16/11) m devant le point suivi du tracteur à l'arrêt
ADHeaderFlow.BACKIN_SWEEP = { 0.2, 0.4, 0.6, 0.8 } -- (16/11) parts de la marche arrière où la caisse de la remorque est contrôlée
ADHeaderFlow.BACKIN_SWEEP_MARGIN = 0.25  -- (16/11) m de chaque côté de la caisse pendant la marche arrière (objets fixes)
ADHeaderFlow.BACKIN_STUCK = 20000        -- (16/11) ms de marche arrière sans avancer : bloquée (objet fixe)
ADHeaderFlow.BACKIN_COUNTER_SWING = 1.6  -- (16/11) m : au début de la marche arrière, le nez du tracteur part d'abord vers la place de la remorque, d'autant au-delà de sa largeur

-- ------------------------------------------------------------------------------------------------------------
-- Petits outils
-- ------------------------------------------------------------------------------------------------------------
local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function refNode(t)
    if t.getAISteeringNode ~= nil then
        local node = t:getAISteeringNode()
        if node ~= nil then
            return node
        end
    end
    return t.components[1].node
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

local function endStraight()
    return (ADNoseIn ~= nil and ADNoseIn.END_STRAIGHT) or ADHeaderFlow.BACKIN_END_STRAIGHT
end

-- ------------------------------------------------------------------------------------------------------------
-- L'attelage : essieu de la remorque, cadre de la barre, moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- { rx, rz (essieu de la remorque, repère de sa caisse), hx, hz, fdx, fdz (cadre de la barre et vers où il regarde,
-- même repère), side (+1 cadre à gauche, -1 à droite), lt (m de l'attelage à l'essieu), dra (m du point suivi du
-- tracteur à l'essieu, attelage droit), cw, cl, dj (moissonneuse : largeur, longueur, m de son repère à son
-- attelage avant), rc (rayon de sa courbe) } ; nil, raison
function ADHeaderFlow.backInRig(t, job)
    local trailer, header, combine = job.trailer, job.header, job.combine
    local sdm = t.ad ~= nil and t.ad.specialDrivingModule or nil
    if trailer == nil or header == nil or combine == nil or sdm == nil or sdm.getReverseNode == nil then
        return nil, "attelage inconnu"
    end
    local node = sdm:getReverseNode()
    if node == nil or sdm.reverseSolo or t.trailer ~= trailer then
        return nil, "pas d'essieu de remorque à conduire en marche arrière"
    end
    local root = trailer.components[1].node
    local wx, wy, wz = getWorldTranslation(node)
    local rx, _, rz = worldToLocal(root, wx, wy, wz)
    local hitch = ADAutonomousManager.frontHitch(combine, header, true)
    if hitch == nil then
        return nil, "cadre de la barre introuvable"
    end
    local hx, _, hz = worldToLocal(root, hitch.x, hitch.y, hitch.z)
    local fdx, _, fdz = worldDirectionToLocal(root, hitch.dirX, 0, hitch.dirZ)
    if math.abs(fdx) < 0.7 then
        return nil, "barre posée dans l'axe de la remorque"
    end
    local ref = refNode(t)
    local input = trailer.getActiveInputAttacherJoint ~= nil and trailer:getActiveInputAttacherJoint() or nil
    local index = t.getAttacherJointIndexFromObject ~= nil and t:getAttacherJointIndexFromObject(trailer) or nil
    local joint = index ~= nil and t.spec_attacherJoints ~= nil and t.spec_attacherJoints.attacherJoints[index] or nil
    local lt, dra
    if input ~= nil and input.node ~= nil and joint ~= nil and joint.jointTransform ~= nil and ADHeaderFlow.straightHitch ~= nil then
        local jx, jy, jz = getWorldTranslation(joint.jointTransform)
        local _, _, back = worldToLocal(ref, jx, jy, jz)
        local _, az = ADHeaderFlow.straightHitch(trailer, input, root)
        lt = az - rz
        dra = lt - back
    else
        -- sans les points d'attelage : mesuré tel quel (attelage à peu près droit sur la route)
        local _, _, back = worldToLocal(ref, wx, wy, wz)
        dra = -back
        lt = dra - 2
    end
    if lt < 1.5 or dra < lt then
        return nil, "essieu de la remorque mal placé"
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
    return { rx = rx, rz = rz, hx = hx, hz = hz, fdx = fdx, fdz = fdz, side = fdx > 0 and 1 or -1, lt = lt, dra = dra,
        cw = cw, cl = cl, dj = dj, rc = rc }
end

-- ------------------------------------------------------------------------------------------------------------
-- Le chemin : où il continue tout droit, où il est droit avant, de quel côté est le champ
-- ------------------------------------------------------------------------------------------------------------
-- sens du tronçon de route qui arrive au point i
local function routeHeading(route, i)
    local j = i - 1
    while j >= 1 do
        local dx, dz = unit(route[i].x - route[j].x, route[i].z - route[j].z)
        if dx ~= nil then
            return dx, dz
        end
        j = j - 1
    end
    return nil
end

-- dernier point de la route, à moins de BACKIN_JUNCTION_SPAN m du bout, d'où le réseau continue tout droit sans
-- suivre la route : index, sens d'arrivée, premier point de la suite
local function findJunction(wayPoints, current)
    local n = #wayPoints
    local cosMax = math.cos(math.rad(ADHeaderFlow.BACKIN_STRAIGHT))
    local fromEnd = 0
    local i = n
    while i >= 2 and i > (current or 1) and fromEnd <= ADHeaderFlow.BACKIN_JUNCTION_SPAN do
        local wp = wayPoints[i]
        local net = wp.id ~= nil and ADGraphManager:getWayPointById(wp.id) or nil
        local dx, dz = routeHeading(wayPoints, i)
        if net ~= nil and net.out ~= nil and dx ~= nil then
            local nextId = wayPoints[i + 1] ~= nil and wayPoints[i + 1].id or nil
            local prevId = wayPoints[i - 1].id
            for _, id in ipairs(net.out) do
                if id ~= nextId and id ~= prevId then
                    local o = ADGraphManager:getWayPointById(id)
                    local ox, oz
                    if o ~= nil then
                        ox, oz = unit(o.x - wp.x, o.z - wp.z)
                    end
                    if ox ~= nil and ox * dx + oz * dz >= cosMax then
                        return i, dx, dz, o
                    end
                end
            end
        end
        fromEnd = fromEnd + dist(wp, wayPoints[i - 1])
        i = i - 1
    end
    return nil
end

-- le chemin après le point start : les points du réseau qui continuent dans le sens (dx, dz), et la longueur
-- cumulée à chacun
local function laneAhead(start, first, dx, dz)
    local cosMax = math.cos(math.rad(ADHeaderFlow.BACKIN_STRAIGHT))
    local points, lengths = { first }, { dist(first, start) }
    local prev, wp = start, first
    while lengths[#lengths] < ADHeaderFlow.BACKIN_LANE_MAX do
        local best, bestDot = nil, cosMax
        for _, id in ipairs(wp.out or {}) do
            if id ~= prev.id then
                local o = ADGraphManager:getWayPointById(id)
                local ox, oz
                if o ~= nil then
                    ox, oz = unit(o.x - wp.x, o.z - wp.z)
                end
                if ox ~= nil and ox * dx + oz * dz >= bestDot then
                    best, bestDot = o, ox * dx + oz * dz
                end
            end
        end
        if best == nil then
            break
        end
        points[#points + 1] = best
        lengths[#lengths + 1] = lengths[#lengths] + dist(best, wp)
        prev, wp = wp, best
    end
    return points, lengths
end

-- aussi pour AutonomousHeaderRoadBack.lua (remorque reculée tout droit jusqu'à la route)
ADHeaderFlow.backInLaneAhead = laneAhead

-- m de route droite avant son point i : dans l'axe du chemin (jx, jz, ux, uz), à moins de BACKIN_LANE_DEV m
local function straightBefore(route, i, jx, jz, ux, uz)
    local back = 0
    local k = i - 1
    while k >= 1 do
        local ox, oz = route[k].x - jx, route[k].z - jz
        local along = ox * ux + oz * uz
        if math.abs(ox * uz - oz * ux) > ADHeaderFlow.BACKIN_LANE_DEV or along > -back then
            break
        end
        back = -along
        k = k - 1
    end
    return back
end

-- (16/11) aussi pour AutonomousHeaderCross.lua (route du tracteur droite avant l'entrée)
ADHeaderFlow.backInStraightBefore = straightBefore

-- premier mètre de culture en s'écartant de (x, z) dans le sens (nx, nz), entre from et to m ; nil : aucune
-- boîte (centre, sens, demi-largeur, demi-longueur), de 0,3 m à 3,3 m au-dessus du sol : un obstacle dedans ?
-- (l'attelage du tracteur lui-même ne compte pas : ADTrafficYieldModule:overlapHit)
local function boxHit(t, cx, cz, dx, dz, halfWidth, halfLength)
    local yield = t.ad ~= nil and t.ad.trafficYieldModule or nil
    if yield == nil or yield.overlapHit == nil then
        return false
    end
    return yield:overlapHit(cx, groundY(cx, cz) + 1.8, cz, MathUtil.getYRotationFromDirection(dx, dz), halfWidth, 1.5, halfLength) == true
end

-- (16/11) aussi pour AutonomousHeaderCross.lua
ADHeaderFlow.backInBoxHit = boxHit

-- (16/11) même boîte : un OBJET FIXE dedans (muret, clôture, poteau, arbre, bâtiment) ? Les véhicules ne comptent
-- pas ; l'attelage du tracteur et la barre non plus. Le masque est celui des objets du capteur avant
-- (ADCollSensorSplit.maskObjects) : le muret du champ 52 (« col02 », « col03 ») était vu par lui. 2e valeur : son nom
function ADHeaderFlow.fixedHit(t, job, cx, cz, dx, dz, halfWidth, halfLength)
    local yield = t ~= nil and t.ad ~= nil and t.ad.trafficYieldModule or nil
    if yield == nil then
        return false
    end
    local y, ry = groundY(cx, cz) + 1.8, MathUtil.getYRotationFromDirection(dx, dz)
    local ignored = yield.overlapIgnoreVehicle
    if job ~= nil and job.header ~= nil then
        yield.overlapIgnoreVehicle = job.header
    end
    local hit, name = false, nil
    if overlapBox ~= nil and CollisionFlag ~= nil and yield.overlapCallback ~= nil then
        local mask = (ADCollSensorSplit ~= nil and ADCollSensorSplit.maskObjects)
            or (CollisionFlag.DEFAULT + CollisionFlag.STATIC_OBJECT + CollisionFlag.TREE + CollisionFlag.BUILDING)
        yield.overlapHitCount, yield.overlapHitName, yield.overlapHitVehicle = 0, nil, nil
        overlapBox(cx, y, cz, 0, ry, 0, halfWidth, 1.5, halfLength, "overlapCallback", yield, mask, true, true, true, true)
        hit = (yield.overlapHitCount or 0) > 0 and not yield.overlapHitVehicle
        name = yield.overlapHitName
    elseif yield.overlapHitStatic ~= nil then
        hit = yield:overlapHitStatic(cx, y, cz, ry, halfWidth, 1.5, halfLength) == true
        name = yield.overlapHitName
    elseif yield.overlapHit ~= nil then
        hit = yield:overlapHit(cx, y, cz, ry, halfWidth, 1.5, halfLength) == true
        name = yield.overlapHitName
    end
    yield.overlapIgnoreVehicle = ignored
    return hit, name
end

-- (16/11) bande du chemin entre from et to m (repère du chemin : jx, jz, ux, uz, nx, nz), décalée de offset m vers
-- n, demi-largeur half : un objet fixe dessus ? (hit, nom)
function ADHeaderFlow.backInBandHit(t, job, lane, offset, from, to, half)
    if to - from < 0.5 then
        return false
    end
    local mid = (from + to) / 2
    local cx, cz = lane.jx + lane.ux * mid + lane.nx * offset, lane.jz + lane.uz * mid + lane.nz * offset
    return ADHeaderFlow.fixedHit(t, job, cx, cz, lane.ux, lane.uz, half, (to - from) / 2)
end

-- (16/11) l'attelage après l'entrée (s : backInStop), sur une demi-largeur half : la bande du milieu du chemin (de
-- from m jusqu'au décalage), celle du décalage, celle où il roule décalé jusqu'au nez du tracteur à l'arrêt, puis la
-- place où le nez du tracteur part d'abord au début de la marche arrière (vers la place de la remorque,
-- swing m au-delà de sa largeur, BACKIN_COUNTER_SWING par défaut) : un objet fixe ? (hit, nom, true si c'est cette
-- dernière place)
function ADHeaderFlow.backInTrainHit(t, job, lane, s, from, half, swing)
    local front = ADHeaderFlow.BACKIN_TRACTOR_FRONT
    local hit, name
    if s.bias > 0 then
        hit, name = ADHeaderFlow.backInBandHit(t, job, lane, 0, from, s.shiftFrom, half)
        if not hit then
            hit, name = ADHeaderFlow.backInBandHit(t, job, lane, s.bias / 2, s.shiftFrom, s.shiftTo, half + s.bias / 2)
        end
        if not hit then
            hit, name = ADHeaderFlow.backInBandHit(t, job, lane, s.bias, s.shiftTo, s.stop + front, half)
        end
    else
        hit, name = ADHeaderFlow.backInBandHit(t, job, lane, 0, from, s.stop + front, half)
    end
    if hit then
        return true, name, false
    end
    swing = swing or ADHeaderFlow.BACKIN_COUNTER_SWING
    hit, name = ADHeaderFlow.backInBandHit(t, job, lane, s.bias + swing / 2, s.stop - 4, s.stop + front, half + swing / 2)
    return hit, name, hit
end

-- (16/11) la caisse de la remorque pendant la marche arrière : l'essieu sur l'axe (q + a x reach x f), la caisse
-- tournée peu à peu du sens du chemin (f = 0) à celui de la remorque à la fin (theta vers n, f = 1). Un objet fixe
-- dans une de ces caisses, ou sur l'axe entre le chemin et l'essieu : (true, nom)
function ADHeaderFlow.backInSweepHit(t, job, s)
    local rig = s.rig
    local trailerWidth = (job.trailer.size ~= nil and job.trailer.size.width) or 3
    local trailerLength = (job.trailer.size ~= nil and job.trailer.size.length) or 12
    local half = trailerWidth / 2 + ADHeaderFlow.BACKIN_SWEEP_MARGIN
    for _, f in ipairs(ADHeaderFlow.BACKIN_SWEEP) do
        local phi = s.theta * f
        local tfx, tfz = math.cos(phi) * s.ux - math.sin(phi) * s.nx, math.cos(phi) * s.uz - math.sin(phi) * s.nz
        local tlx, tlz = tfz, -tfx
        local axX, axZ = s.qx + s.ax * s.reach * f, s.qz + s.az * s.reach * f
        local rootX, rootZ = axX - rig.rx * tlx - rig.rz * tfx, axZ - rig.rx * tlz - rig.rz * tfz
        local hit, name = ADHeaderFlow.fixedHit(t, job, rootX, rootZ, tfx, tfz, half, trailerLength / 2)
        if hit then
            return true, name
        end
    end
    local hit, name = ADHeaderFlow.fixedHit(t, job, s.qx + s.ax * s.reach / 2, s.qz + s.az * s.reach / 2, s.ax, s.az, half, s.reach / 2 + 1)
    return hit, name
end

local function cropEdge(x, z, nx, nz, from, to)
    local d = from
    while d <= to do
        if hasCrop(x + nx * d, z + nz * d) then
            return d
        end
        d = d + 0.5
    end
    return nil
end

-- sol praticable de (x, z) sur width m dans le sens (nx, nz) : ni culture, ni eau
local function isClear(x, z, nx, nz, width)
    local d = 1
    while d <= width do
        local px, pz = x + nx * d, z + nz * d
        if hasCrop(px, pz) or ADHeaderFlow.isWater(px, pz, groundY(px, pz)) then
            return false
        end
        d = d + 0.5
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- La courbe de la moissonneuse, du chemin jusque devant le cadre de la barre
-- ------------------------------------------------------------------------------------------------------------
-- le sol sous la courbe (la largeur de la moissonneuse) : pas d'eau, pas de marche, et pas de culture de l'autre
-- côté du chemin (côté champ, c'est celle du champ à récolter)
local function groundOk(lane, points)
    local half = lane.cw / 2 + 0.3
    local previous, previousY = nil, nil
    for _, p in ipairs(points) do
        local y = groundY(p.x, p.z)
        if previousY ~= nil and math.abs(y - previousY) > ADHeaderFlow.MAX_STEP_RISE then
            return false
        end
        local dx, dz = lane.ux, lane.uz
        if previous ~= nil then
            local ex, ez = unit(p.x - previous.x, p.z - previous.z)
            if ex ~= nil then
                dx, dz = ex, ez
            end
        end
        for _, side in ipairs({ 0, -half, half }) do
            -- GIANTS : la gauche du cap (dx, dz) = (dz, -dx)
            local sx, sz = p.x + dz * side, p.z - dx * side
            if ADHeaderFlow.isWater(sx, sz, groundY(sx, sz)) then
                return false
            end
            local across = (sx - lane.jx) * lane.nx + (sz - lane.jz) * lane.nz
            -- (16/11) barre en travers du chemin (lane.anyCrop) : la culture ne compte d'aucun côté, et pas de champ
            -- (même sans culture) du côté de la barre
            if (across < 0 or lane.anyCrop) and hasCrop(sx, sz) then
                return false
            end
            if lane.anyCrop and across > 0.5 and AutoDrive ~= nil and AutoDrive.checkIsOnField ~= nil and AutoDrive.checkIsOnField(sx, groundY(sx, sz), sz) == true then
                return false
            end
        end
        previous, previousY = p, y
    end
    return true
end

-- points de la courbe de (x, z), cap (fx, fz), jusque devant le cadre hitch (BACKIN_FINAL m entre l'attelage de la
-- moissonneuse et le cadre), pour drivePathModule:setWayPoints ; nil : pas de courbe
function ADHeaderFlow.backInPath(lane, x, z, fx, fz, hitch)
    if ADNoseIn == nil or ADNoseIn.bestCurve == nil or hitch == nil then
        return nil
    end
    local a0 = math.atan2(fx, fz)
    local axis = math.atan2(-hitch.dirX, -hitch.dirZ)
    local delta = axis - a0
    if delta > math.pi then
        delta = delta - 2 * math.pi
    elseif delta < -math.pi then
        delta = delta + 2 * math.pi
    end
    local way = (delta < 0) and -1 or 1
    local straight = endStraight()
    -- où la moissonneuse finit : dans l'axe du cadre, BACKIN_FINAL m entre son attelage et le cadre (moins si la
    -- place manque) ; d'abord en arrivant dans l'axe, sinon un peu moins tournée (remorque plus tournée que prévu) :
    -- elle finit de s'aligner en avançant sur le cadre
    for _, final in ipairs({ ADHeaderFlow.BACKIN_FINAL, ADHeaderFlow.BACKIN_FINAL_MIN }) do
        local gap = lane.dj + final
        local ex, ez = hitch.x + hitch.dirX * gap, hitch.z + hitch.dirZ * gap
        for _, slant in ipairs(ADHeaderFlow.BACKIN_SLANTS) do
            if slant == 0 or math.abs(delta) > math.rad(slant) then
                local a1 = axis - way * math.rad(slant)
                local x1, z1 = ex - math.sin(a1) * straight, ez - math.cos(a1) * straight
                local c = ADNoseIn.bestCurve(x, z, a0, x1, z1, a1, lane.rc, function(candidate)
                    return groundOk(lane, ADNoseIn.samplePoints(candidate, 0))
                end)
                if c ~= nil then
                    local points = ADNoseIn.samplePoints(c, 0)
                    table.insert(points, 1, { x = x, y = 0, z = z })
                    for _, p in ipairs(points) do
                        p.y = groundY(p.x, p.z)
                        p.isPathFinderPoint = true
                    end
                    return points, c, slant, final
                end
            end
        end
    end
    return nil
end

-- le chemin et le cadre de la barre (prévu ou vrai) vus par la moissonneuse : { jx, jz, ux, uz, nx, nz, cw, dj, rc,
-- handover (m après le point du chemin où elle lâche la route), targetId (point du réseau où elle va), turn (°),
-- anyCrop (16/11 : barre en travers du chemin, la culture ne compte d'aucun côté) } ; nil, raison
function ADHeaderFlow.backInLane(plan, hitch)
    if hitch == nil then
        return nil, "cadre de la barre introuvable"
    end
    local rig = plan.rig
    local cosB = -(hitch.dirX * plan.ux + hitch.dirZ * plan.uz)
    local sinB = -(hitch.dirX * plan.nx + hitch.dirZ * plan.nz)
    local beta = math.atan2(sinB, cosB)
    if cosB < math.cos(math.rad(ADHeaderFlow.BACKIN_MAX_TURN)) or sinB < 0 then
        return nil, string.format("cadre de la barre à %.0f° du chemin", math.deg(math.abs(beta)))
    end
    local uF = (hitch.x - plan.jx) * plan.ux + (hitch.z - plan.jz) * plan.uz
    local nF = (hitch.x - plan.jx) * plan.nx + (hitch.z - plan.jz) * plan.nz
    -- début du virage sur le milieu du chemin : l'axe du cadre coupe le chemin, moins la tangente de l'arc
    local turn
    if sinB > 0.08 then
        turn = uF - nF * cosB / sinB - rig.rc * math.tan(beta / 2)
    else
        turn = uF - (rig.dj + endStraight() + ADHeaderFlow.BACKIN_FINAL) - rig.rc
    end
    local lane = { jx = plan.jx, jz = plan.jz, ux = plan.ux, uz = plan.uz, nx = plan.nx, nz = plan.nz,
        cw = rig.cw, dj = rig.dj, rc = rig.rc, turn = math.deg(beta), anyCrop = plan.cross == true }
    -- où elle lâche la route : avant le virage, pas avant d'être sur le chemin droit
    local earliest = -plan.before + 2
    for _, lead in ipairs({ ADHeaderFlow.BACKIN_LEAD, 2 * ADHeaderFlow.BACKIN_LEAD }) do
        local handover = math.max(turn - lead, earliest)
        if handover <= turn then
            local x, z = plan.jx + plan.ux * handover, plan.jz + plan.uz * handover
            if ADHeaderFlow.backInPath(lane, x, z, plan.ux, plan.uz, hitch) ~= nil then
                lane.handover = handover
                lane.latest = math.max(turn, handover)
                break
            end
        end
    end
    if lane.handover == nil then
        return nil, "pas de courbe du chemin jusqu'au cadre de la barre"
    end
    -- point du réseau où la moissonneuse va : sur le chemin, après l'endroit où elle lâche la route
    lane.targetId = plan.jid
    if lane.handover + 4 > 0 then
        for k, p in ipairs(plan.points) do
            lane.targetId = p.id
            if plan.lengths[k] >= lane.handover + 4 then
                break
            end
        end
    end
    return lane
end

-- ------------------------------------------------------------------------------------------------------------
-- Le plan : où la remorque entre dans le champ, d'où le tracteur recule
-- ------------------------------------------------------------------------------------------------------------
-- (16/11) le chemin vu de la route du tracteur, sans la remorque (aussi pour AutonomousHeaderCross.lua) :
-- { j, J (point du chemin d'où le réseau continue tout droit), points, lengths (la suite), ux, uz (sens du chemin),
-- available (m de chemin droit après J), E (bout de la route), uE, leftE, ex, ez, side (+1 champ à gauche, -1 à
-- droite), nx, nz (vers le champ), before (m de route droite de la moissonneuse avant J) } ; nil, raison
function ADHeaderFlow.backInLaneInfo(t, job, wayPoints, current)
    local n = wayPoints ~= nil and #wayPoints or 0
    if n < 3 then
        return nil, "route trop courte"
    end
    local j, hx, hz, first = findJunction(wayPoints, current)
    if j == nil then
        return nil, "le chemin ne continue pas tout droit après l'entrée du champ"
    end
    local J = wayPoints[j]
    local points, lengths = laneAhead(ADGraphManager:getWayPointById(J.id), first, hx, hz)
    -- sens du chemin : de l'entrée vers la suite ; la suite s'arrête où elle s'écarte de cette ligne
    local far = points[#points]
    for k, p in ipairs(points) do
        if lengths[k] >= ADHeaderFlow.BACKIN_LANE_FIT then
            far = p
            break
        end
    end
    local ux, uz = unit(far.x - J.x, far.z - J.z)
    if ux == nil then
        return nil, "chemin trop court après l'entrée"
    end
    local available = lengths[#lengths]
    for k, p in ipairs(points) do
        local ox, oz = p.x - J.x, p.z - J.z
        if math.abs(ox * uz - oz * ux) > ADHeaderFlow.BACKIN_LANE_DEV then
            available = k > 1 and lengths[k - 1] or 0
            break
        end
    end
    -- côté du champ : GIANTS, la gauche du cap (ux, uz) = (uz, -ux)
    local E = wayPoints[n]
    local uE = (E.x - J.x) * ux + (E.z - J.z) * uz
    local leftE = (E.x - J.x) * uz - (E.z - J.z) * ux
    local ex, ez = J.x + ux * uE, J.z + uz * uE
    local side = nil
    if math.abs(leftE) >= 2 then
        side = leftE > 0 and 1 or -1
    else
        local _, fxp, fzp = nil, nil, nil
        if ADAutonomousManager.markerField ~= nil then
            _, fxp, fzp = ADAutonomousManager.markerField(job.combine, E.x, E.z)
        end
        local l = fxp ~= nil and ((fxp - J.x) * uz - (fzp - J.z) * ux) or 0
        if math.abs(l) >= 1 then
            side = l > 0 and 1 or -1
        else
            local onLeft = cropEdge(ex, ez, uz, -ux, 1, ADHeaderFlow.BACKIN_EDGE_SCAN)
            local onRight = cropEdge(ex, ez, -uz, ux, 1, ADHeaderFlow.BACKIN_EDGE_SCAN)
            if (onLeft ~= nil) ~= (onRight ~= nil) then
                side = onLeft ~= nil and 1 or -1
            end
        end
    end
    if side == nil then
        return nil, "côté du champ pas trouvé"
    end
    -- la moissonneuse arrive par le même chemin, dans le même sens
    local route = ADGraphManager:getPathTo(job.combine, J.id)
    local rn = route ~= nil and #route or 0
    if rn < 2 or route[rn].id ~= J.id then
        return nil, "pas de route de la moissonneuse jusqu'à l'entrée du champ"
    end
    local cx, cz = routeHeading(route, rn)
    if cx == nil or cx * ux + cz * uz < math.cos(math.rad(ADHeaderFlow.BACKIN_STRAIGHT)) then
        return nil, "la moissonneuse arrive par un autre côté"
    end
    return { j = j, J = J, points = points, lengths = lengths, ux = ux, uz = uz, available = available, E = E, uE = uE,
        leftE = leftE, ex = ex, ez = ez, side = side, nx = side * uz, nz = -side * ux,
        before = straightBefore(route, rn, J.x, J.z, ux, uz) }
end

-- (16/11) le point d'arrêt du tracteur pour une remorque dont l'essieu finit en (axleX, axleZ), à axleN m du milieu
-- du chemin vers lane.nx, lane.nz, l'axe de la marche arrière (ax, az) à sinA du chemin, le tracteur décalé de bias
-- m vers ce côté : { reach, qx, qz, uQ, stop, shiftFrom, shiftTo, bias } (décalage annulé s'il n'a pas la place de
-- se faire). from : m du chemin où le décalage peut commencer (BACKIN_BIAS_FROM par défaut)
function ADHeaderFlow.backInStop(lane, rig, axleX, axleZ, axleN, ax, az, sinA, bias, from)
    local s
    for _ = 1, 2 do
        local reach = (axleN - bias) / sinA
        local qx, qz = axleX - ax * reach, axleZ - az * reach
        local uQ = (qx - lane.jx) * lane.ux + (qz - lane.jz) * lane.uz
        local uStop = uQ + ADHeaderFlow.BACKIN_START + rig.dra
        -- décalage fini assez tôt pour que la remorque soit droite derrière le tracteur à l'arrêt
        local shiftTo = uStop - 1.5 * rig.lt
        local shiftFrom = math.max(from or ADHeaderFlow.BACKIN_BIAS_FROM, shiftTo - ADHeaderFlow.BACKIN_BIAS_SHIFT)
        s = { reach = reach, qx = qx, qz = qz, uQ = uQ, stop = uStop, shiftFrom = shiftFrom, shiftTo = shiftTo, bias = bias }
        if bias == 0 or shiftTo - shiftFrom >= ADHeaderFlow.BACKIN_BIAS_SHIFT * 0.6 then
            break
        end
        bias = 0
    end
    return s
end

-- (16/11) demi-largeur de l'attelage (tracteur ou remorque, le plus large) sur la bande où il roule
function ADHeaderFlow.backInTrainHalf(t, job)
    local trailerWidth = (job.trailer.size ~= nil and job.trailer.size.width) or 3
    local tractorWidth = (t.size ~= nil and t.size.width) or 2.6
    return math.max(trailerWidth, tractorWidth) / 2 + ADHeaderFlow.BACKIN_BAND_MARGIN
end

-- wayPoints : la route du tracteur vers le point du champ ; nil, raison quand la marche arrière ne se fait pas ici.
-- (16/11) 3e valeur quand la barre peut encore être reculée en travers du chemin : « closed » (champ fermé par un
-- objet fixe) ou « frameSide » (cadre de la barre du côté du champ)
-- (17/11) slide : m de plus le long du chemin après la place habituelle (endroit plus loin le long du champ)
function ADHeaderFlow.backInPlan(t, job, wayPoints, current, slide)
    local n = wayPoints ~= nil and #wayPoints or 0
    if n < 3 then
        return nil, "route trop courte"
    end
    local rig, why = ADHeaderFlow.backInRig(t, job)
    if rig == nil then
        return nil, why
    end
    local info, infoWhy = ADHeaderFlow.backInLaneInfo(t, job, wayPoints, current)
    if info == nil then
        return nil, infoWhy
    end
    if rig.side == info.side then
        return nil, "le cadre de la barre est du côté du champ", "frameSide"
    end
    local J, ux, uz, nx, nz = info.J, info.ux, info.uz, info.nx, info.nz
    local uE, leftE, ex, ez, before = info.uE, info.leftE, info.ex, info.ez, info.before
    -- la remorque reculée : son avant, sa gauche, vers où regarde le cadre de la barre
    local theta = math.rad(ADHeaderFlow.BACKIN_ANGLE)
    local sinT, cosT = math.sin(theta), math.cos(theta)
    local tfx, tfz = cosT * ux - sinT * nx, cosT * uz - sinT * nz
    local tlx, tlz = tfz, -tfx
    local fx, fz = unit(rig.fdx * tlx + rig.fdz * tfx, rig.fdx * tlz + rig.fdz * tfz)
    local cosB = -(fx * ux + fz * uz)
    local sinB = -(fx * nx + fz * nz)
    if cosB < math.cos(math.rad(ADHeaderFlow.BACKIN_MAX_TURN)) or sinB < 0.1 then
        return nil, "cadre de la barre pas tourné vers le chemin une fois la remorque reculée"
    end
    local beta = math.atan2(sinB, cosB)
    local run = rig.dj + endStraight() + ADHeaderFlow.BACKIN_FINAL
    local tangent = rig.rc * math.tan(beta / 2)
    -- le cadre : assez loin dans le champ pour le virage puis la ligne droite de la moissonneuse, assez loin sur le
    -- chemin pour qu'elle soit alignée avant ce virage
    local edge = cropEdge(ex, ez, nx, nz, 1, ADHeaderFlow.BACKIN_EDGE_SCAN) or math.max(math.abs(leftE), ADHeaderFlow.BACKIN_EDGE_DEFAULT)
    local nFrame = math.max(edge + ADHeaderFlow.BACKIN_EDGE_IN, rig.rc * (1 - cosB) + run * sinB)
    local uFrame = math.max(uE + ADHeaderFlow.BACKIN_PAST, -before + ADHeaderFlow.BACKIN_ALIGN + tangent + nFrame * cosB / sinB)
    if uFrame - uE > ADHeaderFlow.BACKIN_SHIFT_MAX then
        return nil, string.format("pas assez de chemin droit avant l'entrée (%.0f m)", before)
    end
    if slide ~= nil and slide > 0 then
        -- (17/11, Champ 7) plus loin le long du champ : le bord du champ est repris là
        uFrame = uFrame + slide
        local sx, sz = J.x + ux * uFrame, J.z + uz * uFrame
        local edgeS = cropEdge(sx, sz, nx, nz, 1, ADHeaderFlow.BACKIN_EDGE_SCAN)
        if edgeS == nil then
            -- pas de culture (entrée déjà écrasée...) : le bord du champ lui-même
            local d = 1
            while d <= ADHeaderFlow.BACKIN_EDGE_SCAN do
                local px, pz = sx + nx * d, sz + nz * d
                if AutoDrive ~= nil and AutoDrive.checkIsOnField ~= nil and AutoDrive.checkIsOnField(px, groundY(px, pz), pz) == true then
                    edgeS = d
                    break
                end
                d = d + 0.5
            end
        end
        if edgeS == nil then
            return nil, "plus de champ le long du chemin ici"
        end
        edge = edgeS
        nFrame = math.max(edge + ADHeaderFlow.BACKIN_EDGE_IN, rig.rc * (1 - cosB) + run * sinB)
    end
    local frameX, frameZ = J.x + ux * uFrame + nx * nFrame, J.z + uz * uFrame + nz * nFrame
    -- la caisse de la remorque, puis son essieu, puis l'axe de la marche arrière (il coupe le milieu du chemin en q)
    local rootX, rootZ = frameX - rig.hx * tlx - rig.hz * tfx, frameZ - rig.hx * tlz - rig.hz * tfz
    local axleX, axleZ = rootX + rig.rx * tlx + rig.rz * tfx, rootZ + rig.rx * tlz + rig.rz * tfz
    -- l'axe de la marche arrière passe par l'essieu ; un peu plus tourné que la remorque attendue, qui finit de
    -- s'aligner sur lui quand elle s'arrête
    local axis = theta + math.rad(ADHeaderFlow.BACKIN_AXIS_EXTRA)
    local sinA = math.sin(axis)
    local ax, az = -(math.cos(axis) * ux - sinA * nx), -(math.cos(axis) * uz - sinA * nz)
    local axleN = (axleX - J.x) * nx + (axleZ - J.z) * nz
    -- la ligne où le tracteur s'arrête et d'où il recule : décalée du milieu du chemin vers le champ (son nez passe de
    -- l'autre côté pendant la marche arrière) ; l'axe de la marche arrière la coupe en q
    local trailerWidth = (job.trailer.size ~= nil and job.trailer.size.width) or 3
    local tractorWidth = (t.size ~= nil and t.size.width) or 2.6
    local lane = { jx = J.x, jz = J.z, ux = ux, uz = uz, nx = nx, nz = nz }
    local half = ADHeaderFlow.backInTrainHalf(t, job)
    local front = ADHeaderFlow.BACKIN_TRACTOR_FRONT
    -- (17/11, Champ 7) décalages essayés vers le champ : BACKIN_BIAS d'abord (comme avant), puis toute l'herbe libre
    -- jusqu'à la culture (le tracteur passe au-delà des poteaux, son nez déborde d'autant moins en face), enfin le
    -- milieu du chemin. Avant : 1,5 m ou le milieu, et un poteau sur la bande décalée suffisait à rester au milieu
    -- (« objet fixe (col) sur la bande décalée »), puis l'arbre en face refusait tout (« LOD0 »).
    local maxBias = math.max(0, edge - math.max(trailerWidth, tractorWidth) / 2 - ADHeaderFlow.BACKIN_BIAS_EDGE)
    local biases, seen = {}, {}
    local function addBias(b)
        b = math.floor(math.max(0, math.min(b, maxBias)) * 10 + 0.5) / 10
        if not seen[b] then
            seen[b] = true
            biases[#biases + 1] = b
        end
    end
    addBias(ADHeaderFlow.BACKIN_BIAS)
    if ADHeaderFlow.BACKIN_BIAS_WIDE then
        local b = ADHeaderFlow.BACKIN_BIAS + 1
        while b < maxBias do
            addBias(b)
            b = b + 1
        end
        addBias(maxBias)
    end
    addBias(0)
    -- un décalage : l'arrêt (s), sinon nil, raison, code
    local function tryBias(b)
        local savedShift = ADHeaderFlow.BACKIN_BIAS_SHIFT
        ADHeaderFlow.BACKIN_BIAS_SHIFT = math.max(savedShift, b * ADHeaderFlow.BACKIN_BIAS_SLOPE)
        -- décalage plus large : il peut commencer avant l'entrée (le tracteur arrive par le même chemin)
        local from = b > ADHeaderFlow.BACKIN_BIAS and math.max(ADHeaderFlow.BACKIN_BIAS_FROM - ADHeaderFlow.BACKIN_BIAS_BEFORE, -before + 2) or nil
        local s = ADHeaderFlow.backInStop(lane, rig, axleX, axleZ, axleN, ax, az, sinA, b, from)
        ADHeaderFlow.BACKIN_BIAS_SHIFT = savedShift
        if s.bias ~= b then
            return nil, string.format("pas assez de chemin pour se décaler de %.1f m", b)
        end
        if b > 0 then
            -- (16/11) objets fixes sur la bande où l'attelage roule après l'entrée ; (17/11) le décalage suit sa diagonale
            local hit, name = ADHeaderFlow.backInBandHit(t, job, lane, 0, ADHeaderFlow.BACKIN_ROUTE_STEP, s.shiftFrom, half)
            local u = s.shiftFrom
            while not hit and u < s.shiftTo do
                local u2 = math.min(u + 2, s.shiftTo)
                local off = b * ((u + u2) / 2 - s.shiftFrom) / math.max(s.shiftTo - s.shiftFrom, 0.1)
                hit, name = ADHeaderFlow.backInBandHit(t, job, lane, off, u, u2, half)
                u = u2
            end
            if not hit then
                hit, name = ADHeaderFlow.backInBandHit(t, job, lane, b, s.shiftTo, s.stop + front, half)
            end
            if not hit then
                local swing = ADHeaderFlow.BACKIN_COUNTER_SWING
                hit, name = ADHeaderFlow.backInBandHit(t, job, lane, b + swing / 2, s.stop - 4, s.stop + front, half + swing / 2)
            end
            if hit then
                return nil, string.format("objet fixe (%s) sur la bande décalée de %.1f m vers le champ", tostring(name), b)
            end
            if b > ADHeaderFlow.BACKIN_BIAS then
                -- (17/11) l'herbe jusqu'à la culture sur toute la bande décalée (le bord du champ n'est mesuré qu'à l'entrée)
                local trainHalf = math.max(trailerWidth, tractorWidth) / 2 + ADHeaderFlow.BACKIN_BIAS_EDGE
                local u = s.shiftFrom
                while u <= s.stop + front do
                    local off = u >= s.shiftTo and b or b * (u - s.shiftFrom) / math.max(s.shiftTo - s.shiftFrom, 0.1)
                    local px, pz = J.x + ux * u + nx * (off + trainHalf), J.z + uz * u + nz * (off + trainHalf)
                    if hasCrop(px, pz) then
                        return nil, string.format("culture sur la bande décalée de %.1f m vers le champ (%.0f m après l'entrée)", b, u)
                    end
                    u = u + 2
                end
            end
        else
            local hit, name, swing = ADHeaderFlow.backInTrainHit(t, job, lane, s, ADHeaderFlow.BACKIN_ROUTE_STEP, half)
            if hit and swing then
                -- le muret longe le chemin jusqu'à l'arrêt : le nez du tracteur le toucherait en partant
                return nil, string.format("champ fermé : objet fixe là où le nez du tracteur part au début de la marche arrière (%s)", tostring(name)), "closed"
            elseif hit then
                return nil, string.format("objet fixe sur le chemin après l'entrée (%s)", tostring(name))
            end
        end
        if s.reach < 2 or s.reach > ADHeaderFlow.BACKIN_MAX_REACH then
            return nil, string.format("remorque à reculer de %.0f m dans le champ", s.reach)
        end
        if s.stop + 1 > info.available then
            return nil, string.format("chemin trop court après l'entrée (%.0f m, il en faut %.0f)", info.available, s.stop + 1)
        end
        -- l'autre côté : le nez du tracteur y passe pendant la marche arrière, BACKIN_OTHER_MIN m depuis la ligne
        -- où il s'arrête (décalée de b vers le champ)
        -- (17/11) mesuré hors jeu : le nez passe à 5,1 m du milieu du chemin sans décalage, 3,6 m décalé de 1,5 m :
        -- BACKIN_OTHER_EXTRA m de plus que BACKIN_OTHER_MIN
        local extra = ADHeaderFlow.BACKIN_OTHER_EXTRA
        local reachOther = ADHeaderFlow.BACKIN_OTHER_MIN + extra - b
        if reachOther > 0.5 then
            for _, along in ipairs({ s.uQ - 6, s.uQ, s.uQ + ADHeaderFlow.BACKIN_START }) do
                if not isClear(J.x + ux * along, J.z + uz * along, -nx, -nz, reachOther) then
                    return nil, "pas assez de place de l'autre côté du chemin"
                end
            end
        end
        local otherHit, otherName = ADHeaderFlow.backInBandHit(t, job, lane, b - (ADHeaderFlow.BACKIN_OTHER_MIN + extra) / 2, s.uQ - 6,
            s.uQ + ADHeaderFlow.BACKIN_START, (ADHeaderFlow.BACKIN_OTHER_MIN + extra) / 2)
        if otherHit then
            return nil, string.format("objet fixe de l'autre côté du chemin, là où passe le nez du tracteur (%s)", tostring(otherName))
        end
        return s
    end
    local s, firstWhy, firstCode = nil, nil, nil
    for i, b in ipairs(biases) do
        local sb, whyB, codeB = tryBias(b)
        if sb ~= nil then
            if i > 1 then
                log("%s : décalé de %.1f m vers le champ (bande d'herbe jusqu'à la culture à %.1f m)", nameOf(t), b, edge)
            end
            s = sb
            break
        end
        log("%s : décalage de %.1f m vers le champ : non (%s)", nameOf(t), b, tostring(whyB))
        if b == 0 then
            firstWhy, firstCode = whyB, codeB
        elseif firstWhy == nil then
            firstWhy = whyB
        end
    end
    if s == nil then
        return nil, firstWhy, firstCode
    end
    local reach, qx, qz, uQ, uStop = s.reach, s.qx, s.qz, s.uQ, s.stop
    local bias = s.bias
    -- (16/11) entre le chemin et la place de la remorque reculée : un objet fixe (muret, clôture) ferme le champ
    local closed, closedName = ADHeaderFlow.backInSweepHit(t, job, { rig = rig, theta = theta, ux = ux, uz = uz, nx = nx, nz = nz,
        qx = qx, qz = qz, ax = ax, az = az, reach = reach })
    if not closed then
        closed, closedName = ADHeaderFlow.fixedHit(t, job, rootX, rootZ, tfx, tfz, trailerWidth / 2 + ADHeaderFlow.BACKIN_SWEEP_MARGIN,
            ((job.trailer.size ~= nil and job.trailer.size.length) or 12) / 2)
    end
    if closed then
        return nil, string.format("champ fermé : objet fixe entre le chemin et la place de la remorque (%s)", tostring(closedName)), "closed"
    end
    -- obstacle (arbre, clôture, bâtiment, véhicule) là où la remorque recule et finit, ou devant le cadre de la barre
    local trailerLength = (job.trailer.size ~= nil and job.trailer.size.length) or 12
    local hit = boxHit(t, (qx + axleX) / 2, (qz + axleZ) / 2, tfx, tfz, trailerWidth / 2 + ADHeaderFlow.BACKIN_OBSTACLE_MARGIN, reach / 2 + 1)
        or boxHit(t, rootX, rootZ, tfx, tfz, trailerWidth / 2 + ADHeaderFlow.BACKIN_OBSTACLE_MARGIN, trailerLength / 2)
        or boxHit(t, frameX + fx * (run / 2 + 0.5), frameZ + fz * (run / 2 + 0.5), fx, fz, rig.cw / 2 + ADHeaderFlow.BACKIN_OBSTACLE_MARGIN, run / 2)
    if hit then
        return nil, "obstacle dans l'entrée du champ (arbre, clôture, véhicule...)"
    end
    local plan = { j = info.j, jid = J.id, jx = J.x, jz = J.z, ux = ux, uz = uz, nx = nx, nz = nz, points = info.points, lengths = info.lengths,
        qx = qx, qz = qz, ax = ax, az = az, reach = reach, start = ADHeaderFlow.BACKIN_START, stop = uStop,
        frame = { x = frameX, y = groundY(frameX, frameZ), z = frameZ, dirX = fx, dirZ = fz }, past = uFrame - uE, depth = nFrame,
        edge = edge, before = before, rig = rig, entrance = { x = info.E.x, z = info.E.z }, bias = bias, shiftFrom = s.shiftFrom, shiftTo = s.shiftTo }
    -- la moissonneuse a sa courbe jusqu'au cadre prévu
    local laneC, laneWhy = ADHeaderFlow.backInLane(plan, plan.frame)
    if laneC == nil then
        return nil, laneWhy
    end
    plan.turn = laneC.turn
    -- (17/11, Champ 7) passage de la moissonneuse, du chemin jusque devant le cadre : pas d'objet fixe (poteau dans
    -- l'herbe du bord) ; sinon endroit plus loin le long du champ
    local hx, hz = plan.jx + plan.ux * laneC.handover, plan.jz + plan.uz * laneC.handover
    local curve = ADHeaderFlow.backInPath(laneC, hx, hz, plan.ux, plan.uz, plan.frame)
    if curve ~= nil then
        local cw = (rig.cw or 4) / 2 + ADHeaderFlow.BACKIN_OBSTACLE_MARGIN
        for k = 2, #curve do
            local p0, p1 = curve[k - 1], curve[k]
            local dx, dz = unit(p1.x - p0.x, p1.z - p0.z)
            if dx ~= nil then
                -- le point suivi de la moissonneuse et l'avant de sa caisse (cl / 2 m devant lui)
                local seg = MathUtil.vector2Length(p1.x - p0.x, p1.z - p0.z) / 2
                local q = (rig.cl or 10) / 4
                local mx, mz = (p0.x + p1.x) / 2, (p0.z + p1.z) / 2
                local hitC, nameC = ADHeaderFlow.fixedHit(t, job, mx + dx * q, mz + dz * q, dx, dz, cw, seg + q + 1)
                if hitC then
                    return nil, string.format("objet fixe (%s) sur le passage de la moissonneuse jusqu'au cadre", tostring(nameC))
                end
            end
        end
    end
    return plan
end

-- ------------------------------------------------------------------------------------------------------------
-- Tracteur : la route passe l'entrée, puis la marche arrière
-- ------------------------------------------------------------------------------------------------------------
-- la route du tracteur après l'entrée : dans l'axe du chemin, décalée peu à peu vers le champ, jusqu'au point d'arrêt.
-- (16/11) plan.routeFrom : m du chemin où elle commence (barre en travers du chemin : avant l'entrée)
function ADHeaderFlow.backInRoute(plan)
    local points = {}
    local function add(d)
        local side = 0
        if plan.bias > 0 then
            side = plan.bias * math.max(0, math.min(1, (d - plan.shiftFrom) / (plan.shiftTo - plan.shiftFrom)))
        end
        local x, z = plan.jx + plan.ux * d + plan.nx * side, plan.jz + plan.uz * d + plan.nz * side
        points[#points + 1] = { x = x, y = groundY(x, z), z = z, isPathFinderPoint = true }
    end
    local d = plan.routeFrom or ADHeaderFlow.BACKIN_ROUTE_STEP
    while d < plan.stop - 2 do
        add(d)
        d = d + ADHeaderFlow.BACKIN_ROUTE_STEP
    end
    add(plan.stop)
    return points
end

-- en route vers le champ, rien de dégagé près du bout : la route du tracteur continue sur le chemin jusqu'au point
-- d'où il reculera ; true = route changée
function ADHeaderFlow.backInTry(mode, job, wayPoints, current)
    if not ADHeaderFlow.BACKIN or ADHeaderBackInTask == nil then
        return false
    end
    local t = mode.vehicle
    local ok, plan, why, code = FarmPilotCall(ADHeaderFlow.backInPlan, t, job, wayPoints, current)
    if not ok then
        log("ERREUR marche arrière dans l'entrée du champ : %s", tostring(plan))
        return false
    end
    -- (17/11, Champ 7 : poteau au bord du chemin là où passe le nez du tracteur) refusée juste après l'entrée : la
    -- même marche arrière est essayée plus loin le long du champ, tous les BACKIN_SLIDE_STEP m
    if plan == nil and code == nil and ADHeaderFlow.BACKIN_SLIDE_MAX > 0 then
        log("%s : pas de marche arrière juste après l'entrée du champ (%s), essai plus loin le long du champ", nameOf(t), tostring(why))
        local slide = ADHeaderFlow.BACKIN_SLIDE_STEP
        while slide <= ADHeaderFlow.BACKIN_SLIDE_MAX do
            local okS, planS, whyS = FarmPilotCall(ADHeaderFlow.backInPlan, t, job, wayPoints, current, slide)
            if okS and planS ~= nil then
                log("%s : marche arrière possible %.0f m plus loin le long du champ", nameOf(t), slide)
                plan = planS
                break
            end
            log("%s : %.0f m plus loin : non (%s)", nameOf(t), slide, tostring(okS and whyS or planS))
            if okS and type(whyS) == "string" and whyS:find("chemin trop court", 1, true) then
                break
            end
            slide = slide + ADHeaderFlow.BACKIN_SLIDE_STEP
        end
    end
    if plan == nil then
        log("%s : pas de marche arrière dans l'entrée du champ (%s)", nameOf(t), tostring(why))
        -- (16/11) champ fermé par un objet fixe, ou cadre de la barre du côté du champ : la barre en travers du chemin
        -- (AutonomousHeaderCross.lua)
        if (code == "closed" or code == "frameSide") and ADHeaderFlow.crossTry ~= nil then
            return ADHeaderFlow.crossTry(mode, job, wayPoints, current)
        end
        return false
    end
    for k = #wayPoints, plan.j + 1, -1 do
        wayPoints[k] = nil
    end
    for _, p in ipairs(ADHeaderFlow.backInRoute(plan)) do
        wayPoints[#wayPoints + 1] = p
    end
    mode.headerBackIn = plan
    job.fieldSpot = { x = plan.entrance.x, z = plan.entrance.z } -- les autres endroits sont cherchés autour de l'entrée
    log("%s : bout de la route encombré côté barre, la remorque sera reculée dans le champ %.0f m après l'entrée (cadre à %.1f m du chemin, virage de %.0f° pour la moissonneuse) ; arrêt %.0f m après l'entrée, décalé de %.1f m vers le champ",
        nameOf(t), plan.past, plan.depth, plan.turn, plan.stop, plan.bias)
    return true
end

-- au bout de sa route : true = la marche arrière est lancée
function ADHeaderFlow.startBackIn(mode, job)
    local plan = mode.headerBackIn
    mode.headerBackIn = nil
    if plan == nil or job.phase ~= "deliver" or ADHeaderBackInTask == nil then
        return false
    end
    local t = mode.vehicle
    job.backInPlan = plan
    mode.headerStage = "backIn"
    mode.headerTask = ADHeaderBackInTask:new(t, job.trailer, plan)
    t.ad.taskModule:addTask(mode.headerTask)
    -- (16/11) même marche arrière pour la barre en travers du chemin (AutonomousHeaderCross.lua), autre message
    AutonomousMode.message(t, ADMessagesManager.messageTypes.INFO, 8000, plan.cross and "AD_autonomous_headerCross" or "AD_autonomous_headerBackIn")
    return true
end

local REASONS = { noTrailer = "pas de remorque à pousser", jackknife = "tracteur et remorque trop de travers",
    blocked = "quelque chose derrière la remorque", timeout = "pas finie à temps", badStart = "tracteur pas en place sur le chemin",
    stuck = "bloquée sans avancer (objet fixe)" }

-- marche arrière finie (result : voir Tasks/HeaderBackInTask.lua)
function ADHeaderFlow.backInDone(mode, job, result)
    local t = mode.vehicle
    local plan = job.backInPlan
    job.backInPlan = nil
    if t.ad.isStoppingWithError or plan == nil then
        job.cancelled = true
        ADHeaderFlow.stopHere(mode, nil)
        return
    end
    local why = nil
    if result ~= "ok" then
        why = REASONS[result] or tostring(result)
    else
        local lane, laneWhy = ADHeaderFlow.backInLane(plan, ADAutonomousManager.frontHitch(job.combine, job.header, true))
        if lane == nil then
            why = laneWhy
        else
            job.backIn = lane
            job.sideBlocked = nil
            log("%s : remorque reculée %s, cadre de la barre à %.0f° du chemin ; la moissonneuse lâchera la route %.0f m %s l'entrée",
                nameOf(t), plan.cross and "en travers du chemin" or "dans l'entrée du champ", lane.turn, math.abs(lane.handover), lane.handover < 0 and "avant" or "après")
        end
    end
    if why ~= nil then
        local what = plan.cross and "barre en travers du chemin" or "marche arrière dans l'entrée du champ"
        log("%s : %s pas réussie (%s)", nameOf(t), what, why)
        if result == "badStart" then
            -- rien n'a bougé : l'endroit est jugé comme d'habitude
            if ADHeaderFlow.onArrival(mode, job) then
                return
            end
        else
            -- (16/11) l'endroit est encombré : la place prévue de la remorque aussi (bloquée par un objet fixe)
            if result == "stuck" and ADHeaderFlow.rejectPlace ~= nil then
                ADHeaderFlow.rejectPlace(job, plan.frame.x, plan.frame.z)
            end
            if ADHeaderFlow.moveOn(mode, job, what .. " pas réussie", true) then
                return
            end
        end
    end
    ADHeaderFlow.tractorWait(mode, job)
end

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse : par le réseau jusqu'au chemin, puis la courbe jusqu'au cadre
-- ------------------------------------------------------------------------------------------------------------
-- la moissonneuse est encore avant l'endroit où elle lâche la route : elle y va par le réseau (point renvoyé)
function ADHeaderFlow.backInBefore(v, job)
    local lane = job ~= nil and job.backIn or nil
    if lane == nil or lane.targetId == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(v.components[1].node)
    if (x - lane.jx) * lane.ux + (z - lane.jz) * lane.uz >= lane.handover - 2 then
        return nil
    end
    return ADGraphManager:getWayPointById(lane.targetId)
end

-- en route vers la barre : true = sur le chemin, la route est lâchée. Dès l'endroit prévu si la courbe jusqu'au cadre
-- existe d'où elle est ; sinon (pas encore dans l'axe du chemin) elle continue sa route et la courbe est recalculée,
-- au plus tard jusqu'au début du virage
function ADHeaderFlow.backInHandover(mode, job, task)
    local lane = job.backIn
    local v = mode.vehicle
    local node = v.components[1].node
    local x, _, z = getWorldTranslation(node)
    local ox, oz = x - lane.jx, z - lane.jz
    local along = ox * lane.ux + oz * lane.uz
    if along < lane.handover or math.abs(ox * lane.uz - oz * lane.ux) > ADHeaderFlow.BACKIN_HANDOVER_SIDE then
        return false
    end
    local late = along >= (lane.latest or lane.handover)
    if not late and lane.nextTry ~= nil and (g_time or 0) < lane.nextTry then
        return false
    end
    lane.nextTry = (g_time or 0) + ADHeaderFlow.BACKIN_RETRY
    local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
    fx, fz = unit(fx, fz)
    local path = nil
    if fx ~= nil then
        path = ADHeaderFlow.backInPath(lane, x, z, fx, fz, ADAutonomousManager.frontHitch(job.combine, job.header, true))
    end
    if path == nil and not late then
        return false
    end
    lane.path = path
    log("%s : sur le chemin avant la barre (%.0f m %s l'entrée), on lâche la route pour la courbe jusqu'au cadre%s", nameOf(v),
        math.abs(along), along < 0 and "avant" or "après", path == nil and " (pas de courbe d'ici)" or "")
    task:finished()
    return true
end

-- chemin tout prêt de la tâche d'attelage (FetchToolTask.lua : presetPath) : la courbe d'où est la moissonneuse
-- jusque devant le cadre ; nil : recherche de chemin
function ADHeaderFlow.backInCurve(vehicle, job, hitch)
    local lane = job ~= nil and job.backIn or nil
    if lane == nil or hitch == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local fx, _, fz = localDirectionToWorld(vehicle.components[1].node, 0, 0, 1)
    fx, fz = unit(fx, fz)
    if fx == nil then
        return nil
    end
    local path, c, slant, final = ADHeaderFlow.backInPath(lane, x, z, fx, fz, hitch)
    if path == nil then
        -- celle calculée en lâchant la route, quelques mètres plus tôt
        path = lane.path
        lane.path = nil
        if path == nil then
            log("%s : pas de courbe d'ici jusqu'au cadre de la barre, recherche de chemin", nameOf(vehicle))
            return nil
        end
        log("%s : courbe jusque devant le cadre de la barre, celle calculée en lâchant la route", nameOf(vehicle))
        return path
    end
    lane.path = nil
    log("%s : courbe jusque devant le cadre de la barre (%.0f° puis %.0f°, %.1f m ; arrivée à %.1f m du cadre, %d° de biais)", nameOf(vehicle),
        math.deg(c.arc1), math.deg(c.arc2), c.length, final, slant)
    return path
end
