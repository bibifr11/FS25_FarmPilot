-- ============================================================================================================
-- FarmPilot : WindrowScan.lua
-- Mode Autonome, presse sans Courseplay : repérage des andains au sol d'un champ (15/11).
--
-- Règle :
-- - Le tas au sol du jeu (DensityMapHeightUtil, produits que la presse ramasse : ADBalerManager.windrowTypes) est lu
--   sur une grille de STEP m (1 m) qui couvre les champs du groupe AutoSwitch et EDGE m autour (10 m). Une case
--   hors des champs du groupe compte si elle n'est sur aucun autre champ et plus près d'un champ du groupe que de
--   tout autre champ : l'andain du voisin est ignoré.
-- - Lecture par morceaux : scan:update(budget) à chaque image, budget = lectures du tas permises à cette image ; le
--   calcul de la ligne médiane qui suit est compté aussi (WORK_COST par case traitée) : jamais de pic de calcul.
--   Lecture d'abord par blocs de BLOCK cases (4 m) : un bloc vide coûte une lecture, un bloc avec un andain est
--   relu case par case (une lecture par case et par produit présent dans le bloc).
-- - Extraction : trous d'une case bouchés ; amincissement (squelette d'une case de large, centré) ; graphe (bouts,
--   croisements) ; bavures de moins de SPUR m et petites boucles (trou dans un tas) enlevées ; à un croisement, les
--   deux branches qui se suivent le mieux (écart < MAX_TURN) forment le même andain, les autres s'y arrêtent (bout
--   d'andain qui touche l'andain de fourrière) ; tour de fourrière fermé = un andain fermé (closed), coupé au virage
--   le plus serré ; bouts libres prolongés dans l'axe tant qu'il y a de l'andain (l'amincissement les raccourcit) ;
--   deux bouts libres face à face à moins de GAP m (à la case près) réunis ; morceaux de moins de MIN_LENGTH m
--   ignorés ; ligne lissée, un point tous les POINT_SPACING m (2 m).
-- - Andain : { id, points = { {x=, z=}, ... } (ligne médiane ordonnée, à suivre de points[1] à points[#points]),
--   length (m), fillType, liters, closed } ; un andain fermé finit sur son premier point.
-- - centerOffset : bandes de CROSS_STEP m en travers de la direction, milieu (pondéré par les litres) de l'andain le
--   plus proche de la direction ; + = à droite de la direction (droite de (dx, dz) = (-dz, dx)).
-- - amountAt : même lecture que ADBalerManager.hasWindrow (getFillLevelAtArea sur un parallélogramme centré).
-- - anyLeft : contrôle rapide par grands blocs (ANY_BLOCK m), vrai dès qu'un bloc du groupe a ANY_MIN_LITERS l.
-- - Journal [FarmPilot Presse] : début et fin du scan (andains, longueurs, images, lectures).
--
-- Branché par : AutonomousWindrow.lua (scan à l'arrivée au champ et à la reprise, anyLeft), WindrowBaleTask.lua
-- (windrows, centerOffset, amountAt). Source dans register.lua (avant BalerControl.lua).
-- ============================================================================================================

ADWindrowScan = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADWindrowScan.STEP = 1               -- m : côté d'une case de la grille
ADWindrowScan.MIN_LENGTH = 5         -- m : andain plus court ignoré
ADWindrowScan.GAP = 3                -- m : trou plus court réuni (bouts face à face)
ADWindrowScan.EDGE = 10              -- m lus autour des champs du groupe
ADWindrowScan.POINT_SPACING = 2      -- m entre deux points de la ligne médiane
ADWindrowScan.BLOCK = 4              -- cases par côté d'un bloc lu d'un coup
ADWindrowScan.BUDGET = 400           -- lectures par image si update() n'a pas de budget
ADWindrowScan.WORK_COST = 0.1        -- une case traitée par le calcul = WORK_COST lecture
ADWindrowScan.CELL_INSET = 0.05      -- m : case lue un peu plus petite (pas de pixel compté dans deux cases)
ADWindrowScan.SPUR = 3               -- m : branche de squelette vers un bout libre plus courte = bavure
ADWindrowScan.LOOP_MIN = 8           -- m : petite boucle de squelette (trou dans le tas) enlevée
ADWindrowScan.DIR_DIST = 4           -- m : direction d'une branche prise à cette distance du croisement
ADWindrowScan.MAX_TURN = 60          -- ° : à un croisement de 3 branches ou plus, deux branches se suivent sous cet écart
ADWindrowScan.MAX_TURN_2 = 100       -- ° : deux branches seules (bavures enlevées) : se suivent sauf demi-tour franc
ADWindrowScan.JOIN_ANGLE = 50        -- ° : trou réuni si les deux bouts se font face sous cet écart
ADWindrowScan.END_EXTEND = 3         -- m : bout libre prolongé dans l'axe au plus de tant
ADWindrowScan.SMOOTH = 1.5           -- m : lissage de la ligne médiane (moyenne sur ± SMOOTH)
ADWindrowScan.LITERS_RADIUS = 3      -- m : case comptée dans l'andain dont un point est à moins de tant
ADWindrowScan.CROSS_STEP = 0.5       -- m : largeur des bandes lues en travers (centerOffset)
ADWindrowScan.CROSS_HALF_LEN = 0.5   -- m : demi-longueur des bandes le long de la direction
ADWindrowScan.HALF_SPAN = 3          -- m : centerOffset sans halfSpan
ADWindrowScan.HALF_LEN = 0.5         -- m : amountAt sans halfLen (ADBalerManager.PROBE_HALF_LENGTH)
ADWindrowScan.HALF_WIDTH = 0.75      -- m : amountAt sans halfWidth (ADBalerManager.PROBE_HALF_WIDTH)
ADWindrowScan.ANY_BLOCK = 16         -- m : côté des blocs d'anyLeft (au moins)
ADWindrowScan.ANY_MAX_BLOCKS = 1500  -- blocs d'anyLeft au plus (grands champs : blocs plus grands)
ADWindrowScan.ANY_MIN_LITERS = 100   -- l : moins dans un bloc = restes, pas un andain (anyLeft)
ADWindrowScan.MAX_LOGGED = 30        -- longueurs écrites au journal au plus

local floor, ceil, sqrt, min, max, huge = math.floor, math.ceil, math.sqrt, math.min, math.max, math.huge

local function log(fmt, ...)
    local ok, s = FarmPilotCall(string.format, fmt, ...)
    print("[FarmPilot Presse] " .. (ok and s or tostring(fmt)))
end
ADWindrowScan.log = log

local function num(v, default, low)
    v = tonumber(v)
    if v == nil or v ~= v or (low ~= nil and v < low) then
        return default
    end
    return v
end

-- ------------------------------------------------------------------------------------------------------------
-- Produits
-- ------------------------------------------------------------------------------------------------------------
-- liste triée des produits (liste ou ensemble { [ft] = true }) ; rien : ceux de ADBalerManager.windrowTypes
local function typeList(fillTypes)
    local list, seen = {}, {}
    local function add(ft)
        ft = tonumber(ft)
        if ft ~= nil and not seen[ft] then
            seen[ft] = true
            list[#list + 1] = ft
        end
    end
    if type(fillTypes) == "table" then
        -- liste { ft, ... } ou ensemble { [ft] = true } (les deux formes, mêlées au besoin)
        for k, v in pairs(fillTypes) do
            if v == true then
                add(k)
            elseif v ~= false then
                add(v)
            end
        end
    elseif fillTypes ~= nil then
        add(fillTypes)
    end
    if #list == 0 and ADBalerManager ~= nil and ADBalerManager.windrowTypes ~= nil then
        local ok, l = FarmPilotCall(ADBalerManager.windrowTypes, nil)
        if ok and type(l) == "table" then
            for _, ft in ipairs(l) do
                add(ft)
            end
        end
    end
    table.sort(list)
    return list
end
ADWindrowScan.typeList = typeList

local function typeName(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeNameByIndex ~= nil then
        local ok, n = FarmPilotCall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, ft)
        if ok and n ~= nil then
            return tostring(n)
        end
    end
    return tostring(ft)
end

local function typeNames(list)
    local names = {}
    for _, ft in ipairs(list) do
        names[#names + 1] = typeName(ft)
    end
    return table.concat(names, ", ")
end

-- ------------------------------------------------------------------------------------------------------------
-- Lecture du tas au sol (DensityMapHeightUtil du jeu : parallélogramme départ, point largeur, point hauteur)
-- ------------------------------------------------------------------------------------------------------------
local function heapReady()
    return DensityMapHeightUtil ~= nil and DensityMapHeightUtil.getFillLevelAtArea ~= nil
end

-- litres d'un produit sur la zone (0 si rien)
local function levelAt(ft, sx, sz, wx, wz, hx, hz)
    local ok, l = FarmPilotCall(DensityMapHeightUtil.getFillLevelAtArea, ft, sx, sz, wx, wz, hx, hz)
    if ok and type(l) == "number" and l > 0 then
        return l
    end
    return 0
end

-- un tas (de n'importe quel produit) sur la zone : true / false ; nil = lecture impossible
local function anyHeapAt(sx, sz, wx, wz, hx, hz)
    if DensityMapHeightUtil.getFillTypeAtArea == nil then
        return nil
    end
    local ok, ft = FarmPilotCall(DensityMapHeightUtil.getFillTypeAtArea, sx, sz, wx, wz, hx, hz)
    if not ok then
        return nil
    end
    return not (ft == nil or ft == 0 or (FillType ~= nil and ft == FillType.UNKNOWN))
end

-- parallélogramme centré sur x, z : hl le long de (dx, dz), hw en travers (comme ADBalerManager.hasWindrow)
local function centeredArea(x, z, dx, dz, hl, hw)
    local px, pz = -dz, dx
    local sx, sz = x - dx * hl - px * hw, z - dz * hl - pz * hw
    return sx, sz, sx + px * 2 * hw, sz + pz * 2 * hw, sx + dx * 2 * hl, sz + dz * 2 * hl
end

local function unit(dx, dz)
    dx, dz = tonumber(dx) or 0, tonumber(dz) or 0
    local l = sqrt(dx * dx + dz * dz)
    if l < 1e-6 then
        return nil
    end
    return dx / l, dz / l
end

-- ------------------------------------------------------------------------------------------------------------
-- Champs : numéros du groupe, contours (polygones du jeu), zone lue
-- ------------------------------------------------------------------------------------------------------------
local function fieldNumber(f)
    if ADAutonomousManager ~= nil and ADAutonomousManager.fieldNumber ~= nil then
        local ok, n = FarmPilotCall(ADAutonomousManager.fieldNumber, f)
        return ok and tonumber(n) or nil
    end
    if f.getId ~= nil then
        local ok, n = FarmPilotCall(f.getId, f)
        if ok and tonumber(n) ~= nil then
            return tonumber(n)
        end
    end
    if f.farmland ~= nil and tonumber(f.farmland.id) ~= nil then
        return tonumber(f.farmland.id)
    end
    return tonumber(f.fieldId)
end

local function allFields()
    if g_fieldManager == nil then
        return {}
    end
    local list = nil
    if g_fieldManager.getFields ~= nil then
        local ok, l = FarmPilotCall(g_fieldManager.getFields, g_fieldManager)
        if ok then
            list = l
        end
    end
    if type(list) ~= "table" then
        list = g_fieldManager.fields
    end
    local out = {}
    for _, f in pairs(list or {}) do
        if type(f) == "table" then
            out[#out + 1] = f
        end
    end
    return out
end

-- numéros du groupe (ensemble, liste ou un numéro ; groupe AutoSwitch complété) : ensemble, liste triée
local function fieldSet(fieldNums)
    local set, list = {}, {}
    local function add(n)
        n = tonumber(n)
        if n ~= nil and not set[n] then
            set[n] = true
            list[#list + 1] = n
        end
    end
    -- (15/11) ensemble { [n] = true } (ctx.fieldNums, ADBaleLoaderManager.fieldNumbers) ou liste { n1, n2 } : un
    -- ensemble { [1] = true } a aussi un [1], on regarde donc chaque valeur (true = la clé est le numéro)
    local raw = {}
    if type(fieldNums) == "table" then
        for k, v in pairs(fieldNums) do
            if v == true then
                raw[#raw + 1] = k
            elseif v ~= false then
                raw[#raw + 1] = v
            end
        end
    elseif fieldNums ~= nil then
        raw[1] = fieldNums
    end
    table.sort(raw, function(a, b)
        return (tonumber(a) or 0) < (tonumber(b) or 0)
    end)
    for _, n in ipairs(raw) do
        add(n)
        if ADAutonomousManager ~= nil and ADAutonomousManager.groupOf ~= nil and tonumber(n) ~= nil then
            local ok, g = FarmPilotCall(ADAutonomousManager.groupOf, tonumber(n))
            if ok and g ~= nil and type(g.members) == "table" then
                for _, m in ipairs(g.members) do
                    add(m)
                end
            end
        end
    end
    table.sort(list)
    return set, list
end

-- contour d'un champ en coordonnées monde (polygonPoints du jeu : nœuds), gardé tant que le champ existe
ADWindrowScan.polygons = setmetatable({}, { __mode = "k" })

local function polygonOf(f)
    local cached = ADWindrowScan.polygons[f]
    if cached ~= nil then
        return cached or nil
    end
    local raw = nil
    if f.getPolygonPoints ~= nil then
        local ok, p = FarmPilotCall(f.getPolygonPoints, f)
        if ok then
            raw = p
        end
    end
    if type(raw) ~= "table" then
        raw = f.polygonPoints
    end
    local poly = { xs = {}, zs = {}, n = 0, minX = huge, minZ = huge, maxX = -huge, maxZ = -huge }
    for _, p in ipairs(type(raw) == "table" and raw or {}) do
        local x, z = nil, nil
        if type(p) == "number" and getWorldTranslation ~= nil then
            local ok, px, _, pz = FarmPilotCall(getWorldTranslation, p)
            if ok then
                x, z = tonumber(px), tonumber(pz)
            end
        elseif type(p) == "table" then
            x, z = tonumber(p.x), tonumber(p.z)
        end
        local n = poly.n
        if x ~= nil and z ~= nil and (n == 0 or math.abs(poly.xs[n] - x) > 0.01 or math.abs(poly.zs[n] - z) > 0.01) then
            n = n + 1
            poly.n = n
            poly.xs[n], poly.zs[n] = x, z
            poly.minX, poly.maxX = min(poly.minX, x), max(poly.maxX, x)
            poly.minZ, poly.maxZ = min(poly.minZ, z), max(poly.maxZ, z)
        end
    end
    if poly.n >= 2 and math.abs(poly.xs[1] - poly.xs[poly.n]) <= 0.01 and math.abs(poly.zs[1] - poly.zs[poly.n]) <= 0.01 then
        poly.n = poly.n - 1
    end
    if poly.n < 3 then
        poly = nil
    end
    ADWindrowScan.polygons[f] = poly or false
    return poly
end

local function inPoly(p, x, z)
    if x < p.minX or x > p.maxX or z < p.minZ or z > p.maxZ then
        return false
    end
    local xs, zs, n = p.xs, p.zs, p.n
    local inside = false
    local j = n
    for i = 1, n do
        local zi, zj = zs[i], zs[j]
        if (zi > z) ~= (zj > z) and x < (xs[j] - xs[i]) * (z - zi) / (zj - zi) + xs[i] then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- distance au contour
local function distPoly(p, x, z)
    local xs, zs, n = p.xs, p.zs, p.n
    local best = huge
    local j = n
    for i = 1, n do
        local ax, az = xs[j], zs[j]
        local ex, ez = xs[i] - ax, zs[i] - az
        local l2 = ex * ex + ez * ez
        local t = 0
        if l2 > 0 then
            t = max(0, min(1, ((x - ax) * ex + (z - az) * ez) / l2))
        end
        local dx, dz = ax + ex * t - x, az + ez * t - z
        local d2 = dx * dx + dz * dz
        if d2 < best then
            best = d2
        end
        j = i
    end
    return sqrt(best)
end

-- abscisses où le contour coupe la ligne z
local function crossings(p, z, out)
    local xs, zs, n = p.xs, p.zs, p.n
    local j = n
    for i = 1, n do
        local zi, zj = zs[i], zs[j]
        if (zi > z) ~= (zj > z) then
            out[#out + 1] = xs[i] + (z - zi) * (xs[j] - xs[i]) / (zj - zi)
        end
        j = i
    end
end

-- zone lue : { groups = contours du groupe, others = contours voisins, nums, edge, minX.. (élargie de edge) }
function ADWindrowScan.zone(fieldNums, edge)
    edge = num(edge, ADWindrowScan.EDGE, 0)
    local set, list = fieldSet(fieldNums)
    local zone = { set = set, nums = list, edge = edge, groups = {}, others = {}, missing = {},
        minX = huge, minZ = huge, maxX = -huge, maxZ = -huge }
    local fields = allFields()
    local found = {}
    for _, f in ipairs(fields) do
        local n = fieldNumber(f)
        if n ~= nil and set[n] then
            local p = polygonOf(f)
            if p ~= nil then
                zone.groups[#zone.groups + 1] = p
                found[n] = true
                zone.minX, zone.maxX = min(zone.minX, p.minX), max(zone.maxX, p.maxX)
                zone.minZ, zone.maxZ = min(zone.minZ, p.minZ), max(zone.maxZ, p.maxZ)
            end
        end
    end
    for _, n in ipairs(list) do
        if not found[n] then
            zone.missing[#zone.missing + 1] = n
        end
    end
    if #zone.groups == 0 then
        return zone
    end
    zone.minX, zone.minZ, zone.maxX, zone.maxZ = zone.minX - edge, zone.minZ - edge, zone.maxX + edge, zone.maxZ + edge
    for _, f in ipairs(fields) do
        local n = fieldNumber(f)
        if n == nil or not set[n] then
            local p = polygonOf(f)
            if p ~= nil and p.maxX >= zone.minX - edge and p.minX <= zone.maxX + edge and p.maxZ >= zone.minZ - edge
                and p.minZ <= zone.maxZ + edge then
                zone.others[#zone.others + 1] = p
            end
        end
    end
    return zone
end

-- le point compte pour le groupe : sur un champ du groupe ; ou hors de tout champ, à moins de edge m d'un champ du
-- groupe et plus près de lui que de tout autre champ
local function inZone(zone, x, z)
    for _, p in ipairs(zone.groups) do
        if inPoly(p, x, z) then
            return true
        end
    end
    for _, p in ipairs(zone.others) do
        if inPoly(p, x, z) then
            return false
        end
    end
    local e = zone.edge
    local dg = huge
    for _, p in ipairs(zone.groups) do
        if x >= p.minX - e and x <= p.maxX + e and z >= p.minZ - e and z <= p.maxZ + e then
            dg = min(dg, distPoly(p, x, z))
        end
    end
    if dg > e then
        return false
    end
    for _, p in ipairs(zone.others) do
        if x >= p.minX - dg and x <= p.maxX + dg and z >= p.minZ - dg and z <= p.maxZ + dg and distPoly(p, x, z) < dg then
            return false
        end
    end
    return true
end
ADWindrowScan.inZone = inZone

-- rectangle entièrement sur un même champ du groupe (ses 4 coins)
local function rectInside(zone, x0, z0, x1, z1)
    for _, p in ipairs(zone.groups) do
        if inPoly(p, x0, z0) and inPoly(p, x1, z0) and inPoly(p, x0, z1) and inPoly(p, x1, z1) then
            return true
        end
    end
    return false
end

local function fieldsText(list)
    local t = {}
    for _, n in ipairs(list or {}) do
        t[#t + 1] = tostring(n)
    end
    return table.concat(t, " + ")
end

-- ------------------------------------------------------------------------------------------------------------
-- Géométrie des lignes (points { x, z } en tableau : p[1], p[2])
-- ------------------------------------------------------------------------------------------------------------
local function dist(a, b)
    local dx, dz = b[1] - a[1], b[2] - a[2]
    return sqrt(dx * dx + dz * dz)
end

-- lissage : moyenne des points à moins de win m le long de la ligne (bouts d'une ligne ouverte gardés)
local function smoothLine(pts, closed, win)
    local n = #pts
    if n < 3 or win <= 0 then
        return pts
    end
    local seg = {}
    for i = 1, n do
        local j = i + 1
        if j > n then
            j = closed and 1 or nil
        end
        seg[i] = j ~= nil and dist(pts[i], pts[j]) or 0
    end
    local out = {}
    for i = 1, n do
        if not closed and (i == 1 or i == n) then
            out[i] = { pts[i][1], pts[i][2] }
        else
            local sx, sz, c = pts[i][1], pts[i][2], 1
            local d, j = 0, i
            for _ = 1, n - 1 do
                local nj = j + 1
                if nj > n then
                    if not closed then
                        break
                    end
                    nj = 1
                end
                d = d + seg[j]
                if d > win then
                    break
                end
                j = nj
                sx, sz, c = sx + pts[j][1], sz + pts[j][2], c + 1
            end
            d, j = 0, i
            for _ = 1, n - 1 do
                local pj = j - 1
                if pj < 1 then
                    if not closed then
                        break
                    end
                    pj = n
                end
                d = d + seg[pj]
                if d > win then
                    break
                end
                j = pj
                sx, sz, c = sx + pts[j][1], sz + pts[j][2], c + 1
            end
            out[i] = { sx / c, sz / c }
        end
    end
    return out
end

-- points tous les ~spacing m ; ligne fermée : sans le point de fermeture
local function resample(pts, closed, spacing)
    local P = pts
    if closed then
        P = {}
        for i, p in ipairs(pts) do
            P[i] = p
        end
        P[#P + 1] = pts[1]
    end
    local cum = { 0 }
    for i = 2, #P do
        cum[i] = cum[i - 1] + dist(P[i - 1], P[i])
    end
    local L = cum[#P]
    if #P < 2 or L <= 0 then
        return { { x = P[1][1], z = P[1][2] } }
    end
    local m = max(closed and 3 or 1, floor(L / spacing + 0.5))
    local out = {}
    local seg = 1
    for k = 0, closed and m - 1 or m do
        local t = L * k / m
        while seg < #P - 1 and cum[seg + 1] < t do
            seg = seg + 1
        end
        local a, b = P[seg], P[seg + 1]
        local sl = cum[seg + 1] - cum[seg]
        local u = sl > 0 and min(1, max(0, (t - cum[seg]) / sl)) or 0
        out[#out + 1] = { x = a[1] + (b[1] - a[1]) * u, z = a[2] + (b[2] - a[2]) * u }
    end
    return out
end

-- ligne fermée : départ au virage le plus serré (coin du champ), point de départ répété à la fin
local function rotateClosed(out)
    local m = #out
    local best, bi = -2, 1
    for i = 1, m do
        local a, b, c = out[(i - 3) % m + 1], out[i], out[(i + 1) % m + 1]
        local ux, uz = unit(b.x - a.x, b.z - a.z)
        local vx, vz = unit(c.x - b.x, c.z - b.z)
        if ux ~= nil and vx ~= nil then
            local turn = 1 - (ux * vx + uz * vz)
            if turn > best + 1e-9 then
                best, bi = turn, i
            end
        end
    end
    local r = {}
    for k = 0, m - 1 do
        r[#r + 1] = out[(bi - 1 + k) % m + 1]
    end
    r[#r + 1] = { x = r[1].x, z = r[1].z }
    return r
end

local function lineLength(points)
    local L = 0
    for i = 2, #points do
        local dx, dz = points[i].x - points[i - 1].x, points[i].z - points[i - 1].z
        L = L + sqrt(dx * dx + dz * dz)
    end
    return L
end

local function acosDeg(c)
    return math.deg(math.acos(max(-1, min(1, c))))
end

-- ============================================================================================================
-- Le scan (par morceaux)
-- ============================================================================================================
local Scan = {}
Scan.__index = Scan
ADWindrowScan.Scan = Scan

-- fieldNums : numéros des champs du groupe, ensemble { [n] = true } ou liste { n1, n2 } ; fillTypes : produits
-- (ADBalerManager.windrowTypes, liste ou ensemble) ;
-- opts : { step = 1, minLength = 5, gap = 3, edge = 10 } (m)
function ADWindrowScan.newScan(fieldNums, fillTypes, opts)
    opts = type(opts) == "table" and opts or {}
    local self = setmetatable({}, Scan)
    self.step = num(opts.step, ADWindrowScan.STEP, 0.1)
    self.minLength = num(opts.minLength, ADWindrowScan.MIN_LENGTH, 0)
    self.gap = num(opts.gap, ADWindrowScan.GAP, 0)
    self.edge = num(opts.edge, ADWindrowScan.EDGE, 0)
    self.spacing = num(opts.pointSpacing, ADWindrowScan.POINT_SPACING, 0.5)
    self.block = max(1, floor(num(opts.block, ADWindrowScan.BLOCK, 1)))
    self.fieldNumsIn = fieldNums
    self.fieldNums = select(2, fieldSet(fieldNums))
    self.fillTypes = typeList(fillTypes)
    self.windrows = {}
    self.done = false
    self.failed = nil
    self.frames, self.reads, self.used, self.budget = 0, 0, 0, ADWindrowScan.BUDGET
    self.cells, self.dropped, self.joined, self.progress = 0, 0, 0, 0
    if coroutine ~= nil and coroutine.create ~= nil then
        self.co = coroutine.create(function()
            self:run()
        end)
    end
    return self
end

-- une image : lit / calcule au plus budget lectures ; true quand c'est fini (scan.windrows rempli)
function Scan:update(budget)
    if self.done then
        return true
    end
    self.budget = max(1, num(budget, ADWindrowScan.BUDGET, 1))
    self.used = 0
    self.frames = self.frames + 1
    if self.co ~= nil then
        self.async = true
        local ok, err = coroutine.resume(self.co)
        if not ok then
            -- repli : sans morceaux si la reprise par morceaux est refusée (le scan repart de zéro)
            if not self.retried and tostring(err):find("yield", 1, true) then
                self.retried = true
                self.co = nil
                log("andains : lecture par morceaux impossible (%s), scan d'un coup", tostring(err))
                return false
            end
            self:fail(err)
        elseif coroutine.status(self.co) == "dead" then
            self.done = true
        end
    else
        self.async = false
        local ok, err = FarmPilotCall(self.run, self)
        if not ok then
            self:fail(err)
        end
        self.done = true
    end
    return self.done
end

function Scan:isDone()
    return self.done
end

function Scan:fail(err)
    self.failed = tostring(err)
    self.windrows = {}
    self.done = true
    log("andains : erreur pendant le scan (champs %s) : %s", fieldsText(self.fieldNums), self.failed)
end

-- n lectures du jeu : attend l'image suivante si le budget de cette image est pris
function Scan:need(n)
    if self.async and self.used > 0 and self.used + n > self.budget then
        coroutine.yield()
    end
    self.used = self.used + n
    self.reads = self.reads + n
end

-- n cases traitées par le calcul
function Scan:work(n)
    self.used = self.used + n * ADWindrowScan.WORK_COST
    if self.async and self.used >= self.budget then
        coroutine.yield()
    end
end

function Scan:run()
    self.windrows = {}
    self.reads, self.cells, self.dropped, self.joined = 0, 0, 0, 0
    if not heapReady() then
        log("andains : lecture du tas au sol indisponible (DensityMapHeightUtil), aucun andain")
        return
    end
    if #self.fillTypes == 0 then
        log("andains : aucun produit d'andain pour cette presse, aucun andain")
        return
    end
    self.zone = ADWindrowScan.zone(self.fieldNumsIn, self.edge)
    self.fieldNums = self.zone.nums
    if #self.zone.missing > 0 then
        log("andains : contour introuvable pour le(s) champ(s) %s", fieldsText(self.zone.missing))
    end
    if #self.zone.groups == 0 then
        log("andains : aucun contour de champ (champs %s), aucun andain", fieldsText(self.fieldNums))
        return
    end
    self:prepareGrid()
    log("andains : scan des champs %s (%s) : zone %.0f x %.0f m, %d blocs de %.0f m, grille %.1f m", fieldsText(self.fieldNums),
        typeNames(self.fillTypes), self.zone.maxX - self.zone.minX, self.zone.maxZ - self.zone.minZ, self.blockTotal,
        self.block * self.step, self.step)
    self:readBlocks()
    self:extract()
    self.progress = 1
    self:report()
end

-- ------------------------------------------------------------------------------------------------------------
-- Grille et blocs utiles
-- ------------------------------------------------------------------------------------------------------------
-- case (i, j) -> clé (j + 1) * W + i + 1 : une colonne et une rangée vides tout autour (voisins sans test de bord)
function Scan:prepareGrid()
    local zone, s, B = self.zone, self.step, self.block
    self.ox = floor(zone.minX / s) * s
    self.oz = floor(zone.minZ / s) * s
    self.nx = max(1, ceil((zone.maxX - self.ox) / s))
    self.nz = max(1, ceil((zone.maxZ - self.oz) / s))
    self.W = self.nx + 2
    self.nbx, self.nbz = ceil(self.nx / B), ceil(self.nz / B)
    self.fg, self.lit, self.ftOf, self.keys = {}, {}, {}, {}
    self.rows, self.blockTotal = {}, 0
    self.zoneCost = 2
    for _, p in ipairs(zone.groups) do
        self.zoneCost = self.zoneCost + p.n / 8
    end
    for _, p in ipairs(zone.others) do
        self.zoneCost = self.zoneCost + p.n / 8
    end
    local bs, e = B * s, self.edge
    for bj = 0, self.nbz - 1 do
        local z0 = self.oz + bj * bs
        local z1 = z0 + bs
        local on = {}
        local zl = z0 - e
        while true do
            for _, p in ipairs(zone.groups) do
                if zl >= p.minZ and zl <= p.maxZ then
                    local xs = {}
                    crossings(p, zl, xs)
                    table.sort(xs)
                    for k = 1, #xs - 1, 2 do
                        local b0 = max(0, floor((xs[k] - e - self.ox) / bs))
                        local b1 = min(self.nbx - 1, floor((xs[k + 1] + e - self.ox) / bs))
                        for bi = b0, b1 do
                            on[bi] = true
                        end
                    end
                    self:work(p.n * 0.5)
                end
            end
            if zl >= z1 + e then
                break
            end
            zl = min(zl + 2, z1 + e)
        end
        local ranges = {}
        local bi = 0
        while bi < self.nbx do
            if on[bi] then
                local b0 = bi
                while bi + 1 < self.nbx and on[bi + 1] do
                    bi = bi + 1
                end
                ranges[#ranges + 1] = { b0, bi }
                self.blockTotal = self.blockTotal + bi - b0 + 1
            end
            bi = bi + 1
        end
        self.rows[bj] = ranges
    end
end

-- produits présents sur le bloc (nil = aucun)
function Scan:presentTypes(x0, z0, x1, z1)
    if DensityMapHeightUtil.getFillTypeAtArea ~= nil then
        self:need(1)
        if anyHeapAt(x0, z0, x1, z0, x0, z1) == false then
            return nil
        end
    end
    local present = nil
    for _, ft in ipairs(self.fillTypes) do
        self:need(1)
        if levelAt(ft, x0, z0, x1, z0, x0, z1) > 0 then
            present = present or {}
            present[#present + 1] = ft
        end
    end
    return present
end

function Scan:readBlocks()
    local s, B = self.step, self.block
    local done = 0
    for bj = 0, self.nbz - 1 do
        for _, r in ipairs(self.rows[bj]) do
            for bi = r[1], r[2] do
                local i0, j0 = bi * B, bj * B
                local i1, j1 = min(self.nx, i0 + B) - 1, min(self.nz, j0 + B) - 1
                local x0, z0 = self.ox + i0 * s, self.oz + j0 * s
                local x1, z1 = self.ox + (i1 + 1) * s, self.oz + (j1 + 1) * s
                local present = self:presentTypes(x0, z0, x1, z1)
                if present ~= nil then
                    self:readCells(i0, j0, i1, j1, present, rectInside(self.zone, x0, z0, x1, z1))
                end
                done = done + 1
                self.progress = 0.8 * done / max(1, self.blockTotal)
            end
        end
    end
end

function Scan:readCells(i0, j0, i1, j1, present, inside)
    local s, W, d = self.step, self.W, ADWindrowScan.CELL_INSET * self.step
    for j = j0, j1 do
        for i = i0, i1 do
            local cx, cz = self.ox + i * s, self.oz + j * s
            local total, best, bestFt = 0, 0, nil
            for _, ft in ipairs(present) do
                self:need(1)
                local l = levelAt(ft, cx + d, cz + d, cx + s - d, cz + d, cx + d, cz + s - d)
                total = total + l
                if l > best then
                    best, bestFt = l, ft
                end
            end
            if total > 0 then
                local keep = inside
                if not keep then
                    self:work(self.zoneCost)
                    keep = inZone(self.zone, cx + s / 2, cz + s / 2)
                end
                if keep then
                    local k = (j + 1) * W + i + 1
                    self.fg[k], self.lit[k], self.ftOf[k] = true, total, bestFt
                    self.keys[#self.keys + 1] = k
                end
            end
        end
    end
end

-- centre de la case d'une clé
function Scan:center(k)
    local W = self.W
    local j = floor(k / W) - 1
    local i = k - (j + 1) * W - 1
    return self.ox + (i + 0.5) * self.step, self.oz + (j + 0.5) * self.step
end

-- andain sous le point (grille lue)
function Scan:fgAt(x, z)
    local i, j = floor((x - self.ox) / self.step), floor((z - self.oz) / self.step)
    if i < 0 or j < 0 or i >= self.nx or j >= self.nz then
        return false
    end
    return self.fg[(j + 1) * self.W + i + 1] == true
end

-- ------------------------------------------------------------------------------------------------------------
-- Extraction : squelette, graphe, andains
-- ------------------------------------------------------------------------------------------------------------
function Scan:extract()
    local W, s = self.W, self.step
    local fg = self.fg
    local OFF = { -W, -W + 1, 1, W + 1, W, W - 1, -1, -W - 1 }   -- 8 voisins, dans l'ordre du tour
    local OFF4 = { -W, 1, W, -1 }
    local keys = self.keys
    table.sort(keys)
    self.cells = #keys

    -- 1) trous d'une case (le long ou en travers)
    local added, addList = {}, {}
    for idx, k in ipairs(keys) do
        for _, d in ipairs(OFF4) do
            local c = k + d
            if not fg[c] and not added[c] and ((fg[c - 1] and fg[c + 1]) or (fg[c - W] and fg[c + W])) then
                added[c] = true
                addList[#addList + 1] = c
            end
        end
        if idx % 128 == 0 then
            self:work(128)
        end
    end
    for _, c in ipairs(addList) do
        fg[c] = true
        keys[#keys + 1] = c
    end
    table.sort(keys)

    -- 2) amincissement : on enlève, côté par côté, les cases de bord dont le retrait ne coupe rien (nombre de
    --    connexité de Yokoi = 1), sauf les bouts (un seul voisin)
    local sk, list = {}, {}
    for i, k in ipairs(keys) do
        sk[k] = true
        list[i] = k
    end
    local function removable(k)
        local n1 = sk[k - W] and 1 or 0
        local n2 = sk[k - W + 1] and 1 or 0
        local n3 = sk[k + 1] and 1 or 0
        local n4 = sk[k + W + 1] and 1 or 0
        local n5 = sk[k + W] and 1 or 0
        local n6 = sk[k + W - 1] and 1 or 0
        local n7 = sk[k - 1] and 1 or 0
        local n8 = sk[k - W - 1] and 1 or 0
        if n1 + n2 + n3 + n4 + n5 + n6 + n7 + n8 < 2 then
            return false
        end
        local c1, c2, c3, c4, c5, c6, c7, c8 = 1 - n1, 1 - n2, 1 - n3, 1 - n4, 1 - n5, 1 - n6, 1 - n7, 1 - n8
        return (c1 - c1 * c2 * c3) + (c3 - c3 * c4 * c5) + (c5 - c5 * c6 * c7) + (c7 - c7 * c8 * c1) == 1
    end
    local changed = true
    while changed do
        changed = false
        for _, d in ipairs(OFF4) do
            local cand = {}
            for idx, k in ipairs(list) do
                if sk[k] and not sk[k + d] then
                    cand[#cand + 1] = k
                end
                if idx % 256 == 0 then
                    self:work(64)
                end
            end
            for idx, k in ipairs(cand) do
                if removable(k) then
                    sk[k] = nil
                    changed = true
                end
                if idx % 128 == 0 then
                    self:work(128)
                end
            end
        end
        local nl = {}
        for _, k in ipairs(list) do
            if sk[k] then
                nl[#nl + 1] = k
            end
        end
        list = nl
    end

    -- 3) graphe : nœuds = bouts (1 voisin) et croisements (3 voisins ou plus, cases voisines réunies) ; arêtes =
    --    chaînes de cases entre deux nœuds ; boucles sans nœud à part
    local deg = {}
    for idx, k in ipairs(list) do
        local c = 0
        for _, d in ipairs(OFF) do
            if sk[k + d] then
                c = c + 1
            end
        end
        deg[k] = c
        if idx % 128 == 0 then
            self:work(128)
        end
    end
    local nodes, nodeOf = {}, {}
    for _, k in ipairs(list) do
        if nodeOf[k] == nil and (deg[k] >= 3 or deg[k] == 1) then
            local node = { id = #nodes + 1, px = { k }, deg = 0 }
            nodes[#nodes + 1] = node
            nodeOf[k] = node
            if deg[k] >= 3 then
                local stack = { k }
                while #stack > 0 do
                    local p = table.remove(stack)
                    for _, d in ipairs(OFF) do
                        local q = p + d
                        if sk[q] and deg[q] >= 3 and nodeOf[q] == nil then
                            nodeOf[q] = node
                            node.px[#node.px + 1] = q
                            stack[#stack + 1] = q
                        end
                    end
                end
            end
            local sx, sz = 0, 0
            for _, p in ipairs(node.px) do
                local x, z = self:center(p)
                sx, sz = sx + x, sz + z
            end
            node.x, node.z = sx / #node.px, sz / #node.px
        end
    end
    local edges, visited, direct = {}, {}, {}
    local function addEdge(a, b, px, ring)
        local e = { id = #edges + 1, a = a, b = b, px = px, ring = ring, alive = true }
        edges[#edges + 1] = e
        return e
    end
    for _, node in ipairs(nodes) do
        for _, p in ipairs(node.px) do
            for _, d in ipairs(OFF) do
                local q = p + d
                if sk[q] then
                    local other = nodeOf[q]
                    if other ~= nil then
                        if other ~= node then
                            local key = min(node.id, other.id) * 1000000 + max(node.id, other.id)
                            if not direct[key] then
                                direct[key] = true
                                addEdge(node, other, {})
                            end
                        end
                    elseif not visited[q] then
                        local chain = { q }
                        visited[q] = true
                        local prev, cur, stop = p, q, nil
                        while true do
                            local nxt = nil
                            for _, d2 in ipairs(OFF) do
                                local r = cur + d2
                                if sk[r] and r ~= prev then
                                    nxt = r
                                    break
                                end
                            end
                            if nxt == nil then
                                break
                            end
                            if nodeOf[nxt] ~= nil then
                                stop = nodeOf[nxt]
                                break
                            end
                            if visited[nxt] then
                                break
                            end
                            visited[nxt] = true
                            chain[#chain + 1] = nxt
                            prev, cur = cur, nxt
                        end
                        if stop ~= nil then
                            addEdge(node, stop, chain)
                        end
                        self:work(#chain)
                    end
                end
            end
        end
    end
    for _, k in ipairs(list) do
        if deg[k] == 2 and nodeOf[k] == nil and not visited[k] then
            visited[k] = true
            local chain = { k }
            local first = nil
            for _, d in ipairs(OFF) do
                if sk[k + d] then
                    first = k + d
                    break
                end
            end
            local prev, cur = k, first
            while cur ~= nil and cur ~= k and not visited[cur] and nodeOf[cur] == nil do
                visited[cur] = true
                chain[#chain + 1] = cur
                local nxt = nil
                for _, d in ipairs(OFF) do
                    local r = cur + d
                    if sk[r] and r ~= prev then
                        nxt = r
                        break
                    end
                end
                prev, cur = cur, nxt
            end
            if cur == k and #chain >= 3 then
                addEdge(nil, nil, chain, true)
            end
            self:work(#chain)
        end
    end
    for _, e in ipairs(edges) do
        local pts, inner = {}, {}
        if e.a ~= nil then
            pts[1] = { e.a.x, e.a.z }
        end
        for _, k in ipairs(e.px) do
            local x, z = self:center(k)
            pts[#pts + 1] = { x, z }
            inner[#inner + 1] = { x, z }
        end
        if e.b ~= nil then
            pts[#pts + 1] = { e.b.x, e.b.z }
        end
        e.pts, e.inner = pts, inner
        local L = 0
        for i = 2, #pts do
            L = L + dist(pts[i - 1], pts[i])
        end
        if e.ring and #pts > 1 then
            L = L + dist(pts[#pts], pts[1])
        end
        e.len = L
        if not e.ring then
            e.a.deg = e.a.deg + 1
            e.b.deg = e.b.deg + 1
        end
    end
    self:work(#edges * 4)

    -- 4) nettoyage : bavures (branche courte vers un bout libre depuis un croisement), petites boucles, doublons
    local function kill(e)
        e.alive = false
        e.a.deg = e.a.deg - 1
        e.b.deg = e.b.deg - 1
    end
    local spur, loopMin = ADWindrowScan.SPUR, ADWindrowScan.LOOP_MIN
    for _ = 1, 3 do
        local removed = false
        local cand = {}
        for _, e in ipairs(edges) do
            if e.alive and not e.ring then
                if e.a == e.b then
                    if e.len < loopMin then
                        kill(e)
                        removed = true
                    end
                elseif e.len < spur and (e.a.deg == 1 or e.b.deg == 1) then
                    cand[#cand + 1] = e
                end
            end
        end
        table.sort(cand, function(a, b)
            if a.len ~= b.len then
                return a.len < b.len
            end
            return a.id < b.id
        end)
        for _, e in ipairs(cand) do
            if e.alive and ((e.a.deg == 1 and e.b.deg >= 3) or (e.b.deg == 1 and e.a.deg >= 3)) then
                kill(e)
                removed = true
            end
        end
        local seen = {}
        for _, e in ipairs(edges) do
            if e.alive and not e.ring and e.a ~= e.b then
                local key = min(e.a.id, e.b.id) * 1000000 + max(e.a.id, e.b.id)
                local o = seen[key]
                if o ~= nil and max(o.len, e.len) < loopMin then
                    if e.len > o.len then
                        kill(e)
                    else
                        kill(o)
                        seen[key] = e
                    end
                    removed = true
                elseif o == nil then
                    seen[key] = e
                end
            end
        end
        self:work(#edges * 2)
        if not removed then
            break
        end
    end

    -- 5) aux croisements : les deux branches qui se suivent le mieux vont ensemble
    local dirDist = ADWindrowScan.DIR_DIST
    local function portDir(port)
        local pts = port.edge.pts
        local n = #pts
        local i0, i1, st = 1, n, 1
        if port.side == 2 then
            i0, i1, st = n, 1, -1
        end
        local x0, z0 = pts[i0][1], pts[i0][2]
        local fx, fz = pts[i1][1], pts[i1][2]
        for i = i0 + st, i1, st do
            local dx, dz = pts[i][1] - x0, pts[i][2] - z0
            if dx * dx + dz * dz >= dirDist * dirDist then
                fx, fz = pts[i][1], pts[i][2]
                break
            end
        end
        local ux, uz = unit(fx - x0, fz - z0)
        return ux or 0, uz or 0
    end
    for _, node in ipairs(nodes) do
        node.ports = {}
    end
    for _, e in ipairs(edges) do
        if e.alive and not e.ring then
            e.port = { { edge = e, side = 1, node = e.a }, { edge = e, side = 2, node = e.b } }
            e.a.ports[#e.a.ports + 1] = e.port[1]
            e.b.ports[#e.b.ports + 1] = e.port[2]
        end
    end
    for _, node in ipairs(nodes) do
        local P = node.ports
        if #P >= 2 then
            local limit = #P == 2 and ADWindrowScan.MAX_TURN_2 or ADWindrowScan.MAX_TURN
            for _, p in ipairs(P) do
                p.dx, p.dz = portDir(p)
            end
            local cand = {}
            for i = 1, #P - 1 do
                for j = i + 1, #P do
                    local dev = acosDeg(-(P[i].dx * P[j].dx + P[i].dz * P[j].dz))
                    if dev <= limit then
                        cand[#cand + 1] = { i, j, dev }
                    end
                end
            end
            table.sort(cand, function(a, b)
                if a[3] ~= b[3] then
                    return a[3] < b[3]
                end
                if a[1] ~= b[1] then
                    return a[1] < b[1]
                end
                return a[2] < b[2]
            end)
            for _, c in ipairs(cand) do
                local p, q = P[c[1]], P[c[2]]
                if p.mate == nil and q.mate == nil then
                    p.mate, q.mate = q, p
                end
            end
            self:work(#P * #P)
        end
    end

    -- 6) traits : arêtes enchaînées par les paires ; bout libre = nœud qui n'a plus que cette branche
    -- (15/11) le milieu d'un croisement (centre des cases réunies) est tiré vers la branche qui s'y arrête : un andain
    -- qui traverse le croisement va de case en case sans lui ; une branche qui s'y arrête finit sur l'axe de
    -- l'andain qui traverse (là où son axe le coupe)
    local strokes, used = {}, {}
    local function push(pts, p)
        local last = pts[#pts]
        if last == nil or math.abs(last[1] - p[1]) > 1e-6 or math.abs(last[2] - p[2]) > 1e-6 then
            pts[#pts + 1] = { p[1], p[2] }
        end
    end
    local function append(pts, list, forward)
        local i0, i1, st = 1, #list, 1
        if not forward then
            i0, i1, st = #list, 1, -1
        end
        for i = i0, i1, st do
            push(pts, list[i])
        end
    end
    -- point de la branche à d m au moins du nœud (le dernier sinon)
    local function pointFrom(port, d)
        local pts = port.edge.pts
        local n = #pts
        local i0, i1, st = 1, n, 1
        if port.side == 2 then
            i0, i1, st = n, 1, -1
        end
        local o = pts[i0]
        for i = i0 + st, i1, st do
            if dist(o, pts[i]) >= d then
                return pts[i]
            end
        end
        return pts[i1]
    end
    -- bout d'un trait au nœud du port (port sans paire)
    local function endPoint(port)
        local node = port.node
        if node.deg <= 1 then
            return { node.x, node.z }
        end
        local a = pointFrom(port, 0.5)
        local b = pointFrom(port, 3)
        local dx, dz = unit(a[1] - b[1], a[2] - b[2])
        if dx == nil then
            return { node.x, node.z }
        end
        for _, q in ipairs(node.ports) do
            if q ~= port and q.mate ~= nil and q.mate ~= port then
                local p1, p2 = pointFrom(q, 2), pointFrom(q.mate, 2)
                local ex, ez = p2[1] - p1[1], p2[2] - p1[2]
                local den = dx * ez - dz * ex
                local el = sqrt(ex * ex + ez * ez)
                if el > 0 and math.abs(den) > 0.3 * el then
                    local t = ((p1[1] - a[1]) * ez - (p1[2] - a[2]) * ex) / den
                    if t >= -1 and t <= 4 then
                        return { a[1] + dx * t, a[2] + dz * t }
                    end
                end
            end
        end
        local t = max(0, min(3, (node.x - a[1]) * dx + (node.z - a[2]) * dz))
        return { a[1] + dx * t, a[2] + dz * t }
    end
    local function walk(e, side)
        local pts = {}
        local startNode = side == 1 and e.a or e.b
        local st = { pts = pts, freeStart = startNode.deg == 1, freeEnd = false, closed = false }
        local first = e
        if e.port[side].mate == nil then
            push(pts, endPoint(e.port[side]))
        end
        while true do
            used[e] = true
            append(pts, e.inner, side == 1)
            local out = e.port[3 - side]
            local m = out.mate
            if m == nil then
                st.freeEnd = out.node.deg == 1
                push(pts, endPoint(out))
                break
            end
            if used[m.edge] then
                if m.edge == first then
                    st.closed = true
                    st.freeStart = false
                end
                break
            end
            e, side = m.edge, m.side
        end
        return st
    end
    for _, e in ipairs(edges) do
        if e.alive and not e.ring then
            for side = 1, 2 do
                if not used[e] and e.port[side].mate == nil then
                    strokes[#strokes + 1] = walk(e, side)
                end
            end
        end
    end
    for _, e in ipairs(edges) do
        if e.alive and not used[e] then
            if e.ring then
                local pts = {}
                append(pts, e.inner, true)
                strokes[#strokes + 1] = { pts = pts, closed = true, freeStart = false, freeEnd = false }
                used[e] = true
            else
                strokes[#strokes + 1] = walk(e, 1)
            end
        end
    end
    self:work(#edges * 4)

    -- 7) bouts libres prolongés dans l'axe tant qu'il y a de l'andain (l'amincissement raccourcit les bouts)
    local function inner(pts, atStart, d)
        local n = #pts
        local i0, i1, st = 1, n, 1
        if not atStart then
            i0, i1, st = n, 1, -1
        end
        local e = pts[i0]
        for i = i0 + st, i1, st do
            if dist(e, pts[i]) >= d then
                return pts[i]
            end
        end
        return pts[i1]
    end
    local function tangent(pts, atStart)
        local e = atStart and pts[1] or pts[#pts]
        local q = inner(pts, atStart, 3)
        return unit(e[1] - q[1], e[2] - q[2])
    end
    local ext, half = ADWindrowScan.END_EXTEND, 0.5 * s
    for _, st in ipairs(strokes) do
        if not st.closed and #st.pts >= 2 then
            for _, atStart in ipairs({ true, false }) do
                if (atStart and st.freeStart) or (not atStart and st.freeEnd) then
                    local tx, tz = tangent(st.pts, atStart)
                    if tx ~= nil then
                        local e = atStart and st.pts[1] or st.pts[#st.pts]
                        local best, d = 0, half
                        while d <= ext + 1e-6 do
                            if self:fgAt(e[1] + tx * d, e[2] + tz * d) then
                                best = d
                            else
                                break
                            end
                            d = d + half
                        end
                        if best > 0 then
                            local p = { e[1] + tx * best, e[2] + tz * best }
                            if atStart then
                                table.insert(st.pts, 1, p)
                            else
                                st.pts[#st.pts + 1] = p
                            end
                        end
                    end
                end
            end
        end
    end

    -- 8) trous de moins de gap m : deux bouts libres face à face réunis (le plus court d'abord)
    local ends = {}
    for si, st in ipairs(strokes) do
        st.index = si
        local L = 0
        for i = 2, #st.pts do
            L = L + dist(st.pts[i - 1], st.pts[i])
        end
        st.len = L
        if not st.closed and #st.pts >= 2 then
            for _, atStart in ipairs({ true, false }) do
                if (atStart and st.freeStart) or (not atStart and st.freeEnd) then
                    local tx, tz = tangent(st.pts, atStart)
                    if tx ~= nil then
                        local e = atStart and st.pts[1] or st.pts[#st.pts]
                        local en = { st = st, atStart = atStart, x = e[1], z = e[2], tx = tx, tz = tz, id = #ends + 1 }
                        ends[#ends + 1] = en
                        if atStart then
                            st.endS = en
                        else
                            st.endE = en
                        end
                    end
                end
            end
        end
    end
    local maxD = self.gap + s
    local cosJoin = math.cos(math.rad(ADWindrowScan.JOIN_ANGLE))
    local buckets = {}
    local function bkey(bx, bz)
        return (bx + 100000) * 1000000 + bz + 100000
    end
    for _, en in ipairs(ends) do
        local k = bkey(floor(en.x / max(maxD, 0.5)), floor(en.z / max(maxD, 0.5)))
        buckets[k] = buckets[k] or {}
        table.insert(buckets[k], en)
    end
    local pairsList = {}
    if self.gap > 0 then
        for _, a in ipairs(ends) do
            local bx, bz = floor(a.x / max(maxD, 0.5)), floor(a.z / max(maxD, 0.5))
            for ox = -1, 1 do
                for oz = -1, 1 do
                    for _, b in ipairs(buckets[bkey(bx + ox, bz + oz)] or {}) do
                        if b.id > a.id then
                            local dx, dz = b.x - a.x, b.z - a.z
                            local d = sqrt(dx * dx + dz * dz)
                            local face = -(a.tx * b.tx + a.tz * b.tz)
                            if d <= maxD and face >= cosJoin then
                                local ok = d < 1.5 * s
                                if not ok then
                                    local ux, uz = dx / d, dz / d
                                    ok = (a.tx * ux + a.tz * uz) >= cosJoin and -(b.tx * ux + b.tz * uz) >= cosJoin
                                end
                                if ok then
                                    pairsList[#pairsList + 1] = { a = a, b = b, cost = d + (1 - face) * 5 }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(pairsList, function(p, q)
        if p.cost ~= q.cost then
            return p.cost < q.cost
        end
        if p.a.id ~= q.a.id then
            return p.a.id < q.a.id
        end
        return p.b.id < q.b.id
    end)
    local parent, chainLen = {}, {}
    local function root(i)
        while parent[i] ~= nil and parent[i] ~= i do
            i = parent[i]
        end
        return i
    end
    for _, st in ipairs(strokes) do
        parent[st.index] = st.index
        chainLen[st.index] = st.len
    end
    for _, pr in ipairs(pairsList) do
        local a, b = pr.a, pr.b
        if a.partner == nil and b.partner == nil then
            local ra, rb = root(a.st.index), root(b.st.index)
            if ra ~= rb then
                a.partner, b.partner = b, a
                parent[rb] = ra
                chainLen[ra] = chainLen[ra] + chainLen[rb]
                self.joined = self.joined + 1
            elseif chainLen[ra] >= 4 * max(self.gap, self.minLength) then
                a.partner, b.partner = b, a   -- tour de fourrière coupé une fois : refermé
                self.joined = self.joined + 1
            end
        end
    end
    self:work(#ends * 8)

    -- chaînes de traits
    local chains, done = {}, {}
    local function chainFrom(st0, enterAtStart)
        local pts = {}
        local cur, inStart = st0, enterAtStart
        local closed = false
        while true do
            done[cur] = true
            local sp = cur.pts
            local i0, i1, step = 1, #sp, 1
            if not inStart then
                i0, i1, step = #sp, 1, -1
            end
            for i = i0, i1, step do
                local last = pts[#pts]
                if last == nil or dist(last, sp[i]) > 1e-6 then
                    pts[#pts + 1] = sp[i]
                end
            end
            local exitEnd = inStart and cur.endE or cur.endS
            if exitEnd == nil or exitEnd.partner == nil then
                break
            end
            local nx = exitEnd.partner
            if done[nx.st] then
                closed = nx.st == st0
                break
            end
            cur, inStart = nx.st, nx.atStart
        end
        return { pts = pts, closed = closed }
    end
    for _, st in ipairs(strokes) do
        if not done[st] then
            if st.closed then
                done[st] = true
                chains[#chains + 1] = { pts = st.pts, closed = true }
            elseif st.endS == nil or st.endS.partner == nil then
                chains[#chains + 1] = chainFrom(st, true)
            elseif st.endE == nil or st.endE.partner == nil then
                chains[#chains + 1] = chainFrom(st, false)
            end
        end
    end
    for _, st in ipairs(strokes) do
        if not done[st] then
            chains[#chains + 1] = chainFrom(st, true)
        end
    end

    -- 9) ligne lissée, un point tous les ~spacing m ; morceaux trop courts ignorés
    local windrows = {}
    for _, c in ipairs(chains) do
        local pts = c.pts
        if #pts >= 2 then
            local sm = smoothLine(pts, c.closed, ADWindrowScan.SMOOTH)
            local points = resample(sm, c.closed, self.spacing)
            if c.closed and #points >= 3 then
                points = rotateClosed(points)
            end
            points = self:recenter(points, c.closed)
            local L = lineLength(points)
            if L >= self.minLength and #points >= 2 then
                windrows[#windrows + 1] = { points = points, length = L, closed = c.closed, liters = 0, byType = {} }
            else
                self.dropped = self.dropped + 1
            end
            self:work(#pts * 4)
        else
            self.dropped = self.dropped + 1
        end
    end

    -- 10) litres et produit : chaque case lue va à l'andain le plus proche (à moins de LITERS_RADIUS m)
    local R = ADWindrowScan.LITERS_RADIUS
    local pb = {}
    for wi, w in ipairs(windrows) do
        for _, p in ipairs(w.points) do
            local k = bkey(floor(p.x / R), floor(p.z / R))
            pb[k] = pb[k] or {}
            table.insert(pb[k], { p.x, p.z, wi })
        end
    end
    for idx, k in ipairs(self.keys) do
        local l = self.lit[k]
        if l ~= nil and l > 0 then
            local x, z = self:center(k)
            local bx, bz = floor(x / R), floor(z / R)
            local best, bw = R * R, nil
            for ox = -1, 1 do
                for oz = -1, 1 do
                    for _, q in ipairs(pb[bkey(bx + ox, bz + oz)] or {}) do
                        local dx, dz = q[1] - x, q[2] - z
                        local d2 = dx * dx + dz * dz
                        if d2 <= best then
                            best, bw = d2, q[3]
                        end
                    end
                end
            end
            if bw ~= nil then
                local w = windrows[bw]
                w.liters = w.liters + l
                local ft = self.ftOf[k]
                if ft ~= nil then
                    w.byType[ft] = (w.byType[ft] or 0) + l
                end
            end
        end
        if idx % 64 == 0 then
            self:work(64 * 4)
        end
    end
    for i, w in ipairs(windrows) do
        w.id = i
        local bestL = -1
        for _, ft in ipairs(self.fillTypes) do
            local l = w.byType[ft] or 0
            if l > bestL then
                bestL, w.fillType = l, ft
            end
        end
        w.byType = nil
    end
    self.windrows = windrows
end

-- milieu de l'andain en travers de la ligne (litres des cases lues) : l'amincissement laisse la ligne jusqu'à une
-- demi-case à côté du milieu ; pas de correction là où un autre andain est tout près (croisement, andains serrés)
ADWindrowScan.RECENTER_HALF = 2.5    -- m en travers comptés pour le milieu
ADWindrowScan.RECENTER_CLEAR = 3.5   -- m : une case d'andain entre RECENTER_HALF et tant = autre andain, pas de correction
ADWindrowScan.RECENTER_MAX = 1       -- m : correction au plus

function Scan:recenter(points, closed)
    local n = #points
    local last = closed and n - 1 or n
    if last < 2 then
        return points
    end
    local s, W, lit = self.step, self.W, self.lit
    local half, clear, cap = ADWindrowScan.RECENTER_HALF, ADWindrowScan.RECENTER_CLEAR, ADWindrowScan.RECENTER_MAX
    local out = {}
    for idx = 1, last do
        local p = points[idx]
        local a, b
        if closed then
            a, b = points[(idx - 2) % last + 1], points[idx % last + 1]
        else
            a, b = points[max(1, idx - 1)], points[min(last, idx + 1)]
        end
        local tx, tz = unit(b.x - a.x, b.z - a.z)
        local q = { x = p.x, z = p.z }
        if tx ~= nil then
            local rx, rz = -tz, tx
            local i0, i1 = max(0, floor((p.x - clear - self.ox) / s)), min(self.nx - 1, floor((p.x + clear - self.ox) / s))
            local j0, j1 = max(0, floor((p.z - clear - self.oz) / s)), min(self.nz - 1, floor((p.z + clear - self.oz) / s))
            local sw, so, busy = 0, 0, false
            for j = j0, j1 do
                for i = i0, i1 do
                    local l = lit[(j + 1) * W + i + 1]
                    if l ~= nil and l > 0 then
                        local cx, cz = self.ox + (i + 0.5) * s - p.x, self.oz + (j + 0.5) * s - p.z
                        if math.abs(cx * tx + cz * tz) <= s then
                            local across = cx * rx + cz * rz
                            if math.abs(across) <= half then
                                sw, so = sw + l, so + l * across
                            elseif math.abs(across) <= clear then
                                busy = true
                            end
                        end
                    end
                end
            end
            if not busy and sw > 0 then
                local o = max(-cap, min(cap, so / sw))
                q.x, q.z = p.x + rx * o, p.z + rz * o
            end
            self:work((i1 - i0 + 1) * (j1 - j0 + 1))
        end
        out[idx] = q
    end
    if closed then
        out[n] = { x = out[1].x, z = out[1].z }
    end
    return out
end

function Scan:report()
    local lens, total = {}, 0
    for i, w in ipairs(self.windrows) do
        total = total + w.length
        if i <= ADWindrowScan.MAX_LOGGED then
            lens[#lens + 1] = string.format("%.0f%s", w.length, w.closed and " (tour)" or "")
        end
    end
    if #self.windrows > ADWindrowScan.MAX_LOGGED then
        lens[#lens + 1] = "..."
    end
    log("andains : scan fini en %d images (%d lectures, %d cases d'andain) : %d andain(s), longueurs %s m (total %.0f m) ; %d morceau(x) de moins de %.0f m ignoré(s), %d trou(s) réuni(s)",
        self.frames, self.reads, self.cells, #self.windrows, #lens > 0 and table.concat(lens, ", ") or "-", total,
        self.dropped, self.minLength, self.joined)
end

-- ============================================================================================================
-- Lectures directes (suivi de l'andain, fin du champ)
-- ============================================================================================================
-- écart latéral (m, + = droite de la direction) du milieu de l'andain en travers de la direction au point x, z ;
-- nil = pas d'andain sur ± halfSpan. Deuxième valeur : litres de l'andain retenu sur la bande lue.
function ADWindrowScan.centerOffset(x, z, dirX, dirZ, fillTypes, halfSpan)
    if not heapReady() or tonumber(x) == nil or tonumber(z) == nil then
        return nil
    end
    local dx, dz = unit(dirX, dirZ)
    if dx == nil then
        return nil
    end
    halfSpan = num(halfSpan, ADWindrowScan.HALF_SPAN, 0)
    if halfSpan <= 0 then
        return nil
    end
    local hl = ADWindrowScan.CROSS_HALF_LEN
    local present = {}
    for _, ft in ipairs(typeList(fillTypes)) do
        if levelAt(ft, centeredArea(x, z, dx, dz, hl, halfSpan)) > 0 then
            present[#present + 1] = ft
        end
    end
    if #present == 0 then
        return nil
    end
    local rx, rz = -dz, dx
    local n = max(1, ceil(2 * halfSpan / ADWindrowScan.CROSS_STEP - 1e-6))
    local w = 2 * halfSpan / n
    local prof = {}
    for i = 1, n do
        local lat = -halfSpan + (i - 0.5) * w
        local sum = 0
        for _, ft in ipairs(present) do
            sum = sum + levelAt(ft, centeredArea(x + rx * lat, z + rz * lat, dx, dz, hl, w / 2))
        end
        prof[i] = sum
    end
    -- morceaux d'andain en travers (une bande vide au milieu tolérée), le plus proche de la direction
    local best, bestD, bestL = nil, huge, 0
    local i = 1
    while i <= n do
        if prof[i] > 0 then
            local first, last = i, i
            local j = i + 1
            while j <= n and (prof[j] > 0 or (j + 1 <= n and prof[j + 1] > 0)) do
                if prof[j] > 0 then
                    last = j
                end
                j = j + 1
            end
            local sw, sl = 0, 0
            for k = first, last do
                local lat = -halfSpan + (k - 0.5) * w
                sw = sw + prof[k]
                sl = sl + prof[k] * lat
            end
            local c = sl / sw
            if math.abs(c) < bestD - 1e-9 then
                best, bestD, bestL = c, math.abs(c), sw
            end
            i = last + 1
        else
            i = i + 1
        end
    end
    return best, bestL
end

-- litres de tas (produits de la presse) sur le parallélogramme centré sur x, z : halfLen le long de la direction,
-- halfWidth en travers (même lecture que ADBalerManager.hasWindrow)
function ADWindrowScan.amountAt(x, z, dirX, dirZ, fillTypes, halfLen, halfWidth)
    if not heapReady() or tonumber(x) == nil or tonumber(z) == nil then
        return 0
    end
    local dx, dz = unit(dirX, dirZ)
    if dx == nil then
        dx, dz = 0, 1
    end
    halfLen = num(halfLen, ADWindrowScan.HALF_LEN, 0)
    halfWidth = num(halfWidth, ADWindrowScan.HALF_WIDTH, 0)
    local total = 0
    for _, ft in ipairs(typeList(fillTypes)) do
        total = total + levelAt(ft, centeredArea(x, z, dx, dz, halfLen, halfWidth))
    end
    return total
end

-- reste-t-il un andain sur les champs du groupe ? (contrôle rapide d'un coup, par grands blocs ; minLiters :
-- ANY_MIN_LITERS par défaut, en dessous ce sont des restes)
function ADWindrowScan.anyLeft(fieldNums, fillTypes, minLiters)
    if not heapReady() then
        return false
    end
    local types = typeList(fillTypes)
    if #types == 0 then
        return false
    end
    minLiters = num(minLiters, ADWindrowScan.ANY_MIN_LITERS, 0)
    local zone = ADWindrowScan.zone(fieldNums, ADWindrowScan.EDGE)
    if #zone.groups == 0 then
        return false
    end
    local w, h = zone.maxX - zone.minX, zone.maxZ - zone.minZ
    local bs = max(ADWindrowScan.ANY_BLOCK, sqrt(w * h / ADWindrowScan.ANY_MAX_BLOCKS))
    local nbx, nbz = max(1, ceil(w / bs)), max(1, ceil(h / bs))
    local reach = zone.edge + bs * 0.75
    local function litersIn(x0, z0, x1, z1)
        local sum = 0
        for _, ft in ipairs(types) do
            sum = sum + levelAt(ft, x0, z0, x1, z0, x0, z1)
        end
        return sum
    end
    for bj = 0, nbz - 1 do
        for bi = 0, nbx - 1 do
            local x0, z0 = zone.minX + bi * bs, zone.minZ + bj * bs
            local x1, z1 = min(x0 + bs, zone.maxX), min(z0 + bs, zone.maxZ)
            local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
            local near = false
            for _, p in ipairs(zone.groups) do
                if inPoly(p, cx, cz) or distPoly(p, cx, cz) <= reach then
                    near = true
                    break
                end
            end
            if near and anyHeapAt(x0, z0, x1, z0, x0, z1) ~= false and litersIn(x0, z0, x1, z1) >= minLiters then
                if rectInside(zone, x0, z0, x1, z1) then
                    return true
                end
                -- bloc au bord : seulement les morceaux de 4 m qui comptent pour le groupe
                local sub, inside = 4, 0
                local sz = z0
                while sz < z1 - 1e-6 do
                    local sx = x0
                    while sx < x1 - 1e-6 do
                        local ex, ez = min(sx + sub, x1), min(sz + sub, z1)
                        if inZone(zone, (sx + ex) / 2, (sz + ez) / 2) then
                            inside = inside + litersIn(sx, sz, ex, ez)
                            if inside >= minLiters then
                                return true
                            end
                        end
                        sx = sx + sub
                    end
                    sz = sz + sub
                end
            end
        end
    end
    return false
end
