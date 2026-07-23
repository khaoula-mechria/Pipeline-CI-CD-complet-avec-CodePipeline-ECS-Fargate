#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Test local du template CloudFormation vpc.yaml
# Fonctionne SANS accès au vrai compte AWS, grâce à LocalStack.
#
# LIMITE IMPORTANTE À CONNAÎTRE (à citer telle quelle dans le rapport) :
# La version Community de LocalStack accepte de créer les ressources
# AWS::EC2::NatGateway et AWS::EC2::VPCEndpoint (elle renvoie des IDs
# valides et les stocke), mais n'émule PAS le comportement réseau réel
# (le NAT ne route pas vraiment de trafic). Ce script valide donc :
#   - que le template se déploie sans erreur CloudFormation
#   - que toutes les ressources et leurs relations sont cohérentes
#   - que les outputs sont bien exportés
# Il NE valide PAS que le NAT Gateway route effectivement le trafic
# internet des subnets privés — cela ne peut être vérifié que sur un
# vrai compte AWS (voir section "AWS validation steps").
#
# Prérequis : Docker installé, pip install cfn-lint awscli-local
# ============================================================================

TEMPLATE="../cloudformation/vpc.yaml"
STACK_NAME="taskmanager-vpc-test"
ENDPOINT="http://localhost:4566"

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=eu-west-1

echo "──────────────────────────────────────────────"
echo "1) Analyse statique du template (cfn-lint)"
echo "──────────────────────────────────────────────"
cfn-lint "$TEMPLATE"
echo "✅ Template valide syntaxiquement"
echo ""

echo "──────────────────────────────────────────────"
echo "2) Démarrage de LocalStack (si pas déjà lancé)"
echo "──────────────────────────────────────────────"
if ! docker ps --format '{{.Names}}' | grep -q localstack; then
  docker run -d --rm --name localstack -p 4566:4566 localstack/localstack
  echo "En attente que LocalStack soit prêt..."
  sleep 8
else
  echo "LocalStack déjà actif."
fi
echo ""

echo "──────────────────────────────────────────────"
echo "3) Validation du template"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation validate-template \
  --template-body file://$TEMPLATE

echo ""
echo "──────────────────────────────────────────────"
echo "4) Déploiement simulé (stratégie NAT = single, par défaut)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file $TEMPLATE \
  --stack-name $STACK_NAME \
  --parameter-overrides ProjectName=taskmanager Environment=dev NatGatewayStrategy=single

echo ""
echo "──────────────────────────────────────────────"
echo "5) Vérification des subnets créés (4 attendus : 2 publics + 2 privés)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT ec2 describe-subnets \
  --filters "Name=tag:Project,Values=taskmanager" \
  --query "Subnets[].{Id:SubnetId,Cidr:CidrBlock,AZ:AvailabilityZone}"

echo ""
echo "──────────────────────────────────────────────"
echo "6) Vérification des tables de routage (3 attendues : 1 publique + 2 privées)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$(aws --endpoint-url=$ENDPOINT cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)" \
  --query "RouteTables[].RouteTableId"

echo ""
echo "──────────────────────────────────────────────"
echo "7) Vérification des outputs exportés"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs"

echo ""
echo "──────────────────────────────────────────────"
echo "8) (Optionnel) Test de la stratégie HA -> décommenter pour tester"
echo "──────────────────────────────────────────────"
# aws --endpoint-url=$ENDPOINT cloudformation deploy \
#   --template-file $TEMPLATE \
#   --stack-name ${STACK_NAME}-ha \
#   --parameter-overrides ProjectName=taskmanager Environment=prod NatGatewayStrategy=ha

echo ""
echo "✅ Tests locaux structurels terminés."
echo "   Rappel : le comportement réel du NAT Gateway n'est PAS validé ici,"
echo "   seulement sur un vrai compte AWS (voir README-tests-locaux.md)."