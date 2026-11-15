-- ============================================================================================================
-- FarmPilot : GateManager.lua
-- Portails et portes sur la route : ouverture, attente, passage, fermeture après l'attelage, véhicule qui suit.
--
-- (15/11) Un véhicule FarmPilot roulait droit dans un portail fermé et restait bloqué contre. Les portails
-- (objets animés de la carte ou posés, liste et géométrie dans GateRegistry.lua) sont maintenant gérés en conduite.
--
-- Règles :
-- - Portail FERMÉ (ou en fermeture) sur la route, à moins de LOOK_AHEAD m de route devant le nez : FarmPilot
--   l'ouvre, ralentit à SLOW_SPEED, s'arrête à « longueur du battant + STOP_MARGIN » tant qu'il n'est pas ouvert,
--   passe, puis le REFERME une fois tout l'attelage sorti de la zone de balayage des battants.
-- - Portail déjà OUVERT, ou en train de s'ouvrir, par quelqu'un d'autre : laissé ouvert, jamais refermé.
-- - Pas de fermeture tant qu'un autre véhicule FarmPilot a le portail devant lui (il prend le relais et refermera
--   après lui), ni tant qu'un véhicule, quel qu'il soit (attelages compris), est dans la zone de balayage.
-- - Portail que FarmPilot ne peut pas ouvrir (désactivé, autre ferme) : ignoré.
-- - Serveur seulement (l'animation est synchronisée aux clients par l'objet animé lui-même). Pas de réglage.
-- - Le drapeau « ouvert par FarmPilot » (obj.fpOpened) est sauvegardé par GateRegistry.lua : un portail ouvert
--   par FarmPilot au moment de la sauvegarde est refermé au chargement si personne n'est dessus.
--
-- Branché par : AutoDrive.lua (ADGates.update à chaque image), DrivePathModule.lua (vitesse maxi),
-- register.lua (chargé après GateRegistry.lua).
-- ============================================================================================================

ADGates = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADGates.LOOK_AHEAD = 50         -- m de route devant le nez
ADGates.SLOW_SPEED = 10         -- km/h vers un portail pas encore ouvert
ADGates.STOP_MARGIN = 1.5       -- m : arrêt du nez à « longueur du battant + marge » tant que ce n'est pas ouvert
ADGates.UPDATE_MS = 250         -- ms entre deux passes
ADGates.CLEAR_MARGIN = 0.5      -- m : marge autour de la zone de balayage avant de refermer
ADGates.NEAR_RANGE = 30         -- m : portails examinés à moins de LOOK_AHEAD + NEAR_RANGE du nez
ADGates.LEAF_EXTEND = 0.5       -- m : battant prolongé à chaque bout pour le croisement
ADGates.DEFAULT_RADIUS = 3      -- m : rayon d'un véhicule sans dimensions

ADGates.timer = 0

-- portail (objet animé) -> { [véhicule] = true } : véhicules FarmPilot qui ont le portail devant eux
-- clés faibles : un objet ou un véhicule supprimé disparaît tout seul
ADGates.claims = setmetatable({}, { __mode = "k" })
-- portail (objet animé) -> état interne : dernier record, journal (une fois par changement d'état)
ADGates.states = setmetatable({}, { __mode = "k" })

local function weakTable()
    return setmetatable({}, { __mode = "k" })
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonctions pures (aucune fonction moteur)
-- ------------------------------------------------------------------------------------------------------------
-- croisement des segments AB et CD : t (0..1 sur AB) ou nil
function ADGates.segIntersect(ax, az, bx, bz, cx, cz, dx, dz)
    local rx, rz = bx - ax, bz - az
    local sx, sz = dx - cx, dz - cz
    local denom = rx * sz - rz * sx
    if math.abs(denom) < 1e-9 then
        return nil -- parallèles (ou segment nul)
    end
    local qx, qz = cx - ax, cz - az
    local t = (qx * sz - qz * sx) / denom
    local u = (qx * rz - qz * rx) / denom
    if t < 0 or t > 1 or u < 0 or u > 1 then
        return nil
    end
    return t
end

-- distance de route du nez au premier croisement d'un battant (prolongé) du portail, ou nil
local function crossGate(gate, ax, az, bx, bz)
    local best = nil
    if gate == nil or gate.leaves == nil then
        return nil
    end
    local ext = ADGates.LEAF_EXTEND
    for _, leaf in ipairs(gate.leaves) do
        local lx, lz = leaf.tx - leaf.hx, leaf.tz - leaf.hz
        local len = math.sqrt(lx * lx + lz * lz)
        if len > 1e-6 then
            local ux, uz = lx / len * ext, lz / len * ext
            local t = ADGates.segIntersect(ax, az, bx, bz, leaf.hx - ux, leaf.hz - uz, leaf.tx + ux, leaf.tz + uz)
            if t ~= nil and (best == nil or t < best) then
                best = t
            end
        end
    end
    return best
end

-- polyligne nez -> wayPoints[index] -> [index+1]..., coupée à lookAhead m
-- -> liste triée par distance { {gate = gate, dist = m}, ... } (un portail au plus une fois)
function ADGates.routeCrossings(fx, fz, wayPoints, index, gates, lookAhead)
    local result = {}
    if wayPoints == nil or gates == nil or index == nil or #gates == 0 then
        return result
    end
    lookAhead = lookAhead or ADGates.LOOK_AHEAD
    local found = {}
    local ax, az = fx, fz
    local travelled = 0
    local k = index
    while wayPoints[k] ~= nil and travelled < lookAhead do
        local wp = wayPoints[k]
        if wp.x ~= nil and wp.z ~= nil then
            local bx, bz = wp.x, wp.z
            local segLen = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
            if segLen > 1e-6 then
                if travelled + segLen > lookAhead then
                    local f = (lookAhead - travelled) / segLen
                    bx, bz = ax + (bx - ax) * f, az + (bz - az) * f
                    segLen = lookAhead - travelled
                end
                for _, gate in ipairs(gates) do
                    if found[gate] == nil then
                        local t = crossGate(gate, ax, az, bx, bz)
                        if t ~= nil then
                            found[gate] = true
                            table.insert(result, { gate = gate, dist = travelled + t * segLen })
                        end
                    end
                end
                travelled = travelled + segLen
                ax, az = bx, bz
            end
        end
        k = k + 1
    end
    table.sort(result, function(a, b) return a.dist < b.dist end)
    return result
end

-- ------------------------------------------------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------------------------------------------------
local function isServer()
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil then
        return g_currentMission:getIsServer()
    end
    return g_server ~= nil
end

local function log(fmt, ...)
    print("[FarmPilot Portails] " .. string.format(fmt, ...))
end

local function vehicleName(v)
    if v ~= nil and v.ad ~= nil and v.ad.stateModule ~= nil and v.ad.stateModule.getName ~= nil then
        local name = v.ad.stateModule:getName()
        if name ~= nil then
            return tostring(name)
        end
    end
    if v ~= nil and v.getName ~= nil then
        return tostring(v:getName())
    end
    return "?"
end

local function gateName(gate)
    return tostring(gate ~= nil and gate.name or "?")
end

local function isGone(obj)
    return obj == nil or obj.isDeleted == true or obj.isDeleting == true
end

local function farmIdOf(v)
    if v.ad ~= nil and v.ad.stateModule ~= nil and v.ad.stateModule.getActualFarmId ~= nil then
        local farmId = v.ad.stateModule:getActualFarmId()
        if farmId ~= nil then
            return farmId
        end
    end
    if v.getOwnerFarmId ~= nil then
        return v:getOwnerFarmId()
    end
    return nil
end

local function getState(gate)
    local obj = gate.obj
    local st = ADGates.states[obj]
    if st == nil then
        st = { vlog = weakTable() }
        ADGates.states[obj] = st
    end
    st.gate = gate
    return st
end

-- journal d'un couple véhicule / portail, seulement quand l'état change
local function logVehicle(gate, v, state, fmt, ...)
    local st = getState(gate)
    if st.vlog[v] ~= state then
        st.vlog[v] = state
        log(fmt, ...)
    end
end

-- en train de s'ouvrir (pas encore ouvert) : lu sur l'animation de l'objet, protégé
local function isOpening(gate)
    local anim = gate.obj ~= nil and gate.obj.animation or nil
    return anim ~= nil and anim.direction ~= nil and anim.direction > 0
end

local function isOpenOrOpening(gate)
    return ADGateRegistry.isOpen(gate) or isOpening(gate)
end

local function noseOf(v)
    local node = v.ad ~= nil and v.ad.frontNode or nil
    if node == nil and v.components ~= nil and v.components[1] ~= nil then
        node = v.components[1].node
    end
    if node == nil or getWorldTranslation == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

-- centre et rayon (demi-diagonale) d'un véhicule ou d'un outil
local function bodyOf(v)
    if v.components == nil or v.components[1] == nil or v.components[1].node == nil then
        return nil
    end
    local node = v.components[1].node
    local radius = ADGates.DEFAULT_RADIUS
    local offset = 0
    if v.size ~= nil and v.size.length ~= nil and v.size.width ~= nil then
        radius = 0.5 * math.sqrt(v.size.length * v.size.length + v.size.width * v.size.width)
        offset = v.size.lengthOffset or 0
    end
    local x, z
    if offset ~= 0 and localToWorld ~= nil then
        local wx, _, wz = localToWorld(node, 0, 0, offset)
        x, z = wx, wz
    else
        local wx, _, wz = getWorldTranslation(node)
        x, z = wx, wz
    end
    return x, z, radius
end

-- un véhicule du jeu (attelages compris) dans la zone de balayage des battants ? -> véhicule ou nil
local function vehicleInSweep(gate)
    local reach = gate.reach or 0
    for _, v in pairs(AutoDrive.getAllVehicles()) do
        if not isGone(v) then
            local x, z, radius = bodyOf(v)
            if x ~= nil then
                local limit = reach + radius + ADGates.CLEAR_MARGIN
                for _, leaf in ipairs(gate.leaves or {}) do
                    local dx, dz = x - leaf.hx, z - leaf.hz
                    if dx * dx + dz * dz < limit * limit then
                        return v
                    end
                end
            end
        end
    end
    return nil
end

local function hasClaims(obj)
    local c = ADGates.claims[obj]
    if c ~= nil then
        for v in pairs(c) do
            return true, v
        end
    end
    return false, nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Passe principale (AutoDrive:update, serveur seulement, toutes les UPDATE_MS)
-- ------------------------------------------------------------------------------------------------------------
function ADGates.update(dt)
    if ADGateRegistry == nil or not isServer() then
        return
    end
    ADGates.timer = ADGates.timer + (dt or 0)
    if ADGates.timer < ADGates.UPDATE_MS then
        return
    end
    ADGates.timer = 0

    local gates = ADGateRegistry.getGates() or {}
    for _, gate in ipairs(gates) do
        if gate.obj ~= nil and ADGates.states[gate.obj] ~= nil then
            ADGates.states[gate.obj].gate = gate -- record le plus récent (recalcul de la géométrie)
        end
    end

    -- 1. véhicules FarmPilot actifs : portails devant eux
    local forward = {}   -- véhicule -> { [obj] = true } portails devant lui à cette passe
    local reversing = {} -- véhicule -> true : en marche arrière, claims gardées telles quelles
    local nearRange = ADGates.LOOK_AHEAD + ADGates.NEAR_RANGE
    for _, v in pairs(AutoDrive.getAllVehicles()) do
        local ad = v.ad
        local dpm = ad ~= nil and ad.drivePathModule or nil
        if not isGone(v) and ad ~= nil and ad.stateModule ~= nil and ad.stateModule:isActive()
            and dpm ~= nil and dpm.wayPoints ~= nil and #dpm.wayPoints > 0 then
            if dpm.getIsReversing ~= nil and dpm:getIsReversing() then
                reversing[v] = true
            else
                local fx, fz = noseOf(v)
                if fx ~= nil then
                    local near = {}
                    for _, gate in ipairs(gates) do
                        if not isGone(gate.obj) and gate.cx ~= nil then
                            local dx, dz = gate.cx - fx, gate.cz - fz
                            if dx * dx + dz * dz < nearRange * nearRange then
                                table.insert(near, gate)
                            end
                        end
                    end
                    local crossings = {}
                    if #near > 0 then
                        crossings = ADGates.routeCrossings(fx, fz, dpm.wayPoints, dpm:getCurrentWayPointIndex(), near, ADGates.LOOK_AHEAD)
                    end
                    ad.fpGates = crossings
                    ad.fpGatesNose = { x = fx, z = fz }
                    local ahead = {}
                    forward[v] = ahead
                    local farmId = farmIdOf(v)
                    for _, c in ipairs(crossings) do
                        local gate, obj = c.gate, c.gate.obj
                        ahead[obj] = true
                        getState(gate)
                        if ADGates.claims[obj] == nil then
                            ADGates.claims[obj] = weakTable()
                        end
                        ADGates.claims[obj][v] = true
                        if ADGateRegistry.isOpen(gate) or (isOpening(gate) and not ADGateRegistry.isClosing(gate)) then
                            if obj.fpOpened then
                                if not ADGateRegistry.isOpen(gate) and c.dist <= (gate.reach or 0) + ADGates.STOP_MARGIN then
                                    logVehicle(gate, v, "wait", "%s attend ouverture : %s (%.1f m)", vehicleName(v), gateName(gate), c.dist)
                                end
                            else
                                logVehicle(gate, v, "leave", "%s laisse ouvert (ouvert par quelqu'un d'autre) : %s (%.1f m)", vehicleName(v), gateName(gate), c.dist)
                            end
                        elseif ADGateRegistry.canOperate(gate, farmId) then
                            ADGateRegistry.open(gate)
                            obj.fpOpened = true
                            getState(gate).closeLogged = nil
                            logVehicle(gate, v, "open", "%s ouvre : %s (%.1f m)", vehicleName(v), gateName(gate), c.dist)
                        else
                            logVehicle(gate, v, "denied", "%s ne peut pas ouvrir : %s (%.1f m)", vehicleName(v), gateName(gate), c.dist)
                        end
                    end
                end
            end
        end
        if ad ~= nil and forward[v] == nil and not reversing[v] then
            ad.fpGates = nil
            ad.fpGatesNose = nil
        end
    end

    -- 2. claims qui ne tiennent plus : portail plus devant, véhicule arrêté, désactivé ou supprimé
    for obj, list in pairs(ADGates.claims) do
        local st = ADGates.states[obj]
        for v in pairs(list) do
            local keep = not isGone(v) and (reversing[v] or (forward[v] ~= nil and forward[v][obj]))
            if not keep then
                list[v] = nil
                if st ~= nil then
                    st.vlog[v] = nil
                    if obj.fpOpened then
                        st.passedBy = v
                    end
                end
            end
        end
        if isGone(obj) or next(list) == nil then
            ADGates.claims[obj] = nil
        end
    end

    -- 3. fermeture des portails ouverts par FarmPilot, une fois libres
    for _, gate in ipairs(gates) do
        local obj = gate.obj
        if obj ~= nil and obj.fpOpened and not isGone(obj) then
            local st = getState(gate)
            local claimed, other = hasClaims(obj)
            if claimed then
                if st.passedBy ~= nil and st.comingLogged ~= other then
                    st.comingLogged = other
                    log("%s ne referme pas : %s arrive", gateName(gate), vehicleName(other))
                end
            elseif not isOpenOrOpening(gate) then
                -- refermé par quelqu'un d'autre entre-temps : plus rien à faire
                obj.fpOpened = false
                st.passedBy, st.comingLogged = nil, nil
            elseif vehicleInSweep(gate) == nil then
                ADGateRegistry.close(gate)
                obj.fpOpened = false
                log("referme : %s%s", gateName(gate), st.passedBy ~= nil and (" (après " .. vehicleName(st.passedBy) .. ")") or "")
                st.passedBy, st.comingLogged = nil, nil
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Conduite (DrivePathModule.lua) : vitesse maxi vers un portail pas encore ouvert ; math.huge ailleurs
-- ------------------------------------------------------------------------------------------------------------
function ADGates.getSpeedLimit(drivePathModule)
    local v = drivePathModule ~= nil and drivePathModule.vehicle or nil
    local list = v ~= nil and v.ad ~= nil and v.ad.fpGates or nil
    if list == nil or #list == 0 or ADGateRegistry == nil then
        return math.huge
    end
    if drivePathModule.getIsReversing ~= nil and drivePathModule:getIsReversing() then
        return math.huge
    end
    -- distance faite depuis la dernière passe (jusqu'à UPDATE_MS de retard)
    local moved = 0
    local nose = v.ad.fpGatesNose
    if nose ~= nil then
        local fx, fz = noseOf(v)
        if fx ~= nil then
            moved = math.sqrt((fx - nose.x) ^ 2 + (fz - nose.z) ^ 2)
        end
    end
    local farmId = farmIdOf(v)
    for _, c in ipairs(list) do
        local gate = c.gate
        if not isGone(gate.obj) and not ADGateRegistry.isOpen(gate) and ADGateRegistry.canOperate(gate, farmId) then
            local dist = c.dist - moved
            if dist <= (gate.reach or 0) + ADGates.STOP_MARGIN then
                return 0
            elseif dist <= ADGates.LOOK_AHEAD then
                return ADGates.SLOW_SPEED
            end
            return math.huge
        end
    end
    return math.huge
end
