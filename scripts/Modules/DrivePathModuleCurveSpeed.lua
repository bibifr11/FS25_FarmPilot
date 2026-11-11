-- ============================================================================================================
-- FarmPilot : DrivePathModuleCurveSpeed.lua
-- Complément de ADDrivePathModule (module AutoDrive d'origine) : vitesse dans les virages selon leur rayon réel.
--
-- (07/11) Dans les virages la vitesse était souvent trop haute et pas proportionnelle au virage.
--
-- Règle : rayon réel du virage = changement de cap / longueur de route sur une fenêtre de quelques mètres ; vitesse
-- du virage = racine(accélération latérale x rayon) x réglage « Vitesse en virage » ; freinage assez tôt pour
-- l'atteindre à l'entrée ; dans un virage qui limite, le freinage commence dès 2 km/h de trop.
-- La limite gardée entre deux calculs (une image sur 4) reste dans DrivePathModule.lua (followWaypoints), mêlée au
-- calcul d'origine.
--
-- (10/11) Angle serré entre deux segments : mêmes vitesses que la règle d'origine, mais freinage prévu selon la
-- distance (la limite ne saute plus quand le tracteur ralentit).
--
-- Branché par deux lignes dans DrivePathModule.lua : followWaypoints (limite de vitesse sur le réseau).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
-- (07/11) Vitesse souvent trop haute dans les virages, pas proportionnelle au virage :
-- l'angle entre deux points voisins ne dit pas si le virage est serré (un virage dessiné ou redessiné avec un point
-- tous les 2,5 m n'a que des petits angles). Ici : rayon réel du virage = changement de cap / longueur de route sur
-- une fenêtre de quelques mètres ; vitesse du virage = racine(accélération latérale x rayon) x réglage « Vitesse en
-- virage » ; et on freine assez tôt pour l'atteindre à l'entrée (décélération CURVE_BRAKE).
ADDrivePathModule.CURVE_WINDOW = 6          -- m de route (entre milieux de segments) pour mesurer le rayon
ADDrivePathModule.CURVE_LATERAL = 1.5       -- m/s² d'accélération latérale dans le virage
ADDrivePathModule.CURVE_BRAKE = 0.6         -- m/s² de décélération prévue avant le virage (freinage doux, commencé tôt)
ADDrivePathModule.CURVE_SPEED_DEVIATION = 2 -- km/h de trop tolérés avant de freiner quand un virage limite
ADDrivePathModule.CURVE_MIN_SPEED = 5       -- km/h
ADDrivePathModule.CURVE_RADIUS_MAX = 300    -- m : plus large = ligne droite
ADDrivePathModule.CURVE_LOOK_MIN = 40       -- m de route regardés au moins
ADDrivePathModule.CURVE_LOOK_MAX = 150      -- m au plus
ADDrivePathModule.CURVE_POINTS_MAX = 150    -- points regardés au plus
ADDrivePathModule.CURVE_BACK = 12           -- m de route regardés derrière le point visé
ADDrivePathModule.CURVE_REVERSAL = math.rad(135) -- changement de sens (marche arrière) : on s'arrête là

-- ------------------------------------------------------------------------------------------------------------
-- Limite de vitesse du virage
-- ------------------------------------------------------------------------------------------------------------
-- rayon (m) et début (m de route depuis le 1er point regardé) du virage le plus contraignant ; limite en km/h
function ADDrivePathModule:getCurveSpeedLimit()
    local wps = self.wayPoints
    local idx = self:getCurrentWayPointIndex()
    if wps == nil or idx == nil or wps[idx] == nil or self.isReversing then
        return math.huge
    end
    -- on part quelques points derrière : avec des points serrés, le point visé est souvent déjà après la fin du
    -- virage alors que le tracteur y est encore
    local first, back = idx, 0
    while first > 1 and idx - first < 10 do
        local a, b = wps[first - 1], wps[first]
        back = back + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        if back > ADDrivePathModule.CURVE_BACK then
            break
        end
        first = first - 1
    end
    first = math.max(1, math.min(first, idx - 1))
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local v = math.abs(self.vehicle.lastSpeedReal or 0) * 1000
    local look = math.min(ADDrivePathModule.CURVE_LOOK_MAX, math.max(ADDrivePathModule.CURVE_LOOK_MIN, v * v / (2 * ADDrivePathModule.CURVE_BRAKE) + 30))
    -- segments k (wps[k] -> wps[k+1]) : cap cumulé (sans saut à ±180°), position de leur milieu sur la route
    local cum, mid, s = {}, {}, 0
    local lastHeading = nil
    local vehAt = nil
    for k = first, math.min(#wps - 1, first + ADDrivePathModule.CURVE_POINTS_MAX) do
        local a, b = wps[k], wps[k + 1]
        if k == idx then
            -- position du véhicule sur la route : un peu avant le point visé
            vehAt = s - math.sqrt((a.x - x) ^ 2 + (a.z - z) ^ 2)
        end
        local dx, dz = b.x - a.x, b.z - a.z
        local len = math.sqrt(dx * dx + dz * dz)
        if len > 0.05 then
            local h = math.atan2(dx, dz)
            local c = 0
            if lastHeading ~= nil then
                local turn = (h - lastHeading + math.pi) % (2 * math.pi) - math.pi
                if math.abs(turn) >= ADDrivePathModule.CURVE_REVERSAL then
                    break
                end
                c = cum[#cum] + turn
            end
            lastHeading = h
            cum[#cum + 1] = c
            mid[#mid + 1] = s + len / 2
            s = s + len
            if vehAt ~= nil and s - vehAt > look then
                break
            end
        end
    end
    if #cum < 2 then
        return math.huge
    end
    vehAt = vehAt or 0
    local factor = AutoDrive.getSetting("cornerSpeed", self.vehicle) or 1
    local best = math.huge
    local m = 2
    for j = 1, #cum - 1 do
        if m <= j then
            m = j + 1
        end
        while m < #cum and mid[m] - mid[j] < ADDrivePathModule.CURVE_WINDOW do
            m = m + 1
        end
        local turn = math.abs(cum[m] - cum[j])
        local length = mid[m] - mid[j]
        -- fenêtre déjà derrière le tracteur : ne compte plus
        if turn > 0.001 and length > 0.5 and mid[m] >= vehAt - 1 then
            local radius = length / turn
            if radius < ADDrivePathModule.CURVE_RADIUS_MAX then
                local vb = math.sqrt(ADDrivePathModule.CURVE_LATERAL * radius) * factor
                local d = math.max(0, mid[j] - vehAt)
                local allowed = math.sqrt(vb * vb + 2 * ADDrivePathModule.CURVE_BRAKE * d) * 3.6
                if allowed < best then
                    best = allowed
                    self.curveRadius = radius
                    self.curveDistance = d
                end
            end
        end
    end
    if best == math.huge then
        self.curveRadius = nil
        return best
    end
    return math.max(ADDrivePathModule.CURVE_MIN_SPEED, best)
end

-- ------------------------------------------------------------------------------------------------------------
-- Limite de vitesse d'un angle serré entre deux segments
-- ------------------------------------------------------------------------------------------------------------
-- (10/11) la vitesse saccadait avant un angle serré (3-6-4-5-6 km/h). La règle d'origine (3 km/h au-dessus de 50°,
-- 12 à 60 km/h entre 5 et 50°) ne voyait l'angle que dans une distance qui raccourcit quand le tracteur ralentit :
-- une fois ralenti, l'angle sortait de la vue, la limite sautait, le tracteur réaccélérait, le revoyait, freinait...
-- Ici : mêmes vitesses à l'angle, mais chaque angle devant le tracteur donne sa vitesse AU point de l'angle et on
-- freine assez tôt pour l'atteindre (comme pour les virages) ; la limite ne dépend plus de la vitesse du tracteur.
ADDrivePathModule.ANGLE_MIN = 5 -- ° : en dessous, pas un angle

-- vitesse (km/h) à un angle de la route, règle d'origine d'AutoDrive
function ADDrivePathModule.speedForAngle(angle)
    if angle < ADDrivePathModule.ANGLE_MIN then
        return math.huge
    elseif angle < 50 then
        return 12 + 48 * (1 - math.clamp(angle - 5, 0, 25) / 25)
    end
    return 3
end

-- limite (km/h) de l'angle le plus contraignant devant le tracteur, à partir du point visé
function ADDrivePathModule:getAngleSpeedLimit()
    local wps = self.wayPoints
    local idx = self:getCurrentWayPointIndex()
    if wps == nil or idx == nil or idx < 2 or wps[idx] == nil or wps[idx + 1] == nil or self.isReversing then
        return math.huge
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local v = math.abs(self.vehicle.lastSpeedReal or 0) * 1000
    local look = math.min(ADDrivePathModule.CURVE_LOOK_MAX, math.max(ADDrivePathModule.CURVE_LOOK_MIN, v * v / (2 * ADDrivePathModule.CURVE_BRAKE) + 30))
    local factor = AutoDrive.getSetting("cornerSpeed", self.vehicle) or 1
    -- d : route entre le tracteur et le point k, moins la distance à laquelle un point compte comme atteint (le
    -- point visé passe alors au suivant) : la vitesse de l'angle est tenue à ce moment-là, comme avant
    local d = math.sqrt((wps[idx].x - x) ^ 2 + (wps[idx].z - z) ^ 2) - (self.min_distance or 0)
    local best = math.huge
    for k = idx, math.min(#wps - 1, idx + ADDrivePathModule.CURVE_POINTS_MAX) do
        local p, c, n = wps[k - 1], wps[k], wps[k + 1]
        local ax, az, bx, bz = c.x - p.x, c.z - p.z, n.x - c.x, n.z - c.z
        local la, lb = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
        if la > 0.05 and lb > 0.05 then
            local turn = math.abs((math.atan2(bx, bz) - math.atan2(ax, az) + math.pi) % (2 * math.pi) - math.pi)
            local vb = ADDrivePathModule.speedForAngle(math.deg(turn)) * factor / 3.6
            if vb < math.huge then
                best = math.min(best, math.sqrt(vb * vb + 2 * ADDrivePathModule.CURVE_BRAKE * math.max(0, d)) * 3.6)
            end
            if turn >= ADDrivePathModule.CURVE_REVERSAL then
                -- changement de sens (marche arrière) : au pas à ce point, comme avant, et rien à regarder au-delà
                break
            end
        end
        d = d + lb
        if d > look then
            break
        end
    end
    return best
end

-- (ADDrivePathModule:followWaypoints) la limite de l'angle, si elle est plus basse ; renvoie maxSpeedDiff
function ADDrivePathModule:applyAngleSpeedLimit(maxSpeedDiff)
    local angleLimit = self:getAngleSpeedLimit()
    if angleLimit < self.speedLimit then
        self.speedLimit = angleLimit
        -- comme pour un virage : on freine dès 2 km/h de trop, la limite baisse peu à peu jusqu'à l'angle
        maxSpeedDiff = math.min(maxSpeedDiff, ADDrivePathModule.CURVE_SPEED_DEVIATION)
    end
    return maxSpeedDiff
end

-- (ADDrivePathModule:followWaypoints) la limite du virage, si elle est plus basse ; renvoie maxSpeedDiff
function ADDrivePathModule:applyCurveSpeedLimit(maxSpeedDiff)
    local curveLimit = self:getCurveSpeedLimit()
    if curveLimit < self.speedLimit then
        self.speedLimit = curveLimit
        -- virage : on freine dès 2 km/h de trop (6 km/h ailleurs), sinon il entre trop vite
        maxSpeedDiff = math.min(maxSpeedDiff, ADDrivePathModule.CURVE_SPEED_DEVIATION)
    end
    return maxSpeedDiff
end
