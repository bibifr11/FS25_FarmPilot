-- ============================================================================================================
-- FarmPilot : HeaderBackInTask.lua
-- Mode Autonome, moissonneuse équipée seule : tâche du tracteur « reculer la remorque porte-barre dans l'entrée du
-- champ ». Le tracteur est arrêté sur le chemin, l'entrée dépassée ; il recule en poussant la remorque le long d'un
-- axe en biais qui entre dans le champ.
--
-- Règle (12/11) :
-- - La marche arrière est celle de FarmPilot avec une remorque (ADSpecialDrivingModule:reverseToPoint) : elle vise
--   un point de l'axe, BACKIN_LOOK m plus loin que l'essieu de la remorque (projeté sur l'axe) ; la remorque rejoint
--   l'axe et s'aligne dessus en reculant.
-- - Remorque à avant-train tournant : l'avant-train est bloqué droit le temps de la marche arrière, puis libéré
--   (même réglage qu'AutoDrive pour une 2e remorque : ADTrailerModule:handleTrailerReversing).
-- - Fini quand l'essieu de la remorque est au bout de l'axe. Arrêt avant : tracteur et remorque trop de travers
--   (BACKIN_MAX_HITCH), quelque chose derrière pendant BACKIN_BLOCKED ms, plus de BACKIN_TIMEOUT ms.
-- - Le tracteur n'est pas où le plan l'attend (route recalculée en chemin) : rien n'est fait (« badStart »).
-- - (16/11) Bloquée sans avancer : l'essieu ne gagne pas STUCK_PROGRESS m sur l'axe pendant
--   ADHeaderFlow.BACKIN_STUCK ms (tracteur ou remorque contre un objet fixe que le capteur arrière ne voit pas :
--   muret bas, nez du tracteur contre une clôture) : arrêt (« stuck »), sans attendre la fin du temps.
-- - (16/11) Même tâche pour la barre reculée en travers du chemin (plan.cross, AutonomousHeaderCross.lua) : seul
--   le texte de la tâche change.
-- - Le résultat (self.result : « ok », « badStart », « noTrailer », « jackknife », « blocked », « timeout »,
--   « stuck ») est lu par Modes/AutonomousHeaderBackIn.lua (backInDone).
--
-- Branché par : Modes/AutonomousHeaderBackIn.lua (startBackIn). Chargé par register.lua après HeaderDropTask.lua.
-- ============================================================================================================

ADHeaderBackInTask = ADInheritsFrom(AbstractTask)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderBackInTask.STATE_STOPPING = 1
ADHeaderBackInTask.STATE_REVERSE = 2
ADHeaderBackInTask.STATE_SETTLE = 3

ADHeaderBackInTask.STOP_TIME = 800         -- ms arrêté avant de reculer
ADHeaderBackInTask.STOP_TIMEOUT = 8000     -- ms pour s'arrêter
ADHeaderBackInTask.SETTLE_TIME = 1200      -- ms arrêté à la fin, avant de libérer l'avant-train
ADHeaderBackInTask.START_SIDE = 2.5        -- m d'écart au chemin accepté pour l'essieu de la remorque, au départ
ADHeaderBackInTask.START_ANGLE = 20        -- ° d'écart au chemin accepté pour la remorque, au départ
ADHeaderBackInTask.START_ALONG = 5         -- m d'écart accepté le long du chemin, au départ
ADHeaderBackInTask.STUCK_PROGRESS = 0.3    -- (16/11) m sur l'axe à gagner pendant ADHeaderFlow.BACKIN_STUCK ms

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
-- plan : { qx, qz (l'axe coupe la ligne où le tracteur s'est arrêté, sur le chemin), ax, az (sens de l'axe, vers le champ), ux, uz (sens du
-- chemin), reach (m de l'essieu sur l'axe à la fin), start (m de l'essieu après qx, qz au départ) }
function ADHeaderBackInTask:new(vehicle, trailer, plan)
    local o = ADHeaderBackInTask:create()
    o.vehicle = vehicle
    o.trailer = trailer
    o.plan = plan
    o.result = nil
    return o
end

function ADHeaderBackInTask:setUp()
    self.state = ADHeaderBackInTask.STATE_STOPPING
    self.timer = 0
    self.total = 0
    self.blocked = 0
    self.stopped = 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Avant-train tournant bloqué / libéré
-- ------------------------------------------------------------------------------------------------------------
-- articulation de l'avant-train : celle qui ne tourne qu'autour de l'axe vertical (comme
-- ADTrailerModule:handleTrailerReversing)
function ADHeaderBackInTask:lockDolly(lock)
    local trailer = self.trailer
    if trailer == nil or trailer.componentJoints == nil or trailer.setComponentJointRotLimit == nil then
        return
    end
    if self.dolly == nil then
        self.dolly = false
        for index, joint in pairs(trailer.componentJoints) do
            local limit = joint.rotLimit
            if limit ~= nil and limit[1] == 0 and (limit[2] or 0) ~= 0 and limit[3] == 0 then
                self.dolly = { index = index, limit = limit[2] }
                break
            end
        end
    end
    if self.dolly == false or self.dollyLocked == lock then
        return
    end
    self.dollyLocked = lock
    local joint = trailer.componentJoints[self.dolly.index]
    if lock then
        trailer:setComponentJointRotLimit(joint, 2, 0, 0)
    else
        trailer:setComponentJointRotLimit(joint, 2, -self.dolly.limit, self.dolly.limit)
    end
    ADAutonomousManager.log("%s : avant-train de « %s » %s", tostring(self.vehicle.ad.stateModule:getName()),
        ADAutonomousManager.toolLabel ~= nil and tostring(ADAutonomousManager.toolLabel(trailer)) or "la remorque", lock and "bloqué pour la marche arrière" or "libéré")
end

-- ------------------------------------------------------------------------------------------------------------
-- Où est l'essieu de la remorque par rapport à l'axe
-- ------------------------------------------------------------------------------------------------------------
-- essieu de la remorque (point que la marche arrière de FarmPilot conduit) : le nœud, x, y, z ; nil = pas de
-- remorque à pousser
function ADHeaderBackInTask:axle()
    local sdm = self.vehicle.ad.specialDrivingModule
    local node = sdm:getReverseNode()
    if node == nil or sdm.reverseSolo then
        return nil
    end
    local x, y, z = getWorldTranslation(node)
    return node, x, y, z
end

-- départ : la remorque est sur le chemin, à peu près dans son sens, l'entrée dépassée d'à peu près ce que le plan
-- attend
function ADHeaderBackInTask:isStartOk(node, x, z)
    local p = self.plan
    local ox, oz = x - p.qx, z - p.qz
    local along = ox * p.ux + oz * p.uz
    local side = math.abs(ox * p.uz - oz * p.ux)
    local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
    local len = MathUtil.vector2Length(fx, fz)
    if len < 0.001 then
        return false, "sens de la remorque inconnu"
    end
    local cosA = (fx * p.ux + fz * p.uz) / len
    if side > ADHeaderBackInTask.START_SIDE then
        return false, string.format("remorque à %.1f m du chemin", side)
    end
    if cosA < math.cos(math.rad(ADHeaderBackInTask.START_ANGLE)) then
        return false, string.format("remorque à %.0f° du chemin", math.deg(math.acos(math.max(-1, math.min(1, cosA)))))
    end
    if math.abs(along - p.start) > ADHeaderBackInTask.START_ALONG then
        return false, string.format("essieu à %.1f m du point où la remorque quitte le chemin, %.1f m attendus", along, p.start)
    end
    return true, nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Déroulé
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderBackInTask:hold(dt)
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm:stopVehicle()
    sdm:update(dt)
end

function ADHeaderBackInTask:update(dt)
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
                ADAutonomousManager.log("%s : pas de remorque à pousser, pas de marche arrière dans le champ", name)
                self:finish("noTrailer")
                return
            end
            local ok, why = self:isStartOk(node, x, z)
            if not ok then
                ADAutonomousManager.log("%s : pas en place pour reculer dans le champ (%s)", name, tostring(why))
                self:finish("badStart")
                return
            end
            self:lockDolly(true)
            self.timer = 0
            self.progress, self.progressTime = nil, 0
            self.state = ADHeaderBackInTask.STATE_REVERSE
            ADAutonomousManager.log("%s : recule la remorque %s (%.1f m sur l'axe)", name, self.plan.cross and "en travers du chemin" or "dans l'entrée du champ", self.plan.reach)
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

function ADHeaderBackInTask:settle(outcome)
    self.outcome = outcome
    self.timer = 0
    self.state = ADHeaderBackInTask.STATE_SETTLE
end

function ADHeaderBackInTask:updateReverse(dt, name)
    local p = self.plan
    local sdm = self.vehicle.ad.specialDrivingModule
    local node, x, y, z = self:axle()
    if node == nil then
        self:settle("noTrailer")
        return
    end
    local along = (x - p.qx) * p.ax + (z - p.qz) * p.az
    if along >= p.reach then
        ADAutonomousManager.log("%s : remorque reculée %s (%.0f s)", name, p.cross and "en travers du chemin" or "dans le champ", self.timer / 1000)
        self:settle("ok")
        return
    end
    if self.timer > ADHeaderFlow.BACKIN_TIMEOUT then
        ADAutonomousManager.log("%s : marche arrière dans le champ pas finie en %.0f s (%.1f m sur %.1f)", name, self.timer / 1000, along, p.reach)
        self:settle("timeout")
        return
    end
    -- (16/11) l'essieu n'avance plus sur l'axe : bloquée (objet fixe)
    if self.progress == nil or along > self.progress + ADHeaderBackInTask.STUCK_PROGRESS then
        self.progress, self.progressTime = along, 0
    else
        self.progressTime = self.progressTime + dt
        if self.progressTime >= (ADHeaderFlow.BACKIN_STUCK or 20000) then
            ADAutonomousManager.log("%s : marche arrière bloquée depuis %.0f s sans avancer (%.1f m sur %.1f), arrêt", name, self.progressTime / 1000, along, p.reach)
            self:settle("stuck")
            return
        end
    end
    -- point visé : sur l'axe, plus loin que l'essieu
    local aim = along + ADHeaderFlow.BACKIN_LOOK
    sdm.reverseNode = node
    sdm.reverseTarget = { x = p.qx + p.ax * aim, y = y, z = p.qz + p.az * aim }
    sdm.currentWayPointIndex = 0
    sdm.wayPoints = {}
    sdm:getBasicStates()
    if math.abs(sdm.angleToTrailer or 0) > ADHeaderFlow.BACKIN_MAX_HITCH then
        ADAutonomousManager.log("%s : tracteur et remorque trop de travers (%.0f°), marche arrière arrêtée", name, math.abs(sdm.angleToTrailer))
        self:settle("jackknife")
        return
    end
    local cdm = self.vehicle.ad.collisionDetectionModule
    if cdm ~= nil and cdm.checkReverseCollision ~= nil and cdm:checkReverseCollision() then
        self.blocked = self.blocked + dt
        self:hold(dt)
        if self.blocked >= ADHeaderFlow.BACKIN_BLOCKED then
            ADAutonomousManager.log("%s : quelque chose derrière la remorque, marche arrière arrêtée", name)
            self:settle("blocked")
        end
        return
    end
    self.blocked = 0
    sdm:reverseToPoint(dt, ADHeaderFlow.BACKIN_SPEED)
end

function ADHeaderBackInTask:finish(result)
    if self.result ~= nil then
        return
    end
    self:lockDolly(false)
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADHeaderBackInTask:abort()
    self:lockDolly(false)
end

function ADHeaderBackInTask:getI18nInfo()
    if self.plan ~= nil and self.plan.cross then
        return "$l10n_AD_task_autonomous_headerCross;"
    end
    return "$l10n_AD_task_autonomous_headerBackIn;"
end
