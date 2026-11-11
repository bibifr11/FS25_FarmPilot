-- ============================================================================================================
-- FarmPilot : AutonomousManager.lua
-- Mode Autonome : arrivé à la cible (comme le mode Conduite), FarmPilot cherche le parcours Courseplay enregistré
-- qui a EXACTEMENT la largeur de l'outil attelé et qui est sur le champ où il arrive, le charge et lance Courseplay.
-- Sinon il s'arrête.
--
-- Règle :
-- - Choix retenu = mémorisé par champ + outil (fichier FarmPilot_Autonome.xml de la sauvegarde) et repris tel quel
--   tant que l'outil, sa largeur et le parcours n'ont pas changé.
-- - Un seul parcours possible : pris et retenu ; aucun, ou plusieurs sans choix retenu : arrêt et attente.
-- - La fenêtre « Parcours Autonome » (AutonomousCoursesGUI.lua) permet de fixer ce choix à l'avance.
--
-- Ce fichier garde la table ADAutonomousManager, ses réglages, l'accès à Courseplay et au mod « Attach Implements
-- Manually », la mémoire champ + outil, le choix du parcours et le lancement de Courseplay. Le reste est rangé par
-- sujet, dans le même dossier (chargés juste après celui-ci, voir register.lua) :
-- - AutonomousManagerFields.lua : champs (sous le véhicule, du marqueur, groupes AutoSwitch), ouvrier du jeu ;
-- - AutonomousManagerTools.lua : outil attelé (largeur, fonction, identité) et outil à aller atteler ;
-- - AutonomousManagerCourses.lua : parcours enregistrés de Courseplay (lecture, lecture pendant le trajet, liste).
--
-- Branché par : AutonomousMode.lua (départ, choix du parcours à l'arrivée), Specialization.lua (startCourse,
-- restartCourse après l'arrêt de FarmPilot), AutoDrive.lua (remise à zéro au chargement de la partie, saveToXml à la
-- sauvegarde, linkCourseplayMouse), AutonomousCoursesGUI.lua (mémoire), FetchToolTask.lua et DetachToolTask.lua
-- (setManualConnections).
-- ============================================================================================================

ADAutonomousManager = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAutonomousManager.FILE_NAME = "FarmPilot_Autonome.xml"
ADAutonomousManager.MAX_FILES = 500        -- garde-fou : fichiers de parcours lus
ADAutonomousManager.SAMPLES = 16           -- points testés par parcours pour trouver son champ
ADAutonomousManager.FIELD_SHARE = 0.5      -- part des points dans le champ pour que le parcours soit « de ce champ »
ADAutonomousManager.WIDTH_STEP = 0.1       -- Courseplay règle la largeur par pas de 10 cm
ADAutonomousManager.assignments = {}       -- [champ .. "|" .. outil] = { field, tool, toolName, width, path, name, manual }
ADAutonomousManager.cache = {}             -- [chemin] = { w, name, pts } ou false
ADAutonomousManager.loaded = false
ADAutonomousManager.PREFETCH_PER_FRAME = 1   -- fichiers de parcours lus par image pendant le trajet
ADAutonomousManager.prefetch = nil          -- lecture en cours : { paths, i }
ADAutonomousManager.prefetched = false      -- cache rempli depuis le dernier départ

-- (10/11) Journal du mode Autonome : les lignes de suivi ne vont dans log.txt qu'avec un canal debug (filtre du
-- log, FarmPilotLogFilter.lua). Les JOURNAL_LINES dernières sont gardées et écrites dans un fichier à part,
-- journal_autonome.xml dans le dossier modSettings du mod, pour relire ce que le tracteur a fait après un essai.
ADAutonomousManager.JOURNAL_FILE = "journal_autonome.xml"
ADAutonomousManager.JOURNAL_LINES = 600
ADAutonomousManager.JOURNAL_DELAY = 1000   -- ms au moins entre deux écritures du fichier
ADAutonomousManager.JOURNAL_MESSAGE_REPEAT = 30000 -- ms avant de réécrire le même message ou la même ligne de suivi
ADAutonomousManager.journal = {}
ADAutonomousManager.journalDirty = false
ADAutonomousManager.journalWritten = nil   -- g_time de la dernière écriture

local function journalWrite()
    local folder = AutoDrive.getModSettingsFolder()
    createFolder(folder)
    local xml = createXMLFile("FarmPilotJournal", folder .. ADAutonomousManager.JOURNAL_FILE, "journal")
    if xml == nil or xml == 0 then
        return
    end
    for i, line in ipairs(ADAutonomousManager.journal) do
        local key = string.format("journal.line(%d)", i - 1)
        setXMLString(xml, key .. "#t", line.t)
        setXMLString(xml, key .. "#text", line.text)
    end
    saveXMLFile(xml)
    delete(xml)
end

-- écrit le fichier s'il y a du nouveau ; force : même si la dernière écriture date de moins de JOURNAL_DELAY ms
function ADAutonomousManager.journalFlush(force)
    if not ADAutonomousManager.journalDirty or createXMLFile == nil or AutoDrive == nil or AutoDrive.getModSettingsFolder == nil then
        return
    end
    local now = g_time or 0
    local last = ADAutonomousManager.journalWritten
    if not force and last ~= nil and now >= last and now - last < ADAutonomousManager.JOURNAL_DELAY then
        return
    end
    ADAutonomousManager.journalWritten = now
    ADAutonomousManager.journalDirty = false
    FarmPilotCall(journalWrite)
end

local function journalAdd(text)
    local journal = ADAutonomousManager.journal
    journal[#journal + 1] = { t = getDate ~= nil and getDate("%d/%m %H:%M:%S") or "", text = text }
    while #journal > ADAutonomousManager.JOURNAL_LINES do
        table.remove(journal, 1)
    end
    ADAutonomousManager.journalDirty = true
    ADAutonomousManager.journalFlush(false)
end

local function log(fmt, ...)
    local text = string.format(fmt, ...)
    print("[FarmPilot Autonome] " .. text)
    journalAdd(text)
end
ADAutonomousManager.log = log

-- (11/11) Lignes de suivi d'autres sujets gardées au journal (le filtre du log les retire de log.txt sans canal
-- debug, FarmPilotLogFilter.lua) : places des bennes au champ et départs pour vider. La même ligne n'est pas
-- réécrite avant JOURNAL_MESSAGE_REPEAT ms.
ADAutonomousManager.JOURNAL_TRACES = { { "^%[AD%-File%] ", "bennes au champ : " }, { "^%[AD%-Vider%] ", "départ pour vider : " } }
ADAutonomousManager.journalLastTrace = nil
ADAutonomousManager.journalLastTraceTime = nil

function ADAutonomousManager.journalTrace(line)
    if type(line) ~= "string" then
        return
    end
    for _, trace in ipairs(ADAutonomousManager.JOURNAL_TRACES) do
        local _, last = string.find(line, trace[1])
        if last ~= nil then
            local now = g_time or 0
            local before = ADAutonomousManager.journalLastTraceTime
            if line == ADAutonomousManager.journalLastTrace and before ~= nil and now >= before and now - before < ADAutonomousManager.JOURNAL_MESSAGE_REPEAT then
                return
            end
            ADAutonomousManager.journalLastTrace = line
            ADAutonomousManager.journalLastTraceTime = now
            journalAdd(trace[2] .. string.sub(line, last + 1))
            return
        end
    end
end

-- (11/11) Les avertissements et les erreurs affichés au joueur vont aussi au journal : après un essai, on relit ce
-- que le chauffeur a annoncé (« ne peut pas rejoindre… »), pas seulement ce qu'il a fait. Le même message n'est
-- pas réécrit avant JOURNAL_MESSAGE_REPEAT ms.
ADAutonomousManager.JOURNAL_MESSAGE_KINDS = { [2] = "avertissement", [3] = "alerte" } -- ADMessagesManager.messageTypes WARN, ERROR
ADAutonomousManager.journalLastMessage = nil
ADAutonomousManager.journalLastMessageTime = nil

function ADAutonomousManager.journalMessage(messageType, text, ...)
    local kind = ADAutonomousManager.JOURNAL_MESSAGE_KINDS[messageType]
    if kind == nil or type(text) ~= "string" then
        return
    end
    local shown = AutoDrive ~= nil and AutoDrive.localize ~= nil and AutoDrive.localize(text) or text
    if select("#", ...) > 0 then
        local ok, formatted = FarmPilotCall(string.format, shown, ...)
        if ok then
            shown = formatted
        end
    end
    local now = g_time or 0
    local last = ADAutonomousManager.journalLastMessageTime
    if shown == ADAutonomousManager.journalLastMessage and last ~= nil and now >= last and now - last < ADAutonomousManager.JOURNAL_MESSAGE_REPEAT then
        return
    end
    ADAutonomousManager.journalLastMessage = shown
    ADAutonomousManager.journalLastMessageTime = now
    log("message affiché (%s) : %s", kind, shown)
end

-- branché sur les deux envois du serveur (AutoDriveMessageEvent, MessageEvent.lua ; sendMessageOrNotification passe
-- par sendNotification)
local function journalMessages(name)
    local original = AutoDriveMessageEvent ~= nil and AutoDriveMessageEvent[name] or nil
    if original == nil then
        return
    end
    AutoDriveMessageEvent[name] = function(vehicle, messageType, text, duration, ...)
        if g_server ~= nil then
            FarmPilotCall(ADAutonomousManager.journalMessage, messageType, text, ...)
        end
        return original(vehicle, messageType, text, duration, ...)
    end
end
journalMessages("sendMessage")
journalMessages("sendNotification")

-- (11/11) Chaque arrêt d'un chauffeur va au journal, avec qui l'a demandé (un bouton : Marche/Arrêt, parking ; ou le
-- chauffeur lui-même : fin de tâche, erreur) et ce qu'il faisait : après un essai, on voit pourquoi un trajet lancé
-- s'est arrêté quelques secondes plus tard. Appelé au début d'AutoDrive:stopAutoDrive (Specialization.lua).
function ADAutonomousManager.journalStop(vehicle)
    local ad = vehicle ~= nil and vehicle.ad or nil
    if g_server == nil or ad == nil or ad.stateModule == nil then
        return
    end
    local doing = nil
    local task = ad.taskModule ~= nil and ad.taskModule.activeTask or nil
    if task ~= nil and task.getI18nInfo ~= nil then
        local ok, info = FarmPilotCall(task.getI18nInfo, task)
        if ok and type(info) == "string" and info ~= "" then
            doing = AutoDrive.localize ~= nil and AutoDrive.localize(info) or info
        end
    end
    log("%s : chauffeur arrêté (%s)%s", tostring(ad.stateModule:getName()), ad.fpStopButtonTime ~= nil and ad.fpStopButtonTime == (g_time or 0) and "au bouton" or "de lui-même",
        doing ~= nil and string.format(", il faisait : %s", tostring(doing)) or "")
end

-- l'arrêt demandé par le bouton Marche/Arrêt (le bouton parking passe par lui quand le chauffeur roule) : noté avec
-- l'heure du jeu, journalStop le reconnaît dans la même image
if ADInputManager ~= nil and ADInputManager.input_start_stop ~= nil then
    local originalStartStop = ADInputManager.input_start_stop
    function ADInputManager:input_start_stop(vehicle, ...)
        if vehicle ~= nil and vehicle.ad ~= nil then
            vehicle.ad.fpStopButtonTime = g_time or 0
        end
        return originalStartStop(self, vehicle, ...)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Courseplay : ses globales (il tourne dans son propre environnement Lua)
-- ------------------------------------------------------------------------------------------------------------
local cpModName = nil
local function modGlobal(modName, name)
    local env = _G[modName]
    if type(env) == "table" then
        local ok, value = FarmPilotCall(function() return env[name] end)
        if ok and value ~= nil then
            return value
        end
    end
    return nil
end

function ADAutonomousManager.cpGlobal(name)
    if cpModName ~= nil then
        return modGlobal(cpModName, name)
    end
    local found = modGlobal("FS25_Courseplay", name)
    if found ~= nil then
        cpModName = "FS25_Courseplay"
        return found
    end
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        local ok, mods = FarmPilotCall(g_modManager.getActiveMods, g_modManager)
        if ok and type(mods) == "table" then
            for _, m in ipairs(mods) do
                local n = m.modName
                if type(n) == "string" and n:lower():find("courseplay", 1, true) then
                    found = modGlobal(n, name)
                    if found ~= nil then
                        cpModName = n
                        return found
                    end
                end
            end
        end
    end
    return nil
end

-- (07/11) clic droit sans effet dans l'éditeur de routes : le clic droit de
-- Courseplay montre / cache la souris, sauf quand le HUD ou l'éditeur d'AutoDrive est ouvert ; Courseplay ne cherche
-- AutoDrive que sous le nom du mod FS25_AutoDrive (log « Auto drive found: false ») : on lui donne FarmPilot
function ADAutonomousManager.linkCourseplayMouse()
    local cp = ADAutonomousManager.cpGlobal("g_Courseplay")
    if type(cp) ~= "table" or cp.autoDrive ~= nil then
        return false
    end
    cp.autoDrive = AutoDrive
    log("Courseplay : clic droit laissé au HUD et à l'éditeur de FarmPilot")
    return true
end

function ADAutonomousManager.hasCp(vehicle)
    return vehicle ~= nil and vehicle.appendLoadedCpCourse ~= nil and vehicle.startCpAtFirstWp ~= nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Mod « Attach Implements Manually » (BayernGamers) : flexibles et prise de force
-- ------------------------------------------------------------------------------------------------------------
-- (07/11) flexibles et prise de force branchés après l'attelage, débranchés avant le dételage, avec les fonctions et
-- les événements du mod (comme le joueur avec ses touches)
local aimModName = nil
local function aimGlobal(name)
    if aimModName == nil then
        aimModName = false
        if type(_G["FS25_attachImplementsManually"]) == "table" then
            aimModName = "FS25_attachImplementsManually"
        elseif g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
            local ok, mods = FarmPilotCall(g_modManager.getActiveMods, g_modManager)
            if ok and type(mods) == "table" then
                for _, m in ipairs(mods) do
                    local n = m.modName
                    if type(n) == "string" and n:lower():find("attachimplementsmanually", 1, true) and type(_G[n]) == "table" then
                        aimModName = n
                        break
                    end
                end
            end
        end
    end
    if aimModName then
        return modGlobal(aimModName, name)
    end
    return nil
end

local function aimJoints(vehicle, tool)
    if vehicle.getImplementIndexByObject == nil or vehicle.getAttacherJointIndexFromImplementIndex == nil then
        return nil
    end
    local index = vehicle:getImplementIndexByObject(tool)
    if index == nil then
        return nil
    end
    local jointDescIndex = vehicle:getAttacherJointIndexFromImplementIndex(index)
    local inputJointDescIndex = nil
    if tool.getActiveInputAttacherJointDescIndex ~= nil then
        inputJointDescIndex = tool:getActiveInputAttacherJointDescIndex()
    elseif tool.spec_attachable ~= nil then
        inputJointDescIndex = tool.spec_attachable.inputAttacherJointDescIndex
    end
    return jointDescIndex, inputJointDescIndex
end

local function aimSendToClients(eventName, vehicle, tool)
    local E = aimGlobal(eventName)
    if g_server ~= nil and type(E) == "table" and E.new ~= nil then
        FarmPilotCall(function() g_server:broadcastEvent(E.new(vehicle, tool), false, nil, vehicle) end)
    end
end

-- connect = true : brancher ; false : débrancher. Renvoie ce qui a changé (« flexibles », « prise de force »)
function ADAutonomousManager.setManualConnections(vehicle, tool, connect)
    local done = {}
    if vehicle == nil or tool == nil then
        return done
    end
    local j, inputJ = aimJoints(vehicle, tool)
    if j == nil then
        return done
    end
    -- prise de force d'abord au débranchement (le mod refuse les flexibles d'un outil encore entraîné)
    local ps = vehicle.spec_attachPowerTakeOffsManually
    if ps ~= nil and type(ps.attachedPTOs) == "table" and vehicle.togglePTOAttachState ~= nil then
        local util = aimGlobal("PowerTakeOffUtil")
        local has = false
        if util ~= nil and util.getHasInputPTO ~= nil and util.getHasOutputPTO ~= nil then
            local ok, r = FarmPilotCall(function() return util.getHasInputPTO(tool, inputJ) and util.getHasOutputPTO(vehicle, j) end)
            has = ok and r == true
        end
        if has and (ps.attachedPTOs[j] ~= nil) ~= connect then
            vehicle:togglePTOAttachState(tool, j, inputJ)
            if (ps.attachedPTOs[j] ~= nil) == connect then
                aimSendToClients("TogglePTOAttachStateEvent", vehicle, tool)
                done[#done + 1] = "pto"
            end
        end
    end
    local hs = vehicle.spec_attachConnectionHosesManually
    if hs ~= nil and type(hs.attachedHoses) == "table" and vehicle.toggleConnectionHoseAttachState ~= nil then
        local util = aimGlobal("ConnectionHoseUtil")
        local has = false
        if util ~= nil and util.getHasInputConnectionHoses ~= nil then
            local ok, r = FarmPilotCall(util.getHasInputConnectionHoses, tool, inputJ)
            has = ok and r == true
        end
        if has and (hs.attachedHoses[j] ~= nil) ~= connect then
            vehicle:toggleConnectionHoseAttachState(tool, j, inputJ)
            if (hs.attachedHoses[j] ~= nil) == connect then
                aimSendToClients("ToggleHoseAttachStateEvent", vehicle, tool)
                done[#done + 1] = "hoses"
            end
        end
    end
    return done
end

-- ------------------------------------------------------------------------------------------------------------
-- Mémoire champ + outil -> parcours (sauvegarde FarmPilot_Autonome.xml)
-- ------------------------------------------------------------------------------------------------------------
function ADAutonomousManager.key(fieldNum, toolKey)
    return tostring(fieldNum) .. "|" .. tostring(toolKey)
end

function ADAutonomousManager:getAssignment(fieldNum, toolKey, legacyKey)
    self:loadFromXml()
    local a = self.assignments[ADAutonomousManager.key(fieldNum, toolKey)]
    if a == nil and legacyKey ~= nil then
        -- choix fait avant que les masses soient ignorées : repris et rangé sous la nouvelle clé
        local old = self.assignments[ADAutonomousManager.key(fieldNum, legacyKey)]
        if old ~= nil then
            a = {}
            for k, v in pairs(old) do
                a[k] = v
            end
            a.tool = toolKey
            self.assignments[ADAutonomousManager.key(fieldNum, toolKey)] = a
            log("champ %s : choix de l'outil %s repris pour %s (masses ignorées)", tostring(fieldNum), tostring(legacyKey), tostring(toolKey))
        end
    end
    return a
end

-- fieldNum = clé de la ligne (groupe de champs, ex. « 52 » ou « 52+60 »)
function ADAutonomousManager:setAssignment(fieldNum, tool, width, e, manual)
    self:loadFromXml()
    local k = ADAutonomousManager.key(fieldNum, tool.key)
    if tool.legacyKey ~= nil then
        -- ancienne clé (masses comprises) remplacée par la nouvelle
        self.assignments[ADAutonomousManager.key(fieldNum, tool.legacyKey)] = nil
    end
    if e == nil then
        self.assignments[k] = nil
        log("champ %s, outil %s : choix effacé (automatique)", tostring(fieldNum), tostring(tool.key))
        return
    end
    self.assignments[k] = {field = fieldNum, tool = tool.key, toolName = tool.name, width = width, path = e.path, name = ADAutonomousManager.courseLabel(e), manual = manual == true}
    log("champ %s, outil %s (%.1f m) : parcours « %s »%s", tostring(fieldNum), tostring(tool.key), width or 0, ADAutonomousManager.courseLabel(e), manual and " (choisi dans la fenêtre)" or " (mémorisé)")
end

local function savegameFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local path = g_currentMission.missionInfo.savegameDirectory
    if path == nil then
        return nil
    end
    return path .. "/" .. ADAutonomousManager.FILE_NAME
end

function ADAutonomousManager:loadFromXml()
    if self.loaded then
        return
    end
    self.loaded = true
    self.assignments = {}
    local file = savegameFile()
    if file == nil or not fileExists(file) then
        return
    end
    local xml = loadXMLFile("fpAutonome", file)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while true do
        local key = string.format("farmPilotAutonome.entry(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local a = {
            field = getXMLString(xml, key .. "#field"),
            tool = getXMLString(xml, key .. "#tool"),
            toolName = getXMLString(xml, key .. "#toolName"),
            width = getXMLFloat(xml, key .. "#width"),
            path = getXMLString(xml, key .. "#path"),
            name = getXMLString(xml, key .. "#name"),
            manual = Utils.getNoNil(getXMLBool(xml, key .. "#manual"), false)
        }
        if a.field ~= nil and a.tool ~= nil and a.path ~= nil then
            local num = tonumber(a.field) or a.field
            a.field = num
            self.assignments[ADAutonomousManager.key(num, a.tool)] = a
        end
        i = i + 1
    end
    delete(xml)
    log("%d choix champ/outil chargés", i)
end

function ADAutonomousManager:saveToXml()
    if not self.loaded then
        return
    end
    local file = savegameFile()
    if file == nil then
        return
    end
    local xml = createXMLFile("fpAutonome", file, "farmPilotAutonome")
    if xml == nil or xml == 0 then
        return
    end
    local keys = {}
    for k, _ in pairs(self.assignments) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local a = self.assignments[k]
        local key = string.format("farmPilotAutonome.entry(%d)", i - 1)
        setXMLString(xml, key .. "#field", tostring(a.field))
        setXMLString(xml, key .. "#tool", a.tool)
        setXMLString(xml, key .. "#toolName", a.toolName or "")
        setXMLFloat(xml, key .. "#width", a.width or 0)
        setXMLString(xml, key .. "#path", a.path)
        setXMLString(xml, key .. "#name", a.name or "")
        setXMLBool(xml, key .. "#manual", a.manual == true)
    end
    saveXMLFile(xml)
    delete(xml)
end

-- ------------------------------------------------------------------------------------------------------------
-- Choix du parcours à l'arrivée (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
-- renvoie e (parcours) ou nil + code d'erreur + texte de détail
function ADAutonomousManager:choose(vehicle)
    if not ADAutonomousManager.hasWorkTool(vehicle) then
        return nil, "noTool"
    end
    if not ADAutonomousManager.hasCp(vehicle) then
        return nil, "noCp"
    end
    local width = ADAutonomousManager.toolWidth(vehicle)
    if width == nil then
        return nil, "noWidth"
    end
    local field = ADAutonomousManager.nearField(vehicle)
    if field == nil then
        return nil, "noField", width
    end
    local fieldNum = ADAutonomousManager.fieldNumber(field)
    local tool = ADAutonomousManager.toolIdentity(vehicle)
    -- fichiers relus à chaque départ (un parcours a pu être ajouté entre-temps) : déjà lus pendant le trajet
    -- (startPrefetch au départ) ; sinon tout est relu maintenant
    if ADAutonomousManager.prefetched then
        ADAutonomousManager.prefetchStep(math.huge)
    else
        ADAutonomousManager.cache = {}
    end
    ADAutonomousManager.prefetched = false
    local courses = ADAutonomousManager.listCourses()
    if courses == nil then
        return nil, "noCp"
    end
    if fieldNum == nil then
        -- (09/11) champ sans numéro : traité comme « pas de champ ici » (avant : erreur Lua rattrapée)
        return nil, "noField", width
    end
    local list = ADAutonomousManager.candidates(courses, field, width)
    local g = ADAutonomousManager.groupOf(fieldNum)
    local fieldTxt = table.concat(g.members, " + ")
    log("champ %s (groupe %s : %s), outil %s, largeur %.1f m : %d parcours enregistré(s), %d à cette largeur sur ce champ",
        tostring(fieldNum), g.key, fieldTxt, tool.key, width, #courses, #list)
    if ADBalerManager ~= nil and ADBalerManager.baler(vehicle) ~= nil then
        -- presse : le parcours du champ qui tombe sur les andains, toutes largeurs, voir BalerManager.lua
        local e, err = ADBalerManager.choose(vehicle, courses, g)
        return e, err, width, fieldTxt, tool
    end

    -- 1) choix mémorisé ou fixé dans la fenêtre : repris s'il est toujours valable
    --    (ligne de ce champ d'abord, puis lignes de parcours qui couvrent ce champ et d'autres)
    local rowKeys, seen = {g.key}, {[g.key] = true}
    for _, e in ipairs(list) do
        if e.rowKey ~= nil and not seen[e.rowKey] then
            seen[e.rowKey] = true
            rowKeys[#rowKeys + 1] = e.rowKey
        end
    end
    for _, rk in ipairs(rowKeys) do
        local a = self:getAssignment(rk, tool.key, tool.legacyKey)
        if a ~= nil then
            for _, e in ipairs(list) do
                if e.path == a.path then
                    log("choix mémorisé repris (ligne %s) : %s", rk, ADAutonomousManager.courseLabel(e))
                    return e, nil, width, fieldTxt, tool
                end
            end
            log("choix mémorisé « %s » (ligne %s) plus valable (parcours supprimé, déplacé ou d'une autre largeur)", tostring(a.name), rk)
        end
    end
    -- 2) un seul parcours possible : on le prend et on le retient
    if #list == 1 then
        self:setAssignment(list[1].rowKey or g.key, tool, width, list[1], false)
        return list[1], nil, width, fieldTxt, tool
    end
    if #list == 0 then
        return nil, "none", width, fieldTxt, tool
    end
    return nil, "several", width, fieldTxt, tool, #list
end

-- ------------------------------------------------------------------------------------------------------------
-- Lancement de Courseplay
-- ------------------------------------------------------------------------------------------------------------
-- charge le parcours puis lance Courseplay au premier point
function ADAutonomousManager:startCourse(vehicle, e)
    local ok, res = FarmPilotCall(vehicle.appendLoadedCpCourse, vehicle, e.file)
    if not ok or res == false then
        log("ERREUR chargement « %s » : %s", ADAutonomousManager.courseLabel(e), tostring(res))
        return false
    end
    if vehicle.setCpCourseName ~= nil then
        FarmPilotCall(vehicle.setCpCourseName, vehicle, e.fname)
    end
    local isControlled = vehicle.spec_enterable ~= nil and vehicle:getIsControlled()
    if vehicle.spec_enterable ~= nil then
        vehicle.spec_enterable.isControlled = false
    end
    local okS, started = FarmPilotCall(vehicle.startCpAtFirstWp, vehicle)
    if vehicle.spec_enterable ~= nil then
        vehicle.spec_enterable.isControlled = isControlled
    end
    if not okS or started ~= true then
        log("Courseplay n'a pas démarré avec « %s » (%s)", ADAutonomousManager.courseLabel(e), tostring(started))
        return false
    end
    log("Courseplay lancé avec « %s »", ADAutonomousManager.courseLabel(e))
    return true
end

-- (08/11) après le plein du semoir : Courseplay repart au dernier point du parcours déjà chargé (comme le mode
-- Chargement avec Courseplay, AutoDrive:RestartCP)
function ADAutonomousManager:restartCourse(vehicle)
    if vehicle.startCpAtLastWp == nil then
        return false
    end
    local isControlled = vehicle.spec_enterable ~= nil and vehicle:getIsControlled()
    if vehicle.spec_enterable ~= nil then
        vehicle.spec_enterable.isControlled = false
    end
    local okS, started = FarmPilotCall(vehicle.startCpAtLastWp, vehicle)
    if vehicle.spec_enterable ~= nil then
        vehicle.spec_enterable.isControlled = isControlled
    end
    if not okS or started ~= true then
        log("Courseplay n'a pas redémarré au dernier point (%s)", tostring(started))
        return false
    end
    log("Courseplay reparti au dernier point")
    return true
end
