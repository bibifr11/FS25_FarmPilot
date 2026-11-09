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
-- Branché par une ligne dans DrivePathModule.lua : followWaypoints (limite de vitesse sur le réseau).
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
