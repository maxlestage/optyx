# Site vitrine d'Optyx

Site React mobile-first présentant les 9 objectifs vintage.
Aucune image à charger : les scènes bokeh sont générées en CSS/SVG et
en WebGL (React Three Fiber).

## Développement

```bash
cd site
npm install
npm run dev        # http://localhost:5173
```

## Production

```bash
npm run build      # sortie statique dans site/dist/
```

`base: './'` : le dossier `dist/` se déploie tel quel sur n'importe quel
hébergement statique (GitHub Pages, Netlify, Vercel, nginx…).

## Déploiement Heroku

Trois voies, les deux premières faisables entièrement depuis un
téléphone :

**1. Bouton « Deploy to Heroku » (conteneur, recommandé).** Ouvrir :

> https://heroku.com/deploy?template=https://github.com/maxlestage/optyx

`app.json` (stack `container`) + `heroku.yml` + `Dockerfile` font tout :
Heroku construit l'image et démarre le site. Aucune CLI.

**2. Tableau de bord (buildpack Node).** App existante connectée au
dépôt GitHub → onglet Deploy → « Deploy Branch » (`master`). Le
`package.json` racine (`heroku-postbuild` construit le site) et le
`Procfile` (`web: node site/server.mjs`) sont détectés automatiquement.
Activer « Automatic Deploys » pour redéployer à chaque merge.

**3. CLI (conteneur), depuis un ordinateur :**

```bash
heroku create optyx-site
heroku stack:set container -a optyx-site
git push heroku master
```

Test local de l'image :

```bash
docker build -t optyx-site .
docker run -p 8080:8080 optyx-site  # http://localhost:8080
```

Les données des objectifs vivent dans `src/lenses.js` : c'est la source
unique du catalogue (fiches, scènes 3D, caractéristiques). Elles étaient
autrefois le miroir du catalogue de l'app iOS, retirée du dépôt.
