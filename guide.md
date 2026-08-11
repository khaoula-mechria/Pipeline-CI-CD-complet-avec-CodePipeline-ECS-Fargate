# Guide — passer du test local au vrai compte AWS, stack par stack

Ce guide sert à **déployer l'infrastructure du projet sur le vrai AWS, un service
à la fois**, en sachant à chaque étape : quelle commande lancer, ce qu'elle fait,
combien ça coûte pendant que ça tourne, comment vérifier que ça marche (en CLI
**et** dans la console), et comment tout supprimer pour arrêter le compteur.

Jusqu'ici tout a été validé sans AWS (cfn-lint + LocalStack, voir
[`infrastructure/scripts/README-tests-locaux.md`](infrastructure/scripts/README-tests-locaux.md)).
Ce qui suit est la suite : le vrai compte.

- Région utilisée dans tout le guide : **`eu-west-2`** (Irlande) — la même que les
  scripts de test locaux. **Ne change jamais de région en cours de route** : les
  `Fn::ImportValue` entre stacks ne franchissent pas les frontières de région.
- `ProjectName=taskmanager`, `Environment=dev` (valeurs par défaut des templates).
  Tous les noms de ressources en découlent : `taskmanager-dev-cluster`,
  `taskmanager-dev-service`, etc.

---

## Réponse courte aux 3 questions posées

| Question | Réponse |
|---|---|
| **Dois-je créer des instances manuellement sur AWS ?** | **Non.** Zéro EC2, zéro instance. Fargate est *serverless* : AWS fournit la capacité de calcul, tu ne gères aucune machine. Tout (VPC, ALB, cluster, service, pipeline) est créé par CloudFormation à partir des 12 templates. Il reste **4 actions manuelles**, aucune n'est une instance — voir [§4](#4-les-4-seules-actions-manuelles-obligatoires). |
| **Combien ça coûte à l'heure ?** | Infrastructure complète en marche : **≈ 0,12 $/h** (≈ 2,9 $/jour, ≈ 85 $/mois). Le poste dominant n'est **pas** Fargate (0,025 $/h) mais **NAT Gateway (0,05 $/h) + ALB (0,033 $/h)**. Détail par étape ci-dessous et récap en [§6](#6-récapitulatif-des-coûts). |
| **Comment vérifier que ça marche ?** | Chaque étape de [§5](#5-déploiement-progressif-12-étapes) a un bloc **Vérifier en CLI** et un bloc **Vérifier dans la console** (avec le lien direct). |

---

## 1. Ouvrir l'interface AWS (console web)

Ta capture montre le **portail d'accès AWS** (IAM Identity Center / ex-AWS SSO) :
un compte, trois rôles disponibles — `AdministratorAccess`, `Bedrock`,
`DataScientist`.

| Ce que tu veux ouvrir | Lien |
|---|---|
| **Portail d'accès** (l'écran de ta capture) | `https://<ton-sous-domaine>.awsapps.com/start` — c'est l'URL que tu as déjà dans ton navigateur ; mets-la en favori. Si tu l'as perdue : `https://signin.aws.amazon.com/` puis « Se connecter avec IAM Identity Center ». |
| **Console AWS** (une fois connectée) | Depuis le portail : clique sur le **nom du rôle `AdministratorAccess`** (le lien bleu de ta capture) → la console s'ouvre dans l'onglet. |
| Console directe (si session déjà active) | https://eu-west-2.console.aws.amazon.com/console/home?region=eu-west-2 |
| CloudFormation (l'écran que tu utiliseras le plus) | https://eu-west-2.console.aws.amazon.com/cloudformation/home?region=eu-west-2#/stacks |
| CloudShell (terminal AWS **dans le navigateur**, déjà authentifié, gratuit) | https://eu-west-2.console.aws.amazon.com/cloudshell/home?region=eu-west-2 |

> **Le rôle à utiliser : `AdministratorAccess`.** `Bedrock` et `DataScientist`
> n'ont pas les droits de créer des rôles IAM, des VPC ou des pipelines : les
> stacks échoueraient sur `AccessDenied`.

> **Vérifie toujours la région** en haut à droite de la console : si elle
> n'affiche pas « Irlande / eu-west-2 », tu regarderas des écrans vides en te
> demandant pourquoi tes stacks ont disparu. C'est l'erreur n°1.

---

## 2. Ouvrir l'AWS CLI

L'AWS CLI n'est pas une application à « ouvrir » : c'est une commande qui
s'exécute dans un terminal. Trois options, de la plus simple à la plus pratique.

### Option A — CloudShell (zéro installation, recommandé pour un premier essai)

Ouvre https://eu-west-2.console.aws.amazon.com/cloudshell/home?region=eu-west-2 :
un terminal Linux s'ouvre dans le navigateur, **déjà connecté avec ton rôle**
(aucune clé à configurer). Gratuit (1 Go de stockage persistant inclus).

Limite : les fichiers du projet ne sont pas dedans. Il faut les y amener :

```bash
git clone https://github.com/<ton-user>/<ce-repo>.git
cd <ce-repo>/infrastructure/cloudformation
```

### Option B — PowerShell sur ta machine (recommandé pour travailler)

1. Installer l'AWS CLI v2 (une fois) :
   - MSI : https://awscli.amazonaws.com/AWSCLIV2.msi
   - ou en ligne de commande :
     ```powershell
     winget install --id Amazon.AWSCLI --source winget
     ```
2. **Ferme et réouvre** PowerShell (le PATH est rechargé au démarrage du shell),
   puis vérifie :
   ```powershell
   aws --version
   # Attendu : aws-cli/2.x.x Python/3.x Windows/10 exe/AMD64
   ```
3. Ouvre ton terminal dans le dossier du projet :
   ```powershell
   cd "$HOME\Desktop\Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate\infrastructure\cloudformation"
   ```

### Option C — le terminal intégré de VS Code

`Ctrl+ù` (ou Terminal → New Terminal). Il est déjà positionné à la racine du
projet — c'est celui que tu utilises pour `npm test`. Les mêmes commandes qu'en
Option B y fonctionnent.

---

## 3. Se connecter (authentifier la CLI)

Ta capture montre le lien **« Clés d'accès »** à droite de chaque rôle : c'est là
qu'AWS te donne de quoi authentifier la CLI. Deux méthodes ; **la première est la
bonne**.

### Méthode 1 — SSO (recommandée : rien de secret sur le disque, renouvellement en 1 commande)

```powershell
aws configure sso --profile taskmanager
```

Le assistant pose 5 questions. Réponds :

| Question | Réponse |
|---|---|
| `SSO session name` | `taskmanager` |
| `SSO start URL` | l'URL de ton portail : `https://<ton-sous-domaine>.awsapps.com/start` |
| `SSO region` | la région **du portail** (souvent `eu-west-2` ou `us-east-1` — elle est indiquée dans la fenêtre « Clés d'accès », onglet SSO) |
| `SSO registration scopes` | laisse la valeur par défaut (`sso:account:access`) → `Entrée` |
| *(un navigateur s'ouvre → autorise)* puis rôle / région / format | rôle **`AdministratorAccess`**, région **`eu-west-2`**, format **`json`** |

Ensuite, à chaque nouvelle journée de travail (la session SSO expire au bout de
quelques heures) :

```powershell
aws sso login --profile taskmanager
```

Et pour ne pas répéter `--profile` sur chaque commande, dans le terminal courant :

```powershell
$env:AWS_PROFILE = "taskmanager"
$env:AWS_DEFAULT_REGION = "eu-west-2"
```

> Ces deux variables ne vivent que dans **le terminal ouvert**. Nouveau
> terminal = à refaire. Pour les rendre permanentes :
> `[Environment]::SetEnvironmentVariable("AWS_PROFILE","taskmanager","User")`.

### Méthode 2 — clés temporaires copier/coller (dépannage rapide)

Dans le portail (ta capture) → clique **« Clés d'accès »** en face de
`AdministratorAccess` → onglet **« Windows (PowerShell) »** → copie le bloc et
colle-le dans ton terminal. Il ressemble à :

```powershell
$env:AWS_ACCESS_KEY_ID="ASIA..."
$env:AWS_SECRET_ACCESS_KEY="..."
$env:AWS_SESSION_TOKEN="..."
$env:AWS_DEFAULT_REGION="eu-west-2"
```

⚠️ Ces clés **expirent en 1 à 12 h** (ce sont des credentials temporaires, d'où
le `AWS_SESSION_TOKEN`). Quand tu verras
`ExpiredToken: The security token included in the request is expired`, c'est
juste ça : recolle un bloc frais. Ne les commite **jamais** dans le repo.

### Vérifier que la connexion marche

```powershell
aws sts get-caller-identity
```

**Ce que ça fait** : demande à AWS « qui suis-je ? ». Aucun coût, aucune
ressource créée — c'est le `ping` de l'authentification.

Attendu :

```json
{
    "UserId": "AROA...:khaoula",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_AdministratorAccess_xxx/khaoula"
}
```

Si tu vois `AdministratorAccess` dans l'`Arn` et le bon numéro de compte : tu es
prête. Note le numéro de compte, il apparaîtra dans tous les ARN.

### Avant d'aller plus loin — mets un garde-fou budget (2 min, gratuit)

```powershell
# Coût réel dépensé ce mois-ci, service par service (lecture seule, gratuit)
aws ce get-cost-and-usage `
  --time-period Start=2026-08-01,End=2026-08-31 `
  --granularity MONTHLY --metrics UnblendedCost `
  --group-by Type=DIMENSION,Key=SERVICE `
  --region us-east-1
```

Et surtout, crée une alerte dans la console (impossible à oublier) :
https://console.aws.amazon.com/billing/home#/budgets → « Create budget » →
*Cost budget* → 10 USD/mois → ton email. AWS t'écrit à 80 % et 100 %.

---

## 4. Les 4 seules actions manuelles obligatoires

Aucune n'est « créer une instance ». Ce sont les 4 choses que CloudFormation ne
**peut pas** faire à ta place (elles impliquent un consentement ou un secret
externe à AWS).

1. **Autoriser la connexion GitHub (CodeStar Connection).**
   `iam.yaml` crée la connexion, mais elle naît au statut **`PENDING`** : le
   *handshake* OAuth avec GitHub doit être fait par un humain dans la console.
   Tant qu'elle est `PENDING`, le stage *Source* de CodePipeline échoue.
   → Console : https://eu-west-2.console.aws.amazon.com/codesuite/settings/connections?region=eu-west-2
   → sélectionne `taskmanager-dev-github` → **« Update pending connection »** →
   autorise l'app AWS Connector for GitHub → le statut passe à **`AVAILABLE`**.
   Vérification :
   ```powershell
   aws codestar-connections list-connections --query "Connections[].{Name:ConnectionName,Status:ConnectionStatus}"
   ```

2. **Donner à CodeBuild un accès GitHub (une fois par compte + région).**
   `codebuild.yaml` déclare `Source.Type: GITHUB` avec `Triggers.Webhook: true`.
   Sans credential GitHub enregistré, la création de la stack échoue sur
   *« No Access token found »*. Crée un
   [Personal Access Token GitHub](https://github.com/settings/tokens) (scopes
   `repo` + `admin:repo_hook`) puis :
   ```powershell
   aws codebuild import-source-credentials `
     --server-type GITHUB --auth-type PERSONAL_ACCESS_TOKEN `
     --token "ghp_xxxxxxxxxxxx"
   ```

3. **Le code applicatif doit être sur GitHub**, dans le dépôt que tu passeras en
   paramètre (`GitHubRepoUrl` pour CodeBuild, `FullRepositoryId` pour le
   pipeline). Le pipeline lit `task-manager/buildspec.yml` **depuis le dépôt**,
   pas depuis ton disque.

4. **Confirmer l'abonnement email SNS** (si tu passes `AlarmEmail`) : AWS envoie
   un mail « AWS Notification - Subscription Confirmation », il faut cliquer le
   lien. Sans ce clic, aucune alarme ne t'arrivera.

---

## 5. Déploiement progressif (12 étapes)

### Le mode d'emploi de chaque étape

Toutes les étapes suivent le même patron :

```powershell
# 0) Filet de sécurité : valider AVANT de créer quoi que ce soit (gratuit)
aws cloudformation validate-template --template-body file://vpc.yml

# 1) Voir ce qui SERA créé, sans rien créer (gratuit) — le "dry run"
aws cloudformation deploy --template-file vpc.yml --stack-name taskmanager-dev-vpc `
  --capabilities CAPABILITY_NAMED_IAM --no-execute-changeset

# 2) Déployer pour de vrai
aws cloudformation deploy --template-file vpc.yml --stack-name taskmanager-dev-vpc `
  --capabilities CAPABILITY_NAMED_IAM
```

**Que fait `aws cloudformation deploy` ?** Il envoie le template à AWS, calcule
un *change set* (la liste des différences avec l'existant), l'exécute, puis
**attend** la fin en bloquant le terminal. Il crée la stack si elle n'existe pas,
la met à jour sinon. En cas d'échec, CloudFormation **annule tout** (rollback) :
tu ne restes pas avec la moitié d'une infra.

- `--capabilities CAPABILITY_NAMED_IAM` : consentement explicite requis dès qu'un
  template crée des rôles IAM **avec un nom choisi** (`RoleName`). Concerné :
  `iam.yaml`, `codebuild.yaml`, `observability.yml`. Le passer partout est sans
  effet ailleurs — c'est plus simple que de s'en souvenir.
- `--parameter-overrides Cle=Valeur` : surcharge les paramètres du template.
  Absent = valeur `Default` du template.
- `--no-execute-changeset` : calcule et affiche, **n'exécute pas**. Zéro coût.

**Si une étape échoue**, la cause est toujours dans les événements de la stack :

```powershell
aws cloudformation describe-stack-events --stack-name <stack> `
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" `
  --output table
```

> **Ordre non négociable** — les stacks se lisent entre elles par
> `Fn::ImportValue`. Déployer la 7 avant la 1 échoue immédiatement
> (`No export named taskmanager-dev-vpc-id found`). Suis la numérotation.

---

### Étape 1 — VPC (le réseau) 💰 0,05 $/h

```powershell
aws cloudformation deploy --template-file vpc.yml `
  --stack-name taskmanager-dev-vpc `
  --parameter-overrides ProjectName=taskmanager Environment=dev NatGatewayStrategy=single `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : 1 VPC (10.0.0.0/16), 2 subnets publics + 2 subnets privés sur
2 zones de disponibilité, 1 Internet Gateway, **1 NAT Gateway**, les tables de
routage, 1 VPC Endpoint S3.

**Coût** : le VPC, les subnets et les routes sont **gratuits**. Ce qui coûte :
NAT Gateway **0,045 $/h** + son adresse IPv4 publique **0,005 $/h** + 0,045 $/GB
de trafic sortant. Soit **≈ 0,05 $/h = 1,20 $/jour**, même sans aucun trafic.
👉 Garde `NatGatewayStrategy=single` (le défaut) ; `ha` double la facture NAT.

**Vérifier en CLI**

```powershell
# Les 13 exports que les autres stacks vont consommer
aws cloudformation describe-stacks --stack-name taskmanager-dev-vpc `
  --query "Stacks[0].Outputs[].{Cle:OutputKey,Valeur:OutputValue}" --output table

# Le NAT doit être "available" — sinon les tâches ECS n'auront pas d'internet
aws ec2 describe-nat-gateways --filter "Name=tag:Project,Values=taskmanager" `
  --query "NatGateways[].{Id:NatGatewayId,Etat:State}" --output table
```

**Vérifier dans la console** : https://eu-west-2.console.aws.amazon.com/vpcconsole/home?region=eu-west-2#vpcs:
→ le VPC `taskmanager-dev-vpc` doit apparaître ; onglet **Resource map** pour voir
les 4 subnets et le routage d'un coup d'œil.

---

### Étape 2 — IAM + connexion GitHub 💰 gratuit

```powershell
aws cloudformation deploy --template-file infrastructure/cloudformation/iam.yaml `
  --stack-name taskmanager-dev-iam `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : 4 rôles IAM (CodePipeline, CodeDeploy, ECS *execution*, ECS
*task*) + la **CodeStar Connection** vers GitHub.

**Coût** : **0 $**. IAM et les connexions sont gratuits — cette étape ne fait
jamais tourner le compteur.

**Vérifier en CLI**

```powershell
aws iam list-roles --query "Roles[?starts_with(RoleName,'taskmanager-dev')].RoleName" --output table
aws codestar-connections list-connections --query "Connections[].{Nom:ConnectionName,Statut:ConnectionStatus}" --output table
```

👉 Le statut sera **`PENDING`** : c'est normal, fais maintenant l'action manuelle
n°1 de [§4](#4-les-4-seules-actions-manuelles-obligatoires) pour le passer à
`AVAILABLE`.

**Console** : https://eu-west-2.console.aws.amazon.com/codesuite/settings/connections?region=eu-west-2

---

### Étape 3 — Secrets Manager 💰 0,0011 $/h (0,80 $/mois)

```powershell
aws cloudformation deploy --template-file secrets-manager.yaml `
  --stack-name taskmanager-dev-secrets `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : 2 secrets (credentials DB avec mot de passe généré par AWS,
clé d'API). Leurs ARN finissent par un suffixe aléatoire — d'où l'export, qu'on
ne peut pas deviner.

**Coût** : **0,40 $/secret/mois** × 2 = **0,80 $/mois** (facturé au prorata) +
0,05 $ par 10 000 appels API. Négligeable, mais **pas supprimable instantanément** :
un secret supprimé reste en « recovery window » 7 à 30 jours et continue d'être
facturé (voir [§7](#7-tout-supprimer-arrêter-le-compteur)).

**Ne saute pas cette étape** : dès qu'une task definition déclare des secrets,
ECS refuse de démarrer la tâche s'il ne peut pas les lire.

**Vérifier en CLI**

```powershell
aws secretsmanager list-secrets --query "SecretList[?starts_with(Name,'taskmanager')].Name" --output table

# Lire la valeur générée (⚠️ affiche le mot de passe en clair dans le terminal)
aws secretsmanager get-secret-value --secret-id taskmanager/dev/db --query SecretString --output text
```

**Console** : https://eu-west-2.console.aws.amazon.com/secretsmanager/listsecrets?region=eu-west-2

---

### Étape 4 — ECR (registre Docker) 💰 ~0 $ (0,005 $/mois)

```powershell
aws cloudformation deploy --template-file ecr.yaml `
  --stack-name taskmanager-dev-ecr `
  --parameter-overrides ProjectName=taskmanager Environment=dev MaxImageCount=10 `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : le dépôt Docker privé `taskmanager-dev`, avec scan de
vulnérabilités au push et une lifecycle policy (10 images max).

**Coût** : **0,10 $/GB-mois** de stockage. L'image du projet pèse 48 Mo → moins
d'un centime par mois. Le *Basic Scanning* est **gratuit**.

**Vérifier en CLI**

```powershell
aws ecr describe-repositories --repository-names taskmanager-dev `
  --query "repositories[0].{Uri:repositoryUri,ScanAuPush:imageScanningConfiguration.scanOnPush,Tags:imageTagMutability}"

# Après le premier build : lister les images poussées
aws ecr list-images --repository-name taskmanager-dev --output table
```

**Console** : https://eu-west-2.console.aws.amazon.com/ecr/repositories?region=eu-west-2

> ⚠️ **Problème connu, à trancher AVANT l'étape 5** (déjà documenté dans
> [`so-far.md`](so-far.md)) : `ecr.yaml` déclare `ImageTagMutability: IMMUTABLE`
> alors que `buildspec.yml` pousse `:latest` à chaque build. **Le 1er build
> passera, tous les suivants échoueront** sur `docker push ...:latest` (ECR
> refuse de réassigner un tag existant). Trois issues : ne pousser que le tag
> SHA, passer le dépôt en `MUTABLE`, ou ne pousser `latest` qu'au premier build.
> Ça n'empêche pas de tester les étapes 4 et 5 — mais ça bloquera le 2ᵉ passage
> du pipeline.

---

### Étape 5 — CodeBuild 💰 0 $ au repos, 0,005 $/minute de build

⚠️ L'action manuelle n°2 de [§4](#4-les-4-seules-actions-manuelles-obligatoires)
(token GitHub) doit être faite avant, sinon la stack échoue.

```powershell
aws cloudformation deploy --template-file codebuild.yaml `
  --stack-name taskmanager-dev-codebuild `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
      GitHubRepoUrl=https://github.com/<ton-user>/<ton-repo> `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : le projet CodeBuild `taskmanager-dev-build` (rôle dédié,
webhook sur `main`/`develop`, cache Docker, log group avec rétention 30 jours) —
il exécute `task-manager/buildspec.yml` : npm ci → SAST Semgrep → tests +
couverture 80 % → build Docker → push ECR → lecture du scan ECR.

**Coût** : **rien tant qu'aucun build ne tourne** (pas de serveur allumé). Un
build coûte 0,005 $/minute sur `BUILD_GENERAL1_SMALL`, et les **100 premières
minutes du mois sont gratuites** → un build de 5 min ≈ **0,025 $**, souvent 0 $.
Timeout à 15 min = plafond de 0,075 $ par build.

**Vérifier en CLI** — et c'est ici que tu testes vraiment, sans pipeline :

```powershell
# Lancer un build à la main
aws codebuild start-build --project-name taskmanager-dev-build --query "build.id" --output text

# Suivre son état (relance la commande de temps en temps)
aws codebuild batch-get-builds --ids "<build-id>" `
  --query "builds[0].{Statut:buildStatus,Phase:currentPhase,Duree:phases[-1].durationInSeconds}"

# Lire les logs
aws logs tail /aws/codebuild/taskmanager-dev --follow
```

Attendu : `buildStatus = SUCCEEDED`, puis une image visible dans
`aws ecr list-images --repository-name taskmanager-dev`.

**Console** : https://eu-west-2.console.aws.amazon.com/codesuite/codebuild/projects?region=eu-west-2
→ le projet → un build → onglets **Phase details** (quelle phase a échoué),
**Build logs**, **Reports** (tests JUnit + couverture Cobertura affichée
nativement).

> 👉 **Bonne étape pour s'arrêter** : à ce stade tu as un CI complet (build,
> tests, image dans ECR) pour ≈ 0,05 $/h — l'essentiel étant le NAT de
> l'étape 1. Les étapes 6 à 12 ajoutent le déploiement, et c'est là que le coût
> horaire double.

---

### Étape 6 — Cluster ECS 💰 0 $ (le cluster vide est gratuit)

```powershell
aws cloudformation deploy --template-file ecs-cluster.yaml `
  --stack-name taskmanager-dev-ecs-cluster `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : le cluster Fargate `taskmanager-dev-cluster` avec
**Container Insights** activé. Un cluster n'est qu'un regroupement logique :
**aucune machine n'est allumée** (c'est la réponse concrète à « dois-je créer des
instances ? » — non, il n'y a pas de nœud à provisionner en Fargate).

**Coût** : cluster = **0 $**. Attention toutefois : **Container Insights publie
des métriques custom facturées** (~0,30 $/métrique/mois, et il en publie
plusieurs dizaines par service) → compte quelques $/mois dès que des tâches
tournent. Pour un test à budget serré, tu peux le désactiver dans
`ecs-cluster.yaml` (`ClusterSettings` → `containerInsights: disabled`).

**Vérifier en CLI**

```powershell
aws ecs describe-clusters --clusters taskmanager-dev-cluster `
  --query "clusters[0].{Nom:clusterName,Statut:status,Taches:runningTasksCount}"
```

**Console** : https://eu-west-2.console.aws.amazon.com/ecs/v2/clusters?region=eu-west-2

---

### Étape 7 — ALB (load balancer) 💰 0,033 $/h

Cette stack prend le VPC et les subnets **en paramètres** : on les lit dans les
exports de l'étape 1 plutôt que de les recopier à la main.

```powershell
$vpcId    = aws cloudformation list-exports --query "Exports[?Name=='taskmanager-dev-vpc-id'].Value" --output text
$pubSub   = aws cloudformation list-exports --query "Exports[?Name=='taskmanager-dev-public-subnet-ids'].Value" --output text
$vpcId; $pubSub   # contrôle visuel avant de déployer

aws cloudformation deploy --template-file alb.yaml `
  --stack-name taskmanager-dev-alb `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
      VpcId=$vpcId "PublicSubnetIds=$pubSub" ContainerPort=3000 HealthCheckPath=/health `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : 1 Application Load Balancer public, **2 target groups**
(Blue et Green — indispensables au déploiement sans interruption), 1 listener
prod (port 80) et 1 listener de test (port 8080), 1 security group.

**Coût** : ALB **0,0225 $/h** + 2 adresses IPv4 publiques (une par AZ)
**0,01 $/h** + LCU ~0,008 $/h en usage faible ≈ **0,033 $/h = 0,79 $/jour**.
Facturé même sans une seule requête : **c'est le 2ᵉ poste de dépense après le NAT.**

**Vérifier en CLI**

```powershell
aws elbv2 describe-load-balancers --names taskmanager-dev-alb `
  --query "LoadBalancers[0].{Dns:DNSName,Etat:State.Code,Schema:Scheme}"
```

À ce stade, `curl http://<DNS>/` répond **503** : c'est le comportement
**attendu** — l'ALB existe mais aucune tâche n'est encore derrière.

**Console** : https://eu-west-2.console.aws.amazon.com/ec2/home?region=eu-west-2#LoadBalancers:

---

### Étape 8 — Task definition 💰 0 $

```powershell
aws cloudformation deploy --template-file ecs-task-definition.yaml `
  --stack-name taskmanager-dev-taskdef `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
      ContainerCpu=256 ContainerMemory=512 ContainerPort=3000 `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : la task definition `taskmanager-dev-task` (le « plan » du
conteneur : image, CPU/RAM, port, healthcheck, injection des secrets) + le log
group applicatif `/ecs/taskmanager-dev` (rétention 30 jours).

**Coût** : **0 $** — une task definition est un document JSON stocké par AWS.
Elle ne coûte que lorsqu'une tâche est **lancée** à partir d'elle (étape 9).

> Celle-ci est une task definition de **bootstrap** : elle pointe sur
> `<repo>:latest`. En régime normal, c'est CodeBuild qui génère le
> `taskdef.json` de chaque build et CodeDeploy qui enregistre une nouvelle
> révision. Il faut donc qu'une image existe déjà dans ECR (étape 5) — sinon la
> tâche de l'étape 9 échouera au *pull*.

**Vérifier en CLI**

```powershell
aws ecs describe-task-definition --task-definition taskmanager-dev-task `
  --query "taskDefinition.{Revision:revision,Cpu:cpu,Memoire:memory,Image:containerDefinitions[0].image}"
```

---

### Étape 9 — Service ECS 💰 0,025 $/h (2 tâches) — l'app devient joignable

```powershell
$vpcId  = aws cloudformation list-exports --query "Exports[?Name=='taskmanager-dev-vpc-id'].Value" --output text
$privSub = aws cloudformation list-exports --query "Exports[?Name=='taskmanager-dev-private-subnet-ids'].Value" --output text

aws cloudformation deploy --template-file ecs-service.yaml `
  --stack-name taskmanager-dev-ecs-service `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
      VpcId=$vpcId "PrivateSubnetIds=$privSub" ContainerPort=3000 DesiredCount=2 `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : le service Fargate `taskmanager-dev-service` — il maintient
2 tâches en vie dans les subnets privés, les enregistre dans le target group
Blue, et délègue les déploiements à CodeDeploy
(`DeploymentController: CODE_DEPLOY`).

**Coût** : Fargate est facturé **à la seconde** sur les ressources demandées, à
eu-west-2 : 0,04048 $/vCPU-h + 0,004445 $/GB-h. Une tâche 0,25 vCPU / 0,5 Go =
**0,0123 $/h** → **2 tâches = 0,025 $/h = 0,59 $/jour**. Pendant un déploiement
Blue/Green, les 2 versions coexistent → **le double**, temporairement.
👉 `DesiredCount=1` divise ce poste par deux si tu veux juste voir l'app répondre.

**Vérifier en CLI — le test qui compte**

```powershell
# 1) Le service a-t-il autant de tâches qui tournent que demandé ?
aws ecs describe-services --cluster taskmanager-dev-cluster --services taskmanager-dev-service `
  --query "services[0].{Statut:status,Voulu:desiredCount,EnCours:runningCount,Type:launchType}"
# Attendu : status ACTIVE, runningCount == desiredCount == 2

# 2) Le load balancer considère-t-il les tâches comme SAINES ? (le vrai verdict)
$tgBlue = aws cloudformation list-exports --query "Exports[?Name=='taskmanager-dev-tg-blue-arn'].Value" --output text
aws elbv2 describe-target-health --target-group-arn $tgBlue `
  --query "TargetHealthDescriptions[].{Cible:Target.Id,Etat:TargetHealth.State,Raison:TargetHealth.Reason}" --output table
# Attendu : "healthy" pour chaque cible

# 3) L'application répond-elle vraiment ?
$dns = aws cloudformation list-exports --query "Exports[?Name=='taskmanager-dev-alb-dns'].Value" --output text
"http://$dns"                                            # ← ouvre cette URL dans ton navigateur
Invoke-RestMethod "http://$dns/health"                   # attendu : status ok
Invoke-RestMethod "http://$dns/api/tasks"                # attendu : la liste JSON des tâches

# 4) Si ça ne répond pas : pourquoi la tâche s'est-elle arrêtée ?
aws ecs describe-services --cluster taskmanager-dev-cluster --services taskmanager-dev-service `
  --query "services[0].events[0:5].message"
aws logs tail /ecs/taskmanager-dev --follow                # les logs du conteneur
```

**Vérifier dans la console**

1. **ECS** → https://eu-west-2.console.aws.amazon.com/ecs/v2/clusters/taskmanager-dev-cluster/services?region=eu-west-2
   → le service doit afficher **2/2 tasks running** ; onglet **Health and
   metrics** pour l'état du target group, onglet **Logs** pour les logs
   applicatifs, onglet **Events** en cas de boucle de redémarrage.
2. **Target group** → https://eu-west-2.console.aws.amazon.com/ec2/home?region=eu-west-2#TargetGroups:
   → `taskmanager-dev-tg-blue` → onglet **Targets** → les 2 cibles en
   **healthy** (vert).
3. **L'app elle-même** : copie le **DNS name** de l'ALB
   (https://eu-west-2.console.aws.amazon.com/ec2/home?region=eu-west-2#LoadBalancers:)
   et ouvre `http://<dns>` → l'interface HTML du task-manager s'affiche.

---

### Étape 10 — CodePipeline + CodeDeploy 💰 ~1 $/mois

⚠️ La connexion GitHub doit être `AVAILABLE` (action manuelle n°1).

```powershell
aws cloudformation deploy --template-file pipeline.yml `
  --stack-name taskmanager-dev-pipeline `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
      FullRepositoryId=<ton-user>/<ton-repo> BranchName=main EnableManualApproval=true `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : le pipeline `taskmanager-dev-pipeline` (Source → Build →
Approval → Deploy), l'application et le *deployment group* CodeDeploy en
Blue/Green (bascule progressive du trafic + rollback automatique), le bucket S3
d'artefacts, le topic SNS de notifications.

**Coût** : **1 $/mois par pipeline actif** (un mois sans aucune exécution n'est
pas facturé) + le stockage S3 des artefacts (quelques centimes) + SNS (1 000
emails/mois gratuits).

**Vérifier en CLI — bout en bout**

```powershell
# État de chaque stage
aws codepipeline get-pipeline-state --name taskmanager-dev-pipeline `
  --query "stageStates[].{Etape:stageName,Statut:latestExecution.status}" --output table

# Déclencher une exécution sans faire de commit
aws codepipeline start-pipeline-execution --name taskmanager-dev-pipeline

# Approuver manuellement (le stage Approval attend, et expire après 7 jours)
aws codepipeline put-approval-result --pipeline-name taskmanager-dev-pipeline `
  --stage-name Approval --action-name ManualApproval `
  --result summary="OK",status=Approved --token <token-lu-dans-get-pipeline-state>

# Suivre le déploiement Blue/Green
aws deploy list-deployments --application-name taskmanager-dev-app `
  --deployment-group-name taskmanager-dev-dg --query "deployments[0]" --output text
aws deploy get-deployment --deployment-id <id> --query "deploymentInfo.status"
```

**Console** (c'est l'écran le plus parlant du projet) :
https://eu-west-2.console.aws.amazon.com/codesuite/codepipeline/pipelines/taskmanager-dev-pipeline/view?region=eu-west-2
→ le diagramme vertical des 4 stages ; le bouton **Review** sur le stage
Approval ; et pour la bascule de trafic :
https://eu-west-2.console.aws.amazon.com/codesuite/codedeploy/deployments?region=eu-west-2
→ un déploiement → **Traffic shifting progress** (10 % → 100 %).

**Le test qui valide tout le projet** : fais un commit trivial sur `main` du
dépôt applicatif, pousse, et regarde le pipeline se déclencher tout seul, puis
`curl http://<dns>/health` pendant la bascule — il doit répondre **200 sans
interruption**.

---

### Étape 11 — Auto scaling 💰 ~0,20 $/mois (2 alarmes)

```powershell
aws cloudformation deploy --template-file ecs-autoscaling.yaml `
  --stack-name taskmanager-dev-autoscaling `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
      MinCapacity=2 MaxCapacity=6 TargetCpuUtilization=70 `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : un *scalable target* sur le service ECS (2 → 6 tâches) avec
une politique **Target Tracking** à 70 % de CPU, + 2 alarmes d'information (CPU
soutenu > 85 %, capacité max atteinte).

**Coût** : les 2 alarmes standard = **0,20 $/mois**. Mais le vrai coût est
indirect : **jusqu'à 6 tâches** = jusqu'à **0,074 $/h** de Fargate au lieu de
0,025 $/h. En test, `MaxCapacity=3` limite la casse.

> ⚠️ Après cette étape, le `DesiredCount` de l'étape 9 n'est plus qu'une valeur
> initiale : **Application Auto Scaling en devient propriétaire**. Pour changer
> durablement le nombre de tâches, ajuste `MinCapacity`/`MaxCapacity`, pas
> `DesiredCount`.

**Vérifier en CLI**

```powershell
aws application-autoscaling describe-scalable-targets --service-namespace ecs `
  --resource-ids service/taskmanager-dev-cluster/taskmanager-dev-service `
  --query "ScalableTargets[0].{Min:MinCapacity,Max:MaxCapacity}"

aws application-autoscaling describe-scaling-activities --service-namespace ecs `
  --resource-id service/taskmanager-dev-cluster/taskmanager-dev-service `
  --query "ScalingActivities[0:5].[StatusCode,Description]" --output table
```

**Console** : l'onglet **Auto scaling** du service ECS (lien de l'étape 9).

---

### Étape 12 — Observabilité 💰 ~1 $/mois (+ logs)

```powershell
aws cloudformation deploy --template-file observability.yml `
  --stack-name taskmanager-dev-observability `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
      AlarmEmail=khaoula.mechria@supcom.tn `
  --capabilities CAPABILITY_NAMED_IAM
```

**Ce que ça crée** : une Lambda Python qui publie 3 métriques custom
(`PipelineDuration`, `PipelineSuccess`, `PipelineFailure`) à chaque fin
d'exécution, la règle EventBridge qui la déclenche, 2 alarmes (durée, échec) et
un **dashboard CloudWatch de 8 widgets**.

**Coût** : dashboard **3 $/mois** (les **3 premiers dashboards sont gratuits** →
0 $ ici), 2 alarmes 0,20 $/mois, 3 métriques custom 0,90 $/mois, Lambda dans le
free tier (0 $), logs 0,50 $/GB ingéré. ≈ **1 $/mois**.

👉 N'oublie pas de **cliquer le lien de confirmation** dans le mail SNS.

**Vérifier en CLI**

```powershell
aws cloudwatch describe-alarms --alarm-name-prefix taskmanager-dev `
  --query "MetricAlarms[].{Nom:AlarmName,Etat:StateValue}" --output table
aws sns list-subscriptions --query "Subscriptions[?contains(TopicArn,'taskmanager')].{Email:Endpoint,Statut:SubscriptionArn}" --output table
# Statut "PendingConfirmation" = tu n'as pas encore cliqué le lien du mail
```

**Console** : https://eu-west-2.console.aws.amazon.com/cloudwatch/home?region=eu-west-2#dashboards:
→ `taskmanager-dev-dashboard`.

---

## 6. Récapitulatif des coûts

Tarifs **eu-west-2**, ordre de grandeur (à confirmer avec
[le calculateur AWS](https://calculator.aws/#/) — les prix évoluent).

| # | Stack | Coût à l'heure | Coût au mois | Facturé même à l'arrêt ? |
|---|---|---|---|---|
| 1 | vpc | **0,050 $** | ~36 $ | ✅ oui (NAT + IP) |
| 2 | iam | 0 $ | 0 $ | — |
| 3 | secrets-manager | 0,0011 $ | 0,80 $ | ✅ oui |
| 4 | ecr | ~0 $ | 0,005 $ | ✅ (négligeable) |
| 5 | codebuild | 0 $ au repos | 0 $ (100 min offertes) | ❌ non |
| 6 | ecs-cluster | 0 $ | 0 $ (+ Container Insights) | ❌ non |
| 7 | alb | **0,033 $** | ~24 $ | ✅ oui |
| 8 | ecs-task-definition | 0 $ | 0 $ | ❌ non |
| 9 | ecs-service (2 tâches) | **0,025 $** | ~18 $ | ✅ oui |
| 10 | pipeline | ~0,0014 $ | ~1 $ | ✅ (si actif) |
| 11 | ecs-autoscaling | 0,0003 $ | 0,20 $ | ✅ oui |
| 12 | observability | 0,0014 $ | ~1 $ | ✅ oui |
| | **TOTAL en marche** | **≈ 0,12 $/h** | **≈ 85 $/mois** | |

**Les 3 arrêts recommandés**, selon ton budget :

| Tu t'arrêtes après… | Ce que tu as validé | Coût |
|---|---|---|
| **Étape 5** | Tout le CI : build, SAST, tests, couverture, image dans ECR, scan | **≈ 0,05 $/h** (uniquement le NAT) |
| **Étape 9** | + l'application réellement joignable sur internet via l'ALB | **≈ 0,11 $/h** |
| **Étape 12** | Le projet complet : CD Blue/Green, scaling, observabilité | **≈ 0,12 $/h** |

**Trois leviers pour payer moins pendant les tests**
1. `DesiredCount=1` et `MinCapacity=1` → Fargate divisé par 2.
2. Supprimer `alb` + `ecs-service` en fin de journée et les redéployer le
   lendemain (2 commandes, ~5 min) → économise 0,058 $/h, soit ~1,4 $/nuit.
3. **Supprimer la stack `vpc` dès que tu ne testes plus** : le NAT est le premier
   poste de dépense et il tourne 24/7, même quand tu ne fais rien.

---

## 7. Tout supprimer (arrêter le compteur)

**Ordre inverse strict** du déploiement : une stack dont les exports sont encore
importés par une autre **refusera** de se supprimer.

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
  Write-Host "Suppression de $s ..."
  aws cloudformation delete-stack --stack-name $s
  aws cloudformation wait stack-delete-complete --stack-name $s
}
```

**Contrôle final — plus rien ne doit tourner :**

```powershell
aws cloudformation describe-stacks --query "Stacks[?starts_with(StackName,'taskmanager')].{Nom:StackName,Statut:StackStatus}" --output table
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" --query "NatGateways[].NatGatewayId"
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
aws ecs list-tasks --cluster taskmanager-dev-cluster 2>$null
```

**Deux pièges à la suppression**

- **Bucket S3 d'artefacts non vide** → `DELETE_FAILED` sur la stack `pipeline`.
  Vide-le puis relance :
  ```powershell
  $b = aws cloudformation describe-stacks --stack-name taskmanager-dev-pipeline `
        --query "Stacks[0].Outputs[?OutputKey=='PipelineArtifactsBucketName'].OutputValue" --output text
  aws s3 rm "s3://$b" --recursive
  ```
- **ECR non vide** → `DELETE_FAILED` sur la stack `ecr` si des images ont été
  poussées :
  ```powershell
  aws ecr delete-repository --repository-name taskmanager-dev --force
  ```
- **Secrets Manager** : les secrets partent en « recovery window » (7 à 30 j) et
  restent facturés. Suppression immédiate si tu es sûre :
  ```powershell
  aws secretsmanager delete-secret --secret-id taskmanager/dev/db --force-delete-without-recovery
  ```

---

## 8. Erreurs fréquentes et ce qu'elles veulent dire

| Message | Cause réelle | Correctif |
|---|---|---|
| `ExpiredToken: ... security token ... is expired` | Session SSO / clés temporaires expirées | `aws sso login --profile taskmanager`, ou recoller les clés du portail |
| `No export named taskmanager-dev-vpc-id found` | Étape sautée, ou **mauvaise région** | Vérifier l'ordre et `$env:AWS_DEFAULT_REGION` |
| `Requires capabilities : [CAPABILITY_NAMED_IAM]` | Le template crée des rôles nommés | Ajouter `--capabilities CAPABILITY_NAMED_IAM` |
| `No Access token found for server type GITHUB` | Action manuelle n°2 non faite | `aws codebuild import-source-credentials ...` |
| Stage *Source* du pipeline en échec | Connexion GitHub restée `PENDING` | Action manuelle n°1 (console → Update pending connection) |
| `ROLLBACK_COMPLETE` (impossible de mettre à jour) | La toute 1ʳᵉ création a échoué : la stack est un cadavre | `aws cloudformation delete-stack --stack-name <s>` puis redéployer |
| Log group `already exists` (codebuild) | Des builds ont tourné avant l'ajout du log group au template | `aws logs delete-log-group --log-group-name /aws/codebuild/taskmanager-dev` puis redéployer |
| ALB renvoie **503** | Aucune cible saine derrière | Étape 9 non faite, ou `describe-target-health` → lire `Reason` |
| Tâche ECS en boucle `STOPPED` | `pull` de l'image impossible, ou secret illisible | `describe-services --query "services[0].events"` + `aws logs tail /ecs/taskmanager-dev` |
| `docker push ...:latest` échoue au 2ᵉ build | `ImageTagMutability: IMMUTABLE` vs push de `latest` | Voir l'avertissement de l'étape 4 — arbitrage à trancher |

---

## 9. Aide-mémoire — les 8 commandes à retenir

```powershell
aws sso login --profile taskmanager                      # se connecter
aws sts get-caller-identity                              # qui suis-je ? (gratuit)
aws cloudformation deploy --template-file X --stack-name Y --capabilities CAPABILITY_NAMED_IAM   # déployer
aws cloudformation describe-stack-events --stack-name Y   # pourquoi ça a échoué
aws cloudformation list-exports                           # tous les liens entre stacks
aws ecs describe-services --cluster taskmanager-dev-cluster --services taskmanager-dev-service   # l'app tourne-t-elle
aws logs tail /ecs/taskmanager-dev --follow                # les logs en direct
aws cloudformation delete-stack --stack-name Y             # arrêter le compteur
```
