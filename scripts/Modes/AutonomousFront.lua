-- ============================================================================================================
-- FarmPilot : AutonomousFront.lua
-- Complément de AutonomousMode.lua : le déroulement de l'attelage AVANT (outils frontaux et masses).
--
-- Règle (10/11) :
-- - Départ : outil avant choisi (ligne « Outil avant ») et pas attelé. L'avant du tracteur est libre : il va
--   l'atteler en marche avant (FetchFrontToolTask.lua). L'avant est pris :
--   * par une masse : elle est posée à la place de parking du tracteur (rien d'autre à régler), et gardée en
--     mémoire pour être reprise en fin de travail, avant qu'il s'y gare ;
--   * par un autre outil avant : posé à sa place de parking s'il en a une, sinon à côté de l'outil arrière qui
--     vient d'être posé (changement d'outil au champ suivant), sinon à côté de l'outil avant à prendre.
--   Puis départ normal (start), qui attelle ensuite l'outil arrière comme avant.
-- - Champ suivant : la ligne « Outil avant suivant » devient l'outil avant ; le départ fait l'échange.
-- - Fin du travail : l'outil arrière est posé à sa place (comme avant), puis l'outil avant (à sa place s'il en a
--   une, sinon DEVANT l'outil arrière, dans la même place, le nez en avant : faucheuse avant et faucheuse arrière
--   rangées l'une devant l'autre dans une travée ; si l'outil arrière n'est pas dans l'axe d'une place : à côté de
--   lui, sans ligne au sol), puis la masse posée au départ est reprise, puis le tracteur va à sa place.
-- - Après un dételage ou un attelage à l'avant, il recule tout droit, puis rejoint une route en marche avant par une
--   courbe calculée (plus de demi-tour sur place devant la place, voir AutonomousNoseIn.lua : exitPlan).
-- - Outil avant sans place rangé dans une place prise en marche arrière (devant l'outil arrière) : repris comme
--   s'il y avait sa place, par les routes puis la courbe, le nez en avant.
-- - Une masse attelée n'est jamais posée en fin de travail.
-- - Place prise en marche arrière (toutes les places de parking en général) : un outil avant y va À CONTRESENS,
--   le nez en avant, sur la ligne de la place, et il y est posé au fond (comme la masse à la place du tracteur) ;
--   pour le reprendre, pareil : jamais par la route de la place, qui amène le tracteur l'arrière vers l'outil.
--   Le demi-tour se fait par les routes, puis une courbe calculée entre dans la place (AutonomousNoseIn.lua).
--
-- Branché par une ligne dans AutonomousMode.lua : reset, start (checkStart, execute), goToNextField
-- (applyNextFront), parkWithToolDrop (parkWithFront), handleParkStage, startFetch (fetchRoutePoint),
-- monitorFetchRoute (readyFor, forwardInPlace), startFetchAttach (tâche), handleFetchStage (afterFetch).
-- ============================================================================================================

ADFrontFlow = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFrontFlow.LAST_REAR_RANGE = 60   -- m : outil arrière posé à moins de ça du tracteur = l'outil avant se pose à côté
ADFrontFlow.PLACE_ANGLE = 30       -- ° : route de la place de l'outil avant qui arrive le nez vers l'outil
ADFrontFlow.DIRECT_RANGE = 50      -- m : outil au fond d'une place prise en marche arrière, tracteur à moins de ça = il y va directement
ADFrontFlow.AHEAD_GAP = 1          -- m entre l'outil arrière rangé au fond de sa place et l'outil avant posé devant lui
ADFrontFlow.AHEAD_MAX = 8          -- m : l'avant de l'outil arrière est au plus à ça devant le point de sa place
ADFrontFlow.AHEAD_SIDE = 0.2       -- m libres de chaque côté de l'outil avant (et du tracteur) devant l'outil arrière

-- ------------------------------------------------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------------------------------------------------
local function nameOf(vehicle)
    return tostring(vehicle.ad.stateModule:getName())
end

local function label(tool)
    if tool == nil then
        return "?"
    end
    local ok, l = FarmPilotCall(ADAutonomousManager.frontLabel, tool)
    return ok and tostring(l) or ADAutonomousManager.toolLabel(tool)
end

local function isAttached(tool)
    return tool ~= nil and tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() ~= nil
end

-- place de parking propre à l'outil (marqueur), ou nil ; except : place d'un autre outil (combiné : même place)
local function ownMarker(tool, except)
    local park = tool ~= nil and tool.advd ~= nil and tool.advd.parkDestination or -1
    if park == nil or park < 1 or park == except then
        return nil
    end
    return ADGraphManager:getMapMarkerById(park)
end

local function parkIdOf(tool)
    return tool ~= nil and tool.advd ~= nil and tool.advd.parkDestination or -1
end

-- outil arrière posé juste avant par ce tracteur, encore là et pas loin : l'outil avant se pose à côté
local function lastRearDrop(vehicle)
    local last = vehicle.ad.fpLastRearDrop
    if last == nil or last.isDeleted or isAttached(last) or last.components == nil then
        return nil
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local tx, _, tz = getWorldTranslation(last.components[1].node)
    if MathUtil.vector2Length(tx - vx, tz - vz) > ADFrontFlow.LAST_REAR_RANGE then
        return nil
    end
    return last
end

local function stop(mode)
    mode.vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(mode.vehicle), ADTaskModule.DONT_PROPAGATE)
end

-- Masse à la place du tracteur (10/11) : le tracteur y entre le NEZ EN AVANT, en prenant la ligne de la place à
-- l'envers, et pose la masse au fond, là où se trouve l'arrière du tracteur quand il y est garé.
ADFrontFlow.MASS_DEPTH_MARGIN = 0.5  -- m entre le bout de la masse et le dernier point de la place
ADFrontFlow.MASS_EXIT_MARGIN = 4     -- m de recul en plus de la longueur du tracteur et de la masse

-- { x, y, z, dirX, dirZ } : où arrive l'attelage avant du tracteur (point d'attelage de la masse posée), direction de
-- la place vers sa sortie ; la distance à reculer ensuite ; true si la place se prend en marche arrière. nil si l'axe
-- de la place est inconnu (aucune route n'y arrive)
function ADFrontFlow.parkSlot(vehicle, marker, tool)
    local mwp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if mwp == nil then
        return nil
    end
    local hx, hz, reverse = AutonomousMode.placeAxis(mwp)
    if hx == nil then
        return nil
    end
    local len = (vehicle.size ~= nil and vehicle.size.length) or 6
    local ml = (tool ~= nil and tool.size ~= nil and tool.size.length) or 1
    -- le dernier point de la place est au fond (là où s'arrête l'arrière du tracteur garé en marche arrière, ou plus
    -- loin s'il y entre en avant) : la masse s'arrête MASS_DEPTH_MARGIN m avant
    local back = ml + ADFrontFlow.MASS_DEPTH_MARGIN
    local slot = { x = mwp.x - hx * back, y = mwp.y, z = mwp.z - hz * back, dirX = -hx, dirZ = -hz }
    if reverse then
        slot.place = mwp -- place prise en marche arrière : entrée en courbe, voir AutonomousNoseIn.lua
    end
    return slot, len + ml + ADFrontFlow.MASS_EXIT_MARGIN, reverse == true
end

-- Outil avant sans place (10/11) : posé DEVANT l'outil arrière, dans la place de celui-ci, sur son axe (faucheuse
-- avant et faucheuse arrière rangées l'une devant l'autre). Mêmes valeurs que parkSlot, plus la place (marqueur) ;
-- slot.ahead = m entre le fond de la place et le bout de l'outil avant, slot.aheadTool = l'outil arrière.
-- nil si l'outil arrière n'a pas de place, n'y est pas rangé dans l'axe, ou si l'axe est inconnu
function ADFrontFlow.aheadSlot(vehicle, rear, tool)
    local marker = ownMarker(rear)
    local mwp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if mwp == nil or mwp.x == nil or rear.components == nil then
        return nil
    end
    local hx, hz, reverse = AutonomousMode.placeAxis(mwp)
    local hitch = hx ~= nil and ADAutonomousManager.toolHitch(vehicle, rear) or nil
    if hitch == nil or not AutonomousMode.toolInPlace(mwp, hitch) then
        return nil
    end
    -- l'avant de l'outil arrière le long de l'axe (négatif : avant le point de la place) : son point d'attelage, ou
    -- le bout de sa longueur s'il dépasse
    local front = (hitch.x - mwp.x) * hx + (hitch.z - mwp.z) * hz
    local rx, _, rz = getWorldTranslation(rear.components[1].node)
    local size = rear.size or {}
    front = math.min(front, (rx - mwp.x) * hx + (rz - mwp.z) * hz - (size.length or 0) / 2 - math.abs(size.lengthOffset or 0))
    local len = (vehicle.size ~= nil and vehicle.size.length) or 6
    local ml = (tool ~= nil and tool.size ~= nil and tool.size.length) or 1
    if -front > ADFrontFlow.AHEAD_MAX then
        return nil -- posé loin devant sa place : pas rangé
    end
    local ahead = math.max(0, -front) + ADFrontFlow.AHEAD_GAP
    local back = ahead + ml
    local slot = { x = mwp.x - hx * back, y = mwp.y, z = mwp.z - hz * back, dirX = -hx, dirZ = -hz, ahead = ahead, aheadTool = rear }
    -- rien devant l'outil arrière, du bout de l'outil avant jusqu'à l'arrière du tracteur (palette, autre outil,
    -- véhicule) : sinon comme avant, à côté
    if ADNoseIn ~= nil then
        local points = {}
        local d = ahead
        while d <= back + len do
            points[#points + 1] = { x = mwp.x - hx * d, z = mwp.z - hz * d }
            d = d + 1
        end
        local half = math.max((vehicle.size ~= nil and vehicle.size.width) or 3, (tool ~= nil and tool.size ~= nil and tool.size.width) or 0) / 2
        local obstacles = ADNoseIn.obstacles(vehicle, { rear }, slot.x, slot.z, 40)
        if not ADNoseIn.pointsClear(points, obstacles, half + ADFrontFlow.AHEAD_SIDE) then
            ADAutonomousManager.log("%s : la place devant « %s » n'est pas libre (%.1f m de large sur %.0f m)", nameOf(vehicle), label(rear), 2 * (half + ADFrontFlow.AHEAD_SIDE),
                back + len - ahead)
            return nil
        end
    end
    if reverse then
        slot.place = mwp -- place prise en marche arrière : entrée en courbe, voir AutonomousNoseIn.lua
    end
    return slot, len + ml + ADFrontFlow.MASS_EXIT_MARGIN, marker
end

-- ------------------------------------------------------------------------------------------------------------
-- Remise à zéro (AutonomousMode:reset)
-- ------------------------------------------------------------------------------------------------------------
function ADFrontFlow.reset(mode)
    mode.fetchSide = nil
    mode.parkSide = nil
    mode.placeTask = nil
    mode.backOffTask = nil
    mode.fpQueue = nil
    mode.fpQueueTractor = nil
    mode.backOffDistance = nil
    mode.noseDrop = nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ : outil avant à atteler (AutonomousMode:start)
-- ------------------------------------------------------------------------------------------------------------
-- avant reset : true = départ refusé (message donné) ; sinon nil, plan { fetch, drop, dropMarker, dropBeside,
-- besideSide, dropSlot, dropPlace, dropBack (masse : place du tracteur, nez en avant) } ou nil (rien à faire à l'avant)
function ADFrontFlow.checkStart(mode)
    local vehicle = mode.vehicle
    local ok, tool, err, wanted = FarmPilotCall(ADAutonomousManager.frontToFetch, vehicle)
    if not ok then
        ADAutonomousManager.log("ERREUR outil avant à atteler : %s", tostring(tool))
        return nil, nil
    end
    if err ~= nil then
        local key = ({ busy = "AD_autonomous_fetchBusy", noJoint = "AD_autonomous_frontNoJoint" })[err] or "AD_autonomous_fetchFailed"
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 12000, key, label(wanted))
        ADAutonomousManager.log("%s : départ refusé, outil avant choisi : %s", nameOf(vehicle), tostring(err))
        if vehicle.ad.stateModule:isActive() then
            vehicle:stopAutoDrive()
        end
        return true
    end
    if tool == nil then
        return nil, nil
    end
    local plan = { fetch = tool }
    local current = ADAutonomousManager.frontObject(vehicle)
    if current ~= nil then
        plan.drop = current
        plan.dropMass = ADAutonomousManager.isMass(current)
        local marker = not plan.dropMass and ownMarker(current) or nil
        if plan.dropMass then
            -- masse : posée à la place de parking du tracteur, reprise quand il revient s'y garer
            local park = vehicle.advd ~= nil and vehicle.advd.parkDestination or -1
            local parkMarker = park ~= nil and park >= 1 and ADGraphManager:getMapMarkerById(park) or nil
            if parkMarker ~= nil then
                plan.dropSlot, plan.dropBack = ADFrontFlow.parkSlot(vehicle, parkMarker, current)
                plan.dropPlace = parkMarker.name
            end
            if plan.dropSlot == nil then
                AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 12000, "AD_autonomous_massNoPark", label(current))
                ADAutonomousManager.log("%s : départ refusé, pas de place de parking du tracteur pour poser « %s »", nameOf(vehicle), label(current))
                if vehicle.ad.stateModule:isActive() then
                    vehicle:stopAutoDrive()
                end
                return true
            end
        end
        if marker ~= nil then
            plan.dropMarker = marker
        elseif plan.dropSlot == nil then
            local rear = not plan.dropMass and lastRearDrop(vehicle) or nil
            if rear ~= nil then
                plan.dropBeside, plan.besideSide = rear, "rear"
            else
                -- outil avant sans place : à côté de l'outil avant à prendre
                plan.dropBeside, plan.besideSide = tool, "front"
            end
        end
    end
    return nil, plan
end

-- après reset : lance la dépose ou l'attelage ; true si lancé
function ADFrontFlow.execute(mode, plan)
    local vehicle = mode.vehicle
    local sm = vehicle.ad.stateModule
    if plan.drop ~= nil then
        if plan.dropMass and not ADAutonomousManager.isMass(plan.fetch) then
            -- masse reprise en fin de travail
            sm:setFpMassReturn(plan.drop)
        end
        mode.parkThen = "restart"
        if plan.dropSlot ~= nil then
            ADFrontFlow.startDropAt(mode, plan.drop, plan.dropSlot, plan.dropPlace, plan.dropBack)
        else
            ADFrontFlow.startDrop(mode, plan.drop, plan.dropMarker, plan.dropBeside, plan.besideSide)
        end
        return true
    end
    if ADAutonomousManager.isMass(plan.fetch) and sm:getFpMassReturn() == plan.fetch then
        sm:setFpMassReturn(nil)
    end
    mode.fetchSide = "front"
    mode:startFetch(plan.fetch)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Dépose à l'avant : à sa place, ou à côté d'un outil posé
-- ------------------------------------------------------------------------------------------------------------
function ADFrontFlow.startDrop(mode, tool, marker, beside, besideSide)
    local vehicle = mode.vehicle
    mode.parkStage = "tool"
    mode.parkTool = tool
    mode.parkSide = "front"
    if marker ~= nil then
        -- sa place se prend en marche arrière : par la route, l'outil avant resterait à l'entrée et le tracteur au
        -- fond ; il y entre à contresens, le nez en avant, et pose l'outil au fond
        local slot, back, reverse = ADFrontFlow.parkSlot(vehicle, marker, tool)
        if slot ~= nil and reverse then
            ADFrontFlow.startDropAt(mode, tool, slot, marker.name, back)
            return
        end
        ADAutonomousManager.log("%s : « %s » (avant) va à sa place « %s »", nameOf(vehicle), label(tool), tostring(marker.name))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_dropGo", tostring(marker.name))
        mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, marker.id)
        vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
        return
    end
    if beside ~= nil and besideSide == "rear" then
        -- l'outil arrière est rangé dans sa place : l'outil avant va devant lui, dans la même place
        local ok, slot, back, place = FarmPilotCall(ADFrontFlow.aheadSlot, vehicle, beside, tool)
        if not ok then
            ADAutonomousManager.log("ERREUR place devant l'outil arrière : %s", tostring(slot))
        elseif slot ~= nil then
            ADFrontFlow.startDropAt(mode, tool, slot, place.name, back)
            return
        end
    end
    ADAutonomousManager.log("%s : « %s » (avant) posé à côté de « %s »", nameOf(vehicle), label(tool), label(beside))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_frontBeside", label(tool), label(beside))
    mode.placeTask = ADFrontPlaceTask:new(vehicle, tool, beside, besideSide)
    mode.driveToDestinationTask = mode.placeTask
    vehicle.ad.taskModule:addTask(mode.placeTask)
end

-- masse au fond de la place du tracteur, nez en avant ; back : m à reculer après le dételage
function ADFrontFlow.startDropAt(mode, tool, slot, placeName, back)
    local vehicle = mode.vehicle
    mode.parkStage = "tool"
    mode.parkTool = tool
    mode.parkSide = "front"
    mode.backOffDistance = back
    if slot.aheadTool ~= nil then
        ADAutonomousManager.log("%s : « %s » (avant) posé dans la place « %s », devant « %s » (à %.1f m du fond), entrée en marche avant", nameOf(vehicle), label(tool),
            tostring(placeName), label(slot.aheadTool), slot.ahead or 0)
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_frontDropAhead", label(tool), tostring(placeName), label(slot.aheadTool))
    else
        ADAutonomousManager.log("%s : « %s » (avant) posé à la place « %s », entrée en marche avant", nameOf(vehicle), label(tool), tostring(placeName))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_frontDropAt", label(tool), tostring(placeName))
    end
    -- place prise en marche arrière : d'abord par les routes jusqu'au point d'où une courbe en marche avant entre
    -- dans la place (garé dedans, il fait le tour) ; voir AutonomousNoseIn.lua
    if slot.place ~= nil and ADNoseIn ~= nil then
        local ok, plan = FarmPilotCall(ADNoseIn.plan, vehicle, slot.place, tool, slot.ahead)
        if not ok then
            ADAutonomousManager.log("ERREUR entrée le nez en avant : %s", tostring(plan))
        elseif plan ~= nil and not plan.ready then
            ADAutonomousManager.log("%s : par les routes (%.0f m) jusqu'au point %s, d'où il entre dans « %s » le nez en avant", nameOf(vehicle), plan.approach.route or 0,
                tostring(plan.wp.id), tostring(placeName))
            mode.parkStage = "noseRoute"
            mode.noseDrop = { tool = tool, slot = slot, placeName = placeName }
            mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, plan.wp.id)
            vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
            return
        elseif plan == nil then
            ADAutonomousManager.log("%s : pas de courbe possible vers « %s », recherche de chemin", nameOf(vehicle), tostring(placeName))
        end
    end
    mode.placeTask = ADFrontPlaceTask:newAt(vehicle, tool, slot, placeName)
    mode.driveToDestinationTask = mode.placeTask
    vehicle.ad.taskModule:addTask(mode.placeTask)
end

-- étapes de la dépose (AutonomousMode:handleParkStage) ; true si traité ici
function ADFrontFlow.handleParkStage(mode)
    local vehicle = mode.vehicle
    local stage = mode.parkStage
    if stage == "noseRoute" then
        -- arrivé par les routes devant la place : la courbe, puis tout droit jusqu'au fond (FrontPlaceTask.lua)
        local drop = mode.noseDrop
        mode.noseDrop = nil
        mode.driveToDestinationTask = nil
        if drop == nil or vehicle.ad.isStoppingWithError then
            mode.parkStage = nil
            mode.parkTool = nil
            mode.parkSide = nil
            mode.parkThen = nil
            mode.fpQueue = nil
            stop(mode)
            return true
        end
        mode.parkStage = "tool"
        mode.placeTask = ADFrontPlaceTask:newAt(vehicle, drop.tool, drop.slot, drop.placeName)
        mode.driveToDestinationTask = mode.placeTask
        vehicle.ad.taskModule:addTask(mode.placeTask)
        return true
    end
    if stage == "tool" and mode.placeTask ~= nil then
        local result = mode.placeTask.result or "?"
        mode.placeTask = nil
        mode.driveToDestinationTask = nil
        if result ~= "ok" or vehicle.ad.isStoppingWithError then
            ADAutonomousManager.log("%s : « %s » pas posé (%s), arrêt", nameOf(vehicle), label(mode.parkTool), tostring(result))
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_frontPlaceFailed", label(mode.parkTool))
            mode.parkStage = nil
            mode.parkTool = nil
            mode.parkSide = nil
            mode.parkThen = nil
            mode.fpQueue = nil
            stop(mode)
            return true
        end
        mode.parkStage = "detach"
        mode.detachTask = ADDetachToolTask:new(vehicle, mode.parkTool)
        vehicle.ad.taskModule:addTask(mode.detachTask)
        return true
    end
    if stage == "detach" then
        local result = mode.detachTask ~= nil and mode.detachTask.result or "?"
        if result ~= "ok" then
            return false -- échec : comme avant (message, arrêt)
        end
        if mode.parkSide ~= "front" and mode.parkTool ~= nil then
            -- outil arrière posé : l'outil avant pourra se poser à côté
            vehicle.ad.fpLastRearDrop = mode.parkTool
        end
        if mode.parkSide == "front" then
            -- l'outil est contre le nez du tracteur : recul tout droit d'abord
            ADAutonomousManager.log("%s : « %s » (avant) dételé, recul", nameOf(vehicle), label(mode.parkTool))
            mode.detachTask = nil
            mode.parkStage = "backoff"
            mode.backOffTask = ADFrontBackOffTask:new(vehicle, mode.backOffDistance, true, nil)
            mode.backOffDistance = nil
            vehicle.ad.taskModule:addTask(mode.backOffTask)
            return true
        end
        if mode.fpQueue ~= nil or mode.parkThen == "restart" then
            mode.detachTask = nil
            ADFrontFlow.continueAfterDrop(mode)
            return true
        end
        return false -- comme avant : outil suivant, ou tracteur garé
    end
    if stage == "backoff" then
        mode.backOffTask = nil
        mode.parkStage = nil
        ADFrontFlow.continueAfterDrop(mode)
        return true
    end
    return false
end

function ADFrontFlow.continueAfterDrop(mode)
    mode.backOffDistance = nil
    mode.parkStage = nil
    mode.parkTool = nil
    mode.parkSide = nil
    if mode.parkThen == "restart" then
        mode.parkThen = nil
        mode:start()
        return
    end
    if mode.parkThen == "swap" then
        -- (ne sert qu'à l'arrière, voir AutonomousMode:handleParkStage)
        mode.parkThen = nil
    end
    ADFrontFlow.nextStep(mode)
end

-- ------------------------------------------------------------------------------------------------------------
-- Champ suivant (AutonomousMode.goToNextField)
-- ------------------------------------------------------------------------------------------------------------
function ADFrontFlow.applyNextFront(vehicle)
    local sm = vehicle.ad.stateModule
    if sm.getFpNextFrontTool == nil then
        return
    end
    local nextFront = sm:getFpNextFrontTool()
    if nextFront ~= nil then
        sm:setFpFrontTool(nextFront)
        sm:setFpNextFrontTool(nil)
        ADAutonomousManager.log("%s : outil avant du champ suivant « %s »", nameOf(vehicle), label(nextFront))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin du travail (AutonomousMode.parkWithToolDrop)
-- ------------------------------------------------------------------------------------------------------------
-- masse posée au départ à la place du tracteur et pas encore reprise (nil sinon)
function ADFrontFlow.massWaiting(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    local mass = sm ~= nil and sm.getFpMassReturn ~= nil and sm:getFpMassReturn() or nil
    if mass ~= nil and (isAttached(mass) or mass.isDeleted) then
        sm:setFpMassReturn(nil)
        return nil
    end
    return mass
end

-- bouton parking sans outil à poser : la masse attend à la place du tracteur, il la reprend avant de s'y garer ;
-- true si lancé
function ADFrontFlow.onParkButton(inputManager, vehicle, farmId)
    if ADFrontFlow.massWaiting(vehicle) == nil or vehicle.ad.modes == nil or vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS] == nil then
        return false
    end
    AutoDrive:StopCP(vehicle)
    if vehicle.ad.stateModule:isActive() then
        inputManager:input_start_stop(vehicle, farmId)
    end
    ADParkButton.rememberMode(vehicle)
    vehicle.ad.stateModule:setMode(AutoDrive.MODE_AUTONOMOUS)
    ADAutonomousManager.log("%s : bouton parking : la masse est à sa place, il la reprend d'abord", nameOf(vehicle))
    local ok, started = FarmPilotCall(AutonomousMode.parkWithToolDrop, vehicle)
    if ok and started then
        if not vehicle.ad.stateModule:isActive() then
            ADParkButton.restoreMode(vehicle) -- rien de lancé (avant pris) : il reste où il est, dans son mode d'avant
        end
        return true
    end
    ADParkButton.restoreMode(vehicle)
    return false
end

-- nil = rien à l'avant (comme avant) ; true = lancé (ou rien à faire mais pas le parking d'origine) ; false = rien
-- de lancé (message donné)
function ADFrontFlow.parkWithFront(vehicle, forcedTool)
    local sm = vehicle.ad.stateModule
    local mass = ADFrontFlow.massWaiting(vehicle)
    if forcedTool ~= nil and mass == nil then
        return nil
    end
    local front = ADAutonomousManager.frontObject(vehicle)
    local frontWork = front ~= nil and not ADAutonomousManager.isMass(front) and ADAutonomousManager.isWorkObject(front)
    if not frontWork and mass == nil then
        return nil
    end
    local name = nameOf(vehicle)
    local steps = {}
    -- 1) outil arrière à sa place (règle d'avant)
    -- (bouton parking : l'outil ou la remorque choisi ; si c'est l'outil avant, il est traité en 2)
    local rearTools
    if forcedTool ~= nil then
        rearTools = forcedTool ~= front and { forcedTool } or {}
    else
        rearTools = ADAutonomousManager.workTools(vehicle)
    end
    local rear, rearMarker = nil, nil
    local keptKey = nil
    if #rearTools > 0 then
        rear = rearTools[1]
        local attacher = rear.getAttacherVehicle ~= nil and rear:getAttacherVehicle() or nil
        rearMarker = ownMarker(rear)
        if #rearTools > 1 or attacher ~= vehicle or rearMarker == nil then
            if mass == nil then
                return nil -- comme avant : message, outils gardés
            end
            -- outils gardés (même message qu'avant), mais la masse attend au fond de la place du tracteur : la
            -- reprendre quand même avant qu'il s'y gare (sinon il recule dessus)
            -- (message donné plus bas, une seule fois : celui-ci dit « il se gare comme avant », faux si l'avant reste
            -- pris)
            keptKey = (#rearTools > 1 or attacher ~= vehicle) and "AD_autonomous_dropSeveral" or "AD_autonomous_dropNoToolPark"
            ADAutonomousManager.log("%s : outil arrière gardé (%s), la masse doit quand même être reprise", name, keptKey)
            rear, rearMarker = nil, nil
        else
            steps[#steps + 1] = { kind = "drop", tool = rear, marker = rearMarker, side = "rear" }
        end
    end
    -- 2) outil avant : à sa place, sinon à côté de l'outil arrière
    if frontWork then
        local marker = ownMarker(front, parkIdOf(rear))
        if marker ~= nil then
            steps[#steps + 1] = { kind = "drop", tool = front, marker = marker, side = "front" }
        elseif rear ~= nil then
            steps[#steps + 1] = { kind = "drop", tool = front, beside = rear, besideSide = "rear", side = "front" }
        else
            ADAutonomousManager.log("%s : l'outil avant n'a pas de place de parking", name)
            if mass == nil then
                AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_frontNoPark", label(front))
                return nil
            end
            frontWork = false
        end
    end
    -- 3) la masse posée au départ (l'avant doit être libre)
    if mass ~= nil and (front == nil or frontWork) then
        steps[#steps + 1] = { kind = "fetch", tool = mass }
        -- la masse est au fond de la place du tracteur, prise nez en avant : ressortir en marche arrière sur la même
        -- ligne avant de s'y garer comme d'habitude
        local len = (vehicle.size ~= nil and vehicle.size.length) or 6
        local ml = (mass.size ~= nil and mass.size.length) or 1
        steps[#steps + 1] = { kind = "backoff", distance = len + ml + ADFrontFlow.MASS_EXIT_MARGIN }
    end
    if mass ~= nil and front ~= nil and not frontWork then
        -- l'avant reste pris : la masse ne peut pas être reprise, et le tracteur ne doit pas reculer dessus en se
        -- garant : il ne va pas à sa place
        ADAutonomousManager.log("%s : avant pris par « %s », « %s » pas reprise : le tracteur ne va pas à sa place (la masse y est)", name, label(front), label(mass))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 15000, "AD_autonomous_massBlocked", label(front), label(mass))
        if #steps == 0 then
            return true -- rien de lancé, mais surtout pas le parking d'origine
        end
        return ADFrontFlow.runQueue(vehicle, steps, nil)
    end
    if keptKey ~= nil then
        -- outil arrière gardé, masse reprise, puis garé : le message d'avant est juste
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, keptKey)
    end
    if #steps == 0 then
        return nil
    end
    -- 4) le tracteur à sa place
    local tractorPark = vehicle.advd ~= nil and vehicle.advd.parkDestination or -1
    local tractorMarker = tractorPark ~= nil and tractorPark >= 1 and tractorPark ~= parkIdOf(rear) and ADGraphManager:getMapMarkerById(tractorPark) or nil
    if tractorMarker == nil then
        ADAutonomousManager.log("%s : le tracteur n'a pas de place de parking (à part celle de l'outil)", name)
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_dropNoTractorPark")
        return false
    end
    steps[#steps + 1] = { kind = "park", marker = tractorMarker }
    return ADFrontFlow.runQueue(vehicle, steps, tractorMarker)
end

-- lance les étapes de la fin du travail ; true si lancé
function ADFrontFlow.runQueue(vehicle, steps, tractorMarker)
    local sm = vehicle.ad.stateModule
    local name = nameOf(vehicle)

    local mode = vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.restartCP = false
    sm:setStartHelper(false) -- pas de relance de Courseplay au parking
    vehicle:startAutoDrive()
    if not sm:isActive() then
        return false
    end
    mode:reset()
    mode.fpQueue = steps
    mode.tractorParkId = tractorMarker ~= nil and tractorMarker.id or nil
    local parts = {}
    for _, s in ipairs(steps) do
        parts[#parts + 1] = s.kind == "park" and ("tracteur à « " .. tostring(s.marker.name) .. " »")
            or (s.kind == "backoff" and string.format("recul de %.0f m", s.distance))
            or (s.kind == "fetch" and ("reprendre « " .. label(s.tool) .. " »")
            or ("poser « " .. label(s.tool) .. " »" .. (s.marker ~= nil and (" à « " .. tostring(s.marker.name) .. " »") or " devant l'outil arrière, dans sa place (sinon à côté)")))
    end
    ADAutonomousManager.log("%s : champ fini : %s", name, table.concat(parts, ", "))
    ADFrontFlow.nextStep(mode)
    return true
end

-- étape suivante de la fin du travail
function ADFrontFlow.nextStep(mode)
    local vehicle = mode.vehicle
    local queue = mode.fpQueue
    local step = queue ~= nil and table.remove(queue, 1) or nil
    if step == nil then
        mode.fpQueue = nil
        stop(mode)
        return
    end
    if step.kind == "drop" then
        if not isAttached(step.tool) then
            ADFrontFlow.nextStep(mode)
            return
        end
        if step.side == "front" then
            ADFrontFlow.startDrop(mode, step.tool, step.marker, step.beside, step.besideSide)
            return
        end
        mode.parkStage = "tool"
        mode.parkTool = step.tool
        mode.parkSide = nil
        ADAutonomousManager.log("%s : l'outil va à sa place « %s »", nameOf(vehicle), tostring(step.marker.name))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_dropGo", tostring(step.marker.name))
        mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, step.marker.id)
        vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
    elseif step.kind == "fetch" then
        if isAttached(step.tool) or step.tool.isDeleted then
            if queue[1] ~= nil and queue[1].kind == "backoff" then
                table.remove(queue, 1) -- rien repris : pas de recul
            end
            ADFrontFlow.nextStep(mode)
            return
        end
        ADAutonomousManager.log("%s : reprend « %s »", nameOf(vehicle), label(step.tool))
        mode.fetchSide = "front"
        mode:startFetch(step.tool)
    elseif step.kind == "backoff" then
        ADAutonomousManager.log("%s : ressort de la place en marche arrière (%.0f m)", nameOf(vehicle), step.distance)
        mode.parkStage = "backoff"
        mode.backOffTask = ADFrontBackOffTask:new(vehicle, step.distance, true, ADAutonomousManager.frontObject(vehicle))
        vehicle.ad.taskModule:addTask(mode.backOffTask)
    else
        mode.fpQueue = nil
        mode.parkStage = "tractor"
        vehicle.ad.onRouteToPark = true
        ADAutonomousManager.log("%s : le tracteur va à « %s »", nameOf(vehicle), tostring(step.marker.name))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_dropDone", tostring(step.marker.name))
        mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, step.marker.id)
        vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
    end
end

-- outil attelé (AutonomousMode:handleFetchStage) : fin du travail en cours = étape suivante ; true si traité ici
function ADFrontFlow.afterFetch(mode, tool)
    local side = mode.fetchSide
    mode.fetchSide = nil
    if mode.fpQueue == nil then
        if side == "front" and tool ~= nil then
            -- départ : attelé nez en avant (masse au fond de la place du tracteur...) : ressortir en marche arrière
            -- sur la même ligne avant le départ normal
            local vehicle = mode.vehicle
            local sm = vehicle.ad.stateModule
            if ADAutonomousManager.isMass(tool) and sm.getFpMassReturn ~= nil and sm:getFpMassReturn() == tool then
                sm:setFpMassReturn(nil)
            end
            local len = (vehicle.size ~= nil and vehicle.size.length) or 6
            local ml = (tool.size ~= nil and tool.size.length) or 1
            local back = len + ml + ADFrontFlow.MASS_EXIT_MARGIN
            ADAutonomousManager.log("%s : « %s » attelé à l'avant, ressort en marche arrière (%.0f m) puis départ", nameOf(vehicle), label(tool), back)
            mode.parkStage = "backoff"
            mode.parkThen = "restart"
            mode.backOffTask = ADFrontBackOffTask:new(vehicle, back, true, tool)
            vehicle.ad.taskModule:addTask(mode.backOffTask)
            return true
        end
        return false
    end
    local sm = mode.vehicle.ad.stateModule
    if tool ~= nil and sm.getFpMassReturn ~= nil and sm:getFpMassReturn() == tool then
        sm:setFpMassReturn(nil)
    end
    ADAutonomousManager.log("%s : « %s » repris", nameOf(mode.vehicle), label(tool))
    ADFrontFlow.nextStep(mode)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Aller atteler un outil avant : par le réseau, puis en face de l'outil (AutonomousMode:startFetch)
-- ------------------------------------------------------------------------------------------------------------
-- point du réseau où aller avant l'attelage, et pourquoi (« marker » ou « front ») ; nil : directement à l'attelage
function ADFrontFlow.fetchRoutePoint(vehicle, tool)
    local hitch = ADAutonomousManager.frontHitch(vehicle, tool)
    if hitch == nil or ADFetchFrontToolTask.isReady(vehicle, hitch) then
        return nil
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local function startHere(wp)
        return MathUtil.vector2Length(wp.x - vx, wp.z - vz) <= AutonomousMode.FETCH_NEAR_START
    end
    -- 1) sa place de parking (masse : celle du tracteur, où elle a été posée), si la route y arrive le nez vers
    -- l'outil et qu'il y est
    -- outil au fond d'une place prise en marche arrière : la route de la place y amène le tracteur l'arrière vers
    -- l'outil. Il va par les routes au point d'où une courbe en marche avant entre dans la place (4e valeur : la
    -- place, pour la courbe, voir AutonomousNoseIn.lua). Pas de courbe possible : de loin, par le réseau au point où
    -- la marche arrière commence ; ensuite, ou de près, directement (recherche de chemin), le nez vers l'outil
    local function reversePlaceRoute(pwp)
        -- (la courbe mène dans l'axe de la place : seulement si l'outil y est vraiment, pas posé devant ou à côté)
        if ADNoseIn ~= nil and AutonomousMode.toolInPlace(pwp, hitch) then
            -- outil rangé devant un autre (pas au fond) : m entre le fond de la place et le bout de l'outil
            local hx, hz = AutonomousMode.placeAxis(pwp)
            local tl = (tool.size ~= nil and tool.size.length) or 0
            local ahead = hx ~= nil and -((hitch.x - pwp.x) * hx + (hitch.z - pwp.z) * hz) - tl or 0
            if ahead < 1 then
                ahead = 0
            end
            local ok, plan = FarmPilotCall(ADNoseIn.plan, vehicle, pwp, tool, ahead, { tool })
            if not ok then
                ADAutonomousManager.log("ERREUR entrée le nez en avant : %s", tostring(plan))
            elseif plan ~= nil then
                if plan.ready then
                    return nil, nil, nil, pwp, ahead
                end
                return plan.wp, "front", nil, pwp, ahead
            end
        end
        if MathUtil.vector2Length(hitch.x - vx, hitch.z - vz) <= ADFrontFlow.DIRECT_RANGE then
            return nil
        end
        local start = AutonomousMode.placeReverseStart(pwp)
        if start ~= nil and not startHere(start) then
            return start, "front"
        end
        return nil
    end
    local marker = ownMarker(tool)
    if marker == nil and ADAutonomousManager.isMass(tool) then
        -- masse au fond de la place du tracteur : jamais par la route de la place
        local park = vehicle.advd ~= nil and vehicle.advd.parkDestination or -1
        local parkMarker = park ~= nil and park >= 1 and ADGraphManager:getMapMarkerById(park) or nil
        local pwp = parkMarker ~= nil and ADGraphManager:getWayPointById(parkMarker.id) or nil
        if pwp ~= nil and pwp.x ~= nil and MathUtil.vector2Length(pwp.x - hitch.x, pwp.z - hitch.z) <= AutonomousMode.FETCH_MARKER_NEAR then
            return reversePlaceRoute(pwp)
        end
        return nil
    end
    local mwp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if mwp ~= nil and MathUtil.vector2Length(mwp.x - hitch.x, mwp.z - hitch.z) <= AutonomousMode.FETCH_MARKER_NEAR and not startHere(mwp) then
        local hx, hz, reverse = AutonomousMode.placeAxis(mwp)
        if hx ~= nil and reverse then
            return reversePlaceRoute(mwp)
        end
        if hx ~= nil and -(hx * hitch.dirX + hz * hitch.dirZ) >= math.cos(math.rad(ADFrontFlow.PLACE_ANGLE)) then
            return mwp, "marker", marker.name
        end
    end
    if marker == nil then
        -- (10/11) pas de place à lui, mais rangé dans une place prise en marche arrière (devant l'outil arrière) :
        -- repris comme si c'était sa place, par les routes puis la courbe
        local okP, place = FarmPilotCall(AutonomousMode.reversePlaceOf, hitch)
        local pwp = okP and place ~= nil and ADGraphManager:getWayPointById(place.id) or nil
        if pwp ~= nil and pwp.x ~= nil then
            local wp, kind, name, nosePlace, ahead = reversePlaceRoute(pwp)
            if wp ~= nil or nosePlace ~= nil then
                ADAutonomousManager.log("%s : « %s » est rangé dans la place « %s » : repris par là, le nez en avant", nameOf(vehicle), label(tool), tostring(place.name))
                return wp, kind, name, nosePlace, ahead
            end
        end
    end
    -- 2) le point du réseau le plus proche de l'avant de l'outil
    local length = (vehicle.size ~= nil and vehicle.size.length) or 6
    local d = length + ADFetchToolTask.FRONT_MARGIN
    local fx, fz = hitch.x + hitch.dirX * d, hitch.z + hitch.dirZ * d
    local best, bestDistance = nil, AutonomousMode.FETCH_ROUTE_RANGE
    for _, wp in pairs(ADGraphManager:getWayPoints()) do
        local dist = MathUtil.vector2Length(wp.x - fx, wp.z - fz)
        local along = (wp.x - hitch.x) * hitch.dirX + (wp.z - hitch.z) * hitch.dirZ
        if dist < bestDistance and along >= AutonomousMode.FETCH_ROUTE_CLEAR then
            best, bestDistance = wp, dist
        end
    end
    if best ~= nil and not startHere(best) then
        return best, "front"
    end
    return nil
end

-- en marche avant sur la route de la place, dans son axe
function ADFrontFlow.forwardInPlace(vehicle, mwp)
    local dpm = vehicle.ad ~= nil and vehicle.ad.drivePathModule or nil
    if mwp == nil or dpm == nil or (dpm.getIsReversing ~= nil and dpm:getIsReversing() == true) then
        return false
    end
    local hx, hz = AutonomousMode.placeAxis(mwp)
    if hx == nil then
        return false
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local fx, _, fz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local len = MathUtil.vector2Length(fx, fz)
    if len < 0.001 then
        return false
    end
    local lateral = math.abs((vx - mwp.x) * hz - (vz - mwp.z) * hx)
    local cosA = (fx * hx + fz * hz) / len
    return lateral <= ADFetchToolTask.READY_LATERAL and cosA >= math.cos(math.rad(ADFetchToolTask.READY_ANGLE))
end
