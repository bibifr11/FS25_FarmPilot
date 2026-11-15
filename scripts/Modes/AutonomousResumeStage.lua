-- ============================================================================================================
-- FarmPilot : AutonomousResumeStage.lua
-- Mode Autonome : au chargement de la partie (et à la relance d'AutoDrive après un blocage), chaque véhicule
-- reprend exactement l'étape où il était (15/11).
--
-- Défaut (15/11, Fendt 728 + remorque à balles Arcusin pleine, champ 42) : il allait vendre les balles. Partie
-- sauvegardée et rechargée : « départ vers « Champ 42 » », il retournait au champ avec la remorque pleine.
-- Cause : AutonomousMode:start() remet tout à zéro (reset) puis part au champ ; l'étape en cours (dépôt des balles,
-- plein de carburant, plein du semoir, reste de l'épandeur, changement d'outil) n'était pas écrite dans la sauvegarde.
--
-- Règle : au rechargement, chaque véhicule reprend exactement là où il en était ; les données de l'étape en cours
-- sont écrites dans la sauvegarde (#fpAutoStage = « nom:données »).
-- - Remorque à balles en route vers le dépôt ou en train de décharger (« bales ») : il retourne au dépôt et décharge,
--   puis retour au champ s'il restait des balles (comme avant la sauvegarde). Remorque déjà vide : retour au champ
--   s'il restait des balles, sinon la suite d'un champ fini (champ suivant, garage).
-- - (15/11) Remorque à balles en train de ramasser (« bales:collect ») : le ramassage reprend sur place, sur le champ
--   sous le tracteur (sinon celui du point de destination), groupe AutoSwitch compris. Avant : départ vers « Champ 58 »
--   depuis le champ 57 (réuni au 58), calcul du trajet depuis l'intérieur du champ, en échec.
-- - (15/11) Enrubanneuse : en train d'enrubanner = « bales:collect » (même reprise sur place) ; en route vers la zone
--   de recharge du film ou en train de recharger (« bales:film ») : film pas plein = la recharge reprend, puis retour
--   au champ ; film déjà plein = retour au champ, l'enrubannage reprend à l'arrivée.
-- - Plein de carburant (« fuel ») : sortie du champ / pompe = le plein reprend (puis retour au champ ou champ
--   suivant, comme avant) ; plein fait, en route vers le champ = il y retourne et Courseplay repart au dernier point.
-- - Plein du semoir ou de l'épandeur vidé pendant le champ (« refill ») : pas encore plein = le plein reprend, puis
--   retour au champ et Courseplay au dernier point ; déjà plein = retour au champ et Courseplay au dernier point.
--   (Plein avant le départ au champ : le départ habituel le refait déjà.)
-- - Reste de l'épandeur en fin de champ (« dump ») : il retourne le rendre ; déjà rendu = la suite d'un champ fini.
--   (Reste rendu avant le garage : AutonomousResumeReturn.lua.)
-- - Changement d'outil avant le champ suivant (« swap ») : l'outil attelé va à sa place, puis l'outil suivant ;
--   outil déjà posé = il va atteler l'outil suivant.
-- - Retour au garage : AutonomousResumeReturn.lua (#fpAutoReturn), inchangé.
-- - Une seule fois, au premier départ après le chargement (relance automatique des aides ou départ à la main).
-- - Relance d'AutoDrive après un blocage (ADTaskModule:stopAndRestartAD) pendant une de ces étapes : même reprise ;
--   au bout de RESTART_MAX relances en RESTART_WINDOW ms, plus de reprise (départ habituel).
-- - Une autre étape peut s'ajouter : ADResumeStage.register(nom, { stage = function(vehicle, mode) -> données ou nil,
--   resume = function(mode, données) -> true si l'étape a repris }) (pas de « : » dans le nom).
-- - Journal : « [FarmPilot Reprise] <véhicule> : … ».
--
-- Branché par : enveloppes posées au chargement de ce fichier sur ADSavegameResume.save / .load
-- (SavegameResume.lua), AutonomousMode:start et ADTaskModule:stopAndRestartAD ; clé #fpAutoStage déclarée dans
-- Specialization.lua. Chargé par register.lua après AutonomousResumeReturn.lua.
-- ============================================================================================================

ADResumeStage = { handlers = {}, order = {} }

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADResumeStage.RESTART_MAX = 3         -- relances après blocage pendant une étape…
ADResumeStage.RESTART_WINDOW = 180000 -- …en moins de ce temps (ms) : plus de reprise, départ habituel
ADResumeStage.RESTART_VALID = 30000   -- ms : relance notée pas reprise dans ce temps (arrêt entre-temps) = oubliée

local function log(fmt, ...)
    if ADSavegameResume ~= nil and ADSavegameResume.log ~= nil then
        ADSavegameResume.log(fmt, ...)
        return
    end
    local ok, s = pcall(string.format, fmt, ...)
    print("[FarmPilot Reprise] " .. (ok and s or tostring(fmt)))
end

local function nameOf(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    return sm ~= nil and sm.getName ~= nil and tostring(sm:getName()) or "?"
end

local function autonomousMode(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.modes == nil or AutoDrive.MODE_AUTONOMOUS == nil then
        return nil
    end
    return vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS]
end

function ADResumeStage.register(name, handler)
    if ADResumeStage.handlers[name] == nil then
        ADResumeStage.order[#ADResumeStage.order + 1] = name
    end
    ADResumeStage.handlers[name] = handler
end

-- ------------------------------------------------------------------------------------------------------------
-- Étape en cours : « nom:données » ; nil si aucune étape à reprendre
-- ------------------------------------------------------------------------------------------------------------
function ADResumeStage.current(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or not sm:isActive() or sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return nil
    end
    local mode = autonomousMode(vehicle)
    if mode == nil then
        return nil
    end
    for _, name in ipairs(ADResumeStage.order) do
        local ok, data = FarmPilotCall(ADResumeStage.handlers[name].stage, vehicle, mode)
        if ok and data ~= nil then
            return name .. ":" .. tostring(data)
        end
    end
    return nil
end

-- AutoDrive en marche, mode remis à zéro (comme le départ) ; false si AutoDrive ne démarre pas
function ADResumeStage.activate(mode)
    local vehicle = mode.vehicle
    local sm = vehicle.ad.stateModule
    if not sm:isActive() then
        vehicle:startAutoDrive()
    end
    if not sm:isActive() then
        return false
    end
    mode:reset()
    vehicle.ad.fpAutonomousCourse = nil
    vehicle.ad.fpAutonomousAI = nil
    return true
end

-- route vers le champ, puis Courseplay repart au dernier point (fin d'étape « back » du plein)
local function driveBackToField(mode, task)
    local vehicle = mode.vehicle
    local fieldMarker = vehicle.ad.stateModule:getFirstMarker()
    local t = DriveToDestinationTask:new(vehicle, fieldMarker.id)
    if ADDriveGoal ~= nil then ADDriveGoal.set(t, "AD_fpGoal_back", fieldMarker.name) end -- but affiché dans l'ATH, voir DriveGoal.lua
    vehicle.ad.taskModule:addTask(t)
    return t
end

-- ------------------------------------------------------------------------------------------------------------
-- Remorque à balles : dépôt / vente (AutonomousBales.lua)
-- ------------------------------------------------------------------------------------------------------------
ADResumeStage.register("bales", {
    stage = function(vehicle, mode)
        if mode.baleStage == "toDeposit" or mode.baleStage == "unload" then
            return mode.baleBack and "back" or "last"
        end
        if mode.baleStage == "collect" then
            return "collect" -- (15/11) en train de ramasser dans le champ
        end
        if mode.baleStage == "refill" then
            return "film" -- (15/11) enrubanneuse : recharge du film (route, plein)
        end
        return nil
    end,
    resume = function(mode, data)
        if ADBaleCollect == nil or ADBaleLoaderManager == nil then
            return false
        end
        local vehicle = mode.vehicle
        local name = nameOf(vehicle)
        local ok, ctx = FarmPilotCall(ADBaleCollect.makeContext, vehicle)
        if not ok or ctx == nil then
            log("%s : partie rechargée pendant %s, mais plus de remorque à balles réglée attelée : départ habituel", name,
                data == "collect" and "le ramassage des balles" or (data == "film" and "la recharge du film" or "le dépôt des balles"))
            return false
        end
        if data == "film" then
            return ADResumeStage.resumeFilm(mode, ctx)
        end
        if data == "collect" then
            -- (15/11) partie rechargée pendant le ramassage (champ 57, réuni au 58 dans AutoSwitch) : il repartait vers le
            -- point « Champ 58 » par le réseau. Le ramassage reprend là où il est : champ sous le tracteur (makeContext)
            -- et champs du point de destination (avec leur groupe)
            local nums = ADAutonomousManager.markerFieldNumbers ~= nil and ADAutonomousManager.markerFieldNumbers(vehicle) or nil
            ctx.fieldNums = ctx.fieldNums or {}
            for _, n in ipairs(nums or {}) do
                for k, _ in pairs(ADBaleLoaderManager.fieldNumbers(n)) do
                    ctx.fieldNums[k] = true
                end
            end
            if ctx.fieldNum == nil and nums ~= nil then
                ctx.fieldNum = nums[1]
            end
            if ctx.fieldNum == nil then
                log("%s : partie rechargée pendant le ramassage des balles, pas de champ ici : départ habituel", name)
                return false
            end
            if not ADResumeStage.activate(mode) then
                return false
            end
            mode.baleCtx = ctx
            log("%s : partie rechargée pendant le ramassage des balles (champ %s, %d sur la remorque) : le ramassage reprend sur place",
                name, tostring(ctx.fieldNum), ADBaleLoaderManager.loadedCount(ctx.tool))
            ADBaleCollect.startCollect(mode, false)
            return true
        end
        -- le champ du ramassage : celui du point de destination (le tracteur est loin du champ)
        local nums = ADAutonomousManager.markerFieldNumbers ~= nil and ADAutonomousManager.markerFieldNumbers(vehicle) or nil
        if nums ~= nil and nums[1] ~= nil then
            ctx.fieldNum = nums[1]
            ctx.fieldNums = ADBaleLoaderManager.fieldNumbers(nums[1])
            for _, n in ipairs(nums) do
                ctx.fieldNums[n] = true
            end
        end
        local back = data == "back"
        local loaded = ADBaleLoaderManager.loadedCount(ctx.tool)
        if loaded <= 0 then
            if back then
                log("%s : partie rechargée après le dépôt des balles (remorque vide) : retour au champ ramasser la suite", name)
                return false -- départ habituel : le champ, puis le ramassage
            end
            if not ADResumeStage.activate(mode) then
                return false
            end
            mode.baleCtx = ctx
            log("%s : partie rechargée après le dernier dépôt des balles (remorque vide) : la suite du champ fini", name)
            ADBaleCollect.finishField(mode)
            return true
        end
        if not ADResumeStage.activate(mode) then
            return false
        end
        mode.baleCtx = ctx
        log("%s : partie rechargée pendant le dépôt des balles (%d sur la remorque) : il retourne au dépôt%s", name, loaded,
            back and ", puis au champ" or "")
        ADBaleCollect.goDeposit(mode, back)
        return true
    end,
})

-- (15/11) enrubanneuse rechargée pendant la recharge du film : le champ est celui du point de destination (le
-- tracteur en est loin) ; film pas plein = la recharge reprend, sinon retour au champ
function ADResumeStage.resumeFilm(mode, ctx)
    local vehicle = mode.vehicle
    local name = nameOf(vehicle)
    if ctx.kind ~= "wrapper" or ADBaleWrapper == nil then
        log("%s : partie rechargée pendant la recharge du film, mais pas d'enrubanneuse réglée attelée : départ habituel", name)
        return false
    end
    local nums = ADAutonomousManager.markerFieldNumbers ~= nil and ADAutonomousManager.markerFieldNumbers(vehicle) or nil
    if nums ~= nil and nums[1] ~= nil then
        ctx.fieldNum = nums[1]
        ctx.fieldNums = ADBaleLoaderManager.fieldNumbers(nums[1])
        for _, n in ipairs(nums) do
            ctx.fieldNums[n] = true
        end
    end
    if not ADResumeStage.activate(mode) then
        return false
    end
    mode.baleCtx = ctx
    if not ADBaleWrapper.filmFull(ctx.tool) then
        log("%s : partie rechargée pendant la recharge du film (%s) : la recharge reprend, puis retour au champ %s", name,
            ADBaleWrapper.filmText(ctx.tool), tostring(ctx.fieldNum))
        ADBaleCollect.goRefill(mode)
        return true
    end
    log("%s : partie rechargée après la recharge du film (%s) : retour au champ %s, l'enrubannage reprendra", name,
        ADBaleWrapper.filmText(ctx.tool), tostring(ctx.fieldNum))
    ADBaleCollect.backToField(mode, "AD_autonomous_wrapFilmBack")
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Plein de carburant (AutonomousFuel.lua) : « back/exit », « back/pump », « back/back », « next/pump »…
-- ------------------------------------------------------------------------------------------------------------
ADResumeStage.register("fuel", {
    stage = function(vehicle, mode)
        if mode.fuelStage ~= nil then
            return tostring(mode.fuelThen or "next") .. "/" .. tostring(mode.fuelStage)
        end
        return nil
    end,
    resume = function(mode, data)
        if ADFuelRun == nil then
            return false
        end
        local vehicle = mode.vehicle
        local name = nameOf(vehicle)
        local after, stage = string.match(tostring(data), "^(%a+)/(%a+)$")
        after = after == "back" and "back" or "next"
        if after == "back" and stage == "back" then
            if not ADResumeStage.activate(mode) then
                return false
            end
            vehicle.ad.fpFuelRun = true
            mode.fuelThen = "back"
            mode.fuelStage = "back"
            mode.fuelTask = driveBackToField(mode)
            log("%s : partie rechargée après le plein de carburant : retour au champ, Courseplay repartira au dernier point", name)
            return true
        end
        log("%s : partie rechargée pendant le plein de carburant : le plein reprend%s", name, after == "back" and ", puis retour au champ" or ", puis le champ suivant")
        return ADFuelRun.start(vehicle, after, ((ADResumeButton ~= nil and ADResumeButton.why) or "partie rechargée") .. " pendant le plein") == true
    end,
})

-- ------------------------------------------------------------------------------------------------------------
-- Plein du semoir / de l'épandeur vidé pendant le champ (AutonomousMode.lua, startRefill « back »)
-- ------------------------------------------------------------------------------------------------------------
ADResumeStage.register("refill", {
    stage = function(vehicle, mode)
        if mode.refillStage ~= nil and mode.refillThen == "back" then
            return tostring(mode.refillStage)
        end
        return nil -- plein avant le départ au champ : le départ habituel le refait
    end,
    resume = function(mode, data)
        local vehicle = mode.vehicle
        local name = nameOf(vehicle)
        local plan = nil
        if data ~= "back" then
            plan = ADSeederManager ~= nil and ADSeederManager.prepare(vehicle) or nil
            plan = plan or (ADSprayerManager ~= nil and ADSprayerManager.preparePlan(vehicle, "back") or nil)
            plan = plan or (ADBalerManager ~= nil and ADBalerManager.preparePlan ~= nil and ADBalerManager.preparePlan(vehicle, "back") or nil) -- (15/11) presse : recharge de la ficelle / du filet, voir BalerManager.lua
        end
        if not ADResumeStage.activate(mode) then
            return false
        end
        if plan ~= nil and plan.marker ~= nil and plan.needsFill then
            log("%s : partie rechargée pendant le plein : le plein reprend, puis retour au champ", name)
            mode:startRefill(plan, "back")
            return true
        end
        mode.refillThen = "back"
        mode.refillStage = "back"
        mode.refillTask = driveBackToField(mode)
        log("%s : partie rechargée après le plein : retour au champ, Courseplay repartira au dernier point", name)
        return true
    end,
})

-- ------------------------------------------------------------------------------------------------------------
-- Reste de l'épandeur en fin de champ (AutonomousSprayerDump.lua ; avant le garage : AutonomousResumeReturn.lua)
-- ------------------------------------------------------------------------------------------------------------
ADResumeStage.register("dump", {
    stage = function(vehicle, mode)
        if mode.dumpStage ~= nil and vehicle.ad.fpDumpThen ~= "park" then
            return "end"
        end
        return nil
    end,
    resume = function(mode, data)
        if ADSprayerDump == nil then
            return false
        end
        local vehicle = mode.vehicle
        local name = nameOf(vehicle)
        local okD, d = FarmPilotCall(ADSprayerDump.decide, vehicle)
        if okD and d ~= nil and d.action == "dump" then
            log("%s : partie rechargée pendant le retour du reste (%.0f L) : il retourne à « %s »", name, d.level or 0, tostring(d.marker ~= nil and d.marker.name))
            return ADSprayerDump.start(vehicle, d, nil) == true
        end
        if vehicle.ad.stateModule:isActive() then
            return false
        end
        log("%s : partie rechargée, reste déjà rendu : la suite du champ fini", name)
        ADSprayerDump.continueAfterDump(vehicle)
        return true
    end,
})

-- ------------------------------------------------------------------------------------------------------------
-- Changement d'outil avant le champ suivant (AutonomousMode.startToolSwap)
-- ------------------------------------------------------------------------------------------------------------
ADResumeStage.register("swap", {
    stage = function(vehicle, mode)
        if mode.parkStage ~= nil and mode.parkThen == "swap" then
            return "next"
        end
        return nil
    end,
    resume = function(mode, data)
        local vehicle = mode.vehicle
        local sm = vehicle.ad.stateModule
        local name = nameOf(vehicle)
        local nextTool = sm.getFpNextTool ~= nil and sm:getFpNextTool() or nil
        if nextTool == nil then
            log("%s : partie rechargée pendant le changement d'outil, outil suivant inconnu : départ habituel", name)
            return false
        end
        local label = ADAutonomousManager.toolLabel(nextTool)
        local okS, plan, err = FarmPilotCall(AutonomousMode.toolSwapPlan, vehicle, nextTool)
        if not okS or err ~= nil then
            log("%s : partie rechargée pendant le changement d'outil, outil suivant « %s » impossible (%s) : arrêt et attente", name, label, tostring(okS and err or plan))
            local key = AutonomousMode.SWAP_FAIL_KEYS ~= nil and AutonomousMode.SWAP_FAIL_KEYS[err] or nil
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, key or "AD_autonomous_fetchFailed", label)
            if sm:isActive() then
                vehicle:stopAutoDrive()
            end
            return true
        end
        if plan == "same" or plan == "fetch" then
            sm:setFpTool(nextTool)
            sm:setFpNextTool(nil)
            log("%s : partie rechargée pendant le changement d'outil, outil déjà posé : va atteler « %s »", name, label)
            return false -- départ habituel : atteler l'outil choisi, puis le champ
        end
        local field = sm:getFirstMarker()
        log("%s : partie rechargée pendant le changement d'outil : l'outil attelé va à sa place, puis « %s »", name, label)
        return AutonomousMode.startToolSwap(vehicle, plan, nextTool, { name = field ~= nil and field.name or "?" }, "?") == true
    end,
})

-- ------------------------------------------------------------------------------------------------------------
-- Sauvegarde (enveloppes de SavegameResume.lua)
-- ------------------------------------------------------------------------------------------------------------
if ADSavegameResume ~= nil then
    local baseSave = ADSavegameResume.save
    function ADSavegameResume.save(stateModule, xmlFile, key, ...)
        if baseSave ~= nil then
            baseSave(stateModule, xmlFile, key, ...)
        end
        local ok, err = FarmPilotCall(function()
            local value = nil
            if stateModule.active then
                value = ADResumeStage.current(stateModule.vehicle)
            elseif stateModule.fpAutoStageLoaded then
                value = stateModule.fpAutoStage -- pas encore reparti depuis le chargement
            end
            if value ~= nil then
                xmlFile:setValue(key .. "#fpAutoStage", value)
            end
        end)
        if not ok then
            log("ERREUR sauvegarde de l'étape en cours : %s", tostring(err))
        end
    end

    local baseLoad = ADSavegameResume.load
    function ADSavegameResume.load(stateModule, xmlFile, key, ...)
        if baseLoad ~= nil then
            baseLoad(stateModule, xmlFile, key, ...)
        end
        local ok, value = FarmPilotCall(xmlFile.getValue, xmlFile, key .. "#fpAutoStage")
        if ok and type(value) == "string" and value ~= "" then
            stateModule.fpAutoStage = value
            stateModule.fpAutoStageLoaded = true
        else
            stateModule.fpAutoStage = nil
            stateModule.fpAutoStageLoaded = nil
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Relance après blocage (enveloppe de ADTaskModule:stopAndRestartAD)
-- ------------------------------------------------------------------------------------------------------------
function ADResumeStage.noteRestart(vehicle, value)
    local sm = vehicle.ad.stateModule
    local now = g_time or 0
    local r = sm.fpAutoStageRestarts
    if r == nil or now < r.first or now - r.first > ADResumeStage.RESTART_WINDOW then
        r = { first = now, count = 0 }
        sm.fpAutoStageRestarts = r
    end
    r.count = r.count + 1
    if r.count >= ADResumeStage.RESTART_MAX then
        sm.fpAutoStageRestarts = nil
        return false
    end
    sm.fpAutoStage = value
    sm.fpAutoStageLoaded = nil
    sm.fpAutoStageTime = now
    return true
end

if ADTaskModule ~= nil and ADTaskModule.stopAndRestartAD ~= nil then
    local baseRestart = ADTaskModule.stopAndRestartAD
    function ADTaskModule:stopAndRestartAD(...)
        local vehicle = self.vehicle
        local okS, value = FarmPilotCall(ADResumeStage.current, vehicle)
        if okS and value ~= nil and vehicle.ad.fpModeBeforePark == nil then
            local okN, noted = FarmPilotCall(ADResumeStage.noteRestart, vehicle, value)
            if okN and noted then
                log("%s : bloqué pendant l'étape « %s » : AutoDrive relancé, l'étape reprendra", nameOf(vehicle), value)
            elseif okN then
                log("%s : bloqué %d fois pendant l'étape « %s » : plus de reprise, départ habituel", nameOf(vehicle), ADResumeStage.RESTART_MAX, value)
            end
        end
        return baseRestart(self, ...)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ (enveloppe de AutonomousMode:start) : l'étape reprend
-- ------------------------------------------------------------------------------------------------------------
-- true si l'étape a repris
function ADResumeStage.resume(mode, value)
    local vehicle = mode.vehicle
    local sm = vehicle.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS or sm:getFirstMarker() == nil then
        return false
    end
    local name, data = string.match(value, "^([^:]+):?(.*)$")
    local handler = name ~= nil and ADResumeStage.handlers[name] or nil
    if handler == nil then
        log("%s : étape sauvegardée « %s » inconnue : départ habituel", nameOf(vehicle), tostring(value))
        return false
    end
    return handler.resume(mode, data) == true
end

if AutonomousMode ~= nil and AutonomousMode.start ~= nil then
    local baseStart = AutonomousMode.start
    function AutonomousMode:start(user, ...)
        local sm = self.vehicle ~= nil and self.vehicle.ad ~= nil and self.vehicle.ad.stateModule or nil
        local value = sm ~= nil and sm.fpAutoStage or nil
        if value ~= nil and not sm.fpAutoStageLoaded then
            local now = g_time or 0
            if now < (sm.fpAutoStageTime or 0) or now - (sm.fpAutoStageTime or 0) > ADResumeStage.RESTART_VALID then
                value = nil -- relance pas faite (arrêté entre-temps) : départ habituel
            end
        end
        if sm ~= nil then
            sm.fpAutoStage = nil -- une seule fois
            sm.fpAutoStageLoaded = nil
            sm.fpAutoStageTime = nil
        end
        if value ~= nil then
            local ok, done = FarmPilotCall(ADResumeStage.resume, self, value)
            if not ok then
                log("ERREUR reprise de l'étape « %s » : %s", tostring(value), tostring(done))
            elseif done then
                return
            end
        end
        return baseStart(self, user, ...)
    end
end
