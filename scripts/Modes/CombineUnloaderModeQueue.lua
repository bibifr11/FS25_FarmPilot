-- ============================================================================================================
-- FarmPilot : CombineUnloaderModeQueue.lua
-- Complément de CombineUnloaderMode : la benne dans la file d'attente de la machine. Commun ensileuse et
-- moissonneuse.
--
-- Historique :
-- - 25/10 14:00 : tout le suivi de la 2e benne (son appel) est écrit dans le log ([AD-Suivi]) ;
-- - 25/10 15:25 : le 7R 350 est parti vider à moitié plein 12 s après le chargement de la partie, sans que
--   personne n'appuie sur rien : chaque départ pour vider est écrit dans le log (niveau, seuil AutoDrive, qui l'a
--   demandé), et sous le seuil de remplissage seul le bouton Continuer du joueur envoie vider.
--
-- Règles :
-- - la benne qui part vider perd sa place dans la file (elle revient en fin de file) et libère l'ensileuse dont
--   elle était la benne attitrée (HarvestManagerQueue.lua) ;
-- - départ pour vider demandé sans le bouton Continuer, remorque sous le seuil : refusé, écrit dans le log ;
-- - appel en 2e, appel ignoré (au plus toutes les 30 s), promotion de la 2e benne : écrits dans le log.
--
-- Branché par des lignes dans CombineUnloaderMode.lua : reset, continue, getNextTask, setToWaitForCall,
-- getTaskAfterUnload (leaveUnloaderQueue, logLeaveToUnload), continue (refuseLeaveBelowThreshold),
-- promoteFollowingUnloader et driveToUnloader (logs [AD-Suivi]).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- La benne quitte la file (elle part vider, ou AutoDrive est arrêté)
-- ------------------------------------------------------------------------------------------------------------
-- reason : pour le log de la benne attitrée libérée (nil = « part vider »)
function CombineUnloaderMode:leaveUnloaderQueue(reason)
    self.vehicle.ad.unloaderQueueTime = nil
    ADHarvestManager.releaseStickyUnloader(self.vehicle, reason)
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ pour vider : log et seuil de remplissage
-- ------------------------------------------------------------------------------------------------------------
-- 25/10 15:25: 7R 350 left to unload half full 12 s after the savegame was loaded, nothing in the log said why:
-- every departure to unload is logged with the fill level, the AutoDrive threshold and who asked for it
function CombineUnloaderMode:logLeaveToUnload(reason)
    local trailers = self.trailers
    if trailers == nil or #trailers == 0 then
        trailers = AutoDrive.getAllUnits(self.vehicle)
    end
    local level, capacity, filled = 0, 0, false
    if trailers ~= nil and #trailers > 0 then
        level, capacity, filled = AutoDrive.getAllFillLevels(trailers)
    end
    local percent = capacity ~= nil and capacity > 0 and level / capacity * 100 or -1
    local threshold = (AutoDrive.getSetting("unloadFillLevel", self.vehicle) or 0) * 100
    print(string.format("[AD-Vider] %s: part vider (%s), remplie a %.0f %% (seuil AutoDrive %.0f %%, atteint %s), etat %s", tostring(self.vehicle:getName()), tostring(reason), percent, threshold, tostring(filled), tostring(self:getStateName())))
    -- la pile d'appels n'est écrite qu'avec un canal debug, comme la ligne au-dessus (filtre du log) : sans elle,
    -- une pile seule dans log.txt ressemblait à une erreur
    if (AutoDrive.currentDebugChannelMask or 0) > 0 and (not filled or string.find(tostring(reason), "continue", 1, true) ~= nil) then
        printCallstack()
    end
end

-- (accroche de CombineUnloaderMode:continue) true : départ refusé, continue s'arrête là
function CombineUnloaderMode:refuseLeaveBelowThreshold()
    -- 25/10 15:25 (7R 350 left to unload half full, nobody pressed anything): below the unload fill level
    -- setting, only the player's "continue" sends an unloader to unload
    if self.state ~= self.STATE_DRIVE_TO_UNLOAD and self.vehicle.ad.continueByPlayer ~= true then
        local trailers = (self.trailers ~= nil and #self.trailers > 0) and self.trailers or AutoDrive.getAllUnits(self.vehicle)
        local filled = false
        if trailers ~= nil and #trailers > 0 then
            _, _, filled = AutoDrive.getAllFillLevels(trailers)
        end
        if not filled then
            print(string.format("[AD-Vider] %s: demande de depart pour vider sans le bouton Continuer, seuil de remplissage pas atteint : ignoree (etat %s)", tostring(self.vehicle:getName()), tostring(self:getStateName())))
            printCallstack()
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Appel en 2e et promotion : logs [AD-Suivi]
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:logPromotion(combine)
    local task = self.vehicle.ad.taskModule ~= nil and self.vehicle.ad.taskModule.activeTask or nil
    print(string.format("[AD-Suivi] %s: la 1re s'en va, je suis promue : %s est a moi (a %.0f m), tache en cours %s", tostring(self.vehicle:getName()),
        tostring(combine ~= nil and combine.getName ~= nil and combine:getName() or "?"), combine ~= nil and AutoDrive.getDistanceBetween(self.vehicle, combine) or -1,
        tostring(task ~= nil and (task.taskType or (task.getI18nInfo ~= nil and task:getI18nInfo()) or "?") or "aucune")))
end

function CombineUnloaderMode:logCalledSecond(unloader)
    -- 25/10 14:00 (the call of the 2nd unloader): the whole follow is logged ([AD-Suivi])
    print(string.format("[AD-Suivi] %s: appelee en 2e, je vais me mettre %d m derriere %s (a %.0f m) et la suivre", tostring(self.vehicle:getName()), DriveToVehicleTask.TARGET_DISTANCE, tostring(unloader:getName()), AutoDrive.getDistanceBetween(self.vehicle, unloader)))
end

-- appel en 2e reçu hors attente d'appel : ignoré, écrit au plus toutes les 30 s
function CombineUnloaderMode:logSecondCallIgnored(unloader)
    if self.callIgnoredLogged == nil or (g_time or 0) - self.callIgnoredLogged > 30000 then
        self.callIgnoredLogged = g_time or 0
        print(string.format("[AD-Suivi] %s: appel en 2e derriere %s ignore (etat %s, pas en attente d'appel)", tostring(self.vehicle:getName()), tostring(unloader:getName()), tostring(self:getStateName())))
    end
end
