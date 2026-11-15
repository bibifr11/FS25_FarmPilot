-- ============================================================================================================
-- FarmPilot : AutonomousResumeButton.lua
-- Bouton Marche/Arrêt : le départ suivant reprend toujours là où le véhicule en était, jamais au début (15/11).
-- Clic droit sur Marche/Arrêt : « Reprendre au début ».
--
-- Défaut : arrêté au bouton Marche/Arrêt puis remis en marche, le chauffeur repartait de zéro :
-- - mode Autonome, Courseplay au travail : AutoDrive est arrêté pendant que Courseplay travaille, le bouton est
--   éteint ; un appui relançait le mode Autonome, qui rechargeait le parcours et relançait Courseplay au PREMIER point
--   (le parcours recommençait au début du champ). Pareil après un arrêt de Courseplay, puis Marche ;
-- - mode Autonome sur la route (dépôt des balles, plein, reste de l'épandeur, changement d'outil, retour au garage,
--   barre de coupe) : départ habituel, vers le champ ;
-- - « Décharger moissonneuse » : la benne qui allait vider retournait au champ chargée ;
-- - « Collecter et livrer » sous le niveau de déchargement : retour au chargement au lieu d'aller livrer.
--
-- Règle (15/11) : l'appui sur Marche/Arrêt reprend toujours là où c'était.
-- - Arrêt au bouton, chauffeur en marche : l'étape en cours est notée comme au chargement d'une partie (même
--   reprise, mêmes données : #fpAutoStage, #fpAutoReturn, #fpUnloadStage, #fpPickupPhase, gardées aussi dans la
--   sauvegarde) ; le départ suivant la reprend, une seule fois. Destination changée entre-temps (mode Autonome) :
--   départ habituel vers la nouvelle destination.
-- - Mode Autonome, Courseplay ou l'ouvrier du jeu au travail : le bouton est allumé ; un appui arrête Courseplay (il
--   retient son dernier point) ou l'ouvrier du jeu, et le tracteur reste sur place.
-- - Mode Autonome arrivé au champ avec le parcours du champ déjà chargé sur le véhicule et un dernier point retenu
--   par Courseplay (arrêt au bouton, arrêt de Courseplay, partie rechargée) : Courseplay repart au dernier point
--   au lieu du premier. Champ fini (Courseplay oublie alors son dernier point) ou autre parcours : premier point.
-- - Clic droit sur Marche/Arrêt (et touche « FP - Reprendre au début », sans touche par défaut) : tout ce qui est
--   noté est oublié, le chauffeur et Courseplay (ou l'ouvrier du jeu) sont arrêtés, le dernier point de Courseplay
--   est oublié, puis départ habituel ; Courseplay repart au premier point du parcours.
-- - Journal : « [FarmPilot Reprise] <véhicule> : arrêté au bouton Marche/Arrêt … », puis « … remis en marche au
--   bouton Marche/Arrêt … » à la reprise.
--
-- Branché par : enveloppes posées au chargement de ce fichier sur ADInputManager:onInputCall, AutonomousMode:start,
-- CombineUnloaderMode:start, ADSavegameResume.pickupStart et ADSavegameResume.log ; une ligne dans
-- AutonomousMode.lua (handleFinishedTask, choix du parcours : continueCourse), HudButton.lua (bouton allumé :
-- helperShown), Hud.lua (clic droit du bouton), InputManager.lua (input_restartFromStart), ExternalInterface.lua
-- (onAIJobFinished : pas de message d'erreur pour un arrêt au bouton). Chargé par register.lua après
-- AutonomousResumeHeader.lua.
-- ============================================================================================================

ADResumeButton = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADResumeButton.FROM_START_VALID = 1200000 -- ms : « Reprendre au début » pas arrivé au champ dans ce temps = oublié
ADResumeButton.WHY = "remis en marche au bouton Marche/Arrêt" -- remplace « partie rechargée » dans le journal

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

local function modeOf(vehicle, modeId)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.modes == nil or modeId == nil then
        return nil
    end
    return vehicle.ad.modes[modeId]
end

local function rootOf(vehicle)
    return vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
end

-- ------------------------------------------------------------------------------------------------------------
-- Courseplay ou l'ouvrier du jeu au travail (mode Autonome : FarmPilot arrêté pendant le travail du champ)
-- ------------------------------------------------------------------------------------------------------------
function ADResumeButton.helperWorking(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or sm:isActive() then
        return nil
    end
    if AutoDrive.getIsCPActive ~= nil and AutoDrive:getIsCPActive(vehicle) then
        return "cp"
    end
    local root = rootOf(vehicle)
    if root.getIsAIActive ~= nil and root:getIsAIActive() then
        return "ai"
    end
    return nil
end

-- bouton Marche/Arrêt allumé (HudButton.lua) : aussi quand Courseplay ou l'ouvrier du jeu travaille pour le mode Autonome
function ADResumeButton.helperShown(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return false
    end
    return ADResumeButton.helperWorking(vehicle) ~= nil
end

-- arrêt de Courseplay (il retient son dernier point) ou de l'ouvrier du jeu, comme leur propre bouton
function ADResumeButton.stopHelper(vehicle, helper)
    local root = rootOf(vehicle)
    vehicle.ad.fpButtonStop = g_time or 0 -- onAIJobFinished : pas de message « ouvrier arrêté avant la fin »
    if helper == "cp" and root.cpStartStopDriver ~= nil then
        root:cpStartStopDriver()
        return true
    end
    if root.stopCurrentAIJob ~= nil and AIMessageSuccessStoppedByUser ~= nil then
        root:stopCurrentAIJob(AIMessageSuccessStoppedByUser.new())
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Arrêt au bouton, chauffeur en marche : l'étape en cours est notée
-- ------------------------------------------------------------------------------------------------------------
function ADResumeButton.noteStop(vehicle)
    local sm = vehicle.ad.stateModule
    local name = nameOf(vehicle)
    local mode = sm:getMode()
    local noted = {}
    if mode == AutoDrive.MODE_AUTONOMOUS then
        local stage = ADResumeStage ~= nil and ADResumeStage.current(vehicle) or nil
        if stage ~= nil then
            sm.fpAutoStage = stage
            sm.fpAutoStageLoaded = true -- gardé jusqu'au départ suivant, aussi dans la sauvegarde
            sm.fpAutoStageTime = nil
            sm.fpAutoStageButton = sm:getFirstMarker() ~= nil and sm:getFirstMarker().id or -1
            noted[#noted + 1] = stage
        end
        local back = ADResumeReturn ~= nil and ADResumeReturn.returnStage(vehicle) or nil
        if back ~= nil then
            sm.fpAutoReturn = "park"
            sm.fpAutoReturnTime = nil
            sm.fpAutoReturnButton = true
            noted[#noted + 1] = "retour au garage (" .. tostring(back) .. ")"
        end
    elseif mode == AutoDrive.MODE_UNLOAD and ADResumeHeader ~= nil and ADResumeHeader.unloadStage ~= nil then
        local stage = ADResumeHeader.unloadStage(vehicle)
        if stage ~= nil then
            sm.fpUnloadStage = stage
            sm.fpUnloadStageLoaded = true
            sm.fpUnloadStageTime = nil
            sm.fpUnloadStageButton = true
            noted[#noted + 1] = stage
        end
    elseif mode == AutoDrive.MODE_PICKUPANDDELIVER and ADSavegameResume ~= nil and ADSavegameResume.phase ~= nil then
        local phase = ADSavegameResume.phase(modeOf(vehicle, AutoDrive.MODE_PICKUPANDDELIVER))
        if phase ~= nil then
            sm.fpPickupPhase = phase
            sm.fpPickupButton = true
            noted[#noted + 1] = phase == "unload" and "livraison" or "chargement"
        end
    end
    if #noted > 0 then
        log("%s : arrêté au bouton Marche/Arrêt pendant « %s » : le départ suivant reprendra là", name, table.concat(noted, " + "))
    end
    return #noted > 0
end

-- (serveur) appui du joueur sur Marche/Arrêt ; true = pris ici (le bouton d'origine ne fait rien de plus)
function ADResumeButton.onStartStop(vehicle)
    local sm = vehicle.ad.stateModule
    if ADGraphManager:getWayPointById(1) == nil or sm:getFirstMarker() == nil then
        return false
    end
    vehicle.ad.fpFromStart = nil -- « Reprendre au début » demandé avant : l'appui suivant reprend là où c'était
    if sm:isActive() then
        ADResumeButton.noteStop(vehicle)
        return false -- arrêt d'origine
    end
    if sm:getMode() == AutoDrive.MODE_AUTONOMOUS then
        local helper = ADResumeButton.helperWorking(vehicle)
        if helper ~= nil then
            vehicle.ad.fpStopButtonTime = g_time or 0
            if ADResumeButton.stopHelper(vehicle, helper) then
                log("%s : arrêté au bouton Marche/Arrêt pendant le travail du champ (%s) : il reste sur place, le départ suivant reprendra au dernier point",
                    nameOf(vehicle), helper == "cp" and "Courseplay" or "ouvrier du jeu")
                return true
            end
        end
    end
    return false -- départ d'origine (la reprise se fait au départ du mode)
end

-- ------------------------------------------------------------------------------------------------------------
-- Clic droit : reprendre au début
-- ------------------------------------------------------------------------------------------------------------
function ADResumeButton.forget(sm)
    sm.fpAutoStage, sm.fpAutoStageLoaded, sm.fpAutoStageTime, sm.fpAutoStageButton = nil, nil, nil, nil
    sm.fpAutoStageRestarts = nil
    sm.fpAutoReturn, sm.fpAutoReturnTime, sm.fpAutoReturnButton, sm.fpAutoReturnRestarts = nil, nil, nil, nil
    sm.fpUnloadStage, sm.fpUnloadStageLoaded, sm.fpUnloadStageTime, sm.fpUnloadStageButton = nil, nil, nil, nil
    sm.fpUnloadStageRestarts = nil
    sm.fpPickupPhase, sm.fpPickupButton = nil, nil
end

-- (serveur) ADInputManager:input_restartFromStart
function ADResumeButton.restartFromStart(vehicle, farmId)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or ADGraphManager:getWayPointById(1) == nil or sm:getFirstMarker() == nil then
        return false
    end
    local name = nameOf(vehicle)
    ADResumeButton.forget(sm)
    vehicle.ad.fpStopButtonTime = g_time or 0
    if sm:isActive() then
        vehicle.ad.isStoppingWithError = true
        sm:setLoopsDone(0)
        vehicle:stopAutoDrive()
    else
        local helper = ADResumeButton.helperWorking(vehicle)
        if helper ~= nil and sm:getMode() == AutoDrive.MODE_AUTONOMOUS then
            ADResumeButton.stopHelper(vehicle, helper)
        end
    end
    local root = rootOf(vehicle)
    if root.rememberCpLastWaypointIx ~= nil then
        FarmPilotCall(root.rememberCpLastWaypointIx, root, nil) -- Courseplay oublie son dernier point
    end
    if sm:getMode() == AutoDrive.MODE_AUTONOMOUS then
        vehicle.ad.fpFromStart = { marker = sm:getFirstMarker().id, time = g_time or 0 }
    end
    log("%s : reprendre au début (clic droit sur Marche/Arrêt) : étapes notées oubliées, départ habituel%s", name,
        sm:getMode() == AutoDrive.MODE_AUTONOMOUS and ", Courseplay au premier point" or "")
    local function go()
        if sm:isActive() then
            return
        end
        if farmId ~= nil and farmId > 0 then
            sm:setActualFarmId(farmId)
        end
        sm:setLoopsDone(0)
        sm:getCurrentMode():start(AutoDrive.USER_PLAYER)
    end
    -- à l'image suivante : FarmPilot, Courseplay ou l'ouvrier du jeu complètement arrêtés avant de repartir
    local mission = g_currentMission
    if mission ~= nil and mission.addUpdateable ~= nil and mission.removeUpdateable ~= nil then
        local once = {}
        once.update = function(self, dt)
            mission:removeUpdateable(self)
            local ok, err = FarmPilotCall(go)
            if not ok then
                log("ERREUR reprendre au début : %s", tostring(err))
            end
        end
        mission:addUpdateable(once)
    else
        go()
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Courseplay au dernier point (AutonomousMode:handleFinishedTask, parcours choisi à l'arrivée au champ)
-- ------------------------------------------------------------------------------------------------------------
-- true = le parcours e est déjà chargé et commencé : Courseplay repartira au dernier point (stopAutoDrive, fpRestartCp)
function ADResumeButton.continueCourse(vehicle, e, fieldText)
    local fromStart = vehicle.ad.fpFromStart
    vehicle.ad.fpFromStart = nil
    local sm = vehicle.ad.stateModule
    if fromStart ~= nil then
        local now = g_time or 0
        local first = sm:getFirstMarker()
        if first ~= nil and fromStart.marker == first.id and now >= fromStart.time and now - fromStart.time <= ADResumeButton.FROM_START_VALID then
            log("%s : reprendre au début : parcours « %s » au premier point", nameOf(vehicle), ADAutonomousManager.courseLabel(e))
            return false
        end
    end
    local root = rootOf(vehicle)
    if e == nil or root.getCurrentCpCourseName == nil or root.getCpLastRememberedWaypointIx == nil or root.startCpAtLastWp == nil then
        return false
    end
    if root.hasCpCourse ~= nil and not root:hasCpCourse() then
        return false
    end
    local okN, current = FarmPilotCall(root.getCurrentCpCourseName, root)
    local okI, ix = FarmPilotCall(root.getCpLastRememberedWaypointIx, root)
    if not okN or not okI or ix == nil or tostring(current) ~= tostring(e.fname) then
        return false
    end
    vehicle.ad.fpRestartCp = true
    log("%s : parcours « %s » déjà commencé : Courseplay repart au dernier point (n° %s) au lieu du premier", nameOf(vehicle), ADAutonomousManager.courseLabel(e), tostring(ix))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 5000, "AD_autonomous_cpContinue", ADAutonomousManager.courseLabel(e), tostring(fieldText or "?"))
    return true
end

function ADResumeButton.continueSafe(vehicle, e, fieldText)
    local ok, done = FarmPilotCall(ADResumeButton.continueCourse, vehicle, e, fieldText)
    if not ok then
        log("ERREUR parcours au dernier point : %s", tostring(done))
        return false
    end
    return done == true
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes
-- ------------------------------------------------------------------------------------------------------------
-- journal : « partie rechargée » devient « remis en marche au bouton Marche/Arrêt » pendant une reprise notée au bouton
if ADSavegameResume ~= nil and ADSavegameResume.log ~= nil then
    local baseLog = ADSavegameResume.log
    function ADSavegameResume.log(fmt, ...)
        if ADResumeButton.why ~= nil and type(fmt) == "string" then
            fmt = string.gsub(fmt, "partie rechargée", ADResumeButton.why)
        end
        return baseLog(fmt, ...)
    end
end

local function withWhy(button, f, ...)
    if not button then
        return f(...)
    end
    ADResumeButton.why = ADResumeButton.WHY
    local res = { pcall(f, ...) }
    ADResumeButton.why = nil
    if not res[1] then
        error(res[2], 0)
    end
    return unpack(res, 2)
end

-- appui du joueur (sur le serveur : événement du client, ou partie solo)
if ADInputManager ~= nil and ADInputManager.onInputCall ~= nil then
    local baseInput = ADInputManager.onInputCall
    function ADInputManager:onInputCall(vehicle, input, farmId, uniqueUserId, sendEvent, ...)
        if input == "input_start_stop" and sendEvent == false and g_server ~= nil and vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
            local ok, taken = FarmPilotCall(ADResumeButton.onStartStop, vehicle)
            if not ok then
                log("ERREUR bouton Marche/Arrêt : %s", tostring(taken))
            elseif taken then
                if vehicle.isServer and SpecializationUtil ~= nil then
                    SpecializationUtil.raiseEvent(vehicle, "onUpdate", 16, false, false, false)
                end
                return
            end
        end
        return baseInput(self, vehicle, input, farmId, uniqueUserId, sendEvent, ...)
    end
end

-- départ du mode Autonome : destination changée depuis l'arrêt au bouton = départ habituel ; journal
if AutonomousMode ~= nil and AutonomousMode.start ~= nil then
    local baseStart = AutonomousMode.start
    function AutonomousMode:start(user, ...)
        local sm = self.vehicle ~= nil and self.vehicle.ad ~= nil and self.vehicle.ad.stateModule or nil
        local button = false
        if sm ~= nil and (sm.fpAutoStageButton ~= nil or sm.fpAutoReturnButton) then
            button = true
            local first = sm:getFirstMarker()
            if sm.fpAutoStageButton ~= nil and sm.fpAutoStage ~= nil and (first == nil or first.id ~= sm.fpAutoStageButton) then
                log("%s : destination changée depuis l'arrêt au bouton : étape « %s » oubliée, départ vers « %s »", nameOf(self.vehicle), tostring(sm.fpAutoStage), tostring(first ~= nil and first.name or "?"))
                sm.fpAutoStage, sm.fpAutoStageLoaded, sm.fpAutoStageTime = nil, nil, nil
            end
            sm.fpAutoStageButton = nil
            sm.fpAutoReturnButton = nil
        end
        return withWhy(button, baseStart, self, user, ...)
    end
end

if CombineUnloaderMode ~= nil and CombineUnloaderMode.start ~= nil then
    local baseUnloadStart = CombineUnloaderMode.start
    function CombineUnloaderMode:start(user, ...)
        local sm = self.vehicle ~= nil and self.vehicle.ad ~= nil and self.vehicle.ad.stateModule or nil
        local button = sm ~= nil and sm.fpUnloadStageButton == true and sm.fpUnloadStage ~= nil
        if sm ~= nil then
            sm.fpUnloadStageButton = nil
        end
        return withWhy(button, baseUnloadStart, self, user, ...)
    end
end

if ADSavegameResume ~= nil and ADSavegameResume.pickupStart ~= nil then
    local basePickup = ADSavegameResume.pickupStart
    function ADSavegameResume.pickupStart(mode, filledToUnload, ...)
        local vehicle = mode ~= nil and mode.vehicle or nil
        local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
        local button = sm ~= nil and sm.fpPickupButton == true and sm.fpPickupPhase ~= nil
        if sm ~= nil then
            sm.fpPickupButton = nil
        end
        return withWhy(button, basePickup, mode, filledToUnload, ...)
    end
end
