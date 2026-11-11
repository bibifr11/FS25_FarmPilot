-- ============================================================================================================
-- FarmPilot : HarvestManagerCombineJob.lua
-- Complément de ADHarvestManager (HarvestManager.lua d'origine AutoDrive : qui appelle quelle benne) : fin de
-- chantier de la MOISSONNEUSE (benne sous la goulotte). Ne concerne pas l'ensileuse (HarvestManagerChopperJob.lua).
--
-- (10/11) La moissonneuse a fini son champ : ses bennes restaient au bord du champ à attendre un appel qui ne
-- venait plus. Comme pour l'ensileuse, chaque benne part vider ce qu'elle porte, puis rentre.
--
-- Règle :
-- - Signal = « champ fini » : Courseplay (onCpFinished) ou l'ouvrier du jeu (travail fini, pas arrêté par le
--   joueur). Un arrêt à la main ne renvoie aucune benne.
-- - Chaque benne de cette moissonneuse (sous la goulotte, suiveuse, garée dans le champ, en route) : chargée, elle
--   part vider puis va à sa place (remorque choisie : la remorque à sa place puis le tracteur à la sienne ; sinon
--   le « P » du véhicule) ; vide, elle y va tout de suite. Sans place réglée : comme pour l'ensileuse
--   (CombineUnloaderModeJobDone.lua).
-- - La benne sous la goulotte prend d'abord le reste de la trémie : elle part quand la goulotte est rentrée ou la
--   trémie vide, au plus tard COMBINE_LAST_LOAD_TIME après la fin.
-- - Une autre moissonneuse travaille encore sur le même point de champ : les bennes restent pour elle.
-- - La moissonneuse reprend le travail (Courseplay, ouvrier du jeu, ou le joueur goulotte sortie) : nouveau
--   chantier, les bennes sont appelées comme d'habitude.
--
-- Branché par : ExternalInterface.lua (onCpFinished et onAIJobFinished : onFieldFinished) et deux lignes dans
-- HarvestManager.lua (ADHarvestManager:update : updateCombineJobs, checkCombineJob).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHarvestManager.COMBINE_LAST_LOAD_TIME = 180000 -- ms : au plus ça pour prendre le reste de la trémie
ADHarvestManager.COMBINE_LAST_LOAD_MIN = 50     -- l : moins dans la trémie = vide
ADHarvestManager.COMBINE_RESTART_GUARD = 5000   -- ms après la fin avant de regarder si elle reprend le travail

-- ------------------------------------------------------------------------------------------------------------
-- La moissonneuse et son conducteur
-- ------------------------------------------------------------------------------------------------------------
-- le véhicule conduit (le tracteur d'une machine traînée)
local function driverOf(harvester)
    if harvester.isTrailedHarvester and harvester.trailingVehicle ~= nil then
        return harvester.trailingVehicle
    end
    return harvester
end

local function fieldMarkerOf(harvester)
    local vehicle = driverOf(harvester)
    if vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
        return vehicle.ad.stateModule:getFirstMarker()
    end
    return nil
end

local function isDrivenByFarmPilot(vehicle)
    return vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:isActive() == true
end

-- au travail par un conducteur automatique (Courseplay ou l'ouvrier du jeu ; FarmPilot sur la route ne compte pas)
function ADHarvestManager.isCombineDriverWorking(vehicle)
    if AutoDrive:getIsCPActive(vehicle) then
        return true
    end
    return vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive() == true and not isDrivenByFarmPilot(vehicle)
end

-- une autre moissonneuse au travail sur le même point de champ
function ADHarvestManager:hasOtherWorkingCombine(harvester)
    local marker = fieldMarkerOf(harvester)
    if marker == nil then
        return false
    end
    for _, other in pairs(self.harvesters) do
        if other ~= harvester and other.ad ~= nil and not other.ad.isChopper and not other.ad.jobDone
            and fieldMarkerOf(other) == marker and ADHarvestManager.isCombineDriverWorking(driverOf(other)) then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Champ fini (accroches dans ExternalInterface.lua)
-- ------------------------------------------------------------------------------------------------------------
-- vehicle : le véhicule dont le conducteur vient de finir son champ
function ADHarvestManager:onFieldFinished(vehicle)
    if g_server == nil or vehicle == nil or self.harvesters == nil or self.idleHarvesters == nil then
        return
    end
    for _, list in ipairs({ self.harvesters, self.idleHarvesters }) do
        for _, harvester in pairs(list) do
            if harvester.ad ~= nil and not harvester.ad.isChopper and not harvester.ad.jobDone
                and (harvester == vehicle or driverOf(harvester) == vehicle) then
                if self:hasOtherWorkingCombine(harvester) then
                    print(string.format("[AD-Chantier] %s: champ fini, une autre moissonneuse travaille encore ici : les bennes restent pour elle", tostring(harvester:getName())))
                else
                    harvester.ad.jobDone = true
                    harvester.ad.combineJobSince = g_time
                    harvester.ad.combineJobTold = {}
                    harvester.ad.combineJobWaitLogged = nil
                    print(string.format("[AD-Chantier] %s: champ fini, ses bennes partent vider ce qu'elles ont, puis rentrent", tostring(harvester:getName())))
                end
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ des bennes (accroche dans ADHarvestManager:update)
-- ------------------------------------------------------------------------------------------------------------
-- la benne de cette moissonneuse est en train de prendre (ou vient prendre) le reste de la trémie
function ADHarvestManager:isTakingLastLoad(harvester, vehicle, unloader)
    local mode = unloader.ad ~= nil and unloader.ad.modes ~= nil and unloader.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or mode.combine ~= harvester or unloader.ad.harvestJobDone then
        return false
    end
    -- la moissonneuse part (champ suivant, parking) : il n'y a plus rien à prendre
    if isDrivenByFarmPilot(vehicle) or not AutoDrive.isPipeOut(vehicle) then
        return false
    end
    local level = AutoDrive.getObjectFillLevels(harvester)
    if (level or 0) < ADHarvestManager.COMBINE_LAST_LOAD_MIN then
        return false
    end
    local _, _, filledToUnload = AutoDrive.getAllFillLevels(AutoDrive.getAllUnits(unloader))
    return not filledToUnload
end

-- les bennes de cette moissonneuse : celles qui travaillent pour elle et celles réglées sur le même point de champ
function ADHarvestManager:getCombineUnloaders(harvester)
    local list = {}
    local marker = fieldMarkerOf(harvester)
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}
    for _, v in pairs(vehicles) do
        local mode = v.ad ~= nil and v.ad.modes ~= nil and v.ad.modes[AutoDrive.MODE_UNLOAD] or nil
        if mode ~= nil and v.ad.stateModule ~= nil and v.ad.stateModule:isActive() and v.ad.stateModule:getMode() == AutoDrive.MODE_UNLOAD
            and (mode.combine == harvester or (marker ~= nil and v.ad.stateModule:getFirstMarker() == marker)) then
            list[#list + 1] = v
        end
    end
    return list
end

-- la benne part vider puis rentre ; déjà partie vider : elle finit sa livraison, puis rentre au lieu de revenir
function ADHarvestManager:sendCombineUnloaderHome(harvester, unloader)
    local mode = unloader.ad.modes[AutoDrive.MODE_UNLOAD]
    if mode.state ~= nil and (mode.state == mode.STATE_DRIVE_TO_UNLOAD or mode.state == mode.STATE_EXIT_FIELD) then
        if not unloader.ad.harvestJobDone then
            unloader.ad.harvestJobDone = true
            print(string.format("[AD-Chantier] %s: chantier termine, deja partie vider : je finis, puis je rentre", tostring(unloader:getName())))
        end
        return
    end
    if mode.onHarvesterJobDone ~= nil then
        mode:onHarvesterJobDone(harvester)
    end
end

-- (accroche dans ADHarvestManager:update, après celle de l'ensileuse) champ fini : la moissonneuse n'appelle plus de
-- benne tant qu'elle n'a pas repris le travail (updateCombineJob), même si son conducteur est encore vu actif un instant
function ADHarvestManager:checkCombineJob(harvester, driverStopped)
    if harvester.ad ~= nil and harvester.ad.combineJobSince ~= nil then
        harvester.ad.jobDone = true
        return true
    end
    return driverStopped
end

function ADHarvestManager:updateCombineJobs()
    for _, harvester in pairs(self.harvesters) do
        if harvester.ad ~= nil and harvester.ad.combineJobSince ~= nil then
            self:updateCombineJob(harvester, driverOf(harvester))
        end
    end
    for _, harvester in pairs(self.idleHarvesters) do
        if harvester.ad ~= nil and harvester.ad.combineJobSince ~= nil then
            self:updateCombineJob(harvester, driverOf(harvester))
        end
    end
end

function ADHarvestManager:updateCombineJob(harvester, vehicle)
    local ad = harvester.ad
    local elapsed = g_time - ad.combineJobSince
    if elapsed >= ADHarvestManager.COMBINE_RESTART_GUARD then
        -- le joueur goulotte sortie : seulement une fois les bennes parties (assis dedans à la fin, il ne les retient pas)
        local byPlayer = ad.combineJobTold == nil and AutoDrive:getIsEntered(vehicle:getRootVehicle()) and AutoDrive.isPipeOut(vehicle)
        if ADHarvestManager.isCombineDriverWorking(vehicle) or byPlayer then
            ad.jobDone = nil
            ad.combineJobSince = nil
            ad.combineJobTold = nil
            ad.combineJobWaitLogged = nil
            print(string.format("[AD-Chantier] %s: la moissonneuse reprend le travail, nouveau chantier", tostring(harvester:getName())))
            return
        end
    end
    if ad.combineJobTold == nil then
        return
    end
    local waiting = false
    for _, unloader in ipairs(self:getCombineUnloaders(harvester)) do
        if not ad.combineJobTold[unloader] then
            if elapsed < ADHarvestManager.COMBINE_LAST_LOAD_TIME and self:isTakingLastLoad(harvester, vehicle, unloader) then
                waiting = true
                if not ad.combineJobWaitLogged then
                    ad.combineJobWaitLogged = true
                    print(string.format("[AD-Chantier] %s: %s prend d'abord le reste de la tremie (%d s au plus)", tostring(harvester:getName()), tostring(unloader:getName()), ADHarvestManager.COMBINE_LAST_LOAD_TIME / 1000))
                end
            else
                ad.combineJobTold[unloader] = true
                self:sendCombineUnloaderHome(harvester, unloader)
            end
        end
    end
    if not waiting then
        ad.combineJobTold = nil
    end
end
