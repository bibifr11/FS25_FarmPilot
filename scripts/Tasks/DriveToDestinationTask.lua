DriveToDestinationTask = ADInheritsFrom(AbstractTask)

DriveToDestinationTask.STATE_PATHPLANNING = 1
DriveToDestinationTask.STATE_DRIVING = 2

function DriveToDestinationTask:new(vehicle, destinationID)
    local o = DriveToDestinationTask:create()
    o.vehicle = vehicle
    o.destinationID = destinationID
    o.trailers = nil
    return o
end

function DriveToDestinationTask:setUp()
    if self.vehicle.spec_locomotive and self.vehicle.ad and self.vehicle.ad.trainModule then
        self.state = DriveToDestinationTask.STATE_DRIVING
        self.vehicle.ad.trainModule:setPathTo(self.destinationID)
    elseif ADGraphManager:getDistanceFromNetwork(self.vehicle) > 30 then
        self.state = DriveToDestinationTask.STATE_PATHPLANNING
        self.vehicle.ad.pathFinderModule:reset()
        self.vehicle.ad.pathFinderModule:startPathPlanningToNetwork(self.destinationID)
    else
        self.state = DriveToDestinationTask.STATE_DRIVING
        self.vehicle.ad.drivePathModule:setPathTo(self.destinationID)
    end
    self.trailers, _ = AutoDrive.getAllUnits(self.vehicle)
    AutoDrive.setTrailerCoverOpen(self.vehicle, self.trailers, false)
end

function DriveToDestinationTask:update(dt)
    if self.state == DriveToDestinationTask.STATE_PATHPLANNING then
        if self.vehicle.ad.pathFinderModule:hasFinished() then
            self.wayPoints = self.vehicle.ad.pathFinderModule:getPath()
            if self.wayPoints == nil or #self.wayPoints == 0 then
                Logging.error("[AutoDrive] Could not calculate path - shutting down")
                self:finished(ADTaskModule.DONT_PROPAGATE)
                self.vehicle:stopAutoDrive()
                AutoDriveMessageEvent.sendMessageOrNotification(self.vehicle, ADMessagesManager.messageTypes.ERROR, "$l10n_AD_Driver_of; %s $l10n_AD_cannot_find_path;", 5000, self.vehicle.ad.stateModule:getName())
            else
                self.vehicle.ad.drivePathModule:setWayPoints(self.wayPoints)
                --self.vehicle.ad.drivePathModule:appendPathTo(self.wayPoints[#self.wayPoints], self.destinationID)
                -- partial route (guided departure, part of the way): its end is not the destination
                self.routeIsPartial = self.vehicle.ad.pathFinderModule.partialPath == true
                self.state = DriveToDestinationTask.STATE_DRIVING
            end
        else
            self.vehicle.ad.pathFinderModule:update(dt)
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
        end
    else
        if self.vehicle.ad.drivePathModule:isTargetReached() and self.routeIsPartial then
            -- end of a partial route, not the destination: plan the rest from here
            print(string.format("[AD-Fin] %s: bout du trajet partiel atteint, calcul de la suite", tostring(self.vehicle:getName())))
            self.routeIsPartial = false
            self:setUp()
        elseif self.vehicle.ad.drivePathModule:isTargetReached() then
            if self.roadClear == nil and self:startRoadClear() then
                return
            end
            self:finished()
        elseif type(self.roadClear) == "table" and g_time - self.roadClear.start > DriveToDestinationTask.ROAD_CLEAR_TIMEOUT then
            print(string.format("[AD-Fin] %s: pas arrive a degager le chemin en %d s, je m'arrete la", tostring(self.vehicle:getName()), DriveToDestinationTask.ROAD_CLEAR_TIMEOUT / 1000))
            self:finished()
        elseif self:isEntranceHold(dt) then
            return
        elseif self:isZoneBusyHold(dt) then
            return
        elseif self:isFieldFullStop(dt) then
            return
        else
            -- S8: the last link of the route, still known when the target is reached (the route is cleared then)
            local wayPoints = self.vehicle.ad.drivePathModule.wayPoints
            if self.roadClear == nil and wayPoints ~= nil and #wayPoints >= 2 then
                self.endWayPoints = wayPoints
                self.endPrevious, self.endLast = wayPoints[#wayPoints - 1], wayPoints[#wayPoints]
            end
            self.vehicle.ad.drivePathModule:update(dt)
        end
    end
end

DriveToDestinationTask.ROAD_CLEAR = 3.5          -- m between the road line and the nearest rear corner of the train
DriveToDestinationTask.ROAD_CLEAR_MAX = 15       -- m driven on at most
DriveToDestinationTask.ROAD_CLEAR_SHOULDER = 4   -- m at most when the ground ahead is not a field (roadside)
DriveToDestinationTask.ROAD_CLEAR_SLOPE = 0.5    -- m of height change per metre refused (ditch, bank)
DriveToDestinationTask.ROAD_CLEAR_STEP = 2       -- m between the added points
DriveToDestinationTask.ROAD_CLEAR_TIMEOUT = 25000 -- ms, then it stops where it is

-- S8 (owner 28/10 17:43, Patriot 4450 at "Champ 40", go 17:01): the destination point is 6 m off the gravel road, the
-- vehicle stopped there with its body still on the road and the 8510 got wedged beside it. In "drive to", a vehicle
-- whose train still stands on the road at its destination drives on straight ahead into the field (or a few metres
-- onto the roadside) until its rear is ROAD_CLEAR m from the road. Once per drive, never when reversing
function DriveToDestinationTask:startRoadClear()
    self.roadClear = false
    local vehicle = self.vehicle
    if vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_DRIVETO or vehicle.spec_locomotive ~= nil or self.routeIsPartial
        or ADTrafficYieldModule == nil or self.endLast == nil or self.endPrevious == nil or self.endLast.id == nil then
        return false
    end
    local last, previous = self.endLast, self.endPrevious
    local dest = ADGraphManager:getWayPointById(last.id)
    if dest == nil then
        return false
    end
    -- the road around the destination: the links of its neighbours, the destination itself left out
    local segments, seen, neighbours = {}, {}, {}
    for _, list in ipairs({dest.out or {}, dest.incoming or {}}) do
        for _, id in ipairs(list) do
            neighbours[id] = true
        end
    end
    for id, _ in pairs(neighbours) do
        local node = ADGraphManager:getWayPointById(id)
        if node ~= nil then
            for _, list in ipairs({node.out or {}, node.incoming or {}}) do
                for _, otherId in ipairs(list) do
                    local key = math.min(id, otherId) .. "-" .. math.max(id, otherId)
                    local other = otherId ~= dest.id and ADGraphManager:getWayPointById(otherId) or nil
                    if other ~= nil and not seen[key] then
                        seen[key] = true
                        table.insert(segments, {node, other})
                    end
                end
            end
        end
    end
    if #segments == 0 then
        return false
    end
    local function roadDistance(x, z)
        local best = math.huge
        for _, segment in ipairs(segments) do
            local a, b = segment[1], segment[2]
            local dx, dz = b.x - a.x, b.z - a.z
            local l2 = dx * dx + dz * dz
            local t = l2 > 0.0001 and math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / l2)) or 0
            best = math.min(best, MathUtil.vector2Length(x - (a.x + dx * t), z - (a.z + dz * t)))
        end
        return best
    end
    -- the last link leads away from the road (the destination is not a point on the road itself), driven forwards
    local dx, dz = last.x - previous.x, last.z - previous.z
    local length = MathUtil.vector2Length(dx, dz)
    if length < 0.5 then
        return false
    end
    dx, dz = dx / length, dz / length
    if roadDistance(last.x + dx * 5, last.z + dz * 5) < roadDistance(last.x, last.z) + 2 then
        return false
    end
    local fx, fz = ADTrafficYieldModule.getDirection(vehicle)
    if fx * dx + fz * dz < 0.7 then
        return false
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local front, rear = ADTrafficYieldModule.getTrainExtents(vehicle)
    local half = ADTrafficYieldModule.getWidth(vehicle) / 2
    -- length of the train behind the vehicle origin along its path: the tractor rear, plus every unit behind it
    local _, tractorLength = ADTrafficYieldModule.getUnitDimensions(vehicle)
    local dims = vehicle.ad.adDimensions
    local behind = (dims ~= nil and dims.maxLengthBack ~= nil and dims.maxLengthBack > 0.1) and dims.maxLengthBack or tractorLength / 2
    local units = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit ~= vehicle and unit.components ~= nil and unit.components[1] ~= nil then
                local ux, uy, uz = getWorldTranslation(unit.components[1].node)
                local _, _, localZ = AutoDrive.worldToLocal(vehicle, ux, uy, uz)
                if localZ < 0 then
                    local _, unitLength = ADTrafficYieldModule.getUnitDimensions(unit)
                    behind = behind + unitLength
                end
            end
        end
    end
    behind = math.max(behind, rear)
    -- the path the train stands on: from the vehicle origin back along the route it drove (the trailers follow it)
    local path = {{x = x, z = z}}
    local wayPoints = self.endWayPoints or {previous}
    local walked = 0
    for i = #wayPoints - 1, 1, -1 do
        local wp = wayPoints[i]
        if wp ~= nil and (wp.x - x) * fx + (wp.z - z) * fz < 0 then
            local p = path[#path]
            walked = walked + MathUtil.vector2Length(wp.x - p.x, wp.z - p.z)
            table.insert(path, {x = wp.x, z = wp.z})
            if walked > behind + 1 then
                break
            end
        end
    end
    if walked < behind then
        -- route too short: straight on behind the last known point
        local p, q = path[#path], path[#path - 1] or {x = x + fx, z = z + fz}
        local bx, bz = p.x - q.x, p.z - q.z
        local bl = MathUtil.vector2Length(bx, bz)
        if bl < 0.01 then
            bx, bz, bl = -fx, -fz, 1
        end
        table.insert(path, {x = p.x + bx / bl * (behind - walked + 1), z = p.z + bz / bl * (behind - walked + 1)})
    end
    -- point of the train <a> metres behind the origin once the vehicle drove <s> metres on along the last link
    local function pointAt(a, s)
        if a <= s then
            return x + dx * (s - a), z + dz * (s - a), dx, dz
        end
        local remaining = a - s
        for k = 1, #path - 1 do
            local p, q = path[k], path[k + 1]
            local l = MathUtil.vector2Length(q.x - p.x, q.z - p.z)
            if l > 0.01 and (remaining <= l or k == #path - 1) then
                local t = remaining / l
                return p.x + (q.x - p.x) * t, p.z + (q.z - p.z) * t, (p.x - q.x) / l, (p.z - q.z) / l
            end
            remaining = remaining - l
        end
        return path[#path].x, path[#path].z, fx, fz
    end
    local function clearance(s)
        local best = math.huge
        local a = 0
        while true do
            local px, pz, ux, uz = pointAt(a, s)
            best = math.min(best, roadDistance(px, pz), roadDistance(px + uz * half, pz - ux * half), roadDistance(px - uz * half, pz + ux * half))
            if a >= behind then
                break
            end
            a = math.min(behind, a + 1)
        end
        return best
    end
    local now = clearance(0)
    if now >= DriveToDestinationTask.ROAD_CLEAR then
        return false
    end
    local needed = DriveToDestinationTask.ROAD_CLEAR_MAX
    for s = 1, DriveToDestinationTask.ROAD_CLEAR_MAX do
        if clearance(s) >= DriveToDestinationTask.ROAD_CLEAR then
            needed = math.min(s + 1, DriveToDestinationTask.ROAD_CLEAR_MAX)
            break
        end
    end
    -- the ground in front of the train: a field all the way, or a few metres of roadside without a ditch or a bank
    local nx, nz = x + fx * front, z + fz * front
    local lastHeight = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, nx, 300, nz)
    local allowed, where = 0, "dans le champ"
    for s = 1, needed do
        local px, pz = nx + dx * s, nz + dz * s
        local height = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, px, 300, pz)
        if math.abs(height - lastHeight) > DriveToDestinationTask.ROAD_CLEAR_SLOPE then
            break
        end
        lastHeight = height
        if not AutoDrive.checkIsOnField(px, height, pz) then
            if s > DriveToDestinationTask.ROAD_CLEAR_SHOULDER then
                break
            end
            where = "sur le bord"
        end
        allowed = s
    end
    local name = tostring(vehicle:getName())
    if allowed < 1 then
        print(string.format("[AD-Fin] %s: arrive, l'arriere est a %.1f m du chemin, mais pas de place devant (ni champ ni bord plat)", name, now))
        return false
    end
    -- points along the last link; the route ends when the steering node is within min_distance of the last one
    local sx, sz = x, z
    if vehicle.getAISteeringNode ~= nil then
        sx, _, sz = getWorldTranslation(vehicle:getAISteeringNode())
    end
    local startAlong = (sx - last.x) * dx + (sz - last.z) * dz
    local endAlong = startAlong + allowed + (vehicle.ad.drivePathModule.min_distance or 1)
    local y = last.y or getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, last.x, 300, last.z)
    local points = {{x = sx, y = y, z = sz}}
    local along = startAlong + DriveToDestinationTask.ROAD_CLEAR_STEP
    while along < endAlong do
        table.insert(points, {x = last.x + dx * along, y = y, z = last.z + dz * along})
        along = along + DriveToDestinationTask.ROAD_CLEAR_STEP
    end
    table.insert(points, {x = last.x + dx * endAlong, y = y, z = last.z + dz * endAlong})
    local destination = vehicle.ad.stateModule:getCurrentDestination()
    vehicle.ad.drivePathModule:setWayPoints(points)
    vehicle.ad.stateModule:setCurrentDestination(destination)
    self.roadClear = {start = g_time}
    print(string.format("[AD-Fin] %s: arrive avec l'arriere a %.1f m du chemin, je degage le chemin de %d m (%s)", name, now, allowed, where))
    return true
end

DriveToDestinationTask.FIELD_FULL_STOP_DISTANCE = 60 -- m before the field point: the field being full, it stops on the road here
DriveToDestinationTask.FIELD_FULL_STOP_MIN = 25     -- m: closer than this it goes on to the field point as before
DriveToDestinationTask.FIELD_FULL_CHECK = 1000      -- ms between two looks

-- owner 25/10: empty unloader back to a field that already holds its unloaders (ADFieldPark.FIELD_CAPACITY): it does not
-- drive up to the entrance (where it blocks it, nose in the field, with no clean way to the roadside), it stops on the
-- road before the entrance and WaitForCallTask parks it beside the road from there
function DriveToDestinationTask:isFieldFullStop(dt)
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or ADFieldPark == nil or not ADFieldPark.isEnabled() or self.vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_UNLOAD
        or mode.state ~= mode.STATE_DRIVE_TO_START or self.routeIsPartial then
        return false
    end
    self.fieldFullCheck = (self.fieldFullCheck or 0) + dt
    if self.fieldFullCheck < DriveToDestinationTask.FIELD_FULL_CHECK then
        return false
    end
    self.fieldFullCheck = 0
    local marker = self.vehicle.ad.stateModule:getFirstMarker()
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp == nil then
        return false
    end
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local distance = MathUtil.vector2Length(wp.x - x, wp.z - z)
    if distance > DriveToDestinationTask.FIELD_FULL_STOP_DISTANCE or distance < DriveToDestinationTask.FIELD_FULL_STOP_MIN
        or AutoDrive.checkIsOnField(x, y, z) then
        return false
    end
    local harvester = ADFieldPark.findHarvester(self.vehicle, wp.x, wp.z)
    if harvester == nil or ADFieldPark.countInField(self.vehicle, harvester) < ADFieldPark.FIELD_CAPACITY then
        return false
    end
    print(string.format("[AD-File] %s: champ complet (%d bennes), je m'arrete sur la route a %.0f m avant l'entree", tostring(self.vehicle:getName()), ADFieldPark.FIELD_CAPACITY, distance))
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    self:finished()
    return true
end

-- owner 25/10: empty unloader back to the field, a full one drives out by the same entrance: it stops on the road
-- before the entrance until the full one is out
function DriveToDestinationTask:isEntranceHold(dt)
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or ADFieldPark == nil or self.vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_UNLOAD
        or mode.state ~= mode.STATE_DRIVE_TO_START then
        return false
    end
    return ADFieldPark.holdForExit(self.vehicle, dt, "sur la route")
end

DriveToDestinationTask.ZONE_RADIUS = 35          -- m around the field point: the entrance zone
DriveToDestinationTask.ZONE_HOLD_MAX = 60        -- m before the field point: the unloader holds on the road from here
DriveToDestinationTask.ZONE_HOLD_TIMEOUT = 180000 -- ms, then it drives on as before

-- owner 27/10 18:12 ("si le tracteur est en dehors, les autres doivent attendre avant d'arriver sur zone"): at the start
-- of a job the first unloader is still on the grass beside the harvester, outside the field, and the next ones drove
-- up to the entrance and queued nose to tail behind its trailer (MF 7S and 942 behind the 7R). An unloader coming to
-- the field point holds on the road before the entrance while another unloader of this harvester is in the entrance
-- zone and not on the field (the called one not yet in place, or one still waiting at the entrance)
function DriveToDestinationTask:isZoneBusyHold(dt)
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or ADFieldPark == nil or not ADFieldPark.isEnabled() or self.vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_UNLOAD
        or mode.state ~= mode.STATE_DRIVE_TO_START or self.routeIsPartial then
        return false
    end
    local hold = self.vehicle.ad.zoneHold
    self.zoneCheck = (self.zoneCheck or 0) + dt
    if self.zoneCheck < DriveToDestinationTask.FIELD_FULL_CHECK then
        if hold ~= nil then
            hold.waited = hold.waited + dt
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
            return true
        end
        return false
    end
    self.zoneCheck = 0
    local marker = self.vehicle.ad.stateModule:getFirstMarker()
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp == nil then
        return false
    end
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local distance = MathUtil.vector2Length(wp.x - x, wp.z - z)
    local busy = nil
    if distance <= DriveToDestinationTask.ZONE_HOLD_MAX and distance >= DriveToDestinationTask.FIELD_FULL_STOP_MIN
        and not AutoDrive.checkIsOnField(x, y, z) then
        local harvester = ADFieldPark.findHarvester(self.vehicle, wp.x, wp.z)
        if harvester ~= nil and ADHarvestManager ~= nil and ADHarvestManager.getUnloadersOf ~= nil then
            for _, other in pairs(ADHarvestManager:getUnloadersOf(harvester)) do
                if other ~= self.vehicle and other.components ~= nil and other.isDeleted ~= true then
                    local ox, oy, oz = getWorldTranslation(other.components[1].node)
                    local od = MathUtil.vector2Length(wp.x - ox, wp.z - oz)
                    local spot = ADFieldPark.parked ~= nil and ADFieldPark.parked[other] or nil
                    -- in the entrance zone, not on the field, and not parked in a field spot: still in the way
                    if od < DriveToDestinationTask.ZONE_RADIUS and not AutoDrive.checkIsOnField(ox, oy, oz)
                        and (spot == nil or spot.roadside) then
                        busy = other
                        break
                    end
                end
            end
        end
    end
    if busy == nil then
        if hold ~= nil then
            print(string.format("[AD-Entree] %s: %s n'est plus dans la zone d'entree, j'y vais (attendu %d s)", tostring(self.vehicle:getName()), tostring(hold.name), math.floor(hold.waited / 1000)))
            self.vehicle.ad.zoneHold = nil
        end
        return false
    end
    if hold == nil or hold.other ~= busy then
        hold = {other = busy, name = busy:getName(), waited = hold ~= nil and hold.waited or 0}
        self.vehicle.ad.zoneHold = hold
        print(string.format("[AD-Entree] %s: %s est dans la zone d'entree sans etre dans le champ, j'attends sur la route a %.0f m du point du champ", tostring(self.vehicle:getName()), tostring(hold.name), distance))
    end
    hold.waited = hold.waited + dt
    if hold.waited > DriveToDestinationTask.ZONE_HOLD_TIMEOUT then
        if not hold.gaveUp then
            hold.gaveUp = true
            print(string.format("[AD-Entree] %s: %s toujours dans la zone apres %d s, je n'attends plus", tostring(self.vehicle:getName()), tostring(hold.name), DriveToDestinationTask.ZONE_HOLD_TIMEOUT / 1000))
        end
        return false
    end
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    return true
end

function DriveToDestinationTask:abort()
    self.vehicle.ad.zoneHold = nil
end

function DriveToDestinationTask:finished(propagate)
    self.vehicle.ad.zoneHold = nil
    self.vehicle.ad.taskModule:setCurrentTaskFinished(propagate)
end

function DriveToDestinationTask:getI18nInfo()
    if self.state == DriveToDestinationTask.STATE_PATHPLANNING then
        return self:getPlanningI18n()
    else
        return "$l10n_AD_task_drive_to_destination;"
    end
end
