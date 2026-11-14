-- ============================================================================================================
-- FarmPilot : AutonomousHeaderHookup.lua
-- Mode Autonome, moissonneuse équipée seule : les gestes du chauffeur. Barre attelée : il la verrouille et branche
-- les cardans et l'hydraulique avant de bouger. Barre reposée sur sa remorque : il la verrouille dessus avant de
-- reculer.
--
-- Règle (13/11, comme sur un vrai chantier) :
-- - Barre attelée (celle de son chantier, prise sur sa remorque) : la moissonneuse reste à l'arrêt HOOKUP_TIME ms,
--   l'ATH affiche « Brancher la coupe : verrouillage, cardans, hydraulique ». Ensuite la suite habituelle (recul,
--   le tracteur dégage, départ au champ).
-- - Barre reposée sur sa remorque : la moissonneuse reste à l'arrêt LOCK_TIME ms, l'ATH affiche « Verrouiller la
--   coupe sur le chariot ». Ensuite la suite habituelle (recul, la remorque repart).
-- - Réglage à 0 : pas de pause, comme avant.
--
-- Branché par : enveloppes posées au chargement : ADFrontFlow.afterFetch (Modes/AutonomousFront.lua),
-- ADHeaderFlow.combineStage (Modes/AutonomousHeader.lua : étapes « hookup », « drop », « lock »). Le texte de la
-- pause : Tasks/HeaderDropTask.lua (ADHeaderWaitTask.textKey). Chargé par register.lua après
-- AutonomousHeaderEntry.lua (son enveloppe de afterFetch doit être la première appelée).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.HOOKUP_TIME = 15000    -- ms à l'arrêt après l'attelage de la barre (0 : pas de pause)
ADHeaderFlow.LOCK_TIME = 8000       -- ms à l'arrêt après la pose de la barre sur sa remorque (0 : pas de pause)

local log = ADHeaderFlow.log

local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function label(o)
    return o ~= nil and ADAutonomousManager.toolLabel(o) or "?"
end

-- pause à l'arrêt : l'étape, la durée, le texte affiché dans l'ATH
local function pause(mode, stage, time, textKey)
    mode.headerStage = stage
    mode.headerTask = ADHeaderWaitTask:new(mode.vehicle, function() return false end, time)
    mode.headerTask.textKey = textKey
    mode.vehicle.ad.taskModule:addTask(mode.headerTask)
end

-- ------------------------------------------------------------------------------------------------------------
-- Barre attelée : pause, puis la suite habituelle
-- ------------------------------------------------------------------------------------------------------------
if ADFrontFlow ~= nil and ADFrontFlow.afterFetch ~= nil and ADHeaderWaitTask ~= nil then
    local baseAfterFetch = ADFrontFlow.afterFetch
    function ADFrontFlow.afterFetch(mode, tool)
        local v = mode.vehicle
        local job = v.ad.fpHeaderJob
        if ADHeaderFlow.HOOKUP_TIME > 0 and job ~= nil and not job.cancelled and job.combine == v and job.header == tool and tool ~= nil
            and mode.fpQueue == nil and mode.fetchSide == "front" and mode.hookupDone ~= tool then
            mode.hookupTool = tool
            log("%s : barre « %s » attelée, verrouillage et branchement des cardans et de l'hydraulique (%.0f s)", nameOf(v), label(tool),
                ADHeaderFlow.HOOKUP_TIME / 1000)
            pause(mode, "hookup", ADHeaderFlow.HOOKUP_TIME, "AD_task_autonomous_headerHookup")
            return true
        end
        mode.hookupDone = nil
        return baseAfterFetch(mode, tool)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Étapes de la moissonneuse
-- ------------------------------------------------------------------------------------------------------------
local baseCombineStage = ADHeaderFlow.combineStage
function ADHeaderFlow.combineStage(mode, job, stage, result)
    local v = mode.vehicle
    if stage == "hookup" then
        -- barre branchée : la suite de l'attelage (recul, puis départ)
        local tool = mode.hookupTool
        mode.hookupTool = nil
        mode.headerStage = nil
        mode.headerTask = nil
        mode.hookupDone = tool
        if not ADFrontFlow.afterFetch(mode, tool) then
            mode.hookupDone = nil
            log("%s : barre « %s » branchée, départ vers le champ", nameOf(v), label(tool))
            mode:start()
        end
        return
    end
    if stage == "drop" and result == "ok" and ADHeaderFlow.LOCK_TIME > 0 and not job.cancelled and ADHeaderWaitTask ~= nil then
        log("%s : barre posée sur « %s », verrouillage sur la remorque (%.0f s)", nameOf(v), label(job.trailer), ADHeaderFlow.LOCK_TIME / 1000)
        pause(mode, "lock", ADHeaderFlow.LOCK_TIME, "AD_task_autonomous_headerLock")
        return
    end
    if stage == "lock" then
        -- barre verrouillée : la suite de la pose (recul, la remorque repart)
        return baseCombineStage(mode, job, "drop", "ok")
    end
    return baseCombineStage(mode, job, stage, result)
end
