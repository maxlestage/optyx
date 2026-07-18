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
  vidéo, capture photo plein format enregistrée dans Photos.
- **Studio** — import d'une photo de la photothèque, choix de l'objectif,
  réglage d'intensité, comparaison avec l'original (appui long), export.
- **Objectifs** — catalogue avec l'histoire de chaque objectif, sa signature
  optique détaillée et un aperçu de bokeh simulé sur une scène de test.

## Comment sont simulés les « défauts » optiques

Le moteur (`LensEngine`) enchaîne des filtres Core Image, chacun pilotant un
défaut caractéristique, dosé par le profil de l'objectif :

- **Bokeh tourbillonnant** — moyenne de copies de l'image légèrement pivotées
  autour du centre (flou tangentiel croissant avec le rayon), masquée pour
  préserver le centre net.
- **Bulles de savon** — seuillage des hautes lumières, dilatation morphologique
  en disques puis extraction du contour, incrusté en mode écran.
- **Glow / halation** — bloom sur les hautes lumières.
- **Aberration chromatique** — dilatation/contraction différentielle des
  canaux rouge et bleu autour du centre.
- **Verre au thorium** — dérive de température de couleur vers le jaune doré.
- **Voile vintage** — noirs levés, contraste et saturation réduits.
- **Vignettage, douceur de bords, grain** — filtres dédiés dosés par profil.

## Lancer le projet

1. Ouvrir `Optyx.xcodeproj` dans **Xcode 16+**.
2. Sélectionner un iPhone (iOS 17+) — la caméra nécessite un appareil réel ;
   dans le simulateur, les onglets **Studio** et **Objectifs** restent
   pleinement fonctionnels.
3. Build & Run.

Aucune dépendance externe : uniquement SwiftUI, Core Image, AVFoundation et
PhotosUI.
