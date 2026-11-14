-- ============================================================================================================
-- FarmPilot : StateModuleHeader.lua
-- Complément de ADStateModule (module AutoDrive d'origine) : véhicule choisi pour la remorque porte-barre d'une
-- moissonneuse en Autonome (Modes/AutonomousHeader.lua).
--
-- Règle (11/11) : réglé par la roue dentée de la ligne « Outil » de la moissonneuse (Gui/HeaderTractorGUI.lua).
-- nil = le tracteur libre le plus proche, sans rien d'attelé. Gardé dans la sauvegarde par l'identifiant unique du
-- véhicule (chargé après la moissonneuse), envoyé aux clients.
--
-- Branché par une ligne en fin de resetAutonomousState, loadAutonomousState, saveAutonomousState,
-- writeAutonomousState et readAutonomousState (StateModuleAutonomous.lua), après celles de StateModuleTrailer.lua :
-- en réseau, même ordre des deux côtés. Clé de sauvegarde déclarée dans Specialization.lua (#fpHeaderTractor).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Champs de l'état, sauvegarde, réseau
-- ------------------------------------------------------------------------------------------------------------
function ADStateModule:resetHeaderState()
    self.fpHeaderTractor = nil
    self.fpHeaderTractorUniqueId = nil -- sauvegarde (véhicule chargé après la moissonneuse)
    self.fpHeaderTractorNetId = nil -- client : véhicule pas encore reçu
end

function ADStateModule:loadHeaderState(xmlFile, key)
    self.fpHeaderTractor = nil
    self.fpHeaderTractorNetId = nil
    self.fpHeaderTractorUniqueId = xmlFile:getValue(key .. "#fpHeaderTractor")
    if self.fpHeaderTractorUniqueId == "" then
        self.fpHeaderTractorUniqueId = nil
    end
end

function ADStateModule:saveHeaderState(xmlFile, key)
    local v = self:getFpHeaderTractor()
    local uniqueId = v ~= nil and v.getUniqueId ~= nil and v:getUniqueId() or self.fpHeaderTractorUniqueId
    if uniqueId ~= nil and uniqueId ~= "" then
        xmlFile:setValue(key .. "#fpHeaderTractor", uniqueId)
    end
end

function ADStateModule:writeHeaderState(streamId)
    local v = self:getFpHeaderTractor()
    local id = v ~= nil and NetworkUtil.getObjectId(v) or nil
    streamWriteBool(streamId, id ~= nil)
    if id ~= nil then
        NetworkUtil.writeNodeObjectId(streamId, id)
    end
end

function ADStateModule:readHeaderState(streamId)
    if streamReadBool(streamId) then
        self.fpHeaderTractorNetId = NetworkUtil.readNodeObjectId(streamId)
        self.fpHeaderTractor = NetworkUtil.getObject(self.fpHeaderTractorNetId)
    else
        self.fpHeaderTractorNetId = nil
        self.fpHeaderTractor = nil
    end
    self.fpHeaderTractorUniqueId = nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Accesseurs
-- ------------------------------------------------------------------------------------------------------------
-- véhicule choisi pour la remorque porte-barre (nil = le tracteur libre le plus proche)
function ADStateModule:getFpHeaderTractor()
    local v = self.fpHeaderTractor
    if v ~= nil and (v.isDeleted or v.isDeleting) then
        self.fpHeaderTractor = nil
        self.fpHeaderTractorUniqueId = nil
        v = nil
    end
    if v == nil and self.fpHeaderTractorUniqueId ~= nil and g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil
        and g_currentMission.vehicleSystem.getVehicleByUniqueId ~= nil then
        v = g_currentMission.vehicleSystem:getVehicleByUniqueId(self.fpHeaderTractorUniqueId)
        self.fpHeaderTractor = v
    end
    if v == nil and self.fpHeaderTractorNetId ~= nil then
        v = NetworkUtil.getObject(self.fpHeaderTractorNetId)
        self.fpHeaderTractor = v
    end
    return v
end

function ADStateModule:setFpHeaderTractor(v)
    self.fpHeaderTractor = v
    self.fpHeaderTractorNetId = nil
    self.fpHeaderTractorUniqueId = v ~= nil and v.getUniqueId ~= nil and v:getUniqueId() or nil
    self:raiseDirtyFlag()
end
