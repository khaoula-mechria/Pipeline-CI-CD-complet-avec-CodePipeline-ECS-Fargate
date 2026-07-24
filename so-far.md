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

## Pas encore fait

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

L'IAM (`iam.yaml`) est maintenant en place et testé (Test 4). Prochaine
étape logique : **`pipeline.yml`**, qui peut désormais importer les 4 ARNs
de rôles exportés par `iam.yaml`, les exports de `vpc.yml` (subnets, VPC
id) et de `ecr.yaml`/`codebuild.yaml` (repo, projet build), pour assembler
CodePipeline (stages Source/Build/Deploy) + les ressources CodeDeploy
(Application + DeploymentGroup Blue/Green) + le service ECS Fargate (+ ALB
si pas déjà prévu ailleurs). Points à garder en tête en écrivant
`pipeline.yml` (contraintes déjà posées par `iam.yaml`) :
- Le bucket S3 d'artefacts doit s'appeler
  `${ProjectName}-${Environment}-pipeline-artifacts-${AWS::AccountId}`
  (convention attendue par `CodePipelineServiceRole`).
- L'application et le deployment group CodeDeploy doivent être préfixés
  `${ProjectName}-${Environment}-` (convention attendue par
  `CodePipelineServiceRole`/`TriggerCodeDeploy`).
- Le topic SNS de notifications doit être préfixé
  `${ProjectName}-${Environment}-`.
- L'action Deploy doit utiliser le provider `CodeDeployToECS` (pas le
  provider ECS standard) pour rester cohérent avec `CodeDeployServiceRole`
  (policy managée `AWSCodeDeployRoleForECS`, spécifique au Blue/Green ECS).

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
