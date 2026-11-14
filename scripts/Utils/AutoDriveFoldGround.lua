-- ============================================================================================================
-- FarmPilot : AutoDriveFoldGround.lua
-- Repli des outils : points « collés au sol » (GroundAdjustedNodes du jeu) remis en place même quand personne
-- n'est près du véhicule (14/11).
--
-- Le jeu ne recale ces points (rampe de pulvé qui suit le sol, par exemple Case IH Patriot 4450 :
-- boomRaycastLeftAdjust, boomRaycastRightAdjust, boomRaycastCenterAdjust) que si la caméra est à moins de
-- maxUpdateDistance du véhicule (100 m par défaut, GroundAdjustedNodes:onUpdate). Au repli, l'animation coupe le
-- suivi du sol (groundAdjustScale vers 0) et les points doivent revenir à leur place de transport. Joueur loin : ils
-- restent là où ils étaient au travail, les bras se replient sur des points décalés et la rampe finit en V, très
-- haute, alors que le jeu dit « replié à 100 % » (auvent du Phytosanitaire le 14/11, porte du hangar le 08/11).
-- Joueur dans le véhicule : le jeu les recale, la rampe se replie bien.
--
-- Règle : pendant que FarmPilot retient un départ (AutoDriveFoldGuard.lua), pour chaque outil du convoi qui a des
-- points collés au sol, que le jeu ne met pas à jour (caméra trop loin) et dont le suivi du sol est coupé ou en
-- train de l'être (repli en cours ou fait) : FarmPilot fait le calcul du jeu (updateGroundAdjustedRaycasts,
-- updateGroundAdjustedNode) et le départ attend que les points soient à leur place, 20 s au plus par outil.
-- Outil déplié au travail (suivi du sol entier) ou caméra assez près : rien, c'est le jeu qui s'en charge.
-- Une rampe déjà restée en V se remet droite au départ suivant.
--
-- Branché par une ligne dans ADFoldGuard.update (AutoDriveFoldGuard.lua). Chargé par register.lua après
-- AutoDriveFoldGuard.lua.
-- ============================================================================================================

ADFoldGround = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFoldGround.HOLD_MAX = 20000   -- ms au plus de départ retenu par outil (Patriot : 6 m au plus à 0,5 m/s = 12 s)
ADFoldGround.EPS = 0.001        -- m : écart sous lequel un point est à sa place

-- outil -> { since = ms, gaveUp = bool } tant que ses points ne sont pas en place
ADFoldGround.state = setmetatable({}, {__mode = "k"})

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local function nameOf(object)
    if ADFoldGuard ~= nil and ADFoldGuard.nameOf ~= nil then
        return ADFoldGuard.nameOf(object)
    end
    return "?"
end

-- l'outil a des points collés au sol et le jeu ne les met pas à jour (caméra plus loin que sa limite)
function ADFoldGround.isLeftAlone(object)
    local spec = object ~= nil and object.spec_groundAdjustedNodes or nil
    if spec == nil or spec.groundAdjustedNodes == nil or #spec.groundAdjustedNodes == 0 then
        return false
    end
    if object.updateGroundAdjustedNode == nil or object.updateGroundAdjustedRaycasts == nil then
        return false
    end
    local distance = object.currentUpdateDistance
    return distance ~= nil and spec.maxUpdateDistance ~= nil and distance >= spec.maxUpdateDistance
end

-- suivi du sol coupé, ou en train de l'être, sur au moins un point (repli en cours ou fait) : part d'animation
-- « groundAdjustScale » du repli (Patriot : 1 -> 0 dans les 2 premières secondes) ou limite de repli du point
-- (<foldable maxLimit="0.01"/>, Foldable:getIsGroundAdjustedNodeActive)
function ADFoldGround.isFolding(object, spec)
    for _, groundAdjustedNode in pairs(spec.groundAdjustedNodes) do
        if (groundAdjustedNode.activeScale or 1) < 1 then
            return true
        end
        if object.getIsGroundAdjustedNodeActive ~= nil and not object:getIsGroundAdjustedNodeActive(groundAdjustedNode) then
            return true
        end
    end
    return false
end

-- plus grand écart (m) entre un point et la place que le jeu lui donne
function ADFoldGround.gap(spec)
    local worst = 0
    for _, groundAdjustedNode in pairs(spec.groundAdjustedNodes) do
        for _, adjustNode in pairs(groundAdjustedNode.adjustNodes or {}) do
            if adjustNode.curY ~= nil and adjustNode.targetY ~= nil then
                worst = math.max(worst, math.abs(adjustNode.curY - adjustNode.targetY))
            end
        end
    end
    return worst
end

-- ------------------------------------------------------------------------------------------------------------
-- À chaque image tant que FarmPilot retient le départ (ADFoldGuard.update) ; rend true pour le retenir encore
-- ------------------------------------------------------------------------------------------------------------
function ADFoldGround.step(vehicle, objects, dt)
    local hold = false
    local now = g_time or 0
    for _, object in pairs(objects or {}) do
        if ADFoldGround.isLeftAlone(object) and ADFoldGround.isFolding(object, object.spec_groundAdjustedNodes) then
            local spec = object.spec_groundAdjustedNodes
            -- le calcul que fait GroundAdjustedNodes:onUpdate quand la caméra est assez près
            object:updateGroundAdjustedRaycasts(dt)
            for _, groundAdjustedNode in pairs(spec.groundAdjustedNodes) do
                object:updateGroundAdjustedNode(groundAdjustedNode, dt)
            end
            if object.raiseActive ~= nil then
                object:raiseActive() -- les bras suivent les points (pièces mobiles du jeu, Cylindered)
            end

            local gap = ADFoldGround.gap(spec)
            local st = ADFoldGround.state[object]
            if gap > ADFoldGround.EPS then
                if st == nil then
                    st = {since = now}
                    ADFoldGround.state[object] = st
                    print(string.format("[AD-Repli] %s: %s, points colles au sol pas recales par le jeu (camera a %.0f m, limite %.0f m) : FarmPilot les remet en place (ecart %.2f m)",
                        nameOf(vehicle), nameOf(object), object.currentUpdateDistance, spec.maxUpdateDistance, gap))
                end
                if now - st.since < ADFoldGround.HOLD_MAX then
                    hold = true
                elseif not st.gaveUp then
                    st.gaveUp = true
                    print(string.format("[AD-Repli] %s: %s, points colles au sol pas en place apres %.0f s (ecart %.2f m) : depart quand meme",
                        nameOf(vehicle), nameOf(object), (now - st.since) / 1000, gap))
                end
            elseif st ~= nil then
                print(string.format("[AD-Repli] %s: %s, points colles au sol en place apres %.1f s",
                    nameOf(vehicle), nameOf(object), (now - st.since) / 1000))
                ADFoldGround.state[object] = nil
            end
        end
    end
    return hold
end
