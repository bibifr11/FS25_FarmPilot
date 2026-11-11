-- #############################################################################
-- FarmPilot : filtre du log
-- Les lignes de suivi ([AD-...], [FarmPilot ...], [AutoDriveSync], [carte], [intersection])
-- ne sont écrites que si un canal debug FarmPilot est actif.
-- Les lignes qui signalent une erreur passent toujours.
-- Traces privées (fichier à part, interrupteur sur le PC) : FarmPilotTraces.lua.
-- Branché par : register.lua (premier fichier chargé)
-- #############################################################################

-- =============================================================================
-- Réglages
-- =============================================================================
local TAGS = { "^%[AD%-", "^%[AD%]", "^%[FarmPilot ", "^%[AutoDriveSync%]", "^AutoDrive : %[carte%]", "^AutoDrive : %[intersection%]" }
local ALWAYS = { "erreur", "error", "echec", "échec" }

-- =============================================================================
-- Helpers
-- =============================================================================
local rawPrint = print

local function isTraceLine(s)
    for _, p in ipairs(TAGS) do
        if string.find(s, p) then
            return true
        end
    end
    return false
end

local function isErrorLine(s)
    local l = string.lower(s)
    for _, w in ipairs(ALWAYS) do
        if string.find(l, w, 1, true) then
            return true
        end
    end
    return false
end

local function debugActive()
    return AutoDrive ~= nil and (AutoDrive.currentDebugChannelMask or 0) > 0
end

-- =============================================================================
-- print du mod
-- =============================================================================
function print(first, ...)
    if type(first) == "string" and isTraceLine(first) then
        -- certaines lignes de suivi sont gardées au journal du mode Autonome, voir ADAutonomousManager.journalTrace
        if ADAutonomousManager ~= nil and ADAutonomousManager.journalTrace ~= nil then
            ADAutonomousManager.journalTrace(first)
        end
        -- traces privées : toutes les lignes de suivi dans leur fichier quand l'interrupteur est posé, voir FarmPilotTraces.lua
        if ADTraces ~= nil then
            ADTraces.add(first)
        end
        if not debugActive() and not isErrorLine(first) then
            return
        end
    end
    rawPrint(first, ...)
end

-- =============================================================================
-- Appels protégés : l'erreur est écrite dans le log (une fois par message)
-- Mêmes retours que pcall : ok, résultats... ou false, message.
-- =============================================================================
local rawPcall = pcall
local reported = {}
local reportedCount = 0

local function report(err)
    local msg = tostring(err)
    if reported[msg] == nil and reportedCount < 100 then
        reported[msg] = true
        reportedCount = reportedCount + 1
        rawPrint("Error: [FarmPilot] " .. msg)
    end
end

local function finish(ok, ...)
    if not ok then
        report(...)
    end
    return ok, ...
end

function FarmPilotCall(f, ...)
    return finish(rawPcall(f, ...))
end
