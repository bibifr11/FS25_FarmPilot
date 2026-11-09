-- ============================================================================================================
-- FarmPilot : AutonomousManagerCourses.lua
-- Complément de AutonomousManager.lua (mode Autonome) : les parcours enregistrés de Courseplay (menu Courseplay >
-- Parcours).
--
-- Règle :
-- - Fichier de parcours lu une fois (cache) : largeur, nom et SAMPLES points répartis sur tout le parcours, pour
--   trouver ses champs. Au plus MAX_FILES fichiers.
-- - (07/11) lecture pendant le trajet : au départ du mode Autonome, la liste des fichiers est relue et le cache vidé,
--   puis les parcours sont lus un par image (PREFETCH_PER_FRAME). À l'arrivée il ne reste presque rien à lire.
-- - Candidats : les parcours qui couvrent le groupe du champ, à la bonne largeur.
--
-- Branché par : AutonomousManager.lua (choose), AutonomousMode.lua (startPrefetch au départ, prefetchStep à chaque
-- image), AutonomousCoursesGUI.lua (listCourses, courseLabel), Specialization.lua (courseLabel).
-- ============================================================================================================

local log = ADAutonomousManager.log   -- la fonction de AutonomousManager.lua

-- ------------------------------------------------------------------------------------------------------------
-- Lecture des fichiers de parcours
-- ------------------------------------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------------------------------------
-- Lecture pendant le trajet
-- ------------------------------------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------------------------------------
-- Liste des parcours, candidats d'un champ
-- ------------------------------------------------------------------------------------------------------------
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
