ADPathCalculator = {}

ADPathCalculator.MAX_ITERATIONS = 10000000

-- vehicle (optional): sections where its train does not fit (wall, tree, post, building, bridge railing
-- closer than half its width + margin) get a big extra weight, so another route is taken when one exists
-- banned (optional): turns not to take, banned[from .. ":" .. at .. ":" .. to] = true (waypoint ids), e.g. the end of a
-- route the train cannot turn into (ADCornerModule:avoidTightEnd)
function ADPathCalculator:GetPath(startID, targetID, preferredStartIds, vehicle, banned)
	local count = 0
	local countIterations = 0
    local narrowWeight = self:getNarrowWeightFunc(vehicle)

    if not ADGraphManager:areWayPointsPrepared() then
        ADPathCalculator.widthCache = {} -- network changed: measure again
        ADPathCalculator.narrowSections = {}
        ADPathCalculator.narrowInfo = {}
		AutoDrive.checkWaypointsLinkedtothemselve(true)		-- find WP linked to themselve, with parameter true issues will be fixed
		AutoDrive.checkWaypointsMultipleSameOut(true)		-- find WP with multiple same out ID, with parameter true issues will be fixed
        ADGraphManager:prepareWayPoints()
    end

    local network = ADGraphManager:getWayPoints()
    local addedWeights = self:getDetourWeights()
    
    if startID == nil or targetID == nil or network[startID] == nil or network[targetID] == nil then
        return {}
    end

    if startID == targetID then
        return {network[startID]}
    end

    local candidates = SortedQueue:new("distance")
    candidates:enqueue({p=network[startID], distance=0, pre=-1})

    local results = {}

    local foundTarget = false
    local sqrt = math.sqrt
    local distanceFunc = function(a, b, c)
        return sqrt((a.x - b.x)* (a.x - b.x) + (a.z - b.z) * (a.z - b.z))
    end
    local distanceFunc2 = function(a, b, c)
        return ADGraphManager:getDriveTimeBetweenNodes(a.id, b.id, c, 30, true)
    end
    -- chemins de terre : temps de trajet à leur vitesse maxi, x100 pour un véhicule « Jamais » (DirtRoadManager.lua)
    if ADDirtRoads ~= nil then distanceFunc2 = ADDirtRoads.wrapDriveTime(distanceFunc2, vehicle) end

    local isSubPrio = function(pointToTest) 
        return bit32.band(pointToTest.flags, AutoDrive.FLAG_SUBPRIO) > 0
    end

    local lastPredecessor = nil
    while not candidates:empty() and not foundTarget and (countIterations < ADPathCalculator.MAX_ITERATIONS) do
        countIterations = countIterations + 1
        local next = candidates:dequeue()
        local point, distance, previousPoint = next.p, next.distance, next.pre
        while point ~= nil and (countIterations < ADPathCalculator.MAX_ITERATIONS) do
            countIterations = countIterations + 1
            if results[point.id] == nil then
                results[point.id] = {}
            end
            if point.id == targetID then
                foundTarget = true
                lastPredecessor = previousPoint
                point = nil
                break
            else
                -- Check all out points if
                -- a) is startpoint
                -- b) has multiple incoming routes? (Because we could have followed the wrong path to that intersection after all, I guess)
                -- c) we have multiple outgoing routes (coming from previousPoint)
                if previousPoint == -1 or #point.incoming > 1 or (point.transitMapping[previousPoint] == nil or #point.transitMapping[previousPoint] > 1) then
                    
                    -- use either the default .out variable of each point or preferably, use the transitMapping 
                    local outMap = point.out
                    if previousPoint ~= -1 and point.transitMapping[previousPoint] ~= nil then
                        outMap = point.transitMapping[previousPoint]
                    end

                    for _, outId in pairs(outMap) do
                        countIterations = countIterations + 1
                        if (countIterations > ADPathCalculator.MAX_ITERATIONS) then
                            -- emergency exit
                            return {}
                        end
                        local outPoint = network[outId]
                        if banned ~= nil and previousPoint ~= -1 and banned[previousPoint .. ":" .. point.id .. ":" .. outId] then
                            outPoint = nil
                        end
                        if outPoint ~= nil then
                        
                        -- Add this out point into our results table with the current distance
                        if results[point.id][outId] == nil then
                            results[point.id][outId] = {distance=distance, pre=previousPoint}
                        else
                            if results[point.id][outId].distance > distance then
                                results[point.id][outId] = {distance=distance, pre=previousPoint}
                            end
                        end

                        -- First check if this outgoing point has already been completely analyzed before
                        local toBeAdded = true
                        if results[outId] ~= nil then
                            local allOutsTested = true
                            if outPoint.transitMapping[point.id] ~= nil then
                                for _, nextOutId in pairs(outPoint.transitMapping[point.id]) do
                                    -- Check for shortcut here as well! (a banned turn counts as tested)
                                    if banned == nil or not banned[point.id .. ":" .. outId .. ":" .. nextOutId] then
                                        allOutsTested = allOutsTested and results[outId][nextOutId] ~= nil and not (results[outId][nextOutId].distance > distance)
                                    end
                                end
                            end
                            if allOutsTested then
                                toBeAdded = false
                            end
                        end

                        -- Add this point then
                        if toBeAdded then --or (#point.incoming > 1)
                            local factor = 1
                            if isSubPrio(outPoint) then
                                factor = 20
                            end
                            local preventTurnaroundWeight = 0
                            if point.id == startID then
                                if not table.contains(preferredStartIds, outPoint.id) then
                                    preventTurnaroundWeight = 5000000
                                end
                            end
                            --candidates:enqueue({p=outPoint, distance=(distance + (distanceFunc(outPoint.x - point.x, outPoint.z - point.z) + (addedWeights[outPoint.id] or 0)) * factor + preventTurnaroundWeight), pre=point.id})
                            --candidates:enqueue({p=outPoint, distance=(distance + (distanceFunc(point, outPoint, previousPoint) + (addedWeights[outPoint.id] or 0)) * factor + preventTurnaroundWeight), pre=point.id})
                            candidates:enqueue({p=outPoint, distance=(distance + (distanceFunc2(point, outPoint, previousPoint) + (addedWeights[outPoint.id] or 0)) * factor + preventTurnaroundWeight + narrowWeight(point, outPoint)), pre=point.id})
                        end
                        end
                    end
                    point = nil
                else
                    -- We can continue analyzing if this is a segment with only one possible direction
                    if #point.transitMapping[previousPoint] == 1 and not (banned ~= nil and banned[previousPoint .. ":" .. point.id .. ":" .. point.transitMapping[previousPoint][1]]) then
                        local outPoint = network[point.transitMapping[previousPoint][1]]
                        if results[point.id][outPoint.id] == nil then
                            results[point.id][outPoint.id] = {distance=distance, pre=previousPoint}
                        else
                            if results[point.id][outPoint.id].distance > distance then
                                results[point.id][outPoint.id] = {distance=distance, pre=previousPoint}
                            end
                        end

                        local factor = 1
                        if isSubPrio(outPoint) then
                            factor = 20
                        end

                        --distance = distance + (distanceFunc(outPoint.x - point.x, outPoint.z - point.z) + (addedWeights[outPoint.id] or 0)) * factor
                        --distance = distance + (distanceFunc(point, outPoint, previousPoint) + (addedWeights[outPoint.id] or 0)) * factor
                        distance = distance + (distanceFunc2(point, outPoint, previousPoint) + (addedWeights[outPoint.id] or 0)) * factor + narrowWeight(point, outPoint)
                        
                        previousPoint = point.id
                        point = outPoint
                    else
                        point = nil
                    end
                end
            end
        end
    end
    
    if not foundTarget then
        return {}
    end

    --Now we just have to reverse engineer the path
    local inversePath = {}
    local point = network[targetID]
    local counter = 0
    while point ~= nil do
        counter = counter + 1
        local previousPoint = network[lastPredecessor]
        lastPredecessor = results[lastPredecessor][point.id].pre

        table.insert(inversePath, point)
        point = previousPoint

        if lastPredecessor == -1 then
            point = nil
        end
        --emergency stop - we have some loop in the graph that went through till here
        if counter >= 500000 then
            return {}
        end
    end

    local path  = {}
    local count = #inversePath
    for i=0, count-1 do
        path[count-i] = inversePath[i+1]
    end

    if vehicle ~= nil then
        local narrow = 0
        for i = 1, #path - 1 do
            if narrowWeight(path[i], path[i + 1]) > 0 then
                narrow = narrow + 1
            end
        end
        if narrow > 0 then
            print(string.format("[AD-Width] %s: no wide enough route, %d narrow section(s) kept (needs %.1f m)", tostring(vehicle:getName()), narrow, ADPathCalculator.lastNeededWidth or 0))
        end
    end

    return path
end

function ADPathCalculator:getDetourWeights()
    local addedWeights = {}
    local maxDetour = AutoDrive.getSetting("mapMarkerDetour")
    if maxDetour > 0 then
        for _, marker in pairs(ADGraphManager:getMapMarkers()) do
            addedWeights[marker.id] = maxDetour
        end
    end
    return addedWeights
end

-- route width check ------------------------------------------------------------------------------
ADPathCalculator.NARROW_WEIGHT = 100000        -- added to a too narrow section: used only if there is no other way
ADPathCalculator.WIDTH_MARGIN = 0.05           -- m free on each side of the train
ADPathCalculator.WIDTH_CHECK_LOW = 0.3         -- m above ground: curbs and verges are ignored
ADPathCalculator.WIDTH_CHECK_HIGH = 3.0        -- m above ground
ADPathCalculator.widthMask = CollisionFlag.DEFAULT + CollisionFlag.STATIC_OBJECT + CollisionFlag.TREE + CollisionFlag.BUILDING
ADPathCalculator.widthCache = {}               -- [halfWidth][fromId][toId] = true when too narrow, false when fine

ADPathCalculator.FOLDED_TOOL_WIDTH = 2.4        -- m, transport width counted for a foldable tool

-- width the train needs to pass: tractor measured at its tyres, trailers at their size, foldable tools at their transport
-- width (their declared size is often the unfolded one)
function ADPathCalculator.getPassageWidth(vehicle)
    local width = 0
    local units = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit.size ~= nil and unit.size.width ~= nil then
                local unitWidth = unit.size.width
                local foldable = unit.spec_foldable
                if unit == vehicle then
                    unitWidth = ADPathCalculator.getWheelsWidth(vehicle) or unitWidth
                elseif foldable ~= nil and foldable.foldingParts ~= nil and #foldable.foldingParts > 0 then
                    unitWidth = math.min(unitWidth, ADPathCalculator.FOLDED_TOOL_WIDTH)
                end
                width = math.max(width, unitWidth)
            end
        end
    end
    if width <= 0 then
        width = 3
    end
    return width
end

-- width from the outside of the left tyre to the outside of the right tyre, mounted (visible) dual
-- wheels included; nil when it cannot be measured
function ADPathCalculator.getWheelsWidth(vehicle)
    local wheels = vehicle.spec_wheels ~= nil and vehicle.spec_wheels.wheels or nil
    local root = vehicle.rootNode or (vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node)
    if wheels == nil or root == nil or root == 0 then
        return nil
    end
    local minX, maxX = math.huge, -math.huge
    local function add(node, width)
        if node == nil or node == 0 or type(width) ~= "number" or width <= 0 then
            return
        end
        local ok, visible = pcall(getEffectiveVisibility, node)
        if ok and visible == false then
            return -- dual wheel not mounted
        end
        local okPos, x = pcall(localToLocal, node, root, 0, 0, 0)
        if okPos and type(x) == "number" then
            minX = math.min(minX, x - width / 2)
            maxX = math.max(maxX, x + width / 2)
        end
    end
    for _, wheel in ipairs(wheels) do
        local physicsWidth = wheel.physics ~= nil and wheel.physics.width or nil
        if wheel.visualWheels ~= nil and #wheel.visualWheels > 0 then
            for _, visualWheel in ipairs(wheel.visualWheels) do
                add(visualWheel.node, visualWheel.width or physicsWidth)
            end
        else
            add(wheel.repr or wheel.driveNode or wheel.node, physicsWidth)
        end
    end
    if maxX <= minX or maxX - minX < 1 or maxX - minX > 10 then
        return nil
    end
    local width = maxX - minX
    if vehicle.adLastWheelsWidth == nil or math.abs(vehicle.adLastWheelsWidth - width) > 0.1 then
        vehicle.adLastWheelsWidth = width
        print(string.format("[AD-Width] %s: width at the tyres %.2f m (vehicle file %.2f m)", tostring(vehicle:getName()), width, vehicle.size ~= nil and vehicle.size.width or 0))
    end
    return width
end

function ADPathCalculator:getNarrowWeightFunc(vehicle)
    if vehicle == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return function() return 0 end
    end
    local width = ADPathCalculator.getPassageWidth(vehicle)
    -- rounded to 10 cm so vehicles of about the same width share the measures
    local halfWidth = math.ceil((width / 2 + ADPathCalculator.WIDTH_MARGIN) * 10) / 10
    ADPathCalculator.lastNeededWidth = halfWidth * 2
    ADPathCalculator.widthCache[halfWidth] = ADPathCalculator.widthCache[halfWidth] or {}
    local cache = ADPathCalculator.widthCache[halfWidth]
    return function(a, b)
        local fromCache = cache[a.id]
        if fromCache == nil then
            fromCache = {}
            cache[a.id] = fromCache
        end
        local narrow = fromCache[b.id]
        if narrow == nil then
            narrow = ADPathCalculator.isSectionNarrow(a, b, halfWidth)
            fromCache[b.id] = narrow
        end
        if narrow then
            return ADPathCalculator.NARROW_WEIGHT
        end
        return 0
    end
end

function ADPathCalculator.isSectionNarrow(a, b, halfWidth)
    local dx, dz = b.x - a.x, b.z - a.z
    local length = math.sqrt(dx * dx + dz * dz)
    if length < 0.1 then
        return false
    end
    local cx, cz = (a.x + b.x) / 2, (a.z + b.z) / 2
    -- height of the network line (road or bridge deck), not of the terrain under a bridge
    local y
    if type(a.y) == "number" and type(b.y) == "number" and a.y ~= -1 and b.y ~= -1 then
        y = (a.y + b.y) / 2
    else
        y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 1, cz)
    end
    local low, high = ADPathCalculator.WIDTH_CHECK_LOW, ADPathCalculator.WIDTH_CHECK_HIGH
    ADPathCalculator.widthHits = 0
    ADPathCalculator.widthHitNode = nil
    overlapBox(cx, y + (low + high) / 2, cz, 0, math.atan2(dx, dz), 0, halfWidth, (high - low) / 2, length / 2, "widthCheckCallback", ADPathCalculator, ADPathCalculator.widthMask, true, true, true, true)
    if ADPathCalculator.widthHits > 0 then
        -- diagnostic: widest free corridor, and whether it is free higher up
        local function hits(hw, lo, hi)
            ADPathCalculator.widthHits = 0
            overlapBox(cx, y + (lo + hi) / 2, cz, 0, math.atan2(dx, dz), 0, hw, (hi - lo) / 2, length / 2, "widthCheckCallback", ADPathCalculator, ADPathCalculator.widthMask, true, true, true, true)
            return ADPathCalculator.widthHits > 0
        end
        local hitNode = ADPathCalculator.widthHitNode
        local freeHalf = 0
        for hw = 0.2, halfWidth, 0.1 do
            if hits(hw, low, high) then
                break
            end
            freeHalf = hw
        end
        local diag = {}
        for _, lo in ipairs({0.5, 0.8, 1.2}) do
            table.insert(diag, string.format("from %.1f m: %s", lo, hits(halfWidth, lo, high) and "hit" or "free"))
        end
        print(string.format("[AD-Width] section %s -> %s: line y %.2f, terrain %.2f, free width %.1f m, %s", tostring(a.id), tostring(b.id), y, getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 1, cz), freeHalf * 2, table.concat(diag, ", ")))
        ADPathCalculator.widthHits = 1
        ADPathCalculator.recordNarrowSection(a, b, halfWidth, hitNode)
        return true
    end
    return false
end

-- debug: narrow sections found, drawn in red with the AutoDrive sensor debug channel
ADPathCalculator.narrowSections = {}
ADPathCalculator.narrowInfo = {}               -- ["fromId>toId"] = {hitName, hx, hz}: what made a section too narrow

function ADPathCalculator.recordNarrowSection(a, b, halfWidth, hitNode)
    local hitName, hx, hy, hz = "?", nil, nil, nil
    if hitNode ~= nil and hitNode ~= 0 then
        local okName, name = pcall(getName, hitNode)
        if okName and name ~= nil then
            hitName = name
        end
        local okParent, parent = pcall(getParent, hitNode)
        if okParent and parent ~= nil and parent ~= 0 then
            local okParentName, parentName = pcall(getName, parent)
            if okParentName and parentName ~= nil then
                hitName = parentName .. "/" .. hitName
            end
        end
        local okPos, x, y, z = pcall(getWorldTranslation, hitNode)
        if okPos then
            hx, hy, hz = x, y, z
        end
    end
    table.insert(ADPathCalculator.narrowSections, {a = a, b = b, halfWidth = halfWidth, hitName = hitName, hx = hx, hy = hy, hz = hz})
    ADPathCalculator.narrowInfo[tostring(a.id) .. ">" .. tostring(b.id)] = {hitName = hitName, hx = hx, hz = hz}
    print(string.format("[AD-Width] section %s -> %s too narrow for %.1f m: hit '%s' at %s", tostring(a.id), tostring(b.id), halfWidth * 2, hitName, hx ~= nil and string.format("%.1f %.1f", hx, hz) or "?"))
end

local function drawRectangle(x, y, z, dirX, dirZ, halfWidth, front, back, r, g, b)
    local sideX, sideZ = dirZ, -dirX
    local corners = {
        {x + dirX * front + sideX * halfWidth, z + dirZ * front + sideZ * halfWidth},
        {x + dirX * front - sideX * halfWidth, z + dirZ * front - sideZ * halfWidth},
        {x - dirX * back - sideX * halfWidth, z - dirZ * back - sideZ * halfWidth},
        {x - dirX * back + sideX * halfWidth, z - dirZ * back + sideZ * halfWidth}
    }
    for i = 1, 4 do
        local c1, c2 = corners[i], corners[i % 4 + 1]
        ADDrawingManager:addLineTask(c1[1], y, c1[2], c2[1], y, c2[2], 1, r, g, b)
    end
end

function ADPathCalculator.debugDraw()
    local vehicle = AutoDrive.getControlledVehicle()
    if vehicle == nil or vehicle.components == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return
    end
    local vx, vy, vz = getWorldTranslation(vehicle.components[1].node)
    local dirX, _, dirZ = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local length = vehicle.size ~= nil and vehicle.size.length or 5
    -- blue: width taken into account for narrow passages
    local halfWidth = ADPathCalculator.getPassageWidth(vehicle) / 2
    drawRectangle(vx, vy + 0.3, vz, dirX, dirZ, halfWidth, length / 2, length / 2, 0, 0.4, 1)
    -- red: sections refused as too narrow, and the object that was hit
    local maxDistance = AutoDrive.drawDistance or 300
    for _, section in ipairs(ADPathCalculator.narrowSections) do
        local a, b = section.a, section.b
        local cx, cz = (a.x + b.x) / 2, (a.z + b.z) / 2
        if MathUtil.vector2Length(cx - vx, cz - vz) < maxDistance then
            local dx, dz = b.x - a.x, b.z - a.z
            local sectionLength = math.sqrt(dx * dx + dz * dz)
            if sectionLength > 0.1 then
                local y = ((type(a.y) == "number" and type(b.y) == "number" and a.y ~= -1 and b.y ~= -1) and (a.y + b.y) / 2 or getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 1, cz)) + ADPathCalculator.WIDTH_CHECK_LOW
                drawRectangle(cx, y, cz, dx / sectionLength, dz / sectionLength, section.halfWidth, sectionLength / 2, sectionLength / 2, 1, 0, 0)
            end
            if section.hx ~= nil then
                ADDrawingManager:addLineTask(section.hx, section.hy, section.hz, section.hx, section.hy + 4, section.hz, 1, 1, 0, 0)
            end
        end
    end
end

function ADPathCalculator.isMapBorder(node)
    for _ = 1, 2 do
        if node == nil or node == 0 then
            return false
        end
        local ok, name = pcall(getName, node)
        if ok and type(name) == "string" and string.find(string.lower(name), "border", 1, true) ~= nil then
            return true
        end
        local okParent, parent = pcall(getParent, node)
        node = okParent and parent or nil
    end
    return false
end

function ADPathCalculator:widthCheckCallback(transformId)
    if transformId == 0 or transformId == g_currentMission.terrainRootNode then
        return true
    end
    if ADPathCalculator.isMapBorder(transformId) then
        return true -- invisible wall at the map edge
    end
    local object = g_currentMission:getNodeObject(transformId)
    if object ~= nil and (object.rootVehicle ~= nil or object.isa ~= nil and object:isa(Vehicle)) then
        return true -- vehicles move, they are not part of the road width
    end
    ADPathCalculator.widthHits = ADPathCalculator.widthHits + 1
    ADPathCalculator.widthHitNode = transformId
    return false
end

-- route moved beside a thin obstacle on the line --------------------------------------------------
-- (08/11, Fabien : « il ne l'a pas vu ») 7R 350 leaving a field: the network line runs through two poles (sections
-- 6282 -> 6281 -> 6280, "too narrow ... hit 'collision/col'"). There was no other way, so the route kept them; the
-- sideways shift of ADAvoidModule started 4 m before the pole and only 1 m: the tyre hit the pole, and the sensors
-- (75 % of the width for static objects) never saw it. It pushed against it until the player came.
-- Now, when a route is set, each run of too narrow network sections is moved sideways as a whole, by the smallest
-- offset whose corridor (whole train width + margin, same heights as the width check) is free and whose ground stays
-- at the height of the line (no ditch, no bank, no bridge edge), with a gentle way out before and back after the
-- obstacle. When no offset fits (gate, bridge, wall, narrow road) the route stays as it was.
ADPathCalculator.SHIFT_OFFSETS = {0.5, 1.0, 1.5, 2.0, 2.5, 3.0} -- m, tried in this order, on both sides
ADPathCalculator.SHIFT_MARGIN = 0.3            -- m free beside the train where it is moved
ADPathCalculator.SHIFT_RATE = 0.25             -- m of offset per metre of route on the way out and back
ADPathCalculator.SHIFT_RAMP_MIN = 6            -- m
ADPathCalculator.SHIFT_RAMP_SHORT = 3          -- m, way out at least when the route starts close to the obstacle
ADPathCalculator.SHIFT_STEP = 2                -- m between two points of the moved part
ADPathCalculator.SHIFT_GROUND_DIFF = 0.6       -- m between the ground beside and the line at most
ADPathCalculator.SHIFT_MAX_TURN = math.rad(30) -- a moved part may not hold a sharper turn than this (bends: ADCornerModule)
ADPathCalculator.SHIFT_END_DISTANCE = 15       -- m, a run this close to the destination stays (the obstacle may be the goal)
ADPathCalculator.SHIFT_JOIN = 20               -- m, two runs closer than this are moved together
ADPathCalculator.SHIFT_RUN_MAX = 120           -- m, a longer run is a narrow road, not an obstacle
ADPathCalculator.SHIFT_FRONT_MARGIN = 2        -- m moved before the nose reaches the obstacle
ADPathCalculator.SHIFT_REAR_MARGIN = 2         -- m moved after the end of the train passed it

ADPathCalculator.SHIFT_DEBUG = true

function ADPathCalculator.shiftLog(text, ...)
    if ADPathCalculator.SHIFT_DEBUG then
        print(string.format("[AD-Poteau] " .. text, ...))
    end
end

local function isPlainNetworkPoint(wp)
    return wp ~= nil and wp.id ~= nil and not wp.isPathFinderPoint and not wp.isCornerPoint and not wp.isShiftPoint
end

-- nose and tail of the train, measured from the vehicle (route points are where the vehicle is)
function ADPathCalculator.getShiftTrain(vehicle)
    local front
    if vehicle.ad ~= nil and vehicle.ad.adDimensions ~= nil and vehicle.ad.adDimensions.maxLengthFront ~= nil and vehicle.ad.adDimensions.maxLengthFront > 0 then
        front = vehicle.ad.adDimensions.maxLengthFront
    else
        front = (vehicle.size ~= nil and vehicle.size.length or 6) / 2 + 0.5
    end
    local length = vehicle.size ~= nil and vehicle.size.length or 6
    local units = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit ~= vehicle and unit.size ~= nil and unit.size.length ~= nil then
                length = length + unit.size.length
            end
        end
    end
    return front, math.max(2, length - front)
end

local function terrainY(x, z)
    return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 300, z)
end

local function lineY(wp)
    if type(wp.y) == "number" and wp.y ~= -1 then
        return wp.y
    end
    return terrainY(wp.x, wp.z)
end

-- the moved part of the route between path distances s0 and s1 (offset 0 there), at full offset between sA and sB.
-- Returns the new points and the first / last index of wayPoints they replace, or nil and the reason
function ADPathCalculator.buildShift(wayPoints, s, sA, sB, offset, rampIn, rampOut)
    local n = #wayPoints
    local s0, s1 = sA - rampIn, sB + rampOut
    if s0 < s[1] or s1 > s[n] then
        return nil, "no room"
    end
    local from, to = nil, nil
    for i = 1, n do
        if s[i] > s0 + 0.01 and s[i] < s1 - 0.01 then
            from = from or i
            to = i
        end
    end
    if from == nil then
        return nil, "nothing to move"
    end
    -- no reverse section, no point of a redrawn bend or of the pathfinder inside, no sharp turn
    for i = math.max(2, from - 1), math.min(n, to + 1) do
        local a, b = wayPoints[i - 1], wayPoints[i]
        if b.isPathFinderPoint or b.isCornerPoint or b.isShiftPoint or b.cornerReverse ~= nil or ADGraphManager:isReverseRoad(a, b) then
            return nil, "reverse, bend or pathfinder points"
        end
        if i < n then
            local c = wayPoints[i + 1]
            local h1 = math.atan2(b.x - a.x, b.z - a.z)
            local h2 = math.atan2(c.x - b.x, c.z - b.z)
            local turn = math.abs((h2 - h1 + math.pi) % (2 * math.pi) - math.pi)
            if turn > ADPathCalculator.SHIFT_MAX_TURN and s[i] > s0 - 1 and s[i] < s1 + 1 then
                return nil, string.format("turn of %.0f deg", math.deg(turn))
            end
        end
    end
    -- path distances of the new points: the original points (they keep their id) and a point every SHIFT_STEP
    local list = {}
    for i = from, to do
        list[#list + 1] = {s = s[i], index = i}
    end
    local step = ADPathCalculator.SHIFT_STEP
    local k = s0 + step
    while k < s1 - 0.5 do
        local near = false
        for i = from, to do
            if math.abs(s[i] - k) < step * 0.4 then
                near = true
                break
            end
        end
        if not near then
            list[#list + 1] = {s = k}
        end
        k = k + step
    end
    -- the ends of the moved part, on the line, unless an original point is there already (no point twice)
    if s0 - s[from - 1] > 0.3 then
        list[#list + 1] = {s = s0, edge = true}
    end
    if to + 1 > n or s[to + 1] - s1 > 0.3 then
        list[#list + 1] = {s = s1, edge = true}
    end
    table.sort(list, function(p, q) return p.s < q.s end)
    local function amount(v)
        local t
        if v <= sA then
            t = rampIn > 0 and (v - s0) / rampIn or 1
        elseif v >= sB then
            t = rampOut > 0 and (s1 - v) / rampOut or 1
        else
            return 1
        end
        t = math.max(0, math.min(1, t))
        return t * t * (3 - 2 * t)
    end
    local points = {}
    local j = 1
    for _, item in ipairs(list) do
        while j < n - 1 and s[j + 1] < item.s do
            j = j + 1
        end
        local a, b = wayPoints[j], wayPoints[j + 1]
        local len = math.max(0.001, s[j + 1] - s[j])
        local f = math.max(0, math.min(1, (item.s - s[j]) / len))
        local bx, bz = a.x + (b.x - a.x) * f, a.z + (b.z - a.z) * f
        local by = lineY(a) + (lineY(b) - lineY(a)) * f
        local dx, dz = (b.x - a.x) / len, (b.z - a.z) / len
        if item.index ~= nil then
            -- an original point: the normal is the mean of the stretches before and after it
            local i = item.index
            local p, q = wayPoints[i - 1], wayPoints[i + 1]
            local d1x, d1z, d2x, d2z = 0, 0, 0, 0
            if p ~= nil then
                local l1 = math.max(0.001, MathUtil.vector2Length(wayPoints[i].x - p.x, wayPoints[i].z - p.z))
                d1x, d1z = (wayPoints[i].x - p.x) / l1, (wayPoints[i].z - p.z) / l1
            end
            if q ~= nil then
                local l2 = math.max(0.001, MathUtil.vector2Length(q.x - wayPoints[i].x, q.z - wayPoints[i].z))
                d2x, d2z = (q.x - wayPoints[i].x) / l2, (q.z - wayPoints[i].z) / l2
            end
            local l = MathUtil.vector2Length(d1x + d2x, d1z + d2z)
            if l > 0.001 then
                dx, dz = (d1x + d2x) / l, (d1z + d2z) / l
            end
            bx, bz, by = wayPoints[i].x, wayPoints[i].z, lineY(wayPoints[i])
        end
        local o = offset * amount(item.s)
        local x, z = bx + dz * o, bz - dx * o
        local point
        if item.index ~= nil then
            point = {}
            for key, value in pairs(wayPoints[item.index]) do
                point[key] = value
            end
        else
            point = {}
        end
        point.x, point.z = x, z
        point.y = terrainY(x, z)
        point.isShiftPoint = true
        point.shiftOffset = o
        point.lineY = by
        points[#points + 1] = point
    end
    return points, from, to
end

-- the moved part is clear: whole train width + margin (growing with the offset), same heights as the width check,
-- ground at the height of the line. Returns clear, reason
function ADPathCalculator.isShiftClear(points, halfWidth, offset)
    local low, high = ADPathCalculator.WIDTH_CHECK_LOW, ADPathCalculator.WIDTH_CHECK_HIGH
    for k, p in ipairs(points) do
        if math.abs(p.y - p.lineY) > ADPathCalculator.SHIFT_GROUND_DIFF then
            return false, string.format("ground %.1f m %s the line", math.abs(p.y - p.lineY), p.y < p.lineY and "below" or "above")
        end
        local q = points[k + 1]
        if q ~= nil then
            local dx, dz = q.x - p.x, q.z - p.z
            local length = math.sqrt(dx * dx + dz * dz)
            if length > 0.05 then
                local share = math.min(1, math.max(math.abs(p.shiftOffset), math.abs(q.shiftOffset)) / math.max(0.01, math.abs(offset)))
                local half = halfWidth + ADPathCalculator.SHIFT_MARGIN * share
                local cx, cz = (p.x + q.x) / 2, (p.z + q.z) / 2
                local y = math.max(terrainY(cx, cz), (p.lineY + q.lineY) / 2)
                ADPathCalculator.widthHits = 0
                ADPathCalculator.widthHitNode = nil
                overlapBox(cx, y + (low + high) / 2, cz, 0, math.atan2(dx, dz), 0, half, (high - low) / 2, length / 2, "widthCheckCallback", ADPathCalculator, ADPathCalculator.widthMask, true, true, true, true)
                if ADPathCalculator.widthHits > 0 then
                    local name = "?"
                    if ADPathCalculator.widthHitNode ~= nil and getName ~= nil then
                        local ok, hitName = pcall(getName, ADPathCalculator.widthHitNode)
                        if ok and hitName ~= nil then
                            name = hitName
                        end
                    end
                    return false, string.format("'%s' %.0f m into the moved part", name, k * ADPathCalculator.SHIFT_STEP)
                end
            end
        end
    end
    return true
end

-- where the obstacles of a run lie along the route: the sections are cut in slices of SHIFT_STEP metres tested like
-- the width check. Returns the path distances of the start of the first and of the end of the last slice hit
function ADPathCalculator.locateShiftHits(wayPoints, s, run, halfWidth)
    local low, high = ADPathCalculator.WIDTH_CHECK_LOW, ADPathCalculator.WIDTH_CHECK_HIGH
    local first, last = nil, nil
    for i = run.first, run.last do
        local a, b = wayPoints[i], wayPoints[i + 1]
        local length = s[i + 1] - s[i]
        if length > 0.05 then
            local slices = math.max(1, math.ceil(length / ADPathCalculator.SHIFT_STEP))
            local ry = math.atan2(b.x - a.x, b.z - a.z)
            for k = 0, slices - 1 do
                local f0, f1 = k / slices, (k + 1) / slices
                local fm = (f0 + f1) / 2
                local cx, cz = a.x + (b.x - a.x) * fm, a.z + (b.z - a.z) * fm
                local y = lineY(a) + (lineY(b) - lineY(a)) * fm
                ADPathCalculator.widthHits = 0
                overlapBox(cx, y + (low + high) / 2, cz, 0, ry, 0, halfWidth, (high - low) / 2, length / slices / 2, "widthCheckCallback", ADPathCalculator, ADPathCalculator.widthMask, true, true, true, true)
                if ADPathCalculator.widthHits > 0 then
                    first = first or (s[i] + length * f0)
                    last = s[i] + length * f1
                end
            end
        end
    end
    return first, last
end

-- one run of too narrow sections wayPoints[first] -> wayPoints[last + 1]: the moved part, or nil
function ADPathCalculator.planShift(vehicle, wayPoints, s, run, halfWidth, front, rear, startS)
    local n = #wayPoints
    local sStart, sEnd = s[run.first], s[run.last + 1]
    -- only around the obstacles themselves, not along the whole sections
    local hitStart, hitEnd = ADPathCalculator.locateShiftHits(wayPoints, s, run, halfWidth)
    if hitStart ~= nil then
        sStart, sEnd = hitStart, hitEnd
    end
    local a, b = wayPoints[run.first], wayPoints[run.last + 1]
    local label = string.format("%s: sections %s -> %s (%.0f m)", tostring(vehicle:getName()), tostring(a.id), tostring(b.id), sEnd - sStart)
    if sEnd - sStart > ADPathCalculator.SHIFT_RUN_MAX then
        ADPathCalculator.shiftLog("%s: long narrow stretch (narrow road), route kept", label)
        return nil
    end
    if s[n] - sEnd < ADPathCalculator.SHIFT_END_DISTANCE then
        ADPathCalculator.shiftLog("%s: next to the destination, route kept", label)
        return nil
    end
    -- side of the line where the hit object was seen: the other side is tried first (+1 = left normal)
    local sides = {-1, 1}
    for i = run.first, run.last do
        local info = ADPathCalculator.narrowInfo[tostring(wayPoints[i].id) .. ">" .. tostring(wayPoints[i + 1].id)]
        if info ~= nil and info.hx ~= nil then
            local p, q = wayPoints[i], wayPoints[i + 1]
            local dx, dz = q.x - p.x, q.z - p.z
            local side = (info.hx - p.x) * dz - (info.hz - p.z) * dx
            if side > 0.05 then
                sides = {-1, 1}
            elseif side < -0.05 then
                sides = {1, -1}
            end
            break
        end
    end
    local lastReason = nil
    for _, margins in ipairs({{front + ADPathCalculator.SHIFT_FRONT_MARGIN, rear + ADPathCalculator.SHIFT_REAR_MARGIN}, {ADPathCalculator.SHIFT_FRONT_MARGIN, ADPathCalculator.SHIFT_REAR_MARGIN}}) do
        local sA = math.max(startS, sStart - margins[1])
        local sB = sEnd + margins[2]
        for _, e in ipairs(ADPathCalculator.SHIFT_OFFSETS) do
            local ramp = math.max(ADPathCalculator.SHIFT_RAMP_MIN, e / ADPathCalculator.SHIFT_RATE)
            local rampIn = math.min(ramp, sA - startS)
            if rampIn >= ADPathCalculator.SHIFT_RAMP_SHORT or rampIn >= ramp then
                for _, sign in ipairs(sides) do
                    local points, from, to = ADPathCalculator.buildShift(wayPoints, s, sA, sB, sign * e, rampIn, ramp)
                    if points == nil then
                        lastReason = from
                    else
                        local clear, reason = ADPathCalculator.isShiftClear(points, halfWidth, sign * e)
                        if clear then
                            ADPathCalculator.shiftLog("%s, hit '%s': route moved %.1f m to the %s over %.0f m (way out %.0f m, back %.0f m)",
                                label, tostring(run.hitName or "?"), e, sign > 0 and "left" or "right", sB - sA, rampIn, ramp)
                            return {from = from, to = to, points = points, endS = sB + ramp}
                        end
                        lastReason = reason
                    end
                end
            else
                lastReason = "too close to the start of the route"
            end
        end
    end
    ADPathCalculator.shiftLog("%s, hit '%s': no free offset beside it (%s), route kept", label, tostring(run.hitName or "?"), tostring(lastReason))
    return nil
end

-- wayPoints: route set for the vehicle (after ADCornerModule:smoothRoute); firstIndex: first point it drives to
function ADPathCalculator.shiftAroundObstacles(vehicle, wayPoints, firstIndex)
    if vehicle == nil or not vehicle.isServer or wayPoints == nil or #wayPoints < 3 or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return wayPoints
    end
    local enabled = AutoDrive.getSetting("avoidEnabled")
    if enabled == false or enabled == 0 then
        return wayPoints
    end
    local narrow = ADPathCalculator:getNarrowWeightFunc(vehicle)
    local halfWidth = (ADPathCalculator.lastNeededWidth or 3) / 2
    local n = #wayPoints
    local s = {0}
    for i = 2, n do
        s[i] = s[i - 1] + MathUtil.vector2Length(wayPoints[i].x - wayPoints[i - 1].x, wayPoints[i].z - wayPoints[i - 1].z)
    end
    local startIndex = math.max(1, math.min(n, (firstIndex or 2) - 1))
    local runs = {}
    for i = startIndex, n - 1 do
        local a, b = wayPoints[i], wayPoints[i + 1]
        if isPlainNetworkPoint(a) and isPlainNetworkPoint(b) and narrow(a, b) > 0 then
            local info = ADPathCalculator.narrowInfo[tostring(a.id) .. ">" .. tostring(b.id)]
            local last = runs[#runs]
            if last ~= nil and s[i] - s[last.last + 1] <= ADPathCalculator.SHIFT_JOIN then
                last.last = i
            else
                runs[#runs + 1] = {first = i, last = i, hitName = info ~= nil and info.hitName or nil}
            end
        end
    end
    if #runs == 0 then
        return wayPoints
    end
    local front, rear = ADPathCalculator.getShiftTrain(vehicle)
    local out = {}
    local copied = 0
    local moved = 0
    local freeFrom = s[startIndex] -- the next moved part starts after the end of the previous one
    for _, run in ipairs(runs) do
        if run.first > copied and s[run.first + 1] > freeFrom then
            local plan = ADPathCalculator.planShift(vehicle, wayPoints, s, run, halfWidth, front, rear, freeFrom)
            if plan ~= nil and plan.from > copied then
                freeFrom = plan.endS
                for i = copied + 1, plan.from - 1 do
                    out[#out + 1] = wayPoints[i]
                end
                for _, point in ipairs(plan.points) do
                    out[#out + 1] = point
                end
                copied = plan.to
                moved = moved + 1
            end
        end
    end
    if moved == 0 then
        return wayPoints
    end
    for i = copied + 1, n do
        out[#out + 1] = wayPoints[i]
    end
    return out
end
