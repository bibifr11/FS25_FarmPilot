-- ============================================================================================================
-- FarmPilot : WaitForCallTaskOffFieldPoint.lua
-- Complément de WaitForCallTask et de DriveToDestinationTask (tâches AutoDrive d'origine), mode « décharger la
-- moissonneuse » avec « Attendre dans le champ » : le point d'attente posé hors du champ.
--
-- Historique : 20/11 (pommes de terre, vidage dans des camions à quelques dizaines de mètres du point d'attente
-- posé sur l'herbe au bord du champ) : aucune place dans le champ, la benne vide s'arrêtait sur le chemin juste
-- après le vidage (arrêt « aucune place » du 11/11) et n'allait jamais au point d'attente.
--
-- Règle :
-- - point d'attente (première destination) hors du sol du champ : la benne y va toujours. Les arrêts sur la route
--   avant l'entrée (champ complet, zone d'entrée occupée, aucune place) ne s'appliquent pas ;
-- - arrivée au point : une place libre dans le champ et un trajet propre = elle y va comme avant ; sinon elle attend
--   au point, sans recul ni bord de la route, et cherche de nouveau plus tard (ADFieldPark.RETRY_DELAY) ;
-- - point d'attente sur le sol du champ (fourrière de la moissonneuse) : règles du 25/10 et du 11/11 inchangées.
--
-- Branché par : DriveToDestinationTaskFieldEntrance.lua (isZoneBusyHold, isFieldFullStop, isNoPlaceStop) ;
-- WaitForCallTaskFieldPark.lua (planToNextSpot) ; WaitForCallTaskRoadside.lua (goRoadsideIfFieldFull).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
WaitForCallTask.OFF_FIELD_POINT_NEAR = 25 -- m from the waiting point: closer than this, it waits at the point

-- ------------------------------------------------------------------------------------------------------------
-- Point d'attente hors du champ
-- ------------------------------------------------------------------------------------------------------------
ADFieldPark.offFieldPointCache = {} -- waypoint id -> true when it is off the field ground

-- the waypoint of the vehicle's waiting point (first destination) when it lies off the field ground, else nil
function ADFieldPark.getOffFieldWaitPoint(vehicle)
    local stateModule = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    local marker = stateModule ~= nil and stateModule:getFirstMarker() or nil
    if marker == nil or marker == 0 or marker.id == nil then
        return nil
    end
    local wp = ADGraphManager:getWayPointById(marker.id)
    if wp == nil then
        return nil
    end
    local off = ADFieldPark.offFieldPointCache[marker.id]
    if off == nil then
        local y = wp.y or getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, wp.x, 0, wp.z)
        off = not AutoDrive.checkIsOnField(wp.x, y, wp.z)
        ADFieldPark.offFieldPointCache[marker.id] = off
    end
    return off and wp or nil
end

-- ------------------------------------------------------------------------------------------------------------
-- En route : pas d'arrêt avant le point (DriveToDestinationTaskFieldEntrance.lua)
-- ------------------------------------------------------------------------------------------------------------
function DriveToDestinationTask:isOffFieldWaitPoint()
    return ADFieldPark ~= nil and ADFieldPark.getOffFieldWaitPoint(self.vehicle) ~= nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Au point : aucune place = attente au point (WaitForCallTaskFieldPark.lua, WaitForCallTaskRoadside.lua)
-- ------------------------------------------------------------------------------------------------------------
-- true when it stands at its off-field waiting point: it waits there and looks again later
function WaitForCallTask:waitAtOffFieldPoint(reason)
    local wp = ADFieldPark.getOffFieldWaitPoint(self.vehicle)
    if wp == nil then
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    if MathUtil.vector2Length(wp.x - x, wp.z - z) > WaitForCallTask.OFF_FIELD_POINT_NEAR then
        return false
    end
    if self.offFieldPointLogged ~= reason then
        self.offFieldPointLogged = reason
        print(string.format("[AD-File] %s: %s, attente au point d'attente (hors du champ)", tostring(self.vehicle:getName()), tostring(reason)))
    end
    ADFieldPark.setParked(self.vehicle, nil)
    self.spots = nil
    self.state = WaitForCallTask.STATE_WAITING
    self.retryTime = 0
    return true
end
