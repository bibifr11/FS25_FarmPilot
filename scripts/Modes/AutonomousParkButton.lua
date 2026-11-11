-- ============================================================================================================
-- FarmPilot : AutonomousParkButton.lua
-- Complément du bouton « Envoyer au parking » (ADInputManager:input_parkVehicle, AutoDrive d'origine).
--
-- (08/11) Envoi au parking : comme en fin de champ, le tracteur va d'abord poser son outil s'il y en a un,
-- puis va se stationner à sa place.
--
-- Règle : un outil de travail attelé directement au tracteur, qui a sa place de parking, et le tracteur qui a la
-- sienne (différente) : le bouton arrête Courseplay et FarmPilot comme avant, puis lance la même suite qu'en fin de
-- champ (AutonomousMode.parkWithToolDrop) : l'outil va à sa place et y est dételé, puis le tracteur va à la sienne.
-- Sinon (pas d'outil avec sa place, plusieurs, tracteur sans place) : bouton d'origine, le tracteur se gare tel
-- quel.
-- Épandeur / pulvé avec du produit : vidange en big bags d'abord (AutonomousSprayerDump.lua), puis ce bouton.
-- (11/11) Benne pas vide et destination de déchargement réglée : elle va vider d'abord (AutonomousParkUnload.lua),
-- puis ce bouton.
--
-- (11/11) Tracteur garé à sa place : les lignes Outil AV, Outil AR, Outil AV suivant, Outil AR suivant et Champ
-- suivant du mode Autonome reviennent à leur valeur par défaut (clearChoices). Sinon, relancé avec un autre outil
-- arrière, le tracteur retournait chercher l'outil avant d'avant. Appelé quand le parking est allé au bout : ligne
-- « tracteur garé » (AutonomousMode:handleParkStage, avec ou sans outil avant) et arrivée du parking d'origine
-- (DriveToMode:handleFinishedTask). Pas à un arrêt en route.
--
-- (09/11) La dépose passe en mode Autonome (seul mode qui sait poser l'outil). Le mode d'avant (Chargement /
-- Livraison…) est noté au passage (rememberMode) et rendu à l'arrêt de FarmPilot (afterStop, crochet dans
-- Specialization.lua), avec ses cibles automatiques. Même chose pour la vidange en big bags (AutonomousSprayerDump.lua)
-- et la remorque posée en fin de chantier (TrailerHitch.lua).
-- ============================================================================================================

ADParkButton = {}

-- ------------------------------------------------------------------------------------------------------------
-- Mode d'avant la dépose
-- ------------------------------------------------------------------------------------------------------------
-- à appeler juste avant setMode(AutoDrive.MODE_AUTONOMOUS) ; le premier mode noté est gardé
function ADParkButton.rememberMode(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.fpModeBeforePark ~= nil then
        return
    end
    local sm = vehicle.ad.stateModule
    local mode = sm:getMode()
    if mode == nil or mode == AutoDrive.MODE_AUTONOMOUS then
        return
    end
    vehicle.ad.fpModeBeforePark = { mode = mode, pickup = sm:getAutomaticPickupTarget(), unload = sm:getAutomaticUnloadTarget() }
end

-- FarmPilot arrêté (garé, arrêt à la main, erreur) : le mode noté revient, sauf s'il a été changé entre-temps
function ADParkButton.restoreMode(vehicle)
    local saved = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.fpModeBeforePark or nil
    if saved == nil then
        return
    end
    vehicle.ad.fpModeBeforePark = nil
    local sm = vehicle.ad.stateModule
    if sm == nil or sm:isActive() or sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return
    end
    sm:setMode(saved.mode)
    if sm:getMode() ~= saved.mode then
        return
    end
    if saved.pickup then
        sm:setAutomaticPickupTarget(true)
    end
    if saved.unload then
        sm:setAutomaticUnloadTarget(true)
    end
    ADAutonomousManager.log("%s : mode d'avant la dépose rendu (%s)", tostring(sm:getName()), tostring(saved.mode))
end

function ADParkButton.afterStop(vehicle)
    ADParkButton.restoreMode(vehicle)
end

-- ------------------------------------------------------------------------------------------------------------
-- Tracteur garé à sa place : choix du HUD du mode Autonome effacés
-- ------------------------------------------------------------------------------------------------------------
ADParkButton.PARKED_RANGE = 30 -- m : parking d'origine, le tracteur doit être arrivé à sa place pour que les choix s'effacent

-- les 5 lignes reviennent à « celui attelé » / « le même » / « aucun » (envoyé aux clients comme un choix du HUD).
-- La masse posée au départ n'est pas touchée ici : elle a été reprise avant de se garer (AutonomousFront.lua) ;
-- si elle ne l'a pas été, elle reste notée pour être reprise au prochain retour. true si quelque chose est effacé
function ADParkButton.clearChoices(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or sm.getFpTool == nil then
        return false
    end
    local cleared = {}
    local function clear(line, get, set, labelOf)
        if get == nil or set == nil then
            return
        end
        local value = get(sm)
        if value ~= nil then
            cleared[#cleared + 1] = string.format("%s « %s »", line, tostring(labelOf(value)))
            set(sm, nil)
        end
    end
    -- noms comme dans le HUD : « Faucheuse (9,4 m) », « Masse (1 500 kg) »
    local function hudName(tool, labelFn)
        if labelFn ~= nil then
            local ok, l = FarmPilotCall(labelFn, tool)
            if ok and l ~= nil then
                return l
            end
        end
        return ADAutonomousManager.toolLabel(tool)
    end
    local function rearName(tool) return hudName(tool, ADAutonomousManager.toolShortLabel) end
    local function frontName(tool) return hudName(tool, ADAutonomousManager.frontLabel) end
    clear("Outil AV", sm.getFpFrontTool, sm.setFpFrontTool, frontName)
    clear("Outil AR", sm.getFpTool, sm.setFpTool, rearName)
    clear("Outil AV suivant", sm.getFpNextFrontTool, sm.setFpNextFrontTool, frontName)
    clear("Outil AR suivant", sm.getFpNextTool, sm.setFpNextTool, rearName)
    clear("Champ suivant", sm.getFpNextField, sm.setFpNextField, function(marker) return marker.name end)
    local name = tostring(sm:getName())
    if #cleared > 0 then
        ADAutonomousManager.log("%s : tracteur garé, choix d'outils effacés (%s)", name, table.concat(cleared, ", "))
    end
    local mass = ADFrontFlow ~= nil and ADFrontFlow.massWaiting(vehicle) or nil
    if mass ~= nil then
        ADAutonomousManager.log("%s : « %s » n'a pas été reprise : elle reste notée, reprise au prochain retour au parking", name, frontName(mass))
    end
    return #cleared > 0
end

-- Hook AutonomousMode:handleParkStage (« tracteur garé »)
function ADParkButton.onParked(vehicle)
    local ok, err = FarmPilotCall(ADParkButton.clearChoices, vehicle)
    if not ok then
        ADAutonomousManager.log("ERREUR choix d'outils à effacer : %s", tostring(err))
    end
end

-- distance du tracteur au point de sa place de parking (la destination du trajet) et nom de la place ; nil si inconnu
function ADParkButton.distanceToParkPlace(vehicle, wayPointId)
    local wp = wayPointId ~= nil and ADGraphManager:getWayPointById(wayPointId) or nil
    if wp == nil or wp.x == nil or wp.z == nil then
        return nil
    end
    local marker = ADGraphManager:getMapMarkerByWayPointId(wayPointId)
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    return MathUtil.vector2Length(wp.x - x, wp.z - z), marker ~= nil and marker.name or "?"
end

-- Hook DriveToMode:handleFinishedTask : parking d'origine (bouton, fin de travail sans outil à poser) arrivé à
-- wayPointId, la place du tracteur
function ADParkButton.onDriveToArrived(vehicle, wayPointId)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or not vehicle.ad.onRouteToPark or vehicle.ad.isStoppingWithError then
        return
    end
    local ok, distance, place = FarmPilotCall(ADParkButton.distanceToParkPlace, vehicle, wayPointId)
    if not ok then
        ADAutonomousManager.log("ERREUR place de parking du tracteur : %s", tostring(distance))
        return
    end
    if distance == nil or distance > ADParkButton.PARKED_RANGE then
        return -- pas arrivé à sa place (trajet écourté) : rien n'est effacé
    end
    ADAutonomousManager.log("%s : tracteur garé à « %s »", tostring(vehicle.ad.stateModule:getName()), tostring(place))
    ADParkButton.onParked(vehicle)
end

-- ------------------------------------------------------------------------------------------------------------
-- Outil à poser ? (mêmes conditions que la fin de champ)
-- ------------------------------------------------------------------------------------------------------------
function ADParkButton.toolToDrop(vehicle)
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil or vehicle.ad.modes == nil
        or vehicle.ad.modes[AutoDrive.MODE_AUTONOMOUS] == nil then
        return nil, "pas de mode Autonome"
    end
    -- (08/11, sur tous les modes) : tout outil ou remorque attelé directement au tracteur qui a
    -- sa propre place de parking (outil de travail, benne, plateau… ; les masses n'ont pas de place)
    local attached = {}
    if vehicle.getAttachedImplements ~= nil then
        local okA, implements = FarmPilotCall(vehicle.getAttachedImplements, vehicle)
        if okA and type(implements) == "table" then
            for _, impl in ipairs(implements) do
                local o = impl.object
                local park = o ~= nil and o.advd ~= nil and o.advd.parkDestination or -1
                if park ~= nil and park >= 1 and ADGraphManager:getMapMarkerById(park) ~= nil then
                    attached[#attached + 1] = o
                end
            end
        end
    end
    if #attached == 0 then
        return nil, "aucun outil attelé avec sa place de parking"
    end
    if #attached > 1 then
        return nil, "plusieurs outils avec leur place de parking"
    end
    local tool = attached[1]
    local toolPark = tool.advd.parkDestination
    local tractorPark = vehicle.advd ~= nil and vehicle.advd.parkDestination or -1
    if tractorPark == nil or tractorPark < 1 or tractorPark == toolPark or ADGraphManager:getMapMarkerById(tractorPark) == nil then
        return nil, "le tracteur n'a pas de place de parking (à part celle de l'outil)"
    end
    return tool
end

-- ------------------------------------------------------------------------------------------------------------
-- Bouton « Envoyer au parking »
-- ------------------------------------------------------------------------------------------------------------
ADParkButton.originalInput = ADInputManager.input_parkVehicle

function ADInputManager:input_parkVehicle(vehicle, farmId, ...)
    if ADSprayerDump ~= nil and ADSprayerDump.onParkButton(self, vehicle, farmId) then return end -- épandeur / pulvé : vider le reste d'abord, voir AutonomousSprayerDump.lua
    if ADParkUnload ~= nil and ADParkUnload.onParkButton(self, vehicle, farmId) then return end -- benne pas vide : aller la vider d'abord, voir AutonomousParkUnload.lua
    local tool, why = ADParkButton.toolToDrop(vehicle)
    if tool ~= nil then
        local name = tostring(vehicle.ad.stateModule:getName())
        -- comme le bouton d'origine : Courseplay arrêté, FarmPilot arrêté s'il roulait
        AutoDrive:StopCP(vehicle)
        if vehicle.ad.stateModule:isActive() then
            self:input_start_stop(vehicle, farmId)
        end
        ADParkButton.rememberMode(vehicle)
        vehicle.ad.stateModule:setMode(AutoDrive.MODE_AUTONOMOUS)
        ADAutonomousManager.log("%s : bouton parking : l'outil « %s » d'abord à sa place, puis le tracteur à la sienne", name, ADAutonomousManager.toolLabel(tool))
        local ok, started = FarmPilotCall(AutonomousMode.parkWithToolDrop, vehicle, tool)
        if ok and started then
            return
        end
        ADAutonomousManager.log("%s : bouton parking : dépose de l'outil pas lancée (%s), parking comme avant", name, ok and "refusée" or tostring(started))
        ADParkButton.restoreMode(vehicle)
    elseif ADFrontFlow ~= nil and ADFrontFlow.onParkButton(self, vehicle, farmId) then return -- masse à reprendre à la place du tracteur, voir AutonomousFront.lua
    elseif vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
        ADAutonomousManager.log("%s : bouton parking : parking comme avant (%s)", tostring(vehicle.ad.stateModule:getName()), tostring(why))
    end
    return ADParkButton.originalInput(self, vehicle, farmId, ...)
end
