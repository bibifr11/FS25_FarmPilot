-- ============================================================================================================
-- FarmPilot : CornerModuleEndManoeuvre.lua
-- Complément de CornerModule.lua : manœuvre en fin de route, au lieu d'un détour. Commun à tous les attelages.
--
-- 08/11 : en fin de parcours, une manœuvre plutôt qu'un détour, décidée avant de partir. Quand le dernier point est
-- hors de portée, une manœuvre est cherchée comme un chauffeur la fait : depuis un point de la route avant le virage,
-- en avant en tournant dans le virage, recul (en tournant de l'autre côté ; tout droit et court avec un outil traîné),
-- puis en avant jusqu'à la destination. Tous les demi-mètres l'attelage est contrôlé (obstacles fixes, fossé ou talus,
-- sol de champ quand la route n'est pas sur un champ). La plus rapide est comparée à l'autre chemin d'arrivée
-- (détour, CornerModuleEndRoute.lua) : la plus rapide est conduite. Conduite avec les temps (legs) d'ADBandTurn
-- (ADBandTurn.driveLeg, BandTurnModuleDrive.lua).
-- Manœuvre ratée : cette destination passe par l'autre chemin d'arrivée pendant EM_FAILED_TIME (endFailed).
--
-- Branché par : CornerModuleEndRoute.lua (avoidTightEnd -> endManoeuvreRoute) ; ADCornerModule:handle
-- (CornerModule.lua) conduit le point de manœuvre (driveEndManoeuvre) ; ADCornerModule:reset -> stopEndManoeuvre ;
-- DrivePathModule.lua laisse ce point au module (isCloseToWaypoint).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADCornerModule.EM_STOP_BACK = 24          -- m of route before the destination where the manoeuvre may start ...
ADCornerModule.EM_STOP_MIN = 3            -- m ... but not closer
ADCornerModule.EM_STOP_STEP = 3           -- m between two starts tried
ADCornerModule.EM_LEAD_IN = 8             -- m of route before the start driven in the first leg (joins it smoothly)
ADCornerModule.EM_STEP = 0.5              -- m per simulated step
ADCornerModule.EM_TURN_STEP = math.rad(15) -- first leg, forward turning into the bend: tried by steps of ...
ADCornerModule.EM_TURN_MAX = math.rad(135) -- ... up to
ADCornerModule.EM_BACK_MAX = 16           -- m backed up at most
ADCornerModule.EM_BACK_STEP = 2           -- m between two lengths tried
ADCornerModule.EM_TRAILER_BACK_MAX = 8    -- m: trailed tool, straight back only ...
ADCornerModule.EM_TRAILER_ARTICULATION = math.rad(30) -- ... and never more bent than this
ADCornerModule.EM_LAST_MAX = 45           -- m of the last forward leg at most
ADCornerModule.EM_RADIUS_MARGIN = 1.1     -- planned radius = turning radius * margin (some steering left to correct)
ADCornerModule.EM_HEADINGS = {{0}, {math.rad(20), -math.rad(20)}} -- arrival heading: the last road direction, else close
ADCornerModule.EM_HEADING_COST = 6        -- s per radian away from the last road direction
ADCornerModule.EM_SPEED = 5               -- km/h during the manoeuvre (ADBandTurn.SPEED)
ADCornerModule.EM_APPROACH_SPEED = 3      -- m/s on the route before a later start
ADCornerModule.EM_STOP_TIME = 4           -- s per stop (change of direction)
ADCornerModule.EM_TILT_MAX = 0.6          -- m between left and right wheels: more = ditch, bank
ADCornerModule.EM_PITCH_MAX = 1.5         -- m between front and rear of a body
ADCornerModule.EM_TESTS_MAX = 200         -- candidates checked at most ...
ADCornerModule.EM_CHECKS_MAX = 3000       -- ... and poses checked at most (one frame of route calculation)
ADCornerModule.EM_ROAD_SHARE = 0.6        -- average share of the speed limit driven on a detour
ADCornerModule.EM_GAIN_MIN = 10           -- s the manoeuvre must save to be preferred to the other way in
ADCornerModule.EM_FAILED_TIME = 600000    -- ms the other way in is used for a destination after a failed manoeuvre
ADCornerModule.EM_TIMEOUT = 150000        -- ms for the whole manoeuvre (waiting for traffic excluded)
ADCornerModule.EM_WAIT_MAX = 30000        -- ms waiting for a vehicle in the way
ADCornerModule.EM_REPLANS = 1             -- new plans from where the train stands when it goes off the line
ADCornerModule.endFailed = {}             -- [targetId] = g_time of a failed manoeuvre

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local function nowMs()
    return g_time or (g_currentMission ~= nil and g_currentMission.time) or 0
end

local function farmlandAt(x, z)
    if g_farmlandManager ~= nil and g_farmlandManager.getFarmlandIdAtWorldPosition ~= nil then
        return g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    end
    return nil
end

-- turning side of the end of the route: sum of the turns of its last metres
local function endSide(path)
    local total, length = 0, 0
    for i = #path - 1, 2, -1 do
        total = total + ADCornerModule.turnAt(path, i)
        length = length + ADCornerModule.dist(path[i], path[i + 1])
        if length > ADCornerModule.EM_STOP_BACK + 10 then
            break
        end
    end
    return total >= 0 and 1 or -1
end

-- ------------------------------------------------------------------------------------------------------------
-- L'attelage pendant la manœuvre et ses contrôles (fossé, talus, autre champ)
-- ------------------------------------------------------------------------------------------------------------
-- the train for the manoeuvre: a wheeled trailer keeps its geometry (hitch, axle); mounted tools (no wheels on the
-- ground) belong to the tractor body
function ADCornerModule:manoeuvreGeometry()
    if self.geoSource == "measured" or (self.geoSource == "estimated" and self.geoWhy ~= "pas de remorque a roues") then
        return self.geo, "trailed tool"
    end
    if self.trailerLength <= 0 or self.vehicle.components == nil then
        return self.geo, "tractor alone"
    end
    local node = self.vehicle.getAIDirectionNode ~= nil and self.vehicle:getAIDirectionNode() or self.vehicle.components[1].node
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local a = ADCornerModule.headingOf(dx, dz)
    local box = {front = self.geo.tractorBox.front, rear = self.geo.tractorBox.rear, half = self.geo.tractorBox.half}
    local units = AutoDrive.getAllUnits(self.vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit ~= self.vehicle and unit.components ~= nil and unit.components[1] ~= nil then
                local b = ADCornerModule.bodyBox(unit, x, z, a)
                box.front, box.rear, box.half = math.max(box.front, b.front), math.min(box.rear, b.rear), math.max(box.half, b.half)
            end
        end
    end
    return {hitch = 0, trailer = 0, tractorBox = box}, string.format("mounted tool (body %.1f m ahead, %.1f m behind the axle)", box.front, -box.rear)
end

-- one body standing level enough: left / right wheels (ditch, bank) and front / rear
function ADCornerModule:isBodyLevel(x, z, a, box)
    local s, c = math.sin(a), math.cos(a)
    local root = g_currentMission.terrainRootNode
    local h = {}
    for i, f in ipairs({box.front, box.rear}) do
        for j, side in ipairs({-1, 1}) do
            local px, pz = x + s * f + c * box.half * side, z + c * f - s * box.half * side
            h[i * 2 + j - 2] = getTerrainHeightAtWorldPos(root, px, 300, pz)
        end
    end
    if math.abs(h[1] - h[2]) > ADCornerModule.EM_TILT_MAX or math.abs(h[3] - h[4]) > ADCornerModule.EM_TILT_MAX then
        return false, "ditch or bank"
    end
    if math.abs((h[1] + h[2]) - (h[3] + h[4])) / 2 > ADCornerModule.EM_PITCH_MAX then
        return false, "slope"
    end
    return true
end

-- wheels of one axle on a field of another farmland than the destination one (the field allowed is its own)
function ADCornerModule:isOtherField(x, z, a, half, farmland)
    local nx, nz = math.cos(a), -math.sin(a)
    for _, side in ipairs({-1, 1}) do
        local px, pz = x + nx * half * side, z + nz * half * side
        if self:isOnField(px, pz) and farmlandAt(px, pz) ~= farmland then
            return true
        end
    end
    return false
end

function ADCornerModule:emCheckPose(pose, reference)
    local ok, reason = self:checkPose(pose, reference, true)
    if not ok then
        return false, reason
    end
    if reference.farmland ~= nil then
        if self:isOtherField(pose.x, pose.z, pose.a, self.geo.tractorBox.half, reference.farmland) then
            return false, "other field (tractor)"
        end
        if self.geo.trailer > 0 and self.geo.trailerBox ~= nil and self:isOtherField(pose.tx, pose.tz, self:trailerHeading(pose), self.geo.trailerBox.half, reference.farmland) then
            return false, "other field (trailer)"
        end
    end
    local level, why = self:isBodyLevel(pose.x, pose.z, pose.a, self.geo.tractorBox)
    if not level then
        return false, why .. " (tractor)"
    end
    if self.geo.trailer > 0 and self.geo.trailerBox ~= nil then
        level, why = self:isBodyLevel(pose.tx, pose.tz, self:trailerHeading(pose), self.geo.trailerBox)
        if not level then
            return false, why .. " (trailer)"
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Poses simulées et temps de la manœuvre (legs pour ADBandTurn.driveLeg)
-- ------------------------------------------------------------------------------------------------------------
-- poses every EM_STEP from pose driving dir (1 forward, -1 back) at curvature k over length
function ADCornerModule:emIntegrate(pose, dir, k, length)
    local poses = {}
    for i = 1, math.floor(length / ADCornerModule.EM_STEP + 0.5) do
        pose = self:move(pose, dir * ADCornerModule.EM_STEP, k)
        poses[i] = pose
    end
    return poses
end

-- a chain of poses checked lazily (shared by the candidates): true when poses[1 .. upTo] are clear
function ADCornerModule:emClear(chain, upTo, reference)
    if chain.blocked ~= nil and upTo >= chain.blocked then
        return false, chain.reason
    end
    while chain.checked < upTo do
        local i = chain.checked + 1
        if i % 2 == 0 or i == upTo then
            self.emChecks = self.emChecks + 1
            local ok, reason = self:emCheckPose(chain.poses[i], reference)
            if ok and chain.trailed and math.abs(ADCornerModule.wrap(chain.poses[i].a - self:trailerHeading(chain.poses[i]))) > ADCornerModule.EM_TRAILER_ARTICULATION then
                ok, reason = false, "tool too bent"
            end
            if not ok then
                chain.blocked, chain.reason = i, reason
                return false, reason
            end
        end
        chain.checked = i
    end
    return true
end

-- poses of an arc, straight, arc path from pose (exact geometry)
function ADCornerModule:emPathPoses(pose, path)
    local poses = {}
    local function add(list)
        for _, p in ipairs(list) do
            poses[#poses + 1] = p
        end
        pose = poses[#poses] or pose
    end
    if path.a1 > 1e-3 then
        add(self:emIntegrate(pose, 1, path.s1 / path.r, path.r * path.a1))
    end
    if path.straight > 0.25 then
        add(self:emIntegrate(pose, 1, 0, path.straight))
    end
    if path.a2 > 1e-3 then
        add(self:emIntegrate(pose, 1, path.s2 / path.r, path.r * path.a2))
    end
    return poses
end

-- sample of a pose for ADBandTurn.driveLeg: tractor axle, and the line followed backwards (trailer axle, or the
-- tractor itself)
function ADCornerModule:emSample(pose)
    if self.geo.trailer > 0 then
        return {x = pose.x, z = pose.z, tx = pose.tx, tz = pose.tz}
    end
    return {x = pose.x, z = pose.z, tx = pose.x, tz = pose.z}
end

function ADCornerModule:emLeg(dir, first, poses, from, to)
    local leg = {dir = dir, points = {}, length = 0}
    if first ~= nil then
        leg.points[1] = self:emSample(first)
    end
    for i = from or 1, to or #poses do
        leg.points[#leg.points + 1] = self:emSample(poses[i])
        leg.length = leg.length + ADCornerModule.EM_STEP
    end
    return leg
end

-- ------------------------------------------------------------------------------------------------------------
-- Calcul de la manœuvre (avant de partir)
-- ------------------------------------------------------------------------------------------------------------
-- the manoeuvre from one of the starts to the target pose (x, z, a). starts: {pose, lead (points before), approach (s)}.
-- side: +1 when the bend turns with increasing heading. Returns {legs, time, text} or nil, reason
function ADCornerModule:planManoeuvre(starts, target, side, reference)
    local R = self.radius * ADCornerModule.EM_RADIUS_MARGIN
    local K = 1 / R
    local trailed = self.geo.trailer > 0
    local speed = ADCornerModule.EM_SPEED / 3.6
    local turnSteps = math.floor(ADCornerModule.EM_TURN_MAX / ADCornerModule.EM_TURN_STEP + 0.5)
    local backMax = trailed and ADCornerModule.EM_TRAILER_BACK_MAX or ADCornerModule.EM_BACK_MAX
    local backCurves = trailed and {0} or {-side * K, 0}
    self.emChecks = 0
    local reasons = {}
    local function note(reason)
        reason = string.gsub(tostring(reason), " at %-?%d+,%-?%d+", "")
        reasons[reason] = (reasons[reason] or 0) + 1
    end
    for pass, headings in ipairs(ADCornerModule.EM_HEADINGS) do
        local candidates = {}
        for si, st in ipairs(starts) do
            st.leg1 = st.leg1 or {poses = self:emIntegrate(st.pose, 1, side * K, R * ADCornerModule.EM_TURN_MAX), checked = 0, trailed = false}
            st.leg2 = st.leg2 or {}
            for j = 0, turnSteps do
                local n1 = math.floor(R * ADCornerModule.EM_TURN_STEP * j / ADCornerModule.EM_STEP + 0.5)
                local pose1 = n1 > 0 and st.leg1.poses[n1] or st.pose
                if pose1 == nil then
                    break
                end
                -- forward only (the end redrawn wider), then with a reverse
                local backs = {}
                if j == 0 then
                    backs[#backs + 1] = {k = 0, length = 0}
                end
                for ci, kr in ipairs(backCurves) do
                    local key = j * 10 + ci
                    st.leg2[key] = st.leg2[key] or {poses = self:emIntegrate(pose1, -1, kr, backMax), checked = 0, trailed = trailed}
                    for L = ADCornerModule.EM_BACK_STEP, backMax, ADCornerModule.EM_BACK_STEP do
                        backs[#backs + 1] = {k = kr, length = L, key = key}
                    end
                end
                for _, b in ipairs(backs) do
                    local n2 = math.floor(b.length / ADCornerModule.EM_STEP + 0.5)
                    local pose2 = n2 > 0 and st.leg2[b.key].poses[n2] or pose1
                    for _, dh in ipairs(headings) do
                        local q = {x = target.x, z = target.z, a = target.a + dh}
                        for _, t in ipairs(ADCornerModule.TYPES) do
                            local path = ADCornerModule.arcLineArc(pose2, q, R, t[1], t[2])
                            if path ~= nil and path.length <= ADCornerModule.EM_LAST_MAX then
                                local stops = n2 > 0 and 2 or 0
                                local length = st.leadLength + n1 * ADCornerModule.EM_STEP + b.length + path.length
                                local time = (st.approach or 0) + length / speed + stops * ADCornerModule.EM_STOP_TIME + math.abs(dh) * ADCornerModule.EM_HEADING_COST
                                candidates[#candidates + 1] = {st = st, j = j, n1 = n1, back = b, n2 = n2, path = path, pose2 = pose2, time = time, dh = dh, length = length}
                            end
                        end
                    end
                end
            end
        end
        table.sort(candidates, function(a, b)
            return a.time < b.time
        end)
        local tested = 0
        for _, c in ipairs(candidates) do
            if tested >= ADCornerModule.EM_TESTS_MAX or self.emChecks >= ADCornerModule.EM_CHECKS_MAX then
                note("search limit reached")
                break
            end
            local ok, reason = true, nil
            if c.n1 > 0 then
                ok, reason = self:emClear(c.st.leg1, c.n1, reference)
                if not ok then
                    reason = "forward: " .. tostring(reason)
                end
            end
            if ok and c.n2 > 0 then
                ok, reason = self:emClear(c.st.leg2[c.back.key], c.n2, reference)
                if not ok then
                    reason = "back: " .. tostring(reason)
                end
            end
            if ok then
                tested = tested + 1
                local poses = self:emPathPoses(c.pose2, c.path)
                local chain = {poses = poses, checked = 0, trailed = false}
                ok, reason = self:emClear(chain, #poses, reference)
                if not ok then
                    reason = "last leg: " .. tostring(reason)
                else
                    -- legs for ADBandTurn.driveLeg
                    local legs = {}
                    local first = self:emLeg(1, nil, c.st.lead or {}, 1, #(c.st.lead or {}))
                    if c.n2 == 0 then
                        -- forward only: lead in, then the path
                        for _, p in ipairs(poses) do
                            first.points[#first.points + 1] = self:emSample(p)
                            first.length = first.length + ADCornerModule.EM_STEP
                        end
                        legs[1] = first
                    else
                        for i = 1, c.n1 do
                            first.points[#first.points + 1] = self:emSample(c.st.leg1.poses[i])
                            first.length = first.length + ADCornerModule.EM_STEP
                        end
                        if #first.points >= 2 then
                            legs[#legs + 1] = first
                        end
                        local pose1 = c.n1 > 0 and c.st.leg1.poses[c.n1] or c.st.pose
                        legs[#legs + 1] = self:emLeg(-1, pose1, c.st.leg2[c.back.key].poses, 1, c.n2)
                        legs[#legs + 1] = self:emLeg(1, c.pose2, poses, 1, #poses)
                    end
                    local text
                    if c.n2 == 0 then
                        text = string.format("forward only, %.0f m", c.path.length)
                    else
                        text = string.format("forward %.0f m turning %.0f deg, back %.0f m %s, forward %.0f m", c.n1 * ADCornerModule.EM_STEP,
                            math.deg(ADCornerModule.EM_TURN_STEP * c.j), c.back.length, c.back.k == 0 and "straight" or "turning", c.path.length)
                    end
                    if math.abs(c.dh) > 1e-3 then
                        text = text .. string.format(", arriving %.0f deg off the road", math.deg(c.dh))
                    end
                    return {legs = legs, time = c.time, text = text, start = c.st, tested = tested, checks = self.emChecks, pass = pass}
                end
            end
            note(reason)
        end
    end
    local worst, count = "nothing possible", 0
    for r, n in pairs(reasons) do
        if n > count then
            worst, count = r, n
        end
    end
    return nil, string.format("%s (x%d, %d checks)", worst, count, self.emChecks)
end

-- starts of the manoeuvre on the route: every EM_STOP_STEP metres between EM_STOP_MIN and EM_STOP_BACK before the
-- destination, where the route runs straight (the train arrives there straight)
function ADCornerModule:manoeuvreStarts(path)
    local starts = {}
    local n = #path
    local back = 0
    local nextAt = ADCornerModule.EM_STOP_MIN
    for i = n - 1, 1, -1 do
        local a, b = path[i], path[i + 1]
        local l = ADCornerModule.dist(a, b)
        while l > 0.01 and nextAt <= back + l and nextAt <= ADCornerModule.EM_STOP_BACK do
            local f = (back + l - nextAt) / l -- from a toward b
            local x, z = a.x + (b.x - a.x) * f, a.z + (b.z - a.z) * f
            local h = ADCornerModule.segHeading(a, b)
            -- straight: the route 4 m before runs the same way (15 deg)
            local before = path[i - 1]
            if before == nil or ADCornerModule.dist(a, {x = x, z = z}) >= 4 or math.abs(ADCornerModule.wrap(ADCornerModule.segHeading(before, a) - h)) < math.rad(15) then
                -- lead in: the route from EM_LEAD_IN metres before up to the start
                local lead, leadLength = {}, 0
                local px, pz, k = x, z, i
                local pts = {}
                while k >= 1 and leadLength < ADCornerModule.EM_LEAD_IN do
                    local q = path[k]
                    local d = MathUtil.vector2Length(q.x - px, q.z - pz)
                    leadLength = leadLength + d
                    pts[#pts + 1] = {x = q.x, z = q.z}
                    px, pz = q.x, q.z
                    k = k - 1
                end
                -- every EM_STEP along the lead in, oldest first
                local line = {}
                for m = #pts, 1, -1 do
                    line[#line + 1] = pts[m]
                end
                line[#line + 1] = {x = x, z = z}
                for m = 1, #line - 1 do
                    local p, q = line[m], line[m + 1]
                    local d = ADCornerModule.dist(p, q)
                    local steps = math.max(1, math.floor(d / ADCornerModule.EM_STEP))
                    local hh = ADCornerModule.segHeading(p, q)
                    for s2 = 0, steps - 1 do
                        local f2 = s2 / steps
                        lead[#lead + 1] = self:straightPose(p.x + (q.x - p.x) * f2, p.z + (q.z - p.z) * f2, hh)
                    end
                end
                starts[#starts + 1] = {pose = self:straightPose(x, z, h), index = i, lead = lead, leadLength = #lead * ADCornerModule.EM_STEP,
                                       approach = 0, back = nextAt}
            end
            nextAt = nextAt + ADCornerModule.EM_STOP_STEP
        end
        back = back + l
        if nextAt > ADCornerModule.EM_STOP_BACK then
            break
        end
    end
    -- the route from the furthest start to a later one is driven at the approach speed, not in the manoeuvre
    local furthest = 0
    for _, st in ipairs(starts) do
        furthest = math.max(furthest, st.back)
    end
    for _, st in ipairs(starts) do
        st.approach = (furthest - st.back) / ADCornerModule.EM_APPROACH_SPEED
    end
    return starts
end

-- the route cut at the start of the manoeuvre, then the manoeuvre point, then the destination. Returns it and the
-- time of the manoeuvre, or nil
function ADCornerModule:endManoeuvreRoute(path, targetId, where)
    if ADBandTurn == nil or ADBandTurn.driveLeg == nil or #path < 2 then
        return nil
    end
    local failed = ADCornerModule.endFailed[targetId]
    if failed ~= nil and nowMs() - failed < ADCornerModule.EM_FAILED_TIME then
        self:log("%s: the manoeuvre failed here %.0f s ago, not tried again", where, (nowMs() - failed) / 1000)
        return nil
    end
    local n = #path
    local P = path[n]
    local target = {x = P.x, z = P.z, a = ADCornerModule.segHeading(path[n - 1], P)}
    local side = endSide(path)
    local saved = self.geo
    local geo, what = self:manoeuvreGeometry()
    self.geo = geo
    local starts = self:manoeuvreStarts(path)
    -- field ground: allowed when the destination (or the route just before it) is on a field, that field only
    local reference = {onField = false, onRoad = false}
    for _, q in ipairs({P, starts[1] ~= nil and starts[1].pose or nil}) do
        if q ~= nil and not reference.onField and self:isOnField(q.x, q.z) then
            reference.onField, reference.farmland = true, farmlandAt(q.x, q.z)
        end
    end
    local plan, reason = nil, "no straight route before the bend"
    if #starts > 0 then
        plan, reason = self:planManoeuvre(starts, target, side, reference)
    end
    self.geo = saved
    if plan == nil then
        self:log("%s: no manoeuvre (%s; %s, radius %.1f m, %d starts)", where, tostring(reason), what, self.radius, #starts)
        return nil
    end
    local st = plan.start
    local route = {}
    for k = 1, st.index do
        route[k] = path[k]
    end
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, st.pose.x, 300, st.pose.z)
    route[#route + 1] = {x = st.pose.x, y = y, z = st.pose.z, isManoeuvrePoint = true,
                         endManoeuvre = {legs = plan.legs, target = target, targetId = targetId, side = side, reference = reference, geo = geo, text = plan.text}}
    local last = {}
    for key, value in pairs(P) do
        last[key] = value
    end
    route[#route + 1] = last
    self:log("%s: manoeuvre %.0f m before it: %s (about %.0f s, %s, radius %.1f m, %d tried, %d checks)", where, st.back, plan.text, plan.time, what,
        self.radius * ADCornerModule.EM_RADIUS_MARGIN, plan.tested, plan.checks)
    return route, plan.time
end

-- ------------------------------------------------------------------------------------------------------------
-- Conduite de la manœuvre (point courant : le point de manœuvre, la destination après lui)
-- ------------------------------------------------------------------------------------------------------------
function ADCornerModule:stopEndManoeuvre()
    if self.endRun ~= nil then
        self.endRun = nil
        if self.vehicle.ad ~= nil and self.vehicle.ad.specialDrivingModule ~= nil then
            self.vehicle.ad.specialDrivingModule:reset()
        end
    end
end

function ADCornerModule:driveEndManoeuvre(dt, wp)
    local m = wp.endManoeuvre
    local sdm = self.vehicle.ad.specialDrivingModule
    local run = self.endRun
    if run == nil or run.wp ~= wp then
        run = {wp = wp, legs = m.legs, legIndex = 1, pointIndex = 1, pause = 0, stillTime = 0, time = 0, wait = 0, replans = 0}
        self.endRun = run
        sdm:reset()
        self:log("end manoeuvre: %s", tostring(m.text))
    end
    if run.time > ADCornerModule.EM_TIMEOUT then
        return self:failEndManoeuvre(dt, wp, "too long")
    end
    local leg = run.legs[run.legIndex]
    -- a vehicle in the way while driving forward (the plan does not see vehicles): wait for it
    if leg ~= nil and leg.dir > 0 and run.pause <= 0 then
        local cdm = self.vehicle.ad.collisionDetectionModule
        if cdm ~= nil and cdm.detectObstacle ~= nil and cdm:detectObstacle() then
            run.wait = run.wait + dt
            if run.wait > ADCornerModule.EM_WAIT_MAX then
                return self:failEndManoeuvre(dt, wp, "vehicle in the way")
            end
            sdm:stopVehicle()
            sdm:update(dt)
            run.stillPos = nil
            return true
        end
    end
    run.time = run.time + dt
    local state = leg ~= nil and ADBandTurn.driveLeg(self.vehicle, run, dt) or "done"
    if state == "running" then
        return true
    end
    if state ~= "done" then
        if run.replans < ADCornerModule.EM_REPLANS and self:replanEndManoeuvre(run, m, state) then
            sdm:stopVehicle()
            sdm:update(dt)
            return true
        end
        return self:failEndManoeuvre(dt, wp, state)
    end
    run.legIndex = run.legIndex + 1
    run.pointIndex, run.pause, run.stillTime, run.stillPos = 1, ADBandTurn.LEG_PAUSE, 0, nil
    if run.legIndex <= #run.legs then
        return true
    end
    self:log("end manoeuvre done in %.0f s", run.time / 1000)
    wp.endManoeuvreDone = true
    self:stopEndManoeuvre()
    self.vehicle.ad.drivePathModule:switchToNextWayPoint()
    return true
end

-- off the planned line or held: a new plan from where the train stands, same destination
function ADCornerModule:replanEndManoeuvre(run, m, why)
    run.replans = run.replans + 1
    local node = self.vehicle.getAIDirectionNode ~= nil and self.vehicle:getAIDirectionNode() or self.vehicle.components[1].node
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local saved = self.geo
    self.geo = m.geo
    local pose = self:straightPose(x, z, ADCornerModule.headingOf(dx, dz))
    if m.geo.trailer > 0 then
        local reverseNode = self.vehicle.ad.specialDrivingModule:getReverseNode()
        if reverseNode ~= nil then
            pose.tx, _, pose.tz = getWorldTranslation(reverseNode)
        end
    end
    local plan, reason = self:planManoeuvre({{pose = pose, index = 0, leadLength = 0, approach = 0, back = 0}}, m.target, m.side, m.reference)
    self.geo = saved
    if plan == nil then
        self:log("end manoeuvre: %s, no new plan from here (%s)", tostring(why), tostring(reason))
        return false
    end
    run.legs, run.legIndex, run.pointIndex, run.pause, run.stillTime, run.stillPos, run.loggedLeg = plan.legs, 1, 1, ADBandTurn.LEG_PAUSE, 0, nil, nil
    self:log("end manoeuvre: %s, planned again from here: %s", tostring(why), plan.text)
    return true
end

-- given up: this destination is reached by the other way in for a while, the route is computed again from here
function ADCornerModule:failEndManoeuvre(dt, wp, why)
    local m = wp.endManoeuvre
    self:log("end manoeuvre given up (%s), route computed again (other way in)", tostring(why))
    ADCornerModule.endFailed[m.targetId] = nowMs()
    wp.endManoeuvreDone = true
    self:stopEndManoeuvre()
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm:stopVehicle()
    sdm:update(dt)
    self.vehicle.ad.drivePathModule:setPathTo(m.targetId)
    return true
end
