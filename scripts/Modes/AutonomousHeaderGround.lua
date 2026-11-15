-- ============================================================================================================
-- FarmPilot : AutonomousHeaderGround.lua
-- Mode Autonome, moissonneuse ou ensileuse équipée seule (ébauche 11/11) : barre SANS remorque (coupe à maïs...).
--
-- Règle (11/11) :
-- - Barre posée par terre : la moissonneuse va la chercher elle-même et l'attelle (AutonomousHeader.lua,
--   startHeaderFetch). L'endroit où elle était est gardé en mémoire (point d'attelage et sens).
-- - Barre à reposer (changement de barre au champ suivant, ou fin de champ) : la moissonneuse la pose elle-même :
--   1. à la place de parking de la barre, si elle en a une ;
--   2. sinon là où elle l'a prise, si l'endroit est toujours libre ;
--   3. sinon comme avant : sur une remorque porte-barre vide amenée par un tracteur ;
--   4. sinon (changement de barre seulement) à côté de la barre à prendre, si celle-ci est par terre.
--   Ensuite : changement de barre = la suivante (elle va la chercher, ou un tracteur l'amène sur sa remorque) ;
--   fin de champ = la moissonneuse va à sa place de parking.
-- - Barre prise sur une remorque : rien ne change, elle y retourne (remorque appelée).
--   (15/11) Toujours, même quand elle a sa propre place de parking : la place de la barre et l'endroit où elle a été
--   prise (dropPlan) ne servent qu'aux barres prises sans remorque. Pas de remorque vide ou pas de tracteur : la
--   moissonneuse attend sur place (AutonomousHeader.lua : startFieldEndWait), jamais de route avec la barre.
-- - L'endroit gardé en mémoire ne survit pas à un rechargement de la partie (pas dans la sauvegarde) : après un
--   rechargement, la place de parking de la barre, sinon une remorque vide.
--
-- Branché par : Modes/AutonomousHeader.lua (startHeaderFetch : remember ; onStart : startSwap ; onFieldDone :
-- startFieldEnd). Enveloppe posée au chargement : ADFrontFlow.continueAfterDrop (barre posée pour un changement :
-- la suivante). La pose elle-même est celle des outils avant (Modes/AutonomousFront.lua, Tasks/FrontPlaceTask.lua).
-- Chargé par register.lua après AutonomousHeaderChoice.lua.
-- ============================================================================================================

ADHeaderGround = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderGround.FREE_MARGIN = 0.5    -- m libres autour de l'endroit où la barre était
ADHeaderGround.EXIT_MARGIN = 4      -- m de recul en plus de la moissonneuse et de la barre, après la pose

-- endroit où chaque barre a été prise par terre (clés faibles : barre vendue = oubliée)
ADHeaderGround.homes = setmetatable({}, { __mode = "k" })
-- (15/11) remorque porte-barre sur laquelle chaque barre a été prise (clés faibles)
ADHeaderGround.fromTrailer = setmetatable({}, { __mode = "k" })

-- ------------------------------------------------------------------------------------------------------------
-- Helpers
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

local function isGone(o)
    return o == nil or o.isDeleted or o.isDeleting
end

local function lengthOf(v, default)
    return (v ~= nil and v.size ~= nil and v.size.length) or default
end

-- point d'attelage de la barre (là où arrive l'attelage avant de la moissonneuse) et sens de la barre vers la
-- moissonneuse : { x, y, z, dirX, dirZ }, ou nil
function ADHeaderGround.hitchOf(combine, header)
    if header == nil or header.components == nil then
        return nil
    end
    -- le cadre d'attelage et son axe (du corps de la barre vers la moissonneuse), attelage avant pris ou non
    return ADAutonomousManager.frontHitch(combine, header, true)
end

-- ------------------------------------------------------------------------------------------------------------
-- Mémoire : où la barre a été prise
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderGround.remember(combine, header)
    if header == nil then
        return
    end
    local trailer = ADHeaderFlow.trailerOf(header)
    if trailer ~= nil then
        ADHeaderGround.homes[header] = nil -- prise sur une remorque : elle y retournera
        ADHeaderGround.fromTrailer[header] = trailer
        return
    end
    ADHeaderGround.fromTrailer[header] = nil
    local spot = ADHeaderGround.hitchOf(combine, header)
    ADHeaderGround.homes[header] = spot
    if spot ~= nil then
        log("%s : « %s » prise par terre en (%.0f, %.0f), elle y sera reposée", nameOf(combine), label(header), spot.x, spot.z)
    end
end

-- l'endroit est libre (rien d'autre que la moissonneuse et sa barre là où la barre se posera)
function ADHeaderGround.isFree(combine, header, spot)
    if ADFrontPlaceTask == nil or ADFrontPlaceTask.isFree == nil then
        return true
    end
    local len, width = ADHeaderFlow.headerBox(header)
    -- la barre s'étend de son point d'attelage vers l'avant, à l'opposé du sens noté
    local cx, cz = spot.x - spot.dirX * len / 2, spot.z - spot.dirZ * len / 2
    return ADFrontPlaceTask.isFree(combine, cx, cz, spot.dirX, spot.dirZ, len / 2 + ADHeaderGround.FREE_MARGIN, width / 2 + ADHeaderGround.FREE_MARGIN)
end

-- (15/11) la barre a été prise sur une remorque porte-barre (elle est encore dessus, elle a été notée au moment de
-- l'attelage, ou le travail en cours de la moissonneuse vient d'une remorque) : elle y retourne toujours
function ADHeaderGround.cameFromTrailer(combine, header)
    if ADHeaderFlow.trailerOf(header) ~= nil or ADHeaderGround.fromTrailer[header] ~= nil then
        return true
    end
    local job = combine ~= nil and combine.ad ~= nil and combine.ad.fpHeaderJob or nil
    return job ~= nil and job.header == header and job.trailer ~= nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Où poser la barre sans remorque : { marker } (sa place), { slot } (là où elle a été prise), ou nil
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderGround.dropPlan(combine, header)
    -- (15/11) barre prise sur une remorque : jamais à sa place ni par terre, toujours sur une remorque
    if ADHeaderGround.cameFromTrailer(combine, header) then
        return nil
    end
    local park = header.advd ~= nil and header.advd.parkDestination or -1
    local marker = park ~= nil and park >= 1 and ADGraphManager:getMapMarkerById(park) or nil
    if marker ~= nil then
        return { marker = marker }
    end
    local spot = ADHeaderGround.homes[header]
    if spot ~= nil then
        if ADHeaderGround.isFree(combine, header, spot) then
            return { slot = spot }
        end
        log("%s : l'endroit où « %s » a été prise n'est plus libre", nameOf(combine), label(header))
    end
    return nil
end

-- Autonome en marche, étapes remises à zéro : le déroulement, ou nil
local function begin(combine)
    local sm = combine.ad.stateModule
    combine.ad.onRouteToRefuel = false
    combine.ad.onRouteToRepair = false
    combine.ad.restartCP = false
    sm:setStartHelper(false)
    if not sm:isActive() then
        combine:startAutoDrive()
        if not sm:isActive() then
            return nil
        end
    end
    local mode = combine.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    mode:reset()
    return mode
end

-- la pose, comme un outil avant ; after : « headerNext » (changement de barre) ou nil (fin de champ)
local function startDrop(mode, header, plan, after)
    local v = mode.vehicle
    mode.parkThen = after
    if plan.marker ~= nil then
        log("%s : « %s » va à sa place « %s »", nameOf(v), label(header), tostring(plan.marker.name))
        ADFrontFlow.startDrop(mode, header, plan.marker, nil, nil)
        return
    end
    if plan.beside ~= nil then
        log("%s : « %s » posée à côté de « %s » (pas de place, pas de remorque vide)", nameOf(v), label(header), label(plan.beside))
        ADFrontFlow.startDrop(mode, header, nil, plan.beside, "front")
        return
    end
    local s = plan.slot
    mode.parkStage = "tool"
    mode.parkTool = header
    mode.parkSide = "front"
    mode.backOffDistance = lengthOf(v, 8) + ADHeaderFlow.headerBox(header) + ADHeaderGround.EXIT_MARGIN
    log("%s : « %s » reposée là où elle a été prise (%.0f, %.0f)", nameOf(v), label(header), s.x, s.z)
    AutonomousMode.message(v, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerGroundDrop", label(header))
    local slot = { x = s.x, y = s.y, z = s.z, dirX = s.dirX, dirZ = s.dirZ }
    mode.placeTask = ADFrontPlaceTask:newAt(v, header, slot, g_i18n:getText("AD_header_homePlace"))
    mode.driveToDestinationTask = mode.placeTask
    v.ad.taskModule:addTask(mode.placeTask)
end

-- ------------------------------------------------------------------------------------------------------------
-- Changement de barre (départ, AutonomousHeader.lua onStart) : true = la moissonneuse pose sa barre elle-même
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderGround.startSwap(mode, combine, header, other)
    local plan = ADHeaderGround.dropPlan(combine, header)
    if plan == nil then
        if ADHeaderFlow.findEmptyTrailer(combine, header) ~= nil then
            return false -- remorque vide : comme avant
        end
        if other == nil or isGone(other) or ADHeaderFlow.trailerOf(other) ~= nil then
            return false
        end
        plan = { beside = other }
    end
    if begin(combine) == nil then
        return false
    end
    ADHeaderFlow.endJob(combine.ad.fpHeaderJob)
    startDrop(mode, header, plan, "headerNext")
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin de champ (AutonomousHeader.lua onFieldDone) : true = barre posée par la moissonneuse, puis son parking
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderGround.startFieldEnd(combine, header)
    local plan = ADHeaderGround.dropPlan(combine, header)
    if plan == nil then
        return false
    end
    local mode = begin(combine)
    if mode == nil then
        return false
    end
    local old = combine.ad.fpHeaderJob
    ADHeaderFlow.endJob(old)
    local park = combine.advd ~= nil and combine.advd.parkDestination or -1
    local marker = park ~= nil and park >= 1 and ADGraphManager:getMapMarkerById(park) or nil
    -- après la pose (ADFrontFlow.continueAfterDrop) : la place de la moissonneuse, sinon arrêt sur place
    mode.fpQueue = marker ~= nil and { { kind = "park", marker = marker } } or {}
    log("%s : champ fini, pose « %s » elle-même, puis %s", nameOf(combine), label(header), marker ~= nil and ("sa place « " .. tostring(marker.name) .. " »") or "arrêt (pas de place de parking)")
    startDrop(mode, header, plan, nil)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppe : barre posée pour un changement de barre, la suivante (même attente que la pose sur remorque)
-- ------------------------------------------------------------------------------------------------------------
if ADFrontFlow ~= nil and ADFrontFlow.continueAfterDrop ~= nil then
    local baseContinueAfterDrop = ADFrontFlow.continueAfterDrop
    function ADFrontFlow.continueAfterDrop(mode)
        if mode.parkThen == "headerNext" then
            mode.parkThen = nil
            mode.backOffDistance = nil
            mode.parkStage = nil
            mode.parkTool = nil
            mode.parkSide = nil
            log("%s : barre posée, la suivante (elle va la chercher, ou attend un tracteur pour la remorque)", nameOf(mode.vehicle))
            ADHeaderFlow.startWait(mode, "waitTractor", function() return ADHeaderFlow.readyToDeliver(mode.vehicle) end)
            return
        end
        return baseContinueAfterDrop(mode)
    end
end
