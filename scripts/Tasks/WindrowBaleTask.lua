-- ============================================================================================================
-- FarmPilot : WindrowBaleTask.lua
-- Mode Autonome, presse : pressage des andains du champ par FarmPilot seul, sans Courseplay (15/11).
--
-- Règle (15/11) :
-- - Liste des andains donnée au départ (ADWindrowScan, WindrowScan.lua : ligne médiane ordonnée, un point tous les
--   ~2 m). (17/11) Andain suivant : d'abord celui qui continue tout droit devant (bout à AHEAD_DIST m au plus de
--   l'attelage, devant le pick-up, à AHEAD_LATERAL m au plus de l'axe du tracteur, andain qui part dans le même sens à
--   AHEAD_ANGLE° près) ; sinon le bout le plus proche de l'attelage (tracteur -> presse), un demi-tour (UTURN_ANGLE)
--   compté UTURN_COST m de plus. On y entre par ce bout, dans l'axe de l'andain (sens pris sur ses ENTRY_DIR_LENGTH
--   premiers mètres). Raison du choix au journal.
-- - Ligne d'approche (comme le ramassage des balles, BaleCollectTask.lua) : le tracteur arrive au point A, dans l'axe,
--   assez loin avant le bout pour que la presse traînée soit droite quand le pick-up y arrive. Longueur droite :
--   presse en biais de asin(timon / rayon) au sortir du virage (rayon de braquage de l'ensemble, celui du chercheur
--   de chemin), écart qui se résorbe sur la longueur du timon : timon x ln(angle / STRAIGHT_ANGLE), entre
--   APPROACH_MIN et APPROACH_MAX m. Début de ligne hors du champ : ligne raccourcie (BACK_MIN m au moins), sinon
--   l'autre bout, sinon l'andain est laissé (raison au journal).
-- - Chemin jusqu'à A : déjà dans l'axe = tout droit ; sinon chercheur de chemin de FarmPilot (champ, règles Strict :
--   jamais dans la culture pas récoltée), balles posées données comme zones interdites ; chemin rendu relu (tracteur
--   et presse traînée simulée le long du chemin) : il ne doit passer sur aucune balle. Pas de chemin, ou chemin qui
--   passe sur une balle : courbe de Dubins au rayon de l'ensemble (les 6 formes essayées, la plus courte qui reste sur
--   le champ, hors culture et loin des balles) ; sinon approche directe si l'andain est devant ; sinon bout laissé.
--   (17/11) Courbe et approche directe : tracteur ET presse, avec leurs demi-largeurs, sur le champ à chaque mètre ;
--   l'exception « parti d'en dehors de tout champ » seulement si l'ensemble démarre vraiment hors du champ, et une
--   fois entré il n'en ressort plus ; objets fixes contrôlés (arbres, souches, poteaux : overlapBox comme le chercheur
--   de chemin). Réglage « champ : strict » : jamais hors du champ, ni l'herbe de la parcelle (sol qui n'est pas du
--   champ), ni la marge du bord pour la ligne d'approche. Courbe refusée : la raison et le point au journal.
-- - Sur l'andain : c'est le PICK-UP de la presse qui suit le milieu de l'andain, pas le tracteur. Le point suivi par
--   le tracteur est pris sur la ligne de l'andain décalée vers l'avant de la distance tracteur -> pick-up (dans le sens
--   de l'andain) et de l'écart du pick-up sur le côté : dans une courbe la presse traînée coupe le virage, le tracteur
--   passe donc à l'extérieur (sqrt(r² + d²) - r). L'écart du pick-up qui reste est corrigé en plus (FB_GAIN, et une
--   part lente FB_INTEGRAL). Le milieu de l'andain est relu PROBE_AHEAD m devant le pick-up
--   (ADWindrowScan.crossPieces, sinon centerOffset) tous les PROBE_STEP m et la ligne suivie est corrigée d'autant
--   (balayage imprécis, andain plus long que prévu) ; la correction est gardée sur la ligne prévue devant (PREDICT m).
--   (17/11) Andain large (plus large que le pick-up + WIDE_MARGIN) : milieu de toute sa largeur (relue sur
--   ± WIDE_HALF_SPAN m s'il touche le bord de la lecture, trous de moins de MERGE_GAP m dedans comptés), lissé
--   (WIDE_GAIN) et recentrage limité (WIDE_RATE m par m) : pas de saut d'un bord à l'autre. Fourche, jonction : tas lu
--   plus large que FORK_WIDTH x la largeur habituelle de l'andain : le bord qui continue la ligne suivie est gardé
--   (branche dans l'axe) ; deux tas séparés côte à côte : celui de la ligne suivie, jamais le milieu des deux ; l'autre
--   branche reste un andain à part, fait après.
-- - (17/11) Trou réuni par le balayage (andain.gaps, jusqu'à 10 m entre deux bouts alignés) : rien n'y est relu, la
--   ligne continue tout droit, la fin de l'andain n'y est pas prise.
-- - (18/11) Andain collé au bord : pendant le suivi et sur la ligne droite d'approche (pas les courbes de demi-tour),
--   en champ strict, tracteur et presse (avec leurs demi-largeurs) peuvent sortir du sol du champ jusqu'à EDGE_GRASS m
--   sur l'herbe du bord, jamais sur un autre champ ; objets fixes (arbres, souches, poteaux) jamais, dans tous les
--   réglages. Contrôle devant, sur la trajectoire prévue du tracteur et de la presse (ligne suivie et ligne prévue,
--   EDGE_LOOK m, tous les EDGE_STEP m) : ralenti avant, arrêt EDGE_STOP m avant ; le reste de l'andain devient un
--   morceau à part, essayé plus tard par son autre bout s'il va, sinon laissé ; raison, distance et point au journal.
-- - Fin de l'andain : plus d'andain lu sur END_GAP m devant et pick-up passé END_MARGIN m après le dernier andain vu.
--   Puis l'andain suivant (demi-tour au rayon dans le champ par le chemin ci-dessus). Au-delà du bout du balayage, la
--   ligne prolongée ne tourne pas (END_SHIFT + END_SPREAD par m) : un andain de fourrière en travers n'est pas suivi.
--   Bout arrêté contre un autre andain de la liste (à moins de JOIN_DIST m, le balayage le finit sur l'axe de
--   l'autre) : fin au bout du balayage, rien n'est relu au-delà.
-- - Tour de fourrière fermé (closed, le dernier point répète le premier, coupé dans un coin) : coupé à nouveau sur une
--   partie droite au plus près de l'attelage, pour entrer dans l'axe.
-- - Balles posées = obstacles : jamais sur la ligne d'approche ni sur un chemin ; balle sur l'andain devant le tracteur :
--   arrêt de cet andain là, le morceau après la balle est gardé pour plus tard.
-- - Presse (ADBalerControl, BalerControl.lua) : vitesse au plus ADBalerControl.speedLimit (km/h), arrêt tant que
--   ADBalerControl.mustStop (balles rondes : éjection), fin « refill » dès que ADBalerControl.twineEmpty.
-- - Liste finie : s'il reste de l'andain au champ (ADWindrowScan.anyLeft), nouveau balayage (au plus RESCAN_MAX fois).
-- - Fin : self.result = « done » (plus d'andain faisable), « refill » (ficelle / filet vide), « blocked » (rien de
--   faisable : aucun andain pressé par la tâche ; ceux laissés sont au journal et dans getProgress().left),
--   « detached » (presse dételée). ctx.fieldNums : ensemble { [n] = true } ou liste { n1, n2 }.
-- - Bandeau : « Presse les andains (faits/total) » ; getProgress() pour la sauvegarde.
-- - Journal [FarmPilot Presse] : andain choisi (id, longueur, distance), entrée (écart du pick-up, presse droite ou
--   non), fin (mètres suivis, écart moyen et maxi du pick-up), demi-tour, blocage avec la raison.
--
-- Branché par : AutonomousWindrow.lua (ADWindrowMode : arrivée au champ, après le balayage). Lit ADWindrowScan
-- (WindrowScan.lua), ADBalerControl (BalerControl.lua), ADBaleLoaderManager.fieldBales (balles posées).
-- ============================================================================================================

ADWindrowBaleTask = ADInheritsFrom(AbstractTask)

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADWindrowBaleTask.WORK_SPEED = 14           -- km/h au plus sur l'andain, en ligne droite
ADWindrowBaleTask.APPROACH_SPEED = 12       -- km/h sur la ligne d'approche, loin de l'entrée
ADWindrowBaleTask.SLOW_BEFORE = 10          -- m : pick-up à moins de ça de l'entrée = vitesse de travail
ADWindrowBaleTask.CURVE_RADIUS = 30         -- m : andain plus serré que ça = plus lent
ADWindrowBaleTask.CURVE_SPEED = 0.6         -- km/h par mètre de rayon dans une courbe
ADWindrowBaleTask.MIN_SPEED = 3             -- km/h au moins (sauf arrêt demandé)
ADWindrowBaleTask.LINE_SLOW_ANGLE = 45      -- degrés : point suivi plus en biais = ralentissement (driveToPoint)
ADWindrowBaleTask.LINE_SLOW_FACTOR = 0.5
ADWindrowBaleTask.LOOK_MIN = 4.5            -- m : point suivi devant le tracteur (au moins)
ADWindrowBaleTask.LOOK_MAX = 9
ADWindrowBaleTask.LOOK_TIME = 1.5           -- s : plus loin quand il roule plus vite
ADWindrowBaleTask.PROBE_AHEAD = 5           -- m devant le pick-up : lecture du milieu de l'andain
ADWindrowBaleTask.PROBE_STEP = 1            -- m entre deux lectures
ADWindrowBaleTask.PROBE_HALF_SPAN = 2.5     -- m de chaque côté de la ligne : andain cherché en travers
ADWindrowBaleTask.PROBE_MAX_SHIFT = 1.5     -- m : correction de la ligne au plus par lecture
ADWindrowBaleTask.PROBE_BLEND = 0.9         -- part de l'écart lu reportée sur la ligne suivie
ADWindrowBaleTask.PROBE_MAX_PER_FRAME = 12  -- lectures au plus par image
ADWindrowBaleTask.END_GAP = 5               -- m sans andain lu devant = fin de l'andain
ADWindrowBaleTask.END_MARGIN = 1            -- m : pick-up passé de ça après le dernier andain vu
ADWindrowBaleTask.JOIN_DIST = 2.5           -- m : bout d'andain si près d'un autre andain = arrêté contre lui
ADWindrowBaleTask.END_ZONE = 3              -- m au bout arrêté contre un autre andain : décalage relu limité
ADWindrowBaleTask.END_SHIFT = 0.3           -- m : décalage relu au plus là, et juste après le bout du balayage...
ADWindrowBaleTask.END_SPREAD = 0.1          -- ... plus ça par m au-delà (la ligne prolongée ne tourne pas)
ADWindrowBaleTask.END_OUTSIDE = 0.5         -- m : andain lu au-delà, plus loin de la ligne prolongée = un autre andain
ADWindrowBaleTask.LOOP_STRAIGHT = 8         -- m de part et d'autre du point de coupe d'un tour fermé...
ADWindrowBaleTask.LOOP_ANGLE = 10           -- ... avec au plus ça (°) entre les deux côtés (partie droite)
ADWindrowBaleTask.FB_GAIN = 0.8             -- part de l'écart du pick-up corrigée (point suivi décalé d'autant)
ADWindrowBaleTask.FB_INTEGRAL = 0.04        -- part lente, par mètre roulé
ADWindrowBaleTask.FB_MAX = 1.5              -- m : décalage maxi du point suivi par la correction
ADWindrowBaleTask.FB_HEADING_MAX = 30       -- degrés : presse plus en biais sur la ligne = pas de correction
ADWindrowBaleTask.COMPENSATE = true         -- point suivi décalé pour le pick-up (false : le tracteur suit l'andain)
ADWindrowBaleTask.STRAIGHT_ANGLE = 2        -- degrés : presse « droite » à l'entrée
ADWindrowBaleTask.APPROACH_MIN = 15         -- m droits au moins avant que le pick-up arrive au bout
ADWindrowBaleTask.APPROACH_MAX = 30
ADWindrowBaleTask.SETTLE = 8                -- m de ligne en plus au début : le tracteur finit son virage (fin du chemin)
ADWindrowBaleTask.BACK_MIN = 4              -- m : début de ligne au moins à ça avant le bout (tracteur)
ADWindrowBaleTask.BACK_STEP = 2             -- m : raccourci de ça à chaque essai (début de ligne hors du champ)
ADWindrowBaleTask.ENTRY_DIR_LENGTH = 6      -- m d'andain pris pour son sens à l'entrée
ADWindrowBaleTask.ENTRY_PROBE_LENGTH = 8    -- m d'andain relus (milieu) au choix du bout, avant de faire la ligne
ADWindrowBaleTask.REF_EXTRA = 6             -- m de ligne en plus derrière le début de la ligne d'approche
ADWindrowBaleTask.PICKUP_TO_AXLE = 2.0      -- m : pick-up -> essieu de la presse quand les roues sont illisibles
ADWindrowBaleTask.SWEEP_TOW_MARGIN = 1.15   -- timon compté plus long pour la presse simulée le long d'un chemin
ADWindrowBaleTask.SWEEP_MARGIN = 1.0        -- m de plus autour du tracteur et de la presse (virages coupés par le suivi)
ADWindrowBaleTask.TURN_RADIUS = 9           -- m : rayon de l'ensemble quand le chercheur de chemin ne le donne pas
ADWindrowBaleTask.ON_LINE_ANGLE = 12        -- degrés : tracteur et presse dans l'axe à moins de ça
ADWindrowBaleTask.ON_LINE_DISTANCE = 0.8    -- m : pick-up à moins de ça de l'axe = déjà dans l'axe
ADWindrowBaleTask.ON_LINE_SLOPE = 0.05      -- m d'écart permis en plus par mètre jusqu'au bout
ADWindrowBaleTask.ON_LINE_MIN = 3           -- m : pick-up au moins à ça avant le bout
ADWindrowBaleTask.DIRECT_ANGLE = 45         -- degrés : approche directe (sans chemin) seulement si l'andain est devant
ADWindrowBaleTask.DIRECT_LATERAL = 10       -- m d'écart au plus à l'axe pour l'approche directe
ADWindrowBaleTask.DIRECT_ROOM = 15          -- m droits au moins devant le pick-up pour l'approche directe
ADWindrowBaleTask.UTURN_ANGLE = 100         -- degrés de virage et plus = demi-tour (journal)
ADWindrowBaleTask.BALE_RADIUS = 1.0         -- m : rayon d'une balle posée (avec marge)
ADWindrowBaleTask.BALE_ZONE = 1.5           -- m : zone interdite autour d'une balle pour le chercheur de chemin
ADWindrowBaleTask.BALE_LOOK = 25            -- m devant l'avant du tracteur : balle sur l'andain = ralentir
ADWindrowBaleTask.BALE_STOP = 4             -- m + rayon de braquage entre l'avant du tracteur et la balle : arrêt de
                                            -- l'andain là (place pour tourner sans toucher la balle)
ADWindrowBaleTask.BALE_SLOW_SPEED = 4       -- km/h en arrivant vers une balle posée sur l'andain
ADWindrowBaleTask.BALE_CLEAR = 3            -- m après la balle : début du morceau gardé
ADWindrowBaleTask.MIN_PIECE = 5             -- m : morceau plus court = pas gardé
ADWindrowBaleTask.BALE_CHECK_INTERVAL = 300 -- ms entre deux contrôles des balles devant
ADWindrowBaleTask.BALES_EVERY = 500         -- ms : liste des balles du champ relue au plus souvent que ça
ADWindrowBaleTask.MAX_END_TRIES = 2         -- essais par bout d'andain (chemin, blocage)
ADWindrowBaleTask.BACK_CUT = 4              -- m de ligne d'approche en moins après un chemin introuvable
ADWindrowBaleTask.DRIVE_TIMEOUT = 180000    -- ms sur le chemin jusqu'à la ligne d'approche
ADWindrowBaleTask.STUCK_TIME = 15000        -- ms arrêté sur la ligne (sans arrêt demandé) = bloqué
ADWindrowBaleTask.PATH_CHECK_INTERVAL = 1000 -- ms entre deux contrôles du chemin (balle posée dessus)
ADWindrowBaleTask.RESCAN_MAX = 1            -- nouveau balayage au plus quand la liste est finie (le mode en relance un
                                            -- autre si la tâche finit « done » avec de l'andain au champ)
ADWindrowBaleTask.RESCAN_BUDGET = 300       -- lectures du sol par image pendant un nouveau balayage, si le mode n'en donne
                                            -- pas (sinon celles de sa recherche : ADWindrowMode.SCAN_BUDGET, petits PC)
ADWindrowBaleTask.DUBINS_STEP = 1           -- m entre deux points d'une courbe de Dubins
ADWindrowBaleTask.EDGE_MARGIN = 10          -- m : début de ligne hors de tout champ permis à moins de ça du champ
-- (17/11) andain suivant
ADWindrowBaleTask.AHEAD_DIST = 30           -- m : bout à moins de ça de l'attelage, devant dans l'axe = suite tout droit
ADWindrowBaleTask.AHEAD_LATERAL = 3         -- m : bout à moins de ça de l'axe du tracteur (de côté)
ADWindrowBaleTask.AHEAD_ANGLE = 30          -- degrés : andain qui part dans le sens du tracteur à moins de ça
ADWindrowBaleTask.AHEAD_MIN = 0.5           -- m : bout au moins à ça devant le pick-up
ADWindrowBaleTask.UTURN_COST = 40           -- m comptés en plus pour un bout qui demande un demi-tour (UTURN_ANGLE)
-- (17/11) trous, andain large, fourche
ADWindrowBaleTask.GAP_EDGE = 0.5            -- m : trou réuni par le balayage, pas relu à plus de ça de ses bouts
ADWindrowBaleTask.PREDICT = 12              -- m de ligne devant la dernière lecture décalés comme elle (ligne prévue)
ADWindrowBaleTask.WIDE_HALF_SPAN = 4.5      -- m : tas qui touche le bord de la lecture relu sur ± ça (toute sa largeur)
ADWindrowBaleTask.MERGE_GAP = 1.0           -- m : deux morceaux plus près que ça = le même andain (trou dans un andain)...
ADWindrowBaleTask.MERGE_WIDTH = 1.3         -- ... s'ils ne sont pas plus larges ensemble que ça x la largeur habituelle
ADWindrowBaleTask.WIDTH_EXTRA = 0.5         -- m ajoutés à MERGE_WIDTH et FORK_WIDTH x la largeur habituelle
ADWindrowBaleTask.ANCHOR_EXTRA = 0.6        -- m : tas lu plus large que la largeur habituelle + ça (fourche, jonction, andain
                                            -- qui touche) : milieu pris depuis le bord qui continue la ligne suivie (andain
                                            -- large : seulement au-delà de FORK_WIDTH x sa largeur habituelle + WIDTH_EXTRA)
ADWindrowBaleTask.FORK_WIDTH = 1.5          -- tas lu plus large que ça x la largeur habituelle (+ WIDTH_EXTRA) : fourche ou
                                            -- jonction au journal
ADWindrowBaleTask.FORK_STICKY = 0.5         -- m : bord gardé d'une lecture à l'autre sauf si l'autre va mieux de ça
ADWindrowBaleTask.WIDTH_SAMPLES = 3         -- lectures pour la largeur habituelle au début de l'andain...
ADWindrowBaleTask.WIDTH_SKIP = 2.5          -- ... à partir de ça (m) après le bout d'entrée (bout arrondi, plus étroit)
ADWindrowBaleTask.WIDTH_RATE = 0.1          -- part d'une lecture dans la largeur habituelle ensuite
ADWindrowBaleTask.WIDTH_NARROW = 0.6        -- lecture plus étroite que ça x la largeur habituelle (andain entamé) : pas
                                            -- comptée dans la largeur habituelle
ADWindrowBaleTask.RESIDUE_PART = 0.15       -- morceau de moins de ça x les litres habituels d'une lecture = restes (passage
                                            -- d'une roue, d'un pick-up) : pas lu, la ligne continue tout droit
ADWindrowBaleTask.ANCHOR_RELEARN = 15       -- m de suite plus large que d'habitude sans fourche finie : largeur habituelle
                                            -- relue (mal apprise au début), bord plus suivi
ADWindrowBaleTask.WIDE_MARGIN = 0.3         -- m : andain plus large que le pick-up + ça = andain large
ADWindrowBaleTask.WIDE_GAIN = 0.3           -- andain large : part de l'écart lu reportée sur la ligne (lissé sur ~3 m)
ADWindrowBaleTask.WIDE_RATE = 0.2           -- m par m : andain large, recentrage au plus
ADWindrowBaleTask.SIDE_NEAR = 2.5           -- m : autre tas à moins de ça du tas suivi = deux tas côte à côte (journal)
ADWindrowBaleTask.PICKUP_WIDTH = 2.0        -- m : largeur du pick-up quand la zone de travail est illisible
-- (17/11) courbe et approche directe : objets fixes
ADWindrowBaleTask.OBSTACLE_STEP = 2         -- m entre deux contrôles d'objets fixes le long d'une courbe
ADWindrowBaleTask.OBSTACLE_GROUND = 0.3     -- m au-dessus du sol : début de la boîte contrôlée (pas le sol)
ADWindrowBaleTask.OBSTACLE_HEIGHT = 3       -- m de haut contrôlés au-dessus
ADWindrowBaleTask.OBSTACLE_MARGIN = 0.3     -- m de plus de chaque côté du tracteur et de la presse
ADWindrowBaleTask.EDGE_START = 10           -- m : ensemble arrêté au bord, un côté déjà dehors (milieu sur le champ) : ce
                                            -- côté toléré au plus sur ça au début d'une courbe, s'il rentre
-- (18/11) andain collé au bord : suivi et ligne droite d'approche
ADWindrowBaleTask.EDGE_GRASS = 3            -- m : champ strict, tracteur et presse au plus à ça hors du sol du champ (herbe
                                            -- du bord, hors de tout autre champ, sans objet fixe)
ADWindrowBaleTask.EDGE_SEARCH = 0.5         -- m entre deux lectures en cherchant le sol du champ (distance au bord)
ADWindrowBaleTask.EDGE_LOOK = 12            -- m de ligne contrôlés devant le pick-up (trajectoire prévue du tracteur)...
ADWindrowBaleTask.EDGE_STEP = 2             -- ... tous les EDGE_STEP m
ADWindrowBaleTask.EDGE_STOP = 4             -- m : pick-up à moins de ça du point qui ne va pas = arrêt de l'andain
ADWindrowBaleTask.EDGE_SLOW_SPEED = 4       -- km/h quand un point qui ne va pas est dans le contrôle devant
ADWindrowBaleTask.EDGE_CHECK_INTERVAL = 300 -- ms entre deux contrôles devant

local function log(fmt, ...)
    local ok, s = FarmPilotCall(string.format, fmt, ...)
    print("[FarmPilot Presse] " .. (ok and s or tostring(fmt)))
end
ADWindrowBaleTask.log = log

-- appel d'une fonction des autres domaines (ADBalerControl, ADWindrowScan) : ok, résultat ; false si elle manque
local function callOf(module, name, ...)
    local m = module ~= nil and _G[module] or nil
    local f = m ~= nil and m[name] or nil
    if type(f) ~= "function" then
        return false, nil
    end
    return FarmPilotCall(f, ...)
end

-- ------------------------------------------------------------------------------------------------------------
-- Petits calculs
-- ------------------------------------------------------------------------------------------------------------
local function normalize(x, z)
    local l = math.sqrt(x * x + z * z)
    if l < 1e-6 then
        return 0, 1
    end
    return x / l, z / l
end

local function clamp(v, a, b)
    return math.max(a, math.min(b, v))
end

local function dist2(ax, az, bx, bz)
    return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

local function angleBetween(ax, az, bx, bz)
    local dot = clamp(ax * bx + az * bz, -1, 1)
    return math.deg(math.acos(dot))
end

-- angle signé (degrés) de a vers b, positif vers l'axe x du monde quand a regarde vers +z
local function signedAngle(ax, az, bx, bz)
    return math.deg(math.atan2(ax * bz - az * bx, ax * bx + az * bz)) * -1
end

-- droite d'une direction (x est, z sud : en regardant vers +z, la droite est vers -x) ; même sens que le « + » de
-- ADWindrowScan.centerOffset
local function rightOf(dx, dz)
    return -dz, dx
end

-- axe x (local) d'un nœud tourné vers d (côté gauche pour le moteur du jeu)
local function handOf(node)
    local hx, _, hz = localDirectionToWorld(node, 0, 0, 1)
    local sx, _, sz = localDirectionToWorld(node, 1, 0, 0)
    local c = hz * sx - hx * sz
    return c >= 0 and 1 or -1
end

local function sideOf(hand, dx, dz)
    return hand * dz, -hand * dx
end

-- distance d'un point au segment [a, b]
local function segDist(px, pz, ax, az, bx, bz)
    local ux, uz = bx - ax, bz - az
    local l2 = ux * ux + uz * uz
    local t = 0
    if l2 > 1e-9 then
        t = clamp(((px - ax) * ux + (pz - az) * uz) / l2, 0, 1)
    end
    return dist2(px, pz, ax + ux * t, az + uz * t)
end

local function rootOf(object)
    return object.rootNode or (object.components ~= nil and object.components[1] ~= nil and object.components[1].node) or nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Ligne suivie (pick-up) : polyligne, un point par mètre ; s = abscisse, sE = abscisse du bout d'entrée
-- ------------------------------------------------------------------------------------------------------------
local Ref = {}

function Ref.new()
    return { x = {}, z = {}, s = {}, n = 0, sE = 0 }
end

function Ref.add(r, x, z)
    if r.n > 0 then
        local d = dist2(x, z, r.x[r.n], r.z[r.n])
        if d < 0.05 then
            return
        end
        r.n = r.n + 1
        r.s[r.n] = r.s[r.n - 1] + d
    else
        r.n = 1
        r.s[1] = 0
    end
    r.x[r.n], r.z[r.n] = x, z
end

-- points d'une liste {x, z} ajoutés tous les step mètres (le dernier aussi)
function Ref.addResampled(r, pts, step)
    if #pts == 0 then
        return
    end
    Ref.add(r, pts[1].x, pts[1].z)
    local carry = 0
    for i = 2, #pts do
        local ax, az, bx, bz = pts[i - 1].x, pts[i - 1].z, pts[i].x, pts[i].z
        local len = dist2(ax, az, bx, bz)
        local t = step - carry
        while t <= len - 1e-6 do
            Ref.add(r, ax + (bx - ax) * t / len, az + (bz - az) * t / len)
            t = t + step
        end
        carry = len - (t - step)
    end
    Ref.add(r, pts[#pts].x, pts[#pts].z)
end

function Ref.recompute(r, from)
    for i = math.max(2, from or 2), r.n do
        r.s[i] = r.s[i - 1] + dist2(r.x[i], r.z[i], r.x[i - 1], r.z[i - 1])
    end
end

-- indice du segment qui porte l'abscisse s (1 .. n-1)
function Ref.index(r, s)
    if r.n < 2 or s <= r.s[1] then
        return 1
    end
    if s >= r.s[r.n] then
        return math.max(1, r.n - 1)
    end
    local lo, hi = 1, r.n
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if r.s[mid] <= s then
            lo = mid
        else
            hi = mid
        end
    end
    return lo
end

-- point à l'abscisse s (prolongé tout droit avant le début et après la fin)
function Ref.point(r, s)
    if r.n == 1 then
        return r.x[1], r.z[1]
    end
    local i = Ref.index(r, s)
    local len = r.s[i + 1] - r.s[i]
    local t = len > 1e-6 and (s - r.s[i]) / len or 0
    return r.x[i] + (r.x[i + 1] - r.x[i]) * t, r.z[i] + (r.z[i + 1] - r.z[i]) * t
end

-- sens de la ligne à l'abscisse s (lissé sur ±h m)
function Ref.tangent(r, s, h)
    h = h or 1.5
    if r.n < 2 then
        return 0, 1
    end
    local ax, az = Ref.point(r, s - h)
    local bx, bz = Ref.point(r, s + h)
    if dist2(ax, az, bx, bz) < 1e-3 then
        local i = Ref.index(r, s)
        return normalize(r.x[i + 1] - r.x[i], r.z[i + 1] - r.z[i])
    end
    return normalize(bx - ax, bz - az)
end

-- abscisse et écart (+ = à droite) du point (x, z) ; cherché autour de hint (± win m) si donné ; au-delà des bouts :
-- sur le prolongement
function Ref.project(r, x, z, hint, win)
    if r.n < 2 then
        return 0, 0
    end
    local i0, i1 = 1, r.n - 1
    if hint ~= nil then
        i0 = Ref.index(r, hint - (win or 10))
        i1 = Ref.index(r, hint + (win or 10))
    end
    local bestD, bestS, bestLat = math.huge, 0, 0
    for i = i0, i1 do
        local ax, az, bx, bz = r.x[i], r.z[i], r.x[i + 1], r.z[i + 1]
        local ux, uz = bx - ax, bz - az
        local len = math.sqrt(ux * ux + uz * uz)
        if len > 1e-6 then
            ux, uz = ux / len, uz / len
            local t = (x - ax) * ux + (z - az) * uz
            local tc = t
            if not (i == 1 and t < 0) and not (i == r.n - 1 and t > len) then
                tc = clamp(t, 0, len)
            end
            local qx, qz = ax + ux * tc, az + uz * tc
            local d = dist2(x, z, qx, qz)
            if d < bestD then
                local rx, rz = rightOf(ux, uz)
                bestD = d
                bestS = r.s[i] + tc
                bestLat = (x - qx) * rx + (z - qz) * rz
            end
        end
    end
    return bestS, bestLat
end

-- points à l'abscisse s et juste après décalés de off (m, + = à droite de la ligne) : plein décalage au plus près,
-- moitié à 1 m devant (relu ensuite) ; ceux d'avant, déjà relus, ne bougent pas
function Ref.shift(r, s, off)
    local tx, tz = Ref.tangent(r, s)
    local rx, rz = rightOf(tx, tz)
    local first = nil
    for i = 1, r.n do
        local d = r.s[i] - s
        if d >= -0.5 and d <= 1.5 then
            local w = d <= 0.5 and 1 or (1.5 - d)
            r.x[i] = r.x[i] + rx * off * w
            r.z[i] = r.z[i] + rz * off * w
            first = first or i
        elseif r.s[i] > s + 1.5 then
            break
        end
    end
    if first ~= nil then
        Ref.recompute(r, first)
    end
end

ADWindrowBaleTask.Ref = Ref

-- ------------------------------------------------------------------------------------------------------------
-- Création
-- ------------------------------------------------------------------------------------------------------------
-- ctx = { fieldNums, fillTypes, baler, windrows (liste d'ADWindrowScan), scan (facultatif) } ; facultatif aussi :
-- ctx.progress = { done = n } (andains faits avant une recharge : compté dans le bandeau)
function ADWindrowBaleTask:new(vehicle, ctx)
    local o = ADWindrowBaleTask:create()
    o.taskType = "ADWindrowBaleTask"
    o.vehicle = vehicle
    o.ctx = ctx or {}
    o.baler = o.ctx.baler
    o.fillTypes = o.ctx.fillTypes or {}
    o.fieldSet = ADWindrowBaleTask.fieldSet(o.ctx.fieldNums)
    o.result = nil
    o.doneBefore = o.ctx.progress ~= nil and tonumber(o.ctx.progress.done) or 0
    o.doneCount = 0
    o.rescans = 0
    o.pressedSinceScan = 0
    o.rows = {}
    o:setRows(o.ctx.windrows or {})
    return o
end

-- numéros de champ : ensemble { [n] = true } ou liste { n1, n2 } -> ensemble
function ADWindrowBaleTask.fieldSet(nums)
    local set = {}
    for k, v in pairs(nums or {}) do
        if v == true then
            set[tonumber(k) or k] = true
        elseif type(v) == "number" or type(v) == "string" then
            set[tonumber(v) or v] = true
        end
    end
    return set
end

-- andains de la liste (ceux d'au moins 2 points)
function ADWindrowBaleTask:setRows(list)
    for _, w in ipairs(list) do
        if type(w) == "table" and type(w.points) == "table" and #w.points >= 2 then
            local pts = {}
            for _, p in ipairs(w.points) do
                if type(p) == "table" and tonumber(p.x) ~= nil and tonumber(p.z) ~= nil then
                    pts[#pts + 1] = { x = tonumber(p.x), z = tonumber(p.z) }
                end
            end
            if #pts >= 2 then
                local len = 0
                for i = 2, #pts do
                    len = len + dist2(pts[i].x, pts[i].z, pts[i - 1].x, pts[i - 1].z)
                end
                local closed = w.closed == true
                    or (#pts >= 4 and len > 20 and dist2(pts[1].x, pts[1].z, pts[#pts].x, pts[#pts].z) < 1.0)
                -- (17/11) trous réunis par le balayage (abscisses depuis le premier point)
                local gaps = {}
                for _, g in ipairs(type(w.gaps) == "table" and w.gaps or {}) do
                    if type(g) == "table" and tonumber(g.from) ~= nil and tonumber(g.to) ~= nil and tonumber(g.to) > tonumber(g.from) then
                        gaps[#gaps + 1] = { from = tonumber(g.from), to = tonumber(g.to), len = tonumber(g.len) }
                    end
                end
                self.rows[#self.rows + 1] = { id = w.id ~= nil and w.id or #self.rows + 1, points = pts, length = tonumber(w.length) or len,
                    fillType = w.fillType, liters = w.liters, closed = closed, state = "todo", tries = { 0, 0 }, why = {}, index = #self.rows + 1,
                    gaps = gaps }
            end
        end
    end
    self:findJoins()
end

-- bouts arrêtés contre un autre andain de la liste (le balayage finit l'andain sur l'axe de l'autre, ~1 m dedans) :
-- row.joins[e] = id de l'autre (15/11)
function ADWindrowBaleTask:findJoins()
    for _, row in ipairs(self.rows) do
        row.joins = row.joins or {}
        if not row.closed then
            for e = 1, 2 do
                local p = e == 1 and row.points[1] or row.points[#row.points]
                for _, other in ipairs(self.rows) do
                    if other ~= row and row.joins[e] == nil then
                        for i = 2, #other.points do
                            local a, b = other.points[i - 1], other.points[i]
                            if segDist(p.x, p.z, a.x, a.z, b.x, b.z) < ADWindrowBaleTask.JOIN_DIST then
                                row.joins[e] = other.id
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

-- tour fermé : coupé (début = fin) sur une partie droite au plus près de (hx, hz) ; sinon au point le plus près
function ADWindrowBaleTask:cutLoop(row, hx, hz)
    local pts = {}
    for i, p in ipairs(row.points) do
        pts[i] = p
    end
    if #pts >= 2 and dist2(pts[1].x, pts[1].z, pts[#pts].x, pts[#pts].z) < 1.0 then
        table.remove(pts)
    end
    local n = #pts
    if n < 4 then
        return
    end
    local function walk(i, step, dist)
        local acc, k = 0, i
        repeat
            local nk = (k - 1 + step) % n + 1
            acc = acc + dist2(pts[k].x, pts[k].z, pts[nk].x, pts[nk].z)
            k = nk
        until acc >= dist or k == i
        return k
    end
    local best, bestD, near, nearD = nil, math.huge, 1, math.huge
    for i = 1, n do
        local d = dist2(pts[i].x, pts[i].z, hx, hz)
        if d < nearD then
            near, nearD = i, d
        end
        if d < bestD then
            local a, b = walk(i, -1, ADWindrowBaleTask.LOOP_STRAIGHT), walk(i, 1, ADWindrowBaleTask.LOOP_STRAIGHT)
            local ax, az = normalize(pts[i].x - pts[a].x, pts[i].z - pts[a].z)
            local bx, bz = normalize(pts[b].x - pts[i].x, pts[b].z - pts[i].z)
            if angleBetween(ax, az, bx, bz) <= ADWindrowBaleTask.LOOP_ANGLE then
                best, bestD = i, d
            end
        end
    end
    local cut = best or near
    local out = {}
    for k = 0, n - 1 do
        out[#out + 1] = pts[(cut - 1 + k) % n + 1]
    end
    out[#out + 1] = { x = pts[cut].x, z = pts[cut].z }
    row.points = out
    if row.cutX == nil or dist2(row.cutX, row.cutZ, pts[cut].x, pts[cut].z) > 0.5 then
        row.cutX, row.cutZ = pts[cut].x, pts[cut].z
        log("%s : tour fermé %s (%.0f m) coupé en (%.0f, %.0f), %s, à %.0f m de l'attelage", self:name(), tostring(row.id), row.length,
            pts[cut].x, pts[cut].z, best ~= nil and "partie droite" or "pas de partie droite", dist2(pts[cut].x, pts[cut].z, hx, hz))
    end
end

function ADWindrowBaleTask:setUp()
    self.timer = 0
    self.state = "choose"
    self.strict = self:isStrict()
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    local okG, geo = FarmPilotCall(self.measureGeometry, self)
    self.geo = okG and geo or nil
    if self.geo ~= nil then
        local g = self.geo
        log("%s : pressage des andains, %d andain(s) au champ, pick-up (%s) à %.1f m derrière le tracteur, %.1f m de côté, %.1f m de large, timon %.1f m (%s), rayon %.1f m%s",
            self:name(), #self.rows, tostring(g.source), g.behind, g.gx, g.pickupWidth or 0, g.tow, tostring(g.towSource or "-"), g.rho,
            self.strict and ", champ strict : jamais hors du champ" or "")
    else
        log("%s : pressage des andains : géométrie de la presse illisible (%s)", self:name(), tostring(geo))
    end
end

function ADWindrowBaleTask:name()
    local sm = self.vehicle.ad ~= nil and self.vehicle.ad.stateModule or nil
    return tostring(sm ~= nil and sm:getName() or "?")
end

function ADWindrowBaleTask:setState(state)
    self.state = state
    self.timer = 0
end

function ADWindrowBaleTask:holdVehicle(dt)
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self.vehicle.ad.specialDrivingModule:update(dt)
end

function ADWindrowBaleTask:speedKmh()
    return math.abs((self.vehicle.lastSpeedReal or 0) * 3600)
end

-- ------------------------------------------------------------------------------------------------------------
-- Géométrie : tracteur, attelage, pick-up
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowBaleTask:tractorPose()
    local node = self.vehicle.components[1].node
    local x, y, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    dx, dz = normalize(dx, dz)
    return x, y, z, dx, dz
end

function ADWindrowBaleTask:balerDir()
    local root = rootOf(self.baler)
    local dx, _, dz = localDirectionToWorld(root, 0, 0, 1)
    return normalize(dx, dz)
end

-- zones de travail « presse » (le pick-up) de la presse
function ADWindrowBaleTask:pickupAreas()
    if self.areas ~= nil then
        return self.areas
    end
    local b = self.baler
    local list = {}
    if WorkAreaType ~= nil and WorkAreaType.BALER ~= nil and b.getTypedWorkAreas ~= nil then
        local ok, typed = FarmPilotCall(b.getTypedWorkAreas, b, WorkAreaType.BALER)
        if ok and type(typed) == "table" then
            for _, a in pairs(typed) do
                if type(a) == "table" and a.width ~= nil and a.height ~= nil then
                    list[#list + 1] = a
                end
            end
        end
    end
    if #list == 0 and b.spec_workArea ~= nil and type(b.spec_workArea.workAreas) == "table" then
        for _, a in ipairs(b.spec_workArea.workAreas) do
            if a.width ~= nil and a.height ~= nil and (WorkAreaType == nil or WorkAreaType.BALER == nil or a.type == WorkAreaType.BALER) then
                list[#list + 1] = a
            end
        end
    end
    self.areas = list
    return list
end

-- milieu du pick-up : centre des zones de travail « presse » (parallélogramme start / width / height : milieu de
-- width et height) ; sinon milieu des repères IA ; sinon la presse elle-même
function ADWindrowBaleTask:pickupPosition()
    local areas = self:pickupAreas()
    if #areas > 0 then
        local sx, sy, sz = 0, 0, 0
        for _, a in ipairs(areas) do
            local wx, wy, wz = getWorldTranslation(a.width)
            local hx, hy, hz = getWorldTranslation(a.height)
            sx, sy, sz = sx + (wx + hx) / 2, sy + (wy + hy) / 2, sz + (wz + hz) / 2
        end
        return sx / #areas, sy / #areas, sz / #areas, "zone de travail"
    end
    if self.baler.getAIMarkers ~= nil then
        local ok, l, r = FarmPilotCall(self.baler.getAIMarkers, self.baler)
        if ok and l ~= nil and r ~= nil then
            local lx, ly, lz = getWorldTranslation(l)
            local rx, ry, rz = getWorldTranslation(r)
            return (lx + rx) / 2, (ly + ry) / 2, (lz + rz) / 2, "repères IA"
        end
    end
    local x, y, z = getWorldTranslation(rootOf(self.baler))
    return x, y, z, "centre de la presse"
end

-- (17/11) largeur du pick-up : start -> width de la zone de travail « presse » (la plus large) ; PICKUP_WIDTH sinon
function ADWindrowBaleTask:pickupWidth()
    local w = 0
    for _, a in ipairs(self:pickupAreas()) do
        if a.start ~= nil and a.width ~= nil then
            local ok, sx, _, sz = FarmPilotCall(getWorldTranslation, a.start)
            local ok2, wx, _, wz = FarmPilotCall(getWorldTranslation, a.width)
            if ok and ok2 and tonumber(sx) ~= nil and tonumber(wx) ~= nil then
                w = math.max(w, dist2(sx, sz, wx, wz))
            end
        end
    end
    return w > 0.3 and w or ADWindrowBaleTask.PICKUP_WIDTH
end

-- point d'attelage de la presse (nœud de son attelage d'entrée), nil si inconnu ou presse automotrice
function ADWindrowBaleTask:hitchPosition()
    local b = self.baler
    if b == self.vehicle or b.getActiveInputAttacherJoint == nil then
        return nil
    end
    local ok, j = FarmPilotCall(b.getActiveInputAttacherJoint, b)
    if ok and type(j) == "table" and j.node ~= nil then
        return getWorldTranslation(j.node)
    end
    return nil
end

-- rayon de braquage de l'ensemble : celui du chercheur de chemin (presse comprise), sinon TURN_RADIUS
function ADWindrowBaleTask:turnRadius()
    local pf = self.vehicle.ad.pathFinderModule
    local r = pf ~= nil and (pf.realTurnRadius or pf.minTurnRadius) or nil
    if (type(r) ~= "number" or r <= 0) and AutoDrive ~= nil and AutoDrive.getDriverRadius ~= nil then
        local ok, rr = FarmPilotCall(AutoDrive.getDriverRadius, self.vehicle)
        r = ok and rr or nil
    end
    if type(r) ~= "number" or r <= 0 then
        r = ADWindrowBaleTask.TURN_RADIUS
    end
    return r
end

-- { behind (tracteur -> pick-up, ensemble droit), gx (pick-up sur le côté, axe x de la presse), hand, hitchBack
--   (tracteur -> attelage), tow (attelage -> essieu estimé), rho, front, halfWidth, balerHalfWidth, length, rigid }
function ADWindrowBaleTask:measureGeometry()
    local v, b = self.vehicle, self.baler
    local tnode = v.components[1].node
    local px, py, pz, src = self:pickupPosition()
    local geo = { source = src, rho = self:turnRadius() }
    geo.front = (v.size ~= nil and v.size.length ~= nil and v.size.length / 2 + (v.size.lengthOffset or 0)) or 2.5
    geo.halfWidth = (v.size ~= nil and v.size.width ~= nil and v.size.width / 2) or 1.4
    geo.balerHalfWidth = (b.size ~= nil and b.size.width ~= nil and b.size.width / 2) or 1.5
    geo.pickupWidth = self:pickupWidth()
    if b == v then
        local lx, _, lz = worldToLocal(tnode, px, py, pz)
        geo.rigid = true
        geo.hand = handOf(tnode)
        geo.gx = lx
        geo.behind = -lz
        geo.hitchBack = 0
        geo.tow = 0
        geo.length = 0
        return geo
    end
    local root = rootOf(b)
    geo.hand = handOf(root)
    local bx, _, bz = worldToLocal(root, px, py, pz)
    local hx, hy, hz = self:hitchPosition()
    if hx ~= nil then
        local _, _, tz = worldToLocal(tnode, hx, hy, hz)
        local hbx, _, hbz = worldToLocal(root, hx, hy, hz)
        geo.hitchBack = -tz
        geo.hitchToPickup = math.max(0.3, hbz - bz)
        geo.gx = bx - hbx
    else
        local _, _, tz = worldToLocal(tnode, px, py, pz)
        geo.hitchBack = geo.front
        geo.hitchToPickup = math.max(0.5, -tz - geo.hitchBack)
        geo.gx = bx
    end
    geo.behind = geo.hitchBack + geo.hitchToPickup
    local axleZ = self:axleZ(root)
    if axleZ ~= nil and hx ~= nil then
        local _, _, hbz = worldToLocal(root, hx, hy, hz)
        geo.tow = math.max(geo.hitchToPickup, hbz - axleZ)
        geo.towSource = "roues"
    else
        geo.tow = geo.hitchToPickup + ADWindrowBaleTask.PICKUP_TO_AXLE
        geo.towSource = "estimé"
    end
    geo.length = (b.size ~= nil and b.size.length ~= nil and b.size.length) or (geo.tow + 1.5)
    return geo
end

-- essieu de la presse (z dans son repère) : roues du jeu (spec_wheels), les plus grandes seulement (pas les roues de
-- jauge du pick-up) ; nil si illisible
function ADWindrowBaleTask:axleZ(root)
    local spec = self.baler.spec_wheels
    if spec == nil or type(spec.wheels) ~= "table" then
        return nil
    end
    local list, maxR = {}, 0
    for _, w in ipairs(spec.wheels) do
        local x, y, z = nil, nil, nil
        local node = w.repr or w.driveNode
        if node ~= nil then
            local ok, a, b, c = FarmPilotCall(getWorldTranslation, node)
            if ok then
                x, y, z = a, b, c
            end
        elseif w.node ~= nil and w.physics ~= nil and w.physics.positionZ ~= nil then
            local ok, a, b, c = FarmPilotCall(localToWorld, w.node, w.physics.positionX or 0, w.physics.positionY or 0, w.physics.positionZ)
            if ok then
                x, y, z = a, b, c
            end
        end
        if x ~= nil then
            local _, _, lz = worldToLocal(root, x, y, z)
            local r = w.physics ~= nil and tonumber(w.physics.radius) or (tonumber(w.radius) or 0)
            list[#list + 1] = { z = lz, r = r }
            maxR = math.max(maxR, r)
        end
    end
    local sum, n = 0, 0
    for _, e in ipairs(list) do
        if e.r >= maxR * 0.8 then
            sum, n = sum + e.z, n + 1
        end
    end
    return n > 0 and sum / n or nil
end

-- point d'attelage (ou à défaut, derrière le tracteur) : distance aux bouts des andains
function ADWindrowBaleTask:hitchPoint()
    local hx, _, hz = self:hitchPosition()
    if hx ~= nil then
        return hx, hz
    end
    local tx, _, tz, dx, dz = self:tractorPose()
    local back = self.geo ~= nil and self.geo.hitchBack or 2
    return tx - dx * back, tz - dz * back
end

-- ------------------------------------------------------------------------------------------------------------
-- Champ, culture, balles
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowBaleTask:fieldNumberAt(x, z)
    local f = ADAutonomousManager.fieldAt(x, z)
    local n = f ~= nil and ADAutonomousManager.fieldNumber(f) or nil
    return n, f ~= nil
end

-- (17/11) réglage « champ : strict » d'AutoDrive (comme le chercheur de chemin) : la presse ne quitte jamais le champ
function ADWindrowBaleTask:isStrict()
    if AutoDrive == nil or AutoDrive.getSetting == nil then
        return false
    end
    local ok, v = FarmPilotCall(AutoDrive.getSetting, "restrictToField", self.vehicle)
    return ok and v == "strict"
end

-- (17/11) sol de champ sous ce point (lecture du jeu, AutoDrive.checkIsOnField, celle de la carte du chercheur de
-- chemin) : l'herbe d'une parcelle est rendue comme le champ par le numéro de parcelle, pas par le sol ; illisible = oui
function ADWindrowBaleTask:fieldGround(x, z)
    if AutoDrive == nil or AutoDrive.checkIsOnField == nil then
        return true
    end
    local ok, on = FarmPilotCall(AutoDrive.checkIsOnField, x, 0, z)
    return not ok or on == true
end

-- point permis : sur le champ de la tâche (sans culture debout), ou (marge permise) hors de tout champ à moins de
-- EDGE_MARGIN m du champ ; jamais sur un autre champ. (17/11) Champ strict : pas de marge, et sol de champ seulement
-- (pas l'herbe de la parcelle)
function ADWindrowBaleTask:pointAllowed(x, z, margin)
    if next(self.fieldSet) == nil then
        return true
    end
    if self.strict then
        margin = false
    end
    local n, anyField = self:fieldNumberAt(x, z)
    if n ~= nil and self.fieldSet[tonumber(n) or n] == true then
        if self.strict and not self:fieldGround(x, z) then
            return false
        end
        return not self:hasCrop(x, z)
    end
    if anyField or not margin then
        return false
    end
    if ADBaleLoaderManager ~= nil and ADBaleLoaderManager.edgeOfField ~= nil then
        local ok, edge = FarmPilotCall(ADBaleLoaderManager.edgeOfField, x, z, self.fieldSet, nil)
        return ok and edge == true
    end
    return false
end

-- point hors de tout champ
function ADWindrowBaleTask:offFields(x, z)
    local _, anyField = self:fieldNumberAt(x, z)
    return not anyField
end

-- (18/11) point du bord : 0 sur le sol du champ de la tâche ; sinon distance (m) jusqu'au sol du champ, cherchée vers
-- (inX, inZ) (un point sur le champ : l'andain) tous les EDGE_SEARCH m jusqu'à EDGE_GRASS m (math.huge au-delà) ;
-- nil et la raison sur un autre champ
function ADWindrowBaleTask:edgeOff(x, z, inX, inZ)
    if next(self.fieldSet) == nil then
        return 0
    end
    local n, anyField = self:fieldNumberAt(x, z)
    local mine = n ~= nil and self.fieldSet[tonumber(n) or n] == true
    if mine and self:fieldGround(x, z) then
        return 0
    end
    if not mine and anyField then
        return nil, "un autre champ"
    end
    local len = dist2(x, z, inX, inZ)
    if len < 0.01 then
        return math.huge
    end
    local ux, uz = (inX - x) / len, (inZ - z) / len
    local step = ADWindrowBaleTask.EDGE_SEARCH
    local d = step
    while d <= math.min(len, ADWindrowBaleTask.EDGE_GRASS + step) + 1e-6 do
        local qx, qz = x + ux * d, z + uz * d
        local n2 = self:fieldNumberAt(qx, qz)
        if n2 ~= nil and self.fieldSet[tonumber(n2) or n2] == true and self:fieldGround(qx, qz) then
            return d
        end
        d = d + step
    end
    return math.huge
end

-- (18/11) ensemble en (x, z), sens (hx, hz), demi-largeur w (milieu et deux côtés) : le plus loin hors du sol du champ
-- (m) et ce point ; nil, la raison et le point sur un autre champ
function ADWindrowBaleTask:poseOff(x, z, hx, hz, w, inX, inZ)
    local sx, sz = rightOf(hx, hz)
    local worst, wx, wz = 0, x, z
    for _, k in ipairs({ 0, 1, -1 }) do
        local qx, qz = x + sx * w * k, z + sz * w * k
        local off, why = self:edgeOff(qx, qz, inX, inZ)
        if off == nil then
            return nil, why, qx, qz
        end
        if off > worst then
            worst, wx, wz = off, qx, qz
        end
    end
    return worst, nil, wx, wz
end

-- (18/11) raison si l'ensemble (x, z, sens hx, hz, demi-largeur w) ne va pas sur l'herbe du bord (champ strict) ; nil
-- s'il va. who : « le tracteur », « la presse »
function ADWindrowBaleTask:edgeWhy(who, x, z, hx, hz, w, inX, inZ)
    local off, why, px, pz = self:poseOff(x, z, hx, hz, w, inX, inZ)
    if off == nil then
        return string.format("%s irait sur %s en (%.0f, %.0f)", who, tostring(why), px, pz), px, pz, nil
    end
    if off > ADWindrowBaleTask.EDGE_GRASS then
        return string.format("%s sortirait du champ de plus de %.0f m en (%.0f, %.0f)", who, ADWindrowBaleTask.EDGE_GRASS, px, pz), px, pz, off
    end
    return nil, px, pz, off
end

-- culture debout sous ce point (carte des cultures du chercheur de chemin) ; inconnue = pas de culture
function ADWindrowBaleTask:hasCrop(x, z)
    if PathFinderModule == nil or PathFinderModule.getMapCropAt == nil then
        return false
    end
    local ok, crop = FarmPilotCall(PathFinderModule.getMapCropAt, x, z)
    return ok and type(crop) == "number" and crop ~= 0
end

-- balles posées au champ (relues au plus tous les BALES_EVERY ms)
function ADWindrowBaleTask:bales()
    local now = g_time or 0
    if self.baleList ~= nil and now >= (self.baleTime or 0) and now - self.baleTime < ADWindrowBaleTask.BALES_EVERY then
        return self.baleList
    end
    local list = {}
    if ADBaleLoaderManager ~= nil and ADBaleLoaderManager.fieldBales ~= nil then
        local ok, l = FarmPilotCall(ADBaleLoaderManager.fieldBales, self.fieldSet)
        if ok and type(l) == "table" then
            list = l
        end
    end
    self.baleList, self.baleTime = list, now
    return list
end

-- une balle dans le couloir (largeur halfWidth + rayon de balle) de a à b ; renvoie la balle et son abscisse
function ADWindrowBaleTask:baleInCorridor(ax, az, bx, bz, halfWidth)
    local ux, uz = normalize(bx - ax, bz - az)
    local len = dist2(ax, az, bx, bz)
    local best, bestAlong = nil, math.huge
    for _, c in ipairs(self:bales()) do
        local rx, rz = c.x - ax, c.z - az
        local along = rx * ux + rz * uz
        if along >= -ADWindrowBaleTask.BALE_RADIUS and along <= len + ADWindrowBaleTask.BALE_RADIUS
            and math.abs(rx * uz - rz * ux) < halfWidth + ADWindrowBaleTask.BALE_RADIUS and along < bestAlong then
            best, bestAlong = c, along
        end
    end
    return best, bestAlong
end

-- (17/11) objet fixe (arbre, souche, poteau, bâtiment) dans la boîte de a à b, demi-largeur halfWidth, de
-- OBSTACLE_GROUND à OBSTACLE_HEIGHT m au-dessus du sol (overlapBox, comme le chercheur de chemin) ; les véhicules (le
-- nôtre compris) et les balles (contrôlées à part) ne comptent pas. Renvoie le nom du premier objet, nil si rien
function ADWindrowBaleTask:obstacleOn(ax, az, bx, bz, halfWidth)
    if overlapBox == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return nil
    end
    local dx, dz = bx - ax, bz - az
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.1 then
        return nil
    end
    local terrain = g_currentMission.terrainRootNode
    local mx, mz = (ax + bx) / 2, (az + bz) / 2
    local okY, y = FarmPilotCall(getTerrainHeightAtWorldPos, terrain, mx, 1, mz)
    y = (okY and tonumber(y)) or 0
    local probe = { hits = 0 }
    probe.callback = function(pr, id)
        if id ~= 0 and id ~= terrain then
            local object = nil
            if g_currentMission.getNodeObject ~= nil then
                local okO, o = FarmPilotCall(g_currentMission.getNodeObject, g_currentMission, id)
                object = okO and o or nil
            end
            local isBale = object ~= nil and Bale ~= nil and object.isa ~= nil and object:isa(Bale)
            if not isBale and (object == nil or object.rootVehicle == nil) then
                pr.hits = pr.hits + 1
                if pr.name == nil then
                    local okN, n = FarmPilotCall(function()
                        if object ~= nil and object.getName ~= nil then
                            return object:getName()
                        end
                        return getName ~= nil and getName(id) or nil
                    end)
                    pr.name = (okN and n ~= nil) and tostring(n) or tostring(id)
                end
            end
        end
        return true
    end
    local h = ADWindrowBaleTask.OBSTACLE_HEIGHT
    local mask = AutoDrive ~= nil and AutoDrive.collisionMaskTerrain or nil
    FarmPilotCall(overlapBox, mx, y + ADWindrowBaleTask.OBSTACLE_GROUND + h / 2, mz, 0, math.atan2(-dz / len, dx / len), 0, len / 2, h / 2, halfWidth,
        "callback", probe, mask, true, true, true, true)
    if probe.hits > 0 then
        return probe.name or "objet"
    end
    return nil
end

-- le chemin (points {x, z}) fait par l'ensemble : tracteur sur le chemin, presse traînée simulée derrière (timon
-- estimé) ; nil si rien ne touche, sinon la raison. withField : chaque point (et les côtés) sur le champ, sans culture
-- (17/11) withField : tracteur et presse avec leurs demi-largeurs ; « parti d'en dehors » seulement si l'ensemble
-- démarre vraiment hors du champ (une fois entré, il n'en ressort plus) ; objets fixes tous les OBSTACLE_STEP m
-- (18/11 : avec ou sans withField)
function ADWindrowBaleTask:sweepProblem(path, withField)
    local geo = self.geo
    if path == nil or #path < 2 then
        return "chemin vide"
    end
    local bales = self:bales()
    local tx, _, tz, hx, hz = self:tractorPose()
    local hitchX, hitchZ = tx - hx * geo.hitchBack, tz - hz * geo.hitchBack
    local ax, az = hitchX, hitchZ
    local tow = geo.tow * ADWindrowBaleTask.SWEEP_TOW_MARGIN
    if not geo.rigid then
        local ux, uz = self:balerDir()
        ax, az = hitchX - ux * tow, hitchZ - uz * tow
    end
    -- balles déjà au contact de l'ensemble au départ (balle qu'il vient de poser derrière) : pas comptées
    local tHalf = geo.halfWidth + ADWindrowBaleTask.BALE_RADIUS + ADWindrowBaleTask.SWEEP_MARGIN
    local bHalf = geo.balerHalfWidth + ADWindrowBaleTask.BALE_RADIUS + ADWindrowBaleTask.SWEEP_MARGIN
    local ignore = {}
    for i, c in ipairs(bales) do
        if segDist(c.x, c.z, tx + hx * geo.front, tz + hz * geo.front, hitchX, hitchZ) < tHalf
            or (not geo.rigid and segDist(c.x, c.z, hitchX, hitchZ, hitchX + (ax - hitchX) * geo.length / math.max(tow, 0.1), hitchZ + (az - hitchZ) * geo.length / math.max(tow, 0.1)) < bHalf) then
            ignore[i] = true
        end
    end
    -- points tous les mètres
    local pts = {}
    for i = 1, #path do
        local p = path[i]
        if i > 1 then
            local q = path[i - 1]
            local len = dist2(p.x, p.z, q.x, q.z)
            local steps = math.floor(len)
            for k = 1, steps - 1 do
                pts[#pts + 1] = { x = q.x + (p.x - q.x) * k / len, z = q.z + (p.z - q.z) * k / len }
            end
        end
        pts[#pts + 1] = { x = p.x, z = p.z }
    end
    local lastX, lastZ = tx, tz
    local tIn, bIn = false, false
    local tSideOut, bSideOut = false, false
    if withField then
        -- (17/11) ensemble déjà sur le champ au départ : l'exception « parti d'en dehors » ne joue pas (une courbe qui
        -- part du bord du champ vers l'herbe était acceptée : champ 52, coincé dans les arbres)
        tIn = self:pointAllowed(tx, tz, false)
        bIn = geo.rigid or self:pointAllowed(ax, az, false)
        -- milieu sur le champ mais un côté déjà dehors (arrêté au bord) : ce côté toléré au début, tant qu'il n'est pas
        -- rentré (EDGE_START m au plus), le milieu jamais dehors
        local sx, sz = rightOf(hx, hz)
        local w = geo.halfWidth
        tSideOut = tIn and not (self:pointAllowed(tx + sx * w, tz + sz * w, false) and self:pointAllowed(tx - sx * w, tz - sz * w, false))
        if not geo.rigid and bIn then
            local bux, buz = normalize(hitchX - ax, hitchZ - az)
            local bsx, bsz = rightOf(bux, buz)
            local bw = geo.balerHalfWidth
            bSideOut = not (self:pointAllowed(ax + bsx * bw, az + bsz * bw, false) and self:pointAllowed(ax - bsx * bw, az - bsz * bw, false))
        end
    end
    local travelled = 0
    local obstX, obstZ, obstAcc = tx, tz, 0
    for i, p in ipairs(pts) do
        local d = dist2(p.x, p.z, lastX, lastZ)
        if d >= 0.3 then
            travelled = travelled + d
            local dx, dz = normalize(p.x - lastX, p.z - lastZ)
            local fx, fz = p.x + dx * geo.front, p.z + dz * geo.front
            local hX, hZ = p.x - dx * geo.hitchBack, p.z - dz * geo.hitchBack
            local rearX, rearZ = hX, hZ
            if not geo.rigid then
                local ux, uz = normalize(hX - ax, hZ - az)
                ax, az = hX - ux * tow, hZ - uz * tow
                rearX, rearZ = hX - ux * geo.length, hZ - uz * geo.length
            end
            for k, c in ipairs(bales) do
                if not ignore[k] then
                    if segDist(c.x, c.z, fx, fz, hX, hZ) < tHalf then
                        return string.format("le tracteur passerait sur une balle (%.0f, %.0f)", c.x, c.z)
                    end
                    if not geo.rigid and segDist(c.x, c.z, hX, hZ, rearX, rearZ) < bHalf then
                        return string.format("la presse passerait sur une balle (%.0f, %.0f)", c.x, c.z)
                    end
                end
            end
            if withField then
                local sx, sz = rightOf(dx, dz)
                local w = geo.halfWidth
                local okT, whereX, whereZ, sideOnlyT = true, p.x, p.z, false
                for _, k in ipairs({ 0, 1, -1 }) do
                    if okT and not self:pointAllowed(p.x + sx * w * k, p.z + sz * w * k, false) then
                        okT, whereX, whereZ, sideOnlyT = false, p.x + sx * w * k, p.z + sz * w * k, k ~= 0
                    end
                end
                local okB, bWhereX, bWhereZ, sideOnlyB = true, ax, az, false
                if not geo.rigid then
                    -- presse : essieu et ses deux côtés (demi-largeur de la presse)
                    local bux, buz = normalize(hX - ax, hZ - az)
                    local bsx, bsz = rightOf(bux, buz)
                    local bw = geo.balerHalfWidth
                    for _, k in ipairs({ 0, 1, -1 }) do
                        if okB and not self:pointAllowed(ax + bsx * bw * k, az + bsz * bw * k, false) then
                            okB, bWhereX, bWhereZ, sideOnlyB = false, ax + bsx * bw * k, az + bsz * bw * k, k ~= 0
                        end
                    end
                end
                -- côté dehors depuis le départ : toléré tant qu'il n'est pas rentré, au plus EDGE_START m
                tSideOut = tSideOut and not okT and sideOnlyT and travelled <= ADWindrowBaleTask.EDGE_START
                bSideOut = bSideOut and not okB and sideOnlyB and travelled <= ADWindrowBaleTask.EDGE_START
                if tSideOut then
                    okT = true
                end
                if bSideOut then
                    okB = true
                end
                -- ensemble parti d'en dehors de tout champ (cour, chemin, presse encore sur le bord) : permis tant
                -- qu'il n'est pas entré sur le champ (15/11) ; (17/11) seulement s'il est parti d'en dehors
                tIn = tIn or okT
                bIn = bIn or okB
                if not okT and (tIn or not self:offFields(whereX, whereZ)) then
                    return string.format("le tracteur sortirait du champ ou irait dans la culture en (%.0f, %.0f)", whereX, whereZ)
                end
                if not okB and (bIn or not self:offFields(bWhereX, bWhereZ)) then
                    return string.format("la presse sortirait du champ ou irait dans la culture en (%.0f, %.0f)", bWhereX, bWhereZ)
                end
            end
            -- (17/11) objets fixes : tracteur (de son avant au dernier contrôle) et presse, tous les OBSTACLE_STEP m ;
            -- (18/11) aussi sur le chemin du chercheur de chemin (presse traînée comprise) : les arbres jamais
            obstAcc = obstAcc + d
            if obstAcc >= ADWindrowBaleTask.OBSTACLE_STEP or i == #pts then
                obstAcc = 0
                local name = self:obstacleOn(obstX, obstZ, fx, fz, geo.halfWidth + ADWindrowBaleTask.OBSTACLE_MARGIN)
                if name ~= nil then
                    return string.format("le tracteur toucherait un objet fixe « %s » en (%.0f, %.0f)", name, p.x, p.z)
                end
                obstX, obstZ = p.x, p.z
                if not geo.rigid then
                    local bname = self:obstacleOn(hX, hZ, rearX, rearZ, geo.balerHalfWidth + ADWindrowBaleTask.OBSTACLE_MARGIN)
                    if bname ~= nil then
                        return string.format("la presse toucherait un objet fixe « %s » en (%.0f, %.0f)", bname, (hX + rearX) / 2, (hZ + rearZ) / 2)
                    end
                end
            end
            lastX, lastZ = p.x, p.z
        end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Choix de l'andain et de la ligne d'approche
-- ------------------------------------------------------------------------------------------------------------
-- points d'un andain pris depuis le bout e (1 : premier point, 2 : dernier)
local function oriented(row, e)
    if e == 1 then
        return row.points
    end
    local out = {}
    for i = #row.points, 1, -1 do
        out[#out + 1] = row.points[i]
    end
    return out
end

-- sens de l'andain à son bout d'entrée : du bout vers le point à ENTRY_DIR_LENGTH m
local function entryDir(pts)
    local e = pts[1]
    local acc = 0
    local target = pts[#pts]
    for i = 2, #pts do
        acc = acc + dist2(pts[i].x, pts[i].z, pts[i - 1].x, pts[i - 1].z)
        if acc >= ADWindrowBaleTask.ENTRY_DIR_LENGTH then
            target = pts[i]
            break
        end
    end
    return normalize(target.x - e.x, target.z - e.z)
end

-- longueur droite voulue avant que le pick-up arrive au bout : presse en biais de asin(timon / rayon) au sortir du
-- virage, écart résorbé sur la longueur du timon
function ADWindrowBaleTask:straightNeed()
    local geo = self.geo
    if geo.rigid or geo.tow <= 0 then
        return ADWindrowBaleTask.APPROACH_MIN
    end
    local a0 = math.deg(math.asin(clamp(geo.tow / math.max(geo.rho, 0.1), 0, 1)))
    local need = geo.tow * math.log(math.max(1, a0 / ADWindrowBaleTask.STRAIGHT_ANGLE))
    return clamp(need, ADWindrowBaleTask.APPROACH_MIN, ADWindrowBaleTask.APPROACH_MAX)
end

-- premiers mètres de l'andain relus (ADWindrowScan.centerOffset) : bout et sens d'entrée pris sur le vrai milieu de
-- l'andain, pas seulement sur le balayage ; renvoie les points (1 par mètre) corrigés
function ADWindrowBaleTask:correctedEntry(pts)
    local ref = Ref.new()
    Ref.addResampled(ref, pts, 1)
    if ref.n < 2 then
        return pts, 0
    end
    local fixed = 0
    local s = 0
    while s <= math.min(ADWindrowBaleTask.ENTRY_PROBE_LENGTH, ref.s[ref.n]) do
        local ox, oz = Ref.point(ref, s)
        local ux, uz = Ref.tangent(ref, s)
        local ok, off = callOf("ADWindrowScan", "centerOffset", ox, oz, ux, uz, self.fillTypes, ADWindrowBaleTask.PROBE_HALF_SPAN)
        if ok and type(off) == "number" then
            Ref.shift(ref, s, clamp(off, -ADWindrowBaleTask.PROBE_MAX_SHIFT, ADWindrowBaleTask.PROBE_MAX_SHIFT))
            fixed = math.max(fixed, math.abs(off))
        end
        s = s + 1
    end
    local out = {}
    for i = 1, ref.n do
        out[i] = { x = ref.x[i], z = ref.z[i] }
    end
    return out, fixed
end

-- ligne d'approche du bout e de l'andain : { row, e, pts, ex, ez (bout), dx, dz, p0x, p0z (tracteur au droit du
-- bout), back, ax, az (début), dist } ; nil et la raison si ce bout ne va pas
function ADWindrowBaleTask:makeLine(row, e)
    local geo = self.geo
    local pts, fixed = self:correctedEntry(oriented(row, e))
    local ex, ez = pts[1].x, pts[1].z
    local dx, dz = entryDir(pts)
    local sx, sz = sideOf(geo.hand, dx, dz)
    local line = { row = row, e = e, pts = pts, ex = ex, ez = ez, dx = dx, dz = dz, fixed = fixed }
    line.p0x, line.p0z = ex - sx * geo.gx, ez - sz * geo.gx
    local want = math.max(ADWindrowBaleTask.BACK_MIN, self:straightNeed() - geo.behind + ADWindrowBaleTask.SETTLE)
    if row.backCap ~= nil and row.backCap[e] ~= nil then
        want = math.min(want, row.backCap[e])
    end
    local why = nil
    -- (18/11) champ strict : une passe (herbe du bord jusqu'à EDGE_GRASS m, tracteur et presse avec leurs demi-largeurs)
    for pass = 1, self.strict and 1 or 2 do
        local margin = pass == 2
        local back = want
        while back >= ADWindrowBaleTask.BACK_MIN - 0.01 do
            local ax, az = line.p0x - dx * back, line.p0z - dz * back
            local ok = true
            local edgeWhy = nil
            if self.strict then
                edgeWhy = self:approachProblem(line, back)
                ok = edgeWhy == nil
            else
                -- début de ligne et ligne (tous les 2 m) sur le champ, pick-up compris
                local k = 0
                while k <= back do
                    if not self:pointAllowed(line.p0x - dx * (back - k), line.p0z - dz * (back - k), margin) then
                        ok = false
                        break
                    end
                    k = k + 2
                end
            end
            -- (18/11) objet fixe sur la ligne droite (presse comprise, jusqu'au tracteur entré dans l'andain) : jamais
            local obstacle = nil
            if ok then
                local hw = math.max(geo.halfWidth, geo.balerHalfWidth) + ADWindrowBaleTask.OBSTACLE_MARGIN
                obstacle = self:obstacleOn(ax - dx * (geo.behind + geo.length), az - dz * (geo.behind + geo.length),
                    ex + dx * (geo.behind + geo.front), ez + dz * (geo.behind + geo.front), hw)
                ok = obstacle == nil
            end
            if obstacle ~= nil then
                why = string.format("objet fixe « %s » sur la ligne d'approche", obstacle)
                back = back - ADWindrowBaleTask.BACK_STEP
            elseif ok then
                -- pas de balle sur la ligne, du début (presse comprise) jusqu'à 3 m dans l'andain
                local bx0, bz0 = ax - dx * (geo.behind + geo.length), az - dz * (geo.behind + geo.length)
                local bale = self:baleInCorridor(bx0, bz0, ex + dx * 3, ez + dz * 3, math.max(geo.halfWidth, geo.balerHalfWidth))
                if bale ~= nil then
                    why = string.format("balle posée sur la ligne d'approche (%.0f, %.0f)", bale.x, bale.z)
                    -- balle derrière le début : ligne plus courte, peut-être
                    back = back - ADWindrowBaleTask.BACK_STEP
                else
                    line.back = back
                    line.ax, line.az = ax, az
                    line.margin = margin
                    line.short = back < want - 0.01
                    return line
                end
            else
                if edgeWhy ~= nil then
                    why = "ligne d'approche : " .. edgeWhy
                else
                    why = margin and "début de la ligne d'approche hors du champ (même au bord)" or "début de la ligne d'approche hors du champ"
                end
                back = back - ADWindrowBaleTask.BACK_STEP
            end
        end
    end
    return nil, why
end

-- (18/11) champ strict, ligne droite d'approche de longueur back : de l'essieu de la presse au début jusqu'au tracteur
-- quand le pick-up arrive au bout, tous les 2 m, avec la plus grande demi-largeur ; raison si un point sort de plus de
-- EDGE_GRASS m du sol du champ ou va sur un autre champ, nil sinon
function ADWindrowBaleTask:approachProblem(line, back)
    local geo = self.geo
    local dx, dz = line.dx, line.dz
    local w = math.max(geo.halfWidth, geo.balerHalfWidth)
    local rearBack = geo.rigid and 0 or math.max(0, geo.hitchBack + geo.tow - geo.behind)
    local from = -(back + rearBack)
    local to = geo.behind
    local k = from
    while k <= to + 1e-6 do
        local qx, qz = line.p0x + dx * k, line.p0z + dz * k
        local why = self:edgeWhy("l'ensemble", qx, qz, dx, dz, w, line.ex, line.ez)
        if why ~= nil then
            return why
        end
        k = k + 2
    end
    return nil
end

-- andains à faire : (17/11) d'abord celui qui continue tout droit devant (bout à moins de AHEAD_DIST m de
-- l'attelage, devant le pick-up, à moins de AHEAD_LATERAL m de l'axe du tracteur, andain qui part dans le même sens à
-- AHEAD_ANGLE° près), puis les autres du plus proche de l'attelage au plus loin, un demi-tour (UTURN_ANGLE) compté
-- UTURN_COST m de plus. Deuxième valeur : le bout le plus proche (journal)
function ADWindrowBaleTask:candidates()
    local hx, hz = self:hitchPoint()
    local tx, _, tz, dx, dz = self:tractorPose()
    local px, _, pz = self:pickupPosition()
    local sx, sz = rightOf(dx, dz)
    local list = {}
    local nearest = nil
    for _, row in ipairs(self.rows) do
        if row.state == "todo" and row.closed and row.tries[1] == 0 and row.tries[2] == 0 and row.why[1] == nil and row.why[2] == nil then
            self:cutLoop(row, hx, hz)
        end
        if row.state == "todo" then
            for e = 1, 2 do
                if row.tries[e] < ADWindrowBaleTask.MAX_END_TRIES and row.why[e] == nil then
                    local p = e == 1 and row.points[1] or row.points[#row.points]
                    local c = { row = row, e = e, dist = dist2(p.x, p.z, hx, hz) }
                    local ux, uz = entryDir(oriented(row, e))
                    c.turn = signedAngle(dx, dz, ux, uz)
                    c.uTurn = math.abs(c.turn) >= ADWindrowBaleTask.UTURN_ANGLE
                    c.along = (p.x - px) * dx + (p.z - pz) * dz
                    c.lateral = math.abs((p.x - tx) * sx + (p.z - tz) * sz)
                    c.ahead = c.dist <= ADWindrowBaleTask.AHEAD_DIST and c.along >= ADWindrowBaleTask.AHEAD_MIN
                        and c.lateral <= ADWindrowBaleTask.AHEAD_LATERAL and math.abs(c.turn) <= ADWindrowBaleTask.AHEAD_ANGLE
                    c.cost = c.dist + ((c.uTurn and not c.ahead) and ADWindrowBaleTask.UTURN_COST or 0)
                    list[#list + 1] = c
                    if nearest == nil or c.dist < nearest.dist - 0.01 then
                        nearest = c
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.ahead ~= b.ahead then
            return a.ahead
        end
        if math.abs(a.cost - b.cost) > 0.01 then
            return a.cost < b.cost
        end
        if math.abs(a.dist - b.dist) > 0.01 then
            return a.dist < b.dist
        end
        return a.row.index < b.row.index
    end)
    return list, nearest
end

-- (17/11) pourquoi ce bout (journal)
local function choiceWhy(c, nearest)
    local why
    if c.ahead then
        why = string.format("suite tout droit devant (bout à %.0f m devant le pick-up, %.1f m de l'axe du tracteur, sens %+.0f°)", c.along, c.lateral, c.turn or 0)
    elseif c.uTurn then
        why = string.format("le plus proche, demi-tour compté %.0f m de plus (%.0f m)", ADWindrowBaleTask.UTURN_COST, c.cost)
    else
        why = "le plus proche"
    end
    if nearest ~= nil and nearest ~= c then
        why = why .. string.format(" ; préféré à l'andain %s, bout %s à %.0f m%s", tostring(nearest.row.id), nearest.e == 1 and "début" or "fin", nearest.dist,
            nearest.uTurn and string.format(" mais demi-tour (%+.0f°)", nearest.turn or 0) or "")
    end
    return why
end

local function endName(e)
    return e == 1 and "début" or "fin"
end

-- un bout ne va pas : raison gardée ; les deux bouts : andain laissé
function ADWindrowBaleTask:dropEnd(row, e, why)
    row.why[e] = why
    log("%s : andain %s, bout %s laissé : %s", self:name(), tostring(row.id), endName(e), tostring(why))
    local other = 3 - e
    if row.why[other] ~= nil or row.tries[other] >= ADWindrowBaleTask.MAX_END_TRIES then
        row.state = "left"
        log("%s : andain %s (%.0f m) laissé : aucun bout faisable (%s / %s)", self:name(), tostring(row.id), row.length,
            tostring(row.why[1] or "essais épuisés"), tostring(row.why[2] or "essais épuisés"))
    end
end

-- un essai de plus sur ce bout (chemin introuvable, bloqué) ; au bout de MAX_END_TRIES : bout laissé
function ADWindrowBaleTask:failEnd(row, e, why)
    row.tries[e] = row.tries[e] + 1
    if row.tries[e] >= ADWindrowBaleTask.MAX_END_TRIES then
        self:dropEnd(row, e, why)
    else
        log("%s : andain %s, bout %s : %s, nouvel essai", self:name(), tostring(row.id), endName(e), tostring(why))
    end
end

function ADWindrowBaleTask:counts()
    local total, done, pending = 0, 0, 0
    for _, row in ipairs(self.rows) do
        total = total + 1
        if row.state == "done" then
            done = done + 1
        elseif row.state == "todo" then
            pending = pending + 1
        end
    end
    return total, done, pending
end

-- andain suivant : le bout le plus proche qui a une ligne d'approche
function ADWindrowBaleTask:updateChoose(dt)
    self:holdVehicle(dt)
    if self.geo == nil then
        local okG, geo = FarmPilotCall(self.measureGeometry, self)
        self.geo = okG and geo or nil
        if self.geo == nil then
            log("%s : géométrie de la presse illisible : arrêt", self:name())
            self:finish("blocked")
            return
        end
    end
    self.geo.rho = self:turnRadius()
    self.strict = self:isStrict()
    local list, nearest = self:candidates()
    for _, c in ipairs(list) do
        local line, why = self:makeLine(c.row, c.e)
        if line == nil then
            self:dropEnd(c.row, c.e, why)
        else
            line.ahead = c.ahead
            line.why = choiceWhy(c, nearest)
            self:startLine(line, c.dist)
            return
        end
    end
    -- aucun bout retenu : ce qui reste à faire est laissé
    for _, row in ipairs(self.rows) do
        if row.state == "todo" then
            row.state = "left"
        end
    end
    local total, done = self:counts()
    local left = total - done
    if left == 0 and self:wantRescan() then
        return
    end
    if left > 0 then
        local names = {}
        for _, row in ipairs(self.rows) do
            if row.state == "left" then
                names[#names + 1] = string.format("%s (%s / %s)", tostring(row.id), tostring(row.why[1] or "essais épuisés"), tostring(row.why[2] or "essais épuisés"))
            end
        end
        -- rien pressé par cette tâche : bloqué ; sinon le champ est fini autant qu'il peut l'être (reste au journal)
        if self.doneCount == 0 then
            log("%s : plus rien de faisable, %d andain(s) laissé(s) : %s ; bloqué", self:name(), left, table.concat(names, " ; "))
            self:finish("blocked")
        else
            log("%s : plus rien de faisable, %d andain(s) laissé(s) : %s ; %d fait(s), fin du champ", self:name(), left, table.concat(names, " ; "), self.doneCount)
            self:finish("done")
        end
        return
    end
    self:finish("done")
end

-- liste finie : nouveau balayage s'il reste de l'andain au champ (au plus RESCAN_MAX fois, et seulement si quelque
-- chose a été pressé depuis le dernier) ; true = balayage lancé
function ADWindrowBaleTask:wantRescan()
    if ADWindrowScan == nil or ADWindrowScan.anyLeft == nil or ADWindrowScan.newScan == nil then
        return false
    end
    if self.rescans >= ADWindrowBaleTask.RESCAN_MAX or self.pressedSinceScan == 0 then
        return false
    end
    local ok, any = callOf("ADWindrowScan", "anyLeft", self.ctx.fieldNums, self.fillTypes)
    if not ok or any ~= true then
        return false
    end
    -- (15/11) mêmes options que la recherche du mode (le scan ne les garde pas)
    local opts = nil
    if ADWindrowMode ~= nil and ADWindrowMode.scanOpts ~= nil then
        local okO, o = FarmPilotCall(ADWindrowMode.scanOpts)
        opts = okO and o or nil
    end
    local okS, scan = callOf("ADWindrowScan", "newScan", self.ctx.fieldNums, self.fillTypes, opts)
    if not okS or scan == nil then
        log("%s : nouveau balayage impossible (%s)", self:name(), tostring(scan))
        return false
    end
    self.rescans = self.rescans + 1
    self.pressedSinceScan = 0
    self.scan = scan
    log("%s : liste finie mais il reste de l'andain au champ : nouveau balayage (%d)", self:name(), self.rescans)
    self:setState("rescan")
    return true
end

-- lectures du sol par image pour un nouveau balayage : comme la recherche du mode (15/11)
function ADWindrowBaleTask.rescanBudget()
    local b = ADWindrowMode ~= nil and tonumber(ADWindrowMode.SCAN_BUDGET) or nil
    if b ~= nil and b > 0 then
        return b
    end
    return ADWindrowBaleTask.RESCAN_BUDGET
end

function ADWindrowBaleTask:updateRescan(dt)
    self:holdVehicle(dt)
    local ok, done = FarmPilotCall(self.scan.update, self.scan, ADWindrowBaleTask.rescanBudget())
    if not ok then
        log("%s : nouveau balayage en erreur (%s)", self:name(), tostring(done))
        self.scan = nil
        self:setState("choose")
        return
    end
    if done ~= true then
        return
    end
    -- les andains faits ou laissés restent dans la liste (compte du bandeau) ; ceux du nouveau balayage s'ajoutent
    local before = #self.rows
    self:setRows(self.scan.windrows or {})
    log("%s : nouveau balayage fini : %d andain(s) de plus", self:name(), #self.rows - before)
    self.scan = nil
    self:setState("choose")
end

-- ------------------------------------------------------------------------------------------------------------
-- Ligne choisie : tout droit (déjà dans l'axe), chemin, ou approche directe
-- ------------------------------------------------------------------------------------------------------------
-- ensemble déjà dans l'axe : tracteur et presse dans le sens de la ligne, pick-up avant le bout et à peu près sur l'axe
function ADWindrowBaleTask:isOnLine(line, minAlong)
    local _, _, _, hx, hz = self:tractorPose()
    if angleBetween(hx, hz, line.dx, line.dz) > ADWindrowBaleTask.ON_LINE_ANGLE then
        return false
    end
    if not self.geo.rigid then
        local bx, bz = self:balerDir()
        if angleBetween(bx, bz, line.dx, line.dz) > ADWindrowBaleTask.ON_LINE_ANGLE then
            return false
        end
    end
    local px, _, pz = self:pickupPosition()
    local rx, rz = px - line.ex, pz - line.ez
    local along = rx * line.dx + rz * line.dz
    local sx, sz = rightOf(line.dx, line.dz)
    local lateral = math.abs(rx * sx + rz * sz)
    return along <= -(minAlong or ADWindrowBaleTask.ON_LINE_MIN) and lateral <= ADWindrowBaleTask.ON_LINE_DISTANCE + ADWindrowBaleTask.ON_LINE_SLOPE * -along
end

-- tout droit du tracteur au bout : pas de balle, sur le champ ; (17/11) côtés du tracteur sur le champ aussi, pas
-- d'objet fixe
function ADWindrowBaleTask:straightClear(line)
    local tx, _, tz = self:tractorPose()
    local bale = self:baleInCorridor(tx, tz, line.ex + line.dx * 3, line.ez + line.dz * 3, math.max(self.geo.halfWidth, self.geo.balerHalfWidth))
    if bale ~= nil then
        return false, string.format("balle posée devant (%.0f, %.0f)", bale.x, bale.z)
    end
    local len = dist2(tx, tz, line.ex, line.ez)
    local ux, uz = normalize(line.ex - tx, line.ez - tz)
    local sx, sz = rightOf(ux, uz)
    local w = self.geo.halfWidth
    local k = 0
    while k <= len do
        local qx, qz = tx + (line.ex - tx) * k / math.max(len, 0.1), tz + (line.ez - tz) * k / math.max(len, 0.1)
        if self.strict then
            -- (18/11) champ strict : herbe du bord jusqu'à EDGE_GRASS m (ligne droite d'approche)
            local why = self:edgeWhy("le tracteur", qx, qz, ux, uz, w, line.ex, line.ez)
            if why ~= nil then
                return false, why
            end
        else
            for _, side in ipairs({ 0, 1, -1 }) do
                local px, pz = qx + sx * w * side, qz + sz * w * side
                if not self:pointAllowed(px, pz, line.margin) then
                    return false, string.format("hors du champ ou dans la culture en (%.0f, %.0f)", px, pz)
                end
            end
        end
        k = k + 2
    end
    local name = self:obstacleOn(tx, tz, line.ex, line.ez, w + ADWindrowBaleTask.OBSTACLE_MARGIN)
    if name ~= nil then
        return false, string.format("objet fixe « %s » sur la ligne droite", name)
    end
    return true
end

function ADWindrowBaleTask:startLine(line, dist)
    local row = line.row
    self.line = line
    self.current = row
    self.path = nil
    local _, _, _, hx, hz = self:tractorPose()
    local turn = signedAngle(hx, hz, line.dx, line.dz)
    local total, done = self:counts()
    log("%s : andain %s choisi (%.0f m, bout %s à %.0f m de l'attelage, sens %+.0f°%s), %d/%d fait(s)", self:name(), tostring(row.id), row.length,
        endName(line.e), dist or 0, turn, line.short and string.format(", ligne d'approche raccourcie à %.0f m", line.back) or "", done + self.doneBefore, total + self.doneBefore)
    if line.why ~= nil then
        log("%s : andain %s : %s", self:name(), tostring(row.id), line.why)
    end
    -- (17/11) suite tout droit devant : déjà dans l'axe même tout près du bout (presse droite), sinon approche directe
    if self:isOnLine(line, line.ahead and ADWindrowBaleTask.AHEAD_MIN or nil) then
        local ok, why = self:straightClear(line)
        if ok then
            log("%s : déjà dans l'axe de l'andain %s : tout droit", self:name(), tostring(row.id))
            self:startFollow(line, "dans l'axe")
            return
        end
        log("%s : dans l'axe de l'andain %s mais %s : chemin", self:name(), tostring(row.id), tostring(why))
    elseif line.ahead and self:canGoDirect(line) then
        log("%s : andain %s tout droit devant : approche directe", self:name(), tostring(row.id))
        self:startFollow(line, "approche directe")
        return
    end
    self.uTurn = math.abs(turn) >= ADWindrowBaleTask.UTURN_ANGLE
    self:startPlanning()
end

-- chercheur de chemin vers le début de la ligne d'approche, balles posées en zones interdites
function ADWindrowBaleTask:startPlanning()
    local line = self.line
    local pf = self.vehicle.ad.pathFinderModule
    local _, ty = self:tractorPose()
    pf:reset()
    local zones = {}
    for _, c in ipairs(self:bales()) do
        zones[#zones + 1] = { x = c.x, z = c.z, radius = ADWindrowBaleTask.BALE_ZONE }
    end
    pf.blockedZones = zones
    self.zonesSet = true
    pf:startPathPlanningTo({ x = line.ax, y = ty, z = line.az }, { x = line.dx, z = line.dz })
    self:setState("planning")
end

function ADWindrowBaleTask:clearZones()
    if self.zonesSet then
        local pf = self.vehicle.ad.pathFinderModule
        if pf ~= nil then
            pf.blockedZones = nil
        end
        self.zonesSet = false
    end
end

function ADWindrowBaleTask:updatePlanning(dt)
    local pf = self.vehicle.ad.pathFinderModule
    if not pf:hasFinished() then
        pf:update(dt)
        self:holdVehicle(dt)
        return
    end
    self:holdVehicle(dt)
    self:clearZones()
    local line = self.line
    local path = pf:getPath()
    local problem = nil
    if path == nil or #path < 2 then
        problem = "pas de chemin du chercheur"
    else
        problem = self:sweepProblem(path, false)
    end
    if problem == nil then
        self:startDrive(path, "chercheur de chemin")
        return
    end
    -- courbe de Dubins au rayon de l'ensemble, vérifiée (champ, culture, balles)
    local dub, why = self:dubinsPath(line)
    if dub ~= nil then
        log("%s : %s : courbe de Dubins à la place (%s)", self:name(), problem, why)
        self:startDrive(dub, "courbe de Dubins")
        return
    end
    -- approche directe : andain devant, assez de place
    if self:canGoDirect(line) then
        log("%s : %s, pas de courbe (%s) : approche directe de l'andain %s", self:name(), problem, tostring(why), tostring(line.row.id))
        self:startFollow(line, "approche directe")
        return
    end
    -- ligne d'approche plus courte d'abord (moins de place prise au bout de l'andain), puis un essai de moins
    if line.back > ADWindrowBaleTask.BACK_MIN + 0.01 then
        line.row.backCap = line.row.backCap or {}
        line.row.backCap[line.e] = math.max(ADWindrowBaleTask.BACK_MIN, line.back - ADWindrowBaleTask.BACK_CUT)
        log("%s : andain %s, bout %s : %s ; courbe : %s : ligne d'approche raccourcie à %.0f m", self:name(), tostring(line.row.id), endName(line.e),
            problem, tostring(why), line.row.backCap[line.e])
    else
        self:failEnd(line.row, line.e, string.format("%s ; courbe : %s", problem, tostring(why)))
    end
    self:setState("choose")
end

-- courbe la plus courte (6 formes de Dubins) du tracteur au début de la ligne, sur le champ, hors culture, loin des
-- balles ; nil et la raison sinon
function ADWindrowBaleTask:dubinsPath(line)
    if ADDubins == nil or ADDubins.dubins_path == nil then
        return nil, "pas de module Dubins"
    end
    local tx, _, tz, hx, hz = self:tractorPose()
    local rho = self.geo.rho
    local q0 = { tx, -tz, math.atan2(-hz, hx) }
    local q1 = { line.ax, -line.az, math.atan2(-line.dz, line.dx) }
    local found = {}
    for word = 1, 6 do
        local d = ADDubins:new()
        d.outPath = {}
        local path = { qi = {}, param = {} }
        local ok, res = FarmPilotCall(d.dubins_path, d, path, q0, q1, rho, word)
        if ok and res == ADDubins.EDUBOK and path.param[3] ~= nil then
            found[#found + 1] = { d = d, path = path, len = (path.param[1] + path.param[2] + path.param[3]) * rho }
        end
    end
    table.sort(found, function(a, b) return a.len < b.len end)
    local lastWhy = "aucune forme possible"
    local refused = {}
    for _, f in ipairs(found) do
        local okS = FarmPilotCall(f.d.dubins_path_sample_many, f.d, f.path, ADWindrowBaleTask.DUBINS_STEP, ADDubins.createWayPoints)
        if okS and #f.d.outPath >= 2 then
            local pts = {}
            for _, p in ipairs(f.d.outPath) do
                pts[#pts + 1] = { x = p.x, y = p.y, z = p.z, isPathFinderPoint = true }
            end
            local _, ty = self:tractorPose()
            pts[#pts + 1] = { x = line.ax, y = ty, z = line.az, isPathFinderPoint = true }
            local problem = self:sweepProblem(pts, true)
            if problem == nil then
                return pts, string.format("%.0f m", f.len)
            end
            -- (17/11) chaque forme refusée au journal : longueur, raison et point
            log("%s : courbe de Dubins de %.0f m vers l'andain %s refusée : %s", self:name(), f.len, tostring(line.row.id), problem)
            refused[#refused + 1] = problem
            lastWhy = problem
        end
    end
    if #refused > 0 then
        lastWhy = string.format("%d forme(s) refusée(s), la plus courte : %s", #refused, refused[1])
    end
    return nil, lastWhy
end

-- approche directe (sans chemin) : l'andain est devant, pas trop de côté, assez de place pour se mettre droit
function ADWindrowBaleTask:canGoDirect(line)
    local tx, _, tz, hx, hz = self:tractorPose()
    if angleBetween(hx, hz, line.dx, line.dz) > ADWindrowBaleTask.DIRECT_ANGLE then
        return false
    end
    local px, _, pz = self:pickupPosition()
    local along = (px - line.ex) * line.dx + (pz - line.ez) * line.dz
    local sx, sz = rightOf(line.dx, line.dz)
    local lateral = math.abs((tx - line.p0x) * sx + (tz - line.p0z) * sz)
    if along > -ADWindrowBaleTask.DIRECT_ROOM or lateral > ADWindrowBaleTask.DIRECT_LATERAL then
        return false
    end
    return (self:straightClear(line))
end

function ADWindrowBaleTask:startDrive(path, how)
    local line = self.line
    local len = 0
    for i = 2, #path do
        len = len + dist2(path[i].x, path[i].z, path[i - 1].x, path[i - 1].z)
    end
    if self.uTurn then
        log("%s : demi-tour vers l'andain %s (%s, %.0f m, rayon %.1f m, ligne droite de %.0f m avant le bout)", self:name(), tostring(line.row.id), how, len, self.geo.rho, line.back + self.geo.behind)
    else
        log("%s : chemin vers l'andain %s (%s, %.0f m, ligne droite de %.0f m avant le bout)", self:name(), tostring(line.row.id), how, len, line.back + self.geo.behind)
    end
    self.path = path
    self.pathCheck = 0
    self.vehicle.ad.drivePathModule:setWayPoints(path)
    self:setState("drive")
end

function ADWindrowBaleTask:updateDrive(dt)
    local dpm = self.vehicle.ad.drivePathModule
    if dpm:isTargetReached() then
        self:startFollow(self.line, "fin du chemin")
        return
    end
    if self.timer >= ADWindrowBaleTask.DRIVE_TIMEOUT then
        self:holdVehicle(dt)
        self:failEnd(self.line.row, self.line.e, "chemin trop long")
        self:setState("choose")
        return
    end
    -- balle posée depuis le calcul sur ce qui reste du chemin : nouveau calcul
    self.pathCheck = self.pathCheck + dt
    if self.pathCheck >= ADWindrowBaleTask.PATH_CHECK_INTERVAL then
        self.pathCheck = 0
        local rest = {}
        local _, idx = dpm:getWayPoints()
        local tx, _, tz = self:tractorPose()
        rest[1] = { x = tx, z = tz }
        for i = math.max(1, idx or 1), #(self.path or {}) do
            rest[#rest + 1] = self.path[i]
        end
        if #rest >= 2 then
            local okP, problem = FarmPilotCall(self.sweepProblem, self, rest, false)
            if okP and problem ~= nil then
                self:holdVehicle(dt)
                log("%s : chemin vers l'andain %s : %s : nouveau calcul", self:name(), tostring(self.line.row.id), problem)
                self:startPlanning()
                return
            end
        end
    end
    dpm:update(dt)
end

-- ------------------------------------------------------------------------------------------------------------
-- Sur la ligne : approche puis andain, le pick-up au milieu
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowBaleTask:startFollow(line, how)
    local geo = self.geo
    local ref = Ref.new()
    local pre = line.back + geo.behind + ADWindrowBaleTask.REF_EXTRA
    -- départ loin derrière (approche directe : derrière le pick-up)
    local px, _, pz = self:pickupPosition()
    local alongP = (px - line.ex) * line.dx + (pz - line.ez) * line.dz
    pre = math.max(pre, -alongP + ADWindrowBaleTask.REF_EXTRA)
    local k = math.ceil(pre)
    while k >= 1 do
        Ref.add(ref, line.ex - line.dx * k, line.ez - line.dz * k)
        k = k - 1
    end
    Ref.add(ref, line.ex, line.ez)
    ref.sE = ref.s[ref.n]
    Ref.addResampled(ref, line.pts, 1)
    -- (17/11) dernier point à moins de 0,5 m de l'avant-dernier : celui-ci enlevé (les points sont décalés chacun sur
    -- sa normale : un segment si court donnerait un faux sens au prolongement après le bout)
    if ref.n >= 3 and ref.s[ref.n] - ref.s[ref.n - 1] < 0.5 and ref.s[ref.n - 1] > ref.sE + 0.5 then
        ref.x[ref.n - 1], ref.z[ref.n - 1] = ref.x[ref.n], ref.z[ref.n]
        ref.x[ref.n], ref.z[ref.n], ref.s[ref.n] = nil, nil, nil
        ref.n = ref.n - 1
        Ref.recompute(ref, ref.n)
    end
    self.ref = ref
    -- bout du balayage : sens de l'andain là (pris avant toute relecture), bouts arrêtés contre un autre andain
    self.endS, self.endIdx = ref.s[ref.n], ref.n
    self.endUx, self.endUz = Ref.tangent(ref, self.endS - 3, 3)
    local joins = line.row.joins or {}
    self.entryJoin, self.exitJoin = joins[line.e], joins[3 - line.e]
    if self.exitJoin ~= nil then
        log("%s : andain %s : s'arrête contre l'andain %s, fin au bout du balayage", self:name(), tostring(line.row.id), tostring(self.exitJoin))
    end
    -- (17/11) ligne d'origine et ses normales : la ligne relue = origine + écart posé sur chaque point ; devant la
    -- dernière lecture, la ligne prévue garde l'écart (carry) sur PREDICT m
    local base = { n = ref.n, x = {}, z = {}, nx = {}, nz = {} }
    for i = 1, ref.n do
        base.x[i], base.z[i] = ref.x[i], ref.z[i]
        local ux, uz = Ref.tangent(ref, ref.s[i], 1)
        base.nx[i], base.nz[i] = rightOf(ux, uz)
    end
    self.base = base
    self.carry = 0
    -- trous réunis par le balayage, en abscisse depuis le bout d'entrée
    self.gaps = {}
    for _, g in ipairs(line.row.gaps or {}) do
        local a, b = g.from, g.to
        if line.e == 2 then
            a, b = line.row.length - g.to, line.row.length - g.from
        end
        self.gaps[#self.gaps + 1] = { from = a, to = b, len = g.len or (b - a) }
    end
    table.sort(self.gaps, function(p, q) return p.from < q.from end)
    -- largeur habituelle de l'andain (lue au début), andain large, fourche
    self.rowWidth, self.widthN, self.widthSum, self.widthMax = nil, 0, 0, 0
    self.wideLogged, self.limitLogged, self.limitCount = false, false, 0
    self.anchor, self.forkOn, self.forkCount, self.sideCount = nil, false, 0, 0
    self.rowLiters, self.anchorFrom, self.anchorN, self.anchorSum, self.residueCount = nil, nil, 0, 0, 0
    self.sHint = nil
    self.entered = false
    self.nextProbe = 0
    self.lastSeen = 0
    self.seenCount = 0
    self.trustScan = false
    self.fbInt = 0
    self.lastSP = nil
    self.stuckTimer = 0
    self.baleCheck = 0
    self.baleAhead = nil
    self.edgeCheck = ADWindrowBaleTask.EDGE_CHECK_INTERVAL
    self.edgeAhead = nil
    self.edgeMax = 0
    self.stats = { n = 0, sum = 0, max = 0, dist = 0, speedSum = 0, t = 0 }
    self.followHow = how
    -- (journal) l'ensemble au début de la ligne : écart du tracteur à l'axe, biais du tracteur et de la presse
    local tx, _, tz, hx, hz = self:tractorPose()
    local sx, sz = rightOf(line.dx, line.dz)
    local bAngle = 0
    if not geo.rigid then
        local bx, bz = self:balerDir()
        bAngle = signedAngle(line.dx, line.dz, bx, bz)
    end
    log("%s : ligne de l'andain %s (%s) : tracteur à %.1f m de l'axe et %+.0f°, presse à %+.0f°, pick-up %.0f m avant le bout", self:name(), tostring(line.row.id),
        tostring(how), (tx - line.p0x) * sx + (tz - line.p0z) * sz, signedAngle(line.dx, line.dz, hx, hz), bAngle, -alongP)
    self:setState("line")
end

-- (17/11) point de la ligne d'origine le plus près de l'abscisse s (nil au-delà de la ligne d'origine)
function ADWindrowBaleTask:baseIndex(s)
    local ref, base = self.ref, self.base
    if base == nil or base.n < 2 then
        return nil
    end
    local i = Ref.index(ref, s)
    if i + 1 <= base.n and math.abs(ref.s[i + 1] - s) < math.abs(ref.s[i] - s) then
        i = i + 1
    end
    if i > base.n then
        return nil
    end
    return i
end

-- (17/11) écart off (m, + = à droite) posé sur le point i ; ligne prévue devant (PREDICT m) décalée de carry
function ADWindrowBaleTask:setOffset(i, off)
    local ref, base = self.ref, self.base
    ref.x[i], ref.z[i] = base.x[i] + base.nx[i] * off, base.z[i] + base.nz[i] * off
    local s0 = ref.s[i]
    local j = i + 1
    while j <= base.n and ref.s[j] - s0 <= ADWindrowBaleTask.PREDICT do
        ref.x[j], ref.z[j] = base.x[j] + base.nx[j] * self.carry, base.z[j] + base.nz[j] * self.carry
        j = j + 1
    end
    Ref.recompute(ref, i)
end

-- (17/11) trou réuni par le balayage à l'abscisse q (à plus de GAP_EDGE m de ses bouts) ?
function ADWindrowBaleTask:inGap(q)
    for _, g in ipairs(self.gaps or {}) do
        if q > g.from + ADWindrowBaleTask.GAP_EDGE and q < g.to - ADWindrowBaleTask.GAP_EDGE then
            return g
        end
    end
    return nil
end

-- (17/11) morceaux lus en travers sans les restes (moins de RESIDUE_PART x les litres habituels d'une lecture : passage
-- d'une roue, d'un pick-up en travers), une fois les litres habituels appris
function ADWindrowBaleTask:dropResidue(pieces, q)
    local L = self.rowLiters
    if L == nil or L <= 0 or type(pieces) ~= "table" then
        return pieces or {}
    end
    local kept = {}
    for _, p in ipairs(pieces) do
        if (p.l or 0) >= L * ADWindrowBaleTask.RESIDUE_PART then
            kept[#kept + 1] = p
        end
    end
    if #kept < #pieces then
        self.residueCount = self.residueCount + 1
        if self.residueCount == 1 then
            log("%s : andain %s : restes lus à %.0f m du bout d'entrée (moins de %.0f %% d'une lecture habituelle) : pas suivis",
                self:name(), tostring(self.line.row.id), q or 0, ADWindrowBaleTask.RESIDUE_PART * 100)
        end
    end
    return kept
end

-- (17/11) morceaux lus en travers : ceux séparés de moins de MERGE_GAP m réunis (trou dans un andain large) tant
-- qu'ils ne sont pas plus larges ensemble que MERGE_WIDTH x la largeur habituelle ; puis le morceau de la ligne
-- suivie (qui contient le milieu attendu expect, sinon le plus près). Renvoie ce morceau et la liste des autres
function ADWindrowBaleTask:pickPiece(pieces, expect)
    expect = expect or 0
    local W = self.rowWidth
    local maxW = W ~= nil and (W * ADWindrowBaleTask.MERGE_WIDTH + ADWindrowBaleTask.WIDTH_EXTRA) or math.huge
    local merged = {}
    for _, p in ipairs(pieces) do
        local last = merged[#merged]
        if last ~= nil and p.lo - last.hi <= ADWindrowBaleTask.MERGE_GAP + 1e-6 and p.hi - last.lo <= maxW then
            local l = last.l + p.l
            last.c = l > 0 and (last.c * last.l + p.c * p.l) / l or (last.c + p.c) / 2
            last.l, last.hi, last.cutHi = l, p.hi, p.cutHi
        else
            merged[#merged + 1] = { c = p.c, l = p.l, lo = p.lo, hi = p.hi, cutLo = p.cutLo, cutHi = p.cutHi }
        end
    end
    local best, bestD, bestC = nil, math.huge, math.huge
    for _, p in ipairs(merged) do
        local d = 0
        if p.lo > expect then
            d = p.lo - expect
        elseif p.hi < expect then
            d = expect - p.hi
        end
        if d < bestD - 1e-6 or (math.abs(d - bestD) <= 1e-6 and math.abs(p.c - expect) < bestC) then
            best, bestD, bestC = p, d, math.abs(p.c - expect)
        end
    end
    local others = {}
    for _, p in ipairs(merged) do
        if p ~= best then
            others[#others + 1] = p
        end
    end
    return best, others
end

-- (17/11) milieu de l'andain lu en travers au point (px, pz), sens (ux, uz) : écart (m, + = à droite) par rapport à
-- ce point, nil si rien. Andain large : milieu de toute sa largeur ; tas plus large que d'habitude (fourche,
-- jonction) : le bord qui continue la ligne suivie ; deux tas côte à côte : celui de la ligne suivie. expect : milieu
-- attendu (ligne déjà relue prolongée tout droit), par rapport au point lu : le balayage, lui, coude vers le milieu
-- d'une fourche
function ADWindrowBaleTask:readCenter(px, pz, ux, uz, q, expect)
    expect = expect or 0
    if ADWindrowScan == nil or ADWindrowScan.crossPieces == nil then
        local ok, off = callOf("ADWindrowScan", "centerOffset", px, pz, ux, uz, self.fillTypes, ADWindrowBaleTask.PROBE_HALF_SPAN)
        if ok and type(off) == "number" then
            return off
        end
        return nil
    end
    local okP, pieces = callOf("ADWindrowScan", "crossPieces", px, pz, ux, uz, self.fillTypes, ADWindrowBaleTask.PROBE_HALF_SPAN)
    if not okP or type(pieces) ~= "table" or #pieces == 0 then
        return nil
    end
    pieces = self:dropResidue(pieces, q)
    if #pieces == 0 then
        return nil
    end
    local piece, others = self:pickPiece(pieces, expect)
    if piece == nil then
        return nil
    end
    if piece.cutLo or piece.cutHi then
        -- touche le bord de la lecture : relu plus large, pour toute sa largeur
        local okW, wide = callOf("ADWindrowScan", "crossPieces", px, pz, ux, uz, self.fillTypes, ADWindrowBaleTask.WIDE_HALF_SPAN)
        if okW and type(wide) == "table" and #wide > 0 then
            local p2, o2 = self:pickPiece(self:dropResidue(wide, q), expect)
            if p2 ~= nil then
                piece, others = p2, o2
            end
        end
    end
    if piece.cutLo and piece.cutHi then
        -- tas sur toute la lecture (andain en travers) : milieu inconnu, la ligne prévue est gardée
        return 0
    end
    local width = piece.hi - piece.lo
    local W = self.rowWidth
    local name = self:name()
    local id = tostring(self.line.row.id)
    local pw = self.geo.pickupWidth or ADWindrowBaleTask.PICKUP_WIDTH
    -- andain large et irrégulier : sa largeur bouge beaucoup, bord suivi seulement pour une vraie fourche
    local anchorAbove = W ~= nil and W + ADWindrowBaleTask.ANCHOR_EXTRA or math.huge
    if W ~= nil and W > pw + ADWindrowBaleTask.WIDE_MARGIN then
        anchorAbove = W * ADWindrowBaleTask.FORK_WIDTH + ADWindrowBaleTask.WIDTH_EXTRA
    end
    if W ~= nil and (width > anchorAbove or piece.cutLo or piece.cutHi) then
        -- plus large que d'habitude (fourche, jonction, andain qui touche) : le milieu pris depuis le bord qui continue
        -- la ligne suivie (ligne prévue : bords attendus à ± W/2) ; bord gardé d'une lecture à l'autre
        local half = W / 2
        local errL = piece.cutLo and math.huge or math.abs(piece.lo - (expect - half))
        local errR = piece.cutHi and math.huge or math.abs(piece.hi - (expect + half))
        local side = errL <= errR and "gauche" or "droit"
        if self.anchor ~= nil and self.anchor ~= side then
            local keep = self.anchor == "gauche" and errL or errR
            local other = self.anchor == "gauche" and errR or errL
            if keep < math.huge and keep - other < ADWindrowBaleTask.FORK_STICKY then
                side = self.anchor
            end
        end
        self.anchor = side
        -- plus large depuis longtemps sans fourche finie : la largeur habituelle était mal apprise, relue
        self.anchorFrom = self.anchorFrom or q
        if not (piece.cutLo or piece.cutHi) then
            self.anchorN, self.anchorSum = self.anchorN + 1, self.anchorSum + width
        end
        if q - self.anchorFrom >= ADWindrowBaleTask.ANCHOR_RELEARN and self.anchorN > 0 then
            self.rowWidth = self.anchorSum / self.anchorN
            log("%s : andain %s : plus large que d'habitude sur %.0f m (%.1f m au lieu de %.1f) : largeur habituelle relue, milieu de toute la largeur",
                name, id, q - self.anchorFrom, self.rowWidth, W)
            self.anchor, self.anchorFrom, self.anchorN, self.anchorSum = nil, nil, 0, 0
            self.forkOn = false
            return piece.c
        end
        if not self.forkOn and (width > W * ADWindrowBaleTask.FORK_WIDTH + ADWindrowBaleTask.WIDTH_EXTRA or piece.cutLo or piece.cutHi) then
            self.forkOn = true
            self.forkCount = self.forkCount + 1
            log("%s : andain %s : tas plus large devant (%.1f m au lieu de %.1f) à %.0f m du bout d'entrée (%.0f, %.0f) : fourche ou jonction, bord %s suivi (branche dans l'axe), l'autre branche reste pour après",
                name, id, width, W, q, px, pz, side)
        end
        return side == "gauche" and piece.lo + half or piece.hi - half
    end
    if self.forkOn then
        self.forkOn = false
        log("%s : andain %s : largeur habituelle retrouvée à %.0f m du bout d'entrée (%.1f m)", name, id, q, width)
    end
    self.anchor, self.anchorFrom, self.anchorN, self.anchorSum = nil, nil, 0, 0
    -- largeur habituelle : moyenne des premières lectures (après le bout arrondi), puis suivie lentement (pas les
    -- lectures d'un andain entamé) ; litres habituels d'une lecture de même
    if not (piece.cutLo or piece.cutHi) then
        self.widthMax = math.max(self.widthMax or 0, width)
        if W == nil then
            if q >= ADWindrowBaleTask.WIDTH_SKIP then
                self.widthN, self.widthSum = self.widthN + 1, self.widthSum + width
                if self.widthN >= ADWindrowBaleTask.WIDTH_SAMPLES then
                    self.rowWidth = self.widthSum / self.widthN
                end
            end
        elseif width >= W * ADWindrowBaleTask.WIDTH_NARROW then
            self.rowWidth = W + (width - W) * ADWindrowBaleTask.WIDTH_RATE
        end
        if q >= ADWindrowBaleTask.WIDTH_SKIP and (self.rowLiters == nil or piece.l >= self.rowLiters * ADWindrowBaleTask.WIDTH_NARROW) then
            self.rowLiters = self.rowLiters == nil and piece.l or self.rowLiters + (piece.l - self.rowLiters) * ADWindrowBaleTask.WIDTH_RATE
        end
        if self.rowWidth ~= nil and not self.wideLogged and self.rowWidth > pw + ADWindrowBaleTask.WIDE_MARGIN then
            self.wideLogged = true
            log("%s : andain %s large (%.1f m, pick-up %.1f m) : milieu de toute la largeur, lissé, recentrage limité à %.2f m par m",
                name, id, self.rowWidth, pw, ADWindrowBaleTask.WIDE_RATE)
        end
    end
    -- deux tas séparés côte à côte : celui de la ligne suivie, jamais le milieu des deux
    for _, o in ipairs(others) do
        local gap = math.max(o.lo - piece.hi, piece.lo - o.hi)
        if gap <= ADWindrowBaleTask.SIDE_NEAR then
            self.sideCount = self.sideCount + 1
            if self.sideCount == 1 then
                log("%s : andain %s : deux tas côte à côte à %.0f m du bout d'entrée (%.0f, %.0f) : celui de la ligne suivie gardé (milieu à %+.1f m), l'autre (à %+.1f m) reste pour après",
                    name, id, q, px, pz, piece.c, o.c)
            end
            break
        end
    end
    return piece.c
end

-- lecture du milieu de l'andain à l'abscisse q (après le bout d'entrée) ; ligne corrigée, ou prolongée au-delà du bout
function ADWindrowBaleTask:probeAt(q)
    local ref = self.ref
    local s = ref.sE + q
    -- bout du balayage à son abscisse d'aujourd'hui (les relectures allongent un peu la ligne)
    local sEnd = ref.s[self.endIdx] or self.endS
    if s > sEnd then
        if self.exitJoin ~= nil then
            -- au-delà, c'est l'autre andain
            return false
        end
        -- au-delà du bout du balayage : sur le prolongement tout droit (sens de l'andain au bout), qui ne tourne pas
        local ux, uz = self.endUx, self.endUz
        local ox, oz = ref.x[self.endIdx] + ux * (s - sEnd), ref.z[self.endIdx] + uz * (s - sEnd)
        local limit = ADWindrowBaleTask.END_SHIFT + ADWindrowBaleTask.END_SPREAD * (s - sEnd)
        local ok, off = callOf("ADWindrowScan", "centerOffset", ox, oz, ux, uz, self.fillTypes, ADWindrowBaleTask.PROBE_HALF_SPAN)
        if not ok or type(off) ~= "number" then
            return false
        end
        if math.abs(off) > limit + ADWindrowBaleTask.END_OUTSIDE then
            -- andain lu loin du prolongement (andain de fourrière en travers, en biais) : pas celui-ci
            return false
        end
        self.lastSeen = math.max(self.lastSeen, q)
        self.seenCount = self.seenCount + 1
        local shift = clamp(off, -limit, limit)
        local rx, rz = rightOf(ux, uz)
        -- (17/11) point ajouté seulement à 0,5 m au moins du dernier (pas de faux sens au prolongement)
        if dist2(ox, oz, ref.x[ref.n], ref.z[ref.n]) >= 0.5 then
            Ref.add(ref, ox + rx * shift, oz + rz * shift)
        end
        return true
    end
    local i = self:baseIndex(s)
    if i == nil then
        return false
    end
    -- (17/11) trou réuni par le balayage : rien n'y est relu, la ligne continue tout droit
    if self:inGap(q) then
        self:setOffset(i, self.carry)
        return false
    end
    local base = self.base
    local nx, nz = base.nx[i], base.nz[i]
    local px, pz = base.x[i] + nx * self.carry, base.z[i] + nz * self.carry
    local ux, uz = nz, -nx
    -- milieu attendu : la ligne déjà relue (2 derniers mètres) prolongée tout droit jusqu'ici
    local expect = 0
    if i >= 4 then
        local ax, az, bx, bz = ref.x[i - 3], ref.z[i - 3], ref.x[i - 1], ref.z[i - 1]
        local dl = dist2(ax, az, bx, bz)
        if dl > 0.5 then
            local ahead = ref.s[i] - ref.s[i - 1]
            local ex, ez = bx + (bx - ax) / dl * ahead, bz + (bz - az) / dl * ahead
            expect = clamp((ex - px) * nx + (ez - pz) * nz, -ADWindrowBaleTask.PROBE_HALF_SPAN, ADWindrowBaleTask.PROBE_HALF_SPAN)
        end
    end
    local m = self:readCenter(px, pz, ux, uz, q, expect)
    if m == nil then
        self:setOffset(i, self.carry)
        return false
    end
    self.lastSeen = math.max(self.lastSeen, q)
    self.seenCount = self.seenCount + 1
    -- près d'un bout arrêté contre un autre andain : celui-ci est lu en travers, décalage limité (pas gardé)
    if (self.exitJoin ~= nil and s > sEnd - ADWindrowBaleTask.END_ZONE) or (self.entryJoin ~= nil and q < ADWindrowBaleTask.END_ZONE) then
        local shift = clamp(m, -ADWindrowBaleTask.END_SHIFT, ADWindrowBaleTask.END_SHIFT) * ADWindrowBaleTask.PROBE_BLEND
        self:setOffset(i, self.carry + shift)
        return true
    end
    local pw = self.geo.pickupWidth or ADWindrowBaleTask.PICKUP_WIDTH
    if self.rowWidth ~= nil and self.rowWidth > pw + ADWindrowBaleTask.WIDE_MARGIN then
        -- andain large : lissé, recentrage limité
        local step = ADWindrowBaleTask.WIDE_RATE * ADWindrowBaleTask.PROBE_STEP
        local d = m * ADWindrowBaleTask.WIDE_GAIN
        if math.abs(d) > step then
            self.limitCount = self.limitCount + 1
            if not self.limitLogged then
                self.limitLogged = true
                log("%s : andain %s : milieu lu à %.1f m de la ligne à %.0f m du bout d'entrée : recentrage limité à %.2f m par m",
                    self:name(), tostring(self.line.row.id), m, q, ADWindrowBaleTask.WIDE_RATE)
            end
        end
        self.carry = self.carry + clamp(d, -step, step)
    else
        self.carry = self.carry + clamp(m, -ADWindrowBaleTask.PROBE_MAX_SHIFT, ADWindrowBaleTask.PROBE_MAX_SHIFT) * ADWindrowBaleTask.PROBE_BLEND
    end
    self:setOffset(i, self.carry)
    return true
end

-- milieu de l'andain relu devant le pick-up, tous les PROBE_STEP m (au plus PROBE_MAX_PER_FRAME par image)
function ADWindrowBaleTask:probeAhead(sig, look)
    if ADWindrowScan == nil or ADWindrowScan.centerOffset == nil then
        self.trustScan = true
        return
    end
    local ahead = math.max(ADWindrowBaleTask.PROBE_AHEAD, look)
    local count = 0
    while self.nextProbe <= sig + ahead and count < ADWindrowBaleTask.PROBE_MAX_PER_FRAME do
        if self.nextProbe >= 0 then
            self:probeAt(self.nextProbe)
        end
        self.nextProbe = self.nextProbe + ADWindrowBaleTask.PROBE_STEP
        count = count + 1
    end
end

-- vitesse sur la ligne (km/h)
function ADWindrowBaleTask:lineSpeed(sP, sig)
    local speed = ADWindrowBaleTask.WORK_SPEED
    if sig < -ADWindrowBaleTask.SLOW_BEFORE then
        speed = ADWindrowBaleTask.APPROACH_SPEED
    end
    -- courbe de l'andain devant : plus lent
    local ref = self.ref
    local ax, az = Ref.tangent(ref, sP, 2)
    local reach = math.max(8, self.geo.behind + 6)
    local bx, bz = Ref.tangent(ref, sP + reach, 2)
    local turn = math.rad(angleBetween(ax, az, bx, bz))
    if turn > 0.01 then
        local radius = reach / turn
        if radius < ADWindrowBaleTask.CURVE_RADIUS then
            speed = math.min(speed, math.max(ADWindrowBaleTask.MIN_SPEED, radius * ADWindrowBaleTask.CURVE_SPEED))
        end
    end
    -- presse : limite du jeu (presque pleine, plateau qui pose)
    local okL, limit = callOf("ADBalerControl", "speedLimit", self.baler)
    if okL and type(limit) == "number" and limit > 0 then
        speed = math.min(speed, limit)
    end
    local b = self.baler
    if b ~= nil and type(b.speedLimit) == "number" and b.speedLimit > 0 then
        speed = math.min(speed, b.speedLimit)
    end
    return math.max(speed, 0.5)
end

function ADWindrowBaleTask:updateLine(dt)
    local ref, geo = self.ref, self.geo
    local row = self.line.row
    local px, _, pz = self:pickupPosition()
    local sP, eP = Ref.project(ref, px, pz, self.sHint, 12)
    self.sHint = sP
    local sig = sP - ref.sE
    local kmh = self:speedKmh()
    local look = clamp(kmh / 3.6 * ADWindrowBaleTask.LOOK_TIME, ADWindrowBaleTask.LOOK_MIN, ADWindrowBaleTask.LOOK_MAX)
    self:probeAhead(sig, look)
    -- l'écart est relu après la correction de la ligne
    sP, eP = Ref.project(ref, px, pz, sP, 6)
    sig = sP - ref.sE
    local tx, ty, tz, hx, hz = self:tractorPose()

    -- entrée dans l'andain
    if not self.entered and sig >= 0 then
        self.entered = true
        local ux, uz = Ref.tangent(ref, ref.sE + 2)
        local bAngle = 0
        if not geo.rigid then
            local bx, bz = self:balerDir()
            bAngle = angleBetween(bx, bz, ux, uz)
        end
        self.entry = { lateral = eP, angle = bAngle, speed = kmh }
        log("%s : entrée dans l'andain %s (%s) : pick-up à %.2f m du milieu, presse à %.1f° de l'axe, %.1f km/h", self:name(), tostring(row.id),
            tostring(self.followHow), math.abs(eP), bAngle, kmh)
    end

    -- fin de l'andain : plus rien lu devant sur END_GAP m et pick-up passé après le dernier andain vu
    if self.entered then
        if self.seenCount == 0 and not self.trustScan and sig >= ADWindrowBaleTask.END_MARGIN then
            -- rien lu du tout : andain parti, ou lecture impossible (alors la ligne du balayage est suivie)
            local okA, amount = callOf("ADWindrowScan", "amountAt", self.line.ex, self.line.ez, self.line.dx, self.line.dz, self.fillTypes, 2, 2)
            if okA and type(amount) == "number" and amount > 0 then
                self.trustScan = true
                self.lastSeen = row.length
                log("%s : andain %s : milieu de l'andain illisible devant le pick-up, ligne du balayage suivie", self:name(), tostring(row.id))
            end
        end
        local lastSeen = self.lastSeen
        if self.trustScan then
            lastSeen = math.max(lastSeen, ref.s[ref.n] - ref.sE)
        end
        -- (17/11) trou réuni par le balayage juste devant : la ligne continue tout droit jusqu'à son autre bout
        for _, g in ipairs(self.gaps or {}) do
            if g.to > lastSeen and g.from <= lastSeen + ADWindrowBaleTask.END_GAP + ADWindrowBaleTask.GAP_EDGE then
                lastSeen = g.to
                if not g.logged then
                    g.logged = true
                    log("%s : andain %s : trou de %.0f m réuni par le balayage (de %.0f à %.0f m du bout d'entrée) : tout droit sur la ligne",
                        self:name(), tostring(row.id), g.to - g.from, g.from, g.to)
                end
            end
        end
        if sig >= lastSeen + ADWindrowBaleTask.END_MARGIN and (sig + math.max(ADWindrowBaleTask.PROBE_AHEAD, look)) - lastSeen >= ADWindrowBaleTask.END_GAP then
            self:endRow("fin")
            return
        end
        -- écart du pick-up (pour le journal), sur l'andain
        if sig >= 3 and sig <= lastSeen - 1 then
            local st = self.stats
            local a = math.abs(eP)
            st.n, st.sum, st.max = st.n + 1, st.sum + a, math.max(st.max, a)
        end
    end

    -- balle posée devant le tracteur sur la ligne : arrêt de cet andain ici
    self.baleCheck = self.baleCheck + dt
    if self.baleCheck >= ADWindrowBaleTask.BALE_CHECK_INTERVAL then
        self.baleCheck = 0
        local fx, fz = tx + hx * geo.front, tz + hz * geo.front
        local sNose = Ref.project(ref, fx, fz, sP + geo.behind + geo.front, 15)
        local aheadX, aheadZ = Ref.point(ref, sNose + ADWindrowBaleTask.BALE_LOOK)
        local nx, nz = Ref.point(ref, sNose)
        local bale, along = self:baleInCorridor(nx, nz, aheadX, aheadZ, math.max(geo.halfWidth, geo.balerHalfWidth))
        self.baleAhead = nil
        if bale ~= nil then
            if along <= geo.rho + ADWindrowBaleTask.BALE_STOP + ADWindrowBaleTask.BALE_RADIUS then
                self:holdVehicle(dt)
                self:baleOnRow(bale, sNose + along - ref.sE)
                return
            end
            self.baleAhead = along
        end
    end

    -- (18/11) devant, sur la trajectoire prévue : herbe du bord (champ strict), objets fixes (toujours)
    self.edgeCheck = self.edgeCheck + dt
    if self.edgeCheck >= ADWindrowBaleTask.EDGE_CHECK_INTERVAL then
        self.edgeCheck = 0
        local qBad, why, wx, wz, off = self:edgeAheadProblem(sP)
        self.edgeAhead = nil
        if qBad ~= nil then
            if qBad - sig <= ADWindrowBaleTask.EDGE_STOP then
                self:holdVehicle(dt)
                self:edgeStop(sig, qBad, why, wx, wz, off)
                return
            end
            self.edgeAhead = qBad
        end
    end

    -- bloqué sur la ligne (sans arrêt demandé par la presse)
    if kmh < 0.3 then
        self.stuckTimer = self.stuckTimer + dt
        if self.stuckTimer >= ADWindrowBaleTask.STUCK_TIME then
            self:holdVehicle(dt)
            if self.entered then
                log("%s : bloqué sur l'andain %s (%.0f s sans avancer, %.0f m faits) : andain arrêté là", self:name(), tostring(row.id), self.stuckTimer / 1000, sig)
                self:splitRow(sig + ADWindrowBaleTask.BALE_CLEAR, "reste après le blocage")
                self:endRow("bloqué")
            else
                self:failEnd(row, self.line.e, "bloqué sur la ligne d'approche")
                self:setState("choose")
            end
            return
        end
    else
        self.stuckTimer = 0
    end

    -- point suivi par le tracteur : la ligne du pick-up décalée de la distance tracteur -> pick-up (vers l'avant, dans
    -- le sens de l'andain) et de l'écart du pick-up sur le côté ; plus la correction de l'écart qui reste
    local sT = sP + look
    local cx, cz = Ref.point(ref, sT)
    local ux, uz = Ref.tangent(ref, sT)
    local rx, rz = rightOf(ux, uz)
    local fb = 0
    if ADWindrowBaleTask.COMPENSATE then
        local sx, sz = sideOf(geo.hand, ux, uz)
        cx, cz = cx + ux * geo.behind - sx * geo.gx, cz + uz * geo.behind - sz * geo.gx
        local tpx, tpz = Ref.tangent(ref, sP)
        local heading = 0
        if not geo.rigid then
            local bx, bz = self:balerDir()
            heading = angleBetween(bx, bz, tpx, tpz)
        end
        if heading <= ADWindrowBaleTask.FB_HEADING_MAX then
            local ds = math.abs(sP - (self.lastSP or sP))
            self.fbInt = clamp(self.fbInt - ADWindrowBaleTask.FB_INTEGRAL * eP * ds, -ADWindrowBaleTask.FB_MAX, ADWindrowBaleTask.FB_MAX)
            fb = clamp(-ADWindrowBaleTask.FB_GAIN * eP + self.fbInt, -ADWindrowBaleTask.FB_MAX, ADWindrowBaleTask.FB_MAX)
        end
    else
        -- sans compensation (essai) : le tracteur suit la ligne de l'andain
        local sTr = Ref.project(ref, tx, tz, sP + geo.behind, 15)
        cx, cz = Ref.point(ref, sTr + look)
    end
    self.lastSP = sP
    cx, cz = cx + rx * fb, cz + rz * fb
    local speed = self:lineSpeed(sP, sig)
    if self.baleAhead ~= nil then
        speed = math.min(speed, ADWindrowBaleTask.BALE_SLOW_SPEED)
    end
    if self.edgeAhead ~= nil then
        speed = math.min(speed, ADWindrowBaleTask.EDGE_SLOW_SPEED)
    end
    local st = self.stats
    st.speedSum, st.t = st.speedSum + kmh * dt, st.t + dt
    self.lastLateral = eP
    self.vehicle.ad.specialDrivingModule:driveToPoint(dt, { x = cx, y = ty, z = cz }, speed, true, 0.5, speed, true,
        ADWindrowBaleTask.LINE_SLOW_ANGLE, ADWindrowBaleTask.LINE_SLOW_FACTOR)
end

-- (18/11) trajectoire prévue quand le pick-up est à l'abscisse s : tracteur (point suivi : ligne décalée de la distance
-- tracteur -> pick-up dans le sens de la ligne) et son sens, attelage, essieu et sens de la presse (traînée : du pick-up
-- vers l'attelage)
function ADWindrowBaleTask:predictedPose(s)
    local ref, geo = self.ref, self.geo
    local function tractorAt(t)
        local px, pz = Ref.point(ref, t)
        local ux, uz = Ref.tangent(ref, t, 1)
        local sx, sz = sideOf(geo.hand, ux, uz)
        return px + ux * geo.behind - sx * geo.gx, pz + uz * geo.behind - sz * geo.gx, px, pz, ux, uz
    end
    local tx, tz, px, pz, ux, uz = tractorAt(s)
    local ax2, az2 = tractorAt(s - 1)
    local bx2, bz2 = tractorAt(s + 1)
    local hx, hz = normalize(bx2 - ax2, bz2 - az2)
    if hx == 0 and hz == 0 then
        hx, hz = ux, uz
    end
    local pose = { tx = tx, tz = tz, hx = hx, hz = hz, px = px, pz = pz }
    if not geo.rigid then
        local hX, hZ = tx - hx * geo.hitchBack, tz - hz * geo.hitchBack
        local bux, buz = normalize(hX - px, hZ - pz)
        if bux == 0 and buz == 0 then
            bux, buz = hx, hz
        end
        pose.hX, pose.hZ = hX, hZ
        pose.bux, pose.buz = bux, buz
        pose.ax, pose.az = hX - bux * geo.tow, hZ - buz * geo.tow
    end
    return pose
end

-- (18/11) contrôle devant le pick-up (abscisse sP) sur EDGE_LOOK m, tous les EDGE_STEP m, jusqu'au bout de l'andain
-- (pick-up END_MARGIN m après le dernier andain vu) : abscisse depuis le bout d'entrée du premier point qui ne va pas,
-- raison, point, distance hors du champ ; nil si tout va
function ADWindrowBaleTask:edgeAheadProblem(sP)
    local ref, geo = self.ref, self.geo
    local sEndAbs = ref.s[self.endIdx] or self.endS or ref.s[ref.n]
    local last = math.max(sEndAbs, ref.sE + (self.lastSeen or 0))
    for _, g in ipairs(self.gaps or {}) do
        if ref.sE + g.to > last and ref.sE + g.from <= last + ADWindrowBaleTask.END_GAP then
            last = ref.sE + g.to
        end
    end
    local sMax = math.min(sP + ADWindrowBaleTask.EDGE_LOOK, last + ADWindrowBaleTask.END_MARGIN)
    local s = sP + ADWindrowBaleTask.EDGE_STEP
    local tw = geo.halfWidth
    local bw = geo.balerHalfWidth
    local om = ADWindrowBaleTask.OBSTACLE_MARGIN
    while s <= sMax + 1e-6 do
        local p = self:predictedPose(s)
        if self.strict then
            local why, wx, wz, off = self:edgeWhy("le tracteur", p.tx, p.tz, p.hx, p.hz, geo.rigid and math.max(tw, bw) or tw, p.px, p.pz)
            if why ~= nil then
                return s - ref.sE, why, wx, wz, off
            end
            self.edgeMax = math.max(self.edgeMax, off or 0)
            if not geo.rigid then
                why, wx, wz, off = self:edgeWhy("la presse", p.ax, p.az, p.bux, p.buz, bw, p.px, p.pz)
                if why ~= nil then
                    return s - ref.sE, why, wx, wz, off
                end
                self.edgeMax = math.max(self.edgeMax, off or 0)
            end
        end
        -- objets fixes : tracteur de l'attelage à l'avant, presse de l'attelage à l'arrière
        local name = self:obstacleOn(p.tx - p.hx * geo.hitchBack, p.tz - p.hz * geo.hitchBack, p.tx + p.hx * geo.front, p.tz + p.hz * geo.front,
            (geo.rigid and math.max(tw, bw) or tw) + om)
        if name ~= nil then
            return s - ref.sE, string.format("le tracteur toucherait un objet fixe « %s » en (%.0f, %.0f)", name, p.tx, p.tz), p.tx, p.tz, nil
        end
        if not geo.rigid then
            local bname = self:obstacleOn(p.hX, p.hZ, p.hX - p.bux * geo.length, p.hZ - p.buz * geo.length, bw + om)
            if bname ~= nil then
                return s - ref.sE, string.format("la presse toucherait un objet fixe « %s » en (%.0f, %.0f)", bname, p.ax, p.az), p.ax, p.az, nil
            end
        end
        s = s + ADWindrowBaleTask.EDGE_STEP
    end
    return nil
end

-- (18/11) arrêt avant le point qui ne va pas (abscisse qBad) : sur la ligne d'approche, ce bout est laissé ; sur
-- l'andain, le reste devient un morceau à part (essayé par son autre bout s'il va, sinon laissé)
function ADWindrowBaleTask:edgeStop(sig, qBad, why, wx, wz, off)
    local row = self.line.row
    local offText = ""
    if off ~= nil then
        offText = off < math.huge and string.format(", %.1f m hors du sol du champ", off)
            or string.format(", plus de %.1f m hors du sol du champ", ADWindrowBaleTask.EDGE_GRASS + ADWindrowBaleTask.EDGE_SEARCH)
    end
    if not self.entered then
        log("%s : andain %s : arrêt sur la ligne d'approche, %s%s, à %.0f m devant le pick-up : bout %s laissé", self:name(), tostring(row.id), tostring(why),
            offText, qBad - sig, endName(self.line.e))
        self:dropEnd(row, self.line.e, why)
        self:setState("choose")
        return
    end
    log("%s : andain %s : arrêt à %.0f m du bout d'entrée, %s%s (pick-up à %.0f m de là) : reste de l'andain à part",
        self:name(), tostring(row.id), sig, tostring(why), offText, qBad - sig)
    self:splitRow(sig, "reste avant le bord", why, row.why[3 - self.line.e])
    self:endRow("bord")
end

-- morceau de l'andain après l'abscisse sig (gardé pour plus tard, s'il est assez long). (18/11) blockedWhy : son bout
-- de coupe ne va pas (arrêt au bord) ; farWhy : son autre bout non plus (déjà laissé) ; les deux : morceau laissé
function ADWindrowBaleTask:splitRow(sig, why, blockedWhy, farWhy)
    local ref = self.ref
    local row = self.line.row
    local from = ref.sE + math.max(0, sig)
    local pts = {}
    for i = 1, ref.n do
        if ref.s[i] >= from then
            pts[#pts + 1] = { x = ref.x[i], z = ref.z[i] }
        end
    end
    local len = 0
    for i = 2, #pts do
        len = len + dist2(pts[i].x, pts[i].z, pts[i - 1].x, pts[i - 1].z)
    end
    if len < ADWindrowBaleTask.MIN_PIECE then
        log("%s : andain %s : %s trop court (%.0f m), pas gardé", self:name(), tostring(row.id), tostring(why), len)
        return
    end
    local id = tostring(row.id) .. "+"
    local gaps = {}
    local fromQ = math.max(0, sig)
    for _, g in ipairs(self.gaps or {}) do
        if g.to > fromQ + 1 then
            gaps[#gaps + 1] = { from = math.max(0, g.from - fromQ), to = g.to - fromQ, len = g.len }
        end
    end
    local piece = { id = id, points = pts, length = len, fillType = row.fillType, state = "todo", tries = { 0, 0 }, why = { blockedWhy, farWhy },
        joins = { nil, self.exitJoin }, index = #self.rows + 1, gaps = gaps }
    self.rows[#self.rows + 1] = piece
    if blockedWhy ~= nil and farWhy ~= nil then
        piece.state = "left"
        log("%s : andain %s : %s laissé (andain %s, %.0f m) : aucun bout faisable (%s / %s)", self:name(), tostring(row.id), tostring(why), id, len,
            tostring(blockedWhy), tostring(farWhy))
        return
    end
    log("%s : andain %s : %s gardé pour plus tard (andain %s, %.0f m%s)", self:name(), tostring(row.id), tostring(why), id, len,
        blockedWhy ~= nil and ", par son autre bout" or "")
end

-- balle posée sur l'andain devant le tracteur
function ADWindrowBaleTask:baleOnRow(bale, baleSig)
    local row = self.line.row
    if not self.entered then
        log("%s : blocage : balle posée sur la ligne d'approche de l'andain %s (%.0f, %.0f)", self:name(), tostring(row.id), bale.x, bale.z)
        self:dropEnd(row, self.line.e, string.format("balle posée sur la ligne d'approche (%.0f, %.0f)", bale.x, bale.z))
        self:setState("choose")
        return
    end
    log("%s : blocage : balle posée sur l'andain %s à %.0f m du bout d'entrée (%.0f, %.0f) : andain arrêté avant la balle", self:name(), tostring(row.id),
        baleSig, bale.x, bale.z)
    self:splitRow(baleSig + ADWindrowBaleTask.BALE_CLEAR, "morceau après la balle")
    self:endRow("balle devant")
end

function ADWindrowBaleTask:endRow(how)
    local row = self.line.row
    local st = self.stats
    local ref = self.ref
    local px, _, pz = self:pickupPosition()
    local sP = Ref.project(ref, px, pz, self.sHint, 12)
    local followed = math.max(0, sP - ref.sE)
    row.state = "done"
    self.doneCount = self.doneCount + 1
    self.pressedSinceScan = self.pressedSinceScan + 1
    local total, done = self:counts()
    log("%s : fin de l'andain %s (%s) : %.0f m suivis sur %.0f, pick-up à %.2f m du milieu en moyenne (%.2f au plus), %.1f km/h en moyenne ; %d/%d fait(s)",
        self:name(), tostring(row.id), tostring(how), followed, row.length, st.n > 0 and st.sum / st.n or 0, st.max,
        st.t > 0 and st.speedSum / st.t or 0, done + self.doneBefore, total + self.doneBefore)
    if self.rowWidth ~= nil and (self.wideLogged or self.forkCount > 0 or self.sideCount > 0 or (self.residueCount or 0) > 0) then
        log("%s : andain %s : largeur habituelle %.1f m (%.1f au plus), pick-up %.1f m ; %d fourche(s) ou jonction(s), %d fois deux tas côte à côte, %d recentrage(s) limité(s), %d lecture(s) avec des restes",
            self:name(), tostring(row.id), self.rowWidth, self.widthMax or 0, self.geo.pickupWidth or 0, self.forkCount, self.sideCount, self.limitCount,
            self.residueCount or 0)
    end
    if self.strict and (self.edgeMax or 0) > 0 then
        log("%s : andain %s : sur l'herbe du bord au plus à %.1f m du sol du champ (prévu, %.0f m permis)", self:name(), tostring(row.id), self.edgeMax,
            ADWindrowBaleTask.EDGE_GRASS)
    end
    self.lastRow = { id = row.id, followed = followed, mean = st.n > 0 and st.sum / st.n or 0, max = st.max, entry = self.entry,
        width = self.rowWidth, forks = self.forkCount, edgeMax = self.edgeMax }
    self.history = self.history or {}
    self.history[#self.history + 1] = self.lastRow
    self.entry = nil
    self.current = nil
    self:setState("choose")
end

-- ------------------------------------------------------------------------------------------------------------
-- À chaque image
-- ------------------------------------------------------------------------------------------------------------
-- presse toujours attelée à ce tracteur (ou presse automotrice)
function ADWindrowBaleTask:balerAttached()
    local b = self.baler
    if b == nil or b.isDeleted or b.isDeleting then
        return false
    end
    if b == self.vehicle then
        return true
    end
    if ADBalerManager ~= nil and ADBalerManager.isAttached ~= nil and ADSeederManager ~= nil then
        local ok, att = FarmPilotCall(ADBalerManager.isAttached, b, self.vehicle)
        if ok then
            return att == true
        end
    end
    if b.getRootVehicle ~= nil then
        local ok, root = FarmPilotCall(b.getRootVehicle, b)
        return ok and root == self.vehicle
    end
    return true
end

function ADWindrowBaleTask:update(dt)
    self.timer = self.timer + dt
    if not self:balerAttached() then
        self:holdVehicle(dt)
        log("%s : presse dételée : arrêt", self:name())
        self:finish("detached")
        return
    end
    -- ficelle / filet vide : recharge (le mode fait le trajet)
    local okT, empty = callOf("ADBalerControl", "twineEmpty", self.baler)
    if okT and empty == true then
        self:holdVehicle(dt)
        log("%s : plus de ficelle / filet : arrêt pour la recharge (andain %s)", self:name(), self.current ~= nil and tostring(self.current.id) or "-")
        self:finish("refill")
        return
    end
    -- arrêt demandé par la presse (pleine, éjection, enrubannage) : on attend sur place
    local okS, stop = callOf("ADBalerControl", "mustStop", self.baler)
    if okS and stop == true and self.state ~= "planning" and self.state ~= "rescan" then
        self:holdVehicle(dt)
        if self.stopSince == nil then
            self.stopSince = g_time or 0
            log("%s : arrêt demandé par la presse (pleine ou balle en sortie)", self:name())
        end
        self.timer = self.timer - dt
        return
    end
    if self.stopSince ~= nil then
        log("%s : la presse repart après %.1f s d'arrêt", self:name(), ((g_time or 0) - self.stopSince) / 1000)
        self.stopSince = nil
    end

    if self.state == "choose" then
        self:updateChoose(dt)
    elseif self.state == "planning" then
        self:updatePlanning(dt)
    elseif self.state == "drive" then
        self:updateDrive(dt)
    elseif self.state == "line" then
        self:updateLine(dt)
    elseif self.state == "rescan" then
        self:updateRescan(dt)
    else
        self:holdVehicle(dt)
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Fin
-- ------------------------------------------------------------------------------------------------------------
function ADWindrowBaleTask:finish(result)
    if self.result ~= nil then
        return
    end
    self.result = result
    self.vehicle.ad.specialDrivingModule:stopVehicle()
    self:clearZones()
    local total, done = self:counts()
    log("%s : pressage des andains fini (%s) : %d/%d andain(s) fait(s)%s", self:name(), tostring(result), done + self.doneBefore, total + self.doneBefore,
        self.rescans > 0 and string.format(", %d nouveau(x) balayage(s)", self.rescans) or "")
    self:finished()
end

function ADWindrowBaleTask:abort()
    self:clearZones()
end

function ADWindrowBaleTask:finished()
    self:clearZones()
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

-- { done, total, windrowId, index, left } : andains faits / total (ceux d'avant une recharge compris), andain en
-- cours, andains laissés (rien de faisable)
function ADWindrowBaleTask:getProgress()
    local total, done = self:counts()
    local left = 0
    for _, row in ipairs(self.rows) do
        if row.state == "left" then
            left = left + 1
        end
    end
    local row = self.current or (self.line ~= nil and self.line.row) or nil
    return { done = done + self.doneBefore, total = total + self.doneBefore, windrowId = row ~= nil and row.id or nil, index = row ~= nil and row.index or nil,
        left = left }
end

-- « Presse les andains (faits/total) »
function ADWindrowBaleTask:getI18nInfo()
    if self.state == "planning" then
        return self:getPlanningI18n()
    end
    local p = self:getProgress()
    return "$l10n_AD_task_autonomous_windrow;" .. string.format(" (%d/%d)", p.done, p.total)
end
