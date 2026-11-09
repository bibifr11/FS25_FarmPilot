-- ============================================================================================================
-- FarmPilot : FollowCombineTaskTurn.lua
-- Complément de FollowCombineTask (tâche AutoDrive d'origine) : le virage de la machine suivie.
-- Commun moissonneuse et ensileuse (les règles propres à l'ensileuse sont marquées).
--
-- AutoDrive d'origine attend dès que AutoDrive.combineIsTurning dit « virage » ; or il le dit aussi quand il reste
-- moins de 20 m de culture devant, la machine récoltant encore tout droit. Ici le virage est verrouillé
-- (self.combineInTurn) : il commence quand la machine recule, s'arrête (moissonneuse) ou change vraiment de cap (pour la
-- moissonneuse le drapeau Courseplay / ouvrier suffit), et il finit quand elle roule en marche avant
-- TURN_END_FORWARD_TIME ms avec un cap stable. (ensileuse) arrêtée TURN_STOPPED_RELEASE_TIME ms : elle attend la benne,
-- ce n'est pas un virage (fin de l'attente, pas de nouvelle attente tant qu'elle reste arrêtée).
--
-- Historique :
--   23/10       une ligne de journal à chaque recul (la benne allait et venait sans rien dire) : logReverse ;
--   26/10 06:38-06:39 marqueur spécifique Courseplay pour les demi-tours (7R arrêté deux fois « attend,
--               l'ensileuse fait demi-tour ») : (ensileuse) le drapeau Courseplay ne compte que dans ses points de
--               demi-tour avec un vrai changement de cap (CP_TURN_WAIT_MIN_DEG) ; décrochement, fin de rang : on roule ;
--   27/10 18:48 attente sans fin : une machine arrêtée ne nous dépassera pas, pas d'attente
--               (combineStandsStill, PASS_BY_STOPPED).
--
-- Branché par : FollowCombineTask:new (initCombineTurn), :setUp (setUpTurn), :abort et :finished (clearTurnFlags),
-- :update (updateCombineTurn ; checkPassByStandingCombine dans STATE_WAIT_FOR_COMBINE_TO_PASS_BY ; logReverse dans les
-- deux reculs). Les états d'origine de update lisent self.combineInTurn au lieu de AutoDrive.combineIsTurning.
-- getLogName sert à toute la poursuite et à CatchCombinePipeTask.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
-- combine turn: the unloader waits until the combine is aligned again and drives forward, a stop alone does not end the turn
FollowCombineTask.TURN_END_FORWARD_TIME = 3000
FollowCombineTask.TURN_END_MAX_HEADING_CHANGE = 5
-- 26/10 06:39 (U-turns have their own Courseplay marker): a Courseplay turn of the forage
-- harvester starts the wait only with a real heading change between its red and green points; a jog or a row finish
-- handed to its pathfinder (8-37 deg) is driven through, the trailer stays beside
FollowCombineTask.CP_TURN_WAIT_MIN_DEG = 90
FollowCombineTask.TURN_HEADING_SAMPLE_TIME = 2000
FollowCombineTask.TURN_STOPPED_RELEASE_TIME = 8000 -- ms standing still: the harvester waits for the trailer, no turn
FollowCombineTask.TURN_STOPPED_SPEED = 0.0002 -- lastSpeedReal (m/ms) below which the combine counts as stopped
FollowCombineTask.PASS_BY_STOPPED = 3000 -- ms standing: the harvester will not pass by, no wait for it (27/10)

-- ------------------------------------------------------------------------------------------------------------
-- Mise en place, et drapeaux de virage posés sur le tracteur
-- ------------------------------------------------------------------------------------------------------------
-- appelée par FollowCombineTask:new
function FollowCombineTask.initCombineTurn(o)
    o.combineInTurn = false
    o.turnHeadingSamples = {}
    o.turnHeadingSampleTimer = 0
    o.turnFlagIgnored = false
end

-- appelée par FollowCombineTask:setUp
function FollowCombineTask:setUpTurn()
    -- chasing again: the anticipated U-turn place is used up
    self.vehicle.ad.anticipatedRear = nil
    self.vehicle.ad.cpTurnFlagIgnored = nil
end

-- appelée par FollowCombineTask:abort et FollowCombineTask:finished
function FollowCombineTask:clearTurnFlags()
    self.vehicle.ad.endRowTurnActive = nil
    self.vehicle.ad.cpTurnFlagIgnored = nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Virage verrouillé de la machine suivie (fonction principale, appelée par update)
-- ------------------------------------------------------------------------------------------------------------
-- latched turn state: starts when the original detection (AutoDrive.combineIsTurning) sees a turn,
-- ends only when the combine drives forward for TURN_END_FORWARD_TIME with a steady heading
function FollowCombineTask:updateCombineTurn(dt)
    local heading = FollowCombineTask.getCombineHeading(self.combine)
    self.turnHeadingSampleTimer = self.turnHeadingSampleTimer - dt
    if self.turnHeadingSampleTimer <= 0 then
        self.turnHeadingSampleTimer = 500
        table.insert(self.turnHeadingSamples, heading)
        local maxSamples = FollowCombineTask.TURN_HEADING_SAMPLE_TIME / 500 + 1
        while #self.turnHeadingSamples > maxSamples do
            table.remove(self.turnHeadingSamples, 1)
        end
    end
    if not AutoDrive.combineIsTurning(self.combine) then
        self.turnFlagIgnored = false
    end
    -- read by the place choice (CombineUnloaderMode:getPipeChasePosition): flag ignored, the place stays beside
    self.vehicle.ad.cpTurnFlagIgnored = self.turnFlagIgnored and not self.combineInTurn
    local chopper = AutoDrive.isChopperUnloading(self.vehicle)
    -- forage harvester only: standing still that long it is not turning, it waits for this trailer: end the wait
    -- (and do not start it again while it stands)
    local stoppedTime = self.combine.ad.noMovementTimer ~= nil and self.combine.ad.noMovementTimer.elapsedTime or 0
    if not chopper or stoppedTime < FollowCombineTask.TURN_STOPPED_RELEASE_TIME then
        self.turnReleasedStopped = false
    elseif self.combineInTurn then
        -- safety net: the chase goes on, with its strict line check (a blocked line hands over to a planned route)
        print(string.format("[AD-Poursuite] %s: moissonneuse arretee depuis %.0f s (elle attend la benne), fin de l'attente du demi-tour, poursuite", FollowCombineTask.getLogName(self.vehicle), stoppedTime / 1000))
        self.combineInTurn = false
        self.turnReleasedStopped = true
    end
    if AutoDrive.combineIsTurning(self.combine) then
        if not self.combineInTurn then
            -- the original detection also says "turning" when less than 20 m of crop is left in front, while the
            -- combine still harvests straight on: the turn only starts when it really stops, reverses or turns
            local reason, flagIgnored = FollowCombineTask.getTurnStartReason(self.combine, heading, self.turnHeadingSamples, chopper)
            if self.turnReleasedStopped then
                return
            end
            if reason == nil then
                if flagIgnored ~= nil and not self.turnFlagIgnored then
                    print(string.format("[AD-Poursuite] %s: %s ignore, poursuite continue, place a cote gardee", FollowCombineTask.getLogName(self.vehicle), flagIgnored))
                    self.turnFlagIgnored = true
                end
                self.vehicle.ad.cpTurnFlagIgnored = self.turnFlagIgnored
                return
            end
            self.turnFlagIgnored = false
            self.vehicle.ad.cpTurnFlagIgnored = false
            print(string.format("[AD-Poursuite] %s: demi-tour de la moissonneuse (%s), attente", FollowCombineTask.getLogName(self.vehicle), reason))
        end
        self.combineInTurn = true
        return
    end
    if not self.combineInTurn then
        return
    end
    local forward = self.combine.ad.driveForwardTimer.elapsedTime >= FollowCombineTask.TURN_END_FORWARD_TIME
    local steady = #self.turnHeadingSamples > FollowCombineTask.TURN_HEADING_SAMPLE_TIME / 500
    if steady then
        local diff = math.abs(heading - self.turnHeadingSamples[1]) % 360
        if diff > 180 then
            diff = 360 - diff
        end
        steady = diff <= FollowCombineTask.TURN_END_MAX_HEADING_CHANGE
    end
    if forward and steady then
        print(string.format("[AD-Poursuite] %s: demi-tour termine (moissonneuse alignee et en marche avant), reprise", FollowCombineTask.getLogName(self.vehicle)))
        self.combineInTurn = false
    end
end

-- why the turn really starts, nil while the combine still drives straight on
function FollowCombineTask.getTurnStartReason(combine, heading, samples, chopper)
    -- Courseplay / helper may report a maneuver while the combine still harvests straight on:
    -- their flag only counts when the combine really reverses, stops or changes heading
    local flag = nil
    if AutoDrive:getIsCPTurning(combine) then
        flag = "Courseplay en virage"
    else
        local rootVehicle = combine.getRootVehicle ~= nil and combine:getRootVehicle() or nil
        if rootVehicle ~= nil and rootVehicle.getAIFieldWorkerIsTurning ~= nil and rootVehicle:getAIFieldWorkerIsTurning() then
            flag = "helper en virage"
        end
    end
    if flag ~= nil and not chopper then
        -- combine harvester: the flag alone starts the wait (behaviour before the forage harvester changes)
        return flag
    end
    local prefix = flag ~= nil and (flag .. ", ") or ""
    if FollowCombineTask.isCombineReversing(combine) then
        return prefix .. "marche arriere"
    end
    -- 26/10 06:38-06:39 (7R stopped twice "attend, l'ensileuse fait demi-tour" on a jog and along an island
    -- edge): Courseplay's turning flag also rises on a jog or a row finish, the harvester turning 8-11 deg. Only its
    -- own turn points (red/green) with a real heading change count; the rest is driven through
    if flag == "Courseplay en virage" and CombineUnloaderMode ~= nil and CombineUnloaderMode.getCpRowTurn ~= nil then
        local row = CombineUnloaderMode.getCpRowTurn(combine)
        if row ~= nil then
            if not row.turning then
                return nil, string.format("%s (pas dans son demi-tour, point rouge %s)", flag, row.dist ~= nil and string.format("a %.0f m", row.dist) or "absent")
            end
            if row.deg ~= nil and not row.headland and row.deg < FollowCombineTask.CP_TURN_WAIT_MIN_DEG then
                return nil, string.format("%s (virage de %.0f deg seulement entre ses points, decrochement)", flag, row.deg)
            end
        end
    end
    -- forage harvester standing still in a straight line: it waits for the trailer, not a turn
    if (combine.lastSpeedReal or 0) < FollowCombineTask.TURN_STOPPED_SPEED and not chopper then
        return prefix .. "arretee"
    end
    if samples ~= nil and #samples > 0 then
        local diff = math.abs(heading - samples[1]) % 360
        if diff > 180 then
            diff = 360 - diff
        end
        if diff > FollowCombineTask.TURN_END_MAX_HEADING_CHANGE then
            return prefix .. string.format("tourne de %.0f deg", diff)
        end
    end
    return nil, flag ~= nil and (flag .. " (moissonneuse en ligne droite, cap stable)") or nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Outils
-- ------------------------------------------------------------------------------------------------------------
function FollowCombineTask.getCombineHeading(combine)
    local dx, _, dz = localDirectionToWorld(combine.components[1].node, 0, 0, 1)
    if combine.ad ~= nil and combine.ad.isReverseAttached then
        dx, dz = -dx, -dz
    end
    return math.deg(math.atan2(dx, dz))
end

-- combine driving backwards
function FollowCombineTask.isCombineReversing(combine)
    local movingDirection = combine.movingDirection or 1
    if combine.ad ~= nil and combine.ad.isReverseAttached then
        movingDirection = -movingDirection
    end
    return (combine.lastSpeedReal or 0) * movingDirection <= -0.00005
end

-- true when the harvester has been standing for PASS_BY_STOPPED ms
function FollowCombineTask.combineStandsStill(combine)
    local timer = combine ~= nil and combine.ad ~= nil and combine.ad.noMovementTimer or nil
    return timer ~= nil and timer.elapsedTime ~= nil and timer.elapsedTime > FollowCombineTask.PASS_BY_STOPPED
end

-- appelée par update() en STATE_WAIT_FOR_COMBINE_TO_PASS_BY ; vrai = update() s'arrête là
function FollowCombineTask:checkPassByStandingCombine()
    -- 27/10 18:48 (endless wait): a harvester standing still will not pass by
    if FollowCombineTask.combineStandsStill(self.combine) then
        print(string.format("[AD-Poursuite] %s: ensileuse arretee face a moi, inutile d'attendre qu'elle me depasse, je cherche ma route", FollowCombineTask.getLogName(self.vehicle)))
        self.stayOnField = true
        self.state = FollowCombineTask.STATE_WAIT_BEFORE_FINISH
        return true
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Journal
-- ------------------------------------------------------------------------------------------------------------
function FollowCombineTask.getLogName(vehicle)
    return vehicle ~= nil and vehicle.getName ~= nil and vehicle:getName() or "?"
end

-- once per reverse: why the unloader backs up (23/10: it went back and forth without a log)
function FollowCombineTask:logReverse(what)
    if self.reverseLogged == self.reverseStartLocation then
        return
    end
    self.reverseLogged = self.reverseStartLocation
    print(string.format("[AD-Poursuite] %s: %s (%.0f m de l'ensileuse, angle avec elle %.0f deg, angle vers elle %.0f deg, ensileuse en virage %s)",
        FollowCombineTask.getLogName(self.vehicle), what, AutoDrive.getDistanceBetween(self.vehicle, self.combine), self.angleToCombineHeading or -1,
        self.angleToCombine or -1, tostring(AutoDrive.combineIsTurning(self.combine))))
end
