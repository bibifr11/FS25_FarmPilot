-- ============================================================================================================
-- FarmPilot : IntersectionHold.lua
-- Complément de IntersectionModule.lua (route « Intersection », points rouges) : attente à la ligne, recul
-- après un raté, patience. Branché par la dernière ligne d'IntersectionModule.lua.
--
-- (08/11, Fendt 942 au croisement de la ferme) : attente de 55-60 s alors qu'un trou de 9 s (au lieu de
-- 12 s) lui suffit, sans voiture en vue.
--
-- Le log (16:25:41 → 16:27:06, heure du PC) : aucun trafic compté (« plus de danger depuis 70 s »). Le 942
-- s'est arrêté 1 m après s'être engagé, avant les points rouges : compté comme « raté », il a reculé de 3 m et
-- s'est retrouvé à 4,4 m de sa ligne. Il ne s'engage qu'à 2 m ou moins : tenu jusqu'à ce que la route soit
-- refaite (75 s). Même blocage : Patriot 4450 de 16:05 à 16:20 (ligne à 4,1 m), 17:37 (4,6 m). La ligne
-- « trou de N s » repartait toutes les 250 ms, même sans aucun danger.
--
-- Règles :
--  1. Tenu à plus de 2 m de sa ligne, plus aucun danger depuis 2 s : il est lâché et avance jusqu'à la ligne
--     au pas d'approche ; là, la règle habituelle s'applique (libre depuis 2 s : il traverse).
--  2. Arrêté après s'être engagé, l'avant pas encore au 1er point rouge : pas un raté. Pas de recul, il se
--     remet en attente à sa ligne (le croisement regarde de nouveau avant de repartir).
--  3. Vrai raté : recul juste assez pour revenir à 1 m de la ligne (avant : 2 m de trop, ligne à 4 m).
--  4. Ligne « il se contente d'un trou de N s » : une fois par valeur (arrondie), et seulement quand un
--     véhicule est vu (danger au dernier contrôle).
-- ============================================================================================================

ADIntersectionHold = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADIntersectionHold.RELEASE_CLEAR_MS = 2000      -- ms sans danger avant de lâcher un véhicule tenu loin de sa ligne
ADIntersectionHold.RETREAT_TO_STOP = 1          -- m : après un raté, l'avant revient à 1 m de la ligne
ADIntersectionHold.RETREAT_MIN = 1              -- m : recul minimal d'un vrai raté
ADIntersectionHold.NOT_MISSED_LOG_MS = 10000    -- ms entre deux lignes « pas un raté » pour le même véhicule
ADIntersectionHold.PATIENCE_TEXT = "il se contente d'un trou" -- ligne « patience » d'IntersectionModule

-- ------------------------------------------------------------------------------------------------------------
-- Aides
-- ------------------------------------------------------------------------------------------------------------
local function stateOf(vehicle)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.intersection or nil
end

local function nameOf(vehicle)
    return tostring(vehicle.getFullName ~= nil and vehicle:getFullName() or vehicle.id)
end

-- m parcourus par l'avant au-delà du 1er point rouge depuis l'engagement (négatif : pas encore dessus).
-- c.lastToStop n'est plus mis à jour une fois engagé : c'est la distance à la ligne au moment de l'engagement,
-- la ligne étant STOP_BEFORE m avant le 1er point rouge. nil quand l'engagement s'est fait déjà sur la portion
-- rouge (distance inconnue).
function ADIntersectionHold.frontPastRed(c)
    if c == nil or c.lastToStop == nil or c.lastToStop < 0 or c.travel == nil then
        return nil
    end
    return c.travel - c.lastToStop - ADIntersectionModule.STOP_BEFORE
end

-- recul qui ramène l'avant à RETREAT_TO_STOP m de la ligne
function ADIntersectionHold.retreatNeeded(travel, toStopAtCommit)
    return math.max(ADIntersectionHold.RETREAT_MIN, travel - toStopAtCommit + ADIntersectionHold.RETREAT_TO_STOP)
end

-- retour à l'attente à la ligne, comme après un recul (sans recul)
local function backToLine(vehicle, c)
    c.committed = nil
    c.stuckMs = 0
    c.travel = 0
    c.holding, c.waited, c.clearTime, c.speed = true, true, 0, nil
    c.waitStart, c.patienceLogged, c.patienceShown = g_time, nil, nil
    c.heldSince, c.heldLogTime = nil, nil
    c.nextCheck = 0
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonctions principales (posées autour de celles d'IntersectionModule par install)
-- ------------------------------------------------------------------------------------------------------------

-- après ADIntersectionModule.handle : règle 1 (lâcher un véhicule tenu loin de sa ligne, sans danger)
function ADIntersectionHold.afterHandle(vehicle, held)
    local c = stateOf(vehicle)
    if c == nil then
        return held
    end
    if not c.waited then
        c.patienceShown = nil
    end
    if not held or not c.holding or not c.waited or c.retreat ~= nil or c.committed ~= nil then
        return held
    end
    local toStop = c.lastToStop
    if toStop == nil or toStop <= ADIntersectionModule.COMMIT_DIST or (c.clearTime or 0) == 0
        or g_time - c.clearTime < ADIntersectionHold.RELEASE_CLEAR_MS then
        return held
    end
    c.holding = false
    c.heldSince, c.heldLogTime = nil, nil
    if vehicle.ad.specialDrivingModule ~= nil then
        vehicle.ad.specialDrivingModule:releaseVehicle()
    end
    ADIntersectionModule.log("%s tenu a %.1f m de sa ligne, plus de danger depuis %.1f s : il avance jusqu'a la ligne",
        nameOf(vehicle), toStop, (g_time - c.clearTime) / 1000)
    -- cette image reste à l'arrêt (déjà freinée), il roule à la suivante
    return held
end

-- à la place de ADIntersectionModule.startRetreat : règles 2 et 3
function ADIntersectionHold.startRetreat(original, vehicle, c)
    local past = ADIntersectionHold.frontPastRed(c)
    if c.committed == nil or past == nil then
        return original(vehicle, c)
    end
    local toStopAtCommit = c.lastToStop
    if past <= 0 then
        -- le compteur de reculs a été augmenté juste avant l'appel : rendu, ce n'était pas un raté
        local key = c.committed.key
        if c.retreatCount ~= nil and key ~= nil and (c.retreatCount[key] or 0) > 0 then
            c.retreatCount[key] = c.retreatCount[key] - 1
        end
        if g_time - (c.notMissedLogTime or -math.huge) >= ADIntersectionHold.NOT_MISSED_LOG_MS then
            c.notMissedLogTime = g_time
            ADIntersectionModule.log("%s arrete %.1f m apres s'etre engage, l'avant a %.1f m du 1er point rouge : pas un rate, pas de recul, il attend a sa ligne",
                nameOf(vehicle), c.travel, -past)
        end
        backToLine(vehicle, c)
        return
    end
    original(vehicle, c)
    local r = c.retreat
    if r ~= nil and r.travel ~= nil then
        local needed = ADIntersectionHold.retreatNeeded(r.travel, toStopAtCommit)
        if needed < r.needed then
            ADIntersectionModule.log("%s recul ramene a %.1f m (au lieu de %.1f m) : engage a %.1f m de sa ligne, l'avant revient a %.0f m de la ligne",
                nameOf(vehicle), needed, r.needed, toStopAtCommit, ADIntersectionHold.RETREAT_TO_STOP)
            r.needed = needed
        end
    end
end

-- à la place de ADIntersectionModule.log : règle 4 (ligne « patience »)
function ADIntersectionHold.log(original, text, ...)
    if type(text) == "string" and string.find(text, ADIntersectionHold.PATIENCE_TEXT, 1, true) ~= nil then
        local c = stateOf(ADIntersectionHold.current)
        if c ~= nil then
            local relaxed = select(3, ...)
            relaxed = type(relaxed) == "number" and math.floor(relaxed + 0.5) or relaxed
            -- pas de danger au dernier contrôle : le trou exigé ne compte pas, rien à dire
            if (c.clearTime or 0) ~= 0 or c.patienceShown == relaxed then
                return
            end
            c.patienceShown = relaxed
        end
    end
    return original(text, ...)
end

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place (appelée par la dernière ligne d'IntersectionModule.lua)
-- ------------------------------------------------------------------------------------------------------------
function ADIntersectionHold.install(module)
    if module == nil or module.adIntersectionHoldInstalled then
        return
    end
    module.adIntersectionHoldInstalled = true
    local originalHandle, originalRetreat, originalLog = module.handle, module.startRetreat, module.log
    module.handle = function(vehicle, dt)
        ADIntersectionHold.current = vehicle
        local ok, held = FarmPilotCall(originalHandle, vehicle, dt)
        ADIntersectionHold.current = nil
        if not ok then
            error(held, 0)
        end
        return ADIntersectionHold.afterHandle(vehicle, held)
    end
    module.startRetreat = function(vehicle, c)
        return ADIntersectionHold.startRetreat(originalRetreat, vehicle, c)
    end
    module.log = function(text, ...)
        return ADIntersectionHold.log(originalLog, text, ...)
    end
end
