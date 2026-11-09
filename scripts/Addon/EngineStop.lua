-- ============================================================================================================
-- FarmPilot : EngineStop.lua
-- Addon : délai avant qu'AutoDrive coupe le moteur d'un véhicule arrêté.
--
-- AutoDrive coupe le moteur après 10 s à l'arrêt (valeur fixe dans son code).
-- Règle : ici ce délai est remplacé par le réglage « Coupure moteur » (page Environnement des réglages d'AutoDrive,
-- sous « Distance clignotant »), ou la coupure est bloquée (« Jamais »). Seul l'appel avec 10 s est changé, pas les
-- autres délais d'AutoDrive (blocage 15 s). L'ancien réglage (Paramètres, jusqu'à la 1.0.0.20) est repris une fois.
--
-- Branché par : AutoDriveAddon.lua (install au chargement de la carte : enveloppe ADSpecialDrivingModule.reset et
-- shouldStopMotor) ; réglage engineStopDelay ajouté au chargement de ce fichier (ADAddon.addSetting).
-- ============================================================================================================

ADAddonEngineStop = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADAddonEngineStop.AD_DELAY_MS = 10000   -- délai codé dans AutoDrive
ADAddonEngineStop.DELAYS = { 0, 10, 30, 60, 120, 300 }   -- secondes, 0 = jamais couper
ADAddonEngineStop.DEFAULT_INDEX = 2     -- 10 s = AutoDrive de base

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
local function delayText(s)
    if s <= 0 then return ADAddon.getText("adAddon_never") end
    if s < 60 then return s .. " s" end
    return (s / 60) .. " min"
end

function ADAddonEngineStop.getDelayMs()
    local autoDrive = ADAddonEngineStop.autoDrive
    local s = autoDrive ~= nil and autoDrive.getSetting("engineStopDelay") or 10
    return (s or 10) * 1000
end

-- ------------------------------------------------------------------------------------------------------------
-- Réglage « Coupure moteur », ajouté à ceux d'AutoDrive au chargement de ce fichier
-- ------------------------------------------------------------------------------------------------------------
local texts = {}
for i, v in ipairs(ADAddonEngineStop.DELAYS) do
    texts[i] = delayText(v)
end
ADAddon.addSetting("engineStopDelay", {
    values = ADAddonEngineStop.DELAYS,
    texts = texts,
    default = ADAddonEngineStop.DEFAULT_INDEX,
    text = "adAddon_engineStopDelay",
    tooltip = "adAddon_engineStopDelay_tooltip"
}, "blinkDistance", "adAddon_engineStopDelay", "adAddon_engineStopDelay_tooltip")

-- ------------------------------------------------------------------------------------------------------------
-- Ancien réglage (Paramètres, jusqu'à la 1.0.0.20)
-- ------------------------------------------------------------------------------------------------------------
-- Jusqu'à la 1.0.0.20 le délai était réglé dans Paramètres et gardé dans modSettings :
-- on le reprend une fois dans le réglage AutoDrive
local function migrateOldSetting(autoDrive)
    local file = getUserProfileAppPath() .. "modSettings/FS25_AutoDriveAddon/settings.xml"
    if not fileExists(file) then
        return
    end
    local xml = loadXMLFile("adAddonSettings", file)
    if xml == nil or xml == 0 then
        return
    end
    local delay = getXMLInt(xml, "adAddon.engineStop#delaySeconds")
    local done = getXMLBool(xml, "adAddon.engineStop#movedToAutoDrive")
    if delay ~= nil and not done then
        local setting = autoDrive.settings.engineStopDelay
        if setting.current == setting.default then
            for i, v in ipairs(ADAddonEngineStop.DELAYS) do
                if v == delay then
                    setting.current = i
                end
            end
        end
        setXMLBool(xml, "adAddon.engineStop#movedToAutoDrive", true)
        saveXMLFile(xml)
    end
    delete(xml)
end

-- ------------------------------------------------------------------------------------------------------------
-- Minuterie de coupure d'AutoDrive
-- ------------------------------------------------------------------------------------------------------------
local function patchTimer(module)
    local timer = module.stoppedTimer
    if timer == nil or timer.adAddonPatched then
        return
    end
    local baseTimer = timer.timer
    -- Seul l'appel avec 10 s (coupure moteur) est changé, pas les autres délais (blocage 15 s)
    timer.timer = function(t, signal, time, dt)
        if time == ADAddonEngineStop.AD_DELAY_MS then
            local delayMs = ADAddonEngineStop.getDelayMs()
            if delayMs > 0 then
                time = delayMs
            end
        end
        return baseTimer(t, signal, time, dt)
    end
    timer.adAddonPatched = true
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place (au chargement de la carte, par AutoDriveAddon.lua)
-- ------------------------------------------------------------------------------------------------------------
function ADAddonEngineStop.install(autoDrive)
    ADAddonEngineStop.autoDrive = autoDrive
    local setting = autoDrive.settings ~= nil and autoDrive.settings.engineStopDelay
    if setting then
        -- textes traduits seulement maintenant (pas encore chargés à la lecture du fichier)
        setting.texts[1] = delayText(0)
        if g_server ~= nil then
            pcall(migrateOldSetting, autoDrive)
        end
    end

    local sdm = ADAddon.getAutoDriveGlobal("ADSpecialDrivingModule")
    if sdm == nil or sdm.reset == nil or sdm.shouldStopMotor == nil then
        ADAddon.warning("ADSpecialDrivingModule not found, engine stop delay inactive")
        return
    end

    local originalReset = sdm.reset
    sdm.reset = function(self, ...)
        local r = originalReset(self, ...)
        patchTimer(self)
        return r
    end

    local originalShouldStop = sdm.shouldStopMotor
    sdm.shouldStopMotor = function(self, ...)
        patchTimer(self)
        if ADAddonEngineStop.getDelayMs() <= 0 then
            return false
        end
        return originalShouldStop(self, ...)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Enregistrement
-- ------------------------------------------------------------------------------------------------------------
ADAddon.addModule(ADAddonEngineStop)
