-- ============================================================================================================
-- FarmPilot : FollowCombineTaskChaseLine.lua
-- Complément de FollowCombineTask (tâche AutoDrive d'origine) : la ligne droite vers la place de poursuite.
-- Commun moissonneuse et ensileuse ; les réactions marquées (ensileuse) ne servent qu'à elle.
--
-- La poursuite d'AutoDrive roule tout droit vers sa place, sans trajet calculé. FarmPilot contrôle cette ligne toutes
-- les LINE_CHECK_INTERVAL ms : obstacle fixe (bâtiment, arbre, mur), zone interdite apprise, autre véhicule dessus,
-- sortie du champ, autre champ, culture debout (réglage « strict » et ensileuse : presque aucune culture admise).
-- Ligne bloquée : arrêt ; encore bloquée après LINE_BLOCKED_TIME : poursuite abandonnée, un trajet est calculé.
--
-- Historique :
--   23/10       petite enclave hors champ dans le champ (poteau) : traversable, le poteau reste un obstacle ;
--   24/10       plants isolés, bande oubliée, culture sur la trace de l'ensileuse : ne bloquent pas la ligne ;
--   24/10       (ensileuse) culture sur la ligne vers la place de côté : passer d'abord derrière elle ;
--   24/10 17:46 rouler dessus ou s'écarter, mais ne pas s'arrêter : bande étroite en travers franchie ;
--   25/10 14:25 bordure de champ possible si aucun obstacle : la ligne peut mordre la bordure du champ ;
--   25/10 16:22 mur non anticipé : (ensileuse) obstacle ou zone interdite vers une place de côté : ce
--               côté est condamné un moment et la place change (autre côté ou derrière) ;
--   25/10 22:34 ensileuse arrêtée, goulotte au-dessus de la bande d'herbe le long du champ : la ligne peut passer sur
--               cette bande (étendu le 27/10, champ 13, à l'ensileuse qui roule) ;
--   25/10 22:38 angle coupé : grosse difficulté près de l'ensileuse arrêtée, une pointe de culture
--               peut être coupée (CROP_TIP_LENGTH) ; la pointe d'un angle droit aussi (CORNER_CUT_*).
-- Autre cas noté (27/10 17:18, champ 13) : un autre véhicule sur la ligne : on l'attend (VEHICLE_WAIT_MAX au plus) au
-- lieu d'abandonner la poursuite.
--
-- Règle : FollowCombineTask.isChaseLineClear(vehicle, combine, chasePos, chaseSide) rend libre, raison. Elle sert aussi
-- à CatchCombinePipeTask (départ), DriveToVehicleTask et StepAsideTask ; FollowCombineCropGuard.lua l'enveloppe (il est
-- chargé après ce fichier). lineCollisionCallback sert aussi à PathFinderModule, CombineUnloaderMode et YTurn.
--
-- Branché par : FollowCombineTask:new (initLineCheck) et FollowCombineTask:followChasePoint (checkChaseLine).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- straight line to the chase point: checked every LINE_CHECK_INTERVAL, the chase is given up after LINE_BLOCKED_TIME blocked
FollowCombineTask.LINE_CHECK_INTERVAL = 500
FollowCombineTask.LINE_BLOCKED_TIME = 2000
-- checked from the vehicle itself: the crop just in front of the hood counts
FollowCombineTask.LINE_SKIP_START = 0
FollowCombineTask.LINE_SKIP_END = 3
FollowCombineTask.STRICT_LINE_MIN_LENGTH = 5 -- m checked ahead even when the chase point is closer (strict)
FollowCombineTask.STRICT_LINE_FRUIT_RATIO = 0.02 -- strict: almost no crop allowed on the chase line
FollowCombineTask.LINE_WIDTH_MARGIN = 0.5
-- small patch off the field inside it (power pole, 23/10): field ground within ENCLAVE_RADIUS in every direction.
-- The pole itself stays an obstacle for the box check
FollowCombineTask.ENCLAVE_RADIUS = 10
FollowCombineTask.BORDER_BITE = 3 -- m: field ground this close beside an off-field point of the line = the border bitten
-- 25/10 22:34: the standing harvester waits at a corner, its pipe over the grass strip beside the field: the
-- line to its place may run over that strip (no crop there, obstacles checked, not another field).
-- 27/10 17:10 (field 13, first row along the wall, pipe over the grass): the 7R stood on the strip 5 m from the crop,
-- its line to the place pointed at the field, and the probe beside the line (parallel to the wall) found no field
-- ground: "hors du champ" every 2 s. The probe now also looks along the line, and the strip beside a forage
-- harvester's field is accepted whether it stands or drives (the whole first row is unloaded from the strip)
FollowCombineTask.STANDING_BORDER_BITE = 12 -- m
FollowCombineTask.CROP_TIP_LENGTH = 12 -- m of crop (cover summed over the 4 m slices) the line may cross in great difficulty (25/10 22:38)
FollowCombineTask.CORNER_CUT_SLICES = 2 -- 4 m slices of crop allowed on the chase line (tip of a corner)
FollowCombineTask.CORNER_CUT_MAX_RATIO = 0.5 -- each partly covered only
FollowCombineTask.LINE_VEHICLE_MARGIN = 2.5 -- m beside the train width: the centre of another vehicle this close to the line blocks it
FollowCombineTask.LINE_VEHICLE_AHEAD = 3 -- m past the end of the checked line
FollowCombineTask.VEHICLE_WAIT_MAX = 60000 -- ms waited for a vehicle on the line before the chase is given up as before
FollowCombineTask.VEHICLE_WAIT_LOG = 10000

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place (appelée par FollowCombineTask:new)
-- ------------------------------------------------------------------------------------------------------------
function FollowCombineTask.initLineCheck(o)
    o.lineCheckTimer = 0
    o.lineClear = true
    o.lineBlockedTimer = AutoDriveTON:new()
    o.lineBlocked = false
end

-- ------------------------------------------------------------------------------------------------------------
-- La ligne droite est-elle libre ? (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
-- the chase drives straight to the chase point without a route: the straight line must be free of
-- buildings, trees and learned blocked zones (vehicles are ignored), never leave the field nor drive onto another
-- field, nor cross standing crop, whatever the setting. Returns clear, reason
function FollowCombineTask.isChaseLineClear(vehicle, combine, chasePos, chaseSide)
    if vehicle == nil or combine == nil or chasePos == nil then
        return true
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local dirX, dirZ = chasePos.x - vx, chasePos.z - vz
    local length = math.sqrt(dirX * dirX + dirZ * dirZ)
    -- strict: the whole line up to the chase point is checked, at least STRICT_LINE_MIN_LENGTH ahead, any real crop stops
    local strict = AutoDrive.getSetting("avoidFruit", vehicle) == "strict" and AutoDrive.isChopperUnloading(vehicle)
    local skipEnd = strict and 0 or FollowCombineTask.LINE_SKIP_END
    if strict and length < FollowCombineTask.STRICT_LINE_MIN_LENGTH then
        if length < 0.1 then
            local rx, _, rz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
            dirX, dirZ, length = rx, rz, 1
        end
        dirX, dirZ = dirX / length * FollowCombineTask.STRICT_LINE_MIN_LENGTH, dirZ / length * FollowCombineTask.STRICT_LINE_MIN_LENGTH
        length = FollowCombineTask.STRICT_LINE_MIN_LENGTH
    end
    local maxRatio = strict and FollowCombineTask.STRICT_LINE_FRUIT_RATIO or PathFinderModule.FRUIT_MAX_RATIO
    local checkLength = length - FollowCombineTask.LINE_SKIP_START - skipEnd
    if checkLength < 1 then
        return true
    end
    dirX, dirZ = dirX / length, dirZ / length
    local a = {x = vx + dirX * FollowCombineTask.LINE_SKIP_START, z = vz + dirZ * FollowCombineTask.LINE_SKIP_START}
    local b = {x = a.x + dirX * checkLength, z = a.z + dirZ * checkLength}
    local pathFinder = vehicle.ad.pathFinderModule
    local halfWidth = pathFinder:getTrainWidth() / 2 + FollowCombineTask.LINE_WIDTH_MARGIN
    local height = PathFinderModule.getTrainHeight(vehicle) + PathFinderModule.OBSTACLE_HEIGHT_MARGIN

    -- obstacles: same box as the pathfinder's route check
    local angleRad = AutoDrive.normalizeAngle(math.atan2(-dirZ, dirX))
    local midX, midZ = (a.x + b.x) / 2, (a.z + b.z) / 2
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, midX, 1, midZ)
    local probe = {hits = 0}
    probe.callback = FollowCombineTask.lineCollisionCallback
    overlapBox(midX, y + height / 2, midZ, 0, angleRad, 0, checkLength / 2, height / 2, halfWidth, "callback", probe, AutoDrive.collisionMaskTerrain, true, true, true, true)
    if probe.hits > 0 then
        return false, "obstacle"
    end
    if pathFinder:boxHitsBlockedZone(midX, midZ, angleRad, checkLength / 2, halfWidth) then
        return false, "zone interdite"
    end
    -- 27/10 17:18 (field 13): the MF, promoted, drove its chase line into the back of the full 7R that stood in the
    -- strip computing its exit. Another vehicle on the line (not the harvester, not the own train): the line is not
    -- free; followChasePoint waits for it instead of giving the chase up
    local other = FollowCombineTask.getVehicleOnLine(vehicle, combine, a, dirX, dirZ, checkLength, halfWidth)
    if other ~= nil then
        return false, "vehicule " .. tostring(other.getName ~= nil and other:getName() or "?")
    end

    local cx, _, cz = getWorldTranslation(combine.components[1].node)
    local combineField = PathFinderModule.getFieldAtPosition(cx, cz)
    -- field of the harvester: its connected field ground, as the pathfinder does in strict mode (map outlines of
    -- two neighbour fields can overlap at the border)
    local combineArea = PathFinderModule.getConnectedFieldArea(cx, cz)
    if combineArea ~= nil and combineArea.capped then
        combineArea = nil
    end
    local function isOtherField(x, z)
        if combineArea ~= nil then
            return not PathFinderModule.isInFieldArea(combineArea, x, z)
        end
        local field = combineField ~= nil and PathFinderModule.getFieldAtPosition(x, z) or nil
        return field ~= nil and field ~= combineField
    end
    local unloadMode = vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    -- standing forage harvester (it waits for this unloader): wider bite over the grass beside the field, and in great
    -- difficulty (no route twice from the same place) a tip of crop may be cut (25/10 22:34-22:38)
    local chopper = combine.ad ~= nil and combine.ad.isChopper == true
    local standing = chopper and math.abs(combine.lastSpeedReal or 0) < 0.0003
    local cropTip = standing and unloadMode ~= nil and unloadMode.cropTipUntil ~= nil and (g_time or 0) < unloadMode.cropTipUntil
    local sideX, sideZ = -dirZ * (halfWidth - FollowCombineTask.LINE_WIDTH_MARGIN), dirX * (halfWidth - FollowCombineTask.LINE_WIDTH_MARGIN)
    local slices = math.max(1, math.ceil(checkLength / 4))
    local cropSlices, cropName = {}, nil
    for k = 0, slices do
        local px, pz = a.x + (b.x - a.x) * k / slices, a.z + (b.z - a.z) * k / slices
        -- same rule as the pathfinder along the border (strict): the centre stays on the field of the harvester,
        -- the sides of the train may be on the grass beside it, never on another field
        -- the harvester drove there: same ground, the tractor may follow (CP turn beyond the border, or the outline
        -- of a neighbour field overlapping its track, sim 24/10 "autre champ")
        local onTrail = unloadMode ~= nil and unloadMode.isOnCombineTrail ~= nil and unloadMode:isOnCombineTrail(px, pz)
        local borderBite = false
        if not AutoDrive.checkIsOnField(px, 0, pz) and not FollowCombineTask.isFieldEnclave(px, pz) then
            if onTrail then
                if not vehicle.ad.offFieldTrailLogged then
                    vehicle.ad.offFieldTrailLogged = true
                    print(string.format("[AD-Poursuite] %s: ligne hors du champ vers %.0f,%.0f mais sur la trace de l'ensileuse, je suis", tostring(vehicle:getName()), px, pz))
                end
            else
                -- 25/10 14:25, field border allowed if no obstacle: the line may bite the border (field
                -- ground within BORDER_BITE m beside the point; the obstacles were checked above). The MF 7S.210 stood
                -- 40 m behind the standing harvester, aligned, and gave the chase up for an axis 1-2 m over the border
                local bite = FollowCombineTask.getBorderBite(px, pz, -dirZ, dirX)
                if bite == nil and chopper then
                    -- grass strip beside the field of the forage harvester (standing or driving, 27/10): field ground
                    -- within STANDING_BORDER_BITE m beside or along the line, no standing crop at the point
                    local wide = FollowCombineTask.getBorderBite(px, pz, -dirZ, dirX, FollowCombineTask.STANDING_BORDER_BITE, dirX, dirZ)
                    if wide ~= nil and PathFinderModule.readCropAt ~= nil and PathFinderModule.readCropAt(px, pz) == 0 then
                        bite = wide
                    end
                end
                if bite == nil then
                    return false, "hors du champ"
                end
                borderBite = true
                if vehicle.ad.borderBiteLogged == nil or (g_time or 0) - vehicle.ad.borderBiteLogged > 30000 then
                    vehicle.ad.borderBiteLogged = g_time or 0
                    print(string.format("[AD-Poursuite] %s: ligne qui mord la bordure du champ vers %.0f,%.0f (champ a %.0f m, pas d'obstacle%s), acceptee", tostring(vehicle:getName()), px, pz, bite, bite > FollowCombineTask.BORDER_BITE and (standing and ", herbe a cote de l'ensileuse arretee" or ", herbe a cote de l'ensileuse") or ""))
                end
            end
        end
        if not onTrail and not borderBite and isOtherField(px, pz) then
            return false, "autre champ"
        end
        for _, side in ipairs({-1, 1}) do
            local sx, sz = px + sideX * side, pz + sideZ * side
            if not onTrail and AutoDrive.checkIsOnField(sx, 0, sz) and isOtherField(sx, sz) then
                return false, "autre champ"
            end
        end
        -- standing crop: same rule as the route check, more than FRUIT_MAX_RATIO of a 4 m stretch at the train width
        -- 24/10: crop on the harvester's own trail does not stop the tractor
        if k < slices and not onTrail then
            local ex, ez = a.x + (b.x - a.x) * (k + 1) / slices, a.z + (b.z - a.z) * (k + 1) / slices
            for _, fruitType in pairs(g_fruitTypeManager:getFruitTypes()) do
                if fruitType.index ~= FruitType.MEADOW and fruitType.index ~= FruitType.GRASS then
                    local ratio = PathFinderModule.getFruitRatio(fruitType.index, px + sideX, pz + sideZ, ex + sideX, ez + sideZ, px - sideX, pz - sideZ)
                    if ratio > maxRatio and PathFinderModule.isOnlyIsolatedCropIn(px + sideX, pz + sideZ, ex + sideX, ez + sideZ, px - sideX, pz - sideZ) then
                        -- isolated plants / leftover strip on the chase line: ignored (24/10)
                        if not vehicle.ad.islandIgnoredLogged then
                            vehicle.ad.islandIgnoredLogged = true
                            print(string.format("[AD-Poursuite] %s: ilot de %s sur la ligne droite vers %.0f,%.0f ignore", tostring(vehicle:getName()), tostring(fruitType.name), px, pz))
                        end
                        ratio = 0
                    end
                    if ratio > maxRatio then
                        table.insert(cropSlices, {k = k, ratio = ratio})
                        cropName = fruitType.name
                        break
                    end
                end
            end
        end
    end
    if #cropSlices > 0 then
        -- the tip of a right-angle corner may be cut. Only that: crop on at most CORNER_CUT_SLICES consecutive
        -- 4 m slices, each partly covered (the corner point, not a crop block across the line)
        local tip = #cropSlices <= FollowCombineTask.CORNER_CUT_SLICES
        for i, c in ipairs(cropSlices) do
            if c.ratio > FollowCombineTask.CORNER_CUT_MAX_RATIO or (i > 1 and c.k ~= cropSlices[i - 1].k + 1) then
                tip = false
            end
        end
        -- 24/10 17:46 (drive over it or swerve, never stop): a narrow band of crop across
        -- the line (one 4 m slice, clear after it up to the place) is crossed
        local band = #cropSlices == 1 and cropSlices[1].k < slices - 1
        -- great difficulty near the standing harvester (25/10 22:38): a tip of crop
        -- of CROP_TIP_SLICES consecutive slices at most, whatever their cover, may be crossed
        local cropLength = 0
        for _, c in ipairs(cropSlices) do
            cropLength = cropLength + c.ratio * 4
        end
        if not tip and cropTip and cropLength <= FollowCombineTask.CROP_TIP_LENGTH then
            local consecutive = true
            for i = 2, #cropSlices do
                if cropSlices[i].k ~= cropSlices[i - 1].k + 1 then
                    consecutive = false
                end
            end
            if consecutive then
                if not vehicle.ad.cropTipLogged then
                    vehicle.ad.cropTipLogged = true
                    print(string.format("[AD-Poursuite] %s: grosse difficulte pres de l'ensileuse arretee, la ligne droite coupe une pointe de %s (%.0f m), autorise", tostring(vehicle:getName()), tostring(cropName), cropLength))
                end
                return true
            end
        end
        if not cropTip then
            vehicle.ad.cropTipLogged = false
        end
        if not tip and band then
            if not vehicle.ad.bandCrossLogged then
                vehicle.ad.bandCrossLogged = true
                print(string.format("[AD-Poursuite] %s: bande etroite de %s en travers de la ligne, je roule dessus", tostring(vehicle:getName()), tostring(cropName)))
            end
            return true
        end
        vehicle.ad.bandCrossLogged = false
        if not tip then
            return false, "culture " .. tostring(cropName)
        end
        if not vehicle.ad.cornerCutLogged then
            vehicle.ad.cornerCutLogged = true
            print(string.format("[AD-Poursuite] %s: ligne droite coupe la pointe de l'angle (%d m), autorise", tostring(vehicle:getName()), #cropSlices * 4))
        end
    else
        vehicle.ad.cornerCutLogged = false
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Outils de la ligne
-- ------------------------------------------------------------------------------------------------------------
-- off-field point of the chase line with field ground within BORDER_BITE m across the line: the line only bites the
-- border (25/10 14:25: allowed if no obstacle). Returns the distance to the field ground,
-- nil when there is none
function FollowCombineTask.getBorderBite(x, z, nx, nz, maxBite, dx, dz)
    for d = 1, maxBite or FollowCombineTask.BORDER_BITE do
        for _, side in ipairs({-1, 1}) do
            if AutoDrive.checkIsOnField(x + nx * d * side, 0, z + nz * d * side) then
                return d
            end
            -- along the line too (27/10): the line from the grass strip into the field
            if dx ~= nil and AutoDrive.checkIsOnField(x + dx * d * side, 0, z + dz * d * side) then
                return d
            end
        end
    end
    return nil
end

function FollowCombineTask.isFieldEnclave(x, z)
    for k = 0, 7 do
        local a = k * math.pi / 4
        local dx, dz = math.sin(a), math.cos(a)
        local found = false
        for d = 2, FollowCombineTask.ENCLAVE_RADIUS, 2 do
            if AutoDrive.checkIsOnField(x + dx * d, 0, z + dz * d) then
                found = true
                break
            end
        end
        if not found then
            return false
        end
    end
    return true
end

function FollowCombineTask.getVehicleOnLine(vehicle, combine, a, dirX, dirZ, checkLength, halfWidth)
    if AutoDrive.getAllVehicles == nil then
        return nil
    end
    local myRoot = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    local combineRoot = combine ~= nil and combine.getRootVehicle ~= nil and combine:getRootVehicle() or combine
    local margin = halfWidth + FollowCombineTask.LINE_VEHICLE_MARGIN
    for _, v in pairs(AutoDrive.getAllVehicles()) do
        if v ~= nil and v.components ~= nil and v.components[1] ~= nil and v ~= vehicle and v ~= combine then
            local root = v.getRootVehicle ~= nil and v:getRootVehicle() or v
            if root ~= myRoot and root ~= combineRoot then
                local x, _, z = getWorldTranslation(v.components[1].node)
                local rx, rz = x - a.x, z - a.z
                local along = rx * dirX + rz * dirZ
                local across = math.abs(rx * (-dirZ) + rz * dirX)
                if along > -1 and along < checkLength + FollowCombineTask.LINE_VEHICLE_AHEAD and across < margin then
                    return v
                end
            end
        end
    end
    return nil
end

function FollowCombineTask.lineCollisionCallback(probe, transformId)
    if transformId ~= 0 and transformId ~= g_currentMission.terrainRootNode then
        -- vehicles are left to the chase as before (combine, other unloaders), only fixed objects count
        local object = g_currentMission:getNodeObject(transformId)
        if object == nil or object.rootVehicle == nil then
            probe.hits = probe.hits + 1
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Dans la poursuite : ligne bloquée (appelée au début de FollowCombineTask:followChasePoint)
-- ------------------------------------------------------------------------------------------------------------
-- vrai = cette image est traitée (arrêt, attente ou changement de place), followChasePoint s'arrête là
function FollowCombineTask:checkChaseLine(dt)
    -- (rouler à côté de l'ensileuse : remis à faux à chaque image, voir FollowCombineTaskChopperDrive.lua)
    self.rollingNow = false
    if self.combineInTurn then
        -- combine turning: no line check, a blocked line must not end the chase during the turn
        self.lineCheckTimer = 0
        self.lineClear = true
        self.lineBlockedTimer:timer(false, FollowCombineTask.LINE_BLOCKED_TIME, dt)
    else
        self.lineCheckTimer = self.lineCheckTimer - dt
    end
    if self.lineCheckTimer < 0 then
        self.lineCheckTimer = FollowCombineTask.LINE_CHECK_INTERVAL
        local clear, reason = FollowCombineTask.isChaseLineClear(self.vehicle, self.combine, self.chasePos, self.chaseSide)
        self.lineBlockReason = reason
        if not clear and self.lineClear then
            print(string.format("[AD-Poursuite] %s: ligne droite vers la moissonneuse bloquee (%s), arret", FollowCombineTask.getLogName(self.vehicle), tostring(reason)))
        end
        self.lineClear = clear
    end
    -- 24/10: crop on the line to the side place: go behind the harvester first, before the island
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if not self.lineClear and self.lineBlockReason ~= nil and string.sub(self.lineBlockReason, 1, 7) == "culture"
        and self.combine.ad.isChopper and mode ~= nil and mode.isIslandRear ~= nil and not mode:isRearChaseHeld()
        and self.chaseSide ~= AutoDrive.CHASEPOS_REAR then
        mode.islandRearUntil = (g_time or 0) + CombineUnloaderMode.ISLAND_REAR_TIME
        print(string.format("[AD-Poursuite] %s: culture sur la ligne vers la place de cote, je passe derriere l'ensileuse", FollowCombineTask.getLogName(self.vehicle)))
        self.lineClear = true
        self.lineCheckTimer = 0
        self.lineBlockedTimer:timer(false, FollowCombineTask.LINE_BLOCKED_TIME, dt)
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return true
    end
    -- 25/10 16:22 (wall not anticipated): a fixed obstacle (wall, tree, building) or a learned blocked zone on
    -- the line to a side place: that side is condemned for a while and the place changes (other side or behind) instead
    -- of handing over to a new route to the same place every 2 s (the Puma along the stone wall, 15:21-15:23)
    if not self.lineClear and (self.lineBlockReason == "obstacle" or self.lineBlockReason == "zone interdite")
        and self.combine.ad.isChopper and mode ~= nil and mode.blockSide ~= nil
        and (self.chaseSide == AutoDrive.CHASEPOS_LEFT or self.chaseSide == AutoDrive.CHASEPOS_RIGHT) and not mode:isSideBlocked(self.chaseSide) then
        mode:blockSide(self.chaseSide, self.lineBlockReason)
        print(string.format("[AD-Poursuite] %s: %s sur la ligne vers la place de %s, ce cote est condamne %d s, je change de place (autre cote ou derriere)", FollowCombineTask.getLogName(self.vehicle), tostring(self.lineBlockReason), self.chaseSide == AutoDrive.CHASEPOS_LEFT and "gauche" or "droite", CombineUnloaderMode.SIDE_BLOCK_TIME / 1000))
        self.lineClear = true
        self.lineCheckTimer = 0
        self.lineBlockedTimer:timer(false, FollowCombineTask.LINE_BLOCKED_TIME, dt)
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return true
    end
    -- another vehicle on the line (27/10, the full unloader still leaving): wait for it, VEHICLE_WAIT_MAX at most
    if not self.lineClear and self.lineBlockReason ~= nil and string.sub(self.lineBlockReason, 1, 8) == "vehicule" then
        self.vehicleWaitSince = self.vehicleWaitSince or (g_time or 0)
        if (g_time or 0) - self.vehicleWaitSince < FollowCombineTask.VEHICLE_WAIT_MAX then
            if self.vehicleWaitLogged == nil or (g_time or 0) - self.vehicleWaitLogged >= FollowCombineTask.VEHICLE_WAIT_LOG then
                self.vehicleWaitLogged = g_time or 0
                print(string.format("[AD-Poursuite] %s: %s sur ma ligne vers la place, je m'arrete et j'attends qu'il parte (%d s)", FollowCombineTask.getLogName(self.vehicle), tostring(self.lineBlockReason), ((g_time or 0) - self.vehicleWaitSince) / 1000))
            end
            self.lineBlockedTimer:timer(false, FollowCombineTask.LINE_BLOCKED_TIME, dt)
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
            return true
        end
    else
        self.vehicleWaitSince = nil
        self.vehicleWaitLogged = nil
    end
    self.lineBlockedTimer:timer(not self.lineClear, FollowCombineTask.LINE_BLOCKED_TIME, dt)
    if not self.lineClear then
        if self.lineBlockedTimer:done() then
            print(string.format("[AD-Poursuite] %s: toujours bloque, poursuite abandonnee, recherche de chemin", FollowCombineTask.getLogName(self.vehicle)))
            self.lineBlocked = true
            self.state = FollowCombineTask.STATE_FINISHED
        end
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return true
    end
    return false
end
