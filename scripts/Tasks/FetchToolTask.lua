-- ============================================================================================================
-- FarmPilot : FetchToolTask.lua
-- Mode Autonome : tâche « aller atteler l'outil choisi dans le HUD », comme le joueur.
--
-- Règle :
-- - Le tracteur se place devant l'outil, dans son axe (recherche de chemin de FarmPilot), recule avec la marche
--   arrière de FarmPilot jusqu'à ce que le jeu puisse atteler, attelle, relève l'outil et le replie (repli de
--   FarmPilot).
-- - Déjà devant l'outil, dans son axe, le nez à l'opposé : marche arrière tout de suite.
-- - Attelage raté : il avance dans l'axe de l'outil et recommence, au plus RETRIES fois.
-- - (09/11) Pas de chemin jusque devant l'outil (hangar, machines autour) : il avance tout droit de ROOM_DISTANCE m
--   (recule si l'avant est bloqué) et recalcule, au plus ROOM_MOVES fois, avant d'abandonner.
-- - (07/11) mod d'attelage manuel : flexibles et prise de force branchés après l'attelage, comme le joueur.
-- - (14/11) Outil posé sur un porteur (barre de coupe sur sa remorque) : la machine sautait à l'attelage. Elle
--   s'approche jusqu'à CARRIED_RANGE m (au lieu d'ATTACH_RANGE) et l'outil est attelé relevé : il est soulevé du
--   porteur au lieu d'être tiré vers le bas contre lui (isCarried, attachRange, attachRaised).
-- - Le résultat (self.result = "ok" ou la raison de l'échec) est lu par AutonomousMode:handleFinishedTask.
-- - (15/11) Couloir de marche arrière : semoir rangé de travers (35°) dans sa travée, le tracteur se plaçait 18 m
--   devant lui dans cet axe, donc devant la travée voisine, et en reculant butait sur l'outil rangé là (« le jeu
--   propose un autre attelage », raté 3 fois). Avant de se placer devant l'outil, le couloir de la marche arrière
--   (de l'attelage de l'outil à l'avant du tracteur placé devant, largeur du tracteur + CORRIDOR_MARGIN m de chaque
--   côté) est contrôlé : un autre véhicule ou outil dedans = le tracteur se place plus près (son avant
--   CORRIDOR_FRONT_GAP m avant ce véhicule, son arrière au moins FRONT_MIN_REAR m devant l'attelage) ; pas la
--   place = couloir gêné (frontDistance), la route de la place de l'outil est prise si elle existe
--   (AutonomousMode.fetchRoutePoint), sinon comme avant. Journal : « couloir de marche arrière ... ».
--
-- Branché par : AutonomousMode.lua (startFetchAttach : ADFetchToolTask:new ; fetchRoutePoint et monitorFetchRoute :
-- isReady, readyFor, FRONT_MARGIN).
-- ============================================================================================================

ADFetchToolTask = ADInheritsFrom(AbstractTask)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFetchToolTask.STATE_PLAN = 1
ADFetchToolTask.STATE_PLANNING = 2
ADFetchToolTask.STATE_DRIVING = 3
ADFetchToolTask.STATE_STOPPING = 4
ADFetchToolTask.STATE_REVERSE = 5
ADFetchToolTask.STATE_ATTACHED = 6
ADFetchToolTask.STATE_FORWARD = 7
ADFetchToolTask.STATE_ROOM = 8

ADFetchToolTask.FRONT_MARGIN = 12         -- m entre l'avant de l'outil et l'arrière du tracteur placé devant
ADFetchToolTask.FRONT_MIN_REAR = 4        -- m (15/11) : couloir gêné, l'arrière du tracteur placé devant au moins à ça de l'attelage de l'outil
ADFetchToolTask.CORRIDOR_MARGIN = 0.5     -- m (15/11) de chaque côté du tracteur : couloir de la marche arrière
ADFetchToolTask.CORRIDOR_FRONT_GAP = 1    -- m (15/11) entre l'avant du tracteur placé devant et un autre véhicule dans le couloir
ADFetchToolTask.CORRIDOR_STEP = 0.5       -- m (15/11) entre deux points lus sur un autre véhicule
ADFetchToolTask.LOOK_AHEAD = 5            -- m : la marche arrière vise un point de l'axe de l'outil, à cette distance derrière le tracteur
ADFetchToolTask.AIM_BEHIND = 3            -- m : ce point ne va pas plus loin que ça dans l'outil
ADFetchToolTask.READY_LATERAL = 1.5       -- m d'écart à l'axe de l'outil accepté pour reculer tout de suite
ADFetchToolTask.READY_ANGLE = 15          -- ° d'écart à l'axe de l'outil accepté pour reculer tout de suite
ADFetchToolTask.READY_MAX = 30            -- m devant l'outil au plus pour reculer tout de suite
ADFetchToolTask.HITCH_AIM = 4             -- m entre les points d'attelage : la marche arrière vise le point d'attelage de l'outil, plus son axe
ADFetchToolTask.DIRECT_BEARING = 25       -- ° : marche arrière directe si le point d'attelage de l'outil est derrière le tracteur, à moins de ça de son axe
ADFetchToolTask.DIRECT_ANGLE = 40         -- ° entre le tracteur et l'outil au plus pour la marche arrière directe (le jeu attelle jusqu'à 70°)
ADFetchToolTask.DIRECT_MAX = 15           -- m entre les points d'attelage au plus pour la marche arrière directe
ADFetchToolTask.DIRECT_SIDE = 0.6         -- m de côté toujours acceptés (tout près, l'angle ne veut plus rien dire)
ADFetchToolTask.ATTACH_RANGE = 0.8        -- m entre les points d'attelage pour essayer d'atteler
ADFetchToolTask.CARRIED_RANGE = 0.3       -- m : pareil pour un outil posé sur un porteur (le jeu rattrape l'écart d'un coup)
ADFetchToolTask.MISS_MARGIN = 0.6         -- m : la distance remonte de ça après le plus près = raté
ADFetchToolTask.STALL_STEP = 0.03         -- m : se rapprocher de moins que ça du point d'attelage ne compte pas
ADFetchToolTask.STALL_TIME = 1200         -- ms sans se rapprocher : le tracteur bute contre l'outil, on attelle si le jeu le permet (il attelle de plus loin qu'ATTACH_RANGE)
ADFetchToolTask.STALL_GIVE_UP = 8000      -- ms sans se rapprocher ni atteler : on arrête de pousser (attelage raté)
ADFetchToolTask.REVERSE_TIMEOUT = 90000   -- ms
ADFetchToolTask.STOP_TIMEOUT = 8000       -- ms pour s'arrêter avant de reculer
ADFetchToolTask.CURVE_STUCK_TIME = 10000  -- ms arrêté sur la courbe d'entrée (AutonomousNoseIn.lua) : recherche de chemin
ADFetchToolTask.ATTACHED_TIME = 2500      -- ms après l'attelage (béquilles, relevage) avant de partir
ADFetchToolTask.CONNECT_TIME = 500        -- ms après l'attelage : flexibles et prise de force (mod d'attelage manuel)
ADFetchToolTask.RETRIES = 2               -- attelage raté : on avance dans l'axe et on recommence, au plus ce nombre de fois
ADFetchToolTask.FORWARD_ROOM = 10         -- m d'avance (en plus de la longueur du tracteur) pour reprendre l'axe
ADFetchToolTask.FORWARD_TIMEOUT = 30000   -- ms
ADFetchToolTask.ROOM_DISTANCE = 10        -- m tout droit quand il n'y a pas de chemin, avant un nouveau calcul
ADFetchToolTask.ROOM_MOVES = 2            -- fois au plus
ADFetchToolTask.ROOM_SPEED = 5            -- km/h
ADFetchToolTask.ROOM_BLOCKED = 1500       -- ms bloqué par un obstacle : on s'arrête là
ADFetchToolTask.ROOM_TIMEOUT = 25000      -- ms
ADFetchToolTask.APPROACH_TEXT = "marche arrière" -- journal (attelage avant : « marche avant »)

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
-- direct (10/11) : arrivé par la route de la place de l'outil, en marche arrière et à portée : marche arrière tout de
-- suite vers le point d'attelage, même si l'outil a bougé (pas dans l'axe à READY_LATERAL / READY_ANGLE près)
function ADFetchToolTask:new(vehicle, tool, direct)
    local o = ADFetchToolTask:create()
    o.vehicle = vehicle
    o.tool = tool
    o.direct = direct == true
    o.result = nil
    return o
end

function ADFetchToolTask:setUp()
    self.carried = nil
    self.state = ADFetchToolTask.STATE_PLAN
    self.timer = 0
    self.minDistance = math.huge
    self.retries = 0
    self.roomMoves = 0
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

-- ------------------------------------------------------------------------------------------------------------
-- Outil posé sur un porteur
-- ------------------------------------------------------------------------------------------------------------
-- (14/11) l'outil est posé sur un porteur (barre de coupe sur sa remorque porte-barre), pas au sol ; regardé une
-- fois, avant l'attelage (attelé, il n'est plus sur le porteur)
function ADFetchToolTask:isCarried()
    if self.carried == nil then
        self.carried = false
        if ADHeaderFlow ~= nil and ADHeaderFlow.trailerOf ~= nil then
            local ok, trailer = FarmPilotCall(ADHeaderFlow.trailerOf, self.tool)
            self.carried = ok and trailer ~= nil
        end
    end
    return self.carried
end

-- m entre les points d'attelage pour essayer d'atteler
function ADFetchToolTask:attachRange()
    return self:isCarried() and ADFetchToolTask.CARRIED_RANGE or ADFetchToolTask.ATTACH_RANGE
end

-- attelage relevé (le jeu attelle baissé quand rien n'est dit : l'outil posé à 1 m du sol était tiré vers le bas
-- contre son porteur). Mêmes contrôles que l'attelage du jeu ; true = attelé
function ADFetchToolTask:attachRaised(info)
    local vehicle, tool = info.attacherVehicle, info.attachable
    local joints = vehicle.spec_attacherJoints ~= nil and vehicle.spec_attacherJoints.attacherJoints or nil
    local joint = joints ~= nil and joints[info.attacherVehicleJointDescIndex] or nil
    if vehicle.attachImplement == nil or joint == nil or joint.jointIndex ~= 0 then
        return false
    end
    if tool.getActiveInputAttacherJointDescIndex == nil or tool:getActiveInputAttacherJointDescIndex() ~= nil then
        return false
    end
    local ok, err = FarmPilotCall(vehicle.attachImplement, vehicle, tool, info.attachableJointDescIndex, info.attacherVehicleJointDescIndex, nil, nil, false)
    if not ok then
        ADAutonomousManager.log("ERREUR attelage relevé : %s", tostring(err))
    end
    return tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() == vehicle
end

-- outil relevé tout de suite (attelé par le jeu de la façon habituelle)
function ADFetchToolTask:raiseNow()
    local tool = self.tool
    local attacher = tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() or nil
    if attacher ~= nil and attacher.getAttacherJointIndexFromObject ~= nil and attacher.setJointMoveDown ~= nil then
        local jointIndex = attacher:getAttacherJointIndexFromObject(tool)
        if jointIndex ~= nil then
            attacher:setJointMoveDown(jointIndex, false)
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Points d'attelage, place devant l'outil
-- ------------------------------------------------------------------------------------------------------------
-- attelage arrière du tracteur et point d'attelage de l'outil (positions monde) ; nil si l'outil ne va plus
function ADFetchToolTask:getJoints()
    local _, joint, _, input = ADAutonomousManager.matchJoints(self.vehicle, self.tool, true)
    if joint == nil or joint.jointTransform == nil or input == nil then
        return nil
    end
    local ax, ay, az = getWorldTranslation(joint.jointTransform)
    local hitch = ADAutonomousManager.toolHitch(self.vehicle, self.tool)
    if hitch == nil then
        return nil
    end
    return { x = ax, y = ay, z = az }, hitch
end

-- point devant l'outil, dans son axe, où le tracteur se place avant de reculer
function ADFetchToolTask:getFrontPoint(hitch)
    local d, who, blocked, at = ADFetchToolTask.frontDistance(self.vehicle, self.tool, hitch)
    if who ~= nil and self.corridorLogged ~= who then
        self.corridorLogged = who
        local length = (self.vehicle.size ~= nil and self.vehicle.size.length) or 6
        if blocked then
            ADAutonomousManager.log("%s : couloir de marche arrière gêné par « %s » à %.1f m de l'attelage de « %s », pas la place de se mettre devant : placé comme avant (%.1f m)",
                tostring(self.vehicle.ad.stateModule:getName()), tostring(who), at or -1, ADAutonomousManager.toolLabel(self.tool), d)
        else
            ADAutonomousManager.log("%s : couloir de marche arrière : « %s » à %.1f m de l'attelage de « %s », tracteur placé plus près (%.1f m au lieu de %.1f m)",
                tostring(self.vehicle.ad.stateModule:getName()), tostring(who), at or -1, ADAutonomousManager.toolLabel(self.tool), d, length + ADFetchToolTask.FRONT_MARGIN)
        end
    end
    return { x = hitch.x + hitch.dirX * d, y = hitch.y, z = hitch.z + hitch.dirZ * d }
end

-- ------------------------------------------------------------------------------------------------------------
-- (15/11) Couloir de la marche arrière
-- ------------------------------------------------------------------------------------------------------------
-- le tracteur, l'outil et tout ce qui y est attelé : jamais un obstacle
local function ownTrain(vehicle, tool)
    local set = {}
    for _, root in ipairs({ vehicle, tool }) do
        if root ~= nil then
            set[root] = true
            local ok, list = FarmPilotCall(AutoDrive.getAllImplements, root, true)
            if ok and type(list) == "table" then
                for _, v in pairs(list) do
                    set[v] = true
                end
            end
        end
    end
    return set
end

-- partie d'un véhicule dans le couloir (axe de l'outil, de fromAlong à toAlong m devant son attelage, halfWidth m de
-- chaque côté) : la plus petite distance le long de l'axe, ou nil
function ADFetchToolTask.corridorAlong(v, hitch, fromAlong, toAlong, halfWidth)
    if v == nil or v.isDeleted == true or v.components == nil or v.components[1] == nil or v.components[1].node == nil
        or v.size == nil or v.size.length == nil or v.size.width == nil then
        return nil
    end
    local node = v.components[1].node
    local length, width = v.size.length, v.size.width
    local cx, _, cz = localToWorld(node, 0, 0, v.size.lengthOffset or 0)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local len = MathUtil.vector2Length(dx, dz)
    if len < 0.001 then
        return nil
    end
    dx, dz = dx / len, dz / len
    -- loin du couloir : pas lu
    local radius = 0.5 * math.sqrt(length * length + width * width)
    local u0 = (cx - hitch.x) * hitch.dirX + (cz - hitch.z) * hitch.dirZ
    local w0 = (cx - hitch.x) * hitch.dirZ - (cz - hitch.z) * hitch.dirX
    if u0 + radius < fromAlong or u0 - radius > toAlong or math.abs(w0) - radius > halfWidth then
        return nil
    end
    local nl = math.max(1, math.ceil(length / ADFetchToolTask.CORRIDOR_STEP))
    local nw = math.max(1, math.ceil(width / ADFetchToolTask.CORRIDOR_STEP))
    local best = nil
    for i = 0, nl do
        local a = -length / 2 + length * i / nl
        for j = 0, nw do
            local b = -width / 2 + width * j / nw
            local px, pz = cx + dx * a + dz * b, cz + dz * a - dx * b
            local u = (px - hitch.x) * hitch.dirX + (pz - hitch.z) * hitch.dirZ
            local w = (px - hitch.x) * hitch.dirZ - (pz - hitch.z) * hitch.dirX
            if u >= fromAlong and u <= toAlong and math.abs(w) <= halfWidth and (best == nil or u < best) then
                best = u
            end
        end
    end
    return best
end

-- distance de l'attelage de l'outil où se place le tracteur (son centre) avant de reculer, et ce qui gêne :
-- d, nom du véhicule dans le couloir (nil : couloir libre), couloir gêné (pas la place de se mettre plus près),
-- distance de ce véhicule le long de l'axe
function ADFetchToolTask.frontDistance(vehicle, tool, hitch)
    local length = (vehicle.size ~= nil and vehicle.size.length) or 6
    local width = (vehicle.size ~= nil and vehicle.size.width) or 3
    local d = length + ADFetchToolTask.FRONT_MARGIN
    local halfWidth = width / 2 + ADFetchToolTask.CORRIDOR_MARGIN
    local toAlong = d + length / 2 + ADFetchToolTask.CORRIDOR_FRONT_GAP
    local own = ownTrain(vehicle, tool)
    local nearest, who = nil, nil
    for _, v in pairs(AutoDrive.getAllVehicles ~= nil and AutoDrive.getAllVehicles() or {}) do
        if not own[v] then
            local ok, u = FarmPilotCall(ADFetchToolTask.corridorAlong, v, hitch, 0.5, toAlong, halfWidth)
            if ok and u ~= nil and (nearest == nil or u < nearest) then
                nearest, who = u, v
            end
        end
    end
    if nearest == nil then
        return d, nil, false, nil
    end
    local name = ADAutonomousManager.toolLabel ~= nil and ADAutonomousManager.toolLabel(who) or "?"
    local fit = nearest - length / 2 - ADFetchToolTask.CORRIDOR_FRONT_GAP
    if fit >= length / 2 + ADFetchToolTask.FRONT_MIN_REAR then
        return math.min(d, fit), name, false, nearest
    end
    return d, name, true, nearest
end

-- déjà devant l'outil, dans son axe, le nez à l'opposé : on recule tout de suite
function ADFetchToolTask.isReady(vehicle, hitch)
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local rx, _, rz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local ox, oz = vx - hitch.x, vz - hitch.z
    local along = ox * hitch.dirX + oz * hitch.dirZ
    local lateral = math.abs(ox * hitch.dirZ - oz * hitch.dirX)
    local len = MathUtil.vector2Length(rx, rz)
    if len < 0.001 then
        return false
    end
    local cosA = (rx * hitch.dirX + rz * hitch.dirZ) / len
    return along > 0 and along <= ADFetchToolTask.READY_MAX and lateral <= ADFetchToolTask.READY_LATERAL
        and cosA >= math.cos(math.rad(ADFetchToolTask.READY_ANGLE))
end

function ADFetchToolTask:isReadyToReverse(hitch)
    return ADFetchToolTask.isReady(self.vehicle, hitch)
end

-- (10/11) méthodes reprises par l'attelage avant (FetchFrontToolTask.lua) : portée de la visée directe, sens du
-- tracteur au bout du chemin (ici le nez à l'opposé de l'outil)
function ADFetchToolTask:isReachableFrom(hitch, ax, az)
    return ADFetchToolTask.isReachable(self.vehicle, hitch, ax, az)
end

function ADFetchToolTask:pathHeading(hitch)
    return { x = hitch.dirX, z = hitch.dirZ }
end

-- (10/11) outil qui a bougé dans sa place : le point d'attelage de l'outil est derrière le tracteur, à portée d'une
-- marche arrière qui le vise directement (ax, az : attelage arrière du tracteur). Pas besoin d'être dans l'axe de l'outil.
function ADFetchToolTask.isReachable(vehicle, hitch, ax, az)
    local fx, _, fz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local len = MathUtil.vector2Length(fx, fz)
    if len < 0.001 then
        return false
    end
    fx, fz = fx / len, fz / len
    local dx, dz = hitch.x - ax, hitch.z - az
    local distance = MathUtil.vector2Length(dx, dz)
    local behind = -(dx * fx + dz * fz)
    local side = math.abs(dx * fz - dz * fx)
    local cosA = fx * hitch.dirX + fz * hitch.dirZ
    return distance <= ADFetchToolTask.DIRECT_MAX and behind > -ADFetchToolTask.DIRECT_SIDE
        and side <= math.max(ADFetchToolTask.DIRECT_SIDE, distance * math.sin(math.rad(ADFetchToolTask.DIRECT_BEARING)))
        and cosA >= math.cos(math.rad(ADFetchToolTask.DIRECT_ANGLE))
end

-- pour la route vers l'outil (AutonomousMode) : prêt à reculer ?, distance entre les points d'attelage, à portée
-- d'une marche arrière directe ?
function ADFetchToolTask.readyFor(vehicle, tool)
    local _, joint = ADAutonomousManager.matchJoints(vehicle, tool, true)
    local hitch = ADAutonomousManager.toolHitch(vehicle, tool)
    if hitch == nil or joint == nil or joint.jointTransform == nil then
        return false, nil, false
    end
    local ax, _, az = getWorldTranslation(joint.jointTransform)
    return ADFetchToolTask.isReady(vehicle, hitch), MathUtil.vector2Length(ax - hitch.x, az - hitch.z), ADFetchToolTask.isReachable(vehicle, hitch, ax, az)
end

-- ------------------------------------------------------------------------------------------------------------
-- À chaque image (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function ADFetchToolTask:holdVehicle(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
end

function ADFetchToolTask:update(dt)
    self.timer = self.timer + dt
    if self.tool == nil or self.tool.isDeleted then
        self:finish("gone")
        return
    end
    local attacher = self.tool.getAttacherVehicle ~= nil and self.tool:getAttacherVehicle() or nil
    if attacher ~= nil and self.state ~= ADFetchToolTask.STATE_ATTACHED then
        if attacher == self.vehicle then
            -- attelé (par le joueur ou par nous)
            self:onAttached()
        else
            self:finish("busy")
        end
        return
    end

    if self.state == ADFetchToolTask.STATE_PLAN then
        self:holdVehicle(dt)
        local _, hitch = self:getJoints()
        if hitch == nil then
            self:finish("noJoint")
            return
        end
        if self:isReadyToReverse(hitch) then
            self.direct = false
            ADAutonomousManager.log("%s : déjà devant l'outil, %s", tostring(self.vehicle.ad.stateModule:getName()), self.APPROACH_TEXT)
            self:setState(ADFetchToolTask.STATE_STOPPING)
            return
        end
        -- (12/11) chemin tout prêt donné par celui qui a créé la tâche (barre sur une remorque reculée dans l'entrée
        -- du champ : la courbe du chemin jusqu'au cadre, Modes/AutonomousHeaderBackIn.lua) ; une seule fois, sinon
        -- la suite habituelle
        if self.presetPath ~= nil then
            local preset = self.presetPath
            self.presetPath = nil
            local ok, path = FarmPilotCall(preset, self.vehicle, hitch)
            if ok and path ~= nil and #path > 0 then
                self.direct = false
                self.vehicle.ad.drivePathModule:setWayPoints(path)
                self.onCurve = true
                self.curveStuck = 0
                self:setState(ADFetchToolTask.STATE_DRIVING)
                return
            end
        end
        -- (10/11) outil avant au fond d'une place prise en marche arrière : une courbe calculée depuis la route qui
        -- passe devant, pas de recherche de chemin ; une seule fois, voir Modes/AutonomousNoseIn.lua
        if self.noseInPlace ~= nil and ADNoseIn ~= nil then
            local place = self.noseInPlace
            self.noseInPlace = nil
            local ok, path, c = FarmPilotCall(ADNoseIn.pathFromVehicle, self.vehicle, place, self.tool, self.noseInAhead, { self.tool })
            if ok and path ~= nil and #path > 0 then
                self.direct = false
                self.vehicle.ad.drivePathModule:setWayPoints(path)
                ADAutonomousManager.log("%s : entrée en courbe vers l'outil (%.0f° puis %.0f°, %.1f m, rayon %.1f m)", tostring(self.vehicle.ad.stateModule:getName()),
                    math.deg(c.arc1), math.deg(c.arc2), c.length, c.radius)
                self.onCurve = true
                self.curveStuck = 0
                self:setState(ADFetchToolTask.STATE_DRIVING)
                return
            end
            ADAutonomousManager.log("%s : pas de courbe d'ici vers l'outil (%s), recherche de chemin", tostring(self.vehicle.ad.stateModule:getName()), ok and "trop serrée, trop longue ou trop loin des routes" or tostring(path))
        end
        if self.direct then
            -- une seule fois : après un déplacement faute de chemin, la règle habituelle
            self.direct = false
            local joint = self:getJoints()
            if joint ~= nil and self:isReachableFrom(hitch, joint.x, joint.z) then
                self.aimHitch = true
                ADAutonomousManager.log("%s : outil pas dans l'axe, %s vers son point d'attelage", tostring(self.vehicle.ad.stateModule:getName()), self.APPROACH_TEXT)
                self:setState(ADFetchToolTask.STATE_STOPPING)
                return
            end
        end
        local front = self:getFrontPoint(hitch)
        local pf = self.vehicle.ad.pathFinderModule
        pf:reset()
        -- (15/11) barre de coupe sur sa remorque : jamais le secours qui traverse la culture (noFallback posé par
        -- Modes/AutonomousHeader.lua, startFetchAttach)
        pf.noFallback = self.noFallback == true
        pf:startPathPlanningTo(front, self:pathHeading(hitch))
        ADAutonomousManager.log("%s : chemin vers l'avant de l'outil (%.0f, %.0f)", tostring(self.vehicle.ad.stateModule:getName()), front.x, front.z)
        self:setState(ADFetchToolTask.STATE_PLANNING)
    elseif self.state == ADFetchToolTask.STATE_PLANNING then
        local pf = self.vehicle.ad.pathFinderModule
        if pf:hasFinished() then
            local path = pf:getPath()
            if path == nil or #path == 0 then
                -- (09/11) un peu de place d'abord, puis nouveau calcul
                if self:startRoom() then
                    return
                end
                self:finish("noPath")
                return
            end
            self.vehicle.ad.drivePathModule:setWayPoints(path)
            self:setState(ADFetchToolTask.STATE_DRIVING)
        else
            pf:update(dt)
            self:holdVehicle(dt)
        end
    elseif self.state == ADFetchToolTask.STATE_DRIVING then
        local dpm = self.vehicle.ad.drivePathModule
        if dpm:isTargetReached() then
            self.onCurve = false
            self:setState(ADFetchToolTask.STATE_STOPPING)
        else
            dpm:update(dt)
            -- la courbe ne regarde pas les obstacles : arrêté dessus trop longtemps (quelque chose sur le passage),
            -- recherche de chemin d'où il est
            if self.onCurve then
                if math.abs(self.vehicle.lastSpeedReal or 0) < 0.0003 then
                    self.curveStuck = (self.curveStuck or 0) + dt
                else
                    self.curveStuck = 0
                end
                if self.curveStuck >= ADFetchToolTask.CURVE_STUCK_TIME or self.driveStuck then
                    ADAutonomousManager.log("%s : arrêté sur la courbe vers l'outil (passage occupé), recherche de chemin", tostring(self.vehicle.ad.stateModule:getName()))
                    self.driveStuck = nil
                    self.onCurve = false
                    self:setState(ADFetchToolTask.STATE_PLAN)
                end
            end
        end
    elseif self.state == ADFetchToolTask.STATE_STOPPING then
        self:holdVehicle(dt)
        if math.abs(self.vehicle.lastSpeedReal) < 0.0015 or self.timer > ADFetchToolTask.STOP_TIMEOUT then
            self.minDistance = math.huge
            self:setState(ADFetchToolTask.STATE_REVERSE)
        end
    elseif self.state == ADFetchToolTask.STATE_REVERSE then
        self:updateReverse(dt)
    elseif self.state == ADFetchToolTask.STATE_FORWARD then
        self:updateForward(dt)
    elseif self.state == ADFetchToolTask.STATE_ROOM then
        self:updateRoom(dt)
    elseif self.state == ADFetchToolTask.STATE_ATTACHED then
        self:holdVehicle(dt)
        if not self.connected and self.timer >= ADFetchToolTask.CONNECT_TIME then
            self.connected = true
            self:connectManual()
        end
        if self.timer >= ADFetchToolTask.ATTACHED_TIME then
            self:prepareForRoad()
            self:finish("ok")
        end
    end
end

function ADFetchToolTask:setState(state)
    self.state = state
    self.timer = 0
    if state == ADFetchToolTask.STATE_REVERSE then
        -- nouvelle approche : « ne se rapproche plus » repart de zéro
        self.stallDistance = nil
        self.stallTime = 0
    end
end

-- (11/11) faucheuse repliée : le tracteur butait contre l'outil avant ATTACH_RANGE et poussait sans jamais essayer
-- d'atteler, alors que le jeu attelle de plus loin. Renvoie : ne se rapproche plus (on essaie d'atteler), ne se
-- rapproche plus depuis trop longtemps (on arrête de pousser).
function ADFetchToolTask:updateStall(dt, distance)
    if self.stallDistance == nil or distance < self.stallDistance - ADFetchToolTask.STALL_STEP then
        self.stallDistance = distance
        self.stallTime = 0
    else
        self.stallTime = (self.stallTime or 0) + dt
    end
    return self.stallTime >= ADFetchToolTask.STALL_TIME, self.stallTime >= ADFetchToolTask.STALL_GIVE_UP
end

-- arrêté contre l'outil sans pouvoir atteler : une ligne au journal, avec ce que le jeu répond
function ADFetchToolTask:logBlocked(distance)
    ADAutonomousManager.log("%s : n'avance plus, à %.2f m du point d'attelage de l'outil, sans pouvoir atteler (%s)",
        tostring(self.vehicle.ad.stateModule:getName()), distance, tostring(self.attachWhy or "raison inconnue"))
end

-- ------------------------------------------------------------------------------------------------------------
-- Marche arrière vers l'outil, nouvel essai
-- ------------------------------------------------------------------------------------------------------------
-- marche arrière de FarmPilot (ADSpecialDrivingModule:reverseToPoint) vers un point dans l'axe de l'outil ;
-- sans le contrôle de collision arrière, qui verrait l'outil lui-même
function ADFetchToolTask:updateReverse(dt)
    local joint, hitch = self:getJoints()
    if joint == nil then
        self:holdVehicle(dt)
        self:finish("noJoint")
        return
    end
    local distance = MathUtil.vector2Length(joint.x - hitch.x, joint.z - hitch.z)
    -- passé à côté ou au-delà du point d'attelage
    local past = (joint.x - hitch.x) * hitch.dirX + (joint.z - hitch.z) * hitch.dirZ < -ADFetchToolTask.MISS_MARGIN
    if distance < self.minDistance then
        self.minDistance = distance
    end
    local stalled, blocked = self:updateStall(dt, distance)
    local range = self:attachRange()
    if distance <= range or stalled then
        if distance <= range then
            self:holdVehicle(dt)
        end
        if self:tryAttach(distance) then
            return
        end
    end
    if blocked then
        self:logBlocked(distance)
    end
    if past or blocked or (self.minDistance < 3 and distance > self.minDistance + ADFetchToolTask.MISS_MARGIN) then
        self:holdVehicle(dt)
        if self.retries < ADFetchToolTask.RETRIES then
            self.retries = self.retries + 1
            ADAutonomousManager.log("%s : attelage raté (au plus près %.2f m), on avance %s et on recommence (%d/%d)", tostring(self.vehicle.ad.stateModule:getName()), self.minDistance, self.aimHitch and "tout droit" or "dans l'axe", self.retries, ADFetchToolTask.RETRIES)
            self:setState(ADFetchToolTask.STATE_FORWARD)
            return
        end
        if self.aimHitch then
            -- visée directe ratée : la règle habituelle (chemin jusque devant l'outil, puis marche arrière dans son axe)
            self.aimHitch = false
            self.retries = 0
            ADAutonomousManager.log("%s : attelage raté en visant le point d'attelage (au plus près %.2f m), on repasse devant l'outil", tostring(self.vehicle.ad.stateModule:getName()), self.minDistance)
            self:setState(ADFetchToolTask.STATE_PLAN)
            return
        end
        ADAutonomousManager.log("%s : attelage raté (au plus près %.2f m, maintenant %.2f m)", tostring(self.vehicle.ad.stateModule:getName()), self.minDistance, distance)
        self:finish("missed")
        return
    end
    if self.timer > ADFetchToolTask.REVERSE_TIMEOUT then
        self:holdVehicle(dt)
        self:finish("timeout")
        return
    end
    if distance <= range then
        -- à portée mais le jeu n'attelle pas encore : tout doucement
        self:reverseTo(dt, hitch, 1, distance)
    else
        self:reverseTo(dt, hitch, math.min(5, math.max(1.5, distance * 0.6)), distance)
    end
end

-- attelage raté : on avance en reprenant l'axe de l'outil, assez loin pour reculer droit, puis on recommence
function ADFetchToolTask:updateForward(dt)
    local _, hitch = self:getJoints()
    if hitch == nil then
        self:holdVehicle(dt)
        self:finish("noJoint")
        return
    end
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local along = (vx - hitch.x) * hitch.dirX + (vz - hitch.z) * hitch.dirZ
    local room = ((self.vehicle.size ~= nil and self.vehicle.size.length) or 6) + ADFetchToolTask.FORWARD_ROOM
    if self.aimHitch then
        -- (10/11) outil qui a bougé : on s'éloigne tout droit de son point d'attelage, par où on est venu (son axe peut
        -- être en travers de la place), puis on recule de nouveau vers lui
        local away = MathUtil.vector2Length(vx - hitch.x, vz - hitch.z)
        if away >= room or away < 0.1 or self.timer > ADFetchToolTask.FORWARD_TIMEOUT then
            self:setState(ADFetchToolTask.STATE_STOPPING)
            return
        end
        local point = { x = vx + (vx - hitch.x) / away * 8, y = hitch.y, z = vz + (vz - hitch.z) / away * 8 }
        self.vehicle.ad.specialDrivingModule:driveToPoint(dt, point, 4, true, 0.6, 8, true)
        return
    end
    if along >= room or self.timer > ADFetchToolTask.FORWARD_TIMEOUT then
        self:setState(ADFetchToolTask.STATE_STOPPING)
        return
    end
    local aim = math.max(along, 0) + 8
    local point = { x = hitch.x + hitch.dirX * aim, y = hitch.y, z = hitch.z + hitch.dirZ * aim }
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, point, 4, true, 0.6, 8, true)
end

-- (09/11) pas de chemin jusque devant l'outil : tout droit en avant (en arrière si l'avant est bloqué), puis nouveau
-- calcul ; false si c'est déjà fait ROOM_MOVES fois ou si les deux côtés sont bloqués
function ADFetchToolTask:startRoom()
    if self.roomMoves >= ADFetchToolTask.ROOM_MOVES then
        return false
    end
    local v = self.vehicle
    local frontBlocked = v.ad.sensors ~= nil and v.ad.sensors.frontSensor ~= nil and v.ad.sensors.frontSensor:pollInfo() == true
    local dir = 1
    if frontBlocked then
        if v.ad.collisionDetectionModule:checkReverseCollision() then
            ADAutonomousManager.log("%s : pas de chemin devant l'outil, avant et arrière bloqués", tostring(v.ad.stateModule:getName()))
            self.roomMoves = ADFetchToolTask.ROOM_MOVES
            return false
        end
        dir = -1
    end
    self.roomMoves = self.roomMoves + 1
    self.roomDir = dir
    local x, _, z = getWorldTranslation(v.components[1].node)
    self.roomStart = { x = x, z = z }
    local tx, ty, tz = AutoDrive.localToWorld(v, 0, 0, 100 * dir)
    self.roomTarget = { x = tx, y = ty, z = tz }
    self.roomBlockedTime = 0
    v.ad.specialDrivingModule:releaseVehicle()
    ADAutonomousManager.log("%s : pas de chemin devant l'outil, on %s de %d m tout droit puis nouveau calcul (%d/%d)", tostring(v.ad.stateModule:getName()),
        dir > 0 and "avance" or "recule", ADFetchToolTask.ROOM_DISTANCE, self.roomMoves, ADFetchToolTask.ROOM_MOVES)
    self:setState(ADFetchToolTask.STATE_ROOM)
    return true
end

function ADFetchToolTask:updateRoom(dt)
    local v = self.vehicle
    local sdm = v.ad.specialDrivingModule
    local x, _, z = getWorldTranslation(v.components[1].node)
    local done = MathUtil.vector2Length(x - self.roomStart.x, z - self.roomStart.z)
    local blocked
    if self.roomDir > 0 then
        blocked = v.ad.sensors ~= nil and v.ad.sensors.frontSensor ~= nil and v.ad.sensors.frontSensor:pollInfo() == true
    else
        blocked = v.ad.collisionDetectionModule:checkReverseCollision() == true
    end
    self.roomBlockedTime = blocked and self.roomBlockedTime + dt or 0
    if done >= ADFetchToolTask.ROOM_DISTANCE or self.roomBlockedTime >= ADFetchToolTask.ROOM_BLOCKED or self.timer >= ADFetchToolTask.ROOM_TIMEOUT then
        ADAutonomousManager.log("%s : %.1f m faits%s, nouveau calcul", tostring(v.ad.stateModule:getName()), done, blocked and " (obstacle)" or "")
        self:holdVehicle(dt)
        self:setState(ADFetchToolTask.STATE_PLAN)
        return
    end
    if blocked then
        self:holdVehicle(dt)
    elseif self.roomDir > 0 then
        sdm:driveToPoint(dt, self.roomTarget, ADFetchToolTask.ROOM_SPEED, false, 0.6, ADFetchToolTask.ROOM_SPEED, true)
    else
        -- même marche arrière que vers l'outil (reverseTo), vers un point loin derrière, tout droit
        sdm.reverseNode = sdm:getReverseNode()
        if sdm.reverseNode == nil then
            self:holdVehicle(dt)
            self:setState(ADFetchToolTask.STATE_PLAN)
            return
        end
        sdm.reverseTarget = self.roomTarget
        sdm.currentWayPointIndex = 0
        sdm.wayPoints = {}
        sdm:getBasicStates()
        sdm:reverseToPoint(dt, ADFetchToolTask.ROOM_SPEED)
    end
end

function ADFetchToolTask:reverseTo(dt, hitch, maxSpeed, distance)
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm.reverseNode = sdm:getReverseNode()
    if sdm.reverseNode == nil then
        self:finish("noJoint")
        return
    end
    if self.aimHitch or (distance ~= nil and distance <= ADFetchToolTask.HITCH_AIM) then
        -- (10/11) derniers mètres, ou outil qui a bougé (pas dans l'axe) : on vise le point d'attelage de l'outil
        -- lui-même ; l'attelage du tracteur, derrière lui dans son axe, y arrive même sans être aligné sur l'outil
        sdm.reverseTarget = { x = hitch.x, y = hitch.y, z = hitch.z }
    else
        -- point de l'axe de l'outil, LOOK_AHEAD m derrière le tracteur (projeté sur l'axe) : le tracteur rejoint l'axe
        -- et s'aligne dessus en reculant, au lieu de viser un point fixe (écart de côté à l'arrivée)
        local rx, _, rz = getWorldTranslation(sdm.reverseNode)
        local along = (rx - hitch.x) * hitch.dirX + (rz - hitch.z) * hitch.dirZ
        local aim = math.max(along - ADFetchToolTask.LOOK_AHEAD, -ADFetchToolTask.AIM_BEHIND)
        sdm.reverseTarget = { x = hitch.x + hitch.dirX * aim, y = hitch.y, z = hitch.z + hitch.dirZ * aim }
    end
    sdm.currentWayPointIndex = 0
    sdm.wayPoints = {}
    sdm:getBasicStates()
    sdm:reverseToPoint(dt, maxSpeed)
end

-- ------------------------------------------------------------------------------------------------------------
-- Attelage, branchements, outil prêt pour la route
-- ------------------------------------------------------------------------------------------------------------
-- point d'attelage du tracteur et de l'outil retenus pour cet outil (l'attelage avant prend ceux de l'avant)
function ADFetchToolTask:matchPair()
    return ADAutonomousManager.matchJoints(self.vehicle, self.tool, true)
end

-- (11/11) le jeu ne propose pas notre outil (un autre outil plus près d'un autre point d'attelage, position de
-- l'outil pas à jour dans sa liste) : le même contrôle que lui (AttacherJoints.updateVehiclesInAttachRange :
-- distance, hauteur, compatibilité, angle) sur notre point d'attelage et celui de l'outil
function ADFetchToolTask:ownAttachInfo(maxDistanceSq, maxAngle)
    local jointIndex, joint, inputIndex, input = self:matchPair()
    if joint == nil or joint.jointTransform == nil or input == nil or input.node == nil then
        return nil
    end
    if joint.jointIndex ~= nil and joint.jointIndex ~= 0 then
        return nil
    end
    if self.vehicle.getIsAttachingAllowed ~= nil and not self.vehicle:getIsAttachingAllowed(joint) then
        return nil
    end
    if self.tool.getIsInputAttacherActive ~= nil and not self.tool:getIsInputAttacherActive(input) then
        return nil
    end
    local x, y, z = getWorldTranslation(joint.jointTransform)
    local ix, iy, iz = getWorldTranslation(input.node)
    local distSq = (x - ix) * (x - ix) + (z - iz) * (z - iz)
    if distSq >= maxDistanceSq or (y - iy) * (y - iy) >= maxDistanceSq * 4 then
        return nil
    end
    if AttacherJoints.getAttacherJointCompatibility ~= nil then
        local ok, compatible = FarmPilotCall(AttacherJoints.getAttacherJointCompatibility, self.vehicle, joint, self.tool, input)
        if not ok or not compatible then
            return nil
        end
    end
    local d
    if input.attachAngleLimitAxis == 1 then
        d = localDirectionToLocal(input.node, joint.jointTransform, 1, 0, 0)
    elseif input.attachAngleLimitAxis == 2 then
        local _, dy = localDirectionToLocal(input.node, joint.jointTransform, 0, 1, 0)
        d = dy
    else
        local _, _, dz = localDirectionToLocal(input.node, joint.jointTransform, 0, 0, 1)
        d = dz
    end
    if d == nil or d <= maxAngle then
        return nil
    end
    return { attacherVehicle = self.vehicle, attacherVehicleJointDescIndex = jointIndex, attachable = self.tool, attachableJointDescIndex = inputIndex }
end

-- attelage du jeu (comme la touche du joueur) quand l'outil est à portée ; distance : entre les points d'attelage
-- (pour le journal). Raté : self.attachWhy dit ce que le jeu répond.
function ADFetchToolTask:tryAttach(distance)
    local maxDistanceSq = AttacherJoints.MAX_ATTACH_DISTANCE_SQ or 1
    local maxAngle = AttacherJoints.MAX_ATTACH_ANGLE or 0.34202
    local attacherVehicle, attacherJointIndex, attachable, attachableJointIndex, warning = AttacherJoints.updateVehiclesInAttachRange(self.vehicle, maxDistanceSq, maxAngle, true)
    local info
    if attachable == self.tool and attacherVehicle == self.vehicle then
        info = {
            attacherVehicle = attacherVehicle,
            attacherVehicleJointDescIndex = attacherJointIndex,
            attachable = attachable,
            attachableJointDescIndex = attachableJointIndex
        }
    else
        info = self:ownAttachInfo(maxDistanceSq, maxAngle)
        if info == nil then
            if attachable == nil then
                self.attachWhy = warning ~= nil and tostring(warning) or "le jeu ne voit pas l'outil à portée d'attelage"
            else
                self.attachWhy = "le jeu propose un autre attelage"
            end
            return false
        end
    end
    if info.attachable.isAttachAllowed ~= nil then
        local farmId = self.vehicle.getActiveFarm ~= nil and self.vehicle:getActiveFarm() or nil
        local allowed, why = info.attachable:isAttachAllowed(farmId, info.attacherVehicle)
        if not allowed then
            self.attachWhy = why ~= nil and tostring(why) or "attelage refusé par l'outil"
            return false
        end
    end
    local carried = self:isCarried()
    if not (carried and self:attachRaised(info)) then
        local accepted = self.vehicle:attachImplementFromInfo(info)
        local attacher = self.tool.getAttacherVehicle ~= nil and self.tool:getAttacherVehicle() or nil
        if not accepted and attacher ~= self.vehicle then
            self.attachWhy = "attelage refusé par le jeu"
            return false
        end
        if carried then
            self:raiseNow()
        end
    end
    if distance ~= nil and distance > self:attachRange() then
        ADAutonomousManager.log("%s : outil « %s » attelé, le tracteur ne se rapprochait plus (points d'attelage à %.2f m)", tostring(self.vehicle.ad.stateModule:getName()), ADAutonomousManager.toolLabel(self.tool), distance)
    else
        ADAutonomousManager.log("%s : outil « %s » attelé", tostring(self.vehicle.ad.stateModule:getName()), ADAutonomousManager.toolLabel(self.tool))
    end
    self:onAttached()
    return true
end

function ADFetchToolTask:onAttached()
    if self.state ~= ADFetchToolTask.STATE_ATTACHED and ADGraphManager.noteGarageExit ~= nil then
        FarmPilotCall(ADGraphManager.noteGarageExit, self.vehicle, self.tool) -- (18/11) la route suivante sort par le garage de l'outil
    end
    if self.state ~= ADFetchToolTask.STATE_ATTACHED then
        self:setState(ADFetchToolTask.STATE_ATTACHED)
    end
end

-- (07/11) mod d'attelage manuel : flexibles et prise de force branchés comme le joueur
function ADFetchToolTask:connectManual()
    local ok, done = FarmPilotCall(ADAutonomousManager.setManualConnections, self.vehicle, self.tool, true)
    if not ok then
        ADAutonomousManager.log("ERREUR flexibles / prise de force : %s", tostring(done))
    elseif #done > 0 then
        ADAutonomousManager.log("%s : branché (%s)", tostring(self.vehicle.ad.stateModule:getName()), table.concat(done, ", "))
    end
end

-- outil relevé, coupé ; le repli pour la route est celui de FarmPilot (réglage « Replier les outils »)
function ADFetchToolTask:prepareForRoad()
    local tool = self.tool
    if tool.getIsTurnedOn ~= nil and tool:getIsTurnedOn() and tool.setIsTurnedOn ~= nil then
        tool:setIsTurnedOn(false)
    end
    local attacher = tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() or nil
    if attacher ~= nil and attacher.getAttacherJointIndexFromObject ~= nil and attacher.setJointMoveDown ~= nil then
        local jointIndex = attacher:getAttacherJointIndexFromObject(tool)
        if jointIndex ~= nil then
            attacher:setJointMoveDown(jointIndex, false)
        end
    end
    AutoDrive.resetFoldState(self.vehicle)
    AutoDrive.getAllVehicleDimensions(self.vehicle, true)
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin de la tâche, collisions, texte du HUD
-- ------------------------------------------------------------------------------------------------------------
function ADFetchToolTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

-- coincé sur la courbe d'entrée (AutonomousMode:onDriveStuck) : elle est lâchée à la prochaine image ; true si
-- c'est bien la courbe qui est suivie
function ADFetchToolTask:onDriveStuck()
    if self.state == ADFetchToolTask.STATE_DRIVING and self.onCurve then
        self.driveStuck = true
        return true
    end
    return false
end

function ADFetchToolTask:abort()
end

-- tout près de l'outil (arrêt, marche arrière) : l'outil n'est pas un obstacle
function ADFetchToolTask:getExcludedVehiclesForCollisionCheck()
    if self.state ~= nil and self.state >= ADFetchToolTask.STATE_STOPPING and self.tool ~= nil then
        return { self.tool }
    end
    return {}
end

function ADFetchToolTask:getI18nInfo()
    if self.state == ADFetchToolTask.STATE_PLANNING then
        return self:getPlanningI18n()
    end
    return "$l10n_AD_task_autonomous_fetch;"
end
