# Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate
# Pipeline CI/CD complet avec AWS CodePipeline, ECS Fargate

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

*(Mis à jour le 2026-08-14. Détail exhaustif exigence par exigence dans
[`CONFORMITE_CDC.md`](CONFORMITE_CDC.md), journal chronologique complet dans
[`so-far.md`](so-far.md).)*

### Fait

- **Infrastructure** : les 12 stacks CloudFormation sont écrites, `cfn-lint`
  propre, et le graphe d'exports/imports entre stacks est cohérent de bout en
  bout (VPC → Secrets Manager → ECR → CodeBuild → IAM → cluster/ALB/task
  definition/service ECS → pipeline CodePipeline + CodeDeploy Blue/Green →
  autoscaling → observabilité). Tous les commentaires/descriptions sont en
  anglais ; les valeurs métier (UI de l'app, tags AWS) restent en français.
- **Application** (`task-manager/`, Node.js/Express) : liste, ajout,
  édition, bascule, suppression, recherche plein texte, filtres
  (statut/priorité) et tri (récence/échéance/priorité/titre), échéances
  optionnelles avec indicateur de retard. 61 tests (Jest + Supertest),
  couverture ~99 % (lignes/branches), seuil bloquant à 80 %.
- **Quality gates** : SAST (Semgrep) bloquant sur `main` et sur PR (vérifié
  empiriquement dans les deux sens sur GitHub Actions : bloque un vrai
  finding, puis passe une fois corrigé), image Docker multi-stage mesurée à
  48 Mo (cible < 200 Mo), scan de vulnérabilités ECR exploité (bloque sur
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

- **Aucun déploiement AWS réel n'a encore réussi de bout en bout** — c'est le
  seul point vraiment bloquant. Tout ce qui précède est validé par
  `cfn-lint`, par LocalStack (dans la limite de ses services Pro-only : ALB,
  ECS, CodeDeploy, CodePipeline, CodeBuild et CodeStar Connections ne sont
  pas émulés), et par lecture statique très poussée — jamais encore par une
  exécution réelle du pipeline sur un compte AWS.
- Traffic shift en rampe linéaire (`ECSLinear10PercentEvery1Minute`) plutôt
  qu'en paliers exacts 10 % → 50 % → 100 % : AWS n'offre pas de configuration
  CodeDeploy ECS prédéfinie avec ces paliers précis, c'est l'équivalent le
  plus proche.
- Pas de stage `ManualApproval` : l'état « approval pending » de F4 n'a donc
  rien à notifier pour l'instant (la permission SNS correspondante est déjà
  prévue dans `iam.yaml`, en attente de ce stage).
- Pas de notification distincte « rollback completed » (seuls les états
  génériques du pipeline sont notifiés).
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
| `tests/` | 61 tests Jest + Supertest — couverture ~99 %, seuil bloquant à 80 % |
| `Dockerfile` | Build multi-stage, utilisateur non-root, `HEALTHCHECK` — image mesurée à **48 Mo** (cible < 200 Mo) |
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

## 📐 Documentation & diagrammes d'architecture

Voir [`infrastructure/README.md`](infrastructure/README.md) pour la
documentation complète de l'infrastructure : architecture AWS globale, flux
de déploiement, flux du pipeline CodePipeline, rôles IAM, réseau (VPC), et
déploiement Blue/Green — chacun avec un diagramme et une explication.

L'avancement du projet (ce qui est fait, testé, prochaine étape) est suivi
dans [`so-far.md`](so-far.md), et la conformité au cahier des charges
(exigence par exigence) dans [`CONFORMITE_CDC.md`](CONFORMITE_CDC.md).

---
