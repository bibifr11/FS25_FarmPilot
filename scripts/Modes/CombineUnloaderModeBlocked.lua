-- ============================================================================================================
-- FarmPilot : CombineUnloaderModeBlocked.lua
-- Complément de CombineUnloaderMode : la benne coincée ou bloquée. Commun ensileuse et moissonneuse (la
-- poursuite bloquée a une suite propre à l'ensileuse, marquée).
--
-- Historique :
-- - 25/10 14:10 : la sécurité « bloqué » d'AutoDrive (8 s sans se rapprocher du point suivant) remettait la benne
--   à zéro (place dans la file et ensileuse perdues, benne suivante appelée de loin) ;
-- - après 2 reculs pour la même machine, la benne la laisse à une autre benne pendant HAND_OVER_TIME ;
-- - poursuite abandonnée sur une ligne droite bloquée : trajet calculé vers la machine ; ensileuse proche : pas de
--   grille (elle bouclait dans les arbres et la culture), suivi du bord de la culture après CLOSE_BLOCKED_TRIES.
--
-- Règles :
-- - coincée au champ ou occupée avec une machine : recul (ReverseFromBadLocationTask) et nouveau calcul, sans
--   remise à zéro ; la remise à zéro d'AutoDrive seulement après STUCK_MAX_RECOVERIES dégagements de suite ;
-- - dégagement demandé par CombineUnloaderMode:monitorTasks plus de MAX_REVERSE_COUNT fois pour la même machine :
--   la benne se désinscrit et attend un appel, cette machine ne la rappelle pas pendant HAND_OVER_TIME
--   (HarvestManager.lua, getClosestIdleUnloader) ;
-- - poursuite bloquée : CatchCombinePipeTask, et après CLOSE_BLOCKED_TRIES blocages au même endroit, trajet
--   calculé autorisé (moissonneuse) ou suivi du bord de la culture seulement (ensileuse).
--
-- Branché par : DrivePathModule.lua (onDriveStuck) ; dans CombineUnloaderMode.lua, une ligne dans monitorTasks
-- (passage de main) et une dans getNextTask (poursuite bloquée).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- 25/10 14:10: AutoDrive's "stuck" safety (DrivePathModule.handleBeingStuck, 8 s without getting closer to the
-- next waypoint) reset the unloader: stop + restart, queue place and harvester lost, the next unloader called from far
-- away (MF 7S.210 14:08, 6205 TTV 13:55 and 14:02). An unloader on the field or busy with a harvester keeps everything:
-- it backs out as for a blocked vehicle and plans again, the reset only after STUCK_MAX_RECOVERIES in a row
CombineUnloaderMode.STUCK_MAX_RECOVERIES = 3
CombineUnloaderMode.STUCK_RECOVERY_RESET = 180000 -- ms without a stuck: the count starts again

-- after this many reversals the unloader gives the harvester up to another unloader, for HAND_OVER_TIME ms
CombineUnloaderMode.MAX_REVERSE_COUNT = 2
CombineUnloaderMode.HAND_OVER_TIME = 120000

-- ------------------------------------------------------------------------------------------------------------
-- Coincée : dégagement en marche arrière sans remise à zéro (appelé par DrivePathModule)
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:onDriveStuck(info)
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local busy = self.combine ~= nil or self.targetUnloader ~= nil or self.state == self.STATE_WAIT_TO_BE_CALLED
    if not busy and not AutoDrive.checkIsOnField(x, y, z) then
        return false
    end
    if self.lastStuckTime ~= nil and (g_time or 0) - self.lastStuckTime > CombineUnloaderMode.STUCK_RECOVERY_RESET then
        self.stuckRecoveries = 0
    end
    self.lastStuckTime = g_time or 0
    self.stuckRecoveries = (self.stuckRecoveries or 0) + 1
    if self.stuckRecoveries > CombineUnloaderMode.STUCK_MAX_RECOVERIES then
        print(string.format("[AD-Coince] %s: %s : %d degagements de suite sans succes, je laisse AutoDrive remettre a zero", tostring(self.vehicle:getName()), tostring(info), self.stuckRecoveries - 1))
        self.stuckRecoveries = 0
        return false
    end
    print(string.format("[AD-Coince] %s: %s : je me degage en marche arriere et je recalcule (%d/%d), sans remise a zero (etat %s)", tostring(self.vehicle:getName()), tostring(info), self.stuckRecoveries, CombineUnloaderMode.STUCK_MAX_RECOVERIES, tostring(self:getStateName())))
    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    self.vehicle.ad.taskModule:abortAllTasks()
    self.targetUnloader = nil
    self.activeTask = ReverseFromBadLocationTask:new(self.vehicle)
    self.state = self.STATE_REVERSE_FROM_BAD_LOCATION
    self.vehicle.ad.taskModule:addTask(self.activeTask)
    self.failedPathFinder = 0
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Deux reculs pour la même machine : la benne passe la main (accroche dans monitorTasks)
-- ------------------------------------------------------------------------------------------------------------
-- true : la benne a passé la main et attend un appel, monitorTasks s'arrête là
function CombineUnloaderMode:handOverAfterReversals()
    self.reverseCount = (self.reverseCount or 0) + 1
    if self.reverseCount > CombineUnloaderMode.MAX_REVERSE_COUNT and self.combine ~= nil then
        -- already reversed twice for this harvester: stop here and let another unloader take it
        CombineUnloaderMode.debugMsg(self.vehicle, "CombineUnloaderMode:monitorTasks() - reversed %d times - hand over to another unloader", self.reverseCount - 1)
        self.vehicle.ad.skipHarvester = self.combine
        self.vehicle.ad.skipHarvesterUntil = g_time + CombineUnloaderMode.HAND_OVER_TIME
        ADHarvestManager:unregisterAsUnloader(self.vehicle)
        self.reverseCount = 0
        self.failedPathFinder = 0
        self.followingUnloader = nil
        self:setToWaitForCall()
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Poursuite bloquée sur la ligne droite : trajet vers la machine (accroche dans getNextTask)
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:getBlockedChaseTask()
    -- chase given up on a blocked straight line: plan a route to the combine
    local nextTask = CatchCombinePipeTask:new(self.vehicle, self.combine)
    self.state = self.STATE_DRIVE_TO_COMBINE
    -- forage harvester close by: the chase drives; after CLOSE_BLOCKED_TRIES blocked chases at the same
    -- place (it cannot reach it in a straight line), a planned route is allowed once
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    if self.closeBlocked ~= nil and MathUtil.vector2Length(x - self.closeBlocked.x, z - self.closeBlocked.z) < 5 then
        self.closeBlocked.count = self.closeBlocked.count + 1
    else
        self.closeBlocked = {x = x, z = z, count = 1}
    end
    -- forage harvester: no grid route near it any more (it looped into trees and crop), the crop edge
    -- following of the catch task handles corners; the planned route is still allowed for a combine harvester
    if self.closeBlocked.count >= CatchCombinePipeTask.CLOSE_BLOCKED_TRIES and self.combine ~= nil and self.combine.ad ~= nil and self.combine.ad.isChopper then
        -- forage harvester: the straight line is blocked by the crop (a corner): follow the crop edge around it,
        -- never a grid route this close
        print(string.format("[AD-Fin] %s: poursuite bloquee %d fois au meme endroit, suivi du bord autorise (pas de grille)", tostring(self.vehicle:getName()), self.closeBlocked.count))
        nextTask.closeRangePlanning = true
        nextTask.edgeOnly = true
        self.closeBlocked = nil
    elseif self.closeBlocked.count >= CatchCombinePipeTask.CLOSE_BLOCKED_TRIES then
        print(string.format("[AD-Fin] %s: poursuite bloquee %d fois au meme endroit, trajet calcule autorise", tostring(self.vehicle:getName()), self.closeBlocked.count))
        nextTask.closeRangePlanning = true
        self.closeBlocked = nil
    end
    return nextTask
end
