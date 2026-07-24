# Tester l'infrastructure sans accès AWS

> **Pour tout valider d'un coup** : `./test7-all-local.sh` enchaîne les 6
> tests (`test-local.sh`, `test2-codebuild.sh`, `test3-vpc.sh`,
> `test4-iam.sh`, `test5-pipeline.sh`, `test6-observability.sh`) dans le bon
> ordre et affiche un rapport récapitulatif (statut + durée) à la fin —
> ~10 min. Voir [`testing-output.md`](testing-output.md) pour le résultat
> détaillé de chaque test, y compris ce qui n'est pas vérifiable en local
> et pourquoi.

Deux niveaux de test, du plus léger au plus complet.

## Niveau 1 — cfn-lint (recommandé au quotidien)

Valide la syntaxe et les bonnes pratiques CloudFormation, sans jamais
contacter AWS. C'est le test à lancer à chaque modification du template.

```bash
pip install cfn-lint
cfn-lint infrastructure/cloudformation/ecr.yaml
```

Aucune sortie = template valide. Il détecte aussi les erreurs de logique
(ex: référence à un paramètre qui n'existe pas, type de ressource mal
orthographié, propriété manquante obligatoire).

## Niveau 2 — LocalStack (simulation complète)

LocalStack fait tourner une fausse API AWS dans Docker, sur ta machine.
Tu peux réellement déployer la stack et créer "un vrai" repository ECR
(local, pas sur AWS), vérifier les outputs — exactement comme tu le
ferais en prod, mais gratuit et sans compte AWS.

Prérequis :

```bash
pip install cfn-lint awscli-local
```

Docker doit être installé et lancé. Pas besoin de démarrer LocalStack
à la main : le script s'en charge (voir ci-dessous).

```bash
cd infrastructure/scripts
chmod +x test-local.sh
./test-local.sh
```

Le script `test-local.sh` exécute, dans l'ordre :

1. **cfn-lint** sur `../cloudformation/ecr.yaml` — arrête tout de suite
   si le template est syntaxiquement invalide.
2. **Démarrage de LocalStack** — si un conteneur nommé `localstack`
   tourne déjà, il est réutilisé ; sinon le script lance
   `localstack/localstack:3.8.1` (services `ecr` + `cloudformation`
   sur le port 4566) et attend jusqu'à 60s (30 tentatives, 2s
   d'intervalle) que `/_localstack/health` réponde.
3. **`aws cloudformation validate-template`** contre l'endpoint
   LocalStack, pour vérifier que le template est bien formé du point
   de vue de l'API CloudFormation.
4. **Déploiement de la stack** (`aws cloudformation deploy`) sous le
   nom `taskmanager-ecr-test`, avec les paramètres
   `ProjectName=taskmanager Environment=dev`.
5. **`aws ecr describe-repositories`** pour confirmer que le
   repository a bien été créé par la stack.
6. **`aws cloudformation describe-stacks`** pour afficher les outputs
   de la stack (`RepositoryUri`, `RepositoryArn`, `RepositoryName`).

Les identifiants AWS factices (`AWS_ACCESS_KEY_ID=test`,
`AWS_SECRET_ACCESS_KEY=test`, région `eu-west-1`) sont exportés
directement par le script — LocalStack ne vérifie pas leur validité,
mais l'AWS CLI exige qu'ils soient présents.

Limite à connaître : la version communautaire (gratuite) de LocalStack
simule bien la création du repository, le scan on push et les policies,
mais l'exécution réelle du scan de vulnérabilités CVE n'est pas simulée
(c'est un service backend AWS propriétaire). Pour valider cette partie
précise, il faudra le vrai accès AWS — mais tout le reste (structure du
template, paramètres, outputs, lifecycle policy) est testable dès
maintenant.

## Niveau 3 — le vrai déploiement (dès que l'accès AWS arrive)

```bash
aws cloudformation deploy \
  --template-file infrastructure/cloudformation/ecr.yaml \
  --stack-name taskmanager-ecr-dev \
  --parameter-overrides ProjectName=taskmanager Environment=dev
```

Puis vérifier dans la console AWS → ECR → repositories, que :
- le repo apparaît en "Private"
- "Scan on push" est bien "Enabled"
- l'onglet "Lifecycle policy" affiche la règle "Garder uniquement les 10
  dernières images"

---

# Test 2 — Valider CodeBuild et buildspec.yml (sans accès AWS)

Deuxième volet : tester la partie build applicatif (`codebuild.yaml` +
`task-manager/buildspec.yml`), toujours sans compte AWS. Fichiers concernés :

- `infrastructure/cloudformation/codebuild.yaml` — le projet CodeBuild
- `task-manager/buildspec.yml` — les phases install/pre_build/build/post_build
- `task-manager/Dockerfile` — build multi-stage de l'image (< 200 Mo)
- `task-manager/jest.config.js` — configuration Jest (coverage, reporter JUnit)
- `task-manager/tests/health.test.js` — tests unitaires (healthcheck + `/api/tasks`)
- `task-manager/package.json` / `package-lock.json` — dépendances de l'app,
  autonomes dans `task-manager/` (voir note en bas de section)

Comme pour le Test 1, tout se lance avec un seul script :

```bash
cd infrastructure/scripts
chmod +x test2-codebuild.sh
./test2-codebuild.sh
```

Le script exécute, dans l'ordre :

## Niveau 0 — cfn-lint

```bash
cfn-lint infrastructure/cloudformation/codebuild.yaml
```

Passe sans erreur, exactement comme `ecr.yaml` (voir Test 1).

## Niveau 1 — vérifier chaque étape manuellement (le plus simple)

```bash
npm ci
npm test                    # doit passer avant de continuer
docker build -t taskmanager:test task-manager
docker run --rm -p 3000:3000 taskmanager:test
curl http://localhost:3000/health   # doit répondre 200
```

Ça valide indépendamment les deux critères "tests unitaires OK" et "image
Docker construite avec succès" — sans toucher à AWS. C'est ce que fait
l'étape 1 du script (avec cleanup automatique du conteneur de test).

## Niveau 2 — rejouer buildspec.yml comme le ferait CodeBuild

Via l'agent officiel AWS, qui tourne 100% en local (aucun compte AWS requis,
juste Docker) :

```bash
git clone https://github.com/aws/aws-codebuild-docker-images.git
curl -o codebuild_build.sh https://raw.githubusercontent.com/aws/aws-codebuild-docker-images/master/local_builds/codebuild_build.sh
chmod +x codebuild_build.sh
docker pull public.ecr.aws/codebuild/amazonlinux2-x86_64-standard:5.0

./codebuild_build.sh \
  -i public.ecr.aws/codebuild/amazonlinux2-x86_64-standard:5.0 \
  -a /tmp/artifacts -s task-manager
```

**Limite réelle à connaître (vérifiée en pratique)** : la phase `pre_build` de
`buildspec.yml` appelle `aws ecr get-login-password` contre le **vrai**
endpoint AWS ECR (pas un simulateur comme LocalStack). Sans compte AWS, cet
appel échoue immédiatement (identifiants introuvables/invalides) — donc le
rejeu s'arrête à la connexion ECR, **avant** `docker build` et les tests, pas
au moment du push final. En pratique, seule la phase `install` (npm ci +
analyse SAST Semgrep) va au bout dans ce mode local ; `build` et `post_build`
(construction Docker, tests, couverture, push) ne sont exercés réellement que
par le Niveau 1 en local, et par la vraie CI une fois déployée sur AWS.

`buildspec.yml` n'a volontairement pas été modifié pour contourner cette
limite (pas de branche conditionnelle "mode local" ajoutée à la logique de
build de production) — le Niveau 1 ci-dessus couvre déjà, sans AWS, les deux
critères qui comptent (tests unitaires + image Docker).

## Passage à AWS réel — ce qui change

Une fois l'accès AWS obtenu, dans l'ordre :

1. **Token GitHub** (prérequis unique, documenté en commentaire en tête de
   `codebuild.yaml`) :
   ```bash
   aws codebuild import-source-credentials \
     --server-type GITHUB \
     --auth-type PERSONAL_ACCESS_TOKEN \
     --token <TON_GITHUB_PERSONAL_ACCESS_TOKEN>
   ```
2. **Déployer `ecr.yaml`** pour de vrai (voir Test 1, Niveau 3) — exporte
   `RepositoryArn`/`RepositoryUri`, importés par `codebuild.yaml` via
   `Fn::ImportValue`.
3. **Déployer `codebuild.yaml`** avec le vrai paramètre `GitHubRepoUrl` :
   ```bash
   aws cloudformation deploy \
     --template-file infrastructure/cloudformation/codebuild.yaml \
     --stack-name taskmanager-codebuild-dev \
     --parameter-overrides ProjectName=taskmanager Environment=dev \
       GitHubRepoUrl=https://github.com/<ton-user>/taskmanager-app.git \
     --capabilities CAPABILITY_NAMED_IAM
   ```
4. **Plus besoin de fournir `ECR_REPOSITORY_URI` / `AWS_ACCOUNT_ID` /
   `AWS_DEFAULT_REGION` à la main** : CodeBuild les injecte automatiquement
   dans l'environnement de build (`EnvironmentVariables` dans
   `codebuild.yaml`), au lieu des valeurs vides utilisées en local.
5. **`aws ecr get-login-password` réussit** car le rôle IAM
   `CodeBuildServiceRole` a les permissions ECR restreintes au repository
   importé — donc `build` et `post_build` s'exécutent réellement (docker
   build, tests, coverage, push), contrairement au mode local ci-dessus.
6. **Le webhook GitHub se crée automatiquement** (`Triggers.Webhook: true`)
   dès que le token est enregistré à l'étape 1 — un push sur `main` ou
   `develop` déclenche le build sans action manuelle supplémentaire.
7. **Vérifier** dans la console CodeBuild (ou `aws codebuild
   batch-get-builds`) que les phases vont bien jusqu'au push ECR, et que
   `imagedefinitions.json` est bien produit en artifact (utilisé plus tard
   par le déploiement ECS).

## Note — fichiers ajoutés / corrigés pour ce Test 2

Fichiers ajoutés : `infrastructure/scripts/test2-codebuild.sh` (ce test) et
cette section de `README-tests-locaux.md`. Fichiers déjà en place, utilisés
par le test : `codebuild.yaml`, `buildspec.yml`, `Dockerfile`, `jest.config.js`,
`tests/health.test.js`.

Trois corrections ont été nécessaires pour que ces tests passent réellement
(bugs préexistants, sans lien avec ce script) :
- `package.json` (racine) avait des clés `scripts`/`devDependencies`
  dupliquées suite à une modification non commitée → restauré à la version
  propre du dernier commit.
- Le Dockerfile était nommé `dokerfile` (faute de frappe) → renommé en
  `Dockerfile` (sinon `docker build` ne le trouve pas automatiquement).
- `task-manager/` n'avait pas son propre `package.json`/`package-lock.json`
  (seul celui de la racine du monorepo existait), donc `npm ci` échouait dès
  la première étape du build Docker → ajout d'un `package.json` autonome
  dans `task-manager/` (mêmes dépendances : express en prod, jest/jest-junit/
  supertest en dev), cohérent avec le fait que ce dossier représente le futur
  repo applicatif indépendant pointé par `GitHubRepoUrl`.
