-- ============================================================================================================
-- FarmPilot : AutonomousResumeHeader.lua
-- Au chargement de la partie (et à la relance d'AutoDrive après un blocage), la moissonneuse équipée seule, le
-- tracteur de sa remorque porte-barre et les bennes de moissonneuse reprennent exactement l'étape où ils étaient
-- (15/11).
--
-- Défaut : le travail de la barre (moissonneuse + tracteur + remorque + barre) n'existait qu'en mémoire. Partie
-- rechargée pendant l'amenée ou la reprise de la barre : la moissonneuse repartait de zéro (nouveau travail, tracteur
-- « occupé », arrêt) et le tracteur partait au champ avec la remorque porte-barre comme outil de travail. Une benne
-- qui allait vider sa dernière charge (sous le niveau de déchargement) retournait au champ chargée ; une benne qui
-- rentrait au parking après la fin du champ retournait au champ ; les bennes qui devaient suivre la moissonneuse au
-- champ suivant restaient à l'ancien champ.
--
-- Règle : les données de l'étape sont écrites dans la sauvegarde, et au premier départ après le chargement chaque
-- véhicule reprend son étape ; ce qui a bougé entre-temps se voit sur place (barre attelée, posée, remorque attelée).
--
-- 1. Moissonneuse et tracteur de la remorque porte-barre (étape « header » de AutonomousResumeStage.lua,
--    #fpAutoStage = « header:rôle|travail|étape|moissonneuse|tracteur|remorque|barre|champ|changement »)
--    Amenée de la barre (« deliver ») :
--    - tracteur : barre déjà prise = la remorque vide va à sa place, puis lui ; remorque en place = il attend la
--      moissonneuse ; sinon il reprend l'amenée (attelle la remorque si besoin, route du champ, place au champ) ;
--    - moissonneuse : barre déjà prise = elle attend que le tracteur ait dégagé, puis départ au champ ; elle allait
--      atteler la barre = elle y retourne ; sinon elle attend la remorque (ou la suit quand elle est partie devant).
--    Reprise de la barre en fin de champ ou au changement de barre (« collect ») :
--    - tracteur : barre déjà posée = la remorque va à sa place, puis lui ; dans le champ = il revient à côté de la
--      moissonneuse (déjà bien placé : il attend) ; sinon il reprend la route du champ ;
--    - moissonneuse : barre déjà posée = sa place (ou l'attente d'un tracteur pour la barre suivante) ; sinon elle
--      attend la remorque à côté d'elle, puis la pose.
--    Moissonneuse seule : attente de la vidange ou de la remorque en fin de champ (« tankWait », « fieldEndWait ») =
--    la fin de champ reprend (vidée d'abord, jamais de route avec la barre) ; route vers une barre posée par terre =
--    elle y retourne ; barre reposée, en route vers sa place = elle y va ; attente d'un tracteur pour la barre
--    suivante = elle attend. Tracteur rentrant sans place pour la remorque (« home ») = il rentre.
--    L'autre véhicule pas encore reparti : celui qui reprend attend (au plus ADHeaderFlow.WAIT_TIMEOUT).
-- 2. Barre prise sur une remorque (#fpHeaderFrom) : gardée dans la sauvegarde de la moissonneuse. Avant, après un
--    rechargement, une barre prise sur une remorque était vue comme une barre « par terre » : posée à sa place par la
--    route en fin de champ, et le contrôle de la route vers le champ suivant était sauté.
-- 3. Bennes en « Décharger moissonneuse » (#fpUnloadStage) : « unload » (en route pour vider ou en train de vider),
--    « unloadPark » (pareil, puis le parking : fin de champ), « park » (vers le parking après la fin de champ).
--    Chargée = elle retourne vider (quel que soit le niveau de déchargement), puis le parking pour « unloadPark » ;
--    vide = le parking (« unloadPark », « park ») ou le champ (« unload », comme avant). Remorque choisie pas attelée :
--    départ habituel (elle va l'atteler d'abord).
-- 4. Bennes qui suivront la moissonneuse au champ suivant (#fpUnloaderFollow, sauvegarde de la moissonneuse) : la liste
--    des bennes, l'ancien et le nouveau champ ; rechargée, elle suit de nouveau (AutonomousHarvesterUnloaders.lua).
-- - Une seule fois au premier départ après le chargement ; relance après blocage : même reprise, au plus
--   ADResumeStage.RESTART_MAX fois en ADResumeStage.RESTART_WINDOW ms.
-- - Journal : « [FarmPilot Reprise] <véhicule> : … ».
--
-- Branché par : ADResumeStage.register (AutonomousResumeStage.lua) ; enveloppes posées au chargement sur
-- ADSavegameResume.save / .load, CombineUnloaderMode:start, ADTaskModule:stopAndRestartAD,
-- ADHeaderGround.cameFromTrailer, ADHarvesterUnloaders.update ; clés déclarées dans Specialization.lua. Chargé par
-- register.lua après AutonomousResumeStage.lua.
-- ============================================================================================================

ADResumeHeader = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADResumeHeader.UNLOAD_MIN = 50          -- l : moins dans la benne = vide (comme CombineUnloaderMode.JOB_DONE_MIN_LOAD)
ADResumeHeader.FIELD_EXIT_FROM = 30     -- m du point du champ : plus loin dans le champ, sortie du champ d'abord (comme setToWaitForCall)

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

local function label(o)
    if o ~= nil and o.getName ~= nil then
        local ok, n = pcall(o.getName, o)
        if ok and n ~= nil then
            return tostring(n)
        end
    end
    return "?"
end

local function isGone(o)
    return o == nil or o.isDeleted or o.isDeleting
end

-- identifiant stable du véhicule (le même d'une partie à l'autre), ou nil
local function uidOf(v)
    if v == nil or v.getUniqueId == nil then
        return nil
    end
    local ok, id = pcall(v.getUniqueId, v)
    if ok and id ~= nil and id ~= "" then
        return tostring(id)
    end
    return nil
end
ADResumeHeader.uidOf = uidOf

local function byUid(uid)
    if uid == nil or uid == "" or uid == "-" then
        return nil
    end
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system ~= nil and system.getVehicleByUniqueId ~= nil then
        local ok, v = pcall(system.getVehicleByUniqueId, system, uid)
        if ok and v ~= nil and not isGone(v) then
            return v
        end
    end
    for _, v in pairs(system ~= nil and system.vehicles or {}) do
        if uidOf(v) == uid and not isGone(v) then
            return v
        end
    end
    return nil
end
ADResumeHeader.byUid = byUid

local function rootOf(o)
    if o ~= nil and o.getRootVehicle ~= nil then
        return o:getRootVehicle() or o
    end
    return o
end

local function attachedTo(trailer, tractor)
    local a = trailer ~= nil and trailer.getAttacherVehicle ~= nil and trailer:getAttacherVehicle() or nil
    return a ~= nil and rootOf(a) == tractor
end

local function split(text)
    local out, from = {}, 1
    text = tostring(text or "")
    while true do
        local i = string.find(text, "|", from, true)
        if i == nil then
            out[#out + 1] = string.sub(text, from)
            return out
        end
        out[#out + 1] = string.sub(text, from, i - 1)
        from = i + 1
    end
end

-- marqueur dans la sauvegarde : son numéro dans la config, sans les marqueurs de dbg (comme #firstMarker)
local function markerSave(marker)
    if type(marker) == "number" then
        marker = ADGraphManager:getMapMarkerById(marker)
    end
    if marker == nil then
        return nil
    end
    if ADGraphManager.getSavedMarkerIndex ~= nil then
        return ADGraphManager:getSavedMarkerIndex(marker)
    end
    return marker.markerIndex
end

local function markerLoad(saved)
    saved = tonumber(saved)
    if saved == nil then
        return nil
    end
    if ADGraphManager.getMarkerForLoad ~= nil then
        return ADGraphManager:getMarkerForLoad(saved)
    end
    return ADGraphManager:getMapMarkerById(saved)
end

local function joinFields(list)
    local out = {}
    for i, p in ipairs(list) do
        out[i] = (p == nil or p == "") and "-" or tostring(p)
    end
    return table.concat(out, "|")
end

-- ------------------------------------------------------------------------------------------------------------
-- 1. Étape de la barre (handler « header » de ADResumeStage)
-- ------------------------------------------------------------------------------------------------------------
local JOB_STAGES = { deliver = true, collect = true }

-- « rôle|travail|étape|moissonneuse|tracteur|remorque|barre|champ|changement », ou nil
function ADResumeHeader.stageOf(vehicle, mode)
    if ADHeaderFlow == nil then
        return nil
    end
    local job = vehicle.ad.fpHeaderJob
    local hs = mode.headerStage
    if mode.parkStage ~= nil then
        -- barre attelée dans l'entrée du champ, petit recul puis départ (AutonomousHeaderClear.lua) : la barre est prise
        if mode.parkThen == "restart" and job ~= nil and job.combine == vehicle and job.phase == "deliver" then
            hs = "taken"
        else
            return nil -- retour au garage (AutonomousResumeReturn.lua) ou changement d'outil (« swap »)
        end
    end
    if job ~= nil and JOB_STAGES[job.phase] and (job.tractor == vehicle or job.combine == vehicle) and not job.cancelled then
        local role = job.tractor == vehicle and "t" or "c"
        local stage = hs or (mode.headerFetch ~= nil and "fetch") or (role == "t" and "start") or "wait"
        return joinFields({ role, job.phase, stage, uidOf(job.combine), uidOf(job.tractor), uidOf(job.trailer), uidOf(job.header),
            markerSave(job.fieldId), job.swap and "1" or "0" })
    end
    if job ~= nil and job.combine == vehicle and hs == "waitClear" then
        return joinFields({ "c", "deliver", "taken", uidOf(job.combine), uidOf(job.tractor), uidOf(job.trailer), uidOf(job.header),
            markerSave(job.fieldId), "0" })
    end
    if hs == "tankWait" or hs == "fieldEndWait" or hs == "waitTractor" or hs == "park" then
        return joinFields({ "c", "-", hs })
    end
    -- (16/11) champ suivant, personne de libre pour la remorque porte-barre (AutonomousHeaderNextField.lua) : le
    -- champ fini est gardé, la remorque y viendra
    local carry = vehicle.ad.fpHeaderCarry
    if hs == "carryWait" and carry ~= nil and carry.prevField ~= nil then
        return joinFields({ "c", "-", "carryWait", "-", "-", "-", "-", markerSave(carry.prevField) })
    end
    if hs == "toHeader" and mode.headerGoal ~= nil then
        return joinFields({ "c", "-", "fetch", "-", "-", "-", uidOf(mode.headerGoal) })
    end
    if hs == nil and mode.headerFetch ~= nil and ADHeaderFlow.isCombine(vehicle) then
        return joinFields({ "c", "-", "fetch", "-", "-", "-", uidOf(mode.headerFetch) })
    end
    if hs == "home" then
        return joinFields({ "t", "-", "home" })
    end
    return nil
end

-- travail de la barre : celui en mémoire (relance après blocage, ou l'autre véhicule déjà reparti), sinon refait
local function jobFor(vehicle, d)
    local combine = d.role == "c" and vehicle or byUid(d.combine)
    local tractor = d.role == "t" and vehicle or byUid(d.tractor)
    local trailer, header = byUid(d.trailer), byUid(d.header)
    local field = markerLoad(d.field)
    if isGone(combine) or isGone(tractor) or isGone(trailer) or isGone(header) or field == nil then
        return nil, string.format("%s introuvable", isGone(combine) and "moissonneuse" or isGone(tractor) and "tracteur"
            or isGone(trailer) and "remorque porte-barre" or isGone(header) and "barre" or "champ")
    end
    for _, v in ipairs({ vehicle, combine, tractor }) do
        local job = v.ad ~= nil and v.ad.fpHeaderJob or nil
        -- (amenée : barre prise entre-temps, le travail est passé à « harvest »)
        if job ~= nil and job.combine == combine and job.tractor == tractor and job.header == header and job.trailer == trailer
            and (job.phase == d.phase or (d.phase == "deliver" and job.phase == "harvest")) and not job.cancelled then
            combine.ad.fpHeaderJob = job
            tractor.ad.fpHeaderJob = job
            return job
        end
    end
    local job = ADHeaderFlow.newJob(combine, tractor, trailer, header, field.markerIndex, d.phase)
    job.swap = d.swap
    return job
end

local function parse(data)
    local p = split(data)
    local function f(i)
        local s = p[i]
        return (s ~= nil and s ~= "" and s ~= "-") and s or nil
    end
    return { role = f(1), phase = f(2), stage = f(3), combine = f(4), tractor = f(5), trailer = f(6), header = f(7),
        field = f(8), swap = f(9) == "1" }
end
ADResumeHeader.parse = parse

-- la moissonneuse, la barre prise : le tracteur dégage d'abord, puis départ au champ
local function combineTaken(mode, job, name)
    job.headerTaken = true
    if not ADResumeStage.activate(mode) then
        return false
    end
    if ADHeaderFlow.startClearWait ~= nil and ADHeaderFlow.startClearWait(mode, job) then
        log("%s : partie rechargée, barre « %s » déjà prise : attend que le tracteur ait dégagé, puis départ au champ", name, label(job.header))
        return true
    end
    log("%s : partie rechargée, barre « %s » déjà prise : départ au champ", name, label(job.header))
    return false -- départ habituel (barre prise : AutonomousHeader.lua, onStart)
end

local function resumeCombine(mode, d, name)
    local v = mode.vehicle
    if d.phase == nil then
        if d.stage == "tankWait" or d.stage == "fieldEndWait" then
            local header = ADHeaderFlow.attachedHeader(v)
            if header == nil then
                log("%s : partie rechargée pendant la fin de champ, plus de barre attelée : départ habituel", name)
                return false
            end
            if ADHeaderFlow.tankLevel(v) >= ADHeaderFlow.tankEmptyMin() then
                log("%s : partie rechargée en fin de champ, trémie pas vidée : attend d'être vidée avant de reposer « %s »", name, label(header))
                return ADHeaderFlow.startTankWait(v, header) == true
            end
            log("%s : partie rechargée en fin de champ : la repose de « %s » reprend", name, label(header))
            return ADHeaderFlow.fieldEndTry(v, header, false, false) == true
        end
        if d.stage == "waitTractor" then
            if not ADResumeStage.activate(mode) then
                return false
            end
            log("%s : partie rechargée, barre reposée : attend un tracteur libre pour la barre suivante", name)
            ADHeaderFlow.startWait(mode, "waitTractor", function() return ADHeaderFlow.readyToDeliver(v) end)
            return true
        end
        if d.stage == "carryWait" then
            -- (16/11) champ suivant, en attente d'un tracteur ou d'une remorque porte-barre : nouvel essai tout de suite
            local header = ADHeaderFlow.attachedHeader(v)
            local done = markerLoad(d.field)
            if header == nil or done == nil or ADHeaderFlow.startCarry == nil then
                log("%s : partie rechargée en attente de la remorque pour le champ suivant, plus de barre ou de champ fini : départ habituel", name)
                return false
            end
            log("%s : partie rechargée en attente de la remorque pour le champ suivant : nouvel essai (« %s » reposée à « %s »)", name, label(header), tostring(done.name))
            v.ad.fpHeaderPrevField = done.markerIndex
            local ok, started = FarmPilotCall(ADHeaderFlow.startCarry, v, header, false)
            v.ad.fpHeaderPrevField = nil
            return ok and started == true
        end
        if d.stage == "park" then
            local park = v.advd ~= nil and v.advd.parkDestination or -1
            if ADHeaderFlow.attachedHeader(v) ~= nil or park == nil or park < 1 then
                return false
            end
            if not ADResumeStage.activate(mode) then
                return false
            end
            log("%s : partie rechargée, barre reposée : va à sa place", name)
            local job = { combine = v, swap = false }
            v.ad.fpHeaderJob = job
            ADHeaderFlow.combineStage(mode, job, "backoff", "ok") -- la route de sa place (AutonomousHeader.lua)
            return true
        end
        if d.stage == "fetch" then
            local header = byUid(d.header)
            if header == nil or ADHeaderFlow.attachedHeader(v) ~= nil then
                return false
            end
            if not ADResumeStage.activate(mode) then
                return false
            end
            log("%s : partie rechargée en route vers « %s » : elle y retourne", name, label(header))
            ADHeaderFlow.goToHeader(mode, header)
            return true
        end
        return false
    end
    if d.phase == "deliver" and (d.stage == "taken" or ADHeaderFlow.attachedHeader(v) == byUid(d.header)) then
        -- barre prise : le travail de la moissonneuse seule (« harvest »), celui du tracteur n'est pas refait
        local live = v.ad.fpHeaderJob
        local header = byUid(d.header)
        if header == nil or ADHeaderFlow.attachedHeader(v) ~= header then
            return false
        end
        if live == nil or live.header ~= header or live.combine ~= v then
            live = { combine = v, tractor = byUid(d.tractor), trailer = byUid(d.trailer), header = header,
                fieldId = (markerLoad(d.field) or {}).markerIndex, phase = "harvest", trailerReady = false, headerTaken = true,
                headerDropped = false, cancelled = false }
            v.ad.fpHeaderJob = live
        end
        if live.tractor == nil then
            log("%s : partie rechargée, barre « %s » déjà prise : départ au champ", name, label(header))
            return false
        end
        return combineTaken(mode, live, name)
    end
    local job, why = jobFor(v, d)
    if job == nil then
        log("%s : partie rechargée pendant le travail de la barre, %s : départ habituel", name, tostring(why))
        return false
    end
    local attached = ADHeaderFlow.attachedHeader(v) == job.header
    if d.phase == "deliver" then
        if attached or d.stage == "taken" then
            return combineTaken(mode, job, name)
        end
        if job.phase ~= "deliver" then
            return false
        end
        if ADHeaderFlow.trailerOf(job.header) ~= job.trailer then
            ADHeaderFlow.endJob(job)
            log("%s : partie rechargée, la barre n'est plus sur « %s » : départ habituel", name, label(job.trailer))
            return false
        end
        if not ADResumeStage.activate(mode) then
            return false
        end
        if d.stage == "fetch" or d.stage == "toHeader" or job.trailerReady then
            log("%s : partie rechargée, remorque au champ : va atteler « %s »", name, label(job.header))
            ADHeaderFlow.goToHeader(mode, job.header)
        elseif d.stage == "waitLeave" or d.stage == "follow" or d.stage == "followWait" then
            -- (18/11, LEXION 6900 : « attend que ARION 570 parte devant », l'ARION garé à GT6, arrêté : attente sans
            -- fin) tracteur à l'arrêt sans reprise à lui : rappelé pour la remorque ; s'il ne part pas, départ habituel (un autre
            -- tracteur libre est choisi)
            local tsm = job.tractor ~= nil and job.tractor.ad ~= nil and job.tractor.ad.stateModule or nil
            if tsm ~= nil and not tsm:isActive() and tsm.fpAutoStage == nil then
                if ADHeaderFlow.callTractor(job) then
                    log("%s : partie rechargée, « %s » était à l'arrêt : rappelé pour la remorque « %s »", name, nameOf(job.tractor), label(job.trailer))
                else
                    ADHeaderFlow.endJob(job)
                    log("%s : partie rechargée, « %s » à l'arrêt ne repart pas : départ habituel (autre tracteur)", name, nameOf(job.tractor))
                    return false
                end
            end
            log("%s : partie rechargée, attend que « %s » parte devant avec la barre, puis le suit", name, nameOf(job.tractor))
            ADHeaderFlow.startWaitLeave(mode, job)
        else
            log("%s : partie rechargée, attend la remorque de « %s » (%s)", name, nameOf(job.tractor), tostring(d.stage))
            ADHeaderFlow.startWait(mode, "waitTrailer", function() return job.trailerReady or job.cancelled end)
        end
        return true
    end
    -- « collect »
    if not attached then
        if not ADResumeStage.activate(mode) then
            return false
        end
        job.headerDropped = true
        log("%s : partie rechargée, barre déjà reposée sur « %s »%s", name, label(job.trailer), job.swap and " : attend la barre suivante" or " : va à sa place")
        ADHeaderFlow.combineStage(mode, job, "backoff", "ok") -- sa place, ou la barre suivante (AutonomousHeader.lua)
        return true
    end
    if not ADResumeStage.activate(mode) then
        return false
    end
    if job.trailerReady then
        log("%s : relancée, remorque à côté : va poser la barre", name)
        ADHeaderFlow.startDrop(mode, job)
        return true
    end
    log("%s : partie rechargée, attend que « %s » amène la remorque à côté d'elle (%s)", name, nameOf(job.tractor), tostring(d.stage))
    ADHeaderFlow.startWait(mode, "waitCollect", function() return job.trailerReady or job.cancelled end)
    return true
end

local function resumeTractor(mode, d, name)
    local t = mode.vehicle
    if d.phase == nil then
        if d.stage == "home" then
            if not ADResumeStage.activate(mode) then
                return false
            end
            log("%s : partie rechargée en rentrant avec la remorque : il rentre", name)
            ADHeaderFlow.goHome(mode, nil)
            return true
        end
        return false
    end
    local job, why = jobFor(t, d)
    if job == nil then
        -- jamais au champ avec la remorque porte-barre comme outil de travail
        log("%s : partie rechargée pendant le travail de la barre, %s : arrêt", name, tostring(why))
        if t.ad.stateModule:isActive() then
            t:stopAutoDrive()
        end
        return true
    end
    local onCombine = ADHeaderFlow.attachedHeader(job.combine) == job.header
    local onTrailer = ADHeaderFlow.trailerOf(job.header) == job.trailer
    local hitched = attachedTo(job.trailer, t)
    if d.phase == "deliver" then
        if onCombine then
            if not ADResumeStage.activate(mode) then
                return false
            end
            job.headerTaken = true
            job.phase = "harvest"
            job.backIn = nil
            t.ad.fpHeaderJob = nil
            log("%s : partie rechargée, barre déjà prise : la remorque vide va à sa place", name)
            ADHeaderFlow.parkTrailer(mode, job)
            return true
        end
        if d.stage == "wait" and hitched and onTrailer then
            if not ADResumeStage.activate(mode) then
                return false
            end
            log("%s : partie rechargée, remorque en place : attend la moissonneuse", name)
            ADHeaderFlow.tractorWait(mode, job)
            return true
        end
        log("%s : partie rechargée pendant l'amenée de « %s » (%s) : elle reprend", name, label(job.header), tostring(d.stage))
        return ADHeaderFlow.tractorStart(mode, job) == true
    end
    -- « collect »
    if not onCombine and onTrailer then
        if not ADResumeStage.activate(mode) then
            return false
        end
        job.headerDropped = true
        t.ad.fpHeaderJob = nil
        log("%s : partie rechargée, barre déjà posée : la remorque va à sa place", name)
        ADHeaderFlow.parkTrailer(mode, job)
        return true
    end
    if hitched and (d.stage == "wait" or d.stage == "intoField" or d.stage == "intoFieldRetry") then
        if not ADResumeStage.activate(mode) then
            return false
        end
        log("%s : partie rechargée dans le champ : revient à côté de la moissonneuse", name)
        ADHeaderFlow.collectEnter(mode, job) -- déjà bien placé : il attend (AutonomousHeaderCollect.lua)
        return true
    end
    log("%s : partie rechargée en allant reprendre « %s » (%s) : il reprend", name, label(job.header), tostring(d.stage))
    return ADHeaderFlow.tractorStart(mode, job) == true
end

function ADResumeHeader.resume(mode, data)
    if ADHeaderFlow == nil then
        return false
    end
    local d = parse(data)
    local name = nameOf(mode.vehicle)
    if d.role == "c" and ADHeaderFlow.isCombine(mode.vehicle) then
        return resumeCombine(mode, d, name)
    elseif d.role == "t" then
        return resumeTractor(mode, d, name)
    end
    return false
end

if ADResumeStage ~= nil then
    ADResumeStage.register("header", { stage = ADResumeHeader.stageOf, resume = ADResumeHeader.resume })
end

-- ------------------------------------------------------------------------------------------------------------
-- 2. Barre prise sur une remorque (#fpHeaderFrom = « barre|remorque »)
-- ------------------------------------------------------------------------------------------------------------
function ADResumeHeader.headerFromText(vehicle)
    if ADHeaderFlow == nil or ADHeaderGround == nil or not ADHeaderFlow.isCombine(vehicle) then
        return nil
    end
    local header = ADHeaderFlow.attachedHeader(vehicle)
    if header == nil then
        return nil
    end
    local trailer = ADHeaderGround.fromTrailer[header]
    local job = vehicle.ad.fpHeaderJob
    if trailer == nil and job ~= nil and job.header == header then
        trailer = job.trailer
    end
    local hu, tu = uidOf(header), uidOf(trailer)
    if hu ~= nil and tu ~= nil then
        return hu .. "|" .. tu
    end
    local sm = vehicle.ad.stateModule
    return sm ~= nil and sm.fpHeaderFrom or nil -- pas encore retrouvée depuis le chargement
end

if ADHeaderGround ~= nil and ADHeaderGround.cameFromTrailer ~= nil then
    local baseCame = ADHeaderGround.cameFromTrailer
    function ADHeaderGround.cameFromTrailer(combine, header)
        if baseCame(combine, header) then
            return true
        end
        local sm = combine ~= nil and combine.ad ~= nil and combine.ad.stateModule or nil
        local text = sm ~= nil and sm.fpHeaderFrom or nil
        if text == nil or header == nil then
            return false
        end
        local hu, tu = string.match(text, "^([^|]+)|(.+)$")
        if hu == nil or hu ~= uidOf(header) then
            return false
        end
        local trailer = byUid(tu)
        if trailer == nil then
            return false
        end
        ADHeaderGround.fromTrailer[header] = trailer
        log("%s : barre « %s » prise sur « %s » (partie rechargée) : jamais reposée par la route", nameOf(combine), label(header), label(trailer))
        return true
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- 3. Bennes en « Décharger moissonneuse » (#fpUnloadStage)
-- ------------------------------------------------------------------------------------------------------------
function ADResumeHeader.unloadStage(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or not sm:isActive() or AutoDrive.MODE_UNLOAD == nil or sm:getMode() ~= AutoDrive.MODE_UNLOAD then
        return nil
    end
    local mode = vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or mode.state == nil then
        return nil
    end
    local done = vehicle.ad.harvestJobDone == true
    if mode.state == mode.STATE_DRIVE_TO_UNLOAD or mode.state == mode.STATE_EXIT_FIELD then
        return done and "unloadPark" or "unload"
    end
    if mode.state == mode.STATE_PARK or (done and mode.state == mode.STATE_DRIVE_TO_START) then
        return "park"
    end
    return nil
end

local function unloadLevel(mode)
    local trailers = AutoDrive.getAllUnits(mode.vehicle)
    if trailers == nil or #trailers == 0 then
        return 0
    end
    local level = AutoDrive.getAllFillLevels(trailers)
    return tonumber(level) or 0
end

-- true = la benne a repris son étape
function ADResumeHeader.resumeUnload(mode, value)
    local v = mode.vehicle
    local sm = v.ad.stateModule
    local name = nameOf(v)
    if sm:getFirstMarker() == nil or sm:getSecondMarker() == nil then
        return false
    end
    if not sm:isActive() then
        v:startAutoDrive()
        if not sm:isActive() then
            return false
        end
    end
    mode.fpHitch = nil -- comme ADTrailerHitch.beforeStart
    if ADTrailerSwap ~= nil and ADTrailerSwap.cancel ~= nil then
        ADTrailerSwap.cancel(mode)
    end
    mode:reset()
    v.ad.harvestJobDone = nil
    local level = unloadLevel(mode)
    local loaded = level >= ADResumeHeader.UNLOAD_MIN
    if value == "park" or (value == "unloadPark" and not loaded) then
        v.ad.harvestJobDone = true
        local task = mode:getParkAfterJobTask(string.format("partie rechargée (%.0f l)", level))
        if task == nil then
            log("%s : partie rechargée en rentrant au parking, pas de parking réglé : départ habituel", name)
            v.ad.harvestJobDone = nil
            return false
        end
        log("%s : partie rechargée en rentrant au parking (%.0f l) : il continue de rentrer", name, level)
        mode.activeTask = task
        v.ad.taskModule:addTask(task)
        return true
    end
    if not loaded then
        log("%s : partie rechargée après avoir vidé (%.0f l) : retour au champ", name, level)
        return false -- départ habituel : vide, retour au champ
    end
    v.ad.harvestJobDone = value == "unloadPark" or nil
    if mode.leaveUnloaderQueue ~= nil then
        mode:leaveUnloaderQueue("partie rechargée, part vider")
    end
    if ADHarvestManager ~= nil and ADHarvestManager.unregisterAsUnloader ~= nil then
        ADHarvestManager:unregisterAsUnloader(v)
    end
    mode.combine = nil
    mode.followingUnloader = nil
    local x, y, z = getWorldTranslation(v.components[1].node)
    local start = sm:getFirstMarker()
    local point = start ~= nil and start.id ~= nil and ADGraphManager:getWayPointById(start.id) or nil
    local fromStart = point ~= nil and MathUtil.vector2Length(x - point.x, z - point.z) or 0
    local task
    if AutoDrive.checkIsOnField(x, y, z) and fromStart > ADResumeHeader.FIELD_EXIT_FROM then
        task = ExitFieldTask:new(v)
        mode.state = mode.STATE_EXIT_FIELD
    else
        task = UnloadAtDestinationTask:new(v, sm:getSecondMarker().id)
        mode.state = mode.STATE_DRIVE_TO_UNLOAD
    end
    log("%s : partie rechargée en allant vider (%.0f l) : il retourne vider%s", name, level, value == "unloadPark" and ", puis le parking" or ", puis le champ")
    mode.activeTask = task
    v.ad.taskModule:addTask(task)
    return true
end

if CombineUnloaderMode ~= nil and CombineUnloaderMode.start ~= nil then
    local baseStart = CombineUnloaderMode.start
    function CombineUnloaderMode:start(user, ...)
        local sm = self.vehicle ~= nil and self.vehicle.ad ~= nil and self.vehicle.ad.stateModule or nil
        local value = sm ~= nil and sm.fpUnloadStage or nil
        if value ~= nil and not sm.fpUnloadStageLoaded then
            local now = g_time or 0
            if now < (sm.fpUnloadStageTime or 0) or now - (sm.fpUnloadStageTime or 0) > ADResumeStage.RESTART_VALID then
                value = nil -- relance pas faite (arrêtée entre-temps) : départ habituel
            end
        end
        if sm ~= nil then
            sm.fpUnloadStage = nil -- une seule fois
            sm.fpUnloadStageLoaded = nil
            sm.fpUnloadStageTime = nil
        end
        -- remorque choisie pas attelée : elle va l'atteler d'abord (TrailerHitch.lua), départ habituel
        local hitchFirst = false
        if value ~= nil and ADTrailerHitch ~= nil and ADTrailerHitch.isTrailerMode ~= nil and ADTrailerHitch.isTrailerMode(self.vehicle) then
            local okT, trailer, err = FarmPilotCall(ADTrailerHitch.trailerToFetch, self.vehicle)
            hitchFirst = not okT or trailer ~= nil or err ~= nil
        end
        if value ~= nil and not hitchFirst then
            local ok, done = FarmPilotCall(ADResumeHeader.resumeUnload, self, value)
            if not ok then
                log("ERREUR reprise de la benne « %s » : %s", tostring(value), tostring(done))
            elseif done then
                return
            end
        end
        return baseStart(self, user, ...)
    end
end

if ADTaskModule ~= nil and ADTaskModule.stopAndRestartAD ~= nil then
    local baseRestart = ADTaskModule.stopAndRestartAD
    function ADTaskModule:stopAndRestartAD(...)
        local vehicle = self.vehicle
        local okS, value = FarmPilotCall(ADResumeHeader.unloadStage, vehicle)
        if okS and value ~= nil then
            local sm = vehicle.ad.stateModule
            local now = g_time or 0
            local r = sm.fpUnloadStageRestarts
            if r == nil or now < r.first or now - r.first > ADResumeStage.RESTART_WINDOW then
                r = { first = now, count = 0 }
                sm.fpUnloadStageRestarts = r
            end
            r.count = r.count + 1
            if r.count < ADResumeStage.RESTART_MAX then
                sm.fpUnloadStage = value
                sm.fpUnloadStageLoaded = nil
                sm.fpUnloadStageTime = now
                log("%s : bloquée pendant l'étape « %s » : AutoDrive relancé, l'étape reprendra", nameOf(vehicle), value)
            else
                sm.fpUnloadStageRestarts = nil
                log("%s : bloquée %d fois pendant l'étape « %s » : plus de reprise, départ habituel", nameOf(vehicle), ADResumeStage.RESTART_MAX, value)
            end
        end
        return baseRestart(self, ...)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- 4. Bennes qui suivront la moissonneuse au champ suivant (#fpUnloaderFollow)
-- « f|ancien champ|nouveau champ|benne,benne » (bennes notées) ou « w|nouveau champ » (son équipe sera rappelée)
-- ------------------------------------------------------------------------------------------------------------
function ADResumeHeader.followText(vehicle)
    if ADHarvesterUnloaders == nil then
        return nil
    end
    local entry = ADHarvesterUnloaders.pending[vehicle]
    if entry ~= nil and entry.old ~= nil and entry.new ~= nil then
        local crew = {}
        for unloader in pairs(entry.crew or {}) do
            local u = uidOf(unloader)
            if u ~= nil then
                crew[#crew + 1] = u
            end
        end
        table.sort(crew)
        if #crew > 0 then
            return string.format("f|%s|%s|%s", tostring(markerSave(entry.old)), tostring(markerSave(entry.new)), table.concat(crew, ","))
        end
    end
    local watch = ADHarvesterUnloaders.recallWatch[vehicle]
    if watch ~= nil and watch.new ~= nil then
        return string.format("w|%s", tostring(markerSave(watch.new)))
    end
    local sm = vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    return sm ~= nil and sm.fpUnloaderFollow or nil -- pas encore repris depuis le chargement
end

-- (à chaque image) les suivis lus dans la sauvegarde, une fois les véhicules chargés
function ADResumeHeader.restoreFollow()
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    for _, v in pairs(system ~= nil and system.vehicles or {}) do
        local sm = v.ad ~= nil and v.ad.stateModule or nil
        local text = sm ~= nil and sm.fpUnloaderFollow or nil
        if text ~= nil then
            sm.fpUnloaderFollow = nil
            local p = split(text)
            local kind, a, b, list = p[1], p[2], p[3], p[4]
            if kind == "f" then
                local old, new = markerLoad(a), markerLoad(b)
                local crew, count = {}, 0
                for u in string.gmatch(list or "", "([^,]+)") do
                    local unloader = byUid(u)
                    if unloader ~= nil then
                        crew[unloader] = true
                        count = count + 1
                    end
                end
                if old ~= nil and new ~= nil and count > 0 and ADHarvesterUnloaders.pending[v] == nil then
                    ADHarvesterUnloaders.pending[v] = { old = old, new = new, crew = crew, since = g_time, ready = false, nextTry = 0 }
                    log("%s : partie rechargée, %d benne(s) de « %s » la suivront à « %s » quand elle aura repris le travail", nameOf(v), count,
                        tostring(old.name), tostring(new.name))
                end
            elseif kind == "w" then
                local new = markerLoad(a)
                if new ~= nil and ADHarvesterUnloaders.recallWatch[v] == nil then
                    ADHarvesterUnloaders.recallWatch[v] = { new = new, since = g_time }
                    log("%s : partie rechargée, son équipe sera rappelée à « %s » quand elle aura repris le travail", nameOf(v), tostring(new.name))
                end
            end
        end
    end
end

ADResumeHeader.followPending = false

if ADHarvesterUnloaders ~= nil and ADHarvesterUnloaders.update ~= nil then
    local baseUpdate = ADHarvesterUnloaders.update
    function ADHarvesterUnloaders.update(dt)
        if ADResumeHeader.followPending then
            ADResumeHeader.followPending = false
            local ok, err = FarmPilotCall(ADResumeHeader.restoreFollow)
            if not ok then
                log("ERREUR bennes au champ suivant après le chargement : %s", tostring(err))
            end
        end
        return baseUpdate(dt)
    end
end

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
            local vehicle = stateModule.vehicle
            if vehicle == nil or vehicle.ad == nil then
                return
            end
            local unload = nil
            if stateModule.active then
                unload = ADResumeHeader.unloadStage(vehicle)
            elseif stateModule.fpUnloadStageLoaded then
                unload = stateModule.fpUnloadStage -- pas encore repartie depuis le chargement
            end
            if unload ~= nil then
                xmlFile:setValue(key .. "#fpUnloadStage", unload)
            end
            local from = ADResumeHeader.headerFromText(vehicle)
            if from ~= nil then
                xmlFile:setValue(key .. "#fpHeaderFrom", from)
            end
            local follow = ADResumeHeader.followText(vehicle)
            if follow ~= nil then
                xmlFile:setValue(key .. "#fpUnloaderFollow", follow)
            end
        end)
        if not ok then
            log("ERREUR sauvegarde de l'étape (barre, benne) : %s", tostring(err))
        end
    end

    local baseLoad = ADSavegameResume.load
    function ADSavegameResume.load(stateModule, xmlFile, key, ...)
        if baseLoad ~= nil then
            baseLoad(stateModule, xmlFile, key, ...)
        end
        local function read(name)
            local ok, value = FarmPilotCall(xmlFile.getValue, xmlFile, key .. "#" .. name)
            if ok and type(value) == "string" and value ~= "" then
                return value
            end
            return nil
        end
        stateModule.fpUnloadStage = read("fpUnloadStage")
        stateModule.fpUnloadStageLoaded = stateModule.fpUnloadStage ~= nil or nil
        stateModule.fpHeaderFrom = read("fpHeaderFrom")
        stateModule.fpUnloaderFollow = read("fpUnloaderFollow")
        if stateModule.fpUnloaderFollow ~= nil then
            ADResumeHeader.followPending = true
        end
    end
end
