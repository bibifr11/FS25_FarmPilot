-- ============================================================================================================
-- FarmPilot : RearTool.lua
-- Addon : outil arrière sélectionné au lancement de la partie.
--
-- Règle : au lancement de la partie (DELAY ms après son début), chaque tracteur sélectionne l'outil attelé derrière
-- lui (le premier de la chaîne), au lieu du dernier attelé au chargement. Une seule fois.
--
-- Branché par : AutoDriveAddon.lua (install au chargement de la carte : active le module) ; addModEventListener
-- (update).
-- ============================================================================================================

ADAddonRearTool = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAddonRearTool.DELAY = 2000

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place (au chargement de la carte, par AutoDriveAddon.lua)
-- ------------------------------------------------------------------------------------------------------------
function ADAddonRearTool.install(autoDrive)
    ADAddonRearTool.active = true
    ADAddonRearTool.done = false
    ADAddonRearTool.timer = 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Outil attelé derrière le tracteur
-- ------------------------------------------------------------------------------------------------------------
-- Position de l'attelage dans le repère du tracteur (z < 0 = derrière)
function ADAddonRearTool.getJointZ(vehicle, implement)
    local spec = vehicle.spec_attacherJoints
    if spec == nil or spec.attacherJoints == nil or implement.jointDescIndex == nil then
        return nil
    end
    local jointDesc = spec.attacherJoints[implement.jointDescIndex]
    if jointDesc == nil or jointDesc.jointTransform == nil then
        return nil
    end
    local _, _, z = localToLocal(jointDesc.jointTransform, vehicle.rootNode, 0, 0, 0)
    return z
end

function ADAddonRearTool.selectRear(vehicle)
    if vehicle.getAttachedImplements == nil or vehicle.setSelectedVehicle == nil then
        return
    end
    local rear, rearZ = nil, 0
    for _, implement in ipairs(vehicle:getAttachedImplements()) do
        if implement.object ~= nil then
            local z = ADAddonRearTool.getJointZ(vehicle, implement)
            if z ~= nil and z < rearZ then
                rear, rearZ = implement.object, z
            end
        end
    end
    if rear == nil then
        return
    end
    if vehicle.getSelectedVehicle ~= nil and vehicle:getSelectedVehicle() == rear then
        return
    end
    vehicle:setSelectedVehicle(rear, nil, true)
end

-- ------------------------------------------------------------------------------------------------------------
-- Au lancement de la partie, une seule fois
-- ------------------------------------------------------------------------------------------------------------
function ADAddonRearTool:update(dt)
    if not ADAddonRearTool.active or ADAddonRearTool.done then
        return
    end
    if g_currentMission == nil or not g_currentMission.isMissionStarted then
        return
    end
    ADAddonRearTool.timer = ADAddonRearTool.timer + dt
    if ADAddonRearTool.timer < ADAddonRearTool.DELAY then
        return
    end
    ADAddonRearTool.done = true

    local vehicleSystem = g_currentMission.vehicleSystem
    if vehicleSystem == nil or vehicleSystem.vehicles == nil then
        return
    end
    for _, vehicle in ipairs(vehicleSystem.vehicles) do
        if vehicle.rootVehicle == vehicle then
            local ok, err = FarmPilotCall(ADAddonRearTool.selectRear, vehicle)
            if not ok then
                ADAddon.warning("rear implement error: " .. tostring(err))
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Enregistrement
-- ------------------------------------------------------------------------------------------------------------
addModEventListener(ADAddonRearTool)
ADAddon.addModule(ADAddonRearTool)
