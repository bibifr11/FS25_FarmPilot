-- ============================================================================================================
-- FarmPilot : LoaderMode.lua
-- Mode « Chargeur » du HUD (AutoDrive.MODE_LOADER, 16/11) : départ, godet à atteler, trajets par la route, fin.
--
-- Règles :
-- - Départ (On/Off), de n'importe où : source choisie contrôlée (silo bâché pas ouvert, source vide, point de
--   vidage disparu : refusé avec message). Godet choisi dans la ligne « Outil » et pas attelé : attelé d'abord,
--   comme l'outil avant du mode Autonome (LoaderMode est un fils d'AutonomousMode). Puis route jusqu'à la source
--   (marqueur dans le silo, sinon point du réseau le plus proche de la source), sauf s'il y est déjà.
-- - Travail : Tasks/LoaderTask.lua. Point de vidage loin de la source : la tâche rend la main godet en position
--   route, le mode fait le trajet par le réseau jusqu'au point du réseau le plus proche du point de vidage, la tâche
--   reprend là (vidage), puis retour par le réseau à la source.
-- - Fin (quantité vidée, ou source vide) : message ; le godet attelé directement au chargeur (télescopique,
--   chargeuse) qui a une place de parking y est ramené, puis le chargeur va à sa place. Godet sur chargeur frontal,
--   ou sans place : il reste attelé. Chargeur sans place : message, il s'arrête sur place.
-- - Rechargement de la partie pendant le travail : il repart (litres déjà vidés gardés, godet plein : va vider).
--
-- Branché par : Specialization.lua (vehicle.ad.modes[MODE_LOADER], stopAutoDrive -> ADLoaderJob.onStop),
-- register.lua (après LoaderJob.lua et LoaderTask.lua).
-- ============================================================================================================

local function log(fmt, ...)
    ADLoaderJob.log(fmt, ...)
end

local function nameOf(vehicle)
    return tostring(vehicle.ad.stateModule:getName())
end

local function call(f, ...)
    if FarmPilotCall ~= nil then
        return FarmPilotCall(f, ...)
    end
    return pcall(f, ...)
end

local function message(vehicle, kind, key, ...)
    AutoDriveMessageEvent.sendMessageOrNotification(vehicle, kind, "$l10n_AD_Driver_of; %s: $l10n_" .. key .. ";", 8000, vehicle.ad.stateModule:getName(), ...)
end

function ADLoaderJob.isLoaderMode(vehicle)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and AutoDrive.MODE_LOADER ~= nil
        and vehicle.ad.stateModule:getMode() == AutoDrive.MODE_LOADER
end

-- ------------------------------------------------------------------------------------------------------------
-- Ligne « Outil » : godets et fourches dételés de la ferme (attelage avant du chargeur)
-- ------------------------------------------------------------------------------------------------------------
local function farmOf(object)
    if object ~= nil and object.getOwnerFarmId ~= nil then
        local ok, id = call(object.getOwnerFarmId, object)
        if ok then
            return id
        end
    end
    return nil
end

function ADLoaderJob.isFetchable(vehicle, tool)
    if tool == nil or tool == vehicle or tool.spec_attachable == nil or tool.isDeleted or tool.isDeleting or not ADLoaderJob.isLoaderTool(tool) then
        return false
    end
    local farm = farmOf(vehicle)
    if farm ~= nil and farmOf(tool) ~= farm then
        return false
    end
    if tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() ~= nil then
        return false
    end
    return ADAutonomousManager.matchFrontJoints ~= nil and ADAutonomousManager.matchFrontJoints(vehicle, tool, false) ~= nil
end

function ADLoaderJob.toolList(vehicle)
    local out = {}
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system == nil or system.vehicles == nil or vehicle == nil then
        return out
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    for _, v in pairs(system.vehicles) do
        local ok, fetchable = call(ADLoaderJob.isFetchable, vehicle, v)
        if ok and fetchable then
            local tx, _, tz = getWorldTranslation(v.components[1].node)
            out[#out + 1] = { tool = v, name = ADAutonomousManager.toolLabel(v), distance = MathUtil.vector2Length(tx - vx, tz - vz) }
        end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    for _, e in ipairs(out) do
        e.name = string.format(g_i18n:getText("AD_autonomous_toolListEntry"), e.name, math.floor(e.distance + 0.5))
    end
    return out
end

-- listes « Outil avant » : en mode Chargeur, les godets seulement
local baseFetchableFront = ADAutonomousManager.fetchableFrontTools
function ADAutonomousManager.fetchableFrontTools(vehicle)
    if ADLoaderJob.isLoaderMode(vehicle) then
        return ADLoaderJob.toolList(vehicle)
    end
    local out = {}
    for _, e in ipairs(baseFetchableFront(vehicle) or {}) do
        if not ADLoaderJob.isLoaderTool(e.tool) then
            out[#out + 1] = e -- les godets ne sont proposés qu'en mode Chargeur
        end
    end
    return out
end

local baseIsFetchableFront = ADAutonomousManager.isFetchableFront
function ADAutonomousManager.isFetchableFront(vehicle, tool)
    if ADLoaderJob.isLoaderTool(tool) then
        return ADLoaderJob.isFetchable(vehicle, tool)
    end
    return baseIsFetchableFront(vehicle, tool)
end

-- outil avant choisi : un godet ne compte qu'en mode Chargeur, et seul un godet compte en mode Chargeur
if ADStateModule.getFpFrontTool ~= nil then
    local baseGetFpFront = ADStateModule.getFpFrontTool
    function ADStateModule:getFpFrontTool()
        local tool = baseGetFpFront(self)
        if tool == nil then
            return nil
        end
        local loader = AutoDrive.MODE_LOADER ~= nil and self.getMode ~= nil and self:getMode() == AutoDrive.MODE_LOADER
        if loader ~= ADLoaderJob.isLoaderTool(tool) then
            return nil
        end
        return tool
    end
end

-- en mode Chargeur, pas d'outil arrière à aller atteler
local baseGetFpTool = ADStateModule.getFpTool
function ADStateModule:getFpTool()
    if AutoDrive.MODE_LOADER ~= nil and self.getMode ~= nil and self:getMode() == AutoDrive.MODE_LOADER then
        return nil
    end
    return baseGetFpTool(self)
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin : godet à sa place, chargeur garé
-- ------------------------------------------------------------------------------------------------------------
local function markerOf(object, except)
    local id = object ~= nil and object.advd ~= nil and object.advd.parkDestination or -1
    if id == nil or id < 1 or id == except then
        return nil
    end
    return ADGraphManager:getMapMarkerById(id)
end

-- true si la dépose ou le garage est lancé
function ADLoaderJob.parkAfter(mode)
    local vehicle = mode.vehicle
    local steps = {}
    local front = ADAutonomousManager.frontObject ~= nil and ADAutonomousManager.frontObject(vehicle) or nil
    local toolMarker = nil
    if front ~= nil and ADLoaderJob.isLoaderTool(front) then
        toolMarker = markerOf(front)
        if toolMarker ~= nil then
            steps[#steps + 1] = { kind = "drop", tool = front, marker = toolMarker, side = "front" }
        else
            log("%s : fin, « %s » n'a pas de place de parking : garde attele", nameOf(vehicle), ADAutonomousManager.toolLabel(front))
        end
    end
    local parkMarker = markerOf(vehicle, toolMarker ~= nil and toolMarker.id or nil)
    if parkMarker == nil then
        log("%s : fin, le chargeur n'a pas de place de parking : arret sur place", nameOf(vehicle))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_dropNoTractorPark")
        return false
    end
    steps[#steps + 1] = { kind = "park", marker = parkMarker }
    log("%s : fin : %s%s a « %s »", nameOf(vehicle), toolMarker ~= nil and ("godet a « " .. tostring(toolMarker.name) .. " », ") or "", "chargeur", tostring(parkMarker.name))
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.restartCP = false
    vehicle.ad.stateModule:setStartHelper(false)
    mode:reset()
    mode.fpQueue = steps
    mode.tractorParkId = parkMarker.id
    ADFrontFlow.nextStep(mode)
    return true
end

-- arrêt (On/Off, fin, erreur) : travail oublié, godet ne vide plus. Appelé au début d'AutoDrive:stopAutoDrive.
function ADLoaderJob.onStop(vehicle)
    if vehicle == nil or vehicle.ad == nil then
        return
    end
    vehicle.ad.fpLoaderJob = nil
    local task = vehicle.ad.taskModule ~= nil and vehicle.ad.taskModule:getActiveTask() or nil
    if task ~= nil and task.fpLoader == true then
        task:abort()
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- LoaderMode
-- ------------------------------------------------------------------------------------------------------------
LoaderMode = ADInheritsFrom(AutonomousMode)

function LoaderMode:new(vehicle)
    local o = LoaderMode:create()
    o.vehicle = vehicle
    LoaderMode.reset(o)
    return o
end

function LoaderMode:reset()
    AutonomousMode.reset(self)
    self.fpLoaderTask = nil
    self.fpLoaderDrive = nil
end

local function refuse(mode, key)
    local v = mode.vehicle
    v.ad.fpLoaderJob = nil
    log("%s : depart refuse (%s)", nameOf(v), key)
    message(v, ADMessagesManager.messageTypes.WARN, key)
    if v.ad.stateModule:isActive() then
        v:stopAutoDrive()
    end
end

function LoaderMode:start(user)
    local v = self.vehicle
    local sm = v.ad.stateModule
    if v.ad.fpLoaderJob == nil and sm.fpLoaderJobText ~= nil then
        -- partie rechargée pendant le travail : il reprend, litres déjà vidés gardés
        local done = tonumber(sm.fpLoaderJobText)
        sm.fpLoaderJobText = nil
        v.ad.fpLoaderJob = { done = done or 0 }
        log("%s : partie rechargee, reprend le chargement (%s deja vides)", nameOf(v), ADLoaderJob.litersText(done or 0))
    end
    local source = ADLoaderJob.selectedSource(v)
    local why = ADLoaderJob.refusal(v, source)
    if why ~= nil then
        refuse(self, why)
        return
    end
    if v.ad.fpLoaderJob == nil then
        local cfg = ADLoaderJob.getCfg(v)
        v.ad.fpLoaderJob = { done = 0 }
        log("%s : mode Chargeur, prend %s, vide %s, quantite %s", nameOf(v), ADLoaderJob.sourceLabel(source, false),
            cfg.dst == ADLoaderJob.DST_POINT and ("au point « " .. ADLoaderJob.pointName(ADLoaderJob.findPoint(cfg.px, cfg.pz)) .. " »") or "en benne",
            cfg.qty > 0 and ADLoaderJob.litersText(cfg.qty) or "tout")
    end
    -- godet choisi à atteler d'abord (étapes de l'outil avant du mode Autonome)
    local frontStop, frontPlan = nil, nil
    if ADFrontFlow ~= nil then
        frontStop, frontPlan = ADFrontFlow.checkStart(self)
        if frontStop then
            v.ad.fpLoaderJob = nil
            return
        end
    end
    if frontPlan == nil and ADLoaderJob.attachedShovel(v) == nil then
        refuse(self, "gui_ad_loader_noTool")
        return
    end
    if not sm:isActive() then
        local job = v.ad.fpLoaderJob
        v:startAutoDrive()
        v.ad.fpLoaderJob = job
    end
    self:reset()
    if frontPlan ~= nil and ADFrontFlow.execute(self, frontPlan) then
        log("%s : va d'abord atteler le godet", nameOf(v))
        return -- puis start() de nouveau
    end
    local ok, err = call(LoaderMode.goToSource, self, source)
    if not ok then
        log("%s : ERREUR depart du chargeur (%s)", nameOf(v), tostring(err))
        v.ad.fpLoaderJob = nil
    end
end

-- point du réseau pour aller à la source : marqueur dans le silo, sinon le plus proche de la source
local function sourceWayPoint(source)
    if source.kind == ADLoaderJob.SRC_SILO and ADSiloJob ~= nil and ADSiloJob.markerInSilo ~= nil then
        local ok, wp = call(ADSiloJob.markerInSilo, source.silo)
        if ok and wp ~= nil then
            return wp
        end
    end
    return ADLoaderJob.nearestWayPoint(source.x, source.z)
end

function LoaderMode:startTask(source, atPoint)
    local v = self.vehicle
    self.fpLoaderTask = LoaderTask:new(v, source, v.ad.fpLoaderJob, atPoint)
    v.ad.taskModule:addTask(self.fpLoaderTask)
end

function LoaderMode:driveTo(wp, where)
    local v = self.vehicle
    self.destinationID = wp
    self.driveToDestinationTask = DriveToDestinationTask:new(v, wp)
    self.fpLoaderDrive = where
    v.ad.taskModule:addTask(self.driveToDestinationTask)
end

function LoaderMode:goToSource(source)
    local v = self.vehicle
    local x, _, z = getWorldTranslation(v.components[1].node)
    if MathUtil.vector2Length(x - source.x, z - source.z) < ADLoaderJob.NEAR_START + 20 then
        self:startTask(source, false)
        return
    end
    local wp = sourceWayPoint(source)
    if wp == nil then
        log("%s : aucun point du reseau pres de la source", nameOf(v))
        v.ad.fpLoaderJob = nil
        message(v, ADMessagesManager.messageTypes.WARN, "gui_ad_loader_noRoute")
        v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
        return
    end
    log("%s : part a la source (point %s)", nameOf(v), tostring(wp))
    self:driveTo(wp, "source")
end

function LoaderMode:goToPoint()
    local v = self.vehicle
    local cfg = ADLoaderJob.getCfg(v)
    local wp = ADLoaderJob.nearestWayPoint(cfg.px or 0, cfg.pz or 0)
    if wp == nil then
        log("%s : aucun point du reseau pres du point de vidage", nameOf(v))
        v.ad.fpLoaderJob = nil
        message(v, ADMessagesManager.messageTypes.WARN, "gui_ad_loader_noRoutePoint")
        v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
        return
    end
    log("%s : part au point de vidage (point %s)", nameOf(v), tostring(wp))
    self:driveTo(wp, "point")
end

function LoaderMode:handleFinishedTask()
    local v = self.vehicle
    if self.fpLoaderTask ~= nil then
        local task = self.fpLoaderTask
        self.fpLoaderTask = nil
        if v.ad.fpLoaderJob == nil then
            v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
            return
        end
        if task.fpLeave == "toPoint" then
            return self:goToPoint()
        elseif task.fpLeave == "toSource" then
            local source = ADLoaderJob.selectedSource(v)
            if source == nil then
                log("%s : source disparue, fin", nameOf(v))
            else
                return self:goToSource(source)
            end
        end
        local done = v.ad.fpLoaderJob.done or 0
        v.ad.fpLoaderJob = nil
        log("%s : chargement fini, %s vides", nameOf(v), ADLoaderJob.litersText(done))
        message(v, ADMessagesManager.messageTypes.INFO, task.fpDoneKey or "gui_ad_loader_doneEmpty")
        local ok, started = call(ADLoaderJob.parkAfter, self)
        if ok and started then
            return
        end
        v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
        return
    end
    if self.fpLoaderDrive ~= nil then
        local where = self.fpLoaderDrive
        self.fpLoaderDrive = nil
        self.driveToDestinationTask = nil
        local source = ADLoaderJob.selectedSource(v)
        if v.ad.isStoppingWithError or v.ad.fpLoaderJob == nil or source == nil then
            log("%s : trajet vers %s interrompu, arret", nameOf(v), where)
            v.ad.fpLoaderJob = nil
            v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
            return
        end
        log("%s : arrive %s", nameOf(v), where == "point" and "au point de vidage" or "a la source")
        self:startTask(source, where == "point")
        return
    end
    if self.parkStage ~= nil or self.fetchStage ~= nil then
        return AutonomousMode.handleFinishedTask(self)
    end
    v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
end
