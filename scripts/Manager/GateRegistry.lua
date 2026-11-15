-- ============================================================================================================
-- FarmPilot : GateRegistry.lua
-- Registre des portails : liste des objets animés qui sont des portails ou des portes, géométrie de leurs
-- battants en position fermée, ouverture / fermeture, et mémoire « ouvert par FarmPilot » dans la sauvegarde.
--
-- (15/11) Un véhicule FarmPilot passait à travers un portail fermé (ou s'y bloquait). Le registre donne à la
-- logique de conduite (GateManager.lua) la position des battants, l'état du portail, et de quoi l'ouvrir et le
-- refermer.
--
-- Règles :
-- - Portail / porte : objet animé (AnimatedObject) avec au moins une pièce animée, sans horaires d'ouverture
--   (openingHours), et commandé par le joueur (triggerNode ou action posAction).
-- - Géométrie calculée à la première demande puis gardée ; recalculée si le nœud racine a bougé de plus de 0,5 m.
-- - Battant : position FERMÉE (image clé de plus petit temps). Charnière = origine de la pièce dans son parent.
--   Centre du battant = centre de la Shape (ou de la Shape enfant la plus éloignée de l'origine à l'horizontale).
--   Bout = charnière + 2 x (centre - charnière). Battant de moins de 0,5 m ignoré.
-- - Aucun battant valable et au moins 2 pièces : segment entre les 2 charnières les plus éloignées (deux demi-
--   battants qui se rejoignent au milieu). Rien du tout : pas de portail (journal une fois).
-- - Ouvert : temps d'animation >= 0,99 et pas en fermeture. Ouvrir / fermer : serveur seulement, même méthode
--   que les horaires d'ouverture du jeu (direction + raiseActive, synchronisé aux clients par le jeu).
-- - Sauvegarde : obj.fpOpened (ouvert par FarmPilot, à refermer) écrit en #farmPilotOpened, relu au chargement.
-- - Toute erreur sur un portail est attrapée : elle ne casse jamais le chargement de la carte.
--
-- Branché par : register.lua (chargement du fichier), GateManager.lua (utilisation). Les enveloppes de
-- AnimatedObject (load, delete, saveToXMLFile, loadFromXMLFile) sont posées ici, au chargement du fichier.
-- ============================================================================================================

ADGateRegistry = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADGateRegistry.MOVE_RECALC = 0.5            -- m : nœud racine déplacé de plus -> géométrie recalculée
ADGateRegistry.MIN_LEAF = 0.5               -- m : battant plus court ignoré
ADGateRegistry.MAX_CHILD_NODES = 40         -- nœuds enfants parcourus au plus par battant
ADGateRegistry.OPEN_TIME = 0.99             -- temps d'animation (0..1) à partir duquel le portail est ouvert
ADGateRegistry.LOG_PREFIX = "[FarmPilot Portails] "

ADGateRegistry.entries = {}                 -- { {obj=, gate=, rootX=, rootZ=, failed=, injected=} }
ADGateRegistry.byObj = {}                   -- obj -> entrée

-- ------------------------------------------------------------------------------------------------------------
-- Helpers : appels protégés
-- ------------------------------------------------------------------------------------------------------------
local unpackf = table.unpack or unpack

local function safeCall(f, ...)
    if FarmPilotCall ~= nil then
        return FarmPilotCall(f, ...)
    end
    return pcall(f, ...)
end

-- appelle une fonction moteur ; renvoie ses valeurs, ou nil si elle manque ou a échoué
local function engine(f, ...)
    if f == nil then
        return nil
    end
    local function pack(...)
        return select("#", ...), { ... }
    end
    local n, r = pack(safeCall(f, ...))
    if not r[1] then
        return nil
    end
    return unpackf(r, 2, n)
end

local function log(text)
    print(ADGateRegistry.LOG_PREFIX .. text)
end

-- ------------------------------------------------------------------------------------------------------------
-- Reconnaissance
-- ------------------------------------------------------------------------------------------------------------
function ADGateRegistry.isGateObject(obj)
    if obj == nil or obj.animation == nil or obj.animation.parts == nil or #obj.animation.parts < 1 then
        return false
    end
    if obj.openingHours ~= nil then
        return false
    end
    local posAction = obj.controls ~= nil and obj.controls.posAction or nil
    return obj.triggerNode ~= nil or posAction ~= nil
end

function ADGateRegistry.register(obj)
    if obj == nil or ADGateRegistry.byObj[obj] ~= nil then
        return
    end
    if not ADGateRegistry.isGateObject(obj) then
        return
    end
    local entry = { obj = obj }
    ADGateRegistry.byObj[obj] = entry
    table.insert(ADGateRegistry.entries, entry)
end

function ADGateRegistry.unregister(obj)
    local entry = obj ~= nil and ADGateRegistry.byObj[obj] or nil
    if entry == nil then
        return
    end
    ADGateRegistry.byObj[obj] = nil
    for i = #ADGateRegistry.entries, 1, -1 do
        if ADGateRegistry.entries[i] == entry then
            table.remove(ADGateRegistry.entries, i)
        end
    end
end

-- simulation : injecte un portail déjà calculé (gate = { obj=, name=, cx=, cz=, leaves=, reach= }) ;
-- jamais recalculé. gate.obj peut être un objet factice ; sans obj, une table vide est créée.
function ADGateRegistry.addForTest(gate)
    if gate == nil then
        return nil
    end
    gate.obj = gate.obj or {}
    local old = ADGateRegistry.byObj[gate.obj]
    if old ~= nil then
        ADGateRegistry.unregister(gate.obj)
    end
    local entry = { obj = gate.obj, gate = gate, injected = true }
    ADGateRegistry.byObj[gate.obj] = entry
    table.insert(ADGateRegistry.entries, entry)
    return gate
end

-- simulation : vide le registre
function ADGateRegistry.reset()
    ADGateRegistry.entries = {}
    ADGateRegistry.byObj = {}
end

-- ------------------------------------------------------------------------------------------------------------
-- Géométrie : fonction pure (testable sans moteur)
-- ------------------------------------------------------------------------------------------------------------
-- hx, hz          : charnière en monde (origine de la pièce, position fermée)
-- lcx, lcz        : centre du battant dans le repère local de la pièce
-- ry              : rotation Y fermée de la pièce (radians)
-- tx, tz          : translation fermée de la pièce dans son parent
-- parentToWorld   : function(x, y, z) -> wx, wy, wz (repère parent -> monde) ; nil = identité
-- ty, lcy         : facultatifs (hauteur de la translation fermée et du centre), 0 par défaut
-- Renvoie leaf = { hx=, hz=, tx=, tz=, len= } (tx, tz = bout du battant en monde) et len ; nil si len < MIN_LEAF.
function ADGateRegistry.leafFromClosed(hx, hz, lcx, lcz, ry, tx, tz, parentToWorld, ty, lcy)
    if hx == nil or hz == nil or lcx == nil or lcz == nil then
        return nil, 0
    end
    ry, tx, tz, ty, lcy = ry or 0, tx or 0, tz or 0, ty or 0, lcy or 0
    -- convention Giants : x' = cos*x + sin*z ; z' = -sin*x + cos*z
    local c, s = math.cos(ry), math.sin(ry)
    local px = tx + c * lcx + s * lcz
    local py = ty + lcy
    local pz = tz - s * lcx + c * lcz
    local wx, wz
    if parentToWorld ~= nil then
        local x, _, z = parentToWorld(px, py, pz)
        wx, wz = x, z
    else
        wx, wz = px, pz
    end
    if wx == nil or wz == nil then
        return nil, 0
    end
    local ex, ez = hx + 2 * (wx - hx), hz + 2 * (wz - hz)
    local dx, dz = ex - hx, ez - hz
    local len = math.sqrt(dx * dx + dz * dz)
    if len < ADGateRegistry.MIN_LEAF then
        return nil, len
    end
    return { hx = hx, hz = hz, tx = ex, tz = ez, len = len }, len
end

-- ------------------------------------------------------------------------------------------------------------
-- Géométrie : lecture du moteur
-- ------------------------------------------------------------------------------------------------------------
-- image clé fermée d'une pièce : { x, y, z, rx, ry, rz, ... } (plus petit temps)
-- Le jeu vide part.frames après le chargement (les images passent dans part.animCurve) : on lit les deux.
local function closedFrame(part)
    local frames = part.frames
    if (frames == nil or #frames == 0) and part.animCurve ~= nil then
        frames = part.animCurve.keyframes
    end
    if frames ~= nil and #frames > 0 then
        local best = nil
        for _, f in ipairs(frames) do
            if best == nil or (f.time or 0) < (best.time or 0) then
                best = f
            end
        end
        return best
    end
    local curve = part.animCurve
    if curve ~= nil and curve.get ~= nil then
        local r = { safeCall(curve.get, curve, 0) }
        if r[1] then
            return { unpackf(r, 2, 11) }
        end
    end
    return nil
end

local function isShape(node)
    if getHasClassId == nil or ClassIds == nil or ClassIds.SHAPE == nil then
        return false
    end
    return engine(getHasClassId, node, ClassIds.SHAPE) == true
end

-- centre du battant dans le repère local de la pièce : x, y, z (ou nil)
local function leafCenterLocal(node)
    if isShape(node) then
        local x, y, z = engine(getShapeBoundingSphere, node)
        if x ~= nil and (x * x + z * z) >= (ADGateRegistry.MIN_LEAF * 0.5) ^ 2 then
            return x, y, z
        end
    end
    -- Shapes enfants : la plus éloignée de l'origine à l'horizontale
    local bestX, bestY, bestZ, bestD = nil, nil, nil, -1
    local queue, head, visited = { node }, 1, 0
    while head <= #queue and visited < ADGateRegistry.MAX_CHILD_NODES do
        local current = queue[head]
        head = head + 1
        local n = engine(getNumOfChildren, current) or 0
        for i = 0, n - 1 do
            if visited >= ADGateRegistry.MAX_CHILD_NODES then
                break
            end
            local child = engine(getChildAt, current, i)
            if child ~= nil and child ~= 0 then
                visited = visited + 1
                table.insert(queue, child)
                if isShape(child) then
                    local wx, wy, wz = engine(getShapeWorldBoundingSphere, child)
                    if wx ~= nil then
                        local lx, ly, lz = engine(worldToLocal, node, wx, wy, wz)
                        if lx ~= nil then
                            local d = lx * lx + lz * lz
                            if d > bestD then
                                bestX, bestY, bestZ, bestD = lx, ly, lz, d
                            end
                        end
                    end
                end
            end
        end
    end
    if bestX ~= nil then
        return bestX, bestY, bestZ
    end
    -- Shape dont le centre est près de l'origine et sans enfant utile : on garde son centre
    if isShape(node) then
        local x, y, z = engine(getShapeBoundingSphere, node)
        if x ~= nil then
            return x, y, z
        end
    end
    return nil
end

-- battant d'une pièce : leaf (ou nil), et charnière hx, hz (ou nil)
local function computeLeaf(part)
    local node = part.node
    if node == nil then
        return nil
    end
    local frame = closedFrame(part)
    if frame == nil or frame[1] == nil then
        return nil
    end
    local tx, ty, tz, ry = frame[1], frame[2] or 0, frame[3] or 0, frame[5] or 0
    local parent = engine(getParent, node)
    if parent == nil or parent == 0 then
        return nil
    end
    local hx, _, hz = engine(localToWorld, parent, tx, ty, tz)
    if hx == nil or hz == nil then
        return nil
    end
    local lcx, lcy, lcz = leafCenterLocal(node)
    if lcx == nil then
        return nil, hx, hz
    end
    local parentToWorld = function(x, y, z)
        return engine(localToWorld, parent, x, y, z)
    end
    local leaf = ADGateRegistry.leafFromClosed(hx, hz, lcx, lcz, ry, tx, tz, parentToWorld, ty, lcy)
    return leaf, hx, hz
end

-- record gate complet d'un objet animé, ou nil
function ADGateRegistry.computeGate(obj)
    local parts = obj.animation ~= nil and obj.animation.parts or nil
    if parts == nil then
        return nil
    end
    local leaves, hinges = {}, {}
    for _, part in ipairs(parts) do
        local ok, leaf, hx, hz = safeCall(computeLeaf, part)
        if ok then
            if leaf ~= nil then
                table.insert(leaves, leaf)
            end
            if hx ~= nil then
                table.insert(hinges, { x = hx, z = hz })
            end
        end
    end
    -- repli : segment entre les 2 charnières les plus éloignées, en deux demi-battants
    if #leaves == 0 and #parts >= 2 and #hinges >= 2 then
        local a, b, best = nil, nil, -1
        for i = 1, #hinges do
            for j = i + 1, #hinges do
                local dx, dz = hinges[j].x - hinges[i].x, hinges[j].z - hinges[i].z
                local d = dx * dx + dz * dz
                if d > best then
                    a, b, best = hinges[i], hinges[j], d
                end
            end
        end
        local half = math.sqrt(best) / 2
        if half >= ADGateRegistry.MIN_LEAF / 2 then
            local mx, mz = (a.x + b.x) / 2, (a.z + b.z) / 2
            table.insert(leaves, { hx = a.x, hz = a.z, tx = mx, tz = mz, len = half })
            table.insert(leaves, { hx = b.x, hz = b.z, tx = mx, tz = mz, len = half })
        end
    end
    if #leaves == 0 then
        return nil
    end
    local sx, sz, n, reach = 0, 0, 0, 0
    for _, leaf in ipairs(leaves) do
        sx = sx + leaf.hx + leaf.tx
        sz = sz + leaf.hz + leaf.tz
        n = n + 2
        reach = math.max(reach, leaf.len)
    end
    local cx, cz = sx / n, sz / n
    local base = (obj.nodeId ~= nil and engine(getName, obj.nodeId)) or obj.saveId or "portail"
    local name = string.format("%s (%.0f, %.0f)", tostring(base), cx, cz)
    return { obj = obj, name = name, cx = cx, cz = cz, leaves = leaves, reach = reach }
end

local function rootPosition(obj)
    if obj.nodeId == nil then
        return nil
    end
    local x, _, z = engine(getWorldTranslation, obj.nodeId)
    return x, z
end

-- ------------------------------------------------------------------------------------------------------------
-- Liste des portails
-- ------------------------------------------------------------------------------------------------------------
function ADGateRegistry.getGates()
    local gates = {}
    for _, entry in ipairs(ADGateRegistry.entries) do
        if entry.injected then
            table.insert(gates, entry.gate)
        else
            local x, z = rootPosition(entry.obj)
            local moved = entry.computed == nil
            if not moved and x ~= nil and entry.rootX ~= nil then
                local dx, dz = x - entry.rootX, z - entry.rootZ
                moved = dx * dx + dz * dz > ADGateRegistry.MOVE_RECALC * ADGateRegistry.MOVE_RECALC
            end
            if moved then
                entry.computed = true
                entry.rootX, entry.rootZ = x, z
                local ok, gate = safeCall(ADGateRegistry.computeGate, entry.obj)
                entry.gate = ok and gate or nil
                if entry.gate == nil and not entry.loggedFail then
                    entry.loggedFail = true
                    log(string.format("objet animé %s ignoré : aucun battant trouvé",
                        tostring(entry.obj.saveId or "?")))
                end
            end
            if entry.gate ~= nil then
                table.insert(gates, entry.gate)
            end
        end
    end
    return gates
end

-- ------------------------------------------------------------------------------------------------------------
-- État et commandes
-- ------------------------------------------------------------------------------------------------------------
local function animationOf(gate)
    return gate ~= nil and gate.obj ~= nil and gate.obj.animation or nil
end

function ADGateRegistry.isOpen(gate)
    local anim = animationOf(gate)
    if anim == nil then
        return false
    end
    return (anim.time or 0) >= ADGateRegistry.OPEN_TIME and (anim.direction or 0) >= 0
end

function ADGateRegistry.isClosing(gate)
    local anim = animationOf(gate)
    return anim ~= nil and (anim.direction or 0) < 0
end

function ADGateRegistry.canOperate(gate, farmId)
    local obj = gate ~= nil and gate.obj or nil
    if obj == nil or obj.isEnabled == false then
        return false
    end
    local handler = g_currentMission ~= nil and g_currentMission.accessHandler or nil
    if handler ~= nil and handler.canFarmAccessOtherId ~= nil and obj.getOwnerFarmId ~= nil then
        local ok, owner = safeCall(obj.getOwnerFarmId, obj)
        if not ok then
            return true
        end
        local ok2, allowed = safeCall(handler.canFarmAccessOtherId, handler, farmId, owner)
        if ok2 then
            return allowed == true
        end
    end
    return true
end

local function isServerObject(obj)
    if obj.isServer ~= nil then
        return obj.isServer == true
    end
    return g_server ~= nil
end

local function setDirection(gate, direction)
    local obj = gate ~= nil and gate.obj or nil
    if obj == nil or obj.animation == nil or not isServerObject(obj) then
        return false
    end
    obj.animation.direction = direction
    if obj.raiseActive ~= nil then
        safeCall(obj.raiseActive, obj)
    end
    return true
end

function ADGateRegistry.open(gate)
    return setDirection(gate, 1)
end

function ADGateRegistry.close(gate)
    return setDirection(gate, -1)
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes du jeu (AnimatedObject)
-- ------------------------------------------------------------------------------------------------------------
function ADGateRegistry.installHooks()
    if ADGateRegistry.hooksInstalled or AnimatedObject == nil or Utils == nil then
        return
    end
    ADGateRegistry.hooksInstalled = true

    if AnimatedObject.load ~= nil and Utils.overwrittenFunction ~= nil then
        AnimatedObject.load = Utils.overwrittenFunction(AnimatedObject.load, function(self, superFunc, ...)
            local success = superFunc(self, ...)
            if success then
                safeCall(ADGateRegistry.register, self)
            end
            return success
        end)
    end

    if AnimatedObject.delete ~= nil and Utils.appendedFunction ~= nil then
        AnimatedObject.delete = Utils.appendedFunction(AnimatedObject.delete, function(self)
            safeCall(ADGateRegistry.unregister, self)
        end)
    end

    if AnimatedObject.saveToXMLFile ~= nil and Utils.appendedFunction ~= nil then
        AnimatedObject.saveToXMLFile = Utils.appendedFunction(AnimatedObject.saveToXMLFile, function(self, xmlFile, key)
            if self.fpOpened and xmlFile ~= nil and xmlFile.handle ~= nil and key ~= nil and setXMLBool ~= nil then
                safeCall(setXMLBool, xmlFile.handle, key .. "#farmPilotOpened", true)
            end
        end)
    end

    if AnimatedObject.loadFromXMLFile ~= nil and Utils.overwrittenFunction ~= nil then
        AnimatedObject.loadFromXMLFile = Utils.overwrittenFunction(AnimatedObject.loadFromXMLFile,
            function(self, superFunc, xmlFile, key, ...)
                local result = superFunc(self, xmlFile, key, ...)
                if xmlFile ~= nil and xmlFile.handle ~= nil and key ~= nil and getXMLBool ~= nil then
                    local ok, value = safeCall(getXMLBool, xmlFile.handle, key .. "#farmPilotOpened")
                    self.fpOpened = ok and value == true
                end
                return result
            end)
    end
end

safeCall(ADGateRegistry.installHooks)
