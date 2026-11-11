-- ============================================================================================================
-- FarmPilot : WaitForCallTaskRoadside.lua
-- Complément de WaitForCallTask (tâche AutoDrive d'origine) : attendre au bord de la route, avant l'entrée du champ.
--
-- Historique : 25/10 (champ plein : ne pas rester le nez dans l'entrée, reculer
-- par où elle est venue, repartir vers le champ par le réseau), 27/10 20:35 (recul arrêté dès qu'un champ est sous
-- l'attelage, voir WaitForCallTaskFieldPark.lua).
--
-- Règle :
-- - le champ a déjà ses bennes (ADFieldPark.FIELD_CAPACITY) : la benne se gare au bord de la route près de l'entrée,
--   les suivantes derrière elle ;
-- - aucune place au bord de la route atteignable depuis l'entrée : recul de ROUTE_BACK_OFF m par où elle est venue,
--   une fois, puis nouvelle recherche depuis la route ;
-- - au bord de la route : la première de la file va dans le champ dès qu'une place s'y libère (retour sur le réseau
--   jusqu'au point du champ d'abord), les autres avancent vers une place plus proche de l'entrée.
--
-- Branché par : WaitForCallTaskFieldPark.lua (déroulé de l'attente, choix de la place).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
-- 25/10: field full and no clean way from the entrance to a roadside place (nose in the field, the road
-- behind): back off along the route it came by, then look again from the road
WaitForCallTask.ROUTE_BACK_OFF = 40        -- m backed off along the route
WaitForCallTask.ROUTE_BACK_OFF_TIMEOUT = 60000
WaitForCallTask.ENTRANCE_NEAR = 15         -- m: beside the road closer than this to the field point, the field search starts here
WaitForCallTask.ROUTE_BACK_OFF_MIN = 8 -- m backed along the route before a field under the train stops the back-off (the entrance itself may be on the field)
WaitForCallTask.NO_PLACE_RETRY = 45000 -- ms between two looks for a place in the field from beside the road

-- ------------------------------------------------------------------------------------------------------------
-- Champ complet : aller au bord de la route
-- ------------------------------------------------------------------------------------------------------------
-- ADFieldPark.FIELD_CAPACITY unloaders already in the field for this harvester: park beside the road near the
-- entrance instead, the next ones behind (true when it does)
function WaitForCallTask:goRoadsideIfFieldFull()
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local harvester = ADFieldPark.findHarvester(self.vehicle, x, z)
    if harvester == nil or ADFieldPark.countInField(self.vehicle, harvester) < ADFieldPark.FIELD_CAPACITY then
        return false
    end
    if self.ignoreCapacity then
        -- no roadside place reachable (see planToNextSpot): a place in the field behind the others rather than the entrance
        print(string.format("[AD-File] %s: champ complet mais aucune place atteignable au bord de la route : je libere l'entree, place dans le champ derriere les autres", tostring(self.vehicle:getName())))
        return false
    end
    print(string.format("[AD-File] %s: champ complet (%d bennes), attente au bord de la route", tostring(self.vehicle:getName()), ADFieldPark.FIELD_CAPACITY))
    return self:goRoadside(harvester)
end

-- the field point (entrance) of the route, when the unloader stands on the road near it; else where it stands
function WaitForCallTask:getEntrance()
    local x, y, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local marker = self.vehicle.ad.stateModule ~= nil and self.vehicle.ad.stateModule:getFirstMarker() or nil
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp ~= nil and not AutoDrive.checkIsOnField(x, y, z) and MathUtil.vector2Length(wp.x - x, wp.z - z) <= ADFieldPark.ROADSIDE_RANGE then
        return wp.x, wp.z
    end
    return x, z
end

-- parks beside the road near the entrance, behind the ones already waiting there
function WaitForCallTask:goRoadside(harvester)
    local x, z = self:getEntrance()
    local module = self.vehicle.ad.trafficYieldModule
    self.spots = ADFieldPark.findRoadsideSpots(self.vehicle, harvester, x, z)
    module:log("field park: waiting beside the road, %d places found (entrance %.0f,%.0f)", #self.spots, x, z)
    self.spotIndex = 0
    if #self.spots == 0 then
        self.state = WaitForCallTask.STATE_WAITING
        self.retryTime = 0
        return true
    end
    self:planToNextSpot()
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Aucune place atteignable : recul par où elle est venue
-- ------------------------------------------------------------------------------------------------------------
-- 25/10: at the entrance, nose in the field, no clean way to a roadside place: back off along the route it came
-- by (the road behind), once; the places are looked for again from there. Returns true when it backs off
function WaitForCallTask:startRouteBackOff()
    if self.routeBackOffDone then
        return false
    end
    self.routeBackOffDone = true
    local module = self.vehicle.ad.trafficYieldModule
    module.escapeBranch = nil
    local targets = module:buildReverseTargets()
    if targets == nil or #targets == 0 then
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    self.backOffTargets = targets
    self.backOffIndex = 1
    self.backOffDistance = WaitForCallTask.ROUTE_BACK_OFF
    self.backOffTimeout = WaitForCallTask.ROUTE_BACK_OFF_TIMEOUT
    self.backOffStart = {x = x, z = z}
    self.backOffTime = 0
    print(string.format("[AD-File] %s: aucune place au bord de la route atteignable depuis l'entree, je recule de %d m par ou je suis venu", tostring(self.vehicle:getName()), WaitForCallTask.ROUTE_BACK_OFF))
    self.state = WaitForCallTask.STATE_BACKING_OFF
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Quitter le bord de la route / avancer dans la file
-- ------------------------------------------------------------------------------------------------------------
-- leaves its roadside place for the field: back on the network to the field point first, the search of a place
-- in the field starts there as for any arrival (25/10)
function WaitForCallTask:leaveRoadside()
    self.parkedSpot = nil
    -- keeps its roadside place until the search reserves one in the field
    self.state = WaitForCallTask.STATE_CHECK
    self.checkTimer = AutoDriveTON:new()
    self.backOffCount = 0
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local marker = self.vehicle.ad.stateModule ~= nil and self.vehicle.ad.stateModule:getFirstMarker() or nil
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp ~= nil and MathUtil.vector2Length(wp.x - x, wp.z - z) > WaitForCallTask.ENTRANCE_NEAR then
        print(string.format("[AD-File] %s: retour sur le reseau jusqu'au point du champ (%.0f m)", tostring(self.vehicle:getName()), MathUtil.vector2Length(wp.x - x, wp.z - z)))
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self.vehicle.ad.drivePathModule:setPathTo(marker.id)
        self.state = WaitForCallTask.STATE_TO_ENTRANCE
    end
end

-- farther than ENTRANCE_NEAR from the field point of its route (backed off along the route, see startRouteBackOff)
function WaitForCallTask:isAwayFromEntrance()
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local marker = self.vehicle.ad.stateModule ~= nil and self.vehicle.ad.stateModule:getFirstMarker() or nil
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    return wp ~= nil and MathUtil.vector2Length(wp.x - x, wp.z - z) > WaitForCallTask.ENTRANCE_NEAR
end

-- waiting beside the road: the first one in the line goes into the field as soon as a place is free there; the
-- others move to a free place closer to the entrance
function WaitForCallTask:moveUpRoadside()
    local spot = self.parkedSpot
    if ADFieldPark.countInField(self.vehicle, spot.harvester) < ADFieldPark.FIELD_CAPACITY
        and ADFieldPark.isFirstOnRoadside(self.vehicle, spot.harvester) and ADFieldPark.canParkFor(self.vehicle, spot.harvester) then
        print(string.format("[AD-File] %s: place libre dans le champ, j'y vais", tostring(self.vehicle:getName())))
        self:leaveRoadside()
        return true
    end
    local spots = ADFieldPark.findRoadsideSpots(self.vehicle, spot.harvester, spot.entrance.x, spot.entrance.z)
    local best = spots[1]
    if best ~= nil and best.distance < spot.distance - 5 then
        print(string.format("[AD-File] %s: place plus proche de l'entree libre au bord de la route, avance (%.0f m)", tostring(self.vehicle:getName()), best.distance))
        self.parkedSpot = nil
        self.spots = spots
        self.spotIndex = 0
        self:planToNextSpot()
        return true
    end
    return false
end
