-- ============================================================================================================
-- FarmPilot : BaleWrapperManager.lua
-- Mode Autonome : l'enrubanneuse traînée qui prend les balles elle-même (spec_baleWrapper avec un bras,
-- baleGrabber.grabNode), comme la remorque à balles (BaleLoaderManager.lua) : la machine, son film, sa recharge.
--
-- Règle (15/11) :
-- - Enrubanneuses du jeu qui prennent la balle au sol avec leur bras (grabNode). Presse-enrubanneuse (pas de bras) :
--   pas gérée, rien ne change (pas de roue dentée).
-- - Même roue dentée et même fenêtre que la remorque à balles (BaleLoaderSettingsGUI.lua) : zone de recharge du film
--   (un marqueur, comme la zone de ravitaillement du semoir) et décalage de visée. Départ refusé tant que ce n'est
--   pas validé.
-- - Au champ : bras en position de travail (repli dans les limites du bras, foldMinLimit / foldMaxLimit), pose
--   automatique des balles mise le temps du travail (rendue comme avant ensuite), puis les balles non enrubannées
--   que la machine accepte (getIsBaleWrappable : taille et pas encore enrubannée), une par une : le bras la prend,
--   la machine l'enrubanne et la pose derrière, on attend qu'elle soit revenue au repos avant la suivante. Balle
--   posée : enrubannée, plus jamais visée. Balle finie que le jeu ne pose pas : on la fait poser
--   (CHANGE_BUTTON_EMPTY, sur le serveur, si la zone de pose est libre).
-- - Plus de film (consommable du jeu, getConsumableIsAvailable) : machine repliée, route vers la zone de recharge,
--   plein de film aux palettes près du marqueur (même plein que le semoir : AutonomousMode.startRefill), retour au
--   champ et l'enrubannage reprend. Film vide au départ du mode : recharge d'abord, puis le champ.
-- - Les balles restent où la machine les pose ; la remorque à balles peut les ramasser ensuite (« enrubannées
--   seulement »).
-- - Journal : « [FarmPilot Balles] … » (choix, prise, balle enrubannée, posée, film vide, recharge, fin de champ).
--
-- Branché par : BaleLoaderManager.lua (isWrapper, grabber, isBusy, position de travail, balles acceptées),
-- BaleCollectTask.lua (préparation, attente de la balle enrubannée, film), AutonomousBales.lua (recharge, retour),
-- AutonomousMode.lua (start : startPlan, une ligne), AutonomousRefill.lua (productsFull : film plein, une ligne).
-- Chargé par register.lua après BaleLoaderManager.lua.
-- ============================================================================================================

ADBaleWrapper = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADBaleWrapper.FILM_TYPE = "BALEWRAP"       -- nom du consommable quand le jeu ne donne pas BaleWrapper.CONSUMABLE_TYPE_NAME
ADBaleWrapper.FINISH_GRACE = 1500          -- ms : balle finie que le jeu ne pose pas encore = on la fait poser
ADBaleWrapper.FOLDED_EPS = 0.01            -- tolérance du repli (replié = 0 ou 1 selon le sens de travail)
-- états du jeu (BaleWrapper.STATE_*) quand ils ne sont pas lisibles
ADBaleWrapper.DEFAULTS = {
    STATE_NONE = 0, STATE_MOVING_BALE_TO_WRAPPER = 1, STATE_MOVING_GRABBER_TO_WORK = 2, STATE_WRAPPER_WRAPPING_BALE = 3,
    STATE_WRAPPER_FINSIHED = 4, STATE_WRAPPER_DROPPING_BALE = 5, STATE_WRAPPER_RESETTING_PLATFORM = 6, CHANGE_BUTTON_EMPTY = 8
}
ADBaleWrapper.STATE_TEXT = { [0] = "au repos", [1] = "prend la balle", [2] = "bras en retour", [3] = "enrubanne", [4] = "balle finie",
    [5] = "pose la balle", [6] = "plateau en retour" }

local function log(fmt, ...)
    if ADBaleLoaderManager ~= nil and ADBaleLoaderManager.log ~= nil then
        ADBaleLoaderManager.log(fmt, ...)
        return
    end
    local ok, s = FarmPilotCall(string.format, fmt, ...)
    print("[FarmPilot Balles] " .. (ok and s or tostring(fmt)))
end

local function safe(f, ...)
    if f == nil then
        return nil
    end
    local ok, a, b, c = FarmPilotCall(f, ...)
    if ok then
        return a, b, c
    end
    return nil
end

local function const(name)
    if BaleWrapper ~= nil and BaleWrapper[name] ~= nil then
        return BaleWrapper[name]
    end
    return ADBaleWrapper.DEFAULTS[name]
end
ADBaleWrapper.const = const

-- ------------------------------------------------------------------------------------------------------------
-- Quelle machine, quel état
-- ------------------------------------------------------------------------------------------------------------
-- enrubanneuse qui prend les balles au sol avec son bras (pas une presse-enrubanneuse)
function ADBaleWrapper.isWrapper(tool)
    if tool == nil or tool.isDeleted or tool.isDeleting or tool.spec_baleLoader ~= nil then
        return false
    end
    local spec = tool.spec_baleWrapper
    return spec ~= nil and spec.baleGrabber ~= nil and spec.baleGrabber.grabNode ~= nil
end

function ADBaleWrapper.spec(tool)
    return tool ~= nil and tool.spec_baleWrapper or nil
end

function ADBaleWrapper.state(tool)
    local spec = ADBaleWrapper.spec(tool)
    return spec ~= nil and spec.baleWrapperState or const("STATE_NONE")
end

function ADBaleWrapper.stateText(tool)
    local s = ADBaleWrapper.state(tool)
    return ADBaleWrapper.STATE_TEXT[s] or tostring(s)
end

-- au repos : pas de balle en cours (prise, enrubannage, pose)
function ADBaleWrapper.isIdle(tool)
    local spec = ADBaleWrapper.spec(tool)
    if spec == nil then
        return true
    end
    return spec.baleWrapperState == const("STATE_NONE") and spec.baleToLoad == nil
end

-- bras, portée (m)
function ADBaleWrapper.grabber(tool)
    local spec = ADBaleWrapper.spec(tool)
    local g = spec ~= nil and spec.baleGrabber or nil
    if g == nil or g.grabNode == nil then
        return nil
    end
    return g.grabNode, g.nearestDistance or 3
end

-- « rondes », « carrées » ou les deux (fenêtre des réglages)
function ADBaleWrapper.baleKinds(tool)
    local spec = ADBaleWrapper.spec(tool)
    if spec == nil then
        return nil
    end
    local function has(w)
        return w ~= nil and type(w.allowedBaleTypes) == "table" and next(w.allowedBaleTypes) ~= nil
    end
    local round, square = has(spec.roundBaleWrapper), has(spec.squareBaleWrapper)
    if round and square then
        return "both"
    elseif round then
        return "round"
    elseif square then
        return "square"
    end
    return nil
end

-- pourquoi la machine ne prendrait pas cette balle (nil = elle la prend) : getIsBaleWrappable du jeu (taille, pas
-- encore enrubannée)
function ADBaleWrapper.rejectReason(tool, bale)
    if tool.getIsBaleWrappable == nil then
        return (tonumber(bale.wrappingState) or 0) >= 1 and "wrapped" or nil
    end
    local ok, wrappable, sizeMatch = FarmPilotCall(tool.getIsBaleWrappable, tool, bale)
    if not ok then
        return "error"
    end
    if wrappable then
        return nil
    end
    if (tonumber(bale.wrappingState) or 0) >= 1 then
        return "wrapped"
    end
    if not sizeMatch then
        return "size"
    end
    return "notSupported"
end

-- ------------------------------------------------------------------------------------------------------------
-- Repli : position de travail (bras dans ses limites) et position route
-- ------------------------------------------------------------------------------------------------------------
local function foldSpec(tool)
    local spec = tool ~= nil and tool.spec_foldable or nil
    if spec == nil or spec.foldingParts == nil or #spec.foldingParts == 0 then
        return nil
    end
    return spec
end

-- repli dans les limites où le bras prend les balles (BaleWrapper:allowsGrabbingBale)
function ADBaleWrapper.foldReady(tool)
    local spec = ADBaleWrapper.spec(tool)
    local fs = foldSpec(tool)
    if spec == nil or fs == nil or fs.foldAnimTime == nil then
        return true
    end
    local minL, maxL = spec.currentWrapperFoldMinLimit or 0, spec.currentWrapperFoldMaxLimit or 1
    return fs.foldAnimTime >= minL and fs.foldAnimTime <= maxL
end

-- le bras peut prendre une balle maintenant (repli et machine au repos)
function ADBaleWrapper.canGrab(tool)
    if tool ~= nil and tool.allowsGrabbingBale ~= nil then
        local ok, r = FarmPilotCall(tool.allowsGrabbingBale, tool)
        if ok then
            return r == true
        end
    end
    return ADBaleWrapper.foldReady(tool) and ADBaleWrapper.isIdle(tool)
end

function ADBaleWrapper.hasFoldParts(tool)
    return foldSpec(tool) ~= nil
end

-- replié pour la route (même règle qu'AutoDrive.isVehicleFolded) ; sans pièces repliables : oui
function ADBaleWrapper.isFolded(tool)
    local fs = foldSpec(tool)
    if fs == nil then
        return true
    end
    local t = fs.foldAnimTime or 0
    if (fs.turnOnFoldDirection or 1) < 0 then
        return t >= 1 - ADBaleWrapper.FOLDED_EPS
    end
    return t <= ADBaleWrapper.FOLDED_EPS
end

local function foldTo(tool, direction)
    local fs = foldSpec(tool)
    if fs == nil or tool.setFoldState == nil then
        return true
    end
    if fs.foldMoveDirection == direction and not fs.moveToMiddle then
        return true -- déjà en route
    end
    if tool.getIsFoldAllowed ~= nil then
        local allowed = safe(tool.getIsFoldAllowed, tool, direction, false)
        if allowed == false then
            return false
        end
    end
    local ok = FarmPilotCall(tool.setFoldState, tool, direction, false)
    return ok
end

-- position de travail : déplié (sens de travail du jeu) si le bras n'est pas dans ses limites
function ADBaleWrapper.unfold(tool)
    if ADBaleWrapper.foldReady(tool) then
        return true
    end
    local fs = foldSpec(tool)
    return foldTo(tool, fs ~= nil and (fs.turnOnFoldDirection or 1) or 1)
end

-- position route : replié (machine au repos seulement, le jeu refuse sinon)
function ADBaleWrapper.fold(tool)
    if ADBaleWrapper.isFolded(tool) then
        return true
    end
    if not ADBaleWrapper.isIdle(tool) then
        return false
    end
    local fs = foldSpec(tool)
    return foldTo(tool, -(fs.turnOnFoldDirection or 1))
end

-- ------------------------------------------------------------------------------------------------------------
-- Pose de la balle enrubannée
-- ------------------------------------------------------------------------------------------------------------
-- pose automatique (le jeu pose la balle finie tout seul) ; rend l'ancien réglage
function ADBaleWrapper.setAutoDrop(tool, on)
    local spec = ADBaleWrapper.spec(tool)
    if spec == nil then
        return nil
    end
    local old = spec.automaticDrop == true
    if old ~= (on == true) then
        if tool.setBaleWrapperAutomaticDrop ~= nil then
            FarmPilotCall(tool.setBaleWrapperAutomaticDrop, tool, on == true)
        else
            spec.automaticDrop = on == true
        end
    end
    return old
end

-- balle finie : la faire poser si le jeu ne l'a pas fait (zone de pose libre, serveur seulement).
-- Renvoie « dropped » (ordre donné), « blocked » (zone de pose prise), sinon nil
function ADBaleWrapper.dropIfFinished(tool)
    if ADBaleWrapper.state(tool) ~= const("STATE_WRAPPER_FINSIHED") then
        return nil
    end
    if tool.isServer == false or tool.doStateChange == nil then
        return nil
    end
    if tool.getIsBaleDropAllowed ~= nil then
        local allowed = safe(tool.getIsBaleDropAllowed, tool)
        if allowed == false then
            return "blocked"
        end
    end
    local ok = FarmPilotCall(tool.doStateChange, tool, const("CHANGE_BUTTON_EMPTY"))
    return ok and "dropped" or nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Film (consommable du jeu)
-- ------------------------------------------------------------------------------------------------------------
function ADBaleWrapper.filmTypeName()
    if BaleWrapper ~= nil and type(BaleWrapper.CONSUMABLE_TYPE_NAME) == "string" then
        return BaleWrapper.CONSUMABLE_TYPE_NAME
    end
    return ADBaleWrapper.FILM_TYPE
end

-- type de consommable du film sur la machine (nil : machine sans film à gérer)
function ADBaleWrapper.filmType(tool)
    local spec = tool ~= nil and tool.spec_consumable or nil
    if spec == nil or spec.typesByName == nil then
        return nil
    end
    return spec.typesByName[ADBaleWrapper.filmTypeName()]
end

function ADBaleWrapper.filmUnit(tool)
    local t = ADBaleWrapper.filmType(tool)
    return t ~= nil and t.fillUnitIndex or nil
end

-- il reste du film pour enrubanner une balle (rouleau en place) ; machine sans film à gérer : oui
function ADBaleWrapper.filmAvailable(tool)
    if ADBaleWrapper.filmType(tool) == nil or tool.getConsumableIsAvailable == nil then
        return true
    end
    local ok, r = FarmPilotCall(tool.getConsumableIsAvailable, tool, ADBaleWrapper.filmTypeName())
    return not ok or r ~= false
end

-- plein de film : plus de place pour un rouleau (capacité libre du jeu, consommable compris)
function ADBaleWrapper.filmFull(tool)
    local unit = ADBaleWrapper.filmUnit(tool)
    if unit == nil or tool.getFillUnitFreeCapacity == nil then
        return true
    end
    local free = safe(tool.getFillUnitFreeCapacity, tool, unit)
    return type(free) == "number" and free <= 0.01
end

-- produits du film : index et noms (ce que la cuve du film accepte)
function ADBaleWrapper.filmFillTypes(tool)
    local unit = ADBaleWrapper.filmUnit(tool)
    local indexes, names = {}, {}
    if unit == nil or tool.getFillUnitSupportedFillTypes == nil then
        return indexes, names
    end
    local supported = safe(tool.getFillUnitSupportedFillTypes, tool, unit) or {}
    for ft, on in pairs(supported) do
        if on then
            indexes[#indexes + 1] = ft
        end
    end
    table.sort(indexes)
    for _, ft in ipairs(indexes) do
        local name = g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeNameByIndex ~= nil and safe(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, ft) or nil
        names[#names + 1] = name or tostring(ft)
    end
    return indexes, names
end

-- « 2 rouleau(x) + rouleau en place 40 % » (journal)
function ADBaleWrapper.filmText(tool)
    local t = ADBaleWrapper.filmType(tool)
    if t == nil then
        return "pas de film à gérer"
    end
    local level = tool.getFillUnitFillLevel ~= nil and safe(tool.getFillUnitFillLevel, tool, t.fillUnitIndex) or nil
    return string.format("%s rouleau(x) en réserve, rouleau en place %.0f %%", type(level) == "number" and string.format("%.0f", level) or "?",
        (tonumber(t.consumingFillLevel) or 0) * 100)
end

-- (hook AutonomousRefill.lua, ADSeederRefill.productsFull) plein = film plein quand l'outil est une enrubanneuse et les
-- produits ceux de son film ; nil sinon (règle du semoir)
function ADBaleWrapper.productsFull(tool, fillTypes)
    if not ADBaleWrapper.isWrapper(tool) or ADBaleWrapper.filmUnit(tool) == nil then
        return nil
    end
    local film = ADBaleWrapper.filmFillTypes(tool)
    for _, ft in ipairs(fillTypes or {}) do
        for _, f in ipairs(film) do
            if f == ft then
                return ADBaleWrapper.filmFull(tool)
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Recharge du film : plan pour AutonomousMode.startRefill (comme le semoir)
-- ------------------------------------------------------------------------------------------------------------
-- ctx : contexte de AutonomousBales (tool, settings.refill, field) ; { kind = "wrapper", tool, settings, marker,
-- fillTypes, field, needsFill, fillKey, emptyKey } ou nil (pas une enrubanneuse)
function ADBaleWrapper.refillPlan(ctx)
    if ctx == nil or not ADBaleWrapper.isWrapper(ctx.tool) then
        return nil
    end
    local indexes, names = ADBaleWrapper.filmFillTypes(ctx.tool)
    local refill = ctx.settings ~= nil and ctx.settings.refill or nil
    return {
        kind = "wrapper", tool = ctx.tool, settings = { fillTypes = names }, fillTypes = indexes, field = ctx.field,
        marker = refill ~= nil and ADGraphManager:getMapMarkerByName(refill) or nil, refillName = refill,
        needsFill = not ADBaleWrapper.filmFull(ctx.tool),
        fillKey = "AD_autonomous_wrapFilmFill", emptyKey = "AD_autonomous_wrapFilmEmpty"
    }
end

-- (hook AutonomousMode:start) enrubanneuse réglée attelée sans film : recharge avant le champ ; sinon nil
function ADBaleWrapper.startPlan(vehicle)
    local ok, plan = FarmPilotCall(ADBaleWrapper.makeStartPlan, vehicle)
    if not ok then
        log("ERREUR recharge du film au départ : %s", tostring(plan))
        return nil
    end
    return plan
end

function ADBaleWrapper.makeStartPlan(vehicle)
    if ADBaleCollect == nil or ADBaleCollect.makeContext == nil then
        return nil
    end
    local ctx = ADBaleCollect.makeContext(vehicle)
    if ctx == nil or ctx.kind ~= "wrapper" or ADBaleWrapper.filmAvailable(ctx.tool) then
        return nil
    end
    local plan = ADBaleWrapper.refillPlan(ctx)
    if plan == nil or #plan.fillTypes == 0 then
        return nil
    end
    plan.needsFill = true
    log("%s : enrubanneuse sans film (%s) : recharge à « %s » avant le champ", tostring(vehicle.ad.stateModule:getName()),
        ADBaleWrapper.filmText(ctx.tool), tostring(plan.refillName))
    return plan
end
