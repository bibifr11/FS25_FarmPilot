-- ============================================================================================================
-- FarmPilot : CatchCombinePipeTaskClear.lua
-- Complément de CatchCombinePipeTask (tâche AutoDrive d'origine) : se dégager, et que faire quand aucun trajet n'est
-- trouvé. Commun moissonneuse et ensileuse (les solutions propres à l'ensileuse, appelées d'ici, sont dans
-- CatchCombinePipeTaskHandover.lua, CatchCombinePipeTaskChopperRoute.lua et CatchCombinePipeTaskChopperUTurn.lua).
--
-- 1. Laisser passer la machine : en attente d'un trajet, une unité du train dans sa voie devant elle (CLEAR_WAY_DISTANCE m,
--    largeur de coupe + CLEAR_WAY_MARGIN) pendant qu'elle avance : recul (CLEAR_WAY_MAX_REVERSE m au plus, sol de champ
--    sans culture derrière), puis attente qu'elle soit passée (STATE_CLEAR_WAY, STATE_WAIT_PASS_BY).
-- 2. Aucun trajet trouvé : les solutions de repli dans l'ordre (ensileuse arrêtée : la poursuite prend la main ; rouler
--    sur sa trace ; étape de recul suivante ; demi-tour dans la bande ; reculer tout droit ; recul dans ses traces pour
--    ouvrir l'angle ; arrêt), sinon un nouveau calcul comme AutoDrive. Trajet trouvé : compteurs remis à zéro.
-- 3. Reculer tout droit pour se dégager (STATE_CLEAR_BACK) : deux échecs au même endroit, recul dans l'axe de la dernière
--    unité par étapes de CLEAR_BACK_STEP m (CLEAR_BACK_MAX en tout), un nouveau calcul après chaque étape ; jamais avec une
--    remorque articulée. Recul impossible ou épuisé : arrêt et journal (STATE_NO_WAY_WAIT) jusqu'à ce que la machine
--    bouge, plus de nouveau calcul toutes les 2 s.
--
-- Historique :
--   24/10       plusieurs solutions : derrière la machine sur sa trace, suivre la trace ;
--   25/10 11:53 derrière une ensileuse arrêtée (elle attend la benne), aucun trajet ne fait que tourner en rond ;
--   30/10       un tracteur sans chemin bouclait sans fin, il doit reculer pour se dégager et trouver une route
--               (MF 7S.210 le nez à 2 m de la haie) : reculer tout droit,
--               puis arrêt et journal ; dégagé de CLEAR_BACK_LIFT m ou plus, le demi-tour dans la bande peut être réessayé.
--
-- Règle : chaque solution rend vrai quand elle a pris la main ; la tâche s'arrête alors pour cette image.
-- Branché par : CatchCombinePipeTask:update (checkClearWay, updateClearWayStates et updateNoRouteStates avant la machine
-- à états ; tryNoRouteFallbacks et onRouteFound dans STATE_PATHPLANNING).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- États et réglages
-- ------------------------------------------------------------------------------------------------------------
-- waiting for a route while the harvester comes towards the unloader: get out of its way
CatchCombinePipeTask.STATE_CLEAR_WAY = {}
CatchCombinePipeTask.STATE_WAIT_PASS_BY = {}
CatchCombinePipeTask.STATE_CLEAR_BACK = {} -- no route: straight back along the trailer axis to get free (30/10)
CatchCombinePipeTask.STATE_NO_WAY_WAIT = {} -- no route and no reverse possible: stopped, waits for the harvester to move
CatchCombinePipeTask.CLEAR_WAY_DISTANCE = 40      -- m in front of the harvester watched
CatchCombinePipeTask.CLEAR_WAY_MARGIN = 2         -- m added on each side of the cutting width
CatchCombinePipeTask.CLEAR_WAY_MIN_SPEED = 0.0005 -- harvester speed (lastSpeedReal) counted as driving forward
CatchCombinePipeTask.CLEAR_WAY_MAX_REVERSE = 20   -- m
CatchCombinePipeTask.CLEAR_WAY_REVERSE_SPEED = 6  -- km/h
CatchCombinePipeTask.CLEAR_WAY_TIMEOUT = 25000    -- ms
CatchCombinePipeTask.CLEAR_WAY_STUCK_TIME = 3000  -- ms without moving while reversing
CatchCombinePipeTask.CLEAR_WAY_REAR_CHECK = 3     -- m behind the last unit that must be field ground without crop
CatchCombinePipeTask.PASS_BY_TIMEOUT = 30000      -- ms
CatchCombinePipeTask.PASS_BY_BEHIND = 5           -- m: the unloader is behind the harvester, it has passed
-- 30/10 (a tractor with no route looped non-stop, it must back off to get free and find a route):
-- MF 7S.210 nose 2 m from the hedge, the band turn failed ("S bloque")
-- and was banned 120 s, a new plan every 2-10 s for minutes. No route twice from the same place: straight back along
-- the trailer axis by CLEAR_BACK_STEP legs, a new plan after each leg (stops as soon as a route forward is found),
-- CLEAR_BACK_MAX in all. Never with an articulated trailer. Reversing impossible or used up: stop and log, no loop
CatchCombinePipeTask.CLEAR_BACK_FAILS = 2         -- failed plans from the same place before backing off
CatchCombinePipeTask.CLEAR_BACK_SAME_PLACE = 1    -- m: closer than this the failures count as the same place
CatchCombinePipeTask.CLEAR_BACK_STEP = 5          -- m per leg, a new plan after each one
CatchCombinePipeTask.CLEAR_BACK_MAX = 20          -- m in all
CatchCombinePipeTask.CLEAR_BACK_LIFT = 5          -- m backed off: the band turn ban of that place is lifted
CatchCombinePipeTask.CLEAR_BACK_SPEED = 5         -- km/h
CatchCombinePipeTask.CLEAR_BACK_REAR_CHECK = 3    -- m behind the last unit (its own heading): field, no crop
CatchCombinePipeTask.CLEAR_BACK_STUCK_TIME = 3000 -- ms without moving (obstacle sensor holds it): stop
CatchCombinePipeTask.CLEAR_BACK_LEG_TIMEOUT = 20000 -- ms per leg
CatchCombinePipeTask.CLEAR_BACK_MEMORY = 120000   -- ms the failures and the back-off of a place are remembered
CatchCombinePipeTask.NO_WAY_WAIT = 60000          -- ms stopped before planning again when nothing moves
CatchCombinePipeTask.NO_WAY_COMBINE_MOVE = 5      -- m moved by the harvester: plan again at once

-- ------------------------------------------------------------------------------------------------------------
-- Accroches (appelées par CatchCombinePipeTask:update)
-- ------------------------------------------------------------------------------------------------------------
-- avant la machine à états ; vrai = update() s'arrête là
function CatchCombinePipeTask:checkClearWay()
    if (self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.state == CatchCombinePipeTask.STATE_DELAY_PATHPLANNING)
        and self:isInCombinePath() then
        self:startClearWay()
        return true
    end
    return false
end

-- avant la machine à états ; vrai = update() s'arrête là
function CatchCombinePipeTask:updateClearWayStates(dt)
    if self.state == CatchCombinePipeTask.STATE_CLEAR_WAY then
        self:updateClearWay(dt)
        return true
    elseif self.state == CatchCombinePipeTask.STATE_WAIT_PASS_BY then
        self:updateWaitPassBy(dt)
        return true
    end
    return false
end

-- avant la machine à états (états retirés de celle-ci) ; vrai = update() s'arrête là
function CatchCombinePipeTask:updateNoRouteStates(dt)
    if self.state == CatchCombinePipeTask.STATE_CLEAR_BACK then
        self:updateClearBack(dt)
        return true
    elseif self.state == CatchCombinePipeTask.STATE_NO_WAY_WAIT then
        self:updateNoWayWait(dt)
        return true
    end
    return false
end

-- STATE_PATHPLANNING, aucun trajet (après notifyAboutFailedPathfinder) ; vrai = update() s'arrête là, sinon nouveau
-- calcul après une attente, comme AutoDrive
function CatchCombinePipeTask:tryNoRouteFallbacks()
    self.infoNoPath = true -- status text only
    self:updateRetryDelay()
    local noRoute = self:countNoRoute()
    -- 25/10 11:53: behind a standing harvester (it waits for this unloader) no planned route loops for ever
    if self:tryStandingHandover("aucun trajet") then
        return true
    end
    -- 24/10 (several ways out): behind the harvester on its own trail, drive that trail
    if self:tryCombineTrail() then
        return true
    end
    -- 30/10: backing off to get free, still no route after a leg: next leg at once
    if self:continueClearBack() then
        return true
    end
    -- fallback: no forward route and the harvester heading is behind, U-turn in the strip
    if self:tryBandTurn("aucun chemin en marche avant") then
        return true
    end
    -- 30/10: no route twice from here, straight back to get free
    if self:tryClearBack(noRoute) then
        return true
    end
    if self:tryOpenReverse() then
        return true
    end
    -- 30/10: no route, reversing impossible or used up: stop and say it, no new plan every 2 s
    if self:tryNoWayWait(noRoute) then
        return true
    end
    return false
end

-- STATE_PATHPLANNING, trajet trouvé et gardé (avant setWayPoints)
function CatchCombinePipeTask:onRouteFound()
    self.lastFailure = nil
    self.infoNoPath = false
    self.retryDelay = CatchCombinePipeTask.RETRY_DELAY_MIN
    self:noteRouteFound()
    self.routeIsPartial = self.vehicle.ad.pathFinderModule.partialPath == true
    self.preplanning = false
end

-- ------------------------------------------------------------------------------------------------------------
-- Laisser passer la machine
-- ------------------------------------------------------------------------------------------------------------
-- tractor and towed units of the unloader
function CatchCombinePipeTask:getTrainUnits()
    local units = {self.vehicle}
    local all = AutoDrive.getAllUnits(self.vehicle)
    if all ~= nil then
        for _, unit in ipairs(all) do
            if unit ~= self.vehicle and unit.components ~= nil then
                table.insert(units, unit)
            end
        end
    end
    return units
end

-- the harvester drives forward and a unit of the unloader stands in its way: in front of it, within its cutting width
function CatchCombinePipeTask:isInCombinePath()
    local combine = self.combine
    if combine == nil or combine.ad == nil or combine.ad.ADRootNode == nil then
        return false
    end
    local movingDirection = combine.movingDirection or 1
    if combine.ad.isReverseAttached then
        movingDirection = -movingDirection
    end
    if (combine.lastSpeedReal or 0) * movingDirection < CatchCombinePipeTask.CLEAR_WAY_MIN_SPEED then
        return false
    end
    local laneHalf = math.max(AutoDrive.getFrontToolWidth(combine) or 0, combine.size.width) / 2 + CatchCombinePipeTask.CLEAR_WAY_MARGIN
    for _, unit in ipairs(self:getTrainUnits()) do
        local x, y, z = getWorldTranslation(unit.components[1].node)
        local diffX, _, diffZ = AutoDrive.worldToLocal(combine, x, y, z, combine.ad.ADRootNode)
        local unitHalfWidth = unit.size ~= nil and unit.size.width / 2 or 1.5
        if diffZ > 0 and diffZ < CatchCombinePipeTask.CLEAR_WAY_DISTANCE and math.abs(diffX) < laneHalf + unitHalfWidth then
            return true
        end
    end
    return false
end

-- ground behind the last unit: field ground without standing crop, across the width of the train
function CatchCombinePipeTask:isRearClear()
    local units = self:getTrainUnits()
    local last = units[#units]
    local dx, _, dz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    local x, _, z = getWorldTranslation(last.components[1].node)
    local back = (last.size ~= nil and last.size.length / 2 or 3) + CatchCombinePipeTask.CLEAR_WAY_REAR_CHECK
    local half = self.vehicle.ad.pathFinderModule:getTrainWidth() / 2
    local rx, rz = x - dx * back, z - dz * back
    for _, side in ipairs({0, -1, 1}) do
        local px, pz = rx - dz * half * side, rz + dx * half * side
        if not AutoDrive.checkIsOnField(px, 0, pz) or PathFinderModule.getMapCropAt(px, pz) ~= 0 then
            return false
        end
    end
    return true
end

function CatchCombinePipeTask:startClearWay()
    if self.state == CatchCombinePipeTask.STATE_PATHPLANNING then
        self.vehicle.ad.pathFinderModule:reset()
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    self.clearWayStart = {x = x, z = z}
    self.clearWayTime = 0
    self.clearWayStuckTime = 0
    self.clearWayLast = {x = x, z = z}
    if self:isRearClear() then
        print(string.format("[AD-Degage] %s: la moissonneuse arrive vers moi, je recule pour degager son passage", FollowCombineTask.getLogName(self.vehicle)))
        self.state = CatchCombinePipeTask.STATE_CLEAR_WAY
    else
        print(string.format("[AD-Degage] %s: la moissonneuse arrive vers moi, recul impossible (culture ou bord du champ derriere), j'attends", FollowCombineTask.getLogName(self.vehicle)))
        self.passByTime = 0
        self.state = CatchCombinePipeTask.STATE_WAIT_PASS_BY
    end
end

function CatchCombinePipeTask:updateClearWay(dt)
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local reversed = MathUtil.vector2Length(x - self.clearWayStart.x, z - self.clearWayStart.z)
    self.clearWayTime = self.clearWayTime + dt
    if MathUtil.vector2Length(x - self.clearWayLast.x, z - self.clearWayLast.z) > 0.3 then
        self.clearWayLast = {x = x, z = z}
        self.clearWayStuckTime = 0
    else
        self.clearWayStuckTime = self.clearWayStuckTime + dt
    end
    local reason = nil
    if not self:isInCombinePath() then
        reason = "hors du passage"
    elseif reversed >= CatchCombinePipeTask.CLEAR_WAY_MAX_REVERSE then
        reason = "recul maximum"
    elseif not self:isRearClear() then
        reason = "culture ou bord du champ derriere"
    elseif self.clearWayTime > CatchCombinePipeTask.CLEAR_WAY_TIMEOUT or self.clearWayStuckTime > CatchCombinePipeTask.CLEAR_WAY_STUCK_TIME then
        reason = "recul bloque"
    end
    if reason ~= nil then
        print(string.format("[AD-Degage] %s: arret du recul apres %.0f m (%s), j'attends que la moissonneuse passe", FollowCombineTask.getLogName(self.vehicle), reversed, reason))
        self.passByTime = 0
        self.state = CatchCombinePipeTask.STATE_WAIT_PASS_BY
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return
    end
    self.vehicle.ad.specialDrivingModule:driveReverse(dt, CatchCombinePipeTask.CLEAR_WAY_REVERSE_SPEED, 1, self.vehicle.ad.trailerModule:canBeHandledInReverse())
end

function CatchCombinePipeTask:updateWaitPassBy(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    self.passByTime = self.passByTime + dt
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local _, _, diffZ = AutoDrive.worldToLocal(self.combine, x, y, z, self.combine.ad.ADRootNode)
    local passed = diffZ < -CatchCombinePipeTask.PASS_BY_BEHIND
    if passed or (not self:isInCombinePath() and self.passByTime > 2000) or self.passByTime > CatchCombinePipeTask.PASS_BY_TIMEOUT then
        print(string.format("[AD-Degage] %s: %s, nouvelle recherche de chemin", FollowCombineTask.getLogName(self.vehicle),
            passed and "la moissonneuse est passee" or (self.passByTime > CatchCombinePipeTask.PASS_BY_TIMEOUT and "attente trop longue" or "plus dans son passage")))
        self.waitForCheckTimer.elapsedTime = 4000
        self.state = CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Aucun trajet au même endroit : compter, reculer tout droit, s'arrêter
-- ------------------------------------------------------------------------------------------------------------
-- failed plans from the same place, remembered on the vehicle (the task is created again after each hand-back)
function CatchCombinePipeTask:countNoRoute()
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local now = g_time or 0
    local f = self.vehicle.ad.noRoute
    if f == nil or MathUtil.vector2Length(vx - f.x, vz - f.z) > CatchCombinePipeTask.CLEAR_BACK_SAME_PLACE or now - f.t > CatchCombinePipeTask.CLEAR_BACK_MEMORY then
        f = {x = vx, z = vz, count = 0}
        self.vehicle.ad.noRoute = f
    end
    f.count = f.count + 1
    f.t = now
    return f
end

function CatchCombinePipeTask:noteRouteFound()
    local cb = self.vehicle.ad.clearBack
    if cb ~= nil and cb.total > 0 and not cb.reported then
        cb.reported = true
        print(string.format("[AD-Fin] %s: degagement : trajet trouve apres %.0f m de recul", tostring(self.vehicle:getName()), cb.total))
    end
    if cb ~= nil and not cb.over then
        -- a route: the back-off of this place is finished (a later failure elsewhere starts from 2 failures again)
        self.vehicle.ad.clearBack = nil
    end
    self.vehicle.ad.noRoute = nil
end

-- the back-off of the last places (nil when forgotten)
function CatchCombinePipeTask:getClearBack()
    local cb = self.vehicle.ad.clearBack
    if cb ~= nil and (g_time or 0) - cb.t > CatchCombinePipeTask.CLEAR_BACK_MEMORY then
        self.vehicle.ad.clearBack = nil
        return nil
    end
    return cb
end

-- the train and its last unit; heading of the last unit (its own axis)
function CatchCombinePipeTask:getClearBackRear()
    local units = self:getTrainUnits()
    local last = units[#units]
    local dx, _, dz = AutoDrive.localDirectionToWorld(last, 0, 0, 1)
    local x, y, z = getWorldTranslation(last.components[1].node)
    return last, x, y, z, dx, dz
end

-- why the train cannot back off from here, nil if it can
function CatchCombinePipeTask:getClearBackBlock()
    if ADTrafficYieldModule ~= nil and ADTrafficYieldModule.cannotReverse ~= nil then
        local articulated = ADTrafficYieldModule.cannotReverse(self.vehicle)
        if articulated then
            return "remorque articulee : " .. tostring(ADTrafficYieldModule.describeArticulated(self.vehicle))
        end
    end
    local last, x, _, z, dx, dz = self:getClearBackRear()
    local back = (last.size ~= nil and last.size.length / 2 or 3) + CatchCombinePipeTask.CLEAR_BACK_REAR_CHECK
    local half = self.vehicle.ad.pathFinderModule:getTrainWidth() / 2
    local rx, rz = x - dx * back, z - dz * back
    for _, side in ipairs({0, -1, 1}) do
        local px, pz = rx - dz * half * side, rz + dx * half * side
        if not AutoDrive.checkIsOnField(px, 0, pz) then
            return string.format("bord du champ a %d m derriere la remorque", CatchCombinePipeTask.CLEAR_BACK_REAR_CHECK)
        end
        if PathFinderModule.getMapCropAt(px, pz) ~= 0 then
            return string.format("culture a %d m derriere la remorque", CatchCombinePipeTask.CLEAR_BACK_REAR_CHECK)
        end
    end
    local cdm = self.vehicle.ad.collisionDetectionModule
    if cdm ~= nil and cdm.checkReverseCollision ~= nil and cdm:checkReverseCollision() then
        return "obstacle derriere (capteur)"
    end
    return nil
end

-- starts one leg: target far behind on the axis of the last unit
function CatchCombinePipeTask:startClearBackLeg(cb)
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local _, lx, ly, lz, dx, dz = self:getClearBackRear()
    cb.t = g_time or 0
    self.clearBackStart = {x = x, z = z}
    self.clearBackLast = {x = x, z = z}
    self.clearBackTime = 0
    self.clearBackStuck = 0
    self.clearBackLeg = 0
    self.clearBackTarget = {x = lx - dx * 100, y = ly, z = lz - dz * 100}
    if self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.preplanning then
        self.vehicle.ad.pathFinderModule:reset()
        self.preplanning = false
    end
    self.state = CatchCombinePipeTask.STATE_CLEAR_BACK
end

-- no route twice from the same place: first leg of the back-off
function CatchCombinePipeTask:tryClearBack(noRoute)
    if noRoute == nil or noRoute.count < CatchCombinePipeTask.CLEAR_BACK_FAILS then
        return false
    end
    local cb = self:getClearBack()
    if cb ~= nil then
        -- already backed off from here (used up or stopped): the other fallbacks, then the stop
        return false
    end
    local name = tostring(self.vehicle:getName())
    local why = self:getClearBackBlock()
    if why ~= nil then
        self.vehicle.ad.clearBack = {total = 0, t = g_time or 0, over = true, why = why}
        print(string.format("[AD-Fin] %s: pas de trajet d'ici %d fois, recul de degagement impossible (%s)", name, noRoute.count, why))
        return false
    end
    cb = {total = 0, t = g_time or 0, over = false}
    self.vehicle.ad.clearBack = cb
    print(string.format("[AD-Fin] %s: pas de trajet d'ici %d fois, je recule tout droit dans l'axe de la remorque pour me degager (%d m par %d m, %d m au plus, nouveau calcul apres chaque pas)",
        name, noRoute.count, CatchCombinePipeTask.CLEAR_BACK_STEP, CatchCombinePipeTask.CLEAR_BACK_STEP, CatchCombinePipeTask.CLEAR_BACK_MAX))
    self:startClearBackLeg(cb)
    return true
end

-- back-off going on and still no route after a leg: next leg at once
function CatchCombinePipeTask:continueClearBack()
    local cb = self:getClearBack()
    if cb == nil or cb.over then
        return false
    end
    local why = self:getClearBackBlock()
    if why ~= nil then
        cb.over, cb.why = true, why
        print(string.format("[AD-Fin] %s: toujours pas de trajet apres %.0f m de recul, recul arrete (%s)", tostring(self.vehicle:getName()), cb.total, why))
        return false
    end
    print(string.format("[AD-Fin] %s: toujours pas de trajet apres %.0f m de recul, je recule encore", tostring(self.vehicle:getName()), cb.total))
    self:startClearBackLeg(cb)
    return true
end

function CatchCombinePipeTask:updateClearBack(dt)
    local cb = self:getClearBack() or {total = 0, t = g_time or 0, over = true}
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local leg = MathUtil.vector2Length(x - self.clearBackStart.x, z - self.clearBackStart.z)
    self.clearBackLeg = leg
    self.clearBackTime = self.clearBackTime + dt
    if MathUtil.vector2Length(x - self.clearBackLast.x, z - self.clearBackLast.z) > 0.3 then
        self.clearBackLast = {x = x, z = z}
        self.clearBackStuck = 0
    else
        self.clearBackStuck = self.clearBackStuck + dt
    end
    local total = cb.total + leg
    local reason, over = nil, false
    if total >= CatchCombinePipeTask.CLEAR_BACK_MAX - 0.05 then
        reason, over = string.format("%d m recules, maximum", CatchCombinePipeTask.CLEAR_BACK_MAX), true
    elseif leg >= CatchCombinePipeTask.CLEAR_BACK_STEP - 0.05 then
        reason = string.format("pas de %d m fait", CatchCombinePipeTask.CLEAR_BACK_STEP)
    else
        local block = self:getClearBackBlock()
        if block ~= nil then
            reason, over = block, true
        elseif self.clearBackStuck > CatchCombinePipeTask.CLEAR_BACK_STUCK_TIME then
            reason, over = "ne recule plus (obstacle derriere ?)", true
        elseif self.clearBackTime > CatchCombinePipeTask.CLEAR_BACK_LEG_TIMEOUT then
            reason, over = "recul trop long", true
        end
    end
    if reason == nil then
        local sdm = self.vehicle.ad.specialDrivingModule
        sdm.reverseTarget = self.clearBackTarget
        sdm:driveReverse(dt, CatchCombinePipeTask.CLEAR_BACK_SPEED, 1, self.vehicle.ad.trailerModule:canBeHandledInReverse())
        return
    end
    cb.total = total
    cb.t = g_time or 0
    cb.over = over
    if over then
        cb.why = reason
    end
    self.clearBackLeg = 0
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    local name = tostring(self.vehicle:getName())
    print(string.format("[AD-Fin] %s: recul de degagement %.1f m (%.1f m en tout) : %s, nouveau calcul", name, leg, total, reason))
    -- 30/10: freed by CLEAR_BACK_LIFT or more, the band turn may be tried again at once
    if total >= CatchCombinePipeTask.CLEAR_BACK_LIFT - 0.05 and self.vehicle.ad.bandTurnFailed ~= nil then
        self.vehicle.ad.bandTurnFailed = nil
        print(string.format("[AD-DemiTour] %s: degage de %.0f m, interdiction du demi-tour de secours levee", name, total))
    end
    self.retryDelay = CatchCombinePipeTask.RETRY_DELAY_MIN
    self.lastFailure = nil
    self.waitForCheckTimer.elapsedTime = 4000
    self.state = CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
end

-- no route again from the same place and the back-off impossible or used up: stopped until the harvester moves
function CatchCombinePipeTask:tryNoWayWait(noRoute)
    local cb = self:getClearBack()
    if noRoute == nil or noRoute.count < CatchCombinePipeTask.CLEAR_BACK_FAILS or cb == nil or not cb.over then
        return false
    end
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    self.noWayWait = {cx = cx, cz = cz, time = 0}
    cb.t = g_time or 0
    print(string.format("[AD-Fin] %s: BLOQUE : pas de trajet d'ici (%d fois) et recul de degagement %s (%.0f m recules : %s). Je m'arrete et j'attends que l'ensileuse bouge (%d s au plus) au lieu de recalculer en boucle",
        tostring(self.vehicle:getName()), noRoute.count, cb.total > 0 and "fini" or "impossible", cb.total, tostring(cb.why), CatchCombinePipeTask.NO_WAY_WAIT / 1000))
    if self.state == CatchCombinePipeTask.STATE_PATHPLANNING or self.preplanning then
        self.vehicle.ad.pathFinderModule:reset()
        self.preplanning = false
    end
    self:warnStuckInCrop(noRoute) -- benne bloquee dans la culture : message au joueur (FollowCombineCropGuard.lua)
    self.state = CatchCombinePipeTask.STATE_NO_WAY_WAIT
    return true
end

function CatchCombinePipeTask:updateNoWayWait(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    local w = self.noWayWait
    w.time = w.time + dt
    local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
    local moved = MathUtil.vector2Length(cx - w.cx, cz - w.cz)
    if moved >= CatchCombinePipeTask.NO_WAY_COMBINE_MOVE or w.time >= CatchCombinePipeTask.NO_WAY_WAIT then
        print(string.format("[AD-Fin] %s: fin de l'arret (%s), nouveau calcul", tostring(self.vehicle:getName()),
            moved >= CatchCombinePipeTask.NO_WAY_COMBINE_MOVE and string.format("l'ensileuse a bouge de %.0f m", moved) or string.format("%d s passees", CatchCombinePipeTask.NO_WAY_WAIT / 1000)))
        local cb = self:getClearBack()
        if cb ~= nil then
            cb.t = g_time or 0
        end
        self.retryDelay = CatchCombinePipeTask.RETRY_DELAY_MIN
        self.lastFailure = nil
        self.waitForCheckTimer.elapsedTime = 4000
        self.state = CatchCombinePipeTask.STATE_DELAY_PATHPLANNING
    end
end
