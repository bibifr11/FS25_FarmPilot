-- ============================================================================================================
-- FarmPilot : AutonomousFieldExit.lua
-- Mode Autonome : départ depuis l'intérieur d'un champ vers une destination du réseau.
--
-- Défaut constaté (15/11, carte Le_Mechet, champ 92) : ARION 570 et broyeur au milieu du champ, bouton parking à
-- 08:52:50 (l'outil va à sa place « G_Broyeur », puis le tracteur à « GT6 »). La route est partie du point 978, le
-- point du réseau le mieux placé devant le tracteur (à 11,5 m), sur un chemin hors du champ derrière un muret :
-- bloqué contre le muret, aucun contournement possible, arrêt. L'entrée du champ (point « Champ 92 », 8260) était à
-- 39 m derrière lui ; de là, la route passe (2e essai, tracteur rapproché à la main : départ 8260, 1 392 m). Le
-- départ d'une route prend le point du réseau devant le véhicule (ADGraphManager:getPathTo, GraphManagerStart.lua) ;
-- la sortie par l'entrée du champ n'existait que pour les bennes (ExitFieldTask).
--
-- Règle (15/11) : en mode Autonome, réglage « Sortie de champ » sur « Par défaut », un véhicule sur un champ qui part
-- vers une destination du réseau (fin de champ et bouton parking : place de l'outil ; champ suivant ; changement
-- d'outil ; aller atteler un outil ; dépôt des balles ; vidange de l'épandeur ; plein de carburant ou de semence ;
-- benne vidée avant le parking) sort d'abord par l'entrée du champ, comme les bennes : ExitFieldTask (l'entrée
-- d'abord, puis les points du réseau les plus proches, jamais à travers la culture ni hors du champ, approche dans
-- l'axe du réseau, obstacle sur le trajet : nouveau calcul en l'évitant). Au point de sortie, la route vers la
-- destination est calculée dans la même image et part de ce point, dans le sens où il est arrivé (point rejoint,
-- GraphManagerStart.lua) : pas d'attente, pas de demi-tour.
-- - Entrée du champ : la 1re destination si son point touche le champ où est le véhicule ; sinon les destinations
--   qui touchent ce champ, celles qui portent son numéro d'abord, puis la plus proche ; il faut une route de là
--   jusqu'à la destination.
-- - Rien ne change : réglage « Le plus proche » (comme AutoDrive) ; véhicule hors champ ; destination sur le même
--   champ ; véhicule déjà à moins de ENTRANCE_NEAR m de l'entrée ; aucune entrée connue (une ligne au journal) ;
--   autres modes ; moissonneuse équipée et tracteur de sa remorque porte-barre pendant leur travail (fpHeaderJob :
--   AutonomousHeader*.lua ont leurs propres entrées et sorties) ; trains.
-- - Aucune sortie propre (plus de point à essayer) : la route habituelle, une ligne au journal ; jamais d'arrêt de
--   plus qu'avant.
-- - Une fois par tâche : une route recalculée par la même tâche (bout d'un trajet partiel) ne ressort pas.
-- - Le calcul de la sortie part tout de suite (pas l'attente de 6 s des bennes, faite pour laisser partir la
--   moissonneuse).
--
-- Branché par : enveloppes posées au chargement de ce fichier sur setUp, update, abort, finished, getI18nInfo et
-- getInfoText de DriveToDestinationTask, LoadAtDestinationTask, UnloadAtDestinationTask et RefuelTask ;
-- ExitFieldTaskExitPoints.lua (une ligne chacune : buildCandidates lit exitEntranceId et exitDestinationId,
-- startExitPlanning appelle onNoExitCandidate) ; register.lua (chargé après AutonomousParkUnload.lua).
-- ============================================================================================================

ADAutonomousFieldExit = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAutonomousFieldExit.ENTRANCE_NEAR = 15          -- m : déjà si près de l'entrée du champ, la route habituelle
ADAutonomousFieldExit.ENTRANCE_TRIES = 4          -- destinations du champ essayées au plus (un calcul de route chacune)
ADAutonomousFieldExit.ENTRANCE_MAX_DISTANCE = 2000 -- m : comme ExitFieldTask.FIELD_POINT_MAX_DISTANCE

-- ------------------------------------------------------------------------------------------------------------
-- Petits outils
-- ------------------------------------------------------------------------------------------------------------
local function log(fmt, ...)
    if ADAutonomousManager ~= nil and ADAutonomousManager.log ~= nil then
        ADAutonomousManager.log(fmt, ...)
    end
end

local function nameOf(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm ~= nil and sm.getName ~= nil then
        return tostring(sm:getName())
    end
    return "?"
end

-- « G_Broyeur », ou « le point 7319 » sans destination à ce point
local function placeName(wayPointId)
    local marker = ADGraphManager.getMapMarkerByWayPointId ~= nil and ADGraphManager:getMapMarkerByWayPointId(wayPointId) or nil
    if marker ~= nil and marker.name ~= nil then
        return string.format("« %s »", tostring(marker.name))
    end
    return string.format("le point %s", tostring(wayPointId))
end

-- le nom porte ce numéro (« Champ 52 - 53 » porte 52 et 53)
local function hasNumber(name, number)
    if type(name) ~= "string" or tonumber(number) == nil then
        return false
    end
    for n in name:gmatch("%d+") do
        if tonumber(n) == tonumber(number) then
            return true
        end
    end
    return false
end

-- numéro du champ sous le véhicule, nil s'il n'est pas connu
local function fieldNumberAt(x, z)
    if ADAutonomousManager == nil or ADAutonomousManager.fieldAt == nil or ADAutonomousManager.fieldNumber == nil then
        return nil
    end
    return ADAutonomousManager.fieldNumber(ADAutonomousManager.fieldAt(x, z))
end

-- ------------------------------------------------------------------------------------------------------------
-- Entrée du champ
-- ------------------------------------------------------------------------------------------------------------
-- destination du réseau par laquelle sortir du champ où est le véhicule (x, z), vers destinationId :
-- { marker, wp, distance } ; sinon nil et la raison (« sameField », « noEntrance », « noArea »)
function ADAutonomousFieldExit.findEntrance(vehicle, destinationId, x, z)
    if PathFinderModule == nil or PathFinderModule.getConnectedFieldArea == nil or PathFinderModule.isNearFieldArea == nil then
        return nil, "noArea"
    end
    local area = PathFinderModule.getConnectedFieldArea(x, z)
    if area == nil then
        return nil, "noArea"
    end
    local dest = ADGraphManager:getWayPointById(destinationId)
    if dest ~= nil and PathFinderModule.isNearFieldArea(area, dest.x, dest.z) then
        return nil, "sameField"
    end
    local sm = vehicle.ad.stateModule
    local first = sm.getFirstMarker ~= nil and sm:getFirstMarker() or nil
    local fieldNum = fieldNumberAt(x, z)
    local list = {}
    for _, marker in pairs(ADGraphManager:getMapMarkers() or {}) do
        local wp = marker.id ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
        if wp ~= nil and marker.id ~= destinationId then
            local distance = MathUtil.vector2Length(wp.x - x, wp.z - z)
            if distance <= ADAutonomousFieldExit.ENTRANCE_MAX_DISTANCE and PathFinderModule.isNearFieldArea(area, wp.x, wp.z) then
                list[#list + 1] = { marker = marker, wp = wp, distance = distance, first = first ~= nil and first.id == marker.id,
                    named = hasNumber(marker.name, fieldNum) }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.first ~= b.first then
            return a.first
        end
        if a.named ~= b.named then
            return a.named
        end
        if a.distance ~= b.distance then
            return a.distance < b.distance
        end
        return a.marker.id < b.marker.id
    end)
    for i = 1, math.min(#list, ADAutonomousFieldExit.ENTRANCE_TRIES) do
        local c = list[i]
        -- (même condition qu'ExitFieldTask:buildCandidates pour l'entrée : une route d'au moins deux points)
        local route = ADGraphManager:pathFromTo(c.marker.id, destinationId, nil, vehicle)
        if route ~= nil and #route > 1 then
            c.fieldNum = fieldNum
            return c
        end
    end
    return nil, "noEntrance", fieldNum
end

-- ------------------------------------------------------------------------------------------------------------
-- Faut-il sortir par l'entrée ? (enveloppe de setUp)
-- ------------------------------------------------------------------------------------------------------------
-- la sortie à faire pour cette tâche { entrance, destinationId, x, z } ; nil : rien ne change
function ADAutonomousFieldExit.plan(task)
    local vehicle = task.vehicle
    local destinationId = task.destinationID
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or destinationId == nil
        or vehicle.spec_locomotive ~= nil or vehicle.components == nil or vehicle.components[1] == nil then
        return nil
    end
    local sm = vehicle.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS or vehicle.ad.fpHeaderJob ~= nil then
        return nil
    end
    if AutoDrive.getSetting("fpExitField", vehicle) == 2 then
        return nil -- « Le plus proche » : comme AutoDrive
    end
    if ADGraphManager:getWayPointById(destinationId) == nil then
        return nil
    end
    local x, y, z = getWorldTranslation(vehicle.components[1].node)
    if not AutoDrive.checkIsOnField(x, y, z) then
        return nil
    end
    local entrance, why, fieldNum = ADAutonomousFieldExit.findEntrance(vehicle, destinationId, x, z)
    if entrance == nil then
        if why == "noEntrance" then
            log("%s : dans le champ %s, aucune destination du réseau à son bord ne mène à %s : départ habituel, par le point de route devant lui",
                nameOf(vehicle), tostring(fieldNum or "?"), placeName(destinationId))
        end
        return nil
    end
    if entrance.distance <= ADAutonomousFieldExit.ENTRANCE_NEAR then
        return nil -- déjà à l'entrée : la route habituelle part d'elle
    end
    return { entrance = entrance, destinationId = destinationId, x = x, z = z }
end

-- ------------------------------------------------------------------------------------------------------------
-- La sortie : une ExitFieldTask tenue par la tâche (ni ajoutée à la file, ni vue par le mode)
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousFieldExit.start(task, plan)
    local vehicle = task.vehicle
    local entrance = plan.entrance
    local exit = ExitFieldTask:new(vehicle)
    exit.exitEntranceId = entrance.marker.id
    exit.exitDestinationId = plan.destinationId
    -- fin de la sortie : rendue à la tâche, pas au mode (ExitFieldTask:finished finirait la tâche en cours)
    exit.finished = function(t)
        t:finishFieldExit()
        if t.fpOutcome == nil then
            t.fpOutcome = "done"
        end
    end
    -- plus aucun point de sortie : la route habituelle, au lieu de l'arrêt des bennes
    exit.onNoExitCandidate = function(t)
        t:finishFieldExit()
        t.fpOutcome = "none"
        return false
    end
    -- pourquoi : le point d'où la route serait partie
    local okF, frontId = FarmPilotCall(ADGraphManager.findMatchingWayPointForVehicle, ADGraphManager, vehicle)
    local frontWp = okF and frontId ~= nil and frontId ~= -1 and ADGraphManager:getWayPointById(frontId) or nil
    local instead = ""
    if frontWp ~= nil and frontId ~= entrance.marker.id then
        instead = string.format(", pas par le point de route %s devant lui (à %.0f m)", tostring(frontId), MathUtil.vector2Length(frontWp.x - plan.x, frontWp.z - plan.z))
    end
    -- entrée : la destination du champ (1re destination ou nom avec son numéro), sinon une destination à son bord
    local by = (entrance.first or entrance.named) and "par son entrée" or "par la destination à son bord"
    log("%s : sortie du champ %s %s « %s » (point %s, à %.0f m) avant la route vers %s%s", nameOf(vehicle), tostring(entrance.fieldNum or "?"), by,
        tostring(entrance.marker.name), tostring(entrance.marker.id), entrance.distance, placeName(plan.destinationId), instead)
    task.fpFieldExit = { task = exit, plan = plan }
    exit:setUp()
end

-- fin de la sortie : la route vers la destination, du point de sortie (baseSetUp : le setUp d'origine de la tâche)
local function afterExit(task, baseSetUp)
    local fe = task.fpFieldExit
    task.fpFieldExit = nil
    local exit = fe ~= nil and fe.task or nil
    local vehicle = task.vehicle
    if exit ~= nil and exit.fpOutcome == "none" then
        log("%s : pas de trajet propre vers l'entrée du champ ni vers un autre point de sortie : départ habituel vers %s",
            nameOf(vehicle), placeName(task.destinationID))
    elseif exit ~= nil and exit.state == ExitFieldTask.STATE_FINISHED and exit.exitPoint ~= nil and exit.exitPoint.id ~= nil
        and ADGraphManager.setJoinedWayPoint ~= nil then
        ADGraphManager.setJoinedWayPoint(vehicle, exit.exitPoint.id, nil, "sorti du champ par là")
    end
    baseSetUp(task)
end

-- une image de la sortie (à la place de l'update d'origine) ; finie : la route vers la destination
function ADAutonomousFieldExit.update(task, dt, baseSetUp)
    local exit = task.fpFieldExit.task
    if exit.fpOutcome == nil then
        exit:update(dt)
        -- calcul de la sortie tout de suite (l'attente de 6 s d'ExitFieldTask laisse partir la moissonneuse)
        local pf = task.vehicle.ad.pathFinderModule
        if exit.state == ExitFieldTask.STATE_PATHPLANNING and pf ~= nil and pf.delayTime ~= nil and pf.delayTime > 0 then
            pf:addDelayTimer(0)
        end
        -- arrivé au point de sortie : la route part dans la même image
        if exit.fpOutcome == nil and exit.state == ExitFieldTask.STATE_FINISHED then
            exit:finished()
        end
    end
    if exit.fpOutcome ~= nil then
        afterExit(task, baseSetUp)
    end
end

-- tâche arrêtée ou finie pendant la sortie
function ADAutonomousFieldExit.clear(task)
    local fe = task.fpFieldExit
    task.fpFieldExit = nil
    if fe ~= nil and fe.task ~= nil and fe.task.fpOutcome == nil then
        fe.task:abort()
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes des tâches (posées au chargement)
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousFieldExit.wrapTask(class)
    if class == nil or class.fpFieldExitWrapped then
        return
    end
    class.fpFieldExitWrapped = true
    local baseSetUp, baseUpdate, baseAbort, baseFinished = class.setUp, class.update, class.abort, class.finished
    local baseI18n, baseInfo = class.getI18nInfo, class.getInfoText

    class.setUp = function(self, ...)
        if not self.fpFieldExitChecked then
            self.fpFieldExitChecked = true -- une fois par tâche
            local ok, plan = FarmPilotCall(ADAutonomousFieldExit.plan, self)
            if not ok then
                log("ERREUR sortie du champ : %s", tostring(plan))
                plan = nil
            end
            if plan ~= nil then
                local okS, err = FarmPilotCall(ADAutonomousFieldExit.start, self, plan)
                if okS then
                    return
                end
                log("ERREUR sortie du champ : %s", tostring(err))
                ADAutonomousFieldExit.clear(self)
            end
        end
        return baseSetUp(self, ...)
    end

    class.update = function(self, dt, ...)
        if self.fpFieldExit ~= nil then
            local ok, err = FarmPilotCall(ADAutonomousFieldExit.update, self, dt, baseSetUp)
            if not ok then
                log("ERREUR sortie du champ : %s, départ habituel", tostring(err))
                ADAutonomousFieldExit.clear(self)
                baseSetUp(self)
            end
            return
        end
        return baseUpdate(self, dt, ...)
    end

    class.abort = function(self, ...)
        if self.fpFieldExit ~= nil then
            FarmPilotCall(ADAutonomousFieldExit.clear, self)
        end
        return baseAbort(self, ...)
    end

    class.finished = function(self, ...)
        if self.fpFieldExit ~= nil then
            FarmPilotCall(ADAutonomousFieldExit.clear, self)
        end
        return baseFinished(self, ...)
    end

    class.getI18nInfo = function(self, ...)
        local fe = self.fpFieldExit
        if fe ~= nil and fe.task ~= nil then
            return fe.task:getI18nInfo()
        end
        return baseI18n(self, ...)
    end

    class.getInfoText = function(self, ...)
        local fe = self.fpFieldExit
        if fe ~= nil and fe.task ~= nil then
            return fe.task:getInfoText()
        end
        return baseInfo(self, ...)
    end
end

-- tâches qui partent vers une destination du réseau (setPathTo, ou recherche de chemin au-delà de 30 m du réseau)
ADAutonomousFieldExit.wrapTask(DriveToDestinationTask)
ADAutonomousFieldExit.wrapTask(LoadAtDestinationTask)
ADAutonomousFieldExit.wrapTask(UnloadAtDestinationTask)
ADAutonomousFieldExit.wrapTask(RefuelTask)
