-- ============================================================================================================
-- FarmPilot : PathFinderModuleGrid.lua
-- Complément de PathFinderModule : la grille de recherche (A*) et la courbe directe.
-- - Pas de trajet : nouvel essai avec des cases plus petites, 9 m -> 6 m -> 4,5 m -> 2 m (les virages du trajet
--   final gardent le vrai rayon, voir PathFinderModuleCorners.lua).
-- - Recherche bloquée vers la moissonneuse : plus de pas n'y changerait rien.
-- - Liste ouverte de l'A* gardée dans un tas binaire (rapide sur les grandes grilles).
-- - Courbe directe (Dubins) : refusée si elle boucle, ou si, en strict, la bande du train touche la culture.
--
-- Historique : 25/10 06:58, 8 essais c'est trop : recul dès le 4e
-- (une recherche bloquée échoue tout de suite ; la tâche recule ensuite sur ses traces).
--
-- Règle : pas de changement de cible ni de restriction quand la grille s'affine, seulement la taille des cases.
--
-- Branché par PathFinderModule.lua : update (shrinkGrid, isMoreStepsUseful, pop_best_node -> popOpenEntry),
-- setupNew / A* (pushOpenNode), getDubinsPath (checkDirectCurve) ; shrinkGrid aussi par PathFinderModuleVerify.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages et taille des cases
-- ------------------------------------------------------------------------------------------------------------
-- smaller grid cells when no path is found: 9 m -> 6 m -> 4.5 m -> 2 m (turns of the final path keep the real radius)
PathFinderModule.GRID_SCALES = {1, 2 / 3, 1 / 2}
PathFinderModule.GRID_FINEST_SIZE = 2
PathFinderModule.GRID_STEPS = #PathFinderModule.GRID_SCALES + 1

function PathFinderModule:getGridScale(step)
    return PathFinderModule.GRID_SCALES[step] or math.min(1, PathFinderModule.GRID_FINEST_SIZE / self.realTurnRadius)
end

-- ------------------------------------------------------------------------------------------------------------
-- Grille plus fine quand rien n'est trouvé
-- ------------------------------------------------------------------------------------------------------------
-- no path found: same start, target and restrictions, but a finer grid
function PathFinderModule:shrinkGrid()
    local oldSize = self.minTurnRadius
    self.gridScaleStep = self.gridScaleStep + 1
    local scale = self:getGridScale(self.gridScaleStep)
    self.minTurnRadius = self.realTurnRadius * scale
    print(string.format("[AD-Fin] %s: pas de chemin avec des cases de %.1f m, essai avec %.1f m (%s)", self:getLogName(), oldSize, self.minTurnRadius, self:getDiagText()))

    local angleRad = AutoDrive.normalizeAngle(math.atan2(self.targetVector.z, self.targetVector.x))
    self.vectorX = {x =   math.cos(angleRad) * self.minTurnRadius, z = math.sin(angleRad) * self.minTurnRadius}
    self.vectorZ = {x = - math.sin(angleRad) * self.minTurnRadius, z = math.cos(angleRad) * self.minTurnRadius}

    local vehicleWorldX, _, vehicleWorldZ, vehicleRx, vehicleRz = self:getStartPose()
    local vehicleVector = {x = vehicleRx, z = vehicleRz}
    self.startCell.direction = self:worldDirectionToGridDirection(vehicleVector)

    local vehicleBehindX, vehicleBehindZ = -vehicleRx * self.minTurnRadius, -vehicleRz * self.minTurnRadius
    self.behindStartCell = self:worldLocationToGridLocation(vehicleWorldX + vehicleBehindX, vehicleWorldZ + vehicleBehindZ)
    self.behindStartCell.direction = self:worldDirectionToGridDirection({x = vehicleBehindX, z = vehicleBehindZ}, vehicleVector)
    self.behind = {x = vehicleWorldX + vehicleBehindX, z = vehicleWorldZ + vehicleBehindZ}

    local targetCell = self:worldLocationToGridLocation(self.target.x, self.target.z)
    self.targetCell = {x = AutoDrive.round(targetCell.x), z = AutoDrive.round(targetCell.z), direction = self.PP_UP}
    self.targetAhead = {x = self.target.x + self.vectorX.x, z = self.target.z + self.vectorX.z}
    self.targetAheadCell = self:worldLocationToGridLocation(self.targetAhead.x, self.targetAhead.z)

    -- smaller cells cover less ground per step
    self.max_pathfinder_steps = math.floor(self.max_pathfinder_steps / scale * self:getGridScale(self.gridScaleStep - 1))
    self:autoRestart()
end

-- ------------------------------------------------------------------------------------------------------------
-- Recherche bloquée : plus de pas n'y changerait rien
-- ------------------------------------------------------------------------------------------------------------
-- 25/10 06:58 (8 tries is too many, it must back off by the 4th): a search to the harvester that
-- ended blocked (no more cells to explore, or its own limit) gives the same result with more steps: the 728 ran
-- 9 identical restarts of 8 s (steps 201/400 ... 201/1200) for nothing. Such a search fails at once; the task
-- then backs off along its own tracks after the next failure from the same place
-- accroche de PathFinderModule:update (pas de trajet) : renvoie increaseStepsAllowed
function PathFinderModule:isMoreStepsUseful(increaseStepsAllowed, keepRestrictions)
    if increaseStepsAllowed and keepRestrictions and self.completelyBlocked then
        increaseStepsAllowed = false
        print(string.format("[AD-Fin] %s: pas de chemin, toutes les cases atteignables sont explorees (%d pas sur %d), chercher avec plus de pas ne changerait rien, abandon de ce trajet",
            self:getLogName(), self.steps or 0, self.max_pathfinder_steps or 0))
    end
    return increaseStepsAllowed
end

-- ------------------------------------------------------------------------------------------------------------
-- Liste ouverte de l'A* en tas binaire
-- ------------------------------------------------------------------------------------------------------------
-- the open set is mirrored in a binary heap (self.openHeap) ordered by f score,
-- entries whose score changed or which were already taken are skipped
function PathFinderModule:pushOpenNode(node, f)
    local heap = self.openHeap
    local i = #heap + 1
    heap[i] = {f = f, node = node}
    while i > 1 do
        local parent = math.floor(i / 2)
        if heap[parent].f <= heap[i].f then
            break
        end
        heap[parent], heap[i] = heap[i], heap[parent]
        i = parent
    end
end

function PathFinderModule:popOpenEntry()
    local heap = self.openHeap
    local count = #heap
    if count == 0 then
        return nil
    end
    local top = heap[1]
    heap[1] = heap[count]
    heap[count] = nil
    count = count - 1
    local i = 1
    while true do
        local left, right, smallest = i * 2, i * 2 + 1, i
        if left <= count and heap[left].f < heap[smallest].f then
            smallest = left
        end
        if right <= count and heap[right].f < heap[smallest].f then
            smallest = right
        end
        if smallest == i then
            break
        end
        heap[smallest], heap[i] = heap[i], heap[smallest]
        i = smallest
    end
    return top
end

-- ------------------------------------------------------------------------------------------------------------
-- Courbe directe (Dubins)
-- ------------------------------------------------------------------------------------------------------------
-- the direct curve must not loop around to reach a point at a hard angle (the harvester is gone meanwhile),
-- and in strict mode the band swept by the whole train (trailer inside the curves) must be free of crop
PathFinderModule.DIRECT_CURVE_MAX_FACTOR = 2
PathFinderModule.DIRECT_CURVE_MIN_LENGTH = 15
function PathFinderModule:checkDirectCurve(path)
    if path == nil or #path < 2 then
        return ADDubins.EDUBNOPATH
    end
    if not self:isChopperWork() then
        return ADDubins.EDUBOK
    end
    local a, b = path[1], path[#path]
    local distance = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
    local length = #path -- samples are 1 m apart
    if length > math.max(PathFinderModule.DIRECT_CURVE_MAX_FACTOR * distance, PathFinderModule.DIRECT_CURVE_MIN_LENGTH) then
        print(string.format("[AD-Fin] %s: courbe directe refusee : %d m pour une cible a %.0f m (boucle)", self:getLogName(), length, distance))
        return ADDubins.EDUBNOPATH
    end
    if (self.strictFruit or self.strictField) then
        local clear, cropAt = self:isGuidedBandClear(path, self.realTurnRadius or self.minTurnRadius, 0)
        if not clear then
            print(string.format("[AD-Fin] %s: courbe directe refusee : culture dans la bande du train a %.0f m", self:getLogName(), cropAt or 0))
            return ADDubins.EDUBNOPATH
        end
    end
    return ADDubins.EDUBOK
end
