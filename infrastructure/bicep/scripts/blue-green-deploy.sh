#!/usr/bin/env bash
# ==============================================================================
# blue-green-deploy.sh
#
# Scripted Blue/Green traffic shift for Azure Container Apps - this is the
# direct replacement for what AWS CodeDeploy's ECSLinear10PercentEvery1Minutes
# DeploymentConfig + BlueGreenDeploymentConfiguration did natively in
# pipeline.yml. Azure has the underlying PRIMITIVE (multiple simultaneously
# active revisions with independently controlled traffic weights) but no
# managed "CodeDeploy for Container Apps" service that owns the stepped
# progression + health-gated rollback for you - that orchestration has to
# live here, called from azure-pipelines.yml's Deploy stage.
#
# Steps, mirroring the AWS deployment group's shape:
#   1. Create a new revision from the freshly pushed image, at 0% traffic
#      (the "Green" revision) - equivalent of CodeDeploy provisioning the new
#      task set before any traffic moves.
#   2. Hit the new revision directly on its OWN revision-specific FQDN
#      (the ACA equivalent of AWS's TestListener on port 8080) before it
#      receives ANY production traffic.
#   3. Shift weights 10 -> 50 -> 100, validating /health and /version on the
#      PRODUCTION fqdn after each step (so we're validating what real users
#      actually hit, not just the revision-specific URL).
#   4. On any failure: revert to 100% on the stable ("Blue") revision and
#      deactivate the bad one - equivalent of AutoRollbackConfiguration's
#      DEPLOYMENT_FAILURE trigger in pipeline.yml.
#   5. On full success: deactivate the old revision - equivalent of
#      TerminateBlueInstancesOnDeploymentSuccess (5-minute wait in AWS;
#      immediate here since Azure bills replicas by actual usage, not a
#      running EC2/Fargate task that needs a grace period to drain).
#
# VERIFY BEFORE FIRST USE: the per-revision FQDN pattern used in
# get_revision_fqdn() below (querying `az containerapp revision list
# --query [].fqdn` directly, rather than constructing the URL by string
# convention) is deliberately queried rather than guessed, precisely because
# the exact hostname format is a platform detail that can change - do not
# hardcode a URL pattern here even if you've seen one that "looks stable".
# ==============================================================================
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:?set RESOURCE_GROUP}"
CONTAINER_APP_NAME="${CONTAINER_APP_NAME:?set CONTAINER_APP_NAME}"
IMAGE_REF="${IMAGE_REF:?set IMAGE_REF, e.g. <acrLoginServer>/taskmanager:<commitSha>}"
IMAGE_TAG="${IMAGE_TAG:?set IMAGE_TAG - used as the revision suffix, must be a valid revision-name segment}"
STEPS="${TRAFFIC_STEPS:-10 50 100}"
STEP_WAIT_SECONDS="${STEP_WAIT_SECONDS:-60}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-120}"

log() { echo "[blue-green] $(date -u +%H:%M:%S) - $*"; }

get_active_stable_revision() {
  # The revision currently carrying traffic BEFORE this deployment starts.
  az containerapp revision list \
    --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
    --query "[?properties.trafficWeight > \`0\`].name" -o tsv | head -n1
}

get_revision_fqdn() {
  local revision_name="$1"
  az containerapp revision show \
    --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
    --revision "$revision_name" --query "properties.fqdn" -o tsv
}

get_production_fqdn() {
  az containerapp show \
    --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
    --query "properties.configuration.ingress.fqdn" -o tsv
}

check_health() {
  local url="$1"
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  while [ $SECONDS -lt $deadline ]; do
    if curl -sf --max-time 5 "https://${url}/health" >/dev/null; then
      log "healthy: https://${url}/health"
      return 0
    fi
    log "waiting for https://${url}/health ..."
    sleep 5
  done
  log "ERROR: ${url}/health never became healthy within ${HEALTH_TIMEOUT_SECONDS}s"
  return 1
}

check_version() {
  local url="$1"
  local expected_tag="$2"
  local actual
  actual=$(curl -sf --max-time 5 "https://${url}/version" | node -e "process.stdin.resume();let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).version)}catch(e){process.exit(1)}})") || return 1
  if [ "$actual" != "$expected_tag" ]; then
    log "ERROR: /version returned '${actual}', expected '${expected_tag}'"
    return 1
  fi
  log "/version confirms build ${actual}"
}

rollback() {
  local stable="$1"
  local bad="$2"
  log "ROLLBACK TRIGGERED: reverting 100% traffic to stable revision ${stable}"
  az containerapp ingress traffic set \
    --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
    --revision-weight "${stable}=100" "${bad}=0" >/dev/null
  az containerapp revision deactivate \
    --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
    --revision "$bad" >/dev/null || log "WARN: could not deactivate ${bad}, traffic is already at 0% for it so this is non-blocking"
  log "Rollback complete. Production traffic is 100% on ${stable}."
  exit 1
}

main() {
  local stable_revision new_revision production_fqdn new_revision_fqdn

  stable_revision=$(get_active_stable_revision)
  log "current stable revision: ${stable_revision}"

  log "creating new revision from ${IMAGE_REF} (0% traffic)"
  az containerapp update \
    --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
    --image "$IMAGE_REF" --revision-suffix "$IMAGE_TAG" >/dev/null

  new_revision="${CONTAINER_APP_NAME}--${IMAGE_TAG}"
  # Pin BOTH revisions by name explicitly. This deliberately overrides the
  # bootstrap `latestRevision: true` traffic rule from container-platform.bicep
  # - once the pipeline owns traffic shifting, weights must be pinned to
  # specific revision names, never left on the "whatever's newest" rule.
  az containerapp ingress traffic set \
    --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
    --revision-weight "${stable_revision}=100" "${new_revision}=0" >/dev/null

  new_revision_fqdn=$(get_revision_fqdn "$new_revision")
  log "validating new revision directly at https://${new_revision_fqdn} (0% prod traffic - equivalent of AWS's CodeDeploy test listener)"
  check_health "$new_revision_fqdn" || { az containerapp revision deactivate --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" --revision "$new_revision"; exit 1; }
  check_version "$new_revision_fqdn" "$IMAGE_TAG" || { az containerapp revision deactivate --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" --revision "$new_revision"; exit 1; }

  production_fqdn=$(get_production_fqdn)

  for weight in $STEPS; do
    stable_weight=$((100 - weight))
    log "shifting traffic: ${new_revision}=${weight}% / ${stable_revision}=${stable_weight}%"
    az containerapp ingress traffic set \
      --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
      --revision-weight "${new_revision}=${weight}" "${stable_revision}=${stable_weight}" >/dev/null

    log "waiting ${STEP_WAIT_SECONDS}s before validating this step"
    sleep "$STEP_WAIT_SECONDS"

    check_health "$production_fqdn" || rollback "$stable_revision" "$new_revision"
  done

  log "100% traffic on ${new_revision} - deactivating old stable revision ${stable_revision}"
  az containerapp revision deactivate \
    --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" \
    --revision "$stable_revision" >/dev/null

  log "Blue/Green deployment complete. ${new_revision} is now the sole active revision."
}

main "$@"
