-- ============================================================================================================
-- FarmPilot : SavegameResume.lua
-- Chargement d'une partie (13/11) : « Collecter et livrer » reprend ce qu'il faisait, et le réseau est caché.
--
-- 1. « Collecter et livrer » : reprise après le chargement de la partie
--    Avant : la sauvegarde ne gardait que « le véhicule roulait ». Au redémarrage (relance automatique des aides
--    ou à la main), le mode repartait de zéro et ne regardait que le remplissage : sous le niveau de
--    déchargement (85 % par défaut), il retournait charger, même avec une benne chargée en route pour livrer ou
--    une benne en train de vider au point de livraison.
--    Règles :
--    - À la sauvegarde d'un véhicule actif en « Collecter et livrer » : la phase en cours est écrite
--      (#fpPickupPhase : « load » = aller charger / charger ; « unload » = aller livrer / vider). Véhicule pas
--      encore reparti depuis le chargement : la phase lue est gardée.
--    - Au premier départ du mode après le chargement de la partie (une seule fois) :
--      « unload » et de la charge dans la benne : il va livrer (et finit de vider s'il est sur place), quel que
--      soit le niveau de déchargement ;
--      « load » et la benne pas pleine : il va charger (et finit de charger s'il est sur place), même au-dessus
--      du niveau de déchargement ;
--      sinon (benne vide, benne pleine, pas de phase) : comme avant.
--    - Destinations multiples : la première reprise garde la destination en cours (ADMultipleTargetsManager
--      repart de la destination du véhicule après un chargement).
--    - Le journal dit la reprise : « [FarmPilot Reprise] <véhicule> : ... ».
--
-- 2. Réseau caché au chargement
--    Avant : l'affichage du réseau (points et lignes, touche « Afficher les points » ou éditeur) était remis tel
--    qu'au moment de la sauvegarde (réglage par joueur, AutoDriveUsersData.xml, et ancienne valeur possible dans
--    la config du réseau).
--    Règle : au chargement de la partie, le réseau est toujours caché (éditeur fermé). La touche du joueur
--    l'affiche comme avant. L'état de l'affichage n'est plus sauvegardé.
--
-- (15/11) Mode Autonome en train de rentrer au garage : sauvegarde et reprise dans AutonomousResumeReturn.lua
-- (enveloppes de ADSavegameResume.save / .load, clé #fpAutoReturn).
--
-- Branché par une ligne chacune : StateModule.lua (saveToXMLFile, readFromXMLFile), PickupAndDeliverMode.lua
-- (getNextTask, état de départ), Specialization.lua (clé #fpPickupPhase de la sauvegarde) et AutoDrive.lua
-- (loadMap, après la lecture des réglages). Chargé par register.lua après PickupAndDeliverMode.lua.
-- ============================================================================================================

ADSavegameResume = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADSavegameResume.MIN_LOAD = 0.1        -- litres : en dessous, la benne est vide
ADSavegameResume.FULL_FREE = 0.001     -- part de place libre : en dessous, la benne est pleine

function ADSavegameResume.log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print("[FarmPilot Reprise] " .. (ok and s or tostring(fmt)))
end

-- ------------------------------------------------------------------------------------------------------------
-- 1. « Collecter et livrer » : phase sauvegardée, reprise au premier départ
-- ------------------------------------------------------------------------------------------------------------
-- phase en cours du mode : « load », « unload » ou nil
-- (noms des états d'origine : STATE_DELIVER = aller charger, STATE_PICKUP = aller livrer ; pendant la tâche,
-- STATE_PICKUP_FROM_NEXT_TARGET = charge, STATE_DELIVER_TO_NEXT_TARGET = livre)
function ADSavegameResume.phase(mode)
    if mode == nil or mode.state == nil or PickupAndDeliverMode == nil then
        return nil
    end
    local s = mode.state
    if s == PickupAndDeliverMode.STATE_DELIVER_TO_NEXT_TARGET or s == PickupAndDeliverMode.STATE_PICKUP then
        return "unload"
    elseif s == PickupAndDeliverMode.STATE_PICKUP_FROM_NEXT_TARGET or s == PickupAndDeliverMode.STATE_DELIVER then
        return "load"
    end
    return nil
end

-- StateModule.lua, saveToXMLFile
function ADSavegameResume.save(stateModule, xmlFile, key)
    local phase = nil
    local vehicle = stateModule.vehicle
    if stateModule.active and stateModule.mode == AutoDrive.MODE_PICKUPANDDELIVER and vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.modes ~= nil then
        phase = ADSavegameResume.phase(vehicle.ad.modes[AutoDrive.MODE_PICKUPANDDELIVER])
    elseif not stateModule.active then
        phase = stateModule.fpPickupPhase -- pas encore reparti depuis le chargement : phase lue gardée
    end
    if phase ~= nil then
        xmlFile:setValue(key .. "#fpPickupPhase", phase)
    end
end

-- StateModule.lua, readFromXMLFile
function ADSavegameResume.load(stateModule, xmlFile, key)
    local phase = xmlFile:getValue(key .. "#fpPickupPhase")
    if phase == "load" or phase == "unload" then
        stateModule.fpPickupPhase = phase
    else
        stateModule.fpPickupPhase = nil
    end
end

-- PickupAndDeliverMode.lua, getNextTask, état de départ : « remplie pour décharger ? » corrigé par la phase lue
function ADSavegameResume.pickupStart(mode, filledToUnload)
    local vehicle = mode ~= nil and mode.vehicle or nil
    local stateModule = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if stateModule == nil or stateModule.fpPickupPhase == nil then
        return filledToUnload
    end
    local phase = stateModule.fpPickupPhase
    stateModule.fpPickupPhase = nil -- une seule fois
    if mode.trailers == nil or #mode.trailers == 0 then
        return filledToUnload
    end
    local fillLevel, fillCapacity, _, fillFree = AutoDrive.getAllFillLevels(mode.trailers)
    fillLevel, fillCapacity, fillFree = fillLevel or 0, fillCapacity or 0, fillFree or 0
    local percent = fillCapacity > 0 and math.floor(100 * fillLevel / fillCapacity + 0.5) or 0
    local name = tostring(stateModule:getName())
    if phase == "unload" and fillLevel > ADSavegameResume.MIN_LOAD then
        ADSavegameResume.log("%s : partie rechargée pendant la livraison, benne à %d %% : va livrer", name, percent)
        return true
    elseif phase == "load" and fillCapacity > 0 and fillFree > fillCapacity * ADSavegameResume.FULL_FREE then
        ADSavegameResume.log("%s : partie rechargée pendant le chargement, benne à %d %% : va charger", name, percent)
        return false
    end
    ADSavegameResume.log("%s : partie rechargée (phase %s, benne à %d %%) : départ habituel", name, phase, percent)
    return filledToUnload
end

-- ------------------------------------------------------------------------------------------------------------
-- 2. Réseau caché au chargement
-- ------------------------------------------------------------------------------------------------------------
if AutoDrive ~= nil and AutoDrive.settings ~= nil and AutoDrive.settings.EditorMode ~= nil then
    AutoDrive.settings.EditorMode.shallNotBeSaved = true -- plus écrit dans AutoDriveUsersData.xml, ni relu
end

-- AutoDrive.lua, loadMap, après la config du réseau et les réglages des joueurs
function ADSavegameResume.hideNetwork()
    local setting = AutoDrive.settings ~= nil and AutoDrive.settings.EditorMode or nil
    if setting ~= nil and AutoDrive.EDITOR_OFF ~= nil and AutoDrive.getSettingState("EditorMode") ~= AutoDrive.EDITOR_OFF then
        AutoDrive.setSettingState("EditorMode", AutoDrive.EDITOR_OFF)
    end
end
