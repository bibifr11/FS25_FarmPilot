-- ============================================================================================================
-- FarmPilot : AutonomousToolEvent.lua
-- Mode Autonome : événement réseau « outil choisi dans le HUD », envoyé au serveur.
--
-- Règle : ligne « Outil » : outil choisi, nil = celui attelé ; ligne « Outil suivant » (isNext) : outil du champ
-- suivant, nil = le même. Le serveur refuse un outil qui ne peut pas être attelé (AutonomousManagerTools.lua :
-- isFetchableTool).
--
-- (09/11) ligne « Remorque » des modes avec benne (isTrailer) : remorque à aller atteler au départ, nil = celle attelée
-- (Modes/TrailerHitch.lua : isFetchableTrailer).
--
-- (10/11) lignes « Outil avant » et « Outil avant suivant » (isFront, isNext) : outil frontal ou masse, nil = celui
-- attelé / le même (AutonomousManagerFront.lua : isFetchableFront).
--
-- Branché par : PullDownList.lua (choix dans la liste des outils du HUD : ADAutonomousToolEvent.send).
-- ============================================================================================================

ADAutonomousToolEvent = {}
ADAutonomousToolEvent_mt = Class(ADAutonomousToolEvent, Event)

InitEventClass(ADAutonomousToolEvent, "ADAutonomousToolEvent")

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousToolEvent.emptyNew()
    local self = Event.new(ADAutonomousToolEvent_mt)
    return self
end

function ADAutonomousToolEvent.new(vehicle, tool, isNext, isTrailer, isFront)
    local self = ADAutonomousToolEvent.emptyNew()
    self.vehicle = vehicle
    self.tool = tool
    self.isNext = isNext == true
    self.isTrailer = isTrailer == true
    self.isFront = isFront == true
    return self
end

-- ------------------------------------------------------------------------------------------------------------
-- Réseau
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousToolEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(self.vehicle))
    streamWriteBool(streamId, self.isNext == true)
    streamWriteBool(streamId, self.isTrailer == true)
    streamWriteBool(streamId, self.isFront == true)
    local toolId = self.tool ~= nil and NetworkUtil.getObjectId(self.tool) or nil
    streamWriteBool(streamId, toolId ~= nil)
    if toolId ~= nil then
        NetworkUtil.writeNodeObjectId(streamId, toolId)
    end
end

function ADAutonomousToolEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    self.isNext = streamReadBool(streamId)
    self.isTrailer = streamReadBool(streamId)
    self.isFront = streamReadBool(streamId)
    self.tool = nil
    if streamReadBool(streamId) then
        self.tool = NetworkUtil.getObject(NetworkUtil.readNodeObjectId(streamId))
    end
    self:run(connection)
end

-- ------------------------------------------------------------------------------------------------------------
-- Sur le serveur : outil enregistré
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousToolEvent:run(connection)
    if g_server == nil or self.vehicle == nil or self.vehicle.ad == nil or self.vehicle.ad.stateModule == nil then
        return
    end
    local tool = self.tool
    if self.isTrailer then
        if tool ~= nil and (ADTrailerHitch == nil or not ADTrailerHitch.isFetchableTrailer(self.vehicle, tool)) then
            ADAutonomousManager.log("%s : remorque refusée (%s)", tostring(self.vehicle.ad.stateModule:getName()), tostring(tool.getName ~= nil and tool:getName() or "?"))
            return
        end
        self.vehicle.ad.stateModule:setFpTrailer(tool)
        ADAutonomousManager.log("%s : remorque choisie « %s »", tostring(self.vehicle.ad.stateModule:getName()), tool ~= nil and ADTrailerHitch.label(tool) or "celle attelée")
        return
    end
    if self.isFront then
        -- (10/11) attelage avant : outil frontal ou masse
        if tool ~= nil and not ADAutonomousManager.isFetchableFront(self.vehicle, tool) then
            ADAutonomousManager.log("%s : outil avant refusé (%s)", tostring(self.vehicle.ad.stateModule:getName()), tostring(tool.getName ~= nil and tool:getName() or "?"))
            return
        end
        local label = tool ~= nil and ADAutonomousManager.frontLabel(tool) or nil
        if self.isNext then
            self.vehicle.ad.stateModule:setFpNextFrontTool(tool)
            ADAutonomousManager.log("%s : outil avant du champ suivant « %s »", tostring(self.vehicle.ad.stateModule:getName()), label or "le même")
        else
            self.vehicle.ad.stateModule:setFpFrontTool(tool)
            ADAutonomousManager.log("%s : outil avant choisi « %s »", tostring(self.vehicle.ad.stateModule:getName()), label or "celui attelé")
        end
        return
    end
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

-- ------------------------------------------------------------------------------------------------------------
-- Envoi
-- ------------------------------------------------------------------------------------------------------------
-- client (ou serveur local) -> serveur
function ADAutonomousToolEvent.send(vehicle, tool, isNext, isTrailer, isFront)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(ADAutonomousToolEvent.new(vehicle, tool, isNext, isTrailer, isFront))
    end
end
