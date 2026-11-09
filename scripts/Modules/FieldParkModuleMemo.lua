-- ============================================================================================================
-- FarmPilot : FieldParkModuleMemo.lua
-- Complément de FieldParkModule.lua : la place mémorisée de chaque champ (moissonneuse et ensileuse).
--
-- Règles : la 1re benne qui atteint sa place dans un champ sans place mémorisée la mémorise, avec le chemin qui l'y a
-- menée (pas une place en file derrière une autre benne, ni au bord de la route). Les bennes suivantes y vont sans
-- nouvelle recherche, par le même chemin si elles partent du même endroit dans le même sens. Gardé dans la partie
-- (AutoDrive_fieldPark.xml) pour la session suivante ; les chemins mémorisés avant l'entrée droite le long du bord
-- (23/10 12h55) ne sont pas gardés.
--
-- Branché par : WaitForCallTaskFieldPark.lua (rememberSpot, getMemoPath), DriveToVehicleTaskFieldPark.lua
-- (getMemoPath) ; FieldParkModuleSearch.lua et FieldParkModuleHarvester.lua (findMemo, forgetMemo).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages et état (places mémorisées)
-- ------------------------------------------------------------------------------------------------------------
ADFieldPark.memos = {}                              -- place remembered for each field (first unloader parked there)
ADFieldPark.MEMO_START_DISTANCE = 3                 -- m: an unloader starting this close to the remembered start takes the same path
ADFieldPark.MEMO_START_ANGLE = 20                   -- degrees, same for its heading

-- ------------------------------------------------------------------------------------------------------------
-- Sauvegarde (AutoDrive_fieldPark.xml)
-- ------------------------------------------------------------------------------------------------------------
-- place found the first time in a field, used by all the next unloaders (no new search, same path). Kept in the
-- savegame (AutoDrive_fieldPark.xml) for the next game session
function ADFieldPark.getMemoFile()
    local mission = g_currentMission
    local dir = mission ~= nil and mission.missionInfo ~= nil and mission.missionInfo.savegameDirectory or nil
    if dir == nil then
        return nil
    end
    return dir .. "/AutoDrive_fieldPark.xml"
end

function ADFieldPark.loadMemos()
    if ADFieldPark.memosLoaded then
        return
    end
    ADFieldPark.memosLoaded = true
    local file = ADFieldPark.getMemoFile()
    if file == nil or not fileExists(file) then
        return
    end
    local xml = loadXMLFile("AutoDrive_fieldPark", file)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while true do
        local key = string.format("fieldPark.spot(%d)", i)
        local fx = getXMLFloat(xml, key .. "#fx")
        if fx == nil then
            break
        end
        local memo = {
            fx = fx, fz = getXMLFloat(xml, key .. "#fz"),
            cx = getXMLFloat(xml, key .. "#cx"), cz = getXMLFloat(xml, key .. "#cz"),
            dirX = getXMLFloat(xml, key .. "#dirX"), dirZ = getXMLFloat(xml, key .. "#dirZ"),
            sense = getXMLInt(xml, key .. "#sense")
        }
        local sx = getXMLFloat(xml, key .. "#sx")
        -- paths remembered before the straight lead-in (23/10 12h55) ended askew: not kept
        if sx ~= nil and getXMLBool(xml, key .. "#straight") == true then
            memo.start = {x = sx, z = getXMLFloat(xml, key .. "#sz"), dx = getXMLFloat(xml, key .. "#sdx"), dz = getXMLFloat(xml, key .. "#sdz")}
            memo.target = {x = getXMLFloat(xml, key .. "#tx"), z = getXMLFloat(xml, key .. "#tz")}
            memo.path = {}
            local j = 0
            while true do
                local pk = string.format("%s.p(%d)", key, j)
                local px = getXMLFloat(xml, pk .. "#x")
                if px == nil then
                    break
                end
                table.insert(memo.path, {x = px, y = getXMLFloat(xml, pk .. "#y"), z = getXMLFloat(xml, pk .. "#z")})
                j = j + 1
            end
            if #memo.path < 2 then
                memo.path, memo.start, memo.target = nil, nil, nil
            end
        end
        if memo.fz ~= nil and memo.cx ~= nil and memo.cz ~= nil and memo.dirX ~= nil and memo.dirZ ~= nil and memo.sense ~= nil then
            table.insert(ADFieldPark.memos, memo)
        end
        i = i + 1
    end
    delete(xml)
    print(string.format("[AD-File] places memorisees chargees : %d champ(s)", #ADFieldPark.memos))
end

function ADFieldPark.saveMemos()
    local file = ADFieldPark.getMemoFile()
    if file == nil then
        return
    end
    local xml = createXMLFile("AutoDrive_fieldPark", file, "fieldPark")
    if xml == nil or xml == 0 then
        return
    end
    for i, memo in ipairs(ADFieldPark.memos) do
        local key = string.format("fieldPark.spot(%d)", i - 1)
        setXMLFloat(xml, key .. "#fx", memo.fx)
        setXMLFloat(xml, key .. "#fz", memo.fz)
        setXMLFloat(xml, key .. "#cx", memo.cx)
        setXMLFloat(xml, key .. "#cz", memo.cz)
        setXMLFloat(xml, key .. "#dirX", memo.dirX)
        setXMLFloat(xml, key .. "#dirZ", memo.dirZ)
        setXMLInt(xml, key .. "#sense", memo.sense)
        if memo.path ~= nil then
            setXMLBool(xml, key .. "#straight", true)
            setXMLFloat(xml, key .. "#sx", memo.start.x)
            setXMLFloat(xml, key .. "#sz", memo.start.z)
            setXMLFloat(xml, key .. "#sdx", memo.start.dx)
            setXMLFloat(xml, key .. "#sdz", memo.start.dz)
            setXMLFloat(xml, key .. "#tx", memo.target.x)
            setXMLFloat(xml, key .. "#tz", memo.target.z)
            for j, p in ipairs(memo.path) do
                local pk = string.format("%s.p(%d)", key, j - 1)
                setXMLFloat(xml, pk .. "#x", p.x)
                setXMLFloat(xml, pk .. "#y", p.y)
                setXMLFloat(xml, pk .. "#z", p.z)
            end
        end
    end
    saveXMLFile(xml)
    delete(xml)
end

-- ------------------------------------------------------------------------------------------------------------
-- Place mémorisée d'un champ : trouver, oublier, mémoriser, chemin
-- ------------------------------------------------------------------------------------------------------------
-- remembered place of the field the harvester works in
function ADFieldPark.findMemo(harvester)
    if harvester == nil or harvester.components == nil then
        return nil
    end
    ADFieldPark.loadMemos()
    if #ADFieldPark.memos == 0 then
        return nil
    end
    local hx, _, hz = getWorldTranslation(harvester.components[1].node)
    local m = ADFieldPark.harvesterMotion[harvester]
    local area = m ~= nil and m.area or nil
    if area == nil or (not area.capped and not PathFinderModule.isInFieldArea(area, hx, hz)) then
        area = ADFieldPark.getHarvesterArea(hx, hz)
    end
    if area == nil then
        return nil
    end
    for _, memo in ipairs(ADFieldPark.memos) do
        if area.capped then
            if MathUtil.vector2Length(memo.cx - hx, memo.cz - hz) < ADFieldPark.HARVESTER_RANGE and AutoDrive.checkIsOnField(memo.fx, 0, memo.fz) then
                return memo
            end
        elseif PathFinderModule.isInFieldArea(area, memo.fx, memo.fz) then
            return memo
        end
    end
    return nil
end

function ADFieldPark.forgetMemo(memo)
    table.removeValue(ADFieldPark.memos, memo)
    ADFieldPark.saveMemos()
end

-- the first unloader reached its place in a field with no remembered place yet: remember it, with the path that led
-- there. Not for a place in line behind another unloader, nor beside the road
function ADFieldPark.rememberSpot(vehicle, spot, path, start)
    if spot == nil or spot.queued or spot.roadside or spot.memo ~= nil or spot.sense == nil or spot.harvester == nil then
        return
    end
    if ADFieldPark.findMemo(spot.harvester) ~= nil then
        return
    end
    -- a point surely inside the field, a few meters from the border, identifies the field
    local fx, fz = nil, nil
    for _, d in ipairs({4, 6, 8}) do
        for a = 0, 315, 45 do
            local x, z = spot.cx + math.sin(math.rad(a)) * d, spot.cz + math.cos(math.rad(a)) * d
            if fx == nil and AutoDrive.checkIsOnField(x, 0, z) and AutoDrive.checkIsOnField(spot.cx + math.sin(math.rad(a)) * (d + 2), 0, spot.cz + math.cos(math.rad(a)) * (d + 2)) then
                fx, fz = x, z
            end
        end
    end
    if fx == nil then
        return
    end
    local memo = {fx = fx, fz = fz, cx = spot.cx, cz = spot.cz, dirX = spot.dirX, dirZ = spot.dirZ, sense = spot.sense}
    if path ~= nil and #path >= 2 and start ~= nil then
        memo.path = {}
        for _, p in ipairs(path) do
            table.insert(memo.path, {x = p.x, y = p.y, z = p.z})
        end
        memo.start = {x = start.x, z = start.z, dx = start.dx, dz = start.dz}
        memo.target = {x = spot.x, z = spot.z}
    end
    table.insert(ADFieldPark.memos, memo)
    ADFieldPark.saveMemos()
    print(string.format("[AD-File] %s: place du champ memorisee (%.0f,%.0f), les bennes suivantes y iront directement", tostring(vehicle:getName()), spot.cx, spot.cz))
end

-- the remembered path, when this unloader starts from the same place toward the same stop
function ADFieldPark.getMemoPath(vehicle, spot)
    local memo = spot.memo
    if memo == nil or memo.path == nil then
        return nil
    end
    local x, _, z = ADTrafficYieldModule.getPosition(vehicle)
    local dx, dz = ADTrafficYieldModule.getDirection(vehicle)
    if MathUtil.vector2Length(x - memo.start.x, z - memo.start.z) > ADFieldPark.MEMO_START_DISTANCE
        or dx * memo.start.dx + dz * memo.start.dz < math.cos(math.rad(ADFieldPark.MEMO_START_ANGLE))
        or MathUtil.vector2Length(spot.x - memo.target.x, spot.z - memo.target.z) > 1 then
        return nil
    end
    local path = {}
    for _, p in ipairs(memo.path) do
        table.insert(path, {x = p.x, y = p.y, z = p.z})
    end
    return path
end
