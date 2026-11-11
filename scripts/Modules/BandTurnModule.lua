-- ============================================================================================================
-- FarmPilot : BandTurnModule.lua
-- Demi-tour d'un tracteur et de sa remorque dans une bande étroite (ADBandTurn). Bennes d'ENSILEUSE seulement (la
-- benne roule à côté de l'ensileuse) ; seuls getGeometry et driveLeg (BandTurnModuleDrive.lua) servent aussi à la
-- manœuvre de fin de route de tous les attelages (CornerModuleEndManoeuvre.lua).
--
-- La manœuvre (temps en avant et en arrière, la remorque peut reculer dans la culture debout) est construite sur une
-- carte locale de la bande lue une fois (sol du champ, culture, obstacles comme les arbres et les véhicules), avec la
-- géométrie réelle de l'attelage (essieu du tracteur, point d'attelage, essieu de la remorque) et le rayon de
-- braquage du tracteur. Sert quand la benne est dans le mauvais sens : arrivée de face sur l'ensileuse, ou départ
-- pleine avec la sortie du champ derrière.
--
-- Règles (dates des commentaires) :
-- - 23/10 : bout de rang : demi-tour en avant d'abord, puis recul tout droit et demi-tour en avant, puis seulement
--   les manœuvres en plusieurs temps (3, 5 ou 7) ; jamais dans la culture, jamais hors du champ ; réglages AutoDrive
--   « rester dans le champ » et « éviter la culture » appliqués ; l'ensileuse est laissée hors du calcul ;
-- - 23/10 : plus de long recul à l'aveugle vers la goulotte, la benne attend l'ensileuse là où elle est ;
-- - 24/10 : une fois tourné, la main revient tout de suite à AutoDrive ;
-- - 25/10 : manœuvre en Y (avance en biais, long recul droit, demi-tour en avant) ; cap visé = cap de l'ensileuse
--   arrêtée ; réglages appliqués à tout demi-tour près d'une machine (le demi-tour de secours allait sur l'herbe) ;
-- - 30/10 : nez près du bord du champ, d'un obstacle ou de la culture : variantes « recul d'abord ».
--
-- Ce fichier : la table, les réglages, les outils, la carte locale et le contrôle de l'attelage dessus (partie pure,
-- testée hors du jeu), la lecture de la carte, et le déroulé du demi-tour (start, update). Le reste, dans des
-- fichiers chargés juste après celui-ci (register.lua) :
--   BandTurnModuleChopperSearch.lua  (ensileuse) construction des manœuvres et recherche de la moins chère
--   BandTurnModuleDrive.lua          géométrie de l'attelage réel et conduite d'un temps (aussi CornerModule)
--
-- Branché par : CatchCombinePipeTaskChopperUTurn.lua (tryBandTurn, tryEndRowUTurn, tryWrongWayTurn : canTry,
-- isFacingHarvester, start ; updateBandTurnState : update), ExitFieldTaskStuck.lua (startBandTurn, updateFullStuck),
-- CatchCombinePipeTask:abort et ExitFieldTask:abortFieldExit (abort) ; CornerModule (getGeometry, driveLeg,
-- LEG_PAUSE).
-- ============================================================================================================

ADBandTurn = {}

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADBandTurn.MAP_RADIUS = 32            -- m around the tractor read into the local map
ADBandTurn.END_ROW_MAP_RADIUS = 40    -- m, end-of-row U-turn (reverse then U-turn)
ADBandTurn.MAP_STEP = 0.5             -- m, local map resolution (crop, field)
ADBandTurn.OBSTACLE_STEP = 1          -- m between two obstacle probes
ADBandTurn.MAP_READS_PER_FRAME = 1500
ADBandTurn.OBSTACLE_PROBES_PER_FRAME = 250
ADBandTurn.SUB_STEP = 0.25            -- m, kinematic integration step
ADBandTurn.GOAL_HEADING = 20          -- deg, final heading tolerance
ADBandTurn.GOAL_ARTICULATION = 15     -- deg, trailer nearly straight at the end
ADBandTurn.GOAL_TRAILER_CROP = 4      -- crop samples still tolerated under the trailer at the end
ADBandTurn.MAX_ARTICULATION = 65      -- deg, never jackknife
ADBandTurn.FIELD_TOLERANCE = 1.0      -- m of the body allowed over the allowed ground
ADBandTurn.GRASS_MAX = 4              -- m of grass beyond the field border allowed when nothing stands there;
                                      -- limited: a stream is not seen as an obstacle
ADBandTurn.REVERSE_COST = 1.5
ADBandTurn.SWITCH_COST = 6            -- m added per change of direction
ADBandTurn.TRACTOR_CROP_COST = 2      -- per crop sample under the tractor
ADBandTurn.TRAILER_CROP_COST = 0.3    -- per crop sample under the trailer (allowed)
ADBandTurn.TRACTOR_FRONT_FROM = 1.0   -- m ahead of the rear axle: from there the tractor (front wheels) never enters the crop
ADBandTurn.RADIUS_MARGIN = 1.1        -- planned turning radius = tractor radius * margin
ADBandTurn.RETRY_DISTANCE = 15        -- m: no new try near a failed one ...
ADBandTurn.RETRY_TIME = 120000        -- ms ... for this long
-- driving the manoeuvre
ADBandTurn.SPEED = 5                  -- km/h
ADBandTurn.LOOK_AHEAD = 2             -- m, forward legs (tractor axle): short, less corner cutting
ADBandTurn.LOOK_BEHIND = 4            -- m, reverse legs (trailer axle)
ADBandTurn.LEG_PAUSE = 800            -- ms standing still between two legs
ADBandTurn.FRONT_CROP_TOLERANCE = 2  -- front samples over crop accepted while driving (map cells of 0.5 m)
ADBandTurn.MAX_DEVIATION = 2.5        -- m off the planned line: stop
ADBandTurn.STUCK_TIME = 6000          -- ms without moving: stop
ADBandTurn.MAX_REPLANS = 3            -- new plans from the current pose when off the line
ADBandTurn.STUCK_MOVE = 0.3           -- m: less than this counts as not moving
ADBandTurn.TIMEOUT = 150000           -- ms for the whole manoeuvre
-- joining the harvester after the turn (head-on arrival)
ADBandTurn.JOIN_WAIT_TIME = 60000     -- ms waiting for the harvester to come alongside
ADBandTurn.JOIN_STOPPED_TIME = 5000   -- ms harvester standing still: back up to its pipe
ADBandTurn.JOIN_MAX_REVERSE = 40      -- m
ADBandTurn.JOIN_REVERSE = false       -- back up to the pipe of a standing harvester (off, 23/10)
ADBandTurn.HOLD_HARVESTER_DISTANCE = 35 -- m: Courseplay harvester held while the train turns

-- ------------------------------------------------------------------------------------------------------------
-- Outils (angles, nom pour le journal)
-- Publiés dans la table (ADBandTurn.wrap...) pour BandTurnModuleChopperSearch.lua et BandTurnModuleDrive.lua.
-- ------------------------------------------------------------------------------------------------------------
local atan2 = math.atan2 or math.atan
local PI, TWO_PI = math.pi, 2 * math.pi

local function wrap(a)
    a = (a + PI) % TWO_PI
    if a < 0 then
        a = a + TWO_PI
    end
    return a - PI
end

ADBandTurn.wrap = wrap

local function logName(vehicle)
    return tostring(vehicle ~= nil and vehicle.getName ~= nil and vehicle:getName() or "?")
end
ADBandTurn.logName = logName

-- ------------------------------------------------------------------------------------------------------------
-- Carte locale et contrôle de l'attelage dessus (pur : carte et géométrie données, aucun appel au jeu,
-- testé hors du jeu)
-- ------------------------------------------------------------------------------------------------------------
-- map: {ox, oz, step, n, cells} cells[iz * n + ix + 1] bit flags: 1 off field, 2 crop, 4 obstacle; outside = all
ADBandTurn.OFF_FIELD, ADBandTurn.CROP, ADBandTurn.OBSTACLE = 1, 2, 4

function ADBandTurn.mapFlags(map, x, z)
    local ix = math.floor((x - map.ox) / map.step)
    local iz = math.floor((z - map.oz) / map.step)
    if ix < 0 or iz < 0 or ix >= map.n or iz >= map.n then
        return 7
    end
    return map.cells[iz * map.n + ix + 1] or 7
end

local function hasFlag(flags, flag)
    return flags % (flag * 2) >= flag
end

-- one body (box along heading a around the reference point x, z): ok, crop samples
local function checkBody(map, x, z, a, box)
    local dx, dz = math.sin(a), math.cos(a)
    local nx, nz = dz, -dx
    local crop, frontCrop = 0, 0
    local half = box.half
    local inner = math.max(0, half - ADBandTurn.FIELD_TOLERANCE)
    local nl = math.max(1, math.ceil(box.front - box.rear))
    for i = 0, nl do
        local l = box.rear + (box.front - box.rear) * i / nl
        for k = 1, 4 do
            local w = box.widths[k]
            local px, pz = x + dx * l + nx * w, z + dz * l + nz * w
            local flags = ADBandTurn.mapFlags(map, px, pz)
            if hasFlag(flags, ADBandTurn.OBSTACLE) then
                return false, 0, "obstacle"
            end
            if hasFlag(flags, ADBandTurn.CROP) then
                crop = crop + 1
                if box.frontFrom ~= nil and l > box.frontFrom then
                    frontCrop = frontCrop + 1
                end
            end
            -- field: the body may reach FIELD_TOLERANCE over the border
            local ws = (w >= 0 and 1 or -1) * math.min(math.abs(w), inner)
            if hasFlag(ADBandTurn.mapFlags(map, x + dx * l + nx * ws, z + dz * l + nz * ws), ADBandTurn.OFF_FIELD) then
                return false, 0, "champ"
            end
        end
    end
    return true, crop, nil, frontCrop
end
ADBandTurn.checkBody = checkBody

-- grass next to the field becomes allowed ground up to GRASS_MAX from the field (obstacles are probed separately)
function ADBandTurn.allowGrass(map)
    local n = map.n
    -- the field-only map is kept: the manoeuvre is built on both, the cheaper one wins
    local strict = {ox = map.ox, oz = map.oz, step = map.step, n = n, cells = {}}
    for k = 1, n * n do
        strict.cells[k] = map.cells[k]
    end
    map.strict = strict
    local depth = math.floor(ADBandTurn.GRASS_MAX / map.step + 0.5)
    local dist = {}
    local queue, head = {}, 1
    for k = 1, n * n do
        if not hasFlag(map.cells[k], ADBandTurn.OFF_FIELD) then
            dist[k] = 0
            queue[#queue + 1] = k
        end
    end
    while head <= #queue do
        local k = queue[head]
        head = head + 1
        local d = dist[k]
        if d < depth then
            local ix, iz = (k - 1) % n, math.floor((k - 1) / n)
            for _, o in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) do
                local jx, jz = ix + o[1], iz + o[2]
                if jx >= 0 and jz >= 0 and jx < n and jz < n then
                    local j = jz * n + jx + 1
                    if dist[j] == nil then
                        dist[j] = d + 1
                        queue[#queue + 1] = j
                        map.cells[j] = map.cells[j] - ADBandTurn.OFF_FIELD
                    end
                end
            end
        end
    end
end

function ADBandTurn.prepareBox(box)
    box.widths = {-box.half, -box.half / 3, box.half / 3, box.half}
    return box
end

-- pose: tractor axle x, z, heading a; trailer axle tx, tz, heading b
function ADBandTurn.checkPose(map, geo, pose)
    local ok, tractorCrop, reason, frontCrop = checkBody(map, pose.x, pose.z, pose.a, geo.tractorBox)
    if not ok then
        return false, reason
    end
    pose.tractorFrontCrop = frontCrop
    local ok2, trailerCrop, reason2 = checkBody(map, pose.tx, pose.tz, pose.b, geo.trailerBox)
    if not ok2 then
        return false, reason2
    end
    return true, nil, tractorCrop, trailerCrop
end

-- drives ds (signed) with curvature k from a pose: exact hitch geometry, the trailer axle follows the hitch
function ADBandTurn.move(geo, pose, ds, k, out)
    local x, z, a = pose.x, pose.z, pose.a
    local tx, tz = pose.tx, pose.tz
    local steps = math.max(1, math.ceil(math.abs(ds) / ADBandTurn.SUB_STEP))
    local s = ds / steps
    for _ = 1, steps do
        if math.abs(k) < 1e-6 then
            x, z = x + math.sin(a) * s, z + math.cos(a) * s
        else
            local na = a + k * s
            -- exact arc
            x = x + (math.cos(a) - math.cos(na)) / k
            z = z + (math.sin(na) - math.sin(a)) / k
            a = na
        end
        local hx, hz = x - math.sin(a) * geo.hitch, z - math.cos(a) * geo.hitch
        local vx, vz = hx - tx, hz - tz
        local l = math.sqrt(vx * vx + vz * vz)
        if l > 1e-6 then
            tx, tz = hx - vx / l * geo.trailer, hz - vz / l * geo.trailer
        end
        if out ~= nil then
            out[#out + 1] = {x = x, z = z, tx = tx, tz = tz}
        end
    end
    local hx, hz = x - math.sin(a) * geo.hitch, z - math.cos(a) * geo.hitch
    local b = atan2(hx - tx, hz - tz)
    return {x = x, z = z, a = wrap(a), tx = tx, tz = tz, b = b}
end

-- ------------------------------------------------------------------------------------------------------------
-- Lecture de la carte locale dans le jeu (sur plusieurs images)
-- ------------------------------------------------------------------------------------------------------------
-- the local map, read over several frames: returns true when complete
function ADBandTurn.updateMapReading(bt)
    local map = bt.map
    local pf = PathFinderModule
    local total = map.n * map.n
    local stored = pf.ignoreIsolatedCrop
    pf.ignoreIsolatedCrop = true
    local budget = ADBandTurn.MAP_READS_PER_FRAME
    while bt.readIndex < total and budget > 0 do
        local i = bt.readIndex
        local ix, iz = i % map.n, math.floor(i / map.n)
        local x, z = map.ox + (ix + 0.5) * map.step, map.oz + (iz + 0.5) * map.step
        local flags = 0
        if not pf.getMapOnFieldAt(x, z) then
            flags = flags + ADBandTurn.OFF_FIELD
        end
        local crop = pf.getMapCropAt(x, z)
        if crop ~= nil and crop ~= 0 then
            flags = flags + ADBandTurn.CROP
        end
        map.cells[i + 1] = flags
        bt.readIndex = i + 1
        budget = budget - 1
    end
    pf.ignoreIsolatedCrop = stored
    if bt.readIndex < total then
        return false
    end
    if not bt.grassDone then
        bt.grassDone = true
        ADBandTurn.allowGrass(map)
    end
    -- obstacles: small boxes 0.5 to 2.5 m above the ground (trees, posts, walls, vehicles; the own train ignored)
    local module = bt.vehicle.ad.trafficYieldModule
    if module == nil or module.overlapHit == nil then
        return true
    end
    local step = ADBandTurn.OBSTACLE_STEP
    local np = math.floor(2 * (bt.mapRadius or ADBandTurn.MAP_RADIUS) / step)
    local probes = ADBandTurn.OBSTACLE_PROBES_PER_FRAME
    -- end of row (23/10): the harvester is left out of the calculation, it drives away during the U-turn
    module.overlapIgnoreVehicle = bt.preferSign ~= nil and bt.harvester or nil
    while bt.probeIndex < np * np and probes > 0 do
        local i = bt.probeIndex
        local px, pz = map.ox + (i % np + 0.5) * step, map.oz + (math.floor(i / np) + 0.5) * step
        local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, px, 0, pz)
        if module:overlapHit(px, y + 1.5, pz, 0, step / 2, 1.0, step / 2) then
            bt.obstacles = bt.obstacles + 1
            local per = math.floor(step / map.step + 0.5)
            local bx, bz = math.floor((px - step / 2 - map.ox) / map.step + 0.5), math.floor((pz - step / 2 - map.oz) / map.step + 0.5)
            for jz = bz, bz + per - 1 do
                for jx = bx, bx + per - 1 do
                    if jx >= 0 and jz >= 0 and jx < map.n and jz < map.n then
                        local k = jz * map.n + jx + 1
                        for _, m in ipairs({map, map.strict}) do
                            if not hasFlag(m.cells[k], ADBandTurn.OBSTACLE) then
                                m.cells[k] = m.cells[k] + ADBandTurn.OBSTACLE
                            end
                        end
                    end
                end
            end
        end
        bt.probeIndex = i + 1
        probes = probes - 1
    end
    module.overlapIgnoreVehicle = nil
    return bt.probeIndex >= np * np
end

-- ------------------------------------------------------------------------------------------------------------
-- Fonction principale : déroulé du demi-tour (carte, recherche, conduite des temps)
-- ------------------------------------------------------------------------------------------------------------
function ADBandTurn.canTry(vehicle)
    local last = vehicle.ad.bandTurnFailed
    if last == nil then
        return true
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    return (g_time or 0) - last.t > ADBandTurn.RETRY_TIME or MathUtil.vector2Length(x - last.x, z - last.z) > ADBandTurn.RETRY_DISTANCE
end

-- heading of the train reversed against the harvester (head-on or driving away from it), harvester not turning.
-- minAngle (deg, default 120): angle to its heading from which it counts as behind
function ADBandTurn.isFacingHarvester(vehicle, harvester, maxDistance, minAngle)
    if harvester == nil or harvester.components == nil then
        return false
    end
    if AutoDrive.getDistanceBetween(vehicle, harvester) > (maxDistance or 100) then
        return false
    end
    if AutoDrive.getIsCPTurning ~= nil and AutoDrive:getIsCPTurning(harvester) then
        return false
    end
    -- same angle as the hand-over checks of the unloader mode (degrees)
    local mode = vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode == nil or mode.getAngleToCombineHeading == nil or mode.combine ~= harvester then
        return false
    end
    local angle = mode:getAngleToCombineHeading()
    return angle ~= nil and angle > (minAngle or 120) and angle <= 180, angle
end

-- starts the U-turn (heading reversed). harvester: after the turn, wait for it or back up to its pipe
-- goalHeading (25/10 16:35): heading to reach instead of the reversed one (the heading of a standing harvester)
function ADBandTurn.start(vehicle, reason, harvester, preferSign, goalHeading)
    local name = logName(vehicle)
    local geo, pose = ADBandTurn.getGeometry(vehicle)
    if geo == nil then
        print(string.format("[AD-DemiTour] %s: demi-tour impossible (%s)", name, tostring(pose)))
        ADBandTurn.markFailed(vehicle)
        return false
    end
    -- end of row: wider map, a reverse then a U-turn needs the room (23/10)
    -- with a harvester (25/10 19:14): wider still, the Y manoeuvre backs up to 50 m
    local r = harvester ~= nil and ADBandTurn.Y_MAP_RADIUS or (preferSign ~= nil and ADBandTurn.END_ROW_MAP_RADIUS or ADBandTurn.MAP_RADIUS)
    local map = {ox = pose.x - r, oz = pose.z - r, step = ADBandTurn.MAP_STEP, n = math.floor(2 * r / ADBandTurn.MAP_STEP), cells = {}, yturn = harvester ~= nil}
    vehicle.ad.bandTurn = {
        vehicle = vehicle, geo = geo, start = pose, map = map, readIndex = 0, probeIndex = 0, obstacles = 0,
        phase = "map", reason = reason, harvester = harvester, time = 0, goal = goalHeading ~= nil and wrap(goalHeading) or wrap(pose.a + PI), preferSign = preferSign, mapRadius = r
    }
    -- the AutoDrive settings apply to every turn near a harvester (25/10 19:14: the fallback turn of the catch
    -- task allowed the grass)
    if preferSign ~= nil or harvester ~= nil then
        local field, fruit = AutoDrive.getSetting("restrictToField", vehicle), AutoDrive.getSetting("avoidFruit", vehicle)
        vehicle.ad.bandTurn.rules = {
            field = field == "strict" and "strict" or (field and "on" or "off"),
            crop = fruit == "strict" and "strict" or (fruit and "on" or "off")
        }
    end
    print(string.format("[AD-DemiTour] %s: demi-tour dans la bande (%s) : rayon %.1f m, attelage %.1f m, remorque %.1f m, lecture de la carte",
        name, tostring(reason), geo.radius, geo.hitch, geo.trailer))
    return true
end

-- new map and search from the current pose, the goal heading kept
function ADBandTurn.replan(vehicle, bt, why)
    local geo, pose = ADBandTurn.getGeometry(vehicle)
    if geo == nil then
        return false
    end
    bt.replans = (bt.replans or 0) + 1
    local r = bt.mapRadius or ADBandTurn.MAP_RADIUS
    bt.geo, bt.start = geo, pose
    bt.map = {ox = pose.x - r, oz = pose.z - r, step = ADBandTurn.MAP_STEP, n = math.floor(2 * r / ADBandTurn.MAP_STEP), cells = {}, yturn = bt.harvester ~= nil}
    bt.readIndex, bt.probeIndex, bt.obstacles, bt.grassDone = 0, 0, 0, nil
    bt.legs, bt.search, bt.loggedLeg, bt.stillPos, bt.holdReason = nil, nil, nil, nil, nil
    bt.phase, bt.time = "map", 0
    print(string.format("[AD-DemiTour] %s: %s, nouveau calcul de la fin de la manoeuvre depuis ici (%d/%d), cap vise %.0f deg plus loin",
        logName(vehicle), tostring(why), bt.replans, ADBandTurn.MAX_REPLANS, math.deg(math.abs(wrap(bt.goal - pose.a)))))
    return true
end

function ADBandTurn.markFailed(vehicle)
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    vehicle.ad.bandTurnFailed = {x = x, z = z, t = g_time or 0}
end

function ADBandTurn.stop(vehicle, dt)
    local sdm = vehicle.ad.specialDrivingModule
    sdm:stopVehicle()
    sdm:update(dt)
end

function ADBandTurn.fail(vehicle, dt, why)
    print(string.format("[AD-DemiTour] %s: demi-tour abandonne (%s), retour au comportement habituel", logName(vehicle), tostring(why)))
    ADBandTurn.markFailed(vehicle)
    vehicle.ad.bandTurn = nil
    ADBandTurn.stop(vehicle, dt)
    return "failed"
end

function ADBandTurn.abort(vehicle)
    if vehicle ~= nil and vehicle.ad ~= nil then
        local bt = vehicle.ad.bandTurn
        if bt ~= nil then
            -- the task was stopped from outside (driver stopped, task replaced): say who did it
            print(string.format("[AD-DemiTour] %s: demi-tour interrompu de l'exterieur (phase %s, temps %s/%s, %.0f s)", logName(vehicle),
                tostring(bt.phase), tostring(bt.legIndex), tostring(bt.legs ~= nil and #bt.legs or "?"), bt.time / 1000))
            if printCallstack ~= nil then
                printCallstack()
            end
        end
        vehicle.ad.bandTurn = nil
    end
end

-- "running", "done" (turned), "joined" (turned and alongside the harvester) or "failed"
function ADBandTurn.update(vehicle, dt)
    local bt = vehicle.ad.bandTurn
    if bt == nil then
        return "failed"
    end
    bt.time = bt.time + dt
    local name = logName(vehicle)
    if bt.phase == "map" then
        ADBandTurn.stop(vehicle, dt)
        if ADBandTurn.updateMapReading(bt) then
            -- nose in the crop (blocked against it): the goal is the way the trailer came, reversed
            ADBandTurn.checkPose(bt.map.strict or bt.map, bt.geo, bt.start)
            if (bt.start.tractorFrontCrop or 0) > 0 and bt.replans == nil then
                bt.goal = wrap(bt.start.b + PI)
                print(string.format("[AD-DemiTour] %s: nez dans la culture (articulation %.0f deg), sortie en arriere d'abord, cap vise = inverse de la remorque", name, math.deg(wrap(bt.start.a - bt.start.b))))
            end
            bt.search = ADBandTurn.newSearch(bt.map, bt.geo, bt.start, bt.goal, bt.preferSign, bt.rules)
            if bt.search.noseBlocked ~= nil then
                print(string.format("[AD-DemiTour] %s: nez a %.1f m (%s), manoeuvres avec recul d'abord ajoutees", name, bt.search.noseDistance or 0, bt.search.noseBlocked))
            end
            bt.phase = "search"
        end
        return "running"
    elseif bt.phase == "search" then
        ADBandTurn.stop(vehicle, dt)
        local result = ADBandTurn.stepSearch(bt.search)
        if result == nil then
            return "running"
        elseif result == false then
            return ADBandTurn.fail(vehicle, dt, string.format("%s, %d essais, obstacles vus %d",
                tostring(bt.search.failReason), bt.search.expansions, bt.obstacles))
        end
        bt.legs = bt.search.legs
        local parts = {}
        for _, leg in ipairs(bt.legs) do
            parts[#parts + 1] = string.format("%s %.0f m", leg.dir > 0 and "avant" or "arriere", leg.length)
        end
        print(string.format("[AD-DemiTour] %s: manoeuvre trouvee (%d essais, %d temps : %s)%s, virage a %s, %s, obstacles vus %d", name,
            bt.search.expansions, #bt.legs, table.concat(parts, ", "),
            bt.search.yturn and ", manoeuvre en Y (avance en biais, long recul droit, demi-tour en avant)" or "",
            bt.search.sign > 0 and "gauche" or "droite",
            bt.search.grass and "sur l'herbe si besoin" or "sans sortir du champ", bt.obstacles))
        if bt.preferSign ~= nil and bt.search.uturnReasons ~= nil then
            local why = {}
            for r, n in pairs(bt.search.uturnReasons) do
                why[#why + 1] = string.format("%s x%d", r, n)
            end
            print(string.format("[AD-DemiTour] %s: bout de rang, demi-tours refuses cote ensileuse : %s", name, table.concat(why, ", ")))
        end
        if bt.preferSign ~= nil then
            print(string.format("[AD-DemiTour] %s: bout de rang : %s, cote ensileuse %s, reglages champ %s / culture %s", name,
                bt.search.yturn and "manoeuvre en Y" or (bt.search.uturn and (#bt.legs > 1 and "recul puis demi-tour en avant" or "demi-tour en avant") or "manoeuvre en plusieurs temps"),
                bt.search.sign == bt.preferSign and "oui" or "non", tostring(bt.rules and bt.rules.field), tostring(bt.rules and bt.rules.crop)))
        end
        bt.search = nil
        -- the map is kept: the front of the tractor is checked against the crop while driving
        bt.legIndex, bt.pointIndex, bt.pause, bt.stillTime = 1, 1, ADBandTurn.LEG_PAUSE, 0
        bt.phase = "drive"
        return "running"
    elseif bt.phase == "drive" then
        if bt.time > ADBandTurn.TIMEOUT then
            return ADBandTurn.fail(vehicle, dt, "trop long")
        end
        ADBandTurn.holdHarvester(vehicle, bt)
        local state = ADBandTurn.driveLeg(vehicle, bt, dt)
        if state == "running" then
            return "running"
        elseif state ~= "done" then
            -- off the planned line (the reverse is not exact): plan the rest again from here, same goal
            if (string.find(state, "ecart", 1, true) ~= nil or string.find(state, "culture", 1, true) ~= nil or string.find(state, "bloque", 1, true) ~= nil) and (bt.replans or 0) < ADBandTurn.MAX_REPLANS and ADBandTurn.replan(vehicle, bt, state) then
                ADBandTurn.stop(vehicle, dt)
                return "running"
            end
            return ADBandTurn.fail(vehicle, dt, state)
        end
        bt.legIndex = bt.legIndex + 1
        bt.pointIndex, bt.pause, bt.stillTime = 1, ADBandTurn.LEG_PAUSE, 0
        if bt.legIndex <= #bt.legs then
            return "running"
        end
        -- 24/10: once turned, hand back to AutoDrive at once, no waiting for the harvester here
        print(string.format("[AD-DemiTour] %s: demi-tour termine en %.0f s, la main revient a AutoDrive", name, bt.time / 1000))
        vehicle.ad.bandTurn = nil
        ADBandTurn.stop(vehicle, dt)
        return "done"
    elseif bt.phase == "join" then
        return ADBandTurn.updateJoin(vehicle, bt, dt)
    end
    return ADBandTurn.fail(vehicle, dt, "etat inconnu")
end

function ADBandTurn.holdHarvester(vehicle, bt)
    local harvester = bt.harvester or vehicle.ad.lastHarvester
    if harvester ~= nil and harvester.components ~= nil and AutoDrive.getDistanceBetween(vehicle, harvester) < ADBandTurn.HOLD_HARVESTER_DISTANCE then
        AutoDrive:holdCPCombine(harvester)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Après une arrivée de face : rejoindre l'ensileuse
-- ------------------------------------------------------------------------------------------------------------
-- after a head-on arrival: the harvester is behind, wait for it to come alongside, or back up to its pipe if it waits
function ADBandTurn.updateJoin(vehicle, bt, dt)
    local name = logName(vehicle)
    local harvester = bt.harvester
    local mode = vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if harvester == nil or harvester.components == nil or mode == nil or mode.getPipeChasePosition == nil then
        vehicle.ad.bandTurn = nil
        return "done"
    end
    local chasePos = mode:getPipeChasePosition()
    if chasePos == nil then
        vehicle.ad.bandTurn = nil
        return "done"
    end
    local _, _, cz = AutoDrive.worldToLocal(vehicle, chasePos.x, chasePos.y or 0, chasePos.z)
    if cz > -2 then
        print(string.format("[AD-DemiTour] %s: a cote de l'ensileuse, la poursuite reprend", name))
        vehicle.ad.bandTurn = nil
        return "joined"
    end
    bt.joinTime = bt.joinTime + dt
    local stopped = math.abs(harvester.lastSpeedReal or 0) < 0.0003
    bt.joinStill = stopped and bt.joinStill + dt or 0
    local sdm = vehicle.ad.specialDrivingModule
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    -- 23/10: no long blind reverse to the pipe any more, the unloader waits for the harvester where it is
    if ADBandTurn.JOIN_REVERSE and bt.joinStart == nil and bt.joinStill > ADBandTurn.JOIN_STOPPED_TIME then
        bt.joinStart = {x = x, z = z}
        sdm:reset()
        print(string.format("[AD-DemiTour] %s: ensileuse arretee %.0f m derriere, recul jusqu'a sa goulotte", name, -cz))
    end
    if bt.joinStart ~= nil then
        local backed = MathUtil.vector2Length(x - bt.joinStart.x, z - bt.joinStart.z)
        bt.joinBlocked = math.abs(vehicle.lastSpeedReal or 0) < 0.0002 and (bt.joinBlocked or 0) + dt or 0
        if backed > ADBandTurn.JOIN_MAX_REVERSE or bt.joinBlocked > ADBandTurn.JOIN_STOPPED_TIME then
            vehicle.ad.bandTurn = nil
            ADBandTurn.stop(vehicle, dt)
            return "done"
        end
        -- straight back on the own axis, the trailer leads
        local reverseNode = sdm:getReverseNode()
        if reverseNode == nil then
            vehicle.ad.bandTurn = nil
            return "done"
        end
        local tx, ty, tz = AutoDrive.localToWorld(vehicle, 0, 0, cz - 6)
        sdm:reverseToTargetLocation(dt, {x = tx, y = ty, z = tz}, ADBandTurn.SPEED)
        return "running"
    end
    if bt.joinTime > ADBandTurn.JOIN_WAIT_TIME then
        vehicle.ad.bandTurn = nil
        ADBandTurn.stop(vehicle, dt)
        return "done"
    end
    ADBandTurn.stop(vehicle, dt)
    return "running"
end
