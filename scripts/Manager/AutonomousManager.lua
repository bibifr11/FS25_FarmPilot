-------------------------------------------------------------------------------
-- FarmPilot - mode Autonome
--   Arrivé à la cible (comme le mode Conduite), FarmPilot cherche le parcours
--   Courseplay enregistré qui a EXACTEMENT la largeur de l'outil attelé et qui est
--   sur le champ où il arrive, le charge et lance Courseplay. Sinon il s'arrête.
--   Choix retenu = mémorisé par champ + outil (fichier de la sauvegarde) et repris
--   tel quel tant que l'outil, sa largeur et le parcours n'ont pas changé.
--   La fenêtre « Parcours Autonome » permet de fixer ce choix à l'avance.
-------------------------------------------------------------------------------
ADAutonomousManager = {}
ADAutonomousManager.FILE_NAME = "FarmPilot_Autonome.xml"
ADAutonomousManager.MAX_FILES = 500        -- garde-fou : fichiers de parcours lus
ADAutonomousManager.SAMPLES = 16           -- points testés par parcours pour trouver son champ
ADAutonomousManager.FIELD_SHARE = 0.5      -- part des points dans le champ pour que le parcours soit « de ce champ »
ADAutonomousManager.WIDTH_STEP = 0.1       -- Courseplay règle la largeur par pas de 10 cm
ADAutonomousManager.assignments = {}       -- [champ .. "|" .. outil] = { field, tool, toolName, width, path, name, manual }
ADAutonomousManager.cache = {}             -- [chemin] = { w, name, pts } ou false
ADAutonomousManager.loaded = false
ADAutonomousManager.PREFETCH_PER_FRAME = 1   -- fichiers de parcours lus par image pendant le trajet
ADAutonomousManager.prefetch = nil          -- lecture en cours : { paths, i }
ADAutonomousManager.prefetched = false      -- cache rempli depuis le dernier départ

local function log(fmt, ...)
    print("[FarmPilot Autonome] " .. string.format(fmt, ...))
end
ADAutonomousManager.log = log

-------------------------------------------------------------------------------
-- Courseplay tourne dans son propre environnement Lua : on y va chercher ses globales
-------------------------------------------------------------------------------
local cpModName = nil
local function modGlobal(modName, name)
    local env = _G[modName]
    if type(env) == "table" then
        local ok, value = pcall(function() return env[name] end)
        if ok and value ~= nil then
            return value
        end
    end
    return nil
end

function ADAutonomousManager.cpGlobal(name)
    if cpModName ~= nil then
        return modGlobal(cpModName, name)
    end
    local found = modGlobal("FS25_Courseplay", name)
    if found ~= nil then
        cpModName = "FS25_Courseplay"
        return found
    end
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        local ok, mods = pcall(g_modManager.getActiveMods, g_modManager)
        if ok and type(mods) == "table" then
            for _, m in ipairs(mods) do
                local n = m.modName
                if type(n) == "string" and n:lower():find("courseplay", 1, true) then
                    found = modGlobal(n, name)
                    if found ~= nil then
                        cpModName = n
                        return found
                    end
                end
            end
        end
    end
    return nil
end

-- (07/11 20:15, Fabien : « le clic droit ne fonctionne pas » dans l'éditeur de routes) : le clic droit de
-- Courseplay montre / cache la souris, sauf quand le HUD ou l'éditeur d'AutoDrive est ouvert ; Courseplay ne cherche
-- AutoDrive que sous le nom du mod FS25_AutoDrive (log « Auto drive found: false ») : on lui donne FarmPilot
function ADAutonomousManager.linkCourseplayMouse()
    local cp = ADAutonomousManager.cpGlobal("g_Courseplay")
    if type(cp) ~= "table" or cp.autoDrive ~= nil then
        return false
    end
    cp.autoDrive = AutoDrive
    log("Courseplay : clic droit laissé au HUD et à l'éditeur de FarmPilot")
    return true
end

-------------------------------------------------------------------------------
-- (07/11 20:17, Fabien : « il n'attelle pas l'hydraulique du mod manual (idem pto) ») mod « Attach Implements
-- Manually » (BayernGamers) : flexibles et prise de force branchés après l'attelage, débranchés avant le dételage,
-- avec les fonctions et les événements du mod (comme le joueur avec ses touches)
-------------------------------------------------------------------------------
local aimModName = nil
local function aimGlobal(name)
    if aimModName == nil then
        aimModName = false
        if type(_G["FS25_attachImplementsManually"]) == "table" then
            aimModName = "FS25_attachImplementsManually"
        elseif g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
            local ok, mods = pcall(g_modManager.getActiveMods, g_modManager)
            if ok and type(mods) == "table" then
                for _, m in ipairs(mods) do
                    local n = m.modName
                    if type(n) == "string" and n:lower():find("attachimplementsmanually", 1, true) and type(_G[n]) == "table" then
                        aimModName = n
                        break
                    end
                end
            end
        end
    end
    if aimModName then
        return modGlobal(aimModName, name)
    end
    return nil
end

local function aimJoints(vehicle, tool)
    if vehicle.getImplementIndexByObject == nil or vehicle.getAttacherJointIndexFromImplementIndex == nil then
        return nil
    end
    local index = vehicle:getImplementIndexByObject(tool)
    if index == nil then
        return nil
    end
    local jointDescIndex = vehicle:getAttacherJointIndexFromImplementIndex(index)
    local inputJointDescIndex = nil
    if tool.getActiveInputAttacherJointDescIndex ~= nil then
        inputJointDescIndex = tool:getActiveInputAttacherJointDescIndex()
    elseif tool.spec_attachable ~= nil then
        inputJointDescIndex = tool.spec_attachable.inputAttacherJointDescIndex
    end
    return jointDescIndex, inputJointDescIndex
end

local function aimSendToClients(eventName, vehicle, tool)
    local E = aimGlobal(eventName)
    if g_server ~= nil and type(E) == "table" and E.new ~= nil then
        pcall(function() g_server:broadcastEvent(E.new(vehicle, tool), false, nil, vehicle) end)
    end
end

-- connect = true : brancher ; false : débrancher. Renvoie ce qui a changé (« flexibles », « prise de force »)
function ADAutonomousManager.setManualConnections(vehicle, tool, connect)
    local done = {}
    if vehicle == nil or tool == nil then
        return done
    end
    local j, inputJ = aimJoints(vehicle, tool)
    if j == nil then
        return done
    end
    -- prise de force d'abord au débranchement (le mod refuse les flexibles d'un outil encore entraîné)
    local ps = vehicle.spec_attachPowerTakeOffsManually
    if ps ~= nil and type(ps.attachedPTOs) == "table" and vehicle.togglePTOAttachState ~= nil then
        local util = aimGlobal("PowerTakeOffUtil")
        local has = false
        if util ~= nil and util.getHasInputPTO ~= nil and util.getHasOutputPTO ~= nil then
            local ok, r = pcall(function() return util.getHasInputPTO(tool, inputJ) and util.getHasOutputPTO(vehicle, j) end)
            has = ok and r == true
        end
        if has and (ps.attachedPTOs[j] ~= nil) ~= connect then
            vehicle:togglePTOAttachState(tool, j, inputJ)
            if (ps.attachedPTOs[j] ~= nil) == connect then
                aimSendToClients("TogglePTOAttachStateEvent", vehicle, tool)
                done[#done + 1] = "pto"
            end
        end
    end
    local hs = vehicle.spec_attachConnectionHosesManually
    if hs ~= nil and type(hs.attachedHoses) == "table" and vehicle.toggleConnectionHoseAttachState ~= nil then
        local util = aimGlobal("ConnectionHoseUtil")
        local has = false
        if util ~= nil and util.getHasInputConnectionHoses ~= nil then
            local ok, r = pcall(util.getHasInputConnectionHoses, tool, inputJ)
            has = ok and r == true
        end
        if has and (hs.attachedHoses[j] ~= nil) ~= connect then
            vehicle:toggleConnectionHoseAttachState(tool, j, inputJ)
            if (hs.attachedHoses[j] ~= nil) == connect then
                aimSendToClients("ToggleHoseAttachStateEvent", vehicle, tool)
                done[#done + 1] = "hoses"
            end
        end
    end
    return done
end

function ADAutonomousManager.hasCp(vehicle)
    return vehicle ~= nil and vehicle.appendLoadedCpCourse ~= nil and vehicle.startCpAtFirstWp ~= nil
end

-------------------------------------------------------------------------------
-- Champs
-------------------------------------------------------------------------------
function ADAutonomousManager.fieldAt(x, z)
    if g_fieldManager ~= nil and g_fieldManager.getFieldAtWorldPosition ~= nil then
        local ok, f = pcall(g_fieldManager.getFieldAtWorldPosition, g_fieldManager, x, z)
        if ok and f ~= nil then
            return f
        end
    end
    if g_farmlandManager ~= nil and g_farmlandManager.getFarmlandAtWorldPosition ~= nil then
        local ok, fl = pcall(g_farmlandManager.getFarmlandAtWorldPosition, g_farmlandManager, x, z)
        if ok and fl ~= nil and fl.field ~= nil then
            return fl.field
        end
    end
    return nil
end

function ADAutonomousManager.fieldNumber(f)
    if f == nil then
        return nil
    end
    local id = nil
    if f.getId ~= nil then
        local ok, r = pcall(f.getId, f)
        if ok then
            id = r
        end
    end
    if type(id) ~= "number" and f.farmland ~= nil and type(f.farmland.id) == "number" then
        id = f.farmland.id
    end
    if id == nil then
        id = f.fieldId
    end
    return id
end

-- même champ : même objet, ou même parcelle (un champ découpé en plusieurs morceaux)
function ADAutonomousManager.sameField(a, b)
    if a == nil or b == nil then
        return false
    end
    if a == b then
        return true
    end
    local fa, fb = a.farmland, b.farmland
    return fa ~= nil and fb ~= nil and fa.id ~= nil and fa.id == fb.id
end

-- numéros de champ écrits dans le nom du marqueur de destination (« Champ 56 » -> {56}, « Champ 52 - 53 » -> {52, 53})
function ADAutonomousManager.markerFieldNumbers(vehicle)
    local sm = vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    local marker = sm ~= nil and sm.getFirstMarker ~= nil and sm:getFirstMarker() or nil
    local name = marker ~= nil and marker.name or nil
    if type(name) ~= "string" then
        return nil
    end
    local list = {}
    for n in name:gmatch("%d+") do
        list[#list + 1] = tonumber(n)
    end
    if #list == 0 then
        return nil
    end
    return list, name
end

-- (07/11, Fabien : « il prend le 52 à gauche alors que je l'envoie dans le 56 à droite ») le champ du marqueur
-- (son numéro), s'il est à moins de 100 m : sous le véhicule, puis anneaux de 5 m
ADAutonomousManager.MARKER_FIELD_RANGE = 100
function ADAutonomousManager.markerField(vehicle, x, z)
    local wanted, name = ADAutonomousManager.markerFieldNumbers(vehicle)
    if wanted == nil then
        return nil
    end
    local function matches(f)
        local num = tonumber(ADAutonomousManager.fieldNumber(f))
        for _, n in ipairs(wanted) do
            if num == n then
                return true
            end
        end
        return false
    end
    local f = ADAutonomousManager.fieldAt(x, z)
    if f ~= nil and matches(f) then
        return f, x, z
    end
    for r = 5, ADAutonomousManager.MARKER_FIELD_RANGE, 5 do
        local steps = math.max(16, math.floor(r / 2))
        for k = 0, steps - 1 do
            local a = k / steps * 2 * math.pi
            local px, pz = x + math.cos(a) * r, z + math.sin(a) * r
            f = ADAutonomousManager.fieldAt(px, pz)
            if f ~= nil and matches(f) then
                return f, px, pz
            end
        end
    end
    log("marqueur « %s » : pas de champ %s à %d m, champ le plus proche", tostring(name), table.concat(wanted, " / "), ADAutonomousManager.MARKER_FIELD_RANGE)
    return nil
end

-- champ du marqueur de destination (« Champ 56 »), sinon champ sous le véhicule, sinon le plus proche
-- (anneaux de 15 m jusqu'à 150 m) ; renvoie aussi un point du champ
function ADAutonomousManager.nearField(vehicle)
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local okM, mf, mx, mz = pcall(ADAutonomousManager.markerField, vehicle, x, z)
    if okM and mf ~= nil then
        return mf, mx, mz
    end
    local f = ADAutonomousManager.fieldAt(x, z)
    if f ~= nil then
        return f, x, z
    end
    for r = 15, 150, 15 do
        for k = 0, 15 do
            local a = k / 16 * 2 * math.pi
            local px, pz = x + math.cos(a) * r, z + math.sin(a) * r
            f = ADAutonomousManager.fieldAt(px, pz)
            if f ~= nil then
                return f, px, pz
            end
        end
    end
    return nil
end

-- (07/11, demande Fabien) mode « Classique » : l'ouvrier du jeu prend le champ quand Courseplay est absent (réglage « Autonome sans Courseplay » sur Ouvrier du jeu).
-- Nouveau travail « champ » du jeu, au point où le chauffeur est arrivé (dans le champ le plus proche s'il est au bord).
-- (07/11) fin d'un travail « champ » de l'ouvrier du jeu : note si le champ est fini (et non arrêté par le joueur
-- ou en erreur), avant l'événement onAIJobFinished qui décide du champ suivant (ExternalInterface)
function ADAutonomousManager.onAIJobFieldWorkStop(job, aiMessage)
    local ok, vehicle = pcall(function() return job.vehicleParameter:getVehicle() end)
    if not ok or vehicle == nil or vehicle.ad == nil then
        return
    end
    local finished = false
    if aiMessage ~= nil and AIMessageSuccessFinishedJob ~= nil and aiMessage.isa ~= nil then
        local okIsa, isa = pcall(aiMessage.isa, aiMessage, AIMessageSuccessFinishedJob)
        finished = okIsa and isa == true
    end
    vehicle.ad.fpAIJobFinishedOk = finished
end

function ADAutonomousManager.startBaseWorker(vehicle)
    local mission = g_currentMission
    if mission == nil or mission.aiJobTypeManager == nil or mission.aiSystem == nil or AIJobType == nil or AIJobType.FIELDWORK == nil then
        return false, "pas d'ouvrier du jeu"
    end
    local field, px, pz = ADAutonomousManager.nearField(vehicle)
    if field == nil then
        return false, "pas de champ"
    end
    local job = mission.aiJobTypeManager:createJob(AIJobType.FIELDWORK)
    if job == nil then
        return false, "travail non créé"
    end
    local farmId = vehicle:getOwnerFarmId()
    job:applyCurrentState(vehicle, mission, farmId, true)
    if px ~= nil and job.positionAngleParameter ~= nil and job.positionAngleParameter.setPosition ~= nil then
        job.positionAngleParameter:setPosition(px, pz)
    end
    job:setValues()
    local ok, err = job:validate(farmId)
    if not ok then
        return false, tostring(err)
    end
    mission.aiSystem:startJob(job, farmId)
    log("ouvrier du jeu lancé sur le champ %s", tostring(ADAutonomousManager.fieldNumber(field)))
    return true
end

-------------------------------------------------------------------------------
-- Champs regroupés
--   AutoSwitch installé : ses groupes (fenêtre Champs : champs réunis en un seul contour),
--   clé = champ principal calculé par AutoSwitch. Sinon chaque champ seul.
--   Un parcours qui couvre plusieurs groupes (ex. « Champ 52_53 ») forme une ligne à lui.
-------------------------------------------------------------------------------
ADAutonomousManager.COURSE_FIELD_SHARE = 0.2   -- part des points pour qu'un champ compte dans un parcours

local function asFields()
    local env = _G["FS25_AutoSwitch"]
    if type(env) ~= "table" then
        return nil
    end
    local ok, f = pcall(function() return env.AS_Fields end)
    if ok and type(f) == "table" and type(f.groups) == "table" then
        return f
    end
    return nil
end

-- { key = numéro du groupe, main = champ affiché en premier, members = { numéros triés } }
function ADAutonomousManager.groupOf(fieldNum)
    if fieldNum == nil then
        return nil
    end
    local asf = asFields()
    local id = tonumber(fieldNum)
    if asf ~= nil and id ~= nil and asf.groups[id] ~= nil then
        local root = asf.groups[id]
        local members, main = {}, root
        for fid, r in pairs(asf.groups) do
            if r == root then
                members[#members + 1] = fid
                if type(asf.chosenMain) == "table" and asf.chosenMain[fid] then
                    main = fid
                end
            end
        end
        table.sort(members, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
        return {key = tostring(root), main = main, members = members, fromAutoSwitch = #members > 1}
    end
    return {key = tostring(fieldNum), main = fieldNum, members = {fieldNum}}
end

-- champs (et groupes) couverts par un parcours, d'après un échantillon de ses points
-- champs touchés par l'échantillon de points (calculé une fois par lecture du fichier)
function ADAutonomousManager.courseHits(info)
    if info.hits == nil then
        local count, tested, inside = {}, 0, 0
        for _, p in ipairs(info.pts) do
            tested = tested + 1
            local f = ADAutonomousManager.fieldAt(p[1], p[2])
            if f ~= nil then
                local num = ADAutonomousManager.fieldNumber(f)
                if num ~= nil then
                    count[num] = (count[num] or 0) + 1
                    inside = inside + 1
                end
            end
        end
        info.hits = {count = count, tested = tested, inside = inside}
    end
    return info.hits
end

function ADAutonomousManager.assignCourseFields(e, info)
    local h = ADAutonomousManager.courseHits(info)
    local count, tested, inside = h.count, h.tested, h.inside
    if tested == 0 or inside / tested < ADAutonomousManager.FIELD_SHARE then
        return
    end
    local groups, keys = {}, {}
    for num, k in pairs(count) do
        if k / tested >= ADAutonomousManager.COURSE_FIELD_SHARE then
            local g = ADAutonomousManager.groupOf(num)
            if g ~= nil and groups[g.key] == nil then
                groups[g.key] = g
                keys[#keys + 1] = g.key
            end
        end
    end
    if #keys == 0 then
        return
    end
    table.sort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
    e.groupKeys = {}
    local nums, seen = {}, {}
    for _, k in ipairs(keys) do
        e.groupKeys[k] = true
        local g = groups[k]
        -- champ principal d'abord, puis les autres
        local ordered = {g.main}
        for _, m in ipairs(g.members) do
            if tostring(m) ~= tostring(g.main) then
                ordered[#ordered + 1] = m
            end
        end
        for _, m in ipairs(ordered) do
            if not seen[tostring(m)] then
                seen[tostring(m)] = true
                nums[#nums + 1] = tostring(m)
            end
        end
    end
    e.rowKey = table.concat(keys, "+")   -- ligne de la fenêtre et clé de la mémoire
    e.fieldNums = nums                     -- numéros affichés (« 52 + 53 »)
    e.fieldNum = keys[1]
end

-- texte d'une ligne : « Champ 12 » ou « Champs 52 + 53 »
function ADAutonomousManager.fieldsLabel(nums)
    if nums == nil or #nums == 0 then
        return "?"
    end
    if #nums == 1 then
        return string.format(g_i18n:getText("gui_ad_autonomous_field"), tostring(nums[1]))
    end
    return string.format(g_i18n:getText("gui_ad_autonomous_fields"), table.concat(nums, " + "))
end

-------------------------------------------------------------------------------
-- Outil attelé : largeur (calcul de Courseplay) et identité (fichiers des outils)
-------------------------------------------------------------------------------
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
        local ok, w = pcall(wwu.getAutomaticWorkWidthAndOffset, vehicle)
        if ok and type(w) == "number" and w > 0.1 then
            return ADAutonomousManager.snapWidth(w)
        end
    end
    -- repli : réglage « largeur de travail » de Courseplay sur ce véhicule
    if vehicle.getCourseGeneratorSettings ~= nil then
        local ok, cs = pcall(vehicle.getCourseGeneratorSettings, vehicle)
        if ok and cs ~= nil and cs.workWidth ~= nil and cs.workWidth.getValue ~= nil then
            local okV, w = pcall(cs.workWidth.getValue, cs.workWidth)
            if okV and type(w) == "number" and w > 0.1 then
                return ADAutonomousManager.snapWidth(w)
            end
        end
    end
    return nil
end

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

-- outils attelés (récursif), sans le tracteur lui-même
local function collectImplements(object, out, depth)
    if object == nil or depth > 6 or object.getAttachedImplements == nil then
        return
    end
    local ok, implements = pcall(object.getAttachedImplements, object)
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

-- (07/11, demande Fabien) il faut un outil de travail attelé (ou une machine qui travaille elle-même) :
-- travail du sol, semoir, planteuse, pulvé, épandeur, faucheuse, faneuse, andaineur, presse.
-- Benne, plateau, remorque de coupe ou moissonneuse seuls : refus au départ.
ADAutonomousManager.WORK_SPECS = {
    "spec_plow", "spec_plowPacker", "spec_cultivator", "spec_roller", "spec_weeder", "spec_mulcher", "spec_stonePicker", "spec_ridgeFormer",
    "spec_sowingMachine", "spec_treePlanter", "spec_sprayer", "spec_mower", "spec_tedder", "spec_windrower", "spec_baler"
}

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
    for _, o in ipairs(list) do
        for _, name in ipairs(ADAutonomousManager.WORK_SPECS) do
            if o[name] ~= nil then
                tools[#tools + 1] = o
                break
            end
        end
    end
    return tools
end

-------------------------------------------------------------------------------
-- (07/11, demande Fabien) outil choisi dans le HUD : le chauffeur va l'atteler avant d'aller au champ.
-- Un seul outil, attelé à l'arrière du tracteur (masses et cuves avant ignorées) ; plusieurs outils : plus tard.
-------------------------------------------------------------------------------
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

function ADAutonomousManager.toolLabel(tool)
    local okN, n = pcall(function() return tool:getFullName() end)
    if okN and n ~= nil and n ~= "" then
        return tostring(n)
    end
    local okG, g = pcall(function() return tool:getName() end)
    return okG and tostring(g) or "?"
end

-- (07/11 20:13, Fabien : « à la place du nom de l'outil on pourrait mettre sa fonction ? », « moins long ») :
-- fonction courte, d'après la catégorie de la boutique du jeu (la même pour les outils des mods), sinon d'après
-- ce que fait l'outil, sinon son nom
ADAutonomousManager.FUNCTION_BY_CATEGORY = {
    PLOWS = "plow", CULTIVATORS = "cultivator", DISCHARROWS = "discHarrow", POWERHARROWS = "powerHarrow",
    SUBSOILERS = "subsoiler", SPADERS = "spader", ROLLERS = "roller", WEEDERS = "weeder", MULCHERS = "mulcher",
    STONEPICKERS = "stonePicker", SEEDERS = "seeder", PLANTERS = "planter", FERTILIZERSPREADERS = "fertilizerSpreader",
    SPRAYERS = "sprayer", SLURRYTANKS = "slurryTank", MANURESPREADERS = "manureSpreader", MOWERS = "mower",
    TEDDERS = "tedder", WINDROWERS = "windrower", BALERS = "baler", BALERSSQUARE = "balerSquare", BALERSROUND = "balerRound"
}
ADAutonomousManager.FUNCTION_BY_SPEC = {
    { "spec_sowingMachine", "seeder" }, { "spec_baler", "baler" }, { "spec_sprayer", "sprayer" }, { "spec_mower", "mower" },
    { "spec_tedder", "tedder" }, { "spec_windrower", "windrower" }, { "spec_plow", "plow" }, { "spec_plowPacker", "roller" },
    { "spec_cultivator", "cultivator" }, { "spec_roller", "roller" }, { "spec_weeder", "weeder" }, { "spec_mulcher", "mulcher" },
    { "spec_stonePicker", "stonePicker" }
}

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
        local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, tool.configFileName)
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
        local okC, cat = pcall(g_storeManager.getCategoryByName, g_storeManager, category)
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

-- (07/11 20:23, Fabien : « Déchaumeur (8 m) : la taille à la fin est importante ») largeur de travail d'un outil
-- dételé : celle que Courseplay calcule sur l'outil, sinon celle de la boutique
function ADAutonomousManager.toolWorkWidth(tool)
    local wwu = ADAutonomousManager.cpGlobal("WorkWidthUtil")
    if wwu ~= nil and wwu.getAutomaticWorkWidthAndOffset ~= nil then
        local ok, w = pcall(wwu.getAutomaticWorkWidthAndOffset, tool)
        if ok and type(w) == "number" and w > 0.1 then
            return ADAutonomousManager.snapWidth(w)
        end
    end
    if g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil and tool.configFileName ~= nil then
        local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, tool.configFileName)
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
    local okF, fn = pcall(ADAutonomousManager.toolFunction, tool)
    fn = okF and fn or ADAutonomousManager.toolLabel(tool)
    local okW, w = pcall(ADAutonomousManager.toolWorkWidth, tool)
    local wt = okW and ADAutonomousManager.widthText(w) or nil
    if wt ~= nil then
        return string.format("%s (%s)", fn, wt), fn, w
    end
    return fn, fn, nil
end

local function farmOf(object)
    if object ~= nil and object.getOwnerFarmId ~= nil then
        local ok, id = pcall(object.getOwnerFarmId, object)
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
                if input.jointType == rj.joint.jointType and input.node ~= nil then
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
        local ok, fetchable = pcall(ADAutonomousManager.isFetchableTool, vehicle, v)
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

-- { key = "…", name = "Kverneland Optima RS 9 m" } ; sans outil, la machine elle-même (moissonneuse...)
local function identityOf(list)
    local keys, names = {}, {}
    for _, o in ipairs(list) do
        local k = shortConfigName(o)
        if k ~= nil then
            keys[#keys + 1] = k
            local okN, n = pcall(function() return o:getFullName() end)
            names[#names + 1] = okN and tostring(n) or k
        end
    end
    if #keys == 0 then
        return nil
    end
    table.sort(keys)
    return { key = table.concat(keys, "+"), name = table.concat(names, " + ") }
end

-- (07/11 20:19, Fabien : le choix reste quel que soit le tracteur ; masses ignorées) : clé = outils de travail
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
        local okN, n = pcall(function() return vehicle:getFullName() end)
        return { key = k or "?", name = okN and tostring(n) or (k or "?") }
    end
    if all ~= nil and all.key ~= id.key then
        id.legacyKey = all.key
    end
    return id
end

-------------------------------------------------------------------------------
-- Parcours enregistrés de Courseplay (menu Courseplay > Parcours)
-------------------------------------------------------------------------------
local function collect(dir, parentName, out, depth)
    if dir == nil or depth > 6 or #out >= ADAutonomousManager.MAX_FILES then
        return
    end
    pcall(dir.refresh, dir)
    local okF, files = pcall(dir.getFiles, dir)
    if okF and type(files) == "table" then
        for _, f in ipairs(files) do
            if #out >= ADAutonomousManager.MAX_FILES then
                return
            end
            out[#out + 1] = { file = f, dir = parentName }
        end
    end
    local okD, dirs = pcall(dir.getDirectories, dir)
    if okD and type(dirs) == "table" then
        for _, sub in ipairs(dirs) do
            local okN, n = pcall(sub.getName, sub)
            collect(sub, okN and n or parentName, out, depth + 1)
        end
    end
end

-- largeur, nom et un échantillon de points répartis sur tout le parcours
function ADAutonomousManager.readCourse(path)
    if path == nil or not fileExists(path) then
        return nil
    end
    local xml = loadXMLFile("fpCpCourse", path)
    if xml == nil or xml == 0 then
        return nil
    end
    local base = "Courses.Course(0)"
    local info = nil
    if hasXMLProperty(xml, base) then
        info = {w = getXMLFloat(xml, base .. "#workWidth"), name = getXMLString(xml, base .. "#name"), pts = {}}
        local n = 0
        while hasXMLProperty(xml, string.format("%s.wp(%d)", base, n + 64)) do
            n = n + 64
        end
        while hasXMLProperty(xml, string.format("%s.wp(%d)", base, n)) do
            n = n + 1
        end
        info.nWp = n
        if n > 0 then
            local step = math.max(1, math.floor(n / ADAutonomousManager.SAMPLES))
            for i = 0, n - 1, step do
                local pos = getXMLString(xml, string.format("%s.wp(%d)#position", base, i))
                if pos ~= nil then
                    local x, _, z = pos:match("^%s*(%S+)%s+(%S+)%s+(%S+)")
                    x, z = tonumber(x), tonumber(z)
                    if x ~= nil and z ~= nil then
                        info.pts[#info.pts + 1] = {x, z}
                    end
                end
                if #info.pts >= ADAutonomousManager.SAMPLES then
                    break
                end
            end
        end
    end
    delete(xml)
    return info
end

-- (07/11) lecture pendant le trajet : au départ du mode Autonome, la liste des fichiers est relue et le cache
-- vidé, puis les parcours sont lus un par image (prefetchStep). À l'arrivée il ne reste presque rien à lire :
-- plus d'à-coup quand il y a beaucoup de parcours.
function ADAutonomousManager.startPrefetch()
    ADAutonomousManager.cache = {}
    ADAutonomousManager.prefetch = nil
    ADAutonomousManager.prefetched = true
    local cp = ADAutonomousManager.cpGlobal("g_Courseplay")
    local storage = cp ~= nil and cp.courseStorage or nil
    if storage == nil or storage.getRootDirectory == nil then
        return
    end
    local okR, root = pcall(storage.getRootDirectory, storage)
    local files = {}
    if okR and root ~= nil then
        collect(root, "", files, 0)
    end
    local paths = {}
    for _, e in ipairs(files) do
        local okP, path = pcall(e.file.getFullPath, e.file)
        if okP and path ~= nil then
            paths[#paths + 1] = path
        end
    end
    ADAutonomousManager.prefetch = {paths = paths, i = 1}
end

function ADAutonomousManager.prefetchStep(n)
    local pf = ADAutonomousManager.prefetch
    if pf == nil then
        return
    end
    local done = 0
    n = n or ADAutonomousManager.PREFETCH_PER_FRAME
    while pf.i <= #pf.paths and done < n do
        local path = pf.paths[pf.i]
        pf.i = pf.i + 1
        if ADAutonomousManager.cache[path] == nil then
            local okI, r = pcall(ADAutonomousManager.readCourse, path)
            local info = okI and r or false
            if info then
                pcall(ADAutonomousManager.courseHits, info)
            end
            ADAutonomousManager.cache[path] = info
            done = done + 1
        end
    end
    if pf.i > #pf.paths then
        ADAutonomousManager.prefetch = nil
    end
end

-- tous les parcours : { file, dir, fname, path, w, field (objet), fieldNum }
function ADAutonomousManager.listCourses()
    local cp = ADAutonomousManager.cpGlobal("g_Courseplay")
    local storage = cp ~= nil and cp.courseStorage or nil
    if storage == nil or storage.getRootDirectory == nil then
        log("stockage des parcours Courseplay introuvable (g_Courseplay %s)", tostring(cp))
        return nil
    end
    local okR, root = pcall(storage.getRootDirectory, storage)
    local files = {}
    if okR and root ~= nil then
        collect(root, "", files, 0)
    end
    local out = {}
    for _, e in ipairs(files) do
        local okP, path = pcall(e.file.getFullPath, e.file)
        e.path = okP and path or nil
        local okN, n = pcall(e.file.getName, e.file)
        e.fname = okN and tostring(n) or "?"
        if e.path ~= nil then
            local info = ADAutonomousManager.cache[e.path]
            if info == nil then
                local okI, r = pcall(ADAutonomousManager.readCourse, e.path)
                info = okI and r or false
                ADAutonomousManager.cache[e.path] = info
            end
            if info then
                e.w = info.w
                ADAutonomousManager.assignCourseFields(e, info)
                out[#out + 1] = e
            end
        end
    end
    table.sort(out, function(a, b)
        local da, db = tostring(a.dir or ""):lower(), tostring(b.dir or ""):lower()
        if da ~= db then
            return da < db
        end
        return a.fname:lower() < b.fname:lower()
    end)
    return out
end

-- parcours qui couvrent le groupe de ce champ, à la bonne largeur
function ADAutonomousManager.candidates(courses, field, width)
    local list = {}
    local g = ADAutonomousManager.groupOf(ADAutonomousManager.fieldNumber(field))
    if g == nil then
        return list
    end
    for _, e in ipairs(courses or {}) do
        if e.groupKeys ~= nil and e.groupKeys[g.key] and ADAutonomousManager.sameWidth(e.w, width) then
            list[#list + 1] = e
        end
    end
    return list
end

function ADAutonomousManager.courseLabel(e)
    if e == nil then
        return "?"
    end
    if e.dir ~= nil and e.dir ~= "" then
        return e.dir .. " / " .. e.fname
    end
    return e.fname
end

-------------------------------------------------------------------------------
-- Mémoire champ + outil -> parcours
-------------------------------------------------------------------------------
function ADAutonomousManager.key(fieldNum, toolKey)
    return tostring(fieldNum) .. "|" .. tostring(toolKey)
end

function ADAutonomousManager:getAssignment(fieldNum, toolKey, legacyKey)
    self:loadFromXml()
    local a = self.assignments[ADAutonomousManager.key(fieldNum, toolKey)]
    if a == nil and legacyKey ~= nil then
        -- choix fait avant que les masses soient ignorées : repris et rangé sous la nouvelle clé
        local old = self.assignments[ADAutonomousManager.key(fieldNum, legacyKey)]
        if old ~= nil then
            a = {}
            for k, v in pairs(old) do
                a[k] = v
            end
            a.tool = toolKey
            self.assignments[ADAutonomousManager.key(fieldNum, toolKey)] = a
            log("champ %s : choix de l'outil %s repris pour %s (masses ignorées)", tostring(fieldNum), tostring(legacyKey), tostring(toolKey))
        end
    end
    return a
end

-- fieldNum = clé de la ligne (groupe de champs, ex. « 52 » ou « 52+60 »)
function ADAutonomousManager:setAssignment(fieldNum, tool, width, e, manual)
    self:loadFromXml()
    local k = ADAutonomousManager.key(fieldNum, tool.key)
    if tool.legacyKey ~= nil then
        -- ancienne clé (masses comprises) remplacée par la nouvelle
        self.assignments[ADAutonomousManager.key(fieldNum, tool.legacyKey)] = nil
    end
    if e == nil then
        self.assignments[k] = nil
        log("champ %s, outil %s : choix effacé (automatique)", tostring(fieldNum), tostring(tool.key))
        return
    end
    self.assignments[k] = {field = fieldNum, tool = tool.key, toolName = tool.name, width = width, path = e.path, name = ADAutonomousManager.courseLabel(e), manual = manual == true}
    log("champ %s, outil %s (%.1f m) : parcours « %s »%s", tostring(fieldNum), tostring(tool.key), width or 0, ADAutonomousManager.courseLabel(e), manual and " (choisi dans la fenêtre)" or " (mémorisé)")
end

local function savegameFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local path = g_currentMission.missionInfo.savegameDirectory
    if path == nil then
        return nil
    end
    return path .. "/" .. ADAutonomousManager.FILE_NAME
end

function ADAutonomousManager:loadFromXml()
    if self.loaded then
        return
    end
    self.loaded = true
    self.assignments = {}
    local file = savegameFile()
    if file == nil or not fileExists(file) then
        return
    end
    local xml = loadXMLFile("fpAutonome", file)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while true do
        local key = string.format("farmPilotAutonome.entry(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local a = {
            field = getXMLString(xml, key .. "#field"),
            tool = getXMLString(xml, key .. "#tool"),
            toolName = getXMLString(xml, key .. "#toolName"),
            width = getXMLFloat(xml, key .. "#width"),
            path = getXMLString(xml, key .. "#path"),
            name = getXMLString(xml, key .. "#name"),
            manual = Utils.getNoNil(getXMLBool(xml, key .. "#manual"), false)
        }
        if a.field ~= nil and a.tool ~= nil and a.path ~= nil then
            local num = tonumber(a.field) or a.field
            a.field = num
            self.assignments[ADAutonomousManager.key(num, a.tool)] = a
        end
        i = i + 1
    end
    delete(xml)
    log("%d choix champ/outil chargés", i)
end

function ADAutonomousManager:saveToXml()
    if not self.loaded then
        return
    end
    local file = savegameFile()
    if file == nil then
        return
    end
    local xml = createXMLFile("fpAutonome", file, "farmPilotAutonome")
    if xml == nil or xml == 0 then
        return
    end
    local keys = {}
    for k, _ in pairs(self.assignments) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local a = self.assignments[k]
        local key = string.format("farmPilotAutonome.entry(%d)", i - 1)
        setXMLString(xml, key .. "#field", tostring(a.field))
        setXMLString(xml, key .. "#tool", a.tool)
        setXMLString(xml, key .. "#toolName", a.toolName or "")
        setXMLFloat(xml, key .. "#width", a.width or 0)
        setXMLString(xml, key .. "#path", a.path)
        setXMLString(xml, key .. "#name", a.name or "")
        setXMLBool(xml, key .. "#manual", a.manual == true)
    end
    saveXMLFile(xml)
    delete(xml)
end

-------------------------------------------------------------------------------
-- Choix du parcours à l'arrivée
--   renvoie e (parcours) ou nil + code d'erreur + texte de détail
-------------------------------------------------------------------------------
function ADAutonomousManager:choose(vehicle)
    if not ADAutonomousManager.hasWorkTool(vehicle) then
        return nil, "noTool"
    end
    if not ADAutonomousManager.hasCp(vehicle) then
        return nil, "noCp"
    end
    local width = ADAutonomousManager.toolWidth(vehicle)
    if width == nil then
        return nil, "noWidth"
    end
    local field = ADAutonomousManager.nearField(vehicle)
    if field == nil then
        return nil, "noField", width
    end
    local fieldNum = ADAutonomousManager.fieldNumber(field)
    local tool = ADAutonomousManager.toolIdentity(vehicle)
    -- fichiers relus à chaque départ (un parcours a pu être ajouté entre-temps) : déjà lus pendant le trajet
    -- (startPrefetch au départ) ; sinon tout est relu maintenant
    if ADAutonomousManager.prefetched then
        ADAutonomousManager.prefetchStep(math.huge)
    else
        ADAutonomousManager.cache = {}
    end
    ADAutonomousManager.prefetched = false
    local courses = ADAutonomousManager.listCourses()
    if courses == nil then
        return nil, "noCp"
    end
    local list = ADAutonomousManager.candidates(courses, field, width)
    local g = ADAutonomousManager.groupOf(fieldNum)
    local fieldTxt = table.concat(g.members, " + ")
    log("champ %s (groupe %s : %s), outil %s, largeur %.1f m : %d parcours enregistré(s), %d à cette largeur sur ce champ",
        tostring(fieldNum), g.key, fieldTxt, tool.key, width, #courses, #list)

    -- 1) choix mémorisé ou fixé dans la fenêtre : repris s'il est toujours valable
    --    (ligne de ce champ d'abord, puis lignes de parcours qui couvrent ce champ et d'autres)
    local rowKeys, seen = {g.key}, {[g.key] = true}
    for _, e in ipairs(list) do
        if e.rowKey ~= nil and not seen[e.rowKey] then
            seen[e.rowKey] = true
            rowKeys[#rowKeys + 1] = e.rowKey
        end
    end
    for _, rk in ipairs(rowKeys) do
        local a = self:getAssignment(rk, tool.key, tool.legacyKey)
        if a ~= nil then
            for _, e in ipairs(list) do
                if e.path == a.path then
                    log("choix mémorisé repris (ligne %s) : %s", rk, ADAutonomousManager.courseLabel(e))
                    return e, nil, width, fieldTxt, tool
                end
            end
            log("choix mémorisé « %s » (ligne %s) plus valable (parcours supprimé, déplacé ou d'une autre largeur)", tostring(a.name), rk)
        end
    end
    -- 2) un seul parcours possible : on le prend et on le retient
    if #list == 1 then
        self:setAssignment(list[1].rowKey or g.key, tool, width, list[1], false)
        return list[1], nil, width, fieldTxt, tool
    end
    if #list == 0 then
        return nil, "none", width, fieldTxt, tool
    end
    return nil, "several", width, fieldTxt, tool, #list
end

-- charge le parcours puis lance Courseplay au premier point
function ADAutonomousManager:startCourse(vehicle, e)
    local ok, res = pcall(vehicle.appendLoadedCpCourse, vehicle, e.file)
    if not ok or res == false then
        log("ERREUR chargement « %s » : %s", ADAutonomousManager.courseLabel(e), tostring(res))
        return false
    end
    if vehicle.setCpCourseName ~= nil then
        pcall(vehicle.setCpCourseName, vehicle, e.fname)
    end
    local isControlled = vehicle.spec_enterable ~= nil and vehicle:getIsControlled()
    if vehicle.spec_enterable ~= nil then
        vehicle.spec_enterable.isControlled = false
    end
    local okS, started = pcall(vehicle.startCpAtFirstWp, vehicle)
    if vehicle.spec_enterable ~= nil then
        vehicle.spec_enterable.isControlled = isControlled
    end
    if not okS or started ~= true then
        log("Courseplay n'a pas démarré avec « %s » (%s)", ADAutonomousManager.courseLabel(e), tostring(started))
        return false
    end
    log("Courseplay lancé avec « %s »", ADAutonomousManager.courseLabel(e))
    return true
end
