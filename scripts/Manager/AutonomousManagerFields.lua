-- ============================================================================================================
-- FarmPilot : AutonomousManagerFields.lua
-- Complément de AutonomousManager.lua (mode Autonome) : les champs.
--
-- Règle :
-- - Champ du travail : celui du marqueur de destination (son numéro, « Champ 56 »), s'il est à moins de
--   MARKER_FIELD_RANGE m ; sinon le champ sous le véhicule ; sinon le plus proche (anneaux de 15 m jusqu'à 150 m).
-- - Champs regroupés : AutoSwitch installé, ses groupes (champs réunis en un seul contour) ; sinon chaque champ seul.
--   Un parcours qui couvre plusieurs groupes (ex. « Champ 52_53 ») forme une ligne à lui.
-- - (07/11) Courseplay absent, réglage « Autonome sans Courseplay » sur Ouvrier du jeu : l'ouvrier du jeu prend le
--   champ (mode « Classique »).
--
-- Branché par : AutonomousManager.lua (choose), AutonomousManagerCourses.lua (champs couverts par un parcours),
-- AutonomousMode.lua (nearField), Specialization.lua (startBaseWorker), AutoDrive.lua (AIJobFieldWork.stop ->
-- onAIJobFieldWorkStop), SprayerManager.lua (surface du champ), AutonomousCoursesGUI.lua (fieldsLabel).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAutonomousManager.MARKER_FIELD_RANGE = 100     -- m : champ du marqueur cherché jusqu'à cette distance (markerField)
ADAutonomousManager.COURSE_FIELD_SHARE = 0.2   -- part des points pour qu'un champ compte dans un parcours

local log = ADAutonomousManager.log   -- la fonction de AutonomousManager.lua

-- ------------------------------------------------------------------------------------------------------------
-- Champ sous un point, numéro, même champ
-- ------------------------------------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------------------------------------
-- Champ du marqueur de destination (« Champ 56 »)
-- ------------------------------------------------------------------------------------------------------------
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

-- (07/11) envoyé au champ 56, il prenait le 52 voisin : le champ du marqueur
-- (son numéro), s'il est à moins de 100 m : sous le véhicule, puis anneaux de 5 m
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

-- ------------------------------------------------------------------------------------------------------------
-- Ouvrier du jeu (mode « Classique », sans Courseplay)
-- ------------------------------------------------------------------------------------------------------------
-- (07/11) mode « Classique » : l'ouvrier du jeu prend le champ quand Courseplay est absent (réglage « Autonome sans Courseplay » sur Ouvrier du jeu).
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

-- ------------------------------------------------------------------------------------------------------------
-- Champs regroupés
--   AutoSwitch installé : ses groupes (fenêtre Champs : champs réunis en un seul contour),
--   clé = champ principal calculé par AutoSwitch. Sinon chaque champ seul.
--   Un parcours qui couvre plusieurs groupes (ex. « Champ 52_53 ») forme une ligne à lui.
-- ------------------------------------------------------------------------------------------------------------
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
