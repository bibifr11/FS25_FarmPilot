-- ============================================================================================================
-- FarmPilot : AutonomousHeaderLeave.lua
-- Mode Autonome, moissonneuse équipée seule : une moissonneuse ne quitte jamais un champ avec la coupe montée, dans
-- aucun cas (17/11).
--
-- Cas en jeu (17/11 17:41, 1.1.1.0) : nouvelle session, Lexion 6900 avec la Convio Flex 1080 montée, arrêtée sur le
-- champ 54 (déjà récolté), destination « Champ 7 », pas de champ suivant. Départ du mode Autonome : « départ vers
-- Champ 7 », sortie du champ 54 par « Champ 52 », et elle partait sur la route avec la coupe. Le rappel de la
-- remorque porte-barre (16/11, AutonomousHeaderNextField.lua) ne couvrait que le changement de champ après un champ
-- fini.
--
-- Règle :
-- - Départ du mode Autonome avec la coupe montée, la moissonneuse sur un champ qui n'est pas sa destination
--   (departCarry, appelé par AutonomousHeader.lua : onStart) : elle ne part pas. La coupe est reposée sur sa remorque
--   porte-barre là où elle est (tracteur rappelé du garage s'il le faut, remorque amenée au marqueur le plus proche
--   puis jusqu'à elle dans le champ), puis la remorque est amenée au champ de destination (même flux que le champ
--   suivant : startCarry). Personne de libre : elle reste sur place, message, nouvel essai chaque minute.
-- - Coupe sans remorque connue : une remorque porte-barre vide qui a la place de cette coupe (servingTrailer) ; sinon
--   message clair, elle reste là (FarmPilot arrêté).
-- - Déjà sur le champ de destination (numéro du marqueur, champs regroupés compris), ou pas sur un champ (sur le
--   chemin d'entrée, juste après avoir pris la barre) : rien ne change.
-- - Garde-fou (leavesField) : une route (DriveToDestinationTask) ou une sortie de champ (ExitFieldTask) qui ferait
--   quitter son champ à une moissonneuse qui a sa coupe montée est refusée à son début : arrêt sur place, message,
--   trace « [AD-Coupe] … ne quitte jamais un champ avec la coupe montée ». Marqueur sans numéro de champ : refusé
--   seulement s'il est à plus de GUARD_NEAR m (on ne sait pas de quel champ il est le bord).
-- - Seule exception : la coupe sans remorque (coupe à maïs) que la moissonneuse conduit elle-même à sa place
--   (AutonomousHeaderGround.lua : parkTool, parkSide « front »).
-- - (17/11 20:14, champ 21 -> « Champ 5 ») Coupe qu'elle vient de prendre sur la remorque amenée pour ce champ : la
--   remorque n'avait pas de place à l'entrée et l'a posée au bord d'un champ voisin (28 m). Ce n'est pas un départ :
--   elle va à son champ dès que le tracteur a dégagé (AutonomousHeaderClear.lua, job.deliveredGo). Avant, le
--   garde-fou rappelait le tracteur pour reposer la coupe et elle attendait (« Attendre l'autre machine »).
--
-- Branché par : Modes/AutonomousHeader.lua (onStart : departCarry) ; enveloppes posées au chargement sur
-- DriveToDestinationTask:setUp/:update et ExitFieldTask:setUp/:update. Chargé par register.lua après
-- AutonomousHeaderNextField.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.LEAVE_GUARD = true        -- false : plus de garde-fou sur les routes (le départ reste contrôlé)
ADHeaderFlow.GUARD_NEAR = 100          -- m : destination sans numéro de champ plus près que ça = le bord de son champ

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function label(o)
    return o ~= nil and ADAutonomousManager.toolLabel(o) or "?"
end

-- numéros de champ d'un nom de marqueur (« Champ 52 » = { 52 }), ou nil
local function numbersOf(name)
    if type(name) ~= "string" then
        return nil
    end
    local list = {}
    for n in name:gmatch("%d+") do
        list[#list + 1] = tonumber(n)
    end
    return #list > 0 and list or nil
end

-- le champ numéro num est dans la liste (champs regroupés dans AutoSwitch compris)
local function inList(num, list)
    for _, n in ipairs(list) do
        if n == num then
            return true
        end
        if ADAutonomousManager.groupOf ~= nil then
            local ok, g = FarmPilotCall(ADAutonomousManager.groupOf, n)
            if ok and g ~= nil and g.members ~= nil then
                for _, m in ipairs(g.members) do
                    if tonumber(m) == num then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- La moissonneuse quitterait-elle son champ ?
-- ------------------------------------------------------------------------------------------------------------
-- destId : point du réseau d'arrivée (nil : sortie de champ). true, raison (journal) = elle quitterait le champ où
-- elle est avec sa coupe montée ; false sinon
function ADHeaderFlow.leavesField(v, destId)
    if v == nil or v.ad == nil or not ADHeaderFlow.isCombine(v) then
        return false
    end
    local header = ADHeaderFlow.attachedHeader(v)
    if header == nil then
        return false
    end
    local mode = v.ad.modes ~= nil and v.ad.modes[AutoDrive.MODE_AUTONOMOUS] or nil
    if mode ~= nil and mode.parkTool == header and mode.parkSide == "front" then
        return false -- coupe sans remorque conduite à sa place par la moissonneuse (AutonomousHeaderGround.lua)
    end
    local x, y, z = getWorldTranslation(v.components[1].node)
    if AutoDrive.checkIsOnField ~= nil and not AutoDrive.checkIsOnField(x, y, z) then
        return false
    end
    local field = ADAutonomousManager.fieldAt(x, z)
    if field == nil then
        return false
    end
    -- (17/11) coupe prise sur la remorque amenée pour ce champ : elle y va (exception, une seule fois par amenée)
    local job = v.ad.fpHeaderJob
    if job ~= nil and job.deliveredGo and job.combine == v and job.header == header then
        local jm = job.fieldId ~= nil and ADGraphManager:getMapMarkerById(job.fieldId) or nil
        local jwp = jm ~= nil and ADGraphManager:getWayPointById(jm.id) or nil
        local jField = jwp ~= nil and ADAutonomousManager.fieldAt(jwp.x, jwp.z) or nil
        local here = tonumber(ADAutonomousManager.fieldNumber(field))
        local nums = jm ~= nil and numbersOf(jm.name) or nil
        if (jField ~= nil and ADAutonomousManager.sameField(field, jField)) or (here ~= nil and nums ~= nil and inList(here, nums)) then
            job.deliveredGo = nil -- arrivée sur son champ : l'exception est finie, le garde-fou reprend
        else
            local dm = destId ~= nil and ADGraphManager.getMapMarkerByWayPointId ~= nil and ADGraphManager:getMapMarkerByWayPointId(destId) or nil
            if destId == nil or (jm ~= nil and (jm.id == destId or (dm ~= nil and dm.name == jm.name))) then
                return false
            end
        end
    end
    local num = tonumber(ADAutonomousManager.fieldNumber(field))
    local here = string.format("champ %s", tostring(num or "?"))
    if destId == nil then
        return true, here .. ", sortie du champ"
    end
    local marker = ADGraphManager.getMapMarkerByWayPointId ~= nil and ADGraphManager:getMapMarkerByWayPointId(destId) or nil
    local wp = ADGraphManager:getWayPointById(destId) or marker
    if wp == nil or wp.x == nil or wp.z == nil then
        return false
    end
    local destField = ADAutonomousManager.fieldAt(wp.x, wp.z)
    if destField ~= nil and ADAutonomousManager.sameField(field, destField) then
        return false
    end
    local list = marker ~= nil and numbersOf(marker.name) or nil
    local destName = marker ~= nil and tostring(marker.name) or ("point " .. tostring(destId))
    if list ~= nil then
        if num ~= nil and inList(num, list) then
            return false
        end
        return true, string.format("%s -> « %s »", here, destName)
    end
    if destField == nil and MathUtil.vector2Length(wp.x - x, wp.z - z) <= ADHeaderFlow.GUARD_NEAR then
        return false -- sans numéro, tout près : le bord de son champ
    end
    return true, string.format("%s -> « %s »", here, destName)
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ du mode Autonome (AutonomousHeader.lua : onStart, coupe montée)
-- ------------------------------------------------------------------------------------------------------------
-- true = pris en charge ici (remorque appelée, ou elle reste) ; nil = elle peut partir (même champ, pas sur un champ)
function ADHeaderFlow.departCarry(mode, header)
    local v = mode.vehicle
    local sm = v.ad.stateModule
    local marker = sm:getFirstMarker()
    if marker == nil or marker.id == nil then
        return nil
    end
    local leaves, why = ADHeaderFlow.leavesField(v, marker.id)
    if not leaves then
        return nil
    end
    local trailer, how = ADHeaderFlow.servingTrailer(v, header)
    if trailer == nil then
        print(string.format("[AD-Coupe] %s: depart refuse, %s : aucune remorque porte-barre pour %s, elle ne quitte jamais un champ avec la coupe montee : reste sur place",
            nameOf(v), tostring(why), label(header)))
        log("%s : départ refusé (%s) : aucune remorque porte-barre pour « %s », elle ne quitte jamais un champ avec la coupe montée, reste ici",
            nameOf(v), tostring(why), label(header))
        AutonomousMode.message(v, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_headerLeaveNoTrailer", label(header))
        if sm:isActive() then
            v:stopAutoDrive()
        end
        return true
    end
    local near = ADHeaderFlow.nearestMarkerId ~= nil and ADHeaderFlow.nearestMarkerId(v) or nil
    log("%s : départ vers « %s » avec « %s » montée (%s) : elle ne quitte jamais un champ avec la coupe montée, la coupe est reposée ici sur « %s » (%s), puis amenée",
        nameOf(v), tostring(marker.name), label(header), tostring(why), label(trailer), tostring(how))
    print(string.format("[AD-Coupe] %s: depart avec la coupe montee (%s) : coupe reposee ici sur %s, puis amenee a %s", nameOf(v), tostring(why),
        label(trailer), tostring(marker.name)))
    local saved = v.ad.fpHeaderPrevField
    v.ad.fpHeaderPrevField = near -- la remorque vient au marqueur le plus proche, puis jusqu'à elle (startCollect)
    local ok, started = FarmPilotCall(ADHeaderFlow.startCarry, v, header, false, true)
    v.ad.fpHeaderPrevField = saved
    if not ok then
        log("ERREUR départ avec la coupe montée : %s", tostring(started))
        if sm:isActive() then
            v:stopAutoDrive()
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Garde-fou : routes et sorties de champ refusées
-- ------------------------------------------------------------------------------------------------------------
local function refuse(task, what, destId)
    if not ADHeaderFlow.LEAVE_GUARD then
        return false
    end
    local v = task.vehicle
    local ok, leaves, why = FarmPilotCall(ADHeaderFlow.leavesField, v, destId)
    if not ok or not leaves then
        return false
    end
    local header = ADHeaderFlow.attachedHeader(v)
    print(string.format("[AD-Coupe] %s: %s refusee (%s) : une moissonneuse ne quitte jamais un champ avec la coupe montee (%s), arret sur place",
        nameOf(v), what, tostring(why), label(header)))
    log("%s : %s refusée (%s) : une moissonneuse ne quitte jamais un champ avec la coupe montée (« %s »), arrêt ici", nameOf(v), what, tostring(why), label(header))
    AutonomousMode.message(v, ADMessagesManager.messageTypes.ERROR, 15000, "AD_autonomous_headerNeverLeave", label(header))
    task.fpHeaderRefused = true
    return true
end

-- arrêt sur place (comme StopAndDisableADTask)
local function stopRefused(task, dt)
    local v = task.vehicle
    local sdm = v.ad.specialDrivingModule
    sdm:stopVehicle()
    if math.abs(v.lastSpeedReal or 0) < 0.0015 then
        if v.ad.stateModule:isActive() then
            v:stopAutoDrive()
        end
    else
        sdm:update(dt)
    end
end

if DriveToDestinationTask ~= nil then
    local baseSetUp = DriveToDestinationTask.setUp
    function DriveToDestinationTask:setUp()
        if refuse(self, "route", self.destinationID) then
            return
        end
        return baseSetUp(self)
    end
    local baseUpdate = DriveToDestinationTask.update
    function DriveToDestinationTask:update(dt)
        if self.fpHeaderRefused then
            return stopRefused(self, dt)
        end
        return baseUpdate(self, dt)
    end
end

if ExitFieldTask ~= nil then
    local baseSetUp = ExitFieldTask.setUp
    function ExitFieldTask:setUp()
        if refuse(self, "sortie du champ", nil) then
            return
        end
        return baseSetUp(self)
    end
    local baseUpdate = ExitFieldTask.update
    function ExitFieldTask:update(dt)
        if self.fpHeaderRefused then
            return stopRefused(self, dt)
        end
        return baseUpdate(self, dt)
    end
end
