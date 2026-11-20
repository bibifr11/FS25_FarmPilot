-- ============================================================================================================
-- FarmPilot : AutonomousMassAuto.lua
-- Mode Autonome : « Masse auto », la masse avant suit le poids de l'outil (17/11).
--
-- Règle :
-- - Ligne « Outil avant » sur « Masse auto » (dernier choix de la liste). Une masse ou un outil avant choisi à la
--   main passe toujours avant : c'est lui qui est pris (le choix « Masse auto » est alors enlevé).
-- - Masse conseillée pour l'outil de la ligne « Outil » (ou celui attelé), mêmes règles que le bloc « Masse avant »
--   d'AutoSwitch : outil porté = tracteur lesté seul à 45 % sur l'avant ; semi-porté 50 % et traîné 60 % avec la
--   charge au crochet ; benne / remorque 50 % ; 30 % pour un 2 roues motrices ; au transport, outil levé, au moins
--   30 % sur l'avant ; la plus exigeante, arrondie à 50 kg au-dessus. Le poids de l'outil est connu avant de l'atteler.
-- - Outil dont le poids change avec la charge (benne, remorque, tonne, semoir, pulvé...) : calcul à moitié plein,
--   le juste milieu entre vide et plein.
-- - Choix : il garde sa masse (ou rien) si elle est à TOLERANCES[1] kg ou moins de la conseillée. Sinon la plus
--   proche à 500 kg près ; s'il n'y en a pas, à 750 kg, puis à 1 t (à égalité : celle attelée, puis la plus lourde).
--   « Pas de masse » compte comme une masse de 0 kg. Rien à 1 t près : il garde la sienne (journal).
-- - Masses possibles : celles posées dans une zone des masses (MassZoneManager.lua), dételées, de la ferme, qui
--   s'attellent à l'avant de ce tracteur, et qu'aucun autre tracteur ne va chercher.
-- - Échange : la masse attelée est posée dans une place libre de la zone la plus proche (par la route de la
--   destination de la zone, puis le nez en avant), puis la nouvelle est attelée (par la route de la zone), puis
--   l'outil arrière comme avant. Pas de place libre : il garde sa masse. Pas de zone : il garde sa masse.
-- - Un outil avant de travail attelé (faucheuse frontale...) : rien ne change. Moissonneuse : jamais.
-- - (20/11) Fin de travail : la masse est gardée pendant tout le travail, puis rangée à la fin. Au retour, l'outil
--   arrière est posé à sa place (comme avant), puis la masse va dans une place libre de la zone la plus proche de la
--   place du tracteur (par la route de la zone, nez en avant, recul), puis le tracteur se gare. Zones pleines (ou pas
--   de zone) : il garde sa masse et le dit au journal. Masse choisie à la main (pas « Masse auto ») : reste attelée.
--
-- Branché par enveloppes (posées au chargement) : ADFrontFlow.checkStart (le choix), ADFrontFlow.startDropAt
-- (route de la zone d'abord), ADFrontFlow.fetchRoutePoint (masse dans une zone : par la route de la zone),
-- ADFrontFlow.parkWithFront (fin de travail : masse rangée).
-- Chargé par register.lua après AutonomousFront.lua et MassZoneManager.lua.
-- ============================================================================================================

ADMassAuto = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADMassAuto.TOLERANCES = { 500, 750, 1000 }   -- kg : écart accepté, palier par palier
ADMassAuto.CIBLE = { porte = 0.45, semiPorte = 0.50, traine = 0.60, remorque = 0.50 } -- part sur l'avant (AutoSwitch)
ADMassAuto.CIBLE_2RM = 0.30                  -- tracteur 2 roues motrices : au travail (AutoSwitch)
ADMassAuto.TRANSPORT = 0.30                  -- outil levé : au moins ça sur l'avant
ADMassAuto.LOAD_SHARE = 0.5                  -- outil à charge variable : calculé à moitié plein
ADMassAuto.LOAD_MIN = 0.1                    -- t : cuve plus légère pleine (ficelle, film, AdBlue) : pas comptée
ADMassAuto.ROUTE_NEAR = 30                   -- m de la destination de la zone : plus de route, directement

local function log(fmt, ...)
    ADAutonomousManager.log("[Masse auto] " .. fmt, ...)
end

local function nameOf(vehicle)
    return tostring(vehicle.ad.stateModule:getName())
end

local function kgText(kg)
    local s = tostring(math.floor((kg or 0) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^ ", ""))
end

local function label(o)
    if o == nil then
        return "pas de masse"
    end
    local ok, l = FarmPilotCall(ADAutonomousManager.frontLabel, o)
    return ok and tostring(l) or ADAutonomousManager.toolLabel(o)
end

-- ------------------------------------------------------------------------------------------------------------
-- Calcul (repris du bloc « Masse avant » d'AutoSwitch, Ballast.lua) : moments au pont arrière du tracteur
--   tr = { masse, zG, zAv, zAr } (t, m) ; charges = { { m, z } } outils arrière ; zLest : centre de la masse avant
-- ------------------------------------------------------------------------------------------------------------
function ADMassAuto.solve(tr, charges, zLest, kind)
    local Lb = tr.zAv - tr.zAr
    if Lb < 0.5 or kind == nil then
        return nil
    end
    local function frontOf(m, z)
        return m * (z - tr.zAr) / Lb
    end
    local avSeul, totSeul = frontOf(tr.masse, tr.zG), tr.masse
    local avArr, totArr = avSeul, totSeul
    for _, c in ipairs(charges) do
        avArr, totArr = avArr + frontOf(c.m, c.z), totArr + c.m
    end
    local k = (zLest - tr.zAr) / Lb
    local function lestPour(a0, t0, r)
        if k - r <= 0.05 then
            return 0
        end
        return (r * t0 - a0) / (k - r)
    end
    local r = ADMassAuto.CIBLE[kind] or 0.45
    if tr.quatreRM == false then
        r = ADMassAuto.CIBLE_2RM
    end
    local bTravail
    if kind == "porte" then
        bTravail = lestPour(avSeul, totSeul, r)
    else
        bTravail = lestPour(avArr, totArr, r)
    end
    local bTransport = lestPour(avArr, totArr, ADMassAuto.TRANSPORT)
    local b = math.max(bTravail, bTransport, 0)
    return math.ceil(b * 1000 / 50 - 1e-6) * 50, bTransport > bTravail and "transport" or "travail"
end

-- ------------------------------------------------------------------------------------------------------------
-- Lecture du jeu
-- ------------------------------------------------------------------------------------------------------------
local function zIn(ref, node, x, y, z)
    local wx, wy, wz = localToWorld(node, x or 0, y or 0, z or 0)
    local _, _, lz = worldToLocal(ref, wx, wy, wz)
    return lz
end

local function refOf(v)
    return v.rootNode or (v.components ~= nil and v.components[1] ~= nil and v.components[1].node) or nil
end

-- masse à vide (t) et centre de gravité z (repère ref) d'un véhicule ; empty : sans le contenu des cuves
local function ownMass(v, ref, empty)
    local m, mz = 0, 0
    for _, c in ipairs(v.components or {}) do
        if c.node ~= nil and c.node ~= 0 then
            local cm = (empty and c.defaultMass) or (v.getComponentMass ~= nil and v:getComponentMass(c)) or c.mass or c.defaultMass or 0
            if cm > 0 then
                local cx, cy, cz = getCenterOfMass(c.node)
                m, mz = m + cm, mz + cm * zIn(ref, c.node, cx, cy, cz)
            end
        end
    end
    if m <= 0 then
        return 0, 0
    end
    return m, mz / m
end

-- t de charge quand l'outil est plein (cuves de plus de LOAD_MIN t)
function ADMassAuto.fullLoad(tool)
    if tool.getFillUnits == nil or g_fillTypeManager == nil then
        return 0
    end
    local total = 0
    for index, unit in pairs(tool:getFillUnits() or {}) do
        local cap = (tool.getFillUnitCapacity ~= nil and tool:getFillUnitCapacity(index)) or unit.capacity or 0
        local ft = tool.getFillUnitFillType ~= nil and tool:getFillUnitFillType(index) or nil
        if ft == nil or ft == 0 or (FillType ~= nil and ft == FillType.UNKNOWN) then
            local supported = tool.getFillUnitSupportedFillTypes ~= nil and tool:getFillUnitSupportedFillTypes(index) or {}
            for f, ok in pairs(supported) do
                if ok then
                    ft = f
                    break
                end
            end
        end
        local desc = ft ~= nil and g_fillTypeManager:getFillTypeByIndex(ft) or nil
        local mpl = desc ~= nil and desc.massPerLiter or 0
        local t = cap * mpl
        if t >= ADMassAuto.LOAD_MIN then
            total = total + t
        end
    end
    return total
end

local function wheelNodes(v)
    local out = {}
    local wheels = v.spec_wheels ~= nil and v.spec_wheels.wheels or nil
    for _, w in ipairs(wheels or {}) do
        local node = w.repr or w.driveNode or w.node
        if node ~= nil and node ~= 0 then
            out[#out + 1] = node
        end
    end
    return out
end

-- 4 roues motrices ? true / false, nil si illisible (compté 4 roues motrices) ; mêmes différentiels lus que le bloc
-- « Masse avant » d'AutoSwitch (Transmission.lua)
function ADMassAuto.is4wd(v)
    local sm = v.spec_motorized
    local diffs = sm ~= nil and sm.differentials or nil
    local ws = v.spec_wheels
    local ref = refOf(v)
    if type(diffs) ~= "table" or #diffs == 0 or ws == nil or ws.wheels == nil or ref == nil then
        return nil
    end
    local referenced = {}
    for _, d in ipairs(diffs) do
        if d.diffIndex1IsWheel ~= true and type(d.diffIndex1) == "number" then referenced[d.diffIndex1 + 1] = true end
        if d.diffIndex2IsWheel ~= true and type(d.diffIndex2) == "number" then referenced[d.diffIndex2 + 1] = true end
    end
    local root
    for i = 1, #diffs do
        if not referenced[i] then
            if root ~= nil then
                return nil
            end
            root = i
        end
    end
    if root == nil then
        return nil
    end
    local driven, visiting, valid = {}, {}, true
    local function walk(index, isWheel)
        if not valid or type(index) ~= "number" then
            valid = false
            return
        end
        if isWheel then
            driven[index] = true
            return
        end
        local i = index + 1
        local d = diffs[i]
        if d == nil or visiting[i] then
            valid = false
            return
        end
        visiting[i] = true
        walk(d.diffIndex1, d.diffIndex1IsWheel == true)
        walk(d.diffIndex2, d.diffIndex2IsWheel == true)
        visiting[i] = nil
    end
    walk(root - 1, false)
    if not valid then
        return nil
    end
    local zs, minZ, maxZ = {}, math.huge, -math.huge
    for i, w in ipairs(ws.wheels) do
        local node = w.repr or w.driveNode or w.node
        if node ~= nil and node ~= 0 then
            local z = zIn(ref, node)
            zs[i] = z
            minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
        end
    end
    if maxZ - minZ < 0.5 then
        return nil
    end
    local mid = (minZ + maxZ) / 2
    local front, rear = false, false
    for i in pairs(driven) do
        if zs[i] == nil then
            return nil
        end
        if zs[i] >= mid then front = true else rear = true end
    end
    if not front and not rear then
        return nil
    end
    return front and rear
end

-- type d'attelage de l'outil : porte / semiPorte / traine / remorque
local function kindOf(tool, input)
    local jt = input ~= nil and input.jointType or nil
    if AttacherJoints ~= nil and jt ~= nil and jt == AttacherJoints.JOINTTYPE_IMPLEMENT then
        return "porte"
    end
    if tool.spec_trailer ~= nil then
        return "remorque"
    end
    if AttacherJoints ~= nil and AttacherJoints.JOINTTYPE_SEMIMOUNTED ~= nil and jt == AttacherJoints.JOINTTYPE_SEMIMOUNTED then
        return "semiPorte"
    end
    if #wheelNodes(tool) == 0 then
        return "porte"
    end
    return "traine"
end

-- masse avant conseillée (kg) pour cet outil attelé à l'arrière de ce tracteur ; info pour le journal ; nil si
-- le calcul est impossible
function ADMassAuto.advisedKg(vehicle, tool)
    local ref = refOf(vehicle)
    local wheels = wheelNodes(vehicle)
    if ref == nil or #wheels < 2 or tool == nil then
        return nil, "tracteur sans roues ou sans outil"
    end
    local zAv, zAr = -math.huge, math.huge
    for _, node in ipairs(wheels) do
        local z = zIn(ref, node)
        zAv, zAr = math.max(zAv, z), math.min(zAr, z)
    end
    if zAv - zAr < 0.5 then
        return nil, "empattement inconnu"
    end
    local m, zG = ownMass(vehicle, ref, false)
    if m <= 0 then
        return nil, "masse du tracteur inconnue"
    end
    local okW, fourWd = FarmPilotCall(ADMassAuto.is4wd, vehicle)
    local tr = { masse = m, zG = zG, zAv = zAv, zAr = zAr, quatreRM = not (okW and fourWd == false) }
    -- outil : point d'attelage arrière du tracteur, son point d'attelage, son centre de gravité et ses roues (dans son repère)
    local _, joint, _, input = ADAutonomousManager.matchJoints(vehicle, tool, false)
    if joint == nil or joint.jointTransform == nil or input == nil or input.node == nil then
        return nil, "pas d'attelage arrière pour l'outil"
    end
    local tref = refOf(tool)
    local tm, tzG = ownMass(tool, tref, true)
    local load = ADMassAuto.fullLoad(tool)
    local half = load * ADMassAuto.LOAD_SHARE
    tm = tm + half -- (la charge au centre de gravité de l'outil)
    if tm <= 0 then
        return nil, "masse de l'outil inconnue"
    end
    local zH = zIn(ref, joint.jointTransform)
    local tzJ = zIn(tref, input.node)
    local kind = kindOf(tool, input)
    local charge
    if kind == "porte" then
        charge = { m = tm, z = zH - (tzJ - tzG) }
    else
        local tw = wheelNodes(tool)
        local sz = 0
        for _, node in ipairs(tw) do
            sz = sz + zIn(tref, node)
        end
        local tzW = #tw > 0 and sz / #tw or tzG
        local bras = tzW - tzJ
        local part = math.abs(bras) < 0.05 and 0 or math.max(0, math.min(1, (tzW - tzG) / bras))
        charge = { m = tm * part, z = zH }
    end
    -- centre de la masse avant : 0,4 m devant l'attelage avant (comme AutoSwitch)
    local zLest = zAv + 1.2
    for _, fj in ipairs(ADAutonomousManager.frontJoints(vehicle)) do
        if fj.joint.jointTransform ~= nil then
            zLest = zIn(ref, fj.joint.jointTransform) + 0.4
            break
        end
    end
    local kg, rule = ADMassAuto.solve(tr, { charge }, zLest, kind)
    if kg == nil then
        return nil, "calcul impossible"
    end
    local info = string.format("tracteur %.1f t%s, outil %s %.1f t%s (%.1f t sur le tracteur), règle %s", m, tr.quatreRM and "" or " (2 roues motrices)", kind, tm,
        load > 0 and string.format(" dont %.1f t de charge (moitié de %.1f t)", half, load) or "", charge.m, rule)
    return kg, info, kind
end

-- ------------------------------------------------------------------------------------------------------------
-- Choix de la masse
-- ------------------------------------------------------------------------------------------------------------
-- masse visée par un autre tracteur (en route pour l'atteler, ou choisie à la main)
local function reservedByOther(vehicle, mass)
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    for _, v in pairs(system ~= nil and system.vehicles or {}) do
        if v ~= vehicle and v.ad ~= nil and v.ad.stateModule ~= nil then
            local mode = v.ad.modes ~= nil and v.ad.modes[AutoDrive.MODE_AUTONOMOUS] or nil
            if mode ~= nil and mode.fetchTool == mass and v.ad.stateModule:isActive() then
                return true
            end
            if v.ad.stateModule.getFpFrontTool ~= nil and v.ad.stateModule:getFpFrontTool() == mass then
                return true
            end
        end
    end
    return false
end

-- masses des zones que ce tracteur peut prendre : { { tool, kg, zone } }
function ADMassAuto.zoneMasses(vehicle, zones)
    local out = {}
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    for _, v in pairs(system ~= nil and system.vehicles or {}) do
        if ADAutonomousManager.isMass(v) then
            local okF, fetchable = FarmPilotCall(ADAutonomousManager.isFetchableFront, vehicle, v)
            if okF and fetchable then
                local zone = ADMassZone.zoneOf(v, zones)
                if zone ~= nil and not reservedByOther(vehicle, v) then
                    out[#out + 1] = { tool = v, kg = ADAutonomousManager.massKg(v) or 0, zone = zone }
                end
            end
        end
    end
    return out
end

-- la meilleure parmi les candidates (palier par palier), ou nil, palier
function ADMassAuto.pick(candidates, advised)
    for _, tol in ipairs(ADMassAuto.TOLERANCES) do
        local best, bestD = nil, nil
        for _, c in ipairs(candidates) do
            local d = math.abs(c.kg - advised)
            if d <= tol then
                local better = best == nil or d < bestD - 0.5
                if not better and best ~= nil and math.abs(d - bestD) <= 0.5 then
                    -- égalité : celle attelée, puis la plus lourde
                    if c.current and not best.current then
                        better = true
                    elseif c.current == best.current and c.kg > best.kg then
                        better = true
                    end
                end
                if better then
                    best, bestD = c, d
                end
            end
        end
        if best ~= nil then
            return best, tol
        end
    end
    return nil, nil
end

-- outil de la ligne « Outil » (sinon celui attelé)
local function rearTool(vehicle)
    if ADSeederManager ~= nil and ADSeederManager.rowTool ~= nil then
        return ADSeederManager.rowTool(vehicle, false)
    end
    return vehicle.ad.stateModule:getFpTool()
end

-- nil = « Masse auto » pas choisie ; sinon { action = keep / fetch / swap / drop, why, fetch, drop, slot, zone, advised }
function ADMassAuto.decide(vehicle)
    local sm = vehicle.ad.stateModule
    if sm.getFpFrontAuto == nil or not sm:getFpFrontAuto() then
        return nil
    end
    if ADHeaderFlow ~= nil and ADHeaderFlow.isCombine ~= nil and ADHeaderFlow.isCombine(vehicle) then
        return nil
    end
    local current = ADAutonomousManager.frontObject(vehicle)
    if current ~= nil and not ADAutonomousManager.isMass(current) then
        return { action = "keep", why = string.format("outil avant attelé (%s)", label(current)) }
    end
    local tool = rearTool(vehicle)
    if tool == nil then
        return { action = "keep", why = "pas d'outil sur la ligne « Outil »" }
    end
    local okA, advised, info = FarmPilotCall(ADMassAuto.advisedKg, vehicle, tool)
    if not okA then
        log("ERREUR calcul : %s", tostring(advised))
        advised = nil
    end
    if advised == nil then
        return { action = "keep", why = "masse conseillée inconnue (" .. tostring(info) .. ")" }
    end
    local curKg = current ~= nil and (ADAutonomousManager.massKg(current) or 0) or 0
    local d = { advised = advised, info = info, toolLabel = ADAutonomousManager.toolLabel(tool), currentKg = curKg }
    if math.abs(curKg - advised) <= ADMassAuto.TOLERANCES[1] then
        d.action, d.why = "keep", string.format("%s attelée, à %s kg près", label(current), kgText(math.abs(curKg - advised)))
        return d
    end
    local zones = ADMassZone.list()
    if #zones == 0 then
        d.action, d.why = "keep", "pas de zone des masses (bouton « Zone des masses » de la destination)"
        return d
    end
    local candidates = { { tool = current, kg = curKg, current = true } }
    if current ~= nil then
        candidates[#candidates + 1] = { tool = nil, kg = 0 } -- pas de masse : poser la sienne
    end
    for _, c in ipairs(ADMassAuto.zoneMasses(vehicle, zones)) do
        candidates[#candidates + 1] = c
    end
    local best, tol = ADMassAuto.pick(candidates, advised)
    if best == nil then
        d.action, d.why = "keep", "aucune masse de la zone à 1 t près"
        return d
    end
    d.tolerance = tol
    if best.current then
        d.action, d.why = "keep", string.format("%s attelée reste la plus proche (palier %s kg)", label(current), kgText(tol))
        return d
    end
    if current ~= nil then
        -- la masse attelée va dans une place libre de la zone la plus proche (celle de la nouvelle masse d'abord)
        local order = {}
        if best.zone ~= nil then
            order[1] = best.zone
        end
        local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
        table.sort(zones, function(a, b)
            return MathUtil.vector2Length(a.wp.x - vx, a.wp.z - vz) < MathUtil.vector2Length(b.wp.x - vx, b.wp.z - vz)
        end)
        for _, g in ipairs(zones) do
            if g ~= best.zone then
                order[#order + 1] = g
            end
        end
        for _, g in ipairs(order) do
            local p = ADMassZone.freePlace(g, { vehicle, current })
            if p ~= nil then
                d.slot, d.zone = p, g
                break
            end
        end
        if d.slot == nil then
            d.action, d.why = "keep", "pas de place libre dans la zone des masses pour poser " .. label(current)
            return d
        end
    end
    d.fetch, d.drop = best.tool, current
    d.action = best.tool == nil and "drop" or (current ~= nil and "swap" or "fetch")
    d.why = string.format("%s à %s kg près (palier %s kg)", label(best.tool), kgText(math.abs(best.kg - advised)), kgText(tol))
    return d
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes
-- ------------------------------------------------------------------------------------------------------------
-- place de la zone pour la dépose : même forme que ADFrontFlow.parkSlot (attelage avant du tracteur à l'arrivée,
-- direction de la place vers la sortie) ; entry : m devant la place où le chemin arrive ; massZone : la zone
function ADMassAuto.dropSlot(vehicle, d)
    local p = d.slot
    local slot = { x = p.x, y = p.y, z = p.z, dirX = p.dirX, dirZ = p.dirZ, entry = ADMassZone.ENTRY, massZone = d.zone }
    local len = (vehicle.size ~= nil and vehicle.size.length) or 6
    local ml = (d.drop ~= nil and d.drop.size ~= nil and d.drop.size.length) or 1
    return slot, len + ml + ADMassZone.EXIT_MARGIN
end

-- (20/11) fin de travail : place libre pour ranger la masse attelée ; { slot, back, zone } ou nil, pourquoi
-- near : { x, z } d'où chercher la zone la plus proche (place du tracteur, sinon le tracteur)
function ADMassAuto.endDrop(vehicle, near)
    local sm = vehicle.ad.stateModule
    if sm.getFpFrontAuto == nil or not sm:getFpFrontAuto() then
        return nil, "« Masse auto » pas choisie"
    end
    if ADHeaderFlow ~= nil and ADHeaderFlow.isCombine ~= nil and ADHeaderFlow.isCombine(vehicle) then
        return nil, "moissonneuse"
    end
    local current = ADAutonomousManager.frontObject(vehicle)
    if current == nil or not ADAutonomousManager.isMass(current) then
        return nil, "pas de masse attelée"
    end
    local zones = ADMassZone.list()
    if #zones == 0 then
        return nil, "pas de zone des masses"
    end
    table.sort(zones, function(a, b)
        return MathUtil.vector2Length(a.wp.x - near.x, a.wp.z - near.z) < MathUtil.vector2Length(b.wp.x - near.x, b.wp.z - near.z)
    end)
    for _, g in ipairs(zones) do
        local p = ADMassZone.freePlace(g, { vehicle, current })
        if p ~= nil then
            local slot, back = ADMassAuto.dropSlot(vehicle, { slot = p, zone = g, drop = current })
            return { slot = slot, back = back, zone = g, mass = current }
        end
    end
    return nil, "toutes les places des zones des masses sont prises"
end

function ADMassAuto.install()
    if ADFrontFlow == nil or ADMassAuto.installed then
        return
    end
    ADMassAuto.installed = true

    -- départ : le choix de la masse
    local baseCheckStart = ADFrontFlow.checkStart
    function ADFrontFlow.checkStart(mode)
        local vehicle = mode.vehicle
        local ok, d = FarmPilotCall(ADMassAuto.decide, vehicle)
        if not ok then
            log("ERREUR choix de la masse : %s", tostring(d))
            return baseCheckStart(mode)
        end
        if d == nil then
            return baseCheckStart(mode)
        end
        local name = nameOf(vehicle)
        if d.advised ~= nil then
            log("%s : « %s », masse conseillée %s kg (%s), attelée %s kg", name, tostring(d.toolLabel), kgText(d.advised), tostring(d.info), kgText(d.currentKg))
        end
        if d.action == "keep" then
            log("%s : masse gardée : %s", name, tostring(d.why))
            return nil, nil
        end
        log("%s : %s : %s", name, d.action == "drop" and "masse posée" or "change de masse", tostring(d.why))
        if d.action == "drop" then
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 10000, "AD_autonomous_massAutoDrop", kgText(d.advised), label(d.drop))
        else
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 10000, "AD_autonomous_massAutoSwap", kgText(d.advised), label(d.fetch))
        end
        local plan = { fetch = d.fetch }
        if d.drop ~= nil then
            plan.drop = d.drop
            plan.dropMass = false -- posée dans la zone : pas reprise en fin de travail
            plan.dropSlot, plan.dropBack = ADMassAuto.dropSlot(vehicle, d)
            plan.dropPlace = d.zone.name
        end
        return nil, plan
    end

    -- dépose dans la zone : par la route de la destination de la zone d'abord (comme l'entrée le nez en avant)
    local baseStartDropAt = ADFrontFlow.startDropAt
    function ADFrontFlow.startDropAt(mode, tool, slot, placeName, back)
        local zone = slot ~= nil and slot.massZone or nil
        if zone ~= nil then
            local vehicle = mode.vehicle
            local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
            if MathUtil.vector2Length(vx - zone.wp.x, vz - zone.wp.z) > ADMassAuto.ROUTE_NEAR then
                mode.parkStage = "noseRoute"
                mode.parkTool = tool
                mode.parkSide = "front"
                mode.backOffDistance = back
                mode.noseDrop = { tool = tool, slot = slot, placeName = placeName }
                log("%s : « %s » va dans la zone des masses « %s » par la route", nameOf(vehicle), label(tool), tostring(placeName))
                AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_frontDropAt", label(tool), tostring(placeName))
                mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, zone.wp.id)
                if ADDriveGoal ~= nil then ADDriveGoal.set(mode.driveToDestinationTask, "AD_fpGoal_toolPark", placeName) end -- but affiché dans l'ATH, voir DriveGoal.lua
                vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
                return
            end
        end
        return baseStartDropAt(mode, tool, slot, placeName, back)
    end

    -- (20/11) fin de travail : outil arrière à sa place, masse rangée dans une zone, tracteur garé
    local baseParkWithFront = ADFrontFlow.parkWithFront
    function ADFrontFlow.parkWithFront(vehicle, forcedTool)
        local handled = baseParkWithFront(vehicle, forcedTool)
        if handled ~= nil or (forcedTool ~= nil and ADAutonomousManager.isMass(forcedTool)) then
            return handled
        end
        local sm = vehicle.ad.stateModule
        if sm.getFpFrontAuto == nil or not sm:getFpFrontAuto() then
            return nil
        end
        local current = ADAutonomousManager.frontObject(vehicle)
        if current == nil or not ADAutonomousManager.isMass(current) then
            return nil
        end
        local name = nameOf(vehicle)
        -- outil arrière : mêmes conditions que la fin de travail habituelle (sinon comme avant : message, rien)
        local tools = forcedTool ~= nil and { forcedTool } or ADAutonomousManager.workTools(vehicle)
        local rear = tools[1]
        local attacher = rear ~= nil and rear.getAttacherVehicle ~= nil and rear:getAttacherVehicle() or nil
        local rearPark = rear ~= nil and rear.advd ~= nil and rear.advd.parkDestination or -1
        local rearMarker = rearPark ~= nil and rearPark >= 1 and ADGraphManager:getMapMarkerById(rearPark) or nil
        if #tools ~= 1 or attacher ~= vehicle or rearMarker == nil then
            return nil
        end
        local tractorPark = vehicle.advd ~= nil and vehicle.advd.parkDestination or -1
        local tractorMarker = tractorPark ~= nil and tractorPark >= 1 and tractorPark ~= rearPark and ADGraphManager:getMapMarkerById(tractorPark) or nil
        if tractorMarker == nil then
            return nil
        end
        local twp = ADGraphManager:getWayPointById(tractorMarker.id)
        local near
        if twp ~= nil and twp.x ~= nil then
            near = { x = twp.x, z = twp.z }
        else
            local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
            near = { x = vx, z = vz }
        end
        local ok, drop, why = FarmPilotCall(ADMassAuto.endDrop, vehicle, near)
        if not ok then
            log("ERREUR rangement de la masse : %s", tostring(drop))
            return nil
        end
        if drop == nil then
            log("%s : fin de travail, masse « %s » gardée : %s", name, label(current), tostring(why))
            return nil
        end
        log("%s : fin de travail, masse « %s » rangée dans la zone « %s »", name, label(current), tostring(drop.zone.name))
        local steps = {
            { kind = "drop", tool = rear, marker = rearMarker, side = "rear" },
            { kind = "drop", tool = drop.mass, side = "front", slot = drop.slot, placeName = drop.zone.name, back = drop.back },
            { kind = "park", marker = tractorMarker },
        }
        return ADFrontFlow.runQueue(vehicle, steps, tractorMarker)
    end

    -- masse posée dans une zone : par la route de la destination de la zone
    local baseFetchRoutePoint = ADFrontFlow.fetchRoutePoint
    function ADFrontFlow.fetchRoutePoint(vehicle, tool)
        if ADAutonomousManager.isMass(tool) then
            local zone = ADMassZone.zoneOf(tool)
            if zone ~= nil then
                local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
                if MathUtil.vector2Length(vx - zone.wp.x, vz - zone.wp.z) > ADMassAuto.ROUTE_NEAR then
                    log("%s : « %s » est dans la zone des masses « %s » : par la route de la zone", nameOf(vehicle), label(tool), tostring(zone.name))
                    return zone.wp, "front"
                end
                return nil
            end
        end
        return baseFetchRoutePoint(vehicle, tool)
    end
end

ADMassAuto.install()
