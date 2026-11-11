-- ============================================================================================================
-- FarmPilot : AutonomousManagerTools.lua
-- Complément de AutonomousManager.lua (mode Autonome) : l'outil de travail.
--
-- Règle :
-- - (07/11) il faut un outil de travail attelé (ou une machine qui travaille elle-même) : WORK_SPECS. Benne,
--   plateau, remorque de coupe ou moissonneuse seuls : refus au départ.
-- - Largeur de l'outil : celle que Courseplay calcule, au pas de 10 cm (WIDTH_STEP).
-- - Nom affiché dans le HUD : la fonction de l'outil et sa largeur, « Déchaumeur (8 m) ».
-- - (07/11) outil choisi dans le HUD : le chauffeur va l'atteler avant d'aller au champ ; un seul outil, attelé à
--   l'arrière du tracteur (masses et cuves avant ignorées).
-- - Identité de l'outil (clé de la mémoire champ + outil) : les outils de travail seulement, masses ignorées, quel
--   que soit le tracteur.
--
-- Branché par : AutonomousManager.lua (choose), AutonomousManagerCourses.lua (largeur), AutonomousMode.lua (départ,
-- outil suivant, dépose de l'outil), FetchToolTask.lua (matchJoints, toolHitch), PullDownList.lua (liste des outils
-- du HUD), AutonomousToolEvent.lua, SeederManager.lua, SprayerManager.lua et les fenêtres du semoir, de l'épandeur et
-- des parcours.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- (07/11) il faut un outil de travail attelé (ou une machine qui travaille elle-même) :
-- travail du sol, semoir, planteuse, pulvé, épandeur, faucheuse, faneuse, andaineur, presse, remorque à balles.
-- Benne, plateau, remorque de coupe ou moissonneuse seuls : refus au départ.
ADAutonomousManager.WORK_SPECS = {
    "spec_plow", "spec_plowPacker", "spec_cultivator", "spec_roller", "spec_weeder", "spec_mulcher", "spec_stonePicker", "spec_ridgeFormer",
    "spec_sowingMachine", "spec_treePlanter", "spec_sprayer", "spec_mower", "spec_tedder", "spec_windrower", "spec_baler",
    "spec_baleLoader" -- remorque à balles (09/11), voir BaleLoaderManager.lua
}

-- (07/11) la fonction de l'outil à la place de son nom, plus courte :
-- fonction courte, d'après la catégorie de la boutique du jeu (la même pour les outils des mods), sinon d'après
-- ce que fait l'outil, sinon son nom
ADAutonomousManager.FUNCTION_BY_CATEGORY = {
    PLOWS = "plow", CULTIVATORS = "cultivator", DISCHARROWS = "discHarrow", POWERHARROWS = "powerHarrow",
    SUBSOILERS = "subsoiler", SPADERS = "spader", ROLLERS = "roller", WEEDERS = "weeder", MULCHERS = "mulcher",
    STONEPICKERS = "stonePicker", SEEDERS = "seeder", PLANTERS = "planter", FERTILIZERSPREADERS = "fertilizerSpreader",
    SPRAYERS = "sprayer", SLURRYTANKS = "slurryTank", MANURESPREADERS = "manureSpreader", MOWERS = "mower",
    TEDDERS = "tedder", WINDROWERS = "windrower", BALERS = "baler", BALERSSQUARE = "balerSquare", BALERSROUND = "balerRound",
    BALELOADERS = "baleLoader"
}
ADAutonomousManager.FUNCTION_BY_SPEC = {
    { "spec_sowingMachine", "seeder" }, { "spec_baler", "baler" }, { "spec_sprayer", "sprayer" }, { "spec_mower", "mower" },
    { "spec_tedder", "tedder" }, { "spec_windrower", "windrower" }, { "spec_plow", "plow" }, { "spec_plowPacker", "roller" },
    { "spec_cultivator", "cultivator" }, { "spec_roller", "roller" }, { "spec_weeder", "weeder" }, { "spec_mulcher", "mulcher" },
    { "spec_stonePicker", "stonePicker" }, { "spec_baleLoader", "baleLoader" }
}

-- ------------------------------------------------------------------------------------------------------------
-- Largeur de travail (calcul de Courseplay)
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousManager.snapWidth(w)
    if w == nil then
        return nil
    end
    local step = ADAutonomousManager.WIDTH_STEP
    return math.floor(w / step + 0.5) * step
end

function ADAutonomousManager.sameWidth(a, b)
    if a == nil or b == nil then
        return false
    end
    return math.abs(ADAutonomousManager.snapWidth(a) - ADAutonomousManager.snapWidth(b)) < 0.011
end

function ADAutonomousManager.toolWidth(vehicle)
    local wwu = ADAutonomousManager.cpGlobal("WorkWidthUtil")
    if wwu ~= nil and wwu.getAutomaticWorkWidthAndOffset ~= nil then
        local ok, w = FarmPilotCall(wwu.getAutomaticWorkWidthAndOffset, vehicle)
        if ok and type(w) == "number" and w > 0.1 then
            return ADAutonomousManager.snapWidth(w)
        end
    end
    -- repli : réglage « largeur de travail » de Courseplay sur ce véhicule
    if vehicle.getCourseGeneratorSettings ~= nil then
        local ok, cs = FarmPilotCall(vehicle.getCourseGeneratorSettings, vehicle)
        if ok and cs ~= nil and cs.workWidth ~= nil and cs.workWidth.getValue ~= nil then
            local okV, w = FarmPilotCall(cs.workWidth.getValue, cs.workWidth)
            if okV and type(w) == "number" and w > 0.1 then
                return ADAutonomousManager.snapWidth(w)
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Outils attelés
-- ------------------------------------------------------------------------------------------------------------
local function shortConfigName(object)
    local f = object ~= nil and object.configFileName or nil
    if type(f) ~= "string" then
        return nil
    end
    f = f:gsub("\\", "/")
    -- dossier + fichier (« optimaRS9m/optimaRS9m.xml »), pareil que le jeu soit dans un mod ou dans data
    local a, b = f:match("([^/]+)/([^/]+)$")
    if a ~= nil then
        return a .. "/" .. b
    end
    return f
end
ADAutonomousManager.shortConfigName = shortConfigName

-- outils attelés (récursif), sans le tracteur lui-même
local function collectImplements(object, out, depth)
    if object == nil or depth > 6 or object.getAttachedImplements == nil then
        return
    end
    local ok, implements = FarmPilotCall(object.getAttachedImplements, object)
    if not ok or type(implements) ~= "table" then
        return
    end
    for _, impl in ipairs(implements) do
        local o = impl.object
        if o ~= nil then
            out[#out + 1] = o
            collectImplements(o, out, depth + 1)
        end
    end
end

-- true, ou false si aucun outil de travail n'est attelé
function ADAutonomousManager.hasWorkTool(vehicle)
    local objects = {vehicle}
    collectImplements(vehicle, objects, 0)
    for _, o in ipairs(objects) do
        for _, name in ipairs(ADAutonomousManager.WORK_SPECS) do
            if o[name] ~= nil then
                return true
            end
        end
    end
    return false
end

-- outils de travail attelés (sans le tracteur ; masses, cuves frontales... ignorées)
function ADAutonomousManager.workTools(vehicle)
    local list, tools = {}, {}
    collectImplements(vehicle, list, 0)
    -- (10/11) l'attelage avant à part (outil frontal, masse), voir AutonomousManagerFront.lua
    local front = ADAutonomousManager.frontSet ~= nil and ADAutonomousManager.frontSet(vehicle) or {}
    for _, o in ipairs(list) do
        for _, name in ipairs(ADAutonomousManager.WORK_SPECS) do
            if o[name] ~= nil and not front[o] then
                tools[#tools + 1] = o
                break
            end
        end
    end
    return tools
end

function ADAutonomousManager.isWorkObject(o)
    if o == nil then
        return false
    end
    for _, name in ipairs(ADAutonomousManager.WORK_SPECS) do
        if o[name] ~= nil then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Nom affiché dans le HUD : fonction et largeur
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousManager.toolLabel(tool)
    local okN, n = FarmPilotCall(function() return tool:getFullName() end)
    if okN and n ~= nil and n ~= "" then
        return tostring(n)
    end
    local okG, g = FarmPilotCall(function() return tool:getName() end)
    return okG and tostring(g) or "?"
end

local function functionText(name)
    local key = "AD_fpFn_" .. name
    if g_i18n ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return nil
end

function ADAutonomousManager.toolFunction(tool)
    local category = nil
    if g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil and tool ~= nil and tool.configFileName ~= nil then
        local ok, item = FarmPilotCall(g_storeManager.getItemByXMLFilename, g_storeManager, tool.configFileName)
        if ok and item ~= nil and type(item.categoryName) == "string" then
            category = string.upper(item.categoryName)
        end
    end
    if category ~= nil then
        local name = ADAutonomousManager.FUNCTION_BY_CATEGORY[category]
        local txt = name ~= nil and functionText(name) or nil
        if txt ~= nil then
            return txt
        end
        -- catégorie inconnue (mod) : son titre dans le jeu
        local okC, cat = FarmPilotCall(g_storeManager.getCategoryByName, g_storeManager, category)
        if okC and cat ~= nil and type(cat.title) == "string" and cat.title ~= "" then
            return cat.title
        end
    end
    for _, e in ipairs(ADAutonomousManager.FUNCTION_BY_SPEC) do
        if tool ~= nil and tool[e[1]] ~= nil then
            local txt = functionText(e[2])
            if txt ~= nil then
                return txt
            end
        end
    end
    return ADAutonomousManager.toolLabel(tool)
end

-- (07/11) largeur affichée après la fonction (« Déchaumeur (8 m) ») : largeur de travail d'un outil
-- dételé : celle que Courseplay calcule sur l'outil, sinon celle de la boutique
-- (09/11) gardée par outil : le HUD la demande à chaque image et Courseplay écrit 4 lignes de log à chaque calcul
-- (16 000 lignes en 3 min). Recalculée seulement quand l'outil se replie ou se déplie.
ADAutonomousManager.toolWidthCache = setmetatable({}, { __mode = "k" })

local function foldKey(tool)
    local spec = tool.spec_foldable
    if spec == nil or spec.foldingParts == nil or #spec.foldingParts == 0 then
        return 0
    end
    return math.floor((spec.foldAnimTime or 0) * 4 + 0.5)
end

function ADAutonomousManager.toolWorkWidth(tool)
    if tool == nil then
        return nil
    end
    local key = foldKey(tool)
    local cached = ADAutonomousManager.toolWidthCache[tool]
    if cached ~= nil and cached.key == key then
        return cached.width or nil
    end
    local w = ADAutonomousManager.computeToolWorkWidth(tool)
    ADAutonomousManager.toolWidthCache[tool] = { key = key, width = w or false }
    return w
end

function ADAutonomousManager.computeToolWorkWidth(tool)
    local wwu = ADAutonomousManager.cpGlobal("WorkWidthUtil")
    if wwu ~= nil and wwu.getAutomaticWorkWidthAndOffset ~= nil then
        local ok, w = FarmPilotCall(wwu.getAutomaticWorkWidthAndOffset, tool)
        if ok and type(w) == "number" and w > 0.1 then
            return ADAutonomousManager.snapWidth(w)
        end
    end
    if g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil and tool.configFileName ~= nil then
        local ok, item = FarmPilotCall(g_storeManager.getItemByXMLFilename, g_storeManager, tool.configFileName)
        local w = ok and item ~= nil and item.specs ~= nil and item.specs.workingWidth or nil
        if type(w) == "number" and w > 0.1 then
            return ADAutonomousManager.snapWidth(w)
        end
    end
    return nil
end

function ADAutonomousManager.widthText(w)
    if w == nil then
        return nil
    end
    local txt
    if math.abs(w - math.floor(w + 0.5)) < 0.05 then
        txt = string.format("%d", math.floor(w + 0.5))
    else
        txt = string.format("%.1f", w)
        local sep = g_i18n ~= nil and rawget(g_i18n, "decimalSeparator") or nil
        if type(sep) ~= "string" or sep == "" then
            local lang = type(g_languageShort) == "string" and g_languageShort or "en"
            sep = (lang == "en" or lang == "ct" or lang == "cs" or lang == "jp" or lang == "kr") and "." or ","
        end
        txt = txt:gsub("%.", sep)
    end
    return txt .. " m"
end

-- « Déchaumeur (8 m) » : fonction et largeur (HUD)
function ADAutonomousManager.toolShortLabel(tool)
    local okF, fn = FarmPilotCall(ADAutonomousManager.toolFunction, tool)
    fn = okF and fn or ADAutonomousManager.toolLabel(tool)
    local okW, w = FarmPilotCall(ADAutonomousManager.toolWorkWidth, tool)
    local wt = okW and ADAutonomousManager.widthText(w) or nil
    if wt ~= nil then
        return string.format("%s (%s)", fn, wt), fn, w
    end
    return fn, fn, nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Outil choisi dans le HUD : le chauffeur va l'atteler avant d'aller au champ
-- ------------------------------------------------------------------------------------------------------------
-- (07/11) un seul outil, attelé à l'arrière du tracteur (masses et cuves avant ignorées) ; plusieurs outils : plus tard.
local function farmOf(object)
    if object ~= nil and object.getOwnerFarmId ~= nil then
        local ok, id = FarmPilotCall(object.getOwnerFarmId, object)
        if ok then
            return id
        end
    end
    return nil
end

-- attelages arrière du tracteur : { index, joint } (libres ou non)
function ADAutonomousManager.rearJoints(vehicle)
    local out = {}
    local spec = vehicle ~= nil and vehicle.spec_attacherJoints or nil
    if spec == nil or spec.attacherJoints == nil then
        return out
    end
    for index, joint in ipairs(spec.attacherJoints) do
        local rear = joint.attacherJointDirection == -1
        if joint.attacherJointDirection == nil and joint.jointTransform ~= nil then
            local _, _, z = localToLocal(joint.jointTransform, vehicle.components[1].node, 0, 0, 0)
            rear = z < 0
        end
        if rear then
            out[#out + 1] = { index = index, joint = joint }
        end
    end
    return out
end

-- le couple (attelage arrière du tracteur, point d'attelage de l'outil) de même type ; freeOnly : attelage libre
function ADAutonomousManager.matchJoints(vehicle, tool, freeOnly)
    local inputs = tool ~= nil and tool.spec_attachable ~= nil and tool.spec_attachable.inputAttacherJoints or nil
    if inputs == nil then
        return nil
    end
    for _, rj in ipairs(ADAutonomousManager.rearJoints(vehicle)) do
        local free = rj.joint.jointIndex == nil or rj.joint.jointIndex == 0
        if free or not freeOnly then
            for inputIndex, input in ipairs(inputs) do
                -- (10/11) point d'attelage d'un outil frontal : pas à l'arrière, voir AutonomousManagerFront.lua
                if input.jointType == rj.joint.jointType and input.node ~= nil
                    and not (ADAutonomousManager.isFrontInput ~= nil and ADAutonomousManager.isFrontInput(tool, input)) then
                    return rj.index, rj.joint, inputIndex, input
                end
            end
        end
    end
    return nil
end

-- outil de travail de la ferme, dételé, qui s'attelle à l'arrière de ce tracteur
function ADAutonomousManager.isFetchableTool(vehicle, tool)
    if tool == nil or tool == vehicle or tool.spec_attachable == nil or tool.isDeleted or tool.isDeleting then
        return false
    end
    if not ADAutonomousManager.isWorkObject(tool) then
        return false
    end
    local farm = farmOf(vehicle)
    if farm ~= nil and farmOf(tool) ~= farm then
        return false
    end
    if tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() ~= nil then
        return false
    end
    return ADAutonomousManager.matchJoints(vehicle, tool, false) ~= nil
end

-- liste du HUD : { tool, name (« Déchaumeur (8 m) »), distance } triée par fonction, largeur puis distance ;
-- deux outils pareils : la distance s'ajoute pour les distinguer
function ADAutonomousManager.fetchableTools(vehicle)
    local out = {}
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system == nil or system.vehicles == nil or vehicle == nil then
        return out
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    for _, v in pairs(system.vehicles) do
        local ok, fetchable = FarmPilotCall(ADAutonomousManager.isFetchableTool, vehicle, v)
        if ok and fetchable then
            local tx, _, tz = getWorldTranslation(v.components[1].node)
            local label, fn, w = ADAutonomousManager.toolShortLabel(v)
            out[#out + 1] = { tool = v, name = label, fn = fn, width = w or 0, distance = MathUtil.vector2Length(tx - vx, tz - vz) }
        end
    end
    table.sort(out, function(a, b)
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

-- l'outil choisi à aller atteler, ou nil (rien de choisi, ou déjà attelé) ; err si on ne peut pas y aller
function ADAutonomousManager.toolToFetch(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or sm.getFpTool == nil then
        return nil
    end
    local tool = sm:getFpTool()
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
    if #ADAutonomousManager.workTools(vehicle) > 0 then
        return nil, "other", tool
    end
    if ADAutonomousManager.matchJoints(vehicle, tool, true) == nil then
        return nil, "noJoint", tool
    end
    return tool
end

-- point d'attelage de l'outil (x, y, z) et sa direction (vers où le tracteur doit regarder)
function ADAutonomousManager.toolHitch(vehicle, tool)
    local _, _, _, input = ADAutonomousManager.matchJoints(vehicle, tool, true)
    if input == nil then
        return nil
    end
    local jx, jy, jz = getWorldTranslation(input.node)
    local root = tool.components[1].node
    local dx, _, dz = localDirectionToWorld(root, 0, 0, 1)
    local _, _, lz = worldToLocal(root, jx, jy, jz)
    if lz < 0 then
        -- point d'attelage à l'arrière de l'outil
        dx, dz = -dx, -dz
    end
    local len = MathUtil.vector2Length(dx, dz)
    if len < 0.001 then
        return nil
    end
    return { x = jx, y = jy, z = jz, dirX = dx / len, dirZ = dz / len }
end

-- ------------------------------------------------------------------------------------------------------------
-- Identité de l'outil (fichiers des outils) : clé de la mémoire champ + outil
-- ------------------------------------------------------------------------------------------------------------
-- { key = "…", name = "Kverneland Optima RS 9 m" } ; sans outil, la machine elle-même (moissonneuse...)
local function identityOf(list)
    local keys, names = {}, {}
    for _, o in ipairs(list) do
        local k = shortConfigName(o)
        if k ~= nil then
            keys[#keys + 1] = k
            local okN, n = FarmPilotCall(function() return o:getFullName() end)
            names[#names + 1] = okN and tostring(n) or k
        end
    end
    if #keys == 0 then
        return nil
    end
    table.sort(keys)
    return { key = table.concat(keys, "+"), name = table.concat(names, " + ") }
end

-- (07/11) le choix reste quel que soit le tracteur ; masses ignorées : clé = outils de travail
-- seulement ; legacyKey = ancienne clé (tous les outils attelés, masses comprises) pour retrouver les choix d'avant
function ADAutonomousManager.toolIdentity(vehicle)
    local list = {}
    collectImplements(vehicle, list, 0)
    local work = {}
    for _, o in ipairs(list) do
        if ADAutonomousManager.isWorkObject(o) then
            work[#work + 1] = o
        end
    end
    local all = identityOf(list)
    local id = identityOf(work) or all
    if id == nil then
        local k = shortConfigName(vehicle)
        local okN, n = FarmPilotCall(function() return vehicle:getFullName() end)
        return { key = k or "?", name = okN and tostring(n) or (k or "?") }
    end
    if all ~= nil and all.key ~= id.key then
        id.legacyKey = all.key
    end
    return id
end
