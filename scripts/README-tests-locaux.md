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
(local, pas sur AWS), pousser une image de test, vérifier les outputs —
exactement comme tu le ferais en prod, mais gratuit et sans compte AWS.

```bash
pip install awscli-local
docker pull localstack/localstack

cd infrastructure/scripts
chmod +x test-local.sh
./test-local.sh
```

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
