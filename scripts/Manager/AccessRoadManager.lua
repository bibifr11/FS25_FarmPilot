-- ============================================================================================================
-- FarmPilot : AccessRoadManager.lua
-- 4e type de point du réseau : « route d'accès » (12/11), en plus des routes primaires, secondaires et tertiaires.
--
-- Une route d'accès est interdite à tout : elle ne sert qu'à accéder au point qui est dessus ou au bout (exemple :
-- la route qui mène au garage). Elle n'est jamais prise en passage.
--
-- Règles :
-- - Éditeur : Maj gauche + clic sur un point (ou sur une section) fait tourner son type :
--   primaire -> secondaire -> tertiaire -> route d'accès -> primaire + intersection -> secondaire + intersection
--   -> tertiaire + intersection -> route d'accès + intersection -> primaire (DirtRoadManager.lua, nextFlags).
--   (15/11) Le point rouge (intersection) garde son type, comme sur une principale et une secondaire : dans
--   l'éditeur il est rouge (comme une secondaire + intersection), le calcul de route le compte en route d'accès.
-- - Couleurs (12/11) : orange foncé pour le sens unique, orange clair pour le double sens (tous deux distincts de
--   l'orange et du marron des secondaires ; modifiables dans « Choix des couleurs »).
-- - Tous les véhicules, sans réglage : la route d'accès est permise seulement si le départ est dessus (le véhicule en
--   repart) ou si la destination est dessus ou juste au bout. Depuis une route d'accès, une route tertiaire qui y
--   mène compte aussi comme accès (garage au bout d'un chemin de terre) ; l'inverse non.
-- - Ailleurs, la traverser coûte THROUGH_WEIGHT (plus cher qu'un raccourci par une tertiaire) : elle n'est prise
--   que s'il n'existe aucune autre route, et le journal le dit.
-- - Un segment est « route d'accès » quand l'un de ses deux points l'est (comme les secondaires et les tertiaires).
-- - Vitesse : pas de limite à part (celle de la route).
-- - Nouveaux points d'une courbe qui part ou arrive sur une route d'accès : route d'accès aussi.
--
-- Branché par une ligne chacune : DirtRoadManager.lua (nextFlags, inheritFlags, accessPoints, wrapDriveTime,
-- logRoute, couleurs) et Specialization.lua (dessin de l'éditeur). Drapeau AutoDrive.FLAG_ACCESS_ROAD = 64
-- (AutoDrive.lua), envoyé sur 7 bits (Sync.lua).
-- ============================================================================================================

ADAccessRoads = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- (15/11) plus cher qu'un passage trop étroit (NARROW_WEIGHT, PathCalculationWidth.lua, monté à 1 000 000 000) : l'ordre
-- reste route d'accès traversée > passage trop étroit > tertiaire en raccourci
ADAccessRoads.THROUGH_WEIGHT = 1000000000000 -- route d'accès traversée sans y accéder : seulement si aucune autre route

-- couleurs de l'éditeur : orange foncé sens unique, orange clair double sens (secondaires : orange 1 / 0.531 / 0.14,
-- marron 0.389 / 0.177 / 0)
AutoDrive.colors.ad_color_accessSingleConnection = { 0.85, 0.33, 0, 1 }
AutoDrive.colors.ad_color_accessDualConnection = { 1, 0.75, 0.4, 1 }
AutoDrive.colors.ad_color_accessNode = { 0.85, 0.33, 0, 0.3 }

-- premières couleurs (jaune, jaune foncé) : si le fichier des couleurs les a gardées, elles ne remplacent pas les
-- nouvelles (XML.lua, lecture de AutoDrive_LocalSettings.xml)
ADAccessRoads.OLD_DEFAULT_COLORS = {
    ad_color_accessSingleConnection = { 1, 0.9, 0 },
    ad_color_accessDualConnection = { 0.6, 0.5, 0 },
    ad_color_accessNode = { 1, 0.9, 0 },
}

function ADAccessRoads.isOldDefaultColor(colorKey, r, g, b)
    local old = ADAccessRoads.OLD_DEFAULT_COLORS[colorKey]
    return old ~= nil and math.abs((r or -1) - old[1]) < 0.002 and math.abs((g or -1) - old[2]) < 0.002 and math.abs((b or -1) - old[3]) < 0.002
end

-- ------------------------------------------------------------------------------------------------------------
-- Points et types
-- ------------------------------------------------------------------------------------------------------------
function ADAccessRoads.isAccess(point)
    return point ~= nil and point.flags ~= nil and AutoDrive.FLAG_ACCESS_ROAD ~= nil and bit32.band(point.flags, AutoDrive.FLAG_ACCESS_ROAD) > 0
end

function ADAccessRoads.isAccessId(wayPointId)
    return wayPointId ~= nil and ADAccessRoads.isAccess(ADGraphManager:getWayPointById(wayPointId))
end

-- courbe entre deux points : route d'accès si l'un des deux bouts l'est (passe avant secondaire et tertiaire)
function ADAccessRoads.inheritFlags(flags, startId, targetId)
    if ADAccessRoads.isAccessId(startId) or ADAccessRoads.isAccessId(targetId) then
        local others = bit32.band(flags or 0, bit32.bnot(AutoDrive.FLAG_SUBPRIO + AutoDrive.FLAG_DIRT_ROAD + AutoDrive.FLAG_ACCESS_ROAD))
        return others + AutoDrive.FLAG_ACCESS_ROAD
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Calcul de route : zone d'accès et coût
-- ------------------------------------------------------------------------------------------------------------
-- la zone d'accès (DirtRoadManager.lua, accessPoints) s'étend-elle de « from » à « to » ?
-- tertiaire -> tertiaire ; route d'accès -> route d'accès ou tertiaire ; tertiaire -> route d'accès : non
-- (une destination sur une tertiaire ne permet pas de traverser une route d'accès voisine)
function ADAccessRoads.canSpread(from, to)
    if ADAccessRoads.isAccess(to) then
        return from == nil or ADAccessRoads.isAccess(from)
    end
    return ADDirtRoads.isDirt(to)
end

-- poids ajouté à un segment : route d'accès traversée en dehors de la zone d'accès
function ADAccessRoads.extraCost(a, b, access)
    if (ADAccessRoads.isAccess(a) and not access[a.id]) or (ADAccessRoads.isAccess(b) and not access[b.id]) then
        return ADAccessRoads.THROUGH_WEIGHT
    end
    return 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Journal : une ligne par nouvelle route qui passe par une route d'accès
-- ------------------------------------------------------------------------------------------------------------
function ADAccessRoads.logRoute(vehicle, wayPoints, access, name)
    local count, through = 0, 0
    for _, wp in ipairs(wayPoints) do
        if ADAccessRoads.isAccess(wp) then
            count = count + 1
            if access ~= nil and not access[wp.id] then
                through = through + 1
            end
        end
    end
    if count == 0 then
        vehicle.fpAccessRouteLog = nil
        return
    end
    local lastWp = wayPoints[#wayPoints]
    local key = tostring(lastWp ~= nil and lastWp.id or "?") .. ":" .. count .. ":" .. through
    if vehicle.fpAccessRouteLog == key then
        return
    end
    vehicle.fpAccessRouteLog = key
    if through > 0 then
        ADDirtRoads.log("%s : route d'accès traversée (%d points), seulement parce qu'il n'y a pas d'autre route", tostring(name), through)
    else
        ADDirtRoads.log("%s : route d'accès pour accéder à la destination ou en repartir (%d points)", tostring(name), count)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Dessin de l'éditeur et de la carte
-- ------------------------------------------------------------------------------------------------------------
-- couleurs d'un segment entre deux points (route d'accès, sinon tertiaire) : sens unique, double sens ; nil sinon
function ADAccessRoads.lineColors(p1, p2)
    local c = AutoDrive.currentColors
    if ADAccessRoads.isAccess(p1) or ADAccessRoads.isAccess(p2) then
        return c.ad_color_accessSingleConnection, c.ad_color_accessDualConnection
    end
    if ADDirtRoads.isDirt(p1) or ADDirtRoads.isDirt(p2) then
        return c.ad_color_dirtSingleConnection, c.ad_color_dirtDualConnection
    end
    return nil, nil
end

-- couleur du point (sphère de l'éditeur) : route d'accès, sinon tertiaire
function ADAccessRoads.nodeColor(point)
    if ADAccessRoads.isAccess(point) then
        return AutoDrive.currentColors.ad_color_accessNode
    end
    return AutoDrive.currentColors.ad_color_dirtNode
end

-- point tertiaire ou route d'accès (dessinés avec leurs couleurs)
function ADAccessRoads.isTyped(point)
    return ADDirtRoads.isDirt(point) or ADAccessRoads.isAccess(point)
end
