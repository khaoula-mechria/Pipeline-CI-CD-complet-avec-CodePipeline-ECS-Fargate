# État d'avancement du projet

> Ce fichier est mis à jour à chaque modification notable du projet. Il sert
> de point d'entrée rapide pour savoir ce qui est fait, testé, et ce qui
> reste à faire — sans avoir à relire tout l'historique git.

Objectif du projet : pipeline CI/CD complet (GitHub → CodeBuild → ECR →
CodePipeline → ECS Fargate) pour l'application Node.js `task-manager`.

## Fait et testé

### Infrastructure (CloudFormation)

- **`infrastructure/cloudformation/ecr.yaml`** — repository ECR privé, scan on
  push activé, lifecycle policy (10 dernières images). Validé sans accès AWS
  via `infrastructure/scripts/test-local.sh` (cfn-lint + LocalStack) — voir
  **Test 1** dans `infrastructure/scripts/README-tests-locaux.md`.
- **`infrastructure/cloudformation/codebuild.yaml`** — projet CodeBuild lié au
  dépôt GitHub (webhook sur push `main`/`develop`), rôle IAM à privilège
  minimal restreint au repo ECR importé depuis `ecr.yaml`. Validé sans accès
  AWS via `infrastructure/scripts/test2-codebuild.sh` — voir **Test 2** dans
  le même README.

### Application (`task-manager/`, Node.js/Express)

- `src/app.js` + `server.js` — API minimale (`/health`, `/api/tasks`).
- `tests/health.test.js` — tests unitaires (Jest + Supertest), 100% de
  couverture sur `app.js`.
- `Dockerfile` — build multi-stage (< 200 Mo), image de prod sans
  devDependencies, exécution en utilisateur non-root, `HEALTHCHECK` intégré.
- `buildspec.yml` — phases install (npm ci + SAST Semgrep) → pre_build (login
  ECR) → build (docker build) → post_build (tests + seuil de couverture 80% +
  push ECR).
- `package.json` / `package-lock.json` propres à `task-manager/` (app
  autonome, cohérente avec le futur repo GitHub dédié pointé par
  `GitHubRepoUrl` dans `codebuild.yaml`).

### Tests locaux exécutés et confirmés (sans accès AWS)

- `cfn-lint` sur `ecr.yaml` et `codebuild.yaml` → passent sans erreur.
- `npm ci` + `npm test` → 2 tests unitaires passent, 100% de couverture.
- `docker build` + `docker run` + `curl /health` → image construite,
  conteneur répond `200 {"status":"ok"}`.
- Rejeu partiel de `buildspec.yml` via l'agent officiel
  `aws-codebuild-docker-images` : la phase `install` s'exécute réellement ;
  le blocage attendu à la connexion ECR (`pre_build`, pas de credentials AWS
  réelles) n'a pas encore été observé jusqu'au bout dans cet environnement
  (pull de l'image CodeBuild trop lent, abandonné après 21 min à 22/54
  layers) — le comportement est documenté par raisonnement technique
  (comportement standard d'`aws ecr get-login-password` sans credentials),
  pas encore vérifié empiriquement ici.

### Bugs corrigés en cours de route

- `package.json` (racine) : clés `scripts`/`devDependencies` dupliquées
  (modif non commitée) → restauré à la version propre.
- `task-manager/dokerfile` (faute de frappe) → renommé `Dockerfile`.
- `task-manager/tests/health.test.js  ` (fichier fantôme, espaces en fin de
  nom, brouillon redondant) → supprimé.
- `task-manager/` sans `package.json`/`package-lock.json` propre → ajoutés
  (sans quoi `docker build` échouait dès `npm ci`).
- `.gitignore` : ajout de `node_modules/` (absent auparavant).

## Pas encore fait

- **`infrastructure/cloudformation/vpc.yml`** — vide (placeholder).
- **`infrastructure/cloudformation/iam.yml`** — vide (placeholder).
- **`infrastructure/cloudformation/pipeline.yml`** — vide (placeholder,
  CodePipeline + déploiement ECS Fargate).
- Déploiement réel sur AWS (aucun accès AWS pour l'instant) : import du token
  GitHub (`aws codebuild import-source-credentials`), déploiement réel de
  `ecr.yaml` puis `codebuild.yaml`, vérification que le build va bien
  jusqu'au push ECR — voir la sous-section "Passage à AWS réel" du Test 2
  dans `infrastructure/scripts/README-tests-locaux.md`.
- Fichier fantôme connu mais non traité : `task-manager/ server.js` (avec un
  espace en début de nom, vide, tracké dans git) — doublon de
  `task-manager/server.js`, à nettoyer un jour.

## Historique des mises à jour de ce fichier

- 2026-07-23 — création initiale, après l'ajout du Test 2 (CodeBuild local).
