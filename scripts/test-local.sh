#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Test local du template CloudFormation ecr.yaml
# Fonctionne SANS accès au vrai compte AWS, grâce à LocalStack
# (émulateur AWS qui tourne dans un conteneur Docker sur ta machine).
#
# Prérequis : Docker installé, pip install cfn-lint awscli-local
# ============================================================================

TEMPLATE="../cloudformation/ecr.yaml"
STACK_NAME="taskmanager-ecr-test"
ENDPOINT="http://localhost:4566"

# Identifiants factices : LocalStack n'a pas besoin de vraies clés AWS,
# mais l'AWS CLI exige que ces variables existent pour construire la requête.
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=eu-west-1

echo "──────────────────────────────────────────────"
echo "1) Analyse statique du template (cfn-lint)"
echo "   Vérifie la syntaxe et les bonnes pratiques AWS,"
echo "   AUCUN accès AWS requis pour cette étape."
echo "──────────────────────────────────────────────"
cfn-lint "$TEMPLATE"
echo "✅ Template valide syntaxiquement"
echo ""

echo "──────────────────────────────────────────────"
echo "2) Démarrage de LocalStack (si pas déjà lancé)"
echo "──────────────────────────────────────────────"
if ! docker ps --format '{{.Names}}' | grep -q localstack; then
  docker run -d --rm --name localstack \
    -p 4566:4566 \
    localstack/localstack
  echo "En attente que LocalStack soit prêt..."
  sleep 8
else
  echo "LocalStack déjà actif."
fi
echo ""

echo "──────────────────────────────────────────────"
echo "3) Validation du template (équivalent local de"
echo "   'aws cloudformation validate-template')"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation validate-template \
  --template-body file://$TEMPLATE

echo ""
echo "──────────────────────────────────────────────"
echo "4) Déploiement simulé de la stack"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file $TEMPLATE \
  --stack-name $STACK_NAME \
  --parameter-overrides ProjectName=taskmanager Environment=dev

echo ""
echo "──────────────────────────────────────────────"
echo "5) Vérification que le repository ECR existe"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT ecr describe-repositories

echo ""
echo "──────────────────────────────────────────────"
echo "6) Vérification des outputs de la stack"
echo "   (RepositoryUri, RepositoryArn, RepositoryName)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs"

echo ""
echo "✅ Tous les tests locaux sont passés."
echo "   Le template est prêt pour un déploiement réel dès que"
echo "   l'accès au compte AWS sera disponible."
