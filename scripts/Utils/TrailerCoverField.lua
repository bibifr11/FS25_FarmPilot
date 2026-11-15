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
-- 14/11 soir (1.0.5.7) : en 1re tournière, la benne suit l'ensileuse sur la bande d'herbe hors de la limite du
-- champ ; la bâche se fermait au bout de 5 s hors du champ, en plein remplissage (captures du 14/11 20 h 09).
-- Fermeture seulement au vrai départ vers le déchargement :
-- - hors du champ depuis STABLE_OUT ET étape de départ (sortie du champ, route vers le déchargement, retour au champ,
--   parking de fin de chantier, plein, réparation) ;
-- - pendant le suivi, le remplissage, l'attente : jamais, même hors du champ (log une fois : « bâche gardée ouverte ») ;
-- - remplissage hors du champ sans être entrée dans le champ (rejoindre la goulotte, suivre) : ouverte, puis plus
--   aucune tâche n'y touche, comme dans le champ ;
-- - en route vers le déchargement, un champ traversé n'ouvre plus la bâche ;
-- - déjà au déchargement (silo tout près du champ) : on laisse AutoDrive l'ouvrir pour vider, comme avant.
--
-- (15/11) La règle vaut aussi pour les autres modes (Livraison, Chargement, Ramassage et livraison, Conduite,
-- Autonome...) : tout véhicule conduit par FarmPilot avec une benne ou une remorque bâchée (jamais un épandeur, un
-- pulvérisateur ou un semoir : voir isWorkTool).
-- - entrée dans le champ (dans le champ depuis STABLE_IN) : bâche ouverte, une fois ; dans le champ, plus aucune
--   tâche ne touche la bâche (les fermetures demandées sont ignorées) ;
-- - sortie du champ (hors du champ depuis STABLE_OUT) : bâche fermée, une fois ; tant que la remorque se remplit hors
--   du champ (son niveau monte), le délai repart à zéro et la bâche reste ouverte (log une fois) ;
-- - sortie du champ déjà au point de chargement ou de déchargement : bâche laissée à AutoDrive ;
-- - hors du champ, comme avant : ouverte et fermée par AutoDrive au silo, au point de vente, au point de chargement ;
-- - au début du mode hors du champ : rien n'est forcé (AutoDrive la gère, comme avant) ;
-- - « Décharger moissonneuse » garde ses étapes « depart » et « work » ci-dessus, sans changement.
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

-- (15/11) mode du véhicule conduit par FarmPilot (nil s'il n'est pas conduit)
function ADCoverField.getActiveMode(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or not sm:isActive() then
        return nil
    end
    return sm:getMode()
end

-- (15/11) la bâche est gérée ici : véhicule conduit, dans le mode où la règle a été prise
function ADCoverField.isManaged(vehicle)
    local mode = ADCoverField.getActiveMode(vehicle)
    return mode ~= nil and mode == vehicle.ad.fpCoverMode
end

-- (15/11) bennes et remorques seulement : jamais un épandeur, un pulvérisateur, une tonne, un semoir ou une
-- planteuse (épandeur d'engrais 18 m au champ 38 : sa bâche s'ouvrait à l'entrée du champ, « c'est pas une benne »).
-- Leur bâche reste gérée par AutoDrive comme avant.
function ADCoverField.isWorkTool(unit)
    return unit.spec_sprayer ~= nil or unit.spec_sowingMachine ~= nil or unit.spec_fertilizingSowingMachine ~= nil
        or unit.spec_treePlanter ~= nil
end

-- (15/11) remorques bâchées attelées (liste vide sinon)
function ADCoverField.getCoveredUnits(vehicle)
    local covered = {}
    local units = AutoDrive.getAllUnits(vehicle)
    if units ~= nil then
        for _, unit in pairs(units) do
            local spec = unit.spec_cover
            if spec ~= nil and spec.state ~= nil and spec.covers ~= nil and #spec.covers > 0 and not ADCoverField.isWorkTool(unit) then
                covered[#covered + 1] = unit
            end
        end
    end
    return covered
end

-- étape de la benne : "depart" (vers le déchargement, retour, parking, plein, réparation), "work" (rejoindre la
-- machine, la goulotte, suivre : remplissage), nil sinon (attente, file derrière la 1re benne...)
function ADCoverField.getStep(vehicle)
    local task = vehicle.ad.taskModule ~= nil and vehicle.ad.taskModule.activeTask or nil
    if task ~= nil and task.class ~= nil then
        local c = task:class()
        if c ~= nil and (c == UnloadAtDestinationTask or c == ParkTask or c == RefuelTask or c == RepairTask) then
            return "depart"
        end
    end
    local mode = vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    local state = mode ~= nil and mode.state or nil
    local M = CombineUnloaderMode
    if state == nil or M == nil then
        return nil
    end
    if state == M.STATE_EXIT_FIELD or state == M.STATE_DRIVE_TO_UNLOAD or state == M.STATE_DRIVE_TO_START or (M.STATE_PARK ~= nil and state == M.STATE_PARK) then
        return "depart"
    end
    if state == M.STATE_DRIVE_TO_COMBINE or state == M.STATE_DRIVE_TO_PIPE or state == M.STATE_ACTIVE_UNLOAD_COMBINE or state == M.STATE_FOLLOW_COMBINE then
        return "work"
    end
    return nil
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
-- units : les remorques à régler (autres modes : bennes et remorques bâchées seulement), sinon tout l'attelage
function ADCoverField.apply(vehicle, open, why, units)
    local trailers = units or AutoDrive.getAllUnits(vehicle)
    if AutoDrive.getSetting("autoTrailerCover", vehicle) == true then
        if ADCoverField.DEBUG then print(string.format("[FarmPilot Bâche] %s : %s, bâche %s", vehicleName(vehicle), why, open and "ouverte" or "fermée")) end
    end
    baseSetTrailerCoverOpen(vehicle, trailers, open)
end

-- à chaque image de la benne (ADTaskModule:update)
function ADCoverField.update(vehicle, dt)
    local ad = vehicle.ad
    -- (15/11) changement de mode, arrêt ou reprise : la règle repart de zéro
    local mode = ADCoverField.getActiveMode(vehicle)
    if mode ~= ad.fpCoverMode then
        ad.fpCoverMode = mode
        ad.fpCoverIn = nil
        ad.fpCoverTime = nil
        ad.fpCoverKeptLog = nil
        ad.fpCoverLastFill = nil
    end
    if mode == nil then
        return
    end
    if not ADCoverField.isHarvestUnloader(vehicle) then
        -- (15/11) autres modes : entrée et sortie du champ seulement
        ADCoverField.updateOtherMode(vehicle, dt)
        return
    end
    ad.fpCoverCheck = (ad.fpCoverCheck or 0) + dt
    if ad.fpCoverCheck < ADCoverField.CHECK_INTERVAL then
        return
    end
    local step = ad.fpCoverCheck
    ad.fpCoverCheck = 0
    local onField = ADCoverField.isOnField(vehicle)
    local work = ADCoverField.getStep(vehicle)
    if ad.fpCoverIn == nil then
        -- début du mode (ou reprise) : l'état du moment, appliqué une fois
        local open = (onField and work ~= "depart") or work == "work"
        ad.fpCoverIn = open
        ad.fpCoverTime = 0
        ad.fpCoverKeptLog = nil
        ADCoverField.apply(vehicle, open, open and (onField and "dans le champ au départ" or "remplissage hors du champ au départ") or (onField and "en route vers le déchargement au départ" or "hors du champ au départ"))
        return
    end
    if ad.fpCoverIn == true then
        -- ouverte : fermée seulement hors du champ ET au vrai départ vers le déchargement
        if onField then
            ad.fpCoverTime = 0
            ad.fpCoverKeptLog = nil
            return
        end
        ad.fpCoverTime = (ad.fpCoverTime or 0) + step
        if ad.fpCoverTime < ADCoverField.STABLE_OUT then
            return
        end
        if work ~= "depart" then
            -- hors du champ en suivant la machine (bande d'herbe de la 1re tournière...) : gardée ouverte
            if ad.fpCoverKeptLog == nil and AutoDrive.getSetting("autoTrailerCover", vehicle) == true then
                ad.fpCoverKeptLog = true
                if ADCoverField.DEBUG then print(string.format("[FarmPilot Bâche] %s : hors du champ mais pas au départ (suit la machine ou attend), bâche gardée ouverte", vehicleName(vehicle))) end
            end
            return
        end
        ad.fpCoverIn = false
        ad.fpCoverTime = 0
        ad.fpCoverKeptLog = nil
        if AutoDrive.isInRangeToLoadUnloadTarget ~= nil and AutoDrive.isInRangeToLoadUnloadTarget(vehicle) == true then
            -- déjà au déchargement (silo tout près du champ) : AutoDrive l'ouvre pour vider, comme avant
            if AutoDrive.getSetting("autoTrailerCover", vehicle) == true then
                if ADCoverField.DEBUG then print(string.format("[FarmPilot Bâche] %s : sortie du champ déjà au déchargement, bâche laissée à AutoDrive", vehicleName(vehicle))) end
            end
            return
        end
        ADCoverField.apply(vehicle, false, "sortie du champ, départ vers le déchargement")
        return
    end
    -- fermée : ouverte à l'entrée du champ (sauf en route vers le déchargement) ou au remplissage hors du champ
    local want = (onField and work ~= "depart") or work == "work"
    if not want then
        ad.fpCoverTime = 0
        return
    end
    ad.fpCoverTime = (ad.fpCoverTime or 0) + step
    if ad.fpCoverTime >= ADCoverField.STABLE_IN then
        ad.fpCoverIn = true
        ad.fpCoverTime = 0
        ad.fpCoverKeptLog = nil
        ADCoverField.apply(vehicle, true, onField and "entrée dans le champ" or "remplissage hors du champ")
    end
end

-- (15/11) la remorque se remplit-elle ? (niveau en hausse depuis le dernier regard)
function ADCoverField.isFilling(vehicle, units)
    local ad = vehicle.ad
    local fill = 0
    if AutoDrive.getAllFillLevels ~= nil and #units > 0 then
        fill = AutoDrive.getAllFillLevels(units) or 0
    end
    local last = ad.fpCoverLastFill
    ad.fpCoverLastFill = fill
    return last ~= nil and fill > last + 0.01
end

-- (15/11) autres modes que « Décharger moissonneuse » : ouverte à l'entrée du champ, fermée à la sortie
function ADCoverField.updateOtherMode(vehicle, dt)
    local ad = vehicle.ad
    ad.fpCoverCheck = (ad.fpCoverCheck or 0) + dt
    if ad.fpCoverCheck < ADCoverField.CHECK_INTERVAL then
        return
    end
    local step = ad.fpCoverCheck
    ad.fpCoverCheck = 0
    local units = ADCoverField.getCoveredUnits(vehicle)
    if #units == 0 then
        -- pas (ou plus) de remorque bâchée : rien à gérer, AutoDrive comme avant
        ad.fpCoverIn = nil
        ad.fpCoverTime = nil
        ad.fpCoverKeptLog = nil
        ad.fpCoverLastFill = nil
        return
    end
    local onField = ADCoverField.isOnField(vehicle)
    local filling = ADCoverField.isFilling(vehicle, units)
    if ad.fpCoverIn == nil then
        -- début du mode : ouverte s'il est déjà dans le champ ; hors du champ, rien n'est forcé (silo, route)
        ad.fpCoverTime = 0
        ad.fpCoverKeptLog = nil
        ad.fpCoverIn = onField
        if onField then
            ADCoverField.apply(vehicle, true, "dans le champ au départ", units)
        end
        return
    end
    if ad.fpCoverIn == true then
        -- ouverte : fermée seulement hors du champ depuis STABLE_OUT, sans remplissage en cours
        if onField then
            ad.fpCoverTime = 0
            ad.fpCoverKeptLog = nil
            return
        end
        if filling then
            ad.fpCoverTime = 0
            if ad.fpCoverKeptLog == nil and AutoDrive.getSetting("autoTrailerCover", vehicle) == true then
                ad.fpCoverKeptLog = true
                print(string.format("[FarmPilot Bâche] %s : hors du champ mais la remorque se remplit, bâche gardée ouverte", vehicleName(vehicle)))
            end
            return
        end
        ad.fpCoverTime = (ad.fpCoverTime or 0) + step
        if ad.fpCoverTime < ADCoverField.STABLE_OUT then
            return
        end
        ad.fpCoverIn = false
        ad.fpCoverTime = 0
        ad.fpCoverKeptLog = nil
        if AutoDrive.isInRangeToLoadUnloadTarget ~= nil and AutoDrive.isInRangeToLoadUnloadTarget(vehicle) == true then
            -- déjà au point de chargement ou de déchargement (tout près du champ) : AutoDrive la gère, comme avant
            if AutoDrive.getSetting("autoTrailerCover", vehicle) == true then
                print(string.format("[FarmPilot Bâche] %s : sortie du champ déjà au point de chargement ou de déchargement, bâche laissée à AutoDrive", vehicleName(vehicle)))
            end
            return
        end
        ADCoverField.apply(vehicle, false, "sortie du champ", units)
        return
    end
    -- fermée ou laissée à AutoDrive hors du champ : ouverte à l'entrée du champ
    if not onField then
        ad.fpCoverTime = 0
        return
    end
    ad.fpCoverTime = (ad.fpCoverTime or 0) + step
    if ad.fpCoverTime >= ADCoverField.STABLE_IN then
        ad.fpCoverIn = true
        ad.fpCoverTime = 0
        ad.fpCoverKeptLog = nil
        ADCoverField.apply(vehicle, true, "entrée dans le champ", units)
    end
end

-- les tâches : bâche ouverte par FarmPilot (champ, remplissage), leur demande est ignorée ; sinon, comme avant
-- (15/11) tous les modes : véhicule conduit, dans le mode où FarmPilot a ouvert la bâche
function AutoDrive.setTrailerCoverOpen(vehicle, trailers, open)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.fpCoverIn == true and ADCoverField.isManaged(vehicle) then
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
