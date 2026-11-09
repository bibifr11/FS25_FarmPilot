-- ============================================================================================================
-- FarmPilot : BalerManager.lua
-- Mode Autonome : la presse à balles (09/11).
--
-- Règle :
-- - Une presse ne travaille pas à sa propre largeur : elle ramasse les andains laissés par la machine passée avant
--   (moissonneuse : paille ; andaineur : herbe, foin). Courseplay ne cherche pas les andains, il suit le parcours
--   chargé.
-- - Au champ, au lieu du parcours à la largeur de l'outil, on prend le parcours Courseplay du champ (toutes
--   largeurs) qui tombe le mieux sur les andains au sol : chaque parcours qui couvre le groupe du champ est lu en
--   entier, des points de contrôle sont pris le long de son tracé (au plus MAX_PROBES, tous les PROBE_STEP_MIN m au
--   moins) et on compte ceux qui ont un andain sous eux (hauteur de tas du jeu, produits que la presse ramasse).
--   Le meilleur gagne s'il en touche au moins MIN_SCORE ; sinon arrêt et attente (« noWindrow »).
-- - Courseplay conduit ensuite le parcours choisi et gère la presse (balles, enrubannage, décalage du pick-up).
-- - Le choix n'est pas retenu : les andains changent à chaque récolte, il est refait à chaque arrivée au champ.
--
-- Branché par : AutonomousManager.lua (choose : presse attelée), AutonomousMode.lua (message « noWindrow »).
-- ============================================================================================================

ADBalerManager = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADBalerManager.MAX_PROBES = 300          -- points de contrôle au plus par parcours
ADBalerManager.PROBE_STEP_MIN = 3        -- m entre deux points de contrôle, au moins
ADBalerManager.PROBE_HALF_LENGTH = 0.5   -- m : demi-longueur de la zone regardée sous un point (le long du tracé)
ADBalerManager.PROBE_HALF_WIDTH = 0.75   -- m : demi-largeur (en travers) : un andain fait 1,5 à 2 m de large
ADBalerManager.MIN_SCORE = 0.25          -- part des points sur un andain pour retenir un parcours
ADBalerManager.MAX_WAYPOINTS = 20000     -- garde-fou : points lus par fichier de parcours
-- produits d'andain si la presse ne dit pas ce qu'elle ramasse
ADBalerManager.FALLBACK_FILLTYPES = { "STRAW", "GRASS_WINDROW", "DRYGRASS_WINDROW" }

local function log(fmt, ...)
    print("[FarmPilot Presse] " .. string.format(fmt, ...))
end
ADBalerManager.log = log

-- ------------------------------------------------------------------------------------------------------------
-- La presse attelée (ou automotrice)
-- ------------------------------------------------------------------------------------------------------------
local function findBaler(object, depth)
    if object == nil or depth > 6 then
        return nil
    end
    if object.spec_baler ~= nil then
        return object
    end
    if object.getAttachedImplements == nil then
        return nil
    end
    local ok, implements = pcall(object.getAttachedImplements, object)
    if not ok or type(implements) ~= "table" then
        return nil
    end
    for _, impl in ipairs(implements) do
        local b = findBaler(impl.object, depth + 1)
        if b ~= nil then
            return b
        end
    end
    return nil
end

function ADBalerManager.baler(vehicle)
    return findBaler(vehicle, 0)
end

-- produits d'andain que la presse ramasse (seulement ceux qui peuvent être au sol en tas)
function ADBalerManager.windrowTypes(baler)
    local list, seen = {}, {}
    local hm = g_densityMapHeightManager
    local function add(ft)
        if ft ~= nil and not seen[ft] and (hm == nil or hm.getDensityMapHeightTypeByFillTypeIndex == nil
            or hm:getDensityMapHeightTypeByFillTypeIndex(ft) ~= nil) then
            seen[ft] = true
            list[#list + 1] = ft
        end
    end
    local spec = baler ~= nil and baler.spec_baler or nil
    if spec ~= nil and spec.fillUnitIndex ~= nil and baler.getFillUnitSupportedFillTypes ~= nil then
        local ok, types = pcall(baler.getFillUnitSupportedFillTypes, baler, spec.fillUnitIndex)
        if ok and type(types) == "table" then
            for ft, supported in pairs(types) do
                if supported then
                    add(ft)
                end
            end
        end
    end
    if #list == 0 and g_fillTypeManager ~= nil then
        for _, name in ipairs(ADBalerManager.FALLBACK_FILLTYPES) do
            add(g_fillTypeManager:getFillTypeIndexByName(name))
        end
    end
    table.sort(list)
    return list
end

-- ------------------------------------------------------------------------------------------------------------
-- Andains au sol
-- ------------------------------------------------------------------------------------------------------------
-- true si un andain (un des produits) est sous le point x, z ; dx, dz = sens du tracé (unitaire)
function ADBalerManager.hasWindrow(x, z, dx, dz, types)
    if DensityMapHeightUtil == nil or DensityMapHeightUtil.getFillLevelAtArea == nil then
        return false
    end
    local hl, hw = ADBalerManager.PROBE_HALF_LENGTH, ADBalerManager.PROBE_HALF_WIDTH
    local px, pz = -dz, dx   -- en travers
    local sx, sz = x - dx * hl - px * hw, z - dz * hl - pz * hw
    local wx, wz = sx + px * 2 * hw, sz + pz * 2 * hw
    local hx, hz = sx + dx * 2 * hl, sz + dz * 2 * hl
    for _, ft in ipairs(types) do
        local ok, level = pcall(DensityMapHeightUtil.getFillLevelAtArea, ft, sx, sz, wx, wz, hx, hz)
        if ok and level ~= nil and level > 0 then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Tracé complet d'un parcours Courseplay
-- ------------------------------------------------------------------------------------------------------------
-- tous les points du fichier (x, z), dans l'ordre
function ADBalerManager.readLine(path)
    if path == nil or not fileExists(path) then
        return nil
    end
    local xml = loadXMLFile("fpCpBalerCourse", path)
    if xml == nil or xml == 0 then
        return nil
    end
    local pts = {}
    local base = "Courses.Course(0)"
    local i = 0
    while i < ADBalerManager.MAX_WAYPOINTS do
        local key = string.format("%s.wp(%d)", base, i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local pos = getXMLString(xml, key .. "#position")
        if pos ~= nil then
            local x, _, z = pos:match("^%s*(%S+)%s+(%S+)%s+(%S+)")
            x, z = tonumber(x), tonumber(z)
            if x ~= nil and z ~= nil then
                pts[#pts + 1] = { x, z }
            end
        end
        i = i + 1
    end
    delete(xml)
    return pts
end

-- part du tracé posée sur un andain : touchés, contrôlés
function ADBalerManager.score(pts, types)
    if pts == nil or #pts < 2 then
        return 0, 0
    end
    local total = 0
    for i = 2, #pts do
        total = total + MathUtil.vector2Length(pts[i][1] - pts[i - 1][1], pts[i][2] - pts[i - 1][2])
    end
    if total <= 0 then
        return 0, 0
    end
    local step = math.max(ADBalerManager.PROBE_STEP_MIN, total / ADBalerManager.MAX_PROBES)
    local hits, probes = 0, 0
    local nextAt = step / 2
    local done = 0
    for i = 2, #pts do
        local ax, az, bx, bz = pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2]
        local len = MathUtil.vector2Length(bx - ax, bz - az)
        if len > 0 then
            local dx, dz = (bx - ax) / len, (bz - az) / len
            while nextAt <= done + len do
                local t = nextAt - done
                probes = probes + 1
                if ADBalerManager.hasWindrow(ax + dx * t, az + dz * t, dx, dz, types) then
                    hits = hits + 1
                end
                nextAt = nextAt + step
            end
            done = done + len
        end
    end
    return hits, probes
end

-- ------------------------------------------------------------------------------------------------------------
-- Choix du parcours (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
-- courses : liste de listCourses ; g : groupe du champ (groupOf). Renvoie e, ou nil + "noWindrow".
function ADBalerManager.choose(vehicle, courses, g)
    local baler = ADBalerManager.baler(vehicle)
    local types = ADBalerManager.windrowTypes(baler)
    local names = {}
    for _, ft in ipairs(types) do
        names[#names + 1] = g_fillTypeManager ~= nil and tostring(g_fillTypeManager:getFillTypeNameByIndex(ft)) or tostring(ft)
    end
    log("presse : recherche des andains (%s) sur le groupe %s", table.concat(names, ", "), tostring(g ~= nil and g.key or "?"))
    if g == nil or #types == 0 then
        return nil, "noWindrow"
    end
    local best, bestScore, tested = nil, 0, 0
    for _, e in ipairs(courses or {}) do
        if e.groupKeys ~= nil and e.groupKeys[g.key] then
            local okR, pts = pcall(ADBalerManager.readLine, e.path)
            if okR and pts ~= nil then
                local hits, probes = ADBalerManager.score(pts, types)
                local s = probes > 0 and hits / probes or 0
                tested = tested + 1
                log("  parcours « %s » (%s m) : %d / %d points sur un andain (%.0f %%)", ADAutonomousManager.courseLabel(e),
                    tostring(e.w), hits, probes, s * 100)
                if s > bestScore then
                    best, bestScore = e, s
                end
            end
        end
    end
    if best ~= nil and bestScore >= ADBalerManager.MIN_SCORE then
        log("presse : parcours « %s » retenu (%.0f %% sur les andains, %d parcours regardés)", ADAutonomousManager.courseLabel(best),
            bestScore * 100, tested)
        return best
    end
    log("presse : aucun parcours ne tombe sur les andains (%d parcours regardés, meilleur %.0f %%)", tested, bestScore * 100)
    return nil, "noWindrow"
end
