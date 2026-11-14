-- ============================================================================================================
-- FarmPilot : DriveGoal.lua
-- Titre de l'ATH pendant un trajet : « Conduire - <but> » au lieu de « Conduire jusqu'à destination ».
--
-- Règles (11/11) :
-- - Chaque trajet dit ce que fait le véhicule : « Conduire - recharge en chaux à Chaux Coopé le mechet »,
--   « Conduire - travail au Champ 52 », « Conduire - retour au Champ 52 », « Conduire - vider le reste de chaux à … ».
-- - Le but est posé par le mode qui lance le trajet (ADDriveGoal.set) ; sans but posé, il vient du type de tâche :
--   recharge, déchargement, carburant, atelier, sinon « vers <destination> ».
-- - Arrivé au point (chargement, déchargement, carburant, atelier) : le but seul, sans « Conduire »
--   (« Recharge en chaux à … »).
-- - Le calcul de route, l'attente (croisement, file) et les autres étapes gardent leur texte.
-- - Ça doit tenir dans l'ATH : chaque but a une forme longue (avec le lieu) puis des formes de plus en plus
--   courtes (clés _short, _tiny, _min : « recharge en chaux », « recharge au point », « recharge ») ;
--   l'ATH prend la plus longue qui tient sur la ligne (HudIcon.lua, splitTextByLength), et « Conduire - <but> »
--   n'est jamais coupé en deux lignes.
-- - Texte envoyé à l'ATH (et aux autres joueurs) : [« Conduire » \30] longue \31 courte \31 ... ;
--   « - » dans un nom = \29. Les autres lecteurs (getCurrentLocalizedTaskInfo) reçoivent la forme longue en clair
--   (ADDriveGoal.plain).
--
-- Branché par : TaskModule.lua (update et onTaskChange, une ligne chacun) ; buts posés dans les modes
-- (AutonomousMode.lua, AutonomousRefill.lua, AutonomousFuel.lua, AutonomousSprayerDump.lua, AutonomousBales.lua,
-- AutonomousFront.lua, TrailerSwap.lua, TrailerHitch.lua, CombineUnloaderMode.lua, CombineUnloaderModeJobDone.lua).
-- ============================================================================================================

ADDriveGoal = {}

-- textes « Conduire jusqu'à … » remplacés, et le but par défaut de chacun
ADDriveGoal.KINDS = {
    ["$l10n_AD_task_drive_to_destination;"] = "drive",
    ["$l10n_AD_task_drive_to_load_point;"] = "load",
    ["$l10n_AD_task_drive_to_unload_point;"] = "unload",
    ["$l10n_AD_task_drive_to_refuel_point;"] = "refuel",
    ["$l10n_AD_task_drive_to_repair_point;"] = "repair"
}
ADDriveGoal.DEFAULT_KEYS = {
    drive = "AD_fpGoal_to",
    load = "AD_fpGoal_load",
    unload = "AD_fpGoal_unload",
    refuel = "AD_fpGoal_refuel",
    repair = "AD_fpGoal_repair"
}

-- but posé par le mode qui lance le trajet : clé de traduction (avec %s) et ses valeurs
function ADDriveGoal.set(task, key, ...)
    if task ~= nil and key ~= nil then
        local args = {}
        for i = 1, select("#", ...) do
            args[i] = tostring(select(i, ...))
        end
        task.fpGoal = { key = key, args = args }
        task.fpGoalCache = nil
    end
    return task
end

-- nom de la destination de la tâche (marqueur), nil si ce n'est pas un marqueur
function ADDriveGoal.destinationName(task)
    local id = task ~= nil and task.destinationID or nil
    if id == nil or ADGraphManager == nil then
        return nil
    end
    local marker = ADGraphManager:getMapMarkerByWayPointId(id)
    return marker ~= nil and marker.name or nil
end

-- première lettre en minuscule (« Chaux » -> « chaux ») ou en majuscule ; lettres non ASCII laissées telles quelles
local function lowerFirst(text)
    return (string.gsub(text, "^%u", string.lower))
end

local function upperFirst(text)
    return (string.gsub(text, "^%l", string.upper))
end

-- noms des produits (« semences + engrais »)
function ADDriveGoal.productNames(fillTypes)
    local names = {}
    for _, fillType in ipairs(fillTypes or {}) do
        local desc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByIndex(fillType) or nil
        if desc ~= nil and desc.title ~= nil then
            names[#names + 1] = lowerFirst(tostring(desc.title))
        end
    end
    if #names == 0 then
        return nil
    end
    return table.concat(names, " + ")
end

-- produit le plus présent dans l'outil (« chaux »)
function ADDriveGoal.productOf(tool)
    if tool == nil or tool.getFillUnits == nil then
        return nil
    end
    local best, bestLevel = nil, 0
    for fillUnitIndex, _ in pairs(tool:getFillUnits()) do
        local level = tool:getFillUnitFillLevel(fillUnitIndex) or 0
        local fillType = tool:getFillUnitFillType(fillUnitIndex)
        if level > bestLevel and fillType ~= nil then
            best, bestLevel = fillType, level
        end
    end
    return best ~= nil and ADDriveGoal.productNames({ best }) or nil
end

-- texte du but (déjà traduit) : forme longue et forme courte, nil si on ne sait pas où va le véhicule
ADDriveGoal.JOIN = "\30"     -- entre « Conduire » et le but : jamais coupé
ADDriveGoal.SHORT = "\31"    -- entre une forme et la suivante, plus courte
ADDriveGoal.FORMS = { "", "_short", "_tiny", "_min" } -- clés des formes, de la plus longue à la plus courte
ADDriveGoal.LEVELS = #ADDriveGoal.FORMS
ADDriveGoal.DASH = "\29"     -- « - » dans un nom (« Champ 52 - 53 »), pour que l'ATH ne coupe pas le nom

local function format(key, args)
    local ok, text = FarmPilotCall(string.format, g_i18n:getText(key), unpack(args))
    if not ok or text == nil or text == "" then
        return nil
    end
    return text
end

function ADDriveGoal.text(task, kind)
    local key, args
    if task.fpGoal ~= nil then
        key, args = task.fpGoal.key, task.fpGoal.args
    else
        local name = ADDriveGoal.destinationName(task)
        if name == nil then
            return nil
        end
        key, args = ADDriveGoal.DEFAULT_KEYS[kind], { tostring(name) }
    end
    if key == nil or g_i18n == nil then
        return nil
    end
    local clean = {}
    for i, arg in ipairs(args) do
        clean[i] = (string.gsub(arg, " %- ", ADDriveGoal.DASH))
    end
    local long = format(key, clean)
    if long == nil then
        return nil
    end
    local forms = { long }
    for i = 2, #ADDriveGoal.FORMS do
        local formKey = key .. ADDriveGoal.FORMS[i]
        if not g_i18n:hasText(formKey) then
            break
        end
        forms[#forms + 1] = format(formKey, clean) or long
    end
    return forms
end

-- texte de l'ATH : celui de la tâche, ou « Conduire - <but> » pendant un trajet
function ADDriveGoal.apply(vehicle, task, info)
    local kind = (task ~= nil and info ~= nil) and ADDriveGoal.KINDS[info] or nil
    if kind == nil then
        return info
    end
    local arrived = false
    if kind ~= "drive" and vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.drivePathModule ~= nil then
        arrived = vehicle.ad.drivePathModule:isTargetReached() == true
    end
    local cacheKey = arrived and (info .. "|arrive") or info
    if task.fpGoalCache == nil or task.fpGoalCache.key ~= cacheKey then
        local forms = ADDriveGoal.text(task, kind)
        local result = info
        if forms ~= nil then
            if arrived then
                for i, form in ipairs(forms) do
                    forms[i] = upperFirst(form)
                end
                result = table.concat(forms, ADDriveGoal.SHORT)
            else
                result = "$l10n_AD_fpGoal_drive;" .. ADDriveGoal.JOIN .. table.concat(forms, ADDriveGoal.SHORT)
            end
        end
        task.fpGoalCache = { key = cacheKey, text = result }
    end
    return task.fpGoalCache.text
end

-- forme longue en clair (« Conduire - recharge en chaux à Chaux Coopé le mechet »)
function ADDriveGoal.plain(text)
    if text == nil or string.find(text, "[\29\30\31]") == nil then
        return text
    end
    text = string.gsub(text, "\31.*$", "")
    text = string.gsub(text, "[\29\30]", " - ")
    return text
end

-- une partie du titre de l'ATH à la forme level (1 la plus longue ; au-delà de la dernière : la dernière) ; texte
-- inchangé s'il ne vient pas d'ici
function ADDriveGoal.shown(part, level)
    if part == nil or string.find(part, "[\29\30\31]") == nil then
        return part
    end
    local head, body = string.match(part, "^(.-)\30(.*)$")
    body = body or part
    local forms = {}
    for form in string.gmatch(body .. "\31", "(.-)\31") do
        forms[#forms + 1] = form
    end
    local text = forms[math.min(level or 1, #forms)] or body
    text = string.gsub(text, "\29", " - ")
    if head ~= nil then
        text = head .. " - " .. text
    end
    return text
end
