-- ============================================================================================================
-- FarmPilot : FollowCombineCropGuard.lua
-- Complément de FollowCombineTask et CatchCombinePipeTask (benne qui suit une moissonneuse) : ne pas entrer dans la
-- culture debout, et prévenir le joueur quand la benne y est quand même bloquée.
--
-- Demande Fabien 08/11 19:52 (photo) : le 7R 350 (benne qui suit la LEXION 6900) est arrêté au milieu du blé debout,
-- message du jeu « Veuillez mettre le moteur en marche d'abord. », barre Courseplay visible.
--
-- Règle :
--   1. poursuite d'une moissonneuse (pas d'une ensileuse, qui a déjà sa ligne stricte) : la ligne droite vers la
--      place est aussi bloquée quand un bloc de culture debout est juste devant le tracteur dans cette direction
--      (de 2 à 10 m devant, largeur de l'attelage + 2 m de chaque côté, deux tranches de 4 m couvertes chacune à plus
--      de 60 %, lu en direct dans la carte de culture du jeu). Le tracteur s'arrête au bord et un trajet est calculé,
--      comme pour toute ligne bloquée. Une bande étroite, une pointe d'angle, une bande oubliée ou des pieds isolés
--      restent franchissables comme avant (ils ne couvrent pas 60 % de cette largeur sur 8 m) ;
--   2. benne arrêtée « BLOQUE » 3 fois de suite avec de la culture sous elle : message au joueur (toutes les minutes
--      au plus) : il faut la dégager à la main (AutoDrive coupe le moteur après le délai d'arrêt, 10 s par défaut).
--
-- Branché : FollowCombineTask.isChaseLineClear enveloppée au chargement (ce fichier est chargé après
-- FollowCombineTask.lua), une ligne dans CatchCombinePipeTask:tryNoWayWait.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
FollowCombineTask.CROP_BLOCK_START = 2          -- m devant le tracteur (repère du tracteur) où commence le contrôle
FollowCombineTask.CROP_BLOCK_SLICE = 4          -- m par tranche
FollowCombineTask.CROP_BLOCK_SLICES = 2         -- tranches couvertes de suite = bloc
FollowCombineTask.CROP_BLOCK_SIDE_MARGIN = 2    -- m de chaque côté de l'attelage
FollowCombineTask.CROP_BLOCK_RATIO = 0.6        -- part couverte de culture debout par tranche
CatchCombinePipeTask.STUCK_CROP_COUNT = 3           -- arrêts « BLOQUE » d'affilée avant de prévenir le joueur
CatchCombinePipeTask.STUCK_CROP_WARN_EVERY = 60000  -- ms entre deux messages
CatchCombinePipeTask.STUCK_CROP_RATIO = 0.3         -- culture sous l'attelage (8 m, largeur + 2 m) comptée « dans la culture »

-- ------------------------------------------------------------------------------------------------------------
-- Culture debout dans un rectangle (carte du jeu, lecture directe)
-- ------------------------------------------------------------------------------------------------------------
-- rectangle de x1,z1 à x2,z2 (axe), demi-largeur halfWidth : plus forte part couverte et nom de la culture
function FollowCombineTask.getStandingCropRatio(x1, z1, x2, z2, halfWidth)
    local dx, dz = x2 - x1, z2 - z1
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 0.1 then
        return 0, nil
    end
    local sideX, sideZ = -dz / l * halfWidth, dx / l * halfWidth
    local best, name = 0, nil
    for _, fruitType in pairs(g_fruitTypeManager:getFruitTypes()) do
        if fruitType.index ~= FruitType.MEADOW and fruitType.index ~= FruitType.GRASS then
            local ratio = PathFinderModule.getFruitRatio(fruitType.index, x1 + sideX, z1 + sideZ, x2 + sideX, z2 + sideZ, x1 - sideX, z1 - sideZ)
            if ratio > best then
                best, name = ratio, fruitType.name
            end
        end
    end
    return best, name
end

function FollowCombineTask.useCropBlockGuard(vehicle, combine)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.pathFinderModule ~= nil and combine ~= nil and combine.ad ~= nil
        and not combine.ad.isChopper and not AutoDrive.isChopperUnloading(vehicle)
end

-- bloc de culture debout devant le tracteur en allant vers (tx, tz) : nom de la culture, ou nil
-- (place à moins de 10 m : rien, le contrôle de la ligne d'origine suffit)
function FollowCombineTask.getCropBlockAhead(vehicle, tx, tz)
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local dx, dz = tx - vx, tz - vz
    local distance = math.sqrt(dx * dx + dz * dz)
    local reach = FollowCombineTask.CROP_BLOCK_START + FollowCombineTask.CROP_BLOCK_SLICE * FollowCombineTask.CROP_BLOCK_SLICES
    if distance < reach then
        return nil
    end
    dx, dz = dx / distance, dz / distance
    local halfWidth = vehicle.ad.pathFinderModule:getTrainWidth() / 2 + FollowCombineTask.CROP_BLOCK_SIDE_MARGIN
    local unloadMode = vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    local name = nil
    for k = 0, FollowCombineTask.CROP_BLOCK_SLICES - 1 do
        local d1 = FollowCombineTask.CROP_BLOCK_START + k * FollowCombineTask.CROP_BLOCK_SLICE
        local d2 = d1 + FollowCombineTask.CROP_BLOCK_SLICE
        local x1, z1, x2, z2 = vx + dx * d1, vz + dz * d1, vx + dx * d2, vz + dz * d2
        -- trace de la moissonneuse : déjà récoltée (règle du 24/10)
        if unloadMode ~= nil and unloadMode.isOnCombineTrail ~= nil and unloadMode:isOnCombineTrail((x1 + x2) / 2, (z1 + z2) / 2) then
            return nil
        end
        local ratio, fruit = FollowCombineTask.getStandingCropRatio(x1, z1, x2, z2, halfWidth)
        if ratio <= FollowCombineTask.CROP_BLOCK_RATIO then
            return nil
        end
        name = fruit
    end
    return name
end

-- culture debout sous l'attelage (8 m centrés sur le tracteur) : nom de la culture, ou nil
function FollowCombineTask.getCropUnderTrain(vehicle)
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local fx, _, fz = localDirectionToWorld(vehicle.components[1].node, 0, 0, 1)
    local halfWidth = vehicle.ad.pathFinderModule:getTrainWidth() / 2 + 1
    local ratio, name = FollowCombineTask.getStandingCropRatio(vx - fx * 4, vz - fz * 4, vx + fx * 4, vz + fz * 4, halfWidth)
    if ratio > CatchCombinePipeTask.STUCK_CROP_RATIO then
        return name
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Ligne droite vers la place : bloquée aussi par un bloc de culture juste devant
-- ------------------------------------------------------------------------------------------------------------
local isChaseLineClearBase = FollowCombineTask.isChaseLineClear

function FollowCombineTask.isChaseLineClear(vehicle, combine, chasePos, chaseSide)
    local clear, reason = isChaseLineClearBase(vehicle, combine, chasePos, chaseSide)
    if clear and chasePos ~= nil and FollowCombineTask.useCropBlockGuard(vehicle, combine) then
        local crop = FollowCombineTask.getCropBlockAhead(vehicle, chasePos.x, chasePos.z)
        if crop ~= nil then
            return false, string.format("culture %s devant le tracteur", tostring(crop))
        end
    end
    return clear, reason
end

-- ------------------------------------------------------------------------------------------------------------
-- Benne bloquée dans la culture : prévenir le joueur
-- ------------------------------------------------------------------------------------------------------------
function CatchCombinePipeTask:warnStuckInCrop(noRoute)
    if noRoute == nil or (noRoute.count or 0) < CatchCombinePipeTask.STUCK_CROP_COUNT or self.vehicle.ad.pathFinderModule == nil then
        return
    end
    local now = g_time or 0
    local last = self.vehicle.ad.stuckCropWarnedAt
    if last ~= nil and now - last < CatchCombinePipeTask.STUCK_CROP_WARN_EVERY then
        return
    end
    local crop = FollowCombineTask.getCropUnderTrain(self.vehicle)
    if crop == nil then
        return
    end
    self.vehicle.ad.stuckCropWarnedAt = now
    local txt = string.format(g_i18n:getText("AD_cropStuck"),
        g_i18n:getText("AD_Driver_of"), tostring(self.vehicle:getName()), tostring(crop))
    print("[AD-Fin] " .. txt)
    AutoDriveMessageEvent.sendMessageOrNotification(self.vehicle, ADMessagesManager.messageTypes.WARN, txt, 15000)
end
