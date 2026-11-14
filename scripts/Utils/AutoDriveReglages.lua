-- ============================================================================================================
-- FarmPilot : AutoDriveReglages.lua
-- Réglages généraux relus dans FarmPilot_config.xml : un index enregistré qui n'existe plus dans la liste du
-- réglage est remis à la valeur par défaut dès le chargement (14/11).
--
-- Cas qui l'a demandé : « Clignotant automatique » (blinkValue) passe d'un angle de 0 à 160° (17 valeurs) à un
-- simple Oui/Non (Settings.lua). Une partie enregistrée avec l'index 8 (70°) n'a plus de 8e valeur :
-- AutoDrive.getSetting la corrigeait déjà au premier appel, mais la page des réglages, ouverte avant, gardait
-- l'index 8 en mémoire. Ici : ancien index 1 (0°) = Non, tout autre ancien index = Oui (le défaut).
--
-- Branché par une ligne dans AutoDrive.readFromXML (XML.lua), juste après la lecture des réglages généraux.
-- Chargé par register.lua après Settings.lua.
-- ============================================================================================================

ADReglages = {}

function ADReglages.fixIndexes()
    for settingName, setting in pairs(AutoDrive.settings) do
        if not setting.isVehicleSpecific and setting.values ~= nil and setting.current ~= nil
            and setting.values[setting.current] == nil then
            local before = setting.current
            setting.current = setting.default or 1
            if setting.values[setting.current] == nil then
                setting.current = 1
            end
            print(string.format("[FarmPilot Reglages] %s : index enregistre %s hors liste (%d valeurs), remis a %d",
                settingName, tostring(before), #setting.values, setting.current))
        end
    end
end
