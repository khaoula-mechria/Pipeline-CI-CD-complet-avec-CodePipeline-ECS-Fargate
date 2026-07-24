#!/usr/bin/env bash
set -uo pipefail
# NOTE : pas de 'set -e' ici, volontairement — ce script doit continuer
# jusqu'au bout même si un test individuel échoue, pour produire un rapport
# complet en une seule exécution plutôt que de s'arrêter au premier échec.

# ============================================================================
# test7-all-local.sh — exécute TOUS les tests locaux (Tests 1 à 6) en une
# seule commande, et affiche un rapport récapitulatif à la fin.
#
# Jusqu'ici, chaque template (ecr/codebuild/vpc/iam/pipeline/observability)
# se validait individuellement via son propre script (test-local.sh,
# test2-codebuild.sh, ..., test6-observability.sh). Ce script les enchaîne
# dans l'ORDRE DE DÉPENDANCE du projet (voir infrastructure/README.md) :
#
#   1. test-local.sh          (ecr.yaml)
#   2. test2-codebuild.sh     (codebuild.yaml + buildspec.yml)
#   3. test3-vpc.sh           (vpc.yml)
#   4. test4-iam.sh           (iam.yaml)
#   5. test5-pipeline.sh      (pipeline.yml)
#   6. test6-observability.sh (observability.yml)
#
# CHOIX DE CONCEPTION IMPORTANTS :
#
# - SKIP_BUILDSPEC_REPLAY=true est exporté avant d'appeler test2-codebuild.sh :
#   son étape 2 (clone git + docker pull d'une image CodeBuild de plusieurs
#   Go) est trop lente pour un run global rapide (déjà documenté : abandonnée
#   après 21 min lors du tout premier essai). L'étape 1 de test2 (cfn-lint +
#   tests unitaires + build Docker + healthcheck) couvre déjà, sans AWS, ce
#   qui compte. Lance test2-codebuild.sh seul (sans cette variable) si tu
#   veux spécifiquement rejouer buildspec.yml en entier.
#
# - Chaque script continue de gérer LUI-MÊME le démarrage de LocalStack, ses
#   propres copies de templates "allégées" (ressources Pro-only retirées) et
#   ses propres vérifications : ce script ne fait qu'orchestrer, il ne
#   duplique aucune logique de test.
#
# - Un test qui se termine avec un code de sortie != 0 est un ÉCHEC RÉEL —
#   les limitations LocalStack déjà connues et documentées (CodeStar
#   Connections, CodeBuild, ELBv2, ECS, CodeDeploy, CodePipeline Pro-only...)
#   sont TOUJOURS gérées à l'intérieur de chaque script (contournées ou
#   rendues non-bloquantes), qui se termine par exit 0 malgré elles. Voir
#   infrastructure/scripts/testing-output.md pour le détail de ce qui est
#   contourné dans chaque test.
#
# - Ce script NE s'arrête PAS au premier échec (pas de 'set -e' global) :
#   il exécute les 6 tests jusqu'au bout et rapporte tout à la fin, pour
#   avoir une vue complète en une seule exécution plutôt que de devoir
#   relancer après chaque correction.
#
# Prérequis : les mêmes que chaque script individuel — Docker installé et
# lancé, Node.js/npm, cfn-lint, git, curl, pip install awscli-local.
# ============================================================================

cd "$(dirname "$0")"

SKIP_BUILDSPEC_REPLAY="${SKIP_BUILDSPEC_REPLAY:-true}"
export SKIP_BUILDSPEC_REPLAY

RESULTS_DIR="$(mktemp -d /tmp/test7-all-local.XXXXXX)"
echo "Logs détaillés de chaque test : $RESULTS_DIR/"
echo ""

declare -a NAMES=(
  "Test 1 — ecr.yaml"
  "Test 2 — codebuild.yaml + buildspec.yml"
  "Test 3 — vpc.yml"
  "Test 4 — iam.yaml"
  "Test 5 — pipeline.yml"
  "Test 6 — observability.yml"
)
declare -a SCRIPTS=(
  "test-local.sh"
  "test2-codebuild.sh"
  "test3-vpc.sh"
  "test4-iam.sh"
  "test5-pipeline.sh"
  "test6-observability.sh"
)
declare -a EXIT_CODES=()
declare -a DURATIONS=()

TOTAL_START=$(date +%s)

for i in "${!SCRIPTS[@]}"; do
  script="${SCRIPTS[$i]}"
  name="${NAMES[$i]}"
  log_file="$RESULTS_DIR/$(printf '%02d' $((i + 1)))-${script%.sh}.log"

  echo "═══════════════════════════════════════════════════════════════"
  echo "▶ $name  ($script)"
  echo "═══════════════════════════════════════════════════════════════"

  step_start=$(date +%s)
  if bash "./$script" > >(tee "$log_file") 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi
  step_end=$(date +%s)

  EXIT_CODES+=("$exit_code")
  DURATIONS+=($((step_end - step_start)))

  echo ""
  if [ "$exit_code" -eq 0 ]; then
    echo "✅ $name terminé (code 0, $((step_end - step_start))s)"
  else
    echo "❌ $name a échoué (code $exit_code, $((step_end - step_start))s) — voir $log_file"
  fi
  echo ""
done

TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - TOTAL_START))

echo "═══════════════════════════════════════════════════════════════"
echo "RAPPORT RÉCAPITULATIF"
echo "═══════════════════════════════════════════════════════════════"
printf "%-45s %-8s %-8s\n" "Test" "Statut" "Durée"
printf "%-45s %-8s %-8s\n" "---------------------------------------------" "------" "-----"

OVERALL_STATUS=0
for i in "${!SCRIPTS[@]}"; do
  code="${EXIT_CODES[$i]}"
  duration="${DURATIONS[$i]}"
  if [ "$code" -eq 0 ]; then
    status="✅ PASS"
  else
    status="❌ FAIL"
    OVERALL_STATUS=1
  fi
  printf "%-45s %-8s %s\n" "${NAMES[$i]}" "$status" "${duration}s"
done

echo ""
echo "Durée totale : ${TOTAL_DURATION}s"
echo "Logs complets : $RESULTS_DIR/"
echo ""

if [ "$OVERALL_STATUS" -eq 0 ]; then
  echo "✅ Les 6 tests locaux sont passés (dans la limite documentée de ce que"
  echo "   LocalStack Community peut vérifier — voir testing-output.md pour le"
  echo "   détail précis de ce qui est/n'est pas testable localement)."
else
  echo "❌ Au moins un test a échoué réellement (pas une limite déjà connue et"
  echo "   documentée) — voir les logs ci-dessus pour diagnostiquer."
fi

exit $OVERALL_STATUS
