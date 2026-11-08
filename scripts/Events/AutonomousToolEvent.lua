-- FarmPilot mode Autonome : outil choisi dans le HUD (ligne « Outil », nil = celui attelé ; ligne « Outil suivant » si isNext : outil du
-- champ suivant, nil = le même), envoyé au serveur
ADAutonomousToolEvent = {}
ADAutonomousToolEvent_mt = Class(ADAutonomousToolEvent, Event)

InitEventClass(ADAutonomousToolEvent, "ADAutonomousToolEvent")

function ADAutonomousToolEvent.emptyNew()
    local self = Event.new(ADAutonomousToolEvent_mt)
    return self
end

function ADAutonomousToolEvent.new(vehicle, tool, isNext)
    local self = ADAutonomousToolEvent.emptyNew()
    self.vehicle = vehicle
    self.tool = tool
    self.isNext = isNext == true
    return self
end

function ADAutonomousToolEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.vehicle))
    streamWriteBool(streamId, self.isNext == true)
    local toolId = self.tool ~= nil and NetworkUtil.getObjectId(self.tool) or nil
    streamWriteBool(streamId, toolId ~= nil)
    if toolId ~= nil then
        NetworkUtil.writeNodeObjectId(streamId, toolId)
    end
end

function ADAutonomousToolEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    self.isNext = streamReadBool(streamId)
    self.tool = nil
    if streamReadBool(streamId) then
        self.tool = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    end
    self:run(connection)
end

function ADAutonomousToolEvent:run(connection)
    if g_server == nil or self.vehicle == nil or self.vehicle.ad == nil or self.vehicle.ad.stateModule == nil then
        return
    end
    local tool = self.tool
    if tool ~= nil and not ADAutonomousManager.isFetchableTool(self.vehicle, tool) then
        ADAutonomousManager.log("%s : outil refusé (%s)", tostring(self.vehicle.ad.stateModule:getName()), tostring(tool.getName ~= nil and tool:getName() or "?"))
        return
    end
    if self.isNext then
        self.vehicle.ad.stateModule:setFpNextTool(tool)
        ADAutonomousManager.log("%s : outil du champ suivant « %s »", tostring(self.vehicle.ad.stateModule:getName()), tool ~= nil and ADAutonomousManager.toolLabel(tool) or "le même")
        return
    end
    self.vehicle.ad.stateModule:setFpTool(tool)
    ADAutonomousManager.log("%s : outil choisi « %s »", tostring(self.vehicle.ad.stateModule:getName()), tool ~= nil and ADAutonomousManager.toolLabel(tool) or "celui attelé")
end

-- client (ou serveur local) -> serveur
function ADAutonomousToolEvent.send(vehicle, tool, isNext)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(ADAutonomousToolEvent.new(vehicle, tool, isNext))
    end
end
