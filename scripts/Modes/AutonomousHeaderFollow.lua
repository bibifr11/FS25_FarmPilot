-- ============================================================================================================
-- FarmPilot : AutonomousHeaderFollow.lua
-- Mode Autonome, moissonneuse équipée seule (12/11) : la moissonneuse suit la remorque porte-barre au lieu de
-- l'attendre à sa place, et ne cherche pas sans fin un chemin vers une barre qu'elle ne peut pas atteindre.
--
-- Règle (12/11) :
-- - Départ : la moissonneuse attend à sa place que le tracteur ait attelé la remorque et soit parti devant elle
--   (plus près du champ qu'elle, par la route, de FOLLOW_GAP m au moins). Elle part alors vers le champ, derrière.
-- - Elle s'arrête avant le chemin du champ : au dernier point de route principale avant la fin de sa route (routes
--   secondaires, chemins de terre et routes d'accès = le chemin), à FOLLOW_MIN m du bout au moins. Route sans
--   chemin : FOLLOW_STOP m avant le bout. Elle y attend que la remorque soit en place, puis va atteler sa barre.
-- - En route, à moins de FOLLOW_CLOSE m de la remorque pas encore en place : elle s'arrête là et repart quand la
--   remorque s'est éloignée (FOLLOW_CLOSE + FOLLOW_RESUME m) ou est en place.
-- - (15/11) « Parti devant elle » = aussi physiquement : la route qui reste au tracteur ne passe plus à moins de
--   PASS_RANGE m d'elle, et la remorque est à PASS_RANGE m d'elle au moins. Avant : seule la longueur de route
--   comptait ; le tracteur venu de la place de la remorque (G_Coupe) était « devant » en distance mais sa route
--   passait par la cour où elle attendait, elle partait la première et lui bouchait la route (essai du 15/11 18:25,
--   Lexion 6900 et MF 7S.210 qui s'attendaient l'un l'autre).
-- - (15/11) Arrêt à FOLLOW_CLOSE m de la remorque seulement si la remorque est DEVANT elle (près de la route qui lui
--   reste à suivre). Remorque derrière elle : elle ne s'arrête pas, elle continue jusqu'à son arrêt avant le chemin.
-- - (15/11) Elle est sur la route même du tracteur et il est arrêté derrière elle depuis BLOCK_TIME ms : elle part la
--   première pour lui ouvrir la route (puis elle ne s'arrête pas devant la remorque, voir plus haut).
-- - (15/11) Relancée à la main pendant l'amenée (le tracteur roule encore pour ce travail) : elle reprend ce travail
--   (rejoin) au lieu d'en créer un autre ; avant : « aucun tracteur libre pour déplacer la remorque porte-barre ».
-- - Remorque en place pendant qu'elle roule : elle va atteler tout de suite.
-- - (13/11) Route lâchée en chemin (remorque trop près, remorque en place) ou coupée à son arrêt : les points qui
--   lui restaient à suivre sont gardés. La route calculée ensuite (suite vers le champ, route vers la barre) repart
--   du premier de ces points devant elle, à RESUME_RANGE m au plus (resumeStart, ADGraphManager.setJoinedWayPoint).
--   Sans ça AutoDrive prend le point le mieux placé devant son nez : dans une courbe à un embranchement c'est
--   celui de l'autre branche, et la nouvelle route fait le tour par là (essai du 13/11 21:44 : 502 m de détour,
--   arrivée sur la barre par le côté du rabatteur).
-- - Calcul du chemin vers la barre posée sur la remorque : PLAN_TIMEOUT ms au plus, tous essais sans chemin
--   confondus (PLAN_TIMEOUT_BLOCKED si le côté de la barre est déjà connu encombré). Pas de chemin : elle demande au
--   tracteur de déplacer la remorque (AutonomousHeaderSpot.lua, moveOn) et attend ; plus d'endroit ou déjà
--   SPOT_MOVES déplacements : arrêt des deux, message « pas de chemin jusqu'à l'avant de l'outil ».
--
-- Branché par : Modes/AutonomousHeader.lua (onStart : startWaitLeave ; combineStage : followStage ; monitor :
-- followMonitor et fetchMonitor ; AutonomousMode:handleFinishedTask : onFetchFailed ; tractorStart : trailerLeft ;
-- tractorWait et tractorStage « wait » : moveRequested). Chargé par register.lua après AutonomousHeaderSpot.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.FOLLOW_GAP = 60               -- m d'avance de la remorque, par la route, pour que la moissonneuse parte
ADHeaderFlow.FOLLOW_CLOSE = 30             -- m : plus près de la remorque que ça, la moissonneuse s'arrête
ADHeaderFlow.FOLLOW_RESUME = 40            -- m de plus pour repartir après un arrêt derrière la remorque
ADHeaderFlow.FOLLOW_MIN = 40               -- m du bout de la route au moins, pour l'arrêt avant le chemin
ADHeaderFlow.FOLLOW_STOP = 80              -- m avant le bout quand la route n'a pas de chemin
ADHeaderFlow.FOLLOW_CHECK = 1000           -- ms entre deux contrôles de l'avance du tracteur
ADHeaderFlow.BLOCK_RANGE = 5               -- m : la route du tracteur passe sur elle (15/11)
ADHeaderFlow.BLOCK_TIME = 10000            -- ms d'arrêt du tracteur derrière elle avant qu'elle parte la première (15/11)
ADHeaderFlow.PASS_RANGE = 15               -- m : la route du tracteur passe plus près d'elle = il n'est pas encore passé devant (15/11)
ADHeaderFlow.PLAN_TIMEOUT = 45000          -- ms de calcul du chemin vers la barre au plus
ADHeaderFlow.PLAN_TIMEOUT_BLOCKED = 15000  -- ... quand le côté de la barre est déjà connu encombré
ADHeaderFlow.RESUME_RANGE = 30             -- m au plus entre la moissonneuse et le point de sa route lâchée d'où la suivante repart
ADHeaderFlow.RESUME_AHEAD = 0.5            -- m devant son nez au moins, pour ce point
ADHeaderFlow.RESUME_KEEP = 40              -- points gardés au plus

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

local function gapTo(a, b)
    local ax, _, az = getWorldTranslation(a.components[1].node)
    local bx, _, bz = getWorldTranslation(b.components[1].node)
    return MathUtil.vector2Length(ax - bx, az - bz)
end

local function lengthFrom(wayPoints, from)
    local l = 0
    for k = math.max(from or 1, 1) + 1, #wayPoints do
        l = l + MathUtil.vector2Length(wayPoints[k].x - wayPoints[k - 1].x, wayPoints[k].z - wayPoints[k - 1].z)
    end
    return l
end

-- distance de (x, z) à la route wayPoints à partir du point from (segments), math.huge sans route
local function routeDistance(wayPoints, from, x, z)
    local best = math.huge
    if wayPoints == nil then
        return best
    end
    from = math.max(from or 1, 1)
    for k = from, #wayPoints do
        local a = wayPoints[k]
        local b = wayPoints[k + 1]
        local d
        if b == nil then
            d = MathUtil.vector2Length(x - a.x, z - a.z)
        else
            local dx, dz = b.x - a.x, b.z - a.z
            local l2 = dx * dx + dz * dz
            local u = l2 > 0 and math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / l2)) or 0
            d = MathUtil.vector2Length(x - (a.x + u * dx), z - (a.z + u * dz))
        end
        if d < best then
            best = d
        end
    end
    return best
end
ADHeaderFlow.routeDistance = routeDistance

-- route secondaire, chemin de terre ou route d'accès : le « chemin » qui mène au champ
local function isLane(point)
    local wp = point
    if point ~= nil and point.flags == nil and point.id ~= nil then
        wp = ADGraphManager:getWayPointById(point.id)
    end
    local flags = wp ~= nil and wp.flags or 0
    local mask = (AutoDrive.FLAG_SUBPRIO or 0) + (AutoDrive.FLAG_DIRT_ROAD or 0) + (AutoDrive.FLAG_ACCESS_ROAD or 0)
    return bit32.band(flags, mask) > 0
end

local function waitTrailer(mode, job)
    ADHeaderFlow.startWait(mode, "waitTrailer", function() return job.trailerReady or job.cancelled end)
end

-- ------------------------------------------------------------------------------------------------------------
-- Route lâchée en chemin : la suivante repart du point qu'elle suivait
-- ------------------------------------------------------------------------------------------------------------
-- garde les points du réseau qui restaient à suivre (wayPoints à partir de from)
function ADHeaderFlow.noteRouteAhead(mode, wayPoints, from)
    local ids = {}
    if wayPoints ~= nil then
        for k = math.max(from or 1, 1), #wayPoints do
            local id = wayPoints[k].id
            if id ~= nil and id > 0 and ids[#ids] ~= id then
                ids[#ids + 1] = id
                if #ids >= ADHeaderFlow.RESUME_KEEP then
                    break
                end
            end
        end
    end
    mode.routeAhead = #ids > 0 and ids or nil
end

-- avant de calculer une nouvelle route : elle repartira du premier point gardé qui est devant le nez de la
-- moissonneuse ; rend ce point (nil : rien de gardé, ou elle n'est plus sur cette route)
function ADHeaderFlow.resumeStart(mode)
    local v = mode.vehicle
    local ids = mode.routeAhead
    if ids == nil or ADGraphManager.setJoinedWayPoint == nil then
        return nil
    end
    local node = v.components[1].node
    local x, _, z = getWorldTranslation(node)
    local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
    local nx, nz = x, z -- le nez
    if v.ad.frontNode ~= nil then
        nx, _, nz = getWorldTranslation(v.ad.frontNode)
    end
    for _, id in ipairs(ids) do
        local p = ADGraphManager:getWayPointById(id)
        if p ~= nil then
            local d = MathUtil.vector2Length(p.x - x, p.z - z)
            if (p.x - nx) * fx + (p.z - nz) * fz >= ADHeaderFlow.RESUME_AHEAD then
                if d > ADHeaderFlow.RESUME_RANGE then
                    break -- le premier point devant elle est trop loin : elle n'est plus sur cette route
                end
                ADGraphManager.setJoinedWayPoint(v, id, ADHeaderFlow.RESUME_RANGE + 1, "celui de la route qu'elle suivait")
                return id
            end
        end
    end
    mode.routeAhead = nil
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Où la moissonneuse s'arrête sur sa route vers le champ
-- ------------------------------------------------------------------------------------------------------------
-- index du point où s'arrêter (nil : aucun), m avant le bout, true si c'est avant le chemin du champ
function ADHeaderFlow.followStopIndex(wayPoints, current)
    local n = #wayPoints
    local first = math.max(current or 1, 1)
    local fromEnd = 0
    local laneSeen = false
    local fallback, fallbackEnd = nil, 0
    local i = n
    while i > first do
        local lane = isLane(wayPoints[i])
        if lane then
            laneSeen = true
        end
        if fallback == nil and fromEnd >= ADHeaderFlow.FOLLOW_STOP then
            fallback, fallbackEnd = i, fromEnd
        end
        -- route principale, et le point d'avant aussi (un point isolé sans type au milieu du chemin ne compte pas)
        if laneSeen and not lane and fromEnd >= ADHeaderFlow.FOLLOW_MIN and not isLane(wayPoints[i - 1]) then
            return i, fromEnd, true
        end
        fromEnd = fromEnd + MathUtil.vector2Length(wayPoints[i].x - wayPoints[i - 1].x, wayPoints[i].z - wayPoints[i - 1].z)
        i = i - 1
    end
    if fallback ~= nil then
        return fallback, fallbackEnd, false
    end
    return nil, fromEnd, false
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ : le tracteur est parti avec la remorque, devant la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderFlow.tractorAhead(job)
    -- (17/11) elle est entre le tracteur et la sortie du champ : elle part la première, il attend derrière
    -- (AutonomousHeaderFieldLead.lua)
    if job.leadFirst and not job.trailerLeft then
        return true
    end
    if not job.trailerLeft then
        return false
    end
    local t, v = job.tractor, job.combine
    local tm = t.ad.modes ~= nil and t.ad.modes[AutoDrive.MODE_AUTONOMOUS] or nil
    if tm == nil or tm.headerStage ~= "toField" then
        return true -- au bout de sa route
    end
    if g_time ~= nil then
        if job.aheadChecked ~= nil and g_time - job.aheadChecked < ADHeaderFlow.FOLLOW_CHECK then
            return false
        end
        job.aheadChecked = g_time
    end
    local dpm = t.ad.drivePathModule
    local wayPoints = dpm ~= nil and dpm.wayPoints or nil
    local task = tm.driveToDestinationTask
    if wayPoints == nil or #wayPoints < 2 or task == nil or t.ad.taskModule:getActiveTask() ~= task or task.routeIsPartial
        or (task.state ~= nil and task.state ~= DriveToDestinationTask.STATE_DRIVING) then
        return false
    end
    local current = dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1
    -- (15/11) pas encore passé devant elle : sa route passe encore près d'elle, ou la remorque est encore à côté
    local cx0, _, cz0 = getWorldTranslation(v.components[1].node)
    local near = routeDistance(wayPoints, math.max(current - 1, 1), cx0, cz0)
    local trailerGap = job.trailer ~= nil and job.trailer.components ~= nil and gapTo(v, job.trailer) or math.huge
    if near < ADHeaderFlow.PASS_RANGE or trailerGap < ADHeaderFlow.PASS_RANGE then
        -- (15/11) elle est SUR la route du tracteur et il est arrêté derrière elle depuis BLOCK_TIME ms : elle part la
        -- première pour lui ouvrir la route (elle ne s'arrêtera pas devant la remorque : followMonitor)
        local now = g_time or 0
        if near < ADHeaderFlow.BLOCK_RANGE and math.abs(t.lastSpeedReal or 0) < 0.0003 and gapTo(v, t) < ADHeaderFlow.FOLLOW_CLOSE then
            job.blockedSince = job.blockedSince or now
            if now - job.blockedSince >= ADHeaderFlow.BLOCK_TIME then
                job.blockedSince = nil
                job.leadFirst = true
                log("%s : « %s » est arrêté derrière elle depuis %d s, sa route passe par elle (à %.0f m) : elle part la première pour lui ouvrir la route",
                    nameOf(v), nameOf(t), ADHeaderFlow.BLOCK_TIME / 1000, near)
                return true
            end
        else
            job.blockedSince = nil
        end
        if not job.passLogged then
            job.passLogged = true
            log("%s : la route de « %s » passe encore par ici (à %.0f m, remorque à %.0f m) : attend qu'il soit passé devant", nameOf(v),
                nameOf(t), near, trailerGap)
        end
        return false
    end
    if job.passLogged then
        job.passLogged = nil
        log("%s : « %s » est passé devant (sa route à %.0f m, remorque à %.0f m)", nameOf(v), nameOf(t), near, trailerGap)
    end
    local remaining = lengthFrom(wayPoints, current)
    if job.combineRoute == nil then
        local marker = ADGraphManager:getMapMarkerById(job.fieldId)
        local route = marker ~= nil and ADGraphManager:getPathTo(v, marker.id) or nil
        job.combineRoute = (route ~= nil and #route >= 2) and lengthFrom(route, 1) or -1
    end
    if job.combineRoute < 0 then
        -- pas de route connue pour la moissonneuse : à vol d'oiseau jusqu'au bout de la route du tracteur
        local last = wayPoints[#wayPoints]
        local tx, _, tz = getWorldTranslation(t.components[1].node)
        local cx, _, cz = getWorldTranslation(v.components[1].node)
        return MathUtil.vector2Length(tx - last.x, tz - last.z) + ADHeaderFlow.FOLLOW_GAP <= MathUtil.vector2Length(cx - last.x, cz - last.z)
    end
    return remaining + ADHeaderFlow.FOLLOW_GAP <= job.combineRoute
end

-- (15/11) moissonneuse relancée pendant l'amenée, son tracteur roule encore pour ce travail : true = reprise
function ADHeaderFlow.rejoin(mode, job)
    local v, t = mode.vehicle, job.tractor
    if t == nil or t.isDeleted or t.ad == nil or t.ad.fpHeaderJob ~= job or not t.ad.stateModule:isActive()
        or t.ad.stateModule:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return false
    end
    if job.header == nil or ADHeaderFlow.trailerOf(job.header) ~= job.trailer then
        return false
    end
    local sm = v.ad.stateModule
    if not sm:isActive() then
        v:startAutoDrive()
        if not sm:isActive() then
            return true
        end
    end
    mode:reset()
    v.ad.fpAutonomousCourse = nil
    v.ad.fpAutonomousAI = nil
    if job.trailerReady then
        log("%s : relancée, « %s » a déjà mis la remorque en place : va atteler « %s »", nameOf(v), nameOf(t), label(job.header))
        ADHeaderFlow.goToHeader(mode, job.header)
    else
        log("%s : relancée pendant l'amenée, « %s » roule encore avec la barre : elle reprend le même travail", nameOf(v), nameOf(t))
        ADHeaderFlow.startWaitLeave(mode, job)
    end
    return true
end

-- la moissonneuse attend à sa place que la remorque soit partie devant elle
function ADHeaderFlow.startWaitLeave(mode, job)
    ADHeaderFlow.startWait(mode, "waitLeave", function()
        return job.cancelled or job.trailerReady or ADHeaderFlow.tractorAhead(job)
    end)
end

-- ------------------------------------------------------------------------------------------------------------
-- La moissonneuse roule derrière la remorque, vers le champ
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderFlow.startFollow(mode, job)
    local v = mode.vehicle
    local marker = ADGraphManager:getMapMarkerById(job.fieldId)
    if marker == nil then
        waitTrailer(mode, job) -- pas de route du champ : elle attend où elle est
        return
    end
    log("%s : la remorque est partie, la suit vers « %s »", nameOf(v), tostring(marker.name))
    ADHeaderFlow.resumeStart(mode) -- après un arrêt derrière la remorque : la route repart du point qu'elle suivait
    mode.headerStage = "follow"
    mode.followBehindLogged = nil
    mode.followCut = nil
    mode.followHold = nil
    mode.driveToDestinationTask = DriveToDestinationTask:new(v, marker.id)
    if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_fetch", label(job.header)) end
    v.ad.taskModule:addTask(mode.driveToDestinationTask)
end

-- (15/11) la remorque est devant la moissonneuse : près de la route qui lui reste à suivre (pas derrière elle)
function ADHeaderFlow.trailerAhead(v, trailer)
    local dpm = v.ad ~= nil and v.ad.drivePathModule or nil
    local wayPoints = dpm ~= nil and dpm.wayPoints or nil
    if wayPoints == nil or #wayPoints < 2 or trailer == nil or trailer.components == nil then
        return true -- pas de route connue : prudence, comme avant
    end
    local current = dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1
    local rx, _, rz = getWorldTranslation(trailer.components[1].node)
    -- devant son nez (sens de marche), et près de la route qui lui reste
    local node = v.components[1].node
    local cx, _, cz = getWorldTranslation(node)
    local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
    if (rx - cx) * fx + (rz - cz) * fz <= 0 then
        return false
    end
    return routeDistance(wayPoints, current, rx, rz) < ADHeaderFlow.PASS_RANGE
end

-- à chaque image pendant qu'elle suit : remorque en place ou trop près = route lâchée ; route connue = coupée avant
-- le chemin du champ
function ADHeaderFlow.followMonitor(mode, job, dt)
    local v = mode.vehicle
    local task = mode.driveToDestinationTask
    if task == nil or v.ad.taskModule:getActiveTask() ~= task then
        return
    end
    -- route lâchée en chemin : les points qui restaient sont gardés (pas ceux d'un trajet partiel ou en calcul)
    local function noteAhead()
        local dpm = v.ad.drivePathModule
        if dpm ~= nil and dpm.wayPoints ~= nil and not task.routeIsPartial
            and (task.state == nil or task.state == DriveToDestinationTask.STATE_DRIVING) then
            local rest = mode.routeAhead -- route déjà coupée à son arrêt : la suite d'avant la coupe reste derrière
            ADHeaderFlow.noteRouteAhead(mode, dpm.wayPoints, dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1)
            if mode.followCut and rest ~= nil and mode.routeAhead ~= nil then
                local seen = {}
                for _, id in ipairs(mode.routeAhead) do seen[id] = true end
                for _, id in ipairs(rest) do
                    if not seen[id] and #mode.routeAhead < ADHeaderFlow.RESUME_KEEP then
                        mode.routeAhead[#mode.routeAhead + 1] = id
                    end
                end
            elseif mode.routeAhead == nil then
                mode.routeAhead = rest
            end
        end
    end
    if job.trailerReady or job.cancelled then
        noteAhead()
        task:finished()
        return
    end
    local gap = gapTo(v, job.trailer)
    if gap <= ADHeaderFlow.FOLLOW_CLOSE and (job.leadFirst or not ADHeaderFlow.trailerAhead(v, job.trailer)) then
        -- (15/11) remorque derrière elle : s'arrêter la bloquerait (le tracteur attend derrière elle), elle continue
        if not mode.followBehindLogged then
            mode.followBehindLogged = true
            log("%s : remorque à %.0f m mais derrière elle, ne s'arrête pas (elle bloquerait le tracteur), continue", nameOf(v), gap)
        end
    elseif gap <= ADHeaderFlow.FOLLOW_CLOSE then
        log("%s : à %.0f m de la remorque, attend qu'elle avance", nameOf(v), gap)
        mode.followHold = true
        noteAhead()
        task:finished()
        return
    end
    if mode.followCut or task.routeIsPartial or (task.state ~= nil and task.state ~= DriveToDestinationTask.STATE_DRIVING) then
        return
    end
    local dpm = v.ad.drivePathModule
    local wayPoints = dpm.wayPoints
    if wayPoints == nil or #wayPoints < 2 then
        return
    end
    mode.followCut = true
    if job.leadFirst then
        -- (15/11) partie devant le tracteur pour lui ouvrir la route : pas d'arrêt sur la route avant le chemin (elle le
        -- bloquerait encore), elle va au bout de sa route ; la remorque ne s'arrêtera pas là (findSpot)
        local last = wayPoints[#wayPoints]
        job.combineStop = { x = last.x, z = last.z }
        log("%s : partie devant « %s », va au bout de sa route sans s'arrêter avant le chemin du champ", nameOf(v), nameOf(job.tractor))
        return
    end
    local current = dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1
    local i, fromEnd, lane = ADHeaderFlow.followStopIndex(wayPoints, current)
    if i == nil or i <= current + 1 then
        log("%s : déjà près du champ, attend là que la remorque soit en place", nameOf(v))
        noteAhead()
        task:finished()
        return
    end
    ADHeaderFlow.noteRouteAhead(mode, wayPoints, i) -- la suite de sa route, après son arrêt
    for k = #wayPoints, i + 1, -1 do
        wayPoints[k] = nil
    end
    job.combineStop = { x = wayPoints[i].x, z = wayPoints[i].z } -- la remorque ne passera pas par là (findSpot)
    log("%s : s'arrêtera %.0f m avant le bout de la route (%s)", nameOf(v), fromEnd, lane and "avant le chemin du champ" or "pas de chemin sur cette route")
end

-- étapes « waitLeave », « follow » et « followWait » de la moissonneuse ; true = traitée ici
function ADHeaderFlow.followStage(mode, job, stage, result)
    local v = mode.vehicle
    if stage == "waitLeave" or stage == "followWait" then
        if result ~= "ok" or job.cancelled then
            job.cancelled = true
            log("%s : la remorque n'est pas venue (%s), arrêt", nameOf(v), tostring(result))
            ADHeaderFlow.stopHere(mode, "AD_autonomous_headerTimeout")
        elseif job.trailerReady then
            log("%s : remorque au champ, va atteler la barre", nameOf(v))
            ADHeaderFlow.goToHeader(mode, job.header)
        else
            ADHeaderFlow.startFollow(mode, job)
        end
        return true
    end
    if stage ~= "follow" then
        return false
    end
    mode.driveToDestinationTask = nil
    local hold = mode.followHold
    mode.followHold = nil
    mode.followCut = nil
    if job.cancelled or v.ad.isStoppingWithError then
        local why = job.cancelled and "la remorque ne vient plus" or "pas de route vers le champ"
        job.cancelled = true
        log("%s : %s, arrêt", nameOf(v), why)
        ADHeaderFlow.stopHere(mode, "AD_autonomous_headerTimeout")
    elseif job.trailerReady then
        log("%s : remorque au champ, va atteler la barre", nameOf(v))
        ADHeaderFlow.goToHeader(mode, job.header)
    elseif hold then
        ADHeaderFlow.startWait(mode, "followWait", function()
            return job.cancelled or job.trailerReady or gapTo(v, job.trailer) > ADHeaderFlow.FOLLOW_CLOSE + ADHeaderFlow.FOLLOW_RESUME
        end)
    else
        log("%s : arrêtée avant le chemin du champ, attend que la remorque soit en place", nameOf(v))
        AutonomousMode.message(v, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerWaitTrailer", nameOf(job.tractor))
        waitTrailer(mode, job)
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Attelage de la barre posée sur la remorque : calcul du chemin borné, pas de chemin = remorque déplacée
-- ------------------------------------------------------------------------------------------------------------
-- la moissonneuse est en train d'atteler la barre de son travail, posée sur sa remorque en place
local function fetchJob(mode)
    local v = mode.vehicle
    local job = v.ad.fpHeaderJob
    local header = mode.headerFetch
    if job == nil or job.combine ~= v or job.phase ~= "deliver" or job.cancelled or header == nil or job.header ~= header
        or ADHeaderFlow.trailerOf(header) ~= job.trailer then
        return nil
    end
    return job
end

-- à chaque image pendant l'attelage : le temps de calcul du chemin est compté, la tâche arrêtée au-delà
function ADHeaderFlow.fetchMonitor(mode, dt)
    local task = mode.fetchTask
    if mode.fetchStage ~= "attach" or task == nil or task.result ~= nil or task.tool ~= mode.headerFetch then
        mode.headerPlanTime = nil
        return
    end
    if task.state ~= ADFetchToolTask.STATE_PLANNING then
        -- chemin trouvé (elle roule, s'arrête, attelle) : le compte repart de zéro pour un calcul suivant ; entre
        -- deux calculs sans chemin (elle se fait de la place) il continue
        if task.state ~= ADFetchToolTask.STATE_PLAN and task.state ~= ADFetchToolTask.STATE_ROOM then
            mode.headerPlanTime = nil
        end
        return
    end
    local job = fetchJob(mode)
    if job == nil then
        return
    end
    mode.headerPlanTime = (mode.headerPlanTime or 0) + dt
    local limit = job.sideBlocked ~= nil and ADHeaderFlow.PLAN_TIMEOUT_BLOCKED or ADHeaderFlow.PLAN_TIMEOUT
    if mode.headerPlanTime < limit then
        return
    end
    local v = mode.vehicle
    log("%s : pas de chemin jusqu'à la barre après %.0f s de calcul, on arrête de chercher", nameOf(v), mode.headerPlanTime / 1000)
    mode.headerPlanTime = nil
    if v.ad.pathFinderModule ~= nil then
        v.ad.pathFinderModule:reset()
    end
    task:finish("noPath")
end

-- fin de l'attelage de la barre sans chemin : true = traité ici (la remorque va être déplacée, la moissonneuse
-- attend) ; false = fin habituelle (message, arrêt), le tracteur est prévenu
function ADHeaderFlow.onFetchFailed(mode)
    local task = mode.fetchTask
    local result = task ~= nil and task.result or nil
    if result == nil or result == "ok" then
        return false
    end
    local job = fetchJob(mode)
    if job == nil then
        return false
    end
    local v = mode.vehicle
    mode.headerPlanTime = nil
    if result ~= "noPath" or not job.trailerReady or (job.spotMoves or 0) >= ADHeaderFlow.SPOT_MOVES then
        job.cancelled = true -- le tracteur n'attend pas pour rien
        return false
    end
    mode.fetchTask = nil
    mode.fetchStage = nil
    mode.fetchTool = nil
    mode.headerFetch = nil
    job.trailerReady = false
    job.moveRequested = true
    job.fetchNoPath = true
    log("%s : pas de chemin jusqu'à la barre, « %s » doit déplacer la remorque", nameOf(v), nameOf(job.tractor))
    AutonomousMode.message(v, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerWaitTrailer", nameOf(job.tractor))
    waitTrailer(mode, job)
    return true
end
