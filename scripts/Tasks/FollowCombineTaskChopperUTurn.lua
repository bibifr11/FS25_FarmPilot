-- ============================================================================================================
-- FarmPilot : FollowCombineTaskChopperUTurn.lua
-- Complément de FollowCombineTask, ENSILEUSE seulement (la benne roule à côté d'elle en continu) : les demi-tours.
-- (moissonneuse, benne sous la goulotte : voir FollowCombinePipeHold.lua)
--
-- 1. Demi-tour de bout de rang de l'ensileuse (Courseplay) : la benne reste sous la goulotte END_ROW_STOP_ADVANCE m
--    après que le point rouge du demi-tour est à portée, s'arrête, attend le premier quart de tour de l'ensileuse
--    (place libérée), puis fait son propre demi-tour vers le nouveau rang (celui d'AutoDrive, puis la manoeuvre dans la
--    bande, puis un trajet). Ensileuse arrêtée avant son demi-tour : elle attend la benne, l'attente est levée et
--    reprend quand elle repart en tournant.
-- 2. Ensileuse revenue en face après son demi-tour : la benne roule le long d'elle (S doux, plusieurs tracés essayés)
--    jusqu'à être derrière elle, puis fait son demi-tour ; sinon elle attend qu'elle soit passée (condition d'origine
--    d'AutoDrive, comme STATE_WAIT_FOR_COMBINE_TO_PASS_BY).
-- 3. Benne de face à l'ensileuse arrêtée : la poursuite ne peut rien faire, son demi-tour d'abord.
--
-- Historique :
--   23/10       arrêt au demi-tour de bout de rang, ni 3/4 ni recul ; conditions d'origine de l'ensileuse pour le
--               lancer ; 22:17 ne jamais partir avant l'ensileuse (ANTICIPATE = false) ; 22:20 manoeuvre lancée après
--               son premier quart de tour ; la benne fait son demi-tour seule avant tout trajet ; ensileuse tournée et
--               arrêtée = elle attend la benne (les deux s'attendaient, 60 s perdues) ;
--   24/10       fonction Courseplay des demi-tours de bout de ligne : attente seulement avant le point
--               rouge d'un vrai demi-tour Courseplay, un décrochement n'en est pas un ; changement de rang, ensileuse en
--               face : rouler le long d'elle ; 11:03 bout de champ : s'arrêter plus tôt (jusqu'à 1 m) ; 13:27 un seul S
--               traversait l'herbe d'un poteau : plusieurs tracés ; 18:50 départ en marche arrière dans ses traces ;
--               19:53 place derrière (décrochement, îlot) annulée pour le demi-tour ;
--   25/10 07:47 benne trop loin, l'ensileuse attend : ensileuse arrêtée avant son demi-tour, fin de l'attente ;
--   25/10 08:03 le 7R fait son demi-tour avant de reprendre la poursuite ;
--   25/10 10:00 arrêt 2 m plus loin (END_ROW_STOP_ADVANCE).
--
-- Branché par : FollowCombineTask:update (checkEndRowTurn, juste après le changement d'état) ; turnBeforeChase est
-- appelée par checkChopperChase et updateChopperBackOff (FollowCombineTaskChopperPlace.lua). Le demi-tour lui-même :
-- HandleHarvesterTurnTask (AutoDrive) puis CatchCombinePipeTask (manoeuvre dans la bande), par le drapeau
-- vehicle.ad.endRowUTurn (voir CatchCombinePipeTaskChopperUTurn.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
FollowCombineTask.END_ROW_TURN_DEG = 150 -- Courseplay course turning that much over 50 m (90 + 90): end-of-row U-turn
FollowCombineTask.END_ROW_BEND_WITHIN = 15 -- m ahead of the harvester
FollowCombineTask.END_ROW_STOP_ADVANCE = 2 -- m the harvester drives on (trailer under the pipe) after the red point is within reach, before the stop (25/10)
FollowCombineTask.END_ROW_DONE_DEG = 120 -- heading change of the harvester before the wait can end
FollowCombineTask.END_ROW_WAIT_STOPPED = 2000 -- ms: turned and standing = done
FollowCombineTask.END_ROW_PAUSE = 30000 -- ms after a wait before another one
FollowCombineTask.END_ROW_STRAIGHT_AHEAD = 30 -- m of Courseplay course read to see the harvester in its row again
FollowCombineTask.END_ROW_STRAIGHT_DEG = 20 -- deg: course ahead counted as straight below this
-- 23/10 22:17: never leave before the harvester, wait until it has freed the place, then the own U-turn
FollowCombineTask.ANTICIPATE = false
FollowCombineTask.END_ROW_FIRST_TURN = 80 -- deg turned by the harvester (its first 90 deg): the own manoeuvre starts
FollowCombineTask.ANTICIPATED_EXTRA = 5 -- m more behind the row entry: room for the harvester to finish its turn
FollowCombineTask.END_ROW_INVERTED_DEG = 150 -- original AutoDrive: harvester heading against ours, wait for the pass-by
FollowCombineTask.END_ROW_PASS_BY_RANGE = 80
FollowCombineTask.END_ROW_PASSED_BY = -10 -- m, harvester behind us along our heading: passed
FollowCombineTask.END_ROW_PASS_BY_TIME = 15000
FollowCombineTask.END_ROW_ALIGNED_DEG = 60 -- tractor within this of the harvester heading afterwards: chase on
-- 24/10: row change, the harvester comes back facing us and waits for the trailer: drive along its side
-- until the trailer is behind it, then the U-turn there (AutoDrive one, else the manoeuvre in several moves)
FollowCombineTask.PASS_ALONG_MARGIN = 5 -- m between the trailer rear and the harvester rear at the stop
-- 24/10 11:03: harvester at the field end, 5 m more behind it was off the field: stop earlier, down to 1 m
FollowCombineTask.PASS_ALONG_MIN_MARGIN = 1
FollowCombineTask.PASS_ALONG_SIDE_ROOM = 1.5 -- m between the harvester (header) side and the train side
FollowCombineTask.PASS_ALONG_S_MIN = 12
FollowCombineTask.PASS_ALONG_S_MAX = 25
FollowCombineTask.PASS_ALONG_S_PER_M = 3
FollowCombineTask.PASS_ALONG_BACKS = {0, 8, 15} -- m reversed in the own track first
FollowCombineTask.PASS_ALONG_STRAIGHTS = {0, 5, 10, 15, 20, 30} -- m straight before the S
FollowCombineTask.PASS_ALONG_S_LENGTHS = {12, 18, 25} -- m, longest S allowed
FollowCombineTask.PASS_ALONG_EXTRA_SIDE = {0, 3} -- m more room beside the harvester
FollowCombineTask.PASS_ALONG_TIME = 90000
FollowCombineTask.PASS_ALONG_BLOCKED = 6000
-- reprise de l'attente après une ensileuse arrêtée (updateEndRowHold)
FollowCombineTask.END_ROW_REARM_DEG = 10
FollowCombineTask.END_ROW_HOLD_MAX = 180000 -- ms, safety
-- de face à l'ensileuse arrêtée (turnBeforeChase)
FollowCombineTask.FACING_UTURN_DEG = 100 -- deg against the harvester heading (as the catch task)
FollowCombineTask.FACING_STOPPED_TIME = 3000 -- ms the harvester stands
FollowCombineTask.FACING_MAX_DISTANCE = 80 -- m

-- ------------------------------------------------------------------------------------------------------------
-- Accroche (appelée par update, juste après le changement d'état)
-- ------------------------------------------------------------------------------------------------------------
-- vrai = cette image est traitée, update() s'arrête là
function FollowCombineTask:checkEndRowTurn(dt)
    -- end-of-row U-turn of a forage harvester (23/10): stop and wait until it has turned, no 3/4, no reversing,
    -- then the repositioning (with its own U-turn) or the chase
    if self.state == FollowCombineTask.STATE_FINISHED and self.vehicle.ad.endRowUTurn ~= nil then
        -- end of row handed over (U-turn, anticipated place): finish now, the chase code below must not run
        self:finished()
        return true
    end
    if self:updateEndRowTurn(dt) then
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Demi-tour de bout de rang (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function FollowCombineTask:updateEndRowTurn(dt)
    local combine = self.combine
    if self.endRowPassAlong ~= nil then
        local p = self.endRowPassAlong
        local name = FollowCombineTask.getLogName(self.vehicle)
        p.time = p.time + dt
        self.stuckTimer:timer(false)
        p.blocked = math.abs(self.vehicle.lastSpeedReal or 0) < 0.0002 and p.blocked + dt or 0
        local reached = self.vehicle.ad.drivePathModule:isTargetReached()
        if not reached and p.time < FollowCombineTask.PASS_ALONG_TIME and p.blocked < FollowCombineTask.PASS_ALONG_BLOCKED then
            self.vehicle.ad.drivePathModule:update(dt)
            return true
        end
        if reached then
            print(string.format("[AD-Poursuite] %s: remorque derriere l'ensileuse, je lance mon demi-tour derriere elle", name))
        else
            print(string.format("[AD-Poursuite] %s: passage le long de l'ensileuse %s, je lance mon demi-tour ici", name,
                p.blocked >= FollowCombineTask.PASS_ALONG_BLOCKED and "bloque" or "trop long"))
        end
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.endRowPassAlong = nil
        self.vehicle.ad.endRowUTurn = g_time or 0
        self.stayOnField = true
        self.state = FollowCombineTask.STATE_FINISHED
        return true
    end
    -- original AutoDrive condition (23/10, the forage harvester's conditions to start it): turn over,
    -- harvester coming back against us: let it pass by (10 m behind us, 15 s at most), then the U-turn toward its side
    if self.endRowPassBy ~= nil then
        local p = self.endRowPassBy
        p.time = p.time + dt
        self.stuckTimer:timer(false)
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        local cx, cy, cz = getWorldTranslation(combine.components[1].node)
        local _, _, offsetZ = AutoDrive.worldToLocal(self.vehicle, cx, cy, cz)
        if offsetZ > FollowCombineTask.END_ROW_PASSED_BY and p.time < FollowCombineTask.END_ROW_PASS_BY_TIME then
            return true
        end
        print(string.format("[AD-Poursuite] %s: ensileuse %s (%.0f m derriere moi), je lance mon demi-tour", FollowCombineTask.getLogName(self.vehicle),
            offsetZ <= FollowCombineTask.END_ROW_PASSED_BY and "passee" or "pas passee apres 15 s", -offsetZ))
        self.endRowPassBy = nil
        self.vehicle.ad.endRowUTurn = g_time or 0
        self.stayOnField = true
        self.state = FollowCombineTask.STATE_FINISHED
        return true
    end
    if not self.endRowTurn then
        if (self.state ~= FollowCombineTask.STATE_CHASING and self.state ~= FollowCombineTask.STATE_WAIT_FOR_TURN)
            or not AutoDrive.isChopperUnloading(self.vehicle) or not combine.ad.isChopper or not AutoDrive:getIsCPActive(combine) then
            return false
        end
        -- kept on the tractor: a new chase task after the wait must not start a second one
        if self.vehicle.ad.endRowTurnPause ~= nil and (g_time or 0) < self.vehicle.ad.endRowTurnPause then
            return false
        end
        -- Courseplay turn points first (24/10, Courseplay's own end-of-row U-turn function):
        -- the wait starts only before the red point of an end-of-row U-turn, a loop or a jog around a power
        -- pole has none. The course shape only when the points cannot be read
        local angle, src
        local row, rowWhy = CombineUnloaderMode.getCpRowTurn(combine)
        -- 25/10 07:47: the wait ended because the harvester stood before its turn (it waited for this
        -- trailer): it starts again only once the harvester drives and really turns (heading changed since then)
        if not self:updateEndRowHold() then
            return false
        end
        if row ~= nil then
            if not row.uTurn or (not row.turning and (row.dist == nil or row.dist > FollowCombineTask.END_ROW_BEND_WITHIN)) then
                self.endRowArm = nil
                return false
            end
            -- 25/10 10:00 (stopping that far back was a problem for some trailers: 2 m further on):
            -- the trailer stays under the pipe END_ROW_STOP_ADVANCE more metres of the
            -- harvester's way before the stop, as long as it drives on without turning
            if not row.turning and math.abs(combine.lastSpeedReal or 0) > FollowCombineTask.TURN_STOPPED_SPEED then
                local cx, _, cz = getWorldTranslation(combine.components[1].node)
                if self.endRowArm == nil then
                    self.endRowArm = {x = cx, z = cz}
                    print(string.format("[AD-Poursuite] %s: point rouge du demi-tour Courseplay a %.0f m, encore %.0f m sous la goulotte avant l'arret",
                        FollowCombineTask.getLogName(self.vehicle), row.dist or -1, FollowCombineTask.END_ROW_STOP_ADVANCE))
                end
                if MathUtil.vector2Length(cx - self.endRowArm.x, cz - self.endRowArm.z) < FollowCombineTask.END_ROW_STOP_ADVANCE then
                    return false
                end
            end
            self.endRowArm = nil
            angle, src = row.deg, "points Courseplay, " .. tostring(row.why)
        else
            local bend
            angle, _, bend = CombineUnloaderMode.getCpTurnAhead(combine, CombineUnloaderMode.CP_UTURN_AHEAD)
            if angle == nil or angle < FollowCombineTask.END_ROW_TURN_DEG or bend == nil or bend > FollowCombineTask.END_ROW_BEND_WITHIN then
                return false
            end
            -- 24/10: a jog (the course comes back to its heading) is no end-of-row U-turn, the trailer goes behind
            if CombineUnloaderMode.isCpJogAhead(combine) then
                return false
            end
            src = string.format("%.0f deg sur le parcours Courseplay, points illisibles : %s", angle, tostring(rowWhy))
        end
        self.endRowTurn = {start = FollowCombineTask.getCombineHeading(combine), time = 0, cpEndIx = row ~= nil and row.endIx or nil}
        self.vehicle.ad.endRowTurnActive = true
        -- 24/10 19:53: the place behind (jog or island) was still on, the trailer followed the harvester into its
        -- U-turn at 17 km/h
        local unloadMode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
        if unloadMode ~= nil and (unloadMode.jogRearStart ~= nil or unloadMode.islandRearUntil ~= nil) then
            unloadMode.jogRearStart = nil
            unloadMode.islandRearUntil = nil
            print(string.format("[AD-Poursuite] %s: place derriere l'ensileuse (decrochement ou ilot) annulee pour le demi-tour de bout de rang", FollowCombineTask.getLogName(self.vehicle)))
        end
        if self.innerTurn then
            self:endInnerTurn("demi-tour de bout de rang, arret")
        end
        -- anticipated (23/10): Courseplay tells where the next row starts, our own U-turn starts now toward
        -- a place behind that entry, both turn at the same time
        local ex, ez, dx, dz = CombineUnloaderMode.getCpRowEntry(combine)
        if ex == nil and self.heldRowEntry ~= nil then
            -- read before the wait was released on the standing harvester (25/10), unreadable now in its turn
            ex, ez, dx, dz = self.heldRowEntry.ex, self.heldRowEntry.ez, self.heldRowEntry.dx, self.heldRowEntry.dz
        end
        self.heldRowEntry = nil
        if ex ~= nil and not self.filled then
            -- new row kept for later: own U-turn toward it once the harvester has done its first 90 deg
            local back0 = (combine.size ~= nil and combine.size.length or 10) / 2 + PathFinderModule.REAR_FALLBACK_GAP
                + AutoDrive.getTractorTrainLength(self.vehicle, true, false) / 2 + FollowCombineTask.ANTICIPATED_EXTRA
            self.vehicle.ad.anticipatedRear = {ex = ex, ez = ez, dx = dx, dz = dz, back = back0, t = g_time or 0}
        end
        if FollowCombineTask.ANTICIPATE and ex ~= nil and not self.filled then
            local back = (combine.size ~= nil and combine.size.length or 10) / 2 + PathFinderModule.REAR_FALLBACK_GAP
                + AutoDrive.getTractorTrainLength(self.vehicle, true, false) / 2 + FollowCombineTask.ANTICIPATED_EXTRA
            self.vehicle.ad.anticipatedRear = {ex = ex, ez = ez, dx = dx, dz = dz, back = back, t = g_time or 0}
            print(string.format("[AD-Poursuite] %s: demi-tour de bout de rang (%.0f deg), anticipe : nouveau rang a %.0f,%.0f cap %.0f deg, je pars me placer %.0f m derriere son entree", FollowCombineTask.getLogName(self.vehicle), angle, ex, ez, math.deg(math.atan2(dx, dz)), back))
            self.endRowTurn = nil
            self.vehicle.ad.endRowTurnActive = nil
            self.vehicle.ad.endRowTurnPause = (g_time or 0) + FollowCombineTask.END_ROW_PAUSE
            -- its own U-turn first (forward, back then forward, 3 points), then the place behind the entry
            self.vehicle.ad.endRowUTurn = g_time or 0
            self.stayOnField = true
            self.state = FollowCombineTask.STATE_FINISHED
            -- nothing else this frame: the chase must not take the hand back (23/10 22:15)
            return true
        end
        print(string.format("[AD-Poursuite] %s: demi-tour de bout de rang (%s), arret, j'attends son premier quart de tour (entree du nouveau rang %s)", FollowCombineTask.getLogName(self.vehicle), src, self.filled and "non lue, benne pleine" or (ex ~= nil and "trouvee" or tostring(CombineUnloaderMode.cpRowEntryWhy or "pas de parcours Courseplay lisible"))))
    end
    local t = self.endRowTurn
    t.time = t.time + dt
    self.stuckTimer:timer(false)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    local heading = FollowCombineTask.getCombineHeading(combine)
    local turned = math.abs(heading - t.start) % 360
    if turned > 180 then
        turned = 360 - turned
    end
    local steady = #self.turnHeadingSamples > FollowCombineTask.TURN_HEADING_SAMPLE_TIME / 500
    if steady then
        local diff = math.abs(heading - self.turnHeadingSamples[1]) % 360
        if diff > 180 then
            diff = 360 - diff
        end
        steady = diff <= FollowCombineTask.TURN_END_MAX_HEADING_CHANGE
    end
    -- 25/10 07:47 (trailer too far back, the harvester waits): held here, the harvester reached the row end
    -- without a trailer under its pipe and stopped; both waited 60 s. Standing that long before its first quarter
    -- turn it waits for this trailer: the wait ends, the chase brings the trailer under the pipe, and the wait
    -- starts again once it really turns (updateEndRowHold)
    local stoppedTime = combine.ad.noMovementTimer ~= nil and combine.ad.noMovementTimer.elapsedTime or 0
    if stoppedTime >= FollowCombineTask.TURN_STOPPED_RELEASE_TIME and turned < FollowCombineTask.END_ROW_FIRST_TURN then
        print(string.format("[AD-Poursuite] %s: ensileuse arretee depuis %.0f s avant son demi-tour (tournee de %.0f deg), elle m'attend : fin de l'attente, je reviens sous la goulotte",
            FollowCombineTask.getLogName(self.vehicle), stoppedTime / 1000, turned))
        self.endRowTurn = nil
        self.vehicle.ad.endRowTurnActive = nil
        self.vehicle.ad.endRowHold = {heading = heading, t = g_time or 0, entry = self.vehicle.ad.anticipatedRear}
        self.vehicle.ad.anticipatedRear = nil
        self.combineInTurn = false
        self.turnReleasedStopped = true
        self.state = FollowCombineTask.STATE_CHASING
        return true
    end
    -- 23/10 22:20: the harvester has done its first 90 deg (place freed): the own manoeuvre starts now
    local ant = self.vehicle.ad.anticipatedRear
    if ant ~= nil and (g_time or 0) - ant.t < PathFinderModule.ANTICIPATED_MAX_AGE and turned >= FollowCombineTask.END_ROW_FIRST_TURN then
        print(string.format("[AD-Poursuite] %s: ensileuse a fait son premier quart de tour (%.0f deg), je lance ma manoeuvre vers le nouveau rang", FollowCombineTask.getLogName(self.vehicle), turned))
        self.endRowTurn = nil
        self.vehicle.ad.endRowTurnActive = nil
        self.vehicle.ad.endRowTurnPause = (g_time or 0) + FollowCombineTask.END_ROW_PAUSE
        self.combineInTurn = false
        self.vehicle.ad.endRowUTurn = g_time or 0
        self.stayOnField = true
        self.state = FollowCombineTask.STATE_FINISHED
        return true
    end
    local forward = combine.ad.driveForwardTimer.elapsedTime >= FollowCombineTask.TURN_END_FORWARD_TIME
    -- turned and standing: it waits for this trailer in its new row (23/10: both waited for each other)
    local waiting = combine.ad.noMovementTimer ~= nil and combine.ad.noMovementTimer.elapsedTime > FollowCombineTask.END_ROW_WAIT_STOPPED
    -- standing at the row entrance it still counts as turning for Courseplay (23/10, 60 s lost): not asked then
    -- headland to row (23/10): it may align on its row with less than END_ROW_DONE_DEG turned; the turn is
    -- over too once Courseplay is no longer turning and its course ahead is straight again
    local cpTurning = AutoDrive:getIsCPTurning(combine)
    local turnOver, overWhy = false, nil
    if t.cpEndIx ~= nil then
        -- Courseplay turn points (24/10): over once it no longer turns and drives its course from the green
        -- point on. No shortcut on a straight course ahead any more (19:53:27 it ended at 23 deg, before its turn)
        local row = CombineUnloaderMode.getCpRowTurn(combine)
        turnOver = row ~= nil and not row.turning and row.ix ~= nil and row.ix >= t.cpEndIx
        if turnOver then
            overWhy = string.format("point vert %d passe, point %d du parcours Courseplay", t.cpEndIx, row.ix)
        end
    else
        local cpAhead = CombineUnloaderMode.getCpTurnAhead(combine, FollowCombineTask.END_ROW_STRAIGHT_AHEAD)
        turnOver = not cpTurning and cpAhead ~= nil and cpAhead < FollowCombineTask.END_ROW_STRAIGHT_DEG
        if turnOver then
            overWhy = string.format("parcours Courseplay droit devant : %.0f deg sur %d m", cpAhead, FollowCombineTask.END_ROW_STRAIGHT_AHEAD)
        end
    end
    local done = (turned >= FollowCombineTask.END_ROW_DONE_DEG or turnOver) and (waiting or (steady and forward and not cpTurning))
    if done and turned < FollowCombineTask.END_ROW_DONE_DEG then
        print(string.format("[AD-Poursuite] %s: ensileuse alignee sur son rang (tourne de %.0f deg, %s), fin de l'attente", FollowCombineTask.getLogName(self.vehicle), turned, tostring(overWhy)))
    end
    if not done and t.time < FollowCombineTask.MAX_TURN_TIME then
        return true
    end
    self.endRowTurn = nil
    self.vehicle.ad.endRowTurnActive = nil
    self.vehicle.ad.endRowTurnPause = (g_time or 0) + FollowCombineTask.END_ROW_PAUSE
    self.combineInTurn = false
    local rx, _, rz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local cx, _, cz = AutoDrive.localDirectionToWorld(combine, 0, 0, 1)
    local aligned = math.deg(math.acos(math.max(-1, math.min(1, rx * cx + rz * cz))))
    if done and aligned <= FollowCombineTask.END_ROW_ALIGNED_DEG and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:isUnloaderOnCorrectSide() then
        print(string.format("[AD-Poursuite] %s: demi-tour de l'ensileuse fini, tracteur dans son sens (%.0f deg), poursuite", FollowCombineTask.getLogName(self.vehicle), aligned))
        self.state = FollowCombineTask.STATE_CHASING
    else
        print(string.format("[AD-Poursuite] %s: demi-tour de l'ensileuse %s, tracteur a %.0f deg, repositionnement avec son demi-tour", FollowCombineTask.getLogName(self.vehicle), done and "fini" or "trop long", aligned))
        -- original AutoDrive (STATE_WAIT_FOR_COMBINE_TO_PASS_BY): heading inverted and close, it comes back along us:
        -- wait until it has passed, the U-turn then ends behind it instead of crossing its way
        local cx, cy, cz = getWorldTranslation(combine.components[1].node)
        local _, _, offsetZ = AutoDrive.worldToLocal(self.vehicle, cx, cy, cz)
        if done and aligned >= FollowCombineTask.END_ROW_INVERTED_DEG and AutoDrive.getDistanceBetween(self.vehicle, combine) < FollowCombineTask.END_ROW_PASS_BY_RANGE
            and offsetZ > FollowCombineTask.END_ROW_PASSED_BY then
            local points, target = self:buildPassAlong(combine)
            if points ~= nil then
                print(string.format("[AD-Poursuite] %s: changement de ligne, ensileuse en face (%.0f deg, %.0f m) : je roule le long d'elle a %.1f m de son axe, %d m, puis demi-tour derriere elle",
                    FollowCombineTask.getLogName(self.vehicle), aligned, offsetZ, target, #points - 1))
                local dpm = self.vehicle.ad.drivePathModule
                dpm:setWayPoints(points)
                -- starts with a reverse in its own track: driven in reverse from the start (the drive module begins
                -- every path forward and turned round toward a point behind the trailer, 24/10 18:50)
                if points[2] ~= nil and points[2].isReverse then
                    dpm.isReversing = true
                    self.vehicle.ad.specialDrivingModule:reset()
                    self.vehicle.ad.specialDrivingModule.currentWayPointIndex = dpm:getCurrentWayPointIndex()
                end
                self.endRowPassAlong = {time = 0, blocked = 0}
                return true
            end
            print(string.format("[AD-Poursuite] %s: ensileuse revient contre moi (%.0f deg), passage le long d'elle impossible (%s), j'attends qu'elle soit passee", FollowCombineTask.getLogName(self.vehicle), aligned, tostring(target)))
            self.endRowPassBy = {time = 0}
            return true
        end
        -- 23/10: the unloader turns by itself (forward U-turn, back then U-turn, 3 points) before any route
        self.vehicle.ad.endRowUTurn = g_time or 0
        self.stayOnField = true
        self.state = FollowCombineTask.STATE_FINISHED
        return true
    end
    return false
end

-- after a wait ended on a standing harvester: true once the wait may start again (it drives and has turned
-- END_ROW_REARM_DEG since), false while it is held
function FollowCombineTask:updateEndRowHold()
    local hold = self.vehicle.ad.endRowHold
    if hold == nil then
        return true
    end
    local heading = FollowCombineTask.getCombineHeading(self.combine)
    local turnedSince = math.abs(heading - hold.heading) % 360
    if turnedSince > 180 then
        turnedSince = 360 - turnedSince
    end
    local driving = math.abs(self.combine.lastSpeedReal or 0) > FollowCombineTask.TURN_STOPPED_SPEED
    if driving and turnedSince >= FollowCombineTask.END_ROW_REARM_DEG then
        print(string.format("[AD-Poursuite] %s: l'ensileuse est repartie et tourne (%.0f deg depuis son arret), l'attente de bout de rang peut reprendre",
            FollowCombineTask.getLogName(self.vehicle), turnedSince))
        -- the new row entry read before the release serves again (not readable any more once it is in its turn)
        self.heldRowEntry = hold.entry
        self.vehicle.ad.endRowHold = nil
        return true
    end
    if (g_time or 0) - hold.t > FollowCombineTask.END_ROW_HOLD_MAX then
        self.vehicle.ad.endRowHold = nil
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Ensileuse revenue en face : rouler le long d'elle, puis demi-tour derrière elle
-- ------------------------------------------------------------------------------------------------------------
-- forward points along the harvester line (its heading reversed), side gap taken up by a gentle S, checked for
-- Strict field / crop and for vehicles or obstacles under the tractor and the trailer; nil, why when it does not fit
function FollowCombineTask:buildPassAlong(combine)
    local hx, _, hz = AutoDrive.localDirectionToWorld(combine, 0, 0, 1)
    local len = math.sqrt(hx * hx + hz * hz)
    if len < 0.01 then
        return nil, "cap de l'ensileuse inconnu"
    end
    hx, hz = hx / len, hz / len
    local nx, nz = hz, -hx
    local cx, _, cz = getWorldTranslation(combine.components[1].node)
    local tx, _, tz = getWorldTranslation(self.vehicle.components[1].node)
    local along = (tx - cx) * hx + (tz - cz) * hz
    local gap = (tx - cx) * nx + (tz - cz) * nz
    local trainWidth = self.vehicle.ad.pathFinderModule ~= nil and self.vehicle.ad.pathFinderModule:getTrainWidth() or 3
    local combineWidth = math.max(combine.size ~= nil and combine.size.width or 4, AutoDrive.getFrontToolWidth(combine) or 0)
    local side = combineWidth / 2 + trainWidth / 2 + FollowCombineTask.PASS_ALONG_SIDE_ROOM
    local combineRear = (combine.size ~= nil and combine.size.length or 10) / 2 - (combine.size ~= nil and combine.size.lengthOffset or 0)
    local tractorLength = self.vehicle.size ~= nil and self.vehicle.size.length or 6
    local tractorOffset = self.vehicle.size ~= nil and self.vehicle.size.lengthOffset or 0
    local d0 = math.max(0, AutoDrive.getTractorTrainLength(self.vehicle, true, false) - tractorLength / 2)
    local aEnd = -(combineRear + FollowCombineTask.PASS_ALONG_MARGIN + d0)
    if along - aEnd < 10 then
        return nil, string.format("deja derriere elle (%.0f m)", along)
    end
    local probe = setmetatable({vehicle = self.vehicle}, {__index = HandleHarvesterTurnTask}) -- (09/11) méthodes de HandleHarvesterTurnTask, voir checkGround
    local head = string.format("ensileuse %.0f,%.0f, tracteur %.0f,%.0f, %.0f m devant / %.0f m de cote", cx, cz, tx, tz, along, gap)
    local function at(s0, lateral, isReverse)
        local x, z = cx + hx * s0 + nx * lateral, cz + hz * s0 + nz * lateral
        return {x = x, y = AutoDrive:getTerrainHeightAtWorldPos(x, z) or 0, z = z, isReverse = isReverse}
    end
    -- 24/10 13:27: one S only crossed the grass patch of a power pole. Several layouts, the simplest first:
    -- a short reverse in the own track first, a straight stretch, then the S (length, side room)
    local best = nil
    local tried = 0
    local signs = gap >= 0 and {1, -1} or {-1, 1}
    for _, back in ipairs(FollowCombineTask.PASS_ALONG_BACKS) do
        for _, straight in ipairs(FollowCombineTask.PASS_ALONG_STRAIGHTS) do
            for _, sMax in ipairs(FollowCombineTask.PASS_ALONG_S_LENGTHS) do
                for _, extra in ipairs(FollowCombineTask.PASS_ALONG_EXTRA_SIDE) do
                    for _, sign in ipairs(signs) do
                        local target = sign * math.max(side + extra, sign * gap > 0 and math.abs(gap) or 0)
                        local a0 = along + back
                        local total = a0 - aEnd
                        local sLen = math.max(FollowCombineTask.PASS_ALONG_S_MIN, math.min(sMax, math.abs(target - gap) * FollowCombineTask.PASS_ALONG_S_PER_M))
                        if straight + sLen <= total - 2 then
                            tried = tried + 1
                            local points = {}
                            -- reverse in the own track (the train came that way), checked at the end only
                            if back > 0 then
                                for d = 0, back, 1 do
                                    table.insert(points, at(along + d, gap, true))
                                end
                            end
                            local fwdStart = #points
                            local n = math.max(2, math.floor(total))
                            for i = 0, n do
                                local d = total * i / n
                                local u = math.max(0, math.min(1, (d - straight) / math.max(sLen, 0.1)))
                                local lateral = gap + (target - gap) * (3 * u * u - 2 * u * u * u)
                                table.insert(points, at(a0 - d, lateral, false))
                            end
                            local keep, why = #points, nil
                            for i = fwdStart + 2, #points do
                                local good, w = HandleHarvesterTurnTask.checkGround(probe, {points[i - 1], points[i]}, 1)
                                if not good then
                                    keep = i - 1
                                    why = string.format("%s a %.0f m", tostring(w), total * (i - 1 - fwdStart - 1) / n)
                                    break
                                end
                            end
                            local ok = true
                            if keep < #points then
                                local sKeep = (points[keep].x - cx) * hx + (points[keep].z - cz) * hz
                                local margin = -sKeep - d0 - combineRear
                                if margin < FollowCombineTask.PASS_ALONG_MIN_MARGIN then
                                    ok = false
                                    -- the failure that went furthest is the one reported
                                    if best == nil or keep > best.keep then
                                        best = {keep = keep, why = string.format("%s (recul %d, droit %d, S %d, cote %s)", why, back, straight, sMax, sign * gap >= 0 and "actuel" or "oppose")}
                                    end
                                else
                                    for i = #points, keep + 1, -1 do
                                        table.remove(points, i)
                                    end
                                end
                            end
                            if ok then
                                local hit = self:passAlongObstacle(points, trainWidth, tractorLength, tractorOffset, d0)
                                if hit == nil then
                                    print(string.format("[AD-Poursuite] %s: passage le long de l'ensileuse : recul %d m, droit %d m, S %.0f m, cote %s, ecart %.1f m (essai %d)%s",
                                        FollowCombineTask.getLogName(self.vehicle), back, straight, sLen, sign * gap >= 0 and "actuel" or "oppose", math.abs(target), tried,
                                        why ~= nil and (", raccourci : " .. why) or ""))
                                    return points, target
                                end
                                if best == nil then
                                    best = {keep = 0, why = hit}
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, string.format("%s, %d essais, le plus loin : %s", head, tried, best ~= nil and best.why or "aucun")
end

-- tractor body every 2 m (the harvester is NOT left out: we must not touch it), trailer body at the stop
function FollowCombineTask:passAlongObstacle(points, trainWidth, tractorLength, tractorOffset, d0)
    local module = self.vehicle.ad.trafficYieldModule
    if module == nil or module.overlapHit == nil then
        return nil
    end
    local halfW = trainWidth / 2
    local last = 0
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if not b.isReverse and (i == #points or i - last >= 2) then
            last = i
            local dx, dz = b.x - a.x, b.z - a.z
            local l = math.max(0.01, math.sqrt(dx * dx + dz * dz))
            dx, dz = dx / l, dz / l
            local x, z = b.x + dx * tractorOffset, b.z + dz * tractorOffset
            local y = AutoDrive:getTerrainHeightAtWorldPos(x, z) or 0
            if module:overlapHit(x, y + 2, z, math.atan2(dx, dz), halfW, 1.5, tractorLength / 2) then
                return string.format("vehicule ou obstacle vers %.0f,%.0f", x, z)
            end
            if i == #points and d0 > 1 then
                local mx, mz = b.x - dx * (tractorLength / 2 + d0 / 2), b.z - dz * (tractorLength / 2 + d0 / 2)
                local my = AutoDrive:getTerrainHeightAtWorldPos(mx, mz) or 0
                if module:overlapHit(mx, my + 2, mz, math.atan2(dx, dz), halfW, 1.5, d0 / 2) then
                    return string.format("remorque sur un vehicule ou obstacle vers %.0f,%.0f", mx, mz)
                end
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- De face à l'ensileuse arrêtée : demi-tour d'abord
-- ------------------------------------------------------------------------------------------------------------
-- 25/10 08:03 (the 7R must do its U-turn before taking up the chase again): the train
-- faces the standing harvester (the wrong way round) and no Courseplay turn of hers will bring it round: the chase
-- hands over to its own U-turn (AutoDrive's end-of-row U-turn first, then the strip manoeuvre, then a route)
function FollowCombineTask:turnBeforeChase(why)
    local combine = self.combine
    if not AutoDrive.isChopperUnloading(self.vehicle) or self.filled or (self.angleToCombineHeading or 0) < FollowCombineTask.FACING_UTURN_DEG
        or (self.distanceToCombine or math.huge) > FollowCombineTask.FACING_MAX_DISTANCE then
        return false
    end
    local stoppedTime = combine.ad.noMovementTimer ~= nil and combine.ad.noMovementTimer.elapsedTime or 0
    if stoppedTime < FollowCombineTask.FACING_STOPPED_TIME then
        return false
    end
    -- a real Courseplay turn being driven brings it round (the maneuvering flag is also raised while it stands)
    local row = CombineUnloaderMode.getCpRowTurn(combine)
    if row ~= nil and row.turning then
        return false
    end
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if mode ~= nil and mode:isRearChaseHeld() then
        return false
    end
    print(string.format("[AD-Poursuite] %s: de face a l'ensileuse arretee (%.0f deg, %.0f m%s), la poursuite ne peut rien faire : demi-tour d'abord (AutoDrive, puis manoeuvre dans la bande, puis trajet)",
        FollowCombineTask.getLogName(self.vehicle), self.angleToCombineHeading or -1, self.distanceToCombine or -1, why ~= nil and (", " .. why) or ""))
    self.vehicle.ad.endRowUTurn = g_time or 0
    self.stayOnField = true
    self.state = FollowCombineTask.STATE_FINISHED
    return true
end
