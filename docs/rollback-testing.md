Oui. Pour ton projet, le test le plus propre est :

**déploiement #1 sain → déploiement #2 volontairement non sain → CodeDeploy détecte l'échec du health check → rollback automatique → Blue reste en production.**

C'est exactement le scénario demandé par le CDC : Blue/Green, traffic shifting 10 % → 50 % → 100 %, et rollback automatique en cas d'échec des health checks. 

## 1. D'abord : vérifier que l'auto-rollback est réellement activé

Après ton premier déploiement réussi :

```powershell
aws deploy get-deployment-group `
  --application-name taskmanager-dev-app `
  --deployment-group-name taskmanager-dev-dg `
  --region eu-west-2 `
  --query "deploymentGroupInfo.autoRollbackConfiguration"
```

### Tu veux voir

```text
enabled : True
events  : DEPLOYMENT_FAILURE
```

Si ce n'est **pas** activé, active-le :

```powershell
aws deploy update-deployment-group `
  --application-name taskmanager-dev-app `
  --current-deployment-group-name taskmanager-dev-dg `
  --auto-rollback-configuration enabled=true,events=DEPLOYMENT_FAILURE `
  --region eu-west-2
```

Puis revérifie :

```powershell
aws deploy get-deployment-group `
  --application-name taskmanager-dev-app `
  --deployment-group-name taskmanager-dev-dg `
  --region eu-west-2 `
  --query "deploymentGroupInfo.autoRollbackConfiguration"
```

**Ne continue pas tant que `enabled=True` n'est pas confirmé.**

---

# 2. Prouver que la version 1 est saine

Avant de casser volontairement la V2 :

```powershell
$dns = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-alb-dns'].Value" `
  --output text

Invoke-RestMethod "http://$dns/health"
```

Tu dois avoir :

```text
status : ok
```

Puis :

```powershell
aws deploy list-deployments `
  --application-name taskmanager-dev-app `
  --deployment-group-name taskmanager-dev-dg `
  --region eu-west-2 `
  --query "deployments[0:5]" `
  --output table
```

Et :

```powershell
aws ecs describe-services `
  --cluster taskmanager-dev-cluster `
  --services taskmanager-dev-service `
  --region eu-west-2 `
  --query "services[0].{Desired:desiredCount,Running:runningCount,Controller:deploymentController.type}" `
  --output table
```

Tu dois avoir :

```text
Desired    Running    Controller
1          1          CODE_DEPLOY
```

Le guide confirme que le service ECS utilise `DeploymentController: CODE_DEPLOY` et que le service est relié au target group Blue. 

---

# 3. Créer volontairement une V2 qui échoue au health check

C'est la méthode que je recommande.

Ton ALB utilise :

```text
/health
```

comme health check. 

Dans ton application, modifie **temporairement** `/health` pour retourner HTTP 500.

Par exemple, si ton application Node/Express contient :

```javascript
app.get('/health', (req, res) => {
    res.status(200).json({ status: 'ok' });
});
```

pour le test V2, remplace temporairement par :

```javascript
app.get('/health', (req, res) => {
    res.status(500).json({ status: 'rollback-test' });
});
```

**Ne change rien d'autre.**

Puis :

```powershell
git add .
git commit -m "test rollback - unhealthy health check"
git push origin main
```

---

# 4. Regarder le pipeline

Immédiatement :

```powershell
aws codepipeline get-pipeline-state `
  --name taskmanager-dev-pipeline `
  --region eu-west-2 `
  --query "stageStates[].{Stage:stageName,Status:latestExecution.status}" `
  --output table
```

Tu veux voir quelque chose comme :

```text
Source       Succeeded
Build        Succeeded
Scan         Succeeded
Deploy       InProgress
```

Puis :

```powershell
aws deploy list-deployments `
  --application-name taskmanager-dev-app `
  --deployment-group-name taskmanager-dev-dg `
  --region eu-west-2 `
  --query "deployments[0:3]" `
  --output table
```

Récupère l'ID :

```powershell
$deploymentId = aws deploy list-deployments `
  --application-name taskmanager-dev-app `
  --deployment-group-name taskmanager-dev-dg `
  --region eu-west-2 `
  --query "deployments[0]" `
  --output text

$deploymentId
```

---

# 5. Suivre le rollback en temps réel

```powershell
aws deploy get-deployment `
  --deployment-id $deploymentId `
  --region eu-west-2 `
  --query "deploymentInfo.{Status:status,Error:errorInformation,Creator:creator}" `
  --output table
```

Répète la commande pendant le déploiement.

### Tu dois observer

D'abord :

```text
InProgress
```

puis :

```text
Failed
```

et les informations d'erreur doivent indiquer un problème de déploiement/health check.

Le CDC définit précisément ce scénario : si les health checks échouent pendant le déploiement, CodeDeploy doit annuler le déploiement. 

---

# 6. Vérifier les target groups Blue / Green

C'est une **preuve très importante**.

```powershell
aws elbv2 describe-target-groups `
  --load-balancer-arn $(
      aws elbv2 describe-load-balancers `
        --names taskmanager-dev-alb `
        --region eu-west-2 `
        --query "LoadBalancers[0].LoadBalancerArn" `
        --output text
  ) `
  --region eu-west-2 `
  --query "TargetGroups[].{Name:TargetGroupName,Port:Port,ARN:TargetGroupArn}" `
  --output table
```

Tu dois avoir deux target groups :

```text
taskmanager-dev-...blue
taskmanager-dev-...green
```

Le guide confirme que l'ALB possède deux target groups, **Blue et Green**, ainsi qu'un listener production et un listener de test. 

---

# 7. La preuve la plus forte : vérifier que Blue revient en production

Après le rollback :

```powershell
aws deploy get-deployment `
  --deployment-id $deploymentId `
  --region eu-west-2 `
  --query "deploymentInfo.status"
```

Attendu :

```text
Failed
```

Puis :

```powershell
Invoke-RestMethod "http://$dns/health"
```

La production doit à nouveau répondre :

```text
status : ok
```

C'est essentiel : **la V2 est rejetée, mais l'application V1 reste disponible.**

---

# 8. Vérifier l'état ECS après rollback

```powershell
aws ecs describe-services `
  --cluster taskmanager-dev-cluster `
  --services taskmanager-dev-service `
  --region eu-west-2 `
  --query "services[0].deployments[].{ID:id,Status:status,TaskDefinition:taskDefinition,Desired:desiredCount,Running:runningCount}" `
  --output table
```

Après rollback, tu veux essentiellement retrouver **la version saine** en production.

Puis :

```powershell
aws ecs list-tasks `
  --cluster taskmanager-dev-cluster `
  --service-name taskmanager-dev-service `
  --region eu-west-2 `
  --desired-status RUNNING
```

---

# 9. Vérifier précisément pourquoi la V2 a été rejetée

```powershell
aws deploy get-deployment `
  --deployment-id $deploymentId `
  --region eu-west-2 `
  --query "deploymentInfo.errorInformation"
```

Puis :

```powershell
aws ecs describe-services `
  --cluster taskmanager-dev-cluster `
  --services taskmanager-dev-service `
  --region eu-west-2 `
  --query "services[0].events[0:10].message" `
  --output table
```

Et les logs :

```powershell
aws logs tail /ecs/taskmanager-dev `
  --region eu-west-2 `
  --since 10m
```

---

# 10. Console AWS : les 3 écrans à capturer

### A. CodePipeline

[CodePipeline — eu-west-2](https://eu-west-2.console.aws.amazon.com/codesuite/codepipeline/pipelines/taskmanager-dev-pipeline/view?region=eu-west-2&utm_source=chatgpt.com)

Capture montrant :

```text
Source    ✓
Build     ✓
Scan      ✓
Deploy    ✗
```

---

### B. CodeDeploy

[CodeDeploy Deployments — eu-west-2](https://eu-west-2.console.aws.amazon.com/codesuite/codedeploy/deployments?region=eu-west-2&utm_source=chatgpt.com)

C'est **la meilleure capture pour ton rapport**.

Tu veux montrer :

```text
Deployment
   ↓
Green environment
   ↓
Health check failure
   ↓
Deployment failed
   ↓
Rollback
   ↓
Blue remains active
```

Le guide indique également que l'écran CodeDeploy **Traffic shifting progress** est la vue la plus parlante pour démontrer le Blue/Green. 

---

### C. ECS

[ECS Clusters — eu-west-2](https://eu-west-2.console.aws.amazon.com/ecs/v2/clusters?region=eu-west-2&utm_source=chatgpt.com)

Montre :

```text
Service
Deployment controller: CODE_DEPLOY
Running: 1
Desired: 1
```

---

# 11. Attention : ton test `/health = 500` peut échouer avant le traffic shift

C'est normal.

Si CodeDeploy détecte que Green n'est jamais `healthy`, il peut échouer **avant même le 10 %**.

Cela prouve :

> **Green unhealthy → deployment failure → automatic rollback**

mais pas forcément :

> **10 % → 50 % → health failure → rollback**

Le CDC demande le traffic shifting 10 % → 50 % → 100 % et le rollback en cas de health-check failure pendant le shift. 

### Pour une démonstration encore plus forte

Une deuxième approche consiste à provoquer une défaillance **après que Green est devenu healthy**, pendant le traffic shifting, par exemple avec une alarme/condition de déploiement. Mais je ne te conseille pas de commencer par cela : c'est plus délicat et dépend exactement de la configuration de ton `pipeline.yml`/CodeDeploy.

---

# 12. Restaurer immédiatement l'application

Une fois la preuve obtenue :

```javascript
app.get('/health', (req, res) => {
    res.status(200).json({ status: 'ok' });
});
```

Puis :

```powershell
git add .
git commit -m "restore healthy health check"
git push origin main
```

Fais **un dernier déploiement sain**, vérifie :

```powershell
Invoke-RestMethod "http://$dns/health"
```

Puis tu peux supprimer toute l'infrastructure.

---

## Ce qui constitue la preuve finale du CDC

| Preuve                   | Résultat attendu              |
| ------------------------ | ----------------------------- |
| V1                       | `Succeeded`                   |
| V1 `/health`             | HTTP 200                      |
| V2                       | nouvelle image/commit         |
| Green                    | créé                          |
| Green health check       | `unhealthy`                   |
| CodeDeploy               | `Failed`                      |
| Auto rollback            | `enabled=True`                |
| Blue                     | reste production              |
| `/health` après rollback | HTTP 200                      |
| CodePipeline             | Deploy échoué                 |
| ECS                      | service toujours opérationnel |

Le CDC demande explicitement le test d'un rollback automatique par simulation d'échec. 

### Trois approches

1. **`/health` → 500 — recommandée** : simple, contrôlée, reproductible.
2. **Arrêter volontairement une tâche Green** : utile si tu veux provoquer une panne runtime, mais plus difficile à synchroniser.
3. **Alarme CloudWatch pendant le traffic shift** : meilleure démonstration avancée, mais seulement si ton CodeDeploy est configuré pour utiliser cette alarme.

**À faire maintenant : avant de modifier GitHub, exécute la commande de l'étape 1 et donne-moi exactement la sortie de `autoRollbackConfiguration`.** C'est elle qui détermine si ton infrastructure actuelle est réellement prête pour le test de rollback.
