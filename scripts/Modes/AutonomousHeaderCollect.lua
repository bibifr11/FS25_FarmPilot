-- ============================================================================================================
-- FarmPilot : AutonomousHeaderCollect.lua
-- Mode Autonome, moissonneuse équipée seule : fin de champ, la remorque porte-barre vient à la moissonneuse.
--
-- (14/11, champ 13) Le tracteur n'avait pas trouvé de chemin dans le champ jusqu'à la moissonneuse : il attendait
-- à l'entrée et la moissonneuse le rejoignait par le réseau, la barre attelée (176 m de route, arrêtée dans une
-- clôture).
--
-- Règle :
-- - En fin de champ la moissonneuse ne bouge pas tant que la remorque n'est pas à côté d'elle : jamais de route
--   avec la barre pour aller la poser.
-- - Le tracteur entre toujours dans le champ. Il essaie plusieurs endroits autour de la moissonneuse, la place de
--   la barre à PLACE_DIST m d'elle : d'abord entre elle et lui, puis derrière elle (la bande qu'elle vient de
--   couper), puis en tournant autour d'elle (COLLECT_ANGLES).
-- - Un endroit est gardé si la remorque et le tracteur y tiennent sur le même terrain qu'elle (champ) sans
--   culture debout, et si le côté du cadre est dégagé jusqu'à elle (isSideFree, AutonomousHeaderSpot.lua : culture,
--   eau, fossé, obstacle). Les endroits dégagés avec la marge habituelle passent d'abord ; ensuite ceux où seule
--   la largeur de la barre est dégagée (bande coupée au milieu d'une culture).
-- - Aucun endroit atteint : le tracteur reste où il est, le dit (message) et recommence toutes les
--   COLLECT_RETRY_TIME ; la moissonneuse attend (WAIT_TIMEOUT au plus).
-- - La moissonneuse ne trouve pas de chemin jusqu'à la remorque : l'endroit est écarté, la remorque va au suivant
--   (COLLECT_MOVES fois au plus).
--
-- Branché par : Modes/AutonomousHeader.lua (tractorStage : collectEnter, collectPlaced, collectRetry,
-- collectMoveOn ; combineStage : collectDropFailed). Tâche : Tasks/HeaderDropTask.lua (ADHeaderPlaceTask, liste
-- d'endroits). Chargé par register.lua après AutonomousHeaderSpot.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.COLLECT_ANGLES = { 40, -40, 80, -80, 120, -120, 160, -160 } -- ° autour d'elle, depuis la direction du tracteur
ADHeaderFlow.COLLECT_SAME = 15           -- ° : deux directions plus proches que ça = le même endroit
ADHeaderFlow.COLLECT_NARROW = -2.5       -- m en moins sur la marge du côté du cadre (largeur de la barre seulement)
ADHeaderFlow.COLLECT_STEP = 2            -- m entre deux points contrôlés
ADHeaderFlow.COLLECT_TRAIN_SIDE = 1.5    -- m de chaque côté de l'axe du tracteur et de la remorque
ADHeaderFlow.COLLECT_TRAIN_FRONT = 4     -- m devant le point suivi du tracteur
ADHeaderFlow.COLLECT_TRAIN_LENGTH = 20   -- m derrière lui quand la longueur de l'attelage n'est pas connue
ADHeaderFlow.COLLECT_REJECT = 15         -- m autour d'un endroit écarté
ADHeaderFlow.COLLECT_RETRY_TIME = 60000  -- ms entre deux essais quand aucun endroit n'est atteint
ADHeaderFlow.COLLECT_MOVES = 3           -- déplacements de la remorque au plus quand la moissonneuse n'arrive pas à elle
ADHeaderFlow.COLLECT_LOG_MAX = 3         -- essais ratés écrits un par un dans le journal (ensuite un sur dix)

-- ------------------------------------------------------------------------------------------------------------
-- Petits outils
-- ------------------------------------------------------------------------------------------------------------
local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function isGone(o)
    return o == nil or o.isDeleted == true or o.components == nil or o.components[1] == nil
end

local function yawOf(x, z)
    return math.atan2(x, z)
end

local function angleBetween(a, b)
    local d = (a - b) % (2 * math.pi)
    if d > math.pi then
        d = 2 * math.pi - d
    end
    return d
end

local function onField(x, z)
    return AutoDrive.checkIsOnField(x, 0, z) == true
end

local function hasCrop(x, z)
    return ADFieldPark ~= nil and ADFieldPark.hasGrowingCrop ~= nil and ADFieldPark.hasGrowingCrop(x, z) == true
end

-- point suivi du tracteur (AutoDrive amène ce point-là au bout du chemin)
local function refPoint(t)
    local node = t.getAISteeringNode ~= nil and t:getAISteeringNode() or nil
    if node == nil then
        node = t.components[1].node
    end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

-- ------------------------------------------------------------------------------------------------------------
-- Endroits autour de la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- le tracteur (cap dirX, dirZ) et la remorque derrière lui tiennent là : même terrain que la moissonneuse, pas de
-- culture debout ; ok, raison
local function trainFits(x, z, dirX, dirZ, length, mustBeField)
    local step = ADHeaderFlow.COLLECT_STEP
    local side = ADHeaderFlow.COLLECT_TRAIN_SIDE
    local along = ADHeaderFlow.COLLECT_TRAIN_FRONT
    while along >= -length do
        for _, across in ipairs({ -side, 0, side }) do
            -- GIANTS : à gauche du cap (dx, dz) = (dz, -dx)
            local px, pz = x + dirX * along + dirZ * across, z + dirZ * along - dirX * across
            if mustBeField and not onField(px, pz) then
                return false, "hors du champ"
            end
            if hasCrop(px, pz) then
                return false, "culture"
            end
        end
        along = along - step
    end
    return true, nil
end

-- le long de l'axe de pose, de la place de la barre vers la moissonneuse : toujours sur son terrain
local function axisOnField(pose, depth)
    local along = 0
    while along <= depth do
        if not onField(pose.x - pose.dirX * along, pose.z - pose.dirZ * along) then
            return false
        end
        along = along + ADHeaderFlow.COLLECT_STEP
    end
    return true
end

local function isRejected(rejected, x, z)
    for _, r in ipairs(rejected or {}) do
        if MathUtil.vector2Length(r.x - x, r.z - z) <= ADHeaderFlow.COLLECT_REJECT then
            return true
        end
    end
    return false
end

-- endroits où amener la remorque, dans l'ordre : { x, z (point suivi du tracteur), dirX, dirZ (son cap), pose (place
-- de la barre), narrow } ; 2e valeur : pourquoi les autres sont écartés (texte du journal)
function ADHeaderFlow.collectSpots(tractor, combine, header, trailer, rejected)
    local tx, tz = refPoint(tractor)
    local cNode = combine.components[1].node
    local cx, _, cz = getWorldTranslation(cNode)
    local fx, _, fz = localDirectionToWorld(cNode, 0, 0, 1)
    local behind = yawOf(-fx, -fz)
    local toTractor = MathUtil.vector2Length(tx - cx, tz - cz) > 1 and yawOf(tx - cx, tz - cz) or behind
    -- directions, de la moissonneuse vers la place de la barre : vers le tracteur, derrière elle, puis autour
    local yaws = { toTractor }
    local function add(yaw)
        for _, other in ipairs(yaws) do
            if angleBetween(yaw, other) < math.rad(ADHeaderFlow.COLLECT_SAME) then
                return
            end
        end
        yaws[#yaws + 1] = yaw
    end
    add(behind)
    for _, angle in ipairs(ADHeaderFlow.COLLECT_ANGLES) do
        add(toTractor + math.rad(angle))
    end

    local model = ADHeaderFlow.trainModel ~= nil and ADHeaderFlow.trainModel(tractor, trailer, header) or nil
    local length = model ~= nil and model.length or ADHeaderFlow.COLLECT_TRAIN_LENGTH
    local mustBeField = onField(cx, cz)
    local combineLength = (combine.size ~= nil and combine.size.length) or ADHeaderFlow.DEFAULT_COMBINE_LENGTH or 10
    local depth = combineLength + ADHeaderDropTask.APPROACH
    local wide, narrow, why = {}, {}, {}
    for _, yaw in ipairs(yaws) do
        local ux, uz = math.sin(yaw), math.cos(yaw)
        -- place de la barre, tournée dans le sens où la moissonneuse arrive (elle roule de chez elle vers la place)
        local px, pz = cx + ux * ADHeaderPlaceTask.PLACE_DIST, cz + uz * ADHeaderPlaceTask.PLACE_DIST
        local heading, sx, sz = yaw, px, pz
        if model ~= nil then
            -- cap du tracteur qui tourne la place dans ce sens, et son point suivi (attelage droit)
            heading = yaw - yawOf(model.ldx, model.ldz)
            local dx, dz = math.sin(heading), math.cos(heading)
            sx, sz = px - (dz * model.lx + dx * model.lz), pz - (-dx * model.lx + dz * model.lz)
        end
        local dirX, dirZ = math.sin(heading), math.cos(heading)
        local pose = { x = px, y = 0, z = pz, dirX = ux, dirZ = uz }
        local reason
        if isRejected(rejected, sx, sz) then
            reason = "déjà essayé"
        elseif mustBeField and not axisOnField(pose, depth) then
            reason = "hors du champ"
        else
            local fits, whyNot = trainFits(sx, sz, dirX, dirZ, length, mustBeField)
            if not fits then
                reason = whyNot
            end
        end
        if reason == nil then
            local spot = { x = sx, z = sz, dirX = dirX, dirZ = dirZ, pose = pose }
            local free, blocked = ADHeaderFlow.isSideFree(tractor, combine, header, pose)
            if free then
                wide[#wide + 1] = spot
            else
                local freeNarrow, blockedNarrow = ADHeaderFlow.isSideFree(tractor, combine, header, pose, ADHeaderFlow.COLLECT_NARROW)
                if freeNarrow then
                    spot.narrow = true
                    narrow[#narrow + 1] = spot
                else
                    reason = tostring(blockedNarrow or blocked)
                end
            end
        end
        if reason ~= nil then
            why[reason] = (why[reason] or 0) + 1
        end
    end
    for _, spot in ipairs(narrow) do
        wide[#wide + 1] = spot
    end
    local parts = {}
    for reason, count in pairs(why) do
        parts[#parts + 1] = string.format("%s %d", reason, count)
    end
    table.sort(parts)
    return wide, table.concat(parts, ", ")
end

-- la remorque est déjà bien placée près de la moissonneuse (même terrain, côté du cadre dégagé jusqu'à elle)
function ADHeaderFlow.collectIsPlaced(tractor, job)
    local combine = job.combine
    local tx, tz = refPoint(tractor)
    local cx, _, cz = getWorldTranslation(combine.components[1].node)
    if MathUtil.vector2Length(tx - cx, tz - cz) > ADHeaderPlaceTask.NEAR then
        return false
    end
    local rx, _, rz = getWorldTranslation(job.trailer.components[1].node)
    if onField(cx, cz) and not onField(rx, rz) then
        return false
    end
    local pose = ADHeaderFlow.lockPose(job.trailer, job.header)
    if pose == nil then
        return false
    end
    -- le cadre tourné vers elle : elle est derrière la place de la barre
    if (cx - pose.x) * pose.dirX + (cz - pose.z) * pose.dirZ > 0 then
        return false
    end
    return ADHeaderFlow.isSideFree(tractor, combine, job.header, pose, ADHeaderFlow.COLLECT_NARROW) == true
end

-- ------------------------------------------------------------------------------------------------------------
-- Tracteur : entrer dans le champ jusqu'à la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- aucun endroit atteint : il reste où il est et recommence plus tard ; la moissonneuse ne bouge pas
local function collectFailed(mode, job, why)
    local t = mode.vehicle
    job.collectFails = (job.collectFails or 0) + 1
    if job.collectFails <= ADHeaderFlow.COLLECT_LOG_MAX or job.collectFails % 10 == 0 then
        log("%s : pas de chemin dans le champ jusqu'à la moissonneuse (%s), elle ne bouge pas, nouvel essai dans %d s (essai %d)",
            nameOf(t), tostring(why), ADHeaderFlow.COLLECT_RETRY_TIME / 1000, job.collectFails)
    end
    if job.collectFails == 1 then
        AutonomousMode.message(t, ADMessagesManager.messageTypes.WARN, 15000, "AD_autonomous_headerNoWay")
    end
    mode.headerStage = "intoFieldRetry"
    mode.headerTask = ADHeaderWaitTask:new(t, function() return job.cancelled or job.headerDropped end, ADHeaderFlow.COLLECT_RETRY_TIME)
    t.ad.taskModule:addTask(mode.headerTask)
end

-- arrivé au champ (ou nouvel essai, ou endroit écarté : moved) : la remorque va près de la moissonneuse
function ADHeaderFlow.collectEnter(mode, job, moved)
    local t = mode.vehicle
    if isGone(job.combine) or isGone(job.trailer) or job.cancelled then
        job.cancelled = true
        log("%s : plus de moissonneuse à rejoindre, arrêt", nameOf(t))
        ADHeaderFlow.stopHere(mode, nil)
        return
    end
    if not moved and ADHeaderFlow.collectIsPlaced(t, job) then
        log("%s : déjà à côté de la moissonneuse, côté de la barre dégagé", nameOf(t))
        job.collectFails = nil
        ADHeaderFlow.tractorWait(mode, job)
        return
    end
    local spots, why = ADHeaderFlow.collectSpots(t, job.combine, job.header, job.trailer, job.collectRejected)
    if #spots == 0 then
        collectFailed(mode, job, why ~= "" and ("aucun endroit dégagé autour d'elle : " .. why) or "aucun endroit dégagé autour d'elle")
        return
    end
    -- essais répétés toutes les minutes : le journal n'est pas rempli (seuls les premiers sont écrits un par un)
    local quiet = (job.collectFails or 0) >= ADHeaderFlow.COLLECT_LOG_MAX
    if why ~= "" and not quiet then
        log("%s : %d endroit(s) possible(s) autour de la moissonneuse (écartés : %s)", nameOf(t), #spots, why)
    end
    mode.headerStage = "intoField"
    mode.headerTask = ADHeaderPlaceTask:new(t, job.combine, job.header, job.trailer, spots)
    mode.headerTask.quiet = quiet
    t.ad.taskModule:addTask(mode.headerTask)
end

-- fin du trajet dans le champ
function ADHeaderFlow.collectPlaced(mode, job, result)
    if result == "ok" then
        job.collectFails = nil
        ADHeaderFlow.tractorWait(mode, job)
        return
    end
    if result == "gone" or job.cancelled then
        job.cancelled = true
        log("%s : plus de moissonneuse à rejoindre (%s), arrêt", nameOf(mode.vehicle), tostring(result))
        ADHeaderFlow.stopHere(mode, nil)
        return
    end
    collectFailed(mode, job, result)
end

-- fin de la pause entre deux essais
function ADHeaderFlow.collectRetry(mode, job, result)
    if result == "timeout" and not job.cancelled and not job.headerDropped then
        ADHeaderFlow.collectEnter(mode, job)
        return
    end
    job.cancelled = true
    log("%s : la moissonneuse n'attend plus la remorque, arrêt", nameOf(mode.vehicle))
    ADHeaderFlow.stopHere(mode, nil)
end

-- ------------------------------------------------------------------------------------------------------------
-- La moissonneuse n'arrive pas jusqu'à la remorque : endroit suivant
-- ------------------------------------------------------------------------------------------------------------
-- (moissonneuse) pose ratée faute de chemin : true = la remorque est envoyée ailleurs, elle attend là
function ADHeaderFlow.collectDropFailed(mode, job, result)
    if result ~= "noPath" or job.cancelled or job.phase ~= "collect" or (job.collectMoves or 0) >= ADHeaderFlow.COLLECT_MOVES then
        return false
    end
    job.collectMoves = (job.collectMoves or 0) + 1
    job.trailerReady = false
    job.collectMove = true
    log("%s : pas de chemin jusqu'à la remorque, elle va à un autre endroit (%d/%d)", nameOf(mode.vehicle), job.collectMoves, ADHeaderFlow.COLLECT_MOVES)
    ADHeaderFlow.startWait(mode, "waitCollect", function() return job.trailerReady or job.cancelled end)
    return true
end

-- (tracteur) l'endroit où il est ne va pas : écarté, il va au suivant
function ADHeaderFlow.collectMoveOn(mode, job)
    local t = mode.vehicle
    job.collectMove = nil
    local x, z = refPoint(t)
    job.collectRejected = job.collectRejected or {}
    table.insert(job.collectRejected, { x = x, z = z })
    log("%s : la moissonneuse n'arrive pas jusqu'à la remorque ici, endroit suivant", nameOf(t))
    ADHeaderFlow.collectEnter(mode, job, true)
end
