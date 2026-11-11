-- ============================================================================================================
-- FarmPilot : BaleLoaderManager.lua
-- Mode Autonome : la remorque à balles (ramasseuse autochargeuse : spec_baleLoader).
--
-- Règle (09/11) :
-- - Même roue dentée que le semoir et l'épandeur, à gauche de la ligne « Outil » (ou « Outil suivant »). Elle ouvre
--   la fenêtre « Réglages de la remorque à balles » (BaleLoaderSettingsGUI.lua) : balles à ramasser (toutes,
--   enrubannées seulement, non enrubannées seulement) et zone de dépôt (un marqueur de la carte). Dans la liste des
--   zones, les marqueurs près d'un point de vente qui prend les balles viennent en premier, puis tous les autres
--   (stockage : les balles sont posées au marqueur). Choix retenu par champ et par machine, comme le semoir.
-- - Tant que ce n'est pas validé, le départ est refusé (roue dentée orange, verte une fois validé).
-- - Les balles : rondes ou carrées selon ce que la remorque sait charger (ses types de balles, fonction du jeu
--   getBaleTypeByBale), sur le champ de la ligne « Champ » (groupe AutoSwitch compris), libres (pas sur une autre
--   machine), à notre ferme, et du même produit que celles déjà chargées si la remorque ne mélange pas.
-- - Le ramassage lui-même : BaleCollectTask.lua ; la suite (dépôt, retour, fin de champ) : AutonomousBales.lua.
--
-- Branché par une ligne dans : AutonomousMode.lua (start : refuseStart), HudButton.lua (hudGear), AutoDrive.lua
-- (saveToXml). Lu aussi par BaleLoaderSettingsGUI.lua, BaleCollectTask.lua et AutonomousBales.lua.
-- ============================================================================================================

ADBaleLoaderManager = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADBaleLoaderManager.FILE_NAME = "FarmPilot_RemorquesBalles.xml"
ADBaleLoaderManager.settings = {}   -- [nom du champ .. "|" .. clé de la machine] = { field, tool, toolName, wrap, deposit, stamp }
ADBaleLoaderManager.loaded = false
ADBaleLoaderManager.stamp = 0
ADBaleLoaderManager.WRAP_ALL = "all"
ADBaleLoaderManager.WRAP_WRAPPED = "wrapped"
ADBaleLoaderManager.WRAP_UNWRAPPED = "unwrapped"
ADBaleLoaderManager.WRAP_ORDER = { "all", "wrapped", "unwrapped" }
ADBaleLoaderManager.SALE_RADIUS = 60       -- m entre le marqueur et la zone où le point de vente prend les balles
ADBaleLoaderManager.FIELD_MARGIN = 6       -- m : balle au bord du champ (posée sur la tournière, l'herbe) comptée au champ
ADBaleLoaderManager.MAX_HEIGHT = 1.6       -- m : centre de la balle plus haut que ça au-dessus du sol = sur une pile ou une remorque
-- produits de balles regardés pour les points de vente quand la remorque est vide
ADBaleLoaderManager.SALE_FILLTYPES = { "STRAW", "DRYGRASS_WINDROW", "GRASS_WINDROW", "SILAGE", "COTTON" }

local function log(fmt, ...)
    local ok, s = FarmPilotCall(string.format, fmt, ...)
    print("[FarmPilot Balles] " .. (ok and s or tostring(fmt)))
end
ADBaleLoaderManager.log = log

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
ADBaleLoaderManager.safe = safe

-- ------------------------------------------------------------------------------------------------------------
-- Quelle machine
-- ------------------------------------------------------------------------------------------------------------
function ADBaleLoaderManager.isBaleLoader(tool)
    return tool ~= nil and tool.spec_baleLoader ~= nil and not tool.isDeleted and not tool.isDeleting
end

-- remorque à balles de ce véhicule : la machine elle-même (automotrice), sinon l'outil attelé
function ADBaleLoaderManager.attachedLoader(vehicle)
    if vehicle == nil then
        return nil
    end
    if ADBaleLoaderManager.isBaleLoader(vehicle) then
        return vehicle
    end
    local okT, tools = FarmPilotCall(ADAutonomousManager.workTools, vehicle)
    for _, t in ipairs(okT and tools or {}) do
        if ADBaleLoaderManager.isBaleLoader(t) then
            return t
        end
    end
    return nil
end

-- outil de la ligne « Outil » (ou « Outil suivant ») : celui choisi si c'est une remorque à balles, sinon celle attelée
function ADBaleLoaderManager.rowTool(vehicle, isNext)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil then
        return nil
    end
    if isNext and sm.getFpNextTool ~= nil then
        local nextTool = sm:getFpNextTool()
        if nextTool ~= nil then
            return ADBaleLoaderManager.isBaleLoader(nextTool) and nextTool or nil
        end
    end
    local tool = sm.getFpTool ~= nil and sm:getFpTool() or nil
    if tool ~= nil then
        return ADBaleLoaderManager.isBaleLoader(tool) and tool or nil
    end
    return ADBaleLoaderManager.attachedLoader(vehicle)
end

function ADBaleLoaderManager.isAttached(tool, vehicle)
    return tool ~= nil and (tool == vehicle or ADSeederManager.attachedTo(tool, vehicle))
end

-- { tool, toolKey, field (nom du marqueur), marker, vehicle } si la ligne a une remorque à balles et un champ ; sinon nil
function ADBaleLoaderManager.context(vehicle, isNext)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil then
        return nil
    end
    if vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return nil
    end
    local tool = ADBaleLoaderManager.rowTool(vehicle, isNext)
    if tool == nil then
        return nil
    end
    local marker = ADSeederManager.rowField(vehicle, isNext)
    if marker == nil or marker.name == nil then
        return nil
    end
    return { tool = tool, toolKey = ADSeederManager.toolKey(tool), field = marker.name, marker = marker, vehicle = vehicle }
end

-- ------------------------------------------------------------------------------------------------------------
-- La remorque : état du bras, chargement, types de balles
-- ------------------------------------------------------------------------------------------------------------
function ADBaleLoaderManager.spec(loader)
    return loader ~= nil and loader.spec_baleLoader or nil
end

-- nombre de balles chargées
function ADBaleLoaderManager.loadedCount(loader)
    local spec = ADBaleLoaderManager.spec(loader)
    if spec == nil then
        return 0
    end
    if spec.fillUnitIndex ~= nil and loader.getFillUnitFillLevel ~= nil then
        local level = safe(loader.getFillUnitFillLevel, loader, spec.fillUnitIndex)
        if type(level) == "number" then
            return math.floor(level + 0.5)
        end
    end
    local bales = loader.getLoadedBales ~= nil and safe(loader.getLoadedBales, loader) or nil
    return type(bales) == "table" and #bales or 0
end

-- places : nombre de balles quand elle est pleine (nil si inconnu)
function ADBaleLoaderManager.capacity(loader)
    local spec = ADBaleLoaderManager.spec(loader)
    if spec ~= nil and spec.fillUnitIndex ~= nil and loader.getFillUnitCapacity ~= nil then
        local cap = safe(loader.getFillUnitCapacity, loader, spec.fillUnitIndex)
        if type(cap) == "number" and cap > 0 and cap < math.huge then
            return math.floor(cap + 0.5)
        end
    end
    return nil
end

-- pleine : le jeu n'attrape plus de balle quand la place libre est à 0 (getIsBaleGrabbingAllowed)
function ADBaleLoaderManager.isFull(loader)
    local spec = ADBaleLoaderManager.spec(loader)
    if spec == nil or spec.fillUnitIndex == nil or loader.getFillUnitFreeCapacity == nil then
        return false
    end
    local free = safe(loader.getFillUnitFreeCapacity, loader, spec.fillUnitIndex)
    return type(free) == "number" and free <= 0.01
end

-- le bras ou le plateau bouge encore (balle en train d'être chargée, plateau qui tourne, pousseur)
function ADBaleLoaderManager.isBusy(loader)
    local spec = ADBaleLoaderManager.spec(loader)
    if spec == nil then
        return false
    end
    if spec.grabberMoveState ~= nil or spec.grabberIsMoving then
        return true
    end
    if (spec.rotatePlatformDirection or 0) ~= 0 or (spec.frontBalePusherDirection or 0) ~= 0 then
        return true
    end
    return false
end

-- en train de décharger (plateau levé, balles qui tombent)
function ADBaleLoaderManager.isUnloading(loader)
    local spec = ADBaleLoaderManager.spec(loader)
    if spec == nil then
        return false
    end
    if loader.getIsAutomaticBaleUnloadingInProgress ~= nil and safe(loader.getIsAutomaticBaleUnloadingInProgress, loader) then
        return true
    end
    return BaleLoader ~= nil and spec.emptyState ~= nil and spec.emptyState ~= BaleLoader.EMPTY_NONE
end

function ADBaleLoaderManager.isInWorkPosition(loader)
    local spec = ADBaleLoaderManager.spec(loader)
    return spec ~= nil and spec.isInWorkPosition == true
end

-- position travail (bras sorti) ou transport : même commande que la touche du jeu
function ADBaleLoaderManager.setWorkPosition(loader, work)
    local spec = ADBaleLoaderManager.spec(loader)
    if spec == nil or BaleLoader == nil or loader.doStateChange == nil then
        return false
    end
    if (spec.isInWorkPosition == true) == (work == true) then
        return true
    end
    if ADBaleLoaderManager.isBusy(loader) or ADBaleLoaderManager.isUnloading(loader) then
        return false
    end
    local ok = FarmPilotCall(loader.doStateChange, loader, BaleLoader.CHANGE_BUTTON_WORK_TRANSPORT)
    return ok
end

-- le bras qui attrape les balles : nœud, portée (m)
function ADBaleLoaderManager.grabber(loader)
    local spec = ADBaleLoaderManager.spec(loader)
    local g = spec ~= nil and spec.baleGrabber or nil
    if g == nil or g.grabNode == nil then
        return nil
    end
    return g.grabNode, g.pickupRange or 3
end

-- « rondes », « carrées » ou les deux (fenêtre des réglages)
function ADBaleLoaderManager.baleKinds(loader)
    local spec = ADBaleLoaderManager.spec(loader)
    local round, square = false, false
    for _, bt in pairs(spec ~= nil and spec.baleTypes or {}) do
        local dim = bt.dimensions or bt
        if dim.isRoundbale then
            round = true
        else
            square = true
        end
    end
    if round and square then
        return "both"
    elseif round then
        return "round"
    elseif square then
        return "square"
    end
    return nil
end

-- produit des balles déjà chargées (nil si vide)
function ADBaleLoaderManager.loadedFillType(loader)
    local bales = loader ~= nil and loader.getLoadedBales ~= nil and safe(loader.getLoadedBales, loader) or nil
    for _, b in ipairs(type(bales) == "table" and bales or {}) do
        local ft = b.getFillType ~= nil and safe(b.getFillType, b) or b.fillType
        if ft ~= nil then
            return ft
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Les balles au champ
-- ------------------------------------------------------------------------------------------------------------
-- toutes les balles de la carte (liste du jeu des objets comptés, sinon les objets sauvegardés)
function ADBaleLoaderManager.allBales()
    local list = {}
    local mission = g_currentMission
    if mission == nil then
        return list
    end
    local seen = {}
    local function add(o)
        if type(o) == "table" and not seen[o] and o.nodeId ~= nil then
            if Bale == nil or o.isa == nil or o:isa(Bale) then
                seen[o] = true
                list[#list + 1] = o
            end
        end
    end
    local ss = mission.slotSystem
    local idx = SlotSystem ~= nil and SlotSystem.LIMITED_OBJECT_BALE or nil
    local limit = ss ~= nil and ss.objectLimits ~= nil and idx ~= nil and ss.objectLimits[idx] or nil
    if limit ~= nil and type(limit.objects) == "table" then
        for k, v in pairs(limit.objects) do
            add(type(v) == "table" and v or k)
        end
        return list
    end
    local items = mission.itemSystem ~= nil and mission.itemSystem.itemsToSave or nil
    for k, v in pairs(items or {}) do
        local o = type(v) == "table" and (v.item or v) or k
        add(o)
    end
    return list
end

-- balle enrubannée (le jeu : wrappingState de 0 à 1)
function ADBaleLoaderManager.isWrapped(bale)
    return (tonumber(bale.wrappingState) or 0) > 0
end

function ADBaleLoaderManager.balePosition(bale)
    local x, y, z = getWorldTranslation(bale.nodeId)
    return x, y, z
end

-- numéros de champ comptés comme « le champ » (groupe AutoSwitch compris)
function ADBaleLoaderManager.fieldNumbers(fieldNum)
    local set = {}
    if fieldNum == nil then
        return set
    end
    local okG, g = FarmPilotCall(ADAutonomousManager.groupOf, fieldNum)
    for _, n in ipairs(okG and g ~= nil and g.members or { fieldNum }) do
        set[tonumber(n) or n] = true
    end
    set[tonumber(fieldNum) or fieldNum] = true
    return set
end

-- la balle est sur le champ (ou à FIELD_MARGIN m du bord)
function ADBaleLoaderManager.onField(x, z, nums)
    local function at(px, pz)
        local f = ADAutonomousManager.fieldAt(px, pz)
        local n = f ~= nil and ADAutonomousManager.fieldNumber(f) or nil
        return n ~= nil and nums[tonumber(n) or n] == true
    end
    if at(x, z) then
        return true
    end
    local m = ADBaleLoaderManager.FIELD_MARGIN
    return at(x + m, z) or at(x - m, z) or at(x, z + m) or at(x, z - m)
end

-- pourquoi la remorque ne prendrait pas cette balle (nil = elle la prend) ; mêmes contrôles que le jeu
-- (BaleLoader.getBaleInRange), sauf la distance
function ADBaleLoaderManager.rejectReason(loader, bale, wrap)
    if bale == nil or bale.isDeleted or bale.nodeId == nil or (entityExists ~= nil and not entityExists(bale.nodeId)) then
        return "gone"
    end
    if bale.getIsMounted ~= nil and safe(bale.getIsMounted, bale) then
        return "mounted"
    end
    if bale.baleJointIndex ~= nil or bale.mountObject ~= nil or bale.dynamicMountObject ~= nil then
        return "mounted"
    end
    if bale.getBaleSupportsBaleLoader ~= nil and not safe(bale.getBaleSupportsBaleLoader, bale) then
        return "notSupported"
    end
    local spec = ADBaleLoaderManager.spec(loader)
    local baleType = loader.getBaleTypeByBale ~= nil and safe(loader.getBaleTypeByBale, loader, bale) or nil
    if baleType == nil then
        return "size"
    end
    -- un seul type de balle à la fois sur la remorque
    if spec ~= nil and spec.currentBaleType ~= nil and spec.currentBaleType ~= baleType and ADBaleLoaderManager.loadedCount(loader) > 0 then
        return "otherType"
    end
    if not baleType.mixedFillTypes then
        local loadedFt = ADBaleLoaderManager.loadedFillType(loader)
        local ft = bale.getFillType ~= nil and safe(bale.getFillType, bale) or bale.fillType
        if loadedFt ~= nil and ft ~= nil and ft ~= loadedFt then
            return "otherProduct"
        end
    end
    -- notre ferme
    local farmId = loader.getActiveFarm ~= nil and safe(loader.getActiveFarm, loader) or (loader.getOwnerFarmId ~= nil and safe(loader.getOwnerFarmId, loader)) or nil
    if farmId ~= nil and bale.ownerFarmId ~= nil and bale.ownerFarmId ~= farmId then
        local ah = g_currentMission ~= nil and g_currentMission.accessHandler or nil
        if ah == nil or ah.canFarmAccessOtherId == nil or not safe(ah.canFarmAccessOtherId, ah, farmId, bale.ownerFarmId) then
            return "farm"
        end
    end
    if wrap == ADBaleLoaderManager.WRAP_WRAPPED and not ADBaleLoaderManager.isWrapped(bale) then
        return "wrap"
    elseif wrap == ADBaleLoaderManager.WRAP_UNWRAPPED and ADBaleLoaderManager.isWrapped(bale) then
        return "wrap"
    end
    return nil
end

-- balle posée sur une autre (pile) ou sur une remorque : pas au sol, le bras ne la prend pas
function ADBaleLoaderManager.isRaised(x, y, z)
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if terrain == nil or getTerrainHeightAtWorldPos == nil then
        return false
    end
    local h = safe(getTerrainHeightAtWorldPos, terrain, x, 0, z)
    return type(h) == "number" and y - h > ADBaleLoaderManager.MAX_HEIGHT
end

-- balles à ramasser sur le champ : { {bale, x, y, z, round} }, et le nombre de balles vues sur le champ
-- skip = { [balle] = true } : balles à laisser (ratées deux fois, prises par une autre remorque)
function ADBaleLoaderManager.findBales(loader, nums, wrap, skip)
    local out, onFieldCount = {}, 0
    for _, bale in ipairs(ADBaleLoaderManager.allBales()) do
        if bale.nodeId ~= nil and (entityExists == nil or entityExists(bale.nodeId)) then
            local x, y, z = ADBaleLoaderManager.balePosition(bale)
            if ADBaleLoaderManager.onField(x, z, nums) and not ADBaleLoaderManager.isRaised(x, y, z) then
                onFieldCount = onFieldCount + 1
                if (skip == nil or not skip[bale]) and ADBaleLoaderManager.rejectReason(loader, bale, wrap) == nil then
                    out[#out + 1] = { bale = bale, x = x, y = y, z = z, round = bale.isRoundbale == true }
                end
            end
        end
    end
    return out, onFieldCount
end

-- ------------------------------------------------------------------------------------------------------------
-- Zones de dépôt : points de vente qui prennent les balles
-- ------------------------------------------------------------------------------------------------------------
local function isBaleTrigger(trigger)
    if trigger == nil then
        return false
    end
    if BaleUnloadTrigger ~= nil and trigger.isa ~= nil and safe(trigger.isa, trigger, BaleUnloadTrigger) then
        return true
    end
    return trigger.baleTrigger ~= nil
end

local function baleTriggerPos(trigger)
    local node = trigger.triggerNode
    if trigger.baleTrigger ~= nil and trigger.baleTrigger.triggerNode ~= nil then
        node = trigger.baleTrigger.triggerNode
    end
    if node == nil or (entityExists ~= nil and not entityExists(node)) then
        return nil
    end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

local function stationAccepts(station, trigger, fillTypes)
    for _, ft in ipairs(fillTypes) do
        local ok = nil
        if trigger.getIsFillTypeAllowed ~= nil then
            ok = safe(trigger.getIsFillTypeAllowed, trigger, ft)
        end
        if ok == nil and station.supportedFillTypes ~= nil then
            ok = station.supportedFillTypes[ft] == true
        end
        if ok == nil and station.getIsFillTypeAllowed ~= nil then
            ok = safe(station.getIsFillTypeAllowed, station, ft)
        end
        if ok == nil or ok == true then
            return true
        end
    end
    return false
end

-- { {x, z, name} } : zones de vente des balles (produit des balles chargées, sinon les produits de balles courants)
function ADBaleLoaderManager.saleSpots(loader)
    local out = {}
    local mission = g_currentMission
    local storage = mission ~= nil and mission.storageSystem or nil
    if storage == nil or storage.getUnloadingStations == nil then
        return out
    end
    local fillTypes = {}
    local loadedFt = loader ~= nil and ADBaleLoaderManager.loadedFillType(loader) or nil
    if loadedFt ~= nil then
        fillTypes[1] = loadedFt
    elseif g_fillTypeManager ~= nil then
        for _, n in ipairs(ADBaleLoaderManager.SALE_FILLTYPES) do
            local ft = g_fillTypeManager:getFillTypeIndexByName(n)
            if ft ~= nil then
                fillTypes[#fillTypes + 1] = ft
            end
        end
    end
    for _, station in pairs(safe(storage.getUnloadingStations, storage) or {}) do
        local selling = station.isSellingPoint == true or (SellingStation ~= nil and station.isa ~= nil and safe(station.isa, station, SellingStation) == true)
        if selling and type(station.unloadTriggers) == "table" then
            for _, trigger in pairs(station.unloadTriggers) do
                if isBaleTrigger(trigger) and stationAccepts(station, trigger, fillTypes) then
                    local x, z = baleTriggerPos(trigger)
                    if x ~= nil then
                        local name = station.getName ~= nil and safe(station.getName, station) or station.uiName
                        out[#out + 1] = { x = x, z = z, name = name }
                    end
                end
            end
        end
    end
    return out
end

-- { [nom du marqueur] = nom du point de vente } : marqueurs à SALE_RADIUS m d'une zone de vente des balles
function ADBaleLoaderManager.saleMarkers(loader)
    local out = {}
    local spots = ADBaleLoaderManager.saleSpots(loader)
    if #spots == 0 then
        return out
    end
    local r2 = ADBaleLoaderManager.SALE_RADIUS * ADBaleLoaderManager.SALE_RADIUS
    for _, m in pairs(ADGraphManager:getMapMarkers() or {}) do
        local wp = m ~= nil and m.name ~= nil and ADGraphManager:getWayPointById(m.id) or nil
        if wp ~= nil and wp.x ~= nil then
            local best, bestD = nil, math.huge
            for _, s in ipairs(spots) do
                local d = (wp.x - s.x) ^ 2 + (wp.z - s.z) ^ 2
                if d <= r2 and d < bestD then
                    best, bestD = s, d
                end
            end
            if best ~= nil then
                out[m.name] = tostring(best.name or "")
            end
        end
    end
    return out
end

-- ------------------------------------------------------------------------------------------------------------
-- Mémoire champ + machine
-- ------------------------------------------------------------------------------------------------------------
function ADBaleLoaderManager:get(field, toolKey)
    self:loadFromXml()
    return self.settings[ADSeederManager.key(field, toolKey)]
end

-- derniers réglages de cette machine (n'importe quel champ), pour préremplir la fenêtre
function ADBaleLoaderManager:lastFor(toolKey)
    self:loadFromXml()
    local best = nil
    for _, s in pairs(self.settings) do
        if s.tool == toolKey and (best == nil or (s.stamp or 0) > (best.stamp or 0)) then
            best = s
        end
    end
    return best
end

function ADBaleLoaderManager.validWrap(w)
    if w == ADBaleLoaderManager.WRAP_WRAPPED or w == ADBaleLoaderManager.WRAP_UNWRAPPED then
        return w
    end
    return ADBaleLoaderManager.WRAP_ALL
end

function ADBaleLoaderManager:set(field, tool, s)
    self:loadFromXml()
    self.stamp = self.stamp + 1
    local toolKey = ADSeederManager.toolKey(tool)
    local entry = {
        field = field, tool = toolKey, toolName = ADAutonomousManager.toolLabel(tool), wrap = ADBaleLoaderManager.validWrap(s.wrap),
        deposit = s.deposit, stamp = self.stamp
    }
    self.settings[ADSeederManager.key(field, toolKey)] = entry
    log("« %s », machine %s : balles %s, dépôt « %s »", tostring(field), toolKey, entry.wrap, tostring(entry.deposit))
    return entry
end

-- ce qui manque : nil si c'est bon, sinon « none » ou « deposit » (zone absente ou effacée)
function ADBaleLoaderManager.missing(s)
    if s == nil then
        return "none"
    end
    if s.deposit == nil or ADGraphManager:getMapMarkerByName(s.deposit) == nil then
        return "deposit"
    end
    return nil
end

function ADBaleLoaderManager.isValid(s)
    return ADBaleLoaderManager.missing(s) == nil
end

-- roue dentée : « none » (pas de remorque à balles sur la ligne), « ok » (validé), « todo » (à régler)
function ADBaleLoaderManager.status(vehicle, isNext)
    local ctx = ADBaleLoaderManager.context(vehicle, isNext)
    if ctx == nil then
        return "none"
    end
    if ADBaleLoaderManager.isValid(ADBaleLoaderManager:get(ctx.field, ctx.toolKey)) then
        return "ok"
    end
    return "todo"
end

-- (hook HudButton) même roue dentée que le semoir et l'épandeur : eux d'abord, sinon la remorque à balles
function ADBaleLoaderManager.hudGear(vehicle, isNext, status, toolTip)
    if status ~= nil and status ~= "none" then
        return status, toolTip
    end
    local ok, s = FarmPilotCall(ADBaleLoaderManager.status, vehicle, isNext)
    s = ok and s or "none"
    if s == "none" then
        return status, toolTip
    end
    return s, isNext and "gui_ad_baleLoader_tooltipNext" or "gui_ad_baleLoader_tooltip"
end

-- { label, field, isNext } si une remorque à balles des lignes Outil / Outil suivant n'est pas réglée pour son champ
function ADBaleLoaderManager.startBlock(vehicle)
    for _, isNext in ipairs({ false, true }) do
        local ctx = ADBaleLoaderManager.context(vehicle, isNext)
        if ctx ~= nil and not ADBaleLoaderManager.isValid(ADBaleLoaderManager:get(ctx.field, ctx.toolKey)) then
            local okL, label = FarmPilotCall(ADAutonomousManager.toolShortLabel, ctx.tool)
            return { label = okL and label or ADAutonomousManager.toolLabel(ctx.tool), field = ctx.field, isNext = isNext }
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ (hook AutonomousMode:start) : refusé tant que ce n'est pas validé
-- ------------------------------------------------------------------------------------------------------------
function ADBaleLoaderManager.checkStart(vehicle)
    local block = ADBaleLoaderManager.startBlock(vehicle)
    if block == nil then
        return false
    end
    log("%s : départ refusé, réglages de « %s » à valider pour « %s »", tostring(vehicle.ad.stateModule:getName()), tostring(block.label), tostring(block.field))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 12000, "AD_autonomous_baleLoaderTodo", tostring(block.label), tostring(block.field))
    if vehicle.ad.stateModule:isActive() then
        vehicle:stopAutoDrive()
    end
    return true
end

-- true = départ refusé (message et log faits)
function ADBaleLoaderManager.refuseStart(mode)
    local ok, refused = FarmPilotCall(ADBaleLoaderManager.checkStart, mode.vehicle)
    if not ok then
        log("ERREUR réglages de la remorque à balles : %s", tostring(refused))
        return false
    end
    return refused == true
end

-- ------------------------------------------------------------------------------------------------------------
-- Sauvegarde (FarmPilot_RemorquesBalles.xml dans la sauvegarde)
-- ------------------------------------------------------------------------------------------------------------
local function savegameFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local path = g_currentMission.missionInfo.savegameDirectory
    if path == nil then
        return nil
    end
    return path .. "/" .. ADBaleLoaderManager.FILE_NAME
end

function ADBaleLoaderManager:loadFromXml()
    if self.loaded then
        return
    end
    self.loaded = true
    self.settings = {}
    local file = savegameFile()
    if file == nil or not fileExists(file) then
        return
    end
    local xml = loadXMLFile("fpRemorquesBalles", file)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while true do
        local key = string.format("farmPilotRemorquesBalles.entry(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local s = {
            field = getXMLString(xml, key .. "#field"),
            tool = getXMLString(xml, key .. "#tool"),
            toolName = getXMLString(xml, key .. "#toolName"),
            wrap = ADBaleLoaderManager.validWrap(getXMLString(xml, key .. "#wrap")),
            deposit = getXMLString(xml, key .. "#deposit"),
            stamp = getXMLInt(xml, key .. "#stamp") or 0
        }
        if s.deposit == "" then
            s.deposit = nil
        end
        if s.field ~= nil and s.tool ~= nil then
            self.settings[ADSeederManager.key(s.field, s.tool)] = s
            self.stamp = math.max(self.stamp, s.stamp)
        end
        i = i + 1
    end
    delete(xml)
    log("%d réglages de remorque à balles chargés", i)
end

function ADBaleLoaderManager:saveToXml()
    if not self.loaded then
        return
    end
    local file = savegameFile()
    if file == nil then
        return
    end
    local xml = createXMLFile("fpRemorquesBalles", file, "farmPilotRemorquesBalles")
    if xml == nil or xml == 0 then
        return
    end
    local keys = {}
    for k, _ in pairs(self.settings) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local s = self.settings[k]
        local key = string.format("farmPilotRemorquesBalles.entry(%d)", i - 1)
        setXMLString(xml, key .. "#field", tostring(s.field))
        setXMLString(xml, key .. "#tool", s.tool)
        setXMLString(xml, key .. "#toolName", s.toolName or "")
        setXMLString(xml, key .. "#wrap", s.wrap or ADBaleLoaderManager.WRAP_ALL)
        setXMLString(xml, key .. "#deposit", s.deposit or "")
        setXMLInt(xml, key .. "#stamp", s.stamp or 0)
    end
    saveXMLFile(xml)
    delete(xml)
end
