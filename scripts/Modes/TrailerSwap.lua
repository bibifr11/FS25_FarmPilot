-- ============================================================================================================
-- FarmPilot : TrailerSwap.lua
-- Modes Chargement / Livraison et Décharger la moissonneuse : échange de bennes à la livraison.
--
-- (09/11) roue dentée de la ligne « Remorque » (Gui/TrailerSwapGUI.lua) : un dossier de marqueurs = les places
-- (StateModuleTrailer.lua : fpSwapFolder). Quand la benne pleine part à la livraison (UnloadAtDestinationTask) :
-- 1. le tracteur va sur une place libre du dossier (route du réseau jusqu'au marqueur) ;
-- 2. il dételle la pleine (DetachToolTask, comme l'outil posé à sa place) ;
-- 3. il va atteler une benne vide qui est sur une autre place (TrailerHitch.lua : startFetch) ;
-- 4. le mode reprend comme après un déchargement (retour au chargement, ou au champ).
-- Place = le marqueur et la bande de route qui y arrive : 22 m du côté de la benne, 10 m de l'autre, 2,2 m de chaque
-- côté (marche arrière jusqu'au marqueur : la benne est de l'autre côté). Libre si aucun engin n'y est.
-- Benne vide = moins de 1 % de sa capacité, de la ferme, dételée, qui prend le produit de la pleine et s'attelle à
-- l'arrière de ce tracteur. Deux tracteurs sur le même dossier ne visent pas la même place ni la même benne.
-- Pas de place libre, pas de benne vide, ou plusieurs remorques attelées : livraison normale, avec un message.
--
-- Branché par une ligne : UnloadAtDestinationTask:setUp ; TrailerHitch.lua (fin des tâches, attelage, arrêt) ;
-- HUD : Hud.lua (roue dentée), HudButton.lua ; réglage envoyé au serveur par TrailerSwapEvent.lua.
-- ============================================================================================================

ADTrailerSwap = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- modes où l'échange se fait (les autres modes avec benne ne livrent pas en boucle)
ADTrailerSwap.MODES = {
    [AutoDrive.MODE_PICKUPANDDELIVER] = true,
    [AutoDrive.MODE_UNLOAD] = true
}

ADTrailerSwap.EMPTY_SHARE = 0.01 -- benne vide : moins de 1 % de sa capacité
ADTrailerSwap.LANE_BACK = 22     -- m : bande de la place, du côté où reste la benne
ADTrailerSwap.LANE_FRONT = 10    -- m : de l'autre côté du marqueur
ADTrailerSwap.LANE_HALF = 2.2    -- m : demi-largeur de la bande
ADTrailerSwap.RADIUS = 10        -- m : marqueur sans route qui y arrive : cercle autour

ADTrailerSwap.FAIL_KEYS = {
    noFree = "AD_swap_noFree",
    noEmpty = "AD_swap_noEmpty",
    notOne = "AD_swap_notOne"
}

-- [tracteur] = { placeId, trailer } : place et benne visées pendant l'échange
ADTrailerSwap.claims = {}

function ADTrailerSwap.log(fmt, ...)
    local ok, txt = FarmPilotCall(string.format, fmt, ...)
    print("[FarmPilot Échange] " .. (ok and txt or tostring(fmt)))
end

local function nameOf(vehicle)
    return tostring(vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:getName() or "?")
end

local function label(trailer)
    return ADTrailerHitch.label(trailer)
end

local function message(vehicle, messageType, duration, key, ...)
    AutonomousMode.message(vehicle, messageType, duration, key, ...)
end

-- ------------------------------------------------------------------------------------------------------------
-- Réglage du véhicule
-- ------------------------------------------------------------------------------------------------------------
function ADTrailerSwap.isSwapMode(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    return sm ~= nil and sm.getFpSwapFolder ~= nil and ADTrailerSwap.MODES[sm:getMode()] == true
end

-- dossier des places réglé, s'il existe encore ; nil = pas d'échange
function ADTrailerSwap.folder(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    local folder = sm ~= nil and sm.getFpSwapFolder ~= nil and sm:getFpSwapFolder() or nil
    if folder == nil or folder == "" then
        return nil
    end
    local groups = ADGraphManager:getGroups()
    if groups == nil or groups[folder] == nil then
        return nil
    end
    return folder
end

-- dossiers de marqueurs (sauf « All »), dans l'ordre alphabétique
function ADTrailerSwap.folders()
    local out = {}
    for name, _ in pairs(ADGraphManager:getGroups() or {}) do
        if name ~= "All" then
            out[#out + 1] = name
        end
    end
    table.sort(out, function(a, b) return string.lower(tostring(a)) < string.lower(tostring(b)) end)
    return out
end

-- ------------------------------------------------------------------------------------------------------------
-- Places
-- ------------------------------------------------------------------------------------------------------------
-- point d'où on arrive sur le marqueur, et si c'est en marche arrière
local function arrival(wp)
    if wp.incoming ~= nil then
        for _, id in ipairs(wp.incoming) do
            local prev = ADGraphManager:getWayPointById(id)
            if prev ~= nil then
                return prev, false
            end
        end
    end
    -- route en marche arrière : le point d'avant a le marqueur dans ses sorties, pas l'inverse
    for _, prev in pairs(ADGraphManager:getWayPoints()) do
        if prev.out ~= nil and prev.id ~= wp.id and table.contains(prev.out, wp.id) then
            return prev, true
        end
    end
    return nil, false
end

-- places du dossier, dans l'ordre du dossier : { marker, x, z, backX, backZ } (back = côté où reste la benne)
function ADTrailerSwap.places(folder)
    local out = {}
    for _, m in ipairs(ADGraphManager:getMapMarkersInGroup(folder)) do
        local wp = ADGraphManager:getWayPointById(m.id)
        if wp ~= nil then
            local p = { marker = m, x = wp.x, z = wp.z }
            local prev, reverse = arrival(wp)
            if prev ~= nil then
                local dx, dz = wp.x - prev.x, wp.z - prev.z
                local len = MathUtil.vector2Length(dx, dz)
                if len > 0.01 then
                    -- marche avant : la benne reste derrière, vers le point d'avant ; marche arrière : de l'autre côté
                    local sign = reverse and 1 or -1
                    p.backX, p.backZ = sign * dx / len, sign * dz / len
                end
            end
            out[#out + 1] = p
        end
    end
    return out
end

function ADTrailerSwap.inPlace(place, x, z)
    local dx, dz = x - place.x, z - place.z
    if place.backX == nil then
        return MathUtil.vector2Length(dx, dz) <= ADTrailerSwap.RADIUS
    end
    local along = dx * place.backX + dz * place.backZ
    local side = math.abs(dx * place.backZ - dz * place.backX)
    return along >= -ADTrailerSwap.LANE_FRONT and along <= ADTrailerSwap.LANE_BACK and side <= ADTrailerSwap.LANE_HALF
end

-- engins sur la place (sauf ce tracteur et ce qu'il tire)
function ADTrailerSwap.occupants(place, vehicle)
    local out = {}
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system == nil or system.vehicles == nil then
        return out
    end
    for _, v in pairs(system.vehicles) do
        local own = v == vehicle or (v.getRootVehicle ~= nil and v:getRootVehicle() == vehicle)
        if not own and v.components ~= nil then
            for _, c in ipairs(v.components) do
                local x, _, z = getWorldTranslation(c.node)
                if ADTrailerSwap.inPlace(place, x, z) then
                    out[#out + 1] = v
                    break
                end
            end
        end
    end
    return out
end

-- ------------------------------------------------------------------------------------------------------------
-- Bennes
-- ------------------------------------------------------------------------------------------------------------
function ADTrailerSwap.isEmpty(trailer)
    local ok, level, capacity = FarmPilotCall(AutoDrive.getObjectFillLevels, trailer)
    if not ok or type(level) ~= "number" then
        return false
    end
    capacity = type(capacity) == "number" and capacity or 0
    return level <= math.max(0.01, capacity * ADTrailerSwap.EMPTY_SHARE)
end

-- produits dans la benne : { [fillType] = true }
function ADTrailerSwap.loadedFillTypes(trailer)
    local types = {}
    local spec = trailer ~= nil and trailer.spec_fillUnit or nil
    if spec ~= nil and spec.fillUnits ~= nil then
        for _, unit in ipairs(spec.fillUnits) do
            if (unit.fillLevel or 0) > 0.01 and unit.fillType ~= nil and (FillType == nil or unit.fillType ~= FillType.UNKNOWN) then
                types[unit.fillType] = true
            end
        end
    end
    return types
end

-- la benne prend tous ces produits
function ADTrailerSwap.accepts(trailer, types)
    local spec = trailer.spec_fillUnit
    if trailer.getFillUnitSupportsFillType == nil or spec == nil or spec.fillUnits == nil then
        return true
    end
    for fillType, _ in pairs(types) do
        local any = false
        for i = 1, #spec.fillUnits do
            local ok, supported = FarmPilotCall(trailer.getFillUnitSupportsFillType, trailer, i, fillType)
            if ok and supported then
                any = true
                break
            end
        end
        if not any then
            return false
        end
    end
    return true
end

-- une remorque attelée derrière la benne (train de remorques)
local function towsTrailer(trailer)
    if trailer.getAttachedImplements == nil then
        return false
    end
    local ok, implements = FarmPilotCall(trailer.getAttachedImplements, trailer)
    if ok and type(implements) == "table" then
        for _, impl in ipairs(implements) do
            if impl.object ~= nil and ADTrailerHitch.isTrailerObject(impl.object) then
                return true
            end
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Places et bennes visées (plusieurs tracteurs sur le même dossier)
-- ------------------------------------------------------------------------------------------------------------
local function claimedByOther(vehicle, placeId, trailer)
    for v, c in pairs(ADTrailerSwap.claims) do
        if v ~= vehicle then
            local active = v.ad ~= nil and v.ad.stateModule ~= nil and v.ad.stateModule:isActive()
            if not active then
                ADTrailerSwap.claims[v] = nil
            elseif (placeId ~= nil and c.placeId == placeId) or (trailer ~= nil and c.trailer == trailer) then
                return true
            end
        end
    end
    return false
end

function ADTrailerSwap.claim(vehicle, placeId, trailer)
    ADTrailerSwap.claims[vehicle] = { placeId = placeId, trailer = trailer }
end

-- fin ou arrêt : plus rien de visé, plus d'échange en cours
function ADTrailerSwap.release(vehicle)
    ADTrailerSwap.claims[vehicle] = nil
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.modes ~= nil then
        for _, mode in pairs(vehicle.ad.modes) do
            if type(mode) == "table" then
                mode.fpSwap = nil
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Plan : place libre pour la pleine, benne vide sur une autre place
-- ------------------------------------------------------------------------------------------------------------
-- benne vide la plus proche de la place near (ou du tracteur), sur les places du dossier sauf near
function ADTrailerSwap.findEmpty(vehicle, places, types, near)
    local rx, rz
    if near ~= nil then
        rx, rz = near.x, near.z
    else
        local x, _, z = getWorldTranslation(vehicle.components[1].node)
        rx, rz = x, z
    end
    local best, bestPlace, bestDistance = nil, nil, math.huge
    for _, p in ipairs(places) do
        if p ~= near then
            for _, o in ipairs(p.occupants or ADTrailerSwap.occupants(p, vehicle)) do
                if ADTrailerHitch.isFetchableTrailer(vehicle, o) and ADTrailerSwap.isEmpty(o) and ADTrailerSwap.accepts(o, types)
                    and not claimedByOther(vehicle, nil, o) then
                    local d = MathUtil.vector2Length(p.x - rx, p.z - rz)
                    if d < bestDistance then
                        best, bestPlace, bestDistance = o, p, d
                    end
                end
            end
        end
    end
    return best, bestPlace
end

-- { folder, place, full, empty, emptyPlace, fillTypes } ; sinon nil, raison, dossier
function ADTrailerSwap.plan(vehicle)
    local folder = ADTrailerSwap.folder(vehicle)
    if folder == nil then
        return nil, "noFolder"
    end
    local attached = ADTrailerHitch.attachedTrailers(vehicle)
    local full = attached[1]
    if #attached ~= 1 or not ADTrailerHitch.isTrailerObject(full) or towsTrailer(full) then
        return nil, "notOne", folder
    end
    if ADTrailerSwap.isEmpty(full) then
        return nil, "notFull", folder -- reste au fond : déchargé normalement
    end
    local places = ADTrailerSwap.places(folder)
    local free
    for _, p in ipairs(places) do
        p.occupants = ADTrailerSwap.occupants(p, vehicle)
        if free == nil and #p.occupants == 0 and not claimedByOther(vehicle, p.marker.id, nil) then
            free = p
        end
    end
    if free == nil then
        return nil, "noFree", folder
    end
    local types = ADTrailerSwap.loadedFillTypes(full)
    local empty, emptyPlace = ADTrailerSwap.findEmpty(vehicle, places, types, free)
    if empty == nil then
        return nil, "noEmpty", folder
    end
    return { folder = folder, place = free, full = full, empty = empty, emptyPlace = emptyPlace, fillTypes = types }
end

-- pour la fenêtre : nombre de places, de places libres, de bennes vides (tous produits)
function ADTrailerSwap.folderInfo(vehicle, folder)
    local places = ADTrailerSwap.places(folder)
    local nFree, nEmpty = 0, 0
    for _, p in ipairs(places) do
        local occupants = ADTrailerSwap.occupants(p, vehicle)
        if #occupants == 0 then
            nFree = nFree + 1
        end
        for _, o in ipairs(occupants) do
            if ADTrailerHitch.isFetchableTrailer(vehicle, o) and ADTrailerSwap.isEmpty(o) then
                nEmpty = nEmpty + 1
            end
        end
    end
    return #places, nFree, nEmpty
end

-- ------------------------------------------------------------------------------------------------------------
-- Livraison : l'échange à la place du déchargement (crochet en tête de UnloadAtDestinationTask:setUp)
-- ------------------------------------------------------------------------------------------------------------
-- true = la tâche de déchargement s'arrête là, l'échange prend la suite
function ADTrailerSwap.onUnloadTask(task)
    local vehicle = task ~= nil and task.vehicle or nil
    if vehicle == nil or vehicle.ad == nil or not ADTrailerSwap.isSwapMode(vehicle) or ADTrailerSwap.folder(vehicle) == nil then
        return false
    end
    local mode = vehicle.ad.modes ~= nil and vehicle.ad.modes[vehicle.ad.stateModule:getMode()] or nil
    if mode == nil or mode.fpHitch ~= nil or mode.fpSwap ~= nil then
        return false
    end
    local ok, plan, err, folder = FarmPilotCall(ADTrailerSwap.plan, vehicle)
    if not ok then
        ADTrailerSwap.log("ERREUR échange de bennes : %s", tostring(plan))
        return false
    end
    if plan == nil then
        if ADTrailerSwap.FAIL_KEYS[err] ~= nil then
            ADTrailerSwap.log("%s : échange de bennes impossible (%s), livraison normale", nameOf(vehicle), tostring(err))
            message(vehicle, ADMessagesManager.messageTypes.WARN, 12000, ADTrailerSwap.FAIL_KEYS[err], tostring(folder))
        end
        return false
    end
    plan.stage = "pending"
    mode.fpSwap = plan
    ADTrailerSwap.claim(vehicle, plan.place.marker.id, plan.empty)
    ADTrailerSwap.log("%s : benne pleine « %s » vers la place « %s », puis la vide « %s » (place « %s »)", nameOf(vehicle), label(plan.full),
        tostring(plan.place.marker.name), label(plan.empty), tostring(plan.emptyPlace ~= nil and plan.emptyPlace.marker.name or "?"))
    message(vehicle, ADMessagesManager.messageTypes.INFO, 10000, "AD_swap_go", label(plan.full), tostring(plan.place.marker.name), label(plan.empty))
    -- fin de la tâche de déchargement : le mode passe la main à l'échange (handleFinishedTask)
    vehicle.ad.taskModule:setCurrentTaskFinished()
    return true
end

-- fin d'une tâche de l'échange (appelé par ADTrailerHitch.handleFinishedTask) ; false = le mode reprend la main
function ADTrailerSwap.handleFinishedTask(mode)
    local s = mode.fpSwap
    local vehicle = mode.vehicle
    local name = nameOf(vehicle)
    if s.stage ~= "pending" and vehicle.ad.taskModule:getActiveTask() ~= s.task then
        -- une autre tâche s'est terminée (recul pour se dégager…) : l'échange est abandonné
        ADTrailerSwap.log("%s : échange de bennes interrompu par une autre tâche", name)
        ADTrailerSwap.cancel(mode)
        return false
    end
    if s.stage == "pending" then
        s.stage = "place"
        s.task = DriveToDestinationTask:new(vehicle, s.place.marker.id)
        vehicle.ad.taskModule:addTask(s.task)
        return true
    end
    if s.stage == "place" then
        if vehicle.ad.isStoppingWithError then
            ADTrailerSwap.cancel(mode)
            vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
            return true
        end
        s.stage = "detach"
        s.task = ADDetachToolTask:new(vehicle, s.full)
        vehicle.ad.taskModule:addTask(s.task)
        return true
    end
    if s.stage == "detach" then
        local result = s.task ~= nil and s.task.result or "?"
        if result ~= "ok" then
            ADTrailerSwap.log("%s : benne pleine pas dételée (%s), arrêt", name, tostring(result))
            message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_swap_dropFailed")
            ADTrailerSwap.cancel(mode)
            vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
            return true
        end
        ADTrailerSwap.log("%s : benne pleine « %s » posée sur « %s »", name, label(s.full), tostring(s.place.marker.name))
        -- la benne vide prévue, si elle est toujours là ; sinon une autre sur les places
        local empty = s.empty
        if not (ADTrailerHitch.isFetchableTrailer(vehicle, empty) and ADTrailerSwap.isEmpty(empty)) then
            local places = ADTrailerSwap.places(s.folder)
            empty = ADTrailerSwap.findEmpty(vehicle, places, s.fillTypes, nil)
            if empty ~= nil then
                ADTrailerSwap.log("%s : la benne vide prévue n'est plus libre, prend « %s »", name, label(empty))
            end
        end
        if empty == nil then
            ADTrailerSwap.log("%s : plus de benne vide dans « %s », arrêt", name, tostring(s.folder))
            message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_swap_emptyGone", tostring(s.folder))
            ADTrailerSwap.cancel(mode)
            vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
            return true
        end
        s.empty = empty
        s.stage = "fetch"
        s.task = nil
        ADTrailerSwap.claim(vehicle, nil, empty)
        -- la vide devient la remorque de la ligne « Remorque » (reposée à sa place à la fin du travail)
        vehicle.ad.stateModule:setFpTrailer(empty)
        ADTrailerHitch.startFetch(mode, empty, nil, "swap")
        return true
    end
    ADTrailerSwap.cancel(mode)
    return false
end

-- benne vide attelée : le mode reprend comme à la fin d'un déchargement (retour au chargement, ou au champ)
function ADTrailerSwap.resume(mode, trailer)
    local vehicle = mode.vehicle
    ADTrailerSwap.cancel(mode)
    ADTrailerSwap.refreshUnits(mode)
    ADTrailerSwap.log("%s : benne vide « %s » attelée, le travail reprend", nameOf(vehicle), label(trailer))
    message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_swap_done", label(trailer))
    mode:handleFinishedTask()
end

function ADTrailerSwap.cancel(mode)
    if mode == nil then
        return
    end
    mode.fpSwap = nil
    if mode.vehicle ~= nil then
        ADTrailerSwap.release(mode.vehicle)
    end
end

-- remorques du mode relues (la benne a changé)
function ADTrailerSwap.refreshUnits(mode)
    local vehicle = mode.vehicle
    if mode.trailers ~= nil or mode.trailerCount ~= nil then
        mode.trailers, mode.trailerCount = AutoDrive.getAllUnits(vehicle)
    end
    if mode.tractorTrainLength ~= nil and AutoDrive.getTractorTrainLength ~= nil then
        mode.tractorTrainLength = AutoDrive.getTractorTrainLength(vehicle, true, false)
    end
    if AutoDrive.getAllDischargeableUnits ~= nil then
        FarmPilotCall(AutoDrive.getAllDischargeableUnits, vehicle, true)
    end
    vehicle.ad.trailerModule:reset()
end

-- ------------------------------------------------------------------------------------------------------------
-- HUD : roue dentée de la ligne « Remorque »
-- ------------------------------------------------------------------------------------------------------------
-- état de la roue dentée : "none" (cachée), "todo" (pas d'échange), "ok" (échange réglé) ; infobulle
function ADTrailerSwap.hudGear(vehicle)
    if not ADTrailerSwap.isSwapMode(vehicle) then
        return "none", "gui_ad_trailerSwap_tooltip"
    end
    return ADTrailerSwap.folder(vehicle) ~= nil and "ok" or "todo", "gui_ad_trailerSwap_tooltip"
end

-- clic sur la roue dentée : la fenêtre « Échange de bennes »
function ADTrailerSwap.onGear(vehicle, button, isDown, isUp)
    vehicle.ad.sToolTipInfo = ADTrailerSwap.folder(vehicle) or g_i18n:getText("gui_ad_trailerSwap_off")
    if button == 1 and isUp then
        if ADTrailerSwapGui ~= nil then
            ADTrailerSwapGui.open(vehicle)
        end
        return true
    end
    if button > 0 and button < 4 and isDown then
        return true, true
    end
    return false
end
