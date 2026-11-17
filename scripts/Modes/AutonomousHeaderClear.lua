-- ============================================================================================================
-- FarmPilot : AutonomousHeaderClear.lua
-- Mode Autonome, moissonneuse équipée seule : la barre vient d'être prise sur sa remorque. Le tracteur dégage
-- d'abord avec la remorque vide, la moissonneuse ne repart qu'ensuite.
--
-- Règle (12/11) :
-- - Avant, les deux repartaient en même temps : avec la barre attelée la moissonneuse prend toute la largeur du
--   chemin, elle se retrouvait nez à nez avec le tracteur ou collée derrière lui.
-- - Barre prise : la moissonneuse attend sur place (« Attendre l'autre machine », message). Elle repart quand le
--   tracteur et la remorque sont à plus de CLEAR_DISTANCE m d'elle ET que la route qu'il lui reste à faire ne
--   croise plus et ne remonte plus la route de la moissonneuse vers son champ (les CLEAR_ROUTE premiers mètres, à
--   moins d'une demi-barre + CLEAR_MARGIN m). Même sens sur le même chemin : pas une gêne, elle suit derrière.
-- - Tracteur arrêté (garé, arrêté à la main), ou CLEAR_TIMEOUT ms passés : elle repart de toute façon.
-- - (17/11) Zone de CLEAR_DISTANCE = 50 m. Une fois partie, elle va à son champ même si la remorque a posé la coupe au
--   bord d'un champ voisin : jamais de rappel du tracteur pour reposer la coupe (AutonomousHeaderLeave.lua).
-- - Remorque reculée dans l'entrée du champ (AutonomousHeaderBackIn.lua) : après l'attelage la moissonneuse ne
--   ressort pas de 18 m en marche arrière (elle traverserait le chemin), elle recule juste de quoi laisser partir
--   la remorque (longueur de la barre + BACKIN_EXIT_MARGIN m).
--
-- Branché par : Modes/AutonomousHeader.lua (onStart : startClearWait ; combineStage « waitClear », enveloppé ici),
-- Modes/AutonomousFront.lua (afterFetch, enveloppé ici). Chargé par register.lua après AutonomousHeaderBackIn.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.CLEAR_WAIT = true           -- false : la moissonneuse repart tout de suite, comme avant
ADHeaderFlow.CLEAR_DISTANCE = 50         -- m entre la moissonneuse et le tracteur (ou sa remorque) avant qu'elle reparte (17/11 : 50 m, avant 30)
ADHeaderFlow.CLEAR_ROUTE = 200           -- m de la route de la moissonneuse vers son champ regardés
ADHeaderFlow.CLEAR_TRACTOR_ROUTE = 500   -- m de la route qui reste au tracteur regardés
ADHeaderFlow.CLEAR_MARGIN = 2.5          -- m en plus de la demi-largeur de la barre
ADHeaderFlow.CLEAR_COS = 0.3             -- routes de même sens au-dessus de ça (pas une gêne)
ADHeaderFlow.CLEAR_CHECK = 1000          -- ms entre deux contrôles
ADHeaderFlow.CLEAR_TIMEOUT = 120000      -- ms d'attente au plus
ADHeaderFlow.BACKIN_EXIT_MARGIN = 2      -- m de recul en plus de la longueur de la barre (remorque dans l'entrée du champ)

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

local function distance(a, b)
    local ax, _, az = getWorldTranslation(a.components[1].node)
    local bx, _, bz = getWorldTranslation(b.components[1].node)
    return MathUtil.vector2Length(ax - bx, az - bz)
end

-- points d'une route à partir de first, sur maxLength m : { x, z, dx, dz } (dx, dz : sens de la route à ce point)
local function routePoints(wayPoints, first, maxLength)
    local out = {}
    local n = wayPoints ~= nil and #wayPoints or 0
    local length = 0
    for i = math.max(1, first or 1), n do
        local p = wayPoints[i]
        local a, b = wayPoints[i], wayPoints[i + 1]
        if b == nil then
            a, b = wayPoints[i - 1], wayPoints[i]
        end
        local dx, dz = 0, 0
        if a ~= nil and b ~= nil then
            local l = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
            if l > 0.01 then
                dx, dz = (b.x - a.x) / l, (b.z - a.z) / l
            end
        end
        out[#out + 1] = { x = p.x, z = p.z, dx = dx, dz = dz }
        if wayPoints[i + 1] ~= nil then
            length = length + MathUtil.vector2Length(wayPoints[i + 1].x - p.x, wayPoints[i + 1].z - p.z)
            if length > maxLength then
                break
            end
        end
    end
    return out
end

-- ------------------------------------------------------------------------------------------------------------
-- Le tracteur a-t-il dégagé ?
-- ------------------------------------------------------------------------------------------------------------
-- route de la moissonneuse vers son champ (1re destination), calculée une fois
function ADHeaderFlow.clearCombineRoute(combine)
    local marker = combine.ad.stateModule:getFirstMarker()
    if marker == nil or marker.id == nil or ADGraphManager.getPathTo == nil then
        return {}
    end
    local route = ADGraphManager:getPathTo(combine, marker.id)
    return routePoints(route, 1, ADHeaderFlow.CLEAR_ROUTE)
end

-- true = la moissonneuse peut repartir ; sinon false, raison
function ADHeaderFlow.tractorCleared(job, state)
    local t, c = job.tractor, job.combine
    if t == nil or t.ad == nil or t.ad.stateModule == nil or not t.ad.stateModule:isActive() then
        return true, "tracteur arrêté"
    end
    local d = distance(t, c)
    if job.trailer ~= nil and job.trailer.components ~= nil and job.trailer.getAttacherVehicle ~= nil and job.trailer:getAttacherVehicle() ~= nil then
        d = math.min(d, distance(job.trailer, c))
    end
    if d < ADHeaderFlow.CLEAR_DISTANCE then
        return false, string.format("à %.0f m", d)
    end
    local dpm = t.ad.drivePathModule
    local wayPoints = dpm ~= nil and dpm.wayPoints or nil
    if wayPoints == nil or #wayPoints < 2 then
        return true, string.format("à %.0f m", d)
    end
    if state.route == nil then
        state.route = ADHeaderFlow.clearCombineRoute(c)
    end
    local current = dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1
    local ahead = routePoints(wayPoints, current, ADHeaderFlow.CLEAR_TRACTOR_ROUTE)
    local width = (job.header ~= nil and job.header.size ~= nil and job.header.size.width) or 6
    local reach = width / 2 + ADHeaderFlow.CLEAR_MARGIN
    for _, p in ipairs(ahead) do
        for _, q in ipairs(state.route) do
            if math.abs(p.x - q.x) <= reach and math.abs(p.z - q.z) <= reach and MathUtil.vector2Length(p.x - q.x, p.z - q.z) <= reach
                and p.dx * q.dx + p.dz * q.dz < ADHeaderFlow.CLEAR_COS then
                return false, "sa route croise encore celle de la moissonneuse"
            end
        end
    end
    return true, string.format("à %.0f m, routes séparées", d)
end

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse : attente, puis départ normal
-- ------------------------------------------------------------------------------------------------------------
-- barre prise (AutonomousHeader.lua : onStart) : true = elle attend ici que le tracteur ait dégagé
function ADHeaderFlow.startClearWait(mode, job)
    local v = mode.vehicle
    if not ADHeaderFlow.CLEAR_WAIT or job.tractor == nil or ADHeaderWaitTask == nil then
        return false
    end
    local state = { next = 0, route = nil, why = nil }
    job.clearWait = state
    mode.headerStage = "waitClear"
    mode.headerTask = ADHeaderWaitTask:new(v, function()
        if job.cancelled then
            return true
        end
        local now = g_time or 0
        if now < state.next then
            return false
        end
        state.next = now + ADHeaderFlow.CLEAR_CHECK
        local cleared, why = ADHeaderFlow.tractorCleared(job, state)
        state.why = why
        return cleared
    end, ADHeaderFlow.CLEAR_TIMEOUT)
    v.ad.taskModule:addTask(mode.headerTask)
    log("%s : barre « %s » prise, attend que « %s » ait dégagé avec la remorque vide", nameOf(v), label(job.header), nameOf(job.tractor))
    AutonomousMode.message(v, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerClearWait", nameOf(job.tractor))
    return true
end

local baseCombineStage = ADHeaderFlow.combineStage
function ADHeaderFlow.combineStage(mode, job, stage, result)
    if stage ~= "waitClear" then
        return baseCombineStage(mode, job, stage, result)
    end
    local v = mode.vehicle
    local state = job.clearWait
    job.clearWait = nil
    if result == "ok" then
        log("%s : « %s » a dégagé (%s), départ normal au champ", nameOf(v), nameOf(job.tractor), tostring(state ~= nil and state.why or "?"))
    else
        log("%s : « %s » n'a pas dégagé en %.0f s (%s), départ normal au champ quand même", nameOf(v), nameOf(job.tractor),
            ADHeaderFlow.CLEAR_TIMEOUT / 1000, tostring(state ~= nil and state.why or "?"))
    end
    mode.headerStage = nil
    mode.headerTask = nil
    -- (17/11) coupe prise sur la remorque amenée pour ce champ, même posée au bord d'un champ voisin : elle part à son
    -- champ, pas de rappel du tracteur pour la reposer (AutonomousHeaderLeave.lua : leavesField)
    job.deliveredGo = true
    mode:start()
end

-- ------------------------------------------------------------------------------------------------------------
-- Remorque reculée dans l'entrée du champ : petit recul après l'attelage
-- ------------------------------------------------------------------------------------------------------------
if ADFrontFlow ~= nil and ADFrontFlow.afterFetch ~= nil and ADFrontBackOffTask ~= nil then
    local baseAfterFetch = ADFrontFlow.afterFetch
    function ADFrontFlow.afterFetch(mode, tool)
        local v = mode.vehicle
        local job = v.ad.fpHeaderJob
        if job ~= nil and job.backIn ~= nil and job.combine == v and job.header == tool and tool ~= nil and mode.fpQueue == nil
            and mode.fetchSide == "front" then
            mode.fetchSide = nil
            local back = ((tool.size ~= nil and tool.size.length) or 3) + ADHeaderFlow.BACKIN_EXIT_MARGIN
            log("%s : « %s » attelée dans l'entrée du champ, recule de %.0f m pour laisser partir la remorque", nameOf(v), label(tool), back)
            mode.parkStage = "backoff"
            mode.parkThen = "restart"
            mode.backOffTask = ADFrontBackOffTask:new(v, back, false, tool)
            v.ad.taskModule:addTask(mode.backOffTask)
            return true
        end
        return baseAfterFetch(mode, tool)
    end
end
