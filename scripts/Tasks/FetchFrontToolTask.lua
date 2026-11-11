-- ============================================================================================================
-- FarmPilot : FetchFrontToolTask.lua
-- Mode Autonome : tâche « aller atteler l'outil AVANT (outil frontal ou masse) », comme le joueur. Même tâche que
-- FetchToolTask.lua, en marche avant.
--
-- Règle (10/11) :
-- - Le tracteur se place en face de l'outil, le nez vers lui, dans son axe (recherche de chemin de FarmPilot), puis
--   avance vers son point d'attelage jusqu'à ce que le jeu puisse atteler (attelage avant du tracteur).
-- - Arrivé par la route de la place de l'outil, outil à portée : il avance tout de suite vers son point
--   d'attelage, même si l'outil a un peu bougé.
-- - Derniers HITCH_AIM m : il vise le point d'attelage lui-même.
-- - Attelage raté : il recule tout droit et recommence, au plus RETRIES fois (puis la règle d'avant, comme
--   l'attelage arrière).
-- - Pas de chemin, mod d'attelage manuel, outil relevé pour la route : comme FetchToolTask.lua.
--
-- Branché par : Modes/AutonomousFront.lua (startFetch avec le côté « front » : ADFetchFrontToolTask:new ; route vers
-- l'outil : readyFor).
-- ============================================================================================================

ADFetchFrontToolTask = ADInheritsFrom(ADFetchToolTask)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFetchFrontToolTask.APPROACH_TEXT = "marche avant"
ADFetchFrontToolTask.BACK_SPEED = 4      -- km/h en reculant pour un nouvel essai

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
function ADFetchFrontToolTask:new(vehicle, tool, direct)
    local o = ADFetchFrontToolTask:create()
    o.vehicle = vehicle
    o.tool = tool
    o.direct = direct == true
    o.result = nil
    o.side = "front"
    return o
end

-- ------------------------------------------------------------------------------------------------------------
-- Points d'attelage, place en face de l'outil
-- ------------------------------------------------------------------------------------------------------------
-- attelage avant du tracteur et point d'attelage de l'outil (positions monde) ; nil si l'outil ne va plus
function ADFetchFrontToolTask:getJoints()
    local _, joint = ADAutonomousManager.matchFrontJoints(self.vehicle, self.tool, true)
    if joint == nil or joint.jointTransform == nil then
        return nil
    end
    local ax, ay, az = getWorldTranslation(joint.jointTransform)
    local hitch = ADAutonomousManager.frontHitch(self.vehicle, self.tool)
    if hitch == nil then
        return nil
    end
    return { x = ax, y = ay, z = az }, hitch
end

function ADFetchFrontToolTask:matchPair()
    return ADAutonomousManager.matchFrontJoints(self.vehicle, self.tool, true)
end

-- au bout du chemin, le nez vers l'outil
function ADFetchFrontToolTask:pathHeading(hitch)
    return { x = -hitch.dirX, z = -hitch.dirZ }
end

-- déjà en face de l'outil, dans son axe, le nez vers lui : on avance tout de suite
function ADFetchFrontToolTask.isReady(vehicle, hitch)
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local fx, _, fz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local ox, oz = vx - hitch.x, vz - hitch.z
    local along = ox * hitch.dirX + oz * hitch.dirZ
    local lateral = math.abs(ox * hitch.dirZ - oz * hitch.dirX)
    local len = MathUtil.vector2Length(fx, fz)
    if len < 0.001 then
        return false
    end
    local cosA = -(fx * hitch.dirX + fz * hitch.dirZ) / len
    return along > 0 and along <= ADFetchToolTask.READY_MAX and lateral <= ADFetchToolTask.READY_LATERAL
        and cosA >= math.cos(math.rad(ADFetchToolTask.READY_ANGLE))
end

function ADFetchFrontToolTask:isReadyToReverse(hitch)
    return ADFetchFrontToolTask.isReady(self.vehicle, hitch)
end

-- le point d'attelage de l'outil est devant l'attelage avant du tracteur (ax, az), à portée d'une marche avant qui le
-- vise directement
function ADFetchFrontToolTask.isReachable(vehicle, hitch, ax, az)
    local fx, _, fz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local len = MathUtil.vector2Length(fx, fz)
    if len < 0.001 then
        return false
    end
    fx, fz = fx / len, fz / len
    local dx, dz = hitch.x - ax, hitch.z - az
    local distance = MathUtil.vector2Length(dx, dz)
    local ahead = dx * fx + dz * fz
    local side = math.abs(dx * fz - dz * fx)
    local cosA = -(fx * hitch.dirX + fz * hitch.dirZ)
    return distance <= ADFetchToolTask.DIRECT_MAX and ahead > -ADFetchToolTask.DIRECT_SIDE
        and side <= math.max(ADFetchToolTask.DIRECT_SIDE, distance * math.sin(math.rad(ADFetchToolTask.DIRECT_BEARING)))
        and cosA >= math.cos(math.rad(ADFetchToolTask.DIRECT_ANGLE))
end

function ADFetchFrontToolTask:isReachableFrom(hitch, ax, az)
    return ADFetchFrontToolTask.isReachable(self.vehicle, hitch, ax, az)
end

-- pour la route vers l'outil (AutonomousFront.lua) : prêt à avancer ?, distance entre les points d'attelage, à portée ?
function ADFetchFrontToolTask.readyFor(vehicle, tool)
    local _, joint = ADAutonomousManager.matchFrontJoints(vehicle, tool, true)
    local hitch = ADAutonomousManager.frontHitch(vehicle, tool)
    if hitch == nil or joint == nil or joint.jointTransform == nil then
        return false, nil, false
    end
    local ax, _, az = getWorldTranslation(joint.jointTransform)
    return ADFetchFrontToolTask.isReady(vehicle, hitch), MathUtil.vector2Length(ax - hitch.x, az - hitch.z),
        ADFetchFrontToolTask.isReachable(vehicle, hitch, ax, az)
end

-- ------------------------------------------------------------------------------------------------------------
-- Marche avant vers l'outil (état STATE_REVERSE de la tâche d'origine), nouvel essai en reculant (STATE_FORWARD)
-- ------------------------------------------------------------------------------------------------------------
function ADFetchFrontToolTask:updateReverse(dt)
    local joint, hitch = self:getJoints()
    if joint == nil then
        self:holdVehicle(dt)
        self:finish("noJoint")
        return
    end
    local distance = MathUtil.vector2Length(joint.x - hitch.x, joint.z - hitch.z)
    -- passé à côté ou au-delà du point d'attelage (dans l'outil)
    local past = (joint.x - hitch.x) * hitch.dirX + (joint.z - hitch.z) * hitch.dirZ < -ADFetchToolTask.MISS_MARGIN
    if distance < self.minDistance then
        self.minDistance = distance
    end
    -- (11/11) comme à l'arrière : le tracteur bute contre l'outil avant ATTACH_RANGE, on attelle si le jeu le permet
    local stalled, blocked = self:updateStall(dt, distance)
    if distance <= ADFetchToolTask.ATTACH_RANGE or stalled then
        if distance <= ADFetchToolTask.ATTACH_RANGE then
            self:holdVehicle(dt)
        end
        if self:tryAttach(distance) then
            return
        end
    end
    if blocked then
        self:logBlocked(distance)
    end
    if past or blocked or (self.minDistance < 3 and distance > self.minDistance + ADFetchToolTask.MISS_MARGIN) then
        self:holdVehicle(dt)
        if self.retries < ADFetchToolTask.RETRIES then
            self.retries = self.retries + 1
            ADAutonomousManager.log("%s : attelage avant raté (au plus près %.2f m), on recule et on recommence (%d/%d)", tostring(self.vehicle.ad.stateModule:getName()), self.minDistance, self.retries, ADFetchToolTask.RETRIES)
            self:setState(ADFetchToolTask.STATE_FORWARD)
            return
        end
        if self.aimHitch then
            self.aimHitch = false
            self.retries = 0
            ADAutonomousManager.log("%s : attelage avant raté en visant le point d'attelage (au plus près %.2f m), on repasse en face de l'outil", tostring(self.vehicle.ad.stateModule:getName()), self.minDistance)
            self:setState(ADFetchToolTask.STATE_PLAN)
            return
        end
        ADAutonomousManager.log("%s : attelage avant raté (au plus près %.2f m, maintenant %.2f m)", tostring(self.vehicle.ad.stateModule:getName()), self.minDistance, distance)
        self:finish("missed")
        return
    end
    if self.timer > ADFetchToolTask.REVERSE_TIMEOUT then
        self:holdVehicle(dt)
        self:finish("timeout")
        return
    end
    if distance <= ADFetchToolTask.ATTACH_RANGE then
        self:approach(dt, hitch, joint, 1, distance)
    else
        self:approach(dt, hitch, joint, math.min(5, math.max(1.5, distance * 0.6)), distance)
    end
end

-- l'outil en face n'est pas un obstacle : pas de contrôle de collision (l'outil est exclu à partir de l'arrêt)
function ADFetchFrontToolTask:approach(dt, hitch, joint, maxSpeed, distance)
    local target
    if self.aimHitch or distance <= ADFetchToolTask.HITCH_AIM then
        -- derniers mètres, ou outil qui a bougé : le point d'attelage lui-même (l'attelage avant est devant le
        -- tracteur, dans son axe : il y arrive en le visant)
        target = { x = hitch.x, y = hitch.y, z = hitch.z }
    else
        -- point de l'axe de l'outil, LOOK_AHEAD m devant l'attelage avant (projeté sur l'axe) : le tracteur rejoint
        -- l'axe et s'aligne dessus en avançant
        local along = (joint.x - hitch.x) * hitch.dirX + (joint.z - hitch.z) * hitch.dirZ
        local aim = math.max(along - ADFetchToolTask.LOOK_AHEAD, -ADFetchToolTask.AIM_BEHIND)
        target = { x = hitch.x + hitch.dirX * aim, y = hitch.y, z = hitch.z + hitch.dirZ * aim }
    end
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, target, 1, false, 0.6, maxSpeed, true)
end

-- attelage raté : on recule tout droit (dans l'axe du tracteur), assez loin pour revenir droit, puis on recommence
function ADFetchFrontToolTask:updateForward(dt)
    local joint, hitch = self:getJoints()
    if hitch == nil then
        self:holdVehicle(dt)
        self:finish("noJoint")
        return
    end
    local room = ADFetchToolTask.FORWARD_ROOM
    local away = MathUtil.vector2Length(joint.x - hitch.x, joint.z - hitch.z)
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm.reverseNode = sdm:getReverseNode()
    if away >= room or self.timer > ADFetchToolTask.FORWARD_TIMEOUT or sdm.reverseNode == nil
        or self.vehicle.ad.collisionDetectionModule:checkReverseCollision() == true then
        self:setState(ADFetchToolTask.STATE_STOPPING)
        return
    end
    local tx, ty, tz = AutoDrive.localToWorld(self.vehicle, 0, 0, -100)
    sdm.reverseTarget = { x = tx, y = ty, z = tz }
    sdm.currentWayPointIndex = 0
    sdm.wayPoints = {}
    sdm:getBasicStates()
    sdm:reverseToPoint(dt, ADFetchFrontToolTask.BACK_SPEED)
end
