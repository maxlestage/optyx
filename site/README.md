# Site vitrine d'Optyx

Site React mobile-first présentant les 9 objectifs simulés par l'app.
Aucune image à charger : les scènes bokeh sont générées en CSS/SVG,
dans l'esthétique des visuels App Store (`marketing/appstore/`).

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

## Déploiement Heroku (conteneur)

Le `Dockerfile` à la racine du dépôt construit le site puis le sert via
`server.mjs` (serveur statique sans dépendance, à l'écoute sur le
`$PORT` fourni par Heroku). Le `heroku.yml` déclare ce Dockerfile comme
processus `web`. Mise en place, une seule fois :

```bash
heroku create optyx-site            # ou votre nom d'app
heroku stack:set container -a optyx-site
git push heroku master              # build l'image et démarre le site
```

Chaque `git push heroku master` reconstruit et redéploie. Test local de
l'image :

```bash
docker build -t optyx-site .
docker run -p 8080:8080 optyx-site  # http://localhost:8080
```

Les données des objectifs (`src/lenses.js`) sont le miroir du catalogue
de l'app (`Optyx/Models/LensProfile.swift`) — toute évolution du
catalogue doit être répercutée ici.
