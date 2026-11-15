-- ============================================================================================================
-- FarmPilot : AutonomousHeaderYard.lua
-- Mode Autonome, moissonneuse équipée seule : au départ, rien de dégagé le long de la route du champ (chemin étroit
-- entre deux haies, bout de la route en virage) : la remorque porte-barre est posée sur une place libre HORS de la
-- route, près du bout (cour de ferme, aire en béton, pré), et la moissonneuse y vient prendre sa barre.
--
-- Règle (15/11, champ 77 : le MF est resté au bout du chemin, de travers dans l'herbe contre la culture, la Lexion
-- n'arrivait pas devant le cadre ; « il y a pourtant de la place pour se stationner », l'aire en béton devant le
-- hangar ; choix 1) :
-- - Quand : rien de dégagé le long de la route (arrêt A, AutonomousHeaderSpot.lua) et pas de marche arrière dans
--   l'entrée du champ ; ou, une fois arrivé, côté de la barre encombré (avant le demi-tour par le réseau et avant
--   l'endroit plus loin sur le réseau). Une seule fois par amenée.
-- - Où : à moins de YARD_RADIUS m du bout de la route du champ, tous les YARD_STEP m, YARD_HEADINGS caps essayés.
-- - Place gardée seulement si :
--   - l'attelage entier (tracteur + remorque, YARD_HALF_WIDTH m de chaque côté de son axe) est hors de tout champ
--     (jamais dans la culture, jamais sur la terre d'un champ), hors de l'eau, sans marche (fossé, talus), sans
--     obstacle (bâtiment, clôture, arbre, véhicule), et à YARD_LANE_CLEAR m au moins de l'axe de toute route du
--     réseau (il ne bloque pas le chemin) ;
--   - le côté du cadre de la barre est dégagé comme partout ailleurs (isSideFree : place de la moissonneuse et son
--     approche) et ne touche pas la terre d'un AUTRE champ que celui à récolter ;
--   - la moissonneuse peut ensuite rejoindre le champ avec sa barre (afterPickupOk).
-- - Ordre : la plus proche du bout de la route d'abord, un cap qui demande de tourner beaucoup par rapport à la route
--   compte YARD_TURN_COST m de plus par degré. Au plus YARD_SPOTS places, à YARD_APART m au moins l'une de l'autre.
-- - Trouvée au départ : la route du tracteur est coupée YARD_LEAD m avant le point de route le plus proche de la
--   place, puis il y va par la recherche de chemin (jamais le secours qui traverse la culture), place par place
--   (ADHeaderPlaceTask). Arrivé : le côté de la barre est contrôlé de nouveau sur place (onArrival).
-- - Pas de chemin jusqu'à aucune place : comme avant (demi-tour par le réseau, puis endroit plus loin).
-- - Réglage YARD = false : comme avant.
--
-- Branché par : Modes/AutonomousHeaderSpot.lua (checkRouteStop : yardOnRoute ; moveOn et onArrival, enveloppés ici),
-- Modes/AutonomousHeader.lua (tractorStage, enveloppé ici : étape « yard »). Tâche : Tasks/HeaderDropTask.lua
-- (ADHeaderPlaceTask, avec label et i18n). Chargé par register.lua après AutonomousHeaderRoadBack.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.YARD = true              -- place hors de la route près du bout quand rien ne va le long de la route
ADHeaderFlow.YARD_RADIUS = 70         -- m autour du bout de la route du champ
ADHeaderFlow.YARD_STEP = 3            -- m entre deux places essayées
ADHeaderFlow.YARD_HEADINGS = 16       -- caps essayés par place
ADHeaderFlow.YARD_HALF_WIDTH = 2.0    -- m de chaque côté de l'axe de l'attelage
ADHeaderFlow.YARD_FRONT = 3           -- m devant le point suivi du tracteur
ADHeaderFlow.YARD_LANE_CLEAR = 2.0    -- m au moins entre l'attelage et l'axe d'une route du réseau
ADHeaderFlow.YARD_TURN_COST = 0.15    -- m de plus par degré entre le cap de la place et la route
ADHeaderFlow.YARD_SPOTS = 5           -- places essayées au plus
ADHeaderFlow.YARD_APART = 6           -- m entre deux places proposées
ADHeaderFlow.YARD_CHECKS = 800        -- places contrôlées au plus (côté de la barre)
ADHeaderFlow.YARD_LEAD = 15           -- m de route avant le point le plus proche de la place : le tracteur s'y arrête

local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
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

local function refNode(t)
    if t.getAISteeringNode ~= nil then
        local node = t:getAISteeringNode()
        if node ~= nil then
            return node
        end
    end
    return t.components[1].node
end

local function onField(x, z)
    return AutoDrive.checkIsOnField ~= nil and AutoDrive.checkIsOnField(x, groundY(x, z), z) == true
end

-- ------------------------------------------------------------------------------------------------------------
-- Routes du réseau autour
-- ------------------------------------------------------------------------------------------------------------
local function laneSegments(cx, cz, radius)
    local segs = {}
    local all = ADGraphManager.getWayPoints ~= nil and ADGraphManager:getWayPoints() or nil
    for _, wp in pairs(all or {}) do
        if MathUtil.vector2Length(wp.x - cx, wp.z - cz) <= radius then
            for _, outId in pairs(wp.out or {}) do
                local o = ADGraphManager:getWayPointById(outId)
                if o ~= nil then
                    table.insert(segs, { ax = wp.x, az = wp.z, bx = o.x, bz = o.z })
                end
            end
            if wp.out == nil or next(wp.out) == nil then
                table.insert(segs, { ax = wp.x, az = wp.z, bx = wp.x, bz = wp.z })
            end
        end
    end
    return segs
end

local function laneDistance(segs, x, z)
    local best = math.huge
    for _, s in ipairs(segs) do
        local vx, vz = s.bx - s.ax, s.bz - s.az
        local l2 = vx * vx + vz * vz
        local u = l2 > 0.0001 and math.max(0, math.min(1, ((x - s.ax) * vx + (z - s.az) * vz) / l2)) or 0
        local d = MathUtil.vector2Length(x - (s.ax + vx * u), z - (s.az + vz * u))
        if d < best then
            best = d
        end
    end
    return best
end

local function nearestWayPointId(x, z)
    local all = ADGraphManager.getWayPoints ~= nil and ADGraphManager:getWayPoints() or nil
    local best, bestD = nil, math.huge
    for _, wp in pairs(all or {}) do
        local d = MathUtil.vector2Length(wp.x - x, wp.z - z)
        if d < bestD then
            best, bestD = wp.id, d
        end
    end
    return best
end

-- ------------------------------------------------------------------------------------------------------------
-- Une place : l'attelage entier hors de la route et hors des champs, côté de la barre dégagé
-- ------------------------------------------------------------------------------------------------------------
-- ok, raison
local function trainFree(t, job, model, segs, x, z, dx, dz)
    local halfW = ADHeaderFlow.YARD_HALF_WIDTH
    local front = ADHeaderFlow.YARD_FRONT
    local back = -model.length
    local prevH = nil
    local along = front
    while along >= back - 0.001 do
        local rowH = nil
        for _, across in ipairs({ -halfW, 0, halfW }) do
            local px, pz = toWorld(x, z, dx, dz, across, along)
            if ADFieldPark ~= nil and ADFieldPark.hasGrowingCrop ~= nil and ADFieldPark.hasGrowingCrop(px, pz) then
                return false, "culture"
            end
            if onField(px, pz) then
                return false, "champ"
            end
            local h = groundY(px, pz)
            if ADHeaderFlow.isWater(px, pz, h) then
                return false, "eau"
            end
            if laneDistance(segs, px, pz) < ADHeaderFlow.YARD_LANE_CLEAR then
                return false, "route"
            end
            if across == 0 then
                rowH = h
            end
        end
        if prevH ~= nil and math.abs(rowH - prevH) > ADHeaderFlow.MAX_STEP_RISE then
            return false, "fossé ou talus"
        end
        prevH = rowH
        along = along - ADHeaderFlow.SAMPLE_STEP
    end
    local yield = t.ad ~= nil and t.ad.trafficYieldModule or nil
    if yield ~= nil and yield.overlapHit ~= nil then
        local cx, cz = toWorld(x, z, dx, dz, 0, (front + back) / 2)
        local ry = MathUtil.getYRotationFromDirection(dx, dz)
        local ignored = yield.overlapIgnoreVehicle
        yield.overlapIgnoreVehicle = job.header
        local hit = yield:overlapHit(cx, groundY(cx, cz) + 1.8, cz, ry, halfW, 1.5, (front - back) / 2)
        yield.overlapIgnoreVehicle = ignored
        if hit then
            return false, "obstacle"
        end
    end
    return true, nil
end

-- l'approche de la moissonneuse ne passe pas sur la terre d'un autre champ que celui à récolter
local function approachOnOtherField(job, pose)
    local width = ADHeaderFlow.DEFAULT_HEADER_WIDTH
    if job.header ~= nil and job.header.size ~= nil then
        local _, span = ADHeaderFlow.headerBox(job.header)
        width = span
    end
    local combine = job.combine
    local length = (combine ~= nil and combine.size ~= nil and combine.size.length) or ADHeaderFlow.DEFAULT_COMBINE_LENGTH
    local halfW = width / 2 + ADHeaderFlow.SIDE_MARGIN
    local depth = length + ADHeaderDropTask.APPROACH + ADHeaderFlow.SIDE_EXTRA
    local bx, bz = -pose.dirX, -pose.dirZ
    local along = 1
    while along <= depth do
        local across = -halfW
        while across <= halfW + 0.001 do
            local x, z = toWorld(pose.x, pose.z, bx, bz, across, along)
            if onField(x, z) and not (ADHeaderFlow.isTargetField ~= nil and ADHeaderFlow.isTargetField(job, x, z)) then
                return true
            end
            across = across + 4
        end
        along = along + 4
    end
    return false
end

-- places hors de la route autour de (cx, cz) ; refDx, refDz : sens de la route en arrivant (nil : aucun)
-- { { x, z, dirX, dirZ, d }, ... } (vide : aucune) ; 2e valeur : raisons des refus comptées
function ADHeaderFlow.findYardSpots(t, job, cx, cz, refDx, refDz)
    local spots, refused = {}, {}
    local model = ADHeaderFlow.trainModel(t, job.trailer, job.header)
    if model == nil then
        refused["attelage inconnu"] = 1
        return spots, refused
    end
    local radius = ADHeaderFlow.YARD_RADIUS
    local segs = laneSegments(cx, cz, radius + model.length + 20)
    local candidates = {}
    local step = ADHeaderFlow.YARD_STEP
    local headings = ADHeaderFlow.YARD_HEADINGS
    local rx = -radius
    while rx <= radius do
        local rz = -radius
        while rz <= radius do
            local d = MathUtil.vector2Length(rx, rz)
            local px, pz = cx + rx, cz + rz
            -- le point suivi du tracteur lui-même dans la culture, sur un champ ou sur la route : aucun cap ne va
            if d <= radius and not (ADFieldPark ~= nil and ADFieldPark.hasGrowingCrop ~= nil and ADFieldPark.hasGrowingCrop(px, pz))
                and not onField(px, pz) and laneDistance(segs, px, pz) >= ADHeaderFlow.YARD_LANE_CLEAR then
                for k = 0, headings - 1 do
                    local a = 2 * math.pi * k / headings
                    local dx, dz = math.sin(a), math.cos(a)
                    local turn = 0
                    if refDx ~= nil then
                        turn = math.deg(math.acos(math.max(-1, math.min(1, dx * refDx + dz * refDz))))
                    end
                    table.insert(candidates, { x = cx + rx, z = cz + rz, dx = dx, dz = dz, d = d, score = d + turn * ADHeaderFlow.YARD_TURN_COST })
                end
            end
            rz = rz + step
        end
        rx = rx + step
    end
    table.sort(candidates, function(a, b) return a.score < b.score end)
    local checks = 0
    local function refuse(why)
        why = tostring(why)
        refused[why] = (refused[why] or 0) + 1
    end
    for _, c in ipairs(candidates) do
        local apart = true
        for _, s in ipairs(spots) do
            if MathUtil.vector2Length(s.x - c.x, s.z - c.z) < ADHeaderFlow.YARD_APART then
                apart = false
                break
            end
        end
        if apart then
            local ok, why = trainFree(t, job, model, segs, c.x, c.z, c.dx, c.dz)
            if not ok then
                refuse(why)
            else
                checks = checks + 1
                if checks > ADHeaderFlow.YARD_CHECKS then
                    break
                end
                local pose = ADHeaderFlow.predictPose(model, c.x, c.z, c.dx, c.dz)
                ok, why = ADHeaderFlow.isSideFree(t, job.combine, job.header, pose, ADHeaderFlow.PREDICT_MARGIN)
                if ok and approachOnOtherField(job, pose) then
                    ok, why = false, "autre champ"
                end
                if ok and ADHeaderFlow.afterPickupOk ~= nil then
                    ok, why = ADHeaderFlow.afterPickupOk(t, job, pose, nil, nil, nil, ADHeaderFlow.PREDICT_MARGIN, nearestWayPointId(pose.x, pose.z))
                end
                if ok then
                    table.insert(spots, { x = c.x, z = c.z, dirX = c.dx, dirZ = c.dz, d = c.d })
                    if #spots >= ADHeaderFlow.YARD_SPOTS then
                        break
                    end
                else
                    refuse("côté de la barre : " .. tostring(why))
                end
            end
        end
    end
    return spots, refused
end

local function refusedText(refused)
    local list = {}
    for why, n in pairs(refused or {}) do
        table.insert(list, { why = why, n = n })
    end
    table.sort(list, function(a, b) return a.n > b.n end)
    local parts = {}
    for i = 1, math.min(5, #list) do
        table.insert(parts, string.format("%s x%d", list[i].why, list[i].n))
    end
    return #parts > 0 and table.concat(parts, ", ") or "aucune place essayée"
end

local function spotsText(spots)
    local parts = {}
    for _, s in ipairs(spots) do
        table.insert(parts, string.format("(%.0f, %.0f) cap %.0f° à %.0f m", s.x, s.z, math.deg(math.atan2(s.dirX, s.dirZ)), s.d))
    end
    return table.concat(parts, " ; ")
end

-- le tracteur va aux places, une par une
local function startYard(mode, job, spots)
    local t = mode.vehicle
    job.yardTried = true
    job.yardSpots = nil
    job.backIn = nil
    AutonomousMode.message(t, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerYard")
    mode.headerStage = "yard"
    local task = ADHeaderPlaceTask:new(t, job.combine, job.header, job.trailer, spots)
    task.label = "va poser la remorque hors de la route"
    task.i18n = "$l10n_AD_task_autonomous_headerYard;"
    mode.headerTask = task
    t.ad.taskModule:addTask(task)
end

-- ------------------------------------------------------------------------------------------------------------
-- Au départ : rien le long de la route (AutonomousHeaderSpot.lua, checkRouteStop)
-- ------------------------------------------------------------------------------------------------------------
-- true : place trouvée, la route est coupée avant elle (le tracteur y va en arrivant)
function ADHeaderFlow.yardOnRoute(mode, job, wayPoints, current)
    if not ADHeaderFlow.YARD or job.phase ~= "deliver" or job.yardTried then
        return false
    end
    local t = mode.vehicle
    local n = #wayPoints
    local e = wayPoints[n]
    local rdx, rdz = unit(e.x - wayPoints[n - 1].x, e.z - wayPoints[n - 1].z)
    local spots, refused = ADHeaderFlow.findYardSpots(t, job, e.x, e.z, rdx, rdz)
    if #spots == 0 then
        job.yardTried = true -- (pas la peine de chercher de nouveau en arrivant)
        log("%s : pas de place hors de la route à moins de %.0f m du bout (%s)", nameOf(t), ADHeaderFlow.YARD_RADIUS, refusedText(refused))
        return false
    end
    job.fieldSpot = job.fieldSpot or { x = e.x, z = e.z }
    -- point de route le plus proche de la 1re place, puis YARD_LEAD m avant
    local first = spots[1]
    local minIndex = math.max(2, (current or 1) + ADHeaderFlow.MIN_AHEAD)
    local k, bestD = n, math.huge
    for i = minIndex, n do
        local d = MathUtil.vector2Length(wayPoints[i].x - first.x, wayPoints[i].z - first.z)
        if d < bestD then
            k, bestD = i, d
        end
    end
    local cut = k
    local back = 0
    while cut > minIndex and back < ADHeaderFlow.YARD_LEAD do
        back = back + MathUtil.vector2Length(wayPoints[cut].x - wayPoints[cut - 1].x, wayPoints[cut].z - wayPoints[cut - 1].z)
        cut = cut - 1
    end
    local fromEnd = 0
    for i = n, cut + 1, -1 do
        fromEnd = fromEnd + MathUtil.vector2Length(wayPoints[i].x - wayPoints[i - 1].x, wayPoints[i].z - wayPoints[i - 1].z)
        wayPoints[i] = nil
    end
    job.yardSpots = spots
    mode.headerStopBefore = fromEnd
    log("%s : rien de dégagé le long de la route, place hors de la route près du bout : %s ; arrêt %.0f m avant le bout, puis y va",
        nameOf(t), spotsText(spots), fromEnd)
    return true
end

-- arrivé au bout de la route coupée : il va à la place hors de la route
local baseOnArrival = ADHeaderFlow.onArrival
function ADHeaderFlow.onArrival(mode, job)
    if job.yardSpots ~= nil and not job.yardTried and job.phase == "deliver" then
        log("%s : va poser la remorque hors de la route", nameOf(mode.vehicle))
        startYard(mode, job, job.yardSpots)
        return true
    end
    return baseOnArrival(mode, job)
end

-- arrivé, côté de la barre encombré : place hors de la route d'abord (une fois), puis comme avant
local baseMoveOn = ADHeaderFlow.moveOn
function ADHeaderFlow.moveOn(mode, job, why, plain)
    if ADHeaderFlow.YARD and job.phase == "deliver" and not job.yardTried
        and (job.spotMoves or 0) < ADHeaderFlow.SPOT_MOVES then
        local t = mode.vehicle
        local x, _, z = getWorldTranslation(refNode(t))
        local cx, cz = x, z
        if job.fieldSpot ~= nil then
            cx, cz = job.fieldSpot.x, job.fieldSpot.z
        end
        local fx, _, fz = localDirectionToWorld(refNode(t), 0, 0, 1)
        local spots, refused = ADHeaderFlow.findYardSpots(t, job, cx, cz, fx, fz)
        job.yardTried = true
        local text = plain and tostring(why) or string.format("côté de la barre encombré (%s)", tostring(why))
        if #spots > 0 then
            ADHeaderFlow.rejectSpot(job, t)
            job.spotMoves = (job.spotMoves or 0) + 1
            log("%s : %s, place hors de la route près du bout : %s", nameOf(t), text, spotsText(spots))
            startYard(mode, job, spots)
            return true
        end
        log("%s : %s, pas de place hors de la route à moins de %.0f m (%s)", nameOf(t), text, ADHeaderFlow.YARD_RADIUS, refusedText(refused))
    end
    return baseMoveOn(mode, job, why, plain)
end

-- fin de l'étape « yard » (tracteur)
local baseTractorStage = ADHeaderFlow.tractorStage
function ADHeaderFlow.tractorStage(mode, job, stage, result)
    if stage ~= "yard" then
        return baseTractorStage(mode, job, stage, result)
    end
    local t = mode.vehicle
    if result == "ok" or t.ad.isStoppingWithError then
        if result == "ok" then
            log("%s : remorque posée hors de la route", nameOf(t))
        end
        -- comme un demi-tour fini : côté de la barre contrôlé sur place, sinon endroit suivant
        return baseTractorStage(mode, job, "turn", result)
    end
    log("%s : pas de chemin jusqu'aux places hors de la route (%s)", nameOf(t), tostring(result))
    if ADHeaderFlow.moveOn(mode, job, "pas de chemin jusqu'à la place hors de la route", true) then
        return
    end
    ADHeaderFlow.tractorWait(mode, job)
end
