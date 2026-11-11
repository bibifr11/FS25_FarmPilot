-- ============================================================================================================
-- FarmPilot : FrontPlaceTask.lua
-- Mode Autonome : tâche « aller poser l'outil AVANT à côté d'un outil posé », sans ligne au sol, et tâche
-- « reculer tout droit » après un dételage à l'avant.
--
-- Règle (10/11) :
-- - Combiné avant + arrière (faucheuse avant + arrière...) : l'outil arrière vient d'être posé à sa place en marche
--   arrière. L'outil avant se pose À CÔTÉ, parallèle, son point d'attelage au niveau de celui de l'outil arrière,
--   GAP m entre les deux : le tracteur ressort, fait demi-tour (recherche de chemin) et entre le nez en avant.
-- - Outil avant sans place à échanger contre un autre : posé de la même façon à côté de l'outil avant à prendre.
-- - Côté : celui où il n'y a rien (véhicules, outils), le plus proche du tracteur d'abord ; rien de libre = échec
--   (« noRoom »), l'outil avant reste attelé.
-- - Pas de chemin : il avance (ou recule) de quelques mètres et recalcule, au plus ROOM_MOVES fois (comme
--   l'attelage), puis échec (« noPath »).
-- - Après un dételage à l'avant, l'outil est contre le nez du tracteur : il recule tout droit de BACK_DISTANCE m
--   avant de repartir (ADFrontBackOffTask). (10/11 soir) Il est alors face à l'outil ou au fond de la place : plus
--   de demi-tour sur place. Le recul est allongé s'il le faut, puis une courbe calculée le mène sur une route en
--   marche avant (Modes/AutonomousNoseIn.lua : exitPlan, exitPath) ; pas de courbe possible : comme avant.
-- - (10/11 soir) Outil avant sans place : posé DEVANT l'outil arrière, dans la place de celui-ci (newAt avec
--   slot.aheadTool) ; l'outil arrière n'est pas un obstacle pendant l'approche.
-- - Masse (10/11, ADFrontPlaceTask:newAt) : posée au fond de la place de parking du tracteur en y entrant le NEZ EN
--   AVANT (la ligne de la place prise à l'envers), puis recul sur la même ligne jusqu'à en être sorti.
-- Le résultat (self.result = "ok" ou la raison de l'échec) est lu par Modes/AutonomousFront.lua.
--
-- Branché par : Modes/AutonomousFront.lua (dépose de l'outil avant : ADFrontPlaceTask:new, ADFrontBackOffTask:new).
-- ============================================================================================================

ADFrontPlaceTask = ADInheritsFrom(AbstractTask)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFrontPlaceTask.STATE_PLAN = 1
ADFrontPlaceTask.STATE_PLANNING = 2
ADFrontPlaceTask.STATE_DRIVING = 3
ADFrontPlaceTask.STATE_STOPPING = 4
ADFrontPlaceTask.STATE_APPROACH = 5
ADFrontPlaceTask.STATE_ROOM = 6

ADFrontPlaceTask.GAP = 1               -- m entre l'outil arrière posé et l'outil avant
ADFrontPlaceTask.FREE_MARGIN = 0.5     -- m autour de la place de l'outil avant qui doivent être libres
ADFrontPlaceTask.ENTRY = 10            -- m devant la place (en plus du tracteur et de l'outil) où le chemin arrive
ADFrontPlaceTask.LOOK_AHEAD = 5        -- m : en entrant, on vise un point de l'axe à ça devant l'attelage avant
ADFrontPlaceTask.STOP_AT = 0.15        -- m : attelage avant à ça du point visé = arrivé
ADFrontPlaceTask.APPROACH_TIMEOUT = 60000 -- ms
ADFrontPlaceTask.STOP_TIMEOUT = 8000   -- ms
ADFrontPlaceTask.CURVE_STUCK_TIME = 10000 -- ms arrêté sur la courbe d'entrée (AutonomousNoseIn.lua) : recherche de chemin
ADFrontPlaceTask.ROOM_DISTANCE = 8     -- m tout droit quand il n'y a pas de chemin
ADFrontPlaceTask.ROOM_MOVES = 2
ADFrontPlaceTask.ROOM_SPEED = 5        -- km/h
ADFrontPlaceTask.ROOM_TIMEOUT = 20000  -- ms
ADFrontPlaceTask.BLOCKED_NEAR = 3      -- m : place du tracteur, obstacle devant à moins de ça du fond = on s'arrête là

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
-- tool : outil avant (ou masse) attelé ; rearTool : l'outil posé à côté duquel il va (outil arrière qui vient d'être
-- posé, ou outil avant à atteler ensuite : refSide = « front »)
function ADFrontPlaceTask:new(vehicle, tool, rearTool, refSide)
    local o = ADFrontPlaceTask:create()
    o.vehicle = vehicle
    o.tool = tool
    o.rearTool = rearTool
    o.refSide = refSide
    o.result = nil
    return o
end

-- place donnée d'avance (masse à la place du tracteur) : slot = { x, y, z, dirX, dirZ } (attelage avant du tracteur à
-- l'arrivée, direction de la place vers la sortie) ; placeName : nom de la place pour le journal
function ADFrontPlaceTask:newAt(vehicle, tool, slot, placeName)
    local o = ADFrontPlaceTask:new(vehicle, tool, nil, nil)
    o.presetSlot = slot
    o.placeName = placeName
    o.aheadTool = slot.aheadTool -- outil arrière rangé au fond : l'outil avant se pose devant lui
    return o
end

-- nom de ce à côté de quoi on pose (journal)
function ADFrontPlaceTask:refName()
    if self.rearTool ~= nil then
        return ADAutonomousManager.toolLabel(self.rearTool)
    end
    return "place " .. tostring(self.placeName)
end

function ADFrontPlaceTask:setUp()
    self.state = ADFrontPlaceTask.STATE_PLAN
    self.timer = 0
    self.roomMoves = 0
    self.slot = nil
    self.blockedAhead = false
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

function ADFrontPlaceTask:setState(state)
    self.state = state
    self.timer = 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Place de l'outil avant à côté de l'outil arrière
-- ------------------------------------------------------------------------------------------------------------
local function sizeOf(v)
    local s = v ~= nil and v.size or nil
    return (s ~= nil and s.width) or 3, (s ~= nil and s.length) or 3
end

-- rien (autre que le tracteur et ses outils) dans le rectangle : centre (cx, cz), axe (dx, dz), demi-longueur hl,
-- demi-largeur hw
function ADFrontPlaceTask.isFree(vehicle, cx, cz, dx, dz, hl, hw)
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system == nil or system.vehicles == nil then
        return true
    end
    local own = {}
    own[vehicle] = true
    for _, o in ipairs(AutoDrive.getAllImplements(vehicle) or {}) do
        own[o] = true
    end
    for _, v in pairs(system.vehicles) do
        if not own[v] and v.components ~= nil and v.components[1] ~= nil and not v.isDeleted then
            local x, _, z = getWorldTranslation(v.components[1].node)
            local w, l = sizeOf(v)
            local r = math.min(w, l) / 2
            local ox, oz = x - cx, z - cz
            local along = math.abs(ox * dx + oz * dz)
            local side = math.abs(ox * dz - oz * dx)
            if along < hl + r and side < hw + r then
                return false
            end
        end
    end
    return true
end

-- { x, z, dirX, dirZ } : où l'attelage avant du tracteur doit arriver (point d'attelage de l'outil avant posé), et
-- direction de l'outil vers le tracteur ; nil si pas de place libre
function ADFrontPlaceTask:findSlot()
    local hitch
    if self.refSide == "front" then
        -- à côté de l'outil avant à atteler ensuite (échange d'outils avant)
        hitch = ADAutonomousManager.frontHitch(self.vehicle, self.rearTool, true)
    else
        hitch = ADAutonomousManager.toolHitch(self.vehicle, self.rearTool)
    end
    if hitch == nil then
        return nil
    end
    local rw = sizeOf(self.rearTool)
    local fw, fl = sizeOf(self.tool)
    local offset = rw / 2 + fw / 2 + ADFrontPlaceTask.GAP
    local sx, sz = hitch.dirZ, -hitch.dirX
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local sides = { 1, -1 }
    -- le côté le plus proche du tracteur d'abord
    if (vx - hitch.x) * sx + (vz - hitch.z) * sz < 0 then
        sides = { -1, 1 }
    end
    for _, sign in ipairs(sides) do
        local px, pz = hitch.x + sx * offset * sign, hitch.z + sz * offset * sign
        local cx, cz = px - hitch.dirX * fl / 2, pz - hitch.dirZ * fl / 2
        if ADFrontPlaceTask.isFree(self.vehicle, cx, cz, hitch.dirX, hitch.dirZ, fl / 2 + ADFrontPlaceTask.FREE_MARGIN, fw / 2 + ADFrontPlaceTask.FREE_MARGIN) then
            return { x = px, y = hitch.y, z = pz, dirX = hitch.dirX, dirZ = hitch.dirZ, sign = sign }
        end
    end
    return nil
end

-- attelage avant du tracteur où l'outil avant est attelé (position monde)
function ADFrontPlaceTask:frontJointPos()
    local attacher = self.tool.getAttacherVehicle ~= nil and self.tool:getAttacherVehicle() or nil
    local index = attacher ~= nil and attacher.getAttacherJointIndexFromObject ~= nil and attacher:getAttacherJointIndexFromObject(self.tool) or nil
    local joint = index ~= nil and attacher.spec_attacherJoints ~= nil and attacher.spec_attacherJoints.attacherJoints[index] or nil
    if joint == nil or joint.jointTransform == nil then
        return nil
    end
    local x, y, z = getWorldTranslation(joint.jointTransform)
    return { x = x, y = y, z = z }
end

-- ------------------------------------------------------------------------------------------------------------
-- À chaque image (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function ADFrontPlaceTask:holdVehicle(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
end

function ADFrontPlaceTask:update(dt)
    self.timer = self.timer + dt
    if self.tool == nil or self.tool.isDeleted or self.tool.getAttacherVehicle == nil or self.tool:getAttacherVehicle() == nil then
        self:holdVehicle(dt)
        self:finish("gone")
        return
    end
    local name = tostring(self.vehicle.ad.stateModule:getName())
    if self.state == ADFrontPlaceTask.STATE_PLAN then
        self:holdVehicle(dt)
        self.slot = self.presetSlot or self:findSlot()
        if self.slot == nil then
            ADAutonomousManager.log("%s : pas de place libre à côté de « %s » pour « %s »", name, self:refName(), ADAutonomousManager.toolLabel(self.tool))
            self:finish("noRoom")
            return
        end
        -- (10/11) place prise en marche arrière : pas de recherche de chemin (demi-tour hors des routes, bloqué contre
        -- un bâtiment), une courbe calculée depuis la route qui passe devant, voir Modes/AutonomousNoseIn.lua
        if self.presetSlot ~= nil and self.presetSlot.place ~= nil and ADNoseIn ~= nil and not self.noseTried then
            self.noseTried = true
            local ok, path, c = FarmPilotCall(ADNoseIn.pathFromVehicle, self.vehicle, self.presetSlot.place, self.tool, self.presetSlot.ahead)
            if ok and path ~= nil and #path > 0 then
                self.vehicle.ad.drivePathModule:setWayPoints(path)
                ADAutonomousManager.log("%s : « %s » posé au fond de « %s », entrée en courbe (%.0f° puis %.0f°, %.1f m, rayon %.1f m)", name,
                    ADAutonomousManager.toolLabel(self.tool), tostring(self.placeName), math.deg(c.arc1), math.deg(c.arc2), c.length, c.radius)
                self.onCurve = true
                self.curveStuck = 0
                self:setState(ADFrontPlaceTask.STATE_DRIVING)
                return
            end
            ADAutonomousManager.log("%s : pas de courbe d'ici vers « %s » (%s), recherche de chemin", name, tostring(self.placeName), ok and "trop serrée, trop longue ou trop loin des routes" or tostring(path))
        end
        local _, vl = sizeOf(self.vehicle)
        local _, fl = sizeOf(self.tool)
        local d = vl + fl + ADFrontPlaceTask.ENTRY
        local entry = { x = self.slot.x + self.slot.dirX * d, y = self.slot.y, z = self.slot.z + self.slot.dirZ * d }
        local pf = self.vehicle.ad.pathFinderModule
        pf:reset()
        pf:startPathPlanningTo(entry, { x = -self.slot.dirX, z = -self.slot.dirZ })
        if self.presetSlot ~= nil then
            ADAutonomousManager.log("%s : « %s » posé au fond de « %s », entrée en marche avant, chemin vers l'entrée (%.0f, %.0f)", name,
                ADAutonomousManager.toolLabel(self.tool), tostring(self.placeName), entry.x, entry.z)
        else
            ADAutonomousManager.log("%s : « %s » posé à %s de « %s », chemin vers l'entrée (%.0f, %.0f)", name, ADAutonomousManager.toolLabel(self.tool),
                self.slot.sign > 0 and "droite" or "gauche", self:refName(), entry.x, entry.z)
        end
        self:setState(ADFrontPlaceTask.STATE_PLANNING)
    elseif self.state == ADFrontPlaceTask.STATE_PLANNING then
        local pf = self.vehicle.ad.pathFinderModule
        if pf:hasFinished() then
            local path = pf:getPath()
            if path == nil or #path == 0 then
                if self:startRoom() then
                    return
                end
                self:finish("noPath")
                return
            end
            self.vehicle.ad.drivePathModule:setWayPoints(path)
            self:setState(ADFrontPlaceTask.STATE_DRIVING)
        else
            pf:update(dt)
            self:holdVehicle(dt)
        end
    elseif self.state == ADFrontPlaceTask.STATE_DRIVING then
        local dpm = self.vehicle.ad.drivePathModule
        if dpm:isTargetReached() then
            self.onCurve = false
            self:setState(ADFrontPlaceTask.STATE_STOPPING)
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
                if self.curveStuck >= ADFrontPlaceTask.CURVE_STUCK_TIME or self.driveStuck then
                    ADAutonomousManager.log("%s : arrêté sur la courbe vers « %s » (passage occupé), recherche de chemin", name, tostring(self.placeName))
                    self.driveStuck = nil
                    self.onCurve = false
                    self:setState(ADFrontPlaceTask.STATE_PLAN)
                end
            end
        end
    elseif self.state == ADFrontPlaceTask.STATE_STOPPING then
        self:holdVehicle(dt)
        if math.abs(self.vehicle.lastSpeedReal) < 0.0015 or self.timer > ADFrontPlaceTask.STOP_TIMEOUT then
            self:setState(ADFrontPlaceTask.STATE_APPROACH)
        end
    elseif self.state == ADFrontPlaceTask.STATE_APPROACH then
        self:updateApproach(dt)
    elseif self.state == ADFrontPlaceTask.STATE_ROOM then
        self:updateRoom(dt)
    end
end

-- en avant dans l'axe de la place jusqu'à ce que l'attelage avant soit au point de la place
function ADFrontPlaceTask:updateApproach(dt)
    local joint = self:frontJointPos()
    local slot = self.slot
    if joint == nil then
        self:holdVehicle(dt)
        self:finish("noJoint")
        return
    end
    local along = (joint.x - slot.x) * slot.dirX + (joint.z - slot.z) * slot.dirZ
    -- (pas devant un outil arrière rangé au fond : c'est lui que le capteur verrait)
    if not self.blockedAhead and self.presetSlot ~= nil and self.aheadTool == nil and along <= ADFrontPlaceTask.BLOCKED_NEAR then
        -- place du tracteur : un mur ou un objet devant avant le fond calculé = posé là
        local v = self.vehicle
        if v.ad.sensors ~= nil and v.ad.sensors.frontSensor ~= nil and v.ad.sensors.frontSensor:pollInfo() == true then
            self.blockedAhead = true
            ADAutonomousManager.log("%s : obstacle devant à %.1f m du fond de la place, « %s » posé ici", tostring(v.ad.stateModule:getName()), along,
                ADAutonomousManager.toolLabel(self.tool))
        end
    end
    if along <= ADFrontPlaceTask.STOP_AT or self.blockedAhead then
        self:holdVehicle(dt)
        if math.abs(self.vehicle.lastSpeedReal) < 0.0015 then
            local lateral = math.abs((joint.x - slot.x) * slot.dirZ - (joint.z - slot.z) * slot.dirX)
            if self.aheadTool ~= nil then
                ADAutonomousManager.log("%s : « %s » dans « %s », devant « %s » (écart %.2f m)", tostring(self.vehicle.ad.stateModule:getName()), ADAutonomousManager.toolLabel(self.tool), tostring(self.placeName),
                    ADAutonomousManager.toolLabel(self.aheadTool), lateral)
            elseif self.presetSlot ~= nil then
                ADAutonomousManager.log("%s : « %s » au fond de « %s » (écart %.2f m)", tostring(self.vehicle.ad.stateModule:getName()), ADAutonomousManager.toolLabel(self.tool), tostring(self.placeName), lateral)
            else
                ADAutonomousManager.log("%s : « %s » à sa place à côté de « %s » (écart %.2f m)", tostring(self.vehicle.ad.stateModule:getName()), ADAutonomousManager.toolLabel(self.tool), self:refName(), lateral)
            end
            self:finish("ok")
        end
        return
    end
    if self.timer > ADFrontPlaceTask.APPROACH_TIMEOUT then
        self:holdVehicle(dt)
        self:finish("timeout")
        return
    end
    local aim = math.max(along - ADFrontPlaceTask.LOOK_AHEAD, -1)
    local target = { x = slot.x + slot.dirX * aim, y = slot.y, z = slot.z + slot.dirZ * aim }
    local maxSpeed = math.min(6, math.max(1.5, along * 0.6))
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, target, 1, false, 0.6, maxSpeed, true)
end

-- pas de chemin : tout droit en avant (en arrière si l'avant est bloqué), puis nouveau calcul
function ADFrontPlaceTask:startRoom()
    if self.roomMoves >= ADFrontPlaceTask.ROOM_MOVES then
        return false
    end
    local v = self.vehicle
    local frontBlocked = v.ad.sensors ~= nil and v.ad.sensors.frontSensor ~= nil and v.ad.sensors.frontSensor:pollInfo() == true
    local dir = 1
    if frontBlocked then
        if v.ad.collisionDetectionModule:checkReverseCollision() then
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
    v.ad.specialDrivingModule:releaseVehicle()
    ADAutonomousManager.log("%s : pas de chemin vers la place de l'outil avant, on %s de %d m puis nouveau calcul (%d/%d)", tostring(v.ad.stateModule:getName()),
        dir > 0 and "avance" or "recule", ADFrontPlaceTask.ROOM_DISTANCE, self.roomMoves, ADFrontPlaceTask.ROOM_MOVES)
    self:setState(ADFrontPlaceTask.STATE_ROOM)
    return true
end

function ADFrontPlaceTask:updateRoom(dt)
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
    if done >= ADFrontPlaceTask.ROOM_DISTANCE or blocked or self.timer >= ADFrontPlaceTask.ROOM_TIMEOUT then
        self:holdVehicle(dt)
        self:setState(ADFrontPlaceTask.STATE_PLAN)
        return
    end
    if self.roomDir > 0 then
        sdm:driveToPoint(dt, self.roomTarget, ADFrontPlaceTask.ROOM_SPEED, false, 0.6, ADFrontPlaceTask.ROOM_SPEED, true)
    else
        sdm.reverseNode = sdm:getReverseNode()
        if sdm.reverseNode == nil then
            self:holdVehicle(dt)
            self:setState(ADFrontPlaceTask.STATE_PLAN)
            return
        end
        sdm.reverseTarget = self.roomTarget
        sdm.currentWayPointIndex = 0
        sdm.wayPoints = {}
        sdm:getBasicStates()
        sdm:reverseToPoint(dt, ADFrontPlaceTask.ROOM_SPEED)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin de la tâche, collisions, texte du HUD
-- ------------------------------------------------------------------------------------------------------------
function ADFrontPlaceTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADFrontPlaceTask:abort()
end

-- coincé sur la courbe d'entrée (AutonomousMode:onDriveStuck) : elle est lâchée à la prochaine image ; true si
-- c'est bien la courbe qui est suivie
function ADFrontPlaceTask:onDriveStuck()
    if self.state == ADFrontPlaceTask.STATE_DRIVING and self.onCurve then
        self.driveStuck = true
        return true
    end
    return false
end

-- l'outil arrière posé à côté (ou au fond de la place, devant lequel on pose) n'est pas un obstacle en entrant
function ADFrontPlaceTask:getExcludedVehiclesForCollisionCheck()
    local other = self.rearTool or self.aheadTool
    if self.state == ADFrontPlaceTask.STATE_APPROACH and other ~= nil then
        return { other }
    end
    return {}
end

function ADFrontPlaceTask:getI18nInfo()
    if self.state == ADFrontPlaceTask.STATE_PLANNING then
        return self:getPlanningI18n()
    end
    return "$l10n_AD_task_autonomous_frontPlace;"
end

-- ============================================================================================================
-- Reculer tout droit après un dételage ou un attelage à l'avant, puis rejoindre une route
-- ============================================================================================================
ADFrontBackOffTask = ADInheritsFrom(AbstractTask)

ADFrontBackOffTask.BACK_DISTANCE = 8   -- m
ADFrontBackOffTask.SPEED = 4           -- km/h
ADFrontBackOffTask.TIMEOUT = 15000     -- ms
ADFrontBackOffTask.EXIT_STUCK_TIME = 10000 -- ms arrêté sur la courbe de sortie (passage occupé) : on s'arrête là
ADFrontBackOffTask.EXIT_TIMEOUT = 90000    -- ms

-- exit : true = après le recul, rejoindre une route en marche avant par une courbe calculée (recul allongé s'il le
-- faut), voir Modes/AutonomousNoseIn.lua ; tool : l'outil attelé à l'avant (sa largeur), ou nil
function ADFrontBackOffTask:new(vehicle, distance, exit, tool)
    local o = ADFrontBackOffTask:create()
    o.vehicle = vehicle
    o.distance = distance or ADFrontBackOffTask.BACK_DISTANCE
    o.exit = exit == true
    o.tool = tool
    o.result = nil
    return o
end

function ADFrontBackOffTask:setUp()
    self.timer = 0
    self.driving = false
    self.exitPlan = nil
    local name = tostring(self.vehicle.ad.stateModule:getName())
    if self.exit and ADNoseIn ~= nil then
        local ok, plan = FarmPilotCall(ADNoseIn.exitPlan, self.vehicle, self.distance, self.tool)
        if not ok then
            ADAutonomousManager.log("ERREUR sortie en courbe : %s", tostring(plan))
        elseif plan ~= nil then
            ADAutonomousManager.log("%s : recul de %.0f m (au moins %.0f), puis courbe (%.0f° puis %.0f°, %.1f m) vers la route, point %s", name, plan.back, self.distance,
                math.deg(plan.curve.arc1), math.deg(plan.curve.arc2), plan.curve.length, tostring(plan.wp.id))
            self.exitPlan = plan
            self.distance = plan.back
        else
            ADAutonomousManager.log("%s : pas de courbe vers une route d'ici, recul de %.0f m", name, self.distance)
        end
    end
    -- au pas : 4 km/h = 1,1 m/s, plus 10 s de marge
    self.timeout = math.max(ADFrontBackOffTask.TIMEOUT, (self.distance / (ADFrontBackOffTask.SPEED / 3.6) + 10) * 1000)
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    self.start = { x = x, z = z }
    local tx, ty, tz = AutoDrive.localToWorld(self.vehicle, 0, 0, -100)
    self.target = { x = tx, y = ty, z = tz }
    self.vehicle.ad.specialDrivingModule:releaseVehicle()
end

function ADFrontBackOffTask:finish()
    if self.result ~= nil then
        return
    end
    self.result = "ok"
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADFrontBackOffTask:update(dt)
    self.timer = self.timer + dt
    local v = self.vehicle
    local sdm = v.ad.specialDrivingModule
    local name = tostring(v.ad.stateModule:getName())
    if self.driving then
        -- la courbe vers la route
        local dpm = v.ad.drivePathModule
        if dpm:isTargetReached() then
            ADAutonomousManager.log("%s : sur la route, la suite par le réseau", name)
            -- les routes calculées d'ici partent du point rejoint, pas d'un point cherché devant le nez, voir GraphManagerStart.lua
            if self.exitWayPointId ~= nil and ADGraphManager.setJoinedWayPoint ~= nil then
                ADGraphManager.setJoinedWayPoint(v, self.exitWayPointId)
            end
            self:finish()
            return
        end
        dpm:update(dt)
        if math.abs(v.lastSpeedReal or 0) < 0.0003 then
            self.stuck = (self.stuck or 0) + dt
        else
            self.stuck = 0
        end
        if self.stuck >= ADFrontBackOffTask.EXIT_STUCK_TIME or self.driveStuck or self.timer >= ADFrontBackOffTask.EXIT_TIMEOUT then
            ADAutonomousManager.log("%s : arrêté sur la courbe de sortie (passage occupé), la suite d'ici", name)
            sdm:stopVehicle()
            sdm:update(dt)
            self:finish()
        end
        return
    end
    local x, _, z = getWorldTranslation(v.components[1].node)
    local done = MathUtil.vector2Length(x - self.start.x, z - self.start.z)
    sdm.reverseNode = sdm:getReverseNode()
    if done >= self.distance or self.timer >= self.timeout or sdm.reverseNode == nil
        or v.ad.collisionDetectionModule:checkReverseCollision() == true then
        sdm:stopVehicle()
        sdm:update(dt)
        if math.abs(v.lastSpeedReal) < 0.0015 or self.timer >= self.timeout then
            local plan = self.exitPlan
            self.exitPlan = nil
            if plan ~= nil then
                local ok, path, c = FarmPilotCall(ADNoseIn.exitPath, v, plan, self.tool)
                if ok and path ~= nil and #path > 0 then
                    ADAutonomousManager.log("%s : recul de %.1f m fait, courbe vers la route (%.0f° puis %.0f°, %.1f m), point %s", name, done, math.deg(c.arc1), math.deg(c.arc2),
                        c.length, tostring(plan.wp.id))
                    v.ad.drivePathModule:setWayPoints(path)
                    self.exitWayPointId = plan.wp.id
                    self.driving = true
                    self.timer = 0
                    self.stuck = 0
                    return
                end
                ADAutonomousManager.log("%s : recul de %.1f m fait, plus de courbe vers la route d'ici (%s), la suite d'ici", name, done, ok and "trop serrée ou passage occupé" or tostring(path))
            end
            self:finish()
        end
        return
    end
    sdm.reverseTarget = self.target
    sdm.currentWayPointIndex = 0
    sdm.wayPoints = {}
    sdm:getBasicStates()
    sdm:reverseToPoint(dt, ADFrontBackOffTask.SPEED)
end

-- coincé sur la courbe de sortie (AutonomousMode:onDriveStuck) : la tâche finit là, la suite d'où il est
function ADFrontBackOffTask:onDriveStuck()
    if self.driving and self.result == nil then
        self.driveStuck = true
        return true
    end
    return false
end

function ADFrontBackOffTask:abort()
end

function ADFrontBackOffTask:getI18nInfo()
    return "$l10n_AD_task_autonomous_backOff;"
end
