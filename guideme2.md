Oui. Tu es maintenant dans le bon scénario : **région `eu-west-2`, SSO configuré, aucun stack existant, 12 templates présents dans `infrastructure/cloudformation/`**.

Le CDC exige notamment CodePipeline, CodeBuild, ECR, ECS Fargate, CodeDeploy Blue/Green, ALB, Secrets Manager, CloudWatch/SNS, tests ≥80 %, SAST, scan Docker, autoscaling et rollback. 

Je te conseille de faire **un seul déploiement complet + un seul test de pipeline + suppression immédiate**, avec `DesiredCount=1` pour limiter le coût.

---

# 0. Avant de commencer — verrouiller la région

Dans PowerShell, depuis la **racine du projet** :

```powershell
cd "C:\Users\user\Desktop\Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate"

$env:AWS_PROFILE="taskmanager"
$env:AWS_DEFAULT_REGION="eu-west-2"

aws sso login --profile taskmanager
```

Puis :

```powershell
aws sts get-caller-identity --profile taskmanager
aws configure get region --profile taskmanager
```

### Tu dois voir

```text
eu-west-2
```

et dans `get-caller-identity` :

```text
arn:aws:sts::XXXXXXXXXXXX:assumed-role/AWSReservedSSO_AdministratorAccess...
```

Le guide confirme que `AdministratorAccess` est le rôle à utiliser pour pouvoir créer VPC, IAM et pipelines. 

---

# 1. Vérifier qu'il n'y a vraiment aucune stack

```powershell
aws cloudformation list-stacks `
  --region eu-west-2 `
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE `
  --query "StackSummaries[].StackName" `
  --output table
```

### Attendu

Aucune stack `taskmanager-dev-*`.

---

# 2. Vérifier les 12 templates AVANT de créer quoi que ce soit

C'est important.

```powershell
$files = @(
    "vpc.yml",
    "iam.yaml",
    "secrets-manager.yaml",
    "ecr.yaml",
    "codebuild.yaml",
    "ecs-cluster.yaml",
    "alb.yaml",
    "ecs-task-definition.yaml",
    "ecs-service.yaml",
    "pipeline.yml",
    "ecs-autoscaling.yaml",
    "observability.yml"
)

foreach ($f in $files) {
    Write-Host "`n===== $f =====" -ForegroundColor Cyan
    aws cloudformation validate-template `
        --template-body "file://infrastructure/cloudformation/$f" `
        --region eu-west-2 `
        --query "Description" `
        --output text
}
```

### Ce que tu veux

Aucune erreur du type :

```text
Template format error
```

ou

```text
ValidationError
```

**Si un seul template échoue : STOP ici.** Ne déploie pas les stacks suivantes.

---

# 3. Déployer VPC

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/vpc.yml `
  --stack-name taskmanager-dev-vpc `
  --parameter-overrides ProjectName=taskmanager Environment=dev NatGatewayStrategy=single `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Attends :

```text
Successfully created/updated stack - taskmanager-dev-vpc
```

### Vérification

```powershell
aws cloudformation describe-stacks `
  --stack-name taskmanager-dev-vpc `
  --region eu-west-2 `
  --query "Stacks[0].{Status:StackStatus,Outputs:Outputs}" `
  --output table
```

Puis :

```powershell
aws ec2 describe-vpcs `
  --region eu-west-2 `
  --filters "Name=tag:Name,Values=taskmanager-dev-vpc" `
  --query "Vpcs[].{VPC:VpcId,CIDR:CidrBlock,State:State}" `
  --output table
```

Et :

```powershell
aws ec2 describe-nat-gateways `
  --region eu-west-2 `
  --filter "Name=state,Values=available" `
  --query "NatGateways[].{ID:NatGatewayId,State:State}" `
  --output table
```

### Confirmation CDC

Tu dois avoir le réseau nécessaire : VPC, subnets et security groups. Le CDC demande explicitement cette infrastructure. 

---

# 4. IAM + GitHub Connection

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/iam.yaml `
  --stack-name taskmanager-dev-iam `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Vérifie :

```powershell
aws iam list-roles `
  --region eu-west-2 `
  --query "Roles[?starts_with(RoleName,'taskmanager-dev')].RoleName" `
  --output table
```

Puis :

```powershell
aws codestar-connections list-connections `
  --region eu-west-2 `
  --query "Connections[].{Name:ConnectionName,Status:ConnectionStatus}" `
  --output table
```

### Important

Tu dois probablement voir :

```text
taskmanager-dev-github    PENDING
```

C'est normal.

Console :

[AWS CodeConnections — eu-west-2](https://eu-west-2.console.aws.amazon.com/codesuite/settings/connections?region=eu-west-2&utm_source=chatgpt.com)

Clique :

**Update pending connection → GitHub → Authorize**

Puis reviens à :

```powershell
aws codestar-connections list-connections `
  --region eu-west-2 `
  --query "Connections[].{Name:ConnectionName,Status:ConnectionStatus}" `
  --output table
```

### Il faut obtenir

```text
taskmanager-dev-github    AVAILABLE
```

Le CDC demande bien GitHub comme source et un déclenchement automatique du pipeline. 

---

# 5. Secrets Manager

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/secrets-manager.yaml `
  --stack-name taskmanager-dev-secrets `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Vérifie :

```powershell
aws secretsmanager list-secrets `
  --region eu-west-2 `
  --query "SecretList[?starts_with(Name,'taskmanager')].Name" `
  --output table
```

### Confirmation CDC

Les secrets doivent être dans Secrets Manager et non dans les variables CodeBuild en clair. C'est une exigence explicite du CDC. 

---

# 6. ECR

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/ecr.yaml `
  --stack-name taskmanager-dev-ecr `
  --parameter-overrides ProjectName=taskmanager Environment=dev MaxImageCount=10 `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Vérifie :

```powershell
aws ecr describe-repositories `
  --repository-names taskmanager-dev `
  --region eu-west-2 `
  --query "repositories[0].{URI:repositoryUri,ScanOnPush:imageScanningConfiguration.scanOnPush,TagMutability:imageTagMutability}" `
  --output table
```

### Très important

Le CDC demande :

* image Docker ;
* tag SHA du commit ;
* push ECR ;
* scan vulnérabilités. 

Ton guide signale toutefois un problème potentiel :

```text
IMMUTABLE
```

avec un `buildspec` qui pousse :

```text
latest
```

Cela peut casser le **deuxième build**. 

**Ne modifie rien maintenant si ton premier objectif est simplement de faire le test.**

---

# 7. CodeBuild

Ici tu dois mettre **ton vrai dépôt GitHub**.

Exemple :

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/codebuild.yaml `
  --stack-name taskmanager-dev-codebuild `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      GitHubRepoUrl=https://github.com/khaoula-mechria/Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Puis :

```powershell
aws codebuild list-projects `
  --region eu-west-2 `
  --query "projects[?starts_with(@,'taskmanager-dev')]" `
  --output table
```

Puis :

```powershell
aws codebuild batch-get-projects `
  --names taskmanager-dev-build `
  --region eu-west-2 `
  --query "projects[0].{Name:name,Source:source.type,Repo:source.location,Branch:source.buildspec}" `
  --output table
```

Le CDC demande CodeBuild pour build/test/scan, avec couverture ≥80 % et SAST. 

---

# 8. ECS Cluster

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/ecs-cluster.yaml `
  --stack-name taskmanager-dev-ecs-cluster `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Vérifie :

```powershell
aws ecs describe-clusters `
  --clusters taskmanager-dev-cluster `
  --region eu-west-2 `
  --query "clusters[0].{Name:clusterName,Status:status,Running:runningTasksCount}" `
  --output table
```

Attendu :

```text
ACTIVE    0
```

C'est normal : **Fargate ne nécessite aucune instance EC2**. Le CDC demande explicitement ECS Fargate comme runtime serverless. 

---

# 9. ALB

```powershell
$vpcId = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-vpc-id'].Value" `
  --output text

$pubSub = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-public-subnet-ids'].Value" `
  --output text

$vpcId
$pubSub
```

Les deux doivent retourner une valeur.

Puis :

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/alb.yaml `
  --stack-name taskmanager-dev-alb `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      VpcId=$vpcId `
      "PublicSubnetIds=$pubSub" `
      ContainerPort=3000 `
      HealthCheckPath=/health `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Vérifie :

```powershell
aws elbv2 describe-load-balancers `
  --names taskmanager-dev-alb `
  --region eu-west-2 `
  --query "LoadBalancers[0].{DNS:DNSName,State:State.Code}" `
  --output table
```

Le CDC demande explicitement un ALB et target groups Blue/Green. 

---

# 10. Task Definition

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/ecs-task-definition.yaml `
  --stack-name taskmanager-dev-taskdef `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      ContainerCpu=256 `
      ContainerMemory=512 `
      ContainerPort=3000 `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Vérifie :

```powershell
aws ecs describe-task-definition `
  --task-definition taskmanager-dev-task `
  --region eu-west-2 `
  --query "taskDefinition.{Revision:revision,CPU:cpu,Memory:memory,Image:containerDefinitions[0].image}" `
  --output table
```

---

# 11. ECS Service — **1 seule tâche pour économiser**

Ici je réduis volontairement :

```text
DesiredCount=1
```

Le CDC exige le scaling automatique, mais ne fixe pas le nombre initial de tâches. Le guide indique également que `DesiredCount=1` réduit le coût Fargate. 

```powershell
$vpcId = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-vpc-id'].Value" `
  --output text

$privSub = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-private-subnet-ids'].Value" `
  --output text

aws cloudformation deploy `
  --template-file infrastructure/cloudformation/ecs-service.yaml `
  --stack-name taskmanager-dev-ecs-service `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      VpcId=$vpcId `
      "PrivateSubnetIds=$privSub" `
      ContainerPort=3000 `
      DesiredCount=1 `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Puis :

```powershell
aws ecs describe-services `
  --cluster taskmanager-dev-cluster `
  --services taskmanager-dev-service `
  --region eu-west-2 `
  --query "services[0].{Status:status,Desired:desiredCount,Running:runningCount,Controller:deploymentController.type}" `
  --output table
```

### Attendu

```text
ACTIVE    1    1    CODE_DEPLOY
```

Puis :

```powershell
$tgBlue = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-tg-blue-arn'].Value" `
  --output text

aws elbv2 describe-target-health `
  --target-group-arn $tgBlue `
  --region eu-west-2 `
  --query "TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State}" `
  --output table
```

### Attendu

```text
healthy
```

Puis :

```powershell
$dns = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-alb-dns'].Value" `
  --output text

$dns
Invoke-RestMethod "http://$dns/health"
```

### Tu veux obtenir

```text
status : ok
```

Cela valide concrètement **réseau → ALB → ECS → container → health check**.

---

# 12. Pipeline + CodeDeploy

C'est la partie la plus importante pour le CDC.

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/pipeline.yml `
  --stack-name taskmanager-dev-pipeline `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      FullRepositoryId=TON_USER/TON_REPO `
      BranchName=main `
      EnableManualApproval=true `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Vérifie :

```powershell
aws codepipeline get-pipeline `
  --name taskmanager-dev-pipeline `
  --region eu-west-2 `
  --query "pipeline.stages[].name" `
  --output table
```

Tu dois retrouver les stages définis par ton template.

Puis :

```powershell
aws deploy get-application `
  --application-name taskmanager-dev-app `
  --region eu-west-2
```

Et :

```powershell
aws deploy get-deployment-group `
  --application-name taskmanager-dev-app `
  --deployment-group-name taskmanager-dev-dg `
  --region eu-west-2 `
  --query "deploymentGroupInfo.{Group:deploymentGroupName,ServiceRole:serviceRoleArn,Controller:deploymentStyle.deploymentType}"
```

Le CDC demande CodeDeploy + Blue/Green + traffic shift **10 → 50 → 100 %**. 

---

# 13. Le test qui prouve réellement le CI/CD

Ne fais **qu'un seul** build/pipeline.

```powershell
aws codepipeline start-pipeline-execution `
  --name taskmanager-dev-pipeline `
  --region eu-west-2
```

Puis :

```powershell
aws codepipeline get-pipeline-state `
  --name taskmanager-dev-pipeline `
  --region eu-west-2 `
  --query "stageStates[].{Stage:stageName,Status:latestExecution.status}" `
  --output table
```

### Tu veux voir

```text
Source       Succeeded
Build        Succeeded
...
Deploy       Succeeded
```

Le CDC exige notamment que le push `main` déclenche le pipeline en moins de 60 s, que les tests en échec bloquent le pipeline, et que l'ancienne version reste disponible pendant le traffic shift. 

Pour le vrai test automatique :

```text
git add .
git commit -m "test CI/CD AWS"
git push origin main
```

Puis immédiatement :

```powershell
aws codepipeline get-pipeline-state `
  --name taskmanager-dev-pipeline `
  --region eu-west-2 `
  --query "stageStates[].{Stage:stageName,Status:latestExecution.status}" `
  --output table
```

---

# 14. Autoscaling

Pour économiser :

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/ecs-autoscaling.yml `
  --stack-name taskmanager-dev-autoscaling `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      MinCapacity=1 `
      MaxCapacity=2 `
      TargetCpuUtilization=70 `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Vérifie :

```powershell
aws application-autoscaling describe-scalable-targets `
  --service-namespace ecs `
  --resource-ids service/taskmanager-dev-cluster/taskmanager-dev-service `
  --region eu-west-2 `
  --query "ScalableTargets[0].{Min:MinCapacity,Max:MaxCapacity}" `
  --output table
```

### Attendu

```text
1    2
```

Cela couvre l'exigence HPA-like du CDC. 

---

# 15. Observabilité

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/observability.yml `
  --stack-name taskmanager-dev-observability `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      AlarmEmail=TON_EMAIL `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Vérifie :

```powershell
aws cloudwatch describe-alarms `
  --region eu-west-2 `
  --alarm-name-prefix taskmanager-dev `
  --query "MetricAlarms[].{Name:AlarmName,State:StateValue}" `
  --output table
```

Puis :

```powershell
aws logs describe-log-groups `
  --region eu-west-2 `
  --query "logGroups[?contains(logGroupName,'taskmanager')].{Name:logGroupName,Retention:retentionInDays}" `
  --output table
```

### Attendu

Rétention :

```text
30
```

Le CDC demande logs centralisés avec rétention 30 jours, dashboard CloudWatch, métriques pipeline et alarme >15 min. 

Et confirme le mail SNS :

```powershell
aws sns list-subscriptions `
  --region eu-west-2 `
  --query "Subscriptions[?contains(Endpoint,'@')].{Email:Endpoint,Status:SubscriptionArn}" `
  --output table
```

Si tu reçois **AWS Notification – Subscription Confirmation**, clique dessus.

---

# 16. CHECKLIST CDC — ce qui doit être visible

| CDC                | Preuve à montrer                             |
| ------------------ | -------------------------------------------- |
| CloudFormation/IaC | 12 stacks `CREATE_COMPLETE`                  |
| VPC/subnets/SG     | VPC console + Resource Map                   |
| ECR                | repository + `ScanOnPush=true`               |
| ECS Fargate        | service `ACTIVE`, tasks `RUNNING`            |
| ALB                | DNS + target `healthy`                       |
| Secrets            | secrets présents dans Secrets Manager        |
| CodeBuild          | build `SUCCEEDED`                            |
| Tests ≥80 %        | CodeBuild Reports / coverage                 |
| SAST               | logs CodeBuild + étape SAST                  |
| CodePipeline       | pipeline avec stages réussis                 |
| GitHub trigger     | push `main` → pipeline                       |
| CodeDeploy         | deployment Blue/Green                        |
| 10→50→100          | écran Traffic shifting                       |
| Rollback           | deployment échoué puis rollback              |
| Autoscaling        | `Min=1 Max=2`                                |
| CloudWatch         | dashboard                                    |
| Logs               | `/ecs/...` et `/aws/codebuild/...`, 30 jours |
| SNS                | email reçu                                   |
| Alarme >15 min     | CloudWatch alarm                             |

Cette checklist correspond directement aux exigences fonctionnelles du CDC. 

---

# 17. AVANT de dépasser 1 heure : SUPPRIMER TOUT

**Ne supprime pas dans un ordre arbitraire.**

```powershell
$stacks = @(
    "taskmanager-dev-observability",
    "taskmanager-dev-autoscaling",
    "taskmanager-dev-pipeline",
    "taskmanager-dev-ecs-service",
    "taskmanager-dev-taskdef",
    "taskmanager-dev-alb",
    "taskmanager-dev-ecs-cluster",
    "taskmanager-dev-codebuild",
    "taskmanager-dev-ecr",
    "taskmanager-dev-secrets",
    "taskmanager-dev-iam",
    "taskmanager-dev-vpc"
)

foreach ($s in $stacks) {
    Write-Host "DELETE $s" -ForegroundColor Yellow
    aws cloudformation delete-stack `
        --stack-name $s `
        --region eu-west-2

    aws cloudformation wait stack-delete-complete `
        --stack-name $s `
        --region eu-west-2
}
```

L'ordre inverse est nécessaire à cause des `Fn::ImportValue`. 

---

# 18. Contrôle final — IMPORTANT

```powershell
aws cloudformation list-stacks `
  --region eu-west-2 `
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED `
  --query "StackSummaries[?starts_with(StackName,'taskmanager-dev')].{Stack:StackName,Status:StackStatus}" `
  --output table
```

Puis :

```powershell
aws ec2 describe-nat-gateways `
  --region eu-west-2 `
  --filter "Name=state,Values=available,pending" `
  --query "NatGateways[].{ID:NatGatewayId,State:State}" `
  --output table
```

Puis :

```powershell
aws elbv2 describe-load-balancers `
  --region eu-west-2 `
  --query "LoadBalancers[?contains(LoadBalancerName,'taskmanager')].LoadBalancerName" `
  --output table
```

Puis :

```powershell
aws ecs list-tasks `
  --cluster taskmanager-dev-cluster `
  --region eu-west-2
```

### Objectif final

```text
Stacks taskmanager-dev : aucune
NAT Gateway available : aucune
ALB taskmanager : aucun
ECS running tasks : aucune
```

Le guide donne le même principe de contrôle final. 

---

## Les 3 choses à surveiller particulièrement

**1. ECR `IMMUTABLE` + `latest`**
C'est le problème déjà identifié dans ton guide. Pour le test d'aujourd'hui, fais un seul build. 

**2. GitHub Connection = `AVAILABLE`**
Ne lance pas le pipeline tant que ce n'est pas `AVAILABLE`.

**3. Ne laisse surtout pas le NAT Gateway après le test.**
C'est le principal coût permanent indiqué dans ton guide. 

### Approches

* **Recommandée maintenant :** tout déployer → 1 pipeline réussi → vérifier CDC → supprimer tout.
* **Budget minimal :** arrêter après ECS + ALB, mais tu ne démontres pas le CI/CD complet.
* **Démonstration maximale :** ajouter un deuxième déploiement et provoquer un rollback ; utile uniquement si tu dois réellement montrer le mécanisme Blue/Green/rollback.

**Prochaine étape immédiate : exécute uniquement les étapes 0 → 2 (SSO, région, absence de stacks, validation des 12 YAML). Ne lance aucun déploiement tant que les 12 `validate-template` ne sont pas OK.**
