# Site vitrine Optyx (site/) — image conteneur pour Heroku ou tout
# hébergeur Docker. Deux étapes : build Vite, puis service statique par
# un serveur Node sans dépendance qui écoute sur $PORT (imposé par
# Heroku au démarrage du dyno).

FROM node:22-alpine AS build
WORKDIR /app
COPY site/package.json site/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY site/ ./
RUN npm run build

FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY site/server.mjs ./server.mjs
# Valeur locale par défaut ; Heroku la remplace par son propre $PORT.
ENV PORT=8080
EXPOSE 8080
USER node
CMD ["node", "server.mjs"]
