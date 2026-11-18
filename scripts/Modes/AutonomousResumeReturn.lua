-- ============================================================================================================
-- FarmPilot : AutonomousResumeReturn.lua
-- Mode Autonome : le retour au garage reprend après le chargement de la partie et après la remise à zéro
-- d'AutoDrive (15/11).
--
-- Défaut (15/11, ARION 570, champ 92, broyeur) : le tracteur rentrait (bouton parking : l'outil à sa place, puis le
-- tracteur à la sienne). Partie sauvegardée et rechargée : il repartait au champ et recommençait le travail.
-- Pareil le matin même sans rechargement : coincé 8 s sur la route du retour, AutoDrive est arrêté puis relancé
-- (ADDrivePathModule:handleBeingStuck → ADTaskModule:stopAndRestartAD) ; la relance appelle AutonomousMode:start(),
-- qui remet tout à zéro (reset) et part au champ.
-- Cause : l'étape du retour (parkStage, outil, place du tracteur) n'est ni sauvegardée ni gardée à la relance.
--
-- Règle :
-- - « En train de rentrer » = mode Autonome en marche avec une étape de parking (outil vers sa place, dételage,
--   tracteur vers sa place, outil avant, barre de moissonneuse), sauf le changement d'outil avant le champ suivant
--   (parkThen « swap ») et le petit recul après un attelage avant de partir au travail (parkThen « restart ») ; aussi la benne qui va vider avant de se garer (AutonomousParkUnload.lua) et l'épandeur qui
--   va rendre son reste avant de se garer (AutonomousSprayerDump.lua, après « park »).
-- - Sauvegarde : #fpAutoReturn écrit pour un véhicule en train de rentrer. Véhicule pas encore reparti depuis le
--   chargement : la valeur lue est gardée.
-- - Relance après blocage : la remise à zéro d'un véhicule en train de rentrer est notée.
-- - Au départ suivant (relance automatique des aides au chargement, ou relance après blocage), une seule fois : au
--   lieu de partir au champ, il continue de rentrer, par le même chemin que le bouton parking
--   (ADInputManager:input_parkVehicle : reste à vider, outil à sa place, puis le tracteur à la sienne ; outil déjà
--   posé : le tracteur va directement à sa place).
-- - Bloqué encore et encore pendant le retour : au bout de RESTART_MAX relances en RESTART_WINDOW ms, plus de
--   relance, il s'arrête (le message « est bloqué » est déjà affiché) au lieu de tourner sans fin.
-- - Arrêt et départ à la main par le joueur : rien ne change (départ habituel). Une relance notée qui n'a pas eu
--   lieu dans les RESTART_VALID ms (arrêté entre-temps) est oubliée.
-- - Bouton parking lancé depuis un autre mode (Chargement, Livraison… : le mode d'avant revient à l'arrêt, voir
--   AutonomousParkButton.lua) : la relance après blocage reste celle d'avant (ce mode-là reprend son travail).
-- - (18/11) Mission donnée par FarmPilot (barre de moissonneuse, chargeur, silo : fpHeaderJob, fpLoaderJob, fpSiloJob) :
--   le retour gardé est oublié, la mission part (avant : le tracteur appelé repartait se garer).
-- - Journal : « [FarmPilot Reprise] <véhicule> : … il continue de rentrer … ».
--
-- Branché par : enveloppes posées au chargement de ce fichier sur ADSavegameResume.save / .load
-- (SavegameResume.lua), AutonomousMode:start et ADTaskModule:stopAndRestartAD ; clé #fpAutoReturn déclarée dans
-- Specialization.lua. Chargé par register.lua après AutonomousMode.lua et AutonomousHeader.lua.
-- ============================================================================================================

ADResumeReturn = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADResumeReturn.RESTART_MAX = 3         -- relances après blocage pendant le retour…
ADResumeReturn.RESTART_WINDOW = 180000 -- …en moins de ce temps (ms) : plus de relance, arrêt
ADResumeReturn.RESTART_VALID = 30000   -- ms : relance notée pas reprise dans ce temps (arrêt entre-temps) = oubliée

local function log(fmt, ...)
    if ADSavegameResume ~= nil and ADSavegameResume.log ~= nil then
        ADSavegameResume.log(fmt, ...)
        return
    end
    local ok, s = pcall(string.format, fmt, ...)
    print("[FarmPilot Reprise] " .. (ok and s or tostring(fmt)))
end

local function nameOf(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    return sm ~= nil and sm.getName ~= nil and tostring(sm:getName()) or "?"
end

local function autonomousMode(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.modes == nil or AutoDrive.MODE_AUTONOMOUS == nil then
        return nil
    end
    return vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS]
end

-- ------------------------------------------------------------------------------------------------------------
-- En train de rentrer ?
-- ------------------------------------------------------------------------------------------------------------
-- l'étape du retour (texte pour le journal) ; nil s'il ne rentre pas
function ADResumeReturn.returnStage(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or not sm:isActive() or sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return nil
    end
    local mode = autonomousMode(vehicle)
    if mode == nil then
        return nil
    end
    -- (15/11) petit recul après l'attelage puis départ au travail (parkThen « restart ») : il ne rentre pas
    if mode.parkStage ~= nil and mode.parkThen ~= "swap" and mode.parkThen ~= "restart" then
        return tostring(mode.parkStage)
    end
    if mode.parkUnloadStage ~= nil then
        return "vider avant de se garer"
    end
    if mode.dumpStage ~= nil and vehicle.ad.fpDumpThen == "park" then
        return "rendre le reste avant de se garer"
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Sauvegarde (enveloppes de SavegameResume.lua)
-- ------------------------------------------------------------------------------------------------------------
if ADSavegameResume ~= nil then
    local baseSave = ADSavegameResume.save
    function ADSavegameResume.save(stateModule, xmlFile, key, ...)
        if baseSave ~= nil then
            baseSave(stateModule, xmlFile, key, ...)
        end
        local ok, err = FarmPilotCall(function()
            local value = nil
            if stateModule.active then
                local stage = ADResumeReturn.returnStage(stateModule.vehicle)
                if stage ~= nil then
                    value = "park"
                end
            else
                value = stateModule.fpAutoReturn == "park" and "park" or nil -- pas encore reparti depuis le chargement
            end
            if value ~= nil then
                xmlFile:setValue(key .. "#fpAutoReturn", value)
            end
        end)
        if not ok then
            log("ERREUR sauvegarde du retour : %s", tostring(err))
        end
    end

    local baseLoad = ADSavegameResume.load
    function ADSavegameResume.load(stateModule, xmlFile, key, ...)
        if baseLoad ~= nil then
            baseLoad(stateModule, xmlFile, key, ...)
        end
        local ok, value = FarmPilotCall(xmlFile.getValue, xmlFile, key .. "#fpAutoReturn")
        stateModule.fpAutoReturn = (ok and value == "park") and "park" or nil
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Relance après blocage (enveloppe de ADTaskModule:stopAndRestartAD)
-- ------------------------------------------------------------------------------------------------------------
-- true si la relance est notée ; false si c'est la relance de trop (arrêt sans relance)
function ADResumeReturn.noteRestart(vehicle)
    local sm = vehicle.ad.stateModule
    local now = g_time or 0
    local r = sm.fpAutoReturnRestarts
    if r == nil or now < r.first or now - r.first > ADResumeReturn.RESTART_WINDOW then
        r = { first = now, count = 0 }
        sm.fpAutoReturnRestarts = r
    end
    r.count = r.count + 1
    if r.count >= ADResumeReturn.RESTART_MAX then
        sm.fpAutoReturnRestarts = nil
        sm.fpAutoReturn = nil
        return false
    end
    sm.fpAutoReturn = "restart"
    sm.fpAutoReturnTime = now
    return true
end

if ADTaskModule ~= nil and ADTaskModule.stopAndRestartAD ~= nil then
    local baseRestart = ADTaskModule.stopAndRestartAD
    function ADTaskModule:stopAndRestartAD(...)
        local vehicle = self.vehicle
        local okS, stage = FarmPilotCall(ADResumeReturn.returnStage, vehicle)
        if okS and stage ~= nil and vehicle.ad.fpModeBeforePark == nil then
            local okN, noted = FarmPilotCall(ADResumeReturn.noteRestart, vehicle)
            if okN and not noted then
                log("%s : bloqué %d fois pendant le retour en moins de %d min : arrêté sans relance, intervention nécessaire",
                    nameOf(vehicle), ADResumeReturn.RESTART_MAX, math.floor(ADResumeReturn.RESTART_WINDOW / 60000))
                self:abortAllTasks()
                self:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
                return
            end
            if okN then
                log("%s : bloqué pendant le retour (étape %s) : AutoDrive relancé, il continuera de rentrer", nameOf(vehicle), stage)
            end
        end
        return baseRestart(self, ...)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ (enveloppe de AutonomousMode:start) : le retour continue
-- ------------------------------------------------------------------------------------------------------------
-- true si le retour est relancé
function ADResumeReturn.resume(mode, why)
    local vehicle = mode.vehicle
    local sm = vehicle.ad.stateModule
    if ADInputManager == nil or ADInputManager.input_parkVehicle == nil then
        return false
    end
    local name = nameOf(vehicle)
    if why == "restart" then
        log("%s : relancé pendant le retour : il continue de rentrer (comme le bouton parking)", name)
    else
        log("%s : partie rechargée pendant le retour : il continue de rentrer (comme le bouton parking)", name)
    end
    local farmId = sm.getActualFarmId ~= nil and sm:getActualFarmId() or nil
    ADInputManager:input_parkVehicle(vehicle, farmId)
    if not sm:isActive() then
        log("%s : retour pas relancé (pas de place de parking ?) : il reste arrêté", name)
    end
    return true
end

if AutonomousMode ~= nil and AutonomousMode.start ~= nil then
    local baseStart = AutonomousMode.start
    function AutonomousMode:start(user, ...)
        local sm = self.vehicle ~= nil and self.vehicle.ad ~= nil and self.vehicle.ad.stateModule or nil
        local why = sm ~= nil and sm.fpAutoReturn or nil
        if why == "restart" and ((g_time or 0) < (sm.fpAutoReturnTime or 0) or (g_time or 0) - (sm.fpAutoReturnTime or 0) > ADResumeReturn.RESTART_VALID) then
            why = nil -- relance pas faite (arrêté entre-temps) : départ habituel
            sm.fpAutoReturn = nil
        end
        -- (18/11, LEXION 6900 : 7R puis ARION 570 appelés pour la remorque porte-barre, tous deux repartis se garer avec
        -- le retour gardé d'avant le chargement : « aucun tracteur libre ») : mission donnée par FarmPilot = le vieux
        -- retour est oublié, la mission part
        local ad = self.vehicle.ad
        if why ~= nil and (ad.fpHeaderJob ~= nil or ad.fpLoaderJob ~= nil or ad.fpSiloJob ~= nil) then
            sm.fpAutoReturn = nil
            log("%s : nouvelle mission (%s) : le retour d'avant le chargement est oublié", nameOf(self.vehicle),
                ad.fpHeaderJob ~= nil and "barre de moissonneuse" or (ad.fpLoaderJob ~= nil and "chargeur" or "silo"))
            why = nil
        end
        if why ~= nil then
            sm.fpAutoReturn = nil -- une seule fois
            local ok, done = FarmPilotCall(ADResumeReturn.resume, self, why)
            if not ok then
                log("ERREUR reprise du retour : %s", tostring(done))
            elseif done then
                return
            end
        end
        return baseStart(self, user, ...)
    end
end
