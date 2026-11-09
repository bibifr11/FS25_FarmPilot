-- ============================================================================================================
-- FarmPilot : HarvestManagerChopperJob.lua
-- Complément de ADHarvestManager (HarvestManager.lua d'origine AutoDrive : qui appelle quelle benne) : le
-- conducteur de l'ENSILEUSE (benne qui roule à côté). Ne concerne pas la moissonneuse.
--
-- - Son conducteur (Courseplay) s'arrête un moment de temps en temps : les bennes gardent leur place, la file et
--   la benne attelée, et attendent ; seul un long arrêt (CHOPPER_DRIVER_STOP_TIME) les libère comme avant.
-- - (26/10) quand l'ensileuse a terminé, signal de renvoi au tracteur pour vider ; celles qui sont vides et
--   reviennent vont au garage : Courseplay arrêté CHOPPER_JOB_DONE_TIME = chantier
--   terminé, chaque benne de cette ensileuse part vider puis au parking (CombineUnloaderModeJobDone.lua).
-- - 27/10 06:49 (log « chantier termine, 0 benne(s) » pour une JAGUAR qu'AutoDrive venait de garer, Courseplay
--   jamais lancé dans la partie) : seule une ensileuse sur laquelle Courseplay a été vu au travail peut finir son
--   chantier ; avant, les bennes attendent comme avant.
-- - Chantier terminé et l'ensileuse conduite ailleurs (AutoDrive ou le joueur) : aucune benne n'est appelée.
--
-- Branché par une ligne dans HarvestManager.lua (ADHarvestManager:update) ; la condition « chantier terminé »
-- du renvoi de la benne attelée (fireUnloader) est restée dans update.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHarvestManager.CHOPPER_DRIVER_STOP_TIME = 300000 -- ms, forage harvester driver stopped longer: unloaders released
-- (26/10) once the forage harvester has finished, its unloaders are sent off to unload; the empty ones coming
-- back go to the garage. Courseplay off the forage harvester this long = its job is done. Every unloader
-- of this harvester (attached, follower, waiting in the field or on its way) leaves to unload whatever it carries,
-- then drives to its AutoDrive park destination; an empty one goes to park at once
ADHarvestManager.CHOPPER_JOB_DONE_TIME = 20000 -- ms

-- ------------------------------------------------------------------------------------------------------------
-- Conducteur arrêté, fin de chantier (accroche dans update) : renvoie driverStopped
-- ------------------------------------------------------------------------------------------------------------
function ADHarvestManager:checkChopperDriver(harvester, vehicle, driverStopped)
    if driverStopped and harvester.ad ~= nil and harvester.ad.isChopper and not (vehicle.ad.onRouteToRefuel or vehicle.ad.onRouteToRepair) then
        -- forage harvester: its driver (Courseplay) stops for a moment now and then. The unloaders keep their place,
        -- the queue and the attached unloader, and wait; only a long stop releases them as before
        harvester.ad.driverStoppedSince = harvester.ad.driverStoppedSince or g_time
        -- 26/10 17:58: Courseplay off for CHOPPER_JOB_DONE_TIME = job done, the unloaders leave to unload and park.
        -- 27/10 06:49 (log: "chantier termine, 0 benne(s)" for a JAGUAR that AutoDrive had just parked, Courseplay never
        -- started in this session): only a harvester Courseplay has been seen working on can finish its job; before
        -- that, the unloaders keep waiting as before
        if not harvester.ad.jobDone and harvester.ad.cpSeenActive and g_time - harvester.ad.driverStoppedSince >= ADHarvestManager.CHOPPER_JOB_DONE_TIME
            and not AutoDrive:getIsCPActive(vehicle) and not AutoDrive:getIsEntered(vehicle:getRootVehicle()) then
            self:onChopperJobDone(harvester, vehicle)
        end
        if g_time - harvester.ad.driverStoppedSince < ADHarvestManager.CHOPPER_DRIVER_STOP_TIME and not harvester.ad.jobDone then
            if not harvester.ad.driverStopLogged then
                harvester.ad.driverStopLogged = true
                print(string.format("[AD-File] %s: conducteur arrete, les bennes gardent leur place et attendent (%d min max)", tostring(harvester:getName()), ADHarvestManager.CHOPPER_DRIVER_STOP_TIME / 60000))
            end
            driverStopped = false
        end
    elseif harvester.ad ~= nil then
        harvester.ad.driverStoppedSince = nil
        harvester.ad.driverStopLogged = false
        if AutoDrive:getIsCPActive(vehicle) and not harvester.ad.cpSeenActive then
            harvester.ad.cpSeenActive = true
            print(string.format("[AD-Chantier] %s: Courseplay au travail, fin de chantier surveillee", tostring(harvester:getName())))
        end
        if harvester.ad.jobDone and AutoDrive:getIsCPActive(vehicle) then
            print(string.format("[AD-Chantier] %s: Courseplay repart, nouveau chantier", tostring(harvester:getName())))
            harvester.ad.jobDone = nil
        end
    end
    -- job done and AutoDrive (or the player) drives the harvester away: no unloader is called for it
    if harvester.ad ~= nil and harvester.ad.jobDone and not AutoDrive:getIsCPActive(vehicle) then
        driverStopped = true
    end
    return driverStopped
end

-- ------------------------------------------------------------------------------------------------------------
-- Les bennes de l'ensileuse et la fin de chantier
-- ------------------------------------------------------------------------------------------------------------
-- the unloaders of a harvester: attached, followers and the ones waiting for its call (same field target)
function ADHarvestManager:getUnloadersOf(harvester)
    local list = {}
    local target = harvester.ad ~= nil and harvester.ad.stateModule ~= nil and harvester.ad.stateModule:getFirstMarker() or nil
    local function add(v)
        if v ~= nil and v.ad ~= nil and v.ad.stateModule ~= nil and v.ad.stateModule:isActive() and v.ad.stateModule:getMode() == AutoDrive.MODE_UNLOAD and not table.contains(list, v) then
            table.insert(list, v)
        end
    end
    for _, v in pairs(self.activeUnloaders) do
        local mode = v.ad ~= nil and v.ad.modes ~= nil and v.ad.modes[AutoDrive.MODE_UNLOAD] or nil
        if mode ~= nil and (mode.combine == harvester or (target ~= nil and v.ad.stateModule:getFirstMarker() == target)) then
            add(v)
        end
    end
    for _, v in pairs(self.idleUnloaders) do
        if target ~= nil and v.ad ~= nil and v.ad.stateModule ~= nil and v.ad.stateModule:getFirstMarker() == target then
            add(v)
        end
    end
    -- followers and unloaders on their way to a follower
    if g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil then
        for _, v in pairs(g_currentMission.vehicleSystem.vehicles) do
            local mode = v.ad ~= nil and v.ad.modes ~= nil and v.ad.modes[AutoDrive.MODE_UNLOAD] or nil
            if mode ~= nil and v.ad.stateModule ~= nil and v.ad.stateModule:isActive() and v.ad.stateModule:getMode() == AutoDrive.MODE_UNLOAD
                and (mode.combine == harvester or (target ~= nil and v.ad.stateModule:getFirstMarker() == target)) then
                add(v)
            end
        end
    end
    return list
end

-- the forage harvester's job is done: its unloaders leave to unload, then to park
function ADHarvestManager:onChopperJobDone(harvester, vehicle)
    harvester.ad.jobDone = true
    local list = self:getUnloadersOf(harvester)
    print(string.format("[AD-Chantier] %s: chantier termine (Courseplay arrete depuis %d s), %d benne(s) : elles partent vider ce qu'elles ont, puis au parking", tostring(harvester:getName()), ADHarvestManager.CHOPPER_JOB_DONE_TIME / 1000, #list))
    for _, v in ipairs(list) do
        local mode = v.ad.modes[AutoDrive.MODE_UNLOAD]
        if mode.onHarvesterJobDone ~= nil then
            mode:onHarvesterJobDone(harvester)
        end
    end
end
