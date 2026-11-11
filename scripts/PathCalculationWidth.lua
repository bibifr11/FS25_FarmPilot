-- ============================================================================================================
-- FarmPilot : PathCalculationWidth.lua
-- Complément de PathCalculation.lua (calcul de route d'AutoDrive sur le réseau) : la largeur des routes.
-- Un tronçon du réseau où le train ne passe pas (mur, arbre, poteau, bâtiment, rambarde de pont plus près que sa
-- demi-largeur + marge, entre 0,3 m et 3 m au-dessus de la ligne) reçoit un gros poids : une autre route est prise
-- quand il y en a une ; sinon le tronçon est gardé et le journal le dit ([AD-Width]).
-- - Largeur du train : tracteur mesuré à ses pneus (roues jumelées montées comprises), remorques à leur taille,
--   outils repliables à leur largeur de transport (2,4 m).
-- - Mesures gardées par demi-largeur arrondie à 10 cm, oubliées quand le réseau change.
-- - Débogage (canal capteurs) : en bleu la largeur prise, en rouge les tronçons refusés et l'objet touché.
--
-- Règle : le bord invisible de la carte et les véhicules (qui bougent) ne comptent pas dans la largeur.
--
-- Branché par PathCalculation.lua : GetPath (getNarrowWeightFunc, resetWidthCache, logNarrowRoute) ; debugDraw par
-- AutoDrive.lua ; getPassageWidth par PathFinderModuleObstacles.lua ; tronçons étroits relus par
-- PathCalculationShift.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- route width check ------------------------------------------------------------------------------
ADPathCalculator.NARROW_WEIGHT = 100000        -- added to a too narrow section: used only if there is no other way
ADPathCalculator.WIDTH_MARGIN = 0.05           -- m free on each side of the train
ADPathCalculator.WIDTH_CHECK_LOW = 0.3         -- m above ground: curbs and verges are ignored
ADPathCalculator.WIDTH_CHECK_HIGH = 3.0        -- m above ground
ADPathCalculator.widthMask = CollisionFlag.DEFAULT + CollisionFlag.STATIC_OBJECT + CollisionFlag.TREE + CollisionFlag.BUILDING
ADPathCalculator.widthCache = {}               -- [halfWidth][fromId][toId] = true when too narrow, false when fine

ADPathCalculator.FOLDED_TOOL_WIDTH = 2.4        -- m, transport width counted for a foldable tool

-- ------------------------------------------------------------------------------------------------------------
-- Largeur du train
-- ------------------------------------------------------------------------------------------------------------
-- width the train needs to pass: tractor measured at its tyres, trailers at their size, foldable tools at their transport
-- width (their declared size is often the unfolded one)
function ADPathCalculator.getPassageWidth(vehicle)
    local width = 0
    local units = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            if unit.size ~= nil and unit.size.width ~= nil then
                local unitWidth = unit.size.width
                local foldable = unit.spec_foldable
                if unit == vehicle then
                    unitWidth = ADPathCalculator.getWheelsWidth(vehicle) or unitWidth
                elseif foldable ~= nil and foldable.foldingParts ~= nil and #foldable.foldingParts > 0 then
                    unitWidth = math.min(unitWidth, ADPathCalculator.FOLDED_TOOL_WIDTH)
                end
                width = math.max(width, unitWidth)
            end
        end
    end
    if width <= 0 then
        width = 3
    end
    return width
end

-- width from the outside of the left tyre to the outside of the right tyre, mounted (visible) dual
-- wheels included; nil when it cannot be measured
function ADPathCalculator.getWheelsWidth(vehicle)
    local wheels = vehicle.spec_wheels ~= nil and vehicle.spec_wheels.wheels or nil
    local root = vehicle.rootNode or (vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node)
    if wheels == nil or root == nil or root == 0 then
        return nil
    end
    local minX, maxX = math.huge, -math.huge
    local function add(node, width)
        if node == nil or node == 0 or type(width) ~= "number" or width <= 0 then
            return
        end
        local ok, visible = FarmPilotCall(getEffectiveVisibility, node)
        if ok and visible == false then
            return -- dual wheel not mounted
        end
        local okPos, x = FarmPilotCall(localToLocal, node, root, 0, 0, 0)
        if okPos and type(x) == "number" then
            minX = math.min(minX, x - width / 2)
            maxX = math.max(maxX, x + width / 2)
        end
    end
    for _, wheel in ipairs(wheels) do
        local physicsWidth = wheel.physics ~= nil and wheel.physics.width or nil
        if wheel.visualWheels ~= nil and #wheel.visualWheels > 0 then
            for _, visualWheel in ipairs(wheel.visualWheels) do
                add(visualWheel.node, visualWheel.width or physicsWidth)
            end
        else
            add(wheel.repr or wheel.driveNode or wheel.node, physicsWidth)
        end
    end
    if maxX <= minX or maxX - minX < 1 or maxX - minX > 10 then
        return nil
    end
    local width = maxX - minX
    if vehicle.adLastWheelsWidth == nil or math.abs(vehicle.adLastWheelsWidth - width) > 0.1 then
        vehicle.adLastWheelsWidth = width
        print(string.format("[AD-Width] %s: width at the tyres %.2f m (vehicle file %.2f m)", tostring(vehicle:getName()), width, vehicle.size ~= nil and vehicle.size.width or 0))
    end
    return width
end

-- ------------------------------------------------------------------------------------------------------------
-- Poids des tronçons trop étroits (calcul de route)
-- ------------------------------------------------------------------------------------------------------------
function ADPathCalculator:getNarrowWeightFunc(vehicle)
    if vehicle == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return function() return 0 end
    end
    local width = ADPathCalculator.getPassageWidth(vehicle)
    -- rounded to 10 cm so vehicles of about the same width share the measures
    local halfWidth = math.ceil((width / 2 + ADPathCalculator.WIDTH_MARGIN) * 10) / 10
    ADPathCalculator.lastNeededWidth = halfWidth * 2
    ADPathCalculator.widthCache[halfWidth] = ADPathCalculator.widthCache[halfWidth] or {}
    local cache = ADPathCalculator.widthCache[halfWidth]
    return function(a, b)
        local fromCache = cache[a.id]
        if fromCache == nil then
            fromCache = {}
            cache[a.id] = fromCache
        end
        local narrow = fromCache[b.id]
        if narrow == nil then
            narrow = ADPathCalculator.isSectionNarrow(a, b, halfWidth)
            fromCache[b.id] = narrow
        end
        if narrow then
            return ADPathCalculator.NARROW_WEIGHT
        end
        return 0
    end
end

function ADPathCalculator.isSectionNarrow(a, b, halfWidth)
    local dx, dz = b.x - a.x, b.z - a.z
    local length = math.sqrt(dx * dx + dz * dz)
    if length < 0.1 then
        return false
    end
    local cx, cz = (a.x + b.x) / 2, (a.z + b.z) / 2
    -- height of the network line (road or bridge deck), not of the terrain under a bridge
    local y
    if type(a.y) == "number" and type(b.y) == "number" and a.y ~= -1 and b.y ~= -1 then
        y = (a.y + b.y) / 2
    else
        y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 1, cz)
    end
    local low, high = ADPathCalculator.WIDTH_CHECK_LOW, ADPathCalculator.WIDTH_CHECK_HIGH
    ADPathCalculator.widthHits = 0
    ADPathCalculator.widthHitNode = nil
    overlapBox(cx, y + (low + high) / 2, cz, 0, math.atan2(dx, dz), 0, halfWidth, (high - low) / 2, length / 2, "widthCheckCallback", ADPathCalculator, ADPathCalculator.widthMask, true, true, true, true)
    if ADPathCalculator.widthHits > 0 then
        -- diagnostic: widest free corridor, and whether it is free higher up
        local function hits(hw, lo, hi)
            ADPathCalculator.widthHits = 0
            overlapBox(cx, y + (lo + hi) / 2, cz, 0, math.atan2(dx, dz), 0, hw, (hi - lo) / 2, length / 2, "widthCheckCallback", ADPathCalculator, ADPathCalculator.widthMask, true, true, true, true)
            return ADPathCalculator.widthHits > 0
        end
        local hitNode = ADPathCalculator.widthHitNode
        local freeHalf = 0
        for hw = 0.2, halfWidth, 0.1 do
            if hits(hw, low, high) then
                break
            end
            freeHalf = hw
        end
        local diag = {}
        for _, lo in ipairs({0.5, 0.8, 1.2}) do
            table.insert(diag, string.format("from %.1f m: %s", lo, hits(halfWidth, lo, high) and "hit" or "free"))
        end
        print(string.format("[AD-Width] section %s -> %s: line y %.2f, terrain %.2f, free width %.1f m, %s", tostring(a.id), tostring(b.id), y, getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 1, cz), freeHalf * 2, table.concat(diag, ", ")))
        ADPathCalculator.widthHits = 1
        ADPathCalculator.recordNarrowSection(a, b, halfWidth, hitNode)
        return true
    end
    return false
end

-- accroche de GetPath (réseau changé)
function ADPathCalculator.resetWidthCache()
    ADPathCalculator.widthCache = {} -- network changed: measure again
    ADPathCalculator.narrowSections = {}
    ADPathCalculator.narrowInfo = {}
end

-- accroche de GetPath (route trouvée) : tronçons trop étroits gardés faute d'autre route
function ADPathCalculator.logNarrowRoute(vehicle, path, narrowWeight)
    if vehicle ~= nil then
        local narrow = 0
        for i = 1, #path - 1 do
            if narrowWeight(path[i], path[i + 1]) > 0 then
                narrow = narrow + 1
            end
        end
        if narrow > 0 then
            print(string.format("[AD-Width] %s: no wide enough route, %d narrow section(s) kept (needs %.1f m)", tostring(vehicle:getName()), narrow, ADPathCalculator.lastNeededWidth or 0))
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Tronçons trop étroits relevés
-- ------------------------------------------------------------------------------------------------------------
-- debug: narrow sections found, drawn in red with the AutoDrive sensor debug channel
ADPathCalculator.narrowSections = {}
ADPathCalculator.narrowInfo = {}               -- ["fromId>toId"] = {hitName, hx, hz}: what made a section too narrow

function ADPathCalculator.recordNarrowSection(a, b, halfWidth, hitNode)
    local hitName, hx, hy, hz = "?", nil, nil, nil
    if hitNode ~= nil and hitNode ~= 0 then
        local okName, name = FarmPilotCall(getName, hitNode)
        if okName and name ~= nil then
            hitName = name
        end
        local okParent, parent = FarmPilotCall(getParent, hitNode)
        if okParent and parent ~= nil and parent ~= 0 then
            local okParentName, parentName = FarmPilotCall(getName, parent)
            if okParentName and parentName ~= nil then
                hitName = parentName .. "/" .. hitName
            end
        end
        local okPos, x, y, z = FarmPilotCall(getWorldTranslation, hitNode)
        if okPos then
            hx, hy, hz = x, y, z
        end
    end
    table.insert(ADPathCalculator.narrowSections, {a = a, b = b, halfWidth = halfWidth, hitName = hitName, hx = hx, hy = hy, hz = hz})
    ADPathCalculator.narrowInfo[tostring(a.id) .. ">" .. tostring(b.id)] = {hitName = hitName, hx = hx, hz = hz}
    print(string.format("[AD-Width] section %s -> %s too narrow for %.1f m: hit '%s' at %s", tostring(a.id), tostring(b.id), halfWidth * 2, hitName, hx ~= nil and string.format("%.1f %.1f", hx, hz) or "?"))
end

-- ------------------------------------------------------------------------------------------------------------
-- Affichage (canal de débogage des capteurs)
-- ------------------------------------------------------------------------------------------------------------
local function drawRectangle(x, y, z, dirX, dirZ, halfWidth, front, back, r, g, b)
    local sideX, sideZ = dirZ, -dirX
    local corners = {
        {x + dirX * front + sideX * halfWidth, z + dirZ * front + sideZ * halfWidth},
        {x + dirX * front - sideX * halfWidth, z + dirZ * front - sideZ * halfWidth},
        {x - dirX * back - sideX * halfWidth, z - dirZ * back - sideZ * halfWidth},
        {x - dirX * back + sideX * halfWidth, z - dirZ * back + sideZ * halfWidth}
    }
    for i = 1, 4 do
        local c1, c2 = corners[i], corners[i % 4 + 1]
        ADDrawingManager:addLineTask(c1[1], y, c1[2], c2[1], y, c2[2], 1, r, g, b)
    end
end

function ADPathCalculator.debugDraw()
    local vehicle = AutoDrive.getControlledVehicle()
    if vehicle == nil or vehicle.components == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return
    end
    local vx, vy, vz = getWorldTranslation(vehicle.components[1].node)
    local dirX, _, dirZ = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local length = vehicle.size ~= nil and vehicle.size.length or 5
    -- blue: width taken into account for narrow passages
    local halfWidth = ADPathCalculator.getPassageWidth(vehicle) / 2
    drawRectangle(vx, vy + 0.3, vz, dirX, dirZ, halfWidth, length / 2, length / 2, 0, 0.4, 1)
    -- red: sections refused as too narrow, and the object that was hit
    local maxDistance = AutoDrive.drawDistance or 300
    for _, section in ipairs(ADPathCalculator.narrowSections) do
        local a, b = section.a, section.b
        local cx, cz = (a.x + b.x) / 2, (a.z + b.z) / 2
        if MathUtil.vector2Length(cx - vx, cz - vz) < maxDistance then
            local dx, dz = b.x - a.x, b.z - a.z
            local sectionLength = math.sqrt(dx * dx + dz * dz)
            if sectionLength > 0.1 then
                local y = ((type(a.y) == "number" and type(b.y) == "number" and a.y ~= -1 and b.y ~= -1) and (a.y + b.y) / 2 or getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, cx, 1, cz)) + ADPathCalculator.WIDTH_CHECK_LOW
                drawRectangle(cx, y, cz, dx / sectionLength, dz / sectionLength, section.halfWidth, sectionLength / 2, sectionLength / 2, 1, 0, 0)
            end
            if section.hx ~= nil then
                ADDrawingManager:addLineTask(section.hx, section.hy, section.hz, section.hx, section.hy + 4, section.hz, 1, 1, 0, 0)
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Rappel de overlapBox
-- ------------------------------------------------------------------------------------------------------------
function ADPathCalculator.isMapBorder(node)
    for _ = 1, 2 do
        if node == nil or node == 0 then
            return false
        end
        local ok, name = FarmPilotCall(getName, node)
        if ok and type(name) == "string" and string.find(string.lower(name), "border", 1, true) ~= nil then
            return true
        end
        local okParent, parent = FarmPilotCall(getParent, node)
        node = okParent and parent or nil
    end
    return false
end

function ADPathCalculator:widthCheckCallback(transformId)
    if transformId == 0 or transformId == g_currentMission.terrainRootNode then
        return true
    end
    if ADPathCalculator.isMapBorder(transformId) then
        return true -- invisible wall at the map edge
    end
    local object = g_currentMission:getNodeObject(transformId)
    if object ~= nil and (object.rootVehicle ~= nil or object.isa ~= nil and object:isa(Vehicle)) then
        return true -- vehicles move, they are not part of the road width
    end
    ADPathCalculator.widthHits = ADPathCalculator.widthHits + 1
    ADPathCalculator.widthHitNode = transformId
    return false
end
