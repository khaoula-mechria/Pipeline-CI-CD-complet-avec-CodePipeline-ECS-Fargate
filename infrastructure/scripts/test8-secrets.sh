#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Test local de secrets-manager.yaml (secrets applicatifs, F3 du CDC)
# Fonctionne SANS accès au vrai compte AWS, grâce à LocalStack.
#
# Ce que ce test valide vraiment :
#   - le template est syntaxiquement correct (cfn-lint) ;
#   - les 2 secrets se créent et AWS génère bien leur valeur
#     (GenerateSecretString) : aucune valeur n'est écrite dans le dépôt ;
#   - le secret DB est un JSON contenant les clés "username" et "password"
#     -> c'est ce qui rend valide la syntaxe "<arn>:password::" utilisée par
#        ecs-task-definition.yaml et taskdef.template.json ;
#   - les 4 outputs sont exportés sous les noms attendus par codebuild.yaml
#     et ecs-task-definition.yaml.
#
# Prérequis : Docker installé et lancé, cfn-lint, awscli, curl, python3.
# ============================================================================

cd "$(dirname "$0")"
TEMPLATE="../cloudformation/secrets-manager.yaml"
STACK_NAME="taskmanager-secrets-test"
ENDPOINT="http://localhost:4566"
PROJECT="taskmanager"
ENVIRONMENT="dev"

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=eu-west-2

echo "──────────────────────────────────────────────"
echo "1) Analyse statique du template (cfn-lint)"
echo "──────────────────────────────────────────────"
cfn-lint "$TEMPLATE"
echo "✅ secrets-manager.yaml valide syntaxiquement"
echo ""

echo "──────────────────────────────────────────────"
echo "2) Démarrage de LocalStack (si pas déjà lancé)"
echo "──────────────────────────────────────────────"
if ! docker ps --format '{{.Names}}' | grep -q localstack; then
  docker run -d --rm --name localstack \
    -p 4566:4566 \
    -e SERVICES=secretsmanager,cloudformation \
    localstack/localstack:3.8.1
  echo "En attente que LocalStack soit prêt..."
  ATTEMPTS=0
  MAX_ATTEMPTS=30
  until curl -s -o /dev/null "$ENDPOINT/_localstack/health"; do
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

# Une stack laissée en CREATE_FAILED/ROLLBACK_COMPLETE par un run précédent
# bloque tout nouveau deploy (même correctif défensif que test5-pipeline.sh).
STACK_STATUS="$(aws --endpoint-url="$ENDPOINT" cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "ABSENTE")"
if [ "$STACK_STATUS" != "ABSENTE" ] && [ "$STACK_STATUS" != "CREATE_COMPLETE" ] && [ "$STACK_STATUS" != "UPDATE_COMPLETE" ]; then
  echo "Suppression d'une stack précédente en état $STACK_STATUS..."
  aws --endpoint-url="$ENDPOINT" cloudformation delete-stack --stack-name "$STACK_NAME"
  aws --endpoint-url="$ENDPOINT" cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" || true
fi

echo "──────────────────────────────────────────────"
echo "3) Déploiement de la stack"
echo "──────────────────────────────────────────────"
aws --endpoint-url="$ENDPOINT" cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides "ProjectName=$PROJECT" "Environment=$ENVIRONMENT"
echo "✅ Stack déployée"
echo ""

echo "──────────────────────────────────────────────"
echo "4) Vérification des 2 secrets créés"
echo "──────────────────────────────────────────────"
aws --endpoint-url="$ENDPOINT" secretsmanager describe-secret \
  --secret-id "$PROJECT/$ENVIRONMENT/db" --query '{Name:Name,ARN:ARN}'
aws --endpoint-url="$ENDPOINT" secretsmanager describe-secret \
  --secret-id "$PROJECT/$ENVIRONMENT/api-key" --query '{Name:Name,ARN:ARN}'
echo "✅ Les 2 secrets existent"
echo ""

echo "──────────────────────────────────────────────"
echo "5) Structure du secret DB (JSON username/password)"
echo "   La VALEUR n'est jamais affichée : seules les clés"
echo "   présentes et la longueur du mot de passe le sont."
echo "──────────────────────────────────────────────"
DB_JSON="$(aws --endpoint-url="$ENDPOINT" secretsmanager get-secret-value \
  --secret-id "$PROJECT/$ENVIRONMENT/db" --query SecretString --output text)"

DB_JSON="$DB_JSON" python3 - <<'PY'
import json, os, sys

secret = json.loads(os.environ["DB_JSON"])
keys = sorted(secret.keys())
print("clés présentes         :", keys)

if keys != ["password", "username"]:
    print("❌ le secret DB devrait contenir exactement username + password")
    sys.exit(1)

print("username               :", secret["username"], "(non sensible)")
print("longueur du password   :", len(secret["password"]), "caractères (généré par AWS)")

if len(secret["password"]) != 32:
    print(f"❌ longueur inattendue : {len(secret['password'])} au lieu de 32")
    sys.exit(1)

interdits = set('"@/\\') & set(secret["password"])
if interdits:
    print("❌ caractères exclus présents malgré ExcludeCharacters :", interdits)
    sys.exit(1)
print("caractères exclus      : aucun présent ✅ (\" @ / \\)")
PY
echo "✅ Secret DB conforme à ce qu'attend la task definition"
echo ""

echo "──────────────────────────────────────────────"
echo "6) Vérification des 4 outputs exportés"
echo "   (consommés par codebuild.yaml et"
echo "    ecs-task-definition.yaml)"
echo "──────────────────────────────────────────────"
OUTPUTS="$(aws --endpoint-url="$ENDPOINT" cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --query 'Stacks[0].Outputs' --output json)"
echo "$OUTPUTS"

OUTPUTS="$OUTPUTS" PROJECT="$PROJECT" ENVIRONMENT="$ENVIRONMENT" python3 - <<'PY'
import json, os, sys

outputs = json.loads(os.environ["OUTPUTS"])
exports = {o.get("ExportName") for o in outputs}
prefix = f"{os.environ['PROJECT']}-{os.environ['ENVIRONMENT']}"
attendus = {
    f"{prefix}-db-secret-arn",
    f"{prefix}-api-key-secret-arn",
    f"{prefix}-db-secret-name",
    f"{prefix}-api-key-secret-name",
}
manquants = attendus - exports
if manquants:
    print("❌ exports manquants :", sorted(manquants))
    sys.exit(1)
print("\n✅ les 4 exports attendus sont présents")
PY
echo ""

echo "──────────────────────────────────────────────"
echo "Résumé"
echo "──────────────────────────────────────────────"
echo "✅ secrets-manager.yaml valide (cfn-lint)"
echo "✅ 2 secrets créés, valeurs générées par AWS (rien en clair dans le dépôt)"
echo "✅ Secret DB au format JSON username/password -> syntaxe '<arn>:password::' exploitable"
echo "✅ 4 outputs exportés sous les noms attendus par les stacks en aval"
echo ""
echo "ℹ️  NON testable en local : l'injection réelle des secrets dans le"
echo "   conteneur par l'agent ECS (service ecs = Pro-only sur LocalStack"
echo "   Community, cf. Test 5). Elle ne pourra être vérifiée que sur un vrai"
echo "   compte AWS, en inspectant les variables d'environnement de la tâche."
