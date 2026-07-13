# Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate
# Pipeline CI/CD complet avec AWS CodePipeline, ECS Fargate

Ce projet démontre la mise en place d’un pipeline **CI/CD complet** pour une application (HTML + Python) en utilisant les services AWS, notamment :

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
