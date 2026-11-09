-- ============================================================================================================
-- FarmPilot : CatchCombinePipeTaskChopperUTurn.lua
-- Complément de CatchCombinePipeTask, ENSILEUSE seulement (la benne roule à côté d'elle en continu) : les demi-tours du
-- train pour se mettre dans son sens. (moissonneuse : le trajet d'AutoDrive d'origine)
--
-- 1. Demi-tour dans la bande (STATE_BAND_TURN, BandTurnModule.lua) : en secours seulement, aucun trajet en marche avant ou
--    poursuite bloquée plusieurs fois au même endroit, le cap de l'ensileuse derrière le nôtre ; pas pendant son virage
--    de fourrière (cap lu chaque seconde) ni juste après (elle revient vers le train).
-- 2. Bout de rang (FollowCombineTaskChopperUTurn.lua l'a demandé, vehicle.ad.endRowUTurn) : le train à l'envers de
--    l'ensileuse fait son propre demi-tour vers son côté (avant, arrière puis avant, 3 points), le trajet calculé
--    seulement si aucun ne passe.
-- 3. À l'envers près d'elle (REVERSED_ANGLE) : demi-tour d'abord (celui d'AutoDrive, puis la manoeuvre en 3/5/7 coups).
-- 4. Arrivées à l'envers au même endroit (WRONG_WAY_*) : demi-tour vers son cap, sinon recul, et plus de place pour le
--    virage dans le trajet suivant ; un trajet court qui ne peut pas tourner le train vers son cap est refusé.
--
-- Historique :
--   23/10       bout de rang, le train contre son cap : son propre demi-tour d'abord ;
--   24/10 18:01 70 s en boucle à 135 deg avec une limite à 150 (REVERSED_ANGLE = 100) ;
--   25/10 08:03 le 7R à côté de l'ensileuse arrêtée à 177 deg : à côté ou devant elle aussi ;
--   25/10 16:35 aucune façon d'aller à côté de l'ensileuse (6205 TTV à 101 deg, 22 m) ; la règle des 120 deg
--               levée près d'elle arrêtée ;
--   25/10 19:14 pas de place derrière elle (haie, bord du champ) : le demi-tour tout de suite ;
--   25/10 22:34 une fois par endroit, comme le recul pour ouvrir l'angle ;
--   26/10 17:20 942 Vario : le même bout de 19 m refusé 8 fois : la règle « face à la moissonneuse » levée pour le calcul
--               suivant (PathFinderModule).
--
-- Branché par : CatchCombinePipeTask:update (sampleCombineHeading, updateBandTurnState, checkEndRowUTurn et
-- checkCloseRangeBandTurn avant la machine à états ; refuseUselessRoute dans STATE_PATHPLANNING) ; tryBandTurn,
-- tryReversedUTurn et tryWrongWayTurn par les solutions de repli et l'arrivée (CatchCombinePipeTaskClear.lua,
-- CatchCombinePipeTaskHandover.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- États et réglages
-- ------------------------------------------------------------------------------------------------------------
CatchCombinePipeTask.STATE_BAND_TURN = {} -- forage harvester: U-turn in the strip, the train faces the wrong way
CatchCombinePipeTask.BAND_TURN_RANGE = 100 -- m from the harvester
CatchCombinePipeTask.BAND_TURN_ANGLE = 90 -- deg: harvester heading this far from ours is behind
CatchCombinePipeTask.BAND_TURN_YAW_RATE = 6 -- deg/s: harvester turning faster than this is in its headland turn
CatchCombinePipeTask.BAND_TURN_AFTER_TURN = 25000 -- ms after the harvester's turn: no U-turn, it comes back to the train
CatchCombinePipeTask.BAND_TURN_BEHIND_RANGE = 40 -- m: harvester only placed behind (heading not reversed) counts this close
CatchCombinePipeTask.END_ROW_UTURN_AGE = 20000    -- ms after the end-of-row wait: own U-turn tried first
CatchCombinePipeTask.END_ROW_UTURN_ANGLE = 120     -- deg against the harvester heading
-- à l'envers (tryReversedUTurn)
CatchCombinePipeTask.REVERSED_ANGLE = 100          -- deg against the harvester heading: the wrong way round (24/10 18:01: 70 s looping at 135 deg with 150)
CatchCombinePipeTask.REVERSED_RANGE = 80
CatchCombinePipeTask.REVERSED_RETRY_DISTANCE = 10
CatchCombinePipeTask.REVERSED_RETRY_TIME = 90000
-- arrivées à l'envers au même endroit (tryWrongWayTurn), trajet court inutile (isUselessShortRoute)
CatchCombinePipeTask.WRONG_WAY_RANGE = 45        -- m from the harvester
CatchCombinePipeTask.WRONG_WAY_RADIUS = 6        -- m: arrivals closer than this count as the same place
CatchCombinePipeTask.WRONG_WAY_ROOM_STEP = 8     -- m added to the aimed point setback per arrival at the same place
CatchCombinePipeTask.WRONG_WAY_ROOM_MAX = 32
CatchCombinePipeTask.WRONG_WAY_FORGET = 120000   -- ms
CatchCombinePipeTask.SHORT_ROUTE_LENGTH = 25     -- m: a route this short ...
CatchCombinePipeTask.SHORT_ROUTE_END_ANGLE = 60  -- deg: ... ending this far from the harvester heading cannot hand over

-- ------------------------------------------------------------------------------------------------------------
-- Accroches (appelées par CatchCombinePipeTask:update)
-- ------------------------------------------------------------------------------------------------------------
-- avant la machine à états (état retiré de celle-ci) ; vrai = update() s'arrête là
function CatchCombinePipeTask:updateBandTurnState(dt)
    if self.state == CatchCombinePipeTask.STATE_BAND_TURN then
        local result = ADBandTurn.update(self.vehicle, dt)
        if result == "joined" then
            self.state = CatchCombinePipeTask.STATE_FINISHED
        elseif result ~= "running" then
            if result == "done" then
                -- turned: plan at once, the earlier failures were for the other heading
                self.retryDelay = CatchCombinePipeTask.RETRY_DELAY_MIN
                self.lastFailure = nil
            end
            self.waitForCheckTimer.elapsedTime = 4000
            self.state = CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
        end
        return true
    end
    return false
end

-- avant la machine à états ; vrai = update() s'arrête là
function CatchCombinePipeTask:checkEndRowUTurn()
    -- end of row, unloader against the harvester heading (23/10): its own U-turn first, to the
    -- harvester side (forward, back then forward, 3 points), the planned route only if none fits
    if self.vehicle.ad.endRowUTurn ~= nil and (self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.state == CatchCombinePipeTask.STATE_DELAY_PATHPLANNING) then
        local since = (g_time or 0) - self.vehicle.ad.endRowUTurn
        self.vehicle.ad.endRowUTurn = nil
        if since < CatchCombinePipeTask.END_ROW_UTURN_AGE and self:tryEndRowUTurn() then
            return true
        end
    end
    return false
end

-- avant la machine à états ; vrai = update() s'arrête là
function CatchCombinePipeTask:checkCloseRangeBandTurn()
    -- forage harvester: the chase was blocked several times at the same place (no straight line forward) and the
    -- harvester heading is behind: U-turn in the strip as a fallback
    if self.closeRangePlanning and not self.bandTurnChecked then
        self.bandTurnChecked = true
        if self:tryBandTurn("poursuite bloquee") then
            return true
        end
    end
    return false
end

-- STATE_PATHPLANNING, trajet trouvé ; vrai = trajet refusé, update() s'arrête là
function CatchCombinePipeTask:refuseUselessRoute()
    -- 25/10 16:35 (6205 TTV: the same 12 m one-cell route every 1.3 s, ending at 101 deg from the standing
    -- harvester): a short route that cannot turn the train toward the harvester heading is useless, the
    -- wrong-way ladder runs instead (band turn toward its heading, back off, more room in the next route)
    if self:isUselessShortRoute(self.wayPoints) then
        local pfm = self.vehicle.ad.pathFinderModule
        local wasPartial = pfm.partialPath == true
        pfm:reset()
        self.preplanning = false
        if self:tryWrongWayTurn(self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombineHeading()) then
            return true
        end
        self:updateRetryDelay()
        -- 26/10 17:20 (942 Vario: the same 19 m stub refused 8 times, the face-to-face rule had cut a 77 m
        -- route down to it): the second identical failure of a cut route lifts that rule for the next plan
        if wasPartial and self.lastFailure ~= nil and self.retryDelay > CatchCombinePipeTask.RETRY_DELAY_MIN and not pfm.partialFacingLifted then
            pfm.partialFacingLifted = true
            print(string.format("[AD-Fin] %s: trajet coupe refuse deux fois de suite, regle face a la moissonneuse levee pour le prochain calcul", tostring(self.vehicle:getName())))
        end
        self.state = CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Cap de l'ensileuse
-- ------------------------------------------------------------------------------------------------------------
-- harvester heading once per second: remembers when it last turned (headland turn)
function CatchCombinePipeTask:sampleCombineHeading()
    if self.combine == nil or g_time == nil then
        return
    end
    local last = self.combineHeading
    if last ~= nil and g_time - last.t < 1000 then
        return
    end
    local dx, _, dz = AutoDrive.localDirectionToWorld(self.combine, 0, 0, 1)
    local yaw = math.deg(math.atan2(dx, dz))
    if last ~= nil then
        local d = math.abs(yaw - last.yaw) % 360
        if d > 180 then
            d = 360 - d
        end
        if d / ((g_time - last.t) / 1000) > CatchCombinePipeTask.BAND_TURN_YAW_RATE then
            self.combineTurnedAt = g_time
        end
    end
    self.combineHeading = {yaw = yaw, t = g_time}
end

-- Courseplay turn really being driven (its turn course). The AutoDrive flag (getIsCPTurning, "maneuvering") is also
-- raised while the harvester stands waiting for a trailer (25/10 08:03): read on its turn points when possible
function CatchCombinePipeTask:isCombineReallyTurning()
    if self.combine == nil then
        return false
    end
    local row = CombineUnloaderMode.getCpRowTurn(self.combine)
    if row ~= nil then
        return row.turning == true
    end
    local standing = self.combine.ad ~= nil and self.combine.ad.noMovementTimer ~= nil and self.combine.ad.noMovementTimer.elapsedTime > 3000
    return AutoDrive:getIsCPTurning(self.combine) and not standing
end

-- ------------------------------------------------------------------------------------------------------------
-- Demi-tours
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester, fallback only (no forward route): U-turn in the strip when its heading is behind ours
function CatchCombinePipeTask:tryBandTurn(why)
    if not AutoDrive.isChopperUnloading(self.vehicle) then
        return false
    end
    if not ADBandTurn.canTry(self.vehicle) then
        print(string.format("[AD-DemiTour] %s: %s, pas de demi-tour de secours ici (deja echoue a moins de %d m il y a moins de %d s)", tostring(self.vehicle:getName()), why, ADBandTurn.RETRY_DISTANCE, ADBandTurn.RETRY_TIME / 1000))
        return false
    end
    local distance = AutoDrive.getDistanceBetween(self.vehicle, self.combine)
    if distance > CatchCombinePipeTask.BAND_TURN_RANGE then
        return false
    end
    -- harvester turning or just turned at the headland: its heading means nothing yet, it comes back, wait
    -- (25/10: the AutoDrive turn flag alone is also raised while it stands waiting for a trailer, its turn points decide)
    if self:isCombineReallyTurning() or (self.combineTurnedAt ~= nil and g_time - self.combineTurnedAt < CatchCombinePipeTask.BAND_TURN_AFTER_TURN) then
        if self.bandTurnTurnLogAt == nil or g_time - self.bandTurnTurnLogAt > 5000 then
            self.bandTurnTurnLogAt = g_time
            print(string.format("[AD-DemiTour] %s: %s, pas de demi-tour de secours (l'ensileuse tourne ou vient de tourner en bout de rang, attente)", tostring(self.vehicle:getName()), why))
        end
        return false
    end
    -- a partial route was found and only waits for a clean stop: not stuck, the next plan goes on
    local pfm = self.vehicle.ad.pathFinderModule
    if pfm.partialPath and (pfm.partialFailCount or 0) > 0 and pfm.partialFailCount < PathFinderModule.PARTIAL_FACING_LIFT_FAILURES then
        print(string.format("[AD-DemiTour] %s: %s, pas de demi-tour de secours (trajet partiel trouve, attente %d/%d)", tostring(self.vehicle:getName()), why, pfm.partialFailCount, PathFinderModule.PARTIAL_FACING_LIFT_FAILURES))
        return false
    end
    -- behind: its heading reversed against ours, or the harvester itself behind us (the route must turn around)
    local behind, angle = ADBandTurn.isFacingHarvester(self.vehicle, self.combine, CatchCombinePipeTask.BAND_TURN_RANGE, CatchCombinePipeTask.BAND_TURN_ANGLE)
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    local dx, _, dz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local bearing = math.abs(AutoDrive.angleBetween({x = dx, z = dz}, {x = cx - vx, z = cz - vz}))
    if not behind and (bearing < CatchCombinePipeTask.BAND_TURN_ANGLE or distance > CatchCombinePipeTask.BAND_TURN_BEHIND_RANGE) then
        print(string.format("[AD-DemiTour] %s: %s, pas de demi-tour de secours (ensileuse pas derriere : cap %.0f deg, position %.0f deg, %.0f m)", tostring(self.vehicle:getName()), why, angle or -1, bearing, distance))
        return false
    end
    if not ADBandTurn.start(self.vehicle, string.format("secours, %s : cap ensileuse %.0f deg, ensileuse a %.0f deg, %.0f m", why, angle or -1, bearing, distance), self.combine) then
        return false
    end
    self.vehicle.ad.pathFinderModule:reset()
    self.preplanning = false
    self.infoEndRowTurn = false -- status text
    self.state = CatchCombinePipeTask.STATE_BAND_TURN
    return true
end

function CatchCombinePipeTask:tryEndRowUTurn()
    if not AutoDrive.isChopperUnloading(self.vehicle) or self.combine == nil then
        return false
    end
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    local dx, _, dz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local facing, angle
    local ant = self.vehicle.ad.anticipatedRear
    if ant ~= nil and (g_time or 0) - ant.t < PathFinderModule.ANTICIPATED_MAX_AGE then
        -- anticipated: the harvester has not turned yet, the new row (Courseplay course) gives the heading and side
        angle = math.deg(math.acos(math.max(-1, math.min(1, dx * ant.dx + dz * ant.dz))))
        facing = angle >= CatchCombinePipeTask.END_ROW_UTURN_ANGLE
        cx, cz = ant.ex, ant.ez
    else
        facing, angle = ADBandTurn.isFacingHarvester(self.vehicle, self.combine, CatchCombinePipeTask.BAND_TURN_RANGE, CatchCombinePipeTask.END_ROW_UTURN_ANGLE)
    end
    -- 25/10 16:35 (6205 TTV at 101-105 deg, 19-22 m from the standing harvester, no turn accepted): near a standing
    -- harvester the 120 deg rule is lifted from REVERSED_ANGLE on, the turn then aims the harvester heading itself
    local goalHeading = nil
    if not facing and angle ~= nil and angle >= CatchCombinePipeTask.REVERSED_ANGLE and self:isCombineStanding()
        and AutoDrive.getDistanceBetween(self.vehicle, self.combine) <= CatchCombinePipeTask.WRONG_WAY_RANGE and ADBandTurn.headingOfNode ~= nil then
        facing = true
        if ant ~= nil and (g_time or 0) - ant.t < PathFinderModule.ANTICIPATED_MAX_AGE then
            goalHeading = math.atan2(ant.dx, ant.dz)
        else
            goalHeading = ADBandTurn.headingOfNode(self.combine.ad.ADRootNode or self.combine.components[1].node)
        end
        print(string.format("[AD-DemiTour] %s: bout de rang, ensileuse arretee a %.0f deg de mon cap (regle des %d deg levee), demi-tour vers son cap", tostring(self.vehicle:getName()), angle, CatchCombinePipeTask.END_ROW_UTURN_ANGLE))
    end
    if not facing then
        print(string.format("[AD-DemiTour] %s: bout de rang, pas de demi-tour propre (ecart de cap %.0f deg)", tostring(self.vehicle:getName()), angle or -1))
        return false
    end
    -- harvester (or new row) side: +1 on the right of the tractor, -1 on the left
    local side = (cx - vx) * dz - (cz - vz) * dx >= 0 and 1 or -1
    if not ADBandTurn.start(self.vehicle, string.format("bout de rang, ensileuse a %s, cap ensileuse %.0f deg", side > 0 and "gauche" or "droite", angle or -1), self.combine, side, goalHeading) then
        return false
    end
    if self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.preplanning then
        self.vehicle.ad.pathFinderModule:reset()
        self.preplanning = false
    end
    self.infoEndRowTurn = true -- status text
    self.state = CatchCombinePipeTask.STATE_BAND_TURN
    return true
end

-- aside (25/10 08:03, the 7R beside the standing harvester at 177 deg): beside or in front of it as well, while it stands
function CatchCombinePipeTask:tryReversedUTurn(angleToCombine, aside)
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if not AutoDrive.isChopperUnloading(self.vehicle) or self.combine == nil or mode == nil then
        return false
    end
    local distance = AutoDrive.getDistanceBetween(self.vehicle, self.combine)
    if angleToCombine < CatchCombinePipeTask.REVERSED_ANGLE or distance > CatchCombinePipeTask.REVERSED_RANGE then
        return false
    end
    local behind = self:isBehindChopper()
    local standing = self.combine.ad ~= nil and self.combine.ad.noMovementTimer ~= nil and self.combine.ad.noMovementTimer.elapsedTime > 3000
    if not behind and not (aside and standing) then
        return false
    end
    if self:isCombineReallyTurning() then
        return false
    end
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local last = mode.reversedTurnTried
    if last ~= nil and MathUtil.vector2Length(vx - last.x, vz - last.z) < CatchCombinePipeTask.REVERSED_RETRY_DISTANCE
        and (g_time or 0) - last.t < CatchCombinePipeTask.REVERSED_RETRY_TIME then
        return false
    end
    mode.reversedTurnTried = {x = vx, z = vz, t = g_time or 0}
    print(string.format("[AD-DemiTour] %s: %s l'ensileuse mais a l'envers (%.0f deg, %.0f m), demi-tour : AutoDrive d'abord, puis manoeuvre",
        tostring(self.vehicle:getName()), behind and "derriere" or "a cote de / devant (arretee)", angleToCombine, distance))
    self.vehicle.ad.endRowUTurn = g_time or 0
    mode.reversedTurnRequested = true
    self.state = CatchCombinePipeTask.STATE_FINISHED
    return true
end

-- 25/10 16:35 (no way to get beside the forage harvester): 6205 TTV at 101 deg, 22 m from the standing
-- harvester: no U-turn accepts 100-150 deg and each new route is the same useless piece. From the 2nd time at the same
-- place: band turn toward the harvester heading (the 120 deg rule lifted), else back off along the own track to open the
-- angle; and every time more room for the turn in the next route (turnRoomExtra, PathFinderModule.startRearFallback)
function CatchCombinePipeTask:tryWrongWayTurn(angle)
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if not AutoDrive.isChopperUnloading(self.vehicle) or self.combine == nil or self.combine.components == nil or angle == nil
        or angle < CatchCombinePipeTask.REVERSED_ANGLE then
        return false
    end
    local distance = AutoDrive.getDistanceBetween(self.vehicle, self.combine)
    if distance > CatchCombinePipeTask.WRONG_WAY_RANGE or not self:isCombineStanding() or self:isCombineReallyTurning() then
        return false
    end
    local name = tostring(self.vehicle:getName())
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local now = g_time or 0
    local w = self.vehicle.ad.wrongWay
    if w == nil or MathUtil.vector2Length(vx - w.x, vz - w.z) > CatchCombinePipeTask.WRONG_WAY_RADIUS or now - w.t > CatchCombinePipeTask.WRONG_WAY_FORGET then
        w = {x = vx, z = vz, t = now, n = 0}
        self.vehicle.ad.wrongWay = w
    end
    w.n = w.n + 1
    w.t = now
    self.vehicle.ad.turnRoomExtra = math.min(CatchCombinePipeTask.WRONG_WAY_ROOM_MAX, w.n * CatchCombinePipeTask.WRONG_WAY_ROOM_STEP)
    -- 25/10 19:14: no place behind her (hedge, field border): more room for the aimed point changes nothing, the
    -- turn comes at once
    local pfm = self.vehicle.ad.pathFinderModule
    local noRearPlace = pfm ~= nil and pfm.rearPlaceNone == true
    if w.n < 2 and not noRearPlace then
        print(string.format("[AD-DemiTour] %s: a l'envers pres de l'ensileuse arretee (%.0f deg, %.0f m), 1re fois ici : prochain trajet avec %d m de plus pour tourner", name, angle, distance, self.vehicle.ad.turnRoomExtra))
        return false
    end
    if noRearPlace and w.n < 2 then
        print(string.format("[AD-DemiTour] %s: a l'envers pres de l'ensileuse arretee (%.0f deg, %.0f m) et aucune place derriere elle : demi-tour dans la bande tout de suite", name, angle, distance))
    end
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    local dx, _, dz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local side = (cx - vx) * dz - (cz - vz) * dx >= 0 and 1 or -1
    local goal = nil
    if ADBandTurn.headingOfNode ~= nil then
        goal = ADBandTurn.headingOfNode(self.combine.ad.ADRootNode or self.combine.components[1].node)
    end
    if ADBandTurn.canTry(self.vehicle) and ADBandTurn.start(self.vehicle, string.format("a l'envers pres de l'ensileuse arretee (%.0f deg, %.0f m, %de fois ici)", angle, distance, w.n), self.combine, side, goal) then
        print(string.format("[AD-DemiTour] %s: %de fois a l'envers au meme endroit (%.0f deg, %.0f m de l'ensileuse arretee), demi-tour dans la bande vers son cap (ensileuse a %s), puis trajet avec %d m de plus pour tourner", name, w.n, angle, distance, side > 0 and "gauche" or "droite", self.vehicle.ad.turnRoomExtra))
        if self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.preplanning then
            self.vehicle.ad.pathFinderModule:reset()
            self.preplanning = false
        end
        self.infoEndRowTurn = true -- status text
        self.state = CatchCombinePipeTask.STATE_BAND_TURN
        return true
    end
    -- 25/10 22:34: once per place, as the open back-off (the Puma backed off here 6 times in 5 min)
    local lastOpen = self.vehicle.ad.openReverseDone
    local openAllowed = lastOpen == nil or (g_time or 0) - lastOpen.t >= CatchCombinePipeTask.OPEN_REVERSE_PAUSE
        or MathUtil.vector2Length(vx - lastOpen.x, vz - lastOpen.z) >= CatchCombinePipeTask.OPEN_REVERSE_RADIUS
    if openAllowed and mode ~= nil and mode.track ~= nil and #mode.track >= 3 and mode.getTrackIndexBehind ~= nil then
        local index, walked = mode:getTrackIndexBehind(CatchCombinePipeTask.OPEN_REVERSE_DISTANCE)
        if index ~= nil and walked ~= nil and walked >= CombineUnloaderMode.TRACK_STOP_DISTANCE + 2 and mode:startTrackReverse(self.combine, nil, index) then
            self.vehicle.ad.openReverseDone = {x = vx, z = vz, t = g_time or 0}
            print(string.format("[AD-DemiTour] %s: %de fois a l'envers au meme endroit (%.0f deg, %.0f m), pas de demi-tour de bande possible, recul de %.0f m dans mes traces pour ouvrir l'angle", name, w.n, angle, distance, walked))
            if self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.preplanning then
                self.vehicle.ad.pathFinderModule:reset()
                self.preplanning = false
            end
            self.infoReverse = {blocked = false, distance = walked} -- status text
            self.state = CatchCombinePipeTask.STATE_OPEN_REVERSE
            return true
        end
    end
    print(string.format("[AD-DemiTour] %s: %de fois a l'envers au meme endroit (%.0f deg, %.0f m), ni demi-tour de bande ni recul possible, prochain trajet avec %d m de plus pour tourner", name, w.n, angle, distance, self.vehicle.ad.turnRoomExtra))
    return false
end

-- a short route that ends far from the harvester heading while the train is the wrong way round: the arrival cannot
-- hand over to the chase, the same route comes again (6205 TTV, 15:38:27-15:38:37)
function CatchCombinePipeTask:isUselessShortRoute(wayPoints)
    if wayPoints == nil or #wayPoints < 2 or not AutoDrive.isChopperUnloading(self.vehicle) or self.combine == nil or self.combine.components == nil then
        return false
    end
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    local myAngle = mode:getAngleToCombineHeading()
    local distance = AutoDrive.getDistanceBetween(self.vehicle, self.combine)
    if myAngle < CatchCombinePipeTask.CLOSE_RANGE_ANGLE or distance > CatchCombinePipeTask.WRONG_WAY_RANGE then
        return false
    end
    local length = 0
    for i = 2, #wayPoints do
        length = length + MathUtil.vector2Length(wayPoints[i].x - wayPoints[i - 1].x, wayPoints[i].z - wayPoints[i - 1].z)
    end
    if length > CatchCombinePipeTask.SHORT_ROUTE_LENGTH then
        return false
    end
    local a, b = wayPoints[#wayPoints - 1], wayPoints[#wayPoints]
    local cx, _, cz = AutoDrive.localDirectionToWorld(self.combine, 0, 0, 1, self.combine.ad.ADRootNode)
    local endAngle = math.abs(AutoDrive.angleBetween({x = b.x - a.x, z = b.z - a.z}, {x = cx, z = cz}))
    if endAngle <= CatchCombinePipeTask.SHORT_ROUTE_END_ANGLE then
        return false
    end
    print(string.format("[AD-Fin] %s: trajet de %.0f m (%d points) qui finit a %.0f deg du cap de l'ensileuse (moi a %.0f deg, %.0f m d'elle) : inutile, refuse", tostring(self.vehicle:getName()), length, #wayPoints, endAngle, myAngle, distance))
    return true
end
