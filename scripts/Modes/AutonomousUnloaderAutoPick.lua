-- ============================================================================================================
-- FarmPilot : AutonomousUnloaderAutoPick.lua
-- Moissonneuse ou ensileuse au travail sans aucune benne : FarmPilot choisit lui-même des tracteurs avec leur
-- remorque et les envoie au champ en « Décharger moissonneuse ».
--
-- Règle (16/11) :
-- - Vaut quel que soit le conducteur de la machine : le joueur, Courseplay, l'ouvrier du jeu ou le mode Autonome.
-- - Machine qui récolte vraiment depuis WORK_TIME : moteur en marche, sur un champ, battage / hachage en marche et
--   coupe (ou pick-up) qui ramasse (dernière surface récoltée il y a moins de HARVEST_RECENT, demi-tours compris).
-- - Aucune benne pour elle : aucun tracteur actif en « Décharger moissonneuse » qui la sert ou qui a son champ en
--   1re destination. Le rappel de son équipe (AutonomousHarvesterUnloaders.lua : pending, recallWatch) passe en
--   premier : rien ici tant qu'il est en cours.
-- - Champ (1re destination) : en mode Autonome, sa 1re destination ; sinon le marqueur qui porte le numéro du champ
--   sous la machine (« Champ 56 », comme AutonomousManagerFields.lua), sa 1re destination d'abord, sinon le plus
--   proche ; sinon un marqueur posé dans ce champ. Ce marqueur devient aussi sa 1re destination (les bennes sont
--   appelées par la machine qui a la même 1re destination). Pas de marqueur : message une fois, rien de plus.
-- - Destination de déchargement (2e destination) : celle déjà réglée sur le tracteur si un déchargement près d'elle
--   prend le produit ; sinon le stockage de la ferme (silo, silo couloir) qui le prend, le plus près du champ ;
--   sinon le point de vente qui le paie le mieux. Toujours un marqueur du réseau à moins de PLACE_RADIUS m. Rien :
--   ce tracteur n'est pas pris.
-- - Remorque : de la ferme, dételée (ou attelée au tracteur candidat), benne qui bascule (pas un épandeur, une
--   remorque à balles, un transbordeur ni une remorque porte-barre), qui prend le produit, vide ou du même produit,
--   pas choisie par un autre tracteur (ligne « Remorque »).
-- - Tracteur : de la ferme, à l'arrêt, pas conduit par le joueur, pas actif (FarmPilot, Courseplay, ouvrier), rien
--   d'autre d'attelé que la remorque ou une masse, pas une moissonneuse, pas de l'équipe d'une autre machine, pas
--   le tracteur d'une remorque porte-barre, attelage arrière libre du type de la remorque.
-- - Puissance : POWER_PER_TONNE ch par tonne de la remorque pleine (masse à vide + capacité × masse au litre du
--   produit), jamais moins (un 100 ch ne part pas avec une remorque de 50 t). Pour chaque remorque, le plus petit
--   tracteur qui suffit (les gros restent pour les grosses remorques). D'abord les tracteurs déjà attelés à une
--   remorque qui convient, puis les couples les plus près du champ.
-- - COMBINE_COUNT bennes pour une moissonneuse, CHOPPER_COUNT pour une ensileuse ; moins s'il n'y a pas assez de
--   couples qui conviennent. Départ comme le rappel d'équipe : remorque choisie (allée chercher au départ,
--   TrailerHitch.lua), parking du tracteur gardé. Une fois partis, ils entrent dans son équipe (scanTeams).
-- - Rien trouvé : message une fois par champ, nouvel essai au plus toutes les RETRY_TIME.
-- - Tracteur parti d'ici qui s'est arrêté sans avoir attelé sa remorque : pas repris avant LAUNCH_GUARD.
-- - Serveur seulement, relevé toutes les SCAN_TIME. Traces [AD-Chantier] : chaque couple, chaque refus.
--
-- Branché par : enveloppe posée au chargement sur ADHarvestManager:update (relevé). Chargé par register.lua juste
-- après AutonomousHarvesterUnloaders.lua.
-- ============================================================================================================

ADUnloaderAutoPick = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADUnloaderAutoPick.POWER_PER_TONNE = 5          -- ch par tonne de la remorque pleine, au moins
ADUnloaderAutoPick.COMBINE_COUNT = 1            -- bennes choisies pour une moissonneuse
ADUnloaderAutoPick.CHOPPER_COUNT = 3            -- bennes choisies pour une ensileuse
ADUnloaderAutoPick.SCAN_TIME = 5000             -- ms entre deux relevés
ADUnloaderAutoPick.WORK_TIME = 20000            -- ms de récolte avant le choix
ADUnloaderAutoPick.HARVEST_RECENT = 30000       -- ms : dernière surface récoltée il y a moins de ça = récolte en cours
ADUnloaderAutoPick.RETRY_TIME = 60000           -- ms entre deux choix pour la même machine
ADUnloaderAutoPick.LAUNCH_GUARD = 300000        -- ms : tracteur arrêté sans sa remorque, pas repris avant ça
ADUnloaderAutoPick.PLACE_RADIUS = 50            -- m entre un déchargement et son marqueur
ADUnloaderAutoPick.FIELD_MARKER_RANGE = 300     -- m : champ sans numéro, sa 1re destination si elle est à moins de ça
ADUnloaderAutoPick.KW_TO_HP = 1.36              -- ch par kW
ADUnloaderAutoPick.MIN_LITERS = 1               -- l : moins = vide
ADUnloaderAutoPick.DEFAULT_MASS_PER_LITER = 0.001 -- t/l si le produit n'a pas de masse connue

-- [machine] = { since = début de la récolte vue, nextTry, field = champ du dernier message, told = { [clé] = true } }
ADUnloaderAutoPick.watch = {}
-- [tracteur] = true : parti d'ici (LAUNCH_GUARD)
ADUnloaderAutoPick.launched = {}
ADUnloaderAutoPick.nextScan = 0

-- ------------------------------------------------------------------------------------------------------------
-- Petits outils
-- ------------------------------------------------------------------------------------------------------------
local function trace(fmt, ...)
    local ok, text = FarmPilotCall(string.format, fmt, ...)
    print("[AD-Chantier] " .. (ok and text or tostring(fmt)))
end

local function safe(f, ...)
    if f == nil then
        return nil
    end
    local ok, a, b, c = FarmPilotCall(f, ...)
    if ok then
        return a, b, c
    end
    return nil
end

local function nameOf(v)
    if v == nil then
        return "?"
    end
    if v.ad ~= nil and v.ad.stateModule ~= nil and v.ad.stateModule.getName ~= nil then
        return tostring(v.ad.stateModule:getName())
    end
    if v.getName ~= nil then
        return tostring(safe(v.getName, v) or "?")
    end
    return "?"
end

local function trailerName(o)
    if ADTrailerHitch ~= nil and ADTrailerHitch.label ~= nil then
        return tostring(safe(ADTrailerHitch.label, o) or nameOf(o))
    end
    return nameOf(o)
end

local function vehicles()
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    return system ~= nil and system.vehicles or {}
end

local function isGone(v)
    return v == nil or v.isDeleted or v.isDeleting
end

local function farmOf(v)
    if v ~= nil and v.getOwnerFarmId ~= nil then
        return safe(v.getOwnerFarmId, v)
    end
    return nil
end

local function posOf(v)
    local node = v.rootNode or (v.components ~= nil and v.components[1] ~= nil and v.components[1].node) or nil
    if node == nil then
        return nil
    end
    local x, y, z = getWorldTranslation(node)
    return x, z, y
end

local function markerPos(marker)
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp == nil then
        return nil
    end
    return wp.x, wp.z
end

local function dist(ax, az, bx, bz)
    if ax == nil or bx == nil then
        return math.huge
    end
    return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

local function unloadModeOf(v)
    return v.ad ~= nil and v.ad.modes ~= nil and v.ad.modes[AutoDrive.MODE_UNLOAD] or nil
end

local function isChopper(h)
    return (h.ad ~= nil and h.ad.isChopper == true) or (h.spec_combine ~= nil and h.spec_combine.isBufferCombine == true)
end

-- le véhicule conduit (le tracteur d'une machine traînée)
local function driverOf(h)
    if h.isTrailedHarvester and h.trailingVehicle ~= nil then
        return h.trailingVehicle
    end
    return h
end

local function rootOf(v)
    if v ~= nil and v.getRootVehicle ~= nil then
        return safe(v.getRootVehicle, v) or v
    end
    return v
end

local function fillTypeDesc(ft)
    if g_fillTypeManager == nil or g_fillTypeManager.getFillTypeByIndex == nil then
        return nil
    end
    return safe(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
end

local function fillTypeLabel(ft)
    local d = fillTypeDesc(ft)
    return tostring(d ~= nil and (d.title or d.name) or ft)
end

local function isUnknownFillType(ft)
    return ft == nil or ft == 0 or (FillType ~= nil and ft == FillType.UNKNOWN)
end

-- ------------------------------------------------------------------------------------------------------------
-- La machine : récolte en cours, produit
-- ------------------------------------------------------------------------------------------------------------
-- true si elle récolte maintenant (sinon false et la raison, pour les traces)
function ADUnloaderAutoPick.isHarvesting(h)
    local spec = h.spec_combine
    if spec == nil then
        return false, "pas une machine de récolte"
    end
    local drv = driverOf(h)
    if drv.getIsMotorStarted ~= nil and not safe(drv.getIsMotorStarted, drv) then
        return false, "moteur coupé"
    end
    if h.getIsTurnedOn ~= nil and not safe(h.getIsTurnedOn, h) then
        return false, "battage coupé"
    end
    -- dernière surface récoltée par la coupe ou le pick-up (Combine:addCutterArea, côté serveur)
    local now = g_currentMission ~= nil and g_currentMission.time or g_time
    local last = spec.lastCuttersAreaTime
    if type(last) ~= "number" or now - last > ADUnloaderAutoPick.HARVEST_RECENT then
        return false, "ne ramasse rien"
    end
    local x, z, y = posOf(h)
    if x == nil then
        return false, "position inconnue"
    end
    local onField = nil
    if AutoDrive.checkIsOnField ~= nil then
        onField = safe(AutoDrive.checkIsOnField, x, y or 0, z)
    end
    if onField == nil and ADAutonomousManager ~= nil and ADAutonomousManager.fieldAt ~= nil then
        onField = ADAutonomousManager.fieldAt(x, z) ~= nil
    end
    if not onField then
        return false, "pas sur un champ"
    end
    return true
end

-- produit récolté : celui de la trémie (ou du tampon de l'ensileuse), sinon le dernier ramassé
function ADUnloaderAutoPick.harvestFillType(h)
    local spec = h.spec_combine
    local ft = nil
    if spec ~= nil and spec.fillUnitIndex ~= nil and h.getFillUnitFillType ~= nil then
        ft = safe(h.getFillUnitFillType, h, spec.fillUnitIndex)
    end
    if isUnknownFillType(ft) and spec ~= nil then
        ft = spec.lastCuttersOutputFillType
    end
    if isUnknownFillType(ft) then
        return nil
    end
    return ft
end

-- ------------------------------------------------------------------------------------------------------------
-- Le champ (1re destination des bennes)
-- ------------------------------------------------------------------------------------------------------------
local function markerHasNumber(marker, num)
    if marker == nil or type(marker.name) ~= "string" or num == nil then
        return false
    end
    for n in marker.name:gmatch("%d+") do
        if tonumber(n) == num then
            return true
        end
    end
    return false
end

-- marqueur du champ où elle récolte, et comment il a été trouvé ; nil, raison et nom du champ sinon
function ADUnloaderAutoPick.fieldMarker(h)
    local sm = h.ad.stateModule
    local current = sm:getFirstMarker()
    if sm:getMode() == AutoDrive.MODE_AUTONOMOUS then
        if current ~= nil then
            return current, "1re destination du mode Autonome"
        end
        return nil, "mode Autonome sans 1re destination", "?"
    end
    local hx, hz = posOf(h)
    local field = (ADAutonomousManager ~= nil and ADAutonomousManager.fieldAt ~= nil) and ADAutonomousManager.fieldAt(hx, hz) or nil
    local num = field ~= nil and tonumber(ADAutonomousManager.fieldNumber(field)) or nil
    if num == nil then
        -- champ sans numéro : sa 1re destination si elle est tout près
        local mx, mz = markerPos(current)
        if current ~= nil and dist(hx, hz, mx, mz) <= ADUnloaderAutoPick.FIELD_MARKER_RANGE then
            return current, string.format("sa 1re destination, à %d m", math.floor(dist(hx, hz, mx, mz)))
        end
        return nil, "champ sans numéro sous la machine, 1re destination loin", "?"
    end
    if markerHasNumber(current, num) then
        return current, string.format("sa 1re destination, champ %d", num)
    end
    local best, bestD = nil, math.huge
    for _, m in pairs(ADGraphManager:getMapMarkers() or {}) do
        if markerHasNumber(m, num) then
            local mx, mz = markerPos(m)
            local d = dist(hx, hz, mx, mz)
            if d < bestD then
                best, bestD = m, d
            end
        end
    end
    if best ~= nil then
        return best, string.format("marqueur du champ %d", num)
    end
    -- un marqueur posé dans ce champ
    for _, m in pairs(ADGraphManager:getMapMarkers() or {}) do
        local mx, mz = markerPos(m)
        if mx ~= nil then
            local f = ADAutonomousManager.fieldAt(mx, mz)
            if f ~= nil and ADAutonomousManager.sameField(f, field) then
                local d = dist(hx, hz, mx, mz)
                if d < bestD then
                    best, bestD = m, d
                end
            end
        end
    end
    if best ~= nil then
        return best, string.format("marqueur dans le champ %d", num)
    end
    return nil, string.format("aucun marqueur pour le champ %d", num), tostring(num)
end

-- une benne la sert déjà : tracteur actif en « Décharger moissonneuse » pour elle, vers son champ (marker) ou vers
-- sa 1re destination
function ADUnloaderAutoPick.hasUnloader(h, marker)
    local own = h.ad.stateModule:getFirstMarker()
    local drv = driverOf(h)
    for _, v in pairs(vehicles()) do
        local sm = v.ad ~= nil and v.ad.stateModule or nil
        if v ~= h and v ~= drv and sm ~= nil and sm:getMode() == AutoDrive.MODE_UNLOAD and sm:isActive() then
            local mode = unloadModeOf(v)
            local first = sm:getFirstMarker()
            if (mode ~= nil and mode.combine == h) or (first ~= nil and (first == marker or first == own)) then
                return true, v
            end
        end
    end
    return false
end

-- le rappel de son équipe est en cours (AutonomousHarvesterUnloaders.lua)
local function recallRunning(h)
    if ADHarvesterUnloaders == nil then
        return false
    end
    local drv = driverOf(h)
    for _, key in ipairs({ h, drv }) do
        if (ADHarvesterUnloaders.pending ~= nil and ADHarvesterUnloaders.pending[key] ~= nil)
            or (ADHarvesterUnloaders.recallWatch ~= nil and ADHarvesterUnloaders.recallWatch[key] ~= nil) then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Déchargements qui prennent le produit (2e destination)
-- ------------------------------------------------------------------------------------------------------------
local function toolTypeDischarge()
    if ToolType ~= nil then
        return ToolType.DISCHARGEABLE or ToolType.UNDEFINED
    end
    return nil
end

local function placeableOf(station)
    return station ~= nil and (station.owningPlaceable or station.placeable) or nil
end

-- silo de la ferme (pas une production, une étable ni un point de vente)
local function isFarmSilo(station, farmId)
    local p = placeableOf(station)
    if p == nil or (p.spec_silo == nil and p.spec_siloExtension == nil) then
        return false
    end
    local owner = farmOf(p)
    return owner == nil or owner == farmId
end

local function triggerTakes(trigger, station, ft, farmId)
    if trigger == nil then
        return false
    end
    if trigger.getIsFillTypeAllowed ~= nil then
        if not safe(trigger.getIsFillTypeAllowed, trigger, ft) then
            return false
        end
    elseif trigger.fillTypes ~= nil and not trigger.fillTypes[ft] then
        return false
    end
    local tt = toolTypeDischarge()
    if tt ~= nil and trigger.getIsToolTypeAllowed ~= nil and not safe(trigger.getIsToolTypeAllowed, trigger, tt) then
        return false
    end
    if station.getIsFillAllowedFromFarm ~= nil and not safe(station.getIsFillAllowedFromFarm, station, farmId) then
        return false
    end
    return true
end

local function triggerPos(trigger)
    if ADTriggerManager ~= nil and ADTriggerManager.getTriggerPos ~= nil then
        local x, _, z = safe(ADTriggerManager.getTriggerPos, trigger)
        if x ~= nil and (x ~= 0 or z ~= 0) then
            return x, z
        end
    end
    return nil
end

-- { kind = "stock" | "sell" | "other", name, price, points = { {x, z} } } : tous les déchargements qui prennent ft
function ADUnloaderAutoPick.placesFor(ft, farmId)
    local places = {}
    local storage = g_currentMission ~= nil and g_currentMission.storageSystem or nil
    local stations = storage ~= nil and storage.getUnloadingStations ~= nil and safe(storage.getUnloadingStations, storage) or nil
    for _, station in pairs(stations or {}) do
        local isSell = SellingStation ~= nil and station.isa ~= nil and safe(station.isa, station, SellingStation) == true
        local usable = true
        local kind = "other"
        if isSell then
            kind = "sell"
            usable = station.isSellingPoint ~= false and not station.hideFromPricesMenu
        elseif isFarmSilo(station, farmId) then
            kind = "stock"
        end
        if usable and kind ~= "sell" and station.getFreeCapacity ~= nil then
            local free = safe(station.getFreeCapacity, station, ft, farmId)
            usable = free == nil or free > ADUnloaderAutoPick.MIN_LITERS
        end
        if usable then
            local points = {}
            for _, trigger in pairs(station.unloadTriggers or {}) do
                if triggerTakes(trigger, station, ft, farmId) then
                    local x, z = triggerPos(trigger)
                    if x ~= nil then
                        points[#points + 1] = { x = x, z = z }
                    end
                end
            end
            if #points > 0 then
                local price = 0
                if isSell and station.getEffectiveFillTypePrice ~= nil then
                    price = safe(station.getEffectiveFillTypePrice, station, ft) or 0
                end
                local name = station.getName ~= nil and safe(station.getName, station) or nil
                places[#places + 1] = { kind = kind, name = tostring(name or kind), price = price, points = points }
            end
        end
    end
    -- silos couloirs (ensilage) : ceux du jeu (la liste réunie d'AutoDrive n'a pas leurs produits)
    if ADTriggerManager ~= nil and ADTriggerManager.getBunkerSilos ~= nil then
        local joined = safe(ADTriggerManager.getBunkerSilos) -- charge les listes si besoin
        for _, b in pairs(ADTriggerManager.bunkerSilos or joined or {}) do
            local area = b.bunkerSiloArea
            local owner = farmOf(b)
            local open = BunkerSilo == nil or BunkerSilo.STATE_FILL == nil or b.state == nil or b.state == BunkerSilo.STATE_FILL
            if area ~= nil and area.sx ~= nil and b.acceptedFillTypes ~= nil and b.acceptedFillTypes[ft] and open
                and (owner == nil or owner == 0 or owner == farmId) then
                local ex, ez = area.wx + area.hx - area.sx, area.wz + area.hz - area.sz
                local points = {
                    { x = area.sx, z = area.sz }, { x = area.wx, z = area.wz }, { x = area.hx, z = area.hz }, { x = ex, z = ez },
                    { x = (area.sx + ex) / 2, z = (area.sz + ez) / 2 }
                }
                places[#places + 1] = { kind = "stock", name = "silo couloir", price = 0, points = points }
            end
        end
    end
    return places
end

-- marqueurs du réseau avec leur position
local function markerList()
    local list = {}
    for _, m in pairs(ADGraphManager:getMapMarkers() or {}) do
        local x, z = markerPos(m)
        if x ~= nil then
            list[#list + 1] = { marker = m, x = x, z = z }
        end
    end
    return list
end

-- marqueur du réseau le plus proche d'un déchargement (à moins de PLACE_RADIUS m), ou nil
local function markerAtPlace(place, markers)
    local best, bestD = nil, ADUnloaderAutoPick.PLACE_RADIUS
    for _, p in ipairs(place.points) do
        for _, e in ipairs(markers) do
            local d = dist(p.x, p.z, e.x, e.z)
            if d <= bestD then
                best, bestD = e.marker, d
            end
        end
    end
    return best
end

-- un déchargement près de ce marqueur prend le produit : la place, sinon nil
function ADUnloaderAutoPick.placeAtMarker(marker, places)
    local mx, mz = markerPos(marker)
    if mx == nil then
        return nil
    end
    for _, place in ipairs(places) do
        for _, p in ipairs(place.points) do
            if dist(p.x, p.z, mx, mz) <= ADUnloaderAutoPick.PLACE_RADIUS then
                return place
            end
        end
    end
    return nil
end

-- destination de la ferme : { places, stock = { marker, place } ou nil, sale = { marker, place } ou nil }
function ADUnloaderAutoPick.destinations(ft, farmId, fx, fz)
    local places = ADUnloaderAutoPick.placesFor(ft, farmId)
    local out = { places = places }
    if #places == 0 then
        return out
    end
    local markers = markerList()
    local stockD = math.huge
    for _, place in ipairs(places) do
        local marker = markerAtPlace(place, markers)
        if marker ~= nil then
            local mx, mz = markerPos(marker)
            local d = dist(fx, fz, mx, mz)
            if place.kind == "stock" then
                if d < stockD then
                    out.stock, stockD = { marker = marker, place = place }, d
                end
            elseif place.kind == "sell" then
                local best = out.sale
                if best == nil or place.price > best.place.price + 0.0001
                    or (math.abs(place.price - best.place.price) <= 0.0001 and d < best.d) then
                    out.sale = { marker = marker, place = place, d = d }
                end
            end
        end
    end
    return out
end

-- 2e destination de ce tracteur : la sienne si elle prend le produit, sinon la ferme ; nil si rien
local function destinationFor(v, dests)
    local own = v.ad.stateModule:getSecondMarker()
    if own ~= nil then
        local place = ADUnloaderAutoPick.placeAtMarker(own, dests.places)
        if place ~= nil then
            return own, "la sienne (" .. place.kind .. ")"
        end
    end
    if dests.stock ~= nil then
        return dests.stock.marker, "stockage de la ferme"
    end
    if dests.sale ~= nil then
        return dests.sale.marker, string.format("meilleur prix (%s)", dests.sale.place.name)
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Remorques et tracteurs
-- ------------------------------------------------------------------------------------------------------------
local function massPerLiter(ft)
    local d = fillTypeDesc(ft)
    local m = d ~= nil and d.massPerLiter or nil
    if type(m) ~= "number" or m <= 0 then
        return ADUnloaderAutoPick.DEFAULT_MASS_PER_LITER
    end
    return m
end

-- { trailer, capacity (l), empty (t), full (t), needHp } ; nil et la raison si elle ne convient pas
function ADUnloaderAutoPick.trailerInfo(o, ft)
    if ADHeaderFlow ~= nil and ADHeaderFlow.isHeaderTrailer ~= nil and ADHeaderFlow.isHeaderTrailer(o) then
        return nil, "remorque porte-barre"
    end
    if o.spec_dischargeable == nil or o.spec_trailer == nil then
        return nil, "ne bascule pas"
    end
    if o.spec_pipe ~= nil or o.spec_baleLoader ~= nil or o.spec_sprayer ~= nil or o.spec_manureSpreader ~= nil then
        return nil, "pas une benne"
    end
    local units = o.getFillUnits ~= nil and safe(o.getFillUnits, o) or nil
    if type(units) ~= "table" then
        return nil, "pas de remplissage"
    end
    local capacity, current = 0, 0
    for i = 1, #units do
        if safe(o.getFillUnitSupportsFillType, o, i, ft) then
            capacity = capacity + (safe(o.getFillUnitCapacity, o, i) or 0)
            local level = safe(o.getFillUnitFillLevel, o, i) or 0
            if level > ADUnloaderAutoPick.MIN_LITERS then
                if safe(o.getFillUnitFillType, o, i) ~= ft then
                    return nil, "chargée d'un autre produit"
                end
                current = current + level
            end
        end
    end
    if capacity <= 0 then
        return nil, "ne prend pas " .. fillTypeLabel(ft)
    end
    if current >= capacity - ADUnloaderAutoPick.MIN_LITERS then
        return nil, "pleine"
    end
    local mpl = massPerLiter(ft)
    local empty = o.getDefaultMass ~= nil and safe(o.getDefaultMass, o) or nil
    if type(empty) ~= "number" or empty <= 0 then
        local total = o.getTotalMass ~= nil and safe(o.getTotalMass, o, true) or nil
        empty = type(total) == "number" and math.max(0, total - current * mpl) or 0
    end
    local full = empty + capacity * mpl
    return { trailer = o, capacity = capacity, empty = empty, full = full, needHp = full * ADUnloaderAutoPick.POWER_PER_TONNE }
end

-- puissance du moteur en ch, ou nil
function ADUnloaderAutoPick.tractorHp(v)
    local motor = v.getMotor ~= nil and safe(v.getMotor, v) or nil
    local kw = motor ~= nil and motor.peakMotorPower or nil
    if type(kw) == "number" and kw > 0 then
        return kw * ADUnloaderAutoPick.KW_TO_HP
    end
    -- sans moteur lisible : la fiche du magasin (en ch)
    if g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil and v.configFileName ~= nil then
        local item = safe(g_storeManager.getItemByXMLFilename, g_storeManager, v.configFileName)
        local hp = item ~= nil and item.specs ~= nil and tonumber(item.specs.power) or nil
        if hp ~= nil and hp > 0 then
            return hp
        end
    end
    return nil
end

-- ce qui est attelé directement au tracteur, masses à part : liste
local function hitchedOf(v)
    local list = {}
    if v.getAttachedImplements == nil then
        return list
    end
    local implements = safe(v.getAttachedImplements, v)
    for _, impl in ipairs(type(implements) == "table" and implements or {}) do
        local o = impl.object
        if o ~= nil and not (ADAutonomousManager ~= nil and ADAutonomousManager.isMass ~= nil and ADAutonomousManager.isMass(o)) then
            list[#list + 1] = o
        end
    end
    return list
end

-- tracteurs réservés : équipe d'une autre machine, tracteur d'une remorque porte-barre ; remorques choisies
local function reservations(h)
    local teamOf, headerTractor, chosenBy = {}, {}, {}
    for _, v in pairs(vehicles()) do
        local sm = v.ad ~= nil and v.ad.stateModule or nil
        if sm ~= nil and not isGone(v) then
            if v ~= h and v ~= driverOf(h) and ADHarvesterUnloaders ~= nil and ADHarvesterUnloaders.getTeam ~= nil then
                local team = ADHarvesterUnloaders.getTeam(v)
                for uid in pairs(team or {}) do
                    teamOf[uid] = v
                end
            end
            if sm.getFpHeaderTractor ~= nil then
                local t = safe(sm.getFpHeaderTractor, sm)
                if t ~= nil then
                    headerTractor[t] = true
                end
            end
            if sm.getFpTrailer ~= nil then
                local t = safe(sm.getFpTrailer, sm)
                if t ~= nil then
                    chosenBy[t] = v
                end
            end
        end
    end
    return teamOf, headerTractor, chosenBy
end

-- tracteur parti d'ici, arrêté sans avoir attelé sa remorque (aller la chercher a raté)
local function failedLaunch(v)
    local since = ADUnloaderAutoPick.launched[v]
    if since == nil then
        return false
    end
    if g_time - since > ADUnloaderAutoPick.LAUNCH_GUARD then
        ADUnloaderAutoPick.launched[v] = nil
        return false
    end
    local sm = v.ad.stateModule
    if sm:isActive() then
        return false
    end
    local t = sm.getFpTrailer ~= nil and sm:getFpTrailer() or nil
    return t ~= nil and t.getAttacherVehicle ~= nil and t:getAttacherVehicle() ~= v
end

-- pourquoi ce tracteur n'est pas pris (nil s'il peut l'être)
local function tractorRefusal(v, h, farmId, teamOf, headerTractor)
    local sm = v.ad.stateModule
    if unloadModeOf(v) == nil then
        return "pas de mode « Décharger moissonneuse »"
    end
    if ADHeaderFlow ~= nil and ADHeaderFlow.isTractor ~= nil and not ADHeaderFlow.isTractor(v) then
        return "pas un tracteur"
    end
    if AutoDrive.getIsEntered ~= nil and AutoDrive:getIsEntered(rootOf(v)) then
        return "conduit par le joueur"
    end
    if sm:isActive() or (AutoDrive.getIsCPActive ~= nil and AutoDrive:getIsCPActive(v))
        or (v.getIsAIActive ~= nil and v:getIsAIActive()) then
        return "actif (FarmPilot, Courseplay ou ouvrier)"
    end
    if v.ad.fpHeaderJob ~= nil or headerTractor[v] then
        return "tracteur de la remorque porte-barre"
    end
    local uid = v.getUniqueId ~= nil and safe(v.getUniqueId, v) or nil
    local owner = uid ~= nil and teamOf[tostring(uid)] or nil
    if owner ~= nil then
        return string.format("équipe de « %s »", nameOf(owner))
    end
    if failedLaunch(v) then
        return string.format("remorque pas attelée au dernier départ, pas repris avant %d min", ADUnloaderAutoPick.LAUNCH_GUARD / 60000)
    end
    if v.getLastSpeed ~= nil and (safe(v.getLastSpeed, v) or 0) > 1 then
        return "roule"
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Choix des couples
-- ------------------------------------------------------------------------------------------------------------
-- couples { tractor, trailer, info, hp, dest, destHow, attached } (wanted au plus) ; refus (journal) ; noDest
function ADUnloaderAutoPick.choose(h, fieldMarker, ft, wanted)
    local farmId = farmOf(h) or farmOf(driverOf(h))
    local fx, fz = markerPos(fieldMarker)
    local dests = ADUnloaderAutoPick.destinations(ft, farmId, fx, fz)
    local teamOf, headerTractor, chosenBy = reservations(h)
    local refusals = {}
    local function refuse(v, why)
        refusals[#refusals + 1] = string.format("« %s » : %s", nameOf(v), why)
    end

    -- remorques de la ferme qui conviennent (attelées ou non)
    local trailerOk = {}
    local freeTrailers = {}
    for _, o in pairs(vehicles()) do
        if not isGone(o) and ADTrailerHitch ~= nil and ADTrailerHitch.isTrailerObject(o) and farmOf(o) == farmId then
            local info, why = ADUnloaderAutoPick.trailerInfo(o, ft)
            local attacher = o.getAttacherVehicle ~= nil and o:getAttacherVehicle() or nil
            if info == nil then
                refuse(o, why)
            elseif attacher ~= nil and (attacher.ad == nil or attacher.ad.stateModule == nil or rootOf(o) ~= attacher) then
                refuse(o, string.format("attelée à « %s »", nameOf(attacher)))
            elseif chosenBy[o] ~= nil and chosenBy[o] ~= attacher and attacher ~= nil then
                refuse(o, string.format("choisie par « %s »", nameOf(chosenBy[o])))
            else
                trailerOk[o] = info
                info.onlyFor = attacher == nil and chosenBy[o] or nil -- choisie par un tracteur : seulement pour lui
                if attacher == nil then
                    freeTrailers[#freeTrailers + 1] = info
                end
            end
        end
    end

    -- tracteurs de la ferme à l'arrêt
    local attachedPairs, freeTractors = {}, {}
    local noDest = 0
    for _, v in pairs(vehicles()) do
        if not isGone(v) and v ~= h and v ~= driverOf(h) and v.ad ~= nil and v.ad.stateModule ~= nil and v.spec_motorized ~= nil
            and v.spec_combine == nil and not (ADHeaderFlow ~= nil and ADHeaderFlow.isCombine(v)) and farmOf(v) == farmId
            and rootOf(v) == v then
            local why = tractorRefusal(v, h, farmId, teamOf, headerTractor)
            local hp = nil
            local hitched = why == nil and hitchedOf(v) or {}
            local own = nil
            if why == nil then
                if #hitched > 1 then
                    why = "plusieurs outils attelés"
                elseif #hitched == 1 then
                    own = hitched[1]
                    if trailerOk[own] == nil then
                        why = string.format("« %s » attelé ne convient pas", trailerName(own))
                    end
                end
            end
            if why == nil then
                hp = ADUnloaderAutoPick.tractorHp(v)
                if hp == nil then
                    why = "puissance inconnue"
                end
            end
            if why == nil and own ~= nil and hp < trailerOk[own].needHp then
                why = string.format("%d ch, trop faible pour sa remorque attelée « %s » (%.1f t pleine, %d ch au moins)", math.floor(hp + 0.5),
                    trailerName(own), trailerOk[own].full, math.ceil(trailerOk[own].needHp))
            end
            local dest, destHow = nil, nil
            if why == nil then
                dest, destHow = destinationFor(v, dests)
                if dest == nil then
                    why = "pas de destination de déchargement pour " .. fillTypeLabel(ft)
                    noDest = noDest + 1
                end
            end
            if why ~= nil then
                refuse(v, why)
            else
                local vx, vz = posOf(v)
                local entry = { tractor = v, hp = hp, dest = dest, destHow = destHow, x = vx, z = vz }
                if own ~= nil then
                    entry.trailer, entry.info, entry.attached = own, trailerOk[own], true
                    entry.d = dist(vx, vz, fx, fz)
                    attachedPairs[#attachedPairs + 1] = entry
                else
                    freeTractors[#freeTractors + 1] = entry
                end
            end
        end
    end

    -- 1. tracteurs déjà attelés à une remorque qui convient, les plus près du champ
    table.sort(attachedPairs, function(a, b) return a.d < b.d end)
    local chosen = {}
    for _, p in ipairs(attachedPairs) do
        if #chosen < wanted then
            chosen[#chosen + 1] = p
        end
    end
    -- 2. remorques dételées, les plus près du champ : chacune prend le plus petit tracteur qui suffit
    for _, info in ipairs(freeTrailers) do
        local tx, tz = posOf(info.trailer)
        info.x, info.z, info.d = tx, tz, dist(tx, tz, fx, fz)
    end
    table.sort(freeTrailers, function(a, b) return a.d < b.d end)
    local used = {}
    for _, info in ipairs(freeTrailers) do
        if #chosen >= wanted then
            break
        end
        local best, free, strong = nil, 0, 0
        for _, t in ipairs(freeTractors) do
            local allowed = not used[t] and (info.onlyFor == nil or info.onlyFor == t.tractor)
            free = free + (allowed and 1 or 0)
            if allowed and t.hp >= info.needHp then -- jamais un tracteur trop faible pour cette remorque pleine
                strong = strong + 1
                if ADAutonomousManager.matchJoints(t.tractor, info.trailer, true) ~= nil then
                    if best == nil or t.hp < best.hp - 0.5
                        or (math.abs(t.hp - best.hp) <= 0.5 and dist(t.x, t.z, info.x, info.z) < dist(best.x, best.z, info.x, info.z)) then
                        best = t
                    end
                end
            end
        end
        if best ~= nil then
            used[best] = true
            chosen[#chosen + 1] = { tractor = best.tractor, hp = best.hp, dest = best.dest, destHow = best.destHow, trailer = info.trailer, info = info, attached = false }
        else
            local why = (info.onlyFor ~= nil and free == 0) and string.format("choisie par « %s », pas libre", nameOf(info.onlyFor))
                or free == 0 and "plus de tracteur libre" or (strong == 0 and "aucun tracteur libre assez puissant" or "attelage d'aucun tracteur assez puissant du bon type")
            refuse(info.trailer, string.format("%s (%.1f t pleine, %d ch au moins)", why, info.full, math.ceil(info.needHp)))
        end
    end
    return chosen, refusals, (dests.stock == nil and dests.sale == nil) and noDest > 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ d'un couple (comme le rappel d'équipe, AutonomousHarvesterUnloaders.lua : recallOne)
-- ------------------------------------------------------------------------------------------------------------
-- nil = parti ; sinon la raison
function ADUnloaderAutoPick.launch(h, pair, fieldMarker)
    local v = pair.tractor
    local sm = v.ad.stateModule
    local mode = unloadModeOf(v)
    v.ad.fpModeBeforePark = nil -- le mode d'avant une dépose ne revient plus à l'arrêt
    sm:setMode(AutoDrive.MODE_UNLOAD)
    if sm:getMode() ~= AutoDrive.MODE_UNLOAD then
        return "mode refusé"
    end
    sm:setFirstMarker(fieldMarker.markerIndex)
    if sm:getSecondMarker() ~= pair.dest then
        sm:setSecondMarker(pair.dest.markerIndex)
    end
    if sm.setFpTrailer ~= nil and sm:getFpTrailer() ~= pair.trailer then
        sm:setFpTrailer(pair.trailer)
    end
    -- parking : celui du tracteur, gardé tel quel
    v.ad.harvestJobDone = nil
    mode:start(AutoDrive.USER_PLAYER)
    if not sm:isActive() then
        return "départ refusé"
    end
    ADUnloaderAutoPick.launched[v] = g_time
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Une machine
-- ------------------------------------------------------------------------------------------------------------
-- message au joueur une fois par champ
local function tellOnce(h, w, key, ...)
    if w.told[key] then
        return
    end
    w.told[key] = true
    if AutonomousMode ~= nil and AutonomousMode.message ~= nil then
        FarmPilotCall(AutonomousMode.message, h, ADMessagesManager.messageTypes.INFO, 10000, key, ...)
    end
end

local function setField(w, key)
    if w.field ~= key then
        w.field = key
        w.told = {}
    end
end

function ADUnloaderAutoPick.check(h)
    local w = ADUnloaderAutoPick.watch[h]
    if w == nil then
        w = { since = nil, nextTry = 0, field = nil, told = {} }
        ADUnloaderAutoPick.watch[h] = w
    end
    if not ADUnloaderAutoPick.isHarvesting(h) then
        w.since = nil
        return
    end
    if w.since == nil then
        w.since = g_time
        return
    end
    if g_time - w.since < ADUnloaderAutoPick.WORK_TIME or g_time < w.nextTry then
        return
    end
    if recallRunning(h) then
        return -- le rappel de son équipe passe en premier
    end
    -- servie par une benne (appelée, ou même 1re destination) : rien, sans chercher le champ (relevé léger)
    if ADUnloaderAutoPick.hasUnloader(h, nil) then
        return
    end
    local name = nameOf(h)
    local marker, how, fieldLabel = ADUnloaderAutoPick.fieldMarker(h)
    if marker == nil then
        setField(w, "?" .. tostring(fieldLabel))
        if not w.told["AD_autonomous_unloadersAutoNoField"] then
            trace("%s: pas de benne choisie automatiquement, %s", name, tostring(how))
        end
        tellOnce(h, w, "AD_autonomous_unloadersAutoNoField", tostring(fieldLabel))
        w.nextTry = g_time + ADUnloaderAutoPick.RETRY_TIME
        return
    end
    setField(w, marker)
    if marker ~= h.ad.stateModule:getFirstMarker() and ADUnloaderAutoPick.hasUnloader(h, marker) then
        return
    end
    local ft = ADUnloaderAutoPick.harvestFillType(h)
    if ft == nil then
        return -- rien encore dans la trémie ni dans la coupe
    end
    w.nextTry = g_time + ADUnloaderAutoPick.RETRY_TIME
    local chopper = isChopper(h)
    local wanted = chopper and ADUnloaderAutoPick.CHOPPER_COUNT or ADUnloaderAutoPick.COMBINE_COUNT
    trace("%s: %s sans benne a %s (%s), %s : choix automatique de %d benne(s)", name, chopper and "ensileuse" or "moissonneuse",
        tostring(marker.name), how, fillTypeLabel(ft), wanted)
    local list, refusals, noDest = ADUnloaderAutoPick.choose(h, marker, ft, wanted)
    for _, r in ipairs(refusals) do
        trace("%s:   refus %s", name, r)
    end
    -- sa 1re destination = ce champ, sinon elle n'appelle pas ses bennes (même 1re destination)
    local sm = h.ad.stateModule
    if #list > 0 and sm:getFirstMarker() ~= marker then
        if sm:isActive() then
            trace("%s: FarmPilot la conduit, sa 1re destination ne change pas : pas de benne choisie", name)
            return
        end
        trace("%s: 1re destination %s -> %s (ses bennes l'appellent par la 1re destination)", name, tostring(sm:getFirstMarker() ~= nil and sm:getFirstMarker().name or "-"),
            tostring(marker.name))
        sm:setFirstMarker(marker.markerIndex)
    end
    local count = 0
    for _, pair in ipairs(list) do
        local ok, why = FarmPilotCall(ADUnloaderAutoPick.launch, h, pair, marker)
        local ratio = pair.info.full > 0 and pair.hp / pair.info.full or 0
        if not ok then
            trace("%s:   ERREUR depart de %s : %s", name, nameOf(pair.tractor), tostring(why))
        elseif why ~= nil then
            trace("%s:   %s pas parti (%s)", name, nameOf(pair.tractor), why)
        else
            count = count + 1
            trace("%s:   %s choisi : %d ch, remorque %s%s, %.1f t pleine (%.1f t a vide + %d l), %.1f ch/t (%d ch au moins), vidage %s (%s)",
                name, nameOf(pair.tractor), math.floor(pair.hp + 0.5), trailerName(pair.trailer), pair.attached and " (attelee)" or " (a atteler)",
                pair.info.full, pair.info.empty, math.floor(pair.info.capacity + 0.5), ratio, math.ceil(pair.info.needHp),
                tostring(pair.dest.name), tostring(pair.destHow))
        end
    end
    if count > 0 then
        trace("%s: %d benne(s) choisie(s) automatiquement pour %s", name, count, tostring(marker.name))
        if AutonomousMode ~= nil and AutonomousMode.message ~= nil then
            FarmPilotCall(AutonomousMode.message, h, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_unloadersAuto", count, tostring(marker.name))
        end
        w.told = {}
        return
    end
    if noDest then
        trace("%s: aucune destination de dechargement pour %s, nouvel essai dans %d s", name, fillTypeLabel(ft), ADUnloaderAutoPick.RETRY_TIME / 1000)
        tellOnce(h, w, "AD_autonomous_unloadersAutoNoDest", fillTypeLabel(ft))
    else
        trace("%s: aucune benne qui convient, nouvel essai dans %d s", name, ADUnloaderAutoPick.RETRY_TIME / 1000)
        tellOnce(h, w, "AD_autonomous_unloadersAutoNone", tostring(marker.name))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Relevé (serveur, toutes les SCAN_TIME)
-- ------------------------------------------------------------------------------------------------------------
function ADUnloaderAutoPick.update(dt)
    if g_server == nil or g_time < ADUnloaderAutoPick.nextScan then
        return
    end
    ADUnloaderAutoPick.nextScan = g_time + ADUnloaderAutoPick.SCAN_TIME
    local seen = {}
    for _, list in ipairs({ ADHarvestManager.harvesters or {}, ADHarvestManager.idleHarvesters or {} }) do
        for _, h in pairs(list) do
            if not seen[h] and not isGone(h) and h.ad ~= nil and h.ad.stateModule ~= nil and h.spec_combine ~= nil then
                seen[h] = true
                local ok, err = FarmPilotCall(ADUnloaderAutoPick.check, h)
                if not ok then
                    trace("%s: ERREUR choix automatique des bennes : %s", nameOf(h), tostring(err))
                end
            end
        end
    end
    for h in pairs(ADUnloaderAutoPick.watch) do
        if not seen[h] then
            ADUnloaderAutoPick.watch[h] = nil
        end
    end
    for v in pairs(ADUnloaderAutoPick.launched) do
        if isGone(v) then
            ADUnloaderAutoPick.launched[v] = nil
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppe (posée au chargement)
-- ------------------------------------------------------------------------------------------------------------
if ADHarvestManager ~= nil and ADHarvestManager.update ~= nil then
    local baseUpdate = ADHarvestManager.update
    function ADHarvestManager:update(dt)
        local ok, err = FarmPilotCall(ADUnloaderAutoPick.update, dt)
        if not ok then
            ADUnloaderAutoPick.watch = {}
            print("[AD-Chantier] ERREUR choix automatique des bennes : " .. tostring(err))
        end
        return baseUpdate(self, dt)
    end
end
