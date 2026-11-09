-- ============================================================================================================
-- FarmPilot : DriveToVehicleTaskTrack.lua
-- Complément de DriveToVehicleTask (tâche AutoDrive d'origine) : la 2e benne reprend le chemin pris par la 1re.
--
-- Historique : 27/10 20:46 (suivre les traces du 942 qui est passé : au moins un passage
-- cohérent).
--
-- Règle : le chemin de la 1re (sa trace jusqu'à la moissonneuse, gardée sur la moissonneuse, puis ses miettes) est
-- essayé avant toute recherche : rejoint là où il passe près devant le tracteur, suivi jusqu'à la miette visée, chaque
-- tronçon vérifié (culture sous les roues, obstacles fixes) ; arrêté un peu avant un endroit bloqué. Trop court ou
-- ne rapprochant pas de la cible : la recherche de trajet habituelle prend la suite.
--
-- Branché par : DriveToVehicleTask:startPlanning (DriveToVehicleTaskFollow.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
-- 27/10 20:46 (follow the tracks of the 942 that went through: at least a consistent passage): the way the
-- 1st drove (its track to the harvester, kept on the harvester, then its crumbs) is taken before any search, joined
-- where it passes near the train, every stretch checked (crop at the tyres, fixed obstacles)
DriveToVehicleTask.TRACK_JOIN_DISTANCE = 25  -- m: the track must pass this close ahead of the tractor
DriveToVehicleTask.TRACK_JOIN_AHEAD = 3      -- m: joined at a point at least this far ahead
DriveToVehicleTask.TRACK_MIN_LENGTH = 10
DriveToVehicleTask.TRACK_MIN_GAIN = 5        -- m closer to the target at least
DriveToVehicleTask.TRACK_MAX_AGE = 1200000   -- ms: the 1st's track to the harvester this old at most
DriveToVehicleTask.TRACK_STOP_OVERRUN = 4    -- m cut back before a blocked spot

-- nom du véhicule pour les logs (même fonction locale dans chaque fichier DriveToVehicleTask*.lua)
local function logName(vehicle)
    return vehicle ~= nil and vehicle.getName ~= nil and tostring(vehicle:getName()) or "?"
end

-- ------------------------------------------------------------------------------------------------------------
-- La trace de la 1re (the 1st's track)
-- ------------------------------------------------------------------------------------------------------------
-- the way the 1st drove: its track to the harvester (shared on the harvester for the next ones, TRACK_MAX_AGE at most)
-- then its crumbs up to the one aimed at. Returns the points and how many of them belong to the track to the harvester
function DriveToVehicleTask:getFirstTrack(targetIndex)
    local points = {}
    local mode = self:getFirstMode()
    local combine = mode ~= nil and mode.combine or nil
    local shared = combine ~= nil and combine.ad ~= nil and combine.ad.sharedLane or nil
    if shared ~= nil and shared.points ~= nil and (g_time or 0) - (shared.time or 0) <= DriveToVehicleTask.TRACK_MAX_AGE then
        for _, p in ipairs(shared.points) do
            points[#points + 1] = {x = p.x, y = p.y, z = p.z}
        end
    end
    local laneCount = #points
    local items = self:getCrumbs()
    if items ~= nil then
        local last = math.min(targetIndex or #items, #items)
        for i = 1, last do
            local c = items[i]
            points[#points + 1] = {x = c.x, y = c.y, z = c.z}
        end
    end
    return points, laneCount
end

-- one stretch of the 1st's track: crop at the tyres and fixed obstacles. The field test is left out on purpose: the
-- 1st drove there, and the entrance where the follower stands is road
function DriveToVehicleTask:trackStretchClear(pfm, a, b, cropHalf)
    local dx, dz = b.x - a.x, b.z - a.z
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 0.05 then
        return true
    end
    local nx, nz = -dz / l, dx / l
    local n = math.max(1, math.ceil(l / 0.5))
    local samples = math.ceil(cropHalf * 4)
    for i = 0, n do
        local px, pz = a.x + dx * i / n, a.z + dz * i / n
        for k = 0, samples do
            local w = -cropHalf + 2 * cropHalf * k / samples
            if pfm:edgeCropAt(px + nx * w, pz + nz * w) then
                return false, "culture"
            end
        end
    end
    if not pfm:isStretchClear(a, b, nil, true, true) then
        return false, "obstacle"
    end
    return true
end

-- the 1st's track joined where it passes ahead of the train and followed up to the crumb aimed at
function DriveToVehicleTask:tryTrack(target, targetIndex, why)
    local pfm = self.vehicle.ad.pathFinderModule
    if pfm == nil or pfm.isStretchClear == nil or pfm.edgeCropAt == nil or pfm.getCropHalfWidth == nil then
        return false
    end
    local name, targetName = logName(self.vehicle), logName(self.targetVehicle)
    local track, laneCount = self:getFirstTrack(targetIndex)
    if #track < 2 then
        return false
    end
    local vx, vy, vz = getWorldTranslation(self.vehicle.components[1].node)
    local hx, _, hz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local hl = math.sqrt(hx * hx + hz * hz)
    if hl < 0.01 then
        return false
    end
    hx, hz = hx / hl, hz / hl
    -- join point: the nearest track point ahead of the tractor, the track running roughly our way there
    local best, bestD = nil, DriveToVehicleTask.TRACK_JOIN_DISTANCE
    for i = 1, #track - 1 do
        local p, q = track[i], track[i + 1]
        local ahead = (p.x - vx) * hx + (p.z - vz) * hz
        local d = MathUtil.vector2Length(p.x - vx, p.z - vz)
        local ldx, ldz = q.x - p.x, q.z - p.z
        local ll = math.sqrt(ldx * ldx + ldz * ldz)
        if ahead >= DriveToVehicleTask.TRACK_JOIN_AHEAD and d < bestD and ll > 0.1 and (ldx * hx + ldz * hz) / ll > 0.3 then
            best, bestD = i, d
        end
    end
    if best == nil then
        print(string.format("[AD-Suivi] %s: %s : trace de %s (%d points, dont %d jusqu'a l'ensileuse) : aucun point a moins de %d m devant moi dans mon sens, pas suivie",
            name, why, targetName, #track, laneCount, DriveToVehicleTask.TRACK_JOIN_DISTANCE))
        return false
    end
    local cropHalf = pfm:getCropHalfWidth()
    local points = {{x = vx, y = vy, z = vz}}
    local length, reason = 0, "fin de la trace"
    local i = best
    while i <= #track do
        local a, b = points[#points], track[i]
        local clear, what = self:trackStretchClear(pfm, a, b, cropHalf)
        if not clear then
            reason = string.format("%s vers %.0f,%.0f", tostring(what), b.x, b.z)
            break
        end
        length = length + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        points[#points + 1] = {x = b.x, y = b.y, z = b.z}
        i = i + 1
    end
    if reason ~= "fin de la trace" then
        -- stopped short of the blocked spot: the train overruns its last point
        local cut = 0
        while #points > 2 and cut < DriveToVehicleTask.TRACK_STOP_OVERRUN do
            local p1, p2 = points[#points - 1], points[#points]
            local l = MathUtil.vector2Length(p2.x - p1.x, p2.z - p1.z)
            cut = cut + l
            length = length - l
            table.remove(points, #points)
        end
    end
    if length < DriveToVehicleTask.TRACK_MIN_LENGTH then
        print(string.format("[AD-Suivi] %s: %s : trace de %s trop courte d'ici (%.0f m, %s), je cherche un trajet", name, why, targetName, length, reason))
        return false
    end
    local last = points[#points]
    local startD = MathUtil.vector2Length(target.x - vx, target.z - vz)
    local endD = MathUtil.vector2Length(target.x - last.x, target.z - last.z)
    if endD > startD - DriveToVehicleTask.TRACK_MIN_GAIN then
        print(string.format("[AD-Suivi] %s: %s : trace de %s ne me rapproche pas de %s (%.0f m au depart, %.0f m a la fin, %s), je cherche un trajet", name, why, targetName, tostring(self.targetKind), startD, endD, reason))
        return false
    end
    print(string.format("[AD-Suivi] %s: %s : je reprends la trace de %s a %.0f m devant moi (point %d/%d, %d jusqu'a l'ensileuse) sur %.0f m vers %s (%d points, fin : %s)",
        name, why, targetName, bestD, best, #track, laneCount, length, tostring(self.targetKind), #points, reason))
    self.wayPoints = points
    self.vehicle.ad.drivePathModule:setWayPoints(points)
    self.state = DriveToVehicleTask.STATE_DRIVING
    self.failures = 0
    self.retryDelay = DriveToVehicleTask.RETRY_WAIT
    return true
end
