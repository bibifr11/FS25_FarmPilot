-- ============================================================================================================
-- FarmPilot : AutonomousHeaderMount.lua
-- Mode Autonome, moissonneuse ou ensileuse équipée seule (12/11) : où la barre de coupe se pose sur sa remorque
-- porte-barre, et dans quel sens.
--
-- Règle (12/11) :
-- - Place de la barre (lockPose), dans cet ordre :
--   1. la barre est posée sur la remorque (pas attelée) : là où elle est ;
--   2. la place prévue par le jeu pour ce modèle : côté barre (Mountable, lockPosition), puis côté remorque
--      (DynamicMountAttacher, lockPosition ; même choix de configuration que le jeu) ;
--   3. là où elle était sur cette remorque quand la moissonneuse l'a prise (gardé en mémoire, pas dans la
--      sauvegarde) : une barre d'un autre modèle que ceux prévus par la remorque y retourne au même endroit ;
--   4. au jugé : la place d'une autre barre de cette remorque (même sens pour toutes), sinon le point de blocage
--      général, l'avant de la barre vers la droite de la remorque (sens habituel des remorques porte-barre).
-- - Avant de la barre : l'axe de son cadre d'attelage vers son corps (pas l'axe de sa racine : un mod peut décrire
--   la barre en long, dans le sens du transport).
-- - Profondeur et envergure de la barre (headerBox) : la plus petite et la plus grande des deux dimensions du jeu.
-- - Le cadre d'attelage d'une barre est toujours un attelage avant (enveloppe de ADAutonomousManager.isFrontInput).
--
-- Branché par : Modes/AutonomousHeader.lua (startHeaderFetch : rememberMount ; findEmptyTrailer, étape « drop » :
-- lockPose, headerBox), Modes/AutonomousHeaderSpot.lua (trainModel, onArrival, isSideFree), Modes/
-- AutonomousHeaderGround.lua (headerBox), Tasks/HeaderDropTask.lua (spotFor, goalFor). Chargé par register.lua après
-- AutonomousHeader.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.DEFAULT_HEADER_SPAN = 9  -- m : envergure de la barre quand le jeu ne la donne pas

-- ------------------------------------------------------------------------------------------------------------
-- Petits outils
-- ------------------------------------------------------------------------------------------------------------
local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function label(o)
    return o ~= nil and ADAutonomousManager.toolLabel(o) or "?"
end

local function endsWith(s, suffix)
    return type(s) == "string" and type(suffix) == "string" and #suffix > 0 and s:sub(-#suffix) == suffix
end

local function attacherOf(o)
    if o ~= nil and o.getAttacherVehicle ~= nil then
        return o:getAttacherVehicle()
    end
    return nil
end

-- la barre est sur la remorque (bloquée, ou posée et pas encore bloquée, ou (15/11) décrochée mais toujours posée
-- dessus : AutonomousHeader.lua, holds)
local function holds(trailer, object)
    if ADHeaderFlow.holds ~= nil then
        return ADHeaderFlow.holds(trailer, object)
    end
    local s = trailer.spec_dynamicMountAttacher
    return (s.dynamicMountedObjects ~= nil and s.dynamicMountedObjects[object] ~= nil)
        or (s.pendingDynamicMountObjects ~= nil and s.pendingDynamicMountObjects[object] ~= nil)
end

-- ------------------------------------------------------------------------------------------------------------
-- Dimensions et sens de la barre
-- ------------------------------------------------------------------------------------------------------------
-- profondeur (dans l'axe de la moissonneuse) et envergure de la barre, en m. Les dimensions du jeu sont prises dans
-- cet ordre quel que soit le sens où le mod les donne (barre décrite en long, comme sur sa remorque)
function ADHeaderFlow.headerBox(header)
    local size = header ~= nil and header.size or nil
    local w, l = size ~= nil and size.width or nil, size ~= nil and size.length or nil
    if w == nil or l == nil then
        return l or 3, w or ADHeaderFlow.DEFAULT_HEADER_SPAN
    end
    return math.min(w, l), math.max(w, l)
end

-- avant de la barre dans son propre repère (x, y, z) : l'axe de son cadre d'attelage vers son corps ; (0, 0, 1)
-- quand le jeu ne le dit pas
local function frontLocal(header)
    local inputs = header ~= nil and header.spec_attachable ~= nil and header.spec_attachable.inputAttacherJoints or nil
    local root = header ~= nil and header.components ~= nil and header.components[1] ~= nil and header.components[1].node or nil
    if inputs ~= nil and root ~= nil then
        for _, input in ipairs(inputs) do
            if input.node ~= nil and ADAutonomousManager.isFrontInput(header, input) then
                local x, y, z = localDirectionToLocal(input.node, root, 1, 0, 0)
                if x ~= nil and MathUtil.vector2Length(x, z) > 0.5 then
                    return x, y, z
                end
            end
        end
    end
    return 0, 0, 1
end

-- { x, y, z, dirX, dirZ } depuis un point et un sens (monde), ou nil
local function poseAt(x, y, z, dx, dz, exact, how)
    local len = dx ~= nil and MathUtil.vector2Length(dx, dz) or 0
    if x == nil or len < 0.001 then
        return nil
    end
    return { x = x, y = y, z = z, dirX = dx / len, dirZ = dz / len, exact = exact, how = how }
end

-- la partie de la remorque qui porte la barre (repère de la mémoire)
local function bedNode(trailer)
    local s = trailer.spec_dynamicMountAttacher
    local trigger = s ~= nil and s.dynamicMountAttacherTrigger or nil
    if trigger ~= nil and trigger.rootNode ~= nil then
        return trigger.rootNode
    end
    return trailer.components[1].node
end

-- ------------------------------------------------------------------------------------------------------------
-- Mémoire : où la barre était sur sa remorque
-- ------------------------------------------------------------------------------------------------------------
-- là où chaque barre était sur sa remorque quand la moissonneuse l'a prise (clés faibles : barre vendue = oubliée)
ADHeaderFlow.mounts = setmetatable({}, { __mode = "k" })

function ADHeaderFlow.rememberMount(trailer, header)
    if trailer == nil or header == nil or header.components == nil then
        return
    end
    local bed = bedNode(trailer)
    local root = header.components[1].node
    local wx, wy, wz = getWorldTranslation(root)
    local x, y, z = worldToLocal(bed, wx, wy, wz)
    local fx, fy, fz = frontLocal(header)
    local dwx, dwy, dwz = localDirectionToWorld(root, fx, fy, fz)
    local dx, _, dz = worldDirectionToLocal(bed, dwx, dwy, dwz)
    ADHeaderFlow.mounts[header] = { trailer = trailer, x = x, y = y, z = z, dx = dx, dz = dz }
    log("« %s » prise sur « %s » : sa place est gardée en mémoire (%.1f m devant, %.1f m à gauche, sens %.0f°)", label(header), label(trailer), z, x,
        math.deg(math.atan2(dx, dz)))
end

-- ------------------------------------------------------------------------------------------------------------
-- Places prévues par le jeu
-- ------------------------------------------------------------------------------------------------------------
-- place prévue par la barre pour cette remorque (jeu : Mountable, lockPosition côté barre)
local function headerSidePose(trailer, header, fx, fy, fz)
    if header.getMountableLockPositions == nil or I3DUtil == nil or I3DUtil.indexToObject == nil then
        return nil
    end
    local ok, positions = FarmPilotCall(header.getMountableLockPositions, header)
    if not ok or type(positions) ~= "table" then
        return nil
    end
    for _, p in ipairs(positions) do
        if endsWith(trailer.configFileName, p.xmlFilename) and p.jointNode ~= nil then
            local okN, node = FarmPilotCall(I3DUtil.indexToObject, trailer.components, p.jointNode, trailer.i3dMappings)
            if okN and node ~= nil and node ~= 0 then
                local t = p.transOffset or { 0, 0, 0 }
                local r = p.rotOffset or { 0, 0, 0 }
                local x, y, z = localToWorld(node, t[1] or 0, t[2] or 0, t[3] or 0)
                -- avant de la barre, tournée de rotOffset dans le repère du point
                local lx, ly, lz = fx, fy, fz
                if mathEulerRotateVector ~= nil then
                    lx, ly, lz = mathEulerRotateVector(r[1] or 0, r[2] or 0, r[3] or 0, fx, fy, fz)
                else
                    local c, sn = math.cos(r[2] or 0), math.sin(r[2] or 0)
                    lx, lz = fx * c + fz * sn, fz * c - fx * sn
                end
                local dx, _, dz = localDirectionToWorld(node, lx, ly, lz)
                local pose = poseAt(x, y, z, dx, dz, true, "prévue par la barre")
                if pose ~= nil then
                    return pose
                end
            end
        end
    end
    return nil
end

-- place prévue par la remorque pour cette barre (jeu : DynamicMountAttacher, lockPosition ; même choix de
-- configuration que le jeu) ; 2e valeur : une place d'une autre barre (pour le sens, au jugé)
local function trailerSidePose(s, header, fx, fy, fz)
    local other = nil
    for _, p in ipairs(s.lockPositions or {}) do
        if p.jointNode ~= nil then
            other = other or p
            if endsWith(header.configFileName, p.xmlFilename) then
                local fits = true
                for configName, configIndex in pairs(p.configurations or {}) do
                    fits = fits and (header.configurations == nil or header.configurations[configName] == configIndex)
                end
                if fits then
                    local x, y, z = getWorldTranslation(p.jointNode)
                    local dx, _, dz = localDirectionToWorld(p.jointNode, fx, fy, fz)
                    local pose = poseAt(x, y, z, dx, dz, true, "prévue par la remorque")
                    if pose ~= nil then
                        return pose, other
                    end
                end
            end
        end
    end
    return nil, other
end

-- ------------------------------------------------------------------------------------------------------------
-- Place de la barre sur la remorque (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
-- position de la barre sur la remorque : { x, y, z, dirX, dirZ (avant de la barre), exact, how } ; exact = place
-- sûre (barre posée dessus, ou place prévue par le jeu) ; how : d'où vient la place (journal)
function ADHeaderFlow.lockPose(trailer, header)
    local s = trailer ~= nil and trailer.spec_dynamicMountAttacher or nil
    if s == nil then
        return nil
    end
    local hasHeader = header ~= nil and header.components ~= nil and header.components[1] ~= nil
    local fx, fy, fz = 0, 0, 1
    if hasHeader then
        fx, fy, fz = frontLocal(header)
        -- 1) la barre est sur la remorque (pas attelée) : là où elle est
        if attacherOf(header) == nil and holds(trailer, header) then
            local root = header.components[1].node
            local x, y, z = getWorldTranslation(root)
            local dx, _, dz = localDirectionToWorld(root, fx, fy, fz)
            local pose = poseAt(x, y, z, dx, dz, true, "posée")
            if pose ~= nil then
                return pose
            end
        end
        -- 2) place prévue par la barre, 3) par la remorque
        local pose = headerSidePose(trailer, header, fx, fy, fz)
        if pose ~= nil then
            return pose
        end
    end
    local other = nil
    if hasHeader then
        local pose
        pose, other = trailerSidePose(s, header, fx, fy, fz)
        if pose ~= nil then
            return pose
        end
        -- 4) là où elle était sur cette remorque
        local m = ADHeaderFlow.mounts[header]
        if m ~= nil and m.trailer == trailer then
            local bed = bedNode(trailer)
            local x, y, z = localToWorld(bed, m.x, m.y, m.z)
            local dx, _, dz = localDirectionToWorld(bed, m.dx, 0, m.dz)
            pose = poseAt(x, y, z, dx, dz, false, "gardée en mémoire")
            if pose ~= nil then
                pose.remembered = true
                return pose
            end
        end
    else
        for _, p in ipairs(s.lockPositions or {}) do
            if p.jointNode ~= nil then
                other = p
                break
            end
        end
    end
    -- 5) au jugé : la place d'une autre barre de cette remorque (même sens pour toutes), sinon le point de blocage
    -- général, l'avant de la barre vers la droite de la remorque (sens habituel des remorques porte-barre)
    if other ~= nil then
        local x, y, z = getWorldTranslation(other.jointNode)
        local dx, _, dz = localDirectionToWorld(other.jointNode, 0, 0, 1)
        local pose = poseAt(x, y, z, dx, dz, false, "au jugé (place d'une autre barre)")
        if pose ~= nil then
            return pose
        end
    end
    local node = s.dynamicMountAttacherTrigger ~= nil and s.dynamicMountAttacherTrigger.jointNode or nil
    if node == nil then
        return nil
    end
    local x, y, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(bedNode(trailer), -1, 0, 0)
    return poseAt(x, y, z, dx, dz, false, "au jugé (point de blocage)")
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppe (posée au chargement)
-- ------------------------------------------------------------------------------------------------------------
-- le cadre d'attelage d'une barre va toujours à l'avant, même quand le mod décrit la barre en long (sens de transport)
local baseIsFrontInput = ADAutonomousManager.isFrontInput
function ADAutonomousManager.isFrontInput(tool, input)
    if tool ~= nil and tool.spec_cutter ~= nil and input ~= nil and input.jointType ~= nil and AttacherJoints ~= nil
        and input.jointType == AttacherJoints.JOINTTYPE_CUTTER then
        return true
    end
    return baseIsFrontInput(tool, input)
end
