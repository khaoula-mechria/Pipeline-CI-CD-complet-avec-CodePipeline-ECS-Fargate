#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Test local du template CloudFormation pipeline.yml
# Fonctionne SANS accès au vrai compte AWS, grâce à LocalStack.
#
# DÉPENDANCES : pipeline.yml importe les exports de vpc.yml, ecr.yaml,
# codebuild.yaml et iam.yaml. Ce script déploie donc les 4 dans l'ordre
# avant pipeline.yml.
#
# LIMITE MAJEURE À CONNAÎTRE (confirmée empiriquement, à citer telle quelle
# dans le rapport) : SIX des ressources de pipeline.yml reposent sur des
# services que LocalStack Community n'implémente PAS du tout (contrairement
# à CodeBuild/CodeStarConnections où la ressource est au moins acceptée) :
#   - AWS::ElasticLoadBalancingV2::LoadBalancer / TargetGroup / Listener
#     ("API for service 'elbv2' not yet implemented or pro feature")
#   - AWS::ECS::Cluster / TaskDefinition / Service
#     ("API for service 'ecs' not yet implemented or pro feature")
#   - AWS::CodeDeploy::Application / DeploymentGroup
#     ("API for service 'codedeploy' not yet implemented or pro feature")
#   - AWS::CodePipeline::Pipeline
#     ("API for service 'codepipeline' not yet implemented or pro feature")
# Contrairement à AWS::CodeBuild::Project (qui est CRÉÉ mais renvoie un Arn
# "unknown"), ces types de ressources font ÉCHOUER la création elle-même
# (CREATE_FAILED immédiat sur la ressource concernée) — CloudFormation ne les
# accepte même pas de façon dégradée.
#
# Cette limite touche la MAJORITÉ du contenu utile de pipeline.yml (ALB,
# target groups, listeners, cluster/service ECS, CodeDeploy, CodePipeline
# lui-même). Ce script :
#   1. Valide la totalité du template avec cfn-lint (toutes les ressources).
#   2. Déploie une copie temporaire de vpc.yml SANS NAT Gateway (limite déjà
#      connue depuis test3-vpc.sh) pour obtenir de VRAIS exports VpcId/
#      subnet-ids que pipeline.yml peut importer.
#   3. Déploie une copie temporaire de pipeline.yml qui NE garde QUE les
#      ressources réellement supportées par LocalStack Community : le
#      bucket S3 d'artefacts, le topic SNS + sa policy, la règle EventBridge,
#      le log group ECS (CloudWatch Logs, supporté), et les 2 security
#      groups (EC2, supporté). Tout le reste (ALB/TG/Listeners/ECS/
#      CodeDeploy/CodePipeline) est retiré de cette copie de test — leur
#      validation structurelle reste garantie par cfn-lint (étape 1),
#      leur déploiement réel n'est vérifiable que sur un vrai compte AWS.
#
# Prérequis : Docker installé, pip install cfn-lint awscli-local
# ============================================================================

CFN_DIR="../cloudformation"
STACK_ECR="taskmanager-ecr-test"
STACK_CODEBUILD="taskmanager-codebuild-test"
STACK_IAM="taskmanager-iam-test"
STACK_VPC="taskmanager-vpc-test"
STACK_PIPELINE="taskmanager-pipeline-test"
ENDPOINT="http://localhost:4566"

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=eu-west-1

echo "──────────────────────────────────────────────"
echo "1) Analyse statique du template complet (cfn-lint)"
echo "   Valide TOUTES les ressources, y compris celles non"
echo "   déployables sur LocalStack Community (voir en-tête)."
echo "──────────────────────────────────────────────"
cfn-lint "$CFN_DIR/pipeline.yml"
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
echo "3) Déploiement des dépendances (ecr, codebuild, iam)"
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

# Copie de iam.yaml sans GitHubConnection ni import CodeBuild réel — mêmes
# limites que test4-iam.sh (voir cet en-tête pour le détail).
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
echo ""

echo "──────────────────────────────────────────────"
echo "4) Déploiement d'une copie de vpc.yml SANS NAT Gateway"
echo "   (limite EIP/NAT déjà documentée dans test3-vpc.sh) pour"
echo "   obtenir de VRAIS exports VpcId / subnet-ids"
echo "──────────────────────────────────────────────"
TMP_VPC="/tmp/vpc-local-test.yaml"
python3 - "$CFN_DIR/vpc.yml" "$TMP_VPC" <<'PYEOF'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    content = f.read()

def remove_resource_block(content, name):
    # ^ (MULTILINE) marque le début de ligne juste après un \n, ce qui
    # détecte correctement la ressource suivante même si elle est précédée
    # d'un bloc de commentaires (pas seulement d'une ligne vide) — piège
    # rencontré en développant ce script : un lookahead ancré sur \n
    # littéral rate ce cas et sur-consomme jusqu'à la ressource suivante.
    pattern = rf"^  {name}:\n(?:.*\n)*?(?=^  [A-Za-z]\w*:|^[A-Za-z]|\Z)"
    return re.sub(pattern, "", content, flags=re.MULTILINE)

# Retire les 2 EIP + 2 NAT Gateway (non émulés par LocalStack Community).
for name in ["NatGateway1Eip", "NatGateway2Eip", "NatGateway1", "NatGateway2"]:
    content = remove_resource_block(content, name)
# Retire les 2 routes privées 0.0.0.0/0 -> NAT (plus de ressource NAT à cibler).
for name in ["PrivateRoute1", "PrivateRoute2"]:
    content = remove_resource_block(content, name)

with open(dst, "w") as f:
    f.write(content)
print(f"Template temporaire écrit dans {dst}")
PYEOF

# Si test3-vpc.sh (ou ce script) a tourné avant sous le même nom de stack,
# elle est très probablement en CREATE_FAILED/ROLLBACK_COMPLETE (NAT Gateway
# — cf. test3-vpc.sh) : un 'deploy' ne peut pas mettre à jour une stack dans
# cet état. On repart propre, comme le fait déjà test3-vpc.sh.
aws --endpoint-url=$ENDPOINT cloudformation delete-stack --stack-name $STACK_VPC 2>/dev/null || true
aws --endpoint-url=$ENDPOINT cloudformation wait stack-delete-complete --stack-name $STACK_VPC 2>/dev/null || true

aws --endpoint-url=$ENDPOINT cloudformation deploy \
  --template-file "$TMP_VPC" \
  --stack-name $STACK_VPC \
  --parameter-overrides ProjectName=taskmanager Environment=dev
echo ""

echo "──────────────────────────────────────────────"
echo "5) Vérification des exports VPC (doivent être réels cette fois,"
echo "   la stack atteint CREATE_COMPLETE sans NAT Gateway)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT cloudformation describe-stacks \
  --stack-name $STACK_VPC \
  --query "Stacks[0].Outputs"
echo ""

echo "──────────────────────────────────────────────"
echo "6) Génération d'une copie temporaire de pipeline.yml ne gardant"
echo "   QUE les ressources supportées par LocalStack Community"
echo "   (S3, SNS+policy, EventBridge, Logs, 2 security groups EC2)"
echo "──────────────────────────────────────────────"
TMP_PIPELINE="/tmp/pipeline-local-test.yaml"
python3 - "$CFN_DIR/pipeline.yml" "$TMP_PIPELINE" <<'PYEOF'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    content = f.read()

def remove_block(content, name):
    # Voir le commentaire équivalent dans la copie de vpc.yml plus haut :
    # ancrage MULTILINE, pas un lookahead \n littéral, pour survivre aux
    # blocs de commentaires entre deux ressources/outputs.
    pattern = rf"^  {name}:\n(?:.*\n)*?(?=^  [A-Za-z]\w*:|^[A-Za-z]|\Z)"
    return re.sub(pattern, "", content, flags=re.MULTILINE)

# Ressources retirées : Pro-only sur LocalStack Community (ELBv2 entier,
# ECS Cluster/TaskDefinition/Service, CodeDeploy, CodePipeline).
REMOVE_RESOURCES = [
    "ApplicationLoadBalancer", "BlueTargetGroup", "GreenTargetGroup",
    "ProdListener", "TestListener",
    "EcsCluster", "EcsTaskDefinition", "EcsService",
    "CodeDeployApplication", "CodeDeployDeploymentGroup",
    "CodePipeline",
]
for name in REMOVE_RESOURCES:
    content = remove_block(content, name)

# Outputs retirés : référencent des ressources qui viennent d'être retirées.
REMOVE_OUTPUTS = [
    "LoadBalancerDnsName", "EcsClusterName", "EcsServiceName",
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
echo "7) Vérification du bucket S3 d'artefacts (versioning + nom exact"
echo "   attendu par CodePipelineServiceRole dans iam.yaml)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT s3api get-bucket-versioning \
  --bucket "taskmanager-dev-pipeline-artifacts-000000000000"
echo ""

echo "──────────────────────────────────────────────"
echo "8) Vérification du topic SNS + sa policy (publish autorisé"
echo "   pour events.amazonaws.com)"
echo "──────────────────────────────────────────────"
TOPIC_ARN=$(aws --endpoint-url=$ENDPOINT sns list-topics \
  --query "Topics[?contains(TopicArn, 'pipeline-notifications')].TopicArn" --output text)
echo "Topic ARN: $TOPIC_ARN"
aws --endpoint-url=$ENDPOINT sns get-topic-attributes --topic-arn "$TOPIC_ARN" \
  --query "Attributes.Policy" --output text
echo ""

echo "──────────────────────────────────────────────"
echo "9) Vérification de la règle EventBridge"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT events describe-rule \
  --name taskmanager-dev-pipeline-state-change
echo ""

echo "──────────────────────────────────────────────"
echo "10) Vérification des 2 security groups (règles de port)"
echo "──────────────────────────────────────────────"
aws --endpoint-url=$ENDPOINT ec2 describe-security-groups \
  --filters "Name=group-name,Values=*${STACK_PIPELINE}*,taskmanager*" \
  --query "SecurityGroups[].[GroupName,IpPermissions[].FromPort]" 2>&1 || \
aws --endpoint-url=$ENDPOINT ec2 describe-security-groups \
  --query "SecurityGroups[?contains(Description, 'taskmanager-dev')].[GroupName,Description,IpPermissions[].FromPort]"

echo ""
echo "✅ Tests locaux terminés (partiellement — voir en-tête du script)."
echo "   Rappel : ALB, target groups, listeners, cluster/service ECS,"
echo "   CodeDeploy et CodePipeline lui-même ne sont validés QUE"
echo "   syntaxiquement (cfn-lint, étape 1) — non déployables en local,"
echo "   limite LocalStack Community. Le reste (S3, SNS+policy,"
echo "   EventBridge, security groups) est déployé et vérifié ci-dessus."
