-- ============================================================================================================
-- FarmPilot : DriveOverObjects.lua
-- Objets sur lesquels on roule (18/11) : pont-bascule et toute plateforme avec un déclencheur de pesée.
--
-- Défaut (18/11, 942 Vario + épandeur, « vider le reste ») : le balayage devant (ApproachModule, à partir de 0,30 m
-- au-dessus du sol) voyait le bord de la « Grande station de pesage » : écart dans l'herbe le long du hangar, puis
-- retour sur la ligne et arrêt à 0,6 m du pont, sans fin.
--
-- Règle : un placeable qui pèse les véhicules (spec_weighingStation, ou une spec avec triggerVehicleNodes, comme
-- Weighing.lua les trouve) n'est jamais un obstacle : ni pour le balayage devant (ApproachModule:isIgnored), ni pour
-- les capteurs avant (CollSensor, CollSensorSplit). Les autres objets ne changent pas.
--
-- Branché par : ApproachModule.lua (isIgnored), CollSensor.lua et CollSensorSplit.lua (collisionTestCallback).
-- Chargé par register.lua avant ApproachModule.lua.
-- ============================================================================================================

ADDriveOver = {}
ADDriveOver.cache = setmetatable({}, { __mode = "k" })

-- true : on roule dessus (pont-bascule)
function ADDriveOver.isDriveOver(object)
    if type(object) ~= "table" then
        return false
    end
    local c = ADDriveOver.cache[object]
    if c ~= nil then
        return c
    end
    local yes = object.spec_weighingStation ~= nil
    if not yes then
        for key, value in pairs(object) do
            if type(key) == "string" and key:sub(1, 5) == "spec_" and type(value) == "table" and value.triggerVehicleNodes ~= nil then
                yes = true
                break
            end
        end
    end
    ADDriveOver.cache[object] = yes
    return yes
end
