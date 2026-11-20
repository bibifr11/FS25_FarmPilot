-- ============================================================================================================
-- FarmPilot : FieldParkModuleSameField.lua
-- Complément de FieldParkModuleSearch.lua : la place d'attente de la benne reste dans le champ de la moissonneuse.
--
-- Historique : 20/11 (1.1.6.7, Lexion 6900 et Fendt 728) : aucune place près de l'entrée, la recherche élargie
-- « des deux côtés jusqu'à 145 m » a pris une place dans le champ voisin et le 728 est allé s'y garer.
--
-- Règle de base des bennes : jamais sur un autre champ (culture ou pas). Une place dont le centre est sur un autre
-- champ que celui de la moissonneuse, ou sur du sol non relié à son champ, est refusée (compte « other field »).
-- Même contrôle que la place sous la goulotte (ADPipePlaceGuard, CombineUnloaderModePlaceGuard.lua).
--
-- Branché par : FieldParkModuleSearch.lua (ADFieldPark.addCandidates, une ligne).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Champ de la moissonneuse, lu une fois par recherche
-- ------------------------------------------------------------------------------------------------------------
function ADFieldPark.getSearchField(search)
    if search.sameField == nil then
        search.sameField = false
        local harvester = search.harvester
        if harvester ~= nil and harvester.components ~= nil and ADPipePlaceGuard ~= nil and ADPipePlaceGuard.combineField ~= nil then
            local ok, field, area = pcall(ADPipePlaceGuard.combineField, harvester)
            if ok and (field ~= nil or area ~= nil) then
                search.sameField = {field = field, area = area}
            end
        end
    end
    return search.sameField or nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Place sur un autre champ : refusée
-- ------------------------------------------------------------------------------------------------------------
function ADFieldPark.isOtherField(search, x, z)
    if ADPipePlaceGuard == nil or ADPipePlaceGuard.otherFieldAt == nil then
        return false
    end
    local f = ADFieldPark.getSearchField(search)
    if f == nil then
        return false
    end
    if ADPipePlaceGuard.otherFieldAt(x, z, f.field, f.area) ~= nil then
        ADFieldPark.count(search, "other field")
        return true
    end
    return false
end
