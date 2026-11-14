-- ============================================================================================================
-- FarmPilot : TireChangeManager.lua
-- Pneus changés automatiquement à l'atelier, comme « Faire le plein » et « Réparer » (14/11).
--
-- Usure des pneus : celle d'AutoSwitch (FS25_AutoSwitch, AS_TireLife : chaque roue de 0 = neuve à 1 = lisse, et
-- son bouton « Pneus neufs » de l'atelier). Sans AutoSwitch, ou usure des pneus d'AutoSwitch coupée (Use Your Tyres
-- actif) : rien, et la ligne du réglage est cachée.
--
-- Règle :
-- - réglage par véhicule « Changer les pneus à » : Non / 10 / 20 / 30 / 40 / 50 % restant, 20 % à l'achat
--   (paramètres du véhicule, sous « Réparer automatiquement ») ;
-- - le tracteur et tous ses outils attelés comptent : dès qu'un pneu a moins que le seuil restant, le tracteur va à
--   l'atelier le plus proche par le même chemin que la réparation automatique (ADTaskModule:hasToRepair ->
--   RepairTask) ; il finit d'abord son travail en cours (chargé, ou benne d'une moissonneuse : isJobRunning), sauf
--   sous EMERGENCY_LEFT (5 %) restant : il y va tout de suite ;
-- - à l'atelier (RepairTask:finished) : comme le bouton « Pneus neufs » d'AutoSwitch (AS_TireLife:replaceTires :
--   pneus usés à 25 % ou plus, même prix, payé comme une réparation), pour chaque engin du convoi qui a un pneu usé
--   à 25 % ou plus ; découvert d'AutoSwitch admis (AS_Overdraft:getLimit), comme au bouton ; puis il reprend son
--   travail (RepairTask:finished relance le mode) ;
-- - pas assez d'argent, ou pas d'atelier : message, il repart travailler et ne réessaie pas avant le lendemain
--   (jour du jeu) ;
-- - log.txt : lignes « [FarmPilot Pneus] … ».
--
-- Branché par des enveloppes posées au chargement : ADTaskModule:hasToRepair, ADTaskModule:RepairIfNeeded,
-- RepairTask:finished, ADSettingsPage:onFrameOpen (ligne cachée sans AutoSwitch). Chargé par register.lua après
-- scripts/Gui/SettingsPage.lua.
-- ============================================================================================================

ADTireChange = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADTireChange.EMERGENCY_LEFT = 0.05   -- moins de 5 % restant : à l'atelier tout de suite, même en plein travail
ADTireChange.REPLACE_FROM = 0.25     -- engin du convoi pris à l'atelier s'il a un pneu usé à 25 % ou plus (AutoSwitch)

AutoDrive.settings.fpTireChange = {
    values = {0, 0.1, 0.2, 0.3, 0.4, 0.5},
    texts = {"gui_ad_no", "10 %", "20 %", "30 %", "40 %", "50 %"},
    default = 3, -- 20 % restant à l'achat
    current = 3,
    text = "gui_ad_fpTireChange",
    tooltip = "gui_ad_fpTireChange_tooltip",
    translate = false, -- « gui_ad_no » traduit quand même (ADSettingsPage:onGuiSetupFinished)
    isVehicleSpecific = true,
    isCopyPaste = true
}

local function log(fmt, ...)
    print("[FarmPilot Pneus] " .. string.format(fmt, ...))
end

local function nameOf(vehicle)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
        return tostring(vehicle.ad.stateModule:getName())
    end
    return vehicle ~= nil and vehicle.getName ~= nil and tostring(vehicle:getName()) or "?"
end

-- ------------------------------------------------------------------------------------------------------------
-- AutoSwitch
-- ------------------------------------------------------------------------------------------------------------
-- table AS_TireLife d'AutoSwitch si son usure des pneus est active, sinon nil
function ADTireChange.tireLife()
    local env = _G["FS25_AutoSwitch"]
    if type(env) ~= "table" then
        return nil
    end
    local ok, tl = FarmPilotCall(function() return env.AS_TireLife end)
    if not ok or type(tl) ~= "table" or tl.active ~= true or tl.ENABLED == false or type(tl.vehicles) ~= "table"
        or tl.getReplacePlan == nil or tl.replaceTires == nil then
        return nil
    end
    return tl
end

local function overdraftLimit(farmId)
    local env = _G["FS25_AutoSwitch"]
    local od = type(env) == "table" and env.AS_Overdraft or nil
    if od == nil or od.getLimit == nil then
        return 0
    end
    local ok, l = FarmPilotCall(od.getLimit, od, farmId)
    return (ok and type(l) == "number" and l > 0) and l or 0
end

local function currentDay()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    return env ~= nil and env.currentDay or 0
end

-- usure la plus forte d'un engin suivi par AutoSwitch (nil s'il ne l'est pas)
function ADTireChange.objectWear(tl, obj)
    if obj == nil or tl.vehicles[obj] == nil or obj.spec_wheels == nil or obj.spec_wheels.wheels == nil then
        return nil
    end
    local maxW = 0
    for _, wheel in ipairs(obj.spec_wheels.wheels) do
        maxW = math.max(maxW, wheel.__asWear or 0)
    end
    return maxW
end

-- usure la plus forte du convoi (tracteur et outils attelés) et l'engin qui l'a
function ADTireChange.convoyWear(tl, vehicle)
    local maxW, worst = 0, nil
    for _, obj in ipairs(AutoDrive.getAllImplements(vehicle, true)) do
        local w = ADTireChange.objectWear(tl, obj)
        if w ~= nil and w >= maxW then
            maxW, worst = w, obj
        end
    end
    return maxW, worst
end

-- ------------------------------------------------------------------------------------------------------------
-- Faut-il aller à l'atelier ?
-- ------------------------------------------------------------------------------------------------------------
-- true si un pneu du convoi a moins que le seuil restant ; 2e valeur : true sous EMERGENCY_LEFT ; 3e : usure
function ADTireChange.check(vehicle)
    if vehicle == nil or vehicle.ad == nil then
        return false
    end
    local threshold = AutoDrive.getSetting("fpTireChange", vehicle)
    if type(threshold) ~= "number" or threshold <= 0 then
        return false
    end
    if vehicle.ad.fpTireWaitDay ~= nil then
        if vehicle.ad.fpTireWaitDay == currentDay() then
            return false
        end
        vehicle.ad.fpTireWaitDay = nil
    end
    local tl = ADTireChange.tireLife()
    if tl == nil then
        return false
    end
    local maxW = ADTireChange.convoyWear(tl, vehicle)
    local left = 1 - maxW
    if left > threshold + 1e-6 then
        return false
    end
    return true, left <= ADTireChange.EMERGENCY_LEFT, maxW
end

-- ------------------------------------------------------------------------------------------------------------
-- À l'atelier
-- ------------------------------------------------------------------------------------------------------------
-- engins du convoi à prendre (un pneu usé à 25 % ou plus) avec le plan d'AutoSwitch ; prix total
function ADTireChange.plans(tl, vehicle)
    local list, total, count = {}, 0, 0
    local from = tl.REPLACE_FROM or ADTireChange.REPLACE_FROM
    for _, obj in ipairs(AutoDrive.getAllImplements(vehicle, true)) do
        local w = ADTireChange.objectWear(tl, obj)
        if w ~= nil and w >= from then
            local ok, plan = FarmPilotCall(tl.getReplacePlan, tl, obj)
            if ok and type(plan) == "table" and plan.wheels ~= nil and #plan.wheels > 0 then
                list[#list + 1] = { obj = obj, plan = plan }
                total = total + (plan.price or 0)
                count = count + #plan.wheels
            end
        end
    end
    return list, total, count
end

-- appelé à l'arrivée à l'atelier (RepairTask:finished, serveur) ; true si des pneus ont été changés
function ADTireChange.atWorkshop(vehicle)
    local need = ADTireChange.check(vehicle)
    if not need then
        return false
    end
    local tl = ADTireChange.tireLife()
    local list, total, count = ADTireChange.plans(tl, vehicle)
    if #list == 0 then
        return false
    end
    local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
    local price = g_i18n ~= nil and g_i18n.formatMoney ~= nil and g_i18n:formatMoney(total, 0, true, true) or tostring(total)
    if farmId ~= nil and g_currentMission ~= nil and g_currentMission.getMoney ~= nil then
        local ok, money = FarmPilotCall(g_currentMission.getMoney, g_currentMission, farmId)
        local limit = overdraftLimit(farmId)
        if ok and type(money) == "number" and money + limit < total then
            vehicle.ad.fpTireWaitDay = currentDay()
            log("%s : %d pneus à changer pour %d, solde %d, découvert permis %d : pas assez, nouvel essai demain",
                nameOf(vehicle), count, math.floor(total), math.floor(money), math.floor(limit))
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 12000, "AD_fpTires_noMoney", price)
            return false
        end
    end
    local done = 0
    for _, e in ipairs(list) do
        local ok, changed = FarmPilotCall(tl.replaceTires, tl, e.obj)
        if ok and changed then
            done = done + #e.plan.wheels
            log("%s : %s, %d pneus neufs (%d)", nameOf(vehicle), nameOf(e.obj), #e.plan.wheels, math.floor(e.plan.price or 0))
        elseif not ok then
            log("ERREUR pneus neufs %s : %s", nameOf(e.obj), tostring(changed))
        end
    end
    if done > 0 then
        AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.INFO, 10000, "AD_fpTires_done", done, price)
    else
        vehicle.ad.fpTireWaitDay = currentDay()
    end
    return done > 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes (posées au chargement)
-- ------------------------------------------------------------------------------------------------------------
-- départ à l'atelier : réparation d'origine, ou pneus usés
local baseHasToRepair = ADTaskModule.hasToRepair
function ADTaskModule:hasToRepair()
    if baseHasToRepair(self) then
        return true
    end
    local ok, need, urgent, wear = FarmPilotCall(ADTireChange.check, self.vehicle)
    if not ok then
        log("ERREUR usure des pneus : %s", tostring(need))
        return false
    end
    if not need then
        self.fpTireLogged = nil
        return false
    end
    if not urgent and self:isJobRunning("tires", "FarmPilot Pneus") then
        return false
    end
    if not self.fpTireLogged then
        self.fpTireLogged = true
        log("%s : pneus usés à %d %% (seuil %d %% restant)%s, départ à l'atelier", nameOf(self.vehicle), math.floor(wear * 100 + 0.5),
            math.floor((AutoDrive.getSetting("fpTireChange", self.vehicle) or 0) * 100 + 0.5), urgent and ", tout de suite" or "")
    end
    return true
end

-- pas d'atelier : pas de message à chaque tâche, nouvel essai demain
local baseRepairIfNeeded = ADTaskModule.RepairIfNeeded
function ADTaskModule:RepairIfNeeded()
    local vehicle = self.vehicle
    local okT, tires = FarmPilotCall(ADTireChange.check, vehicle)
    if okT and tires and AutoDrive.getClosestRepairTrigger ~= nil and AutoDrive:getClosestRepairTrigger(vehicle) == nil then
        local okR, repair = FarmPilotCall(baseHasToRepair, self)
        if okR and not repair then
            vehicle.ad.fpTireWaitDay = currentDay()
            self.fpTireLogged = nil
            log("%s : pneus usés mais pas d'atelier sur le réseau, nouvel essai demain", nameOf(vehicle))
            AutonomousMode.message(vehicle, ADMessagesManager.messageTypes.ERROR, 12000, "AD_fpTires_noWorkshop")
            return
        end
    end
    return baseRepairIfNeeded(self)
end

-- à l'atelier : pneus changés avant que le travail reprenne
local baseRepairFinished = RepairTask.finished
function RepairTask:finished()
    if g_server ~= nil then
        local ok, err = FarmPilotCall(ADTireChange.atWorkshop, self.vehicle)
        if not ok then
            log("ERREUR pneus à l'atelier : %s", tostring(err))
        end
        if self.vehicle ~= nil and self.vehicle.ad ~= nil and self.vehicle.ad.taskModule ~= nil then
            self.vehicle.ad.taskModule.fpTireLogged = nil
        end
    end
    return baseRepairFinished(self)
end

-- ligne « Changer les pneus à » cachée sans l'usure des pneus d'AutoSwitch
function ADTireChange.updateRow(page)
    local element = page ~= nil and page.settingElements ~= nil and page.settingElements.fpTireChange or nil
    local row = element ~= nil and element.parent or nil
    if row == nil or row.setVisible == nil then
        return
    end
    local show = ADTireChange.tireLife() ~= nil
    if row.fpShown == show then
        return
    end
    row.fpShown = show
    row:setVisible(show)
    local layout = row.parent
    if layout ~= nil and layout.elements ~= nil then
        -- couleurs alternées des lignes visibles
        local even = false
        for _, c in ipairs(layout.elements) do
            if c.setImageColor ~= nil and c.profile == row.profile and (c.getIsVisible == nil or c:getIsVisible()) then
                c:setImageColor(nil, table.unpack(InGameMenuSettingsFrame.COLOR_ALTERNATING[even]))
                even = not even
            end
        end
        if layout.invalidateLayout ~= nil then
            layout:invalidateLayout()
        end
    end
end

local baseFrameOpen = ADSettingsPage.onFrameOpen
function ADSettingsPage:onFrameOpen(...)
    local ok, err = FarmPilotCall(ADTireChange.updateRow, self)
    if not ok then
        log("ERREUR ligne des pneus : %s", tostring(err))
    end
    return baseFrameOpen(self, ...)
end
