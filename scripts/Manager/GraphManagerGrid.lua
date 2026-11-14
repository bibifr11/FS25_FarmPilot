-- ============================================================================================================
-- FarmPilot : GraphManagerGrid.lua
-- Points du réseau rangés par cases de 100 m : chercher le point le plus proche, ou les points autour d'un endroit,
-- ne parcourt plus tout le réseau (14/11).
--
-- D'où ça vient : retour d'un joueur le 14/11 (ralentissements avec 3 moissonneuses et 9 tracteurs, réseau de
-- 34 973 points et 574 marqueurs). À chaque départ, chaque sortie de champ, chaque recherche du point de départ,
-- AutoDrive passait sur tous les points du réseau, souvent 2 ou 3 fois de suite : avec 35 000 points, un à-coup à
-- chaque fois, multiplié par le nombre de véhicules.
--
-- Règle :
-- - les points sont rangés une fois par cases de GRID_SIZE m ; la grille est refaite au premier besoin après toute
--   modification du réseau (markChanges : éditeur, chargement, réseau reçu en multijoueur) ou si le nombre de points
--   a changé ;
-- - points autour d'un endroit (rayon) : seulement les cases qui touchent le cercle ;
-- - point le plus proche : la case de l'endroit, puis un anneau de cases de plus tant qu'un point plus proche peut
--   encore s'y trouver ; même résultat que l'ancien parcours complet ;
-- - le calcul de la route jusqu'à la destination ne change pas.
--
-- Enveloppes posées au chargement : ADGraphManager:markChanges (grille à refaire) ; remplacées :
-- AutoDrive:updateWayPointsDistance (points autour du véhicule + plus proche), ADGraphManager:getWayPointsInRange.
-- Pour nos fichiers : ADGraphManager:fpGetWayPointsNear(x, z, rayon) = points des cases autour (à filtrer ensuite).
-- Chargé par register.lua après AutonomousYardZone.lua (Specialization.lua et GraphManager.lua déjà chargés).
-- ============================================================================================================

ADGraphGrid = {}

ADGraphGrid.GRID_SIZE = 100   -- m, côté d'une case
ADGraphGrid.grid = nil
ADGraphGrid.builds = 0        -- grilles faites depuis le chargement (mesure fpPerf)

local floor = math.floor
local sqrt = math.sqrt
local abs = math.abs
local max = math.max

local function cellKey(cx, cz)
    return cx * 100000 + cz
end

-- grille à jour (refaite si le réseau a changé)
function ADGraphGrid.get()
    local wayPoints = ADGraphManager:getWayPoints()
    if wayPoints == nil then
        return nil
    end
    local count = #wayPoints
    local g = ADGraphGrid.grid
    if g ~= nil and g.source == wayPoints and g.count == count then
        return g
    end
    local size = ADGraphGrid.GRID_SIZE
    local cells = {}
    local minCx, maxCx, minCz, maxCz = math.huge, -math.huge, math.huge, -math.huge
    for _, wp in pairs(wayPoints) do
        if wp.x ~= nil and wp.z ~= nil then
            local cx, cz = floor(wp.x / size), floor(wp.z / size)
            local key = cellKey(cx, cz)
            local cell = cells[key]
            if cell == nil then
                cell = {}
                cells[key] = cell
            end
            cell[#cell + 1] = wp
            if cx < minCx then minCx = cx end
            if cx > maxCx then maxCx = cx end
            if cz < minCz then minCz = cz end
            if cz > maxCz then maxCz = cz end
        end
    end
    g = { source = wayPoints, count = count, cells = cells, size = size, minCx = minCx, maxCx = maxCx, minCz = minCz, maxCz = maxCz, empty = minCx == math.huge }
    ADGraphGrid.grid = g
    ADGraphGrid.builds = ADGraphGrid.builds + 1
    return g
end

-- fn(wp) pour chaque point des cases qui touchent le cercle (x, z, r) ; à filtrer par la distance
function ADGraphGrid.forEachNear(g, x, z, r, fn)
    if g == nil or g.empty then
        return
    end
    local size = g.size
    local cx0, cx1 = max(floor((x - r) / size), g.minCx), math.min(floor((x + r) / size), g.maxCx)
    local cz0, cz1 = max(floor((z - r) / size), g.minCz), math.min(floor((z + r) / size), g.maxCz)
    local cells = g.cells
    for cx = cx0, cx1 do
        for cz = cz0, cz1 do
            local cell = cells[cellKey(cx, cz)]
            if cell ~= nil then
                for i = 1, #cell do
                    fn(cell[i])
                end
            end
        end
    end
end

-- point le plus proche de (x, z) qui passe le filtre (ou n'importe lequel) : wp, distance
function ADGraphGrid.closest(g, x, z, filter)
    if g == nil or g.empty then
        return nil, math.huge
    end
    local size = g.size
    local cx, cz = floor(x / size), floor(z / size)
    local cells = g.cells
    local best, bestD = nil, math.huge
    local function scan(kx, kz)
        local cell = cells[cellKey(kx, kz)]
        if cell ~= nil then
            for i = 1, #cell do
                local wp = cell[i]
                local dx, dz = wp.x - x, wp.z - z
                local d = sqrt(dx * dx + dz * dz)
                if d < bestD and (filter == nil or filter(wp)) then
                    best, bestD = wp, d
                end
            end
        end
    end
    local maxRing = max(abs(cx - g.minCx), abs(g.maxCx - cx), abs(cz - g.minCz), abs(g.maxCz - cz))
    for k = 0, maxRing do
        if k == 0 then
            scan(cx, cz)
        else
            for dx = -k, k do
                scan(cx + dx, cz - k)
                scan(cx + dx, cz + k)
            end
            for dz = -k + 1, k - 1 do
                scan(cx - k, cz + dz)
                scan(cx + k, cz + dz)
            end
        end
        -- un point hors des anneaux 0..k est à au moins k cases de l'endroit
        if best ~= nil and bestD <= k * size then
            break
        end
    end
    return best, bestD
end

local function notReverse(wp)
    return wp.incoming == nil or #wp.incoming > 0
end

-- mesure fpPerf (FarmPilotPerf.lua), si elle tourne
local function perfStart()
    local perf = ADFarmPilotPerf
    if perf ~= nil and perf.active then
        return perf.now()
    end
    return nil
end
local function perfStop(t0, what)
    if t0 ~= nil and ADFarmPilotPerf ~= nil and ADFarmPilotPerf.active then
        ADFarmPilotPerf.add(what, ADFarmPilotPerf.now() - t0)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Remplacements (mêmes résultats que les fonctions d'AutoDrive, sans parcourir tout le réseau)
-- ------------------------------------------------------------------------------------------------------------

-- AutoDrive:updateWayPointsDistance (Specialization.lua) : points à moins de drawDistance du véhicule, point le plus
-- proche, point le plus proche qui n'est pas un départ de marche arrière
local baseUpdateWayPointsDistance = AutoDrive.updateWayPointsDistance
function AutoDrive:updateWayPointsDistance(x, z)
    local g = ADGraphGrid.get()
    if g == nil then
        return baseUpdateWayPointsDistance(self, x, z)
    end
    local t0 = perfStart()
    local distances = self.ad.distances
    distances.wayPoints = {}
    distances.closest.wayPoint = nil
    distances.closest.distance = math.huge
    distances.closestNotReverse.wayPoint = nil
    distances.closestNotReverse.distance = math.huge
    self.ad.wayPointsInRange = nil

    if x == nil or z == nil then
        x, _, z = getWorldTranslation(self.components[1].node)
    end
    local drawDistance = AutoDrive.drawDistance or 0
    local list = distances.wayPoints
    local closest, closestD = nil, math.huge
    local notRev, notRevD = nil, math.huge
    ADGraphGrid.forEachNear(g, x, z, drawDistance, function(wp)
        local dx, dz = wp.x - x, wp.z - z
        local distance = sqrt(dx * dx + dz * dz)
        if distance <= drawDistance then
            list[#list + 1] = {distance = distance, wayPoint = wp}
            if distance < closestD then
                closest, closestD = wp, distance
            end
            if distance < notRevD and notReverse(wp) then
                notRev, notRevD = wp, distance
            end
        end
    end)
    -- rien à moins de drawDistance : on cherche plus loin, anneau par anneau
    if closest == nil then
        closest, closestD = ADGraphGrid.closest(g, x, z, nil)
    end
    if notRev == nil then
        notRev, notRevD = ADGraphGrid.closest(g, x, z, notReverse)
    end
    distances.closest.wayPoint = closest
    distances.closest.distance = closest ~= nil and closestD or math.huge
    distances.closestNotReverse.wayPoint = notRev
    distances.closestNotReverse.distance = notRev ~= nil and notRevD or math.huge
    perfStop(t0, "closest")
end

-- ADGraphManager:getWayPointsInRange (GraphManager.lua) : ids des points entre rangeMin et rangeMax (exclus)
local baseGetWayPointsInRange = ADGraphManager.getWayPointsInRange
function ADGraphManager:getWayPointsInRange(point, rangeMin, rangeMax)
    local g = ADGraphGrid.get()
    if g == nil or point == nil or rangeMax == nil or rangeMax == math.huge then
        return baseGetWayPointsInRange(self, point, rangeMin, rangeMax)
    end
    local t0 = perfStart()
    local inRange = {}
    ADGraphGrid.forEachNear(g, point.x, point.z, rangeMax, function(wp)
        local dis = MathUtil.vector2Length(wp.x - point.x, wp.z - point.z)
        if dis < rangeMax and dis > rangeMin then
            inRange[#inRange + 1] = wp.id
        end
    end)
    perfStop(t0, "closest")
    return inRange
end

-- pour nos fichiers : les points des cases autour de (x, z) (liste à filtrer par la distance)
function ADGraphManager:fpGetWayPointsNear(x, z, r)
    local g = ADGraphGrid.get()
    if g == nil or r == nil or r == math.huge then
        return self:getWayPoints() or {}
    end
    local list = {}
    ADGraphGrid.forEachNear(g, x, z, r, function(wp)
        list[#list + 1] = wp
    end)
    return list
end

-- réseau modifié : grille à refaire
local baseMarkChanges = ADGraphManager.markChanges
function ADGraphManager:markChanges()
    ADGraphGrid.grid = nil
    return baseMarkChanges(self)
end
