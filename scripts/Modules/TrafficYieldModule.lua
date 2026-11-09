-- ============================================================================================================
-- FarmPilot : TrafficYieldModule.lua
-- Croisement face à face de deux véhicules AutoDrive sur une route à double sens : fichier principal (table du
-- module, états du plan, réglages communs, point d'entrée, fin du plan, texte d'état).
--
-- Situation : deux véhicules AD se rencontrent face à face sur une route à double sens. Chacun voit l'autre avec ses
-- capteurs de collision et tous deux restent arrêtés pour toujours (detectAdTrafficOnRoute() n'est pas appelé sur une
-- route à double sens).
--
-- Règle (manœuvre classique) :
-- 1. Quand les deux véhicules sont bloqués depuis <trafficYieldDelay> secondes, un plan commun est créé.
-- 2. Les rôles sont choisis de façon déterministe (même résultat quel que soit le véhicule qui détecte en premier) :
--    - REVERSER (celui qui recule) : le véhicule le plus facile à faire reculer (vide d'abord, puis sans remorque, puis
--      le plus petit id). Il recule le long de son propre trajet pour faire de la place.
--    - PARKER (celui qui se gare) : l'autre. Il cherche une place libre au bord de la route (côté droit d'abord, puis
--      gauche), s'y range et attend.
-- 3. Une fois le PARKER garé, le REVERSER repart et passe. Quand il est passé, le PARKER revient sur son trajet.
-- Tout tourne sur le serveur (AutoDrive:onUpdate est côté serveur) : sans souci en multijoueur.
-- Depuis le 28/10 : recule celui qui manœuvre le moins (pickReverser), seulement du côté de conduite (getSides), et
-- un véhicule en face est vu de loin sur les trajets : l'un des deux se range ou attend d'avance (mode "early").
--
-- Fichiers du module, découpé par sujet le 09/11 (register.lua les charge juste après celui-ci) :
--   TrafficYieldModuleTrain.lua         attelage : dimensions, attelage articulé, rayon de braquage, recul à faire ;
--   TrafficYieldModuleRoute.lua         lecture des trajets (distances, polyligne) et du réseau à double sens ;
--   TrafficYieldModuleAnticipation.lua  comparaison des trajets, véhicule en face vu de loin, files, ralentir ;
--   TrafficYieldModuleDeadlock.lua      arrêtés nez à nez : détection, plan classique, 3e véhicule ;
--   TrafficYieldModuleEarlyPlan.lua     situation face au chemin à double sens et choix du plan d'avance ;
--   TrafficYieldModuleApproach.lua      conduite des deux véhicules pendant le plan d'avance ;
--   TrafficYieldModuleSingleTrack.lua   attente avant le chemin à double sens, recul hors de son entrée, dégagement ;
--   TrafficYieldModuleDetour.lua        autre chemin pour éviter le face à face, tout droit à l'embranchement ;
--   TrafficYieldModuleSpot.lua          place au bord de la route le long du trajet (trajet parallèle, remorque) ;
--   TrafficYieldModuleObstacles.lua     terrain et obstacles d'une place (hauteur, pente, eau, champ, objets) ;
--   TrafficYieldModuleReverser.lua      le véhicule qui recule (REVERSER) ;
--   TrafficYieldModuleParker.lua        le véhicule qui se gare (PARKER) et son retour sur le trajet.
-- État partagé entre véhicules (modifié pendant le jeu) : des champs de la table, une seule fois chacun :
-- ADTrafficYieldModule.pairHistory (ce fichier) et ADTrafficYieldModule.routeCache (Anticipation).
--
-- Branché par : Specialization.lua (ADTrafficYieldModule:new, vehicle.ad.trafficYieldModule),
-- DrivePathModuleObstacles.lua (handle à chaque image, côté serveur, dans ADDrivePathModule:handleDrivingModules),
-- TaskModule.lua (getWaitInfo, texte du HUD). L'état du module et ses outils (getPosition, getTrainExtents, getWidth,
-- overlapHit, reverseTowards, resyncWayPoints…) servent aussi à FieldParkModule, AvoidModule, IntersectionModule,
-- ApproachModule, ObstacleDetourModule, DrivePathModuleStuck, BandTurnModule, PathFinderModulePark/Guided,
-- WaitForCallTask*, DriveToDestinationTaskArrival, CatchCombinePipeTaskClear, FollowCombineTaskChopperUTurn et
-- HandleHarvesterTurnTaskHarvesterWay.
-- ============================================================================================================

ADTrafficYieldModule = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages : journal
-- ------------------------------------------------------------------------------------------------------------
ADTrafficYieldModule.DEBUG = true -- temporary diagnostic logs for the tests

-- ------------------------------------------------------------------------------------------------------------
-- États du plan
-- ------------------------------------------------------------------------------------------------------------
ADTrafficYieldModule.STATE_IDLE = 0
ADTrafficYieldModule.STATE_REVERSER_RETREAT = 1
ADTrafficYieldModule.STATE_REVERSER_WAIT = 2
ADTrafficYieldModule.STATE_REVERSER_PASS = 3
ADTrafficYieldModule.STATE_REVERSER_BRANCH = 4
ADTrafficYieldModule.STATE_REVERSER_HIDE = 5
ADTrafficYieldModule.STATE_PARKER_SEARCH = 11
ADTrafficYieldModule.STATE_PARKER_MOVE = 12
ADTrafficYieldModule.STATE_PARKER_WAIT = 13
ADTrafficYieldModule.STATE_PARKER_PASS = 14
ADTrafficYieldModule.STATE_YIELDER_APPROACH = 21
ADTrafficYieldModule.STATE_PRIORITY_APPROACH = 22
ADTrafficYieldModule.STATE_WAIT_DETACHED = 31
-- gap between two vehicles of the same oncoming queue (rear of one to the front of the next)
ADTrafficYieldModule.QUEUE_GAP = 40
ADTrafficYieldModule.STATE_SECTION_CLEAR = 41

ADTrafficYieldModule.STATE_NAMES = {
    [0] = "IDLE",
    [1] = "REVERSER_RETREAT",
    [2] = "REVERSER_WAIT",
    [3] = "REVERSER_PASS",
    [4] = "REVERSER_BRANCH",
    [5] = "REVERSER_HIDE",
    [11] = "PARKER_SEARCH",
    [12] = "PARKER_MOVE",
    [13] = "PARKER_WAIT",
    [14] = "PARKER_PASS",
    [21] = "YIELDER_APPROACH",
    [22] = "PRIORITY_APPROACH",
    [31] = "WAIT_DETACHED",
    [41] = "SECTION_CLEAR"
}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages communs
-- ------------------------------------------------------------------------------------------------------------
ADTrafficYieldModule.ANTICIPATION_DISTANCE = 250 -- m of route looked ahead to find an oncoming AD vehicle
ADTrafficYieldModule.ANTICIPATION_INTERVAL = 250 -- ms between two route comparisons
ADTrafficYieldModule.ANTICIPATION_DECEL = 1.2    -- m/s2 comfortable deceleration used to compute the speed limit
ADTrafficYieldModule.ANTICIPATION_GAP = 10       -- m free between both fronts when stopped
ADTrafficYieldModule.ANTICIPATION_START_DELAY = 1500 -- ms both stopped before the manoeuvre starts
ADTrafficYieldModule.PLAN_TIMEOUT = 180000      -- ms, whole manoeuvre
ADTrafficYieldModule.COOLDOWN = 20000           -- ms, no new detection after a plan ended
ADTrafficYieldModule.PATH_STEP = 2               -- m between two points of the parallel path
ADTrafficYieldModule.PATH_EXTRA = 8              -- m of parallel path after the parking point (alignment, aim)
ADTrafficYieldModule.CANDIDATE_STEP = 5          -- m between two leaving points tested along the route
ADTrafficYieldModule.SECTION_WAIT_CLEAR = 15     -- m kept free before the start of a single track when the yielder waits there (25/10)
ADTrafficYieldModule.SECTION_BACKOFF_MAX = 50    -- m, longest reverse of a yielder already in the mouth of the single track (25/10)
ADTrafficYieldModule.JUNCTION_GAP = 5           -- m between my front and the node where my route leaves the road, when I wait before the turn-off (26/10)
--[==[ Mis de côté (09/11) : inutilisé
ADTrafficYieldModule.SECTION_BACKOFF_MIN = 6     -- m, a back-off stopped before (vehicle queue behind) falls back to the standard manoeuvre
]==]
ADTrafficYieldModule.SECTION_CLEAR_MAX = 150     -- m, longest reverse of the vehicle in the single track that gives way to one stuck in the mouth
ADTrafficYieldModule.SECTION_BACKOFF_INSIDE = 8  -- m, front already this far inside the single track: too deep, no back-off
ADTrafficYieldModule.YIELDER_STOPPED_FALLBACK = 10000 -- ms stopped without a spot nor a hold of its own: standard manoeuvre
ADTrafficYieldModule.YIELDER_SHARE = 0.65        -- part of the free distance given to the vehicle that pulls over
ADTrafficYieldModule.DETOUR_MAX = 400            -- m, longest detour taken to avoid meeting an oncoming vehicle
ADTrafficYieldModule.DETOUR_MIN_AHEAD = 5        -- m, the detour must leave the route before the head-on section (27/10: 15 m refused the 7R 350 at 13 m of the junction)
ADTrafficYieldModule.DETOUR_PENALTY = 1000000    -- added weight of the head-on section waypoints when looking for a detour
ADTrafficYieldModule.SPOT_CLEARANCE = 6          -- m kept free between the oncoming vehicle and the end of the roadside path
ADTrafficYieldModule.COOLDOWN_SUCCESS = 3000    -- ms, after a successful plan (another conflict may follow at once)
ADTrafficYieldModule.GIVE_UP_TIME = 300000      -- ms, after two failed attempts the pair is left alone this long
ADTrafficYieldModule.HISTORY_TIMEOUT = 600000   -- ms, a failure older than this is forgotten
-- 27/10 (942 Vario + header trailer waiting 11 m before the turn-off, the 7R 350 + Big Body coming out of the single
-- track drove into it, the plan ended "partner out" too early, the 942 reversed, its trailer swung against the shed and
-- nothing moved for 3 min), rules of 28/10:
ADTrafficYieldModule.EXIT_ROOM = 10              -- S1: m added to the length of the train coming out, between the junction and my front
ADTrafficYieldModule.REVERSE_STUCK_MS = 10000    -- S3: ms reversing without moving REVERSE_STUCK_M: stuck, even if the rear sensor sees nothing
ADTrafficYieldModule.REVERSE_STUCK_M = 1
ADTrafficYieldModule.PLAN_STUCK_MS = 90000       -- S3: ms without any of both moving PLAN_STUCK_M: the roles are swapped
ADTrafficYieldModule.PLAN_STUCK_M = 2
ADTrafficYieldModule.S4_MIN_SPEED = 12         -- km/h counted for a slow or stopped vehicle (it restarts)
ADTrafficYieldModule.S6_LOOK_AHEAD = 400       -- m of the partner's route searched for the entrance point it still has to pass
ADTrafficYieldModule.SPOT_MOUTH_CLEAR = 25     -- m: no roadside spot this close to the mouth of a single track (28/10)
ADTrafficYieldModule.SPOT_PASS_MARGIN = 0.5    -- m between a parked train and the other train passing beside it
-- 30/10 (MF 7S.210 + Cargos 750 parked in a bend, trailer still across the road, the 8510 let through at once):
-- the trailer follows its hitch (it cuts inside the bend), not the path
ADTrafficYieldModule.TOW_STEP = 0.5             -- m of tractor travel per step of the trailer simulation
ADTrafficYieldModule.TOW_EXTRA = 30             -- m added to the roadside path when the trailer is not off the road at its end
ADTrafficYieldModule.TOW_ROAD_TOLERANCE = 0.6   -- m: the trailer is off the road once its rear and centre are this close to the full offset
ADTrafficYieldModule.PASS_GAP = 10              -- m kept by the other train while the parked one finishes lining up
-- 30/10 (942 Vario + Bergmann parked twice for the 7R 350, nose against the railing of the bridge, stuck)
ADTrafficYieldModule.PASSED_ROUTE_WIDTH = 8     -- m: a vehicle this close to my route ahead of me is not passed yet
ADTrafficYieldModule.PARK_TRACE_TTL = 300000    -- ms the roadside path driven stays known (way back to the route)
ADTrafficYieldModule.REJOIN_STUCK_MS = 3000     -- ms stopped with an obstacle against the nose, off my route, before backing out
ADTrafficYieldModule.REJOIN_TIMEOUT = 60000     -- ms at most for backing out along the roadside path
ADTrafficYieldModule.ENTRY_INSIDE = 3           -- m past the start of the two-way track before a vehicle counts as inside
-- 28/10, traffic rules of the two-way track:
ADTrafficYieldModule.EXIT_PRIORITY_DISTANCE = 120 -- m from the one in the two-way track to its exit: closer, the one on the road waits before entering
ADTrafficYieldModule.REVERSE_SEARCH_MAX = 70      -- m reversed at most while looking for a spot behind (28/10)
ADTrafficYieldModule.DETOUR_ROAD_SPEED = 25       -- km/h at least counted on a detour (time lost by a detour against time lost waiting)
ADTrafficYieldModule.RADIUS_TIE = 0.5             -- m: turning radii of both trains closer than this are a tie (the shorter train parks)
ADTrafficYieldModule.MANOEUVRE_TIE = 15           -- deg: reverse manoeuvres closer than this are a tie (the shorter reverse decides)
ADTrafficYieldModule.RED_LINE_BEFORE_TRACK = 40   -- m: a red section ending this close before the two-way track is its crossing

ADTrafficYieldModule.SEARCH_INTERVAL = 500      -- ms between two roadside searches
ADTrafficYieldModule.MAX_DETECTION_DISTANCE = 45 -- m between the two vehicle centres
ADTrafficYieldModule.REVERSE_STEP = 5           -- m between two reverse targets
ADTrafficYieldModule.REVERSE_SPEED = 7          -- km/h
ADTrafficYieldModule.PARK_SPEED = 7             -- km/h
ADTrafficYieldModule.LATERAL_MARGIN = 0.6       -- m free space between the two vehicles when passing
ADTrafficYieldModule.MAX_SLOPE_DIFF = 1.2       -- m height difference allowed inside the parking footprint
-- map collision shapes that never block a vehicle in practice (field border collisions of the maps)
ADTrafficYieldModule.IGNORED_SHAPE_NAMES = {
    borderCol = true
}
ADTrafficYieldModule.MAX_ROAD_HEIGHT_DIFF = 1.0 -- m height difference allowed between road and parking spot

-- ------------------------------------------------------------------------------------------------------------
-- État partagé entre véhicules (modifié pendant le jeu)
-- ------------------------------------------------------------------------------------------------------------
-- failed attempts per pair of vehicles: key "idA-idB" -> {failures, time}
ADTrafficYieldModule.pairHistory = {}

-- ------------------------------------------------------------------------------------------------------------
-- Création et remise à zéro
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:new(vehicle)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.vehicle = vehicle
    o.blockedTimer = AutoDriveTON:new()
    o.rejoinTimer = AutoDriveTON:new()
    ADTrafficYieldModule.reset(o)
    o.cooldownUntil = 0
    return o
end

function ADTrafficYieldModule:reset()
    self.state = ADTrafficYieldModule.STATE_IDLE
    self.plan = nil
    self.partner = nil
    self.reverseTargets = nil
    self.reverseTargetIndex = 0
    self.reverseStart = nil
    self.escapeBranch = nil
    self.branchTargetIndex = 0
    self.reachedRouteIndex = nil
    self.pathIndex = nil
    self.reverseBlockedTimer = AutoDriveTON:new()
    self.stateTimer = AutoDriveTON:new()
    self.yielderStoppedTimer = AutoDriveTON:new()
    self.noOncomingTimer = AutoDriveTON:new()
    self.lastSearchTime = 0
    self.alignmentDone = nil
    self.alignmentTime = 0
    self.reverseProgress = nil
    self.comingAtMeLogged = nil
    self.blockedTimer:timer(false)
end

-- ------------------------------------------------------------------------------------------------------------
-- Outils communs
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:log(text, ...)
    if ADTrafficYieldModule.DEBUG then
        print(string.format("[AD-Yield] %s (%s) [%s]: " .. text, ADTrafficYieldModule.getName(self.vehicle), tostring(self.vehicle.id),
            ADTrafficYieldModule.STATE_NAMES[self.state] or tostring(self.state), ...))
    end
end

function ADTrafficYieldModule.getName(vehicle)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
        return vehicle.ad.stateModule:getName()
    end
    return "?"
end

-- side used when pulling over: the driving side only (never against the traffic; without a free spot on that
-- side, the vehicle reverses or the other one pulls over instead).
-- Local +x is left in GIANTS, so right is negative x. Setting trafficYieldDriveSide: 1 = right-hand traffic, 2 = left-hand
function ADTrafficYieldModule.getSides()
    if AutoDrive.getSetting("trafficYieldDriveSide") == 2 then
        return {{name = "left", sign = 1}}
    end
    return {{name = "right", sign = -1}}
end

-- straight run along the roadside after the swerve, for the towed units to line up behind the tractor:
-- a trailer only converges onto the tractor's track after about twice its own length
function ADTrafficYieldModule.getRunOut(trailLength)
    if trailLength <= 0 then
        return 2
    end
    return trailLength * 2 + 4
end

function ADTrafficYieldModule.isEnabled()
    return AutoDrive.getSetting("trafficYieldEnabled") == true or AutoDrive.getSetting("trafficYieldEnabled") == 1
end

function ADTrafficYieldModule.getPosition(vehicle)
    return getWorldTranslation(vehicle.components[1].node)
end

function ADTrafficYieldModule.getDirection(vehicle)
    local dx, _, dz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local length = MathUtil.vector2Length(dx, dz)
    if length < 0.0001 then
        return 0, 1
    end
    return dx / length, dz / length
end

function ADTrafficYieldModule.getSpeedKmh(vehicle)
    return math.abs(vehicle.lastSpeedReal or 0) * 3600
end

function ADTrafficYieldModule.isAdVehicleUsable(vehicle)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.components ~= nil and vehicle.ad.stateModule ~= nil
        and vehicle.ad.stateModule:isActive() and vehicle.ad.trafficYieldModule ~= nil and vehicle.ad.drivePathModule ~= nil
end

-- ------------------------------------------------------------------------------------------------------------
-- État du module (qui conduit, occupé, changement d'état, arrêt)
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule:isControlling()
    if self.rejoin ~= nil then
        return true
    end
    if self.state == ADTrafficYieldModule.STATE_YIELDER_APPROACH then
        -- backing off from the mouth of a single track or holding before it: the module drives (26/10,
        -- the "stuck" safety of DrivePathModule reset the 7R 350 in the middle of its back-off)
        local plan = self.plan
        return plan ~= nil and (plan.sectionBackOff ~= nil or (plan.parked == true and not plan.straightOn))
    end
    return self.state ~= ADTrafficYieldModule.STATE_IDLE and self.state ~= ADTrafficYieldModule.STATE_REVERSER_PASS and self.state ~= ADTrafficYieldModule.STATE_PARKER_PASS
        and self.state ~= ADTrafficYieldModule.STATE_PRIORITY_APPROACH
end

function ADTrafficYieldModule:isBusy()
    return self.state ~= ADTrafficYieldModule.STATE_IDLE or g_time < self.cooldownUntil
end

function ADTrafficYieldModule:setState(newState)
    if newState ~= self.state then
        self:log("-> %s (partner %s)", ADTrafficYieldModule.STATE_NAMES[newState] or tostring(newState), ADTrafficYieldModule.getName(self.partner))
        --[==[ Mis de côté (09/11) : inutilisé
        local oldName = ADTrafficYieldModule.STATE_NAMES[self.state] or "?"
        ]==]
        self.state = newState
        self.stateTimer:timer(false)
    end
end

function ADTrafficYieldModule:ensureMotorStarted()
    if self.vehicle.startMotor ~= nil and not self.vehicle:getIsMotorStarted() and self.vehicle:getCanMotorRun() then
        self.vehicle:startMotor()
    end
end

function ADTrafficYieldModule:holdVehicle(dt)
    -- a planned hold, not a blocked vehicle: isBlocked would make the unloader mode think it is stuck
    -- after 10 s and reverse out of the road (CombineUnloaderMode:monitorTasks)
    self.vehicle.ad.specialDrivingModule:stopVehicle(false)
    self.vehicle.ad.specialDrivingModule:update(dt)
end

-- ------------------------------------------------------------------------------------------------------------
-- Point d'entrée (fonction principale), appelé à chaque image
-- ------------------------------------------------------------------------------------------------------------
-- entry point, called every frame from ADDrivePathModule:followWaypoints (server)
-- returns true when this module controls the vehicle for this frame
function ADTrafficYieldModule:handle(dt, obstacleDetected)
    if not self.vehicle.isServer then
        return false
    end
    if self.parkTrace ~= nil and self:updateRejoin(dt) then
        return true
    end
    -- 26/10 (obstacles thread): the vehicle now stops 3 m behind an AD vehicle on its route, before the front sensors see it:
    -- that stop counts as "blocked by a vehicle" for the face to face detection
    if not obstacleDetected then
        local approach = self.vehicle.ad.approachModule
        if approach ~= nil and approach.shouldStop ~= nil and approach:shouldStop() then
            obstacleDetected = true
        end
    end

    -- parked / hidden vehicle waiting for a given vehicle to pass, no longer linked to a plan
    if self.state == ADTrafficYieldModule.STATE_WAIT_DETACHED then
        return self:updateDetachedWait(dt)
    end

    if self.state == ADTrafficYieldModule.STATE_IDLE then
        if not ADTrafficYieldModule.isEnabled() then
            self.blockedTimer:timer(false)
            return false
        end
        -- anticipation: oncoming AD vehicle on my route -> slow down and stop at a safe distance
        local holding = self:updateAnticipation(dt)
        if self.state == ADTrafficYieldModule.STATE_IDLE then
            if holding then
                return true
            end
            self:checkForHeadOnDeadlock(dt, obstacleDetected)
        end
        -- a plan may have just started
        if self.state == ADTrafficYieldModule.STATE_IDLE then
            return false
        end
    end

    if not self:checkPlanStillValid() then
        return false
    end

    if self.state == ADTrafficYieldModule.STATE_REVERSER_RETREAT then
        self:updateReverserRetreat(dt)
    elseif self.state == ADTrafficYieldModule.STATE_REVERSER_WAIT then
        self:updateReverserWait(dt)
    elseif self.state == ADTrafficYieldModule.STATE_REVERSER_PASS then
        self:updateReverserPass(dt)
    elseif self.state == ADTrafficYieldModule.STATE_YIELDER_APPROACH then
        -- holding at the stop point while still approaching: the module drives this frame
        if self:updateYielderApproach(dt) and self.state == ADTrafficYieldModule.STATE_YIELDER_APPROACH then
            return true
        end
    elseif self.state == ADTrafficYieldModule.STATE_PRIORITY_APPROACH then
        if self:updatePriorityApproach(dt) and self.state == ADTrafficYieldModule.STATE_PRIORITY_APPROACH then
            return true
        end
    elseif self.state == ADTrafficYieldModule.STATE_REVERSER_BRANCH then
        self:updateReverserBranch(dt)
    elseif self.state == ADTrafficYieldModule.STATE_REVERSER_HIDE then
        self:updateReverserHide(dt)
    elseif self.state == ADTrafficYieldModule.STATE_PARKER_PASS then
        self:updateParkerPass(dt)
    elseif self.state == ADTrafficYieldModule.STATE_PARKER_SEARCH then
        self:updateParkerSearch(dt)
    elseif self.state == ADTrafficYieldModule.STATE_PARKER_MOVE then
        self:updateParkerMove(dt)
    elseif self.state == ADTrafficYieldModule.STATE_PARKER_WAIT then
        self:updateParkerWait(dt)
    elseif self.state == ADTrafficYieldModule.STATE_SECTION_CLEAR then
        self:updateSectionClear(dt)
    end

    -- while driving inside a plan (passing / approaching), keep anticipating any OTHER oncoming vehicle
    if self:holdForOtherOncoming(dt) then
        return true
    end

    -- stopped face to face by a vehicle that the route comparison could not see
    if self:checkBlockedWhilePassing(dt, obstacleDetected) then
        return self:isControlling()
    end

    return self:isControlling()
end

-- ------------------------------------------------------------------------------------------------------------
-- Suivi et fin du plan
-- ------------------------------------------------------------------------------------------------------------
function ADTrafficYieldModule.getPairKey(vehicleA, vehicleB)
    local a, b = vehicleA.id or 0, vehicleB.id or 0
    if a > b then
        a, b = b, a
    end
    return tostring(a) .. "-" .. tostring(b)
end

function ADTrafficYieldModule:checkPlanStillValid()
    local plan = self.plan
    if plan == nil then
        self:reset()
        return false
    end
    local partner = self.partner
    if not ADTrafficYieldModule.isAdVehicleUsable(partner) or partner.ad.trafficYieldModule.plan ~= plan then
        self:endPlan("partner not available any more", false)
        return false
    end
    if plan.mode == "sectionClear" and plan.parked and not self.vehicle.ad.drivePathModule:isOnRoadNetwork() and self.state == ADTrafficYieldModule.STATE_REVERSER_PASS then
        -- through the single track and into the field: done
        plan.passed = true
        self:endPlan("through the single track", true)
        return false
    end
    if not self.vehicle.ad.drivePathModule:isOnRoadNetwork() and self.state ~= ADTrafficYieldModule.STATE_PARKER_MOVE and self.state ~= ADTrafficYieldModule.STATE_PARKER_WAIT
        and self.state ~= ADTrafficYieldModule.STATE_SECTION_CLEAR then
        self:endPlan("vehicle left the road network", false)
        return false
    end
    if g_time - plan.startTime > ADTrafficYieldModule.PLAN_TIMEOUT then
        self:endPlan("timeout", false)
        return false
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local px, _, pz = ADTrafficYieldModule.getPosition(partner)
    -- S3 (27/10, 28/10): neither of both moved PLAN_STUCK_M in PLAN_STUCK_MS: the roles are swapped
    local progress = plan.progress
    if progress == nil then
        progress = {time = g_time, pos = {}}
        plan.progress = progress
    end
    for _, item in ipairs({{self.vehicle, x, z}, {partner, px, pz}}) do
        local last = progress.pos[item[1]]
        if last == nil then
            progress.pos[item[1]] = {x = item[2], z = item[3]}
        elseif MathUtil.vector2Length(item[2] - last.x, item[3] - last.z) >= ADTrafficYieldModule.PLAN_STUCK_M then
            progress.pos[item[1]] = {x = item[2], z = item[3]}
            progress.time = g_time
        end
    end
    if g_time - progress.time > ADTrafficYieldModule.PLAN_STUCK_MS then
        self:restartWithRolesSwapped(string.format("nobody moved for %d s", ADTrafficYieldModule.PLAN_STUCK_MS / 1000),
            string.format("personne n'a bouge depuis %d s", ADTrafficYieldModule.PLAN_STUCK_MS / 1000))
        return false
    end
    local maxApart = 120
    if plan.mode == "early" then
        maxApart = 3 * ADTrafficYieldModule.ANTICIPATION_DISTANCE
    elseif plan.mode == "sectionClear" then
        maxApart = ADTrafficYieldModule.SECTION_CLEAR_MAX + 100
    end
    if MathUtil.vector2Length(px - x, pz - z) > maxApart then
        self:endPlan("vehicles too far apart", plan.passed)
        return false
    end
    return true
end

-- ends the plan for both vehicles
function ADTrafficYieldModule:endPlan(reason, success)
    local plan = self.plan
    self:log("end of plan: %s (success=%s)", tostring(reason), tostring(success))

    if plan ~= nil and plan.pairKey ~= nil and success ~= nil then
        if success then
            ADTrafficYieldModule.pairHistory[plan.pairKey] = nil
        else
            local history = ADTrafficYieldModule.pairHistory[plan.pairKey] or {failures = 0}
            history.failures = history.failures + 1
            history.time = g_time
            history.lastReverser = plan.firstReverser or plan.reverser
            if plan.mode == "early" then
                -- the same early plan would start again at once and block both again (21:08-21:20: 3 timeouts in a row)
                history.earlyTried = g_time
            end
            ADTrafficYieldModule.pairHistory[plan.pairKey] = history
        end
    end

    local vehicles = {self.vehicle}
    if plan ~= nil then
        vehicles = {plan.reverser, plan.parker}
    end

    for _, vehicle in pairs(vehicles) do
        if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.trafficYieldModule ~= nil then
            local module = vehicle.ad.trafficYieldModule
            if module.plan == plan then
                local wasControlling = module.state ~= ADTrafficYieldModule.STATE_IDLE
                local reachedRouteIndex = module.reachedRouteIndex
                -- 28/10 (S7): the parked one stays parked until the last vehicle of the oncoming queue has passed
                local parkedWaiting = success == true and (module.state == ADTrafficYieldModule.STATE_PARKER_WAIT or module.state == ADTrafficYieldModule.STATE_REVERSER_HIDE)
                local passer = plan ~= nil and (vehicle == plan.parker and plan.reverser or plan.parker) or nil
                local spot = plan ~= nil and plan.parkSpot or nil
                -- 30/10 (B, D): the roadside path I drove stays known: same partner again = I stay, blocked off my route = way back
                if plan ~= nil and vehicle == plan.parker and spot ~= nil and spot.path ~= nil
                    and (module.state == ADTrafficYieldModule.STATE_PARKER_WAIT or module.state == ADTrafficYieldModule.STATE_PARKER_MOVE) then
                    module.parkTrace = {path = spot.path, spot = spot, partner = passer, time = g_time}
                end
                module:reset()
                local nextInQueue = nil
                if parkedWaiting and passer ~= nil then
                    nextInQueue = ADTrafficYieldModule.findFollowerBehind(passer, ADTrafficYieldModule.QUEUE_GAP, vehicle)
                    if nextInQueue ~= nil and module:hasPassedMe(nextInQueue, spot and spot.dirX, spot and spot.dirZ) then
                        nextInQueue = nil
                    end
                end
                if nextInQueue ~= nil then
                    module.waitDirX = spot and spot.dirX
                    module.waitDirZ = spot and spot.dirZ
                    module.waitFor = nextInQueue
                    module.waitSpot = spot
                    module.waitRouteIndex = reachedRouteIndex
                    module:setState(ADTrafficYieldModule.STATE_WAIT_DETACHED)
                    print(string.format("[AD-Croise] %s: %s est passe, je reste gare pour la file : %s", ADTrafficYieldModule.getName(vehicle),
                        ADTrafficYieldModule.getName(passer), ADTrafficYieldModule.getName(nextInQueue)))
                    wasControlling = false
                end
                if success == true then
                    module.cooldownUntil = g_time + ADTrafficYieldModule.COOLDOWN_SUCCESS
                elseif success == false then
                    module.cooldownUntil = g_time + ADTrafficYieldModule.COOLDOWN
                end
                if wasControlling and vehicle.ad.specialDrivingModule ~= nil then
                    vehicle.ad.specialDrivingModule:releaseVehicle()
                end
                if nextInQueue == nil then
                    ADTrafficYieldModule.resyncWayPoints(vehicle, reachedRouteIndex)
                end
            end
        end
    end

    if success == false and plan ~= nil and plan.reverser ~= nil then
        AutoDriveMessageEvent.sendMessageOrNotification(plan.reverser, ADMessagesManager.messageTypes.WARN, "$l10n_AD_Driver_of; %s $l10n_AD_trafficYield_failed;", 5000, ADTrafficYieldModule.getName(plan.reverser))
    end
end

-- S3: the plan is stuck (or a reverser cannot reverse): end it and start the standard manoeuvre again with the roles
-- swapped (the pair history says who reversed last; A1 still applies; 2 failures = the pair is left alone)
function ADTrafficYieldModule:restartWithRolesSwapped(reason, reasonFr)
    local plan = self.plan
    local partner = self.partner
    local vehicle = self.vehicle
    local early = plan ~= nil and plan.mode == "early"
    self:log("%s: the roles are swapped", reason)
    print(string.format("[AD-Croise] %s: %s, %s", ADTrafficYieldModule.getName(vehicle), reasonFr,
        early and "fin du plan d'attente, manoeuvre classique ensuite" or ("j'inverse les roles avec " .. ADTrafficYieldModule.getName(partner))))
    self:endPlan(reason, false)
    if not early and ADTrafficYieldModule.isAdVehicleUsable(partner) and ADTrafficYieldModule.isAdVehicleUsable(vehicle) then
        ADTrafficYieldModule.startPlan(vehicle, partner)
    end
end

-- after a manoeuvre the current waypoint may be behind the vehicle (parker drove past it on the roadside)
-- skip every waypoint that is no longer in front of the vehicle
function ADTrafficYieldModule.resyncWayPoints(vehicle, restartRouteIndex)
    local drivePathModule = vehicle.ad.drivePathModule
    if drivePathModule == nil then
        return
    end
    -- the reverser went back along its route: restart from the last route waypoint it reversed past
    local wps, idx = drivePathModule:getWayPoints()
    -- AutoDrive never drives with index 1 (it always needs the previous waypoint), so clamp to 2
    if restartRouteIndex ~= nil and wps ~= nil and idx ~= nil then
        restartRouteIndex = math.max(2, restartRouteIndex)
        if restartRouteIndex < idx and wps[restartRouteIndex] ~= nil and wps[restartRouteIndex - 1] ~= nil then
            drivePathModule:setCurrentWayPointIndex(restartRouteIndex)
        end
    end
    local wayPoints, currentIndex = drivePathModule:getWayPoints()
    local skipped = 0
    if wayPoints ~= nil and currentIndex ~= nil then
        while skipped < 30 do
            local wp = drivePathModule:getCurrentWayPoint()
            if wp == nil or drivePathModule:getNextWayPoint() == nil then
                break
            end
            local _, _, localZ = AutoDrive.worldToLocal(vehicle, wp.x, wp.y, wp.z)
            if localZ > 2 then
                break
            end
            drivePathModule:switchToNextWayPoint()
            skipped = skipped + 1
        end
    end
    drivePathModule.minDistanceToNextWp = math.huge
    if drivePathModule.minDistanceTimer ~= nil then
        drivePathModule.minDistanceTimer:timer(false)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Texte d'état (28/10) : ce que le véhicule attend et pour qui (HUD)
-- ------------------------------------------------------------------------------------------------------------
-- what the vehicle waits for, or the manoeuvre it drives for another one, as an AutoDrive text ($l10n_ keys and names);
-- nil when it just drives. ADTaskModule shows it instead of the text of the task while it lasts
function ADTrafficYieldModule.getWaitInfo(vehicle)
    if vehicle == nil or vehicle.ad == nil then
        return nil
    end
    local getName = ADTrafficYieldModule.getName
    local stopped = ADTrafficYieldModule.getSpeedKmh(vehicle) < 1
    local function waitFor(other, what)
        return "$l10n_AD_ty_waitFor; " .. getName(other) .. " $l10n_AD_ty_" .. what .. ";"
    end
    local function doing(what, other)
        return "$l10n_AD_ty_" .. what .. "; " .. getName(other)
    end
    local m = vehicle.ad.trafficYieldModule
    if m ~= nil then
        local state, plan, partner = m.state, m.plan, m.partner
        if state == ADTrafficYieldModule.STATE_WAIT_DETACHED and m.waitFor ~= nil then
            return waitFor(m.waitFor, "toPass")
        end
        if partner ~= nil and plan ~= nil then
            if state == ADTrafficYieldModule.STATE_REVERSER_RETREAT or state == ADTrafficYieldModule.STATE_REVERSER_BRANCH then
                return doing("reverseFor", partner)
            elseif state == ADTrafficYieldModule.STATE_SECTION_CLEAR then
                return plan.parked and waitFor(partner, "toPass") or doing("reverseFor", partner)
            elseif state == ADTrafficYieldModule.STATE_REVERSER_HIDE or state == ADTrafficYieldModule.STATE_PARKER_WAIT then
                return waitFor(partner, "toPass")
            elseif state == ADTrafficYieldModule.STATE_PARKER_MOVE then
                return doing("parkFor", partner)
            elseif state == ADTrafficYieldModule.STATE_PARKER_SEARCH then
                return waitFor(partner, "toReverse")
            elseif state == ADTrafficYieldModule.STATE_REVERSER_WAIT then
                return waitFor(partner, plan.mode == "sectionClear" and "toClear" or "toPark")
            elseif state == ADTrafficYieldModule.STATE_YIELDER_APPROACH then
                if plan.sectionBackOff ~= nil then
                    return doing("reverseFor", partner)
                elseif plan.straightOn then
                    -- drives on along another way
                elseif plan.waitBeforeSection and (plan.parked or stopped) then
                    return waitFor(partner, "leaveTrack")
                elseif plan.parkSpot ~= nil then
                    return doing("parkFor", partner)
                elseif stopped then
                    return waitFor(partner, "toPass")
                end
            elseif state == ADTrafficYieldModule.STATE_PRIORITY_APPROACH and stopped then
                return waitFor(partner, "toPark")
            end
        end
        if m.anticipationHoldFor ~= nil and stopped then
            return waitFor(m.anticipationHoldFor, "toPass")
        end
    end
    -- red points (Intersection): what it waits for there
    local c = vehicle.ad.intersection
    if c ~= nil and c.holding and c.lastReason ~= nil then
        return "$l10n_AD_ty_crossing; " .. tostring(c.lastReason)
    end
    -- queue behind another AutoDrive vehicle
    local am = vehicle.ad.approachModule
    if stopped and am ~= nil and am.shouldStop ~= nil and am:shouldStop() then
        local hit = am:getHit()
        local root = hit ~= nil and hit.object ~= nil and hit.object.getRootVehicle ~= nil and hit.object:getRootVehicle() or nil
        local name = root ~= nil and getName(root) or "?"
        if name == "?" and hit ~= nil and hit.name ~= nil then
            name = tostring(hit.name)
        end
        return "$l10n_AD_ty_queue; " .. name
    end
    return nil
end
