-- ============================================================================================================
-- FarmPilot : LightsOff.lua
-- Addon : feux du véhicule quand AutoDrive coupe le moteur.
--
-- Règle : moteur coupé par AutoDrive : seuls les phares de base restent allumés (s'ils l'étaient déjà), puis les
-- feux sont remis comme avant au redémarrage du moteur. AutoDrive qui s'arrête gère lui-même les feux.
--
-- Branché par : AutoDriveAddon.lua (install au chargement de la carte : enveloppe AutoDrive.updateAutoDriveLights,
-- appelée à chaque image ; TurnLightsBends.lua l'enveloppe ensuite à son tour).
-- ============================================================================================================

ADAddonLightsOff = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- Bit 0 du masque = phares de base (touche L)
ADAddonLightsOff.HEADLIGHTS_MASK = 1

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local function getLightsState(vehicle)
    local spec = vehicle.spec_lights
    return {
        mask = spec.lightsTypesMask or 0,
        beacon = spec.beaconLightsActive == true,
        turn = spec.turnLightState or Lights.TURNLIGHT_OFF
    }
end

local function applyLightsState(vehicle, state)
    local current = getLightsState(vehicle)
    if current.mask ~= state.mask and vehicle.setLightsTypesMask ~= nil then
        vehicle:setLightsTypesMask(state.mask, true)
    end
    if current.beacon ~= state.beacon and vehicle.setBeaconLightsVisibility ~= nil then
        vehicle:setBeaconLightsVisibility(state.beacon)
    end
    if current.turn ~= state.turn and vehicle.setTurnLightState ~= nil then
        vehicle:setTurnLightState(state.turn)
    end
end

-- Phares de base gardés seulement s'ils étaient allumés avant la coupure
local function getParkedState(saved)
    return {
        mask = saved.mask % 2 == 1 and ADAddonLightsOff.HEADLIGHTS_MASK or 0,
        beacon = false,
        turn = Lights.TURNLIGHT_OFF
    }
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place (au chargement de la carte, par AutoDriveAddon.lua)
-- ------------------------------------------------------------------------------------------------------------
function ADAddonLightsOff.install(autoDrive)
    local original = autoDrive.updateAutoDriveLights
    if original == nil then
        ADAddon.warning("updateAutoDriveLights not found, lights handling inactive")
        return
    end

    -- AutoDrive appelle AutoDrive.updateAutoDriveLights(vehicle) à chaque image
    autoDrive.updateAutoDriveLights = function(vehicle, switchOff)
        if vehicle.spec_lights == nil or vehicle.getIsMotorStarted == nil then
            return original(vehicle, switchOff)
        end

        if switchOff then
            -- AutoDrive s'arrête : il gère lui-même les feux
            vehicle.adAddonSavedLights = nil
            vehicle.adAddonParkedLights = nil
            return original(vehicle, switchOff)
        end

        local isActive = vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:isActive()

        if isActive and not vehicle:getIsMotorStarted() then
            if vehicle.adAddonSavedLights == nil then
                vehicle.adAddonSavedLights = getLightsState(vehicle)
                vehicle.adAddonParkedLights = getParkedState(vehicle.adAddonSavedLights)
            end
            applyLightsState(vehicle, vehicle.adAddonParkedLights)
            return
        end

        if vehicle.adAddonSavedLights ~= nil and vehicle:getIsMotorStarted() then
            applyLightsState(vehicle, vehicle.adAddonSavedLights)
            vehicle.adAddonSavedLights = nil
            vehicle.adAddonParkedLights = nil
        end

        return original(vehicle, switchOff)
    end

end

-- ------------------------------------------------------------------------------------------------------------
-- Enregistrement
-- ------------------------------------------------------------------------------------------------------------
ADAddon.addModule(ADAddonLightsOff)
