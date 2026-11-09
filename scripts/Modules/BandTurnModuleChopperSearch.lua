-- ============================================================================================================
-- FarmPilot : BandTurnModuleChopperSearch.lua
-- Complément de BandTurnModule.lua, ENSILEUSE seulement : construction des manœuvres du demi-tour dans la bande et
-- recherche de la moins chère. Partie pure : carte locale et géométrie données, aucun appel au jeu (testée hors du
-- jeu).
--
-- Manœuvres essayées (variantes de longueurs, les deux sens, la carte « champ seul » et la carte avec l'herbe) :
-- - bout de rang (23/10) : demi-tour en avant, ou recul tout droit puis demi-tour en avant ; aucune culture sous
--   l'attelage ; côté de l'ensileuse préféré ;
-- - manœuvre en Y (25/10) : avance en biais, long recul droit le long de la diagonale, demi-tour en avant ;
-- - manœuvre en plusieurs temps : S vers le bord de la culture, recul de la remorque dans la culture, en avant en
--   butée vers le nouveau cap, encore un recul si la bande est trop courte (3, 5 ou 7 temps, 23/10), redressage ;
-- - nez dans la culture ou trop près du bord, d'un obstacle (30/10) : recul d'abord.
-- Le coût compte les longueurs (recul plus cher), les changements de sens, la culture sous l'attelage (réglage
-- AutoDrive « éviter la culture » : strict refusé, actif compté, inactif ignoré).
--
-- Branché par : BandTurnModule.lua (ADBandTurn.update : newSearch, stepSearch).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
local PI = math.pi

-- The manoeuvre, built step by step like a driver does it (the trailer goes back into the crop):
--   1. forward: if needed first sideways to the crop edge, then an S: away from the crop, then the nose toward the
--      crop (the front wheels never enter it)
--   2. reverse: the trailer swings back into the crop until it stands across the strip, tail in the crop
--   3. forward at full lock toward the new heading; if the strip is too short: reverse a little, forward again
--   4. forward until the trailer is straight behind and out of the crop
-- Every 0.5 m the whole train is checked on the local map (field, crop, obstacles). Variants of step 1 (lengths of
-- the S) are tried, the cheapest complete one is kept.
ADBandTurn.STEP = 0.5                   -- m per simulated step
ADBandTurn.SHIFT = {0, 3, 5, 7}         -- m of each arc of a first S moving the train sideways to the crop edge
ADBandTurn.BACK_OUT_EXTRA = {0, 3, 6}     -- m reversed beyond the point where the front wheels leave the crop (nose in it)
-- 30/10 (MF 7S.210 nose 2 m from the hedge: "S bloque", 432 tries): nose close to the field border, an obstacle
-- or the crop ahead, "back first" variants too (straight or curved back, then the S)
ADBandTurn.NOSE_PROBE = 5                  -- m straight on checked in front of the train
ADBandTurn.NOSE_BACK = {4, 8, 12}          -- m backed first
ADBandTurn.S_OUT = {0, 2, 4, 6, 8, 10}  -- m turning away from the crop
ADBandTurn.S_IN = {0, 2, 4, 6, 8, 10, 12} -- m turning toward the crop
ADBandTurn.REVERSE_MAX = 25             -- m per reverse leg
ADBandTurn.FORWARD_MAX = 30             -- m per forward leg
ADBandTurn.REVERSE_ARTICULATION = 55    -- deg kept at most while reversing
ADBandTurn.MAX_CYCLES = 3               -- reverse / forward cycles after the first: 3, 5 or 7 legs (23/10)
ADBandTurn.EDGE_MARGIN = 0.5              -- m kept free beyond the end of each reverse leg (crop for the tractor, edge, obstacle)
ADBandTurn.STALL_LENGTH = 3             -- m reversed without gaining anything on the turn: the leg ends
ADBandTurn.STRAIGHTEN_LENGTH = 25       -- m driven at most to straighten the trailer at the end
ADBandTurn.VARIANTS_PER_FRAME = 6
ADBandTurn.CROP_SCAN = 12               -- m beside the train to find the crop side
-- end of row (23/10, drawing): 1) one forward U-turn (blue), 2) straight back first, then the forward
-- U-turn (red), 3) only then the 3-point manoeuvres (green). Never in the crop, never out of the field
ADBandTurn.UTURN_LEAD = {0, 3, 6}                  -- m straight on before the forward U-turn
ADBandTurn.UTURN_BACK = {4, 8, 12, 16, 20, 25}     -- m straight back before it (red)
ADBandTurn.UTURN_SWING = {0, 3, 5, 8, 11}         -- m first turned the other way (left to go right, wider circle)
ADBandTurn.UTURN_OTHER_SIDE_COST = 15              -- m added when turning away from the preferred side (harvester side)
ADBandTurn.UTURN_BONUS = 20                        -- m taken off U-turn variants: preferred over the 3-point ones
-- Y manoeuvre (25/10 19:14, drawing: red forward on a diagonal, blue long straight reverse along it, green
-- forward turn into the row)
ADBandTurn.Y_SWING = {0, 4, 8, 12}                 -- m of arc turned the other way first (the diagonal)
ADBandTurn.Y_LEAD = {0, 6, 12}                     -- m straight on along the diagonal
ADBandTurn.Y_BACK = {15, 25, 35, 50}               -- m straight back along the diagonal
ADBandTurn.Y_MAP_RADIUS = 50                       -- m: the long reverse needs the room on the local map
ADBandTurn.Y_GAIN = 2                              -- articulation wanted per rad of trailer heading error while backing
ADBandTurn.Y_MAX_ARTICULATION = math.rad(30)       -- rad, at most

-- ------------------------------------------------------------------------------------------------------------
-- Outils de construction (un pas, un temps, un arc, un recul)
-- ------------------------------------------------------------------------------------------------------------
local function try(search, pose, ds, k)
    local samples = {}
    local p = ADBandTurn.move(search.geo, pose, ds, k, samples)
    if math.abs(ADBandTurn.wrap(p.a - p.b)) > math.rad(ADBandTurn.MAX_ARTICULATION) then
        return nil
    end
    local ok, _, tractorCrop, trailerCrop = ADBandTurn.checkPose(search.map, search.geo, p)
    -- the front wheels never go into the crop, the rear wheels may when the trailer is backed into it. Started with
    -- the nose in the crop (blocked): only reversing out of it, never deeper
    if not ok or (p.tractorFrontCrop > 0 and (ds > 0 or p.tractorFrontCrop > (pose.tractorFrontCrop or 0))) then
        return nil
    end
    p.tractorCrop, p.trailerCrop = tractorCrop, trailerCrop
    return p, samples
end

-- angle turned in the turning sense since the start (rad, -pi/2 .. 3/2 pi)
local function turned(search, a)
    return ADBandTurn.wrap((a - search.start.a) * search.sign + PI / 2) - PI / 2
end

local function newLeg(dir, pose)
    return {dir = dir, points = {}, length = 0, endHeading = pose.a}
end

local function addStep(run, leg, samples, p)
    for _, s in ipairs(samples) do
        leg.points[#leg.points + 1] = s
    end
    leg.length = leg.length + ADBandTurn.STEP
    leg.endHeading = p.a
    run.crop = run.crop + p.trailerCrop
    run.tractorCrop = (run.tractorCrop or 0) + p.tractorCrop
    run.pose = p
end

-- forward with a fixed curvature for a length; false if blocked before
local function forwardArc(search, run, leg, k, length)
    local driven = 0
    while driven < length - 1e-6 do
        local p, samples = try(search, run.pose, ADBandTurn.STEP, k)
        if p == nil then
            return false
        end
        addStep(run, leg, samples, p)
        driven = driven + ADBandTurn.STEP
    end
    return true
end

-- reverse as far as the room allows (23/10: each leg to the edge, EDGE_MARGIN kept): each step the steering
-- that swings the trailer most into the turning sense (tail into the crop), articulation limited. Ends at the edge,
-- or when it gains nothing on the turn for STALL_LENGTH. untilAcross: first reverse (trailer across the strip)
local function reverseLeg(search, run, maxLength, untilAcross)
    local leg = newLeg(-1, run.pose)
    local K = 1 / search.geo.radius
    local stall = 0
    while leg.length < maxLength do
        local best, bestSamples, bestScore = nil, nil, -math.huge
        for _, k in ipairs({-K, -K / 2, 0, K / 2, K}) do
            local p, samples = try(search, run.pose, -ADBandTurn.STEP, k)
            if p ~= nil and try(search, p, -ADBandTurn.EDGE_MARGIN, k) == nil then
                p = nil
            end
            if p ~= nil then
                local art = math.abs(ADBandTurn.wrap(p.a - p.b))
                local prevArt = math.abs(ADBandTurn.wrap(run.pose.a - run.pose.b))
                if art <= math.rad(ADBandTurn.REVERSE_ARTICULATION) or art < prevArt then
                    local score = turned(search, p.b) - turned(search, run.pose.b)
                    if not untilAcross then
                        -- second reverse legs: gain room, keep the heading
                        score = -math.abs(turned(search, p.a) - turned(search, run.pose.a)) * 0.1 + score
                    end
                    score = score - p.trailerCrop * 0.0005 - p.tractorCrop * 0.003
                    if score > bestScore then
                        best, bestSamples, bestScore = p, samples, score
                    end
                end
            end
        end
        if best == nil then
            break
        end
        stall = bestScore <= 0 and stall + ADBandTurn.STEP or 0
        addStep(run, leg, bestSamples, best)
        if math.abs(ADBandTurn.wrap(run.pose.a - search.goal)) <= math.rad(ADBandTurn.GOAL_HEADING / 2) then
            break
        end
        if stall >= ADBandTurn.STALL_LENGTH then
            break
        end
    end
    return leg
end

-- forward at full lock in the turning sense (half lock when full lock is blocked) until the goal heading or blocked
local function forwardTurnLeg(search, run)
    local leg = newLeg(1, run.pose)
    local K = search.sign / search.geo.radius
    while leg.length < ADBandTurn.FORWARD_MAX do
        if math.abs(ADBandTurn.wrap(run.pose.a - search.goal)) <= math.rad(ADBandTurn.GOAL_HEADING / 2) then
            break
        end
        local p, samples = try(search, run.pose, ADBandTurn.STEP, K)
        if p == nil then
            p, samples = try(search, run.pose, ADBandTurn.STEP, K / 2)
        end
        if p == nil then
            break
        end
        addStep(run, leg, samples, p)
    end
    return leg
end

-- nose in the crop: reverse with curvature k until the front wheels are out, then extra meters. false if blocked
local function backOut(search, run, leg, k, extra)
    local after = 0
    while after < extra - 1e-6 or (run.pose.tractorFrontCrop or 0) > 0 do
        if leg.length >= ADBandTurn.REVERSE_MAX then
            return false
        end
        local p, samples = try(search, run.pose, -ADBandTurn.STEP, k)
        if p == nil then
            return false
        end
        addStep(run, leg, samples, p)
        if p.tractorFrontCrop == 0 then
            after = after + ADBandTurn.STEP
        end
    end
    return true
end

-- ------------------------------------------------------------------------------------------------------------
-- Manœuvres : demi-tour en avant, manœuvre en Y, manœuvre en plusieurs temps
-- ------------------------------------------------------------------------------------------------------------
-- forward U-turn at full lock to the goal heading, after a straight lead (> 0) or a straight reverse (< 0) along
-- the own axis. No crop at all under the train. Returns {legs, cost} or nil, reason
function ADBandTurn.buildUTurn(search, straight, swing)
    local K = 1 / search.geo.radius
    local run = {pose = search.start, crop = 0}
    run.pose.trailerCrop = 0
    local legs = {}
    if straight < 0 then
        local leg = newLeg(-1, run.pose)
        -- straight back: each step the steering that keeps the trailer in line and on its heading
        local b0 = run.pose.b
        while leg.length < -straight - 1e-6 do
            local best, bestSamples, bestScore = nil, nil, math.huge
            for _, k in ipairs({-K, -K / 2, -K / 4, 0, K / 4, K / 2, K}) do
                local p, samples = try(search, run.pose, -ADBandTurn.STEP, k)
                if p ~= nil then
                    local score = math.abs(ADBandTurn.wrap(p.a - p.b)) + math.abs(ADBandTurn.wrap(p.b - b0))
                    if score < bestScore then
                        best, bestSamples, bestScore = p, samples, score
                    end
                end
            end
            if best == nil then
                return nil, "recul bloque"
            end
            addStep(run, leg, bestSamples, best)
        end
        legs[#legs + 1] = leg
    end
    local leg = newLeg(1, run.pose)
    if straight > 0 and not forwardArc(search, run, leg, 0, straight) then
        return nil, "avance droite bloquee"
    end
    -- swing out the other way first, at full lock: the circle of the U-turn gets wider
    if (swing or 0) > 0 and not forwardArc(search, run, leg, -search.sign * K, swing) then
        return nil, "contre-braquage bloque"
    end
    while math.abs(ADBandTurn.wrap(run.pose.a - search.goal)) > math.rad(ADBandTurn.GOAL_HEADING / 2) do
        if leg.length >= ADBandTurn.FORWARD_MAX * 2 then
            return nil, "demi-tour trop long"
        end
        local p, samples = try(search, run.pose, ADBandTurn.STEP, search.sign * K)
        if p == nil then
            return nil, string.format("demi-tour bloque a %.0f deg", math.deg(turned(search, run.pose.a)))
        end
        addStep(run, leg, samples, p)
    end
    -- straighten the trailer behind
    local driven = 0
    while math.abs(ADBandTurn.wrap(run.pose.a - run.pose.b)) > math.rad(ADBandTurn.GOAL_ARTICULATION) do
        if driven >= ADBandTurn.STRAIGHTEN_LENGTH then
            return nil, "remorque pas redressee"
        end
        local err = ADBandTurn.wrap(search.goal - run.pose.a)
        local p, samples = try(search, run.pose, ADBandTurn.STEP, math.max(-K, math.min(K, err / 4)))
        if p == nil then
            return nil, "redressage bloque"
        end
        addStep(run, leg, samples, p)
        driven = driven + ADBandTurn.STEP
    end
    legs[#legs + 1] = leg
    -- crop under the train: AutoDrive setting avoidFruit (23/10): strict refused, on costed, off ignored
    local cropMode = search.rules ~= nil and search.rules.crop or "strict"
    if cropMode == "strict" and (run.crop > 0 or (run.tractorCrop or 0) > 0) then
        return nil, "culture sous l'attelage"
    end
    local cost = -ADBandTurn.UTURN_BONUS
    if cropMode ~= "off" then
        cost = cost + run.crop * ADBandTurn.TRAILER_CROP_COST + (run.tractorCrop or 0) * ADBandTurn.TRACTOR_CROP_COST
    end
    for _, l in ipairs(legs) do
        cost = cost + l.length * (l.dir < 0 and ADBandTurn.REVERSE_COST or 1) + ADBandTurn.SWITCH_COST
    end
    if search.preferSign ~= nil and search.sign ~= search.preferSign then
        cost = cost + ADBandTurn.UTURN_OTHER_SIDE_COST
    end
    return {legs = legs, cost = cost, crop = 0, uturn = true}
end

-- Y manoeuvre (25/10 19:14): forward at full lock the other way over swing m then straight over lead m (red, a
-- diagonal), straight back along it over back m with the trailer kept in line (blue), forward at full lock to the goal
-- heading and straighten (green). No crop at all under the train (strict). Returns {legs, cost} or nil, reason
function ADBandTurn.buildYTurn(search, lead, swing, back)
    local K = 1 / search.geo.radius
    local run = {pose = search.start, crop = 0}
    run.pose.trailerCrop = 0
    local legs = {}
    -- red
    local leg = newLeg(1, run.pose)
    if (swing or 0) > 0 and not forwardArc(search, run, leg, -search.sign * K, swing) then
        return nil, "Y : avance en biais bloquee"
    end
    if (lead or 0) > 0 and not forwardArc(search, run, leg, 0, lead) then
        return nil, "Y : avance droite bloquee"
    end
    if leg.length > 0 then
        legs[#legs + 1] = leg
    end
    -- blue: straight back along the diagonal (the tractor heading after the red leg). After the arc the trailer still
    -- points the old way and reversing swings it further out: like a driver, the tractor is counter-steered past the
    -- trailer heading (articulation against the error) until the trailer lies on the diagonal, then kept in line
    leg = newLeg(-1, run.pose)
    local a0 = run.pose.a
    while leg.length < back - 1e-6 do
        local pose = run.pose
        local e = ADBandTurn.wrap(a0 - pose.b)
        local wanted = math.max(-ADBandTurn.Y_MAX_ARTICULATION, math.min(ADBandTurn.Y_MAX_ARTICULATION, -ADBandTurn.Y_GAIN * e))
        local aWanted = pose.b + wanted
        local best, bestSamples, bestErr = nil, nil, math.huge
        for _, k in ipairs({-K, -K / 2, -K / 4, 0, K / 4, K / 2, K}) do
            local p, samples = try(search, pose, -ADBandTurn.STEP, k)
            if p ~= nil then
                local err = math.abs(ADBandTurn.wrap(p.a - aWanted))
                if err < bestErr then
                    best, bestSamples, bestErr = p, samples, err
                end
            end
        end
        if best == nil then
            return nil, string.format("Y : recul bloque a %.0f m", leg.length)
        end
        addStep(run, leg, bestSamples, best)
    end
    legs[#legs + 1] = leg
    -- green: full lock to the goal heading, then straighten the trailer
    leg = newLeg(1, run.pose)
    while math.abs(ADBandTurn.wrap(run.pose.a - search.goal)) > math.rad(ADBandTurn.GOAL_HEADING / 2) do
        if leg.length >= ADBandTurn.FORWARD_MAX * 2 then
            return nil, "Y : demi-tour trop long"
        end
        local p, samples = try(search, run.pose, ADBandTurn.STEP, search.sign * K)
        if p == nil then
            return nil, string.format("Y : demi-tour bloque a %.0f deg", math.deg(turned(search, run.pose.a)))
        end
        addStep(run, leg, samples, p)
    end
    local driven = 0
    while math.abs(ADBandTurn.wrap(run.pose.a - run.pose.b)) > math.rad(ADBandTurn.GOAL_ARTICULATION) do
        if driven >= ADBandTurn.STRAIGHTEN_LENGTH then
            return nil, "Y : remorque pas redressee"
        end
        local err = ADBandTurn.wrap(search.goal - run.pose.a)
        local p, samples = try(search, run.pose, ADBandTurn.STEP, math.max(-K, math.min(K, err / 4)))
        if p == nil then
            return nil, "Y : redressage bloque"
        end
        addStep(run, leg, samples, p)
        driven = driven + ADBandTurn.STEP
    end
    legs[#legs + 1] = leg
    local cropMode = search.rules ~= nil and search.rules.crop or "strict"
    if cropMode == "strict" and (run.crop > 0 or (run.tractorCrop or 0) > 0) then
        return nil, "Y : culture sous l'attelage"
    end
    -- half the U-turn bonus: a plain U-turn stays cheaper, the Y beats the 3-point manoeuvres
    local cost = -ADBandTurn.UTURN_BONUS / 2
    if cropMode ~= "off" then
        cost = cost + run.crop * ADBandTurn.TRAILER_CROP_COST + (run.tractorCrop or 0) * ADBandTurn.TRACTOR_CROP_COST
    end
    for _, l in ipairs(legs) do
        cost = cost + l.length * (l.dir < 0 and ADBandTurn.REVERSE_COST or 1) + ADBandTurn.SWITCH_COST
    end
    if search.preferSign ~= nil and search.sign ~= search.preferSign then
        cost = cost + ADBandTurn.UTURN_OTHER_SIDE_COST
    end
    return {legs = legs, cost = cost, crop = 0, uturn = true, yturn = true}
end

-- one variant: sideways shift, S out / in lengths, back-out (nose in the crop: {curvature sign, extra m}).
-- Returns {legs, cost} or nil, reason
function ADBandTurn.buildVariant(search, shift, sOut, sIn, back)
    local K = 1 / search.geo.radius
    local run = {pose = search.start, crop = 0}
    run.pose.trailerCrop = 0
    local legs = {}
    -- 0. nose in the crop: back out first
    if back ~= nil then
        local out = newLeg(-1, run.pose)
        if not backOut(search, run, out, back[1] * search.sign * K, back[2]) then
            return nil, (search.start.tractorFrontCrop or 0) > 0 and "sortie du mais en arriere bloquee" or "recul d'abord bloque"
        end
        if #out.points > 0 then
            legs[#legs + 1] = out
        end
    end
    -- 1. the S
    local leg = newLeg(1, run.pose)
    if not forwardArc(search, run, leg, -search.sign * K, shift) or not forwardArc(search, run, leg, search.sign * K, shift)
        or not forwardArc(search, run, leg, search.sign * K, sOut) or not forwardArc(search, run, leg, -search.sign * K, sIn) then
        return nil, "S bloque"
    end
    if leg.length > 0 then
        legs[#legs + 1] = leg
    end
    -- 2. trailer back into the crop, across the strip
    leg = reverseLeg(search, run, ADBandTurn.REVERSE_MAX, true)
    if leg.length < 1 then
        return nil, "recul impossible"
    end
    local previous = legs[#legs]
    if previous ~= nil and previous.dir < 0 then
        -- straight after the back-out: one reverse leg
        for _, p in ipairs(leg.points) do
            previous.points[#previous.points + 1] = p
        end
        previous.length = previous.length + leg.length
        previous.endHeading = leg.endHeading
    else
        legs[#legs + 1] = leg
    end
    -- 3. forward turn, more cycles if needed
    local cycles = 0
    while true do
        leg = forwardTurnLeg(search, run)
        if leg.length >= ADBandTurn.STEP then
            legs[#legs + 1] = leg
        end
        if math.abs(ADBandTurn.wrap(run.pose.a - search.goal)) <= math.rad(ADBandTurn.GOAL_HEADING) then
            break
        end
        cycles = cycles + 1
        if cycles > ADBandTurn.MAX_CYCLES or leg.length < 1 and cycles > 1 then
            return nil, string.format("cap tourne %.0f deg seulement", math.deg(turned(search, run.pose.a)))
        end
        leg = reverseLeg(search, run, ADBandTurn.REVERSE_MAX, false)
        if leg.length < 1 then
            return nil, string.format("bloque a %.0f deg", math.deg(turned(search, run.pose.a)))
        end
        legs[#legs + 1] = leg
    end
    -- 4. straighten
    leg = legs[#legs]
    if leg.dir < 0 then
        leg = newLeg(1, run.pose)
        legs[#legs + 1] = leg
    end
    local driven = 0
    while math.abs(ADBandTurn.wrap(run.pose.a - run.pose.b)) > math.rad(ADBandTurn.GOAL_ARTICULATION) or run.pose.trailerCrop > ADBandTurn.GOAL_TRAILER_CROP
        or (run.pose.tractorCrop or 0) > 0 do
        if driven >= ADBandTurn.STRAIGHTEN_LENGTH then
            return nil, "remorque pas redressee"
        end
        local err = ADBandTurn.wrap(search.goal - run.pose.a)
        local k = math.max(-K, math.min(K, err / 4))
        local p, samples = try(search, run.pose, ADBandTurn.STEP, k)
        if p == nil then
            p, samples = try(search, run.pose, ADBandTurn.STEP, 0)
        end
        if p == nil then
            return nil, "redressage bloque"
        end
        addStep(run, leg, samples, p)
        driven = driven + ADBandTurn.STEP
    end
    local cost = run.crop * ADBandTurn.TRAILER_CROP_COST + (run.tractorCrop or 0) * ADBandTurn.TRACTOR_CROP_COST
    for _, l in ipairs(legs) do
        cost = cost + l.length * (l.dir < 0 and ADBandTurn.REVERSE_COST or 1) + ADBandTurn.SWITCH_COST
    end
    return {legs = legs, cost = cost, crop = run.crop}
end

-- ------------------------------------------------------------------------------------------------------------
-- Recherche : côté de la culture, nez bloqué, variantes, la moins chère
-- ------------------------------------------------------------------------------------------------------------
-- crop side: +1 crop on the right of the heading, -1 on the left, nil if none near
function ADBandTurn.findCropSide(map, pose)
    local rx, rz = math.cos(pose.a), -math.sin(pose.a)
    local best, bestD = nil, math.huge
    for _, side in ipairs({1, -1}) do
        for d = 0, ADBandTurn.CROP_SCAN, 0.5 do
            local flags = ADBandTurn.mapFlags(map, pose.x + rx * d * side, pose.z + rz * d * side)
            if flags % 4 >= 2 and flags % 2 == 0 then
                if d < bestD then
                    best, bestD = side, d
                end
                break
            end
        end
    end
    return best, bestD
end

-- 30/10: what stops the train straight on within NOSE_PROBE m ("bord du champ", "obstacle", "culture") and
-- the distance driven before it, nil if free
function ADBandTurn.noseBlocked(map, geo, start)
    local pose = start
    local driven = 0
    while driven < ADBandTurn.NOSE_PROBE - 1e-6 do
        local p = ADBandTurn.move(geo, pose, ADBandTurn.STEP, 0)
        local ok, reason = ADBandTurn.checkPose(map, geo, p)
        if not ok then
            return reason == "champ" and "bord du champ" or tostring(reason), driven
        end
        if (p.tractorFrontCrop or 0) > 0 then
            return "culture", driven
        end
        pose = p
        driven = driven + ADBandTurn.STEP
    end
    return nil
end

-- search object: start pose, goal heading (rad); step(n) returns nil while running, then true (self.legs) or false
function ADBandTurn.newSearch(map, geo, start, goalHeading, preferSign, rules)
    local search = {map = map, fieldMap = map.strict or map, geo = geo, start = start, goal = goalHeading, variants = {}, index = 0, expansions = 0, preferSign = preferSign, rules = rules}
    -- U-turn ground: AutoDrive setting restrictToField (23/10): strict = field only, otherwise grass allowed too
    local uturnMap = (rules == nil or rules.field == "strict") and (map.strict or map) or map
    -- end of row: forward U-turns first (field only, both senses, preferred side cheaper)
    if preferSign ~= nil and (start.tractorFrontCrop or 0) == 0 then
        for _, sign in ipairs({preferSign, -preferSign}) do
            for _, swing in ipairs(ADBandTurn.UTURN_SWING) do
                for _, lead in ipairs(ADBandTurn.UTURN_LEAD) do
                    search.variants[#search.variants + 1] = {"uturn", lead, swing, uturnMap, sign}
                end
                for _, back in ipairs(ADBandTurn.UTURN_BACK) do
                    search.variants[#search.variants + 1] = {"uturn", -back, swing, uturnMap, sign}
                end
            end
        end
    end
    -- Y manoeuvre (25/10 19:14): whenever the train is not nose in the crop and the map is wide enough, both senses
    if (start.tractorFrontCrop or 0) == 0 and map.yturn then
        local ySigns = preferSign ~= nil and {preferSign, -preferSign} or {1, -1}
        for _, sign in ipairs(ySigns) do
            for _, swing in ipairs(ADBandTurn.Y_SWING) do
                for _, lead in ipairs(ADBandTurn.Y_LEAD) do
                    for _, back in ipairs(ADBandTurn.Y_BACK) do
                        if swing + lead > 0 or preferSign == nil then
                            search.variants[#search.variants + 1] = {"yturn", lead, swing, uturnMap, sign, back}
                        end
                    end
                end
            end
        end
    end
    ADBandTurn.checkPose(map.strict or map, geo, start)
    local cropSide, distance = ADBandTurn.findCropSide(map, start)
    search.cropSide, search.cropDistance = cropSide, distance
    -- the heading turns away from the crop first (positive angle = turning right), then the other way: no crop
    -- close by (or a blocked side), both senses are tried and the cheapest manoeuvre is kept
    local signs = cropSide ~= nil and {-cropSide, cropSide} or {1, -1}
    -- nose in the crop (blocked against it): back out first, no sideways shift
    local backs, shifts = {false}, ADBandTurn.SHIFT
    if (start.tractorFrontCrop or 0) > 0 then
        backs, shifts = {}, {0}
        for _, kSign in ipairs({-1, 0, 1}) do
            for _, extra in ipairs(ADBandTurn.BACK_OUT_EXTRA) do
                backs[#backs + 1] = {kSign, extra}
            end
        end
    else
        -- 30/10: nose close to the border, an obstacle or the crop: back first as well, no sideways shift then
        local what, distance = ADBandTurn.noseBlocked(map.strict or map, geo, start)
        if what ~= nil then
            search.noseBlocked, search.noseDistance = what, distance
            for _, kSign in ipairs({0, -1, 1}) do
                for _, extra in ipairs(ADBandTurn.NOSE_BACK) do
                    backs[#backs + 1] = {kSign, extra}
                end
            end
        end
    end
    -- end of row: the field setting applies to these manoeuvres too (23/10; narrow strip fallback keeps the grass)
    local maps = {map, map.strict}
    if rules ~= nil and rules.field == "strict" then
        maps = {map.strict or map}
    end
    for _, sign in ipairs(signs) do
        for _, m in ipairs(maps) do
            for _, back in ipairs(backs) do
                for _, shift in ipairs(back and {0} or shifts) do
                    for _, sOut in ipairs(ADBandTurn.S_OUT) do
                        for _, sIn in ipairs(ADBandTurn.S_IN) do
                            search.variants[#search.variants + 1] = {shift, sOut, sIn, m, sign, back or nil}
                        end
                    end
                end
            end
        end
    end
    return search
end

function ADBandTurn.stepSearch(search)
    for _ = 1, ADBandTurn.VARIANTS_PER_FRAME do
        search.index = search.index + 1
        local variant = search.variants[search.index]
        if variant == nil then
            if search.best ~= nil then
                search.legs = search.best.legs
                search.grass = search.best.grass
                search.sign = search.best.sign
                search.uturn = search.best.uturn
                search.yturn = search.best.yturn
                return true
            end
            search.failReason = "aucune manoeuvre possible (" .. tostring(search.lastReason) .. ")"
            return false
        end
        search.expansions = search.expansions + 1
        search.map = variant[4]
        search.sign = variant[5]
        local result, reason
        if variant[1] == "uturn" then
            result, reason = ADBandTurn.buildUTurn(search, variant[2], variant[3])
        elseif variant[1] == "yturn" then
            result, reason = ADBandTurn.buildYTurn(search, variant[2], variant[3], variant[6])
        else
            result, reason = ADBandTurn.buildVariant(search, variant[1], variant[2], variant[3], variant[6])
        end
        if result ~= nil then
            result.grass = variant[4] ~= search.fieldMap
            result.sign = variant[5]
        end
        if result ~= nil and (search.best == nil or result.cost < search.best.cost) then
            search.best = result
        elseif result == nil then
            if (variant[1] == "uturn" or variant[1] == "yturn") and variant[5] == search.preferSign then
                search.uturnReasons = search.uturnReasons or {}
                search.uturnReasons[reason] = (search.uturnReasons[reason] or 0) + 1
            end
            search.lastReason = reason
            search.reasons = search.reasons or {}
            search.reasons[reason] = (search.reasons[reason] or 0) + 1
        end
    end
    return nil
end
