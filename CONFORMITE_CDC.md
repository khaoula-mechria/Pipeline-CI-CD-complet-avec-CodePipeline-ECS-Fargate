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

L'infrastructure CloudFormation est **structurellement complète** (9 templates couvrant VPC, IAM, ECR,
CodeBuild, cluster/service/task definition ECS, ALB Blue/Green, CodePipeline/CodeDeploy, observabilité) et
la majorité des exigences F1/F2/F4 du cahier des charges sont couvertes.

✅ **L'incohérence applicative signalée par la première version de ce rapport est résolue** (2026-07-28) :
le dépôt ne contient plus qu'une seule application (Node.js/Express, `task-manager/`). Le CRUD de l'ancienne
app Flask a été porté vers Express, puis la version Flask supprimée. GitHub Actions, CodeBuild et ECS
valident et déploient désormais exactement le même code. Trois bugs réels ont été trouvés au passage et
corrigés — voir « Historique de ce rapport » en fin de document.

Il reste **un problème structurel** :

- **Aucun déploiement AWS réel** n'a jamais eu lieu (voir `so-far.md`) : CodeBuild, CodeDeploy, ECS, ALB et
  CodePipeline eux-mêmes n'ont jamais tourné, seulement été validés syntaxiquement.

Et deux exigences du cahier des charges restent **absentes de l'implémentation**, pas seulement partielles :
l'injection de secrets via Secrets Manager (IAM seul, aucun secret ni bloc `Secrets:` réel) et l'auto-scaling
ECS basé sur le CPU (aucune ressource `ApplicationAutoScaling` dans le dépôt).

---

## Tableau 1 — Stack technologique (§1.3 du CDC)

| # | Technologie | Statut | Preuve (fichier) | Commentaire |
|---|---|---|---|---|
| 1 | AWS CodePipeline | ✅ | `infrastructure/cloudformation/pipeline.yml` | 3 stages Source (CodeStarSourceConnection) → Build (CodeBuild) → Deploy (`CodeDeployToECS`). Jamais exécuté réellement. |
| 2 | Amazon ECS Fargate | ✅ | `ecs-cluster.yaml`, `ecs-service.yaml`, `ecs-task-definition.yaml` | `RequiresCompatibilities: FARGATE`, `DeploymentController: CODE_DEPLOY`. Jamais déployé réellement (ECS = Pro-only sur LocalStack). |
| 3 | AWS CodeBuild | ✅ | `infrastructure/cloudformation/codebuild.yaml`, `task-manager/buildspec.yml` | Projet + rôle IAM + buildspec complet (SAST, tests, push ECR). Le rejeu local via l'agent officiel ne va jamais jusqu'au bout (pull d'image trop lent). |
| 4 | Amazon ECR | ✅ | `infrastructure/cloudformation/ecr.yaml` | Repository privé, `ScanOnPush: true`, lifecycle policy 10 images. Testé de bout en bout sur LocalStack. |
| 5 | AWS CloudFormation | ✅ | `infrastructure/cloudformation/*.yaml` | 9 templates non vides (`parameters.json` est vide, voir gaps). |
| 6 | Docker | ✅ | `task-manager/Dockerfile` | Dockerfile unique, multi-stage, non-root, `HEALTHCHECK`. Le doublon single-stage de la racine a été supprimé. Image mesurée : **48 Mo**. |
| 7 | GitHub Actions | ✅ | `.github/workflows/ci.yml` | Exécute les mêmes quality gates que `buildspec.yml` (SAST Semgrep, tests Jest, seuil de couverture 80 %) sur la même application, publie le rapport JUnit + la couverture HTML en artefacts, et valide le build Docker + sa taille. Ne pousse rien vers AWS (rôle volontairement limité à la protection de branche). |
| 8 | Amazon CloudWatch | ✅ | `infrastructure/cloudformation/observability.yml` | Dashboard (7 widgets) + 2 alarmes. Testé de bout en bout sur LocalStack. |
| 9 | AWS SNS | ✅ | `pipeline.yml` (topic + policy), `observability.yml` (abonnement email optionnel) | Voir nuance sur l'état « approval pending » au Tableau 5. |

---

## Tableau 2 — F1 : Déclenchement automatique du pipeline

| Règle du CDC | Statut | Preuve | Commentaire |
|---|---|---|---|
| Push sur `main` déclenche le pipeline en <60s | ✅ | `codebuild.yaml` (webhook GitHub sur push `main`/`develop`), `pipeline.yml` (`CodeStarSourceConnection`, `BranchName: main`) | Déclenchement natif AWS, non chronométré empiriquement (jamais exécuté réellement). |
| Push sur `feature/*` ne déclenche que Build+Test | ✅ | `.github/workflows/ci.yml` (`push: [..., 'feature/**']`) | Le workflow s'exécute sur `feature/**` et n'y fait que Build et Test : il ne pousse aucune image et ne touche jamais à AWS. Le stage Deploy reste l'affaire de CodePipeline, câblé sur `main` uniquement. |
| PR vers `main` doit passer les quality gates avant merge | ✅ | `.github/workflows/ci.yml` | Sur `pull_request` vers `main`/`develop`, le job exécute SAST Semgrep (bloquant), les tests unitaires et le seuil de couverture 80 % (bloquant), puis valide le build Docker. Reste à activer la protection de branche côté GitHub pour rendre le job **obligatoire** au merge (réglage d'interface, hors dépôt). |
| Déclenchement manuel via console/CLI reste possible | ✅ | — | Capacité native de CodePipeline/CodeBuild, aucun blocage identifié dans l'IaC. |

---

## Tableau 3 — F2 : Stage Build & Test

| Règle du CDC | Statut | Preuve | Commentaire |
|---|---|---|---|
| Dockerfile multi-stage, image finale < 200 Mo | ✅ | `task-manager/Dockerfile` | Multi-stage (`build` → `production`), image de prod sans devDependencies, utilisateur non-root, `HEALTHCHECK`. **Taille réellement mesurée : 48 Mo**, soit très en dessous de la cible de 200 Mo (première mesure effective du projet). Le doublon single-stage de la racine a été supprimé. |
| Tests unitaires ≥80% de couverture, rapport JUnit exporté | ✅ | `task-manager/tests/` (3 fichiers), `task-manager/jest.config.js`, `reports/junit.xml` | 27 tests (Jest + Supertest) couvrant les routes HTML, l'API, le store et le rendu : **100% de couverture** sur les 3 modules de `src/`, sur l'application réellement déployée. `jest.config.js` fixe `collectCoverageFrom: ['src/**/*.js']` — sans ça, un module non testé ne faisait pas baisser la couverture et le gate était contournable. Rapport JUnit généré (`reports/junit.xml`, 27 tests) et publié en artefact par les deux CI. |
| Scan SAST bloque le pipeline si vulnérabilités critiques | ⚠️ | `task-manager/buildspec.yml` (phase `pre_build`), `.github/workflows/ci.yml` | Semgrep (`--config auto --error`) avec `exit 1` sur détection, désormais présent **dans les deux CI** avec la même commande (avant : uniquement CodeBuild). Reste ⚠️ pour une seule raison : le gate n'a toujours pas été observé bloquant un build de bout en bout sur un vrai compte AWS. |
| Image taguée avec le SHA du commit, poussée sur ECR | ✅ | `task-manager/buildspec.yml` | `IMAGE_TAG=$(echo "$CODEBUILD_RESOLVED_SOURCE_VERSION" \| cut -c1-8)`, puis `docker push "$ECR_REPOSITORY_URI:$IMAGE_TAG"`. Logique correcte et lisible, jamais exécutée sur un vrai compte AWS. |

---

## Tableau 4 — F3 : Déploiement Blue/Green sur ECS Fargate

| Règle du CDC | Statut | Preuve | Commentaire |
|---|---|---|---|
| Traffic shift progressif 10% → 50% → 100% sur 10 min | ⚠️ | `pipeline.yml` (`CodeDeployDeploymentGroup`) | `DeploymentConfigName: CodeDeployDefault.ECSLinear10PercentEvery1Minute` (rampe linéaire 10%/min) utilisé comme équivalent AWS prédéfini le plus proche — le commentaire du template reconnaît lui-même qu'*« AWS ne propose pas de config prédéfinie avec paliers 10/50/100 exacts »*. Aucune `AWS::CodeDeploy::DeploymentConfig` personnalisée n'a été créée pour coller exactement au CDC. |
| Rollback automatique en <3 min sur échec des health checks | ⚠️ | `pipeline.yml` (`AutoRollbackConfiguration: {Enabled: true, Events: [DEPLOYMENT_FAILURE]}`) | Le rollback automatique est bien configuré, mais déclenché uniquement par l'évènement `DEPLOYMENT_FAILURE` de CodeDeploy — aucune alarme CloudWatch dédiée ne pilote ce rollback, et aucun test ne démontre le délai de 3 minutes (seuls les paramètres de health check ALB — intervalle 15s, seuil 3 — donnent un ordre de grandeur théorique de ~45s pour détecter l'échec, sans preuve empirique de bout en bout). |
| Secrets injectés via Secrets Manager, jamais en clair | ❌ | `iam.yaml` (permission IAM seule) | Seule une permission `secretsmanager:GetSecretValue` existe (`EcsTaskExecutionRole`, scopée par convention de nommage). **Aucune ressource `AWS::SecretsManager::Secret` n'existe dans le dépôt**, et **aucun bloc `Secrets:` n'est présent** dans `taskdef.template.json` ni `ecs-task-definition.yaml` — seules des variables d'environnement non sensibles (`PROJECT_NAME`, `NODE_ENV`) y figurent. L'intention est documentée en commentaire mais non câblée. |
| Le nombre de tâches Fargate scale automatiquement selon le CPU | ❌ | — | Recherche exhaustive (`ApplicationAutoScaling`, `ScalableTarget`, `ScalingPolicy`, `AutoScaling`) : **aucune occurrence dans tout le dépôt**. `ecs-service.yaml` utilise un `DesiredCount` fixe (paramètre, défaut 2). |

---

## Tableau 5 — F4 : Notifications & Observabilité

| Règle du CDC | Statut | Preuve | Commentaire |
|---|---|---|---|
| Notification SNS à chaque changement d'état (succès, échec, approval pending) | ⚠️ | `pipeline.yml` (`PipelineNotificationsTopic`, `PipelineStateChangeRule`) | La règle EventBridge couvre `STARTED, SUCCEEDED, FAILED, RESUMED, CANCELED, SUPERSEDED`. Mais **aucun stage `ManualApproval` n'existe dans le pipeline** (seulement Source → Build → Deploy) — l'état « approval pending » n'a donc structurellement rien à notifier. `iam.yaml` contient une permission `sns:Publish` explicitement commentée comme réservée à ce futur stage, confirmant que c'est un manque connu, pas un oubli. Slack (mentionné comme optionnel dans le CDC) n'est pas implémenté. |
| Métriques clés exposées sur un dashboard CloudWatch | ✅ | `observability.yml` (`PipelineDashboard`, 7 widgets) | Durée de pipeline, taux de succès 7 jours glissants, latence ALB (`TargetResponseTime`), CPU/mémoire ECS, métriques CodeBuild — correspond bien à l'exigence. Alimenté par une Lambda de métriques custom car CodePipeline ne publie pas nativement ces métriques. |
| Logs centralisés dans CloudWatch Logs, rétention 30 jours | ⚠️ | `ecs-task-definition.yaml` (`EcsLogGroup`, `RetentionInDays: 30`), `observability.yml` (`MetricsPublisherLogGroup`, 30 jours) | Rétention correcte pour les logs ECS et Lambda. **Le log group CodeBuild n'a pas de ressource `AWS::Logs::LogGroup` dédiée** dans `codebuild.yaml` (référencé par nom seulement) — sans rétention explicite, il serait créé par défaut sans expiration à l'exécution réelle. |
| Alarme si la durée du pipeline dépasse 15 minutes | ✅ | `observability.yml` (`PipelineDurationAlarm`, `Threshold: 900`, commentaire citant explicitement le CDC) | Correspondance exacte et directe avec l'exigence. |

---

## Tableau 6 — User Stories (US-01 à US-05)

| US | Critère d'acceptance (BDD) | Statut | Preuve / Commentaire |
|---|---|---|---|
| US-01 (Développeur) | Commit sur `main` → stage Source démarre en <60s | ✅ | Webhook GitHub + `CodeStarSourceConnection`, cf. Tableau 2. Non chronométré empiriquement. |
| US-01 | Tests échouent → pipeline s'arrête + notification d'échec | ⚠️ | `buildspec.yml` fait bien échouer le build (`exit 1`) sous le seuil de couverture ; la notification SNS sur `FAILED` existe (Tableau 5), mais l'ensemble n'a jamais tourné réellement. |
| US-01 | Ancienne version dispo pendant le traffic shift | ✅ | `BlueGreenDeploymentConfiguration` (`TerminateBlueInstancesOnDeploymentSuccess`, attente 5 min) dans `pipeline.yml`. |
| US-02 (Tech Lead) | Rapport HTML de couverture disponible dans les artefacts CodeBuild | ✅ | Jest génère `coverage/lcov-report/` (HTML) et `reports/junit.xml` pour l'application réellement déployée. `buildspec.yml` déclare le rapport JUnit en section `reports`, et `ci.yml` publie les deux en artefacts GitHub (`actions/upload-artifact`). |
| US-02 | Couverture <80% → build échoue avec message explicite | ✅ | `buildspec.yml` compare `$COVERAGE` à `$COVERAGE_THRESHOLD` et sort en erreur ; message affiché avant `exit 1`. |
| US-03 (DevOps) | Health checks ECS échouent >3 fois/5min → CodeDeploy annule | ⚠️ | `AutoRollbackConfiguration` existe mais s'appuie sur `DEPLOYMENT_FAILURE`, pas sur un compteur de health checks explicite câblé à une alarme — voir Tableau 4. **Correction 2026-07-28** : `taskdef.template.json` (le fichier réellement déployé à chaque exécution du pipeline) ne déclarait aucun `healthCheck` — le health check du conteneur disparaissait donc dès le premier passage du pipeline, privant ce critère de son mécanisme de détection. Les deux task definitions déclarent maintenant le même health check. |
| US-03 | Rollback terminé → notification "rollback completed" | ❌ | Aucun évènement/état spécifique « rollback completed » n'est distingué dans `PipelineStateChangeRule` (seulement les états génériques de pipeline) — pas de notification dédiée au rollback trouvée. |
| US-04 (Manager) | Dashboard : durée moyenne, taux de succès 7j, nb déploiements | ✅ | `PipelineDashboard` couvre ces 3 métriques (widgets dédiés). |
| US-04 | Alarme >15min → email d'alerte | ⚠️ | Alarme présente et correcte (Tableau 5), mais l'abonnement email (`AlarmEmailSubscription`) est conditionnel à un paramètre `AlarmEmail` vide par défaut — sans le renseigner au déploiement, aucun email ne part réellement. |
| US-05 (Développeur) | Scan ECR bloque le déploiement si vulnérabilités CRITICAL | ❌ | `ecr.yaml` active bien `ScanOnPush: true`, mais **aucune étape du pipeline (buildspec, CodePipeline) ne lit ni ne réagit aux résultats de ce scan** — le scan a lieu mais rien ne le consomme pour bloquer un déploiement. |
| US-05 | Vulnérabilités HIGH → notification sans bloquer | ❌ | Idem — aucune intégration trouvée entre le scan ECR et SNS/CloudWatch. |

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
| AWS Secrets Manager | ❌ | `iam.yaml` (permission IAM uniquement, aucun secret réel) |
| Amazon CloudWatch | ✅ | `observability.yml` |
| AWS SNS | ✅ | `pipeline.yml`, `observability.yml` |

---

## Ce qu'il reste à faire (par ordre de priorité)

| Priorité | Sujet | Description |
|---|---|---|
| 🔴 Bloquant | Déploiement AWS réel | Aucune ressource n'a jamais été déployée sur un vrai compte AWS. CodeBuild, ALB, ECS, CodeDeploy et CodePipeline eux-mêmes (11 des ~17 ressources de `pipeline.yml`) ne sont validés que par `cfn-lint`, jamais exécutés. |
| 🟠 Majeur | Secrets Manager non câblé | Créer une ressource `AWS::SecretsManager::Secret` et ajouter un bloc `Secrets:` dans les DEUX task definitions (`ecs-task-definition.yaml` et `taskdef.template.json`) pour au moins un secret, afin de rendre l'exigence F3 réellement fonctionnelle. |
| 🟠 Majeur | Auto Scaling ECS absent | Ajouter un `AWS::ApplicationAutoScaling::ScalableTarget` + `ScalingPolicy` (cible CPU) sur le service ECS. |
| 🟡 Mineur | Traffic shift non conforme aux paliers | Créer un `AWS::CodeDeploy::DeploymentConfig` personnalisé pour coller aux paliers 10 % → 50 % → 100 % du CDC, au lieu de la rampe linéaire prédéfinie actuelle. |
| 🟡 Mineur | Rétention CloudWatch Logs CodeBuild | Ajouter une ressource `AWS::Logs::LogGroup` avec `RetentionInDays: 30` pour le log group CodeBuild dans `codebuild.yaml`. |
| 🟡 Mineur | Scan ECR non exploité | Ajouter une étape (buildspec ou action CodePipeline) qui lit le résultat du scan ECR (`ScanOnPush`) et bloque sur CRITICAL / notifie sur HIGH (US-05). |
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

---

*Ce rapport complète `so-far.md` (journal d'avancement chronologique) avec une vue de traçabilité
exigence-par-exigence par rapport au cahier des charges fourni. Il doit être régénéré/mis à jour si le CDC
ou l'implémentation évoluent significativement.*
