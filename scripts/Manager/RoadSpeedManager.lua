-- ============================================================================================================
-- FarmPilot : RoadSpeedManager.lua
-- Vitesse par type de route : calcul d'itinéraire au temps réel, et vitesse maxi en conduite sur les secondaires.
--
-- (15/11) Le calcul d'AutoDrive comptait chaque segment au temps de trajet, mais avec une vitesse plafonnée à
-- 30 km/h pour tous : une grande ligne droite sur une route principale ne valait pas plus qu'une petite route
-- droite, seuls les virages faisaient la différence. Or une route principale n'est pas limitée, alors que les
-- secondaires et les tertiaires le sont.
--
-- Règles :
-- - Principale (et route d'accès) : vitesse du véhicule (réglage du HUD, bornée à sa vitesse maxi).
-- - Secondaire : réglage général « Vitesse maxi sur route secondaire », 35 km/h par défaut.
-- - Tertiaire : réglage général « Vitesse maxi sur route tertiaire » (DirtRoadManager.lua), 25 km/h par défaut.
-- - Virages : même vitesse selon l'angle qu'AutoDrive (getDriveTimeBetweenNodes), sauf la ligne droite (moins de
--   3°) qui n'est plus bornée à 50 km/h : seule la vitesse du type de route compte.
-- - Un segment prend le type le plus lent de ses deux points (tertiaire, puis secondaire, puis principale).
-- - Les coûts « Non » (x100), raccourci par une tertiaire, route d'accès traversée, passage étroit restent
--   ajoutés par-dessus, comme avant (DirtRoadManager.lua, AccessRoadManager.lua, PathCalculationWidth.lua).
-- - Conduite : le véhicule ne dépasse pas la vitesse des secondaires dessus, et ralentit LOOK_AHEAD m avant d'y
--   entrer (comme les tertiaires).
--
-- Branché par : PathCalculation.lua (fonction de coût), DrivePathModule.lua (vitesse maxi), register.lua (chargé
-- après DirtRoadManager.lua), gui/globalSettingsPage.xml (réglage).
-- ============================================================================================================

ADRoadSpeeds = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADRoadSpeeds.LOOK_AHEAD = 30                -- m : ralentir avant d'entrer sur une route secondaire
ADRoadSpeeds.STRAIGHT_ANGLE = 3             -- ° : en dessous, ligne droite (vitesse du type de route seulement)

-- vitesse selon l'angle du virage, comme ADGraphManager:getDriveTimeBetweenNodes (GraphManager.lua)
ADRoadSpeeds.ANGLE_SPEEDS = {
    { 5, 38 }, { 8, 27 }, { 12, 20 }, { 15, 13 }, { 20, 10 }, { 30, 7 }
}
ADRoadSpeeds.SHARP_SPEED = 4                -- km/h : virage de 30° ou plus

-- réglage général : onglet Général, sous la vitesse des tertiaires
AutoDrive.settings.secondaryRoadSpeed = {
    values = { 20, 25, 30, 35, 40, 45, 50 },
    texts = { "20 km/h", "25 km/h", "30 km/h", "35 km/h", "40 km/h", "45 km/h", "50 km/h" },
    default = 4,
    current = 4,
    text = "gui_ad_secondaryRoadSpeed",
    tooltip = "gui_ad_secondaryRoadSpeed_tooltip",
    translate = false,
    isVehicleSpecific = false,
    isUserSpecific = false
}

-- ------------------------------------------------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------------------------------------------------
function ADRoadSpeeds.getSecondarySpeed()
    return AutoDrive.getSetting("secondaryRoadSpeed") or 35
end

function ADRoadSpeeds.isSecondary(point)
    return point ~= nil and point.flags ~= nil and bit32.band(point.flags, AutoDrive.FLAG_SUBPRIO) > 0
end

-- vitesse maxi du type de route d'un segment a -> b (km/h, math.huge = pas de limite de type)
function ADRoadSpeeds.typeSpeed(a, b)
    if ADDirtRoads ~= nil and (ADDirtRoads.isDirt(a) or ADDirtRoads.isDirt(b)) then
        return ADDirtRoads.getMaxSpeed()
    end
    if ADRoadSpeeds.isSecondary(a) or ADRoadSpeeds.isSecondary(b) then
        return ADRoadSpeeds.getSecondarySpeed()
    end
    return math.huge
end

-- vitesse selon l'angle entre (c -> a) et (a -> b) ; math.huge en ligne droite
function ADRoadSpeeds.angleSpeed(a, b, c)
    if c == nil then
        return math.huge
    end
    local angle = math.abs(AutoDrive.angleBetween({ x = b.x - a.x, z = b.z - a.z }, { x = a.x - c.x, z = a.z - c.z }))
    if angle < ADRoadSpeeds.STRAIGHT_ANGLE then
        return math.huge
    end
    for _, entry in ipairs(ADRoadSpeeds.ANGLE_SPEEDS) do
        if angle < entry[1] then
            return entry[2]
        end
    end
    return ADRoadSpeeds.SHARP_SPEED
end

-- ------------------------------------------------------------------------------------------------------------
-- Calcul de route (PathCalculation.lua) : temps de trajet d'un segment, en secondes
-- ------------------------------------------------------------------------------------------------------------
-- f(a, b, previousId) : a et b sont des points du réseau, previousId l'id du point d'avant a (ou -1 / nil)
function ADRoadSpeeds.driveTimeFunc(vehicle)
    local routeSpeed = (ADDirtRoads ~= nil and ADDirtRoads.routeSpeed ~= nil) and ADDirtRoads.routeSpeed(vehicle) or 40
    local network = ADGraphManager:getWayPoints()
    local sqrt = math.sqrt
    local typeSpeed, angleSpeed = ADRoadSpeeds.typeSpeed, ADRoadSpeeds.angleSpeed
    return function(a, b, previousId)
        local dx, dz = b.x - a.x, b.z - a.z
        local distance = sqrt(dx * dx + dz * dz)
        local c = (previousId ~= nil and previousId ~= -1) and network[previousId] or nil
        local speed = math.min(routeSpeed, typeSpeed(a, b), angleSpeed(a, b, c))
        return distance / (math.max(speed, 1) / 3.6)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Conduite (DrivePathModule.lua) : vitesse maxi sur une route secondaire, ou avant d'y entrer ; math.huge ailleurs
-- ------------------------------------------------------------------------------------------------------------
function ADRoadSpeeds.getSpeedLimit(drivePathModule)
    local wayPoints = drivePathModule ~= nil and drivePathModule.wayPoints or nil
    if wayPoints == nil or drivePathModule.getCurrentWayPointIndex == nil then
        return math.huge
    end
    local index = drivePathModule:getCurrentWayPointIndex()
    local last = wayPoints[index - 1]
    if ADRoadSpeeds.isSecondary(last) then
        return ADRoadSpeeds.getSecondarySpeed()
    end
    -- distance comptée depuis le véhicule (sinon depuis le point déjà passé)
    local vehicle = drivePathModule.vehicle
    if vehicle ~= nil and vehicle.components ~= nil and vehicle.components[1] ~= nil and getWorldTranslation ~= nil then
        local x, _, z = getWorldTranslation(vehicle.components[1].node)
        last = { x = x, z = z }
    end
    local distance = 0
    local k = index
    while wayPoints[k] ~= nil and distance <= ADRoadSpeeds.LOOK_AHEAD do
        local wp = wayPoints[k]
        if last ~= nil and wp.x ~= nil and last.x ~= nil then
            distance = distance + MathUtil.vector2Length(wp.x - last.x, wp.z - last.z)
        end
        if ADRoadSpeeds.isSecondary(wp) and distance <= ADRoadSpeeds.LOOK_AHEAD then
            return ADRoadSpeeds.getSecondarySpeed()
        end
        last = wp
        k = k + 1
    end
    return math.huge
end
