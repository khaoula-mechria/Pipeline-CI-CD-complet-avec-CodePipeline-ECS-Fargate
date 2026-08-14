# Rapport de conformité au Cahier des Charges

> Audit du dépôt `Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate` par rapport au document
> *« CAHIER DES CHARGES & FONCTIONNEL — Pipeline CI/CD Complet avec AWS CodePipeline + ECS Fargate »*
> (Programme de Stages Juillet / Août 2026).

- **Date de l'audit :** 2026-07-28 — **mis à jour le 2026-07-28** après l'unification sur une application
  unique (voir la section « Historique de ce rapport » en fin de document)
- **Branche auditée :** `deployment/ecs-fargate` (la plus avancée ; `main` et les autres branches distantes
  n'ont pas les 4 templates ECS/ALB extraits)
- **Méthodologie :** lecture statique de l'intégralité du dépôt (CloudFormation, buildspec, Dockerfile,
  workflow GitHub Actions, tests, scripts). **Aucun déploiement AWS réel n'a eu lieu** — toute la validation
  documentée dans `so-far.md` est faite via `cfn-lint` et LocalStack Community, qui n'émule pas
  `AWS::CodeBuild::Project`, `AWS::CodeStarConnections::Connection`, ELBv2, ECS, CodeDeploy, ni CodePipeline
  lui-même. Les statuts ci-dessous portent donc sur la **conformité du code/IaC écrit**, pas sur un
  comportement observé en production.

Légende : ✅ Conforme · ⚠️ Partiel · ❌ Manquant

---

## Résumé exécutif

L'infrastructure CloudFormation est **structurellement complète** (12 templates couvrant VPC, IAM, Secrets Manager, ECR,
CodeBuild, cluster/service/task definition ECS, ALB Blue/Green, CodePipeline/CodeDeploy, auto scaling,
observabilité) et
la majorité des exigences F1/F2/F4 du cahier des charges sont couvertes.

✅ **L'incohérence applicative signalée par la première version de ce rapport est résolue** (2026-07-28) :
le dépôt ne contient plus qu'une seule application (Node.js/Express, `task-manager/`). Le CRUD de l'ancienne
app Flask a été porté vers Express, puis la version Flask supprimée. GitHub Actions, CodeBuild et ECS
valident et déploient désormais exactement le même code. Trois bugs réels ont été trouvés au passage et
corrigés — voir « Historique de ce rapport » en fin de document.

Il reste **un problème structurel** :

- **Aucun déploiement AWS réel** n'a jamais eu lieu (voir `so-far.md`) : CodeBuild, CodeDeploy, ECS, ALB et
  CodePipeline eux-mêmes n'ont jamais tourné, seulement été validés syntaxiquement.

✅ **L'injection des secrets via Secrets Manager est également réglée** (2026-07-28) : 2 secrets dont les
valeurs sont générées par AWS, injectés dans les deux task definitions. Aucune valeur sensible ne se trouve
dans le dépôt, dans les paramètres CloudFormation ou dans les variables d'environnement CodeBuild — seuls
des ARN y circulent.

✅ **L'auto-scaling ECS sur le CPU est également en place** (2026-07-28) : `ScalableTarget` (2 à 6 tâches) et
policy Target Tracking à 70 % de CPU, avec 2 alarmes CloudWatch et le nombre de tâches désormais visible sur
le dashboard.

✅ **Un audit complet du dépôt a été mené le 2026-08-14** (5 revues ciblées : IAM/sécurité, conformité CDC,
mécanique du pipeline, scripts LocalStack, observabilité/coûts, chaque piste revérifiée avant correction) et
a trouvé 3 bugs qui auraient chacun fait échouer un déploiement réel de bout en bout, même le tout premier,
sans qu'aucun ne soit détectable par `cfn-lint` ni par LocalStack : le chemin d'`appspec.yaml` dans
`pipeline.yml`, la policy SNS ne laissant pas passer les alarmes CloudWatch, et des permissions IAM
manquantes pour les report groups CodeBuild. Tous corrigés — voir « Historique de ce rapport ».

**Plus aucune exigence du cahier des charges n'est totalement absente de l'implémentation.** Ce qui reste
relève soit d'un déploiement AWS réel (le point bloquant ci-dessus), soit d'écarts mineurs listés en fin de
document.

---

## Tableau 1 — Stack technologique (§1.3 du CDC)

| # | Technologie | Statut | Preuve (fichier) | Commentaire |
|---|---|---|---|---|
| 1 | AWS CodePipeline | ✅ | `infrastructure/cloudformation/pipeline.yml` | 3 stages Source (CodeStarSourceConnection) → Build (CodeBuild) → Deploy (`CodeDeployToECS`). Jamais exécuté réellement. |
| 2 | Amazon ECS Fargate | ✅ | `ecs-cluster.yaml`, `ecs-service.yaml`, `ecs-task-definition.yaml` | `RequiresCompatibilities: FARGATE`, `DeploymentController: CODE_DEPLOY`. Jamais déployé réellement (ECS = Pro-only sur LocalStack). |
| 3 | AWS CodeBuild | ✅ | `infrastructure/cloudformation/codebuild.yaml`, `task-manager/buildspec.yml` | Projet + rôle IAM + buildspec complet (SAST, tests, push ECR). Le rejeu local via l'agent officiel ne va jamais jusqu'au bout (pull d'image trop lent). |
| 4 | Amazon ECR | ✅ | `infrastructure/cloudformation/ecr.yaml`, `task-manager/buildspec.yml` | Repository privé, `ScanOnPush: true`, lifecycle policy 10 images. Testé de bout en bout sur LocalStack. Le résultat du scan est désormais **exploité** par le buildspec : blocage sur CRITICAL, notification SNS sur HIGH (US-05). |
| 5 | AWS CloudFormation | ✅ | `infrastructure/cloudformation/*.yaml` | 12 templates non vides (`parameters.json` est vide, voir gaps). |
| 6 | Docker | ✅ | `task-manager/Dockerfile` | Dockerfile unique, multi-stage, non-root, `HEALTHCHECK`. Le doublon single-stage de la racine a été supprimé. Image mesurée : **48 Mo**. |
| 7 | GitHub Actions | ✅ | `.github/workflows/ci.yml` | **2 jobs parallèles.** `app` rejoue les gates de `buildspec.yml` sur la même application (npm ci, SAST Semgrep, tests Jest, seuil 80 %, build Docker + taille) et publie JUnit + couverture HTML/XML + rapport SAST en artefacts. `infra` rejoue la validation statique des scripts locaux : `cfn-lint` sur les 12 templates, validité de `appspec.yaml`/`buildspec.yml`/`taskdef.template.json`, et **dry-run du rendu de `taskdef.json`**. Ne pousse rien vers AWS (rôle volontairement limité à la protection de branche). |
| 8 | Amazon CloudWatch | ✅ | `infrastructure/cloudformation/observability.yml` | Dashboard (8 widgets, dont le nombre de tâches ECS) + 2 alarmes de pipeline, plus 2 alarmes d'auto scaling dans `ecs-autoscaling.yaml`. Testé de bout en bout sur LocalStack. |
| 9 | AWS SNS | ✅ | `pipeline.yml` (topic + policy), `observability.yml` (abonnement email optionnel) | Voir nuance sur l'état « approval pending » au Tableau 5. |

---

## Tableau 2 — F1 : Déclenchement automatique du pipeline

| Règle du CDC | Statut | Preuve | Commentaire |
|---|---|---|---|
| Push sur `main` déclenche le pipeline en <60s | ✅ | `codebuild.yaml` (webhook GitHub sur push `main`/`develop`), `pipeline.yml` (`CodeStarSourceConnection`, `BranchName: main`) | Déclenchement natif AWS, non chronométré empiriquement (jamais exécuté réellement). |
| Push sur `feature/*` ne déclenche que Build+Test | ✅ | `.github/workflows/ci.yml` (`push: [..., 'feature/**']`) | Le workflow s'exécute sur `feature/**` et n'y fait que Build et Test : il ne pousse aucune image et ne touche jamais à AWS. Le stage Deploy reste l'affaire de CodePipeline, câblé sur `main` uniquement. |
| PR vers `main` doit passer les quality gates avant merge | ✅ | `.github/workflows/ci.yml` | Sur `pull_request` vers `main`/`develop`, les 2 jobs s'exécutent : `app` (SAST Semgrep bloquant, tests, seuil de couverture 80 % bloquant, build Docker) et `infra` (`cfn-lint` bloquant sur les 12 templates, validité des manifestes de déploiement, dry-run du rendu de `taskdef.json`). Aucun filtre de chemin, volontairement : un job conditionné qui ne démarre pas bloquerait indéfiniment une PR s'il était déclaré obligatoire. Reste à activer la protection de branche côté GitHub pour rendre les 2 jobs **obligatoires** au merge (réglage d'interface, hors dépôt). |
| Déclenchement manuel via console/CLI reste possible | ✅ | — | Capacité native de CodePipeline/CodeBuild, aucun blocage identifié dans l'IaC. |

---

## Tableau 3 — F2 : Stage Build & Test

| Règle du CDC | Statut | Preuve | Commentaire |
|---|---|---|---|
| Dockerfile multi-stage, image finale < 200 Mo | ✅ | `task-manager/Dockerfile` | Multi-stage (`build` → `production`), image de prod sans devDependencies, utilisateur non-root, `HEALTHCHECK`. **Taille réellement mesurée : 48 Mo**, soit très en dessous de la cible de 200 Mo (première mesure effective du projet). Le doublon single-stage de la racine a été supprimé. |
| Tests unitaires ≥80% de couverture, rapport JUnit exporté | ✅ | `task-manager/tests/` (3 fichiers), `task-manager/jest.config.js`, `reports/junit.xml`, `coverage/` | 29 tests (Jest + Supertest) couvrant les routes HTML, l'API, le store et le rendu : **100 % de couverture** (lignes, branches, fonctions) sur les 3 modules de `src/`, c'est-à-dire sur l'application réellement déployée. Trois garde-fous cumulés : `collectCoverageFrom: ['src/**/*.js']` (un module non testé fait baisser la couverture, le gate n'est pas contournable), `coverageThreshold` global à 80 % dans Jest (`npm test` échoue de lui-même, y compris en local), et une revérification explicite du seuil dans **les deux CI** qui affiche la valeur mesurée. Rapports produits : JUnit XML, couverture **HTML** (`lcov-report/`) et couverture **XML Cobertura**, publiés en artefacts par GitHub Actions et par CodeBuild. **Gate vérifié empiriquement** : avec un module non couvert injecté, la couverture tombe à 61,81 %, Jest sort en erreur et le contrôle shell des deux CI bloque également. |
| Scan SAST bloque le pipeline si vulnérabilités critiques | ✅ | `task-manager/buildspec.yml` (phase `pre_build`), `.github/workflows/ci.yml` | Semgrep (`--config auto --error`) avec `exit 1` sur détection, présent **dans les deux CI** avec la même commande. **Vérifié empiriquement dans les deux sens sur GitHub Actions (2026-08-14)** : un vrai finding (`express-check-csurf-middleware-usage`) a bloqué le job pendant plusieurs runs consécutifs (confirmé via l'API GitHub Actions, run exécuté contre le commit exact), puis le job est repassé au vert une fois la suppression correctement ciblée (le `check_id` réel de la règle diffère de celui affiché sur la page semgrep.dev — confirmé en installant Semgrep sous WSL, faute de support natif Windows). Reste à observer sur un vrai build **CodeBuild** (même commande, jamais encore exécutée sur un vrai compte AWS). |
| Image taguée avec le SHA du commit, poussée sur ECR | ✅ | `task-manager/buildspec.yml` | `IMAGE_TAG=$(echo "$CODEBUILD_RESOLVED_SOURCE_VERSION" \| cut -c1-8)`, puis `docker push "$ECR_REPOSITORY_URI:$IMAGE_TAG"`. Logique correcte et lisible, jamais exécutée sur un vrai compte AWS. |

---

## Tableau 4 — F3 : Déploiement Blue/Green sur ECS Fargate

| Règle du CDC | Statut | Preuve | Commentaire |
|---|---|---|---|
| Traffic shift progressif 10% → 50% → 100% sur 10 min | ⚠️ | `pipeline.yml` (`CodeDeployDeploymentGroup`) | `DeploymentConfigName: CodeDeployDefault.ECSLinear10PercentEvery1Minute` (rampe linéaire 10%/min) utilisé comme équivalent AWS prédéfini le plus proche — le commentaire du template reconnaît lui-même qu'*« AWS ne propose pas de config prédéfinie avec paliers 10/50/100 exacts »*. Aucune `AWS::CodeDeploy::DeploymentConfig` personnalisée n'a été créée pour coller exactement au CDC. |
| Rollback automatique en <3 min sur échec des health checks | ⚠️ | `pipeline.yml` (`AutoRollbackConfiguration: {Enabled: true, Events: [DEPLOYMENT_FAILURE]}`) | Le rollback automatique est bien configuré, mais déclenché uniquement par l'évènement `DEPLOYMENT_FAILURE` de CodeDeploy — aucune alarme CloudWatch dédiée ne pilote ce rollback, et aucun test ne démontre le délai de 3 minutes (seuls les paramètres de health check ALB — intervalle 15s, seuil 3 — donnent un ordre de grandeur théorique de ~45s pour détecter l'échec, sans preuve empirique de bout en bout). **Bug trouvé et corrigé le 2026-08-14, en amont de ce mécanisme** : `AppSpecTemplatePath: appspec.yaml` pointait vers la racine de `SourceArtifact` au lieu de `task-manager/appspec.yaml` — sans correction, le stage Deploy aurait échoué à trouver le fichier avant même de pouvoir démarrer un déploiement Blue/Green, quel qu'il soit. |
| Secrets injectés via Secrets Manager, jamais en clair | ✅ | `secrets-manager.yaml`, `ecs-task-definition.yaml` (bloc `Secrets`), `taskdef.template.json` (bloc `secrets`), `iam.yaml` (`ReadAppSecrets`) | 2 secrets créés (`<projet>/<env>/db` en JSON `username`+`password`, `<projet>/<env>/api-key`), **valeurs générées par AWS** via `GenerateSecretString` : aucune donnée sensible dans le dépôt ni dans les paramètres CloudFormation. Injectés en `DB_USERNAME`/`DB_PASSWORD`/`API_KEY` dans les **deux** task definitions — la CloudFormation (bootstrap) et `taskdef.template.json` (celle réellement déployée à chaque exécution du pipeline). Seuls des **ARN** circulent (`secrets-manager.yaml` → variables d'environnement `codebuild.yaml` → `taskdef.json`) ; un ARN n'est pas une donnée sensible, et `describe-task-definition` ne renvoie jamais la valeur, contrairement au bloc `Environment`. Validé par `test8-secrets.sh`. Reste à vérifier sur un vrai compte AWS : l'injection effective par l'agent ECS (service `ecs` Pro-only sur LocalStack). |
| Le nombre de tâches Fargate scale automatiquement selon le CPU | ✅ | `ecs-autoscaling.yaml` | `AWS::ApplicationAutoScaling::ScalableTarget` sur `ecs:service:DesiredCount` (2 à 6 tâches) + `ScalingPolicy` de type **Target Tracking** sur la métrique prédéfinie `ECSServiceAverageCPUUtilization`, **cible 70 %**, `DisableScaleIn: false` (l'énoncé demande « augmente ou diminue »). Cooldowns asymétriques : 60 s en scale-out, 300 s en scale-in pour éviter le battement. 2 alarmes CloudWatch d'observabilité notifient le topic SNS (CPU soutenu > 85 %, capacité max atteinte) — elles ne pilotent pas le scaling, Target Tracking gérant ses propres alarmes internes. Le dashboard affiche `RunningTaskCount` avec une annotation à 70 %, ce qui rend le scaling **visible**. Validé par `test9-autoscaling.sh` (22 vérifications structurelles). Reste à vérifier sur un vrai compte AWS : le scaling effectif sous charge. |

---

## Tableau 5 — F4 : Notifications & Observabilité

| Règle du CDC | Statut | Preuve | Commentaire |
|---|---|---|---|
| Notification SNS à chaque changement d'état (succès, échec, approval pending) | ⚠️ | `pipeline.yml` (`PipelineNotificationsTopic`, `PipelineStateChangeRule`) | La règle EventBridge couvre `STARTED, SUCCEEDED, FAILED, RESUMED, CANCELED, SUPERSEDED`. Mais **aucun stage `ManualApproval` n'existe dans le pipeline** (seulement Source → Build → Deploy) — l'état « approval pending » n'a donc structurellement rien à notifier. `iam.yaml` contient une permission `sns:Publish` explicitement commentée comme réservée à ce futur stage, confirmant que c'est un manque connu, pas un oubli. Slack (mentionné comme optionnel dans le CDC) n'est pas implémenté. |
| Métriques clés exposées sur un dashboard CloudWatch | ✅ | `observability.yml` (`PipelineDashboard`, 7 widgets) | Durée de pipeline, taux de succès 7 jours glissants, latence ALB (`TargetResponseTime`), CPU/mémoire ECS, métriques CodeBuild — correspond bien à l'exigence. Alimenté par une Lambda de métriques custom car CodePipeline ne publie pas nativement ces métriques. |
| Logs centralisés dans CloudWatch Logs, rétention 30 jours | ✅ | `ecs-task-definition.yaml` (`EcsLogGroup`), `codebuild.yaml` (`BuildLogGroup`), `observability.yml` (`MetricsPublisherLogGroup`) | Les trois log groups déclarés comme ressources CloudFormation portent `RetentionInDays: 30`. Le log group CodeBuild, qui manquait, est désormais **créé explicitement** et référencé par `LogsConfig.CloudWatchLogs.GroupName: !Ref BuildLogGroup` — laissé à la création implicite par CodeBuild, il aurait eu une rétention « Never expire ». `VpcFlowLogsGroup` reste paramétrable (`FlowLogsRetentionDays`) et désactivé par défaut. |
| Alarme si la durée du pipeline dépasse 15 minutes | ✅ | `observability.yml` (`PipelineDurationAlarm`, `Threshold: 900`, commentaire citant explicitement le CDC) | Correspondance exacte et directe avec l'exigence. **Bug trouvé et corrigé le 2026-08-14** : la policy du topic SNS (`pipeline.yml`) n'autorisait à publier que le principal `events.amazonaws.com` (EventBridge) ; les 4 alarmes CloudWatch de ce template et de `ecs-autoscaling.yaml` publient sous le principal `cloudwatch.amazonaws.com`, qui n'avait aucune autorisation. Conséquence si non corrigé : l'alarme aurait bien changé d'état (visible dans la console), mais sa notification SNS/email aurait été rejetée silencieusement — rien de visible côté pipeline pour le signaler. Statement ajouté à `PipelineNotificationsTopicPolicy`, scopé par `aws:SourceOwner`. |

---

## Tableau 6 — User Stories (US-01 à US-05)

| US | Critère d'acceptance (BDD) | Statut | Preuve / Commentaire |
|---|---|---|---|
| US-01 (Développeur) | Commit sur `main` → stage Source démarre en <60s | ✅ | Webhook GitHub + `CodeStarSourceConnection`, cf. Tableau 2. Non chronométré empiriquement. |
| US-01 | Tests échouent → pipeline s'arrête + notification d'échec | ⚠️ | `buildspec.yml` fait bien échouer le build (`exit 1`) sous le seuil de couverture ; la notification SNS sur `FAILED` existe (Tableau 5), mais l'ensemble n'a jamais tourné réellement. |
| US-01 | Ancienne version dispo pendant le traffic shift | ✅ | `BlueGreenDeploymentConfiguration` (`TerminateBlueInstancesOnDeploymentSuccess`, attente 5 min) dans `pipeline.yml`. |
| US-02 (Tech Lead) | Rapport HTML de couverture disponible dans les artefacts CodeBuild | ✅ | `buildspec.yml` archive `coverage/lcov-report/` en `coverage-html.tar.gz` et l'exporte dans les artefacts du build (l'archive est nécessaire : les artefacts sont aplatis par `discard-paths`, imposé par `CodeDeployToECS`). En plus, un report group `code-coverage` au format **COBERTURAXML** fait afficher la couverture directement dans l'onglet Reports de CodeBuild, avec son évolution entre builds. `ci.yml` publie HTML + XML + JUnit en artefacts GitHub. **Correction 2026-07-28** : `buildspec.yml` forçait `--coverageReporters=json-summary --coverageReporters=text`, écrasant la config Jest — CodeBuild ne produisait donc aucun rapport HTML et ce critère était insatisfiable. |
| US-02 | Couverture <80% → build échoue avec message explicite | ✅ | Double gate : `coverageThreshold` de Jest (message `Jest: "global" coverage threshold for lines (80%) not met: X%`) puis contrôle shell dans les deux CI, qui affiche la couverture mesurée avant `exit 1`. **Vérifié empiriquement** en injectant un module non couvert : couverture tombée à 61,81 %, `npm test` sort en code 1, et le contrôle shell bloque également. |
| US-03 (DevOps) | Health checks ECS échouent >3 fois/5min → CodeDeploy annule | ⚠️ | `AutoRollbackConfiguration` existe mais s'appuie sur `DEPLOYMENT_FAILURE`, pas sur un compteur de health checks explicite câblé à une alarme — voir Tableau 4. **Correction 2026-07-28** : `taskdef.template.json` (le fichier réellement déployé à chaque exécution du pipeline) ne déclarait aucun `healthCheck` — le health check du conteneur disparaissait donc dès le premier passage du pipeline, privant ce critère de son mécanisme de détection. Les deux task definitions déclarent maintenant le même health check. |
| US-03 | Rollback terminé → notification "rollback completed" | ❌ | Aucun évènement/état spécifique « rollback completed » n'est distingué dans `PipelineStateChangeRule` (seulement les états génériques de pipeline) — pas de notification dédiée au rollback trouvée. |
| US-04 (Manager) | Dashboard : durée moyenne, taux de succès 7j, nb déploiements | ✅ | `PipelineDashboard` couvre ces 3 métriques (widgets dédiés). |
| US-04 | Alarme >15min → email d'alerte | ⚠️ | Alarme présente et correcte (Tableau 5), mais l'abonnement email (`AlarmEmailSubscription`) est conditionnel à un paramètre `AlarmEmail` vide par défaut — sans le renseigner au déploiement, aucun email ne part réellement. |
| US-05 (Développeur) | Scan ECR bloque le déploiement si vulnérabilités CRITICAL | ✅ | `task-manager/buildspec.yml` (phase `post_build`, après `docker push`) + `codebuild.yaml` (IAM). Le scan est déclenché par `ScanOnPush` (`ecr.yaml`) ; le build attend sa fin (`aws ecr wait image-scan-complete` — sans quoi `describe-image-scan-findings` renverrait un scan `IN_PROGRESS` et donc zéro finding, laissant passer le gate à tort), puis lit `findingSeverityCounts`. **CRITICAL > 0 → `exit 1`** : le stage Build échoue, donc le stage Deploy n'est jamais atteint et le déploiement est bien bloqué. Si le scan ne se termine pas, le build échoue aussi (fail-safe : sans résultat, l'absence de CRITICAL ne peut pas être garantie). Le rôle CodeBuild a reçu `ecr:DescribeImageScanFindings`. Logique de décision vérifiée sur 4 payloads de scan représentatifs. |
| US-05 | Vulnérabilités HIGH → notification sans bloquer | ✅ | Même étape : **HIGH > 0 (sans CRITICAL) → `aws sns publish`** vers le topic de notification du pipeline, puis le build **continue**. Le message contient l'image, le commit et le décompte par sévérité. L'ARN du topic est construit par convention de nommage (et non importé) car `codebuild.yaml` se déploie en 5ᵉ position, avant `pipeline.yml` (10ᵉ) qui crée le topic — un `Fn::ImportValue` créerait une dépendance circulaire. Le rôle CodeBuild a reçu `sns:Publish`, scopé à ce seul topic. La publication est best-effort : son échec n'interrompt pas le build. |

---

## Tableau 7 — Composants d'architecture (§4.2 du CDC)

| Composant | Statut | Fichier(s) CloudFormation |
|---|---|---|
| GitHub (source) | ✅ | `iam.yaml` (`GitHubConnection`, CodeStar) — validée seulement par cfn-lint, autorisation manuelle requise sur un vrai compte |
| AWS CodePipeline | ✅ | `pipeline.yml` |
| AWS CodeBuild | ✅ | `codebuild.yaml` |
| Amazon ECR | ✅ | `ecr.yaml` |
| AWS CodeDeploy | ✅ | `pipeline.yml` (`CodeDeployApplication`, `CodeDeployDeploymentGroup`) |
| Amazon ECS Fargate | ✅ | `ecs-cluster.yaml`, `ecs-service.yaml`, `ecs-task-definition.yaml` |
| Application Load Balancer | ✅ | `alb.yaml` (2 target groups Blue/Green, listeners prod/test) |
| AWS Secrets Manager | ✅ | `secrets-manager.yaml` (2 secrets générés par AWS) + `iam.yaml` (`ReadAppSecrets`) + blocs `Secrets` des 2 task definitions |
| Amazon CloudWatch | ✅ | `observability.yml` |
| AWS SNS | ✅ | `pipeline.yml`, `observability.yml` |

---

## Ce qu'il reste à faire (par ordre de priorité)

| Priorité | Sujet | Description |
|---|---|---|
| 🔴 Bloquant | Déploiement AWS réel | Aucune ressource n'a jamais été déployée sur un vrai compte AWS. CodeBuild, ALB, ECS, CodeDeploy et CodePipeline eux-mêmes (11 des ~17 ressources de `pipeline.yml`) ne sont validés que par `cfn-lint`, jamais exécutés. |
| 🟡 Mineur | Traffic shift non conforme aux paliers | Créer un `AWS::CodeDeploy::DeploymentConfig` personnalisé pour coller aux paliers 10 % → 50 % → 100 % du CDC, au lieu de la rampe linéaire prédéfinie actuelle. |
| 🟡 Mineur | Notification "rollback completed" | Ajouter un évènement/état distinct pour notifier spécifiquement la fin d'un rollback (US-03), au-delà des états génériques déjà notifiés. |
| 🟡 Mineur | Pas de stage d'approbation | Ajouter un stage `ManualApproval` dans `pipeline.yml` pour que l'état « approval pending » de F4 ait une source (la permission `sns:Publish` est déjà prévue dans `iam.yaml`). |
| 🟡 Mineur | `parameters.json` vide | Renseigner ou supprimer `infrastructure/cloudformation/parameters.json`. |
| 🟡 Mineur | Protection de branche GitHub | Rendre le job CI obligatoire au merge côté réglages GitHub (le workflow existe et bloque déjà en cas d'échec, mais rien ne l'impose encore). |

---

## Historique de ce rapport

**2026-07-28 — version initiale.** Audit complet du dépôt contre le cahier des charges. Deux constats
bloquants : aucun déploiement AWS réel, et une incohérence applicative (deux applications divergentes, le
pipeline construit autour d'un stub, GitHub Actions validant une app que rien ne déployait).

**2026-07-28 — mise à jour après unification applicative.** Le dépôt ne contient plus qu'une seule
application (Node.js/Express) : le CRUD de l'app Flask a été porté vers Express (`src/app.js`,
`src/tasks.js`, `src/views.js`), l'app Flask et tous les doublons ont été supprimés (`src/app.py`,
`templates/index.html`, `requirements.txt`, `tasks.db`, `Dockerfile` racine, `package.json`/
`package-lock.json` racine, fichier fantôme `task-manager/ server.js`), et `.github/workflows/ci.yml` a été
réécrit pour exécuter les mêmes gates que `buildspec.yml` sur cette même application.

Trois bugs réels ont été trouvés pendant cette unification — aucun n'était détectable par `cfn-lint` :

| Bug | Conséquence s'il n'avait pas été corrigé |
|---|---|
| `codebuild.yaml` déclarait `BuildSpec: buildspec.yml`, chemin résolu depuis la racine du dépôt, alors que le fichier est dans `task-manager/` | CodeBuild n'aurait jamais trouvé le buildspec : échec du build avant même la phase `install`, donc pipeline inopérant de bout en bout |
| `taskdef.template.json` — le fichier réellement déployé par `CodeDeployToECS` à chaque exécution — ne déclarait ni `environment` ni `healthCheck` | Le health check du conteneur disparaissait dès le premier passage du pipeline, privant le rollback automatique Blue/Green (F3, US-03) de son mécanisme de détection |
| `NODE_ENV` valait `!Ref Environment` (donc `dev`/`staging`/`prod`) et écrasait le `ENV NODE_ENV=production` du Dockerfile | Application tournant en mode non-production jusqu'en production (`prod` n'est pas une valeur reconnue par Express) |

Vérifications effectuées pour cette mise à jour : 27 tests Jest passent avec **100 % de couverture**, le
gate de couverture passe, `reports/junit.xml` est généré, l'image Docker est construite et **mesurée à
48 Mo**, le CRUD complet a été exercé en direct contre le conteneur (ajout → API → bascule → suppression),
le `HEALTHCHECK` Docker remonte `healthy`, `cfn-lint` est propre sur les deux templates modifiés, et
`test2-codebuild.sh` repasse (exit 0).

**2026-07-28 — mise à jour après câblage de Secrets Manager (F3).** Nouvelle stack `secrets-manager.yaml`
(2 secrets, valeurs générées par AWS), bloc `Secrets` ajouté aux deux task definitions, permissions du rôle
d'exécution ECS vérifiées. Points de conception notables :

| Décision | Raison |
|---|---|
| Valeurs générées par AWS (`GenerateSecretString`), jamais en paramètre de stack | C'est le cœur de F3 : aucune valeur sensible ne doit exister dans le dépôt ni dans l'historique des paramètres CloudFormation. La vraie clé d'API tierce (non générable) se pousse hors CloudFormation via `put-secret-value` ; un update de stack ne l'écrase pas. |
| ARN passés par exports CloudFormation → variables d'environnement CodeBuild → `taskdef.json` | L'ARN d'un secret se termine par un suffixe aléatoire de 6 caractères ajouté par AWS (confirmé empiriquement au Test 8 : `.../db-pvWiCG`) : **impossible à reconstruire par convention de nommage**. Un ARN n'est pas une donnée sensible, donc le faire transiter par CodeBuild ne contrevient pas à F3 — c'est la valeur qui ne doit jamais y apparaître. |
| Bloc `Secrets` ajouté aux **deux** task definitions | Même piège que le health check corrigé plus haut : `taskdef.template.json` est celle réellement déployée à chaque exécution du pipeline. La déclarer seulement dans la CloudFormation aurait fait disparaître les secrets dès le premier passage. |
| Restriction IAM par préfixe de nom plutôt que par ARN importé | Le wildcard `.../secret:<projet>/<env>/*` couvre le suffixe aléatoire et évite de coupler `iam.yaml` (déployée en 2ᵉ position) à la stack de secrets. Vérifié par correspondance de motif : les secrets d'un autre environnement ou d'un autre projet sont bien refusés. |
| Pas de `kms:Decrypt` | Les secrets utilisent la clé gérée par AWS (`alias/aws/secretsmanager`), qui n'exige aucune permission KMS explicite. Commenté dans `iam.yaml` car ça devrait changer avec une clé gérée par le client, sous peine de tâches ECS qui ne démarrent plus. |

Vérifications : `test8-secrets.sh` (nouveau, chaîné dans `test7-all-local.sh`) passe — les 2 secrets se
créent, la structure JSON `username`/`password` du secret DB est confirmée, la longueur et l'exclusion de
caractères du mot de passe généré sont vérifiées, les 4 exports attendus sont présents. Le rendu de
`taskdef.json` par le `sed` de `buildspec.yml` a été simulé avec des ARN réalistes : JSON valide, 3 secrets
correctement référencés, aucun placeholder oublié, aucune valeur de secret dans le fichier. `cfn-lint` est
propre sur les 11 templates.

Corrigé au passage : les notes d'ordre de déploiement étaient **incohérentes entre fichiers** (`iam.yaml`
listait encore un `ecs.yaml` inexistant, `observability.yml` une liste de 6 stacks pré-refactor) et le
tableau de `infrastructure/README.md` annonçait toujours « les 6 stacks » alors qu'il y en avait 10. Tout
est normalisé sur une liste de référence unique de **11 stacks**.

Limite connue et assumée : l'application ne **lit** pas encore ces secrets (`DB_USERNAME`, `DB_PASSWORD`,
`API_KEY` sont disponibles dans le conteneur mais inutilisés) — le store est en mémoire et il n'y a ni base
de données ni appel à un service tiers. Le mécanisme d'injection est en place et conforme à F3 ; son usage
suivra le besoin applicatif.

**2026-07-28 — mise à jour après ajout de l'auto scaling ECS (F3).** Nouvelle stack `ecs-autoscaling.yaml` :
`ScalableTarget` sur `ecs:service:DesiredCount` (2 à 6 tâches), `ScalingPolicy` Target Tracking sur
`ECSServiceAverageCPUUtilization` à **70 %**, et 2 alarmes CloudWatch notifiant le topic SNS. Points de
conception notables :

| Décision | Raison |
|---|---|
| Target Tracking plutôt que Step Scaling | C'est l'approche recommandée par AWS et celle qui correspond littéralement à l'énoncé F3 (« cible CPU »). On fixe l'objectif, AWS calcule l'ajustement — pas de paliers à maintenir. |
| Les 2 alarmes CloudWatch ne pilotent PAS le scaling | Target Tracking crée et gère ses **propres** alarmes internes (`TargetTracking-service/...`). Les alarmes de ce template servent à prévenir l'équipe (F4) : CPU soutenu au-delà de la cible, et surtout **capacité maximale atteinte** — le signal « l'auto scaling n'a plus de marge ». Documenté en tête du template pour éviter qu'on les câble par erreur à une policy. |
| Cooldowns asymétriques (60 s out / 300 s in) | Réagir vite à une montée de charge, mais redescendre lentement pour éviter le battement quand la charge oscille. |
| Aucune modification de `iam.yaml` | Application Auto Scaling utilise son rôle lié au service (`AWSServiceRoleForApplicationAutoScaling_ECSService`), créé par AWS à la première utilisation — inutile de déclarer un rôle. |
| `DesiredCount` de `ecs-service.yaml` devient une valeur *initiale* | Dès que le `ScalableTarget` est attaché, Application Auto Scaling possède `DesiredCount`. Une mise à jour de la stack du service peut le réinitialiser transitoirement, puis l'auto scaling corrige. Comportement connu de CloudFormation + Application Auto Scaling, désormais documenté dans la description du paramètre et dans `infrastructure/README.md` plutôt que subi. |
| `RunningTaskCount` ajouté au dashboard | Sans ça, F3 serait déclarée mais invisible. Le widget ECS montre maintenant CPU et nombre de tâches sur le même graphique, avec une annotation à 70 % : on voit la charge monter puis les tâches suivre. |

Vérifications : `test9-autoscaling.sh` (nouveau, chaîné dans `test7-all-local.sh` qui passe à 8 tests) —
**22 vérifications structurelles**, exit 0. Volontairement statique et non déployé : ni
`application-autoscaling` ni `ecs` ne sont émulés par LocalStack Community, un déploiement échouerait pour
des raisons d'émulation et n'apprendrait rien. Le script vérifie ce que `cfn-lint` ne voit pas — format exact
du `ResourceId` (`service/<cluster>/<service>`), dimension scalable, absence de nom en dur, et surtout la
**cohérence des seuils entre stacks** : seuil d'alarme strictement au-dessus de la cible (sinon l'alarme
sonne alors que l'auto scaling fait son travail) et `MinCapacity` ≤ `DesiredCount` de `ecs-service.yaml`.
`cfn-lint` propre sur les 12 templates ; JSON du dashboard revalidé (8 widgets).

Reste à vérifier sur un vrai compte AWS : le scaling effectif sous charge, via
`aws application-autoscaling describe-scaling-activities`.

**2026-07-28 — mise à jour après renforcement des quality gates de couverture (F2 / US-02).** Les tests
portaient déjà sur l'application réellement déployée depuis l'unification applicative ; cette passe a ajouté
les rapports manquants et corrigé deux défauts réels :

| Défaut trouvé | Conséquence | Correction |
|---|---|---|
| `buildspec.yml` passait `--coverageReporters=json-summary --coverageReporters=text`, ce qui **écrase** la liste de `jest.config.js` | CodeBuild ne générait **jamais** le rapport HTML : US-02 (« un rapport HTML de couverture est disponible dans les artefacts CodeBuild ») était littéralement insatisfiable | Suppression de l'option : `jest.config.js` redevient la source de vérité unique des reporters |
| Aucun rapport de couverture n'était exporté par CodeBuild | Le Tech Lead n'avait accès à rien, quel que soit le format | Report group `code-coverage` en **COBERTURAXML** (affiché nativement par CodeBuild, avec l'évolution entre builds) + archive `coverage-html.tar.gz` dans les artefacts |
| Aucun format XML de couverture n'était produit | Rien d'exploitable par CodeBuild, SonarQube, GitLab… | Ajout du reporter `cobertura` → `coverage/cobertura-coverage.xml` |
| Le seuil n'était appliqué que par du shell dans les deux CI | Un développeur pouvait faire chuter la couverture sans le voir avant la CI | `coverageThreshold` global à 80 % dans Jest : `npm test` échoue de lui-même, y compris en local |

Ajouts de tests : 2 cas qui couvraient un comportement réel jusque-là non exercé — création d'une tâche via
un **corps JSON** (`express.json()` est monté mais aucun test ne l'empruntait) et 404 sur route inconnue.
Total : **29 tests**, 100 % de couverture (lignes, branches, fonctions).

**Le gate a été vérifié empiriquement**, ce que les versions précédentes de ce rapport signalaient comme
jamais démontré : en injectant temporairement un module non testé dans `src/`, la couverture tombe à
**61,81 %**, Jest sort en code 1 avec un message explicite, et le contrôle shell des deux CI bloque
également. Le module de test a été retiré, et le projet est revenu à 29 tests / 100 %.

Vérifications complémentaires : XML Cobertura bien formé (3 classes, `line-rate=1`), rapport HTML présent
(`coverage/lcov-report/index.html`), archivage `tar` fonctionnel (24 Ko), YAML de `ci.yml` et
`buildspec.yml` valides, `.gitignore` complété pour l'archive générée, et `test2-codebuild.sh` repasse
(exit 0 : cfn-lint + 29 tests + build Docker + `/health`).

Note : `pytest.ini` et `requirements.txt` ne s'appliquent pas — le projet a été unifié sur Node.js/Express,
la pile de tests est Jest + Supertest.

**2026-07-28 — mise à jour après alignement de GitHub Actions sur CodeBuild.** `ci.yml` est passé d'un job
unique à **2 jobs parallèles** : `app` (les gates de `buildspec.yml`) et `infra` (la validation statique que
faisaient seulement les scripts locaux). La CI détecte donc maintenant les erreurs d'infrastructure avant
qu'un run CodePipeline soit consommé — et avant le merge.

Ajouté au job `infra` : `cfn-lint` sur les 12 templates, validité YAML de `appspec.yaml` et `buildspec.yml`,
validité JSON de `taskdef.template.json` (avec contrôle de présence du `healthCheck`, dont dépend le rollback
Blue/Green), et un **dry-run du rendu de `taskdef.json`** — le même `sed` que `buildspec.yml`, suivi d'une
vérification qu'il ne reste aucun placeholder non substitué hormis `<IMAGE1_NAME>` (substitué par
CodePipeline). Ce dernier contrôle attrape en CI la classe de bugs qui, sinon, ne se manifeste qu'au stage
Deploy, après un build et un push d'image complets.

Ajouté au job `app` : le rapport SAST (`semgrep-report.json`, comme dans CodeBuild) est produit et publié en
artefact, et la taille de l'image apparaît dans le résumé du job.

| Détail technique | Pourquoi |
|---|---|
| `--ignore-checks W6001` sur `cfn-lint` | `cfn-lint` sort en **code 4** sur un simple warning. Les 5 outputs pass-through de `pipeline.yml` déclenchent W6001 (« output value is an import from another output ») — volontairement, pour préserver les noms d'export consommés par `observability.yml`. Seul ce check est ignoré : tout **nouveau** warning fait donc bien échouer le job. |
| Aucun filtre de chemin sur les 2 jobs | Un job conditionné par les chemins modifiés qui ne démarre pas reste « en attente » et bloquerait indéfiniment une PR s'il est déclaré obligatoire dans la protection de branche GitHub. |

**Bug latent trouvé et corrigé au passage** : `test5-pipeline.sh` **échouait déjà** (exit 4) depuis le
refactor du 2026-07-27, pour cette même raison — il lançait `cfn-lint pipeline.yml` sous `set -e`, et les
warnings W6001 introduits par les outputs pass-through interrompaient le script dès son étape 1. Le script
passe maintenant `--ignore-checks W6001` et atteint bien ses étapes suivantes.

`.gitignore` complété pour tous les fichiers générés par les CI (`semgrep-report.json`, `taskdef.json`,
`taskdef.rendered.json`, `imageDetail.json`), en vérifiant que `taskdef.template.json` — la source
versionnée — reste bien suivi.

Vérifications : YAML du workflow valide (2 jobs, 9 + 6 étapes), et **chaque nouvelle étape rejouée
localement** — `cfn-lint` sur les 12 templates avec le flag (exit 0), validation des manifestes (port 3000,
3 secrets, `healthCheck` présent), dry-run du rendu (`taskdef.json` valide, seul `<IMAGE1_NAME>` subsistant),
29 tests / 100 % de couverture, et les 4 artefacts de couverture présents.

---

**2026-07-28 — mise à jour après exploitation du scan ECR (US-05).** Le scan tournait déjà (`ScanOnPush`
activé dans `ecr.yaml`) mais **rien ne lisait ses résultats** : c'était le dernier écart fonctionnel du
rapport. `buildspec.yml` appelle maintenant `describe-image-scan-findings` juste après le `docker push`,
et applique les deux règles de US-05 : **CRITICAL → `exit 1`** (le stage Build échoue, donc Deploy n'est
jamais atteint) et **HIGH → notification SNS sans blocage**.

| Décision | Raison |
|---|---|
| `aws ecr wait image-scan-complete` avant de lire les findings | `ScanOnPush` est **asynchrone**. Sans cette attente, `describe-image-scan-findings` renvoie un scan encore `IN_PROGRESS` avec zéro finding — le gate passerait systématiquement à tort, en donnant l'illusion de fonctionner. |
| Échec du build si le scan ne se termine pas | Fail-safe : sans résultat de scan, l'absence de vulnérabilité CRITICAL ne peut pas être *garantie*. Le statut réel du scan est affiché dans le log pour diagnostiquer. |
| ARN du topic SNS construit par convention, pas importé | `codebuild.yaml` se déploie en 5ᵉ position, `pipeline.yml` (qui crée le topic) en 10ᵉ. Un `Fn::ImportValue` créerait une dépendance circulaire dans l'ordre de déploiement. Le `TopicName` est déterministe et un ARN SNS n'a pas de suffixe aléatoire — contrairement à Secrets Manager, la convention est fiable ici. |
| Publication SNS best-effort | Un échec de notification ne doit ni masquer un échec de build (cas CRITICAL), ni faire échouer un build sain (cas HIGH). |
| Notification envoyée aussi pour CRITICAL | La règle EventBridge notifie déjà l'échec du pipeline, mais sans dire **pourquoi**. Le message du scan porte l'image, le commit et le décompte par sévérité. |

IAM : le rôle CodeBuild a reçu `ecr:DescribeImageScanFindings` (scopé au repository importé) et `sns:Publish`
(scopé au seul topic du projet). `ecr-scan-findings.json` est exporté en artefact du build, y compris quand
le build a été bloqué, pour pouvoir analyser les CVE.

Vérification : la logique de décision a été rejouée sur 4 payloads représentatifs de
`describe-image-scan-findings` — aucun finding, HIGH seul, CRITICAL présent, et `findingSeverityCounts`
absent. Les 4 se comportent conformément à US-05 (respectivement : passe sans notification, passe avec
notification, bloque avec notification, passe sans erreur malgré la structure vide). `cfn-lint` propre sur
`codebuild.yaml`, YAML du buildspec valide.

---

**2026-08-14 — traduction anglaise de l'IaC, enrichissement applicatif, et audit complet du dépôt.**

Tous les commentaires/descriptions des 12 templates CloudFormation sont passés du français à l'anglais
(aucune valeur fonctionnelle touchée) ; l'UI de l'application reste en français (contenu utilisateur, pas
documentation technique). L'application `task-manager` a gagné l'édition de tâches, des échéances
optionnelles, la recherche, le filtrage et le tri — toujours en mémoire, zéro nouvelle dépendance, 61 tests
(contre 29) pour une couverture de 99,3 %/99,1 % (lignes/branches).

Le gate SAST, qui bloquait le job `SAST (Semgrep)` de `ci.yml` sur un finding
`express-check-csurf-middleware-usage`, a été corrigé en deux temps : un premier `nosemgrep` mal placé (sur
les routes plutôt que sur `const app = express()`, la ligne que la règle matche réellement) n'a rien changé
; un second essai avec la bonne ligne mais un `check_id` incomplet non plus (`check_id` réel confirmé à 0
faux négatif via Semgrep installé sous WSL, faute de support natif Windows — le nom de la règle est dupliqué
dans le `check_id` complet, ce qui n'apparaît pas sur sa page semgrep.dev). Les deux échecs ont été observés
empiriquement via l'API GitHub Actions (run exécuté contre le commit exact), pas seulement supposés.

L'audit complet (5 revues ciblées, chaque piste revérifiée avant correction) a trouvé et corrigé :

| Bug | Conséquence s'il n'avait pas été corrigé |
|---|---|
| `pipeline.yml` : `AppSpecTemplatePath: appspec.yaml` résolu depuis la racine de `SourceArtifact`, alors que le fichier est dans `task-manager/` (même catégorie que le bug `BuildSpec` déjà corrigé pour `codebuild.yaml`, jamais reproduit ici) | Le stage Deploy aurait échoué à trouver l'AppSpec dès le premier déploiement Blue/Green, après que Source et Build aient déjà réussi |
| `PipelineNotificationsTopicPolicy` n'autorisait que `events.amazonaws.com` à publier | Les 4 alarmes CloudWatch auraient changé d'état correctement, mais leur notification SNS/email aurait été rejetée silencieusement — rien de visible côté pipeline |
| `CodeBuildServiceRole` sans permissions `codebuild:*ReportGroup*`/`*Report*` alors que `buildspec.yml` déclare un bloc `reports:` | Le build aurait échoué à la remontée des rapports, après que tests, SAST, build Docker et scan ECR aient déjà réussi |
| Rôle CodeBuild sans permission S3 sur le bucket d'artefacts CodePipeline (nécessaire quand ce projet tourne comme action Build d'un pipeline) | Contournée jusqu'ici par une policy attachée à la main dans la console AWS (avec l'ID de compte réel en clair — seul endroit du dépôt à le faire), non reproductible depuis un déploiement CloudFormation propre |

Corrigé au passage, sans lien avec un déploiement réel mais trouvé en cours de revue : les notes « ordre de
déploiement » de 4 templates décrivaient encore l'ancien ordre erroné (IAM avant secrets/ecr/codebuild), de
même que le tableau principal d'`infrastructure/README.md` — en contradiction avec l'encadré juste en
dessous, qui donnait déjà le bon ordre ; un commentaire de `pipeline.yml` attribuait à tort la couverture
des branches `feature/*` au webhook CodeBuild (qui ne couvre que `main`/`develop` — c'est
`.github/workflows/ci.yml` qui s'en charge) ; `test5-pipeline.sh` omettait 2 outputs à exclure de sa copie
de test de `pipeline.yml`.

Le conflit `ECR IMMUTABLE` + tag `latest` (identifié le 2026-07-28, jamais tranché entre les 3 options alors
envisagées) est résolu : `buildspec.yml` ne pousse plus `latest` sur les builds automatisés. Une régression a
été détectée et corrigée avant d'être commise dans ce rapport : `ecs-task-definition.yaml` dépend de
`<repo>:latest` pour son image de bootstrap (avant que le pipeline n'ait jamais tourné) — un premier correctif
avait supprimé `latest` de partout, cassant ce chemin. Solution retenue : le pousser une seule fois, à la
main, dans le guide de déploiement (`guideme2.md`), le seul moment où c'est sans risque.

Vérifications effectuées après chaque correction : `cfn-lint` propre sur les 12 templates, graphe complet des
exports/imports entre stacks recalculé sans référence pendante, `npm test` (61 tests, ~99 %), et Semgrep
(WSL) à 0 finding après modification de `buildspec.yml`.

---

*Ce rapport complète `so-far.md` (journal d'avancement chronologique) avec une vue de traçabilité
exigence-par-exigence par rapport au cahier des charges fourni. Il doit être régénéré/mis à jour si le CDC
ou l'implémentation évoluent significativement.*
