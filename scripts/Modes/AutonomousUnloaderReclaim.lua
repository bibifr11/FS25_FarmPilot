-- ============================================================================================================
-- FarmPilot : AutonomousUnloaderReclaim.lua
-- Benne qui rentre au garage : la moissonneuse qui cherche une benne peut la reprendre (choix automatique,
-- AutonomousUnloaderAutoPick.lua).
--
-- (17/11) Champ 7 fini, le 7R Gen2 350 allait vider au « Stock Ferme » puis rentrer au garage (bouton parking).
-- Pendant ce temps, la Lexion au champ 5 cherchait une benne : « refus 7R Gen2 350 : actif ». Aucune autre benne
-- libre, la Lexion attendait, et le 7R allait se garer.
--
-- Règle (17/11) :
-- - Un tracteur dont il ne reste que « vider puis garage », ou seulement « garage », compte comme libre pour le choix
--   automatique des bennes (homeStage) :
--   . bouton parking avec la benne pas vide (AutonomousParkUnload.lua : parkUnloadStage) : « vider » ;
--   . fin de chantier de sa machine en « Décharger moissonneuse », benne chargée qui part vider avant le parking
--     (CombineUnloaderModeJobDone.lua : sortie du champ, route vers le déchargement) : « vider » ;
--   . dépose de l'outil puis parking du tracteur (AutonomousMode : parkStage « tool » ou « tractor », pas pendant le
--     dételage, pas un changement d'outil), fin de chantier vers le parking (STATE_PARK, retour au point de départ),
--     parking d'origine d'AutoDrive (onRouteToPark) : « garage ».
-- - Sa benne compte comme vide dans le choix (elle sera vidée avant de repartir) ; le reste du choix ne change pas
--   (puissance, attelage, produit, destination de déchargement).
-- - « vider » : il finit de vider là où il allait (jamais de mélange de produits), puis va à la moissonneuse au lieu
--   du garage. Benne pas vidée (rien ne se vide) : la reprise est annulée, il rentre au garage comme avant.
-- - « garage » : arrêté tout de suite, puis parti à la moissonneuse à l'image suivante.
-- - En attendant, il compte comme une benne qui la sert (pas d'appel d'une 2e benne).
-- - Au moment de repartir : moissonneuse partie, ou une autre benne la sert déjà = reprise annulée, garage comme
--   avant. Arrêté autrement (bouton, erreur) : reprise annulée.
-- - Départ : comme le choix automatique (ADUnloaderAutoPick.launch), étapes notées par le bouton Marche/Arrêt
--   oubliées (c'est un nouveau travail).
-- - Journal : « [AD-Chantier] <machine>: <tracteur> rentrait au garage : ... ».
--
-- Branché par : AutonomousUnloaderAutoPick.lua (tractorRefusal, choose, launch, hasUnloader) ; une ligne dans
-- Specialization.lua (après l'arrêt, avant la suite du bouton parking) ; enveloppe posée au chargement sur
-- CombineUnloaderMode:getParkAfterJobStepTask. Chargé par register.lua après AutonomousParkUnload.lua.
-- ============================================================================================================

ADUnloaderReclaim = {}

ADUnloaderReclaim.MIN_LITERS = 50 -- l : en dessous, la benne compte comme vide (comme AutonomousParkUnload.lua)

local function trace(fmt, ...)
    local ok, text = FarmPilotCall(string.format, fmt, ...)
    text = ok and text or tostring(fmt)
    print("[AD-Chantier] " .. text)
    if ADAutonomousManager ~= nil and ADAutonomousManager.log ~= nil then
        FarmPilotCall(ADAutonomousManager.log, "%s", text)
    end
end

local function nameOf(v)
    local sm = v ~= nil and v.ad ~= nil and v.ad.stateModule or nil
    if sm ~= nil and sm.getName ~= nil then
        return tostring(sm:getName())
    end
    return tostring(v ~= nil and v.getName ~= nil and v:getName() or "?")
end

local function isGone(v)
    return v == nil or v.isDeleted == true or v.isDeleting == true
end

-- litres dans les bennes attelées
function ADUnloaderReclaim.load(v)
    if ADParkUnload ~= nil and ADParkUnload.load ~= nil then
        local ok, level = FarmPilotCall(ADParkUnload.load, v)
        if ok and type(level) == "number" then
            return level
        end
    end
    return 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Ce qui reste au tracteur : « unload » (vider puis garage), « park » (garage seulement), nil (autre chose)
-- ------------------------------------------------------------------------------------------------------------
function ADUnloaderReclaim.homeStage(v)
    local ad = v ~= nil and v.ad or nil
    local sm = ad ~= nil and ad.stateModule or nil
    if sm == nil or not sm:isActive() or ad.isStoppingWithError then
        return nil
    end
    if AutoDrive.getIsCPActive ~= nil and AutoDrive:getIsCPActive(v) then
        return nil
    end
    local mode = sm:getMode()
    if mode == AutoDrive.MODE_AUTONOMOUS then
        local am = ad.modes ~= nil and ad.modes[AutoDrive.MODE_AUTONOMOUS] or nil
        if am == nil then
            return nil
        end
        if am.parkUnloadStage ~= nil then
            return am.parkUnloadGaveUp and nil or "unload"
        end
        if (am.parkStage == "tool" or am.parkStage == "tractor") and am.parkThen == nil then
            return "park"
        end
        return nil
    end
    if mode == AutoDrive.MODE_UNLOAD and ad.harvestJobDone then
        local um = ad.modes ~= nil and ad.modes[AutoDrive.MODE_UNLOAD] or nil
        if um == nil then
            return nil
        end
        if um.state == CombineUnloaderMode.STATE_PARK then
            return "park"
        end
        if um.getParkAfterJobMarker == nil or um:getParkAfterJobMarker() == nil then
            return nil -- sans parking : il retourne au champ, pas au garage
        end
        if um.state == CombineUnloaderMode.STATE_EXIT_FIELD or um.state == CombineUnloaderMode.STATE_DRIVE_TO_UNLOAD then
            return "unload"
        end
        if um.state == CombineUnloaderMode.STATE_DRIVE_TO_START then
            return "park"
        end
        return nil
    end
    if mode == AutoDrive.MODE_DRIVETO and ad.onRouteToPark then
        return "park"
    end
    return nil
end

-- tracteur en attente de reprise pour cette machine
function ADUnloaderReclaim.pendingFor(v, h)
    local r = v ~= nil and v.ad ~= nil and v.ad.fpReclaim or nil
    return r ~= nil and r.h == h and not isGone(v)
end

-- ------------------------------------------------------------------------------------------------------------
-- Pris par le choix automatique (ADUnloaderAutoPick.launch) : nil = pris ; sinon la raison
-- ------------------------------------------------------------------------------------------------------------
function ADUnloaderReclaim.take(h, pair, fieldMarker)
    local v = pair.tractor
    local stage = ADUnloaderReclaim.homeStage(v)
    if stage == nil then
        return "ne rentre plus au garage"
    end
    v.ad.fpReclaim = { h = h, pair = pair, marker = fieldMarker, since = g_time }
    if stage == "unload" then
        trace("%s: %s rentrait au garage : finit de vider (%.0f l), puis va a %s au lieu du garage", nameOf(h), nameOf(v),
            ADUnloaderReclaim.load(v), tostring(fieldMarker.name))
        return nil
    end
    trace("%s: %s rentrait au garage (vide) : arrete, puis part a %s", nameOf(h), nameOf(v), tostring(fieldMarker.name))
    v.ad.fpReclaimGo = true
    v:stopAutoDrive()
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin de chantier en « Décharger moissonneuse » : vidée, au lieu de la route du parking (enveloppe ci-dessous)
-- ------------------------------------------------------------------------------------------------------------
-- true = arrêt pour la reprise (la tâche d'arrêt est renvoyée), false = parking comme avant
function ADUnloaderReclaim.afterJobDoneUnload(mode)
    local v = mode.vehicle
    local r = v.ad.fpReclaim
    if r == nil or mode.state ~= CombineUnloaderMode.STATE_DRIVE_TO_UNLOAD then
        return false
    end
    local why = ADUnloaderReclaim.cancelReason(v, r)
    if why ~= nil then
        trace("%s: reprise de %s annulee (%s) : il rentre au garage", nameOf(r.h), nameOf(v), why)
        v.ad.fpReclaim = nil
        return false
    end
    v.ad.fpReclaimGo = true
    return true
end

-- pourquoi la reprise n'a plus lieu (nil : elle a lieu)
function ADUnloaderReclaim.cancelReason(v, r)
    if isGone(r.h) then
        return "moissonneuse partie"
    end
    local level = ADUnloaderReclaim.load(v)
    if level >= ADUnloaderReclaim.MIN_LITERS then
        return string.format("benne pas videe, reste %.0f l", level)
    end
    if ADUnloaderAutoPick ~= nil and ADUnloaderAutoPick.hasUnloader ~= nil then
        local served, by = ADUnloaderAutoPick.hasUnloader(r.h, r.marker, v)
        if served then
            return string.format("%s la sert deja", nameOf(by))
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Après l'arrêt (Specialization.lua, après ADParkButton.afterStop, avant ADParkUnload.afterStop)
-- ------------------------------------------------------------------------------------------------------------
function ADUnloaderReclaim.afterStop(v)
    local r = v ~= nil and v.ad ~= nil and v.ad.fpReclaim or nil
    if r == nil then
        return
    end
    local go = v.ad.fpReclaimGo == true or v.ad.fpParkUnloadContinue == true
    v.ad.fpReclaimGo = nil
    v.ad.fpReclaim = nil
    if v.ad.isStoppingWithError or not go then
        trace("%s: reprise de %s annulee (arrete avant)", nameOf(r.h), nameOf(v))
        return
    end
    local why = ADUnloaderReclaim.cancelReason(v, r)
    if why ~= nil then
        trace("%s: reprise de %s annulee (%s) : il rentre au garage", nameOf(r.h), nameOf(v), why)
        if v.ad.fpParkUnloadContinue ~= true then
            -- arrêté pour la reprise : la route du garage reprend (bouton parking, suite habituelle)
            v.ad.fpParkUnloadContinue = true
        end
        return
    end
    v.ad.fpParkUnloadContinue = nil -- pas la suite du bouton parking
    v.ad.fpReclaimPending = r
    local function go_()
        ADUnloaderReclaim.launchNow(v)
    end
    local mission = g_currentMission
    if mission ~= nil and mission.addUpdateable ~= nil and mission.removeUpdateable ~= nil then
        local once = {}
        once.update = function(self, dt)
            mission:removeUpdateable(self)
            go_()
        end
        mission:addUpdateable(once)
    else
        go_()
    end
end

function ADUnloaderReclaim.launchNow(v)
    local r = v.ad.fpReclaimPending
    v.ad.fpReclaimPending = nil
    if r == nil or v.ad.stateModule:isActive() then
        return
    end
    if ADResumeButton ~= nil and ADResumeButton.forget ~= nil then
        ADResumeButton.forget(v.ad.stateModule) -- nouveau travail : rien à reprendre
    end
    local pair = {}
    for k, val in pairs(r.pair) do
        pair[k] = val
    end
    pair.home = nil
    local ok, why = FarmPilotCall(ADUnloaderAutoPick.launch, r.h, pair, r.marker)
    if ok and why == nil then
        trace("%s: %s repris (au lieu du garage) : part a %s", nameOf(r.h), nameOf(v), tostring(r.marker.name))
        return
    end
    trace("%s: %s pas reparti (%s) : il rentre au garage", nameOf(r.h), nameOf(v), ok and tostring(why) or ("ERREUR " .. tostring(why)))
    if not v.ad.stateModule:isActive() and ADParkUnload ~= nil and ADParkUnload.continueToPark ~= nil then
        ADParkUnload.continueToPark(v)
    end
end

-- tracteur enlevé du jeu, ou reprise oubliée : rien à faire de plus ici (vehicle.ad disparaît avec lui)

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppe (posée au chargement)
-- ------------------------------------------------------------------------------------------------------------
if CombineUnloaderMode ~= nil and CombineUnloaderMode.getParkAfterJobStepTask ~= nil then
    local baseStep = CombineUnloaderMode.getParkAfterJobStepTask
    function CombineUnloaderMode:getParkAfterJobStepTask(...)
        local ok, stop = FarmPilotCall(ADUnloaderReclaim.afterJobDoneUnload, self)
        if ok and stop then
            self.vehicle.ad.harvestJobDone = nil
            self.vehicle.ad.onRouteToPark = false
            return StopAndDisableADTask:new(self.vehicle, ADTaskModule.DONT_PROPAGATE)
        end
        return baseStep(self, ...)
    end
end
