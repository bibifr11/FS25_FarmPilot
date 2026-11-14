-- ============================================================================================================
-- FarmPilot : HudAnchor.lua
-- Le bas du HUD reste là où le joueur l'a posé ; le HUD grandit et rétrécit seulement vers le haut (12/11).
--
-- Règles (12/11) :
-- - Le HUD change de hauteur selon le mode (3 lignes de listes, 4 avec benne ou moissonneuse, 6 en Autonome,
--   en-tête des astuces de l'éditeur). Le bas ne bouge pas : seules les lignes du haut s'ajoutent ou s'enlèvent.
-- - Le bas « voulu » (bas posé par le joueur à la souris, ou lu dans ses réglages) est gardé à part et
--   enregistré (AutoDrive.HudY). Avant, la position poussée vers le bas faute de place en haut était
--   enregistrée à la place : le HUD descendait un peu plus à chaque changement de mode et ne remontait jamais.
-- - Pas assez de place en haut de l'écran : le HUD descend juste ce qu'il faut, le temps d'être grand,
--   puis revient à son bas voulu quand il rétrécit.
-- - Pendant que le joueur le déplace, le bas voulu = ce qu'il voit (pas plus haut que ce qui tient à l'écran).
-- - Haut de l'écran : comme avant, l'en-tête entier doit tenir, avec 3 écarts de marge.
--
-- Branché par : Hud.lua (createHudAt : position du bas ; drawHud et toggleHudExtension : refaire le HUD depuis
-- le bas voulu). Chargé par register.lua après Hud.lua.
-- ============================================================================================================

ADHudAnchor = {}

-- ------------------------------------------------------------------------------------------------------------
-- Hauteurs
-- ------------------------------------------------------------------------------------------------------------

-- plus haut bas possible : le haut de l'en-tête (au-dessus des lignes) reste dans l'écran, avec 3 écarts de marge
-- (même calcul qu'avant). hud.height ne compte pas l'en-tête.
function ADHudAnchor.maxBottom(hud, height, headerHeight)
    return 1 - (height + 3 * hud.gapHeight + headerHeight)
end

-- plus petit HUD possible (3 lignes de listes, en-tête simple, sans astuces) : limite haute du bas voulu
function ADHudAnchor.smallestMaxBottom(hud, pullDownRows)
    local extraRows = math.max((pullDownRows or 3) - 3, 0)
    local height = hud.height - extraRows * (hud.borderY + hud.iconHeight)
    local header = hud.headerHeight
    if hud.isShowingTips and hud.headerExtensionHeight ~= nil then
        header = header - hud.headerExtensionHeight
    end
    return ADHudAnchor.maxBottom(hud, height, header)
end

-- ------------------------------------------------------------------------------------------------------------
-- Position
-- ------------------------------------------------------------------------------------------------------------

-- wantedY : bas demandé. Retourne le bas affiché ; garde le bas voulu dans hud.fpAnchorY.
function ADHudAnchor.place(hud, wantedY, pullDownRows)
    local low = 2 * hud.gapHeight
    local shownMax = math.max(ADHudAnchor.maxBottom(hud, hud.height, hud.headerHeight), low)
    local anchorMax = math.max(ADHudAnchor.smallestMaxBottom(hud, pullDownRows), low)
    if wantedY == nil then
        wantedY = hud.fpAnchorY or hud.posY or low
    end
    if hud.isMoving then
        -- déplacé à la souris : le bas voulu est celui qu'on voit
        anchorMax = shownMax
    end
    hud.fpAnchorY = math.clamp(wantedY, low, anchorMax)
    return math.min(hud.fpAnchorY, shownMax)
end

-- bas voulu pour refaire le HUD (changement de mode, d'échelle, astuces)
function ADHudAnchor.wanted(hud)
    return hud.fpAnchorY or hud.posY
end
