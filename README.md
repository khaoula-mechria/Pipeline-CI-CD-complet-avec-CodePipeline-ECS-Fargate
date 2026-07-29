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

## 🗂️ Application

Tout le code applicatif vit dans [`task-manager/`](task-manager/) — c'est la
**seule** application du dépôt, et il n'y a pas de manifeste Node à la racine :

| Fichier | Rôle |
|---|---|
| `src/app.js` | Routes Express : `/` (UI HTML), `/add`, `/toggle/:id`, `/delete/:id`, `/api/tasks`, `/health` |
| `src/tasks.js` | Store des tâches, en mémoire (voir le commentaire d'en-tête pour le pourquoi) |
| `src/views.js` | Rendu HTML sans moteur de template (zéro dépendance ajoutée) |
| `tests/` | Tests Jest + Supertest (couverture 100 %, seuil du pipeline : 80 %) |
| `Dockerfile` | Build multi-stage, utilisateur non-root, `HEALTHCHECK` — image mesurée à **48 Mo** (cible < 200 Mo) |
| `buildspec.yml` | Phases CodeBuild : install → SAST → build → tests + push ECR |

```bash
cd task-manager
npm ci
npm test        # tests + couverture
npm start       # http://localhost:3000
```

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
