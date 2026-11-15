-- ============================================================================================================
-- FarmPilot : AutonomousHeaderEntry.lua
-- Mode Autonome, moissonneuse équipée seule : après avoir pris sa barre, la moissonneuse ne prend plus la route là
-- où la barre ne passe pas. Elle avance droit jusqu'au champ quand il est devant elle, et un endroit d'où il
-- faudrait prendre une route trop étroite n'est plus choisi pour la remorque.
--
-- Règle (13/11, comme sur un vrai chantier : la barre se prend au bord du champ et ne roule pas montée) :
-- - Entrée directe : barre prise, le champ à récolter (celui du marqueur de destination) est à moins de
--   ENTRY_RANGE m droit devant la barre, et le couloir jusqu'au champ est praticable sur la largeur de la barre plus
--   ENTRY_MARGIN de chaque côté (pas d'eau, pas de fossé ni de talus, pas de culture d'un autre champ, pas
--   d'obstacle) : elle recule juste de la profondeur de la barre plus ENTRY_BACKOFF m, attend que la remorque soit
--   partie, puis avance tout droit jusqu'au bord du champ (Tasks/HeaderEnterTask.lua). Le travail est lancé là,
--   sans trajet par le réseau.
-- - Elle s'arrête quand l'avant de la barre est ENTRY_INSIDE m dans le champ : la coupe commence au bord, les roues
--   ne roulent pas dans la culture debout avant que la barre tourne. Barre déjà au-dessus du champ : elle ne bouge
--   pas, le travail est lancé d'où elle est.
-- - Le couloir est contrôlé deux fois : de loin, au choix de l'endroit (obstacles fixes seulement : la remorque
--   n'y est pas encore) ; puis d'où elle est vraiment, juste avant d'avancer (tout compte, la remorque aussi).
--   Plus praticable à ce moment-là : elle fait la sortie habituelle d'un attelage à l'avant (le reste du recul, la
--   courbe vers la route) et y va par le réseau, comme avant.
-- - Route avec la barre : barre de plus de ROAD_MIN_WIDTH m (largeur maximale d'un convoi agricole : au-delà, une
--   barre ne roule jamais montée). Un endroit d'où il n'y a pas d'entrée directe n'est gardé que si la route du
--   réseau jusqu'au champ est libre sur la largeur de la barre plus ROAD_MARGIN de chaque côté (arbres, bâtiments,
--   clôtures ; les véhicules ne comptent pas), contrôlée tous les ROAD_STEP m jusqu'au champ. Sinon l'endroit est
--   écarté, comme un côté encombré.
-- - Barre plus étroite, ou marqueur sans numéro de champ : rien ne change.
-- - (15/11) Départ au champ suivant avec une barre prise sur une remorque : même contrôle (entrée directe ou route
--   assez large, headerTravelOk) ; sinon la barre est reposée sur sa remorque et le tracteur la ré-amène
--   (AutonomousHeader.lua, onStart). Jamais de départ par le réseau avec une barre de plus de ROAD_MIN_WIDTH m sans
--   ce contrôle.
-- - Réglages ENTRY = false et ROAD_CHECK = false : comme avant.
--
-- Branché par : Modes/AutonomousHeaderSpot.lua (findRouteStop, findSpot : afterPickupOk), Modes/AutonomousMode.lua
-- (departToField, enveloppé ici), Modes/AutonomousHeaderClear.lua (startClearWait, enveloppé ici),
-- Modes/AutonomousFront.lua (afterFetch, enveloppé ici). Chargé par register.lua après AutonomousHeaderGround.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.ENTRY = true           -- la moissonneuse entre droit dans le champ après avoir pris sa barre
ADHeaderFlow.ENTRY_RANGE = 25       -- m devant la barre au plus jusqu'au champ à récolter
ADHeaderFlow.ENTRY_BACK = 10        -- m en plus quand le couloir part de la moissonneuse (elle a reculé)
ADHeaderFlow.ENTRY_INSIDE = 2       -- m : l'avant de la barre s'arrête à cette distance dans le champ (les roues restent dehors)
ADHeaderFlow.ENTRY_MARGIN = 0.7     -- m de chaque côté de la barre
ADHeaderFlow.ENTRY_STEP = 2         -- m entre deux points du sol contrôlés
ADHeaderFlow.ENTRY_BACKOFF = 2      -- m de recul après l'attelage, en plus de la profondeur de la barre
ADHeaderFlow.ROAD_CHECK = true      -- jamais de route avec la barre là où elle ne passe pas
ADHeaderFlow.ROAD_MIN_WIDTH = 4.5   -- m : une barre moins large que ça passe où passe la moissonneuse
ADHeaderFlow.ROAD_MARGIN = 0.5      -- m de chaque côté de la barre
ADHeaderFlow.ROAD_STEP = 5          -- m entre deux contrôles le long de la route
ADHeaderFlow.ROAD_BOX_Y = 1.9       -- m au-dessus du sol : milieu de la boîte contrôlée (barre relevée)
ADHeaderFlow.ROAD_BOX_HALF = 1.1    -- m : demi-hauteur de la boîte
ADHeaderFlow.ROAD_SKIPS = 8          -- endroits plus loin écartés au plus par recherche (une route calculée pour chacun)

local log = ADHeaderFlow.log

local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function unit(x, z)
    local l = math.sqrt(x * x + z * z)
    if l < 0.0001 then
        return nil
    end
    return x / l, z / l
end

local function groundY(x, z)
    if getTerrainHeightAtWorldPos ~= nil and g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
    end
    return 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Champ à récolter
-- ------------------------------------------------------------------------------------------------------------
-- numéros de champ écrits dans le nom du marqueur de destination de la moissonneuse ; nil : aucun
local function wanted(job)
    if job.fieldNumbers == nil then
        local ok, list = FarmPilotCall(ADAutonomousManager.markerFieldNumbers, job.combine)
        job.fieldNumbers = ok and list or false
    end
    return job.fieldNumbers or nil
end

-- (x, z) est dans le champ à récolter : sur de la terre de champ (pas la bande d'herbe ni le chemin de la même
-- parcelle), et le champ porte un des numéros du marqueur
function ADHeaderFlow.isTargetField(job, x, z)
    local list = wanted(job)
    if list == nil then
        return false
    end
    if AutoDrive.checkIsOnField ~= nil and not AutoDrive.checkIsOnField(x, groundY(x, z), z) then
        return false
    end
    local f = ADAutonomousManager.fieldAt(x, z)
    if f == nil then
        return false
    end
    local num = tonumber(ADAutonomousManager.fieldNumber(f))
    for _, n in ipairs(list) do
        if num == n then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Obstacles
-- ------------------------------------------------------------------------------------------------------------
-- boîte (centre, cap, demi-largeur, demi-hauteur, demi-longueur) : quelque chose dedans ? full = tout compte
-- (véhicules aussi, sauf l'attelage de t) ; sinon les obstacles fixes seulement
local function boxHit(t, x, y, z, ry, halfW, halfY, halfL, full)
    local yield = t ~= nil and t.ad ~= nil and t.ad.trafficYieldModule or nil
    if yield == nil then
        return false
    end
    if not full and yield.overlapHitStatic ~= nil then
        return yield:overlapHitStatic(x, y, z, ry, halfW, halfY, halfL), yield.overlapHitName
    end
    if yield.overlapHit ~= nil then
        return yield:overlapHit(x, y, z, ry, halfW, halfY, halfL), yield.overlapHitName
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Couloir tout droit jusqu'au champ
-- ------------------------------------------------------------------------------------------------------------
-- de (x, z) dans le sens (dx, dz) : { x, z, dx, dz, reach (m jusqu'au champ), length (m à faire, 0 = la barre y est
-- déjà) } ; nil, raison. front : m entre (x, z) et l'avant de la barre (le sol n'est contrôlé qu'à partir de là) ;
-- range : m au plus de la barre au champ ; extra : m en plus de chaque côté (couloir prévu de loin) ; full : voir
-- boxHit
function ADHeaderFlow.entryCorridor(t, job, header, x, z, dx, dz, front, range, extra, full)
    local _, span = ADHeaderFlow.headerBox(header)
    local halfW = span / 2 + ADHeaderFlow.ENTRY_MARGIN + (extra or 0)
    local reach = nil
    local a = 0
    while a <= front + range do
        if ADHeaderFlow.isTargetField(job, x + dx * a, z + dz * a) then
            reach = a
            break
        end
        a = a + 1
    end
    if reach == nil then
        return nil, "pas de champ à récolter droit devant"
    end
    -- m à faire : jusqu'à ce que l'avant de la barre soit ENTRY_INSIDE m dans le champ
    local length = math.max(0, reach - front + ADHeaderFlow.ENTRY_INSIDE)
    if length == 0 then
        return { x = x, z = z, dx = dx, dz = dz, reach = reach, length = 0 } -- la barre est déjà au-dessus du champ
    end
    local from, to = front, front + length
    -- sol : pas d'eau, pas de marche, pas de culture d'un autre champ
    local step = ADHeaderFlow.ENTRY_STEP
    local previousRow = nil
    local along = from
    while along <= to + 0.001 do
        local row = {}
        local i = 0
        local across = -halfW
        while across <= halfW + 0.001 do
            i = i + 1
            local px, pz = x + dx * along - dz * across, z + dz * along + dx * across
            local h = groundY(px, pz)
            if ADHeaderFlow.isWater ~= nil and ADHeaderFlow.isWater(px, pz, h) then
                return nil, "eau"
            end
            if (row[i - 1] ~= nil and math.abs(h - row[i - 1]) > ADHeaderFlow.MAX_STEP_RISE)
                or (previousRow ~= nil and previousRow[i] ~= nil and math.abs(h - previousRow[i]) > ADHeaderFlow.MAX_STEP_RISE) then
                return nil, "fossé ou talus"
            end
            if ADFieldPark ~= nil and ADFieldPark.hasGrowingCrop ~= nil and ADFieldPark.hasGrowingCrop(px, pz)
                and not ADHeaderFlow.isTargetField(job, px, pz) then
                return nil, "culture d'un autre champ"
            end
            row[i] = h
            across = across + step
        end
        previousRow = row
        along = along + step
    end
    -- obstacles : une boîte sur tout le couloir
    local mid = (from + to) / 2
    local cx, cz = x + dx * mid, z + dz * mid
    local hit, name = boxHit(t, cx, groundY(cx, cz) + 1.8, cz, MathUtil.getYRotationFromDirection(dx, dz), halfW, 1.5,
        math.max((to - from) / 2, 0.5), full)
    if hit then
        return nil, string.format("obstacle (%s)", tostring(name or "?"))
    end
    return { x = x, z = z, dx = dx, dz = dz, reach = reach, length = length }
end

-- couloir d'où est la moissonneuse, barre attelée ; full : voir boxHit
function ADHeaderFlow.entryFromVehicle(v, job, header, full)
    local root = v.components[1].node
    local x, _, z = getWorldTranslation(root)
    local fx, _, fz = localDirectionToWorld(root, 0, 0, 1)
    local dx, dz = unit(fx, fz)
    if dx == nil then
        return nil, "cap inconnu"
    end
    local depth = ADHeaderFlow.headerBox(header)
    local front = ((v.size ~= nil and v.size.length) or ADHeaderFlow.DEFAULT_COMBINE_LENGTH) / 2 + depth
    return ADHeaderFlow.entryCorridor(v, job, header, x, z, dx, dz, front, ADHeaderFlow.ENTRY_RANGE + ADHeaderFlow.ENTRY_BACK, 0, full)
end

-- ------------------------------------------------------------------------------------------------------------
-- Route avec la barre
-- ------------------------------------------------------------------------------------------------------------
-- la barre passe sur la route points[from..to] jusqu'au champ ? true ; false, x, z, nom de l'obstacle
function ADHeaderFlow.roadFits(t, job, points, from, to)
    local _, span = ADHeaderFlow.headerBox(job.header)
    local halfW = span / 2 + ADHeaderFlow.ROAD_MARGIN
    local step = ADHeaderFlow.ROAD_STEP
    local s = 0
    for i = from, to - 1 do
        local a, b = points[i], points[i + 1]
        local len = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        local dx, dz = unit(b.x - a.x, b.z - a.z)
        if dx ~= nil then
            local ry = MathUtil.getYRotationFromDirection(dx, dz)
            while s <= len do
                local x, z = a.x + dx * s, a.z + dz * s
                if ADHeaderFlow.isTargetField(job, x, z) then
                    return true -- la suite est dans le champ
                end
                local hit, name = boxHit(t, x, groundY(x, z) + ADHeaderFlow.ROAD_BOX_Y, z, ry, halfW, ADHeaderFlow.ROAD_BOX_HALF, step / 2, false)
                if hit then
                    return false, x, z, name
                end
                s = s + step
            end
            s = s - len
        end
    end
    return true
end

-- un endroit pour la remorque (pose : place prévue de la barre) : une fois la barre prise, la moissonneuse peut
-- rejoindre le champ ? true ; false, raison, true si c'est la route qui ne passe pas. points, from : la route du
-- tracteur et le point où il s'arrêterait (la suite est la route jusqu'au champ) ; sinon startId : point du réseau
-- de l'endroit. back : m de route remontés avant ce point (la remorque est derrière le tracteur). extra : voir
-- entryCorridor. blocked : la suite de la route est déjà connue trop étroite (la raison) : pas contrôlée de nouveau
function ADHeaderFlow.afterPickupOk(t, job, pose, points, from, back, extra, startId, blocked)
    if not ADHeaderFlow.ROAD_CHECK or job == nil or job.phase ~= "deliver" or job.header == nil or job.combine == nil then
        return true
    end
    local _, span = ADHeaderFlow.headerBox(job.header)
    if span <= ADHeaderFlow.ROAD_MIN_WIDTH or wanted(job) == nil then
        return true
    end
    if ADHeaderFlow.ENTRY and pose ~= nil and pose.dirX ~= nil then
        local plan = ADHeaderFlow.entryCorridor(t, job, job.header, pose.x, pose.z, pose.dirX, pose.dirZ, 0, ADHeaderFlow.ENTRY_RANGE, extra, false)
        if plan ~= nil then
            return true, "entrée directe"
        end
    end
    if blocked ~= nil then
        return false, blocked, true
    end
    if points == nil then
        local sm = job.combine.ad ~= nil and job.combine.ad.stateModule or nil
        local marker = sm ~= nil and sm:getFirstMarker() or nil
        if marker == nil or startId == nil then
            return true
        end
        points = ADGraphManager:pathFromTo(startId, marker.id)
        from = 1
    else
        -- la remorque est derrière le point d'arrêt du tracteur : la route de la barre commence là
        local left = back or 0
        while from > 1 and left > 0 do
            left = left - MathUtil.vector2Length(points[from].x - points[from - 1].x, points[from].z - points[from - 1].z)
            from = from - 1
        end
    end
    if points == nil or #points < 2 then
        return true
    end
    local fits, x, z, name = ADHeaderFlow.roadFits(t, job, points, from, #points)
    if fits then
        return true
    end
    return false, string.format("route trop étroite pour la barre : %s en (%.0f, %.0f)", tostring(name or "obstacle"), x, z), true
end

-- ------------------------------------------------------------------------------------------------------------
-- (15/11) Départ au champ suivant, barre attelée
-- ------------------------------------------------------------------------------------------------------------
-- la moissonneuse peut aller au champ de son marqueur de destination avec la barre attelée ? true, raison ; false,
-- raison. Barre de ROAD_MIN_WIDTH m ou moins, contrôle coupé ou marqueur sans numéro de champ : true (comme avant).
-- Sinon : entrée directe d'où elle est, ou route du réseau (depuis son point le plus proche) assez large jusqu'au
-- champ (roadFits). Utilisé par AutonomousHeader.lua (onStart, départ au champ suivant).
function ADHeaderFlow.headerTravelOk(v, header)
    if not ADHeaderFlow.ROAD_CHECK or header == nil then
        return true, "contrôle de la route coupé"
    end
    local _, span = ADHeaderFlow.headerBox(header)
    if span <= ADHeaderFlow.ROAD_MIN_WIDTH then
        return true, string.format("barre de %.1f m", span)
    end
    local job = { combine = v, header = header, phase = "nextField" }
    if wanted(job) == nil then
        return true, "marqueur sans numéro de champ"
    end
    if ADHeaderFlow.ENTRY then
        local plan = ADHeaderFlow.entryFromVehicle(v, job, header, true)
        if plan ~= nil then
            return true, "entrée directe"
        end
    end
    local sm = v.ad.stateModule
    local marker = sm ~= nil and sm:getFirstMarker() or nil
    if marker == nil or ADGraphManager.pathFromTo == nil then
        return false, "pas de point de destination"
    end
    local x, _, z = getWorldTranslation(v.components[1].node)
    local best, bestD = nil, math.huge
    local all = ADGraphManager.getWayPoints ~= nil and ADGraphManager:getWayPoints() or nil
    for _, wp in pairs(all or {}) do
        if wp.x ~= nil and wp.id ~= nil then
            local d = MathUtil.vector2Length(wp.x - x, wp.z - z)
            if d < bestD then
                best, bestD = wp, d
            end
        end
    end
    local points = best ~= nil and ADGraphManager:pathFromTo(best.id, marker.id) or nil
    if points == nil or #points < 2 then
        return false, "pas de route du réseau jusqu'au champ"
    end
    local fits, fx, fz, name = ADHeaderFlow.roadFits(v, job, points, 1, #points)
    if fits then
        return true, string.format("route assez large (%.1f m)", span)
    end
    return false, string.format("route trop étroite pour la barre : %s en (%.0f, %.0f)", tostring(name or "obstacle"), fx, fz)
end

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse : petit recul après l'attelage, puis tout droit dans le champ
-- ------------------------------------------------------------------------------------------------------------
if ADFrontFlow ~= nil and ADFrontFlow.afterFetch ~= nil and ADFrontBackOffTask ~= nil then
    local baseAfterFetch = ADFrontFlow.afterFetch
    function ADFrontFlow.afterFetch(mode, tool)
        local v = mode.vehicle
        local job = v.ad.fpHeaderJob
        if ADHeaderFlow.ENTRY and job ~= nil and job.backIn == nil and job.combine == v and job.header == tool and tool ~= nil
            and mode.fpQueue == nil and mode.fetchSide == "front" then
            -- la remorque est encore devant : seuls les obstacles fixes comptent
            local ok, plan = FarmPilotCall(ADHeaderFlow.entryFromVehicle, v, job, tool, false)
            if ok and plan ~= nil then
                mode.fetchSide = nil
                local back = ADHeaderFlow.headerBox(tool) + ADHeaderFlow.ENTRY_BACKOFF
                log("%s : barre attelée au bord du champ (%s), recule de %.0f m pour laisser partir la remorque", nameOf(v),
                    plan.length > 0 and string.format("à %.0f m devant la barre", plan.length - ADHeaderFlow.ENTRY_INSIDE) or "la barre est au-dessus", back)
                job.entryShort = { tool = tool, back = back }
                mode.parkStage = "backoff"
                mode.parkThen = "restart"
                mode.backOffTask = ADFrontBackOffTask:new(v, back, false, tool)
                v.ad.taskModule:addTask(mode.backOffTask)
                return true
            end
        end
        return baseAfterFetch(mode, tool)
    end
end

-- barre prise (AutonomousHeader.lua : onStart) : au départ qui suit, l'entrée directe est essayée
if ADHeaderFlow.startClearWait ~= nil then
    local baseClearWait = ADHeaderFlow.startClearWait
    function ADHeaderFlow.startClearWait(mode, job)
        job.entryPending = true
        return baseClearWait(mode, job)
    end
end

-- true = elle avance tout droit jusqu'au bord du champ (la tâche prend la place du trajet vers le champ)
function ADHeaderFlow.startEntry(mode, job)
    local v = mode.vehicle
    local header = ADHeaderFlow.attachedHeader(v)
    local sm = v.ad.stateModule
    if header == nil or ADHeaderEnterTask == nil or sm:getFirstMarker() == nil then
        return false
    end
    local plan, why = ADHeaderFlow.entryFromVehicle(v, job, header, true)
    if plan == nil then
        log("%s : pas d'entrée directe dans le champ (%s), y va par le réseau", nameOf(v), tostring(why))
        return false
    end
    if plan.length > 0 then
        log("%s : champ droit devant, avance de %.0f m jusqu'au bord sans passer par le réseau", nameOf(v), plan.length)
        AutonomousMode.message(v, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_headerEntry")
    else
        log("%s : barre déjà au bord du champ, le travail est lancé d'ici sans passer par le réseau", nameOf(v))
    end
    mode.destinationID = sm:getFirstMarker().id
    mode.headerEntry = true
    mode.driveToDestinationTask = ADHeaderEnterTask:new(v, plan)
    v.ad.taskModule:addTask(mode.driveToDestinationTask)
    local ok, err = FarmPilotCall(ADAutonomousManager.startPrefetch)
    if not ok then
        log("ERREUR lecture des parcours : %s", tostring(err))
    end
    return true
end

local baseDepart = AutonomousMode.departToField
function AutonomousMode:departToField()
    local v = self.vehicle
    local job = v.ad.fpHeaderJob
    if ADHeaderFlow.ENTRY and job ~= nil and job.combine == v and job.entryPending then
        job.entryPending = nil
        local short = job.entryShort
        job.entryShort = nil
        local ok, started = FarmPilotCall(ADHeaderFlow.startEntry, self, job)
        if not ok then
            log("ERREUR entrée directe dans le champ : %s", tostring(started))
        elseif started then
            return
        end
        if short ~= nil and ADFrontBackOffTask ~= nil and ADHeaderFlow.attachedHeader(v) == short.tool then
            -- le petit recul était fait pour l'entrée directe, qui n'est plus possible : la sortie habituelle d'un
            -- attelage à l'avant (le reste du recul, puis la courbe vers la route), ensuite le réseau
            local tool = short.tool
            local len = (v.size ~= nil and v.size.length) or 6
            local ml = (tool.size ~= nil and tool.size.length) or 1
            local back = math.max(2, len + ml + (ADFrontFlow.MASS_EXIT_MARGIN or 0) - short.back)
            log("%s : sortie habituelle d'abord (recul de %.0f m de plus, puis la route)", nameOf(v), back)
            self.parkStage = "backoff"
            self.parkThen = "restart"
            self.backOffTask = ADFrontBackOffTask:new(v, back, true, tool)
            v.ad.taskModule:addTask(self.backOffTask)
            return
        end
    end
    return baseDepart(self)
end

-- fin de l'entrée directe : le résultat dans le journal, la suite est celle d'une arrivée au champ
local baseHandle = AutonomousMode.handleFinishedTask
function AutonomousMode:handleFinishedTask()
    if self.headerEntry and self.headerStage == nil then
        self.headerEntry = nil
        local task = self.driveToDestinationTask
        if task ~= nil and task.result ~= nil and task.result ~= "ok" then
            log("%s : entrée dans le champ arrêtée avant la fin (%s), le travail est lancé d'ici", nameOf(self.vehicle), tostring(task.result))
        end
    end
    return baseHandle(self)
end
