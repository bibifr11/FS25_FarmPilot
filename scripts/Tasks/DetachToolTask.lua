-- FarmPilot mode Autonome : dételer l'outil à sa place de parking, comme le joueur
-- (arrêt, outil coupé, abaissé si le jeu le demande, puis dételage du jeu avec ses béquilles).
-- Le résultat (self.result = "ok" ou la raison de l'échec) est lu par AutonomousMode:handleFinishedTask.
ADDetachToolTask = ADInheritsFrom(AbstractTask)

ADDetachToolTask.STATE_STOP = 1
ADDetachToolTask.STATE_LOWER = 2
ADDetachToolTask.STATE_DETACH = 3

ADDetachToolTask.LOWER_TIME = 2500      -- ms laissées pour abaisser l'outil avant de dételer
ADDetachToolTask.LOWER_TIMEOUT = 8000   -- ms : l'outil n'accepte toujours pas d'être dételé
ADDetachToolTask.DETACH_TIMEOUT = 20000 -- ms : béquilles / dételage pas terminés

function ADDetachToolTask:new(vehicle, tool)
    local o = ADDetachToolTask:create()
    o.vehicle = vehicle
    o.tool = tool
    o.result = nil
    return o
end

function ADDetachToolTask:setUp()
    self.state = ADDetachToolTask.STATE_STOP
    self.timer = 0
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

function ADDetachToolTask:isAttached()
    return self.tool ~= nil and self.tool.getAttacherVehicle ~= nil and self.tool:getAttacherVehicle() ~= nil
end

function ADDetachToolTask:update(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    self.timer = self.timer + dt

    if not self:isAttached() then
        -- déjà dételé (par le joueur ou par le jeu)
        self:finish("ok")
        return
    end

    if self.state == ADDetachToolTask.STATE_STOP then
        if math.abs(self.vehicle.lastSpeedReal) < 0.0015 then
            if self.tool.getIsTurnedOn ~= nil and self.tool:getIsTurnedOn() and self.tool.setIsTurnedOn ~= nil then
                self.tool:setIsTurnedOn(false)
            end
            local attacher = self.tool:getAttacherVehicle()
            -- (07/11 20:17, Fabien) mod d'attelage manuel : prise de force et flexibles débranchés d'abord
            -- (sinon le mod refuse le dételage)
            local okM, done = pcall(ADAutonomousManager.setManualConnections, attacher, self.tool, false)
            if not okM then
                ADAutonomousManager.log("ERREUR débranchement flexibles / prise de force : %s", tostring(done))
            elseif #done > 0 then
                ADAutonomousManager.log("%s : débranché (%s)", tostring(self.vehicle.ad.stateModule:getName()), table.concat(done, ", "))
            end
            local jointIndex = attacher.getAttacherJointIndexFromObject ~= nil and attacher:getAttacherJointIndexFromObject(self.tool) or nil
            local allowsLowering = self.tool.getAllowsLowering == nil or self.tool:getAllowsLowering()
            if jointIndex ~= nil and allowsLowering and attacher.setJointMoveDown ~= nil then
                attacher:setJointMoveDown(jointIndex, true)
            end
            self.state = ADDetachToolTask.STATE_LOWER
            self.timer = 0
        end
    elseif self.state == ADDetachToolTask.STATE_LOWER then
        local allowed = self.tool.isDetachAllowed == nil or self.tool:isDetachAllowed()
        if allowed and self.timer >= ADDetachToolTask.LOWER_TIME then
            if self.tool.startDetachProcess ~= nil then
                self.tool:startDetachProcess()
            else
                local attacher = self.tool:getAttacherVehicle()
                attacher:detachImplementByObject(self.tool)
            end
            self.state = ADDetachToolTask.STATE_DETACH
            self.timer = 0
        elseif not allowed and self.timer >= ADDetachToolTask.LOWER_TIMEOUT then
            self:finish("notAllowed")
        end
    elseif self.state == ADDetachToolTask.STATE_DETACH then
        if self.timer >= ADDetachToolTask.DETACH_TIMEOUT then
            self:finish("timeout")
        end
    end
end

function ADDetachToolTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self:finished()
end

function ADDetachToolTask:abort()
end

function ADDetachToolTask:finished()
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADDetachToolTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_detach;"
end
