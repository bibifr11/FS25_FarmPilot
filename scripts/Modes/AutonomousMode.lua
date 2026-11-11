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
AutonomousMode.FETCH_PLACE_LATERAL = 2.5  -- m : point d'attelage de l'outil à moins de ça de l'axe de sa place
AutonomousMode.FETCH_PLACE_ANGLE = 30     -- ° : outil dans l'axe de sa place à moins de ça (dans un sens ou dans l'autre)
AutonomousMode.FETCH_PLACE_AXIS = 6       -- m de route avant le point de la place pour en prendre l'axe
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
    if ADAutonomousManager.journalFlush ~= nil then
        ADAutonomousManager.journalFlush(true) -- journal du mode Autonome : les dernières lignes dans le fichier (arrêt)
    end
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
    self.fetchPlace = nil
    self.fetchTask = nil
    self.fetchStuckTimer = nil
    self.fetchNoseAhead = nil
    -- (08/11) semoir : plein à la zone de ravitaillement, comme le mode Chargement (voir startRefill)
    self.refillStage = nil
    self.refillThen = nil
    self.refillPlan = nil
    self.refillTask = nil
    self.dumpStage = nil -- épandeur : vider le reste en big bags, voir AutonomousSprayerDump.lua
    if ADBaleCollect ~= nil then ADBaleCollect.reset(self) end -- remorque à balles : étapes du ramassage, voir AutonomousBales.lua
    if ADFuelRun ~= nil then ADFuelRun.reset(self) end -- plein de carburant, voir AutonomousFuel.lua
    if ADFrontFlow ~= nil then ADFrontFlow.reset(self) end -- attelage avant, voir AutonomousFront.lua
    if ADParkUnload ~= nil then ADParkUnload.reset(self) end -- bouton parking, benne à vider d'abord, voir AutonomousParkUnload.lua
    self.vehicle.ad.trailerModule:reset()
end

-- (11/11) coincé 8 s sur une courbe calculée (entrée ou sortie d'une place, DrivePathModuleStuck.lua) : la tâche
-- lâche la courbe elle-même (recherche de chemin, ou suite par le réseau) ; pas de remise à zéro d'AutoDrive, qui
-- relancerait le départ. true si une tâche s'en occupe
function AutonomousMode:onDriveStuck(info)
    local taskModule = self.vehicle.ad.taskModule
    local task = taskModule ~= nil and taskModule.activeTask or nil
    if task ~= nil and task.onDriveStuck ~= nil then
        local ok, handled = FarmPilotCall(task.onDriveStuck, task, info)
        if ok and handled then
            ADAutonomousManager.log("%s : %s : la courbe est lâchée", tostring(self.vehicle.ad.stateModule:getName()), tostring(info))
            return true
        end
    end
    return false
end

function AutonomousMode:stop()
    if ADAutonomousManager.journalFlush ~= nil then
        ADAutonomousManager.journalFlush(true) -- journal du mode Autonome : les dernières lignes dans le fichier
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function AutonomousMode:start(user)
    -- (08/11) départ refusé tant que les réglages ne sont pas validés : semoir sur la ligne
    -- Outil (ou Outil suivant) : culture, produits et zone de ravitaillement à valider (roue dentée) avant le départ
    local okB, block = FarmPilotCall(ADSeederManager.startBlock, self.vehicle)
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
    local frontStop, frontPlan = nil, nil
    if ADFrontFlow ~= nil then frontStop, frontPlan = ADFrontFlow.checkStart(self) if frontStop then return end end -- outil avant à atteler, voir AutonomousFront.lua
    -- (07/11) outil choisi dans le HUD et pas encore attelé : on va l'atteler d'abord
    local okF, fetchTool, fetchErr, wanted = FarmPilotCall(ADAutonomousManager.toolToFetch, self.vehicle)
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
        local okT, hasTool = FarmPilotCall(ADAutonomousManager.hasWorkTool, self.vehicle)
        if okT and not hasTool and fetchTool == nil and not (frontPlan ~= nil and ADAutonomousManager.isWorkObject(frontPlan.fetch)) then
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
    if frontPlan ~= nil and ADFrontFlow.execute(self, frontPlan) then return end -- l'avant d'abord, puis start() de nouveau
    if fetchTool ~= nil then
        self:startFetch(fetchTool)
        return
    end
    -- (08/11) semoir réglé attelé : culture mise sur le semoir ; pas plein = plein à la zone d'abord, puis le champ
    local okP, plan = FarmPilotCall(ADSeederManager.prepare, self.vehicle)
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
    local ok, err = FarmPilotCall(ADAutonomousManager.startPrefetch)
    if not ok then
        ADAutonomousManager.log("ERREUR lecture des parcours : %s", tostring(err))
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Message au joueur
-- ------------------------------------------------------------------------------------------------------------
-- texte traduit et rempli ici (les textes contiennent des %s, que le gestionnaire de messages ne sait pas remplacer)
function AutonomousMode.message(vehicle, messageType, duration, key, ...)
    local ok, txt = FarmPilotCall(string.format, g_i18n:getText(key), ...)
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
        FarmPilotCall(ADAutonomousManager.prefetchStep)
    end
    if ADAutonomousManager.journalDirty then
        ADAutonomousManager.journalFlush(false)
    end
    if self.fetchStage == "route" then
        local ok, err = FarmPilotCall(self.monitorFetchRoute, self, dt)
        if not ok then
            ADAutonomousManager.log("ERREUR route vers l'outil : %s", tostring(err))
        end
    end
    if ADSprayerManager ~= nil then FarmPilotCall(ADSprayerManager.monitorTarget, self, dt) end -- épandeur : chargement arrêté à la quantité voulue, voir SprayerManager.lua
    if self.parkUnloadStage ~= nil and ADParkUnload ~= nil then FarmPilotCall(ADParkUnload.monitor, self, dt) end -- bouton parking, benne à vider : plus d'attente si rien ne se vide, voir AutonomousParkUnload.lua
    if self.refillStage == "load" then
        local ok, err = FarmPilotCall(self.monitorRefill, self, dt)
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
    if self.fuelStage ~= nil and ADFuelRun ~= nil then ADFuelRun.handleStage(self) return end -- plein de carburant : pompe, retour, voir AutonomousFuel.lua
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
    if self.parkUnloadStage ~= nil and ADParkUnload ~= nil then ADParkUnload.handleStage(self) return end -- bouton parking : benne vidée, la suite, voir AutonomousParkUnload.lua
    if self.baleStage ~= nil and ADBaleCollect ~= nil then ADBaleCollect.handleStage(self) return end -- remorque à balles : ramassage, dépôt, retour, voir AutonomousBales.lua
    if self.driveToDestinationTask == nil then
        return
    end
    self.driveToDestinationTask = nil
    local vehicle = self.vehicle
    local name = vehicle.ad.stateModule:getName()
    if vehicle.ad.isStoppingWithError == false and ADBaleCollect ~= nil and ADBaleCollect.onArrival(self) then return end -- remorque à balles : notre ramassage au lieu d'un parcours, voir AutonomousBales.lua

    if vehicle.ad.isStoppingWithError == false then
        local ok, e, err, width, fieldNum, tool, count = FarmPilotCall(ADAutonomousManager.choose, ADAutonomousManager, vehicle)
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
    if ADFuelRun ~= nil and ADFuelRun.beforeNextField(vehicle) then return true end -- peu de carburant : plein d'abord, voir AutonomousFuel.lua
    local doneName = tostring(sm:getFirstMarkerName() or "?")
    local name = tostring(sm:getName())
    -- (07/11, 4e ligne « Outil suivant ») : outil à changer avant le champ suivant ?
    local swap = nil
    local nextTool = sm.getFpNextTool ~= nil and sm:getFpNextTool() or nil
    if nextTool ~= nil then
        local okS, plan, err = FarmPilotCall(AutonomousMode.toolSwapPlan, vehicle, nextTool)
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
    if ADFrontFlow ~= nil then ADFrontFlow.applyNextFront(vehicle) end -- outil avant suivant, échangé au départ, voir AutonomousFront.lua
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
    if ADFrontFlow ~= nil then local handled = ADFrontFlow.parkWithFront(vehicle, forcedTool) if handled ~= nil then return handled end end -- outil avant, masse à reprendre, voir AutonomousFront.lua
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
    if ADFrontFlow ~= nil and ADFrontFlow.handleParkStage(self) then return end -- attelage avant, voir AutonomousFront.lua
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
            if ADParkButton ~= nil then ADParkButton.onParked(vehicle) end -- garé à sa place : choix d'outils et champ suivant effacés, voir AutonomousParkButton.lua
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

-- (10/11) place prise en marche arrière : le réseau n'écrit pas ce bout de route dans les « incoming » du point où il
-- arrive (c'est ce qui en fait une marche arrière, voir ADGraphManager:isReverseRoad). Table « point d'arrivée ->
-- point de départ » de ces bouts de route, refaite quand le nombre de points change ou après REVERSE_INDEX_AGE ms
-- (30 s : la refaire coûte jusqu'à 25 ms sur un très grand réseau, 37 000 points)
AutonomousMode.REVERSE_INDEX_AGE = 30000

-- le point d'où part la marche arrière qui arrive à wp ; nil s'il n'y en a pas
function AutonomousMode.reversePrevious(wp)
    local index = AutonomousMode.reverseIndex
    local count = ADGraphManager.getWayPointsCount ~= nil and ADGraphManager:getWayPointsCount() or nil
    local now = g_time or 0
    if index == nil or index.count ~= count or now < index.time or now - index.time > AutonomousMode.REVERSE_INDEX_AGE then
        index = { count = count, time = now, prev = {} }
        for _, p in pairs(ADGraphManager:getWayPoints()) do
            if p.out ~= nil then
                for _, outId in pairs(p.out) do
                    local target = ADGraphManager:getWayPointById(outId)
                    if target ~= nil and (target.incoming == nil or not table.contains(target.incoming, p.id)) then
                        local known = index.prev[outId]
                        if known == nil or p.id < known then
                            index.prev[outId] = p.id
                        end
                    end
                end
            end
        end
        AutonomousMode.reverseIndex = index
    end
    local id = index.prev[wp.id]
    return id ~= nil and ADGraphManager:getWayPointById(id) or nil
end

-- le point d'avant sur la route qui arrive à wp, et true si ce bout de route se prend en marche arrière
local function previousPoint(wp)
    local inc = wp.incoming ~= nil and wp.incoming[1] or nil
    local p = inc ~= nil and ADGraphManager:getWayPointById(inc) or nil
    if p ~= nil then
        return p, false
    end
    p = AutonomousMode.reversePrevious(wp)
    return p, p ~= nil
end

-- axe d'une place (sens de la route qui y arrive) : derniers FETCH_PLACE_AXIS m de route avant le point de la place ;
-- nil sans route qui arrive. 3e valeur : true si cette route se prend en marche arrière (10/11 : ces places-là
-- n'avaient pas d'axe)
function AutonomousMode.placeAxis(mwp)
    local prev, cur, reverse = nil, mwp, false
    for _ = 1, 20 do
        local p, byReverse = previousPoint(cur)
        if p == nil or p == mwp then
            break
        end
        if prev == nil then
            reverse = byReverse
        end
        prev, cur = p, p
        if MathUtil.vector2Length(mwp.x - p.x, mwp.z - p.z) >= AutonomousMode.FETCH_PLACE_AXIS then
            break
        end
    end
    if prev == nil then
        return nil
    end
    local hx, hz = mwp.x - prev.x, mwp.z - prev.z
    local len = MathUtil.vector2Length(hx, hz)
    if len < 0.5 then
        return nil
    end
    return hx / len, hz / len, reverse
end

-- place prise en marche arrière : le point du réseau où cette marche arrière commence (le tracteur y arrive en marche
-- avant) ; nil si la place se prend en marche avant ou n'a pas de route
function AutonomousMode.placeReverseStart(mwp)
    local cur, start = mwp, nil
    for _ = 1, 60 do
        local p, byReverse = previousPoint(cur)
        if p == nil or p == mwp or not byReverse then
            break
        end
        start, cur = p, p
    end
    return start
end

-- (10/11) le tracteur recule dans la place : en marche arrière sur la route, dans l'axe de la place (pas encore dans
-- le virage qui y mène : la ligne droite jusqu'à l'outil couperait le coin)
function AutonomousMode.reversingInPlace(vehicle, mwp)
    local dpm = vehicle.ad ~= nil and vehicle.ad.drivePathModule or nil
    if mwp == nil or dpm == nil or dpm.getIsReversing == nil or dpm:getIsReversing() ~= true then
        return false
    end
    local hx, hz = AutonomousMode.placeAxis(mwp)
    if hx == nil then
        return false
    end
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    local fx, _, fz = AutoDrive.localDirectionToWorld(vehicle, 0, 0, 1)
    local len = MathUtil.vector2Length(fx, fz)
    if len < 0.001 then
        return false
    end
    local lateral = math.abs((vx - mwp.x) * hz - (vz - mwp.z) * hx)
    local cosA = -(fx * hx + fz * hz) / len
    return lateral <= ADFetchToolTask.READY_LATERAL and cosA >= math.cos(math.rad(ADFetchToolTask.READY_ANGLE))
end

-- (09/11) outil rangé dans l'axe de sa place ? axe = derniers FETCH_PLACE_AXIS m de route avant le point de la place.
-- true, écart du point d'attelage à l'axe (m), angle de l'outil avec l'axe (°) ; sans route qui arrive : true
function AutonomousMode.toolInPlace(mwp, hitch)
    local hx, hz = AutonomousMode.placeAxis(mwp)
    if hx == nil then
        return true
    end
    local ox, oz = hitch.x - mwp.x, hitch.z - mwp.z
    local lateral = math.abs(ox * hz - oz * hx)
    local cosA = math.min(1, math.abs(hitch.dirX * hx + hitch.dirZ * hz))
    local angle = math.deg(math.acos(cosA))
    return lateral <= AutonomousMode.FETCH_PLACE_LATERAL and angle <= AutonomousMode.FETCH_PLACE_ANGLE, lateral, angle
end

-- (10/11) la place prise en marche arrière où un outil est rangé, même si elle ne lui est pas attribuée (faucheuse
-- arrière au fond d'une travée, faucheuse avant devant elle) : le marqueur, ou nil. L'outil est dans l'axe de la
-- place (toolInPlace), pas au-delà du fond, son point d'attelage tourné vers la sortie. hitch : son point d'attelage
-- (toolHitch pour un outil arrière, frontHitch pour un outil avant : direction vers le tracteur)
AutonomousMode.FETCH_PLACE_BEYOND = 3   -- m : point d'attelage au plus à ça au-delà du point de la place
function AutonomousMode.reversePlaceOf(hitch)
    local best, bestLateral = nil, math.huge
    for _, marker in pairs(ADGraphManager:getMapMarkers()) do
        local mwp = ADGraphManager:getWayPointById(marker.id)
        if mwp ~= nil and mwp.x ~= nil and MathUtil.vector2Length(mwp.x - hitch.x, mwp.z - hitch.z) <= AutonomousMode.FETCH_MARKER_NEAR then
            local hx, hz, reverse = AutonomousMode.placeAxis(mwp)
            if hx ~= nil and reverse then
                local inPlace, lateral = AutonomousMode.toolInPlace(mwp, hitch)
                local along = (hitch.x - mwp.x) * hx + (hitch.z - mwp.z) * hz
                local out = -(hitch.dirX * hx + hitch.dirZ * hz)
                -- (pas plus loin devant la place que le début de sa marche arrière : posé dans la cour, ce n'est pas rangé)
                local start = AutonomousMode.placeReverseStart(mwp)
                local depth = start ~= nil and MathUtil.vector2Length(start.x - mwp.x, start.z - mwp.z) or 0
                if inPlace and along <= AutonomousMode.FETCH_PLACE_BEYOND and along >= -depth and out >= math.cos(math.rad(AutonomousMode.FETCH_PLACE_ANGLE))
                    and lateral < bestLateral then
                    best, bestLateral = marker, lateral
                end
            end
        end
    end
    return best
end

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
        -- (09/11) seulement si l'outil y est rangé dans l'axe : en travers, la route de la place bute sur l'outil
        local inPlace, lateral, angle = AutonomousMode.toolInPlace(mwp, hitch)
        if inPlace then
            return mwp, "marker", marker.name
        end
        ADAutonomousManager.log("%s : « %s » pas rangé dans l'axe de sa place « %s » (écart %.1f m, angle %.0f°) : route vers le point du réseau devant l'outil",
            tostring(vehicle.ad.stateModule:getName()), ADAutonomousManager.toolLabel(tool), tostring(marker.name), lateral or -1, angle or -1)
    end
    -- (10/11) pas à sa place (ou pas de place à lui), mais rangé au fond d'une place prise en marche arrière : par la
    -- route de cette place, qui amène le tracteur en marche arrière devant lui (pas de demi-tour devant la place)
    local okP, place = FarmPilotCall(AutonomousMode.reversePlaceOf, hitch)
    local pwp = okP and place ~= nil and ADGraphManager:getWayPointById(place.id) or nil
    if pwp ~= nil and pwp.x ~= nil and pwp ~= mwp and not startHere(pwp) then
        ADAutonomousManager.log("%s : « %s » est rangé dans la place « %s » : repris par la route de cette place", tostring(vehicle.ad.stateModule:getName()),
            ADAutonomousManager.toolLabel(tool), tostring(place.name))
        return pwp, "marker", place.name
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
    local okR, wp, kind, markerName, nosePlace, noseAhead = FarmPilotCall(self.fetchSide == "front" and ADFrontFlow.fetchRoutePoint or AutonomousMode.fetchRoutePoint, vehicle, tool) -- (10/11) avant : AutonomousFront.lua
    if not okR then
        ADAutonomousManager.log("ERREUR route vers l'outil : %s", tostring(wp))
        wp, nosePlace, noseAhead = nil, nil, nil
    end
    self.fetchNoseIn = nosePlace -- outil avant au fond d'une place prise en marche arrière : entrée en courbe, voir AutonomousNoseIn.lua
    self.fetchNoseAhead = noseAhead -- ... et m entre le fond de la place et le bout de l'outil (rangé devant un autre)
    AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_fetchGo", ADAutonomousManager.toolLabel(tool))
    if wp ~= nil then
        if kind == "marker" then
            ADAutonomousManager.log("%s : va chercher « %s » par le réseau, vers sa place « %s »", name, ADAutonomousManager.toolLabel(tool), tostring(markerName))
        else
            ADAutonomousManager.log("%s : va chercher « %s » par le réseau, point %s devant l'outil", name, ADAutonomousManager.toolLabel(tool), tostring(wp.id))
        end
        self.fetchStage = "route"
        self.fetchPlace = kind == "marker" and wp or nil
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
    local T = self.fetchSide == "front" and ADFetchFrontToolTask or ADFetchToolTask -- (10/11) avant : FetchFrontToolTask.lua
    local ready, distance, reachable = T.readyFor(self.vehicle, self.fetchTool)
    if distance == nil then
        return
    end
    local name = tostring(self.vehicle.ad.stateModule:getName())
    if ready and distance <= AutonomousMode.FETCH_HANDOVER then
        ADAutonomousManager.log("%s : devant l'outil par le réseau (%.1f m), %s", name, distance, T.APPROACH_TEXT)
        task:finished()
        return
    end
    -- (10/11) outil qui a bougé dans sa place : la route mène où il était, plus où il est. En marche arrière dans la
    -- place, son point d'attelage derrière le tracteur et à portée : on lâche la route et on recule vers lui
    local inPlace
    if self.fetchSide == "front" then
        inPlace = ADFrontFlow.forwardInPlace(self.vehicle, self.fetchPlace)
    else
        inPlace = AutonomousMode.reversingInPlace(self.vehicle, self.fetchPlace)
    end
    if reachable and distance <= AutonomousMode.FETCH_HANDOVER and inPlace then
        ADAutonomousManager.log("%s : outil pas dans l'axe (%.1f m), on lâche la route et on vise son point d'attelage", name, distance)
        task:finished()
        return
    end
    -- (pas en route vers le point d'où une courbe entre dans la place : arrêté par la circulation, il y va quand même,
    -- la courbe ne part que de là)
    if self.fetchNoseIn == nil and math.abs(self.vehicle.lastSpeedReal or 0) < 0.0003 and distance <= AutonomousMode.FETCH_STUCK_RANGE then
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
    self.fetchPlace = nil
    self.driveToDestinationTask = nil
    local T = self.fetchSide == "front" and ADFetchFrontToolTask or ADFetchToolTask -- (10/11) avant : FetchFrontToolTask.lua
    self.fetchTask = T:new(self.vehicle, self.fetchTool, true)
    self.fetchTask.noseInPlace = self.fetchNoseIn
    self.fetchTask.noseInAhead = self.fetchNoseAhead
    self.fetchNoseIn = nil
    self.fetchNoseAhead = nil
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
    if result == "ok" and ADFrontFlow ~= nil and ADFrontFlow.afterFetch(self, tool) then return end -- fin du travail : masse reprise, voir AutonomousFront.lua
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
    if ADBaleCollect ~= nil and ADBaleCollect.onContinue(self) then return end -- remorque à balles : >> = dépôt tout de suite (aussi sur le 1er trajet vers le champ), voir AutonomousBales.lua
    if self.refillStage == "load" and self.refillTask ~= nil and self.vehicle.ad.taskModule:getActiveTask() == self.refillTask then
        ADAutonomousManager.log("%s : plein arrêté par le joueur (Continuer)", tostring(self.vehicle.ad.stateModule:getName()))
        self.refillTask:continue()
        self.refillTask:finished()
        return
    end
    if self:skipFieldOnRoad() then return end
    if self.vehicle.ad.continueByPlayer then
        ADAutonomousManager.log("%s : >> : rien à passer ici (pas sur la route vers un champ ; au champ, le parcours finit le champ)", tostring(self.vehicle.ad.stateModule:getName()))
    end
end

-- (09/11) >> sur la route vers le champ (pas encore arrivé) : ce champ est laissé, départ vers le champ suivant, avec
-- la même suite qu'un champ fini (outil suivant, plein de carburant, reste du pulvé). Au champ, le parcours finit le
-- champ : >> n'y fait rien. Pas de champ suivant : message, la route continue. true = bouton pris ici.
function AutonomousMode:skipFieldOnRoad()
    local vehicle = self.vehicle
    local sm = vehicle.ad.stateModule
    local first = sm:getFirstMarker()
    if not vehicle.isServer or not sm:isActive() or self.driveToDestinationTask == nil
        or vehicle.ad.taskModule:getActiveTask() ~= self.driveToDestinationTask
        or first == nil or self.destinationID ~= first.id
        or self.refillStage ~= nil or self.fetchStage ~= nil or self.parkStage ~= nil or self.dumpStage ~= nil
        or self.fuelStage ~= nil or self.baleStage ~= nil then
        return false
    end
    local name = tostring(sm:getName())
    local nextField = sm:getFpNextField()
    if nextField == nil or nextField.markerIndex == nil or ADGraphManager:getMapMarkerById(nextField.markerIndex) == nil then
        ADAutonomousManager.log("%s : >> sur la route : pas de champ suivant, la route vers « %s » continue", name, tostring(first.name))
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 8000, "AD_autonomous_skipNoNext", tostring(first.name))
        return true
    end
    ADAutonomousManager.log("%s : >> sur la route : « %s » laissé, champ suivant « %s »", name, tostring(first.name), tostring(nextField.name))
    self.driveToDestinationTask = nil
    vehicle.ad.taskModule:abortCurrentTask()
    -- arrêt puis, à l'image suivante, la suite d'un champ fini (AutonomousBales.lua, afterStop -> onCpFinished -> goToNextField)
    vehicle.ad.fpBaleContinue = true
    vehicle.ad.taskModule:addTask(StopAndDisableADTask:new(vehicle, ADTaskModule.DONT_PROPAGATE))
    return true
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
