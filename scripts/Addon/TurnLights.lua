-- Clignotant avant les virages et les croisements
-- AutoDrive allume le clignotant seulement quand l'angle du trajet juste devant dépasse son réglage
-- « Clignotant automatique » : la distance regardée dépend de la vitesse, donc il clignote trop tard.
-- Ici le trajet est regardé sur une distance fixe (réglage « Distance clignotant », 50 m par défaut),
-- le clignotant s'allume du côté du virage et s'éteint une fois le virage passé et le tracteur de nouveau droit.
-- Le réglage est ajouté à ceux d'AutoDrive (sauvegarde et multijoueur par AutoDrive) et affiché
-- dans sa page de réglages, juste sous « Clignotant automatique ».

ADAddonTurnLights = {}

ADAddonTurnLights.DISTANCES = { 20, 30, 40, 50, 60, 70, 80, 100 }
ADAddonTurnLights.DEFAULT_INDEX = 4     -- 50 m
ADAddonTurnLights.KEEP_ANGLE = 15       -- degrés de virage encore devant qui gardent le clignotant
-- (07/11, demande Fabien) après le virage, le clignotant reste allumé le temps de remettre droit :
-- éteint quand le tracteur est de nouveau dans l'axe de la route (STRAIGHT_ANGLE) après AFTER_MIN m, au plus AFTER_MAX m
ADAddonTurnLights.AFTER_MIN = 8         -- m roulés depuis la fin du virage devant (environ 5 m après la sortie du virage)
ADAddonTurnLights.AFTER_MAX = 30        -- m au plus
ADAddonTurnLights.STRAIGHT_ANGLE = 6    -- degrés entre le tracteur et la route : « droit »

local texts = {}
for i, v in ipairs(ADAddonTurnLights.DISTANCES) do
    texts[i] = v .. " m"
end
ADAddon.addSetting("blinkDistance", {
    values = ADAddonTurnLights.DISTANCES,
    texts = texts,
    default = ADAddonTurnLights.DEFAULT_INDEX,
    text = "gui_ad_blinkDistance",
    tooltip = "gui_ad_blinkDistance_tooltip"
}, "blinkValue", "adAddon_blinkDistance", "adAddon_blinkDistance_tooltip")

-- Renvoie 1 (gauche), -1 (droite) ou 0 si le trajet tourne d'au moins minAngle dans les maxDistance m devant.
-- Un clignotant déjà allumé reste allumé tant qu'il reste au moins KEEP_ANGLE de ce virage devant.
function ADAddonTurnLights.getUpcomingTurnDirection(module, maxDistance, minAngle)
    local autoDrive = ADAddonTurnLights.autoDrive
    local index = module:getCurrentWayPointIndex()
    local wayPoints = module.wayPoints
    if wayPoints == nil or index == nil or wayPoints[index] == nil then
        return 0
    end
    local x, _, z = getWorldTranslation(module.vehicle.components[1].node)
    local prev = wayPoints[index - 1] or { x = x, z = z }
    local current = module.adAddonBlinkDir or 0
    local keepAngle = math.min(ADAddonTurnLights.KEEP_ANGLE, minAngle)
    local distance = MathUtil.vector2Length(wayPoints[index].x - x, wayPoints[index].z - z)
    local cumulated = 0
    local keep = false
    local i = index
    while distance <= maxDistance and wayPoints[i + 1] ~= nil do
        local wpCurrent = wayPoints[i]
        local wpAhead = wayPoints[i + 1]
        local wpRef = (i == index) and prev or wayPoints[i - 1]
        local angle = autoDrive.angleBetween({ x = wpAhead.x - wpCurrent.x, z = wpAhead.z - wpCurrent.z }, { x = wpCurrent.x - wpRef.x, z = wpCurrent.z - wpRef.z })
        cumulated = cumulated + math.max(-90, math.min(90, angle))
        if cumulated >= minAngle then
            return 1
        elseif cumulated <= -minAngle then
            return -1
        end
        if current ~= 0 and cumulated * current >= keepAngle then
            keep = true
        end
        distance = distance + MathUtil.vector2Length(wpAhead.x - wpCurrent.x, wpAhead.z - wpCurrent.z)
        i = i + 1
    end
    if keep then
        return current
    end
    return 0
end

-- TEST 27/10 (Fabien : « aucun n'a de clignotant aux croisements ») : journal [AD-Clignotant]
ADAddonTurnLights.LOG = true
ADAddonTurnLights.RESET_LOG_INTERVAL = 5000 -- ms entre deux lignes « éteint par un autre script »

local function vehicleName(vehicle)
    local ad = vehicle.ad
    if ad ~= nil and ad.stateModule ~= nil and ad.stateModule.getName ~= nil then
        return tostring(ad.stateModule:getName())
    end
    return tostring(vehicle.getName ~= nil and vehicle:getName() or vehicle.id)
end

local function log(vehicle, text, ...)
    if ADAddonTurnLights.LOG then
        print(string.format("[AD-Clignotant] %s: " .. text, vehicleName(vehicle), ...))
    end
end

local function currentState(vehicle)
    local spec = vehicle.spec_lights
    return spec ~= nil and spec.turnLightState or nil
end

-- écart en degrés entre le tracteur et le tronçon de route qu'il suit (marche avant comme arrière)
function ADAddonTurnLights.headingError(module)
    local wayPoints = module.wayPoints
    local index = module:getCurrentWayPointIndex()
    if wayPoints == nil or index == nil or wayPoints[index] == nil then
        return 0
    end
    local node = module.vehicle.components[1].node
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local b = wayPoints[index]
    local a = wayPoints[index - 1] or { x = x, z = z }
    local rx, rz = b.x - a.x, b.z - a.z
    if rx * rx + rz * rz < 0.01 or dx * dx + dz * dz < 0.0001 then
        return 0
    end
    local angle = math.abs(ADAddonTurnLights.autoDrive.angleBetween({ x = rx, z = rz }, { x = dx, z = dz }))
    if angle > 90 then
        angle = 180 - angle
    end
    return angle
end

function ADAddonTurnLights.update(module, minAngle, dt)
    local vehicle = module.vehicle
    -- autres mods qui éteignent le clignotant : sans effet pendant que FarmPilot conduit (TurnLightsOtherMods.lua)
    if ADAddonTurnLightsOtherMods ~= nil and not ADAddonTurnLightsOtherMods.done then
        ADAddonTurnLightsOtherMods.install()
    end
    local maxDistance = ADAddonTurnLights.autoDrive.getSetting("blinkDistance") or 50
    local direction = 0
    if module:isOnRoadNetwork() then
        direction = ADAddonTurnLights.getUpcomingTurnDirection(module, maxDistance, minAngle)
    end
    if direction ~= 0 then
        module.adAddonBlinkClear = 0
        module.adAddonBlinkClearX = nil
        local wanted = direction > 0 and Lights.TURNLIGHT_LEFT or Lights.TURNLIGHT_RIGHT
        local before = currentState(vehicle)
        if module.adAddonBlinkDir ~= direction then
            log(vehicle, "virage a %s dans les %d m (angle >= %d) : clignotant demande (etat avant %s)",
                direction > 0 and "gauche" or "droite", maxDistance, minAngle, tostring(before))
            module.adAddonResetLogTime = nil
        elseif before ~= wanted then
            -- quelqu'un l'a eteint entre deux passages (le jeu, un autre mod comme AutoTurnOffTurnLights ?) : remis
            local now = g_time or 0
            if module.adAddonResetLogTime == nil or now - module.adAddonResetLogTime >= ADAddonTurnLights.RESET_LOG_INTERVAL then
                module.adAddonResetLogTime = now
                log(vehicle, "clignotant eteint par un autre script (etat %s), remis", tostring(before))
            end
        end
        module.adAddonBlinkDir = direction
        vehicle:setTurnLightState(wanted, true)
        local after = currentState(vehicle)
        if after ~= wanted and before ~= wanted then
            log(vehicle, "le jeu refuse le clignotant (etat %s apres la demande %s)", tostring(after), tostring(wanted))
        end
    elseif (module.adAddonBlinkDir or 0) ~= 0 then
        -- plus de virage devant : gardé allumé jusqu'à ce que le tracteur soit de nouveau droit
        local x, _, z = getWorldTranslation(vehicle.components[1].node)
        if module.adAddonBlinkClearX == nil then
            module.adAddonBlinkClearX, module.adAddonBlinkClearZ = x, z
        end
        module.adAddonBlinkClear = (module.adAddonBlinkClear or 0) + dt
        local moved = MathUtil.vector2Length(x - module.adAddonBlinkClearX, z - module.adAddonBlinkClearZ)
        local err = ADAddonTurnLights.headingError(module)
        if (moved >= ADAddonTurnLights.AFTER_MIN and err <= ADAddonTurnLights.STRAIGHT_ANGLE) or moved >= ADAddonTurnLights.AFTER_MAX then
            module.adAddonBlinkDir = 0
            module.adAddonBlinkClearX = nil
            vehicle:setTurnLightState(Lights.TURNLIGHT_OFF)
            log(vehicle, "virage passe, tracteur droit (%.0f m apres, ecart %.0f deg) : clignotant eteint", moved, err)
        else
            -- un autre script a pu l'éteindre entre-temps (le jeu en redressant, un autre mod) : remis
            local wanted = module.adAddonBlinkDir > 0 and Lights.TURNLIGHT_LEFT or Lights.TURNLIGHT_RIGHT
            if currentState(vehicle) ~= wanted then
                vehicle:setTurnLightState(wanted, true)
            end
        end
    end
end

function ADAddonTurnLights.install(autoDrive)
    ADAddonTurnLights.autoDrive = autoDrive

    local pathModule = ADAddon.getAutoDriveGlobal("ADDrivePathModule")
    if pathModule == nil or pathModule.checkActiveAttributesSet == nil or pathModule.reset == nil then
        ADAddon.warning("ADDrivePathModule not found, turn lights inactive")
        return
    end

    local originalReset = pathModule.reset
    pathModule.reset = function(self, ...)
        self.adAddonBlinkDir = 0
        self.adAddonBlinkClear = 0
        self.adAddonBlinkClearX = nil
        return originalReset(self, ...)
    end

    -- Le clignotant d'AutoDrive est coupé pendant son appel, puis remplacé par celui-ci
    local originalCheck = pathModule.checkActiveAttributesSet
    pathModule.checkActiveAttributesSet = function(self, dt)
        local vehicle = self.vehicle
        local minAngle = autoDrive.getSetting("blinkValue") or 0
        if not vehicle.isServer or minAngle <= 0 or vehicle.setTurnLightState == nil then
            return originalCheck(self, dt)
        end
        local own = rawget(vehicle, "setTurnLightState")
        vehicle.setTurnLightState = function() end
        local ok, err = pcall(originalCheck, self, dt)
        rawset(vehicle, "setTurnLightState", own)
        if not ok then
            error(err, 0)
        end
        if ((g_updateLoopIndex + vehicle.id) % autoDrive.PERF_FRAMES == 0) then
            if not self.adAddonBlinkSeen then
                self.adAddonBlinkSeen = true
                log(vehicle, "suivi des virages actif (angle %d, distance %d m, setTurnLightState %s)", minAngle,
                    autoDrive.getSetting("blinkDistance") or -1, tostring(vehicle.setTurnLightState ~= nil))
            end
            ADAddonTurnLights.update(self, minAngle, dt * autoDrive.PERF_FRAMES)
        end
    end
    print("[AD-Clignotant] module installe (TEST 27/10)")
end

ADAddon.addModule(ADAddonTurnLights)
