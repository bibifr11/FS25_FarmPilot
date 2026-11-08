-- Silo vide : au chargement, si la benne a déjà quelque chose et que plus rien
-- n'entre pendant 30 s, AutoDrive repart avec ce qu'il a au lieu d'attendre

ADAddonSiloEmpty = {}

ADAddonSiloEmpty.WAIT_TIME = 30000

function ADAddonSiloEmpty.install(autoDrive)
    local loadTask = ADAddon.getAutoDriveGlobal("LoadAtDestinationTask")
    if loadTask == nil or loadTask.update == nil then
        ADAddon.warning("LoadAtDestinationTask not found, empty silo departure inactive")
        return
    end

    local originalSetUp = loadTask.setUp
    loadTask.setUp = function(self, ...)
        self.adAddonLastFill = nil
        self.adAddonStillTime = 0
        return originalSetUp(self, ...)
    end

    local originalUpdate = loadTask.update
    loadTask.update = function(self, dt)
        if self.fpKeepLoading then return originalUpdate(self, dt) end -- plein du semoir FarmPilot : attend plein ou Continuer (Modes/AutonomousRefill.lua)
        local vehicle = self.vehicle
        if self.state == loadTask.STATE_DRIVING and self.trailers ~= nil and #self.trailers > 0
            and vehicle.ad ~= nil and not vehicle.ad.hasAL
            and (vehicle.ad.drivePathModule:isTargetReached() or vehicle.ad.trailerModule:isActiveAtTrigger()) then

            local fillLevel = autoDrive.getAllFillLevels(self.trailers)
            if fillLevel > 0 and self.adAddonLastFill ~= nil and fillLevel <= self.adAddonLastFill + 0.01 then
                self.adAddonStillTime = (self.adAddonStillTime or 0) + dt
            else
                self.adAddonStillTime = 0
                self.adAddonLastFill = fillLevel
            end

            if self.adAddonStillTime >= ADAddonSiloEmpty.WAIT_TIME then
                self.adAddonStillTime = 0
                self.adAddonLastFill = nil
                if vehicle.ad.trailerModule.stopLoading ~= nil then
                    vehicle.ad.trailerModule:stopLoading()
                end
                self:finished()
                return
            end
        else
            self.adAddonStillTime = 0
            self.adAddonLastFill = nil
        end

        return originalUpdate(self, dt)
    end

end

ADAddon.addModule(ADAddonSiloEmpty)
