-- ============================================================================================================
-- FarmPilot : CatchCombinePipeTaskHandover.lua
-- Complément de CatchCombinePipeTask : quand la poursuite (FollowCombineTask) prend la main au lieu d'un trajet calculé.
-- Départ direct : commun moissonneuse et ensileuse. Tout le reste : ENSILEUSE seulement (la benne roule à côté d'elle
-- en continu) ; pour la moissonneuse les règles d'AutoDrive restent (35 deg, bon côté).
--
-- 1. (commun) Proche et alignée au départ : la poursuite part tout de suite, seulement si la ligne droite vers la place est
--    libre (FollowCombineTask.isChaseLineClear, FollowCombineTaskChaseLine.lua), sinon un trajet est calculé.
-- 2. Déjà à côté de l'ensileuse (côté goulotte, même cap, hors de sa voie, pas devant son nez) : la poursuite directement.
-- 3. Ensileuse proche (CLOSE_RANGE ; CLOSE_RANGE_STANDING si elle est arrêtée et nous dans le cône derrière elle) : pas de
--    trajet calculé, la poursuite prend la main ; seulement dans son sens (CLOSE_RANGE_ANGLE), sinon demi-tour d'abord.
-- 4. Arrivée au bout du trajet : derrière elle sur sa trace (courbes), jusqu'à CHOPPER_HANDOVER_ANGLE, n'importe quel côté
--    dans le cône derrière elle ; sinon attente au demi-tour anticipé, demi-tour, essais au même endroit, attente.
-- 5. Aucun trajet et ensileuse arrêtée : la poursuite prend la main (tryStandingHandover) ; sa ligne droite peut couper
--    une pointe de culture un moment (tryCropTipHandover, CROP_TIP_*).
-- 6. Passages de main au même endroit en peu de temps : la place derrière elle est imposée un moment (noteHandover).
--
-- Historique :
--   23/10       déjà à côté : poursuite directe ; derrière elle sur sa trace en courbe, jamais de face (167 deg) ;
--               demi-tour anticipé : attendre derrière l'entrée du rang ; la poursuite seulement derrière, jamais de côté ;
--   24/10 21:08 à 10 m, la poursuite reprend (CLOSE_RANGE, était 4) ; (sim b) derrière elle mais à l'envers :
--               demi-tour d'abord ;
--   25/10 08:03 le 7R fait son demi-tour avant de reprendre la poursuite (CLOSE_RANGE_ANGLE) ;
--   25/10 11:53 arrivée derrière l'ensileuse arrêtée, de l'autre côté que prévu : le côté ne compte pas dans le cône ;
--   25/10 14:10 MF 7S.210 à 29 m derrière l'ensileuse arrêtée, trajets en boucle 4 min (CLOSE_RANGE_STANDING) ;
--   25/10 16:22 passages de main répétés au même endroit (HANDOVER_LOOP_*) ;
--   25/10 16:35 aucune façon d'aller à côté de l'ensileuse : demi-tour vers son cap, ou recul ;
--   25/10 22:38 en grosse difficulté sur la fourrière, l'angle peut être coupé (CROP_TIP_*) ;
--   30/10       une fois par endroit (tryCropTipHandover).
--
-- Branché par : CatchCombinePipeTask:setUp (isStraightLineFree), :update (checkBesideInPlace et checkCloseRange avant la
-- machine à états ; checkChopperArrival, noteHandover et onArrivalNotHandedOver à l'arrivée en STATE_DRIVING) ;
-- tryStandingHandover par tryNoRouteFallbacks (CatchCombinePipeTaskClear.lua), tryCropTipHandover par tryOpenReverse
-- (CatchCombinePipeTaskChopperRoute.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester (23/10): unloader already beside it (pipe side, same heading, out of its lane, not past
-- its nose): the chase takes over directly, no route, no manoeuvre
CatchCombinePipeTask.BESIDE_ANGLE = 30            -- deg between the unloader and the harvester headings
CatchCombinePipeTask.BESIDE_MAX_LATERAL = 15      -- m from the harvester centre line at most
CatchCombinePipeTask.BESIDE_MAX_BACK = 10         -- m behind the harvester rear at most
CatchCombinePipeTask.CLOSE_RANGE = 10             -- m from the forage harvester: the chase drives, no planned route (24/10 21:08, was 4)
CatchCombinePipeTask.CLOSE_RANGE_ANGLE = 90       -- deg: only in the harvester's direction (25/10 08:03: the 7R, 177 deg, looped 4 min)
CatchCombinePipeTask.CLOSE_RANGE_STANDING = 32    -- m: harvester standing and the unloader in the cone behind it, before any route (25/10 14:10, MF 7S.210 looping 4 min at 29 m)
CatchCombinePipeTask.CLOSE_BLOCKED_TRIES = 3       -- chases given up at the same place before a planned route is allowed
CatchCombinePipeTask.HANDOVER_DISTANCE = 15        -- m from the harvester: the chase takes over when the route cannot align
CatchCombinePipeTask.HANDOVER_TRIES = 2
CatchCombinePipeTask.CHOPPER_HANDOVER_ANGLE = 50  -- deg between unloader and forage harvester headings, behind it
-- forage harvester standing (full, it waits for this unloader) and the unloader in the cone behind it: the chase takes
-- over whatever side was planned, it picks the free side itself (25/10 11:53: the Puma arrived 22 m behind the
-- standing JAGUAR at 35 deg, right of the planned left side, and planned the same point again for ever)
CatchCombinePipeTask.STANDING_HANDOVER_DISTANCE = 30 -- m from the harvester
CatchCombinePipeTask.STANDING_SPEED = 0.0003 -- lastSpeedReal (m/ms) under which the harvester stands
-- 25/10 16:22: hand-overs to the chase at the same place in a short time (the chase gives the place back at once:
-- obstacle on its line): after HANDOVER_LOOP_COUNT the place behind the harvester is forced for HANDOVER_LOOP_REAR_TIME
CatchCombinePipeTask.HANDOVER_LOOP_COUNT = 4
CatchCombinePipeTask.HANDOVER_LOOP_TIME = 30000
CatchCombinePipeTask.HANDOVER_LOOP_RADIUS = 3
CatchCombinePipeTask.HANDOVER_LOOP_REAR_TIME = 60000
-- 25/10 22:38 (in great difficulty on the headland the corner may be cut): no route twice near the
-- standing harvester: the chase takes over and may cut a tip of crop on its straight line for CROP_TIP_TIME
CatchCombinePipeTask.CROP_TIP_DISTANCE = 40  -- m from the standing harvester
CatchCombinePipeTask.CROP_TIP_ANGLE = 100    -- deg off its heading at most (not the wrong way round)
CatchCombinePipeTask.CROP_TIP_TIME = 60000   -- ms

-- ------------------------------------------------------------------------------------------------------------
-- Commun : départ direct (appelée par CatchCombinePipeTask:setUp, machine proche et alignée)
-- ------------------------------------------------------------------------------------------------------------
-- vrai = la ligne droite vers la place est libre, la poursuite part tout de suite
function CatchCombinePipeTask:isStraightLineFree()
    -- close and aligned: chase straight away, but only if the straight line is free, otherwise plan a route
    local chasePos, chaseSide = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getPipeChasePosition()
    local clear, reason = FollowCombineTask.isChaseLineClear(self.vehicle, self.combine, chasePos, chaseSide)
    if not clear then
        print(string.format("[AD-Poursuite] %s: moissonneuse proche mais ligne droite bloquee (%s), recherche de chemin", FollowCombineTask.getLogName(self.vehicle), tostring(reason)))
    end
    return clear
end

-- ------------------------------------------------------------------------------------------------------------
-- Ensileuse : accroches de update avant la machine à états
-- ------------------------------------------------------------------------------------------------------------
-- vrai = update() s'arrête là
function CatchCombinePipeTask:checkBesideInPlace()
    if (self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.state == CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
        or self.state == CatchCombinePipeTask.STATE_DRIVING) and self:isBesideInPlace() then
        if self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.preplanning then
            self.vehicle.ad.pathFinderModule:reset()
            self.preplanning = false
        end
        print(string.format("[AD-Fin] %s: deja a cote de l'ensileuse (%.0f m, angle %.0f deg, bon cote), la poursuite prend la main directement", tostring(self.vehicle:getName()), AutoDrive.getDistanceBetween(self.vehicle, self.combine), self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombineHeading()))
        self:noteHandover()
        self:finished()
        return true
    end
    return false
end

-- vrai = update() s'arrête là (sinon l'état a pu passer à STATE_FINISHED)
function CatchCombinePipeTask:checkCloseRange()
    -- forage harvester close by: no planned route to its pipe (a route that must arrive in its heading loops
    -- around at that range), the chase takes over: strict straight line, wait for it to pass, change side.
    -- Only when the chase gave up several times at the same place, a planned route is allowed again
    -- 25/10 14:10 (MF 7S.210: 29 m behind the standing harvester, aligned, routes to a point 10 m ahead looping
    -- for 4 min): a standing harvester waits for this unloader, the chase takes over from further away
    local closeRange = CatchCombinePipeTask.CLOSE_RANGE
    if self.state ~= CatchCombinePipeTask.STATE_DRIVING and self:isCombineStanding() then
        local _, _, inCone = self:isInRearCone()
        if inCone then
            closeRange = CatchCombinePipeTask.CLOSE_RANGE_STANDING
        end
    end
    if not self.closeRangePlanning and AutoDrive.isChopperUnloading(self.vehicle)
        and (self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.state == CatchCombinePipeTask.STATE_DELAY_PATHPLANNING or self.state == CatchCombinePipeTask.STATE_DRIVING)
        and AutoDrive.getDistanceBetween(self.vehicle, self.combine) < closeRange then
        -- 25/10 08:03 (the 7R must do its U-turn before taking up the chase again): only in
        -- the harvester's direction. The 7R passed the standing harvester the wrong way round (177 deg) at 10 m, the
        -- chase took over and looped 4 min (chase, reverse, new route, chase...). The wrong way round: a route being
        -- driven goes on (it ends behind the harvester); without a route its own U-turn first, then a new route
        local angle = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombineHeading()
        if angle < CatchCombinePipeTask.CLOSE_RANGE_ANGLE then
            print(string.format("[AD-Fin] %s: ensileuse a %.0f m (< %d m%s), pas de trajet calcule, la poursuite prend la main", tostring(self.vehicle:getName()), AutoDrive.getDistanceBetween(self.vehicle, self.combine), closeRange, closeRange ~= CatchCombinePipeTask.CLOSE_RANGE and ", arretee et moi derriere elle" or ""))
            if self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.preplanning then
                self.vehicle.ad.pathFinderModule:reset()
                self.preplanning = false
            end
            self.closeWrongWayLogged = false
            self:noteHandover()
            self.state = CatchCombinePipeTask.STATE_FINISHED
        elseif self.state ~= CatchCombinePipeTask.STATE_DRIVING then
            if angle >= CatchCombinePipeTask.REVERSED_ANGLE and self:tryReversedUTurn(angle, true) then
                return true
            end
            if not self.closeWrongWayLogged then
                self.closeWrongWayLogged = true
                print(string.format("[AD-Fin] %s: a l'envers a %.0f m de l'ensileuse (%.0f deg), pas de poursuite avant mon demi-tour, nouveau trajet", tostring(self.vehicle:getName()), AutoDrive.getDistanceBetween(self.vehicle, self.combine), angle))
            end
        elseif not self.closeWrongWayLogged then
            self.closeWrongWayLogged = true
            print(string.format("[AD-Fin] %s: ensileuse a %.0f m mais a %.0f deg de mon cap, la poursuite ne prend pas la main, je finis mon trajet", tostring(self.vehicle:getName()), AutoDrive.getDistanceBetween(self.vehicle, self.combine), angle))
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Ensileuse : arrivée au bout du trajet (STATE_DRIVING)
-- ------------------------------------------------------------------------------------------------------------
-- rend l'angle et le côté retenus, et l'angle maximal admis
function CatchCombinePipeTask:checkChopperArrival(angleToCombine, isCorrectSide)
    -- forage harvester in a curve (23/10): behind it on its own track and aligned with that track,
    -- the chase takes over even when the harvester itself points elsewhere
    -- not when facing it (23/10: accepted at 167 deg on the previous row's track)
    if angleToCombine >= CatchCombinePipeTask.CHOPPER_HANDOVER_ANGLE and angleToCombine < 90 and AutoDrive.isChopperUnloading(self.vehicle) and self:isBehindChopper() then
        local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
        local tx, tz = PathFinderModule.getTrailDirectionAt(self.combine, vx, vz)
        if tx ~= nil then
            local rx, _, rz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
            local trailAngle = math.abs(AutoDrive.angleBetween({x = rx, z = rz}, {x = tx, z = tz}))
            print(string.format("[AD-Fin] %s: derriere l'ensileuse sur sa trace (%.0f m), angle avec l'ensileuse %.0f deg, avec sa trace %.0f deg, bon cote %s", tostring(self.vehicle:getName()), AutoDrive.getDistanceBetween(self.vehicle, self.combine), angleToCombine, trailAngle, tostring(isCorrectSide)))
            if trailAngle < CatchCombinePipeTask.CHOPPER_HANDOVER_ANGLE then
                angleToCombine = trailAngle
                isCorrectSide = true
            end
        end
    end

    -- forage harvester (23/10): behind it, the chase takes over up to CHOPPER_HANDOVER_ANGLE (curves)
    local maxAngle = AutoDrive.isChopperUnloading(self.vehicle) and CatchCombinePipeTask.CHOPPER_HANDOVER_ANGLE or 35
    -- in the cone behind a forage harvester the planned side does not matter (25/10 11:53)
    isCorrectSide = self:acceptOtherSideBehind(angleToCombine, isCorrectSide, maxAngle)
    return angleToCombine, isCorrectSide, maxAngle
end

-- pas de passage de main : vrai = update() s'arrête là, sinon nouveau calcul comme AutoDrive
function CatchCombinePipeTask:onArrivalNotHandedOver(dt, angleToCombine, isCorrectSide)
    -- anticipated end-of-row U-turn (23/10): in place behind the next row before the harvester,
    -- wait there for it to come in instead of planning again
    local ant = self.vehicle.ad.anticipatedRear
    if ant ~= nil and AutoDrive.isChopperUnloading(self.vehicle) and (g_time or 0) - ant.t < PathFinderModule.ANTICIPATED_MAX_AGE then
        if not self.anticipatedWaitPrinted then
            self.anticipatedWaitPrinted = true
            print(string.format("[AD-Fin] %s: demi-tour anticipe : en place derriere l'entree du rang, j'attends l'ensileuse (angle %.0f deg, %.0f m)", tostring(self.vehicle:getName()), angleToCombine, AutoDrive.getDistanceBetween(self.vehicle, self.combine)))
        end
        self.infoAnticipatedWaitAt = g_time or 0 -- status text
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return true
    end
    -- 24/10 (sim b): behind it but the wrong way round: U-turn now, the AutoDrive one first
    -- (HandleHarvesterTurnTask, end-of-row mode), then the 3/5/7-move manoeuvre
    if self:tryReversedUTurn(angleToCombine, true) then
        return true
    end
    -- 25/10 16:35 (no way to get beside the forage harvester): 6205 TTV at 101 deg, 22 m from
    -- the standing harvester, looping every 1.3 s: from the 2nd arrival at the same place, band turn toward
    -- the harvester heading, else back off, and more room for the turn in the next route
    if self:tryWrongWayTurn(angleToCombine) then
        return true
    end
    if AutoDrive.isChopperUnloading(self.vehicle) then
        print(string.format("[AD-Fin] %s: arrive, pas de poursuite : %.0f m de l'ensileuse, angle %.0f deg, bon cote %s, derriere %s", tostring(self.vehicle:getName()), AutoDrive.getDistanceBetween(self.vehicle, self.combine), angleToCombine, tostring(isCorrectSide), tostring(self:isBehindChopper())))
    end
    -- forage harvester: close to it but unable to hand over (wrong heading or side, face to face):
    -- recalculating gives the same 1-cell route forever. After HANDOVER_TRIES at the same place, the chase
    -- takes over anyway: it waits for the harvester to pass, backs off or changes side (original procedures)
    if AutoDrive.isChopperUnloading(self.vehicle) and AutoDrive.getDistanceBetween(self.vehicle, self.combine) < CatchCombinePipeTask.HANDOVER_DISTANCE then
        local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
        if self.handoverPlace ~= nil and MathUtil.vector2Length(vx - self.handoverPlace.x, vz - self.handoverPlace.z) < 2 then
            self.handoverTries = (self.handoverTries or 0) + 1
        else
            self.handoverPlace = {x = vx, z = vz}
            self.handoverTries = 1
            self.handoverWaitPrinted = false
        end
        if self.handoverTries >= CatchCombinePipeTask.HANDOVER_TRIES and self:tryBandTurn("pres de l'ensileuse sans pouvoir s'aligner") then
            self.handoverPlace = nil
            self.handoverTries = 0
            return true
        end
        if self.handoverTries >= CatchCombinePipeTask.HANDOVER_TRIES and not self.handoverWaitPrinted then
            -- (23/10) the chase takes over only behind the harvester, never from its side (it
            -- drives into the header): wait here, the route behind is planned again
            self.handoverWaitPrinted = true
            print(string.format("[AD-Fin] %s: pres de l'ensileuse (%.0f m) sans pouvoir s'aligner (angle %.0f deg, bon cote %s, derriere %s), pas de poursuite de cote, attente", tostring(self.vehicle:getName()), AutoDrive.getDistanceBetween(self.vehicle, self.combine), angleToCombine, tostring(isCorrectSide), tostring(self:isBehindChopper())))
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Ensileuse : outils
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester: unloader on the pipe side, same heading, outside its lane, level with it (not past its nose)
function CatchCombinePipeTask:isBesideInPlace()
    local combine = self.combine
    if not AutoDrive.isChopperUnloading(self.vehicle) or combine == nil or combine.ad == nil or combine.components == nil then
        return false
    end
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if mode:getAngleToCombineHeading() >= CatchCombinePipeTask.BESIDE_ANGLE or not mode:isUnloaderOnCorrectSide() then
        return false
    end
    local cx, _, cz = getWorldTranslation(combine.components[1].node)
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local rx, rz = self.vehicle.ad.pathFinderModule:getWorkingDirection(combine)
    local along = (vx - cx) * rx + (vz - cz) * rz
    local lateral = math.abs((vx - cx) * rz - (vz - cz) * rx)
    local halfLength = combine.size ~= nil and combine.size.length / 2 or 5
    if along > halfLength or along < -(halfLength + CatchCombinePipeTask.BESIDE_MAX_BACK) then
        return false
    end
    local laneHalf = math.max(AutoDrive.getFrontToolWidth(combine) or 0, combine.size.width) / 2
    local unitHalfWidth = self.vehicle.size ~= nil and self.vehicle.size.width / 2 or 1.5
    return lateral >= laneHalf + unitHalfWidth and lateral <= CatchCombinePipeTask.BESIDE_MAX_LATERAL and not self:isInCombinePath()
end

-- forage harvester: the unloader is behind it (its rear half), not beside or ahead; any other harvester: true
function CatchCombinePipeTask:isBehindChopper()
    if not AutoDrive.isChopperUnloading(self.vehicle) or self.combine == nil or self.combine.components == nil then
        return true
    end
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local rx, rz = self.vehicle.ad.pathFinderModule:getWorkingDirection(self.combine)
    return (vx - cx) * rx + (vz - cz) * rz < 0
end

-- forage harvester standing: full, it waits for this unloader
function CatchCombinePipeTask:isCombineStanding()
    local c = self.combine
    if c == nil then
        return false
    end
    if math.abs(c.lastSpeedReal or 0) < CatchCombinePipeTask.STANDING_SPEED then
        return true
    end
    return c.ad ~= nil and c.ad.noMovementTimer ~= nil and (c.ad.noMovementTimer.elapsedTime or 0) > 1000
end

-- the unloader in the cone behind the forage harvester: behind its rear, no further aside than behind.
-- Returns its lateral and longitudinal offsets (m, harvester frame) and whether it is in the cone
function CatchCombinePipeTask:isInRearCone()
    if self.combine == nil or self.combine.components == nil then
        return 0, 0, false
    end
    local vx, vy, vz = getWorldTranslation(self.vehicle.components[1].node)
    local dx, _, dz = AutoDrive.worldToLocal(self.combine, vx, vy, vz, self.combine.ad ~= nil and self.combine.ad.ADRootNode or nil)
    local rear = (self.combine.size ~= nil and self.combine.size.length or 10) / 2
    return dx, dz, dz < -rear and math.abs(dx) <= -dz
end

-- arrival behind a forage harvester on the other side than the planned one (25/10 11:53: the Puma arrived 22 m
-- behind the standing JAGUAR at 35 deg, right of the planned left side, and planned the same point for ever): in the
-- cone behind it the side does not matter, the chase picks the free side itself (or drives behind it first)
function CatchCombinePipeTask:acceptOtherSideBehind(angleToCombine, isCorrectSide, maxAngle)
    if isCorrectSide or not AutoDrive.isChopperUnloading(self.vehicle) or angleToCombine >= maxAngle then
        return isCorrectSide
    end
    local dx, dz, inCone = self:isInRearCone()
    if not inCone then
        return false
    end
    print(string.format("[AD-Fin] %s: arrive derriere l'ensileuse (%.0f m derriere, %.0f m de cote, angle %.0f deg) de l'autre cote que prevu : la poursuite prend la main et choisit le cote libre", tostring(self.vehicle:getName()), -dz, math.abs(dx), angleToCombine))
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Ensileuse : passages de main
-- ------------------------------------------------------------------------------------------------------------
function CatchCombinePipeTask:noteHandover()
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if mode == nil or not AutoDrive.isChopperUnloading(self.vehicle) then
        return
    end
    local now = g_time or 0
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local h = mode.handoverLoop
    if h == nil or now - h.t0 > CatchCombinePipeTask.HANDOVER_LOOP_TIME or MathUtil.vector2Length(vx - h.x, vz - h.z) > CatchCombinePipeTask.HANDOVER_LOOP_RADIUS then
        mode.handoverLoop = {x = vx, z = vz, t0 = now, n = 1}
        return
    end
    h.n = h.n + 1
    if h.n >= CatchCombinePipeTask.HANDOVER_LOOP_COUNT and mode.isIslandRear ~= nil and not mode:isIslandRear() then
        mode.islandRearUntil = now + CatchCombinePipeTask.HANDOVER_LOOP_REAR_TIME
        print(string.format("[AD-Fin] %s: %d passages de main a la poursuite au meme endroit en %.0f s, la place derriere l'ensileuse est forcee %d s", tostring(self.vehicle:getName()), h.n, (now - h.t0) / 1000, CatchCombinePipeTask.HANDOVER_LOOP_REAR_TIME / 1000))
        mode.handoverLoop = nil
    end
end

-- no route and the forage harvester stands (full, it waits for this unloader), the unloader in the cone behind it less
-- than CHOPPER_HANDOVER_ANGLE off its heading: the chase takes over, a planned route only loops at that range
function CatchCombinePipeTask:tryStandingHandover(why)
    if not AutoDrive.isChopperUnloading(self.vehicle) or not self:isCombineStanding() then
        return false
    end
    local dx, dz, inCone = self:isInRearCone()
    if not inCone then
        return false
    end
    local distance = AutoDrive.getDistanceBetween(self.vehicle, self.combine)
    local angle = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombineHeading()
    if distance > CatchCombinePipeTask.STANDING_HANDOVER_DISTANCE or angle >= CatchCombinePipeTask.CHOPPER_HANDOVER_ANGLE then
        return false
    end
    print(string.format("[AD-Fin] %s: %s, ensileuse arretee et moi derriere elle (%.0f m derriere, %.0f m de cote, angle %.0f deg) : la poursuite prend la main et choisit le cote libre", tostring(self.vehicle:getName()), why, -dz, math.abs(dx), angle))
    self:noteHandover()
    if self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.preplanning then
        self.vehicle.ad.pathFinderModule:reset()
        self.preplanning = false
    end
    self.state = CatchCombinePipeTask.STATE_FINISHED
    return true
end

-- 25/10 22:38 (in great difficulty on the headland the corner may be cut): no route twice
-- from the same place near the standing harvester (its place off the field at a corner, no grid there, no edge to
-- follow): the chase takes over and its straight line may cut a tip of crop for a while, instead of backing off
-- along the track again and again (6 back-offs in 5 min, the trailer in the maize, 21:32-21:37)
function CatchCombinePipeTask:tryCropTipHandover(f)
    if not self:isCombineStanding() or f.cropTipDone then
        return false
    end
    local distance = AutoDrive.getDistanceBetween(self.vehicle, self.combine)
    local angle = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombineHeading()
    if distance > CatchCombinePipeTask.CROP_TIP_DISTANCE or angle >= CatchCombinePipeTask.CROP_TIP_ANGLE then
        return false
    end
    -- 30/10: once per place, the chase gave the train back at once and a new task started it again every 10 s
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local done = self.vehicle.ad.cropTipDoneAt
    if done ~= nil and (g_time or 0) - done.t < CatchCombinePipeTask.CLEAR_BACK_MEMORY
        and MathUtil.vector2Length(vx - done.x, vz - done.z) < CatchCombinePipeTask.OPEN_REVERSE_RADIUS then
        f.cropTipDone = true
        print(string.format("[AD-Fin] %s: poursuite qui coupe la pointe deja essayee d'ici il y a %.0f s, pas une deuxieme fois", tostring(self.vehicle:getName()), ((g_time or 0) - done.t) / 1000))
        return false
    end
    self.vehicle.ad.cropTipDoneAt = {x = vx, z = vz, t = g_time or 0}
    f.cropTipDone = true
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    mode.cropTipUntil = (g_time or 0) + CatchCombinePipeTask.CROP_TIP_TIME
    print(string.format("[AD-Fin] %s: pas de trajet d'ici %d fois pres de l'ensileuse arretee (%.0f m, %.0f deg) : la poursuite prend la main et peut couper une pointe de culture pendant %d s", tostring(self.vehicle:getName()), f.count, distance, angle, CatchCombinePipeTask.CROP_TIP_TIME / 1000))
    self:noteHandover()
    if self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.preplanning then
        self.vehicle.ad.pathFinderModule:reset()
        self.preplanning = false
    end
    self.state = CatchCombinePipeTask.STATE_FINISHED
    return true
end
