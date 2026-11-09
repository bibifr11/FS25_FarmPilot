-- ============================================================================================================
-- FarmPilot : DriveToVehicleTaskFollow.lua
-- Complément de DriveToVehicleTask (tâche AutoDrive d'origine) : la 2e benne appelée derrière la 1re la rejoint et
-- suit ses miettes.
--
-- Historique : 25/10 14:00 (appel de la 2e benne), 16:30 (le 7R
-- ne trouvait aucun chemin : à affiner), 16:38 (dans le suivi, le 942 était parti très loin),
-- 25/10 15:12 (s'écarter quand la moissonneuse ou la 1re vient vers elle, StepAsideTask), 27/10 20:47 (ordre des
-- essais : la trace de la 1re, le bord de la culture, les bandes coupées, la grille fine, une ligne droite).
--
-- Règle :
-- - attendre que la 1re soit en place à côté de la moissonneuse avec des miettes posées (garée dans le champ si elle
--   attend dans l'entrée, voir DriveToVehicleTaskFieldPark.lua) ;
-- - viser une miette CRUMB_FROM_END m avant la fin de la trace (jamais « 35 m derrière la 1re » s'il y a des miettes) ;
-- - trajet : la trace de la 1re (DriveToVehicleTaskTrack.lua), puis la grille, la bande coupée, une ligne droite ;
--   pas de trajet : attendre et recalculer, sans jamais lâcher le suivi ; un trajet bien plus long que la ligne
--   droite est refusé ;
-- - une miette proche devant : le suivi (FollowVehicleTask) commence tout de suite.
--
-- Branché par une ligne dans DriveToVehicleTask.lua : setUp, update, abort.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
-- 25/10 14:00 (call of the 2nd unloader), 16:30 (the 7R found no route, to be refined here), 16:38 (the 942
-- went far off while following): the 2nd unloader called behind the 1st.
-- It waits until the 1st is in place beside the harvester with crumbs laid, aims the crumb trail (never "35 m behind the
-- 1st" when crumbs exist), with the grid route first, then a route traced in the cut strips (band flood), then a straight
-- line; no route: it waits and tries again, and never gives up the follow (that made the harvester call it again every
-- 13 s). A route far longer than the straight distance is refused (it waits instead). A crumb close ahead: it follows at once
DriveToVehicleTask.CRUMB_FROM_END = 40         -- m from the end of the crumb trail: the crumb aimed at (the follow keeps 40 m)
DriveToVehicleTask.ATTACH_DISTANCE = 15        -- m: a crumb this close ahead, the follow starts at once (FollowVehicleTask rule)
DriveToVehicleTask.MIN_CRUMBS = 3
DriveToVehicleTask.WAIT_FIRST_MAX = 120000     -- ms waiting for the 1st to be in place before the old target is used anyway
DriveToVehicleTask.STRAIGHT_MAX = 60           -- m: straight line to the target when no route is found
DriveToVehicleTask.STRAIGHT_ANGLE = 60         -- deg: the target this far off the heading at most for a straight line
DriveToVehicleTask.STRAIGHT_SPEED = 10         -- km/h
DriveToVehicleTask.STRAIGHT_TIMEOUT = 60000
DriveToVehicleTask.LONG_ROUTE_RATIO = 3        -- a route longer than this times the straight distance ...
DriveToVehicleTask.LONG_ROUTE_MIN = 150        -- ... and longer than this is refused (wait, plan again)
DriveToVehicleTask.LONG_ROUTE_WAIT = 15000
DriveToVehicleTask.RETRY_WAIT = 4000           -- ms before the next plan after a failure (doubles up to RETRY_WAIT_MAX)
DriveToVehicleTask.RETRY_WAIT_MAX = 15000
DriveToVehicleTask.BAND_WAIT = 10000           -- ms waiting for the flood of the cut strips
DriveToVehicleTask.LOG_INTERVAL = 30000
DriveToVehicleTask.REPLAN_TARGET_MOVED = 40    -- m the 1st moved since the route was planned (no-crumb target): new route
DriveToVehicleTask.REPLAN_MIN_AGE = 15000      -- ms between two plans
DriveToVehicleTask.REPLAN_MIN_LEFT = 25        -- m left on the route to still plan again
DriveToVehicleTask.ARRIVALS_MAX = 3            -- arrivals without a crumb close by before waiting in place
DriveToVehicleTask.WAIT_HERE_CHECK = 5000

DriveToVehicleTask.STATE_WAIT_FOR_FIRST = 0
DriveToVehicleTask.STATE_BAND_WAIT = 3
DriveToVehicleTask.STATE_STRAIGHT = 4
DriveToVehicleTask.STATE_RETRY_WAIT = 5
DriveToVehicleTask.STATE_WAIT_HERE = 6

-- nom du véhicule pour les logs (même fonction locale dans chaque fichier DriveToVehicleTask*.lua)
local function logName(vehicle)
    return vehicle ~= nil and vehicle.getName ~= nil and tostring(vehicle:getName()) or "?"
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place (DriveToVehicleTask:setUp)
-- ------------------------------------------------------------------------------------------------------------
function DriveToVehicleTask:setUpFollowFirst()
    self.waitStart = g_time or 0
    if self:isFirstReady() then
        self:startPlanning(self.why)
    else
        self.state = DriveToVehicleTask.STATE_WAIT_FOR_FIRST
        self:logWaitFirst(true)
        self:parkInFieldFirst()
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- La 1re benne et ses miettes (the 1st unloader and its crumbs)
-- ------------------------------------------------------------------------------------------------------------
function DriveToVehicleTask:getFirstMode()
    local t = self.targetVehicle
    return t ~= nil and t.ad ~= nil and t.ad.modes ~= nil and t.ad.modes[AutoDrive.MODE_UNLOAD] or nil
end

function DriveToVehicleTask:getCrumbs()
    local mode = self:getFirstMode()
    local crumbs = mode ~= nil and mode.getBreadCrumbs ~= nil and mode:getBreadCrumbs() or nil
    return crumbs ~= nil and crumbs.items or nil
end

-- the 1st unloader is beside the harvester (active unloading) and has laid crumbs to follow
function DriveToVehicleTask:isFirstReady()
    local mode = self:getFirstMode()
    if mode == nil then
        return false
    end
    local items = self:getCrumbs()
    return mode.state == CombineUnloaderMode.STATE_ACTIVE_UNLOAD_COMBINE and items ~= nil and #items >= DriveToVehicleTask.MIN_CRUMBS
end

function DriveToVehicleTask:logWaitFirst(force)
    local now = g_time or 0
    if not force and self.lastLog ~= nil and now - self.lastLog < DriveToVehicleTask.LOG_INTERVAL then
        return
    end
    self.lastLog = now
    local mode = self:getFirstMode()
    local items = self:getCrumbs()
    print(string.format("[AD-Suivi] %s: %s : j'attends que %s soit en place a cote de l'ensileuse avant de partir (son etat %s, %d miettes, elle est a %.0f m, depuis %d s)",
        logName(self.vehicle), self.why, logName(self.targetVehicle), tostring(mode ~= nil and mode.getStateName ~= nil and mode:getStateName() or "?"),
        items ~= nil and #items or 0, AutoDrive.getDistanceBetween(self.vehicle, self.targetVehicle), math.floor((now - (self.waitStart or now)) / 1000)))
end

-- the nearest crumb ahead of the tractor (index, distance)
function DriveToVehicleTask:getNearestCrumbAhead()
    local items = self:getCrumbs()
    if items == nil then
        return nil, nil, 0
    end
    local vx, vy, vz = getWorldTranslation(self.vehicle.components[1].node)
    local nearest, nearestD = nil, math.huge
    for i, c in ipairs(items) do
        local _, _, lz = AutoDrive.worldToLocal(self.vehicle, c.x, c.y or vy, c.z)
        if lz > 1 then
            local d = MathUtil.vector2Length(c.x - vx, c.z - vz)
            if d < nearestD then
                nearest, nearestD = i, d
            end
        end
    end
    return nearest, nearestD, #items
end

-- target point, arrival vector, what it is, crumb index: the crumb CRUMB_FROM_END m before the end of the trail (or the
-- nearest one ahead when the tractor is already further along it); without crumbs, TARGET_DISTANCE m behind the 1st
function DriveToVehicleTask:chooseTarget()
    local items = self:getCrumbs()
    local nearest, nearestD = self:getNearestCrumbAhead()
    if items ~= nil and #items >= 2 and not (self.forceOldTarget and #items < DriveToVehicleTask.MIN_CRUMBS) then
        if nearest ~= nil and nearestD < DriveToVehicleTask.ATTACH_DISTANCE then
            return items[nearest], nil, "miette proche", nearest
        end
        local index = #items
        local dist = 0
        while index > 1 do
            local a, b = items[index - 1], items[index]
            dist = dist + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
            index = index - 1
            if dist >= DriveToVehicleTask.CRUMB_FROM_END then
                break
            end
        end
        if nearest ~= nil and nearest > index then
            index = nearest
        end
        local p = items[index]
        local q = items[index + 1]
        local dx, dz
        if q ~= nil then
            dx, dz = q.x - p.x, q.z - p.z
        else
            dx, dz = p.x - items[index - 1].x, p.z - items[index - 1].z
        end
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 0.1 then
            local rx, _, rz = AutoDrive.localDirectionToWorld(self.targetVehicle, 0, 0, 1)
            dx, dz, l = rx, rz, 1
        end
        return {x = p.x, y = p.y, z = p.z}, {x = dx / l, z = dz / l}, string.format("la miette %d/%d", index, #items), index
    end
    local tx, ty, tz = getWorldTranslation(self.targetVehicle.components[1].node)
    local rx, _, rz = AutoDrive.localDirectionToWorld(self.targetVehicle, 0, 0, 1)
    return {x = tx - DriveToVehicleTask.TARGET_DISTANCE * rx, y = ty, z = tz - DriveToVehicleTask.TARGET_DISTANCE * rz}, {x = rx, z = rz},
        string.format("%d m derriere", DriveToVehicleTask.TARGET_DISTANCE), nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Calcul du trajet (planning)
-- ------------------------------------------------------------------------------------------------------------
function DriveToVehicleTask:startPlanning(why)
    local target, vector, kind, index = self:chooseTarget()
    if target == nil then
        self:startRetryWait(DriveToVehicleTask.RETRY_WAIT, "pas de cible")
        return
    end
    local name, targetName = logName(self.vehicle), logName(self.targetVehicle)
    if kind == "miette proche" then
        local _, d = self:getNearestCrumbAhead()
        print(string.format("[AD-Suivi] %s: %s : une miette de %s a %.0f m devant moi, je la suis sans trajet", name, why, targetName, d or -1))
        self:startFollowing()
        return
    end
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    self.target = target
    self.targetKind = kind
    self.targetIsCrumb = index ~= nil
    local tx, _, tz = getWorldTranslation(self.targetVehicle.components[1].node)
    self.targetPos = {x = tx, z = tz, time = g_time or 0}
    self.straight = MathUtil.vector2Length(target.x - vx, target.z - vz)
    -- order (27/10 20:47): the 1st's track, the crop edge, the cut strips, the (fine) grid, a straight line
    if self:tryTrack(target, index, why) then
        return
    end
    local pfm = self.vehicle.ad.pathFinderModule
    pfm:reset()
    pfm:startPathPlanningToFollow(self.targetVehicle, target, vector)
    self.bandTried = false
    self.state = DriveToVehicleTask.STATE_PATHPLANNING
    print(string.format("[AD-Suivi] %s: %s : trajet vers %s de %s (%.0f m a vol d'oiseau, elle est a %.0f m)", name, why, kind, targetName, self.straight, AutoDrive.getDistanceBetween(self.vehicle, self.targetVehicle)))
end

-- ------------------------------------------------------------------------------------------------------------
-- Pas de trajet par la grille : bande coupée, ligne droite, nouvel essai
-- ------------------------------------------------------------------------------------------------------------
function DriveToVehicleTask:getRouteLength(wayPoints)
    local length = 0
    for i = 2, #wayPoints do
        length = length + MathUtil.vector2Length(wayPoints[i].x - wayPoints[i - 1].x, wayPoints[i].z - wayPoints[i - 1].z)
    end
    return length
end

function DriveToVehicleTask:startRetryWait(delay, why)
    self.state = DriveToVehicleTask.STATE_RETRY_WAIT
    self.retryTime = delay
    self.retryWhy = why
end

-- the 1st unloader moved on since the route was planned (no-crumb target): the route ends far behind it
function DriveToVehicleTask:targetMovedAway()
    if self.targetIsCrumb or self.targetPos == nil or self.targetVehicle == nil or self.targetVehicle.components == nil then
        return false
    end
    if (g_time or 0) - self.targetPos.time < DriveToVehicleTask.REPLAN_MIN_AGE then
        return false
    end
    local tx, _, tz = getWorldTranslation(self.targetVehicle.components[1].node)
    local moved = MathUtil.vector2Length(tx - self.targetPos.x, tz - self.targetPos.z)
    if moved < DriveToVehicleTask.REPLAN_TARGET_MOVED then
        return false
    end
    local left = self.vehicle.ad.drivePathModule.getDistanceToLastWaypoint ~= nil and self.vehicle.ad.drivePathModule:getDistanceToLastWaypoint(1000) or 0
    if left < DriveToVehicleTask.REPLAN_MIN_LEFT then
        return false
    end
    print(string.format("[AD-Suivi] %s: %s a bouge de %.0f m depuis mon calcul (encore %.0f m de trajet), nouveau trajet", logName(self.vehicle), logName(self.targetVehicle), moved, left))
    return true
end

-- no grid route: the cut strips (ADBandRoute flood, maybe still running), then a straight line, else wait and plan again
function DriveToVehicleTask:noRoute()
    local pfm = self.vehicle.ad.pathFinderModule
    if pfm.bandFlood == nil and ADBandRoute ~= nil and self.target ~= nil and pfm.getCropHalfWidth ~= nil then
        pfm.bandFlood = ADBandRoute.request(self.target.x, self.target.z, pfm:getCropHalfWidth())
    end
    if pfm.bandFlood ~= nil and not pfm.bandFlood.done then
        self.state = DriveToVehicleTask.STATE_BAND_WAIT
        self.bandWaitTime = 0
        return
    end
    self:tryBandOrStraight()
end

function DriveToVehicleTask:isStraightPossible()
    if self.target == nil or self.straight == nil or self.straight > DriveToVehicleTask.STRAIGHT_MAX then
        return false, string.format("%.0f m, trop loin", self.straight or -1)
    end
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local fx, _, fz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local angle = math.abs(AutoDrive.angleBetween({x = fx, z = fz}, {x = self.target.x - vx, z = self.target.z - vz}))
    if angle > DriveToVehicleTask.STRAIGHT_ANGLE then
        return false, string.format("cible a %.0f deg de mon cap", angle)
    end
    local firstMode = self:getFirstMode()
    local harvester = (firstMode ~= nil and firstMode.combine) or self.targetVehicle
    local clear, reason = FollowCombineTask.isChaseLineClear(self.vehicle, harvester, self.target, AutoDrive.CHASEPOS_REAR)
    if not clear then
        return false, tostring(reason)
    end
    return true
end

function DriveToVehicleTask:tryBandOrStraight()
    local pfm = self.vehicle.ad.pathFinderModule
    local name, targetName = logName(self.vehicle), logName(self.targetVehicle)
    local path, bandWhy = nil, "pas de bande"
    if self.bandTried then
        bandWhy = "deja essayee avant la grille"
    elseif pfm.getBandPath ~= nil then
        path, bandWhy = pfm:getBandPath()
    end
    if path ~= nil and #path >= 2 then
        print(string.format("[AD-Suivi] %s: pas de trajet par la grille, trajet dans la bande coupee vers %s de %s (%d points, %.0f m), en route",
            name, tostring(self.targetKind), targetName, #path, self:getRouteLength(path)))
        self.wayPoints = path
        self.vehicle.ad.drivePathModule:setWayPoints(path)
        self.state = DriveToVehicleTask.STATE_DRIVING
        self.failures = 0
        self.retryDelay = DriveToVehicleTask.RETRY_WAIT
        return
    end
    local straightOk, straightWhy = self:isStraightPossible()
    if straightOk then
        print(string.format("[AD-Suivi] %s: pas de trajet (grille, bande : %s), ligne droite libre vers %s de %s (%.0f m), j'y vais tout droit",
            name, tostring(bandWhy), tostring(self.targetKind), targetName, self.straight))
        self.state = DriveToVehicleTask.STATE_STRAIGHT
        self.straightTime = 0
        self.lineCheckTime = 0
        return
    end
    self.failures = self.failures + 1
    print(string.format("[AD-Suivi] %s: aucun trajet vers %s de %s (grille non, bande : %s, ligne droite : %s), essai %d, j'attends %.0f s et je recalcule (je reste sa suiveuse)",
        name, tostring(self.targetKind), targetName, tostring(bandWhy), tostring(straightWhy), self.failures, self.retryDelay / 1000))
    if self.failures >= DriveToVehicleTask.PARK_AFTER_FAILURES and not self.failParkTried then
        self.failParkTried = true
        if self:parkInFieldFirst(string.format("%d trajets sans issue vers %s", self.failures, targetName)) then
            return
        end
    end
    self:startRetryWait(self.retryDelay, "aucun trajet")
    self.retryDelay = math.min(self.retryDelay * 2, DriveToVehicleTask.RETRY_WAIT_MAX)
end

-- ------------------------------------------------------------------------------------------------------------
-- Arrivée (arrival)
-- ------------------------------------------------------------------------------------------------------------
function DriveToVehicleTask:startFollowing()
    self.vehicle.ad.taskModule:addTask(FollowVehicleTask:new(self.vehicle, self.targetVehicle))
    self.vehicle.ad.taskModule:setCurrentTaskFinished(ADTaskModule.DONT_PROPAGATE)
end

function DriveToVehicleTask:arrived(how)
    local name, targetName = logName(self.vehicle), logName(self.targetVehicle)
    local nearest, nearestD, crumbCount = self:getNearestCrumbAhead()
    if nearest ~= nil and nearestD < DriveToVehicleTask.ATTACH_DISTANCE then
        print(string.format("[AD-Suivi] %s: au bout du trajet (%s), les miettes de %s passent a %.0f m devant moi (%d miettes) : je la suis", name, how, targetName, nearestD, crumbCount))
        self:startFollowing()
        return
    end
    self.arrivals = self.arrivals + 1
    local tx, _, tz = getWorldTranslation(self.targetVehicle.components[1].node)
    self.arrivedFirstPos = {x = tx, z = tz}
    local where = nearest ~= nil and string.format("la plus proche devant a %.0f m", nearestD) or "aucune devant moi"
    if crumbCount >= 2 and self.arrivals < DriveToVehicleTask.ARRIVALS_MAX then
        print(string.format("[AD-Suivi] %s: au bout du trajet (%s), pas de miette de %s a moins de %d m devant moi (%d miettes, %s) : nouveau trajet vers ses miettes (%d/%d)",
            name, how, targetName, DriveToVehicleTask.ATTACH_DISTANCE, crumbCount, where, self.arrivals, DriveToVehicleTask.ARRIVALS_MAX))
        self:startPlanning("miettes pas atteintes")
        return
    end
    print(string.format("[AD-Suivi] %s: au bout du trajet (%s), pas de miette de %s a moins de %d m devant moi (%d miettes, %s) : j'attends ici, je reste sa suiveuse et je regarde toutes les %d s",
        name, how, targetName, DriveToVehicleTask.ATTACH_DISTANCE, crumbCount, where, DriveToVehicleTask.WAIT_HERE_CHECK / 1000))
    self.state = DriveToVehicleTask.STATE_WAIT_HERE
    self.waitHereTime = 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale : déroulé de la tâche (DriveToVehicleTask:update)
-- ------------------------------------------------------------------------------------------------------------
function DriveToVehicleTask:signalPromotion()
    self.promoted = true
end

function DriveToVehicleTask:stopHere(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
end

function DriveToVehicleTask:updateFollowFirst(dt)
    if self.targetVehicle == nil or self.targetVehicle.components == nil or g_currentMission.nodeToObject[self.targetVehicle.components[1].node] == nil then
        self:finished()
        return
    end
    if self.promoted then
        -- the 1st unloader left while this one was still on its way to it: straight to the harvester
        print(string.format("[AD-Suivi] %s: promue pendant mon trajet vers %s, je laisse ce trajet et je vais a l'ensileuse", logName(self.vehicle), logName(self.targetVehicle)))
        if self.state == DriveToVehicleTask.STATE_PATHPLANNING or self.state == DriveToVehicleTask.STATE_BAND_WAIT or self.state == DriveToVehicleTask.STATE_PARK_PLAN then
            self.vehicle.ad.pathFinderModule:reset()
        end
        self:leaveParkSpot()
        self.targetVehicle.ad.modes[AutoDrive.MODE_UNLOAD]:unregisterFollowingUnloader()
        self.vehicle.ad.taskModule:setCurrentTaskFinished()
        return
    end
    if self.state == DriveToVehicleTask.STATE_PARK_SEARCH or self.state == DriveToVehicleTask.STATE_PARK_PLAN or self.state == DriveToVehicleTask.STATE_PARK_DRIVE then
        self:updatePark(dt)
        return
    end
    -- 25/10 15:12: the harvester or the 1st comes toward this follower: it steps aside (StepAsideTask) and comes back
    if StepAsideTask ~= nil and StepAsideTask.hook(self.vehicle, self.targetVehicle, dt) then
        return
    end
    local state = self.state
    if state == DriveToVehicleTask.STATE_WAIT_FOR_FIRST then
        self:stopHere(dt)
        if self:isFirstReady() then
            self:leaveParkSpot()
            self:startPlanning(self.why .. ", la 1re est en place")
        elseif (g_time or 0) - (self.waitStart or 0) > DriveToVehicleTask.WAIT_FIRST_MAX then
            print(string.format("[AD-Suivi] %s: j'attends depuis %d s que %s soit en place, je pars quand meme vers %d m derriere elle",
                logName(self.vehicle), DriveToVehicleTask.WAIT_FIRST_MAX / 1000, logName(self.targetVehicle), DriveToVehicleTask.TARGET_DISTANCE))
            self.forceOldTarget = true
            self:leaveParkSpot()
            self:startPlanning("attente trop longue")
        else
            self:logWaitFirst(false)
        end
    elseif state == DriveToVehicleTask.STATE_PATHPLANNING then
        local pfm = self.vehicle.ad.pathFinderModule
        if pfm:hasFinished() then
            self.wayPoints = pfm:getPath()
            if self.wayPoints ~= nil and #self.wayPoints > 0 then
                local length = self:getRouteLength(self.wayPoints)
                if length > DriveToVehicleTask.LONG_ROUTE_MIN and length > DriveToVehicleTask.LONG_ROUTE_RATIO * (self.straight or 0) then
                    print(string.format("[AD-Suivi] %s: trajet trouve vers %s de %s mais bien trop long (%.0f m pour %.0f m a vol d'oiseau, %d points), refuse : j'attends %d s et je recalcule",
                        logName(self.vehicle), tostring(self.targetKind), logName(self.targetVehicle), length, self.straight or 0, #self.wayPoints, DriveToVehicleTask.LONG_ROUTE_WAIT / 1000))
                    self:startRetryWait(DriveToVehicleTask.LONG_ROUTE_WAIT, "trajet trop long")
                    return
                end
                print(string.format("[AD-Suivi] %s: trajet trouve vers %s de %s (%d points, %.0f m), en route", logName(self.vehicle), tostring(self.targetKind), logName(self.targetVehicle), #self.wayPoints, length))
                self.vehicle.ad.drivePathModule:setWayPoints(self.wayPoints)
                self.state = DriveToVehicleTask.STATE_DRIVING
                self.failures = 0
                self.retryDelay = DriveToVehicleTask.RETRY_WAIT
                return
            end
            self:noRoute()
        else
            pfm:update(dt)
            self:stopHere(dt)
            -- order: the cut strips before the grid (the grid waits for the same flood anyway)
            if not self.bandTried and pfm.bandFlood ~= nil and pfm.bandFlood.done and pfm.getBandPath ~= nil then
                self.bandTried = true
                local path, bandWhy = pfm:getBandPath()
                if path ~= nil and #path >= 2 then
                    print(string.format("[AD-Suivi] %s: trajet dans la bande coupee vers %s de %s avant la grille (%d points, %.0f m), en route",
                        logName(self.vehicle), tostring(self.targetKind), logName(self.targetVehicle), #path, self:getRouteLength(path)))
                    pfm:reset()
                    self.wayPoints = path
                    self.vehicle.ad.drivePathModule:setWayPoints(path)
                    self.state = DriveToVehicleTask.STATE_DRIVING
                    self.failures = 0
                    self.retryDelay = DriveToVehicleTask.RETRY_WAIT
                else
                    print(string.format("[AD-Suivi] %s: pas de trajet par la bande coupee vers %s de %s (%s), la grille continue",
                        logName(self.vehicle), tostring(self.targetKind), logName(self.targetVehicle), tostring(bandWhy)))
                end
            end
        end
    elseif state == DriveToVehicleTask.STATE_BAND_WAIT then
        self:stopHere(dt)
        self.bandWaitTime = (self.bandWaitTime or 0) + dt
        local flood = self.vehicle.ad.pathFinderModule.bandFlood
        local done = flood == nil or ADBandRoute.step(flood, ADBandRoute.BUDGET)
        if done or self.bandWaitTime > DriveToVehicleTask.BAND_WAIT then
            self:tryBandOrStraight()
        end
    elseif state == DriveToVehicleTask.STATE_DRIVING then
        if self.vehicle.ad.drivePathModule:isTargetReached() then
            self:arrived("trajet")
        elseif self:targetMovedAway() then
            self:startPlanning("la 1re a bouge")
        else
            self.vehicle.ad.drivePathModule:update(dt)
        end
    elseif state == DriveToVehicleTask.STATE_STRAIGHT then
        self.straightTime = (self.straightTime or 0) + dt
        local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
        local d = MathUtil.vector2Length(vx - self.target.x, vz - self.target.z)
        local _, _, lz = AutoDrive.worldToLocal(self.vehicle, self.target.x, self.target.y or 0, self.target.z)
        if d < 4 or lz < -1 or self.straightTime > DriveToVehicleTask.STRAIGHT_TIMEOUT then
            self:arrived("ligne droite")
            return
        end
        self.lineCheckTime = (self.lineCheckTime or 0) + dt
        if self.lineCheckTime > 1000 then
            self.lineCheckTime = 0
            local ok, why = self:isStraightPossible()
            if not ok then
                print(string.format("[AD-Suivi] %s: ligne droite vers %s de %s bloquee en route (%s), j'attends et je recalcule", logName(self.vehicle), tostring(self.targetKind), logName(self.targetVehicle), tostring(why)))
                self:startRetryWait(DriveToVehicleTask.RETRY_WAIT, "ligne droite bloquee")
                return
            end
        end
        self.vehicle.ad.specialDrivingModule:driveToPoint(dt, self.target, DriveToVehicleTask.STRAIGHT_SPEED, true, 1, DriveToVehicleTask.STRAIGHT_SPEED, true)
    elseif state == DriveToVehicleTask.STATE_RETRY_WAIT then
        self:stopHere(dt)
        self.retryTime = self.retryTime - dt
        if self.retryTime <= 0 then
            if self:isFirstReady() or self.forceOldTarget then
                self:startPlanning("nouvel essai apres " .. tostring(self.retryWhy))
            else
                self.state = DriveToVehicleTask.STATE_WAIT_FOR_FIRST
                self:logWaitFirst(true)
            end
        end
    elseif state == DriveToVehicleTask.STATE_WAIT_HERE then
        self:stopHere(dt)
        self.waitHereTime = (self.waitHereTime or 0) + dt
        if self.waitHereTime > DriveToVehicleTask.WAIT_HERE_CHECK then
            self.waitHereTime = 0
            local nearest, nearestD = self:getNearestCrumbAhead()
            if nearest ~= nil and nearestD < DriveToVehicleTask.ATTACH_DISTANCE then
                print(string.format("[AD-Suivi] %s: une miette de %s passe maintenant a %.0f m devant moi : je la suis", logName(self.vehicle), logName(self.targetVehicle), nearestD))
                self:startFollowing()
                return
            end
            local tx, _, tz = getWorldTranslation(self.targetVehicle.components[1].node)
            if self.arrivedFirstPos ~= nil and MathUtil.vector2Length(tx - self.arrivedFirstPos.x, tz - self.arrivedFirstPos.z) > DriveToVehicleTask.REPLAN_TARGET_MOVED then
                self.arrivals = 0
                self:startPlanning("la 1re a bouge pendant mon attente")
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin de la tâche (DriveToVehicleTask:abort)
-- ------------------------------------------------------------------------------------------------------------
function DriveToVehicleTask:abortFollowFirst()
    if self.state == DriveToVehicleTask.STATE_PATHPLANNING or self.state == DriveToVehicleTask.STATE_BAND_WAIT or self.state == DriveToVehicleTask.STATE_PARK_PLAN then
        self.vehicle.ad.pathFinderModule:reset()
    end
    self:leaveParkSpot()
end
