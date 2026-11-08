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
-- Sinon (pas d'outil avec sa place, plusieurs, tracteur sans place) : bouton d'origine, le tracteur se gare tel
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
    -- (Fabien 08/11 20:57 « sur tous les modes ») : tout outil ou remorque attelé directement au tracteur qui a
    -- sa propre place de parking (outil de travail, benne, plateau… ; les masses n'ont pas de place)
    local attached = {}
    if vehicle.getAttachedImplements ~= nil then
        local okA, implements = pcall(vehicle.getAttachedImplements, vehicle)
        if okA and type(implements) == "table" then
            for _, impl in ipairs(implements) do
                local o = impl.object
                local park = o ~= nil and o.advd ~= nil and o.advd.parkDestination or -1
                if park ~= nil and park >= 1 and ADGraphManager:getMapMarkerById(park) ~= nil then
                    attached[#attached + 1] = o
                end
            end
        end
    end
    if #attached == 0 then
        return nil, "aucun outil attelé avec sa place de parking"
    end
    if #attached > 1 then
        return nil, "plusieurs outils avec leur place de parking"
    end
    local tool = attached[1]
    local toolPark = tool.advd.parkDestination
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
        local ok, started = pcall(AutonomousMode.parkWithToolDrop, vehicle, tool)
        if ok and started then
            return
        end
        ADAutonomousManager.log("%s : bouton parking : dépose de l'outil pas lancée (%s), parking comme avant", name, ok and "refusée" or tostring(started))
    elseif vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
        ADAutonomousManager.log("%s : bouton parking : parking comme avant (%s)", tostring(vehicle.ad.stateModule:getName()), tostring(why))
    end
    return ADParkButton.originalInput(self, vehicle, farmId, ...)
end
