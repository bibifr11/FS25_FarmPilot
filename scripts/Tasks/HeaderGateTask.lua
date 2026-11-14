-- ============================================================================================================
-- FarmPilot : HeaderGateTask.lua
-- Mode Autonome, moissonneuse équipée seule : les deux tâches de la barre amenée devant la moissonneuse qui attend
-- en face de l'entrée du champ (Modes/AutonomousHeaderGate.lua).
--
-- Règle (13/11) :
-- - ADHeaderGateBackTask (moissonneuse) : arrêtée sur la route, l'entrée du champ dépassée, elle recule tout
--   droit, puis en quart de cercle de l'autre côté de la route jusque dans l'axe de l'entrée, puis tout droit dans
--   cet axe (le chemin : ADHeaderFlow.gateBackPath, refait d'où elle est vraiment). Elle vise un point du chemin
--   LOOK m derrière elle, avec le braquage du cercle qui y passe (steerBack). Dans l'axe et assez loin de la
--   route : elle avance tout droit vers le champ jusqu'à sa place d'attente (plan.depth m de l'axe de la route),
--   le nez vers le champ.
--   Rien n'est fait (« badStart ») si elle n'est pas sur la route dans son sens ; (« ground ») si le sol n'est pas
--   libre le long du chemin refait. Arrêt avant la fin : quelque chose derrière pendant BLOCKED ms (« blocked »),
--   un coin dans une culture (« offGround », contrôlé toutes les CROP_CHECK ms), TIMEOUT ms (« timeout »). Pas
--   assez droite à la fin : « badPose ».
-- - ADHeaderGateInTask (tracteur) : arrêté avant l'entrée, il attend que la moissonneuse soit en place
--   (job.gateReady), GATE_WAIT ms au plus. Puis il avance le long de la route, décalé de plan.offset m vers le
--   champ, et s'arrête quand le cadre de la barre est dans l'axe de la moissonneuse, là où elle est vraiment
--   (ADHeaderFlow.gateStop). Les SLOW_DISTANCE derniers mètres à SLOW km/h, l'arrêt demandé STOP_LEAD m avant.
--   « cancelled » : la moissonneuse n'est pas en place ; « blocked » : arrêté BLOCKED ms ; « timeout » ;
--   « noFrame » : cadre de la barre introuvable.
-- - Les résultats (self.result) sont lus par Modes/AutonomousHeaderGate.lua (combineStage « gateBack »,
--   gateInDone).
--
-- Branché par : Modes/AutonomousHeaderGate.lua. Chargé par register.lua après HeaderRoadBackTask.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Outils communs
-- ------------------------------------------------------------------------------------------------------------
local function groundY(x, z)
    if getTerrainHeightAtWorldPos ~= nil and g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
    end
    return 0
end

local function hold(vehicle, dt)
    local sdm = vehicle.ad.specialDrivingModule
    sdm:stopVehicle()
    sdm:update(dt)
end

local function angleOf(cosine)
    return math.deg(math.acos(math.max(-1, math.min(1, cosine))))
end

-- un coin de ce véhicule (pris shrink m en dedans) est dans une culture ?
local function cornerInCrop(v, shrink)
    if v == nil or v.components == nil or ADFieldPark == nil or ADFieldPark.hasGrowingCrop == nil then
        return false
    end
    local node = v.components[1].node
    local size = v.size or {}
    local halfW = math.max((size.width or 3) / 2 - shrink, 0.5)
    local halfL = math.max((size.length or 8) / 2 - shrink, 0.5)
    local ox, oz = size.widthOffset or 0, size.lengthOffset or 0
    for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
        local x, _, z = localToWorld(node, ox + c[1] * halfW, 0, oz + c[2] * halfL)
        if ADFieldPark.hasGrowingCrop(x, z) == true then
            return true
        end
    end
    return false
end

-- ============================================================================================================
-- Moissonneuse : se ranger en face de l'entrée, en marche arrière
-- ============================================================================================================
ADHeaderGateBackTask = ADInheritsFrom(AbstractTask)

ADHeaderGateBackTask.STATE_STOPPING = 1
ADHeaderGateBackTask.STATE_REVERSE = 2
ADHeaderGateBackTask.STATE_PAUSE = 3
ADHeaderGateBackTask.STATE_FORWARD = 4
ADHeaderGateBackTask.STATE_SETTLE = 5

ADHeaderGateBackTask.SPEED = 4             -- km/h en marche arrière
ADHeaderGateBackTask.SLOW = 2              -- km/h sur les derniers mètres
ADHeaderGateBackTask.SLOW_DISTANCE = 2     -- m
ADHeaderGateBackTask.LOOK = 4.5            -- m : le point visé est ça plus loin sur le chemin
ADHeaderGateBackTask.FORWARD_SPEED = 3     -- km/h pour revenir à sa place d'attente
ADHeaderGateBackTask.FORWARD_LOOK = 6      -- m
ADHeaderGateBackTask.STOP_TIME = 500       -- ms à l'arrêt avant de partir
ADHeaderGateBackTask.STOP_TIMEOUT = 8000   -- ms
ADHeaderGateBackTask.PAUSE_TIME = 700      -- ms entre la marche arrière et la marche avant
ADHeaderGateBackTask.SETTLE_TIME = 500     -- ms
ADHeaderGateBackTask.TIMEOUT = 120000      -- ms pour la marche arrière
ADHeaderGateBackTask.FORWARD_TIMEOUT = 40000 -- ms
ADHeaderGateBackTask.BLOCKED = 10000       -- ms avec quelque chose derrière
ADHeaderGateBackTask.CROP_CHECK = 250      -- ms entre deux contrôles des coins
ADHeaderGateBackTask.CROP_SHRINK = 0.3     -- m
ADHeaderGateBackTask.START_ANGLE = 20      -- ° au plus entre la moissonneuse et la route, au départ
ADHeaderGateBackTask.START_SHORT = 3       -- m : il lui manque au plus ça de route après l'entrée
ADHeaderGateBackTask.ALIGN_ANGLE = 2       -- ° : bien dans l'axe de l'entrée, elle n'a pas besoin de reculer jusqu'au bout
ADHeaderGateBackTask.ALIGN_SIDE = 0.3      -- m
ADHeaderGateBackTask.ALIGN_EXTRA = 1       -- m au-delà de sa place d'attente au moins, avant de revenir en avant
ADHeaderGateBackTask.STOP_LEAD = 0.2       -- m
ADHeaderGateBackTask.STEER_LIMIT = 45      -- ° : angle donné au jeu pour le braquage maximum

-- plan : le plan de l'entrée (ADHeaderFlow.gatePlan) ; job : le travail (tracteur, remorque : pas des obstacles)
function ADHeaderGateBackTask:new(vehicle, plan, job)
    local o = ADHeaderGateBackTask:create()
    o.vehicle = vehicle
    o.plan = plan
    o.job = job
    o.result = nil
    return o
end

function ADHeaderGateBackTask:setUp()
    self.state = ADHeaderGateBackTask.STATE_STOPPING
    self.timer = 0
    self.stopped = 0
    self.blocked = 0
    self.cropTimer = 0
    self.index = 1
    self.axleZ = nil
end

function ADHeaderGateBackTask:settle(outcome)
    self.outcome = outcome
    self.timer = 0
    self.state = ADHeaderGateBackTask.STATE_SETTLE
end

-- le chemin de la marche arrière, d'où elle est : true ; false, résultat, raison
function ADHeaderGateBackTask:prepare()
    local plan, v = self.plan, self.vehicle
    local a, q, cosRoute = ADHeaderFlow.gatePose(plan, v)
    local sigma = plan.sigma or (cosRoute >= 0 and 1 or -1)
    if math.abs(q) > ADHeaderFlow.GATE_ROAD_SIDE then
        return false, "badStart", string.format("à %.1f m de l'axe de la route", math.abs(q))
    end
    if sigma * cosRoute < math.cos(math.rad(ADHeaderGateBackTask.START_ANGLE)) then
        return false, "badStart", string.format("à %.0f° de la route", angleOf(sigma * cosRoute))
    end
    local points, short, backTo = ADHeaderFlow.gateBackPath(plan, a, q, sigma)
    if short > ADHeaderGateBackTask.START_SHORT then
        return false, "badStart", string.format("arrêtée %.1f m trop tôt après l'entrée", short)
    end
    local ok, why = ADHeaderFlow.gateGround(self.job ~= nil and self.job.tractor or v, plan, points)
    if not ok then
        return false, "ground", tostring(why)
    end
    self.points = points
    self.backTo = backTo
    self.sigma = sigma
    self.index = 1
    return true
end

-- index du point du chemin le plus proche (il ne recule jamais), m de chemin restants après lui
function ADHeaderGateBackTask:progress(x, z)
    local points = self.points
    local i = self.index
    local best = MathUtil.vector2Length(points[i].x - x, points[i].z - z)
    while i < #points do
        local d = MathUtil.vector2Length(points[i + 1].x - x, points[i + 1].z - z)
        if d > best then
            break
        end
        i, best = i + 1, d
    end
    self.index = i
    return i, (#points - i) * ADHeaderFlow.GATE_STEP
end

-- point visé : LOOK m plus loin sur le chemin, prolongé tout droit dans l'axe de l'entrée après son bout
function ADHeaderGateBackTask:aim(i)
    local points = self.points
    local n = #points
    local steps = math.ceil(ADHeaderGateBackTask.LOOK / ADHeaderFlow.GATE_STEP)
    if i + steps <= n then
        return points[i + steps].x, points[i + steps].z
    end
    local over = (i + steps - n) * ADHeaderFlow.GATE_STEP
    return ADHeaderFlow.gateWorld(self.plan, 0, points[n].q + over)
end

-- m du repère de la machine au milieu de son essieu fixe, le long d'elle, lus sur ses roues (nil : pas lisible)
local function fixedAxleOffset(v)
    local spec = v.spec_wheels
    if spec == nil or spec.wheels == nil then
        return nil
    end
    local root = v.components[1].node
    local fixedZ, fixedCount, steerCount = 0, 0, 0
    for _, wheel in pairs(spec.wheels) do
        local physics = wheel.physics or wheel
        if wheel.node ~= nil and physics.positionX ~= nil then
            local _, _, z = localToLocal(wheel.node, root, physics.positionX, physics.positionY or 0, physics.positionZ or 0)
            if math.max(math.abs(physics.rotMax or 0), math.abs(physics.rotMin or 0)) > 0.05 then
                steerCount = steerCount + 1
            else
                fixedZ, fixedCount = fixedZ + z, fixedCount + 1
            end
        end
    end
    if steerCount == 0 or fixedCount == 0 then
        return nil
    end
    return fixedZ / fixedCount
end

-- le point de la machine qui suit le chemin : le milieu de son essieu fixe (là où elle ne glisse pas de côté ; pour
-- une moissonneuse, l'essieu avant) : le nœud que le jeu y pose, sinon lu sur ses roues, sinon son nœud de direction
function ADHeaderGateBackTask:steerPoint()
    local v = self.vehicle
    local wheels = v.spec_wheels
    if wheels ~= nil and wheels.steeringCenterNode ~= nil and wheels.steeringCenterNode ~= 0 then
        return getWorldTranslation(wheels.steeringCenterNode)
    end
    if self.axleZ == nil then
        self.axleZ = fixedAxleOffset(v) or false
    end
    if self.axleZ ~= false then
        return localToWorld(v.components[1].node, 0, 0, self.axleZ)
    end
    return getWorldTranslation(v.getAIDirectionNode ~= nil and v:getAIDirectionNode() or v.components[1].node)
end

-- un pas de marche arrière vers le point (tx, tz) du chemin, derrière elle.
-- La marche arrière d'AutoDrive pour un véhicule seul (reverseToPoint) braque en proportion de l'angle vers le point
-- visé : sur un quart de cercle presque à son rayon de braquage elle braque trop peu et sort large. Ici le braquage
-- est celui du cercle qui passe par le point visé (courbure 2 x écart de côté / distance²), en part du braquage
-- maximum (rayon de braquage : plan.rig.rc).
function ADHeaderGateBackTask:steerBack(dt, tx, tz, speed)
    local v = self.vehicle
    local sdm = v.ad.specialDrivingModule
    local sx, _, sz = self:steerPoint()
    -- côté et distance du point visé, vus de ce point dans le sens de la machine
    local lx, _, lz = worldDirectionToLocal(v.components[1].node, tx - sx, 0, tz - sz)
    local ld2 = lx * lx + lz * lz
    local curvature = ld2 > 0.01 and 2 * lx / ld2 or 0
    local part = math.max(-1, math.min(1, curvature * self.plan.rig.rc))
    local limit = ADHeaderGateBackTask.STEER_LIMIT
    local theta = math.rad(limit) * math.abs(part)
    -- en marche arrière le jeu inverse le côté : direction donnée à droite = roues braquées à gauche
    local dirX = (part > 0 and -1 or 1) * math.sin(theta)
    sdm:releaseVehicle()
    if v.startMotor ~= nil and v.getIsMotorStarted ~= nil and not v:getIsMotorStarted() and (v.getCanMotorRun == nil or v:getCanMotorRun()) then
        v:startMotor()
    end
    local stored = AutoDrive.smootherDriving
    AutoDrive.smootherDriving = false
    AutoDrive.driveInDirection(v, dt, limit, 0.4, 0.2, limit + 1, true, false, dirX, math.cos(theta), speed, 1)
    AutoDrive.smootherDriving = stored
end

function ADHeaderGateBackTask:update(dt)
    self.timer = self.timer + dt
    local v, plan = self.vehicle, self.plan
    local name = tostring(v.ad.stateModule:getName())
    local sdm = v.ad.specialDrivingModule
    if self.state == ADHeaderGateBackTask.STATE_STOPPING then
        hold(v, dt)
        if math.abs(v.lastSpeedReal or 0) < 0.0003 then
            self.stopped = self.stopped + dt
        else
            self.stopped = 0
        end
        if self.stopped >= ADHeaderGateBackTask.STOP_TIME or self.timer > ADHeaderGateBackTask.STOP_TIMEOUT then
            local ok, result, why = self:prepare()
            if not ok then
                ADAutonomousManager.log("%s : ne se range pas en face de l'entrée du champ (%s)", name, tostring(why))
                self:finish(result)
                return
            end
            self.timer = 0
            self.state = ADHeaderGateBackTask.STATE_REVERSE
            ADAutonomousManager.log("%s : se range en face de l'entrée du champ en marche arrière (%.0f m, rayon %.1f m)", name,
                #self.points * ADHeaderFlow.GATE_STEP, plan.rho)
        end
    elseif self.state == ADHeaderGateBackTask.STATE_REVERSE then
        local a, q, _, cosField = ADHeaderFlow.gatePose(plan, v)
        local sx, _, sz = self:steerPoint()
        local i, left = self:progress(sx, sz)
        local aligned = math.abs(a) <= ADHeaderGateBackTask.ALIGN_SIDE and cosField >= math.cos(math.rad(ADHeaderGateBackTask.ALIGN_ANGLE))
        if (aligned and q >= plan.depth + ADHeaderGateBackTask.ALIGN_EXTRA) or left <= ADHeaderGateBackTask.STOP_LEAD or q >= self.backTo then
            self.timer = 0
            self.state = ADHeaderGateBackTask.STATE_PAUSE
            return
        end
        if self.timer > ADHeaderGateBackTask.TIMEOUT then
            ADAutonomousManager.log("%s : marche arrière en face de l'entrée pas finie en %.0f s (il reste %.1f m)", name, self.timer / 1000, left)
            self:settle("timeout")
            return
        end
        self.cropTimer = self.cropTimer + dt
        if self.cropTimer >= ADHeaderGateBackTask.CROP_CHECK then
            self.cropTimer = 0
            if cornerInCrop(v, ADHeaderGateBackTask.CROP_SHRINK) then
                ADAutonomousManager.log("%s : un coin dans une culture, marche arrière arrêtée à %.1f m de la fin", name, left)
                self:settle("offGround")
                return
            end
        end
        local cdm = v.ad.collisionDetectionModule
        if cdm ~= nil and cdm.checkReverseCollision ~= nil and cdm:checkReverseCollision() then
            self.blocked = self.blocked + dt
            hold(v, dt)
            if self.blocked >= ADHeaderGateBackTask.BLOCKED then
                ADAutonomousManager.log("%s : quelque chose derrière elle, marche arrière arrêtée à %.1f m de la fin", name, left)
                self:settle("blocked")
            end
            return
        end
        self.blocked = 0
        local tx, tz = self:aim(i)
        self:steerBack(dt, tx, tz, left <= ADHeaderGateBackTask.SLOW_DISTANCE and ADHeaderGateBackTask.SLOW or ADHeaderGateBackTask.SPEED)
    elseif self.state == ADHeaderGateBackTask.STATE_PAUSE then
        hold(v, dt)
        if self.timer >= ADHeaderGateBackTask.PAUSE_TIME and math.abs(v.lastSpeedReal or 0) < 0.0003 then
            self.timer = 0
            self.state = ADHeaderGateBackTask.STATE_FORWARD
        end
    elseif self.state == ADHeaderGateBackTask.STATE_FORWARD then
        -- tout droit vers le champ, dans l'axe de l'entrée, jusqu'à sa place d'attente
        local _, q = ADHeaderFlow.gatePose(plan, v)
        local left = q - plan.depth
        if left <= ADHeaderGateBackTask.STOP_LEAD or self.timer > ADHeaderGateBackTask.FORWARD_TIMEOUT then
            self:settle("ok")
            return
        end
        local tx, tz = ADHeaderFlow.gateWorld(plan, 0, q - ADHeaderGateBackTask.FORWARD_LOOK)
        sdm:driveToPoint(dt, { x = tx, y = groundY(tx, tz), z = tz }, 1, false, 0.6,
            math.min(ADHeaderGateBackTask.FORWARD_SPEED, math.max(1.5, left * 1.5)), true)
    elseif self.state == ADHeaderGateBackTask.STATE_SETTLE then
        hold(v, dt)
        if self.timer >= ADHeaderGateBackTask.SETTLE_TIME then
            local outcome = self.outcome or "ok"
            if outcome == "ok" then
                local a, q, _, cosField = ADHeaderFlow.gatePose(plan, v)
                if cosField < math.cos(math.rad(ADHeaderFlow.GATE_POSE_ANGLE)) or math.abs(a) > ADHeaderFlow.GATE_PLACE_ALONG then
                    ADAutonomousManager.log("%s : pas assez droite en face de l'entrée (à %.0f° de son axe, %.1f m de côté)", name, angleOf(cosField), math.abs(a))
                    outcome = "badPose"
                end
            end
            self:finish(outcome)
        end
    end
end

function ADHeaderGateBackTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADHeaderGateBackTask:abort()
end

function ADHeaderGateBackTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_headerGateBack;"
end

-- ============================================================================================================
-- Tracteur : arrêter le cadre de la barre devant la moissonneuse
-- ============================================================================================================
ADHeaderGateInTask = ADInheritsFrom(AbstractTask)

ADHeaderGateInTask.STATE_WAIT = 1
ADHeaderGateInTask.STATE_DRIVE = 2
ADHeaderGateInTask.STATE_SETTLE = 3

ADHeaderGateInTask.SPEED = 5               -- km/h
ADHeaderGateInTask.SLOW = 2                -- km/h sur les derniers mètres
ADHeaderGateInTask.SLOW_DISTANCE = 2.5     -- m
ADHeaderGateInTask.STOP_LEAD = 0.25        -- m : l'arrêt est demandé ça avant la fin (le temps de freiner)
ADHeaderGateInTask.LOOK = 6                -- m : le point visé est ça devant lui, le long de la route
ADHeaderGateInTask.TIMEOUT = 120000        -- ms pour avancer
ADHeaderGateInTask.BLOCKED = 15000         -- ms à l'arrêt
ADHeaderGateInTask.STILL = 0.3             -- km/h
ADHeaderGateInTask.SETTLE_TIME = 500       -- ms

function ADHeaderGateInTask:new(vehicle, job, plan)
    local o = ADHeaderGateInTask:create()
    o.vehicle = vehicle
    o.job = job
    o.plan = plan
    o.result = nil
    return o
end

function ADHeaderGateInTask:setUp()
    self.state = ADHeaderGateInTask.STATE_WAIT
    self.timer = 0
    self.still = 0
end

function ADHeaderGateInTask:settle(outcome)
    self.outcome = outcome
    self.timer = 0
    self.state = ADHeaderGateInTask.STATE_SETTLE
end

-- m que le cadre de la barre doit encore faire le long de la route pour être dans l'axe de la moissonneuse
function ADHeaderGateInTask:left()
    local job, stop = self.job, self.stop
    local frame = ADAutonomousManager.frontHitch(job.combine, job.header, true)
    if frame == nil then
        return nil
    end
    return -((frame.x - stop.cx) * stop.wx + (frame.z - stop.cz) * stop.wz)
end

function ADHeaderGateInTask:update(dt)
    self.timer = self.timer + dt
    local v, job, plan = self.vehicle, self.job, self.plan
    local name = tostring(v.ad.stateModule:getName())
    local sdm = v.ad.specialDrivingModule
    if self.state == ADHeaderGateInTask.STATE_WAIT then
        hold(v, dt)
        if job.cancelled or job.gate ~= plan then
            self:finish("cancelled")
            return
        end
        if not job.gateReady then
            if self.timer > ADHeaderFlow.GATE_WAIT then
                ADAutonomousManager.log("%s : la moissonneuse n'est pas en place en face de l'entrée après %.0f s", name, self.timer / 1000)
                self:finish("cancelled")
            end
            return
        end
        local stop, why = ADHeaderFlow.gateStop(plan, v, job)
        if stop == nil then
            ADAutonomousManager.log("%s : pas de barre arrêtée devant la moissonneuse (%s)", name, tostring(why))
            self:finish("cancelled")
            return
        end
        self.stop = stop
        local left = self:left()
        if left == nil then
            self:finish("noFrame")
            return
        end
        self.timer = 0
        self.state = ADHeaderGateInTask.STATE_DRIVE
        ADAutonomousManager.log("%s : la moissonneuse est en place, avance le cadre de la barre jusque devant elle (%.1f m%s)", name, left,
            stop.offset > 0 and string.format(", décalé de %.1f m vers le champ", stop.offset) or "")
    elseif self.state == ADHeaderGateInTask.STATE_DRIVE then
        local left = self:left()
        if left == nil then
            self:settle("noFrame")
            return
        end
        if left <= ADHeaderGateInTask.STOP_LEAD then
            self:settle("ok")
            return
        end
        if self.timer > ADHeaderGateInTask.TIMEOUT then
            ADAutonomousManager.log("%s : cadre de la barre pas arrivé devant la moissonneuse en %.0f s (il reste %.1f m)", name, self.timer / 1000, left)
            self:settle("timeout")
            return
        end
        if math.abs(v.lastSpeedReal or 0) * 3600 < ADHeaderGateInTask.STILL and self.timer > 3000 then
            self.still = self.still + dt
            if self.still > ADHeaderGateInTask.BLOCKED then
                ADAutonomousManager.log("%s : arrêté à %.1f m de la fin, quelque chose devant lui", name, left)
                self:settle("blocked")
                return
            end
        else
            self.still = 0
        end
        -- point visé : devant lui le long de la route, décalé vers le champ
        local a = ADHeaderFlow.gatePose(plan, v)
        local tx, tz = ADHeaderFlow.gateWorld(plan, a + ADHeaderGateInTask.LOOK, -self.stop.offset)
        local speed = left <= ADHeaderGateInTask.SLOW_DISTANCE and ADHeaderGateInTask.SLOW or ADHeaderGateInTask.SPEED
        sdm:driveToPoint(dt, { x = tx, y = groundY(tx, tz), z = tz }, 1, true, 0.6, speed, true)
    elseif self.state == ADHeaderGateInTask.STATE_SETTLE then
        hold(v, dt)
        if self.timer >= ADHeaderGateInTask.SETTLE_TIME then
            self:finish(self.outcome or "ok")
        end
    end
end

function ADHeaderGateInTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADHeaderGateInTask:abort()
end

function ADHeaderGateInTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_headerGateIn;"
end
