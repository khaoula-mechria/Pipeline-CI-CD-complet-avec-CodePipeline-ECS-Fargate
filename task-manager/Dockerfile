# ==============================================================================
# Dockerfile multi-stage pour l'application Node.js "task manager"
# Objectif : image finale < 200 Mo (critère cité dans la doc d'architecture)
# ==============================================================================

# ---------- STAGE 1 : build ----------
# Contient les devDependencies (nécessaires seulement pour installer/compiler),
# ce stage n'est PAS présent dans l'image finale.
FROM node:20-alpine AS build

WORKDIR /app

# Copier uniquement les manifests d'abord -> le cache Docker des layers
# n'est invalidé que si package.json change, pas à chaque changement de code.
COPY package*.json ./
RUN npm ci

# Copier le reste du code source
COPY . .

# Si l'app a un build step (TypeScript, bundler...), décommenter :
# RUN npm run build


# ---------- STAGE 2 : production ----------
# Image finale minimale : uniquement le runtime Node + les dépendances de
# production (pas de devDependencies, pas d'outils de build).
FROM node:20-alpine AS production

WORKDIR /app
ENV NODE_ENV=production

# Applique les correctifs déjà disponibles dans les dépôts Alpine pour les
# paquets OS (ex. openssl) sans attendre qu'une nouvelle version de l'image
# de base node:20-alpine soit publiée en amont.
RUN apk upgrade --no-cache

# Ne réinstaller que les dépendances de production, puis supprimer npm/npx/
# corepack : ce sont des outils de build (jamais invoqués en production, le
# conteneur ne fait que "node server.js"), mais leurs propres dépendances
# embarquées (glob, minimatch, tar, etc., globalement installées sous
# /usr/local/lib/node_modules/) sont scannées comme du code applicatif et
# faisaient remonter des CVE (dont une CRITICAL) qui n'ont jamais été
# exécutables ici. Les supprimer élimine ces findings sans toucher aux
# dépendances réelles de l'application (task-manager/package.json), qui
# restent, elles, intactes et scannées normalement.
COPY package*.json ./
RUN npm ci --omit=dev \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
              /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack

# Récupérer uniquement le code applicatif depuis le stage "build"
# (adapter le chemin "src"/"dist" selon la structure réelle du projet)
COPY --from=build /app/src ./src
COPY --from=build /app/server.js ./server.js

# Bonne pratique sécurité : ne pas exécuter le process en root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 3000

# Healthcheck utilisé par ECS pour valider que le conteneur répond
# (cohérent avec les "health checks" du déploiement Blue/Green)
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1

CMD ["node", "server.js"]
