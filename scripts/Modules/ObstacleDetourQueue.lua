-- ============================================================================================================
-- FarmPilot : ObstacleDetourQueue.lua
-- Complément de ObstacleDetourModule.lua (contournement d'un obstacle) et de AvoidModule.lua (écart) : un
-- véhicule arrêté devant moi, sur ma route et dans mon sens, qui attend son tour (file, pont-bascule,
-- déchargement, conducteur au volant), on attend derrière lui. Branché par la dernière ligne de
-- ObstacleDetourModule.lua et de AvoidModule.lua.
--
-- (08/11) Le Volvo FH16 a voulu contourner un tracteur + remorque arrêté sur le
-- pont-bascule au lieu d'attendre derrière.
--
-- Pourquoi : ObstacleDetourModule traite un véhicule arrêté devant comme un obstacle fixe dès qu'il reste
-- immobile 45 s (5 s s'il est garé moteur coupé) : recul puis contournement calculé. Au log du 08/11 à 17:05 :
-- Patriot derrière le semoir 'Momentum 18', « obstacle is a vehicle, keep waiting (5 s) » puis un essai de
-- contournement toutes les 3 s. Une pesée AutoDrive (Weighing.lua) tient 5 s à l'arrêt, mais l'approche à
-- 5 km/h, le centrage, une pesée à la main ou une file devant le pont dépassent vite 45 s.
--
-- Règle : véhicule devant (capteur de route jusqu'à 12 m, sinon capteur avant), tourné dans mon sens (à 60°
-- près), et
--   - sur un pont-bascule (un élément de l'attelage dans le déclencheur du pont), ou
--   - conduit : AutoDrive actif, ouvrier ou Courseplay, joueur au volant, ou
--   - arrêté lui-même derrière un autre véhicule arrêté dans mon sens (file),
-- = file d'attente : j'attends derrière, sans horloge, sans recul, sans contournement ni écart. Le filet
-- « coincé » ou « pousse » ne lance pas non plus de contournement.
-- Rien ne change pour un objet fixe ni pour un véhicule garé (personne dedans, ni AutoDrive ni ouvrier) hors
-- d'une file : contourné après 5 s moteur coupé, 45 s moteur tournant.
-- ============================================================================================================

ADObstacleDetourQueue = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADObstacleDetourQueue.SAME_WAY_DOT = 0.5      -- cos 60° : tourné dans mon sens
ADObstacleDetourQueue.FRONT_DISTANCE = 12     -- m : véhicule vu par le capteur de route jusqu'à cette distance
ADObstacleDetourQueue.QUEUE_LOOK = 25         -- m au-delà de lui : un autre véhicule arrêté dans mon sens = une file
ADObstacleDetourQueue.QUEUE_LATERAL = 3       -- m de ma ligne (plus sa demi-largeur)
ADObstacleDetourQueue.STOPPED_KMH = 1         -- km/h : arrêté
ADObstacleDetourQueue.LOG_INTERVAL = 30000    -- ms entre deux lignes « file » pour le même véhicule devant

-- ------------------------------------------------------------------------------------------------------------
-- Aides
-- ------------------------------------------------------------------------------------------------------------
local function rootOf(object)
    if object == nil then
        return nil
    end
    return object.getRootVehicle ~= nil and object:getRootVehicle() or object
end

local function nameOf(object)
    if object == nil then
        return "?"
    end
    if object.getName ~= nil then
        local ok, name = FarmPilotCall(object.getName, object)
        if ok and name ~= nil then
            return tostring(name)
        end
    end
    return tostring(object.id)
end

-- direction (x, z) normée de l'avant d'un véhicule, nil si inconnue
local function directionOf(object)
    if object == nil or object.components == nil or object.components[1] == nil or object.components[1].node == nil then
        return nil, nil
    end
    local dx, _, dz = localDirectionToWorld(object.components[1].node, 0, 0, 1)
    local length = MathUtil.vector2Length(dx or 0, dz or 0)
    if length < 0.0001 then
        return nil, nil
    end
    return dx / length, dz / length
end

local function speedKmh(object)
    return math.abs((object ~= nil and object.lastSpeedReal) or 0) * 3600
end

local function combinationOf(root)
    if root.getChildVehicles ~= nil then
        local ok, list = FarmPilotCall(root.getChildVehicles, root)
        if ok and type(list) == "table" then
            return list
        end
    end
    return { root }
end

-- un élément de l'attelage dans le déclencheur d'un pont-bascule (ponts trouvés par Weighing.lua)
function ADObstacleDetourQueue.isOnWeighbridge(root)
    if root == nil then
        return false
    end
    if root.adAddonWeigh ~= nil then
        return true -- pesée AutoDrive en cours (Weighing.lua)
    end
    local stations = ADAddonWeighing ~= nil and ADAddonWeighing.stations or nil
    if stations == nil or #stations == 0 then
        return false
    end
    for _, v in ipairs(combinationOf(root)) do
        if v.components ~= nil then
            for _, component in ipairs(v.components) do
                for _, station in ipairs(stations) do
                    if component.node ~= nil and station.triggerVehicleNodes ~= nil and station.triggerVehicleNodes[component.node] ~= nil then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- quelqu'un le conduit : renvoie le motif, nil sinon
function ADObstacleDetourQueue.getDriver(root)
    if root == nil then
        return nil
    end
    if root.ad ~= nil and root.ad.stateModule ~= nil and root.ad.stateModule.isActive ~= nil and root.ad.stateModule:isActive() then
        return "AutoDrive"
    end
    if root.getIsAIActive ~= nil and root:getIsAIActive() then
        return "ouvrier"
    end
    if (root.getIsControlled ~= nil and root:getIsControlled()) or (root.getIsEntered ~= nil and root:getIsEntered()) then
        return "joueur au volant"
    end
    return nil
end

-- un autre véhicule arrêté, tourné dans mon sens, devant lui sur ma ligne (jusqu'à QUEUE_LOOK m au-delà) : son nom
function ADObstacleDetourQueue.findQueueBeyond(vehicle, frontRoot)
    local mx, mz = directionOf(vehicle)
    if mx == nil or AutoDrive == nil or AutoDrive.getAllVehicles == nil then
        return nil
    end
    local px, _, pz = getWorldTranslation(vehicle.components[1].node)
    local myRoot = rootOf(vehicle)
    -- devant moi, l'attelage de tête finit à frontFar m (le long de mon axe)
    local frontFar = -math.huge
    for _, v in ipairs(combinationOf(frontRoot)) do
        if v.components ~= nil and v.components[1] ~= nil then
            local vx, _, vz = getWorldTranslation(v.components[1].node)
            local along = (vx - px) * mx + (vz - pz) * mz
            local half = ((v.size ~= nil and v.size.length) or 0) / 2
            frontFar = math.max(frontFar, along + half)
        end
    end
    if frontFar == -math.huge then
        return nil
    end
    local maxAhead = frontFar + ADObstacleDetourQueue.QUEUE_LOOK
    for _, other in pairs(AutoDrive.getAllVehicles()) do
        local root = rootOf(other)
        if root ~= nil and root ~= myRoot and root ~= frontRoot and other.components ~= nil and other.components[1] ~= nil
            and not AutoDrive:checkIsConnected(myRoot, other) and not AutoDrive:checkIsConnected(frontRoot, other)
            and speedKmh(root) < ADObstacleDetourQueue.STOPPED_KMH then
            local ox, _, oz = getWorldTranslation(other.components[1].node)
            local ahead = (ox - px) * mx + (oz - pz) * mz
            local lateral = math.abs((ox - px) * mz - (oz - pz) * mx)
            local halfWidth = ((other.size ~= nil and other.size.width) or 3) / 2
            local dx, dz = directionOf(root)
            local half = ((other.size ~= nil and other.size.length) or 0) / 2
            if ahead - half > frontFar - 1 and ahead - half < maxAhead and lateral < ADObstacleDetourQueue.QUEUE_LATERAL + halfWidth
                and dx ~= nil and dx * mx + dz * mz > ADObstacleDetourQueue.SAME_WAY_DOT then
                return nameOf(root)
            end
        end
    end
    return nil
end

-- le véhicule devant : celui du capteur de route (jusqu'à FRONT_DISTANCE m), sinon celui du capteur avant long.
-- Renvoie l'objet touché (remorque, outil ou tracteur) et sa distance (nil si inconnue)
function ADObstacleDetourQueue.getVehicleInFront(vehicle)
    local ad = vehicle.ad
    local approach = ad ~= nil and ad.approachModule or nil
    if approach ~= nil and approach.getHit ~= nil then
        local hit = approach:getHit()
        local distance = approach.getEstimatedDistance ~= nil and approach:getEstimatedDistance() or (hit ~= nil and hit.distance)
        if hit ~= nil and hit.isVehicle and hit.object ~= nil and (distance or 99) <= ADObstacleDetourQueue.FRONT_DISTANCE then
            return hit.object, distance
        end
    end
    local sensor = ad ~= nil and ad.sensors ~= nil and ad.sensors.frontSensorDynamicLong or nil
    if sensor == nil or sensor.getBoxShape == nil or AutoDrive == nil or AutoDrive.getAllVehicles == nil then
        return nil, nil
    end
    local box = sensor:getBoxShape()
    local boundingBox = { box.topLeft, box.topRight, box.downRight, box.downLeft }
    local myRoot = rootOf(vehicle)
    for _, other in pairs(AutoDrive.getAllVehicles()) do
        if other ~= nil and other ~= vehicle and rootOf(other) ~= myRoot and not AutoDrive:checkIsConnected(myRoot, other)
            and other.components ~= nil and other.size ~= nil and other.size.width ~= nil and other.size.length ~= nil and other.rootNode ~= nil then
            local ok, hit = FarmPilotCall(AutoDrive.boxesIntersect, boundingBox, AutoDrive.getBoundingBoxForVehicle(other))
            if ok and hit == true then
                return other, nil
            end
        end
    end
    return nil, nil
end

-- motif de la file (texte) et nom du véhicule devant, ou nil : 'object' peut être donné (écart), sinon cherché
function ADObstacleDetourQueue.getQueueReason(vehicle, object, distance)
    if vehicle == nil or vehicle.components == nil or vehicle.components[1] == nil then
        return nil
    end
    if object == nil then
        object, distance = ADObstacleDetourQueue.getVehicleInFront(vehicle)
    end
    local root = rootOf(object)
    if root == nil or root == rootOf(vehicle) then
        return nil
    end
    local mx, mz = directionOf(vehicle)
    local ox, oz = directionOf(object)
    if ox == nil then
        ox, oz = directionOf(root)
    end
    if mx == nil or ox == nil or ox * mx + oz * mz <= ADObstacleDetourQueue.SAME_WAY_DOT then
        return nil
    end
    if ADObstacleDetourQueue.isOnWeighbridge(root) then
        return "sur le pont-bascule", nameOf(root)
    end
    local driver = ADObstacleDetourQueue.getDriver(root)
    if driver ~= nil then
        return driver, nameOf(root)
    end
    local beyond = ADObstacleDetourQueue.findQueueBeyond(vehicle, root)
    if beyond ~= nil then
        return string.format("file derriere '%s'", beyond), nameOf(root)
    end
    return nil
end

local function logQueue(detour, reason, name)
    local now = g_time or 0
    if detour.adQueueName ~= name or now - (detour.adQueueLogTime or -math.huge) >= ADObstacleDetourQueue.LOG_INTERVAL then
        detour.adQueueName, detour.adQueueLogTime = name, now
        detour:log("'%s' arrete devant, dans mon sens (%s) : file d'attente, j'attends derriere (ni recul ni contournement)",
            tostring(name), tostring(reason))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonctions principales (posées autour de celles des modules par install / installAvoid)
-- ------------------------------------------------------------------------------------------------------------

-- ADObstacleDetourModule:isBlockedByStaticObstacle : un véhicule en file n'est pas un obstacle fixe (pas
-- d'horloge de contournement, pas de zone interdite apprise)
function ADObstacleDetourQueue.isBlockedByStaticObstacle(original, detour)
    local blocked = original(detour)
    if not blocked then
        detour.adQueueName = nil
        return blocked
    end
    local reason, name = ADObstacleDetourQueue.getQueueReason(detour.vehicle)
    if reason == nil then
        return blocked
    end
    logQueue(detour, reason, name)
    return false
end

-- ADObstacleDetourModule:startFromStuck (filets « coincé » et « pousse ») : pas de contournement dans une file
function ADObstacleDetourQueue.startFromStuck(original, detour)
    local reason, name = ADObstacleDetourQueue.getQueueReason(detour.vehicle)
    if reason ~= nil then
        logQueue(detour, reason, name)
        return false
    end
    return original(detour)
end

-- ADAvoidModule:isWaitingMyWay : la tête de file reste devant, pas d'écart pour passer à côté
function ADObstacleDetourQueue.isWaitingMyWay(original, avoid, root)
    if original(avoid, root) then
        return true
    end
    return root ~= nil and ADObstacleDetourQueue.getQueueReason(avoid.vehicle, root) ~= nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place (dernière ligne de ObstacleDetourModule.lua et de AvoidModule.lua)
-- ------------------------------------------------------------------------------------------------------------
function ADObstacleDetourQueue.install(module)
    if module == nil or module.adQueueInstalled then
        return
    end
    module.adQueueInstalled = true
    local originalBlocked, originalStuck = module.isBlockedByStaticObstacle, module.startFromStuck
    module.isBlockedByStaticObstacle = function(self)
        return ADObstacleDetourQueue.isBlockedByStaticObstacle(originalBlocked, self)
    end
    module.startFromStuck = function(self)
        return ADObstacleDetourQueue.startFromStuck(originalStuck, self)
    end
end

function ADObstacleDetourQueue.installAvoid(module)
    if module == nil or module.adQueueInstalled or module.isWaitingMyWay == nil then
        return
    end
    module.adQueueInstalled = true
    local original = module.isWaitingMyWay
    module.isWaitingMyWay = function(self, root)
        return ADObstacleDetourQueue.isWaitingMyWay(original, self, root)
    end
end
