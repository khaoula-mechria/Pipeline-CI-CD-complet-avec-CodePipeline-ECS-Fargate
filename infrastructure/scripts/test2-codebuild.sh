#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Test local de codebuild.yaml + buildspec.yml (application task-manager)
# Fonctionne SANS accès au vrai compte AWS.
#
# SKIP_BUILDSPEC_REPLAY=true saute l'étape 2 (clone git + docker pull d'une
# image CodeBuild officielle de plusieurs Go) : sur le réseau contraint de
# certains environnements, ce pull est trop lent pour être attendu (déjà
# documenté : abandonné après 21 min lors du premier essai). L'étape 1
# (cfn-lint + tests unitaires + build Docker + healthcheck) couvre déjà,
# sans AWS, les deux critères qui comptent — voir test7-all-local.sh, qui
# active ce mode par défaut pour un run global rapide.
#
# Prérequis : Docker installé et lancé, Node.js/npm, cfn-lint, git, curl.
# ============================================================================

SKIP_BUILDSPEC_REPLAY="${SKIP_BUILDSPEC_REPLAY:-false}"

cd "$(dirname "$0")"
ROOT_DIR="$(cd ../.. && pwd)"
TEMPLATE="../cloudformation/codebuild.yaml"
APP_DIR="$ROOT_DIR/task-manager"
IMAGE_TAG="taskmanager:test2"
CONTAINER_NAME="taskmanager-test2"
CODEBUILD_IMAGE="public.ecr.aws/codebuild/amazonlinux2-x86_64-standard:5.0"

echo "──────────────────────────────────────────────"
echo "0) Analyse statique du template (cfn-lint)"
echo "   Vérifie codebuild.yaml, AUCUN accès AWS requis."
echo "──────────────────────────────────────────────"
cfn-lint "$TEMPLATE"
echo "✅ Template codebuild.yaml valide syntaxiquement"
echo ""

echo "──────────────────────────────────────────────"
echo "1) Validation manuelle : tests unitaires + image Docker"
echo "   (équivalent 'Niveau 1' — ne touche jamais AWS)"
echo "──────────────────────────────────────────────"

cleanup_container() {
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT

echo "-> npm ci"
(cd "$ROOT_DIR" && npm ci)

echo "-> npm test"
(cd "$ROOT_DIR" && npm test)
echo "✅ Tests unitaires OK"
echo ""

echo "-> docker build (Dockerfile de $APP_DIR)"
docker build -t "$IMAGE_TAG" "$APP_DIR"
echo "✅ Image Docker construite avec succès"
echo ""

echo "-> docker run + vérification /health"
cleanup_container
docker run -d --name "$CONTAINER_NAME" -p 3000:3000 "$IMAGE_TAG" >/dev/null

ATTEMPTS=0
MAX_ATTEMPTS=15
until curl -sf http://localhost:3000/health >/dev/null; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    echo "❌ /health n'a pas répondu après $((MAX_ATTEMPTS * 2))s (voir 'docker logs $CONTAINER_NAME')."
    exit 1
  fi
  sleep 2
done
echo "✅ GET /health répond 200"
cleanup_container
trap - EXIT
echo ""

if [ "$SKIP_BUILDSPEC_REPLAY" = "true" ]; then
  echo "──────────────────────────────────────────────"
  echo "2) Rejeu de buildspec.yml — SAUTÉ (SKIP_BUILDSPEC_REPLAY=true)"
  echo "──────────────────────────────────────────────"
  echo "ℹ️  Étape volontairement sautée (clone git + docker pull de plusieurs Go,"
  echo "   trop lent pour un run global). Voir test2-codebuild.sh sans cette"
  echo "   variable pour l'exécuter."
  echo ""
else
echo "──────────────────────────────────────────────"
echo "2) Rejeu de buildspec.yml via l'agent CodeBuild officiel"
echo "   (aws-codebuild-docker-images, 100% local, aucun compte AWS)"
echo "──────────────────────────────────────────────"

WORKDIR="$(mktemp -d)"
cleanup_workdir() {
  rm -rf "$WORKDIR"
}
trap cleanup_workdir EXIT

echo "Clonage de aws/aws-codebuild-docker-images dans $WORKDIR"
git clone --depth 1 https://github.com/aws/aws-codebuild-docker-images.git "$WORKDIR/aws-codebuild-docker-images"

echo "Téléchargement de codebuild_build.sh"
curl -sS -o "$WORKDIR/codebuild_build.sh" \
  https://raw.githubusercontent.com/aws/aws-codebuild-docker-images/master/local_builds/codebuild_build.sh
chmod +x "$WORKDIR/codebuild_build.sh"

echo "docker pull $CODEBUILD_IMAGE"
docker pull "$CODEBUILD_IMAGE"

echo ""
echo "Exécution de buildspec.yml (source = $APP_DIR)..."
set +e
"$WORKDIR/codebuild_build.sh" \
  -i "$CODEBUILD_IMAGE" \
  -a "$WORKDIR/artifacts" \
  -s "$APP_DIR"
BUILD_EXIT_CODE=$?
set -e

echo ""
if [ "$BUILD_EXIT_CODE" -ne 0 ]; then
  echo "⚠️  Le rejeu s'est arrêté (code $BUILD_EXIT_CODE) — c'est ATTENDU sans compte AWS."
  echo "   La phase pre_build appelle 'aws ecr get-login-password' contre le vrai"
  echo "   endpoint AWS ECR : sans credentials réelles, cet appel échoue immédiatement,"
  echo "   avant même 'docker build' et les tests. Seule la phase 'install' (npm ci +"
  echo "   SAST Semgrep) va au bout en local dans ce mode."
  echo "   -> Pour valider tests unitaires + build Docker sans AWS, utiliser l'étape 1"
  echo "      ci-dessus (ou 'buildspec.yml' n'est volontairement pas modifié pour"
  echo "      contourner cette limite)."
else
  echo "✅ Rejeu complet de buildspec.yml réussi (cas rare : credentials AWS détectées)."
fi
fi

echo ""
echo "──────────────────────────────────────────────"
echo "Résumé"
echo "──────────────────────────────────────────────"
echo "✅ codebuild.yaml valide (cfn-lint)"
echo "✅ Tests unitaires + image Docker + /health validés sans AWS (étape 1)"
if [ "$SKIP_BUILDSPEC_REPLAY" = "true" ]; then
  echo "ℹ️  Rejeu buildspec.yml (étape 2) sauté (SKIP_BUILDSPEC_REPLAY=true)."
else
  echo "ℹ️  Ordonnancement des phases buildspec.yml rejoué (étape 2) — le blocage à la"
  echo "   connexion ECR est normal sans compte AWS ; 'build'/'post_build' ne seront"
  echo "   exercés en pratique que par la vraie CI une fois déployée (voir README)."
fi
