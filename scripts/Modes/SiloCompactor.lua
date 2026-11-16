-- ============================================================================================================
-- FarmPilot : SiloCompactor.lua
-- Silo couloir à l'ensilage : bennes réparties sur la largeur, tracteur tasseur, silo fermé respecté (16/11).
--
-- Avant : code AutoDrive d'origine seul. Chaque benne suit la même route dans le silo et vide en roulant (vitesse
-- calculée pour finir 2 m avant le fond, ADTrailerModule:getBunkerSiloSpeed) : toutes vident sur la même ligne, tas
-- au milieu, côtés vides. Aucun tasseur, aucune vérification de l'état du silo, « une benne à la fois »
-- (ADUnloadManager) seulement si le réglage UMRange n'est pas sur Non (Non par défaut).
-- Le jeu (BunkerSilo.lua) ne laisse bâcher qu'à 100 % de tassage (getCanCloseSilo). Le tassage avance avec la
-- distance roulée dans le silo x masse du véhicule x part des roues posées sur le silo.
--
-- Règles :
-- 1. Couloirs de vidage : la largeur du silo est partagée en couloirs (milieu, gauche, droite selon la largeur) ;
--    chaque benne qui va vider dans le silo prend le couloir suivant. Seule la fin de sa route est décalée de côté :
--    les points dans le silo, et en rampe sur les RAMP m avant l'entrée. Jamais à moins de WALL_MARGIN m d'un mur.
-- 2. Tasseur : voir SiloCompactorTask.lua (fenêtre « Tassage », SiloCompactGUI.lua).
-- 3. Silo bâché, en fermentation ou en vidage : aucune benne n'y entre. Elle s'arrête à HOLD_DIST m et attend,
--    message toutes les MSG_REPEAT. Le tasseur s'arrête (message) quand le silo n'est plus en remplissage.
-- 4. Un tasseur travaille : une seule benne à la fois dans le silo (la plus proche), même si UMRange est sur Non ;
--    tasseur dans le silo : les bennes attendent à HOLD_DIST m qu'il soit sorti.
-- 5. 100 % de tassage et plus aucune benne depuis IDLE_TIME : message « bâchage possible ». Pas de bâche
--    automatique : le joueur décide. Puis, selon la fenêtre « Tassage » : il attend et reprend si le silo se
--    remplit encore, ou il s'arrête.
-- 6. Silo à fond : la benne entre en marche arrière jusqu'au fond, puis ressort en marche avant en vidant (16/11).
--    Silo traversant : elle traverse en vidant, comme avant. Fond détecté par un rayon (getWall).
--
-- Enveloppes posées au chargement : ADDrivePathModule:setPathTo et setWayPoints (1), ADUnloadManager:update (3 et 4),
-- UnloadAtDestinationTask:update (6).
-- ============================================================================================================

ADSiloCompactor = {}

ADSiloCompactor.UPDATE_TIME = 1000      -- ms, contrôle des bennes autour des silos
ADSiloCompactor.RAMP = 15               -- m avant l'entrée où la benne glisse vers son couloir
ADSiloCompactor.WALL_MARGIN = 0.8       -- m entre la benne et le mur
ADSiloCompactor.MIN_SIDE_SHIFT = 1.5    -- m, en dessous un couloir de côté ne sert à rien : couloir unique
ADSiloCompactor.APPROACH = 40           -- m, benne à cette distance du silo : le tasseur sort
ADSiloCompactor.HOLD_DIST = 20          -- m, benne arrêtée à cette distance du silo (fermé, tasseur dedans, autre benne)
ADSiloCompactor.WAIT_ALONG = 12         -- m devant l'entrée, place d'attente du tasseur
ADSiloCompactor.WAIT_SIDE = 5           -- m à côté du bord du silo, place d'attente du tasseur
ADSiloCompactor.END_MARGIN = 2          -- m du fond, comme les bennes
ADSiloCompactor.LANE_OVERLAP = 0.8      -- couloirs du tasseur : recouvrement de 20 %
ADSiloCompactor.SPEED_FWD = 8           -- km/h
ADSiloCompactor.SPEED_REV = 7           -- km/h
ADSiloCompactor.STUCK_TIME = 15000      -- ms sans avancer : bout du couloir considéré atteint (tas trop haut)
ADSiloCompactor.LEG_MAX_TIME = 120000   -- ms au plus pour un aller ou un retour
ADSiloCompactor.IDLE_TIME = 120000      -- ms sans benne avant le message des 100 %
ADSiloCompactor.MSG_REPEAT = 60000      -- ms entre deux messages « silo fermé » pour la même benne

ADSiloCompactor.lastUpdate = 0

local function log(fmt, ...)
    print("[FP-Silo] " .. string.format(fmt, ...))
end

local function nameOf(v)
    if v ~= nil and v.getName ~= nil then
        return tostring(v:getName())
    end
    return "?"
end

-- ------------------------------------------------------------------------------------------------------------
-- Géométrie du silo (bunkerSiloArea.inner : s = coin d'entrée, w = coin largeur, h = coin du fond)
-- across = m depuis le bord gauche (0..width), along = m depuis l'entrée (0..length)
-- ------------------------------------------------------------------------------------------------------------
function ADSiloCompactor.getGeometry(silo, flip)
    local a = silo ~= nil and silo.bunkerSiloArea ~= nil and silo.bunkerSiloArea.inner or nil
    if a == nil or a.sx == nil or a.wx == nil or a.hx == nil then
        return nil
    end
    local wx, wz = a.wx - a.sx, a.wz - a.sz
    local hx, hz = a.hx - a.sx, a.hz - a.sz
    local width = MathUtil.vector2Length(wx, wz)
    local length = MathUtil.vector2Length(hx, hz)
    if width < 1 or length < 1 then
        return nil
    end
    local g = { sx = a.sx, sz = a.sz, ux = wx / width, uz = wz / width, vx = hx / length, vz = hz / length, width = width, length = length, flip = flip == true }
    if g.flip then
        -- entrée de l'autre côté (silo traversant) : origine au coin du fond, sens inversé, bord gauche gardé
        g.sx, g.sz = a.hx, a.hz
        g.vx, g.vz = -g.vx, -g.vz
    end
    return g
end

function ADSiloCompactor.toLocal(g, x, z)
    local dx, dz = x - g.sx, z - g.sz
    return dx * g.ux + dz * g.uz, dx * g.vx + dz * g.vz
end

function ADSiloCompactor.point(g, across, along)
    local x = g.sx + g.ux * across + g.vx * along
    local z = g.sz + g.uz * across + g.vz * along
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
    return { x = x, y = y, z = z }
end

-- distance d'un point au rectangle du silo (0 dedans)
function ADSiloCompactor.distanceTo(g, x, z)
    local across, along = ADSiloCompactor.toLocal(g, x, z)
    local dx = math.max(0, -across, across - g.width)
    local dz = math.max(0, -along, along - g.length)
    return MathUtil.vector2Length(dx, dz)
end

function ADSiloCompactor.vehicleDistance(g, vehicle)
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    return ADSiloCompactor.distanceTo(g, x, z)
end

-- ------------------------------------------------------------------------------------------------------------
-- Silo à fond ou traversant (16/11)
-- Un rayon à 2 m de haut, tiré dans l'axe du silo depuis chaque bout vers l'autre : s'il touche un objet posé (le
-- silo lui-même, son mur du fond), ce bout-là est fermé. Le tas d'ensilage (sol du jeu) n'est pas un objet posé.
-- silo.fpWall = "h" (fond côté coin h), "s" (fond côté coin s) ou "none" (traversant)
-- ------------------------------------------------------------------------------------------------------------
ADSiloCompactor.wallRay = {}

function ADSiloCompactor.wallRay:callback(hitObjectId, x, y, z, distance)
    if hitObjectId ~= nil and hitObjectId ~= 0 and g_currentMission ~= nil and g_currentMission.getNodeObject ~= nil then
        local object = g_currentMission:getNodeObject(hitObjectId)
        if object ~= nil and Placeable ~= nil and object.isa ~= nil and object:isa(Placeable) then
            self.hit = true
            return false
        end
    end
    return true -- le tas, un véhicule... : on continue
end

local function castWall(x, z, dx, dz, length)
    if raycastAll == nil then
        return nil
    end
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z) + 2
    ADSiloCompactor.wallRay.hit = false
    raycastAll(x, y, z, dx, 0, dz, length, "callback", ADSiloCompactor.wallRay)
    return ADSiloCompactor.wallRay.hit
end

function ADSiloCompactor.getWall(silo)
    if silo.fpWall ~= nil then
        return silo.fpWall
    end
    local g = ADSiloCompactor.getGeometry(silo)
    if g == nil then
        return "none"
    end
    local mid = g.width / 2
    local okA, towardH = FarmPilotCall(castWall, g.sx + g.ux * mid + g.vx * 2, g.sz + g.uz * mid + g.vz * 2, g.vx, g.vz, g.length + 2)
    local okB, towardS = FarmPilotCall(castWall, g.sx + g.ux * mid + g.vx * (g.length - 2), g.sz + g.uz * mid + g.vz * (g.length - 2), -g.vx, -g.vz, g.length + 2)
    if not okA or not okB or towardH == nil or towardS == nil then
        return "none" -- pas de rayon possible : traité comme traversant, sans le garder (nouvel essai la fois suivante)
    end
    if towardH and not towardS then
        silo.fpWall = "h"
    elseif towardS and not towardH then
        silo.fpWall = "s"
    else
        silo.fpWall = "none"
    end
    log("silo %.0f x %.0f m : %s", g.width, g.length, silo.fpWall == "none" and "traversant" or "a fond")
    return silo.fpWall
end

function ADSiloCompactor.hasBackWall(silo)
    return ADSiloCompactor.getWall(silo) ~= "none"
end

-- géométrie avec l'entrée au bon bout : silo à fond = toujours le bout ouvert ; traversant = flipIfOpen
function ADSiloCompactor.getEntryGeometry(silo, flipIfOpen)
    local wall = ADSiloCompactor.getWall(silo)
    if wall == "h" then
        return ADSiloCompactor.getGeometry(silo, false)
    elseif wall == "s" then
        return ADSiloCompactor.getGeometry(silo, true)
    end
    return ADSiloCompactor.getGeometry(silo, flipIfOpen == true)
end

-- ------------------------------------------------------------------------------------------------------------
-- État du silo
-- ------------------------------------------------------------------------------------------------------------
function ADSiloCompactor.isFilling(silo)
    if silo == nil or silo.state == nil or BunkerSilo == nil or BunkerSilo.STATE_FILL == nil then
        return true -- inconnu : comme avant
    end
    return silo.state == BunkerSilo.STATE_FILL
end

function ADSiloCompactor.getCompactedPercent(silo)
    return silo ~= nil and silo.compactedPercent or 0
end

-- silo dont la zone contient le point (x, z)
function ADSiloCompactor.getSiloAt(x, z)
    if ADTriggerManager == nil or ADTriggerManager.getBunkerSilos == nil then
        return nil
    end
    for _, silo in pairs(ADTriggerManager.getBunkerSilos()) do
        local g = ADSiloCompactor.getGeometry(silo)
        if g ~= nil and ADSiloCompactor.distanceTo(g, x, z) <= 0 then
            return silo, g
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Véhicules
-- ------------------------------------------------------------------------------------------------------------
-- tracteur sans benne : rien d'attelé qui se vide (benne, remorque, épandeur...) et pas un camion benne
function ADSiloCompactor.isCompactorCandidate(vehicle)
    if vehicle == nil or vehicle.spec_dischargeable ~= nil then
        return false
    end
    local units = AutoDrive.getAllUnits(vehicle)
    for _, unit in pairs(units or {}) do
        if unit ~= vehicle and unit.spec_leveler == nil and unit.spec_bunkerSiloCompacter == nil
            and (unit.spec_dischargeable ~= nil or unit.spec_trailer ~= nil) then -- lame, rouleau : acceptés
            return false
        end
    end
    return true
end

function ADSiloCompactor.getFill(vehicle)
    local units = AutoDrive.getAllUnits(vehicle)
    if units == nil or #units == 0 then
        return 0
    end
    local fill = AutoDrive.getAllFillLevels(units)
    return fill or 0
end

-- largeur de l'attelage (la plus large des unités)
function ADSiloCompactor.getWidth(vehicle)
    local w = vehicle.size ~= nil and vehicle.size.width or 3
    for _, unit in pairs(AutoDrive.getAllUnits(vehicle) or {}) do
        if unit.size ~= nil and unit.size.width ~= nil then
            w = math.max(w, unit.size.width)
        end
    end
    return w
end

function ADSiloCompactor.getCompactor(silo)
    local c = silo ~= nil and silo.fpCompactor or nil
    if c == nil then
        return nil
    end
    local task = c.ad ~= nil and c.ad.taskModule ~= nil and c.ad.taskModule:getActiveTask() or nil
    if c.ad == nil or c.ad.stateModule == nil or not c.ad.stateModule:isActive() or task == nil or task.fpSiloCompact ~= true or task.silo ~= silo then
        silo.fpCompactor = nil -- arrêté par le joueur ou autre tâche
        return nil
    end
    return c, task
end

-- ------------------------------------------------------------------------------------------------------------
-- 1. Couloirs de vidage
-- ------------------------------------------------------------------------------------------------------------
-- décalages possibles depuis l'axe du silo : milieu d'abord, puis gauche, droite
function ADSiloCompactor.getUnloadLaneShifts(width, unitWidth)
    local side = width / 2 - unitWidth / 2 - ADSiloCompactor.WALL_MARGIN
    if side < ADSiloCompactor.MIN_SIDE_SHIFT then
        return { 0 }
    end
    return { 0, -side, side }
end

-- décale la fin de la route (points dans le silo et rampe avant l'entrée) ; les points du réseau ne sont pas touchés
function ADSiloCompactor.shiftRoute(wayPoints, g, shift)
    local count = #wayPoints
    local first = nil
    for i = count, 1, -1 do
        local wp = wayPoints[i]
        local across, along = ADSiloCompactor.toLocal(g, wp.x, wp.z)
        if across < -1 or across > g.width + 1 or along < -ADSiloCompactor.RAMP or along > g.length + 1 then
            break
        end
        first = i
    end
    if first == nil then
        return wayPoints, 0
    end
    local out = {}
    local moved = 0
    for i = 1, count do
        local wp = wayPoints[i]
        if i >= first then
            local _, along = ADSiloCompactor.toLocal(g, wp.x, wp.z)
            local factor = 1
            if along < 0 then
                factor = math.max(0, 1 + along / ADSiloCompactor.RAMP)
            end
            local copy = {}
            for k, v in pairs(wp) do
                copy[k] = v
            end
            copy.fpSiloShift = true
            copy.x = wp.x + g.ux * shift * factor
            copy.z = wp.z + g.uz * shift * factor
            out[i] = copy
            moved = moved + 1
        else
            out[i] = wp
        end
    end
    return out, moved
end

function ADSiloCompactor.onPathSet(drivePathModule)
    local vehicle = drivePathModule.vehicle
    local wps = drivePathModule.wayPoints
    if vehicle == nil or vehicle.ad == nil or wps == nil or #wps < 2 then
        return
    end
    local last = wps[#wps]
    if last.fpSiloShift then
        return -- route déjà décalée
    end
    local silo, g = ADSiloCompactor.getSiloAt(last.x, last.z)
    if silo == nil or not ADSiloCompactor.isFilling(silo) or ADSiloCompactor.isCompactorCandidate(vehicle) or ADSiloCompactor.getFill(vehicle) < 0.1 then
        return
    end
    -- entrée = côté d'où arrive la route
    local entryIndex = #wps
    for i = #wps, 1, -1 do
        if ADSiloCompactor.distanceTo(g, wps[i].x, wps[i].z) > 0 then
            entryIndex = i
            break
        end
    end
    local _, along = ADSiloCompactor.toLocal(g, wps[entryIndex].x, wps[entryIndex].z)
    g = ADSiloCompactor.getEntryGeometry(silo, along > g.length / 2)
    local shifts = ADSiloCompactor.getUnloadLaneShifts(g.width, ADSiloCompactor.getWidth(vehicle))
    silo.fpNextLane = ((silo.fpNextLane or 0) % #shifts) + 1
    local shift = shifts[silo.fpNextLane]
    if shift == 0 then
        log("%s : vide au milieu du silo (couloir %d/%d, silo %.1f m de large)", nameOf(vehicle), silo.fpNextLane, #shifts, g.width)
        return
    end
    local out, moved = ADSiloCompactor.shiftRoute(wps, g, shift)
    drivePathModule.wayPoints = out
    drivePathModule:setDirtyFlag()
    log("%s : vide dans le couloir %d/%d, decale de %.1f m (%d points, silo %.1f m de large)", nameOf(vehicle), silo.fpNextLane, #shifts, shift, moved, g.width)
end

-- ------------------------------------------------------------------------------------------------------------
-- 3 et 4. Bennes autour des silos (toutes les UPDATE_TIME ms, serveur)
-- ------------------------------------------------------------------------------------------------------------
function ADSiloCompactor.update(dt)
    if g_time < ADSiloCompactor.lastUpdate + ADSiloCompactor.UPDATE_TIME then
        return
    end
    ADSiloCompactor.lastUpdate = g_time
    if ADTriggerManager == nil or ADTriggerManager.getBunkerSilos == nil then
        return
    end
    for _, silo in pairs(ADTriggerManager.getBunkerSilos()) do
        local g = ADSiloCompactor.getGeometry(silo)
        if g ~= nil then
            ADSiloCompactor.updateSilo(silo, g)
        end
    end
end

function ADSiloCompactor.updateSilo(silo, g)
    -- bennes chargées qui vont vider dans ce silo
    local trailers = {}
    for _, vehicle in pairs(AutoDrive.getAllVehicles()) do
        if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:isActive()
            and not ADSiloCompactor.isCompactorCandidate(vehicle)
            and ADUnloadManager:isDestinationInBunkerSilo(vehicle, silo) and ADSiloCompactor.getFill(vehicle) >= 0.1 then
            table.insert(trailers, { v = vehicle, d = ADSiloCompactor.vehicleDistance(g, vehicle) })
        end
    end
    silo.fpTrailerNear = false
    if #trailers == 0 then
        return
    end
    for _, t in ipairs(trailers) do
        if t.d < ADSiloCompactor.APPROACH then
            silo.fpTrailerNear = true
            silo.fpLastTrailerTime = g_time
        end
    end

    -- 3. silo fermé : personne n'entre
    if not ADSiloCompactor.isFilling(silo) then
        for _, t in ipairs(trailers) do
            if t.d > 0 and t.d < ADSiloCompactor.HOLD_DIST then
                t.v.ad.drivePathModule:setPaused()
                if t.v.ad.fpSiloClosedMsg == nil or g_time - t.v.ad.fpSiloClosedMsg > ADSiloCompactor.MSG_REPEAT then
                    t.v.ad.fpSiloClosedMsg = g_time
                    log("%s : silo ferme (etat %s), attend devant", nameOf(t.v), tostring(silo.state))
                    AutoDriveMessageEvent.sendMessageOrNotification(t.v, ADMessagesManager.messageTypes.WARN, "$l10n_AD_Driver_of; %s: $l10n_AD_fp_silo_closed;", 5000, t.v.ad.stateModule:getName())
                end
            end
        end
        return
    end

    -- 4. tasseur au travail : une benne à la fois, et aucune tant qu'il est dans le silo
    local compactor, task = ADSiloCompactor.getCompactor(silo)
    if compactor == nil then
        return
    end
    local compactorInside = task:isInSilo()
    local allowed = nil
    if not compactorInside then
        for _, t in ipairs(trailers) do
            if t.d <= 0 then
                allowed = t.v -- déjà dedans
                break
            end
            if allowed == nil or t.d < ADSiloCompactor.vehicleDistance(g, allowed) then
                allowed = t.v
            end
        end
    end
    for _, t in ipairs(trailers) do
        if t.v ~= allowed and t.d > 0 and t.d < ADSiloCompactor.HOLD_DIST then
            t.v.ad.drivePathModule:setPaused()
            if t.v.ad.fpSiloHoldLogged ~= silo then
                t.v.ad.fpSiloHoldLogged = silo
                log("%s : attend devant le silo (%s)", nameOf(t.v), compactorInside and "tasseur dans le silo" or ("benne " .. nameOf(allowed) .. " en premier"))
            end
        elseif t.v.ad.fpSiloHoldLogged == silo then
            t.v.ad.fpSiloHoldLogged = nil
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- 6. Silo à fond : la benne entre en marche arrière jusqu'au fond (route du joueur, comme avant), commence à vider
--    au fond, puis ressort en marche avant en vidant : le tas est étalé sur la longueur au lieu d'un seul tas au
--    fond. Vitesse = distance jusqu'à l'entrée / temps qu'il faut pour vider ce qui reste. Arrivée à l'entrée pas
--    encore vide : elle finit sur place comme avant. Silo traversant : rien de changé (elle traverse en vidant).
-- ------------------------------------------------------------------------------------------------------------
ADSiloCompactor.SPREAD_MIN_SPEED = 1.5  -- km/h
ADSiloCompactor.SPREAD_MAX_SPEED = 10   -- km/h
ADSiloCompactor.SPREAD_EXIT = 2         -- m après l'entrée : bout de la ressortie

function ADSiloCompactor.spreadOut(task, dt)
    local v = task.vehicle
    if v == nil or v.ad == nil or v.ad.trailerModule == nil or v.ad.drivePathModule == nil then
        return false
    end
    local tm, dpm = v.ad.trailerModule, v.ad.drivePathModule
    local sp = task.fpSpread
    if sp == nil then
        if task.fpSpreadDone or not dpm:isTargetReached() or not tm:isUnloadingToBunkerSilo() or not dpm:getIsReversing() then
            return false
        end
        local silo = tm:getBunkerTrigger()
        if silo == nil or silo.bunkerSiloArea == nil or not ADSiloCompactor.hasBackWall(silo) or ADSiloCompactor.getFill(v) < 0.1 then
            return false
        end
        local g = ADSiloCompactor.getEntryGeometry(silo)
        local x, _, z = getWorldTranslation(v.components[1].node)
        local across = ADSiloCompactor.toLocal(g, x, z)
        across = math.max(0, math.min(g.width, across))
        sp = { silo = silo, exit = ADSiloCompactor.point(g, across, -ADSiloCompactor.SPREAD_EXIT) }
        task.fpSpread = sp
        log("%s : au fond du silo, ressort en marche avant en vidant (%.0f l)", nameOf(v), ADSiloCompactor.getFill(v))
    end
    tm:update(dt)
    local fill = ADSiloCompactor.getFill(v)
    local x, _, z = getWorldTranslation(v.components[1].node)
    local dist = MathUtil.vector2Length(x - sp.exit.x, z - sp.exit.z)
    if fill < 0.1 or not tm:isUnloadingToBunkerSilo() or dist < 1.5 then
        log("%s : fin de la ressortie en vidant (reste %.0f l, %.1f m de l'entree)", nameOf(v), fill, dist)
        task.fpSpread = nil
        task.fpSpreadDone = true
        v.ad.specialDrivingModule:stopVehicle()
        v.ad.specialDrivingModule:update(dt)
        return true
    end
    local speed = ADSiloCompactor.SPREAD_MAX_SPEED
    local trailer = tm.bunkerTrailer
    local node = trailer ~= nil and trailer.getCurrentDischargeNode ~= nil and trailer:getCurrentDischargeNode() or nil
    if node ~= nil and node.emptySpeed ~= nil and node.emptySpeed > 0 then
        local timeS = (fill / node.emptySpeed) / 1000
        speed = dist / math.max(1, timeS) * 3.6
    end
    speed = math.max(ADSiloCompactor.SPREAD_MIN_SPEED, math.min(ADSiloCompactor.SPREAD_MAX_SPEED, speed))
    v.ad.specialDrivingModule:driveToPoint(dt, sp.exit, speed, false, 0.5, speed, true)
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes
-- ------------------------------------------------------------------------------------------------------------
-- 1. route vers le point de vidage : couloir de la benne
local baseSetPathTo = ADDrivePathModule.setPathTo
function ADDrivePathModule:setPathTo(wayPointId)
    local r = baseSetPathTo(self, wayPointId)
    FarmPilotCall(ADSiloCompactor.onPathSet, self)
    return r
end

-- route calculée par le pathfinder (départ du champ) : même chose
local baseSetWayPoints = ADDrivePathModule.setWayPoints
function ADDrivePathModule:setWayPoints(wayPoints)
    local r = baseSetWayPoints(self, wayPoints)
    FarmPilotCall(ADSiloCompactor.onPathSet, self)
    return r
end

-- 3 et 4. bennes autour des silos (appelé chaque image, serveur, même si UMRange est sur Non)
local baseUnloadManagerUpdate = ADUnloadManager.update
function ADUnloadManager:update(dt)
    FarmPilotCall(ADSiloCompactor.update, dt)
    return baseUnloadManagerUpdate(self, dt)
end

-- 6. silo à fond : ressortie en marche avant en vidant
local baseUnloadTaskUpdate = UnloadAtDestinationTask.update
function UnloadAtDestinationTask:update(dt)
    local ok, handled = FarmPilotCall(ADSiloCompactor.spreadOut, self, dt)
    if ok and handled then
        return
    end
    return baseUnloadTaskUpdate(self, dt)
end
