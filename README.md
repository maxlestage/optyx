# Optyx 📷

Application iOS native (SwiftUI + Core Image + AVFoundation) qui simule le rendu
des objectifs photo vintage les plus recherchés — directement dans le viseur ou
sur vos photos existantes.

## Objectifs simulés

| Objectif | Signature |
|---|---|
| **Helios 44-2** 58 mm f/2 | Bokeh tourbillonnant culte (URSS, M42) |
| **Zeiss Biotar** 58 mm f/2 | L'original allemand, tourbillon plus doux |
| **Meyer-Optik Görlitz Trioplan** 100 mm f/2.8 | Bokeh « bulles de savon » |
| **Leica Summicron** 50 mm f/2 | Micro-contraste, rendu précis mais organique |
| **Leica Noctilux** 50 mm f/1 | Glow onirique, vignettage massif |
| **Canon « Dream Lens »** 50 mm f/0.95 | Voile de rêve, halos généreux |
| **Pentax Super Takumar** 50 mm f/1.4 | Chaleur dorée du verre au thorium |
| **Noct-Nikkor** 58 mm f/1.2 | Conçu pour la nuit, coma maîtrisé |
| **Angénieux Cinéma** 25–250 mm | Look ciné : contraste doux, grain |

## Fonctionnalités

- **Caméra** — viseur temps réel avec le rendu de l'objectif appliqué au flux
  vidéo, capture photo plein format enregistrée dans Photos. Affichage
  **Metal** (`MTKView`) : la chaîne de filtres est exécutée une seule fois par
  trame dans un pixel buffer, la boucle d'affichage ne fait que recopier la
  texture — aucun aller-retour CPU par image. Le viseur rend en pleine
  qualité, identique à la photo capturée.
- **Vidéo** — mode vidéo avec la simulation appliquée en direct : les trames
  déjà rendues pour le viseur alimentent un `AVAssetWriter` (HEVC .mov,
  1440 px, audio micro en AAC) sans aucun rendu supplémentaire. Chronomètre
  à l'écran, fichier enregistré dans Photos. Sans accès micro, la vidéo est
  muette. Pastille **24 i/s** : mode cinéma qui cale le capteur sur
  24 images par seconde pour le rendu de mouvement film ; la cadence
  automatique revient dès qu'on repasse en photo ou qu'on désactive la
  pastille. Pastille **2.39:1** : letterbox CinemaScope — le flux est
  recadré au format large, gravé dans le fichier, avec les bandes noires
  visibles en direct dans le viseur. Pastille **4K** : enregistrement à
  3840 px de plus grand côté avec **stabilisation cinématique**, pour tous
  les profils d'objectifs (1440 px et stabilisation désactivée sinon).
  Pastille **HDR** : capture 10 bits et encodage HEVC Main10 en HLG
  BT.2020 (lu comme HDR par Photos ; le Dolby Vision proprement dit est
  réservé au pipeline de capture natif d'Apple). Audio AAC **stéréo
  48 kHz 192 kbit/s** quand le matériel le permet, débit vidéo explicite
  (~0,15 bit/pixel/s, majoré en HDR).
- **Toutes les orientations** — l'app suit la rotation du téléphone
  (portrait, paysage, retourné) : viseur, profondeur, photos et vidéos
  s'orientent correctement ; l'orientation est verrouillée pendant un
  enregistrement vidéo (les dimensions du fichier ne peuvent pas changer
  en cours de route).
- **Contrôles de prise de vue** — bascule caméra arrière ↔ frontale
  (TrueDepth : la profondeur reste disponible en selfie), **zoom par
  pincement** (pastille tap-pour-revenir-à-1×), verrouillage
  **AE/AF** (exposition + mise au point), **retardateur 3 s / 5 s / 10 s**
  (pastille cyclique, compte à rebours plein écran, un tap sur le
  déclencheur annule ; différé aussi pour lancer une vidéo, jamais pour
  l'arrêter), **mode rafale** (8 captures pleine qualité enchaînées —
  rendu vintage, EXIF et profondeur pour chaque vue ; compteur sur la
  pastille, un tap sur le déclencheur interrompt ; RAW ignoré pendant la
  rafale pour tenir la cadence).
- **Formats de fichier** — menu partagé caméra/Studio (mémorisé) :
  **HEIC** (défaut, moderne et léger), **JPEG** (universel), **PNG** et
  **TIFF** (sans perte). L'EXIF est préservé dans tous les formats ; la
  carte de profondeur embarquée n'existe qu'en HEIC et JPEG (limite des
  conteneurs) ; le DNG ProRAW reste géré par la pastille RAW.
- **Formats photo** — menu de cadrage dans le viseur : **4:3** natif,
  **3:2** (film 135), **1:1** (6×6 moyen format), **16:9** et **65:24**
  (panoramique XPan). Recadrage centré appliqué **avant** la chaîne de
  filtres — le vignettage et les masques épousent le cadre choisi — et
  visible en direct ; le masque de profondeur est recadré à l'identique.
  En mode RAW, le DNG conserve le plein cadre du capteur.
- **Histogramme temps réel** — histogramme RVB superposé dans le viseur,
  calculé sur le **rendu vintage affiché** (pas la scène brute) via
  `CIAreaHistogram` à cadence réduite ; pastille pour le masquer.
- **Zébras, focus peaking & grille des tiers** — pastilles dédiées :
  hachures diagonales sur les zones surexposées (luminance ≥ 95 %),
  surlignage vert des contours nets pour caler la mise au point, et grille
  des tiers alignée sur l'image rendue (letterbox compris). Aides
  affichées dans le viseur uniquement — jamais gravées dans les photos ni
  les vidéos.
- **Métadonnées photographe** — la photo vintage est exportée en HEIC avec
  **tout l'EXIF de la capture d'origine** (exposition, ISO, focale réelle,
  GPS…), la **carte de profondeur LiDAR / double objectif embarquée** en
  donnée auxiliaire (la photo reste ré-éditable avec sa profondeur, y
  compris dans le Studio), la **distance au sujet** mesurée sur la carte de
  profondeur inscrite dans `SubjectDistance` / `SubjectDistRange` (l'info
  de profondeur de champ), et l'objectif simulé consigné dans `LensModel`
  et `UserComment`. Les exports du Studio recopient de même l'EXIF et les
  cartes auxiliaires du fichier importé.
- **Profondeur en direct** — sur les iPhone à LiDAR ou double capteur, la
  carte de profondeur est capturée en continu (`AVCaptureDepthDataOutput`
  synchronisée avec la vidéo) : dans le viseur comme sur la photo capturée,
  le bokeh vintage ne s'applique qu'à l'arrière-plan réel, le sujet reste
  net. Pastille « Profondeur » pour revenir au masque radial.
- **RAW / Apple ProRAW** — bouton RAW dans le viseur : la capture enregistre
  le DNG original (ProRAW sur iPhone 12 Pro et ultérieurs, RAW Bayer sinon)
  joint en ressource alternative à la photo vintage. Le RAW conserve les
  données brutes du capteur — le rendu vintage est « développé » à côté, jamais
  détruit dans le fichier RAW.
- **Studio** — import d'une photo de la photothèque (y compris fichiers
  RAW/DNG, développés via `CIRAWFilter`), choix de l'objectif, réglage
  d'intensité, comparaison avec l'original (appui long), export.
- **Profondeur (photos Portrait)** — si la photo importée embarque un matte
  « effets portrait » ou une carte de disparité/profondeur, le bokeh vintage
  (tourbillon, douceur, bulles) suit l'arrière-plan réel de la scène au lieu
  du masque radial : le sujet reste net, seul le fond tourbillonne.
  Désactivable d'un interrupteur dans le Studio.
- **Objectifs** — catalogue avec l'histoire de chaque objectif, sa signature
  optique détaillée et un aperçu de bokeh simulé sur une scène de test.

## Comment sont simulés les « défauts » optiques

Le moteur (`LensEngine`) enchaîne des filtres Core Image, chacun pilotant un
défaut caractéristique, dosé par le profil de l'objectif :

- **Bokeh tourbillonnant** — moyenne de copies de l'image légèrement pivotées
  autour du centre (flou tangentiel croissant avec le rayon), masquée pour
  préserver le centre net. Avec une carte de profondeur, l'amplitude du
  tourbillon est graduée sur trois bandes de distance : discret juste
  derrière le sujet, maximal au loin.
- **Bulles de savon** — seuillage des hautes lumières, dilatation morphologique
  en disques puis extraction du contour, incrusté en mode écran. Avec une
  carte de profondeur, trois couches de bulles (petites, moyennes, larges)
  sont réparties en bandes de distance : le diamètre des anneaux croît avec
  l'éloignement du plan de netteté, comme sur un vrai objectif.
- **Glow / halation** — bloom sur les hautes lumières ; avec une carte de
  profondeur, atténué sur le sujet et plein sur l'arrière-plan.
- **Aberration chromatique** — dilatation/contraction différentielle des
  canaux rouge et bleu autour du centre ; avec une carte de profondeur, le
  décalage des franges est mis à l'échelle par bande de distance.
- **Vignettage** — assombrissement des coins ; avec une carte de profondeur,
  le sujet n'est que partiellement assombri.
- **Verre au thorium** — dérive de température de couleur vers le jaune doré.
- **Voile vintage** — noirs levés, contraste et saturation réduits.
- **Douceur de bords, grain** — filtres dédiés dosés par profil.

## Lancer le projet

1. Ouvrir `Optyx.xcodeproj` dans **Xcode 16+**.
2. Sélectionner un iPhone (iOS 17+) — la caméra nécessite un appareil réel ;
   dans le simulateur, les onglets **Studio** et **Objectifs** restent
   pleinement fonctionnels.
3. Build & Run.

Aucune dépendance externe : uniquement SwiftUI, Core Image, AVFoundation et
PhotosUI.
