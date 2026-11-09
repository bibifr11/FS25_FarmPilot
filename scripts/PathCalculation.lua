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
        ADPathCalculator.resetWidthCache() -- (largeur des routes), voir PathCalculationWidth.lua
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
    -- routes tertiaires : accès au départ / à la destination seulement, temps à leur vitesse maxi, x100 « Jamais » (DirtRoadManager.lua)
    if ADDirtRoads ~= nil then distanceFunc2 = ADDirtRoads.wrapDriveTime(distanceFunc2, vehicle, startID, targetID) end
    -- routes secondaires : Auto (tracteurs x1, camions x20 d'origine), Autorisées x1, Jamais x100 (DirtRoadManager.lua)
    local subPrioFactor = ADDirtRoads ~= nil and ADDirtRoads.secondaryFactor(vehicle) or 20

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
                                factor = subPrioFactor
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
                            factor = subPrioFactor
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

    ADPathCalculator.logNarrowRoute(vehicle, path, narrowWeight) -- (largeur des routes : tronçons étroits gardés), voir PathCalculationWidth.lua

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
