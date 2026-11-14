-- ============================================================================================================
-- FarmPilot : HeaderTractorEvent.lua
-- Événement réseau « véhicule de la remorque porte-barre », envoyé au serveur.
--
-- (11/11) fenêtre « Transport de la barre » (Gui/HeaderTractorGUI.lua) : véhicule choisi pour une moissonneuse, ou
-- aucun (le tracteur libre le plus proche). Le serveur l'enregistre dans l'état de la moissonneuse
-- (StateModuleHeader.lua : setFpHeaderTractor), qui part ensuite chez les clients avec le reste de l'état.
--
-- Branché par : HeaderTractorGUI.lua (choix : ADHeaderTractorEvent.send).
-- ============================================================================================================

ADHeaderTractorEvent = {}
ADHeaderTractorEvent_mt = Class(ADHeaderTractorEvent, Event)

InitEventClass(ADHeaderTractorEvent, "ADHeaderTractorEvent")

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderTractorEvent.emptyNew()
    local self = Event.new(ADHeaderTractorEvent_mt)
    return self
end

function ADHeaderTractorEvent.new(vehicle, tractor)
    local self = ADHeaderTractorEvent.emptyNew()
    self.vehicle = vehicle
    self.tractor = tractor
    return self
end

-- ------------------------------------------------------------------------------------------------------------
-- Réseau
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderTractorEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.vehicle))
    streamWriteBool(streamId, self.tractor ~= nil)
    if self.tractor ~= nil then
        NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.tractor))
    end
end

function ADHeaderTractorEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    self.tractor = nil
    if streamReadBool(streamId) then
        self.tractor = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    end
    self:run(connection)
end

-- ------------------------------------------------------------------------------------------------------------
-- Sur le serveur : véhicule enregistré
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderTractorEvent:run(connection)
    if g_server == nil or self.vehicle == nil or self.vehicle.ad == nil or self.vehicle.ad.stateModule == nil
        or self.vehicle.ad.stateModule.setFpHeaderTractor == nil then
        return
    end
    self.vehicle.ad.stateModule:setFpHeaderTractor(self.tractor)
    ADHeaderFlow.log("%s : remorque porte-barre déplacée par %s", tostring(self.vehicle.ad.stateModule:getName()),
        self.tractor ~= nil and ("« " .. ADHeaderFlow.vehicleName(self.tractor) .. " »") or "le tracteur libre le plus proche")
end

-- ------------------------------------------------------------------------------------------------------------
-- Envoi
-- ------------------------------------------------------------------------------------------------------------
-- client (ou serveur local) -> serveur
function ADHeaderTractorEvent.send(vehicle, tractor)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(ADHeaderTractorEvent.new(vehicle, tractor))
    end
end
