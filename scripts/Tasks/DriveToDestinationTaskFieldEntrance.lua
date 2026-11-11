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
--   WaitForCallTask la gare au bord de la route (WaitForCallTaskRoadside.lua) ;
-- - 11/11 (champ 56), moissonneuse : avant l'entrée, la place est cherchée depuis le point du champ sans y aller ;
--   aucune place, ou aucun trajet propre depuis l'entrée : arrêt sur le chemin, même suite que le champ complet
--   (jamais d'attente au point du champ, sur la fourrière de la moissonneuse).
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

DriveToDestinationTask.NO_PLACE_SEARCH_DISTANCE = 100 -- m before the field point: combine, the place is looked for from it while driving (11/11)

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

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse : pas de place atteignable depuis l'entrée, arrêt sur le chemin avant (11/11, champ 56)
-- ------------------------------------------------------------------------------------------------------------
-- 11/11 (champ 56 : la benne est allée jusqu'au point du champ, n'a trouvé aucune place ni aucun trajet propre,
-- a reculé dans la prairie, est revenue et a attendu à l'entrée, en plein sur la fourrière de la moissonneuse) :
-- benne vide qui revient au champ d'une moissonneuse, à NO_PLACE_SEARCH_DISTANCE m du point du champ, la place est
-- cherchée depuis ce point (pose d'arrivée : le dernier tronçon du trajet), sans y aller, pendant qu'elle roule.
-- Arrivée à FIELD_FULL_STOP_MIN m avant la fin de la recherche : elle attend là. Une place et un trajet propre
-- depuis l'entrée (ADFieldPark.findWayFromEntrance) : elle continue comme avant. Sinon elle s'arrête sur le chemin
-- (à FIELD_FULL_STOP_DISTANCE m au plus du point du champ), la tâche finit ici et WaitForCallTask la gare au bord de la route si possible, puis cherche de nouveau de temps en
-- temps depuis le point du champ (vehicle.ad.noPlaceAhead, voir WaitForCallTaskFieldPark.lua).
function DriveToDestinationTask:getEntrancePose(wp)
    local wayPoints = self.vehicle.ad.drivePathModule.wayPoints
    local previous = nil
    if wayPoints ~= nil then
        for i = #wayPoints, 1, -1 do
            local p = wayPoints[i]
            if MathUtil.vector2Length(p.x - wp.x, p.z - wp.z) > 2 then
                previous = p
                break
            end
        end
    end
    local dx, dz
    if previous ~= nil then
        local l = MathUtil.vector2Length(wp.x - previous.x, wp.z - previous.z)
        dx, dz = (wp.x - previous.x) / l, (wp.z - previous.z) / l
    else
        dx, dz = ADTrafficYieldModule.getDirection(self.vehicle)
    end
    return {x = wp.x, z = wp.z, dx = dx, dz = dz}
end

function DriveToDestinationTask:isNoPlaceStop(dt)
    if self.noPlaceDone then
        return false
    end
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or ADFieldPark == nil or ADFieldPark.findWayFromEntrance == nil or not ADFieldPark.isEnabled()
        or self.vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_UNLOAD or mode.state ~= mode.STATE_DRIVE_TO_START
        or self.routeIsPartial or self.vehicle.ad.trafficYieldModule == nil or AutoDrive:getIsCPActive(self.vehicle) then
        return false
    end
    local marker = self.vehicle.ad.stateModule:getFirstMarker()
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp == nil then
        return false
    end
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local distance = MathUtil.vector2Length(wp.x - x, wp.z - z)
    if self.noPlaceStopAt ~= nil then
        -- no place reachable: it stops on the road once within FIELD_FULL_STOP_DISTANCE m of the field point
        if distance > DriveToDestinationTask.FIELD_FULL_STOP_DISTANCE then
            return false
        end
        return self:stopNoPlace(dt, distance)
    end
    if self.noPlaceSearch == nil then
        if distance > DriveToDestinationTask.NO_PLACE_SEARCH_DISTANCE then
            return false
        end
        self.noPlaceDone = true
        if distance < DriveToDestinationTask.FIELD_FULL_STOP_MIN or AutoDrive.checkIsOnField(x, y, z) then
            -- started near the field: as before
            return false
        end
        local harvester = ADFieldPark.findHarvester(self.vehicle, wp.x, wp.z)
        if harvester == nil or (harvester.ad ~= nil and harvester.ad.isChopper == true) then
            -- forage harvester: its own rules (narrow first strip), unchanged
            return false
        end
        local trailers = AutoDrive.getAllUnits(self.vehicle)
        local fillLevel = trailers ~= nil and #trailers > 0 and AutoDrive.getAllFillLevels(trailers) or 0
        if fillLevel ~= nil and fillLevel > 0.1 then
            return false
        end
        self.noPlaceDone = false
        self.noPlaceOrigin = self:getEntrancePose(wp)
        self.noPlaceSearch = ADFieldPark.newSearch(self.vehicle, self.noPlaceOrigin)
        self.vehicle.ad.trafficYieldModule:log("field park: %.0f m before the field point, looking for a place from it (x=%.0f z=%.0f heading %.0f°)",
            distance, wp.x, wp.z, math.deg(math.atan2(self.noPlaceOrigin.dx, self.noPlaceOrigin.dz)))
        return false
    end
    local spots = ADFieldPark.searchStep(self.noPlaceSearch)
    if spots == nil then
        if distance <= DriveToDestinationTask.FIELD_FULL_STOP_MIN then
            -- the search is not done yet: wait here, before the entrance
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
            return true
        end
        return false
    end
    local search = self.noPlaceSearch
    self.noPlaceSearch = nil
    self.noPlaceDone = true
    if search.result ~= nil then
        self.vehicle.ad.trafficYieldModule:log("field park: %s", search.result)
    end
    if WaitForCallTask ~= nil and WaitForCallTask.HARVESTER_AWAY ~= nil and WaitForCallTask.HARVESTER_AWAY[search.result or ""] then
        -- no harvester at work in this field: as before (waits at the entrance, the HUD says why)
        return false
    end
    local index, way = nil, nil
    if #spots > 0 and not search.waitSense then
        index, way = ADFieldPark.findWayFromEntrance(self.vehicle, spots, self.noPlaceOrigin)
    end
    if index ~= nil then
        self.vehicle.ad.trafficYieldModule:log("field park: place %d reachable from the field point (%s), driving on", index, way)
        return false
    end
    self.noPlaceStopAt = {spots = #spots > 0 and not search.waitSense and #spots or 0}
    self.noPlaceDone = false
    if distance > DriveToDestinationTask.FIELD_FULL_STOP_DISTANCE then
        return false
    end
    return self:stopNoPlace(dt, distance)
end

function DriveToDestinationTask:stopNoPlace(dt, distance)
    local found = self.noPlaceStopAt.spots
    self.noPlaceStopAt = nil
    self.noPlaceDone = true
    if found > 0 then
        print(string.format("[AD-File] %s: %d place(s) dans le champ mais aucun trajet propre depuis l'entree, je m'arrete sur le chemin a %.0f m avant", tostring(self.vehicle:getName()), found, distance))
    else
        print(string.format("[AD-File] %s: aucune place dans le champ pour l'instant, je m'arrete sur le chemin a %.0f m avant l'entree", tostring(self.vehicle:getName()), distance))
    end
    self.vehicle.ad.noPlaceAhead = {origin = self.noPlaceOrigin, time = g_time or 0}
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    self:finished()
    return true
end
