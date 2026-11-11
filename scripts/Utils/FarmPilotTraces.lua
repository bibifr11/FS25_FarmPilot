-- ============================================================================================================
-- FarmPilot : FarmPilotTraces.lua
-- Traces privées : toutes les lignes de suivi du mod dans un fichier à part, sans toucher à log.txt.
--
-- (11/11) Les lignes de suivi ([AD-...], [FarmPilot ...]) ne vont dans log.txt qu'avec un canal debug. Pour relire
-- un essai dans le détail (point de départ d'une route, fin d'une courbe…), elles sont écrites dans leur propre
-- fichier quand l'interrupteur est posé.
--
-- Règle :
-- - interrupteur = le fichier SWITCH_FILE présent dans le dossier modSettings du mod (son contenu ne compte pas).
--   Absent (cas de tous les joueurs) : rien n'est gardé, rien n'est écrit, aucun calcul en plus ;
-- - présent : les LINES dernières lignes de suivi sont écrites dans FILE, au même endroit, au plus une fois toutes
--   les DELAY ms ; l'interrupteur est regardé toutes les CHECK ms (pas besoin de relancer le jeu) ;
-- - log.txt ne change pas (filtre du log, FarmPilotLogFilter.lua).
--
-- Branché par : print du mod (FarmPilotLogFilter.lua), AutoDrive:update (AutoDrive.lua, écriture des lignes en
-- attente), register.lua (chargé juste après le filtre du log).
-- ============================================================================================================

ADTraces = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADTraces.SWITCH_FILE = "FarmPilot_traces.txt" -- présent = traces allumées
ADTraces.FILE = "traces_farmpilot.xml"
ADTraces.LINES = 2000   -- dernières lignes gardées
ADTraces.DELAY = 2000   -- ms au moins entre deux écritures du fichier
ADTraces.CHECK = 5000   -- ms entre deux regards sur l'interrupteur

ADTraces.lines = {}
ADTraces.dirty = false
ADTraces.written = nil  -- g_time de la dernière écriture
ADTraces.on = false
ADTraces.checked = nil  -- g_time du dernier regard sur l'interrupteur

-- ------------------------------------------------------------------------------------------------------------
-- Interrupteur
-- ------------------------------------------------------------------------------------------------------------
local function folder()
    if AutoDrive == nil or AutoDrive.getModSettingsFolder == nil then
        return nil
    end
    return AutoDrive.getModSettingsFolder()
end

-- true si les traces privées sont allumées (regardé au plus toutes les CHECK ms)
function ADTraces.isOn()
    local now = g_time or 0
    local last = ADTraces.checked
    if last ~= nil and now >= last and now - last < ADTraces.CHECK then
        return ADTraces.on
    end
    local dir = fileExists ~= nil and folder() or nil
    if dir == nil then
        return false -- pas encore chargé : on regardera de nouveau au prochain appel
    end
    ADTraces.checked = now
    ADTraces.on = fileExists(dir .. ADTraces.SWITCH_FILE) == true
    return ADTraces.on
end

-- ------------------------------------------------------------------------------------------------------------
-- Fichier
-- ------------------------------------------------------------------------------------------------------------
local function write()
    local dir = folder()
    if dir == nil or createXMLFile == nil then
        return
    end
    createFolder(dir)
    local xml = createXMLFile("FarmPilotTraces", dir .. ADTraces.FILE, "traces")
    if xml == nil or xml == 0 then
        return
    end
    for i, line in ipairs(ADTraces.lines) do
        local key = string.format("traces.line(%d)", i - 1)
        setXMLString(xml, key .. "#t", line.t)
        setXMLInt(xml, key .. "#ms", line.ms)
        setXMLString(xml, key .. "#text", line.text)
    end
    saveXMLFile(xml)
    delete(xml)
end

-- écrit le fichier s'il y a du nouveau ; force : même si la dernière écriture date de moins de DELAY ms
function ADTraces.flush(force)
    if not ADTraces.dirty then
        return
    end
    local now = g_time or 0
    local last = ADTraces.written
    if not force and last ~= nil and now >= last and now - last < ADTraces.DELAY then
        return
    end
    ADTraces.written = now
    ADTraces.dirty = false
    FarmPilotCall(write)
end

-- ------------------------------------------------------------------------------------------------------------
-- Une ligne de suivi (appelé par le print du mod, et directement pour une donnée précise)
-- ------------------------------------------------------------------------------------------------------------
function ADTraces.add(text)
    if type(text) ~= "string" or not ADTraces.isOn() then
        return
    end
    local lines = ADTraces.lines
    lines[#lines + 1] = { t = getDate ~= nil and getDate("%d/%m %H:%M:%S") or "", ms = math.floor(g_time or 0), text = text }
    while #lines > ADTraces.LINES do
        table.remove(lines, 1)
    end
    ADTraces.dirty = true
    ADTraces.flush(false)
end

-- une donnée précise, seulement dans le fichier de traces : le texte n'est formaté que si elles sont allumées
function ADTraces.log(fmt, ...)
    if not ADTraces.isOn() then
        return
    end
    local ok, text = FarmPilotCall(string.format, fmt, ...)
    if ok then
        ADTraces.add(text)
    end
end

-- Hook AutoDrive:update : les lignes en attente sont écrites (traces et journal du mode Autonome)
function ADTraces.update(dt)
    if ADTraces.dirty then
        ADTraces.flush(false)
    end
    if ADAutonomousManager ~= nil and ADAutonomousManager.journalDirty and ADAutonomousManager.journalFlush ~= nil then
        ADAutonomousManager.journalFlush(false)
    end
end
