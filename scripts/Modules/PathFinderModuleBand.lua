-- ============================================================================================================
-- FarmPilot : PathFinderModuleBand.lua
-- Complément de PathFinderModule : les bandes coupées (ensileuse, strict).
-- - Flot des bandes (ADBandRoute, BandRouteModule.lua) : vraies distances de conduite dans les bandes coupées vers la
--   cible, demandé au départ du trajet, attendu au plus BAND_FLOOD_WAIT ms ; il guide l'estimation de l'A* et
--   refuse le sol de champ que les bandes n'atteignent pas (passage de roues, poche).
-- - Trajet tracé dans la bande : quand la grille ne trouve rien, le trajet est relevé dans le flot, du tracteur à la
--   cible, éclairci, chaque morceau contrôlé pour les obstacles (le flot ne connaît que la culture et le champ).
-- - Tour du champ par la bande (ADBandTour, BandTourModule.lua) : sans trajet, le tour du champ par les bandes, en
--   marche avant seulement, jusqu'au point derrière l'ensileuse dans son sens ; une fois par endroit.
--
-- Historique :
-- - 23/10 : le tour du champ par les bandes coupées, en marche avant ;
-- - 25/10 16:30, le 7R ne trouvait aucun chemin : la grille (cases de 9-10 m) ne passe pas dans une bande coupée ;
-- - 27/10 20:46 (MF 7S.210 : « obstacle sur la bande à -195,-572 » 9 fois, au coin du champ) : un morceau droit qui
--   coupe le coin de la bande est recontrôlé point par point le long de la bande, refusé seulement si elle touche.
--
-- Règle : seulement pour l'ensileuse en strict, les autres trajets ne changent pas.
--
-- Branché par PathFinderModule.lua : startPathPlanningTo (requestBandFlood), update (updateBandSearch,
-- abortOrTour), estimate_cost (estimateBandCost), isDriveableAstar (isOutOfBand) ; getBandPath par
-- DriveToVehicleTask.lua et ExitFieldTask.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.BAND_FLOOD_WAIT = 10000 -- ms the search waits for the flood of the cut strips (ADBandRoute)
PathFinderModule.BAND_UNREACHED_PENALTY = 1000 -- estimate added for a place out of the strips that reach the target
PathFinderModule.BAND_START_LOOKUP = 8 -- m around the start to find the strips (it may stand at the crop edge)

-- ------------------------------------------------------------------------------------------------------------
-- Flot des bandes : demande et attente
-- ------------------------------------------------------------------------------------------------------------
-- accroche de startPathPlanningTo
function PathFinderModule:requestBandFlood(targetX, targetZ)
    -- forage harvester work, strict: real driving distances inside the cut strips toward the target (ADBandRoute)
    self.bandFlood = nil
    self.bandFloodStartDistance = nil
    if (self.strictFruit or self.strictField) and self:isChopperWork() and ADBandRoute ~= nil then
        self.bandFlood = ADBandRoute.request(targetX, targetZ, self:getCropHalfWidth())
        self.bandFloodWaitUntil = (g_time or 0) + PathFinderModule.BAND_FLOOD_WAIT
        self.bandFloodLogged = false
    end
end

-- accroche de PathFinderModule:update (après delayTime) ; true = update s'arrête là pour cette image
function PathFinderModule:updateBandSearch()
    if self.bandFlood ~= nil and not self.isFinished then
        local done = ADBandRoute.step(self.bandFlood, ADBandRoute.BUDGET)
        if not done and (g_time or 0) < self.bandFloodWaitUntil then
            return true
        end
        if not self.bandFloodLogged then
            self.bandFloodLogged = true
            self:logBandFlood()
        end
    end
    if self.bandTour ~= nil then
        self:updateBandTour()
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Distances par les bandes (A*)
-- ------------------------------------------------------------------------------------------------------------
-- accroche de estimate_cost : nil = pas de flot des bandes, estimation d'origine
function PathFinderModule:estimateBandCost(node, goal_node)
    local band = self:getBandDistanceAtNode(node)
    if band then
        return band * 1.5 + (node.cost + goal_node.cost) * 0.5
    elseif band == false then
        -- strips known but this place cannot reach the target through them
        return self:get_cost(node, goal_node) * 1.5 + PathFinderModule.BAND_UNREACHED_PENALTY + (node.cost + goal_node.cost) * 0.5
    end
    return nil
end

-- real driving distance from a grid node to the target through the cut strips: number, false when the strips
-- are known but the node is not in them, nil when there is no flood (any other trip)
function PathFinderModule:getBandDistanceAtNode(node)
    if not self:isBandFloodReady() then
        return nil
    end
    local p = self:gridLocationToWorldLocation(node)
    return ADBandRoute.getDistance(self.bandFlood, p.x, p.z) or false
end

function PathFinderModule:isBandFloodReady()
    return self.bandFlood ~= nil and self.bandFlood.done and not self.bandFlood.failed and self.bandFloodStartDistance ~= nil
end

-- distance gained toward the target: real distance in the strips when both ends are in them
function PathFinderModule:getBandGain(fromX, fromZ, toX, toZ)
    if not self:isBandFloodReady() then
        return nil
    end
    local a = ADBandRoute.getDistance(self.bandFlood, fromX, fromZ, PathFinderModule.BAND_START_LOOKUP)
    if a == nil then
        return nil
    end
    local b = ADBandRoute.getDistance(self.bandFlood, toX, toZ)
    if b == nil then
        -- from the strips to a place they do not reach: a dead end, never a gain
        return -math.huge
    end
    return a - b
end

-- field ground the strips do not reach (a wheel lane through the crop, a pocket): no way for the train.
-- Not judged near the start (the train stands where it stands) and near the target
function PathFinderModule:isOutOfBand(x, z)
    -- only when the strips link the start to the target: else the search keeps its usual checks
    if not self:isBandFloodReady() or not self.bandFloodStartDistance then
        return false
    end
    if MathUtil.vector2Length(x - self.startX, z - self.startZ) < PathFinderModule.VERIFY_SKIP_START
        or MathUtil.vector2Length(x - self.target.x, z - self.target.z) < PathFinderModule.VERIFY_SKIP_END then
        return false
    end
    return ADBandRoute.getDistance(self.bandFlood, x, z, math.max(1, self.minTurnRadius / 2)) == nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Trajet tracé dans la bande
-- ------------------------------------------------------------------------------------------------------------
-- 25/10 16:30 (the 7R found no route): the grid (cells of the turning radius, 9-10 m) finds no way through
-- a cut strip. The flood of the cut strips (ADBandRoute, 1 m points, whole train width) knows the real way: traced back
-- from the tractor to the target, thinned, each piece checked for obstacles (the flood only knows crop and field).
-- Returns the waypoints (isPathFinderPoint) or nil, reason
PathFinderModule.BAND_PATH_THIN = 3          -- m between kept points on a straight stretch
PathFinderModule.BAND_PATH_CORNER = 12       -- deg: a heading change above this keeps the point
PathFinderModule.BAND_PATH_START_AHEAD = 1.5 -- m: the first point is ahead of the tractor at least
PathFinderModule.BAND_PATH_MAX_HEADING = 100 -- deg between the tractor heading and the first piece
PathFinderModule.BAND_PATH_END_TOLERANCE = 6 -- m between the end of the trace and the target at most
-- fixed objects only (vehicles are left to the chase), the first one hit is named for the log
local function bandCollisionCallback(probe, transformId)
    if transformId ~= 0 and transformId ~= g_currentMission.terrainRootNode then
        local object = g_currentMission:getNodeObject(transformId)
        if object == nil or object.rootVehicle == nil then
            probe.hits = probe.hits + 1
            if probe.name == nil then
                local ok, n = FarmPilotCall(function()
                    if object ~= nil and object.getName ~= nil then
                        return object:getName()
                    end
                    return getName ~= nil and getName(transformId) or nil
                end)
                probe.name = (ok and n ~= nil) and tostring(n) or tostring(transformId)
            end
        end
    end
    return true
end

-- obstacle box over one straight piece a -> b of the band route: hits, name of the first object
function PathFinderModule:bandPieceHits(a, b, height, halfWidth)
    local dx, dz = b.x - a.x, b.z - a.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len <= 0.1 then
        return 0, nil
    end
    local angleRad = AutoDrive.normalizeAngle(math.atan2(-dz / len, dx / len))
    local midX, midZ = (a.x + b.x) / 2, (a.z + b.z) / 2
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, midX, 1, midZ)
    local probe = {hits = 0, callback = bandCollisionCallback}
    overlapBox(midX, y + height / 2, midZ, 0, angleRad, 0, len / 2, height / 2, halfWidth, "callback", probe, AutoDrive.collisionMaskTerrain, true, true, true, true)
    return probe.hits, probe.name
end

function PathFinderModule:getBandPath()
    local flood = self.bandFlood
    if flood == nil then
        return nil, "pas de bande"
    end
    if not flood.done then
        return nil, "bande pas finie"
    end
    if flood.failed then
        return nil, "aucun point libre pres de la cible"
    end
    local vx, vy, vz, hx, hz = self:getStartPose()
    local raw = ADBandRoute.tracePath(flood, vx, vz, PathFinderModule.BAND_START_LOOKUP)
    if raw == nil or #raw < 2 then
        return nil, "le depart n'est relie a la cible par aucune bande"
    end
    local tail = raw[#raw]
    if MathUtil.vector2Length(tail.x - flood.x, tail.z - flood.z) > ADBandRoute.TARGET_SNAP + PathFinderModule.BAND_PATH_END_TOLERANCE then
        return nil, string.format("bande interrompue a %.0f m de la cible", MathUtil.vector2Length(tail.x - flood.x, tail.z - flood.z))
    end
    -- the trace starts at the reached point closest to the tractor, maybe beside or behind it: first point ahead
    local first = nil
    for i = 1, math.min(#raw, 20) do
        local dx, dz = raw[i].x - vx, raw[i].z - vz
        if dx * hx + dz * hz >= PathFinderModule.BAND_PATH_START_AHEAD then
            first = i
            break
        end
    end
    if first == nil or first >= #raw then
        return nil, "la bande part derriere le tracteur"
    end
    local look = raw[math.min(#raw, first + 3)]
    local angle = math.abs(AutoDrive.angleBetween({x = hx, z = hz}, {x = look.x - vx, z = look.z - vz}))
    if angle > PathFinderModule.BAND_PATH_MAX_HEADING then
        return nil, string.format("la bande part a %.0f deg de mon cap", angle)
    end
    -- thinning: a point every BAND_PATH_THIN m, every corner, the last one
    local kept = {{x = vx, z = vz}}
    local lastKept = kept[1]
    local lastDir = nil
    for i = first, #raw do
        local p = raw[i]
        local dx, dz = p.x - lastKept.x, p.z - lastKept.z
        local d = math.sqrt(dx * dx + dz * dz)
        local corner = false
        if lastDir ~= nil and i < #raw then
            local q = raw[i + 1]
            corner = math.abs(AutoDrive.angleBetween(lastDir, {x = q.x - p.x, z = q.z - p.z})) > PathFinderModule.BAND_PATH_CORNER
        end
        if (i == #raw or corner or d >= PathFinderModule.BAND_PATH_THIN) and d > 0.5 then
            kept[#kept + 1] = {x = p.x, z = p.z, raw = i}
            lastDir = {x = dx / d, z = dz / d}
            lastKept = kept[#kept]
        end
    end
    if #kept < 2 then
        return nil, "bande trop courte"
    end
    -- obstacles along each piece (walls, trees, learned blocked zones): the flood only knows crop and field.
    -- 27/10 20:46 (MF 7S.210: "obstacle sur la bande a -195,-572" 9 times, the corner of the field where the
    -- 942 had just driven): a straight piece between two kept points cuts the corner of the band and touches what
    -- stands beside it; such a piece is checked again point by point along the band itself, and only refused when
    -- the band really touches, the object named
    local halfWidth = self:getTrainWidth() / 2 + FollowCombineTask.LINE_WIDTH_MARGIN
    local height = PathFinderModule.getTrainHeight(self.vehicle) + PathFinderModule.OBSTACLE_HEIGHT_MARGIN
    local out = {kept[1]}
    local rechecked = 0
    for i = 2, #kept do
        local a, b = kept[i - 1], kept[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local len = math.sqrt(dx * dx + dz * dz)
        if len > 0.1 then
            local angleRad = AutoDrive.normalizeAngle(math.atan2(-dz / len, dx / len))
            local midX, midZ = (a.x + b.x) / 2, (a.z + b.z) / 2
            local hits, hitName = self:bandPieceHits(a, b, height, halfWidth)
            if hits > 0 then
                if a.raw == nil or b.raw == nil or b.raw <= a.raw + 1 then
                    return nil, string.format("obstacle sur la bande a %.0f,%.0f (%s)", midX, midZ, tostring(hitName))
                end
                for j = a.raw + 1, b.raw do
                    local fineHits, fineName = self:bandPieceHits(raw[j - 1], raw[j], height, halfWidth)
                    if fineHits > 0 then
                        return nil, string.format("obstacle sur la bande a %.0f,%.0f (%s, confirme point par point en %.0f,%.0f)", midX, midZ, tostring(hitName), raw[j].x, raw[j].z)
                    end
                end
                rechecked = rechecked + 1
                print(string.format("[AD-Bande] %s: coin de la bande en %.0f,%.0f : la corde touche %s, le trace point par point passe (%d points gardes)", self:getLogName(), midX, midZ, tostring(hitName), b.raw - a.raw))
                for j = a.raw + 1, b.raw - 1 do
                    out[#out + 1] = {x = raw[j].x, z = raw[j].z, raw = j}
                end
            end
            if self:boxHitsBlockedZone(midX, midZ, angleRad, len / 2, halfWidth) then
                return nil, string.format("zone interdite sur la bande a %.0f,%.0f", midX, midZ)
            end
        end
        out[#out + 1] = b
    end
    local path = {}
    for i, p in ipairs(out) do
        path[i] = {x = p.x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p.x, 1, p.z), z = p.z, isPathFinderPoint = true}
    end
    print(string.format("[AD-Bande] %s: trajet trace dans la bande : %d points (%d bruts), %.0f m", self:getLogName(), #path, #raw - first + 1, ADBandRoute.getDistance(flood, vx, vz, PathFinderModule.BAND_START_LOOKUP) or 0))
    return path
end

function PathFinderModule:logBandFlood()
    local flood = self.bandFlood
    local straight = MathUtil.vector2Length(self.startX - self.target.x, self.startZ - self.target.z)
    if not flood.done then
        print(string.format("[AD-Bande] %s: trajet dans la bande vers %.0f,%.0f pas fini a temps (%d points), recherche sans lui", self:getLogName(), self.target.x, self.target.z, flood.reached))
        return
    end
    if flood.failed then
        print(string.format("[AD-Bande] %s: trajet dans la bande vers %.0f,%.0f : aucun point libre a %d m de la cible", self:getLogName(), self.target.x, self.target.z, ADBandRoute.TARGET_SNAP))
        return
    end
    -- the start stands at the crop edge: a wider look around it
    local d = ADBandRoute.getDistance(flood, self.startX, self.startZ, PathFinderModule.BAND_START_LOOKUP)
    self.bandFloodStartDistance = d
    if d == nil then
        print(string.format("[AD-Bande] %s: trajet dans la bande vers %.0f,%.0f : %d points libres, le depart %.0f,%.0f n'est relie a la cible par aucune bande assez large (%.1f s)", self:getLogName(), self.target.x, self.target.z, flood.reached, self.startX, self.startZ, flood.seconds or 0))
        self.bandFloodStartDistance = false
        return
    end
    print(string.format("[AD-Bande] %s: trajet dans la bande vers %.0f,%.0f : %.0f m par la bande (vol d'oiseau %.0f m), %d points libres, %.1f s", self:getLogName(), self.target.x, self.target.z, d, straight, flood.reached, flood.seconds or 0))
end

-- ------------------------------------------------------------------------------------------------------------
-- Tour du champ par la bande
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester, strict, no route (23/10): the tour of the field through the cut strips, forward only, to
-- the point behind the harvester in its direction (ADBandTour). Once per place (TOUR_RETRY_PLACE m, TOUR_RETRY_TIME ms)
PathFinderModule.TOUR_RETRY_TIME = 120000
PathFinderModule.TOUR_RETRY_PLACE = 15
PathFinderModule.TOUR_POINT_SPACING = 2

function PathFinderModule:startBandTour()
    if self.bandTour ~= nil or self.startPose ~= nil or ADBandTour == nil or not self:isChopperWork() or not (self.strictFruit or self.strictField)
        or not self.goingToPipe or self.target == nil or self.targetVector == nil then
        return false
    end
    local x, _, z, hx, hz = self:getStartPose()
    local now = g_time or 0
    if self.tourFailX ~= nil and now - (self.tourFailTime or 0) < PathFinderModule.TOUR_RETRY_TIME
        and MathUtil.vector2Length(x - self.tourFailX, z - self.tourFailZ) < PathFinderModule.TOUR_RETRY_PLACE then
        return false
    end
    local tl = MathUtil.vector2Length(self.targetVector.x, self.targetVector.z)
    if tl < 0.01 then
        return false
    end
    local th = math.atan2(self.targetVector.x / tl, self.targetVector.z / tl)
    local flood = self:isBandFloodReady() and self.bandFlood or nil
    self.bandTour = ADBandTour.start(x, z, math.atan2(hx, hz), self.target.x, self.target.z, th, self.realTurnRadius or self.minTurnRadius, self:getCropHalfWidth(), flood)
    print(string.format("[AD-Tour] %s: pas de trajet, recherche du tour par la bande (marche avant seulement, rayon %.1f m) vers %.0f,%.0f", self:getLogName(), self.realTurnRadius or self.minTurnRadius, self.target.x, self.target.z))
    return true
end

-- no route: the tour first, else the usual end (the calling task waits and plans again)
function PathFinderModule:abortOrTour()
    if self:startBandTour() then
        self.isFinished = false
        self.smoothDone = false
        self.dubinsDone = false
        return true
    end
    self:abort()
    return false
end

function PathFinderModule:updateBandTour()
    local tour = self.bandTour
    if not ADBandTour.step(tour, ADBandTour.BUDGET) then
        return
    end
    self.bandTour = nil
    local x, _, z = self:getStartPose()
    if tour.found then
        local points = {}
        for i, p in ipairs(tour.path) do
            if i == 1 or i == #tour.path or (i - 1) % PathFinderModule.TOUR_POINT_SPACING == 0 then
                points[#points + 1] = {x = p.x, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p.x, 1, p.z), z = p.z}
            end
        end
        local blocked = nil
        for i = 2, #points do
            if not self:isStretchClear(points[i - 1], points[i], nil, true, true) then
                blocked = points[i]
                break
            end
        end
        if blocked == nil then
            self.wayPoints = points
            self.partialPath = false
            self.completelyBlocked = false
            self.isFinished = true
            self.smoothDone = true
            self.dubinsDone = true
            ADScheduler:removePathfinderVehicle(self.vehicle)
            print(string.format("[AD-Tour] %s: tour trouve, %.0f m par la bande jusque derriere l'ensileuse (%d poses, %.1f s)", self:getLogName(), tour.length or 0, tour.expansions, tour.seconds or 0))
            return
        end
        print(string.format("[AD-Tour] %s: tour trouve mais obstacle vers %.0f,%.0f, attente", self:getLogName(), blocked.x, blocked.z))
    else
        print(string.format("[AD-Tour] %s: aucun tour possible en marche avant (%d poses, %.1f s%s, au plus pres %.0f m de l'arrivee, arrivee %s), attente", self:getLogName(), tour.expansions, tour.seconds or 0,
            tour.timeout and ", temps depasse" or "", tour.closest or -1, tour.goalFree and "libre" or "dans la culture ou hors champ"))
    end
    self.tourFailX, self.tourFailZ, self.tourFailTime = x, z, g_time or 0
    self:abort()
end
