-- ============================================================================================================
-- FarmPilot : HudLoader.lua
-- HUD du mode « Chargeur » (16/11) : 4 lignes (Prendre, Vider, Outil, Quantité).
--
-- - Bouton de mode : « Chargeur » juste après « Tassage » (chargeuse « A », jaune quand il roule).
-- - « Prendre » : tous les silos couloirs de la carte (« Silo N : produit (litres) ») puis les tas au sol trouvés
--   autour du chargeur et des marqueurs (« Tas : produit (litres) - distance »).
-- - « Vider » : « Benne » puis les points du jeu qui prennent le produit de la source, le plus proche d'abord.
-- - « Outil » : godet attelé, ou godet / fourche dételé à aller atteler (liste « Outil avant » du mode Autonome
--   limitée aux godets, Modes/LoaderMode.lua).
-- - « Quantité » : Tout, 2 000 à 100 000 L.
-- - On/Off : démarre / arrête.
-- Les choix sont un réglage du véhicule (#fpLoaderCfg), envoyé au serveur (ADLoaderEvent).
--
-- Branché par : Hud.lua (fpRowKind « loader » : 4 lignes, ADLoaderHud.addRows), register.lua (après HudSilo.lua).
-- ============================================================================================================

ADLoaderHud = {}
ADLoaderHud.TEXT_CACHE = 2000 -- ms : texte d'une ligne fermée recalculé au plus toutes les 2 s (recherche des tas)
ADLoaderHud.version = 0     -- augmenté à chaque choix

local function text(key)
    return g_i18n:getText(key)
end

function ADLoaderHud.isLoaderHud(vehicle)
    return ADLoaderJob ~= nil and ADLoaderJob.isLoaderMode ~= nil and ADLoaderJob.isLoaderMode(vehicle)
end

local baseRowKind = AutoDriveHud.fpRowKind
function AutoDriveHud.fpRowKind(vehicle)
    if ADLoaderHud.isLoaderHud(vehicle) then
        return "loader"
    end
    return baseRowKind(vehicle)
end

-- ------------------------------------------------------------------------------------------------------------
-- Lignes (Hud.lua : createHud)
-- ------------------------------------------------------------------------------------------------------------
function ADLoaderHud.addRows(hud)
    local x = hud.posX + 2 * hud.gapWidth + hud.buttonWidth
    local w = hud.iconWidth * 6 + hud.gapWidth * 5
    local function add(row, kind, order)
        local list = ADPullDownList:new(x, row, w, hud.listItemHeight, ADPullDownList.TYPE_FILLTYPE, 1)
        list.fpLoader = kind
        list.order = order
        table.insert(hud.hudElements, list)
        return list
    end
    add(hud.row4, "src", 1)
    add(hud.row3, "dst", 2)
    local toolList = ADPullDownList:new(x, hud.rowLoaderTool, w, hud.listItemHeight, ADPullDownList.TYPE_FILLTYPE, 1)
    toolList.fpFront = true
    toolList.fpLoaderTool = true
    toolList.order = 3
    table.insert(hud.hudElements, toolList)
    add(hud.rowLoaderQty, "qty", 4)
    if hud.targetPullDownList ~= nil then
        hud.targetPullDownList.fpHidden = true -- même rangée que « Prendre »
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Textes
-- ------------------------------------------------------------------------------------------------------------
local function qtyText(q)
    if q == nil or q <= 0 then
        return text("gui_ad_loader_qtyAll")
    end
    return ADLoaderJob.litersText(q)
end

local function computeCollapsed(list, vehicle)
    local cfg = ADLoaderJob.getCfg(vehicle)
    if list.fpLoader == "src" then
        local s = ADLoaderJob.selectedSource(vehicle)
        if s == nil then
            return text("gui_ad_loader_hudSrcNone")
        end
        local x, _, z = getWorldTranslation(vehicle.components[1].node)
        s.dist = MathUtil.vector2Length(s.x - x, s.z - z)
        return string.format(text("gui_ad_loader_hudSrc"), ADLoaderJob.sourceLabel(s, true))
    elseif list.fpLoader == "dst" then
        if cfg.dst == ADLoaderJob.DST_POINT then
            local t = ADLoaderJob.findPoint(cfg.px, cfg.pz)
            return string.format(text("gui_ad_loader_hudDst"), t ~= nil and ADLoaderJob.pointName(t) or text("gui_ad_loader_pointGone"))
        end
        return string.format(text("gui_ad_loader_hudDst"), text("gui_ad_loader_trailer"))
    end
    return string.format(text("gui_ad_loader_hudQty"), qtyText(cfg.qty))
end

function ADLoaderHud.collapsedText(list, vehicle)
    local now = g_time or 0
    if list.fpLoaderText ~= nil and list.fpLoaderVehicle == vehicle and list.fpLoaderVersion == ADLoaderHud.version and now - (list.fpLoaderTime or 0) < ADLoaderHud.TEXT_CACHE then
        return list.fpLoaderText
    end
    list.fpLoaderText = computeCollapsed(list, vehicle)
    list.fpLoaderTime = now
    list.fpLoaderVehicle = vehicle
    list.fpLoaderVersion = ADLoaderHud.version
    return list.fpLoaderText
end

-- ------------------------------------------------------------------------------------------------------------
-- Listes ouvertes
-- ------------------------------------------------------------------------------------------------------------
function ADLoaderHud.fillOptions(list, vehicle)
    list.fpLoaderEntries = {}
    list.options = { {} }
    local function addOption(entry, label)
        local i = #list.fpLoaderEntries + 1
        list.fpLoaderEntries[i] = entry
        list.options[1][i] = { displayName = label, returnValue = i }
    end
    if list.fpLoader == "src" then
        for _, s in ipairs(ADLoaderJob.sources(vehicle)) do
            addOption({ source = s }, ADLoaderJob.sourceLabel(s, true))
        end
        if #list.fpLoaderEntries == 0 then
            list.options[1][1] = { displayName = text("gui_ad_loader_hudSrcNone"), returnValue = 0 }
        end
    elseif list.fpLoader == "dst" then
        addOption({ trailer = true }, text("gui_ad_loader_trailer"))
        local s = ADLoaderJob.selectedSource(vehicle)
        if s ~= nil then
            for _, p in ipairs(ADLoaderJob.points(s.fillType, s.x, s.z)) do
                addOption({ point = p }, p.name .. " - " .. ADLoaderJob.distanceText(p.dist))
            end
        end
    else
        for _, q in ipairs(ADLoaderJob.QUANTITIES) do
            addOption({ qty = q }, qtyText(q))
        end
    end
    list.fpToolOptions = true -- retour aux types de produit en quittant le mode (restoreFillTypeOptions)
    list.fpToolList = nil
end

-- choix dans la liste : réglage du véhicule, envoyé au serveur
function ADLoaderHud.apply(list, vehicle, value)
    local e = list.fpLoaderEntries ~= nil and list.fpLoaderEntries[value] or nil
    if e == nil then
        return
    end
    local cfg = ADLoaderJob.getCfg(vehicle)
    if e.source ~= nil then
        cfg.src, cfg.sx, cfg.sz = e.source.kind, e.source.x, e.source.z
        -- autre source : le point choisi peut ne pas prendre ce produit, il reste choisi s'il le prend
        local t = cfg.dst == ADLoaderJob.DST_POINT and ADLoaderJob.findPoint(cfg.px, cfg.pz) or nil
        if t ~= nil and not ADTriggerManager.triggerSupportsFillType(t, e.source.fillType or 0) then
            cfg.dst, cfg.px, cfg.pz = ADLoaderJob.DST_TRAILER, nil, nil
        end
    elseif e.trailer then
        cfg.dst, cfg.px, cfg.pz = ADLoaderJob.DST_TRAILER, nil, nil
    elseif e.point ~= nil then
        cfg.dst, cfg.px, cfg.pz = ADLoaderJob.DST_POINT, e.point.x, e.point.z
    elseif e.qty ~= nil then
        cfg.qty = e.qty
    end
    ADLoaderHud.version = ADLoaderHud.version + 1 -- textes des lignes refaits tout de suite
    ADLoaderEvent.send(vehicle, ADLoaderJob.cfgToText(cfg))
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes de ADPullDownList
-- ------------------------------------------------------------------------------------------------------------
local baseIsFpTool = ADPullDownList.isFpTool
function ADPullDownList:isFpTool(vehicle)
    if self.fpLoader ~= nil or self.fpLoaderTool then
        return ADLoaderHud.isLoaderHud(vehicle)
    end
    if ADLoaderHud.isLoaderHud(vehicle) then
        return false -- lignes des autres modes : rien dans le HUD Chargeur
    end
    return baseIsFpTool(self, vehicle)
end

local baseCreateFpTool = ADPullDownList.createSelection_FpTool
function ADPullDownList:createSelection_FpTool(vehicle)
    if self.fpLoader ~= nil then
        local ok = FarmPilotCall(ADLoaderHud.fillOptions, self, vehicle)
        if not ok then
            self.options = { { { displayName = "", returnValue = 0 } } }
        end
        return
    end
    return baseCreateFpTool(self, vehicle)
end

local baseNewStateFill = ADPullDownList.getNewState_FillType
function ADPullDownList:getNewState_FillType(vehicle)
    if self.fpLoader ~= nil and self:isFpTool(vehicle) then
        if self.state == ADPullDownList.STATE_COLLAPSED then
            local ok, t = FarmPilotCall(ADLoaderHud.collapsedText, self, vehicle)
            self.text = ok and t or ""
        end
        return self.state, self.selected
    end
    local state, selected = baseNewStateFill(self, vehicle)
    if self.fpLoaderTool and self.state == ADPullDownList.STATE_COLLAPSED and ADLoaderHud.isLoaderHud(vehicle) then
        FarmPilotCall(ADLoaderHud.toolText, self, vehicle) -- « Outil : ... » au lieu de « Outil avant : ... »
    end
    return state, selected
end

-- ligne « Outil » : godet choisi à atteler, sinon godet attelé, sinon aucun
function ADLoaderHud.toolText(list, vehicle)
    local chosen = list:fpGetTool(vehicle)
    local attached = ADLoaderJob.attachedShovel(vehicle)
    if chosen ~= nil and chosen ~= attached then
        list.text = string.format(text("gui_ad_loader_hudToolFetch"), ADAutonomousManager.toolLabel(chosen))
    elseif attached ~= nil then
        list.text = string.format(text("gui_ad_loader_hudTool"), ADAutonomousManager.toolLabel(attached))
    else
        list.text = text("gui_ad_loader_hudToolNone")
    end
end

local baseCollapse = ADPullDownList.collapse
function ADPullDownList:collapse(vehicle, setItem)
    if self.fpLoader ~= nil and vehicle ~= nil and self:isFpTool(vehicle) then
        local value = nil
        if setItem == true and self.hovered ~= nil then
            local entry = self:getListElementByIndex(vehicle, self.hovered)
            value = entry ~= nil and entry.returnValue or nil
        end
        if self.state == ADPullDownList.STATE_EXPANDED then
            self.layer = self.layer - 1
        end
        self.state = ADPullDownList.STATE_COLLAPSED
        AutoDrive.pullDownListExpanded = 0
        if value ~= nil and value > 0 then
            FarmPilotCall(ADLoaderHud.apply, self, vehicle, value)
        end
        AutoDrive.Hud.lastUIScale = 0
        return
    end
    return baseCollapse(self, vehicle, setItem)
end

local baseAct = ADPullDownList.act
function ADPullDownList:act(vehicle, posX, posY, isDown, isUp, button)
    if self.fpLoader ~= nil and button == 3 and self.state == ADPullDownList.STATE_COLLAPSED then
        return isUp == true -- clic droit : rien à vider sur ces lignes
    end
    return baseAct(self, vehicle, posX, posY, isDown, isUp, button)
end

local baseGetTool = ADPullDownList.fpGetTool
function ADPullDownList:fpGetTool(vehicle)
    if self.fpLoader ~= nil then
        return nil
    end
    return baseGetTool(self, vehicle)
end
