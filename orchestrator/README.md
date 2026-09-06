# Module 1 — Orchestrateur de deploiement

Deploie les 12 stacks CloudFormation du projet en deduisant l'ordre a partir des
dependances reelles entre templates, et parallelise ce qui peut l'etre.

Remplace le runbook manuel de 21 etapes (`guideme2.md`, Appendix A du rapport),
ou l'ordre etait ecrit a la main et chaque stack attendait la precedente.

## Ce qui est analyse

Le parseur lit les 12 templates de `infrastructure/cloudformation/` et en extrait
deux types de dependances :

| Type | Source | Exemple |
|---|---|---|
| `import` | `Fn::ImportValue` -> `Export.Name` | `iam.yaml` importe `taskmanager-dev-codebuild-arn` |
| `parameter` | parametre alimente par un export au deploiement | `alb.yaml` recoit `VpcId` depuis `taskmanager-dev-vpc-id` |

Le second type est indispensable **dans ce repo** : `alb.yaml` et `ecs-service.yaml`
ne font aucun `Fn::ImportValue` vers le VPC. Ils declarent `VpcId` / `*SubnetIds`
en parametres typés, que le runbook resout a la main via
`aws cloudformation list-exports` avant de les passer en `--parameter-overrides`.
Sans ce cablage (declare dans [`stacks.py`](stacks.py)), le graphe placerait `alb`
en vague 1 en parallele du VPC dont il depend pourtant.

Le parsing passe par un vrai loader YAML ([`cfn_yaml.py`](cfn_yaml.py)) et non par
grep : `codebuild.yaml`, `vpc.yml` et `pipeline.yml` contiennent le texte
`Fn::ImportValue` dans des **commentaires** ou des descriptions, qu'un grep
compterait a tort comme des dependances.

## Resultat sur ce repo

22 dependances, 7 vagues au lieu de 12 etapes sequentielles :

```
Vague 1 (parallele) : ecr, ecs-cluster, secrets, vpc
Vague 2 (parallele) : alb (<- vpc), codebuild (<- ecr, secrets)
Vague 3             : iam (<- codebuild)
Vague 4             : taskdef (<- ecr, iam, secrets)
Vague 5             : ecs-service (<- alb, ecs-cluster, taskdef, vpc)
Vague 6             : pipeline (<- alb, ecs-cluster, ecs-service, iam)
Vague 7 (parallele) : autoscaling, observability
```

L'ordre derive confirme que **codebuild doit preceder iam** (`iam.yaml` importe
`codebuild-arn`), ce que l'ordre ecrit dans `guideme2.md` ne respecte pas.

## Lancer en local

Prerequis : `pip install boto3 networkx pyyaml` (deja installes sur ce poste).

### Sans AWS (hors ligne)

```powershell
python -m orchestrator graph              # vagues + dependances
python -m orchestrator graph --edges      # detaille chaque arete et son motif
python -m orchestrator graph --json       # sortie machine (utilisee par le dashboard)
python -m orchestrator validate           # templates, cycles, parametres manquants
python -m orchestrator deploy --dry-run   # rejoue l'enchainement sans appeler AWS
```

`--dry-run` n'appelle **aucune** API AWS : les exports sont simules a partir du
graphe. Utile sur ce projet ou l'infrastructure est detruite entre deux tests.

### Deploiement reel

```powershell
aws sso login --profile AdministratorAccess-136609826386

$env:GITHUB_REPO_URL   = "https://github.com/khaoula-mechria/Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate"
$env:FULL_REPOSITORY_ID = "khaoula-mechria/Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate"
$env:ALARM_EMAIL        = "ton.email@exemple.com"

python -m orchestrator deploy --profile AdministratorAccess-136609826386 --region eu-west-2
```

### Variables d'environnement

| Variable | Defaut | Utilisee par |
|---|---|---|
| `PROJECT_NAME` | `taskmanager` | toutes |
| `ENVIRONMENT` | `dev` | toutes |
| `AWS_REGION` | `eu-west-2` | deploiement |
| `GITHUB_REPO_URL` | *(vide — obligatoire)* | `codebuild` |
| `FULL_REPOSITORY_ID` | *(vide)* | `pipeline` |
| `BRANCH_NAME` | `main` | `pipeline` |
| `ALARM_EMAIL` | *(vide)* | `observability` |

`python -m orchestrator validate` liste les variables manquantes avant tout appel AWS.

## Mesure du gain

En fin de deploiement, l'orchestrateur affiche :

```
=== Bilan ===
  Stacks deployees        : 12 en 7 vagues
  Parallele (reel)        : <mesure>
  Sequentiel (estime)     : <somme des durees par stack>
  Gain                    : <%>
```

Le "sequentiel estime" est la **somme des durees reellement observees** pour
chaque stack : le meme travail, enchaine au lieu d'etre parallelise. C'est la
comparaison citee dans le memoire.

## Etat partage

Chaque changement d'etat est ecrit dans `.orchestrator-state.json` a la racine
(statut par stack, vague courante, chronos). C'est ce fichier que lit le
dashboard Streamlit du module 4.

## Tests

```powershell
python -m pytest orchestrator/ -v
```

9 tests hors ligne : acyclicite, respect des aretes par les vagues, `codebuild`
avant `iam`, `vpc` avant `alb` malgre l'absence d'`ImportValue`, et non-prise en
compte des `Fn::ImportValue` cites dans les commentaires.

## Fichiers

| Fichier | Role |
|---|---|
| [`cfn_yaml.py`](cfn_yaml.py) | Loader YAML tolerant aux tags courts (`!Ref`, `!Sub`, `!ImportValue`) |
| [`stacks.py`](stacks.py) | Registre des 12 stacks : noms, parametres, cablage inter-stacks |
| [`dependency_graph.py`](dependency_graph.py) | Extraction exports/imports, graphe networkx, decoupage en vagues |
| [`deploy.py`](deploy.py) | Deploiement boto3 vague par vague, polling, chronos |
| [`cli.py`](cli.py) | Commandes `graph`, `validate`, `deploy` |
