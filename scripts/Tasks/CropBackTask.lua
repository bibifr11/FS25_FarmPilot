-- ============================================================================================================
-- FarmPilot : CropBackTask.lua
-- Benne de MOISSONNEUSE, mode Strict : déchargement fini avec le train dans la culture debout (le nez du tracteur
-- passé devant la ligne de coupe). Elle recule sur son tracé, dans l'axe de la dernière unité, par pas de STEP m,
-- jusqu'à ce que le train entier soit sorti de la culture debout, puis elle recalcule (attente d'appel, nouveau
-- trajet propre). Jamais de « Destruction de la culture », jamais d'attente sans fin le nez dans le blé.
--
-- Historique :
-- - (16/11) champ 52 du Mechet, 7R Gen2 350 + MR Big Body à côté de la Lexion 6900 (1re fourrière le long du
--   muret) : « décharge fini dans la culture », puis 6 calculs « pas de chemin » et « se garer dans le champ » ; il
--   n'a jamais reculé. Ses traces derrière lui (blé d'hiver état 11, écrasé par les roues) comptaient comme du blé
--   debout. Elles comptent comme libres (PathFinderModuleCropMap.lua), et il recule maintenant sur son tracé.
--
-- Règles :
-- - seulement sur son propre tracé : le tracé du tracteur enregistré en marche avant au champ (recordTrail) ; le
--   point derrière la remorque doit en être à TRAIL_RADIUS m au plus. Une trace de roues qui n'est pas la sienne
--   (passage, jalonnage) n'ouvre jamais le recul ;
-- - derrière la dernière unité, sous ses roues (REAR_CHECK m) : sol du champ, pas de culture debout (coupée, fanée
--   ou écrasée par les roues : libre) ; pas de remorque articulée ; capteur d'obstacle arrière ;
-- - MAX m au plus ; bloqué, impossible ou fini : nouveau calcul (attente d'appel), comme avant.
--
-- Branché par : CombineUnloaderMode:getTaskAfterUnload (benne de moissonneuse, Strict, dans la culture : newIfNeeded)
-- et CombineUnloaderMode:monitorTasks (recordTrail). Fin de la tâche : STATE_LEAVE_CROP, attente d'appel.
-- L'ensileuse n'utilise pas ce fichier.
-- ============================================================================================================

CropBackTask = ADInheritsFrom(AbstractTask)

CropBackTask.STEP = 5                -- m per leg; the crop is read again after each one
CropBackTask.MAX = 40                -- m in all
CropBackTask.SPEED = 5               -- km/h
CropBackTask.REAR_CHECK = 3          -- m behind the last unit checked under its wheels
CropBackTask.STUCK_TIME = 3000       -- ms without moving: something behind
CropBackTask.LEG_TIMEOUT = 20000     -- ms per leg
CropBackTask.TRAIL_STEP = 1          -- m between two points of the tractor's trail
CropBackTask.TRAIL_MAX = 150         -- points kept (m of trail)
CropBackTask.TRAIL_RADIUS = 1.2      -- m between the point behind the trailer and the trail
CropBackTask.FOOT_STEP = 1.5         -- m between the crop samples along a unit
CropBackTask.FOOT_INSET = 0.3        -- m inside the unit sides for the crop samples
CropBackTask.MAP_FORGET = 8          -- m beyond the train length where the map is read again (fresh tracks)

-- ------------------------------------------------------------------------------------------------------------
-- Tracé du tracteur (benne de moissonneuse, en marche avant au champ)
-- ------------------------------------------------------------------------------------------------------------
function CropBackTask.recordTrail(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.components == nil then
        return
    end
    -- léger : rien tant qu'il n'a pas roulé TRAIL_STEP m en avant depuis le dernier point
    local speed = (vehicle.lastSpeedReal or 0) * (vehicle.movingDirection or 1)
    if speed <= 0.0005 then
        return
    end
    local x, y, z = getWorldTranslation(vehicle.components[1].node)
    local trail = vehicle.ad.cropTrail
    local last = trail ~= nil and trail[#trail] or nil
    if last ~= nil and MathUtil.vector2Length(x - last.x, z - last.z) < CropBackTask.TRAIL_STEP then
        return
    end
    if AutoDrive.isChopperUnloading(vehicle) or not AutoDrive.checkIsOnField(x, y, z) then
        vehicle.ad.cropTrail = nil
        return
    end
    if trail == nil then
        trail = {}
        vehicle.ad.cropTrail = trail
    end
    table.insert(trail, {x = x, z = z})
    while #trail > CropBackTask.TRAIL_MAX do
        table.remove(trail, 1)
    end
end

-- distance from x, z to the trail (math.huge without trail)
function CropBackTask.distanceToTrail(trail, x, z)
    local best = math.huge
    if trail == nil then
        return best
    end
    for i = 1, #trail do
        local a = trail[i]
        local b = trail[i + 1]
        local d
        if b == nil then
            d = MathUtil.vector2Length(x - a.x, z - a.z)
        else
            local dx, dz = b.x - a.x, b.z - a.z
            local l2 = dx * dx + dz * dz
            local t = l2 > 0 and math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / l2)) or 0
            d = MathUtil.vector2Length(x - (a.x + dx * t), z - (a.z + dz * t))
        end
        if d < best then
            best = d
        end
    end
    return best
end

-- ------------------------------------------------------------------------------------------------------------
-- Train et culture
-- ------------------------------------------------------------------------------------------------------------
function CropBackTask.getUnits(vehicle)
    local units = {vehicle}
    local all = AutoDrive.getAllUnits(vehicle)
    if all ~= nil then
        for _, unit in ipairs(all) do
            if unit ~= vehicle and unit.components ~= nil then
                table.insert(units, unit)
            end
        end
    end
    return units
end

local function unitFrame(unit)
    local node = unit.components[1].node
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local size = unit.size or {}
    return x, z, dx, dz, size.length or 6, size.width or 3, size.lengthOffset or 0
end

-- standing crop under the train (field map: cut, withered and crushed by the wheels count as none): true, x, z
function CropBackTask.isTrainInStandingCrop(vehicle)
    for _, unit in ipairs(CropBackTask.getUnits(vehicle)) do
        local x, z, dx, dz, length, width, offset = unitFrame(unit)
        local half = math.max(0.2, width / 2 - CropBackTask.FOOT_INSET)
        local n = math.max(1, math.ceil(length / CropBackTask.FOOT_STEP))
        for i = 0, n do
            local l = offset - length / 2 + length * i / n
            for _, side in ipairs({-1, 0, 1}) do
                local px, pz = x + dx * l - dz * half * side, z + dz * l + dx * half * side
                if PathFinderModule.getMapCropAt(px, pz) ~= 0 then
                    return true, px, pz
                end
            end
        end
    end
    return false
end

-- lateral offsets of the wheels of the train (outer edges known from the wheels, else the unit sides less 0.5 m)
function CropBackTask.getWheelLanes(vehicle)
    local lanes, seen = {}, {}
    local function add(v)
        local key = math.floor(v * 10 + 0.5)
        if not seen[key] and v > 0.2 then
            seen[key] = true
            table.insert(lanes, v)
        end
    end
    for _, unit in ipairs(CropBackTask.getUnits(vehicle)) do
        local found = false
        local spec = unit.spec_wheels
        local root = unit.components[1].node
        if spec ~= nil and spec.wheels ~= nil and localToLocal ~= nil then
            for _, wheel in pairs(spec.wheels) do
                local physics = wheel.physics
                if physics ~= nil and wheel.node ~= nil and physics.positionX ~= nil then
                    local wx = localToLocal(wheel.node, root, physics.positionX, physics.positionY or 0, physics.positionZ or 0)
                    add(math.abs(wx))
                    found = true
                end
            end
        end
        if not found then
            add(((unit.size ~= nil and unit.size.width) or 3) / 2 - 0.5)
        end
    end
    return lanes
end

-- why the train cannot back off along its trail from here, nil if it can
function CropBackTask.getRearBlock(vehicle)
    if ADTrafficYieldModule ~= nil and ADTrafficYieldModule.cannotReverse ~= nil and ADTrafficYieldModule.cannotReverse(vehicle) then
        return "remorque articulee"
    end
    local units = CropBackTask.getUnits(vehicle)
    local x, z, dx, dz, length, _, offset = unitFrame(units[#units])
    local lanes = CropBackTask.getWheelLanes(vehicle)
    local trail = vehicle.ad.cropTrail
    if trail == nil or #trail < 3 then
        return "pas de trace enregistree"
    end
    for d = 1, CropBackTask.REAR_CHECK do
        local back = length / 2 - offset + d
        local cx, cz = x - dx * back, z - dz * back
        if CropBackTask.distanceToTrail(trail, cx, cz) > CropBackTask.TRAIL_RADIUS then
            return string.format("hors de son trace a %d m derriere la remorque", d)
        end
        for _, lane in ipairs(lanes) do
            for _, side in ipairs({-1, 1}) do
                local px, pz = cx - dz * lane * side, cz + dx * lane * side
                if not AutoDrive.checkIsOnField(px, 0, pz) then
                    return string.format("bord du champ a %d m derriere la remorque", d)
                end
                if PathFinderModule.getMapCropAt(px, pz) ~= 0 then
                    return string.format("culture debout sous les roues a %d m derriere la remorque (%.0f,%.0f)", d, px, pz)
                end
            end
        end
    end
    local cdm = vehicle.ad.collisionDetectionModule
    if cdm ~= nil and cdm.checkReverseCollision ~= nil and cdm:checkReverseCollision() then
        return "obstacle derriere (capteur)"
    end
    return nil
end

-- the fresh tracks of the train are read again from the density map
function CropBackTask.refreshMap(vehicle)
    if PathFinderModule.forgetMapAround == nil then
        return
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local length = AutoDrive.getTractorTrainLength ~= nil and AutoDrive.getTractorTrainLength(vehicle, true, false) or 20
    PathFinderModule.forgetMapAround(x, z, (length or 20) + CropBackTask.MAP_FORGET)
end

-- ------------------------------------------------------------------------------------------------------------
-- La tâche
-- ------------------------------------------------------------------------------------------------------------
-- the task when the train stands in the standing crop and can back off along its trail; else nil and why
function CropBackTask.newIfNeeded(vehicle, combine)
    CropBackTask.refreshMap(vehicle)
    local inCrop, cx, cz = CropBackTask.isTrainInStandingCrop(vehicle)
    if not inCrop then
        return nil, "train hors de la culture debout (traces ecrasees ou bord coupe)", false
    end
    local why = CropBackTask.getRearBlock(vehicle)
    if why ~= nil then
        return nil, string.format("culture debout en %.0f,%.0f, recul sur son trace impossible : %s", cx, cz, why), true
    end
    return CropBackTask:new(vehicle, combine), string.format("culture debout en %.0f,%.0f", cx, cz), true
end

function CropBackTask:new(vehicle, combine)
    local o = CropBackTask:create()
    o.vehicle = vehicle
    o.combine = combine
    o.total = 0
    return o
end

function CropBackTask.getLogName(vehicle)
    return tostring(vehicle:getName())
end

function CropBackTask:setUp()
    self:startLeg()
end

function CropBackTask:startLeg()
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local units = CropBackTask.getUnits(self.vehicle)
    local lx, lz, dx, dz = unitFrame(units[#units])
    self.legStart = {x = x, z = z}
    self.last = {x = x, z = z}
    self.legTime = 0
    self.stuck = 0
    local ly = getTerrainHeightAtWorldPos ~= nil and g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil
        and getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, lx, 0, lz) or 0
    self.target = {x = lx - dx * 100, y = ly, z = lz - dz * 100}
end

function CropBackTask:stop(dt)
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm:stopVehicle()
    sdm:update(dt)
end

function CropBackTask:done(dt, text)
    print(string.format("[AD-Fin] %s: recul sur son trace : %s (%.1f m en tout), nouveau calcul", CropBackTask.getLogName(self.vehicle), text, self.total))
    self:stop(dt)
    self:finished()
end

function CropBackTask:update(dt)
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local leg = MathUtil.vector2Length(x - self.legStart.x, z - self.legStart.z)
    self.legTime = self.legTime + dt
    if MathUtil.vector2Length(x - self.last.x, z - self.last.z) > 0.3 then
        self.last = {x = x, z = z}
        self.stuck = 0
    else
        self.stuck = self.stuck + dt
    end
    if self.total + leg >= CropBackTask.MAX - 0.05 then
        self.total = self.total + leg
        return self:done(dt, string.format("%d m recules, maximum", CropBackTask.MAX))
    end
    if leg >= CropBackTask.STEP - 0.05 then
        -- (16/11) un pas fait : la culture relue (traces fraîches), sorti du blé debout = fini
        self.total = self.total + leg
        CropBackTask.refreshMap(self.vehicle)
        local inCrop, cx, cz = CropBackTask.isTrainInStandingCrop(self.vehicle)
        if not inCrop then
            return self:done(dt, "sorti de la culture debout")
        end
        print(string.format("[AD-Fin] %s: recul sur son trace, pas de %d m fait (%.1f m en tout), encore de la culture debout en %.0f,%.0f, je continue",
            CropBackTask.getLogName(self.vehicle), CropBackTask.STEP, self.total, cx, cz))
        self:startLeg()
        return
    end
    local block = CropBackTask.getRearBlock(self.vehicle)
    if block ~= nil then
        self.total = self.total + leg
        return self:done(dt, "arrete (" .. block .. ")")
    end
    if self.stuck > CropBackTask.STUCK_TIME then
        self.total = self.total + leg
        return self:done(dt, "ne recule plus (obstacle derriere ?)")
    end
    if self.legTime > CropBackTask.LEG_TIMEOUT then
        self.total = self.total + leg
        return self:done(dt, "recul trop long")
    end
    local sdm = self.vehicle.ad.specialDrivingModule
    sdm.reverseTarget = self.target
    sdm:driveReverse(dt, CropBackTask.SPEED, 1, self.vehicle.ad.trailerModule:canBeHandledInReverse())
end

function CropBackTask:abort()
end

function CropBackTask:finished()
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function CropBackTask:getI18nInfo()
    return "$l10n_AD_task_reversing_from_collision;"
end
