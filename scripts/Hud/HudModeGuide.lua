-- ============================================================================================================
-- FarmPilot : HudModeGuide.lua
-- Guide des modes (18/11) : colonne des 8 icônes de mode collée à droite du HUD.
--
-- Règles :
-- - Les modes du bouton de mode (ADStateModule.MODE_CYCLE), dans le même ordre, de haut en bas. Le bouton de mode
--   du HUD reste à sa place et marche comme avant.
-- - Mode actif : icône en couleur (jaune quand le chauffeur roule, comme le bouton de mode), sur un fond plus clair
--   encadré de jaune. Les autres : grisés. Autonome : l'icône de la machine conduite (moissonneuse, ensileuse,
--   récolteuse, sinon tracteur), voir ADHudButton.harvesterIcon.
-- - Mode interdit pour ce véhicule (ADStateModule:isModeAllowed, par exemple un train) : très pâle, barré en rouge,
--   le clic ne fait rien.
-- - Clic gauche sur une icône : passe directement à ce mode (réglé par le serveur : AutoDriveHudInputEventEvent,
--   TYPE_FP_MODE). Souris sur une icône : son nom à côté de la colonne.
-- - Taille fixe (ne change pas avec le mode, pour que les icônes ne bougent pas sous la souris), bas aligné sur le
--   bas du HUD ; s'il n'y a pas la place à droite de l'écran, à gauche du HUD.
-- - Même style que le HUD (fond aux coins arrondis, ADHudIcon.drawRounded).
--
-- Branché par : Hud.lua (createHudAt : ajout aux éléments du HUD). Chargé par register.lua après HudInputEvent.lua.
-- ============================================================================================================

ADModeGuide = ADInheritsFrom(ADGenericHudElement)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages (pixels à l'échelle 1, écran 1080p)
-- ------------------------------------------------------------------------------------------------------------
ADModeGuide.ICON_PX = 28 -- côté d'une icône
ADModeGuide.GAP_PX = 3 -- entre deux icônes
ADModeGuide.PAD_PX = 5 -- bord de la colonne
ADModeGuide.FRAME_PX = 2 -- cadre du mode actif / de l'icône sous la souris
ADModeGuide.TIP_PAD_PX = 8 -- marge du nom affiché à côté

ADModeGuide.ALPHA_OFF = 0.42 -- mode pas actif
ADModeGuide.ALPHA_BARRED = 0.22 -- mode interdit
ADModeGuide.COLOR_ACTIVE = { 1, 0.78, 0, 1 } -- cadre jaune
ADModeGuide.COLOR_ACTIVE_BG = { 0.20, 0.23, 0.18, 1 }
ADModeGuide.COLOR_HOVER = { 0.9, 0.9, 0.9, 0.8 }
ADModeGuide.COLOR_BARRED = { 0.86, 0.16, 0.16, 1 }

-- icône (n° de input_silomode_N dans textures/ad_gui.xml) et nom de chaque mode ; jaune en marche = N + 1
ADModeGuide.ICON = {
    [AutoDrive.MODE_DRIVETO] = 1,
    [AutoDrive.MODE_DELIVERTO] = 2,
    [AutoDrive.MODE_PICKUPANDDELIVER] = 3,
    [AutoDrive.MODE_LOAD] = 4,
    [AutoDrive.MODE_UNLOAD] = 5,
}
ADModeGuide.NAME = {
    [AutoDrive.MODE_DRIVETO] = "AD_MODE_DRIVETO",
    [AutoDrive.MODE_DELIVERTO] = "AD_MODE_DELIVERTO",
    [AutoDrive.MODE_PICKUPANDDELIVER] = "AD_MODE_PICKUPANDDELIVER",
    [AutoDrive.MODE_LOAD] = "AD_MODE_LOAD",
    [AutoDrive.MODE_UNLOAD] = "AD_MODE_UNLOAD",
    [AutoDrive.MODE_BGA] = "AD_MODE_BGA",
}
if AutoDrive.MODE_AUTONOMOUS ~= nil then ADModeGuide.NAME[AutoDrive.MODE_AUTONOMOUS] = "AD_MODE_AUTONOMOUS" end
if AutoDrive.MODE_COMPACT ~= nil then
    ADModeGuide.ICON[AutoDrive.MODE_COMPACT] = 9
    ADModeGuide.NAME[AutoDrive.MODE_COMPACT] = "AD_MODE_COMPACT"
end
if AutoDrive.MODE_LOADER ~= nil then
    ADModeGuide.ICON[AutoDrive.MODE_LOADER] = 11
    ADModeGuide.NAME[AutoDrive.MODE_LOADER] = "AD_MODE_LOADER"
end
-- modes qui ont une icône jaune « en marche »
ADModeGuide.HAS_RUNNING = { [9] = true, [11] = true, [7] = true, [13] = true, [15] = true, [17] = true }

local function log(fmt, ...)
    print("[FP-Hud] " .. string.format(fmt, ...))
end

local function modes()
    return ADStateModule.MODE_CYCLE or {}
end

-- n° de l'icône du mode (blanche, à l'arrêt)
function ADModeGuide.iconOf(vehicle, mode)
    if AutoDrive.MODE_AUTONOMOUS ~= nil and mode == AutoDrive.MODE_AUTONOMOUS then
        local kind = vehicle ~= nil and ADHudButton.harvesterIcon ~= nil and ADHudButton.harvesterIcon(vehicle) or false
        return ADHudButton.HARVESTER_ICON ~= nil and ADHudButton.HARVESTER_ICON[kind] or 7
    end
    return ADModeGuide.ICON[mode] or 1
end

-- ------------------------------------------------------------------------------------------------------------
-- Création (appelée par createHudAt à chaque construction du HUD)
-- ------------------------------------------------------------------------------------------------------------
function ADModeGuide.addTo(hud, uiScale)
    local o = ADModeGuide:create()
    o:init(hud.posX, hud.posY, 0, 0)
    o.layer = 6
    o.hud = hud
    o.uiScale = uiScale or 1
    o.overlays = {}
    for i = 1, #modes() do
        o.overlays[i] = g_overlayManager:createOverlay("ad_gui.input_silomode_1", 0, 0, 0, 0)
    end
    o:layout()
    table.insert(hud.hudElements, o)
    return o
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en page : refaite quand le HUD bouge
-- ------------------------------------------------------------------------------------------------------------
function ADModeGuide:layout()
    local hud = self.hud
    local key = string.format("%.5f;%.5f;%.5f;%.3f", hud.posX or 0, hud.posY or 0, hud.width or 0, self.uiScale)
    if self.layoutKey == key then
        return
    end
    self.layoutKey = key
    local s = self.uiScale
    local iconW, iconH = getNormalizedScreenValues(ADModeGuide.ICON_PX * s, ADModeGuide.ICON_PX * s)
    local gapW, gapH = getNormalizedScreenValues(ADModeGuide.GAP_PX * s, ADModeGuide.GAP_PX * s)
    local padW, padH = getNormalizedScreenValues(ADModeGuide.PAD_PX * s, ADModeGuide.PAD_PX * s)
    local frameW, frameH = getNormalizedScreenValues(ADModeGuide.FRAME_PX * s, ADModeGuide.FRAME_PX * s)
    local n = #modes()
    local w = iconW + 2 * padW
    local h = n * iconH + (n - 1) * gapH + 2 * padH
    local x = hud.posX + hud.width + (hud.gapWidth or gapW)
    self.onLeft = false
    if x + w > 1 then
        x = hud.posX - (hud.gapWidth or gapW) - w -- pas la place à droite de l'écran : à gauche du HUD
        self.onLeft = true
    end
    local y = hud.posY
    if y + h > 1 then
        y = 1 - h
    end
    self.position.x, self.position.y = x, y
    self.size.width, self.size.height = w, h
    self.L = { iconW = iconW, iconH = iconH, gapH = gapH, padW = padW, padH = padH, frameW = frameW, frameH = frameH }
    self.cells = {}
    for i = 1, n do
        local cx = x + padW
        local cy = y + h - padH - i * iconH - (i - 1) * gapH -- 1er mode en haut
        self.cells[i] = { x = cx, y = cy }
        local ov = self.overlays[i]
        if ov ~= nil then
            ov:setPosition(cx, cy)
            ov:setDimension(iconW, iconH)
        end
    end
end

-- n° de la case sous la souris, ou nil
function ADModeGuide:cellAt(posX, posY)
    if self.cells == nil or posX == nil or posY == nil then
        return nil
    end
    local L = self.L
    for i, c in ipairs(self.cells) do
        if posX >= c.x and posX <= c.x + L.iconW and posY >= c.y - L.gapH / 2 and posY <= c.y + L.iconH + L.gapH / 2 then
            return i
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Dessin
-- ------------------------------------------------------------------------------------------------------------
local function color(name)
    local c = AutoDrive.currentColors ~= nil and AutoDrive.currentColors[name] or AutoDrive.colors[name]
    return c or { 0, 0, 0, 0.9 }
end

local function rounded(x, y, w, h, uiScale, c)
    local ov = { x = x, y = y, width = w, height = h }
    if not ADHudIcon.drawRounded(ov, uiScale, true, true, c) then
        drawFilledRect(x, y, w, h, c[1], c[2], c[3], c[4])
    end
end

-- cadre autour d'une icône : fond de la couleur du cadre, puis le fond intérieur
local function frame(self, c, inner)
    local L = self.L
    rounded(c.x - 2 * L.frameW, c.y - 2 * L.frameH, L.iconW + 4 * L.frameW, L.iconH + 4 * L.frameH, self.uiScale * 0.5, inner.border)
    rounded(c.x - L.frameW, c.y - L.frameH, L.iconW + 2 * L.frameW, L.iconH + 2 * L.frameH, self.uiScale * 0.5, inner.fill)
end

-- trait rouge en travers (de bas à gauche à haut à droite), en petits carrés
local function barre(self, c)
    local L = self.L
    local steps = 16
    local dw, dh = L.frameW * 1.4, L.frameH * 1.4
    local col = ADModeGuide.COLOR_BARRED
    for k = 0, steps do
        local t = k / steps
        local px = c.x + L.iconW * (0.08 + 0.84 * t) - dw / 2
        local py = c.y + L.iconH * (0.08 + 0.84 * t) - dh / 2
        drawFilledRect(px, py, dw, dh, col[1], col[2], col[3], col[4])
    end
end

function ADModeGuide:onDraw(vehicle, uiScale)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or self.overlays == nil then
        return
    end
    self:layout()
    local sm = vehicle.ad.stateModule
    local current = sm:getMode()
    local running = sm:isActive()
    rounded(self.position.x, self.position.y, self.size.width, self.size.height, self.uiScale, color("ad_color_background"))

    local hover = nil
    if g_inputBinding ~= nil and g_inputBinding:getShowMouseCursor() then
        hover = self:cellAt(g_lastMousePosX, g_lastMousePosY)
    end
    for i, mode in ipairs(modes()) do
        local c, ov = self.cells[i], self.overlays[i]
        local allowed = sm:isModeAllowed(mode)
        local icon = ADModeGuide.iconOf(vehicle, mode)
        if mode == current and running and ADModeGuide.HAS_RUNNING[icon] then
            icon = icon + 1
        end
        ov:setSliceId("ad_gui.input_silomode_" .. icon)
        if mode == current then
            frame(self, c, { border = ADModeGuide.COLOR_ACTIVE, fill = ADModeGuide.COLOR_ACTIVE_BG })
            ov:setColor(1, 1, 1, 1)
        else
            if hover == i and allowed then
                frame(self, c, { border = ADModeGuide.COLOR_HOVER, fill = color("ad_color_background") })
            end
            ov:setColor(1, 1, 1, allowed and ADModeGuide.ALPHA_OFF or ADModeGuide.ALPHA_BARRED)
        end
        ov:render()
        if not allowed then
            barre(self, c)
        end
    end
    if hover ~= nil then
        self:drawName(modes()[hover], self.cells[hover])
    end
end

-- nom du mode à côté de la colonne (côté opposé au HUD)
function ADModeGuide:drawName(mode, c)
    local key = ADModeGuide.NAME[mode]
    if key == nil or c == nil then
        return
    end
    local text = g_i18n:getText(key)
    local size = AutoDrive.FONT_SCALE * self.uiScale
    local padW, padH = getNormalizedScreenValues(ADModeGuide.TIP_PAD_PX * self.uiScale, ADModeGuide.TIP_PAD_PX * self.uiScale * 0.6)
    local tw = getTextWidth(size, text) + 2 * padW
    local th = getTextHeight(size, text) + 2 * padH
    local x = self.onLeft and (self.position.x - self.L.padW - tw) or (self.position.x + self.size.width + self.L.padW)
    local y = c.y + (self.L.iconH - th) / 2
    rounded(x, y, tw, th, self.uiScale * 0.5, color("ad_color_header"))
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(unpack(color("ad_color_hudTextDefault")))
    renderText(x + padW, y + padH + getTextHeight(size, text) * 0.15, size, text)
    setTextColor(1, 1, 1, 1)
end

-- ------------------------------------------------------------------------------------------------------------
-- Souris
-- ------------------------------------------------------------------------------------------------------------
-- tout clic dans la colonne est pris par le HUD (jamais un point posé dans l'éditeur derrière)
function ADModeGuide:act(vehicle, posX, posY, isDown, isUp, button)
    if not (isUp and button == 1) then
        return true, true
    end
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or AutoDrive.pullDownListExpanded ~= 0 then
        return true, true
    end
    local i = self:cellAt(posX, posY)
    local mode = i ~= nil and modes()[i] or nil
    local sm = vehicle.ad.stateModule
    if mode == nil or mode == sm:getMode() then
        return true, true
    end
    if not sm:isModeAllowed(mode) then
        log("guide des modes : %s interdit pour %s", tostring(ADModeGuide.NAME[mode]), tostring(sm:getName()))
        return true, true
    end
    log("guide des modes : %s passe de %s a %s", tostring(sm:getName()), tostring(ADModeGuide.NAME[sm:getMode()]), tostring(ADModeGuide.NAME[mode]))
    AutoDriveHudInputEventEvent:sendFpModeEvent(vehicle, mode)
    return true, false
end

-- ------------------------------------------------------------------------------------------------------------
-- Réseau : le mode choisi est réglé par le serveur (comme le bouton de mode)
-- ------------------------------------------------------------------------------------------------------------
AutoDriveHudInputEventEvent.TYPE_FP_MODE = 8

function AutoDriveHudInputEventEvent:sendFpModeEvent(vehicle, mode)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(AutoDriveHudInputEventEvent.new(vehicle, self.TYPE_FP_MODE, mode))
    end
end

local baseRun = AutoDriveHudInputEventEvent.run
function AutoDriveHudInputEventEvent:run(connection)
    if self.eventType == AutoDriveHudInputEventEvent.TYPE_FP_MODE then
        if g_server ~= nil and self.vehicle ~= nil and self.vehicle.ad ~= nil and self.vehicle.ad.stateModule ~= nil then
            self.vehicle.ad.stateModule:setMode(self.value)
        end
        return
    end
    return baseRun(self, connection)
end
