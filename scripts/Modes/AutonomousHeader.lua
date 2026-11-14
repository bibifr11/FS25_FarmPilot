-- ============================================================================================================
-- FarmPilot : AutonomousHeader.lua
-- Mode Autonome : moissonneuse équipée seule (ébauche 11/11). Un tracteur amène la remorque porte-barre au bord du
-- champ, la moissonneuse y prend sa barre de coupe et part récolter ; champ fini, les étapes inverses.
--
-- Règle (11/11) :
-- - Départ en Autonome d'une moissonneuse sans barre : la barre de la ferme qui s'attelle à elle, posée sur une
--   remorque porte-barre, la plus proche. Barre posée par terre (sans remorque) : la moissonneuse va l'atteler
--   directement, comme un outil avant (FetchFrontToolTask.lua).
-- - Le tracteur (au départ comme à la fin) : celui déjà attelé à la remorque, sinon le véhicule choisi par la roue
--   dentée de la ligne « Outil » de la moissonneuse (Gui/HeaderTractorGUI.lua), sinon le tracteur libre le plus
--   proche. Règle complète (masses, véhicule choisi, automoteurs) : AutonomousHeaderTractor.lua.
-- - Il va chercher la remorque si besoin (attelage arrière habituel), la conduit à la 1re destination de la
--   moissonneuse (son champ) et attend là ; arrêt avant le bout ou demi-tour si le côté du cadre de la barre est
--   encombré (AutonomousHeaderSpot.lua).
-- - (12/11) La moissonneuse part derrière la remorque et s'arrête avant le chemin du champ, où elle attend que la
--   remorque soit en place (AutonomousHeaderFollow.lua) ; elle y va alors par le réseau, attelle la barre en marche
--   avant, recule, puis départ normal du mode Autonome (parcours Courseplay de la largeur de la barre). Pas de
--   chemin jusqu'à la barre : le tracteur déplace la remorque (AutonomousHeaderFollow.lua, AutonomousHeaderSpot.lua).
--   (12/11) Bout de la route encombré côté barre : le tracteur dépasse l'entrée du champ et recule la remorque dedans,
--   en biais ; la moissonneuse arrive par le chemin et suit une courbe jusqu'au cadre (AutonomousHeaderBackIn.lua).
--   (12/11) Barre à plus de FETCH_DIRECT m et pas de route de l'attelage avant jusqu'à elle (remorque arrêtée sur
--   sa route, barre posée loin d'une route) : elle va d'abord par le réseau au point le plus proche de la barre et
--   lâche la route à DROP_HANDOVER m d'elle (ou arrêtée derrière la remorque), puis l'attelage habituel.
-- - Barre prise : le tracteur range la remorque vide à sa place, puis se gare (il est libre pendant la récolte).
--   Remorque sans place : il rentre à sa place avec elle.
-- - Champ fini (fin de travail habituelle : AutonomousMode.parkWithToolDrop) : la moissonneuse s'arrête et appelle
--   un tracteur (même choix) ; il va chercher la remorque, entre dans le champ et s'arrête à PLACE_DIST m
--   de la moissonneuse, la barre tournée vers elle (HeaderDropTask.lua : ADHeaderPlaceTask), et attend ; la
--   moissonneuse ne bouge pas tant que la remorque n'est pas à côté d'elle, jamais de route avec la barre pour
--   aller la poser (14/11, AutonomousHeaderCollect.lua). La moissonneuse se place au-dessus de la remorque, la
--   barre à sa position de transport (HeaderDropTask.lua), la dételle, la remorque la bloque (jeu) ; la
--   moissonneuse recule et va à sa place ; le tracteur pose la remorque à sa place puis se gare (fin de travail
--   habituelle).
-- - Place de la barre sur la remorque (lockPose) : AutonomousHeaderMount.lua.
-- - Barre sans remorque (coupe à maïs...) : la moissonneuse la repose elle-même, à sa place ou là où elle l'a prise,
--   avant toute remorque (AutonomousHeaderGround.lua).
-- - La barre est choisie seule (pas de ligne en plus dans le HUD). Le travail en cours n'est pas sauvegardé : partie
--   rechargée pendant la récolte = remorque retrouvée à la fin du champ (celle du départ si elle est vide, sinon la
--   remorque porte-barre vide la plus proche qui a une place pour cette barre).
--
-- Branché par : enveloppes posées au chargement de ce fichier sur AutonomousMode:start, :handleFinishedTask,
-- :monitorTasks, :reset, :startFetchAttach, AutonomousMode.parkWithToolDrop et ADAutonomousManager.hasWorkTool.
-- Tâches : Tasks/HeaderDropTask.lua (ADHeaderWaitTask, ADHeaderPlaceTask, ADHeaderDropTask, ADHeaderTurnTask).
-- Le reste, un fichier par sujet dans Modes/ : place de la barre sur la remorque AutonomousHeaderMount.lua ;
-- tracteur de la remorque et roue dentée AutonomousHeaderTractor.lua ; arrêt de la remorque au départ
-- AutonomousHeaderSpot.lua ; la moissonneuse suit la remorque AutonomousHeaderFollow.lua ; remorque reculée dans
-- l'entrée du champ AutonomousHeaderBackIn.lua (tâche Tasks/HeaderBackInTask.lua) ; fin de champ, la remorque
-- vient à la moissonneuse AutonomousHeaderCollect.lua ; barre choisie ou selon
-- la culture AutonomousHeaderChoice.lua ; barre sans remorque AutonomousHeaderGround.lua. Choix gardé : Modules/StateModuleHeader.lua. Chargé par register.lua après
-- SprayerManager.lua.
-- ============================================================================================================

ADHeaderFlow = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.WAIT_TIMEOUT = 1800000   -- ms (30 min) d'attente de l'autre machine au plus, puis arrêt
ADHeaderFlow.DROP_HANDOVER = 45       -- m entre la moissonneuse et le cadre de la barre à atteler : la route est lâchée
ADHeaderFlow.DROP_STUCK_TIME = 8000   -- ms arrêtée près de la barre sur la route (le tracteur gêne) : route lâchée
ADHeaderFlow.DROP_STUCK_RANGE = 70    -- m
ADHeaderFlow.BACK_MARGIN = 4          -- m de recul après la pose, en plus de la profondeur de la barre
ADHeaderFlow.FETCH_DIRECT = 60        -- m : barre plus près que ça de la moissonneuse : pas de route avant l'attelage

-- ------------------------------------------------------------------------------------------------------------
-- Petits outils
-- ------------------------------------------------------------------------------------------------------------
local function nameOf(vehicle)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
        return tostring(vehicle.ad.stateModule:getName())
    end
    return "?"
end

local function label(object)
    if object == nil then
        return "?"
    end
    return ADAutonomousManager.toolLabel(object)
end

function ADHeaderFlow.vehicleName(v)
    if v ~= nil and v.ad ~= nil and v.ad.stateModule ~= nil then
        return tostring(v.ad.stateModule:getName())
    end
    return label(v)
end

function ADHeaderFlow.log(fmt, ...)
    ADAutonomousManager.log("[Barre] " .. fmt, ...)
end
local log = ADHeaderFlow.log

local function farmOf(object)
    if object ~= nil and object.getOwnerFarmId ~= nil then
        local ok, id = FarmPilotCall(object.getOwnerFarmId, object)
        if ok then
            return id
        end
    end
    return nil
end

local function vehicles()
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    return system ~= nil and system.vehicles or {}
end

local function isGone(o)
    return o == nil or o.isDeleted or o.isDeleting
end

local function attacherOf(o)
    if o ~= nil and o.getAttacherVehicle ~= nil then
        return o:getAttacherVehicle()
    end
    return nil
end

local function rootOf(o)
    if o ~= nil and o.getRootVehicle ~= nil then
        return o:getRootVehicle() or o
    end
    return o
end

local function distance(a, b)
    local ax, _, az = getWorldTranslation(a.components[1].node)
    local bx, _, bz = getWorldTranslation(b.components[1].node)
    return MathUtil.vector2Length(ax - bx, az - bz)
end

local function stopHere(mode, key, ...)
    if key ~= nil then
        AutonomousMode.message(mode.vehicle, ADMessagesManager.messageTypes.ERROR, 15000, key, ...)
    end
    mode.headerStage = nil
    mode.headerTask = nil
    mode.driveToDestinationTask = nil
    mode.vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(mode.vehicle, ADTaskModule.DONT_PROPAGATE))
end
ADHeaderFlow.stopHere = stopHere

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse, barre, remorque porte-barre, tracteur
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderFlow.isCombine(v)
    return v ~= nil and v.spec_combine ~= nil and v.spec_attacherJoints ~= nil and v.ad ~= nil
end

function ADHeaderFlow.isHeader(o)
    return o ~= nil and o.spec_cutter ~= nil and o.spec_attachable ~= nil
end

-- la barre attelée à la moissonneuse, ou nil
function ADHeaderFlow.attachedHeader(combine)
    if combine == nil or combine.getAttachedImplements == nil then
        return nil
    end
    local ok, implements = FarmPilotCall(combine.getAttachedImplements, combine)
    if not ok or type(implements) ~= "table" then
        return nil
    end
    for _, impl in ipairs(implements) do
        if ADHeaderFlow.isHeader(impl.object) then
            return impl.object
        end
    end
    return nil
end

function ADHeaderFlow.isHeaderTrailer(v)
    local s = v ~= nil and v.spec_dynamicMountAttacher or nil
    if s == nil or v.spec_attachable == nil then
        return false
    end
    if s.lockPositions ~= nil and #s.lockPositions > 0 then
        return true
    end
    if g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil and v.configFileName ~= nil then
        local ok, item = FarmPilotCall(g_storeManager.getItemByXMLFilename, g_storeManager, v.configFileName)
        if ok and item ~= nil and type(item.categoryName) == "string" then
            return string.upper(item.categoryName) == "CUTTERTRAILERS"
        end
    end
    return false
end

local function holds(trailer, object)
    local s = trailer.spec_dynamicMountAttacher
    return (s.dynamicMountedObjects ~= nil and s.dynamicMountedObjects[object] ~= nil)
        or (s.pendingDynamicMountObjects ~= nil and s.pendingDynamicMountObjects[object] ~= nil)
end

-- la barre est bloquée sur la remorque (le jeu l'a verrouillée à sa place)
function ADHeaderFlow.isMounted(trailer, header)
    local s = trailer ~= nil and trailer.spec_dynamicMountAttacher or nil
    return s ~= nil and s.dynamicMountedObjects ~= nil and s.dynamicMountedObjects[header] ~= nil
end

-- la remorque porte-barre sur laquelle la barre est posée, ou nil
function ADHeaderFlow.trailerOf(header)
    if header == nil then
        return nil
    end
    for _, v in pairs(vehicles()) do
        if v ~= header and ADHeaderFlow.isHeaderTrailer(v) and holds(v, header) then
            return v
        end
    end
    return nil
end

function ADHeaderFlow.isEmptyTrailer(trailer)
    local s = trailer.spec_dynamicMountAttacher
    return next(s.dynamicMountedObjects or {}) == nil and next(s.pendingDynamicMountObjects or {}) == nil
end

-- barre de la ferme, dételée, qui s'attelle à l'avant de la moissonneuse : { header, trailer (ou nil), distance } ;
-- celle choisie dans la ligne « Barre » du HUD, sinon d'après la culture du champ (AutonomousHeaderChoice.lua :
-- rank). nil, raison (« chosenBusy », « noCrop ») quand aucune ne va. anyJoint : même si l'avant est pris (barre à
-- changer)
function ADHeaderFlow.findHeader(combine, anyJoint)
    local farm = farmOf(combine)
    local chosen, crop = nil, nil
    if ADHeaderFlow.headerChoice ~= nil then
        chosen, crop = ADHeaderFlow.headerChoice(combine)
    end
    local best, bestRank, refused = nil, nil, false
    for _, v in pairs(vehicles()) do
        if ADHeaderFlow.isHeader(v) and not isGone(v) and attacherOf(v) == nil
            and (farm == nil or farmOf(v) == farm)
            and (chosen == nil or v == chosen)
            and ADAutonomousManager.matchFrontJoints(combine, v, not anyJoint) ~= nil then
            local rank = 1
            if ADHeaderFlow.rank ~= nil then
                rank = ADHeaderFlow.rank(v, crop)
            end
            if rank == nil then
                refused = true -- ne coupe pas la culture du champ
            else
                local d = distance(combine, v)
                local trailer = ADHeaderFlow.trailerOf(v)
                -- d'abord celle qui coupe sûrement la culture, puis celles posées sur une remorque, puis la plus proche
                local better = best == nil or rank < bestRank
                    or (rank == bestRank and (((trailer ~= nil) ~= (best.trailer ~= nil) and trailer ~= nil)
                        or ((trailer ~= nil) == (best.trailer ~= nil) and d < best.distance)))
                if better then
                    best, bestRank = { header = v, trailer = trailer, distance = d }, rank
                end
            end
        end
    end
    if best == nil and chosen ~= nil then
        return nil, "chosenBusy"
    end
    if best == nil and refused then
        return nil, "noCrop"
    end
    return best
end

-- remorque porte-barre vide de la ferme pour reposer la barre : celle du travail en cours, sinon une qui a une
-- place pour cette barre (la plus proche), sinon celle d'où elle vient, sinon la plus proche
function ADHeaderFlow.findEmptyTrailer(combine, header, preferred)
    if preferred ~= nil and not isGone(preferred) and ADHeaderFlow.isEmptyTrailer(preferred) then
        return preferred
    end
    local farm = farmOf(combine)
    local best, bestRank, bestD = nil, math.huge, math.huge
    for _, v in pairs(vehicles()) do
        if ADHeaderFlow.isHeaderTrailer(v) and not isGone(v) and (farm == nil or farmOf(v) == farm) and ADHeaderFlow.isEmptyTrailer(v) then
            local pose = ADHeaderFlow.lockPose(v, header)
            if pose ~= nil then
                local d = distance(combine, v)
                local rank = pose.exact and 0 or (pose.remembered and 1 or 2)
                if rank < bestRank or (rank == bestRank and d < bestD) then
                    best, bestRank, bestD = v, rank, d
                end
            end
        end
    end
    return best
end

-- message quand le véhicule choisi n'était pas libre
local function noteChosen(combine, chosenBusy, tractor)
    if chosenBusy ~= nil then
        log("%s : « %s » (choisi) pas libre, appel de « %s »", nameOf(combine), ADHeaderFlow.vehicleName(chosenBusy), ADHeaderFlow.vehicleName(tractor))
        AutonomousMode.message(combine, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_headerChosenBusy",
            ADHeaderFlow.vehicleName(chosenBusy), ADHeaderFlow.vehicleName(tractor))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Travail en cours (une moissonneuse, un tracteur, une remorque, une barre), gardé sur les deux machines
-- ------------------------------------------------------------------------------------------------------------
-- job.phase : « deliver » (remorque amenée, barre prise), « harvest » (récolte), « collect » (barre reposée)
function ADHeaderFlow.newJob(combine, tractor, trailer, header, fieldId, phase)
    local job = { combine = combine, tractor = tractor, trailer = trailer, header = header, fieldId = fieldId,
        phase = phase, trailerReady = false, headerTaken = false, headerDropped = false, cancelled = false }
    combine.ad.fpHeaderJob = job
    tractor.ad.fpHeaderJob = job
    return job
end

function ADHeaderFlow.endJob(job)
    if job == nil then
        return
    end
    if job.combine ~= nil and job.combine.ad ~= nil and job.combine.ad.fpHeaderJob == job then
        job.combine.ad.fpHeaderJob = nil
    end
    if job.tractor ~= nil and job.tractor.ad ~= nil and job.tractor.ad.fpHeaderJob == job then
        job.tractor.ad.fpHeaderJob = nil
    end
end

-- le tracteur part en Autonome vers le champ de la moissonneuse (son départ : ADHeaderFlow.tractorStart)
function ADHeaderFlow.callTractor(job)
    local t = job.tractor
    local sm = t.ad.stateModule
    if sm:isActive() then
        return false
    end
    sm:setMode(AutoDrive.MODE_AUTONOMOUS)
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return false
    end
    sm:setFirstMarker(job.fieldId)
    local mode = t.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    mode:start()
    return sm:isActive()
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ (enveloppe de AutonomousMode:start) : true = départ pris en charge ici
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderFlow.onStart(mode)
    local v = mode.vehicle
    local job = v.ad.fpHeaderJob
    if job ~= nil and job.tractor == v then
        return ADHeaderFlow.tractorStart(mode, job)
    end
    if not ADHeaderFlow.isCombine(v) then
        return false
    end
    local header = ADHeaderFlow.attachedHeader(v)
    if header ~= nil then
        if job ~= nil and job.phase == "deliver" and job.header == header and not job.headerTaken then
            -- barre prise : le tracteur rentre (étape « wait » du tracteur), départ normal au champ
            job.headerTaken = true
            -- (12/11) le tracteur dégage d'abord avec la remorque vide, elle repart ensuite (AutonomousHeaderClear.lua)
            if ADHeaderFlow.startClearWait ~= nil and ADHeaderFlow.startClearWait(mode, job) then
                return true
            end
            log("%s : barre « %s » prise, départ normal au champ", nameOf(v), label(header))
            return false
        end
        -- barre attelée qui ne va pas (autre barre choisie, ne coupe pas la culture) : reposée, puis la bonne
        -- (AutonomousHeaderChoice.lua)
        if job == nil and ADHeaderFlow.swapFor ~= nil then
            local other = ADHeaderFlow.swapFor(v, header)
            if other ~= nil then
                log("%s : barre « %s » à changer pour « %s »", nameOf(v), label(header), label(other))
                AutonomousMode.message(v, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerSwap", label(other))
                -- barre sans remorque (coupe à maïs...) : posée par la moissonneuse (AutonomousHeaderGround.lua)
                if ADHeaderGround ~= nil and ADHeaderGround.startSwap(mode, v, header, other) then
                    return true
                end
                if ADHeaderFlow.startCollect(v, header, true) then
                    return true
                end
            end
        end
        return false
    end
    local found, why = ADHeaderFlow.findHeader(v)
    if found == nil then
        if why ~= nil then
            local key = why == "chosenBusy" and "AD_autonomous_headerChosenGone" or "AD_autonomous_headerNoCrop"
            local crop = ADHeaderFlow.cropName ~= nil and ADHeaderFlow.cropName(v) or "?"
            AutonomousMode.message(v, ADMessagesManager.messageTypes.ERROR, 12000, key, crop)
            log("%s : départ refusé, aucune barre (%s, culture %s)", nameOf(v), why, crop)
            if v.ad.stateModule:isActive() then
                v:stopAutoDrive()
            end
            return true
        end
        return false -- pas de barre : refus habituel (aucun outil de travail)
    end
    local sm = v.ad.stateModule
    if sm:getFirstMarker() == nil then
        return false
    end
    local tractor, why, chosenBusy = nil, nil, nil
    if found.trailer ~= nil then
        tractor, why, chosenBusy = ADHeaderFlow.tractorFor(found.trailer, v)
        if tractor == nil then
            local key = why == "busy" and "AD_autonomous_headerBusy" or "AD_autonomous_headerNoTractor"
            AutonomousMode.message(v, ADMessagesManager.messageTypes.ERROR, 12000, key, label(found.trailer))
            log("%s : départ refusé, remorque « %s » : %s", nameOf(v), label(found.trailer), tostring(why))
            if sm:isActive() then
                v:stopAutoDrive()
            end
            return true
        end
    end
    if not sm:isActive() then
        v:startAutoDrive()
        if not sm:isActive() then
            return true
        end
    end
    mode:reset()
    v.ad.fpAutonomousCourse = nil
    v.ad.fpAutonomousAI = nil
    if found.trailer == nil then
        log("%s : barre « %s » posée par terre, va l'atteler", nameOf(v), label(found.header))
        ADHeaderFlow.goToHeader(mode, found.header)
        return true
    end
    noteChosen(v, chosenBusy, tractor)
    local job = ADHeaderFlow.newJob(v, tractor, found.trailer, found.header, sm:getFirstMarkerId(), "deliver")
    log("%s : barre « %s » sur « %s », « %s » l'amène à « %s »", nameOf(v), label(found.header), label(found.trailer),
        nameOf(tractor), tostring(sm:getFirstMarker().name))
    if not ADHeaderFlow.callTractor(job) then
        ADHeaderFlow.endJob(job)
        log("%s : « %s » ne part pas", nameOf(v), nameOf(tractor))
        stopHere(mode, "AD_autonomous_headerNoTractor", label(found.trailer))
        return true
    end
    AutonomousMode.message(v, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerWaitTrailer", nameOf(tractor))
    ADHeaderFlow.startWaitLeave(mode, job) -- elle part derrière la remorque (AutonomousHeaderFollow.lua)
    return true
end

function ADHeaderFlow.startWait(mode, stage, isDone)
    mode.headerStage = stage
    mode.headerTask = ADHeaderWaitTask:new(mode.vehicle, isDone, ADHeaderFlow.WAIT_TIMEOUT)
    mode.vehicle.ad.taskModule:addTask(mode.headerTask)
end

-- point du réseau le plus proche de (x, z), et sa distance
local function nearestWayPoint(x, z)
    local best, bestD = nil, math.huge
    local all = ADGraphManager.getWayPoints ~= nil and ADGraphManager:getWayPoints() or nil
    for _, wp in pairs(all or {}) do
        if wp.x ~= nil and wp.id ~= nil then
            local d = MathUtil.vector2Length(wp.x - x, wp.z - z)
            if d < bestD then
                best, bestD = wp, d
            end
        end
    end
    return best, bestD
end

-- la moissonneuse rejoint la barre (sur sa remorque ou par terre) : tout près, ou quand l'attelage avant a sa propre
-- route jusqu'à elle, l'attelage habituel tout de suite ; sinon d'abord par le réseau jusqu'au point le plus proche
-- de la barre (étape « toHeader », route lâchée près d'elle : monitor)
function ADHeaderFlow.goToHeader(mode, header)
    local v = mode.vehicle
    -- (13/11) route vers le champ lâchée en chemin : celle-ci repart du point qu'elle suivait (AutonomousHeaderFollow.lua)
    if ADHeaderFlow.resumeStart ~= nil then ADHeaderFlow.resumeStart(mode) end
    local hitch = ADAutonomousManager.frontHitch(v, header, true)
    if hitch ~= nil then
        local x, _, z = getWorldTranslation(v.components[1].node)
        local d = MathUtil.vector2Length(hitch.x - x, hitch.z - z)
        local own = false
        if ADFrontFlow ~= nil and ADFrontFlow.fetchRoutePoint ~= nil then
            local ok, wp, _, _, nosePlace = FarmPilotCall(ADFrontFlow.fetchRoutePoint, v, header)
            own = ok and (wp ~= nil or nosePlace ~= nil)
        end
        local target = nil
        if d > ADHeaderFlow.FETCH_DIRECT and not own then
            target = nearestWayPoint(hitch.x, hitch.z)
        end
        -- (12/11) remorque reculée dans l'entrée du champ : par le réseau jusqu'au chemin, même de près ; la route
        -- est lâchée avant le virage vers le cadre (monitor, AutonomousHeaderBackIn.lua)
        local lanePoint = ADHeaderFlow.backInBefore ~= nil and ADHeaderFlow.backInBefore(v, v.ad.fpHeaderJob) or nil
        if lanePoint ~= nil then
            target = lanePoint
        end
        if target ~= nil and MathUtil.vector2Length(target.x - x, target.z - z) > (AutonomousMode.FETCH_NEAR_START or 3) then
            log("%s : barre « %s » à %.0f m, y va par le réseau (point %s)", nameOf(v), label(header), d, tostring(target.id))
            mode.headerStage = "toHeader"
            mode.headerGoal = header
            mode.dropStuck = 0
            mode.driveToDestinationTask = DriveToDestinationTask:new(v, target.id)
            if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_fetch", label(header)) end
            v.ad.taskModule:addTask(mode.driveToDestinationTask)
            return
        end
    end
    ADHeaderFlow.startHeaderFetch(mode, header)
end

-- la moissonneuse va atteler la barre : par le réseau, puis en face, marche avant (AutonomousMode:startFetch,
-- côté « front ») ; ensuite recul et départ normal (ADFrontFlow.afterFetch, puis AutonomousMode:start)
function ADHeaderFlow.startHeaderFetch(mode, header)
    mode.headerStage = nil
    mode.routeAhead = nil
    mode.headerFetch = header
    mode.fetchSide = "front"
    if ADHeaderGround ~= nil then ADHeaderGround.remember(mode.vehicle, header) end -- par terre : reposée là, voir AutonomousHeaderGround.lua
    local trailer = ADHeaderFlow.trailerOf(header)
    if trailer ~= nil then
        ADHeaderFlow.rememberMount(trailer, header) -- sur une remorque : reposée au même endroit (lockPose)
    end
    mode:startFetch(header)
end

-- départ du tracteur appelé : remorque attelée d'abord (attelage arrière habituel), puis le champ
function ADHeaderFlow.tractorStart(mode, job)
    local t = mode.vehicle
    local sm = t.ad.stateModule
    if (job.phase ~= "deliver" and job.phase ~= "collect") or job.cancelled or isGone(job.trailer) then
        ADHeaderFlow.endJob(job)
        return false
    end
    if not sm:isActive() then
        t:startAutoDrive()
        if not sm:isActive() then
            return true
        end
    end
    mode:reset()
    local attacher = attacherOf(job.trailer)
    if attacher == nil then
        log("%s : va atteler la remorque « %s »", nameOf(t), label(job.trailer))
        mode.fetchSide = nil
        mode:startFetch(job.trailer)
        return true
    end
    if rootOf(attacher) ~= t then
        job.cancelled = true
        log("%s : remorque « %s » attelée ailleurs, arrêt", nameOf(t), label(job.trailer))
        stopHere(mode, "AD_autonomous_headerBusy", label(job.trailer))
        return true
    end
    local marker = ADGraphManager:getMapMarkerById(job.fieldId)
    if marker == nil then
        job.cancelled = true
        stopHere(mode, nil)
        return true
    end
    log("%s : amène « %s » à « %s » (%s)", nameOf(t), label(job.trailer), tostring(marker.name), job.phase)
    AutonomousMode.message(t, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerTrailerGo", tostring(marker.name))
    mode.headerStage = "toField"
    job.trailerLeft = true -- la moissonneuse peut partir derrière (AutonomousHeaderFollow.lua)
    mode.driveToDestinationTask = DriveToDestinationTask:new(t, marker.id)
    if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_headerTrailer", marker.name) end
    t.ad.taskModule:addTask(mode.driveToDestinationTask)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Étapes (enveloppe de AutonomousMode:handleFinishedTask) : true = fin de tâche prise en charge ici
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderFlow.handleStage(mode)
    local stage = mode.headerStage
    if stage == nil then
        return false
    end
    local v = mode.vehicle
    local job = v.ad.fpHeaderJob
    local task = mode.headerTask
    mode.headerTask = nil
    local result = task ~= nil and task.result or nil
    if stage == "waitTractor" then
        -- changement de barre : un tracteur est libre, la bonne barre est amenée (départ habituel, onStart)
        mode.headerStage = nil
        if result ~= "ok" then
            log("%s : pas de tracteur libre pour la barre suivante (%s), arrêt", nameOf(v), tostring(result))
            stopHere(mode, "AD_autonomous_headerTimeout")
            return true
        end
        mode:reset()
        mode:start()
        return true
    end
    if stage == "toHeader" then
        -- au bout de la route vers la barre (ou route lâchée près d'elle) : l'attelage habituel
        local header = mode.headerGoal
        mode.headerStage = nil
        mode.headerGoal = nil
        mode.driveToDestinationTask = nil
        if v.ad.isStoppingWithError or isGone(header) then
            if job ~= nil then
                job.cancelled = true
            end
            log("%s : pas de route jusqu'à la barre, arrêt", nameOf(v))
            stopHere(mode, nil)
            return true
        end
        ADHeaderFlow.startHeaderFetch(mode, header)
        return true
    end
    if job == nil then
        stopHere(mode, nil)
        return true
    end
    if job.tractor == v then
        ADHeaderFlow.tractorStage(mode, job, stage, result)
    else
        ADHeaderFlow.combineStage(mode, job, stage, result)
    end
    return true
end

function ADHeaderFlow.tractorStage(mode, job, stage, result)
    local t = mode.vehicle
    if stage == "toField" then
        mode.driveToDestinationTask = nil
        if t.ad.isStoppingWithError then
            job.cancelled = true
            stopHere(mode, nil)
            return
        end
        if ADHeaderFlow.startBackIn ~= nil and ADHeaderFlow.startBackIn(mode, job) then
            return -- la remorque est reculée dans l'entrée du champ (AutonomousHeaderBackIn.lua)
        end
        if ADHeaderFlow.onArrival(mode, job) then
            return -- demi-tour (AutonomousHeaderSpot.lua)
        end
        if job.phase == "collect" then
            -- fin : il entre dans le champ jusqu'à la moissonneuse, elle ne vient pas à lui (AutonomousHeaderCollect.lua)
            ADHeaderFlow.collectEnter(mode, job)
            return
        end
        ADHeaderFlow.tractorWait(mode, job)
    elseif stage == "turn" then
        if t.ad.isStoppingWithError then
            job.cancelled = true
            stopHere(mode, nil)
            return
        end
        if result ~= "ok" then
            log("%s : déplacement pas fini (%s), attend là", nameOf(t), tostring(result))
        elseif ADHeaderFlow.onArrival(mode, job) then
            return -- pas dégagé ici non plus : endroit suivant (AutonomousHeaderSpot.lua)
        end
        ADHeaderFlow.tractorWait(mode, job)
    elseif stage == "backIn" then
        ADHeaderFlow.backInDone(mode, job, result) -- AutonomousHeaderBackIn.lua
    elseif stage == "intoField" then
        ADHeaderFlow.collectPlaced(mode, job, result) -- AutonomousHeaderCollect.lua
    elseif stage == "intoFieldRetry" then
        ADHeaderFlow.collectRetry(mode, job, result) -- AutonomousHeaderCollect.lua
    elseif stage == "wait" then
        job.trailerReady = false
        if job.collectMove and result == "ok" and not job.cancelled and not job.headerDropped then
            -- la moissonneuse n'a pas trouvé de chemin jusqu'à la remorque : la remorque va à un autre endroit
            ADHeaderFlow.collectMoveOn(mode, job) -- AutonomousHeaderCollect.lua
            return
        end
        if job.moveRequested and result == "ok" and not job.cancelled and not job.headerTaken then
            -- la moissonneuse n'a pas trouvé de chemin jusqu'à la barre : la remorque va ailleurs
            job.moveRequested = nil
            if ADHeaderFlow.moveOn(mode, job, "la moissonneuse n'arrive pas jusqu'à la barre", true) then
                return
            end
            job.cancelled = true
            log("%s : plus d'endroit où mettre la remorque, arrêt", nameOf(t))
            stopHere(mode, nil) -- le message est déjà affiché (moveOn)
            return
        end
        job.moveRequested = nil
        if result ~= "ok" or job.cancelled then
            job.cancelled = true
            log("%s : attente finie sans la moissonneuse (%s), arrêt", nameOf(t), tostring(result))
            stopHere(mode, "AD_autonomous_headerTimeout")
            return
        end
        if job.phase == "deliver" then
            -- barre prise : remorque vide rangée à sa place, puis le tracteur se gare (libre pendant la récolte)
            job.phase = "harvest"
            job.backIn = nil -- la remorque repart de l'entrée du champ (AutonomousHeaderBackIn.lua)
            t.ad.fpHeaderJob = nil
            ADHeaderFlow.parkTrailer(mode, job)
        else
            t.ad.fpHeaderJob = nil -- la moissonneuse garde le sien jusqu'à sa place
            ADHeaderFlow.parkTrailer(mode, job)
        end
    else
        -- « home » : garé avec la remorque vide, il attend l'appel de fin de champ
        mode.driveToDestinationTask = nil
        log("%s : garé avec la remorque vide pendant la récolte", nameOf(t))
        stopHere(mode, nil)
    end
end

function ADHeaderFlow.tractorWait(mode, job)
    local t = mode.vehicle
    job.trailerReady = true
    log("%s : remorque en place, attend la moissonneuse (%s)", nameOf(t), job.phase)
    if job.phase == "deliver" then
        ADHeaderFlow.startWait(mode, "wait", function() return job.headerTaken or job.cancelled or job.moveRequested end)
    else
        ADHeaderFlow.startWait(mode, "wait", function() return job.headerDropped or job.cancelled or job.collectMove end)
    end
end

-- remorque sans place de parking : le tracteur rentre à sa place avec elle
function ADHeaderFlow.goHome(mode, job)
    local t = mode.vehicle
    local park = t.advd ~= nil and t.advd.parkDestination or -1
    local marker = park ~= nil and park >= 1 and ADGraphManager:getMapMarkerById(park) or nil
    if marker == nil then
        log("%s : pas de place de parking, reste au champ", nameOf(t))
        stopHere(mode, nil)
        return
    end
    log("%s : rentre à « %s » avec la remorque", nameOf(t), tostring(marker.name))
    AutonomousMode.message(t, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerHome", tostring(marker.name))
    mode.headerStage = "home"
    t.ad.onRouteToPark = true
    mode.driveToDestinationTask = DriveToDestinationTask:new(t, marker.id)
    if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_park", marker.name) end
    t.ad.taskModule:addTask(mode.driveToDestinationTask)
end

-- barre reposée : la remorque va à sa place et y est dételée, puis le tracteur à la sienne (étapes habituelles de
-- AutonomousMode:handleParkStage, comme parkWithToolDrop, le tracteur roulant déjà)
function ADHeaderFlow.parkTrailer(mode, job)
    local t = mode.vehicle
    local trailer = job.trailer
    local toolPark = trailer.advd ~= nil and trailer.advd.parkDestination or -1
    local toolMarker = toolPark ~= nil and toolPark >= 1 and ADGraphManager:getMapMarkerById(toolPark) or nil
    local tractorPark = t.advd ~= nil and t.advd.parkDestination or -1
    local tractorMarker = tractorPark ~= nil and tractorPark >= 1 and tractorPark ~= toolPark and ADGraphManager:getMapMarkerById(tractorPark) or nil
    if toolMarker == nil or tractorMarker == nil then
        log("%s : remorque ou tracteur sans place de parking, ramené à la place du tracteur", nameOf(t))
        AutonomousMode.message(t, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_dropNoToolPark")
        ADHeaderFlow.goHome(mode, job)
        return
    end
    mode:reset()
    mode.parkStage = "tool"
    mode.parkTool = trailer
    mode.tractorParkId = tractorPark
    mode.driveToDestinationTask = DriveToDestinationTask:new(t, toolMarker.id)
    if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_toolPark", toolMarker.name) end
    t.ad.taskModule:addTask(mode.driveToDestinationTask)
    log("%s : la remorque va à sa place « %s », puis le tracteur à « %s »", nameOf(t), tostring(toolMarker.name), tostring(tractorMarker.name))
end

function ADHeaderFlow.combineStage(mode, job, stage, result)
    local v = mode.vehicle
    if ADHeaderFlow.followStage(mode, job, stage, result) then
        return -- elle suit la remorque (AutonomousHeaderFollow.lua)
    end
    if stage == "waitTrailer" then
        if result ~= "ok" or job.cancelled then
            job.cancelled = true
            if job.fetchNoPath then
                -- pas de chemin jusqu'à la barre et plus d'endroit où déplacer la remorque : le message de l'attelage
                log("%s : pas de chemin jusqu'à la barre, plus d'endroit où déplacer la remorque, arrêt", nameOf(v))
                stopHere(mode, "AD_autonomous_fetchNoPath", label(job.header))
                return
            end
            log("%s : la remorque n'est pas venue (%s), arrêt", nameOf(v), tostring(result))
            stopHere(mode, "AD_autonomous_headerTimeout")
            return
        end
        log("%s : remorque au champ, va atteler la barre", nameOf(v))
        ADHeaderFlow.goToHeader(mode, job.header)
    elseif stage == "waitCollect" then
        if result ~= "ok" or job.cancelled then
            job.cancelled = true
            log("%s : la remorque n'est pas revenue (%s), arrêt", nameOf(v), tostring(result))
            stopHere(mode, "AD_autonomous_headerTimeout")
            return
        end
        -- (14/11) la remorque est venue à côté d'elle (AutonomousHeaderCollect.lua) : elle y va tout droit, jamais par
        -- la route avec la barre
        log("%s : remorque à côté, va poser la barre", nameOf(v))
        ADHeaderFlow.startDrop(mode, job)
    elseif stage == "drop" then
        if result ~= "ok" then
            if ADHeaderFlow.collectDropFailed(mode, job, result) then
                return -- la remorque va à un autre endroit, nouvel essai (AutonomousHeaderCollect.lua)
            end
            job.cancelled = true
            log("%s : barre pas posée (%s), arrêt", nameOf(v), tostring(result))
            stopHere(mode, "AD_autonomous_headerDropFailed", tostring(result))
            return
        end
        local depth = ADHeaderFlow.headerBox(job.header)
        local back = depth + ADHeaderFlow.BACK_MARGIN
        log("%s : barre posée sur « %s », recul de %.0f m", nameOf(v), label(job.trailer), back)
        mode.headerStage = "backoff"
        mode.headerTask = ADFrontBackOffTask:new(v, back, false, nil)
        v.ad.taskModule:addTask(mode.headerTask)
    elseif stage == "backoff" then
        job.headerDropped = true -- le tracteur emmène la remorque
        if job.swap then
            -- changement de barre : la bonne barre est amenée dès qu'un tracteur est libre (souvent le même, une fois
            -- la remorque rangée)
            v.ad.fpHeaderJob = nil
            log("%s : barre reposée, attend un tracteur libre pour la suivante", nameOf(v))
            ADHeaderFlow.startWait(mode, "waitTractor", function() return ADHeaderFlow.readyToDeliver(v) end)
            return
        end
        local park = v.advd ~= nil and v.advd.parkDestination or -1
        local marker = park ~= nil and park >= 1 and ADGraphManager:getMapMarkerById(park) or nil
        if marker == nil then
            log("%s : pas de place de parking, reste ici", nameOf(v))
            stopHere(mode, nil)
            return
        end
        log("%s : va à sa place « %s »", nameOf(v), tostring(marker.name))
        mode.headerStage = "park"
        v.ad.onRouteToPark = true
        mode.driveToDestinationTask = DriveToDestinationTask:new(v, marker.id)
        if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_park", marker.name) end
        v.ad.taskModule:addTask(mode.driveToDestinationTask)
    else
        -- « park »
        mode.driveToDestinationTask = nil
        v.ad.fpHeaderJob = nil
        log("%s : garée", nameOf(v))
        if ADParkButton ~= nil and ADParkButton.onParked ~= nil then ADParkButton.onParked(v) end
        stopHere(mode, nil)
    end
end

function ADHeaderFlow.startDrop(mode, job)
    mode.headerStage = "drop"
    mode.headerTask = ADHeaderDropTask:new(mode.vehicle, job.header, job.trailer)
    mode.vehicle.ad.taskModule:addTask(mode.headerTask)
end

-- ------------------------------------------------------------------------------------------------------------
-- À chaque image (enveloppe de AutonomousMode:monitorTasks) : arrêt du tracteur au départ (côté barre dégagé),
-- route de la moissonneuse vers la barre (attelage) lâchée près d'elle
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderFlow.monitor(mode, dt)
    local v = mode.vehicle
    local job = v.ad.fpHeaderJob
    if mode.headerStage == "toField" and job ~= nil and job.tractor == v then
        ADHeaderFlow.checkRouteStop(mode, job) -- arrêt avant le bout, côté barre dégagé (AutonomousHeaderSpot.lua)
        return
    end
    if mode.headerStage == "follow" and job ~= nil and job.combine == v then
        ADHeaderFlow.followMonitor(mode, job, dt) -- derrière la remorque, arrêt avant le chemin (AutonomousHeaderFollow.lua)
        return
    end
    if mode.headerStage ~= "toHeader" then
        return
    end
    local task = mode.driveToDestinationTask
    if task == nil or v.ad.taskModule:getActiveTask() ~= task then
        return
    end
    -- but : le cadre de la barre à atteler
    local goal, what = mode.headerGoal ~= nil and ADAutonomousManager.frontHitch(v, mode.headerGoal, true) or nil, "barre"
    if goal == nil then
        return
    end
    local x, _, z = getWorldTranslation(v.components[1].node)
    local d = MathUtil.vector2Length(goal.x - x, goal.z - z)
    if job ~= nil and job.backIn ~= nil then
        -- remorque reculée dans l'entrée du champ : la route est lâchée sur le chemin, avant le virage vers le cadre
        if ADHeaderFlow.backInHandover(mode, job, task) then
            return
        end
    elseif d <= ADHeaderFlow.DROP_HANDOVER then
        log("%s : près de la %s (%.0f m), on lâche la route", nameOf(v), what, d)
        task:finished()
        return
    end
    if math.abs(v.lastSpeedReal or 0) < 0.0003 and d <= ADHeaderFlow.DROP_STUCK_RANGE then
        mode.dropStuck = (mode.dropStuck or 0) + dt
        if mode.dropStuck >= ADHeaderFlow.DROP_STUCK_TIME then
            log("%s : arrêtée près de la %s (%.0f m), on lâche la route", nameOf(v), what, d)
            task:finished()
        end
    else
        mode.dropStuck = 0
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Champ fini (enveloppe de AutonomousMode.parkWithToolDrop) : true = la moissonneuse appelle la remorque
-- ------------------------------------------------------------------------------------------------------------
-- near (bouton parking, AutonomousHeaderParkButton.lua) : la remorque vient près de la moissonneuse si elle est loin
-- de son champ ; 2e valeur quand rien n'est lancé : pourquoi (« noTrailer », « noTractor »...)
function ADHeaderFlow.onFieldDone(vehicle, forcedTool, near)
    if forcedTool ~= nil or not ADHeaderFlow.isCombine(vehicle) then
        return false
    end
    local sm = vehicle.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS or sm:isActive() then
        return false
    end
    local header = ADHeaderFlow.attachedHeader(vehicle)
    if header == nil then
        return false
    end
    -- barre sans remorque : posée par la moissonneuse (AutonomousHeaderGround.lua)
    if ADHeaderGround ~= nil and ADHeaderGround.startFieldEnd(vehicle, header) then
        return true
    end
    return ADHeaderFlow.startCollect(vehicle, header, false, near)
end

-- (14/11) champ fini, réglage « Se garer à la fin du travail » sur Non : une moissonneuse en mode Autonome qui a sa
-- barre la repose quand même (sur sa remorque, ou à sa place pour une barre sans remorque) et va se garer ;
-- true = lancé. Accroche dans ExternalInterface.lua (onCpFinished, onAIJobFinished).
function ADHeaderFlow.fieldEndAlways(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or not ADHeaderFlow.isCombine(vehicle) then
        return false
    end
    if vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_AUTONOMOUS or ADHeaderFlow.attachedHeader(vehicle) == nil then
        return false
    end
    local started = ADHeaderFlow.onFieldDone(vehicle, nil)
    if started then
        log("%s : champ fini, la barre est reposée même si « Se garer à la fin du travail » est sur Non", nameOf(vehicle))
    end
    return started == true
end

-- la moissonneuse appelle la remorque vide pour reposer sa barre ; swap : changement de barre (au champ suivant ou au
-- départ), la bonne barre est amenée ensuite ; true = lancé
function ADHeaderFlow.startCollect(vehicle, header, swap, near)
    local sm = vehicle.ad.stateModule
    local old = vehicle.ad.fpHeaderJob
    local trailer = ADHeaderFlow.findEmptyTrailer(vehicle, header, old ~= nil and old.trailer or nil)
    if trailer == nil then
        log("%s : champ fini, aucune remorque porte-barre vide, fin habituelle", nameOf(vehicle))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_headerNoTrailer")
        return false, "noTrailer"
    end
    if old ~= nil and old.tractor ~= nil and old.tractor.ad ~= nil and old.tractor.ad.fpHeaderJob == old then
        old.tractor.ad.fpHeaderJob = nil
    end
    local tractor, why, chosenBusy = ADHeaderFlow.tractorFor(trailer, vehicle)
    if tractor == nil then
        log("%s : champ fini, pas de tracteur pour « %s » (%s), fin habituelle", nameOf(vehicle), label(trailer), tostring(why))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_headerNoTractor", label(trailer))
        return false, "noTractor"
    end
    -- (12/11) le tracteur roule encore pour ranger cette remorque (barre prise il y a peu) : il est rappelé
    if tractor.ad.stateModule:isActive() and ADHeaderFlow.isParkingTrailer ~= nil and ADHeaderFlow.isParkingTrailer(tractor, trailer) then
        log("%s : « %s » roule encore avec la remorque vide, il est rappelé", nameOf(vehicle), nameOf(tractor))
        tractor:stopAutoDrive()
    end
    local field = (old ~= nil and old.fieldId) or (sm:getFirstMarker() ~= nil and sm:getFirstMarkerId()) or nil
    if swap then
        -- là où elle est : le champ qu'elle vient de finir (AutonomousHarvesterUnloaders.lua), sinon le marqueur le
        -- plus proche
        field = vehicle.ad.fpHeaderPrevField or (ADHeaderFlow.nearestMarkerId ~= nil and ADHeaderFlow.nearestMarkerId(vehicle)) or field
    end
    if near and ADHeaderFlow.nearField ~= nil then
        field = ADHeaderFlow.nearField(vehicle, field) or field
    end
    if field == nil then
        return false, "noField"
    end
    ADHeaderFlow.endJob(old)
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.restartCP = false
    sm:setStartHelper(false)
    vehicle:startAutoDrive()
    if not sm:isActive() then
        return false, "noStart"
    end
    local mode = vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    mode:reset()
    noteChosen(vehicle, chosenBusy, tractor)
    local job = ADHeaderFlow.newJob(vehicle, tractor, trailer, header, field, "collect")
    job.swap = swap
    log("%s : %s, appelle « %s » avec « %s »", nameOf(vehicle), swap and "changement de barre" or "champ fini", nameOf(tractor), label(trailer))
    if not ADHeaderFlow.callTractor(job) then
        ADHeaderFlow.endJob(job)
        log("%s : « %s » ne part pas, arrêt", nameOf(vehicle), nameOf(tractor))
        stopHere(mode, "AD_autonomous_headerNoTractor", label(trailer))
        return true
    end
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerCall", nameOf(tractor))
    ADHeaderFlow.startWait(mode, "waitCollect", function() return job.trailerReady or job.cancelled end)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes (posées au chargement)
-- ------------------------------------------------------------------------------------------------------------
-- une moissonneuse avec sa barre travaille elle-même
local baseHasWorkTool = ADAutonomousManager.hasWorkTool
function ADAutonomousManager.hasWorkTool(vehicle)
    if baseHasWorkTool(vehicle) then
        return true
    end
    return ADHeaderFlow.isCombine(vehicle) and ADHeaderFlow.attachedHeader(vehicle) ~= nil
end

local baseStart = AutonomousMode.start
function AutonomousMode:start(user)
    local ok, handled = FarmPilotCall(ADHeaderFlow.onStart, self)
    if not ok then
        log("ERREUR départ : %s", tostring(handled))
    elseif handled then
        return
    end
    return baseStart(self, user)
end

local baseHandle = AutonomousMode.handleFinishedTask
function AutonomousMode:handleFinishedTask()
    if self.headerStage ~= nil then
        local ok, err = FarmPilotCall(ADHeaderFlow.handleStage, self)
        if not ok then
            log("ERREUR étape %s : %s", tostring(self.headerStage), tostring(err))
            stopHere(self, nil)
        end
        return
    end
    if self.headerFetch ~= nil and self.fetchStage == "attach" then
        -- barre sur la remorque sans chemin jusqu'à elle : la remorque est déplacée (AutonomousHeaderFollow.lua)
        local ok, handled = FarmPilotCall(ADHeaderFlow.onFetchFailed, self)
        if not ok then
            log("ERREUR attelage de la barre : %s", tostring(handled))
        elseif handled then
            return
        end
    end
    return baseHandle(self)
end

local baseMonitor = AutonomousMode.monitorTasks
function AutonomousMode:monitorTasks(dt)
    baseMonitor(self, dt)
    if self.headerStage ~= nil then
        local ok, err = FarmPilotCall(ADHeaderFlow.monitor, self, dt)
        if not ok then
            log("ERREUR route vers la remorque : %s", tostring(err))
        end
    elseif self.headerFetch ~= nil then
        local ok, err = FarmPilotCall(ADHeaderFlow.fetchMonitor, self, dt) -- calcul du chemin borné (AutonomousHeaderFollow.lua)
        if not ok then
            log("ERREUR attelage de la barre : %s", tostring(err))
        end
    end
end

local baseReset = AutonomousMode.reset
function AutonomousMode:reset()
    baseReset(self)
    self.headerStage = nil
    self.headerTask = nil
    self.headerFetch = nil
    self.headerGoal = nil
    self.routeAhead = nil
    self.dropStuck = nil
    self.headerStopChecked = nil
    self.headerStopBefore = nil
    self.followCut = nil
    self.followHold = nil
    self.headerPlanTime = nil
    self.headerBackIn = nil
end

-- attelage de la barre posée sur la remorque : la remorque et son tracteur ne sont pas des obstacles
local baseFetchAttach = AutonomousMode.startFetchAttach
function AutonomousMode:startFetchAttach()
    baseFetchAttach(self)
    local header = self.headerFetch
    local task = self.fetchTask
    if header ~= nil and task ~= nil and task.tool == header then
        local trailer = ADHeaderFlow.trailerOf(header)
        local tractor = trailer ~= nil and rootOf(attacherOf(trailer)) or nil
        task.getExcludedVehiclesForCollisionCheck = function(t)
            if t.state ~= nil and t.state >= ADFetchToolTask.STATE_STOPPING then
                return { header, trailer, tractor }
            end
            return {}
        end
        -- (12/11) remorque reculée dans l'entrée du champ : une courbe calculée du chemin jusqu'au cadre, pas de
        -- recherche de chemin (AutonomousHeaderBackIn.lua)
        local job = self.vehicle.ad.fpHeaderJob
        if job ~= nil and job.backIn ~= nil and job.combine == self.vehicle and ADHeaderFlow.backInCurve ~= nil then
            task.presetPath = function(vehicle, hitch)
                return ADHeaderFlow.backInCurve(vehicle, job, hitch)
            end
        end
    end
end

local baseParkWithToolDrop = AutonomousMode.parkWithToolDrop
function AutonomousMode.parkWithToolDrop(vehicle, forcedTool)
    local ok, handled = FarmPilotCall(ADHeaderFlow.onFieldDone, vehicle, forcedTool)
    if not ok then
        log("ERREUR fin de champ : %s", tostring(handled))
    elseif handled then
        return true
    end
    return baseParkWithToolDrop(vehicle, forcedTool)
end
