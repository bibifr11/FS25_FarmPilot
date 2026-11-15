-- ============================================================================================================
-- FarmPilot : DirtRoadAccessZone.lua
-- Route tertiaire : zone d'accès près de la destination et pénalité « raccourci » une fois par passage.
--
-- (15/11) Retour d'une benne vers « Champ 58 » : le carrefour devant l'entrée du champ et le point juste avant
-- lui étaient des points de route tertiaire, sur la route principale. La destination était 2 points plus loin :
-- pour le calcul, ces tertiaires n'étaient pas « l'accès à la destination » mais des raccourcis, et chaque segment
-- qui les touchait coûtait ACCESS_WEIGHT. La route directe en touchait 4, le grand tour par le nord 2 : la benne
-- faisait 2,9 km au lieu de 1,7 km.
--
-- Règles :
-- - Une route tertiaire à moins de NEAR_TARGET m de la destination (distance le long du réseau) compte comme
--   accès à la destination, comme celle qui est dessus ou juste au bout (la zone s'étend ensuite le long de cette
--   tertiaire, comme avant). Les routes d'accès ne sont pas concernées (seulement pour aller à leur point).
-- - La pénalité « raccourci » (ACCESS_WEIGHT) est comptée une fois par passage : en entrant sur une tertiaire hors
--   zone d'accès, pas à chaque segment. Un passage va de l'entrée sur la tertiaire jusqu'à la sortie ; les segments
--   tertiaires qui se suivent ne comptent qu'une fois.
-- - Une tertiaire coupée par un seul point d'une autre route (embranchement au milieu) reste une seule tertiaire
--   pour la zone d'accès.
--
-- Branché par : DirtRoadManager.lua (accessPoints x2, wrapDriveTime), une ligne chacun ; register.lua (chargé après
-- DirtRoadManager.lua).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADDirtRoads.NEAR_TARGET = 50    -- m le long du réseau : une tertiaire aussi proche de la destination est un accès

-- ------------------------------------------------------------------------------------------------------------
-- Zone d'accès : tertiaires près de la destination
-- ------------------------------------------------------------------------------------------------------------
-- ids des points de route tertiaire (pas route d'accès) à moins de NEAR_TARGET m de la destination, par le réseau
-- (dans les deux sens : la route peut y arriver par n'importe quel côté)
function ADDirtRoads.nearTargetSeeds(targetID)
    local seeds = {}
    local network = ADGraphManager:getWayPoints()
    local target = (network ~= nil and targetID ~= nil) and network[targetID] or nil
    if target == nil then
        return seeds
    end
    local best = { [targetID] = 0 }
    local queue = { target }
    local i = 1
    while queue[i] ~= nil do
        local p = queue[i]
        i = i + 1
        local d = best[p.id]
        local function visit(id)
            local n = network[id]
            if n ~= nil and n.x ~= nil then
                local nd = d + MathUtil.vector2Length(n.x - p.x, n.z - p.z)
                if nd <= ADDirtRoads.NEAR_TARGET and (best[id] == nil or nd < best[id]) then
                    best[id] = nd
                    queue[#queue + 1] = n
                end
            end
        end
        for _, id in pairs(p.out or {}) do visit(id) end
        for _, id in pairs(p.incoming or {}) do visit(id) end
    end
    for id in pairs(best) do
        local p = network[id]
        if ADDirtRoads.isDirt(p) and not (ADAccessRoads ~= nil and ADAccessRoads.isAccess(p)) then
            seeds[#seeds + 1] = id
        end
    end
    return seeds
end

-- ------------------------------------------------------------------------------------------------------------
-- Coût : pénalité « raccourci » à l'entrée sur la tertiaire seulement
-- ------------------------------------------------------------------------------------------------------------
-- segment a -> b : entre-t-il sur une tertiaire hors zone d'accès ?
function ADDirtRoads.throughEntry(a, b, access)
    local bThrough = ADDirtRoads.isDirt(b) and not access[b.id]
    local aThrough = ADDirtRoads.isDirt(a) and not access[a.id]
    return bThrough and not aThrough
end

-- ------------------------------------------------------------------------------------------------------------
-- Zone d'accès : une tertiaire coupée par un seul point d'une autre route (embranchement) continue
-- ------------------------------------------------------------------------------------------------------------
-- Exemple (Champ 3) : la tertiaire qui mène au champ a, au milieu, un point de route secondaire où part une autre
-- branche ; la zone d'accès s'arrêtait à ce point, et le bout de tertiaire d'avant comptait comme raccourci.
-- Règle : depuis un point de la zone, à travers UN point voisin qui n'est ni tertiaire ni route d'accès, la zone
-- continue sur les tertiaires voisines de ce point.
function ADDirtRoads.spreadGap(p, network, push)
    local function neighbours(q, f)
        for _, id in pairs(q.out or {}) do f(id) end
        for _, id in pairs(q.incoming or {}) do f(id) end
    end
    neighbours(p, function(id)
        local gap = network[id]
        if gap ~= nil and not ADDirtRoads.isDirt(gap) and not (ADAccessRoads ~= nil and ADAccessRoads.isAccess(gap)) then
            neighbours(gap, function(nid)
                local n = network[nid]
                if n ~= nil and n ~= p and ADDirtRoads.isDirt(n) and not (ADAccessRoads ~= nil and ADAccessRoads.isAccess(n)) then
                    push(nid, gap)
                end
            end)
        end
    end)
end
