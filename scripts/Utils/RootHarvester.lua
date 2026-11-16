-- ============================================================================================================
-- FarmPilot : RootHarvester.lua
-- Bennes des arracheuses (ni moissonneuse ni ensileuse : carottes, pommes de terre, betteraves, panais...) (14/11).
--
-- D'où ça vient : retour d'un joueur du 14/11 (FarmPilot 1.0.1.39, Courseplay, arracheuse de carottes Dewulf
-- tractée, 3 captures) :
-- 1. la benne vide arrive du mauvais côté de la goulotte, puis se corrige ;
-- 2. la benne pleine affiche « Planning the way out of the field » 6 à 10 min (610 s) avant de partir ;
-- 3. les bennes suivantes attendent en file sur le chemin avec « Planning the way (3905 s) ».
--
-- Causes trouvées :
-- 1. AutoDrive.getPipeSide (CombineUtil.lua, identique à AutoDrive 3.0.1.4) garde le côté de la goulotte dès
--    qu'elle est « sortie ». Sur l'arracheuse Dewulf, la goulotte n'a qu'une position, toujours « sortie », même
--    repliée pour la route : le côté lu machine repliée (bout de la goulotte relevé au-dessus de la machine) est
--    gardé pour toute la partie. Le trajet vers la goulotte vise ce côté ; une fois en suivi, la place est
--    recalculée sous le bout de la goulotte, d'où la correction ;
-- 2. un seul véhicule calcule à la fois (ADScheduler, tranches de 3 s) : un véhicule resté dans la file sans plus
--    calculer (calcul arrêté par sa tâche) garde sa tranche, les autres sont en pause pendant ce temps ; et chaque
--    point de sortie essayé sans trajet propre coûte une recherche complète (toutes les tailles de cases) ;
-- 3. la benne suivante recalcule sans fin vers la 1re (jamais lâcher le suivi) ; le compteur affiché ne repartait
--    pas de zéro entre deux calculs (3905 s = depuis le 1er calcul, pas un seul calcul).
--
-- Règle (arracheuses seulement, moissonneuse et ensileuse ne changent pas) :
-- - côté de la goulotte : lu et gardé seulement machine dépliée ; repliée, le côté du pied de la goulotte (fixé
--   au châssis), sans le garder ; même chose pour la longueur de la goulotte ;
-- - sortie du champ : ROOT_CANDIDATE_MAX de calcul au plus par point de sortie, puis le point suivant ; plus aucun
--   point ou ROOT_EXIT_MAX dépassé : secours en ligne droite sans culture vers un point du réseau (dans l'axe du
--   réseau quand il tient) ; jamais à travers la culture ;
-- - benne suivante : ROOT_FOLLOW_PLAN_MAX de calculs sans rouler vers la 1re, puis elle attend sur place sans plus
--   calculer, jusqu'à passer 1re (elle part alors à l'arracheuse comme avant).
--
-- Valable pour tous (aucune logique changée, seulement des pannes) :
-- - file du calcul : un véhicule qui ne calcule plus depuis IDLE_TIME est retiré de la file (remis s'il reprend) ;
-- - « Planning the way (N s) » : le compteur repart de zéro à chaque changement d'étape de la tâche.
--
-- Enveloppes posées au chargement (aucune ligne dans les fichiers d'origine) : AutoDrive.getPipeSide,
-- AutoDrive.getPipeLength, ExitFieldTask:update, ExitFieldTask:handleNoExitRoute,
-- DriveToVehicleTask:updateFollowFirst, DriveToVehicleTask:getI18nInfo, PathFinderModule:update, ADScheduler:updateActiveVehicle,
-- ADScheduler:addPathfinderVehicle,
-- ADTaskModule:update. Chargé par register.lua après TireChangeManager.lua.
-- ============================================================================================================

ADRootHarvester = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
ADRootHarvester.GRAIN = { "WHEAT", "BARLEY", "OAT", "CANOLA", "SORGHUM", "SOYBEAN", "MAIZE", "SUNFLOWER", "RICE", "RICELONGGRAIN" }
ADRootHarvester.BASE_MIN_X = 0.3              -- m : pied de la goulotte, nettement d'un côté de l'axe de la machine
ADRootHarvester.READ_MIN_X = 0.5              -- m : bout de la goulotte dépliée, nettement d'un côté
ADRootHarvester.ROOT_CANDIDATE_MAX = 30000    -- ms de calcul (tranches de la file) au plus pour un point de sortie
ADRootHarvester.ROOT_EXIT_MAX = 90000         -- ms depuis le début du calcul de sortie : secours en ligne droite
ADRootHarvester.ROOT_STRAIGHT_MAX = 300       -- m : point du réseau visé en ligne droite au plus loin
ADRootHarvester.ROOT_STRAIGHT_STEP = 3        -- m entre deux points de la ligne droite
ADRootHarvester.ROOT_FOLLOW_PLAN_MAX = 90000  -- ms de calculs sans rouler vers la 1re benne
ADRootHarvester.STATE_ROOT_WAIT = 20          -- DriveToVehicleTask : attend sur place sans calculer
ADRootHarvester.IDLE_TIME = 8000              -- ms sans calcul : retiré de la file du calcul

local function log(fmt, ...)
    print(string.format("[FarmPilot Arracheuse] " .. fmt, ...))
end

local function vehicleName(vehicle)
    if vehicle ~= nil and vehicle.getName ~= nil then
        local ok, name = pcall(vehicle.getName, vehicle)
        if ok and name ~= nil then
            return tostring(name)
        end
    end
    return "?"
end

local function now()
    return g_time or 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Arracheuse ou pas
-- ------------------------------------------------------------------------------------------------------------
-- true : récolteuse à trémie et goulotte (pas une ensileuse) qui ne prend aucune céréale
function ADRootHarvester.isRoot(combine)
    if combine == nil or combine.ad == nil or combine.ad.isHarvester ~= true or combine.spec_combine == nil then
        return false
    end
    if combine.ad.fpIsRoot ~= nil then
        return combine.ad.fpIsRoot
    end
    local types = nil
    if combine.getFillUnitSupportedFillTypes ~= nil and g_fillTypeManager ~= nil then
        types = combine:getFillUnitSupportedFillTypes(combine.spec_combine.fillUnitIndex or 1)
    end
    if types == nil or next(types) == nil then
        return false -- pas encore lu : on regardera au prochain appel
    end
    local root = true
    for _, name in ipairs(ADRootHarvester.GRAIN) do
        local index = g_fillTypeManager:getFillTypeIndexByName(name)
        if index ~= nil and types[index] then
            root = false
            break
        end
    end
    combine.ad.fpIsRoot = root
    if root then
        local names = {}
        for index, on in pairs(types) do
            if on then
                names[#names + 1] = tostring(g_fillTypeManager:getFillTypeNameByIndex(index))
            end
        end
        table.sort(names)
        log("%s : arracheuse (%s), règles des arracheuses pour ses bennes", vehicleName(combine), table.concat(names, ", "))
    end
    return root
end

-- l'arracheuse de la benne (celle qu'elle vide, sinon la dernière)
function ADRootHarvester.harvesterOf(vehicle)
    if vehicle == nil or vehicle.ad == nil then
        return nil
    end
    local mode = vehicle.ad.modes ~= nil and AutoDrive.MODE_UNLOAD ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    return (mode ~= nil and mode.combine) or vehicle.ad.lastHarvester
end

function ADRootHarvester.isRootUnloader(vehicle)
    return ADRootHarvester.isRoot(ADRootHarvester.harvesterOf(vehicle))
end

-- ------------------------------------------------------------------------------------------------------------
-- Côté et longueur de la goulotte
-- ------------------------------------------------------------------------------------------------------------
-- machine dépliée (en travail) ; sans pliage : toujours dépliée
function ADRootHarvester.isUnfolded(combine)
    if combine.spec_foldable ~= nil and combine.getIsUnfolded ~= nil then
        local ok, unfolded = pcall(combine.getIsUnfolded, combine)
        if ok and unfolded == false then
            return false
        end
    end
    return true
end

function ADRootHarvester.isWorking(combine)
    return ADRootHarvester.isUnfolded(combine) and AutoDrive.isPipeOut(combine)
end

-- côté du pied de la goulotte : du châssis vers le bout, le 1er élément nettement d'un côté ; 0 si aucun
function ADRootHarvester.getMountSide(combine)
    local dischargeNode = AutoDrive.getDischargeNode(combine)
    local root = AutoDrive.getPipeRoot(combine)
    if dischargeNode == nil or root == nil then
        return 0
    end
    local chain = {}
    local node = dischargeNode
    local count = 0
    while node ~= nil and node ~= 0 and node ~= root and count < 100 do
        chain[#chain + 1] = node
        node = getParent(node)
        count = count + 1
    end
    for i = #chain, 1, -1 do
        local x = localToLocal(chain[i], root, 0, 0, 0)
        if math.abs(x) >= ADRootHarvester.BASE_MIN_X then
            return AutoDrive.sign(x), x
        end
    end
    return 0
end

-- côté lu sur le bout de la goulotte (comme AutoDrive), sans rien garder
function ADRootHarvester.readTipSide(combine)
    local root = AutoDrive.getPipeRoot(combine)
    local x, y, z = getWorldTranslation(AutoDrive.getDischargeNode(combine))
    local diffX = AutoDrive.worldToLocal(combine, x, y, z, root)
    return AutoDrive.sign(diffX), diffX
end

local function sideText(side)
    if side == AutoDrive.CHASEPOS_LEFT then
        return "gauche"
    elseif side == AutoDrive.CHASEPOS_RIGHT then
        return "droite"
    end
    return "au milieu"
end

-- AutoDrive.getPipeSide pour une arracheuse ; nil : pas une arracheuse (code d'origine)
function ADRootHarvester.getPipeSide(combine)
    if not ADRootHarvester.isRoot(combine) then
        return nil
    end
    local ad = combine.ad
    if ad.fpRootPipeSide ~= nil and ad.fpRootPipeRoot ~= nil and ad.pipeRoot == ad.fpRootPipeRoot then
        ad.storedPipeSide = ad.fpRootPipeSide
        return ad.fpRootPipeSide
    end
    ad.fpRootPipeSide = nil
    if ADRootHarvester.isWorking(combine) then
        local side, x = ADRootHarvester.readTipSide(combine)
        if math.abs(x or 0) >= ADRootHarvester.READ_MIN_X then
            ad.fpRootPipeSide = side
            ad.fpRootPipeRoot = AutoDrive.getPipeRoot(combine)
            ad.storedPipeSide = side
            log("%s : goulotte à %s (lue machine dépliée, %.1f m de l'axe), gardée", vehicleName(combine), sideText(side), x)
            return side
        end
    end
    -- repliée (ou bout de la goulotte dans l'axe) : rien n'est gardé, le côté du pied de la goulotte
    ad.storedPipeSide = nil
    local side, x = ADRootHarvester.getMountSide(combine)
    if side == 0 then
        side = ADRootHarvester.readTipSide(combine)
    end
    if ad.fpRootFoldedLog ~= side then
        ad.fpRootFoldedLog = side
        log("%s : machine repliée, goulotte à %s d'après son pied (%s), relue une fois dépliée", vehicleName(combine), sideText(side), x ~= nil and string.format("%.1f m de l'axe", x) or "bout de la goulotte")
    end
    return side
end

-- AutoDrive.getPipeLength pour une arracheuse : la longueur n'est gardée que machine dépliée
function ADRootHarvester.getPipeLength(combine, base)
    local ad = combine.ad
    if ad.fpRootLengthOk == true and ad.storedPipeLength ~= nil then
        return ad.storedPipeLength
    end
    local working = ADRootHarvester.isWorking(combine)
    ad.storedPipeLength = nil
    local length = base(combine)
    if working then
        ad.fpRootLengthOk = ad.storedPipeLength ~= nil
    else
        ad.storedPipeLength = nil
    end
    return length
end

local baseGetPipeSide = AutoDrive.getPipeSide
function AutoDrive.getPipeSide(combine)
    local ok, side = FarmPilotCall(ADRootHarvester.getPipeSide, combine)
    if ok and side ~= nil then
        return side
    end
    return baseGetPipeSide(combine)
end

local baseGetPipeLength = AutoDrive.getPipeLength
function AutoDrive.getPipeLength(combine)
    if combine ~= nil and ADRootHarvester.isRoot(combine) then
        local ok, length = FarmPilotCall(ADRootHarvester.getPipeLength, combine, baseGetPipeLength)
        if ok and length ~= nil then
            return length
        end
    end
    return baseGetPipeLength(combine)
end

-- ------------------------------------------------------------------------------------------------------------
-- Sortie du champ de la benne pleine (ExitFieldTask)
-- ------------------------------------------------------------------------------------------------------------
-- true : ce véhicule calcule en ce moment (il a la tranche de la file, ou il est seul)
local function isComputing(vehicle)
    if ADScheduler == nil or ADScheduler.pathFinderVehicles == nil then
        return true
    end
    return ADScheduler.activePathFinderVehicle == vehicle or #ADScheduler.pathFinderVehicles <= 1
end

-- secours : ligne droite sans culture vers un point du réseau (dans l'axe du réseau quand il tient)
function ADRootHarvester.straightExit(task, why)
    local vehicle = task.vehicle
    local pf = vehicle.ad.pathFinderModule
    local candidates = task:buildCandidates()
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local halfWidth = pf:getTrainWidth() / 2
    local chosen, chosenIndex, approach, appended = nil, nil, nil, nil
    -- 1er passage : les points atteints dans l'axe du réseau (portail), 2e : les autres
    for pass = 1, 2 do
        for index, c in ipairs(candidates) do
            if c.distance <= ADRootHarvester.ROOT_STRAIGHT_MAX then
                local a, list = nil, nil
                if pass == 1 then
                    a, list = task:buildApproach(c)
                end
                if pass == 2 or a ~= nil then
                    local tx, tz = c.wp.x, c.wp.z
                    if a ~= nil then
                        tx, tz = a.x, a.z
                    end
                    if ExitFieldTask.getCropCrossing(vx, vz, tx, tz, halfWidth) < 0.5 then
                        chosen, chosenIndex, approach, appended = c, index, a, list
                        break
                    end
                end
            end
        end
        if chosen ~= nil then
            break
        end
    end
    if chosen == nil then
        log("%s : %s, aucune ligne droite sans culture vers un point du réseau (%d points regardés)", vehicleName(vehicle), why, #candidates)
        return false
    end
    local target = approach or {x = chosen.wp.x, y = chosen.wp.y, z = chosen.wp.z}
    local dx, dz = target.x - vx, target.z - vz
    local length = math.sqrt(dx * dx + dz * dz)
    local path = {}
    local step = ADRootHarvester.ROOT_STRAIGHT_STEP
    local d = step
    while d < length - step / 2 do
        local px, pz = vx + dx / length * d, vz + dz / length * d
        path[#path + 1] = {x = px, y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, px, 1, pz), z = pz}
        d = d + step
    end
    if appended ~= nil then
        for _, p in ipairs(appended) do
            path[#path + 1] = p
        end
    else
        path[#path + 1] = {x = chosen.wp.x, y = chosen.wp.y or getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, chosen.wp.x, 1, chosen.wp.z), z = chosen.wp.z}
    end
    pf:reset()
    if ADScheduler ~= nil then
        ADScheduler:removePathfinderVehicle(vehicle)
    end
    task.candidates = candidates
    task.candidateIndex = chosenIndex
    task.exitPoint = {x = chosen.wp.x, z = chosen.wp.z, id = chosen.wp.id}
    task.wayPoints = path
    vehicle.ad.drivePathModule:setWayPoints(path)
    pf.partialPath = false
    task:onExitRouteSet()
    task.state = ExitFieldTask.STATE_DRIVING
    task.fpRootPlanStart = nil
    log("%s : %s, sortie en ligne droite sans culture vers le point %s (%.0f m%s, %d points)", vehicleName(vehicle), why, tostring(chosen.wp.id), chosen.distance,
        approach ~= nil and string.format(", dans l'axe du réseau à %.0f m avant", approach.distance) or "", #path)
    return true
end

-- ExitFieldTask:update : true si traité ici
function ADRootHarvester.exitWatch(task, dt)
    if task.state ~= ExitFieldTask.STATE_PATHPLANNING then
        if task.state == ExitFieldTask.STATE_DRIVING then
            task.fpRootPlanStart = nil
        end
        return false
    end
    if task.directExit or not ADRootHarvester.isRootUnloader(task.vehicle) then
        return false
    end
    local t = now()
    task.fpRootPlanStart = task.fpRootPlanStart or t
    local key = tostring(task.candidateIndex)
    if task.fpRootCandKey ~= key then
        task.fpRootCandKey = key
        task.fpRootCandMs = 0
    end
    if isComputing(task.vehicle) then
        task.fpRootCandMs = task.fpRootCandMs + dt
    end
    if t - task.fpRootPlanStart > ADRootHarvester.ROOT_EXIT_MAX and not task.fpRootStraightTried then
        task.fpRootStraightTried = true
        if ADRootHarvester.straightExit(task, string.format("%d s de calcul de la sortie", math.floor((t - task.fpRootPlanStart) / 1000))) then
            return true
        end
    end
    if task.fpRootCandMs > ADRootHarvester.ROOT_CANDIDATE_MAX then
        local candidate = task.candidates ~= nil and task.candidates[task.candidateIndex] or nil
        log("%s : point de sortie %s (%s/%d) sans trajet après %d s de calcul, point suivant", vehicleName(task.vehicle), candidate ~= nil and tostring(candidate.wp.id) or "?",
            tostring(task.candidateIndex), task.candidates ~= nil and #task.candidates or 0, math.floor(task.fpRootCandMs / 1000))
        task.fpRootCandKey = nil
        local pf = task.vehicle.ad.pathFinderModule
        pf:reset()
        if ADScheduler ~= nil then
            ADScheduler:removePathfinderVehicle(task.vehicle)
        end
        task:handleNoExitRoute()
        return true
    end
    return false
end

-- ExitFieldTask:handleNoExitRoute : plus aucun point de sortie (la benne s'arrêterait) : la ligne droite d'abord
function ADRootHarvester.noExitRoute(task)
    if task.directExit or task.candidates == nil or (task.candidateIndex or 0) < #task.candidates then
        return false
    end
    if not ADRootHarvester.isRootUnloader(task.vehicle) then
        return false
    end
    if task:tryBandExit() then
        return true
    end
    return ADRootHarvester.straightExit(task, string.format("aucun des %d points de sortie n'a donné de trajet propre", #task.candidates))
end

local baseExitUpdate = ExitFieldTask.update
function ExitFieldTask:update(dt)
    local ok, handled = FarmPilotCall(ADRootHarvester.exitWatch, self, dt)
    if ok and handled then
        return
    end
    return baseExitUpdate(self, dt)
end

local baseNoExitRoute = ExitFieldTask.handleNoExitRoute
function ExitFieldTask:handleNoExitRoute()
    local ok, handled = FarmPilotCall(ADRootHarvester.noExitRoute, self)
    if ok and handled then
        return
    end
    return baseNoExitRoute(self)
end

-- ------------------------------------------------------------------------------------------------------------
-- Benne suivante vers la 1re (DriveToVehicleTask)
-- ------------------------------------------------------------------------------------------------------------
local FOLLOW_PLANNING = {
    [DriveToVehicleTask.STATE_PATHPLANNING] = true,
    [DriveToVehicleTask.STATE_BAND_WAIT] = true,
    [DriveToVehicleTask.STATE_RETRY_WAIT] = true,
}
local FOLLOW_MOVING = {
    [DriveToVehicleTask.STATE_DRIVING] = true,
    [DriveToVehicleTask.STATE_STRAIGHT] = true,
    [DriveToVehicleTask.STATE_WAIT_HERE] = true,
}

-- true si traité ici
function ADRootHarvester.followWatch(task, dt)
    if task.state == ADRootHarvester.STATE_ROOT_WAIT then
        if task.promoted or task.targetVehicle == nil or task.targetVehicle.components == nil then
            return false -- passée 1re, ou la 1re a disparu : la suite d'origine
        end
        if StepAsideTask ~= nil and StepAsideTask.hook(task.vehicle, task.targetVehicle, dt) then
            return true
        end
        task:stopHere(dt)
        return true
    end
    if FOLLOW_MOVING[task.state] then
        task.fpRootPlanMs = 0
        return false
    end
    if not FOLLOW_PLANNING[task.state] then
        return false
    end
    task.fpRootPlanMs = (task.fpRootPlanMs or 0) + dt
    if task.fpRootPlanMs <= ADRootHarvester.ROOT_FOLLOW_PLAN_MAX then
        return false
    end
    local firstMode = task.getFirstMode ~= nil and task:getFirstMode() or nil
    local harvester = (firstMode ~= nil and firstMode.combine) or ADRootHarvester.harvesterOf(task.vehicle)
    if not ADRootHarvester.isRoot(harvester) then
        task.fpRootPlanMs = 0
        return false
    end
    if task.state == DriveToVehicleTask.STATE_PATHPLANNING or task.state == DriveToVehicleTask.STATE_BAND_WAIT then
        task.vehicle.ad.pathFinderModule:reset()
        if ADScheduler ~= nil then
            ADScheduler:removePathfinderVehicle(task.vehicle)
        end
    end
    log("%s : %d s de calculs sans trouver de trajet vers %s, j'attends ici sans plus calculer jusqu'à passer 1re", vehicleName(task.vehicle),
        math.floor(task.fpRootPlanMs / 1000), vehicleName(task.targetVehicle))
    task.state = ADRootHarvester.STATE_ROOT_WAIT
    task:stopHere(dt)
    return true
end

local baseUpdateFollowFirst = DriveToVehicleTask.updateFollowFirst
local baseFollowI18n = DriveToVehicleTask.getI18nInfo
function DriveToVehicleTask:updateFollowFirst(dt)
    local ok, handled = FarmPilotCall(ADRootHarvester.followWatch, self, dt)
    if ok and handled then
        return
    end
    return baseUpdateFollowFirst(self, dt)
end

function DriveToVehicleTask:getI18nInfo()
    if self.state == ADRootHarvester.STATE_ROOT_WAIT then
        return "$l10n_AD_task_wait_for_call;"
    end
    return baseFollowI18n(self)
end

-- ------------------------------------------------------------------------------------------------------------
-- File du calcul (ADScheduler) : véhicules qui ne calculent plus
-- ------------------------------------------------------------------------------------------------------------
function ADRootHarvester.dropIdle(scheduler)
    local list = scheduler.pathFinderVehicles
    if list == nil then
        return
    end
    local t = now()
    for i = #list, 1, -1 do
        local vehicle = list[i]
        local pf = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.pathFinderModule or nil
        if pf ~= nil then
            if pf.fpLastUpdate == nil then
                pf.fpLastUpdate = t
            elseif t - pf.fpLastUpdate > ADRootHarvester.IDLE_TIME then
                print(string.format("[AD-File] %s ne calcule plus depuis %d s, retiré de la file du calcul", vehicleName(vehicle), math.floor((t - pf.fpLastUpdate) / 1000)))
                pf.fpDropped = true
                if scheduler.activePathFinderVehicle == vehicle then
                    scheduler.activePathFinderVehicle = nil
                end
                scheduler:removePathfinderVehicle(vehicle)
            end
        end
    end
end

-- entrée dans la file : compté à partir de maintenant (pas de son dernier calcul, parfois vieux de plusieurs minutes)
local baseAddPathfinderVehicle = ADScheduler.addPathfinderVehicle
function ADScheduler:addPathfinderVehicle(vehicle)
    local pf = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.pathFinderModule or nil
    if pf ~= nil and not ADRootHarvester.rotating then -- (le tour de la file remet le véhicule actif au bout : pas une entrée)
        pf.fpLastUpdate = now()
        pf.fpDropped = nil
    end
    return baseAddPathfinderVehicle(self, vehicle)
end

local baseUpdateActiveVehicle = ADScheduler.updateActiveVehicle
function ADScheduler:updateActiveVehicle()
    FarmPilotCall(ADRootHarvester.dropIdle, self)
    ADRootHarvester.rotating = true
    local ok, err = pcall(baseUpdateActiveVehicle, self)
    ADRootHarvester.rotating = false
    if not ok then
        error(err, 0)
    end
end

local basePfUpdate = PathFinderModule.update
function PathFinderModule:update(dt)
    self.fpLastUpdate = now()
    if self.fpDropped then
        self.fpDropped = nil
        if self.isFinished == false and ADScheduler ~= nil then
            ADScheduler:addPathfinderVehicle(self.vehicle)
        end
    end
    return basePfUpdate(self, dt)
end

-- ------------------------------------------------------------------------------------------------------------
-- Compteur « Planning the way (N s) » : repart de zéro à chaque changement d'étape de la tâche
-- ------------------------------------------------------------------------------------------------------------
local baseTaskModuleUpdate = ADTaskModule.update
function ADTaskModule:update(dt)
    local task = self.activeTask
    if task ~= nil and task.fpSeenState ~= task.state then
        task.fpSeenState = task.state
        task.infoStateStart = nil
    end
    return baseTaskModuleUpdate(self, dt)
end
