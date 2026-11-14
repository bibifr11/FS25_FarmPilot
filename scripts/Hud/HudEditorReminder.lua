-- ============================================================================================================
-- FarmPilot : HudEditorReminder.lua
-- Fenêtre « Rappel éditeur » : types de route avec leur couleur, et les points essentiels qu'on oublie (13/11).
--
-- Règles (13/11) :
-- - Ouverte et fermée par le bouton « ? » du bandeau du HUD (il ouvrait les astuces de l'éditeur dans le bandeau ;
--   les touches de ces astuces sont reprises dans la fenêtre). Le HUD ne change plus de taille.
-- - Collée à gauche du HUD, bas aligné sur le bas du HUD ; s'il n'y a pas la place à gauche, à droite.
-- - Un clic dans la fenêtre la ferme aussi ; un clic dedans ne pose jamais de point dans l'éditeur.
-- - Types de route : principale, secondaire, tertiaire, accès, intersection, marche arrière, avec un trait de la
--   couleur réellement utilisée par l'éditeur (couleurs du joueur comprises), en sens unique et en double sens.
-- - Même style que le HUD (fond et bandeau aux coins arrondis, ADHudIcon.drawRounded).
--
-- Branché par : Hud.lua (createHudAt : ajout de la fenêtre aux éléments ; toggleHudExtension : ouvrir / fermer).
-- Chargé par register.lua après HudIcon.lua.
-- ============================================================================================================

ADEditorReminder = ADInheritsFrom(ADGenericHudElement)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADEditorReminder.WIDTH_PX = 380 -- largeur de la fenêtre (pixels à l'échelle 1, écran 1080p)
ADEditorReminder.SWATCH_PX = 34 -- longueur d'un trait de couleur
ADEditorReminder.LINE_PX = 4 -- épaisseur d'un trait de couleur
ADEditorReminder.shown = false -- ouverte ou non (gardée tant que la partie tourne)

-- lignes du tableau : texte, couleur sens unique, couleur double sens (nil = pas de double sens)
ADEditorReminder.ROADS = {
    { "fp_reminder_road_primary", "ad_color_singleConnection", "ad_color_dualConnection" },
    { "fp_reminder_road_secondary", "ad_color_subPrioSingleConnection", "ad_color_subPrioDualConnection" },
    { "fp_reminder_road_tertiary", "ad_color_dirtSingleConnection", "ad_color_dirtDualConnection" },
    { "fp_reminder_road_access", "ad_color_accessSingleConnection", "ad_color_accessDualConnection" },
    { "fp_reminder_road_intersection", "ad_color_intersectionConnection", "ad_color_intersectionConnection" },
    { "fp_reminder_road_reverse", "ad_color_reverseConnection", nil },
}

-- points essentiels, dans l'ordre
ADEditorReminder.POINTS = {
    "fp_reminder_point_secondary",
    "fp_reminder_point_tertiary",
    "fp_reminder_point_access",
    "fp_reminder_point_intersection",
    "fp_reminder_point_places",
    "fp_reminder_point_parking",
    "fp_reminder_point_keys",
    "fp_reminder_point_keys2",
}

-- ------------------------------------------------------------------------------------------------------------
-- Ouvrir / fermer, création
-- ------------------------------------------------------------------------------------------------------------
function ADEditorReminder.toggle()
    ADEditorReminder.shown = not ADEditorReminder.shown
end

-- appelée par createHudAt à chaque construction du HUD
function ADEditorReminder.addTo(hud, uiScale)
    local o = ADEditorReminder:create()
    o:init(hud.posX, hud.posY, 0, 0)
    o.layer = 6
    o.hud = hud
    o.uiScale = uiScale or 1
    table.insert(hud.hudElements, o)
    return o
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en page (taille et place calculées avec les vrais textes, avant chaque dessin)
-- ------------------------------------------------------------------------------------------------------------

-- coupe un texte en lignes qui tiennent dans maxWidth (entre deux mots)
function ADEditorReminder.wrap(text, fontSize, maxWidth)
    local lines, line = {}, nil
    for word in string.gmatch(text or "", "%S+") do
        local test = line == nil and word or (line .. " " .. word)
        if line ~= nil and getTextWidth(fontSize, test) > maxWidth then
            table.insert(lines, line)
            line = word
        else
            line = test
        end
    end
    if line ~= nil then
        table.insert(lines, line)
    end
    return lines
end

function ADEditorReminder:layout()
    local hud, ui = self.hud, self.uiScale
    local L = {}
    L.font = AutoDrive.FONT_SCALE * ui
    L.lineH = getTextHeight(L.font, "text") + hud.gapHeight
    L.gapW, L.gapH = hud.gapWidth, hud.gapHeight
    L.width = getNormalizedScreenValues(ADEditorReminder.WIDTH_PX * ui, 0)
    L.swatchW, L.swatchH = getNormalizedScreenValues(ADEditorReminder.SWATCH_PX * ui, ADEditorReminder.LINE_PX * ui)
    L.headerH = hud.headerHeight or (AutoDriveHud.defaultHeaderHeight * ui)
    L.padX = 3 * L.gapW
    L.textW = L.width - 2 * L.padX
    -- colonnes des traits, à droite : « Sens unique » puis « Double sens » ; largeur = titre de colonne ou trait
    L.colFont = L.font * 0.85
    L.colW = math.max(L.swatchW, getTextWidth(L.colFont, g_i18n:getText("fp_reminder_single")), getTextWidth(L.colFont, g_i18n:getText("fp_reminder_dual")))
    L.colDualMid = L.width - L.padX - L.colW / 2
    L.colSingleMid = L.colDualMid - L.colW - 5 * L.gapW
    L.labelW = L.colSingleMid - L.colW / 2 - L.gapW - L.padX -- place pour le nom de la route
    L.points = {}
    local count = 0
    for _, key in ipairs(ADEditorReminder.POINTS) do
        local lines = ADEditorReminder.wrap("• " .. g_i18n:getText(key), L.font, L.textW - getTextWidth(L.font, "• "))
        table.insert(L.points, lines)
        count = count + #lines
    end
    -- bandeau, ligne des colonnes, routes, écart, points, marge
    L.height = L.headerH + (1 + #ADEditorReminder.ROADS) * L.lineH + L.lineH * 0.5 + count * L.lineH + 2 * L.gapH
    -- place : à gauche du HUD, sinon à droite ; bas aligné sur le HUD, sans sortir de l'écran
    local x = hud.posX - L.gapW - L.width
    if x < 0 then
        x = hud.posX + hud.width + L.gapW
    end
    local y = math.max(0, math.min(hud.posY, 1 - L.height))
    self.position.x, self.position.y = x, y
    self.size.width, self.size.height = L.width, L.height
    return L
end

-- ------------------------------------------------------------------------------------------------------------
-- Dessin
-- ------------------------------------------------------------------------------------------------------------
local function color(name)
    local c = AutoDrive.currentColors ~= nil and AutoDrive.currentColors[name] or AutoDrive.colors[name]
    return c or { 1, 1, 1, 1 }
end

local function rounded(x, y, w, h, uiScale, top, bottom, c)
    local ov = { x = x, y = y, width = w, height = h }
    if not ADHudIcon.drawRounded(ov, uiScale, top, bottom, c) then
        drawFilledRect(x, y, w, h, c[1], c[2], c[3], c[4])
    end
end

function ADEditorReminder:onDraw(vehicle, uiScale)
    if not ADEditorReminder.shown then
        return
    end
    local L = self:layout()
    local x, y, w, h = self.position.x, self.position.y, self.size.width, self.size.height
    rounded(x, y, w, h - L.headerH, uiScale, false, true, color("ad_color_background"))
    rounded(x, y + h - L.headerH, w, L.headerH, uiScale, true, false, color("ad_color_header"))

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(true)
    setTextColor(unpack(color("ad_color_hudTextDefault")))
    local textH = getTextHeight(L.font, "text")
    renderText(x + L.padX, y + h - L.headerH + (L.headerH - textH) / 2, L.font, g_i18n:getText("fp_reminder_title"))

    -- en-tête des colonnes
    local rowY = y + h - L.headerH - L.lineH
    setTextColor(unpack(color("ad_color_hudTextSpecial")))
    setTextAlignment(RenderText.ALIGN_CENTER)
    renderText(x + L.colSingleMid, rowY, L.colFont, g_i18n:getText("fp_reminder_single"))
    renderText(x + L.colDualMid, rowY, L.colFont, g_i18n:getText("fp_reminder_dual"))

    -- routes
    setTextBold(false)
    for _, road in ipairs(ADEditorReminder.ROADS) do
        rowY = rowY - L.lineH
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(unpack(color("ad_color_hudTextDefault")))
        local label = g_i18n:getText(road[1])
        local size = L.font
        if getTextWidth(size, label) > L.labelW then
            size = size * L.labelW / getTextWidth(size, label) -- nom trop long (autre langue) : police réduite
        end
        renderText(x + L.padX, rowY, size, label)
        local lineY = rowY + textH * 0.35
        local c1 = color(road[2])
        drawFilledRect(x + L.colSingleMid - L.swatchW / 2, lineY, L.swatchW, L.swatchH, c1[1], c1[2], c1[3], 1)
        if road[3] ~= nil then
            local c2 = color(road[3])
            drawFilledRect(x + L.colDualMid - L.swatchW / 2, lineY, L.swatchW, L.swatchH, c2[1], c2[2], c2[3], 1)
        end
    end

    -- points essentiels
    rowY = rowY - L.lineH * 0.5
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(unpack(color("ad_color_hudTextDefault")))
    for _, lines in ipairs(L.points) do
        for i, line in ipairs(lines) do
            rowY = rowY - L.lineH
            renderText(x + L.padX + (i > 1 and getTextWidth(L.font, "• ") or 0), rowY, L.font, line)
        end
    end
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

-- une fenêtre fermée ne prend aucun clic
function ADEditorReminder:hit(posX, posY, layer)
    return ADEditorReminder.shown and ADGenericHudElement.hit(self, posX, posY, layer)
end

-- clic dans la fenêtre : la ferme ; la souris dessus ne pose jamais de point (pris par le HUD, sans bruit de clic
-- quand elle ne fait que passer)
function ADEditorReminder:act(vehicle, posX, posY, isDown, isUp, button)
    if isUp and button == 1 then
        ADEditorReminder.shown = false
        return true, false
    end
    return true, true
end
