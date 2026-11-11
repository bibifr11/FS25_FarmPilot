-- ============================================================================================================
-- FarmPilot : HandleHarvesterTurnTaskReverseToPipe.lua
-- Complément de HandleHarvesterTurnTask : après le demi-tour de bout de rang, la benne attend que l'ENSILEUSE ait
-- fini son virage, puis recule à côté d'elle jusqu'à sa goulotte (benne qui roule à côté). Ne concerne pas la
-- moissonneuse.
--
-- Historique :
-- - 23/10 22:55 : après le demi-tour, ensileuse derrière dans le même sens : recul droit jusqu'à sa goulotte ;
--   23/10 23:03 : la diagonale vers la goulotte coupait le bord de la culture, recul droit sur son axe ;
-- - 24/10 07:42 : recul aligné sur l'ensileuse avec les outils AutoDrive (points de recul suivis par le module
--   de conduite), parallèle à elle à la distance de la goulotte, un S doux au début reprend l'écart de côté ;
-- - 24/10 09:15 : arrêté 27 m trop tôt : bloqué, il s'arrête là et attend que l'ensileuse arrive à côté ;
-- - 24/10 17:53 : le système original d'AutoDrive pour reculer parallèle à côté d'elle ; la culture ne compte
--   pas pour ce recul (le champ, si) ; 24/10 18:01, recul abandonné : le recul attend la fin du virage
--   de l'ensileuse, garde la place du côté de départ, finit seulement à côté d'elle et repart si elle tourne
--   encore ; 24/10 18:50, il ne reculait pas : chemin en marche arrière dès le 1er point ; 24/10 19:29
--   (encore trop près) : ligne du recul = trace Courseplay du nouveau rang décalée de la demi-coupe + 1 m ;
-- - 25/10 14:21 : recul droit seulement s'il finit vraiment à la goulotte (6205 TTV : 43 m avec 55 m d'écart).
--
-- Branché par des lignes dans HandleHarvesterTurnTask.lua : update (fin du demi-tour en bout de rang :
-- startWaitCombineTurn ; états STATE_WAIT_COMBINE_TURN et STATE_REVERSE_TO_PIPE).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- end of row (23/10 22:55): after the U-turn, harvester behind on the same heading: straight back to its pipe
HandleHarvesterTurnTask.STATE_REVERSE_TO_PIPE = 12
HandleHarvesterTurnTask.PIPE_REVERSE_ANGLE = 30 -- deg between tractor and harvester headings
HandleHarvesterTurnTask.PIPE_REVERSE_RANGE = 90 -- m
HandleHarvesterTurnTask.PIPE_REVERSE_TIME = 90000
HandleHarvesterTurnTask.PIPE_REVERSE_BLOCKED = 6000
HandleHarvesterTurnTask.PIPE_REVERSE_SPEED = 12
HandleHarvesterTurnTask.PIPE_WAIT_TIME = 60000 -- ms waiting for the harvester where the reverse stopped
HandleHarvesterTurnTask.PIPE_REVERSE_WIDTH = 0.7 -- share of the axle width checked on the straight line back
-- 24/10 18:01 (reverse given up): started while the harvester was still turning (aligned for a moment),
-- its pipe place then jumped to its other side and the reverse ended 56 m short. The reverse waits for the end of
-- the harvester's turn, keeps the place on its starting side, ends only beside it, and starts again if the
-- harvester turns once more
HandleHarvesterTurnTask.STATE_WAIT_COMBINE_TURN = 13
HandleHarvesterTurnTask.TURN_WAIT_MAX = 60000 -- ms waiting for the end of the harvester's turn
HandleHarvesterTurnTask.TURN_STEADY_TIME = 2000 -- ms of steady heading (and no Courseplay turn) = turn finished
HandleHarvesterTurnTask.TURN_STEADY_DEG = 4
HandleHarvesterTurnTask.PIPE_BESIDE_GAP = 6 -- m aside at most to count as beside the pipe place
HandleHarvesterTurnTask.PIPE_REVERSE_TURNED = 20 -- deg the harvester turns during the reverse: stop and plan again
HandleHarvesterTurnTask.PIPE_REVERSE_RESTARTS = 3

HandleHarvesterTurnTask.STRAIGHT_BACK_MAX_SIDE = 6 -- m beside the pipe at the end of a straight reverse at most (25/10 14:21)
HandleHarvesterTurnTask.STRAIGHT_BACK_MAX_DISTANCE = 45 -- m straight back at most
HandleHarvesterTurnTask.ALIGNED_S_MIN = 12 -- m of reverse to take up the side gap
HandleHarvesterTurnTask.ALIGNED_S_MAX = 25
HandleHarvesterTurnTask.ALIGNED_S_PER_M = 3 -- m of reverse per m of side gap
HandleHarvesterTurnTask.ALIGNED_MAX_GAP = 12

-- 24/10 19:29 (still too close): the reverse line is the Courseplay course of the new row, offset by
-- half the header width + REVERSE_HEADER_GAP up to the side edge of the train. It was taken from the harvester itself,
-- still finishing its turn: the train ended in front of the header tip and the harvester stopped
HandleHarvesterTurnTask.REVERSE_HEADER_GAP = 1 -- m between the header tip line and the side edge of the train
HandleHarvesterTurnTask.ROW_LINE_AHEAD = 80 -- m of Courseplay course read from its current waypoint
HandleHarvesterTurnTask.ROW_LINE_DEG = 6 -- deg from the row heading for a course segment to belong to the row
HandleHarvesterTurnTask.ROW_LINE_MIN = 10 -- m of straight course at least
HandleHarvesterTurnTask.ROW_LINE_BEHIND = 30 -- m: the harvester stands at most this far from the ends of the line read
-- the reverse goes on until the tractor stands at the pipe place (the trailer under the pipe): the waypoints are
-- followed by the trailer wheels, the last one is reached 3 m early
HandleHarvesterTurnTask.REVERSE_END_PAST = 2 -- m

-- ------------------------------------------------------------------------------------------------------------
-- Place à la goulotte et cap de l'ensileuse
-- ------------------------------------------------------------------------------------------------------------
-- pipe place in the world: during the reverse on the side it started on (the side choice of the chase can jump
-- to the other side while the harvester pivots), else the chase place
function HandleHarvesterTurnTask:getPipePlace()
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or mode.getPipeChasePosition == nil or mode.combine == nil then
        return nil
    end
    if self.pipeSide ~= nil and mode.getSideChaseOffsetX ~= nil then
        local x = self.pipeSide * (mode:getSideChaseOffsetX() + mode:getPipeSlopeCorrection())
        local z = mode:getSideChaseOffsetZ(AutoDrive.dynamicChaseDistance or self.combine.ad.isHarvester) - 2
        return AutoDrive.createWayPointRelativeToVehicle(self.combine, x, z)
    end
    return mode:getPipeChasePosition()
end

function HandleHarvesterTurnTask:getCombineHeadingDeg()
    local dx, _, dz = AutoDrive.localDirectionToWorld(self.combine, 0, 0, 1)
    return math.deg(math.atan2(dx, dz))
end

function HandleHarvesterTurnTask.headingDiff(a, b)
    local d = math.abs(a - b) % 360
    if d > 180 then
        d = 360 - d
    end
    return d
end

-- ------------------------------------------------------------------------------------------------------------
-- Attente de la fin de son virage
-- ------------------------------------------------------------------------------------------------------------
function HandleHarvesterTurnTask:startWaitCombineTurn()
    self.turnWait = {time = 0, steady = 0, heading = self:getCombineHeadingDeg(), sample = 0, logged = false}
    self.state = HandleHarvesterTurnTask.STATE_WAIT_COMBINE_TURN
end

-- stands where the U-turn ended until the harvester has finished its own turn, then the reverse beside it
function HandleHarvesterTurnTask:updateWaitCombineTurn(dt)
    local w = self.turnWait
    local name = tostring(self.vehicle:getName())
    w.time = w.time + dt
    w.sample = w.sample + dt
    if w.sample >= 500 then
        w.sample = 0
        -- 24/10 19:29: steady over the whole window (4 deg per half second let a harvester still turning pass)
        local h = self:getCombineHeadingDeg()
        if HandleHarvesterTurnTask.headingDiff(h, w.heading) <= HandleHarvesterTurnTask.TURN_STEADY_DEG then
            w.steady = w.steady + 500
        else
            w.steady = 0
            w.heading = h
        end
    end
    -- the Courseplay turn flag is also raised on straight lines (seen 24/10): with it, a longer steady heading
    local need = AutoDrive:getIsCPTurning(self.combine) and 2 * HandleHarvesterTurnTask.TURN_STEADY_TIME or HandleHarvesterTurnTask.TURN_STEADY_TIME
    if w.steady >= need or w.time > HandleHarvesterTurnTask.TURN_WAIT_MAX then
        if w.time > HandleHarvesterTurnTask.TURN_WAIT_MAX then
            print(string.format("[AD-DemiTour] %s: l'ensileuse tourne encore apres %.0f s, je lance quand meme le recul", name, w.time / 1000))
        elseif w.logged then
            print(string.format("[AD-DemiTour] %s: ensileuse alignee (cap stable %.0f s), je recule a cote d'elle", name, w.steady / 1000))
        end
        if self:startReverseToPipe() then
            self.state = HandleHarvesterTurnTask.STATE_REVERSE_TO_PIPE
        else
            self.state = HandleHarvesterTurnTask.STATE_FINISHED
        end
        return
    end
    if not w.logged and w.time > 600 then
        w.logged = true
        print(string.format("[AD-DemiTour] %s: demi-tour fini, l'ensileuse finit son virage, j'attends qu'elle soit alignee avant de reculer a cote d'elle", name))
    end
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
end

-- ------------------------------------------------------------------------------------------------------------
-- Lancement du recul vers la goulotte
-- ------------------------------------------------------------------------------------------------------------
-- pipe position seen from the tractor (x left, z ahead), nil if unknown
function HandleHarvesterTurnTask:getPipeLocal()
    local chasePos = self:getPipePlace()
    if chasePos == nil then
        return nil
    end
    local x, _, z = AutoDrive.worldToLocal(self.vehicle, chasePos.x, chasePos.y or 0, chasePos.z)
    return x, z
end

function HandleHarvesterTurnTask:startReverseToPipe()
    local name = tostring(self.vehicle:getName())
    -- the pipe place stays on the side the tractor is on now (place chosen by the chase, else the tractor's side)
    self.pipeSide = nil
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode ~= nil and mode.getPipeChasePosition ~= nil and mode.combine ~= nil then
        local _, chaseSide = mode:getPipeChasePosition()
        if chaseSide == AutoDrive.CHASEPOS_LEFT or chaseSide == AutoDrive.CHASEPOS_RIGHT then
            self.pipeSide = chaseSide
        else
            local vx, vy, vz = getWorldTranslation(self.vehicle.components[1].node)
            local ox = AutoDrive.worldToLocal(self.combine, vx, vy, vz, self.combine.ad.ADRootNode)
            self.pipeSide = ox >= 0 and AutoDrive.CHASEPOS_LEFT or AutoDrive.CHASEPOS_RIGHT
        end
    end
    self.pipeReverseHeading = self:getCombineHeadingDeg()
    local rx, _, rz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local cx, _, cz = AutoDrive.localDirectionToWorld(self.combine, 0, 0, 1)
    local angle = math.deg(math.acos(math.max(-1, math.min(1, (rx * cx + rz * cz) / math.max(0.001, math.sqrt((rx * rx + rz * rz) * (cx * cx + cz * cz)))))))
    local px, pz = self:getPipeLocal()
    if px == nil then
        print(string.format("[AD-DemiTour] %s: demi-tour fini, goulotte inconnue, la poursuite reprend", name))
        return false
    end
    if angle > HandleHarvesterTurnTask.PIPE_REVERSE_ANGLE or pz > -2 or -pz > HandleHarvesterTurnTask.PIPE_REVERSE_RANGE then
        print(string.format("[AD-DemiTour] %s: demi-tour fini, pas de recul vers la goulotte (cap %.0f deg, goulotte %.0f m devant / %.0f m a gauche), la poursuite reprend", name, angle, pz, px))
        return false
    end
    -- 24/10 07:42: reverse aligned on the harvester, with the AutoDrive tools (reverse waypoints driven by
    -- the drive module, as the original reverse-to-combine section): parallel to it at the pipe distance, a
    -- gentle S at the start takes up the side gap
    self.rowLine = self:getRowLine()
    local aligned, alignedWhy = self:buildAlignedReverse()
    if aligned == nil and alignedWhy ~= nil and string.sub(alignedWhy, 1, 7) == "culture" then
        -- 24/10 17:53 (AutoDrive's original parallel reverse beside it): the original
        -- reverse-to-combine section does not look at the crop, the parallel reverse is kept (field still checked)
        print(string.format("[AD-DemiTour] %s: recul parallele : %s ignoree (comme le recul d'origine AutoDrive)", name, tostring(alignedWhy)))
        aligned, alignedWhy = self:buildAlignedReverse(true)
    end
    if aligned ~= nil then
        local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
        self.pipeReverse = {x = x, z = z, time = 0, blocked = 0, aligned = true}
        self.vehicle.ad.specialDrivingModule:reset()
        local dpm = self.vehicle.ad.drivePathModule
        dpm:setWayPoints(aligned)
        -- 24/10 18:50 (it did not reverse): the drive module starts every path forward and only switches to
        -- reverse when it reaches the 2nd point, which lies behind the trailer: the tractor turned round forward
        -- toward it. This path is reverse from its first point: driven in reverse from the start
        dpm.isReversing = true
        self.vehicle.ad.specialDrivingModule:reset()
        self.vehicle.ad.specialDrivingModule.currentWayPointIndex = dpm:getCurrentWayPointIndex()
        print(string.format("[AD-DemiTour] %s: demi-tour fini, ensileuse derriere dans mon sens (%.0f deg) : recul aligne de %.0f m jusqu'a sa goulotte (ecart de cote %.1f m repris en S sur %.0f m)",
            name, angle, self.alignedLen or -pz, self.alignedGap or 0, self.alignedS or 0))
        print(string.format("[AD-DemiTour] %s: ligne du recul : %s, a %.1f m du trace (coupe %.1f m / 2 + %.0f m + train %.1f m / 2), remorque jusque sous la goulotte",
            name, self.alignedSrc or "?", self.alignedOffset or 0, self.alignedHeader or 0, HandleHarvesterTurnTask.REVERSE_HEADER_GAP, (self.alignedTrainHalf or 0) * 2))
        return true
    end
    print(string.format("[AD-DemiTour] %s: recul aligne impossible (%s), recul droit", name, tostring(alignedWhy)))
    -- 25/10 14:21 (6205 TTV: "recul droit de 43 m" with a side gap of 55 m; MF 7S.210: 87 m, ended 14 m aside):
    -- straight back only when it really ends at the pipe: side gap plus the drift of the heading angle small, way short
    local drift = math.abs(px) + (-pz) * math.sin(math.rad(math.min(90, angle)))
    if drift > HandleHarvesterTurnTask.STRAIGHT_BACK_MAX_SIDE or -pz > HandleHarvesterTurnTask.STRAIGHT_BACK_MAX_DISTANCE then
        print(string.format("[AD-DemiTour] %s: demi-tour fini, recul droit refuse (goulotte %.0f m derriere, %.0f m de cote, cap %.0f deg : j'arriverais a %.0f m de cote), la poursuite ou un nouveau trajet reprend", name, -pz, px, angle, drift))
        return false
    end
    -- straight back on its own axis (original AutoDrive, 23/10 23:03: the diagonal to the pipe cut the crop edge),
    -- the chase corrects the side gap afterwards. The line must respect the field and crop settings too
    local points = {}
    local steps = math.max(2, math.ceil(-pz / 2))
    for i = 0, steps do
        local f = i / steps
        local wx, wy, wz = AutoDrive.localToWorld(self.vehicle, 0, 0, pz * f)
        table.insert(points, {x = wx, y = wy, z = wz})
    end
    -- its own cut lane: the wheels already stand there, a small margin under the axles against the crop edge
    local ok, why = self:checkGround(points, HandleHarvesterTurnTask.PIPE_REVERSE_WIDTH)
    if not ok then
        print(string.format("[AD-DemiTour] %s: demi-tour fini, recul vers la goulotte refuse (%s), la poursuite reprend", name, tostring(why)))
        return false
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    self.pipeReverse = {x = x, z = z, time = 0, blocked = 0}
    self.vehicle.ad.specialDrivingModule:reset()
    print(string.format("[AD-DemiTour] %s: demi-tour fini, ensileuse derriere dans mon sens (%.0f deg) : recul droit de %.0f m jusqu'a sa goulotte (ecart de cote %.0f m, corrige par la poursuite)", name, angle, -pz, px))
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Ligne du recul aligné
-- ------------------------------------------------------------------------------------------------------------
-- half width of the train at its widest (body or outer tyre edge)
function HandleHarvesterTurnTask:getTrainHalfWidth()
    local half = 0
    local units = AutoDrive.getAllUnits(self.vehicle)
    for _, unit in pairs(units or {}) do
        if unit.size ~= nil and unit.size.width ~= nil then
            half = math.max(half, math.abs(unit.size.width) / 2)
        end
    end
    local pfm = self.vehicle.ad.pathFinderModule
    if pfm ~= nil and pfm.getWheelHalfWidth ~= nil then
        local ok, wheelHalf = FarmPilotCall(pfm.getWheelHalfWidth, pfm)
        if ok and wheelHalf ~= nil and wheelHalf < 5 then
            half = math.max(half, wheelHalf)
        end
    end
    if half < 0.5 then
        half = 1.5
    end
    return half
end

-- header width of the harvester (its front tool), else its own width
function HandleHarvesterTurnTask:getHeaderWidth()
    local width = AutoDrive.getFrontToolWidth(self.combine) or 0
    if width < 1 and self.combine.size ~= nil and self.combine.size.width ~= nil then
        width = math.abs(self.combine.size.width)
    end
    return width
end

-- distance from the tractor root back to the node that follows the reverse waypoints (trailer wheels), and that node
function HandleHarvesterTurnTask:getReverseNodeBehind()
    local sdm = self.vehicle.ad.specialDrivingModule
    if sdm == nil or sdm.getReverseNode == nil then
        return nil
    end
    local ok, node = FarmPilotCall(sdm.getReverseNode, sdm)
    if not ok or node == nil then
        return nil
    end
    local x, y, z = getWorldTranslation(node)
    local _, _, lz = AutoDrive.worldToLocal(self.vehicle, x, y, z)
    return math.max(0, -lz), x, z
end

-- line of the straight course part matching the row heading, read on the Courseplay course of the harvester. With
-- fromIx, from its current waypoint on; otherwise the whole course, the part the harvester stands on
function HandleHarvesterTurnTask:readCpRowLine(refX, refZ, fromIx, maxOff)
    local ok, line = FarmPilotCall(function()
        local strategy = self.combine.getCpDriveStrategy ~= nil and self.combine:getCpDriveStrategy() or nil
        if strategy == nil or strategy.getCurrentCourse == nil or strategy.ppc == nil then
            return nil
        end
        local course = strategy:getCurrentCourse()
        local ix = strategy.ppc:getCurrentWaypointIx()
        if course == nil or ix == nil then
            return nil
        end
        local n = course:getNumberOfWaypoints()
        local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
        local first = fromIx and math.max(1, ix - 2) or 1
        local cosMax = math.cos(math.rad(HandleHarvesterTurnTask.ROW_LINE_DEG))
        local best, run = nil, nil
        local function closeRun()
            if run ~= nil and run.len >= HandleHarvesterTurnTask.ROW_LINE_MIN then
                local dx, dz = run.x2 - run.x1, run.z2 - run.z1
                local len = math.sqrt(dx * dx + dz * dz)
                if len > 1 then
                    dx, dz = dx / len, dz / len
                    local along = (cx - run.x1) * dx + (cz - run.z1) * dz
                    local off = math.abs((cx - run.x1) * dz - (cz - run.z1) * dx)
                    if off <= maxOff and along >= -HandleHarvesterTurnTask.ROW_LINE_BEHIND and along <= len + HandleHarvesterTurnTask.ROW_LINE_BEHIND
                        and (best == nil or off < best.off) then
                        best = {x = run.x1, z = run.z1, dx = dx, dz = dz, len = len, off = off}
                    end
                end
            end
            run = nil
        end
        local px, _, pz = course:getWaypointPosition(first)
        local dist = 0
        for i = first + 1, n do
            local x, _, z = course:getWaypointPosition(i)
            local seg = MathUtil.vector2Length(x - px, z - pz)
            if seg > 0.1 then
                local dx, dz = (x - px) / seg, (z - pz) / seg
                if dx * refX + dz * refZ >= cosMax then
                    if run == nil then
                        run = {x1 = px, z1 = pz, len = 0}
                    end
                    run.x2, run.z2 = x, z
                    run.len = run.len + seg
                else
                    closeRun()
                    if fromIx and best ~= nil then
                        break
                    end
                end
                dist = dist + seg
                px, pz = x, z
                if fromIx and dist > HandleHarvesterTurnTask.ROW_LINE_AHEAD then
                    break
                end
            end
        end
        closeRun()
        return best
    end)
    if ok then
        return line
    end
    return nil
end

-- the new row: point, unit driving direction and source. Ways tried in turn: the Courseplay course from its current
-- waypoint, the whole course, the row entry read at the end of the row, the harvester itself
function HandleHarvesterTurnTask:getRowLine()
    local hx, _, hz = AutoDrive.localDirectionToWorld(self.combine, 0, 0, 1)
    local len = math.sqrt(hx * hx + hz * hz)
    if len < 0.01 then
        return nil
    end
    hx, hz = hx / len, hz / len
    local refX, refZ = hx, hz
    if self.cpRow ~= nil and self.cpRow.dx ~= nil and self.cpRow.dx * hx + self.cpRow.dz * hz > 0.7 then
        refX, refZ = self.cpRow.dx, self.cpRow.dz
    end
    local maxOff = math.max(3, self:getHeaderWidth() / 2)
    local line = self:readCpRowLine(refX, refZ, true, maxOff)
    if line ~= nil then
        line.src = string.format("trace Courseplay devant l'ensileuse (%.0f m lus, ensileuse a %.1f m du trace)", line.len, line.off)
        return line
    end
    line = self:readCpRowLine(refX, refZ, false, maxOff)
    if line ~= nil then
        line.src = string.format("trace Courseplay du rang (parcours entier, %.0f m, ensileuse a %.1f m du trace)", line.len, line.off)
        return line
    end
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    if self.cpRow ~= nil and self.cpRow.dx ~= nil and refX == self.cpRow.dx then
        local off = math.abs((cx - self.cpRow.x) * self.cpRow.dz - (cz - self.cpRow.z) * self.cpRow.dx)
        if off <= maxOff then
            return {x = self.cpRow.x, z = self.cpRow.z, dx = self.cpRow.dx, dz = self.cpRow.dz,
                src = string.format("entree du rang lue en bout de rang (ensileuse a %.1f m)", off)}
        end
    end
    return {x = cx, z = cz, dx = hx, dz = hz, src = "position et cap de l'ensileuse (trace Courseplay illisible)"}
end

-- reverse waypoints from the train to the pipe place, along the row line; nil, reason if refused
function HandleHarvesterTurnTask:buildAlignedReverse(ignoreCrop)
    local pipe = self:getPipePlace()
    if pipe == nil then
        return nil, "goulotte inconnue"
    end
    local line = self.rowLine or self:getRowLine()
    if line == nil then
        return nil, "cap de l'ensileuse inconnu"
    end
    local hx, hz = line.dx, line.dz
    local nx, nz = hz, -hx -- left of the row
    local tx, _, tz = getWorldTranslation(self.vehicle.components[1].node)
    local sT = (tx - line.x) * hx + (tz - line.z) * hz
    local sP = (pipe.x - line.x) * hx + (pipe.z - line.z) * hz
    local along = sT - sP -- m from the pipe place up to the tractor
    -- side of the train: the pipe side, else the side it stands on
    local side = self.pipeSide
    if side ~= AutoDrive.CHASEPOS_LEFT and side ~= AutoDrive.CHASEPOS_RIGHT then
        side = ((tx - line.x) * nx + (tz - line.z) * nz) >= 0 and AutoDrive.CHASEPOS_LEFT or AutoDrive.CHASEPOS_RIGHT
    end
    local header = self:getHeaderWidth()
    local trainHalf = self:getTrainHalfWidth()
    local offset = header / 2 + HandleHarvesterTurnTask.REVERSE_HEADER_GAP + trainHalf
    local targetLat = side * offset
    -- the waypoints are followed by the trailer wheels: start behind the train, end when the tractor stands at the place
    local tractorHalf = (self.vehicle.size ~= nil and self.vehicle.size.length or 6) / 2
    local d0 = math.max(0, AutoDrive.getTractorTrainLength(self.vehicle, true, false) - tractorHalf)
    local dRev, rx, rz = self:getReverseNodeBehind()
    dRev = dRev or d0
    local startLat
    if rx ~= nil then
        startLat = (rx - line.x) * nx + (rz - line.z) * nz
    else
        startLat = (tx - line.x) * nx + (tz - line.z) * nz
    end
    d0 = math.max(d0, dRev + 1)
    local dEnd = along + dRev + HandleHarvesterTurnTask.REVERSE_END_PAST
    if dEnd - d0 < 4 then
        return nil, string.format("goulotte trop pres (%.0f m, remorque %.0f m)", along, dRev)
    end
    local gap = startLat - targetLat
    if math.abs(gap) > HandleHarvesterTurnTask.ALIGNED_MAX_GAP then
        return nil, string.format("ecart de cote trop grand (%.0f m)", gap)
    end
    local sLen = math.min(dEnd - d0 - 2, math.max(HandleHarvesterTurnTask.ALIGNED_S_MIN,
        math.min(HandleHarvesterTurnTask.ALIGNED_S_MAX, math.abs(gap) * HandleHarvesterTurnTask.ALIGNED_S_PER_M)))
    local points = {}
    local n = math.max(2, math.floor(dEnd - d0))
    for i = 0, n do
        local d = d0 + (dEnd - d0) * i / n -- m behind the tractor root, along the row
        local u = math.min(1, (d - d0) / math.max(sLen, 0.1))
        local lateral = targetLat + gap * (1 - (3 * u * u - 2 * u * u * u))
        local s = sT - d
        local x, z = line.x + hx * s + nx * lateral, line.z + hz * s + nz * lateral
        local y = AutoDrive:getTerrainHeightAtWorldPos(x, z) or 0
        table.insert(points, {x = x, y = y, z = z, isReverse = true})
    end
    local ok, why = self:checkGround(points, HandleHarvesterTurnTask.PIPE_REVERSE_WIDTH, ignoreCrop)
    if not ok then
        return nil, why
    end
    self.alignedGap = math.abs(gap)
    self.alignedS = sLen
    self.alignedLen = dEnd - d0
    self.alignedSrc = line.src
    self.alignedOffset = offset
    self.alignedHeader = header
    self.alignedTrainHalf = trainHalf
    return points
end

-- ------------------------------------------------------------------------------------------------------------
-- Recul vers la goulotte
-- ------------------------------------------------------------------------------------------------------------
-- straight back toward the pipe, the side gap corrected along the way; done once beside it
function HandleHarvesterTurnTask:updateReverseToPipe(dt)
    local name = tostring(self.vehicle:getName())
    local r = self.pipeReverse
    local sdm = self.vehicle.ad.specialDrivingModule
    local px, pz = self:getPipeLocal()
    if px == nil then
        print(string.format("[AD-DemiTour] %s: goulotte perdue pendant le recul, la poursuite reprend", name))
        sdm:stopVehicle()
        return true
    end
    if pz > -2 and (not r.aligned or math.abs(px) <= HandleHarvesterTurnTask.PIPE_BESIDE_GAP) then
        print(string.format("[AD-DemiTour] %s: a cote de la goulotte apres le recul (%.0f m de cote), la poursuite reprend", name, math.abs(px)))
        sdm:stopVehicle()
        return true
    end
    if pz > -2 and not r.besideLogged then
        r.besideLogged = true
        print(string.format("[AD-DemiTour] %s: goulotte a hauteur mais a %.0f m de cote, pas encore a cote, je continue le recul", name, math.abs(px)))
    end
    -- the harvester turns again (its turn was not finished): stop, wait for it, plan the reverse again from here
    if self.pipeReverseHeading ~= nil and HandleHarvesterTurnTask.headingDiff(self:getCombineHeadingDeg(), self.pipeReverseHeading) > HandleHarvesterTurnTask.PIPE_REVERSE_TURNED
        and (self.pipeRestarts or 0) < HandleHarvesterTurnTask.PIPE_REVERSE_RESTARTS then
        self.pipeRestarts = (self.pipeRestarts or 0) + 1
        print(string.format("[AD-DemiTour] %s: l'ensileuse a tourne de %.0f deg pendant le recul, j'arrete, j'attends qu'elle soit alignee et je recalcule le recul (%d/%d)", name,
            HandleHarvesterTurnTask.headingDiff(self:getCombineHeadingDeg(), self.pipeReverseHeading), self.pipeRestarts, HandleHarvesterTurnTask.PIPE_REVERSE_RESTARTS))
        sdm:stopVehicle()
        sdm:update(dt)
        self:startWaitCombineTurn()
        return false
    end
    r.time = r.time + dt
    -- 24/10 09:15: held 27 m short (probably its rear sensor on the harvester header), then the chase from
    -- ahead of it planned a route forward. Blocked: stop there and wait for the harvester to come alongside
    if r.waiting then
        sdm:stopVehicle()
        sdm:update(dt)
        if r.time > HandleHarvesterTurnTask.PIPE_REVERSE_TIME + HandleHarvesterTurnTask.PIPE_WAIT_TIME then
            print(string.format("[AD-DemiTour] %s: l'ensileuse n'est pas arrivee a cote (encore %.0f m), la poursuite reprend", name, -pz))
            return true
        end
        return false
    end
    r.blocked = math.abs(self.vehicle.lastSpeedReal or 0) < 0.0002 and r.blocked + dt or 0
    if r.time > HandleHarvesterTurnTask.PIPE_REVERSE_TIME or r.blocked > HandleHarvesterTurnTask.PIPE_REVERSE_BLOCKED then
        local sensor = self.vehicle.ad.collisionDetectionModule ~= nil and self.vehicle.ad.collisionDetectionModule:checkReverseCollision()
        print(string.format("[AD-DemiTour] %s: recul vers la goulotte arrete (%s%s, encore %.0f m), j'attends l'ensileuse ici", name,
            r.blocked > HandleHarvesterTurnTask.PIPE_REVERSE_BLOCKED and "bloque" or "trop long", sensor and ", capteur arriere" or "", -pz))
        r.waiting = true
        r.time = HandleHarvesterTurnTask.PIPE_REVERSE_TIME
        sdm:stopVehicle()
        return false
    end
    if r.aligned then
        if self.vehicle.ad.drivePathModule:isTargetReached() then
            print(string.format("[AD-DemiTour] %s: recul aligne fini (goulotte encore %.0f m derriere), j'attends l'ensileuse", name, -pz))
            r.waiting = true
            r.time = HandleHarvesterTurnTask.PIPE_REVERSE_TIME
            return false
        end
        self.vehicle.ad.drivePathModule:update(dt)
        return false
    end
    local tx, ty, tz = AutoDrive.localToWorld(self.vehicle, 0, 0, pz - 6)
    sdm:reverseToTargetLocation(dt, {x = tx, y = ty, z = tz}, HandleHarvesterTurnTask.PIPE_REVERSE_SPEED)
    return false
end
