-- ============================================================================================================
-- FarmPilot : TurnLightsOtherMods.lua
-- Complément de TurnLights.lua : les autres mods qui éteignent le clignotant restent sans effet pendant que
-- FarmPilot conduit.
--
-- Demande Fabien 08/11 18:40 : « souvent c'est écrit interrompu par un autre script, trouvons le script pour le
-- désactiver quand nous sommes là ».
--
-- Script trouvé dans les mods de Fabien : FS25_autoTurnOffTurnLights (Ifko[nator]), spécialisation
-- « autoTurnOffTurnLights ». Son onUpdate éteint le clignotant dès que le volant revient vers le centre après
-- avoir tourné du côté du clignotant. Avec FarmPilot au volant, le moindre coup de volant avant le virage
-- suffit à l'éteindre (log « clignotant eteint par un autre script »), FarmPilot le rallume, d'où un clignotant
-- qui ne s'allume pas à la bonne distance.
--
-- Règle : véhicule conduit par FarmPilot = l'onUpdate de ce mod ne fait rien (ses repères de coup de volant
-- sont remis à zéro). Joueur au volant, ou Courseplay, ou l'ouvrier du jeu : ce mod marche comme avant.
-- ============================================================================================================

ADAddonTurnLightsOtherMods = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- spécialisations connues qui éteignent le clignotant toutes seules : nom de la spécialisation -> description
ADAddonTurnLightsOtherMods.KNOWN = {
    autoTurnOffTurnLights = "FS25_autoTurnOffTurnLights (extinction auto du clignotant)"
}

-- ------------------------------------------------------------------------------------------------------------
-- Véhicule conduit par FarmPilot ?
-- ------------------------------------------------------------------------------------------------------------
function ADAddonTurnLightsOtherMods.isDrivenByFarmPilot(vehicle)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.isActive ~= nil
        and vehicle.ad.stateModule:isActive() == true
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place (une fois, dès que la spécialisation de l'autre mod existe)
-- ------------------------------------------------------------------------------------------------------------
function ADAddonTurnLightsOtherMods.install()
    if ADAddonTurnLightsOtherMods.done or g_specializationManager == nil or g_specializationManager.getSpecializationObjectByName == nil then
        return
    end
    ADAddonTurnLightsOtherMods.done = true
    for specName, label in pairs(ADAddonTurnLightsOtherMods.KNOWN) do
        local spec = g_specializationManager:getSpecializationObjectByName(specName)
        if spec ~= nil and type(spec.onUpdate) == "function" and not spec.fpTurnLightsWrapped then
            local original = spec.onUpdate
            spec.fpTurnLightsWrapped = true
            -- l'événement onUpdate est appelé par spec[eventName](...) : la fonction remplacée ici est celle appelée
            spec.onUpdate = function(vehicle, ...)
                if ADAddonTurnLightsOtherMods.isDrivenByFarmPilot(vehicle) then
                    local drivable = vehicle.spec_drivable
                    if drivable ~= nil then
                        drivable.hasSteeredToTurnLeftDirection = false
                        drivable.hasSteeredToTurnRightDirection = false
                    end
                    return
                end
                return original(vehicle, ...)
            end
            print(string.format("[AD-Clignotant] %s : sans effet pendant que FarmPilot conduit", label))
        end
    end
end
