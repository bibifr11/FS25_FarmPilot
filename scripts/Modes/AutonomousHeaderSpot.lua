-- ============================================================================================================
-- FarmPilot : AutonomousHeaderSpot.lua
-- Mode Autonome, moissonneuse équipée seule (ébauche 11/11) : où le tracteur arrête la remorque porte-barre au
-- départ, pour que la moissonneuse puisse arriver de face sur le cadre d'attelage de la barre.
--
-- Règle (11/11, choix A et B) :
-- - Côté du cadre « dégagé » : derrière le cadre de la barre (côté d'où arrive la moissonneuse), sur la largeur de
--   la barre plus SIDE_MARGIN de chaque côté et sur la longueur de la moissonneuse plus l'approche de la pose
--   (ADHeaderDropTask.APPROACH) : pas de culture debout, pas d'eau (étang, rivière, berge mouillée), pas de fossé ni
--   de talus, pas d'obstacle (arbre, bâtiment, clôture, véhicule). Une pente régulière jusqu'à MAX_SLOPE reste
--   praticable (pré en pente) ; seule une marche (MAX_STEP_RISE entre deux points voisins) est un fossé ou un talus.
-- - (12/11) Endroit choisi de loin : contrôlé PREDICT_MARGIN m plus large et plus profond que sur place, pour que
--   l'endroit soit encore bon une fois la remorque arrêtée (elle n'est jamais exactement où on l'attend).
-- - A : en route vers le champ, sur les ROUTE_SPAN derniers mètres de la route, le tracteur s'arrête au point le plus
--   proche du bout où ce côté est dégagé, la remorque droite derrière lui (route droite sur la longueur de
--   l'attelage). Le bout lui-même dégagé : il va au bout, comme avant.
-- - B : arrivé, côté encore encombré : demi-tour par le réseau, il revient dans l'autre sens (point du réseau à moins
--   de TURN_RADIUS m, parcouru dans le sens opposé, côté dégagé, route de TURN_MAX m au plus). Une seule fois.
-- - Toujours rien (11/11 : c'est FarmPilot qui amène la moissonneuse, à lui de trouver la place) : point du réseau
--   dégagé le plus proche du champ, dans les deux sens, à moins de FAR_RADIUS m ; la moissonneuse y vient prendre sa
--   barre, puis va au champ par le réseau.
-- - (12/11) Endroit pas bon une fois sur place, ou la moissonneuse n'arrive pas jusqu'à la barre : il est écarté
--   (REJECT_RADIUS m autour) et le tracteur va au suivant, au plus SPOT_MOVES fois.
-- - (12/11) Routes refusées : celle qui repart en arrière sur place (voie à double sens sans boucle, sauf au départ
--   d'un cul-de-sac) et celle qui passe là où la moissonneuse attend ou va s'arrêter (l'autre voie d'une route à
--   deux voies ne compte pas).
-- - Rien à moins de FAR_RADIUS m, ou plus de FAR_CHECKS côtés contrôlés : il attend au bout de la route (message).
-- - (12/11) Bout de la route encombré et rien de dégagé à moins de BACKIN_PREFER m avant : la remorque est d'abord
--   reculée en biais dans l'entrée du champ, quand le chemin le permet (AutonomousHeaderBackIn.lua).
-- - (13/11) Un endroit dégagé avant le bout de la route, ou plus loin, n'est gardé que si la moissonneuse peut
--   ensuite rejoindre le champ avec sa barre : champ droit devant elle, ou route assez large pour la barre
--   (AutonomousHeaderEntry.lua : afterPickupOk). Au plus ROAD_SKIPS endroits écartés pour ça par recherche.
-- - (13/11) Une flaque n'est pas de l'eau : sol mouillé par un plan d'eau au ras du chemin, sans PUDDLE_DEPTH m
--   d'eau nulle part à PUDDLE_RINGS m autour (isWater). La berge d'un étang reste de l'eau.
-- - (13/11) Un croisement juste avant le chemin du champ, le cadre de la barre tourné vers la route d'où vient la
--   moissonneuse : la remorque est reculée tout droit jusqu'à la route (AutonomousHeaderRoadBack.lua), avant toute
--   marche arrière en biais.
--
-- Branché par : Modes/AutonomousHeader.lua (monitor : checkRouteStop ; tractorStage « toField » et « turn » :
-- onArrival ; tractorStage « wait » : moveOn). Tâche du demi-tour : Tasks/HeaderDropTask.lua (ADHeaderTurnTask).
-- Chargé par register.lua après AutonomousHeader.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.ROUTE_SPAN = 150        -- m de la fin de la route où le tracteur peut s'arrêter (A)
ADHeaderFlow.SIDE_MARGIN = 1.5       -- m de chaque côté de la barre
ADHeaderFlow.SIDE_EXTRA = 3          -- m en plus derrière la moissonneuse
ADHeaderFlow.SAMPLE_STEP = 2         -- m entre deux points contrôlés
ADHeaderFlow.MAX_STEP_RISE = 0.6     -- m de dénivelé entre deux points voisins (fossé, talus)
ADHeaderFlow.MAX_RISE = 1.0          -- m d'écart avec le sol sous la barre, au pied de la remorque...
ADHeaderFlow.MAX_SLOPE = 0.20        -- ... plus cette pente régulière en s'éloignant (20 % : pré en pente)
ADHeaderFlow.WATER_MARGIN = 0.3      -- m : sol à moins de ça au-dessus de l'eau = eau (berge mouillée)
ADHeaderFlow.PUDDLE_DEPTH = 0.35     -- m d'eau au-dessus du sol : moins que ça partout autour = flaque, praticable
ADHeaderFlow.PUDDLE_RINGS = { 3, 6, 9 } -- m autour du point où une eau plus profonde est cherchée
ADHeaderFlow.PREDICT_MARGIN = 2      -- m en plus (largeur et profondeur) pour un endroit choisi de loin
ADHeaderFlow.SPOT_MOVES = 3          -- déplacements de la remorque au plus, une fois au bout de la route
ADHeaderFlow.REJECT_RADIUS = 20      -- m autour d'un endroit écarté
ADHeaderFlow.ROUTE_TRIES = 40        -- routes calculées au plus pour un endroit plus loin (voie à double sens : une par point, même quand on y arrive dans le mauvais sens)
ADHeaderFlow.STRAIGHT_ANGLE = 10     -- ° : route droite (remorque alignée derrière le tracteur)
ADHeaderFlow.STRAIGHT_EXTRA = 6      -- m de route droite en plus de l'attelage
ADHeaderFlow.MIN_AHEAD = 3           -- points de route au moins devant le tracteur pour s'arrêter avant le bout
ADHeaderFlow.TURN_RADIUS = 150       -- m autour du bout de la route pour revenir dans l'autre sens (B)
ADHeaderFlow.TURN_MAX = 3000         -- m de route au plus pour le demi-tour
ADHeaderFlow.TURN_TRIES = 6          -- routes calculées au plus
ADHeaderFlow.FAR_RADIUS = 1000       -- m autour du bout de la route pour un endroit dégagé plus loin
ADHeaderFlow.FAR_CHECKS = 600        -- côtés contrôlés au plus (les points les plus proches du champ d'abord)
ADHeaderFlow.DEFAULT_HEADER_WIDTH = 9
ADHeaderFlow.DEFAULT_COMBINE_LENGTH = 10
ADHeaderFlow.DEFAULT_COMBINE_WIDTH = 3.5
ADHeaderFlow.PASS_MARGIN = 1.5       -- m de chaque côté de la moissonneuse arrêtée pour passer à côté d'elle
ADHeaderFlow.BACK_ANGLE = 100        -- ° entre deux tronçons de route : au-delà, la route repart en arrière

local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

-- point du tracteur qui suit la route (AutoDrive suit les points avec ce point-là)
local function refNode(t)
    if t.getAISteeringNode ~= nil then
        local node = t:getAISteeringNode()
        if node ~= nil then
            return node
        end
    end
    return t.components[1].node
end

local function unit(x, z)
    local l = MathUtil.vector2Length(x, z)
    if l < 0.001 then
        return nil
    end
    return x / l, z / l
end

-- GIANTS : +x local (à gauche) du cap (dx, dz) = (dz, -dx)
local function toWorld(px, pz, dx, dz, lx, lz)
    return px + dz * lx + dx * lz, pz - dx * lx + dz * lz
end

local function groundY(x, z)
    if getTerrainHeightAtWorldPos == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return 0
    end
    return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
end

-- de l'eau en (x, z), le sol à la hauteur h (étang, rivière ; la berge juste au-dessus de l'eau compte aussi).
-- (13/11) Une flaque ne compte pas : un plan d'eau posé au ras du chemin (ornière de boue) mouille le sol sans
-- qu'il y ait de fond nulle part. Le point n'est de l'eau que s'il est lui-même sous PUDDLE_DEPTH m d'eau, ou si
-- un point autour (8 directions, à chaque distance de PUDDLE_RINGS) l'est : là c'est la berge d'un vrai plan d'eau.
function ADHeaderFlow.isWater(x, z, h)
    local env = g_currentMission ~= nil and g_currentMission.environmentAreaSystem or nil
    if env == nil or env.getWaterYAtWorldPosition == nil then
        return false
    end
    local waterY = env:getWaterYAtWorldPosition(x, h, z)
    if waterY == nil or waterY <= h - ADHeaderFlow.WATER_MARGIN then
        return false
    end
    if waterY - h >= ADHeaderFlow.PUDDLE_DEPTH then
        return true
    end
    for _, radius in ipairs(ADHeaderFlow.PUDDLE_RINGS) do
        for k = 0, 7 do
            local px, pz = x + math.sin(k * math.pi / 4) * radius, z + math.cos(k * math.pi / 4) * radius
            local ph = groundY(px, pz)
            local pw = env:getWaterYAtWorldPosition(px, ph, pz)
            if pw ~= nil and pw - ph >= ADHeaderFlow.PUDDLE_DEPTH then
                return true
            end
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- La barre sur la remorque, l'attelage droit : place et sens de la barre dans le repère du tracteur
-- ------------------------------------------------------------------------------------------------------------
-- point d'attelage de la remorque dans le repère de sa caisse, l'attelage droit. Remorque à essieu avant tournant
-- (timon et avant-train articulés sur la caisse) : mesuré tel quel, le timon de travers fausse la place de la
-- barre ; on prend l'articulation de la caisse, plus la longueur du timon dans l'axe.
local function straightHitch(trailer, input, root)
    local ix, iy, iz = getWorldTranslation(input.node)
    local ax, _, az = worldToLocal(root, ix, iy, iz)
    if input.rootNode == nil or input.rootNode == root or trailer.componentJoints == nil then
        return ax, az
    end
    local best, bestD = nil, math.huge
    for _, joint in ipairs(trailer.componentJoints) do
        local ci = joint.componentIndices
        if joint.jointNode ~= nil and ci ~= nil and (ci[1] == 1 or ci[2] == 1) then
            local jx, jy, jz = getWorldTranslation(joint.jointNode)
            local d = MathUtil.vector2Length(jx - ix, jz - iz)
            if d < bestD then
                best, bestD = { worldToLocal(root, jx, jy, jz) }, d
            end
        end
    end
    if best == nil then
        return ax, az
    end
    -- le timon part de l'articulation vers l'avant ou vers l'arrière de la caisse, comme il est maintenant
    local side = best[3] >= 0 and 1 or -1
    if math.abs(az - best[3]) > 0.3 * bestD then
        side = az >= best[3] and 1 or -1
    end
    return best[1], best[3] + side * bestD
end
ADHeaderFlow.straightHitch = straightHitch -- aussi pour AutonomousHeaderBackIn.lua

-- { lx, lz, ldx, ldz, length } ; length = longueur de l'attelage derrière le point suivi
function ADHeaderFlow.trainModel(t, trailer, header)
    local pose = ADHeaderFlow.lockPose(trailer, header)
    if pose == nil then
        return nil
    end
    local ref = refNode(t)
    local root = trailer.components[1].node
    -- attelage droit : le point d'attelage du tracteur et celui de la remorque confondus, les deux dans le même axe
    local input = trailer.getActiveInputAttacherJoint ~= nil and trailer:getActiveInputAttacherJoint() or nil
    local index = t.getAttacherJointIndexFromObject ~= nil and t:getAttacherJointIndexFromObject(trailer) or nil
    local joint = index ~= nil and t.spec_attacherJoints ~= nil and t.spec_attacherJoints.attacherJoints[index] or nil
    if input ~= nil and input.node ~= nil and joint ~= nil and joint.jointTransform ~= nil then
        local wx, wy, wz = getWorldTranslation(joint.jointTransform)
        local hx, _, hz = worldToLocal(ref, wx, wy, wz)
        local ax, az = straightHitch(trailer, input, root)
        local px, _, pz = worldToLocal(root, pose.x, pose.y, pose.z)
        local ddx, _, ddz = worldDirectionToLocal(root, pose.dirX, 0, pose.dirZ)
        local lx, lz = hx + px - ax, hz + pz - az
        local trailerRear = math.min(lz, hz - az - ((trailer.size ~= nil and trailer.size.length or 8) / 2))
        return { lx = lx, lz = lz, ldx = ddx, ldz = ddz, length = -trailerRear }
    end
    -- sans les points d'attelage : la remorque telle qu'elle est maintenant derrière le tracteur
    local lx, _, lz = worldToLocal(ref, pose.x, pose.y, pose.z)
    local ddx, _, ddz = worldDirectionToLocal(ref, pose.dirX, 0, pose.dirZ)
    return { lx = lx, lz = lz, ldx = ddx, ldz = ddz, length = math.max(-lz, 0) + 4 }
end

-- place de la barre si le point suivi du tracteur est en (x, z), cap (dx, dz), l'attelage droit
function ADHeaderFlow.predictPose(model, x, z, dx, dz)
    local px, pz = toWorld(x, z, dx, dz, model.lx, model.lz)
    local ddx, ddz = toWorld(0, 0, dx, dz, model.ldx, model.ldz)
    ddx, ddz = unit(ddx, ddz)
    return { x = px, y = groundY(px, pz), z = pz, dirX = ddx, dirZ = ddz }
end

-- ------------------------------------------------------------------------------------------------------------
-- Côté du cadre dégagé ?
-- ------------------------------------------------------------------------------------------------------------
-- ok, raison (« culture », « eau », « fossé ou talus », « obstacle ») ; extra : m en plus en largeur et en
-- profondeur (endroit choisi de loin)
function ADHeaderFlow.isSideFree(tractor, combine, header, pose, extra)
    if pose == nil or pose.dirX == nil then
        return false, "place de la barre inconnue"
    end
    local width = ADHeaderFlow.DEFAULT_HEADER_WIDTH
    if header ~= nil and header.size ~= nil then
        local _, span = ADHeaderFlow.headerBox(header)
        width = span
    end
    local length = (combine ~= nil and combine.size ~= nil and combine.size.length) or ADHeaderFlow.DEFAULT_COMBINE_LENGTH
    extra = extra or 0
    local halfW = width / 2 + ADHeaderFlow.SIDE_MARGIN + extra
    local depth = length + ADHeaderDropTask.APPROACH + ADHeaderFlow.SIDE_EXTRA + extra
    -- la moissonneuse arrive par l'arrière du cadre : vers -dir
    local bx, bz = -pose.dirX, -pose.dirZ
    local h0 = groundY(pose.x, pose.z)
    local step = ADHeaderFlow.SAMPLE_STEP
    local previousRow = nil
    local along = 1
    while along <= depth do
        local row = {}
        local i = 0
        local across = -halfW
        while across <= halfW + 0.001 do
            i = i + 1
            local x, z = toWorld(pose.x, pose.z, bx, bz, across, along)
            if ADFieldPark ~= nil and ADFieldPark.hasGrowingCrop ~= nil and ADFieldPark.hasGrowingCrop(x, z) then
                return false, "culture"
            end
            local h = groundY(x, z)
            if ADHeaderFlow.isWater(x, z, h) then
                return false, "eau"
            end
            if math.abs(h - h0) > ADHeaderFlow.MAX_RISE + ADHeaderFlow.MAX_SLOPE * along
                or (row[i - 1] ~= nil and math.abs(h - row[i - 1]) > ADHeaderFlow.MAX_STEP_RISE)
                or (previousRow ~= nil and previousRow[i] ~= nil and math.abs(h - previousRow[i]) > ADHeaderFlow.MAX_STEP_RISE) then
                return false, "fossé ou talus"
            end
            row[i] = h
            across = across + step
        end
        previousRow = row
        along = along + step
    end
    -- obstacles : une boîte sur toute la zone, de 0,3 m à 3,3 m au-dessus du sol (l'attelage lui-même ignoré)
    local yield = tractor ~= nil and tractor.ad ~= nil and tractor.ad.trafficYieldModule or nil
    if yield ~= nil and yield.overlapHit ~= nil then
        local cx, cz = toWorld(pose.x, pose.z, bx, bz, 0, (1 + depth) / 2)
        local ry = MathUtil.getYRotationFromDirection(bx, bz)
        local ignored = yield.overlapIgnoreVehicle
        yield.overlapIgnoreVehicle = header
        local hit = yield:overlapHit(cx, h0 + 1.8, cz, ry, halfW, 1.5, (depth - 1) / 2)
        yield.overlapIgnoreVehicle = ignored
        if hit then
            return false, "obstacle"
        end
    end
    return true, nil
end

-- ------------------------------------------------------------------------------------------------------------
-- A : arrêt avant le bout de la route
-- ------------------------------------------------------------------------------------------------------------
local function heading(wayPoints, i)
    local j = i - 1
    while j >= 1 do
        local dx, dz = unit(wayPoints[i].x - wayPoints[j].x, wayPoints[i].z - wayPoints[j].z)
        if dx ~= nil then
            return dx, dz
        end
        j = j - 1
    end
    return nil
end

-- la route est droite sur length m avant le point i (la remorque est alignée derrière le tracteur)
local function isStraightBefore(wayPoints, i, dx, dz, length)
    local cosMax = math.cos(math.rad(ADHeaderFlow.STRAIGHT_ANGLE))
    local done = 0
    local k = i
    while done < length do
        if k <= 1 then
            return false
        end
        local a, b = wayPoints[k - 1], wayPoints[k]
        local l = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        if l > 0.001 and ((b.x - a.x) * dx + (b.z - a.z) * dz) / l < cosMax then
            return false
        end
        done = done + l
        k = k - 1
    end
    return true
end

-- index du point de route où s'arrêter (nil : aucun), distance depuis le bout, raison du refus du bout
function ADHeaderFlow.findRouteStop(t, job, wayPoints, current)
    local model = ADHeaderFlow.trainModel(t, job.trailer, job.header)
    local n = wayPoints ~= nil and #wayPoints or 0
    if model == nil or n < 2 then
        return nil, 0, "attelage inconnu"
    end
    local straight = model.length + ADHeaderFlow.STRAIGHT_EXTRA
    local fromEnd = 0
    local endWhy = nil
    local roadWhy = nil -- la route vers le champ est trop étroite pour la barre à partir d'ici (AutonomousHeaderEntry.lua)
    local i = n
    while i >= 2 and fromEnd <= ADHeaderFlow.ROUTE_SPAN do
        if i < n and i < (current or 1) + ADHeaderFlow.MIN_AHEAD then
            break
        end
        local dx, dz = heading(wayPoints, i)
        local why
        if dx == nil then
            why = "route"
        elseif not isStraightBefore(wayPoints, i, dx, dz, straight) then
            why = "virage"
        else
            local pose = ADHeaderFlow.predictPose(model, wayPoints[i].x, wayPoints[i].z, dx, dz)
            local ok
            ok, why = ADHeaderFlow.isSideFree(t, job.combine, job.header, pose, ADHeaderFlow.PREDICT_MARGIN)
            if ok and i < n and ADHeaderFlow.afterPickupOk ~= nil then
                -- (13/11) barre prise avant le bout : la moissonneuse doit pouvoir rejoindre le champ avec elle
                local road
                ok, why, road = ADHeaderFlow.afterPickupOk(t, job, pose, wayPoints, i, model.length, ADHeaderFlow.PREDICT_MARGIN, nil, roadWhy)
                if road then
                    roadWhy = why
                end
            end
            if ok then
                return i, fromEnd, endWhy
            end
        end
        if i == n then
            endWhy = why
        end
        fromEnd = fromEnd + MathUtil.vector2Length(wayPoints[i].x - wayPoints[i - 1].x, wayPoints[i].z - wayPoints[i - 1].z)
        i = i - 1
    end
    job.roadWhy = roadWhy
    return nil, fromEnd, endWhy
end

-- à chaque image en route vers le champ (départ) : une fois la route connue, le point d'arrêt est choisi et la
-- route coupée là
function ADHeaderFlow.checkRouteStop(mode, job)
    if mode.headerStopChecked or job.phase ~= "deliver" then
        return
    end
    local t = mode.vehicle
    local task = mode.driveToDestinationTask
    if task == nil or t.ad.taskModule:getActiveTask() ~= task or task.routeIsPartial
        or (task.state ~= nil and task.state ~= DriveToDestinationTask.STATE_DRIVING) then
        return
    end
    local dpm = t.ad.drivePathModule
    local wayPoints = dpm.wayPoints
    if wayPoints == nil or #wayPoints < 2 then
        return
    end
    mode.headerStopChecked = true
    local current = dpm.getCurrentWayPointIndex ~= nil and dpm:getCurrentWayPointIndex() or 1
    local n = #wayPoints
    local i, fromEnd, endWhy = ADHeaderFlow.findRouteStop(t, job, wayPoints, current)
    -- (12/11) bout encombré et rien de dégagé tout près : la remorque est reculée dans l'entrée du champ
    -- (AutonomousHeaderBackIn.lua), la route continue sur le chemin jusqu'au point d'où le tracteur recule
    if ADHeaderFlow.backInTry ~= nil and i ~= n and (i == nil or fromEnd > ADHeaderFlow.BACKIN_PREFER)
        and ADHeaderFlow.backInTry(mode, job, wayPoints, current) then
        return
    end
    if i == nil then
        log("%s : côté de la barre encombré au bout de la route (%s), rien de dégagé sur %.0f m avant : va au bout", nameOf(t), tostring(endWhy), fromEnd)
        if job.roadWhy ~= nil then
            log("%s : des endroits dégagés avant ont été écartés (%s)", nameOf(t), tostring(job.roadWhy))
        end
        return
    end
    if i == n then
        log("%s : bout de la route dégagé côté barre", nameOf(t))
        return
    end
    for k = n, i + 1, -1 do
        wayPoints[k] = nil
    end
    mode.headerStopBefore = fromEnd
    log("%s : bout de la route encombré côté barre (%s), arrêt %.0f m avant", nameOf(t), tostring(endWhy), fromEnd)
end

-- ------------------------------------------------------------------------------------------------------------
-- B : demi-tour par le réseau
-- ------------------------------------------------------------------------------------------------------------
local function routeLength(route)
    local l = 0
    for k = 2, #route do
        l = l + MathUtil.vector2Length(route[k].x - route[k - 1].x, route[k].z - route[k - 1].z)
    end
    return l
end

-- réseau droit sur length m avant le point wp, dans le sens (dx, dz) (en remontant les liaisons d'arrivée)
local function isNetworkStraightBefore(wp, dx, dz, length)
    local cosMax = math.cos(math.rad(ADHeaderFlow.STRAIGHT_ANGLE))
    local done = 0
    local current = wp
    while done < length do
        local best, bestCos, bestLength = nil, cosMax, 0
        for _, inId in pairs(current.incoming or {}) do
            local prev = ADGraphManager:getWayPointById(inId)
            if prev ~= nil then
                local l = MathUtil.vector2Length(current.x - prev.x, current.z - prev.z)
                local c = l > 0.001 and ((current.x - prev.x) * dx + (current.z - prev.z) * dz) / l or -1
                if c >= bestCos then
                    best, bestCos, bestLength = prev, c, l
                end
            end
        end
        if best == nil then
            return false
        end
        done = done + bestLength
        current = best
    end
    return true
end

-- endroit écarté : une fois sur place le côté n'était pas dégagé, ou la moissonneuse n'y est pas arrivée
local function isRejected(job, x, z)
    for _, r in ipairs(job.rejected or {}) do
        if MathUtil.vector2Length(r.x - x, r.z - z) <= ADHeaderFlow.REJECT_RADIUS then
            return true
        end
    end
    return false
end

-- l'endroit où le tracteur est arrêté maintenant ne sera plus proposé
function ADHeaderFlow.rejectSpot(job, t)
    local x, _, z = getWorldTranslation(refNode(t))
    job.rejected = job.rejected or {}
    table.insert(job.rejected, { x = x, z = z })
end

-- la route passe là où la moissonneuse attend ou va s'arrêter (chemin à une voie : le tracteur resterait bloqué
-- devant elle) ; l'autre voie d'une route à deux voies ne compte pas. La route est contrôlée tous les 2 m.
local function crossesCombine(route, job)
    local combine = job.combine
    if combine == nil or combine.components == nil then
        return false
    end
    local node = combine.components[1].node
    local _, cy, _ = getWorldTranslation(node)
    local size = combine.size
    local halfL = ((size ~= nil and size.length) or ADHeaderFlow.DEFAULT_COMBINE_LENGTH) / 2 + 3
    local halfW = ((size ~= nil and size.width) or ADHeaderFlow.DEFAULT_COMBINE_WIDTH) / 2 + ADHeaderFlow.PASS_MARGIN
    local stop = job.combineStop
    local function hit(x, z)
        local lx, _, lz = worldToLocal(node, x, cy, z)
        if math.abs(lx) <= halfW and math.abs(lz) <= halfL then
            return true
        end
        return stop ~= nil and MathUtil.vector2Length(x - stop.x, z - stop.z) <= ADHeaderFlow.PASS_MARGIN + 1
    end
    for k = 1, #route do
        if hit(route[k].x, route[k].z) then
            return true
        end
        if k > 1 then
            local a, b = route[k - 1], route[k]
            local n = math.ceil(MathUtil.vector2Length(b.x - a.x, b.z - a.z) / 2)
            for s = 1, n - 1 do
                if hit(a.x + (b.x - a.x) * s / n, a.z + (b.z - a.z) * s / n) then
                    return true
                end
            end
        end
    end
    return false
end

-- cul-de-sac : à partir du point wp, aucun point du réseau devant le tracteur (bout de la route d'un champ : il ne
-- peut que repartir en arrière, comme il le fait pour rentrer)
local function isDeadEnd(t, wp)
    local ref = refNode(t)
    local x, _, z = getWorldTranslation(ref)
    local fx, _, fz = localDirectionToWorld(ref, 0, 0, 1)
    local net = wp ~= nil and wp.id ~= nil and ADGraphManager:getWayPointById(wp.id) or wp
    for _, outId in pairs(net ~= nil and net.out or {}) do
        local o = ADGraphManager:getWayPointById(outId)
        if o ~= nil and (o.x - x) * fx + (o.z - z) * fz > 1 then
            return false
        end
    end
    return true
end

-- la route repart en arrière : dès le départ (voie à double sens sans boucle : le réseau ne propose qu'un demi-tour
-- sur place, impossible avec la remorque sur un chemin) ou plus loin (deux tronçons à plus de BACK_ANGLE° l'un de
-- l'autre). Au départ d'un cul-de-sac, repartir en arrière est la seule sortie : accepté une fois.
local function turnsBack(t, route)
    local ref = refNode(t)
    local px, _, pz = getWorldTranslation(ref)
    local pdx, _, pdz = localDirectionToWorld(ref, 0, 0, 1)
    local cosMax = math.cos(math.rad(ADHeaderFlow.BACK_ANGLE))
    local minLength = 3 -- le premier point de la route peut être sous le tracteur
    local checked = 0
    local deadEnd = isDeadEnd(t, route[1])
    for k = 1, #route do
        local l = MathUtil.vector2Length(route[k].x - px, route[k].z - pz)
        if l > minLength then
            local dx, dz = (route[k].x - px) / l, (route[k].z - pz) / l
            checked = checked + 1
            if dx * pdx + dz * pdz < cosMax then
                if not (deadEnd and checked <= 2) then
                    return true
                end
                deadEnd = false
            end
            px, pz, pdx, pdz = route[k].x, route[k].z, dx, dz
            minLength = 0.5
        end
    end
    return false
end

-- point du réseau dégagé où aller : { id, length, distance } ou nil ; opposite = seulement parcouru dans l'autre sens
-- que le tracteur (demi-tour). Les endroits sont pris du plus proche au plus loin du bout de la route du champ
-- (job.fieldSpot), les endroits écartés sautés ; une seule route calculée par point (elle dit dans quel sens on y
-- arrive).
function ADHeaderFlow.findSpot(t, job, radius, opposite, maxChecks)
    local model = ADHeaderFlow.trainModel(t, job.trailer, job.header)
    local all = ADGraphManager.getWayPoints ~= nil and ADGraphManager:getWayPoints() or nil
    if model == nil or all == nil then
        return nil
    end
    local ref = refNode(t)
    local tx, _, tz = getWorldTranslation(ref)
    local ex, ez = tx, tz
    if job.fieldSpot ~= nil then
        ex, ez = job.fieldSpot.x, job.fieldSpot.z
    end
    local fx, _, fz = localDirectionToWorld(ref, 0, 0, 1)
    local candidates = {}
    for _, wp in pairs(all) do
        local d = MathUtil.vector2Length(wp.x - ex, wp.z - ez)
        if d <= radius and not isRejected(job, wp.x, wp.z) then
            for _, inId in pairs(wp.incoming or {}) do
                local prev = ADGraphManager:getWayPointById(inId)
                if prev ~= nil then
                    local dx, dz = unit(wp.x - prev.x, wp.z - prev.z)
                    if dx ~= nil and (not opposite or dx * fx + dz * fz < -0.5) then
                        table.insert(candidates, { wp = wp, dx = dx, dz = dz, d = d })
                    end
                end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.d < b.d end)
    local straight = model.length + ADHeaderFlow.STRAIGHT_EXTRA
    local maxRoutes = opposite and ADHeaderFlow.TURN_TRIES or ADHeaderFlow.ROUTE_TRIES
    local routes, routeCount, checks = {}, 0, 0
    local roadSkips = 0
    for _, c in ipairs(candidates) do
        -- le contrôle de la route droite ne coûte rien : seuls les côtés contrôlés comptent
        local isStraight = isNetworkStraightBefore(c.wp, c.dx, c.dz, straight)
        if isStraight then
            checks = checks + 1
            if maxChecks ~= nil and checks > maxChecks then
                break
            end
        end
        if isStraight
            and ADHeaderFlow.isSideFree(t, job.combine, job.header, ADHeaderFlow.predictPose(model, c.wp.x, c.wp.z, c.dx, c.dz), ADHeaderFlow.PREDICT_MARGIN) then
            local entry = routes[c.wp.id]
            if entry == nil then
                if routeCount >= maxRoutes then
                    break
                end
                routeCount = routeCount + 1
                entry = { route = ADGraphManager:getPathTo(t, c.wp.id) }
                if entry.route ~= nil and #entry.route >= 2 and turnsBack(t, entry.route) then
                    entry.route = nil -- demi-tour sur place : pas une route pour la remorque
                end
                routes[c.wp.id] = entry
            end
            local route = entry.route
            local n = route ~= nil and #route or 0
            if n >= 2 and route[n].id == c.wp.id then
                local len = routeLength(route)
                local dx, dz = heading(route, n)
                if len <= ADHeaderFlow.TURN_MAX and dx ~= nil and dx * c.dx + dz * c.dz > 0.9
                    and isStraightBefore(route, n, dx, dz, straight) and not crossesCombine(route, job) then
                    -- (13/11) barre prise là : la moissonneuse doit pouvoir rejoindre le champ avec elle (AutonomousHeaderEntry.lua)
                    local fits, why = true, nil
                    if ADHeaderFlow.afterPickupOk ~= nil then
                        fits, why = ADHeaderFlow.afterPickupOk(t, job, ADHeaderFlow.predictPose(model, c.wp.x, c.wp.z, c.dx, c.dz), nil, nil, nil,
                            ADHeaderFlow.PREDICT_MARGIN, c.wp.id)
                    end
                    if fits then
                        return { id = c.wp.id, length = len, distance = c.d }
                    end
                    roadSkips = roadSkips + 1
                    if roadSkips <= 3 then
                        log("%s : endroit dégagé au point %s (à %.0f m du champ) écarté : %s", nameOf(t), tostring(c.wp.id), c.d, tostring(why))
                    end
                    if roadSkips >= ADHeaderFlow.ROAD_SKIPS then
                        break
                    end
                end
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Arrivée du tracteur (départ) : true = demi-tour ou endroit plus loin lancé, sinon il attend la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderFlow.onArrival(mode, job)
    local t = mode.vehicle
    if job.phase ~= "deliver" then
        return false
    end
    if job.fieldSpot == nil then
        -- bout de la route du champ : les endroits sont cherchés autour de là
        local x, _, z = getWorldTranslation(refNode(t))
        job.fieldSpot = { x = x, z = z }
    end
    local pose = ADHeaderFlow.lockPose(job.trailer, job.header)
    local ok, why = ADHeaderFlow.isSideFree(t, job.combine, job.header, pose)
    if ok then
        log("%s : côté de la barre dégagé", nameOf(t))
        job.sideBlocked = nil
        return false
    end
    job.sideBlocked = why
    return ADHeaderFlow.moveOn(mode, job, why)
end

-- l'endroit ne va pas (why : ce qui encombre le côté de la barre, ou plain = la raison en toutes lettres) : il est
-- écarté et le tracteur va au suivant (demi-tour par le réseau la première fois, sinon l'endroit dégagé le plus
-- proche du champ) ; false = plus rien à essayer, il attend là (message)
function ADHeaderFlow.moveOn(mode, job, why, plain)
    local t = mode.vehicle
    job.backIn = nil -- la remorque n'est plus reculée dans l'entrée du champ (AutonomousHeaderBackIn.lua)
    ADHeaderFlow.rejectSpot(job, t)
    job.spotMoves = job.spotMoves or 0
    why = plain and tostring(why) or string.format("côté de la barre encombré (%s)", tostring(why))
    if job.spotMoves >= ADHeaderFlow.SPOT_MOVES then
        log("%s : %s, déjà %d déplacements, attend là", nameOf(t), why, job.spotMoves)
        AutonomousMode.message(t, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_headerSideBlocked")
        return false
    end
    local spot, text = nil, "AD_autonomous_headerMove"
    if job.spotMoves == 0 then
        spot = ADHeaderFlow.findSpot(t, job, ADHeaderFlow.TURN_RADIUS, true)
        if spot ~= nil then
            text = "AD_autonomous_headerTurn"
            log("%s : %s, demi-tour par le réseau (point %s à %.0f m, route %.0f m)", nameOf(t), why, tostring(spot.id), spot.distance, spot.length)
        else
            log("%s : %s, pas de demi-tour possible, cherche plus loin", nameOf(t), why)
        end
    else
        log("%s : %s ici aussi, cherche un autre endroit", nameOf(t), why)
    end
    if spot == nil then
        spot = ADHeaderFlow.findSpot(t, job, ADHeaderFlow.FAR_RADIUS, false, ADHeaderFlow.FAR_CHECKS)
        if spot ~= nil then
            log("%s : endroit dégagé à %.0f m du champ (point %s, route %.0f m), la moissonneuse y viendra", nameOf(t), spot.distance, tostring(spot.id), spot.length)
        end
    end
    if spot == nil then
        log("%s : aucun endroit dégagé à moins de %.0f m, attend là", nameOf(t), ADHeaderFlow.FAR_RADIUS)
        AutonomousMode.message(t, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_headerSideBlocked")
        return false
    end
    job.spotMoves = job.spotMoves + 1
    AutonomousMode.message(t, ADMessagesManager.messageTypes.INFO, 8000, text)
    mode.headerStage = "turn"
    -- le temps de la route à 5 km/h, deux minutes de marge
    mode.headerTask = ADHeaderTurnTask:new(t, spot.id, 120000 + spot.length / 1.4 * 1000)
    t.ad.taskModule:addTask(mode.headerTask)
    return true
end
