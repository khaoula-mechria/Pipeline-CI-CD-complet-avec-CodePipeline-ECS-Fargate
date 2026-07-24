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
- **`infrastructure/cloudformation/vpc.yml`** — VPC 2 AZ, 2 subnets publics +
  2 privés, Internet Gateway, NAT Gateway(s) (stratégie `single`/`ha`
  paramétrable), VPC Endpoint Gateway S3, Flow Logs optionnels. Validé via
  `infrastructure/scripts/test3-vpc.sh` (cfn-lint + LocalStack) : VPC,
  subnets, Internet Gateway, route tables et VPC Endpoint S3 se créent tous
  correctement. Le NAT Gateway ne peut pas être validé en local — limite
  LocalStack Community documentée ci-dessous, pas un problème du template.

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

- `cfn-lint` sur `ecr.yaml`, `codebuild.yaml` et `vpc.yml` → passent sans erreur.
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
- `test3-vpc.sh` exécuté de bout en bout (LocalStack Community, exit code 0) :
  VPC + 4 subnets (2 publics/2 privés, bonnes CIDR/AZ) + Internet Gateway +
  4 route tables (1 principale implicite + 1 publique + 2 privées) + VPC
  Endpoint S3 confirmés créés via `aws ec2 describe-*`. Le déploiement
  échoue ensuite sur `NatGateway1` (`InvalidAllocationID.NotFound`) : l'EIP
  associée est acceptée par CloudFormation mais LocalStack Community ne
  l'émule pas réellement côté EC2 (`describe-addresses` renvoie une liste
  vide, `AllocationId` reste `"unknown"`) — confirmé empiriquement, ce n'est
  pas un défaut du template `vpc.yml`. Les outputs de la stack ne sont donc
  pas disponibles en local (stack jamais `CREATE_COMPLETE`).

### Bugs corrigés en cours de route

- `package.json` (racine) : clés `scripts`/`devDependencies` dupliquées
  (modif non commitée) → restauré à la version propre.
- `task-manager/dokerfile` (faute de frappe) → renommé `Dockerfile`.
- `task-manager/tests/health.test.js  ` (fichier fantôme, espaces en fin de
  nom, brouillon redondant) → supprimé.
- `task-manager/` sans `package.json`/`package-lock.json` propre → ajoutés
  (sans quoi `docker build` échouait dès `npm ci`).
- `.gitignore` : ajout de `node_modules/` (absent auparavant).
- `test3-vpc.sh` (ajouté par l'utilisateur avec `vpc.yml`) : chemin du
  template pointait vers `vpc.yaml` (inexistant, le fichier réel est
  `vpc.yml`) → corrigé. Démarrage LocalStack fragile (image `latest` non
  épinglée, simple `sleep 8` sans attente active) → aligné sur le pattern
  robuste de `test-local.sh` (image `3.8.1` épinglée déjà en cache,
  attente active sur `/_localstack/health`, services `ec2,iam,logs,
  cloudformation` explicites). Déploiement + étapes de vérification
  faisaient échouer tout le script à la première erreur (le NAT Gateway
  échoue toujours en local, cf. ci-dessus) → rendu non bloquant, avec
  récupération du `VpcId` via tag EC2 plutôt que les Outputs (indisponibles
  tant que la stack n'est pas `CREATE_COMPLETE`) et suppression automatique
  d'une éventuelle stack `CREATE_FAILED` d'un run précédent avant de
  redéployer.

## Pas encore fait

- **`infrastructure/cloudformation/iam.yml`** — vide (placeholder). À noter :
  ce fichier apparaît actuellement comme supprimé côté git avec un nouveau
  fichier non suivi `iam.yaml` à la place (même contenu vide) — probablement
  un renommage fait hors de git ailleurs ; à vérifier/`git add`/`git rm` en
  conséquence avant de commencer à le remplir.
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

## Prochaine étape

Ordre de dépendance logique de ce qui reste : **IAM (`iam.yml`/`.yaml`)
avant `pipeline.yml`**, car CodePipeline et les tâches ECS Fargate ont
besoin de rôles IAM (task execution role, task role, rôle CodePipeline) qui
n'existent pas encore. Une fois l'IAM en place, `pipeline.yml` peut
importer les exports de `vpc.yml` (subnets, VPC id), `ecr.yaml` (repo) et
`codebuild.yaml` (projet build) pour assembler CodePipeline + le service
ECS Fargate (+ ALB si pas déjà prévu ailleurs).

## Historique des mises à jour de ce fichier

- 2026-07-23 — création initiale, après l'ajout du Test 2 (CodeBuild local).
- 2026-07-23 — ajout et validation du Test 3 (`vpc.yml` + `test3-vpc.sh`) :
  bugs corrigés dans le script de test (chemin de fichier, démarrage
  LocalStack, non-blocage sur l'échec attendu du NAT Gateway) ; `vpc.yml`
  lui-même n'a nécessité aucune correction.
