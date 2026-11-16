-- ============================================================================================================
-- FarmPilot : SiloCompactMode.lua
-- Mode « Tassage » du HUD (AutoDrive.MODE_COMPACT, 16/11) : départ, outils à atteler, fin du travail.
--
-- Règles :
-- - Lignes du HUD (Hud/HudSilo.lua) : Silo, Attente, Outil AV (lame), Outil AR (rouleau). Les listes d'outils ne
--   montrent que les outils de silo de la ferme, dételés : lames (spec_leveler) et rouleaux de silo
--   (spec_bunkerSiloCompacter). Même choix enregistré que les lignes Outil AV / Outil AR du mode Autonome
--   (fpFrontTool, fpTool, AutonomousToolEvent.lua) ; dans le mode Autonome, ces outils de silo ne sont pas proposés.
-- - Départ (On/Off ou Démarrer de la fenêtre), de n'importe où : silo choisi contrôlé ; l'outil avant choisi et pas
--   attelé est attelé d'abord, puis l'outil arrière, comme en mode Autonome (CompactMode est un fils
--   d'AutonomousMode : mêmes étapes fetch / park) ; puis route jusqu'au silo et tassage (SiloCompactorTask.lua).
-- - Fin du tassage (silo fermé, ou 100 % avec « s'arrêter ») : les outils de silo attelés qui ont une place de
--   parking y sont ramenés (arrière puis avant ; outil avant sans place : à côté de l'outil arrière), puis le
--   tracteur va à sa place. Outil sans place, ou tracteur sans place : message, il s'arrête sur place.
--
-- Branché par : Specialization.lua (vehicle.ad.modes[MODE_COMPACT]), register.lua (après SiloCompactorTask.lua).
-- ============================================================================================================

ADSiloFetch = {}

local function log(fmt, ...)
    print("[FP-Silo] " .. string.format(fmt, ...))
end

local function nameOf(vehicle)
    return tostring(vehicle.ad.stateModule:getName())
end

local function farmOf(object)
    if object ~= nil and object.getOwnerFarmId ~= nil then
        local ok, id = FarmPilotCall(object.getOwnerFarmId, object)
        if ok then
            return id
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Outils de silo
-- ------------------------------------------------------------------------------------------------------------
function ADSiloFetch.isSiloTool(o)
    return o ~= nil and (o.spec_leveler ~= nil or o.spec_bunkerSiloCompacter ~= nil)
end

-- outil de silo de la ferme, dételé, qui s'attelle à l'avant (front) ou à l'arrière de ce tracteur
function ADSiloFetch.isFetchable(vehicle, tool, front)
    if tool == nil or tool == vehicle or tool.spec_attachable == nil or tool.isDeleted or tool.isDeleting or not ADSiloFetch.isSiloTool(tool) then
        return false
    end
    local farm = farmOf(vehicle)
    if farm ~= nil and farmOf(tool) ~= farm then
        return false
    end
    if tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() ~= nil then
        return false
    end
    if front then
        return ADAutonomousManager.matchFrontJoints ~= nil and ADAutonomousManager.matchFrontJoints(vehicle, tool, false) ~= nil
    end
    return ADAutonomousManager.matchJoints(vehicle, tool, false) ~= nil
end

-- liste du HUD : { tool, name, distance }, la plus proche d'abord
function ADSiloFetch.list(vehicle, front)
    local out = {}
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system == nil or system.vehicles == nil or vehicle == nil then
        return out
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    for _, v in pairs(system.vehicles) do
        local ok, fetchable = FarmPilotCall(ADSiloFetch.isFetchable, vehicle, v, front)
        if ok and fetchable then
            local tx, _, tz = getWorldTranslation(v.components[1].node)
            out[#out + 1] = { tool = v, name = ADAutonomousManager.toolLabel(v), distance = MathUtil.vector2Length(tx - vx, tz - vz) }
        end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    local count = {}
    for _, e in ipairs(out) do
        count[e.name] = (count[e.name] or 0) + 1
    end
    for _, e in ipairs(out) do
        if count[e.name] > 1 then
            e.name = string.format(g_i18n:getText("AD_autonomous_toolListEntry"), e.name, math.floor(e.distance + 0.5))
        end
    end
    return out
end

local function isSiloMode(vehicle)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and AutoDrive.MODE_COMPACT ~= nil
        and vehicle.ad.stateModule:getMode() == AutoDrive.MODE_COMPACT
end

local function withoutSiloTools(list)
    local out = {}
    for _, e in ipairs(list or {}) do
        if not ADSiloFetch.isSiloTool(e.tool) then
            out[#out + 1] = e
        end
    end
    return out
end

-- listes du HUD : en mode Tassage les outils de silo seulement ; ailleurs, pas d'outils de silo
local baseFetchableTools = ADAutonomousManager.fetchableTools
function ADAutonomousManager.fetchableTools(vehicle)
    if isSiloMode(vehicle) then
        return ADSiloFetch.list(vehicle, false)
    end
    return withoutSiloTools(baseFetchableTools(vehicle))
end

local baseFetchableFront = ADAutonomousManager.fetchableFrontTools
function ADAutonomousManager.fetchableFrontTools(vehicle)
    if isSiloMode(vehicle) then
        return ADSiloFetch.list(vehicle, true)
    end
    return withoutSiloTools(baseFetchableFront(vehicle))
end

-- choix reçu par le serveur (AutonomousToolEvent.lua) : un outil de silo est accepté
local baseIsFetchableTool = ADAutonomousManager.isFetchableTool
function ADAutonomousManager.isFetchableTool(vehicle, tool)
    if ADSiloFetch.isSiloTool(tool) then
        return ADSiloFetch.isFetchable(vehicle, tool, false)
    end
    return baseIsFetchableTool(vehicle, tool)
end

local baseIsFetchableFront = ADAutonomousManager.isFetchableFront
function ADAutonomousManager.isFetchableFront(vehicle, tool)
    if ADSiloFetch.isSiloTool(tool) then
        return ADSiloFetch.isFetchable(vehicle, tool, true)
    end
    return baseIsFetchableFront(vehicle, tool)
end

-- les lignes « Outil AV / AR » des modes Autonome et Tassage partagent le même réglage du tracteur : un outil de silo
-- ne compte qu'en Tassage, un autre outil qu'ailleurs (pas de rouleau atteler en mode Autonome, et inversement)
local function sameKind(sm, tool)
    if tool == nil then
        return nil
    end
    local compact = AutoDrive.MODE_COMPACT ~= nil and sm.getMode ~= nil and sm:getMode() == AutoDrive.MODE_COMPACT
    if compact ~= ADSiloFetch.isSiloTool(tool) then
        return nil
    end
    return tool
end

local baseGetFpTool = ADStateModule.getFpTool
function ADStateModule:getFpTool()
    return sameKind(self, baseGetFpTool(self))
end

if ADStateModule.getFpFrontTool ~= nil then
    local baseGetFpFront = ADStateModule.getFpFrontTool
    function ADStateModule:getFpFrontTool()
        return sameKind(self, baseGetFpFront(self))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin du tassage : outils à leur place, tracteur garé
-- ------------------------------------------------------------------------------------------------------------
local function markerOf(object, except)
    local id = object ~= nil and object.advd ~= nil and object.advd.parkDestination or -1
    if id == nil or id < 1 or id == except then
        return nil
    end
    return ADGraphManager:getMapMarkerById(id)
end

-- outils de silo attelés : arrière, avant
function ADSiloFetch.attached(vehicle)
    local front = ADAutonomousManager.frontObject ~= nil and ADAutonomousManager.frontObject(vehicle) or nil
    local rear = nil
    for _, t in ipairs(ADSiloTools.list(vehicle)) do
        if t ~= front and t.getAttacherVehicle ~= nil and t:getAttacherVehicle() == vehicle then
            rear = rear or t
        end
    end
    if front ~= nil and not ADSiloFetch.isSiloTool(front) then
        front = nil
    end
    return rear, front
end

-- true si la dépose est lancée
function ADSiloFetch.parkAfter(mode)
    local vehicle = mode.vehicle
    local rear, front = ADSiloFetch.attached(vehicle)
    if rear == nil and front == nil then
        return false
    end
    local steps = {}
    local rearMarker = markerOf(rear)
    if rear ~= nil then
        if rearMarker == nil then
            log("%s : fin du tassage, « %s » n'a pas de place de parking : gardé", nameOf(vehicle), ADAutonomousManager.toolLabel(rear))
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_dropNoToolPark")
            return false
        end
        steps[#steps + 1] = { kind = "drop", tool = rear, marker = rearMarker, side = "rear" }
    end
    if front ~= nil then
        local marker = markerOf(front, rearMarker ~= nil and rearMarker.id or nil)
        if marker ~= nil then
            steps[#steps + 1] = { kind = "drop", tool = front, marker = marker, side = "front" }
        elseif rear ~= nil then
            steps[#steps + 1] = { kind = "drop", tool = front, beside = rear, besideSide = "rear", side = "front" }
        else
            log("%s : fin du tassage, « %s » (avant) n'a pas de place de parking : gardé", nameOf(vehicle), ADAutonomousManager.toolLabel(front))
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_frontNoPark", ADAutonomousManager.toolLabel(front))
            return false
        end
    end
    local tractorMarker = markerOf(vehicle, rearMarker ~= nil and rearMarker.id or nil)
    if tractorMarker == nil then
        log("%s : fin du tassage, le tracteur n'a pas de place de parking : outils gardés", nameOf(vehicle))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_dropNoTractorPark")
        return false
    end
    steps[#steps + 1] = { kind = "park", marker = tractorMarker }
    local parts = {}
    for _, st in ipairs(steps) do
        if st.kind == "drop" then
            parts[#parts + 1] = "« " .. ADAutonomousManager.toolLabel(st.tool) .. " »" .. (st.side == "front" and " (avant)" or "")
                .. (st.marker ~= nil and (" à « " .. tostring(st.marker.name) .. " »") or " à côté de l'outil arrière")
        end
    end
    parts[#parts + 1] = "le tracteur à « " .. tostring(tractorMarker.name) .. " »"
    log("%s : fin du tassage : %s", nameOf(vehicle), table.concat(parts, ", "))
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.restartCP = false
    vehicle.ad.stateModule:setStartHelper(false)
    mode:reset()
    mode.fpQueue = steps
    mode.tractorParkId = tractorMarker.id
    ADFrontFlow.nextStep(mode)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- CompactMode
-- ------------------------------------------------------------------------------------------------------------
CompactMode = ADInheritsFrom(AutonomousMode)

function CompactMode:new(vehicle)
    local o = CompactMode:create()
    o.vehicle = vehicle
    CompactMode.reset(o)
    return o
end

function CompactMode:reset()
    AutonomousMode.reset(self)
    self.fpSiloTask = nil
    self.fpSiloDrive = nil
end

local function refuse(mode, key)
    local v = mode.vehicle
    v.ad.fpSiloJob = nil
    AutoDriveMessageEvent.sendMessageOrNotification(v, ADMessagesManager.messageTypes.WARN, "$l10n_AD_Driver_of; %s: $l10n_" .. key .. ";", 6000, v.ad.stateModule:getName())
    if v.ad.stateModule:isActive() then
        v:stopAutoDrive()
    end
end

function CompactMode:start(user)
    local v = self.vehicle
    local sm = v.ad.stateModule
    if v.ad.fpSiloJob == nil and sm.fpSiloJobText ~= nil then
        -- partie rechargée pendant le tassage : il reprend
        local x, z = string.match(sm.fpSiloJobText, "^([%-%d%.]+);([%-%d%.]+)$")
        sm.fpSiloJobText = nil
        if x ~= nil then
            v.ad.fpSiloJob = { x = tonumber(x), z = tonumber(z) }
            log("%s : partie rechargee, reprend le tassage", nameOf(v))
        end
    end
    if v.ad.fpSiloJob == nil then
        local silo = ADSiloJob.selectedSilo(v)
        if silo == nil then
            log("%s : mode Tassage, depart refuse (aucun silo choisi)", nameOf(v))
            refuse(self, "gui_ad_silo_noSilo")
            return
        end
        if not ADSiloCompactor.isFilling(silo) then
            refuse(self, "gui_ad_silo_closed")
            return
        end
        local cx, cz = ADSiloJob.center(silo)
        v.ad.fpSiloJob = { x = cx, z = cz }
        log("%s : mode Tassage, silo %d (%.0f, %.0f)", nameOf(v), ADSiloJob.siloNumber(silo), cx, cz)
    end
    -- outils choisis : l'avant d'abord, puis l'arrière (étapes du mode Autonome)
    local frontStop, frontPlan = nil, nil
    if ADFrontFlow ~= nil then
        frontStop, frontPlan = ADFrontFlow.checkStart(self)
        if frontStop then
            v.ad.fpSiloJob = nil
            return
        end
    end
    local okF, fetchTool, fetchErr, wanted = FarmPilotCall(ADAutonomousManager.toolToFetch, v)
    if not okF then
        fetchTool, fetchErr = nil, nil
    end
    if fetchErr ~= nil then
        local key = ({ busy = "AD_autonomous_fetchBusy", other = "AD_autonomous_fetchOther", noJoint = "AD_autonomous_fetchNoJoint" })[fetchErr] or "AD_autonomous_fetchFailed"
        AutonomousMode.message(v, ADMessagesManager.messageTypes.ERROR, 12000, key, wanted ~= nil and ADAutonomousManager.toolLabel(wanted) or "?")
        log("%s : depart refuse, outil arriere choisi : %s", nameOf(v), tostring(fetchErr))
        v.ad.fpSiloJob = nil
        if sm:isActive() then
            v:stopAutoDrive()
        end
        return
    end
    if not sm:isActive() then
        local job = v.ad.fpSiloJob
        v:startAutoDrive()
        v.ad.fpSiloJob = job
    end
    self:reset()
    if frontPlan ~= nil and ADFrontFlow.execute(self, frontPlan) then
        log("%s : va d'abord atteler l'outil avant", nameOf(v))
        return -- puis start() de nouveau
    end
    if fetchTool ~= nil then
        log("%s : va d'abord atteler « %s »", nameOf(v), ADAutonomousManager.toolLabel(fetchTool))
        self:startFetch(fetchTool) -- puis start() de nouveau
        return
    end
    local ok, err = FarmPilotCall(ADSiloJob.startJob, self)
    if not ok then
        log("%s : ERREUR depart du tassage (%s)", nameOf(v), tostring(err))
        v.ad.fpSiloJob = nil
    end
end

-- pas de champ ici : arrivée de la route du silo, fin du tassage ; le reste (outils, parking) comme en Autonome
function CompactMode:handleFinishedTask()
    local v = self.vehicle
    if self.fpSiloTask ~= nil then
        self.fpSiloTask = nil
        v.ad.fpSiloJob = nil
        local ok, started = FarmPilotCall(ADSiloFetch.parkAfter, self)
        if ok and started then
            return
        end
        v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
        return
    end
    if self.fpSiloDrive then
        self.fpSiloDrive = nil
        self.driveToDestinationTask = nil
        local job = v.ad.fpSiloJob
        local silo = job ~= nil and ADSiloJob.findSilo(job.x, job.z) or nil
        local why = v.ad.isStoppingWithError and "error" or ADSiloJob.refusal(v, silo)
        if why == nil then
            self.fpSiloTask = SiloCompactTask:new(v, silo)
            v.ad.taskModule:addTask(self.fpSiloTask)
            return
        end
        log("%s : arrive au silo, tassage impossible (%s), arret", nameOf(v), tostring(why))
        v.ad.fpSiloJob = nil
        v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
        return
    end
    if self.parkStage ~= nil or self.fetchStage ~= nil then
        return AutonomousMode.handleFinishedTask(self)
    end
    v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
end
