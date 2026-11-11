-- ============================================================================================================
-- FarmPilot : TurnLightsBends.lua
-- Complément de TurnLights.lua (clignotant avant les virages) : quel virage mérite le clignotant, à quelle
-- distance il s'allume, et qui a le droit de l'éteindre. Branché par une ligne en tête de
-- ADAddonTurnLights.update (TurnLights.lua), qui passe la main à ADAddonTurnLightsBends.update.
--
-- (08/11, MF 7S.210 + plateau à balles) : il mettait son clignotant aussi pour un écart, et pas à la
-- bonne distance avant un virage.
--
-- Ce que dit le log (MF 7S.210, 19:31 → 19:56, heure du PC) :
--  - les 4 écarts autour de 'Objet de décoration 35' (19:35:28, 19:38:52, 19:50:45, 19:54:06) ne demandent
--    pas de clignotant : l'écart décale la ligne suivie, pas les points de la route ;
--  - l'ancien calcul additionne les angles de tous les points des 50/70 m devant le tracteur et s'allume au
--    point où la somme passe 70° : la distance n'est pas celle du début du virage. Carrefour 7044 (61°,
--    trajet retour) : allumé 22 m avant seulement, quand la courbe 30 m APRÈS le carrefour complète la somme ;
--  - le demi-tour en bout de route (point 7388, 179°, marche arrière) compte comme un virage à gauche
--    (19:36:26), puis le clignotant est remis par-dessus les feux de détresse de la marche arrière
--    (« éteint par un autre script (etat 3) », 19:36:39 → 19:38:03, 19:51:54 → 19:53:19) ;
--  - virage redessiné (points de virage, 2608-1627, 129°) : clignotant éteint 8 à 11 m après l'entrée dans la
--    partie redessinée, avant le virage (19:32:58 → 19:33:00, 19:48:20 → 19:48:25) ;
--  - à l'arrêt (croisement, file), AutoDrive éteint le clignotant à chaque image (« etat 0 », feux de détresse
--    en marche arrière) : c'est lui l'« autre script » des lignes « etat 0, remis » toutes les 5 s.
--
-- Règles :
--  1. Un virage = changement de cap durable : la somme des angles à partir du premier point qui tourne (sur
--     BEND_SPAN m) atteint l'angle réglé ; au carrefour (point du réseau à 3 voisins ou plus, ou point rouge)
--     JUNCTION_ANGLE fait sur JUNCTION_SPAN m suffit (une longue courbe de route qui passe un carrefour, non).
--  2. Un écart n'est pas un virage : la route revient à son cap de départ (à moitié de l'angle près) dans les
--     ECART_SPAN m, à moins de ECART_LATERAL m de sa ligne de départ : pas de clignotant.
--  3. Le clignotant s'allume quand le DÉBUT du virage (premier point qui tourne de START_ANGLE dans son sens)
--     est à la distance réglée ; le log dit cette distance.
--  4. Un demi-tour sur place (point de plus de CUSP_ANGLE, manœuvre) arrête la recherche : pas un virage.
--  5. Marche arrière : rien n'est touché, les feux de détresse d'AutoDrive restent.
--  6. Points d'un virage redessiné (isCornerPoint) : toujours la route, le clignotant reste jusqu'au bout.
--  7. Arrêté avec un clignotant demandé : AutoDrive ne l'éteint plus (il le faisait à chaque image).
--  8. Moteur coupé (arrêt prolongé) : clignotant éteint, pas rallumé tant que le moteur ne tourne pas (09/11).
-- ============================================================================================================

ADAddonTurnLightsBends = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAddonTurnLightsBends.NOISE_ANGLE = 2        -- degrés : en dessous, le point ne tourne pas
ADAddonTurnLightsBends.BEND_SPAN = 40         -- m : longueur sur laquelle un virage fait son angle
ADAddonTurnLightsBends.JUNCTION_ANGLE = 45    -- degrés : à un carrefour, ce virage suffit (si le réglage est plus grand)...
ADAddonTurnLightsBends.JUNCTION_SPAN = 15     -- m : ... s'il est fait sur cette longueur, le carrefour dedans
ADAddonTurnLightsBends.START_ANGLE = 5        -- degrés : début du virage = premier point qui tourne d'au moins ça dans son sens
ADAddonTurnLightsBends.ECART_SPAN = 40        -- m : un écart revient à son cap dans cette longueur
ADAddonTurnLightsBends.ECART_LATERAL = 6      -- m : et reste à moins de cette distance de sa ligne de départ
ADAddonTurnLightsBends.CUSP_ANGLE = 150       -- degrés : demi-tour sur place (marche arrière) : fin de la recherche
ADAddonTurnLightsBends.BACK_SPAN = 20         -- m : la recherche regarde aussi derrière (écart déjà commencé)
ADAddonTurnLightsBends.REVERSE_KMH = 0.5      -- km/h en arrière : marche arrière
ADAddonTurnLightsBends.LOG = true

-- ------------------------------------------------------------------------------------------------------------
-- Aides
-- ------------------------------------------------------------------------------------------------------------
local function vehicleName(vehicle)
    local ad = vehicle.ad
    if ad ~= nil and ad.stateModule ~= nil and ad.stateModule.getName ~= nil then
        return tostring(ad.stateModule:getName())
    end
    return tostring(vehicle.getName ~= nil and vehicle:getName() or vehicle.id)
end

local function log(vehicle, text, ...)
    if ADAddonTurnLightsBends.LOG then
        print(string.format("[AD-Clignotant] %s: " .. text, vehicleName(vehicle), ...))
    end
end

local function currentState(vehicle)
    local spec = vehicle.spec_lights
    return spec ~= nil and spec.turnLightState or nil
end

local function setting(name, default)
    local autoDrive = ADAddonTurnLights.autoDrive
    local value = autoDrive ~= nil and autoDrive.getSetting ~= nil and autoDrive.getSetting(name) or nil
    return value or default
end

-- angle signé (degrés, gauche positif) au point b, du segment a→b au segment b→c (comme TurnLights)
local function turnAngle(a, b, c)
    return ADAddonTurnLights.autoDrive.angleBetween({ x = c.x - b.x, z = c.z - b.z }, { x = b.x - a.x, z = b.z - a.z })
end

-- carrefour : point du réseau à 3 voisins ou plus (entrées et sorties), ou point rouge (Intersection)
function ADAddonTurnLightsBends.isJunction(wp)
    if wp == nil or wp.id == nil or ADGraphManager == nil or ADGraphManager.getWayPointById == nil then
        return false
    end
    local g = ADGraphManager:getWayPointById(wp.id)
    if g == nil then
        return false
    end
    if AutoDrive ~= nil and AutoDrive.FLAG_INTERSECTION ~= nil and g.flags ~= nil and bit32.band(g.flags, AutoDrive.FLAG_INTERSECTION) > 0 then
        return true
    end
    local seen, count = {}, 0
    for _, list in ipairs({ g.out or {}, g.incoming or {} }) do
        for _, id in pairs(list) do
            if not seen[id] then
                seen[id] = true
                count = count + 1
            end
        end
    end
    return count >= 3
end

-- la route autour du tracteur : points (x, z, angle au point, distance depuis le tracteur, négative derrière),
-- de 'back' m derrière jusqu'à 'length' m devant ou un demi-tour
function ADAddonTurnLightsBends.routeAhead(module, length, back)
    local wayPoints = module.wayPoints
    local index = module:getCurrentWayPointIndex()
    if wayPoints == nil or index == nil or wayPoints[index] == nil then
        return {}
    end
    local x, _, z = getWorldTranslation(module.vehicle.components[1].node)
    local prev = wayPoints[index - 1] or { x = x, z = z }
    local points = {}
    local distance = MathUtil.vector2Length(wayPoints[index].x - x, wayPoints[index].z - z)
    -- derrière (règle 2 : un écart dans lequel le tracteur est déjà engagé se voit en entier)
    local first, behind = index, distance
    while back ~= nil and back > 0 and wayPoints[first - 2] ~= nil do
        local seg = MathUtil.vector2Length(wayPoints[first].x - wayPoints[first - 1].x, wayPoints[first].z - wayPoints[first - 1].z)
        if behind - seg < -back or math.abs(turnAngle(wayPoints[first - 2], wayPoints[first - 1], wayPoints[first])) >= ADAddonTurnLightsBends.CUSP_ANGLE then
            break
        end
        first, behind = first - 1, behind - seg
    end
    local i = first
    distance = behind
    while wayPoints[i + 1] ~= nil and distance <= length do
        local ref = (i == index) and prev or (wayPoints[i - 1] or prev)
        local angle = turnAngle(ref, wayPoints[i], wayPoints[i + 1])
        if math.abs(angle) >= ADAddonTurnLightsBends.CUSP_ANGLE then
            points.cusp = distance
            break
        end
        points[#points + 1] = { wp = wayPoints[i], x = wayPoints[i].x, z = wayPoints[i].z, angle = angle, distance = distance,
            hx = wayPoints[i].x - ref.x, hz = wayPoints[i].z - ref.z }
        distance = distance + MathUtil.vector2Length(wayPoints[i + 1].x - wayPoints[i].x, wayPoints[i + 1].z - wayPoints[i].z)
        i = i + 1
    end
    return points
end

-- règle 2 : à partir du point s, la route revient-elle à son cap de départ près de sa ligne de départ ?
function ADAddonTurnLightsBends.isEcart(points, s, minAngle)
    local start = points[s]
    local hl = MathUtil.vector2Length(start.hx, start.hz)
    if hl < 0.001 then
        return false
    end
    local hx, hz = start.hx / hl, start.hz / hl
    local cumulated, peak = 0, 0
    for k = s, #points do
        local p = points[k]
        if p.distance - start.distance > ADAddonTurnLightsBends.ECART_SPAN then
            break
        end
        cumulated = cumulated + math.max(-90, math.min(90, p.angle))
        peak = math.max(peak, math.abs(cumulated))
        if peak >= minAngle * 0.5 and math.abs(cumulated) < minAngle * 0.5 and k > s then
            -- revenu au cap : à quelle distance de la ligne de départ ?
            local nxt = points[k + 1] or p
            local lateral = math.abs((nxt.x - start.x) * hz - (nxt.z - start.z) * hx)
            return lateral <= ADAddonTurnLightsBends.ECART_LATERAL, lateral
        end
    end
    return false
end

-- somme des angles (bornés à 90°) à partir du point s sur 'span' m : meilleure somme, indice où elle est atteinte,
-- et carrefour rencontré avant ce point
local function sweep(points, s, span)
    local self = ADAddonTurnLightsBends
    local cumulated, best, peak, junction, junctionAtPeak = 0, 0, s, false, false
    local e = s
    while points[e] ~= nil and points[e].distance - points[s].distance <= span do
        cumulated = cumulated + math.max(-90, math.min(90, points[e].angle))
        junction = junction or self.isJunction(points[e].wp)
        if math.abs(cumulated) > math.abs(best) then
            best, peak, junctionAtPeak = cumulated, e, junction
        end
        e = e + 1
    end
    return best, peak, junctionAtPeak
end

-- règles 1 à 4 : le premier virage devant dont le début est à moins de maxDistance m.
-- Renvoie nil ou {direction = 1 (gauche) / -1 (droite), distance = m jusqu'au début (0 : déjà commencé), angle, junction}
function ADAddonTurnLightsBends.findBend(module, maxDistance, minAngle)
    local self = ADAddonTurnLightsBends
    local points = self.routeAhead(module, maxDistance + self.BEND_SPAN + self.ECART_SPAN, self.BACK_SPAN)
    local junctionAngle = math.min(minAngle, self.JUNCTION_ANGLE)
    local s = 1
    while points[s] ~= nil and points[s].distance <= maxDistance do
        local p = points[s]
        if math.abs(p.angle) >= self.NOISE_ANGLE then
            -- virage : l'angle réglé sur BEND_SPAN m, ou au carrefour JUNCTION_ANGLE sur JUNCTION_SPAN m
            local best, peak = sweep(points, s, self.BEND_SPAN)
            local needed, junction = minAngle, false
            if math.abs(best) < minAngle then
                local shortBest, shortPeak, atJunction = sweep(points, s, self.JUNCTION_SPAN)
                if atJunction and math.abs(shortBest) >= junctionAngle then
                    best, peak, needed, junction = shortBest, shortPeak, junctionAngle, true
                end
            end
            if math.abs(best) >= needed then
                -- début du virage : les premiers points qui tournent peu ou dans l'autre sens n'en font pas partie
                local sign, rest, start = best > 0 and 1 or -1, math.abs(best), s
                while start < peak and points[start].angle * sign < self.START_ANGLE
                    and rest - math.max(-90, math.min(90, points[start].angle)) * sign >= needed do
                    rest = rest - math.max(-90, math.min(90, points[start].angle)) * sign
                    start = start + 1
                end
                local b = points[start]
                if b.distance > maxDistance then
                    return nil -- le début de ce virage n'est pas encore à la distance réglée
                end
                local ecart, lateral = self.isEcart(points, start, needed)
                if ecart then
                    module.adAddonEcartLogged = module.adAddonEcartLogged or {}
                    if not module.adAddonEcartLogged[b.wp] then
                        module.adAddonEcartLogged[b.wp] = true
                        log(module.vehicle, "ecart dans %.0f m (%.0f deg puis retour, %.1f m de cote) : pas de clignotant", math.max(0, b.distance), math.abs(best), lateral or -1)
                    end
                    -- l'écart (même déjà commencé) est passé en entier : la recherche reprend après lui
                    s = start
                    while points[s + 1] ~= nil and points[s + 1].distance - b.distance <= self.ECART_SPAN do
                        s = s + 1
                    end
                elseif points[peak].distance >= 0 then
                    return { direction = sign, distance = math.max(0, b.distance), angle = math.abs(best), junction = junction }
                end
                -- sinon : tout l'angle de ce virage est déjà derrière le tracteur, il est passé
            end
        end
        s = s + 1
    end
    return nil
end

-- clignotant déjà allumé : gardé tant qu'il reste KEEP_ANGLE de ce virage devant (comme TurnLights)
local function keepCurrent(module, current)
    local points = ADAddonTurnLightsBends.routeAhead(module, ADAddonTurnLightsBends.BEND_SPAN)
    local cumulated = 0
    for _, p in ipairs(points) do
        cumulated = cumulated + math.max(-90, math.min(90, p.angle))
        if cumulated * current >= ADAddonTurnLights.KEEP_ANGLE then
            return true
        end
    end
    return false
end

local function isMovingBackward(vehicle)
    local speed = (vehicle.lastSpeedReal or 0) * (vehicle.movingDirection or 1)
    return speed * 3600 < -ADAddonTurnLightsBends.REVERSE_KMH
end

-- règle 5
function ADAddonTurnLightsBends.isReversing(module)
    return (module.getIsReversing ~= nil and module:getIsReversing()) or isMovingBackward(module.vehicle)
end

-- règle 6 : sur la route du réseau, ou sur un point de virage redessiné ou décalé (poteau)
function ADAddonTurnLightsBends.isOnRoute(module)
    if module:isOnRoadNetwork() then
        return true
    end
    local wp = module.getCurrentWayPoint ~= nil and module:getCurrentWayPoint() or nil
    return wp ~= nil and (wp.isCornerPoint == true or wp.isShiftPoint == true)
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale : remplace ADAddonTurnLights.update (appelée par la ligne en tête de celle-ci)
-- ------------------------------------------------------------------------------------------------------------
function ADAddonTurnLightsBends.update(module, minAngle, dt)
    local vehicle = module.vehicle
    if ADAddonTurnLightsBends.isReversing(module) then
        if (module.adAddonBlinkDir or 0) ~= 0 then
            module.adAddonBlinkDir = 0
            module.adAddonBlinkClearX = nil
            log(vehicle, "marche arriere : clignotant laisse aux feux de detresse d'AutoDrive")
        end
        return
    end
    -- règle 8 (09/11) : moteur coupé à l'arrêt = clignotant éteint, pas rallumé. Avant, AutoDrive
    -- l'éteignait à chaque image et FarmPilot le rallumait (log « eteint par un autre script (etat 0), remis »).
    -- Moteur redémarré et virage toujours devant : il se rallume au passage suivant.
    if vehicle.getIsMotorStarted ~= nil and not vehicle:getIsMotorStarted() then
        if (module.adAddonBlinkDir or 0) ~= 0 then
            module.adAddonBlinkDir = 0
            module.adAddonBlinkClearX = nil
            if vehicle.setTurnLightState ~= nil then
                vehicle:setTurnLightState(Lights.TURNLIGHT_OFF)
            end
            log(vehicle, "moteur coupe : clignotant eteint")
        end
        return
    end
    local maxDistance = setting("blinkDistance", 50)
    local current = module.adAddonBlinkDir or 0
    local direction, bend = 0, nil
    if ADAddonTurnLightsBends.isOnRoute(module) then
        -- le virage en cours finit d'abord (il en reste KEEP_ANGLE devant), puis le suivant
        if current ~= 0 and keepCurrent(module, current) then
            direction = current
        else
            bend = ADAddonTurnLightsBends.findBend(module, maxDistance, minAngle)
            direction = bend ~= nil and bend.direction or 0
        end
    end
    if direction ~= 0 then
        module.adAddonBlinkClear = 0
        module.adAddonBlinkClearX = nil
        local wanted = direction > 0 and Lights.TURNLIGHT_LEFT or Lights.TURNLIGHT_RIGHT
        local before = currentState(vehicle)
        if current ~= direction then
            log(vehicle, "virage a %s : debut dans %.0f m (%.0f deg%s) : clignotant demande (reglage %d m, angle >= %d, etat avant %s)",
                direction > 0 and "gauche" or "droite", bend ~= nil and bend.distance or 0, bend ~= nil and bend.angle or 0,
                (bend ~= nil and bend.junction) and ", carrefour" or "", maxDistance, minAngle, tostring(before))
            module.adAddonResetLogTime = nil
        elseif before ~= wanted then
            local now = g_time or 0
            if module.adAddonResetLogTime == nil or now - module.adAddonResetLogTime >= ADAddonTurnLights.RESET_LOG_INTERVAL then
                module.adAddonResetLogTime = now
                log(vehicle, "clignotant eteint par un autre script (etat %s), remis", tostring(before))
            end
        end
        module.adAddonBlinkDir = direction
        vehicle:setTurnLightState(wanted, true)
    elseif current ~= 0 then
        -- plus de virage devant : gardé allumé jusqu'à ce que le tracteur soit de nouveau droit (comme TurnLights)
        local x, _, z = getWorldTranslation(vehicle.components[1].node)
        if module.adAddonBlinkClearX == nil then
            module.adAddonBlinkClearX, module.adAddonBlinkClearZ = x, z
        end
        local moved = MathUtil.vector2Length(x - module.adAddonBlinkClearX, z - module.adAddonBlinkClearZ)
        local err = ADAddonTurnLights.headingError(module)
        if (moved >= ADAddonTurnLights.AFTER_MIN and err <= ADAddonTurnLights.STRAIGHT_ANGLE) or moved >= ADAddonTurnLights.AFTER_MAX then
            module.adAddonBlinkDir = 0
            module.adAddonBlinkClearX = nil
            vehicle:setTurnLightState(Lights.TURNLIGHT_OFF)
            log(vehicle, "virage passe, tracteur droit (%.0f m apres, ecart %.0f deg) : clignotant eteint", moved, err)
        else
            local wanted = current > 0 and Lights.TURNLIGHT_LEFT or Lights.TURNLIGHT_RIGHT
            if currentState(vehicle) ~= wanted then
                vehicle:setTurnLightState(wanted, true)
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place : règle 7 (AutoDrive n'éteint plus à l'arrêt un clignotant demandé ; marche arrière inchangée)
-- ------------------------------------------------------------------------------------------------------------
function ADAddonTurnLightsBends.install(autoDrive)
    local original = autoDrive.updateAutoDriveLights
    if original == nil then
        return
    end
    autoDrive.updateAutoDriveLights = function(vehicle, switchOff, ...)
        local dpm = (not switchOff) and vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.drivePathModule or nil
        if dpm == nil or (dpm.adAddonBlinkDir or 0) == 0 or vehicle.setTurnLightState == nil or isMovingBackward(vehicle)
            or (vehicle.getIsMotorStarted ~= nil and not vehicle:getIsMotorStarted()) then
            return original(vehicle, switchOff, ...)
        end
        local own = rawget(vehicle, "setTurnLightState")
        local setter = vehicle.setTurnLightState
        vehicle.setTurnLightState = function(v, state, ...)
            if state == Lights.TURNLIGHT_OFF then
                return -- arrêté : le clignotant demandé reste
            end
            return setter(v, state, ...)
        end
        local ok, err = FarmPilotCall(original, vehicle, switchOff, ...)
        rawset(vehicle, "setTurnLightState", own)
        if not ok then
            error(err, 0)
        end
    end
end

ADAddon.addModule(ADAddonTurnLightsBends)
