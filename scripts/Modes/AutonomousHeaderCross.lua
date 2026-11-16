-- ============================================================================================================
-- FarmPilot : AutonomousHeaderCross.lua
-- Mode Autonome, moissonneuse équipée seule : la remorque porte-barre est reculée EN TRAVERS DU CHEMIN, l'arrière
-- dans l'herbe de l'autre côté du champ, quand le champ est fermé (muret, clôture le long du chemin) ou que le
-- cadre de la barre est du côté du champ. La moissonneuse arrive par le chemin, prend sa barre sur place, puis va
-- au champ par son entrée.
--
-- Règle (16/11, champ 52 : muret en pierre bas entre un chemin à une voie et le champ) :
-- - Quand : la marche arrière dans l'entrée du champ ne se fait pas (AutonomousHeaderBackIn.lua : backInTry) parce
--   qu'un objet fixe est entre le chemin et la place de la remorque (« closed »), ou parce que le cadre de la barre
--   est du côté du champ (« frameSide »). Il faut le cadre de la barre du côté du champ : une fois la remorque
--   reculée de l'autre côté, il regarde le chemin, vers la moissonneuse qui arrive dans le même sens que le
--   tracteur. Sinon (cadre de l'autre côté), pas de barre en travers : l'endroit suivant.
-- - Où : AVANT l'entrée du champ, de CROSS_ENTRY_GAP à CROSS_SPAN m (la moissonneuse continue tout droit jusqu'à
--   l'entrée après avoir pris sa barre), la remorque à CROSS_ANGLES ° du chemin (45° d'abord), le cadre assez loin
--   dans l'herbe pour le virage puis la ligne droite de la moissonneuse (mêmes calculs que la marche arrière dans
--   le champ, côté herbe : backInStop, backInLane, backInPath).
-- - Le tracteur passe la place, s'arrête décalé de CROSS_BIASES m vers l'herbe (son nez passe côté champ pendant la
--   marche arrière : il faut CROSS_SWING m moins ce décalage de libres de ce côté, ni culture, ni objet fixe ; au
--   tout début il part d'abord vers l'herbe, CROSS_COUNTER_SWING m au-delà de sa largeur), puis recule (même tâche
--   que la marche arrière dans le champ : Tasks/HeaderBackInTask.lua, plan.cross).
-- - Interdit, contrôlé AVANT, avec CROSS_MARGIN m de marge : la culture (d'aucun côté), un autre champ (terre de
--   champ, même sans culture, du côté de l'herbe), l'eau, un fossé ou un talus, un objet fixe (muret, clôture,
--   poteau, arbre, bâtiment : AutonomousHeaderBackIn.lua, fixedHit) et un véhicule. Contrôlés : la bande où
--   l'attelage roule décalé, la caisse de la remorque pendant la marche arrière (BACKIN_SWEEP) et à la fin, devant
--   le cadre, la courbe de la moissonneuse jusqu'au cadre (elle doit exister), et le chemin de la place jusqu'à
--   l'entrée pour la moissonneuse avec sa barre (AutonomousHeaderEntry.lua : afterPickupOk).
-- - La route du tracteur est droite sur la place : coupée au dernier point avant le décalage, puis des points sur
--   la ligne du chemin jusqu'à l'arrêt (backInRoute, plan.routeFrom).
-- - Une place écartée (job.rejected : tracteur resté bloqué avant d'y être) n'est plus proposée.
-- - Rien ne va : pas de barre en travers, la suite habituelle (place hors de la route, bout de la route, endroit
--   suivant). Marche arrière pas réussie : l'endroit suivant (backInDone : moveOn).
-- - Barre prise : comme dans l'entrée du champ, petit recul (AutonomousHeaderClear.lua), le tracteur repart
--   d'abord, puis la moissonneuse va au champ.
-- - Réglage CROSS = false : comme avant (pas de barre en travers du chemin).
--
-- Branché par : Modes/AutonomousHeaderBackIn.lua (backInTry : crossTry ; startBackIn, backInDone, backInLane,
-- groundOk : plan.cross). Chargé par register.lua après AutonomousHeaderBackIn.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.CROSS = true                    -- false : jamais de barre reculée en travers du chemin
ADHeaderFlow.CROSS_ANGLES = { 45, 50, 40 }   -- ° entre la remorque reculée et le chemin, dans cet ordre
ADHeaderFlow.CROSS_ENTRY_GAP = 10            -- m : le cadre est au moins ça avant l'entrée du champ
ADHeaderFlow.CROSS_SPAN = 45                 -- m avant l'entrée, au plus
ADHeaderFlow.CROSS_STEP = 4                  -- m entre deux places essayées le long du chemin
ADHeaderFlow.CROSS_BIASES = { 1.5, 3, 4.5 }  -- m : le tracteur s'arrête décalé d'autant vers l'herbe, dans cet ordre
ADHeaderFlow.CROSS_SWING = 5.5               -- m du milieu de l'arrêt jusqu'où le nez du tracteur passe côté champ, marge comprise (4,5 mesurés hors jeu)
ADHeaderFlow.CROSS_COUNTER_SWING = 3         -- m : au début de la marche arrière son nez part d'abord vers l'herbe, d'autant au-delà de sa largeur (2,5 mesurés hors jeu)
ADHeaderFlow.CROSS_MARGIN = 0.5              -- m autour de la remorque et de la moissonneuse (objets fixes, véhicules)
ADHeaderFlow.CROSS_EDGE = 3                  -- m du milieu du chemin : le cadre est au moins ça dans l'herbe
ADHeaderFlow.CROSS_GRID = 1.5                -- m entre deux points du sol contrôlés
ADHeaderFlow.CROSS_CURVE_STEP = 4            -- m entre deux contrôles d'objets fixes sur la courbe de la moissonneuse

-- ------------------------------------------------------------------------------------------------------------
-- Petits outils
-- ------------------------------------------------------------------------------------------------------------
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

local function groundY(x, z)
    if getTerrainHeightAtWorldPos == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return 0
    end
    return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
end

local function hasCrop(x, z)
    return ADFieldPark ~= nil and ADFieldPark.hasGrowingCrop ~= nil and ADFieldPark.hasGrowingCrop(x, z) == true
end

local function onField(x, y, z)
    return AutoDrive ~= nil and AutoDrive.checkIsOnField ~= nil and AutoDrive.checkIsOnField(x, y, z) == true
end

local function endStraight()
    return (ADNoseIn ~= nil and ADNoseIn.END_STRAIGHT) or ADHeaderFlow.BACKIN_END_STRAIGHT
end

-- sol d'une caisse (centre, sens, demi-largeur, demi-longueur), tous les CROSS_GRID m : nil s'il est praticable,
-- sinon ce qui ne va pas (culture, eau, fossé ou talus ; field : la terre d'un champ aussi)
local function boxGround(cx, cz, dx, dz, half, halfLength, field)
    local lx, lz = dz, -dx
    local nA = math.max(1, math.ceil(2 * halfLength / ADHeaderFlow.CROSS_GRID))
    local nW = math.max(1, math.ceil(2 * half / ADHeaderFlow.CROSS_GRID))
    local previous = {}
    for i = 0, nA do
        local a = -halfLength + 2 * halfLength * i / nA
        for k = 0, nW do
            local w = -half + 2 * half * k / nW
            local x, z = cx + dx * a + lx * w, cz + dz * a + lz * w
            local y = groundY(x, z)
            if hasCrop(x, z) then
                return string.format("culture en (%.0f, %.0f)", x, z)
            end
            if ADHeaderFlow.isWater(x, z, y) then
                return string.format("eau en (%.0f, %.0f)", x, z)
            end
            if field and onField(x, y, z) then
                return string.format("champ en (%.0f, %.0f)", x, z)
            end
            if previous[k] ~= nil and math.abs(y - previous[k]) > ADHeaderFlow.MAX_STEP_RISE then
                return string.format("fossé ou talus en (%.0f, %.0f)", x, z)
            end
            previous[k] = y
        end
    end
    return nil
end

-- objet fixe (muret, clôture, arbre...) ou véhicule dans la caisse : nil, sinon ce que c'est
local function boxBlocked(t, job, cx, cz, dx, dz, half, halfLength)
    local hit, name = ADHeaderFlow.fixedHit(t, job, cx, cz, dx, dz, half, halfLength)
    if hit then
        return string.format("objet fixe (%s)", tostring(name))
    end
    if ADHeaderFlow.backInBoxHit ~= nil and ADHeaderFlow.backInBoxHit(t, cx, cz, dx, dz, half, halfLength) then
        return "obstacle"
    end
    return nil
end

local function isRejected(job, x, z)
    for _, r in ipairs(job.rejected or {}) do
        if MathUtil.vector2Length(r.x - x, r.z - z) <= ADHeaderFlow.REJECT_RADIUS then
            return true
        end
    end
    return false
end

-- dernier point de la route du tracteur (entre current et j) au plus à uMax m sur le chemin : index, m
local function cutIndex(wayPoints, j, current, jx, jz, ux, uz, uMax)
    for k = j, math.max(1, current or 1), -1 do
        local u = (wayPoints[k].x - jx) * ux + (wayPoints[k].z - jz) * uz
        if u <= uMax then
            return k, u
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Le plan
-- ------------------------------------------------------------------------------------------------------------
-- même plan que la marche arrière dans le champ (AutonomousHeaderBackIn.lua : backInPlan), nx, nz vers l'herbe, plus
-- cross = true, angle (°), cut (index de la route du tracteur gardée), routeFrom ; nil, raison
function ADHeaderFlow.crossPlan(t, job, wayPoints, current)
    local rig, why = ADHeaderFlow.backInRig(t, job)
    if rig == nil then
        return nil, why
    end
    local info, infoWhy = ADHeaderFlow.backInLaneInfo(t, job, wayPoints, current)
    if info == nil then
        return nil, infoWhy
    end
    if rig.side ~= info.side then
        return nil, "le cadre de la barre n'est pas du côté du champ : en travers du chemin, il tournerait le dos à la moissonneuse"
    end
    local J, ux, uz, uE = info.J, info.ux, info.uz, info.uE
    local gx, gz = -info.nx, -info.nz -- vers l'herbe, de l'autre côté du champ
    local lane = { jx = J.x, jz = J.z, ux = ux, uz = uz, nx = gx, nz = gz }
    -- la route du tracteur, droite avant le point du chemin, et où il en est
    local straight = ADHeaderFlow.backInStraightBefore(wayPoints, info.j, J.x, J.z, ux, uz)
    local cur = wayPoints[math.max(1, math.min(current or 1, info.j))]
    local uCur = (cur.x - J.x) * ux + (cur.z - J.z) * uz
    local routeMin = math.max(-straight, uCur)
    local trailerWidth = (job.trailer.size ~= nil and job.trailer.size.width) or 3
    local trailerLength = (job.trailer.size ~= nil and job.trailer.size.length) or 12
    local trainHalf = ADHeaderFlow.backInTrainHalf(t, job)
    local run = rig.dj + endStraight() + ADHeaderFlow.BACKIN_FINAL
    local front = ADHeaderFlow.BACKIN_TRACTOR_FRONT
    local last = "pas de place avant l'entrée"
    for _, angle in ipairs(ADHeaderFlow.CROSS_ANGLES) do
        local theta = math.rad(angle)
        local sinT, cosT = math.sin(theta), math.cos(theta)
        local tfx, tfz = cosT * ux - sinT * gx, cosT * uz - sinT * gz
        local tlx, tlz = tfz, -tfx
        local fx, fz = unit(rig.fdx * tlx + rig.fdz * tfx, rig.fdx * tlz + rig.fdz * tfz)
        local cosB, sinB = -(fx * ux + fz * uz), -(fx * gx + fz * gz)
        if cosB >= math.cos(math.rad(ADHeaderFlow.BACKIN_MAX_TURN)) and sinB >= 0.1 then
            local beta = math.atan2(sinB, cosB)
            local tangent = rig.rc * math.tan(beta / 2)
            local nFrame = math.max(ADHeaderFlow.CROSS_EDGE, rig.rc * (1 - cosB) + run * sinB)
            -- la moissonneuse est alignée sur le chemin avant son virage
            local uLow = math.max(uE - ADHeaderFlow.CROSS_SPAN, -info.before + ADHeaderFlow.BACKIN_ALIGN + tangent + nFrame * cosB / sinB)
            local uFrame = uE - ADHeaderFlow.CROSS_ENTRY_GAP
            if uFrame < uLow then
                last = string.format("pas assez de chemin droit avant l'entrée (%.0f m)", info.before)
            end
            while uFrame >= uLow do
                local plan, planWhy = ADHeaderFlow.crossAt(t, job, wayPoints, current, {
                    rig = rig, info = info, lane = lane, angle = angle, theta = theta, tfx = tfx, tfz = tfz, tlx = tlx, tlz = tlz,
                    fx = fx, fz = fz, run = run, front = front, uFrame = uFrame, nFrame = nFrame, routeMin = routeMin, straight = straight,
                    trailerWidth = trailerWidth, trailerLength = trailerLength, trainHalf = trainHalf })
                if plan ~= nil then
                    return plan
                end
                last = planWhy or last
                uFrame = uFrame - ADHeaderFlow.CROSS_STEP
            end
        else
            last = "cadre de la barre pas tourné vers le chemin une fois la remorque en travers"
        end
    end
    return nil, last
end

-- une place (c : voir crossPlan) : le plan, ou nil, raison
function ADHeaderFlow.crossAt(t, job, wayPoints, current, c)
    local rig, info, lane = c.rig, c.info, c.lane
    local J, ux, uz, gx, gz = info.J, lane.ux, lane.uz, lane.nx, lane.nz
    local frameX, frameZ = J.x + ux * c.uFrame + gx * c.nFrame, J.z + uz * c.uFrame + gz * c.nFrame
    if isRejected(job, frameX, frameZ) then
        return nil, "place déjà écartée"
    end
    local where = string.format("cadre %.0f m avant l'entrée, %.0f°", info.uE - c.uFrame, c.angle)
    -- la caisse de la remorque à la fin, puis son essieu
    local rootX, rootZ = frameX - rig.hx * c.tlx - rig.hz * c.tfx, frameZ - rig.hx * c.tlz - rig.hz * c.tfz
    local axleX, axleZ = rootX + rig.rx * c.tlx + rig.rz * c.tfx, rootZ + rig.rx * c.tlz + rig.rz * c.tfz
    -- au sol (herbe : ni culture, ni eau, ni champ, ni fossé) et libre : la remorque à la fin, puis devant le cadre
    local bad = boxGround(rootX, rootZ, c.tfx, c.tfz, c.trailerWidth / 2 + ADHeaderFlow.CROSS_MARGIN, c.trailerLength / 2, true)
    if bad ~= nil then
        return nil, string.format("%s : %s sous la remorque", where, bad)
    end
    local runX, runZ = frameX + c.fx * (c.run / 2 + 0.5), frameZ + c.fz * (c.run / 2 + 0.5)
    local runHalf = rig.cw / 2 + ADHeaderFlow.CROSS_MARGIN
    bad = boxGround(runX, runZ, c.fx, c.fz, runHalf, c.run / 2, true)
    if bad ~= nil then
        return nil, string.format("%s : %s devant le cadre", where, bad)
    end
    bad = boxBlocked(t, job, rootX, rootZ, c.tfx, c.tfz, c.trailerWidth / 2 + ADHeaderFlow.CROSS_MARGIN, c.trailerLength / 2)
        or boxBlocked(t, job, runX, runZ, c.fx, c.fz, runHalf, c.run / 2)
    if bad ~= nil then
        return nil, string.format("%s : %s à la place de la remorque ou devant le cadre", where, bad)
    end
    -- l'axe de la marche arrière, puis l'arrêt du tracteur, décalé vers l'herbe
    local axis = c.theta + math.rad(ADHeaderFlow.BACKIN_AXIS_EXTRA)
    local sinA = math.sin(axis)
    local ax, az = -(math.cos(axis) * ux - sinA * gx), -(math.cos(axis) * uz - sinA * gz)
    local axleN = (axleX - J.x) * gx + (axleZ - J.z) * gz
    local last = nil
    for _, bias in ipairs(ADHeaderFlow.CROSS_BIASES) do
        local s = ADHeaderFlow.backInStop(lane, rig, axleX, axleZ, axleN, ax, az, sinA, bias, c.routeMin + ADHeaderFlow.BACKIN_ROUTE_STEP)
        local plan
        plan, last = ADHeaderFlow.crossStop(t, job, wayPoints, current, c, s, bias, where, {
            frameX = frameX, frameZ = frameZ, rootX = rootX, rootZ = rootZ, ax = ax, az = az })
        if plan ~= nil then
            return plan
        end
    end
    return nil, last
end

-- un arrêt du tracteur (s : backInStop) pour une place : le plan, ou nil, raison
function ADHeaderFlow.crossStop(t, job, wayPoints, current, c, s, bias, where, p)
    local rig, info, lane = c.rig, c.info, c.lane
    local J, ux, uz, gx, gz = info.J, lane.ux, lane.uz, lane.nx, lane.nz
    where = string.format("%s, décalé de %.1f m", where, bias)
    if s.bias ~= bias then
        return nil, string.format("%s : pas la place de se décaler", where)
    end
    if s.reach < 2 or s.reach > ADHeaderFlow.BACKIN_MAX_REACH then
        return nil, string.format("%s : remorque à reculer de %.0f m", where, s.reach)
    end
    if s.stop > 0 and s.stop + 1 > info.available then
        return nil, string.format("%s : chemin trop court après l'entrée (%.0f m, il en faut %.0f)", where, info.available, s.stop + 1)
    end
    -- la route du tracteur : gardée jusqu'au dernier point avant le décalage, droite après
    local uMax = s.shiftFrom - 1
    local cut, uCut = cutIndex(wayPoints, info.j, current, J.x, J.z, ux, uz, uMax)
    if cut == nil or uCut < -c.straight - 0.5 or cut < (current or 1) then
        return nil, string.format("%s : route du tracteur pas droite avant la place", where)
    end
    -- côté champ, là où le nez du tracteur passe pendant la marche arrière : ni culture, ni eau, ni objet fixe
    local need = ADHeaderFlow.CROSS_SWING - bias
    if need > 0.5 then
        for _, along in ipairs({ s.uQ - 6, s.uQ, s.uQ + ADHeaderFlow.BACKIN_START, s.stop }) do
            local d = 1
            while d <= need do
                local x, z = J.x + ux * along - gx * d, J.z + uz * along - gz * d
                if hasCrop(x, z) or ADHeaderFlow.isWater(x, z, groundY(x, z)) then
                    return nil, string.format("%s : culture ou eau côté champ, là où passe le nez du tracteur", where)
                end
                d = d + 0.5
            end
        end
        local hit, name = ADHeaderFlow.backInBandHit(t, job, lane, -need / 2, s.uQ - 6, s.stop + c.front, need / 2)
        if hit then
            return nil, string.format("%s : objet fixe côté champ, là où passe le nez du tracteur (%s)", where, tostring(name))
        end
    end
    -- la bande où l'attelage roule décalé (et pendant qu'il se décale) jusqu'au nez du tracteur à l'arrêt, et la place
    -- où son nez part d'abord vers l'herbe au début de la marche arrière : au sol, pas de culture ni de champ (côté
    -- herbe), pas d'objet fixe
    local swing = ADHeaderFlow.CROSS_COUNTER_SWING
    local mid = (s.shiftTo + s.stop + c.front) / 2
    local halfLength = (s.stop + c.front - s.shiftTo) / 2
    local bad = boxGround(J.x + ux * mid + gx * bias, J.z + uz * mid + gz * bias, ux, uz, c.trainHalf, halfLength, bias - c.trainHalf > 1)
    if bad == nil and s.shiftTo - s.shiftFrom > 0.5 then
        mid = (s.shiftFrom + s.shiftTo) / 2
        bad = boxGround(J.x + ux * mid + gx * bias / 2, J.z + uz * mid + gz * bias / 2, ux, uz, c.trainHalf + bias / 2, (s.shiftTo - s.shiftFrom) / 2, false)
    end
    if bad == nil then
        mid = (s.stop - 4 + s.stop + c.front) / 2
        local off = bias + c.trainHalf + swing / 2
        bad = boxGround(J.x + ux * mid + gx * off, J.z + uz * mid + gz * off, ux, uz, swing / 2, (c.front + 4) / 2, off - swing / 2 > 1)
    end
    if bad ~= nil then
        return nil, string.format("%s : %s sur la bande décalée", where, bad)
    end
    local hit, name = ADHeaderFlow.backInTrainHit(t, job, lane, s, s.shiftFrom, c.trainHalf, swing)
    if hit then
        return nil, string.format("%s : objet fixe sur la bande décalée (%s)", where, tostring(name))
    end
    -- la caisse de la remorque pendant la marche arrière : objets fixes, sol
    hit, name = ADHeaderFlow.backInSweepHit(t, job, { rig = rig, theta = c.theta, ux = ux, uz = uz, nx = gx, nz = gz,
        qx = s.qx, qz = s.qz, ax = p.ax, az = p.az, reach = s.reach })
    if hit then
        return nil, string.format("%s : objet fixe là où la remorque recule (%s)", where, tostring(name))
    end
    for _, f in ipairs(ADHeaderFlow.BACKIN_SWEEP) do
        local phi = c.theta * f
        local tfx, tfz = math.cos(phi) * ux - math.sin(phi) * gx, math.cos(phi) * uz - math.sin(phi) * gz
        local tlx, tlz = tfz, -tfx
        local axX, axZ = s.qx + p.ax * s.reach * f, s.qz + p.az * s.reach * f
        local rx, rz = axX - rig.rx * tlx - rig.rz * tfx, axZ - rig.rx * tlz - rig.rz * tfz
        bad = boxGround(rx, rz, tfx, tfz, c.trailerWidth / 2, c.trailerLength / 2, false)
        if bad ~= nil then
            return nil, string.format("%s : %s là où la remorque recule", where, bad)
        end
    end
    local uFrameE = c.uFrame
    local plan = { j = info.j, cut = cut, routeFrom = uCut + ADHeaderFlow.BACKIN_ROUTE_STEP, jid = J.id, jx = J.x, jz = J.z, ux = ux, uz = uz,
        nx = gx, nz = gz, points = info.points, lengths = info.lengths, qx = s.qx, qz = s.qz, ax = p.ax, az = p.az, reach = s.reach,
        start = ADHeaderFlow.BACKIN_START, stop = s.stop,
        frame = { x = p.frameX, y = groundY(p.frameX, p.frameZ), z = p.frameZ, dirX = c.fx, dirZ = c.fz },
        past = uFrameE - info.uE, depth = c.nFrame, before = info.before, rig = rig, entrance = { x = info.E.x, z = info.E.z },
        bias = bias, shiftFrom = s.shiftFrom, shiftTo = s.shiftTo, cross = true, angle = c.angle }
    -- la moissonneuse a sa courbe du chemin jusqu'au cadre (ni culture, ni champ du côté de l'herbe, ni eau, ni marche)
    local laneC, laneWhy = ADHeaderFlow.backInLane(plan, plan.frame)
    if laneC == nil then
        return nil, string.format("%s : %s", where, tostring(laneWhy))
    end
    -- ... sans objet fixe sur la courbe, une fois hors du chemin
    local hx, hz = J.x + ux * laneC.handover, J.z + uz * laneC.handover
    local path = ADHeaderFlow.backInPath(laneC, hx, hz, ux, uz, plan.frame)
    if path ~= nil then
        local half = rig.cw / 2 + ADHeaderFlow.CROSS_MARGIN
        local done = 0
        for k = 2, #path do
            local a, b = path[k - 1], path[k]
            local dx, dz = unit(b.x - a.x, b.z - a.z)
            done = done + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
            local across = (b.x - J.x) * gx + (b.z - J.z) * gz
            if dx ~= nil and done >= ADHeaderFlow.CROSS_CURVE_STEP and across >= half then
                done = 0
                local blocked = boxBlocked(t, job, b.x, b.z, dx, dz, half, ADHeaderFlow.CROSS_CURVE_STEP / 2)
                if blocked ~= nil then
                    return nil, string.format("%s : %s sur la courbe de la moissonneuse", where, blocked)
                end
            end
        end
    end
    plan.turn = laneC.turn
    -- barre prise : la moissonneuse va au champ par le chemin, jusqu'à l'entrée (la barre y passe)
    if ADHeaderFlow.afterPickupOk ~= nil then
        local points = {}
        local d = c.uFrame
        while d < info.uE do
            points[#points + 1] = { x = J.x + ux * d, z = J.z + uz * d }
            d = d + ADHeaderFlow.ROAD_STEP
        end
        points[#points + 1] = { x = info.E.x, z = info.E.z }
        if #points >= 2 then
            local ok, pickupWhy = ADHeaderFlow.afterPickupOk(t, job, nil, points, 1, 0)
            if not ok then
                return nil, string.format("%s : %s", where, tostring(pickupWhy))
            end
        end
    end
    return plan
end

-- ------------------------------------------------------------------------------------------------------------
-- En route vers le champ : la route du tracteur passe la place, puis la marche arrière (AutonomousHeaderBackIn.lua)
-- ------------------------------------------------------------------------------------------------------------
-- true = route changée (même suite que la marche arrière dans le champ : mode.headerBackIn, startBackIn)
function ADHeaderFlow.crossTry(mode, job, wayPoints, current)
    if not ADHeaderFlow.CROSS or ADHeaderBackInTask == nil then
        return false
    end
    local t = mode.vehicle
    local ok, plan, why = FarmPilotCall(ADHeaderFlow.crossPlan, t, job, wayPoints, current)
    if not ok then
        log("ERREUR barre en travers du chemin : %s", tostring(plan))
        return false
    end
    if plan == nil then
        log("%s : pas de barre en travers du chemin (%s)", nameOf(t), tostring(why))
        return false
    end
    for k = #wayPoints, plan.cut + 1, -1 do
        wayPoints[k] = nil
    end
    for _, p in ipairs(ADHeaderFlow.backInRoute(plan)) do
        wayPoints[#wayPoints + 1] = p
    end
    mode.headerBackIn = plan
    job.fieldSpot = { x = plan.entrance.x, z = plan.entrance.z } -- les autres endroits sont cherchés autour de l'entrée
    log("%s : champ fermé ou cadre côté champ, la remorque sera reculée en travers du chemin %.0f m avant l'entrée, à %.0f° (cadre à %.1f m du chemin dans l'herbe, virage de %.0f° pour la moissonneuse) ; arrêt %.0f m %s l'entrée, décalé de %.1f m vers l'herbe",
        nameOf(t), -plan.past, plan.angle, plan.depth, plan.turn, math.abs(plan.stop), plan.stop < 0 and "avant" or "après", plan.bias)
    return true
end
