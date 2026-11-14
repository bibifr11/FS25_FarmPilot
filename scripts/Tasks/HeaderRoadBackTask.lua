-- ============================================================================================================
-- FarmPilot : HeaderRoadBackTask.lua
-- Mode Autonome, moissonneuse équipée seule : tâche du tracteur « reculer la remorque porte-barre tout droit jusqu'à
-- la route ». Le tracteur est arrêté sur le chemin du champ, le croisement derrière lui ; il recule dans l'axe du
-- chemin jusqu'à ce que le cadre de la barre soit sur la route, face à la moissonneuse qui arrive par là.
--
-- Règle (13/11) :
-- - Même marche arrière que pour l'entrée du champ (Tasks/HeaderBackInTask.lua, dont cette tâche reprend l'arrêt,
--   le contrôle du départ, l'avant-train bloqué et la fin) : elle vise un point de l'axe du chemin, BACKIN_LOOK m
--   derrière l'essieu de la remorque. Ici l'axe est celui du chemin : la remorque ne tourne pas.
-- - La distance à reculer est mesurée au départ sur le vrai cadre de la barre (où il est le long du chemin), pas sur
--   le plan : fin quand il est sur l'axe de la route. Les ROADBACK_SLOW_DISTANCE derniers mètres se font à
--   ROADBACK_SLOW km/h, l'arrêt est demandé ROADBACK_STOP_LEAD m avant (le temps de freiner).
-- - Au départ la remorque doit être presque dans l'axe du chemin (ROADBACK_START_SIDE m, ROADBACK_START_ANGLE °,
--   plus serré que pour la marche arrière en biais : il y a de la culture des deux côtés). Sinon, tracteur pas où le
--   plan l'attend, cadre trop loin de la route, ou un coin déjà dans une culture : rien n'est fait (« badStart »).
-- - Arrêt avant la fin : tracteur et remorque trop de travers (ROADBACK_MAX_HITCH), un coin du tracteur ou de la
--   remorque dans une culture (« offLane », contrôlé toutes les ROADBACK_CROP_CHECK ms), quelque chose derrière
--   pendant BACKIN_BLOCKED ms, plus de BACKIN_TIMEOUT ms.
-- - Le résultat (self.result : « ok », « badStart », « noTrailer », « jackknife », « offLane », « blocked »,
--   « timeout ») est lu par Modes/AutonomousHeaderRoadBack.lua (roadBackDone).
--
-- Branché par : Modes/AutonomousHeaderRoadBack.lua (startBackIn enveloppé). Chargé par register.lua après
-- HeaderBackInTask.lua.
-- ============================================================================================================

ADHeaderRoadBackTask = ADInheritsFrom(ADHeaderBackInTask)

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
-- plan : { qx, qz (le croisement : l'axe du chemin coupe l'axe de la route), ux, uz (sens du chemin, du croisement
-- vers le champ), start (m de l'essieu de la remorque après le croisement, attendus au départ), reach (m de recul
-- attendus), frameAt (m après le croisement où le cadre de la barre s'arrête) } ; job : pour le vrai cadre
function ADHeaderRoadBackTask:new(vehicle, trailer, plan, job)
    local o = ADHeaderRoadBackTask:create()
    o.vehicle = vehicle
    o.trailer = trailer
    o.plan = plan
    o.job = job
    o.result = nil
    return o
end

-- ------------------------------------------------------------------------------------------------------------
-- Culture au bord du chemin
-- ------------------------------------------------------------------------------------------------------------
-- un coin de ce véhicule (pris ROADBACK_CROP_SHRINK m en dedans) est dans une culture ?
local function cornerInCrop(v)
    if v == nil or v.components == nil or ADFieldPark == nil or ADFieldPark.hasGrowingCrop == nil then
        return false
    end
    local node = v.components[1].node
    local size = v.size or {}
    local shrink = ADHeaderFlow.ROADBACK_CROP_SHRINK
    local halfW = math.max((size.width or 2.6) / 2 - shrink, 0.5)
    local halfL = math.max((size.length or 6) / 2 - shrink, 0.5)
    local ox, oz = size.widthOffset or 0, size.lengthOffset or 0
    for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
        local x, _, z = localToWorld(node, ox + c[1] * halfW, 0, oz + c[2] * halfL)
        if ADFieldPark.hasGrowingCrop(x, z) == true then
            return true
        end
    end
    return false
end

function ADHeaderRoadBackTask:inCrop()
    return cornerInCrop(self.vehicle) or cornerInCrop(self.trailer)
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ : remorque presque dans l'axe du chemin
-- ------------------------------------------------------------------------------------------------------------
local baseIsStartOk = ADHeaderBackInTask.isStartOk
function ADHeaderRoadBackTask:isStartOk(node, x, z)
    local ok, why = baseIsStartOk(self, node, x, z)
    if not ok then
        return false, why
    end
    local p = self.plan
    local ox, oz = x - p.qx, z - p.qz
    local side = math.abs(ox * p.uz - oz * p.ux)
    if side > ADHeaderFlow.ROADBACK_START_SIDE then
        return false, string.format("remorque à %.1f m du milieu du chemin", side)
    end
    local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
    local len = MathUtil.vector2Length(fx, fz)
    local cosA = (fx * p.ux + fz * p.uz) / len
    if cosA < math.cos(math.rad(ADHeaderFlow.ROADBACK_START_ANGLE)) then
        return false, string.format("remorque à %.0f° du chemin", math.deg(math.acos(math.max(-1, math.min(1, cosA)))))
    end
    if self:inCrop() then
        return false, "un coin du tracteur ou de la remorque dans une culture"
    end
    return true, nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Combien reculer
-- ------------------------------------------------------------------------------------------------------------
-- l'essieu est à (x, z) : où il doit finir le long du chemin (self.axleEnd, m après le croisement), d'après le vrai
-- cadre de la barre ; false, raison quand le cadre n'est pas où le plan l'attend
function ADHeaderRoadBackTask:measure(x, z)
    local p = self.plan
    local axle = (x - p.qx) * p.ux + (z - p.qz) * p.uz
    local travel = p.reach
    local job = self.job
    local hitch = job ~= nil and ADAutonomousManager.frontHitch(job.combine, job.header, true) or nil
    if hitch ~= nil then
        travel = (hitch.x - p.qx) * p.ux + (hitch.z - p.qz) * p.uz - (p.frameAt or 0)
    end
    if travel > p.reach + ADHeaderBackInTask.START_ALONG + 2 or travel < -2 then
        return false, string.format("cadre de la barre à %.1f m de la route, %.1f m attendus", travel, p.reach)
    end
    self.travel = math.max(0, travel)
    self.axleEnd = axle - self.travel
    return true, nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Déroulé
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderRoadBackTask:update(dt)
    self.timer = self.timer + dt
    self.total = self.total + dt
    local name = tostring(self.vehicle.ad.stateModule:getName())
    if self.state == ADHeaderBackInTask.STATE_STOPPING then
        self:hold(dt)
        if math.abs(self.vehicle.lastSpeedReal or 0) < 0.0003 then
            self.stopped = self.stopped + dt
        else
            self.stopped = 0
        end
        if self.stopped >= ADHeaderBackInTask.STOP_TIME or self.timer > ADHeaderBackInTask.STOP_TIMEOUT then
            local node, x, _, z = self:axle()
            if node == nil then
                ADAutonomousManager.log("%s : pas de remorque à pousser, pas de recul jusqu'à la route", name)
                self:finish("noTrailer")
                return
            end
            local ok, why = self:isStartOk(node, x, z)
            if ok then
                ok, why = self:measure(x, z)
            end
            if not ok then
                ADAutonomousManager.log("%s : pas en place pour reculer jusqu'à la route (%s)", name, tostring(why))
                self:finish("badStart")
                return
            end
            self:lockDolly(true)
            self.timer = 0
            self.state = ADHeaderBackInTask.STATE_REVERSE
            ADAutonomousManager.log("%s : recule la remorque tout droit jusqu'à la route (%.1f m)", name, self.travel)
        end
    elseif self.state == ADHeaderBackInTask.STATE_REVERSE then
        self:updateReverse(dt, name)
    elseif self.state == ADHeaderBackInTask.STATE_SETTLE then
        self:hold(dt)
        if self.timer >= ADHeaderBackInTask.SETTLE_TIME then
            self:finish(self.outcome or "ok")
        end
    end
end

function ADHeaderRoadBackTask:updateReverse(dt, name)
    local p = self.plan
    local sdm = self.vehicle.ad.specialDrivingModule
    local node, x, y, z = self:axle()
    if node == nil then
        self:settle("noTrailer")
        return
    end
    -- m que l'essieu doit encore reculer le long du chemin
    local axle = (x - p.qx) * p.ux + (z - p.qz) * p.uz
    local left = axle - self.axleEnd
    if left <= ADHeaderFlow.ROADBACK_STOP_LEAD then
        ADAutonomousManager.log("%s : remorque reculée jusqu'à la route (%.0f s)", name, self.timer / 1000)
        self:settle("ok")
        return
    end
    if self.timer > ADHeaderFlow.BACKIN_TIMEOUT then
        ADAutonomousManager.log("%s : recul jusqu'à la route pas fini en %.0f s (il reste %.1f m sur %.1f)", name, self.timer / 1000, left, self.travel)
        self:settle("timeout")
        return
    end
    -- point visé : sur l'axe du chemin, derrière l'essieu (vers la route et au-delà)
    local aim = axle - ADHeaderFlow.BACKIN_LOOK
    sdm.reverseNode = node
    sdm.reverseTarget = { x = p.qx + p.ux * aim, y = y, z = p.qz + p.uz * aim }
    sdm.currentWayPointIndex = 0
    sdm.wayPoints = {}
    sdm:getBasicStates()
    if math.abs(sdm.angleToTrailer or 0) > ADHeaderFlow.ROADBACK_MAX_HITCH then
        ADAutonomousManager.log("%s : tracteur et remorque trop de travers (%.0f°), recul arrêté à %.1f m de la route", name, math.abs(sdm.angleToTrailer), left)
        self:settle("jackknife")
        return
    end
    self.cropTimer = (self.cropTimer or 0) + dt
    if self.cropTimer >= ADHeaderFlow.ROADBACK_CROP_CHECK then
        self.cropTimer = 0
        if self:inCrop() then
            ADAutonomousManager.log("%s : un coin du tracteur ou de la remorque dans la culture au bord du chemin, recul arrêté à %.1f m de la route", name, left)
            self:settle("offLane")
            return
        end
    end
    local cdm = self.vehicle.ad.collisionDetectionModule
    if cdm ~= nil and cdm.checkReverseCollision ~= nil and cdm:checkReverseCollision() then
        self.blocked = self.blocked + dt
        self:hold(dt)
        if self.blocked >= ADHeaderFlow.BACKIN_BLOCKED then
            ADAutonomousManager.log("%s : quelque chose derrière la remorque, recul arrêté à %.1f m de la route", name, left)
            self:settle("blocked")
        end
        return
    end
    self.blocked = 0
    local speed = left <= ADHeaderFlow.ROADBACK_SLOW_DISTANCE and ADHeaderFlow.ROADBACK_SLOW or ADHeaderFlow.ROADBACK_SPEED
    sdm:reverseToPoint(dt, speed)
end

function ADHeaderRoadBackTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_headerRoadBack;"
end
