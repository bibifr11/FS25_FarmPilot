-- ============================================================================================================
-- FarmPilot : TrailerSwapEvent.lua
-- Événement réseau « dossier des places de l'échange de bennes », envoyé au serveur.
--
-- (09/11) fenêtre « Échange de bennes » (Gui/TrailerSwapGUI.lua) : nom du dossier de marqueurs, "" = pas
-- d'échange. Le serveur l'enregistre dans l'état du véhicule (StateModuleTrailer.lua : setFpSwapFolder), qui part
-- ensuite chez les clients avec le reste de l'état.
--
-- Branché par : TrailerSwapGUI.lua (choix d'un dossier : ADTrailerSwapEvent.send).
-- ============================================================================================================

ADTrailerSwapEvent = {}
ADTrailerSwapEvent_mt = Class(ADTrailerSwapEvent, Event)

InitEventClass(ADTrailerSwapEvent, "ADTrailerSwapEvent")

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
function ADTrailerSwapEvent.emptyNew()
    local self = Event.new(ADTrailerSwapEvent_mt)
    return self
end

function ADTrailerSwapEvent.new(vehicle, folder)
    local self = ADTrailerSwapEvent.emptyNew()
    self.vehicle = vehicle
    self.folder = folder or ""
    return self
end

-- ------------------------------------------------------------------------------------------------------------
-- Réseau
-- ------------------------------------------------------------------------------------------------------------
function ADTrailerSwapEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.vehicle))
    streamWriteString(streamId, self.folder or "")
end

function ADTrailerSwapEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    self.folder = streamReadString(streamId)
    self:run(connection)
end

-- ------------------------------------------------------------------------------------------------------------
-- Sur le serveur : dossier enregistré
-- ------------------------------------------------------------------------------------------------------------
function ADTrailerSwapEvent:run(connection)
    if g_server == nil or self.vehicle == nil or self.vehicle.ad == nil or self.vehicle.ad.stateModule == nil
        or self.vehicle.ad.stateModule.setFpSwapFolder == nil then
        return
    end
    local folder = self.folder
    if folder ~= "" and (ADGraphManager:getGroups() == nil or ADGraphManager:getGroups()[folder] == nil) then
        ADTrailerSwap.log("%s : dossier refusé (%s)", tostring(self.vehicle.ad.stateModule:getName()), tostring(folder))
        return
    end
    self.vehicle.ad.stateModule:setFpSwapFolder(folder)
    ADTrailerSwap.log("%s : échange de bennes %s", tostring(self.vehicle.ad.stateModule:getName()),
        folder ~= "" and ("sur les places du dossier « " .. folder .. " »") or "arrêté (livraison normale)")
end

-- ------------------------------------------------------------------------------------------------------------
-- Envoi
-- ------------------------------------------------------------------------------------------------------------
-- client (ou serveur local) -> serveur
function ADTrailerSwapEvent.send(vehicle, folder)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(ADTrailerSwapEvent.new(vehicle, folder))
    end
end
