-- ============================================================================================================
-- FarmPilot : AutonomousManagerFront.lua
-- Complément de AutonomousManagerTools.lua (mode Autonome) : l'attelage AVANT du tracteur (outils frontaux et
-- masses).
--
-- Règle (10/11) :
-- - Ligne « Outil avant » du HUD (et « Outil avant suivant ») : outils frontaux (faucheuse avant, cuve frontale,
--   rouleau avant...) par fonction et largeur, et masses par leur poids (« Masse (1 500 kg) »). Vide = celui attelé
--   (rien ne change).
-- - Outil frontal ou arrière : d'après le point d'attelage de l'outil. Son axe X part de l'attelage vers le corps de
--   l'outil : vers l'avant de l'outil = outil frontal (faucheuse avant, masse), vers l'arrière = outil arrière. Un
--   outil frontal n'apparaît plus dans la liste « Outil » (arrière), un outil arrière pas dans « Outil avant ».
-- - Masse = catégorie « weights » de la boutique.
-- - Les outils de travail attelés à l'avant ne comptent plus dans workTools (outil arrière) : l'outil arrière se
--   pose, s'échange et s'attelle comme avant, l'avant à part.
--
-- Branché par : AutonomousManagerTools.lua (workTools, matchJoints), Modes/AutonomousFront.lua (déroulement),
-- Tasks/FetchFrontToolTask.lua, Tasks/FrontPlaceTask.lua, Hud/PullDownList.lua (liste « Outil avant »),
-- Events/AutonomousToolEvent.lua (isFront).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAutonomousManager.FRONT_SHAPE_MIN = 0.5   -- axe du point d'attelage vers l'avant de l'outil à plus que ça = outil frontal
ADAutonomousManager.MASS_STEP = 50          -- kg : poids affiché arrondi à ça

-- ------------------------------------------------------------------------------------------------------------
-- Forme de l'outil : frontal ou arrière
-- ------------------------------------------------------------------------------------------------------------
-- > 0 : le corps de l'outil est devant son point d'attelage (outil frontal) ; < 0 : derrière (outil arrière) ;
-- nil si on ne sait pas
function ADAutonomousManager.inputShape(tool, input)
    if tool == nil or input == nil or input.node == nil or tool.components == nil or tool.components[1] == nil then
        return nil
    end
    local _, _, z = localDirectionToLocal(input.node, tool.components[1].node, 1, 0, 0)
    return z
end

function ADAutonomousManager.isFrontInput(tool, input)
    local z = ADAutonomousManager.inputShape(tool, input)
    return z ~= nil and z > ADAutonomousManager.FRONT_SHAPE_MIN
end

-- ------------------------------------------------------------------------------------------------------------
-- Attelages avant du tracteur
-- ------------------------------------------------------------------------------------------------------------
-- { index, joint } (libres ou non)
function ADAutonomousManager.frontJoints(vehicle)
    local out = {}
    local spec = vehicle ~= nil and vehicle.spec_attacherJoints or nil
    if spec == nil or spec.attacherJoints == nil then
        return out
    end
    for index, joint in ipairs(spec.attacherJoints) do
        local front = joint.attacherJointDirection == 1
        if joint.attacherJointDirection == nil and joint.jointTransform ~= nil then
            local _, _, z = localToLocal(joint.jointTransform, vehicle.components[1].node, 0, 0, 0)
            front = z > 0
        end
        if front then
            out[#out + 1] = { index = index, joint = joint }
        end
    end
    return out
end

function ADAutonomousManager.isFrontJointIndex(vehicle, index)
    if index == nil then
        return false
    end
    for _, fj in ipairs(ADAutonomousManager.frontJoints(vehicle)) do
        if fj.index == index then
            return true
        end
    end
    return false
end

-- le couple (attelage avant du tracteur, point d'attelage frontal de l'outil) de même type ; freeOnly : attelage libre
function ADAutonomousManager.matchFrontJoints(vehicle, tool, freeOnly)
    local inputs = tool ~= nil and tool.spec_attachable ~= nil and tool.spec_attachable.inputAttacherJoints or nil
    if inputs == nil then
        return nil
    end
    for _, fj in ipairs(ADAutonomousManager.frontJoints(vehicle)) do
        local free = fj.joint.jointIndex == nil or fj.joint.jointIndex == 0
        if free or not freeOnly then
            for inputIndex, input in ipairs(inputs) do
                if input.jointType == fj.joint.jointType and input.node ~= nil and ADAutonomousManager.isFrontInput(tool, input) then
                    return fj.index, fj.joint, inputIndex, input
                end
            end
        end
    end
    return nil
end

-- ce qui est attelé directement à l'avant du tracteur (outil ou masse), ou nil
function ADAutonomousManager.frontObject(vehicle)
    if vehicle == nil or vehicle.getAttachedImplements == nil then
        return nil
    end
    local ok, implements = FarmPilotCall(vehicle.getAttachedImplements, vehicle)
    if not ok or type(implements) ~= "table" then
        return nil
    end
    for _, impl in ipairs(implements) do
        if impl.object ~= nil and ADAutonomousManager.isFrontJointIndex(vehicle, impl.jointDescIndex) then
            return impl.object
        end
    end
    return nil
end

-- objets attelés à l'avant du tracteur (et ce qui y est attelé), pour les retirer de workTools
function ADAutonomousManager.frontSet(vehicle)
    local set = {}
    local front = ADAutonomousManager.frontObject(vehicle)
    local function add(o, depth)
        if o == nil or depth > 6 or set[o] then
            return
        end
        set[o] = true
        if o.getAttachedImplements ~= nil then
            local ok, implements = FarmPilotCall(o.getAttachedImplements, o)
            if ok and type(implements) == "table" then
                for _, impl in ipairs(implements) do
                    add(impl.object, depth + 1)
                end
            end
        end
    end
    add(front, 0)
    return set
end

-- ------------------------------------------------------------------------------------------------------------
-- Masses
-- ------------------------------------------------------------------------------------------------------------
local function storeCategory(tool)
    if g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil and tool ~= nil and tool.configFileName ~= nil then
        local ok, item = FarmPilotCall(g_storeManager.getItemByXMLFilename, g_storeManager, tool.configFileName)
        if ok and item ~= nil and type(item.categoryName) == "string" then
            return string.upper(item.categoryName)
        end
    end
    return nil
end

function ADAutonomousManager.isMass(tool)
    if tool == nil or tool.spec_attachable == nil then
        return false
    end
    if storeCategory(tool) == "WEIGHTS" then
        return true
    end
    -- sans catégorie (mod) : pas un outil de travail, rien à remplir, et « weight » dans le fichier
    local f = type(tool.configFileName) == "string" and string.lower(tool.configFileName) or ""
    return not ADAutonomousManager.isWorkObject(tool) and tool.spec_fillUnit == nil and f:find("weight", 1, true) ~= nil
end

-- poids en kg, arrondi
function ADAutonomousManager.massKg(tool)
    local kg = nil
    if tool.getTotalMass ~= nil then
        local ok, t = FarmPilotCall(tool.getTotalMass, tool, true)
        if ok and type(t) == "number" and t > 0 then
            kg = t * 1000
        end
    end
    if kg == nil and tool.defaultMass ~= nil then
        kg = tool.defaultMass * 1000
    end
    if kg == nil then
        return nil
    end
    local step = ADAutonomousManager.MASS_STEP
    return math.floor(kg / step + 0.5) * step
end

local function kgText(kg)
    local s = tostring(math.floor(kg + 0.5))
    -- 1500 -> « 1 500 »
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^ ", ""))
end

-- « Masse (1 500 kg) » ou « Faucheuse (3 m) »
function ADAutonomousManager.frontLabel(tool)
    if ADAutonomousManager.isMass(tool) then
        local kg = ADAutonomousManager.massKg(tool)
        local name = g_i18n:getText("AD_fpFn_mass")
        if kg ~= nil then
            return string.format("%s (%s kg)", name, kgText(kg)), name, kg / 1000
        end
        return name, name, nil
    end
    return ADAutonomousManager.toolShortLabel(tool)
end

-- ------------------------------------------------------------------------------------------------------------
-- Liste « Outil avant » du HUD
-- ------------------------------------------------------------------------------------------------------------
local function farmOf(object)
    if object ~= nil and object.getOwnerFarmId ~= nil then
        local ok, id = FarmPilotCall(object.getOwnerFarmId, object)
        if ok then
            return id
        end
    end
    return nil
end

-- outil frontal ou masse de la ferme, dételé, qui s'attelle à l'avant de ce tracteur
function ADAutonomousManager.isFetchableFront(vehicle, tool)
    if tool == nil or tool == vehicle or tool.spec_attachable == nil or tool.isDeleted or tool.isDeleting then
        return false
    end
    if not ADAutonomousManager.isWorkObject(tool) and not ADAutonomousManager.isMass(tool) then
        return false
    end
    local farm = farmOf(vehicle)
    if farm ~= nil and farmOf(tool) ~= farm then
        return false
    end
    if tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() ~= nil then
        return false
    end
    return ADAutonomousManager.matchFrontJoints(vehicle, tool, false) ~= nil
end

-- { tool, name, distance } : outils par fonction et largeur, puis masses par poids, puis distance
function ADAutonomousManager.fetchableFrontTools(vehicle)
    local out = {}
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system == nil or system.vehicles == nil or vehicle == nil then
        return out
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    for _, v in pairs(system.vehicles) do
        local ok, fetchable = FarmPilotCall(ADAutonomousManager.isFetchableFront, vehicle, v)
        if ok and fetchable then
            local tx, _, tz = getWorldTranslation(v.components[1].node)
            local label, fn, w = ADAutonomousManager.frontLabel(v)
            out[#out + 1] = { tool = v, name = label, fn = fn, mass = ADAutonomousManager.isMass(v), width = w or 0,
                distance = MathUtil.vector2Length(tx - vx, tz - vz) }
        end
    end
    table.sort(out, function(a, b)
        if a.mass ~= b.mass then
            return not a.mass
        end
        if a.fn ~= b.fn then
            return a.fn < b.fn
        end
        if a.width ~= b.width then
            return a.width < b.width
        end
        return a.distance < b.distance
    end)
    local count = {}
    for _, e in ipairs(out) do
        count[e.name] = (count[e.name] or 0) + 1
    end
    for _, e in ipairs(out) do
        if count[e.name] > 1 then
            e.name = string.format(g_i18n:getText("AD_autonomous_toolListEntry"), e.name, math.floor(e.distance + 0.5))
        end
    end
    return out
end

-- ------------------------------------------------------------------------------------------------------------
-- Point d'attelage d'un outil frontal
-- ------------------------------------------------------------------------------------------------------------
-- point d'attelage (x, y, z) et direction de l'outil vers le tracteur (le tracteur arrive en face, le nez vers -dir) ;
-- anyJoint : même si l'attelage avant du tracteur est pris (masse encore attelée)
function ADAutonomousManager.frontHitch(vehicle, tool, anyJoint)
    local _, _, _, input = ADAutonomousManager.matchFrontJoints(vehicle, tool, anyJoint ~= true)
    if input == nil then
        return nil
    end
    local jx, jy, jz = getWorldTranslation(input.node)
    local dx, _, dz = localDirectionToWorld(input.node, -1, 0, 0)
    local len = MathUtil.vector2Length(dx, dz)
    if len < 0.001 then
        return nil
    end
    return { x = jx, y = jy, z = jz, dirX = dx / len, dirZ = dz / len }
end

-- ------------------------------------------------------------------------------------------------------------
-- Outil avant à atteler au départ
-- ------------------------------------------------------------------------------------------------------------
-- l'outil avant choisi à aller atteler, ou nil (rien de choisi, ou déjà attelé) ; err : « busy », « noJoint »
function ADAutonomousManager.frontToFetch(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or sm.getFpFrontTool == nil then
        return nil
    end
    local tool = sm:getFpFrontTool()
    if tool == nil then
        return nil
    end
    local attacher = tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() or nil
    if attacher ~= nil then
        local root = tool.getRootVehicle ~= nil and tool:getRootVehicle() or attacher
        if root == vehicle or attacher == vehicle then
            return nil -- déjà attelé
        end
        return nil, "busy", tool
    end
    if ADAutonomousManager.matchFrontJoints(vehicle, tool, false) == nil then
        return nil, "noJoint", tool
    end
    return tool
end
