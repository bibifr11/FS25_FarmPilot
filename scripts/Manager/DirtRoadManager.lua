-- ============================================================================================================
-- FarmPilot : DirtRoadManager.lua
-- 3e type de point du réseau : « chemin de terre », en plus des routes primaires et secondaires d'AutoDrive.
--
-- (08/11) Chemin préférentiel par véhicule, réglé dans le menu véhicule de FP (exemple : un semi ne prend jamais
-- de chemin).
-- Idem pour les tracteurs (dans le menu, les autoriser à prendre les chemins de terre) : un nouveau type de route,
-- 3e type de voie (les points).
-- Comme les vitesses y sont limitées, le temps de trajet compte : un chemin n'est pris que s'il fait gagner du
-- temps au total.
-- Couleurs : rose pour le sens unique, violet pour le double sens.
--
-- Règles :
-- - Éditeur : Maj gauche + clic sur un point (ou sur une section) fait tourner son type :
--   primaire -> secondaire -> chemin de terre -> primaire + intersection -> secondaire + intersection -> primaire.
-- - Réglage véhicule « Chemins de terre » : Auto (camions et semis : Jamais ; tracteurs et autres : Autorisés),
--   Jamais, Autorisés.
-- - Réglage général « Vitesse maxi sur chemin de terre » (30 km/h par défaut) : le véhicule ne la dépasse pas sur un
--   chemin de terre, et le calcul de route compte le temps de trajet à cette vitesse.
-- - Autorisés : le chemin de terre est pris seulement s'il fait gagner du temps (ou si la route est trop étroite).
-- - Jamais : un chemin de terre coûte 100 fois plus ; il n'est pris que s'il n'y a pas d'autre route (ou si la seule
--   autre route est trop étroite pour l'attelage). Le log le dit.
-- - Un segment est « chemin de terre » quand l'un de ses deux points l'est (comme les routes secondaires).
-- - Nom affiché « route tertiaire » (principale, secondaire, tertiaire ; le code garde « dirt »). Même option
--   pour les secondaires (Auto, Jamais ou Autorisé) :
--   réglage véhicule « Routes secondaires » :
--   Auto = tracteurs : raccourci au temps de trajet (les raccourcis sont permis sur les secondaires, ce n'était
--   pas le cas avant) ; camions et semis : comme AutoDrive d'origine (secondaire 20 fois
--   plus chère) ; Autorisées = au temps de trajet, comme une principale ; Jamais = 100 fois plus chère, seulement
--   s'il n'y a pas d'autre route.
-- - Une route tertiaire ne sert qu'à accéder à une destination, jamais autrement :
--   elle n'est permise que si elle touche le départ ou l'arrivée (la destination est
--   dessus ou au bout, ou le véhicule en repart). Jamais comme raccourci entre deux autres routes : ce passage coûte
--   ACCESS_WEIGHT, donc seulement s'il n'existe vraiment aucune autre route (le log le dit).
-- ============================================================================================================

ADDirtRoads = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADDirtRoads.NEVER_FACTOR = 100              -- coût d'un chemin de terre pour un véhicule « Jamais »
ADDirtRoads.SEARCH_SPEED = 30               -- km/h : vitesse maxi du calcul de route d'AutoDrive (PathCalculation.lua)
ADDirtRoads.DEFAULT_ROUTE_SPEED = 40        -- km/h : vitesse sur route quand le calcul se fait sans véhicule
ADDirtRoads.TRUCK_SPEED = 75                -- km/h : au-delà, un véhicule hors catégorie tracteur compte comme camion
ADDirtRoads.LOOK_AHEAD = 30                 -- m : ralentir avant d'entrer sur un chemin de terre

ADDirtRoads.ACCESS_WEIGHT = 1000000       -- tertiaire qui ne mène ni au départ ni à la destination : jamais (sauf seule route)
ADDirtRoads.SECONDARY_FACTOR_AUTO = 20      -- coût d'une route secondaire dans AutoDrive d'origine (PathCalculation.lua)

ADDirtRoads.MODE_AUTO = 1
ADDirtRoads.MODE_NEVER = 2
ADDirtRoads.MODE_ALLOWED = 3

-- couleurs de l'éditeur (08/11) : rose sens unique, violet double sens
AutoDrive.colors.ad_color_dirtSingleConnection = { 1, 0.41, 0.71, 1 }
AutoDrive.colors.ad_color_dirtDualConnection = { 0.6, 0.2, 1, 1 }
AutoDrive.colors.ad_color_dirtNode = { 1, 0.41, 0.71, 0.3 }

-- réglage véhicule : menu véhicule FP
AutoDrive.settings.dirtRoads = {
    values = { ADDirtRoads.MODE_AUTO, ADDirtRoads.MODE_NEVER, ADDirtRoads.MODE_ALLOWED },
    texts = { "gui_ad_dirtRoads_auto", "gui_ad_dirtRoads_never", "gui_ad_dirtRoads_allowed" },
    default = 1,
    current = 1,
    text = "gui_ad_dirtRoads",
    tooltip = "gui_ad_dirtRoads_tooltip",
    translate = true,
    isVehicleSpecific = true,
    isUserSpecific = false,
    isCopyPaste = true
}

-- réglage véhicule : routes secondaires (08/11)
AutoDrive.settings.secondaryRoads = {
    values = { ADDirtRoads.MODE_AUTO, ADDirtRoads.MODE_NEVER, ADDirtRoads.MODE_ALLOWED },
    texts = { "gui_ad_secondaryRoads_auto", "gui_ad_dirtRoads_never", "gui_ad_dirtRoads_allowed" },
    default = 1,
    current = 1,
    text = "gui_ad_secondaryRoads",
    tooltip = "gui_ad_secondaryRoads_tooltip",
    translate = true,
    isVehicleSpecific = true,
    isUserSpecific = false,
    isCopyPaste = true
}

-- réglage général : menu général FP
AutoDrive.settings.dirtRoadSpeed = {
    values = { 15, 20, 25, 30, 35, 40, 50 },
    texts = { "15 km/h", "20 km/h", "25 km/h", "30 km/h", "35 km/h", "40 km/h", "50 km/h" },
    default = 4,
    current = 4,
    text = "gui_ad_dirtRoadSpeed",
    tooltip = "gui_ad_dirtRoadSpeed_tooltip",
    translate = false,
    isVehicleSpecific = false,
    isUserSpecific = false
}

local function log(fmt, ...)
    print("[FarmPilot Routes] " .. string.format(fmt, ...))
end
ADDirtRoads.log = log

-- ------------------------------------------------------------------------------------------------------------
-- Points et types
-- ------------------------------------------------------------------------------------------------------------
-- point du réseau (table avec flags) : chemin de terre ?
function ADDirtRoads.isDirt(point)
    return point ~= nil and point.flags ~= nil and bit32.band(point.flags, AutoDrive.FLAG_DIRT_ROAD) > 0
end

function ADDirtRoads.isDirtId(wayPointId)
    return wayPointId ~= nil and ADDirtRoads.isDirt(ADGraphManager:getWayPointById(wayPointId))
end

-- type suivant (Maj gauche + clic) : primaire -> secondaire -> chemin de terre -> primaire + intersection ->
-- secondaire + intersection -> primaire ; les autres drapeaux (point de champ…) sont gardés
function ADDirtRoads.nextFlags(flags)
    flags = flags or 0
    local SUB, INTER, DIRT = AutoDrive.FLAG_SUBPRIO, AutoDrive.FLAG_INTERSECTION, AutoDrive.FLAG_DIRT_ROAD
    local others = bit32.band(flags, bit32.bnot(SUB + INTER + DIRT))
    local subPrio = bit32.band(flags, SUB) > 0
    local intersection = bit32.band(flags, INTER) > 0
    local dirt = bit32.band(flags, DIRT) > 0
    if intersection then
        if subPrio or dirt then
            return others                       -- secondaire + intersection -> primaire
        end
        return others + SUB + INTER             -- primaire + intersection -> secondaire + intersection
    end
    if dirt then
        return others + INTER                   -- chemin de terre -> primaire + intersection
    end
    if subPrio then
        return others + DIRT                    -- secondaire -> chemin de terre
    end
    return others + SUB                         -- primaire -> secondaire
end

-- nouveaux points d'une courbe (ou d'une ligne) entre deux points : chemin de terre si l'un des deux bouts l'est
-- (sauf si la courbe est déjà secondaire)
function ADDirtRoads.inheritFlags(flags, startId, targetId)
    flags = flags or 0
    if bit32.band(flags, AutoDrive.FLAG_SUBPRIO) > 0 or bit32.band(flags, AutoDrive.FLAG_DIRT_ROAD) > 0 then
        return flags
    end
    if ADDirtRoads.isDirtId(startId) or ADDirtRoads.isDirtId(targetId) then
        return flags + AutoDrive.FLAG_DIRT_ROAD
    end
    return flags
end

-- ------------------------------------------------------------------------------------------------------------
-- Véhicule : Jamais / Autorisés
-- ------------------------------------------------------------------------------------------------------------
-- camion (semi, porteur) : catégorie « TRUCKS » du magasin ; hors catégorie tracteur, vitesse maxi > 75 km/h
function ADDirtRoads.isTruck(vehicle)
    if vehicle == nil then
        return false
    end
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if root.fpIsTruck ~= nil then
        return root.fpIsTruck
    end
    local isTruck = false
    local item = (g_storeManager ~= nil and root.configFileName ~= nil) and g_storeManager:getItemByXMLFilename(root.configFileName) or nil
    local category = item ~= nil and item.categoryName ~= nil and string.upper(tostring(item.categoryName)) or ""
    if category == "TRUCKS" then
        isTruck = true
    elseif string.find(category, "TRACTOR", 1, true) == nil then
        local motor = root.spec_motorized ~= nil and root.spec_motorized.motor or nil
        local maxKmh = (motor ~= nil and motor.maxForwardSpeed ~= nil) and motor.maxForwardSpeed * 3.6 or 0
        isTruck = maxKmh > ADDirtRoads.TRUCK_SPEED
    end
    root.fpIsTruck = isTruck
    return isTruck
end

-- chemins de terre autorisés pour ce véhicule ? (et pourquoi, pour le log)
function ADDirtRoads.isAllowed(vehicle)
    local mode = ADDirtRoads.MODE_AUTO
    if vehicle ~= nil then
        mode = AutoDrive.getSetting("dirtRoads", vehicle) or ADDirtRoads.MODE_AUTO
    end
    if mode == ADDirtRoads.MODE_NEVER then
        return false, "réglage Jamais"
    elseif mode == ADDirtRoads.MODE_ALLOWED then
        return true, "réglage Autorisés"
    end
    if ADDirtRoads.isTruck(vehicle) then
        return false, "Auto : camion"
    end
    return true, "Auto"
end

function ADDirtRoads.getMaxSpeed()
    return AutoDrive.getSetting("dirtRoadSpeed") or 30
end

-- vitesse du véhicule sur la route (réglage du HUD, bornée à sa vitesse maxi)
function ADDirtRoads.routeSpeed(vehicle)
    local speed = ADDirtRoads.DEFAULT_ROUTE_SPEED
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.getSpeedLimit ~= nil then
        speed = vehicle.ad.stateModule:getSpeedLimit() or speed
        if AutoDrive.getVehicleMaxSpeed ~= nil then
            local ok, maxSpeed = FarmPilotCall(AutoDrive.getVehicleMaxSpeed, vehicle)
            if ok and maxSpeed ~= nil and maxSpeed > 0 then
                speed = math.min(speed, maxSpeed)
            end
        end
    end
    return math.max(speed, 1)
end

-- ------------------------------------------------------------------------------------------------------------
-- Calcul de route (PathCalculation.lua) : temps de trajet
-- ------------------------------------------------------------------------------------------------------------
-- Le calcul d'AutoDrive compte chaque segment au temps de trajet, vitesse bornée à 30 km/h (virages plus lents).
-- Sur un chemin de terre, le véhicule roule au plus à la vitesse du chemin au lieu de sa vitesse de route : à la
-- même échelle, la borne devient 30 x vitesse du chemin / vitesse de route. Un véhicule « Jamais » paie en plus x100.
-- routes tertiaires d'accès : la tertiaire où se trouve le départ (véhicule dessus), et celle où se
-- trouve la destination ou qui y mène (destination dessus ou juste au bout) ; { [id] = true }
function ADDirtRoads.accessPoints(startID, targetID)
    local access = {}
    local network = ADGraphManager:getWayPoints()
    if network == nil then
        return access
    end
    local queue = {}
    local function push(id)
        local p = id ~= nil and network[id] or nil
        if p ~= nil and not access[id] and ADDirtRoads.isDirt(p) then
            access[id] = true
            queue[#queue + 1] = p
        end
    end
    -- départ : seulement s'il est lui-même sur la tertiaire (un départ à côté d'une tertiaire n'en fait pas un raccourci)
    push(startID)
    -- destination : dessus, ou au bout (point voisin)
    local target = targetID ~= nil and network[targetID] or nil
    if target ~= nil then
        push(targetID)
        for _, n in pairs(target.out or {}) do push(n) end
        for _, n in pairs(target.incoming or {}) do push(n) end
    end
    local i = 1
    while queue[i] ~= nil do
        local p = queue[i]
        i = i + 1
        for _, n in pairs(p.out or {}) do push(n) end
        for _, n in pairs(p.incoming or {}) do push(n) end
    end
    return access
end

function ADDirtRoads.wrapDriveTime(baseFunc, vehicle, startID, targetID)
    local access = ADDirtRoads.accessPoints(startID, targetID)
    local accessWeight = ADDirtRoads.ACCESS_WEIGHT
    local allowed = ADDirtRoads.isAllowed(vehicle)
    local routeSpeed = ADDirtRoads.routeSpeed(vehicle)
    local dirtSpeed = math.min(routeSpeed, ADDirtRoads.getMaxSpeed())
    local cap = ADDirtRoads.SEARCH_SPEED * dirtSpeed / routeSpeed
    local factor = allowed and 1 or ADDirtRoads.NEVER_FACTOR
    local isDirt = ADDirtRoads.isDirt
    return function(a, b, c)
        if isDirt(a) or isDirt(b) then
            local through = (isDirt(a) and not access[a.id]) or (isDirt(b) and not access[b.id])
            return ADGraphManager:getDriveTimeBetweenNodes(a.id, b.id, c, cap, true) * factor + (through and accessWeight or 0)
        end
        return baseFunc(a, b, c)
    end
end

-- routes secondaires : coût par véhicule (réglage « Routes secondaires », 08/11)
function ADDirtRoads.secondaryFactor(vehicle)
    local mode = ADDirtRoads.MODE_AUTO
    if vehicle ~= nil and AutoDrive.getSetting ~= nil then
        mode = AutoDrive.getSetting("secondaryRoads", vehicle) or ADDirtRoads.MODE_AUTO
    end
    if mode == ADDirtRoads.MODE_NEVER then
        return ADDirtRoads.NEVER_FACTOR
    elseif mode == ADDirtRoads.MODE_ALLOWED then
        return 1
    end
    -- Auto : raccourcis permis sur les secondaires :
    -- tracteurs = raccourci pris dès qu'il fait gagner du temps ; camions et semis = comme AutoDrive d'origine (x20)
    -- (calcul sans véhicule : comme AutoDrive d'origine)
    if vehicle == nil or ADDirtRoads.isTruck(vehicle) then
        return ADDirtRoads.SECONDARY_FACTOR_AUTO
    end
    return 1
end

-- ------------------------------------------------------------------------------------------------------------
-- Conduite (DrivePathModule.lua) : vitesse limitée et log de la route
-- ------------------------------------------------------------------------------------------------------------
-- vitesse maxi sur le segment en cours, ou avant d'entrer sur un chemin de terre ; math.huge ailleurs
function ADDirtRoads.getSpeedLimit(drivePathModule)
    local wayPoints = drivePathModule ~= nil and drivePathModule.wayPoints or nil
    if wayPoints == nil then
        return math.huge
    end
    local index = drivePathModule:getCurrentWayPointIndex()
    local last = wayPoints[index - 1]
    if ADDirtRoads.isDirt(last) then
        return ADDirtRoads.getMaxSpeed()
    end
    -- distance comptée depuis le véhicule (sinon depuis le point déjà passé)
    local vehicle = drivePathModule.vehicle
    if vehicle ~= nil and vehicle.components ~= nil and vehicle.components[1] ~= nil and getWorldTranslation ~= nil then
        local x, _, z = getWorldTranslation(vehicle.components[1].node)
        last = { x = x, z = z }
    end
    local distance = 0
    local k = index
    while wayPoints[k] ~= nil and distance <= ADDirtRoads.LOOK_AHEAD do
        local wp = wayPoints[k]
        if last ~= nil and wp.x ~= nil and last.x ~= nil then
            distance = distance + MathUtil.vector2Length(wp.x - last.x, wp.z - last.z)
        end
        if ADDirtRoads.isDirt(wp) and distance <= ADDirtRoads.LOOK_AHEAD then
            return ADDirtRoads.getMaxSpeed()
        end
        last = wp
        k = k + 1
    end
    return math.huge
end

-- une ligne de log par nouvelle route qui passe par un chemin de terre
function ADDirtRoads.logRoute(vehicle, wayPoints)
    if vehicle == nil or wayPoints == nil then
        return
    end
    local count = 0
    for _, wp in ipairs(wayPoints) do
        if ADDirtRoads.isDirt(wp) then
            count = count + 1
        end
    end
    if count == 0 then
        vehicle.fpDirtRouteLog = nil
        return
    end
    local lastWp = wayPoints[#wayPoints]
    local key = tostring(lastWp ~= nil and lastWp.id or "?") .. ":" .. count
    if vehicle.fpDirtRouteLog == key then
        return
    end
    vehicle.fpDirtRouteLog = key
    local name = (vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil) and vehicle.ad.stateModule:getName() or tostring(vehicle.getName ~= nil and vehicle:getName() or "?")
    local allowed, why = ADDirtRoads.isAllowed(vehicle)
    -- tertiaire prise ailleurs qu'à l'accès au départ / à la destination : seulement faute d'autre route
    local firstWp = wayPoints[1]
    local okA, access = FarmPilotCall(ADDirtRoads.accessPoints, firstWp ~= nil and firstWp.id or nil, lastWp ~= nil and lastWp.id or nil)
    local through = 0
    for _, wp in ipairs(wayPoints) do
        if ADDirtRoads.isDirt(wp) and okA and not access[wp.id] then
            through = through + 1
        end
    end
    if through > 0 then
        log("%s : route tertiaire prise en raccourci (%d points), seulement parce qu'il n'y a pas d'autre route", tostring(name), through)
    elseif allowed then
        log("%s : route tertiaire pour accéder à la destination (%d points, %d km/h maxi dessus, %s)", tostring(name), count, ADDirtRoads.getMaxSpeed(), why)
    else
        log("%s : routes tertiaires interdites (%s) mais pas d'autre route possible : je passe par la tertiaire (%d points)", tostring(name), why, count)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Dessin de l'éditeur (Specialization.lua, AutoDrive.lua)
-- ------------------------------------------------------------------------------------------------------------
-- couleurs de l'aperçu « type suivant » d'une section (Maj gauche maintenue)
function ADDirtRoads.previewColors(sectionWayPoint, single, dual)
    local nextFlags = ADDirtRoads.nextFlags(sectionWayPoint ~= nil and sectionWayPoint.flags or 0)
    local c = AutoDrive.currentColors
    if bit32.band(nextFlags, AutoDrive.FLAG_INTERSECTION) > 0 then
        return c.ad_color_intersectionConnection, c.ad_color_intersectionConnection
    elseif bit32.band(nextFlags, AutoDrive.FLAG_DIRT_ROAD) > 0 then
        return c.ad_color_dirtSingleConnection, c.ad_color_dirtDualConnection
    elseif bit32.band(nextFlags, AutoDrive.FLAG_SUBPRIO) > 0 then
        return c.ad_color_subPrioSingleConnection, c.ad_color_subPrioDualConnection
    end
    return c.ad_color_singleConnection or single, c.ad_color_dualConnection or dual
end

-- aperçu d'une courbe : rose / violet quand elle part ou arrive sur un chemin de terre
function ADDirtRoads.splinePreviewColor(startWp, endWp, isDual, collisionFree, color)
    if not collisionFree or startWp == nil or endWp == nil then
        return color
    end
    if ADDirtRoads.isDirtId(startWp.id) or ADDirtRoads.isDirtId(endWp.id) then
        return isDual and AutoDrive.currentColors.ad_color_dirtDualConnection or AutoDrive.currentColors.ad_color_dirtSingleConnection
    end
    return color
end

-- carte du menu : ligne rose (sens unique) ou violette (double sens)
function ADDirtRoads.mapColor(node, outNode, r, g, b, a)
    if not (ADDirtRoads.isDirt(node) or ADDirtRoads.isDirt(outNode)) or ADGraphManager:isReverseRoad(node, outNode) then
        return r, g, b, a
    end
    if ADGraphManager:isDualRoad(node, outNode) then
        return unpack(AutoDrive.currentColors.ad_color_dirtDualConnection)
    end
    return unpack(AutoDrive.currentColors.ad_color_dirtSingleConnection)
end
