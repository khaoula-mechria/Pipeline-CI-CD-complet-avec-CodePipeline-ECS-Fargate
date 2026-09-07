# Pipeline CI/CD complet avec AWS CodePipeline et ECS Fargate

Ce projet démontre la mise en place d’un pipeline **CI/CD complet** pour une
application web conteneurisée (**Node.js / Express**, interface HTML) en
utilisant les services AWS, notamment :

- **AWS CodePipeline** (orchestration CI/CD)
- **AWS CodeBuild** (build et tests)
- **Amazon ECR** (stockage des images Docker)
- **Amazon ECS Fargate** (déploiement serverless de conteneurs)

---

## 📌 Objectif du projet

Automatiser le cycle de livraison d’une application conteneurisée :

1. Récupération du code source  
2. Build + tests  
3. Construction et push de l’image Docker vers ECR  
4. Déploiement automatique sur ECS Fargate  

---

## ✅ État actuel — ce qui est fait, ce qui ne l'est pas

*(Mis à jour le 2026-09-07. Détail exhaustif exigence par exigence dans
[`CONFORMITE_CDC.md`](CONFORMITE_CDC.md), journal chronologique complet dans
[`so-far.md`](so-far.md), preuves du run réel dans [`rapport.md`](rapport.md).)*

### Fait

- **Un run end-to-end réel a réussi sur AWS** : push GitHub → CodePipeline →
  CodeBuild (SAST, tests, image) → ECR → scan Inspector v2 → approbation
  manuelle → CodeDeploy Blue/Green → ECS Fargate, avec bascule de 100 % du
  trafic vers GREEN derrière l'ALB. Déroulé détaillé dans
  [`rapport.md`](rapport.md), 17 captures dans [`preuves/`](preuves/).
- **Stage `ManualApproval`** présent et conditionnel (paramètre
  `EnableManualApproval` de `pipeline.yml`) — vu en fonctionnement pendant le
  run réel (`preuves/01-pipeline-mid-run-approval.png`).
- **Infrastructure** : les 12 stacks CloudFormation sont écrites, `cfn-lint`
  propre, et le graphe d'exports/imports entre stacks est cohérent de bout en
  bout (VPC → Secrets Manager → ECR → CodeBuild → IAM → cluster/ALB/task
  definition/service ECS → pipeline CodePipeline + CodeDeploy Blue/Green →
  autoscaling → observabilité). Tous les commentaires/descriptions sont en
  anglais ; les valeurs métier (UI de l'app, tags AWS) restent en français.
- **Application** (`task-manager/`, Node.js/Express) : liste, ajout,
  édition, bascule, suppression, recherche plein texte, filtres
  (statut/priorité) et tri (récence/échéance/priorité/titre), échéances
  optionnelles avec indicateur de retard. 63 tests (Jest + Supertest),
  couverture ~99 % (lignes/branches), seuil bloquant à 80 %.
- **Quality gates** : SAST (Semgrep) bloquant sur `main` et sur PR (vérifié
  empiriquement dans les deux sens sur GitHub Actions : bloque un vrai
  finding, puis passe une fois corrigé), image Docker multi-stage mesurée à
  50,2 Mo (cible < 200 Mo), scan de vulnérabilités ECR exploité (bloque sur
  CRITICAL, notifie sans bloquer sur HIGH).
- **Secrets** injectés via Secrets Manager (jamais en clair) ; **autoscaling**
  Target Tracking CPU à 70 % (2 à 6 tâches) ; **observabilité** : dashboard
  CloudWatch (durée pipeline, taux de succès, latence ALB, CPU/mémoire ECS),
  logs à rétention 30 jours, alarme si le pipeline dépasse 15 min.
- **Audit complet du 2026-08-14** : 3 bugs qui auraient chacun fait échouer
  un déploiement réel de bout en bout, même le tout premier, ont été trouvés
  et corrigés — le chemin de `appspec.yaml` dans `pipeline.yml` (Deploy
  n'aurait jamais trouvé le fichier), la policy du topic SNS qui ne laissait
  passer que les notifications EventBridge et pas celles des alarmes
  CloudWatch (les alarmes se seraient déclenchées sans jamais notifier
  personne), et des permissions IAM manquantes pour les report groups que
  `buildspec.yml` utilise (le build aurait échoué juste après le scan ECR).
  Le conflit `ECR IMMUTABLE` + tag `latest` identifié depuis le 2026-07-28
  est également résolu.

### Pas fait, ou connu et non bloquant

- Traffic shift en rampe linéaire (`ECSLinear10PercentEvery1Minute`) plutôt
  qu'en paliers exacts 10 % → 50 % → 100 % : AWS n'offre pas de configuration
  CodeDeploy ECS prédéfinie avec ces paliers précis, c'est l'équivalent le
  plus proche.
- Une image `:latest` doit être poussée manuellement **une fois** avant le
  premier déploiement du service ECS : `ecs-task-definition.yaml` s'appuie sur
  ce tag tant que le pipeline n'a jamais tourné (bootstrap, voir `rapport.md`).
- Pas de notification distincte « rollback completed » (seuls les états
  génériques du pipeline sont notifiés). La procédure de test du rollback est
  décrite dans [`docs/rollback-testing.md`](docs/rollback-testing.md), mais
  n'a pas encore été exécutée sur le compte réel.
- Protection de branche GitHub pas encore activée — réglage à faire dans les
  paramètres du dépôt GitHub, pas dans le code.
- Le store de tâches reste en mémoire (choix assumé, voir l'en-tête de
  `src/tasks.js`) : les secrets DB sont bien injectés dans le conteneur mais
  non utilisés, faute de base de données réelle branchée.

---

## 🗂️ Application

Tout le code applicatif vit dans [`task-manager/`](task-manager/) — c'est la
**seule** application du dépôt, et il n'y a pas de manifeste Node à la racine :

| Fichier | Rôle |
|---|---|
| `src/app.js` | Routes Express : `/` (UI HTML, avec recherche/filtres/tri en query string), `/add`, `/edit/:id`, `/toggle/:id`, `/delete/:id`, `/api/tasks`, `/health` |
| `src/tasks.js` | Store des tâches, en mémoire (voir le commentaire d'en-tête pour le pourquoi) — CRUD complet, filtrage et tri |
| `src/views.js` | Rendu HTML sans moteur de template (zéro dépendance ajoutée) — barre de recherche/filtres, formulaire d'édition par tâche |
| `tests/` | 63 tests Jest + Supertest — couverture ~99 %, seuil bloquant à 80 % |
| `Dockerfile` | Build multi-stage, utilisateur non-root, `HEALTHCHECK` — image mesurée à **50,2 Mo** (cible < 200 Mo) |
| `buildspec.yml` | Phases CodeBuild : install → SAST → build → tests + push ECR |

```bash
cd task-manager
npm ci
npm test        # tests + couverture (échoue sous 80 %)
npm start       # http://localhost:3000
```

Rapports produits à chaque `npm test` : `coverage/lcov-report/` (HTML),
`coverage/cobertura-coverage.xml` (XML, lu nativement par CodeBuild) et
`reports/junit.xml` — tous les trois publiés en artefacts par les deux CI.

Les mêmes quality gates (SAST Semgrep, tests, seuil de couverture 80 %) sont
exécutés par [`.github/workflows/ci.yml`](.github/workflows/ci.yml) avant merge
et par `task-manager/buildspec.yml` dans CodeBuild.

---

## 🛠️ Outils locaux (branche `develop`)

Quatre modules Python qui s'ajoutent au pipeline **sans rien y remplacer**. Ils
tournent en local ; le pipeline AWS ne dépend d'aucun d'eux.

| Module | Rôle | Lancer |
|---|---|---|
| [`orchestrator/`](orchestrator/README.md) | Déploie les 12 stacks en **vagues parallèles**, l'ordre étant déduit des dépendances réelles entre templates (22 dépendances → 7 vagues au lieu de 12 étapes) | `python -m orchestrator graph` |
| [`optimizer/`](optimizer/README.md) | Analyse le service ECS et compare une règle de rightsizing maison à **AWS Compute Optimizer** | `python -m optimizer analyze --sample` |
| [`explainer/`](explainer/README.md) | Traduit le rapport précédent en explication lisible (API Anthropic), avec application **sous validation humaine explicite** | `python -m explainer explain --sample` |
| [`dashboard/`](dashboard/README.md) | Tableau de bord Streamlit : graphe de déploiement en direct, optimisation, explication | `streamlit run dashboard/app.py` |

```bash
pip install -r requirements-modules.txt
python -m pytest orchestrator/ optimizer/ explainer/ dashboard/   # 67 tests, hors ligne
```

Tous les tests tournent **sans AWS ni clé d'API**. Chaque module a son propre
README avec la commande exacte et les variables d'environnement attendues.

> À noter : `orchestrator` lit les templates de `infrastructure/cloudformation/`
> et en déduit l'ordre de déploiement. C'est cette analyse qui fait autorité,
> pas l'ordre écrit dans les guides — `guide.md` et `guideme2.md` placent tous
> deux IAM avant CodeBuild, alors que `iam.yaml` importe l'export
> `…-codebuild-arn` et exige donc l'inverse.

---

## 📚 Documentation — quel fichier sert à quoi

| Document | Contenu | Quand le lire |
|---|---|---|
| [`guideme2.md`](guideme2.md) | Runbook de déploiement, étape par étape | Pour déployer sur AWS |
| [`rapport.md`](rapport.md) | Preuve du run end-to-end réussi (+ [`preuves/`](preuves/)) | Pour vérifier ce qui a réellement tourné |
| [`CONFORMITE_CDC.md`](CONFORMITE_CDC.md) | Conformité au cahier des charges, exigence par exigence | Pour l'évaluation |
| [`so-far.md`](so-far.md) | Journal chronologique du projet | Pour l'historique des décisions |
| [`infrastructure/README.md`](infrastructure/README.md) | Architecture AWS, réseau, IAM, Blue/Green — avec diagrammes | Pour comprendre l'infrastructure |
| [`docs/rollback-testing.md`](docs/rollback-testing.md) | Procédure de test du rollback automatique | Pour prouver F3 |
| [`infrastructure/scripts/README-tests-locaux.md`](infrastructure/scripts/README-tests-locaux.md) | Validation locale (cfn-lint, LocalStack) | Pour tester sans compte AWS |
| [`guide.md`](guide.md) | Guide de déploiement d'origine, plus discursif | Archive — `guideme2.md` le remplace |

---
