-- ============================================================================================================
-- FarmPilot : ApproachModuleWidth.lua
-- Complément d'ApproachModule.lua : la largeur et la hauteur balayées pour les objets fixes.
--
-- Règle (16/11 18:59, Patriot 4450 dans une rue de village : coin de muret et bord de toit à côté de la ligne, sans
-- ligne [AD-Obst], le capteur avant a arrêté au dernier moment puis contournement au lieu de l'écart) : le balayage
-- de la route voit tout ce que l'attelage va toucher.
-- - Largeur : celle de l'attelage le plus large, rampes et outils repliés compris (ADPathCalculator.getPassageWidth :
--   tracteur à ses pneus, remorques à leur taille, outils repliables à leur largeur de transport), au moins la largeur
--   déclarée du véhicule de tête (celle des capteurs avant : un automoteur avec ses rampes repliées sur les côtés),
--   plus OBJECT_SIDE_MARGIN de chaque côté.
-- - Hauteur : de OBJECT_BOTTOM au-dessus du sol (herbe, bordures de trottoir basses) jusqu'au point le plus haut de
--   l'attelage plus OBJECT_TOP_MARGIN (bord de toit, auvent, coin de mur), sous les fils électriques.
-- - Mesures gardées DIM_REFRESH ms (dépliage, attelage d'un outil).
--
-- Branché par ApproachModule.lua : buildBoxes (getObjectScanShape).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADApproachModule.OBJECT_SIDE_MARGIN = 0.15  -- m ajoutés de chaque côté de la largeur de l'attelage
ADApproachModule.OBJECT_BOTTOM = 0.3        -- m au-dessus du sol : herbe, bordures et trottoirs bas ignorés
ADApproachModule.OBJECT_TOP_MARGIN = 0.3    -- m au-dessus du point le plus haut de l'attelage
ADApproachModule.OBJECT_MIN_HEIGHT = 3      -- m, hauteur d'attelage prise au moins
ADApproachModule.OBJECT_MAX_TOP = 4.8       -- m, haut de boîte au plus (les fils électriques passent au-dessus)
ADApproachModule.OBJECT_MIN_WIDTH = 2       -- m
ADApproachModule.OBJECT_MAX_WIDTH = 6       -- m, garde-fou contre une largeur déclarée dépliée
ADApproachModule.DIM_REFRESH = 2000         -- ms entre deux mesures de l'attelage

-- ------------------------------------------------------------------------------------------------------------
-- Mesures de l'attelage
-- ------------------------------------------------------------------------------------------------------------
-- largeur réelle de l'attelage le plus large (m), rampes repliées comprises
function ADApproachModule.getObjectScanWidth(vehicle)
    local width = 0
    if ADPathCalculator ~= nil and ADPathCalculator.getPassageWidth ~= nil then
        width = ADPathCalculator.getPassageWidth(vehicle) or 0
    end
    -- le véhicule de tête à sa largeur déclarée (automoteur : rampes repliées le long de la cabine), comme les capteurs
    if vehicle.size ~= nil and vehicle.size.width ~= nil then
        width = math.max(width, vehicle.size.width)
    end
    if width <= 0 then
        width = 3
    end
    return math.clamp(width, ADApproachModule.OBJECT_MIN_WIDTH, ADApproachModule.OBJECT_MAX_WIDTH)
end

-- hauteur du point le plus haut de l'attelage (m au-dessus du sol)
function ADApproachModule.getObjectScanHeight(vehicle)
    if PathFinderModule ~= nil and PathFinderModule.getTrainHeight ~= nil then
        return math.max(ADApproachModule.OBJECT_MIN_HEIGHT, PathFinderModule.getTrainHeight(vehicle) or 0)
    end
    local height = ADApproachModule.OBJECT_MIN_HEIGHT
    local vehicles = vehicle.getChildVehicles ~= nil and vehicle:getChildVehicles() or {vehicle}
    for _, v in pairs(vehicles) do
        if v.size ~= nil and v.size.height ~= nil then
            height = math.max(height, v.size.height)
        end
    end
    return height
end

-- forme de la boîte des objets fixes : demi-largeur, bas et haut au-dessus du sol (m), mesurée toutes les DIM_REFRESH ms
function ADApproachModule:getObjectScanShape()
    local now = g_time or 0
    if self.objectShape == nil or now - self.objectShape.time > ADApproachModule.DIM_REFRESH then
        local width = ADApproachModule.getObjectScanWidth(self.vehicle)
        local height = ADApproachModule.getObjectScanHeight(self.vehicle)
        local shape = {
            time = now,
            halfWidth = width * 0.5 + ADApproachModule.OBJECT_SIDE_MARGIN,
            bottom = ADApproachModule.OBJECT_BOTTOM,
            top = math.min(height + ADApproachModule.OBJECT_TOP_MARGIN, ADApproachModule.OBJECT_MAX_TOP)
        }
        local old = self.objectShape
        if old == nil or math.abs(old.halfWidth - shape.halfWidth) > 0.05 or math.abs(old.top - shape.top) > 0.05 then
            self:log("route scan for fixed objects: width %.2f m (train %.2f m), %.2f .. %.2f m above the ground",
                shape.halfWidth * 2, width, shape.bottom, shape.top)
        end
        self.objectShape = shape
    end
    return self.objectShape.halfWidth, self.objectShape.bottom, self.objectShape.top
end
