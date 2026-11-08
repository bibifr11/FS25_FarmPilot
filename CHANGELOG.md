# FarmPilot – Changelog

FarmPilot 1.0.0.0 est basé sur AutoDrive 3.0.1.4 (Stephan Schlosser et l'équipe AutoDrive, licence MIT).
FarmPilot 1.0.0.0 is based on AutoDrive 3.0.1.4 (Stephan Schlosser and the AutoDrive team, MIT licence).

## 1.0.1.12

- Moissonneuse : le tracteur reste sous la goulotte pendant le déchargement.
- Le mod autoTurnOffTurnLights est neutralisé quand FarmPilot conduit (clignotants gérés par FarmPilot).
- Combine: the tractor stays under the pipe while unloading.
- The autoTurnOffTurnLights mod is neutralised while FarmPilot drives (indicators handled by FarmPilot).

## 1.0.1.11

- Fenêtre « Réglages du semoir » : culture et zone de ravitaillement en listes déroulantes ; seules les cultures de saison sont proposées.
- Virages : un virage n'est plus redessiné si l'attelage passe sur la route telle qu'elle est dessinée (plus de coupures de voie inutiles).
- "Seeder settings" window: crop and refill zone as drop-down lists; only in-season crops are offered.
- Bends: a bend is no longer redrawn when the train fits the route as drawn (no more needless lane cutting).

## 1.0.1.9

- Semoir en mode Autonome : roue dentée sur la ligne Outil (orange = à régler, verte = validé) qui ouvre la fenêtre « Réglages du semoir » (culture, cuves à remplir, zone de ravitaillement), retenue par champ et par semoir. Au départ il fait le plein si besoin ; quand le semoir est vide au champ, il sort, refait le plein comme en mode Chargement (palettes, big bags, silos), revient et Courseplay repart au dernier point.
- Seeder in Autonomous mode: gear icon on the Tool line (orange = to set, green = validated) opens the "Seeder settings" window (crop, tanks to fill, refill zone), saved per field and seeder. It fills up before leaving if needed; when the seeder is empty in the field, it leaves, refills like the Load mode (pallets, big bags, silos), comes back and Courseplay resumes at the last point.

## 1.0.1.8

### Nouveau mode « Autonome »
- FarmPilot conduit jusqu'au champ, puis charge et lance le parcours Courseplay enregistré pour ce champ et la largeur de l'outil. La fenêtre « Parcours Autonome » (Ctrl + Alt + 5 pavé numérique) permet de choisir le parcours de chaque champ.
- HUD en mode Autonome : Champ, Outil, Champ suivant, Outil suivant.
- Fin du champ : l'outil est posé à sa place de parking, puis le tracteur va chercher l'outil suivant (routes, marche arrière, attelage, flexibles et prise de force) et part au champ suivant. Si l'outil suivant n'est pas disponible, il pose quand même l'outil et s'arrête avec un message.
- Compatible avec le mod d'attelage manuel (flexibles et prise de force branchés et débranchés automatiquement).

### Conduite
- Fin de route trop serrée : une manœuvre avant / arrière / avant est calculée avant le départ, ou un détour s'il est plus rapide.
- Poteaux et piquets sur la route : la route passe à côté. S'il pousse sans avancer, il recule et contourne.
- Vitesse adaptée dans les virages ; le clignotant reste allumé jusqu'à ce que le tracteur soit droit.
- Le champ d'arrivée est celui du marqueur de destination.
- Courseplay laisse le clic droit au HUD et à l'éditeur de FarmPilot.
- Aide en jeu et textes à jour (FR, EN, DE).

### New "Autonomous" mode
- FarmPilot drives to the field, then loads and starts the saved Courseplay course for that field and the tool width. The "Autonomous courses" window (Ctrl + Alt + numpad 5) picks the course for each field.
- HUD in Autonomous mode: Field, Tool, Next field, Next tool.
- End of field: the tool is parked at its parking spot, then the tractor fetches the next tool (roads, reversing, hitching, hoses and PTO) and drives to the next field. If the next tool is not available, it still parks the tool and stops with a message.
- Works with the manual attach mod (hoses and PTO connected and disconnected automatically).

### Driving
- Route end too tight: a forward / reverse / forward manoeuvre is planned before leaving, or a detour if it is faster.
- Posts and poles on the route: the route goes around them. If it pushes without moving, it backs up and goes around.
- Speed adapted in bends; the indicator stays on until the tractor is straight.
- The arrival field is the one of the destination marker.
- Courseplay leaves the right click to the FarmPilot HUD and editor.
- In-game help and texts updated (FR, EN, DE).

## 1.0.0.1
- Allemand : 13 textes manquants ajoutés (contournement d'obstacle, virage large, évitement) / German: 13 missing texts added.
- Français et allemand : 66 textes restés en anglais traduits / French and German: 66 texts still in English translated.

## 1.0.0.0

### Passage d'AutoDrive à FarmPilot
- Nouveau nom, nouvelle icône, auteur bibifr. Les crédits et la licence d'AutoDrive sont gardés.
- Si vous jouez déjà avec AutoDrive : FarmPilot reprend votre réseau de routes (fichier AutoDrive_config.xml de la partie), le dossier modSettings/FS25_AutoDrive (routes enregistrées, couleurs) et les réglages des véhicules. Rien à copier.
- Nouvelle installation ou nouvelle partie : tout est enregistré sous le nom FarmPilot (FarmPilot_config.xml, modSettings/FS25_FarmPilot).
- Si AutoDrive est aussi activé, FarmPilot le désactive (HUD, touches, conduite) et affiche un message pour le retirer des mods.
- Les mods qui cherchent AutoDrive (Courseplay, addons…) trouvent FarmPilot à sa place.

### 1. Croisement face à face sur route à double sens
- Deux véhicules FarmPilot qui se retrouvent nez à nez ne restent plus bloqués : l'un se range sur le bas-côté, l'autre recule, puis chacun reprend sa route.
- Le croisement est repéré de loin, en comparant les trajets sur 250 m : les deux ralentissent et s'arrêtent à bonne distance l'un de l'autre.
- Si l'un peut sortir du tronçon commun avant que l'autre y entre, il passe simplement le premier.
- Les rôles (qui recule, qui se range) sont choisis toujours de la même façon : en priorité le véhicule vide, puis celui sans remorque.
- La place sur le bas-côté est calculée avec la taille réelle des deux attelages (longueur, largeur, outils avant et arrière), la pente, l'eau et les champs.
- Le véhicule se range du côté de la circulation, jamais à contresens. Réglage droite ou gauche pour les cartes en conduite à gauche.
- Si rien ne marche : il recule le long de sa route, les rôles s'inversent, ou il se cache dans un embranchement ou un cul-de-sac du réseau.
- Après deux échecs, message rouge et pause de 5 minutes pour la paire.
- Il prend un autre itinéraire (400 m de plus au maximum) quand ça évite le tronçon en face à face.
- Plus de deux véhicules : gestion des convois (seul le premier négocie) et d'un troisième véhicule qui arrive pendant la manœuvre.
- Chemin à voie unique : celui qui cède s'arrête 15 m avant l'entrée du chemin, ou continue tout droit s'il n'a pas besoin du chemin.
- Celui qui est dans le chemin recule quand l'autre est coincé, jusqu'à sortir du trajet de sortie de champ de l'autre.
- Priorité à celui qui sort du chemin, et il prend l'autre voie dès qu'elle est à 5 m.
- 28/10 : l'attente dure le temps que l'attelage qui sort passe, plus 10 m.
- 28/10 : la manœuvre se termine seulement quand l'autre ne vient plus vers lui.
- 28/10 : un recul bloqué (10 s, ou 90 s sans avancer) inverse les rôles.
- 28/10 : une remorque de coupe ne recule jamais.
- Nouveaux réglages : croisement oui/non, délai avant croisement, recul maximum, marge entre les attelages, côté de circulation.

### 2. Attente dans le champ (stationnement)
- Une benne qui attend l'appel de la moissonneuse ou de l'ensileuse entre dans le champ et se gare le long de la bordure. Avant, elle bouchait la route à l'entrée.
- La place est choisie sur du sol déjà récolté, à plat, loin des chemins, au moins à 40 m de l'entrée, parallèle à la bordure, du côté où travaille la machine.
- Le trajet jusqu'à la place ne passe jamais dans la culture debout.
- La place est retenue par champ dans la sauvegarde : les bennes suivantes y vont directement.
- Les bennes se garent en file l'une derrière l'autre, sur la même bande récoltée.
- Les places laissent la place de repartir et sont orientées dans le sens de travail de la machine.
- Les bennes font la file dans la première bande étroite d'un champ en ouverture.
- Champ plein : la benne vide attend au bord de la route avant l'entrée et avance quand une place se libère. Sans place, elle recule de 40 m.
- Une benne vide attend avant l'entrée pendant qu'une pleine sort par là (120 s au maximum).
- Dernier essai des deux côtés, plus loin et plus près de l'entrée, quand le côté de la machine n'a rien.
- Les bennes sont appelées dans leur ordre d'arrivée.
- Pas de place au démarrage : la benne attend au bord de la route.
- Nouveau réglage : « Attente dans le champ » (oui par défaut).

### 3. Sortie du champ
- Pour quitter le champ, le véhicule vise d'abord l'entrée du champ où il se trouve (jusqu'à 2000 m), au lieu du point du réseau le plus proche, qui peut être derrière la culture ou sur le champ voisin.
- S'il ne peut pas l'atteindre proprement, il essaie jusqu'à 6 autres points du réseau, sans traverser la culture ni passer par un autre champ.
- Les portails sont passés dans l'axe : le tracteur se met en ligne 12 à 20 m avant, puis va tout droit.
- Une benne vide arrêtée sur le point de sortie : il prend le point suivant.
- L'entrée est essayée 3 fois avant de passer à un autre point.
- La 2e benne appelée qui arrive par l'entrée se gare d'abord dans le champ pour laisser sortir.
- Benne pleine : elle prend la sortie la plus proche, s'il n'y a pas d'obstacle ou d'autre champ à traverser.

### 4. Champ et culture : mode « Strict »
- « Rester dans le champ » et « Éviter la culture » ont une 3e valeur, « Strict » : le calcul de trajet ne lève jamais la restriction en secours.
- En Strict, le champ, c'est le sol de champ relié au départ et à l'arrivée : la benne ne passe jamais sur le champ voisin. L'herbe en bordure reste utilisable.
- Les petits îlots de culture oubliés sont ignorés.
- Le calcul de trajet affine sa grille (6 m, 4,5 m puis 2 m) avant tout secours, et arrondit les virages au rayon réel du tracteur.
- La culture est vérifiée sur le couloir réellement suivi par les roues de tout l'attelage.
- Les branches au-dessus de l'attelage ne comptent plus comme un mur.
- Trajet partiel : quand aucun trajet complet n'existe, il roule jusqu'au dernier point propre et recalcule de là. Un trajet partiel ne finit jamais dans la culture.
- Départ guidé : un attelage coincé (culture autour, virage trop serré) se dégage d'abord par de petites courbes en avant.
- Un endroit où un véhicule bloque sans arrêt devient une zone interdite pour les calculs suivants. Ces zones expirent après 5 minutes.

### 5. Ensileuse (benne qui suit l'ensileuse)
#### Approche
- La benne vise la place derrière l'ensileuse, sur sa trace coupée, puis choisit elle-même le côté libre.
- La place derrière suit la trace réellement roulée par l'ensileuse, aussi en courbe et après son demi-tour.
- Elle ne fait plus le tour de l'ensileuse arrêtée dans le mauvais sens.
- Après deux arrivées au même endroit inutile, elle fait demi-tour dans la bande ou recule dans ses traces.
- Ensileuse arrêtée : la benne va directement à la goulotte.
- Ensileuse qui vient vers elle : la benne recule hors de son chemin si c'est libre derrière, sinon elle attend.
- Après deux reculs pour la même ensileuse, elle la laisse à une autre benne pendant 2 minutes.
- Pas de trajet trouvé deux fois près de l'ensileuse arrêtée : la poursuite prend le relais, quitte à couper une pointe de maïs.
- Carte fine du champ (sol de champ et culture) et itinéraires par l'intérieur des bandes coupées, sans marche arrière, quand la grille ne trouve rien (« on fait le tour du champ par l'intérieur »).

#### Poursuite
- La benne suit l'ensileuse sur sa trace et lit la course Courseplay devant (bout de rang, demi-tour, décrochement).
- Elle garde la place arrière pendant que l'ensileuse tourne.
- La ligne droite vers la place est vérifiée toutes les demi-secondes (obstacle, hors champ, autre champ, culture). Si elle est bloquée, la benne s'arrête et calcule un trajet.
- Un côté dont la place est prise par un obstacle fixe est évité un moment.
- Elle attend un véhicule sur sa ligne (60 s au maximum).
- La bande d'herbe à côté du champ est acceptée.
- Position 3/4 arrière : elle la quitte quand l'ensileuse s'arrête ou que la ligne est bloquée, puis roule derrière jusqu'à 0,5 m du nez.
- Elle n'attend plus qu'une ensileuse arrêtée passe.
- Elle se rapproche derrière l'ensileuse.
- Les décrochements et fins de rang Courseplay sont traversés au lieu d'être pris pour des demi-tours.

#### Deuxième benne (suiveuse)
- La 2e benne vise les traces de la 1re et attend derrière elle pendant que la 1re est en place.
- Pour rejoindre, ordre de recherche : traces de la 1re, puis bord du maïs, puis bandes coupées, puis grille fine, puis ligne droite.
- Tant que la 1re n'est pas en place, la 2e attend sur une place dans le champ et non dans l'entrée. Elle s'y gare aussi après 2 échecs de calcul.
- Elle s'écarte quand l'ensileuse ou la 1re benne revient vers elle, laisse passer, puis revient se placer.

#### Demi-tours en bout de rang
- Le demi-tour de l'ensileuse est lu sur ses points de virage Courseplay. Le simple drapeau « virage » ne déclenche plus de demi-tour.
- Ordre des manœuvres : demi-tour en avant, recul puis demi-tour, demi-tour décalé, manœuvre en Y quand la fourrière est étroite (ton dessin du 25/10).
- Manœuvre en équerre, d'après tes deux dessins du 27/10 : quart de tour, recul droit, quart de tour dans le nouveau rang.
- Demi-tour dans la bande coupée quand la fourrière n'a pas de place, la remorque pouvant reculer dans la culture.
- Chaque manœuvre est vérifiée avant d'être lancée (sol de champ, culture, obstacles), au rayon de braquage propre du tracteur.
- La trace de la remorque est aussi vérifiée à l'intérieur des virages serrés.

#### Benne pleine
- Si aucune sortie en avant n'est possible, elle recule dans ses traces, se range sur le récolté ou l'herbe pour laisser passer la suivante, ou fait demi-tour dans la bande vers la sortie.
- Rangée de côté, elle suit la bande coupée et cherche une sortie en chemin. L'entrée du champ reste la sortie préférée.
- Plusieurs bennes pleines coincées : la moins gênée par la culture sort la première.
- Pour reculer dans ses traces, elle refuse une trace collée au maïs, s'arrête si la remorque touche la culture, et ne recule pas plus de 25 m d'affilée.

#### Chantier
- La benne reste avec son ensileuse jusqu'à ce qu'elle soit pleine, et la file garde l'ordre d'arrivée.
- Un court arrêt de Courseplay ne libère plus les bennes. Seul un long arrêt les libère.
- Fin du chantier (vue aussi via Courseplay) : chaque benne vide ce qu'elle porte, puis va à son parking.
- La sécurité « coincé » laisse d'abord la benne se dégager (reculer, recalculer) avant de tout réinitialiser.
- Le bouton « continuer » du joueur est distingué des autres appels.

### 6. Obstacles sur la route (conducteur « intelligent »)
- Freinage anticipé : il regarde le trajet devant et ralentit progressivement avant un obstacle, au lieu de piler au dernier moment.
- Il suit un véhicule plus lent à sa vitesse et garde 3 m derrière un autre véhicule FarmPilot.
- Petit écart : un obstacle d'un seul côté (poteau, balle, panneau, voiture garée) est évité par un léger décalage, sans s'arrêter.
- Voiture du trafic arrêtée nez à nez : il recule un peu, change de voie, puis passe.
- Contournement : bloqué par un objet fixe (objet tombé, muret, arbre), il recule puis calcule un chemin autour pour rejoindre sa route plus loin. Sinon il reste arrêté avec un message.
- Un premier essai de contournement rapide se fait sans reculer.
- Un véhicule arrêté depuis un moment est aussi contourné (plus vite s'il est vide).
- Devant un portail, il attend au lieu de contourner.
- Pas de contournement pendant l'attente à un croisement.
- La sécurité « coincé » tente un contournement avant de relancer.
- Nouveaux réglages : contournement oui/non, délai avant contournement, recul avant contournement, écart devant un obstacle léger.

### 7. Virages larges
- Les virages serrés du réseau sont pris en arc, au rayon de braquage réel de l'attelage.
- Le tracteur déborde en entrée ou en sortie quand la place est libre, et la remorque ne coupe plus l'intérieur.
- Nouveau réglage : « Virages larges ».

### 8. Passages étroits
- Le calcul d'itinéraire évite les tronçons trop étroits pour l'attelage (roues jumelées, outil large) quand un autre chemin existe.
- La largeur est mesurée aux pneus du tracteur. Les outils repliables comptent pour 2,4 m.
- Au départ d'un calcul (reprise après Courseplay en bordure), le couloir devant est vérifié : il démarre plus près s'il y a un arbre ou un muret.
- Affichage de débogage : cadre bleu pour la largeur prise, cadres rouges sur les tronçons refusés.

### 9. Intersections (nouveau type de route, points rouges)
- Nouveau marquage « Intersection » dans l'éditeur (Maj gauche + clic). Il se pose en plus du type normal ou secondaire.
- Avant de traverser ou de s'insérer, il ralentit (20 puis 8 km/h) et regarde les voies sur 120 m.
- Il s'arrête juste avant le premier point rouge si un véhicule arrive (voiture du jeu, tracteur, joueur), puis traverse sans s'arrêter.
- Chaque véhicule qui arrive est suivi pour estimer sa vitesse.
- Le trou qu'il attend dépend du temps de traversée de son attelage. Après 30 s d'attente, il devient moins exigeant.
- Un véhicule arrêté à côté ou qui attend à sa propre ligne n'est pas compté comme un danger.
- Il ne s'engage pas si la sortie après le croisement est occupée.
- Arrêté au milieu du croisement : il recule tout de suite jusqu'à la ligne.
- « L'intersection prime » : il attend ou il y va, jamais entre deux.

### 10. Ravitaillement et réparation
- Le plein et la réparation automatiques attendent la fin du travail en cours (benne vide, plus au service d'une moissonneuse).
- Jamais repoussé : la demande du joueur ou de Courseplay, un réservoir sous 5 %, des dégâts à 90 % ou plus.

### 11. Textes et affichage
- Textes d'état clairs, en français, de ce que fait chaque véhicule et depuis combien de temps (« Se gare dans le champ », « Poursuit l'ensileuse par derrière », « Calcul du trajet (12 s) », « Laisse passer »…). Environ 60 nouveaux textes.
- Le HUD coupe les lignes longues seulement entre les parties du texte, plus au milieu d'un mot (« Demi-tour »).
- Nouveau canal de débogage « Poursuite (affichage permanent) » : trajets, place visée, traces suivies et place d'écart dessinés en couleur.

### 12. Ajouts du 28 au 31/10
- Règles de circulation sur les chemins à double sens : priorité à celui qui est déjà engagé, croisement prévu de loin, place choisie avec le rayon réel de l'attelage, la remorque articulée et toute la file d'en face. Le texte d'état dit qui il attend.
- Celui qui ne peut pas reculer (véhicule collé derrière, remorque articulée) prend la route d'en face et revient plus tard. Celui du chemin ne recule jamais sans place sûre.
- Rangement dans une courbe : la vraie trace de la remorque est simulée, l'autre n'est libéré que quand tout l'attelage est hors de la route. Objets fixes (garde-corps de pont…) contrôlés sur tout le trajet de rangement.
- Virages trop serrés pour l'attelage : la courbe est vue en entier (même dessinée avec beaucoup de points) et redessinée au rayon réel de l'attelage. Les dalles et bordures au sol ne comptent plus comme obstacles.
- Ensileuse : recul de dégagement quand aucun trajet n'est trouvé (pas de 5 m, 20 m au plus) ; demi-tour de bout de rang contrôlé contre le virage de l'ensileuse, il attend qu'elle soit passée.
- Écart autour d'un objet fixe (cône, poteau, balle) permis pendant un croisement pour celui qui passe, jamais pour celui qui attend.

### 13. Ancien AutoDrive Addon, maintenant intégré
- Pont-bascule : le véhicule centre tout l'attelage dessus, s'arrête 5 s et affiche le produit, le chargement et le poids total, puis repart. Arrêt à la main sur le pont (3 s) : le poids s'affiche aussi. Avec AutoSwitch, chaque pesée va dans son registre.
- Clignotant : avec le « Clignotant automatique », il s'allume avant un virage ou un croisement, du côté du virage. Nouveau réglage « Distance clignotant » (20 à 100 m).
- Coupure moteur : nouveau réglage du temps à l'arrêt avant de couper le moteur (Jamais, 10 s, 30 s, 1, 2 ou 5 min). Moteur coupé : seuls les phares de base restent allumés, tout revient au redémarrage.
- Silo vide : au chargement, si la benne contient déjà quelque chose et que plus rien n'entre pendant 30 s, il repart avec ce qu'il a.
- Outil arrière : au lancement de la partie, chaque tracteur sélectionne l'outil attelé derrière lui.
- Si l'ancien mod FS25_AutoDriveAddon est encore activé, FarmPilot n'active pas ces fonctions une deuxième fois : désactivez l'Addon.

---

## 1.0.0.0 (English)

### From AutoDrive to FarmPilot
- New name, new icon, author bibifr. The AutoDrive credits and licence are kept.
- If you already play with AutoDrive: FarmPilot takes over your road network (the savegame's AutoDrive_config.xml), the modSettings/FS25_AutoDrive folder (saved routes, colours) and the vehicle settings. Nothing to copy.
- New install or new savegame: everything is saved under the FarmPilot name (FarmPilot_config.xml, modSettings/FS25_FarmPilot).
- If AutoDrive is also active, FarmPilot disables it (HUD, keys, driving) and shows a message asking to remove it from the mods.
- Mods that look for AutoDrive (Courseplay, add-ons…) find FarmPilot instead.

### 1. Head-on passing on two-way roads
- Two FarmPilot vehicles meeting nose to nose no longer stay blocked: one pulls over on the roadside, the other reverses, then both carry on.
- The meeting is detected early, by comparing both routes over 250 m: both slow down and stop with a safe gap.
- If one can leave the shared section before the other enters it, it simply goes first.
- The roles (who reverses, who pulls over) are always chosen the same way: the empty vehicle first, then the one without a trailer.
- The roadside spot is computed from the real size of both vehicle combinations (length, width, front and rear implements), and it takes slope, water and fields into account.
- The vehicle pulls over on the traffic side, never against the traffic. A right or left setting covers left-hand-drive maps.
- If nothing works: it reverses along its route, the roles are swapped, or it hides in a branch or dead end of the network.
- After two failures, a red message is shown and the pair pauses for 5 minutes.
- It takes another route (at most 400 m longer) when that avoids the head-on section.
- More than two vehicles: convoys are handled (only the head vehicle negotiates), and so is a third vehicle arriving during the manoeuvre.
- Single-track lane: the vehicle that gives way stops 15 m before the lane entrance, or goes straight on if it does not need the lane.
- The vehicle inside the lane reverses when the other one is stuck, until it is clear of the other's field exit path.
- The vehicle coming out of the lane has priority, and it takes the other lane as soon as it is within 5 m.
- 28/10: the wait lasts as long as the length of the outgoing vehicle combination plus 10 m.
- 28/10: the manoeuvre only ends once the other vehicle is no longer coming toward it.
- 28/10: a blocked reverse (10 s, or 90 s without progress) swaps the roles.
- 28/10: a forage wagon never reverses.
- New settings: head-on passing on/off, delay before passing, maximum reverse, margin between the vehicles, driving side.

### 2. Waiting inside the field (parking)
- An unloader waiting for the call of the combine or forage harvester drives into the field and parks along the border. Before, it blocked the road at the entrance.
- The spot is on harvested, flat ground, away from the roads, at least 40 m from the entrance, parallel to the border, on the side where the harvester works.
- The way to the spot never goes through standing crop.
- The spot is remembered per field in the savegame: the next unloaders go straight there.
- Unloaders park in line, one behind the other, on the same harvested strip.
- Spots leave room to drive away and face the harvester's working direction.
- Unloaders queue in the first narrow strip of a field being opened.
- Full field: an empty unloader waits at the roadside before the entrance and moves up when a spot frees. Without a spot, it backs off 40 m.
- An empty unloader waits before the entrance while a full one drives out through it (120 s at most).
- When the harvester's side has nothing, a last search looks on both sides, farther away and closer to the entrance.
- Unloaders are called in order of arrival.
- No spot at start: the unloader waits at the roadside.
- New setting: "Wait inside the field" (on by default).

### 3. Leaving the field
- To leave the field, the vehicle first aims at the entrance of the field it is on (up to 2000 m). Before, it aimed at the nearest network point, which can be behind the crop or on the neighbouring field.
- If it cannot reach the entrance cleanly, it tries up to 6 other network points, without crossing crop or another field.
- Gates are driven through along their axis: the tractor lines up 12 to 20 m before, then goes straight.
- An empty unloader standing on the exit point: the next point is used.
- The entrance is tried 3 times before moving on to another point.
- The 2nd unloader called that arrives by the entrance parks in the field first, to let the full one out.
- Full unloader: it takes the nearest exit, if no obstacle or other field is in the way.

### 4. Field and crop: "Strict" mode
- "Restrict to field" and "Avoid fruit" get a 3rd value, "Strict": the route calculation never lifts the restriction as a fallback.
- In Strict mode, the field is the field ground connected to the start and to the target: the unloader never drives onto the neighbouring field. Grass along the border stays usable.
- Small forgotten patches of crop are ignored.
- The route calculation refines its grid (6 m, 4.5 m, then 2 m) before any fallback, and rounds the corners to the real turning radius of the tractor.
- Crop is checked along the corridor actually driven by the wheels of the whole vehicle combination.
- Branches above the vehicle combination no longer count as a wall.
- Partial route: when no complete route exists, it drives to the last clean point and plans again from there. A partial route never ends in the crop.
- Guided departure: a stuck vehicle combination (crop around it, corner too sharp) first frees itself with short forward curves.
- A place where a vehicle keeps blocking becomes a forbidden zone for later route calculations. These zones expire after 5 minutes.

### 5. Forage harvester (unloader following the forage harvester)
#### Approach
- The unloader aims at the place behind the forage harvester, on its cut track, then picks the free side itself.
- The place behind follows the track the forage harvester actually drove, also in curves and after its U-turn.
- It no longer drives around a stopped forage harvester the wrong way.
- After arriving twice at the same useless place, it makes a U-turn in the strip or reverses along its own tracks.
- Stopped forage harvester: the unloader goes straight to the pipe.
- Forage harvester coming toward it: the unloader reverses out of its way if the ground behind is free, otherwise it waits.
- After reversing twice for the same forage harvester, it leaves it to another unloader for 2 minutes.
- No route found twice near the stopped forage harvester: the chase takes over, even if it cuts a tip of maize.
- Fine field map (field ground and crop), and routes through the inside of the cut strips without reversing when the grid finds nothing ("drive around the field from the inside").

#### Chase
- The unloader follows the forage harvester on its track and reads the Courseplay course ahead (row end, U-turn, jog).
- It holds the rear place while the forage harvester turns.
- The straight line to the place is checked every half second (obstacle, off field, other field, crop). If it is blocked, the unloader stops and plans a route.
- A side whose place is taken by a fixed obstacle is avoided for a while.
- It waits for a vehicle on its line (60 s at most).
- The grass strip beside the field is accepted.
- 3/4 rear position: it leaves it when the forage harvester stops or the line is blocked, then drives up behind it to 0.5 m from its nose.
- It no longer waits for a stopped forage harvester to pass.
- It closes up behind the forage harvester.
- Courseplay jogs and row ends are driven through instead of being taken for U-turns.

#### Second unloader (follower)
- The 2nd unloader aims at the tracks of the 1st and waits behind it while the 1st is in place.
- To join, it searches in this order: tracks of the 1st, then the maize edge, then the cut strips, then the fine grid, then a straight line.
- While the 1st is not in place, the 2nd waits on a spot in the field, not in the entrance. It also parks there after 2 failed route calculations.
- It steps aside when the forage harvester or the 1st unloader comes back toward it, lets them pass, then comes back into place.

#### U-turns at the end of the row
- The forage harvester's U-turn is read from its Courseplay turn points. The plain "turn" flag no longer starts a U-turn.
- Order of the manoeuvres: forward U-turn, reverse then U-turn, offset U-turn, then a Y manoeuvre when the headland is narrow (Fabien's drawing of 25/10).
- Square manoeuvre, from Fabien's two drawings of 27/10: quarter turn, straight reverse, quarter turn into the new row.
- U-turn inside the cut strip when the headland has no room; the trailer may back into the crop.
- Each manoeuvre is checked before it starts (field ground, crop, obstacles), at the tractor's own turning radius.
- The trailer's track is also checked inside tight curves.

#### Full unloader
- If no forward exit is possible, it reverses along its tracks, pulls aside on harvested ground or grass to let the next one pass, or makes a U-turn in the strip toward the exit.
- Once aside, it follows the cut strip and looks for an exit on the way. The field entrance stays the preferred exit.
- Several full unloaders stuck: the one least hindered by the crop leaves first.
- When reversing along its tracks, it refuses a track that hugs the maize, stops if the trailer touches the crop, and reverses no more than 25 m in a row.

#### Job
- The unloader stays with its forage harvester until it is full, and the queue keeps the order of arrival.
- A short Courseplay stop no longer releases the unloaders. Only a long stop releases them.
- End of the job (also detected through Courseplay): each unloader unloads what it carries, then drives to its park destination.
- The "stuck" safety first lets the unloader free itself (reverse, plan again) before resetting everything.
- The player's "continue" button is told apart from other callers.

### 6. Obstacles on the road ("smart driver")
- Anticipated braking: it looks at the route ahead and slows down progressively before an obstacle, instead of braking hard at the last moment.
- It follows a slower vehicle at its speed and keeps 3 m behind another FarmPilot vehicle.
- Small sidestep: an obstacle on one side only (pole, bale, sign, parked car) is avoided with a slight sideways shift, without stopping.
- AI traffic car stopped nose to nose: it reverses a little, changes lane, then passes.
- Detour: blocked by a fixed object (fallen object, low wall, tree), it reverses, then plans a way around to rejoin its route further on. Otherwise it stays stopped and shows a message.
- A first quick detour attempt is made without reversing.
- A vehicle that has been standing still for a while is also driven around (sooner if nobody is in it).
- In front of a gate, it waits instead of driving around.
- No detour while waiting at a crossing.
- The "stuck" safety tries a detour before restarting.
- New settings: detour on/off, delay before detour, reverse before detour, sidestep light obstacles.

### 7. Wide corners
- Sharp corners of the network are driven on an arc, at the real turning radius of the vehicle combination.
- The tractor swings wide on entry or exit when there is room, and the trailer no longer cuts the inside.
- New setting: "Wide corners".

### 8. Narrow passages
- The route calculation avoids sections too narrow for the vehicle combination (dual wheels, wide implement) when another way exists.
- The width is measured at the tractor's tyres. Foldable implements count as 2.4 m.
- At the start of a route calculation (taking over from Courseplay at a field border), the corridor ahead is checked: it starts closer if there is a tree or a low wall.
- Debug display: a blue frame shows the width used, red frames show the sections refused.

### 9. Intersections (new road type, red points)
- New "Intersection" marking in the editor (Left Shift + click). It is added on top of the normal or sub-priority type.
- Before crossing or joining a road, it slows down (20 then 8 km/h) and watches the lanes over 120 m.
- It stops just before the first red point if a vehicle is coming (AI car, tractor, player), then crosses without stopping.
- Each approaching vehicle is tracked to estimate its speed.
- The gap it waits for depends on how long its vehicle combination takes to cross. After 30 s of waiting, it asks for less.
- A vehicle stopped beside the crossing, or waiting at its own line, does not count as a danger.
- It does not pull out if the exit after the crossing is occupied.
- Stopped in the middle of the crossing: it reverses at once to the line.
- "The intersection comes first": it either waits or goes, never stops halfway.

### 10. Refuel and repair
- Automatic refuel and repair wait until the current job is done (unloader empty, no longer working for a harvester).
- Never postponed: a request by the player or Courseplay, a tank below 5 %, damage of 90 % or more.

### 11. Texts and display
- Clear status texts describe what each vehicle is doing and for how long ("Parks in the field", "Following the forage harvester from behind", "Planning the way (12 s)", "Lets … pass"…). About 60 new texts.
- The HUD splits long lines only between parts of the text, no longer in the middle of a word ("Demi-tour").
- New debug channel "Chase (permanent display)": routes, target place, followed tracks and step-aside place drawn in colour.

### 12. Additions from 28/10 to 31/10
- Traffic rules on two-way tracks: priority to the vehicle already on the track, passing planned from far away, passing place chosen with the real turning radius of the combination, articulated trailers and the whole queue coming the other way. The status text says who it is waiting for.
- A vehicle that cannot reverse (vehicle right behind, articulated trailer) takes the road ahead and comes back later. The vehicle on the track never reverses without a safe place.
- Pulling over in a bend: the real trailer path is simulated, and the other vehicle is released only once the whole combination is off the road. Fixed objects (bridge railings…) are checked along the whole pull-over path.
- Corners too tight for the combination: the whole bend is detected (even when drawn with many points) and redrawn at the real radius of the combination. Flat slabs and kerbs no longer count as obstacles.
- Forage harvester: backing out when no path is found (5 m steps, 20 m max); headland turn checked against the harvester's own turn, it waits until the harvester has passed.
- Driving around a fixed object (cone, post, bale) is allowed during a head-on passing for the vehicle that drives on, never for the one that waits.

### 13. Former AutoDrive Addon, now built in
- Weighbridge: the vehicle centres the whole combination on it, stops for 5 s and shows the product, the load and the total weight, then drives on. Stopping on it yourself (3 s) shows the weight too. With AutoSwitch, each weighing goes to its register.
- Turn lights: with "Turnlight Automatic", the turn light comes on before a turn or a crossing, on the side of the turn. New "Turnlight Distance" setting (20 to 100 m).
- Engine stop: new setting for the time stopped before the engine is turned off (Never, 10 s, 30 s, 1, 2 or 5 min). Engine off: only the low beams stay on, everything comes back on restart.
- Empty silo: at the loading point, if the trailer already holds something and nothing more comes in for 30 s, it leaves with what it has.
- Rear implement: at game start, each tractor selects the implement attached at its rear.
- If the old FS25_AutoDriveAddon mod is still active, FarmPilot does not run these functions a second time: disable the Addon.
