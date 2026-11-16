-- ============================================================================================================
-- FarmPilot : LoaderTask.lua
-- Tâche du mode « Chargeur » (16/11) : prendre dans la source choisie et vider dans une benne ou au point choisi.
--
-- Base : UnloadBGATask (tâche chargeur d'origine d'AutoDrive : bras, godet, rangées du silo, approche de la benne
-- ou du point). Ce fichier en fait un fils et change seulement :
-- - la source : celle du HUD (silo couloir ou tas au sol), pas le silo le plus proche ; produit fermenté ou non ;
-- - la benne : toute benne arrêtée à moins de TRAILER_RANGE m de la source qui prend le produit, conduite par
--   FarmPilot, garée attelée ou dételée ; la plus proche du chargeur ;
-- - le point de vidage : celui du HUD ; à plus de DIRECT_RANGE m de la source, la tâche s'arrête godet en position
--   route (fpLeave « toPoint » / « toSource ») et le mode fait le trajet par le réseau ;
-- - la fin : quantité vidée atteinte, ou source vide (fpDone) ; plus de message d'erreur « pas de silo » ;
-- - les bras : cherchés aussi sur le chargeur frontal attelé au tracteur (pas seulement tracteur et godet).
--
-- Branché par : Modes/LoaderMode.lua, register.lua (après UnloadBGATask.lua et LoaderJob.lua).
-- ============================================================================================================

LoaderTask = ADInheritsFrom(UnloadBGATask)

local function log(fmt, ...)
    ADLoaderJob.log(fmt, ...)
end

local function nameOf(v)
    return v ~= nil and v.ad ~= nil and v.ad.stateModule ~= nil and tostring(v.ad.stateModule:getName()) or "?"
end

-- source : ADLoaderJob.siloSource / heapSource ; job : vehicle.ad.fpLoaderJob ; atPoint : la tâche démarre au point
-- de vidage (arrivée par la route, godet plein)
function LoaderTask:new(vehicle, source, job, atPoint)
    local o = LoaderTask:create()
    o.vehicle = vehicle
    o.fpSource = source
    o.fpJob = job
    o.fpAtPoint = atPoint == true
    o.fpLoader = true
    return o
end

-- ------------------------------------------------------------------------------------------------------------
-- Source, point, benne
-- ------------------------------------------------------------------------------------------------------------
function LoaderTask:getTargetBunker()
    return self.fpSource ~= nil and self.fpSource.bunker or nil
end

function LoaderTask:getTargetUnloadPoint()
    local cfg = ADLoaderJob.getCfg(self.vehicle)
    if cfg.dst ~= ADLoaderJob.DST_POINT or self.shovel == nil then
        return nil -- (godet pas encore trouvé : getCurrentStates d'origine lit son produit)
    end
    return ADLoaderJob.findPoint(cfg.px, cfg.pz)
end

function LoaderTask:pointFar()
    local t = self.targetUnloadTrigger
    if t == nil or self.fpSource == nil then
        return false
    end
    local x, _, z = ADTriggerManager.getTriggerPos(t)
    return MathUtil.vector2Length(x - self.fpSource.x, z - self.fpSource.z) > ADLoaderJob.DIRECT_RANGE
end

local function rootOf(o)
    if o ~= nil and o.getRootVehicle ~= nil then
        local ok, r = pcall(o.getRootVehicle, o)
        if ok and r ~= nil then
            return r
        end
    end
    return o
end

local function stopped(v)
    return v ~= nil and math.abs(v.lastSpeedReal or 0) < 0.0004
end

-- benne arrêtée près de la source qui prend le produit ; renvoie benne, chauffeur FarmPilot (ou nil)
function LoaderTask:findCloseTrailer()
    self.fpTrailerRoot = nil
    if self.fpSource == nil then
        return nil
    end
    local ft = self.shovel ~= nil and self.shovel.getFillUnitFillType ~= nil and self.shovel:getFillUnitFillType(1) or 0
    if ft == nil or ft <= 0 then
        ft = self.fpSource.fillType or 0
    end
    local vx, _, vz = getWorldTranslation(self.vehicle.components[1].node)
    local best, bestRoot, bestD = nil, nil, math.huge
    for _, v in pairs(AutoDrive.getAllVehicles()) do
        if v ~= self.vehicle and v.spec_trailer ~= nil and v.spec_fillUnit ~= nil and rootOf(v) ~= self.vehicle then
            local tx, _, tz = getWorldTranslation(v.components[1].node)
            local root = rootOf(v)
            if MathUtil.vector2Length(tx - self.fpSource.x, tz - self.fpSource.z) <= ADLoaderJob.TRAILER_RANGE and stopped(root)
                and not (root.ad ~= nil and root.ad.trailerModule ~= nil and root.ad.trailerModule.isActiveAtTrigger ~= nil and root.ad.trailerModule:isActiveAtTrigger()) then
                local free = 0
                for i = 1, #v.spec_fillUnit.fillUnits do
                    if ft <= 0 or v:getFillUnitSupportsFillType(i, ft) then
                        free = free + v:getFillUnitFreeCapacity(i, ft > 0 and ft or nil)
                    end
                end
                local d = MathUtil.vector2Length(tx - vx, tz - vz)
                if free >= 10 and d < bestD then
                    best, bestRoot, bestD = v, root, d
                end
            end
        end
    end
    if best == nil then
        return nil
    end
    self.fpTrailerRoot = bestRoot
    local driver = bestRoot ~= best and bestRoot.ad ~= nil and bestRoot.ad.noMovementTimer ~= nil and bestRoot or nil
    if self.fpLastTrailer ~= best then
        self.fpLastTrailer = best
        log("%s : benne trouvee « %s » (%s) a %.0f m", nameOf(self.vehicle), tostring(best.getName ~= nil and best:getName() or "?"),
            driver ~= nil and "avec chauffeur" or "garee", bestD)
    end
    return best, driver
end

function LoaderTask:checkCurrentTrailerStillValid()
    if self.targetTrailer == nil then
        return false
    end
    local root = self.fpTrailerRoot or rootOf(self.targetTrailer)
    local _, _, _, free = AutoDrive.getObjectNonFuelFillLevels(self.targetTrailer)
    return stopped(root) and (free or 0) >= 1
end

function LoaderTask:checkIfPossibleToRestart()
    if self.targetTrailer == nil then
        self.targetTrailer, self.targetDriver = self:findCloseTrailer()
        local _, _, _, free = AutoDrive.getObjectNonFuelFillLevels(self.targetTrailer)
        self.trailerLeftCapacity = free
    end
    if self.targetUnloadTrigger == nil then
        self.targetUnloadTrigger = self:getTargetUnloadPoint()
    end
    if self.unloadToTrigger then
        return self.targetUnloadTrigger ~= nil and self.targetUnloadTriggerFree
    end
    return self.targetTrailer ~= nil and (self.trailerLeftCapacity or 0) >= 1
end

-- benne FarmPilot servie par un chargeur : elle ne part pas à moitié pleine entre deux godets (Addon/SiloEmpty.lua)
ADLoaderJob.SERVED_TIME = 120000 -- ms sans godet vidé dedans : plus servie

function ADLoaderJob.isServed(vehicle)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.fpLoaderServedUntil ~= nil and (g_time or 0) < vehicle.ad.fpLoaderServedUntil
end

function LoaderTask:markServed(on)
    local root = self.fpTrailerRoot
    if root ~= nil and root.ad ~= nil then
        root.ad.fpLoaderServedUntil = on and ((g_time or 0) + ADLoaderJob.SERVED_TIME) or nil
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Bras et godet : aussi sur le chargeur frontal (tracteur -> chargeur -> godet)
-- ------------------------------------------------------------------------------------------------------------
function LoaderTask:getVehicleShovel()
    UnloadBGATask.getVehicleShovel(self)
    if self.shovel == nil then
        return
    end
    local objects = { self.vehicle }
    for _, impl in pairs(AutoDrive.getAllImplements(self.vehicle, true)) do
        objects[#objects + 1] = impl
    end
    for _, o in ipairs(objects) do
        local tools = o.spec_cylindered ~= nil and o.spec_cylindered.movingTools or nil
        for _, axis in pairs(tools or {}) do
            if axis.axis == "AXIS_FRONTLOADER_ARM" and self.armMain == nil then
                self.armMain = axis
            elseif axis.axis == "AXIS_FRONTLOADER_ARM2" and self.armExtender == nil then
                self.armExtender = axis
            elseif axis.axis == "AXIS_FRONTLOADER_TOOL" and self.shovelRotator == nil then
                self.shovelRotator = axis
            end
        end
    end
    log("%s : godet « %s », bras %s, rallonge %s, godet %s", nameOf(self.vehicle), tostring(self.shovel.getName ~= nil and self.shovel:getName() or "?"),
        tostring(self.armMain ~= nil), tostring(self.armExtender ~= nil), tostring(self.shovelRotator ~= nil))
end

-- ------------------------------------------------------------------------------------------------------------
-- Départ
-- ------------------------------------------------------------------------------------------------------------
function LoaderTask:initializeBGA()
    UnloadBGATask.initializeBGA(self)
    if self.state == self.STATE_IDLE then
        return
    end
    local cfg = ADLoaderJob.getCfg(self.vehicle)
    self.unloadToTrigger = cfg.dst == ADLoaderJob.DST_POINT
    self.targetUnloadTrigger = self:getTargetUnloadPoint()
    self.fpFillTypes = self.fpSource.kind == ADLoaderJob.SRC_SILO and ADLoaderJob.siloFillTypes(self.fpSource.silo) or { self.fpSource.fillType }
    self.action = self.ACTION_DRIVETOSILO_COMMON_POINT
    self.shovelFillLevel = self:getShovelFillLevel()
    self:getCurrentStates()
    if self:checkForUnloadCondition() then
        self.action = self.ACTION_DRIVETOUNLOAD
    end
    log("%s : chargeur pret, vide %s, deja vide %s / %s%s", nameOf(self.vehicle), self.unloadToTrigger and "au point" or "en benne",
        ADLoaderJob.litersText(self.fpJob.done), cfg.qty > 0 and ADLoaderJob.litersText(cfg.qty) or "tout", self.fpAtPoint and " (arrive au point)" or "")
end

-- ------------------------------------------------------------------------------------------------------------
-- Rangées : tous les produits de la source (ensilage fermenté ou non)
-- ------------------------------------------------------------------------------------------------------------
function LoaderTask:checkForFillLevelInCurrentRow()
    local bunker = self.targetBunker
    local saved = bunker.outputFillType
    local total = 0
    for _, ft in ipairs(self.fpFillTypes or { saved }) do
        bunker.outputFillType = ft
        local ok, l = pcall(UnloadBGATask.checkForFillLevelInCurrentRow, self)
        if ok and type(l) == "number" then
            total = total + l
        end
    end
    bunker.outputFillType = saved
    return total
end

-- toutes les rangées vides : source vide, fin du travail (pas d'arrêt en erreur)
function LoaderTask:setShovelOffsetToNonEmptyRow()
    local level = self:checkForFillLevelInCurrentRow()
    local iterations = self.highestShovelOffsetCounter + 1
    while level == 0 and iterations >= 0 do
        iterations = iterations - 1
        if self.shovelOffsetCounter > self.highestShovelOffsetCounter then
            self.shovelOffsetCounter = 0
        else
            self.shovelOffsetCounter = self.shovelOffsetCounter + 1
        end
        level = self:checkForFillLevelInCurrentRow()
    end
    if level == 0 and iterations < 0 then
        log("%s : source vide, fin du travail (%s vides)", nameOf(self.vehicle), ADLoaderJob.litersText(self.fpJob.done))
        self:finishJob("gui_ad_loader_doneEmpty")
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Quantité et fin
-- ------------------------------------------------------------------------------------------------------------
function LoaderTask:quantityReached()
    local cfg = ADLoaderJob.getCfg(self.vehicle)
    return cfg.qty > 0 and (self.fpJob.done or 0) >= cfg.qty
end

function LoaderTask:finishJob(key)
    if self.fpDone then
        return
    end
    self.fpDone = true
    self.fpDoneKey = key
    self:markServed(false) -- la benne peut repartir avec ce qu'elle a
    if self.shovel ~= nil and self.shovel.setDischargeState ~= nil then
        self.shovel:setDischargeState(Dischargeable.DISCHARGE_STATE_OFF, true)
    end
    self.state = self.STATE_IDLE
    self:finished()
end

-- litres vidés : baisse du godet pendant le vidage
function LoaderTask:countUnloaded()
    local liters = self.shovelFilledCapacity or 0
    if self.fpLastLiters ~= nil and liters < self.fpLastLiters and self.action ~= nil and self.action >= self.ACTION_DRIVETOUNLOAD_INIT then
        self.fpJob.done = (self.fpJob.done or 0) + (self.fpLastLiters - liters)
    end
    self.fpLastLiters = liters
end

-- quitte la tâche godet en position route, pour un trajet par le réseau (le mode le fait)
function LoaderTask:leaveByRoad(dt, where)
    self.shovelTarget = self.SHOVELSTATE_TRANSPORT
    if self.shovelState ~= self.shovelTarget then
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        return
    end
    log("%s : part par la route vers %s (godet %s)", nameOf(self.vehicle), where == "toPoint" and "le point de vidage" or "la source",
        ADLoaderJob.litersText(self.shovelFilledCapacity))
    self.fpLeave = where
    self.state = self.STATE_IDLE
    self:finished()
end

function LoaderTask:driveToSiloCommonPoint(dt)
    if self:quantityReached() and (self.shovelFillLevel or 0) <= 0.01 then
        log("%s : quantite videe (%s), fin du travail", nameOf(self.vehicle), ADLoaderJob.litersText(self.fpJob.done))
        self:finishJob("gui_ad_loader_doneQty")
        return
    end
    if self.fpAtPoint then
        return self:leaveByRoad(dt, "toSource")
    end
    return UnloadBGATask.driveToSiloCommonPoint(self, dt)
end

function LoaderTask:driveToBGAUnloadInit(dt)
    if self.unloadToTrigger and not self.fpAtPoint and self:pointFar() then
        return self:leaveByRoad(dt, "toPoint")
    end
    return UnloadBGATask.driveToBGAUnloadInit(self, dt)
end

-- ------------------------------------------------------------------------------------------------------------
-- Boucle
-- ------------------------------------------------------------------------------------------------------------
function LoaderTask:update(dt)
    if self.fpDone or self.fpLeave ~= nil then
        return
    end
    -- chauffeur sans minuterie FarmPilot : pas suivi par la tâche d'origine
    if self.targetDriver ~= nil and (self.targetDriver.ad == nil or self.targetDriver.ad.noMovementTimer == nil) then
        self.targetDriver = nil
    end
    local wasState = self.state
    UnloadBGATask.update(self, dt)
    if self.state ~= self.STATE_IDLE then
        self:countUnloaded()
        if self.targetTrailer ~= nil and not self.unloadToTrigger then
            self:markServed(true)
        end
    end
    if wasState ~= self.state and self.state == self.STATE_WAITING_FOR_RESTART then
        log("%s : attend %s", nameOf(self.vehicle), self.unloadToTrigger and "que le point de vidage ait de la place" or "une benne pres de la source")
    end
end

function LoaderTask:abort()
    self:markServed(false)
    if self.shovel ~= nil and self.shovel.setDischargeState ~= nil then
        self.shovel:setDischargeState(Dischargeable.DISCHARGE_STATE_OFF, true)
    end
end

function LoaderTask:finished()
    self.vehicle.ad.taskModule:setCurrentTaskFinished(ADTaskModule.DONT_PROPAGATE)
end

function LoaderTask:getI18nInfo()
    if self.state == self.STATE_WAITING_FOR_RESTART then
        return self.unloadToTrigger and "$l10n_gui_ad_loader_waitPoint;" or "$l10n_gui_ad_loader_waitTrailer;"
    end
    return "$l10n_gui_ad_loader_working;"
end
