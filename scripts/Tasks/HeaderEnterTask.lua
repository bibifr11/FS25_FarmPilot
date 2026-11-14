-- ============================================================================================================
-- FarmPilot : HeaderEnterTask.lua
-- Mode Autonome, moissonneuse équipée seule : tâche de la moissonneuse « avancer jusqu'au bord du champ ». La
-- barre vient d'être prise près du champ à récolter : elle avance tout droit, sans passer par le réseau, jusqu'à ce
-- que la barre soit au bord du champ ; le travail est lancé là.
--
-- Règle (13/11) :
-- - Elle suit une ligne droite (plan.x, plan.z, plan.dx, plan.dz) sur plan.length m, à ENTRY_SPEED km/h au plus,
--   en visant un point de la ligne ENTRY_LOOK m plus loin.
-- - Fini quand la longueur est faite. Arrêt avant : plus de ENTRY_TIMEOUT ms, ou à l'arrêt pendant ENTRY_BLOCKED ms.
--   Dans tous les cas le travail est lancé d'où elle est (elle est au bord du champ).
-- - Le résultat (self.result : « ok », « blocked », « timeout ») est écrit dans le journal par
--   Modes/AutonomousHeaderEntry.lua.
--
-- Branché par : Modes/AutonomousHeaderEntry.lua (startEntry : la tâche prend la place du trajet vers le champ,
-- AutonomousMode.driveToDestinationTask). Chargé par register.lua après HeaderBackInTask.lua.
-- ============================================================================================================

ADHeaderEnterTask = ADInheritsFrom(AbstractTask)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderEnterTask.ENTRY_SPEED = 6        -- km/h
ADHeaderEnterTask.ENTRY_LOOK = 6         -- m : point visé devant elle, sur la ligne
ADHeaderEnterTask.ENTRY_TIMEOUT = 90000  -- ms
ADHeaderEnterTask.ENTRY_BLOCKED = 8000   -- ms à l'arrêt
ADHeaderEnterTask.ENTRY_STILL = 0.5      -- km/h : à l'arrêt en dessous

-- ------------------------------------------------------------------------------------------------------------
-- Tâche
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderEnterTask:new(vehicle, plan)
    local o = ADHeaderEnterTask:create()
    o.vehicle = vehicle
    o.plan = plan
    o.result = nil
    return o
end

function ADHeaderEnterTask:setUp()
    self.timer = 0
    self.still = 0
end

-- m faits le long de la ligne
function ADHeaderEnterTask:done()
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    return (x - self.plan.x) * self.plan.dx + (z - self.plan.z) * self.plan.dz
end

function ADHeaderEnterTask:update(dt)
    local plan = self.plan
    local sdm = self.vehicle.ad.specialDrivingModule
    self.timer = self.timer + dt
    local done = self:done()
    if done >= plan.length then
        sdm:stopVehicle()
        sdm:update(dt)
        self:finish("ok")
        return
    end
    if self.timer > ADHeaderEnterTask.ENTRY_TIMEOUT then
        sdm:stopVehicle()
        sdm:update(dt)
        self:finish("timeout")
        return
    end
    local speed = math.abs(self.vehicle.lastSpeedReal or 0) * 3600
    if speed < ADHeaderEnterTask.ENTRY_STILL and self.timer > 3000 then
        self.still = self.still + dt
        if self.still > ADHeaderEnterTask.ENTRY_BLOCKED then
            sdm:stopVehicle()
            sdm:update(dt)
            self:finish("blocked")
            return
        end
    else
        self.still = 0
    end
    local aim = done + ADHeaderEnterTask.ENTRY_LOOK
    local x, z = plan.x + plan.dx * aim, plan.z + plan.dz * aim
    local y = getTerrainHeightAtWorldPos ~= nil and g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil
        and getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z) or 0
    local left = plan.length - done
    local maxSpeed = math.min(ADHeaderEnterTask.ENTRY_SPEED, math.max(2, left * 1.5))
    sdm:driveToPoint(dt, { x = x, y = y, z = z }, 1, true, 0.6, maxSpeed, true)
end

function ADHeaderEnterTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADHeaderEnterTask:abort()
end

function ADHeaderEnterTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_headerEntry;"
end
