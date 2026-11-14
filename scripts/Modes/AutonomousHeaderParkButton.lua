-- ============================================================================================================
-- FarmPilot : AutonomousHeaderParkButton.lua
-- Mode Autonome, moissonneuse équipée seule : bouton « Envoyer au parking » sur une moissonneuse qui a sa barre de
-- coupe attelée.
--
-- Règle (12/11) :
-- - Avant, elle partait au parking par la route avec sa barre : avec 10 m de coupe elle ne passe nulle part.
-- - Maintenant, comme en fin de champ : la barre est d'abord reposée sur sa remorque (un tracteur l'amène), ou à sa
--   place pour une barre sans remorque (AutonomousHeaderGround.lua), puis la moissonneuse va à son parking.
-- - Loin de son champ (plus de PARK_NEAR m du point du champ) : la remorque vient au point du réseau le plus
--   proche de la moissonneuse, pas au champ.
-- - Le tracteur roule encore pour ranger cette remorque vide (barre prise il y a peu) : il est rappelé
--   (AutonomousHeader.lua : startCollect).
-- - Une remorque vide existe mais aucun tracteur ne peut l'amener : la moissonneuse reste où elle est (message),
--   elle ne part pas avec sa barre. Appuyer de nouveau plus tard.
-- - Aucune remorque porte-barre vide et pas de place pour cette barre : bouton d'origine, comme avant.
-- - Barre déjà en train d'être reposée : le bouton ne change rien, le parking suit.
--
-- Branché par : Modes/AutonomousParkButton.lua (ADInputManager:input_parkVehicle). Chargé par register.lua après
-- AutonomousHeaderClear.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.PARK_NEAR = 150             -- m du point du champ : plus loin, la remorque vient près de la moissonneuse

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function label(o)
    return o ~= nil and ADAutonomousManager.toolLabel(o) or "?"
end

-- le tracteur est en train de ranger cette remorque (après la prise de la barre : AutonomousHeader.lua, parkTrailer
-- et goHome)
function ADHeaderFlow.isParkingTrailer(tractor, trailer)
    local mode = tractor.ad ~= nil and tractor.ad.modes ~= nil and tractor.ad.modes[AutoDrive.MODE_AUTONOMOUS] or nil
    if mode == nil then
        return false
    end
    return (mode.parkStage == "tool" and mode.parkTool == trailer) or mode.headerStage == "home"
end

-- point du champ (fieldId) à plus de PARK_NEAR m de la moissonneuse : le marqueur le plus proche d'elle ; sinon nil
function ADHeaderFlow.nearField(vehicle, fieldId)
    if ADHeaderFlow.nearestMarkerId == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local marker = fieldId ~= nil and ADGraphManager:getMapMarkerById(fieldId) or nil
    if marker ~= nil then
        local wp = marker.id ~= nil and ADGraphManager.getWayPointById ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
        local p = wp or marker
        if p.x ~= nil and p.z ~= nil and MathUtil.vector2Length(p.x - x, p.z - z) <= ADHeaderFlow.PARK_NEAR then
            return nil
        end
    end
    local near = ADHeaderFlow.nearestMarkerId(vehicle)
    if near ~= nil and near ~= fieldId then
        local m = ADGraphManager:getMapMarkerById(near)
        log("%s : loin de son champ, la remorque viendra à « %s »", nameOf(vehicle), tostring(m ~= nil and m.name or near))
    end
    return near
end

-- ------------------------------------------------------------------------------------------------------------
-- Bouton « Envoyer au parking »
-- ------------------------------------------------------------------------------------------------------------
-- true = traité ici (le bouton d'origine ne fait rien de plus)
function ADHeaderFlow.onParkButton(inputManager, vehicle, farmId)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or not ADHeaderFlow.isCombine(vehicle) then
        return false
    end
    local header = ADHeaderFlow.attachedHeader(vehicle)
    if header == nil then
        return false
    end
    local sm = vehicle.ad.stateModule
    local job = vehicle.ad.fpHeaderJob
    if sm:isActive() and job ~= nil and job.phase == "collect" and not job.cancelled then
        log("%s : bouton parking : la barre « %s » est déjà en train d'être reposée, le parking suit", nameOf(vehicle), label(header))
        return true
    end
    -- comme le bouton d'origine : Courseplay arrêté, FarmPilot arrêté s'il roulait
    AutoDrive:StopCP(vehicle)
    if sm:isActive() then
        inputManager:input_start_stop(vehicle, farmId)
    end
    if ADParkButton ~= nil and ADParkButton.rememberMode ~= nil then
        ADParkButton.rememberMode(vehicle)
    end
    sm:setMode(AutoDrive.MODE_AUTONOMOUS)
    log("%s : bouton parking : la barre « %s » d'abord sur sa remorque, puis le parking", nameOf(vehicle), label(header))
    local ok, started, why = FarmPilotCall(ADHeaderFlow.onFieldDone, vehicle, nil, true)
    if ok and started then
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerParkFirst")
        return true
    end
    if ADParkButton ~= nil and ADParkButton.restoreMode ~= nil then
        ADParkButton.restoreMode(vehicle)
    end
    if not ok then
        log("ERREUR bouton parking, barre à reposer : %s", tostring(started))
        return false
    end
    if why == "noTractor" then
        log("%s : bouton parking : aucun tracteur pour amener la remorque, la moissonneuse reste là avec sa barre", nameOf(vehicle))
        return true
    end
    log("%s : bouton parking : barre pas reposée (%s), parking comme avant", nameOf(vehicle), tostring(why))
    return false
end
