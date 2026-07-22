# Tester l'infrastructure sans accès AWS

Deux niveaux de test, du plus léger au plus complet.

## Niveau 1 — cfn-lint (recommandé au quotidien)

Valide la syntaxe et les bonnes pratiques CloudFormation, sans jamais
contacter AWS. C'est le test à lancer à chaque modification du template.

```bash
pip install cfn-lint
cfn-lint infrastructure/cloudformation/ecr.yaml
```

Aucune sortie = template valide. Il détecte aussi les erreurs de logique
(ex: référence à un paramètre qui n'existe pas, type de ressource mal
orthographié, propriété manquante obligatoire).

## Niveau 2 — LocalStack (simulation complète)

LocalStack fait tourner une fausse API AWS dans Docker, sur ta machine.
Tu peux réellement déployer la stack et créer "un vrai" repository ECR
(local, pas sur AWS), vérifier les outputs — exactement comme tu le
ferais en prod, mais gratuit et sans compte AWS.

Prérequis :

```bash
pip install cfn-lint awscli-local
```

Docker doit être installé et lancé. Pas besoin de démarrer LocalStack
à la main : le script s'en charge (voir ci-dessous).

```bash
cd infrastructure/scripts
chmod +x test-local.sh
./test-local.sh
```

Le script `test-local.sh` exécute, dans l'ordre :

1. **cfn-lint** sur `../cloudformation/ecr.yaml` — arrête tout de suite
   si le template est syntaxiquement invalide.
2. **Démarrage de LocalStack** — si un conteneur nommé `localstack`
   tourne déjà, il est réutilisé ; sinon le script lance
   `localstack/localstack:3.8.1` (services `ecr` + `cloudformation`
   sur le port 4566) et attend jusqu'à 60s (30 tentatives, 2s
   d'intervalle) que `/_localstack/health` réponde.
3. **`aws cloudformation validate-template`** contre l'endpoint
   LocalStack, pour vérifier que le template est bien formé du point
   de vue de l'API CloudFormation.
4. **Déploiement de la stack** (`aws cloudformation deploy`) sous le
   nom `taskmanager-ecr-test`, avec les paramètres
   `ProjectName=taskmanager Environment=dev`.
5. **`aws ecr describe-repositories`** pour confirmer que le
   repository a bien été créé par la stack.
6. **`aws cloudformation describe-stacks`** pour afficher les outputs
   de la stack (`RepositoryUri`, `RepositoryArn`, `RepositoryName`).

Les identifiants AWS factices (`AWS_ACCESS_KEY_ID=test`,
`AWS_SECRET_ACCESS_KEY=test`, région `eu-west-1`) sont exportés
directement par le script — LocalStack ne vérifie pas leur validité,
mais l'AWS CLI exige qu'ils soient présents.

Limite à connaître : la version communautaire (gratuite) de LocalStack
simule bien la création du repository, le scan on push et les policies,
mais l'exécution réelle du scan de vulnérabilités CVE n'est pas simulée
(c'est un service backend AWS propriétaire). Pour valider cette partie
précise, il faudra le vrai accès AWS — mais tout le reste (structure du
template, paramètres, outputs, lifecycle policy) est testable dès
maintenant.

## Niveau 3 — le vrai déploiement (dès que l'accès AWS arrive)

```bash
aws cloudformation deploy \
  --template-file infrastructure/cloudformation/ecr.yaml \
  --stack-name taskmanager-ecr-dev \
  --parameter-overrides ProjectName=taskmanager Environment=dev
```

Puis vérifier dans la console AWS → ECR → repositories, que :
- le repo apparaît en "Private"
- "Scan on push" est bien "Enabled"
- l'onglet "Lifecycle policy" affiche la règle "Garder uniquement les 10
  dernières images"
