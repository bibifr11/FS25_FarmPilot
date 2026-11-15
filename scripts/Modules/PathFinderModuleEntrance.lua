-- ============================================================================================================
-- FarmPilot : PathFinderModuleEntrance.lua
-- Entrée du champ des bennes : un carré de 20 × 20 m autour du point d'entrée où la culture peut être écrasée.
--
-- Règle (15/11) : rien ne roule dans la culture, sauf à l'entrée du champ : dans le carré de 20 × 20 m centré sur le
-- point du champ de la benne (sa 1re destination en mode « Décharger moissonneuse »), la culture compte comme absente
-- pour son trajet, sa place d'attente et le contrôle « trajet propre depuis l'entrée ».
--
-- Seulement pour les bennes (mode Décharger moissonneuse / ensileuse), seulement pendant leurs calculs : le carré est
-- posé au début du calcul et retiré à la fin. Les autres véhicules (moissonneuse avec sa coupe, tracteur de la
-- remorque porte-coupe, mode Autonome) ne sont pas concernés.
--
-- Branché par enveloppes (chargé après tous les PathFinderModule*.lua et FieldParkModule*.lua) :
-- PathFinderModule.update, PathFinderModule.startPathPlanningToPipe, ADFieldPark.searchStep, ADFieldPark.findDirectPath
-- (pose du carré) ;
-- PathFinderModule.getMapCropAt, ADFieldPark.hasGrowingCrop (culture absente dans le carré).
-- ============================================================================================================

PathFinderModule.ENTRANCE_SQUARE_HALF = 10 -- m : carré de 20 × 20 m
PathFinderModule.entranceSquares = nil      -- carrés actifs pendant le calcul d'une benne
PathFinderModule.cropIgnoreIslands = nil    -- (15/11) îlots oubliés ignorés aussi par ADFieldPark.hasGrowingCrop
PathFinderModule.entranceSquarePrinted = setmetatable({}, { __mode = "k" })

-- carrés d'entrée d'un véhicule : le point du champ d'une benne, nil pour les autres
function PathFinderModule.getEntranceSquares(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or AutoDrive == nil or AutoDrive.MODE_UNLOAD == nil then
        return nil
    end
    local stateModule = vehicle.ad.stateModule
    if stateModule.getMode == nil or stateModule:getMode() ~= AutoDrive.MODE_UNLOAD or stateModule.getFirstWayPoint == nil then
        return nil
    end
    local id = stateModule:getFirstWayPoint()
    local wp = id ~= nil and ADGraphManager ~= nil and ADGraphManager:getWayPointById(id) or nil
    if wp == nil then
        return nil
    end
    if PathFinderModule.entranceSquarePrinted[vehicle] ~= id then
        PathFinderModule.entranceSquarePrinted[vehicle] = id
        local name = vehicle.getName ~= nil and vehicle:getName() or "?"
        print(string.format("[AD-Entree] %s: carre de %.0f x %.0f m autour de l'entree du champ (%.0f,%.0f) : la culture peut y etre ecrasee",
            tostring(name), 2 * PathFinderModule.ENTRANCE_SQUARE_HALF, 2 * PathFinderModule.ENTRANCE_SQUARE_HALF, wp.x, wp.z))
    end
    return {{x = wp.x, z = wp.z}}
end

function PathFinderModule.isInEntranceSquare(x, z)
    local squares = PathFinderModule.entranceSquares
    if squares == nil then
        return false
    end
    local h = PathFinderModule.ENTRANCE_SQUARE_HALF
    for _, sq in ipairs(squares) do
        if math.abs(x - sq.x) <= h and math.abs(z - sq.z) <= h then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Règles de base des bennes (15/11, remises) : seule la culture DU CHAMP de la moissonneuse compte. La culture d'un
-- champ voisin (de l'autre côté d'un chemin, d'une haie) est ignorée : le train ne va de toute façon jamais sur un
-- autre champ en Strict (PathFinderModuleField.lua). Les îlots de culture oubliés par la moissonneuse sont ignorés.
-- Posé avec le carré de l'entrée, pendant les calculs des bennes seulement.
-- ------------------------------------------------------------------------------------------------------------
PathFinderModule.cropOwnAreas = nil
PathFinderModule.cropOwnPrinted = setmetatable({}, { __mode = "k" })

function PathFinderModule.getCropOwnAreas(vehicle, squares, combine)
    if squares == nil then
        return nil
    end
    local areas, count = {}, 0
    local points = {}
    -- le champ est pris sous la moissonneuse (toujours sur son champ) ; l'entrée seulement si elle est inconnue :
    -- un champ voisin peut être plus près du point d'entrée que le champ lui-même
    if combine == nil and vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.modes ~= nil and AutoDrive.MODE_UNLOAD ~= nil then
        local mode = vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
        combine = mode ~= nil and mode.combine or nil
    end
    if combine ~= nil and combine.components ~= nil and combine.components[1] ~= nil and combine.components[1].node ~= nil then
        local cx, _, cz = getWorldTranslation(combine.components[1].node)
        table.insert(points, {x = cx, z = cz})
    else
        for _, sq in ipairs(squares) do
            table.insert(points, {x = sq.x, z = sq.z})
        end
    end
    for _, p in ipairs(points) do
        local area = PathFinderModule.getConnectedFieldArea(p.x, p.z)
        if area ~= nil and not areas[area] then
            areas[area] = true
            count = count + 1
        end
    end
    if count == 0 then
        return nil
    end
    if PathFinderModule.cropOwnPrinted[vehicle] ~= count then
        PathFinderModule.cropOwnPrinted[vehicle] = count
        local name = vehicle ~= nil and vehicle.getName ~= nil and vehicle:getName() or "?"
        print(string.format("[AD-Entree] %s: seule la culture du champ de la moissonneuse compte (%d zone(s) de champ), culture des champs voisins et ilots oublies ignores",
            tostring(name), count))
    end
    return areas
end

-- culture d'un champ voisin : sol de champ qui n'est dans aucune zone du champ de la moissonneuse
function PathFinderModule.isOtherFieldCrop(x, z)
    local areas = PathFinderModule.cropOwnAreas
    if areas == nil then
        return false
    end
    -- sol de champ seulement (lu dans la carte du sol) : sans lui, on ne sait pas à quel champ est la culture
    if not AutoDrive.checkIsOnField(x, 0, z) then
        return false
    end
    for area, _ in pairs(areas) do
        if PathFinderModule.isInFieldArea(area, x, z) then
            return false
        end
    end
    return true
end

-- appelle fn avec les carrés du véhicule posés, les retire ensuite (même en cas d'erreur, l'erreur est relancée)
function PathFinderModule.withEntranceSquares(vehicle, fn, ...)
    local saved = PathFinderModule.entranceSquares
    local savedAreas = PathFinderModule.cropOwnAreas
    local savedIsolated = PathFinderModule.ignoreIsolatedCrop
    PathFinderModule.entranceSquares = PathFinderModule.getEntranceSquares(vehicle)
    local first = select(1, ...)
    if PathFinderModule.entranceSquares ~= nil then
        local combine = type(first) == "table" and first.pipeCombine or nil
        PathFinderModule.cropOwnAreas = PathFinderModule.getCropOwnAreas(vehicle, PathFinderModule.entranceSquares, combine)
        PathFinderModule.ignoreIsolatedCrop = true
    elseif type(first) == "table" and first.cropCombine ~= nil then
        -- (15/11) tracteur de la remorque porte-barre qui entre dans le champ jusqu'à la moissonneuse : mêmes règles
        -- de base (culture des champs voisins et îlots oubliés ignorés), sans carré d'entrée
        PathFinderModule.cropOwnAreas = PathFinderModule.getCropOwnAreas(vehicle, {}, first.cropCombine)
        PathFinderModule.ignoreIsolatedCrop = true
    end
    local results = table.pack(xpcall(fn, function(e)
        return (debug ~= nil and debug.traceback ~= nil) and debug.traceback(tostring(e), 2) or e
    end, ...))
    PathFinderModule.entranceSquares = saved
    PathFinderModule.cropOwnAreas = savedAreas
    PathFinderModule.ignoreIsolatedCrop = savedIsolated
    if not results[1] then
        error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
end

-- ------------------------------------------------------------------------------------------------------------
-- Culture absente dans le carré
-- ------------------------------------------------------------------------------------------------------------
local getMapCropAt = PathFinderModule.getMapCropAt
PathFinderModule.getMapCropAt = function(x, z)
    if PathFinderModule.entranceSquares ~= nil and PathFinderModule.isInEntranceSquare(x, z) then
        return 0
    end
    local crop = getMapCropAt(x, z)
    if crop ~= 0 and PathFinderModule.cropOwnAreas ~= nil and PathFinderModule.isOtherFieldCrop(x, z) then
        return 0
    end
    return crop
end

if ADFieldPark ~= nil and ADFieldPark.hasGrowingCrop ~= nil then
    local hasGrowingCrop = ADFieldPark.hasGrowingCrop
    ADFieldPark.hasGrowingCrop = function(x, z)
        if PathFinderModule.entranceSquares ~= nil and PathFinderModule.isInEntranceSquare(x, z) then
            return false
        end
        if PathFinderModule.cropOwnAreas ~= nil and PathFinderModule.isOtherFieldCrop(x, z) then
            return false
        end
        local crop, fruit = hasGrowingCrop(x, z)
        -- (15/11) îlots oubliés ignorés (remorque porte-barre en fin de champ, AutonomousHeaderCollect.lua)
        if crop and PathFinderModule.cropIgnoreIslands and PathFinderModule.isIsolatedCrop ~= nil and PathFinderModule.isIsolatedCrop(x, z) then
            return false
        end
        return crop, fruit
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Pose du carré pendant les calculs des bennes
-- ------------------------------------------------------------------------------------------------------------
local update = PathFinderModule.update
PathFinderModule.update = function(self, ...)
    return PathFinderModule.withEntranceSquares(self.vehicle, update, self, ...)
end

-- (15/11) le départ du calcul vers la goulotte essaie d'abord le suivi du bord de la culture (PathFinderModuleEdge.lua,
-- hors de update) : le carré y est posé aussi
local startPathPlanningToPipe = PathFinderModule.startPathPlanningToPipe
PathFinderModule.startPathPlanningToPipe = function(self, ...)
    return PathFinderModule.withEntranceSquares(self.vehicle, startPathPlanningToPipe, self, ...)
end

if ADFieldPark ~= nil then
    if ADFieldPark.searchStep ~= nil then
        local searchStep = ADFieldPark.searchStep
        ADFieldPark.searchStep = function(search, ...)
            return PathFinderModule.withEntranceSquares(search ~= nil and search.vehicle or nil, searchStep, search, ...)
        end
    end
    if ADFieldPark.findDirectPath ~= nil then
        local findDirectPath = ADFieldPark.findDirectPath
        ADFieldPark.findDirectPath = function(vehicle, ...)
            return PathFinderModule.withEntranceSquares(vehicle, findDirectPath, vehicle, ...)
        end
    end
end
