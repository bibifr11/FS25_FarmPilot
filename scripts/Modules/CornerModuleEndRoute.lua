-- ============================================================================================================
-- FarmPilot : CornerModuleEndRoute.lua
-- Complément de CornerModule.lua : fin de route trop serrée, autre chemin d'arrivée. Commun à tous les attelages.
--
-- Fin de la route (07/11 : virage d'arrivée trop serré = un autre itinéraire, même avec un détour) : une
-- destination derrière un demi-tour plus serré que le braquage du tracteur (« Champ 56 », 170° sur 5 m) n'est jamais
-- atteinte : le tracteur tourne autour du point, la sécurité « bloqué » le relance et la même route le ramène. Avant
-- de partir, la fin de la route est conduite en simulation (direction d'AutoDrive, limitée au rayon de braquage) ;
-- quand le dernier point n'est pas atteint, le virage le plus serré de la fin est interdit et une autre route est
-- cherchée (une autre façon d'entrer dans la destination, détour accepté jusqu'à DETOUR_MAX m).
-- 08/11 : une manœuvre avant d'arriver (CornerModuleEndManoeuvre.lua) est comparée à ce détour : la plus rapide est
-- gardée (EM_ROAD_SHARE, EM_GAIN_MIN). Le choix est gardé dans endCache (vidé quand le réseau change).
--
-- Branché par : GraphManager.lua (ADGraphManager:pathFromTo -> avoidTightEnd, dans un pcall ; markChanges vide
-- endCache).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADCornerModule.END_SIM_BACK = 30       -- m of route before the destination driven in the simulation
ADCornerModule.END_SIM_EXTRA = 25      -- m driven at most beyond the length of that route
ADCornerModule.END_SIM_STEP = 0.25     -- m per simulated step
ADCornerModule.END_TRIES = 4           -- other routes tried at most
ADCornerModule.DETOUR_MAX = 3000       -- m a route may be longer than the first one
ADCornerModule.endCache = {}           -- [start:target:radius] = turns banned for the route found, false when none (cleared when the network changes)

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local function routeLength(path)
    local length = 0
    for i = 1, #path - 1 do
        length = length + ADCornerModule.dist(path[i], path[i + 1])
    end
    return length
end

-- ------------------------------------------------------------------------------------------------------------
-- Simulation de l'arrivée : le dernier point est-il atteint ?
-- ------------------------------------------------------------------------------------------------------------
-- true when the train reaches the last point of path; else false, the closest distance and the sharpest turn of the
-- end of the route as "from:at:to" (waypoint ids), nil when there is none to ban
function ADCornerModule:canReachEnd(path)
    local n = #path
    if n < 3 then
        return true
    end
    -- a reverse section near the end (parking backwards into a shed): driven by AutoDrive's reversing, not judged here
    local reverseLength = 0
    for i = n - 1, 1, -1 do
        if ADGraphManager:isReverseRoad(path[i], path[i + 1]) or path[i].isPathFinderPoint or path[i + 1].isPathFinderPoint then
            return true
        end
        reverseLength = reverseLength + ADCornerModule.dist(path[i], path[i + 1])
        if reverseLength > ADCornerModule.END_SIM_BACK + 10 then
            break
        end
    end
    local radius = self.radius or 6
    local lookAhead = self.lookAhead or 5
    local dpm = self.vehicle.ad ~= nil and self.vehicle.ad.drivePathModule or nil
    local reach = math.max(1.5, math.min(5, dpm ~= nil and dpm.min_distance or 3))
    -- start END_SIM_BACK m before the end, on the route, along it
    local s, back = n, 0
    while s > 1 and back < ADCornerModule.END_SIM_BACK do
        back = back + ADCornerModule.dist(path[s - 1], path[s])
        s = s - 1
    end
    s = math.max(s, 1)
    local x, z = path[s].x, path[s].z
    local h = ADCornerModule.segHeading(path[s], path[s + 1])
    if s > 1 then
        h = ADCornerModule.segHeading(path[s - 1], path[s])
    end
    local current = s + 1
    local step = ADCornerModule.END_SIM_STEP
    local budget = back + ADCornerModule.END_SIM_EXTRA
    local travelled, closest = 0, math.huge
    local last = path[n]
    while travelled < budget do
        -- a point counts as passed within reach, the next one may be taken instead (AutoDrive skips one at most)
        local moved = true
        while moved and current <= n do
            moved = false
            for skip = 0, 1 do
                local p = path[current + skip]
                if p ~= nil and MathUtil.vector2Length(p.x - x, p.z - z) < reach then
                    current = current + skip + 1
                    moved = true
                    break
                end
            end
        end
        closest = math.min(closest, MathUtil.vector2Length(last.x - x, last.z - z))
        if current > n then
            return true
        end
        local k = current
        while k < n and MathUtil.vector2Length(path[k].x - x, path[k].z - z) < lookAhead do
            k = k + 1
        end
        local tx, tz = path[k].x, path[k].z
        local alpha = ADCornerModule.wrap(ADCornerModule.headingOf(tx - x, tz - z) - h)
        local ld = math.max(1, MathUtil.vector2Length(tx - x, tz - z))
        local curvature = math.max(-1 / radius, math.min(1 / radius, 2 * math.sin(alpha) / ld))
        h = h + curvature * step
        x, z = x + math.sin(h) * step, z + math.cos(h) * step
        travelled = travelled + step
    end
    -- sharpest turn between network points in the end of the route
    local worst, key = 0, nil
    local length = 0
    for i = n - 1, 2, -1 do
        length = length + ADCornerModule.dist(path[i], path[i + 1])
        if length > ADCornerModule.END_SIM_BACK then
            break
        end
        local a, b, c = path[i - 1], path[i], path[i + 1]
        if ADCornerModule.isNetworkPoint(a) and ADCornerModule.isNetworkPoint(b) and ADCornerModule.isNetworkPoint(c) then
            local turn = math.abs(ADCornerModule.turnAt(path, i))
            if turn > worst then
                worst, key = turn, a.id .. ":" .. b.id .. ":" .. c.id
            end
        end
    end
    return false, closest, key
end

-- ------------------------------------------------------------------------------------------------------------
-- Autre chemin d'arrivée (détour)
-- ------------------------------------------------------------------------------------------------------------
-- another way into the destination: the sharpest turn of the end (key) is banned and the route searched again.
-- Returns the route, the turns banned and the metres added, or nil
function ADCornerModule:findOtherWayIn(path, startId, targetId, preferredNeighbors, key, where, length0)
    if key == nil then
        self:log("%s: no turn to avoid, no other way in", where)
        return nil
    end
    local banned = {}
    for try = 1, ADCornerModule.END_TRIES do
        banned[key] = true
        local other = ADPathCalculator:GetPath(startId, targetId, preferredNeighbors or {}, self.vehicle, banned)
        if other == nil or #other < 2 then
            self:log("%s: no other route (try %d)", where, try)
            return nil
        end
        local length = routeLength(other)
        if length > length0 + ADCornerModule.DETOUR_MAX then
            self:log("%s: the other route is %.0f m longer (%.0f m at most)", where, length - length0, ADCornerModule.DETOUR_MAX)
            return nil
        end
        local ok2, closest2, key2 = self:canReachEnd(other)
        if ok2 then
            local before = other[#other - 2]
            self:log("%s: other route of %.0f m instead of %.0f m (+%.0f m), coming in by %s", where, length, length0, length - length0, tostring(before ~= nil and before.id or "?"))
            return other, banned, length - length0
        end
        if key2 == nil or banned[key2] then
            self:log("%s: the other route ends as tight (%.1f m at best)", where, closest2)
            return nil
        end
        key = key2
    end
    self:log("%s: no other route the train can end", where)
    return nil
end

-- seconds to drive the metres added by a detour (average share of the speed limit)
function ADCornerModule:detourSeconds(extra)
    local limit = 40
    local sm = self.vehicle.ad ~= nil and self.vehicle.ad.stateModule or nil
    if sm ~= nil and sm.getSpeedLimit ~= nil then
        limit = sm:getSpeedLimit() or limit
    end
    return extra / math.max(1, limit * ADCornerModule.EM_ROAD_SHARE / 3.6)
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale : route gardée, manœuvre ou autre chemin, le plus rapide
-- ------------------------------------------------------------------------------------------------------------
-- path: network route from startId to targetId (ADPathCalculator:GetPath). Returns it, or a route ending with a
-- manoeuvre (08/11), or another route the train can drive to the end, whichever is faster
function ADCornerModule:avoidTightEnd(path, startId, targetId, preferredNeighbors)
    if path == nil or #path < 3 or not self.vehicle.isServer or not ADCornerModule.isEnabled() then
        return path
    end
    self:readTrain()
    local cacheKey = string.format("%s:%s:%.0f", tostring(startId), tostring(targetId), (self.radius or 0) * 10)
    local cached = ADCornerModule.endCache[cacheKey]
    if cached == false then
        return path
    end
    if cached == "manoeuvre" then
        local route = self:endManoeuvreRoute(path, targetId, "same route as before")
        if route ~= nil then
            return route
        end
    elseif cached ~= nil then
        local other = ADPathCalculator:GetPath(startId, targetId, preferredNeighbors or {}, self.vehicle, cached)
        if other ~= nil and #other >= 2 and self:canReachEnd(other) then
            return other
        end
    end
    local ok, closest, key = self:canReachEnd(path)
    if ok then
        return path
    end
    ADCornerModule.endCache[cacheKey] = false
    local marker = ADGraphManager.getMapMarkerByWayPointId ~= nil and ADGraphManager:getMapMarkerByWayPointId(targetId) or nil
    local where = string.format("end of the route to %s (%s)", marker ~= nil and tostring(marker.name) or "?", tostring(targetId))
    local length0 = routeLength(path)
    self:log("%s: radius %.1f m, the last point is not reached (%.1f m at best, turn %s too tight): manoeuvre or another way in", where, self.radius, closest, tostring(key))
    local manoeuvre, manoeuvreTime = self:endManoeuvreRoute(path, targetId, where)
    local other, banned, extra = self:findOtherWayIn(path, startId, targetId, preferredNeighbors, key, where, length0)
    if manoeuvre ~= nil then
        local detourTime = other ~= nil and self:detourSeconds(extra) or math.huge
        if other == nil or manoeuvreTime + ADCornerModule.EM_GAIN_MIN < detourTime then
            ADCornerModule.endCache[cacheKey] = "manoeuvre"
            self:log("%s: manoeuvre kept (%.0f s; other way in: %s)", where, manoeuvreTime,
                other ~= nil and string.format("+%.0f m, about %.0f s more", extra, detourTime) or "none")
            return manoeuvre
        end
        self:log("%s: the other way in is faster (+%.0f m, about %.0f s, manoeuvre %.0f s)", where, extra, detourTime, manoeuvreTime)
    end
    if other ~= nil then
        ADCornerModule.endCache[cacheKey] = banned
        return other
    end
    self:log("%s: route kept", where)
    return path
end
