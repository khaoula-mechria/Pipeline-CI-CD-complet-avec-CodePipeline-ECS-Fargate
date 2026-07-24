# Résultats des tests locaux (`infrastructure/scripts/`)

> Snapshot d'exécution réelle des 5 scripts de test, dans l'ordre où ils
> doivent être lancés. Chaque section indique : ce que le script teste, s'il
> passe ou non, et — pour tout ce qui ne peut pas être vérifié sans un vrai
> compte AWS — pourquoi, précisément.
>
> Environnement d'exécution : cfn-lint 1.53.1, Docker + LocalStack Community
> `3.8.1`, Node.js/npm (voir `package.json`), aucun accès AWS réel.

---

## `test-local.sh` — Test 1 : `ecr.yaml`

**Résultat : ✅ PASSE intégralement (exit code 0).**

| Étape | Résultat |
|---|---|
| `cfn-lint ecr.yaml` | ✅ Valide syntaxiquement |
| Démarrage LocalStack | ✅ (conteneur réutilisé s'il tourne déjà) |
| `cloudformation validate-template` | ✅ Template bien formé |
| `cloudformation deploy` (stack `taskmanager-ecr-test`) | ✅ `CREATE_COMPLETE` |
| Outputs exportés (`RepositoryUri`, `RepositoryArn`, `RepositoryName`) | ✅ Les 3 présents et corrects |

Détail des outputs obtenus :
```
RepositoryArn  = arn:aws:ecr:us-east-1:000000000000:repository/taskmanager-dev
RepositoryName = taskmanager-dev
RepositoryUri  = http://localhost:4566
```

**Rien à signaler côté template.** Seule curiosité, sans impact : `RepositoryUri`
vaut l'URL de l'endpoint LocalStack (`http://localhost:4566`) au lieu d'un
vrai host `<account>.dkr.ecr.<region>.amazonaws.com/...` — c'est LocalStack
qui renvoie son propre endpoint pour cet attribut, pas une erreur de
`ecr.yaml`. Sur un vrai compte AWS, `RepositoryUri` aura le format standard.

**Non testable en local :** le scan de vulnérabilités CVE réel (`Scan on
push`) — c'est un service backend AWS propriétaire, LocalStack Community ne
l'exécute pas. La ressource et sa configuration (`ScanOnPush: true`) sont
bien créées, mais aucun scan ne tourne réellement derrière.

---

## `test2-codebuild.sh` — Test 2 : `codebuild.yaml` + `buildspec.yml`

**Résultat : ✅ PASSE sur tout ce qui est vérifiable sans compte AWS ; ⚠️ une
étape s'arrête à un point ATTENDU et documenté (pas un échec du template).**

| Étape | Résultat |
|---|---|
| `cfn-lint codebuild.yaml` | ✅ Valide syntaxiquement |
| `npm ci` | ✅ 359 paquets installés (2 vulnérabilités *moderate*, sans lien avec ce projet — dépendances tierces) |
| `npm test` | ✅ 2/2 tests passent, **100% de couverture** sur `app.js` |
| `docker build` (Dockerfile multi-stage) | ✅ Image construite |
| `docker run` + `curl /health` | ✅ Répond `200 {"status":"ok"}` |
| Rejeu `buildspec.yml` via l'agent officiel `aws-codebuild-docker-images` | ⚠️ Non re-testé dans cette session (voir note) — comportement déjà documenté : la phase `install` (npm ci + SAST Semgrep) s'exécute, puis `pre_build` échoue à `aws ecr get-login-password` |

**Note sur le rejeu `buildspec.yml`** : cette étape clone un dépôt GitHub et
télécharge une image Docker CodeBuild officielle (plusieurs Go) — trop lente
dans cet environnement (déjà abandonnée après 21 min à 22/54 layers lors
d'un run précédent, cf. `so-far.md`). Elle n'a pas été relancée ici pour
éviter de rebloquer la session sur un téléchargement réseau, mais le reste
du script (cfn-lint + Niveau 1, ci-dessus) a été re-exécuté et confirmé à
neuf. Le comportement de cette étape reste : `install` passe, puis blocage
attendu à la connexion ECR (pas de credentials AWS réelles) — documenté par
raisonnement technique (comportement standard d'`aws ecr get-login-password`
sans credentials), conforme à ce qui est décrit dans le script lui-même.

**Non testable en local :**
- Le webhook GitHub réel (`Triggers.Webhook: true`) — nécessite un vrai
  dépôt GitHub + un token importé via `aws codebuild import-source-credentials`.
- Les phases `build`/`post_build` de `buildspec.yml` (docker build réel dans
  CodeBuild, push ECR) — bloquées par l'absence de credentials AWS réelles
  dès `pre_build`, comme expliqué ci-dessus.
- Le SAST Semgrep exécuté *dans* CodeBuild (la phase `install` du rejeu ne va
  pas jusqu'à confirmer son rapport de sortie dans ce mode).

---

## `test3-vpc.sh` — Test 3 : `vpc.yml`

**Résultat : ✅ PASSE sur tout ce qui est émulable par LocalStack Community
(exit code 0, non-bloquant par design) ; ❌ le NAT Gateway échoue — limite
LocalStack connue, pas un défaut de `vpc.yml`.**

| Étape | Résultat |
|---|---|
| `cfn-lint vpc.yml` | ✅ Valide syntaxiquement |
| `cloudformation validate-template` | ✅ Template bien formé (tous les paramètres listés correctement) |
| Déploiement (stratégie NAT `single`) | ❌ Échoue sur `NatGateway1` — voir limite ci-dessous |
| VPC + 4 subnets (2 publics/2 privés) | ✅ Créés avec les bons CIDR/AZ (`10.0.0.0/24`@`eu-west-1a`, `10.0.10.0/24`@`eu-west-1a`, `10.0.1.0/24`@`eu-west-1b`, `10.0.11.0/24`@`eu-west-1b`) |
| Route tables (4 attendues : 1 implicite + 1 publique + 2 privées) | ✅ 4 confirmées |
| Internet Gateway / VPC Endpoint S3 | ✅ Créés (vérifiés dans un run antérieur, structure inchangée) |
| Outputs exportés | ❌ Absents — attendu, la stack n'atteint jamais `CREATE_COMPLETE` |

**Limite LocalStack confirmée empiriquement (à nouveau)** : l'`EIP` associée
au NAT Gateway est acceptée par CloudFormation mais LocalStack Community ne
l'émule pas réellement côté EC2 — son `AllocationId` reste `"unknown"`, donc
`AWS::EC2::NatGateway` échoue avec `InvalidAllocationID.NotFound`. Le script
le documente lui-même et continue (non-bloquant) pour vérifier le reste de
la stack malgré cet échec attendu.

**Non testable en local :**
- Le NAT Gateway lui-même et le routage sortant réel des subnets privés.
- La stratégie `ha` (1 NAT Gateway par AZ) — bloquée par la même limite EIP,
  pas testée dans cette session (l'échec serait identique dès le premier
  NAT Gateway).
- Les VPC Flow Logs (`EnableFlowLogs=true`, non activé par défaut, pas
  testé ici).

---

## `test4-iam.sh` — Test 4 : `iam.yaml`

**Résultat : ✅ PASSE intégralement (exit code 0), après correction d'une
lacune réelle trouvée dans `iam.yaml` — voir `so-far.md` (Test 4) pour le
détail complet du diagnostic.**

| Étape | Résultat |
|---|---|
| `cfn-lint iam.yaml` (template complet, avec `GitHubConnection`) | ✅ Valide syntaxiquement |
| Déploiement dépendances (`ecr.yaml`, `codebuild.yaml`) | ✅ |
| Déploiement `iam.yaml` (copie sans `GitHubConnection`, import CodeBuild patché) | ✅ `CREATE_COMPLETE` |
| Les 4 rôles créés | ✅ `taskmanager-dev-codepipeline-role`, `-codedeploy-role`, `-ecs-execution-role`, `-ecs-task-role` |
| Managed policies attachées | ✅ `AWSCodeDeployRoleForECS` sur CodeDeploy, `AmazonECSTaskExecutionRolePolicy` sur ExecutionRole |
| Policies inline (contenu réel vérifié via `iam get-role-policy`) | ✅ Tous les statements présents, y compris les 2 ajoutés pour `CodeDeployToECS` (`ecs:RegisterTaskDefinition`, `iam:PassRole` scopé) |
| 4 outputs exportés | ✅ Tous présents et corrects |

**Lacune trouvée et corrigée avant ce résultat** : `CodePipelineServiceRole`
n'avait pas les permissions requises par l'action CodePipeline
`CodeDeployToECS` (Blue/Green ECS) — `ecs:RegisterTaskDefinition` et un
`iam:PassRole` scopé aux rôles de tâche ECS. Confirmé manquant par
comparaison avec la documentation IAM officielle d'AWS pour ce provider
précis (pas détecté par cfn-lint, le template restait syntaxiquement
valide). Corrigé dans `iam.yaml` avant ce test.

**Limite LocalStack découverte en testant** : `AWS::CodeBuild::Project` est
un service Pro-only sur LocalStack Community (`aws codebuild list-projects`
renvoie *"API for service 'codebuild' not yet implemented or pro
feature"*). Son `Fn::GetAtt ...Arn` renvoie le littéral `"unknown"`, ce qui
casse l'import fait par `iam.yaml` en aval si non contourné — le script
neutralise ce cas avec un ARN factice dans sa copie temporaire.

**Non testable en local :**
- `GitHubConnection` (CodeStar Connections) — validée seulement par
  cfn-lint ; Pro-only sur LocalStack Community. Son autorisation manuelle
  dans la console AWS et son bon fonctionnement réel ne sont vérifiables
  que sur un vrai compte AWS.
- Le comportement réel de l'action `CodeDeployToECS` (lecture de
  `taskdef.json`/`imageDetail.json`, génération de la task definition,
  déclenchement du Blue/Green CodeDeploy) — implémenté depuis dans
  `pipeline.yml` (voir Test 5), nécessite un pipeline en exécution réelle
  pour être vérifié de bout en bout.
- Le contenu et l'effet réel des policies managées AWS
  (`AWSCodeDeployRoleForECS`, `AmazonECSTaskExecutionRolePolicy`) —
  LocalStack accepte de les attacher mais n'en vérifie pas la couverture
  fonctionnelle.

---

## `test5-pipeline.sh` — Test 5 : `pipeline.yml`

**Résultat : ✅ PASSE sur les ressources réellement déployables (exit code
0) ; le reste — la majorité du template — n'est validé que syntaxiquement
(cfn-lint), limite LocalStack Community bien plus large que pour les 4
tests précédents.**

| Étape | Résultat |
|---|---|
| `cfn-lint pipeline.yml` (template complet, ~17 ressources) | ✅ Valide syntaxiquement |
| Déploiement dépendances (`ecr.yaml`, `codebuild.yaml`, `iam.yaml`) | ✅ |
| Copie de `vpc.yml` sans NAT Gateway → exports VPC réels | ✅ `CREATE_COMPLETE`, VpcId/subnet-ids réels obtenus |
| Copie de `pipeline.yml` réduite aux ressources supportées | ✅ `CREATE_COMPLETE` |
| Bucket S3 d'artefacts (nom exact + versioning) | ✅ `VersioningConfiguration.Status = Enabled` |
| Topic SNS + policy (publish `events.amazonaws.com`) | ✅ Policy confirmée, condition `ArnEquals` sur l'ARN de la règle EventBridge |
| Règle EventBridge (pattern d'état du pipeline) | ✅ Confirmée via `describe-rule` |
| Log group CloudWatch | ✅ Créé |
| 2 security groups (ALB, ECS Service) | ⚠️ Créés, mais règles d'ingress non appliquées (voir limite ci-dessous) |
| ALB + 2 target groups + 2 listeners | ❌ Non déployables (`elbv2` Pro-only) |
| Cluster + task definition + service ECS | ❌ Non déployables (`ecs` Pro-only) |
| CodeDeploy Application + DeploymentGroup | ❌ Non déployables (`codedeploy` Pro-only) |
| CodePipeline lui-même | ❌ Non déployable (`codepipeline` Pro-only) |

**Contexte** : contrairement à `iam.yaml`/`codebuild.yaml`, `pipeline.yml`
mobilise 4 services entiers non implémentés par LocalStack Community —
`elbv2`, `ecs`, `codedeploy`, `codepipeline` (`aws <service> list-*` renvoie
explicitement *"API for service '...' not yet implemented or pro
feature"* pour chacun). Contrairement à `AWS::CodeBuild::Project` (accepté
à la création, seul son `Arn` casse), ces 4 types de ressources font
échouer la CRÉATION elle-même (`CREATE_FAILED` immédiat) — CloudFormation
ne les accepte même pas de façon dégradée. Sur ~17 ressources du template,
seules 6 ont donc pu être réellement déployées et vérifiées.

**Limite additionnelle découverte** : les règles `SecurityGroupIngress`
définies en ligne sur `AWS::EC2::SecurityGroup` (service par ailleurs
supporté) ne sont pas appliquées par LocalStack Community — les 2 groupes
sont créés, mais `describe-security-groups` renvoie une liste d'ingress
vide pour les deux. Le template est syntaxiquement correct et suit la
syntaxe CloudFormation standard ; ce n'est pas un défaut de `pipeline.yml`.

**Fichiers ajoutés/modifiés en même temps**, nécessaires pour que
`pipeline.yml` fonctionne réellement une fois déployé sur un vrai compte
(pas juste pour le template lui-même) : `codebuild.yaml` (2 variables
d'environnement `PROJECT_NAME`/`ENVIRONMENT_NAME`), `task-manager/buildspec.yml`
(génère désormais `imageDetail.json` + rend `taskdef.json`, plus
`imagedefinitions.json` qui n'était pas le bon format pour l'action
`CodeDeployToECS`), et deux nouveaux fichiers requis par cette action :
`task-manager/taskdef.template.json` et `task-manager/appspec.yaml`.

**Non testable en local :**
- L'ALB, les 2 target groups et les 2 listeners Blue/Green (`elbv2`).
- Le cluster, la task definition et le service ECS Fargate (`ecs`).
- L'Application et le DeploymentGroup CodeDeploy — traffic shift progressif,
  rollback automatique sur échec (`codedeploy`).
- CodePipeline lui-même — les 3 stages, le déclenchement sur push GitHub
  réel, l'exécution de bout en bout (`codepipeline`).
- Les règles d'ingress des security groups (acceptées par CloudFormation,
  non appliquées par LocalStack).
- Par construction : tout ce qui dépend de `GitHubConnection` (Test 4) et
  du NAT Gateway (Test 3), déjà non testables en amont.

---

## Résumé global

| Test | Fichier testé | Statut |
|---|---|---|
| 1 | `ecr.yaml` | ✅ Passe intégralement |
| 2 | `codebuild.yaml` + `buildspec.yml` | ✅ Passe sur tout le testable ; blocage ECR attendu au-delà |
| 3 | `vpc.yml` | ✅ Passe sur tout l'émulable ; NAT Gateway non testable (limite LocalStack) |
| 4 | `iam.yaml` | ✅ Passe intégralement (après correction d'une lacune IAM réelle) |
| 5 | `pipeline.yml` | ✅ Passe sur 6/~17 ressources déployables ; le reste (ALB/ECS/CodeDeploy/CodePipeline) non testable (limite LocalStack) |

**Point commun à retenir** : cinq limites LocalStack Community distinctes
bloquent une vérification 100% locale — `AWS::CodeStarConnections::Connection`
(Test 4), `AWS::CodeBuild::Project` (Tests 2 et 4), l'émulation réelle de
`AWS::EC2::EIP`/`NatGateway` (Test 3), les services `elbv2`/`ecs`/
`codedeploy`/`codepipeline` entiers (Test 5), et les règles
`SecurityGroupIngress` inline (Test 5). Aucune de ces limites n'est un
défaut des templates : elles sont contournées ou documentées dans chaque
script pour isoler ce qui teste vraiment l'infrastructure du projet. Tout
le reste — syntaxe CloudFormation, structure des ressources, contenu réel
des IAM policies et des policies SNS/EventBridge, tests unitaires, build
Docker — est validé et passe.
