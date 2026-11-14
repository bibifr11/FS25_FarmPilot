-- ============================================================================================================
-- FarmPilot : StateModuleFieldClear.lua
-- Ligne « Champ » du mode Autonome remise à « Champ : aucun » quand le tracteur est garé à sa place (14/11).
--
-- D'où ça vient : capture du 14/11 vers 12 h 35 (heure de Paris), tracteur rentré après son champ, HUD toujours sur
-- « Champ 13 ». Depuis le 11/11, une fois garé, les lignes Outil AV, Outil AR, Outil AV suivant, Outil AR suivant
-- et Champ suivant reviennent à leur valeur par défaut (ADParkButton.clearChoices) ; la ligne « Champ » était
-- oubliée.
--
-- Règle :
-- - garé à sa place (même moment que les autres lignes : ADParkButton.clearChoices) : la ligne « Champ » affiche
--   « Champ : aucun » (mode Autonome). Le marqueur d'AutoDrive n'est pas effacé (il ne doit jamais être vide :
--   plus de 40 endroits du code d'origine le lisent), seul un drapeau fpFieldCleared est posé ;
-- - n'importe quel choix de la 1re ligne (liste, carte, touches, champ suivant qui passe en 1re ligne) enlève le
--   drapeau (enveloppe de ADStateModule:setFirstMarker) ;
-- - départ en Autonome par le joueur avec « Champ : aucun » : refusé, message « choisissez un champ » ;
-- - drapeau gardé dans la sauvegarde (vehicles.xml, AutoDrive#fpFieldCleared) et envoyé aux joueurs en réseau.
--
-- Branché par une ligne dans StateModuleAutonomous.lua (resetAutonomousState, loadAutonomousState,
-- saveAutonomousState, writeAutonomousState, readAutonomousState, en dernier), AutonomousParkButton.lua
-- (clearChoices), PullDownList.lua (getNewState_Target) et AutonomousMode.lua (start). Clé de sauvegarde déclarée
-- dans Specialization.lua. Chargé par register.lua après StateModuleFront.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- État, sauvegarde, réseau
-- ------------------------------------------------------------------------------------------------------------
function ADStateModule:resetFieldClearState()
    self.fpFieldCleared = false
end

function ADStateModule:loadFieldClearState(xmlFile, key)
    self.fpFieldCleared = xmlFile:getValue(key .. "#fpFieldCleared") == true
end

function ADStateModule:saveFieldClearState(xmlFile, key)
    if self.fpFieldCleared == true then
        xmlFile:setValue(key .. "#fpFieldCleared", true)
    end
end

function ADStateModule:writeFieldClearState(streamId)
    streamWriteBool(streamId, self.fpFieldCleared == true)
end

function ADStateModule:readFieldClearState(streamId)
    self.fpFieldCleared = streamReadBool(streamId)
end

-- ------------------------------------------------------------------------------------------------------------
-- Accesseurs
-- ------------------------------------------------------------------------------------------------------------
-- true : la ligne « Champ » du mode Autonome affiche « Champ : aucun »
function ADStateModule:isFpFieldCleared()
    return self.fpFieldCleared == true and self.getMode ~= nil and self:getMode() == AutoDrive.MODE_AUTONOMOUS
end

function ADStateModule:setFpFieldCleared(on)
    on = on == true
    if (self.fpFieldCleared == true) ~= on then
        self.fpFieldCleared = on
        self:raiseDirtyFlag()
    end
end

-- tout choix de la 1re ligne enlève « Champ : aucun »
local baseSetFirstMarker = ADStateModule.setFirstMarker
function ADStateModule:setFirstMarker(markerId)
    self.fpFieldCleared = false
    return baseSetFirstMarker(self, markerId)
end

-- ------------------------------------------------------------------------------------------------------------
-- Branchements
-- ------------------------------------------------------------------------------------------------------------
-- ADParkButton.clearChoices : tracteur garé, la ligne « Champ » se vide aussi ; texte pour le log, nil si rien
function ADStateModule.clearFieldOnParked(sm)
    if sm == nil or sm.fpFieldCleared == true then
        return nil
    end
    local name = sm.getFirstMarkerName ~= nil and sm:getFirstMarkerName() or nil
    sm:setFpFieldCleared(true)
    return string.format("Champ « %s »", tostring(name or "?"))
end

-- PullDownList:getNewState_Target : texte de la ligne repliée, nil = texte d'origine (nom du marqueur)
function ADStateModule.fieldLineText(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm ~= nil and sm.isFpFieldCleared ~= nil and sm:isFpFieldCleared() then
        return g_i18n:getText("AD_autonomous_fieldNone")
    end
    return nil
end

-- AutonomousMode:start : true si le départ du joueur est refusé (« Champ : aucun »)
function ADStateModule.refuseStartNoField(mode, user)
    local vehicle = mode.vehicle
    local sm = vehicle.ad.stateModule
    if user ~= AutoDrive.USER_PLAYER or sm.isFpFieldCleared == nil or not sm:isFpFieldCleared() then
        return false
    end
    ADAutonomousManager.log("%s : départ refusé, ligne « Champ » vide (garé après son dernier champ)", tostring(sm:getName()))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 10000, "AD_autonomous_fieldNoneStart")
    if sm:isActive() then
        vehicle:stopAutoDrive()
    end
    return true
end
