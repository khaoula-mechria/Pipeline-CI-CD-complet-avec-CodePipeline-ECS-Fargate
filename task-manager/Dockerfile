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

# Ne réinstaller que les dépendances de production
COPY package*.json ./
RUN npm ci --omit=dev

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
