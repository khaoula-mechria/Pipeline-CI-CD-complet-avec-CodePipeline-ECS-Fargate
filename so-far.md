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
- **`infrastructure/cloudformation/pipeline.yml`** — rempli. Une seule stack
  qui assemble tout ce qui restait : bucket S3 d'artefacts + topic SNS +
  règle EventBridge de notification (F4), 2 security groups, ALB + 2 target
  groups (Blue/Green) + 2 listeners (prod/test), cluster ECS Fargate +
  Task Definition (bootstrap) + Service (`DeploymentController: CODE_DEPLOY`),
  CodeDeploy Application + DeploymentGroup (Blue/Green, traffic shift
  `ECSLinear10PercentEvery1Minute`, rollback automatique sur échec), et
  CodePipeline (Source GitHub → Build CodeBuild → Deploy CodeDeployToECS).
  Pas de `ecs.yaml` séparé : le service ECS est créé directement ici.
  Importe les 4 rôles + la connexion GitHub de `iam.yaml`, le VPC/subnets de
  `vpc.yml`, le repo ECR de `ecr.yaml`, et référence le projet `codebuild.yaml`
  par convention de nommage. Validé via
  `infrastructure/scripts/test5-pipeline.sh` — voir **Test 5** ci-dessous.

### Application (`task-manager/`, Node.js/Express)

- `src/app.js` + `server.js` — API minimale (`/health`, `/api/tasks`).
- `tests/health.test.js` — tests unitaires (Jest + Supertest), 100% de
  couverture sur `app.js`.
- `Dockerfile` — build multi-stage (< 200 Mo), image de prod sans
  devDependencies, exécution en utilisateur non-root, `HEALTHCHECK` intégré.
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

## Pas encore fait

- Déploiement réel sur AWS (aucun accès AWS pour l'instant) : import du token
  GitHub (`aws codebuild import-source-credentials`), autorisation manuelle
  de `GitHubConnection`, déploiement réel des 5 stacks dans l'ordre
  (`vpc.yml` → `ecr.yaml` → `iam.yaml` → `codebuild.yaml` → `pipeline.yml`),
  premier passage du pipeline de bout en bout (Source → Build → Deploy
  Blue/Green) — rien de tout cela n'est vérifiable sans compte AWS réel, vu
  l'étendue des limites LocalStack Community documentées dans le Test 5.
- Fichier fantôme connu mais non traité : `task-manager/ server.js` (avec un
  espace en début de nom, vide, tracké dans git) — doublon de
  `task-manager/server.js`, à nettoyer un jour.
- Dashboard CloudWatch + alarmes (EPIC CICD-EP-04 du cahier des charges,
  hors `pipeline.yml` : métriques custom, widgets, alarme si pipeline
  > 15 min) — pas encore commencé.

## Prochaine étape

L'infrastructure CloudFormation est maintenant complète et testée dans la
limite de ce que LocalStack Community permet (Tests 1 à 5). Il ne reste
plus de template CloudFormation vide. Deux chemins possibles pour la suite,
selon ce qui devient disponible en premier :
1. **Accès à un vrai compte AWS** : dérouler le déploiement réel dans
   l'ordre documenté ci-dessus, en particulier valider empiriquement tout
   ce que LocalStack n'a pas pu vérifier (ALB/target groups, ECS
   Fargate réel, CodeDeploy Blue/Green avec vrai traffic shift,
   CodePipeline déclenché par un vrai push GitHub).
2. **Sans accès AWS pour l'instant** : avancer sur l'EPIC Observabilité
   (dashboard CloudWatch + alarmes, CICD-EP-04 du cahier des charges) —
   c'est la seule brique fonctionnelle qui n'existe dans aucun template
   actuel et qui reste largement testable en local (CloudWatch Logs/metrics
   sont supportés par LocalStack Community, contrairement à ELBv2/ECS/
   CodeDeploy/CodePipeline).

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
