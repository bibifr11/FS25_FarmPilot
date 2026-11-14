-- ============================================================================================================
-- FarmPilot : TrailerCoverField.lua
-- Bâche des bennes de récolte (mode « Décharger moissonneuse ») : ouverte à l'entrée du champ, fermée à la sortie,
-- rien entre les deux (14/11).
--
-- D'où ça vient : retour d'un joueur transmis le 14/11 vers 15 h 03 (heure de Paris), capture : la benne arrive
-- à l'ensileuse, sa bâche s'ouvre et se ferme en boucle, elle ne se met jamais en place. Décision du 14/11 15 h 04 :
-- « qu'on l'ouvre et ferme que en début ou sortie de champ uniquement ».
--
-- Cause : chaque tâche d'AutoDrive règle la bâche à son début : ouverte pour rejoindre la goulotte
-- (CatchCombinePipeTask, FollowCombineTask, EmptyHarvesterTask, HandleHarvesterTurnTask), fermée pour suivre la
-- 1re benne, s'écarter, partir (DriveToVehicleTask, FollowVehicleTask, StepAsideTask, ExitFieldTask...) et à
-- chaque image de marche arrière (SpecialDrivingModule, fermée hors d'un silo). Quand les tâches s'enchaînent près
-- de l'ensileuse, la bâche fait des allers-retours ; fermée, la benne ne peut pas être remplie (le jeu refuse le
-- remplissage par la goulotte), la mise en place échoue et la tâche suivante la rouvre.
--
-- Règle (bennes en mode « Décharger moissonneuse » conduites par FarmPilot, moissonneuse comme ensileuse) :
-- - dans le champ : plus aucune tâche ne touche la bâche ;
-- - entrée dans le champ (la benne y est depuis STABLE_IN) : bâche ouverte, une fois ;
-- - sortie du champ (hors du champ depuis STABLE_OUT) : bâche fermée, une fois ;
-- - hors du champ, comme avant (ouverte au silo pour vider, fermée sur la route) ;
-- - réglage « bâche automatique » à Non : rien ne change (comme avant, personne ne touche la bâche).
--
-- Enveloppes posées au chargement : AutoDrive.setTrailerCoverOpen, ADTaskModule:update. Chargé par register.lua
-- après RootHarvester.lua.
-- ============================================================================================================

ADCoverField = {}
ADCoverField.DEBUG = false

ADCoverField.STABLE_IN = 2000     -- ms dans le champ avant d'ouvrir
ADCoverField.STABLE_OUT = 5000    -- ms hors du champ avant de fermer (pas d'allers-retours en longeant le bord)
ADCoverField.CHECK_INTERVAL = 250 -- ms entre deux regards

local function vehicleName(vehicle)
    if vehicle ~= nil and vehicle.getName ~= nil then
        local ok, name = pcall(vehicle.getName, vehicle)
        if ok and name ~= nil then
            return tostring(name)
        end
    end
    return "?"
end

-- benne de récolte conduite par FarmPilot
function ADCoverField.isHarvestUnloader(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    return sm ~= nil and sm:isActive() and sm:getMode() == AutoDrive.MODE_UNLOAD
end

function ADCoverField.isOnField(vehicle)
    local node = vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or nil
    if node == nil then
        return false
    end
    local x, y, z = getWorldTranslation(node)
    return AutoDrive.checkIsOnField(x, y, z) == true
end

local baseSetTrailerCoverOpen = AutoDrive.setTrailerCoverOpen

-- ouvre / ferme vraiment (seul appel qui passe dans le champ)
function ADCoverField.apply(vehicle, open, why)
    local trailers = AutoDrive.getAllUnits(vehicle)
    if AutoDrive.getSetting("autoTrailerCover", vehicle) == true then
        if ADCoverField.DEBUG then print(string.format("[FarmPilot Bâche] %s : %s, bâche %s", vehicleName(vehicle), why, open and "ouverte" or "fermée")) end
    end
    baseSetTrailerCoverOpen(vehicle, trailers, open)
end

-- à chaque image de la benne (ADTaskModule:update)
function ADCoverField.update(vehicle, dt)
    local ad = vehicle.ad
    if not ADCoverField.isHarvestUnloader(vehicle) then
        ad.fpCoverIn = nil
        ad.fpCoverTime = nil
        return
    end
    ad.fpCoverCheck = (ad.fpCoverCheck or 0) + dt
    if ad.fpCoverCheck < ADCoverField.CHECK_INTERVAL then
        return
    end
    local step = ad.fpCoverCheck
    ad.fpCoverCheck = 0
    local onField = ADCoverField.isOnField(vehicle)
    if ad.fpCoverIn == nil then
        -- début du mode (ou reprise) : l'état du moment, appliqué une fois
        ad.fpCoverIn = onField
        ad.fpCoverTime = 0
        ADCoverField.apply(vehicle, onField, onField and "dans le champ au départ" or "hors du champ au départ")
        return
    end
    if onField == ad.fpCoverIn then
        ad.fpCoverTime = 0
        return
    end
    ad.fpCoverTime = (ad.fpCoverTime or 0) + step
    if ad.fpCoverTime >= (onField and ADCoverField.STABLE_IN or ADCoverField.STABLE_OUT) then
        ad.fpCoverIn = onField
        ad.fpCoverTime = 0
        ADCoverField.apply(vehicle, onField, onField and "entrée dans le champ" or "sortie du champ")
    end
end

-- les tâches : dans le champ, leur demande est ignorée ; dehors, comme avant
function AutoDrive.setTrailerCoverOpen(vehicle, trailers, open)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.fpCoverIn == true and ADCoverField.isHarvestUnloader(vehicle) then
        return
    end
    return baseSetTrailerCoverOpen(vehicle, trailers, open)
end

local baseTaskModuleUpdate = ADTaskModule.update
function ADTaskModule:update(dt)
    if self.vehicle ~= nil then
        FarmPilotCall(ADCoverField.update, self.vehicle, dt)
    end
    return baseTaskModuleUpdate(self, dt)
end
