-- ============================================================================================================
-- FarmPilot : MotorStartWait.lua
-- Démarrage du moteur au lancement de FarmPilot.
--
-- (15/11) FarmPilot lancé moteur éteint : le tracteur partait tout de suite, pendant que le moteur démarrait.
-- Règle :
-- - Lancement (AutoDrive:startAutoDrive : bouton Marche/Arrêt, partie rechargée, relance par un mode) avec le moteur
--   éteint : le moteur est démarré et le tracteur reste arrêté DURATION ms, le temps que le moteur démarre. Le titre
--   de la fenêtre FarmPilot affiche « Démarre (5 s) », avec le temps qui décompte (4 s, 3 s...).
-- - Moteur déjà en marche : départ tout de suite, comme avant.
-- - Pendant l'attente, rien d'autre ne part : pas de mise à jour des tâches (comme le repli des outils,
--   AutoDriveFoldGuard.lua), donc pas de calcul de trajet ni de contrôle « bloqué » qui compterait ces 5 s.
-- - FarmPilot arrêté pendant l'attente : l'attente est oubliée.
--
-- Branché par une ligne dans Specialization.lua : AutoDrive:startAutoDrive (arm) et AutoDrive:onUpdate (update,
-- juste après ADFoldGuard.update).
-- ============================================================================================================

ADMotorStartWait = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADMotorStartWait.DURATION = 5000   -- ms d'attente au lancement, moteur éteint
ADMotorStartWait.TEXT = "$l10n_AD_task_fpMotorStart;"

local function nameOf(vehicle)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.getName ~= nil then
        return tostring(vehicle.ad.stateModule:getName())
    end
    return "?"
end

local function motorOff(vehicle)
    return vehicle.startMotor ~= nil and vehicle.getIsMotorStarted ~= nil and not vehicle:getIsMotorStarted()
end

local function startMotor(vehicle)
    if motorOff(vehicle) and (vehicle.getCanMotorRun == nil or vehicle:getCanMotorRun()) then
        vehicle:startMotor()
    end
end

-- texte du titre : « Démarre (5 s) » ; secondes restantes arrondies au-dessus
function ADMotorStartWait.text(leftMs)
    return ADMotorStartWait.TEXT .. string.format(" (%d s)", math.max(0, math.ceil(leftMs / 1000)))
end

-- ------------------------------------------------------------------------------------------------------------
-- Lancement : appelé par AutoDrive:startAutoDrive, juste après la mise en marche
-- ------------------------------------------------------------------------------------------------------------
function ADMotorStartWait.arm(vehicle)
    local ad = vehicle ~= nil and vehicle.ad or nil
    if ad == nil then
        return
    end
    ad.fpMotorWait = nil
    if not motorOff(vehicle) then
        return
    end
    local now = g_time or 0
    ad.fpMotorWait = { untilTime = now + ADMotorStartWait.DURATION, shown = nil }
    startMotor(vehicle)
    print(string.format("[FarmPilot] %s : lancé moteur éteint, démarrage du moteur, départ dans %d s", nameOf(vehicle), ADMotorStartWait.DURATION / 1000))
end

-- ------------------------------------------------------------------------------------------------------------
-- Attente : rend allowTaskUpdate, shouldStopVehicle (inchangés quand rien n'attend)
-- ------------------------------------------------------------------------------------------------------------
function ADMotorStartWait.update(vehicle, dt, allowTaskUpdate, shouldStopVehicle)
    local ad = vehicle ~= nil and vehicle.ad or nil
    local w = ad ~= nil and ad.fpMotorWait or nil
    if w == nil then
        return allowTaskUpdate, shouldStopVehicle
    end
    if ad.stateModule == nil or not ad.stateModule:isActive() then
        ad.fpMotorWait = nil
        return allowTaskUpdate, shouldStopVehicle
    end
    local left = w.untilTime - (g_time or 0)
    if left <= 0 then
        ad.fpMotorWait = nil
        -- le titre revient au texte de la tâche à la mise à jour suivante
        if ad.taskModule ~= nil then
            ad.taskModule.lastTaskInfo = nil
        end
        print(string.format("[FarmPilot] %s : moteur démarré, départ", nameOf(vehicle)))
        return allowTaskUpdate, shouldStopVehicle
    end
    startMotor(vehicle)
    local text = ADMotorStartWait.text(left)
    if w.shown ~= text then
        w.shown = text
        ad.stateModule:setCurrentTaskInfo(text)
    end
    return false, true
end

-- en attente de démarrage (pour les autres scripts) ; FarmPilot arrêté : plus d'attente (oubliée au lancement suivant)
function ADMotorStartWait.isWaiting(vehicle)
    local ad = vehicle ~= nil and vehicle.ad or nil
    return ad ~= nil and ad.fpMotorWait ~= nil and ad.stateModule ~= nil and ad.stateModule:isActive() and (g_time or 0) < ad.fpMotorWait.untilTime
end
