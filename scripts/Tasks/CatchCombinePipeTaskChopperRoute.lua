-- ============================================================================================================
-- FarmPilot : CatchCombinePipeTaskChopperRoute.lua
-- Complément de CatchCombinePipeTask, ENSILEUSE seulement (la benne roule à côté d'elle en continu) : le trajet vers
-- elle. (moissonneuse : le trajet d'AutoDrive d'origine)
--
-- 1. Trajet en morceaux : un trajet partiel finit par un arrêt et un nouveau calcul ; le morceau suivant est calculé dès
--    que le tracteur a commencé celui-ci, depuis la fin de ce morceau, et ajouté au bout : le tracteur roule sans
--    s'arrêter. Relancé si l'ensileuse a beaucoup bougé ; pas de trajet : arrêt et nouveau calcul comme avant.
-- 2. Aucun trajet : départ guidé pour désenclaver le train ; attente entre deux calculs doublée tant que rien ne bouge
--    (RETRY_DELAY_MIN à RETRY_DELAY_MAX) ; sur sa trace, elle devant : suivre sa trace jusque derrière elle ; recul dans
--    ses propres traces pour ouvrir l'angle (STATE_OPEN_REVERSE, OPEN_REVERSE_DISTANCE m, une fois par endroit).
-- 3. Arrêté contre un véhicule (bennes qui attendent) sur le trajet : recul dans ses traces, puis nouveau calcul.
--
-- Historique :
--   24/10       10 m de recul pour ouvrir l'angle, c'était trop court (OPEN_REVERSE_DISTANCE = 15) ; arrêté contre un
--               véhicule : reculer dans ses traces ; (sim 24/10) sur sa trace, elle devant : la suivre ;
--   25/10 14:21 6205 TTV : 51 morceaux ajoutés en 90 s sans bouger (PREPLAN_MAX_STANDING) ;
--   25/10 19:14 7R : morceaux jusqu'à 135 m de l'ensileuse : un morceau qui finit plus loin d'elle n'est pas ajouté.
--
-- Branché par : CatchCombinePipeTask:new (retryDelay), :update (updateVehicleBlocked et updateOpenReverseState avant la
-- machine à états, checkGuidedDeparture dans STATE_PATHPLANNING, attente retryDelay dans STATE_DELAY_PATHPLANNING,
-- checkPreplannedEnd et updatePreplanning dans STATE_DRIVING) ; updateRetryDelay, tryCombineTrail et tryOpenReverse par
-- les solutions de repli (CatchCombinePipeTaskClear.lua, CatchCombinePipeTaskChopperUTurn.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- États et réglages
-- ------------------------------------------------------------------------------------------------------------
CatchCombinePipeTask.STATE_OPEN_REVERSE = {} -- forage harvester: backing off along its own track to open the angle
CatchCombinePipeTask.OPEN_REVERSE_DISTANCE = 15 -- m (24/10: 10 was too short)
CatchCombinePipeTask.OPEN_REVERSE_FAILS = 2 -- failed plans from the same place before backing off
CatchCombinePipeTask.OPEN_REVERSE_RADIUS = 15 -- m around a place already backed off from: no new back-off there
CatchCombinePipeTask.OPEN_REVERSE_PAUSE = 120000 -- ms before a back-off is allowed again at the same place
-- forage harvester: no route, nothing moved since the last try (same start, harvester still): wait longer each time
CatchCombinePipeTask.RETRY_DELAY_MIN = 1000 -- ms
CatchCombinePipeTask.RETRY_DELAY_MAX = 10000 -- ms
CatchCombinePipeTask.RETRY_SAME_VEHICLE = 1 -- m moved by the unloader counted as the same start
CatchCombinePipeTask.RETRY_SAME_COMBINE = 2 -- m moved by the harvester counted as the same target
-- trajet en morceaux (updatePreplanning)
CatchCombinePipeTask.PREPLAN_START_DISTANCE = 1    -- m driven on the piece before planning the next one
CatchCombinePipeTask.PREPLAN_COMBINE_MOVED = 30    -- m the harvester may move before the next piece is planned again
CatchCombinePipeTask.PREPLAN_MIN_LEFT = 5          -- m left on the piece to still relaunch
CatchCombinePipeTask.PREPLAN_MAX_STANDING = 3      -- pieces appended at most while the tractor stays within PREPLAN_STANDING_RADIUS (25/10 14:21)
CatchCombinePipeTask.PREPLAN_STANDING_RADIUS = 10  -- m
-- sur sa trace (tryCombineTrail)
CatchCombinePipeTask.TRAIL_BEARING = 60      -- deg: the harvester ahead of the tractor within this angle
CatchCombinePipeTask.TRAIL_RETRY_DISTANCE = 5
CatchCombinePipeTask.TRAIL_RETRY_TIME = 30000
-- arrêté contre un véhicule (updateVehicleBlocked)
CatchCombinePipeTask.VEHICLE_BLOCKED_TIME = 10000 -- ms standing in front of a vehicle before backing off
CatchCombinePipeTask.VEHICLE_BLOCKED_REVERSE = 15 -- m backed off along the own tracks

-- ------------------------------------------------------------------------------------------------------------
-- Accroches (appelées par CatchCombinePipeTask:update)
-- ------------------------------------------------------------------------------------------------------------
-- STATE_PATHPLANNING, aucun trajet : départ guidé
function CatchCombinePipeTask:checkGuidedDeparture()
    if (self.wayPoints == nil or #self.wayPoints < 1) and self.vehicle.ad.pathFinderModule:tryGuidedDeparture() then
        -- forage harvester: no route to it from here, a guided departure frees the train first (desenclavement),
        -- the next plan starts from where it stops
        self.wayPoints = self.vehicle.ad.pathFinderModule:getPath()
        print(string.format("[AD-Fin] %s: aucun chemin vers l'ensileuse, desenclavement par depart guide", tostring(self.vehicle:getName())))
    end
end

-- avant la machine à états (état retiré de celle-ci) ; vrai = update() s'arrête là
function CatchCombinePipeTask:updateOpenReverseState(dt)
    if self.state == CatchCombinePipeTask.STATE_OPEN_REVERSE then
        local result = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:updateTrackReverse(dt)
        if result ~= "running" then
            print(string.format("[AD-Fin] %s: recul de degagement termine (%s), nouveau calcul", tostring(self.vehicle:getName()), result))
            self.state = CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
        end
        return true
    end
    return false
end

-- STATE_DRIVING, fin du trajet ; vrai = update() s'arrête là
function CatchCombinePipeTask:checkPreplannedEnd()
    if self.vehicle.ad.drivePathModule:isTargetReached() and self.preplanning then
        -- end of a partial route, the next route is still being planned: wait for it here
        self.preplanning = false
        self.state = CatchCombinePipeTask.STATE_PATHPLANNING
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Trajet en morceaux (appelée par update en STATE_DRIVING)
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester: a partial route ends with a stop and a new plan. The next piece is planned as soon as the
-- tractor has started this one, from the end of this piece (its position and heading), and appended to it:
-- the tractor drives on without stopping. Relaunched if the harvester moved a lot; no route: stop and plan as before
function CatchCombinePipeTask:updatePreplanning(dt)
    if not self.routeIsPartial or not AutoDrive.isChopperUnloading(self.vehicle) then
        return
    end
    local pf = self.vehicle.ad.pathFinderModule
    local dpm = self.vehicle.ad.drivePathModule
    local vx, vy, vz = getWorldTranslation(self.vehicle.components[1].node)
    local name = tostring(self.vehicle:getName())
    local wps = dpm:getWayPoints()
    if wps == nil or #wps < 2 then
        self.routeIsPartial = false
        return
    end
    local last, before = wps[#wps], wps[#wps - 1]
    local leftOnPiece = MathUtil.vector2Length(last.x - vx, last.z - vz)
    if not self.preplanning then
        if MathUtil.vector2Length(wps[1].x - vx, wps[1].z - vz) < CatchCombinePipeTask.PREPLAN_START_DISTANCE then
            return
        end
        local dx, dz = last.x - before.x, last.z - before.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 0.1 then
            self.routeIsPartial = false
            return
        end
        -- forage harvester: the piece ends within CLOSE_RANGE of it, the chase drives from there (no grid route near it)
        local hx, _, hz = getWorldTranslation(self.combine.components[1].node)
        if AutoDrive.isChopperUnloading(self.vehicle) and MathUtil.vector2Length(last.x - hx, last.z - hz) < CatchCombinePipeTask.CLOSE_RANGE then
            self.routeIsPartial = false
            print(string.format("[AD-Fin] %s: fin du morceau a %.0f m de l'ensileuse, pas de morceau suivant, la poursuite prendra la main", name, MathUtil.vector2Length(last.x - hx, last.z - hz)))
            return
        end
        self.nextStartPose = {x = last.x, y = last.y or vy, z = last.z, rx = dx / l, rz = dz / l}
        if self:startNewPathFinding() then
            self.preplanning = true
            local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
            self.preplanCombine = {x = cx, z = cz}
            print(string.format("[AD-Fin] %s: calcul du morceau suivant lance depuis la fin du morceau (%.0f,%.0f), %.0f m avant", name, last.x, last.z, leftOnPiece))
        else
            self.routeIsPartial = false
        end
        self.nextStartPose = nil
        return
    end
    pf:update(dt)
    if not pf:hasFinished() then
        return
    end
    self.preplanning = false
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    local moved = MathUtil.vector2Length(cx - self.preplanCombine.x, cz - self.preplanCombine.z)
    if moved > CatchCombinePipeTask.PREPLAN_COMBINE_MOVED then
        if leftOnPiece > CatchCombinePipeTask.PREPLAN_MIN_LEFT then
            -- planned toward where the harvester was: plan again from the same end of piece
            print(string.format("[AD-Fin] %s: l'ensileuse a bouge de %.0f m, nouveau calcul du morceau suivant", name, moved))
            return
        end
        self.routeIsPartial = false
        print(string.format("[AD-Fin] %s: l'ensileuse a bouge de %.0f m, arret au bout du morceau et nouveau calcul", name, moved))
        return
    end
    local path = pf:getPath()
    if path == nil or #path < 2 then
        self.routeIsPartial = false
        print(string.format("[AD-Fin] %s: pas de morceau suivant, arret au bout du morceau et nouveau calcul", name))
        return
    end
    -- 25/10 14:21 (6205 TTV: 51 pieces appended in 90 s without moving, lane and grid in turn): no more than
    -- PREPLAN_MAX_STANDING pieces while the tractor stays about where it is, then it drives this piece to its end
    local anchor = self.preplanAnchor
    if anchor == nil or MathUtil.vector2Length(vx - anchor.x, vz - anchor.z) > CatchCombinePipeTask.PREPLAN_STANDING_RADIUS then
        self.preplanAnchor = {x = vx, z = vz, count = 0}
        anchor = self.preplanAnchor
    end
    anchor.count = anchor.count + 1
    if anchor.count > CatchCombinePipeTask.PREPLAN_MAX_STANDING then
        self.routeIsPartial = false
        print(string.format("[AD-Fin] %s: %d morceaux ajoutes sans avancer de %d m, boucle : arret au bout de ce morceau et nouveau calcul", name, anchor.count - 1, CatchCombinePipeTask.PREPLAN_STANDING_RADIUS))
        return
    end
    -- 25/10 19:14 (7R, pieces up to 135 m from the harvester): a partial next piece that ends farther from the
    -- harvester than the end of this piece leads away, it is not appended
    if pf.partialPath then
        local pEnd = path[#path]
        local dStart = MathUtil.vector2Length(last.x - cx, last.z - cz)
        local dEnd = MathUtil.vector2Length(pEnd.x - cx, pEnd.z - cz)
        if dEnd > dStart - 1 then
            self.routeIsPartial = false
            print(string.format("[AD-Fin] %s: morceau suivant refuse, il m'eloigne de l'ensileuse (%.0f m -> %.0f m) : arret au bout de ce morceau et nouveau calcul", name, dStart, dEnd))
            return
        end
    end
    -- what is left of this piece, then the next piece
    local newWps = {{x = vx, y = vy, z = vz}}
    local index = dpm:getCurrentWayPointIndex() or 2
    for i = math.max(index, 2), #wps do
        newWps[#newWps + 1] = wps[i]
    end
    for i = 1, #path do
        local p = path[i]
        local tail = newWps[#newWps]
        if MathUtil.vector2Length(p.x - tail.x, p.z - tail.z) > 0.5 then
            newWps[#newWps + 1] = p
        end
    end
    self.wayPoints = newWps
    dpm:setWayPoints(newWps)
    self.routeIsPartial = pf.partialPath == true
    self.newPathFindingCounter = 0
    print(string.format("[AD-Fin] %s: morceau suivant ajoute a la suite (%d points), sans arret%s", name, #path, self.routeIsPartial and ", encore partiel" or ""))
end

-- ------------------------------------------------------------------------------------------------------------
-- Aucun trajet : attente, sa trace, recul pour ouvrir l'angle
-- ------------------------------------------------------------------------------------------------------------
-- forage harvester: a failed plan from the same start with the harvester at the same place gives the same result,
-- the next try waits twice as long (up to RETRY_DELAY_MAX); anything moved: back to RETRY_DELAY_MIN
function CatchCombinePipeTask:updateRetryDelay()
    if not AutoDrive.isChopperUnloading(self.vehicle) then
        return
    end
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    local f = self.lastFailure
    if f ~= nil and MathUtil.vector2Length(vx - f.vx, vz - f.vz) < CatchCombinePipeTask.RETRY_SAME_VEHICLE
        and MathUtil.vector2Length(cx - f.cx, cz - f.cz) < CatchCombinePipeTask.RETRY_SAME_COMBINE then
        self.retryDelay = math.min(CatchCombinePipeTask.RETRY_DELAY_MAX, (self.retryDelay or CatchCombinePipeTask.RETRY_DELAY_MIN) * 2)
        print(string.format("[AD-Fin] %s: meme echec, rien n'a bouge, nouvel essai dans %.0f s", tostring(self.vehicle:getName()), self.retryDelay / 1000))
    else
        self.retryDelay = CatchCombinePipeTask.RETRY_DELAY_MIN
    end
    self.lastFailure = {vx = vx, vz = vz, cx = cx, cz = cz}
end

-- forage harvester: no route, but the tractor stands on the harvester's trail with the harvester ahead (sim 24/10:
-- 17 m behind it, aligned, target 21 m behind it is behind the tractor): drive its trail up to just behind it
function CatchCombinePipeTask:tryCombineTrail()
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if not AutoDrive.isChopperUnloading(self.vehicle) or self.combine == nil or mode == nil or mode.getCombineTrailFrom == nil then
        return false
    end
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    if self.trailTried ~= nil and MathUtil.vector2Length(vx - self.trailTried.x, vz - self.trailTried.z) < CatchCombinePipeTask.TRAIL_RETRY_DISTANCE
        and g_time - self.trailTried.time < CatchCombinePipeTask.TRAIL_RETRY_TIME then
        return false
    end
    self.trailTried = {x = vx, z = vz, time = g_time}
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    local dx, _, dz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local bearing = math.abs(AutoDrive.angleBetween({x = dx, z = dz}, {x = cx - vx, z = cz - vz}))
    if bearing > CatchCombinePipeTask.TRAIL_BEARING then
        return false
    end
    local combineRear = (self.combine.size ~= nil and self.combine.size.length or 10) / 2 - (self.combine.size ~= nil and self.combine.size.lengthOffset or 0)
    local points, why = mode:getCombineTrailFrom(vx, vz, HandleHarvesterTurnTask.TRAIL_START_DISTANCE, combineRear + HandleHarvesterTurnTask.TRAIL_KEEP_BEHIND_CLOSE)
    if points == nil then
        print(string.format("[AD-Fin] %s: pas de chemin, trace de l'ensileuse inutilisable (%s)", tostring(self.vehicle:getName()), tostring(why)))
        return false
    end
    -- (09/11) avec les méthodes de HandleHarvesterTurnTask : un virage serré (< 30 m) appelle self:getTrailerOfftrack
    local ok, groundWhy = HandleHarvesterTurnTask.checkGround(setmetatable({vehicle = self.vehicle}, {__index = HandleHarvesterTurnTask}), points)
    if not ok then
        print(string.format("[AD-Fin] %s: pas de chemin, trace de l'ensileuse refusee (%s)", tostring(self.vehicle:getName()), tostring(groundWhy)))
        return false
    end
    print(string.format("[AD-Fin] %s: pas de chemin, je suis la trace de l'ensileuse jusqu'a %.0f m derriere elle (%d points)",
        tostring(self.vehicle:getName()), HandleHarvesterTurnTask.TRAIL_KEEP_BEHIND_CLOSE, #points))
    self.vehicle.ad.pathFinderModule:reset()
    self.wayPoints = points
    self.vehicle.ad.drivePathModule:setWayPoints(points)
    self.combinesStartLocation = {x = cx, z = cz}
    self.routeIsPartial = false
    self.preplanning = false
    self.infoNoPath = false
    self.infoOnTrail = true -- status text, until the next plan
    self.state = CatchCombinePipeTask.STATE_DRIVING
    return true
end

-- forage harvester: no route from here several times (nose against the crop, angle too sharp): back off about
-- OPEN_REVERSE_DISTANCE along its own clean track to open the angle, then plan again. Once per place
function CatchCombinePipeTask:tryOpenReverse()
    if not AutoDrive.isChopperUnloading(self.vehicle) then
        return false
    end
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    local track = mode.track
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    -- once per place: remembered on the vehicle, the place of the failures moves with the back-off itself
    local last = self.vehicle.ad.openReverseDone
    if last ~= nil and (g_time or 0) - last.t < CatchCombinePipeTask.OPEN_REVERSE_PAUSE
        and MathUtil.vector2Length(x - last.x, z - last.z) < CatchCombinePipeTask.OPEN_REVERSE_RADIUS then
        return false
    end
    local f = self.openFails
    if f == nil or MathUtil.vector2Length(x - f.x, z - f.z) > 2 then
        self.openFails = {x = x, z = z, count = 1}
        return false
    end
    f.count = f.count + 1
    if f.count < CatchCombinePipeTask.OPEN_REVERSE_FAILS or f.done then
        return false
    end
    if self:tryCropTipHandover(f) then
        return true
    end
    if track == nil or #track < 3 then
        if not f.noTrackLogged then
            f.noTrackLogged = true
            print(string.format("[AD-Fin] %s: pas de trajet d'ici %d fois, recul impossible (pas de traces enregistrees)", tostring(self.vehicle:getName()), f.count))
        end
        return false
    end
    -- track point about OPEN_REVERSE_DISTANCE behind the tractor
    -- counted from the track point closest to the tractor (11:57: counted from the newest one, ahead after a
    -- reverse, the 10 m back-off was 2 m and ended at once)
    local index, walked = mode:getTrackIndexBehind(CatchCombinePipeTask.OPEN_REVERSE_DISTANCE)
    if index == nil or walked < CombineUnloaderMode.TRACK_STOP_DISTANCE + 2 then
        if not f.shortLogged then
            f.shortLogged = true
            print(string.format("[AD-Fin] %s: pas de trajet d'ici %d fois, recul impossible (%.0f m de traces derriere)", tostring(self.vehicle:getName()), f.count, walked or 0))
        end
        return false
    end
    f.done = true
    if mode:startTrackReverse(self.combine, nil, index) then
        self.vehicle.ad.openReverseDone = {x = x, z = z, t = g_time or 0}
        print(string.format("[AD-Fin] %s: pas de trajet d'ici %d fois, recul de %.0f m dans ses traces pour ouvrir l'angle", tostring(self.vehicle:getName()), f.count, walked))
        self.infoReverse = {blocked = false, distance = walked} -- status text
        self.state = CatchCombinePipeTask.STATE_OPEN_REVERSE
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Arrêté contre un véhicule (appelée par update avant la machine à états)
-- ------------------------------------------------------------------------------------------------------------
-- 24/10: stuck against a vehicle (waiting trailers) on the way to the harvester: back off in its own
-- tracks, then plan again from there (the planned route did not see them or they moved meanwhile)
function CatchCombinePipeTask:updateVehicleBlocked(dt, standing)
    local detour = self.vehicle.ad.obstacleDetourModule
    if not standing or detour == nil or detour.isVehicleInFront == nil or not AutoDrive.isChopperUnloading(self.vehicle)
        or self.vehicle.ad.drivePathModule:isTargetReached() then
        self.vehicleBlockedTime = 0
        return false
    end
    self.vehicleBlockedTime = (self.vehicleBlockedTime or 0) + dt
    if self.vehicleBlockedTime < CatchCombinePipeTask.VEHICLE_BLOCKED_TIME then
        return false
    end
    self.vehicleBlockedTime = 0
    if not detour:isVehicleInFront() then
        return false
    end
    local name = tostring(self.vehicle:getName())
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    local track = mode.track
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local last = self.vehicle.ad.openReverseDone
    if last ~= nil and (g_time or 0) - last.t < CatchCombinePipeTask.OPEN_REVERSE_PAUSE
        and MathUtil.vector2Length(x - last.x, z - last.z) < 3 then
        return false
    end
    if track == nil or #track < 3 then
        print(string.format("[AD-Fin] %s: bloque par un vehicule devant, recul impossible (pas de traces enregistrees)", name))
        self.vehicle.ad.openReverseDone = {x = x, z = z, t = g_time or 0}
        return false
    end
    local index, walked = mode:getTrackIndexBehind(CatchCombinePipeTask.VEHICLE_BLOCKED_REVERSE)
    if index == nil or walked < CombineUnloaderMode.TRACK_STOP_DISTANCE + 2 then
        print(string.format("[AD-Fin] %s: bloque par un vehicule devant, recul impossible (%.0f m de traces derriere)", name, walked or 0))
        self.vehicle.ad.openReverseDone = {x = x, z = z, t = g_time or 0}
        return false
    end
    self.vehicle.ad.openReverseDone = {x = x, z = z, t = g_time or 0}
    if mode:startTrackReverse(self.combine, nil, index) then
        print(string.format("[AD-Fin] %s: bloque %d s par un vehicule devant, recul de %.0f m dans ses traces puis nouveau calcul", name,
            CatchCombinePipeTask.VEHICLE_BLOCKED_TIME / 1000, math.min(walked, CatchCombinePipeTask.VEHICLE_BLOCKED_REVERSE)))
        self.preplanning = false
        self.vehicle.ad.pathFinderModule:reset()
        -- status text
        self.infoReverse = {blocked = true, distance = math.min(walked, CatchCombinePipeTask.VEHICLE_BLOCKED_REVERSE)}
        self.state = CatchCombinePipeTask.STATE_OPEN_REVERSE
        return true
    end
    return false
end
