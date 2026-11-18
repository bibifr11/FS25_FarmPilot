-- ============================================================================================================
-- FarmPilot : MassZoneManager.lua
-- Mode Autonome : la zone des masses (17/11).
--
-- Règle :
-- - Une destination faite dans l'éditeur devient une zone des masses par le bouton « Zone des masses » de la
--   fenêtre de modification de la destination (EnterTargetNameGUI.lua). Le même bouton la retire.
-- - La zone est un carré blanc dessiné au sol (HUD ouvert ou éditeur), juste après le point, dans l'axe de la route qui
--   y arrive : PLACES places côte à côte, les masses toutes posées le point d'attelage vers la destination. Le
--   tracteur vient et repart par la route de la destination, et arrive sur chaque place le nez en avant.
-- - Les masses posées dans le carré (même à la main, même mal alignées) sont celles que « Masse auto » peut prendre ;
--   une masse posée par FarmPilot va dans une place libre.
-- - Une destination prise en marche arrière, ou sans route, ne peut pas être une zone des masses (message).
-- - Les zones sont gardées dans la sauvegarde (FarmPilot_Masses.xml), par nom de destination (renommée : suivie).
--
-- Branché par : AutoDrive.lua (draw : dessin ; saveToXml : sauvegarde), EnterTargetNameGUI.lua (bouton),
-- Modes/AutonomousMassAuto.lua (masses de la zone, place libre).
-- ============================================================================================================

ADMassZone = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADMassZone.FILE_NAME = "FarmPilot_Masses.xml"
ADMassZone.PLACES = 5                -- places côte à côte
ADMassZone.PLACE_WIDTH = 1.8         -- m par place (masse jusqu'à 1,2 m de large + marge)
ADMassZone.ROW_DISTANCE = 0          -- m entre la destination et la ligne des points d'attelage : (18/11) au niveau du point (20 m avant : carré trop loin, derrière un talus à Ma$se)
ADMassZone.ROW_DEPTH = 2.5           -- m de profondeur de la rangée (longueur d'une masse + marge)
ADMassZone.FRONT_MARGIN = 1          -- m dessinés devant les points d'attelage
ADMassZone.ENTRY = 3                 -- m devant la place (en plus du tracteur et de la masse) où le chemin arrive
ADMassZone.EXIT_MARGIN = 4           -- m de recul en plus du tracteur et de la masse après la dépose
ADMassZone.INSIDE_MARGIN = 1.5       -- m autour du carré : une masse posée là compte dans la zone
ADMassZone.SLOT_FREE = 0.9           -- m : un objet à moins de ça du milieu d'une place la prend
ADMassZone.COLOR = { 1, 1, 1 }

ADMassZone.zones = {}                -- [nom de la destination] = { places }
ADMassZone.loaded = false

local function log(fmt, ...)
    if ADAutonomousManager ~= nil and ADAutonomousManager.log ~= nil then
        ADAutonomousManager.log("[Masses] " .. fmt, ...)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Zones
-- ------------------------------------------------------------------------------------------------------------
function ADMassZone.isZone(name)
    ADMassZone:loadFromXml()
    return name ~= nil and ADMassZone.zones[name] ~= nil
end

-- { name, marker, wp, hx, hz (axe d'arrivée), px, pz (côté), places = { { x, y, z, dirX, dirZ, index } }, corners }
-- ou nil, raison (« marker », « axis », « reverse »)
function ADMassZone.geometry(name)
    local marker = name ~= nil and ADGraphManager:getMapMarkerByName(name) or nil
    local wp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp == nil or wp.x == nil then
        return nil, "marker"
    end
    local hx, hz, reverse = AutonomousMode.placeAxis(wp)
    if hx == nil then
        return nil, "axis"
    end
    if reverse then
        return nil, "reverse"
    end
    local cfg = ADMassZone.zones[name] or {}
    local n = cfg.places or ADMassZone.PLACES
    local w = ADMassZone.PLACE_WIDTH
    local px, pz = -hz, hx
    local g = { name = name, marker = marker, wp = wp, hx = hx, hz = hz, px = px, pz = pz, places = {} }
    local rx, rz = wp.x + hx * ADMassZone.ROW_DISTANCE, wp.z + hz * ADMassZone.ROW_DISTANCE
    -- places du milieu vers les côtés : la plus proche de l'axe d'abord
    local order = {}
    for i = 1, n do
        order[#order + 1] = { i = i, off = (i - (n + 1) / 2) * w }
    end
    table.sort(order, function(a, b)
        if math.abs(math.abs(a.off) - math.abs(b.off)) > 0.01 then
            return math.abs(a.off) < math.abs(b.off)
        end
        return a.off > b.off
    end)
    for _, o in ipairs(order) do
        g.places[#g.places + 1] = { x = rx + px * o.off, y = wp.y, z = rz + pz * o.off, dirX = -hx, dirZ = -hz, index = o.i, offset = o.off }
    end
    local half = n * w / 2
    local near = ADMassZone.ROW_DISTANCE - ADMassZone.FRONT_MARGIN
    local far = ADMassZone.ROW_DISTANCE + ADMassZone.ROW_DEPTH
    local function pt(along, side)
        return { x = wp.x + hx * along + px * side, z = wp.z + hz * along + pz * side }
    end
    g.corners = { pt(near, -half), pt(near, half), pt(far, half), pt(far, -half) }
    g.near, g.far, g.half = near, far, half
    return g
end

-- zones valides : liste de géométries
function ADMassZone.list()
    ADMassZone:loadFromXml()
    local out = {}
    for name, _ in pairs(ADMassZone.zones) do
        local g = ADMassZone.geometry(name)
        if g ~= nil then
            out[#out + 1] = g
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- le point (x, z) est-il dans le carré (avec la marge) ?
function ADMassZone.contains(g, x, z)
    local dx, dz = x - g.wp.x, z - g.wp.z
    local along = dx * g.hx + dz * g.hz
    local side = dx * g.px + dz * g.pz
    local m = ADMassZone.INSIDE_MARGIN
    return along >= g.near - m and along <= g.far + m and math.abs(side) <= g.half + m
end

-- bouton de la fenêtre de la destination : ajoute ou retire la zone ; renvoie true (ajoutée), false (retirée) ou
-- nil, raison (pas possible)
function ADMassZone.toggle(name)
    ADMassZone:loadFromXml()
    if name == nil then
        return nil, "marker"
    end
    ADMassZone.drawCache = nil
    if ADMassZone.zones[name] ~= nil then
        ADMassZone.zones[name] = nil
        log("zone des masses retirée : « %s »", tostring(name))
        return false
    end
    ADMassZone.zones[name] = { places = ADMassZone.PLACES }
    local g, why = ADMassZone.geometry(name)
    if g == nil then
        ADMassZone.zones[name] = nil
        log("« %s » ne peut pas être une zone des masses (%s)", tostring(name), tostring(why))
        return nil, why
    end
    log("zone des masses : « %s », %d places de %.1f m, à %.0f m du point", tostring(name), #g.places, ADMassZone.PLACE_WIDTH, ADMassZone.ROW_DISTANCE)
    return true
end

-- destination supprimée : la zone aussi
function ADMassZone.remove(name)
    ADMassZone:loadFromXml()
    if name ~= nil and ADMassZone.zones[name] ~= nil then
        ADMassZone.zones[name] = nil
        ADMassZone.drawCache = nil
        log("destination supprimée : zone des masses « %s » retirée", tostring(name))
    end
end

-- destination renommée : la zone suit
function ADMassZone.rename(oldName, newName)
    ADMassZone:loadFromXml()
    if oldName == nil or newName == nil or oldName == newName or ADMassZone.zones[oldName] == nil then
        return
    end
    ADMassZone.zones[newName] = ADMassZone.zones[oldName]
    ADMassZone.zones[oldName] = nil
    ADMassZone.drawCache = nil
    log("zone des masses renommée : « %s » -> « %s »", tostring(oldName), tostring(newName))
end

-- ------------------------------------------------------------------------------------------------------------
-- Masses et places
-- ------------------------------------------------------------------------------------------------------------
local function posOf(o)
    if o == nil or o.components == nil or o.components[1] == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(o.components[1].node)
    return x, z
end

-- zone qui contient cet objet (géométrie) ou nil
function ADMassZone.zoneOf(o, zones)
    local x, z = posOf(o)
    if x == nil then
        return nil
    end
    for _, g in ipairs(zones or ADMassZone.list()) do
        if ADMassZone.contains(g, x, z) then
            return g
        end
    end
    return nil
end

-- place libre de la zone (la plus proche de l'axe d'abord) : rien à moins de SLOT_FREE m du milieu de la place ;
-- exclude : véhicules à ne pas compter (le tracteur et ce qu'il porte) ; taken : places déjà visées { {x, z} }
function ADMassZone.freePlace(g, exclude, taken)
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    local skip = {}
    for _, v in ipairs(exclude or {}) do
        skip[v] = true
    end
    local half = ADMassZone.ROW_DEPTH / 2
    for _, p in ipairs(g.places) do
        -- milieu de la place : derrière le point d'attelage, dans la profondeur de la rangée
        local cx, cz = p.x - p.dirX * half, p.z - p.dirZ * half
        local free = true
        for _, t in ipairs(taken or {}) do
            if MathUtil.vector2Length(t.x - p.x, t.z - p.z) < ADMassZone.PLACE_WIDTH / 2 then
                free = false
            end
        end
        if free and system ~= nil and system.vehicles ~= nil then
            for _, v in pairs(system.vehicles) do
                if not skip[v] and v.components ~= nil and v.components[1] ~= nil and not v.isDeleted then
                    local vx, vz = posOf(v)
                    if vx ~= nil then
                        local dx, dz = vx - cx, vz - cz
                        local along = math.abs(dx * p.dirX + dz * p.dirZ)
                        local side = math.abs(dx * p.dirZ - dz * p.dirX)
                        if along <= half + ADMassZone.SLOT_FREE and side <= ADMassZone.PLACE_WIDTH / 2 then
                            free = false
                            break
                        end
                    end
                end
            end
        end
        if free then
            return p
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Dessin (AutoDrive:draw) : carré blanc au sol, traits entre les places, ligne d'accès depuis la destination
-- ------------------------------------------------------------------------------------------------------------
local function terrainY(x, z)
    return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z) + 0.1
end

local function line(a, b)
    local c = ADMassZone.COLOR
    ADDrawingManager:addLineTask(a.x, terrainY(a.x, a.z), a.z, b.x, terrainY(b.x, b.z), b.z, 1, c[1], c[2], c[3])
end

function ADMassZone.shouldDraw()
    if g_currentMission == nil or g_currentMission.terrainRootNode == nil or ADDrawingManager == nil then
        return false
    end
    if AutoDrive.isEditorModeEnabled ~= nil and AutoDrive.isEditorModeEnabled() then
        return true
    end
    local vehicle = AutoDrive.getControlledVehicle ~= nil and AutoDrive.getControlledVehicle() or nil
    return vehicle ~= nil and vehicle.ad ~= nil and AutoDrive.getSetting("showHUD") == true
end

ADMassZone.DRAW_REFRESH = 2000       -- ms : zones recalculées pour le dessin (pas à chaque image)

function ADMassZone.draw()
    if next(ADMassZone.zones) == nil and ADMassZone.loaded or not ADMassZone.shouldDraw() then
        return
    end
    local now = g_time or 0
    local cache = ADMassZone.drawCache
    if cache == nil or now - cache.time > ADMassZone.DRAW_REFRESH or now < cache.time then
        cache = { time = now, list = ADMassZone.list() }
        ADMassZone.drawCache = cache
    end
    for _, g in ipairs(cache.list) do
        local c = g.corners
        line(c[1], c[2])
        line(c[2], c[3])
        line(c[3], c[4])
        line(c[4], c[1])
        -- séparations des places
        local n = #g.places
        for i = 1, n - 1 do
            local side = -g.half + i * ADMassZone.PLACE_WIDTH
            local a = { x = g.wp.x + g.hx * g.near + g.px * side, z = g.wp.z + g.hz * g.near + g.pz * side }
            local b = { x = g.wp.x + g.hx * g.far + g.px * side, z = g.wp.z + g.hz * g.far + g.pz * side }
            line(a, b)
        end
        -- accès : de la destination au bord du carré
        line({ x = g.wp.x, z = g.wp.z }, { x = g.wp.x + g.hx * g.near, z = g.wp.z + g.hz * g.near })
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Sauvegarde (FarmPilot_Masses.xml dans la sauvegarde)
-- ------------------------------------------------------------------------------------------------------------
local function savegameFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local path = g_currentMission.missionInfo.savegameDirectory
    if path == nil then
        return nil
    end
    return path .. "/" .. ADMassZone.FILE_NAME
end

function ADMassZone:loadFromXml()
    if self.loaded then
        return
    end
    self.loaded = true
    self.zones = {}
    local file = savegameFile()
    if file == nil or not fileExists(file) then
        return
    end
    local xml = loadXMLFile("fpMasses", file)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while true do
        local key = string.format("farmPilotMasses.zone(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local name = getXMLString(xml, key .. "#marker")
        if name ~= nil and name ~= "" then
            self.zones[name] = { places = getXMLInt(xml, key .. "#places") or ADMassZone.PLACES }
        end
        i = i + 1
    end
    delete(xml)
end

function ADMassZone:saveToXml()
    if not self.loaded then
        return
    end
    local file = savegameFile()
    if file == nil then
        return
    end
    local xml = createXMLFile("fpMasses", file, "farmPilotMasses")
    if xml == nil or xml == 0 then
        return
    end
    local names = {}
    for name, _ in pairs(self.zones) do
        names[#names + 1] = name
    end
    table.sort(names)
    for i, name in ipairs(names) do
        local key = string.format("farmPilotMasses.zone(%d)", i - 1)
        setXMLString(xml, key .. "#marker", name)
        setXMLInt(xml, key .. "#places", self.zones[name].places or ADMassZone.PLACES)
    end
    saveXMLFile(xml)
    delete(xml)
end
