-- ============================================================================================================
-- FarmPilot : AutonomousHeaderNextField.lua
-- Mode Autonome, moissonneuse équipée seule : au changement de champ, la remorque porte-barre change de champ avec
-- la moissonneuse (16/11).
--
-- Cas en jeu (16/11, The Mechet, Lexion 6900, MF 7S.210, Lizard Legacy Trailer 35FT) : l'amenée de la barre au
-- Champ 52 avait été annulée (pas de chemin jusqu'à la barre), le joueur avait attelé la barre à la main puis garé
-- le MF et la remorque au bouton parking. Champ 52 fini, champ suivant « Champ 7 » : la Lexion a pris ce vieux
-- travail d'amenée pour « barre prise, attend que MF 7S.210 ait dégagé », sans même démarrer FarmPilot ; personne
-- n'est venu chercher la barre, elle est restée au Champ 52 avec la barre montée.
--
-- Règle :
-- - Travail de la barre resté d'avant (settleJob) : amenée annulée, tracteur qui n'attend plus (garé, arrêté,
--   occupé ailleurs), ou n'importe quel travail autre que la récolte au moment du champ suivant (le champ vient
--   d'être fini) : la barre attelée compte comme prise sur la remorque de ce travail (phase « harvest », comme
--   après une amenée normale), le tracteur est libéré. La remorque et le tracteur restent notés dans le travail :
--   ils sont rappelés en premier.
-- - Départ au champ suivant avec une barre qui a une remorque porte-barre (prise dessus, ou une remorque vide qui a
--   la place de cette barre : servingTrailer) : la barre ne roule jamais montée jusqu'au champ suivant. La
--   moissonneuse rappelle le tracteur (celui qui a amené la remorque s'il est libre, sinon le véhicule choisi à la
--   roue dentée, sinon le tracteur libre le plus proche : AutonomousHeaderTractor.lua) ; il attelle la remorque à sa
--   place, vient au champ fini, la barre est posée dessus (fin de champ habituelle), puis la remorque est amenée au
--   champ suivant (changement de barre : AutonomousHeader.lua, startCollect avec swap).
-- - Aucune remorque vide ou aucun tracteur libre : la moissonneuse reste au champ fini avec sa barre (moteur coupé),
--   message au joueur et journal, nouvel essai toutes les CARRY_RETRY ms ; jamais la route avec la barre. Barre
--   dételée par le joueur ou champ suivant changé pendant l'attente : arrêt.
-- - Barre sans remorque (coupe à maïs, prise par terre) : rien ne change (AutonomousHeaderGround.lua, contrôle de
--   la route headerTravelOk). NEXT_FIELD_CARRY = false : comme avant (la barre roule si la route le permet).
--
-- Branché par : Modes/AutonomousHeader.lua (onStart : settleJob, nextFieldCarry) ; enveloppe posée au chargement
-- sur ADHeaderFlow.handleStage (étape « carryWait »). Chargé par register.lua après AutonomousHeaderEntry.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.NEXT_FIELD_CARRY = true     -- la remorque porte-barre change de champ avec la moissonneuse
ADHeaderFlow.CARRY_RETRY = 60000         -- ms entre deux essais quand personne n'est libre
ADHeaderFlow.CARRY_LOG_MAX = 3           -- essais écrits un par un dans le journal, ensuite un sur dix

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function label(o)
    return o ~= nil and ADAutonomousManager.toolLabel(o) or "?"
end

local function isGone(o)
    return o == nil or o.isDeleted or o.isDeleting
end

local function markerName(id)
    local m = id ~= nil and ADGraphManager:getMapMarkerById(id) or nil
    return m ~= nil and tostring(m.name) or tostring(id)
end

-- ------------------------------------------------------------------------------------------------------------
-- Travail de la barre resté d'avant
-- ------------------------------------------------------------------------------------------------------------
-- pourquoi ce travail ne vit plus (barre attelée à la moissonneuse), ou nil
local function staleWhy(v, job)
    if job.cancelled then
        return "travail annulé"
    end
    if v.ad.fpHeaderPrevField ~= nil then
        return "champ fini depuis"
    end
    if job.phase == "deliver" and not job.headerTaken then
        local t = job.tractor
        if isGone(t) or t.ad == nil or t.ad.stateModule == nil then
            return "tracteur supprimé"
        end
        if t.ad.fpHeaderJob ~= job then
            return "le tracteur a un autre travail"
        end
        if not t.ad.stateModule:isActive() then
            return "le tracteur n'attend plus (à l'arrêt ou garé)"
        end
    end
    return nil
end

-- onStart (AutonomousHeader.lua), barre attelée : renvoie le travail à garder (le même, réglé, ou nil)
function ADHeaderFlow.settleJob(mode, job, header)
    local v = mode.vehicle
    if job == nil or job.combine ~= v or job.phase == "harvest" then
        return job
    end
    local why = staleWhy(v, job)
    if why == nil then
        return job
    end
    local t = job.tractor
    if t ~= nil and t.ad ~= nil and t.ad.fpHeaderJob == job then
        t.ad.fpHeaderJob = nil
    end
    if job.header ~= header or isGone(job.trailer) then
        -- une autre barre attelée (à la main), ou la remorque n'existe plus : ce travail ne dit plus rien
        log("%s : travail de la barre d'avant (%s, « %s ») oublié : %s", nameOf(v), tostring(job.phase), label(job.header),
            job.header ~= header and string.format("« %s » attelée à sa place", label(header)) or "remorque supprimée")
        ADHeaderFlow.endJob(job)
        return nil
    end
    log("%s : travail de la barre d'avant (%s, %s) : « %s » attelée, comptée comme prise sur « %s », « %s » libéré",
        nameOf(v), tostring(job.phase), why, label(header), label(job.trailer), nameOf(t))
    job.phase = "harvest"
    job.headerTaken = true
    job.headerDropped = false
    job.cancelled = false
    job.trailerReady = false
    job.moveRequested = nil
    job.collectMove = nil
    job.fetchNoPath = nil
    job.clearWait = nil
    job.backIn = nil
    job.swap = nil
    if ADHeaderGround ~= nil and ADHeaderGround.fromTrailer ~= nil then
        ADHeaderGround.fromTrailer[header] = job.trailer -- elle y retournera
    end
    return job
end

-- ------------------------------------------------------------------------------------------------------------
-- La remorque porte-barre de cette barre
-- ------------------------------------------------------------------------------------------------------------
-- la remorque d'où vient la barre (travail en cours, notée à l'attelage, ou encore dessous), sinon une remorque vide
-- de la ferme qui a la place de cette barre (prévue par le jeu ou gardée en mémoire) ; nil = barre sans remorque
function ADHeaderFlow.servingTrailer(v, header)
    local job = v.ad.fpHeaderJob
    if job ~= nil and job.header == header and job.trailer ~= nil and not isGone(job.trailer) then
        return job.trailer, "son travail"
    end
    if ADHeaderGround ~= nil then
        local from = ADHeaderGround.fromTrailer ~= nil and ADHeaderGround.fromTrailer[header] or nil
        if from ~= nil and not isGone(from) then
            return from, "prise dessus"
        end
        if ADHeaderGround.homes ~= nil and ADHeaderGround.homes[header] ~= nil then
            return nil -- prise par terre : elle y retourne (AutonomousHeaderGround.lua)
        end
    end
    local under = ADHeaderFlow.trailerOf(header)
    if under ~= nil then
        return under, "posée dessus"
    end
    local trailer = ADHeaderFlow.findEmptyTrailer(v, header, nil)
    if trailer ~= nil and ADHeaderFlow.lockPose ~= nil then
        local pose = ADHeaderFlow.lockPose(trailer, header)
        if pose ~= nil and (pose.exact or pose.remembered) then
            return trailer, "a sa place"
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Champ suivant : barre reposée sur sa remorque au champ fini, puis amenée
-- ------------------------------------------------------------------------------------------------------------
-- onStart (AutonomousHeader.lua), champ suivant : true = pris en charge ici ; nil = pas concerné (contrôle d'avant)
function ADHeaderFlow.nextFieldCarry(mode, header)
    local v = mode.vehicle
    if not ADHeaderFlow.NEXT_FIELD_CARRY or header == nil then
        return nil
    end
    local trailer, how = ADHeaderFlow.servingTrailer(v, header)
    if trailer == nil then
        return nil
    end
    local sm = v.ad.stateModule
    log("%s : champ suivant « %s » : la remorque porte-barre change de champ avec elle (« %s », %s) : « %s » reposée dessus à « %s », puis amenée",
        nameOf(v), tostring(sm:getFirstMarker() ~= nil and sm:getFirstMarker().name or "?"), label(trailer), tostring(how), label(header),
        markerName(v.ad.fpHeaderPrevField))
    print(string.format("[AD-Coupe] %s: champ suivant, la remorque %s change de champ avec la moissonneuse (%s)", nameOf(v), label(trailer), tostring(how)))
    return ADHeaderFlow.startCarry(v, header, false)
end

-- tracteur appelé (true), ou attente sur place (true aussi : rien ne part avec la barre)
-- (17/11) depart : départ du mode Autonome d'un champ qui n'est pas la destination (AutonomousHeaderLeave.lua),
-- mêmes étapes, textes « quitter le champ »
function ADHeaderFlow.startCarry(v, header, retry, depart)
    local sm = v.ad.stateModule
    local carry = v.ad.fpHeaderCarry
    if not retry or carry == nil or carry.header ~= header then
        carry = { header = header, prevField = v.ad.fpHeaderPrevField, field = sm:getFirstMarkerId(), tries = 0, depart = depart == true }
        v.ad.fpHeaderCarry = carry
    end
    local what = carry.depart and "départ du champ" or "champ suivant"
    local keys = carry.depart and { "AD_autonomous_headerLeaveNoTractor", "AD_autonomous_headerLeaveNoTrailer", "AD_autonomous_headerLeaveStay" }
        or { "AD_autonomous_headerNextNoTractor", "AD_autonomous_headerNextNoTrailer", "AD_autonomous_headerNextStay" }
    local started, why, trailer = ADHeaderFlow.startCollect(v, header, true, nil, true)
    if started then
        if carry.tries > 0 then
            log("%s : " .. what .. ", un tracteur est libre après %d essai(s) : « %s » va être reposée", nameOf(v), carry.tries, label(header))
        end
        v.ad.fpHeaderCarry = nil
        return true
    end
    carry.tries = carry.tries + 1
    trailer = trailer or ADHeaderFlow.servingTrailer(v, header)
    if carry.tries <= ADHeaderFlow.CARRY_LOG_MAX or carry.tries % 10 == 0 or carry.why ~= why then
        print(string.format("[AD-Coupe] %s: %s, barre %s pas reposee (%s) : reste dans le champ, nouvel essai dans %d s (essai %d)",
            nameOf(v), carry.depart and "depart du champ" or "champ suivant", label(header), tostring(why), ADHeaderFlow.CARRY_RETRY / 1000, carry.tries))
    end
    if carry.tries == 1 or carry.why ~= why then
        log("%s : " .. what .. ", « %s » pas reposée (%s) : reste ici avec la barre (jamais de route avec), nouvel essai toutes les %d s",
            nameOf(v), label(header), tostring(why), ADHeaderFlow.CARRY_RETRY / 1000)
        if why == "noTractor" then
            AutonomousMode.message(v, ADMessagesManager.messageTypes.WARN, 15000, keys[1], label(trailer))
        elseif why == "noTrailer" then
            AutonomousMode.message(v, ADMessagesManager.messageTypes.WARN, 15000, keys[2], label(header))
        else
            AutonomousMode.message(v, ADMessagesManager.messageTypes.WARN, 15000, keys[3], label(header))
        end
    end
    carry.why = why
    v.ad.onRouteToRefuel = false
    v.ad.onRouteToRepair = false
    v.ad.restartCP = false
    sm:setStartHelper(false)
    if not sm:isActive() then
        v:startAutoDrive()
        if not sm:isActive() then
            return true -- FarmPilot ne démarre pas : elle reste quand même où elle est
        end
    end
    local mode = v.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    mode:reset()
    mode.headerStage = "carryWait"
    -- fini avant l'heure : la barre n'est plus attelée (dételée par le joueur)
    mode.headerTask = ADHeaderWaitTask:new(v, function() return ADHeaderFlow.attachedHeader(v) ~= header end, ADHeaderFlow.CARRY_RETRY)
    mode.headerTask.textKey = "AD_task_autonomous_headerStay"
    v.ad.taskModule:addTask(mode.headerTask)
    return true
end

-- fin de l'attente : nouvel essai, ou arrêt (barre dételée, champ suivant changé)
function ADHeaderFlow.carryRetry(mode, result)
    local v = mode.vehicle
    local carry = v.ad.fpHeaderCarry
    local header = ADHeaderFlow.attachedHeader(v)
    local sm = v.ad.stateModule
    if result ~= "timeout" or header == nil or carry == nil or carry.header ~= header or sm:getFirstMarkerId() ~= carry.field then
        v.ad.fpHeaderCarry = nil
        log("%s : attente de la remorque pour le champ suivant finie (%s) : arrêt", nameOf(v),
            header == nil and "plus de barre attelée" or (carry ~= nil and sm:getFirstMarkerId() ~= carry.field) and "champ suivant changé" or tostring(result))
        ADHeaderFlow.stopHere(mode, nil)
        return
    end
    v.ad.fpHeaderPrevField = carry.prevField -- la remorque vient au champ fini (startCollect)
    local ok, err = FarmPilotCall(ADHeaderFlow.startCarry, v, header, true, carry.depart)
    v.ad.fpHeaderPrevField = nil
    if not ok then
        log("ERREUR remorque porte-barre au champ suivant, nouvel essai : %s", tostring(err))
        v.ad.fpHeaderCarry = nil
        ADHeaderFlow.stopHere(mode, nil)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppe (posée au chargement)
-- ------------------------------------------------------------------------------------------------------------
local baseHandleStage = ADHeaderFlow.handleStage
function ADHeaderFlow.handleStage(mode)
    if mode.headerStage ~= "carryWait" then
        return baseHandleStage(mode)
    end
    local task = mode.headerTask
    mode.headerStage = nil
    mode.headerTask = nil
    ADHeaderFlow.carryRetry(mode, task ~= nil and task.result or nil)
    return true
end
