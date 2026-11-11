-- ============================================================================================================
-- FarmPilot : Weighing.lua
-- Addon : pesée sur les ponts-bascules du jeu (PlaceableWeighingStation).
--
-- Règle :
-- - Quand AutoDrive passe sur un pont-bascule, l'attelage ralentit à l'approche (APPROACH_KMH, puis ON_BRIDGE_KMH sur
--   le pont), s'arrête quand tout l'attelage est dessus et centré, le poids du chargement s'affiche au milieu de
--   l'écran (WAIT_MS à l'arrêt), puis il repart.
-- - On lit le capteur du pont (spec.triggerVehicleNodes = noeuds des véhicules dessus).
-- - L'arrêt se fait comme la pause « repliage des outils » d'AutoDrive : la tâche en cours n'est pas mise à jour et
--   le module de conduite spéciale tient le véhicule arrêté.
-- - Pesée à la main : le joueur s'arrête lui-même sur le pont (tout l'attelage dessus, 3 s à l'arrêt). Fenêtre
--   affichée et pesée enregistrée à son nom.
-- - Chaque pesée est envoyée au registre d'AutoSwitch s'il est installé. Seule la pesée de l'attelage où le joueur
--   est assis est affichée.
--
-- Branché par : AutoDriveAddon.lua (install au chargement de la carte : enveloppe ADTaskModule.update,
-- ADDrivePathModule.getSpeedLimitBySteeringAngle et ADStateModule.setActive) ; addModEventListener (update, draw).
-- ADAddonWeighing.stations est lu par ObstacleDetourQueue.lua (file devant le pont).
-- ============================================================================================================

ADAddonWeighing = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAddonWeighing.WAIT_MS = 5000            -- arrêt une fois immobile
ADAddonWeighing.SHOW_AFTER_MS = 3000      -- fenêtre gardée après le départ (puis fondu)
ADAddonWeighing.STOPPED_KMH = 0.5
ADAddonWeighing.SCAN_INTERVAL_MS = 10000
ADAddonWeighing.BRAKE_DECEL = 2.0          -- m/s², pour viser le centre en freinant
ADAddonWeighing.APPROACH_DIST = 40         -- m : pont devant le tracteur, on ralentit
ADAddonWeighing.APPROACH_KMH = 12
ADAddonWeighing.MANUAL_WAIT_MS = 3000      -- conduite à la main : pesée après 3 s à l'arrêt sur le pont
ADAddonWeighing.MANUAL_SHOW_MS = 6000      -- fenêtre affichée 6 s
ADAddonWeighing.ON_BRIDGE_KMH = 5          -- sur le pont : lent, pour s'arrêter pile au centre
ADAddonWeighing.SITE_MAX_DIST = 1000  -- m : point de vente pris comme nom du site
ADAddonWeighing.FADE_MS = 400            -- ms : fondu de la fenêtre de pesée

-- Réservoirs du tracteur, pas du chargement
ADAddonWeighing.IGNORED_FILLTYPES = { "DIESEL", "DEF", "AIR", "ELECTRICCHARGE", "METHANE" }

-- ------------------------------------------------------------------------------------------------------------
-- État partagé (ponts trouvés, pesées affichées)
-- ------------------------------------------------------------------------------------------------------------
ADAddonWeighing.stations = {}
ADAddonWeighing.nextScan = 0
ADAddonWeighing.displays = {}

-- (perf 07/11) résultat gardé par bâtiment : les spécialisations d'un bâtiment ne changent pas
ADAddonWeighing.specCache = setmetatable({}, { __mode = "k" })

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local T = ADAddon.getText

local function formatTons(kg)
    -- séparateur décimal de la langue du jeu
    if g_i18n ~= nil and g_i18n.formatNumber ~= nil then
        local ok, n = FarmPilotCall(g_i18n.formatNumber, g_i18n, kg / 1000, 1)
        if ok and type(n) == "string" then
            return n .. " t"
        end
    end
    return string.format("%.1f t", kg / 1000)
end

local function getCombination(vehicle)
    local root = vehicle.rootVehicle or vehicle
    if root.getChildVehicles ~= nil then
        return root:getChildVehicles()
    end
    return { vehicle }
end

-- ------------------------------------------------------------------------------------------------------------
-- Ponts-bascules de la carte et nom du site
-- ------------------------------------------------------------------------------------------------------------
-- Ponts-bascules posés sur la carte : on garde leur table des noeuds présents
function ADAddonWeighing.scanStations()
    local list = {}
    local cache = ADAddonWeighing.specCache
    local system = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if system ~= nil and system.placeables ~= nil then
        for _, placeable in ipairs(system.placeables) do
            local spec = cache[placeable]
            if spec == nil then
                spec = placeable.spec_weighingStation
                if spec == nil then
                    for key, value in pairs(placeable) do
                        if type(value) == "table" and type(key) == "string" and key:sub(1, 5) == "spec_" and value.triggerVehicleNodes ~= nil then
                            spec = value
                            break
                        end
                    end
                end
                cache[placeable] = spec or false
            end
            if spec == false then spec = nil end
            if spec ~= nil and spec.triggerVehicleNodes ~= nil then
                spec.adAddonPlaceable = placeable
                table.insert(list, spec)
            end
        end
    end
    ADAddonWeighing.stations = list
end

local function placeableName(p)
    if p.getName ~= nil then
        local ok, name = FarmPilotCall(p.getName, p)
        if ok and type(name) == "string" then return name end
    end
    return ""
end

local function acceptsFillType(p, fillTypeIndex)
    local ss = p.spec_sellingStation ~= nil and p.spec_sellingStation.sellingStation or nil
    if ss == nil then return false end
    if fillTypeIndex == nil then return true end
    if ss.acceptedFillTypes ~= nil then
        return ss.acceptedFillTypes[fillTypeIndex] == true
    end
    if ss.getIsFillTypeAllowed ~= nil then
        local ok, res = FarmPilotCall(ss.getIsFillTypeAllowed, ss, fillTypeIndex)
        return ok and res == true
    end
    return true
end

-- nom du site : le point de vente le plus proche du pont qui accepte le produit (sinon le nom du pont)
function ADAddonWeighing.findSiteName(bridge, fillTypeIndex)
    if bridge == nil then return nil end
    bridge.adAddonSiteNames = bridge.adAddonSiteNames or {}
    local key = fillTypeIndex or 0
    if bridge.adAddonSiteNames[key] ~= nil then
        return bridge.adAddonSiteNames[key]
    end
    local result = placeableName(bridge)
    local system = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    local node = bridge.rootNode
    if system ~= nil and system.placeables ~= nil and node ~= nil and node ~= 0 then
        local bx, _, bz = getWorldTranslation(node)
        local best, bestDist = nil, ADAddonWeighing.SITE_MAX_DIST
        for _, p in ipairs(system.placeables) do
            if p ~= bridge and p.rootNode ~= nil and p.rootNode ~= 0 and acceptsFillType(p, fillTypeIndex) then
                local x, _, z = getWorldTranslation(p.rootNode)
                local d = math.sqrt((x - bx) ^ 2 + (z - bz) ^ 2)
                if d < bestDist and placeableName(p) ~= "" then
                    best, bestDist = p, d
                end
            end
        end
        if best ~= nil then
            result = placeableName(best)
        end
    end
    bridge.adAddonSiteNames[key] = result
    return result
end

-- Pont sur lequel ce véhicule a au moins un composant, ou nil
local function getStationOf(vehicle)
    if vehicle.components == nil then
        return nil
    end
    for _, station in ipairs(ADAddonWeighing.stations) do
        for _, component in ipairs(vehicle.components) do
            if component.node ~= nil and station.triggerVehicleNodes[component.node] ~= nil then
                return station
            end
        end
    end
    return nil
end

-- Centre du pont : centre de la forme du capteur
local function getStationCenter(station)
    if station.adAddonTriggerNode == nil then
        local node = station.triggerNode
        if type(node) ~= "number" then
            for key, value in pairs(station) do
                if type(value) == "number" and type(key) == "string" and key:lower():find("trigger") ~= nil and entityExists(value) then
                    node = value
                    break
                end
            end
        end
        station.adAddonTriggerNode = node or 0
    end
    local node = station.adAddonTriggerNode
    if node == 0 or not entityExists(node) then
        return nil
    end
    -- getShapeWorldBoundingSphere : centre en coordonnées du monde
    -- (getShapeBoundingSphere donne un centre local au noeud : à repasser dans le monde)
    if getShapeWorldBoundingSphere ~= nil then
        local ok, x, _, z = FarmPilotCall(getShapeWorldBoundingSphere, node)
        if ok and x ~= nil then
            return x, z
        end
    end
    if getShapeBoundingSphere ~= nil then
        local ok, lx, ly, lz = FarmPilotCall(getShapeBoundingSphere, node)
        if ok and lx ~= nil then
            local x, _, z = localToWorld(node, lx, ly, lz)
            return x, z
        end
    end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

-- ------------------------------------------------------------------------------------------------------------
-- Poids de l'attelage
-- ------------------------------------------------------------------------------------------------------------
local ignoredFillTypes = nil
local function getIgnoredFillTypes()
    if ignoredFillTypes == nil then
        ignoredFillTypes = {}
        for _, name in ipairs(ADAddonWeighing.IGNORED_FILLTYPES) do
            local index = g_fillTypeManager:getFillTypeIndexByName(name)
            if index ~= nil then
                ignoredFillTypes[index] = true
            end
        end
    end
    return ignoredFillTypes
end

-- Poids du chargement (kg) et poids total de l'attelage (kg)
local function getWeights(vehicles)
    local load, total = 0, 0
    local byType = {}
    local ignored = getIgnoredFillTypes()
    for _, v in ipairs(vehicles) do
        if v.getTotalMass ~= nil then
            total = total + v:getTotalMass(true) * 1000
        end
        local spec = v.spec_fillUnit
        if spec ~= nil and spec.fillUnits ~= nil then
            for _, fu in ipairs(spec.fillUnits) do
                if fu.fillType ~= nil and not ignored[fu.fillType] and (fu.fillLevel or 0) > 0 then
                    local fillType = g_fillTypeManager:getFillTypeByIndex(fu.fillType)
                    if fillType ~= nil and fillType.massPerLiter ~= nil then
                        local kg = fu.fillLevel * fillType.massPerLiter * 1000
                        load = load + kg
                        byType[fillType] = (byType[fillType] or 0) + kg
                    end
                end
            end
        end
    end
    -- produit principal (le plus lourd)
    local main, mainKg = nil, 0
    for fillType, kg in pairs(byType) do
        if kg > mainKg then
            main, mainKg = fillType, kg
        end
    end
    return load, total, main
end

-- ------------------------------------------------------------------------------------------------------------
-- Centrage sur le pont
-- ------------------------------------------------------------------------------------------------------------
-- Roues d'un véhicule (noeuds), comme AutoDrive (PathCalculation)
local function getWheelNodes(v)
    local nodes = {}
    local spec = v.spec_wheels
    if spec ~= nil and spec.wheels ~= nil then
        for _, wheel in ipairs(spec.wheels) do
            local node = wheel.repr or wheel.driveNode or wheel.node
            if node ~= nil and node ~= 0 then
                table.insert(nodes, node)
            end
        end
    end
    return nodes
end

-- Vrai quand le milieu des roues de l'attelage arrive au centre du pont (en tenant compte du freinage)
local function isCentered(vehicle, vehicles, station)
    local root = vehicle.rootVehicle or vehicle
    if station == nil or root.rootNode == nil then
        return true
    end
    local cx, cz = getStationCenter(station)
    if cx == nil then
        return true
    end
    local tx, _, tz = getWorldTranslation(root.rootNode)
    local dx, _, dz = localDirectionToWorld(root.rootNode, 0, 0, 1)
    -- Avant / arrière des roues de tout l'attelage (sinon gabarit du véhicule)
    local front, rear = -math.huge, math.huge
    local function add(x, wz)
        local d = (x - tx) * dx + (wz - tz) * dz
        front = math.max(front, d)
        rear = math.min(rear, d)
    end
    for _, v in ipairs(vehicles) do
        local wheels = getWheelNodes(v)
        if #wheels > 0 then
            for _, node in ipairs(wheels) do
                local x, _, wz = getWorldTranslation(node)
                add(x, wz)
            end
        elseif v.rootNode ~= nil and v.size ~= nil then
            local offset = v.size.lengthOffset or 0
            local half = (v.size.length or 0) / 2
            for _, z in ipairs({ offset + half, offset - half }) do
                local x, _, wz = localToWorld(v.rootNode, 0, 0, z)
                add(x, wz)
            end
        end
    end
    if front == -math.huge then
        return true
    end
    local middle = (front + rear) / 2
    local target = (cx - tx) * dx + (cz - tz) * dz
    local speed = math.abs(vehicle.lastSpeedReal or 0) * 1000   -- m/s
    local brake = speed * speed / (2 * ADAddonWeighing.BRAKE_DECEL) + 0.3
    local centered = target - middle <= brake
    return centered
end

-- ------------------------------------------------------------------------------------------------------------
-- Pesée par AutoDrive : passage, arrêt, enregistrement
-- ------------------------------------------------------------------------------------------------------------
-- Suivi du passage : arrêt quand tout l'attelage est sur le pont et centré dessus
local function updatePass(vehicle)
    local vehicles = getCombination(vehicle)
    local onStation = false
    local w = vehicle.adAddonWeigh

    local tractorOn = false
    for _, v in ipairs(vehicles) do
        local station = getStationOf(v)
        if station ~= nil then
            onStation = true
            if v == (vehicle.rootVehicle or vehicle) then
                tractorOn = true
            end
            if w == nil then
                w = { seen = {}, done = false, holding = false }
                vehicle.adAddonWeigh = w
            end
            w.seen[v] = true
            w.station = station
        end
    end

    if not onStation then
        -- Attelage sorti du pont : le prochain passage pèsera de nouveau
        if w ~= nil and not w.holding then
            vehicle.adAddonWeigh = nil
        end
        return
    end

    if w.done or w.holding then
        return
    end

    for _, v in ipairs(vehicles) do
        if not w.seen[v] then
            return
        end
    end

    -- Tout l'attelage est monté : on avance jusqu'à le centrer sur le pont
    -- (sauf si le tracteur sort déjà du pont : attelage plus long que le pont)
    if tractorOn and not isCentered(vehicle, vehicles, w.station) then
        return
    end

    w.holding = true
    w.stoppedTime = 0
    w.vehicles = vehicles
end

local function finishHold(vehicle, w)
    w.holding = false
    w.done = true
    local sdm = vehicle.ad.specialDrivingModule
    if sdm ~= nil then
        sdm:releaseVehicle()
    end
    local d = ADAddonWeighing.displays[vehicle]
    if d ~= nil then
        d.untilTime = g_time + ADAddonWeighing.SHOW_AFTER_MS
    end
end

-- Pesée envoyée au registre d'AutoSwitch s'il est installé
local function recordWeighing(vehicle, d)
    if d == nil then
        return
    end
    local env = _G["FS25_AutoSwitch"]
    local register = type(env) == "table" and env.AS_Register or nil
    if register == nil or register.addWeighing == nil then
        return
    end
    local ok, err = FarmPilotCall(register.addWeighing, register, {
        vehicle = d.name,
        site = d.site,
        driver = d.driver,
        fillType = d.fillTypeName,
        load = d.load,
        total = d.total,
        farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
    })
    if not ok then
        ADAddon.warning("AutoSwitch register: " .. tostring(err))
    end
end

-- Arrêt tenu tant que le pesage n'est pas fini ; renvoie true si la tâche AutoDrive doit attendre
local function updateHold(vehicle, w, dt)
    local sdm = vehicle.ad.specialDrivingModule
    if sdm == nil then
        w.holding = false
        return false
    end

    sdm.motorShouldNotBeStopped = true
    sdm:stopVehicle()
    sdm:update(dt)
    sdm.motorShouldNotBeStopped = false

    local kmh = (vehicle.lastSpeedReal or 0) * 3600
    if kmh <= ADAddonWeighing.STOPPED_KMH then
        w.stoppedTime = w.stoppedTime + dt
        local load, total, fillType = getWeights(w.vehicles or getCombination(vehicle))
        local d = ADAddonWeighing.displays[vehicle]
        if d == nil then
            d = { startTime = g_time }
            ADAddonWeighing.displays[vehicle] = d
        end
        d.name = vehicle:getFullName()
        d.site = w.station ~= nil and ADAddonWeighing.findSiteName(w.station.adAddonPlaceable, fillType ~= nil and fillType.index or nil) or nil
        d.driver = "AutoDrive"
        d.load, d.total, d.untilTime = load, total, math.huge
        d.product = fillType ~= nil and (fillType.title or fillType.name) or nil
        d.fillTypeName = fillType ~= nil and fillType.name or nil
    end

    if w.stoppedTime >= ADAddonWeighing.WAIT_MS then
        recordWeighing(vehicle, ADAddonWeighing.displays[vehicle])
        finishHold(vehicle, w)
        return false
    end
    return true
end

-- Vitesse maxi près d'un pont-bascule (nil = pas de limite)
local function getApproachSpeed(vehicle)
    local w = vehicle.adAddonWeigh
    if w ~= nil and (w.done or w.holding) then
        return nil
    end
    if w ~= nil then
        return ADAddonWeighing.ON_BRIDGE_KMH
    end
    local root = vehicle.rootVehicle or vehicle
    if root.rootNode == nil then
        return nil
    end
    local tx, _, tz = getWorldTranslation(root.rootNode)
    local dx, _, dz = localDirectionToWorld(root.rootNode, 0, 0, 1)
    for _, station in ipairs(ADAddonWeighing.stations) do
        local cx, cz = getStationCenter(station)
        if cx ~= nil then
            local ahead = (cx - tx) * dx + (cz - tz) * dz
            local side = math.abs((cx - tx) * dz - (cz - tz) * dx)
            if ahead > 0 and ahead < ADAddonWeighing.APPROACH_DIST and side < 6 then
                return ADAddonWeighing.APPROACH_KMH
            end
        end
    end
    return nil
end

-- Une image d'AutoDrive : renvoie true si la tâche doit attendre (pesée en cours)
local function weighStep(self, dt)
    local vehicle = self.vehicle
    if vehicle == nil or vehicle.ad == nil or not vehicle.isServer then
        return false
    end
    if g_time >= ADAddonWeighing.nextScan then
        ADAddonWeighing.nextScan = g_time + ADAddonWeighing.SCAN_INTERVAL_MS
        ADAddonWeighing.scanStations()
    end
    if #ADAddonWeighing.stations == 0 then
        return false
    end
    if self.activeTask ~= nil then
        updatePass(vehicle)
    end
    vehicle.adAddonWeighSpeed = getApproachSpeed(vehicle)
    local w = vehicle.adAddonWeigh
    if w ~= nil and w.holding then
        return updateHold(vehicle, w, dt)
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place (au chargement de la carte, par AutoDriveAddon.lua)
-- ------------------------------------------------------------------------------------------------------------
function ADAddonWeighing.install(autoDrive)
    local taskModule = ADAddon.getAutoDriveGlobal("ADTaskModule")
    if taskModule == nil or taskModule.update == nil then
        ADAddon.warning("ADTaskModule not found, weighbridge inactive")
        return
    end

    local originalUpdate = taskModule.update
    taskModule.update = function(self, dt, ...)
        local ok, wait = FarmPilotCall(weighStep, self, dt)
        if not ok then
            if not ADAddonWeighing.errorShown then
                ADAddonWeighing.errorShown = true
                ADAddon.warning("weighbridge error: " .. tostring(wait))
            end
            if self.vehicle ~= nil then self.vehicle.adAddonWeigh = nil end
        elseif wait then
            return
        end
        return originalUpdate(self, dt, ...)
    end

    -- Vitesse limitée à l'approche et sur le pont (AutoDrive appelle cette fonction à chaque image)
    local drivePath = ADAddon.getAutoDriveGlobal("ADDrivePathModule")
    if drivePath ~= nil and drivePath.getSpeedLimitBySteeringAngle ~= nil then
        local originalLimit = drivePath.getSpeedLimitBySteeringAngle
        drivePath.getSpeedLimitBySteeringAngle = function(self, ...)
            local limit = originalLimit(self, ...)
            local kmh = self.vehicle ~= nil and self.vehicle.adAddonWeighSpeed or nil
            if kmh ~= nil and limit ~= nil then
                return math.min(limit, kmh)
            end
            return limit
        end
    end

    -- AutoDrive arrêté pendant la pesée : on libère
    local stateModule = ADAddon.getAutoDriveGlobal("ADStateModule")
    if stateModule ~= nil and stateModule.setActive ~= nil then
        local originalSetActive = stateModule.setActive
        stateModule.setActive = function(self, active, ...)
            local vehicle = self.vehicle
            if not active and vehicle ~= nil then
                vehicle.adAddonWeigh = nil
                vehicle.adAddonWeighSpeed = nil
                ADAddonWeighing.displays[vehicle] = nil
            end
            return originalSetActive(self, active, ...)
        end
    end

end

-- ------------------------------------------------------------------------------------------------------------
-- Pesée à la main : le joueur s'arrête lui-même sur le pont (tout l'attelage dessus,
-- 3 s à l'arrêt). Fenêtre affichée et pesée enregistrée à son nom.
-- ------------------------------------------------------------------------------------------------------------
local function getPlayerName()
    local tries = {
        function() return g_currentMission.playerNickname end,
        function() return g_localPlayer:getNickname() end,
        function() return g_localPlayer.nickname end,
        function() return g_gameSettings:getValue("nickname") end,
    }
    for _, f in ipairs(tries) do
        local ok, name = FarmPilotCall(f)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return T("adAddon_player")
end

local function getControlledVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local ok, v = FarmPilotCall(g_localPlayer.getCurrentVehicle, g_localPlayer)
        if ok and v ~= nil then return v end
    end
    return g_currentMission ~= nil and g_currentMission.controlledVehicle or nil
end

function ADAddonWeighing:updateManual(dt)
    local v = getControlledVehicle()
    local root = v ~= nil and (v.rootVehicle or v) or nil
    local m = self.manual
    if m ~= nil and m.root ~= root then
        self.manual, m = nil, nil
    end
    if root == nil or not root.isServer then
        return
    end
    if root.ad ~= nil and root.ad.stateModule ~= nil and root.ad.stateModule:isActive() then
        return
    end
    if g_time >= self.nextScan then
        self.nextScan = g_time + self.SCAN_INTERVAL_MS
        self.scanStations()
    end
    if #self.stations == 0 then
        return
    end

    local vehicles = getCombination(root)
    local allOn, anyOn, station = true, false, nil
    for _, veh in ipairs(vehicles) do
        local st = getStationOf(veh)
        if st ~= nil then
            anyOn, station = true, st
        else
            allOn = false
        end
    end
    if not anyOn then
        self.manual = nil
        return
    end
    if m == nil then
        m = { root = root, still = 0, done = false }
        self.manual = m
    end
    if m.done then
        return
    end
    local kmh = math.abs(root.lastSpeedReal or 0) * 3600
    if allOn and kmh <= self.STOPPED_KMH then
        m.still = m.still + dt
    else
        m.still = 0
    end
    if m.still < self.MANUAL_WAIT_MS then
        return
    end

    m.done = true
    local load, total, fillType = getWeights(vehicles)
    local d = {
        startTime = g_time,
        untilTime = g_time + self.MANUAL_SHOW_MS,
        name = root:getFullName(),
        load = load,
        total = total,
        product = fillType ~= nil and (fillType.title or fillType.name) or nil,
        fillTypeName = fillType ~= nil and fillType.name or nil,
        site = station ~= nil and self.findSiteName(station.adAddonPlaceable, fillType ~= nil and fillType.index or nil) or nil,
        driver = getPlayerName(),
    }
    self.displays[root] = d
    recordWeighing(root, d)
end

function ADAddonWeighing:update(dt)
    local ok, err = FarmPilotCall(self.updateManual, self, dt)
    if not ok and not self.manualErrorShown then
        self.manualErrorShown = true
        ADAddon.warning("manual weighing error: " .. tostring(err))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Fenêtre de pesée
-- ------------------------------------------------------------------------------------------------------------
local function uiScale()
    if g_gameSettings ~= nil and g_gameSettings.getValue ~= nil then
        local ok, v = FarmPilotCall(g_gameSettings.getValue, g_gameSettings, "uiScale")
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return 1
end

-- images des coins arrondis de la fenêtre, chargées une fois (false si absentes : coins carrés)
local modDir = g_currentModDirectory
local cornerOv = nil
local function corners()
    if cornerOv == nil then
        cornerOv = {}
        for _, k in ipairs({ "tl", "tr", "bl", "br" }) do
            local ok, o = FarmPilotCall(createImageOverlay, Utils.getFilename(({ tl = "hud/corner_tl.dds", tr = "hud/corner_tr.dds", bl = "hud/corner_bl.dds", br = "hud/corner_br.dds" })[k], modDir))
            if ok and o ~= nil and o ~= 0 then cornerOv[k] = o else cornerOv = false break end
        end
    end
    if cornerOv and not cornerOv.ready then
        -- (07/11) pas de dessin avant que les images soient prêtes (« renderOverlay called too soon »)
        if getIsOverlayReady ~= nil then
            for _, k in ipairs({ "tl", "tr", "bl", "br" }) do
                local ok, r = FarmPilotCall(getIsOverlayReady, cornerOv[k])
                if ok and not r then return nil end
            end
        end
        cornerOv.ready = true
    end
    return cornerOv or nil
end

-- Petite fenêtre de pesée : apparaît en fondu, disparaît seule après le départ
function ADAddonWeighing:drawPanel(d, alpha, yTop)
    local sc = uiScale()
    local aspect = (g_screenWidth or 1920) / math.max(1, g_screenHeight or 1080)
    local function py(px) return px * sc / 1080 end
    local function pxw(px) return py(px) / aspect end
    local function text(x, y, size, s, r, g, b, align, bold)
        setTextAlignment(align or RenderText.ALIGN_LEFT)
        setTextBold(bold == true)
        setTextColor(r, g, b, alpha)
        renderText(x, y, py(size), tostring(s))
    end

    local W, H, titleH, pad = pxw(440), py(190), py(44), pxw(18)
    local x0, y0 = 0.5 - W / 2, yTop - H
    -- coins arrondis : petite image de quart de cercle (hud/corner_*.dds) teintée, et rectangles
    -- pleins calés sur les vrais pixels de l'écran (même dessin que les fenêtres Météo et Champs
    -- d'AutoSwitch ; les bandes de 1 px laissaient des espaces autour du cadre)
    local sw, sh = math.max(1, g_screenWidth or 1920), math.max(1, g_screenHeight or 1080)
    local function sx(v) return math.floor(v * sw + 0.5) / sw end
    local function sy(v) return math.floor(v * sh + 0.5) / sh end
    local left, right = sx(x0), sx(x0 + W)
    local bottom, top = sy(y0), sy(yTop)
    local mid = sy(yTop - titleH)
    local rh = sy(y0 + py(12)) - bottom
    local rw = sx(x0 + pxw(12)) - left
    local cs = corners()
    local function part(yb, yt, roundTop, roundBottom, r, g, b, a)
        if cs == nil then
            drawFilledRect(left, yb, right - left, yt - yb, r, g, b, a)
            return
        end
        local b2, t2 = yb, yt
        if roundBottom then
            drawFilledRect(left + rw, yb, right - left - 2 * rw, rh, r, g, b, a)
            setOverlayColor(cs.bl, r, g, b, a); renderOverlay(cs.bl, left, yb, rw, rh)
            setOverlayColor(cs.br, r, g, b, a); renderOverlay(cs.br, right - rw, yb, rw, rh)
            b2 = yb + rh
        end
        if roundTop then
            drawFilledRect(left + rw, yt - rh, right - left - 2 * rw, rh, r, g, b, a)
            setOverlayColor(cs.tl, r, g, b, a); renderOverlay(cs.tl, left, yt - rh, rw, rh)
            setOverlayColor(cs.tr, r, g, b, a); renderOverlay(cs.tr, right - rw, yt - rh, rw, rh)
            t2 = yt - rh
        end
        if t2 > b2 then drawFilledRect(left, b2, right - left, t2 - b2, r, g, b, a) end
    end
    part(bottom, mid, false, true, 0.05, 0.07, 0.10, 0.88 * alpha)
    part(mid, top, true, false, 0.10, 0.14, 0.20, 0.95 * alpha)
    local title = T("adAddon_weighbridge")
    if d.site ~= nil and d.site ~= "" then
        title = title .. " - " .. d.site
    end
    text(x0 + pad, yTop - py(31), 20, title, 1.00, 0.80, 0.30, nil, true)

    -- (même dessin que la fenêtre Météo d'AutoSwitch : lignes fines grises entre les rubriques)
    local function line(yy)
        drawFilledRect(x0 + pad, yy, W - 2 * pad, py(1), 1, 1, 1, 0.15 * alpha)
    end
    local y = yTop - titleH - py(30)
    text(x0 + pad, y, 16, T("adAddon_product"), 0.70, 0.73, 0.78)
    text(x0 + W - pad, y, 16, d.product or T("adAddon_empty"), 1, 1, 1, RenderText.ALIGN_RIGHT, true)
    line(y - py(8))
    y = y - py(44)
    text(x0 + pad, y + py(4), 16, T("adAddon_load"), 0.70, 0.73, 0.78)
    text(x0 + W - pad, y, 30, formatTons(d.load), 0.55, 0.90, 0.45, RenderText.ALIGN_RIGHT, true)
    line(y - py(8))
    y = y - py(32)
    text(x0 + pad, y, 16, T("adAddon_totalWeight"), 0.70, 0.73, 0.78)
    text(x0 + W - pad, y, 16, formatTons(d.total), 1, 1, 1, RenderText.ALIGN_RIGHT)
    line(y - py(8))
    y = y - py(30)
    local who = tostring(d.name)
    if d.driver ~= nil and d.driver ~= "AutoDrive" then
        who = who .. "  -  " .. d.driver
    end
    text(x0 + pad, y, 14, who, 0.70, 0.73, 0.78)
    return H
end

function ADAddonWeighing:draw()
    if next(ADAddonWeighing.displays) == nil then
        return
    end
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() then
        return
    end
    -- seulement la pesée de l'attelage où le joueur est assis (pas celle des autres tracteurs)
    local cv = getControlledVehicle()
    local mine = cv ~= nil and (cv.rootVehicle or cv) or nil
    local yTop = 0.78
    for vehicle, d in pairs(ADAddonWeighing.displays) do
        if g_time > d.untilTime or vehicle.isDeleted then
            ADAddonWeighing.displays[vehicle] = nil
        elseif mine ~= nil and (vehicle.rootVehicle or vehicle) == mine then
            local alpha = math.min(1, (g_time - (d.startTime or 0)) / self.FADE_MS)
            if d.untilTime ~= math.huge then
                alpha = math.min(alpha, (d.untilTime - g_time) / self.FADE_MS)
            end
            alpha = math.max(0, math.min(1, alpha))
            local ok, h = FarmPilotCall(self.drawPanel, self, d, alpha, yTop)
            if ok then
                yTop = yTop - h - 0.01
            elseif not self.drawErrorShown then
                self.drawErrorShown = true
                ADAddon.warning("weighing display error: " .. tostring(h))
            end
        end
    end
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

-- ------------------------------------------------------------------------------------------------------------
-- Enregistrement
-- ------------------------------------------------------------------------------------------------------------
ADAddon.addModule(ADAddonWeighing)
addModEventListener(ADAddonWeighing)
