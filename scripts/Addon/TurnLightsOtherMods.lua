-- ============================================================================================================
-- FarmPilot : TurnLightsOtherMods.lua
-- Complément de TurnLights.lua : les autres mods qui éteignent le clignotant restent sans effet pendant que
-- FarmPilot conduit.
--
-- (08/11) Souvent affiché : interrompu par un autre script. Trouver ce script pour le désactiver pendant que
-- FarmPilot conduit.
--
-- Script trouvé dans les mods installés : FS25_autoTurnOffTurnLights (Ifko[nator]), spécialisation
-- « autoTurnOffTurnLights ». Son onUpdate éteint le clignotant dès que le volant revient vers le centre après
-- avoir tourné du côté du clignotant. Avec FarmPilot au volant, le moindre coup de volant avant le virage
-- suffit à l'éteindre (log « clignotant eteint par un autre script »), FarmPilot le rallume, d'où un clignotant
-- qui ne s'allume pas à la bonne distance.
--
-- Règle : véhicule conduit par FarmPilot = l'onUpdate de ce mod ne fait rien (ses repères de coup de volant
-- sont remis à zéro à chaque passage). Joueur au volant, ou Courseplay, ou l'ouvrier du jeu : ce mod marche comme avant.
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
-- Mise en place, par véhicule
-- V1.0.1.13 cherchait la spécialisation une seule fois au démarrage (g_specializationManager) : pas trouvée en jeu
-- (aucune ligne « sans effet » au log du 08/11 21:48, « éteint par un autre script » toujours là). Maintenant :
--  1) à chaque passage pendant que FarmPilot conduit, ses repères de coup de volant sont remis à zéro. Son
--     onUpdate ne peut éteindre qu'au passage qui suit celui où il a posé un repère : remis à zéro entre les deux,
--     il n'éteint jamais, quel que soit l'ordre des mises à jour ;
--  2) en plus, sa fonction onUpdate est remplacée, trouvée sur le type du véhicule (specializationsByName).
-- ------------------------------------------------------------------------------------------------------------
local function wrap(spec, label)
    if type(spec) ~= "table" or type(spec.onUpdate) ~= "function" or spec.fpTurnLightsWrapped then
        return
    end
    local original = spec.onUpdate
    spec.fpTurnLightsWrapped = true
    -- l'événement onUpdate est appelé par spec[eventName](...) : la fonction remplacée ici est celle appelée
    spec.onUpdate = function(vehicle, ...)
        if ADAddonTurnLightsOtherMods.isDrivenByFarmPilot(vehicle) then
            return
        end
        return original(vehicle, ...)
    end
    print(string.format("[AD-Clignotant] %s : sans effet pendant que FarmPilot conduit", label))
end

-- appelé à chaque passage du clignotant FarmPilot (TurnLights.lua), véhicule conduit par FarmPilot
function ADAddonTurnLightsOtherMods.update(vehicle)
    if not ADAddonTurnLightsOtherMods.isDrivenByFarmPilot(vehicle) then
        return
    end
    local drivable = vehicle.spec_drivable
    if drivable ~= nil then
        drivable.hasSteeredToTurnLeftDirection = false
        drivable.hasSteeredToTurnRightDirection = false
    end
    local byName = vehicle.specializationsByName
    for specName, label in pairs(ADAddonTurnLightsOtherMods.KNOWN) do
        local spec = type(byName) == "table" and byName[specName] or nil
        if spec == nil and g_specializationManager ~= nil and g_specializationManager.getSpecializationObjectByName ~= nil then
            local ok, s = pcall(g_specializationManager.getSpecializationObjectByName, g_specializationManager, specName)
            spec = ok and s or nil
        end
        wrap(spec, label)
    end
end
