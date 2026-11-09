-- ============================================================================================================
-- FarmPilot : DrivePathModuleObstacles.lua
-- Complément de ADDrivePathModule (module AutoDrive d'origine) : là où le suivi de route passe la main aux modules de
-- conduite FarmPilot (obstacles, trafic, virages trop serrés).
--
-- Historique : 08/11 (poteau ou piquet sur la ligne du réseau : la route passe à
-- côté).
--
-- Règle, à chaque image (serveur), dans cet ordre, le premier module qui prend la main arrête le suivi de route :
-- face à face entre deux véhicules AutoDrive (ADTrafficYieldModule), portion Intersection (ADIntersectionModule),
-- voiture arrêtée nez à nez (ADAvoidModule), virage trop serré pour l'attelage (ADCornerModule), obstacle fixe qui
-- bloque la route (zone apprise, ADObstacleDetourModule) ; un véhicule AutoDrive trop près devant compte comme un
-- obstacle (ADApproachModule). Ralentissement avant un obstacle plus loin et ligne suivie décalée pendant un écart.
-- Route donnée : virages trop serrés redessinés (ADCornerModule:smoothRoute), poteau sur la ligne contourné
-- (ADPathCalculator.shiftAroundObstacles).
--
-- Branché par une ligne dans DrivePathModule.lua : reset, setPathTo, appendPathTo, followWaypoints (2),
-- getLookAheadTarget.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Remise à zéro (ADDrivePathModule:reset)
-- ------------------------------------------------------------------------------------------------------------
function ADDrivePathModule:resetDrivingModules()
    if self.vehicle.ad ~= nil and self.vehicle.ad.obstacleDetourModule ~= nil then
        self.vehicle.ad.obstacleDetourModule:reset()
    end
    if self.vehicle.ad ~= nil and self.vehicle.ad.approachModule ~= nil then
        self.vehicle.ad.approachModule:reset()
    end
    if self.vehicle.ad ~= nil and self.vehicle.ad.avoidModule ~= nil then
        self.vehicle.ad.avoidModule:reset()
    end
    if self.vehicle.ad ~= nil and self.vehicle.ad.cornerModule ~= nil then
        self.vehicle.ad.cornerModule:reset()
    end
    self.lateralOffset = 0
    self.pushX = nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Route donnée (ADDrivePathModule:setPathTo, ADDrivePathModule:appendPathTo)
-- ------------------------------------------------------------------------------------------------------------
-- sharp corners replaced by arcs of the real turning radius (ADCornerModule); the first points stay as they are
function ADDrivePathModule:prepareRoute(wayPoints, firstIndex)
    if wayPoints ~= nil and #wayPoints >= 3 and self.vehicle.ad.cornerModule ~= nil then
        wayPoints = self.vehicle.ad.cornerModule:smoothRoute(wayPoints, firstIndex)
    end
    return ADDrivePathModule.shiftAroundObstacles(self.vehicle, wayPoints, 2)
end

-- (08/11) a pole or a post on the network line: the route is moved beside it when it is set
-- (ADPathCalculator.shiftAroundObstacles); any error leaves the route as it was
function ADDrivePathModule.shiftAroundObstacles(vehicle, wayPoints, firstIndex)
    if wayPoints == nil or #wayPoints < 3 or ADPathCalculator.shiftAroundObstacles == nil then
        return wayPoints
    end
    local ok, shifted = pcall(ADPathCalculator.shiftAroundObstacles, vehicle, wayPoints, firstIndex)
    if not ok then
        print(string.format("[AD-Poteau] %s: error %s, route kept", tostring(vehicle.getName ~= nil and vehicle:getName() or "?"), tostring(shifted)))
        return wayPoints
    end
    return shifted or wayPoints
end

-- ------------------------------------------------------------------------------------------------------------
-- Limite de vitesse (ADDrivePathModule:followWaypoints)
-- ------------------------------------------------------------------------------------------------------------
function ADDrivePathModule:applyDrivingModulesSpeedLimit(dt)
    -- anticipated slow-down in front of an obstacle further on the route (ADApproachModule)
    if self.vehicle.ad.approachModule ~= nil then
        self.speedLimit = math.min(self.speedLimit, self.vehicle.ad.approachModule:getSpeedLimit(dt))
    end
    -- light obstacle on one side: lateral offset of the followed line, without stopping (ADAvoidModule)
    if self.vehicle.ad.avoidModule ~= nil then
        self.speedLimit = math.min(self.speedLimit, self.vehicle.ad.avoidModule:update(dt))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Les modules prennent la main (ADDrivePathModule:followWaypoints)
-- ------------------------------------------------------------------------------------------------------------
-- true : un module conduit le véhicule cette image (fin du suivi de route) ; sinon false, et obstacleDetected mis à
-- jour (un véhicule AutoDrive trop près devant compte comme un obstacle)
function ADDrivePathModule:handleDrivingModules(dt, obstacleDetected)
    -- head-on deadlock resolution between two AD vehicles: the module takes control while active
    if self.vehicle.ad.trafficYieldModule ~= nil and self.vehicle.ad.trafficYieldModule:handle(dt, obstacleDetected) then
        return true, obstacleDetected
    end
    -- portion Intersection : arrêt avant de traverser si un véhicule arrive sur la route
    if ADIntersectionModule.handle(self.vehicle, dt) then
        return true, obstacleDetected
    end
    -- traffic car stopped nose to nose: the lane change backs up first and drives meanwhile (ADAvoidModule)
    if self.vehicle.ad.avoidModule ~= nil and self.vehicle.ad.avoidModule:handle(dt) then
        return true, obstacleDetected
    end
    -- bend too tight for the train: backing up a few metres before taking it (ADCornerModule)
    if self.vehicle.ad.cornerModule ~= nil and self.vehicle.ad.cornerModule:handle(dt) then
        return true, obstacleDetected
    end
    self:learnBlockedPlace(dt, obstacleDetected)
    -- static obstacle blocking the route forever: reverse and compute a route around it
    if self.vehicle.ad.obstacleDetourModule ~= nil and self.vehicle.ad.obstacleDetourModule:handle(dt, obstacleDetected) then
        return true, obstacleDetected
    end

    -- another AutoDrive vehicle closer than the gap on the route: stop here, like the sensors would
    if not obstacleDetected and self.vehicle.ad.approachModule ~= nil and self.vehicle.ad.approachModule:shouldStop() then
        obstacleDetected = true
    end
    return false, obstacleDetected
end

-- front sensor keeps the vehicle stopped on a calculated route: the place becomes a forbidden zone for all later route searches
function ADDrivePathModule:learnBlockedPlace(dt, obstacleDetected)
    local wp = self:getCurrentWayPoint()
    local odm = self.vehicle.ad.obstacleDetourModule
    local blocked = obstacleDetected and self.vehicle.isServer and wp ~= nil and wp.isPathFinderPoint and odm ~= nil and odm:isBlockedByStaticObstacle()
    if not blocked then
        self.learnZoneTimer = 0
        return
    end
    if self.learnZoneTimer ~= nil and self.learnZoneTimer < 0 then
        return
    end
    self.learnZoneTimer = (self.learnZoneTimer or 0) + dt
    if self.learnZoneTimer < PathFinderModule.LEARNED_ZONE_DELAY then
        return
    end
    -- once per stop
    self.learnZoneTimer = -1
    if odm:isVehicleInFront() then
        return
    end
    local length = self.vehicle.size ~= nil and self.vehicle.size.length or 5
    local bx, _, bz = AutoDrive.localToWorld(self.vehicle, 0, 0, length / 2 + 1)
    -- the task driving this route may plan again around the zone (ExitFieldTask)
    self.vehicle.ad.routeBlockedTime = g_time
    PathFinderModule.addLearnedZone(bx, bz, self.vehicle:getName())
end

-- ------------------------------------------------------------------------------------------------------------
-- Ligne suivie décalée (ADDrivePathModule:getLookAheadTarget)
-- ------------------------------------------------------------------------------------------------------------
function ADDrivePathModule:applyLateralOffset(targetX, targetZ, wp_current, wp_ahead, distanceToNextTarget, x, z)
    -- lateral offset while avoiding a light obstacle (ADAvoidModule): along the left normal of the stretch
    local offset = self.lateralOffset or 0
    if offset ~= 0 then
        local dx, dz = wp_ahead.x - wp_current.x, wp_ahead.z - wp_current.z
        if distanceToNextTarget <= 0.1 then
            dx, dz = wp_current.x - x, wp_current.z - z
        end
        local l = MathUtil.vector2Length(dx, dz)
        if l > 0.1 then
            targetX = targetX + dz / l * offset
            targetZ = targetZ - dx / l * offset
        end
    end
    return targetX, targetZ
end
