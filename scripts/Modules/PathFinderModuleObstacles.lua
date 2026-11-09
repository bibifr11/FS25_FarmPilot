-- ============================================================================================================
-- FarmPilot : PathFinderModuleObstacles.lua
-- Complément de PathFinderModule : les obstacles.
-- - Hauteur du contrôle : hauteur réelle du train + 0,5 m (au moins 3 m) ; les branches au-dessus ne sont pas un mur.
-- - Zones interdites : là où le capteur avant a arrêté un véhicule sur un trajet calculé (obstacle que la recherche
--   ne voit pas), gardées 5 min pour tous les véhicules ; et les zones de contournement (27/10) d'ADObstacleDetourModule.
-- - Hors du champ, en grille fine : boîte d'obstacles élargie.
-- - Départ du trajet : le bout entre le véhicule et le point de départ est roulé sans contrôle, le départ est
--   rapproché si un arbre, un mur… s'y trouve ; départ depuis la pose donnée par l'appelant (morceau suivant).
--
-- Règle : une zone interdite compte comme un obstacle pour la grille, les raccourcis et les tronçons.
--
-- Branché par PathFinderModule.lua : reset (getTrainHeight), startPathPlanningTo (getStartPose,
-- getFreeStartDistance), checkGridCell / isDriveableAstar / isDriveableDubins / lissage (boxHitsBlockedZone),
-- getShapeDefByDirectionType (isOffFieldReduced) ; addLearnedZone par DrivePathModule.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Hauteur du train
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.OBSTACLE_HEIGHT_MARGIN = 0.5
PathFinderModule.OBSTACLE_MIN_HEIGHT = 3

function PathFinderModule.getTrainHeight(vehicle)
    local height = PathFinderModule.OBSTACLE_MIN_HEIGHT
    local vehicles = {vehicle}
    if vehicle.getChildVehicles ~= nil then
        vehicles = vehicle:getChildVehicles()
    end
    for _, v in pairs(vehicles) do
        if v.size ~= nil and v.size.height ~= nil then
            height = math.max(height, v.size.height)
        end
    end
    return height
end

-- ------------------------------------------------------------------------------------------------------------
-- Zones interdites (le capteur avant a arrêté un véhicule)
-- ------------------------------------------------------------------------------------------------------------
-- zones the pathfinder must avoid although overlapBox finds nothing there (set by ADObstacleDetourModule:
-- an obstacle the front sensor stopped on, which the route search does not see). {x, z, radius}
-- box as given to overlapBox (center, rotation around Y, half extents along local X and Z)
function PathFinderModule:boxHitsBlockedZone(cx, cz, ry, halfX, halfZ)
    local cosA, sinA = math.cos(ry), math.sin(ry)
    -- learned zones are tried again after LEARNED_ZONE_TTL: if the obstacle is still there the front sensor adds it back
    local now = g_time or 0
    for i = #PathFinderModule.learnedZones, 1, -1 do
        local zone = PathFinderModule.learnedZones[i]
        if now - (zone.time or now) > PathFinderModule.LEARNED_ZONE_TTL then
            table.remove(PathFinderModule.learnedZones, i)
            print(string.format("[AD-Fin] zone interdite en %.0f,%.0f retiree (%d min), elle sera retestee", zone.x, zone.z, PathFinderModule.LEARNED_ZONE_TTL / 60000))
        end
    end
    for _, zones in ipairs({self.blockedZones or {}, PathFinderModule.learnedZones}) do
        for _, zone in ipairs(zones) do
            local dx, dz = zone.x - cx, zone.z - cz
            local lx = dx * cosA - dz * sinA
            local lz = dx * sinA + dz * cosA
            if zone.byCenter then
                -- detour zones (27/10): only the cells whose center lies inside the zone, the box is not enlarged
                if dx * dx + dz * dz < zone.radius * zone.radius then
                    return true
                end
            elseif math.abs(lx) < halfX + zone.radius and math.abs(lz) < halfZ + zone.radius then
                return true
            end
        end
    end
    return false
end

-- places where the front sensor stopped a vehicle on a calculated route: kept for the whole session, for all vehicles
PathFinderModule.learnedZones = {}
PathFinderModule.LEARNED_ZONE_RADIUS = 4
PathFinderModule.LEARNED_ZONE_DELAY = 3000
PathFinderModule.LEARNED_ZONE_TTL = 300000 -- ms

function PathFinderModule.addLearnedZone(x, z, vehicleName)
    for _, zone in ipairs(PathFinderModule.learnedZones) do
        if MathUtil.vector2Length(zone.x - x, zone.z - z) < zone.radius then
            return
        end
    end
    table.insert(PathFinderModule.learnedZones, {x = x, z = z, radius = PathFinderModule.LEARNED_ZONE_RADIUS, time = g_time or 0})
    print(string.format("[AD-Fin] %s: zone interdite ajoutee en %.0f,%.0f (capteur avant bloque), %d zone(s)", tostring(vehicleName), x, z, #PathFinderModule.learnedZones))
end

-- ------------------------------------------------------------------------------------------------------------
-- Hors du champ en grille fine : boîte d'obstacles plus large
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.OFF_FIELD_EXTRA_MARGIN = 1.5

function PathFinderModule:isOffFieldReduced(x, z, isOnField)
    if self.gridScaleStep == nil or self.gridScaleStep <= 1 then
        return false
    end
    if isOnField == nil then
        isOnField = PathFinderModule.getMapOnFieldAt(x, z)
    end
    return not isOnField
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ du trajet
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.START_DISTANCES_SHORTER = {5, 3, 1.5}

-- longest start distance (up to PATHFINDER_START_DISTANCE) whose corridor, vehicle -> start point + turning radius at train width, hits no obstacle
function PathFinderModule:getFreeStartDistance(vehicleWorldX, vehicleWorldZ, dirX, dirZ)
    local maxDistance = self.PATHFINDER_START_DISTANCE
    local distances = {maxDistance}
    for _, d in ipairs(PathFinderModule.START_DISTANCES_SHORTER) do
        if d < maxDistance then
            table.insert(distances, d)
        end
    end
    local halfWidth = ADPathCalculator.getPassageWidth(self.vehicle) / 2 + 0.5
    local angleRad = math.atan2(dirX, dirZ)
    local height = self.vehicleMinHeight or 6
    -- from the front of the vehicle, so its own wheels and body are not in the box
    local frontOffset = (self.vehicle.size ~= nil and self.vehicle.size.length ~= nil and self.vehicle.size.length / 2 or 2.5) + 0.3
    -- beyond the start point the vehicle still needs about its turning radius to turn: check that too
    local turnSpace = math.max(2, self.minTurnRadius or 2)
    for _, distance in ipairs(distances) do
        local length = distance + turnSpace - frontOffset
        if length <= 0.5 then
            return distance
        end
        local cx = vehicleWorldX + dirX * (frontOffset + length / 2)
        local cz = vehicleWorldZ + dirZ * (frontOffset + length / 2)
        local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 1, cz)
        self.collisionhits = 0
        overlapBox(cx, y + height / 2 + 0.3, cz, 0, angleRad, 0, halfWidth, height / 2, length / 2, "collisionTestCallback", self, self.mask, true, true, true, true)
        if self:boxHitsBlockedZone(cx, cz, angleRad, halfWidth, length / 2) then
            self.collisionhits = self.collisionhits + 1
        end
        if self.collisionhits == 0 then
            if distance ~= maxDistance then
                print(string.format("[AD-Start] %s: obstacle ahead, path starts %.1f m in front instead of %.1f m", tostring(self.vehicle:getName()), distance, maxDistance))
            end
            return distance
        end
    end
    local shortest = distances[#distances]
    print(string.format("[AD-Start] %s: obstacle right in front of the vehicle, path starts %.1f m in front", tostring(self.vehicle:getName()), shortest))
    return shortest
end

-- where the route starts: the vehicle, or the pose given by the caller (end of the piece being driven)
function PathFinderModule:getStartPose()
    if self.startPose ~= nil then
        local p = self.startPose
        return p.x, p.y, p.z, p.rx, p.rz
    end
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local rx, _, rz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    return x, y, z, rx, rz
end
