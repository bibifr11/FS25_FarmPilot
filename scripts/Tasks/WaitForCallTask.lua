WaitForCallTask = ADInheritsFrom(AbstractTask)

function WaitForCallTask:new(vehicle)
    local o = WaitForCallTask:create()
    o.vehicle = vehicle
    return o
end

function WaitForCallTask:setUp()
    ADHarvestManager:registerAsUnloader(self.vehicle)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self:setUpFieldPark() -- FarmPilot : se garer dans le champ avant d'attendre l'appel, voir WaitForCallTaskFieldPark.lua
end

function WaitForCallTask:update(dt)
    -- FarmPilot : place dans le champ ou au bord de la route, puis attente de l'appel, voir WaitForCallTaskFieldPark.lua
    self:updateFieldPark(dt)
end

function WaitForCallTask:abort()
    self:abortFieldPark() -- FarmPilot : place rendue, calcul de trajet arrêté, voir WaitForCallTaskFieldPark.lua
end

function WaitForCallTask:finished()
    self:finishedFieldPark() -- FarmPilot : place rendue, voir WaitForCallTaskFieldPark.lua
    self.vehicle.ad.taskModule:setCurrentTaskFinished(self.propagate)
end

function WaitForCallTask:getInfoText()
    local text = self:getFieldParkInfoText() -- FarmPilot : se gare dans le champ, voir WaitForCallTaskFieldPark.lua
    if text ~= nil then
        return text
    end
    return g_i18n:getText("AD_task_wait_for_call")
end

function WaitForCallTask:getI18nInfo()
    local text = self:getFieldParkI18nInfo() -- FarmPilot : étape de la place dans le champ, voir WaitForCallTaskFieldPark.lua
    if text ~= nil then
        return text
    end
    return "$l10n_AD_task_wait_for_call;"
end
