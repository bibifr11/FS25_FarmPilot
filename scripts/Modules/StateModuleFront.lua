-- ============================================================================================================
-- FarmPilot : StateModuleFront.lua
-- Complément de StateModuleAutonomous.lua : l'état de l'attelage AVANT du mode Autonome.
--
-- Contenu (10/11) :
-- - outil avant à atteler avant le champ (ligne « Outil avant », nil = celui attelé) ;
-- - outil avant du champ suivant (ligne « Outil avant suivant », nil = le même) ;
-- - masse posée à sa zone pour atteler un outil avant, à reprendre en fin de travail (après la dépose des outils).
-- Champs de l'état, sauvegarde (xml), réseau, accesseurs. Un véhicule est gardé comme l'outil de la ligne « Outil » :
-- objet, sinon son identifiant de sauvegarde (chargé après le tracteur), sinon son identifiant réseau (client).
--
-- Branché par une ligne dans StateModuleAutonomous.lua : resetAutonomousState, loadAutonomousState,
-- saveAutonomousState, writeAutonomousState, readAutonomousState (en dernier, même ordre des deux côtés).
-- Clés de sauvegarde déclarées dans Specialization.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADStateModule.FRONT_SLOTS = { "fpFrontTool", "fpNextFrontTool", "fpMassReturn" }

-- ------------------------------------------------------------------------------------------------------------
-- Véhicule gardé (objet, identifiant de sauvegarde, identifiant réseau)
-- ------------------------------------------------------------------------------------------------------------
function ADStateModule:getFrontSlot(slot)
    local v = self[slot]
    if v ~= nil and (v.isDeleted or v.isDeleting) then
        self[slot] = nil
        self[slot .. "UniqueId"] = nil
        v = nil
    end
    local uid = self[slot .. "UniqueId"]
    if v == nil and uid ~= nil and g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil
        and g_currentMission.vehicleSystem.getVehicleByUniqueId ~= nil then
        -- sauvegarde : l'outil est chargé après le tracteur
        v = g_currentMission.vehicleSystem:getVehicleByUniqueId(uid)
        self[slot] = v
    end
    local netId = self[slot .. "NetId"]
    if v == nil and netId ~= nil then
        -- client : l'outil arrive après le tracteur
        v = NetworkUtil.getObject(netId)
        self[slot] = v
    end
    return v
end

function ADStateModule:setFrontSlot(slot, v)
    self[slot] = v
    self[slot .. "NetId"] = nil
    self[slot .. "UniqueId"] = v ~= nil and v.getUniqueId ~= nil and v:getUniqueId() or nil
    self:raiseDirtyFlag()
end

-- ------------------------------------------------------------------------------------------------------------
-- Champs, sauvegarde, réseau
-- ------------------------------------------------------------------------------------------------------------
function ADStateModule:resetFrontState()
    for _, slot in ipairs(ADStateModule.FRONT_SLOTS) do
        self[slot] = nil
        self[slot .. "UniqueId"] = nil
        self[slot .. "NetId"] = nil
    end
end

function ADStateModule:loadFrontState(xmlFile, key)
    for _, slot in ipairs(ADStateModule.FRONT_SLOTS) do
        self[slot] = nil
        self[slot .. "NetId"] = nil
        local uid = xmlFile:getValue(key .. "#" .. slot)
        self[slot .. "UniqueId"] = (uid ~= nil and uid ~= "") and uid or nil
    end
end

function ADStateModule:saveFrontState(xmlFile, key)
    for _, slot in ipairs(ADStateModule.FRONT_SLOTS) do
        local v = self:getFrontSlot(slot)
        local uid = v ~= nil and v.getUniqueId ~= nil and v:getUniqueId() or self[slot .. "UniqueId"]
        if uid ~= nil and uid ~= "" then
            xmlFile:setValue(key .. "#" .. slot, uid)
        end
    end
end

function ADStateModule:writeFrontState(streamId)
    for _, slot in ipairs(ADStateModule.FRONT_SLOTS) do
        local v = self:getFrontSlot(slot)
        local id = v ~= nil and NetworkUtil.getObjectId(v) or nil
        streamWriteBool(streamId, id ~= nil)
        if id ~= nil then
            NetworkUtil.writeNodeObjectId(streamId, id)
        end
    end
end

function ADStateModule:readFrontState(streamId)
    for _, slot in ipairs(ADStateModule.FRONT_SLOTS) do
        self[slot .. "UniqueId"] = nil
        if streamReadBool(streamId) then
            self[slot .. "NetId"] = NetworkUtil.readNodeObjectId(streamId)
            self[slot] = NetworkUtil.getObject(self[slot .. "NetId"])
        else
            self[slot .. "NetId"] = nil
            self[slot] = nil
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Accesseurs
-- ------------------------------------------------------------------------------------------------------------
-- outil avant (ou masse) choisi dans le HUD, à atteler avant d'aller au champ (nil = celui attelé)
function ADStateModule:getFpFrontTool()
    return self:getFrontSlot("fpFrontTool")
end

function ADStateModule:setFpFrontTool(v)
    self:setFrontSlot("fpFrontTool", v)
end

-- outil avant du champ suivant (nil = le même)
function ADStateModule:getFpNextFrontTool()
    return self:getFrontSlot("fpNextFrontTool")
end

function ADStateModule:setFpNextFrontTool(v)
    self:setFrontSlot("fpNextFrontTool", v)
end

-- masse posée à sa zone, à reprendre en fin de travail
function ADStateModule:getFpMassReturn()
    return self:getFrontSlot("fpMassReturn")
end

function ADStateModule:setFpMassReturn(v)
    self:setFrontSlot("fpMassReturn", v)
end
