# Optyx 📷

Site vitrine des neuf objectifs photo vintage les plus recherchés, avec pour
chacun son histoire, ses caractéristiques optiques et une scène de bokeh
rendue en direct dans le navigateur (React Three Fiber).

En ligne : **https://optyx-d758dfd33137.herokuapp.com** ·
miroir GitHub Pages : **https://maxlestage.github.io/optyx/**

## Objectifs présentés

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

Chaque fiche donne la formule optique, le nombre de lamelles de diaphragme,
la distance de mise au point minimale, la cote en occasion, ainsi que des
anecdotes de fabrication.

## Le rendu de bokeh

Le héros de la page est une scène **React Three Fiber** avec un shader GLSL
écrit pour l'occasion : chaque point lumineux est un disque dont on contrôle
l'anneau de bord (les « bulles de savon » du Trioplan), la déformation en œil
de chat vers les bords du champ, la frange chromatique et les aigrettes de
diffraction. Les paramètres viennent du catalogue (`site/src/lenses.js`), un
jeu par objectif.

## Développement

```bash
cd site
npm install
npm run dev        # http://localhost:5173
npm run build      # sortie statique dans site/dist/
```

`base: './'` dans la configuration Vite : le dossier `dist/` se déploie tel
quel sur n'importe quel hébergement statique.

## Déploiement

- **Heroku** — `app.json` (stack `container`) + `heroku.yml` + `Dockerfile`,
  ou le buildpack Node via le `package.json` racine et le `Procfile`. Détails
  dans [`site/README.md`](site/README.md).
- **GitHub Pages** — workflow `deploy-site.yml`, publication sur la branche
  `gh-pages`.

## Historique

Ce dépôt hébergeait aussi **Optyx**, une application iOS native (SwiftUI +
Core Image + AVFoundation) qui appliquait ces mêmes signatures optiques au
flux de la caméra en temps réel. Le code a été retiré du dépôt ; il reste
consultable dans l'historique Git, jusqu'au commit qui précède sa
suppression.
