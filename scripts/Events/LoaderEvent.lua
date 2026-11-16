-- ============================================================================================================
-- FarmPilot : LoaderEvent.lua
-- Événement réseau du mode « Chargeur » (Hud/HudLoader.lua), envoyé au serveur : réglages du véhicule
-- (« src;sx:sz;dst;px:pz;qty », Modes/LoaderJob.lua).
-- ============================================================================================================

ADLoaderEvent = {}
ADLoaderEvent_mt = Class(ADLoaderEvent, Event)

InitEventClass(ADLoaderEvent, "ADLoaderEvent")

function ADLoaderEvent.emptyNew()
    local self = Event.new(ADLoaderEvent_mt)
    return self
end

function ADLoaderEvent.new(vehicle, cfgText)
    local self = ADLoaderEvent.emptyNew()
    self.vehicle = vehicle
    self.cfgText = cfgText or ""
    return self
end

function ADLoaderEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.vehicle))
    streamWriteString(streamId, self.cfgText)
end

function ADLoaderEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    self.cfgText = streamReadString(streamId)
    self:run(connection)
end

-- sur le serveur
function ADLoaderEvent:run(connection)
    local v = self.vehicle
    if g_server == nil or v == nil or v.ad == nil or ADLoaderJob == nil then
        return
    end
    if self.cfgText ~= "" then
        ADLoaderJob.setCfg(v, ADLoaderJob.textToCfg(self.cfgText))
    end
end

-- client (ou serveur local) -> serveur
function ADLoaderEvent.send(vehicle, cfgText)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(ADLoaderEvent.new(vehicle, cfgText))
    end
end
