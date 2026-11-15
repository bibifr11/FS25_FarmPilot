-- ============================================================================================================
-- FarmPilot : BalerManager.lua
-- Mode Autonome : la presse à balles (09/11).
--
-- Règle :
-- - Une presse ne travaille pas à sa propre largeur : elle ramasse les andains laissés par la machine passée avant
--   (moissonneuse : paille ; andaineur : herbe, foin). Courseplay ne cherche pas les andains, il suit le parcours
--   chargé.
-- - Au champ, au lieu du parcours à la largeur de l'outil, on prend le parcours Courseplay du champ (toutes
--   largeurs) qui tombe le mieux sur les andains au sol : chaque parcours qui couvre le groupe du champ est lu en
--   entier, des points de contrôle sont pris le long de son tracé (au plus MAX_PROBES, tous les PROBE_STEP_MIN m au
--   moins) et on compte ceux qui ont un andain sous eux (hauteur de tas du jeu, produits que la presse ramasse).
--   Le meilleur gagne s'il en touche au moins MIN_SCORE ; sinon arrêt et attente (« noWindrow »).
-- - Courseplay conduit ensuite le parcours choisi et gère la presse (balles, enrubannage, décalage du pick-up).
-- - Le choix n'est pas retenu : les andains changent à chaque récolte, il est refait à chaque arrivée au champ.
-- - (15/11) Ficelle / filet, comme le semoir : roue dentée à gauche de la ligne « Outil » (ou « Outil suivant »), qui
--   ouvre la fenêtre « Réglages de la presse » (BalerSettingsGUI.lua) avec un seul choix : « Zone de recharge
--   (ficelle / filet) » (marqueurs près d'une palette de ficelle ou de filet : RefillSources.lua ; sinon tous).
--   Choix retenu par champ et par presse (FarmPilot_Presses.xml). Tant que ce n'est pas validé, le départ est refusé
--   (roue dentée orange, verte une fois validé). Presse sans ficelle ni filet (consommable du jeu absent) : pas de
--   roue dentée, départ comme avant.
-- - (15/11) La recharge passe par le même chemin que le plein du semoir (AutonomousMode:startRefill / monitorRefill /
--   handleRefillStage, LoadAtDestinationTask) : avant le champ si la ficelle / le filet est sous REFILL_BELOW de la
--   contenance ; quand Courseplay s'arrête faute de ficelle / filet (BalerController : stopCurrentAIJob
--   AIMessageErrorOutOfFill -> événement onCpEmpty), sortie du champ, recharge à la zone, retour, et Courseplay repart
--   au dernier point. Les palettes de ficelle / filet près du marqueur remplissent la cuve du consommable de la presse
--   par leur zone de remplissage (FillTriggerVehicle), comme les big bags du semoir ; « plein » = plus de place dans
--   cette cuve (getFillUnitFreeCapacity du jeu : rouleaux de réserve pleins).
--
-- Branché par : AutonomousManager.lua (choose : presse attelée), AutonomousMode.lua (message « noWindrow » ; une
-- ligne chacun : start -> refuseStart et preparePlan, onCpEmpty -> preparePlan), HudButton.lua (hudGear),
-- AutoDrive.lua (saveToXml), AutonomousResumeStage.lua (étape « refill » : preparePlan). Lu aussi par
-- BalerSettingsGUI.lua et AutonomousBalerRefill.lua.
-- ============================================================================================================

ADBalerManager = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADBalerManager.MAX_PROBES = 300          -- points de contrôle au plus par parcours
ADBalerManager.PROBE_STEP_MIN = 3        -- m entre deux points de contrôle, au moins
ADBalerManager.PROBE_HALF_LENGTH = 0.5   -- m : demi-longueur de la zone regardée sous un point (le long du tracé)
ADBalerManager.PROBE_HALF_WIDTH = 0.75   -- m : demi-largeur (en travers) : un andain fait 1,5 à 2 m de large
ADBalerManager.MIN_SCORE = 0.25          -- part des points sur un andain pour retenir un parcours
ADBalerManager.MAX_WAYPOINTS = 20000     -- garde-fou : points lus par fichier de parcours
-- produits d'andain si la presse ne dit pas ce qu'elle ramasse
ADBalerManager.FALLBACK_FILLTYPES = { "STRAW", "GRASS_WINDROW", "DRYGRASS_WINDROW" }
-- (15/11) ficelle / filet : zone de recharge, comme le semoir
ADBalerManager.FILE_NAME = "FarmPilot_Presses.xml"
ADBalerManager.settings = {}   -- [nom du champ .. "|" .. clé de la presse] = { field, tool, toolName, refill, stamp }
ADBalerManager.loaded = false
ADBalerManager.stamp = 0
ADBalerManager.REFILL_BELOW = 0.20     -- part de la contenance (rouleaux) sous laquelle il recharge avant d'aller au champ
ADBalerManager.FULL_MARGIN = 0.01      -- rouleau : place libre plus petite = plein
-- consommables de la presse (Baler.CONSUMABLE_TYPE_NAME_ROUND / _SQUARE du jeu) : filet (balles rondes), ficelle
ADBalerManager.CONSUMABLE_TYPES = { "BALE_NET", "BALE_TWINE" }

local function log(fmt, ...)
    local ok, s = FarmPilotCall(string.format, fmt, ...)
    print("[FarmPilot Presse] " .. (ok and s or tostring(fmt)))
end
ADBalerManager.log = log

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

-- ------------------------------------------------------------------------------------------------------------
-- La presse attelée (ou automotrice)
-- ------------------------------------------------------------------------------------------------------------
local function findBaler(object, depth)
    if object == nil or depth > 6 then
        return nil
    end
    if object.spec_baler ~= nil then
        return object
    end
    if object.getAttachedImplements == nil then
        return nil
    end
    local ok, implements = FarmPilotCall(object.getAttachedImplements, object)
    if not ok or type(implements) ~= "table" then
        return nil
    end
    for _, impl in ipairs(implements) do
        local b = findBaler(impl.object, depth + 1)
        if b ~= nil then
            return b
        end
    end
    return nil
end

function ADBalerManager.baler(vehicle)
    return findBaler(vehicle, 0)
end

-- produits d'andain que la presse ramasse (seulement ceux qui peuvent être au sol en tas)
function ADBalerManager.windrowTypes(baler)
    local list, seen = {}, {}
    local hm = g_densityMapHeightManager
    local function add(ft)
        if ft ~= nil and not seen[ft] and (hm == nil or hm.getDensityMapHeightTypeByFillTypeIndex == nil
            or hm:getDensityMapHeightTypeByFillTypeIndex(ft) ~= nil) then
            seen[ft] = true
            list[#list + 1] = ft
        end
    end
    local spec = baler ~= nil and baler.spec_baler or nil
    if spec ~= nil and spec.fillUnitIndex ~= nil and baler.getFillUnitSupportedFillTypes ~= nil then
        local ok, types = FarmPilotCall(baler.getFillUnitSupportedFillTypes, baler, spec.fillUnitIndex)
        if ok and type(types) == "table" then
            for ft, supported in pairs(types) do
                if supported then
                    add(ft)
                end
            end
        end
    end
    if #list == 0 and g_fillTypeManager ~= nil then
        for _, name in ipairs(ADBalerManager.FALLBACK_FILLTYPES) do
            add(g_fillTypeManager:getFillTypeIndexByName(name))
        end
    end
    table.sort(list)
    return list
end

-- ------------------------------------------------------------------------------------------------------------
-- Andains au sol
-- ------------------------------------------------------------------------------------------------------------
-- true si un andain (un des produits) est sous le point x, z ; dx, dz = sens du tracé (unitaire)
function ADBalerManager.hasWindrow(x, z, dx, dz, types)
    if DensityMapHeightUtil == nil or DensityMapHeightUtil.getFillLevelAtArea == nil then
        return false
    end
    local hl, hw = ADBalerManager.PROBE_HALF_LENGTH, ADBalerManager.PROBE_HALF_WIDTH
    local px, pz = -dz, dx   -- en travers
    local sx, sz = x - dx * hl - px * hw, z - dz * hl - pz * hw
    local wx, wz = sx + px * 2 * hw, sz + pz * 2 * hw
    local hx, hz = sx + dx * 2 * hl, sz + dz * 2 * hl
    for _, ft in ipairs(types) do
        local ok, level = FarmPilotCall(DensityMapHeightUtil.getFillLevelAtArea, ft, sx, sz, wx, wz, hx, hz)
        if ok and level ~= nil and level > 0 then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Tracé complet d'un parcours Courseplay
-- ------------------------------------------------------------------------------------------------------------
-- tous les points du fichier (x, z), dans l'ordre
function ADBalerManager.readLine(path)
    if path == nil or not fileExists(path) then
        return nil
    end
    local xml = loadXMLFile("fpCpBalerCourse", path)
    if xml == nil or xml == 0 then
        return nil
    end
    local pts = {}
    local base = "Courses.Course(0)"
    local i = 0
    while i < ADBalerManager.MAX_WAYPOINTS do
        local key = string.format("%s.wp(%d)", base, i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local pos = getXMLString(xml, key .. "#position")
        if pos ~= nil then
            local x, _, z = pos:match("^%s*(%S+)%s+(%S+)%s+(%S+)")
            x, z = tonumber(x), tonumber(z)
            if x ~= nil and z ~= nil then
                pts[#pts + 1] = { x, z }
            end
        end
        i = i + 1
    end
    delete(xml)
    return pts
end

-- part du tracé posée sur un andain : touchés, contrôlés
function ADBalerManager.score(pts, types)
    if pts == nil or #pts < 2 then
        return 0, 0
    end
    local total = 0
    for i = 2, #pts do
        total = total + MathUtil.vector2Length(pts[i][1] - pts[i - 1][1], pts[i][2] - pts[i - 1][2])
    end
    if total <= 0 then
        return 0, 0
    end
    local step = math.max(ADBalerManager.PROBE_STEP_MIN, total / ADBalerManager.MAX_PROBES)
    local hits, probes = 0, 0
    local nextAt = step / 2
    local done = 0
    for i = 2, #pts do
        local ax, az, bx, bz = pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2]
        local len = MathUtil.vector2Length(bx - ax, bz - az)
        if len > 0 then
            local dx, dz = (bx - ax) / len, (bz - az) / len
            while nextAt <= done + len do
                local t = nextAt - done
                probes = probes + 1
                if ADBalerManager.hasWindrow(ax + dx * t, az + dz * t, dx, dz, types) then
                    hits = hits + 1
                end
                nextAt = nextAt + step
            end
            done = done + len
        end
    end
    return hits, probes
end

-- ------------------------------------------------------------------------------------------------------------
-- Choix du parcours (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
-- courses : liste de listCourses ; g : groupe du champ (groupOf). Renvoie e, ou nil + "noWindrow".
function ADBalerManager.choose(vehicle, courses, g)
    local baler = ADBalerManager.baler(vehicle)
    local types = ADBalerManager.windrowTypes(baler)
    local names = {}
    for _, ft in ipairs(types) do
        names[#names + 1] = g_fillTypeManager ~= nil and tostring(g_fillTypeManager:getFillTypeNameByIndex(ft)) or tostring(ft)
    end
    log("presse : recherche des andains (%s) sur le groupe %s", table.concat(names, ", "), tostring(g ~= nil and g.key or "?"))
    if g == nil or #types == 0 then
        return nil, "noWindrow"
    end
    local best, bestScore, tested = nil, 0, 0
    for _, e in ipairs(courses or {}) do
        if e.groupKeys ~= nil and e.groupKeys[g.key] then
            local okR, pts = FarmPilotCall(ADBalerManager.readLine, e.path)
            if okR and pts ~= nil then
                local hits, probes = ADBalerManager.score(pts, types)
                local s = probes > 0 and hits / probes or 0
                tested = tested + 1
                log("  parcours « %s » (%s m) : %d / %d points sur un andain (%.0f %%)", ADAutonomousManager.courseLabel(e),
                    tostring(e.w), hits, probes, s * 100)
                if s > bestScore then
                    best, bestScore = e, s
                end
            end
        end
    end
    if best ~= nil and bestScore >= ADBalerManager.MIN_SCORE then
        log("presse : parcours « %s » retenu (%.0f %% sur les andains, %d parcours regardés)", ADAutonomousManager.courseLabel(best),
            bestScore * 100, tested)
        return best
    end
    log("presse : aucun parcours ne tombe sur les andains (%d parcours regardés, meilleur %.0f %%)", tested, bestScore * 100)
    return nil, "noWindrow"
end

-- ============================================================================================================
-- (15/11) Ficelle / filet : zone de recharge, comme le semoir
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- La ficelle / le filet de la presse (consommable du jeu : spec_consumable)
-- ------------------------------------------------------------------------------------------------------------
-- noms des consommables de la presse : ceux du jeu (Baler) d'abord, puis la liste connue
function ADBalerManager.consumableTypeNames()
    local out, seen = {}, {}
    local function add(n)
        if type(n) == "string" and n ~= "" and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    if Baler ~= nil then
        add(Baler.CONSUMABLE_TYPE_NAME_ROUND)
        add(Baler.CONSUMABLE_TYPE_NAME_SQUARE)
    end
    for _, n in ipairs(ADBalerManager.CONSUMABLE_TYPES) do
        add(n)
    end
    return out
end

-- produit de la cuve du consommable : celui du nom du consommable s'il y est accepté, sinon le premier accepté
local function consumableFillType(tool, unit, typeName)
    local ft = g_fillTypeManager ~= nil and safe(g_fillTypeManager.getFillTypeIndexByName, g_fillTypeManager, typeName) or nil
    local supported = safe(tool.getFillUnitSupportedFillTypes, tool, unit)
    if type(supported) ~= "table" or (ft ~= nil and supported[ft]) then
        return ft
    end
    local first = safe(tool.getFillUnitFirstSupportedFillType, tool, unit)
    if first ~= nil then
        return first
    end
    for idx, ok in pairs(supported) do
        if ok then
            return idx
        end
    end
    return ft
end

-- { typeName, fillUnit, fillType, stored, consuming, level, capacity, free, available } en rouleaux, ou nil si la
-- presse ne prend ni ficelle ni filet. stored = rouleaux de réserve (niveau de la cuve), consuming = rouleau(x) en
-- cours, capacity = réserve + en cours (Consumable:onLoad), free = place dans la cuve (getFillUnitFreeCapacity du
-- jeu : seulement la réserve quand un rouleau est en cours), available = getConsumableIsAvailable du jeu.
function ADBalerManager.consumable(tool)
    if tool == nil or tool.spec_baler == nil then
        return nil
    end
    local spec = tool.spec_consumable
    if spec == nil or type(spec.typesByName) ~= "table" then
        return nil
    end
    for _, name in ipairs(ADBalerManager.consumableTypeNames()) do
        local t = spec.typesByName[name]
        if type(t) == "table" and type(t.fillUnitIndex) == "number" then
            local unit = t.fillUnitIndex
            local nCons = tonumber(t.numConsumingSlots) or 0
            local nStore = tonumber(t.numStorageSlots) or 0
            local cLevel = tonumber(t.consumingFillLevel) or 0
            local stored = tonumber(safe(tool.getFillUnitFillLevel, tool, unit)) or 0
            local capacity = nStore + nCons
            if capacity <= 0 then
                capacity = tonumber(safe(tool.getFillUnitCapacity, tool, unit)) or 0
            end
            local consuming = cLevel * nCons
            local free = tonumber(safe(tool.getFillUnitFreeCapacity, tool, unit))
            if free == nil then
                free = capacity - stored - consuming
            end
            local available = safe(tool.getConsumableIsAvailable, tool, name)
            if available == nil then
                available = cLevel > 0
            end
            return {
                typeName = name, fillUnit = unit, fillType = consumableFillType(tool, unit, name), stored = stored,
                consuming = consuming, level = stored + consuming, capacity = capacity, free = math.max(0, free),
                available = available == true
            }
        end
    end
    return nil
end

function ADBalerManager.isFull(info)
    return info ~= nil and info.free <= ADBalerManager.FULL_MARGIN
end

-- « BALE_TWINE 0,40 / 30 rouleaux (place 24,00) » pour le log
function ADBalerManager.levelText(info)
    if info == nil then
        return "ni ficelle ni filet"
    end
    return string.format("%s %.2f / %.0f rouleaux (place %.2f)", tostring(info.typeName), info.level, info.capacity, info.free)
end

-- ------------------------------------------------------------------------------------------------------------
-- Quelle presse, quel champ (lignes « Outil » et « Champ » du HUD)
-- ------------------------------------------------------------------------------------------------------------
-- presse qui prend de la ficelle ou du filet
function ADBalerManager.isBaler(tool)
    return tool ~= nil and tool.spec_baler ~= nil and not tool.isDeleted and not tool.isDeleting and ADBalerManager.consumable(tool) ~= nil
end

-- presse de ce véhicule : la machine elle-même (automotrice), sinon l'outil attelé
function ADBalerManager.attachedBaler(vehicle)
    if vehicle == nil then
        return nil
    end
    if ADBalerManager.isBaler(vehicle) then
        return vehicle
    end
    local okT, tools = FarmPilotCall(ADAutonomousManager.workTools, vehicle)
    for _, t in ipairs(okT and tools or {}) do
        if ADBalerManager.isBaler(t) then
            return t
        end
    end
    local b = ADBalerManager.baler(vehicle)
    if ADBalerManager.isBaler(b) then
        return b
    end
    return nil
end

-- outil de la ligne « Outil » (ou « Outil suivant ») : celui choisi si c'est une presse, sinon celle attelée
function ADBalerManager.rowTool(vehicle, isNext)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil then
        return nil
    end
    if isNext and sm.getFpNextTool ~= nil then
        local nextTool = sm:getFpNextTool()
        if nextTool ~= nil then
            return ADBalerManager.isBaler(nextTool) and nextTool or nil
        end
    end
    local tool = sm.getFpTool ~= nil and sm:getFpTool() or nil
    if tool ~= nil then
        return ADBalerManager.isBaler(tool) and tool or nil
    end
    return ADBalerManager.attachedBaler(vehicle)
end

function ADBalerManager.isAttached(tool, vehicle)
    return tool ~= nil and (tool == vehicle or ADSeederManager.attachedTo(tool, vehicle))
end

-- { tool, toolKey, field (nom du marqueur), marker, vehicle } si la ligne a une presse à ficelle / filet et un
-- champ ; sinon nil
function ADBalerManager.context(vehicle, isNext)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil then
        return nil
    end
    if vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return nil
    end
    local tool = ADBalerManager.rowTool(vehicle, isNext)
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
-- Mémoire champ + presse
-- ------------------------------------------------------------------------------------------------------------
function ADBalerManager:get(field, toolKey)
    self:loadFromXml()
    return self.settings[ADSeederManager.key(field, toolKey)]
end

-- derniers réglages de cette presse (n'importe quel champ), pour préremplir la fenêtre
function ADBalerManager:lastFor(toolKey)
    self:loadFromXml()
    local best = nil
    for _, s in pairs(self.settings) do
        if s.tool == toolKey and (best == nil or (s.stamp or 0) > (best.stamp or 0)) then
            best = s
        end
    end
    return best
end

function ADBalerManager:set(field, tool, s)
    self:loadFromXml()
    self.stamp = self.stamp + 1
    local toolKey = ADSeederManager.toolKey(tool)
    local entry = { field = field, tool = toolKey, toolName = ADAutonomousManager.toolLabel(tool), refill = s.refill, stamp = self.stamp }
    self.settings[ADSeederManager.key(field, toolKey)] = entry
    log("« %s », presse %s : zone de recharge (ficelle / filet) « %s »", tostring(field), toolKey, tostring(entry.refill))
    return entry
end

-- ce qui manque : nil si c'est bon, sinon « none » ou « refill » (zone absente ou effacée)
function ADBalerManager.missing(s)
    if s == nil then
        return "none"
    end
    if s.refill == nil or ADGraphManager:getMapMarkerByName(s.refill) == nil then
        return "refill"
    end
    return nil
end

function ADBalerManager.isValid(s)
    return ADBalerManager.missing(s) == nil
end

-- roue dentée : « none » (pas de presse à ficelle / filet sur la ligne), « ok » (validé), « todo » (à régler)
function ADBalerManager.status(vehicle, isNext)
    local ctx = ADBalerManager.context(vehicle, isNext)
    if ctx == nil then
        return "none"
    end
    if ADBalerManager.isValid(ADBalerManager:get(ctx.field, ctx.toolKey)) then
        return "ok"
    end
    return "todo"
end

-- (hook HudButton) même roue dentée que le semoir, l'épandeur et la remorque à balles : eux d'abord, sinon la presse
function ADBalerManager.hudGear(vehicle, isNext, status, toolTip)
    if status ~= nil and status ~= "none" then
        return status, toolTip
    end
    local ok, s = FarmPilotCall(ADBalerManager.status, vehicle, isNext)
    s = ok and s or "none"
    if s == "none" then
        return status, toolTip
    end
    return s, isNext and "gui_ad_baler_tooltipNext" or "gui_ad_baler_tooltip"
end

-- { label, field, isNext } si une presse des lignes Outil / Outil suivant n'est pas réglée pour son champ
function ADBalerManager.startBlock(vehicle)
    for _, isNext in ipairs({ false, true }) do
        local ctx = ADBalerManager.context(vehicle, isNext)
        if ctx ~= nil and not ADBalerManager.isValid(ADBalerManager:get(ctx.field, ctx.toolKey)) then
            local okL, label = FarmPilotCall(ADAutonomousManager.toolShortLabel, ctx.tool)
            return { label = okL and label or ADAutonomousManager.toolLabel(ctx.tool), field = ctx.field, isNext = isNext }
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ (hook AutonomousMode:start) : refusé tant que ce n'est pas validé
-- ------------------------------------------------------------------------------------------------------------
function ADBalerManager.checkStart(vehicle)
    local block = ADBalerManager.startBlock(vehicle)
    if block == nil then
        return false
    end
    log("%s : départ refusé, zone de recharge de la presse « %s » à valider pour « %s »", tostring(vehicle.ad.stateModule:getName()),
        tostring(block.label), tostring(block.field))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 12000, "AD_autonomous_balerTodo", tostring(block.label), tostring(block.field))
    if vehicle.ad.stateModule:isActive() then
        vehicle:stopAutoDrive()
    end
    return true
end

-- true = départ refusé (message et log faits)
function ADBalerManager.refuseStart(mode)
    local ok, refused = FarmPilotCall(ADBalerManager.checkStart, mode.vehicle)
    if not ok then
        log("ERREUR réglages de la presse : %s", tostring(refused))
        return false
    end
    return refused == true
end

-- ------------------------------------------------------------------------------------------------------------
-- Plan de recharge (hooks AutonomousMode:start, onCpEmpty, AutonomousResumeStage « refill ») : même forme que le
-- plan du semoir
-- ------------------------------------------------------------------------------------------------------------
-- Courseplay : plus de ficelle / filet = il s'arrête et le signale (onCpEmpty), au lieu d'attendre sur place
function ADBalerManager.applyCpSettings(vehicle)
    if vehicle.getCpSettings == nil then
        return
    end
    local okS, settings = FarmPilotCall(vehicle.getCpSettings, vehicle)
    local refill = okS and settings ~= nil and settings.refillOnTheField or nil
    if refill ~= nil and refill.getValue ~= nil and refill:getValue() ~= 0 then
        FarmPilotCall(refill.setValue, refill, 0)
        log("Courseplay : « plein dans le champ » remis sur désactivé (FarmPilot va recharger la presse à la zone)")
    end
end

-- after = « field » (départ : recharge sous REFILL_BELOW) ou « back » (Courseplay arrêté : recharge si pas plein) ;
-- renvoie { kind, tool, settings, marker, fillTypes, field, needsFill, fillUnit, consumable, levelBefore, fillKey,
-- emptyKey } ou nil (pas de presse réglée attelée)
function ADBalerManager.plan(vehicle, after)
    local ctx = ADBalerManager.context(vehicle, false)
    if ctx == nil or not ADBalerManager.isAttached(ctx.tool, vehicle) then
        return nil
    end
    local s = ADBalerManager:get(ctx.field, ctx.toolKey)
    if not ADBalerManager.isValid(s) then
        return nil
    end
    local info = ADBalerManager.consumable(ctx.tool)
    if info == nil or info.fillType == nil then
        return nil
    end
    FarmPilotCall(ADBalerManager.applyCpSettings, vehicle)
    local name = tostring(vehicle.ad.stateModule:getName())
    local full = ADBalerManager.isFull(info)
    local needsFill
    if after == "back" then
        needsFill = not full
        if needsFill then
            log("%s : presse « %s » : %s (%s) : recharge à « %s », puis retour au champ", name, ADAutonomousManager.toolLabel(ctx.tool),
                info.available and "ficelle / filet pas plein" or "plus de ficelle / filet (vide)", ADBalerManager.levelText(info), tostring(s.refill))
        else
            log("%s : presse « %s » : ficelle / filet plein (%s) : pas de recharge", name, ADAutonomousManager.toolLabel(ctx.tool), ADBalerManager.levelText(info))
        end
    else
        needsFill = not full and (not info.available or info.level < info.capacity * ADBalerManager.REFILL_BELOW)
        if needsFill then
            log("%s : presse « %s » : ficelle / filet presque vide (%s, recharge sous %.0f %%) : recharge à « %s » avant le champ", name,
                ADAutonomousManager.toolLabel(ctx.tool), ADBalerManager.levelText(info), ADBalerManager.REFILL_BELOW * 100, tostring(s.refill))
        end
    end
    local ftName = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeNameByIndex(info.fillType) or nil
    return {
        kind = "baler", tool = ctx.tool, settings = { fillTypes = { tostring(ftName or info.typeName) } },
        marker = ADGraphManager:getMapMarkerByName(s.refill), fillTypes = { info.fillType }, field = ctx.field,
        needsFill = needsFill, fillUnit = info.fillUnit, consumable = info.typeName, levelBefore = info.level,
        fillKey = "AD_autonomous_balerFill", emptyKey = "AD_autonomous_balerEmpty"
    }
end

function ADBalerManager.preparePlan(vehicle, after)
    local ok, plan = FarmPilotCall(ADBalerManager.plan, vehicle, after or "field")
    if not ok then
        log("ERREUR plan de recharge : %s", tostring(plan))
        return nil
    end
    return plan
end

-- ------------------------------------------------------------------------------------------------------------
-- Sauvegarde (FarmPilot_Presses.xml dans la sauvegarde)
-- ------------------------------------------------------------------------------------------------------------
local function savegameFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local path = g_currentMission.missionInfo.savegameDirectory
    if path == nil then
        return nil
    end
    return path .. "/" .. ADBalerManager.FILE_NAME
end

function ADBalerManager:loadFromXml()
    if self.loaded then
        return
    end
    self.loaded = true
    self.settings = {}
    local file = savegameFile()
    if file == nil or not fileExists(file) then
        return
    end
    local xml = loadXMLFile("fpPresses", file)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while true do
        local key = string.format("farmPilotPresses.entry(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local s = {
            field = getXMLString(xml, key .. "#field"),
            tool = getXMLString(xml, key .. "#tool"),
            toolName = getXMLString(xml, key .. "#toolName"),
            refill = getXMLString(xml, key .. "#refill"),
            stamp = getXMLInt(xml, key .. "#stamp") or 0
        }
        if s.refill == "" then
            s.refill = nil
        end
        if s.field ~= nil and s.tool ~= nil then
            self.settings[ADSeederManager.key(s.field, s.tool)] = s
            self.stamp = math.max(self.stamp, s.stamp)
        end
        i = i + 1
    end
    delete(xml)
    log("%d réglages de presse chargés", i)
end

function ADBalerManager:saveToXml()
    if not self.loaded then
        return
    end
    local file = savegameFile()
    if file == nil then
        return
    end
    local xml = createXMLFile("fpPresses", file, "farmPilotPresses")
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
        local key = string.format("farmPilotPresses.entry(%d)", i - 1)
        setXMLString(xml, key .. "#field", tostring(s.field))
        setXMLString(xml, key .. "#tool", s.tool)
        setXMLString(xml, key .. "#toolName", s.toolName or "")
        setXMLString(xml, key .. "#refill", s.refill or "")
        setXMLInt(xml, key .. "#stamp", s.stamp or 0)
    end
    saveXMLFile(xml)
    delete(xml)
end
