-- ============================================================================================================
-- FarmPilot : FieldParkModuleEntrance.lua
-- Complément de FieldParkModule.lua : l'entrée du champ (moissonneuse et ensileuse).
--
-- Règles :
-- - champ complet (FIELD_CAPACITY bennes au champ pour cette machine) : les suivantes se garent au bord d'une route
--   d'AutoDrive près de l'entrée (ROADSIDE_RANGE), parallèles à la route, hors des champs, le nez vers l'entrée ; la
--   première arrivée entre la première quand une place se libère ;
-- - 25/10 : entrée partagée par une benne pleine qui sort et une benne vide qui entre (7R et 942 nez à nez) : celle
--   qui entre cède le passage, elle s'arrête sur la route avant l'entrée jusqu'à ce que la pleine soit sortie (au
--   plus EXIT_YIELD_TIMEOUT ; EXIT_ON_POINT_TIMEOUT pour une benne arrêtée sur le point de sortie lui-même).
--
-- Branché par : WaitForCallTaskRoadside.lua (findRoadsideSpots, isFirstOnRoadside) ; CatchCombinePipeTask:update,
-- WaitForCallTaskFieldPark.lua et DriveToDestinationTaskFieldEntrance.lua (holdForExit) ; ExitFieldTaskExitPoints.lua
-- (publishFieldExit et abortFieldExit -> setFieldExit, isExitPointBlocked -> isExitPointTaken).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFieldPark.FIELD_CAPACITY = 2                      -- unloaders parked in the field for one harvester; the next ones wait beside the road
ADFieldPark.ROADSIDE_MIN = 15                       -- m kept free in front of the entrance
ADFieldPark.ROADSIDE_STEP = 5                       -- m between two places tried along a road

-- field entrance shared by a full unloader driving out and an empty one coming in (25/10, 7R and 942 nose to
-- nose at the entrance): the one coming in gives way, it stops on the road before the entrance until the full one is out
ADFieldPark.EXIT_YIELD_RADIUS = 45                  -- m around the network point a full unloader drives out to
ADFieldPark.EXIT_YIELD_DONE = 10                    -- m: the full unloader this close to its point is out of the field
ADFieldPark.EXIT_YIELD_RANGE = 250                  -- m: a full unloader further from its point is not waited for
ADFieldPark.EXIT_YIELD_STALE = 3000                 -- ms: exit point not refreshed for this long (task ended, AutoDrive stopped)
ADFieldPark.EXIT_YIELD_TIMEOUT = 120000             -- ms waited at most for one full unloader
ADFieldPark.EXIT_POINT_TAKEN = 12                   -- m: a vehicle standing this close to the exit point blocks it
ADFieldPark.EXIT_ON_POINT_TIMEOUT = 15000           -- ms waited at most by a vehicle standing on the exit point itself (the full one looks for another point meanwhile)

-- ------------------------------------------------------------------------------------------------------------
-- Champ complet : attente au bord de la route
-- ------------------------------------------------------------------------------------------------------------
-- first one waiting beside the road for this harvester (order of arrival)
function ADFieldPark.isFirstOnRoadside(vehicle, harvester)
    local mine = vehicle.ad ~= nil and vehicle.ad.unloaderQueueTime or math.huge
    for other, spot in pairs(ADFieldPark.parked) do
        if other ~= vehicle and spot ~= nil and spot.roadside and spot.harvester == harvester and other.isDeleted ~= true then
            local t = other.ad ~= nil and other.ad.unloaderQueueTime or math.huge
            if t < mine then
                return false
            end
        end
    end
    return true
end

-- places beside the AutoDrive roads within ADFieldPark.ROADSIDE_RANGE of the entrance (x, z), parallel to the road,
-- the whole train off every road line, off the fields, on flat free ground, nearest to the entrance first
function ADFieldPark.findRoadsideSpots(vehicle, harvester, x, z)
    ADTrafficYieldModule.measureTrain(vehicle)
    local front, rear = ADTrafficYieldModule.getTrainExtents(vehicle)
    local length = front + rear
    local halfW = ADTrafficYieldModule.getWidth(vehicle) / 2 + 0.5
    local halfL = length / 2 + 0.5
    local range = ADFieldPark.ROADSIDE_RANGE
    local nearby = ADFieldPark.getWayPointsAround(x, z, range + length + 20)
    local probe = {vehicle = vehicle, halfW = halfW, halfL = halfL}
    local candidates = {}
    for _, wp in ipairs(nearby) do
        for _, id in pairs(wp.out or {}) do
            local nb = ADGraphManager:getWayPointById(id)
            local segment = nb ~= nil and MathUtil.vector2Length(nb.x - wp.x, nb.z - wp.z) or 0
            if segment > 0.5 then
                local tx, tz = (nb.x - wp.x) / segment, (nb.z - wp.z) / segment
                for along = 0, segment, ADFieldPark.ROADSIDE_STEP do
                    local rx, rz = wp.x + tx * along, wp.z + tz * along
                    for _, side in ipairs({1, -1}) do
                        local nx, nz = tz * side, -tx * side
                        local cx, cz = rx + nx * (ADFieldPark.ROAD_HALF_WIDTH + halfW), rz + nz * (ADFieldPark.ROAD_HALF_WIDTH + halfW)
                        local distance = MathUtil.vector2Length(cx - x, cz - z)
                        if distance >= ADFieldPark.ROADSIDE_MIN + halfL and distance <= range then
                            -- nose toward the entrance, to drive in when a place in the field is free
                            local dx, dz = tx, tz
                            if dx * (x - cx) + dz * (z - cz) < 0 then
                                dx, dz = -dx, -dz
                            end
                            table.insert(candidates, {cx = cx, cz = cz, dx = dx, dz = dz, distance = distance})
                        end
                    end
                end
            end
        end
    end
    table.sort(candidates, function(c1, c2) return c1.distance < c2.distance end)
    local spots = {}
    for _, c in ipairs(candidates) do
        if ADFieldPark.isRoadsideFree(vehicle, probe, c, nearby, halfW, halfL) then
            local shift = length / 2 - front
            local tx, tz = c.cx + c.dx * shift, c.cz + c.dz * shift
            table.insert(spots, {
                x = tx, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, tx, 0, tz), z = tz,
                dirX = c.dx, dirZ = c.dz, cx = c.cx, cz = c.cz, halfL = halfL,
                roadside = true, harvester = harvester, entrance = {x = x, z = z}, distance = c.distance
            })
            if #spots >= ADFieldPark.MAX_TRIES then
                break
            end
        end
    end
    return spots
end

function ADFieldPark.isRoadsideFree(vehicle, probe, c, nearby, halfW, halfL)
    if ADFieldPark.overlapsTakenSpot(probe, c.cx, c.cz, c.dx, c.dz) then
        return false
    end
    for _, wp in ipairs(nearby) do
        if ADFieldPark.distanceToFootprint(wp.x, wp.z, c.cx, c.cz, c.dx, c.dz, halfW, halfL) < ADFieldPark.ROAD_HALF_WIDTH then
            return false
        end
    end
    local minH, maxH = math.huge, -math.huge
    for _, p in ipairs(ADFieldPark.getOutline(c.cx, c.cz, c.dx, c.dz, halfW, halfL)) do
        local h = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p[1], 0, p[2])
        minH, maxH = math.min(minH, h), math.max(maxH, h)
        if AutoDrive.checkIsOnField(p[1], h, p[2]) then
            return false
        end
    end
    if maxH - minH > ADTrafficYieldModule.MAX_SLOPE_DIFF then
        return false
    end
    if vehicle.ad.trafficYieldModule:overlapHit(c.cx, maxH + 1.9, c.cz, math.atan2(c.dx, c.dz), halfW, 1.3, halfL) then
        return false
    end
    c.maxH = maxH
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Entrée partagée : la benne qui entre cède le passage à la benne pleine qui sort
-- ------------------------------------------------------------------------------------------------------------
-- full unloader driving out of the field to the network point (x, z), refreshed each frame by ExitFieldTask
function ADFieldPark.setFieldExit(vehicle, x, z)
    if x == nil then
        vehicle.ad.fieldExit = nil
    else
        vehicle.ad.fieldExit = {x = x, z = z, t = g_time or 0}
    end
end

-- another unloader driving out to a network point near this vehicle and not out yet: the vehicle, its distance to
-- the point and this vehicle's distance to it
function ADFieldPark.getExitInWay(vehicle)
    local all = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    for _, other in pairs(all) do
        local exit = other ~= vehicle and other.ad ~= nil and other.isDeleted ~= true and other.ad.fieldExit or nil
        if exit ~= nil and (g_time or 0) - exit.t < ADFieldPark.EXIT_YIELD_STALE then
            local mine = MathUtil.vector2Length(x - exit.x, z - exit.z)
            if mine < ADFieldPark.EXIT_YIELD_RADIUS then
                local ox, _, oz = getWorldTranslation(other.components[1].node)
                local left = MathUtil.vector2Length(ox - exit.x, oz - exit.z)
                if left > ADFieldPark.EXIT_YIELD_DONE and left < ADFieldPark.EXIT_YIELD_RANGE then
                    return other, left, mine
                end
            end
        end
    end
    return nil
end

-- true while the vehicle must hold (stopped) for a full unloader coming out; logs once per full unloader
function ADFieldPark.holdForExit(vehicle, dt, where)
    local other, left, mine = ADFieldPark.getExitInWay(vehicle)
    local hold = vehicle.ad.exitYield
    if other == nil then
        if hold ~= nil then
            print(string.format("[AD-Entree] %s: %s est sorti, j'y vais (attendu %d s)", tostring(vehicle:getName()), tostring(hold.name), math.floor(hold.waited / 1000)))
            vehicle.ad.exitYield = nil
        end
        return false
    end
    if hold == nil or hold.other ~= other then
        hold = {other = other, name = other:getName(), waited = 0}
        vehicle.ad.exitYield = hold
        print(string.format("[AD-Entree] %s: %s sort plein par l'entree (encore %.0f m), je l'attends %s a %.0f m de l'entree", tostring(vehicle:getName()), tostring(hold.name), left, where, mine))
    end
    hold.waited = hold.waited + dt
    local limit = mine < ADFieldPark.EXIT_POINT_TAKEN and ADFieldPark.EXIT_ON_POINT_TIMEOUT or ADFieldPark.EXIT_YIELD_TIMEOUT
    if hold.waited > limit then
        if not hold.gaveUp then
            hold.gaveUp = true
            print(string.format("[AD-Entree] %s: %s toujours pas sorti apres %d s, je n'attends plus", tostring(vehicle:getName()), tostring(hold.name), limit / 1000))
        end
        return false
    end
    vehicle.ad.specialDrivingModule:stopVehicle()
    vehicle.ad.specialDrivingModule:update(dt)
    return true
end

-- a vehicle other than this one standing on the network point (x, z): an unloader waiting there for its call
function ADFieldPark.isExitPointTaken(vehicle, x, z)
    local all = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, other in pairs(all) do
        if other ~= vehicle and other.ad ~= nil and other.isDeleted ~= true and other.components ~= nil and other.getRootVehicle ~= nil
            and other:getRootVehicle() == other and (other.lastSpeedReal or 0) < 0.0005 and other.ad.stateModule ~= nil
            and other.ad.stateModule:isActive() then
            local ox, _, oz = getWorldTranslation(other.components[1].node)
            if MathUtil.vector2Length(ox - x, oz - z) < ADFieldPark.EXIT_POINT_TAKEN then
                return other
            end
        end
    end
    return nil
end
