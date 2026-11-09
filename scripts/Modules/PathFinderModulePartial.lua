-- ============================================================================================================
-- FarmPilot : PathFinderModulePartial.lua
-- Complément de PathFinderModule : le trajet partiel.
-- Pas de trajet complet propre : le début propre du trajet est gardé (jusqu'au premier tronçon refusé, jusqu'à un
-- virage trop serré, ou jusqu'à la case explorée la plus proche de la cible), le véhicule y roule et la tâche
-- recalcule à l'arrivée. L'arrêt se fait avec une marge, train entier hors de la culture, jamais face à la
-- moissonneuse dans son chemin.
--
-- Historique :
-- - règle : rouler jusqu'au dernier point valable, recalculer de là ;
-- - 25/10 19:14 : une cible dans un obstacle (haie) n'est jamais approchée morceau par morceau ;
-- - 26/10 17:20 (942 Vario, 91° de la moissonneuse arrêtée, 39 m) : un arrêt à contresens mais bien à côté de sa
--   ligne n'est pas « face à face », seul compte un arrêt dans le couloir devant elle.
--
-- Règle : un trajet partiel doit rapprocher d'au moins PARTIAL_MIN_GAIN m de la cible.
--
-- Branché par PathFinderModule.lua : update (usePartialGridPath) ; par PathFinderModuleVerify.lua (usePartialPath,
-- usePartialBeforeSharp, trimPartialEnd).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Trajet partiel
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.PARTIAL_MIN_GAIN = 10

function PathFinderModule:partialAllowed()
    return self.allowPartialPath and (self.strictFruit or self.strictField) and not self.partialPath and self.isNewPF
end

-- a partial route must bring the vehicle at least PARTIAL_MIN_GAIN closer to the target
function PathFinderModule:partialGain(endPoint)
    local band = self:getBandGain(self.startX, self.startZ, endPoint.x, endPoint.z)
    if band ~= nil then
        return band
    end
    local startDistance = MathUtil.vector2Length(self.startX - self.target.x, self.startZ - self.target.z)
    local endDistance = MathUtil.vector2Length(endPoint.x - self.target.x, endPoint.z - self.target.z)
    return startDistance - endDistance
end

-- refused route: keep its clean beginning, up to the first refused stretch
function PathFinderModule:usePartialPath(badIndex)
    -- a partial route can be shortened again
    if not (self:partialAllowed() or self.partialPath) or badIndex == nil or badIndex < 2 then
        return false
    end
    local points = {}
    for i = 1, badIndex do
        points[i] = self.wayPoints[i]
    end
    local gain = self:partialGain(points[#points])
    if gain < PathFinderModule.PARTIAL_MIN_GAIN then
        return false
    end
    self.wayPoints = points
    self.partialPath = true
    print(string.format("[AD-Fin] %s: trajet partiel jusqu'a %.0f,%.0f (%.0f m plus pres), nouveau calcul a l'arrivee", self:getLogName(), points[#points].x, points[#points].z, gain))
    return true
end

-- a corner too sharp for the train: the route is kept up to it (rule: drive to the last valid point, plan
-- again from there), with the usual end checks of a partial route
PathFinderModule.SHARP_PARTIAL_MIN_LENGTH = 10

function PathFinderModule:usePartialBeforeSharp()
    local index = self.firstSharpIndex
    if not self:isChopperWork() or index == nil or index < 2 or not (self:partialAllowed() or self.partialPath) then
        return false
    end
    local length = 0
    for i = 2, index do
        length = length + MathUtil.vector2Length(self.wayPoints[i].x - self.wayPoints[i - 1].x, self.wayPoints[i].z - self.wayPoints[i - 1].z)
    end
    if length < PathFinderModule.SHARP_PARTIAL_MIN_LENGTH then
        return false
    end
    local saved, savedPartial = self.wayPoints, self.partialPath
    local p = saved[index]
    if self:usePartialPath(index) and self:trimPartialEnd() then
        print(string.format("[AD-Fin] %s: virage trop serre vers %.0f,%.0f : trajet garde jusqu'avant lui (%.0f m), nouveau calcul de la", self:getLogName(), p.x, p.z, length))
        return true
    end
    self.wayPoints = saved
    self.partialPath = savedPartial
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin d'un trajet partiel : jamais face à la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- end of a partial route to a harvester: never waiting face to face with it, against its way
PathFinderModule.PARTIAL_MAX_HEADING_ANGLE = math.rad(120)
PathFinderModule.PARTIAL_HEADING_LENGTH = 3
PathFinderModule.PARTIAL_FACING_MAX_DISTANCE = 60 -- the rule only matters near the harvester
PathFinderModule.PARTIAL_FACING_LIFT_FAILURES = 5 -- after so many waits in a row, the rule is lifted
PathFinderModule.PARTIAL_SHORT_MIN_GAIN = 2 -- a partial route shortened to a clean stop must still move this much
-- 26/10 17:20 (942 Vario, 91 deg from the standing harvester, 39 m): a stop heading against the harvester but well
-- beside its line is not "face to face": only a stop in the corridor ahead of it counts
PathFinderModule.PARTIAL_FACING_CORRIDOR = 10 -- m each side of the harvester's line
PathFinderModule.PARTIAL_FACING_BEHIND = 5 -- m: a stop further behind its rear is out of its way

function PathFinderModule:isPartialEndFacingCombine(index)
    local wps = self.wayPoints
    if not self.goingToPipe or self.pipeCombine == nil or self.pipeCombine.components == nil or index < 2 then
        return false
    end
    local b = wps[index]
    local a = nil
    for j = index - 1, 1, -1 do
        a = wps[j]
        if MathUtil.vector2Length(b.x - a.x, b.z - a.z) >= PathFinderModule.PARTIAL_HEADING_LENGTH then
            break
        end
    end
    local dx, dz = b.x - a.x, b.z - a.z
    local length = math.sqrt(dx * dx + dz * dz)
    if length < 0.5 then
        return false
    end
    if self:isChopperWork() then
        if self.partialFacingLifted then
            return false
        end
        local cx, _, cz = getWorldTranslation(self.pipeCombine.components[1].node)
        if MathUtil.vector2Length(b.x - cx, b.z - cz) > PathFinderModule.PARTIAL_FACING_MAX_DISTANCE then
            return false
        end
        -- out of the harvester's corridor (beside its line or behind it): it never drives into that stop
        local lx, _, lz = AutoDrive.worldToLocal(self.pipeCombine, b.x, b.y or 0, b.z)
        if lx ~= nil and (math.abs(lx) > PathFinderModule.PARTIAL_FACING_CORRIDOR or lz < -PathFinderModule.PARTIAL_FACING_BEHIND) then
            return false
        end
    end
    local rx, _, rz = AutoDrive.localDirectionToWorld(self.pipeCombine, 0, 0, 1)
    return (dx * rx + dz * rz) / length < math.cos(PathFinderModule.PARTIAL_MAX_HEADING_ANGLE)
end

-- shortens the partial route to its last point not facing the harvester; false: no usable point, wait
function PathFinderModule:trimPartialEnd()
    local wps = self.wayPoints
    for i = #wps, 2, -1 do
        if self:partialGain(wps[i]) < PathFinderModule.PARTIAL_MIN_GAIN then
            return false
        end
        if not self:isPartialEndFacingCombine(i) then
            if i < #wps then
                for j = #wps, i + 1, -1 do
                    table.remove(wps, j)
                end
                print(string.format("[AD-Fin] %s: fin du trajet partiel face a la moissonneuse, arret plus tot a %.0f,%.0f", self:getLogName(), wps[i].x, wps[i].z))
            end
            return self:keepPartialStopMargin()
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Arrêt propre, avec marge
-- ------------------------------------------------------------------------------------------------------------
-- a partial route stops with margin: PARTIAL_STOP_MARGIN meters back along the route, and the train standing there
-- (its width + 1 m each side) touches no crop. Returns false if nothing worth driving is left
PathFinderModule.PARTIAL_STOP_MARGIN = 10
PathFinderModule.PARTIAL_DRIVE_SHARE = 0.8 -- forage harvester: share of a partial piece driven before the stop
PathFinderModule.STOP_OVERRUN = 4 -- clear ground in front of a stop: the train overruns its last point by ~3 m
PathFinderModule.PARTIAL_STOP_START_IGNORE = 15 -- crop this close to the start is where the train already stands
function PathFinderModule:isPartialStopClear(i)
    local wps = self.wayPoints
    local a, b = wps[i - 1], wps[i]
    local dx, dz = b.x - a.x, b.z - a.z
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 0.05 then
        return true
    end
    dx, dz = dx / l, dz / l
    local chopper = self:isChopperWork()
    -- exact train width: the route itself is already checked with its margin (combine harvester: width + 1 m)
    local half = chopper and self:getCropHalfWidth() or ((self.trainHalfWidth or 2) + 1)
    local back = math.max(AutoDrive.getTractorTrainLength(self.vehicle, true, false), 8)
    -- the train already stands near the start: crop there is not run over by driving on, it is not counted
    local start = wps[1]
    if chopper and start ~= nil then
        local fromStart = MathUtil.vector2Length(b.x - start.x, b.z - start.z) - PathFinderModule.PARTIAL_STOP_START_IGNORE
        back = math.max(math.min(back, fromStart), 0.5)
    end
    local c1X, c1Z = b.x - dz * half - dx * back, b.z + dx * half - dz * back
    local ahead = chopper and PathFinderModule.STOP_OVERRUN or 2
    local c2X, c2Z = b.x - dz * half + dx * ahead, b.z + dx * half + dz * ahead
    local c4X, c4Z = b.x + dz * half - dx * back, b.z - dx * half - dz * back
    return PathFinderModule.getMapCropRatio(nil, c1X, c1Z, c2X, c2Z, c4X, c4Z) <= 0
end

function PathFinderModule:keepPartialStopMargin()
    local wps = self.wayPoints
    local saved = {}
    for i = 1, #wps do
        saved[i] = wps[i]
    end
    local removed = 0
    local margin = PathFinderModule.PARTIAL_STOP_MARGIN
    if self:isChopperWork() then
        -- forage harvester: drive PARTIAL_DRIVE_SHARE of the planned piece (the next piece is planned meanwhile),
        -- the stop itself keeps STOP_OVERRUN of clean ground ahead (isPartialStopClear)
        local length = 0
        for i = 2, #wps do
            length = length + MathUtil.vector2Length(wps[i].x - wps[i - 1].x, wps[i].z - wps[i - 1].z)
        end
        margin = length * (1 - PathFinderModule.PARTIAL_DRIVE_SHARE)
    end
    while #wps > 2 do
        local last, before = wps[#wps], wps[#wps - 1]
        if removed >= margin and self:isPartialStopClear(#wps) then
            break
        end
        removed = removed + MathUtil.vector2Length(last.x - before.x, last.z - before.z)
        table.remove(wps, #wps)
    end
    if (#wps < 2 or self:partialGain(wps[#wps]) < PathFinderModule.PARTIAL_MIN_GAIN) and not self:isChopperWork() then
        print(string.format("[AD-Fin] %s: trajet partiel trop court avec la marge, attente", self:getLogName()))
        return false
    end
    if #wps < 2 or self:partialGain(wps[#wps]) < PathFinderModule.PARTIAL_MIN_GAIN then
        -- too short with the full margin: smaller margin, as long as the stopped train touches no crop
        for i = #wps + 1, #saved do
            wps[i] = saved[i]
        end
        removed = 0
        while #wps > 2 and not self:isPartialStopClear(#wps) do
            local last, before = wps[#wps], wps[#wps - 1]
            removed = removed + MathUtil.vector2Length(last.x - before.x, last.z - before.z)
            table.remove(wps, #wps)
        end
        if #wps < 2 or not self:isPartialStopClear(#wps) or self:partialGain(wps[#wps]) < PathFinderModule.PARTIAL_SHORT_MIN_GAIN then
            print(string.format("[AD-Fin] %s: trajet partiel trop court avec la marge, attente", self:getLogName()))
            return false
        end
        print(string.format("[AD-Fin] %s: trajet partiel court (marge reduite a %.0f m, arret propre), a %.0f,%.0f", self:getLogName(), removed, wps[#wps].x, wps[#wps].z))
        return true
    end
    print(string.format("[AD-Fin] %s: trajet partiel arrete %.0f m plus tot (marge), a %.0f,%.0f", self:getLogName(), removed, wps[#wps].x, wps[#wps].z))
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Trajet partiel sur la grille
-- ------------------------------------------------------------------------------------------------------------
-- no route at the finest grid: route to the explored cell closest to the target
function PathFinderModule:usePartialGridPath()
    if not self:partialAllowed() or self.closedset == nil or self.nodeGoal == nil then
        return false
    end
    -- 25/10 19:14: a target inside an obstacle (hedge) is never approached piece by piece (the 7R crept toward the
    -- hedge, route after route). The target itself must be free of fixed obstacles
    if self.target ~= nil and self.targetVector ~= nil and self:isRearPointObstructed(self.target.x, self.target.z, self.targetVector.x, self.targetVector.z) then
        if not self.targetObstructedPrinted then
            self.targetObstructedPrinted = true
            print(string.format("[AD-Fin] %s: cible %.0f,%.0f dans un obstacle, pas de trajet partiel vers elle", self:getLogName(), self.target.x, self.target.z))
        end
        return false
    end
    local best, bestDistance = nil, math.huge
    for node, _ in pairs(self.closedset) do
        if node ~= self.nodeBehindStart and self.came_from[node] ~= nil then
            local distance = MathUtil.vector2Length(node.x - self.nodeGoal.x, node.z - self.nodeGoal.z)
            local band = self:getBandDistanceAtNode(node)
            if band ~= nil then
                -- in grid cells, as the straight distance; a node out of the strips is never the best
                distance = band ~= false and band / self.minTurnRadius or math.huge
            end
            if distance < bestDistance then
                best, bestDistance = node, distance
            end
        end
    end
    if best == nil or best == self.nodeStart then
        return false
    end
    local endPoint = self:gridLocationToWorldLocation(best)
    if self:partialGain(endPoint) < PathFinderModule.PARTIAL_MIN_GAIN then
        return false
    end
    self.path = self:unwind_path({}, self.came_from, best)
    table.insert(self.path, best)
    self.partialPath = true
    self.completelyBlocked = false
    self.isFinished = true
    print(string.format("[AD-Fin] %s: pas de trajet complet, trajet partiel jusqu'a %.0f,%.0f, nouveau calcul a l'arrivee", self:getLogName(), endPoint.x, endPoint.z))
    return true
end
