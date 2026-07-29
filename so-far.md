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
- **`infrastructure/cloudformation/iam.yaml`** — rempli (4 rôles IAM +
  connexion GitHub CodeStar). Validé via
  `infrastructure/scripts/test4-iam.sh` (cfn-lint + LocalStack) — voir
  **Test 4** ci-dessous : les 4 rôles, leurs policies et les 4 outputs
  exportés se créent et se vérifient correctement. Une lacune réelle a été
  trouvée et corrigée avant de tester (voir "Bugs corrigés").
- **`infrastructure/cloudformation/pipeline.yml`** — rempli, puis **refactorisé
  le 2026-07-27** (branche `deployment/ecs-fargate`) : l'ALB, les 2 target
  groups Blue/Green, les 2 security groups, le cluster/task definition/
  service ECS ont été **extraits** vers 4 nouveaux templates dédiés
  (`ecs-cluster.yaml`, `alb.yaml`, `ecs-task-definition.yaml`,
  `ecs-service.yaml` — voir ci-dessous) pour suivre une structure modulaire.
  `pipeline.yml` ne contient plus que l'orchestration CI/CD : bucket S3
  d'artefacts + topic SNS + règle EventBridge de notification (F4),
  CodeDeploy Application + DeploymentGroup (Blue/Green, traffic shift
  `ECSLinear10PercentEvery1Minute`, rollback automatique sur échec), et
  CodePipeline (Source GitHub → Build CodeBuild → Deploy CodeDeployToECS).
  `CodeDeployDeploymentGroup` référence maintenant le cluster/service ECS et
  les target groups/listeners ALB via `Fn::ImportValue` (plus de `!Ref`/
  `!GetAtt` locaux). Les 5 outputs consommés par `observability.yml`
  (`LoadBalancerDnsName`, `AlbFullName`, `BlueTargetGroupFullName`,
  `EcsClusterName`, `EcsServiceName`) sont conservés sous forme de
  pass-through (`Value: !ImportValue ...`, **sans** `Export` — le nom est
  désormais exporté par les nouvelles stacks, CloudFormation refuse un même
  nom d'export en double) : `observability.yml` n'a nécessité **aucune**
  modification. Importe toujours les rôles + la connexion GitHub de
  `iam.yaml`, et référence le projet `codebuild.yaml` par convention de
  nommage.
- **`infrastructure/cloudformation/ecs-cluster.yaml`** (nouveau, 2026-07-27) —
  cluster ECS Fargate extrait de `pipeline.yml`, avec Container Insights
  activé (`ClusterSettings.containerInsights: enabled` — absent avant le
  refactor). Exporte `-ecs-cluster-name` (même nom qu'avant, aucun
  changement en aval) et un nouveau `-ecs-cluster-arn`.
- **`infrastructure/cloudformation/alb.yaml`** (nouveau, 2026-07-27) — ALB
  public + 2 target groups Blue/Green + listener prod (80) + listener de
  test CodeDeploy (8080), extraits de `pipeline.yml`. `VpcId`/
  `PublicSubnetIds` passés en paramètres explicites (plus de `!ImportValue`
  interne à ce template — respecte la contrainte "pas d'ID en dur", la
  valeur réelle vient toujours des Outputs de `vpc.yml`). Ajout d'un
  listener HTTPS conditionnel (`Condition: HasCertificate`, actif seulement
  si le paramètre `CertificateArn` est renseigné) pour préparer HTTPS sans
  restructurer le template plus tard. Exporte les ARN/noms des 2 target
  groups, des 2 listeners, du security group ALB, en plus des exports déjà
  existants (`-alb-dns`, `-alb-full-name`, `-tg-blue-full-name`).
- **`infrastructure/cloudformation/ecs-task-definition.yaml`** (nouveau,
  2026-07-27) — log group + Task Definition ECS extraits de `pipeline.yml`.
  `ContainerImage` devient un paramètre explicite (vide par défaut =
  `<RepositoryUri de ecr.yaml>:latest`, via `Condition: UseDefaultImage` —
  ce paramètre ne compte que pour un déploiement manuel initial, le pipeline
  écrase toujours la task definition via `taskdef.json` à chaque exécution
  réelle). Bloc `Environment` du conteneur documenté avec un commentaire
  explicite sur où ajouter des variables applicatives non sensibles, et où
  NE PAS mettre de secret (renvoi vers `Secrets:` + Secrets Manager, déjà
  prévu côté `EcsTaskExecutionRole` dans `iam.yaml`).
- **`infrastructure/cloudformation/ecs-service.yaml`** (nouveau, 2026-07-27) —
  security group + service ECS Fargate extraits de `pipeline.yml`.
  `DeploymentController: CODE_DEPLOY` conservé. Le `DependsOn` sur les
  listeners (nécessaire quand tout était dans le même template) a disparu :
  l'ordre de déploiement entre stacks (`alb.yaml` avant `ecs-service.yaml`)
  suffit désormais à le garantir.
- **`infrastructure/cloudformation/ecs-autoscaling.yaml`** (nouveau,
  2026-07-28) — auto scaling du service ECS (F3 : « le nombre de tâches Fargate
  scale automatiquement selon la charge CPU »). `ScalableTarget` sur
  `ecs:service:DesiredCount` (2 à 6 tâches) + `ScalingPolicy` de type **Target
  Tracking** sur `ECSServiceAverageCPUUtilization`, cible **70 %**, avec
  `DisableScaleIn: false` (l'énoncé dit « augmente ou diminue »). Cooldowns
  asymétriques assumés : 60 s en scale-out (réagir vite), 300 s en scale-in
  (éviter le battement). Aucun rôle IAM créé : Application Auto Scaling utilise
  son rôle lié au service, donc `iam.yaml` n'a eu besoin d'aucune modification.
  2 alarmes CloudWatch d'**observabilité** notifiant le topic SNS existant :
  CPU soutenu > 85 % pendant 5 min, et capacité maximale atteinte
  (`RunningTaskCount >= MaxCapacity`, via Container Insights déjà activé sur le
  cluster). Ces 2 alarmes ne pilotent PAS le scaling — Target Tracking gère ses
  propres alarmes internes ; c'est documenté en tête du template pour éviter
  qu'on les câble par erreur à une policy. Validé via
  `infrastructure/scripts/test9-autoscaling.sh` — voir **Test 9** ci-dessous.
- **`infrastructure/cloudformation/secrets-manager.yaml`** (nouveau,
  2026-07-28) — secrets applicatifs (F3 du cahier des charges). 2 secrets sous
  le préfixe `${ProjectName}/${Environment}/` : `db` (JSON
  `{username, password}`) et `api-key` (valeur simple). **Aucune valeur
  sensible dans le template** : les deux sont générés par AWS via
  `GenerateSecretString`, jamais écrits en dur ni passés en paramètre de stack.
  La vraie clé d'API (qui vient d'un fournisseur externe et ne peut pas être
  générée) se pousse hors CloudFormation en une commande
  (`aws secretsmanager put-secret-value`) ; un update ultérieur de la stack ne
  l'écrase pas, `GenerateSecretString` ne s'appliquant qu'à la création.
  Pas de `KmsKeyId` : la clé gérée par AWS (`alias/aws/secretsmanager`) évite
  d'avoir à accorder `kms:Decrypt` — commenté explicitement dans `iam.yaml`
  car ça devrait changer avec une clé gérée par le client. Validé via
  `infrastructure/scripts/test8-secrets.sh` — voir **Test 8** ci-dessous.
- **`infrastructure/cloudformation/observability.yml`** — rempli (EPIC
  CICD-EP-04 : dashboard + alarmes). Une Lambda publie 3 métriques custom
  (`PipelineDuration`, `PipelineSuccess`, `PipelineFailure`) déclenchée par
  une règle EventBridge dédiée sur les états terminaux du pipeline
  (CodePipeline n'a pas de métrique de durée/succès native). Dashboard
  CloudWatch avec 7 widgets (durée pipeline, succès/échecs, taux de succès
  7j glissants, durée + résultats CodeBuild, CPU/mémoire ECS, latence +
  hôtes sains ALB). 2 alarmes (durée > 15 min, échec de pipeline) notifiant
  le topic SNS déjà créé dans `pipeline.yml`. Abonnement email optionnel
  (paramètre `AlarmEmail`, vide par défaut). Validé via
  `infrastructure/scripts/test6-observability.sh` — voir **Test 6**
  ci-dessous.

### Outillage de test (`infrastructure/scripts/`)

- **`test8-secrets.sh`** (nouveau, 2026-07-28) — valide
  `secrets-manager.yaml` : création des 2 secrets, génération effective des
  valeurs par AWS, structure JSON du secret DB, et présence des 4 exports.
  Chaîné dans `test7-all-local.sh`. Voir **Test 8** ci-dessous.
- **`test9-autoscaling.sh`** (nouveau, 2026-07-28) — valide
  `ecs-autoscaling.yaml`. Validation **statique approfondie** plutôt que
  déploiement : ni `application-autoscaling` ni `ecs` ne sont émulés par
  LocalStack Community, un déploiement échouerait donc pour des raisons
  d'émulation et non de template. 22 vérifications structurelles ciblées sur
  les erreurs réellement plausibles ici. Chaîné dans `test7-all-local.sh`.
  Voir **Test 9** ci-dessous.
- **`test7-all-local.sh`** — exécute les 8 tests (Tests 1 à 6 + Tests 8 et 9)
  en une seule commande et affiche un rapport récapitulatif (statut + durée,
  logs détaillés dans un répertoire temporaire). Auparavant, chaque
  template se validait uniquement individuellement. Voir **Test 7**
  ci-dessous pour le détail et les deux corrections que sa mise en place a
  révélées dans les scripts existants.

### Application (`task-manager/`, Node.js/Express — application UNIQUE)

- **Unification sur une seule application (2026-07-28)** : le dépôt contenait
  deux applications divergentes — une app Flask/SQLite avec le vrai CRUD
  (`src/app.py` + `templates/index.html`) et un stub Express (`/health` +
  `/api/tasks` vide) autour duquel tout le pipeline était construit. La CI
  GitHub ne validait que la Flask, que rien ne déployait. Le CRUD a été **porté
  vers Express**, puis la version Flask supprimée. Fichiers supprimés :
  `task-manager/src/app.py`, `templates/index.html`, `requirements.txt`,
  `task-manager/tasks.db`, le `Dockerfile` single-stage de la racine, les
  `package.json`/`package-lock.json` dupliqués de la racine, et le fichier
  fantôme `task-manager/ server.js`.
- `src/app.js` — routes Express : `/` (UI HTML), `POST /add`,
  `POST /toggle/:id`, `POST /delete/:id`, `GET /api/tasks`, `GET /health`.
- `src/tasks.js` — store des tâches **en mémoire**. Choix assumé et documenté
  dans l'en-tête du fichier : le système de fichiers Fargate est éphémère et
  plusieurs tâches tournent derrière l'ALB, donc un SQLite local (comme la
  version Flask) donnerait un état divergent par tâche, effacé à chaque
  déploiement Blue/Green. Un stockage partagé (DynamoDB/RDS) ne demanderait de
  remplacer que ce module.
- `src/views.js` — rendu HTML de la page (portage du template Jinja2), sans
  moteur de template externe : zéro dépendance ajoutée, et échappement HTML
  explicite (Jinja2 échappait automatiquement — sans ça, XSS stockée).
- `tests/` — 29 tests (Jest + Supertest) répartis en `health.test.js`,
  `tasks.test.js`, `views.test.js` : **100% de couverture** (lignes, branches,
  fonctions) sur les 3 modules de `src/`, c'est-à-dire sur l'application
  réellement déployée. `jest.config.js` fixe `collectCoverageFrom:
  ['src/**/*.js']` — sans ça, ajouter un module non testé ne faisait pas baisser
  la couverture et le quality gate à 80% était contournable.
- **Rapports de couverture HTML + XML (2026-07-28)** : `jest.config.js` est la
  source de vérité unique des reporters — `text` (logs CI), `json-summary`
  (lu par les quality gates), `lcov` (→ `coverage/lcov-report/` HTML, US-02) et
  `cobertura` (→ `coverage/cobertura-coverage.xml`, format XML standard). Un
  `coverageThreshold` global à 80 % fait échouer `npm test` lui-même, donc y
  compris en local, avant la CI.
  Deux vraies lacunes corrigées au passage : (1) `buildspec.yml` passait
  `--coverageReporters=json-summary --coverageReporters=text`, ce qui
  **écrasait** la liste de `jest.config.js` — CodeBuild ne produisait donc
  jamais le rapport HTML, rendant US-02 littéralement insatisfiable ; (2) les
  rapports de couverture n'étaient pas exportés. Désormais `buildspec.yml`
  déclare deux report groups (`unit-tests` en JUNITXML et `code-coverage` en
  **COBERTURAXML**, que CodeBuild sait afficher nativement avec l'évolution
  d'un build à l'autre) et archive le HTML en `coverage-html.tar.gz` pour
  l'exporter malgré `discard-paths`. `ci.yml` publie HTML + XML + JUnit en
  artefacts GitHub et écrit la couverture dans le résumé du job.
- `Dockerfile` — build multi-stage, image de prod sans devDependencies,
  exécution en utilisateur non-root, `HEALTHCHECK` intégré. **Taille réelle
  mesurée : 48 Mo** (cible < 200 Mo du cahier des charges) — jamais mesurée
  jusqu'ici, seulement visée.
- `buildspec.yml` — phases install (npm ci + SAST Semgrep) → pre_build (login
  ECR) → build (docker build) → post_build (tests + seuil de couverture 80% +
  push ECR). Depuis `pipeline.yml` : post_build génère aussi `imageDetail.json`
  (format attendu par l'action CodePipeline `CodeDeployToECS` — remplace
  l'ancien `imagedefinitions.json`, format pour l'action ECS standard non
  utilisée ici) et rend `taskdef.json` à partir de
  `taskdef.template.json` (ARN des rôles ECS injectés via les variables
  d'environnement `PROJECT_NAME`/`ENVIRONMENT_NAME`/`AWS_ACCOUNT_ID` ajoutées
  au projet CodeBuild dans `codebuild.yaml`).
- `taskdef.template.json` — template de Task Definition ECS versionné dans le
  repo applicatif, avec placeholders (`<PROJECT_NAME>`, `<AWS_ACCOUNT_ID>`...)
  rendus au build, et `<IMAGE1_NAME>` laissé tel quel (substitué par
  CodePipeline lui-même via `Image1ContainerName`).
- `appspec.yaml` — AppSpec CodeDeploy pour ECS (statique, aucune valeur
  spécifique au compte -> versionné tel quel, consommé directement depuis
  l'artefact Source par l'action `CodeDeployToECS`).
- `package.json` / `package-lock.json` propres à `task-manager/` — désormais
  les **seuls** manifestes Node du dépôt (ceux de la racine, qui dupliquaient
  les mêmes dépendances, ont été supprimés : c'est exactement ce genre de
  duplication qui avait laissé les deux applications diverger).
- **Résolution de chemin du buildspec corrigée (2026-07-28)** : `codebuild.yaml`
  déclarait `BuildSpec: buildspec.yml`, un chemin résolu depuis la **racine**
  du dépôt cloné — or le fichier est dans `task-manager/`. CodeBuild ne l'aurait
  jamais trouvé et le build aurait échoué avant la phase `install`. Corrigé en
  `BuildSpec: task-manager/buildspec.yml` ; en contrepartie, chaque phase du
  buildspec commence par un `cd "$CODEBUILD_SRC_DIR/$APP_DIR"` (CodeBuild
  exécute toujours les commandes depuis la racine du dépôt, quel que soit
  l'emplacement du buildspec) et les sections `reports`/`artifacts`/`cache`
  portent le préfixe `task-manager/`. `test2-codebuild.sh` a été aligné en
  conséquence (`npm ci`/`npm test` dans `task-manager/`, et rejeu du buildspec
  avec `-s <racine> -b task-manager/buildspec.yml`).
- **`taskdef.template.json` aligné sur `ecs-task-definition.yaml`** : il ne
  contenait ni `environment` ni `healthCheck`. Comme c'est CE fichier que
  l'action `CodeDeployToECS` déploie à chaque exécution du pipeline (la task
  definition CloudFormation ne sert qu'au bootstrap), le health check du
  conteneur disparaissait dès le premier passage du pipeline — or c'est lui qui
  conditionne le rollback automatique Blue/Green (F3). Les deux fichiers
  déclarent maintenant le même health check et les mêmes variables.
- **`NODE_ENV` corrigé** dans `ecs-task-definition.yaml` : la valeur était
  `!Ref Environment`, donc `dev`/`staging`/`prod` — aucune n'est une valeur
  valide pour Node/Express (`prod` ≠ `production`), et elle écrasait le
  `ENV NODE_ENV=production` du Dockerfile, faisant tourner l'application en
  mode dégradé jusqu'en production. Désormais `NODE_ENV: production` fixe, et
  le nom de l'environnement du projet est exposé séparément via `APP_ENV`.

### Tests locaux exécutés et confirmés (sans accès AWS)

- `cfn-lint` sur `ecr.yaml`, `codebuild.yaml` et `vpc.yml` → passent sans erreur.
- `npm ci` + `npm test` → 29 tests unitaires passent, 100% de couverture,
  rapports HTML + Cobertura XML + JUnit générés.
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
- `test4-iam.sh` exécuté de bout en bout (LocalStack Community, exit code 0,
  après corrections — voir Test 4 ci-dessous) : les 4 rôles IAM
  (`taskmanager-dev-codepipeline-role`, `-codedeploy-role`,
  `-ecs-execution-role`, `-ecs-task-role`) sont créés, les 4 outputs
  exportés confirmés via `describe-stacks`, et le contenu réel des policies
  (managed policies attachées + statements inline, y compris les deux
  nouveaux ajoutés pour le Blue/Green ECS) vérifié via `iam get-role-policy`
  / `iam list-attached-role-policies`. Seule `GitHubConnection` n'est validée
  que syntaxiquement (cfn-lint), pas déployée — limite LocalStack Community
  documentée ci-dessous.
- `test5-pipeline.sh` exécuté de bout en bout (LocalStack Community, exit
  code 0, après corrections — voir Test 5 ci-dessous) : sur les ~17
  ressources de `pipeline.yml`, les 6 réellement supportées par LocalStack
  Community (bucket S3 versionné, topic SNS + policy, règle EventBridge,
  log group, 2 security groups) sont déployées et vérifiées. Les 11 autres
  (ALB, 2 target groups, 2 listeners, cluster/task def/service ECS,
  CodeDeploy Application + DeploymentGroup, CodePipeline lui-même) ne sont
  validées que syntaxiquement (cfn-lint) — limite LocalStack Community
  documentée ci-dessous, bien plus étendue que pour les templates
  précédents.
- `test6-observability.sh` exécuté de bout en bout (LocalStack Community,
  exit code 0 — voir Test 6 ci-dessous) : 6 des 7 ressources de
  `observability.yml` déployées et vérifiées (log group, rôle IAM, 2
  alarmes, dashboard, abonnement SNS) ; seule la fonction Lambda
  (`MetricsPublisherFunction`) est retirée de la copie de test — sa
  création réelle déclenche un pull Docker de l'image runtime Python trop
  lent pour cet environnement (même limite déjà documentée pour l'image
  CodeBuild au Test 2).
- `test7-all-local.sh` exécuté de bout en bout (LocalStack Community, exit
  code 0) : les 6 tests enchaînés en une seule commande, tous PASS, 597s au
  total (~10 min) — voir Test 7 ci-dessous pour le détail et les deux
  corrections que sa mise en place a révélées.

### Test 4 — `iam.yaml` (rôles IAM du pipeline)

**Lacune trouvée et corrigée avant test** (dans `CodePipelineServiceRole`) :
le stage Deploy de `pipeline.yaml` utilisera l'action CodePipeline
`CodeDeployToECS` (Blue/Green ECS), qui — contrairement au provider
`CodeDeploy` générique — **génère lui-même une nouvelle révision de task
definition** à chaque exécution (à partir de `taskdef.json` +
`imageDetail.json`) avant de déclencher CodeDeploy. D'après la
documentation AWS officielle
(`action-reference-ECSbluegreen.html#edit-role-codedeploy-ecs`), ça exige
deux permissions absentes du template initial :
- `ecs:RegisterTaskDefinition` (Resource `*`, contrainte AWS — cette action
  n'accepte pas de restriction par ARN).
- `iam:PassRole` restreint aux ARN de `EcsTaskExecutionRole` et
  `EcsTaskRole`, avec condition `iam:PassedToService` sur
  `ecs.amazonaws.com`/`ecs-tasks.amazonaws.com`.

Sans ces deux statements, le stage Deploy du futur pipeline aurait échoué
dès l'enregistrement de la task definition — pas un bug visible par
cfn-lint (le template restait syntaxiquement valide), seulement au moment
d'une exécution réelle. Le reste du template (4 rôles, policies existantes)
a été comparé statement par statement aux exemples IAM minimaux publiés par
AWS pour CodePipeline + CodeDeploy + ECS et correspond déjà exactement — pas
d'autre lacune trouvée.

**Bugs de script corrigés en testant** (dans `test4-iam.sh`, pas dans
`iam.yaml`) :
- Démarrage LocalStack fragile (image `latest` non épinglée, simple
  `sleep 8`) → aligné sur le pattern robuste des tests précédents (image
  `3.8.1` épinglée, attente active sur `/_localstack/health`).
- `cfn-lint --ignore-checks W3005 iam.yaml` : `--ignore-checks` consomme
  tous les arguments positionnels qui suivent (`nargs='+'`), donc le chemin
  du template était avalé par la liste des checks ignorés et cfn-lint
  tentait de lire un template vide → template passé **avant** l'option
  (`cfn-lint iam.yaml --ignore-checks W3005`). Note : ce flag n'est
  finalement plus nécessaire une fois le point suivant corrigé.
- **Limite LocalStack Community non documentée jusqu'ici, découverte en
  testant** : `AWS::CodeBuild::Project` est un service Pro-only, comme
  `AWS::CodeStarConnections::Connection` déjà connu. `aws codebuild
  list-projects` renvoie explicitement *"API for service 'codebuild' not
  yet implemented or pro feature"*. CloudFormation accepte quand même la
  ressource à la création (comme pour l'EIP du NAT Gateway dans `vpc.yml`),
  mais `Fn::GetAtt BuildProject.Arn` n'est jamais résolu et renvoie le
  littéral `"unknown"` — qui se propage via l'Output exporté par
  `codebuild.yaml` jusqu'à l'`Fn::ImportValue` fait par `iam.yaml`
  (statement `TriggerCodeBuild`), et fait échouer `PutRolePolicy` avec
  `MalformedPolicyDocument: Resource unknown must be in ARN format or "*"`.
  Sans lien avec `iam.yaml` : le script remplace maintenant cet import par
  un ARN factice dans sa copie temporaire (même technique déjà utilisée pour
  `GitHubConnection`), pour isoler ce qui teste vraiment `iam.yaml`.
- Nettoyage manuel nécessaire entre tentatives : un rollback `CREATE_FAILED`
  sur LocalStack ne supprime pas toujours les rôles IAM déjà créés
  (`EntityAlreadyExists` au run suivant) — les rôles orphelins ont dû être
  supprimés à la main (`iam delete-role-policy` / `detach-role-policy` /
  `delete-role`) avant de relancer.

**Ce qui n'est PAS testable en local** :
- `GitHubConnection` (CodeStar Connections) : validée seulement par
  cfn-lint, pas déployée sur LocalStack (limite Pro connue). Son
  autorisation manuelle dans la console et son bon fonctionnement réel ne
  sont vérifiables que sur un vrai compte AWS.
- Le comportement réel du provider CodePipeline `CodeDeployToECS` (lecture
  de `taskdef.json`/`imageDetail.json`, génération de la nouvelle révision,
  déclenchement effectif du Blue/Green CodeDeploy) : ça n'existe que côté
  `pipeline.yaml` (pas encore écrit) et nécessite un vrai pipeline en
  exécution — les permissions IAM ajoutées ici sont basées sur la
  documentation AWS, pas encore exercées de bout en bout.
- La politique managée `AWSCodeDeployRoleForECS` et
  `AmazonECSTaskExecutionRolePolicy` : LocalStack Community accepte de les
  attacher (confirmé via `iam list-attached-role-policies`), mais ne
  vérifie pas leur contenu réel ni leur effet à l'exécution — seul un vrai
  compte AWS peut confirmer qu'elles couvrent effectivement tous les appels
  faits par CodeDeploy/ECS.

### Test 5 — `pipeline.yml` (CodePipeline + CodeDeploy Blue/Green + ECS Fargate)

**Contenu ajouté en même temps** (nécessaire pour que `pipeline.yml`
fonctionne réellement, pas juste au niveau du template) :
- `codebuild.yaml` : ajout de 2 variables d'environnement au projet
  CodeBuild (`PROJECT_NAME`, `ENVIRONMENT_NAME`) — sans elles, `buildspec.yml`
  n'a aucun moyen de construire les ARN des rôles ECS au moment du build.
- `task-manager/buildspec.yml` : remplace la génération de
  `imagedefinitions.json` (format de l'action CodePipeline ECS standard,
  jamais utilisée ici) par `imageDetail.json` (`{"ImageURI": "..."}` — format
  attendu par `Image1ArtifactName` de l'action `CodeDeployToECS`) et par le
  rendu de `taskdef.json` à partir de `taskdef.template.json` (`sed` sur les
  4 placeholders `<AWS_ACCOUNT_ID>`/`<PROJECT_NAME>`/`<ENVIRONMENT_NAME>`/
  `<AWS_REGION>` ; `<IMAGE1_NAME>` reste intact, substitué par CodePipeline
  lui-même).
- `task-manager/taskdef.template.json` et `task-manager/appspec.yaml` :
  fichiers requis par l'action `CodeDeployToECS`
  (`TaskDefinitionTemplateArtifact`/`AppSpecTemplateArtifact`), absents du
  repo jusqu'ici.

**Décisions d'architecture notables :**
- Pas de `ecs.yaml` séparé (contrairement à ce que suggérait la note
  d'ordre de déploiement dans `iam.yaml`) : le cluster/task definition/
  service ECS sont créés directement dans `pipeline.yml`, avec l'ALB et les
  2 target groups Blue/Green — regrouper évite un problème d'ordre réel
  (le DeploymentGroup CodeDeploy exige que le service ECS existe déjà à sa
  création ; créer `ecs.yaml` après `pipeline.yaml`, comme suggéré par la
  note originale, aurait été impossible techniquement).
- `DeploymentConfigName: CodeDeployDefault.ECSLinear10PercentEvery1Minute`
  choisi comme l'équivalent prédéfini AWS le plus proche du traffic shift
  F3 du cahier des charges (10 % → 100 % en ~10 min) — AWS ne propose pas de
  config avec paliers 10/50/100 % exacts.
- Notifications SNS de changement d'état (F4) implémentées via une règle
  EventBridge (pas via le statement `sns:Publish` déjà présent sur
  `CodePipelineServiceRole`, qui lui est réservé à un futur stage
  `ManualApproval` — CodePipeline ne publie pas nativement sur SNS pour les
  événements SUCCESS/FAILURE).
- `taskdef.json` vient de l'artefact de **Build** (généré dynamiquement,
  ARN réels injectés) ; `appspec.yaml` vient de l'artefact **Source**
  (statique, aucune valeur spécifique au compte).

**Lacune de script trouvée et corrigée en testant** (dans le script, pas
dans `pipeline.yml`) : le premier jet des fonctions Python de suppression de
blocs (réutilisées du script précédent) utilisait un lookahead ancré sur un
saut de ligne littéral (`\n  Ressource:`) pour détecter où s'arrêter. Ça
fonctionne uniquement quand deux ressources sont séparées par une ligne
vide simple — dès qu'un bloc de commentaires s'intercale (très fréquent
dans ce projet, très commenté), le lookahead ne matchait plus et la
suppression dévorait tout jusqu'à la ressource suivante, supprimant des
ressources qui auraient dû être gardées (`PrivateRouteTable1` dans une
copie de test de `vpc.yml`, puis la clé `Outputs:` elle-même dans une copie
de `pipeline.yml`). Corrigé en ancrant le lookahead avec `re.MULTILINE`
(`^  Ressource:` / `^[A-Za-z]` pour les clés de premier niveau) plutôt que
sur un `\n` littéral.

**Limite LocalStack BEAUCOUP plus étendue que pour les templates
précédents** : sur les ~17 ressources de `pipeline.yml`, **11** reposent sur
des services que LocalStack Community n'implémente pas du tout —
`elbv2` (ALB, 2 target groups, 2 listeners), `ecs` (cluster, task
definition, service), `codedeploy` (Application, DeploymentGroup) et
`codepipeline` (le pipeline lui-même). Contrairement à
`AWS::CodeBuild::Project` (accepté à la création, seul son `Arn` est cassé),
ces 4 services font échouer la création de la ressource elle-même
(`CREATE_FAILED` immédiat) — CloudFormation ne les accepte même pas de
façon dégradée. Seules les **6** ressources restantes ont pu être déployées
et vérifiées : bucket S3 (versioning confirmé), topic SNS + sa policy
(condition `ArnEquals` sur l'ARN de la règle EventBridge confirmée), règle
EventBridge (pattern confirmé via `describe-rule`), log group, et les 2
security groups (créés, mais voir la limite suivante).

**Limite LocalStack additionnelle découverte** : les règles `SecurityGroupIngress`
définies en ligne dans `AWS::EC2::SecurityGroup` ne sont PAS appliquées par
LocalStack Community — `aws ec2 describe-security-groups` confirme que les
2 groupes sont bien créés (et que leur règle d'egress générique passe),
mais renvoie une liste d'ingress vide dans les deux cas. C'est cohérent
avec les autres limites déjà documentées (émulation partielle de services
par ailleurs "supportés") ; le template lui-même est syntaxiquement correct
(cfn-lint) et suit la syntaxe standard CloudFormation.

**Ce qui n'est PAS testable en local** (résumé) :
- L'ALB, les 2 target groups et les 2 listeners (Blue/Green) — `elbv2`
  Pro-only.
- Le cluster, la task definition et le service ECS Fargate — `ecs` Pro-only.
- L'Application et le DeploymentGroup CodeDeploy (traffic shift, rollback
  automatique) — `codedeploy` Pro-only.
- CodePipeline lui-même (les 3 stages Source/Build/Deploy, le déclenchement
  réel sur push GitHub, l'exécution bout en bout) — `codepipeline` Pro-only.
- Les règles d'ingress des security groups — acceptées par cfn-lint et par
  CloudFormation, mais non appliquées par LocalStack Community.
- Par construction, tout ce qui dépend de `GitHubConnection` (Pro-only,
  Test 4) et du NAT Gateway (Pro-only, Test 3) reste non plus testable ici.

### Test 6 — `observability.yml` (dashboard CloudWatch + alarmes, EPIC CICD-EP-04)

**Résultat : ✅ PASSE sur 6 des 7 ressources (exit code 0).** Bonne surprise
par rapport aux Tests 2/4/5 : CloudWatch (Alarm + Dashboard) et Lambda sont
tous les deux supportés par LocalStack Community — la seule vraie limite
ici est opérationnelle (pull Docker), pas un service Pro-only manquant.

**Découverte en testant, avant même d'écrire le script** : les appels CLI
directs `aws cloudwatch describe-alarms` / `list-dashboards` /
`put-metric-data` échouent tous avec *"Operation detection failed. Missing
Action in request for query-protocol service ServiceModel(cloudwatch)"* —
un bug de compatibilité entre LocalStack 3.8.1 et la version d'awscli/
botocore installée ici (1.45.54 / 1.43.54), PAS une limite Pro. Vérifié en
déployant directement une `AWS::CloudWatch::Alarm` et un
`AWS::CloudWatch::Dashboard` minimalistes via CloudFormation (qui n'emprunte
pas ce chemin CLI) : les deux atteignent `CREATE_COMPLETE` sans problème.
Ce test vérifie donc les ressources CloudWatch via
`describe-stack-resources`/`describe-stacks`, jamais via `aws cloudwatch`.

**Découverte en testant, deuxième surprise** : `AWS::Lambda::Function` EST
supporté par LocalStack Community (`aws lambda list-functions` répond
normalement, contrairement à CodeBuild/CodeDeploy/ECS/CodePipeline qui
renvoient explicitement "not yet implemented or pro feature"). Mais sa
création déclenche en coulisses un `docker pull` de l'image runtime — la
toute première tentative a échoué immédiatement avec *"Docker not
available"* (le conteneur LocalStack n'avait pas accès au socket Docker de
l'hôte : corrigé en relançant avec
`-v /var/run/docker.sock:/var/run/docker.sock`). Une fois corrigé, la
création elle-même reste bloquée en `CREATE_IN_PROGRESS` sans avancer
pendant plusieurs minutes — même classe de limite réseau déjà rencontrée et
documentée au Test 2 (pull de l'image CodeBuild abandonné après 21 min).
Ce test retire donc `MetricsPublisherFunction` (+ sa `Permission` + sa
règle EventBridge dédiée) de la copie déployée ; le code Python (~40
lignes, dans `observability.yml`) n'est validé que par lecture, pas exécuté
localement.

**Dépendances manquantes contournées** : la copie de test allégée de
`pipeline.yml` (Test 5) n'exporte pas `EcsClusterName`/`EcsServiceName`/
`AlbFullName`/`BlueTargetGroupFullName` (ressources ECS/ALB retirées, Pro-only).
Un petit stack "stub" (`taskmanager-dashboard-stubs-test`, une unique
ressource `AWS::CloudFormation::WaitConditionHandle` + 4 Outputs factices)
est déployé juste avant `observability.yml` pour fournir ces 4 exports sous
les mêmes noms — uniquement pour permettre de tester la STRUCTURE du
Dashboard (les widgets ECS/ALB ne remonteront jamais de vraies données dans
ce mode, évidemment).

**Résultat détaillé** : `MetricsPublisherLogGroup`, `MetricsPublisherRole`,
`PipelineDurationAlarm`, `PipelineFailureAlarm`, `PipelineDashboard` et
`AlarmEmailSubscription` tous confirmés `CREATE_COMPLETE` (vérifié à la
fois via `describe-stack-resources` et directement sur les ressources
réelles — `logs describe-log-groups`, `iam get-role` — pour contourner un
bug de cohérence secondaire de LocalStack où `describe-stack-resources`
affichait par erreur `DELETE_COMPLETE` après un cycle rapide
delete-stack/redeploy sous le même nom, alors que les ressources réelles
existaient bien).

**Anomalie mineure découverte** : `AlarmEmailSubscription` (protégée par la
`Condition: HasAlarmEmail`, qui doit être fausse quand `AlarmEmail=''`, sa
valeur par défaut) a quand même été créée par LocalStack alors qu'elle
n'aurait pas dû l'être sur un vrai CloudFormation — LocalStack Community
n'évalue pas correctement cette Condition pour ce type de ressource (ou ne
valide pas le format d'`Endpoint` vide). Le template lui-même est correct :
`Condition: HasAlarmEmail` est la façon standard CloudFormation de
conditionner une ressource, et fonctionnera comme prévu sur un vrai compte
AWS.

**Ce qui n'est PAS testable en local** :
- La fonction Lambda elle-même (calcul réel de la durée via
  `list_pipeline_executions`, publication de métriques) — limite Docker
  décrite ci-dessus.
- Le contenu réel du Dashboard une fois rendu dans la console (couleurs,
  rendu des widgets) et les vraies données CodeBuild/ECS/ALB dans ses
  métriques — dépend de `pipeline.yml` en fonctionnement réel (Pro-only,
  Test 5).
- Le déclenchement réel des 2 alarmes (nécessite de vraies données de
  métrique, donc un pipeline qui tourne pour de vrai).
- L'envoi effectif d'un email par `AlarmEmailSubscription` (nécessite une
  vraie adresse + confirmation SNS, non simulée par LocalStack).

### Test 7 — `test7-all-local.sh` (orchestrateur des 6 tests)

**Contexte** : jusqu'ici, valider toute l'infrastructure demandait de
lancer 6 scripts à la main, dans le bon ordre, en se souvenant lequel
importe quoi. `test7-all-local.sh` enchaîne les Tests 1 à 6 dans l'ordre de
dépendance du projet, en une seule commande, et affiche un rapport
récapitulatif (statut + durée par test) à la fin. Il n'ajoute AUCUNE
logique de validation propre — il orchestre les 6 scripts existants tels
quels et agrège leurs résultats.

**Deux problèmes réels révélés en l'écrivant** (pas des limites LocalStack,
de vrais bugs de script, invisibles tant que chaque test tournait seul) :

1. **Collision de nom de stack entre Test 3 et Test 5.** `test3-vpc.sh`
   déploie le VRAI `vpc.yml` sous le nom `taskmanager-vpc-test` ; comme le
   NAT Gateway y échoue toujours (limite déjà connue), cette stack finit
   systématiquement en `CREATE_FAILED`/`ROLLBACK_COMPLETE`. `test5-pipeline.sh`
   déploie ENSUITE sa propre copie allégée de `vpc.yml` (sans NAT) sous le
   **même nom de stack**, pour obtenir de vrais exports VpcId/subnet-ids —
   mais un `cloudformation deploy` ne peut pas mettre à jour une stack dans
   cet état, il faut d'abord la supprimer. `test3-vpc.sh` le fait déjà pour
   lui-même (voir son commentaire "Une stack déjà en CREATE_FAILED... bloque
   tout nouveau deploy") mais ne le fait pas pour le bénéfice du script
   suivant. **Corrigé** : ajout du même `delete-stack`/`wait
   stack-delete-complete` défensif dans `test5-pipeline.sh`, juste avant son
   propre déploiement de `vpc.yml` — invisible quand `test5-pipeline.sh`
   tourne seul (la stack n'existe pas encore ou est déjà dans le bon état),
   mais bloquant en enchaînement sans ce correctif.
2. **`test2-codebuild.sh` beaucoup trop lent pour un run global.** Son étape
   2 (clone `aws/aws-codebuild-docker-images` + `docker pull` d'une image
   de plusieurs Go) est la même limite déjà documentée au Test 2 (abandonnée
   après 21 min lors du tout premier essai) — inchangée en soi, mais
   inacceptable comme étape par défaut d'un script censé tout valider
   rapidement. **Corrigé** : ajout d'une variable d'environnement
   `SKIP_BUILDSPEC_REPLAY` (défaut `false`, comportement inchangé pour un
   lancement individuel de `test2-codebuild.sh`) ; `test7-all-local.sh`
   l'exporte à `true`, l'étape 1 (cfn-lint + tests unitaires + build Docker
   + healthcheck) restant seule suffisante pour valider sans AWS.

**Résultat de l'exécution complète** : les 6 tests passent (exit code 0
pour chacun), 597 secondes au total (~10 min), aucune erreur cachée dans
les logs détaillés. Table récapitulative :

| Test | Statut | Durée |
|---|---|---|
| Test 1 — `ecr.yaml` | ✅ PASS | 35s |
| Test 2 — `codebuild.yaml` + `buildspec.yml` | ✅ PASS | 76s |
| Test 3 — `vpc.yml` | ✅ PASS | 36s |
| Test 4 — `iam.yaml` | ✅ PASS | 96s |
| Test 5 — `pipeline.yml` | ✅ PASS | 162s |
| Test 6 — `observability.yml` | ✅ PASS | 192s |

**Ce qui n'est PAS testable en local** : exactement la même liste que dans
chacun des Tests 1 à 6 pris individuellement (`test7-all-local.sh` n'élargit
ni ne réduit la couverture — il ne fait qu'agréger). Voir
`infrastructure/scripts/testing-output.md` pour le détail complet.

### Test 8 — `secrets-manager.yaml` (secrets applicatifs, F3)

**Résultat : ✅ PASSE (exit code 0).** Secrets Manager est supporté par
LocalStack Community — comme CloudWatch/Lambda au Test 6, et contrairement à
CodeBuild/ECS/CodeDeploy/CodePipeline.

Ce que le script vérifie réellement, au-delà du `cfn-lint` :
- les 2 secrets se créent et **AWS génère bien leur valeur** — ce qui prouve
  que rien n'a besoin d'être écrit en clair dans le dépôt ;
- le secret DB est un JSON contenant **exactement** `username` + `password` :
  c'est ce qui valide la syntaxe `<arn>:password::` utilisée par
  `ecs-task-definition.yaml` et `taskdef.template.json` (une clé absente ferait
  échouer le démarrage de la tâche ECS, pas le déploiement de la stack) ;
- la longueur du mot de passe généré (32) et l'absence effective des caractères
  exclus (`" @ / \`) ;
- les **4 exports** sont présents sous les noms attendus par `codebuild.yaml` et
  `ecs-task-definition.yaml`.

Le script n'affiche jamais une valeur de secret : seulement les clés présentes,
la longueur du mot de passe, et les ARN (qui ne sont pas des données sensibles).

**Confirmé empiriquement** : l'ARN d'un secret se termine bien par un suffixe
aléatoire de 6 caractères ajouté par AWS (`...:secret:taskmanager/dev/db-pvWiCG`).
C'est la raison d'être de tout le câblage par exports/variables d'environnement
plutôt que par convention de nommage : cet ARN est **impossible à reconstruire**.
Le wildcard de la policy `ReadAppSecrets` (`.../secret:${ProjectName}/${Environment}/*`)
le couvre correctement, et refuse bien les secrets d'un autre environnement ou
d'un autre projet (vérifié par correspondance de motif).

**Ce qui n'est PAS testable en local** : l'injection réelle des secrets dans le
conteneur par l'agent ECS (service `ecs` Pro-only sur LocalStack Community, cf.
Test 5). Elle ne pourra être vérifiée que sur un vrai compte AWS, en inspectant
les variables d'environnement de la tâche en cours d'exécution.

### Test 9 — `ecs-autoscaling.yaml` (Application Auto Scaling, F3)

**Résultat : ✅ PASSE (exit code 0), 22 vérifications structurelles.**

**Choix de méthode assumé** : contrairement aux Tests 1/3/4/6/8, ce test ne
déploie rien sur LocalStack. Les 3 ressources du template dépendent de services
non émulés par LocalStack Community (`application-autoscaling` n'existe pas, et
les 2 alarmes importent des noms ECS + le topic SNS, or `ecs` est Pro-only —
cf. Test 5). Un déploiement échouerait donc pour des raisons d'émulation, pas de
template : ça n'apporterait aucune information. Le script fait à la place de la
validation statique approfondie, en chargeant le YAML (avec un loader tolérant
aux tags courts `!Ref`/`!Sub`/`!ImportValue`) et en vérifiant les erreurs
réellement plausibles sur ce type de template :

- `ServiceNamespace: ecs` et `ScalableDimension: ecs:service:DesiredCount` —
  une faute ici passe `cfn-lint` mais casse le scaling à l'exécution ;
- `ResourceId` au format exact `service/<cluster>/<service>`, construit
  **uniquement** depuis des `Fn::ImportValue` (aucun nom en dur) ;
- `PolicyType: TargetTrackingScaling`, métrique prédéfinie
  `ECSServiceAverageCPUUtilization`, `DisableScaleIn: false` ;
- la policy pointe bien vers le `ScalableTarget` de ce même template ;
- **cohérence des seuils** : cible CPU = 70 % (valeur du CDC), seuil d'alarme
  (85 %) *strictement au-dessus* de la cible — sinon l'alarme sonnerait alors
  que l'auto scaling fait exactement son travail ; `MaxCapacity > MinCapacity` ;
  cooldown de scale-in > scale-out ;
- **cohérence inter-stacks** : `MinCapacity` (2) ≤ `DesiredCount` de
  `ecs-service.yaml` (2), sinon Application Auto Scaling corrigerait le compte
  dès sa première évaluation ;
- les 2 alarmes notifient bien le topic SNS et sont en
  `TreatMissingData: notBreaching` (un service pas encore démarré n'émet aucune
  donnée : il ne doit pas déclencher d'alarme) ;
- les 3 exports attendus sont présents ;
- Container Insights est bien activé sur le cluster — sans lui, l'alarme de
  capacité (qui lit `ECS/ContainerInsights`) resterait en `INSUFFICIENT_DATA`.

**Ce qui n'est PAS testable en local** : le scaling réel. Sur un vrai compte
AWS, il faudra générer de la charge CPU puis vérifier via
`aws application-autoscaling describe-scaling-activities` que le nombre de
tâches monte, puis redescend une fois la charge retombée.

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
- `iam.yaml` (`CodePipelineServiceRole`) : deux permissions manquantes pour
  l'action CodePipeline `CodeDeployToECS` (Blue/Green ECS) — voir détail
  dans le Test 4 ci-dessus (`ecs:RegisterTaskDefinition` et `iam:PassRole`
  restreint aux rôles de tâche ECS). Trouvé par comparaison avec la
  documentation IAM officielle d'AWS pour ce provider précis, pas par
  cfn-lint (le template restait syntaxiquement valide sans ces statements).
- `test4-iam.sh` (ajouté par l'utilisateur avec `iam.yaml` rempli) : mêmes
  bugs de robustesse LocalStack que `test3-vpc.sh` à l'origine (image
  `latest` non épinglée, `sleep 8` sans attente active) → corrigés de la
  même façon. Découverte en testant : `AWS::CodeBuild::Project` est
  Pro-only sur LocalStack Community (comme `CodeStarConnections` déjà
  connu) — son `Fn::GetAtt ...Arn` renvoie `"unknown"`, ce qui cassait
  l'import fait par `iam.yaml` en aval ; le script isole maintenant ce cas
  avec un ARN factice (détail complet dans le Test 4 ci-dessus).
- `pipeline.yml` + `test5-pipeline.sh` : voir le détail complet dans le
  Test 5 ci-dessus — pas de bug dans `pipeline.yml` lui-même (premier jet
  cfn-lint propre), mais un bug de script (lookahead regex cassé par les
  blocs de commentaires, corrigé avec `re.MULTILINE`) et trois fichiers
  ajoutés en même temps parce que `pipeline.yml` ne pouvait pas fonctionner
  sans eux : `codebuild.yaml` (2 variables d'environnement), `buildspec.yml`
  (génération `imageDetail.json` + `taskdef.json`), et les 2 nouveaux
  fichiers `task-manager/taskdef.template.json` / `appspec.yaml`.
- `observability.yml` + `test6-observability.sh` : voir le détail complet
  dans le Test 6 ci-dessus — pas de bug dans `observability.yml` lui-même
  (premier jet cfn-lint propre). Un bug d'environnement corrigé (LocalStack
  lancé sans accès au socket Docker de l'hôte, requis pour que
  `AWS::Lambda::Function` puisse créer son conteneur d'exécution). Deux
  outputs ajoutés à `pipeline.yml` après coup (`AlbFullName`,
  `BlueTargetGroupFullName`) car le dashboard en avait besoin et ils
  n'existaient pas encore.
- `test7-all-local.sh` : voir le détail complet dans le Test 7 ci-dessus —
  deux bugs réels trouvés en enchaînant les 6 scripts (invisibles quand
  chacun tourne seul) : collision de nom de stack `taskmanager-vpc-test`
  entre `test3-vpc.sh` et `test5-pipeline.sh` (corrigé par un
  `delete-stack` défensif ajouté à `test5-pipeline.sh`, avant son propre
  déploiement de `vpc.yml`), et l'étape 2 de `test2-codebuild.sh` (pull
  Docker de plusieurs Go) beaucoup trop lente pour un run global (corrigé
  par une variable `SKIP_BUILDSPEC_REPLAY`, activée uniquement par
  `test7-all-local.sh`).

## Pas encore fait

- Déploiement réel sur AWS (aucun accès AWS pour l'instant) : import du token
  GitHub (`aws codebuild import-source-credentials`), autorisation manuelle
  de `GitHubConnection`, déploiement réel des **12** stacks dans l'ordre
  (`vpc.yml` → `iam.yaml` → `secrets-manager.yaml` → `ecr.yaml` →
  `codebuild.yaml` → `ecs-cluster.yaml` → `alb.yaml` →
  `ecs-task-definition.yaml` → `ecs-service.yaml` → `pipeline.yml` →
  `ecs-autoscaling.yaml` → `observability.yml`), remplacement de la valeur
  placeholder du secret
  `api-key` par la vraie clé (`aws secretsmanager put-secret-value`), premier
  passage du pipeline de bout en bout (Source → Build → Deploy Blue/Green),
  vérification que les 3 secrets arrivent bien dans les variables
  d'environnement de la tâche ECS, et confirmation que les métriques/alarmes
  remontent réellement — rien de tout cela n'est vérifiable sans compte AWS
  réel, vu l'étendue des limites LocalStack Community documentées dans les
  Tests 5, 6 et 8.
- Tests locaux (`test5-pipeline.sh` et consorts) pas encore mis à jour pour
  refléter le nouveau découpage `pipeline.yml`/`ecs-cluster.yaml`/
  `alb.yaml`/`ecs-task-definition.yaml`/`ecs-service.yaml` — les 4 nouveaux
  templates n'ont été validés que par `cfn-lint` jusqu'ici (voir entrée
  d'historique 2026-07-27), pas encore déployés sur LocalStack.
- Les gaps de conformité listés dans `CONFORMITE_CDC.md` encore ouverts (tous
  mineurs désormais) : rétention manquante sur le log group CodeBuild, scan ECR
  non exploité par le pipeline, pas de notification spécifique
  « rollback completed », pas de stage `ManualApproval`, traffic shift en rampe
  linéaire au lieu des paliers 10/50/100 %, protection de branche GitHub à
  activer côté réglages du dépôt.
- L'application ne LIT encore aucun des secrets injectés (`DB_USERNAME`,
  `DB_PASSWORD`, `API_KEY` sont disponibles dans le conteneur mais inutilisés) :
  normal, le store est en mémoire et il n'y a pas encore de base de données ni
  d'appel à un service tiers. Le mécanisme d'injection est en place et
  conforme ; son utilisation viendra avec le besoin applicatif.

(Le fichier fantôme `task-manager/ server.js` a été supprimé le 2026-07-28
lors de l'unification applicative — cf. section Application ci-dessus.)

## Prochaine étape

L'infrastructure CloudFormation est maintenant complète (6 stacks, plus
aucun template vide) et testée dans la limite de ce que LocalStack
Community permet, via une seule commande (`test7-all-local.sh`, Tests 1 à
6 enchaînés). L'EPIC Observabilité, qui restait le seul morceau
fonctionnel du cahier des charges pas encore commencé, est maintenant
couvert. La suite dépend maintenant presque entièrement de l'accès à un
vrai compte AWS, pour valider empiriquement tout ce que LocalStack n'a pas
pu vérifier :
- Le déploiement réel dans l'ordre documenté ci-dessus.
- ALB/target groups, ECS Fargate réel, CodeDeploy Blue/Green avec vrai
  traffic shift, CodePipeline déclenché par un vrai push GitHub (Test 5).
- La fonction Lambda de métriques, le rendu réel du dashboard, et le
  déclenchement effectif des 2 alarmes sur des données réelles (Test 6).
- L'injection réelle des secrets dans le conteneur par l'agent ECS (Test 8).
- Le scaling réel du nombre de tâches sous charge CPU (Test 9) : à vérifier
  avec `aws application-autoscaling describe-scaling-activities` après avoir
  généré de la charge.

Sans accès AWS, il reste néanmoins des écarts de conformité identifiés par
`CONFORMITE_CDC.md` et faisables sans compte AWS (tous en IaC ou en code) :

- Un `AWS::CodeDeploy::DeploymentConfig` personnalisé pour coller aux paliers
  10 % → 50 % → 100 % du cahier des charges (la config prédéfinie actuelle est
  une rampe linéaire).
- La rétention 30 jours manquante sur le log group CodeBuild, un stage
  `ManualApproval` (pour que l'état « approval pending » de F4 existe), et
  l'exploitation du résultat du scan ECR (US-05).
- Mettre à jour `test5-pipeline.sh` et consorts pour le découpage en 4
  templates ECS/ALB du 2026-07-27 (seul `test2-codebuild.sh` a été réaligné,
  lors de l'unification applicative du 2026-07-28).

## Historique des mises à jour de ce fichier

- 2026-07-23 — création initiale, après l'ajout du Test 2 (CodeBuild local).
- 2026-07-23 — ajout et validation du Test 3 (`vpc.yml` + `test3-vpc.sh`) :
  bugs corrigés dans le script de test (chemin de fichier, démarrage
  LocalStack, non-blocage sur l'échec attendu du NAT Gateway) ; `vpc.yml`
  lui-même n'a nécessité aucune correction.
- 2026-07-24 — ajout et validation du Test 4 (`iam.yaml` +
  `test4-iam.sh`) : une lacune réelle trouvée et corrigée dans
  `CodePipelineServiceRole` (permissions manquantes pour l'action
  CodePipeline `CodeDeployToECS`), confirmée par comparaison avec la
  documentation IAM officielle d'AWS pour ce provider. Bugs de script
  corrigés (mêmes patterns de robustesse LocalStack que Test 3). Découverte
  d'une nouvelle limite LocalStack Community : `AWS::CodeBuild::Project` est
  Pro-only (comme `CodeStarConnections`), contournée dans le script de test.
- 2026-07-24 — ajout et validation du Test 5 (`pipeline.yml` +
  `test5-pipeline.sh`) : `pipeline.yml` rempli en une seule stack
  (CodePipeline + CodeDeploy Blue/Green + ALB + ECS Fargate, pas de
  `ecs.yaml` séparé — voir justification dans le Test 5). Mis à jour en
  même temps : `codebuild.yaml` (2 env vars), `buildspec.yml` (génération
  `imageDetail.json`/`taskdef.json`), ajout de
  `task-manager/taskdef.template.json` et `task-manager/appspec.yaml`.
  Découverte de deux nouvelles limites LocalStack Community : 4 services
  entiers non implémentés (`elbv2`, `ecs`, `codedeploy`, `codepipeline` —
  11 des ~17 ressources du template), et les règles `SecurityGroupIngress`
  inline non appliquées même quand le service EC2 est par ailleurs supporté.
  Plus aucun template CloudFormation du projet n'est vide.
- 2026-07-24 — ajout et validation du Test 6 (`observability.yml` +
  `test6-observability.sh`) : EPIC CICD-EP-04 (Observabilité) complété —
  Lambda de métriques custom (durée/succès/échec du pipeline, publiées via
  une règle EventBridge dédiée), dashboard CloudWatch (7 widgets : pipeline,
  CodeBuild, ECS, ALB), 2 alarmes (durée > 15 min, échec) notifiant le topic
  SNS existant, abonnement email optionnel. Contrairement aux Tests 2/4/5,
  CloudWatch et Lambda sont supportés par LocalStack Community — la seule
  vraie limite trouvée est un bug de compatibilité CLI (`aws cloudwatch ...`
  échoue, mais la création via CloudFormation fonctionne) et un pull Docker
  trop lent pour la fonction Lambda (contournée en la retirant de la copie
  de test, comme pour l'image CodeBuild au Test 2). 2 outputs ajoutés à
  `pipeline.yml` (`AlbFullName`, `BlueTargetGroupFullName`), nécessaires
  pour les dimensions CloudWatch de l'ALB. C'était le dernier composant
  d'infrastructure identifié dans le cahier des charges qui n'existait pas
  encore : les 6 stacks CloudFormation du projet sont maintenant toutes
  remplies et testées dans la limite de LocalStack Community.
- 2026-07-24 — ajout et validation du Test 7 (`test7-all-local.sh`) :
  orchestrateur qui enchaîne les Tests 1 à 6 en une seule commande avec
  rapport récapitulatif (statut + durée), là où chaque template ne se
  validait auparavant qu'individuellement. Deux bugs réels révélés en
  chaînant les scripts, invisibles quand chacun tournait seul : collision
  de nom de stack `taskmanager-vpc-test` entre `test3-vpc.sh` et
  `test5-pipeline.sh` (corrigée par un `delete-stack` défensif ajouté à
  `test5-pipeline.sh`), et l'étape de rejeu `buildspec.yml` de
  `test2-codebuild.sh` beaucoup trop lente pour un run global (corrigée par
  une nouvelle variable `SKIP_BUILDSPEC_REPLAY`). Exécution complète
  confirmée : 6/6 tests PASS, 597s au total, aucune erreur cachée.
- 2026-07-27 — refactor sur la branche `deployment/ecs-fargate` : extraction
  de l'ALB, des 2 target groups Blue/Green, des security groups, et du
  cluster/task definition/service ECS hors de `pipeline.yml`, vers 4
  nouveaux templates dédiés (`ecs-cluster.yaml` avec Container Insights
  activé, `alb.yaml` avec listener HTTPS conditionnel préparé pour plus
  tard, `ecs-task-definition.yaml` avec `ContainerImage` paramétrable,
  `ecs-service.yaml`). `pipeline.yml` ne garde que l'orchestration CI/CD
  (bucket S3, SNS, CodeDeploy Application/DeploymentGroup, CodePipeline) et
  référence les 4 nouvelles stacks par `Fn::ImportValue`. Les exports déjà
  consommés par `observability.yml` ont été déplacés vers les nouvelles
  stacks sous le MÊME nom (`-alb-full-name`, `-tg-blue-full-name`,
  `-ecs-cluster-name`, `-ecs-service-name`) : `observability.yml` n'a requis
  aucune modification. `iam.yaml` inchangé (déjà conforme : rôles
  d'exécution/applicatif ECS déjà présents et commentés). Les 5 nouveaux/
  modifiés templates passent `cfn-lint` sans erreur (seuls des warnings
  W6001 attendus sur les outputs pass-through de `pipeline.yml`) ; pas
  encore redéployés sur LocalStack sous ce nouveau découpage.
- 2026-07-28 — **unification sur une application unique** (Node.js/Express),
  suite au constat bloquant du rapport de conformité. Le CRUD de l'app Flask
  (liste, ajout, bascule, suppression, UI HTML) a été porté vers Express en 3
  modules (`src/app.js`, `src/tasks.js` store en mémoire, `src/views.js` rendu
  HTML sans dépendance), puis l'app Flask et tous les doublons supprimés
  (`src/app.py`, `templates/index.html`, `requirements.txt`, `tasks.db`,
  `Dockerfile` racine single-stage, `package.json`/`package-lock.json` racine,
  fichier fantôme `task-manager/ server.js`). `.github/workflows/ci.yml`
  réécrit : il ne fait plus un `py_compile` d'une app que rien ne déployait,
  mais exécute les mêmes gates que `buildspec.yml` (SAST Semgrep, tests,
  seuil de couverture 80 %), publie le rapport JUnit + la couverture HTML en
  artefacts (US-02), build l'image et mesure sa taille — et se déclenche aussi
  sur `feature/**` en Build+Test seulement (F1). Trois bugs réels trouvés au
  passage et corrigés : le `BuildSpec:` de `codebuild.yaml` pointait vers un
  chemin inexistant (le build aurait échoué avant `install`), le
  `taskdef.template.json` réellement déployé perdait le health check du
  conteneur dont dépend le rollback Blue/Green, et `NODE_ENV` recevait
  `dev`/`prod` en écrasant le `production` du Dockerfile. Vérifié : 29 tests
  passent, 100 % de couverture, image mesurée à **48 Mo** (< 200 Mo), CRUD
  complet exercé en direct contre le conteneur (ajout → API → bascule →
  suppression), `HEALTHCHECK` Docker à `healthy`, `cfn-lint` propre, et
  `test2-codebuild.sh` repasse (exit 0).
- 2026-07-28 — création de `CONFORMITE_CDC.md` : audit de conformité du
  dépôt par rapport au cahier des charges fourni (tableaux exigence par
  exigence pour §1.3, F1-F4, US-01 à US-05, §4.2, plus une liste priorisée
  de ce qu'il reste à faire). Deux manques structurels identifiés : Secrets
  Manager non câblé (IAM seul, aucun secret réel ni bloc `Secrets:`) et
  auto-scaling ECS totalement absent. Confirme aussi l'incohérence
  applicative déjà connue (pipeline construit autour du stub Express, pas
  de l'app Flask réelle) et le fait qu'aucun déploiement AWS réel n'a
  encore eu lieu.
- 2026-07-28 — **Secrets Manager câblé de bout en bout** (F3 du cahier des
  charges) : nouvelle stack `secrets-manager.yaml` (2 secrets, valeurs
  **générées par AWS** via `GenerateSecretString` — aucune donnée sensible
  dans le dépôt, ni dans les paramètres CloudFormation), bloc `Secrets:`
  ajouté aux **deux** task definitions (`ecs-task-definition.yaml` pour le
  bootstrap ET `taskdef.template.json` pour tous les déploiements réels du
  pipeline), et permissions du rôle d'exécution ECS documentées/vérifiées
  (`secretsmanager:GetSecretValue` était déjà présent et son wildcard couvre
  bien le suffixe aléatoire des ARN — vérifié par correspondance de motif ;
  pas de `kms:Decrypt` nécessaire avec la clé gérée par AWS, désormais
  explicitement commenté). Les 3 variables `DB_USERNAME`/`DB_PASSWORD`/
  `API_KEY` arrivent dans le conteneur sans qu'aucune valeur ne transite en
  clair : seuls des ARN circulent, de `secrets-manager.yaml` vers
  `codebuild.yaml` (variables d'environnement) puis vers `taskdef.json`.
  Un garde-fou a été ajouté dans `buildspec.yml` : le build échoue tôt et
  explicitement si les ARN sont vides, au lieu de produire un `taskdef.json`
  avec des placeholders non substitués qui casserait le déploiement ECS bien
  plus loin. Nouveau `test8-secrets.sh` (chaîné dans `test7-all-local.sh`,
  qui passe donc de 6 à 7 tests) : ✅ exit 0 — Secrets Manager est supporté
  par LocalStack Community, les 2 secrets se créent, la structure JSON
  `username`/`password` du secret DB est confirmée (c'est elle qui rend
  valide la syntaxe `<arn>:password::`), la longueur et les caractères exclus
  du mot de passe généré sont vérifiés, et les 4 exports attendus sont
  présents. Au passage : les notes d'ordre de déploiement des templates
  étaient incohérentes entre fichiers (`iam.yaml` listait encore un
  `ecs.yaml` inexistant, `observability.yml` une liste de 6 stacks
  pré-refactor) et le tableau de `infrastructure/README.md` annonçait
  toujours « les 6 stacks » — tout est normalisé sur une liste de référence
  unique de 11 stacks. `cfn-lint` propre sur les 11 templates (seuls les
  W6001 pré-existants et attendus sur les outputs pass-through de
  `pipeline.yml` subsistent). L'application ne lit pas encore ces secrets
  (store en mémoire, pas de base de données) : le mécanisme d'injection est
  en place et conforme, son usage viendra avec le besoin applicatif.
- 2026-07-28 — **Auto scaling ECS ajouté** (F3 : « le nombre de tâches Fargate
  scale automatiquement selon la charge CPU ») : nouvelle stack
  `ecs-autoscaling.yaml` — `ScalableTarget` sur `ecs:service:DesiredCount`
  (2 à 6 tâches), `ScalingPolicy` **Target Tracking** sur
  `ECSServiceAverageCPUUtilization` avec **cible 70 %**, scale-in activé,
  cooldowns asymétriques (60 s out / 300 s in pour éviter le battement), et
  2 alarmes CloudWatch notifiant le topic SNS existant (CPU soutenu > 85 %,
  capacité maximale atteinte via `RunningTaskCount`). **Aucune modification de
  `iam.yaml` nécessaire** : Application Auto Scaling utilise son rôle lié au
  service. Target Tracking a été préféré à Step Scaling parce que c'est
  l'approche recommandée par AWS et celle qui correspond littéralement à
  l'énoncé (« cible CPU »).
  Deux pièges identifiés et documentés en tête du template plutôt que subis :
  (1) Target Tracking crée ses **propres** alarmes internes — les 2 alarmes de
  ce template servent à prévenir l'équipe, pas à scaler, et ne doivent surtout
  pas être câblées à une policy ; (2) le `DesiredCount` de `ecs-service.yaml`
  n'est plus qu'une valeur **initiale** dès que le ScalableTarget est attaché —
  une mise à jour de cette stack peut le réinitialiser transitoirement, et
  Application Auto Scaling le corrige ensuite. La note est reprise dans la
  description du paramètre `DesiredCount` et dans `infrastructure/README.md`.
  Le widget ECS du dashboard affiche maintenant `RunningTaskCount` sur l'axe
  de droite avec une annotation à 70 % : le scaling devient visible (CPU qui
  monte → tâches qui suivent), ce qui rend l'exigence F3 observable et pas
  seulement déclarée. Nouveau `test9-autoscaling.sh` (chaîné dans
  `test7-all-local.sh`, qui passe de 7 à 8 tests) : ✅ exit 0, 22 vérifications
  structurelles. Volontairement **statique** et non déployé — ni
  `application-autoscaling` ni `ecs` ne sont émulés par LocalStack Community,
  un déploiement échouerait pour des raisons d'émulation et n'apprendrait rien
  (voir Test 9 pour la liste des vérifications, dont la cohérence des seuils
  entre stacks). `cfn-lint` propre sur les 12 templates, JSON du dashboard
  revalidé (8 widgets). Ordre de déploiement porté à 12 stacks
  (`ecs-autoscaling.yaml` en 11ᵉ : après `ecs-service.yaml` dont elle scale le
  service, et après `pipeline.yml` dont elle importe le topic SNS).
- 2026-07-28 — **quality gates de couverture renforcés** (F2 / US-02). Les
  tests portaient déjà sur l'application réellement déployée depuis
  l'unification ; cette passe a ajouté les rapports manquants et corrigé deux
  défauts réels. (1) `buildspec.yml` passait
  `--coverageReporters=json-summary --coverageReporters=text`, ce qui
  **écrasait** la liste de `jest.config.js` : CodeBuild ne générait donc
  **jamais** le rapport HTML, et US-02 (« un rapport HTML de couverture est
  disponible dans les artefacts CodeBuild ») était littéralement
  insatisfiable — option supprimée, `jest.config.js` redevient la source de
  vérité unique. (2) Aucun rapport de couverture n'était exporté : ajout d'un
  report group `code-coverage` au format **COBERTURAXML** (CodeBuild l'affiche
  nativement avec l'évolution entre builds) et d'une archive
  `coverage-html.tar.gz` dans les artefacts — nécessaire parce que les
  artefacts sont aplatis par `discard-paths`, imposé par `CodeDeployToECS`.
  Ajout du reporter `cobertura` (il n'existait aucun XML de couverture) et
  d'un `coverageThreshold` global à 80 % dans Jest, pour que `npm test`
  échoue de lui-même, y compris en local, avant la CI. `ci.yml` publie
  désormais HTML + XML + JUnit en artefacts et écrit la couverture dans le
  résumé du job. 2 tests ajoutés sur du comportement réel non exercé
  jusque-là (création via corps JSON — `express.json()` est monté mais aucun
  test ne l'empruntait — et 404 sur route inconnue) : **29 tests**, 100 % de
  couverture.
  **Le gate a été vérifié empiriquement**, ce qui n'avait jamais été fait : en
  injectant temporairement un module non testé dans `src/`, la couverture
  tombe à **61,81 %**, Jest sort en code 1 avec un message explicite, et le
  contrôle shell des deux CI bloque aussi ; le module a ensuite été retiré et
  le projet est revenu à 29 tests / 100 %. Vérifié également : XML Cobertura
  bien formé, HTML présent, archivage `tar` fonctionnel, YAML des deux CI
  valide, `.gitignore` complété, et `test2-codebuild.sh` repasse (exit 0).
  Note : `pytest.ini`/`requirements.txt` ne s'appliquent pas, le projet est
  unifié sur Node.js/Express (Jest + Supertest).
