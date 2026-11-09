-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleSingleTrack.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : attendre avant un chemin à double sens (chemin
-- unique) que l'autre en sorte, reculer hors de son entrée, ou faire reculer celui qui est dedans.
--
-- Règle :
-- - celui qui attend reste à sa ligne d'attente jusqu'à ce que l'autre soit sorti du chemin, remorque comprise, et ne
--   vienne plus sur lui (S2, S6) ; son trajet de sortie hors réseau peut passer sur la place : recul de 10 m de plus,
--   SECTION_BACKOFF_MAX m au plus (26/10) ;
-- - le recul suit mon propre trajet derrière moi, jamais une ligne droite dans l'inconnu (26/10) ;
-- - bloqué dans l'entrée (véhicule collé derrière, attelage articulé) : place sûre pour l'autre dans le chemin et détour
--   pour moi sont calculés ensemble, le moins long est pris (25/10, gardé le 28/10 en dernier recours) ; ni l'un ni
--   l'autre : j'attends, celui du chemin ne recule pas sans place sûre (règle 8, 28/10) ;
-- - celui du chemin recule (état SECTION_CLEAR) jusqu'à être hors du trajet de l'autre, SECTION_CLEAR_MAX m au plus.
--
-- Branché par : updateYielderApproach (TrafficYieldModuleApproach.lua), TrafficYieldModule:handle (updateSectionClear),
-- updateReverserWait (startClearAsReverser, TrafficYieldModuleReverser.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Où en est l'autre ?
-- ------------------------------------------------------------------------------------------------------------
-- first node of the head-on section on my route (world position), nil when not found
function ADTrafficYieldModule:findSectionStart()
    local section = self.earlySection
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if section == nil or section[1] == nil or wayPoints == nil or currentIndex == nil then
        return nil
    end
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp ~= nil and wp.id == section[1] then
            return {x = wp.x, z = wp.z, id = wp.id}
        end
    end
    return nil
end

-- I already drive on the way of the partner (the two waypoints behind me are on its route): I am inside the
-- single track, not in its mouth, a short reverse would not get me out of it
function ADTrafficYieldModule:isInsideSection()
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil or self.partner == nil then
        return false
    end
    local _, otherDist = ADTrafficYieldModule.collectRouteAhead(self.partner, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    local behind1, behind2 = wayPoints[currentIndex - 1], wayPoints[currentIndex - 2]
    return behind1 ~= nil and behind2 ~= nil and behind1.id ~= nil and behind2.id ~= nil and otherDist[behind1.id] ~= nil and otherDist[behind2.id] ~= nil
end

-- the partner (the vehicle coming out of the single track) is clear of its entrance, trailer included
function ADTrafficYieldModule:isPartnerClearOfSection()
    local start = self.plan.sectionStart
    if start == nil or self.partner == nil then
        return true
    end
    -- S6 (28/10: "partner out" while the 6205 TTV was still 100 m up the farm track): out only once
    -- the partner has passed the entrance point on its own route
    if start.id ~= nil and self.partner.ad ~= nil and self.partner.ad.drivePathModule ~= nil then
        local wps, idx = self.partner.ad.drivePathModule:getWayPoints()
        if wps ~= nil and idx ~= nil then
            local qx, _, qz = ADTrafficYieldModule.getPosition(self.partner)
            local distance = 0
            for i = math.max(1, idx), #wps do
                local wp = wps[i]
                if wp == nil then
                    break
                end
                distance = distance + MathUtil.vector2Length(wp.x - qx, wp.z - qz)
                qx, qz = wp.x, wp.z
                if distance > ADTrafficYieldModule.S6_LOOK_AHEAD then
                    break
                end
                if wp.id == start.id then
                    return false
                end
            end
        end
    end
    local px, _, pz = ADTrafficYieldModule.getPosition(self.partner)
    local _, partnerRear = ADTrafficYieldModule.getTrainExtents(self.partner)
    -- past the entrance in its own direction of travel (still inside the track: the entrance is ahead of it)
    local dx, dz = ADTrafficYieldModule.getDirection(self.partner)
    return (px - start.x) * dx + (pz - start.z) * dz > partnerRear + 8
end

-- the part of the remaining route of the partner that is off the network (pathfinder lead-in: exit of a field, detour):
-- those points have no id, the route comparison cannot see them, the single track may begin before its first network
-- point and run over the place where I wait (26/10, Puma 240 CVX nose to nose with the 6205 TTV leaving its
-- field). True when my train (front, centre, rear) is within passing distance of one of those segments.
-- (network lanes side by side are never compared here: two lanes of a road are closer than that and are fine)
-- extra: more room asked (m), e.g. before ending the plan (the sensors stop both earlier than the routes touch)
function ADTrafficYieldModule:isOnPartnerOffNetworkWay(extra)
    local partner = self.partner
    if partner == nil or partner.ad == nil or partner.ad.drivePathModule == nil then
        return false
    end
    local wayPoints, currentIndex = partner.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return false
    end
    local px, _, pz = ADTrafficYieldModule.getPosition(partner)
    local points = {{x = px, z = pz, off = not partner.ad.drivePathModule:isOnRoadNetwork()}}
    local distance = 0
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        local last = points[#points]
        distance = distance + MathUtil.vector2Length(wp.x - last.x, wp.z - last.z)
        table.insert(points, {x = wp.x, z = wp.z, off = wp.id == nil})
        if distance > 150 then
            break
        end
    end
    local segments = {}
    for k = 1, #points - 1 do
        if points[k].off or points[k + 1].off then
            table.insert(segments, {points[k], points[k + 1]})
        end
    end
    if #segments == 0 then
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(self.vehicle)
    local myFront, myRear = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local margin = AutoDrive.getSetting("trafficYieldMargin") or ADTrafficYieldModule.LATERAL_MARGIN
    local needed = (ADTrafficYieldModule.getWidth(self.vehicle) + ADTrafficYieldModule.getWidth(partner)) / 2 + margin + 1 + (extra or 0)
    for _, f in ipairs({myFront, 0, -myRear}) do
        local tx, tz = x + dirX * f, z + dirZ * f
        for _, seg in ipairs(segments) do
            if ADTrafficYieldModule.distanceToPolyline(seg, tx, tz) < needed then
                return true
            end
        end
    end
    return false
end

-- S2 (27/10): the partner is not done with me while its next metres run over my train (network lanes
-- included: the 7R 350 came out of the single track on other nodes and drove on into the 942 Vario), or, with routeOnly
-- false, while it drives straight at me
function ADTrafficYieldModule:isPartnerComingAtMe(routeOnly)
    local partner = self.partner
    if partner == nil or partner.ad == nil or partner.ad.drivePathModule == nil then
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local px, _, pz = ADTrafficYieldModule.getPosition(partner)
    local dist = MathUtil.vector2Length(px - x, pz - z)
    if dist > 80 then
        return false
    end
    local dirX, dirZ = ADTrafficYieldModule.getDirection(self.vehicle)
    local myFront, myRear = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local needed = (ADTrafficYieldModule.getWidth(self.vehicle) + ADTrafficYieldModule.getWidth(partner)) / 2
    local wayPoints, currentIndex = partner.ad.drivePathModule:getWayPoints()
    if wayPoints ~= nil and currentIndex ~= nil then
        local line = {{x = px, z = pz}}
        local distance = 0
        for i = math.max(1, currentIndex), #wayPoints do
            local wp = wayPoints[i]
            if wp == nil then
                break
            end
            local last = line[#line]
            distance = distance + MathUtil.vector2Length(wp.x - last.x, wp.z - last.z)
            table.insert(line, {x = wp.x, z = wp.z})
            if distance > 60 then
                break
            end
        end
        if #line >= 2 then
            for _, f in ipairs({myFront, 0, -myRear}) do
                if ADTrafficYieldModule.distanceToPolyline(line, x + dirX * f, z + dirZ * f) < needed then
                    return true, "route"
                end
            end
        end
    end
    if not routeOnly and dist < 30 and ADTrafficYieldModule.getSpeedKmh(partner) > 1 then
        local pdx, pdz = ADTrafficYieldModule.getDirection(partner)
        for _, f in ipairs({myFront, 0, -myRear}) do
            local tx, tz = x + dirX * f, z + dirZ * f
            local ahead = (tx - px) * pdx + (tz - pz) * pdz
            local lateral = math.abs((tx - px) * pdz - (tz - pz) * pdx)
            if ahead > 0 and ahead < 30 and lateral < needed then
                return true, "heading"
            end
        end
    end
    return false
end

-- the partner came out and stopped right in front of me (its sensor sees me): I am on its way, whatever the routes say
function ADTrafficYieldModule:isPartnerStoppedInFront(dt)
    local partner = self.partner
    if partner == nil then
        return false
    end
    local px, py, pz = ADTrafficYieldModule.getPosition(partner)
    local localX, _, localZ = AutoDrive.worldToLocal(self.vehicle, px, py, pz)
    local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local partnerFront = ADTrafficYieldModule.getTrainExtents(partner)
    -- 26/10 20:00 (7R 350 in a bend, MT635 stopped against it at an angle: not seen as "in front"): a cone ahead of me,
    -- not a corridor
    local gap = MathUtil.vector2Length(localX, localZ) - myFront - partnerFront
    local inFront = localZ > 0 and gap < 12 and math.abs(localX) < math.max(4, localZ * 0.7) and ADTrafficYieldModule.getSpeedKmh(partner) < 1
    self.partnerStoppedTimer = self.partnerStoppedTimer or AutoDriveTON:new()
    return self.partnerStoppedTimer:timer(inFront, 3000, dt)
end

-- S2: out of the single track but still coming at me: not done (logged once)
function ADTrafficYieldModule:isPartnerStillComing()
    local coming, how = self:isPartnerComingAtMe(false)
    if coming and not self.comingAtMeLogged then
        self.comingAtMeLogged = true
        self:log("%s is out of the single track but %s: not done yet", ADTrafficYieldModule.getName(self.partner),
            how == "route" and "its route runs over me" or "it drives at me")
        print(string.format("[AD-Croise] %s: %s est sorti du chemin unique mais %s, le croisement n'est pas fini", ADTrafficYieldModule.getName(self.vehicle),
            ADTrafficYieldModule.getName(self.partner), how == "route" and "son trajet passe sur moi" or "il vient droit sur moi"))
    end
    return coming
end

-- ------------------------------------------------------------------------------------------------------------
-- Attente avant le chemin unique
-- ------------------------------------------------------------------------------------------------------------
-- the yielder waits on its road SECTION_WAIT_CLEAR m before the single track until the other one is out of it
function ADTrafficYieldModule:updateSectionWait(dt)
    local plan = self.plan
    local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local remaining
    if plan.waitPoint ~= nil then
        local _, _, localZ = AutoDrive.worldToLocal(self.vehicle, plan.waitPoint.x, plan.waitPoint.y or 0, plan.waitPoint.z)
        remaining = localZ - myFront
        -- (its way out may still run over my place after its last network point of the single track: wait until it is past)
        if self.earlyGap == nil and self:isPartnerClearOfSection() and not self:isOnPartnerOffNetworkWay(8) and not self:isPartnerStillComing() then
            self:endPlan("partner out of the single track", true)
            return false
        end
    elseif self.earlyGap ~= nil then
        local elapsed = (g_time - (self.earlyGapTime or g_time)) / 1000
        remaining = (self.earlySectionMine or 0) - myFront - ADTrafficYieldModule.SECTION_WAIT_CLEAR - ADTrafficYieldModule.getSpeedKmh(self.vehicle) / 3.6 * elapsed
    else
        local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
        remaining = MathUtil.vector2Length(plan.sectionStart.x - x, plan.sectionStart.z - z) - myFront - ADTrafficYieldModule.SECTION_WAIT_CLEAR
        if self:isPartnerClearOfSection() and not self:isOnPartnerOffNetworkWay(8) and not self:isPartnerStillComing() then
            self:endPlan("partner out of the single track", true)
            return false
        end
    end
    -- stopped short of the wait line by something else (sensor: the other one already at the mouth, 26/10 18:00):
    -- I am waiting anyway, go on as if parked (the nose to nose rule below may back me off)
    self.waitStoppedTimer = self.waitStoppedTimer or AutoDriveTON:new()
    local stoppedShort = self.waitStoppedTimer:timer(not plan.parked and remaining > 0.5 and ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1, 3000, dt)
    if remaining > 0.5 and not plan.parked and not stoppedShort then
        local allowedSpeed = math.sqrt(2 * ADTrafficYieldModule.ANTICIPATION_DECEL * remaining) * 3.6
        local drivePathModule = self.vehicle.ad.drivePathModule
        if drivePathModule.speedLimit ~= nil then
            drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, math.max(allowedSpeed, 3))
        end
        return false
    end
    -- stopped before the single track: off the shared way, the other one may drive through
    if not plan.parked then
        self:log("waiting before the single track%s (%.1f m to the wait point%s), %s may come out", stoppedShort and string.format(" (stopped %.0f m short of the line)", remaining) or "",
            remaining, plan.waitPoint ~= nil and "" or ", no wait point", ADTrafficYieldModule.getName(self.partner))
    end
    plan.parked = true
    -- 26/10: the wait line comes from the network points, the other one may still have to drive over my place
    -- (pathfinder lead-in before its first network point): once it is close, check that my train is off its remaining route,
    -- else back off some more (once)
    do
        local reason = nil
        -- nose to nose: at most twice (it may be stopped by something else, a crossing, a third vehicle)
        if self:isPartnerStoppedInFront(dt) then
            if (plan.noseBackOffs or 0) < 2 then
                plan.noseBackOffs = (plan.noseBackOffs or 0) + 1
                reason = "stopped nose to nose with me"
            end
        elseif g_time >= (plan.nextWaitClearCheck or 0) then
            plan.nextWaitClearCheck = g_time + 1000
            local px, _, pz = ADTrafficYieldModule.getPosition(self.partner)
            local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
            if MathUtil.vector2Length(px - x, pz - z) < 60 and (self:isOnPartnerOffNetworkWay() or self:isPartnerComingAtMe(true)) then
                reason = "its way out runs over my place"
            end
        end
        if reason ~= nil and ADTrafficYieldModule.cannotReverse(self.vehicle) then
            -- A1: I never reverse: the other one backs out of my way, else the standard manoeuvre (it reverses, I park)
            self:logCannotReverse(self.partner)
            if self:resolveStuckInMouth("articulated trailer, I do not back off", "remorque articulee, je ne recule pas") then
                return true
            end
            local history = ADTrafficYieldModule.pairHistory[plan.pairKey] or {failures = 0, time = g_time}
            history.earlyTried = g_time
            ADTrafficYieldModule.pairHistory[plan.pairKey] = history
            self:endPlan("header trailer on the way of the partner, fall back to the standard manoeuvre", nil)
            return false
        end
        if reason ~= nil then
            plan.extraBackOff = (plan.extraBackOff or 0) + 10
            if plan.extraBackOff > ADTrafficYieldModule.SECTION_BACKOFF_MAX then
                -- reversing does not get me off its way: it backs out of the single track instead, or the standard manoeuvre
                self:log("still on the way of %s after %d m more: I give up backing off", ADTrafficYieldModule.getName(self.partner), plan.extraBackOff - 10)
                print(string.format("[AD-Croise] %s: toujours sur le trajet de %s apres %d m de recul en plus, j'arrete de reculer", ADTrafficYieldModule.getName(self.vehicle),
                    ADTrafficYieldModule.getName(self.partner), plan.extraBackOff - 10))
                if self:resolveStuckInMouth("still on its way after backing off", "toujours sur son trajet apres le recul") then
                    return true
                end
                local history = ADTrafficYieldModule.pairHistory[plan.pairKey] or {failures = 0, time = g_time}
                history.earlyTried = g_time
                ADTrafficYieldModule.pairHistory[plan.pairKey] = history
                self:endPlan("still on the way of the partner after backing off, fall back to the standard manoeuvre", nil)
                return false
            end
            plan.sectionBackOff = {distance = 10, where = plan.waitWhere or "chemin", extra = true}
            self.reverseTargets = nil
            self:log("%s %s: I back off 10 m more", ADTrafficYieldModule.getName(self.partner), reason)
            print(string.format("[AD-Croise] %s: %s, je recule encore de 10 m", ADTrafficYieldModule.getName(self.vehicle),
                reason == "stopped nose to nose with me" and (ADTrafficYieldModule.getName(self.partner) .. " s'est arrete nez a nez avec moi") or ("le trajet de sortie de " .. ADTrafficYieldModule.getName(self.partner) .. " passe sur ma place")))
            return self:updateSectionBackOff(dt)
        end
    end
    self:holdVehicle(dt)
    if self.stateTimer:timer(true, 120000, dt) then
        self:endPlan("wait before the single track: timeout", false)
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Recul hors de l'entrée du chemin unique
-- ------------------------------------------------------------------------------------------------------------
-- the yielder is already in the mouth of the single track (closer than SECTION_WAIT_CLEAR): it reverses along its
-- own route until its front is SECTION_WAIT_CLEAR m before the start of the track, then waits there.
-- Returns true while the module drives the vehicle
function ADTrafficYieldModule:updateSectionBackOff(dt)
    local plan = self.plan
    local backOff = plan.sectionBackOff
    if self.reverseTargets == nil then
        self.reverseTargets = self:buildReverseTargets()
        self.reverseTargetIndex = 1
        local x, y, z = ADTrafficYieldModule.getPosition(self.vehicle)
        self.reverseStart = {x = x, y = y, z = z}
        -- 26/10 (7R 350 + trailer just started its route, backed off 12 m + 10 m "straight" and ended in the grass):
        -- the back-off follows my own route behind me, never a straight line into the unknown
        self.backOffLine = {{x = x, z = z}}
        for _, t in ipairs(self.reverseTargets) do
            if t.straight then
                break
            end
            table.insert(self.backOffLine, {x = t.x, z = t.z})
        end
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local reversed = MathUtil.vector2Length(x - self.reverseStart.x, z - self.reverseStart.z)
    local blockedBehind = self.vehicle.ad.collisionDetectionModule:checkReverseCollision()
    local blockedTooLong = self.reverseBlockedTimer:timer(blockedBehind, 8000, dt)
    local target = self.reverseTargets[self.reverseTargetIndex]
    if target ~= nil and target.straight then
        target = nil -- end of my route behind me: no further
    end
    -- drifted off my route (trailer): stop here
    local offRoute = #self.backOffLine >= 2 and ADTrafficYieldModule.distanceToPolyline(self.backOffLine, x, z) > 3.5
    if offRoute and not backOff.offRouteLogged then
        backOff.offRouteLogged = true
        self:log("back-off left my route (%.1f m aside), I stop here", ADTrafficYieldModule.distanceToPolyline(self.backOffLine, x, z))
        print(string.format("[AD-Croise] %s: le recul s'ecarte de mon trace, j'arrete la", ADTrafficYieldModule.getName(self.vehicle)))
    end
    if #self.backOffLine < 2 and not backOff.noRouteLogged then
        backOff.noRouteLogged = true
        self:log("no route behind me to back off along")
        print(string.format("[AD-Croise] %s: pas de trace derriere moi, je ne recule pas", ADTrafficYieldModule.getName(self.vehicle)))
    end
    backOff.time = backOff.time or g_time
    -- 26/10 (Puma 240 CVX backed off 18 m "before the single track" and stayed nose to nose with the 6205 TTV
    -- coming out of the field): the way of the other one may run along my own route before its first network point
    -- (pathfinder lead-in, field entrance, same dirt track): the wait line is only good once my whole train is off its
    -- remaining route, else I keep reversing up to SECTION_BACKOFF_MAX
    if g_time >= (backOff.nextClearCheck or 0) then
        backOff.nextClearCheck = g_time + 500
        backOff.clear = not self:isOnPartnerOffNetworkWay()
    end
    local reached = reversed >= backOff.distance
    if reached and not backOff.clear and not backOff.extended and not backOff.extra and reversed < ADTrafficYieldModule.SECTION_BACKOFF_MAX and target ~= nil then
        backOff.extended = true
        self:log("backed off %.0f m but still on the way of %s, I keep reversing (%d m at most)", reversed, ADTrafficYieldModule.getName(self.partner), ADTrafficYieldModule.SECTION_BACKOFF_MAX)
        print(string.format("[AD-Croise] %s: recule de %.0f m mais toujours sur le trajet de %s, je continue a reculer (%d m au plus)", ADTrafficYieldModule.getName(self.vehicle),
            reversed, ADTrafficYieldModule.getName(self.partner), ADTrafficYieldModule.SECTION_BACKOFF_MAX))
    end
    local stuck = backOff.stopped and self:isReverseStuck()
    local done = (reached and (backOff.clear or reversed >= ADTrafficYieldModule.SECTION_BACKOFF_MAX)) or target == nil or blockedTooLong or stuck or offRoute or g_time - backOff.time > 60000
    if done then
        plan.sectionBackOff = nil
        self.backOffLine = nil
        -- far enough: at the wait line (3 m), or, when the wait line is only the single track itself, at least 8 m
        -- before it, and off the way of the other one; still in the mouth, across the turn-off or on its way: the other
        -- one gives way instead (25/10)
        local remaining = backOff.distance - reversed
        local farEnough = (remaining <= 3 or (backOff.where ~= "route" and remaining <= ADTrafficYieldModule.SECTION_WAIT_CLEAR - 8)) and backOff.clear == true
        if not farEnough and backOff.clear ~= true then
            self:log("back-off stopped after %.0f m, still on the way of %s", reversed, ADTrafficYieldModule.getName(self.partner))
            print(string.format("[AD-Croise] %s: recul arrete apres %.0f m, toujours sur le trajet de %s", ADTrafficYieldModule.getName(self.vehicle), reversed, ADTrafficYieldModule.getName(self.partner)))
        end
        if not farEnough then
            -- blocked behind (vehicle queue) before getting out of the mouth: classic manoeuvre, I park on the roadside
            self:log("back-off before the single track stopped after %.0f m of %.0f m", reversed, backOff.distance)
            -- 25/10: with a vehicle right behind me, I go first and the other one gives way:
            -- the vehicle in the single track backs out of my way, I drive in first
            if self:resolveStuckInMouth() then
                return true
            end
            print(string.format("[AD-Croise] %s: recul bloque apres %.0f m sur %.0f m, manoeuvre classique (je me range)", ADTrafficYieldModule.getName(self.vehicle), reversed, backOff.distance))
            local history = ADTrafficYieldModule.pairHistory[plan.pairKey] or {failures = 0, time = g_time}
            history.earlyTried = g_time
            ADTrafficYieldModule.pairHistory[plan.pairKey] = history
            self:endPlan("back-off blocked, fall back to the standard manoeuvre", nil)
            return false
        end
        -- off the shared way: wait here like a yielder that stopped before the single track
        plan.waitBeforeSection = true
        plan.parked = true
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:log("backed off %.0f m of %.0f m before the single track%s, %s may come out", reversed, backOff.distance,
            blockedTooLong and " (blocked behind)" or "", ADTrafficYieldModule.getName(self.partner))
        print(string.format("[AD-Croise] %s: recule de %.0f m sur %.0f m avant le chemin unique%s, %s peut sortir", ADTrafficYieldModule.getName(self.vehicle),
            reversed, backOff.distance, blockedTooLong and " (bloque derriere)" or "", ADTrafficYieldModule.getName(self.partner)))
        self:holdVehicle(dt)
        return true
    end
    -- stop first (it may still roll into the mouth), then reverse
    if not backOff.stopped then
        self:holdVehicle(dt)
        if ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1 then
            backOff.stopped = true
        end
        return true
    end
    if self:reverseTowards(dt, target) then
        if target.routeIndex ~= nil then
            self.reachedRouteIndex = target.routeIndex
        end
        self.reverseTargetIndex = self.reverseTargetIndex + 1
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Bloqué dans l'entrée : celui du chemin recule (SECTION_CLEAR)
-- ------------------------------------------------------------------------------------------------------------
-- 25/10, kept on 28/10 as the exceptional last resort (only with a sure spot in the two-way track; a detour may be
-- taken too; both are computed at once): I am in the mouth of the two-way track and cannot back off (vehicle right
-- behind me, articulated train).
-- Both ways out are computed: a sure spot in the track for the other one (it backs up and pulls over, I go first) and a
-- detour for me (straight on at the turn-off, or another way); the one that loses the least time is taken.
-- Returns true when one of them started, false: standard manoeuvre
function ADTrafficYieldModule:resolveStuckInMouth(why, whyFr)
    local plan = self.plan
    local other = self.partner
    if other == nil or plan == nil or plan.sectionCleared or other.ad == nil or other.ad.trafficYieldModule == nil then
        return false
    end
    local myName, otherName = ADTrafficYieldModule.getName(self.vehicle), ADTrafficYieldModule.getName(other)
    local otherModule = other.ad.trafficYieldModule
    local spot, reverseLength = nil, nil
    local spotWhy = nil
    if ADTrafficYieldModule.cannotReverse(other) then
        spotWhy = "remorque articulee"
    elseif ADTrafficYieldModule.hasFollowerBehind(other, 20, self.vehicle) then
        spotWhy = "vehicule derriere lui"
    else
        spot, reverseLength = otherModule:searchSpotBehind(self.vehicle)
        if spot == nil then
            spotWhy = "aucune place sure"
        end
    end
    local detourExtra, applyDetour = nil, nil
    local _, turnOffIndex = self:findTurnOffBeforeSection()
    local okStraight, extraStraight, applyStraight = self:tryStraightOn(turnOffIndex, true, true)
    if okStraight then
        detourExtra, applyDetour = extraStraight, applyStraight
    end
    local okDetour, extraDetour, applyOther = self:tryDetour(other, nil, true)
    if okDetour and (detourExtra == nil or extraDetour < detourExtra) then
        detourExtra, applyDetour = extraDetour, applyOther
    end
    local clearTime = spot ~= nil and (reverseLength / (ADTrafficYieldModule.REVERSE_SPEED / 3.6) + 20) or nil
    local detourTime = detourExtra ~= nil and detourExtra / (ADTrafficYieldModule.DETOUR_ROAD_SPEED / 3.6) or nil
    print(string.format("[AD-Croise] %s: %s : place sure pour %s dans le chemin : %s ; detour pour moi : %s",
        myName, whyFr or "recul impossible (vehicule colle derriere)", otherName,
        spot ~= nil and string.format("oui, %.0f m de recul (%.0f s)", reverseLength, clearTime) or ("non, " .. tostring(spotWhy)),
        detourTime ~= nil and string.format("oui, %.0f m de plus (%.0f s)", detourExtra, detourTime) or "non"))
    if clearTime ~= nil and (detourTime == nil or clearTime <= detourTime) then
        return self:startSectionClear(why, whyFr)
    end
    if detourTime ~= nil then
        applyDetour()
        plan.sectionBackOff = nil
        self.backOffLine = nil
        self.reverseTargets = nil
        plan.straightOn = true
        plan.waitBeforeSection = false
        plan.parked = true -- the other one drives on
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        print(string.format("[AD-Croise] %s: je prends le detour (%.0f m de plus), %s sort du chemin", myName, detourExtra, otherName))
        return true
    end
    -- neither: 28/10 (rule 8), the one in the track never reverses without a sure spot, I wait
    print(string.format("[AD-Croise] %s: ni place sure pour %s ni detour : j'attends, %s ne recule pas sans place sure", myName, otherName, otherName))
    return false
end

-- I am stuck in the mouth of the single track (vehicle queue behind me): roles swapped, the partner in the
-- single track reverses along its own route until it is off my way (or parks beside the track), I drive in first
function ADTrafficYieldModule:startSectionClear(why, whyFr)
    local plan = self.plan
    local other = self.partner
    if other == nil or plan == nil or plan.sectionCleared then
        return false
    end
    if ADTrafficYieldModule.hasFollowerBehind(other, 20, self.vehicle) then
        return false
    end
    plan.sectionCleared = true
    plan.mode = "sectionClear"
    plan.reverser, plan.parker = self.vehicle, other -- I drive on (REVERSER_PASS), it gets off the way
    plan.parked = false
    plan.waitBeforeSection = nil
    plan.reverserMayStop = true
    self:log("%s: %s backs out of the single track, I go first", why or "back-off blocked behind me", ADTrafficYieldModule.getName(other))
    print(string.format("[AD-Croise] %s: %s : je passe d'abord, %s recule dans le chemin", ADTrafficYieldModule.getName(self.vehicle),
        whyFr or "recul impossible (vehicule colle derriere)", ADTrafficYieldModule.getName(other)))
    local otherModule = other.ad.trafficYieldModule
    self.vehicle.ad.specialDrivingModule:releaseVehicle()
    other.ad.specialDrivingModule:releaseVehicle()
    otherModule.reverseTargets = nil
    self:setState(ADTrafficYieldModule.STATE_REVERSER_WAIT)
    self:holdVehicle(0)
    otherModule:setState(ADTrafficYieldModule.STATE_SECTION_CLEAR)
    return true
end

-- my whole train (front, centre, rear) is far enough from the route the partner still has to drive
function ADTrafficYieldModule:isClearOfPartnerRoute()
    local partner = self.partner
    local route = ADTrafficYieldModule.getRoutePolyline(partner, ADTrafficYieldModule.SECTION_CLEAR_MAX + 100)
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(self.vehicle)
    local myFront, myRear = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local margin = AutoDrive.getSetting("trafficYieldMargin") or ADTrafficYieldModule.LATERAL_MARGIN
    local needed = (ADTrafficYieldModule.getWidth(self.vehicle) + ADTrafficYieldModule.getWidth(partner)) / 2 + margin + 1
    -- its route may end at the field entrance and go on into the field: keep 20 m more around that end
    local last = route[#route]
    for _, f in ipairs({myFront, 0, -myRear}) do
        local px, pz = x + dirX * f, z + dirZ * f
        if ADTrafficYieldModule.distanceToPolyline(route, px, pz) < needed or MathUtil.vector2Length(px - last.x, pz - last.z) < needed + 20 then
            return false
        end
    end
    return true
end

-- the vehicle in the single track backs out of the way of the one stuck in the mouth, then waits until it passed
function ADTrafficYieldModule:updateSectionClear(dt)
    local plan = self.plan
    if plan.parked then
        self:holdVehicle(dt)
        local partner = self.partner
        if self:hasPassedMe(partner) or not partner.ad.drivePathModule:isOnRoadNetwork() then
            plan.passed = true
            self:endPlan("the other one went through the single track", true)
            return
        end
        if self.stateTimer:timer(true, 120000, dt) then
            self:endPlan("single track clear: wait timeout", false)
        end
        return
    end
    if self.reverseTargets == nil then
        self.reverseTargets = self:buildReverseTargets(ADTrafficYieldModule.SECTION_CLEAR_MAX)
        self.reverseTargetIndex = 1
        local x, y, z = ADTrafficYieldModule.getPosition(self.vehicle)
        self.reverseStart = {x = x, y = y, z = z}
        self.clearStartTime = g_time
    end
    -- a free place beside the track (field): park there, the other one passes (roles of the standard plan)
    if self:tryOwnParkingSpot(dt) then
        return
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local reversed = MathUtil.vector2Length(x - self.reverseStart.x, z - self.reverseStart.z)
    local blockedBehind = self.vehicle.ad.collisionDetectionModule:checkReverseCollision()
    local blockedTooLong = self.reverseBlockedTimer:timer(blockedBehind, 8000, dt)
    if self:isReverseStuck() then
        blockedTooLong = true -- S3
    end
    local target = self.reverseTargets[self.reverseTargetIndex]
    local clear = self:isClearOfPartnerRoute()
    if clear or target == nil or blockedTooLong or reversed >= ADTrafficYieldModule.SECTION_CLEAR_MAX or g_time - self.clearStartTime > 150000 then
        plan.parked = true
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:holdVehicle(dt)
        self:log("backed %.0f m out of the single track (%s), %s goes through", reversed, clear and "off its way" or (blockedTooLong and "blocked behind" or "limit"),
            ADTrafficYieldModule.getName(self.partner))
        print(string.format("[AD-Croise] %s: recule de %.0f m dans le chemin (%s), %s passe", ADTrafficYieldModule.getName(self.vehicle), reversed,
            clear and "hors de son chemin" or (blockedTooLong and "bloque derriere" or "limite"), ADTrafficYieldModule.getName(self.partner)))
        return
    end
    if self:reverseTowards(dt, target) then
        if target.routeIndex ~= nil then
            self.reachedRouteIndex = target.routeIndex
        end
        self.reverseTargetIndex = self.reverseTargetIndex + 1
    end
end
