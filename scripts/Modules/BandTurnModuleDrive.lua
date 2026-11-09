-- ============================================================================================================
-- FarmPilot : BandTurnModuleDrive.lua
-- Complément de BandTurnModule.lua : la géométrie de l'attelage réel (essieu du tracteur, point d'attelage, essieu
-- de la remorque, caisses, rayon) et la conduite d'un temps de manœuvre (en avant : le tracteur suit sa ligne ; en
-- arrière : l'essieu de la remorque suit la sienne). Sert au demi-tour dans la bande (ensileuse) ET à la manœuvre de
-- fin de route de tous les attelages (CornerModuleEndManoeuvre.lua).
--
-- Règles : arrêt et nouveau calcul quand l'attelage s'écarte de la ligne (MAX_DEVIATION), reste sur place
-- (STUCK_TIME) ou met l'avant du tracteur dans la culture ; recul retenu quand le capteur arrière voit un obstacle.
--
-- Branché par : BandTurnModule.lua (start, replan, update) ; CornerModule.lua (readGeometry -> getGeometry),
-- CornerModuleEndManoeuvre.lua (driveEndManoeuvre -> driveLeg) ; CatchCombinePipeTaskChopperUTurn.lua
-- (headingOfNode).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Outils (copies des constantes de BandTurnModule.lua)
-- ------------------------------------------------------------------------------------------------------------
local atan2 = math.atan2 or math.atan
local TWO_PI = 2 * math.pi

-- ------------------------------------------------------------------------------------------------------------
-- Géométrie de l'attelage réel
-- ------------------------------------------------------------------------------------------------------------
local function headingOfNode(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    return atan2(dx, dz)
end
ADBandTurn.headingOfNode = headingOfNode

-- box of a unit (size.length, size.width, size.lengthOffset around its root node) along heading a, around x, z
local function unitBox(unit, x, z, a, frontFrom)
    local root = unit.components[1].node
    local length = unit.size ~= nil and unit.size.length or 6
    local width = unit.size ~= nil and unit.size.width or 3
    local offset = unit.size ~= nil and unit.size.lengthOffset or 0
    local cx, _, cz = localToWorld(root, 0, 0, offset)
    local c = (cx - x) * math.sin(a) + (cz - z) * math.cos(a)
    return ADBandTurn.prepareBox({front = c + length / 2, rear = c - length / 2, half = width / 2, frontFrom = frontFrom})
end

-- tractor and one trailer: axle positions, hitch distance, trailer length, boxes, radius. nil, reason if unusable
function ADBandTurn.getGeometry(vehicle)
    local sdm = vehicle.ad.specialDrivingModule
    local reverseNode = sdm:getReverseNode()
    local trailer = vehicle.trailer
    if reverseNode == nil or trailer == nil or sdm.reverseSolo then
        return nil, "pas de remorque a roues"
    end
    local units = 0
    for _, implement in pairs(AutoDrive.getAllImplements(vehicle, true)) do
        if implement ~= vehicle and implement.spec_wheels ~= nil and implement.spec_wheels.wheels ~= nil and #implement.spec_wheels.wheels > 0 then
            units = units + 1
        end
    end
    if units > 1 then
        return nil, "plusieurs remorques"
    end
    local axleNode = vehicle.getAIDirectionNode ~= nil and vehicle:getAIDirectionNode() or vehicle.components[1].node
    local x, _, z = getWorldTranslation(axleNode)
    local a = headingOfNode(axleNode)
    local tx, _, tz = getWorldTranslation(reverseNode)
    local b = headingOfNode(trailer.components[1].node)
    -- hitch: the input attacher joint of the trailer, else where the two axes meet
    local hx, hz = nil, nil
    if trailer.getActiveInputAttacherJoint ~= nil then
        local joint = trailer:getActiveInputAttacherJoint()
        if joint ~= nil and joint.node ~= nil then
            local jx, _, jz = getWorldTranslation(joint.node)
            hx, hz = jx, jz
        end
    end
    if hx == nil then
        local l = math.max(4, AutoDrive.getTractorTrainLength(vehicle, false, true) * 0.6)
        hx, hz = tx + math.sin(b) * l, tz + math.cos(b) * l
    end
    local hitch = (x - hx) * math.sin(a) + (z - hz) * math.cos(a)
    local trailerLength = MathUtil.vector2Length(hx - tx, hz - tz)
    if trailerLength < 2 then
        return nil, "geometrie de la remorque inconnue"
    end
    local radius = AutoDrive.getDriverRadius(vehicle, true)
    if radius == nil or radius < 3 or radius > 20 then
        radius = 7
    end
    local geo = {
        hitch = hitch,
        trailer = trailerLength,
        radius = radius * ADBandTurn.RADIUS_MARGIN,
        tractorBox = unitBox(vehicle, x, z, a, ADBandTurn.TRACTOR_FRONT_FROM),
        trailerBox = unitBox(trailer, tx, tz, b)
    }
    -- the trailer heading used by the search is the hitch direction seen from its axle
    local pose = {x = x, z = z, a = a, tx = tx, tz = tz, b = atan2(hx - tx, hz - tz)}
    return geo, pose
end

-- ------------------------------------------------------------------------------------------------------------
-- Conduite d'un temps de manœuvre
-- ------------------------------------------------------------------------------------------------------------
local function nearestIndex(points, from, x, z, useTrailer)
    local best, bestD = from, math.huge
    for i = from, math.min(#points, from + 40) do
        local p = points[i]
        local px, pz = p.x, p.z
        if useTrailer then
            px, pz = p.tx, p.tz
        end
        local d = MathUtil.vector2Length(px - x, pz - z)
        if d < bestD then
            best, bestD = i, d
        end
    end
    return best, bestD
end

-- one leg: "running", "done" or the reason of a stop
function ADBandTurn.driveLeg(vehicle, bt, dt)
    local leg = bt.legs[bt.legIndex]
    local sdm = vehicle.ad.specialDrivingModule
    if bt.loggedLeg ~= bt.legIndex then
        bt.loggedLeg = bt.legIndex
        print(string.format("[AD-DemiTour] %s: temps %d/%d : %s %.0f m", ADBandTurn.logName(vehicle), bt.legIndex, #bt.legs, leg.dir > 0 and "avant" or "arriere", leg.length))
    end
    if bt.pause > 0 then
        bt.pause = bt.pause - dt
        sdm:stopVehicle()
        sdm:update(dt)
        if bt.pause <= 0 then
            sdm:reset()
        end
        return "running"
    end
    local axleNode = vehicle.getAIDirectionNode ~= nil and vehicle:getAIDirectionNode() or vehicle.components[1].node
    local x, y, z = getWorldTranslation(axleNode)
    local points = leg.points
    if #points == 0 then
        return "done"
    end
    local last = points[#points]
    -- stuck: less than STUCK_MOVE in STUCK_TIME (the speed alone can jitter above zero)
    if bt.stillPos == nil or MathUtil.vector2Length(x - bt.stillPos.x, z - bt.stillPos.z) > ADBandTurn.STUCK_MOVE then
        bt.stillPos = {x = x, z = z}
        bt.stillTime = 0
    else
        bt.stillTime = bt.stillTime + dt
        if bt.stillTime > ADBandTurn.STUCK_TIME then
            local trailerNode = vehicle.trailer ~= nil and vehicle.trailer.components ~= nil and vehicle.trailer.components[1].node or nil
            local articulation = trailerNode ~= nil and math.deg(math.abs(ADBandTurn.wrap(headingOfNode(axleNode) - headingOfNode(trailerNode)))) or -1
            return string.format("bloque %.0f s sur place (%s ; vitesse %.1f km/h, moteur %s, articulation %.0f deg, temps %s)", bt.stillTime / 1000,
                tostring(bt.holdReason or "pas d'avance"), math.abs(vehicle.lastSpeedReal or 0) * 3600,
                tostring(vehicle.getIsMotorStarted ~= nil and vehicle:getIsMotorStarted()), articulation, leg.dir > 0 and "avant" or "arriere")
        end
    end
    -- the engine may have been stopped while waiting (stopped timer of the special driving module)
    sdm:releaseVehicle()
    if vehicle.startMotor and not vehicle:getIsMotorStarted() and vehicle:getCanMotorRun() then
        vehicle:startMotor()
    end
    if leg.dir > 0 then
        local i, d = nearestIndex(points, bt.pointIndex, x, z, false)
        bt.pointIndex = i
        if d > ADBandTurn.MAX_DEVIATION then
            return string.format("ecart de %.1f m en marche avant", d)
        end
        -- the front wheels never go into the crop: the line was cut inside, stop and plan again from here
        if bt.map ~= nil then
            local _, _, _, frontCrop = ADBandTurn.checkBody(bt.map, x, z, headingOfNode(axleNode), bt.geo.tractorBox)
            if (frontCrop or 0) > ADBandTurn.FRONT_CROP_TOLERANCE then
                return string.format("avant du tracteur dans la culture (ecart %.1f m)", d)
            end
        end
        -- end of the leg reached or passed (along its last direction)
        local prev = points[math.max(1, #points - 2)]
        local ex, ez = last.x - prev.x, last.z - prev.z
        if i >= #points - 1 or (ex * (last.x - x) + ez * (last.z - z)) <= 0 then
            return "done"
        end
        local j = i
        while j < #points and MathUtil.vector2Length(points[j].x - x, points[j].z - z) < ADBandTurn.LOOK_AHEAD do
            j = j + 1
        end
        local t = points[j]
        local lx, lz = AutoDrive.getDriveDirection(vehicle, t.x, y, t.z, axleNode)
        local maxAngle = 60
        if vehicle.maxRotation then
            maxAngle = vehicle.maxRotation > TWO_PI and vehicle.maxRotation or math.deg(vehicle.maxRotation)
        end
        sdm:releaseVehicle()
        if vehicle.startMotor and not vehicle:getIsMotorStarted() and vehicle:getCanMotorRun() then
            vehicle:startMotor()
        end
        vehicle.ad.trailerModule:handleTrailerReversing(false)
        AutoDrive.driveInDirection(vehicle, dt, maxAngle, 0.5, 0.2, 20, true, true, lx, lz, ADBandTurn.SPEED, 1)
        return "running"
    end
    -- reverse: the trailer axle follows its planned line (special driving module, as the track reverse)
    local reverseNode = sdm:getReverseNode()
    if reverseNode == nil then
        return "plus de point de recul"
    end
    local rx, _, rz = getWorldTranslation(reverseNode)
    local i, d = nearestIndex(points, bt.pointIndex, rx, rz, true)
    bt.pointIndex = i
    if d > ADBandTurn.MAX_DEVIATION + 0.5 then
        return string.format("ecart de %.1f m en marche arriere", d)
    end
    local prev = points[math.max(1, #points - 2)]
    local ex, ez = last.x - prev.x, last.z - prev.z
    if i >= #points - 1 or (ex * (last.x - x) + ez * (last.z - z)) <= 0 then
        return "done"
    end
    local j = i
    while j < #points and MathUtil.vector2Length(points[j].tx - rx, points[j].tz - rz) < ADBandTurn.LOOK_BEHIND do
        j = j + 1
    end
    local t = points[j]
    if vehicle.ad.collisionDetectionModule ~= nil and vehicle.ad.collisionDetectionModule:checkReverseCollision() then
        -- the reverse module holds the train: something behind the trailer
        if bt.holdReason == nil then
            print(string.format("[AD-DemiTour] %s: recul retenu, obstacle detecte derriere la remorque", ADBandTurn.logName(vehicle)))
        end
        bt.holdReason = "obstacle derriere la remorque"
    else
        bt.holdReason = nil
    end
    sdm:reverseToTargetLocation(dt, {x = t.tx, y = y, z = t.tz}, ADBandTurn.SPEED)
    return "running"
end
