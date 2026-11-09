-- ============================================================================================================
-- FarmPilot : DriveToVehicleTaskFieldPark.lua
-- Complément de DriveToVehicleTask (tâche AutoDrive d'origine) : la 2e benne appelée qui attend la 1re ne reste pas
-- dans l'entrée du champ ou sur la route : elle va d'abord se garer dans le champ.
--
-- Historique : 26/10 20:36 (en attente pour rejoindre le 2e tracteur : mieux vaut se garer
-- plus loin dans le champ pour ne pas bloquer l'entrée), 27/10 20:46 (MF 7S.210 bloqué 2 min
-- dans l'entrée, 9 échecs).
--
-- Règle : appelée alors que la 1re n'est pas encore en place, et debout dans l'entrée ou sur la route : place cherchée
-- avec les règles des places d'attente (ADFieldPark, FieldParkModule.lua), trajet direct, mémorisé ou pathfinder ;
-- après PARK_AFTER_FAILURES trajets ratés de suite vers la 1re, même chose, puis nouveau calcul de là.
-- Pas de place : elle attend où elle est que la 1re soit en place.
--
-- Branché par : DriveToVehicleTaskFollow.lua (mise en place, déroulé, échecs de trajet) et DriveToVehicleTask.lua
-- (finished).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
-- 26/10 20:36 (waiting to join the 2nd tractor, better parked further into the field so the entrance stays free):
-- called while the 1st is not in place yet and standing in the entrance or on the road,
-- the follower first drives to a field park place (same rules as the waiting places) and waits there
DriveToVehicleTask.STATE_PARK_SEARCH = 7
DriveToVehicleTask.STATE_PARK_PLAN = 8
DriveToVehicleTask.STATE_PARK_DRIVE = 9
DriveToVehicleTask.PARK_PLAN_TIMEOUT = 30000 -- ms of pathfinding to one place at most
-- 27/10 20:46 (MF 7S.210 blocked 2 min in the entrance, 9 failures): after PARK_AFTER_FAILURES failed plans in a
-- row the follower goes to a field park place first (the entrance stays free), and plans again from there
DriveToVehicleTask.PARK_AFTER_FAILURES = 2

-- nom du véhicule pour les logs (même fonction locale dans chaque fichier DriveToVehicleTask*.lua)
local function logName(vehicle)
    return vehicle ~= nil and vehicle.getName ~= nil and tostring(vehicle:getName()) or "?"
end

-- ------------------------------------------------------------------------------------------------------------
-- Attente de la 1re : se garer hors de l'entrée (waiting for the 1st: out of the entrance)
-- ------------------------------------------------------------------------------------------------------------
-- standing in the entrance or on the road while waiting: a field park place is looked for (ADFieldPark rules)
function DriveToVehicleTask:parkInFieldFirst(because)
    if ADFieldPark == nil or ADFieldPark.isEnabled == nil or not ADFieldPark.isEnabled() or self.vehicle.ad.trafficYieldModule == nil then
        return false
    end
    local good, why = ADFieldPark.isGoodWaitingPlace(self.vehicle)
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local onField = AutoDrive.checkIsOnField(x, y, z)
    if good or (why ~= "road" and why ~= "off field" and onField) then
        return false
    end
    if because ~= nil then
        print(string.format("[AD-Suivi] %s: %s et je suis dans l'entree (%s) : je vais me garer dans le champ et je recalcule de la", logName(self.vehicle), tostring(because), tostring(why)))
    else
        print(string.format("[AD-Suivi] %s: appelee en 2e mais %s n'est pas encore en place et je suis dans l'entree (%s) : je vais d'abord me garer dans le champ", logName(self.vehicle), logName(self.targetVehicle), tostring(why)))
    end
    self.parkSearch = ADFieldPark.newSearch(self.vehicle)
    self.state = DriveToVehicleTask.STATE_PARK_SEARCH
    return true
end

function DriveToVehicleTask:parkGiveUp(reason)
    ADFieldPark.setParked(self.vehicle, nil)
    self.parkSpot = nil
    print(string.format("[AD-Suivi] %s: pas de place dans le champ (%s), j'attends ici que %s soit en place", logName(self.vehicle), tostring(reason), logName(self.targetVehicle)))
    self.state = DriveToVehicleTask.STATE_WAIT_FOR_FIRST
end

function DriveToVehicleTask:planToParkSpot()
    self.parkIndex = (self.parkIndex or 0) + 1
    local spot = self.parkSpots ~= nil and self.parkSpots[self.parkIndex] or nil
    if spot == nil or self.parkIndex > ADFieldPark.MAX_TRIES then
        self:parkGiveUp(self.parkIndex == 1 and "aucune place libre" or "aucun trajet propre vers une place")
        return
    end
    self.parkSpot = spot
    ADFieldPark.setParked(self.vehicle, spot, true)
    local wayPoints = ADFieldPark.getMemoPath(self.vehicle, spot)
    if wayPoints ~= nil then
        self.vehicle.ad.drivePathModule:setWayPoints(wayPoints)
        self.state = DriveToVehicleTask.STATE_PARK_DRIVE
        return
    end
    local target, leadIn = ADFieldPark.getLeadIn(self.vehicle, spot)
    self.parkLeadIn = leadIn
    wayPoints = ADFieldPark.findDirectPath(self.vehicle, target)
    if wayPoints ~= nil then
        self.vehicle.ad.drivePathModule:setWayPoints(ADFieldPark.appendLeadIn(wayPoints, leadIn))
        self.state = DriveToVehicleTask.STATE_PARK_DRIVE
        return
    end
    if spot.roadside then
        self:planToParkSpot()
        return
    end
    self.parkPlanTime = 0
    local pfm = self.vehicle.ad.pathFinderModule
    pfm:reset()
    pfm:startPathPlanningTo({x = target.x, y = target.y, z = target.z}, {x = target.dirX, z = target.dirZ})
    self.state = DriveToVehicleTask.STATE_PARK_PLAN
end

function DriveToVehicleTask:updatePark(dt)
    if self.state == DriveToVehicleTask.STATE_PARK_SEARCH then
        self:stopHere(dt)
        local spots = ADFieldPark.searchStep(self.parkSearch)
        if spots ~= nil then
            if self.parkSearch.result ~= nil then
                print(string.format("[AD-Suivi] %s: recherche de place : %s", logName(self.vehicle), tostring(self.parkSearch.result)))
            end
            self.parkSearch = nil
            self.parkSpots = spots
            self.parkIndex = 0
            self:planToParkSpot()
        end
    elseif self.state == DriveToVehicleTask.STATE_PARK_PLAN then
        local pfm = self.vehicle.ad.pathFinderModule
        self.parkPlanTime = (self.parkPlanTime or 0) + dt
        if pfm:hasFinished() then
            local wayPoints = pfm:getPath()
            local crosses = wayPoints ~= nil and #wayPoints > 1 and WaitForCallTask ~= nil and WaitForCallTask.pathCrossesCrop ~= nil and WaitForCallTask.pathCrossesCrop(self, wayPoints, pfm)
            if wayPoints == nil or #wayPoints <= 1 or pfm.fallBackMode3 or crosses then
                print(string.format("[AD-Suivi] %s: place %d : %s, place suivante", logName(self.vehicle), self.parkIndex, crosses and "le trajet traverse la culture" or "pas de trajet"))
                self:planToParkSpot()
            else
                self.vehicle.ad.drivePathModule:setWayPoints(ADFieldPark.appendLeadIn(wayPoints, self.parkLeadIn))
                self.state = DriveToVehicleTask.STATE_PARK_DRIVE
            end
        elseif self.parkPlanTime > DriveToVehicleTask.PARK_PLAN_TIMEOUT then
            pfm:reset()
            print(string.format("[AD-Suivi] %s: place %d : calcul trop long, place suivante", logName(self.vehicle), self.parkIndex))
            self:planToParkSpot()
        else
            pfm:update(dt)
            self:stopHere(dt)
        end
    elseif self.state == DriveToVehicleTask.STATE_PARK_DRIVE then
        if self.vehicle.ad.drivePathModule:isTargetReached() then
            ADFieldPark.setParked(self.vehicle, self.parkSpot, false)
            self.parkedInField = true
            print(string.format("[AD-Suivi] %s: garee dans le champ, l'entree est libre, j'attends que %s soit en place", logName(self.vehicle), logName(self.targetVehicle)))
            self.state = DriveToVehicleTask.STATE_WAIT_FOR_FIRST
        else
            self.vehicle.ad.drivePathModule:update(dt)
        end
    end
end

function DriveToVehicleTask:leaveParkSpot()
    if self.parkSpot ~= nil and ADFieldPark ~= nil then
        ADFieldPark.setParked(self.vehicle, nil)
    end
    self.parkSpot = nil
    self.parkedInField = nil
end
