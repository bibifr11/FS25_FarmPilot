-- ============================================================================================================
-- FarmPilot : AutoDriveFoldGuard.lua
-- Complément du repli des outils d'AutoDrive (AutoDrive:onUpdate dans Specialization.lua, AutoDrive.foldAllImplements
-- et AutoDrive.getAllImplementsFolded dans AutoDriveUtilFuncs.lua, réglage « Replier les outils »).
--
-- (08/11) Vérifier la fermeture des outils avant de partir : le tracteur partait parfois alors qu'ils n'étaient
-- pas fermés.
-- (08/11) La rampe du Case IH Patriot 4450 se replie mal, reste à la verticale,
-- très haute, et accroche la porte du hangar sur le trajet vers G_Epandeur.
--
-- Règle : à chaque départ (FarmPilot lancé, outil attelé, fin de chargement ou de déchargement), le tracteur reste
-- arrêté, moteur tournant :
--   1. tant qu'un outil bouge encore (repli ou dépli en cours, attelage qui monte ou descend, ordre de repli du jeu
--      en attente, par exemple celui de Courseplay en fin de champ), puis encore 1 s sans aucun mouvement ;
--   2. « Replier les outils » = oui : tant qu'un outil n'est pas complètement replié. Plus de départ au bout de
--      30 s : un repli arrêté en route est relancé vers la position route (l'ordre « bascule » d'AutoDrive ne fait
--      plus rien une fois la moitié du repli passée), l'outil est relevé d'abord si le jeu refuse de replier un outil
--      baissé ; tant qu'il ne se replie pas, message au joueur toutes les minutes ;
--   3. « Replier les outils » = non : un repli vu en cours puis arrêté en route est terminé (jamais de départ à moitié
--      replié) ; un outil déplié qui ne bouge pas reste tel quel (réglage respecté).
--
-- Appelé au début d'AutoDrive:onUpdate (Specialization.lua, une ligne), avant la mise à jour des tâches : il rend
-- « pas de mise à jour des tâches, arrêter le véhicule » tant qu'il retient le départ.
-- ============================================================================================================

ADFoldGuard = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADFoldGuard.MIN_WAIT = 1000       -- ms d'observation au moins à chaque départ (l'ordre de repli de Courseplay arrive après)
ADFoldGuard.SETTLE = 1000         -- ms sans aucun mouvement avant de partir
ADFoldGuard.STALL = 3000          -- ms sans mouvement d'un outil pas replié avant de relancer son repli (puis entre deux essais)
ADFoldGuard.LOGGED_TRIES = 3      -- relances écrites dans le log par outil et par départ (les suivantes avec le message)
ADFoldGuard.PENDING_MAX = 20000   -- ms pendant lesquelles un attelage qui bouge ou un ordre du jeu en attente retient le départ
ADFoldGuard.WARN_EVERY = 60000    -- ms entre deux messages au joueur (le premier après autant d'attente)
ADFoldGuard.SAMPLE = 250          -- ms entre deux lectures du temps d'animation de repli
ADFoldGuard.MOVE_EPS = 0.0001     -- variation du temps d'animation de repli entre deux lectures comptée comme un mouvement
ADFoldGuard.END_EPS = 0.01        -- tolérance aux bouts (replié, déplié, position intermédiaire)

-- ------------------------------------------------------------------------------------------------------------
-- Outils et états
-- ------------------------------------------------------------------------------------------------------------
function ADFoldGuard.nameOf(object)
    if object ~= nil and object.getName ~= nil then
        local ok, name = pcall(object.getName, object)
        if ok and name ~= nil then
            return tostring(name)
        end
    end
    return "?"
end

-- pourcentage replié (sens de travail -1 : replié à 1 ; sens +1 : replié à 0)
function ADFoldGuard.foldedPercent(spec)
    local t = spec.foldAnimTime or 0
    if (spec.turnOnFoldDirection or 1) < 0 then
        return math.floor(t * 100 + 0.5)
    end
    return math.floor((1 - t) * 100 + 0.5)
end

-- arrêté entre ses bouts : ni replié, ni déplié, ni à la position intermédiaire (rampe levée dépliée)
function ADFoldGuard.isBetween(spec)
    local t = spec.foldAnimTime or 0
    local e = ADFoldGuard.END_EPS
    if t <= e or t >= 1 - e then
        return false
    end
    return spec.foldMiddleAnimTime == nil or math.abs(t - spec.foldMiddleAnimTime) > e
end

function ADFoldGuard.isFoldAnimPlaying(object, spec)
    if object.getIsAnimationPlaying == nil then
        return false
    end
    for _, part in pairs(spec.foldingParts) do
        if part.animationName ~= nil and object:getIsAnimationPlaying(part.animationName) then
            return true
        end
    end
    return false
end

-- un attelage du convoi (avec un outil dessus) monte ou descend
function ADFoldGuard.isJointMoving(objects)
    for _, object in pairs(objects) do
        local spec = object.spec_attacherJoints
        if spec ~= nil and spec.attacherJoints ~= nil and spec.attachedImplements ~= nil then
            for _, implement in pairs(spec.attachedImplements) do
                local joint = implement.jointDescIndex ~= nil and spec.attacherJoints[implement.jointDescIndex] or nil
                if joint ~= nil and joint.isMoving then
                    return true
                end
            end
        end
    end
    return false
end

-- ordre du jeu en attente (repli « jusqu'au bout » demandé par Courseplay, pas encore accepté par l'outil)
function ADFoldGuard.isGameOrderPending(vehicle)
    local root = vehicle.rootVehicle or vehicle
    local controller = root.actionController
    if controller == nil or controller.actions == nil then
        return false
    end
    for _, action in pairs(controller.actions) do
        if action.forceDirectionUntilFinished ~= nil then
            return true
        end
    end
    return false
end

function ADFoldGuard.describe(guard)
    local parts = {}
    for object, _ in pairs(guard.parts) do
        if object.spec_foldable ~= nil then
            parts[#parts + 1] = string.format("%s replie a %d %%", ADFoldGuard.nameOf(object), ADFoldGuard.foldedPercent(object.spec_foldable))
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "pas d'outil repliable"
end

-- ------------------------------------------------------------------------------------------------------------
-- Relance du repli
-- ------------------------------------------------------------------------------------------------------------
function ADFoldGuard.raiseIfLowered(object)
    if object.getAttacherVehicle == nil or object.getIsLowered == nil then
        return false
    end
    local attacher = object:getAttacherVehicle()
    if attacher == nil or attacher.getAttacherJointIndexFromObject == nil or attacher.setJointMoveDown == nil or not object:getIsLowered() then
        return false
    end
    local index = attacher:getAttacherJointIndexFromObject(object)
    if index == nil then
        return false
    end
    attacher:setJointMoveDown(index, false)
    return true
end

-- ordre direct vers la position route (-sens de travail), sans « bascule » ni position intermédiaire
function ADFoldGuard.relaunchFold(vehicle, object, part, guard, now)
    local spec = object.spec_foldable
    local direction = -(spec.turnOnFoldDirection or 1)
    part.tries = part.tries + 1
    part.lastTry = now
    guard.tries = guard.tries + 1
    if vehicle.startMotor ~= nil and vehicle.getIsMotorStarted ~= nil and not vehicle:getIsMotorStarted() then
        vehicle:startMotor()
    end
    local allowed, warning = true, nil
    if object.getIsFoldAllowed ~= nil then
        allowed, warning = object:getIsFoldAllowed(direction, false)
    end
    local action
    if allowed and object.setFoldState ~= nil then
        if spec.foldMoveDirection == direction and not spec.moveToMiddle then
            -- ordre déjà donné mais l'animation est arrêtée : il faut l'arrêter pour le redonner
            object:setFoldState(0, false)
        end
        object:setFoldState(direction, false)
        part.reason = nil
        action = "je relance le repli vers la position route"
    elseif ADFoldGuard.raiseIfLowered(object) then
        part.reason = "outil baisse, je le releve d'abord"
        action = part.reason
    else
        part.reason = warning ~= nil and tostring(warning) or "repli refuse par le jeu"
        action = "repli refuse (" .. part.reason .. ")"
    end
    if part.tries <= ADFoldGuard.LOGGED_TRIES then
        print(string.format("[AD-Repli] %s: %s pas replie (%d %%), immobile depuis %.0f s : %s (essai %d)",
            ADFoldGuard.nameOf(vehicle), ADFoldGuard.nameOf(object), ADFoldGuard.foldedPercent(spec),
            (now - (part.lastMove or guard.armedAt)) / 1000, action, part.tries))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ retenu tant que les outils ne sont pas prêts
-- ------------------------------------------------------------------------------------------------------------
-- rend allowTaskUpdate, shouldStopVehicle (inchangés quand rien ne retient le départ)
function ADFoldGuard.update(vehicle, dt, allowTaskUpdate, shouldStopVehicle)
    local ad = vehicle.ad
    if ad == nil or ad.foldStartTime == nil then
        return allowTaskUpdate, shouldStopVehicle
    end
    local now = g_time or 0
    local guard = ad.foldGuard
    -- nouveau départ : AutoDrive.resetFoldState a remis l'heure de repli
    if ad.foldStartTime > 0 and (guard == nil or guard.armedFor ~= ad.foldStartTime) then
        guard = {armedFor = ad.foldStartTime, armedAt = now, parts = {}, active = true, tries = 0}
        ad.foldGuard = guard
    end
    if guard == nil or not guard.active then
        return allowTaskUpdate, shouldStopVehicle
    end

    local foldOn = AutoDrive.getSetting("FoldImplements", vehicle) == true
    local objects = AutoDrive.getAllImplements(vehicle, true) or {}
    local moving = false
    local blocking = {}
    for _, object in pairs(objects) do
        local spec = object.spec_foldable
        if spec ~= nil and spec.foldingParts ~= nil and #spec.foldingParts > 0 then
            local t = spec.foldAnimTime or 0
            local part = guard.parts[object]
            if part == nil then
                part = {refT = t, refTime = now, tries = 0}
                guard.parts[object] = part
            end
            if now - part.refTime >= ADFoldGuard.SAMPLE then
                part.wasMoving = math.abs(t - part.refT) > ADFoldGuard.MOVE_EPS
                part.refT, part.refTime = t, now
            end
            if part.wasMoving or ADFoldGuard.isFoldAnimPlaying(object, spec) then
                part.lastMove = now
                moving = true
                if (spec.foldMoveDirection or 0) ~= 0 and spec.foldMoveDirection ~= spec.turnOnFoldDirection and not spec.moveToMiddle then
                    part.sawFolding = true
                end
            end
            -- presses et ramasseuses : la logique d'AutoDrive (balles à poser d'abord) garde la main
            if not AutoDrive.isVehicleFolded(object) and object.spec_baler == nil and object.spec_baleLoader == nil
                and (foldOn or (part.sawFolding and ADFoldGuard.isBetween(spec))) then
                blocking[#blocking + 1] = object
            end
        end
    end
    if now - guard.armedAt < ADFoldGuard.PENDING_MAX and (ADFoldGuard.isJointMoving(objects) or ADFoldGuard.isGameOrderPending(vehicle)) then
        moving = true
    end
    if moving then
        guard.lastMove = now
    end

    for _, object in ipairs(blocking) do
        local part = guard.parts[object]
        if now - math.max(part.lastMove or guard.armedAt, part.lastTry or 0) >= ADFoldGuard.STALL then
            ADFoldGuard.relaunchFold(vehicle, object, part, guard, now)
        end
    end

    local settled = guard.lastMove == nil or now - guard.lastMove >= ADFoldGuard.SETTLE
    if not moving and settled and #blocking == 0 and now - guard.armedAt >= ADFoldGuard.MIN_WAIT then
        guard.active = false
        if guard.holdLogged or guard.tries > 0 then
            print(string.format("[AD-Repli] %s: outils prets apres %.1f s (%s), depart", ADFoldGuard.nameOf(vehicle), (now - guard.armedAt) / 1000, ADFoldGuard.describe(guard)))
        end
        return allowTaskUpdate, shouldStopVehicle
    end

    if not guard.holdLogged and now - guard.armedAt >= ADFoldGuard.MIN_WAIT + ADFoldGuard.SETTLE then
        guard.holdLogged = true
        local why = #blocking > 0 and string.format("%d outil(s) pas replie(s)", #blocking) or (moving and "outil ou attelage en mouvement" or "1 s apres le dernier mouvement")
        print(string.format("[AD-Repli] %s: depart retenu (%s ; %s)", ADFoldGuard.nameOf(vehicle), why, ADFoldGuard.describe(guard)))
    end
    if #blocking > 0 and now - guard.armedAt >= ADFoldGuard.WARN_EVERY and (guard.warnedAt == nil or now - guard.warnedAt >= ADFoldGuard.WARN_EVERY) then
        guard.warnedAt = now
        local object = blocking[1]
        local part = guard.parts[object]
        local txt = string.format(g_i18n:getText("AD_foldWait"), g_i18n:getText("AD_Driver_of"), ADFoldGuard.nameOf(vehicle),
            ADFoldGuard.nameOf(object), ADFoldGuard.foldedPercent(object.spec_foldable), part.reason ~= nil and (" : " .. part.reason) or "")
        print("[AD-Repli] " .. txt)
        AutoDriveMessageEvent.sendMessageOrNotification(vehicle, ADMessagesManager.messageTypes.WARN, txt, 10000)
    end

    -- arrêté moteur tournant : pas de coupure du moteur à l'arrêt pendant un repli
    local sdm = ad.specialDrivingModule
    if sdm ~= nil then
        sdm.motorShouldBeStopped = false
        if sdm.stoppedTimer ~= nil and sdm.stoppedTimer.timer ~= nil then
            sdm.stoppedTimer:timer(false)
        end
    end
    return false, true
end
