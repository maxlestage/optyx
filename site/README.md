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

Les données des objectifs (`src/lenses.js`) sont le miroir du catalogue
de l'app (`Optyx/Models/LensProfile.swift`) — toute évolution du
catalogue doit être répercutée ici.
