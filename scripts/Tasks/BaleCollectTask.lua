-- ============================================================================================================
-- FarmPilot : BaleCollectTask.lua
-- Mode Autonome, remorque à balles : ramassage des balles du champ (notre script, sans Courseplay).
--
-- Règle (09/11) :
-- - Remorque en position travail (bras sorti), puis, tant qu'elle n'est pas pleine : la balle à ramasser la plus
--   proche (BaleLoaderManager.findBales : rondes ou carrées selon la remorque, enrubannées ou non selon le réglage).
-- - Le jeu attrape une balle quand elle passe à moins de pickupRange (3 m en général) du nœud du bras, côté bras.
--   On se met donc dans l'axe d'approche avec le décalage du bras : la ligne suivie par le tracteur passe à côté de
--   la balle, de la distance entre l'axe de la remorque et le bras ; le bras passe sur la balle.
-- - Axe d'approche (09/11) : du tracteur vers la balle, ronde ou carrée (le bras prend une balle carrée dans
--   n'importe quel sens) ; la ligne passe par le tracteur, le bras sur la balle. Le chemin jusqu'au début de la ligne
--   (APPROACH_RUN m avant le bras) : chercheur de chemin de FarmPilot ; déjà dans l'axe : pas de chemin, la ligne
--   directement. Chemin refusé (virage trop serré pour la remorque...) : approche directe, tout droit sur la ligne
--   depuis là où il est ; le bras fait le reste. Pareil si le début de la ligne est à moins de MIN_PATH m (balle
--   proche, tracteur pas dans l'axe ; une balle juste devant le tracteur : recul d'abord). Loin de la balle (plus de FAR_DISTANCE m) : FAR_SPEED km/h.
-- - Sur la ligne : APPROACH_SPEED km/h, point suivi LINE_LOOKAHEAD m devant sur la ligne. Le bras bouge = balle
--   prise : arrêt jusqu'à la fin du chargement, puis la balle suivante.
-- - Bras passé PASS_BEYOND m après la balle sans la prendre (ou délai dépassé) : raté, nouvel essai ; après
--   MAX_TRIES essais la balle est laissée (log).
-- - Fin : « full » (pleine), « noBales » (plus de balle à ramasser), ou une erreur (« noLoader », « noWork »).
--   La remorque repasse en position transport avant de rendre la main (route vers le dépôt).
-- - (09/11) Départ bloqué : une balle juste devant le tracteur (la suivante d'un rang, celle que le bras charge) bloque
--   le départ du chemin. Le tracteur recule tout droit de BACKOFF_DISTANCE m puis recalcule ; ce n'est pas compté
--   comme un essai raté. Au plus BACKOFF_MAX reculs de suite au même endroit, ensuite essai raté comme avant.
--   Même recul avant de rendre la main pour le dépôt si une balle est juste devant ou si le dernier départ était bloqué.
-- - (09/11) Bouton >> (Continuer) : fin « continue » dès que le bras a fini sa balle, bras rentré ; ensuite dépôt
--   tout de suite, ou champ laissé si la remorque est vide (AutonomousBales.lua).
-- - (15/11) Ensemble, vitesse, ordre (942 + Arcusin AutoStack au champ 5 : 2 km/h, bras passé à 7,5 / 8,2 / 8,9 m
--   des balles, 40 à 57 s par essai, balle laissée après 2 essais, il tournait à côté).
--   Avant : balle proche hors de l'axe (début de ligne à moins de MIN_PATH m) = approche directe, ligne qui part du
--   tracteur : il braquait à fond, la remorque coupait le virage et le bras passait loin ; sur la ligne la vitesse
--   tombait à 30 % dès que le point suivi passait à plus de 30° (6 -> 1,8 km/h) ; balle suivante = la plus proche
--   (+20 m derrière), sans compter le virage : un rang pris dans le désordre, avec des boucles.
--   Maintenant :
--   1. ordre : la balle suivante est celle qui coûte le moins à l'ensemble : mètres roulés jusqu'à ce que le bras
--      passe sur la balle, virage et demi-tour compris (courbe de Dubins au rayon de l'ensemble, celui du chercheur
--      de chemin, depuis PATH_START m devant le tracteur jusqu'à PATH_END m avant le début de la ligne). Plusieurs
--      sens d'approche sont essayés par balle (tous les HEADING_STEP degrés, et la ligne qui part du tracteur) ;
--      début de ligne hors du champ ou ligne qui passe sur une autre balle (sous le tracteur ou la remorque) :
--      coût en plus. Déjà dans l'axe (bras sur la trace de la balle, tracteur et remorque droits) : tout droit, sans
--      chemin ; à coût égal, tout droit (PATH_OVERHEAD m de plus pour un chemin). Une balle dans l'axe devant passe
--      ainsi avant une balle un peu plus proche sur le côté ou derrière : un rang est pris à la suite, sans boucle ;
--   2. ensemble : plus d'approche directe pour une balle proche hors de l'axe. Le début de la ligne est assez loin
--      (behind + APPROACH_RUN m avant la balle) pour que tracteur et remorque soient droits quand le bras arrive, et le
--      chercheur de chemin (rayon et remorque comptés) fait la boucle jusque-là. Sur la ligne, le point suivi est
--      décalé de l'écart du bras qui ne vient pas du tracteur (remorque en biais) : c'est le bras qui est ramené sur la
--      balle, pas seulement le nez du tracteur. Approche directe seulement en dernier recours (pas de chemin), avec ce
--      même suivi ;
--   3. vitesse : APPROACH_SPEED km/h près de la balle, FAR_SPEED km/h loin (plus de FAR_DISTANCE m), chemin à la
--      vitesse du champ ; ralentissement seulement si le point suivi est très en biais, progressif (LINE_SLOW_ANGLE,
--      LINE_SLOW_FACTOR) ; point suivi plus loin quand il roule vite. Le jeu attrape la balle en roulant
--      (BaleLoader.onUpdate : balle dans le déclencheur du bras et à moins de pickupRange, aucun contrôle de vitesse),
--      mais n'en prend pas d'autre tant que le bras charge (getIsBaleGrabbingAllowed) : pendant le chargement il
--      continue tout droit sur la ligne à GRAB_SPEED km/h, GRAB_ROLL m au plus, et s'arrête si une balle est juste
--      devant le bras ou le tracteur, ou si le bord du champ approche.
--   Traces : coût et sens de la balle choisie, vitesse et écart du bras quand il prend la balle (ou la rate).
--
-- Lancé par AutonomousBales.lua (étape « collect »).
-- ============================================================================================================

ADBaleCollectTask = ADInheritsFrom(AbstractTask)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADBaleCollectTask.APPROACH_SPEED = 10       -- km/h sur la ligne d'approche, près de la balle (6 avant le 15/11)
ADBaleCollectTask.LINE_LOOKAHEAD = 6        -- m : point suivi devant le tracteur, sur la ligne (au moins)
ADBaleCollectTask.LOOKAHEAD_TIME = 1.6      -- s : point suivi plus loin quand il roule plus vite (vitesse x ce temps)
ADBaleCollectTask.LINE_SLOW_ANGLE = 45      -- degrés : ralentissement progressif de 0,75 à 1,5 fois cet angle (20 avant)
ADBaleCollectTask.LINE_SLOW_FACTOR = 0.5    -- part de la vitesse gardée au bout du ralentissement (0,3 avant)
ADBaleCollectTask.ARM_GAIN = 1.0            -- part de l'écart du bras (en plus de celui du tracteur) corrigée sur la ligne
ADBaleCollectTask.ARM_DECAY = 6             -- m : la remorque se remet dans l'axe du tracteur sur à peu près cette longueur
ADBaleCollectTask.ARM_SHIFT_MAX = 1.5       -- m : décalage maxi du point suivi pour ramener le bras
ADBaleCollectTask.ARM_HEADING_MAX = 25      -- degrés : tracteur plus en biais que ça sur la ligne = pas de correction du bras
ADBaleCollectTask.APPROACH_RUN = 12         -- m de ligne droite avant que le bras arrive à la balle (en plus de behind)
ADBaleCollectTask.ON_LINE_DISTANCE = 0.8    -- m : bras à moins de ça de la trace de la balle = déjà dans l'axe (tracteur avant le 15/11)
ADBaleCollectTask.ON_LINE_SLOPE = 0.05      -- m d'écart du bras permis en plus par mètre jusqu'à la balle
ADBaleCollectTask.ON_LINE_ARM_MIN = 4       -- m : bras au moins à ça avant la balle pour la prendre tout droit
ADBaleCollectTask.ON_LINE_ANGLE = 12        -- degrés : tracteur et remorque dans l'axe à moins de ça
ADBaleCollectTask.ON_LINE_LATERAL_COST = 5  -- m de coût par mètre d'écart du bras ou du tracteur à la ligne (tout droit)
ADBaleCollectTask.PASS_BEYOND = 3           -- m : bras passé de ça après la balle sans l'attraper = raté
ADBaleCollectTask.MAX_TRIES = 2             -- essais par balle
ADBaleCollectTask.PREPARE_TIMEOUT = 20000   -- ms pour sortir ou rentrer le bras
ADBaleCollectTask.REQUEST_INTERVAL = 5000   -- ms entre deux demandes de sortie du bras
ADBaleCollectTask.APPROACH_TIMEOUT = 60000  -- ms sur la ligne d'approche (+ le temps de rouler jusqu'à la balle)
ADBaleCollectTask.FAR_DISTANCE = 20         -- m : bras plus loin que ça avant la balle = FAR_SPEED
ADBaleCollectTask.FAR_SPEED = 15            -- km/h sur la ligne, loin de la balle (12 avant le 15/11)
ADBaleCollectTask.DRIVE_TIMEOUT = 180000    -- ms sur le chemin jusqu'à la ligne
ADBaleCollectTask.GRAB_TIMEOUT = 30000      -- ms pour que le bras finisse de charger
ADBaleCollectTask.STUCK_TIME = 10000        -- ms arrêté sur la ligne d'approche = bloqué
ADBaleCollectTask.CHECK_INTERVAL = 1000     -- ms entre deux contrôles de la balle visée
ADBaleCollectTask.BACKOFF_DISTANCE = 10     -- m de recul quand une balle bloque le départ du chemin
ADBaleCollectTask.BACKOFF_SPEED = 5         -- km/h en recul
ADBaleCollectTask.BACKOFF_TIMEOUT = 25000   -- ms pour reculer
ADBaleCollectTask.BACKOFF_REAR_BLOCKED = 1500 -- ms de capteur arrière bloqué : recul arrêté là
ADBaleCollectTask.BACKOFF_MAX = 2           -- reculs de suite au même endroit
ADBaleCollectTask.BACKOFF_SAME_PLACE = 15   -- m roulés depuis la fin du dernier recul : le compte repart à zéro
ADBaleCollectTask.FRONT_LENGTH = 8          -- m devant l'avant du tracteur : balle qui gêne le départ vers le dépôt
ADBaleCollectTask.FRONT_HALF_WIDTH = 2.5    -- m de chaque côté de l'axe du tracteur
-- (15/11) choix de la balle : coût pour l'ensemble
ADBaleCollectTask.TURN_RADIUS = 9           -- m : rayon de l'ensemble quand le chercheur de chemin ne le donne pas
ADBaleCollectTask.PATH_START = 7            -- m : le chemin part de là devant le tracteur (comme le chercheur de chemin)
ADBaleCollectTask.PATH_END = 7              -- m : et finit tout droit sur cette longueur avant le début de la ligne
ADBaleCollectTask.HEADING_STEP = 30         -- degrés entre deux sens d'approche essayés pour une balle
ADBaleCollectTask.PATH_OVERHEAD = 10        -- m ajoutés à un chemin (calcul, reprise de la ligne) : à coût égal, tout droit
ADBaleCollectTask.BODY_HALF_WIDTH = 1.6     -- m : autre balle à moins de ça de l'axe de la ligne = sous le tracteur
ADBaleCollectTask.BODY_PENALTY = 60         -- m ajoutés au coût d'une ligne qui passe sur une autre balle
ADBaleCollectTask.OFF_FIELD_PENALTY = 80    -- m ajoutés quand le début de la ligne ou la fin du chemin est hors du champ
-- (15/11) chargement en roulant
ADBaleCollectTask.GRAB_SPEED = 6            -- km/h tout droit pendant que le bras charge
ADBaleCollectTask.GRAB_ROLL = 10            -- m roulés au plus pendant le chargement
ADBaleCollectTask.GRAB_CLEAR = 6            -- m devant le bras : une balle là = arrêt (le bras occupé la raterait)
ADBaleCollectTask.GRAB_CLEAR_SIDE = 1.5     -- m de chaque côté de la trace du bras
ADBaleCollectTask.GRAB_FIELD_AHEAD = 6      -- m devant l'avant du tracteur : hors du champ = arrêt
ADBaleCollectTask.GRAB_CHECK_INTERVAL = 250 -- ms entre deux contrôles pendant le chargement en roulant

ADBaleCollectTask.claims = {}   -- [balle] = véhicule : balle visée par une remorque (deux remorques au même champ)

local function log(fmt, ...)
    ADBaleLoaderManager.log(fmt, ...)
end

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
-- ctx = { tool (remorque), settings (wrap, deposit), fieldNums (numéros du champ), fieldName }
function ADBaleCollectTask:new(vehicle, ctx)
    local o = ADBaleCollectTask:create()
    o.taskType = "ADBaleCollectTask"
    o.vehicle = vehicle
    o.loader = ctx.tool
    o.ctx = ctx
    o.wrap = ctx.settings ~= nil and ctx.settings.wrap or ADBaleLoaderManager.WRAP_ALL
    o.tries = {}         -- [balle] = essais ratés
    o.left = {}          -- [balle] = true : laissée
    o.picked = 0
    o.result = nil
    return o
end

function ADBaleCollectTask:setUp()
    self.timer = 0
    self.checkTimer = 0
    self.state = "prepare"
    self.target = nil
    self.lastRequest = nil
    self.vehicle.ad.specialDrivingModule:stopVehicle()
end

function ADBaleCollectTask:name()
    return tostring(self.vehicle.ad.stateModule:getName())
end

function ADBaleCollectTask:setState(state)
    self.state = state
    self.timer = 0
end

function ADBaleCollectTask:holdVehicle(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
end

-- vitesse du tracteur (km/h)
function ADBaleCollectTask:speedKmh()
    return math.abs((self.vehicle.lastSpeedReal or 0) * 3600)
end

-- ------------------------------------------------------------------------------------------------------------
-- Géométrie : tracteur, remorque, bras
-- ------------------------------------------------------------------------------------------------------------
local function rootOf(object)
    return object.rootNode or (object.components ~= nil and object.components[1] ~= nil and object.components[1].node) or nil
end

local function normalize(x, z)
    local l = math.sqrt(x * x + z * z)
    if l < 1e-6 then
        return 0, 1
    end
    return x / l, z / l
end

-- position et sens du tracteur
function ADBaleCollectTask:tractorPose()
    local node = self.vehicle.components[1].node
    local x, y, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    dx, dz = normalize(dx, dz)
    return x, y, z, dx, dz
end

-- sens de l'axe x (local) d'un nœud par rapport à son axe z : même convention que le moteur, lue sur le nœud lui-même
local function handOf(node)
    local hx, _, hz = localDirectionToWorld(node, 0, 0, 1)
    local sx, _, sz = localDirectionToWorld(node, 1, 0, 0)
    local c = hz * sx - hx * sz
    return c >= 0 and 1 or -1
end

-- axe x (local) d'un nœud tourné vers d
local function sideOf(node, dx, dz)
    local c = handOf(node)
    return c * dz, -c * dx
end

-- décalage du bras : gx = côté (axe x de la remorque), behind = distance tracteur -> bras dans le sens de marche
function ADBaleCollectTask:grabGeometry()
    local grabNode = ADBaleLoaderManager.grabber(self.loader)
    local root = rootOf(self.loader)
    if grabNode == nil or root == nil then
        return nil
    end
    local wx, wy, wz = getWorldTranslation(grabNode)
    local gx = worldToLocal(root, wx, wy, wz)
    local _, _, tz = worldToLocal(self.vehicle.components[1].node, wx, wy, wz)
    return gx, -tz
end

function ADBaleCollectTask:grabPosition()
    local grabNode = ADBaleLoaderManager.grabber(self.loader)
    local x, y, z = getWorldTranslation(grabNode)
    return x, y, z
end

-- sens de la remorque
function ADBaleCollectTask:loaderDir()
    local root = rootOf(self.loader)
    local dx, _, dz = localDirectionToWorld(root, 0, 0, 1)
    return normalize(dx, dz)
end

local function angleBetween(ax, az, bx, bz)
    local dot = math.max(-1, math.min(1, ax * bx + az * bz))
    return math.deg(math.acos(dot))
end

-- angle signé (degrés) de a vers b, positif vers l'axe x du monde quand a regarde vers +z
local function signedAngle(ax, az, bx, bz)
    return math.deg(math.atan2(ax * bz - az * bx, ax * bx + az * bz)) * -1
end

-- (15/11) rayon de braquage de l'ensemble : celui du chercheur de chemin (remorque comprise), sinon TURN_RADIUS
function ADBaleCollectTask:turnRadius()
    local pf = self.vehicle.ad.pathFinderModule
    local r = pf ~= nil and (pf.realTurnRadius or pf.minTurnRadius) or nil
    if (type(r) ~= "number" or r <= 0) and AutoDrive.getDriverRadius ~= nil then
        local ok, rr = FarmPilotCall(AutoDrive.getDriverRadius, self.vehicle)
        r = ok and rr or nil
    end
    if type(r) ~= "number" or r <= 0 then
        r = ADBaleCollectTask.TURN_RADIUS
    end
    return r
end

-- (15/11) longueur de la courbe la plus courte (Dubins, rayon rho) de (x0, z0) sens h à (x1, z1) sens d ;
-- sans le module Dubins : droite + arcs, une boucle en plus si c'est trop près pour tourner
local function curveLength(x0, z0, hx, hz, x1, z1, dx, dz, rho)
    if ADDubins ~= nil and ADDubins.dubins_shortest_path ~= nil then
        local path = { qi = {}, param = {} }
        local q0 = { x0, -z0, math.atan2(-hz, hx) }
        local q1 = { x1, -z1, math.atan2(-dz, dx) }
        local ok, res = FarmPilotCall(ADDubins.dubins_shortest_path, ADDubins, path, q0, q1, rho)
        if ok and res == ADDubins.EDUBOK and path.param[3] ~= nil then
            return (path.param[1] + path.param[2] + path.param[3]) * rho
        end
    end
    local ex, ez = x1 - x0, z1 - z0
    local dist = math.sqrt(ex * ex + ez * ez)
    local ux, uz = normalize(ex, ez)
    local turn = math.rad(angleBetween(hx, hz, ux, uz) + angleBetween(ux, uz, dx, dz))
    local len = dist + rho * turn
    if dist < 2 * rho and turn > math.pi / 2 then
        len = len + math.pi * rho
    end
    return len
end

-- ------------------------------------------------------------------------------------------------------------
-- Choix de la balle et de la ligne d'approche
-- ------------------------------------------------------------------------------------------------------------
function ADBaleCollectTask:skipList()
    local skip = {}
    for b, _ in pairs(self.left) do
        skip[b] = true
    end
    for b, v in pairs(ADBaleCollectTask.claims) do
        if v ~= self.vehicle then
            if v == nil or v.isDeleted or v.ad == nil or not v.ad.stateModule:isActive() then
                ADBaleCollectTask.claims[b] = nil
            else
                skip[b] = true
            end
        end
    end
    return skip
end

function ADBaleCollectTask:candidates()
    local list, onField = ADBaleLoaderManager.findBales(self.loader, self.ctx.fieldNums, self.wrap, self:skipList())
    return list, onField
end

--[==[ Mis de côté (15/11) : la plus proche ne compte pas le virage de l'ensemble (un rang pris dans le désordre,
-- avec des boucles) ; remplacé par chooseBale (coût pour l'ensemble, virage et demi-tour compris)
ADBaleCollectTask.BEHIND_PENALTY = 20       -- m ajoutés à la distance d'une balle derrière le tracteur (demi-tour)

-- la plus proche (une balle derrière compte BEHIND_PENALTY m de plus)
function ADBaleCollectTask:nearest(list)
    local tx, _, tz, hx, hz = self:tractorPose()
    local best, bestCost = nil, math.huge
    for _, c in ipairs(list) do
        local dx, dz = c.x - tx, c.z - tz
        local cost = math.sqrt(dx * dx + dz * dz)
        if dx * hx + dz * hz < 0 then
            cost = cost + ADBaleCollectTask.BEHIND_PENALTY
        end
        if cost < bestCost then
            best, bestCost = c, cost
        end
    end
    return best
end
]==]

-- sens d'approche d'une balle, ronde ou carrée : du tracteur vers la balle, ligne qui passe par le tracteur avec le
-- bras (décalé de gx sur le côté) sur la balle ; balle trop près (à côté du tracteur) : du tracteur vers la balle
function ADBaleCollectTask:approachDir(c, gx)
    local tx, _, tz = self:tractorPose()
    local dx, dz = normalize(c.x - tx, c.z - tz)
    local root = rootOf(self.loader)
    if gx == nil or root == nil or MathUtil.vector2Length(c.x - tx, c.z - tz) <= math.abs(gx) + 1 then
        return dx, dz
    end
    for _ = 1, 3 do
        local sx, sz = sideOf(root, dx, dz)
        dx, dz = normalize(c.x - sx * gx - tx, c.z - sz * gx - tz)
    end
    return dx, dz
end

--[==[ Mis de côté (09/11) : balle carrée prise dans sa longueur ; le chemin pour s'y mettre demandait des virages
-- trop serrés pour la remorque, alors que le bras la prend dans n'importe quel sens
function ADBaleCollectTask:approachDir(c)
    local tx, _, tz = self:tractorPose()
    local dx, dz = normalize(c.x - tx, c.z - tz)
    if not c.round and c.bale.nodeId ~= nil then
        local bx, _, bz = localDirectionToWorld(c.bale.nodeId, 0, 0, 1)
        bx, bz = normalize(bx, bz)
        if bx * dx + bz * dz < 0 then
            bx, bz = -bx, -bz
        end
        return bx, bz
    end
    return dx, dz
end
]==]

-- (15/11) ligne d'approche de la balle c dans le sens d : P0 (point de la ligne au droit de la balle), côté s,
-- départ A (behind + APPROACH_RUN m avant P0 : ensemble droit quand le bras arrive) ; geo = { gx, behind, root, hand }
function ADBaleCollectTask:lineFor(c, dx, dz, geo)
    local hand = geo.hand or handOf(geo.root)
    local sx, sz = hand * dz, -hand * dx
    local line = { bx = c.x, bz = c.z, dx = dx, dz = dz, sx = sx, sz = sz, gx = geo.gx, behind = geo.behind }
    line.p0x, line.p0z = c.x - sx * geo.gx, c.z - sz * geo.gx
    line.back = math.max(ADBaleCollectTask.APPROACH_RUN * 0.5, geo.behind + ADBaleCollectTask.APPROACH_RUN)
    line.ax, line.az = line.p0x - dx * line.back, line.p0z - dz * line.back
    return line
end

-- géométrie de l'ensemble pour le choix : { gx, behind, root, hand, rho } ; nil si la remorque n'a pas de bras
function ADBaleCollectTask:trainGeometry()
    local gx, behind = self:grabGeometry()
    local root = rootOf(self.loader)
    if gx == nil or root == nil then
        return nil
    end
    return { gx = gx, behind = behind, root = root, hand = handOf(root), rho = self:turnRadius() }
end

-- ligne d'approche de la cible, du tracteur vers la balle (déjà dans l'axe, ou approche directe)
function ADBaleCollectTask:makeLine(c)
    local geo = self:trainGeometry()
    if geo == nil then
        return nil
    end
    local dx, dz = self:approachDir(c, geo.gx)
    return self:lineFor(c, dx, dz, geo)
end

--[==[ Mis de côté (15/11) : remplacé par lineFor (même ligne, sens d'approche au choix) et makeLine ci-dessus
-- ligne d'approche de la cible : P0 (point de la ligne au droit de la balle), sens d, côté xd, départ A
function ADBaleCollectTask:makeLine(c)
    local gx, behind = self:grabGeometry()
    if gx == nil then
        return nil
    end
    local dx, dz = self:approachDir(c, gx)
    local sx, sz = sideOf(rootOf(self.loader), dx, dz)
    local line = { bx = c.x, bz = c.z, dx = dx, dz = dz, sx = sx, sz = sz, gx = gx, behind = behind }
    line.p0x, line.p0z = c.x - sx * gx, c.z - sz * gx
    local back = math.max(ADBaleCollectTask.APPROACH_RUN * 0.5, behind + ADBaleCollectTask.APPROACH_RUN)
    line.ax, line.az = line.p0x - dx * back, line.p0z - dz * back
    return line
end
]==]

-- (15/11) ensemble déjà dans l'axe : tracteur et remorque dans le sens de la ligne, bras assez loin avant la balle
-- et à peu près sur sa trace (écart permis plus grand quand la balle est plus loin : le suivi a la place de le corriger)
function ADBaleCollectTask:isOnLine(line)
    local _, _, _, hx, hz = self:tractorPose()
    local lx, lz = self:loaderDir()
    if angleBetween(hx, hz, line.dx, line.dz) > ADBaleCollectTask.ON_LINE_ANGLE or angleBetween(lx, lz, line.dx, line.dz) > ADBaleCollectTask.ON_LINE_ANGLE then
        return false
    end
    local ax, _, az = self:grabPosition()
    local rx, rz = ax - line.bx, az - line.bz
    local along = rx * line.dx + rz * line.dz
    local lateral = math.abs(rx * line.sx + rz * line.sz)
    return along <= -ADBaleCollectTask.ON_LINE_ARM_MIN and lateral <= ADBaleCollectTask.ON_LINE_DISTANCE + ADBaleCollectTask.ON_LINE_SLOPE * -along
end

--[==[ Mis de côté (15/11) : écart lu au tracteur seulement, et bras à 11 m au moins de la balle : après le
-- chargement en roulant la balle suivante du rang n'était plus « dans l'axe » (boucle pour la reprendre)
function ADBaleCollectTask:isOnLine(line)
    local tx, _, tz, hx, hz = self:tractorPose()
    local rx, rz = tx - line.p0x, tz - line.p0z
    local lateral = math.abs(rx * line.sx + rz * line.sz)
    local along = rx * line.dx + rz * line.dz
    local lx, lz = self:loaderDir()
    return lateral <= ADBaleCollectTask.ON_LINE_DISTANCE and angleBetween(hx, hz, line.dx, line.dz) <= ADBaleCollectTask.ON_LINE_ANGLE
        and angleBetween(lx, lz, line.dx, line.dz) <= ADBaleCollectTask.ON_LINE_ANGLE and along <= -(line.behind + 4)
end
]==]

-- (15/11) point sur le champ de la tâche (sans marge) ; pas de numéro de champ connu : compté sur le champ
function ADBaleCollectTask:isFieldPoint(x, z)
    local nums = self.ctx.fieldNums
    if nums == nil or next(nums) == nil then
        return true
    end
    local f = ADAutonomousManager.fieldAt(x, z)
    local n = f ~= nil and ADAutonomousManager.fieldNumber(f) or nil
    return n ~= nil and nums[tonumber(n) or n] == true
end

-- (15/11) une autre balle sous le tracteur ou la remorque sur la ligne, entre le départ (fromAlong, compté depuis
-- P0) et le moment où le bras passe sur la balle (le tracteur est alors behind m après P0)
function ADBaleCollectTask:lineHitsBale(line, target, list, fromAlong)
    local to = line.behind + 3
    for _, o in ipairs(list) do
        if o.bale ~= target.bale then
            local rx, rz = o.x - line.p0x, o.z - line.p0z
            local along = rx * line.dx + rz * line.dz
            if along >= fromAlong and along <= to and math.abs(rx * line.sx + rz * line.sz) < ADBaleCollectTask.BODY_HALF_WIDTH then
                return true
            end
        end
    end
    return false
end

-- (15/11) balle suivante : celle qui coûte le moins à l'ensemble, en mètres roulés jusqu'à ce que le bras passe sur
-- elle. Pour chaque balle : tout droit si le tracteur est déjà dans l'axe, sinon chemin (courbe au rayon de
-- l'ensemble) jusqu'au début d'une ligne, dans HEADING_STEP sens essayés. Renvoie { c, line, cost, onLine, why }
function ADBaleCollectTask:chooseBale(list, geo)
    local tx, _, tz, hx, hz = self:tractorPose()
    local sx0, sz0 = tx + hx * ADBaleCollectTask.PATH_START, tz + hz * ADBaleCollectTask.PATH_START
    local fixed = ADBaleCollectTask.PATH_START + ADBaleCollectTask.PATH_END
    local best = nil
    local steps = math.max(1, math.floor(360 / ADBaleCollectTask.HEADING_STEP + 0.5))
    local armX, _, armZ = self:grabPosition()
    for _, c in ipairs(list) do
        -- 1. tout droit : ligne qui part du bras (un rang suit ainsi la trace des balles, sans zigzag), du tracteur,
        --    ou droit devant ; écarts du bras et du tracteur à la ligne comptés en plus
        local adx, adz = self:approachDir(c, geo.gx)
        for i = 1, 3 do
            local dx, dz = normalize(c.x - armX, c.z - armZ)
            if i == 2 then
                dx, dz = adx, adz
            elseif i == 3 then
                dx, dz = hx, hz
            end
            local direct = self:lineFor(c, dx, dz, geo)
            if self:isOnLine(direct) then
                local along = (direct.p0x - tx) * dx + (direct.p0z - tz) * dz
                local armLateral = math.abs((armX - c.x) * direct.sx + (armZ - c.z) * direct.sz)
                local tractorLateral = math.abs((tx - direct.p0x) * direct.sx + (tz - direct.p0z) * direct.sz)
                local cost = along + geo.behind + ADBaleCollectTask.ON_LINE_LATERAL_COST * math.max(armLateral, tractorLateral)
                if best == nil or cost < best.cost then
                    local why = nil
                    if self:lineHitsBale(direct, c, list, -along) then
                        cost = cost + ADBaleCollectTask.BODY_PENALTY
                        why = "autre balle sur la ligne"
                    end
                    if best == nil or cost < best.cost then
                        best = { c = c, line = direct, cost = cost, onLine = true, why = why }
                    end
                end
            end
        end
        -- 2. chemin jusqu'au début d'une ligne : sens du tracteur tourné de k x HEADING_STEP, et la ligne du tracteur
        for k = 0, steps do
            local dx, dz = adx, adz
            if k < steps then
                local a = math.rad(k * ADBaleCollectTask.HEADING_STEP)
                local ca, sa = math.cos(a), math.sin(a)
                dx, dz = hx * ca + hz * sa, -hx * sa + hz * ca
            end
            local line = self:lineFor(c, dx, dz, geo)
            local ex, ez = line.ax - dx * ADBaleCollectTask.PATH_END, line.az - dz * ADBaleCollectTask.PATH_END
            local cost = fixed + ADBaleCollectTask.PATH_OVERHEAD + curveLength(sx0, sz0, hx, hz, ex, ez, dx, dz, geo.rho) + line.back + geo.behind
            if best == nil or cost < best.cost then
                -- contrôles plus coûteux seulement pour une ligne qui peut passer devant
                local why = nil
                if not self:isFieldPoint(line.ax, line.az) or not self:isFieldPoint(ex, ez) then
                    cost = cost + ADBaleCollectTask.OFF_FIELD_PENALTY
                    why = "début de ligne hors du champ"
                end
                if (best == nil or cost < best.cost) and self:lineHitsBale(line, c, list, -line.back) then
                    cost = cost + ADBaleCollectTask.BODY_PENALTY
                    why = (why ~= nil and (why .. ", ") or "") .. "autre balle sur la ligne"
                end
                if best == nil or cost < best.cost then
                    best = { c = c, line = line, cost = cost, onLine = false, why = why }
                end
            end
        end
    end
    if best ~= nil then
        best.turn = signedAngle(hx, hz, best.line.dx, best.line.dz)
    end
    return best
end

function ADBaleCollectTask:claim(bale)
    for b, v in pairs(ADBaleCollectTask.claims) do
        if v == self.vehicle then
            ADBaleCollectTask.claims[b] = nil
        end
    end
    if bale ~= nil then
        ADBaleCollectTask.claims[bale] = self.vehicle
    end
end

-- balle visée ratée : nouvel essai, ou laissée après MAX_TRIES
function ADBaleCollectTask:missed(why)
    local bale = self.target ~= nil and self.target.bale or nil
    if bale ~= nil then
        self.tries[bale] = (self.tries[bale] or 0) + 1
        if self.tries[bale] >= ADBaleCollectTask.MAX_TRIES then
            self.left[bale] = true
            log("%s : balle laissée après %d essais (%s)", self:name(), self.tries[bale], tostring(why))
        else
            log("%s : balle ratée (%s), nouvel essai", self:name(), tostring(why))
        end
    end
    self.target = nil
    self:claim(nil)
    self:setState("find")
end

-- ------------------------------------------------------------------------------------------------------------
-- À chaque image (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
function ADBaleCollectTask:update(dt)
    self.timer = self.timer + dt
    local loader = self.loader
    if loader == nil or loader.isDeleted or not ADBaleLoaderManager.isAttached(loader, self.vehicle) then
        self:holdVehicle(dt)
        self:finish("noLoader")
        return
    end
    -- le bras attrape une balle (visée ou non) : chargement (en roulant depuis la ligne d'approche, sinon arrêté)
    -- (pas pendant le recul : le bras finit de se replier, on ne vise rien)
    if self.state ~= "grab" and self.state ~= "prepare" and self.state ~= "fold" and self.state ~= "backoff" and ADBaleLoaderManager.isBusy(loader) then
        self.countBefore = self.countBefore or ADBaleLoaderManager.loadedCount(loader)
        self:startGrab()
    end

    -- >> : fin demandée, une fois la balle en cours chargée (pas pendant un recul)
    if self.depositRequested and self.result == nil and self.state ~= "grab" and self.state ~= "backoff" then
        self:holdVehicle(dt)
        self:finish("continue")
        return
    end

    if self.state == "prepare" then
        self:holdVehicle(dt)
        if ADBaleLoaderManager.isInWorkPosition(loader) then
            self:setState("find")
        elseif self.timer >= ADBaleCollectTask.PREPARE_TIMEOUT then
            log("%s : le bras de la remorque ne sort pas", self:name())
            self:finish("noWork")
        elseif not ADBaleLoaderManager.isBusy(loader) and not ADBaleLoaderManager.isUnloading(loader)
            and (self.lastRequest == nil or self.timer - self.lastRequest >= ADBaleCollectTask.REQUEST_INTERVAL) then
            -- même commande que la touche du jeu ; redemandée si le bras n'est toujours pas sorti
            self.lastRequest = self.timer
            ADBaleLoaderManager.setWorkPosition(loader, true)
        end
    elseif self.state == "find" then
        self:holdVehicle(dt)
        self:updateFind()
    elseif self.state == "planning" then
        self:updatePlanning(dt)
    elseif self.state == "drive" then
        self:updateDrive(dt)
    elseif self.state == "approach" then
        self:updateApproach(dt)
    elseif self.state == "backoff" then
        self:updateBackOff(dt)
    elseif self.state == "grab" then
        if not self:updateGrabRoll(dt) then
            self:holdVehicle(dt)
        end
        if not ADBaleLoaderManager.isBusy(loader) or self.timer >= ADBaleCollectTask.GRAB_TIMEOUT then
            local now = ADBaleLoaderManager.loadedCount(loader)
            if now > (self.countBefore or now) or self.target ~= nil and ADBaleLoaderManager.rejectReason(loader, self.target.bale, self.wrap) ~= nil then
                self.picked = self.picked + math.max(1, now - (self.countBefore or now))
            end
            self.countBefore = nil
            self.target = nil
            self.rollLine = nil
            self:claim(nil)
            self:setState("find")
        end
    elseif self.state == "fold" then
        self:holdVehicle(dt)
        if not ADBaleLoaderManager.isInWorkPosition(loader) or self.timer >= ADBaleCollectTask.PREPARE_TIMEOUT then
            -- départ vers le dépôt bloqué par une balle juste devant : recul d'abord
            if not self.finalBackOffDone and (self.lastStartObstructed or self:baleInFront()) then
                self.finalBackOffDone = true
                if self:startBackOff("done", "balle ou obstacle juste devant le tracteur avant de repartir", true) then
                    return
                end
            end
            self:finished()
        elseif not ADBaleLoaderManager.isBusy(loader) and not self.foldRequested then
            self.foldRequested = ADBaleLoaderManager.setWorkPosition(loader, false)
        end
    end
end

-- balle suivante, ou fin
function ADBaleCollectTask:updateFind()
    local loader = self.loader
    if ADBaleLoaderManager.isFull(loader) then
        self:finish("full")
        return
    end
    local list, onField = self:candidates()
    self.onField = onField
    if #list == 0 then
        self:finish("noBales")
        return
    end
    local geo = self:trainGeometry()
    if geo == nil then
        log("%s : la remorque n'a pas de bras (nœud grabNode) : arrêt", self:name())
        self:finish("noWork")
        return
    end
    local plan = self:chooseBale(list, geo)
    if plan == nil then
        self:finish("noBales")
        return
    end
    local c, line = plan.c, plan.line
    self.target = c
    self.line = line
    self.chosenAt = g_time or 0
    self:claim(c.bale)
    -- la plus proche, pour la trace (choix différent = virage évité)
    local nearestDist = math.huge
    for _, o in ipairs(list) do
        nearestDist = math.min(nearestDist, self:distanceTo(o))
    end
    local costText = string.format("coût %.0f m, sens %+.0f°%s%s", plan.cost, plan.turn or 0,
        plan.why ~= nil and (", " .. plan.why) or "",
        nearestDist < self:distanceTo(c) - 0.5 and string.format(", la plus proche à %.0f m", nearestDist) or "")
    if plan.onLine then
        log("%s : balle à %.0f m, déjà dans l'axe (bras à %.1f m de côté), %s", self:name(), self:distanceTo(c), line.gx, costText)
        self:startApproach()
        return
    end
    local pf = self.vehicle.ad.pathFinderModule
    pf:reset()
    pf:startPathPlanningTo({ x = line.ax, y = c.y, z = line.az }, { x = line.dx, z = line.dz })
    log("%s : balle à %.0f m (%d à ramasser), %s, chemin vers la ligne d'approche (bras à %.1f m de côté, %.1f m derrière le tracteur, rayon %.1f m)",
        self:name(), self:distanceTo(c), #list, costText, line.gx, line.behind, geo.rho)
    self:setState("planning")
end

--[==[ Mis de côté (15/11) : balle proche hors de l'axe = approche directe depuis le tracteur (il braquait à fond,
-- la remorque coupait le virage, bras passé à 7,5 / 8,2 / 8,9 m de la balle) ; le chemin fait maintenant la boucle
ADBaleCollectTask.MIN_PATH = 20             -- m : début de la ligne plus près que ça du tracteur = approche directe

    -- début de la ligne trop près pour un chemin (la ligne passe par le tracteur) : approche directe
    local tx, _, tz = self:tractorPose()
    if MathUtil.vector2Length(line.ax - tx, line.az - tz) < ADBaleCollectTask.MIN_PATH then
        -- une balle juste devant le tracteur : recul d'abord (le tracteur la pousserait)
        if self:baleInFront() and self:startBackOff("find", "balle proche juste devant le tracteur") then
            return
        end
        self:startDirect("balle proche, pas dans l'axe")
        return
    end
]==]

function ADBaleCollectTask:distanceTo(c)
    local tx, _, tz = self:tractorPose()
    return MathUtil.vector2Length(c.x - tx, c.z - tz)
end

-- la balle visée est-elle toujours à prendre ? (contrôle espacé)
function ADBaleCollectTask:targetStillValid(dt)
    self.checkTimer = self.checkTimer + dt
    if self.checkTimer < ADBaleCollectTask.CHECK_INTERVAL then
        return true
    end
    self.checkTimer = 0
    if self.target == nil then
        return false
    end
    return ADBaleLoaderManager.rejectReason(self.loader, self.target.bale, self.wrap) == nil
end

function ADBaleCollectTask:updatePlanning(dt)
    local pf = self.vehicle.ad.pathFinderModule
    if not pf:hasFinished() then
        pf:update(dt)
        self:holdVehicle(dt)
        return
    end
    local path = pf:getPath()
    if path == nil or #path < 2 then
        self:holdVehicle(dt)
        self.lastStartObstructed = pf.startObstructed == true
        if self.lastStartObstructed and self:startBackOff("find", "départ du chemin bloqué juste devant le tracteur") then
            return
        end
        if self:startDirect("pas de chemin jusqu'à la ligne d'approche") then
            return
        end
        self:missed("pas de chemin jusqu'à la ligne d'approche")
        return
    end
    self.lastStartObstructed = false
    self.vehicle.ad.drivePathModule:setWayPoints(path)
    self:setState("drive")
end

function ADBaleCollectTask:updateDrive(dt)
    if not self:targetStillValid(dt) then
        self:holdVehicle(dt)
        self.target = nil
        self:claim(nil)
        self:setState("find")
        return
    end
    local dpm = self.vehicle.ad.drivePathModule
    if dpm:isTargetReached() then
        self:startApproach()
        return
    end
    if self.timer >= ADBaleCollectTask.DRIVE_TIMEOUT then
        self:holdVehicle(dt)
        self:missed("chemin trop long")
        return
    end
    dpm:update(dt)
end

function ADBaleCollectTask:startApproach()
    self.stuckTimer = 0
    self.bestLateral = nil
    self.lineMaxSpeed = 0
    local dist = self.target ~= nil and self:distanceTo(self.target) or 0
    self.approachTimeout = ADBaleCollectTask.APPROACH_TIMEOUT + dist / (ADBaleCollectTask.FAR_SPEED / 3.6) * 1000
    self:setState("approach")
end

-- pas de chemin : tout droit vers la balle, sur la ligne qui passe par le tracteur ; même suivi de l'ensemble
function ADBaleCollectTask:startDirect(why)
    if self.target == nil then
        return false
    end
    local line = self:makeLine(self.target)
    if line == nil then
        return false
    end
    self.line = line
    local _, _, _, hx, hz = self:tractorPose()
    log("%s : %s : approche directe, tout droit vers la balle à %.0f m (sens %+.0f°, suivi de l'ensemble)", self:name(), tostring(why),
        self:distanceTo(self.target), signedAngle(hx, hz, line.dx, line.dz))
    self:startApproach()
    return true
end

-- sur la ligne : point suivi devant le tracteur, décalé de l'écart du bras dû à la remorque ; le bras passe sur la balle
function ADBaleCollectTask:updateApproach(dt)
    local line = self.line
    if not self:targetStillValid(dt) then
        -- prise entre deux contrôles, ou plus à prendre
        self:holdVehicle(dt)
        self.target = nil
        self:claim(nil)
        self:setState("find")
        return
    end
    local gxw, _, gzw = self:grabPosition()
    local along = (gxw - line.bx) * line.dx + (gzw - line.bz) * line.dz
    local lateral = (gxw - line.bx) * line.sx + (gzw - line.bz) * line.sz
    if math.abs(along) < 2 and (self.bestLateral == nil or math.abs(lateral) < math.abs(self.bestLateral)) then
        self.bestLateral = lateral
    end
    local kmh = self:speedKmh()
    self.lineMaxSpeed = math.max(self.lineMaxSpeed or 0, kmh)
    if along > ADBaleCollectTask.PASS_BEYOND then
        self:holdVehicle(dt)
        self:missed(string.format("bras passé à %.1f m de la balle, à %.1f km/h", math.abs(self.bestLateral or lateral), kmh))
        return
    end
    if self.timer >= (self.approachTimeout or ADBaleCollectTask.APPROACH_TIMEOUT) then
        self:holdVehicle(dt)
        self:missed("délai dépassé sur la ligne d'approche")
        return
    end
    if math.abs(self.vehicle.lastSpeedReal or 0) < 0.0003 then
        self.stuckTimer = self.stuckTimer + dt
        if self.stuckTimer >= ADBaleCollectTask.STUCK_TIME then
            self:holdVehicle(dt)
            self:missed("bloqué sur la ligne d'approche")
            return
        end
    else
        self.stuckTimer = 0
    end
    local tx, ty, tz, hx, hz = self:tractorPose()
    local s = (tx - line.p0x) * line.dx + (tz - line.p0z) * line.dz
    -- ensemble : l'écart du bras qui ne vient pas du tracteur (remorque en biais, virage coupé) se résorbe tout seul
    -- en ligne droite, sur ARM_DECAY m environ ; la part qui resterait quand le bras arrive à la balle est corrigée
    -- en visant d'autant de l'autre côté de la ligne (seulement tracteur à peu près dans l'axe et bras avant la balle)
    local shift = 0
    if along < 0 and angleBetween(hx, hz, line.dx, line.dz) <= ADBaleCollectTask.ARM_HEADING_MAX then
        local tractorLateral = (tx - line.p0x) * line.sx + (tz - line.p0z) * line.sz
        shift = -ADBaleCollectTask.ARM_GAIN * (lateral - tractorLateral) * math.exp(along / ADBaleCollectTask.ARM_DECAY)
        shift = math.max(-ADBaleCollectTask.ARM_SHIFT_MAX, math.min(ADBaleCollectTask.ARM_SHIFT_MAX, shift))
    end
    local look = math.max(ADBaleCollectTask.LINE_LOOKAHEAD, kmh / 3.6 * ADBaleCollectTask.LOOKAHEAD_TIME)
    local cx = line.p0x + line.dx * (s + look) + line.sx * shift
    local cz = line.p0z + line.dz * (s + look) + line.sz * shift
    local speed = ADBaleCollectTask.APPROACH_SPEED
    if along < -ADBaleCollectTask.FAR_DISTANCE then
        speed = ADBaleCollectTask.FAR_SPEED
    end
    self.lastLateral, self.lastAlong = lateral, along
    -- sans contrôle de collision : les capteurs verraient la balle visée (et celles d'à côté) ; ralentissement
    -- seulement si le point suivi est très en biais, progressif
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, { x = cx, y = ty, z = cz }, speed, false, 0.5, speed, true,
        ADBaleCollectTask.LINE_SLOW_ANGLE, ADBaleCollectTask.LINE_SLOW_FACTOR)
end

--[==[ Mis de côté (15/11) : point suivi sur la ligne au nez du tracteur seulement, coupure à 30 % dès 30° (2 km/h)
    local tx, ty, tz = self:tractorPose()
    local s = (tx - line.p0x) * line.dx + (tz - line.p0z) * line.dz
    local cx = line.p0x + line.dx * (s + ADBaleCollectTask.LINE_LOOKAHEAD)
    local cz = line.p0z + line.dz * (s + ADBaleCollectTask.LINE_LOOKAHEAD)
    local speed = ADBaleCollectTask.APPROACH_SPEED
    if along < -ADBaleCollectTask.FAR_DISTANCE then
        speed = ADBaleCollectTask.FAR_SPEED
    end
    -- sans contrôle de collision : les capteurs verraient la balle visée (et celles d'à côté)
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, { x = cx, y = ty, z = cz }, speed, false, 0.5, speed, true)
]==]

-- ------------------------------------------------------------------------------------------------------------
-- (15/11) Chargement en roulant
-- ------------------------------------------------------------------------------------------------------------
-- le bras vient d'attraper une balle : trace (vitesse, écart du bras), puis chargement ; depuis la ligne d'approche,
-- il continue tout droit sur la ligne pendant le chargement
function ADBaleCollectTask:startGrab()
    local fromLine = self.state == "approach" and self.line ~= nil
    if fromLine then
        local secs = ((g_time or 0) - (self.chosenAt or g_time or 0)) / 1000
        log("%s : balle attrapée à %.1f km/h (%.1f au plus sur la ligne), bras à %.2f m de la balle visée (%.1f m avant), %.0f s depuis le choix",
            self:name(), self:speedKmh(), self.lineMaxSpeed or 0, math.abs(self.lastLateral or 0), -(self.lastAlong or 0), secs)
        local tx, _, tz = self:tractorPose()
        self.rollLine = self.line
        self.rollStart = { x = tx, z = tz }
        self.rollCheckTimer = ADBaleCollectTask.GRAB_CHECK_INTERVAL
    else
        self.rollLine = nil
    end
    self:setState("grab")
end

-- tout droit pendant le chargement, GRAB_ROLL m au plus ; false = arrêt (ligne finie, balle devant, bord du champ)
function ADBaleCollectTask:updateGrabRoll(dt)
    local line = self.rollLine
    if line == nil then
        return false
    end
    local tx, ty, tz, hx, hz = self:tractorPose()
    if MathUtil.vector2Length(tx - self.rollStart.x, tz - self.rollStart.z) >= ADBaleCollectTask.GRAB_ROLL then
        self.rollLine = nil
        return false
    end
    self.rollCheckTimer = (self.rollCheckTimer or 0) + dt
    if self.rollCheckTimer >= ADBaleCollectTask.GRAB_CHECK_INTERVAL then
        self.rollCheckTimer = 0
        local okB, blocked = FarmPilotCall(self.rollBlocked, self, tx, tz, hx, hz)
        if not okB or blocked then
            self.rollLine = nil
            return false
        end
    end
    local s = (tx - line.p0x) * line.dx + (tz - line.p0z) * line.dz
    local cx = line.p0x + line.dx * (s + ADBaleCollectTask.LINE_LOOKAHEAD)
    local cz = line.p0z + line.dz * (s + ADBaleCollectTask.LINE_LOOKAHEAD)
    local speed = ADBaleCollectTask.GRAB_SPEED
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, { x = cx, y = ty, z = cz }, speed, false, 0.5, speed, true,
        ADBaleCollectTask.LINE_SLOW_ANGLE, ADBaleCollectTask.LINE_SLOW_FACTOR)
    return true
end

-- arrêt pendant le chargement : balle juste devant le bras (il ne la prendrait pas, occupé) ou devant le tracteur
-- (il la pousserait), ou bord du champ devant
function ADBaleCollectTask:rollBlocked(tx, tz, hx, hz)
    local front = (self.vehicle.size ~= nil and self.vehicle.size.length ~= nil and self.vehicle.size.length / 2) or 2.5
    if not self:isFieldPoint(tx + hx * (front + ADBaleCollectTask.GRAB_FIELD_AHEAD), tz + hz * (front + ADBaleCollectTask.GRAB_FIELD_AHEAD)) then
        return true
    end
    local list = ADBaleLoaderManager.findBales(self.loader, self.ctx.fieldNums, ADBaleLoaderManager.WRAP_ALL, {})
    local ax, _, az = self:grabPosition()
    for _, c in ipairs(list) do
        local rx, rz = c.x - tx, c.z - tz
        local along = rx * hx + rz * hz
        if along > 0 and along <= front + ADBaleCollectTask.FRONT_LENGTH and math.abs(rx * hz - rz * hx) <= ADBaleCollectTask.BODY_HALF_WIDTH + 0.4 then
            return true
        end
        local qx, qz = c.x - ax, c.z - az
        local alongArm = qx * hx + qz * hz
        if alongArm > -0.5 and alongArm <= ADBaleCollectTask.GRAB_CLEAR and math.abs(qx * hz - qz * hx) <= ADBaleCollectTask.GRAB_CLEAR_SIDE then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------
-- Recul quand le départ est bloqué
-- ------------------------------------------------------------------------------------------------------------
-- une balle du champ juste devant le tracteur (FRONT_LENGTH m devant son avant, FRONT_HALF_WIDTH m de chaque côté)
function ADBaleCollectTask:baleInFront()
    local okL, list = FarmPilotCall(ADBaleLoaderManager.findBales, self.loader, self.ctx.fieldNums, ADBaleLoaderManager.WRAP_ALL, {})
    if not okL or type(list) ~= "table" then
        return false
    end
    local tx, _, tz, hx, hz = self:tractorPose()
    local front = (self.vehicle.size ~= nil and self.vehicle.size.length ~= nil and self.vehicle.size.length / 2) or 2.5
    for _, c in ipairs(list) do
        local rx, rz = c.x - tx, c.z - tz
        local along = rx * hx + rz * hz
        local side = math.abs(rx * hz - rz * hx)
        if along > 0 and along <= front + ADBaleCollectTask.FRONT_LENGTH and side <= ADBaleCollectTask.FRONT_HALF_WIDTH then
            return true
        end
    end
    return false
end

-- after = "find" (balle suivante) ou "done" (rendre la main pour le dépôt) ; force : sans limite de nombre
function ADBaleCollectTask:startBackOff(after, why, force)
    local tx, _, tz = self:tractorPose()
    -- compte remis à zéro quand le tracteur a roulé ailleurs depuis la fin du dernier recul
    if self.backOffEnd == nil or MathUtil.vector2Length(tx - self.backOffEnd.x, tz - self.backOffEnd.z) > ADBaleCollectTask.BACKOFF_SAME_PLACE then
        self.backOffCount = 0
    end
    if not force and self.backOffCount >= ADBaleCollectTask.BACKOFF_MAX then
        log("%s : %s, déjà %d recul(s) ici", self:name(), tostring(why), self.backOffCount)
        return false
    end
    self.backOffCount = self.backOffCount + 1
    self.backOffStart = { x = tx, z = tz }
    self.backOffAfter = after
    self.rearBlockedTime = 0
    local rx, ry, rz = AutoDrive.localToWorld(self.vehicle, 0, 0, -100)
    self.backOffTarget = { x = rx, y = ry, z = rz }
    self.target = nil
    self:claim(nil)
    self.vehicle.ad.specialDrivingModule:reset()
    log("%s : %s, recul de %d m puis nouveau calcul (recul %d)", self:name(), tostring(why), ADBaleCollectTask.BACKOFF_DISTANCE, self.backOffCount)
    self:setState("backoff")
    return true
end

function ADBaleCollectTask:updateBackOff(dt)
    local tx, _, tz = self:tractorPose()
    local done = MathUtil.vector2Length(tx - self.backOffStart.x, tz - self.backOffStart.z)
    local sdm = self.vehicle.ad.specialDrivingModule
    local rearBlocked = self.vehicle.ad.collisionDetectionModule:checkReverseCollision() == true
    self.rearBlockedTime = rearBlocked and (self.rearBlockedTime + dt) or 0
    local rearStop = self.rearBlockedTime >= ADBaleCollectTask.BACKOFF_REAR_BLOCKED
    local timedOut = self.timer >= ADBaleCollectTask.BACKOFF_TIMEOUT
    if done >= ADBaleCollectTask.BACKOFF_DISTANCE or rearStop or timedOut then
        log("%s : recul fini (%.1f m%s)", self:name(), done, rearStop and ", arrêté par le capteur arrière" or (timedOut and ", délai dépassé" or ""))
        self.backOffEnd = { x = tx, z = tz }
        sdm:reset()
        self:holdVehicle(dt)
        if self.backOffAfter == "done" then
            self:finished()
        else
            self:setState("find")
        end
        return
    end
    if rearBlocked then
        sdm:stopAndHoldVehicle(dt)
        return
    end
    sdm:releaseVehicle()
    local v = self.vehicle
    if v.startMotor ~= nil and v.getIsMotorStarted ~= nil and not v:getIsMotorStarted() and (v.getCanMotorRun == nil or v:getCanMotorRun()) then
        v:startMotor()
    end
    sdm:reverseToTargetLocation(dt, self.backOffTarget, ADBaleCollectTask.BACKOFF_SPEED)
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin
-- ------------------------------------------------------------------------------------------------------------
function ADBaleCollectTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.target = nil
    self:claim(nil)
    log("%s : ramassage fini (%s), %d balle(s) ramassée(s), %d chargée(s)", self:name(), tostring(result), self.picked,
        ADBaleLoaderManager.loadedCount(self.loader))
    if result == "full" or result == "noBales" or result == "continue" then
        -- bras rentré avant la route
        self.foldRequested = false
        self:setState("fold")
        return
    end
    self:finished()
end

function ADBaleCollectTask:abort()
    self:claim(nil)
end

function ADBaleCollectTask:finished()
    self:claim(nil)
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function ADBaleCollectTask:getI18nInfo()
    if self.state == "planning" then
        return self:getPlanningI18n()
    end
    return "$l10n_AD_task_autonomous_bales;" .. string.format(" (%d)", ADBaleLoaderManager.loadedCount(self.loader))
end
