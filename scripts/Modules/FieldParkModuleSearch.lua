-- ============================================================================================================
-- FarmPilot : FieldParkModuleSearch.lua
-- Complément de FieldParkModule.lua : la recherche des places le long du bord du champ. Moissonneuse et ensileuse ;
-- les parties marquées (ensileuse) ne servent qu'aux bennes d'ensileuse (search.chopper, search.narrow).
--
-- La recherche se fait sur plusieurs images (un point d'anneau par appel de searchStep) : d'abord les places en file
-- derrière les bennes déjà garées et la place mémorisée du champ, puis des anneaux autour de l'entrée (RADII), chaque
-- place parallèle au bord, la ligne médiane de l'attelage sur la bordure. Passes suivantes quand rien ne va : sans la
-- marge à la culture (bande déjà récoltée), (ensileuse) dans la bande étroite sans place pour doubler (27/10 19:51),
-- puis des deux côtés de l'entrée, plus loin (WIDE_RADII, 25/10 19:06).
-- Règles : place du côté où la machine est partie à l'entrée, nez dans le sens de sa 1re fourrière (27/10 20:35 :
-- les places dans le mauvais sens ne comptent pas) ; pas au-delà d'une benne garée (25/10) ; file derrière une benne
-- garée sur sa bande, même si la culture est proche (25/10) ; (ensileuse) place pour qu'une autre benne double
-- (PASS_MIN_WIDTH) et hors du chemin de l'ensileuse (LANE_LENGTH).
--
-- Branché par : WaitForCallTaskFieldPark.lua et DriveToVehicleTaskFieldPark.lua (newSearch, searchStep) ;
-- PathFinderModulePark.lua et CombineUnloaderModeTracks.lua (getPassWidth, isInHarvesterWay).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFieldPark.RADII = {45, 55, 65, 75, 85}            -- m, rings searched around the vehicle (beyond ENTRANCE_CLEARANCE)
ADFieldPark.ANGLE_STEP = 10                         -- degrees between two candidates on a ring
-- 25/10 19:06 (Puma: no place found at the entrance, free harvested ground along the border near the entrance
-- and along the far headland, then the full one could not come out): last pass, both sides, farther, closer to the
-- entrance
ADFieldPark.WIDE_RADII = {30, 40, 55, 70, 85, 100, 115, 130, 145}
ADFieldPark.WIDE_ENTRANCE_CLEARANCE = 25
ADFieldPark.ENTRANCE_CLEARANCE = 40                 -- m between the parked train and the place where the unloader waits (field entrance)
ADFieldPark.NOSE_SEARCH = 30                        -- m looked at ahead of the tractor to find the field it waits at
ADFieldPark.CENTRE_OFFSETS = {0, 0.5, 1, 1.5, 2}    -- m from the border to the centre line of the train, into the field: astride the border first, half on the grass
-- forage harvester (opening a field, narrow cut strip): a spot must leave room for another trailer to pass,
-- and stay out of the harvester's way
ADFieldPark.PASS_MIN_WIDTH = 4                      -- m of free cut ground beside the parked train
ADFieldPark.PASS_SEARCH = 12                        -- m looked at beside the train
ADFieldPark.LANE_LENGTH = 60                        -- m ahead of the harvester kept free
ADFieldPark.LANE_MARGIN = 2                         -- m added to the harvester half width and the train half width
ADFieldPark.HARVESTER_MIN_DISTANCE = 15             -- m between the parked train and the harvester
ADFieldPark.QUEUE_ENTRANCE_CLEARANCE = 15           -- forage harvester: m kept from the entrance by an unloader queued behind another
ADFieldPark.BETWEEN_MARGIN = 2 -- m added to the half length of the parked train across the straight line to the place

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale : nouvelle recherche, un pas de recherche
-- ------------------------------------------------------------------------------------------------------------
-- starts a search of waiting places inside the field around the vehicle. The search is spread over several
-- frames (one candidate position per call of ADFieldPark.searchStep) to avoid a hitch
-- origin (optional): {x, z, dx, dz} the search starts from instead of where the vehicle stands (an unloader waiting
-- beside the road looks again from the entrance it came to, without driving there)
function ADFieldPark.newSearch(vehicle, origin)
    ADTrafficYieldModule.measureTrain(vehicle)
    local search = {vehicle = vehicle}
    search.x, search.py, search.z = ADTrafficYieldModule.getPosition(vehicle)
    search.vdx, search.vdz = ADTrafficYieldModule.getDirection(vehicle)
    if origin ~= nil then
        search.x, search.z, search.vdx, search.vdz = origin.x, origin.z, origin.dx, origin.dz
        search.py = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, origin.x, 0, origin.z)
    end
    search.halfW = ADTrafficYieldModule.getWidth(vehicle) / 2 + 0.5
    search.front, search.rear = ADTrafficYieldModule.getTrainExtents(vehicle)
    search.length = search.front + search.rear
    search.halfL = search.length / 2 + 0.5
    local maxRadius = ADFieldPark.RADII[#ADFieldPark.RADII]
    search.nearby = ADFieldPark.getWayPointsAround(search.x, search.z, maxRadius + search.length + 10)
    search.candidates = {}
    search.radiusIndex = 1
    search.angle = 0
    -- the harvester must already be working in the field: park along the border on its side (left or right of
    -- the entrance), where it has already harvested. Otherwise there is nothing to do, wait at the entrance
    local harvester = ADFieldPark.findHarvester(vehicle, search.x, search.z)
    if harvester == nil then
        search.result = "no harvester"
        return search
    end
    local hx, hy, hz = getWorldTranslation(harvester.components[1].node)
    search.harvester = harvester
    search.chopper = harvester.ad ~= nil and harvester.ad.isChopper == true
    if not AutoDrive.checkIsOnField(hx, hy, hz) then
        search.result = "harvester not in the field yet"
        return search
    end
    -- the field to park in is the one the nose of the tractor points to (it waits at its entrance); the
    -- harvester must work in that one, otherwise the unloader waits for it at the entrance
    local noseArea = nil
    for d = 2, ADFieldPark.NOSE_SEARCH, 2 do
        local fx, fz = search.x + search.vdx * d, search.z + search.vdz * d
        if AutoDrive.checkIsOnField(fx, search.py, fz) then
            noseArea = ADFieldPark.getHarvesterArea(fx, fz)
            search.noseX, search.noseZ = fx, fz
            break
        end
    end
    search.area = noseArea or ADFieldPark.getHarvesterArea(hx, hz)
    if noseArea ~= nil and not noseArea.capped and not PathFinderModule.isInFieldArea(noseArea, hx, hz) then
        search.result = "harvester not in the field ahead"
        return search
    end
    -- GIANTS local +x (left) of the heading is (dz, -dx)
    local lateral = (hx - search.x) * search.vdz - (hz - search.z) * search.vdx
    if math.abs(lateral) > 5 then
        search.side = lateral > 0 and 1 or -1
    end
    -- the place remembered for this field, and the sense of the first headland: unknown, nobody in the field yet
    -- and nothing remembered, wait beside the road (no place chosen at random)
    search.memo = ADFieldPark.findMemo(harvester)
    -- the side is the one the harvester set off to along the border at the entrance: the unloaders turn
    -- the same way and park in the cutting direction. Where it is now only when its sense is not known
    local sense = ADFieldPark.getHarvesterSense(search)
    if sense ~= nil and search.noseX ~= nil then
        local area, relaxed = ADFieldPark.area, ADFieldPark.relaxed
        ADFieldPark.area, ADFieldPark.relaxed = search.area, false
        local bx, _, tx, tz, nx, nz = ADFieldPark.findBorder(search.noseX, search.noseZ, search.py)
        ADFieldPark.area, ADFieldPark.relaxed = area, relaxed
        if bx ~= nil then
            -- the harvester goes along this border with (n x d) of the sign of its sense
            local dx, dz = tx, tz
            if ((nx * dz - nz * dx) > 0 and 1 or -1) ~= sense then
                dx, dz = -dx, -dz
            end
            local across = dx * search.vdz - dz * search.vdx
            if math.abs(across) > 0.3 then
                search.side = across > 0 and 1 or -1
                vehicle.ad.trafficYieldModule:log("field park: side %d, the way the harvester set off along the border at the entrance", search.side)
                -- a place remembered on the other side (before this rule) is forgotten
                local memo = search.memo
                if memo ~= nil and ((memo.cx - search.x) * search.vdz - (memo.cz - search.z) * search.vdx) * search.side < 0 then
                    vehicle.ad.trafficYieldModule:log("field park: remembered place on the other side, forgotten")
                    ADFieldPark.forgetMemo(memo)
                    search.memo = nil
                end
            end
        end
    end
    if sense == nil and search.memo == nil and ADFieldPark.countInField(vehicle, harvester) == 0 then
        search.result = "harvester direction not known yet (first headland not done), waiting beside the road"
        search.waitSense = true
    end
    return search
end

-- one step of the search; returns nil while searching, then the list of spots best first: along the field
-- border, then close to the vehicle, then nose ahead. Each spot is {x, y, z, dirX, dirZ}, where the tractor stops
function ADFieldPark.searchStep(search)
    ADFieldPark.relaxed = false
    if search.result ~= nil then
        return {}
    end
    ADFieldPark.area = search.area
    ADFieldPark.relaxed = search.relaxed == true
    ADFieldPark.updateHarvesterMotion(search.harvester)
    if not search.queueDone then
        search.queueDone = true
        ADFieldPark.addQueueCandidates(search)
        ADFieldPark.addMemoCandidate(search)
        if search.memoFree then
            -- the remembered place (or the line behind it): no search along the border
            return ADFieldPark.pickSpots(search)
        end
        return nil
    end
    local radius = (search.wide and ADFieldPark.WIDE_RADII or ADFieldPark.RADII)[search.radiusIndex]
    if radius ~= nil then
        ADFieldPark.addCandidates(search, radius, search.angle)
        search.angle = search.angle + ADFieldPark.ANGLE_STEP
        if search.angle >= 360 then
            search.angle = 0
            search.radiusIndex = search.radiusIndex + 1
        end
        return nil
    end
    return ADFieldPark.pickSpots(search)
end

-- ------------------------------------------------------------------------------------------------------------
-- Places en file derrière les bennes garées, place mémorisée du champ
-- ------------------------------------------------------------------------------------------------------------
-- spots right behind, then right in front of the unloaders already parked nearby, in line with them, so the
-- unloaders queue along the border. They come before any other candidate
function ADFieldPark.addQueueCandidates(search)
    for other, spot in pairs(ADFieldPark.parked) do
        local valid = other ~= search.vehicle and other.isDeleted ~= true and other.components ~= nil and spot.cx ~= nil
        if valid and spot.roadside then
            -- waiting beside the road, not a place in the field to queue behind
        elseif valid and not spot.reserved then
            -- still standing there
            local ox, _, oz = ADTrafficYieldModule.getPosition(other)
            valid = MathUtil.vector2Length(ox - spot.x, oz - spot.z) < 5
        end
        if not valid then
            ADFieldPark.parked[other] = nil
        elseif MathUtil.vector2Length(spot.cx - search.x, spot.cz - search.z) < ADFieldPark.RADII[#ADFieldPark.RADII] + 50 then
            local offset = spot.halfL + ADFieldPark.QUEUE_GAP + search.halfL
            -- right behind it only (order of arrival along the border)
            for rank, sign in ipairs({-1}) do
                local cx, cz = spot.cx + spot.dirX * sign * offset, spot.cz + spot.dirZ * sign * offset
                -- forage harvester: in line behind the last one, in order of arrival (queue rules, see isSpotAllowed)
                local queued = true
                -- 25/10: the line behind a parked unloader is on the same harvested strip as its place: the crop
                -- beyond the train does not matter (relaxed, as for the remembered place), and the refusal is logged
                ADFieldPark.reject = "taken, in the harvester's way or too close to the entrance"
                local relaxed = ADFieldPark.relaxed
                ADFieldPark.relaxed = true
                local maxH = ADFieldPark.isSpotAllowed(search, cx, cz, spot.dirX, spot.dirZ, queued)
                    and ADFieldPark.isGroundFree(cx, cz, spot.dirX, spot.dirZ, search.halfW, search.halfL, search.nearby, search.py) or nil
                ADFieldPark.relaxed = relaxed
                if maxH == nil then
                    search.vehicle.ad.trafficYieldModule:log("field park: no place in line behind %s at x=%.0f z=%.0f (%s)", ADTrafficYieldModule.getName(other), cx, cz, tostring(ADFieldPark.reject))
                end
                if maxH ~= nil then
                    local c = {cx = cx, cz = cz, dx = spot.dirX, dz = spot.dirZ, maxH = maxH, cost = -1000 + rank}
                    if sign < 0 then
                        -- behind it: moves up to its place when it leaves
                        c.ahead, c.aheadVehicle = spot, other
                    end
                    table.insert(search.candidates, c)
                end
            end
        end
    end
end

-- the place remembered for this field, free and still on clean ground: first choice
function ADFieldPark.addMemoCandidate(search)
    local memo = search.memo
    if memo == nil or search.relaxed then
        return
    end
    for _, c in ipairs(search.candidates) do
        if c.ahead ~= nil and c.ahead.memo == memo then
            -- the remembered place is taken, the line behind it is offered
            search.memoFree = true
        end
    end
    -- queued: no side rule (the unloader may come from another road), never in the harvester's way. The place was
    -- good once: the crop farther than the train itself does not matter (relaxed)
    ADFieldPark.reject = "taken"
    local relaxed = ADFieldPark.relaxed
    ADFieldPark.relaxed = true
    local maxH = ADFieldPark.isSpotAllowed(search, memo.cx, memo.cz, memo.dirX, memo.dirZ, true)
        and ADFieldPark.isGroundFree(memo.cx, memo.cz, memo.dirX, memo.dirZ, search.halfW, search.halfL, search.nearby, search.py) or nil
    ADFieldPark.relaxed = relaxed
    if maxH ~= nil and search.vehicle.ad.trafficYieldModule:overlapHit(memo.cx, maxH + 1.9, memo.cz, math.atan2(memo.dirX, memo.dirZ), search.halfW, 1.3, search.halfL) then
        maxH = nil
    end
    if maxH ~= nil then
        table.insert(search.candidates, {cx = memo.cx, cz = memo.cz, dx = memo.dirX, dz = memo.dirZ, maxH = maxH, cost = -2000, memo = memo})
        search.memoFree = true
        search.vehicle.ad.trafficYieldModule:log("field park: remembered place of this field is free")
    elseif not search.memoFree then
        search.vehicle.ad.trafficYieldModule:log("field park: remembered place of this field not usable (%s), looking along the border", tostring(ADFieldPark.reject))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Place permise ? (côté de l'entrée, distance à l'entrée, benne garée entre les deux)
-- ------------------------------------------------------------------------------------------------------------
-- on the harvester side of the entrance, and far enough from it
-- queued (forage harvester, in line behind a parked unloader): no side rule, no room-to-pass rule (the line is
-- wanted), QUEUE_ENTRANCE_CLEARANCE from the entrance; never in the harvester's way
function ADFieldPark.isSpotAllowed(search, cx, cz, dx, dz, queued)
    if ADFieldPark.overlapsTakenSpot(search, cx, cz, dx, dz) then
        return false
    end
    if queued then
        if ADFieldPark.isInHarvesterWay(search.harvester, cx, cz, search.halfW, search.halfL) then
            return false
        end
        return ADFieldPark.distanceToFootprint(search.x, search.z, cx, cz, dx, dz, search.halfW, search.halfL) >= ADFieldPark.QUEUE_ENTRANCE_CLEARANCE
    end
    if search.chopper then
        if ADFieldPark.isInHarvesterWay(search.harvester, cx, cz, search.halfW, search.halfL) then
            search.stats = search.stats or {}
            search.stats["harvester way"] = (search.stats["harvester way"] or 0) + 1
            return false
        end
        if not search.narrow and ADFieldPark.getPassWidth(cx, cz, dx, dz, search.halfW, search.halfL) < ADFieldPark.PASS_MIN_WIDTH then
            search.stats = search.stats or {}
            search.stats["no room to pass"] = (search.stats["no room to pass"] or 0) + 1
            return false
        end
    end
    if search.side ~= nil then
        local lateral = (cx - search.x) * search.vdz - (cz - search.z) * search.vdx
        if lateral * search.side <= 0 then
            return false
        end
    end
    if ADFieldPark.isParkedBetween(search, cx, cz) then
        -- 25/10: a place beyond an unloader parked along the border: the way there goes through it
        -- (942 stopped behind the parked 6205). The line behind it is the place for this one
        ADFieldPark.reject = "beyond a parked unloader"
        return false
    end
    return ADFieldPark.distanceToFootprint(search.x, search.z, cx, cz, dx, dz, search.halfW, search.halfL) >= (search.wide and ADFieldPark.WIDE_ENTRANCE_CLEARANCE or ADFieldPark.ENTRANCE_CLEARANCE)
end

-- an unloader parked in the field (not beside the road) stands between the searching unloader and the place (cx, cz):
-- close to the straight line from one to the other, with the parked train's half length as width (it stands along
-- the border, the place farther along the same border)
function ADFieldPark.isParkedBetween(search, cx, cz)
    local vx, vz = cx - search.x, cz - search.z
    local length = MathUtil.vector2Length(vx, vz)
    if length < 1 then
        return false
    end
    vx, vz = vx / length, vz / length
    for other, spot in pairs(ADFieldPark.parked) do
        if other ~= search.vehicle and spot ~= nil and spot.cx ~= nil and not spot.roadside and other.isDeleted ~= true then
            local ox, oz = spot.cx - search.x, spot.cz - search.z
            local along = ox * vx + oz * vz
            local across = math.abs(ox * vz - oz * vx)
            local halfL = spot.halfL or search.halfL
            if along > halfL and along < length - 1 and across < halfL + search.halfW + ADFieldPark.BETWEEN_MARGIN then
                return true
            end
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- (ensileuse) place pour doubler à côté, hors du chemin de l'ensileuse
-- ------------------------------------------------------------------------------------------------------------
-- free cut field ground beside a train footprint (centre cx, cz, direction dx, dz), widest side, in m
function ADFieldPark.getPassWidth(cx, cz, dx, dz, halfW, halfL)
    local best = 0
    for _, side in ipairs({1, -1}) do
        local nx, nz = dz * side, -dx * side
        local width = math.huge
        -- every 2 m from the rear of the trailer to the nose of the tractor: the narrowest place counts
        local steps = math.max(2, math.ceil(halfL * 2 / 2))
        for k = 0, steps do
            local f = -1 + 2 * k / steps
            local px, pz = cx + dx * halfL * f, cz + dz * halfL * f
            local w = 0
            local o = halfW + 0.5
            while o <= halfW + ADFieldPark.PASS_SEARCH do
                local x, z = px + nx * o, pz + nz * o
                local crop = PathFinderModule.getMapCropAt(x, z)
                if (crop ~= nil and crop ~= 0) or not PathFinderModule.getMapOnFieldAt(x, z) then
                    break
                end
                w = o - halfW
                o = o + 0.5
            end
            width = math.min(width, w)
        end
        best = math.max(best, width)
    end
    return best
end

-- forage harvester: the footprint stands in its lane ahead, or too close to it
function ADFieldPark.isInHarvesterWay(harvester, cx, cz, halfW, halfL)
    if harvester == nil or harvester.components == nil then
        return false
    end
    local hx, _, hz = getWorldTranslation(harvester.components[1].node)
    local rx, _, rz = AutoDrive.localDirectionToWorld(harvester, 0, 0, 1)
    local dx, dz = cx - hx, cz - hz
    if math.sqrt(dx * dx + dz * dz) - halfL < ADFieldPark.HARVESTER_MIN_DISTANCE then
        return true
    end
    local ahead = dx * rx + dz * rz
    local side = math.abs(dx * rz - dz * rx)
    local width = (harvester.size ~= nil and harvester.size.width or 4) / 2 + halfW + ADFieldPark.LANE_MARGIN
    return ahead > -halfL and ahead < ADFieldPark.LANE_LENGTH + halfL and side < width
end

-- ------------------------------------------------------------------------------------------------------------
-- Places le long du bord, sur les anneaux autour de l'entrée
-- ------------------------------------------------------------------------------------------------------------
-- all the headings of the train centred on one point of a ring
function ADFieldPark.addCandidates(search, radius, angle)
    local halfW, halfL, py = search.halfW, search.halfL, search.py
    local a = math.rad(angle)
    local cx, cz = search.x + math.sin(a) * radius, search.z + math.cos(a) * radius
    if not ADFieldPark.isOnField(cx, py, cz) then
        return
    end
    -- always parallel to the border: the heading is the direction of the border itself, the train
    -- stands about 1 m away from it
    local bx, bz, tx, tz, nx, nz = ADFieldPark.findBorder(cx, cz, py)
    if bx == nil then
        ADFieldPark.count(search, "no border")
        return
    end
    if search.chopper then
        -- straight along the border over the whole train: heading from the border points at both ends
        local b1x, b1z = ADFieldPark.findBorder(cx - tx * halfL, cz - tz * halfL, py)
        local b2x, b2z = ADFieldPark.findBorder(cx + tx * halfL, cz + tz * halfL, py)
        if b1x ~= nil and b2x ~= nil then
            local cl = MathUtil.vector2Length(b2x - b1x, b2z - b1z)
            if cl > halfL then
                local ntx, ntz = (b2x - b1x) / cl, (b2z - b1z) / cl
                if ntx * tx + ntz * tz < 0 then
                    ntx, ntz = -ntx, -ntz
                end
                -- normal keeps its side (toward the border)
                local nnx, nnz = -ntz, ntx
                if nnx * nx + nnz * nz < 0 then
                    nnx, nnz = -nnx, -nnz
                end
                tx, tz, nx, nz = ntx, ntz, nnx, nnz
            end
        end
    end
    for _, sign in ipairs({1, -1}) do
        local dx, dz = tx * sign, tz * sign
        -- the centre line of the train on the border (half on the grass), a little into the field when
        -- something stands there
        for _, offset in ipairs(ADFieldPark.CENTRE_OFFSETS) do
            local px, pz = bx - nx * offset, bz - nz * offset
            local maxH = nil
            ADFieldPark.reject = "side or entrance"
            if ADFieldPark.isSpotAllowed(search, px, pz, dx, dz) then
                maxH = ADFieldPark.isGroundFree(px, pz, dx, dz, halfW, halfL, search.nearby, py)
                if maxH ~= nil and search.vehicle.ad.trafficYieldModule:overlapHit(px, maxH + 1.9, pz, math.atan2(dx, dz), halfW, 1.3, halfL) then
                    ADFieldPark.reject = "obstacle"
                    maxH = nil
                end
            end
            if maxH == nil then
                ADFieldPark.count(search, ADFieldPark.reject)
            else
                -- nose pointing away from the entrance: the train drives straight in along the border
                local ox, oz = px - search.x, pz - search.z
                local away = (dx * ox + dz * oz) / math.max(MathUtil.vector2Length(ox, oz), 0.1)
                -- the spot farthest from the entrance first, the next one queues behind it
                local cost = 3 * offset - 0.5 * radius - 3 * away
                table.insert(search.candidates, {cx = px, cz = pz, dx = dx, dz = dz, nx = nx, nz = nz, maxH = maxH, cost = cost})
                break
            end
        end
    end
end

-- diagnostic: why the places along the border were refused
function ADFieldPark.count(search, reason)
    search.stats = search.stats or {}
    search.stats[reason] = (search.stats[reason] or 0) + 1
end

-- ------------------------------------------------------------------------------------------------------------
-- Choix des places (sens de la fourrière, passes suivantes, obstacles)
-- ------------------------------------------------------------------------------------------------------------
-- best candidates first, obstacle test (vehicles, bales, trees...) only on them
function ADFieldPark.pickSpots(search)
    local candidates = search.candidates
    local parts = {}
    for reason, n in pairs(search.stats or {}) do
        table.insert(parts, string.format("%s %d", reason, n))
    end
    search.vehicle.ad.trafficYieldModule:log("field park: %d places, refused: %s (side %s, at x=%.0f z=%.0f)", #candidates,
        table.concat(parts, ", "), tostring(search.side), search.x, search.z)
    search.lastStats = search.stats or {}
    search.stats = {}
    -- 27/10 20:35 (7R, field 56: it must park, there is plenty of room): the places
    -- facing the wrong way do not count: the next passes run before giving up (the first pass had found one place
    -- facing the wrong way and the unloader went to wait beside the road while the harvested strip was wide)
    local sense = ADFieldPark.getHarvesterSense(search)
    local facing = #candidates
    if sense ~= nil then
        facing = 0
        for _, c in ipairs(candidates) do
            if c.nx == nil or ((c.nx * c.dz - c.nz * c.dx) > 0 and 1 or -1) == sense then
                facing = facing + 1
            end
        end
        if facing == 0 and #candidates > 0 and not search.wide then
            search.vehicle.ad.trafficYieldModule:log("field park: %d places but none faces the harvester's way, next pass", #candidates)
            search.candidates = {}
            candidates = search.candidates
        end
    end
    if #candidates == 0 and not search.relaxed and not search.memoFree then
        -- nothing away from the standing crop (the harvester is still on its headlands): look again without the
        -- harvester clearance, the unloader must not stay on the road
        search.relaxed = true
        search.queueDone = false
        search.radiusIndex = 1
        search.angle = 0
        search.vehicle.ad.trafficYieldModule:log("field park: no spot away from the crop, trying the harvested strip")
        return nil
    end
    if #candidates == 0 and search.relaxed and search.chopper and not search.narrow and not search.memoFree and (search.lastStats["no room to pass"] or 0) > 0 then
        -- 27/10 19:51 (as always intended): the forage harvester has only cut its first strip along the
        -- border, too narrow for another trailer to pass beside a parked one: the unloaders queue in that strip
        -- anyway (the called one at the front drives on to the harvester, the next moves up), rather than places
        -- on the far side reached through the crop or a wait at the entrance
        search.narrow = true
        search.queueDone = false
        search.radiusIndex = 1
        search.angle = 0
        search.vehicle.ad.trafficYieldModule:log("field park: only the narrow first strip is cut, queuing in it without room to pass")
        print(string.format("[AD-File] %s: seule la bande etroite le long du bord est coupee, file dans la bande", tostring(search.vehicle:getName())))
        return nil
    end
    if #candidates == 0 and search.relaxed and not search.wide and not search.memoFree then
        -- still nothing on the harvester's side within 85 m: both sides of the entrance, up to 145 m, 25 m from it
        search.wide = true
        search.wideSide = search.side
        search.side = nil
        search.queueDone = false
        search.radiusIndex = 1
        search.angle = 0
        local maxRadius = ADFieldPark.WIDE_RADII[#ADFieldPark.WIDE_RADII]
        search.nearby = ADFieldPark.getWayPointsAround(search.x, search.z, maxRadius + search.length + 10)
        search.vehicle.ad.trafficYieldModule:log("field park: nothing on side %s, looking on both sides up to %d m, %d m from the entrance", tostring(search.wideSide), maxRadius, ADFieldPark.WIDE_ENTRANCE_CLEARANCE)
        print(string.format("[AD-File] %s: aucune place du cote de l'ensileuse, je cherche des deux cotes jusqu'a %d m", tostring(search.vehicle:getName()), maxRadius))
        return nil
    end
    ADFieldPark.relaxed = false
    if #candidates == 0 then
        search.result = "no harvested ground along the border"
    end
    -- nose the way the harvester sets off along the border (its first headland)
    if sense ~= nil then
        local kept = {}
        for _, c in ipairs(candidates) do
            if c.nx == nil or ((c.nx * c.dz - c.nz * c.dx) > 0 and 1 or -1) == sense then
                table.insert(kept, c)
            end
        end
        search.vehicle.ad.trafficYieldModule:log("field park: harvester sense %d, %d of %d places face its way", sense, #kept, #candidates)
        if #kept == 0 and search.wide and #candidates > 0 then
            -- last pass: a place facing the other way is better than blocking the entrance
            search.vehicle.ad.trafficYieldModule:log("field park: none faces its way, the others are kept (last pass)")
            kept = candidates
        end
        candidates = kept
    else
        -- only the places in line with an unloader already parked: they face its way
        local kept = {}
        for _, c in ipairs(candidates) do
            if c.nx == nil then
                table.insert(kept, c)
            end
        end
        search.vehicle.ad.trafficYieldModule:log("field park: harvester direction not known yet, %d of %d places in line with a parked unloader", #kept, #candidates)
        candidates = kept
        if #kept == 0 then
            search.waitSense = true
        end
    end
    table.sort(candidates, function(c1, c2) return c1.cost < c2.cost end)
    local spots = {}
    for _, c in ipairs(candidates) do
        if not search.vehicle.ad.trafficYieldModule:overlapHit(c.cx, c.maxH + 1.9, c.cz, math.atan2(c.dx, c.dz), search.halfW, 1.3, search.halfL) then
            -- the footprint is centred on (cx, cz): the tractor stops ahead of the centre so that the whole train,
            -- trailers included, stands inside it
            local shift = search.length / 2 - search.front
            local tx, tz = c.cx + c.dx * shift, c.cz + c.dz * shift
            table.insert(spots, {
                x = tx, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, tx, search.py, tz), z = tz,
                dirX = c.dx, dirZ = c.dz,
                -- footprint, for the next unloader that queues behind this one
                cx = c.cx, cz = c.cz, halfL = search.halfL,
                queued = c.cost < -900 and c.memo == nil,
                ahead = c.ahead, aheadVehicle = c.aheadVehicle,
                harvester = search.harvester,
                -- the remembered place, or the sense this place was chosen for (remembered for the next unloaders)
                memo = c.memo or (c.ahead ~= nil and c.ahead.memo or nil), sense = sense
            })
            if #spots >= ADFieldPark.MAX_TRIES then
                break
            end
        end
    end
    return spots
end
