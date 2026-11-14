-- ============================================================================================================
-- FarmPilot : HudTextWrap.lua
-- Message d'une ligne du HUD (ex. le message rouge « Aucun chauffeur avec la même destination disponible ») :
-- coupé sur 2 lignes s'il est plus large que le HUD (12/11).
--
-- Règles (12/11) :
-- - Le texte tient dans la fenêtre : de son début jusqu'au bord droit du HUD, moins un écart.
-- - Il tient sur une ligne : affiché comme avant, au même endroit.
-- - Trop large : coupé entre deux mots, en 2 lignes aussi égales que possible, centrées sur la même ligne du HUD.
-- - Encore trop large sur 2 lignes (mot très long, langue plus longue) : la police rétrécit juste ce qu'il faut.
--
-- Branché par : Hud/HudHarvesterInfo.lua (onDraw, une ligne). Chargé par register.lua après HudHarvesterInfo.lua.
-- ============================================================================================================

ADHudTextWrap = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHudTextWrap.LINE_SPACING = 1.05 -- écart entre les 2 lignes, en hauteur de police
ADHudTextWrap.MIN_FONT_RATIO = 0.7 -- la police ne descend pas sous 70 % de sa taille

-- ------------------------------------------------------------------------------------------------------------
-- Découpe
-- ------------------------------------------------------------------------------------------------------------

-- largeur disponible depuis posX jusqu'au bord droit du HUD
function ADHudTextWrap.maxWidth(posX)
    local hud = AutoDrive.Hud
    if hud == nil or hud.posX == nil or hud.width == nil then
        return nil
    end
    return hud.posX + hud.width - (hud.gapWidth or 0) - posX
end

-- coupe en 2 lignes entre deux mots ; garde la coupe dont la ligne la plus large est la plus courte
function ADHudTextWrap.split(text, fontSize)
    local words = {}
    for word in string.gmatch(text, "%S+") do
        table.insert(words, word)
    end
    if #words < 2 then
        return { text }
    end
    local best, bestWidth = nil, math.huge
    for i = 1, #words - 1 do
        local first = table.concat(words, " ", 1, i)
        local second = table.concat(words, " ", i + 1, #words)
        local width = math.max(getTextWidth(fontSize, first), getTextWidth(fontSize, second))
        if width < bestWidth then
            best, bestWidth = { first, second }, width
        end
    end
    return best
end

-- lignes à afficher et taille de police
function ADHudTextWrap.layout(text, fontSize, maxWidth)
    if text == nil or text == "" or maxWidth == nil or maxWidth <= 0 or getTextWidth(fontSize, text) <= maxWidth then
        return { text }, fontSize
    end
    local lines = ADHudTextWrap.split(text, fontSize)
    local widest = 0
    for _, line in ipairs(lines) do
        widest = math.max(widest, getTextWidth(fontSize, line))
    end
    if widest > maxWidth then
        fontSize = math.max(fontSize * maxWidth / widest, fontSize * ADHudTextWrap.MIN_FONT_RATIO)
    end
    return lines, fontSize
end

-- ------------------------------------------------------------------------------------------------------------
-- Affichage
-- ------------------------------------------------------------------------------------------------------------

-- posY : ligne de base d'un texte d'une ligne (comme avant). Couleur et alignement déjà posés par l'appelant.
function ADHudTextWrap.render(posX, posY, fontSize, text)
    local lines, size = ADHudTextWrap.layout(text, fontSize, ADHudTextWrap.maxWidth(posX))
    if #lines == 1 then
        renderText(posX, posY, size, lines[1])
        return
    end
    local step = size * ADHudTextWrap.LINE_SPACING
    renderText(posX, posY + step / 2, size, lines[1])
    renderText(posX, posY - step / 2, size, lines[2])
end
