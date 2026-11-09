-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleObstacles.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : la place est-elle libre ? Terrain et obstacles.
--
-- Règle :
-- - terrain : chaque point comparé à la route juste à côté (pas à la hauteur où je suis, 28/10), MAX_ROAD_HEIGHT_DIFF
--   et MAX_SLOPE_DIFF au plus ; pas d'eau ; champ noté (ou refusé au 1er passage de la recherche droite) ;
-- - obstacles : boîte de 0,6 à 3,2 m au-dessus du sol (les bordures basses ne comptent pas), formes réelles (exactTest) ;
--   sur tout le trajet, aussi sa partie encore sur la route, où seuls les objets fixes comptent (30/10) ;
-- - ignorés : moi et mon attelage, le véhicule mis de côté (overlapIgnoreVehicle, demi-tour en bout de rang 23/10), les
--   bordures de champ, les panneaux, les formes avec lesquelles le véhicule ne peut pas entrer en collision.
--
-- Branché par : searchSpotAlongRoute (isPathFree), searchParkingSpotStraight (isSpotFree) ; overlapHit sert aussi à
-- FieldParkModule, BandTurnModule, PathFinderModulePark, PathFinderModuleGuided et FollowCombineTaskChopperUTurn
-- (avec le module du véhicule).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Trajet de rangement libre ?
-- ------------------------------------------------------------------------------------------------------------
-- checks a parallel path: terrain, water, field and obstacles along it (the vehicle body width)
-- returns free, onField, why (refusal reason: "hauteur", "pente", "eau", "objet <name>")
function ADTrafficYieldModule:isPathFree(points, width, roadY, py)
    local halfW = width / 2 + 0.2
    local onField = false
    -- terrain / water / field on the points first (cheap)
    for _, p in ipairs(points) do
        local h = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p.x, py, p.z)
        -- 28/10 (Patriot on the 7 % farm track): compared with the road right beside the point, not with
        -- the height where I stand (12 m further on a 7 % slope is already 0.9 m)
        local roadH = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p.x - p.dirZ * p.offset, py, p.z + p.dirX * p.offset)
        if math.abs(h - roadH) > ADTrafficYieldModule.MAX_ROAD_HEIGHT_DIFF then
            return false, false, string.format("hauteur (%.1f m)", h - roadH)
        end
        -- lateral slope of the strip
        local lx, lz = p.x + p.dirZ * halfW, p.z - p.dirX * halfW
        local rx, rz = p.x - p.dirZ * halfW, p.z + p.dirX * halfW
        local hl = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, lx, py, lz)
        local hr = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, rx, py, rz)
        if math.abs(hl - hr) > ADTrafficYieldModule.MAX_SLOPE_DIFF then
            return false, false, string.format("pente (%.1f m)", math.abs(hl - hr))
        end
        if g_currentMission.environmentAreaSystem ~= nil and g_currentMission.environmentAreaSystem.getWaterYAtWorldPosition ~= nil then
            local waterY = g_currentMission.environmentAreaSystem:getWaterYAtWorldPosition(p.x, h, p.z)
            if waterY ~= nil and waterY > h - 0.2 then
                return false, false, "eau"
            end
        end
        if p.offset ~= 0 and AutoDrive.checkIsOnField(p.x, h, p.z) then
            onField = true
        end
    end
    -- obstacles: one box per path segment, oriented along it
    -- 30/10 (C, 942 Vario against the railing of a bridge): the whole path, also its part still over the road;
    -- there only fixed objects count (vehicles on the road are the traffic, checked apart)
    for k = 1, #points - 1 do
        local a, b = points[k], points[k + 1]
        local onRoad = math.abs(b.offset) <= halfW
        local dx, dz = b.x - a.x, b.z - a.z
        local segLength = math.max(0.1, MathUtil.vector2Length(dx, dz))
        local mx, mz = (a.x + b.x) / 2, (a.z + b.z) / 2
        local h = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, mx, py, mz)
        if self:overlapHit(mx, h + 1.9, mz, math.atan2(dx, dz), halfW, 1.3, segLength / 2 + 0.2) and not (onRoad and self.overlapHitVehicle) then
            return false, onField, "objet " .. tostring(self.overlapHitName)
        end
    end
    return true, onField
end

-- ------------------------------------------------------------------------------------------------------------
-- Place libre ? (recherche droite, depuis l'axe du véhicule)
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:isSpotFree(px, py, pz, dirX, dirZ, forward, lateral, width, frontExtent, totalLength, allowField, runOut)
    local ry = math.atan2(dirX, dirZ)
    -- frame of the road at (px, pz) heading (dirX, dirZ); GIANTS local +x is left = (dirZ, -dirX)
    local function toWorld(lateralOffset, forwardOffset)
        return px + dirX * forwardOffset + dirZ * lateralOffset, py, pz + dirZ * forwardOffset - dirX * lateralOffset
    end
    local sign = lateral >= 0 and 1 or -1

    -- 1. final footprint of the whole train (tractor front at forward + tractorLength / 2)
    -- final position: tractor at the end of the straight run, whole train lined up behind it
    local frontZ = forward + (runOut or 0) + frontExtent
    local centerZ = frontZ - totalLength / 2
    local fx, _, fz = toWorld(lateral, centerZ)
    local roadY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, px, py, pz)

    -- terrain check on the footprint corners
    local minH, maxH = math.huge, -math.huge
    local halfW = width / 2 + 0.2
    local halfL = totalLength / 2 + 0.3
    local onField = false
    local roadDiff = 0
    local slopeDiff = 0
    for _, corner in ipairs({{-1, -1}, {-1, 1}, {1, -1}, {1, 1}, {0, 0}}) do
        local cx, _, cz = toWorld(lateral + corner[1] * halfW, centerZ + corner[2] * halfL)
        local h = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, py, cz)
        minH = math.min(minH, h)
        maxH = math.max(maxH, h)
        -- 28/10: each corner against the road right beside it (on a slope the road itself rises)
        local bx, _, bz = toWorld(0, centerZ + corner[2] * halfL)
        roadDiff = math.max(roadDiff, math.abs(h - getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, bx, py, bz)))
        if not allowField and AutoDrive.checkIsOnField(cx, h, cz) then
            onField = true
        end
    end
    if onField then
        return false
    end
    -- lateral slope of the footprint: left against right corners, the slope along the road does not count
    for _, f in ipairs({-1, 1}) do
        local ax, _, az = toWorld(lateral - halfW, centerZ + f * halfL)
        local bx, _, bz = toWorld(lateral + halfW, centerZ + f * halfL)
        slopeDiff = math.max(slopeDiff, math.abs(getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, ax, py, az) - getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, bx, py, bz)))
    end
    if slopeDiff > ADTrafficYieldModule.MAX_SLOPE_DIFF or roadDiff > ADTrafficYieldModule.MAX_ROAD_HEIGHT_DIFF then
        return false
    end

    -- water check
    if g_currentMission.environmentAreaSystem ~= nil and g_currentMission.environmentAreaSystem.getWaterYAtWorldPosition ~= nil then
        local waterY = g_currentMission.environmentAreaSystem:getWaterYAtWorldPosition(fx, roadY, fz)
        if waterY ~= nil and waterY > minH - 0.2 then
            return false
        end
    end

    -- box from 0.6 m to 3.2 m above the ground: low road borders / curbs are ignored
    local fy = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, fx, py, fz) + 1.9
    if self:overlapHit(fx, fy, fz, ry, halfW, 1.3, halfL) then
        return false
    end

    -- 2. swerve corridor, roadside part only (from the side of my own lane to the spot)
    local corridorStart = frontExtent
    local corridorEnd = frontZ
    local corridorHalfL = (corridorEnd - corridorStart) / 2
    local innerEdge = width / 2 + 0.2
    local outerEdge = math.abs(lateral) + width / 2
    if corridorHalfL > 0.5 and outerEdge > innerEdge then
        local corridorCenterX = sign * (innerEdge + outerEdge) / 2
        local corridorHalfW = (outerEdge - innerEdge) / 2
        local cx, _, cz = toWorld(corridorCenterX, corridorStart + corridorHalfL)
        if self:overlapHit(cx, fy, cz, ry, corridorHalfW, 1.3, corridorHalfL) then
            return false
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Obstacles dans une boîte
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:overlapHit(x, y, z, ry, halfX, halfY, halfZ)
    self.overlapHitCount = 0
    self.overlapHitName = nil
    self.overlapHitVehicle = nil
    local mask = CollisionFlag.STATIC_OBJECT + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.VEHICLE + CollisionFlag.TREE + CollisionFlag.BUILDING + CollisionFlag.TRAFFIC_VEHICLE + CollisionFlag.TRAFFIC_VEHICLE_BLOCKING
    overlapBox(x, y, z, 0, ry, 0, halfX, halfY, halfZ, "overlapCallback", self, mask, true, true, true, true) -- dynamics, kinematics, statics, exactTest (real geometry, not the bounding box)
    return self.overlapHitCount > 0
end

function ADTrafficYieldModule:overlapCallback(transformId)
    if transformId == nil or transformId == 0 or transformId == g_currentMission.terrainRootNode then
        return true
    end
    local object = g_currentMission:getNodeObject(transformId)
    if object == nil then
        local parent = getParent(transformId)
        if parent ~= nil and parent ~= 0 then
            object = g_currentMission:getNodeObject(parent)
        end
    end
    if object ~= nil and (object == self.vehicle or AutoDrive:checkIsConnected(self.vehicle:getRootVehicle(), object)) then
        return true -- ignore myself
    end
    local ignored = self.overlapIgnoreVehicle
    if object ~= nil and ignored ~= nil and (object == ignored or (ignored.getRootVehicle ~= nil and AutoDrive:checkIsConnected(ignored:getRootVehicle(), object))) then
        return true -- vehicle left out of this reading (end-of-row U-turn: the harvester, 23/10)
    end
    if object == nil then
        if ADTrafficYieldModule.IGNORED_SHAPE_NAMES[getName(transformId)] then
            return true -- field border
        end
        if ADSensor ~= nil and ADSensor.isElementBlockingVehicle ~= nil and not ADSensor:isElementBlockingVehicle(transformId) then
            return true -- traffic sign etc.
        end
        -- only keep the shapes the vehicle would physically collide with
        if not self:isShapeBlockingVehicle(transformId) then
            return true
        end
    end

    self.overlapHitCount = self.overlapHitCount + 1
    self.overlapHitName = object ~= nil and object.getName ~= nil and object:getName() or getName(transformId)
    self.overlapHitVehicle = object ~= nil and object.getRootVehicle ~= nil
    return false -- blocked, no need to look further
end

-- compares the collision filter of the shape with the one of the vehicle (FS25 physics rule:
-- two shapes collide when groupA & maskB ~= 0 and groupB & maskA ~= 0)
function ADTrafficYieldModule:isShapeBlockingVehicle(shapeId)
    if getCollisionFilterGroup == nil or getCollisionFilterMask == nil or bitAND == nil then
        return true
    end
    local ok, shapeGroup, shapeMask, vehGroup, vehMask = pcall(function()
        local vehicleNode = self.vehicle.components[1].node
        return getCollisionFilterGroup(shapeId), getCollisionFilterMask(shapeId), getCollisionFilterGroup(vehicleNode), getCollisionFilterMask(vehicleNode)
    end)
    if not ok or shapeGroup == nil or shapeMask == nil or vehGroup == nil or vehMask == nil then
        return true
    end
    return bitAND(shapeGroup, vehMask) ~= 0 and bitAND(vehGroup, shapeMask) ~= 0
end
