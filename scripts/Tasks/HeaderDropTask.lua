-- ============================================================================================================
-- FarmPilot : HeaderDropTask.lua
-- Mode Autonome, moissonneuse équipée seule (ébauche 11/11) : attendre l'autre machine (ADHeaderWaitTask), garer
-- la remorque dans le champ près de la moissonneuse (ADHeaderPlaceTask) et reposer la barre de coupe sur sa
-- remorque porte-barre (ADHeaderDropTask) ; au départ, demi-tour par le réseau quand le côté du cadre de la barre
-- est encombré (ADHeaderTurnTask).
--
-- Règle (11/11) :
-- - Fin de champ : le tracteur entre dans le champ et s'arrête à PLACE_DIST m de la moissonneuse, la remorque
--   tournée pour que la barre y arrive de face (cadre d'attelage côté moissonneuse) ; les endroits essayés autour
--   d'elle sont choisis par Modes/AutonomousHeaderCollect.lua (14/11).
-- - La barre se pose à sa position de transport sur la remorque : la place prévue par la remorque pour ce modèle de
--   barre, sinon son point de blocage général. Avant de la barre = axe Z de ce point.
-- - La moissonneuse se met en face, dans cet axe, APPROACH m avant (recherche de chemin de FarmPilot), puis avance
--   en gardant la barre dans l'axe jusqu'à ce qu'elle soit au-dessus de sa place (STOP_TOL), s'arrête et la dételle
--   sans l'abaisser. La remorque la bloque (jeu : la barre posée et immobile est verrouillée à sa place).
-- - Arrivée trop de côté (MISS_LATERAL) : elle recule dans l'axe et recommence, au plus RETRIES fois.
-- - Pas bloquée après MOUNT_TIMEOUT : échec (la moissonneuse s'arrête, la remorque ne part pas avec une barre libre).
-- - Le résultat (self.result = "ok" ou la raison de l'échec) est lu par Modes/AutonomousHeader.lua.
-- - (17/11) Avant de chercher son chemin, la moissonneuse contrôle la vraie place de la barre et son point d'approche
--   (ADHeaderFlow.approachCheck, Modes/AutonomousHeaderCollect.lua) : hors du champ ou encombré = pas de recherche,
--   « noPath » tout de suite (la remorque va ailleurs).
-- - (17/11) Barre montée : le chemin vers la remorque reste sur le champ, barre comprise (jamais l'herbe ni le chemin
--   du bord, même en strict ; pf.headerOnField, PathFinderModuleField.lua). Champ 5 : la courbe directe vers le point
--   d'approche sortait du champ et menait la moissonneuse dans la haie.
-- - (15/11) Rien ne roule dans une culture : ces recherches de chemin (le tracteur vers la moissonneuse, la
--   moissonneuse vers la remorque) n'utilisent jamais le secours qui traverse la culture (pf.noFallback) ; pas de
--   chemin = endroit suivant ou nouvel essai (Modes/AutonomousHeaderCollect.lua).
--
-- Branché par : Modes/AutonomousHeader.lua (startWait : ADHeaderWaitTask:new ; tractorStage : ADHeaderPlaceTask:new ;
-- startDrop : ADHeaderDropTask:new ; monitor : ADHeaderDropTask.goalFor), Modes/AutonomousHeaderSpot.lua
-- (onArrival : ADHeaderTurnTask:new). Chargé par register.lua après FrontPlaceTask.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Attendre l'autre machine (à l'arrêt) jusqu'à isDone(), au plus timeout ms
-- ------------------------------------------------------------------------------------------------------------
ADHeaderWaitTask = ADInheritsFrom(AbstractTask)

function ADHeaderWaitTask:new(vehicle, isDone, timeout)
    local o = ADHeaderWaitTask:create()
    o.vehicle = vehicle
    o.isDone = isDone
    o.timeout = timeout or math.huge
    o.result = nil
    return o
end

function ADHeaderWaitTask:setUp()
    self.timer = 0
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

function ADHeaderWaitTask:update(dt)
    local sdm = self.vehicle.ad.specialDrivingModule
    -- (15/11) keepMotor : moteur tournant pendant l'attente (moissonneuse qui se fait vider, la goulotte doit marcher)
    if self.keepMotor then
        sdm.motorShouldNotBeStopped = true
    end
    sdm:stopVehicle()
    sdm:update(dt)
    if self.keepMotor then
        sdm.motorShouldNotBeStopped = false
    end
    self.timer = self.timer + dt
    local ok, done = FarmPilotCall(self.isDone)
    if ok and done then
        self:finish("ok")
    elseif self.timer >= self.timeout then
        self:finish("timeout")
    end
end

function ADHeaderWaitTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADHeaderWaitTask:abort()
end

-- textKey : texte de l'ATH pour cette attente (pauses du chauffeur, Modes/AutonomousHeaderHookup.lua)
function ADHeaderWaitTask:getI18nInfo()
    if self.textKey ~= nil then
        return "$l10n_" .. self.textKey .. ";"
    end
    return "$l10n_AD_task_autonomous_headerWait;"
end

-- ------------------------------------------------------------------------------------------------------------
-- Garer la remorque dans le champ, près de la moissonneuse (tracteur)
-- ------------------------------------------------------------------------------------------------------------
ADHeaderPlaceTask = ADInheritsFrom(AbstractTask)

ADHeaderPlaceTask.PLACE_DIST = 40       -- m entre la moissonneuse et l'arrêt du tracteur
ADHeaderPlaceTask.NEAR = 55             -- m : le tracteur est déjà plus près que ça, il reste là
ADHeaderPlaceTask.STOP_TIMEOUT = 8000   -- ms
ADHeaderPlaceTask.DRIVE_TIMEOUT = 180000 -- ms

ADHeaderPlaceTask.STATE_PLAN = 1
ADHeaderPlaceTask.STATE_PLANNING = 2
ADHeaderPlaceTask.STATE_DRIVING = 3
ADHeaderPlaceTask.STATE_STOPPING = 4

-- spots : endroits à essayer dans l'ordre (Modes/AutonomousHeaderCollect.lua : collectSpots) ; sans liste, l'endroit
-- entre la moissonneuse et le tracteur (spotFor)
function ADHeaderPlaceTask:new(vehicle, combine, header, trailer, spots)
    local o = ADHeaderPlaceTask:create()
    o.vehicle = vehicle
    o.combine = combine
    o.header = header
    o.trailer = trailer
    o.spots = spots
    o.spotIndex = 0
    o.result = nil
    return o
end

local function yawOf(x, z)
    return math.atan2(x, z)
end

-- arrêt du tracteur : { x, z, dirX, dirZ } ; nil si déjà assez près
function ADHeaderPlaceTask.spotFor(tractor, combine, header, trailer)
    local tx, _, tz = getWorldTranslation(tractor.components[1].node)
    local cx, _, cz = getWorldTranslation(combine.components[1].node)
    local ux, uz = tx - cx, tz - cz
    local d = MathUtil.vector2Length(ux, uz)
    if d <= ADHeaderPlaceTask.NEAR or d < 0.001 then
        return nil
    end
    ux, uz = ux / d, uz / d
    local pose = ADHeaderFlow.lockPose(trailer, header)
    local fx, _, fz = localDirectionToWorld(trailer.components[1].node, 0, 0, 1)
    -- angle entre la remorque et l'avant de la barre posée : la barre doit regarder vers l'entrée (u), son cadre
    -- vers la moissonneuse
    local delta = pose ~= nil and (yawOf(pose.dirX, pose.dirZ) - yawOf(fx, fz)) or 0
    local a = yawOf(ux, uz) - delta
    return { x = cx + ux * ADHeaderPlaceTask.PLACE_DIST, z = cz + uz * ADHeaderPlaceTask.PLACE_DIST, dirX = math.sin(a), dirZ = math.cos(a) }
end

function ADHeaderPlaceTask:setUp()
    self.state = ADHeaderPlaceTask.STATE_PLAN
    self.timer = 0
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

function ADHeaderPlaceTask:hold(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
end

function ADHeaderPlaceTask:update(dt)
    self.timer = self.timer + dt
    local name = tostring(self.vehicle.ad.stateModule:getName())
    if self.combine == nil or self.combine.isDeleted or self.trailer == nil or self.trailer.isDeleted then
        self:hold(dt)
        self:finish("gone")
        return
    end
    if self.state == ADHeaderPlaceTask.STATE_PLAN then
        self:hold(dt)
        local spot, which
        if self.spots ~= nil then
            self.spotIndex = self.spotIndex + 1
            spot = self.spots[self.spotIndex]
            if spot == nil then
                self:finish("noPath")
                return
            end
            which = string.format(", endroit %d/%d%s", self.spotIndex, #self.spots, spot.narrow and " (juste la largeur de la barre)" or "")
        else
            spot = ADHeaderPlaceTask.spotFor(self.vehicle, self.combine, self.header, self.trailer)
            if spot == nil then
                ADHeaderFlow.log("%s : déjà près de la moissonneuse", name)
                self:finish("ok")
                return
            end
        end
        local pf = self.vehicle.ad.pathFinderModule
        pf:reset()
        -- (15/11) rien ne roule dans une culture : jamais le secours qui la traverse, pas de chemin = endroit suivant
        pf.noFallback = true
        -- (15/11) règles de base : culture des champs voisins et îlots oubliés ignorés (PathFinderModuleEntrance.lua)
        pf.cropCombine = self.combine
        pf:startPathPlanningTo({ x = spot.x, y = 0, z = spot.z }, { x = spot.dirX, z = spot.dirZ })
        -- quiet (essais répétés toutes les minutes) : écrit seulement quand un chemin est trouvé
        -- label : autre trajet que l'entrée dans le champ (place hors de la route, AutonomousHeaderYard.lua)
        self.spotText = string.format("%s : %s (%.0f, %.0f)%s", name, self.label or "entre dans le champ vers la moissonneuse", spot.x, spot.z, which or "")
        if not self.quiet then
            ADHeaderFlow.log("%s", self.spotText)
        end
        self.state = ADHeaderPlaceTask.STATE_PLANNING
        self.timer = 0
    elseif self.state == ADHeaderPlaceTask.STATE_PLANNING then
        local pf = self.vehicle.ad.pathFinderModule
        if pf:hasFinished() then
            local path = pf:getPath()
            if path == nil or #path == 0 then
                if self.spots ~= nil and self.spotIndex < #self.spots then
                    -- pas de chemin jusqu'à cet endroit : le suivant
                    if not self.quiet then
                        ADHeaderFlow.log("%s : pas de chemin jusqu'à cet endroit, endroit suivant", name)
                    end
                    self:hold(dt)
                    self.state = ADHeaderPlaceTask.STATE_PLAN
                    self.timer = 0
                    return
                end
                self:finish("noPath")
                return
            end
            if self.quiet and self.spotText ~= nil then
                ADHeaderFlow.log("%s", self.spotText)
            end
            self.vehicle.ad.drivePathModule:setWayPoints(path)
            self.state = ADHeaderPlaceTask.STATE_DRIVING
            self.timer = 0
        else
            pf:update(dt)
            self:hold(dt)
        end
    elseif self.state == ADHeaderPlaceTask.STATE_DRIVING then
        local dpm = self.vehicle.ad.drivePathModule
        if dpm:isTargetReached() then
            self.state = ADHeaderPlaceTask.STATE_STOPPING
            self.timer = 0
        elseif self.timer > ADHeaderPlaceTask.DRIVE_TIMEOUT then
            self:hold(dt)
            self:finish("timeout")
        else
            dpm:update(dt)
        end
    else
        self:hold(dt)
        if math.abs(self.vehicle.lastSpeedReal or 0) < 0.0015 or self.timer > ADHeaderPlaceTask.STOP_TIMEOUT then
            self:finish("ok")
        end
    end
end

function ADHeaderPlaceTask:finish(result)
    if self.result ~= nil then
        return
    end
    local pf = self.vehicle.ad ~= nil and self.vehicle.ad.pathFinderModule or nil
    if pf ~= nil then
        pf.cropCombine = nil
    end
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADHeaderPlaceTask:abort()
end

function ADHeaderPlaceTask:getI18nInfo()
    if self.state == ADHeaderPlaceTask.STATE_PLANNING then
        return self:getPlanningI18n()
    end
    return self.i18n or "$l10n_AD_task_autonomous_headerPlace;"
end

-- ------------------------------------------------------------------------------------------------------------
-- Demi-tour par le réseau jusqu'à un point parcouru dans l'autre sens (tracteur, départ ; AutonomousHeaderSpot.lua)
-- ------------------------------------------------------------------------------------------------------------
ADHeaderTurnTask = ADInheritsFrom(AbstractTask)

ADHeaderTurnTask.TIMEOUT = 300000       -- ms

function ADHeaderTurnTask:new(vehicle, wayPointId, timeout)
    local o = ADHeaderTurnTask:create()
    o.vehicle = vehicle
    o.wayPointId = wayPointId
    o.timeout = math.max(ADHeaderTurnTask.TIMEOUT, timeout or 0) -- route longue : le temps de la faire
    o.result = nil
    return o
end

function ADHeaderTurnTask:setUp()
    self.timer = 0
    self.vehicle.ad.drivePathModule:setPathTo(self.wayPointId)
end

function ADHeaderTurnTask:update(dt)
    self.timer = self.timer + dt
    local dpm = self.vehicle.ad.drivePathModule
    if self.vehicle.ad.isStoppingWithError then
        self:finish("noPath")
    elseif dpm:isTargetReached() then
        self:finish("ok")
    elseif self.timer > (self.timeout or ADHeaderTurnTask.TIMEOUT) then
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self:finish("timeout")
    else
        dpm:update(dt)
    end
end

function ADHeaderTurnTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADHeaderTurnTask:abort()
end

function ADHeaderTurnTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_headerTurn;"
end

-- ------------------------------------------------------------------------------------------------------------
-- Reposer la barre sur la remorque : réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderDropTask = ADInheritsFrom(AbstractTask)

ADHeaderDropTask.STATE_PLAN = 1
ADHeaderDropTask.STATE_PLANNING = 2
ADHeaderDropTask.STATE_DRIVING = 3
ADHeaderDropTask.STATE_STOPPING = 4
ADHeaderDropTask.STATE_ALIGN = 5
ADHeaderDropTask.STATE_BACK = 6
ADHeaderDropTask.STATE_SETTLE = 7
ADHeaderDropTask.STATE_MOUNT = 8

ADHeaderDropTask.APPROACH = 14          -- m : la barre part de là devant sa place, dans son axe
ADHeaderDropTask.READY_LATERAL = 1.2    -- m d'écart à l'axe accepté pour avancer tout de suite
ADHeaderDropTask.READY_ANGLE = 12       -- ° d'écart à l'axe accepté pour avancer tout de suite
ADHeaderDropTask.READY_MAX = 40         -- m avant la place au plus pour avancer tout de suite
ADHeaderDropTask.LOOK_AHEAD = 4         -- m : la moissonneuse vise un point de l'axe, à ça devant la barre
ADHeaderDropTask.STOP_TOL = 0.15        -- m : la barre est au-dessus de sa place
ADHeaderDropTask.MISS_LATERAL = 0.8     -- m de côté à moins de 2 m de la place = raté
ADHeaderDropTask.RETRIES = 2
ADHeaderDropTask.BACK_SPEED = 4         -- km/h en reculant pour un nouvel essai
ADHeaderDropTask.ALIGN_TIMEOUT = 90000  -- ms
ADHeaderDropTask.BACK_TIMEOUT = 30000   -- ms
ADHeaderDropTask.STOP_TIMEOUT = 8000    -- ms
ADHeaderDropTask.SETTLE_TIME = 1500     -- ms à l'arrêt avant de dételer
ADHeaderDropTask.MOUNT_FORCE_TIME = 5000 -- ms : barre posée mais pas encore bloquée, on demande au jeu de la bloquer
ADHeaderDropTask.MOUNT_TIMEOUT = 15000  -- ms

-- ------------------------------------------------------------------------------------------------------------
-- Création, géométrie
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderDropTask:new(vehicle, header, trailer)
    local o = ADHeaderDropTask:create()
    o.vehicle = vehicle
    o.header = header
    o.trailer = trailer
    o.result = nil
    return o
end

-- place de la barre et position voulue de la moissonneuse : { x, z (moissonneuse), dirX, dirZ, ahead (m entre la
-- moissonneuse et la barre), pose (ADHeaderFlow.lockPose) } ; nil si la remorque n'a pas de place
function ADHeaderDropTask.goalFor(vehicle, header, trailer)
    local pose = ADHeaderFlow.lockPose(trailer, header)
    if pose == nil or header == nil then
        return nil
    end
    local vNode = vehicle.components[1].node
    local cx, _, cz = getWorldTranslation(vNode)
    local hx, _, hz = getWorldTranslation(header.components[1].node)
    local fx, _, fz = localDirectionToWorld(vNode, 0, 0, 1)
    local ahead = (hx - cx) * fx + (hz - cz) * fz
    return { x = pose.x - pose.dirX * ahead, z = pose.z - pose.dirZ * ahead, dirX = pose.dirX, dirZ = pose.dirZ,
        ahead = ahead, pose = pose }
end

-- (17/11) emprise de la barre pour la recherche de chemin : demi-largeur, distance de l'avant de la barre au véhicule
ADHeaderDropTask.HEADER_DEFAULT_WIDTH = 9 -- m si la barre n'a pas de taille connue
function ADHeaderDropTask.headerFootprint(header, goal)
    local size = header ~= nil and header.size or nil
    local width = size ~= nil and tonumber(size.width) or nil
    if width == nil or width <= 0 then
        width = ADHeaderDropTask.HEADER_DEFAULT_WIDTH
    end
    local length = size ~= nil and tonumber(size.length) or 2
    return { half = width / 2, ahead = math.max(0, (goal ~= nil and goal.ahead or 6)) + length / 2 }
end

-- barre par rapport à sa place : le long de l'axe (< 0 : pas encore arrivée), de côté, écart d'angle (°)
function ADHeaderDropTask:headerError(pose)
    local hx, _, hz = getWorldTranslation(self.header.components[1].node)
    local ox, oz = hx - pose.x, hz - pose.z
    local along = ox * pose.dirX + oz * pose.dirZ
    local side = ox * pose.dirZ - oz * pose.dirX
    local fx, _, fz = localDirectionToWorld(self.vehicle.components[1].node, 0, 0, 1)
    local len = MathUtil.vector2Length(fx, fz)
    local cosA = len > 0.001 and (fx * pose.dirX + fz * pose.dirZ) / len or -1
    return along, side, math.deg(math.acos(math.max(-1, math.min(1, cosA))))
end

function ADHeaderDropTask:isReady(goal)
    local along, side, angle = self:headerError(goal.pose)
    return along < -1 and along >= -ADHeaderDropTask.READY_MAX and math.abs(side) <= ADHeaderDropTask.READY_LATERAL
        and angle <= ADHeaderDropTask.READY_ANGLE
end

function ADHeaderDropTask:holdVehicle(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
end

function ADHeaderDropTask:setState(state)
    self.state = state
    self.timer = 0
end

function ADHeaderDropTask:setUp()
    self.retries = 0
    self:setState(ADHeaderDropTask.STATE_PLAN)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

-- ------------------------------------------------------------------------------------------------------------
-- À chaque image (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderDropTask:update(dt)
    self.timer = self.timer + dt
    local name = tostring(self.vehicle.ad.stateModule:getName())
    if self.header == nil or self.header.isDeleted or self.trailer == nil or self.trailer.isDeleted then
        self:holdVehicle(dt)
        self:finish("gone")
        return
    end
    local attached = self.header.getAttacherVehicle ~= nil and self.header:getAttacherVehicle() == self.vehicle
    if not attached and self.state ~= ADHeaderDropTask.STATE_MOUNT then
        self:holdVehicle(dt)
        self:finish("notAttached")
        return
    end
    local goal = ADHeaderDropTask.goalFor(self.vehicle, self.header, self.trailer)
    if goal == nil then
        self:holdVehicle(dt)
        self:finish("noPlace")
        return
    end

    if self.state == ADHeaderDropTask.STATE_PLAN then
        self:holdVehicle(dt)
        if self:isReady(goal) then
            ADHeaderFlow.log("%s : déjà dans l'axe de la place, avance", name)
            self:setState(ADHeaderDropTask.STATE_STOPPING)
            return
        end
        local start = { x = goal.x - goal.dirX * ADHeaderDropTask.APPROACH, y = goal.pose.y, z = goal.z - goal.dirZ * ADHeaderDropTask.APPROACH }
        -- (17/11) point d'approche dans la haie : pas de recherche de chemin (4 grilles, lag), la remorque va ailleurs
        if ADHeaderFlow.approachCheck ~= nil then
            local ok, why = ADHeaderFlow.withCombineCropRules(self.vehicle, self.vehicle, ADHeaderFlow.approachCheck, self.vehicle, self.header, self.trailer, start)
            if not ok then
                ADHeaderFlow.log("%s : chemin vers la remorque pas cherché, place %s (%.0f, %.0f) : %s", name, goal.pose.exact and "prévue" or "générale",
                    start.x, start.z, tostring(why))
                self:finish("noPath")
                return
            end
        end
        local pf = self.vehicle.ad.pathFinderModule
        pf:reset()
        -- (15/11) rien ne roule dans une culture : jamais le secours qui la traverse, pas de chemin = la remorque va
        -- ailleurs (AutonomousHeaderCollect.lua : collectDropFailed)
        pf.noFallback = true
        -- (17/11) barre montée : le trajet reste sur le champ, barre comprise (pas l'herbe ni le chemin du bord, même
        -- en strict), voir PathFinderModuleField.lua (isHeaderOffField)
        pf.headerOnField = ADHeaderDropTask.headerFootprint(self.header, goal)
        pf:startPathPlanningTo(start, { x = goal.dirX, z = goal.dirZ })
        ADHeaderFlow.log("%s : chemin vers la remorque, place %s (%.0f, %.0f), gardé dans le champ avec la barre (%.1f m de large, avant à %.1f m)", name,
            goal.pose.exact and "prévue" or "générale", start.x, start.z, pf.headerOnField.half * 2, pf.headerOnField.ahead)
        self:setState(ADHeaderDropTask.STATE_PLANNING)
    elseif self.state == ADHeaderDropTask.STATE_PLANNING then
        local pf = self.vehicle.ad.pathFinderModule
        if pf:hasFinished() then
            local path = pf:getPath()
            if path == nil or #path == 0 then
                ADHeaderFlow.log("%s : pas de chemin vers la remorque en gardant la barre dans le champ (%d case(s) refusées pour la barre)", name, pf.headerRefusals or 0)
                self:finish("noPath")
                return
            end
            self.vehicle.ad.drivePathModule:setWayPoints(path)
            self:setState(ADHeaderDropTask.STATE_DRIVING)
        else
            pf:update(dt)
            self:holdVehicle(dt)
        end
    elseif self.state == ADHeaderDropTask.STATE_DRIVING then
        local dpm = self.vehicle.ad.drivePathModule
        if dpm:isTargetReached() then
            self:setState(ADHeaderDropTask.STATE_STOPPING)
        else
            dpm:update(dt)
        end
    elseif self.state == ADHeaderDropTask.STATE_STOPPING then
        self:holdVehicle(dt)
        if math.abs(self.vehicle.lastSpeedReal or 0) < 0.0015 or self.timer > ADHeaderDropTask.STOP_TIMEOUT then
            self:setState(ADHeaderDropTask.STATE_ALIGN)
        end
    elseif self.state == ADHeaderDropTask.STATE_ALIGN then
        self:updateAlign(dt, goal, name)
    elseif self.state == ADHeaderDropTask.STATE_BACK then
        self:updateBack(dt, goal)
    elseif self.state == ADHeaderDropTask.STATE_SETTLE then
        self:holdVehicle(dt)
        if math.abs(self.vehicle.lastSpeedReal or 0) < 0.0015 and self.timer >= ADHeaderDropTask.SETTLE_TIME then
            if self:detach(name) then
                self:setState(ADHeaderDropTask.STATE_MOUNT)
            else
                self:finish("notAllowed")
            end
        end
    elseif self.state == ADHeaderDropTask.STATE_MOUNT then
        self:holdVehicle(dt)
        if ADHeaderFlow.isMounted(self.trailer, self.header) then
            ADHeaderFlow.log("%s : barre bloquée sur la remorque", name)
            self:finish("ok")
        elseif self.timer >= ADHeaderDropTask.MOUNT_FORCE_TIME and not self.forced and self.trailer.forceDynamicMountPendingObjects ~= nil then
            self.forced = true
            FarmPilotCall(self.trailer.forceDynamicMountPendingObjects, self.trailer, false)
        elseif self.timer >= ADHeaderDropTask.MOUNT_TIMEOUT then
            self:finish("notMounted")
        end
    end
end

-- marche avant dans l'axe de la place, la barre visant sa place
function ADHeaderDropTask:updateAlign(dt, goal, name)
    local pose = goal.pose
    local along, side, angle = self:headerError(pose)
    if along >= -ADHeaderDropTask.STOP_TOL then
        self:holdVehicle(dt)
        if math.abs(side) > ADHeaderDropTask.MISS_LATERAL then
            self:miss(along, side, name)
            return
        end
        ADHeaderFlow.log("%s : barre au-dessus de sa place (écart %.2f m, de côté %.2f m, %.1f°)", name, along, side, angle)
        self:setState(ADHeaderDropTask.STATE_SETTLE)
        return
    end
    if along > -2 and math.abs(side) > ADHeaderDropTask.MISS_LATERAL then
        self:holdVehicle(dt)
        self:miss(along, side, name)
        return
    end
    if self.timer > ADHeaderDropTask.ALIGN_TIMEOUT then
        self:holdVehicle(dt)
        self:finish("timeout")
        return
    end
    -- point de l'axe LOOK_AHEAD m devant la barre (projetée sur l'axe)
    local aim = along + ADHeaderDropTask.LOOK_AHEAD
    local target = { x = pose.x + pose.dirX * aim, y = pose.y, z = pose.z + pose.dirZ * aim }
    local speed = math.min(5, math.max(1, -along * 0.6))
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, target, 1, false, 0.6, speed, true)
end

function ADHeaderDropTask:miss(along, side, name)
    if self.retries < ADHeaderDropTask.RETRIES then
        self.retries = self.retries + 1
        ADHeaderFlow.log("%s : barre trop de côté (%.2f m), recule et recommence (%d/%d)", name, side, self.retries, ADHeaderDropTask.RETRIES)
        self:setState(ADHeaderDropTask.STATE_BACK)
        return
    end
    ADHeaderFlow.log("%s : barre trop de côté (%.2f m, le long %.2f m), abandon", name, side, along)
    self:finish("missed")
end

-- nouvel essai : marche arrière tout droit jusqu'à APPROACH m de la place
function ADHeaderDropTask:updateBack(dt, goal)
    local along = self:headerError(goal.pose)
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm.reverseNode = sdm:getReverseNode()
    if along <= -ADHeaderDropTask.APPROACH or self.timer > ADHeaderDropTask.BACK_TIMEOUT or sdm.reverseNode == nil
        or self.vehicle.ad.collisionDetectionModule:checkReverseCollision() == true then
        self:setState(ADHeaderDropTask.STATE_STOPPING)
        return
    end
    local tx, ty, tz = AutoDrive.localToWorld(self.vehicle, 0, 0, -100)
    sdm.reverseTarget = { x = tx, y = ty, z = tz }
    sdm.currentWayPointIndex = 0
    sdm.wayPoints = {}
    sdm:getBasicStates()
    sdm:reverseToPoint(dt, ADHeaderDropTask.BACK_SPEED)
end

-- barre coupée et dételée sans l'abaisser (elle tombe sur la remorque) ; mod d'attelage manuel : débranchée d'abord
function ADHeaderDropTask:detach(name)
    local header = self.header
    if header.getIsTurnedOn ~= nil and header:getIsTurnedOn() and header.setIsTurnedOn ~= nil then
        header:setIsTurnedOn(false)
    end
    local attacher = header:getAttacherVehicle()
    if attacher == nil then
        return true
    end
    local okM, done = FarmPilotCall(ADAutonomousManager.setManualConnections, attacher, header, false)
    if okM and type(done) == "table" and #done > 0 then
        ADHeaderFlow.log("%s : débranché (%s)", name, table.concat(done, ", "))
    end
    if header.isDetachAllowed ~= nil and not header:isDetachAllowed() then
        ADHeaderFlow.log("%s : le jeu refuse de dételer la barre", name)
        return false
    end
    local ok, err = FarmPilotCall(attacher.detachImplementByObject, attacher, header)
    if not ok then
        ADHeaderFlow.log("ERREUR dételage de la barre : %s", tostring(err))
        return false
    end
    ADHeaderFlow.log("%s : barre dételée au-dessus de la remorque", name)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin de la tâche, collisions, texte du HUD
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderDropTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADHeaderDropTask:abort()
end

-- la remorque, son tracteur et la barre ne sont pas des obstacles
function ADHeaderDropTask:getExcludedVehiclesForCollisionCheck()
    local out = { self.header, self.trailer }
    local attacher = self.trailer ~= nil and self.trailer.getAttacherVehicle ~= nil and self.trailer:getAttacherVehicle() or nil
    if attacher ~= nil then
        out[#out + 1] = attacher.getRootVehicle ~= nil and attacher:getRootVehicle() or attacher
    end
    return out
end

function ADHeaderDropTask:getI18nInfo()
    if self.state == ADHeaderDropTask.STATE_PLANNING then
        return self:getPlanningI18n()
    end
    return "$l10n_AD_task_autonomous_headerDrop;"
end
