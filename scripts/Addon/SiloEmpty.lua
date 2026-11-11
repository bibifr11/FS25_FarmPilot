-- ============================================================================================================
-- FarmPilot : SiloEmpty.lua
-- Addon : silo vide, départ avec ce qu'il y a.
--
-- Règle : au chargement, si la benne a déjà quelque chose et que plus rien n'entre pendant le temps réglé,
-- AutoDrive repart avec ce qu'il a au lieu d'attendre. Sauf pour le plein du semoir en mode Autonome
-- (task.fpKeepLoading, AutonomousRefill.lua : il attend plein ou Continuer).
--
-- (09/11) temps réglable par véhicule (réglage fpSiloEmptyWait, onglet Véhicule) : Non, 15 s, 30 s (par défaut,
-- comme avant), 1 min, 2 min, 5 min. Non = jamais de départ anticipé : il attend le niveau « Remplir jusqu'à »
-- comme AutoDrive d'origine (camion en bord de champ rempli par un transbordeur, qui peut s'arrêter à mi-benne).
-- Un reste de moins de 1 % de la capacité (EMPTY_SHARE) compte comme une benne vide : pas de départ « à vide ».
--
-- Branché par : AutoDriveAddon.lua (install au chargement de la carte : enveloppe LoadAtDestinationTask.setUp et
-- update). AutonomousRefill.lua s'accroche par la 1re ligne de l'update enveloppé (fpKeepLoading). Ligne du réglage :
-- gui/vehicleSettingsPage.xml.
-- ============================================================================================================

ADAddonSiloEmpty = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAddonSiloEmpty.WAIT_TIME = 30000     -- par défaut (réglage absent ou illisible)
ADAddonSiloEmpty.EMPTY_SHARE = 0.01    -- en dessous de 1 % de la capacité, la benne compte comme vide

-- réglage véhicule : menu véhicule FP (0 = Non, jamais de départ anticipé)
AutoDrive.settings = AutoDrive.settings or {}
AutoDrive.settings.fpSiloEmptyWait = {
    values = { 0, 15000, 30000, 60000, 120000, 300000 },
    texts = { "gui_ad_fpSiloEmptyWait_off", "gui_ad_fpSiloEmptyWait_15", "gui_ad_fpSiloEmptyWait_30",
        "gui_ad_fpSiloEmptyWait_60", "gui_ad_fpSiloEmptyWait_120", "gui_ad_fpSiloEmptyWait_300" },
    default = 3,
    current = 3,
    text = "gui_ad_fpSiloEmptyWait",
    tooltip = "gui_ad_fpSiloEmptyWait_tooltip",
    translate = true,
    isVehicleSpecific = true,
    isUserSpecific = false,
    isCopyPaste = true
}

-- temps d'attente du véhicule en ms ; nil = Non (pas de départ anticipé)
function ADAddonSiloEmpty.waitTime(vehicle)
    local ok, wait = FarmPilotCall(AutoDrive.getSetting, "fpSiloEmptyWait", vehicle)
    if not ok or type(wait) ~= "number" then
        return ADAddonSiloEmpty.WAIT_TIME
    end
    if wait <= 0 then
        return nil
    end
    return wait
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place (au chargement de la carte, par AutoDriveAddon.lua)
-- ------------------------------------------------------------------------------------------------------------
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

            local wait = ADAddonSiloEmpty.waitTime(vehicle)
            if wait == nil then
                self.adAddonStillTime = 0
                self.adAddonLastFill = nil
                return originalUpdate(self, dt)
            end
            local fillLevel, fillCapacity = autoDrive.getAllFillLevels(self.trailers)
            local loaded = fillLevel > math.max(0.01, (fillCapacity or 0) * ADAddonSiloEmpty.EMPTY_SHARE)
            if loaded and self.adAddonLastFill ~= nil and fillLevel <= self.adAddonLastFill + 0.01 then
                self.adAddonStillTime = (self.adAddonStillTime or 0) + dt
            else
                self.adAddonStillTime = 0
                self.adAddonLastFill = fillLevel
            end

            if self.adAddonStillTime >= wait then
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

-- ------------------------------------------------------------------------------------------------------------
-- Enregistrement
-- ------------------------------------------------------------------------------------------------------------
ADAddon.addModule(ADAddonSiloEmpty)
