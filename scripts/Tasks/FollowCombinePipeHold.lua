-- ============================================================================================================
-- FarmPilot : FollowCombinePipeHold.lua
-- Complément de FollowCombineTask (tâche AutoDrive d'origine) : rester sous la goulotte de la moissonneuse.
--
-- (08/11) En bout de ligne, moissonneuse goulotte sortie, le tracteur partait ou faisait marche AR.
-- En moissonneuse ça ne doit pas arriver.
--
-- Règle : tant que la moissonneuse (pas l'ensileuse) vide dans une remorque de ce tracteur et que la remorque n'est
-- pas pleine, le tracteur ne recule pas pour « reprendre de la place » et ne part pas. Il reste arrêté quand elle
-- est arrêtée, avance avec elle, et recule seulement quand elle recule elle-même, à sa vitesse.
-- Fin du maintien : remorque pleine, goulotte rentrée, ou plus de grain dans la remorque depuis 3 s.
--
-- Appelé au début de FollowCombineTask:update (avant la machine à états d'origine).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
FollowCombineTask.PIPE_HOLD_GRACE = 3000 -- ms the hold lasts after the last grain seen falling into this train
FollowCombineTask.PIPE_HOLD_MIN_REVERSE_KMH = 2 -- km/h at least when backing up with the combine

-- ------------------------------------------------------------------------------------------------------------
-- La moissonneuse vide-t-elle dans une de nos remorques ?
-- ------------------------------------------------------------------------------------------------------------
function FollowCombineTask:isCombineDischargingIntoUs()
    local pipeVehicles = {}
    if self.combine.spec_combine ~= nil then
        pipeVehicles[1] = self.combine
    else
        for _, implement in pairs(AutoDrive.getAllImplements(self.combine) or {}) do
            if implement ~= nil and implement.spec_combine ~= nil then
                pipeVehicles[#pipeVehicles + 1] = implement
            end
        end
    end
    for _, v in ipairs(pipeVehicles) do
        if v.getDischargeState ~= nil and v.getCurrentDischargeNode ~= nil and v:getDischargeState() == Dischargeable.DISCHARGE_STATE_OBJECT then
            local node = v:getCurrentDischargeNode()
            local target = node ~= nil and node.dischargeObject or nil
            if target ~= nil then
                for _, trailer in pairs(self.trailers or {}) do
                    if trailer == target then
                        return true
                    end
                end
                if target.rootVehicle ~= nil and target.rootVehicle == self.vehicle then
                    return true
                end
            end
        end
    end
    return false
end


-- ------------------------------------------------------------------------------------------------------------
-- Maintien sous la goulotte
-- ------------------------------------------------------------------------------------------------------------
-- 08/11 20:03: pipe out over this trailer and the trailer not full, the tractor stays under the pipe until the
-- trailer is full or the combine stops emptying (pipe in, combine empty, pipe away from the trailer): it stands while the
-- combine stands, rolls on with it, backs up only when the combine itself backs up, at its speed
function FollowCombineTask:holdUnderCombinePipe(dt)
    local combine = self.combine
    if combine.ad == nil or combine.ad.isChopper or not combine.ad.isHarvester or self.filled then
        if self.pipeHold ~= nil then
            print(string.format("[AD-Poursuite] %s: %s, je quitte la goulotte", FollowCombineTask.getLogName(self.vehicle), self.filled and "remorque pleine" or "fin du vidage"))
        end
        self.pipeHold = nil
        return false
    end
    local now = g_time or 0
    if AutoDrive.isPipeOut(combine) and self:isCombineDischargingIntoUs() then
        if self.pipeHold == nil then
            print(string.format("[AD-Poursuite] %s: moissonneuse goulotte sortie qui vide dans ma remorque : je reste dessous (pas de recul, pas de depart) jusqu'a remorque pleine ou fin du vidage",
                FollowCombineTask.getLogName(self.vehicle)))
        end
        self.pipeHold = now
    elseif self.pipeHold == nil then
        return false
    elseif now - self.pipeHold > FollowCombineTask.PIPE_HOLD_GRACE then
        print(string.format("[AD-Poursuite] %s: goulotte rentree ou plus de grain dans ma remorque depuis %.0f s, la poursuite reprend",
            FollowCombineTask.getLogName(self.vehicle), (now - self.pipeHold) / 1000))
        self.pipeHold = nil
        return false
    end
    -- whatever was planned before (reversing for room, waiting for a turn, finishing): back to a plain chase afterwards
    if self.state ~= FollowCombineTask.STATE_CHASING then
        self.state = FollowCombineTask.STATE_CHASING
        self.lastState = self.state
        self.reverseStartLocation = nil
        self:resetAllTimers()
    end
    self.stuckTimer:timer(false)
    self.angleWrongTimer:timer(false)
    self.lineBlockedTimer:timer(false, FollowCombineTask.LINE_BLOCKED_TIME, dt)
    local speed = math.abs(combine.lastSpeedReal or 0) * 3600 -- km/h
    if FollowCombineTask.isCombineReversing(combine) then
        self.vehicle.ad.specialDrivingModule:driveReverse(dt, math.max(speed, FollowCombineTask.PIPE_HOLD_MIN_REVERSE_KMH), 1, self.vehicle.ad.trailerModule:canBeHandledInReverse())
        return true
    end
    if math.abs(combine.lastSpeedReal or 0) > FollowCombineTask.TURN_STOPPED_SPEED and self.chasePos ~= nil then
        local _, _, ahead = AutoDrive.worldToLocal(self.vehicle, self.chasePos.x, self.chasePos.y or 0, self.chasePos.z)
        if ahead > -1 then
            self.vehicle.ad.specialDrivingModule:driveToPoint(dt, self.chasePos, speed, false, 1, math.max(speed + 5, 6))
            return true
        end
    end
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
    return true
end
