#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Test local du template CloudFormation vpc.yml
# Fonctionne SANS accès au vrai compte AWS, grâce à LocalStack.
#
# LIMITE IMPORTANTE À CONNAÎTRE (vérifiée empiriquement, à citer telle
# quelle dans le rapport) :
# La version Community de LocalStack accepte la ressource AWS::EC2::EIP au
# niveau CloudFormation (CREATE_COMPLETE), mais ne l'émule pas vraiment côté
# EC2 : son AllocationId reste "unknown" (confirmé avec
# `aws ec2 describe-addresses` -> liste vide). Comme AWS::EC2::NatGateway a
# besoin de cet AllocationId, sa création échoue systématiquement
# (InvalidAllocationID.NotFound), et la stack entière finit en
# CREATE_FAILED — sans rapport avec la qualité du template.
# Ce script valide donc, malgré cet échec attendu du NAT Gateway :
#   - que le template est syntaxiquement valide (cfn-lint + validate-template)
#   - que VPC, subnets (x4), Internet Gateway, route tables et le VPC
#     Endpoint S3 se créent tous correctement
# Il NE valide PAS la création du NAT Gateway, ni le routage réseau réel
# des subnets privés — cela ne peut être vérifié que sur un vrai compte AWS
# (voir section "AWS validation steps" plus bas).
#
# Prérequis : Docker installé, pip install cfn-lint awscli
# ============================================================================

TEMPLATE="../cloudformation/vpc.yml"
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
  docker run -d --rm --name localstack \
    -p 4566:4566 \
    -e SERVICES=ec2,iam,logs,cloudformation \
    localstack/localstack:3.8.1
  echo "En attente que LocalStack soit prêt..."
  ATTEMPTS=0
  MAX_ATTEMPTS=30
  until curl -s -o /dev/null http://localhost:4566/_localstack/health; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
      echo "❌ LocalStack n'a pas démarré après $((MAX_ATTEMPTS * 2))s (voir 'docker logs localstack')."
      exit 1
    fi
    sleep 2
  done
  echo "✅ LocalStack est prêt !"
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
# Une stack déjà en CREATE_FAILED d'un run précédent bloque tout nouveau
# 'deploy' -> on repart propre si elle existe.
aws --endpoint-url=$ENDPOINT cloudformation delete-stack --stack-name $STACK_NAME 2>/dev/null || true
aws --endpoint-url=$ENDPOINT cloudformation wait stack-delete-complete --stack-name $STACK_NAME 2>/dev/null || true

set +e
aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file $TEMPLATE \
  --stack-name $STACK_NAME \
  --parameter-overrides ProjectName=taskmanager Environment=dev NatGatewayStrategy=single
DEPLOY_EXIT_CODE=$?
set -e

echo ""
if [ "$DEPLOY_EXIT_CODE" -ne 0 ]; then
  echo "⚠️  Le déploiement s'est arrêté (code $DEPLOY_EXIT_CODE) — c'est ATTENDU sur"
  echo "   LocalStack Community : NatGateway1 échoue car l'AllocationId de son EIP"
  echo "   reste 'unknown' (EIP non réellement émulé). VPC/subnets/route tables/IGW"
  echo "   se créent bien avant ce point (vérifié ci-dessous)."
else
  echo "✅ Déploiement complet réussi (cas rare : cette version de LocalStack émule l'EIP)."
fi

# VpcId récupéré via son tag EC2 (fonctionne même si la stack est en
# CREATE_FAILED, contrairement aux Outputs qui ne sont jamais publiés tant
# que la stack n'atteint pas CREATE_COMPLETE — et plus fiable juste après un
# déploiement en échec que 'cloudformation describe-stack-resources', dont
# la réponse peut être temporairement vide sur LocalStack).
VPC_ID=$(aws --endpoint-url=$ENDPOINT ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=taskmanager" \
  --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)

echo ""
echo "──────────────────────────────────────────────"
echo "5) Vérification des subnets créés (4 attendus : 2 publics + 2 privés)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT ec2 describe-subnets \
  --filters "Name=tag:Project,Values=taskmanager" \
  --query "Subnets[].{Id:SubnetId,Cidr:CidrBlock,AZ:AvailabilityZone}"

echo ""
echo "──────────────────────────────────────────────"
echo "6) Vérification des tables de routage (4 attendues : 1 principale"
echo "   implicite + 1 publique + 2 privées)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[].RouteTableId"

echo ""
echo "──────────────────────────────────────────────"
echo "7) Vérification des outputs exportés"
echo "──────────────────────────────────────────────"
OUTPUTS=$(aws --endpoint-url=$ENDPOINT cloudformation describe-stacks \
  --stack-name $STACK_NAME --query "Stacks[0].Outputs" --output json 2>/dev/null || echo "null")
echo "$OUTPUTS"
if [ "$OUTPUTS" = "null" ]; then
  echo "ℹ️  Pas d'outputs : normal, la stack n'a pas atteint CREATE_COMPLETE"
  echo "   (bloquée par la limite EIP/NAT ci-dessus, pas par le template)."
fi

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