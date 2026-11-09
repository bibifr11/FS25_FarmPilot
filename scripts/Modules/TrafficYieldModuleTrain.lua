-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleTrain.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : l'attelage de chaque véhicule.
--
-- Règle :
-- - dimensions réelles de chaque élément, mesurées par le capteur d'AutoDrive au début d'un plan (measureTrain),
--   sinon celles du xml du véhicule ; avant (outils frontaux compris), arrière, largeur, longueur remorquée ;
-- - attelage articulé (A1, 27/10 et 28/10) : avant-train pivotant, remorque sur dolly, deux remorques à la suite, coupe
--   sur remorque : il ne recule jamais, l'autre recule ; une seule remorque rigide (remorque d'ensilage) recule ;
-- - rayon de braquage de tout l'attelage (28/10) : le plus maniable a le plus petit rayon ;
-- - recul à faire pour sortir du chemin à double sens (28/10) : somme des virages, comptée double avec remorque ;
--   recule celui qui manœuvre le moins.
--
-- Branché par : les autres fichiers TrafficYieldModule*.lua. getTrainExtents, getWidth, getUnitDimensions,
-- measureTrain, cannotReverse et describeArticulated servent aussi à FieldParkModule, WaitForCallTaskFieldPark,
-- DriveToDestinationTaskArrival, CatchCombinePipeTaskClear et HandleHarvesterTurnTaskHarvesterWay.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Dimensions de l'attelage
-- ------------------------------------------------------------------------------------------------------------
-- measures the real dimensions of every unit of the train in its current (transport) state, with the
-- AutoDrive dimension sensor; done once when a plan starts, the results are cached in vehicle.ad.adDimensions
function ADTrafficYieldModule.measureTrain(vehicle)
    local ok = pcall(function()
        AutoDrive.getAllVehicleDimensions(vehicle, true)
    end)
    if not ok then
        Logging.error("[AD] ADTrafficYieldModule: could not measure the dimensions of %s", ADTrafficYieldModule.getName(vehicle))
    end
end

-- real width / length of one unit: measured values when available, otherwise the vehicle xml values
function ADTrafficYieldModule.getUnitDimensions(unit)
    local width = (unit.size ~= nil and unit.size.width) or 3
    local length = (unit.size ~= nil and unit.size.length) or 5
    local dims = unit.ad ~= nil and unit.ad.adDimensions or nil
    if dims ~= nil then
        if dims.maxWidthLeft ~= nil and dims.maxWidthRight ~= nil and (dims.maxWidthLeft + dims.maxWidthRight) > 0.5 then
            width = dims.maxWidthLeft + dims.maxWidthRight
        elseif dims.width ~= nil and dims.width > 0.5 then
            width = dims.width
        end
        if dims.maxLengthFront ~= nil and dims.maxLengthBack ~= nil and (dims.maxLengthFront + dims.maxLengthBack) > 0.5 then
            length = dims.maxLengthFront + dims.maxLengthBack
        elseif dims.length ~= nil and dims.length > 0.5 then
            length = dims.length
        end
    end
    return width, length
end

-- widest unit of the train (tractor, front / rear implements, trailers)
function ADTrafficYieldModule.getWidth(vehicle)
    local maxWidth = ADTrafficYieldModule.getUnitDimensions(vehicle)
    local units, _ = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            local width = ADTrafficYieldModule.getUnitDimensions(unit)
            maxWidth = math.max(maxWidth, width)
        end
    end
    return math.min(maxWidth, 8)
end

-- distances from the vehicle origin to the front-most and rear-most points of the train
-- (front implements included, e.g. a front cultivator or a front weight)
function ADTrafficYieldModule.getTrainExtents(vehicle)
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(vehicle)
    local front, rear = tractorLength / 2, tractorLength / 2
    local units, _ = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit ~= vehicle and unit.components ~= nil then
                local _, unitLength = ADTrafficYieldModule.getUnitDimensions(unit)
                local ux, uy, uz = getWorldTranslation(unit.components[1].node)
                local _, _, localZ = AutoDrive.worldToLocal(vehicle, ux, uy, uz)
                front = math.max(front, localZ + unitLength / 2)
                rear = math.max(rear, -(localZ - unitLength / 2))
            end
        end
    end
    return front, rear
end

-- length of the whole train (sum of all units)
function ADTrafficYieldModule.getTotalLength(vehicle)
    local length = 0
    local units, count = AutoDrive.getAllUnits(vehicle)
    if units ~= nil and count ~= nil and count > 0 then
        for _, unit in pairs(units) do
            local _, unitLength = ADTrafficYieldModule.getUnitDimensions(unit)
            length = length + unitLength
        end
    end
    if length <= 0 then
        local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(vehicle)
        length = tractorLength
    end
    return length
end

-- length towed behind the hitch of the tractor (0: nothing towed, mounted implements are rigid)
function ADTrafficYieldModule.getTowedLength(vehicle)
    local units, count = AutoDrive.getAllUnits(vehicle)
    if units == nil or count == nil or count < 2 then
        return 0
    end
    local towed = false
    for _, unit in pairs(units) do
        if ADTrafficYieldModule.isTowedUnit(vehicle, unit) then
            towed = true
            break
        end
    end
    if not towed then
        return 0
    end
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(vehicle)
    local _, rear = ADTrafficYieldModule.getTrainExtents(vehicle)
    return math.max(0, rear - tractorLength / 2)
end

-- ------------------------------------------------------------------------------------------------------------
-- Remorque, chargement, priorité
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule.hasTrailer(vehicle)
    local _, trailerCount = AutoDrive.getAllUnits(vehicle)
    return trailerCount ~= nil and trailerCount > 1
end

function ADTrafficYieldModule.isLoaded(vehicle)
    local trailers, _ = AutoDrive.getAllUnits(vehicle)
    if trailers == nil or #trailers == 0 then
        return false
    end
    local fillLevel, fillCapacity = AutoDrive.getAllFillLevels(trailers)
    if fillCapacity == nil or fillCapacity <= 0 then
        return false
    end
    return (fillLevel / fillCapacity) > 0.1
end

-- the lower the score, the more the vehicle should be the one reversing
function ADTrafficYieldModule.getPriorityScore(vehicle)
    local score = 0
    if ADTrafficYieldModule.isLoaded(vehicle) then
        score = score + 2
    end
    if ADTrafficYieldModule.hasTrailer(vehicle) then
        score = score + 1
    end
    return score
end

-- ------------------------------------------------------------------------------------------------------------
-- Attelage articulé : ne recule jamais (A1)
-- ------------------------------------------------------------------------------------------------------------
-- a unit pulled on its own wheels behind its attacher (trailer, dolly, trailed implement), not a mounted implement
function ADTrafficYieldModule.isTowedUnit(root, unit)
    if unit == nil or unit == root or unit.spec_attachable == nil then
        return false
    end
    if AutoDrive.isImplementAllowedForReverseDriving ~= nil then
        local ok, towed = pcall(AutoDrive.isImplementAllowedForReverseDriving, root, unit)
        if ok and towed then
            return true
        end
    end
    return string.find(string.lower(tostring(unit.typeName or "")), "trailer", 1, true) ~= nil
end

-- front axle pivoting with the drawbar (turntable): a component joint turning around the vertical axis only
-- (AutoDrive locks it while reversing, ADTrailerModule keeps the original limit in unit.ad.rotLimitBackup)
function ADTrafficYieldModule.hasPivotingFrontAxle(unit)
    if unit.ad ~= nil and unit.ad.rotLimitBackup ~= nil and math.abs(unit.ad.rotLimitBackup) > math.rad(5) then
        return true
    end
    if unit.components == nil or #unit.components < 2 or unit.componentJoints == nil then
        return false
    end
    for _, joint in pairs(unit.componentJoints) do
        local limit = joint.rotLimit
        if limit ~= nil and limit[2] ~= nil and math.abs(limit[2]) > math.rad(5)
            and math.abs(limit[1] or 0) <= math.abs(limit[2]) / 2 and math.abs(limit[3] or 0) <= math.abs(limit[2]) / 2 then
            return true
        end
    end
    return false
end

-- 28/10: an articulated train never reverses: front axle pivoting with the drawbar (two-axle turntable tipper, header
-- trailer), a trailer on a dolly, or two trailers in a row; a single rigid trailer (silage trailer) reverses.
-- A1 (27/10): a header carried on a trailer. Returns true, the name of the unit and what it is
ADTrafficYieldModule.ARTICULATED_FR = {header = "remorque de coupe", dolly = "dolly", two = "deux remorques a la suite", turntable = "avant-train pivotant"}
function ADTrafficYieldModule.cannotReverse(vehicle)
    if vehicle == nil or vehicle.getRootVehicle == nil then
        return false
    end
    local root = vehicle:getRootVehicle()
    if root == nil then
        return false
    end
    local children = root.childVehicles
    if children == nil and root.getChildVehicles ~= nil then
        children = root:getChildVehicles()
    end
    if children == nil then
        return false
    end
    for _, unit in pairs(children) do
        if unit ~= root then
            local typeName = string.lower(tostring(unit.typeName or ""))
            local name = (unit.getFullName ~= nil and unit:getFullName()) or typeName
            local attacher = unit.getAttacherVehicle ~= nil and unit:getAttacherVehicle() or nil
            -- a harvester with its own header reverses normally
            if root.spec_combine == nil and (unit.spec_cutter ~= nil or string.find(typeName, "cutter", 1, true) ~= nil) then
                if attacher ~= root or string.find(typeName, "trailer", 1, true) ~= nil then
                    return true, name, "header"
                end
            end
            if ADTrafficYieldModule.isTowedUnit(root, unit) then
                if string.find(typeName, "dolly", 1, true) ~= nil then
                    return true, name, "dolly"
                end
                if attacher ~= nil and attacher ~= root and ADTrafficYieldModule.isTowedUnit(root, attacher) then
                    return true, name, "two"
                end
                if ADTrafficYieldModule.hasPivotingFrontAxle(unit) then
                    return true, name, "turntable"
                end
            end
        end
    end
    return false
end

-- text of the articulated unit for the log: "avant-train pivotant (name)"
function ADTrafficYieldModule.describeArticulated(vehicle)
    local articulated, name, kind = ADTrafficYieldModule.cannotReverse(vehicle)
    if not articulated then
        return nil
    end
    return string.format("%s (%s)", ADTrafficYieldModule.ARTICULATED_FR[kind] or tostring(kind), tostring(name))
end

-- A1: logged once per plan and vehicle
function ADTrafficYieldModule:logCannotReverse(other)
    local plan = self.plan
    if plan ~= nil then
        plan.a1Logged = plan.a1Logged or {}
        if plan.a1Logged[self.vehicle] then
            return
        end
        plan.a1Logged[self.vehicle] = true
    end
    local what = ADTrafficYieldModule.describeArticulated(self.vehicle)
    self:log("articulated train (%s): I never reverse, %s reverses", tostring(what), ADTrafficYieldModule.getName(other))
    print(string.format("[AD-Croise] %s: remorque articulee, %s, je ne recule pas : %s recule", ADTrafficYieldModule.getName(self.vehicle), tostring(what),
        ADTrafficYieldModule.getName(other)))
end

-- ------------------------------------------------------------------------------------------------------------
-- Rayon de braquage et recul à faire
-- ------------------------------------------------------------------------------------------------------------
-- 28/10: turning radius of the whole train (the most manoeuvrable one has the smaller radius): the radius of the tractor
-- (vehicle file or steering geometry, as ADCornerModule) plus what the towed units cut inside its arc (towed length
-- squared / twice the radius)
function ADTrafficYieldModule.getTrainRadius(vehicle)
    local fileRadius = AutoDrive.getDriverRadius ~= nil and AutoDrive.getDriverRadius(vehicle, true) or 0
    local wheelRadius = ADCornerModule ~= nil and ADCornerModule.getWheelRadius ~= nil and ADCornerModule.getWheelRadius(vehicle) or nil
    local radius = math.max(fileRadius or 0, wheelRadius or 0)
    if radius < 3 then
        radius = 6
    end
    radius = math.min(radius, 14)
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(vehicle)
    local towed = math.max(0, ADTrafficYieldModule.getTotalLength(vehicle) - tractorLength)
    return radius + towed * towed / (2 * radius), radius, towed
end

-- reverse distance of the standard manoeuvre: the AutoDrive setting, at least REVERSE_SEARCH_MAX (28/10)
function ADTrafficYieldModule.getMaxReverse()
    return math.max(AutoDrive.getSetting("trafficYieldMaxReverse") or 50, ADTrafficYieldModule.REVERSE_SEARCH_MAX)
end

-- 28/10 (the one that manoeuvres the least reverses, even if its reverse is longer): the reverse a vehicle would have to
-- drive along its own route to get out of the two-way track (up to SECTION_CLEAR_MAX m, plus its length once out of it):
-- the sum of the turns of that path (degrees), counted double with a trailer, and its length
function ADTrafficYieldModule.getReverseManoeuvre(vehicle)
    local trailer = ADTrafficYieldModule.hasTrailer(vehicle)
    local result = {angle = 0, length = 0, trailer = trailer, score = 0}
    local wayPoints, currentIndex = vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return result
    end
    local x, _, z = ADTrafficYieldModule.getPosition(vehicle)
    local dirX, dirZ = ADTrafficYieldModule.getDirection(vehicle)
    local heading = math.atan2(-dirX, -dirZ)
    local lastX, lastZ = x, z
    local outLength = nil
    local trainLength = ADTrafficYieldModule.getTotalLength(vehicle)
    for i = currentIndex - 1, 1, -1 do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        local d = MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        if d > 0.5 then
            local h = math.atan2(wp.x - lastX, wp.z - lastZ)
            local turn = h - heading
            while turn > math.pi do
                turn = turn - 2 * math.pi
            end
            while turn < -math.pi do
                turn = turn + 2 * math.pi
            end
            result.angle = result.angle + math.abs(math.deg(turn))
            result.length = result.length + d
            heading = h
            lastX, lastZ = wp.x, wp.z
        end
        local nextWp = wayPoints[i + 1]
        if outLength == nil and (wp.id == nil or nextWp == nil or nextWp.id == nil or not ADTrafficYieldModule.isTwoWay(wp.id, nextWp.id)) then
            outLength = result.length -- out of the two-way track: its length more
        end
        if outLength ~= nil and result.length >= outLength + trainLength then
            break
        end
        if result.length >= ADTrafficYieldModule.SECTION_CLEAR_MAX then
            -- still in the two-way track after the longest reverse: I cannot clear the way backwards
            result.tooLong = outLength == nil
            break
        end
    end
    result.score = result.angle * (trailer and 2 or 1)
    if result.tooLong then
        result.score = result.score + 100000 -- the other one reverses when it can get out
    end
    -- something right behind me (a car, a wall): I cannot reverse at all
    if vehicle.ad.collisionDetectionModule ~= nil and vehicle.ad.collisionDetectionModule:checkReverseCollision() then
        result.blocked = true
        result.score = math.huge
    end
    return result
end
