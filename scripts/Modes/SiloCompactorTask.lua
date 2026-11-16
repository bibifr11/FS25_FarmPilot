-- ============================================================================================================
-- FarmPilot : SiloCompactorTask.lua
-- Tasseur de silo couloir (16/11) : fenêtre « Tassage » (Gui/SiloCompactGUI.lua), réglages du tracteur, travail
-- dans le silo, lame et rouleau, reprise au chargement de la partie.
--
-- Lancement : mode « Tassage » du HUD (bouton de mode, après « Autonome », Hud/HudSilo.lua) : 1re ligne = silo
-- (tous les silos de la carte), 2e ligne = attente, roue dentée = fenêtre des réglages ; On/Off ou Démarrer de la
-- fenêtre. Lancé de n'importe où : le tracteur va seul au silo par le réseau (marqueur dans le silo, sinon point du
-- réseau le plus proche de l'entrée), puis tasse. Arrêt : On/Off ou bouton Arrêter de la fenêtre.
-- Ancien lancement gardé : « Conduire vers » un marqueur dans le silo, tracteur sans benne.
--
-- Réglages (par tracteur, gardés dans la sauvegarde) :
-- - Entrée dans le silo : marche avant (aller en avant, retour en arrière) ou marche arrière (l'inverse) ;
-- - Largeur de travail : Auto (le plus large du tracteur et de ses outils) ou 2 à 6 m ;
-- - Hauteur de la lame au-dessus du tas : 0 à 0,5 m (lame à vérins réglables seulement) ;
-- - Attente quand une benne arrive : sur le côté de l'entrée, ou à un marqueur choisi ;
-- - À 100 % de tassage : continuer (attend et reprend si le silo se remplit) ou s'arrêter. Message dans les deux cas.
--
-- Travail :
-- - silo à fond : entrée par le bout ouvert, aller jusqu'à END_MARGIN m du mur (outil compris) ; silo traversant :
--   entrée par le bout le plus proche, aller jusqu'au bout ;
-- - couloirs côte à côte de la largeur de travail (recouvrement 20 %), le premier = le plus proche du tracteur ;
-- - aller : lame ou rouleau baissé (lame tenue à sa hauteur), retour : outil levé ;
-- - bloqué STUCK_TIME sur le tas : bout du couloir pris comme atteint ; benne à moins de APPROACH m : il sort tout
--   droit puis va à sa place d'attente ; benne repartie : il reprend le couloir où il en était.
-- Enveloppes posées au chargement : DriveToMode:start, :handleFinishedTask, :reset ; ADSavegameResume.save / load.
-- Mode « Tassage » (AutoDrive.MODE_COMPACT) : CompactMode, voir SiloCompactMode.lua.
-- Une ligne dans Specialization.lua (AutoDrive:stopAutoDrive -> ADSiloJob.onStop).
-- ============================================================================================================

ADSiloJob = {}

ADSiloJob.GEAR_RANGE = 300              -- m, roue dentée visible si un silo est à cette distance
ADSiloJob.NEAR_START = 40               -- m du silo : tasse sans trajet
ADSiloJob.ENTRY_WP_RANGE = 60           -- m, point du réseau accepté devant l'entrée
ADSiloJob.WAIT_MARKER_RANGE = 150       -- m, marqueur d'attente accepté autour du silo
ADSiloJob.WIDTHS = { 0, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6 }
ADSiloJob.BLADES = { 0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5 }
ADSiloJob.DIR_FORWARD = 1
ADSiloJob.DIR_REVERSE = 2
ADSiloJob.WAIT_SIDE = 1
ADSiloJob.WAIT_MARKER = 2
-- travail de la lame : auto (pousser si silo à fond, sinon tasser), pousser contre le fond, tasser sans pousser
ADSiloJob.PUSH_AUTO = 0
ADSiloJob.PUSH_WALL = 1
ADSiloJob.PUSH_NONE = 2

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
-- Réglages du tracteur : « dir;largeur;lame;arret;attente;marqueur;pousser;silo » (silo = « x:z » du centre)
-- ------------------------------------------------------------------------------------------------------------
function ADSiloJob.defaultCfg()
    return { dir = ADSiloJob.DIR_FORWARD, width = 0, blade = 0, stop = false, wait = ADSiloJob.WAIT_SIDE, marker = nil, push = ADSiloJob.PUSH_AUTO, sx = nil, sz = nil }
end

function ADSiloJob.cfgToText(cfg)
    local marker = cfg.marker ~= nil and string.gsub(cfg.marker, ";", ",") or ""
    local silo = cfg.sx ~= nil and cfg.sz ~= nil and string.format("%.2f:%.2f", cfg.sx, cfg.sz) or ""
    return string.format("%d;%.2f;%.2f;%d;%d;%s;%d;%s", cfg.dir, cfg.width, cfg.blade, cfg.stop and 1 or 0, cfg.wait, marker, cfg.push or 0, silo)
end

function ADSiloJob.textToCfg(text)
    local cfg = ADSiloJob.defaultCfg()
    if type(text) ~= "string" or text == "" then
        return cfg
    end
    local parts = {}
    for p in string.gmatch(text .. ";", "([^;]*);") do
        table.insert(parts, p)
    end
    cfg.dir = tonumber(parts[1]) == ADSiloJob.DIR_REVERSE and ADSiloJob.DIR_REVERSE or ADSiloJob.DIR_FORWARD
    cfg.width = math.max(0, math.min(6, tonumber(parts[2]) or 0))
    cfg.blade = math.max(0, math.min(0.5, tonumber(parts[3]) or 0))
    cfg.stop = tonumber(parts[4]) == 1
    cfg.wait = tonumber(parts[5]) == ADSiloJob.WAIT_MARKER and ADSiloJob.WAIT_MARKER or ADSiloJob.WAIT_SIDE
    cfg.marker = parts[6] ~= nil and parts[6] ~= "" and parts[6] or nil
    local push = tonumber(parts[7])
    cfg.push = (push == ADSiloJob.PUSH_WALL or push == ADSiloJob.PUSH_NONE) and push or ADSiloJob.PUSH_AUTO
    local sx, sz = string.match(parts[8] or "", "^([%-%d%.]+):([%-%d%.]+)$")
    cfg.sx, cfg.sz = tonumber(sx), tonumber(sz)
    return cfg
end

function ADSiloJob.getCfg(vehicle)
    if vehicle.ad.fpSiloCfg == nil then
        local sm = vehicle.ad.stateModule
        vehicle.ad.fpSiloCfg = ADSiloJob.textToCfg(sm ~= nil and sm.fpSiloCfgText or nil)
    end
    return vehicle.ad.fpSiloCfg
end

function ADSiloJob.setCfg(vehicle, cfg)
    vehicle.ad.fpSiloCfg = cfg
end

-- ------------------------------------------------------------------------------------------------------------
-- Silos
-- ------------------------------------------------------------------------------------------------------------
function ADSiloJob.center(silo)
    local g = ADSiloCompactor.getGeometry(silo)
    if g == nil then
        return nil
    end
    local p = ADSiloCompactor.point(g, g.width / 2, g.length / 2)
    return p.x, p.z
end

function ADSiloJob.findSilo(x, z)
    if x == nil or z == nil or ADTriggerManager == nil then
        return nil
    end
    for _, silo in pairs(ADTriggerManager.getBunkerSilos()) do
        local cx, cz = ADSiloJob.center(silo)
        if cx ~= nil and MathUtil.vector2Length(cx - x, cz - z) < 1 then
            return silo
        end
    end
    return nil
end

-- numéro du silo sur la carte (silos rangés d'ouest en est puis du nord au sud, toujours le même)
function ADSiloJob.siloNumber(silo)
    local list = {}
    for _, s in pairs(ADTriggerManager ~= nil and ADTriggerManager.getBunkerSilos() or {}) do
        local x, z = ADSiloJob.center(s)
        if x ~= nil then
            table.insert(list, { silo = s, x = x, z = z })
        end
    end
    table.sort(list, function(a, b)
        if math.abs(a.x - b.x) > 1 then
            return a.x < b.x
        end
        return a.z < b.z
    end)
    for i, e in ipairs(list) do
        if e.silo == silo then
            return i
        end
    end
    return 0
end

-- silo choisi dans le HUD (réglage du tracteur), ou nil
function ADSiloJob.selectedSilo(vehicle)
    local cfg = ADSiloJob.getCfg(vehicle)
    return ADSiloJob.findSilo(cfg.sx, cfg.sz)
end

function ADSiloJob.selectSilo(vehicle, silo)
    local cfg = ADSiloJob.getCfg(vehicle)
    if silo ~= nil then
        cfg.sx, cfg.sz = ADSiloJob.center(silo)
    else
        cfg.sx, cfg.sz = nil, nil
    end
end

-- silos par distance au tracteur : { { silo, g, dist }, ... }
function ADSiloJob.silosNear(vehicle, range)
    local list = {}
    if ADTriggerManager == nil then
        return list
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    for _, silo in pairs(ADTriggerManager.getBunkerSilos()) do
        local g = ADSiloCompactor.getGeometry(silo)
        if g ~= nil then
            local d = ADSiloCompactor.distanceTo(g, x, z)
            if range == nil or d <= range then
                table.insert(list, { silo = silo, g = g, dist = d })
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

-- marqueur de la carte dans le silo (le premier trouvé) : id du point
function ADSiloJob.markerInSilo(silo)
    local g = ADSiloCompactor.getGeometry(silo)
    if g == nil then
        return nil
    end
    for _, m in pairs(ADGraphManager:getMapMarkers()) do
        local wp = m ~= nil and ADGraphManager:getWayPointById(m.id) or nil
        if wp ~= nil and ADSiloCompactor.distanceTo(g, wp.x, wp.z) <= 0 then
            return m.id
        end
    end
    return nil
end

-- point du réseau le plus proche de l'entrée (bout ouvert, ou le plus proche du tracteur pour un traversant)
function ADSiloJob.entryWayPoint(vehicle, silo)
    local g0 = ADSiloCompactor.getGeometry(silo)
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local _, along = ADSiloCompactor.toLocal(g0, x, z)
    local g = ADSiloCompactor.getEntryGeometry(silo, along > g0.length / 2)
    local entry = ADSiloCompactor.point(g, g.width / 2, -5)
    local best, bestD = nil, ADSiloJob.ENTRY_WP_RANGE
    for id, wp in pairs(ADGraphManager:getWayPoints()) do
        if wp ~= nil and wp.x ~= nil then
            local d = MathUtil.vector2Length(wp.x - entry.x, wp.z - entry.z)
            if d < bestD then
                best, bestD = wp.id or id, d
            end
        end
    end
    return best
end

function ADSiloJob.markerPoint(name)
    if name == nil then
        return nil
    end
    local m = ADGraphManager:getMapMarkerByName(name)
    local wp = m ~= nil and ADGraphManager:getWayPointById(m.id) or nil
    if wp == nil then
        return nil
    end
    return { x = wp.x, y = wp.y, z = wp.z }
end

-- ------------------------------------------------------------------------------------------------------------
-- Lame et rouleau
-- ------------------------------------------------------------------------------------------------------------
ADSiloTools = {}
ADSiloTools.BLADE_BAND = 0.05           -- m, la lame ne bouge pas à moins de 5 cm de sa hauteur
ADSiloTools.BLADE_STEP = 0.03           -- pas de réglage des vérins par contrôle

function ADSiloTools.list(vehicle)
    local tools = {}
    for _, imp in pairs(AutoDrive.getAllImplements(vehicle, false) or {}) do
        if imp ~= vehicle and (imp.spec_leveler ~= nil or imp.spec_bunkerSiloCompacter ~= nil) then
            table.insert(tools, imp)
        end
    end
    return tools
end

function ADSiloTools.hasBlade(vehicle)
    for _, t in ipairs(ADSiloTools.list(vehicle)) do
        if t.spec_leveler ~= nil then
            return true
        end
    end
    return false
end

-- longueur de l'attelage devant (front) ou derrière la racine du tracteur
function ADSiloTools.overhang(vehicle, front)
    local half = (vehicle.size ~= nil and vehicle.size.length or 6) / 2
    local extra = 0
    for _, imp in pairs(AutoDrive.getAllImplements(vehicle, false) or {}) do
        if imp ~= vehicle and imp.components ~= nil and imp.size ~= nil then
            local ix, iy, iz = getWorldTranslation(imp.components[1].node)
            local _, _, lz = AutoDrive.worldToLocal(vehicle, ix, iy, iz)
            if (front and lz > 0) or (not front and lz < 0) then
                extra = math.max(extra, math.abs(lz) - half + (imp.size.length or 0) / 2)
            end
        end
    end
    return half + math.max(0, extra)
end

-- largeur de travail : réglage, sinon le plus large du tracteur et de ses outils
function ADSiloTools.workWidth(vehicle, cfg)
    if cfg ~= nil and cfg.width ~= nil and cfg.width > 0 then
        return cfg.width
    end
    local w = vehicle.size ~= nil and vehicle.size.width or 3
    for _, t in ipairs(ADSiloTools.list(vehicle)) do
        if t.size ~= nil and t.size.width ~= nil then
            w = math.max(w, t.size.width)
        end
    end
    return w
end

local function setDown(tool, down)
    local done = false
    if down and tool.aiImplementStartLine ~= nil then
        done = FarmPilotCall(tool.aiImplementStartLine, tool) -- baissé (et en route) comme par l'ouvrier du jeu
    elseif not down and tool.aiImplementEndLine ~= nil then
        done = FarmPilotCall(tool.aiImplementEndLine, tool)
    end
    local attacher = tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() or nil
    if attacher ~= nil and attacher.getAttacherJointIndexFromObject ~= nil and attacher.setJointMoveDown ~= nil then
        local okI, index = FarmPilotCall(attacher.getAttacherJointIndexFromObject, attacher, tool)
        if okI and index ~= nil then
            FarmPilotCall(attacher.setJointMoveDown, attacher, index, down)
            done = true
        end
    end
    return done
end

-- bladeUp : la lame reste levée (tasser sans pousser), seul le rouleau descend
function ADSiloTools.lower(vehicle, down, bladeUp)
    local tools = {}
    for _, t in ipairs(ADSiloTools.list(vehicle)) do
        if not (down and bladeUp and t.spec_leveler ~= nil) then
            table.insert(tools, t)
        end
    end
    for _, t in ipairs(tools) do
        setDown(t, down)
        t.fpSiloDown = down
        local spec = t.spec_attacherJointControl
        if not down and spec ~= nil then
            spec.heightTargetAlpha = -1 -- plus de réglage de hauteur : le relevage reprend la main
        end
    end
    if #tools > 0 then
        log("%s : %s %s", nameOf(vehicle), down and "baisse" or "leve", #tools == 1 and nameOf(tools[1]) or (#tools .. " outils"))
    end
end

-- (16/11) une sorte d'outil seulement : « blade » (lame) ou « roller » (rouleau de silo) ; journal au changement
function ADSiloTools.setKind(vehicle, kind, down)
    local changed = {}
    for _, t in ipairs(ADSiloTools.list(vehicle)) do
        local isBlade = t.spec_leveler ~= nil
        if (kind == "blade") == isBlade then
            if t.fpSiloDown ~= down then
                t.fpSiloDown = down
                table.insert(changed, t)
            end
            setDown(t, down)
            local spec = t.spec_attacherJointControl
            if not down and spec ~= nil then
                spec.heightTargetAlpha = -1
            end
        end
    end
    if #changed > 0 then
        log("%s : %s %s", nameOf(vehicle), down and "baisse" or "leve", #changed == 1 and nameOf(changed[1]) or (#changed .. " outils"))
    end
end

-- (16/11) lame devant (true) ou derrière (false) le tracteur ; nil sans lame. Les outils peuvent être inversés :
-- lame derrière et rouleau devant
function ADSiloTools.bladeAtFront(vehicle)
    for _, t in ipairs(ADSiloTools.list(vehicle)) do
        if t.spec_leveler ~= nil and t.rootNode ~= nil then
            local x, y, z = getWorldTranslation(t.rootNode)
            local _, _, lz = worldToLocal(vehicle.components[1].node, x, y, z)
            return lz > 0
        end
    end
    return nil
end

function ADSiloTools.hasRoller(vehicle)
    for _, t in ipairs(ADSiloTools.list(vehicle)) do
        if t.spec_bunkerSiloCompacter ~= nil and t.spec_leveler == nil then
            return true
        end
    end
    return false
end

-- lame à vérins réglables (attacherJointControl) : tenue à cfg.blade m au-dessus du sol sous elle
function ADSiloTools.holdBlade(vehicle, height)
    for _, t in ipairs(ADSiloTools.list(vehicle)) do
        local spec = t.spec_attacherJointControl
        local lev = t.spec_leveler
        local node = lev ~= nil and lev.nodes ~= nil and lev.nodes[1] ~= nil and lev.nodes[1].node or nil
        if spec ~= nil and spec.heightController ~= nil and node ~= nil then
            local x, y, z = getWorldTranslation(node)
            local ground = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, y, z)
            local err = y - (ground + (height or 0)) -- > 0 : trop haute
            local alpha = spec.heightController.moveAlpha or 0
            if err > ADSiloTools.BLADE_BAND then
                spec.heightTargetAlpha = math.min(1, alpha + ADSiloTools.BLADE_STEP)
            elseif err < -ADSiloTools.BLADE_BAND then
                spec.heightTargetAlpha = math.max(0, alpha - ADSiloTools.BLADE_STEP)
            else
                spec.heightTargetAlpha = -1
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Lancer / arrêter (serveur)
-- ------------------------------------------------------------------------------------------------------------
-- raison du refus, ou nil
function ADSiloJob.refusal(vehicle, silo)
    if silo == nil then
        return "gui_ad_silo_noSilo"
    end
    if not ADSiloCompactor.isFilling(silo) then
        return "gui_ad_silo_closed"
    end
    if not ADSiloCompactor.isCompactorCandidate(vehicle) then
        return "gui_ad_silo_hasTrailer"
    end
    local other = ADSiloCompactor.getCompactor(silo)
    if other ~= nil and other ~= vehicle then
        return "gui_ad_silo_busy"
    end
    return nil
end

function ADSiloJob.isRunning(vehicle)
    local task = vehicle.ad ~= nil and vehicle.ad.taskModule ~= nil and vehicle.ad.taskModule:getActiveTask() or nil
    return vehicle.ad.fpSiloJob ~= nil and vehicle.ad.stateModule:isActive() or (task ~= nil and task.fpSiloCompact == true)
end

function ADSiloJob.start(vehicle, silo)
    local why = ADSiloJob.refusal(vehicle, silo)
    if why ~= nil then
        log("%s : tassage refuse (%s)", nameOf(vehicle), why)
        AutoDriveMessageEvent.sendMessageOrNotification(vehicle, ADMessagesManager.messageTypes.WARN, "$l10n_AD_Driver_of; %s: $l10n_" .. why .. ";", 5000, vehicle.ad.stateModule:getName())
        return false
    end
    local sm = vehicle.ad.stateModule
    if sm:isActive() then
        vehicle:stopAutoDrive()
    end
    local cx, cz = ADSiloJob.center(silo)
    ADSiloJob.selectSilo(vehicle, silo)
    vehicle.ad.fpSiloJob = { x = cx, z = cz }
    sm:setMode(AutoDrive.MODE_COMPACT or AutoDrive.MODE_DRIVETO)
    log("%s : demarre le tassage (silo %.0f, %.0f)", nameOf(vehicle), cx, cz)
    sm:getCurrentMode():start(AutoDrive.USER_PLAYER)
    return true
end

function ADSiloJob.stop(vehicle)
    local wasRunning = ADSiloJob.isRunning(vehicle)
    vehicle.ad.fpSiloJob = nil
    if wasRunning and vehicle.ad.stateModule:isActive() then
        log("%s : tassage arrete par le joueur", nameOf(vehicle))
        vehicle:stopAutoDrive()
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- HUD : roue dentée « Tassage » (même case que la roue du semoir, mode « Tassage » seulement)
-- ------------------------------------------------------------------------------------------------------------
function ADSiloJob.gearShown(vehicle)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil
        and AutoDrive.MODE_COMPACT ~= nil and vehicle.ad.stateModule:getMode() == AutoDrive.MODE_COMPACT
end

function ADSiloJob.hudGear(vehicle, status, toolTip)
    if status ~= nil and status ~= "none" then
        return status, toolTip
    end
    if not ADSiloJob.gearShown(vehicle) then
        return status, toolTip
    end
    return ADSiloJob.isRunning(vehicle) and "ok" or "todo", "gui_ad_silo_tooltip"
end

function ADSiloJob.onGear(vehicle, button, isDown, isUp)
    if button == 1 and isUp then
        if ADSiloCompactGui ~= nil then
            ADSiloCompactGui.open(vehicle)
        end
        return true
    end
    if button > 0 and button < 4 and isDown then
        return true, true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Tâche du tasseur
-- ------------------------------------------------------------------------------------------------------------
SiloCompactTask = ADInheritsFrom(AbstractTask)

SiloCompactTask.STATE_IN = 1            -- aller dans le couloir (outil baissé)
SiloCompactTask.STATE_OUT = 2           -- retour à l'entrée (outil levé)
SiloCompactTask.STATE_TO_WAIT = 3
SiloCompactTask.STATE_WAITING = 4

function SiloCompactTask:new(vehicle, silo)
    local o = SiloCompactTask:create()
    o.vehicle = vehicle
    o.silo = silo
    o.fpSiloCompact = true
    return o
end

SiloCompactTask.PUSH_DIFF = 0.3 -- m : tas plus haut côté entrée que côté fond = la lame pousse dans le fond

function SiloCompactTask:setUp()
    local v = self.vehicle
    self.cfg = ADSiloJob.getCfg(v)
    local g0 = ADSiloCompactor.getGeometry(self.silo)
    local x, _, z = getWorldTranslation(v.components[1].node)
    local across, along = ADSiloCompactor.toLocal(g0, x, z)
    local flip
    if along < 0 or along > g0.length then
        flip = along > g0.length -- dehors : entrée = bout le plus proche
    else
        -- dedans : l'entrée est derrière lui s'il est entré en avant
        local dx, _, dz = AutoDrive.localDirectionToWorld(v, 0, 0, 1)
        flip = (dx * g0.vx + dz * g0.vz) < 0
    end
    self.g = ADSiloCompactor.getEntryGeometry(self.silo, flip)
    self.hasWall = ADSiloCompactor.hasBackWall(self.silo)
    self.reverseIn = self.cfg.dir == ADSiloJob.DIR_REVERSE
    -- (16/11) travail autonome : aller lame en tête lame baissée (pousse au fond ou égalise, choisi
    -- à chaque passage, voir decideBlade), retour en marche arrière lame levée ; le rouleau tasse dans les deux sens
    local blade = ADSiloTools.hasBlade(v)
    self.hasBladeTool = blade
    self.hasRollerTool = ADSiloTools.hasRoller(v)
    if blade and not self.hasWall and self.cfg.push == ADSiloJob.PUSH_WALL then
        log("%s : silo traversant, rien pour pousser contre : egalise seulement", nameOf(v))
    end
    if blade and self.cfg.push ~= ADSiloJob.PUSH_NONE then
        -- l'aller se fait lame en tête : marche avant lame devant, marche arrière lame derrière
        self.bladeFront = ADSiloTools.bladeAtFront(v) ~= false
        self.reverseIn = not self.bladeFront
    end
    -- bout de l'aller : mur moins outil et marge (silo à fond), bord du silo (traversant)
    if self.hasWall then
        self.inAlong = self.g.length - ADSiloCompactor.END_MARGIN - ADSiloTools.overhang(v, not self.reverseIn)
    else
        self.inAlong = self.g.length - 0.5
    end
    self.inAlong = math.max(4, self.inAlong)
    self.outAlong = -(ADSiloTools.overhang(v, self.reverseIn) + 3)
    -- couloirs
    local w = ADSiloTools.workWidth(v, self.cfg)
    local minAcross = w / 2 + ADSiloCompactor.WALL_MARGIN
    local maxAcross = self.g.width - minAcross
    self.lanes = {}
    if maxAcross <= minAcross then
        self.lanes = { self.g.width / 2 }
    else
        local n = math.max(1, math.ceil((maxAcross - minAcross) / (w * ADSiloCompactor.LANE_OVERLAP)) + 1)
        for i = 1, n do
            table.insert(self.lanes, minAcross + (maxAcross - minAcross) * (i - 1) / math.max(1, n - 1))
        end
    end
    local localAcross = ADSiloCompactor.toLocal(self.g, x, z)
    self.lane = 1
    for i, a in ipairs(self.lanes) do
        if math.abs(a - localAcross) < math.abs(self.lanes[self.lane] - localAcross) then
            self.lane = i
        end
    end
    self.silo.fpCompactor = v
    self.silo.fpLastTrailerTime = self.silo.fpLastTrailerTime or g_time
    self.fullMsgSent = false
    self.done = false
    local _, alongNow = ADSiloCompactor.toLocal(self.g, x, z)
    -- arrivé au fond (ancien lancement par un marqueur au fond) : il commence par ressortir
    self:setState(alongNow > 5 and SiloCompactTask.STATE_OUT or SiloCompactTask.STATE_IN)
    log("%s : tasse le silo (%s, %.0f x %.0f m, %d couloirs de %.1f m, entree %s, lame %s, %.0f t, tassage %d %%)", nameOf(v),
        self.hasWall and "a fond" or "traversant", self.g.width, self.g.length, #self.lanes, w, self.reverseIn and "en marche arriere" or "en marche avant",
        not blade and "aucune" or (self.cfg.push == ADSiloJob.PUSH_NONE and "levee (tasse sans pousser)" or "pousse ou egalise selon le tas") .. (self.hasRollerTool and ", rouleau" or ""),
        (v.getTotalMass ~= nil and v:getTotalMass(false) or 0), ADSiloCompactor.getCompactedPercent(self.silo))
end

function SiloCompactTask:setState(state)
    local old = self.state
    self.state = state
    self.stateSince = g_time
    self.stuckTimer = 0
    self.enteredLane = false
    self.leftSilo = false
    local v = self.vehicle
    if state == SiloCompactTask.STATE_IN then
        self.bladeMode, self.bladeHeight = self:decideBlade()
        ADSiloTools.setKind(v, "roller", true)
        ADSiloTools.setKind(v, "blade", self.bladeMode == "push" or self.bladeMode == "level")
    elseif state == SiloCompactTask.STATE_OUT then
        ADSiloTools.setKind(v, "blade", false) -- retour : lame levée, le rouleau continue de tasser
    elseif state == SiloCompactTask.STATE_TO_WAIT or state == SiloCompactTask.STATE_WAITING then
        if old == SiloCompactTask.STATE_IN or old == SiloCompactTask.STATE_OUT then
            ADSiloTools.lower(v, false)
        end
    end
end

-- hauteur du tas (m au-dessus du sol du silo) en un point du couloir ; nil si inconnue
function SiloCompactTask:heapAt(across, along)
    if DensityMapHeightUtil == nil or DensityMapHeightUtil.getHeightAtWorldPos == nil then
        return nil
    end
    local p = ADSiloCompactor.point(self.g, across, along)
    local ground = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, p.x, 0, p.z)
    local ok, y = pcall(DensityMapHeightUtil.getHeightAtWorldPos, p.x, ground, p.z)
    if not ok or y == nil then
        return nil
    end
    return math.max(0, y - ground)
end

-- passage lame baissée : « push » (pousser dans le fond), « level » (égaliser à la hauteur moyenne du tas), « up »
-- (lame levée) ou nil (pas de lame) ; et la hauteur de la lame au-dessus du sol
function SiloCompactTask:decideBlade()
    if not self.hasBladeTool then
        return nil, 0
    end
    if self.cfg.push == ADSiloJob.PUSH_NONE then
        return "up", 0
    end
    local across = self.lanes[self.lane]
    local L = self.inAlong
    local front, back, all, nF, nB = 0, 0, 0, 0, 0
    for i = 0, 4 do
        local hf = self:heapAt(across, L * (0.10 + 0.08 * i))
        local hb = self:heapAt(across, L * (0.58 + 0.08 * i))
        if hf ~= nil then front, nF = front + hf, nF + 1 end
        if hb ~= nil then back, nB = back + hb, nB + 1 end
    end
    local mode, height
    if nF == 0 or nB == 0 then
        -- hauteur du tas inconnue : comme avant (pousse si silo à fond)
        mode = self.hasWall and "push" or "level"
        height = self.cfg.blade
    else
        front, back = front / nF, back / nB
        all = (front + back) / 2
        if self.hasWall and (self.cfg.push == ADSiloJob.PUSH_WALL or front > back + SiloCompactTask.PUSH_DIFF) then
            mode, height = "push", self.cfg.blade
        else
            mode, height = "level", math.max(self.cfg.blade, all)
        end
        log("%s : couloir %d, tas %.2f m cote entree / %.2f m cote fond : %s (lame a %.2f m)", nameOf(self.vehicle), self.lane, front, back,
            mode == "push" and "pousse dans le fond" or "egalise", height)
    end
    return mode, height
end

-- dans le silo ou en train d'en sortir : les bennes attendent
function SiloCompactTask:isInSilo()
    if self.state == SiloCompactTask.STATE_IN or self.state == SiloCompactTask.STATE_OUT or self.state == SiloCompactTask.STATE_TO_WAIT then
        return true
    end
    return ADSiloCompactor.vehicleDistance(self.g, self.vehicle) <= 0
end

function SiloCompactTask:distanceTo(point)
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    return MathUtil.vector2Length(x - point.x, z - point.z)
end

function SiloCompactTask:isStuck(dt)
    if self.vehicle.lastSpeedReal ~= nil and self.vehicle.lastSpeedReal * 3600 < 0.5 then
        self.stuckTimer = self.stuckTimer + dt
    else
        self.stuckTimer = 0
    end
    return self.stuckTimer > ADSiloCompactor.STUCK_TIME or g_time - self.stateSince > ADSiloCompactor.LEG_MAX_TIME
end

-- avance vers un point, en avant ou en arrière ; true = arrivé
function SiloCompactTask:go(dt, point, reverse, speed)
    local sdm = self.vehicle.ad.specialDrivingModule
    if reverse then
        local reached = sdm:reverseToTargetLocation(dt, point, speed or ADSiloCompactor.SPEED_REV)
        return reached or self:distanceTo(point) < 2.5
    end
    sdm:driveToPoint(dt, point, speed or ADSiloCompactor.SPEED_FWD, false, 0.5, speed or ADSiloCompactor.SPEED_FWD, true)
    return self:distanceTo(point) < 2.5
end

function SiloCompactTask:waitTarget()
    if self.cfg.wait == ADSiloJob.WAIT_MARKER then
        local p = ADSiloJob.markerPoint(self.cfg.marker)
        if p ~= nil and ADSiloCompactor.distanceTo(self.g, p.x, p.z) > 3 and ADSiloCompactor.distanceTo(self.g, p.x, p.z) < ADSiloJob.WAIT_MARKER_RANGE then
            return p
        end
    end
    local across = self.lanes[self.lane] < self.g.width / 2 and -ADSiloCompactor.WAIT_SIDE or self.g.width + ADSiloCompactor.WAIT_SIDE
    return ADSiloCompactor.point(self.g, across, -ADSiloCompactor.WAIT_ALONG)
end

-- le point est-il derrière le tracteur
function SiloCompactTask:isBehind(point)
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local _, _, lz = AutoDrive.worldToLocal(self.vehicle, point.x, y, point.z)
    return lz < 0
end

function SiloCompactTask:update(dt)
    if self.done then
        return
    end
    local v = self.vehicle
    local sdm = v.ad.specialDrivingModule

    if not ADSiloCompactor.isFilling(self.silo) then
        log("%s : silo plus en remplissage (etat %s), fin du tassage", nameOf(v), tostring(self.silo.state))
        AutoDriveMessageEvent.sendMessageOrNotification(v, ADMessagesManager.messageTypes.INFO, "$l10n_AD_Driver_of; %s: $l10n_AD_fp_silo_compactDone;", 5000, v.ad.stateModule:getName())
        self:finished()
        return
    end

    local percent = ADSiloCompactor.getCompactedPercent(self.silo)
    if self.silo.fpTrailerNear and (self.state == SiloCompactTask.STATE_IN or self.state == SiloCompactTask.STATE_OUT) then
        log("%s : benne en approche, sort du silo (tassage %d %%)", nameOf(v), percent)
        self:setState(SiloCompactTask.STATE_TO_WAIT)
    end

    local across = self.lanes[self.lane]
    if self.state == SiloCompactTask.STATE_IN then
        local entry = ADSiloCompactor.point(self.g, across, 3)
        local far = ADSiloCompactor.point(self.g, across, self.inAlong)
        if not self.enteredLane and self:distanceTo(entry) < 2.5 then
            self.enteredLane = true
        end
        local aim = self.enteredLane and far or entry
        local reached = self:go(dt, aim, self.reverseIn)
        if self.bladeMode == "push" or self.bladeMode == "level" then
            ADSiloTools.holdBlade(v, self.bladeHeight or self.cfg.blade)
        end
        if (self.enteredLane and (reached and aim == far or self:isStuck(dt))) or (not self.enteredLane and g_time - self.stateSince > ADSiloCompactor.LEG_MAX_TIME) then
            self:setState(SiloCompactTask.STATE_OUT)
        end

    elseif self.state == SiloCompactTask.STATE_OUT then
        local target = ADSiloCompactor.point(self.g, across, self.outAlong)
        if self:go(dt, target, not self.reverseIn) or self:isStuck(dt) then
            self.lane = (self.lane % #self.lanes) + 1
            if self.lane == 1 then
                log("%s : un tour du silo, tassage %d %%", nameOf(v), percent)
                if percent >= 100 and g_time - (self.silo.fpLastTrailerTime or 0) > ADSiloCompactor.IDLE_TIME then
                    self:setState(SiloCompactTask.STATE_TO_WAIT)
                    return
                end
            end
            self:setState(SiloCompactTask.STATE_IN)
        end

    elseif self.state == SiloCompactTask.STATE_TO_WAIT then
        -- d'abord tout droit hors du silo dans son couloir (jamais en biais vers un mur), puis la place d'attente
        if not self.leftSilo then
            local exit = ADSiloCompactor.point(self.g, across, self.outAlong)
            if self:go(dt, exit, not self.reverseIn) or self:isStuck(dt) then
                self.leftSilo = true
                self.stuckTimer = 0
            end
        else
            local target = self:waitTarget()
            if self:go(dt, target, self:isBehind(target)) or self:isStuck(dt) then
                self:setState(SiloCompactTask.STATE_WAITING)
            end
        end

    elseif self.state == SiloCompactTask.STATE_WAITING then
        sdm:stopVehicle()
        sdm:update(dt)
        local trailerInside = false
        for _, other in pairs(AutoDrive.getAllVehicles()) do
            if other ~= v and other.ad ~= nil and other.ad.stateModule ~= nil and other.ad.stateModule:isActive()
                and ADSiloCompactor.vehicleDistance(self.g, other) <= 0 then
                trailerInside = true
                break
            end
        end
        local busy = self.silo.fpTrailerNear or trailerInside
        if busy then
            self.stateSince = g_time
        elseif percent >= 100 and g_time - (self.silo.fpLastTrailerTime or 0) > ADSiloCompactor.IDLE_TIME then
            if not self.fullMsgSent then
                self.fullMsgSent = true
                log("%s : silo tasse a 100 %%, bachage possible (fait par le joueur)%s", nameOf(v), self.cfg.stop and ", arret demande" or "")
                AutoDriveMessageEvent.sendMessageOrNotification(v, ADMessagesManager.messageTypes.INFO, "$l10n_AD_Driver_of; %s: $l10n_AD_fp_silo_canCover;", 8000, v.ad.stateModule:getName())
                if self.cfg.stop then
                    self:finished()
                    return
                end
            end
        elseif g_time - self.stateSince > 3000 then
            self.fullMsgSent = percent >= 100 and self.fullMsgSent
            log("%s : plus de benne, reprend le tassage couloir %d (tassage %d %%)", nameOf(v), self.lane, percent)
            self:setState(SiloCompactTask.STATE_IN)
        end
    end
end

function SiloCompactTask:abort()
    if self.state == SiloCompactTask.STATE_IN then
        ADSiloTools.lower(self.vehicle, false)
    end
    if self.silo ~= nil and self.silo.fpCompactor == self.vehicle then
        self.silo.fpCompactor = nil
    end
end

function SiloCompactTask:finished()
    self.done = true
    self:abort()
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function SiloCompactTask:getI18nInfo()
    local p = string.format(" (%d %%)", ADSiloCompactor.getCompactedPercent(self.silo))
    if self.state == SiloCompactTask.STATE_WAITING or self.state == SiloCompactTask.STATE_TO_WAIT then
        return "$l10n_AD_fp_silo_waiting;" .. p
    end
    return "$l10n_AD_fp_silo_compacting;" .. p
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes : « Conduire vers »
-- ------------------------------------------------------------------------------------------------------------
-- tassage demandé (fenêtre) ou repris au chargement : va au silo, ou tasse tout de suite s'il y est
function ADSiloJob.startJob(mode)
    local v = mode.vehicle
    local job = v.ad.fpSiloJob
    local silo = ADSiloJob.findSilo(job.x, job.z)
    local why = ADSiloJob.refusal(v, silo)
    if why ~= nil then
        log("%s : tassage impossible (%s)", nameOf(v), why)
        v.ad.fpSiloJob = nil
        AutoDriveMessageEvent.sendMessageOrNotification(v, ADMessagesManager.messageTypes.WARN, "$l10n_AD_Driver_of; %s: $l10n_" .. why .. ";", 5000, v.ad.stateModule:getName())
        if v.ad.stateModule:isActive() then
            v:stopAutoDrive()
        end
        return
    end
    if not v.ad.stateModule:isActive() then
        v:startAutoDrive()
        v.ad.fpSiloJob = job -- (startAutoDrive ne passe pas par stopAutoDrive, gardé par sécurité)
    end
    mode:reset()
    local g = ADSiloCompactor.getGeometry(silo)
    if ADSiloCompactor.vehicleDistance(g, v) < ADSiloJob.NEAR_START then
        mode.fpSiloTask = SiloCompactTask:new(v, silo)
        v.ad.taskModule:addTask(mode.fpSiloTask)
        return
    end
    local wp = ADSiloJob.markerInSilo(silo) or ADSiloJob.entryWayPoint(v, silo)
    if wp == nil then
        log("%s : aucun marqueur dans le silo ni point du reseau devant l'entree", nameOf(v))
        v.ad.fpSiloJob = nil
        AutoDriveMessageEvent.sendMessageOrNotification(v, ADMessagesManager.messageTypes.WARN, "$l10n_AD_Driver_of; %s: $l10n_gui_ad_silo_noRoute;", 6000, v.ad.stateModule:getName())
        v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
        return
    end
    log("%s : part au silo (point %s)", nameOf(v), tostring(wp))
    mode.destinationID = wp
    mode.driveToDestinationTask = DriveToDestinationTask:new(v, wp)
    mode.fpSiloDrive = true -- mode « Tassage » : arrivée au silo, voir SiloCompactMode.lua
    v.ad.taskModule:addTask(mode.driveToDestinationTask)
end

local baseDriveToStart = DriveToMode.start
function DriveToMode:start(user)
    local v = self.vehicle
    local sm = v.ad.stateModule
    if v.ad.fpSiloJob == nil and sm.fpSiloJobText ~= nil then
        -- partie rechargée pendant le tassage : il reprend
        local x, z = string.match(sm.fpSiloJobText, "^([%-%d%.]+);([%-%d%.]+)$")
        sm.fpSiloJobText = nil
        if x ~= nil then
            v.ad.fpSiloJob = { x = tonumber(x), z = tonumber(z) }
            log("%s : partie rechargee, reprend le tassage", nameOf(v))
        end
    end
    if v.ad.fpSiloJob ~= nil then
        local ok, err = FarmPilotCall(ADSiloJob.startJob, self)
        if not ok then
            log("%s : ERREUR depart du tassage (%s)", nameOf(v), tostring(err))
            v.ad.fpSiloJob = nil
        end
        return
    end
    return baseDriveToStart(self, user)
end

local baseDriveToFinished = DriveToMode.handleFinishedTask
function DriveToMode:handleFinishedTask()
    local v = self.vehicle
    if self.fpSiloTask ~= nil then
        -- fin du tassage (silo fermé, ou 100 % avec « s'arrêter ») : arrêt comme une arrivée normale
        self.fpSiloTask = nil
        v.ad.fpSiloJob = nil
        v.ad.taskModule:addTask(StopAndDisableADTask:new(v), ADTaskModule.DONT_PROPAGATE)
        return
    end
    if self.driveToDestinationTask ~= nil and v.ad.isStoppingWithError == false and self.destinationID ~= nil
        and self.fpHitch == nil and self.fpSwap == nil then -- attelage / échange de bennes en cours : TrailerHitch.lua d'abord
        local silo = nil
        if v.ad.fpSiloJob ~= nil then
            silo = ADSiloJob.findSilo(v.ad.fpSiloJob.x, v.ad.fpSiloJob.z)
        else
            local wp = ADGraphManager:getWayPointById(self.destinationID)
            silo = wp ~= nil and ADSiloCompactor.getSiloAt(wp.x, wp.z) or nil
        end
        if silo ~= nil and ADSiloJob.refusal(v, silo) == nil then
            self.driveToDestinationTask = nil
            self.fpSiloTask = SiloCompactTask:new(v, silo)
            v.ad.taskModule:addTask(self.fpSiloTask)
            return
        end
        if silo ~= nil then
            log("%s : arrive au silo, tassage impossible (%s), arret", nameOf(v), tostring(ADSiloJob.refusal(v, silo)))
        end
        v.ad.fpSiloJob = nil
    end
    return baseDriveToFinished(self)
end

local baseDriveToReset = DriveToMode.reset
function DriveToMode:reset()
    self.fpSiloTask = nil
    return baseDriveToReset(self)
end

-- arrêt (On/Off, fin, erreur) : le tassage demandé est oublié ; outils levés.
-- Appelé au début d'AutoDrive:stopAutoDrive (une ligne dans Specialization.lua).
function ADSiloJob.onStop(vehicle)
    if vehicle == nil or vehicle.ad == nil then
        return
    end
    vehicle.ad.fpSiloJob = nil
    local task = vehicle.ad.taskModule ~= nil and vehicle.ad.taskModule:getActiveTask() or nil
    if task ~= nil and task.fpSiloCompact == true and not task.done then
        task:abort()
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Sauvegarde : réglages (#fpSiloCfg) et tassage en cours (#fpSiloJob = « x;z » du silo)
-- ------------------------------------------------------------------------------------------------------------
if ADSavegameResume ~= nil then
    local baseSave = ADSavegameResume.save
    function ADSavegameResume.save(stateModule, xmlFile, key, ...)
        if baseSave ~= nil then
            baseSave(stateModule, xmlFile, key, ...)
        end
        FarmPilotCall(function()
            local v = stateModule.vehicle
            if v == nil or v.ad == nil then
                return
            end
            if v.ad.fpSiloCfg ~= nil then
                xmlFile:setValue(key .. "#fpSiloCfg", ADSiloJob.cfgToText(v.ad.fpSiloCfg))
            elseif stateModule.fpSiloCfgText ~= nil then
                xmlFile:setValue(key .. "#fpSiloCfg", stateModule.fpSiloCfgText)
            end
            local job = v.ad.fpSiloJob
            if job ~= nil and stateModule.active then
                xmlFile:setValue(key .. "#fpSiloJob", string.format("%.2f;%.2f", job.x, job.z))
            elseif stateModule.fpSiloJobText ~= nil then
                xmlFile:setValue(key .. "#fpSiloJob", stateModule.fpSiloJobText) -- pas encore reparti depuis le chargement
            end
        end)
    end

    local baseLoad = ADSavegameResume.load
    function ADSavegameResume.load(stateModule, xmlFile, key, ...)
        if baseLoad ~= nil then
            baseLoad(stateModule, xmlFile, key, ...)
        end
        local function read(name)
            local ok, value = FarmPilotCall(xmlFile.getValue, xmlFile, key .. "#" .. name)
            if ok and type(value) == "string" and value ~= "" then
                return value
            end
            return nil
        end
        stateModule.fpSiloCfgText = read("fpSiloCfg")
        stateModule.fpSiloJobText = read("fpSiloJob")
    end
end
