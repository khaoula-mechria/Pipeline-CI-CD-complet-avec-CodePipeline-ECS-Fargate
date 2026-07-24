#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Test local du template CloudFormation iam.yaml
# Fonctionne SANS accès au vrai compte AWS, grâce à LocalStack.
#
# DÉPENDANCE : iam.yaml importe l'ARN exporté par codebuild.yaml
# (${ProjectName}-${Environment}-codebuild-arn). Ce script déploie donc
# ecr.yaml puis codebuild.yaml AVANT iam.yaml, dans le bon ordre.
#
# LIMITES IMPORTANTES À CONNAÎTRE (confirmées empiriquement, à citer telles
# quelles dans le rapport) :
#
# 1. AWS::CodeStarConnections::Connection n'est PAS supporté par la version
#    Community de LocalStack (service avancé, réservé à LocalStack Pro).
#    Ce script déploie donc iam.yaml UNE FOIS SANS la ressource
#    GitHubConnection (copie temporaire du template). La connexion GitHub
#    elle-même ne peut être testée structurellement qu'avec cfn-lint
#    (étape 1), pas avec un déploiement local.
#
# 2. AWS::CodeBuild::Project est ÉGALEMENT un service Pro-only sur LocalStack
#    Community : `aws codebuild list-projects` renvoie explicitement
#    "API for service 'codebuild' not yet implemented or pro feature".
#    CloudFormation accepte quand même la ressource à la création (comme
#    pour l'EIP du NAT Gateway dans vpc.yml), mais son attribut Arn n'est
#    jamais résolu : Fn::GetAtt BuildProject.Arn renvoie le littéral
#    "unknown", qui se propage via l'Output exporté
#    (${ProjectName}-${Environment}-codebuild-arn) jusqu'à l'import fait par
#    iam.yaml (statement TriggerCodeBuild) et fait échouer PutRolePolicy
#    avec "MalformedPolicyDocument: Resource unknown must be in ARN format
#    or *". Ce script remplace donc aussi cet import par un ARN factice dans
#    la copie temporaire, pour isoler ce qui teste VRAIMENT iam.yaml.
#
# Prérequis : Docker installé, pip install cfn-lint awscli-local
# ============================================================================

CFN_DIR="../cloudformation"
STACK_ECR="taskmanager-ecr-test"
STACK_CODEBUILD="taskmanager-codebuild-test"
STACK_IAM="taskmanager-iam-test"
ENDPOINT="http://localhost:4566"

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=eu-west-1

echo "──────────────────────────────────────────────"
echo "1) Analyse statique du template complet (cfn-lint)"
echo "   Ceci valide AUSSI la ressource GitHubConnection,"
echo "   même si elle ne sera pas déployée sur LocalStack."
echo "──────────────────────────────────────────────"
cfn-lint "$CFN_DIR/iam.yaml"
echo "✅ Template valide syntaxiquement"
echo ""

echo "──────────────────────────────────────────────"
echo "2) Démarrage de LocalStack (si pas déjà lancé)"
echo "──────────────────────────────────────────────"
if ! docker ps --format '{{.Names}}' | grep -q localstack; then
  # Image épinglée (3.8.1, déjà validée dans test3-vpc.sh) plutôt que
  # "latest" : évite un pull non déterministe et un éventuel changement de
  # comportement entre exécutions.
  docker run -d --rm --name localstack -p 4566:4566 localstack/localstack:3.8.1
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
else
  echo "LocalStack déjà actif."
fi
echo ""

echo "──────────────────────────────────────────────"
echo "3) Déploiement des dépendances (ecr.yaml puis codebuild.yaml)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file "$CFN_DIR/ecr.yaml" \
  --stack-name $STACK_ECR \
  --parameter-overrides ProjectName=taskmanager Environment=dev

aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file "$CFN_DIR/codebuild.yaml" \
  --stack-name $STACK_CODEBUILD \
  --parameter-overrides ProjectName=taskmanager Environment=dev \
    GitHubRepoUrl=https://github.com/ton-user/taskmanager.git
echo ""

echo "──────────────────────────────────────────────"
echo "4) Génération d'une copie temporaire de iam.yaml SANS GitHubConnection"
echo "   et avec un ARN factice pour l'import CodeBuild (deux limites"
echo "   LocalStack Community documentées en en-tête de ce script)"
echo "──────────────────────────────────────────────"
TMP_TEMPLATE="/tmp/iam-local-test.yaml"
python3 - "$CFN_DIR/iam.yaml" "$TMP_TEMPLATE" <<'PYEOF'
import sys, re

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    content = f.read()

# Supprime le bloc de ressource GitHubConnection (jusqu'au prochain
# résource de niveau 2 espaces, en l'occurrence "  CodePipelineServiceRole:")
content = re.sub(
    r"  GitHubConnection:.*?(?=\n  CodePipelineServiceRole:)",
    "",
    content,
    flags=re.DOTALL,
)

# Remplace la référence à GitHubConnection dans la policy CodePipeline
# par une valeur factice, pour ne pas casser Ref
content = content.replace(
    "                Resource:\n                  - !Ref GitHubConnection",
    "                Resource:\n                  - !Sub 'arn:aws:codestar-connections:${AWS::Region}:${AWS::AccountId}:connection/dummy'",
)

# Retire l'Output GitHubConnectionArn
content = re.sub(
    r"  GitHubConnectionArn:.*?(?=\n  CodePipelineServiceRoleArn:)",
    "",
    content,
    flags=re.DOTALL,
)

# Remplace l'import de l'ARN CodeBuild par un ARN factice : sur LocalStack
# Community, AWS::CodeBuild::Project est un service Pro-only (CloudFormation
# accepte la ressource, mais son Arn n'est jamais résolu -> "unknown"), donc
# l'Output exporté par codebuild.yaml vaut littéralement "unknown" et casse
# la policy IAM en aval. Ceci isole le test pour valider iam.yaml lui-même.
content = content.replace(
    "                Resource:\n"
    "                  - !ImportValue\n"
    "                    'Fn::Sub': '${ProjectName}-${Environment}-codebuild-arn'",
    "                Resource:\n"
    "                  - !Sub 'arn:aws:codebuild:${AWS::Region}:${AWS::AccountId}:project/${ProjectName}-${Environment}-build'",
)

with open(dst, "w") as f:
    f.write(content)

print(f"Template temporaire écrit dans {dst}")
PYEOF
echo ""

echo "──────────────────────────────────────────────"
echo "5) Déploiement de iam.yaml (version testable) sur LocalStack"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file "$TMP_TEMPLATE" \
  --stack-name $STACK_IAM \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ProjectName=taskmanager Environment=dev

echo ""
echo "──────────────────────────────────────────────"
echo "6) Vérification des 4 rôles créés"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT iam list-roles \
  --query "Roles[?contains(RoleName, 'taskmanager-dev')].RoleName"

echo ""
echo "──────────────────────────────────────────────"
echo "7) Vérification des outputs exportés"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation describe-stacks \
  --stack-name $STACK_IAM \
  --query "Stacks[0].Outputs"

echo ""
echo "✅ Tests locaux terminés."
echo "   Rappel : GitHubConnection n'a été validé QUE syntaxiquement"
echo "   (cfn-lint), pas déployé. Son autorisation manuelle et son bon"
echo "   fonctionnement ne sont vérifiables que sur un vrai compte AWS."