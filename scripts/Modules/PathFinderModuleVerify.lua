-- ============================================================================================================
-- FarmPilot : PathFinderModuleVerify.lua
-- Complément de PathFinderModule : contrôle du trajet trouvé.
-- Les cases peuvent être plus larges qu'une bande libre : un trajet trouvé sur la grille peut encore traverser la
-- culture ou un obstacle. Après le lissage, chaque tronçon est contrôlé (obstacles, zones interdites, culture par
-- tranches de 4 m, limite du champ) ; s'il est refusé : grille plus fine, sinon trajet partiel, départ guidé, ou
-- attente et nouvel essai (strict). Les virages trop serrés sont arrondis au vrai rayon (PathFinderModuleCorners.lua).
--
-- Historique : 25/10, sortie vers le réseau : les derniers mètres sont aussi jugés pour
-- les obstacles (un mur ou un poteau au bout du trajet).
--
-- Règle (strict) : mieux vaut attendre et recalculer que traverser la culture ; les premiers mètres (où le train est
-- déjà) et les derniers (près de la cible) ne sont pas jugés.
--
-- Branché par PathFinderModule.lua : smoothResultingPPPath_Refined (checkSmoothedPath, isFruitStretchClear) ;
-- isStretchClear aussi par DriveToVehicleTask.lua et les fichiers Band, Corners, Edge.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.FRUIT_SLICE_LENGTH = 4
PathFinderModule.ZIGZAG_MAX_KEPT = 2

-- ------------------------------------------------------------------------------------------------------------
-- Tronçon droit dégagé
-- ------------------------------------------------------------------------------------------------------------
-- straight stretch a -> b: obstacles, blocked zones, crops and field limit, as the shortcut check does
-- inner: optional unit vector towards the turn centre, the trailer cuts inside a turn
-- narrow: corridor of the train only (used to verify a whole path, hedges and trees along it are normal)
-- crop along a -> b, judged in short slices: a local bite into the crop must not vanish in the average of a long stretch
function PathFinderModule:isFruitStretchClear(a, b, halfWidth)
    local vectorX, vectorZ = b.x - a.x, b.z - a.z
    local length = math.sqrt(vectorX * vectorX + vectorZ * vectorZ)
    if length < 0.05 then
        return true
    end
    local angleRad = AutoDrive.normalizeAngle(math.atan2(-vectorZ, vectorX))
    local leftAngle = AutoDrive.normalizeAngle(angleRad + math.rad(-90))
    local rightAngle = AutoDrive.normalizeAngle(angleRad + math.rad(90))
    local slices = math.max(1, math.ceil(length / PathFinderModule.FRUIT_SLICE_LENGTH))
    local cosL, sinL = math.cos(leftAngle), math.sin(leftAngle)
    local cosR, sinR = math.cos(rightAngle), math.sin(rightAngle)
    for k = 0, slices - 1 do
        local sx, sz = a.x + vectorX * k / slices, a.z + vectorZ * k / slices
        local ex, ez = a.x + vectorX * (k + 1) / slices, a.z + vectorZ * (k + 1) / slices
        local c1X, c1Z = sx - cosL * halfWidth, sz + sinL * halfWidth
        local c2X, c2Z = ex - cosL * halfWidth, ez + sinL * halfWidth
        local c4X, c4Z = sx - cosR * halfWidth, sz + sinR * halfWidth
        local filter = self:getCropFilter()
        if filter ~= nil or self.goingToNetwork or self.strictFruit then
            local ratio, found = PathFinderModule.getMapCropRatio(filter, c1X, c1Z, c2X, c2Z, c4X, c4Z)
            -- same rule as the grid cells: the train may run along the crop edge, not into it
            if ratio > PathFinderModule.CELL_MAX_RATIO then
                local fruitType = found ~= nil and g_fruitTypeManager:getFruitTypeByIndex(found) or nil
                return false, "culture " .. tostring(fruitType ~= nil and fruitType.name or "")
            end
        end
    end
    return true
end

function PathFinderModule:isStretchClear(a, b, inner, narrow, obstaclesOnly)
    local vectorX, vectorZ = b.x - a.x, b.z - a.z
    local length = math.sqrt(vectorX * vectorX + vectorZ * vectorZ)
    if length < 0.05 then
        return true
    end
    local angleRad = AutoDrive.normalizeAngle(math.atan2(-vectorZ, vectorX))
    local leftAngle = AutoDrive.normalizeAngle(angleRad + math.rad(-90))
    local rightAngle = AutoDrive.normalizeAngle(angleRad + math.rad(90))
    local halfWidth = self.trainHalfWidth or 3
    local midX, midZ = a.x + vectorX / 2, a.z + vectorZ / 2
    -- same corridor as the shortcut check of the grid path, at least the train width
    local boxHalf = math.max(self.minTurnRadius * PathFinderModule.GRID_SIZE_FACTOR + 1.5, halfWidth + 0.5)
    if narrow then
        boxHalf = halfWidth + 0.5
    end
    -- trees on the grass are not always seen: wider corridor off the field in reduced grids
    if self:isOffFieldReduced(midX, midZ) then
        boxHalf = boxHalf + PathFinderModule.OFF_FIELD_EXTRA_MARGIN
    end
    local boxX, boxZ = midX, midZ
    if inner ~= nil then
        boxHalf = boxHalf + PathFinderModule.CORNER_INNER_MARGIN / 2
        boxX = boxX + inner.x * PathFinderModule.CORNER_INNER_MARGIN / 2
        boxZ = boxZ + inner.z * PathFinderModule.CORNER_INNER_MARGIN / 2
    end
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, boxX, 1, boxZ)

    self.collisionhits = 0
    overlapBox(boxX, y + self.vehicleMinHeight / 2, boxZ, 0, angleRad, 0, length / 2 + 1, self.vehicleMinHeight / 2, boxHalf, "collisionTestCallback", self, self.mask, true, true, true, true)
    if self.collisionhits > 0 or self:boxHitsBlockedZone(boxX, boxZ, angleRad, length / 2 + 1, boxHalf) then
        return false, "obstacle"
    end
    if obstaclesOnly then
        return true
    end
    if self:checkSlopeAngle(a.x, a.z, b.x, b.z) then
        return false, "pente"
    end

    if self.avoidFruitSetting and not self.fallBackMode3 then
        local clear, reason = self:isFruitStretchClear(a, b, self.cropHalfWidth or halfWidth)
        if not clear then
            return false, reason
        end
    end

    if self.restrictToField and not (self.fallBackMode1 or self.fallBackMode2) then
        local sideHalf = halfWidth - PathFinderModule.FRUIT_CHECK_CORRIDOR_MARGIN
        local sideX, sideZ = math.cos(leftAngle) * sideHalf, -math.sin(leftAngle) * sideHalf
        for _, t in ipairs({0, 0.5, 1}) do
            local px, pz = a.x + vectorX * t, a.z + vectorZ * t
            for _, sign in ipairs({1, -1}) do
                local allowed, onOtherField = self:isTrainSideAllowed(px + sideX * sign, pz + sideZ * sign)
                if not allowed then
                    return false, onOtherField and "bord du champ (autre champ)" or "bord du champ (hors champ)"
                end
            end
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Premier tronçon refusé d'un trajet
-- ------------------------------------------------------------------------------------------------------------
-- the first meters (at the vehicle) and the last meters (next to the target) are not judged
PathFinderModule.VERIFY_SKIP_START = 12
PathFinderModule.START_CROP_RADIUS = 4
PathFinderModule.START_CROP_AHEAD = 1 -- m ahead of the tractor node where crop may still be (its own front)
PathFinderModule.VERIFY_CROP_START = 3 -- forage harvester, strict: crop judged from here on (12 m before)
PathFinderModule.VERIFY_SKIP_END = 15
function PathFinderModule:findBlockedStretch()
    local wps = self.wayPoints
    if wps == nil then
        return nil
    end
    -- distances along the route: the first and last meters are not judged (start turn, approach)
    local total = 0
    for i = 1, #wps - 1 do
        total = total + MathUtil.vector2Length(wps[i + 1].x - wps[i].x, wps[i + 1].z - wps[i].z)
    end
    local skipFrom, skipTo = PathFinderModule.VERIFY_SKIP_START, total - PathFinderModule.VERIFY_SKIP_END
    if self:isChopperWork() and (self.strictFruit or self.strictField) then
        -- strict: no turn through the crop at the start either, only the train's own place is left out
        skipFrom = PathFinderModule.VERIFY_CROP_START
    end
    if self.partialPath or self.goingBehind then
        -- a partial route stops before the target: its end is where the vehicle waits, it is judged too;
        -- behind the harvester is cut ground, nothing to leave out there
        skipTo = total
    end
    local done = 0
    for i = 1, #wps - 1 do
        local a, b = wps[i], wps[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local length = math.sqrt(dx * dx + dz * dz)
        local from = math.max(0, skipFrom - done)
        local to = math.min(length, skipTo - done)
        -- start turn: crop and field edge not judged, obstacles still are
        local startTo = math.min(length, skipFrom - done, skipTo - done)
        if startTo > 0.5 then
            local pb = {x = a.x + dx * startTo / length, z = a.z + dz * startTo / length}
            if not self:isStretchClear(a, pb, nil, true, true) then
                return i, "obstacle"
            end
        end
        -- 25/10, exit to the network: the last meters are judged for obstacles too. A wall or a post
        -- between the field and the road is thinner than a cell, the coarse grid drives through it
        if self.exitToNetwork then
            local endFrom = math.max(0, skipTo - done, startTo)
            if length - endFrom > 0.5 then
                local pa = {x = a.x + dx * endFrom / length, z = a.z + dz * endFrom / length}
                if not self:isStretchClear(pa, b, nil, true, true) then
                    return i, "obstacle (approche)"
                end
            end
        end
        done = done + length
        if to - from > 0.5 then
            local pa = {x = a.x + dx * from / length, z = a.z + dz * from / length}
            local pb = {x = a.x + dx * to / length, z = a.z + dz * to / length}
            local clear, reason = self:isStretchClear(pa, pb, nil, true)
            if not clear then
                return i, reason
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Contrôle du trajet lissé (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
-- accroche de smoothResultingPPPath_Refined (fin du lissage) ; true = smoothResultingPPPath_Refined s'arrête là
function PathFinderModule:checkSmoothedPath()
    -- the cells can be wider than a free strip: a path found on the grid may still cross crop or an obstacle
    if self.gridScaleStep ~= nil and not self.chasingVehicle and not self.isSecondChasingVehicle then
        local badIndex, reason = self:findBlockedStretch()
        if badIndex ~= nil then
            local p = self.wayPoints[badIndex]
            if self.gridScaleStep < PathFinderModule.GRID_STEPS then
                print(string.format("[AD-Fin] %s: trajet en cases de %.1f m refuse (%s vers %.0f,%.0f), recalcul plus fin", self:getLogName(), self.minTurnRadius, tostring(reason), p.x, p.z))
                self.isFinished = false
                self:shrinkGrid()
                return true
            end
            if (self.strictFruit or self.strictField) and self:usePartialPath(badIndex) then
                -- the clean beginning of the route is kept, the task plans again on arrival
            elseif (self.strictFruit or self.strictField) and self:tryGuidedDeparture() then
                self.smoothDone = true
                return true
            elseif self.strictFruit or self.strictField then
                -- strict: better wait and plan again than drive through the crop, the calling task retries
                print(string.format("[AD-Fin] %s: aucun trajet propre (%s vers %.0f,%.0f), strict : attente et nouvel essai", self:getLogName(), tostring(reason), p.x, p.z))
                self:dumpSearchMap("trajet refuse", self.wayPoints, p)
                self:abortOrTour()
                self.smoothStep = 3
                return true
            else
                print(string.format("[AD-Fin] %s: trajet en cases de %.1f m garde malgre %s vers %.0f,%.0f (pas mieux)", self:getLogName(), self.minTurnRadius, tostring(reason), p.x, p.z))
            end
        end
        if self.partialPath and not self:trimPartialEnd() then
            if self:tryGuidedDeparture() then
                self.smoothDone = true
                return true
            end
            print(string.format("[AD-Fin] %s: trajet partiel sans point d'arret propre (face a la moissonneuse ou emprise dans la culture), attente et nouvel essai", self:getLogName()))
            self.partialFailCount = (self.partialFailCount or 0) + 1
            if self.partialFailCount >= PathFinderModule.PARTIAL_FACING_LIFT_FAILURES and not self.partialFacingLifted and self:isChopperWork() then
                self.partialFacingLifted = true
                print(string.format("[AD-Fin] %s: %d attentes de suite, regle face a la moissonneuse levee", self:getLogName(), self.partialFailCount))
            end
            self:abortOrTour()
            self.smoothStep = 3
            return true
        end
        -- a route leaves: the next wait counts from zero again
        self.partialFailCount = 0
        self.partialFacingLifted = false
        self.guidedInRow = 0
        self.guidedLimitPrinted = false
    end
    if self.gridScaleStep ~= nil and self.gridScaleStep > 1 then
        local kept, sharp = self:roundCornersToTurnRadius()
        kept, sharp = kept or 0, sharp or 0
        -- a corner too sharp for the train cannot be driven: finer grid, and on the finest one no route (strict)
        if sharp > 0 and self.gridScaleStep < PathFinderModule.GRID_STEPS then
            print(string.format("[AD-Fin] %s: %d virage(s) trop serre(s) en cases de %.1f m, recalcul plus fin", self:getLogName(), sharp, self.minTurnRadius))
            self.isFinished = false
            self:shrinkGrid()
            return true
        elseif sharp > 0 and (self.strictFruit or self.strictField) and self:usePartialBeforeSharp() then
            -- the route is driven up to the corner, planned again there
        elseif sharp > 0 and (self.strictFruit or self.strictField) and self:tryGuidedDeparture() then
            self.smoothDone = true
            return true
        elseif sharp > 0 and (self.strictFruit or self.strictField) and self:tryGuidedDeparture(true) then
            self.smoothDone = true
            return true
        elseif sharp > 0 and (self.strictFruit or self.strictField) then
            print(string.format("[AD-Fin] %s: %d virage(s) trop serre(s) pour le train meme en cases de %.1f m, strict : attente et nouvel essai", self:getLogName(), sharp, self.minTurnRadius))
            self:dumpSearchMap("virages trop serres", self.wayPoints, nil)
            self:abortOrTour()
            self.smoothStep = 3
            return true
        end
        -- zigzag: the points of a coarse grid fall badly in the free strip, a finer grid follows it
        if kept > PathFinderModule.ZIGZAG_MAX_KEPT and self.gridScaleStep < PathFinderModule.GRID_STEPS then
            print(string.format("[AD-Fin] %s: zigzag en cases de %.1f m (%d angles), recalcul plus fin", self:getLogName(), self.minTurnRadius, kept))
            self.isFinished = false
            self:shrinkGrid()
            return true
        end
    end
    -- a whole route leaves: the further departures count from zero again
    if not self.partialPath then
        self.guidedLossInRow = 0
    end
    return false
end
