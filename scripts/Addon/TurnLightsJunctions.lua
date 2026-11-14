-- ============================================================================================================
-- FarmPilot : TurnLightsJunctions.lua
-- Clignotant aux intersections du réseau, plus à l'angle en degrés (14/11).
--
-- Avant : TurnLightsBends.lua allume dès que la route tourne de l'angle réglé (« Clignotant automatique »),
-- donc aussi dans un simple virage de route, et pas toujours à un carrefour où la route choisie tourne peu.
--
-- Règles :
--  1. Un clignotant seulement à une INTERSECTION du réseau : point à 3 voisins ou plus (entrées et sorties),
--     point rouge (Intersection), ou point où le trajet entre dans le réseau / en sort (champ, cour, silo).
--     Un virage de route sans intersection : pas de clignotant, quel que soit son angle.
--  2. À l'intersection on compare la route choisie aux autres branches (cap d'arrivée sur APPROACH_SPAN m avant,
--     cap de sortie = direction de la route au bout de EXIT_SPAN m, pour qu'un raccord arrondi compte en entier) :
--      - la route choisie est la plus droite de toutes et tourne de moins de FOLLOW_ANGLE : on suit la route,
--        pas de clignotant (tout droit au carrefour, ou route principale qui s'incline, chemin qui part à côté) ;
--      - sinon, s'il tourne d'au moins MIN_TURN : clignotant du côté de la route choisie.
--  3. Entrée / sortie du réseau : clignotant si le trajet tourne d'au moins MIN_TURN.
--  4. Le clignotant s'allume quand l'intersection est à la « Distance clignotant » (réglage, 50 m par défaut),
--     reste tant que la sortie de l'intersection (EXIT_SPAN m après) est devant, puis s'éteint quand le
--     tracteur est droit (règle d'extinction de TurnLights.lua, inchangée).
--  5. Inchangé (TurnLightsBends.lua) : marche arrière, moteur coupé, arrêt (AutoDrive ne l'éteint plus).
--
-- Branché par : TurnLightsBends.lua (ADAddonTurnLightsBends.update appelle findTurn quand ACTIVE).
-- ============================================================================================================

ADAddonTurnLightsJunctions = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAddonTurnLightsJunctions.ACTIVE = true
ADAddonTurnLightsJunctions.APPROACH_SPAN = 12  -- m : cap d'arrivée pris sur cette longueur avant l'intersection
ADAddonTurnLightsJunctions.EXIT_SPAN = 15      -- m : cap de sortie pris sur cette longueur après l'intersection
ADAddonTurnLightsJunctions.MIN_TURN = 25       -- degrés : en dessous, la route choisie est « tout droit »
ADAddonTurnLightsJunctions.FOLLOW_ANGLE = 60   -- degrés : route la plus droite et moins que ça = on suit la route
ADAddonTurnLightsJunctions.BACK_ANGLE = 150    -- degrés : branche qui repart en arrière (autre voie) : ignorée
ADAddonTurnLightsJunctions.BACK_SPAN = 20      -- m : intersection passée encore regardée (sortie pas finie)
ADAddonTurnLightsJunctions.CUSP_ANGLE = 150    -- degrés : demi-tour sur place (manœuvre) : fin de la recherche
ADAddonTurnLightsJunctions.LOG = true

-- ------------------------------------------------------------------------------------------------------------
-- Aides
-- ------------------------------------------------------------------------------------------------------------
local function angleOf(dx, dz, rx, rz)
    -- angle signé (degrés, gauche positif) pour aller du cap (rx, rz) au cap (dx, dz), comme TurnLights
    return ADAddonTurnLights.autoDrive.angleBetween({ x = dx, z = dz }, { x = rx, z = rz })
end

local function graphPoint(id)
    if id == nil or ADGraphManager == nil or ADGraphManager.getWayPointById == nil then
        return nil
    end
    return ADGraphManager:getWayPointById(id)
end

-- voisins d'un point du réseau (sorties et entrées, sans doublon)
local function neighbours(g)
    local seen, list = {}, {}
    for _, ids in ipairs({ g.out or {}, g.incoming or {} }) do
        for _, id in pairs(ids) do
            if not seen[id] then
                seen[id] = true
                list[#list + 1] = id
            end
        end
    end
    return list
end

function ADAddonTurnLightsJunctions.isJunction(g)
    if g == nil then
        return false
    end
    if AutoDrive ~= nil and AutoDrive.FLAG_INTERSECTION ~= nil and g.flags ~= nil and bit32.band(g.flags, AutoDrive.FLAG_INTERSECTION) > 0 then
        return true
    end
    return #neighbours(g) >= 3
end

-- point à 'span' m le long d'une branche du réseau partie de g vers firstId : à chaque point on prend la suite
-- la plus droite (un raccord arrondi est suivi jusqu'au bout)
local function branchEnd(g, firstId, span)
    local prev, cur = g, graphPoint(firstId)
    if cur == nil then
        return nil
    end
    local length = MathUtil.vector2Length(cur.x - prev.x, cur.z - prev.z)
    while length < span do
        local best, bestAngle = nil, nil
        for _, id in ipairs(neighbours(cur)) do
            local n = graphPoint(id)
            if n ~= nil and n ~= prev then
                local a = math.abs(angleOf(n.x - cur.x, n.z - cur.z, cur.x - prev.x, cur.z - prev.z))
                if a < 90 and (bestAngle == nil or a < bestAngle) then
                    best, bestAngle = n, a
                end
            end
        end
        if best == nil then
            break
        end
        length = length + MathUtil.vector2Length(best.x - cur.x, best.z - cur.z)
        prev, cur = cur, best
    end
    return cur, prev
end

-- le trajet suivi : points de 'back' m derrière à 'length' m devant (distance négative derrière), arrêt au demi-tour
local function route(module, length, back)
    local wayPoints = module.wayPoints
    local index = module:getCurrentWayPointIndex()
    if wayPoints == nil or index == nil or wayPoints[index] == nil then
        return {}
    end
    local x, _, z = getWorldTranslation(module.vehicle.components[1].node)
    local first = index
    local distance = MathUtil.vector2Length(wayPoints[index].x - x, wayPoints[index].z - z)
    while wayPoints[first - 1] ~= nil do
        local seg = MathUtil.vector2Length(wayPoints[first].x - wayPoints[first - 1].x, wayPoints[first].z - wayPoints[first - 1].z)
        if distance - seg < -back then
            break
        end
        first, distance = first - 1, distance - seg
    end
    local points = {}
    local i = first
    while wayPoints[i] ~= nil and distance <= length do
        local wp = wayPoints[i]
        points[#points + 1] = { wp = wp, distance = distance }
        local a, c = wayPoints[i - 1], wayPoints[i + 1]
        if c == nil then
            break
        end
        if a ~= nil and #points > 1 and math.abs(angleOf(c.x - wp.x, c.z - wp.z, wp.x - a.x, wp.z - a.z)) >= ADAddonTurnLightsJunctions.CUSP_ANGLE then
            break
        end
        distance = distance + MathUtil.vector2Length(c.x - wp.x, c.z - wp.z)
        i = i + 1
    end
    return points
end

-- point du trajet à 'span' m avant (step -1) ou après (step 1) le point k
local function along(points, k, step, span)
    local j = k
    while points[j + step] ~= nil and math.abs(points[j + step].distance - points[k].distance) < span do
        j = j + step
    end
    if points[j + step] ~= nil then
        j = j + step
    end
    return points[j]
end

-- ------------------------------------------------------------------------------------------------------------
-- Règles 1 à 3 : la décision à une intersection du trajet (point k)
-- Renvoie nil (pas une intersection), ou { direction = 1 gauche / -1 droite / 0 pas de clignotant, angle, why }
-- ------------------------------------------------------------------------------------------------------------
function ADAddonTurnLightsJunctions.decide(points, k)
    local self = ADAddonTurnLightsJunctions
    local p = points[k]
    local before, after = along(points, k, -1, self.APPROACH_SPAN), along(points, k, 1, self.EXIT_SPAN)
    if before == nil or after == nil or before == p or after == p then
        return nil
    end
    local wp = p.wp
    local rx, rz = wp.x - before.wp.x, wp.z - before.wp.z
    -- cap de sortie = direction du trajet au bout des EXIT_SPAN m (un raccord arrondi compte en entier)
    local ka = k
    while points[ka] ~= after do
        ka = ka + 1
    end
    local ap = points[ka - 1].wp
    local chosen = angleOf(after.wp.x - ap.x, after.wp.z - ap.z, rx, rz)
    local g = graphPoint(wp.id)
    local prevWp, nextWp = points[k - 1] and points[k - 1].wp, points[k + 1] and points[k + 1].wp
    -- règle 3 : entrée ou sortie du réseau
    if g ~= nil and ((prevWp ~= nil and prevWp.id == nil) or (nextWp ~= nil and nextWp.id == nil)) then
        if math.abs(chosen) >= self.MIN_TURN then
            return { direction = chosen > 0 and 1 or -1, angle = chosen, why = (nextWp ~= nil and nextWp.id == nil) and "sortie du reseau" or "entree dans le reseau" }
        end
        return { direction = 0, angle = chosen, why = "entree/sortie tout droit" }
    end
    if not self.isJunction(g) then
        return nil
    end
    -- règle 2 : la route choisie contre les autres branches
    local straightest = math.abs(chosen)
    local branches = 0
    for _, id in ipairs(neighbours(g)) do
        if (prevWp == nil or id ~= prevWp.id) and (nextWp == nil or id ~= nextWp.id) then
            local e, ep = branchEnd(g, id, self.EXIT_SPAN)
            if e ~= nil then
                local a = angleOf(e.x - ep.x, e.z - ep.z, rx, rz)
                if math.abs(a) < self.BACK_ANGLE then
                    branches = branches + 1
                    straightest = math.min(straightest, math.abs(a))
                end
            end
        end
    end
    if math.abs(chosen) < self.MIN_TURN then
        return { direction = 0, angle = chosen, why = "tout droit" }
    end
    if math.abs(chosen) <= straightest and math.abs(chosen) < self.FOLLOW_ANGLE then
        return { direction = 0, angle = chosen, why = "suit la route" }
    end
    return { direction = chosen > 0 and 1 or -1, angle = chosen, why = string.format("tourne (%d autre(s) branche(s))", branches) }
end

-- ------------------------------------------------------------------------------------------------------------
-- Règle 4 : la première intersection où le trajet tourne, à moins de maxDistance m, sortie pas encore passée.
-- Même forme que ADAddonTurnLightsBends.findBend : nil ou {direction, distance, angle, junction = true}
-- ------------------------------------------------------------------------------------------------------------
function ADAddonTurnLightsJunctions.findTurn(module, maxDistance)
    local self = ADAddonTurnLightsJunctions
    local points = route(module, maxDistance + self.EXIT_SPAN, self.BACK_SPAN + self.APPROACH_SPAN)
    module.adAddonJunctionLogged = module.adAddonJunctionLogged or {}
    for k, p in ipairs(points) do
        if p.distance > maxDistance then
            break
        end
        if p.distance >= -self.BACK_SPAN and p.wp.id ~= nil then
            local d = self.decide(points, k)
            if d ~= nil then
                local exit = along(points, k, 1, self.EXIT_SPAN)
                if exit ~= nil and exit.distance > 0 then
                    if self.LOG and module.adAddonJunctionLogged[p.wp.id] ~= d.direction then
                        module.adAddonJunctionLogged[p.wp.id] = d.direction
                        print(string.format("[AD-Clignotant] intersection %s dans %.0f m : %s, %.0f deg -> %s", tostring(p.wp.id),
                            math.max(0, p.distance), d.why, d.angle, d.direction > 0 and "gauche" or (d.direction < 0 and "droite" or "pas de clignotant")))
                    end
                    if d.direction ~= 0 then
                        return { direction = d.direction, distance = math.max(0, p.distance), angle = math.abs(d.angle), junction = true }
                    end
                end
            end
        end
    end
    return nil
end

