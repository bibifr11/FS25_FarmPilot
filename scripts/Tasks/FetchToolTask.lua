-- ============================================================================================================
-- FarmPilot : FetchToolTask.lua
-- Mode Autonome : tâche « aller atteler l'outil choisi dans le HUD », comme le joueur.
--
-- Règle :
-- - Le tracteur se place devant l'outil, dans son axe (recherche de chemin de FarmPilot), recule avec la marche
--   arrière de FarmPilot jusqu'à ce que le jeu puisse atteler, attelle, relève l'outil et le replie (repli de
--   FarmPilot).
-- - Déjà devant l'outil, dans son axe, le nez à l'opposé : marche arrière tout de suite.
-- - Attelage raté : il avance dans l'axe de l'outil et recommence, au plus RETRIES fois.
-- - (07/11) mod d'attelage manuel : flexibles et prise de force branchés après l'attelage, comme le joueur.
-- - Le résultat (self.result = "ok" ou la raison de l'échec) est lu par AutonomousMode:handleFinishedTask.
--
-- Branché par : AutonomousMode.lua (startFetchAttach : ADFetchToolTask:new ; fetchRoutePoint et monitorFetchRoute :
-- isReady, readyFor, FRONT_MARGIN).
-- ============================================================================================================

ADFetchToolTask = ADInheritsFrom(AbstractTask)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFetchToolTask.STATE_PLAN = 1
ADFetchToolTask.STATE_PLANNING = 2
ADFetchToolTask.STATE_DRIVING = 3
ADFetchToolTask.STATE_STOPPING = 4
ADFetchToolTask.STATE_REVERSE = 5
ADFetchToolTask.STATE_ATTACHED = 6
ADFetchToolTask.STATE_FORWARD = 7

ADFetchToolTask.FRONT_MARGIN = 12         -- m entre l'avant de l'outil et l'arrière du tracteur placé devant
ADFetchToolTask.LOOK_AHEAD = 5            -- m : la marche arrière vise un point de l'axe de l'outil, à cette distance derrière le tracteur
ADFetchToolTask.AIM_BEHIND = 3            -- m : ce point ne va pas plus loin que ça dans l'outil
ADFetchToolTask.READY_LATERAL = 1.5       -- m d'écart à l'axe de l'outil accepté pour reculer tout de suite
ADFetchToolTask.READY_ANGLE = 15          -- ° d'écart à l'axe de l'outil accepté pour reculer tout de suite
ADFetchToolTask.READY_MAX = 30            -- m devant l'outil au plus pour reculer tout de suite
ADFetchToolTask.ATTACH_RANGE = 0.8        -- m entre les points d'attelage pour essayer d'atteler
ADFetchToolTask.MISS_MARGIN = 0.6         -- m : la distance remonte de ça après le plus près = raté
ADFetchToolTask.REVERSE_TIMEOUT = 90000   -- ms
ADFetchToolTask.STOP_TIMEOUT = 8000       -- ms pour s'arrêter avant de reculer
ADFetchToolTask.ATTACHED_TIME = 2500      -- ms après l'attelage (béquilles, relevage) avant de partir
ADFetchToolTask.CONNECT_TIME = 500        -- ms après l'attelage : flexibles et prise de force (mod d'attelage manuel)
ADFetchToolTask.RETRIES = 2               -- attelage raté : on avance dans l'axe et on recommence, au plus ce nombre de fois
ADFetchToolTask.FORWARD_ROOM = 10         -- m d'avance (en plus de la longueur du tracteur) pour reprendre l'axe
ADFetchToolTask.FORWARD_TIMEOUT = 30000   -- ms

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
function ADFetchToolTask:new(vehicle, tool)
    local o = ADFetchToolTask:create()
    o.vehicle = vehicle
    o.tool = tool
    o.result = nil
    return o
end

function ADFetchToolTask:setUp()
    self.state = ADFetchToolTask.STATE_PLAN
    self.timer = 0
    self.minDistance = math.huge
    self.retries = 0
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

-- ------------------------------------------------------------------------------------------------------------
-- Points d'attelage, place devant l'outil
-- ------------------------------------------------------------------------------------------------------------
-- attelage arrière du tracteur et point d'attelage de l'outil (positions monde) ; nil si l'outil ne va plus
function ADFetchToolTask:getJoints()
    local _, joint, _, input = ADAutonomousManager.matchJoints(self.vehicle, self.tool, true)
    if joint == nil or joint.jointTransform == nil or input == nil then
        return nil
    end
    local ax, ay, az = getWorldTranslation(joint.jointTransform)
    local hitch = ADAutonomousManager.toolHitch(self.vehicle, self.tool)
    if hitch == nil then
        return nil
    end
    return { x = ax, y = ay, z = az }, hitch
end

-- point devant l'outil, dans son axe, où le tracteur se place avant de reculer
function ADFetchToolTask:getFrontPoint(hitch)
    local length = (self.vehicle.size ~= nil and self.vehicle.size.length) or 6
    local d = length + ADFetchToolTask.FRONT_MARGIN
    return { x = hitch.x + hitch.dirX * d, y = hitch.y, z = hitch.z + hitch.dirZ * d }
end

-- déjà devant l'outil, dans son axe, le nez à l'opposé : on recule tout de suite
function ADFetchToolTask.isReady(vehicle, hitch)
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local rx, _, rz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local ox, oz = vx - hitch.x, vz - hitch.z
    local along = ox * hitch.dirX + oz * hitch.dirZ
    local lateral = math.abs(ox * hitch.dirZ - oz * hitch.dirX)
    local len = MathUtil.vector2Length(rx, rz)
    if len < 0.001 then
        return false
    end
    local cosA = (rx * hitch.dirX + rz * hitch.dirZ) / len
    return along > 0 and along <= ADFetchToolTask.READY_MAX and lateral <= ADFetchToolTask.READY_LATERAL
        and cosA >= math.cos(math.rad(ADFetchToolTask.READY_ANGLE))
end

function ADFetchToolTask:isReadyToReverse(hitch)
    return ADFetchToolTask.isReady(self.vehicle, hitch)
end

-- pour la route vers l'outil (AutonomousMode) : prêt à reculer ?, distance entre les points d'attelage
function ADFetchToolTask.readyFor(vehicle, tool)
    local _, joint = ADAutonomousManager.matchJoints(vehicle, tool, true)
    local hitch = ADAutonomousManager.toolHitch(vehicle, tool)
    if hitch == nil or joint == nil or joint.jointTransform == nil then
        return false, nil
    end
    local ax, _, az = getWorldTranslation(joint.jointTransform)
    return ADFetchToolTask.isReady(vehicle, hitch), MathUtil.vector2Length(ax - hitch.x, az - hitch.z)
end

-- ------------------------------------------------------------------------------------------------------------
-- À chaque image (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function ADFetchToolTask:holdVehicle(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
end

function ADFetchToolTask:update(dt)
    self.timer = self.timer + dt
    if self.tool == nil or self.tool.isDeleted then
        self:finish("gone")
        return
    end
    local attacher = self.tool.getAttacherVehicle ~= nil and self.tool:getAttacherVehicle() or nil
    if attacher ~= nil and self.state ~= ADFetchToolTask.STATE_ATTACHED then
        if attacher == self.vehicle then
            -- attelé (par le joueur ou par nous)
            self:onAttached()
        else
            self:finish("busy")
        end
        return
    end

    if self.state == ADFetchToolTask.STATE_PLAN then
        self:holdVehicle(dt)
        local _, hitch = self:getJoints()
        if hitch == nil then
            self:finish("noJoint")
            return
        end
        if self:isReadyToReverse(hitch) then
            ADAutonomousManager.log("%s : déjà devant l'outil, marche arrière", tostring(self.vehicle.ad.stateModule:getName()))
            self:setState(ADFetchToolTask.STATE_STOPPING)
            return
        end
        local front = self:getFrontPoint(hitch)
        local pf = self.vehicle.ad.pathFinderModule
        pf:reset()
        pf:startPathPlanningTo(front, { x = hitch.dirX, z = hitch.dirZ })
        ADAutonomousManager.log("%s : chemin vers l'avant de l'outil (%.0f, %.0f)", tostring(self.vehicle.ad.stateModule:getName()), front.x, front.z)
        self:setState(ADFetchToolTask.STATE_PLANNING)
    elseif self.state == ADFetchToolTask.STATE_PLANNING then
        local pf = self.vehicle.ad.pathFinderModule
        if pf:hasFinished() then
            local path = pf:getPath()
            if path == nil or #path == 0 then
                self:finish("noPath")
                return
            end
            self.vehicle.ad.drivePathModule:setWayPoints(path)
            self:setState(ADFetchToolTask.STATE_DRIVING)
        else
            pf:update(dt)
            self:holdVehicle(dt)
        end
    elseif self.state == ADFetchToolTask.STATE_DRIVING then
        local dpm = self.vehicle.ad.drivePathModule
        if dpm:isTargetReached() then
            self:setState(ADFetchToolTask.STATE_STOPPING)
        else
            dpm:update(dt)
        end
    elseif self.state == ADFetchToolTask.STATE_STOPPING then
        self:holdVehicle(dt)
        if math.abs(self.vehicle.lastSpeedReal) < 0.0015 or self.timer > ADFetchToolTask.STOP_TIMEOUT then
            self.minDistance = math.huge
            self:setState(ADFetchToolTask.STATE_REVERSE)
        end
    elseif self.state == ADFetchToolTask.STATE_REVERSE then
        self:updateReverse(dt)
    elseif self.state == ADFetchToolTask.STATE_FORWARD then
        self:updateForward(dt)
    elseif self.state == ADFetchToolTask.STATE_ATTACHED then
        self:holdVehicle(dt)
        if not self.connected and self.timer >= ADFetchToolTask.CONNECT_TIME then
            self.connected = true
            self:connectManual()
        end
        if self.timer >= ADFetchToolTask.ATTACHED_TIME then
            self:prepareForRoad()
            self:finish("ok")
        end
    end
end

function ADFetchToolTask:setState(state)
    self.state = state
    self.timer = 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Marche arrière vers l'outil, nouvel essai
-- ------------------------------------------------------------------------------------------------------------
-- marche arrière de FarmPilot (ADSpecialDrivingModule:reverseToPoint) vers un point dans l'axe de l'outil ;
-- sans le contrôle de collision arrière, qui verrait l'outil lui-même
function ADFetchToolTask:updateReverse(dt)
    local joint, hitch = self:getJoints()
    if joint == nil then
        self:holdVehicle(dt)
        self:finish("noJoint")
        return
    end
    local distance = MathUtil.vector2Length(joint.x - hitch.x, joint.z - hitch.z)
    -- passé à côté ou au-delà du point d'attelage
    local past = (joint.x - hitch.x) * hitch.dirX + (joint.z - hitch.z) * hitch.dirZ < -ADFetchToolTask.MISS_MARGIN
    if distance < self.minDistance then
        self.minDistance = distance
    end
    if distance <= ADFetchToolTask.ATTACH_RANGE then
        self:holdVehicle(dt)
        if self:tryAttach() then
            return
        end
    end
    if past or (self.minDistance < 3 and distance > self.minDistance + ADFetchToolTask.MISS_MARGIN) then
        self:holdVehicle(dt)
        if self.retries < ADFetchToolTask.RETRIES then
            self.retries = self.retries + 1
            ADAutonomousManager.log("%s : attelage raté (au plus près %.2f m), on avance dans l'axe et on recommence (%d/%d)", tostring(self.vehicle.ad.stateModule:getName()), self.minDistance, self.retries, ADFetchToolTask.RETRIES)
            self:setState(ADFetchToolTask.STATE_FORWARD)
            return
        end
        ADAutonomousManager.log("%s : attelage raté (au plus près %.2f m, maintenant %.2f m)", tostring(self.vehicle.ad.stateModule:getName()), self.minDistance, distance)
        self:finish("missed")
        return
    end
    if self.timer > ADFetchToolTask.REVERSE_TIMEOUT then
        self:holdVehicle(dt)
        self:finish("timeout")
        return
    end
    if distance <= ADFetchToolTask.ATTACH_RANGE then
        -- à portée mais le jeu n'attelle pas encore : tout doucement
        self:reverseTo(dt, hitch, 1)
    else
        self:reverseTo(dt, hitch, math.min(5, math.max(1.5, distance * 0.6)))
    end
end

-- attelage raté : on avance en reprenant l'axe de l'outil, assez loin pour reculer droit, puis on recommence
function ADFetchToolTask:updateForward(dt)
    local _, hitch = self:getJoints()
    if hitch == nil then
        self:holdVehicle(dt)
        self:finish("noJoint")
        return
    end
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local along = (vx - hitch.x) * hitch.dirX + (vz - hitch.z) * hitch.dirZ
    local room = ((self.vehicle.size ~= nil and self.vehicle.size.length) or 6) + ADFetchToolTask.FORWARD_ROOM
    if along >= room or self.timer > ADFetchToolTask.FORWARD_TIMEOUT then
        self:setState(ADFetchToolTask.STATE_STOPPING)
        return
    end
    local aim = math.max(along, 0) + 8
    local point = { x = hitch.x + hitch.dirX * aim, y = hitch.y, z = hitch.z + hitch.dirZ * aim }
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, point, 4, true, 0.6, 8, true)
end

function ADFetchToolTask:reverseTo(dt, hitch, maxSpeed)
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm.reverseNode = sdm:getReverseNode()
    if sdm.reverseNode == nil then
        self:finish("noJoint")
        return
    end
    -- point de l'axe de l'outil, LOOK_AHEAD m derrière le tracteur (projeté sur l'axe) : le tracteur rejoint l'axe
    -- et s'aligne dessus en reculant, au lieu de viser un point fixe (écart de côté à l'arrivée)
    local rx, _, rz = getWorldTranslation(sdm.reverseNode)
    local along = (rx - hitch.x) * hitch.dirX + (rz - hitch.z) * hitch.dirZ
    local aim = math.max(along - ADFetchToolTask.LOOK_AHEAD, -ADFetchToolTask.AIM_BEHIND)
    sdm.reverseTarget = { x = hitch.x + hitch.dirX * aim, y = hitch.y, z = hitch.z + hitch.dirZ * aim }
    sdm.currentWayPointIndex = 0
    sdm.wayPoints = {}
    sdm:getBasicStates()
    sdm:reverseToPoint(dt, maxSpeed)
end

-- ------------------------------------------------------------------------------------------------------------
-- Attelage, branchements, outil prêt pour la route
-- ------------------------------------------------------------------------------------------------------------
-- attelage du jeu (comme la touche du joueur) quand l'outil est à portée
function ADFetchToolTask:tryAttach()
    local maxDistanceSq = AttacherJoints.MAX_ATTACH_DISTANCE_SQ or 1
    local maxAngle = AttacherJoints.MAX_ATTACH_ANGLE or 0.34202
    local attacherVehicle, attacherJointIndex, attachable, attachableJointIndex = AttacherJoints.updateVehiclesInAttachRange(self.vehicle, maxDistanceSq, maxAngle, true)
    if attachable ~= self.tool or attacherVehicle ~= self.vehicle then
        return false
    end
    if attachable.isAttachAllowed ~= nil then
        local farmId = self.vehicle.getActiveFarm ~= nil and self.vehicle:getActiveFarm() or nil
        local allowed = attachable:isAttachAllowed(farmId, attacherVehicle)
        if not allowed then
            return false
        end
    end
    local info = {
        attacherVehicle = attacherVehicle,
        attacherVehicleJointDescIndex = attacherJointIndex,
        attachable = attachable,
        attachableJointDescIndex = attachableJointIndex
    }
    if not self.vehicle:attachImplementFromInfo(info) then
        return false
    end
    ADAutonomousManager.log("%s : outil « %s » attelé", tostring(self.vehicle.ad.stateModule:getName()), ADAutonomousManager.toolLabel(self.tool))
    self:onAttached()
    return true
end

function ADFetchToolTask:onAttached()
    if self.state ~= ADFetchToolTask.STATE_ATTACHED then
        self:setState(ADFetchToolTask.STATE_ATTACHED)
    end
end

-- (07/11) mod d'attelage manuel : flexibles et prise de force branchés comme le joueur
function ADFetchToolTask:connectManual()
    local ok, done = pcall(ADAutonomousManager.setManualConnections, self.vehicle, self.tool, true)
    if not ok then
        ADAutonomousManager.log("ERREUR flexibles / prise de force : %s", tostring(done))
    elseif #done > 0 then
        ADAutonomousManager.log("%s : branché (%s)", tostring(self.vehicle.ad.stateModule:getName()), table.concat(done, ", "))
    end
end

-- outil relevé, coupé ; le repli pour la route est celui de FarmPilot (réglage « Replier les outils »)
function ADFetchToolTask:prepareForRoad()
    local tool = self.tool
    if tool.getIsTurnedOn ~= nil and tool:getIsTurnedOn() and tool.setIsTurnedOn ~= nil then
        tool:setIsTurnedOn(false)
    end
    local attacher = tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() or nil
    if attacher ~= nil and attacher.getAttacherJointIndexFromObject ~= nil and attacher.setJointMoveDown ~= nil then
        local jointIndex = attacher:getAttacherJointIndexFromObject(tool)
        if jointIndex ~= nil then
            attacher:setJointMoveDown(jointIndex, false)
        end
    end
    AutoDrive.resetFoldState(self.vehicle)
    AutoDrive.getAllVehicleDimensions(self.vehicle, true)
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin de la tâche, collisions, texte du HUD
-- ------------------------------------------------------------------------------------------------------------
function ADFetchToolTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADFetchToolTask:abort()
end

-- tout près de l'outil (arrêt, marche arrière) : l'outil n'est pas un obstacle
function ADFetchToolTask:getExcludedVehiclesForCollisionCheck()
    if self.state ~= nil and self.state >= ADFetchToolTask.STATE_STOPPING and self.tool ~= nil then
        return { self.tool }
    end
    return {}
end

function ADFetchToolTask:getI18nInfo()
    if self.state == ADFetchToolTask.STATE_PLANNING then
        return self:getPlanningI18n()
    end
    return "$l10n_AD_task_autonomous_fetch;"
end
