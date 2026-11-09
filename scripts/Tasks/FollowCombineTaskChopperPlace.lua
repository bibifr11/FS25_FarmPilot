-- ============================================================================================================
-- FarmPilot : FollowCombineTaskChopperPlace.lua
-- Complément de FollowCombineTask, ENSILEUSE seulement (la benne roule à côté d'elle en continu) : se replacer.
-- (moissonneuse, benne sous la goulotte : voir FollowCombinePipeHold.lua)
--
-- 1. Ensileuse de face à moins de 30 m (AutoDrive d'origine : recul) : recul seulement si elle vient vraiment vers
--    nous ; arrêtée de face : demi-tour d'abord (FollowCombineTaskChopperUTurn.lua) ; sinon la poursuite continue.
-- 2. Décrochement (poteau) : la place est derrière, la benne attend exprès que l'ensileuse la dépasse, sans recul.
-- 3. Pendant un virage Courseplay qui n'est pas un demi-tour de bout de rang (décrochement, îlot) : la benne suit
--    derrière sans s'arrêter ; ensileuse arrêtée qui attend la benne : on va à sa place si elle est devant, sinon on
--    reste arrêté (reculer mettait le nez du train dans la culture).
-- 4. Place devant mais à plus de 50 deg de côté (décrochement, ensileuse arrêtée qui attend) : on y va sans attendre.
-- 5. Ensileuse arrêtée, sa place derrière le tracteur (ou de côté et trop près devant) : recul tout droit jusqu'à
--    l'avoir BACK_AHEAD m devant (plus si elle est de côté), jamais dans sa voie devant elle ni dans la culture.
-- 6. Recul pour dégager l'ensileuse : d'abord essayé dans ses traces (STATE_TRACK_REVERSE) au lieu du recul droit
--    d'AutoDrive (STATE_REVERSING_FROM_CHOPPER).
--
-- Historique :
--   24/10       11:56 décrochement : la place est derrière, on reste arrêté exprès ; ensileuse arrêtée qui attend la
--               benne : rester arrêté aussi ; 13:26 place derrière elle revenue devant mais 7 m de côté : y aller ;
--               17:45 (3 fois au même endroit) ensileuse arrêtée, place devant à plus de 50 deg : y aller ; 17:59
--               arrêt devant la culture (S au poteau) et 20:36-20:42 fonction Courseplay des demi-tours de bout
--               de ligne : virage Courseplay qui n'est pas un demi-tour : suivre derrière ;
--   25/10       06:55 ensileuse arrêtée et place derrière elle : la benne peut reculer de quelques
--               mètres ; 08:03 le 7R fait son demi-tour avant de reprendre la poursuite
--               (le 7R tournait en rond 4 min) ; 09:58 il voyait trop tard que l'ensileuse n'avançait plus avant de
--               reculer ; 09:59 recul dans les traces fini, place loin devant : poursuite tout de suite.
--
-- Branché par : FollowCombineTask:update (checkChopperChase dans STATE_CHASING, driveChopperTurnWait dans
-- STATE_WAIT_FOR_TURN, updateChopperBackOff juste avant la machine à états), :followChasePoint (tryBackToPlace),
-- :shouldWaitForChasePos (isChopperPlaceAhead). Le recul dans les traces lui-même : CombineUnloaderMode
-- (startTrackReverse, updateTrackReverse).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- États et réglages
-- ------------------------------------------------------------------------------------------------------------
FollowCombineTask.STATE_TRACK_REVERSE = {} -- forage harvester: backing off along its own track, out of its way
FollowCombineTask.STATE_BACK_TO_PLACE = {} -- forage harvester standing, its place behind the tractor: a few metres back (25/10)
FollowCombineTask.TRACK_REVERSE_DISTANCE = 80 -- m backed off along its own track at most (forage harvester)
-- reculer vers sa place (tryBackToPlace)
FollowCombineTask.BACK_STAND_TIME = 2000 -- ms the harvester stands before the tractor backs up
FollowCombineTask.BACK_MIN_BEHIND = 3 -- m the place is behind the tractor at least
FollowCombineTask.BACK_AHEAD = 4 -- m the place must be ahead of the tractor at the end
FollowCombineTask.BACK_AHEAD_PER_SIDE = 1.2 -- m ahead more per m the place is aside (room to steer to it)
FollowCombineTask.BACK_MAX_DISTANCE = 16 -- m backed up at most
FollowCombineTask.BACK_MAX_TIME = 25000
FollowCombineTask.BACK_BLOCKED_TIME = 3000 -- ms without moving: something behind, stop there
FollowCombineTask.BACK_SPEED = 6 -- km/h
FollowCombineTask.BACK_COOLDOWN = 20000 -- ms before another one
FollowCombineTask.BACK_MIN_SIDE = 2 -- m aside at least for a place ahead to count as out of reach
FollowCombineTask.BACK_ASIDE_RATIO = 1.0 -- place less far ahead than this times its side offset (45 deg or more aside): back up first
-- l'ensileuse vient-elle vers nous ? (isChopperComingAtUs)
FollowCombineTask.COMING_MIN_SPEED = 1 -- km/h
FollowCombineTask.COMING_LANE_MARGIN = 2 -- m beside the harvester and the train

-- ------------------------------------------------------------------------------------------------------------
-- Poursuite : ensileuse de face, décrochement (appelée par update, STATE_CHASING)
-- ------------------------------------------------------------------------------------------------------------
-- rend : stop (update() s'arrête là), wrongChopperHeading mis à jour, waitingPassForJog
function FollowCombineTask:checkChopperChase(wrongChopperHeading)
    if wrongChopperHeading and not self:isChopperComingAtUs() then
        -- 25/10 08:03 (the 7R must do its U-turn before taking up the chase again): facing
        -- the standing harvester the chase can drive nowhere, the 7R looped 4 min (chase, reverse, route, chase...):
        -- its own U-turn first, the chase after
        if self:turnBeforeChase() then
            return true
        end
        -- forage harvester stopped (waiting for its unloader) or turning elsewhere at a corner: it is not coming,
        -- backing off would only make both wait for each other
        wrongChopperHeading = false
        if not self.notComingLogged then
            self.notComingLogged = true
            print(string.format("[AD-Poursuite] %s: ensileuse de face mais arretee ou pas dans notre direction, pas de recul, poursuite continue", tostring(self.vehicle:getName())))
        end
    elseif wrongChopperHeading then
        self.notComingLogged = false
    end

    -- 24/10 11:56: going behind the harvester for a jog, the place is behind us and we stand on purpose
    -- while it drives past: that is no stuck chase, no reverse in our tracks
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    -- whatever its speed (13:26:03: slowed under 2 km/h, the old timer backed off 16 m)
    local waitingPassForJog = self.combine.ad.isChopper and mode ~= nil and mode:isRearChaseHeld() and not wrongChopperHeading
    if waitingPassForJog then
        self.infoJogWaitAt = g_time or 0 -- status text
    end
    if waitingPassForJog and self.angleWrongTimer.elapsedTime > 15000 and not self.jogWaitLogged then
        self.jogWaitLogged = true
        print(string.format("[AD-Poursuite] %s: decrochement, place derriere moi, j'attends qu'elle me depasse (pas de recul)", tostring(self.vehicle:getName())))
    elseif not waitingPassForJog then
        self.jogWaitLogged = false
    end
    return false, wrongChopperHeading, waitingPassForJog
end

-- the forage harvester drives toward this unloader: moving, and the unloader stands ahead of it in its lane
function FollowCombineTask:isChopperComingAtUs()
    local combine = self.combine
    if combine == nil or combine.components == nil then
        return true
    end
    -- real motion of the harvester (positions over time): its node axes are not reliable for every harvester
    local cx, _, cz = getWorldTranslation(combine.components[1].node)
    local now = g_time or 0
    local m = self.chopperMotion
    if m == nil or now - m.t > 3000 then
        self.chopperMotion = {x = cx, z = cz, t = now, vx = 0, vz = 0}
        return false
    end
    if now - m.t >= 500 then
        local dt = (now - m.t) / 1000
        m.vx, m.vz = (cx - m.x) / dt, (cz - m.z) / dt
        m.x, m.z, m.t = cx, cz, now
    end
    local speed = math.sqrt(m.vx * m.vx + m.vz * m.vz) * 3.6
    if speed < FollowCombineTask.COMING_MIN_SPEED then
        return false
    end
    local rx, rz = m.vx / (speed / 3.6), m.vz / (speed / 3.6)
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local dx, dz = vx - cx, vz - cz
    local ahead = dx * rx + dz * rz
    if ahead <= 0 then
        return false
    end
    local lateral = math.abs(dx * rz - dz * rx)
    local combineHalf = (combine.size ~= nil and combine.size.width or 4) / 2
    local trainHalf = (self.vehicle.size ~= nil and self.vehicle.size.width or 3) / 2
    return lateral <= combineHalf + trainHalf + FollowCombineTask.COMING_LANE_MARGIN
end

-- ------------------------------------------------------------------------------------------------------------
-- Attente du virage Courseplay (appelée par update, STATE_WAIT_FOR_TURN, ensileuse à goulotte orientable)
-- ------------------------------------------------------------------------------------------------------------
-- appelée juste avant la suite d'origine (if isdrivingReverse ...) ; vrai = déjà conduit (poursuite ou arrêt),
-- la suite d'origine ne fait rien de plus
function FollowCombineTask:driveChopperTurnWait(dt, isdrivingReverse, combineIsDriving)
    -- 24/10 17:59 (stopped before the crop, S bend at the pole): a jog or an island makes the
    -- trailer follow behind the harvester; CP calls the bend a turn, but this is no U-turn: keep following
    local unloadMode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    local rearHeld = unloadMode ~= nil and unloadMode.isRearChaseHeld ~= nil and unloadMode:isRearChaseHeld()
    -- 24/10 20:36-20:42 (lost behind at the pole, Courseplay's own end-of-row U-turn function):
    -- a Courseplay turn that is no end-of-row U-turn on its turn points, nor a
    -- headland corner (loop or jog around a power pole, row finish), is followed behind as well
    local cpRow = CombineUnloaderMode.getCpRowTurn(self.combine)
    local cpNoUTurn = cpRow ~= nil and cpRow.turning and not cpRow.uTurn and not cpRow.headland
        and (cpRow.deg ~= nil or (cpRow.endIx ~= nil and cpRow.startIx ~= nil and cpRow.endIx <= cpRow.startIx))
    if cpNoUTurn and not rearHeld and not self.cpNoUTurnLogged then
        self.cpNoUTurnLogged = true
        print(string.format("[AD-Poursuite] %s: virage Courseplay qui n'est pas un demi-tour de bout de rang (%s), je suis derriere l'ensileuse sans m'arreter", FollowCombineTask.getLogName(self.vehicle), tostring(cpRow.why)))
    elseif not cpNoUTurn then
        self.cpNoUTurnLogged = false
    end
    rearHeld = rearHeld or cpNoUTurn
    -- and the harvester standing there waits for this trailer: its place ahead is driven to
    local _, _, placeAhead = AutoDrive.worldToLocal(self.vehicle, self.chasePos.x, self.chasePos.y, self.chasePos.z)
    if isdrivingReverse then
        return false
    elseif rearHeld and AutoDrive.isChopperUnloading(self.vehicle) then
        if not self.rearHeldTurnLogged then
            self.rearHeldTurnLogged = true
            print(string.format("[AD-Poursuite] %s: virage Courseplay pendant le decrochement, je reste derriere l'ensileuse sans m'arreter", FollowCombineTask.getLogName(self.vehicle)))
        end
        self:followChasePoint(dt)
        return true
    elseif not combineIsDriving and placeAhead > 0.5 and AutoDrive.isChopperUnloading(self.vehicle) then
        self:followChasePoint(dt)
        return true
    elseif not combineIsDriving and self:getAngleToCobine() > 45 and AutoDrive.isChopperUnloading(self.vehicle) then
        -- 24/10 11:56: the harvester stands and waits for the trailer, backing off only put the
        -- train nose in the crop: stand still too (the end of the turn wait sees it waiting)
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Place devant mais de côté : y aller sans attendre (appelée au début de shouldWaitForChasePos)
-- ------------------------------------------------------------------------------------------------------------
-- vrai = shouldWaitForChasePos rend faux (pas d'attente)
function FollowCombineTask:isChopperPlaceAhead()
    -- 24/10 13:26: jog, the place behind the harvester came ahead of us but 7 m aside (> 50 deg): drive to it
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if self.combine.ad.isChopper and mode ~= nil and mode:isRearChaseHeld() then
        local _, _, ahead = AutoDrive.worldToLocal(self.vehicle, self.chasePos.x, self.chasePos.y, self.chasePos.z)
        if ahead > 0.5 then
            self.angleWrongTimer:timer(false)
            return true
        end
    end
    -- 24/10 17:45 (3 times at the same place): the harvester stands and waits for this trailer, its place is
    -- ahead but more than 50 deg aside: waiting here waits for each other forever, drive to it
    if self.combine.ad.isChopper and math.abs(self.combine.lastSpeedReal or 0) < 0.0003 then
        local _, _, ahead = AutoDrive.worldToLocal(self.vehicle, self.chasePos.x, self.chasePos.y, self.chasePos.z)
        if ahead > 0.5 then
            if not self.standingCombineLogged then
                self.standingCombineLogged = true
                print(string.format("[AD-Poursuite] %s: ensileuse arretee qui m'attend, place %.0f deg de cote mais devant (%.1f m), j'y vais",
                    FollowCombineTask.getLogName(self.vehicle), self:getAngleToChasePos(), ahead))
            end
            self.angleWrongTimer:timer(false)
            return true
        end
    else
        self.standingCombineLogged = nil
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Ensileuse arrêtée, sa place derrière : reculer vers elle (appelée par followChasePoint)
-- ------------------------------------------------------------------------------------------------------------
-- (commentaire de l'appel dans followChasePoint)
-- 25/10 06:55 (harvester stopped, place behind it: the unloader may back up a few metres):
-- the harvester stands and waits for this trailer, its place lies behind the tractor: back up to it
-- 25/10 06:55 (same, during the chase):
-- the harvester stands (it waits for this trailer) and the chase place lies behind the tractor
-- (behind the harvester through a jog, or beside it after an overshoot): rolling on brings nothing (it does not move),
-- waiting makes both wait. The tractor backs up straight until the place is a few metres ahead, then the chase drives
-- to it. Never in the harvester's lane ahead of it (its header), never into the crop, once per place
function FollowCombineTask:tryBackToPlace(dt)
    local combine = self.combine
    if not AutoDrive.isChopperUnloading(self.vehicle) or self.chasePos == nil or self.filled or self.innerTurn or self.endRowTurn ~= nil then
        return false
    end
    local stoppedTime = combine.ad.noMovementTimer ~= nil and combine.ad.noMovementTimer.elapsedTime or 0
    if stoppedTime < FollowCombineTask.BACK_STAND_TIME or math.abs(combine.lastSpeedReal or 0) > FollowCombineTask.TURN_STOPPED_SPEED then
        return false
    end
    local lx, _, lz = AutoDrive.worldToLocal(self.vehicle, self.chasePos.x, self.chasePos.y or 0, self.chasePos.z)
    -- the place behind us, or aside and too close ahead to steer to it (25/10 09:58, too slow to see that the
    -- harvester no longer moved before backing up: jog place 0.5 m ahead and 7 m aside, the trailer stood 60 s
    -- beside the standing harvester before anything backed up)
    local aside = math.abs(lx) >= FollowCombineTask.BACK_MIN_SIDE and lz < math.abs(lx) * FollowCombineTask.BACK_ASIDE_RATIO
    if lz > -FollowCombineTask.BACK_MIN_BEHIND and not aside then
        return false
    end
    local where = lz < 0 and string.format("%.0f m derriere moi", -lz) or string.format("%.1f m devant moi seulement, %.0f m de cote", lz, math.abs(lx))
    local now = g_time or 0
    if self.backToPlaceLast ~= nil and now - self.backToPlaceLast < FollowCombineTask.BACK_COOLDOWN then
        return false
    end
    local name = FollowCombineTask.getLogName(self.vehicle)
    -- the train beside the harvester (clear of its header) or behind it: never backing up in its lane ahead of it
    local vx, vy, vz = getWorldTranslation(self.vehicle.components[1].node)
    local ox, _, oz = AutoDrive.worldToLocal(combine, vx, vy, vz, combine.ad.ADRootNode)
    local combineHalf = math.max(combine.size ~= nil and combine.size.width or 4, AutoDrive.getFrontToolWidth(combine) or 0) / 2
    local trainHalf = (self.vehicle.ad.pathFinderModule ~= nil and self.vehicle.ad.pathFinderModule:getTrainWidth() or 3) / 2
    local combineRear = (combine.size ~= nil and combine.size.length or 10) / 2 - (combine.size ~= nil and combine.size.lengthOffset or 0)
    local tractorFront = (self.vehicle.size ~= nil and self.vehicle.size.length or 6) / 2 + (self.vehicle.size ~= nil and self.vehicle.size.lengthOffset or 0)
    local beside = math.abs(ox) >= combineHalf + trainHalf + FollowCombineTask.ROLL_SIDE_ROOM
    local behind = oz + tractorFront < -combineRear
    if not beside and not behind then
        if not self.backToPlaceLogged then
            self.backToPlaceLogged = true
            print(string.format("[AD-Poursuite] %s: ensileuse arretee, place %s, mais je suis dans sa voie devant elle : pas de recul", name, where))
        end
        self.backToPlaceLast = now
        return false
    end
    if self:isCropBehindTrain() then
        if not self.backToPlaceLogged then
            self.backToPlaceLogged = true
            print(string.format("[AD-Poursuite] %s: ensileuse arretee, place %s, culture derriere la remorque : pas de recul", name, where))
        end
        self.backToPlaceLast = now
        return false
    end
    self.backToPlaceLogged = false
    self.backToPlaceLast = now
    -- room to steer to it: BACK_AHEAD plus BACK_AHEAD_PER_SIDE per metre aside (7 m aside: about 12.5 m ahead, 30 deg)
    local need = FollowCombineTask.BACK_AHEAD + math.abs(lx) * FollowCombineTask.BACK_AHEAD_PER_SIDE
    self.backToPlace = {sx = vx, sz = vz, time = 0, still = 0, need = need}
    print(string.format("[AD-Poursuite] %s: ensileuse arretee depuis %.0f s, place %s, je recule jusqu'a l'avoir %.0f m devant (%d m au plus)",
        name, stoppedTime / 1000, where, need, FollowCombineTask.BACK_MAX_DISTANCE))
    self.state = FollowCombineTask.STATE_BACK_TO_PLACE
    return true
end

function FollowCombineTask:updateBackToPlace(dt)
    local b = self.backToPlace
    if b == nil or self.chasePos == nil then
        self.backToPlace = nil
        self.state = FollowCombineTask.STATE_CHASING
        return
    end
    b.time = b.time + dt
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local reversed = MathUtil.vector2Length(vx - b.sx, vz - b.sz)
    local _, _, lz = AutoDrive.worldToLocal(self.vehicle, self.chasePos.x, self.chasePos.y or 0, self.chasePos.z)
    if b.time > 1500 and math.abs(self.vehicle.lastSpeedReal or 0) < 0.0003 then
        b.still = b.still + dt
    else
        b.still = 0
    end
    local why
    if lz >= b.need then
        why = "place devant"
    elseif reversed >= FollowCombineTask.BACK_MAX_DISTANCE then
        why = string.format("%d m recules", FollowCombineTask.BACK_MAX_DISTANCE)
    elseif math.abs(self.combine.lastSpeedReal or 0) > FollowCombineTask.TURN_STOPPED_SPEED then
        why = "l'ensileuse repart"
    elseif b.still > FollowCombineTask.BACK_BLOCKED_TIME then
        why = "quelque chose derriere"
    elseif b.time > FollowCombineTask.BACK_MAX_TIME then
        why = "trop long"
    elseif self:isCropBehindTrain() then
        why = "culture derriere la remorque"
    end
    if why ~= nil then
        print(string.format("[AD-Poursuite] %s: recul termine (%s) apres %.0f m, place %.0f m %s, la poursuite reprend",
            FollowCombineTask.getLogName(self.vehicle), why, reversed, math.abs(lz), lz >= 0 and "devant" or "derriere"))
        self.backToPlace = nil
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        self.state = FollowCombineTask.STATE_CHASING
        return
    end
    self.vehicle.ad.specialDrivingModule:driveReverse(dt, FollowCombineTask.BACK_SPEED, 1, self.vehicle.ad.trailerModule:canBeHandledInReverse())
end

-- ------------------------------------------------------------------------------------------------------------
-- États de recul : vers sa place, dans ses traces (appelée par update juste avant la machine à états)
-- ------------------------------------------------------------------------------------------------------------
-- vrai = update() s'arrête là
function FollowCombineTask:updateChopperBackOff(dt)
    if self.state == FollowCombineTask.STATE_BACK_TO_PLACE then
        self:updateBackToPlace(dt)
        return true
    elseif self.state == FollowCombineTask.STATE_TRACK_REVERSE then
        local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
        local result = mode:updateTrackReverse(dt)
        if result ~= "running" then
            -- 25/10 08:03 (the 7R, 8 times "quelque chose derriere" without moving a metre): nothing to gain by
            -- waiting here facing the standing harvester, its own U-turn forward instead
            if result == "blocked" and (mode.trackReverseMoved or 0) < 2 and self:turnBeforeChase("recul impossible") then
                return true
            end
            -- 25/10 09:59: the harvester stands and waits for this trailer, its place now well ahead: the chase
            -- goes there at once instead of 8 s of waiting and a new call
            if self.chasePos ~= nil and math.abs(self.combine.lastSpeedReal or 0) <= FollowCombineTask.TURN_STOPPED_SPEED then
                local _, _, ahead = AutoDrive.worldToLocal(self.vehicle, self.chasePos.x, self.chasePos.y or 0, self.chasePos.z)
                if ahead >= FollowCombineTask.BACK_AHEAD then
                    print(string.format("[AD-Poursuite] %s: recul dans les traces fini, ensileuse arretee et place %.0f m devant moi : la poursuite reprend tout de suite",
                        FollowCombineTask.getLogName(self.vehicle), ahead))
                    self.state = FollowCombineTask.STATE_CHASING
                    return true
                end
            end
            -- out of its way (or as far as possible): wait, the harvester passes, then a new call
            self.stayOnField = true
            self.state = FollowCombineTask.STATE_WAIT_BEFORE_FINISH
        end
        return true
    elseif self.state == FollowCombineTask.STATE_REVERSING_FROM_CHOPPER and AutoDrive.isChopperUnloading(self.vehicle) and not self.trackReverseTried then
        -- forage harvester: back off along its own track (crop free) to a place out of its way, not straight back
        self.trackReverseTried = true
        if self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:startTrackReverse(self.combine, FollowCombineTask.TRACK_REVERSE_DISTANCE) then
            print(string.format("[AD-Poursuite] %s: face a l'ensileuse, recul dans ses traces pour la laisser passer", FollowCombineTask.getLogName(self.vehicle)))
            self.state = FollowCombineTask.STATE_TRACK_REVERSE
        end
        return true
    end
    return false
end
