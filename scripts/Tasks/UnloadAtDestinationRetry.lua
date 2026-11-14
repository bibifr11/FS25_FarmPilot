-- ============================================================================================================
-- FarmPilot : UnloadAtDestinationRetry.lua
-- Point de livraison : la benne ne vide pas (13/11).
--
-- Avant : arrivé chargé au point de livraison, si le jeu ne voyait aucun endroit où vider, le véhicule
-- attendait sans fin, sans rien dire. Couper puis relancer l'aide le débloquait : la relance refait la liste
-- des bennes attelées, remet les minuteries de déchargement et le côté de bennage. Toute la file derrière
-- lui restait bloquée.
--
-- Règles :
--   - Arrêté au point de livraison, chargé, et rien ne coule depuis 15 s : FarmPilot fait lui-même ce que fait
--     « couper / relancer » (bennes coupées puis relues, minuteries, côté de bennage, liste des triggers).
--   - Au plus 3 relances par arrêt. Après la 3e, message « impossible de vider ici » (une fois) et il reste
--     sur place, comme avant.
--   - Chaque relance écrit une ligne dans le journal avec la raison vue avant la relance :
--     « [FarmPilot Déchargement] <véhicule> : relance 1/3 : <raison> ».
--   - Ne touche pas aux bennes AutoLoad ni aux plateaux à balles (ils ont leur propre attente).
--
-- Branché par une ligne : UnloadAtDestinationTask.lua (update, attente au point de livraison).
-- Chargé par register.lua après UnloadAtDestinationTask.lua.
-- ============================================================================================================

ADUnloadRetry = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADUnloadRetry.WAIT_MS = 15000      -- rien ne coule depuis ce temps : relance
ADUnloadRetry.MAX_TRIES = 3        -- relances par arrêt au point de livraison
ADUnloadRetry.FLOW_L = 0.5         -- litres : une baisse plus grande = ça coule
ADUnloadRetry.GAP_MS = 1000        -- plus appelé depuis ce temps : nouvel arrêt

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
function ADUnloadRetry.log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print("[FarmPilot Déchargement] " .. (ok and s or tostring(fmt)))
end

local function vehicleName(vehicle)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.getName ~= nil then
        return tostring(vehicle.ad.stateModule:getName())
    end
    return vehicle ~= nil and vehicle.getName ~= nil and tostring(vehicle:getName()) or "?"
end

local function trailerName(trailer)
    return trailer ~= nil and trailer.getName ~= nil and tostring(trailer:getName()) or "?"
end

local function fillOf(trailer)
    if trailer == nil or trailer.getFillUnits == nil then
        return 0
    end
    local total = 0
    for index, _ in pairs(trailer:getFillUnits() or {}) do
        total = total + (trailer:getFillUnitFillLevel(index) or 0)
    end
    return total
end

-- ------------------------------------------------------------------------------------------------------------
-- Raison : pourquoi la benne ne vide pas (vue avant la relance)
-- ------------------------------------------------------------------------------------------------------------
function ADUnloadRetry.reason(task)
    local vehicle = task.vehicle
    local trailers = task.trailers
    if trailers == nil or #trailers == 0 then
        return "aucune benne attelée vue"
    end
    local maxDist = AutoDrive.getMaxTriggerDistance(vehicle) or 0
    for _, trailer in pairs(trailers) do
        if fillOf(trailer) > 0.1 then
            local name = trailerName(trailer)
            if trailer.getCurrentDischargeNode == nil or trailer:getCurrentDischargeNode() == nil then
                return string.format("%s : pas de point de vidage", name)
            end
            local dist = AutoDrive.getDistanceToUnloadPosition(trailer)
            if dist ~= nil and dist > maxDist then
                return string.format("%s à %.1f m du point de livraison (au plus %.1f m)", name, dist, maxDist)
            end
            local state = trailer.getDischargeState ~= nil and trailer:getDischargeState() or nil
            if state ~= nil and Dischargeable ~= nil and state ~= Dischargeable.DISCHARGE_STATE_OFF and trailer.spec_pipe == nil then
                return string.format("%s restée en vidage (état %s) sans rien vider", name, tostring(state))
            end
            local side = trailer.spec_trailer ~= nil and trailer.spec_trailer.preferedTipSideIndex or nil
            if trailer.getCanDischargeToObject ~= nil and not trailer:getCanDischargeToObject(trailer:getCurrentDischargeNode()) then
                return string.format("%s : le jeu ne voit pas d'endroit où vider (côté de bennage %s)", name, tostring(side))
            end
            return string.format("%s : endroit vu (côté de bennage %s) mais vidage pas lancé", name, tostring(side))
        end
    end
    return "aucune benne chargée"
end

-- ------------------------------------------------------------------------------------------------------------
-- Relance : ce que fait « couper / relancer »
-- ------------------------------------------------------------------------------------------------------------
function ADUnloadRetry.restart(task)
    local vehicle = task.vehicle
    for _, trailer in pairs(task.trailers or {}) do
        if trailer.getDischargeState ~= nil and trailer.setDischargeState ~= nil and Dischargeable ~= nil
            and trailer.spec_pipe == nil and trailer:getDischargeState() ~= Dischargeable.DISCHARGE_STATE_OFF then
            trailer:setDischargeState(Dischargeable.DISCHARGE_STATE_OFF)
        end
        if trailer.ad ~= nil then
            trailer.ad.lastTipSideIndex = nil
        end
        if trailer.unloadDelayTimer ~= nil then
            trailer.unloadDelayTimer:timer(false)
        end
    end
    if ADTriggerManager ~= nil then
        ADTriggerManager.searchedForTriggers = false
    end
    vehicle.ad.trailerModule:reset()
    task.trailers, _ = AutoDrive.getAllUnits(vehicle)
end

-- ------------------------------------------------------------------------------------------------------------
-- Attente au point de livraison (appelée à chaque image tant qu'il attend)
-- ------------------------------------------------------------------------------------------------------------
function ADUnloadRetry.waiting(task, dt)
    local vehicle = task.vehicle
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.trailerModule == nil then
        return
    end
    if vehicle.ad.trailerModule:getHasAL() == true or task.baleTrailer ~= nil then
        return
    end
    local now = g_time or 0
    local fill = (task.trailers ~= nil and #task.trailers > 0) and AutoDrive.getAllFillLevels(task.trailers) or 0
    local r = task.fpUnloadRetry
    if r == nil or now - r.lastSeen > ADUnloadRetry.GAP_MS then
        r = { since = now, fill = fill, tries = 0, told = false }
        task.fpUnloadRetry = r
    end
    r.lastSeen = now
    if fill < r.fill - ADUnloadRetry.FLOW_L then
        -- ça coule : on repart de zéro
        r.fill = fill
        r.since = now
        return
    end
    if now - r.since < ADUnloadRetry.WAIT_MS then
        return
    end
    r.since = now
    if r.tries < ADUnloadRetry.MAX_TRIES then
        r.tries = r.tries + 1
        ADUnloadRetry.log("%s : relance %d/%d : %s", vehicleName(vehicle), r.tries, ADUnloadRetry.MAX_TRIES, ADUnloadRetry.reason(task))
        ADUnloadRetry.restart(task)
        r.fill = (task.trailers ~= nil and #task.trailers > 0) and AutoDrive.getAllFillLevels(task.trailers) or 0
    elseif not r.told then
        r.told = true
        ADUnloadRetry.log("%s : impossible de vider ici après %d relances : %s", vehicleName(vehicle), ADUnloadRetry.MAX_TRIES, ADUnloadRetry.reason(task))
        AutoDriveMessageEvent.sendMessageOrNotification(vehicle, ADMessagesManager.messageTypes.ERROR, "$l10n_AD_Driver_of; %s $l10n_fp_unloadImpossible;", 8000, vehicleName(vehicle))
    end
end
