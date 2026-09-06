"""Comparaison recommandation maison vs AWS Compute Optimizer.

Le but n'est PAS de montrer que la regle maison fait mieux, mais de rendre les
deux avis lisibles cote a cote, y compris quand ils ne portent pas sur le meme
levier ou quand AWS ne se prononce pas.

Point important : les deux outils n'actionnent pas le meme levier.
  - la regle maison ajuste le NOMBRE de taches (DesiredCount) ;
  - Compute Optimizer recommande la TAILLE de tache (CPU/memoire).
Un ecart de recommandation n'est donc pas forcement un desaccord : le tableau
affiche explicitement la colonne "levier" pour eviter cette confusion.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from .metrics import ServiceMetrics
from .rules import Recommendation, HOURS_PER_MONTH, task_hourly_cost


@dataclass
class AwsRecommendation:
    """Avis d'AWS Compute Optimizer, ou la raison de son absence."""

    available: bool
    finding: str | None = None
    finding_reasons: list | None = None
    current_cpu_units: int | None = None
    current_memory_mb: int | None = None
    recommended_cpu_units: int | None = None
    recommended_memory_mb: int | None = None
    estimated_monthly_saving_usd: float | None = None
    lever: str = "task_size"
    unavailable_reason: str | None = None

    def to_json(self) -> dict:
        return asdict(self)


def fetch_aws_recommendation(
    service_arn: str | None, region: str = "eu-west-2", profile: str | None = None
) -> AwsRecommendation:
    """Appelle compute_optimizer.get_ecs_service_recommendations()."""
    if not service_arn:
        return AwsRecommendation(
            available=False,
            unavailable_reason=(
                "ARN du service ECS inconnu : le service n'est pas deploye, "
                "Compute Optimizer ne peut pas etre interroge."
            ),
        )

    session = boto3.Session(profile_name=profile) if profile else boto3.Session()
    client = session.client("compute-optimizer", region_name=region)

    try:
        response = client.get_ecs_service_recommendations(serviceArns=[service_arn])
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code in {"OptInRequiredException", "AccessDeniedException"}:
            reason = (
                "Compte non inscrit a AWS Compute Optimizer (opt-in requis) ou "
                "permission manquante. Activer le service puis attendre la periode "
                "d'analyse (jusqu'a 14 jours de metriques)."
            )
        else:
            reason = f"Appel Compute Optimizer en echec ({code})."
        return AwsRecommendation(available=False, unavailable_reason=reason)
    except BotoCoreError as exc:
        return AwsRecommendation(available=False, unavailable_reason=f"Erreur reseau/SDK : {exc}")

    recommendations = response.get("ecsServiceRecommendations", [])
    if not recommendations:
        errors = response.get("errors", [])
        detail = errors[0].get("message") if errors else None
        return AwsRecommendation(
            available=False,
            unavailable_reason=(
                detail
                or "Compute Optimizer n'a pas encore de recommandation pour ce service "
                "(il lui faut environ 14 jours de metriques continues)."
            ),
        )

    recommendation = recommendations[0]
    options = recommendation.get("serviceRecommendationOptions", [])
    best = options[0] if options else {}
    savings = (best.get("savingsOpportunity") or {}).get("estimatedMonthlySavings", {})

    return AwsRecommendation(
        available=True,
        finding=recommendation.get("finding"),
        finding_reasons=recommendation.get("findingReasonCodes") or [],
        current_cpu_units=recommendation.get("currentServiceConfiguration", {}).get("cpu"),
        current_memory_mb=recommendation.get("currentServiceConfiguration", {}).get("memory"),
        recommended_cpu_units=best.get("cpu"),
        recommended_memory_mb=best.get("memory"),
        estimated_monthly_saving_usd=savings.get("value"),
    )


@dataclass
class Comparison:
    metrics: dict
    house: dict
    aws: dict
    agreement: str
    delta_cost_usd: float | None
    delta_risk: str
    notes: list

    def to_json(self) -> dict:
        return asdict(self)


def _aws_saving_usd(
    aws: AwsRecommendation, metrics: ServiceMetrics, region: str
) -> float | None:
    """Economie AWS, recalculee depuis la taille de tache si AWS ne la chiffre pas."""
    if aws.estimated_monthly_saving_usd is not None:
        return round(aws.estimated_monthly_saving_usd, 2)
    if not aws.available or not metrics.desired_count:
        return None
    current = task_hourly_cost(aws.current_cpu_units, aws.current_memory_mb, region)
    proposed = task_hourly_cost(aws.recommended_cpu_units, aws.recommended_memory_mb, region)
    if current is None or proposed is None:
        return None
    return round((current - proposed) * metrics.desired_count * HOURS_PER_MONTH, 2)


def compare(
    metrics: ServiceMetrics,
    house: Recommendation,
    aws: AwsRecommendation,
    region: str = "eu-west-2",
) -> Comparison:
    """Construit le tableau comparatif des deux avis."""
    notes: list[str] = []
    aws_saving = _aws_saving_usd(aws, metrics, region)

    if metrics.source == "sample":
        notes.append(
            "Metriques d'EXEMPLE (--sample) : chiffres illustratifs, pas des mesures reelles."
        )

    # Risque porte par la recommandation maison elle-meme, independamment de la
    # disponibilite de l'avis AWS : passer a une seule tache supprime la
    # redondance entre AZ, quel que soit ce qu'AWS en pense.
    single_task = (
        house.action == "reduce_task_count" and house.recommended_desired_count == 1
    )
    if single_task:
        notes.append(
            "La cible d'une seule tache supprime la redondance multi-AZ : toute "
            "interruption de cette tache coupe le service jusqu'au remplacement."
        )

    if not aws.available:
        agreement = "aws_indisponible"
        delta_risk = (
            "non comparable ; cible maison a 1 tache = perte de redondance multi-AZ"
            if single_task
            else "non comparable"
        )
        notes.append(f"Compute Optimizer : {aws.unavailable_reason}")
        notes.append(
            "Sans avis AWS, la recommandation maison reste une proposition isolee : "
            "la validation humaine est d'autant plus necessaire."
        )
    else:
        house_acts = house.action != "none"
        aws_acts = (aws.finding or "").lower() in {"overprovisioned", "underprovisioned"}
        if house_acts and aws_acts:
            agreement = "accord"
            notes.append(
                "Les deux outils concluent a un sur/sous-provisionnement, mais sur des "
                "leviers differents (nombre de taches vs taille de tache) : les gains "
                "ne s'additionnent pas mecaniquement."
            )
        elif house_acts != aws_acts:
            agreement = "desaccord"
            notes.append(
                "Un seul des deux outils propose un changement. Ecart attendu : la regle "
                "maison ne regarde que la moyenne d'utilisation sur la fenetre, la ou "
                "Compute Optimizer integre aussi les pics et l'historique long."
            )
        else:
            agreement = "accord"
            notes.append("Les deux outils jugent la configuration actuelle adaptee.")

        # Risque percu : reduire le nombre de taches touche a la disponibilite
        # (moins de taches = moins de redondance entre AZ), reduire la taille de
        # tache touche a la performance unitaire.
        if single_task:
            delta_risk = "maison plus risquee (1 seule tache : plus de redondance multi-AZ)"
        elif house_acts and not aws_acts:
            delta_risk = "maison plus agressive (AWS ne recommande aucun changement)"
        elif aws_acts and not house_acts:
            delta_risk = "AWS plus agressive (la regle maison ne se prononce pas)"
        else:
            delta_risk = "comparable"

    delta_cost = None
    if house.monthly_saving_usd is not None and aws_saving is not None:
        delta_cost = round(house.monthly_saving_usd - aws_saving, 2)

    return Comparison(
        metrics=metrics.to_json(),
        house=house.to_json(),
        aws=aws.to_json(),
        agreement=agreement,
        delta_cost_usd=delta_cost,
        delta_risk=delta_risk,
        notes=notes,
    )


def _fmt(value, suffix: str = "", dash: str = "-") -> str:
    if value is None:
        return dash
    if isinstance(value, float):
        return f"{value:.2f}{suffix}"
    return f"{value}{suffix}"


def render_table(comparison: Comparison) -> str:
    """Rend le tableau comparatif en texte pour la CLI."""
    house = comparison.house
    aws = comparison.aws
    metrics = comparison.metrics

    rows = [
        ("Levier", "nombre de taches", "taille de tache (CPU/memoire)"),
        ("Verdict", _fmt(house["finding"]), _fmt(aws["finding"], dash="indisponible")),
        (
            "Configuration actuelle",
            f"{_fmt(house['current_desired_count'])} tache(s)",
            f"{_fmt(aws['current_cpu_units'])} CPU / {_fmt(aws['current_memory_mb'])} Mo",
        ),
        (
            "Recommandation",
            f"{_fmt(house['recommended_desired_count'])} tache(s)",
            f"{_fmt(aws['recommended_cpu_units'])} CPU / {_fmt(aws['recommended_memory_mb'])} Mo",
        ),
        (
            "Economie mensuelle",
            f"${_fmt(house['monthly_saving_usd'])}",
            f"${_fmt(aws['estimated_monthly_saving_usd'])}",
        ),
        ("Confiance", _fmt(house["confidence"]), "n/a (modele AWS)"),
    ]

    width = max(len(label) for label, _, _ in rows)
    lines = [
        f"Service : {metrics['service_name']} (cluster {metrics['cluster_name']})",
        f"Fenetre : {metrics['window_days']} jours, source={metrics['source']}",
        f"Observe : CPU {_fmt(metrics['cpu']['average'], '%')} moyen "
        f"(max {_fmt(metrics['cpu']['maximum'], '%')}), "
        f"memoire {_fmt(metrics['memory']['average'], '%')} moyen "
        f"(max {_fmt(metrics['memory']['maximum'], '%')}), "
        f"{metrics['cpu']['datapoints']} datapoints",
        "",
        f"  {'':{width}} | {'Regle maison':<32} | AWS Compute Optimizer",
        f"  {'-' * width}-+-{'-' * 32}-+-{'-' * 32}",
    ]
    for label, left, right in rows:
        lines.append(f"  {label:{width}} | {left:<32} | {right}")

    lines.append("")
    lines.append(f"  Accord            : {comparison.agreement}")
    lines.append(f"  Delta cout        : {_fmt(comparison.delta_cost_usd, ' USD/mois')}")
    lines.append(f"  Delta risque      : {comparison.delta_risk}")
    lines.append("")
    lines.append(f"  Motif (maison)    : {house['rationale']}")

    if comparison.notes:
        lines.append("")
        lines.append("  Remarques :")
        for note in comparison.notes:
            lines.append(f"    - {note}")

    lines.append("")
    lines.append(
        "  Aucune modification n'a ete appliquee. Toute application passe par "
        "une validation humaine explicite (module 3, --apply)."
    )
    return "\n".join(lines)
