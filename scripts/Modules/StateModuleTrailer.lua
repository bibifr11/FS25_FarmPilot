-- ============================================================================================================
-- FarmPilot : StateModuleTrailer.lua
-- Complément de ADStateModule (module AutoDrive d'origine) : la remorque choisie sur la ligne « Remorque » du HUD
-- (modes avec benne, voir Modes/TrailerHitch.lua).
--
-- (09/11) même principe que l'outil du mode Autonome (StateModuleAutonomous.lua) : nil = celle attelée ; gardée
-- dans la sauvegarde par l'identifiant unique de la remorque (chargée après le tracteur), envoyée aux clients.
--
-- (09/11) échange de bennes (Modes/TrailerSwap.lua) : dossier de marqueurs des places (fpSwapFolder, nil = pas
-- d'échange), réglé par la roue dentée de la ligne « Remorque » ; gardé dans la sauvegarde, envoyé aux clients.
--
-- Branché par une ligne en fin de resetAutonomousState, loadAutonomousState, saveAutonomousState,
-- writeAutonomousState et readAutonomousState (StateModuleAutonomous.lua) : en réseau, même ordre des deux côtés.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Champs de l'état, sauvegarde, réseau
-- ------------------------------------------------------------------------------------------------------------
function ADStateModule:resetTrailerState()
    self.fpTrailer = nil
    self.fpTrailerUniqueId = nil -- sauvegarde (remorque chargée après le tracteur)
    self.fpTrailerNetId = nil -- client : remorque pas encore reçue
    self.fpSwapFolder = nil
end

function ADStateModule:loadTrailerState(xmlFile, key)
    self.fpTrailer = nil
    self.fpTrailerNetId = nil
    self.fpTrailerUniqueId = xmlFile:getValue(key .. "#fpTrailer")
    if self.fpTrailerUniqueId == "" then
        self.fpTrailerUniqueId = nil
    end
    self.fpSwapFolder = xmlFile:getValue(key .. "#fpSwapFolder")
    if self.fpSwapFolder == "" then
        self.fpSwapFolder = nil
    end
end

function ADStateModule:saveTrailerState(xmlFile, key)
    local trailer = self:getFpTrailer()
    local uniqueId = trailer ~= nil and trailer.getUniqueId ~= nil and trailer:getUniqueId() or self.fpTrailerUniqueId
    if uniqueId ~= nil and uniqueId ~= "" then
        xmlFile:setValue(key .. "#fpTrailer", uniqueId)
    end
    if self.fpSwapFolder ~= nil and self.fpSwapFolder ~= "" then
        xmlFile:setValue(key .. "#fpSwapFolder", self.fpSwapFolder)
    end
end

function ADStateModule:writeTrailerState(streamId)
    local trailer = self:getFpTrailer()
    local trailerId = trailer ~= nil and NetworkUtil.getObjectId(trailer) or nil
    streamWriteBool(streamId, trailerId ~= nil)
    if trailerId ~= nil then
        NetworkUtil.writeNodeObjectId(streamId, trailerId)
    end
    streamWriteString(streamId, self.fpSwapFolder or "")
end

function ADStateModule:readTrailerState(streamId)
    if streamReadBool(streamId) then
        self.fpTrailerNetId = NetworkUtil.readNodeObjectId(streamId)
        self.fpTrailer = NetworkUtil.getObject(self.fpTrailerNetId)
    else
        self.fpTrailerNetId = nil
        self.fpTrailer = nil
    end
    self.fpTrailerUniqueId = nil
    self.fpSwapFolder = streamReadString(streamId)
    if self.fpSwapFolder == "" then
        self.fpSwapFolder = nil
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Accesseurs
-- ------------------------------------------------------------------------------------------------------------
-- remorque choisie, que le chauffeur va atteler avant de partir (nil = celle attelée)
function ADStateModule:getFpTrailer()
    local trailer = self.fpTrailer
    if trailer ~= nil and (trailer.isDeleted or trailer.isDeleting) then
        self.fpTrailer = nil
        self.fpTrailerUniqueId = nil
        trailer = nil
    end
    if trailer == nil and self.fpTrailerUniqueId ~= nil and g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil
        and g_currentMission.vehicleSystem.getVehicleByUniqueId ~= nil then
        trailer = g_currentMission.vehicleSystem:getVehicleByUniqueId(self.fpTrailerUniqueId)
        self.fpTrailer = trailer
    end
    if trailer == nil and self.fpTrailerNetId ~= nil then
        trailer = NetworkUtil.getObject(self.fpTrailerNetId)
        self.fpTrailer = trailer
    end
    return trailer
end

-- dossier des places de l'échange de bennes (nil = pas d'échange)
function ADStateModule:getFpSwapFolder()
    return self.fpSwapFolder
end

function ADStateModule:setFpSwapFolder(folder)
    if folder == "" then
        folder = nil
    end
    self.fpSwapFolder = folder
    self:raiseDirtyFlag()
end

function ADStateModule:setFpTrailer(trailer)
    self.fpTrailer = trailer
    self.fpTrailerNetId = nil
    self.fpTrailerUniqueId = trailer ~= nil and trailer.getUniqueId ~= nil and trailer:getUniqueId() or nil
    self:raiseDirtyFlag()
end
