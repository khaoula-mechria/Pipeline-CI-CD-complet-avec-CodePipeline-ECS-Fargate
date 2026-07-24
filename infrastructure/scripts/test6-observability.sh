#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Test local du template CloudFormation observability.yml
# Fonctionne SANS accès au vrai compte AWS, grâce à LocalStack.
#
# DÉPENDANCES : observability.yml importe le topic SNS de pipeline.yml
# (déjà couvert par la stack de test allégée de test5-pipeline.sh) ainsi que
# 4 exports supplémentaires (noms ECS, nom "full" de l'ALB et du target
# group Blue) que la copie de TEST de pipeline.yml n'exporte pas — ces
# ressources (ALB, ECS) sont Pro-only sur LocalStack et ont donc été
# retirées de cette copie dans test5-pipeline.sh. Ce script déploie donc un
# petit stack "stub" qui exporte des valeurs FACTICES sous les mêmes noms,
# uniquement pour permettre de tester la STRUCTURE du dashboard (les
# métriques ECS/ALB elles-mêmes ne remonteront jamais de vraies données
# dans ce mode).
#
# LIMITES IMPORTANTES À CONNAÎTRE (confirmées empiriquement) :
#
# 1. Les appels CLI directs `aws cloudwatch ...` (describe-alarms,
#    list-dashboards, put-metric-data) échouent sur cette combinaison
#    LocalStack 3.8.1 / awscli 1.45.54 / botocore 1.43.54 avec l'erreur
#    "Operation detection failed. Missing Action in request for
#    query-protocol service ServiceModel(cloudwatch)". C'est un bug de
#    compatibilité CLI <-> LocalStack, PAS une limite Pro : confirmé en
#    déployant directement une Alarm et un Dashboard via CloudFormation
#    (qui n'utilise pas ce chemin CLI) — les deux atteignent CREATE_COMPLETE
#    sans problème. Ce script vérifie donc les ressources CloudWatch via
#    `aws cloudformation describe-stack-resources` / `describe-stacks`
#    plutôt que via `aws cloudwatch ...`.
#
# 2. AWS::Lambda::Function EST supporté par LocalStack Community (contrairement
#    à CodeBuild/CodeDeploy/ECS/CodePipeline), MAIS sa création déclenche en
#    coulisses un `docker pull` de l'image runtime (ex: image Python 3.12)
#    — sur le réseau contraint de cet environnement, ce pull est trop lent
#    pour être attendu (même classe de limite déjà documentée pour l'image
#    CodeBuild dans le Test 2 : abandonné après plusieurs minutes sans
#    progression visible). Ce script retire donc MetricsPublisherFunction
#    (+ son Permission + sa règle EventBridge dédiée) de la copie de test ;
#    le reste (rôle IAM, log group, 2 alarmes, dashboard) est réellement
#    déployé et vérifié. Le code Lambda lui-même n'est validable qu'en le
#    relisant (Python simple, ~40 lignes, cf. observability.yml) ou sur un
#    vrai compte AWS.
#
# Prérequis : Docker installé et LANCÉ AVEC ACCÈS AU SOCKET DOCKER DE L'HÔTE
# (`-v /var/run/docker.sock:/var/run/docker.sock`) si tu veux un jour tester
# la vraie invocation Lambda ; pas nécessaire pour ce script, qui la retire.
# pip install cfn-lint awscli-local
# ============================================================================

CFN_DIR="../cloudformation"
STACK_ECR="taskmanager-ecr-test"
STACK_CODEBUILD="taskmanager-codebuild-test"
STACK_IAM="taskmanager-iam-test"
STACK_PIPELINE="taskmanager-pipeline-test"
STACK_STUBS="taskmanager-dashboard-stubs-test"
STACK_OBSERVABILITY="taskmanager-observability-test"
ENDPOINT="http://localhost:4566"

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=eu-west-1

echo "──────────────────────────────────────────────"
echo "1) Analyse statique du template complet (cfn-lint)"
echo "──────────────────────────────────────────────"
cfn-lint "$CFN_DIR/observability.yml"
echo "✅ Template valide syntaxiquement"
echo ""

echo "──────────────────────────────────────────────"
echo "2) Démarrage de LocalStack (si pas déjà lancé)"
echo "──────────────────────────────────────────────"
if ! docker ps --format '{{.Names}}' | grep -q localstack; then
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
echo "3) Déploiement des dépendances (ecr, codebuild, iam, pipeline allégée)"
echo "   — réutilise les mêmes copies de test que test4/test5"
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

TMP_IAM="/tmp/iam-local-test.yaml"
python3 - "$CFN_DIR/iam.yaml" "$TMP_IAM" <<'PYEOF'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    content = f.read()
content = re.sub(r"  GitHubConnection:.*?(?=\n  CodePipelineServiceRole:)", "", content, flags=re.DOTALL)
content = content.replace(
    "                Resource:\n                  - !Ref GitHubConnection",
    "                Resource:\n                  - !Sub 'arn:aws:codestar-connections:${AWS::Region}:${AWS::AccountId}:connection/dummy'",
)
content = re.sub(r"  GitHubConnectionArn:.*?(?=\n  CodePipelineServiceRoleArn:)", "", content, flags=re.DOTALL)
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

aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file "$TMP_IAM" \
  --stack-name $STACK_IAM \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ProjectName=taskmanager Environment=dev

TMP_PIPELINE="/tmp/pipeline-local-test.yaml"
python3 - "$CFN_DIR/pipeline.yml" "$TMP_PIPELINE" <<'PYEOF'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    content = f.read()

def remove_block(content, name):
    pattern = rf"^  {name}:\n(?:.*\n)*?(?=^  [A-Za-z]\w*:|^[A-Za-z]|\Z)"
    return re.sub(pattern, "", content, flags=re.MULTILINE)

REMOVE_RESOURCES = [
    "ApplicationLoadBalancer", "BlueTargetGroup", "GreenTargetGroup",
    "ProdListener", "TestListener",
    "EcsCluster", "EcsTaskDefinition", "EcsService",
    "CodeDeployApplication", "CodeDeployDeploymentGroup",
    "CodePipeline",
]
for name in REMOVE_RESOURCES:
    content = remove_block(content, name)

REMOVE_OUTPUTS = [
    "LoadBalancerDnsName", "AlbFullName", "BlueTargetGroupFullName",
    "EcsClusterName", "EcsServiceName",
    "CodePipelineName", "CodeDeployApplicationName",
    "CodeDeployDeploymentGroupName",
]
for name in REMOVE_OUTPUTS:
    content = remove_block(content, name)

with open(dst, "w") as f:
    f.write(content)
print(f"Template temporaire écrit dans {dst}")
PYEOF

aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file "$TMP_PIPELINE" \
  --stack-name $STACK_PIPELINE \
  --parameter-overrides ProjectName=taskmanager Environment=dev
echo ""

echo "──────────────────────────────────────────────"
echo "4) Déploiement d'un stack 'stub' exportant des valeurs FACTICES pour"
echo "   les 4 exports ECS/ALB que la copie de test de pipeline.yml ne"
echo "   fournit pas (ressources Pro-only retirées, cf. test5) — nécessaire"
echo "   UNIQUEMENT pour que le Dashboard (import-dépendant) se déploie ici"
echo "──────────────────────────────────────────────"
TMP_STUBS="/tmp/dashboard-stubs-test.yaml"
cat > "$TMP_STUBS" <<'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Stack de test UNIQUEMENT : exporte des valeurs factices sous les noms que
  pipeline.yml exporterait normalement pour EcsClusterName/EcsServiceName/
  AlbFullName/BlueTargetGroupFullName, ressources Pro-only sur LocalStack
  (voir test5-pipeline.sh) et donc absentes de la copie de test réelle.
Parameters:
  ProjectName:
    Type: String
    Default: taskmanager
  Environment:
    Type: String
    Default: dev
Resources:
  # AWS::CloudFormation::WaitConditionHandle : ressource "no-op" la plus
  # légère qui existe, juste pour satisfaire l'obligation d'avoir au moins
  # une ressource dans le template.
  Placeholder:
    Type: AWS::CloudFormation::WaitConditionHandle
Outputs:
  EcsClusterName:
    Value: !Sub '${ProjectName}-${Environment}-cluster'
    Export:
      Name: !Sub '${ProjectName}-${Environment}-ecs-cluster-name'
  EcsServiceName:
    Value: !Sub '${ProjectName}-${Environment}-service'
    Export:
      Name: !Sub '${ProjectName}-${Environment}-ecs-service-name'
  AlbFullName:
    Value: !Sub 'app/${ProjectName}-${Environment}-alb/0000000000000000'
    Export:
      Name: !Sub '${ProjectName}-${Environment}-alb-full-name'
  BlueTargetGroupFullName:
    Value: !Sub 'targetgroup/${ProjectName}-${Environment}-tg-blue/0000000000000000'
    Export:
      Name: !Sub '${ProjectName}-${Environment}-tg-blue-full-name'
EOF

aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file "$TMP_STUBS" \
  --stack-name $STACK_STUBS \
  --parameter-overrides ProjectName=taskmanager Environment=dev
echo ""

echo "──────────────────────────────────────────────"
echo "5) Génération d'une copie temporaire de observability.yml SANS la"
echo "   fonction Lambda (+ sa Permission + sa règle EventBridge dédiée) —"
echo "   limite Docker-pull décrite en en-tête de ce script"
echo "──────────────────────────────────────────────"
TMP_OBSERVABILITY="/tmp/observability-local-test.yaml"
python3 - "$CFN_DIR/observability.yml" "$TMP_OBSERVABILITY" <<'PYEOF'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    content = f.read()

def remove_block(content, name):
    pattern = rf"^  {name}:\n(?:.*\n)*?(?=^  [A-Za-z]\w*:|^[A-Za-z]|\Z)"
    return re.sub(pattern, "", content, flags=re.MULTILINE)

for name in ["MetricsPublisherFunction", "MetricsPublisherPermission", "PipelineMetricsEventRule"]:
    content = remove_block(content, name)
for name in ["MetricsPublisherFunctionArn"]:
    content = remove_block(content, name)

with open(dst, "w") as f:
    f.write(content)
print(f"Template temporaire écrit dans {dst}")
PYEOF

aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file "$TMP_OBSERVABILITY" \
  --stack-name $STACK_OBSERVABILITY \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ProjectName=taskmanager Environment=dev
echo ""

echo "──────────────────────────────────────────────"
echo "6) Vérification des ressources créées (describe-stack-resources —"
echo "   PAS 'aws cloudwatch ...', cf. limite CLI en en-tête)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation describe-stack-resources \
  --stack-name $STACK_OBSERVABILITY \
  --query "StackResources[].[LogicalResourceId,ResourceType,ResourceStatus]" \
  --output table
echo ""

echo "──────────────────────────────────────────────"
echo "7) Vérification du contenu réel du Dashboard (DashboardBody rendu,"
echo "   via describe-stacks -> pas d'output direct pour ça : on relit le"
echo "   template déployé pour confirmer les imports résolus)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation get-template \
  --stack-name $STACK_OBSERVABILITY \
  --query "TemplateBody" --output text | grep -A2 "ecs-cluster-name\|PipelineDuration" | head -20 || true
echo ""

echo "──────────────────────────────────────────────"
echo "8) Vérification des outputs de la stack"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation describe-stacks \
  --stack-name $STACK_OBSERVABILITY \
  --query "Stacks[0].Outputs"

echo ""
echo "✅ Tests locaux terminés (partiellement — voir en-tête du script)."
echo "   Rappel : MetricsPublisherFunction (Lambda) n'a pas été déployée"
echo "   dans cette copie de test (pull Docker trop lent en local) ; les"
echo "   alarmes et le dashboard sont réellement créés et vérifiés."
