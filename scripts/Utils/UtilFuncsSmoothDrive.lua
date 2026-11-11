-- ============================================================================================================
-- FarmPilot : UtilFuncsSmoothDrive.lua
-- Complément de AutoDrive.driveInDirection (UtilFuncs.lua) : conduite douce, vitesse lissée, accélérateur dosé.
--
-- (11/11) Vitesse en dents de scie (4/6/4/6 km/h) dans les virages serrés au ralenti et pendant les manœuvres
-- (rangement d'outil, faucheuse). L'accélérateur d'origine est en tout ou rien : plein gaz jusqu'à la limite + 2 km/h
-- (+6 hors virage), puis frein jusqu'à la limite, puis plein gaz... Dans les manœuvres, la vitesse demandée était
-- divisée par 3 d'un coup dès que le point visé passait à plus de 20° sur le côté (plein gaz puis coupure).
--
-- Règle :
--   1. ralentissement selon l'angle du point visé PROGRESSIF (de 0,75 fois l'angle limite à 1,5 fois l'angle
--      limite) au lieu d'un seuil ; même vitesse au bout qu'avant ;
--   2. vitesse demandée lissée : une baisse est prise tout de suite (sécurité) et gardée 1,5 s ; elle ne remonte
--      qu'ensuite, en rampe (3 km/h par seconde). Une limite qui saute 4/6/4/6 donne 4 stable ;
--   3. accélérateur dosé selon l'écart entre la vitesse demandée et la vitesse prévue dans 2 s (un attelage lourd
--      continue d'accélérer après qu'on a levé le pied) : plein loin en dessous, 30 % en arrivant, presque relâché
--      si on va dépasser ; le limiteur du moteur (VehicleMotor:setSpeedLimit) tient la vitesse sans « plein gaz puis coupure ».
--      Jamais 0 en roulant (le jeu freine tout seul à accélérateur 0, WheelsUtil.updateWheelsPhysics) ; le freinage
--      reste celui de l'appelant ;
--   4. une petite réserve monte doucement si le tracteur reste en dessous (côte, outil lourd) et retombe ensuite.
-- Un arrêt (allowedToDrive faux, vitesse 0), un freinage demandé par l'appelant (accélération <= 0) et le suivi d'une
-- moissonneuse ou d'une ensileuse (la benne doit suivre la machine sans retard) passent tels quels.
--
-- Branché par une ligne dans UtilFuncs.lua : AutoDrive.driveInDirection.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages / constantes
-- ------------------------------------------------------------------------------------------------------------
AutoDrive.SMOOTH_DRIVE = true                 -- false = comportement d'origine
AutoDrive.SMOOTH_RAMP_UP = 3                  -- km/h par seconde : montée de la vitesse demandée
AutoDrive.SMOOTH_HOLD_MS = 1500               -- ms : une baisse de la vitesse demandée est gardée au moins ce temps
AutoDrive.SMOOTH_RAMP_START = 1               -- km/h au-dessus de la vitesse actuelle d'où repart la rampe
AutoDrive.SMOOTH_PEDAL_MIN = 0.3              -- accélérateur quand on arrive à la vitesse demandée
AutoDrive.SMOOTH_PEDAL_LOW = 0.08             -- accélérateur quand on va la dépasser (jamais 0)
AutoDrive.SMOOTH_ANTICIPATE = 2.0             -- s : on regarde la vitesse prévue (vitesse + accélération x ce temps)
AutoDrive.SMOOTH_PEDAL_GAIN = 0.2             -- accélérateur en plus par km/h d'écart (plein à 3 km/h en dessous)
AutoDrive.SMOOTH_BOOST_RATE = 0.15            -- réserve en plus par seconde passée en dessous (écart > 0,3 km/h)
AutoDrive.SMOOTH_BOOST_MAX = 0.5
AutoDrive.SMOOTH_RESET_MS = 1000              -- plus appelé depuis 1 s : on repart de la vitesse actuelle
AutoDrive.SMOOTH_SKIP_TASKS = {                -- suivi de moissonneuse / ensileuse : comportement d'origine
    CatchCombinePipeTask = true,
    HandleHarvesterTurnTask = true,
    DriveToVehicleTask = true,
}
AutoDrive.SMOOTH_NO_SLOW_ANGLE = 180          -- angle passé au jeu : son seuil d'origine ne joue plus

-- ------------------------------------------------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------------------------------------------------
-- angle (°) entre l'avant du tracteur et le point visé, calculé comme le jeu (AIVehicleUtil.driveInDirection)
function AutoDrive.smoothDriveTargetAngle(lx, lz)
    if lx == nil or lz == nil then
        return 0
    end
    local len = math.sqrt(lx * lx + lz * lz)
    if len < 0.0001 then
        return 0
    end
    local dot = math.max(-1, math.min(1, lz / len))
    return math.deg(math.acos(dot))
end

-- part (0 à 1) du ralentissement d'angle : 0 sous 0,75 fois l'angle limite, 1 à 1,5 fois l'angle limite
function AutoDrive.smoothDriveAngleShare(angle, slowAngleLimit)
    if slowAngleLimit == nil or slowAngleLimit <= 0 then
        return 0
    end
    local from = slowAngleLimit * 0.75
    local to = slowAngleLimit * 1.5
    return math.max(0, math.min(1, (angle - from) / (to - from)))
end

-- vrai si le tracteur suit ou rejoint une moissonneuse / ensileuse : là, la vitesse doit suivre la machine sans
-- retard, on garde le comportement d'origine
function AutoDrive.smoothDriveIsHarvesterFollow(vehicle)
    local tm = vehicle.ad.taskModule
    local task = tm ~= nil and tm.getActiveTask ~= nil and tm:getActiveTask() or nil
    if task == nil then
        return false
    end
    if AutoDrive.SMOOTH_SKIP_TASKS[task.taskType or ""] then
        return true
    end
    return FollowCombineTask ~= nil and type(task.class) == "function" and task:class() == FollowCombineTask
end

-- accélérateur pour un écart vitesse demandée - vitesse prévue dans 2 s (km/h) : plein loin en dessous, réduit près de la
-- vitesse, jamais sous SMOOTH_PEDAL_MIN (le limiteur du moteur tient la vitesse, le freinage reste à l'appelant)
function AutoDrive.smoothDrivePedal(err, boost, maxPedal)
    local pedal
    if err < 0 then
        -- on va dépasser : accélérateur presque relâché
        pedal = AutoDrive.SMOOTH_PEDAL_LOW + boost
    else
        pedal = AutoDrive.SMOOTH_PEDAL_MIN + err * AutoDrive.SMOOTH_PEDAL_GAIN + boost
    end
    return math.min(maxPedal, pedal)
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale : appelée par AutoDrive.driveInDirection avant AIVehicleUtil.driveInDirection
-- renvoie acceleration, slowAcceleration, slowAngleLimit, maxSpeed, slowDownFactor à passer au jeu
-- ------------------------------------------------------------------------------------------------------------
function AutoDrive.smoothDriveInputs(vehicle, dt, acceleration, slowAcceleration, slowAngleLimit, allowedToDrive, lx, lz, maxSpeed, slowDownFactor)
    if not AutoDrive.SMOOTH_DRIVE or vehicle == nil or vehicle.ad == nil then
        return acceleration, slowAcceleration, slowAngleLimit, maxSpeed, slowDownFactor
    end
    local st = vehicle.ad.smoothDrive
    if st == nil then
        st = {}
        vehicle.ad.smoothDrive = st
    end
    local now = (g_time or 0)
    local stale = st.lastTime == nil or (now - st.lastTime) > AutoDrive.SMOOTH_RESET_MS
    st.lastTime = now

    -- arrêt, freinage demandé ou suivi de moissonneuse : tel quel, la rampe repartira de la vitesse actuelle
    if not allowedToDrive or maxSpeed == nil or maxSpeed <= 0 or acceleration == nil or acceleration <= 0
        or AutoDrive.smoothDriveIsHarvesterFollow(vehicle) then
        st.target = nil
        st.hold = nil
        st.lastSpeed = nil
        st.boost = 0
        return acceleration, slowAcceleration, slowAngleLimit, maxSpeed, slowDownFactor
    end

    dt = math.max(0, math.min(dt or 16, 200))
    local speed = math.abs((vehicle.lastSpeedReal or 0) * 3600)

    -- 1. ralentissement d'angle progressif
    local share = AutoDrive.smoothDriveAngleShare(AutoDrive.smoothDriveTargetAngle(lx, lz), slowAngleLimit)
    local factor = slowDownFactor or 1
    local wanted = maxSpeed * (1 - (1 - factor) * share)
    -- l'accélérateur de l'appelant reste le plafond, quel que soit l'angle : avec une vitesse limite le jeu ne
    -- le réduit pas non plus (AIVehicleUtil.driveInDirection ne prend slowAcceleration que sans vitesse limite).
    -- En marche arrière avec un outil traîné le point visé est derrière (angle proche de 180°) : il serait resté
    -- à 0,2 au lieu de 0,4, trop peu pour un outil lourd.
    local maxPedal = acceleration

    -- 2. vitesse demandée lissée : on garde la plus basse vue pendant SMOOTH_HOLD_MS (une limite qui saute
    --    4/6/4/6 donne 4 stable), puis on remonte en rampe ; vers le bas, tout de suite (sécurité)
    if stale or st.hold == nil or st.target == nil then
        st.hold = wanted
        st.holdUntil = now + AutoDrive.SMOOTH_HOLD_MS
        st.target = math.min(wanted, speed + AutoDrive.SMOOTH_RAMP_START)
        st.boost = 0
    end
    if wanted < st.hold - 0.05 then
        st.hold = wanted
        st.holdUntil = now + AutoDrive.SMOOTH_HOLD_MS
    elseif wanted <= st.hold + 0.3 then
        -- même vitesse, ou qui monte doucement (0,3 km/h au plus d'un coup) : suivie, la garde repart
        st.hold = math.max(st.hold, wanted)
        st.holdUntil = now + AutoDrive.SMOOTH_HOLD_MS
    elseif now >= st.holdUntil then
        st.hold = wanted
    end
    if st.hold <= st.target then
        st.target = st.hold
    else
        st.target = math.min(st.hold, math.max(st.target, speed - 0.5) + AutoDrive.SMOOTH_RAMP_UP * dt / 1000)
    end
    local target = math.max(0.5, st.target)

    -- accélération mesurée (km/h par seconde), lissée
    if st.lastSpeed ~= nil and dt > 0 then
        local a = (speed - st.lastSpeed) * 1000 / dt
        st.accel = (st.accel or 0) + (a - (st.accel or 0)) * math.min(1, dt / 300)
    else
        st.accel = 0
    end
    st.lastSpeed = speed

    -- 4. réserve si on reste en dessous
    local err = target - speed
    if err > 0.3 then
        st.boost = math.min(AutoDrive.SMOOTH_BOOST_MAX, (st.boost or 0) + AutoDrive.SMOOTH_BOOST_RATE * dt / 1000)
    elseif err < 0 then
        st.boost = math.max(0, (st.boost or 0) - AutoDrive.SMOOTH_BOOST_RATE * 2 * dt / 1000)
    end

    -- 3. accélérateur dosé
    local predicted = speed + math.max(0, st.accel) * AutoDrive.SMOOTH_ANTICIPATE
    local pedal = AutoDrive.smoothDrivePedal(target - predicted, st.boost or 0, maxPedal)
    st.lastPedal = pedal
    st.lastTarget = target

    return pedal, pedal, AutoDrive.SMOOTH_NO_SLOW_ANGLE, target, 1
end
