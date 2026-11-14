-- ============================================================================================================
-- FarmPilot : AutonomousHarvesterUnloaders.lua
-- Mode Autonome, moissonneuse ou ensileuse (ébauche 11/11) : ses bennes gardent son champ.
--
-- Règle (11/11) :
-- - Le champ (numéro) de la moissonneuse est aussi celui de ses bennes : les bennes en mode « Décharger
--   moissonneuse » qui ont ce champ en 1re destination la servent (règle d'AutoDrive : même 1re destination).
-- - Une autre moissonneuse ou ensileuse travaille encore l'ancien champ : les bennes y restent (message).
-- - Le champ qu'elle vient de finir est gardé le temps du départ (fpHeaderPrevField) : un changement de barre s'y fait
--   (Modes/AutonomousHeader.lua : startCollect).
--
-- Règle (14/11) : les bennes changent de champ quand la moissonneuse est PRÊTE à recommencer, pas à son départ.
-- - Champ fini et champ suivant prévu : ses bennes ne rentrent pas au parking. Vide, la benne attend à l'ancien
--   champ ; chargée, elle part vider puis revient attendre.
-- - La moissonneuse part (barre reposée, route, barre reprise) : les bennes ne bougent pas, elles ne gênent ni la
--   route ni l'entrée du champ suivant.
-- - Elle a repris le travail au champ suivant : chaque benne passe au nouveau champ (1re destination) et y roule
--   pour attendre l'appel. Celle qui vide finit, puis revient au nouveau champ. Une benne à l'arrêt change
--   seulement de 1re destination.
-- - Elle n'a pas repris au bout de FOLLOW_MAX_TIME, ou son champ a été changé à la main : les bennes ne l'attendent
--   plus.
--
-- Branché par : enveloppes posées au chargement sur AutonomousMode.goToNextField (plan),
-- CombineUnloaderMode:getParkAfterJobMarker (pas de parking tant qu'elle suit), CombineUnloaderMode:onHarvesterJobDone
-- (journal) et ADHarvestManager:update (suivi). Chargé par register.lua après AutonomousHeaderChoice.lua.
-- ============================================================================================================

ADHarvesterUnloaders = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHarvesterUnloaders.FOLLOW_MAX_TIME = 60 * 60 * 1000 -- ms : pas repris le travail au bout de ça, les bennes ne l'attendent plus
ADHarvesterUnloaders.READY_GUARD = 5000               -- ms après la fin du champ avant de regarder si elle a repris le travail (comme COMBINE_RESTART_GUARD)
ADHarvesterUnloaders.RETRY_TIME = 1000                -- ms entre deux essais pour une benne occupée

-- [moissonneuse] = { old = marqueur fini, new = marqueur suivant, crew = { [benne] = true }, since, ready, nextTry }
ADHarvesterUnloaders.pending = {}

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function nameOf(vehicle)
    return ADHeaderFlow.vehicleName(vehicle)
end

local function vehicles()
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    return system ~= nil and system.vehicles or {}
end

local function isGone(vehicle)
    return vehicle == nil or vehicle.isDeleted or vehicle.isDeleting or vehicle.ad == nil or vehicle.ad.stateModule == nil
end

-- ------------------------------------------------------------------------------------------------------------
-- La moissonneuse
-- ------------------------------------------------------------------------------------------------------------
-- une autre machine qui récolte encore ce champ
local function otherHarvesterOn(harvester, marker)
    for _, v in pairs(vehicles()) do
        if v ~= harvester and v.ad ~= nil and v.ad.stateModule ~= nil and ADHeaderFlow.isCombine(v)
            and v.ad.stateModule:getFirstMarker() == marker
            and (v.ad.stateModule:isActive() or v.ad.stateModule:getMode() == AutoDrive.MODE_AUTONOMOUS) then
            return v
        end
    end
    return nil
end

-- le champ suivant prévu (marqueur), ou nil
local function nextFieldOf(harvester)
    local sm = harvester.ad.stateModule
    if sm.getFpNextField == nil or sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS then
        return nil
    end
    local nextField = sm:getFpNextField()
    if nextField == nil or nextField.markerIndex == nil or ADGraphManager:getMapMarkerById(nextField.markerIndex) == nil then
        return nil
    end
    return nextField
end

-- au travail (Courseplay ou l'ouvrier du jeu ; FarmPilot sur la route ne compte pas)
local function isWorking(harvester)
    if ADHarvestManager ~= nil and ADHarvestManager.isCombineDriverWorking ~= nil and AutoDrive.getIsCPActive ~= nil then
        return ADHarvestManager.isCombineDriverWorking(harvester) == true
    end
    if AutoDrive.getIsCPActive ~= nil and AutoDrive:getIsCPActive(harvester) then
        return true
    end
    return harvester.getIsAIActive ~= nil and harvester:getIsAIActive() == true and not harvester.ad.stateModule:isActive()
end

-- ------------------------------------------------------------------------------------------------------------
-- Bennes qui la suivront
-- ------------------------------------------------------------------------------------------------------------
-- true (et la moissonneuse) : cette benne garde son chantier, sa moissonneuse a un champ suivant
function ADHarvesterUnloaders.staysWithHarvester(unloader)
    if isGone(unloader) then
        return false
    end
    for harvester, entry in pairs(ADHarvesterUnloaders.pending) do
        if entry.crew[unloader] then
            return true, harvester
        end
    end
    local marker = unloader.ad.stateModule:getFirstMarker()
    if marker == nil then
        return false
    end
    for _, v in pairs(vehicles()) do
        if v ~= unloader and v.ad ~= nil and v.ad.stateModule ~= nil and ADHeaderFlow.isCombine(v)
            and v.ad.stateModule:getFirstMarker() == marker and nextFieldOf(v) ~= nil then
            return true, v
        end
    end
    return false
end

-- (départ au champ suivant) les bennes de l'ancien champ sont notées : elles suivront quand elle sera prête ;
-- renvoie leur nombre
function ADHarvesterUnloaders.plan(harvester, oldMarker, newMarker)
    local name = nameOf(harvester)
    local before = ADHarvesterUnloaders.pending[harvester]
    local crew, count = {}, 0
    -- repartie avant d'avoir repris le travail : ses bennes d'avant restent les siennes
    if before ~= nil then
        for v in pairs(before.crew) do
            if not isGone(v) and v.ad.stateModule:getMode() == AutoDrive.MODE_UNLOAD and v.ad.stateModule:getFirstMarker() == before.old then
                crew[v] = true
                count = count + 1
            end
        end
    end
    local old = (before ~= nil and count > 0) and before.old or oldMarker
    if old == oldMarker then
        local other = otherHarvesterOn(harvester, oldMarker)
        if other ~= nil then
            ADHarvesterUnloaders.pending[harvester] = nil
            log("%s : « %s » encore récolté par « %s », les bennes y restent", name, tostring(oldMarker.name), nameOf(other))
            AutonomousMode.message(harvester, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_unloadersStay", tostring(oldMarker.name))
            return 0
        end
        for _, v in pairs(vehicles()) do
            local sm = v.ad ~= nil and v.ad.stateModule or nil
            if v ~= harvester and sm ~= nil and not crew[v] and sm:getMode() == AutoDrive.MODE_UNLOAD and sm:getFirstMarker() == oldMarker then
                crew[v] = true
                count = count + 1
            end
        end
    end
    if count == 0 then
        ADHarvesterUnloaders.pending[harvester] = nil
        return 0
    end
    ADHarvesterUnloaders.pending[harvester] = { old = old, new = newMarker, crew = crew, since = g_time, ready = false, nextTry = 0 }
    log("%s : %d benne(s) de « %s » la suivront à « %s » quand elle aura repris le travail", name, count, tostring(old.name), tostring(newMarker.name))
    AutonomousMode.message(harvester, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_unloadersWait", count, tostring(newMarker.name))
    return count
end

-- ------------------------------------------------------------------------------------------------------------
-- La moissonneuse a repris le travail : chaque benne passe au nouveau champ
-- ------------------------------------------------------------------------------------------------------------
-- true = réglé pour cette benne (partie, ou laissée) ; false = occupée, nouvel essai plus tard
local function moveUnloader(harvester, unloader, entry)
    if isGone(unloader) then
        return true
    end
    local sm = unloader.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_UNLOAD or sm:getFirstMarker() ~= entry.old then
        return true -- réglée autrement entre-temps
    end
    local name, field = nameOf(unloader), tostring(entry.new.name)
    local mode = unloader.ad.modes ~= nil and unloader.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or not sm:isActive() then
        sm:setFirstMarker(entry.new.markerIndex)
        log("%s : benne « %s » à l'arrêt, sa 1re destination passe à « %s »", nameOf(harvester), name, field)
        return true
    end
    local state = mode.state
    if state ~= nil and (state == mode.STATE_DRIVE_TO_UNLOAD or state == mode.STATE_EXIT_FIELD or state == mode.STATE_PARK) then
        -- elle finit ce qu'elle fait ; partie vider : elle reviendra au nouveau champ (1re destination)
        sm:setFirstMarker(entry.new.markerIndex)
        if state ~= mode.STATE_PARK then
            unloader.ad.harvestJobDone = nil
        end
        log("%s : benne « %s » %s, puis « %s »", nameOf(harvester), name, state == mode.STATE_PARK and "rentre au parking" or "vide d'abord", field)
        return true
    end
    if state == nil or (state ~= mode.STATE_WAIT_TO_BE_CALLED and state ~= mode.STATE_DRIVE_TO_START) then
        return false -- sous une goulotte, en manœuvre : pas maintenant
    end
    sm:setFirstMarker(entry.new.markerIndex)
    unloader.ad.harvestJobDone = nil
    unloader.ad.taskModule:abortAllTasks()
    if mode.leaveUnloaderQueue ~= nil then
        mode:leaveUnloaderQueue("suit la moissonneuse au champ suivant")
    end
    if ADHarvestManager ~= nil and ADHarvestManager.unregisterAsUnloader ~= nil then
        ADHarvestManager:unregisterAsUnloader(unloader) -- pas d'appel pendant la route
    end
    mode.combine = nil
    mode.followingUnloader = nil
    mode.targetUnloader = nil
    local task = DriveToDestinationTask:new(unloader, entry.new.id)
    if ADDriveGoal ~= nil then
        ADDriveGoal.set(task, "AD_fpGoal_back", entry.new.name)
    end
    mode.state = mode.STATE_DRIVE_TO_START
    mode.activeTask = task
    unloader.ad.taskModule:addTask(task)
    log("%s : benne « %s » part de « %s » vers « %s »", nameOf(harvester), name, tostring(entry.old.name), field)
    return true
end

local function drop(harvester, why)
    local entry = ADHarvesterUnloaders.pending[harvester]
    ADHarvesterUnloaders.pending[harvester] = nil
    if entry ~= nil and why ~= nil then
        log("%s : %s, ses bennes restent à « %s »", isGone(harvester) and "moissonneuse" or nameOf(harvester), why, tostring(entry.old.name))
    end
end

local function updateEntry(harvester, entry)
    if isGone(harvester) then
        drop(harvester, "moissonneuse supprimée")
        return
    end
    local sm = harvester.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS or sm:getFirstMarker() ~= entry.new then
        drop(harvester, "son champ a été changé")
        return
    end
    if g_time - entry.since > ADHarvesterUnloaders.FOLLOW_MAX_TIME then
        drop(harvester, string.format("pas repris le travail en %d min", ADHarvesterUnloaders.FOLLOW_MAX_TIME / 60000))
        return
    end
    if not entry.ready then
        -- même attente que ADHarvestManager (depuis sa fin de champ) : les bennes changent de champ dans la même
        -- image que son « nouveau chantier », juste avant, pour qu'aucune ne soit vue réglée sur un autre champ
        local since = harvester.ad.combineJobSince or entry.since
        if g_time - since < ADHarvesterUnloaders.READY_GUARD or not isWorking(harvester) then
            return
        end
        local other = otherHarvesterOn(harvester, entry.old)
        if other ~= nil then
            ADHarvesterUnloaders.pending[harvester] = nil
            log("%s : « %s » récolté par « %s », les bennes y restent", nameOf(harvester), tostring(entry.old.name), nameOf(other))
            AutonomousMode.message(harvester, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_unloadersStay", tostring(entry.old.name))
            return
        end
        entry.ready = true
        entry.nextTry = 0
        local count = 0
        for _ in pairs(entry.crew) do
            count = count + 1
        end
        log("%s : au travail à « %s », ses %d benne(s) la rejoignent", nameOf(harvester), tostring(entry.new.name), count)
        AutonomousMode.message(harvester, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_unloadersFollow", count, tostring(entry.new.name))
    end
    if g_time < entry.nextTry then
        return
    end
    entry.nextTry = g_time + ADHarvesterUnloaders.RETRY_TIME
    local crew = {}
    for unloader in pairs(entry.crew) do
        crew[#crew + 1] = unloader
    end
    for _, unloader in ipairs(crew) do
        local ok, done = FarmPilotCall(moveUnloader, harvester, unloader, entry)
        if not ok then
            log("ERREUR benne au champ suivant : %s", tostring(done))
            done = true
        end
        if done then
            entry.crew[unloader] = nil
        end
    end
    if next(entry.crew) == nil then
        ADHarvesterUnloaders.pending[harvester] = nil
    end
end

-- (à chaque image, avant ADHarvestManager:update) suivi des moissonneuses parties au champ suivant
function ADHarvesterUnloaders.update(dt)
    if next(ADHarvesterUnloaders.pending) == nil then
        return
    end
    local list = {}
    for harvester in pairs(ADHarvesterUnloaders.pending) do
        list[#list + 1] = harvester
    end
    for _, harvester in ipairs(list) do
        local entry = ADHarvesterUnloaders.pending[harvester]
        if entry ~= nil then
            updateEntry(harvester, entry)
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes (posées au chargement)
-- ------------------------------------------------------------------------------------------------------------
-- départ au champ suivant
local baseGoToNextField = AutonomousMode.goToNextField
function AutonomousMode.goToNextField(vehicle)
    local harvester = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and ADHeaderFlow.isCombine(vehicle)
    local sm = harvester and vehicle.ad.stateModule or nil
    local oldMarker = sm ~= nil and sm:getFirstMarker() or nil
    if harvester then
        vehicle.ad.fpHeaderPrevField = sm:getFirstMarkerId()
    end
    local result = baseGoToNextField(vehicle)
    if harvester then
        vehicle.ad.fpHeaderPrevField = nil
        local newMarker = sm:getFirstMarker()
        if oldMarker ~= nil and newMarker ~= nil and newMarker ~= oldMarker then
            local ok, err = FarmPilotCall(ADHarvesterUnloaders.plan, vehicle, oldMarker, newMarker)
            if not ok then
                log("ERREUR bennes au champ suivant : %s", tostring(err))
            end
        end
    end
    return result
end

-- fin de chantier d'une benne qui suivra sa moissonneuse : pas de parking (vide elle attend au champ, chargée elle
-- vide puis revient), voir CombineUnloaderModeJobDone.lua
if CombineUnloaderMode ~= nil and CombineUnloaderMode.getParkAfterJobMarker ~= nil then
    local baseParkMarker = CombineUnloaderMode.getParkAfterJobMarker
    function CombineUnloaderMode:getParkAfterJobMarker()
        local ok, stays = FarmPilotCall(ADHarvesterUnloaders.staysWithHarvester, self.vehicle)
        if ok and stays then
            return nil
        end
        return baseParkMarker(self)
    end

    local baseJobDone = CombineUnloaderMode.onHarvesterJobDone
    function CombineUnloaderMode:onHarvesterJobDone(harvester)
        if not self.vehicle.ad.harvestJobDone then
            local ok, stays, leader = FarmPilotCall(ADHarvesterUnloaders.staysWithHarvester, self.vehicle)
            if ok and stays then
                log("%s : champ fini, la benne « %s » ne rentre pas, elle la suivra au champ suivant", nameOf(leader), nameOf(self.vehicle))
            end
        end
        return baseJobDone(self, harvester)
    end
end

-- suivi à chaque image, avant le choix des bennes par ADHarvestManager
if ADHarvestManager ~= nil and ADHarvestManager.update ~= nil then
    local baseUpdate = ADHarvestManager.update
    function ADHarvestManager:update(dt)
        local ok, err = FarmPilotCall(ADHarvesterUnloaders.update, dt)
        if not ok then
            ADHarvesterUnloaders.pending = {}
            log("ERREUR suivi des bennes au champ suivant : %s", tostring(err))
        end
        return baseUpdate(self, dt)
    end
end
