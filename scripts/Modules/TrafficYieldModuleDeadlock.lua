-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleDeadlock.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : deux véhicules arrêtés nez à nez.
--
-- Règle :
-- - bloqués depuis <trafficYieldDelay> s, à moins de MAX_DETECTION_DISTANCE m, face à face, sur le réseau, et avec un
--   tronçon à double sens commun à leurs trajets (28/10) ; pas pendant un croisement engagé (26/10) ;
-- - d'abord, l'un des deux prend une autre voie s'il y en a une (27/10, tryDetour) ;
-- - sinon plan classique : recule celui qui manœuvre le moins (28/10), même si son recul est plus long ; 1 échec : rôles
--   inversés ; 2 échecs : la paire est laissée tranquille GIVE_UP_TIME ms ; attelage articulé : ne recule jamais (A1) ;
--   un véhicule suivi de près ne recule pas ;
-- - pendant un plan, arrêté par un 3e véhicule : le plan lui est passé (handOverTo), le véhicule garé attend seul que
--   celui-là et sa file soient passés (S7, 28/10).
--
-- Branché par : TrafficYieldModule:handle (checkForHeadOnDeadlock, updateDetachedWait, checkBlockedWhilePassing),
-- updateAnticipation et restartWithRolesSwapped (startPlan).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Détection : arrêtés nez à nez
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:checkForHeadOnDeadlock(dt, obstacleDetected)
    local isStopped = ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1
    local onRoad = self.vehicle.ad.drivePathModule:isOnRoadNetwork()
    local delay = (AutoDrive.getSetting("trafficYieldDelay") or 5) * 1000

    local blockedLongEnough = self.blockedTimer:timer(obstacleDetected and isStopped and onRoad and g_time >= self.cooldownUntil, delay, dt)
    if not blockedLongEnough then
        return
    end
    if (g_updateLoopIndex % AutoDrive.PERF_FRAMES) ~= 0 then
        return
    end

    if ADTrafficYieldModule.intersectionHasPriority(self.vehicle) then
        return -- engaged on a red section: the crossing decides (wait or go), 26/10
    end
    local other = self:findHeadOnPartner()
    if other ~= nil and not ADTrafficYieldModule.intersectionHasPriority(other) then
        -- 27/10: nose to nose, before anybody reverses, either of us takes another lane when there is one
        local otherModule = other.ad.trafficYieldModule
        if self:tryDetour(other) or (otherModule ~= nil and otherModule.tryDetour ~= nil and otherModule:tryDetour(self.vehicle)) then
            self.blockedTimer:timer(false)
            return
        end
        ADTrafficYieldModule.startPlan(self.vehicle, other)
    end
end

function ADTrafficYieldModule:findHeadOnPartner(excluded)
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(self.vehicle)
    local myLength = ADTrafficYieldModule.getTotalLength(self.vehicle)

    local bestOther = nil
    local bestDistance = math.huge

    for _, other in pairs(AutoDrive.getAllVehicles()) do
        if other ~= self.vehicle and other ~= excluded and other.ad ~= self.vehicle.ad and ADTrafficYieldModule.isAdVehicleUsable(other)
            and not AutoDrive:checkIsConnected(self.vehicle, other) then
            local ox, _, oz = ADTrafficYieldModule.getPosition(other)
            local distance = MathUtil.vector2Length(ox - x, oz - z)
            local maxDistance = ADTrafficYieldModule.MAX_DETECTION_DISTANCE + myLength / 2

            if distance < maxDistance and distance < bestDistance then
                local odirX, odirZ = ADTrafficYieldModule.getDirection(other)
                local headingDot = dirX * odirX + dirZ * odirZ
                -- other in front of me and me in front of other
                local _, _, otherLocalZ = AutoDrive.worldToLocal(self.vehicle, ox, 0, oz)
                local myX, myY, myZ = ADTrafficYieldModule.getPosition(self.vehicle)
                local _, _, meLocalZInOther = AutoDrive.worldToLocal(other, myX, myY, myZ)

                local otherModule = other.ad.trafficYieldModule
                local otherBlocked = other.ad.specialDrivingModule ~= nil and other.ad.specialDrivingModule:isStoppingVehicle()
                local otherStopped = ADTrafficYieldModule.getSpeedKmh(other) < 1
                local otherOnRoad = other.ad.drivePathModule:isOnRoadNetwork()


                if headingDot < -0.5 and otherLocalZ > 0 and meLocalZInOther > 0 and otherBlocked and otherStopped and otherOnRoad and not otherModule:isBusy() then
                    -- 28/10 (8510 and Patriot face to face on the two one-way lanes of a road, a crossing manoeuvre
                    -- started): only two vehicles whose routes share a two-way stretch (one lane driven both ways) are face to face
                    if ADTrafficYieldModule.shareTwoWayStretch(self.vehicle, other) then
                        bestOther = other
                        bestDistance = distance
                    elseif self.notTwoWayLogged ~= other or g_time - (self.notTwoWayTime or 0) > 30000 then
                        self.notTwoWayLogged, self.notTwoWayTime = other, g_time
                        self:log("face to face with %s but no shared two-way stretch (one-way lanes): no crossing manoeuvre", ADTrafficYieldModule.getName(other))
                        print(string.format("[AD-Croise] %s: face a %s mais pas de troncon a double sens commun (voies a sens unique) : pas de procedure de croisement",
                            ADTrafficYieldModule.getName(self.vehicle), ADTrafficYieldModule.getName(other)))
                    end
                end
            end
        end
    end
    return bestOther
end

-- ------------------------------------------------------------------------------------------------------------
-- Plan classique : l'un recule, l'autre se gare
-- ------------------------------------------------------------------------------------------------------------
-- 28/10: the one that will manoeuvre the least reverses, even if its reverse is longer (turns of its
-- way back out of the two-way track, double with a trailer; the length only breaks a tie). Load and weight no longer count
function ADTrafficYieldModule.pickReverser(vehicleA, vehicleB)
    local manA = ADTrafficYieldModule.getReverseManoeuvre(vehicleA)
    local manB = ADTrafficYieldModule.getReverseManoeuvre(vehicleB)
    local reverser, parker
    if math.abs(manA.score - manB.score) > ADTrafficYieldModule.MANOEUVRE_TIE then
        if manA.score < manB.score then
            reverser, parker = vehicleA, vehicleB
        else
            reverser, parker = vehicleB, vehicleA
        end
    elseif math.abs(manA.length - manB.length) > 5 then
        if manA.length < manB.length then
            reverser, parker = vehicleA, vehicleB
        else
            reverser, parker = vehicleB, vehicleA
        end
    elseif (vehicleA.id or 0) < (vehicleB.id or 0) then
        reverser, parker = vehicleA, vehicleB
    else
        reverser, parker = vehicleB, vehicleA
    end
    return reverser, parker, manA, manB
end

function ADTrafficYieldModule.startPlan(vehicleA, vehicleB)
    local reverser, parker, manA, manB = ADTrafficYieldModule.pickReverser(vehicleA, vehicleB)
    do
        local manR = reverser == vehicleA and manA or manB
        local manP = reverser == vehicleA and manB or manA
        local tooLong = string.format(", ne sort pas du chemin en %d m de recul", ADTrafficYieldModule.SECTION_CLEAR_MAX)
        print(string.format("[AD-Croise] face a face %s / %s : %s recule (virages %.0f deg sur %.0f m%s, contre %.0f deg sur %.0f m%s pour %s)",
            ADTrafficYieldModule.getName(vehicleA), ADTrafficYieldModule.getName(vehicleB), ADTrafficYieldModule.getName(reverser),
            manR.angle, manR.length, (manR.trailer and " avec remorque, comptes double" or "") .. (manR.tooLong and tooLong or ""), manP.angle, manP.length,
            (manP.trailer and " avec remorque, comptes double" or "") .. (manP.blocked and ", bloque derriere" or "") .. (manP.tooLong and tooLong or ""),
            ADTrafficYieldModule.getName(parker)))
    end

    -- previous failed attempts of this pair: 1 failure -> swap the roles (the other one reverses along
    -- its own route, where there may be a free roadside or a junction), 2 failures -> give up for a while
    local key = ADTrafficYieldModule.getPairKey(vehicleA, vehicleB)
    local history = ADTrafficYieldModule.pairHistory[key]
    if history ~= nil and g_time - history.time > ADTrafficYieldModule.HISTORY_TIMEOUT then
        ADTrafficYieldModule.pairHistory[key] = nil
        history = nil
    end
    if history ~= nil then
        if history.failures >= 2 then
            for _, vehicle in pairs({vehicleA, vehicleB}) do
                vehicle.ad.trafficYieldModule.cooldownUntil = g_time + ADTrafficYieldModule.GIVE_UP_TIME
                vehicle.ad.trafficYieldModule.blockedTimer:timer(false)
            end
            AutoDriveMessageEvent.sendMessageOrNotification(vehicleA, ADMessagesManager.messageTypes.ERROR, "$l10n_AD_Driver_of; %s $l10n_AD_trafficYield_giveUp;", 10000, ADTrafficYieldModule.getName(vehicleA))
            return
        end
        if history.failures == 1 and history.lastReverser == reverser then
            reverser, parker = parker, reverser
        end
    end

    -- A1 (27/10, 28/10): an articulated train never reverses, the other one does
    local a1 = false
    if ADTrafficYieldModule.cannotReverse(reverser) and not ADTrafficYieldModule.cannotReverse(parker) then
        local what = ADTrafficYieldModule.describeArticulated(reverser)
        reverser.ad.trafficYieldModule:log("articulated train (%s): I never reverse, %s reverses", tostring(what), ADTrafficYieldModule.getName(parker))
        print(string.format("[AD-Croise] %s: remorque articulee, %s, je ne recule pas : %s recule", ADTrafficYieldModule.getName(reverser), tostring(what),
            ADTrafficYieldModule.getName(parker)))
        reverser, parker = parker, reverser
        a1 = true
    elseif ADTrafficYieldModule.cannotReverse(parker) then
        a1 = true
    end

    -- a vehicle with another one right behind it cannot reverse: it parks, the other one reverses (never onto a header trailer)
    local maxReverse = ADTrafficYieldModule.getMaxReverse() + 10
    if not a1 and ADTrafficYieldModule.hasFollowerBehind(reverser, maxReverse, parker) and not ADTrafficYieldModule.hasFollowerBehind(parker, maxReverse, reverser) then
        reverser.ad.trafficYieldModule:log("a vehicle follows me, %s reverses instead", ADTrafficYieldModule.getName(parker))
        reverser, parker = parker, reverser
    end

    local plan = {
        pairKey = key,
        firstReverser = reverser, -- roles may be swapped during the plan, keep the initial one for the history
        reverser = reverser,
        parker = parker,
        startTime = g_time,
        parkSpot = nil,      -- set by parker when a free roadside spot is found
        reverserMayStop = false,
        reverserAtLimit = false,
        parked = false,
        passed = false,
        mode = "park",       -- "park": parker parks on the roadside / "branch": reverser hides in a side branch
        hidden = false
    }

    local rModule = reverser.ad.trafficYieldModule
    local pModule = parker.ad.trafficYieldModule
    rModule:log("STANDARD plan: I reverse, %s parks", ADTrafficYieldModule.getName(parker))

    -- measure both trains in their current state so the roadside spot fits them exactly
    ADTrafficYieldModule.measureTrain(reverser)
    ADTrafficYieldModule.measureTrain(parker)

    rModule:reset()
    pModule:reset()
    rModule.plan, rModule.partner = plan, parker
    pModule.plan, pModule.partner = plan, reverser


    rModule:setState(ADTrafficYieldModule.STATE_REVERSER_RETREAT)
    pModule:setState(ADTrafficYieldModule.STATE_PARKER_SEARCH)

    AutoDriveMessageEvent.sendMessageOrNotification(reverser, ADMessagesManager.messageTypes.INFO, "$l10n_AD_Driver_of; %s $l10n_AD_trafficYield_giveWay;", 5000, ADTrafficYieldModule.getName(reverser))
end

-- ------------------------------------------------------------------------------------------------------------
-- Un autre véhicule pendant le plan
-- ------------------------------------------------------------------------------------------------------------
-- a vehicle passing inside a plan is stopped by its sensor face to face with another AD vehicle that is
-- not part of the plan (e.g. started between both vehicles, already too close to be seen on the route):
-- hand over to it with a standard plan instead of waiting for the pass timeout
function ADTrafficYieldModule:checkBlockedWhilePassing(dt, obstacleDetected)
    local passing = self.state == ADTrafficYieldModule.STATE_REVERSER_PASS or self.state == ADTrafficYieldModule.STATE_PARKER_PASS
    local isStopped = ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1
    local delay = (AutoDrive.getSetting("trafficYieldDelay") or 5) * 1000
    if not self.blockedTimer:timer(passing and obstacleDetected and isStopped, delay, dt) then
        return false
    end
    if (g_updateLoopIndex % AutoDrive.PERF_FRAMES) ~= 0 then
        return false
    end
    local other = self:findHeadOnPartner(self.partner)
    if other == nil then
        return false
    end
    self:log("blocked face to face by %s while passing", ADTrafficYieldModule.getName(other))
    self:handOverTo(other, true)
    return true
end

-- leaves the current plan to start a new one with another oncoming vehicle; the partner of the current
-- plan, if parked or hidden, keeps waiting on its own until this vehicle has passed it
function ADTrafficYieldModule:handOverTo(other, faceToFace)
    local partner = self.partner
    if partner ~= nil and partner.ad ~= nil and partner.ad.trafficYieldModule ~= nil then
        local partnerModule = partner.ad.trafficYieldModule
        if partnerModule.plan == self.plan then
            local waiting = partnerModule.state == ADTrafficYieldModule.STATE_PARKER_WAIT or partnerModule.state == ADTrafficYieldModule.STATE_PARKER_MOVE
                or partnerModule.state == ADTrafficYieldModule.STATE_REVERSER_HIDE or partnerModule.state == ADTrafficYieldModule.STATE_REVERSER_BRANCH
            local reachedRouteIndex = partnerModule.reachedRouteIndex
            partnerModule:reset()
            if waiting then
                local partnerSpot = self.plan ~= nil and self.plan.parkSpot or nil
                partnerModule.waitDirX = partnerSpot and partnerSpot.dirX
                partnerModule.waitDirZ = partnerSpot and partnerSpot.dirZ
                partnerModule.waitFor = self.vehicle
                partnerModule.waitSpot = partnerSpot
                partnerModule.waitRouteIndex = reachedRouteIndex
                partnerModule:setState(ADTrafficYieldModule.STATE_WAIT_DETACHED)
            else
                partnerModule.cooldownUntil = g_time + ADTrafficYieldModule.COOLDOWN_SUCCESS
                if partner.ad.specialDrivingModule ~= nil then
                    partner.ad.specialDrivingModule:releaseVehicle()
                end
                ADTrafficYieldModule.resyncWayPoints(partner, reachedRouteIndex)
            end
        end
    end
    self:log("hand over to %s", ADTrafficYieldModule.getName(other))
    local myRouteIndex = self.reachedRouteIndex
    self:reset()
    ADTrafficYieldModule.resyncWayPoints(self.vehicle, myRouteIndex)
    if faceToFace then
        -- already nose to nose: no room left to pull over in advance
        ADTrafficYieldModule.startPlan(self.vehicle, other)
    else
        ADTrafficYieldModule.startEarlyPlan(self.vehicle, other)
    end
end

function ADTrafficYieldModule:updateDetachedWait(dt)
    if not self:finishAlignment(dt, self.waitSpot, self.waitFor) then
        self:holdVehicle(dt)
    end
    local done = self:hasPassedMe(self.waitFor, self.waitDirX, self.waitDirZ)
    if done then
        -- 28/10 (S7): then the next one of its queue, until the last has passed
        local nextInQueue = ADTrafficYieldModule.findFollowerBehind(self.waitFor, ADTrafficYieldModule.QUEUE_GAP, self.vehicle)
        if nextInQueue ~= nil and nextInQueue ~= self.waitFor and not self:hasPassedMe(nextInQueue, self.waitDirX, self.waitDirZ) then
            print(string.format("[AD-Croise] %s: %s est passe, je reste gare pour la file : %s", ADTrafficYieldModule.getName(self.vehicle),
                ADTrafficYieldModule.getName(self.waitFor), ADTrafficYieldModule.getName(nextInQueue)))
            self.waitFor = nextInQueue
            done = false
        end
    end
    if done or self.stateTimer:timer(true, 180000, dt) then
        local routeIndex = self.waitRouteIndex
        self:reset()
        self.waitFor = nil
        self.waitSpot = nil
        self.waitRouteIndex = nil
        self.cooldownUntil = g_time + ADTrafficYieldModule.COOLDOWN_SUCCESS
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        ADTrafficYieldModule.resyncWayPoints(self.vehicle, routeIndex)
        return false
    end
    return true
end
