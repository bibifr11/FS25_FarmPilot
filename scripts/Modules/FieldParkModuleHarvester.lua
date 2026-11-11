-- ============================================================================================================
-- FarmPilot : FieldParkModuleHarvester.lua
-- Complément de FieldParkModule.lua : le sens de marche de la machine (moissonneuse ou ensileuse) et le sens de sa
-- 1re fourrière, qui donnent le sens des bennes garées le long du bord.
--
-- Règles : le sens de la 1re fourrière (ADFieldPark.SENSE_RUN m le long du bord dans le même sens, pas un virage en
-- bout de rang) est mesuré une fois et gardé pour tout le champ ; avec Courseplay, il est lu tout de suite dans la
-- course de la machine. Nouveau champ : nouveau sens à mesurer. Une place mémorisée du champ dans l'autre sens est
-- oubliée. Les bennes n'entrent au champ que si le sens est connu, une place est mémorisée, ou une benne y est déjà.
--
-- Branché par : ADHarvestManager:update (trackHarvester, pour chaque machine qui travaille) ; FieldParkModuleSearch.lua
-- (getHarvesterSense, updateHarvesterMotion) ; WaitForCallTaskRoadside.lua (canParkFor).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFieldPark.MOTION_MIN = 2                          -- m the harvester must have moved to give its direction
ADFieldPark.MOTION_TTL = 120000                     -- ms a measured direction of the harvester stays valid
ADFieldPark.TRACK_INTERVAL = 1000                   -- ms between two looks at a working harvester
ADFieldPark.SENSE_RUN = 30                          -- m driven along the border the same way: a headland, not a turn at a row end
ADFieldPark.SENSE_BORDER = 15                       -- m at most between the harvester on its headland and the border

-- ------------------------------------------------------------------------------------------------------------
-- Sens de marche de la machine (mesuré sur ses positions)
-- ------------------------------------------------------------------------------------------------------------
-- direction the harvester drives in, measured on its positions (the node axis of some harvesters points backwards)
function ADFieldPark.updateHarvesterMotion(harvester)
    if harvester == nil or harvester.components == nil then
        return nil
    end
    local hx, _, hz = getWorldTranslation(harvester.components[1].node)
    local m = ADFieldPark.harvesterMotion[harvester]
    if m == nil then
        m = {x = hx, z = hz, t = g_time}
        ADFieldPark.harvesterMotion[harvester] = m
    end
    local d = MathUtil.vector2Length(hx - m.x, hz - m.z)
    if d >= ADFieldPark.MOTION_MIN then
        m.dx, m.dz, m.tDir = (hx - m.x) / d, (hz - m.z) / d, g_time
        m.x, m.z, m.t = hx, hz, g_time
    elseif g_time - m.t > 15000 then
        -- standing still: start a new measure from here
        m.x, m.z, m.t = hx, hz, g_time
    end
    if m.dx ~= nil and g_time - m.tDir < ADFieldPark.MOTION_TTL then
        return m.dx, m.dz
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Sens de la 1re fourrière (mesuré, ou lu dans la course Courseplay)
-- ------------------------------------------------------------------------------------------------------------
-- the way the harvester goes round the field along its border (headlands): +1 / -1 seen from the border outward
-- normal, nil while unknown. A parked train along any border faces the same way as the harvester passes there.
-- Measured once on its first headland (ADFieldPark.trackHarvester), kept for the whole field
function ADFieldPark.getHarvesterSense(search)
    local m = search.harvester ~= nil and ADFieldPark.harvesterMotion[search.harvester] or nil
    if m ~= nil and m.sense ~= nil then
        return m.sense
    end
    if search.memo ~= nil then
        return search.memo.sense
    end
    return nil
end

-- called for every working harvester (ADHarvestManager:update): follows it all the time and keeps the sense of its
-- first headland, ADFieldPark.SENSE_RUN m driven along the border the same way (not a turn at the end of a row)
function ADFieldPark.trackHarvester(harvester)
    if harvester == nil or harvester.components == nil then
        return
    end
    local m = ADFieldPark.harvesterMotion[harvester]
    if m ~= nil and m.trackTime ~= nil and g_time - m.trackTime < ADFieldPark.TRACK_INTERVAL and g_time >= m.trackTime then
        return
    end
    ADFieldPark.updateHarvesterMotion(harvester)
    m = ADFieldPark.harvesterMotion[harvester]
    m.trackTime = g_time
    local hx, hy, hz = getWorldTranslation(harvester.components[1].node)
    -- Courseplay (even standing still): the sense of the first headland is in the course of the harvester, known at once
    local courseSense = ADFieldPark.getCourseSense(harvester, m)
    if courseSense ~= nil and courseSense ~= m.sense then
        m.sense, m.senseArea, m.senseX, m.senseZ = courseSense, nil, hx, hz
        print(string.format("[AD-File] %s: sens de la 1re fourriere lu dans la course Courseplay (%d), garde pour tout le champ", tostring(harvester:getName()), courseSense))
        local memo = ADFieldPark.findMemo(harvester)
        if memo ~= nil and memo.sense ~= courseSense then
            print(string.format("[AD-File] %s: place memorisee du champ dans l'autre sens, oubliee", tostring(harvester:getName())))
            ADFieldPark.forgetMemo(memo)
        end
    end
    if m.lastX == nil then
        m.lastX, m.lastZ = hx, hz
        return
    end
    local d = MathUtil.vector2Length(hx - m.lastX, hz - m.lastZ)
    if d < 1 then
        return
    end
    local mdx, mdz = (hx - m.lastX) / d, (hz - m.lastZ) / d
    m.lastX, m.lastZ = hx, hz
    if d > 50 or not AutoDrive.checkIsOnField(hx, hy, hz) then
        -- moved on the road, or teleported
        m.run, m.runSense = 0, nil
        return
    end
    if m.area == nil or (not m.area.capped and not PathFinderModule.isInFieldArea(m.area, hx, hz)) then
        m.area = ADFieldPark.getHarvesterArea(hx, hz)
    end
    -- another field: its first headland gives a new sense
    if m.sense ~= nil and m.senseArea ~= nil and m.area ~= m.senseArea
        and (m.senseArea.capped or not PathFinderModule.isInFieldArea(m.senseArea, hx, hz))
        and (not m.senseArea.capped or MathUtil.vector2Length(hx - m.senseX, hz - m.senseZ) > ADFieldPark.HARVESTER_RANGE) then
        print(string.format("[AD-File] %s: nouveau champ, sens de la 1re fourriere a mesurer", tostring(harvester:getName())))
        m.sense, m.senseArea = nil, nil
    end
    if m.sense ~= nil then
        return
    end
    local area, relaxed = ADFieldPark.area, ADFieldPark.relaxed
    ADFieldPark.area, ADFieldPark.relaxed = m.area, false
    local bx, bz, tx, tz, nx, nz = ADFieldPark.findBorder(hx, hz, hy)
    ADFieldPark.area, ADFieldPark.relaxed = area, relaxed
    local s = nil
    if bx ~= nil and math.abs((bx - hx) * nx + (bz - hz) * nz) < ADFieldPark.SENSE_BORDER and math.abs(mdx * tx + mdz * tz) > 0.85 then
        s = (nx * mdz - nz * mdx) > 0 and 1 or -1
    end
    if s ~= nil and s == m.runSense then
        m.run = m.run + d
    else
        m.run, m.runSense = s ~= nil and d or 0, s
    end
    if s ~= nil and m.run >= ADFieldPark.SENSE_RUN then
        m.sense, m.senseArea, m.senseX, m.senseZ = s, m.area, hx, hz
        print(string.format("[AD-File] %s: sens de la 1re fourriere mesure (%d), garde pour tout le champ", tostring(harvester:getName()), s))
        -- a remembered place of this field that faces the other way is from another harvest: forgotten
        local memo = ADFieldPark.findMemo(harvester)
        if memo ~= nil and memo.sense ~= s then
            print(string.format("[AD-File] %s: place memorisee du champ dans l'autre sens, oubliee", tostring(harvester:getName())))
            ADFieldPark.forgetMemo(memo)
        end
    end
end

-- sense of the outermost headland of the Courseplay course of the harvester (or of the tractor pulling it): +1 / -1
-- like getHarvesterSense, from the signed area of the headland loop; nil without Courseplay course or headland
function ADFieldPark.getCourseSense(harvester, m)
    local ok, sense = FarmPilotCall(function()
        for _, v in ipairs({harvester, harvester.getRootVehicle ~= nil and harvester:getRootVehicle() or nil, harvester.trailingVehicle}) do
            local course = v ~= nil and v.getFieldWorkCourse ~= nil and v:getFieldWorkCourse() or nil
            if course ~= nil and course.waypoints ~= nil then
                if m.course == course then
                    return m.courseSense
                end
                local first, last, prev = nil, nil, nil
                local area, n = 0, 0
                for _, wp in ipairs(course.waypoints) do
                    local a = wp.attributes
                    if a ~= nil and a:getHeadlandPassNumber() == 1 and not a:isIslandHeadland() and wp.x ~= nil and wp.z ~= nil then
                        if prev ~= nil then
                            area = area + prev.x * wp.z - wp.x * prev.z
                        end
                        first = first or wp
                        prev, last, n = wp, wp, n + 1
                    end
                end
                local s = nil
                if n >= 10 then
                    area = area + last.x * first.z - first.x * last.z
                    s = area > 0 and 1 or -1
                end
                m.course, m.courseSense = course, s
                return s
            end
        end
        return nil
    end)
    return ok and sense or nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Les bennes peuvent-elles entrer au champ ?
-- ------------------------------------------------------------------------------------------------------------
-- the unloaders may go into the field: the sense of the harvester is known, a place is remembered for its field,
-- or another unloader already stands there (the next ones queue behind it)
function ADFieldPark.canParkFor(vehicle, harvester)
    if harvester == nil then
        return true
    end
    local m = ADFieldPark.harvesterMotion[harvester]
    return (m ~= nil and m.sense ~= nil) or ADFieldPark.findMemo(harvester) ~= nil
        or ADFieldPark.countInField(vehicle, harvester) > 0
end
