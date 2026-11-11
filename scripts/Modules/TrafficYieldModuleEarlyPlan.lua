-- ============================================================================================================
-- FarmPilot : TrafficYieldModuleEarlyPlan.lua
-- Complément de TrafficYieldModule.lua (croisement face à face) : le plan d'avance (early yield). Dès qu'un
-- véhicule en face est vu sur le trajet, celui qui cède cherche une place au bord de la route devant lui, sur son
-- propre trajet, et s'y range d'avance ; l'autre ne s'arrête pas.
--
-- Règles du chemin à double sens (28/10) :
-- 1. Le chemin à double sens est prioritaire pour en sortir : celui qui est dedans, à moins de EXIT_PRIORITY_DISTANCE m
--    de sa sortie, sort d'abord ; celui sur la route attend avant la ligne rouge (sinon à sa ligne d'attente), ou prend
--    un détour s'il perd moins de temps qu'à attendre.
-- 2. Plus loin, ou personne dedans : les deux entrent, le croisement est prévu : chacun cherche une place dans sa partie
--    du chemin ; une place : celui-là se range, l'autre continue ; deux : se range l'attelage au plus petit rayon de
--    braquage. Aucune place : celui encore dehors attend à son bout ; tous deux dedans : ils s'arrêtent et celui qui
--    manœuvre le moins recule (plan classique). Pas de détour dans ce cas.
-- La portion face à face est prolongée en arrière jusqu'à la vraie entrée du chemin (S4/S6, 28/10) ; arrêté à sa ligne,
-- sur la portion rouge ou à moins de ENTRY_INSIDE m après l'entrée, un véhicule compte encore comme dehors (30/10).
--
-- Branché par : updateAnticipation (startEarlyPlan), handOverTo ; la situation (getOncomingGap, findRedLineBefore)
-- sert aussi à TrafficYieldModuleApproach.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Situation face au chemin à double sens
-- ------------------------------------------------------------------------------------------------------------
-- S4/S6 (28/10, Magnum 7220 / 6205 TTV on the 270 m farm track): the head-on section is only searched in the
-- first ANTICIPATION_DISTANCE m of both routes, so on a long single track it began in the middle of the track (the 6205
-- had just left the farm): the wait line, the turn-off and "partner out of the single track" were all measured from
-- there (the plan ended while the 6205 was still 100 m up the track). The section is extended backwards along my route
-- to the real entrance of the single track (two-way links), never behind me
function ADTrafficYieldModule:extendSectionToEntrance(mine, section)
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if mine == nil or section == nil or section[1] == nil or wayPoints == nil or currentIndex == nil then
        return mine, section, false
    end
    local first = nil
    for i = math.max(1, currentIndex), #wayPoints do
        if wayPoints[i] ~= nil and wayPoints[i].id == section[1] then
            first = i
            break
        end
    end
    if first == nil then
        return mine, section, false
    end
    local k = first
    while k - 1 >= math.max(1, currentIndex - 1) and wayPoints[k - 1] ~= nil and wayPoints[k - 1].id ~= nil
        and ADTrafficYieldModule.isTwoWay(wayPoints[k - 1].id, wayPoints[k].id) do
        k = k - 1
    end
    -- the two-way stretch reaches the point behind me: I am already on the single track
    local inside = k < currentIndex
    -- 30/10 (7R 350 held at its red line counted inside, the 942 Vario 75 m from the exit had to pull over;
    -- rules: within 120 m the one in the track comes out first, the road one checks the track before the red line):
    -- held at my line, on the red portion, or less than ENTRY_INSIDE m past the start of the track = still outside
    if inside then
        local c = self.vehicle.ad.intersection
        if c ~= nil and c.committed == nil and (c.holding or c.waited) then
            inside = false
        elseif ADIntersectionModule ~= nil and ADIntersectionModule.isIntersectionPoint ~= nil
            and (ADIntersectionModule.isIntersectionPoint(wayPoints[currentIndex]) or ADIntersectionModule.isIntersectionPoint(wayPoints[currentIndex - 1])) then
            inside = false
        else
            -- the real start of the two-way stretch behind me (further back than the previous point)
            local start = k
            while start - 1 >= 1 and start > currentIndex - 30 and wayPoints[start - 1] ~= nil and wayPoints[start - 1].id ~= nil
                and wayPoints[start].id ~= nil and ADTrafficYieldModule.isTwoWay(wayPoints[start - 1].id, wayPoints[start].id) do
                start = start - 1
            end
            if start > 1 and start >= currentIndex - 30 then
                local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
                local past = 0
                for i = start, currentIndex - 2 do
                    past = past + MathUtil.vector2Length(wayPoints[i + 1].x - wayPoints[i].x, wayPoints[i + 1].z - wayPoints[i].z)
                    if past >= ADTrafficYieldModule.ENTRY_INSIDE then
                        break
                    end
                end
                local last = wayPoints[currentIndex - 1]
                if past < ADTrafficYieldModule.ENTRY_INSIDE and last ~= nil then
                    past = past + MathUtil.vector2Length(x - last.x, z - last.z)
                end
                if past < ADTrafficYieldModule.ENTRY_INSIDE then
                    inside = false
                end
            end
        end
    end
    k = math.max(k, currentIndex)
    if k == first then
        return mine, section, inside
    end
    local extended = {}
    for i = k, first - 1 do
        table.insert(extended, wayPoints[i].id)
    end
    for _, id in ipairs(section) do
        table.insert(extended, id)
    end
    local x, _, z = ADTrafficYieldModule.getPosition(self.vehicle)
    local distance, lastX, lastZ = 0, x, z
    for i = math.max(1, currentIndex), k do
        local wp = wayPoints[i]
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
    end
    return distance, extended, inside
end

function ADTrafficYieldModule:getOncomingGap(other)
    if not ADTrafficYieldModule.isAdVehicleUsable(other) then
        return nil
    end
    local myList, myDist = ADTrafficYieldModule.collectRouteAhead(self.vehicle, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    local otherList, otherDist = ADTrafficYieldModule.collectRouteAhead(other, ADTrafficYieldModule.ANTICIPATION_DISTANCE)
    local mine, da, section = ADTrafficYieldModule.findHeadOnSection(self.vehicle, myList, myDist, other, otherList, otherDist)
    if mine == nil then
        return nil
    end
    local gap = mine + da
    local inside
    mine, section, inside = self:extendSectionToEntrance(mine, section)
    return gap, mine, section, inside
end

-- where I am against the two-way track I share with 'other': distance to its entrance on my route, inside or not,
-- distance of the other one to that entrance along its route (its exit), my arrival time at the track
function ADTrafficYieldModule:getTrackSituation(other)
    local gap, mine, section, inside = self:getOncomingGap(other)
    if gap == nil or mine == nil or section == nil or section[1] == nil then
        return nil
    end
    local otherToEntrance = ADTrafficYieldModule.getRouteDistanceTo(other, section[1], 600) or math.max(0, gap - mine)
    local front = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local speed = math.max(ADTrafficYieldModule.getSpeedKmh(self.vehicle), ADTrafficYieldModule.S4_MIN_SPEED) / 3.6
    return {
        gap = gap,
        mine = mine,
        section = section,
        inside = inside == true,
        otherToEntrance = otherToEntrance,
        arrival = inside and 0 or math.max(0, mine - front) / speed
    }
end

-- 28/10 (the track is checked before driving onto the red line; someone in it: stop at the point before the red line):
-- distance along my route to the first point of the red (Intersection)
-- section that leads into the two-way track 'sectionDistance' m ahead (it ends at most RED_LINE_BEFORE_TRACK m before
-- the track, or overlaps it), nil without one, -1 when that red section has already begun behind me (my front is on it)
function ADTrafficYieldModule:findRedLineBefore(sectionDistance)
    if ADIntersectionModule == nil or ADIntersectionModule.isIntersectionPoint == nil or sectionDistance == nil then
        return nil
    end
    local wayPoints, currentIndex = self.vehicle.ad.drivePathModule:getWayPoints()
    if wayPoints == nil or currentIndex == nil then
        return nil
    end
    local lastX, _, lastZ = ADTrafficYieldModule.getPosition(self.vehicle)
    local distance = 0
    local redStart, redEnd = nil, nil
    -- a red section already begun behind me
    if wayPoints[currentIndex - 1] ~= nil and ADIntersectionModule.isIntersectionPoint(wayPoints[currentIndex - 1]) then
        redStart = -1
    end
    local found = nil
    for i = math.max(1, currentIndex), #wayPoints do
        local wp = wayPoints[i]
        if wp == nil then
            break
        end
        distance = distance + MathUtil.vector2Length(wp.x - lastX, wp.z - lastZ)
        lastX, lastZ = wp.x, wp.z
        if distance > sectionDistance + 15 then
            break
        end
        if ADIntersectionModule.isIntersectionPoint(wp) then
            redStart = redStart or distance
            redEnd = distance
        elseif redStart ~= nil then
            -- end of a red section: keep the last one before the track
            if redEnd >= sectionDistance - ADTrafficYieldModule.RED_LINE_BEFORE_TRACK then
                found = redStart
            end
            redStart, redEnd = nil, nil
        end
    end
    if redStart ~= nil and redEnd >= sectionDistance - ADTrafficYieldModule.RED_LINE_BEFORE_TRACK then
        found = redStart
    end
    return found
end

-- ------------------------------------------------------------------------------------------------------------
-- Démarrage du plan d'avance
-- ------------------------------------------------------------------------------------------------------------
-- a spot in my part of the two-way track for the planned crossing with 'other' (driving side, SPOT_MOUTH_CLEAR m from the
-- mouths, the other whole train passes beside), searched ahead of me up to the other one (28/10; it
-- stops before the end of my spot if needed); nil without one
function ADTrafficYieldModule:searchCrossingSpot(other, situation)
    local savedPartner = self.partner
    self.partner = other
    self.spotTwoWayOnly = true
    local myFront = ADTrafficYieldModule.getTrainExtents(self.vehicle)
    local otherFront = ADTrafficYieldModule.getTrainExtents(other)
    local maxAhead = situation.gap - myFront - otherFront - ADTrafficYieldModule.SPOT_CLEARANCE
    local spot = nil
    if maxAhead > 10 then
        local ok, result = FarmPilotCall(self.searchSpotBySides, self, maxAhead, true)
        if ok then
            spot = result
        else
            Logging.error("[AD] ADTrafficYieldModule: crossing spot search failed: %s", tostring(result))
        end
    end
    self.spotTwoWayOnly = nil
    self.partner = savedPartner
    return spot
end

-- the plan in which 'yielder' gives way (waits at its end or pulls over in the track) and 'priority' drives on
function ADTrafficYieldModule.createEarlyPlan(yielder, priority, options)
    options = options or {}
    ADTrafficYieldModule.measureTrain(yielder)
    ADTrafficYieldModule.measureTrain(priority)

    local plan = {
        mode = "early",
        pairKey = ADTrafficYieldModule.getPairKey(yielder, priority),
        firstReverser = priority,
        reverser = priority, -- the vehicle that drives on (same role as the reverser once the other is parked)
        parker = yielder,
        startTime = g_time,
        parkSpot = options.parkSpot,
        reverserMayStop = true,
        reverserAtLimit = false,
        parked = false,
        passed = false,
        hidden = false,
        exitWait = options.exitWait, -- 28/10: I wait before the two-way track (red line, wait line)
        crossing = options.crossing, -- 28/10: crossing planned inside the two-way track, I pull over in my spot
        spotTwoWayOnly = options.crossing
    }
    if options.crossing then
        plan.waitBeforeSection = false -- I drive into the track to my spot
    end
    local yModule = yielder.ad.trafficYieldModule
    local pModule = priority.ad.trafficYieldModule
    yModule:log("EARLY plan: I %s for %s", options.crossing and "pull over in the two-way track" or "wait before the two-way track", ADTrafficYieldModule.getName(priority))
    -- 30/10 (B): already parked aside for this same vehicle (the plan ended too early): I stay where I am
    local trace = yModule.parkTrace
    local stayParked = options.crossing and trace ~= nil and trace.partner == priority and g_time - trace.time < 60000
        and yModule:isOffMyRoute(1.5)
    yModule:reset()
    pModule:reset()
    yModule.plan, yModule.partner = plan, priority
    pModule.plan, pModule.partner = plan, yielder
    if stayParked then
        plan.parkSpot = trace.spot
        plan.parked = true
        yModule.alignmentDone = true
        print(string.format("[AD-Croise] %s: deja gare pour %s, je reste a ma place", ADTrafficYieldModule.getName(yielder), ADTrafficYieldModule.getName(priority)))
        yModule:setState(ADTrafficYieldModule.STATE_PARKER_WAIT)
    else
        yModule:setState(ADTrafficYieldModule.STATE_YIELDER_APPROACH)
    end
    pModule:setState(ADTrafficYieldModule.STATE_PRIORITY_APPROACH)
    return plan
end

-- 28/10 (traffic rules of the two-way track):
-- 1. the two-way track has priority to come out: the one inside, less than EXIT_PRIORITY_DISTANCE m from its exit, comes
--    out first; the one on the road waits before the red line (else at its wait line), or takes a detour if it loses less
--    time than waiting
-- 2. farther, or nobody inside yet: both drive in, the crossing is planned: each one looks for a spot in its part of the
--    track; one spot: that one pulls over, the other one drives on; two: the smaller turning radius of the whole train
--    pulls over. No spot at all: the one still outside waits at its end (no manoeuvre at all); both inside: they stop and
--    the one that manoeuvres the least reverses (standard plan). No detour in this case (18:19)
-- (the first one at the track no longer goes first: S4 of 28/10 17:01 is replaced by these rules)
-- Returns true when a plan started or a detour was taken
function ADTrafficYieldModule.startEarlyPlan(vehicleA, vehicleB)
    local mA, mB = vehicleA.ad.trafficYieldModule, vehicleB.ad.trafficYieldModule
    local nameA, nameB = ADTrafficYieldModule.getName(vehicleA), ADTrafficYieldModule.getName(vehicleB)
    local sA = mA:getTrackSituation(vehicleB)
    local sB = mB:getTrackSituation(vehicleA)
    if sA == nil or sB == nil then
        -- one of both no longer sees the shared stretch: the one with no trailer gives way, as before
        local scoreA = ADTrafficYieldModule.getPriorityScore(vehicleA)
        local scoreB = ADTrafficYieldModule.getPriorityScore(vehicleB)
        local yielder = (scoreA < scoreB or (scoreA == scoreB and (vehicleA.id or 0) < (vehicleB.id or 0))) and vehicleA or vehicleB
        ADTrafficYieldModule.createEarlyPlan(yielder, yielder == vehicleA and vehicleB or vehicleA, {})
        return true
    end

    -- rule 1: the one inside comes out first when it is close to its exit
    local outside, inside, sOut, sIn = nil, nil, nil, nil
    if sB.inside and not sA.inside then
        outside, inside, sOut, sIn = vehicleA, vehicleB, sA, sB
    elseif sA.inside and not sB.inside then
        outside, inside, sOut, sIn = vehicleB, vehicleA, sB, sA
    end
    if outside ~= nil and sOut.otherToEntrance <= ADTrafficYieldModule.EXIT_PRIORITY_DISTANCE then
        local outName, inName = ADTrafficYieldModule.getName(outside), ADTrafficYieldModule.getName(inside)
        -- time I would lose waiting: until the whole train coming out is past the entrance, minus my own way to it
        local inSpeed = math.max(ADTrafficYieldModule.getSpeedKmh(inside) / 3.6, 2)
        local clearTime = (sOut.otherToEntrance + ADTrafficYieldModule.getTotalLength(inside) + ADTrafficYieldModule.EXIT_ROOM) / inSpeed
        local lost = math.max(0, clearTime - sOut.arrival)
        local roadSpeed = math.max(ADTrafficYieldModule.getSpeedKmh(outside), ADTrafficYieldModule.DETOUR_ROAD_SPEED) / 3.6
        print(string.format("[AD-Croise] %s: %s sort du chemin a double sens dans %.0f m (moins de %d m) : j'attends avant d'entrer (environ %.0f s d'attente)",
            outName, inName, sOut.otherToEntrance, ADTrafficYieldModule.EXIT_PRIORITY_DISTANCE, lost))
        local maxExtra = lost * roadSpeed
        if maxExtra > 5 then
            local ok, extra = outside.ad.trafficYieldModule:tryDetour(inside, maxExtra)
            if ok then
                print(string.format("[AD-Croise] %s: detour de %.0f m, moins de temps perdu que d'attendre %.0f s que %s sorte du chemin",
                    outName, extra or 0, lost, inName))
                return true
            end
        end
        ADTrafficYieldModule.createEarlyPlan(outside, inside, {exitWait = true})
        return true
    end

    -- rule 2: crossing planned inside the two-way track
    ADTrafficYieldModule.measureTrain(vehicleA)
    ADTrafficYieldModule.measureTrain(vehicleB)
    local spotA = mA:searchCrossingSpot(vehicleB, sA)
    local spotB = mB:searchCrossingSpot(vehicleA, sB)
    local yielder, spot, why
    if spotA ~= nil and spotB ~= nil then
        local rA = ADTrafficYieldModule.getTrainRadius(vehicleA)
        local rB = ADTrafficYieldModule.getTrainRadius(vehicleB)
        if math.abs(rA - rB) > ADTrafficYieldModule.RADIUS_TIE then
            yielder = rA < rB and vehicleA or vehicleB
        else
            local lA, lB = ADTrafficYieldModule.getTotalLength(vehicleA), ADTrafficYieldModule.getTotalLength(vehicleB)
            if math.abs(lA - lB) > 1 then
                yielder = lA < lB and vehicleA or vehicleB
            else
                yielder = (vehicleA.id or 0) < (vehicleB.id or 0) and vehicleA or vehicleB
            end
        end
        spot = yielder == vehicleA and spotA or spotB
        why = string.format("place des deux cotes, %s se gare (attelage : rayon %.1f m contre %.1f m)", ADTrafficYieldModule.getName(yielder),
            yielder == vehicleA and rA or rB, yielder == vehicleA and rB or rA)
    elseif spotA ~= nil or spotB ~= nil then
        yielder = spotA ~= nil and vehicleA or vehicleB
        spot = spotA or spotB
        why = string.format("place pour %s seulement", ADTrafficYieldModule.getName(yielder))
    end
    if yielder ~= nil then
        local priority = yielder == vehicleA and vehicleB or vehicleA
        print(string.format("[AD-Croise] %s et %s : croisement prevu dans le chemin a double sens, %s a %.0f m (%s) : %s se gare, %s passe",
            nameA, nameB, why, spot.entryDistance or 0, spot.side == "left" and "gauche" or "droite", ADTrafficYieldModule.getName(yielder),
            ADTrafficYieldModule.getName(priority)))
        -- 30/10: who counted as inside, distances to the exit, where the spot is (to check a log line against the map)
        print(string.format("[AD-Croise]   %s dedans=%s (l'autre a %.0f m de l'entree), %s dedans=%s (l'autre a %.0f m), place entree %.0f,%.0f fin %.0f,%.0f decalage %.1f m",
            nameA, tostring(sA.inside), sA.otherToEntrance or -1, nameB, tostring(sB.inside), sB.otherToEntrance or -1,
            spot.entryX or 0, spot.entryZ or 0, spot.finalX or 0, spot.finalZ or 0, spot.lateral or 0))
        ADTrafficYieldModule.createEarlyPlan(yielder, priority, {crossing = true, parkSpot = spot})
        return true
    end

    -- no spot in the track for either
    if not sA.inside or not sB.inside then
        local waiter
        if not sA.inside and sB.inside then
            waiter = vehicleA
        elseif not sB.inside and sA.inside then
            waiter = vehicleB
        else
            waiter = sA.arrival > sB.arrival and vehicleA or vehicleB -- both outside: the later one at the track
        end
        local other = waiter == vehicleA and vehicleB or vehicleA
        print(string.format("[AD-Croise] %s et %s : aucune place dans le chemin a double sens : %s attend a son bout (aucune manoeuvre), %s passe",
            nameA, nameB, ADTrafficYieldModule.getName(waiter), ADTrafficYieldModule.getName(other)))
        ADTrafficYieldModule.createEarlyPlan(waiter, other, {exitWait = true})
        return true
    end
    -- both inside without any spot: both stop at the safe distance (anticipation), then the standard plan makes the one
    -- that manoeuvres the least reverse (rule 7)
    print(string.format("[AD-Croise] %s et %s : tous deux dans le chemin a double sens, aucune place devant : ils s'arretent, celui qui manoeuvre le moins recule",
        nameA, nameB))
    local key = ADTrafficYieldModule.getPairKey(vehicleA, vehicleB)
    local history = ADTrafficYieldModule.pairHistory[key] or {failures = 0, time = g_time}
    history.earlyTried = g_time
    ADTrafficYieldModule.pairHistory[key] = history
    return false
end
