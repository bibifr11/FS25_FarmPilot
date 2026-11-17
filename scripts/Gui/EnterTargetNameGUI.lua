--
-- AutoDrive Enter Target Name GUI
-- V1.1.0.0
--
-- @author Stephan Schlosser
-- @date 08/08/2019

ADEnterTargetNameGui = {}
ADEnterTargetNameGui.debug = false

local ADEnterTargetNameGui_mt = Class(ADEnterTargetNameGui, DialogElement)

function ADEnterTargetNameGui.new(target)
    local self = DialogElement.new(target, ADEnterTargetNameGui_mt)
    self:include(ADGuiDebugMixin)
    self.editName = nil
    self.editId = nil
    self.edit = false
    return self
end

function ADEnterTargetNameGui:onOpen()
    self:debugMsg("ADEnterTargetNameGui:onOpen")
    ADEnterTargetNameGui:superClass().onOpen(self)
    self.textInputElement.blockTime = 0
    self.textInputElement:onFocusActivate()
    self.editName = nil
    self.editId = nil
    self.edit = false
    local controlledVehicle = AutoDrive.getControlledVehicle()
    -- If editSelectedMapMarker is true, we have to edit the map marker selected on the pull down list otherwise we can go for closest waypoint
    if controlledVehicle then
        if AutoDrive.editSelectedMapMarker ~= nil and AutoDrive.editSelectedMapMarker == true then
            self.editId = controlledVehicle.ad.stateModule:getFirstMarkerId()
            self.editName = ADGraphManager:getMapMarkerById(self.editId).name
        else
            local closest, _ = controlledVehicle:getClosestWayPoint()
            if closest ~= nil and closest ~= -1 and ADGraphManager:getWayPointById(closest) ~= nil then
                local cId = closest
                for i, mapMarker in pairs(ADGraphManager:getMapMarkers()) do
                    -- If we have already a map marker on this waypoint, we edit it otherwise we create a new one
                    if mapMarker.id == cId then
                        self.editId = i
                        self.editName = mapMarker.name
                        break
                    end
                end
            end
        end
    end

    if self.editId ~= nil and self.editName ~= nil then
        self.edit = true
    end

    if self.edit then
        self.titleElement:setText(g_i18n:getText("gui_ad_enterTargetNameTitle_edit"))
        self.textInputElement:setText(self.editName)
    else
        self.titleElement:setText(g_i18n:getText("gui_ad_enterTargetNameTitle_add"))
        self.textInputElement:setText("")
    end

    self.buttonsCreateElement:setVisible(not self.edit)
    self.buttonsEditElement:setVisible(self.edit)
    -- (17/11) zone des masses de la destination (FarmPilot, MassZoneManager.lua)
    if self.massZoneButton ~= nil then
        local isZone = ADMassZone ~= nil and self.edit and ADMassZone.isZone(self.editName)
        self.massZoneButton:setText(g_i18n:getText(isZone and "gui_ad_massZoneRemove" or "gui_ad_massZone"))
        self.massZoneButton:setVisible(ADMassZone ~= nil and self.edit)
    end
end

-- (17/11) bouton « Zone des masses » : ajoute ou retire le carré des masses après la destination (MassZoneManager.lua)
function ADEnterTargetNameGui:onClickMassZone()
    self:debugMsg("ADEnterTargetNameGui:onClickMassZone")
    if ADMassZone == nil or not self.edit or self.editName == nil then
        return
    end
    local ok, added, why = FarmPilotCall(ADMassZone.toggle, self.editName)
    if not ok then
        ADAutonomousManager.log("ERREUR zone des masses : %s", tostring(added))
        added = nil
    end
    local vehicle = AutoDrive.getControlledVehicle()
    local key, kind
    if added == nil then
        key, kind = why == "reverse" and "gui_ad_massZoneReverse" or "gui_ad_massZoneImpossible", ADMessagesManager.messageTypes.ERROR
    else
        key, kind = added and "gui_ad_massZoneAdded" or "gui_ad_massZoneRemoved", ADMessagesManager.messageTypes.INFO
    end
    if vehicle ~= nil then
        local okT, txt = FarmPilotCall(string.format, g_i18n:getText(key), tostring(self.editName))
        AutoDriveMessageEvent.sendMessageOrNotification(vehicle, kind, okT and txt or g_i18n:getText(key), 10000)
    end
    self:onClickBack()
end

function ADEnterTargetNameGui:onClickOk()
    self:debugMsg("ADEnterTargetNameGui:onClickOk")
    if self.edit then
        ADGraphManager:renameMapMarker(self.textInputElement.text, self.editId)
        if ADMassZone ~= nil then
            ADMassZone.rename(self.editName, self.textInputElement.text) -- (17/11) la zone des masses suit
        end
    else
        ADGraphManager:createMapMarkerOnClosest(AutoDrive.getControlledVehicle(), self.textInputElement.text)
    end
    self:onClickBack()
end

function ADEnterTargetNameGui:onClickDelete()
    self:debugMsg("ADEnterTargetNameGui:onClickDelete")
    ADGraphManager:removeMapMarker(self.editId)
    if ADMassZone ~= nil then
        ADMassZone.remove(self.editName) -- (17/11) sa zone des masses aussi
    end
    self:onClickBack()
end

function ADEnterTargetNameGui:onClickReset()
    self:debugMsg("ADEnterTargetNameGui:onClickReset")
    self.textInputElement:setText(self.editName)
end

function ADEnterTargetNameGui:onEnterPressed(_, isClick)
    self:debugMsg("ADEnterTargetNameGui:onEnterPressed")
    if not isClick then
        self:onClickOk()
    end
end

function ADEnterTargetNameGui:onEscPressed()
    self:debugMsg("ADEnterTargetNameGui:onEscPressed")
    self:onClickBack()
end
