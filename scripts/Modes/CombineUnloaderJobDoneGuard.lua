-- ============================================================================================================
-- FarmPilot : CombineUnloaderJobDoneGuard.lua
-- Benne de moissonneuse (ou d'ensileuse) à la fin du chantier : la fin de chantier n'est plus oubliée en route.
--
-- Règle (15/11, champ 77 : benne John Deere partie vider à 9 %, sortie au plus court au lieu de l'entrée, revenue
-- dans le champ en marche arrière, puis « Chargé, attend un appel » alors que la moissonneuse était rentrée à la
-- ferme ; règle 7A+ : en fin de champ, benne vider + garage) :
-- - Quand la benne part à la fin du chantier (onHarvesterJobDone, avec un parking réglé), la fin de chantier est
--   notée à part (vehicle.ad.fpJobDone : machine, 1re destination, heure). Elle survit à une relance de la benne
--   (stopAndRestartAD, start hors bouton du joueur), qui effaçait harvestJobDone.
-- - Tant qu'elle est notée et que la 1re destination n'a pas changé : la benne ne se met jamais en attente d'appel.
--   Chargée (JOB_DONE_MIN_LOAD l ou plus) : elle repart vider, puis au parking ; vide : directement au parking.
-- - Relancée hors bouton du joueur : même chose tout de suite (pas de retour au champ d'abord).
-- - Effacée : appelée par une machine (assignToHarvester), relancée par le joueur, 1re destination changée (elle
--   suit sa moissonneuse au champ suivant), arrivée au parking.
-- - Traces [AD-Chantier] à chaque relance d'une benne en fin de chantier et à chaque attente d'appel évitée.
--
-- Branché par : enveloppes de CombineUnloaderMode (onHarvesterJobDone, start, setToWaitForCall, assignToHarvester,
-- getParkAfterJobStepTask) et ADTaskModule:stopAndRestartAD (trace). Chargé par register.lua après
-- AutonomousResumeHeader.lua.
-- ============================================================================================================

ADJobDoneGuard = ADJobDoneGuard or {}

local function nameOf(v)
    return v ~= nil and v.getName ~= nil and tostring(v:getName()) or "?"
end

local function log(fmt, ...)
    print("[AD-Chantier] " .. string.format(fmt, ...))
end

-- la fin de chantier notée vaut encore pour cette benne ?
function ADJobDoneGuard.active(mode)
    local v = mode ~= nil and mode.vehicle or nil
    local memo = v ~= nil and v.ad ~= nil and v.ad.fpJobDone or nil
    if memo == nil then
        return nil
    end
    local sm = v.ad.stateModule
    if sm == nil or sm:getFirstMarker() ~= memo.marker then
        v.ad.fpJobDone = nil -- elle suit sa moissonneuse ailleurs
        return nil
    end
    return memo
end

local function clear(v, why)
    if v ~= nil and v.ad ~= nil and v.ad.fpJobDone ~= nil then
        v.ad.fpJobDone = nil
        log("%s: fin de chantier oubliee (%s)", nameOf(v), tostring(why))
    end
end

-- la benne repart comme à la fin du chantier : vider (chargée) puis parking, ou parking (vide)
local function leaveAgain(mode, memo, why)
    local v = mode.vehicle
    v.ad.harvestJobDone = nil -- onHarvesterJobDone repart de zéro
    log("%s: %s, mais le chantier de %s est fini : elle ne reste pas, elle repart (vider si chargee, puis parking)", nameOf(v), tostring(why), nameOf(memo.harvester))
    mode:onHarvesterJobDone(memo.harvester)
    return v.ad.harvestJobDone == true
end

if CombineUnloaderMode ~= nil and CombineUnloaderMode.onHarvesterJobDone ~= nil then
    local baseJobDone = CombineUnloaderMode.onHarvesterJobDone
    function CombineUnloaderMode:onHarvesterJobDone(harvester)
        baseJobDone(self, harvester)
        local v = self.vehicle
        if v.ad.harvestJobDone and v.ad.fpJobDone == nil then
            v.ad.fpJobDone = { harvester = harvester, marker = v.ad.stateModule:getFirstMarker(), since = g_time }
        end
    end

    -- jamais d'attente d'appel tant que la fin de chantier vaut
    local baseWait = CombineUnloaderMode.setToWaitForCall
    if baseWait ~= nil then function CombineUnloaderMode:setToWaitForCall(keepCombine)
        local memo = ADJobDoneGuard.active(self)
        if memo ~= nil and leaveAgain(self, memo, "attente d'appel demandee") then
            return
        end
        return baseWait(self, keepCombine)
    end end

    -- relancée (pas par le joueur) : la fin de chantier reprend tout de suite
    local baseStart = CombineUnloaderMode.start
    if baseStart ~= nil then function CombineUnloaderMode:start(user, ...)
        if user == AutoDrive.USER_PLAYER then
            clear(self.vehicle, "relancee par le joueur")
        end
        local r = baseStart(self, user, ...)
        local memo = ADJobDoneGuard.active(self)
        if memo ~= nil and not self.vehicle.ad.harvestJobDone and self.vehicle.ad.stateModule:isActive() then
            leaveAgain(self, memo, "relancee")
        end
        return r
    end end

    local baseAssign = CombineUnloaderMode.assignToHarvester
    if baseAssign ~= nil then function CombineUnloaderMode:assignToHarvester(harvester)
        if self.state == self.STATE_WAIT_TO_BE_CALLED then
            clear(self.vehicle, "appelee par " .. nameOf(harvester))
        end
        return baseAssign(self, harvester)
    end end

    local baseStep = CombineUnloaderMode.getParkAfterJobStepTask
    if baseStep ~= nil then function CombineUnloaderMode:getParkAfterJobStepTask()
        if self.state == self.STATE_PARK then
            self.vehicle.ad.fpJobDone = nil -- arrivée au parking
        end
        return baseStep(self)
    end end
end

-- trace : une benne en fin de chantier relancée (c'est là que la fin de chantier était oubliée)
if ADTaskModule ~= nil and ADTaskModule.stopAndRestartAD ~= nil then
    local baseRestart = ADTaskModule.stopAndRestartAD
    function ADTaskModule:stopAndRestartAD(...)
        local v = self.vehicle
        if v ~= nil and v.ad ~= nil and v.ad.fpJobDone ~= nil then
            local mode = v.ad.modes ~= nil and AutoDrive.MODE_UNLOAD ~= nil and v.ad.modes[AutoDrive.MODE_UNLOAD] or nil
            log("%s: relance pendant la fin de chantier (etat %s, tache %s, fin de chantier %s)", nameOf(v),
                mode ~= nil and mode.getStateName ~= nil and tostring(mode:getStateName()) or "?",
                tostring(self.getActiveTask ~= nil and self:getActiveTask() ~= nil and (self:getActiveTask().taskType or "?") or "aucune"),
                tostring(v.ad.harvestJobDone))
        end
        return baseRestart(self, ...)
    end
end
