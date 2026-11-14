-- ============================================================================================================
-- FarmPilot : FarmPilotPerf.lua
-- Commande console « fpPerf » : mesure le temps que prend FarmPilot à chaque image et l'écrit dans log.txt (14/11).
--
-- D'où ça vient : retour d'un joueur le 14/11 (ralentissements avec 3 moissonneuses et 9 tracteurs). Sans mesure, on
-- ne sait pas si le temps part dans FarmPilot, dans un autre mod ou dans le jeu : le joueur lance « fpPerf » dans la
-- console (touche ²), laisse tourner, puis envoie son log.txt.
--
-- Règle :
-- - « fpPerf » : mesure 60 s ; « fpPerf 120 » : 120 s (10 à 600) ; « fpPerf stop » : arrête ;
-- - toutes les 10 s une ligne « [FarmPilot Perf] » : images par seconde du jeu, ms par image prises par FarmPilot
--   (véhicules, général dont calcul de chemin, affichage), pic, recherches du point le plus proche et calculs de
--   route ; puis les véhicules les plus lourds ; à la fin, la moyenne de toute la mesure ;
-- - rien n'est mesuré tant que la commande n'est pas lancée : les enveloppes ne sont posées qu'au lancement et
--   enlevées à la fin.
--
-- Enveloppes (seulement pendant la mesure) : AutoDrive:update, AutoDrive:draw, AutoDrive:onUpdate,
-- AutoDrive:onUpdateTick, AutoDrive:onDrawUIInfo, ADScheduler:update, ADGraphManager:pathFromTo, getPathTo.
-- Les recherches du point le plus proche sont comptées par GraphManagerGrid.lua. Commande posée au chargement de la
-- carte (AutoDrive:loadMap), enlevée à sa fermeture (AutoDrive:deleteMap). Chargé par register.lua.
-- ============================================================================================================

ADFarmPilotPerf = {}

ADFarmPilotPerf.DEFAULT_SECONDS = 60
ADFarmPilotPerf.MIN_SECONDS = 10
ADFarmPilotPerf.MAX_SECONDS = 600
ADFarmPilotPerf.REPORT_INTERVAL = 10000 -- ms entre deux lignes
ADFarmPilotPerf.TOP_VEHICLES = 5

ADFarmPilotPerf.active = false

-- horloge en ms (la plus fine disponible)
function ADFarmPilotPerf.now()
    if getTimeSec ~= nil then
        return getTimeSec() * 1000
    end
    if netGetTime ~= nil then
        return netGetTime()
    end
    return g_time or 0
end

local function log(fmt, ...)
    print("[FarmPilot Perf] " .. string.format(fmt, ...))
end

local function newWindow()
    return {
        frames = 0, frameMs = 0,
        vehicles = 0, global = 0, pathfinder = 0, draw = 0,
        peak = 0, frameFp = 0,
        closestN = 0, closestMs = 0, routeN = 0, routeMs = 0,
        byVehicle = {}, active = {}
    }
end

-- temps ajouté à la mesure en cours (what : "closest", "route")
function ADFarmPilotPerf.add(what, ms)
    local w = ADFarmPilotPerf.window
    if w == nil then
        return
    end
    if what == "closest" then
        w.closestN = w.closestN + 1
        w.closestMs = w.closestMs + ms
    elseif what == "route" then
        w.routeN = w.routeN + 1
        w.routeMs = w.routeMs + ms
    end
end

local function addFrameTime(w, part, ms)
    w[part] = w[part] + ms
    w.frameFp = w.frameFp + ms
end

local function vehicleName(vehicle)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.getName ~= nil then
        local ok, n = pcall(vehicle.ad.stateModule.getName, vehicle.ad.stateModule)
        if ok and n ~= nil then
            return tostring(n)
        end
    end
    if vehicle ~= nil and vehicle.getName ~= nil then
        local ok, n = pcall(vehicle.getName, vehicle)
        if ok and n ~= nil then
            return tostring(n)
        end
    end
    return "?"
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes (posées au lancement, enlevées à la fin)
-- ------------------------------------------------------------------------------------------------------------
ADFarmPilotPerf.wrapped = {}

local function wrap(target, name, makeWrapper)
    local base = target[name]
    if type(base) ~= "function" then
        return
    end
    local wrapper = makeWrapper(base)
    target[name] = wrapper
    table.insert(ADFarmPilotPerf.wrapped, { target = target, name = name, base = base, wrapper = wrapper })
end

local function timed(part)
    return function(base)
        return function(self, ...)
            local w = ADFarmPilotPerf.window
            if w == nil then
                return base(self, ...)
            end
            local t0 = ADFarmPilotPerf.now()
            local a, b, c, d = base(self, ...)
            addFrameTime(w, part, ADFarmPilotPerf.now() - t0)
            return a, b, c, d
        end
    end
end

local function timedVehicle(base)
    return function(self, ...)
        local w = ADFarmPilotPerf.window
        if w == nil then
            return base(self, ...)
        end
        local t0 = ADFarmPilotPerf.now()
        local a, b, c, d = base(self, ...)
        local ms = ADFarmPilotPerf.now() - t0
        addFrameTime(w, "vehicles", ms)
        w.byVehicle[self] = (w.byVehicle[self] or 0) + ms
        if self.ad ~= nil and self.ad.stateModule ~= nil and self.ad.stateModule.isActive ~= nil and self.ad.stateModule:isActive() then
            w.active[self] = true
        end
        return a, b, c, d
    end
end

local function timedSub(what)
    return function(base)
        return function(self, ...)
            local w = ADFarmPilotPerf.window
            if w == nil then
                return base(self, ...)
            end
            -- getPathTo appelle pathFromTo : un seul calcul compté
            if w.inSub == what then
                return base(self, ...)
            end
            w.inSub = what
            local t0 = ADFarmPilotPerf.now()
            local ok, a, b, c, d = pcall(base, self, ...)
            local ms = ADFarmPilotPerf.now() - t0
            w.inSub = nil
            if not ok then
                error(a, 0)
            end
            if what == "pathfinder" then
                w.pathfinder = w.pathfinder + ms
            else
                ADFarmPilotPerf.add(what, ms)
            end
            return a, b, c, d
        end
    end
end

-- AutoDrive:update : une fois par image ; sert aussi à mesurer la durée d'une image du jeu
local function frameWrapper(base)
    return function(self, dt, ...)
        local perf = ADFarmPilotPerf
        if perf.window ~= nil then
            perf.endFrame(dt)
        end
        local w = perf.window
        if w == nil then
            return base(self, dt, ...)
        end
        local t0 = perf.now()
        local a, b, c, d = base(self, dt, ...)
        addFrameTime(w, "global", perf.now() - t0)
        return a, b, c, d
    end
end

function ADFarmPilotPerf.installWrappers()
    if #ADFarmPilotPerf.wrapped > 0 then
        return
    end
    wrap(AutoDrive, "update", frameWrapper)
    wrap(AutoDrive, "draw", timed("draw"))
    wrap(AutoDrive, "onUpdate", timedVehicle)
    wrap(AutoDrive, "onUpdateTick", timedVehicle)
    wrap(AutoDrive, "onDrawUIInfo", timed("draw"))
    if ADScheduler ~= nil then
        wrap(ADScheduler, "update", timedSub("pathfinder"))
    end
    if ADGraphManager ~= nil then
        wrap(ADGraphManager, "pathFromTo", timedSub("route"))
        wrap(ADGraphManager, "getPathTo", timedSub("route"))
    end
end

-- enlevées seulement si personne n'a enveloppé par-dessus (sinon elles restent, sans rien mesurer)
function ADFarmPilotPerf.removeWrappers()
    for i = #ADFarmPilotPerf.wrapped, 1, -1 do
        local e = ADFarmPilotPerf.wrapped[i]
        if e.target[e.name] == e.wrapper then
            e.target[e.name] = e.base
            table.remove(ADFarmPilotPerf.wrapped, i)
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Mesure
-- ------------------------------------------------------------------------------------------------------------
function ADFarmPilotPerf.start(seconds)
    ADFarmPilotPerf.installWrappers()
    ADFarmPilotPerf.active = true
    ADFarmPilotPerf.window = newWindow()
    ADFarmPilotPerf.total = newWindow()
    ADFarmPilotPerf.remaining = seconds * 1000
    ADFarmPilotPerf.untilReport = ADFarmPilotPerf.REPORT_INTERVAL
    ADFarmPilotPerf.seconds = seconds
    local count = 0
    if ADGraphManager ~= nil and ADGraphManager.getWayPoints ~= nil and ADGraphManager:getWayPoints() ~= nil then
        count = #ADGraphManager:getWayPoints()
    end
    log("mesure lancée pour %d s (réseau : %d points), une ligne toutes les %d s", seconds, count, ADFarmPilotPerf.REPORT_INTERVAL / 1000)
end

function ADFarmPilotPerf.stop(why)
    if not ADFarmPilotPerf.active then
        return
    end
    local t = ADFarmPilotPerf.total
    if t ~= nil and t.frames > 0 then
        ADFarmPilotPerf.report(t, "fin de la mesure (" .. tostring(why) .. "), moyenne")
    else
        log("fin de la mesure (%s), aucune image mesurée", tostring(why))
    end
    ADFarmPilotPerf.active = false
    ADFarmPilotPerf.window = nil
    ADFarmPilotPerf.total = nil
    ADFarmPilotPerf.removeWrappers()
end

local function merge(into, w)
    for _, k in ipairs({ "frames", "frameMs", "vehicles", "global", "pathfinder", "draw", "closestN", "closestMs", "routeN", "routeMs" }) do
        into[k] = into[k] + w[k]
    end
    if w.peak > into.peak then
        into.peak = w.peak
    end
    for v, ms in pairs(w.byVehicle) do
        into.byVehicle[v] = (into.byVehicle[v] or 0) + ms
    end
    for v in pairs(w.active) do
        into.active[v] = true
    end
end

-- fin d'une image (appelé au début de l'image suivante)
function ADFarmPilotPerf.endFrame(dt)
    local w = ADFarmPilotPerf.window
    if w == nil then
        return
    end
    if w.started then
        w.frames = w.frames + 1
        w.frameMs = w.frameMs + (dt or 0)
        if w.frameFp > w.peak then
            w.peak = w.frameFp
        end
    end
    w.started = true
    w.frameFp = 0
    ADFarmPilotPerf.untilReport = ADFarmPilotPerf.untilReport - (dt or 0)
    ADFarmPilotPerf.remaining = ADFarmPilotPerf.remaining - (dt or 0)
    if ADFarmPilotPerf.untilReport <= 0 then
        ADFarmPilotPerf.untilReport = ADFarmPilotPerf.REPORT_INTERVAL
        if w.frames > 0 then
            ADFarmPilotPerf.report(w, string.format("%.0f s", w.frameMs / 1000))
            merge(ADFarmPilotPerf.total, w)
        end
        local fresh = newWindow()
        fresh.started = true
        ADFarmPilotPerf.window = fresh
    end
    if ADFarmPilotPerf.remaining <= 0 then
        ADFarmPilotPerf.stop(string.format("%d s", ADFarmPilotPerf.seconds))
    end
end

function ADFarmPilotPerf.report(w, title)
    local n = math.max(w.frames, 1)
    local fpMs = (w.vehicles + w.global + w.draw) / n
    local frame = w.frameMs / n
    local fps = frame > 0 and 1000 / frame or 0
    local nActive = 0
    for _ in pairs(w.active) do
        nActive = nActive + 1
    end
    log("%s : %.0f images/s (%.1f ms par image) ; FarmPilot %.2f ms par image (%.0f %%) = véhicules %.2f (%d en route) + général %.2f (dont calcul de chemin %.2f) + affichage %.2f ; pic %.1f ms ; point le plus proche : %d %s, %.1f ms ; routes : %d %s, %.1f ms",
        title, fps, frame, fpMs, frame > 0 and fpMs / frame * 100 or 0, w.vehicles / n, nActive, w.global / n, w.pathfinder / n, w.draw / n, w.peak,
        w.closestN, w.closestN == 1 and "recherche" or "recherches", w.closestMs, w.routeN, w.routeN == 1 and "calcul" or "calculs", w.routeMs)
    local list = {}
    for v, ms in pairs(w.byVehicle) do
        list[#list + 1] = { v = v, ms = ms }
    end
    table.sort(list, function(a, b) return a.ms > b.ms end)
    if #list > 0 then
        local parts = {}
        for i = 1, math.min(#list, ADFarmPilotPerf.TOP_VEHICLES) do
            parts[#parts + 1] = string.format("%s %.2f ms", vehicleName(list[i].v), list[i].ms / n)
        end
        log("  plus lourds (ms par image) : %s", table.concat(parts, ", "))
    end
end

-- commande console : fpPerf [secondes|stop]
function ADFarmPilotPerf:consoleCommand(arg)
    if arg ~= nil and string.lower(tostring(arg)) == "stop" then
        if not ADFarmPilotPerf.active then
            return "fpPerf : aucune mesure en cours"
        end
        ADFarmPilotPerf.stop("arrêtée")
        return "fpPerf : mesure arrêtée, résultat dans log.txt"
    end
    local seconds = tonumber(arg) or ADFarmPilotPerf.DEFAULT_SECONDS
    seconds = math.floor(math.max(ADFarmPilotPerf.MIN_SECONDS, math.min(ADFarmPilotPerf.MAX_SECONDS, seconds)))
    if ADFarmPilotPerf.active then
        ADFarmPilotPerf.stop("relancée")
    end
    ADFarmPilotPerf.start(seconds)
    return string.format("fpPerf : mesure de %d s lancée, lignes [FarmPilot Perf] dans log.txt", seconds)
end

-- commande posée au chargement de la carte, enlevée à sa fermeture
local baseLoadMap = AutoDrive.loadMap
function AutoDrive:loadMap(...)
    local a, b, c, d = baseLoadMap(self, ...)
    if addConsoleCommand ~= nil then
        addConsoleCommand("fpPerf", "FarmPilot : mesure le temps pris par FarmPilot (fpPerf [secondes|stop])", "consoleCommand", ADFarmPilotPerf)
    end
    return a, b, c, d
end

local baseDeleteMap = AutoDrive.deleteMap
function AutoDrive:deleteMap(...)
    if ADFarmPilotPerf.active then
        ADFarmPilotPerf.stop("carte fermée")
    end
    if removeConsoleCommand ~= nil then
        removeConsoleCommand("fpPerf")
    end
    return baseDeleteMap(self, ...)
end
