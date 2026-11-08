-- ============================================================================================================
-- FarmPilot : AutonomousParkButton.lua
-- Complément du bouton « Envoyer au parking » (ADInputManager:input_parkVehicle, AutoDrive d'origine).
--
-- Demande Fabien 08/11 13:47 : « Lorsqu'on appuie sur l'envoi au parking, il faut, comme en fin de champ, qu'il
-- aille poser son outil s'il y en a un, puis qu'il aille se stationner à sa place. »
--
-- Règle : un outil de travail attelé directement au tracteur, qui a sa place de parking, et le tracteur qui a la
-- sienne (différente) : le bouton arrête Courseplay et FarmPilot comme avant, puis lance la même suite qu'en fin de
-- champ (AutonomousMode.parkWithToolDrop) : l'outil va à sa place et y est dételé, puis le tracteur va à la sienne.
-- Sinon (pas d'outil, plusieurs outils, outil ou tracteur sans place) : bouton d'origine, le tracteur se gare tel
-- quel.
-- ============================================================================================================

ADParkButton = {}

-- ------------------------------------------------------------------------------------------------------------
-- Outil à poser ? (mêmes conditions que la fin de champ)
-- ------------------------------------------------------------------------------------------------------------
function ADParkButton.toolToDrop(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.modes == nil
        or vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS] == nil then
        return nil, "pas de mode Autonome"
    end
    local ok, tools = pcall(ADAutonomousManager.workTools, vehicle)
    if not ok or tools == nil or #tools == 0 then
        return nil, "pas d'outil"
    end
    if #tools > 1 then
        return nil, "plusieurs outils"
    end
    local tool = tools[1]
    if tool.getAttacherVehicle == nil or tool:getAttacherVehicle() ~= vehicle then
        return nil, "outil pas attelé directement au tracteur"
    end
    local toolPark = tool.advd ~= nil and tool.advd.parkDestination or -1
    if toolPark == nil or toolPark < 1 or ADGraphManager:getMapMarkerById(toolPark) == nil then
        return nil, "l'outil n'a pas de place de parking"
    end
    local tractorPark = vehicle.advd ~= nil and vehicle.advd.parkDestination or -1
    if tractorPark == nil or tractorPark < 1 or tractorPark == toolPark or ADGraphManager:getMapMarkerById(tractorPark) == nil then
        return nil, "le tracteur n'a pas de place de parking (à part celle de l'outil)"
    end
    return tool
end

-- ------------------------------------------------------------------------------------------------------------
-- Bouton « Envoyer au parking »
-- ------------------------------------------------------------------------------------------------------------
ADParkButton.originalInput = ADInputManager.input_parkVehicle

function ADInputManager:input_parkVehicle(vehicle, farmId, ...)
    local tool, why = ADParkButton.toolToDrop(vehicle)
    if tool ~= nil then
        local name = tostring(vehicle.ad.stateModule:getName())
        -- comme le bouton d'origine : Courseplay arrêté, FarmPilot arrêté s'il roulait
        AutoDrive:StopCP(vehicle)
        if vehicle.ad.stateModule:isActive() then
            self:input_start_stop(vehicle, farmId)
        end
        vehicle.ad.stateModule:setMode(AutoDrive.MODE_AUTONOMOUS)
        ADAutonomousManager.log("%s : bouton parking : l'outil « %s » d'abord à sa place, puis le tracteur à la sienne", name, ADAutonomousManager.toolLabel(tool))
        local ok, started = pcall(AutonomousMode.parkWithToolDrop, vehicle)
        if ok and started then
            return
        end
        ADAutonomousManager.log("%s : bouton parking : dépose de l'outil pas lancée (%s), parking comme avant", name, ok and "refusée" or tostring(started))
    elseif vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and why ~= "pas d'outil" and why ~= "pas de mode Autonome" then
        ADAutonomousManager.log("%s : bouton parking : outil gardé (%s)", tostring(vehicle.ad.stateModule:getName()), tostring(why))
    end
    return ADParkButton.originalInput(self, vehicle, farmId, ...)
end
