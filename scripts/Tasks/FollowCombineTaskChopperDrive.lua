-- ============================================================================================================
-- FarmPilot : FollowCombineTaskChopperDrive.lua
-- Complément de FollowCombineTask, ENSILEUSE seulement (la benne roule à côté d'elle en continu) : rouler avec elle.
-- (moissonneuse, benne sous la goulotte : voir FollowCombinePipeHold.lua)
--
-- 1. Ne pas s'arrêter : la place passe derrière le tracteur ou trop de côté pendant que l'ensileuse roule : la benne
--    roule moins vite qu'elle, parallèle, jusqu'à ce que la place revienne devant ; derrière elle, elle se rapproche
--    jusqu'à REAR_CHASE_GAP de son arrière. Même contrôle de ligne que la poursuite ; un vrai blocage arrête.
-- 2. Courbe vers nous (CombineUnloaderMode.curveRearSide) : la place 3/4 arrière est derrière le tracteur, il roule
--    moins vite que l'ensileuse en visant devant la place, sans s'arrêter ni reculer.
-- 3. Virage Courseplay de l'ensileuse vers notre côté : la benne prend la place 3/4 arrière de son côté, recule juste
--    ce qu'il faut (jamais dans la culture) ; fin quand l'ensileuse roule de nouveau droit en marche avant, ou tout de
--    suite si elle s'arrête (elle attend la benne) ou si la ligne vers cette place est bloquée.
-- 4. Journal de diagnostic (une ligne par seconde) pendant ses virages et le 3/4 arrière.
--
-- Historique :
--   23/10       3/4 arrière dans les courbes vers nous, sans arrêt ni recul, seulement sous CP_TURN_MAX_DEG ; journal de
--               diagnostic ;
--   24/10       ne pas s'arrêter (942 arrêté 6 s, 40 m avant un décrochement) : rouler au lieu d'attendre ; 11:56
--               décrochement (poteau) : la benne attend derrière exprès ; plants isolés, bande étroite, trace de
--               l'ensileuse derrière la remorque : n'empêchent pas le recul ;
--   27/10 21:17 en se remettant derrière, le départ était un peu tard : se rapprocher à 0,5 m ;
--   27/10 21:21 (7R 350 et ensileuse qui s'attendaient 50 s dans un coin) : la place 3/4 est quittée dès que
--               l'ensileuse s'arrête ou que la ligne vers elle est bloquée, et pas reprise avant la fin de ce virage.
--
-- Branché par : FollowCombineTask:update (logDiagnostic, updateInnerTurn, checkInnerTurn) et
-- FollowCombineTask:followChasePoint (rollInsteadOfWait, driveChopperCurve). isCropBehindTrain sert aussi au recul vers
-- sa place (FollowCombineTaskChopperPlace.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- rouler au lieu d'attendre (rollInsteadOfWait)
FollowCombineTask.ROLL_SLOWER_KMH = 3
FollowCombineTask.ROLL_MIN_KMH = 2
FollowCombineTask.ROLL_MIN_COMBINE_KMH = 4 -- the harvester slower than this is stopping: the tractor stops too
FollowCombineTask.ROLL_AIM_AHEAD = 8 -- m ahead of the tractor along the harvester
FollowCombineTask.ROLL_SIDE_ROOM = 0.5 -- m between the header side and the train side at least
FollowCombineTask.ROLL_CATCH_TIME = 3 -- s: the speed lets the harvester bring a place behind up in about this time
FollowCombineTask.ROLL_CATCH_MAX_KMH = 6 -- km/h faster than the harvester at most while closing up behind it
FollowCombineTask.ROLL_CLOSE_TOLERANCE = 0.5 -- m: closer than this to the REAR_CHASE_GAP place, harvester speed
-- courbe vers nous (driveChopperCurve)
FollowCombineTask.CURVE_SLOWER_KMH = 3
FollowCombineTask.CURVE_MIN_KMH = 2
FollowCombineTask.CURVE_AIM_AHEAD = 8 -- m
-- forage harvester (Courseplay) turning toward the unloader's side: the unloader takes the 3/4 rear place on its side
FollowCombineTask.INNER_TURN_MIN_DEG = 3 -- heading change toward us that starts it (with the Courseplay turn flag)
FollowCombineTask.INNER_TURN_REAR_RATIO = 0.75 -- the place moves back by this part of the harvester length
FollowCombineTask.INNER_TURN_REVERSE_TOLERANCE = 1.5 -- m behind the tractor before it backs up
FollowCombineTask.INNER_TURN_REVERSE_SPEED = 8 -- km/h
FollowCombineTask.INNER_TURN_REAR_CHECK = 4 -- m behind the train free of crop to back up
FollowCombineTask.INNER_TURN_MAX_TIME = 60000
-- 27/10 21:21 (7R 350 and the harvester waiting for each other 50 s in a corner): the 3/4 rear place is left at
-- once when the harvester stands still (it waits for the trailer) or when the line to it is blocked by crop; it is not
-- taken again before the harvester has finished that turn
FollowCombineTask.INNER_TURN_STANDING = 3000 -- ms the harvester stands before the 3/4 place is left
-- journal de diagnostic (logDiagnostic)
FollowCombineTask.DIAG_INTERVAL = 1000

-- ------------------------------------------------------------------------------------------------------------
-- Rouler au lieu d'attendre (appelée par followChasePoint quand il faudrait attendre)
-- ------------------------------------------------------------------------------------------------------------
-- 24/10, no stopping (942 standing 6 s, 40 m before a jog): the place went behind the tractor (behind the
-- harvester or 3/4 rear) or more than 50 deg aside while the forage harvester drives on. The tractor no longer stops
-- and waits: it rolls on slower than the harvester, parallel to it at its present distance aside, until the
-- harvester has brought the place up ahead. Same line check as the chase (islands, bands, trail); a real block stops.
function FollowCombineTask:rollInsteadOfWait(dt)
    if not AutoDrive.isChopperUnloading(self.vehicle) or self.chasePos == nil or self.combineInTurn
        or FollowCombineTask.isCombineReversing(self.combine) then
        return false
    end
    -- a jog in its course (power pole): the tractor waits behind on purpose, as decided (24/10 11:56)
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if mode ~= nil and mode.jogRearStart ~= nil then
        return false
    end
    local combineSpeed = math.abs(self.combine.lastSpeedReal or 0) * 3600
    if combineSpeed < FollowCombineTask.ROLL_MIN_COMBINE_KMH then
        return false
    end
    -- tractor in the harvester frame: beside it (clear of the header) or behind it, never in its lane ahead
    local vx, vy, vz = getWorldTranslation(self.vehicle.components[1].node)
    local ox, _, oz = AutoDrive.worldToLocal(self.combine, vx, vy, vz, self.combine.ad.ADRootNode)
    local combineHalf = math.max(self.combine.size ~= nil and self.combine.size.width or 4, AutoDrive.getFrontToolWidth(self.combine) or 0) / 2
    local trainHalf = (self.vehicle.ad.pathFinderModule ~= nil and self.vehicle.ad.pathFinderModule:getTrainWidth() or 3) / 2
    local combineRear = (self.combine.size ~= nil and self.combine.size.length or 10) / 2 - (self.combine.size ~= nil and self.combine.size.lengthOffset or 0)
    local tractorFront = (self.vehicle.size ~= nil and self.vehicle.size.length or 6) / 2 + (self.vehicle.size ~= nil and self.vehicle.size.lengthOffset or 0)
    local beside = math.abs(ox) >= combineHalf + trainHalf + FollowCombineTask.ROLL_SIDE_ROOM
    local behind = oz + tractorFront < -combineRear
    if not beside and not behind then
        return false
    end
    -- 27/10 21:17 (getting back behind, it left a bit late, it must close up to 0.5 m):
    -- behind the harvester the tractor closes up until its nose is REAR_CHASE_GAP behind the harvester rear
    local rearGap = CombineUnloaderMode ~= nil and CombineUnloaderMode.REAR_CHASE_GAP or 0.5
    local closeTo = -(combineRear + tractorFront + rearGap)
    local behindHarvester = (not beside) and behind
    local catchUp = behindHarvester and oz < closeTo - FollowCombineTask.ROLL_CLOSE_TOLERANCE
    local ax, ay, az = AutoDrive.localToWorld(self.combine, ox, 0, oz + FollowCombineTask.ROLL_AIM_AHEAD, self.combine.ad.ADRootNode)
    local aim = {x = ax, y = ay, z = az}
    self.rollCheckTimer = (self.rollCheckTimer or 0) - dt
    if self.rollCheckTimer < 0 then
        self.rollCheckTimer = FollowCombineTask.LINE_CHECK_INTERVAL
        local clear, reason = FollowCombineTask.isChaseLineClear(self.vehicle, self.combine, aim, self.chaseSide)
        if not clear and self.rollClear ~= false then
            print(string.format("[AD-Poursuite] %s: place derriere moi, je roulerais a cote de l'ensileuse mais la ligne est bloquee (%s), arret", FollowCombineTask.getLogName(self.vehicle), tostring(reason)))
        end
        self.rollClear = clear
    end
    if not self.rollClear then
        return false
    end
    -- slower the further the place is behind (18:38: 3 km/h slower only, the place 8 m behind never came up):
    -- the harvester brings it up in about ROLL_CATCH_TIME, never faster than the harvester minus ROLL_SLOWER_KMH
    local _, _, lz = AutoDrive.worldToLocal(self.vehicle, self.chasePos.x, self.chasePos.y or 0, self.chasePos.z)
    local behind = math.max(0, -lz)
    local speed = math.max(math.min(combineSpeed - FollowCombineTask.ROLL_SLOWER_KMH, combineSpeed - behind / FollowCombineTask.ROLL_CATCH_TIME * 3.6), FollowCombineTask.ROLL_MIN_KMH)
    if catchUp then
        -- faster than the harvester while the gap is open, its speed once the nose is REAR_CHASE_GAP behind
        local gap = closeTo - oz
        speed = combineSpeed + math.min(FollowCombineTask.ROLL_CATCH_MAX_KMH, gap / FollowCombineTask.ROLL_CATCH_TIME * 3.6)
        if not self.rollCloseLogged then
            self.rollCloseLogged = true
            print(string.format("[AD-Poursuite] %s: derriere l'ensileuse a %.1f m de son arriere, je me rapproche a %.1f m (%.0f km/h, elle %.0f km/h)",
                FollowCombineTask.getLogName(self.vehicle), -(oz + tractorFront + combineRear), rearGap, speed, combineSpeed))
        end
    elseif behindHarvester then
        -- closed up: the harvester's speed, the gap stays
        speed = combineSpeed
    end
    if not catchUp then
        self.rollCloseLogged = false
    end
    if not self.rollLogged then
        self.rollLogged = true
        print(string.format("[AD-Poursuite] %s: place %s (%.0f m, %.0f deg), je ne m'arrete pas : je roule a %.0f km/h %s l'ensileuse jusqu'a ce qu'elle revienne devant",
            FollowCombineTask.getLogName(self.vehicle), lz < -1 and "derriere moi" or "trop de cote", lz, self:getAngleToChasePos(), speed, beside and "a cote de" or "derriere"))
    end
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, aim, speed, false, 1, speed, true)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Courbe vers nous : rouler moins vite qu'elle (appelée par followChasePoint, juste avant driveToPoint)
-- ------------------------------------------------------------------------------------------------------------
-- vrai = déjà conduit, followChasePoint s'arrête là
function FollowCombineTask:driveChopperCurve(dt, combineSpeed, acc)
    -- (la poursuite roule vers sa place : fin de « rouler au lieu d'attendre »)
    self.rollLogged = nil
    self.rollingNow = false
    -- forage harvester in a curve toward us: the 3/4 rear place lies behind the tractor, it stops and lets the
    -- harvester move on (23/10), no reversing
    local unloadMode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    -- (not while it stands: it may be waiting for this trailer under its pipe)
    local combineStands = self.combine.ad.noMovementTimer ~= nil and self.combine.ad.noMovementTimer.elapsedTime > 3000
    if AutoDrive.isChopperUnloading(self.vehicle) and unloadMode.curveRearSide ~= nil and self.chasePos ~= nil and not combineStands then
        local _, _, lz = AutoDrive.worldToLocal(self.vehicle, self.chasePos.x, self.chasePos.y or 0, self.chasePos.z)
        if lz < -1 then
            -- no stop any more (23/10): it drives on slower than the harvester, aiming its line ahead of
            -- the place, until the harvester has brought the place up beside it
            local slow = math.max(combineSpeed - FollowCombineTask.CURVE_SLOWER_KMH, FollowCombineTask.CURVE_MIN_KMH)
            if not self.curveWaitLogged then
                self.curveWaitLogged = true
                print(string.format("[AD-Poursuite] %s: 3/4 arriere : place %.0f m derriere, ralenti a %.0f km/h, l'ensileuse avance", FollowCombineTask.getLogName(self.vehicle), -lz, slow))
            end
            local fx, _, fz = AutoDrive.localDirectionToWorld(self.combine, 0, 0, 1)
            local ahead = -lz + FollowCombineTask.CURVE_AIM_AHEAD
            local aim = {x = self.chasePos.x + fx * ahead, y = self.chasePos.y, z = self.chasePos.z + fz * ahead}
            self.vehicle.ad.specialDrivingModule:driveToPoint(dt, aim, slow, false, acc, slow)
            return true
        end
    end
    self.curveWaitLogged = false
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Place 3/4 arrière dans ses virages
-- ------------------------------------------------------------------------------------------------------------
-- appelée par update() ; vrai = update() s'arrête là
function FollowCombineTask:checkInnerTurn(dt)
    if self.innerTurn and (self.state == FollowCombineTask.STATE_CHASING or self.state == FollowCombineTask.STATE_WAIT_FOR_TURN) then
        self:driveInnerTurn(dt)
        return true
    end
    return false
end

-- forage harvester driven by Courseplay turning toward our side: we are inside its turn. Instead of staying beside
-- the cab (it comes at us) the unloader takes the 3/4 rear place on its side, backing up only as much as needed.
-- Ends when the harvester drives forward again on a steady heading. Outside of its turn nothing changes.
function FollowCombineTask:updateInnerTurn(dt)
    local combine = self.combine
    local usable = AutoDrive.isChopperUnloading(self.vehicle) and combine.ad.isChopper and combine.ad.isAutoAimingChopper
        and not combine.ad.isFixedPipeChopper and AutoDrive:getIsCPActive(combine) and not self.filled
    if not usable then
        if self.innerTurn then
            self:endInnerTurn("plus applicable")
        end
        return
    end
    local samples = self.turnHeadingSamples
    if #samples < 2 then
        return
    end
    local h = math.rad(FollowCombineTask.getCombineHeading(combine))
    local h0 = math.rad(samples[1])
    local fx, fz = math.sin(h), math.cos(h)
    local diff = math.deg(math.abs(AutoDrive.normalizeAngle(h - h0)))
    if diff > 180 then
        diff = 360 - diff
    end
    if self.innerTurn then
        self.innerTurnTime = self.innerTurnTime + dt
        local timer = combine.ad ~= nil and combine.ad.noMovementTimer or nil
        if timer ~= nil and timer.elapsedTime ~= nil and timer.elapsedTime > FollowCombineTask.INNER_TURN_STANDING then
            self.innerTurnBanned = true
            self:endInnerTurn(string.format("ensileuse arretee depuis %.0f s, elle m'attend : retour a ma place normale", timer.elapsedTime / 1000))
            return
        end
        local steady = #samples > FollowCombineTask.TURN_HEADING_SAMPLE_TIME / 500 and diff <= FollowCombineTask.TURN_END_MAX_HEADING_CHANGE
        local forward = combine.ad.driveForwardTimer.elapsedTime >= FollowCombineTask.TURN_END_FORWARD_TIME
        if steady and forward and not AutoDrive:getIsCPTurning(combine) then
            self:endInnerTurn("ensileuse realignee et en marche avant, retour au point normal")
        elseif self.innerTurnTime > FollowCombineTask.INNER_TURN_MAX_TIME then
            self:endInnerTurn("trop long, retour au comportement normal")
        end
        return
    end
    local turning = self.combineInTurn or AutoDrive:getIsCPTurning(combine)
    if not turning then
        self.innerTurnBanned = nil
    end
    if self.innerTurnBanned or self.endRowTurn ~= nil or not turning or diff < FollowCombineTask.INNER_TURN_MIN_DEG then
        return
    end
    -- 3/4 only in bends under CP_TURN_MAX_DEG (23/10)
    local cpAngle = CombineUnloaderMode.getCpTurnAhead(combine, 30)
    if cpAngle ~= nil and cpAngle >= CombineUnloaderMode.CP_TURN_MAX_DEG then
        return
    end
    -- our side of the harvester and the way it turns, both as 2D cross products (same sign = toward us)
    local cx, _, cz = getWorldTranslation(combine.components[1].node)
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local dx, dz = vx - cx, vz - cz
    local along = dx * fx + dz * fz
    local lateral = fx * dz - fz * dx
    local turn = math.sin(h0) * fz - math.cos(h0) * fx
    local halfWidth = (combine.size ~= nil and combine.size.width or 4) / 2
    local length = combine.size ~= nil and combine.size.length or 8
    if math.abs(lateral) < halfWidth or along < -length or lateral * turn <= 0 then
        return
    end
    self.innerTurn = true
    self.innerTurnTime = 0
    self.innerTurnReverseLogged = false
    self.innerTurnCropLogged = false
    print(string.format("[AD-Poursuite] %s: virage de l'ensileuse vers nous (%.0f deg), placement 3/4 arriere de notre cote", FollowCombineTask.getLogName(self.vehicle), diff))
end

function FollowCombineTask:endInnerTurn(reason)
    self.innerTurn = false
    self.angleWrongTimer:timer(false)
    self.lineClear = true
    self.lineBlockedTimer:timer(false)
    print(string.format("[AD-Poursuite] %s: fin du placement 3/4 arriere (%s)", FollowCombineTask.getLogName(self.vehicle), reason))
end

-- 3/4 rear place on our side: the usual side place moved back by INNER_TURN_REAR_RATIO of the harvester length
function FollowCombineTask:getInnerTurnPoint()
    local combine = self.combine
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    local h = math.rad(FollowCombineTask.getCombineHeading(combine))
    local fx, fz = math.sin(h), math.cos(h)
    local cx, cy, cz = getWorldTranslation(combine.components[1].node)
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local dx, dz = vx - cx, vz - cz
    local along = dx * fx + dz * fz
    local ux, uz = dx - fx * along, dz - fz * along
    local ul = math.sqrt(ux * ux + uz * uz)
    if ul < 0.1 then
        return nil
    end
    ux, uz = ux / ul, uz / ul
    local length = combine.size ~= nil and combine.size.length or 8
    local side = mode:getSideChaseOffsetX()
    local back = mode:getSideChaseOffsetZ(AutoDrive.dynamicChaseDistance or combine.ad.isHarvester) - 2 - length * FollowCombineTask.INNER_TURN_REAR_RATIO
    local x, z = cx + fx * back + ux * side, cz + fz * back + uz * side
    return {x = x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, cy, z), z = z}
end

function FollowCombineTask:driveInnerTurn(dt)
    local point = self:getInnerTurnPoint()
    if point == nil then
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return
    end
    self.chasePos = point
    local _, _, diffZ = AutoDrive.worldToLocal(self.vehicle, point.x, point.y, point.z)
    if diffZ < -FollowCombineTask.INNER_TURN_REVERSE_TOLERANCE then
        -- the place is behind: back up just as much as needed, never into the crop
        if self:isCropBehindTrain() then
            if not self.innerTurnCropLogged then
                self.innerTurnCropLogged = true
                print(string.format("[AD-Poursuite] %s: 3/4 arriere : culture derriere la remorque, arret sur place", FollowCombineTask.getLogName(self.vehicle)))
            end
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
            return
        end
        if not self.innerTurnReverseLogged then
            self.innerTurnReverseLogged = true
            print(string.format("[AD-Poursuite] %s: 3/4 arriere : place %.0f m derriere, recul", FollowCombineTask.getLogName(self.vehicle), -diffZ))
        end
        self.vehicle.ad.specialDrivingModule:driveReverse(dt, FollowCombineTask.INNER_TURN_REVERSE_SPEED, 1, self.vehicle.ad.trailerModule:canBeHandledInReverse())
        return
    end
    self.innerTurnReverseLogged = false
    -- forward: same line check as the chase, a blocked line only stops the unloader here
    self.lineCheckTimer = self.lineCheckTimer - dt
    if self.lineCheckTimer < 0 then
        self.lineCheckTimer = FollowCombineTask.LINE_CHECK_INTERVAL
        local clear, reason = FollowCombineTask.isChaseLineClear(self.vehicle, self.combine, point, self.chaseSide)
        if not clear then
            -- 27/10 21:21: no stop on a blocked 3/4 line (the harvester then waits for us): back to the usual place
            self.innerTurnBanned = true
            self:endInnerTurn(string.format("ligne vers la place 3/4 bloquee (%s), pas d'arret, retour a ma place normale", tostring(reason)))
            return
        end
        self.lineClear = clear
    end
    if not self.lineClear then
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return
    end
    local combineSpeed = self.combine.lastSpeedReal * 3600
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, point, combineSpeed, false, 1, math.max(combineSpeed + 10, 8))
end

-- ------------------------------------------------------------------------------------------------------------
-- Outils : culture derrière la remorque
-- ------------------------------------------------------------------------------------------------------------
-- standing crop just behind the train (the strip it would back into)
function FollowCombineTask:isCropBehindTrain()
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local rx, _, rz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local trainLength = math.max(AutoDrive.getTractorTrainLength(self.vehicle, true, false), 8)
    local half = self.vehicle.ad.pathFinderModule:getTrainWidth() / 2
    local sx, sz = -rz * half, rx * half
    local ax, az = vx - rx * trainLength, vz - rz * trainLength
    local bx, bz = ax - rx * FollowCombineTask.INNER_TURN_REAR_CHECK, az - rz * FollowCombineTask.INNER_TURN_REAR_CHECK
    for _, fruitType in pairs(g_fruitTypeManager:getFruitTypes()) do
        if fruitType.index ~= FruitType.MEADOW and fruitType.index ~= FruitType.GRASS then
            local ratio = PathFinderModule.getFruitRatio(fruitType.index, ax + sx, az + sz, bx + sx, bz + sz, ax - sx, az - sz)
            if ratio > FollowCombineTask.STRICT_LINE_FRUIT_RATIO then
                -- 24/10: isolated plants, a narrow strip or the harvester's trail do not stop it (same rule
                -- as the chase line)
                if FollowCombineTask.isOnlyIgnoredCropIn(self.vehicle, ax + sx, az + sz, bx + sx, bz + sz, ax - sx, az - sz) then
                    if not self.innerTurnIslandLogged then
                        self.innerTurnIslandLogged = true
                        print(string.format("[AD-Poursuite] %s: 3/4 arriere : plants isoles ou bande derriere la remorque, ignores", FollowCombineTask.getLogName(self.vehicle)))
                    end
                else
                    return true
                end
            end
        end
    end
    return false
end

-- crop in the parallelogram only made of isolated plants, narrow strips or crop on the harvester's own trail
-- (24/10: none of them stops the chase)
function FollowCombineTask.isOnlyIgnoredCropIn(vehicle, c1X, c1Z, c2X, c2Z, c3X, c3Z)
    local unloadMode = vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    local ux, uz = c2X - c1X, c2Z - c1Z
    local vx, vz = c3X - c1X, c3Z - c1Z
    local nu = math.max(1, math.ceil(math.sqrt(ux * ux + uz * uz) / PathFinderModule.ISLAND_SAMPLE))
    local nv = math.max(1, math.ceil(math.sqrt(vx * vx + vz * vz) / PathFinderModule.ISLAND_SAMPLE))
    for i = 0, nu do
        for j = 0, nv do
            local x, z = c1X + ux * i / nu + vx * j / nv, c1Z + uz * i / nu + vz * j / nv
            if PathFinderModule.getMapCropRawAt(x, z) ~= 0 and not PathFinderModule.isIsolatedCrop(x, z)
                and not (unloadMode ~= nil and unloadMode.isOnCombineTrail ~= nil and unloadMode:isOnCombineTrail(x, z)) then
                return false
            end
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Journal de diagnostic
-- ------------------------------------------------------------------------------------------------------------
-- diagnostic (23/10): once a second while the forage harvester turns or the 3/4 rear place is used
function FollowCombineTask:logDiagnostic(dt)
    if not AutoDrive.isChopperUnloading(self.vehicle) then
        return
    end
    local unloadMode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    local cpAngle, cpSide, cpBend = CombineUnloaderMode.getCpTurnAhead(self.combine, 30)
    local active = unloadMode.curveRearSide ~= nil or self.combineInTurn or self.innerTurn or AutoDrive.combineIsTurning(self.combine)
        or (cpAngle ~= nil and cpAngle >= 20)
    if not active then
        self.diagTimer = 0
        return
    end
    self.diagTimer = (self.diagTimer or 0) - dt
    if self.diagTimer > 0 then
        return
    end
    self.diagTimer = FollowCombineTask.DIAG_INTERVAL
    local names = {}
    for k, v in pairs(FollowCombineTask) do
        if type(k) == "string" and k:sub(1, 6) == "STATE_" and type(v) == "table" then
            names[v] = k:sub(7)
        end
    end
    local lx, lz = 0, 0
    if self.chasePos ~= nil then
        lx, _, lz = AutoDrive.worldToLocal(self.vehicle, self.chasePos.x, self.chasePos.y or 0, self.chasePos.z)
    end
    local vx, vy, vz = getWorldTranslation(self.vehicle.components[1].node)
    local ox, _, oz = AutoDrive.worldToLocal(self.combine, vx, vy, vz, self.combine.ad.ADRootNode)
    local speed = (self.vehicle.lastSpeedReal or 0) * 3600
    local cSpeed = (self.combine.lastSpeedReal or 0) * 3600
    print(string.format("[AD-Diag] %s: etat %s, place visee %.1f m devant / %.1f m a gauche du tracteur, tracteur %.1f m devant / %.1f m a gauche de l'ensileuse, %.0f m, angle %.0f deg, vitesse %.1f / ensileuse %.1f km/h, 3/4 %s, virage CP %s (latche %s, interieur %s), parcours CP sur 30 m : %s",
        FollowCombineTask.getLogName(self.vehicle), tostring(names[self.state]), lz, lx, oz, ox, self.distanceToCombine or -1, self.angleToCombineHeading or -1, speed, cSpeed,
        tostring(unloadMode.curveRearSide), tostring(AutoDrive.combineIsTurning(self.combine)), tostring(self.combineInTurn), tostring(self.innerTurn),
        cpAngle ~= nil and string.format("%.0f deg vers la %s, premier coude a %s m", cpAngle, cpSide == 1 and "gauche" or "droite", cpBend ~= nil and string.format("%.0f", cpBend) or "-") or "inconnu"))
end
