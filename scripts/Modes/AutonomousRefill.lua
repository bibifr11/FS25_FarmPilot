-- ============================================================================================================
-- FarmPilot : AutonomousRefill.lua
-- Complément du plein du semoir en mode Autonome (AutonomousMode.startRefill ... handleRefillStage).
--
-- (08/11) Le plein du semoir doit marcher comme le mode Chargement ; dans le log du 08/11
-- (16:34, 16:39, 17:09) « plein fait » arrive sans rien charger (cuves 2719 et 2505 / 3500 l avant et après), et la
-- sortie du champ vers le plein doit être celle déjà faite pour les fins de champ (pas dans les arbres).
--
-- Règle : au point de ravitaillement le semoir ne repart pas sans avoir chargé, sauf si le joueur appuie sur
-- « Continuer » (comme le mode Chargement qui attend au point de chargement). Il repart quand les cuves des
-- produits choisis sont pleines (réglage « niveau de remplissage » du mode Chargement), ou quand AutoDrive finit
-- la tâche de chargement après avoir chargé quelque chose.
--
-- Ce que fait ce fichier (sans changer AutonomousMode.lua) :
--   1. portée de chargement : pendant le plein, AutoDrive mesure la distance au point de ravitaillement et pas à
--      la 1re destination (le champ) ; sinon ADTrailerModule ne cherche jamais de zone de chargement ;
--   2. « Silo vide » (Addon/SiloEmpty.lua : départ après 30 s si le niveau ne monte plus et n'est pas nul) ne
--      s'applique pas au plein : un semoir n'arrive jamais vide, c'est ce qui finissait le plein sans charger ;
--   3. fin du plein : raison dans le log ; refusée (il reste au point) si rien n'est entré, pas plein, pas Continuer ;
--   4. diagnostic au point : zones de chargement à moins de 30 m (produits, stock, distance, cuve du semoir vue
--      par la zone), portée d'AutoDrive, cuves du semoir ;
--   5. « plein » = vraies cuves du semoir (semence, engrais) : une cuve de 1 l (« cuve 3 0/1 » dans le log)
--      n'empêche plus d'être plein ;
--   6. sortie du champ : plus d'ExitFieldTask (sortie des bennes de moissonneuse, points pris sur la route vers la
--      2e destination, sans rapport ici) ; la tâche de plein sort comme les fins de champ, par
--      PathFinderModule:startPathPlanningToNetwork -> getFieldExitWayPoint (destination du champ d'abord) ;
--   7. Courseplay « cuve vide » (onCpEmpty) : état noté dans le log, plein lancé ou non.
-- Crochets dans les fichiers d'origine : register.lua (source de ce fichier) et Addon/SiloEmpty.lua (une ligne).
-- ============================================================================================================

ADSeederRefill = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADSeederRefill.DIAG_RADIUS = 30        -- m autour du point de ravitaillement (ou du semoir) : zones listées dans le log
ADSeederRefill.TINY_CAPACITY = 10      -- l : cuve plus petite = pas une vraie cuve, ignorée pour « plein »
ADSeederRefill.LOADED_MIN = 1          -- l entrés dans les cuves choisies depuis le départ vers le point = « a chargé »
ADSeederRefill.WAIT_NOTICE = 60000     -- ms arrêté au point sans que le niveau monte : état et zones dans le log
ADSeederRefill.LOOP_WINDOW = 20000     -- ms sur lesquelles les fins refusées sont comptées
ADSeederRefill.LOOP_MAX = 3            -- fins refusées dans LOOP_WINDOW = la tâche finit en boucle : arrêt au point
-- 6. plus d'étape « exit » (ExitFieldTask) : startRefill passe directement à la tâche de plein, qui sort du champ
-- par la recherche de chemin de FarmPilot (destination du champ), comme les fins de champ
AutonomousMode.REFILL_EXIT_DISTANCE = math.huge

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local function log(fmt, ...)
    ADAutonomousManager.log(fmt, ...)
end

local function vehicleName(vehicle)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
        return tostring(vehicle.ad.stateModule:getName())
    end
    return "?"
end

local function yesNo(b)
    return b and "oui" or "non"
end

local function fillTypeName(index)
    local name = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeNameByIndex(index) or nil
    return tostring(name or index)
end

local function fillTypeNames(list)
    local names = {}
    for _, ft in ipairs(list or {}) do
        names[#names + 1] = fillTypeName(ft)
    end
    return #names > 0 and table.concat(names, "+") or "-"
end

-- mode Autonome du tracteur pendant l'étape « load » du plein (et le tracteur), sinon nil
function ADSeederRefill.loadingMode(vehicle)
    local root = vehicle
    if vehicle ~= nil and vehicle.getRootVehicle ~= nil then
        root = vehicle:getRootVehicle() or vehicle
    end
    if root == nil or root.ad == nil or root.ad.stateModule == nil or root.ad.modes == nil then
        return nil
    end
    if root.ad.stateModule:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return nil
    end
    local mode = root.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    if mode == nil or mode.refillStage ~= "load" or mode.refillPlan == nil or mode.refillPlan.marker == nil then
        return nil
    end
    return mode, root
end

-- point du réseau du point de ravitaillement
function ADSeederRefill.refillWayPoint(mode)
    local marker = mode.refillPlan ~= nil and mode.refillPlan.marker or nil
    if marker == nil then
        return nil
    end
    return ADGraphManager:getWayPointById(marker.id)
end

-- vraies cuves du semoir pour les produits choisis : la cuve de la semence et celle de l'engrais
-- (ADSeederManager.fillUnits), sinon toute cuve qui prend un produit choisi ; moins de TINY_CAPACITY l : ignorée
function ADSeederRefill.realUnits(tool, fillTypes)
    local units = {}
    local function wanted(i)
        local supported = tool:getFillUnitSupportedFillTypes(i) or {}
        for _, ft in ipairs(fillTypes or {}) do
            if supported[ft] then
                return true
            end
        end
        return false
    end
    local function add(i)
        if wanted(i) and (tool:getFillUnitCapacity(i) or 0) >= ADSeederRefill.TINY_CAPACITY then
            units[#units + 1] = i
        end
    end
    for _, i in ipairs(ADSeederManager.fillUnits(tool)) do
        add(i)
    end
    if #units == 0 then
        for i, _ in pairs(tool:getFillUnits()) do
            add(i)
        end
        table.sort(units)
    end
    return units
end

-- litres dans les cuves données, et leur contenance
function ADSeederRefill.unitsLevel(tool, units)
    local level, capacity = 0, 0
    for _, i in ipairs(units) do
        level = level + (tool:getFillUnitFillLevel(i) or 0)
        capacity = capacity + (tool:getFillUnitCapacity(i) or 0)
    end
    return level, capacity
end

function ADSeederRefill.planLevel(plan)
    if plan == nil or plan.tool == nil then
        return 0, 0
    end
    return ADSeederRefill.unitsLevel(plan.tool, ADSeederRefill.realUnits(plan.tool, plan.fillTypes))
end

-- 5. cuves choisies pleines, vraies cuves seulement (ADSeederManager.productsFull d'origine si aucune)
ADSeederRefill.originalProductsFull = ADSeederManager.productsFull
function ADSeederRefill.productsFull(tool, fillTypes, rootVehicle)
    local units = ADSeederRefill.realUnits(tool, fillTypes)
    if #units == 0 then
        return ADSeederRefill.originalProductsFull(tool, fillTypes, rootVehicle)
    end
    local level = AutoDrive.getSetting("unloadFillLevel", rootVehicle) or 1
    for _, i in ipairs(units) do
        local capacity = tool:getFillUnitCapacity(i) or 0
        if (tool:getFillUnitFillLevel(i) or 0) < capacity * level * 0.999 - 0.01 then
            return false
        end
    end
    return true
end

-- « cuve 1 SEEDS 2719/3500, cuve 2 FERTILIZER 2505/3500, cuve 3 SEEDS 0/1 ignorée » (nœud = exactFillRootNode)
function ADSeederRefill.unitsText(tool, fillTypes)
    local real = {}
    for _, i in ipairs(ADSeederRefill.realUnits(tool, fillTypes)) do
        real[i] = true
    end
    local indices = {}
    for i, _ in pairs(tool:getFillUnits()) do
        indices[#indices + 1] = i
    end
    table.sort(indices)
    local parts = {}
    for _, i in ipairs(indices) do
        local supported = tool:getFillUnitSupportedFillTypes(i) or {}
        local names = {}
        for _, ft in ipairs(fillTypes or {}) do
            if supported[ft] then
                names[#names + 1] = fillTypeName(ft)
            end
        end
        if #names > 0 then
            local unit = tool.getFillUnitByIndex ~= nil and tool:getFillUnitByIndex(i) or nil
            parts[#parts + 1] = string.format("cuve %s %s %.0f/%.0f%s%s", tostring(i), table.concat(names, "+"),
                tool:getFillUnitFillLevel(i) or 0, tool:getFillUnitCapacity(i) or 0,
                (unit ~= nil and unit.exactFillRootNode ~= nil) and " (noeud)" or "", real[i] and "" or " ignorée")
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "aucune cuve pour ces produits"
end

-- toutes les cuves d'un engin : « cuve 1 2719/3500, cuve 2 2505/3500, cuve 3 0/1 »
function ADSeederRefill.allUnitsText(tool)
    local indices = {}
    for i, _ in pairs(tool:getFillUnits()) do
        indices[#indices + 1] = i
    end
    table.sort(indices)
    local parts = {}
    for _, i in ipairs(indices) do
        parts[#parts + 1] = string.format("cuve %s %.0f/%.0f", tostring(i), tool:getFillUnitFillLevel(i) or 0, tool:getFillUnitCapacity(i) or 0)
    end
    return table.concat(parts, ", ")
end

-- nom de la zone de chargement (station ou bâtiment)
function ADSeederRefill.triggerName(trigger)
    local source = trigger.source
    if source ~= nil and source.getName ~= nil then
        local ok, name = FarmPilotCall(source.getName, source)
        if ok and name ~= nil then
            return tostring(name)
        end
    end
    local placeable = source ~= nil and source.owningPlaceable or nil
    if placeable ~= nil and placeable.getName ~= nil then
        local ok, name = FarmPilotCall(placeable.getName, placeable)
        if ok and name ~= nil then
            return tostring(name)
        end
    end
    return "?"
end

-- produits de la zone (attribut fillTypes du xml) ; sans liste, AutoDrive.fillTypesMatch refuse la zone
function ADSeederRefill.triggerFillTypesText(trigger)
    if trigger.fillableObjects == nil and trigger.source == nil then
        return "pas une zone de chargement"
    end
    if trigger.fillTypes == nil then
        return "aucune liste (AutoDrive n'y charge pas)"
    end
    local names = {}
    for ft, on in pairs(trigger.fillTypes) do
        if on then
            names[#names + 1] = fillTypeName(ft)
        end
    end
    table.sort(names)
    return #names > 0 and table.concat(names, "+") or "liste vide"
end

-- stock de la station pour les produits choisis (ce que regarde AutoDrive : source:getAllFillLevels)
function ADSeederRefill.stockText(trigger, vehicle, fillTypes)
    if trigger.hasInfiniteCapacity then
        return "infini"
    end
    local source = trigger.source
    if source == nil or source.getAllFillLevels == nil then
        return "inconnu (pas de station)"
    end
    local farmId = nil
    if vehicle.getActiveFarm ~= nil then
        farmId = vehicle:getActiveFarm()
    elseif vehicle.getOwnerFarmId ~= nil then
        farmId = vehicle:getOwnerFarmId()
    end
    local ok, levels = FarmPilotCall(source.getAllFillLevels, source, farmId)
    if not ok or type(levels) ~= "table" then
        return "illisible"
    end
    local parts = {}
    for _, ft in ipairs(fillTypes or {}) do
        parts[#parts + 1] = string.format("%s %s", fillTypeName(ft), levels[ft] ~= nil and string.format("%.0f l", levels[ft]) or "-")
    end
    return table.concat(parts, ", ")
end

-- engins du tracteur que la zone voit (LoadTrigger.fillableObjects = { object, fillUnitIndex }, rempli par le jeu
-- quand un noeud de remplissage de la cuve est dans le volume de la zone)
function ADSeederRefill.fillableText(trigger, vehicle, tool)
    local units = {}
    if AutoDrive.getAllUnits ~= nil then
        units = AutoDrive.getAllUnits(vehicle) or {}
    end
    local function label(object)
        if object == tool then
            return "semoir"
        elseif object == vehicle then
            return "tracteur"
        end
        for _, unit in ipairs(units) do
            if unit == object then
                return "autre engin du tracteur"
            end
        end
        return nil
    end
    local found, seen, others = {}, {}, 0
    for _, entry in pairs(trigger.fillableObjects or {}) do
        local object = type(entry) == "table" and entry.object or entry
        local fillUnitIndex = type(entry) == "table" and entry.fillUnitIndex or nil
        local name = label(object)
        if name == nil then
            others = others + 1
        else
            local key = name .. "|" .. tostring(fillUnitIndex)
            if not seen[key] then
                seen[key] = true
                found[#found + 1] = string.format("%s cuve %s", name, tostring(fillUnitIndex or "?"))
            end
        end
    end
    local text = #found > 0 and table.concat(found, ", ") or "non"
    if trigger.validFillableObject ~= nil and label(trigger.validFillableObject) ~= nil then
        text = text .. string.format(" (prêt : %s cuve %s)", label(trigger.validFillableObject), tostring(trigger.validFillableFillUnitIndex or "?"))
    end
    if others > 0 then
        text = text .. string.format(" ; %d autre(s) engin(s) dans la zone", others)
    end
    return text
end

function ADSeederRefill.loadingText(trigger)
    if trigger.isLoading then
        return "charge (" .. fillTypeName(trigger.selectedFillType) .. ")"
    end
    return "ne charge pas"
end

-- raison probable quand la tâche de chargement d'AutoDrive finit seule (LoadAtDestinationTask)
function ADSeederRefill.guessEnd(mode, task)
    local vehicle = mode.vehicle
    local parts = {}
    if AutoDrive.getSetting("unloadFillLevel", vehicle) == 0 then
        parts[#parts + 1] = "réglage « niveau de remplissage » à 0 %"
    end
    local rotate = AutoDrive.getSetting("rotateTargets", vehicle)
    if (rotate == AutoDrive.RT_ONLYPICKUP or rotate == AutoDrive.RT_PICKUPANDDELIVER) and AutoDrive.getSetting("useFolders") then
        parts[#parts + 1] = "rotation des cibles avec dossiers"
    end
    if task ~= nil and task.trailers ~= nil and #task.trailers > 0 and AutoDrive.getAllFillLevels ~= nil then
        local level, capacity, filled = AutoDrive.getAllFillLevels(task.trailers)
        if filled then
            parts[#parts + 1] = string.format("niveau de remplissage d'AutoDrive atteint (toutes les cuves, %.0f/%.0f l)", level or 0, capacity or 0)
        end
    end
    if #parts == 0 then
        parts[1] = "tâche de chargement finie sans raison connue (autre script)"
    end
    return table.concat(parts, ", ")
end

-- 4. diagnostic au point de ravitaillement (log) : portée d'AutoDrive, cuves, zones de chargement proches
function ADSeederRefill.diagnose(mode, why)
    local vehicle, plan = mode.vehicle, mode.refillPlan
    local name = vehicleName(vehicle)
    local sm = vehicle.ad.stateModule
    local tool = plan.tool
    local wp = ADSeederRefill.refillWayPoint(mode)
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local tx, tz = vx, vz
    if tool ~= nil and tool.components ~= nil and tool.components[1] ~= nil then
        tx, _, tz = getWorldTranslation(tool.components[1].node)
    end
    local toPoint = wp ~= nil and MathUtil.vector2Length(vx - wp.x, vz - wp.z) or -1
    local maxDistance = AutoDrive.getMaxTriggerDistance ~= nil and AutoDrive.getMaxTriggerDistance(vehicle) or 25
    local adDistance = AutoDrive.getDistanceToTargetPosition(vehicle)
    local inRange = AutoDrive.isInRangeToLoadUnloadTarget ~= nil and AutoDrive.isInRangeToLoadUnloadTarget(vehicle) or false
    local first = sm:getFirstMarker()
    local oldDistance = ADSeederRefill.originalDistance ~= nil and ADSeederRefill.originalDistance(vehicle) or nil
    local trailerModule = vehicle.ad.trailerModule
    local activeAtTrigger = trailerModule ~= nil and trailerModule.isActiveAtTrigger ~= nil and trailerModule:isActiveAtTrigger() or false
    log("%s : plein, %s « %s » : tracteur à %.0f m du point ; portée de chargement d'AutoDrive %.0f m (max %.0f m) : %s (sans le correctif : %s m, vers la 1re destination « %s ») ; chargement aux zones %s, zone en cours %s",
        name, why, tostring(plan.marker.name), toPoint, adDistance or -1, maxDistance or -1, inRange and "à portée" or "HORS PORTÉE",
        oldDistance ~= nil and string.format("%.0f", oldDistance) or "?", first ~= nil and tostring(first.name) or "?",
        yesNo(mode:shouldLoadOnTrigger()), yesNo(activeAtTrigger))
    local selected = sm.getSelectedFillTypes ~= nil and sm:getSelectedFillTypes() or nil
    log("%s : produits choisis %s (mode Chargement : %s) ; %s ; réglages : niveau de remplissage %s, rotation des cibles %s, dossiers %s",
        name, fillTypeNames(plan.fillTypes), fillTypeNames(selected), tool ~= nil and ADSeederRefill.unitsText(tool, plan.fillTypes) or "pas de semoir",
        tostring(AutoDrive.getSetting("unloadFillLevel", vehicle)), tostring(AutoDrive.getSetting("rotateTargets", vehicle)), tostring(AutoDrive.getSetting("useFolders")))
    if ADTriggerManager == nil or ADTriggerManager.getLoadTriggers == nil then
        log("%s :   zones de chargement : liste d'AutoDrive absente", name)
        return
    end
    local count, unplaced = 0, 0
    for _, trigger in pairs(ADTriggerManager.getLoadTriggers() or {}) do
        local x, _, z = ADTriggerManager.getTriggerPos(trigger)
        local seesTool = false
        for _, entry in pairs(trigger.fillableObjects or {}) do
            if type(entry) == "table" and entry.object == tool then
                seesTool = true
            end
        end
        local placed = x ~= nil and not (x == 0 and z == 0)
        local toTrigger = (placed and wp ~= nil) and MathUtil.vector2Length(x - wp.x, z - wp.z) or math.huge
        local toTool = placed and MathUtil.vector2Length(x - tx, z - tz) or math.huge
        if math.min(toTrigger, toTool) <= ADSeederRefill.DIAG_RADIUS or seesTool then
            count = count + 1
            log("%s :   zone %d « %s » en %s : %s m du point, %s m du semoir (AutoDrive : %.0f m max) ; produits %s ; stock %s ; semoir vu par la zone : %s ; %s",
                name, count, ADSeederRefill.triggerName(trigger), placed and string.format("%.0f,%.0f", x, z) or "position inconnue",
                toTrigger < math.huge and string.format("%.0f", toTrigger) or "?", toTool < math.huge and string.format("%.0f", toTool) or "?",
                maxDistance or -1, ADSeederRefill.triggerFillTypesText(trigger), ADSeederRefill.stockText(trigger, vehicle, plan.fillTypes),
                ADSeederRefill.fillableText(trigger, vehicle, tool), ADSeederRefill.loadingText(trigger))
        elseif not placed then
            unplaced = unplaced + 1
        end
    end
    if count == 0 then
        log("%s :   aucune zone de chargement à moins de %d m du point ni du semoir : AutoDrive ne peut rien charger ici%s", name,
            ADSeederRefill.DIAG_RADIUS, unplaced > 0 and string.format(" (%d zone(s) sans position ignorée(s))", unplaced) or "")
    end
end

-- arrivée au point (diagnostic une fois), puis attente sans que le niveau monte (état dans le log une fois)
function ADSeederRefill.watch(mode, dt)
    local task, plan, vehicle = mode.refillTask, mode.refillPlan, mode.vehicle
    if task == nil or plan == nil or vehicle.ad.taskModule:getActiveTask() ~= task then
        return
    end
    if task.state ~= LoadAtDestinationTask.STATE_DRIVING or not vehicle.ad.drivePathModule:isTargetReached() then
        return
    end
    local level = ADSeederRefill.planLevel(plan)
    local now = g_time or 0
    if task.fpArrival == nil then
        task.fpArrival = now
        task.fpLastLevel = level
        task.fpLastRise = now
        ADSeederRefill.diagnose(mode, "arrivé au point")
        return
    end
    if level > (task.fpLastLevel or 0) + 0.5 then
        task.fpLastLevel = level
        task.fpLastRise = now
        task.fpNoticeDone = nil
    elseif not task.fpNoticeDone and now - (task.fpLastRise or now) >= ADSeederRefill.WAIT_NOTICE then
        task.fpNoticeDone = true
        log("%s : rien n'entre dans le semoir depuis %.0f s au point « %s » : il attend le plein ou « Continuer »",
            vehicleName(vehicle), (now - (task.fpLastRise or now)) / 1000, tostring(plan.marker.name))
        ADSeederRefill.diagnose(mode, "attente au point")
    end
end

-- 3. fin de l'étape « load » : raison dans le log ; true = fin refusée, il reste au point (nouvelle tâche de plein)
function ADSeederRefill.onLoadEnd(mode)
    local vehicle, plan, task = mode.vehicle, mode.refillPlan, mode.refillTask
    local name = vehicleName(vehicle)
    if plan == nil or plan.tool == nil or plan.marker == nil then
        return false
    end
    if vehicle.ad.isStoppingWithError then
        log("%s : fin du plein : arrêt sur erreur d'AutoDrive", name)
        return false
    end
    local level = ADSeederRefill.planLevel(plan)
    local startLevel = task ~= nil and task.fpStartLevel or level
    local gained = level - startLevel
    local full = ADSeederRefill.productsFull(plan.tool, plan.fillTypes, vehicle)
    local reason = task ~= nil and task.fpEndReason or nil
    local tanks = ADSeederRefill.unitsText(plan.tool, plan.fillTypes)
    if reason == nil then
        reason = full and "cuves choisies pleines" or ADSeederRefill.guessEnd(mode, task)
    end
    if full or (task ~= nil and task.fpEndReason ~= nil) or gained > ADSeederRefill.LOADED_MIN then
        log("%s : fin du plein (%s) : %.0f l chargés, %s", name, reason, gained, tanks)
        mode.fpRefusals = nil
        return false
    end
    log("%s : fin du plein refusée (%s) : rien chargé, pas plein (%s) ; il reste au point « %s » jusqu'au plein ou « Continuer »",
        name, reason, tanks, tostring(plan.marker.name))
    if printCallstack ~= nil then
        log("%s : pile d'appels de cette fin (qui a fini la tâche) :", name)
        printCallstack()
    end
    local now = g_time or 0
    local recent = {}
    for _, t in ipairs(mode.fpRefusals or {}) do
        if now - t < ADSeederRefill.LOOP_WINDOW then
            recent[#recent + 1] = t
        end
    end
    recent[#recent + 1] = now
    mode.fpRefusals = recent
    if #recent >= ADSeederRefill.LOOP_MAX then
        log("%s : %d fins refusées en moins de %.0f s : arrêt au point « %s », le joueur reprend la main", name, #recent,
            ADSeederRefill.LOOP_WINDOW / 1000, tostring(plan.marker.name))
        mode.fpRefusals = nil
        mode.refillTask = nil
        mode.refillStage = nil
        mode.refillPlan = nil
        mode.refillThen = nil
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_seederFill", tostring(plan.marker.name))
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
        return true
    end
    local ok, err = FarmPilotCall(ADSeederRefill.diagnose, mode, "fin refusée au point")
    if not ok then
        log("ERREUR diagnostic du plein : %s", tostring(err))
    end
    mode.refillTask = nil
    mode:startRefillLoad()
    return true
end

-- 7. Courseplay « cuve vide » : ce qui peut empêcher le plein sans autre ligne dans le log
function ADSeederRefill.cpEmptyState(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil then
        return "véhicule sans FarmPilot"
    end
    local sm = vehicle.ad.stateModule
    local parts = {}
    parts[#parts + 1] = "serveur " .. yesNo(vehicle.isServer)
    parts[#parts + 1] = "mode " .. (sm:getMode() == AutoDrive.MODE_AUTONOMOUS and "Autonome" or tostring(sm:getMode()))
    parts[#parts + 1] = "FarmPilot actif " .. yesNo(sm:isActive())
    local job = false
    local aiSystem = g_currentMission ~= nil and g_currentMission.aiSystem or nil
    if aiSystem ~= nil and aiSystem.activeJobVehicles ~= nil then
        for _, jobVehicle in pairs(aiSystem.activeJobVehicles) do
            if jobVehicle == vehicle then
                job = true
            end
        end
    end
    parts[#parts + 1] = "ouvrier encore enregistré " .. (job and "oui (FarmPilot ne peut pas démarrer)" or "non")
    if vehicle.getCpSettings ~= nil then
        local ok, settings = FarmPilotCall(vehicle.getCpSettings, vehicle)
        if ok and settings ~= nil and settings.refillOnTheField ~= nil and settings.refillOnTheField.getValue ~= nil then
            parts[#parts + 1] = "Courseplay plein dans le champ " .. tostring(settings.refillOnTheField:getValue())
        end
    end
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if info ~= nil then
        parts[#parts + 1] = string.format("ouvrier achète semence %s, engrais %s", tostring(info.helperBuySeeds), tostring(info.helperBuyFertilizer))
    end
    local ok, ctx = FarmPilotCall(ADSeederManager.context, vehicle, false)
    if ok and ctx ~= nil and ctx.tool ~= nil then
        parts[#parts + 1] = "semoir " .. ADSeederRefill.allUnitsText(ctx.tool)
    else
        parts[#parts + 1] = "pas de semoir sur la ligne Outil"
    end
    return table.concat(parts, ", ")
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonctions principales (branchées sur AutoDrive, AutonomousMode et ADSeederManager)
-- ------------------------------------------------------------------------------------------------------------

-- 1. portée de chargement mesurée au point de ravitaillement pendant le plein (le mode Chargement mesure à sa
-- destination de chargement, AutonomousMode à la 1re destination = le champ)
ADSeederRefill.originalDistance = AutoDrive.getDistanceToTargetPosition
function AutoDrive.getDistanceToTargetPosition(vehicle, ...)
    local mode, root = ADSeederRefill.loadingMode(vehicle)
    if mode ~= nil and vehicle.components ~= nil and vehicle.components[1] ~= nil then
        local wp = ADSeederRefill.refillWayPoint(mode)
        if wp ~= nil then
            local x, _, z = getWorldTranslation(vehicle.components[1].node)
            local distance = MathUtil.vector2Length(x - wp.x, z - wp.z)
            local drivePath = root.ad.drivePathModule
            if drivePath ~= nil and drivePath.getIsReversing ~= nil and drivePath:getIsReversing() then
                distance = distance - AutoDrive.getTractorTrainLength(root, true)
            end
            return distance
        end
    end
    if ADSeederRefill.originalDistance ~= nil then
        return ADSeederRefill.originalDistance(vehicle, ...)
    end
    return math.huge
end

-- 5. plein = vraies cuves du semoir
ADSeederManager.productsFull = ADSeederRefill.productsFull

-- nouveau plein : compteur de fins refusées remis à zéro
ADSeederRefill.originalStartRefill = AutonomousMode.startRefill
function AutonomousMode:startRefill(plan, after)
    self.fpRefusals = nil
    return ADSeederRefill.originalStartRefill(self, plan, after)
end

-- 2. tâche de plein : pas de départ « silo vide » (crochet dans Addon/SiloEmpty.lua), niveau au départ noté
ADSeederRefill.originalStartRefillLoad = AutonomousMode.startRefillLoad
function AutonomousMode:startRefillLoad()
    ADSeederRefill.originalStartRefillLoad(self)
    local task = self.refillTask
    if task ~= nil then
        task.fpKeepLoading = true
        task.fpStartLevel = ADSeederRefill.planLevel(self.refillPlan)
    end
end

-- 4. diagnostic à l'arrivée et pendant l'attente, puis le suivi d'origine (cuves pleines = fini)
ADSeederRefill.originalMonitorRefill = AutonomousMode.monitorRefill
function AutonomousMode:monitorRefill(dt)
    local ok, err = FarmPilotCall(ADSeederRefill.watch, self, dt)
    if not ok then
        log("ERREUR diagnostic du plein : %s", tostring(err))
    end
    return ADSeederRefill.originalMonitorRefill(self, dt)
end

-- « Continuer » du joueur : seule façon de repartir sans avoir chargé
ADSeederRefill.originalContinue = AutonomousMode.continue
function AutonomousMode:continue()
    if self.refillStage == "load" and self.refillTask ~= nil then
        self.refillTask.fpEndReason = "Continuer (joueur)"
    end
    return ADSeederRefill.originalContinue(self)
end

-- 3. fin de l'étape « load » : raison dans le log, refusée si rien n'est entré (pas plein, pas Continuer)
ADSeederRefill.originalHandleRefillStage = AutonomousMode.handleRefillStage
function AutonomousMode:handleRefillStage()
    if self.refillStage == "load" then
        local ok, stay = FarmPilotCall(ADSeederRefill.onLoadEnd, self)
        if not ok then
            log("ERREUR fin du plein : %s", tostring(stay))
        elseif stay then
            return
        end
    end
    return ADSeederRefill.originalHandleRefillStage(self)
end

-- 7. Courseplay « cuve vide » : état avant, plein lancé ou non après
ADSeederRefill.originalOnCpEmpty = AutonomousMode.onCpEmpty
function AutonomousMode.onCpEmpty(vehicle)
    local ok, state = FarmPilotCall(ADSeederRefill.cpEmptyState, vehicle)
    local started = ADSeederRefill.originalOnCpEmpty(vehicle)
    log("%s : Courseplay signale une cuve vide (onCpEmpty) : %s -> plein %s", vehicleName(vehicle), ok and tostring(state) or "?",
        started and "lancé" or "pas lancé")
    return started
end
