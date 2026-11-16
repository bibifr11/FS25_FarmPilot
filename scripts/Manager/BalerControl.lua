-- ============================================================================================================
-- FarmPilot : BalerControl.lua
-- Mode Autonome : la presse au travail sans Courseplay (15/11) : mise en route, pick-up, pose des balles, vitesse et
-- arrêts, avec la logique de l'ouvrier du jeu (AIDriveStrategyBaler).
--
-- Règle (15/11) :
-- - prepare(baler) : dépli (sens de travail du jeu), mise en route dès que le jeu l'accepte (repli dans ses limites,
--   presse alimentée), pick-up baissé (comme la touche « baisser » : attelage, pick-up, repli du milieu), pose
--   automatique des balles le temps du travail (presse : automaticDrop, ou celle du plateau ; presse-enrubanneuse :
--   aussi celle de l'enrubanneuse). Les réglages d'avant sont gardés, release les rend. Appel répété sans risque :
--   ce qui est fait n'est pas refait ; ce que le jeu refuse encore (mise en route pendant le dépli) est refait à
--   chaque appel de mustStop.
-- - release(baler, forRoad) : arrêt, pick-up relevé, repli si forRoad, réglages rendus. (15/11) Balle finie encore
--   dans la presse avant la route (canal d'une presse à balles carrées, chambre ou porte ouverte d'une ronde, balle sur
--   le plateau) : le jeu refuse le repli tant qu'elle y est (Baler:getIsFoldAllowed) et AutoDrive attendrait le repli
--   sans fin. La pose automatique reste en marche (le jeu pousse la balle dehors, presse arrêtée), isEmptying(baler)
--   est vrai et emptyStep(baler), appelé à chaque image tracteur arrêté, aide le jeu comme la touche du joueur
--   (« décharger la balle », poser la balle du plateau) ; presse vide ou EMPTY_TIMEOUT ms passées : repli et réglages
--   rendus. Balle entamée sans balle finie : le jeu accepte le repli, elle reste dans la presse pour le champ suivant.
-- - speedLimit(baler) en km/h : vitesse de l'outil (getSpeedLimit du jeu, au plus WORK_SPEED_MAX) ; presse à chambre
--   (pas « non-stop ») : moins de SLOW_DOWN_FILL_LEVEL L avant la balle = 2 + libre / 200 x 20 km/h, comme le jeu ;
--   balle qui tombe du plateau : vitesse de dépose du plateau (platformAIDropSpeed du jeu, 3 km/h par défaut ; le jeu
--   ne la prend que pour les presses « non-stop », ici pour toutes : ralentir ne gêne jamais).
-- - mustStop(baler) : chambre pleine ou porte ouverte (éjection d'une balle ronde) comme le jeu ; presse-enrubanneuse :
--   balle en cours (prise, enrubannage, balle finie, pose) ; presse demandée au travail (prepare) pas encore en route
--   ou pick-up pas baissé. Balle enrubannée finie que le jeu ne pose pas : on la fait poser (ADBaleWrapper.
--   dropIfFinished) au bout de FINISH_GRACE ms. Presse pas prête au bout de NOT_READY_WARN ms : journal et message
--   (une fois), elle reste arrêtée.
-- - twineEmpty(baler) : plus de ficelle / filet (ADBalerManager.consumable : getConsumableIsAvailable du jeu ; le jeu
--   passe tout seul au rouleau de réserve).
-- - Journal : « [FarmPilot Presse] … » : mise en route, pourquoi elle s'arrête puis repart, réglages rendus.
--
-- Branché par : AutonomousWindrow.lua (prepare avant le pressage, release à la fin, avant la recharge et à l'arrêt),
-- WindrowBaleTask.lua (speedLimit, mustStop, twineEmpty). Chargé par register.lua après WindrowScan.lua.
-- ============================================================================================================

ADBalerControl = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADBalerControl.SLOW_DOWN_FILL_LEVEL = 200   -- L libres dans la chambre : en dessous, ralentir (AIDriveStrategyBaler)
ADBalerControl.SLOW_DOWN_START_SPEED = 20   -- km/h ajoutés à pleine marge (AIDriveStrategyBaler.slowDownStartSpeed)
ADBalerControl.SLOW_DOWN_MIN_SPEED = 2      -- km/h au moins en ralentissant (le jeu : « 2 km/h au moins »)
ADBalerControl.PLATFORM_DROP_SPEED = 3      -- km/h pendant la dépose du plateau si le jeu ne la donne pas
ADBalerControl.WORK_SPEED_MAX = 20          -- km/h au plus au travail (presses du jeu : 10 à 18 km/h)
ADBalerControl.DEFAULT_SPEED = 12           -- km/h si l'outil ne donne pas de vitesse
ADBalerControl.FINISH_GRACE = 1500          -- ms : balle enrubannée finie que le jeu ne pose pas = on la fait poser
ADBalerControl.NOT_READY_WARN = 20000       -- ms : presse demandée au travail pas en route = journal et message
ADBalerControl.EMPTY_TIMEOUT = 30000        -- ms au plus pour poser la balle finie encore dans la presse avant la route
ADBalerControl.EMPTY_ASK = 2000             -- ms entre deux appels de la touche « décharger la balle » pendant ce temps
ADBalerControl.FOLD_EPS = 0.01              -- tolérance du repli
ADBalerControl.LOWER_RETRY = 2000           -- ms entre deux ordres « pick-up baissé » refusés
-- valeurs du jeu si ses constantes ne sont pas lisibles
ADBalerControl.UNLOADING_CLOSED = 1
ADBalerControl.WRAPPER_STATE_NONE = 0
ADBalerControl.WRAPPER_STATE_FINISHED = 4
ADBalerControl.WRAPPER_STATE_RESETTING = 6

ADBalerControl.states = setmetatable({}, { __mode = "k" }) -- [presse] = { wanted, saved, since, warned, stopReason, finishedSince }

local function log(fmt, ...)
    if ADBalerManager ~= nil and ADBalerManager.log ~= nil then
        ADBalerManager.log(fmt, ...)
        return
    end
    local ok, s = FarmPilotCall(string.format, fmt, ...)
    print("[FarmPilot Presse] " .. (ok and s or tostring(fmt)))
end

local function safe(f, ...)
    if f == nil then
        return nil
    end
    local ok, a, b = FarmPilotCall(f, ...)
    if ok then
        return a, b
    end
    return nil
end

local function nameOf(baler)
    if ADAutonomousManager ~= nil and ADAutonomousManager.toolLabel ~= nil then
        local ok, n = FarmPilotCall(ADAutonomousManager.toolLabel, baler)
        if ok and n ~= nil then
            return tostring(n)
        end
    end
    return tostring(safe(baler.getFullName, baler) or "presse")
end

local function now()
    return g_time or 0
end

local function stateOf(baler)
    local st = ADBalerControl.states[baler]
    if st == nil then
        st = {}
        ADBalerControl.states[baler] = st
    end
    return st
end

local function unloadingClosed()
    if Baler ~= nil and Baler.UNLOADING_CLOSED ~= nil then
        return Baler.UNLOADING_CLOSED
    end
    return ADBalerControl.UNLOADING_CLOSED
end

local function wrapperConst(name, default)
    if BaleWrapper ~= nil and BaleWrapper[name] ~= nil then
        return BaleWrapper[name]
    end
    return default
end

-- ------------------------------------------------------------------------------------------------------------
-- État de la presse
-- ------------------------------------------------------------------------------------------------------------
local function foldSpec(baler)
    local fs = baler.spec_foldable
    if fs == nil or fs.foldingParts == nil or #fs.foldingParts == 0 then
        return nil
    end
    return fs
end

-- dépliée (position de travail du jeu : getIsUnfolded) ; sans pièces repliables : oui
function ADBalerControl.isUnfolded(baler)
    local fs = foldSpec(baler)
    if fs == nil then
        return true
    end
    if baler.getIsUnfolded ~= nil then
        local r = safe(baler.getIsUnfolded, baler)
        if r ~= nil then
            return r == true
        end
    end
    local t, dir = fs.foldAnimTime or 0, fs.turnOnFoldDirection or 1
    if dir < 0 then
        return t <= ADBalerControl.FOLD_EPS
    end
    return t >= 1 - ADBalerControl.FOLD_EPS
end

-- repliée pour la route (même règle qu'AutoDrive.isVehicleFolded)
function ADBalerControl.isFolded(baler)
    local fs = foldSpec(baler)
    if fs == nil then
        return true
    end
    local t, dir = fs.foldAnimTime or 0, fs.turnOnFoldDirection or 1
    if dir < 0 then
        return t >= 1 - ADBalerControl.FOLD_EPS
    end
    return t <= ADBalerControl.FOLD_EPS
end

function ADBalerControl.isTurnedOn(baler)
    if baler.getIsTurnedOn == nil then
        return true -- rien à mettre en route
    end
    return safe(baler.getIsTurnedOn, baler) == true
end

function ADBalerControl.isLowered(baler)
    if baler.spec_pickup ~= nil and baler.spec_pickup.isLowered ~= nil then
        return baler.spec_pickup.isLowered == true
    end
    if baler.getIsLowered ~= nil then
        return safe(baler.getIsLowered, baler, true) == true
    end
    return true -- rien à baisser
end

-- prête : dépliée, en route, pick-up baissé
function ADBalerControl.isReady(baler)
    return ADBalerControl.isUnfolded(baler) and ADBalerControl.isTurnedOn(baler) and ADBalerControl.isLowered(baler)
end

-- « dépliée, en route, pick-up baissé » pour le journal
function ADBalerControl.stateText(baler)
    local fs = foldSpec(baler)
    local fold = fs ~= nil and string.format("repli %.0f %%", (fs.foldAnimTime or 0) * 100) or "pas de repli"
    return string.format("%s, %s, %s, pick-up %s", fold, ADBalerControl.isUnfolded(baler) and "dépliée" or "pas dépliée",
        ADBalerControl.isTurnedOn(baler) and "en route" or "arrêtée", ADBalerControl.isLowered(baler) and "baissé" or "relevé")
end

-- ------------------------------------------------------------------------------------------------------------
-- Gestes : dépli / repli, mise en route, pick-up
-- ------------------------------------------------------------------------------------------------------------
local function foldTo(baler, direction)
    local fs = foldSpec(baler)
    if fs == nil or baler.setFoldState == nil then
        return true
    end
    if fs.foldMoveDirection == direction and not fs.moveToMiddle then
        return true -- déjà en route
    end
    if baler.getIsFoldAllowed ~= nil then
        local allowed = safe(baler.getIsFoldAllowed, baler, direction, false)
        if allowed == false then
            return false
        end
    end
    local ok = FarmPilotCall(baler.setFoldState, baler, direction, false)
    return ok
end

-- pick-up (et attelage, repli du milieu) baissé ou relevé, comme la touche du joueur
local function setLowered(baler, down)
    local attacher = baler.getAttacherVehicle ~= nil and safe(baler.getAttacherVehicle, baler) or nil
    if attacher ~= nil and baler.setLoweredAll ~= nil and attacher.getAttacherJointIndexFromObject ~= nil then
        local index = safe(attacher.getAttacherJointIndexFromObject, attacher, baler)
        if index ~= nil and FarmPilotCall(baler.setLoweredAll, baler, down, index) then
            return true
        end
    end
    if baler.setPickupState ~= nil then
        return FarmPilotCall(baler.setPickupState, baler, down) == true
    end
    return false
end

-- ce qui manque pour travailler, fait dans l'ordre (dépli, mise en route, pick-up) ; true = prête. Pick-up : un
-- essai toutes les LOWER_RETRY ms au plus (le jeu peut le refuser un moment : pas d'ordre à chaque image)
local function stepPrepare(baler, st)
    if not ADBalerControl.isUnfolded(baler) then
        local fs = foldSpec(baler)
        foldTo(baler, fs ~= nil and (fs.turnOnFoldDirection or 1) or 1)
        return false
    end
    if not ADBalerControl.isTurnedOn(baler) and baler.setIsTurnedOn ~= nil then
        local can = baler.getCanBeTurnedOn == nil or safe(baler.getCanBeTurnedOn, baler) == true
        if can then
            FarmPilotCall(baler.setIsTurnedOn, baler, true)
        end
    end
    if not ADBalerControl.isLowered(baler) and (st.lowerTry == nil or now() < st.lowerTry or now() - st.lowerTry >= ADBalerControl.LOWER_RETRY) then
        st.lowerTry = now()
        setLowered(baler, true)
    end
    return ADBalerControl.isReady(baler)
end

-- ------------------------------------------------------------------------------------------------------------
-- Pose automatique des balles (réglages du joueur gardés, rendus à la fin)
-- ------------------------------------------------------------------------------------------------------------
local function balerAutoDrop(baler)
    local spec = baler.spec_baler
    if spec == nil then
        return nil
    end
    if spec.hasPlatform then
        return spec.platformAutomaticDrop == true
    end
    return spec.automaticDrop == true
end

local function setBalerAutoDrop(baler, on)
    local spec = baler.spec_baler
    if spec == nil or balerAutoDrop(baler) == (on == true) then
        return
    end
    if baler.setBalerAutomaticDrop ~= nil and FarmPilotCall(baler.setBalerAutomaticDrop, baler, on == true) then
        return
    end
    if spec.hasPlatform then
        spec.platformAutomaticDrop = on == true
    else
        spec.automaticDrop = on == true
    end
end

local function setWrapperAutoDrop(baler, on)
    local spec = baler.spec_baleWrapper
    if spec == nil then
        return nil
    end
    local old = spec.automaticDrop == true
    if old ~= (on == true) then
        if baler.setBaleWrapperAutomaticDrop ~= nil and FarmPilotCall(baler.setBaleWrapperAutomaticDrop, baler, on == true) then
            return old
        end
        spec.automaticDrop = on == true
    end
    return old
end

-- ------------------------------------------------------------------------------------------------------------
-- prepare / release (contrat)
-- ------------------------------------------------------------------------------------------------------------
-- true si la presse est déjà prête
function ADBalerControl.prepare(baler)
    if baler == nil or baler.isDeleted then
        return false
    end
    local st = stateOf(baler)
    if not st.wanted then
        st.wanted = true
        st.since = now()
        st.warned = nil
        st.stopReason = nil
        st.lowerTry = nil
        if st.saved == nil then
            st.saved = { autoDrop = balerAutoDrop(baler), wrapperAutoDrop = nil }
            st.saved.wrapperAutoDrop = setWrapperAutoDrop(baler, true)
        end
        setBalerAutoDrop(baler, true)
        log("presse « %s » : mise au travail (dépli, mise en route, pick-up baissé, pose automatique des balles) ; avant : %s, pose auto %s",
            nameOf(baler), ADBalerControl.stateText(baler), tostring(st.saved.autoDrop))
    end
    return stepPrepare(baler, st)
end

-- (15/11) balle finie encore dans la presse : le jeu refuse alors le repli (Baler:getIsFoldAllowed : balle dans le canal
-- et chambre remplie au-delà du seuil, plus d'une balle, balle sur le plateau) ; porte encore ouverte ou balle qui sort
function ADBalerControl.holdsBale(baler)
    local spec = baler ~= nil and baler.spec_baler or nil
    if spec == nil then
        return false
    end
    if spec.bales ~= nil and #spec.bales > 0 then
        return true
    end
    if spec.isBaleUnloading == true or spec.platformReadyToDrop == true or spec.platformDropInProgress == true then
        return true
    end
    if Baler ~= nil and Baler.UNLOADING_CLOSED ~= nil and spec.unloadingState ~= nil and spec.unloadingState ~= Baler.UNLOADING_CLOSED then
        return true
    end
    return false
end

local function holdsText(baler)
    local spec = baler.spec_baler or {}
    local fill = 0
    if baler.getFillUnitFillLevel ~= nil and spec.fillUnitIndex ~= nil then
        fill = safe(baler.getFillUnitFillLevel, baler, spec.fillUnitIndex) or 0
    end
    local closed = Baler == nil or Baler.UNLOADING_CLOSED == nil or spec.unloadingState == nil or spec.unloadingState == Baler.UNLOADING_CLOSED
    return string.format("%d balle(s) finie(s) dedans%s%s%s, chambre %.0f L", spec.bales ~= nil and #spec.bales or 0, closed and "" or ", porte ouverte",
        spec.isBaleUnloading == true and ", balle qui sort" or "", (spec.platformReadyToDrop == true or spec.platformDropInProgress == true) and ", balle sur le plateau" or "", fill)
end

-- presse arrêtée : comme la touche du joueur, poser la balle du plateau ou décharger la balle finie (porte fermée,
-- rien en cours) ; la pose automatique gardée en marche fait le reste
local function askUnload(baler, st)
    local spec = baler.spec_baler
    local t = now()
    if st.emptyAsk ~= nil and t >= st.emptyAsk and t - st.emptyAsk < ADBalerControl.EMPTY_ASK then
        return
    end
    st.emptyAsk = t
    if spec.platformReadyToDrop == true and spec.platformDropInProgress ~= true and baler.dropBaleFromPlatform ~= nil then
        FarmPilotCall(baler.dropBaleFromPlatform, baler, false)
        return
    end
    local closed = Baler == nil or Baler.UNLOADING_CLOSED == nil or spec.unloadingState == nil or spec.unloadingState == Baler.UNLOADING_CLOSED
    if spec.bales ~= nil and #spec.bales > 0 and closed and spec.isBaleUnloading ~= true and baler.handleUnloadingBaleEvent ~= nil then
        FarmPilotCall(baler.handleUnloadingBaleEvent, baler)
    end
end

-- vrai tant que la presse pose la balle finie qu'elle contenait avant la route (release forRoad)
function ADBalerControl.isEmptying(baler)
    if baler == nil or baler.isDeleted then
        return false
    end
    return stateOf(baler).emptying ~= nil
end

-- à chaque image, tracteur arrêté : true quand c'est fini (presse vide ou EMPTY_TIMEOUT), repli et réglages rendus
function ADBalerControl.emptyStep(baler)
    if baler == nil or baler.isDeleted then
        return true
    end
    local st = stateOf(baler)
    if st.emptying == nil then
        return true
    end
    local waited = now() - st.emptying
    local holds = ADBalerControl.holdsBale(baler)
    if holds and waited >= 0 and waited < ADBalerControl.EMPTY_TIMEOUT then
        askUnload(baler, st)
        return false
    end
    if holds then
        log("presse « %s » : toujours une balle dedans au bout de %.0f s (%s) : réglages rendus, le repli attend que la balle soit sortie",
            nameOf(baler), waited / 1000, holdsText(baler))
    else
        log("presse « %s » : balle posée en %.1f s, presse vide : repli pour la route", nameOf(baler), math.max(waited, 0) / 1000)
    end
    ADBalerControl.release(baler, true, true)
    return true
end

-- noEmpty : repli et réglages rendus tout de suite, même avec une balle dedans (fin de emptyStep)
function ADBalerControl.release(baler, forRoad, noEmpty)
    if baler == nil or baler.isDeleted then
        return
    end
    local st = stateOf(baler)
    st.wanted = false
    st.stopReason = nil
    st.finishedSince = nil
    st.emptying = nil
    st.emptyAsk = nil
    if baler.setIsTurnedOn ~= nil and baler.getIsTurnedOn ~= nil and ADBalerControl.isTurnedOn(baler) then
        FarmPilotCall(baler.setIsTurnedOn, baler, false)
    end
    if baler.spec_pickup ~= nil or baler.setLoweredAll ~= nil then
        if ADBalerControl.isLowered(baler) then
            setLowered(baler, false)
        end
    end
    if forRoad and not noEmpty and ADBalerControl.holdsBale(baler) then
        st.emptying = now()
        setBalerAutoDrop(baler, true)
        log("presse « %s » : arrêtée, pick-up relevé ; balle finie encore dedans (%s) : la presse la pose avant la route (pose automatique gardée le temps de la poser), puis repli",
            nameOf(baler), holdsText(baler))
        return
    end
    local folded = true
    if forRoad and not ADBalerControl.isFolded(baler) then
        local fs = foldSpec(baler)
        folded = foldTo(baler, -(fs ~= nil and (fs.turnOnFoldDirection or 1) or 1))
    end
    if st.saved ~= nil then
        if st.saved.autoDrop ~= nil then
            setBalerAutoDrop(baler, st.saved.autoDrop)
        end
        if st.saved.wrapperAutoDrop ~= nil then
            setWrapperAutoDrop(baler, st.saved.wrapperAutoDrop)
        end
        log("presse « %s » : %s, réglages rendus (pose auto %s)%s", nameOf(baler), forRoad and "arrêtée, pick-up relevé, repli pour la route" or "arrêtée, pick-up relevé",
            tostring(st.saved.autoDrop), folded and "" or " ; repli refusé par le jeu pour l'instant, AutoDrive replie avant la route")
        st.saved = nil
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Vitesse et arrêts (contrat) : la logique de l'ouvrier du jeu (AIDriveStrategyBaler.getDriveData)
-- ------------------------------------------------------------------------------------------------------------
function ADBalerControl.toolSpeed(baler)
    local v = baler.getSpeedLimit ~= nil and safe(baler.getSpeedLimit, baler) or nil
    if type(v) ~= "number" or v <= 0 or v == math.huge then
        v = tonumber(baler.speedLimit)
    end
    if v == nil or v <= 0 or v == math.huge then
        v = ADBalerControl.DEFAULT_SPEED
    end
    return math.min(v, ADBalerControl.WORK_SPEED_MAX)
end

local function chamber(baler)
    local spec = baler.spec_baler
    if spec == nil or spec.fillUnitIndex == nil then
        return nil, nil
    end
    local fill = tonumber(safe(baler.getFillUnitFillLevel, baler, spec.fillUnitIndex)) or 0
    local cap = tonumber(safe(baler.getFillUnitCapacity, baler, spec.fillUnitIndex)) or 0
    return fill, cap
end

function ADBalerControl.speedLimit(baler)
    if baler == nil then
        return ADBalerControl.DEFAULT_SPEED
    end
    local limit = ADBalerControl.toolSpeed(baler)
    local spec = baler.spec_baler
    if spec == nil then
        return limit
    end
    if not spec.nonStopBaling then
        local fill, cap = chamber(baler)
        if cap ~= nil and cap > 0 then
            local free = cap - fill
            if free < ADBalerControl.SLOW_DOWN_FILL_LEVEL then
                local slow = ADBalerControl.SLOW_DOWN_MIN_SPEED + math.max(0, free) / ADBalerControl.SLOW_DOWN_FILL_LEVEL * ADBalerControl.SLOW_DOWN_START_SPEED
                limit = math.min(limit, slow)
            end
        end
    end
    if spec.platformDropInProgress then
        limit = math.min(limit, tonumber(spec.platformAIDropSpeed) or ADBalerControl.PLATFORM_DROP_SPEED)
    end
    return limit
end

-- balle enrubannée finie que le jeu ne pose pas (pose automatique coupée, zone de pose prise) : on la fait poser
local function nudgeWrapper(baler, st, wstate)
    if wstate ~= wrapperConst("STATE_WRAPPER_FINSIHED", ADBalerControl.WRAPPER_STATE_FINISHED) then
        st.finishedSince = nil
        return
    end
    st.finishedSince = st.finishedSince or now()
    if now() - st.finishedSince >= ADBalerControl.FINISH_GRACE and ADBaleWrapper ~= nil and ADBaleWrapper.dropIfFinished ~= nil then
        local ok, r = FarmPilotCall(ADBaleWrapper.dropIfFinished, baler)
        if ok and r ~= nil and st.dropLogged ~= r then
            st.dropLogged = r
            log("presse-enrubanneuse « %s » : balle enrubannée finie pas posée par le jeu : %s", nameOf(baler),
                r == "dropped" and "on la fait poser" or "zone de pose prise, on attend")
        end
        st.finishedSince = now()
    end
end

-- true (et pourquoi) tant que le tracteur doit rester arrêté
local function stopReason(baler, st)
    local spec = baler.spec_baler
    if spec ~= nil and not spec.nonStopBaling then
        local fill, cap = chamber(baler)
        if cap ~= nil and cap > 0 and fill >= cap - 0.001 then
            return "chambre pleine (balle finie)"
        end
        if spec.unloadingState ~= nil and spec.unloadingState ~= unloadingClosed() then
            return "éjection de la balle"
        end
    end
    local wspec = baler.spec_baleWrapper
    if wspec ~= nil and wspec.baleWrapperState ~= nil then
        local s = wspec.baleWrapperState
        nudgeWrapper(baler, st, s)
        if s ~= wrapperConst("STATE_NONE", ADBalerControl.WRAPPER_STATE_NONE) and s ~= wrapperConst("STATE_WRAPPER_RESETTING_PLATFORM", ADBalerControl.WRAPPER_STATE_RESETTING) then
            return "enrubannage de la balle"
        end
    end
    if st.wanted and not stepPrepare(baler, st) then
        if not st.warned and now() - (st.since or now()) >= ADBalerControl.NOT_READY_WARN then
            st.warned = true
            log("presse « %s » pas prête au bout de %.0f s (%s) : elle reste arrêtée", nameOf(baler), ADBalerControl.NOT_READY_WARN / 1000,
                ADBalerControl.stateText(baler))
            local root = baler.getRootVehicle ~= nil and safe(baler.getRootVehicle, baler) or nil
            if root ~= nil and root.ad ~= nil and root.ad.stateModule ~= nil and AutonomousMode ~= nil and AutonomousMode.message ~= nil then
                FarmPilotCall(AutonomousMode.message, root, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_windrowNotReady", nameOf(baler))
            end
        end
        return "mise en route (dépli, pick-up)"
    end
    return nil
end

function ADBalerControl.mustStop(baler)
    if baler == nil or baler.isDeleted then
        return false
    end
    local st = stateOf(baler)
    local reason = stopReason(baler, st)
    if reason ~= st.stopReason then
        if reason ~= nil then
            log("presse « %s » : arrêt du tracteur (%s)", nameOf(baler), reason)
        elseif st.stopReason ~= nil then
            log("presse « %s » : repart (fin de : %s)", nameOf(baler), st.stopReason)
        end
        st.stopReason = reason
    end
    return reason ~= nil, reason
end

function ADBalerControl.twineEmpty(baler)
    if baler == nil or ADBalerManager == nil or ADBalerManager.consumable == nil then
        return false
    end
    local ok, info = FarmPilotCall(ADBalerManager.consumable, baler)
    if not ok or info == nil then
        return false -- presse sans ficelle ni filet à gérer
    end
    return info.available ~= true
end
