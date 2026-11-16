-- ============================================================================================================
-- FarmPilot : SiloCompactEvent.lua
-- Événement réseau de la fenêtre « Tassage » (Gui/SiloCompactGUI.lua), envoyé au serveur : réglages du tracteur,
-- et Démarrer (silo désigné par son centre) ou Arrêter. Le travail est fait par Modes/SiloCompactorTask.lua.
-- ============================================================================================================

ADSiloCompactEvent = {}
ADSiloCompactEvent_mt = Class(ADSiloCompactEvent, Event)

InitEventClass(ADSiloCompactEvent, "ADSiloCompactEvent")

ADSiloCompactEvent.SAVE = 0
ADSiloCompactEvent.START = 1
ADSiloCompactEvent.STOP = 2

function ADSiloCompactEvent.emptyNew()
    local self = Event.new(ADSiloCompactEvent_mt)
    return self
end

function ADSiloCompactEvent.new(vehicle, action, cfgText, x, z)
    local self = ADSiloCompactEvent.emptyNew()
    self.vehicle = vehicle
    self.action = action
    self.cfgText = cfgText or ""
    self.x = x or 0
    self.z = z or 0
    return self
end

function ADSiloCompactEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.vehicle))
    streamWriteUIntN(streamId, self.action, 2)
    streamWriteString(streamId, self.cfgText)
    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.z)
end

function ADSiloCompactEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    self.action = streamReadUIntN(streamId, 2)
    self.cfgText = streamReadString(streamId)
    self.x = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)
    self:run(connection)
end

-- sur le serveur
function ADSiloCompactEvent:run(connection)
    local v = self.vehicle
    if g_server == nil or v == nil or v.ad == nil or v.ad.stateModule == nil or ADSiloJob == nil then
        return
    end
    if self.cfgText ~= "" then
        ADSiloJob.setCfg(v, ADSiloJob.textToCfg(self.cfgText))
    end
    if self.action == ADSiloCompactEvent.START then
        local silo = ADSiloJob.findSilo(self.x, self.z)
        FarmPilotCall(ADSiloJob.start, v, silo)
    elseif self.action == ADSiloCompactEvent.STOP then
        FarmPilotCall(ADSiloJob.stop, v)
    end
end

-- client (ou serveur local) -> serveur
function ADSiloCompactEvent.send(vehicle, action, cfgText, x, z)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(ADSiloCompactEvent.new(vehicle, action, cfgText, x, z))
    end
end
