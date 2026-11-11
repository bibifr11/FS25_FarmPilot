-- ============================================================================================================
-- FarmPilot : ObstacleDetourEscape.lua
-- Contournement raté devant un objet fixe : passer au pas, sinon passage retenu comme bouché et autre route.
--
-- Règle (09/11) :
-- - Après le dernier contournement raté au même endroit (ADObstacleDetourModule:fail) devant un objet fixe (pas un
--   véhicule, pas un portail) : le véhicule avance au pas (CREEP_SPEED km/h) sur sa route sans tenir compte du
--   capteur avant ; un véhicule devant l'arrête toujours. Passé (obstacle derrière le milieu du tracteur et capteur
--   libre CREEP_CLEAR_TIME ms, ou CREEP_DISTANCE m plus loin que l'obstacle) : la route continue normalement.
-- - Il n'avance plus (moins de CREEP_STUCK_MOVE m en CREEP_STUCK_TIME ms) ou délai CREEP_TIMEOUT dépassé : les
--   tronçons du réseau de sa route à moins de BLOCK_RADIUS m de l'obstacle sont retenus comme bouchés pour cette
--   largeur de train et les plus larges (même poids qu'un tronçon trop étroit dans le calcul de route), sauvés dans
--   la partie (FILE_NAME). Puis demi-tour : nouvelle route vers la même destination depuis un point du réseau
--   avant le passage (sinon le plus proche), chemin calculé jusqu'à son premier point à 25 m ou plus
--   (ADObstacleDetourModule:startPlanning).
-- - Pas d'autre route, ou pas de chemin pour faire demi-tour : arrêt comme avant, message ; le passage reste retenu,
--   le prochain départ prend l'autre route.
-- - Au pas une fois, demi-tour une fois, par endroit et par route donnée.
-- - Réseau changé (éditeur) : un passage dont les points ont bougé ou disparu est oublié.
--
-- Branché par : dernière ligne de ObstacleDetourModule.lua (install : fail, handle, isControlling, updatePlanning,
-- reset) ; une ligne dans DrivePathModuleObstacles.lua (handleDrivingModules : creepOverride) ; install enveloppe
-- aussi ADPathCalculator.GetPath, getNarrowWeightFunc et resetWidthCache (PathCalculationWidth.lua, chargé avant).
-- ============================================================================================================

ADObstacleDetourEscape = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADObstacleDetourEscape.CREEP_SPEED = 2.5         -- km/h (sous la limite de « pousse sans avancer », 3 km/h)
ADObstacleDetourEscape.CREEP_DISTANCE = 20       -- m roulés au pas : passé
ADObstacleDetourEscape.CREEP_MIN_MOVE = 3        -- m roulés avant de croire le capteur libre
ADObstacleDetourEscape.CREEP_CLEAR_TIME = 3000   -- ms de capteur libre : passé
ADObstacleDetourEscape.CREEP_STUCK_MOVE = 0.5    -- m
ADObstacleDetourEscape.CREEP_STUCK_TIME = 5000   -- ms sans avancer de CREEP_STUCK_MOVE : coincé
ADObstacleDetourEscape.CREEP_TIMEOUT = 60000     -- ms au pas au plus
ADObstacleDetourEscape.BLOCK_RADIUS = 8          -- m de l'obstacle : tronçon du réseau retenu comme bouché
ADObstacleDetourEscape.SAME_PLACE = 15           -- m : au pas une fois, demi-tour une fois, par endroit
ADObstacleDetourEscape.MOVED_POINT = 1           -- m : point du réseau déplacé dans l'éditeur, passage oublié
ADObstacleDetourEscape.START_RANGE = 60          -- m : points du réseau d'où repartir
ADObstacleDetourEscape.MAX_STARTS = 12           -- calculs de route au plus
ADObstacleDetourEscape.FILE_NAME = "FarmPilot_PassagesBouches.xml"

ADObstacleDetourEscape.passages = {}  -- ["a>b"] = {a, b, half, ax, az, bx, bz, what, by}
ADObstacleDetourEscape.loaded = false

local function log(text, ...)
    print(string.format("[AD-Passage] " .. text, ...))
end

local function nameOf(vehicle)
    local ad = vehicle.ad
    return tostring(ad ~= nil and ad.stateModule ~= nil and ad.stateModule:getName() or vehicle.id)
end

local function dist(ax, az, bx, bz)
    return math.sqrt((ax - bx) * (ax - bx) + (az - bz) * (az - bz))
end

-- distance d'un point au segment ab
local function distToSegment(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local l2 = dx * dx + dz * dz
    local t = 0
    if l2 > 1e-6 then
        t = math.max(0, math.min(1, ((px - ax) * dx + (pz - az) * dz) / l2))
    end
    return dist(px, pz, ax + t * dx, az + t * dz)
end

-- demi-largeur du train arrondie comme le calcul des tronçons étroits (PathCalculationWidth.lua)
function ADObstacleDetourEscape.halfWidthOf(vehicle)
    local width = ADPathCalculator.getPassageWidth(vehicle)
    return math.ceil((width / 2 + ADPathCalculator.WIDTH_MARGIN) * 10) / 10
end

-- ------------------------------------------------------------------------------------------------------------
-- Passages bouchés : sauvegarde dans la partie
-- ------------------------------------------------------------------------------------------------------------
local function savegameFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. ADObstacleDetourEscape.FILE_NAME
end

function ADObstacleDetourEscape.load()
    if ADObstacleDetourEscape.loaded then
        return
    end
    ADObstacleDetourEscape.loaded = true
    local file = savegameFile()
    if file == nil or not fileExists(file) then
        return
    end
    local xml = loadXMLFile("fpPassagesBouches", file)
    if xml == nil or xml == 0 then
        return
    end
    local i, n = 0, 0
    while true do
        local key = string.format("farmPilotPassagesBouches.passage(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local p = {
            a = getXMLInt(xml, key .. "#a"), b = getXMLInt(xml, key .. "#b"), half = getXMLFloat(xml, key .. "#half"),
            ax = getXMLFloat(xml, key .. "#ax"), az = getXMLFloat(xml, key .. "#az"),
            bx = getXMLFloat(xml, key .. "#bx"), bz = getXMLFloat(xml, key .. "#bz"),
            what = getXMLString(xml, key .. "#what"), by = getXMLString(xml, key .. "#by")
        }
        if p.a ~= nil and p.b ~= nil and p.half ~= nil and p.ax ~= nil and p.az ~= nil and p.bx ~= nil and p.bz ~= nil then
            ADObstacleDetourEscape.passages[p.a .. ">" .. p.b] = p
            n = n + 1
        end
        i = i + 1
    end
    delete(xml)
    log("%d tronçon(s) bouché(s) chargé(s)", n)
end

function ADObstacleDetourEscape.save()
    local file = savegameFile()
    if file == nil then
        return
    end
    local xml = createXMLFile("fpPassagesBouches", file, "farmPilotPassagesBouches")
    if xml == nil or xml == 0 then
        return
    end
    local keys = {}
    for k, _ in pairs(ADObstacleDetourEscape.passages) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local p = ADObstacleDetourEscape.passages[k]
        local key = string.format("farmPilotPassagesBouches.passage(%d)", i - 1)
        setXMLInt(xml, key .. "#a", p.a)
        setXMLInt(xml, key .. "#b", p.b)
        setXMLFloat(xml, key .. "#half", p.half)
        setXMLFloat(xml, key .. "#ax", p.ax)
        setXMLFloat(xml, key .. "#az", p.az)
        setXMLFloat(xml, key .. "#bx", p.bx)
        setXMLFloat(xml, key .. "#bz", p.bz)
        setXMLString(xml, key .. "#what", tostring(p.what or "?"))
        setXMLString(xml, key .. "#by", tostring(p.by or "?"))
    end
    saveXMLFile(xml)
    delete(xml)
end

-- réseau changé : passages dont un point a bougé ou disparu oubliés
function ADObstacleDetourEscape.checkNetwork()
    local removed = 0
    for k, p in pairs(ADObstacleDetourEscape.passages) do
        local a, b = ADGraphManager:getWayPointById(p.a), ADGraphManager:getWayPointById(p.b)
        if a == nil or b == nil or dist(a.x, a.z, p.ax, p.az) > ADObstacleDetourEscape.MOVED_POINT
            or dist(b.x, b.z, p.bx, p.bz) > ADObstacleDetourEscape.MOVED_POINT then
            ADObstacleDetourEscape.passages[k] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        log("réseau changé : %d tronçon(s) bouché(s) oublié(s)", removed)
        ADObstacleDetourEscape.save()
    end
end

-- tronçon a -> b bouché pour cette demi-largeur ?
function ADObstacleDetourEscape.isBlocked(aId, bId, half)
    local p = ADObstacleDetourEscape.passages[tostring(aId) .. ">" .. tostring(bId)]
    return p ~= nil and half ~= nil and half >= p.half - 0.05
end

-- ------------------------------------------------------------------------------------------------------------
-- Au pas (après le dernier contournement raté)
-- ------------------------------------------------------------------------------------------------------------
local function samePlace(pos, x, z)
    return pos ~= nil and dist(pos.x, pos.z, x, z) < ADObstacleDetourEscape.SAME_PLACE
end

-- point de l'obstacle : vu par le balayage de la route, sinon là où le capteur avant l'a arrêté (zone interdite du
-- dernier contournement), sinon devant le nez
local function obstaclePoint(odm)
    local approach = odm.vehicle.ad.approachModule
    local hit = approach ~= nil and approach:getHit() or nil
    if hit ~= nil and hit.x ~= nil and hit.z ~= nil and not hit.isVehicle then
        return hit.x, hit.z, tostring(hit.name or approach.hitName or "?")
    end
    local zones = odm.blockedZones
    if zones ~= nil and #zones > 0 and zones[#zones].x ~= nil then
        return zones[#zones].x, zones[#zones].z, tostring(approach ~= nil and approach.hitName or "?")
    end
    local length = odm.vehicle.size ~= nil and odm.vehicle.size.length or 5
    local bx, _, bz = AutoDrive.localToWorld(odm.vehicle, 0, 0, length / 2 + 2.5)
    return bx, bz, "?"
end

-- distance de l'obstacle devant le milieu du tracteur (négative : derrière)
local function aheadOf(odm, ox, oz)
    local x, _, z = odm:getPosition()
    local fx, _, fz = AutoDrive.localToWorld(odm.vehicle, 0, 0, 1)
    local dx, dz = fx - x, fz - z
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 1e-6 then
        return 0
    end
    return ((ox - x) * dx + (oz - z) * dz) / l
end

function ADObstacleDetourEscape.startCreep(odm)
    local x, _, z = odm:getPosition()
    if samePlace(odm.creepPos, x, z) then
        return false
    end
    if odm:isVehicleInFront() or odm:isGateInFront() then
        return false
    end
    local ox, oz, what = obstaclePoint(odm)
    odm.creepPos = {x = x, z = z}
    odm.escapeObstacle = {x = ox, z = oz, name = what}
    -- passé : l'obstacle derrière le tracteur, ou CREEP_DISTANCE m plus loin que lui
    local need = math.max(0, aheadOf(odm, ox, oz)) + ADObstacleDetourEscape.CREEP_DISTANCE
    odm.creep = {sx = x, sz = z, px = x, pz = z, time = 0, noMove = 0, clear = 0, need = need}
    log("%s : contournement impossible, avance au pas (%.1f km/h) sans tenir compte du capteur avant ('%s' à %.1f m)",
        nameOf(odm.vehicle), ADObstacleDetourEscape.CREEP_SPEED, what, aheadOf(odm, ox, oz))
    AutoDriveMessageEvent.sendMessageOrNotification(odm.vehicle, ADMessagesManager.messageTypes.INFO, "$l10n_AD_Driver_of; %s $l10n_AD_obstacleDetour_creep;", 5000, nameOf(odm.vehicle))
    return true
end

-- (DrivePathModuleObstacles.lua, handleDrivingModules) à chaque image pendant l'avance au pas : obstacleDetected
-- rendu (false pour passer, true pour rester arrêté) et vitesse limitée
function ADObstacleDetourEscape.creepOverride(dpm, dt, obstacleDetected)
    local odm = dpm.vehicle.ad ~= nil and dpm.vehicle.ad.obstacleDetourModule or nil
    if odm == nil or odm.creep == nil or not dpm.vehicle.isServer then
        return obstacleDetected
    end
    local c = odm.creep
    local x, _, z = odm:getPosition()
    -- un véhicule devant : arrêt comme d'habitude, l'horloge « coincé » attend
    if obstacleDetected and odm:isVehicleInFront() then
        c.px, c.pz, c.noMove = x, z, 0
        return true
    end
    c.time = c.time + dt
    local moved = dist(c.sx, c.sz, x, z)
    if dist(c.px, c.pz, x, z) >= ADObstacleDetourEscape.CREEP_STUCK_MOVE then
        c.px, c.pz, c.noMove = x, z, 0
    else
        c.noMove = c.noMove + dt
    end
    local o = odm.escapeObstacle
    local behind = o ~= nil and aheadOf(odm, o.x, o.z) < 0
    if obstacleDetected or not behind then
        c.clear = 0
    else
        c.clear = c.clear + dt
    end
    if moved >= c.need or (moved >= ADObstacleDetourEscape.CREEP_MIN_MOVE and c.clear >= ADObstacleDetourEscape.CREEP_CLEAR_TIME) then
        log("%s : passé au pas (%.1f m), la route continue", nameOf(odm.vehicle), moved)
        odm.creep = nil
        odm.attemptsHere = 0
        odm.lastAttemptPos = nil
        return obstacleDetected
    end
    if c.noMove >= ADObstacleDetourEscape.CREEP_STUCK_TIME or c.time >= ADObstacleDetourEscape.CREEP_TIMEOUT then
        log("%s : toujours coincé au pas (%.1f m roulés en %.0f s)", nameOf(odm.vehicle), moved, c.time / 1000)
        odm.creep = nil
        local ok, err = FarmPilotCall(ADObstacleDetourEscape.reroute, odm)
        if not ok then
            log("ERREUR passage bouché : %s", tostring(err))
        end
        return true
    end
    dpm.speedLimit = math.min(dpm.speedLimit or ADObstacleDetourEscape.CREEP_SPEED, ADObstacleDetourEscape.CREEP_SPEED)
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Passage bouché : retenu, puis demi-tour par une autre route
-- ------------------------------------------------------------------------------------------------------------
local function isNetworkPoint(wp)
    return wp ~= nil and wp.id ~= nil and not wp.isPathFinderPoint and ADGraphManager:getWayPointById(wp.id) ~= nil
end

-- tronçons du réseau de la route près de l'obstacle ; index du premier
local function blockedSections(wayPoints, currentIndex, ox, oz)
    local list, first = {}, nil
    local from = math.max(1, (currentIndex or 1) - 4)
    local to = math.min(#wayPoints - 1, (currentIndex or 1) + 8)
    for i = from, to do
        local a, b = wayPoints[i], wayPoints[i + 1]
        if isNetworkPoint(a) and isNetworkPoint(b) and distToSegment(ox, oz, a.x, a.z, b.x, b.z) <= ADObstacleDetourEscape.BLOCK_RADIUS then
            list[#list + 1] = {a = a, b = b}
            first = first or i
        end
    end
    return list, first
end

local function addPassage(a, b, half, what, by)
    local key = a.id .. ">" .. b.id
    local old = ADObstacleDetourEscape.passages[key]
    if old ~= nil and old.half <= half then
        return
    end
    ADObstacleDetourEscape.passages[key] = {a = a.id, b = b.id, half = half, ax = a.x, az = a.z, bx = b.x, bz = b.z, what = what, by = by}
end

local function hasOut(wp, id)
    if wp == nil or wp.out == nil then
        return false
    end
    for _, outId in pairs(wp.out) do
        if outId == id then
            return true
        end
    end
    return false
end

local function routeHasBlocked(route, half)
    for i = 1, #route - 1 do
        if route[i].id ~= nil and route[i + 1].id ~= nil and ADObstacleDetourEscape.isBlocked(route[i].id, route[i + 1].id, half) then
            return true
        end
    end
    return false
end

-- points du réseau d'où repartir : ceux de la route avant le passage (demi-tour sur la même route), puis les plus
-- proches du véhicule (route à sens unique) ; jamais un point au-delà de l'obstacle
local function startCandidates(odm, wayPoints, first, x, z, ox, oz)
    local list, seen = {}, {}
    local limit = aheadOf(odm, ox, oz) - 1
    for i = first + 1, #wayPoints do
        if wayPoints[i].id ~= nil then
            seen[wayPoints[i].id] = true
        end
    end
    local function add(wp)
        if wp ~= nil and wp.id ~= nil and not seen[wp.id] and #list < ADObstacleDetourEscape.MAX_STARTS and aheadOf(odm, wp.x, wp.z) < limit then
            seen[wp.id] = true
            list[#list + 1] = wp.id
        end
    end
    for i = first, 1, -1 do
        local wp = wayPoints[i]
        if isNetworkPoint(wp) then
            if dist(wp.x, wp.z, x, z) > ADObstacleDetourEscape.START_RANGE then
                break
            end
            add(wp)
        end
    end
    local near = {}
    for _, id in ipairs(ADGraphManager:getWayPointsInRange({x = x, z = z}, 0, ADObstacleDetourEscape.START_RANGE) or {}) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            near[#near + 1] = {wp = wp, d = dist(wp.x, wp.z, x, z)}
        end
    end
    table.sort(near, function(p, q) return p.d < q.d end)
    for _, p in ipairs(near) do
        add(p.wp)
    end
    return list
end

function ADObstacleDetourEscape.reroute(odm)
    local vehicle = odm.vehicle
    local name = nameOf(vehicle)
    local x, y, z = odm:getPosition()
    if samePlace(odm.reroutePos, x, z) then
        return false
    end
    odm.reroutePos = {x = x, z = z}
    local dpm = vehicle.ad.drivePathModule
    local wayPoints, currentIndex = dpm:getWayPoints()
    if wayPoints == nil or #wayPoints < 2 then
        return false
    end
    ADObstacleDetourEscape.load()
    local ox, oz, what
    if odm.escapeObstacle ~= nil then
        ox, oz, what = odm.escapeObstacle.x, odm.escapeObstacle.z, odm.escapeObstacle.name
    else
        ox, oz, what = obstaclePoint(odm)
    end
    local list, first = blockedSections(wayPoints, currentIndex, ox, oz)
    if #list == 0 then
        log("%s : pas de tronçon du réseau près de l'obstacle « %s » : arrêt comme avant", name, what)
        return false
    end
    local half = ADObstacleDetourEscape.halfWidthOf(vehicle)
    for _, s in ipairs(list) do
        addPassage(s.a, s.b, half, what, name)
        -- route à double sens : l'autre sens est bouché aussi
        if hasOut(ADGraphManager:getWayPointById(s.b.id), s.a.id) then
            addPassage(s.b, s.a, half, what, name)
        end
    end
    ADObstacleDetourEscape.save()
    log("%s : passage bouché retenu (%d tronçon(s) près de « %s » à %.0f,%.0f, train de %.1f m et plus large)", name, #list, what, ox, oz, half * 2)

    -- destination : dernier point du réseau de la route
    local destId = nil
    for i = #wayPoints, 1, -1 do
        if isNetworkPoint(wayPoints[i]) then
            destId = wayPoints[i].id
            break
        end
    end
    local route, startId = nil, nil
    if destId ~= nil then
        for _, id in ipairs(startCandidates(odm, wayPoints, first, x, z, ox, oz)) do
            local r = ADGraphManager:pathFromTo(id, destId, {}, vehicle)
            -- la route donnée commence après son point de départ
            if r ~= nil and #r >= 1 and r[1].id ~= id then
                table.insert(r, 1, ADGraphManager:getWayPointById(id))
            end
            if r ~= nil and #r >= 2 and not routeHasBlocked(r, half) then
                route, startId = r, id
                break
            end
        end
    end
    if route == nil then
        log("%s : pas d'autre route vers la destination : arrêt, le passage reste retenu", name)
        AutoDriveMessageEvent.sendMessageOrNotification(vehicle, ADMessagesManager.messageTypes.ERROR, "$l10n_AD_Driver_of; %s $l10n_AD_obstacleDetour_failed;", 8000, name)
        return false
    end
    -- nouvelle route, puis chemin jusqu'à son premier point du réseau à 25 m ou plus (demi-tour)
    odm.rerouteOld = {wayPoints = wayPoints, index = currentIndex}
    local newWayPoints = {{x = x, y = y, z = z, isPathFinderPoint = true}}
    for _, wp in ipairs(route) do
        newWayPoints[#newWayPoints + 1] = wp
    end
    dpm.wayPoints = newWayPoints
    dpm:setCurrentWayPointIndex(2)
    dpm.minDistanceToNextWp = math.huge
    dpm.minDistanceTimer:timer(false)
    dpm:setDirtyFlag()
    log("%s : autre route de %d points depuis le point %s, demi-tour calculé", name, #route, tostring(startId))
    AutoDriveMessageEvent.sendMessageOrNotification(vehicle, ADMessagesManager.messageTypes.INFO, "$l10n_AD_Driver_of; %s $l10n_AD_obstacleDetour_reroute;", 8000, name)
    odm.reversedDistance = 0
    odm.rerouting = true
    odm:startPlanning()
    return true
end

-- demi-tour impossible : la route d'avant, arrêt comme avant (le passage reste retenu)
local function rerouteFailed(odm)
    local old = odm.rerouteOld
    odm.rerouteOld = nil
    odm.rerouting = nil
    if old ~= nil then
        local dpm = odm.vehicle.ad.drivePathModule
        dpm.wayPoints = old.wayPoints
        dpm:setCurrentWayPointIndex(old.index or 1)
        dpm:setDirtyFlag()
    end
    log("%s : pas de chemin pour faire demi-tour : arrêt, l'autre route sera prise au prochain départ", nameOf(odm.vehicle))
end

-- ------------------------------------------------------------------------------------------------------------
-- Branchements
-- ------------------------------------------------------------------------------------------------------------
function ADObstacleDetourEscape.install(module)
    if module == nil or module.adEscapeInstalled then
        return
    end
    module.adEscapeInstalled = true
    local baseFail, baseControlling, basePlanning = module.fail, module.isControlling, module.updatePlanning
    local baseHandle, baseReset = module.handle, module.reset
    module.fail = function(self, reason)
        local rerouting = self.rerouting
        baseFail(self, reason)
        if rerouting then
            rerouteFailed(self)
            return
        end
        if (self.attemptsHere or 0) >= ADObstacleDetourModule.MAX_ATTEMPTS_SAME_PLACE then
            local ok, err = FarmPilotCall(ADObstacleDetourEscape.startCreep, self)
            if not ok then
                self.creep = nil
                log("ERREUR avance au pas : %s", tostring(err))
            end
        end
    end
    -- pendant l'avance au pas, la sécurité « coincé » et l'écart ne s'en mêlent pas
    module.isControlling = function(self)
        return self.creep ~= nil or baseControlling(self)
    end
    -- pendant l'avance au pas, pas de nouveau contournement
    module.handle = function(self, dt, obstacleDetected)
        if self.creep ~= nil and self.state == ADObstacleDetourModule.STATE_IDLE then
            self.blockTimer:timer(false)
            return false
        end
        return baseHandle(self, dt, obstacleDetected)
    end
    -- demi-tour trouvé : fin du demi-tour
    module.updatePlanning = function(self, dt)
        basePlanning(self, dt)
        if self.rerouting and self.state == ADObstacleDetourModule.STATE_IDLE then
            self.rerouting = nil
            self.rerouteOld = nil
        end
    end
    -- nouvelle route donnée (ADDrivePathModule:reset)
    module.reset = function(self)
        baseReset(self)
        self.creep = nil
        self.creepPos = nil
        self.reroutePos = nil
        self.escapeObstacle = nil
        self.rerouting = nil
        self.rerouteOld = nil
    end
    -- calcul de route (GetPath seulement, pas le décalage autour d'un poteau) : tronçons bouchés pour cette largeur
    if ADPathCalculator ~= nil and not ADPathCalculator.adEscapeInstalled then
        ADPathCalculator.adEscapeInstalled = true
        local baseGetPath, baseWeight, baseWidthReset = ADPathCalculator.GetPath, ADPathCalculator.getNarrowWeightFunc, ADPathCalculator.resetWidthCache
        ADPathCalculator.GetPath = function(calc, ...)
            ADObstacleDetourEscape.inGetPath = true
            local ok, path = FarmPilotCall(baseGetPath, calc, ...)
            ADObstacleDetourEscape.inGetPath = false
            if not ok then
                error(path, 0)
            end
            return path
        end
        ADPathCalculator.getNarrowWeightFunc = function(calc, vehicle)
            local f = baseWeight(calc, vehicle)
            if not ADObstacleDetourEscape.inGetPath or vehicle == nil then
                return f
            end
            ADObstacleDetourEscape.load()
            if next(ADObstacleDetourEscape.passages) == nil then
                return f
            end
            local okH, half = FarmPilotCall(ADObstacleDetourEscape.halfWidthOf, vehicle)
            if not okH then
                return f
            end
            return function(a, b)
                if ADObstacleDetourEscape.isBlocked(a.id, b.id, half) then
                    return ADPathCalculator.NARROW_WEIGHT
                end
                return f(a, b)
            end
        end
        ADPathCalculator.resetWidthCache = function()
            baseWidthReset()
            ADObstacleDetourEscape.load()
            local ok, err = FarmPilotCall(ADObstacleDetourEscape.checkNetwork)
            if not ok then
                log("ERREUR réseau changé : %s", tostring(err))
            end
        end
    end
end
