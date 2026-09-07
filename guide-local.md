# Guide 1 — Tester le projet en local (sans AWS)

Tout ce qui peut être vérifié **sans compte AWS, sans clé d'API et sans aucun
coût**. À faire avant tout déploiement réel.

Pour le déploiement sur un vrai compte, voir **[`guide-aws.md`](guide-aws.md)**.

Chaque étape indique la commande exacte et le **résultat attendu**. Les sorties
ci-dessous ont été relevées sur ce dépôt le 2026-09-07.

---

## Prérequis

| Outil | Version testée | Nécessaire pour |
|---|---|---|
| Node.js + npm | 20+ | l'application |
| Python | 3.13 | les templates et les 4 modules |
| Docker | 29.4 | l'image (daemon démarré) |

```bash
node --version && npm --version && python --version && docker --version
```

---

## 1. Application Node.js

```bash
cd task-manager
npm ci
npm test
```

**Attendu** — le seuil de couverture est bloquant à 80 % :

```
File      | % Stmts | % Branch | % Funcs | % Lines
All files |   99.33 |    99.1  |   100   |   100
 app.js   |   100   |   100    |   100   |   100
 tasks.js |   98.73 |   98.46  |   100   |   100
 views.js |   100   |   100    |   100   |   100

Test Suites: 4 passed, 4 total
Tests:       63 passed, 63 total
```

Puis l'application elle-même :

```bash
npm start                              # http://localhost:3000
```

Dans un autre terminal :

```bash
curl http://localhost:3000/health      # {"status":"ok"}
curl http://localhost:3000/version     # {"version":"dev"}
curl http://localhost:3000/api/tasks   # []
```

`/health` est utilisé par trois mécanismes distincts (HEALTHCHECK Docker, health
check du conteneur ECS, target groups Blue/Green de l'ALB). S'il ne répond pas
200, rien ne se déploiera sur AWS.

> **Rapports générés** : `coverage/lcov-report/index.html` (HTML),
> `coverage/cobertura-coverage.xml` (lu par CodeBuild) et `reports/junit.xml`.

---

## 2. Image Docker

Le daemon Docker doit tourner (Docker Desktop démarré).

```bash
cd task-manager
docker build -t taskmanager:localtest .
docker run --rm -d -p 3000:3000 --name tm-test taskmanager:localtest
sleep 5 && curl http://localhost:3000/health     # {"status":"ok"}
docker stop tm-test
```

Vérifier la taille — l'exigence du CDC est < 200 Mo :

```bash
docker inspect --format '{{.Size}}' taskmanager:localtest
```

**Attendu** : ~52 600 000 octets, soit **~50,2 Mo**.

> N'utilise pas `docker images` pour ce contrôle : la taille affichée y est
> gonflée par le bundling des attestations BuildKit. Seul `docker inspect`
> donne la valeur comparable à la cible des 200 Mo.

L'image doit aussi tourner en utilisateur non-root :

```bash
docker run --rm taskmanager:localtest whoami       # doit renvoyer autre chose que "root"
```

---

## 3. Templates CloudFormation

```bash
pip install cfn-lint
cfn-lint --region eu-west-2 infrastructure/cloudformation/*.yaml infrastructure/cloudformation/*.yml
```

**Attendu** : **0 erreur**, et 5 avertissements `W6001` sur `pipeline.yml`.

`W6001` (« Check Outputs using ImportValue ») est **normal ici** : `pipeline.yml`
ré-exporte des valeurs qu'il importe d'autres stacks. C'est un choix assumé, pas
un défaut.

> Préciser `--region eu-west-2` a de l'importance. Sans ce drapeau, cfn-lint
> valide contre **toutes** les régions AWS et remonte ~22 fausses erreurs
> `E3006` du type « `AWS::CodeStarConnections::Connection` does not exist in
> `ap-east-2` » — ces services n'existent simplement pas dans ces régions, que
> le projet ne cible pas.

---

## 4. Les 4 modules Python

```bash
pip install -r requirements-modules.txt
python -m pytest orchestrator/ optimizer/ explainer/ dashboard/ -q
```

**Attendu** : `67 passed`. Aucun de ces tests ne contacte AWS ni l'API Anthropic.

### 4.1 Ordre de déploiement (module 1)

```bash
python -m orchestrator graph
```

**Attendu** — c'est cette sortie qui fait autorité sur l'ordre de déploiement,
pas l'ordre écrit dans un guide :

```
12 stacks, 22 dependances, 7 vagues

  Vague 1 (en parallele)
    - ecr, ecs-cluster, secrets, vpc
  Vague 2 (en parallele)
    - alb          <- vpc
    - codebuild    <- ecr, secrets
  Vague 3   - iam          <- codebuild
  Vague 4   - taskdef      <- ecr, iam, secrets
  Vague 5   - ecs-service  <- alb, ecs-cluster, taskdef, vpc
  Vague 6   - pipeline     <- alb, ecs-cluster, ecs-service, iam
  Vague 7 (en parallele)
    - autoscaling, observability
```

Pour voir le motif de chaque dépendance :

```bash
python -m orchestrator graph --edges
```

Vérifier les paramètres avant tout déploiement :

```bash
python -m orchestrator validate
```

**Attendu** : `12/12` templates chargés, graphe acyclique, 7 vagues, puis
**3 points à corriger** — `GitHubRepoUrl`, `FullRepositoryId` et `AlarmEmail`
sont vides tant que les variables d'environnement ne sont pas définies. Le code
de sortie est 1, c'est voulu.

### 4.2 Simuler le déploiement, sans toucher à AWS

```bash
export GITHUB_REPO_URL="https://github.com/khaoula-mechria/Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate"
python -m orchestrator deploy --dry-run
```

**Attendu** : les 7 vagues s'enchaînent, chaque stack passe `CREATE_COMPLETE`,
et le bilan final affiche le temps parallèle, le séquentiel estimé et le gain.
**Aucun appel AWS n'est émis** — les exports sont simulés à partir du graphe.

Sans `GITHUB_REPO_URL`, le dry-run s'arrête proprement en vague 2 avec le motif
exact (`parametre(s) obligatoire(s) sans valeur : GitHubRepoUrl`) : c'est le
comportement attendu, pas un bug.

### 4.3 Analyse de rightsizing (module 2)

```bash
python -m optimizer analyze --sample
```

**Attendu** : le tableau comparatif « Règle maison / AWS Compute Optimizer ».
Avec `--sample`, les métriques viennent de `optimizer/sample_metrics.json` et
sont étiquetées `source=sample` partout — elles ne peuvent pas être confondues
avec des mesures réelles, et Compute Optimizer n'est pas interrogé.

```bash
python -m optimizer analyze --sample --json > rapport-demo.json
```

### 4.4 Explication en langage naturel (module 3)

Sans clé d'API et sans aucun coût, pour voir ce qui serait envoyé au modèle :

```bash
python -m explainer explain --sample --print-prompt
```

Avec une clé :

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
python -m explainer explain --sample
```

**Vérifier les garde-fous** — les deux commandes doivent **refuser** :

```bash
python -m explainer apply --report rapport-demo.json
# -> "Le drapeau --apply est obligatoire pour modifier l'infrastructure."

python -m explainer apply --report rapport-demo.json --apply
# -> "Le rapport repose sur des metriques d'EXEMPLE (--sample). ... refuse."
```

Aucun chemin de code n'enchaîne analyse → application. Même avec `--apply` sur
de vraies données, une confirmation tapée au clavier est exigée, et seules les
réponses `o`/`oui`/`y`/`yes` valent accord.

### 4.5 Tableau de bord (module 4)

```bash
streamlit run dashboard/app.py          # http://localhost:8501
```

**Attendu** : trois onglets.

- **Déploiement** — le graphe des 12 stacks. Sans credentials AWS, un
  avertissement s'affiche (`AWS injoignable…`) et l'application bascule sur le
  fichier d'orchestrateur : c'est le comportement prévu. Pour voir les couleurs
  évoluer, lancer `python -m orchestrator deploy --dry-run` dans un autre
  terminal et choisir « Fichier d'orchestrateur » comme source d'état.
- **Optimisation** — cocher « Utiliser les métriques d'exemple », puis
  « Analyser ».
- **Explication** — nécessite `ANTHROPIC_API_KEY`. Le bouton « Appliquer »
  reste désactivé tant que la case n'est pas cochée **et** que le mot
  `APPLIQUER` n'est pas saisi.

Lecture du graphe : trait plein = `Fn::ImportValue`, **pointillés** = dépendance
passant par un paramètre, **orange** = arête menant à une stack en cours.

---

## 5. Scripts de validation avancée

`infrastructure/scripts/` contient 9 scripts qui vont plus loin (LocalStack,
rejeu du buildspec via l'agent CodeBuild local). Ils sont écrits en Bash — sous
Windows, les lancer depuis Git Bash ou WSL.

```bash
cd infrastructure/scripts
./test7-all-local.sh          # enchaîne les 6 tests principaux, ~10 min
```

> **Limite connue** : LocalStack en édition gratuite n'émule ni ALB, ni ECS, ni
> CodeDeploy, ni CodePipeline, ni CodeBuild, ni CodeStar Connections. Ces six
> services ne sont donc validables que sur un vrai compte AWS
> ([`guide-aws.md`](guide-aws.md)).

---

## 6. SAST (Semgrep)

C'est le même gate que celui de la CI et de CodeBuild :

```bash
pip install semgrep
cd task-manager
semgrep --config auto --error .
```

**Attendu** : `0 findings`. La règle CSRF est volontairement neutralisée sur la
ligne `const app = express();` de `src/app.js` — l'application n'a ni session ni
cookie d'authentification sur lequel une requête forgée pourrait s'appuyer.

> **Semgrep ne tourne pas nativement sous Windows** (le binaire moteur n'y est
> pas fourni) : utiliser WSL, Docker, ou s'appuyer sur la CI GitHub Actions, qui
> exécute exactement cette commande.
>
> `--config auto` télécharge un jeu de règles distant qui **évolue dans le
> temps** : du code inchangé peut se mettre à échouer un jour. C'est déjà arrivé
> sur ce projet.

---

## Récapitulatif

| # | Vérification | Commande | Attendu |
|---|---|---|---|
| 1 | Tests applicatifs | `npm test` | 63 tests, ~99 % |
| 2 | Image Docker | `docker inspect --format '{{.Size}}'` | ~50,2 Mo < 200 Mo |
| 3 | Templates | `cfn-lint --region eu-west-2 …` | 0 erreur, 5 W6001 |
| 4 | Modules Python | `python -m pytest …` | 67 passed |
| 5 | Ordre de déploiement | `python -m orchestrator graph` | 12 stacks, 22 dép., 7 vagues |
| 6 | Simulation complète | `python -m orchestrator deploy --dry-run` | 7 vagues, 0 appel AWS |
| 7 | Garde-fous humains | `python -m explainer apply …` sans `--apply` | refus |
| 8 | SAST | `semgrep --config auto --error .` | 0 finding |

Une fois ces huit points au vert, passer à **[`guide-aws.md`](guide-aws.md)**.
