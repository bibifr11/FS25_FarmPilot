-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleApproach.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : conduite des deux véhicules pendant le plan
-- d'avance (états YIELDER_APPROACH et PRIORITY_APPROACH).
--
-- Règle :
-- - celui qui cède (YIELDER) a YIELDER_SHARE de la distance libre pour trouver sa place, l'autre s'arrête plus tôt ;
-- - avant la ligne rouge qui mène au chemin à double sens, il vérifie le chemin : quelqu'un en sort, il s'arrête au
--   point avant la ligne rouge (28/10) ; sans ligne rouge, il attend SECTION_WAIT_CLEAR m avant le chemin (25/10), et
--   avant l'embranchement s'il n'y tient pas en entier (26/10), avec la place pour l'attelage qui sort (S1, 27/10) ;
-- - déjà dans l'entrée : il recule jusqu'à sa ligne d'attente (25/10), ou continue tout droit à l'embranchement plutôt
--   que de reculer (26/10) ; attelage articulé : l'autre recule (A1) ;
-- - arrêté sans place devant (YIELDER_STOPPED_FALLBACK) : manœuvre classique ;
-- - celui qui passe (PRIORITY) reste à PASS_GAP m de l'autre tant qu'il s'aligne (30/10) et s'arrête avant le bout du
--   trajet de rangement de l'autre.
--
-- Branché par : TrafficYieldModule:handle (updateYielderApproach, updatePriorityApproach).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Vitesse vers le véhicule en face
-- ------------------------------------------------------------------------------------------------------------
-- speed limit / hold to stop before the oncoming partner (same rule as the anticipation)
-- returns true while held at the stop point
-- share: part of the free distance this vehicle may drive (the other one drives the rest)
function ADTrafficYieldModule:limitSpeedTowards(dt, partner, share)
    share = share or 0.5
    if g_time >= (self.nextGapCheck or 0) then
        self.nextGapCheck = g_time + ADTrafficYieldModule.ANTICIPATION_INTERVAL
        self.earlyGap, self.earlySectionMine, self.earlySection = self:getOncomingGap(partner)
        self.earlyGapTime = g_time
        local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        local otherFront = ADTrafficYieldModule.getTrainExtents(partner)
        self.earlyStopGap = myFront + otherFront + ADTrafficYieldModule.ANTICIPATION_GAP
    end
    if self.earlyGap == nil then
        return false, nil
    end
    local elapsed = (g_time - (self.earlyGapTime or g_time)) / 1000
    local closing = (ADTrafficYieldModule.getSpeedKmh(self.vehicle) + ADTrafficYieldModule.getSpeedKmh(partner)) / 3.6 * elapsed
    local stopDistance = (self.earlyGap - closing - self.earlyStopGap) * share
    if stopDistance > 0.5 then
        local allowedSpeed = math.sqrt(2 * ADTrafficYieldModule.ANTICIPATION_DECEL * stopDistance) * 3.6
        local drivePathModule = self.vehicle.ad.drivePathModule
        if drivePathModule.speedLimit ~= nil then
            drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, math.max(allowedSpeed, 3))
        end
        return false, stopDistance
    end
    self:holdVehicle(dt)
    return true, stopDistance
end

-- ------------------------------------------------------------------------------------------------------------
-- Celui qui cède (YIELDER_APPROACH)
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:updateYielderApproach(dt)
    local plan = self.plan
    if plan.sectionBackOff ~= nil then
        return self:updateSectionBackOff(dt)
    end
    if plan.straightOn then
        -- driving away along the road: done once the other one is out of the single track (or no longer oncoming)
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        if self:isPartnerClearOfSection() then
            self:endPlan("partner out of the single track (straight on)", true)
        elseif self.stateTimer:timer(true, 120000, dt) then
            self:endPlan("straight on: timeout", true)
        end
        return false
    end
    -- the yielder gets most of the free distance to find a spot (the other one stops earlier)
    local holding, stopDistance = self:limitSpeedTowards(dt, self.partner, ADTrafficYieldModule.YIELDER_SHARE)
    if self.earlyGap == nil then
        -- waiting before the single track: the partner may still be in the mouth (its last node passed but its trailer
        -- not out yet, 25/10 21:00 and 21:08): keep waiting until it is clear of the entrance
        if plan.waitBeforeSection and plan.sectionStart ~= nil then
            return self:updateSectionWait(dt)
        end
        -- not oncoming any more (route changed): nothing to do. 28/10: the plan goes on through a single route comparison
        -- without the shared stretch (speeds changing, end of the 250 m look-ahead: the plan started again 4 times), 2 s in a
        -- row end it
        if self.noOncomingTimer:timer(true, 2000, dt) then
            self:endPlan("no more oncoming", nil)
            return false
        end
    else
        self.noOncomingTimer:timer(false)
    end

    -- 28/10: before driving onto the red line (Intersection) that leads into the two-way track I check the
    -- track; someone coming out, I stop at the point before the red line, no back-off. Without a red line: the wait line below
    if plan.waitBeforeSection == nil and self.earlySectionMine ~= nil then
        local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        local redLine = self:findRedLineBefore(self.earlySectionMine)
        local stopBefore = ADIntersectionModule ~= nil and ADIntersectionModule.STOP_BEFORE or 1
        if redLine ~= nil and redLine - stopBefore - myFront > -0.5 then
            local stopAt = math.max(redLine - stopBefore, myFront)
            plan.sectionStart = self:findSectionStart()
            plan.waitBeforeSection = true
            plan.redLine = true
            plan.waitWhere = "route"
            plan.waitPoint = self:getRoutePointAhead(stopAt)
            self:log("two-way track %.0f m ahead, red line at %.0f m: I wait before it, %s comes out first", self.earlySectionMine, redLine,
                ADTrafficYieldModule.getName(self.partner))
            print(string.format("[AD-Croise] %s: chemin a double sens %.0f m devant, ligne rouge a %.0f m : j'attends au point avant la ligne rouge, %s sort d'abord",
                ADTrafficYieldModule.getName(self.vehicle), self.earlySectionMine, redLine - myFront, ADTrafficYieldModule.getName(self.partner)))
        end
    end

    -- 25/10 (Puma 240 CVX waiting with its nose in the mouth of a single track, on the crossing, the 6205 TTV
    -- coming out of it held by the crossing): the single track starts ahead of me, I wait on my road
    -- SECTION_WAIT_CLEAR m before it, the other one comes out first, then I go
    if plan.waitBeforeSection == nil and self.earlySectionMine ~= nil then
        local myFront, myRear = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        plan.sectionStart = self:findSectionStart()
        -- where my front stops: SECTION_WAIT_CLEAR m before the single track; 26/10 (7R 350 stopped across the
        -- turn-off, trailer on the road in the middle of the traffic: the single track started 15 m after the turn-off):
        -- when my whole train cannot wait between the turn-off and the single track, I wait on my road before the turn-off
        -- S1 (27/10, rule of 28/10: the 942 Vario waited 11 m before the turn-off, the 7R 350 + Big Body turning out of the
        -- single track drove into it): the room left between the junction and my front is the length of the train coming
        -- out + EXIT_ROOM (at least SECTION_WAIT_CLEAR)
        local exitRoom = math.max(ADTrafficYieldModule.SECTION_WAIT_CLEAR, ADTrafficYieldModule.getTotalLength(self.partner) + ADTrafficYieldModule.EXIT_ROOM)
        plan.exitRoom = exitRoom
        local waitLine = self.earlySectionMine - exitRoom
        local turnOff, turnOffIndex = self:findTurnOffBeforeSection()
        local where = "chemin"
        -- the former line (15 m before the single track, 5 m before the turn-off), kept when the room asked would need a
        -- back-off longer than SECTION_BACKOFF_MAX (then no back-off at all would happen)
        local oldWaitLine = self.earlySectionMine - ADTrafficYieldModule.SECTION_WAIT_CLEAR
        local oldWhere = "chemin"
        if turnOff ~= nil and self.earlySectionMine - turnOff < myFront + myRear + ADTrafficYieldModule.SECTION_WAIT_CLEAR + 3 then
            local beforeTurnOff = turnOff - ADTrafficYieldModule.JUNCTION_GAP
            if beforeTurnOff < oldWaitLine then
                oldWaitLine = beforeTurnOff
                oldWhere = "route"
            end
        end
        if turnOff ~= nil and self.earlySectionMine - turnOff < myFront + myRear + exitRoom + 3 then
            local beforeTurnOff = turnOff - math.max(ADTrafficYieldModule.JUNCTION_GAP, exitRoom)
            if beforeTurnOff < waitLine then
                waitLine = beforeTurnOff
                where = "route"
            end
        end
        if waitLine - myFront <= 2 and myFront - waitLine > ADTrafficYieldModule.SECTION_BACKOFF_MAX then
            local capped = math.max(waitLine, math.min(oldWaitLine, myFront - ADTrafficYieldModule.SECTION_BACKOFF_MAX))
            if capped ~= waitLine then
                self:log("room of %.0f m for %s would need a back-off over %d m: wait line moved %.0f m forward", exitRoom,
                    ADTrafficYieldModule.getName(self.partner), ADTrafficYieldModule.SECTION_BACKOFF_MAX, capped - waitLine)
                waitLine = capped
                where = (turnOff ~= nil and waitLine < turnOff) and "route" or oldWhere
            end
        end
        plan.waitBeforeSection = waitLine - myFront > 2
        -- cannot wait before the turn-off any more: straight on along the road rather than reversing (26/10)
        if not plan.waitBeforeSection and where == "route" and self:tryStraightOn(turnOffIndex) then
            plan.straightOn = true
            plan.waitBeforeSection = false
            plan.parked = true -- the other one drives on
            self.vehicle.ad.specialDrivingModule:releaseVehicle()
            return false
        end
        plan.waitWhere = where
        if plan.waitBeforeSection then
            plan.waitPoint = self:getRoutePointAhead(waitLine)
            self:log("single track %.0f m ahead (turn-off %s m): I wait with my front %.0f m ahead (%s), %s comes out first", self.earlySectionMine,
                turnOff ~= nil and string.format("%.0f", turnOff) or "-", waitLine, where, ADTrafficYieldModule.getName(self.partner))
            print(string.format("[AD-Croise] %s: chemin unique %.0f m devant (embranchement a %s m), j'attends l'avant a %.0f m (%s, %.0f m de place pour la sortie de %s), %s sort d'abord",
                ADTrafficYieldModule.getName(self.vehicle), self.earlySectionMine, turnOff ~= nil and string.format("%.0f", turnOff) or "-", waitLine,
                where == "route" and "sur ma route avant l'embranchement" or "avant le chemin unique", exitRoom, ADTrafficYieldModule.getName(self.partner),
                ADTrafficYieldModule.getName(self.partner)))
        else
            -- 25/10 (942 Vario stopped across the mouth of the single track, the Puma 240 CVX coming out of it, waiting
            -- too close): already in the mouth, I back off along my route to the wait line
            local frontDistance = self.earlySectionMine - myFront
            local distance = myFront - waitLine
            if plan.sectionStart ~= nil and frontDistance > -ADTrafficYieldModule.SECTION_BACKOFF_INSIDE and distance <= ADTrafficYieldModule.SECTION_BACKOFF_MAX
                and not self:isInsideSection() and ADTrafficYieldModule.cannotReverse(self.vehicle) then
                -- A1: too close but I never reverse: the other one backs out of the single track, I go first
                self:logCannotReverse(self.partner)
                if self:resolveStuckInMouth("articulated trailer, I do not back off", "remorque articulee, je ne recule pas") then
                    return true
                end
            elseif plan.sectionStart ~= nil and frontDistance > -ADTrafficYieldModule.SECTION_BACKOFF_INSIDE and distance <= ADTrafficYieldModule.SECTION_BACKOFF_MAX
                and not self:isInsideSection() then
                plan.sectionBackOff = {distance = math.max(distance, 3), where = where}
                print(string.format("[AD-Croise] %s: embranchement a %s m, ligne d'attente a %.0f m", ADTrafficYieldModule.getName(self.vehicle),
                    turnOff ~= nil and string.format("%.0f", turnOff) or "-", waitLine))
                self:log("single track %.0f m ahead (front at %.0f m): too close, I back off %.0f m, %s comes out first", self.earlySectionMine, frontDistance,
                    plan.sectionBackOff.distance, ADTrafficYieldModule.getName(self.partner))
                print(string.format("[AD-Croise] %s: chemin unique a %.0f m (avant a %.0f m), trop pres : je recule de %.0f m, %s sort d'abord", ADTrafficYieldModule.getName(self.vehicle),
                    self.earlySectionMine, frontDistance, plan.sectionBackOff.distance, ADTrafficYieldModule.getName(self.partner)))
                return self:updateSectionBackOff(dt)
            end
        end
    end
    if plan.waitBeforeSection and plan.parkSpot == nil then
        return self:updateSectionWait(dt)
    end

    if plan.parkSpot == nil then
        if g_time - self.lastSearchTime >= ADTrafficYieldModule.SEARCH_INTERVAL and stopDistance ~= nil then
            self.lastSearchTime = g_time
            -- the whole stretch on the right first, the left side only as a last resort
            plan.parkSpot = self:searchSpotBySides(stopDistance + 2, true)
            if plan.parkSpot ~= nil then
                self:log("early spot found: side=%s at %.0f m, field=%s", plan.parkSpot.side, plan.parkSpot.entryDistance, tostring(plan.parkSpot.onField))
            end
        end
        -- stopped by something else (sensor, crossing) without any spot ahead: waiting for the plan timeout
        -- would block both for 3 min (25/10)
        local stoppedTooLong = self.yielderStoppedTimer:timer(ADTrafficYieldModule.getSpeedKmh(self.vehicle) < 1, ADTrafficYieldModule.YIELDER_STOPPED_FALLBACK, dt)
        if plan.parkSpot == nil and (holding or stoppedTooLong) then
            -- stopped without any spot ahead: classic manoeuvre (reverse + roadside / side branch)
            local history = ADTrafficYieldModule.pairHistory[plan.pairKey] or {failures = 0, time = g_time}
            history.earlyTried = g_time
            ADTrafficYieldModule.pairHistory[plan.pairKey] = history
            self:endPlan("no spot ahead, fall back to the standard manoeuvre", nil)
            return false
        end
        return holding
    end

    -- drive normally along the route until the leaving point, then swerve into the spot
    local spot = plan.parkSpot
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local _, _, entryLocalZ = AutoDrive.worldToLocal(self.vehicle, spot.entryX, spot.y, spot.entryZ)
    if entryLocalZ < 2 or MathUtil.vector2Length(spot.entryX - x, spot.entryZ - z) < 3 then
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:setState(ADTrafficYieldModule.STATE_PARKER_MOVE)
        return false
    end
    -- slow down so the swerve starts at park speed (no skid into the ditch at full speed)
    local parkSpeed = ADTrafficYieldModule.PARK_SPEED / 3.6
    local allowedSpeed = math.sqrt(parkSpeed * parkSpeed + 2 * ADTrafficYieldModule.ANTICIPATION_DECEL * math.max(entryLocalZ - 2, 0)) * 3.6
    local drivePathModule = self.vehicle.ad.drivePathModule
    if drivePathModule.speedLimit ~= nil then
        drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, allowedSpeed)
    end
    if holding then
        -- the spot is known and the partner waits until we are parked: never stop before reaching it
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:ensureMotorStarted()
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Celui qui passe (PRIORITY_APPROACH)
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:updatePriorityApproach(dt)
    local plan = self.plan
    if plan.parked then
        self.vehicle.ad.specialDrivingModule:releaseVehicle()
        self:setState(ADTrafficYieldModule.STATE_REVERSER_PASS)
        return false
    end
    -- 30/10 (C): while the other one finishes lining up, I stay PASS_GAP m from its front
    local parker = self.partner
    if plan.parkSpot ~= nil and parker ~= nil and parker.components ~= nil then
        local px, py, pz = ADTrafficYieldModule.getPosition(parker)
        local _, _, parkerLocalZ = AutoDrive.worldToLocal(self.vehicle, px, py, pz)
        local parkerFront = ADTrafficYieldModule.getTrainExtents(parker)
        local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        if parkerLocalZ > 0 and parkerLocalZ - parkerFront - myFront <= ADTrafficYieldModule.PASS_GAP then
            if not plan.passGapLogged then
                plan.passGapLogged = true
                self:log("%s not lined up yet: I wait %d m from it", ADTrafficYieldModule.getName(parker), ADTrafficYieldModule.PASS_GAP)
            end
            self:holdVehicle(dt)
            return true
        end
    end
    -- keep the safe stopping distance until the other one has pulled over
    local holding = self:limitSpeedTowards(dt, self.partner, 1 - ADTrafficYieldModule.YIELDER_SHARE)
    -- once the roadside spot is known, stop before the end of its path so the other train can line up completely
    local spot = plan.parkSpot
    if not holding and spot ~= nil and spot.aimX ~= nil then
        local _, _, aimLocalZ = AutoDrive.worldToLocal(self.vehicle, spot.aimX, spot.y, spot.aimZ)
        local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
        local free = aimLocalZ - myFront - ADTrafficYieldModule.SPOT_CLEARANCE
        if aimLocalZ > 0 and free <= 0.5 then
            self:holdVehicle(dt)
            return true
        elseif aimLocalZ > 0 then
            local allowedSpeed = math.sqrt(2 * ADTrafficYieldModule.ANTICIPATION_DECEL * free) * 3.6
            local drivePathModule = self.vehicle.ad.drivePathModule
            if drivePathModule.speedLimit ~= nil then
                drivePathModule.speedLimit = math.min(drivePathModule.speedLimit, math.max(allowedSpeed, 3))
            end
        end
    end
    return holding
end
