-- ============================================================================================================
-- FarmPilot : StateModuleAutonomous.lua
-- Complément de ADStateModule (module AutoDrive d'origine) : l'état propre au mode Autonome, et l'ordre des modes.
--
-- Contenu :
-- - ordre des modes au bouton, avec « Autonome » juste après « Conduite » (le numéro 6, BGA, reste hors du cycle) ;
-- - champ suivant (vide par défaut ; à la fin du champ il passe en 1re destination et se vide), outil à aller atteler
--   avant le champ, outil du champ suivant (4e ligne du HUD) : champs de l'état, sauvegarde (xml), réseau
--   (doWriteStream / doReadStream), rechargement du réseau de routes, accesseurs.
--
-- Règle : chaque bloc est appelé exactement où il était dans StateModule.lua ; en réseau, l'écriture et la lecture
-- gardent le même ordre (ici l'un sous l'autre, appelés au même endroit de doWriteStream / doReadStream).
--
-- Branché par une ligne dans StateModule.lua : reset, readFromXMLFile, saveToXMLFile, doWriteStream, doReadStream,
-- resetMarkersOnReload ; nextMode, previousMode et setMode appellent stepMode / isModeAllowed.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages : ordre des modes au bouton (nextMode, previousMode, setMode)
-- ------------------------------------------------------------------------------------------------------------
-- FarmPilot : ordre des modes au bouton, avec « Autonome » juste après « Conduite »
-- (le numéro 6, BGA, reste hors du cycle comme avant)
ADStateModule.MODE_CYCLE = {AutoDrive.MODE_DRIVETO, AutoDrive.MODE_AUTONOMOUS, AutoDrive.MODE_PICKUPANDDELIVER, AutoDrive.MODE_DELIVERTO, AutoDrive.MODE_LOAD, AutoDrive.MODE_UNLOAD}

function ADStateModule:isModeAllowed(mode)
    if mode == AutoDrive.MODE_UNLOAD and self.vehicle.spec_locomotive then
        -- skip harvester mode for train
        return false
    end
    if mode == AutoDrive.MODE_AUTONOMOUS and self.vehicle.spec_locomotive then
        return false
    end
    return table.contains(ADStateModule.MODE_CYCLE, mode)
end

function ADStateModule:stepMode(dir)
    local cycle = ADStateModule.MODE_CYCLE
    local idx = 1
    for i, m in ipairs(cycle) do
        if m == self.mode then
            idx = i
            break
        end
    end
    for _ = 1, #cycle do
        idx = idx + dir
        if idx > #cycle then
            idx = 1
        elseif idx < 1 then
            idx = #cycle
        end
        if self:isModeAllowed(cycle[idx]) then
            break
        end
    end
    self.mode = cycle[idx]
    self:setAutomaticPickupTarget(false) -- disable automatic target on mode change
    self:setAutomaticUnloadTarget(false) -- disable automatic target on mode change
    AutoDrive.Hud.lastUIScale = 0
    self:raiseDirtyFlag()
end

-- ------------------------------------------------------------------------------------------------------------
-- Champs de l'état (ADStateModule:reset)
-- ------------------------------------------------------------------------------------------------------------
function ADStateModule:resetAutonomousState()
    self.fpNextField = nil -- FarmPilot mode Autonome : champ suivant (vide par défaut)
    -- FarmPilot mode Autonome : outil à aller atteler avant le champ (nil = celui attelé)
    self.fpTool = nil
    self.fpToolUniqueId = nil -- sauvegarde (outil chargé après le tracteur)
    self.fpToolNetId = nil -- client : outil pas encore reçu
    -- FarmPilot mode Autonome : outil du champ suivant (nil = le même), 4e ligne du HUD
    self.fpNextTool = nil
    self.fpNextToolUniqueId = nil
    self.fpNextToolNetId = nil
    if self.resetTrailerState ~= nil then self:resetTrailerState() end -- remorque des modes avec benne, voir StateModuleTrailer.lua
    if self.resetFrontState ~= nil then self:resetFrontState() end -- attelage avant, voir StateModuleFront.lua
end

-- ------------------------------------------------------------------------------------------------------------
-- Sauvegarde (ADStateModule:readFromXMLFile, ADStateModule:saveToXMLFile)
-- ------------------------------------------------------------------------------------------------------------
function ADStateModule:loadAutonomousState(xmlFile, key)
    local fpNextField = xmlFile:getValue(key .. "#fpNextField")
    if fpNextField ~= nil and fpNextField >= 1 then
        self.fpNextField = ADGraphManager:getMarkerForLoad(fpNextField, xmlFile:getValue(key .. "#fpNextFieldName"))
    else
        self.fpNextField = nil
    end

    self.fpTool = nil
    self.fpToolNetId = nil
    self.fpToolUniqueId = xmlFile:getValue(key .. "#fpTool")
    if self.fpToolUniqueId == "" then
        self.fpToolUniqueId = nil
    end
    self.fpNextTool = nil
    self.fpNextToolNetId = nil
    self.fpNextToolUniqueId = xmlFile:getValue(key .. "#fpNextTool")
    if self.fpNextToolUniqueId == "" then
        self.fpNextToolUniqueId = nil
    end
    if self.loadTrailerState ~= nil then self:loadTrailerState(xmlFile, key) end -- remorque des modes avec benne, voir StateModuleTrailer.lua
    if self.loadFrontState ~= nil then self:loadFrontState(xmlFile, key) end -- attelage avant, voir StateModuleFront.lua
end

function ADStateModule:saveAutonomousState(xmlFile, key)
    local nextFieldIndex = ADGraphManager:getSavedMarkerIndex(self.fpNextField)
    if nextFieldIndex ~= nil then
        xmlFile:setValue(key .. "#fpNextField", nextFieldIndex)
        xmlFile:setValue(key .. "#fpNextFieldName", self.fpNextField.name or "")
    end
    local fpTool = self:getFpTool()
    local fpToolUniqueId = fpTool ~= nil and fpTool.getUniqueId ~= nil and fpTool:getUniqueId() or self.fpToolUniqueId
    if fpToolUniqueId ~= nil and fpToolUniqueId ~= "" then
        xmlFile:setValue(key .. "#fpTool", fpToolUniqueId)
    end
    local fpNextTool = self:getFpNextTool()
    local fpNextToolUniqueId = fpNextTool ~= nil and fpNextTool.getUniqueId ~= nil and fpNextTool:getUniqueId() or self.fpNextToolUniqueId
    if fpNextToolUniqueId ~= nil and fpNextToolUniqueId ~= "" then
        xmlFile:setValue(key .. "#fpNextTool", fpNextToolUniqueId)
    end
    if self.saveTrailerState ~= nil then self:saveTrailerState(xmlFile, key) end -- remorque des modes avec benne, voir StateModuleTrailer.lua
    if self.saveFrontState ~= nil then self:saveFrontState(xmlFile, key) end -- attelage avant, voir StateModuleFront.lua
end

-- ------------------------------------------------------------------------------------------------------------
-- Réseau (ADStateModule:doWriteStream, ADStateModule:doReadStream) : même ordre des deux côtés
-- ------------------------------------------------------------------------------------------------------------
function ADStateModule:writeAutonomousState(streamId)
    streamWriteUIntN(streamId, self:getFpNextFieldId() + 1, 20)
    local fpTool = self:getFpTool()
    local fpToolId = fpTool ~= nil and NetworkUtil.getObjectId(fpTool) or nil
    streamWriteBool(streamId, fpToolId ~= nil)
    if fpToolId ~= nil then
        NetworkUtil.writeNodeObjectId(streamId, fpToolId)
    end
    local fpNextTool = self:getFpNextTool()
    local fpNextToolId = fpNextTool ~= nil and NetworkUtil.getObjectId(fpNextTool) or nil
    streamWriteBool(streamId, fpNextToolId ~= nil)
    if fpNextToolId ~= nil then
        NetworkUtil.writeNodeObjectId(streamId, fpNextToolId)
    end
    if self.writeTrailerState ~= nil then self:writeTrailerState(streamId) end -- remorque des modes avec benne (même ordre à la lecture)
    if self.writeFrontState ~= nil then self:writeFrontState(streamId) end -- attelage avant (même ordre à la lecture)
end

function ADStateModule:readAutonomousState(streamId)
    self.fpNextField = ADGraphManager:getMapMarkerById(streamReadUIntN(streamId, 20) - 1)
    if streamReadBool(streamId) then
        self.fpToolNetId = NetworkUtil.readNodeObjectId(streamId)
        self.fpTool = NetworkUtil.getObject(self.fpToolNetId)
    else
        self.fpToolNetId = nil
        self.fpTool = nil
    end
    self.fpToolUniqueId = nil
    if streamReadBool(streamId) then
        self.fpNextToolNetId = NetworkUtil.readNodeObjectId(streamId)
        self.fpNextTool = NetworkUtil.getObject(self.fpNextToolNetId)
    else
        self.fpNextToolNetId = nil
        self.fpNextTool = nil
    end
    self.fpNextToolUniqueId = nil
    if self.readTrailerState ~= nil then self:readTrailerState(streamId) end -- remorque des modes avec benne (même ordre qu'à l'écriture)
    if self.readFrontState ~= nil then self:readFrontState(streamId) end -- attelage avant (même ordre qu'à l'écriture)
end

-- ------------------------------------------------------------------------------------------------------------
-- Rechargement du réseau de routes (ADStateModule:resetMarkersOnReload)
-- ------------------------------------------------------------------------------------------------------------
function ADStateModule:reloadAutonomousMarkers()
    if self.fpNextField ~= nil and self.fpNextField.id ~= nil then
        self.fpNextField = ADGraphManager:getMapMarkerByWayPointId(self.fpNextField.id)
    else
        self.fpNextField = nil
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Accesseurs : champ suivant, outil, outil du champ suivant
-- ------------------------------------------------------------------------------------------------------------
-- FarmPilot mode Autonome : champ suivant (nil = vide). À la fin du champ, il passe en 1re destination et se vide.
function ADStateModule:getFpNextField()
    return self.fpNextField
end

function ADStateModule:getFpNextFieldId()
    if self.fpNextField ~= nil and self.fpNextField.markerIndex ~= nil then
        return self.fpNextField.markerIndex
    end
    return -1
end

function ADStateModule:setFpNextField(markerId)
    if markerId ~= nil and markerId >= 1 then
        self.fpNextField = ADGraphManager:getMapMarkerById(markerId)
    else
        self.fpNextField = nil
    end
    self:raiseDirtyFlag()
end

-- FarmPilot mode Autonome : outil choisi dans le HUD, que le chauffeur va atteler avant d'aller au champ (nil = celui attelé)
function ADStateModule:getFpTool()
    local tool = self.fpTool
    if tool ~= nil and (tool.isDeleted or tool.isDeleting) then
        self.fpTool = nil
        self.fpToolUniqueId = nil
        tool = nil
    end
    if tool == nil and self.fpToolUniqueId ~= nil and g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil
        and g_currentMission.vehicleSystem.getVehicleByUniqueId ~= nil then
        -- savegame : l'outil est chargé après le tracteur
        tool = g_currentMission.vehicleSystem:getVehicleByUniqueId(self.fpToolUniqueId)
        self.fpTool = tool
    end
    if tool == nil and self.fpToolNetId ~= nil then
        -- client : l'outil arrive après le tracteur
        tool = NetworkUtil.getObject(self.fpToolNetId)
        self.fpTool = tool
    end
    return tool
end

function ADStateModule:setFpTool(tool)
    self.fpTool = tool
    self.fpToolNetId = nil
    self.fpToolUniqueId = tool ~= nil and tool.getUniqueId ~= nil and tool:getUniqueId() or nil
    self:raiseDirtyFlag()
end

-- FarmPilot mode Autonome : outil du champ suivant (4e ligne du HUD) : à la fin du champ, l'outil attelé va à sa place
-- et celui-ci est attelé avant d'aller au champ suivant (nil = le même)
function ADStateModule:getFpNextTool()
    local tool = self.fpNextTool
    if tool ~= nil and (tool.isDeleted or tool.isDeleting) then
        self.fpNextTool = nil
        self.fpNextToolUniqueId = nil
        tool = nil
    end
    if tool == nil and self.fpNextToolUniqueId ~= nil and g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil
        and g_currentMission.vehicleSystem.getVehicleByUniqueId ~= nil then
        tool = g_currentMission.vehicleSystem:getVehicleByUniqueId(self.fpNextToolUniqueId)
        self.fpNextTool = tool
    end
    if tool == nil and self.fpNextToolNetId ~= nil then
        tool = NetworkUtil.getObject(self.fpNextToolNetId)
        self.fpNextTool = tool
    end
    return tool
end

function ADStateModule:setFpNextTool(tool)
    self.fpNextTool = tool
    self.fpNextToolNetId = nil
    self.fpNextToolUniqueId = tool ~= nil and tool.getUniqueId ~= nil and tool:getUniqueId() or nil
    self:raiseDirtyFlag()
end
