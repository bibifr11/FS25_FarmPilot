-- ============================================================================================================
-- FarmPilot : CombineUnloaderModeChopperChase.lua
-- Complément de CombineUnloaderMode:getPipeChasePosition : la place de la benne qui roule à côté de l'ENSILEUSE.
-- Ne concerne pas la moissonneuse (benne sous la goulotte), sauf isSideFruitBlocking qui lui rend le résultat
-- d'origine AutoDrive.
--
-- Historique :
-- - 23/10 : ensileuse en virage vers la benne : la benne roule à son 3/4 arrière pour la laisser tourner, et
--   revient à côté après le virage ; pas de 3/4 arrière pour un demi-tour de bout de rang ; place gardée
--   CURVE_MIN_TIME au moins (elle changeait toutes les 2 s) ;
-- - 24/10 : derrière elle, la benne la poussait : le nez du tracteur à 0,5 m de son arrière ; décrochement du
--   parcours : derrière elle ; 24/10 13:35 : derrière elle avant l'îlot ; 24/10 19:53 : la place du
--   décrochement restait pendant le demi-tour de bout de rang ;
-- - 24/10 (942 arrêté devant du maïs oublié) : contrôle de la culture dans la poursuite ; les capteurs
--   de culture de l'ensileuse ne comptent que la vraie culture ;
-- - 25/10 16:22, mur non anticipé (Puma, 50 passages de main le long du mur) : côté condamné, place
--   rapprochée de l'ensileuse quand un mur, un arbre ou un bâtiment l'occupe ;
-- - 24/10 : benne derrière l'ensileuse mais à l'envers : demi-tour AutoDrive d'abord.
--
-- Branché par : CombineUnloaderMode.lua, getPipeChasePosition (3/4 arrière, côtés bloqués, décrochement/îlot,
-- capteurs de culture), getRearChaseOffsetZ (0,5 m derrière), getNextTask (arrivée à l'envers) ; FollowCombineTask
-- et CatchCombinePipeTask lisent isRearChaseHeld, isIslandRear, blockSide, isSideBlocked, REAR_CHASE_GAP.
-- La lecture du parcours Courseplay est dans CombineUnloaderModeCourseplay.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester in a curve toward the unloader (23/10): the unloader drives at its 3/4 rear, so that the
-- harvester can turn; back beside it once the curve ends. The curve is read on the harvester's own track: lateral
-- offset of its position CURVE_BACK m ago (on the side it turns to)
CombineUnloaderMode.CURVE_BACK = 5
CombineUnloaderMode.CURVE_IN = 1.3 -- m, about 15 deg (24/10: 0.6 took the 3/4 rear on a small kink)
CombineUnloaderMode.CURVE_OUT = 0.2 -- m (about 4-5 deg)
CombineUnloaderMode.CURVE_REAR_GAP = 0 -- m behind the harvester rear (23/10: further back the pipe cannot reach, it stops)
CombineUnloaderMode.CP_TURN_MIN_DEG = 20 -- Courseplay course: bend toward the trailer that starts the 3/4 rear place
CombineUnloaderMode.CP_TURN_MAX_DEG = 70 -- and below this only
CombineUnloaderMode.CP_TURN_WITHIN = 15 -- m ahead of the harvester
CombineUnloaderMode.CP_UTURN_DEG = 150 -- 23/10: a Courseplay U-turn is 90 + 90 deg
CombineUnloaderMode.CP_UTURN_AHEAD = 50 -- m of course read for it
CombineUnloaderMode.CURVE_MIN_TIME = 10000 -- ms the 3/4 rear place is kept at least once taken

-- ------------------------------------------------------------------------------------------------------------
-- Derrière l'ensileuse : nez du tracteur à 0,5 m de son arrière (accroche dans getRearChaseOffsetZ)
-- ------------------------------------------------------------------------------------------------------------
CombineUnloaderMode.REAR_CHASE_GAP = 0.5 -- m (24/10) between the tractor nose and the forage harvester rear when chasing behind
function CombineUnloaderMode:getRearChaseGapOffset(rearChaseOffset)
    -- 24/10: behind it, it often pushed the harvester. The chase place is the tractor root (rear axle),
    -- its nose is further ahead: front of the tractor REAR_CHASE_GAP behind the harvester rear (0.5 m)
    local size = self.vehicle.size or {}
    local front = (size.length or 6) / 2 + (size.lengthOffset or 0)
    local csize = self.combine.size or {}
    local rear = (csize.length or 10) / 2 - (csize.lengthOffset or 0)
    rearChaseOffset = math.min(rearChaseOffset, -(rear + front + CombineUnloaderMode.REAR_CHASE_GAP))
    return rearChaseOffset
end

-- ------------------------------------------------------------------------------------------------------------
-- 3/4 arrière en virage
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:getChopperCurveOffset()
    local trail = self.combine.ad ~= nil and self.combine.ad.chopperTrail or nil
    if trail == nil or #trail < 2 then
        return 0
    end
    local cx, cy, cz = getWorldTranslation(self.combine.components[1].node)
    for i = #trail, 1, -1 do
        local p = trail[i]
        if MathUtil.vector2Length(p.x - cx, p.z - cz) >= CombineUnloaderMode.CURVE_BACK then
            local lx, _, lz = AutoDrive.worldToLocal(self.combine, p.x, cy, p.z, self.combine.ad.ADRootNode)
            if lz < 0 then
                return lx
            end
            return 0
        end
    end
    return 0
end

function CombineUnloaderMode:getChopperCurveSide(side)
    local offset = self:getChopperCurveOffset()
    local toward = offset * side
    local was = self.curveRearSide == side
    -- a turn announced by Courseplay (23/10): 3/4 rear at once, whichever way it turns
    -- no longer from the Courseplay turn flag (23/10: raised often on straight lines, the 3/4 stop slowed the trailer)
    local announced = false
    -- Courseplay drives: its course tells the next bend and its side before the harvester turns
    local cpAngle, cpSide, cpBend = CombineUnloaderMode.getCpTurnAhead(self.combine, 30)
    -- the 3/4 only helps in bends under CP_TURN_MAX_DEG (23/10)
    local tooSharp = cpAngle ~= nil and cpAngle >= CombineUnloaderMode.CP_TURN_MAX_DEG
    local cpTurn = cpAngle ~= nil and not tooSharp and cpAngle >= CombineUnloaderMode.CP_TURN_MIN_DEG and cpSide == side and cpBend ~= nil and cpBend <= CombineUnloaderMode.CP_TURN_WITHIN
    -- end-of-row U-turn (23/10): no 3/4 there, the normal turn handling drives (the 3/4 stop left the trailer 16 m behind)
    local uAngle = CombineUnloaderMode.getCpTurnAhead(self.combine, CombineUnloaderMode.CP_UTURN_AHEAD)
    local uTurn = uAngle ~= nil and uAngle >= CombineUnloaderMode.CP_UTURN_DEG
    local now = (announced and not uTurn) or cpTurn and not uTurn or toward > (was and CombineUnloaderMode.CURVE_OUT or CombineUnloaderMode.CURVE_IN)
    if uTurn or tooSharp or self.vehicle.ad.endRowTurnActive then
        now = false
    end
    -- kept CURVE_MIN_TIME at least (23/10: it switched on and off every 2 s, never reached)
    if was and not now and not uTurn and not tooSharp and not self.vehicle.ad.endRowTurnActive and (g_time or 0) - (self.curveRearStart or 0) < CombineUnloaderMode.CURVE_MIN_TIME then
        now = true
    end
    if now and not was then
        self.curveRearStart = g_time or 0
    end
    if now ~= was then
        print(string.format("[AD-Poursuite] %s: %s", tostring(self.vehicle:getName()),
            now and (cpTurn and string.format("coude de %.0f deg vers la benne a %.0f m sur le parcours Courseplay, benne en 3/4 arriere", cpAngle, cpBend)
                or announced and "virage annonce par Courseplay, benne en 3/4 arriere"
                or string.format("ensileuse en virage vers la benne (%.1f m sur %d m), benne en 3/4 arriere", math.abs(offset), CombineUnloaderMode.CURVE_BACK))
                or (uTurn and string.format("demi-tour de bout de rang (%.0f deg sur le parcours Courseplay), pas de 3/4 arriere", uAngle) or "fin du virage, benne de nouveau a cote")))
        self.curveRearSide = now and side or nil
    end
    return now
end

-- (accroche dans getPipeChasePosition) distances avant/arrière des places de gauche et de droite, et place de
-- gauche prise en 3/4 arrière
function CombineUnloaderMode:getChopperCurvePlaces(planningPhase, sideChaseTermZ)
    local leftZ, rightZ = sideChaseTermZ - 2, sideChaseTermZ - 2
    local curveLeft = false
    if not planningPhase and AutoDrive.isChopperUnloading(self.vehicle) then
        local curveZ = math.min(sideChaseTermZ - 2, -((self.combine.size ~= nil and self.combine.size.length or 10) / 2 + CombineUnloaderMode.CURVE_REAR_GAP))
        local unloaderSide = self:getUnloaderOnSide()
        if unloaderSide == AutoDrive.CHASEPOS_LEFT and self:getChopperCurveSide(AutoDrive.CHASEPOS_LEFT) then
            leftZ = curveZ
            curveLeft = true
        elseif unloaderSide == AutoDrive.CHASEPOS_RIGHT and self:getChopperCurveSide(AutoDrive.CHASEPOS_RIGHT) then
            rightZ = curveZ
        end
    end
    return leftZ, rightZ, curveLeft
end

-- ------------------------------------------------------------------------------------------------------------
-- Décrochement du parcours et îlot : place derrière l'ensileuse
-- ------------------------------------------------------------------------------------------------------------
-- behind the harvester through a jog, kept until the course is straight again
-- 24/10 13:35 (behind it before the island): real crop on the straight line to the side place
CombineUnloaderMode.ISLAND_REAR_TIME = 20000 -- ms behind the harvester
function CombineUnloaderMode:isIslandRear()
    return self.islandRearUntil ~= nil and (g_time or 0) < self.islandRearUntil
end

-- rear place held on purpose (jog or island): standing while the harvester moves past is no stuck chase
function CombineUnloaderMode:isRearChaseHeld()
    return self.jogRearStart ~= nil or self:isIslandRear()
end

function CombineUnloaderMode:updateJogRear()
    local now = g_time or 0
    local name = tostring(self.vehicle:getName())
    -- 24/10 19:53: the jog place stayed on into the end-of-row U-turn, the trailer followed the harvester into
    -- it. A Courseplay U-turn (red point) close ahead or being driven ends it, the end-of-row wait takes over
    local row = CombineUnloaderMode.getCpRowTurn(self.combine)
    local near = FollowCombineTask ~= nil and FollowCombineTask.END_ROW_BEND_WITHIN or 15
    if row ~= nil and row.uTurn and (row.turning or (row.dist ~= nil and row.dist <= near)) then
        if self.jogRearStart ~= nil then
            print(string.format("[AD-Poursuite] %s: decrochement annule, demi-tour de bout de rang Courseplay (%s)", name, tostring(row.why)))
            self.jogRearStart = nil
        end
        return false
    end
    local jog, maxDev, endDev, bendAt = CombineUnloaderMode.isCpJogAhead(self.combine)
    if jog then
        if self.jogRearStart == nil then
            print(string.format("[AD-Poursuite] %s: decrochement sur le parcours Courseplay (ecart %.0f deg a %.0f m, revient a %.0f deg), je passe derriere l'ensileuse", name, maxDev, bendAt, endDev))
            self.jogRearStart = now
        end
        self.jogRearLast = now
        return true
    end
    if self.jogRearStart == nil then
        return false
    end
    local straight = CombineUnloaderMode.getCpCourseShape(self.combine, CombineUnloaderMode.JOG_STRAIGHT_AHEAD)
    if now - self.jogRearStart < CombineUnloaderMode.JOG_MIN_TIME or straight == nil or straight > CombineUnloaderMode.JOG_STRAIGHT_DEG then
        return true
    end
    print(string.format("[AD-Poursuite] %s: decrochement passe, parcours droit devant, retour a cote", name))
    self.jogRearStart = nil
    return false
end

-- (accroche dans getPipeChasePosition, après le virage Courseplay) place derrière gardée exprès
function CombineUnloaderMode:isChopperRearHeld(planningPhase)
    return not planningPhase and AutoDrive.isChopperUnloading(self.vehicle) and AutoDrive:getIsCPActive(self.combine)
        and not self.vehicle.ad.endRowTurnActive and (self:updateJogRear() or self:isIslandRear())
end

-- ------------------------------------------------------------------------------------------------------------
-- Côté bloqué, obstacle fixe à la place
-- ------------------------------------------------------------------------------------------------------------
-- 25/10 16:22 (wall not anticipated, Puma 15:21-15:23: 50 hand-overs along the stone wall): a side place
-- whose straight line or place is taken by a fixed obstacle (wall, tree, building) or a learned blocked zone is
-- condemned for SIDE_BLOCK_TIME: the chase takes the other side or the rear instead of planning the same place again
CombineUnloaderMode.SIDE_BLOCK_TIME = 90000
CombineUnloaderMode.PLACE_CHECK_INTERVAL = 1000 -- ms between two obstacle checks of a place
CombineUnloaderMode.PLACE_CLOSER_STEP = 1.5     -- m closer to the harvester tried when the place is obstructed
CombineUnloaderMode.PLACE_MIN_GAP = 0.4         -- m between the harvester side and the train side at least
function CombineUnloaderMode:blockSide(side, why)
    self.blockedSides = self.blockedSides or {}
    self.blockedSides[side] = {till = (g_time or 0) + CombineUnloaderMode.SIDE_BLOCK_TIME, why = why}
end

function CombineUnloaderMode:isSideBlocked(side)
    local b = self.blockedSides ~= nil and self.blockedSides[side] or nil
    return b ~= nil and (g_time or 0) < b.till
end

-- fixed obstacle in the box the train takes at a place (aligned with the harvester, the trailer behind the tractor)
function CombineUnloaderMode:isPlaceObstructed(pos)
    if pos == nil or self.combine == nil or self.combine.components == nil or FollowCombineTask == nil then
        return false
    end
    local rx, _, rz = AutoDrive.localDirectionToWorld(self.combine, 0, 0, 1, self.combine.ad.ADRootNode)
    local length = math.max(6, AutoDrive.getTractorTrainLength(self.vehicle, true, false))
    local halfWidth = self.vehicle.ad.pathFinderModule:getTrainWidth() / 2 + 0.3
    local height = PathFinderModule.getTrainHeight(self.vehicle) + PathFinderModule.OBSTACLE_HEIGHT_MARGIN
    local angleRad = AutoDrive.normalizeAngle(math.atan2(-rz, rx))
    -- the place is where the tractor stands, the train reaches 3 m ahead of it and the rest behind
    local cx, cz = pos.x - rx * (length / 2 - 3), pos.z - rz * (length / 2 - 3)
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 1, cz)
    local probe = {hits = 0, callback = FollowCombineTask.lineCollisionCallback}
    overlapBox(cx, y + height / 2, cz, 0, angleRad, 0, length / 2, height / 2, halfWidth, "callback", probe, AutoDrive.collisionMaskTerrain, true, true, true, true)
    if probe.hits > 0 then
        return true
    end
    return self.vehicle.ad.pathFinderModule:boxHitsBlockedZone(cx, cz, angleRad, length / 2, halfWidth)
end

-- a side place of a forage harvester: obstructed, it is brought closer to the harvester when that frees it (the spout
-- reaches), else the side counts as blocked. Checked every PLACE_CHECK_INTERVAL. Returns the place, blocked
function CombineUnloaderMode:checkPlaceObstacle(side, pos, blocked, offsetX, offsetZ)
    if blocked or pos == nil or self.combine == nil or self.combine.ad == nil or not self.combine.ad.isChopper then
        return pos, blocked
    end
    local now = g_time or 0
    self.placeCheck = self.placeCheck or {}
    local c = self.placeCheck[side]
    if c == nil or now - c.t >= CombineUnloaderMode.PLACE_CHECK_INTERVAL or c.offsetZ ~= offsetZ then
        c = {t = now, blocked = false, offsetX = nil, offsetZ = offsetZ}
        local name = tostring(self.vehicle:getName())
        local sideName = side == AutoDrive.CHASEPOS_LEFT and "gauche" or "droite"
        if self:isPlaceObstructed(pos) then
            local sign = offsetX >= 0 and 1 or -1
            local minOffset = (self.combine.size ~= nil and self.combine.size.width or 3) / 2 + self.vehicle.ad.pathFinderModule:getTrainWidth() / 2 + CombineUnloaderMode.PLACE_MIN_GAP
            local closer = math.abs(offsetX) - CombineUnloaderMode.PLACE_CLOSER_STEP
            while closer >= minOffset do
                local p = AutoDrive.createWayPointRelativeToVehicle(self.combine, sign * closer, offsetZ)
                if not self:isPlaceObstructed(p) then
                    c.offsetX = sign * closer
                    break
                end
                closer = closer - CombineUnloaderMode.PLACE_CLOSER_STEP
            end
            if c.offsetX ~= nil then
                if self.placeLogged ~= side * 10 + 1 then
                    self.placeLogged = side * 10 + 1
                    print(string.format("[AD-Poursuite] %s: obstacle fixe a la place de %s (%.1f m de l'axe de l'ensileuse), place rapprochee a %.1f m", name, sideName, math.abs(offsetX), math.abs(c.offsetX)))
                end
            else
                c.blocked = true
                if self.placeLogged ~= side * 10 + 2 then
                    self.placeLogged = side * 10 + 2
                    print(string.format("[AD-Poursuite] %s: obstacle fixe a la place de %s de l'ensileuse (mur, arbre ?), meme rapprochee jusqu'a %.1f m de son axe : ce cote est bloque", name, sideName, minOffset))
                end
            end
        elseif self.placeLogged == side * 10 + 1 or self.placeLogged == side * 10 + 2 then
            self.placeLogged = nil
            print(string.format("[AD-Poursuite] %s: la place de %s est de nouveau libre", name, sideName))
        end
        self.placeCheck[side] = c
    end
    if c.blocked then
        return pos, true
    end
    if c.offsetX ~= nil then
        return AutoDrive.createWayPointRelativeToVehicle(self.combine, c.offsetX, offsetZ), false
    end
    return pos, false
end

-- (accroche dans getPipeChasePosition) places de gauche et de droite, et leur blocage
function CombineUnloaderMode:checkChopperPlaces(leftChasePos, leftBlocked, rightChasePos, rightBlocked, sideChaseTermX, leftZ, rightZ)
    -- 25/10 16:22 (wall not anticipated): a side condemned by an obstacle on the chase line (blockSide),
    -- and a wall, tree or building at a side place: the place is brought closer to the harvester when that frees it,
    -- else that side counts as blocked
    if self:isSideBlocked(AutoDrive.CHASEPOS_LEFT) then
        leftBlocked = true
    end
    if self:isSideBlocked(AutoDrive.CHASEPOS_RIGHT) then
        rightBlocked = true
    end
    leftChasePos, leftBlocked = self:checkPlaceObstacle(AutoDrive.CHASEPOS_LEFT, leftChasePos, leftBlocked, sideChaseTermX + self:getPipeSlopeCorrection(), leftZ)
    rightChasePos, rightBlocked = self:checkPlaceObstacle(AutoDrive.CHASEPOS_RIGHT, rightChasePos, rightBlocked, -(sideChaseTermX + self:getPipeSlopeCorrection()), rightZ)
    return leftChasePos, leftBlocked, rightChasePos, rightBlocked
end

-- ------------------------------------------------------------------------------------------------------------
-- Capteurs de culture de l'ensileuse
-- ------------------------------------------------------------------------------------------------------------
-- 24/10, crop control in the chase (942 stopped in front of leftover maize): the
-- harvester's side fruit sensors trip on any plant (more than 10 pixels) and send the place behind the harvester,
-- the trailer beside it then stops. For a forage harvester the crop counts only when it is real crop: not isolated
-- plants or a narrow strip (same rule as the chase line), not on the harvester's own trail
CombineUnloaderMode.SENSOR_CROP_STEP = 1 -- m between the samples read in the sensor box
CombineUnloaderMode.SENSOR_CROP_CACHE = 500 -- ms
function CombineUnloaderMode:isSideFruitBlocking(sensor)
    if sensor == nil or not (AutoDrive.getSetting("avoidFruit", self.vehicle) and sensor:pollInfo()) then
        return false
    end
    if not self.combine.ad.isChopper or sensor.triggerType == ADSensor.TYPE_SWATH then
        return true
    end
    local now = g_time or 0
    self.sensorCropCache = self.sensorCropCache or {}
    local cached = self.sensorCropCache[sensor]
    if cached ~= nil and now >= cached.t and now - cached.t < CombineUnloaderMode.SENSOR_CROP_CACHE then
        return cached.v
    end
    local corners = sensor:getCorners()
    local c1, c2, c3 = corners[1], corners[2], corners[3]
    local ux, uz = c2.x - c1.x, c2.z - c1.z
    local vx, vz = c3.x - c1.x, c3.z - c1.z
    local nu = math.max(1, math.ceil(math.sqrt(ux * ux + uz * uz) / CombineUnloaderMode.SENSOR_CROP_STEP))
    local nv = math.max(1, math.ceil(math.sqrt(vx * vx + vz * vz) / CombineUnloaderMode.SENSOR_CROP_STEP))
    local real, seen = false, false
    for i = 0, nu do
        for j = 0, nv do
            local x, z = c1.x + ux * i / nu + vx * j / nv, c1.z + uz * i / nu + vz * j / nv
            if PathFinderModule.getMapCropRawAt(x, z) ~= 0 then
                seen = true
                if not PathFinderModule.isIsolatedCrop(x, z) and not self:isOnCombineTrail(x, z) then
                    real = true
                    break
                end
            end
        end
        if real then
            break
        end
    end
    self.sensorCropLogged = self.sensorCropLogged or {}
    if real then
        self.sensorCropLogged[sensor] = nil
    elseif not self.sensorCropLogged[sensor] then
        self.sensorCropLogged[sensor] = true
        local sensors = self.combine.ad.sensors or (self.combineRootVehicle ~= nil and self.combineRootVehicle.ad ~= nil and self.combineRootVehicle.ad.sensors) or {}
        local where = "droit"
        if sensor == sensors.leftFrontSensorFruit then
            where = "avant gauche"
        elseif sensor == sensors.rightFrontSensorFruit then
            where = "avant droit"
        elseif sensor == sensors.leftSensorFruit then
            where = "gauche"
        end
        print(string.format("[AD-Poursuite] %s: capteur de culture %s de l'ensileuse : %s, ignore, la place reste a cote", tostring(self.vehicle:getName()),
            where, seen and "plants isoles, bande etroite ou sa trace" or "quelques plants epars"))
    end
    self.sensorCropCache[sensor] = {t = now, v = real}
    return real
end

-- ------------------------------------------------------------------------------------------------------------
-- Benne derrière l'ensileuse mais à l'envers : demi-tour d'abord (accroche dans getNextTask)
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:getReversedTurnTask()
    -- forage harvester, behind it the wrong way round (24/10): AutoDrive U-turn first, its fallbacks after
    self.reversedTurnRequested = nil
    local nextTask = HandleHarvesterTurnTask:new(self.vehicle, self.combine)
    return nextTask
end
