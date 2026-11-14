-- ============================================================================================================
-- FarmPilot : AutonomousYardZone.lua
-- Mode Autonome : un seul tracteur à la fois dans la zone d'une place d'outils (hangar, cour), les autres attendent
-- sur la route qu'il ait fini (14/11).
--
-- D'où ça vient : le 14/11 vers 21 h (heure de Paris), le 728 pose ses faucheuses dans « G_Faucheuse », recule de
-- 17 m devant le hangar et repart chercher un autre outil ; au même moment le 942 vient atteler l'Arcusin dans
-- « G_ARcusin », la place d'à côté (6 m) : il quitte la route vers l'avant de l'outil, à 4 m de l'endroit où le 728
-- s'est arrêté. Le 942 bouche la sortie du 728 (« Fait la file derrière 942 »), le 728 bouche l'arrivée du 942 :
-- 13 min sans bouger. Règle du 14/11 21 h 14 : « il faudrait que l'un attende que l'autre finisse avant de venir
-- dans sa zone ».
--
-- Règle (tracteurs en mode Autonome) :
-- - étapes d'outils : aller poser l'outil à sa place, le poser, reculer ; aller chercher un outil, l'atteler ;
--   aller à la place du tracteur ;
-- - à APPROACH m de sa place (ou de l'outil), le tracteur prend la zone autour (CONFLICT m) si personne ne l'a ;
--   sinon il s'arrête sur la route et attend (ATH : « Attend que X libère la zone des outils ») ;
-- - la zone est rendue quand il en est sorti (RELEASE m) sans autre étape d'outil dans cette zone, ou s'il est arrêté ;
-- - le premier arrivé passe en premier ; plusieurs étapes de suite dans la même zone (poser l'outil arrière, puis
--   l'avant, reprendre la masse...) : il la garde ;
-- - jamais de blocage sans fin : si celui qui a la zone attend lui-même celui qui attend, ou fait la file derrière
--   lui depuis DEADLOCK_TIME, ou au bout de MAX_WAIT, celui qui attend repart (comme avant) ;
-- - déjà sur place (attelage ou dételage commencé) : jamais arrêté au milieu de la manœuvre.
--
-- Enveloppes posées au chargement : ADTaskModule:update (suivi des zones), ADDrivePathModule:handleDrivingModules
-- (arrêt sur la route), ADTrafficYieldModule.getWaitInfo (texte de l'ATH), AutonomousMode:monitorFetchRoute (pas
-- d'abandon de la route pendant l'attente). Chargé par register.lua après TrailerCoverField.lua.
-- ============================================================================================================

ADYardZone = {}

ADYardZone.APPROACH = 45          -- m de sa place (ou de l'outil) : le tracteur demande la zone
ADYardZone.CONFLICT = 30          -- m entre deux places (ou outils) : même zone
ADYardZone.RELEASE = 40           -- m du centre de sa zone : sorti, zone rendue
ADYardZone.CHECK_INTERVAL = 500   -- ms entre deux regards
ADYardZone.DEADLOCK_TIME = 20000  -- ms : celui qui a la zone fait la file derrière celui qui attend : il repart
ADYardZone.MAX_WAIT = 600000      -- ms d'attente au plus

-- zones prises : [véhicule] = { { x, z, label }, ... }
ADYardZone.claims = {}

local function nameOf(vehicle)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
        local ok, n = pcall(vehicle.ad.stateModule.getName, vehicle.ad.stateModule)
        if ok and n ~= nil then
            return tostring(n)
        end
    end
    return "?"
end

local function toolLabel(tool)
    if tool == nil then
        return "?"
    end
    local ok, l = pcall(ADAutonomousManager.toolLabel, tool)
    return ok and l ~= nil and tostring(l) or "?"
end

local function position(object)
    local node = object ~= nil and object.components ~= nil and object.components[1] ~= nil and object.components[1].node or nil
    if node == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

local function markerPoint(markerId)
    if markerId == nil or markerId < 1 then
        return nil
    end
    local marker = ADGraphManager:getMapMarkerById(markerId)
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp == nil then
        return nil
    end
    return wp.x, wp.z, marker.name
end

local function distance(ax, az, bx, bz)
    return MathUtil.vector2Length(ax - bx, az - bz)
end

-- tracteur en mode Autonome, conduit par FarmPilot
function ADYardZone.isAutonomous(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    return sm ~= nil and sm:isActive() and sm:getMode() == AutoDrive.MODE_AUTONOMOUS
end

-- étape d'outils en cours : { x, z, label, canWait } (centre de la zone voulue), ou nil
-- canWait : le tracteur roule encore vers sa place (route, ou chemin vers l'outil pas encore commencé à reculer)
function ADYardZone.getStep(vehicle)
    if not ADYardZone.isAutonomous(vehicle) then
        return nil
    end
    local mode = vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS] or nil
    if mode == nil then
        return nil
    end
    local task = vehicle.ad.taskModule ~= nil and vehicle.ad.taskModule:getActiveTask() or nil
    local class = task ~= nil and task.class ~= nil and task:class() or nil
    local onRoute = class ~= nil and class == DriveToDestinationTask
    local fs, ps = mode.fetchStage, mode.parkStage
    if (fs == "route" or fs == "attach") and mode.fetchTool ~= nil and not mode.fetchTool.isDeleted then
        local x, z = position(mode.fetchTool)
        if x == nil then
            return nil
        end
        local canWait = onRoute
        if not canWait and class ~= nil and (class == ADFetchToolTask or class == ADFetchFrontToolTask) and task.state ~= nil then
            canWait = task.state == ADFetchToolTask.STATE_PLAN or task.state == ADFetchToolTask.STATE_PLANNING or task.state == ADFetchToolTask.STATE_DRIVING
        end
        return { x = x, z = z, label = toolLabel(mode.fetchTool), canWait = canWait }
    end
    if ps == "tool" or ps == "noseRoute" or ps == "detach" or ps == "backoff" then
        local tool = mode.parkTool
        local x, z, label = nil, nil, nil
        if tool ~= nil and tool.advd ~= nil then
            x, z, label = markerPoint(tool.advd.parkDestination)
        end
        if x == nil and mode.noseDrop ~= nil and mode.noseDrop.slot ~= nil and mode.noseDrop.slot.x ~= nil then
            x, z, label = mode.noseDrop.slot.x, mode.noseDrop.slot.z, mode.noseDrop.placeName
        end
        if x == nil and onRoute and task.destinationID ~= nil then
            local wp = ADGraphManager:getWayPointById(task.destinationID)
            if wp ~= nil then
                x, z = wp.x, wp.z
            end
        end
        if x == nil then
            x, z = position(vehicle)
        end
        if x == nil then
            return nil
        end
        return { x = x, z = z, label = label ~= nil and tostring(label) or toolLabel(tool), canWait = onRoute }
    end
    if ps == "tractor" then
        local x, z, label = markerPoint(mode.tractorParkId)
        if x == nil then
            return nil
        end
        return { x = x, z = z, label = tostring(label), canWait = onRoute }
    end
    return nil
end

-- zone d'un autre tracteur qui couvre ce point : véhicule, zone
function ADYardZone.findBlocker(vehicle, x, z)
    for other, zones in pairs(ADYardZone.claims) do
        if other ~= vehicle then
            if other.isDeleted or not ADYardZone.isAutonomous(other) then
                ADYardZone.claims[other] = nil
            else
                for _, zone in ipairs(zones) do
                    if distance(zone.x, zone.z, x, z) <= ADYardZone.CONFLICT then
                        return other, zone
                    end
                end
            end
        end
    end
    return nil
end

-- celui qui a la zone fait la file derrière celui qui attend (ou l'attend lui-même) : celui qui attend repart
local function isBlockedBy(owner, waiter)
    local wait = owner.ad ~= nil and owner.ad.fpYardWait or nil
    if wait ~= nil and wait.by == waiter then
        return true, "il attend lui-même que %s libère sa zone"
    end
    local am = owner.ad ~= nil and owner.ad.approachModule or nil
    if am ~= nil and am.shouldStop ~= nil and am:shouldStop() then
        local hit = am:getHit()
        local root = hit ~= nil and hit.object ~= nil and hit.object.getRootVehicle ~= nil and hit.object:getRootVehicle() or nil
        if root == waiter then
            return false, "queue"
        end
    end
    return false, nil
end

local function release(vehicle, index, why)
    local zones = ADYardZone.claims[vehicle]
    local zone = zones ~= nil and zones[index] or nil
    if zone == nil then
        return
    end
    table.remove(zones, index)
    if #zones == 0 then
        ADYardZone.claims[vehicle] = nil
    end
    ADAutonomousManager.log("%s : zone de « %s » rendue (%s)", nameOf(vehicle), tostring(zone.label), why)
end

local function claim(vehicle, step, why)
    local zones = ADYardZone.claims[vehicle] or {}
    ADYardZone.claims[vehicle] = zones
    zones[#zones + 1] = { x = step.x, z = step.z, label = step.label }
    ADAutonomousManager.log("%s : prend la zone de « %s »%s", nameOf(vehicle), tostring(step.label), why or "")
end

local function stopWaiting(vehicle)
    vehicle.ad.fpYardWait = nil
end

-- à chaque image du tracteur (ADTaskModule:update)
function ADYardZone.update(vehicle, dt)
    local ad = vehicle.ad
    ad.fpYardCheck = (ad.fpYardCheck or 0) + dt
    if ad.fpYardCheck < ADYardZone.CHECK_INTERVAL then
        return
    end
    local elapsed = ad.fpYardCheck
    ad.fpYardCheck = 0
    local zones = ADYardZone.claims[vehicle]
    if not ADYardZone.isAutonomous(vehicle) then
        stopWaiting(vehicle)
        if zones ~= nil then
            for i = #zones, 1, -1 do
                release(vehicle, i, "tracteur arrêté")
            end
        end
        return
    end
    local want = ADYardZone.getStep(vehicle)
    local vx, vz = position(vehicle)
    if vx == nil then
        return
    end
    -- zones quittées
    if zones ~= nil then
        for i = #zones, 1, -1 do
            local zone = zones[i]
            local stillWanted = want ~= nil and distance(zone.x, zone.z, want.x, want.z) <= ADYardZone.CONFLICT
            if not stillWanted and distance(zone.x, zone.z, vx, vz) > ADYardZone.RELEASE then
                release(vehicle, i, string.format("sorti, à %.0f m", distance(zone.x, zone.z, vx, vz)))
            end
        end
        zones = ADYardZone.claims[vehicle]
    end
    if want == nil then
        stopWaiting(vehicle)
        return
    end
    -- zone déjà à lui
    if zones ~= nil then
        for _, zone in ipairs(zones) do
            if distance(zone.x, zone.z, want.x, want.z) <= ADYardZone.CONFLICT then
                stopWaiting(vehicle)
                return
            end
        end
    end
    if want.canWait and distance(want.x, want.z, vx, vz) > ADYardZone.APPROACH then
        stopWaiting(vehicle)
        return
    end
    local other, zone = ADYardZone.findBlocker(vehicle, want.x, want.z)
    if other == nil then
        stopWaiting(vehicle)
        claim(vehicle, want)
        return
    end
    if not want.canWait then
        -- déjà sur place, manœuvre commencée : jamais arrêté au milieu
        stopWaiting(vehicle)
        claim(vehicle, want, string.format(" (déjà sur place, zone partagée avec %s)", nameOf(other)))
        return
    end
    local wait = ad.fpYardWait
    if wait == nil or wait.by ~= other then
        wait = { by = other, label = zone.label, ms = 0, queueMs = 0 }
        ad.fpYardWait = wait
        ADAutonomousManager.log("%s : attend que %s libère la zone de « %s » (sa place « %s » à %.0f m)", nameOf(vehicle), nameOf(other), tostring(zone.label),
            tostring(want.label), distance(zone.x, zone.z, want.x, want.z))
    end
    wait.ms = wait.ms + elapsed
    local mutual, how = isBlockedBy(other, vehicle)
    if how == "queue" and math.abs(other.lastSpeedReal or 0) < 0.0003 then
        wait.queueMs = wait.queueMs + elapsed
    else
        wait.queueMs = 0
    end
    local why = nil
    if mutual then
        why = string.format(how, nameOf(vehicle))
    elseif wait.queueMs >= ADYardZone.DEADLOCK_TIME then
        why = string.format("il fait la file derrière lui depuis %.0f s", wait.queueMs / 1000)
    elseif wait.ms >= ADYardZone.MAX_WAIT then
        why = string.format("%.0f min d'attente", wait.ms / 60000)
    end
    if why ~= nil then
        ADAutonomousManager.log("%s : n'attend plus %s (%s), entre dans la zone de « %s » comme avant", nameOf(vehicle), nameOf(other), why, tostring(zone.label))
        stopWaiting(vehicle)
        claim(vehicle, want, string.format(" (zone partagée avec %s)", nameOf(other)))
    end
end

local baseTaskModuleUpdate = ADTaskModule.update
function ADTaskModule:update(dt)
    if self.vehicle ~= nil and self.vehicle.ad ~= nil then
        FarmPilotCall(ADYardZone.update, self.vehicle, dt)
    end
    return baseTaskModuleUpdate(self, dt)
end

-- attente : arrêté sur la route (comme le croisement, pas un véhicule bloqué)
local baseHandleDrivingModules = ADDrivePathModule.handleDrivingModules
function ADDrivePathModule:handleDrivingModules(dt, obstacleDetected)
    local vehicle = self.vehicle
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.fpYardWait ~= nil and ADYardZone.isAutonomous(vehicle) then
        vehicle.ad.specialDrivingModule:stopVehicle(false)
        vehicle.ad.specialDrivingModule:update(dt)
        return true, obstacleDetected
    end
    return baseHandleDrivingModules(self, dt, obstacleDetected)
end

-- ATH : « Attend que X libère la zone des outils »
local baseGetWaitInfo = ADTrafficYieldModule.getWaitInfo
function ADTrafficYieldModule.getWaitInfo(vehicle)
    local wait = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.fpYardWait or nil
    if wait ~= nil and wait.by ~= nil then
        return "$l10n_AD_ty_waitFor; " .. ADTrafficYieldModule.getName(wait.by) .. " $l10n_AD_ty_toLeaveYard;"
    end
    return baseGetWaitInfo(vehicle)
end

-- route vers l'outil : arrêté parce qu'il attend, ce n'est pas « arrêté près de l'outil »
local baseMonitorFetchRoute = AutonomousMode.monitorFetchRoute
function AutonomousMode:monitorFetchRoute(dt)
    if self.vehicle ~= nil and self.vehicle.ad ~= nil and self.vehicle.ad.fpYardWait ~= nil then
        self.fetchStuckTimer = 0
        return
    end
    return baseMonitorFetchRoute(self, dt)
end
