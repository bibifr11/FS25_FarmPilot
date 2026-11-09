-- ============================================================================================================
-- FarmPilot : AutonomousMode.lua
-- Mode « Autonome » = mode Conduite, puis à l'arrivée le parcours Courseplay de la largeur exacte de l'outil (voir
-- AutonomousManager.lua) ; sinon arrêt et attente.
--
-- Règle :
-- - Départ refusé tant que le semoir, l'épandeur ou la remorque à balles de la ligne Outil (ou Outil suivant) n'est
--   pas réglé (roue dentée), ou sans outil de travail attelé ni outil choisi.
-- - (07/11) outil choisi dans le HUD et pas encore attelé : le chauffeur va l'atteler d'abord (par le réseau, puis
--   devant l'outil, marche arrière, attelage), puis part au champ.
-- - (08/11) semoir ou épandeur réglé pas plein : plein à sa zone de ravitaillement d'abord, comme le mode
--   Chargement ; vide au champ (Courseplay s'arrête) : sortie du champ, plein, retour, Courseplay repart au dernier
--   point.
-- - À l'arrivée : le parcours choisi (AutonomousManager.lua), ou l'ouvrier du jeu si Courseplay est absent (réglage
--   « Autonome sans Courseplay »), sinon arrêt et attente avec un message.
-- - (07/11) champ fini : champ suivant s'il y en a un (outil suivant changé d'abord si besoin) ; sinon l'outil est
--   posé à sa place de parking, puis le tracteur va à la sienne.
--
-- Branché par : Specialization.lua (AutonomousMode:new pour le mode MODE_AUTONOMOUS), ExternalInterface.lua (champ
-- fini : goToNextField, parkWithToolDrop ; Courseplay arrêté cuve vide : onCpEmpty), InputManager.lua (bouton
-- « Continuer »), AutonomousParkButton.lua (parkWithToolDrop). AutonomousRefill.lua, chargé après ce fichier,
-- enveloppe startRefill, startRefillLoad, monitorRefill, continue, handleRefillStage et onCpEmpty.
-- SprayerManager.lua et AutonomousSprayerDump.lua sont appelés par une ligne chacun, de même que
-- BaleLoaderManager.lua et AutonomousBales.lua (remorque à balles : notre ramassage à l'arrivée au champ).
-- ============================================================================================================

AutonomousMode = ADInheritsFrom(AbstractMode)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- aller atteler l'outil (voir fetchRoutePoint, monitorFetchRoute)
AutonomousMode.FETCH_MARKER_NEAR = 25   -- m : l'outil est à sa place si son point d'attelage est à moins de ça du point de la place
AutonomousMode.FETCH_ROUTE_RANGE = 40   -- m : point du réseau cherché à moins de ça de l'avant de l'outil
AutonomousMode.FETCH_ROUTE_CLEAR = 8    -- m : ce point du réseau est au moins à ça devant l'outil (pas sous l'outil)
AutonomousMode.FETCH_NEAR_START = 3     -- m : le tracteur y est déjà
AutonomousMode.FETCH_HANDOVER = 12      -- m entre les points d'attelage : sur la route, dans l'axe de l'outil, on passe à l'attelage
AutonomousMode.FETCH_STUCK_TIME = 8000  -- ms arrêté sur la route près de l'outil (obstacle = l'outil) : on passe à l'attelage
AutonomousMode.FETCH_STUCK_RANGE = 30   -- m
-- plein du semoir (voir startRefill) ; AutonomousRefill.lua le met à math.huge (plus d'étape « exit »)
AutonomousMode.REFILL_EXIT_DISTANCE = 30   -- m : au champ et plus loin que ça de son marqueur = sortie du champ d'abord (mode Chargement)

-- messages d'échec
AutonomousMode.SWAP_FAIL_KEYS = {
    busy = "AD_autonomous_fetchBusy",
    noJoint = "AD_autonomous_fetchNoJoint",
    several = "AD_autonomous_swapSeveral",
    noToolPark = "AD_autonomous_swapNoToolPark"
}

AutonomousMode.FETCH_FAIL_KEYS = {
    noPath = "AD_autonomous_fetchNoPath",
    missed = "AD_autonomous_fetchMissed",
    timeout = "AD_autonomous_fetchMissed",
    busy = "AD_autonomous_fetchBusy",
    noJoint = "AD_autonomous_fetchNoJoint"
}

-- ------------------------------------------------------------------------------------------------------------
-- Création, remise à zéro, arrêt
-- ------------------------------------------------------------------------------------------------------------
function AutonomousMode:new(vehicle)
    local o = AutonomousMode:create()
    o.vehicle = vehicle
    AutonomousMode.reset(o)
    return o
end

function AutonomousMode:reset()
    self.driveToDestinationTask = nil
    self.destinationID = nil
    -- fin du travail : outil posé à sa place puis tracteur garé (voir parkWithToolDrop)
    self.parkStage = nil
    self.parkTool = nil
    self.detachTask = nil
    self.tractorParkId = nil
    -- (07/11) changement d'outil avant le champ suivant : après le dételage, on va atteler swapTool
    self.parkThen = nil
    self.swapTool = nil
    -- avant le champ : aller atteler l'outil choisi dans le HUD (voir startFetch)
    self.fetchStage = nil
    self.fetchTool = nil
    self.fetchTask = nil
    self.fetchStuckTimer = nil
    -- (08/11) semoir : plein à la zone de ravitaillement, comme le mode Chargement (voir startRefill)
    self.refillStage = nil
    self.refillThen = nil
    self.refillPlan = nil
    self.refillTask = nil
    self.dumpStage = nil -- épandeur : vider le reste en big bags, voir AutonomousSprayerDump.lua
    if ADBaleCollect ~= nil then ADBaleCollect.reset(self) end -- remorque à balles : étapes du ramassage, voir AutonomousBales.lua
    self.vehicle.ad.trailerModule:reset()
end

function AutonomousMode:stop()
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function AutonomousMode:start(user)
    -- (08/11) départ refusé tant que les réglages ne sont pas validés : semoir sur la ligne
    -- Outil (ou Outil suivant) : culture, produits et zone de ravitaillement à valider (roue dentée) avant le départ
    local okB, block = pcall(ADSeederManager.startBlock, self.vehicle)
    if not okB then
        ADAutonomousManager.log("ERREUR réglages du semoir : %s", tostring(block))
        block = nil
    end
    if block ~= nil then
        AutonomousMode.message(self.vehicle, ADMessagesManager.messageTypes.ERROR, 12000, "AD_autonomous_seederTodo", tostring(block.label), tostring(block.field))
        ADAutonomousManager.log("%s : départ refusé, réglages du semoir « %s » à valider pour « %s »", tostring(self.vehicle.ad.stateModule:getName()), tostring(block.label), tostring(block.field))
        if self.vehicle.ad.stateModule:isActive() then
            self.vehicle:stopAutoDrive()
        end
        return
    end
    if ADSprayerManager ~= nil and ADSprayerManager.refuseStart(self) then return end -- épandeur / pulvé : réglages à valider (roue dentée), voir SprayerManager.lua
    if ADBaleLoaderManager ~= nil and ADBaleLoaderManager.refuseStart(self) then return end -- remorque à balles : réglages à valider (roue dentée), voir BaleLoaderManager.lua
    -- (07/11) outil choisi dans le HUD et pas encore attelé : on va l'atteler d'abord
    local okF, fetchTool, fetchErr, wanted = pcall(ADAutonomousManager.toolToFetch, self.vehicle)
    if not okF then
        ADAutonomousManager.log("ERREUR outil à atteler : %s", tostring(fetchTool))
        fetchTool, fetchErr = nil, nil
    end
    if fetchErr ~= nil then
        local key = ({ busy = "AD_autonomous_fetchBusy", other = "AD_autonomous_fetchOther", noJoint = "AD_autonomous_fetchNoJoint" })[fetchErr] or "AD_autonomous_fetchFailed"
        AutonomousMode.message(self.vehicle, ADMessagesManager.messageTypes.ERROR, 12000, key, wanted ~= nil and ADAutonomousManager.toolLabel(wanted) or "?")
        ADAutonomousManager.log("%s : départ refusé, outil choisi : %s", tostring(self.vehicle.ad.stateModule:getName()), tostring(fetchErr))
        if self.vehicle.ad.stateModule:isActive() then
            self.vehicle:stopAutoDrive()
        end
        return
    end
    if not self.vehicle.ad.stateModule:isActive() then
        -- (07/11) refus au départ sans outil de travail (benne, plateau, moissonneuse seuls)
        local okT, hasTool = pcall(ADAutonomousManager.hasWorkTool, self.vehicle)
        if okT and not hasTool and fetchTool == nil then
            AutonomousMode.message(self.vehicle, ADMessagesManager.messageTypes.ERROR, 8000, "AD_autonomous_noTool")
            ADAutonomousManager.log("%s : départ refusé (aucun outil de travail attelé)", tostring(self.vehicle.ad.stateModule:getName()))
            return
        end
        self.vehicle:startAutoDrive()
    end

    if self.vehicle.ad.stateModule:getFirstMarker() == nil then
        return
    end

    self:reset()
    self.vehicle.ad.fpAutonomousCourse = nil
    self.vehicle.ad.fpAutonomousAI = nil
    if fetchTool ~= nil then
        self:startFetch(fetchTool)
        return
    end
    -- (08/11) semoir réglé attelé : culture mise sur le semoir ; pas plein = plein à la zone d'abord, puis le champ
    local okP, plan = pcall(ADSeederManager.prepare, self.vehicle)
    if not okP then
        ADAutonomousManager.log("ERREUR semoir : %s", tostring(plan))
        plan = nil
    end
    plan = plan or (ADSprayerManager ~= nil and ADSprayerManager.preparePlan(self.vehicle, "field") or nil) -- épandeur / pulvé : même plein que le semoir, voir SprayerManager.lua
    if plan ~= nil and plan.needsFill and plan.marker ~= nil then
        self:startRefill(plan, "field")
        return
    end
    self:departToField()
end

-- départ normal vers le champ (1re destination), le parcours Courseplay est choisi à l'arrivée
function AutonomousMode:departToField()
    self.destinationID = self.vehicle.ad.stateModule:getFirstMarker().id
    ADAutonomousManager.log("%s : départ vers « %s »", tostring(self.vehicle.ad.stateModule:getName()), tostring(self.vehicle.ad.stateModule:getFirstMarker().name))
    self.driveToDestinationTask = DriveToDestinationTask:new(self.vehicle, self.destinationID)
    self.vehicle.ad.taskModule:addTask(self.driveToDestinationTask)
    -- parcours Courseplay lus pendant le trajet (un par image), pas tous d'un coup à l'arrivée
    local ok, err = pcall(ADAutonomousManager.startPrefetch)
    if not ok then
        ADAutonomousManager.log("ERREUR lecture des parcours : %s", tostring(err))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Message au joueur
-- ------------------------------------------------------------------------------------------------------------
-- texte traduit et rempli ici (les textes contiennent des %s, que le gestionnaire de messages ne sait pas remplacer)
function AutonomousMode.message(vehicle, messageType, duration, key, ...)
    local ok, txt = pcall(string.format, g_i18n:getText(key), ...)
    if not ok then
        txt = g_i18n:getText(key)
    end
    txt = string.format("%s %s: %s", g_i18n:getText("AD_Driver_of"), tostring(vehicle.ad.stateModule:getName()), txt)
    AutoDriveMessageEvent.sendMessageOrNotification(vehicle, messageType, txt, duration)
end

-- ------------------------------------------------------------------------------------------------------------
-- À chaque image, et fin de chaque tâche (arrivée au champ : choix du parcours)
-- ------------------------------------------------------------------------------------------------------------
function AutonomousMode:monitorTasks(dt)
    if ADAutonomousManager.prefetch ~= nil then
        pcall(ADAutonomousManager.prefetchStep)
    end
    if self.fetchStage == "route" then
        local ok, err = pcall(self.monitorFetchRoute, self, dt)
        if not ok then
            ADAutonomousManager.log("ERREUR route vers l'outil : %s", tostring(err))
        end
    end
    if ADSprayerManager ~= nil then pcall(ADSprayerManager.monitorTarget, self, dt) end -- épandeur : chargement arrêté à la quantité voulue, voir SprayerManager.lua
    if self.refillStage == "load" then
        local ok, err = pcall(self.monitorRefill, self, dt)
        if not ok then
            ADAutonomousManager.log("ERREUR plein du semoir : %s", tostring(err))
        end
    end
end

-- (08/11) plein du semoir : chargé aux zones comme le mode Chargement
function AutonomousMode:shouldLoadOnTrigger()
    return self.refillStage == "load"
end

function AutonomousMode:handleFinishedTask()
    if self.parkStage ~= nil then
        self:handleParkStage()
        return
    end
    if self.fetchStage ~= nil then
        self:handleFetchStage()
        return
    end
    if self.refillStage ~= nil then
        self:handleRefillStage()
        return
    end
    if self.dumpStage ~= nil and ADSprayerDump ~= nil then ADSprayerDump.handleStage(self) return end -- épandeur : vider le reste, voir AutonomousSprayerDump.lua
    if self.baleStage ~= nil and ADBaleCollect ~= nil then ADBaleCollect.handleStage(self) return end -- remorque à balles : ramassage, dépôt, retour, voir AutonomousBales.lua
    if self.driveToDestinationTask == nil then
        return
    end
    self.driveToDestinationTask = nil
    local vehicle = self.vehicle
    local name = vehicle.ad.stateModule:getName()
    if vehicle.ad.isStoppingWithError == false and ADBaleCollect ~= nil and ADBaleCollect.onArrival(self) then return end -- remorque à balles : notre ramassage au lieu d'un parcours, voir AutonomousBales.lua

    if vehicle.ad.isStoppingWithError == false then
        local ok, e, err, width, fieldNum, tool, count = pcall(ADAutonomousManager.choose, ADAutonomousManager, vehicle)
        if not ok then
            ADAutonomousManager.log("ERREUR choix du parcours : %s", tostring(e))
            e, err = nil, "error"
        end
        local w = width ~= nil and string.format("%.1f", width) or "?"
        local f = tostring(fieldNum or "?")
        -- (07/11) Courseplay absent : selon le réglage « Autonome sans Courseplay », attente
        -- ou ouvrier du jeu (mode « Classique »). Avec Courseplay : parcours, ou arrêt et attente comme avant.
        local useAI = e == nil and err == "noCp" and AutoDrive.getSetting("autonomousNoCp") == 2
        if useAI then
            local field = ADAutonomousManager.nearField(vehicle)
            if field == nil then
                useAI, err = false, "noField"
            elseif fieldNum == nil then
                f = tostring(ADAutonomousManager.fieldNumber(field) or "?")
            end
        end
        if useAI then
            -- lancé juste après l'arrêt de FarmPilot (stopAutoDrive)
            vehicle.ad.fpAutonomousAI = true
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_aiNoCp", f)
            ADAutonomousManager.log("%s : %s -> ouvrier du jeu sur le champ %s", tostring(name), tostring(err), f)
        elseif e ~= nil then
            -- le parcours est lancé juste après l'arrêt de FarmPilot (stopAutoDrive)
            vehicle.ad.fpAutonomousCourse = e
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 5000, "AD_autonomous_start", ADAutonomousManager.courseLabel(e), f)
        elseif err == "none" then
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_none", w, f)
        elseif err == "several" then
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_several", tostring(count or 2), w, f)
        elseif err == "noField" then
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_noField")
        elseif err == "noWindrow" then
            -- presse : aucun parcours du champ ne tombe sur les andains, voir BalerManager.lua
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_noWindrow", f)
        elseif err == "noWidth" then
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_noWidth")
        elseif err == "noTool" then
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_noTool")
        else
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_noCp")
        end
        if e == nil and not useAI then
            ADAutonomousManager.log("%s : arrêt et attente (%s, largeur %s m, champ %s)", tostring(name), tostring(err), w, f)
        end
    end
    vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle), ADTaskModule.DONT_PROPAGATE)
end

-- ------------------------------------------------------------------------------------------------------------
-- Champ fini : champ suivant, changement d'outil
-- ------------------------------------------------------------------------------------------------------------
-- (07/11) fin du champ (Courseplay ou ouvrier du jeu) : s'il y a un champ suivant, il passe en
-- 1re destination, la ligne « Champ suivant » se vide et le chauffeur part le travailler ; sinon rien (se garer comme avant).
function AutonomousMode.goToNextField(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.stateModule.getFpNextField == nil then
        return false
    end
    local sm = vehicle.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS or sm:isActive() then
        return false
    end
    local nextField = sm:getFpNextField()
    if nextField == nil or nextField.markerIndex == nil or ADGraphManager:getMapMarkerById(nextField.markerIndex) == nil then
        if nextField ~= nil then
            sm:setFpNextField(nil)
        end
        return false
    end
    local doneName = tostring(sm:getFirstMarkerName() or "?")
    local name = tostring(sm:getName())
    -- (07/11, 4e ligne « Outil suivant ») : outil à changer avant le champ suivant ?
    local swap = nil
    local nextTool = sm.getFpNextTool ~= nil and sm:getFpNextTool() or nil
    if nextTool ~= nil then
        local okS, plan, err = pcall(AutonomousMode.toolSwapPlan, vehicle, nextTool)
        if not okS then
            ADAutonomousManager.log("ERREUR outil suivant : %s", tostring(plan))
            plan, err = nil, "error"
        end
        if err ~= nil then
            -- rien n'est changé : le tracteur reste au bout du champ avec son outil, le joueur décide
            local label = ADAutonomousManager.toolLabel(nextTool)
            ADAutonomousManager.log("%s : « %s » fini, outil suivant « %s » impossible (%s), arrêt et attente", name, doneName, label, tostring(err))
            local key = AutonomousMode.SWAP_FAIL_KEYS[err] or "AD_autonomous_fetchFailed"
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, key, label)
            return true
        end
        if plan == "same" then
            sm:setFpTool(nextTool)
            sm:setFpNextTool(nil)
        elseif plan == "fetch" then
            -- rien d'attelé : on va directement atteler l'outil suivant
            sm:setFpTool(nextTool)
            sm:setFpNextTool(nil)
        else
            swap = plan
        end
    end
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.onRouteToPark = false
    vehicle.ad.restartCP = false
    sm:setFirstMarker(nextField.markerIndex)
    sm:setFpNextField(nil)
    if swap ~= nil then
        return AutonomousMode.startToolSwap(vehicle, swap, nextTool, nextField, doneName)
    end
    ADAutonomousManager.log("%s : « %s » fini, départ vers le champ suivant « %s »", name, doneName, tostring(nextField.name))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_nextFieldGo", tostring(nextField.name))
    sm:getCurrentMode():start()
    return true
end

-- (07/11) que faire pour avoir l'outil suivant : « same » (déjà attelé), « fetch » (rien d'attelé, aller le chercher),
-- ou { tool, marker } (poser l'outil attelé à sa place, puis aller chercher l'outil suivant) ; nil, err si impossible.
-- (08/11) outil suivant impossible : l'outil attelé est quand même dételé. Outil suivant pris par un autre engin
-- ou qui ne s'attelle pas = l'outil attelé est quand même posé à sa place (nextErr), puis le chauffeur s'arrête là
-- avec le message (start() refuse d'aller le chercher). Outil attelé sans place de parking : il le garde et s'arrête
-- au bout du champ (08/11).
function AutonomousMode.toolSwapPlan(vehicle, nextTool)
    local nextErr = nil
    local attacher = nextTool.getAttacherVehicle ~= nil and nextTool:getAttacherVehicle() or nil
    if attacher ~= nil then
        local root = nextTool.getRootVehicle ~= nil and nextTool:getRootVehicle() or attacher
        if root == vehicle or attacher == vehicle then
            return "same"
        end
        nextErr = "busy"
    elseif ADAutonomousManager.matchJoints(vehicle, nextTool, false) == nil then
        nextErr = "noJoint"
    end
    local tools = ADAutonomousManager.workTools(vehicle)
    if #tools == 0 then
        if nextErr ~= nil then
            return nil, nextErr
        end
        return "fetch"
    end
    local tool = tools[1]
    local toolAttacher = tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() or nil
    if #tools > 1 or toolAttacher ~= vehicle then
        return nil, "several"
    end
    local toolPark = tool.advd ~= nil and tool.advd.parkDestination or -1
    local toolMarker = toolPark ~= nil and toolPark >= 1 and ADGraphManager:getMapMarkerById(toolPark) or nil
    if toolMarker == nil then
        return nil, "noToolPark"
    end
    return { tool = tool, marker = toolMarker, nextErr = nextErr }
end

-- (07/11) l'outil attelé va à sa place (dételé comme le joueur), puis le chauffeur attelle l'outil suivant et part au
-- champ suivant (1re destination déjà réglée) ; voir handleParkStage (parkThen = « swap »)
function AutonomousMode.startToolSwap(vehicle, plan, nextTool, nextField, doneName)
    local sm = vehicle.ad.stateModule
    local name = tostring(sm:getName())
    local mode = vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    vehicle:startAutoDrive()
    if not sm:isActive() then
        return false
    end
    mode:reset()
    mode.parkTool = plan.tool
    mode.parkThen = "swap"
    mode.swapTool = nextTool
    local nextLabel = ADAutonomousManager.toolLabel(nextTool)
    if plan.nextErr ~= nil then
        ADAutonomousManager.log("%s : outil suivant « %s » pas disponible (%s) : l'outil attelé est quand même posé", name, nextLabel, tostring(plan.nextErr))
    end
    mode.parkStage = "tool"
    mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, plan.marker.id)
    vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
    ADAutonomousManager.log("%s : « %s » fini, l'outil va à sa place « %s », puis « %s » pour le champ suivant « %s »", name, tostring(doneName),
        tostring(plan.marker.name), nextLabel, tostring(nextField.name))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 10000, "AD_autonomous_swapGo", tostring(plan.marker.name), nextLabel, tostring(nextField.name))
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin du travail : outil posé à sa place, puis tracteur garé
-- ------------------------------------------------------------------------------------------------------------
-- (07/11) fin du travail sans champ suivant : si l'outil a sa place de parking et le tracteur la sienne,
-- le chauffeur pose l'outil à sa place (dételé comme le joueur), puis va garer le tracteur. Masses et cuves ignorées.
-- Renvoie true si c'est lancé ; sinon false et le chauffeur se gare comme avant.
function AutonomousMode.parkWithToolDrop(vehicle, forcedTool)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.modes == nil then
        return false
    end
    local sm = vehicle.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS or sm:isActive() then
        return false
    end
    local name = tostring(sm:getName())
    -- forcedTool : outil ou remorque choisi par le bouton parking (AutonomousParkButton.lua)
    local tools = forcedTool ~= nil and { forcedTool } or ADAutonomousManager.workTools(vehicle)
    if #tools == 0 then
        return false
    end
    local tool = tools[1]
    local attacher = tool.getAttacherVehicle ~= nil and tool:getAttacherVehicle() or nil
    if #tools > 1 or attacher ~= vehicle then
        ADAutonomousManager.log("%s : %d outil(s) de travail attelé(s), pas de dételage", name, #tools)
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_dropSeveral")
        return false
    end
    local toolPark = tool.advd ~= nil and tool.advd.parkDestination or -1
    local toolMarker = toolPark ~= nil and toolPark >= 1 and ADGraphManager:getMapMarkerById(toolPark) or nil
    if toolMarker == nil then
        ADAutonomousManager.log("%s : l'outil n'a pas de place de parking", name)
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_dropNoToolPark")
        return false
    end
    local tractorPark = vehicle.advd ~= nil and vehicle.advd.parkDestination or -1
    local tractorMarker = tractorPark ~= nil and tractorPark >= 1 and tractorPark ~= toolPark and ADGraphManager:getMapMarkerById(tractorPark) or nil
    if tractorMarker == nil then
        ADAutonomousManager.log("%s : le tracteur n'a pas de place de parking (à part celle de l'outil)", name)
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.WARN, 10000, "AD_autonomous_dropNoTractorPark")
        return false
    end
    local mode = vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.restartCP = false
    sm:setStartHelper(false) -- pas de relance de Courseplay au parking
    vehicle:startAutoDrive()
    if not sm:isActive() then
        return false
    end
    mode:reset()
    mode.parkStage = "tool"
    mode.parkTool = tool
    mode.tractorParkId = tractorPark
    mode.driveToDestinationTask = DriveToDestinationTask:new(vehicle, toolMarker.id)
    vehicle.ad.taskModule:addTask(mode.driveToDestinationTask)
    ADAutonomousManager.log("%s : champ fini, l'outil va à sa place « %s », puis le tracteur à « %s »", name, tostring(toolMarker.name), tostring(tractorMarker.name))
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_dropGo", tostring(toolMarker.name))
    return true
end

-- étapes : « tool » (route vers la place de l'outil) -> « detach » (dételage) -> « tractor » (route vers la place du tracteur)
function AutonomousMode:handleParkStage()
    local vehicle = self.vehicle
    local name = tostring(vehicle.ad.stateModule:getName())
    local stage = self.parkStage
    if stage == "tool" then
        self.driveToDestinationTask = nil
        if vehicle.ad.isStoppingWithError then
            self.parkStage = nil
            vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
            return
        end
        self.parkStage = "detach"
        self.detachTask = ADDetachToolTask:new(vehicle, self.parkTool)
        vehicle.ad.taskModule:addTask(self.detachTask)
    elseif stage == "detach" then
        local result = self.detachTask ~= nil and self.detachTask.result or "?"
        self.detachTask = nil
        if result == "ok" and self.parkThen == "swap" then
            -- (07/11) changement d'outil : l'outil suivant devient l'outil du champ, start() va l'atteler puis au champ
            local nextTool = self.swapTool
            self.parkStage = nil
            self.parkTool = nil
            self.parkThen = nil
            self.swapTool = nil
            vehicle.ad.stateModule:setFpTool(nextTool)
            vehicle.ad.stateModule:setFpNextTool(nil)
            ADAutonomousManager.log("%s : outil posé, va chercher l'outil suivant « %s »", name, nextTool ~= nil and ADAutonomousManager.toolLabel(nextTool) or "?")
            self:start()
            return
        end
        local marker = ADGraphManager:getMapMarkerById(self.tractorParkId or -1)
        if result == "ok" and marker ~= nil then
            self.parkStage = "tractor"
            self.parkTool = nil
            vehicle.ad.onRouteToPark = true
            ADAutonomousManager.log("%s : outil dételé, le tracteur va à « %s »", name, tostring(marker.name))
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_dropDone", tostring(marker.name))
            self.driveToDestinationTask = DriveToDestinationTask:new(vehicle, marker.id)
            vehicle.ad.taskModule:addTask(self.driveToDestinationTask)
        else
            ADAutonomousManager.log("%s : outil non dételé (%s), arrêt", name, tostring(result))
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_dropFailed")
            self.parkStage = nil
            self.parkTool = nil
            vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
        end
    else
        -- « tractor » : arrivé à sa place
        self.parkStage = nil
        self.driveToDestinationTask = nil
        if not vehicle.ad.isStoppingWithError then
            ADAutonomousManager.log("%s : tracteur garé", name)
        end
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Aller atteler l'outil choisi dans le HUD
-- ------------------------------------------------------------------------------------------------------------
-- (07/11) routes existantes pour aller devant l'outil : toujours par le
-- réseau d'abord : vers la place de parking de l'outil s'il y est (routes en marche arrière dans la place), sinon vers
-- le point du réseau le plus proche de l'avant de l'outil ; la recherche de chemin ne sert qu'à finir

-- point du réseau où aller avant l'attelage, et pourquoi (« marker » ou « front ») ; nil : directement à l'attelage
function AutonomousMode.fetchRoutePoint(vehicle, tool)
    local hitch = ADAutonomousManager.toolHitch(vehicle, tool)
    if hitch == nil then
        return nil
    end
    if ADFetchToolTask.isReady(vehicle, hitch) then
        return nil
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local function startHere(wp)
        return MathUtil.vector2Length(wp.x - vx, wp.z - vz) <= AutonomousMode.FETCH_NEAR_START
    end
    -- 1) la place de parking de l'outil, s'il y est
    local park = tool.advd ~= nil and tool.advd.parkDestination or -1
    local marker = park ~= nil and park >= 1 and ADGraphManager:getMapMarkerById(park) or nil
    local mwp = marker ~= nil and ADGraphManager:getWayPointById(marker.id) or nil
    if mwp ~= nil and MathUtil.vector2Length(mwp.x - hitch.x, mwp.z - hitch.z) <= AutonomousMode.FETCH_MARKER_NEAR and not startHere(mwp) then
        return mwp, "marker", marker.name
    end
    -- 2) le point du réseau le plus proche de l'avant de l'outil
    local length = (vehicle.size ~= nil and vehicle.size.length) or 6
    local d = length + ADFetchToolTask.FRONT_MARGIN
    local fx, fz = hitch.x + hitch.dirX * d, hitch.z + hitch.dirZ * d
    local best, bestDistance = nil, AutonomousMode.FETCH_ROUTE_RANGE
    for _, wp in pairs(ADGraphManager:getWayPoints()) do
        local dist = MathUtil.vector2Length(wp.x - fx, wp.z - fz)
        local along = (wp.x - hitch.x) * hitch.dirX + (wp.z - hitch.z) * hitch.dirZ
        if dist < bestDistance and along >= AutonomousMode.FETCH_ROUTE_CLEAR then
            best, bestDistance = wp, dist
        end
    end
    if best ~= nil and not startHere(best) then
        return best, "front"
    end
    return nil
end

-- (07/11) aller atteler l'outil choisi : par le réseau, puis devant l'outil, marche arrière, attelage
function AutonomousMode:startFetch(tool)
    local vehicle = self.vehicle
    local name = tostring(vehicle.ad.stateModule:getName())
    self.fetchTool = tool
    self.fetchStuckTimer = 0
    vehicle.ad.onRouteToPark = false
    local okR, wp, kind, markerName = pcall(AutonomousMode.fetchRoutePoint, vehicle, tool)
    if not okR then
        ADAutonomousManager.log("ERREUR route vers l'outil : %s", tostring(wp))
        wp = nil
    end
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_fetchGo", ADAutonomousManager.toolLabel(tool))
    if wp ~= nil then
        if kind == "marker" then
            ADAutonomousManager.log("%s : va chercher « %s » par le réseau, vers sa place « %s »", name, ADAutonomousManager.toolLabel(tool), tostring(markerName))
        else
            ADAutonomousManager.log("%s : va chercher « %s » par le réseau, point %s devant l'outil", name, ADAutonomousManager.toolLabel(tool), tostring(wp.id))
        end
        self.fetchStage = "route"
        self.driveToDestinationTask = DriveToDestinationTask:new(vehicle, wp.id)
        vehicle.ad.taskModule:addTask(self.driveToDestinationTask)
    else
        ADAutonomousManager.log("%s : va chercher « %s »", name, ADAutonomousManager.toolLabel(tool))
        self:startFetchAttach()
    end
end

-- sur la route vers l'outil : dans son axe et assez près (ou arrêté devant lui) -> attelage
function AutonomousMode:monitorFetchRoute(dt)
    local task = self.driveToDestinationTask
    if self.fetchStage ~= "route" or task == nil or self.vehicle.ad.taskModule:getActiveTask() ~= task or self.fetchTool == nil then
        return
    end
    local ready, distance = ADFetchToolTask.readyFor(self.vehicle, self.fetchTool)
    if distance == nil then
        return
    end
    local name = tostring(self.vehicle.ad.stateModule:getName())
    if ready and distance <= AutonomousMode.FETCH_HANDOVER then
        ADAutonomousManager.log("%s : devant l'outil par le réseau (%.1f m), marche arrière", name, distance)
        task:finished()
        return
    end
    if math.abs(self.vehicle.lastSpeedReal or 0) < 0.0003 and distance <= AutonomousMode.FETCH_STUCK_RANGE then
        self.fetchStuckTimer = (self.fetchStuckTimer or 0) + dt
        if self.fetchStuckTimer >= AutonomousMode.FETCH_STUCK_TIME then
            ADAutonomousManager.log("%s : arrêté près de l'outil sur le réseau (%.1f m), on finit sans la route", name, distance)
            task:finished()
        end
    else
        self.fetchStuckTimer = 0
    end
end

function AutonomousMode:startFetchAttach()
    self.fetchStage = "attach"
    self.driveToDestinationTask = nil
    self.fetchTask = ADFetchToolTask:new(self.vehicle, self.fetchTool)
    self.vehicle.ad.taskModule:addTask(self.fetchTask)
end

-- étapes : « route » (par le réseau) -> « attach » (devant l'outil, marche arrière, attelage) -> départ au champ
function AutonomousMode:handleFetchStage()
    local vehicle = self.vehicle
    local name = tostring(vehicle.ad.stateModule:getName())
    local stage = self.fetchStage
    if stage == "route" then
        self.driveToDestinationTask = nil
        if vehicle.ad.isStoppingWithError then
            self.fetchStage = nil
            vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
            return
        end
        self:startFetchAttach()
        return
    end
    local tool = self.fetchTool
    local result = self.fetchTask ~= nil and self.fetchTask.result or "?"
    self.fetchTask = nil
    self.fetchStage = nil
    self.fetchTool = nil
    local label = tool ~= nil and ADAutonomousManager.toolLabel(tool) or "?"
    if result == "ok" then
        ADAutonomousManager.log("%s : outil « %s » attelé, départ vers le champ", name, label)
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_fetchDone", label)
        -- départ normal du mode Autonome (l'outil choisi est maintenant attelé)
        self:start()
    else
        ADAutonomousManager.log("%s : outil « %s » pas attelé (%s), arrêt", name, label, tostring(result))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, AutonomousMode.FETCH_FAIL_KEYS[result] or "AD_autonomous_fetchFailed", label)
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Plein à la zone de ravitaillement (semoir ; épandeur et pulvé : SprayerManager.lua)
-- ------------------------------------------------------------------------------------------------------------
-- (08/11) semoir : plein à la zone de ravitaillement, comme le mode Chargement :
--   au départ (semoir pas plein) : plein, puis le champ ;
--   semoir vide au champ (Courseplay s'arrête, événement onCpEmpty) : sortie du champ, plein, retour au champ,
--   puis Courseplay repart au dernier point (startCpAtLastWp, comme le mode Chargement avec Courseplay)

function AutonomousMode:startRefill(plan, after)
    local vehicle = self.vehicle
    local name = tostring(vehicle.ad.stateModule:getName())
    self.refillPlan = plan
    self.refillThen = after
    ADSeederManager.setLoadFillTypes(vehicle, plan.fillTypes)
    ADAutonomousManager.log("%s : semoir (%s), plein %s à « %s »%s", name, ADSeederManager.fillText(plan.tool, plan.fillTypes),
        table.concat(plan.settings.fillTypes or {}, "+"), tostring(plan.marker.name), after == "back" and ", puis retour au champ" or ", puis départ au champ")
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, after == "back" and (plan.emptyKey or "AD_autonomous_seederEmpty") or (plan.fillKey or "AD_autonomous_seederFill"), tostring(plan.marker.name)) -- textes de l'épandeur : SprayerManager.lua
    if after == "back" then
        local x, y, z = getWorldTranslation(vehicle.components[1].node)
        local fieldMarker = vehicle.ad.stateModule:getFirstMarker()
        local wp = fieldMarker ~= nil and ADGraphManager:getWayPointById(fieldMarker.id) or nil
        local dist = wp ~= nil and MathUtil.vector2Length(x - wp.x, z - wp.z) or 0
        if AutoDrive.checkIsOnField(x, y, z) and dist > AutonomousMode.REFILL_EXIT_DISTANCE then
            self.refillStage = "exit"
            self.refillTask = ExitFieldTask:new(vehicle)
            vehicle.ad.taskModule:addTask(self.refillTask)
            return
        end
    end
    self:startRefillLoad()
end

function AutonomousMode:startRefillLoad()
    self.refillStage = "load"
    self.refillTask = LoadAtDestinationTask:new(self.vehicle, self.refillPlan.marker.id)
    self.vehicle.ad.taskModule:addTask(self.refillTask)
end

-- arrêté au point de ravitaillement : les cuves des produits choisis pleines = fini, même si une autre cuve du semoir
-- (produit non choisi) est vide (le mode Chargement compte toutes les cuves et attendrait)
function AutonomousMode:monitorRefill(dt)
    local task = self.refillTask
    if task == nil or self.refillPlan == nil or self.vehicle.ad.taskModule:getActiveTask() ~= task then
        return
    end
    if task.state ~= LoadAtDestinationTask.STATE_DRIVING or not self.vehicle.ad.drivePathModule:isTargetReached() then
        return
    end
    if self.vehicle.ad.trailerModule:isActiveAtTrigger() then
        return
    end
    if ADSeederManager.productsFull(self.refillPlan.tool, self.refillPlan.fillTypes, self.vehicle) then
        task:finished()
    end
end

-- étapes : « exit » (sortie du champ) -> « load » (plein) -> « back » (retour au champ) ou départ au champ
function AutonomousMode:handleRefillStage()
    local vehicle = self.vehicle
    local name = tostring(vehicle.ad.stateModule:getName())
    local stage = self.refillStage
    self.refillTask = nil
    if vehicle.ad.isStoppingWithError then
        self.refillStage = nil
        self.refillPlan = nil
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
        return
    end
    if stage == "exit" then
        self:startRefillLoad()
    elseif stage == "load" then
        local plan = self.refillPlan
        ADAutonomousManager.log("%s : plein fait (%s)", name, ADSeederManager.fillText(plan.tool, plan.fillTypes))
        if self.refillThen == "back" then
            local fieldMarker = vehicle.ad.stateModule:getFirstMarker()
            self.refillStage = "back"
            self.refillTask = DriveToDestinationTask:new(vehicle, fieldMarker.id)
            vehicle.ad.taskModule:addTask(self.refillTask)
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_seederBack", tostring(fieldMarker.name))
        else
            self.refillStage = nil
            self.refillPlan = nil
            self.refillThen = nil
            self:departToField()
        end
    else
        -- « back » : revenu au champ, Courseplay repart au dernier point (voir stopAutoDrive, fpRestartCp)
        self.refillStage = nil
        self.refillPlan = nil
        self.refillThen = nil
        ADAutonomousManager.log("%s : de retour au champ, Courseplay repart où il s'était arrêté", name)
        vehicle.ad.fpRestartCp = true
        vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
    end
end

-- bouton « Continuer » au point de ravitaillement (rien à charger, ou le joueur ne veut pas attendre) : on repart
function AutonomousMode:continue()
    if self.baleStage ~= nil and ADBaleCollect ~= nil and ADBaleCollect.onContinue(self) then return end -- remorque à balles : >> = dépôt tout de suite, voir AutonomousBales.lua
    if self.refillStage == "load" and self.refillTask ~= nil and self.vehicle.ad.taskModule:getActiveTask() == self.refillTask then
        ADAutonomousManager.log("%s : plein arrêté par le joueur (Continuer)", tostring(self.vehicle.ad.stateModule:getName()))
        self.refillTask:continue()
        self.refillTask:finished()
    end
end

-- Courseplay arrêté semoir vide (événement onCpEmpty) en mode Autonome : plein à la zone puis retour au champ ;
-- true si c'est lancé (sinon arrêt comme avant)
function AutonomousMode.onCpEmpty(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.modes == nil or not vehicle.isServer then
        return false
    end
    local sm = vehicle.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS or sm:isActive() then
        return false
    end
    local name = tostring(sm:getName())
    local plan = ADSeederManager.prepare(vehicle)
    plan = plan or (ADSprayerManager ~= nil and ADSprayerManager.preparePlan(vehicle, "back") or nil) -- épandeur / pulvé vide : même plein que le semoir, voir SprayerManager.lua
    if plan == nil or plan.marker == nil then
        ADAutonomousManager.log("%s : Courseplay arrêté (cuve vide), pas de semoir réglé attelé : arrêt", name)
        return false
    end
    if not plan.needsFill then
        -- cuves choisies pleines : c'est une autre cuve qui manque, un plein ne servirait à rien (et tournerait en rond)
        ADAutonomousManager.log("%s : Courseplay arrêté (cuve vide) mais les cuves choisies sont pleines (%s) : arrêt", name, ADSeederManager.fillText(plan.tool, plan.fillTypes))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_seederOther")
        return false
    end
    vehicle.ad.onRouteToRefuel = false
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.onRouteToPark = false
    vehicle.ad.restartCP = false
    vehicle:startAutoDrive()
    if not sm:isActive() then
        return false
    end
    local mode = vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS]
    mode:reset()
    mode:startRefill(plan, "back")
    return true
end
