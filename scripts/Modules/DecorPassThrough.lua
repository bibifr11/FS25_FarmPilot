-- ============================================================================================================
-- FarmPilot : DecorPassThrough.lua
-- Objets de décor traversés au pas sans contact : ignorés ensuite par les capteurs (18/11).
--
-- Essai du 18/11 19:40 : 728 + broyeur au Champ 52, « Objet de décoration 35 » (muret de pierres au bord) vu à 0 m
-- par le capteur avant et le balayage de route ; ni écart ni contournement possibles, recul, puis avance au pas sur
-- 16,6 m à 2 km/h sans rien toucher. À chaque passage, la même attente et la même avance au pas.
--
-- Règle : pendant l'avance au pas (ObstacleDetourEscape.lua), les objets fixes sans véhicule (décor) vus par le
-- capteur avant ou le balayage de route sont notés. Passé au pas : ils sont retenus (nom + position du nœud) et
-- sauvés dans la partie (FILE_NAME), avec l'endroit traversé. Ensuite, à moins de PLACE_DIST m de cet endroit, le capteur avant (CollSensor.lua) et le balayage de route
-- (ApproachModule.lua) les ignorent : le tracteur roule à sa vitesse. Toujours coincé au pas : rien de retenu.
-- Un véhicule n'est jamais retenu.
-- ============================================================================================================

ADDecorPassThrough = {}
ADDecorPassThrough.FILE_NAME = "FarmPilot_DecorTraverses.xml"
ADDecorPassThrough.MATCH_DIST = 1.5   -- m : même nom et nœud à moins que ça = même objet
ADDecorPassThrough.PLACE_DIST = 30    -- m : ignoré seulement quand le tracteur est à moins que ça de l'endroit traversé (un long muret reste vu ailleurs)
ADDecorPassThrough.entries = {}       -- { name, x, z }
ADDecorPassThrough.cache = {}         -- id du nœud -> entrées qui lui correspondent
ADDecorPassThrough.loaded = false

local function log(text, ...)
    print(string.format("[AD-Decor] " .. text, ...))
end

local function savegameFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. ADDecorPassThrough.FILE_NAME
end

function ADDecorPassThrough.load()
    if ADDecorPassThrough.loaded then
        return
    end
    ADDecorPassThrough.loaded = true
    local file = savegameFile()
    if file == nil or fileExists == nil or not fileExists(file) then
        return
    end
    local xml = loadXMLFile("fpDecorTraverses", file)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while true do
        local key = string.format("farmPilotDecorTraverses.object(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local e = { name = getXMLString(xml, key .. "#name"), x = getXMLFloat(xml, key .. "#x"), z = getXMLFloat(xml, key .. "#z"),
            px = getXMLFloat(xml, key .. "#px"), pz = getXMLFloat(xml, key .. "#pz") }
        if e.name ~= nil and e.x ~= nil and e.z ~= nil and e.px ~= nil and e.pz ~= nil then
            ADDecorPassThrough.entries[#ADDecorPassThrough.entries + 1] = e
        end
        i = i + 1
    end
    delete(xml)
    log("%d objet(s) de décor traversé(s) sans contact chargé(s) : ignorés par les capteurs", #ADDecorPassThrough.entries)
end

function ADDecorPassThrough.save()
    local file = savegameFile()
    if file == nil then
        return
    end
    local xml = createXMLFile("fpDecorTraverses", file, "farmPilotDecorTraverses")
    if xml == nil or xml == 0 then
        return
    end
    for i, e in ipairs(ADDecorPassThrough.entries) do
        local key = string.format("farmPilotDecorTraverses.object(%d)", i - 1)
        setXMLString(xml, key .. "#name", e.name)
        setXMLFloat(xml, key .. "#x", e.x)
        setXMLFloat(xml, key .. "#z", e.z)
        setXMLFloat(xml, key .. "#px", e.px)
        setXMLFloat(xml, key .. "#pz", e.pz)
    end
    saveXMLFile(xml)
    delete(xml)
end

local function nodeInfo(node)
    if node == nil or node == 0 or getName == nil or getWorldTranslation == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(node)
    return tostring(getName(node)), x, z
end

-- entrées retenues pour ce nœud (même nom, nœud au même endroit)
local function entriesOf(node)
    local list = ADDecorPassThrough.cache[node]
    if list ~= nil then
        return list
    end
    ADDecorPassThrough.load()
    list = {}
    local name, x, z = nodeInfo(node)
    if name ~= nil then
        for _, e in ipairs(ADDecorPassThrough.entries) do
            if e.name == name and MathUtil.vector2Length(e.x - x, e.z - z) <= ADDecorPassThrough.MATCH_DIST then
                list[#list + 1] = e
            end
        end
    end
    ADDecorPassThrough.cache[node] = list
    return list
end

-- vrai si ce nœud est un objet de décor déjà traversé sans contact, et le véhicule près de l'endroit traversé
function ADDecorPassThrough.isIgnored(node, vehicle)
    if node == nil or node == 0 or vehicle == nil or vehicle.components == nil or vehicle.components[1] == nil then
        return false
    end
    local list = entriesOf(node)
    if #list == 0 then
        return false
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    for _, e in ipairs(list) do
        if MathUtil.vector2Length(e.px - vx, e.pz - vz) <= ADDecorPassThrough.PLACE_DIST then
            return true
        end
    end
    return false
end

-- un capteur a vu ce nœud de décor : noté pendant l'avance au pas
function ADDecorPassThrough.noteHit(vehicle, node)
    local odm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.obstacleDetourModule or nil
    if odm == nil or odm.creep == nil or node == nil or node == 0 then
        return
    end
    odm.creep.decorNodes = odm.creep.decorNodes or {}
    odm.creep.decorNodes[node] = true
end

-- passé au pas sans rester coincé : les objets notés sont retenus et sauvés
function ADDecorPassThrough.rememberCreep(odm, vehicleName)
    local c = odm ~= nil and odm.creep or nil
    if c == nil or c.decorNodes == nil then
        return
    end
    ADDecorPassThrough.load()
    local added = {}
    for node, _ in pairs(c.decorNodes) do
        local name, x, z = nodeInfo(node)
        if name ~= nil and not ADDecorPassThrough.isIgnored(node, odm.vehicle) then
            local px, pz = (c.sx + (odm.creepEndX or c.sx)) / 2, (c.sz + (odm.creepEndZ or c.sz)) / 2
            ADDecorPassThrough.entries[#ADDecorPassThrough.entries + 1] = { name = name, x = x, z = z, px = px, pz = pz }
            ADDecorPassThrough.cache[node] = nil
            added[#added + 1] = string.format("'%s' (%.0f, %.0f)", name, x, z)
        end
    end
    if #added > 0 then
        ADDecorPassThrough.save()
        log("%s : traversé au pas sans contact : %s retenu(s), ignoré(s) ensuite par les capteurs", tostring(vehicleName), table.concat(added, ", "))
    end
end
