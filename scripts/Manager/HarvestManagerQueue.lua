-- ============================================================================================================
-- FarmPilot : HarvestManagerQueue.lua
-- Complément de ADHarvestManager (HarvestManager.lua d'origine AutoDrive) : la file d'attente des bennes. Commun
-- ensileuse et moissonneuse ; la benne attitrée et l'ordre dans la ligne ne concernent que l'ENSILEUSE (benne qui
-- roule à côté).
--
-- Règles :
-- - ordre d'arrivée, pour les deux types de machine : la première benne en attente pour cette machine est appelée
--   la première (puis la plus proche). Un appel raté garde la place ; elle n'est perdue qu'en partant vider
--   (CombineUnloaderModeQueue.lua). L'heure d'arrivée est notée ici ; la comparaison est restée dans la boucle de
--   getClosestIdleUnloader (mêlée au code d'origine) ;
-- - ensileuse : sa benne attitrée reste la sienne jusqu'à ce qu'elle soit pleine (dans une bande étroite les
--   remorques ne peuvent pas se croiser, celle qui est arrivée la première doit être appelée la première) ;
-- - (24/10) bennes inscrites à moins de QUEUE_SAME_TIME d'écart (chargement de la
--   partie : le 7R appelé alors que le 728 était devant lui dans la ligne) : celle de devant d'abord ;
-- - une benne qui a laissé cette machine après 2 reculs n'est pas rappelée par elle pendant un moment
--   (CombineUnloaderModeBlocked.lua) : ce test est resté dans getClosestIdleUnloader ;
-- - 25/10 16:38 (le 942 parti très loin) : une benne de nouveau en attente d'appel qui garde sa machine
--   (demi-tour abandonné, nouveau trajet) ne la quitte pas, sa suiveuse reste sa suiveuse (pas de promotion) ;
-- - appel de la 2e benne et benne appelée dans la file : écrits dans le log ([AD-Suivi], [AD-File]).
--
-- Branché par des lignes dans HarvestManager.lua : registerAsUnloader, update (log de l'appel en 2e),
-- assignUnloaderToHarvester, getClosestIdleUnloader ; releaseStickyUnloader est appelée par
-- CombineUnloaderModeQueue.lua et CombineUnloaderModeJobDone.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHarvestManager.QUEUE_SAME_TIME = 10000 -- ms: unloaders registered this close together are called by their place in the line
ADHarvestManager.QUEUE_LINE_ANGLE = 30 -- deg at most between the headings of two unloaders in the same line
ADHarvestManager.QUEUE_LINE_SIDE = 6 -- m at most aside from the other one's axis
ADHarvestManager.QUEUE_LINE_AHEAD = 2 -- m ahead at least

-- ------------------------------------------------------------------------------------------------------------
-- Inscription dans la file (accroches dans registerAsUnloader)
-- ------------------------------------------------------------------------------------------------------------
-- true : la benne garde sa machine et sa suiveuse (pas de promotion de la suiveuse)
function ADHarvestManager:keepFollowerOnWaitAgain(vehicle)
    -- 25/10 16:38 (the 942 went far off): an unloader that waits for a call again while keeping its harvester
    -- (U-turn given up, new route: setToWaitForCall(true)) is not leaving it, its follower stays its follower. The
    -- promotion here sent the 942 to the harvester and back behind the 6205 TTV every 2 s (15:38:23-15:38:27)
    local mode = vehicle.ad ~= nil and vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    local keepFollower = mode ~= nil and mode.combine ~= nil and mode:getFollowingUnloader() ~= nil
    if keepFollower then
        print(string.format("[AD-Suivi] %s: de nouveau en attente d'appel mais je garde mon ensileuse, %s reste ma suiveuse (pas de promotion)", tostring(vehicle:getName()), tostring(mode:getFollowingUnloader():getName())))
    end
    return keepFollower
end

function ADHarvestManager:onUnloaderQueued(vehicle)
    -- queue by order of arrival: the first unloader waiting for this harvester is called first.
    -- A failed call keeps the place in the queue, it is only cleared when the unloader leaves to unload
    if vehicle.ad ~= nil and vehicle.ad.unloaderQueueTime == nil then
        vehicle.ad.unloaderQueueTime = g_time
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Benne attitrée de l'ensileuse
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester only: the unloader it worked with last, until that one is full and leaves to unload
-- (accroche dans assignUnloaderToHarvester)
function ADHarvestManager:setStickyUnloader(harvester, closestUnloader)
    if harvester.ad ~= nil and harvester.ad.isChopper then
        -- forage harvester: this unloader stays its own until it is full (chopper only)
        if harvester.ad.stickyUnloader ~= closestUnloader then
            print(string.format("[AD-File] %s: benne attitree : %s", tostring(harvester.getName ~= nil and harvester:getName() or "?"), tostring(closestUnloader:getName())))
        end
        harvester.ad.stickyUnloader = closestUnloader
    end
end

function ADHarvestManager.releaseStickyUnloader(vehicle, reason)
    for _, list in ipairs({ADHarvestManager.harvesters or {}, ADHarvestManager.idleHarvesters or {}}) do
        for _, harvester in pairs(list) do
            if harvester ~= nil and harvester.ad ~= nil and harvester.ad.stickyUnloader == vehicle then
                harvester.ad.stickyUnloader = nil
                print(string.format("[AD-File] %s: %s %s, benne suivante de la file", tostring(harvester.getName ~= nil and harvester:getName() or "?"), tostring(vehicle.getName ~= nil and vehicle:getName() or "?"), reason or "part vider"))
            end
        end
    end
end

-- (accroche au début de getClosestIdleUnloader) la benne attitrée, si elle attend et n'a pas laissé cette
-- ensileuse ; nil sinon
function ADHarvestManager:getStickyIdleUnloader(harvester)
    local chopper = harvester ~= nil and harvester.ad ~= nil and harvester.ad.isChopper == true
    local sticky = chopper and harvester.ad.stickyUnloader or nil
    if sticky ~= nil and table.contains(self.idleUnloaders, sticky) then
        local handedOver = sticky.ad.skipHarvester == harvester and sticky.ad.skipHarvesterUntil ~= nil and g_time < sticky.ad.skipHarvesterUntil
        if not handedOver then
            return sticky
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Ordre dans la ligne (ensileuse ; accroche dans getClosestIdleUnloader)
-- ------------------------------------------------------------------------------------------------------------
-- unloader a stands in front of unloader b in the same line: same heading, on b's axis, ahead of b
function ADHarvestManager.isAheadInLine(a, b)
    if a == nil or b == nil or a.components == nil or b.components == nil then
        return false
    end
    local ax, _, az = getWorldTranslation(a.components[1].node)
    local bx, _, bz = getWorldTranslation(b.components[1].node)
    local ahx, _, ahz = localDirectionToWorld(a.components[1].node, 0, 0, 1)
    local bhx, _, bhz = localDirectionToWorld(b.components[1].node, 0, 0, 1)
    local la, lb = math.sqrt(ahx * ahx + ahz * ahz), math.sqrt(bhx * bhx + bhz * bhz)
    if la < 0.01 or lb < 0.01 then
        return false
    end
    ahx, ahz, bhx, bhz = ahx / la, ahz / la, bhx / lb, bhz / lb
    if ahx * bhx + ahz * bhz < math.cos(math.rad(ADHarvestManager.QUEUE_LINE_ANGLE)) then
        return false
    end
    local dx, dz = ax - bx, az - bz
    local along = dx * bhx + dz * bhz
    local aside = math.abs(dx * bhz - dz * bhx)
    return along >= ADHarvestManager.QUEUE_LINE_AHEAD and aside <= ADHarvestManager.QUEUE_LINE_SIDE
end

function ADHarvestManager:applyQueueLineOrder(harvester, closestUnloader, closestDistance, closestTime, matching)
    local chopper = harvester ~= nil and harvester.ad ~= nil and harvester.ad.isChopper == true
    -- 24/10: unloaders registered within QUEUE_SAME_TIME of each other (game load: the 7R was
    -- called, the 728 stood in front of it in the line) go by their place in the line, the one in front first
    if chopper and closestUnloader ~= nil and matching > 1 then
        local first, firstTime = closestUnloader, closestTime
        local moved = 0
        local changed = true
        while changed and moved < matching do
            changed = false
            for _, unloader in pairs(self.idleUnloaders) do
                local queueTime = unloader.ad.unloaderQueueTime or math.huge
                local handedOver = unloader.ad.skipHarvester == harvester and unloader.ad.skipHarvesterUntil ~= nil and g_time < unloader.ad.skipHarvesterUntil
                if unloader ~= closestUnloader and not handedOver and unloader.ad.stateModule:getFirstMarker() == harvester.ad.stateModule:getFirstMarker()
                    and math.abs(queueTime - closestTime) <= ADHarvestManager.QUEUE_SAME_TIME and ADHarvestManager.isAheadInLine(unloader, closestUnloader) then
                    closestUnloader = unloader
                    closestDistance = AutoDrive.getDistanceBetween(unloader, harvester)
                    closestTime = queueTime
                    moved = moved + 1
                    changed = true
                    break
                end
            end
        end
        if closestUnloader ~= first and closestUnloader ~= self.lastQueueLinePrinted then
            print(string.format("[AD-File] %s: %s devant %s dans la ligne (inscrites a %.0f s d'ecart), %s appelee d'abord", tostring(harvester.getName ~= nil and harvester:getName() or "?"),
                tostring(closestUnloader:getName()), tostring(first:getName()), math.abs(closestTime - firstTime) / 1000, tostring(closestUnloader:getName())))
        end
        self.lastQueueLinePrinted = closestUnloader ~= first and closestUnloader or nil
    end
    return closestUnloader, closestDistance, closestTime
end

-- ------------------------------------------------------------------------------------------------------------
-- Logs de la file et de l'appel en 2e
-- ------------------------------------------------------------------------------------------------------------
-- (accroche à la fin de getClosestIdleUnloader)
function ADHarvestManager:logQueueCall(harvester, closestUnloader, closestDistance, closestTime, matching)
    if closestUnloader ~= nil and matching > 1 and closestUnloader ~= self.lastQueuePrinted then
        self.lastQueuePrinted = closestUnloader
        print(string.format("[AD-File] %s: %d unloaders waiting, first in queue called: %s (waiting %.0f s, %.0f m)", tostring(harvester.getName ~= nil and harvester:getName() or "?"), matching, tostring(closestUnloader:getName()), (g_time - closestTime) / 1000, closestDistance))
    end
end

-- (accroche dans update, appel de la 2e benne)
function ADHarvestManager:logSecondCall(harvester, unloader, fillLevel, maxCapacity, closestUnloader)
    if harvester.ad ~= nil and (harvester.ad.secondCallLogged == nil or g_time - harvester.ad.secondCallLogged > 10000) then
        harvester.ad.secondCallLogged = g_time
        print(string.format("[AD-Suivi] %s: 1re benne %s remplie a %.0f %% (seuil d'appel %.0f %%), 2e benne appelee : %s", tostring(harvester.getName ~= nil and harvester:getName() or "?"), tostring(unloader:getName()), fillLevel / math.max(1, maxCapacity) * 100, AutoDrive.getSetting("preCallLevel", harvester) * 100, tostring(closestUnloader:getName())))
    end
end
