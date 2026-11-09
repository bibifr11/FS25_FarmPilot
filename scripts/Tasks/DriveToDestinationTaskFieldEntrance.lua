-- ============================================================================================================
-- FarmPilot : DriveToDestinationTaskFieldEntrance.lua
-- Complément de DriveToDestinationTask (tâche AutoDrive d'origine) : la benne vide qui revient au champ (mode
-- moissonneuse) n'encombre pas l'entrée.
--
-- Historique : 25/10 (champ complet : arrêt sur la route avant l'entrée ; une
-- pleine sort par la même entrée : elle passe d'abord), 27/10 18:12 (tracteur encore hors du champ : les autres
-- attendent avant d'arriver sur zone ; MF 7S et 942 à la queue leu leu derrière la remorque du 7R).
--
-- Règle, sur la route avant le point du champ :
-- - une benne pleine sort par cette entrée : attente qu'elle soit sortie (ADFieldPark.holdForExit) ;
-- - une autre benne de cette moissonneuse est dans la zone d'entrée sans être dans le champ : attente sur la route
--   (ZONE_HOLD_TIMEOUT au plus) ;
-- - le champ a déjà ses bennes (ADFieldPark.FIELD_CAPACITY) : arrêt sur la route, la tâche finit ici et
--   WaitForCallTask la gare au bord de la route (WaitForCallTaskRoadside.lua).
--
-- Branché par : DriveToDestinationTask:updateArrival (DriveToDestinationTaskArrival.lua) ; DriveToDestinationTask.lua
-- (abort, finished : attente effacée).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
DriveToDestinationTask.FIELD_FULL_STOP_DISTANCE = 60 -- m before the field point: the field being full, it stops on the road here
DriveToDestinationTask.FIELD_FULL_STOP_MIN = 25     -- m: closer than this it goes on to the field point as before
DriveToDestinationTask.FIELD_FULL_CHECK = 1000      -- ms between two looks

DriveToDestinationTask.ZONE_RADIUS = 35          -- m around the field point: the entrance zone
DriveToDestinationTask.ZONE_HOLD_MAX = 60        -- m before the field point: the unloader holds on the road from here
DriveToDestinationTask.ZONE_HOLD_TIMEOUT = 180000 -- ms, then it drives on as before

-- ------------------------------------------------------------------------------------------------------------
-- Une pleine sort par cette entrée
-- ------------------------------------------------------------------------------------------------------------
-- 25/10: empty unloader back to the field, a full one drives out by the same entrance: it stops on the road
-- before the entrance until the full one is out
function DriveToDestinationTask:isEntranceHold(dt)
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or ADFieldPark == nil or self.vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_UNLOAD
        or mode.state ~= mode.STATE_DRIVE_TO_START then
        return false
    end
    return ADFieldPark.holdForExit(self.vehicle, dt, "sur la route")
end

-- ------------------------------------------------------------------------------------------------------------
-- Zone d'entrée occupée par une autre benne
-- ------------------------------------------------------------------------------------------------------------
-- 27/10 18:12 (the tractor still outside the field, the others wait before reaching the zone): at the start
-- of a job the first unloader is still on the grass beside the harvester, outside the field, and the next ones drove
-- up to the entrance and queued nose to tail behind its trailer (MF 7S and 942 behind the 7R). An unloader coming to
-- the field point holds on the road before the entrance while another unloader of this harvester is in the entrance
-- zone and not on the field (the called one not yet in place, or one still waiting at the entrance)
function DriveToDestinationTask:isZoneBusyHold(dt)
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or ADFieldPark == nil or not ADFieldPark.isEnabled() or self.vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_UNLOAD
        or mode.state ~= mode.STATE_DRIVE_TO_START or self.routeIsPartial then
        return false
    end
    local hold = self.vehicle.ad.zoneHold
    self.zoneCheck = (self.zoneCheck or 0) + dt
    if self.zoneCheck < DriveToDestinationTask.FIELD_FULL_CHECK then
        if hold ~= nil then
            hold.waited = hold.waited + dt
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
            return true
        end
        return false
    end
    self.zoneCheck = 0
    local marker = self.vehicle.ad.stateModule:getFirstMarker()
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp == nil then
        return false
    end
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local distance = MathUtil.vector2Length(wp.x - x, wp.z - z)
    local busy = nil
    if distance <= DriveToDestinationTask.ZONE_HOLD_MAX and distance >= DriveToDestinationTask.FIELD_FULL_STOP_MIN
        and not AutoDrive.checkIsOnField(x, y, z) then
        local harvester = ADFieldPark.findHarvester(self.vehicle, wp.x, wp.z)
        if harvester ~= nil and ADHarvestManager ~= nil and ADHarvestManager.getUnloadersOf ~= nil then
            for _, other in pairs(ADHarvestManager:getUnloadersOf(harvester)) do
                if other ~= self.vehicle and other.components ~= nil and other.isDeleted ~= true then
                    local ox, oy, oz = getWorldTranslation(other.components[1].node)
                    local od = MathUtil.vector2Length(wp.x - ox, wp.z - oz)
                    local spot = ADFieldPark.parked ~= nil and ADFieldPark.parked[other] or nil
                    -- in the entrance zone, not on the field, and not parked in a field spot: still in the way
                    if od < DriveToDestinationTask.ZONE_RADIUS and not AutoDrive.checkIsOnField(ox, oy, oz)
                        and (spot == nil or spot.roadside) then
                        busy = other
                        break
                    end
                end
            end
        end
    end
    if busy == nil then
        if hold ~= nil then
            print(string.format("[AD-Entree] %s: %s n'est plus dans la zone d'entree, j'y vais (attendu %d s)", tostring(self.vehicle:getName()), tostring(hold.name), math.floor(hold.waited / 1000)))
            self.vehicle.ad.zoneHold = nil
        end
        return false
    end
    if hold == nil or hold.other ~= busy then
        hold = {other = busy, name = busy:getName(), waited = hold ~= nil and hold.waited or 0}
        self.vehicle.ad.zoneHold = hold
        print(string.format("[AD-Entree] %s: %s est dans la zone d'entree sans etre dans le champ, j'attends sur la route a %.0f m du point du champ", tostring(self.vehicle:getName()), tostring(hold.name), distance))
    end
    hold.waited = hold.waited + dt
    if hold.waited > DriveToDestinationTask.ZONE_HOLD_TIMEOUT then
        if not hold.gaveUp then
            hold.gaveUp = true
            print(string.format("[AD-Entree] %s: %s toujours dans la zone apres %d s, je n'attends plus", tostring(self.vehicle:getName()), tostring(hold.name), DriveToDestinationTask.ZONE_HOLD_TIMEOUT / 1000))
        end
        return false
    end
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Champ complet : arrêt sur la route
-- ------------------------------------------------------------------------------------------------------------
-- 25/10: empty unloader back to a field that already holds its unloaders (ADFieldPark.FIELD_CAPACITY): it does not
-- drive up to the entrance (where it blocks it, nose in the field, with no clean way to the roadside), it stops on the
-- road before the entrance and WaitForCallTask parks it beside the road from there
function DriveToDestinationTask:isFieldFullStop(dt)
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or ADFieldPark == nil or not ADFieldPark.isEnabled() or self.vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_UNLOAD
        or mode.state ~= mode.STATE_DRIVE_TO_START or self.routeIsPartial then
        return false
    end
    self.fieldFullCheck = (self.fieldFullCheck or 0) + dt
    if self.fieldFullCheck < DriveToDestinationTask.FIELD_FULL_CHECK then
        return false
    end
    self.fieldFullCheck = 0
    local marker = self.vehicle.ad.stateModule:getFirstMarker()
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp == nil then
        return false
    end
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local distance = MathUtil.vector2Length(wp.x - x, wp.z - z)
    if distance > DriveToDestinationTask.FIELD_FULL_STOP_DISTANCE or distance < DriveToDestinationTask.FIELD_FULL_STOP_MIN
        or AutoDrive.checkIsOnField(x, y, z) then
        return false
    end
    local harvester = ADFieldPark.findHarvester(self.vehicle, wp.x, wp.z)
    if harvester == nil or ADFieldPark.countInField(self.vehicle, harvester) < ADFieldPark.FIELD_CAPACITY then
        return false
    end
    print(string.format("[AD-File] %s: champ complet (%d bennes), je m'arrete sur la route a %.0f m avant l'entree", tostring(self.vehicle:getName()), ADFieldPark.FIELD_CAPACITY, distance))
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    self:finished()
    return true
end
