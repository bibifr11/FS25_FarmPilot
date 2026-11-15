-- ============================================================================================================
-- FarmPilot : AutonomousBalerRefill.lua
-- Mode Autonome : recharge de la ficelle / du filet de la presse à sa zone (15/11), par le même chemin que le plein
-- du semoir (AutonomousMode:startRefill, startRefillLoad, monitorRefill, handleRefillStage et les compléments
-- d'AutonomousRefill.lua).
--
-- Règle (15/11) : plus de ficelle / filet (ou presque plus avant le champ), la presse va recharger à la zone choisie
-- dans sa fenêtre (roue dentée, BalerManager.lua), comme le semoir ; puis elle revient au champ et Courseplay repart
-- au dernier point. Rien ne change pour le semoir ni l'épandeur ; pour la presse (plan « baler ») :
--   1. « plein » = plus de place dans la cuve du consommable (getFillUnitFreeCapacity du jeu : rouleaux de réserve
--      pleins). La règle du semoir (niveau de la cuve >= contenance) n'est jamais vraie ici : le niveau de la cuve ne
--      compte pas le rouleau en cours, qui est dans la contenance ;
--   2. niveau en rouleaux (réserve + rouleau en cours) pour le suivi du plein d'AutonomousRefill.lua (niveau au
--      départ, arrivée au point, fin refusée si rien n'est entré) ; une cuve de 2 rouleaux n'est plus « ignorée » ;
--   3. journal [FarmPilot Presse] : route vers la zone (niveau), recharge faite (niveau avant / après), retour au
--      champ et Courseplay au dernier point.
--
-- Branché par : register.lua (source, après AutonomousRefill.lua). Enveloppes posées au chargement de ce fichier sur
-- ADSeederManager.productsFull / fillText, ADSeederRefill.productsFull / planLevel / unitsText, AutonomousMode:startRefill et
-- AutonomousMode:handleRefillStage.
-- ============================================================================================================

ADBalerRefill = {}

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local function log(fmt, ...)
    if ADBalerManager ~= nil and ADBalerManager.log ~= nil then
        ADBalerManager.log(fmt, ...)
    end
end

local function nameOf(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    return sm ~= nil and sm.getName ~= nil and tostring(sm:getName()) or "?"
end

local function markerName(plan)
    return tostring(plan ~= nil and plan.marker ~= nil and plan.marker.name or "?")
end

local function fieldName(vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    local m = sm ~= nil and sm:getFirstMarker() or nil
    return tostring(m ~= nil and m.name or "?")
end

-- ficelle / filet de la presse si les produits demandés sont le sien ; sinon nil (semoir, épandeur : inchangés)
function ADBalerRefill.balerInfo(tool, fillTypes)
    if ADBalerManager == nil or tool == nil or tool.spec_baler == nil then
        return nil
    end
    local info = ADBalerManager.consumable(tool)
    if info == nil or info.fillType == nil then
        return nil
    end
    for _, ft in ipairs(fillTypes or {}) do
        if ft == info.fillType then
            return info
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- 1. et 2. plein et niveau de la presse
-- ------------------------------------------------------------------------------------------------------------
local function wrapFull(base)
    return function(tool, fillTypes, rootVehicle, ...)
        local ok, info = FarmPilotCall(ADBalerRefill.balerInfo, tool, fillTypes)
        if ok and info ~= nil then
            return ADBalerManager.isFull(info)
        end
        return base(tool, fillTypes, rootVehicle, ...)
    end
end

if ADSeederManager ~= nil and ADSeederManager.productsFull ~= nil then
    ADBalerRefill.baseProductsFull = ADSeederManager.productsFull
    ADSeederManager.productsFull = wrapFull(ADSeederManager.productsFull)
end

-- texte du niveau dans les lignes du plein d'AutonomousMode.lua (« plein fait (…) ») : en rouleaux pour la presse
if ADSeederManager ~= nil and ADSeederManager.fillText ~= nil then
    local baseFillText = ADSeederManager.fillText
    function ADSeederManager.fillText(tool, fillTypes, ...)
        local ok, info = FarmPilotCall(ADBalerRefill.balerInfo, tool, fillTypes)
        if ok and info ~= nil then
            return "presse, ficelle / filet " .. ADBalerManager.levelText(info)
        end
        return baseFillText(tool, fillTypes, ...)
    end
end

if ADSeederRefill ~= nil then
    if ADSeederRefill.productsFull ~= nil then
        ADSeederRefill.productsFull = wrapFull(ADSeederRefill.productsFull)
    end
    local basePlanLevel = ADSeederRefill.planLevel
    if basePlanLevel ~= nil then
        function ADSeederRefill.planLevel(plan, ...)
            if plan ~= nil and plan.kind == "baler" then
                local ok, info = FarmPilotCall(ADBalerRefill.balerInfo, plan.tool, plan.fillTypes)
                if ok and info ~= nil then
                    return info.level, info.capacity
                end
            end
            return basePlanLevel(plan, ...)
        end
    end
    local baseUnitsText = ADSeederRefill.unitsText
    if baseUnitsText ~= nil then
        function ADSeederRefill.unitsText(tool, fillTypes, ...)
            local ok, info = FarmPilotCall(ADBalerRefill.balerInfo, tool, fillTypes)
            if ok and info ~= nil then
                return "presse, ficelle / filet " .. ADBalerManager.levelText(info)
            end
            return baseUnitsText(tool, fillTypes, ...)
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- 3. journal : route vers la zone, recharge faite, retour au champ
-- ------------------------------------------------------------------------------------------------------------
function ADBalerRefill.onStart(mode, plan, after)
    local info = ADBalerManager.consumable(plan.tool)
    if info ~= nil then
        plan.levelBefore = info.level
    end
    log("%s : presse : route vers la zone de recharge « %s » (%s), puis %s « %s »", nameOf(mode.vehicle), markerName(plan),
        ADBalerManager.levelText(info), after == "back" and "retour au champ" or "départ au champ", fieldName(mode.vehicle))
end

function ADBalerRefill.afterStage(mode, plan, stage, after)
    local vehicle = mode.vehicle
    local name = nameOf(vehicle)
    if stage == "load" then
        if mode.refillStage == "load" then
            return -- fin refusée, il reste au point (AutonomousRefill.lua le dit dans le log)
        end
        local info = ADBalerManager.consumable(plan.tool)
        local before = plan.levelBefore or 0
        local now = info ~= nil and info.level or 0
        if vehicle.ad.isStoppingWithError then
            log("%s : presse : recharge à « %s » arrêtée sur erreur d'AutoDrive (%.2f -> %.2f rouleaux)", name, markerName(plan), before, now)
        elseif mode.refillStage == "back" then
            log("%s : presse rechargée à « %s » : %.2f -> %.2f rouleaux (%s) ; retour au champ « %s »", name, markerName(plan), before, now,
                ADBalerManager.levelText(info), fieldName(vehicle))
        elseif after == "field" and mode.destinationID ~= nil then
            log("%s : presse rechargée à « %s » : %.2f -> %.2f rouleaux (%s) ; départ au champ « %s »", name, markerName(plan), before, now,
                ADBalerManager.levelText(info), fieldName(vehicle))
        else
            log("%s : presse : recharge à « %s » arrêtée au point (%.2f -> %.2f rouleaux), voir les lignes du plein", name, markerName(plan), before, now)
        end
    elseif stage == "back" then
        if vehicle.ad.fpRestartCp == true then
            local info = ADBalerManager.consumable(plan.tool)
            log("%s : presse de retour au champ « %s » (%s) : Courseplay repart au dernier point", name, fieldName(vehicle), ADBalerManager.levelText(info))
        else
            log("%s : presse : retour au champ « %s » arrêté (erreur d'AutoDrive)", name, fieldName(vehicle))
        end
    end
end

if AutonomousMode ~= nil and AutonomousMode.startRefill ~= nil then
    local baseStartRefill = AutonomousMode.startRefill
    function AutonomousMode:startRefill(plan, after, ...)
        if plan ~= nil and plan.kind == "baler" then
            local ok, err = FarmPilotCall(ADBalerRefill.onStart, self, plan, after)
            if not ok then
                log("ERREUR départ vers la recharge : %s", tostring(err))
            end
        end
        return baseStartRefill(self, plan, after, ...)
    end
end

if AutonomousMode ~= nil and AutonomousMode.handleRefillStage ~= nil then
    local baseHandleRefillStage = AutonomousMode.handleRefillStage
    function AutonomousMode:handleRefillStage(...)
        local plan, stage, after = self.refillPlan, self.refillStage, self.refillThen
        local r = baseHandleRefillStage(self, ...)
        if plan ~= nil and plan.kind == "baler" then
            local ok, err = FarmPilotCall(ADBalerRefill.afterStage, self, plan, stage, after)
            if not ok then
                log("ERREUR suivi de la recharge : %s", tostring(err))
            end
        end
        return r
    end
end
