-- FarmPilot : CombineUnloaderModePlaceGuard.lua
-- ------------------------------------------------------------------------------------------------------------
-- (19/11) La place de la benne sous la goulotte reste dans le champ de la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- Champ 80 (1.1.5.0, 18:36) : la Lexion arrêtée au bord du champ, goulotte sortie au-dessus de la haie. La place au
-- tuyau tombait en (625, -70), dans le blé du champ voisin, à 9 m du bord. Le 7R y est allé (trajet « vers
-- moissonneuse » : la culture près de la goulotte est permise pour les dernières cases) puis la poursuite l'a gardé
-- sous la goulotte. Rien ne contrôlait la place elle-même : avec la moissonneuse arrêtée, getPipeChasePosition prend
-- la place de côté même quand ce côté est bloqué.
-- Règle de base des bennes : la benne reste dans le champ de la moissonneuse, jamais sur un autre champ (culture ou
-- pas) ; l'herbe du bord n'est permise qu'au ras du champ (BORDER_GRASS m, comme la ligne droite de poursuite).
-- Place de côté refusée (la place, les deux côtés de la remorque, l'avant et l'arrière) : place derrière la
-- moissonneuse, côté opposé à la goulotte, la benne attend dans le champ que la goulotte revienne au-dessus du champ.
-- Branché par register.lua (après CombineUnloaderMode.lua et CombineUnloaderModeCutLine.lua) : enveloppe
-- CombineUnloaderMode:getPipeChasePosition. Essai : simu/test_benne_place_autre_champ.lua.

ADPipePlaceGuard = ADPipePlaceGuard or {}
ADPipePlaceGuard.BORDER_GRASS = 3 -- m d'herbe permis au bord du champ de la moissonneuse (FollowCombineTask.BORDER_BITE)
ADPipePlaceGuard.ALONG = 4 -- m : avant et arrière de la remorque contrôlés autour de la place
ADPipePlaceGuard.CACHE_TIME = 1000 -- ms : même place (case de 2 m), même réponse
ADPipePlaceGuard.LOG_INTERVAL = 10000 -- ms

local function fieldIdAt(x, z)
    if PathFinderModule.getFieldIdAt ~= nil then
        local ok, id = pcall(PathFinderModule.getFieldIdAt, x, z)
        if ok then
            return id
        end
    end
    return nil
end

-- champ de la moissonneuse : son contour (getFieldAtPosition) et son sol relié (comme la ligne droite de poursuite)
function ADPipePlaceGuard.combineField(combine)
    local cx, _, cz = getWorldTranslation(combine.components[1].node)
    local field = PathFinderModule.getFieldAtPosition(cx, cz)
    local area = PathFinderModule.getConnectedFieldArea ~= nil and PathFinderModule.getConnectedFieldArea(cx, cz) or nil
    if area ~= nil and area.capped then
        area = nil
    end
    return field, area
end

-- sol du champ de la moissonneuse en x, z : nil si oui, sinon la raison
local function otherFieldAt(x, z, field, area)
    if not AutoDrive.checkIsOnField(x, 0, z) then
        return nil
    end
    local f = PathFinderModule.getFieldAtPosition(x, z)
    if field ~= nil and f ~= nil and f ~= field then
        return string.format("autre champ (%s)", tostring(fieldIdAt(x, z) or "?"))
    end
    if area ~= nil and PathFinderModule.isInFieldArea ~= nil and not PathFinderModule.isInFieldArea(area, x, z) then
        return "autre champ (sol non relié au champ de la moissonneuse)"
    end
    return nil
end
ADPipePlaceGuard.otherFieldAt = otherFieldAt -- aussi pour la place d'attente, voir FieldParkModuleSameField.lua

-- un point de la remorque : nil si permis, sinon la raison
function ADPipePlaceGuard.pointRefusal(x, z, field, area)
    if AutoDrive.checkIsOnField(x, 0, z) then
        return otherFieldAt(x, z, field, area)
    end
    -- hors du sol de champ : seulement l'herbe au ras du champ de la moissonneuse
    for d = 1, ADPipePlaceGuard.BORDER_GRASS do
        for _, dir in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {0.7071, 0.7071}, {0.7071, -0.7071}, {-0.7071, 0.7071}, {-0.7071, -0.7071}}) do
            local px, pz = x + dir[1] * d, z + dir[2] * d
            if AutoDrive.checkIsOnField(px, 0, pz) and otherFieldAt(px, pz, field, area) == nil then
                return nil
            end
        end
    end
    return string.format("hors du champ à plus de %d m du bord (haie, talus)", ADPipePlaceGuard.BORDER_GRASS)
end

-- place au tuyau (ou place de côté de l'ensileuse) : nil si permise, sinon la raison et le point refusé
function ADPipePlaceGuard.placeRefusal(mode, place)
    local combine = mode.combine
    local field, area = ADPipePlaceGuard.combineField(combine)
    local hx, _, hz = AutoDrive.localDirectionToWorld(combine, 0, 0, 1)
    local len = math.sqrt(hx * hx + hz * hz)
    if len < 0.001 then
        hx, hz, len = 0, 1, 1
    end
    hx, hz = hx / len, hz / len
    local half = 1.5
    if mode.vehicle ~= nil and mode.vehicle.size ~= nil and mode.vehicle.size.width ~= nil then
        half = mode.vehicle.size.width / 2
    end
    local along = ADPipePlaceGuard.ALONG
    local points = {
        {place.x, place.z},
        {place.x - hz * half, place.z + hx * half},
        {place.x + hz * half, place.z - hx * half},
        {place.x + hx * along, place.z + hz * along},
        {place.x - hx * along, place.z - hz * along}
    }
    for _, p in ipairs(points) do
        local why = ADPipePlaceGuard.pointRefusal(p[1], p[2], field, area)
        if why ~= nil then
            return why, p[1], p[2]
        end
    end
    return nil
end

local function cachedRefusal(mode, place)
    local key = string.format("%d,%d", math.floor(place.x / 2 + 0.5), math.floor(place.z / 2 + 0.5))
    local now = g_time or 0
    local c = mode.pipePlaceGuardCache
    if c ~= nil and c.key == key and c.combine == mode.combine and now >= c.t and now - c.t < ADPipePlaceGuard.CACHE_TIME then
        return c.why, c.x, c.z
    end
    local why, x, z = ADPipePlaceGuard.placeRefusal(mode, place)
    mode.pipePlaceGuardCache = {key = key, combine = mode.combine, t = now, why = why, x = x, z = z}
    return why, x, z
end

local getPipeChasePosition = CombineUnloaderMode.getPipeChasePosition
function CombineUnloaderMode:getPipeChasePosition(planningPhase)
    local node, side = getPipeChasePosition(self, planningPhase)
    self.pipePlaceRefused = nil
    if node == nil or side == AutoDrive.CHASEPOS_REAR or self.combine == nil or self.combine.components == nil
        or self.combine.components[1] == nil then
        return node, side
    end
    local why, wx, wz = cachedRefusal(self, node)
    if why == nil then
        return node, side
    end
    -- place derrière, côté opposé à la goulotte
    local rearX = self:getRearChaseOffsetX(side == AutoDrive.CHASEPOS_LEFT, side == AutoDrive.CHASEPOS_RIGHT)
    local rear = AutoDrive.createWayPointRelativeToVehicle(self.combine, rearX, self:getRearChaseOffsetZ(planningPhase))
    self.pipePlaceRefused = why
    self.chasePosIndex = AutoDrive.CHASEPOS_REAR
    local now = g_time or 0
    if self.pipePlaceLogT == nil or now < self.pipePlaceLogT or now - self.pipePlaceLogT > ADPipePlaceGuard.LOG_INTERVAL then
        self.pipePlaceLogT = now
        local name = self.vehicle ~= nil and self.vehicle.getName ~= nil and self.vehicle:getName() or "?"
        local cname = self.combine.getName ~= nil and self.combine:getName() or "?"
        print(string.format("[AD-Poursuite] %s: place sous la goulotte de %s en %.0f,%.0f refusée : %s en %.0f,%.0f ; la benne reste dans le champ de la moissonneuse (place derrière en %.0f,%.0f, attend que la goulotte revienne au-dessus du champ)",
            tostring(name), tostring(cname), node.x, node.z, why, wx or node.x, wz or node.z, rear.x, rear.z))
    end
    return rear, AutoDrive.CHASEPOS_REAR
end
