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
  texture — aucun aller-retour CPU par image. Le viseur utilise un mode
  aperçu allégé (4 rotations de tourbillon au lieu de 6, 2 bandes de
  profondeur au lieu de 3) ; la capture garde la qualité maximale.
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
