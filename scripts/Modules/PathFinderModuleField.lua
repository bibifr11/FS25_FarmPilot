-- ============================================================================================================
-- FarmPilot : PathFinderModuleField.lua
-- Complément de PathFinderModule (recherche de trajet d'AutoDrive d'origine) : le champ.
-- - Sortie de champ : un véhicule sur un champ rejoint le réseau par une destination (en mode moissonneuse, le
--   champ réglé en 1re destination ; sinon la destination la plus proche, à 500 m au plus, qui mène à la cible,
--   celles du champ où il est d'abord), jamais par un point au-delà de la culture ou sur un autre champ.
-- - Contours des champs de la carte et sol de champ relié : deux champs ne comptent pour un que si leur sol se
--   touche (une bande d'herbe ou une route entre eux les sépare).
-- - Restriction au champ d'une position : normal = seulement sur le champ ; strict = partout sauf sur un autre
--   champ (l'herbe et les bas-côtés restent permis), côtés du train compris.
-- - Réglages stricts posés au départ de chaque trajet.
--
-- Règle : les réglages « strict » (rester sur le champ, éviter la culture) ne sont jamais levés par les modes de
-- secours d'AutoDrive, quel que soit le trajet ; le champ est reconnu par son contour sur la carte (un champ peut
-- s'étendre sur plusieurs parcelles) et par le sol relié au départ et à l'arrivée.
--
-- Branché par PathFinderModule.lua : startPathPlanningToNetwork (getFieldExitStart), startPathPlanningTo
-- (setupStrictChecks), isDriveableAstar / isDriveableDubins (isFieldPositionAllowed), smoothResultingPPPath_Refined
-- (isShortcutOffField). Aussi utilisé par FieldParkModule.lua et FollowCombineTask.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Sortie de champ par une destination du réseau
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.FIELD_EXIT_MAX_DISTANCE = 500 -- m, field point of the harvester mode used to leave the field

-- a vehicle on a field leaves it by a destination of the network instead of the closest point, which can
-- be past the crop or on another field: in harvester mode the field set as first destination, otherwise
-- the closest destination (up to FIELD_EXIT_MAX_DISTANCE) that leads to the target
function PathFinderModule:getFieldExitWayPoint(destinationId)
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    if not AutoDrive.checkIsOnField(x, y, z) then
        return nil
    end
    local function leadsToDestination(wayPointId)
        local wayPoint = wayPointId ~= nil and ADGraphManager:getWayPointById(wayPointId) or nil
        if wayPoint == nil or wayPointId == destinationId then
            return nil
        end
        local distance = MathUtil.vector2Length(wayPoint.x - x, wayPoint.z - z)
        if distance > PathFinderModule.FIELD_EXIT_MAX_DISTANCE then
            return nil
        end
        local route = ADGraphManager:pathFromTo(wayPointId, destinationId, nil, self.vehicle)
        if route == nil or #route < 2 then
            return nil
        end
        return distance
    end
    local stateModule = self.vehicle.ad.stateModule
    if stateModule:getMode() == AutoDrive.MODE_UNLOAD then
        local fieldWayPointId = stateModule:getFirstWayPoint()
        if leadsToDestination(fieldWayPointId) ~= nil then
            return fieldWayPointId
        end
    end
    -- closest destinations first, the route search only runs until one leads to the target
    local markers = {}
    for _, marker in pairs(ADGraphManager:getMapMarkers()) do
        local wayPoint = marker.id ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
        if wayPoint ~= nil then
            local distance = MathUtil.vector2Length(wayPoint.x - x, wayPoint.z - z)
            if distance <= PathFinderModule.FIELD_EXIT_MAX_DISTANCE then
                table.insert(markers, {id = marker.id, distance = distance, x = wayPoint.x, z = wayPoint.z})
            end
        end
    end
    -- destinations of the field the vehicle is on come first (their point is often just off the field edge)
    local area = PathFinderModule.getConnectedFieldArea(x, z)
    if area ~= nil then
        for _, marker in ipairs(markers) do
            marker.sameField = PathFinderModule.isNearFieldArea(area, marker.x, marker.z)
        end
    end
    table.sort(markers, function(a, b)
        if a.sameField ~= b.sameField then
            return a.sameField == true
        end
        return a.distance < b.distance
    end)
    for _, marker in ipairs(markers) do
        -- never a destination lying on a neighbouring field
        local onOtherField = not marker.sameField and AutoDrive.checkIsOnField(marker.x, 0, marker.z)
        if not onOtherField and leadsToDestination(marker.id) ~= nil then
            return marker.id
        end
    end
    return nil
end

-- accroche de startPathPlanningToNetwork : départ du trajet = la destination par laquelle le véhicule sort du champ
function PathFinderModule:getFieldExitStart(destinationId, closest)
    local fieldExit = self:getFieldExitWayPoint(destinationId)
    if fieldExit ~= nil then
        local exitMarker = ADGraphManager:getMapMarkerByWayPointId(fieldExit)
        print(string.format("[AD-Exit] %s: leaving the field by the destination point %s (%s) first", tostring(self.vehicle:getName()), tostring(fieldExit), exitMarker ~= nil and tostring(exitMarker.name) or "field"))
        closest = fieldExit
    end
    return closest
end

-- ------------------------------------------------------------------------------------------------------------
-- Contours des champs de la carte
-- ------------------------------------------------------------------------------------------------------------
-- field outlines of the map, with a bounding box each, read once
function PathFinderModule.getFieldOutlines()
    if PathFinderModule.fieldOutlines ~= nil then
        return PathFinderModule.fieldOutlines
    end
    local outlines = {}
    if g_fieldManager ~= nil and g_fieldManager.fields ~= nil and FieldPointGenerator ~= nil then
        for _, field in pairs(g_fieldManager.fields) do
            local points = FieldPointGenerator:getFieldWorldPoints(field)
            if points ~= nil and #points >= 3 then
                local outline = {field = field, points = points, minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge}
                for _, p in ipairs(points) do
                    outline.minX = math.min(outline.minX, p.x)
                    outline.maxX = math.max(outline.maxX, p.x)
                    outline.minZ = math.min(outline.minZ, p.z)
                    outline.maxZ = math.max(outline.maxZ, p.z)
                end
                table.insert(outlines, outline)
            end
        end
    end
    if #outlines > 0 then
        PathFinderModule.fieldOutlines = outlines
    end
    return outlines
end

-- field whose outline contains the position, nil if none
function PathFinderModule.getFieldAtPosition(x, z)
    for _, outline in ipairs(PathFinderModule.getFieldOutlines()) do
        if x >= outline.minX and x <= outline.maxX and z >= outline.minZ and z <= outline.maxZ then
            local inside = false
            local points = outline.points
            local j = #points
            for i = 1, #points do
                local pi, pj = points[i], points[j]
                if ((pi.z > z) ~= (pj.z > z)) and (x < (pj.x - pi.x) * (z - pi.z) / (pj.z - pi.z) + pi.x) then
                    inside = not inside
                end
                j = i
            end
            if inside then
                return outline.field
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Sol de champ relié (deux champs ne comptent pour un que si leur sol se touche)
-- ------------------------------------------------------------------------------------------------------------
-- connected field ground: flood fill of the on-field samples around a position. Two fields count as one
-- only if their ground touches, a grass strip or a road between them splits them
PathFinderModule.FIELD_AREA_STEP = 4
PathFinderModule.FIELD_AREA_MAX_SAMPLES = 60000
PathFinderModule.FIELD_AREA_CACHE_TIME = 600000
PathFinderModule.fieldAreaCache = {}

function PathFinderModule.getFieldAreaKey(ix, iz)
    return (ix + 50000) * 100000 + (iz + 50000)
end

function PathFinderModule.isInFieldArea(area, x, z)
    local step = PathFinderModule.FIELD_AREA_STEP
    local ix, iz = math.floor(x / step + 0.5), math.floor(z / step + 0.5)
    if area.cells[PathFinderModule.getFieldAreaKey(ix, iz)] then
        return true
    end
    -- position on the field edge, the nearest sample is off the field: look at the samples around it
    if not AutoDrive.checkIsOnField(ix * step, 0, iz * step) then
        for dx = -1, 1 do
            for dz = -1, 1 do
                if area.cells[PathFinderModule.getFieldAreaKey(ix + dx, iz + dz)] then
                    return true
                end
            end
        end
    end
    return false
end

PathFinderModule.FIELD_EDGE_DISTANCE = 12 -- m, a point this close to the field ground belongs to the field

function PathFinderModule.isNearFieldArea(area, x, z)
    local step = PathFinderModule.FIELD_AREA_STEP
    local range = math.ceil(PathFinderModule.FIELD_EDGE_DISTANCE / step)
    local ix, iz = math.floor(x / step + 0.5), math.floor(z / step + 0.5)
    for dx = -range, range do
        for dz = -range, range do
            if (dx * dx + dz * dz) * step * step <= PathFinderModule.FIELD_EDGE_DISTANCE ^ 2 and area.cells[PathFinderModule.getFieldAreaKey(ix + dx, iz + dz)] then
                return true
            end
        end
    end
    return false
end

function PathFinderModule.getConnectedFieldArea(x, z)
    local step = PathFinderModule.FIELD_AREA_STEP
    local getKey = PathFinderModule.getFieldAreaKey
    local sx, sz = math.floor(x / step + 0.5), math.floor(z / step + 0.5)
    local seedX, seedZ
    for r = 0, 2 do
        for dx = -r, r do
            for dz = -r, r do
                if seedX == nil and math.max(math.abs(dx), math.abs(dz)) == r and AutoDrive.checkIsOnField((sx + dx) * step, 0, (sz + dz) * step) then
                    seedX, seedZ = sx + dx, sz + dz
                end
            end
        end
        if seedX ~= nil then
            break
        end
    end
    if seedX == nil then
        return nil
    end
    local seedKey = getKey(seedX, seedZ)
    local now = g_time or 0
    local cache = PathFinderModule.fieldAreaCache
    for i = #cache, 1, -1 do
        if now - cache[i].time > PathFinderModule.FIELD_AREA_CACHE_TIME or now < cache[i].time then
            table.remove(cache, i)
        elseif cache[i].cells[seedKey] then
            return cache[i]
        end
    end
    local area = {cells = {}, count = 0, capped = false, time = now}
    local visited = {[seedKey] = true}
    local queue = {seedX, seedZ}
    local head = 1
    while head < #queue do
        local ix, iz = queue[head], queue[head + 1]
        head = head + 2
        area.cells[getKey(ix, iz)] = true
        area.count = area.count + 1
        if area.count >= PathFinderModule.FIELD_AREA_MAX_SAMPLES then
            area.capped = true
            break
        end
        for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
            local nx, nz = ix + d[1], iz + d[2]
            local key = getKey(nx, nz)
            if not visited[key] then
                visited[key] = true
                if AutoDrive.checkIsOnField(nx * step, 0, nz * step) then
                    table.insert(queue, nx)
                    table.insert(queue, nz)
                end
            end
        end
    end
    table.insert(cache, area)
    if #cache > 8 then
        table.remove(cache, 1)
    end
    return area
end

-- ------------------------------------------------------------------------------------------------------------
-- Restriction au champ d'une position (normal et strict)
-- ------------------------------------------------------------------------------------------------------------
-- field restriction for one position: normal mode = only on a field, strict mode = anywhere but on another field
PathFinderModule.OFF_FIELD_NEAR_ENDS = 12
PathFinderModule.OFF_FIELD_MAX_DISTANCE = 8

-- grass strip along a field: field ground within OFF_FIELD_MAX_DISTANCE
function PathFinderModule:isNearFieldGround(x, z)
    self.nearFieldCache = self.nearFieldCache or {}
    local key = string.format("%d|%d", math.floor(x), math.floor(z))
    local cached = self.nearFieldCache[key]
    if cached ~= nil then
        return cached
    end
    local result = false
    for _, d in ipairs({PathFinderModule.OFF_FIELD_MAX_DISTANCE / 2, PathFinderModule.OFF_FIELD_MAX_DISTANCE}) do
        for i = 0, 7 do
            local a = i * math.pi / 4
            if AutoDrive.checkIsOnField(x + math.cos(a) * d, 0, z + math.sin(a) * d) then
                result = true
                break
            end
        end
        if result then
            break
        end
    end
    self.nearFieldCache[key] = result
    return result
end
function PathFinderModule:isFieldPositionAllowed(x, z, isOnField)
    if isOnField == nil then
        isOnField = PathFinderModule.getMapOnFieldAt(x, z)
    end
    if not self.strictField then
        return isOnField or self.parkOnGrass == true
    end
    if not isOnField and self.parkOnGrass then
        -- forage harvester, full unloader parking aside: the grass beside the field is allowed (obstacles checked)
        return true
    end
    if not isOnField then
        -- finer grids find gaps on the grass between trees AutoDrive does not always see: stay on field ground,
        -- except around the start and the target (the vehicle may wait on the grass beside the field)
        -- strict: the field ground only, whatever the grid, except around the start and the target
        local near = PathFinderModule.OFF_FIELD_NEAR_ENDS
        local nearStart = self.startX ~= nil and MathUtil.vector2Length(x - self.startX, z - self.startZ) < near
        local nearTarget = self.target ~= nil and MathUtil.vector2Length(x - self.target.x, z - self.target.z) < near
        return nearStart or nearTarget
    end
    -- the unloader may stand at the entrance on ground taken for another field: the first meters from where it
    -- stands are never refused for another field
    if self.startX ~= nil and MathUtil.vector2Length(x - self.startX, z - self.startZ) < PathFinderModule.OFF_FIELD_NEAR_ENDS then
        return true
    end
    if self.allowedAreas ~= nil and next(self.allowedAreas) ~= nil then
        local capped = false
        for area, _ in pairs(self.allowedAreas) do
            if PathFinderModule.isInFieldArea(area, x, z) then
                return true
            end
            capped = capped or area.capped
        end
        if not capped then
            return false
        end
    end
    if self.allowedFields ~= nil and next(self.allowedFields) ~= nil then
        local field = PathFinderModule.getFieldAtPosition(x, z)
        if field ~= nil then
            return self.allowedFields[field] == true
        end
        -- cultivated ground outside every field outline: allowed if it lies on one of our farmlands
    end
    return self.allowedFarmlands ~= nil and self.allowedFarmlands[g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)] == true
end

-- side of the train along the field border (strict): the grass beside the field is allowed, only the ground of another field is refused,
-- the centre line of the route is checked by isFieldPositionAllowed. Returns allowed, onOtherField
function PathFinderModule:isTrainSideAllowed(x, z)
    local isOnField = PathFinderModule.getMapOnFieldAt(x, z)
    if self.strictField and not isOnField then
        return true, false
    end
    return self:isFieldPositionAllowed(x, z, isOnField), isOnField
end

-- ------------------------------------------------------------------------------------------------------------
-- Réglages stricts au départ d'un trajet
-- ------------------------------------------------------------------------------------------------------------
-- accroche de startPathPlanningTo (après le réglage avoidFruit)
function PathFinderModule:setupStrictChecks(vehicleWorldX, vehicleWorldZ, targetX, targetZ)
    -- strict settings are never dropped by the fallback modes, whatever the trip
    self.strictField = AutoDrive.getSetting("restrictToField", self.vehicle) == "strict"
    self.strictFruit = self.avoidFruitSetting == "strict"
    if self.allowCrop then
        -- crop avoided first, crossed only by the fallback (the caller lifts noFallback)
        self.strictFruit = false
    end
    if self.strictField then
        -- strict: never drive on another field, wherever the trip starts or ends. Ground that is not a field (grass, verges) stays allowed
        self.restrictToField = true
        -- the field is identified by the map's field outline, a field can lie on several farmlands
        self.allowedFields = {}
        self.allowedFarmlands = {}
        for _, pos in ipairs({{x = vehicleWorldX, z = vehicleWorldZ, onField = self.startIsOnField}, {x = targetX, z = targetZ, onField = self.endIsOnField}}) do
            if pos.onField then
                local field = PathFinderModule.getFieldAtPosition(pos.x, pos.z)
                if field ~= nil then
                    self.allowedFields[field] = true
                end
                self.allowedFarmlands[g_farmlandManager:getFarmlandIdAtWorldPosition(pos.x, pos.z)] = true
            end
        end
        -- the field ground actually connected to the start and to the target, outlines and farmlands do not always match the worked field
        self.allowedAreas = {}
        for _, pos in ipairs({{x = vehicleWorldX, z = vehicleWorldZ}, {x = targetX, z = targetZ}}) do
            local area = PathFinderModule.getConnectedFieldArea(pos.x, pos.z)
            if area ~= nil then
                self.allowedAreas[area] = true
                PathFinderModule.debugMsg(self.vehicle, "PFM:startPathPlanningTo strict field area xz %.1f,%.1f samples %d capped %s", pos.x, pos.z, area.count, tostring(area.capped))
            end
        end
    end
    self.islandCache = {}
    self.strictFruitRefusals = 0
    self.mapReadsAtStart = PathFinderModule.fieldMapReads
    PathFinderModule.searchCells = {}
end

-- ------------------------------------------------------------------------------------------------------------
-- Raccourci du lissage : rester sur le champ
-- ------------------------------------------------------------------------------------------------------------
-- accroche de smoothResultingPPPath_Refined (restrictToField) : true = le raccourci sort du champ
function PathFinderModule:isShortcutOffField(node, vectorX, vectorZ, leftAngle)
    local hasCollision = false
    local halfWidth = (self.trainHalfWidth or 3) - PathFinderModule.FRUIT_CHECK_CORRIDOR_MARGIN
    local sideX, sideZ = math.cos(leftAngle) * halfWidth, -math.sin(leftAngle) * halfWidth
    for _, t in ipairs({0, 0.5, 1}) do
        local px, pz = node.x + vectorX * t, node.z + vectorZ * t
        if not self:isTrainSideAllowed(px + sideX, pz + sideZ) or not self:isTrainSideAllowed(px - sideX, pz - sideZ) then
            hasCollision = true
            break
        end
    end

    if hasCollision then
        if self.vehicle ~= nil and self.vehicle.ad ~= nil and self.vehicle.ad.debug ~= nil and AutoDrive.debugVehicleMsg ~= nil then
            PathFinderModule.debugVehicleMsg(self.vehicle,
                string.format("PFM smoothResultingPPPath_Refined hasCollision %d",
                    10
                )
            )
        end
    end
    return hasCollision
end
