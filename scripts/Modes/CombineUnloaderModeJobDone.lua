-- ============================================================================================================
-- FarmPilot : CombineUnloaderModeJobDone.lua
-- Complément de CombineUnloaderMode (mode AutoDrive d'origine « décharger la moissonneuse ») : fin de chantier
-- de l'ENSILEUSE (benne qui roule à côté). Ne concerne pas la moissonneuse (benne sous la goulotte).
--
-- (26/10) Quand l'ensileuse a terminé, signal de renvoi au tracteur pour vider ; celles qui sont vides et
-- reviennent vont au garage.
-- (26/10) Sans parking dans leur réglage, elles reviennent au champ.
--
-- Règle : Courseplay arrêté sur l'ensileuse (HarvestManagerChopperJob.lua) = chantier terminé. Chaque benne de
-- cette ensileuse part vider ce qu'elle porte (même peu : JOB_DONE_MIN_LOAD), puis roule jusqu'à sa destination de
-- parking AutoDrive (le « P » du véhicule) et AutoDrive s'arrête ; une benne vide va tout de suite au parking.
-- Sans parking réglé : benne vide = elle reste au champ et attend ; benne chargée = elle vide puis revient au champ.
--
-- Branché par : HarvestManagerChopperJob.lua (onHarvesterJobDone) ; dans CombineUnloaderMode.lua, une ligne dans
-- start (l'ancienne fin de chantier est oubliée) et deux dans getNextTask (étapes vers le parking ; vidée sans
-- parking : retour au champ).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
CombineUnloaderMode.STATE_PARK = {} -- 26/10 17:58: harvester job done, driving to the park destination

-- (26/10) once the forage harvester has finished, its unloaders are sent off to unload; the empty ones coming
-- back go to the garage. The harvester's job is done: whatever this unloader was doing, it leaves to
-- unload what it carries (even a little), then drives to its park destination; an empty one goes to park at once
CombineUnloaderMode.JOB_DONE_MIN_LOAD = 50 -- liters: less is "empty"

-- ------------------------------------------------------------------------------------------------------------
-- Destination de parking, départ de chaque benne à la fin du chantier
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:getParkAfterJobMarker()
    local parkId = self.vehicle.ad.stateModule.getParkDestinationAtJobFinished ~= nil and self.vehicle.ad.stateModule:getParkDestinationAtJobFinished() or -1
    local marker = parkId ~= nil and parkId >= 1 and ADGraphManager:getMapMarkerById(parkId) or nil
    if marker ~= nil and marker.id ~= nil then
        return marker
    end
    return nil
end

function CombineUnloaderMode:onHarvesterJobDone(harvester)
    if self.vehicle.ad.harvestJobDone then
        return
    end
    local name = tostring(self.vehicle:getName())
    local trailers = (self.trailers ~= nil and #self.trailers > 0) and self.trailers or AutoDrive.getAllUnits(self.vehicle)
    local level, capacity = 0, 0
    if trailers ~= nil and #trailers > 0 then
        level, capacity = AutoDrive.getAllFillLevels(trailers)
    end
    local marker = self:getParkAfterJobMarker()
    local loaded = level >= CombineUnloaderMode.JOB_DONE_MIN_LOAD
    -- 26/10 18:06 (no park destination in its settings: back to the field): no park destination and
    -- nothing to unload: it stays where it is and waits, as before
    if marker == nil and not loaded then
        print(string.format("[AD-Chantier] %s: chantier termine, vide (%.0f l) et pas de parking attribue (le P d'AutoDrive) : je reste au champ", name, level))
        return
    end
    self.vehicle.ad.harvestJobDone = true
    self.vehicle.ad.unloaderQueueTime = nil
    self.vehicle.ad.taskModule:abortAllTasks()
    ADHarvestManager.releaseStickyUnloader(self.vehicle, "chantier termine")
    ADHarvestManager:unregisterAsUnloader(self.vehicle, true) -- no promotion: every unloader leaves
    self.combine = nil
    self.followingUnloader = nil
    self.targetUnloader = nil
    local nextTask
    if loaded then
        local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
        local start = self.vehicle.ad.stateModule:getFirstMarker()
        local point = start ~= nil and start.id ~= nil and ADGraphManager:getWayPointById(start.id) or nil
        local distanceToStart = point ~= nil and MathUtil.vector2Length(x - point.x, z - point.z) or 0
        print(string.format("[AD-Chantier] %s: chantier termine, je pars vider (remplie a %.0f %%, %.0f l), puis %s", name, capacity > 0 and level / capacity * 100 or 0, level, marker ~= nil and ("au parking " .. tostring(marker.name)) or "retour au champ (pas de parking attribue)"))
        if AutoDrive.checkIsOnField(x, y, z) and distanceToStart > 30 then
            nextTask = ExitFieldTask:new(self.vehicle)
            self.state = self.STATE_EXIT_FIELD
        else
            nextTask = UnloadAtDestinationTask:new(self.vehicle, self.vehicle.ad.stateModule:getSecondMarker().id)
            self.state = self.STATE_DRIVE_TO_UNLOAD
        end
    else
        nextTask = self:getParkAfterJobTask(string.format("chantier termine, vide (%.0f l)", level))
    end
    self.activeTask = nextTask
    if nextTask ~= nil then
        self.vehicle.ad.taskModule:addTask(nextTask)
    end
end

-- the drive to the park destination (AutoDrive's "P" of the vehicle). Without one (26/10 18:06): back to the
-- field target and waiting for a call, as before; nil = the usual way
function CombineUnloaderMode:getParkAfterJobTask(reason)
    local fpDrop = ADTrailerHitch ~= nil and ADTrailerHitch.parkAfterJobTask(self) or nil if fpDrop ~= nil then return fpDrop end -- remorque choisie : à sa place d'abord, voir TrailerHitch.lua
    local name = tostring(self.vehicle:getName())
    local marker = self:getParkAfterJobMarker()
    if marker == nil then
        print(string.format("[AD-Chantier] %s: %s, pas de parking attribue (le P d'AutoDrive) : je retourne au champ et j'attends", name, tostring(reason)))
        self.vehicle.ad.harvestJobDone = nil
        self.parkAfterJobName = nil
        return nil
    end
    print(string.format("[AD-Chantier] %s: %s, je rentre au parking %s", name, tostring(reason), tostring(marker.name)))
    self.state = self.STATE_PARK
    self.vehicle.ad.onRouteToPark = true
    self.parkAfterJobName = marker.name
    return DriveToDestinationTask:new(self.vehicle, marker.id)
end

-- ------------------------------------------------------------------------------------------------------------
-- Étapes suivantes (accroches dans CombineUnloaderMode:getNextTask)
-- ------------------------------------------------------------------------------------------------------------
-- vidée, ou de retour au champ, après la fin de chantier : vers le parking ; arrivée au parking : AutoDrive s'arrête
function CombineUnloaderMode:isParkAfterJobStep()
    return (self.state == self.STATE_DRIVE_TO_UNLOAD and self.vehicle.ad.harvestJobDone and self:getParkAfterJobMarker() ~= nil)
        or self.state == self.STATE_PARK
        or (self.state == self.STATE_DRIVE_TO_START and self.vehicle.ad.harvestJobDone and self:getParkAfterJobMarker() ~= nil)
end

function CombineUnloaderMode:getParkAfterJobStepTask()
    if self.state == self.STATE_DRIVE_TO_UNLOAD then
        -- 26/10 17:58: unloaded after the harvester's end of job: to the park destination, not back to the field
        return self:getParkAfterJobTask("vide, chantier termine")
    elseif self.state == self.STATE_PARK then
        self.vehicle.ad.onRouteToPark = false
        print(string.format("[AD-Chantier] %s: arrive%s, AutoDrive s'arrete", tostring(self.vehicle:getName()), self.parkAfterJobName ~= nil and (" au parking " .. tostring(self.parkAfterJobName)) or " au point de depart"))
        if self.parkAfterJobName ~= nil then
            AutoDriveMessageEvent.sendMessageOrNotification(self.vehicle, ADMessagesManager.messageTypes.INFO, "$l10n_AD_Driver_of; %s $l10n_AD_has_reached; %s", 5000, self.vehicle.ad.stateModule:getName(), self.parkAfterJobName)
        end
        return StopAndDisableADTask:new(self.vehicle, ADTaskModule.DONT_PROPAGATE)
    end
    return self:getParkAfterJobTask("chantier termine")
end

-- vidée sans parking réglé : retour au champ comme avant, la fin de chantier est oubliée
function CombineUnloaderMode:forgetJobDoneWithoutPark()
    if self.vehicle.ad.harvestJobDone then
        print(string.format("[AD-Chantier] %s: videe, pas de parking attribue : je retourne au champ et j'attends", tostring(self.vehicle:getName())))
        self.vehicle.ad.harvestJobDone = nil
    end
end
