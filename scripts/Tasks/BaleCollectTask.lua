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
-- - Axe d'approche : balle ronde = du tracteur vers la balle ; balle carrée = dans la longueur de la balle (le sens le
--   plus proche). Le chemin jusqu'au début de la ligne (APPROACH_RUN m avant le bras) : chercheur de chemin de
--   FarmPilot ; déjà dans l'axe : pas de chemin, la ligne directement.
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
--
-- Lancé par AutonomousBales.lua (étape « collect »).
-- ============================================================================================================

ADBaleCollectTask = ADInheritsFrom(AbstractTask)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADBaleCollectTask.APPROACH_SPEED = 6        -- km/h sur la ligne d'approche
ADBaleCollectTask.LINE_LOOKAHEAD = 5        -- m : point suivi devant le tracteur, sur la ligne
ADBaleCollectTask.APPROACH_RUN = 12         -- m de ligne droite avant que le bras arrive à la balle
ADBaleCollectTask.ON_LINE_DISTANCE = 0.8    -- m : tracteur à moins de ça de la ligne = déjà dans l'axe
ADBaleCollectTask.ON_LINE_ANGLE = 12        -- degrés : tracteur et remorque dans l'axe à moins de ça
ADBaleCollectTask.PASS_BEYOND = 3           -- m : bras passé de ça après la balle sans l'attraper = raté
ADBaleCollectTask.MAX_TRIES = 2             -- essais par balle
ADBaleCollectTask.BEHIND_PENALTY = 20       -- m ajoutés à la distance d'une balle derrière le tracteur (demi-tour)
ADBaleCollectTask.PREPARE_TIMEOUT = 20000   -- ms pour sortir ou rentrer le bras
ADBaleCollectTask.REQUEST_INTERVAL = 5000   -- ms entre deux demandes de sortie du bras
ADBaleCollectTask.APPROACH_TIMEOUT = 60000  -- ms sur la ligne d'approche
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

-- axe x (local) d'un nœud tourné vers d : même convention que le moteur, lue sur le nœud lui-même
local function sideOf(node, dx, dz)
    local hx, _, hz = localDirectionToWorld(node, 0, 0, 1)
    local sx, _, sz = localDirectionToWorld(node, 1, 0, 0)
    local c = hz * sx - hx * sz
    c = c >= 0 and 1 or -1
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

-- sens d'approche d'une balle : ronde = du tracteur vers la balle ; carrée = sa longueur, le sens le plus proche
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

-- ligne d'approche de la cible : P0 (point de la ligne au droit de la balle), sens d, côté xd, départ A
function ADBaleCollectTask:makeLine(c)
    local gx, behind = self:grabGeometry()
    if gx == nil then
        return nil
    end
    local dx, dz = self:approachDir(c)
    local sx, sz = sideOf(rootOf(self.loader), dx, dz)
    local line = { bx = c.x, bz = c.z, dx = dx, dz = dz, sx = sx, sz = sz, gx = gx, behind = behind }
    line.p0x, line.p0z = c.x - sx * gx, c.z - sz * gx
    local back = math.max(ADBaleCollectTask.APPROACH_RUN * 0.5, behind + ADBaleCollectTask.APPROACH_RUN)
    line.ax, line.az = line.p0x - dx * back, line.p0z - dz * back
    return line
end

-- tracteur déjà sur la ligne, dans l'axe, assez loin avant la balle
function ADBaleCollectTask:isOnLine(line)
    local tx, _, tz, hx, hz = self:tractorPose()
    local rx, rz = tx - line.p0x, tz - line.p0z
    local lateral = math.abs(rx * line.sx + rz * line.sz)
    local along = rx * line.dx + rz * line.dz
    local lx, lz = self:loaderDir()
    return lateral <= ADBaleCollectTask.ON_LINE_DISTANCE and angleBetween(hx, hz, line.dx, line.dz) <= ADBaleCollectTask.ON_LINE_ANGLE
        and angleBetween(lx, lz, line.dx, line.dz) <= ADBaleCollectTask.ON_LINE_ANGLE and along <= -(line.behind + 4)
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
    -- le bras attrape une balle (visée ou non) : arrêt jusqu'à la fin du chargement
    -- (pas pendant le recul : le bras finit de se replier, on ne vise rien)
    if self.state ~= "grab" and self.state ~= "prepare" and self.state ~= "fold" and self.state ~= "backoff" and ADBaleLoaderManager.isBusy(loader) then
        self.countBefore = self.countBefore or ADBaleLoaderManager.loadedCount(loader)
        self:setState("grab")
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
        self:holdVehicle(dt)
        if not ADBaleLoaderManager.isBusy(loader) or self.timer >= ADBaleCollectTask.GRAB_TIMEOUT then
            local now = ADBaleLoaderManager.loadedCount(loader)
            if now > (self.countBefore or now) or self.target ~= nil and ADBaleLoaderManager.rejectReason(loader, self.target.bale, self.wrap) ~= nil then
                self.picked = self.picked + math.max(1, now - (self.countBefore or now))
            end
            self.countBefore = nil
            self.target = nil
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
    local c = self:nearest(list)
    if c == nil then
        self:finish("noBales")
        return
    end
    local line = self:makeLine(c)
    if line == nil then
        log("%s : la remorque n'a pas de bras (nœud grabNode) : arrêt", self:name())
        self:finish("noWork")
        return
    end
    self.target = c
    self.line = line
    self:claim(c.bale)
    if self:isOnLine(line) then
        log("%s : balle à %.0f m, déjà dans l'axe (bras à %.1f m de côté)", self:name(), self:distanceTo(c), line.gx)
        self:startApproach()
        return
    end
    local pf = self.vehicle.ad.pathFinderModule
    pf:reset()
    pf:startPathPlanningTo({ x = line.ax, y = c.y, z = line.az }, { x = line.dx, z = line.dz })
    log("%s : balle à %.0f m (%d à ramasser), chemin vers la ligne d'approche (bras à %.1f m de côté, %.1f m derrière le tracteur)",
        self:name(), self:distanceTo(c), #list, line.gx, line.behind)
    self:setState("planning")
end

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
    self:setState("approach")
end

-- sur la ligne : point suivi devant le tracteur ; le bras passe sur la balle
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
    if along > ADBaleCollectTask.PASS_BEYOND then
        self:holdVehicle(dt)
        self:missed(string.format("bras passé à %.1f m de la balle", math.abs(self.bestLateral or lateral)))
        return
    end
    if self.timer >= ADBaleCollectTask.APPROACH_TIMEOUT then
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
    local tx, ty, tz = self:tractorPose()
    local s = (tx - line.p0x) * line.dx + (tz - line.p0z) * line.dz
    local cx = line.p0x + line.dx * (s + ADBaleCollectTask.LINE_LOOKAHEAD)
    local cz = line.p0z + line.dz * (s + ADBaleCollectTask.LINE_LOOKAHEAD)
    local speed = ADBaleCollectTask.APPROACH_SPEED
    -- sans contrôle de collision : les capteurs verraient la balle visée (et celles d'à côté)
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, { x = cx, y = ty, z = cz }, speed, false, 0.5, speed, true)
end

-- ------------------------------------------------------------------------------------------------------------
-- Recul quand le départ est bloqué
-- ------------------------------------------------------------------------------------------------------------
-- une balle du champ juste devant le tracteur (FRONT_LENGTH m devant son avant, FRONT_HALF_WIDTH m de chaque côté)
function ADBaleCollectTask:baleInFront()
    local okL, list = pcall(ADBaleLoaderManager.findBales, self.loader, self.ctx.fieldNums, ADBaleLoaderManager.WRAP_ALL, {})
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
        log("%s : %s, déjà %d recul(s) ici : essai compté comme raté", self:name(), tostring(why), self.backOffCount)
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
    if result == "full" or result == "noBales" then
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
