-- ============================================================================================================
-- FarmPilot : AutonomousHeaderStuck.lua
-- Mode Autonome, moissonneuse équipée seule : le tracteur de la remorque porte-barre n'attend JAMAIS sans fin devant
-- un objet fixe en allant à sa place. Bloqué, il recule un peu, l'endroit est écarté et la remorque va au suivant ;
-- la moissonneuse qui l'attend suit le nouveau plan.
--
-- Règle (16/11, champ 52 : le MF 7S.210, décalé vers le champ pour sa marche arrière, s'est collé au muret du chemin
-- et y est resté ; le contournement disait « keep waiting », la Lexion « attend que la remorque soit en place ») :
-- - Bloqué : au départ (amenée de la barre), étapes « toField » (route vers le champ, et sa suite sur le chemin
--   jusqu'à l'arrêt d'une marche arrière), « turn » (demi-tour, endroit plus loin) et « yard » (place hors de la
--   route) ; moins de STUCK_SPEED m/s, un objet fixe devant (ADObstacleDetourModule:isBlockedByStaticObstacle : le
--   capteur avant ou le balayage de la route ; pas un véhicule, pas un portail, pas une attente au croisement), et
--   pas de contournement en cours, pendant STUCK_TIME ms d'affilée (contrôlé toutes les STUCK_CHECK ms).
-- - Alors : la tâche en cours est arrêtée (étape « stuck »), message, traces. La place prévue est écartée
--   (job.rejected : cadre de la marche arrière ou de la barre en travers du chemin, recul jusqu'à la route, place
--   hors de la route, bout de la route) et le plan oublié. Le tracteur recule tout droit de STUCK_BACK m avec la
--   remorque (ADFrontBackOffTask, étape « unstick ») pour se dégager, puis endroit suivant
--   (AutonomousHeaderSpot.lua : moveOn, place hors de la route d'abord une fois). Plus rien : il attend là, la
--   moissonneuse vient à lui (tractorWait).
-- - La moissonneuse attend « remorque en place » (job.trailerReady) : il ne passe à vrai qu'une fois la remorque au
--   nouvel endroit ; la remorque reculée (job.backIn), le recul jusqu'à la route (job.roadBack) sont effacés par
--   moveOn : elle va au nouvel endroit comme d'habitude.
-- - Marche arrière bloquée sans avancer : Tasks/HeaderBackInTask.lua (« stuck », BACKIN_STUCK).
-- - Réglage STUCK = false : comme avant.
--
-- Branché par : Modes/AutonomousHeader.lua (monitor et tractorStage, enveloppés ici : étapes « stuck » et
-- « unstick »). Chargé par register.lua après AutonomousHeaderGate.lua et avant AutonomousHeaderHookup.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.STUCK = true             -- false : pas de contrôle, comme avant
ADHeaderFlow.STUCK_TIME = 20000       -- ms bloqué devant un objet fixe
ADHeaderFlow.STUCK_SPEED = 0.3        -- m/s : en dessous, il n'avance pas
ADHeaderFlow.STUCK_CHECK = 500        -- ms entre deux contrôles
ADHeaderFlow.STUCK_BACK = 3           -- m de recul pour se dégager
ADHeaderFlow.STUCK_STAGES = { toField = true, turn = true, yard = true }

local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

-- un objet fixe devant, pas un véhicule : true, son nom
function ADHeaderFlow.fixedAhead(t)
    local ad = t.ad
    local detour = ad ~= nil and ad.obstacleDetourModule or nil
    if detour == nil or detour.isBlockedByStaticObstacle == nil then
        return false
    end
    if detour.isControlling ~= nil and detour:isControlling() then
        return false -- un contournement est en cours
    end
    if not detour:isBlockedByStaticObstacle() then
        return false
    end
    if detour.isVehicleInFront ~= nil and detour:isVehicleInFront() then
        return false
    end
    local hit = ad.approachModule ~= nil and ad.approachModule.getHit ~= nil and ad.approachModule:getHit() or nil
    if hit ~= nil and hit.isVehicle then
        return false
    end
    return true, hit ~= nil and hit.name or "capteur avant"
end

-- à chaque image : le tracteur bloqué devant un objet fixe depuis STUCK_TIME ms ? (étape « stuck »)
function ADHeaderFlow.stuckMonitor(mode, dt)
    local t = mode.vehicle
    local job = t.ad.fpHeaderJob
    local stage = mode.headerStage
    if job == nil or job.tractor ~= t or job.phase ~= "deliver" or not ADHeaderFlow.STUCK_STAGES[stage] then
        mode.stuckTime, mode.stuckCheck, mode.stuckStage = nil, nil, nil
        return
    end
    if mode.stuckStage ~= stage then
        mode.stuckStage, mode.stuckTime, mode.stuckCheck = stage, 0, 0
    end
    mode.stuckCheck = (mode.stuckCheck or 0) + dt
    if mode.stuckCheck < ADHeaderFlow.STUCK_CHECK then
        return
    end
    local step = mode.stuckCheck
    mode.stuckCheck = 0
    local fixed, name = false, nil
    if math.abs(t.lastSpeedReal or 0) * 1000 < ADHeaderFlow.STUCK_SPEED then
        fixed, name = ADHeaderFlow.fixedAhead(t)
    end
    if not fixed then
        mode.stuckTime = 0
        return
    end
    mode.stuckTime = (mode.stuckTime or 0) + step
    if mode.stuckTime < ADHeaderFlow.STUCK_TIME then
        return
    end
    -- bloqué : la tâche en cours s'arrête, la suite dans tractorStage (« stuck »)
    local task = t.ad.taskModule:getActiveTask()
    local dpm = t.ad.drivePathModule
    local wayPoints = dpm ~= nil and dpm.wayPoints or nil
    local stuck = { from = stage, name = name, plan = mode.headerBackIn, roadBack = mode.headerRoadBack }
    if wayPoints ~= nil and #wayPoints > 0 then
        stuck.routeEnd = { x = wayPoints[#wayPoints].x, z = wayPoints[#wayPoints].z }
    end
    if stage == "yard" and task ~= nil and task.spots ~= nil and task.spotIndex ~= nil then
        stuck.yardSpot = task.spots[task.spotIndex]
    end
    log("%s : bloqué depuis %.0f s sans avancer devant un objet fixe (%s), étape « %s » : arrêt, l'endroit est écarté", nameOf(t),
        mode.stuckTime / 1000, tostring(name), tostring(stage))
    mode.stuckTime, mode.stuckCheck, mode.stuckStage = nil, nil, nil
    mode.headerStuck = stuck
    mode.headerStage = "stuck"
    if t.ad.obstacleDetourModule ~= nil and t.ad.obstacleDetourModule.reset ~= nil then
        t.ad.obstacleDetourModule:reset()
    end
    if task ~= nil and task.finish ~= nil then
        task:finish("stuck")
    elseif task ~= nil and task.finished ~= nil then
        task:finished()
    else
        t.ad.taskModule:setCurrentTaskFinished()
    end
end

-- tâche arrêtée : la place prévue est écartée, petit recul pour se dégager
function ADHeaderFlow.stuckDone(mode, job)
    local t = mode.vehicle
    local stuck = mode.headerStuck or {}
    mode.headerStuck = nil
    mode.driveToDestinationTask = nil
    if t.ad.isStoppingWithError then
        job.cancelled = true
        ADHeaderFlow.stopHere(mode, nil)
        return
    end
    AutonomousMode.message(t, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_headerStuck")
    local places = {}
    if stuck.plan ~= nil and stuck.plan.frame ~= nil then
        places[#places + 1] = { stuck.plan.frame.x, stuck.plan.frame.z, stuck.plan.cross and "barre en travers du chemin" or "marche arrière dans l'entrée du champ" }
    end
    if stuck.roadBack ~= nil and stuck.roadBack.x ~= nil then
        places[#places + 1] = { stuck.roadBack.x, stuck.roadBack.z, "recul jusqu'à la route" }
    end
    if stuck.yardSpot ~= nil then
        places[#places + 1] = { stuck.yardSpot.x, stuck.yardSpot.z, "place hors de la route" }
    end
    if #places == 0 and stuck.routeEnd ~= nil then
        places[#places + 1] = { stuck.routeEnd.x, stuck.routeEnd.z, "bout de la route" }
    end
    for _, p in ipairs(places) do
        ADHeaderFlow.rejectPlace(job, p[1], p[2])
        log("%s : place écartée (%s, en %.0f, %.0f)", nameOf(t), p[3], p[1], p[2])
    end
    if job.fieldSpot == nil and stuck.routeEnd ~= nil then
        job.fieldSpot = { x = stuck.routeEnd.x, z = stuck.routeEnd.z } -- les autres endroits sont cherchés autour du bout de la route
    end
    -- le plan prévu est oublié
    mode.headerBackIn = nil
    mode.headerRoadBack = nil
    mode.headerGate = nil
    job.roadBack = nil
    job.backIn = nil
    job.trailerReady = false
    mode.stuckWhy = string.format("bloqué par un objet fixe (%s)", tostring(stuck.name))
    if ADFrontBackOffTask ~= nil and ADHeaderFlow.STUCK_BACK > 0 then
        log("%s : recule de %.0f m pour se dégager", nameOf(t), ADHeaderFlow.STUCK_BACK)
        mode.headerStage = "unstick"
        mode.headerTask = ADFrontBackOffTask:new(t, ADHeaderFlow.STUCK_BACK, false, nil)
        t.ad.taskModule:addTask(mode.headerTask)
        return
    end
    ADHeaderFlow.unstuckDone(mode, job)
end

-- dégagé : endroit suivant, sinon il attend là (la moissonneuse vient à lui)
function ADHeaderFlow.unstuckDone(mode, job)
    local t = mode.vehicle
    local why = mode.stuckWhy or "bloqué par un objet fixe"
    mode.stuckWhy = nil
    if t.ad.isStoppingWithError then
        job.cancelled = true
        ADHeaderFlow.stopHere(mode, nil)
        return
    end
    if ADHeaderFlow.moveOn(mode, job, why, true) then
        return
    end
    ADHeaderFlow.tractorWait(mode, job)
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes
-- ------------------------------------------------------------------------------------------------------------
if ADHeaderFlow.monitor ~= nil then
    local baseMonitor = ADHeaderFlow.monitor
    function ADHeaderFlow.monitor(mode, dt)
        baseMonitor(mode, dt)
        if ADHeaderFlow.STUCK and mode.headerStage ~= nil then
            ADHeaderFlow.stuckMonitor(mode, dt)
        end
    end
end

if ADHeaderFlow.tractorStage ~= nil then
    local baseTractorStage = ADHeaderFlow.tractorStage
    function ADHeaderFlow.tractorStage(mode, job, stage, result)
        if stage == "stuck" then
            ADHeaderFlow.stuckDone(mode, job)
            return
        end
        if stage == "unstick" then
            ADHeaderFlow.unstuckDone(mode, job)
            return
        end
        return baseTractorStage(mode, job, stage, result)
    end
end
