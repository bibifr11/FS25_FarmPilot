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
-- Règle (15/11) : aucune benne au changement de champ (toutes au garage) : son équipe de la session d'avant revient.
-- - Équipe de la moissonneuse, et de l'ensileuse depuis le 16/11 (voir plus bas) : les tracteurs en mode
--   « Décharger moissonneuse » qui l'ont servie (même 1re destination, ou servant cette machine), notés pendant
--   qu'elle travaille et à son départ, avec leur remorque choisie (ligne « Remorque ») et leur parking. Un tracteur
--   n'est que dans une équipe. Gardée dans la sauvegarde de la machine (#fpUnloaderTeam, identifiants uniques des
--   véhicules).
-- - Elle a repris le travail au champ suivant (même moment que plus haut) et aucune benne n'est pour ce champ (aucun
--   tracteur actif en « Décharger moissonneuse » vers ce champ ou vers elle, aucune de ses bennes en route) : chaque
--   tracteur de son équipe à l'arrêt, et chaque benne notée à l'arrêt, repasse en « Décharger moissonneuse », 1re
--   destination = le nouveau champ, même remorque (allée chercher au départ, TrailerHitch.lua) et même parking,
--   puis AutoDrive démarre. Pas avant : ils gêneraient la moissonneuse qui reprend sa coupe.
-- - Jamais repris : tracteur conduit par le joueur, actif (AutoDrive, Courseplay, ouvrier), avec un autre outil
--   attelé (sa benne ou une masse seulement), sans benne à atteler, sans destination de déchargement.
-- - Équipe vide (première fois) : comme avant.
--
-- Règle (16/11) : l'ensileuse a la même équipe et le même rappel que la moissonneuse.
-- - Ses bennes (attelée à côté d'elle, suiveuse, en attente, même 1re destination) sont notées comme celles de la
--   moissonneuse ; entre deux champs elles rentrent au garage, elles sont rappelées au champ suivant quand elle a
--   repris le travail (Courseplay ou l'ouvrier du jeu, jamais pendant la route ni à l'arrivée avant le travail).
-- - Remorque posée à sa place à la fin de son chantier (TrailerHitch.lua) : rappelée avec la même remorque, allée
--   chercher au départ, comme pour la moissonneuse.
-- - Champ suivant prévu : quand elle part, ADHarvestManager arrête sur place sa benne attelée et la suiveuse (1re
--   destination plus la même : fireUnloader). Notées ; quand elle a repris le travail elles repartent (vider si
--   pleines) puis la rejoignent comme ses autres bennes. Conduite par le joueur : laissée à l'arrêt.
-- - La conduite des bennes d'ensileuse (CombineUnloaderModeChopperChase.lua, etc.) ne change pas.
--
-- Branché par : enveloppes posées au chargement sur AutonomousMode.goToNextField (plan),
-- CombineUnloaderMode:getParkAfterJobMarker (pas de parking tant qu'elle suit), CombineUnloaderMode:onHarvesterJobDone
-- (journal), ADHarvestManager:update (suivi), ADHarvestManager:fireUnloader (16/11, bennes d'ensileuse arrêtées au
-- départ) et ADSavegameResume.save / .load (équipe dans la sauvegarde ; clé #fpUnloaderTeam déclarée dans
-- Specialization.lua). Chargé par register.lua après AutonomousHeaderChoice.lua.
-- ============================================================================================================

ADHarvesterUnloaders = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHarvesterUnloaders.FOLLOW_MAX_TIME = 60 * 60 * 1000 -- ms : pas repris le travail au bout de ça, les bennes ne l'attendent plus
ADHarvesterUnloaders.READY_GUARD = 5000               -- ms après la fin du champ avant de regarder si elle a repris le travail (comme COMBINE_RESTART_GUARD)
ADHarvesterUnloaders.RETRY_TIME = 1000                -- ms entre deux essais pour une benne occupée
ADHarvesterUnloaders.TEAM_SCAN_TIME = 5000            -- ms entre deux relevés de l'équipe des moissonneuses au travail (15/11)

-- [moissonneuse] = { old = marqueur fini, new = marqueur suivant, crew = { [benne] = true }, since, ready, nextTry,
-- fired = { [benne] = true } (16/11, arrêtées au départ par ADHarvestManager) }
ADHarvesterUnloaders.pending = {}
-- (15/11) [moissonneuse] = { new = marqueur suivant, since } : partie sans benne qui la suit, son équipe est rappelée
-- quand elle a repris le travail
ADHarvesterUnloaders.recallWatch = {}
ADHarvesterUnloaders.nextTeamScan = 0

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
-- (15/11) Son équipe de bennes, gardée dans la sauvegarde
-- ------------------------------------------------------------------------------------------------------------
-- ensileuse (sans trémie)
local function isChopper(v)
    return v.ad ~= nil and v.ad.isChopper == true or (v.spec_combine ~= nil and v.spec_combine.isBufferCombine == true)
end

-- (16/11) moissonneuse ou ensileuse : même équipe, même rappel
local function isTeamHarvester(v)
    return not isGone(v) and ADHeaderFlow.isCombine(v)
end

local function kindOf(harvester)
    return isChopper(harvester) and "ensileuse" or "moissonneuse"
end

-- identifiant stable du véhicule (le même d'une partie à l'autre), ou nil
local function uidOf(v)
    if v == nil or v.getUniqueId == nil then
        return nil
    end
    local ok, id = FarmPilotCall(v.getUniqueId, v)
    if ok and id ~= nil and id ~= "" then
        return tostring(id)
    end
    return nil
end

local function byUid(uid)
    if uid == nil or uid == "" then
        return nil
    end
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system ~= nil and system.getVehicleByUniqueId ~= nil then
        local ok, v = FarmPilotCall(system.getVehicleByUniqueId, system, uid)
        if ok and v ~= nil then
            return v
        end
    end
    for _, v in pairs(vehicles()) do
        if uidOf(v) == uid then
            return v
        end
    end
    return nil
end

local function unloadModeOf(v)
    return v.ad.modes ~= nil and v.ad.modes[AutoDrive.MODE_UNLOAD] or nil
end

-- réglages du tracteur à garder : remorque choisie (nil = celle attelée) et parking
local function settingsOf(v)
    local sm = v.ad.stateModule
    local trailer = sm.getFpTrailer ~= nil and sm:getFpTrailer() or nil
    local park = sm.getParkDestinationAtJobFinished ~= nil and sm:getParkDestinationAtJobFinished() or nil
    return {
        trailer = uidOf(trailer) or sm.fpTrailerUniqueId,
        park = (park ~= nil and park >= 1) and park or nil
    }
end

-- [uid] = { trailer = uid ou nil, park = n° de marqueur ou nil }
function ADHarvesterUnloaders.getTeam(harvester)
    return harvester ~= nil and harvester.ad ~= nil and harvester.ad.fpUnloaderTeam or nil
end

-- note les tracteurs actifs en « Décharger moissonneuse » qui la servent (marker : son champ) ; un tracteur n'est
-- que dans une équipe
function ADHarvesterUnloaders.rememberTeam(harvester, marker)
    if not isTeamHarvester(harvester) then
        return 0
    end
    local count = 0
    for _, v in pairs(vehicles()) do
        local sm = v.ad ~= nil and v.ad.stateModule or nil
        local mode = sm ~= nil and unloadModeOf(v) or nil
        if v ~= harvester and mode ~= nil and not ADHeaderFlow.isCombine(v) and sm:getMode() == AutoDrive.MODE_UNLOAD and sm:isActive()
            and (mode.combine == harvester or (mode.combine == nil and marker ~= nil and sm:getFirstMarker() == marker)) then
            local uid = uidOf(v)
            if uid ~= nil then
                for _, other in pairs(vehicles()) do
                    local team = other ~= harvester and ADHarvesterUnloaders.getTeam(other) or nil
                    if team ~= nil then
                        team[uid] = nil
                    end
                end
                harvester.ad.fpUnloaderTeam = harvester.ad.fpUnloaderTeam or {}
                if harvester.ad.fpUnloaderTeam[uid] == nil then
                    log("%s : « %s » noté dans son équipe de bennes", nameOf(harvester), nameOf(v))
                end
                harvester.ad.fpUnloaderTeam[uid] = settingsOf(v)
                count = count + 1
            end
        end
    end
    return count
end

-- relevé régulier : les moissonneuses au travail notent leurs bennes
local function scanTeams()
    if g_time < ADHarvesterUnloaders.nextTeamScan then
        return
    end
    ADHarvesterUnloaders.nextTeamScan = g_time + ADHarvesterUnloaders.TEAM_SCAN_TIME
    for _, v in pairs(vehicles()) do
        if isTeamHarvester(v) and isWorking(v) then
            ADHarvesterUnloaders.rememberTeam(v, v.ad.stateModule:getFirstMarker())
        end
    end
end

-- sauvegarde : « uid|remorque|parking;… »
function ADHarvesterUnloaders.teamToString(team)
    if team == nil then
        return nil
    end
    local uids = {}
    for uid in pairs(team) do
        uids[#uids + 1] = uid
    end
    table.sort(uids)
    local parts = {}
    for _, uid in ipairs(uids) do
        local memo = team[uid]
        parts[#parts + 1] = string.format("%s|%s|%s", uid, memo.trailer or "", memo.park ~= nil and tostring(memo.park) or "")
    end
    return #parts > 0 and table.concat(parts, ";") or nil
end

function ADHarvesterUnloaders.teamFromString(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local team, count = {}, 0
    for part in string.gmatch(text, "[^;]+") do
        local uid, trailer, park = string.match(part, "^([^|]*)|([^|]*)|([^|]*)$")
        if uid ~= nil and uid ~= "" then
            team[uid] = { trailer = trailer ~= "" and trailer or nil, park = tonumber(park) }
            count = count + 1
        end
    end
    return count > 0 and team or nil
end

-- ------------------------------------------------------------------------------------------------------------
-- (15/11) Rappel de l'équipe quand elle a repris le travail sans benne
-- ------------------------------------------------------------------------------------------------------------
-- une benne est déjà pour ce champ : tracteur actif en « Décharger moissonneuse » vers ce champ ou vers elle, ou une
-- de ses bennes notées encore en route
local function hasUnloaderFor(harvester, marker, entry)
    for _, v in pairs(vehicles()) do
        local sm = v.ad ~= nil and v.ad.stateModule or nil
        if v ~= harvester and sm ~= nil and sm:getMode() == AutoDrive.MODE_UNLOAD and sm:isActive() then
            local mode = unloadModeOf(v)
            if sm:getFirstMarker() == marker or (mode ~= nil and mode.combine == harvester)
                or (entry ~= nil and entry.crew[v] and sm:getFirstMarker() == entry.old) then
                return true
            end
        end
    end
    return false
end

-- un outil attelé qui n'est ni sa benne ni une masse ; sinon false et la benne attelée
local function otherToolOf(tractor, wanted)
    local list = ADTrailerHitch ~= nil and ADTrailerHitch.attachedTrailers(tractor) or {}
    local own = nil
    for _, o in ipairs(list) do
        if own == nil and ADTrailerHitch.isTrailerObject(o) and (wanted == nil or o == wanted) then
            own = o
        else
            return true
        end
    end
    return false, own
end

-- nil = repris ; sinon la raison
local function recallOne(harvester, tractor, memo, marker)
    local sm = tractor.ad.stateModule
    local mode = unloadModeOf(tractor)
    if mode == nil then
        return "pas de mode « Décharger moissonneuse »"
    end
    if AutoDrive.getIsEntered ~= nil and AutoDrive:getIsEntered(tractor:getRootVehicle()) then
        return "conduit par le joueur"
    end
    if sm:isActive() or (AutoDrive.getIsCPActive ~= nil and AutoDrive:getIsCPActive(tractor))
        or (tractor.getIsAIActive ~= nil and tractor:getIsAIActive()) then
        return "au travail ailleurs"
    end
    local wanted = memo.trailer ~= nil and byUid(memo.trailer) or nil
    local other, own = otherToolOf(tractor, wanted)
    if other then
        return "un autre outil est attelé"
    end
    if wanted ~= nil and own == nil then
        local attacher = wanted.getAttacherVehicle ~= nil and wanted:getAttacherVehicle() or nil
        if attacher ~= nil then
            return "sa remorque est attelée à un autre véhicule"
        end
    end
    if wanted == nil and own == nil then
        return "pas de benne à atteler"
    end
    if sm:getSecondMarker() == nil then
        return "pas de destination de déchargement"
    end
    tractor.ad.fpModeBeforePark = nil -- (15/11) le mode d'avant une dépose ne revient plus à l'arrêt
    sm:setMode(AutoDrive.MODE_UNLOAD)
    if sm:getMode() ~= AutoDrive.MODE_UNLOAD then
        return "mode refusé"
    end
    sm:setFirstMarker(marker.markerIndex)
    if sm.setFpTrailer ~= nil and sm:getFpTrailer() ~= wanted then
        sm:setFpTrailer(wanted) -- même remorque qu'avant (nil = celle attelée)
    end
    if memo.park ~= nil and sm.setParkDestinationAtJobFinished ~= nil and ADGraphManager:getMapMarkerById(memo.park) ~= nil then
        sm:setParkDestinationAtJobFinished(memo.park)
    end
    tractor.ad.harvestJobDone = nil
    tractor.ad.workingForChopper = nil -- (16/11) ensileuse ou moissonneuse : revu d'après la machine du nouveau champ
    mode:start(AutoDrive.USER_PLAYER)
    if not sm:isActive() then
        return "départ refusé"
    end
    print(string.format("[AD-Chantier] %s: equipe de %s (%s), rappele vers %s (remorque %s)", tostring(tractor:getName()), tostring(harvester:getName()),
        kindOf(harvester), tostring(marker.name), ((wanted or own) ~= nil and ADTrailerHitch ~= nil) and ADTrailerHitch.label(wanted or own) or "?"))
    return nil
end

-- elle a repris le travail à marker sans benne : son équipe à l'arrêt (et ses bennes notées à l'arrêt) y part ;
-- exclude = bennes à laisser ; renvoie le nombre de tracteurs repris
function ADHarvesterUnloaders.recallTeam(harvester, marker, entry, exclude)
    if not isTeamHarvester(harvester) or marker == nil then
        return 0
    end
    local team = ADHarvesterUnloaders.getTeam(harvester)
    if team == nil or next(team) == nil then
        return 0 -- première fois : comme avant
    end
    if hasUnloaderFor(harvester, marker, entry) then
        return 0
    end
    local list, seen = {}, {}
    for uid, memo in pairs(team) do
        local v = byUid(uid)
        if v == nil then
            team[uid] = nil -- vendu
        elseif not isGone(v) and v ~= harvester and not seen[v] and not (exclude ~= nil and exclude[v]) then
            seen[v] = true
            list[#list + 1] = { vehicle = v, memo = memo }
        end
    end
    if entry ~= nil then
        for v in pairs(entry.crew) do
            if not isGone(v) and not seen[v] and not v.ad.stateModule:isActive() and v.ad.stateModule:getMode() == AutoDrive.MODE_UNLOAD then
                seen[v] = true
                list[#list + 1] = { vehicle = v, memo = settingsOf(v) }
            end
        end
    end
    table.sort(list, function(a, b) return nameOf(a.vehicle) < nameOf(b.vehicle) end)
    local count = 0
    for _, item in ipairs(list) do
        local ok, why = FarmPilotCall(recallOne, harvester, item.vehicle, item.memo, marker)
        if not ok then
            log("ERREUR rappel de « %s » : %s", nameOf(item.vehicle), tostring(why))
        elseif why ~= nil then
            log("%s : « %s » pas rappelé (%s)", nameOf(harvester), nameOf(item.vehicle), why)
        else
            count = count + 1
            log("%s : aucune benne à « %s », « %s » de son équipe rappelé", nameOf(harvester), tostring(marker.name), nameOf(item.vehicle))
        end
    end
    if count > 0 then
        AutonomousMode.message(harvester, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_unloadersRecall", count, tostring(marker.name))
    end
    return count
end

-- ------------------------------------------------------------------------------------------------------------
-- (16/11) Bennes de l'ensileuse arrêtées sur place à son départ
-- ------------------------------------------------------------------------------------------------------------
-- (crochet de ADHarvestManager:fireUnloader) sa 1re destination a changé : la benne attelée et sa suiveuse sont
-- arrêtées sur place ; une benne qui la suivra est notée pour repartir quand elle aura repris le travail
function ADHarvesterUnloaders.noteFired(unloader, harvester)
    if isGone(unloader) then
        return
    end
    local entry = harvester ~= nil and ADHarvesterUnloaders.pending[harvester] or nil
    if entry == nil or not entry.crew[unloader] then
        local _, leader = ADHarvesterUnloaders.staysWithHarvester(unloader)
        entry = leader ~= nil and ADHarvesterUnloaders.pending[leader] or nil
        harvester = leader
    end
    if entry == nil then
        return
    end
    local mode = unloadModeOf(unloader)
    local follower = mode ~= nil and mode.getFollowingUnloader ~= nil and mode:getFollowingUnloader() or nil
    for _, v in ipairs({ unloader, follower }) do
        if v ~= nil and entry.crew[v] and not (entry.fired ~= nil and entry.fired[v]) then
            entry.fired = entry.fired or {}
            entry.fired[v] = true
            log("%s : partie vers « %s », benne « %s » arrêtée sur place, elle repartira quand elle aura repris le travail",
                nameOf(harvester), tostring(entry.new.name), nameOf(v))
        end
    end
end

-- elle a repris le travail : ses bennes arrêtées à son départ redémarrent (1re destination encore l'ancien champ :
-- moveUnloader les envoie ensuite au nouveau, comme ses bennes qui attendaient) ; renvoie leur nombre
local function restartFired(harvester, entry)
    local fired = entry.fired
    entry.fired = nil
    if fired == nil then
        return 0
    end
    local count = 0
    for v in pairs(fired) do
        local sm = not isGone(v) and v.ad.stateModule or nil
        local mode = sm ~= nil and unloadModeOf(v) or nil
        if entry.crew[v] and mode ~= nil and not sm:isActive() and sm:getMode() == AutoDrive.MODE_UNLOAD and sm:getFirstMarker() == entry.old then
            local why = nil
            if AutoDrive.getIsEntered ~= nil and AutoDrive:getIsEntered(v:getRootVehicle()) then
                why = "conduite par le joueur"
            elseif (AutoDrive.getIsCPActive ~= nil and AutoDrive:getIsCPActive(v)) or (v.getIsAIActive ~= nil and v:getIsAIActive()) then
                why = "au travail ailleurs"
            else
                v.ad.harvestJobDone = nil
                local ok, err = FarmPilotCall(mode.start, mode, AutoDrive.USER_PLAYER)
                if not ok then
                    why = "ERREUR " .. tostring(err)
                elseif not sm:isActive() then
                    why = "départ refusé"
                end
            end
            if why ~= nil then
                log("%s : benne « %s » arrêtée à son départ, pas redémarrée (%s)", nameOf(harvester), nameOf(v), why)
            else
                count = count + 1
                print(string.format("[AD-Chantier] %s: arretee au depart de %s (%s), redemarre pour %s", tostring(v:getName()), tostring(harvester:getName()),
                    kindOf(harvester), tostring(entry.new.name)))
            end
        end
    end
    return count
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
            restartFired(harvester, entry) -- (16/11) ses bennes arrêtées à son départ reprennent là-bas, pour l'autre machine
            log("%s : « %s » récolté par « %s », les bennes y restent", nameOf(harvester), tostring(entry.old.name), nameOf(other))
            AutonomousMode.message(harvester, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_unloadersStay", tostring(entry.old.name))
            ADHarvesterUnloaders.recallTeam(harvester, entry.new, nil, entry.crew) -- (15/11) son équipe à l'arrêt, sans ces bennes-là
            return
        end
        entry.ready = true
        entry.nextTry = 0
        restartFired(harvester, entry) -- (16/11) d'abord ses bennes arrêtées à son départ : elles la suivent, l'équipe n'est pas rappelée
        local count = 0
        for _ in pairs(entry.crew) do
            count = count + 1
        end
        -- (15/11) aucune benne pour le nouveau champ : son équipe et ses bennes à l'arrêt repartent (les bennes reprises
        -- ont alors le nouveau champ en 1re destination, moveUnloader les laisse)
        local recalled = ADHarvesterUnloaders.recallTeam(harvester, entry.new, entry, nil)
        if recalled == 0 then
            log("%s : au travail à « %s », ses %d benne(s) la rejoignent", nameOf(harvester), tostring(entry.new.name), count)
            AutonomousMode.message(harvester, ADMessagesManager.messageTypes.INFO, 8000, "AD_autonomous_unloadersFollow", count, tostring(entry.new.name))
        end
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

-- (15/11) partie sans benne qui la suit : quand elle a repris le travail, son équipe est rappelée
local function updateWatch(harvester, watch)
    ADHarvesterUnloaders.recallWatch[harvester] = nil
    if isGone(harvester) or ADHarvesterUnloaders.pending[harvester] ~= nil then
        return
    end
    local sm = harvester.ad.stateModule
    if sm:getMode() ~= AutoDrive.MODE_AUTONOMOUS or sm:getFirstMarker() ~= watch.new then
        return -- son champ a été changé
    end
    if g_time - watch.since > ADHarvesterUnloaders.FOLLOW_MAX_TIME then
        log("%s : pas repris le travail en %d min, son équipe n'est pas rappelée", nameOf(harvester), ADHarvesterUnloaders.FOLLOW_MAX_TIME / 60000)
        return
    end
    local since = harvester.ad.combineJobSince or watch.since
    if g_time - since < ADHarvesterUnloaders.READY_GUARD or not isWorking(harvester) then
        ADHarvesterUnloaders.recallWatch[harvester] = watch -- pas encore au travail : on attend
        return
    end
    ADHarvesterUnloaders.recallTeam(harvester, watch.new, nil, nil)
end

-- (à chaque image, avant ADHarvestManager:update) suivi des moissonneuses parties au champ suivant
function ADHarvesterUnloaders.update(dt)
    scanTeams() -- (15/11) équipe de chaque moissonneuse au travail
    if next(ADHarvesterUnloaders.recallWatch) ~= nil then
        local watched = {}
        for harvester, watch in pairs(ADHarvesterUnloaders.recallWatch) do
            watched[#watched + 1] = { harvester = harvester, watch = watch }
        end
        for _, w in ipairs(watched) do
            updateWatch(w.harvester, w.watch)
        end
    end
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
        FarmPilotCall(ADHarvesterUnloaders.rememberTeam, vehicle, oldMarker) -- (15/11) ses bennes encore là sont notées
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
            -- (15/11) aucune benne ne la suit et elle a une équipe : rappelée quand elle aura repris le travail
            ADHarvesterUnloaders.recallWatch[vehicle] = nil
            local team = ADHarvesterUnloaders.getTeam(vehicle)
            if ADHarvesterUnloaders.pending[vehicle] == nil and team ~= nil and next(team) ~= nil and isTeamHarvester(vehicle) then
                ADHarvesterUnloaders.recallWatch[vehicle] = { new = newMarker, since = g_time }
                log("%s : aucune benne ne la suit, son équipe sera rappelée à « %s » quand elle aura repris le travail", nameOf(vehicle), tostring(newMarker.name))
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

-- (16/11) benne arrêtée sur place par ADHarvestManager (ensileuse partie au champ suivant) : notée
if ADHarvestManager ~= nil and ADHarvestManager.fireUnloader ~= nil then
    local baseFire = ADHarvestManager.fireUnloader
    function ADHarvestManager:fireUnloader(unloader, harvester)
        local ok, err = FarmPilotCall(ADHarvesterUnloaders.noteFired, unloader, harvester)
        if not ok then
            log("ERREUR benne arrêtée au départ : %s", tostring(err))
        end
        return baseFire(self, unloader, harvester)
    end
end

-- suivi à chaque image, avant le choix des bennes par ADHarvestManager
if ADHarvestManager ~= nil and ADHarvestManager.update ~= nil then
    local baseUpdate = ADHarvestManager.update
    function ADHarvestManager:update(dt)
        local ok, err = FarmPilotCall(ADHarvesterUnloaders.update, dt)
        if not ok then
            ADHarvesterUnloaders.pending = {}
            ADHarvesterUnloaders.recallWatch = {}
            log("ERREUR suivi des bennes au champ suivant : %s", tostring(err))
        end
        return baseUpdate(self, dt)
    end
end

-- (15/11) son équipe dans la sauvegarde de la moissonneuse (#fpUnloaderTeam)
if ADSavegameResume ~= nil then
    local baseSave = ADSavegameResume.save
    function ADSavegameResume.save(stateModule, xmlFile, key, ...)
        if baseSave ~= nil then
            baseSave(stateModule, xmlFile, key, ...)
        end
        local ok, err = FarmPilotCall(function()
            local vehicle = stateModule.vehicle
            local text = vehicle ~= nil and ADHarvesterUnloaders.teamToString(ADHarvesterUnloaders.getTeam(vehicle)) or nil
            if text ~= nil then
                xmlFile:setValue(key .. "#fpUnloaderTeam", text)
            end
        end)
        if not ok then
            log("ERREUR sauvegarde de l'équipe de bennes : %s", tostring(err))
        end
    end

    local baseLoad = ADSavegameResume.load
    function ADSavegameResume.load(stateModule, xmlFile, key, ...)
        if baseLoad ~= nil then
            baseLoad(stateModule, xmlFile, key, ...)
        end
        local vehicle = stateModule.vehicle
        if vehicle ~= nil and vehicle.ad ~= nil then
            local ok, text = FarmPilotCall(xmlFile.getValue, xmlFile, key .. "#fpUnloaderTeam")
            vehicle.ad.fpUnloaderTeam = ok and ADHarvesterUnloaders.teamFromString(text) or nil
        end
    end
end
