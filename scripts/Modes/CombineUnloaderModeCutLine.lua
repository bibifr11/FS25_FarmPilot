-- ============================================================================================================
-- FarmPilot : CombineUnloaderModeCutLine.lua
-- Complément de CombineUnloaderMode, FollowCombineTask et EmptyHarvesterTask : la benne qui vide une MOISSONNEUSE
-- (pas l'ensileuse) garde le nez du tracteur derrière la ligne de coupe.
--
-- (16/11) Champ 52, LEXION 6900 + benne du 7R 350 : après la vidange, le nez de la benne était dans le blé debout
-- et elle n'a pas pu repartir (« decharge fini dans la culture »). Trois causes, toutes dans le placement au tuyau :
--   1. la place au tuyau met le point de remplissage de la remorque sous la goulotte, sans regarder où arrive le
--      tracteur : avec une goulotte avancée et une longue benne, le nez passait l'avant de la barre de coupe ;
--   2. pour une moissonneuse arrêtée, le trajet finit sur la place « de calcul » (planningPhase), une demi-longueur
--      de tracteur plus loin encore ;
--   3. pendant la vidange à l'arrêt (EmptyHarvesterTask), goulotte sans grain qui tombe = la benne avance tout droit,
--      jusqu'à 30 m de la moissonneuse (ce jour-là : 8 m de plus dans le blé).
--
-- Règle : pendant la vidange à côté d'une moissonneuse, le nez du tracteur (avant du tracteur et de ses outils avant)
-- ne dépasse jamais la ligne de coupe (avant de la barre de coupe) moins 1 m, quand il y a de la culture debout
-- devant lui dans son couloir au-delà de cette ligne. La place au tuyau est reculée d'autant ; s'il faudrait avancer
-- plus pour remplir l'avant de la benne, on n'avance pas (remplissage moins régulier accepté). Couloir du tracteur
-- sans culture au-delà de la ligne (côté chaume, bout du champ) : pas de borne, comme avant.
--
-- Branché par : CombineUnloaderMode.lua (getPipeChasePosition, branche moissonneuse), FollowCombineTask.lua
-- (followChasePoint), FollowCombinePipeHold.lua (holdUnderCombinePipe), EmptyHarvesterTask.lua (vidange à l'arrêt,
-- avance vers la goulotte).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
CombineUnloaderMode.CUT_LINE_MARGIN = 1.0        -- m : nez au plus à cette distance derrière l'avant de la coupe
CombineUnloaderMode.CUT_LINE_DRIVE_MARGIN = 0.5  -- m : en roulant, arrêt si le nez arrive à cette distance de la ligne
CombineUnloaderMode.CUT_LINE_CROP_START = 0.5    -- m après la ligne de coupe où commence la lecture de la culture
CombineUnloaderMode.CUT_LINE_CROP_LENGTH = 6     -- m de couloir lus au-delà de la ligne
CombineUnloaderMode.CUT_LINE_SIDE_MARGIN = 0.3   -- m de chaque côté du tracteur dans le couloir lu
CombineUnloaderMode.CUT_LINE_CROP_RATIO = 0.1    -- part de culture debout dans le couloir comptée « culture devant »
CombineUnloaderMode.CUT_LINE_MAX_LATERAL = 25    -- m : au-delà, le tracteur n'est pas à côté de la moissonneuse
CombineUnloaderMode.CUT_LINE_CACHE = 300         -- ms entre deux lectures de la culture
CombineUnloaderMode.CUT_LINE_LATCH = 3000        -- ms : la borne reste après la dernière culture vue (pas de va-et-vient)
CombineUnloaderMode.CUT_LINE_LOG_EVERY = 5000    -- ms entre deux lignes de journal pour la même borne

-- ------------------------------------------------------------------------------------------------------------
-- Moissonneuse concernée ?
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:usesCutLine()
    local combine = self.combine
    if combine == nil or combine.ad == nil or combine.components == nil or combine.components[1] == nil then
        return false
    end
    if combine.ad.isChopper or combine.ad.isAutoAimingChopper or combine.ad.isFixedPipeChopper or combine.ad.isSugarcaneHarvester
        or combine.ad.isReverseAttached then
        return false
    end
    if AutoDrive.isChopperUnloading ~= nil and self.vehicle ~= nil and AutoDrive.isChopperUnloading(self.vehicle) then
        return false
    end
    return self.vehicle ~= nil and self.vehicle.components ~= nil and self.vehicle.components[1] ~= nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Mesures
-- ------------------------------------------------------------------------------------------------------------
-- avant le plus avancé d'un véhicule (boîte size autour de sa racine), compté le long de l'axe de node
local function frontAlong(obj, node)
    if obj == nil or obj.size == nil or obj.components == nil or obj.components[1] == nil then
        return nil
    end
    local n = obj.components[1].node
    local half, off = (obj.size.length or 0) / 2, obj.size.lengthOffset or 0
    local best = nil
    for _, z in ipairs({ off + half, off - half }) do
        local wx, wy, wz = localToWorld(n, 0, 0, z)
        local _, _, lz = worldToLocal(node, wx, wy, wz)
        if best == nil or lz > best then
            best = lz
        end
    end
    return best
end

-- distance de la racine de la moissonneuse à l'avant de sa barre de coupe, le long de son axe
function CombineUnloaderMode.getCutLineAhead(combine)
    local node = combine.components[1].node
    local best = nil
    for _, implement in pairs(AutoDrive.getAllImplements(combine, false) or {}) do
        if implement ~= combine and implement.spec_cutter ~= nil then
            local f = frontAlong(implement, node)
            if f ~= nil and (best == nil or f > best) then
                best = f
            end
        end
    end
    if best == nil then
        -- coupe intégrée, ou pas de barre trouvée : l'avant de la machine elle-même
        best = frontAlong(combine, node) or ((combine.size ~= nil and combine.size.length or 10) / 2)
    end
    return best
end

-- distance de la racine du tracteur à son nez (outils attelés devant compris), le long de son axe
function CombineUnloaderMode.getNoseAhead(vehicle)
    local node = vehicle.components[1].node
    local best = frontAlong(vehicle, node) or ((vehicle.size ~= nil and vehicle.size.length or 6) / 2)
    for _, implement in pairs(AutoDrive.getAllImplements(vehicle, false) or {}) do
        if implement ~= vehicle and implement.components ~= nil and implement.components[1] ~= nil then
            local ix, iy, iz = getWorldTranslation(implement.components[1].node)
            local _, _, lz = worldToLocal(node, ix, iy, iz)
            if lz > 0 then
                local f = frontAlong(implement, node)
                if f ~= nil and f > best then
                    best = f
                end
            end
        end
    end
    return best
end

-- ligne de coupe de la moissonneuse : racine, axe, distance à l'avant de la coupe
function CombineUnloaderMode:getCutLine()
    local node = self.combine.components[1].node
    local x, _, z = getWorldTranslation(node)
    local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
    local l = math.sqrt(fx * fx + fz * fz)
    if l < 0.01 then
        return nil
    end
    fx, fz = fx / l, fz / l
    return { x = x, z = z, fx = fx, fz = fz, ahead = CombineUnloaderMode.getCutLineAhead(self.combine) }
end

-- culture debout dans le couloir du tracteur au-delà de la ligne de coupe (lat = décalage latéral, côté droit > 0)
function CombineUnloaderMode:hasCropBeyondCutLine(cut, lat)
    local now = g_time or 0
    local cache = self.cutLineCrop
    if cache ~= nil and now - cache.time < CombineUnloaderMode.CUT_LINE_CACHE and math.abs(cache.lat - lat) < 1
        and math.abs(cache.ahead - cut.ahead) < 0.5 then
        return cache.crop, cache.ratio, cache.fruit
    end
    -- côté droit de l'axe (fx, fz) : (fz, -fx)
    local sx, sz = cut.fz, -cut.fx
    local s1 = cut.ahead + CombineUnloaderMode.CUT_LINE_CROP_START
    local s2 = cut.ahead + CombineUnloaderMode.CUT_LINE_CROP_LENGTH
    local x1, z1 = cut.x + cut.fx * s1 + sx * lat, cut.z + cut.fz * s1 + sz * lat
    local x2, z2 = cut.x + cut.fx * s2 + sx * lat, cut.z + cut.fz * s2 + sz * lat
    local width = (self.vehicle.size ~= nil and self.vehicle.size.width) or 3
    local ratio, fruit = 0, nil
    if FollowCombineTask ~= nil and FollowCombineTask.getStandingCropRatio ~= nil then
        ratio, fruit = FollowCombineTask.getStandingCropRatio(x1, z1, x2, z2, width / 2 + CombineUnloaderMode.CUT_LINE_SIDE_MARGIN)
    end
    local crop = (ratio or 0) > CombineUnloaderMode.CUT_LINE_CROP_RATIO
    if crop then
        self.cutLineCropUntil = now + CombineUnloaderMode.CUT_LINE_LATCH
    elseif self.cutLineCropUntil ~= nil and now < self.cutLineCropUntil then
        -- culture vue il y a moins de 3 s : la borne reste
        crop = true
    end
    self.cutLineCrop = { time = now, lat = lat, ahead = cut.ahead, crop = crop, ratio = ratio or 0, fruit = fruit }
    return crop, ratio or 0, fruit
end

-- de combien le nez (noseX, noseZ) dépasse la ligne de coupe moins margin, culture debout devant ; nil = pas de borne
function CombineUnloaderMode:getCutLineExcess(noseX, noseZ, margin, cut)
    cut = cut or self:getCutLine()
    if cut == nil then
        return nil
    end
    local dx, dz = noseX - cut.x, noseZ - cut.z
    local along = dx * cut.fx + dz * cut.fz
    local lat = dx * cut.fz - dz * cut.fx
    local excess = along - (cut.ahead - margin)
    if excess <= 0 or math.abs(lat) > CombineUnloaderMode.CUT_LINE_MAX_LATERAL then
        return nil
    end
    local crop, ratio, fruit = self:hasCropBeyondCutLine(cut, lat)
    if not crop then
        return nil
    end
    return excess, cut, ratio, fruit
end

-- ------------------------------------------------------------------------------------------------------------
-- Place au tuyau bornée (accroche dans getPipeChasePosition, branche moissonneuse)
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:boundChaseToCutLine(chasePos, sideIndex, planningPhase)
    if chasePos == nil or sideIndex == AutoDrive.CHASEPOS_REAR or not self:usesCutLine() then
        return chasePos
    end
    local cut = self:getCutLine()
    if cut == nil then
        return chasePos
    end
    -- tracteur à la place, dans l'axe de la moissonneuse : son nez
    local nose = CombineUnloaderMode.getNoseAhead(self.vehicle)
    local excess, _, ratio, fruit = self:getCutLineExcess(chasePos.x + cut.fx * nose, chasePos.z + cut.fz * nose, CombineUnloaderMode.CUT_LINE_MARGIN, cut)
    local now = g_time or 0
    if excess == nil then
        -- journal seulement quand la culture a disparu (pas quand la place est déjà derrière la ligne)
        if self.cutLineBound ~= nil and self.cutLineCrop ~= nil and self.cutLineCrop.crop == false then
            print(string.format("[AD-Poursuite] %s: plus de culture devant le nez au-dela de la ligne de coupe de %s, place au tuyau sans borne",
                tostring(self.vehicle.getName ~= nil and self.vehicle:getName() or "?"), tostring(self.combine.getName ~= nil and self.combine:getName() or "?")))
            self.cutLineBound = nil
        end
        return chasePos
    end
    local bounded = { x = chasePos.x - cut.fx * excess, y = chasePos.y, z = chasePos.z - cut.fz * excess }
    local last = self.cutLineBound
    if last == nil or (now - last.time > CombineUnloaderMode.CUT_LINE_LOG_EVERY and math.abs(last.excess - excess) > 1) then
        print(string.format("[AD-Poursuite] %s: nez borne a la ligne de coupe de %s : place au tuyau reculee de %.1f m%s (avant de la coupe a %.1f m devant la machine, nez du tracteur a %.1f m de sa racine, marge %.1f m, culture %s %.0f %% devant) ; remplissage moins regulier accepte",
            tostring(self.vehicle.getName ~= nil and self.vehicle:getName() or "?"), tostring(self.combine.getName ~= nil and self.combine:getName() or "?"),
            excess, planningPhase and " (trajet)" or "", cut.ahead, nose, CombineUnloaderMode.CUT_LINE_MARGIN, tostring(fruit or "?"), (ratio or 0) * 100))
        self.cutLineBound = { time = now, excess = excess }
    end
    return bounded
end

-- ------------------------------------------------------------------------------------------------------------
-- En roulant : le nez réel du tracteur est-il à la ligne de coupe (culture debout devant) ?
-- ------------------------------------------------------------------------------------------------------------
function CombineUnloaderMode:isNoseAtCutLine()
    if not self:usesCutLine() then
        return false
    end
    local node = self.vehicle.components[1].node
    local x, _, z = getWorldTranslation(node)
    local hx, _, hz = localDirectionToWorld(node, 0, 0, 1)
    local l = math.sqrt(hx * hx + hz * hz)
    if l < 0.01 then
        return false
    end
    local nose = CombineUnloaderMode.getNoseAhead(self.vehicle)
    local excess = self:getCutLineExcess(x + hx / l * nose, z + hz / l * nose, CombineUnloaderMode.CUT_LINE_DRIVE_MARGIN)
    return excess ~= nil, excess
end

-- arrêt au lieu d'avancer (vidange à côté d'une moissonneuse) : true = arrêté ici, l'appelant ne roule pas
local function stopAtCutLine(owner, vehicle, dt, what)
    local mode = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or mode.isNoseAtCutLine == nil then
        return false
    end
    local atLine, excess = mode:isNoseAtCutLine()
    if not atLine then
        if owner.cutLineStopped then
            owner.cutLineStopped = nil
            print(string.format("[AD-Poursuite] %s: la ligne de coupe s'est eloignee, il avance de nouveau (%s)", tostring(vehicle:getName()), what))
        end
        return false
    end
    if not owner.cutLineStopped then
        owner.cutLineStopped = true
        print(string.format("[AD-Poursuite] %s: nez a %.1f m de la ligne de coupe (culture debout devant), il n'avance pas plus (%s)",
            tostring(vehicle:getName()), math.max(0, CombineUnloaderMode.CUT_LINE_DRIVE_MARGIN - (excess or 0)), what))
    end
    vehicle.ad.specialDrivingModule:stopVehicle()
    vehicle.ad.specialDrivingModule:update(dt)
    return true
end

-- poursuite (followChasePoint, place de côté) et maintien sous la goulotte (holdUnderCombinePipe)
function FollowCombineTask:stopAtCutLine(dt)
    if self.combine == nil or self.combine.ad == nil or self.combine.ad.isChopper or self.chaseSide == AutoDrive.CHASEPOS_REAR then
        return false
    end
    return stopAtCutLine(self, self.vehicle, dt, "poursuite")
end

-- vidange à l'arrêt : la benne avance vers la goulotte tant que rien ne tombe (EmptyHarvesterTask, STATE_UNLOADING)
function EmptyHarvesterTask:stopAtCutLine(dt)
    if self.combine == nil or self.combine.ad == nil or self.combine.ad.isChopper then
        return false
    end
    return stopAtCutLine(self, self.vehicle, dt, "vidange a l'arret")
end
