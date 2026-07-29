#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Test local de ecs-autoscaling.yaml (Application Auto Scaling, F3 du CDC)
# Fonctionne SANS accès au vrai compte AWS.
#
# LIMITE STRUCTURELLE DE CE TEST, à lire avant de s'étonner de sa brièveté :
# les 3 ressources de ce template dépendent de services que LocalStack
# Community n'implémente PAS :
#   - AWS::ApplicationAutoScaling::ScalableTarget / ScalingPolicy
#     -> service "application-autoscaling", non émulé ;
#   - les 2 alarmes CloudWatch importent le topic SNS de pipeline.yml et les
#     noms de cluster/service ECS, or ecs est Pro-only (cf. Test 5).
# Un déploiement LocalStack de ce template échouerait donc pour des raisons
# d'émulation, pas de template — comme déjà documenté pour l'ALB/ECS/CodeDeploy
# au Test 5. Ce script fait donc de la validation STATIQUE approfondie plutôt
# que du déploiement : cfn-lint + vérifications structurelles ciblées sur les
# erreurs réellement plausibles ici (mauvais format de ResourceId, mauvaise
# dimension scalable, seuils incohérents, exports attendus manquants).
#
# Prérequis : cfn-lint, python3 (avec PyYAML).
# ============================================================================

cd "$(dirname "$0")"
TEMPLATE="../cloudformation/ecs-autoscaling.yaml"
SERVICE_TEMPLATE="../cloudformation/ecs-service.yaml"

echo "──────────────────────────────────────────────"
echo "1) Analyse statique du template (cfn-lint)"
echo "──────────────────────────────────────────────"
cfn-lint "$TEMPLATE"
echo "✅ ecs-autoscaling.yaml valide syntaxiquement"
echo ""

echo "──────────────────────────────────────────────"
echo "2) Vérifications structurelles"
echo "──────────────────────────────────────────────"

TEMPLATE="$TEMPLATE" SERVICE_TEMPLATE="$SERVICE_TEMPLATE" python3 - <<'PY'
import os
import sys

import yaml


# CloudFormation utilise des tags YAML courts (!Ref, !Sub, !ImportValue) que
# le loader standard refuse : on les charge en objets opaques, il suffit de
# pouvoir inspecter la STRUCTURE du template.
class CfnLoader(yaml.SafeLoader):
    pass


def opaque(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return {f"Fn::{tag_suffix}": loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return {f"Fn::{tag_suffix}": loader.construct_sequence(node, deep=True)}
    return {f"Fn::{tag_suffix}": loader.construct_mapping(node, deep=True)}


CfnLoader.add_multi_constructor("!", opaque)

with open(os.environ["TEMPLATE"], encoding="utf-8") as handle:
    template = yaml.load(handle, Loader=CfnLoader)
with open(os.environ["SERVICE_TEMPLATE"], encoding="utf-8") as handle:
    service_template = yaml.load(handle, Loader=CfnLoader)

resources = template["Resources"]
params = template["Parameters"]
failures = []


def check(label, condition, detail=""):
    print(f"  {'✅' if condition else '❌'} {label}")
    if not condition:
        failures.append(f"{label} {detail}".strip())


# --- ScalableTarget ---------------------------------------------------------
target = resources["ServiceScalableTarget"]["Properties"]
check("ServiceNamespace = ecs", target["ServiceNamespace"] == "ecs")
check(
    "ScalableDimension = ecs:service:DesiredCount",
    target["ScalableDimension"] == "ecs:service:DesiredCount",
)

# ResourceId doit être un Fn::Sub de la forme service/<cluster>/<service>,
# construit depuis des ImportValue — jamais un nom en dur.
sub = target["ResourceId"]["Fn::Sub"]
pattern, variables = sub[0], sub[1]
check("ResourceId au format 'service/<cluster>/<service>'",
      pattern == "service/${ClusterName}/${ServiceName}", f"-> {pattern!r}")
check("cluster et service viennent d'un ImportValue (aucun nom en dur)",
      all("Fn::ImportValue" in value for value in variables.values()))

# --- ScalingPolicy ---------------------------------------------------------
policy = resources["CpuTargetTrackingPolicy"]["Properties"]
config = policy["TargetTrackingScalingPolicyConfiguration"]
check("PolicyType = TargetTrackingScaling", policy["PolicyType"] == "TargetTrackingScaling")
check(
    "métrique prédéfinie = ECSServiceAverageCPUUtilization",
    config["PredefinedMetricSpecification"]["PredefinedMetricType"]
    == "ECSServiceAverageCPUUtilization",
)
check("scale-in ACTIVÉ (F3 : 'augmente ou diminue')", config["DisableScaleIn"] is False)
check(
    "la policy cible bien le ScalableTarget de ce template",
    policy["ScalingTargetId"] == {"Fn::Ref": "ServiceScalableTarget"},
)

# --- Cohérence des valeurs par défaut --------------------------------------
target_cpu = params["TargetCpuUtilization"]["Default"]
alarm_cpu = params["HighCpuAlarmThreshold"]["Default"]
min_cap = params["MinCapacity"]["Default"]
max_cap = params["MaxCapacity"]["Default"]

print(f"\n  cible CPU = {target_cpu}%   seuil d'alarme = {alarm_cpu}%   capacité = {min_cap}-{max_cap}")
check("cible CPU = 70 % (valeur demandée par le CDC)", target_cpu == 70)
check("seuil d'alarme STRICTEMENT au-dessus de la cible", alarm_cpu > target_cpu,
      "sinon l'alarme se déclenche alors que l'auto scaling fait son travail")
check("MaxCapacity > MinCapacity (il y a une marge pour scaler)", max_cap > min_cap)
check(
    "scale-in plus lent que scale-out (anti-flapping)",
    params["ScaleInCooldown"]["Default"] > params["ScaleOutCooldown"]["Default"],
)

# MinCapacity doit être cohérent avec le DesiredCount initial du service,
# sinon Application Auto Scaling corrige dès la première évaluation.
desired = service_template["Parameters"]["DesiredCount"]["Default"]
check(f"MinCapacity ({min_cap}) <= DesiredCount de ecs-service.yaml ({desired})",
      min_cap <= desired)

# --- Alarmes ---------------------------------------------------------------
alarms = {name: res["Properties"] for name, res in resources.items()
          if res["Type"] == "AWS::CloudWatch::Alarm"}
check("2 alarmes CloudWatch déclarées", len(alarms) == 2, f"-> {len(alarms)}")

for name, alarm in alarms.items():
    check(f"{name} notifie le topic SNS du pipeline",
          any("pipeline-notifications-arn" in str(action) for action in alarm["AlarmActions"]))
    # Un service pas encore démarré n'émet aucune donnée : l'alarme ne doit
    # pas se déclencher pour autant.
    check(f"{name} : TreatMissingData = notBreaching",
          alarm.get("TreatMissingData") == "notBreaching")

cpu_alarm = alarms["ServiceHighCpuAlarm"]
check("alarme CPU sur AWS/ECS CPUUtilization",
      (cpu_alarm["Namespace"], cpu_alarm["MetricName"]) == ("AWS/ECS", "CPUUtilization"))
capacity_alarm = alarms["ServiceMaxCapacityAlarm"]
check("alarme capacité sur ECS/ContainerInsights RunningTaskCount",
      (capacity_alarm["Namespace"], capacity_alarm["MetricName"])
      == ("ECS/ContainerInsights", "RunningTaskCount"))

# --- Exports ---------------------------------------------------------------
exports = {
    output["Export"]["Name"]["Fn::Sub"]
    for output in template["Outputs"].values()
    if "Export" in output
}
attendus = {
    "${ProjectName}-${Environment}-ecs-scalable-target-id",
    "${ProjectName}-${Environment}-ecs-cpu-policy-arn",
    "${ProjectName}-${Environment}-ecs-capacity-range",
}
check("les 3 exports attendus sont présents", attendus <= exports,
      f"manquants: {sorted(attendus - exports)}")

if failures:
    print("\n❌ Vérifications en échec :")
    for failure in failures:
        print("   -", failure)
    sys.exit(1)
print("\n✅ Toutes les vérifications structurelles passent")
PY
echo ""

echo "──────────────────────────────────────────────"
echo "3) Cohérence avec Container Insights"
echo "   L'alarme de capacité lit ECS/ContainerInsights :"
echo "   sans Container Insights activé sur le cluster,"
echo "   elle resterait en INSUFFICIENT_DATA."
echo "──────────────────────────────────────────────"
if grep -q 'containerInsights' ../cloudformation/ecs-cluster.yaml; then
  grep -n -A1 'ClusterSettings' ../cloudformation/ecs-cluster.yaml
  echo "✅ Container Insights est bien activé sur le cluster"
else
  echo "❌ Container Insights introuvable dans ecs-cluster.yaml"
  exit 1
fi
echo ""

echo "──────────────────────────────────────────────"
echo "Résumé"
echo "──────────────────────────────────────────────"
echo "✅ ecs-autoscaling.yaml valide (cfn-lint)"
echo "✅ ScalableTarget correctement formé (ecs:service:DesiredCount, ResourceId sans valeur en dur)"
echo "✅ Target Tracking CPU à 70 %, scale-in activé, cooldowns cohérents"
echo "✅ 2 alarmes CloudWatch câblées au topic SNS, tolérantes aux données absentes"
echo "✅ Bornes de capacité cohérentes avec le DesiredCount de ecs-service.yaml"
echo ""
echo "ℹ️  NON testable en local : le scaling réel. Ni"
echo "   'application-autoscaling' ni 'ecs' ne sont émulés par LocalStack"
echo "   Community (cf. Test 5). Il faudra, sur un vrai compte AWS : générer de"
echo "   la charge CPU, puis vérifier via 'aws application-autoscaling"
echo "   describe-scaling-activities' que le nombre de tâches monte puis"
echo "   redescend."
