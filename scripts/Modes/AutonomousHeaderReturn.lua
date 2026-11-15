-- ============================================================================================================
-- FarmPilot : AutonomousHeaderReturn.lua
-- Mode Autonome, moissonneuse équipée seule : fin de champ, la barre est reposée sur sa remorque ; la moissonneuse
-- rentre à sa place et le tracteur ramène la remorque à la sienne. Les deux gardent leur écart sur la route du retour.
--
-- Règle (15/11, champ 77, 19:34 : les deux partaient ensemble, le MF à 2,5 m derrière la Lexion ; elle a touché le
-- poteau du portail de la cour, ne pouvait plus reculer, « recul impossible (véhicule derrière) » ; choix A) :
-- - Départ : celle des deux qui est la plus près de l'entrée du champ part la première ; l'autre part seulement quand
--   la première a DEPART_GAP m d'avance. Elle part quand même si la première ne bouge plus depuis STUCK_TIME ms, ou
--   au bout de DEPART_MAX ms.
-- - En route : celle de derrière reste toujours à FOLLOW_GAP m au moins de celle de devant (devant elle, sur les
--   LOOK_AHEAD m de sa route, dans le même sens) : elle s'arrête et repart à FOLLOW_GAP + RESUME m. Celle de devant a
--   ainsi toujours la place de reculer ou de manœuvrer. Face à face : rien ici (croisement habituel). Arrêt plus long
--   que HOLD_MAX ms : elle repart (jamais de blocage l'une derrière l'autre).
-- - Seulement au retour de fin de champ (barre posée sur la remorque), pas à l'amenée (AutonomousHeaderFollow.lua).
--
-- Branché par : enveloppes de ADHeaderFlow.parkTrailer et ADHeaderFlow.combineStage (étape « backoff ») ;
-- DriveToDestinationTask:updateArrival (DriveToDestinationTaskArrival.lua), enveloppée ici : arrêt sur place tant que
-- task.fpHold le demande. Chargé par register.lua après AutonomousHeaderYard.lua.
-- ============================================================================================================

ADHeaderReturn = ADHeaderReturn or {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderReturn.ENABLED = true
ADHeaderReturn.DEPART_GAP = 60      -- m d'avance de la première avant que la deuxième parte
ADHeaderReturn.FOLLOW_GAP = 25      -- m au moins derrière celle de devant
ADHeaderReturn.RESUME = 5           -- m en plus pour repartir
ADHeaderReturn.LOOK_AHEAD = 45      -- m de sa route regardés devant elle
ADHeaderReturn.ROUTE_WIDTH = 6      -- m de chaque côté de sa route
ADHeaderReturn.STUCK_TIME = 15000   -- ms : la première ne bouge plus, la deuxième part quand même
ADHeaderReturn.DEPART_MAX = 240000  -- ms d'attente au plus au départ
ADHeaderReturn.HOLD_MAX = 60000     -- ms d'arrêt au plus en route

local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function pos(v)
    local x, _, z = getWorldTranslation(v.components[1].node)
    return x, z
end

local function gone(v)
    return v == nil or v.isDeleted or v.ad == nil or v.ad.stateModule == nil or not v.ad.stateModule:isActive()
end

local function stopped(v)
    return math.abs(v.lastSpeedReal or 0) < 0.0003
end

-- distance de (x, z) au segment a-b
local function segDistance(a, b, x, z)
    local vx, vz = b.x - a.x, b.z - a.z
    local l2 = vx * vx + vz * vz
    local u = l2 > 0.0001 and math.max(0, math.min(1, ((x - a.x) * vx + (z - a.z) * vz) / l2)) or 0
    return MathUtil.vector2Length(x - (a.x + vx * u), z - (a.z + vz * u))
end

-- p est devant v, sur les LOOK_AHEAD m de sa route, et va dans le même sens (pas face à face)
function ADHeaderReturn.isAhead(v, p)
    local node = v.components[1].node
    local vx, vz = pos(v)
    local px, pz = pos(p)
    local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
    if (px - vx) * fx + (pz - vz) * fz <= 0 then
        return false
    end
    local gx, _, gz = localDirectionToWorld(p.components[1].node, 0, 0, 1)
    if fx * gx + fz * gz < -0.5 then
        return false -- face à face : croisement habituel
    end
    local dpm = v.ad.drivePathModule
    local wayPoints = dpm ~= nil and dpm.wayPoints or nil
    if wayPoints == nil or #wayPoints < 2 then
        return true
    end
    local i = dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1
    i = math.max(2, i)
    local done = 0
    local prev = { x = vx, z = vz }
    while i <= #wayPoints and done <= ADHeaderReturn.LOOK_AHEAD do
        local w = wayPoints[i]
        if segDistance(prev, w, px, pz) <= ADHeaderReturn.ROUTE_WIDTH then
            return true
        end
        done = done + MathUtil.vector2Length(w.x - prev.x, w.z - prev.z)
        prev = w
        i = i + 1
    end
    return false
end

-- arrêt sur place demandé ? (appelé à chaque image pendant la route)
function ADHeaderReturn.hold(task)
    local s = task.fpReturn
    local v, p = task.vehicle, s.partner
    local now = g_time or 0
    if gone(p) then
        if not s.departed then
            s.departed = true
            log("%s : retour du champ, part : « %s » est arrivée (ou arrêtée)", nameOf(v), nameOf(p))
        end
        return false
    end
    local vx, vz = pos(v)
    local px, pz = pos(p)
    local d = MathUtil.vector2Length(px - vx, pz - vz)
    -- départ : la deuxième attend que la première ait DEPART_GAP m d'avance
    if not s.departed then
        s.waitSince = s.waitSince or now
        if stopped(p) then
            s.stillSince = s.stillSince or now
        else
            s.stillSince = nil
        end
        local why = nil
        if d >= ADHeaderReturn.DEPART_GAP then
            why = string.format("« %s » a %.0f m d'avance", nameOf(p), d)
        elseif s.stillSince ~= nil and now - s.stillSince >= ADHeaderReturn.STUCK_TIME then
            why = string.format("« %s » ne bouge plus (à %.0f m)", nameOf(p), d)
        elseif now - s.waitSince >= ADHeaderReturn.DEPART_MAX then
            why = string.format("attendu %.0f s", (now - s.waitSince) / 1000)
        end
        if why ~= nil then
            s.departed = true
            log("%s : retour du champ, part : %s", nameOf(v), why)
            return false
        end
        if not s.waitLogged then
            s.waitLogged = true
            log("%s : retour du champ, « %s » part la première, attend qu'elle ait %.0f m d'avance", nameOf(v), nameOf(p), ADHeaderReturn.DEPART_GAP)
        end
        return true
    end
    -- en route : FOLLOW_GAP m au moins derrière celle de devant
    local limit = ADHeaderReturn.FOLLOW_GAP + (s.holdSince ~= nil and ADHeaderReturn.RESUME or 0)
    if d < limit and ADHeaderReturn.isAhead(v, p) then
        if s.holdSince == nil then
            s.holdSince = now
            log("%s : retour du champ, « %s » devant à %.0f m, s'arrête pour lui laisser %.0f m", nameOf(v), nameOf(p), d, ADHeaderReturn.FOLLOW_GAP)
        end
        if now - s.holdSince < ADHeaderReturn.HOLD_MAX then
            return true
        end
        if not s.holdMaxLogged then
            s.holdMaxLogged = true
            log("%s : retour du champ, arrêtée depuis %.0f s derrière « %s », repart", nameOf(v), ADHeaderReturn.HOLD_MAX / 1000, nameOf(p))
        end
        return false
    end
    if s.holdSince ~= nil then
        log("%s : retour du champ, « %s » à %.0f m, repart", nameOf(v), nameOf(p), d)
        s.holdSince = nil
        s.holdMaxLogged = nil
    end
    return false
end

-- la première des deux à partir : la plus près de l'entrée du champ (1re destination de la moissonneuse)
local function leaderOf(job)
    if job.returnLead ~= nil then
        return job.returnLead
    end
    local c, t = job.combine, job.tractor
    local marker = c.ad.stateModule.getFirstMarker ~= nil and c.ad.stateModule:getFirstMarker() or nil
    local wp = marker ~= nil and marker.id ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    local lead = t
    if wp ~= nil then
        local cx, cz = pos(c)
        local tx, tz = pos(t)
        if MathUtil.vector2Length(cx - wp.x, cz - wp.z) < MathUtil.vector2Length(tx - wp.x, tz - wp.z) then
            lead = c
        end
    end
    job.returnLead = lead
    log("%s : retour du champ, « %s » part la première (la plus près de l'entrée)", nameOf(c), nameOf(lead))
    return lead
end

function ADHeaderReturn.attach(task, v, partner, job)
    if not ADHeaderReturn.ENABLED or task == nil or partner == nil or partner == v or gone(partner) then
        return
    end
    local lead = leaderOf(job)
    task.fpReturn = { partner = partner, departed = lead == v }
    task.fpHold = ADHeaderReturn.hold
end

-- ------------------------------------------------------------------------------------------------------------
-- Accroches
-- ------------------------------------------------------------------------------------------------------------
if DriveToDestinationTask ~= nil and DriveToDestinationTask.updateArrival ~= nil then
    local baseArrival = DriveToDestinationTask.updateArrival
    function DriveToDestinationTask:updateArrival(dt)
        if self.fpHold ~= nil then
            local ok, h = FarmPilotCall(self.fpHold, self)
            if ok and h then
                local sdm = self.vehicle.ad.specialDrivingModule
                sdm:stopVehicle()
                sdm:update(dt)
                return true
            end
        end
        return baseArrival(self, dt)
    end
end

-- tracteur : la remorque rentre à sa place après la fin de champ (barre posée dessus)
local baseParkTrailer = ADHeaderFlow.parkTrailer
function ADHeaderFlow.parkTrailer(mode, job)
    baseParkTrailer(mode, job)
    if job ~= nil and job.headerDropped and job.combine ~= nil and mode.parkStage == "tool" then
        ADHeaderReturn.attach(mode.driveToDestinationTask, mode.vehicle, job.combine, job)
    end
end

-- moissonneuse : barre posée, recul fait, elle rentre à sa place
local baseCombineStage = ADHeaderFlow.combineStage
function ADHeaderFlow.combineStage(mode, job, stage, result)
    baseCombineStage(mode, job, stage, result)
    if stage == "backoff" and mode.headerStage == "park" and job ~= nil and job.tractor ~= nil and not job.swap then
        ADHeaderReturn.attach(mode.driveToDestinationTask, mode.vehicle, job.tractor, job)
    end
end
