-- ============================================================================================================
-- FarmPilot : DrivePathModuleStuck.lua
-- Complément de ADDrivePathModule (module AutoDrive d'origine) : véhicule coincé ou qui pousse sans avancer.
--
-- Historique : 25/10 14:10 (la sécurité « coincé » d'AutoDrive remettait à zéro
-- les bennes de l'ensileuse : place dans la file, ensileuse et suivi perdus), 08/11 (7R 350 contre un poteau qu'il
-- n'a pas vu, 1 min 40 à pousser à 0 km/h).
--
-- Règle :
-- - la sécurité « coincé » (8 s sans approcher le point suivant) ne compte pas pendant la manœuvre d'un module
--   (croisement, contournement, écart, virage serré, recul d'intersection) ;
-- - coincé : une ligne de log, le mode peut se rattraper seul (onDriveStuck), sinon recul et contournement calculé
--   (ADObstacleDetourModule) avant la remise à zéro d'AutoDrive ;
-- - pousse sans avancer (PUSH_TIME sans bouger de PUSH_MOVE m alors qu'il doit rouler) : recul et passage à côté
--   (ADAvoidModule), à nouveau au même endroit : recul et contournement calculé, ensuite la sécurité de 8 s.
--
-- Branché par une ligne dans DrivePathModule.lua : update, followWaypoints (2), checkIfStuck, handleBeingStuck.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Sécurité « coincé » d'AutoDrive (checkIfStuck, handleBeingStuck)
-- ------------------------------------------------------------------------------------------------------------
-- (ADDrivePathModule:update) la sécurité « coincé » ne compte pas pendant qu'un module conduit
function ADDrivePathModule:mayCheckIfStuck()
    return (self.vehicle.ad.trafficYieldModule == nil or not self.vehicle.ad.trafficYieldModule:isControlling())
        and (self.vehicle.ad.obstacleDetourModule == nil or not self.vehicle.ad.obstacleDetourModule:isControlling())
        and (self.vehicle.ad.intersection == nil or self.vehicle.ad.intersection.retreat == nil)
end

-- (ADDrivePathModule:checkIfStuck) un module fait une manœuvre (contournement, écart, virage serré)
function ADDrivePathModule:isModuleManoeuvring()
    return (self.vehicle.ad.obstacleDetourModule ~= nil and self.vehicle.ad.obstacleDetourModule:isControlling())
        or (self.vehicle.ad.avoidModule ~= nil and self.vehicle.ad.avoidModule:isControlling())
        or (self.vehicle.ad.cornerModule ~= nil and self.vehicle.ad.cornerModule:isControlling())
end

-- (ADDrivePathModule:handleBeingStuck) true : rattrapé (le mode, ou recul et contournement) ; false : AutoDrive est
-- remis à zéro comme avant
function ADDrivePathModule:tryRecoverFromStuck()
    -- 25/10 14:10: this safety (8 s without getting closer to the next waypoint) reset the unloaders of the
    -- forage harvester (stop + restart): queue place, harvester and follow lost, the next unloader called from far
    -- away (MF 7S.210 14:08, 6205 TTV 13:55 and 14:02). Logged, and the mode may recover on its own instead
    local wp = self:getCurrentWayPoint()
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local distance = wp ~= nil and MathUtil.vector2Length(x - wp.x, z - wp.z) or -1
    local task = self.vehicle.ad.taskModule ~= nil and self.vehicle.ad.taskModule.activeTask or nil
    local taskName = "aucune"
    if task ~= nil then
        taskName = task.taskType or (task.getI18nInfo ~= nil and task:getI18nInfo()) or "?"
    end
    local info = string.format("coince : 8 s sans approcher le point suivant (a %.1f m, au plus pres %.1f m, point %d/%d, vitesse %.1f km/h, marche arriere %s, tache %s)",
        distance, self.minDistanceToNextWp ~= math.huge and self.minDistanceToNextWp or -1, self.currentWayPoint or 0, self.wayPoints ~= nil and #self.wayPoints or 0,
        math.abs(self.vehicle.lastSpeedReal or 0) * 3600, tostring(self.isReversing), tostring(taskName))
    local mode = self.vehicle.ad.stateModule ~= nil and self.vehicle.ad.stateModule:getCurrentMode() or nil
    if mode ~= nil and mode.onDriveStuck ~= nil and mode:onDriveStuck(info) then
        self.minDistanceTimer:timer(false)
        self.minDistanceToNextWp = math.huge
        return true
    end
    -- stuck against something (wall, house corner): a plain restart puts the vehicle back on the same
    -- route from the same spot. Reversing first and planning a way around (ADObstacleDetourModule) is tried before
    local detour = self.vehicle.ad.obstacleDetourModule
    if detour ~= nil and detour.startFromStuck ~= nil and detour:startFromStuck() then
        print(string.format("[AD-Coince] %s: %s : recul puis contournement avant la remise a zero", tostring(self.vehicle:getName()), info))
        self.minDistanceTimer:timer(false)
        self.minDistanceToNextWp = math.huge
        return true
    end
    print(string.format("[AD-Coince] %s: %s : AutoDrive remis a zero (arret puis redemarrage)", tostring(self.vehicle:getName()), info))
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Pousse sans avancer
-- ------------------------------------------------------------------------------------------------------------
-- (08/11) 7R 350 against a pole beside the line, tried to drive on without seeing it: 1 min 40
-- pushing at 0 km/h, sensors free, and the 8 s safety above never fired. Pushing = told to drive on (no stop asked,
-- speed limit at least PUSH_MIN_LIMIT, engine running, on the road network) without moving PUSH_MOVE metres for
-- PUSH_TIME. Then: back up and pass beside it (ADAvoidModule:startFromPush); pushing again at the same place (twice): back up
-- and compute a way around (ADObstacleDetourModule:startFromStuck); after that the 8 s safety as before
ADDrivePathModule.PUSH_TIME = 3000          -- ms
ADDrivePathModule.PUSH_MOVE = 0.5           -- m
ADDrivePathModule.PUSH_MIN_LIMIT = 3        -- km/h
ADDrivePathModule.PUSH_SAME_PLACE = 10      -- m
ADDrivePathModule.PUSH_GAP = 500            -- ms without a check: the watch starts again

function ADDrivePathModule:checkIfPushing(dt)
    if not self.vehicle.isServer then
        return
    end
    local ad = self.vehicle.ad
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local now = g_time or 0
    local idle = (self.speedLimit or 0) < ADDrivePathModule.PUSH_MIN_LIMIT or (self.acceleration or 1) <= 0 or not self:isOnRoadNetwork()
        or (self.vehicle.getIsMotorStarted ~= nil and not self.vehicle:getIsMotorStarted())
        or (ad.trailerModule ~= nil and ad.trailerModule.isActiveAtTrigger ~= nil and ad.trailerModule:isActiveAtTrigger())
        or (ad.specialDrivingModule ~= nil and ad.specialDrivingModule:isStoppingVehicle())
    if idle or self.pushX == nil or self.pushCheckTime == nil or now - self.pushCheckTime > ADDrivePathModule.PUSH_GAP
        or MathUtil.vector2Length(x - self.pushX, z - self.pushZ) > ADDrivePathModule.PUSH_MOVE then
        self.pushX, self.pushZ = x, z
        self.pushTime = 0
        self.pushCheckTime = now
        return
    end
    self.pushCheckTime = now
    self.pushTime = (self.pushTime or 0) + dt
    if self.pushTime < ADDrivePathModule.PUSH_TIME then
        return
    end
    self.pushX = nil
    self:handlePushing(x, z)
end

function ADDrivePathModule:handlePushing(x, z)
    local ad = self.vehicle.ad
    if self.pushPlaceX ~= nil and MathUtil.vector2Length(x - self.pushPlaceX, z - self.pushPlaceZ) < ADDrivePathModule.PUSH_SAME_PLACE then
        self.pushCount = (self.pushCount or 0) + 1
    else
        self.pushPlaceX, self.pushPlaceZ = x, z
        self.pushCount = 1
    end
    local name = ad.stateModule ~= nil and ad.stateModule:getName() or tostring(self.vehicle.id)
    local info = string.format("pousse sans avancer depuis %.0f s (limite %.0f km/h, point %d/%d, decalage %.1f m, fois %d ici)",
        ADDrivePathModule.PUSH_TIME / 1000, self.speedLimit or 0, self.currentWayPoint or 0, self.wayPoints ~= nil and #self.wayPoints or 0,
        self.lateralOffset or 0, self.pushCount)
    if self.pushCount == 1 and ad.avoidModule ~= nil and ad.avoidModule.startFromPush ~= nil and ad.avoidModule:startFromPush() then
        print(string.format("[AD-Pousse] %s: %s : recul puis passage a cote", tostring(name), info))
        return
    end
    if self.pushCount <= 3 and ad.obstacleDetourModule ~= nil and ad.obstacleDetourModule.startFromStuck ~= nil and ad.obstacleDetourModule:startFromStuck() then
        print(string.format("[AD-Pousse] %s: %s : recul puis contournement calcule", tostring(name), info))
        return
    end
    print(string.format("[AD-Pousse] %s: %s : rien de possible ici, la securite coince (8 s) prend la suite", tostring(name), info))
end
