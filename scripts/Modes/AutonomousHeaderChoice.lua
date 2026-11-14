-- ============================================================================================================
-- FarmPilot : AutonomousHeaderChoice.lua
-- Mode Autonome, moissonneuse ou ensileuse équipée seule (ébauche 11/11) : quelle barre de coupe, et son changement.
--
-- Règle (11/11) :
-- - Ligne « Barre » du HUD (Hud/HudHarvester.lua) : une barre précise, ou « Auto » (défaut) = d'après la culture du
--   champ : coupe à blé pour le blé, coupe à maïs pour le maïs... (cultures que la barre sait couper, données du
--   jeu : Cutter, fruitTypeIndices ; pick-up : le jeu ne le dit pas, culture inconnue).
-- - Culture du champ : la plus présente sur le champ du marqueur de destination (points tous les CROP_STEP m
--   jusqu'à SAMPLE_RANGE m). Champ vide (labouré, pas semé) ou déjà récolté (chaumes) : culture inconnue, la barre la
--   plus proche.
-- - Barre qui ne sait pas couper la culture : jamais prise. Aucune barre pour cette culture : départ refusé, message.
-- - Barre attelée qui ne va pas (une autre est choisie, ou elle ne coupe pas la culture du champ) : barre sans
--   remorque, la moissonneuse la pose elle-même (AutonomousHeaderGround.lua) ; sinon elle la repose sur une remorque
--   vide là où elle est (fin de champ). Puis elle attend qu'un tracteur soit libre si la bonne barre est sur une
--   remorque (amenée au champ comme au départ), ou va la chercher si elle est par terre.
-- - Ligne « Barre suivante » : devient la ligne « Barre » au champ suivant (« Auto » compris).
-- - Moissonneuse et ensileuse : même règle (barres à l'avant, coupe à maïs ou bec d'ensileuse).
--
-- Branché par : Modes/AutonomousHeader.lua (findHeader : headerChoice, rank ; onStart : swapFor, cropName ;
-- startCollect : nearestMarkerId ; stade « backoff » : readyToDeliver). Enveloppes posées au chargement :
-- ADAutonomousManager.isFetchableFront (barres dans la liste « Barre »), ADAutonomousManager.frontToFetch (la barre
-- n'est pas un outil avant ordinaire), ADFrontFlow.applyNextFront (« Barre suivante »). Chargé par register.lua après
-- AutonomousHeaderSpot.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.SAMPLE_RANGE = 80       -- m autour du point du champ lu pour la culture
ADHeaderFlow.CROP_STEP = 8           -- m entre deux points lus

-- noms courts des barres dans les listes (catégories de la boutique du jeu)
if ADAutonomousManager.FUNCTION_BY_CATEGORY ~= nil then
    ADAutonomousManager.FUNCTION_BY_CATEGORY.CUTTERS = "cutter"
    ADAutonomousManager.FUNCTION_BY_CATEGORY.CORNHEADERS = "cornHeader"
    ADAutonomousManager.FUNCTION_BY_CATEGORY.FORAGEHARVESTERCUTTERS = "chopperHeader"
end

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function isGone(o)
    return o == nil or o.isDeleted or o.isDeleting
end

-- ------------------------------------------------------------------------------------------------------------
-- Culture du champ
-- ------------------------------------------------------------------------------------------------------------
local function markerPos(marker)
    if marker == nil then
        return nil
    end
    local wp = ADGraphManager.getWayPointById ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if wp ~= nil then
        return wp.x, wp.z
    end
    return marker.x, marker.z
end

local function fruitAt(x, z)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then
        return nil
    end
    local index, growth = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)
    if index == nil or index == 0 or growth == nil or growth == 0 then
        return nil
    end
    if FruitType ~= nil and (index == FruitType.MEADOW or index == FruitType.GRASS) then
        return nil
    end
    -- déjà récolté (chaumes) : plus rien à couper
    local ft = g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByIndex ~= nil and g_fruitTypeManager:getFruitTypeByIndex(index) or nil
    if ft ~= nil and ((type(ft.cutStates) == "table" and ft.cutStates[growth] == true) or (ft.cutState ~= nil and ft.cutState ~= 0 and ft.cutState == growth)) then
        return nil
    end
    return index
end

-- culture la plus présente sur le champ du marqueur de destination, ou nil
function ADHeaderFlow.fieldCrop(vehicle)
    if FSDensityMapUtil == nil or ADAutonomousManager.markerField == nil or ADAutonomousManager.fieldAt == nil then
        return nil
    end
    local sm = vehicle.ad.stateModule
    local x, z = markerPos(sm:getFirstMarker())
    if x == nil then
        return nil
    end
    local field, px, pz = ADAutonomousManager.markerField(vehicle, x, z)
    if field == nil then
        return nil
    end
    local count, best, bestCount = {}, nil, 0
    local r = 0
    while r <= ADHeaderFlow.SAMPLE_RANGE do
        local steps = r == 0 and 1 or math.max(8, math.floor(2 * math.pi * r / ADHeaderFlow.CROP_STEP))
        for k = 0, steps - 1 do
            local a = k / steps * 2 * math.pi
            local sx, sz = px + math.cos(a) * r, pz + math.sin(a) * r
            if ADAutonomousManager.sameField(ADAutonomousManager.fieldAt(sx, sz), field) then
                local fruit = fruitAt(sx, sz)
                if fruit ~= nil then
                    count[fruit] = (count[fruit] or 0) + 1
                    if count[fruit] > bestCount then
                        best, bestCount = fruit, count[fruit]
                    end
                end
            end
        end
        r = r + ADHeaderFlow.CROP_STEP
    end
    return best
end

function ADHeaderFlow.cropName(vehicle)
    local fruit = ADHeaderFlow.fieldCrop(vehicle)
    if fruit == nil or g_fruitTypeManager == nil then
        return "?"
    end
    local ft = g_fruitTypeManager:getFruitTypeByIndex(fruit)
    if ft ~= nil and ft.fillType ~= nil and ft.fillType.title ~= nil then
        return ft.fillType.title
    end
    return ft ~= nil and tostring(ft.name) or "?"
end

-- la barre coupe cette culture : true, false, ou nil (le jeu ne le dit pas)
function ADHeaderFlow.canCut(header, fruit)
    local spec = header ~= nil and header.spec_cutter or nil
    -- (12/11) le jeu range les cultures de la barre dans fruitTypeIndices (liste d'index)
    local list = spec ~= nil and (spec.fruitTypeIndices or spec.fruitTypes) or nil
    if list == nil or fruit == nil then
        return nil
    end
    local any = false
    for k, v in pairs(list) do
        any = true
        if v == fruit or (k == fruit and v == true) then
            return true
        end
    end
    if not any then
        return nil
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Barre voulue
-- ------------------------------------------------------------------------------------------------------------
-- barre choisie dans la ligne « Barre » (ou nil = auto), culture du champ (auto seulement)
function ADHeaderFlow.headerChoice(combine)
    local sm = combine.ad.stateModule
    local chosen = sm.getFpFrontTool ~= nil and sm:getFpFrontTool() or nil
    if chosen ~= nil and ADHeaderFlow.isHeader(chosen) and not isGone(chosen) then
        return chosen, nil
    end
    return nil, ADHeaderFlow.fieldCrop(combine)
end

-- rang pour findHeader : 0 coupe la culture, 1 culture ou barre inconnue, nil ne la coupe pas
function ADHeaderFlow.rank(header, crop)
    if crop == nil then
        return 1
    end
    local can = ADHeaderFlow.canCut(header, crop)
    if can == true then
        return 0
    elseif can == false then
        return nil
    end
    return 1
end

-- barre attelée à changer : la barre à prendre à la place, ou nil
function ADHeaderFlow.swapFor(combine, header)
    local chosen, crop = ADHeaderFlow.headerChoice(combine)
    if chosen ~= nil then
        if chosen ~= header and (chosen.getAttacherVehicle == nil or chosen:getAttacherVehicle() == nil) then
            return chosen
        end
        return nil
    end
    if crop == nil or ADHeaderFlow.canCut(header, crop) ~= false then
        return nil
    end
    local found = ADHeaderFlow.findHeader(combine, true)
    return found ~= nil and found.header or nil
end

-- changement de barre : la bonne barre est là et, si elle est sur une remorque, un tracteur est libre
function ADHeaderFlow.readyToDeliver(combine)
    local found = ADHeaderFlow.findHeader(combine)
    if found == nil then
        return true -- plus de barre : le départ habituel donne le message
    end
    return found.trailer == nil or ADHeaderFlow.tractorFor(found.trailer, combine, true) ~= nil -- (à chaque image : sans journal)
end

-- marqueur le plus proche de la moissonneuse (index de marqueur), pour la remorque appelée
function ADHeaderFlow.nearestMarkerId(vehicle)
    local markers = ADGraphManager.getMapMarkers ~= nil and ADGraphManager:getMapMarkers() or nil
    if markers == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local best, bestD = nil, math.huge
    for index, m in pairs(markers) do
        local mx, mz = markerPos(m)
        if mx ~= nil then
            local d = MathUtil.vector2Length(mx - x, mz - z)
            if d < bestD then
                best, bestD = m.markerIndex or index, d
            end
        end
    end
    return best
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes
-- ------------------------------------------------------------------------------------------------------------
-- liste « Barre » : les barres de la ferme, dételées (sur une remorque ou par terre), qui vont à l'avant
local baseFetchableFront = ADAutonomousManager.isFetchableFront
function ADAutonomousManager.isFetchableFront(vehicle, tool)
    if ADHeaderFlow.isCombine(vehicle) then
        if not ADHeaderFlow.isHeader(tool) or isGone(tool) or tool == vehicle then
            return false
        end
        if tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() ~= nil then
            return false
        end
        if vehicle.getOwnerFarmId ~= nil and tool.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() ~= tool:getOwnerFarmId() then
            return false
        end
        return ADAutonomousManager.matchFrontJoints(vehicle, tool, false) ~= nil
    end
    return baseFetchableFront ~= nil and baseFetchableFront(vehicle, tool) or false
end

-- moissonneuse : la barre suit son propre déroulement (AutonomousHeader.lua), pas celui des outils avant
if ADAutonomousManager.frontToFetch ~= nil then
    local baseFrontToFetch = ADAutonomousManager.frontToFetch
    function ADAutonomousManager.frontToFetch(vehicle)
        if ADHeaderFlow.isCombine(vehicle) then
            return nil
        end
        return baseFrontToFetch(vehicle)
    end
end

-- « Barre suivante » devient « Barre » au champ suivant, « Auto » compris
if ADFrontFlow ~= nil and ADFrontFlow.applyNextFront ~= nil then
    local baseApplyNextFront = ADFrontFlow.applyNextFront
    function ADFrontFlow.applyNextFront(vehicle)
        if ADHeaderFlow.isCombine(vehicle) then
            local sm = vehicle.ad.stateModule
            if sm.getFpNextFrontTool ~= nil then
                local nextHeader = sm:getFpNextFrontTool()
                sm:setFpFrontTool(nextHeader)
                sm:setFpNextFrontTool(nil)
                log("%s : barre du champ suivant : %s", ADHeaderFlow.vehicleName(vehicle), nextHeader ~= nil and ADAutonomousManager.toolLabel(nextHeader) or "auto (culture)")
            end
            return
        end
        return baseApplyNextFront(vehicle)
    end
end
