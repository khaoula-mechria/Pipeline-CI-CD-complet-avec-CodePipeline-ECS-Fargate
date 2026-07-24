# Infrastructure — Documentation & Diagrammes

Documentation de l'infrastructure AWS du projet, entièrement définie en
CloudFormation (`infrastructure/cloudformation/`) et validée localement sans
accès AWS via LocalStack (`infrastructure/scripts/`, voir
[`scripts/testing-output.md`](scripts/testing-output.md) pour les résultats
détaillés de chaque test).

## Les 6 stacks, dans l'ordre de déploiement

| # | Stack | Rôle |
|---|---|---|
| 1 | [`vpc.yml`](cloudformation/vpc.yml) | Réseau : VPC, subnets publics/privés, NAT Gateway(s), VPC Endpoint S3 |
| 2 | [`ecr.yaml`](cloudformation/ecr.yaml) | Registre Docker privé (scan on push, lifecycle policy) |
| 3 | [`iam.yaml`](cloudformation/iam.yaml) | Rôles IAM du pipeline + connexion GitHub (CodeStar Connections) |
| 4 | [`codebuild.yaml`](cloudformation/codebuild.yaml) | Projet CodeBuild (build, tests, SAST, push ECR) |
| 5 | [`pipeline.yml`](cloudformation/pipeline.yml) | CodePipeline + CodeDeploy Blue/Green + ALB + ECS Fargate |
| 6 | [`observability.yml`](cloudformation/observability.yml) | Dashboard CloudWatch + alarmes + métriques custom |

---

## 1. Architecture AWS globale

```mermaid
flowchart TB
    Dev([Développeur]) -->|git push| Repo[Repo GitHub<br/>task-manager]

    subgraph AWS["Compte AWS"]
        direction TB

        Connection["CodeStar Connection<br/>(iam.yaml)"]
        CP["AWS CodePipeline<br/>(pipeline.yml)"]
        CB["AWS CodeBuild<br/>(codebuild.yaml)"]
        ECR[("Amazon ECR<br/>(ecr.yaml)")]
        CD["AWS CodeDeploy<br/>Blue/Green<br/>(pipeline.yml)"]

        subgraph VPC["VPC (vpc.yml)"]
            direction TB
            subgraph Public["Subnets publics x2 AZ"]
                ALB["Application<br/>Load Balancer"]
                NAT["NAT Gateway"]
            end
            subgraph Private["Subnets privés x2 AZ"]
                ECS["ECS Fargate Service<br/>(Blue/Green)"]
            end
        end

        SM[("Secrets Manager")]

        subgraph OBS["Observabilité (observability.yml)"]
            direction TB
            EVB["EventBridge"]
            LBD["Lambda<br/>Metrics Publisher"]
            CW["CloudWatch<br/>Dashboard + Alarmes"]
        end

        SNS["SNS Topic<br/>Notifications"]
    end

    Team([Équipe DevOps])

    Repo -->|webhook push main| Connection --> CP
    CP -->|Source| CP
    CP -->|Build| CB --> ECR
    CB -->|imageDetail.json<br/>taskdef.json| CP
    CP -->|Deploy: CodeDeployToECS| CD
    CD -->|traffic shift 10%→100%| ALB
    ALB --> ECS
    ECS -->|pull image| ECR
    ECS -->|secrets au runtime| SM
    ECS -->|sortie internet| NAT

    CP -.execution state.-> EVB
    EVB -->|notif SUCCESS/FAILED/...| SNS
    EVB -->|à chaque fin d'exécution| LBD --> CW
    CD -.rollback sur échec.-> CD
    CW -.alarme durée/échec.-> SNS
    SNS -->|email optionnel| Team
```

**Lecture** : le code applicatif vit dans un dépôt GitHub dédié (pointé par
`FullRepositoryId`/`GitHubRepoUrl`). Un push sur `main` déclenche
CodePipeline via la connexion CodeStar ; CodeBuild construit, teste et
scanne l'image avant de la pousser sur ECR ; CodeDeploy pilote ensuite un
déploiement Blue/Green sans interruption vers ECS Fargate, derrière un ALB
dans les subnets publics. Toute la couche observabilité (EventBridge →
SNS/Lambda → CloudWatch) est indépendante du chemin de déploiement lui-même
— elle observe, elle ne bloque jamais un déploiement.

---

## 2. Flux de déploiement (Deployment flow)

```mermaid
sequenceDiagram
    actor Dev as Développeur
    participant GH as GitHub
    participant CBW as CodeBuild - webhook direct
    participant CP as CodePipeline
    participant CBP as CodeBuild - action Build
    participant ECRr as Amazon ECR
    participant CDp as CodeDeploy
    participant ECSs as ECS Fargate

    Dev->>GH: git push feature/*
    GH-->>CBW: webhook (build + test uniquement)
    CBW->>CBW: install → SAST → build Docker → tests
    Note over CBW: Pas de déploiement,<br/>juste un retour rapide au développeur

    Dev->>GH: git push main (après merge)
    GH-->>CP: webhook via CodeStar Connection
    activate CP
    CP->>CP: Stage Source (récupère le code)
    CP->>CBP: Stage Build
    activate CBP
    CBP->>CBP: install → SAST → build → tests + coverage ≥ 80%
    CBP->>ECRr: docker push (tag = SHA du commit)
    CBP->>CP: imageDetail.json + taskdef.json
    deactivate CBP
    CP->>CDp: Stage Deploy (action CodeDeployToECS)
    activate CDp
    CDp->>CDp: enregistre nouvelle Task Definition
    CDp->>ECSs: déploie la révision "Green" à côté de "Blue"
    CDp->>CDp: traffic shift progressif (10%→100%, ~10 min)
    alt Health checks OK
        CDp->>CDp: 100% du trafic sur Green, Blue terminée
    else Health checks échouent
        CDp->>ECSs: rollback automatique vers Blue (< 3 min)
    end
    deactivate CDp
    CP-->>Dev: notification SNS (succès/échec)
    deactivate CP
```

**Lecture** : deux chemins distincts et volontairement découplés. Les
branches `feature/*` (et `develop`) sont validées par le webhook CodeBuild
existant depuis `codebuild.yaml` — rapide, sans toucher à la production.
Seul un push sur `main` déclenche le pipeline complet jusqu'au déploiement
Blue/Green réel.

---

## 3. Pipeline flow (stages CodePipeline détaillés)

```mermaid
flowchart LR
    subgraph Source["Stage Source"]
        S1["CodeStarSourceConnection<br/>branch: main"]
    end

    subgraph Build["Stage Build"]
        B1["CodeBuild project<br/>taskmanager-dev-build"]
        B2["buildspec.yml :<br/>install → pre_build (SAST + login ECR)<br/>→ build (docker) → post_build (tests + push)"]
        B3["Artefacts générés :<br/>imageDetail.json<br/>taskdef.json (rendu depuis taskdef.template.json)"]
    end

    subgraph Deploy["Stage Deploy"]
        D1["Action CodeDeployToECS"]
        D2["TaskDefinitionTemplateArtifact = BuildArtifact"]
        D3["AppSpecTemplateArtifact = SourceArtifact<br/>(appspec.yaml)"]
        D4["Image1ContainerName = IMAGE1_NAME"]
    end

    SourceArtifact[("SourceArtifact<br/>(S3, bucket pipeline-artifacts)")]
    BuildArtifact[("BuildArtifact<br/>(S3, bucket pipeline-artifacts)")]

    S1 --> SourceArtifact
    SourceArtifact --> B1
    B1 --> B2 --> B3
    B3 --> BuildArtifact
    SourceArtifact -.->|appspec.yaml| D3
    BuildArtifact -.->|taskdef.json + imageDetail.json| D2
    D2 --> D1
    D3 --> D1
    D4 --> D1
    D1 -->|CreateDeployment| CodeDeploy["AWS CodeDeploy<br/>DeploymentGroup Blue/Green"]
```

**Lecture** : le point clé du câblage est que `taskdef.json` (contenant les
vrais ARN des rôles ECS, rendus au moment du build) vient de l'artefact de
**Build**, alors que `appspec.yaml` (statique, aucune valeur spécifique au
compte) vient directement de l'artefact **Source** — voir
`task-manager/buildspec.yml` et `task-manager/taskdef.template.json`.

---

## 4. Rôles IAM

```mermaid
flowchart LR
    subgraph Services["Services AWS (Principal)"]
        SvcCP["codepipeline.amazonaws.com"]
        SvcCD["codedeploy.amazonaws.com"]
        SvcCB["codebuild.amazonaws.com"]
        SvcECSx["ecs-tasks.amazonaws.com"]
        SvcLambda["lambda.amazonaws.com"]
    end

    subgraph Roles["Rôles IAM (iam.yaml / codebuild.yaml / observability.yml)"]
        RCP["CodePipelineServiceRole"]
        RCD["CodeDeployServiceRole<br/>(managed: AWSCodeDeployRoleForECS)"]
        RCB["CodeBuildServiceRole"]
        RExec["EcsTaskExecutionRole<br/>(managed: AmazonECSTaskExecutionRolePolicy)"]
        RTask["EcsTaskRole"]
        RMetrics["MetricsPublisherRole"]
    end

    subgraph Resources["Ressources accédées"]
        S3b[("S3 - bucket artefacts")]
        GHC["CodeStar Connection"]
        ECRrepo[("ECR repository")]
        CDapp["CodeDeploy App/DeploymentGroup"]
        ECSrt["ecs:RegisterTaskDefinition<br/>+ iam:PassRole (Exec/Task)"]
        Logsg[("CloudWatch Logs")]
        Secretsm[("Secrets Manager<br/>taskmanager/dev/*")]
        CWm["cloudwatch:PutMetricData<br/>(namespace scopé)"]
        CPExec["codepipeline:ListPipelineExecutions"]
    end

    SvcCP -->|AssumeRole| RCP
    SvcCD -->|AssumeRole| RCD
    SvcCB -->|AssumeRole| RCB
    SvcECSx -->|AssumeRole| RExec
    SvcECSx -->|AssumeRole| RTask
    SvcLambda -->|AssumeRole| RMetrics

    RCP --> S3b
    RCP --> GHC
    RCP -->|codebuild:StartBuild| RCB
    RCP --> CDapp
    RCP --> ECSrt

    RCD --> CDapp

    RCB --> ECRrepo
    RCB --> Logsg

    RExec --> ECRrepo
    RExec --> Logsg
    RExec --> Secretsm

    RTask --> CWm

    RMetrics --> CPExec
    RMetrics --> CWm
    RMetrics --> Logsg
```

**Lecture** : chaque rôle est restreint au strict nécessaire (principe du
moindre privilège documenté dans `iam.yaml`) — `RCP` (CodePipeline) ne peut
déclencher QUE le projet CodeBuild et l'application CodeDeploy de CE
projet ; `RExec` (démarrage du conteneur) et `RTask` (code applicatif) sont
volontairement deux rôles distincts, jamais fusionnés. Le seul `*` accepté
sans restriction est `cloudwatch:PutMetricData` (contrainte AWS — l'API
n'accepte pas de restriction par ARN), compensé par une `Condition` sur le
namespace.

---

## 5. Réseau (VPC)

```mermaid
flowchart TB
    IGW["Internet Gateway"]
    Internet(["Internet"])
    Internet <--> IGW

    subgraph VPC["VPC 10.0.0.0/16 (vpc.yml)"]
        direction LR

        subgraph AZ1["AZ 1 (eu-west-1a)"]
            direction TB
            Pub1["Subnet public 1<br/>10.0.0.0/24"]
            Priv1["Subnet privé 1<br/>10.0.10.0/24"]
        end

        subgraph AZ2["AZ 2 (eu-west-1b)"]
            direction TB
            Pub2["Subnet public 2<br/>10.0.1.0/24"]
            Priv2["Subnet privé 2<br/>10.0.11.0/24"]
        end

        NAT1["NAT Gateway 1<br/>(toujours créé)"]
        NAT2["NAT Gateway 2<br/>(si stratégie = ha)"]
        S3EP["VPC Endpoint S3<br/>(Gateway, gratuit)"]

        ALBsg["ALB<br/>(SG: 80/8080 depuis 0.0.0.0/0)"]
        ECSsg["ECS Fargate tasks<br/>(SG: ContainerPort depuis ALB uniquement)"]
    end

    IGW --- Pub1
    IGW --- Pub2
    Pub1 --> NAT1
    Pub2 -.-> NAT2

    Priv1 -->|0.0.0.0/0| NAT1
    Priv2 -->|single: NAT1 / ha: NAT2| NAT1

    Pub1 --> ALBsg
    Pub2 --> ALBsg
    ALBsg --> ECSsg
    Priv1 --- ECSsg
    Priv2 --- ECSsg
    Priv1 -.trafic ECR via S3.-> S3EP
    Priv2 -.trafic ECR via S3.-> S3EP
```

**Lecture** : les tâches ECS Fargate n'ont jamais d'IP publique (subnets
privés) ; leur seule sortie internet passe par le(s) NAT Gateway(s) —
stratégie `single` (1 NAT partagé, ~32 $/mois, par défaut dev/staging) ou
`ha` (1 NAT par AZ, recommandé en prod). Le VPC Endpoint S3 (gratuit)
détourne le trafic vers le backend S3 d'ECR hors du NAT Gateway, pour
réduire les coûts. Le security group des tâches ECS n'autorise QUE l'ALB
en entrée — jamais 0.0.0.0/0 directement vers les conteneurs.

---

## 6. Déploiement Blue/Green (CodeDeploy + ECS)

```mermaid
flowchart TB
    subgraph Before["Avant déploiement"]
        direction LR
        ProdL1["Prod Listener :80"] --> BlueTG1["Target Group BLUE<br/>(v. actuelle, 100% trafic)"]
        TestL1["Test Listener :8080"] -.-> GreenTG1["Target Group GREEN<br/>(vide)"]
    end

    Trigger["CodePipeline déclenche<br/>CodeDeploy (action CodeDeployToECS)"]

    subgraph During["Pendant le déploiement"]
        direction LR
        NewRev["Nouvelle Task Definition<br/>enregistrée (nouvelle image)"]
        NewRev --> GreenTasks["Tâches Fargate GREEN<br/>démarrées"]
        GreenTasks --> HC{"Health checks<br/>ALB + ECS OK ?"}
        HC -->|Test listener :8080| Validate["Validation sur GreenTG<br/>(hors trafic public)"]
    end

    subgraph Shift["Traffic shift progressif"]
        direction TB
        P1["10% → GreenTG<br/>90% → BlueTG"]
        P2["... paliers toutes les minutes ..."]
        P3["100% → GreenTG<br/>(CodeDeployDefault.ECSLinear10PercentEvery1Minute)"]
        P1 --> P2 --> P3
    end

    subgraph Success["Succès"]
        direction LR
        ProdL2["Prod Listener :80"] --> GreenTG2["Target Group GREEN<br/>devient la prod (100%)"]
        BlueOld["Anciennes tâches BLUE<br/>terminées après 5 min"]
    end

    subgraph Failure["Échec (rollback automatique < 3 min)"]
        direction LR
        ProdL3["Prod Listener :80"] --> BlueTG3["Target Group BLUE<br/>reste la prod (100%)"]
        GreenFail["Tâches GREEN<br/>arrêtées"]
    end

    Before --> Trigger --> During
    HC -->|OK| Shift --> Success
    HC -->|KO, DEPLOYMENT_FAILURE| Failure

    Success -.notif SNS.-> Notif1["'deployment succeeded'"]
    Failure -.notif SNS.-> Notif2["'rollback completed'"]
```

**Lecture** : le listener de test (port 8080, `TestListener` dans
`pipeline.yml`) permet de valider la version Green avant de lui envoyer du
vrai trafic public — jamais exposé aux utilisateurs finaux en usage normal.
`AutoRollbackConfiguration` (Événement `DEPLOYMENT_FAILURE`) déclenche le
rollback automatiquement dès qu'un health check échoue pendant le shift,
sans action manuelle (critère US-03 du cahier des charges).

---

## Où voir tout ça testé concrètement

Chaque diagramme correspond à un ou plusieurs fichiers CloudFormation
listés en tête de ce document. Les scripts `infrastructure/scripts/test*.sh`
valident chacun une partie de cette architecture sans accès AWS (via
LocalStack) — `./scripts/test7-all-local.sh` les enchaîne tous en une seule
commande (~10 min) avec un rapport récapitulatif. Voir
[`scripts/testing-output.md`](scripts/testing-output.md) pour le détail
complet, résultat par résultat, y compris ce qui n'a pas pu être vérifié
localement (services Pro-only sur LocalStack Community : CodeStar
Connections, CodeBuild, ELBv2, ECS, CodeDeploy, CodePipeline) et pourquoi.

L'avancement global du projet (ce qui est fait, testé, et la prochaine
étape) est suivi dans [`so-far.md`](../so-far.md) à la racine du dépôt.
