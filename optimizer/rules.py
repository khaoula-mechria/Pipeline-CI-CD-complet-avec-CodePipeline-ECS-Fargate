"""Regle de rightsizing "maison" : explicite, seuils configurables, pas de ML.

Levier utilise : le NOMBRE DE TACHES desirees (`DesiredCount` de ecs-service.yaml).
C'est le seul levier que ce projet peut actionner sans remplacer la task
definition, et il est borne par `MinCapacity` de ecs-autoscaling.yaml.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

from .metrics import ServiceMetrics

# --- Seuils par defaut (tous surchargables en CLI) -------------------------

# En dessous de ce taux d'utilisation moyen, la capacite est jugee sur-provisionnee.
DEFAULT_LOW_UTILIZATION_PCT = 40.0
# Utilisation projetee a ne pas depasser apres reduction : garde-fou anti-saturation.
DEFAULT_SAFETY_CEILING_PCT = 70.0
# Nombre minimum de datapoints pour considerer la fenetre representative.
DEFAULT_MIN_DATAPOINTS = 12

# Prix Fargate Linux/x86 a la demande, region eu-west-2 (Londres), en USD.
# Tarif public liste ; a reajuster si AWS change sa grille ou si la region change.
FARGATE_PRICING = {
    "eu-west-2": {"vcpu_hour": 0.04656, "gb_hour": 0.00511},
    "eu-west-1": {"vcpu_hour": 0.04456, "gb_hour": 0.00489},
    "us-east-1": {"vcpu_hour": 0.04048, "gb_hour": 0.004445},
}
HOURS_PER_MONTH = 730


@dataclass
class Recommendation:
    """Recommandation maison, toujours soumise a validation humaine."""

    action: str  # "reduce_task_count" | "none"
    finding: str  # "Overprovisioned" | "Optimized" | "Unknown"
    current_desired_count: int | None
    recommended_desired_count: int | None
    rationale: str
    confidence: str  # "low" | "medium" | "high"
    observed_cpu_pct: float | None
    observed_memory_pct: float | None
    projected_cpu_pct: float | None
    projected_memory_pct: float | None
    monthly_cost_current_usd: float | None
    monthly_cost_recommended_usd: float | None
    monthly_saving_usd: float | None
    thresholds: dict
    lever: str = "task_count"

    def to_json(self) -> dict:
        return asdict(self)


def task_hourly_cost(cpu_units: int | None, memory_mb: int | None, region: str) -> float | None:
    """Cout horaire d'UNE tache Fargate, d'apres sa taille declaree."""
    pricing = FARGATE_PRICING.get(region)
    if not pricing or not cpu_units or not memory_mb:
        return None
    vcpu = cpu_units / 1024
    gb = memory_mb / 1024
    return vcpu * pricing["vcpu_hour"] + gb * pricing["gb_hour"]


def evaluate(
    metrics: ServiceMetrics,
    region: str = "eu-west-2",
    low_utilization_pct: float = DEFAULT_LOW_UTILIZATION_PCT,
    safety_ceiling_pct: float = DEFAULT_SAFETY_CEILING_PCT,
    min_capacity: int = 1,
    min_datapoints: int = DEFAULT_MIN_DATAPOINTS,
) -> Recommendation:
    """Applique la regle de rightsizing aux metriques observees."""
    thresholds = {
        "low_utilization_pct": low_utilization_pct,
        "safety_ceiling_pct": safety_ceiling_pct,
        "min_capacity": min_capacity,
        "min_datapoints": min_datapoints,
    }

    cpu = metrics.cpu.average
    memory = metrics.memory.average
    current = metrics.desired_count

    hourly = task_hourly_cost(metrics.task_cpu_units, metrics.task_memory_mb, region)
    cost_current = round(hourly * current * HOURS_PER_MONTH, 2) if hourly and current else None

    def build(action, finding, recommended, rationale, confidence, projected_cpu, projected_mem):
        cost_reco = (
            round(hourly * recommended * HOURS_PER_MONTH, 2) if hourly and recommended else None
        )
        saving = (
            round(cost_current - cost_reco, 2)
            if cost_current is not None and cost_reco is not None
            else None
        )
        return Recommendation(
            action=action,
            finding=finding,
            current_desired_count=current,
            recommended_desired_count=recommended,
            rationale=rationale,
            confidence=confidence,
            observed_cpu_pct=cpu,
            observed_memory_pct=memory,
            projected_cpu_pct=projected_cpu,
            projected_memory_pct=projected_mem,
            monthly_cost_current_usd=cost_current,
            monthly_cost_recommended_usd=cost_reco,
            monthly_saving_usd=saving,
            thresholds=thresholds,
        )

    # --- Cas ou la regle refuse de se prononcer ---------------------------
    if not metrics.has_data:
        return build(
            "none", "Unknown", current,
            metrics.note or "Aucune metrique CloudWatch exploitable sur la fenetre.",
            "low", None, None,
        )

    if metrics.cpu.datapoints < min_datapoints:
        return build(
            "none", "Unknown", current,
            f"Fenetre trop courte : {metrics.cpu.datapoints} datapoints "
            f"(minimum {min_datapoints}). Mesure non representative.",
            "low", None, None,
        )

    if current is None:
        return build(
            "none", "Unknown", None,
            "Nombre de taches desirees inconnu (service introuvable).", "low", None, None,
        )

    # --- Regle principale --------------------------------------------------
    driver = max(cpu, memory)
    driver_name = "CPU" if cpu >= memory else "memoire"

    if driver >= low_utilization_pct:
        return build(
            "none", "Optimized", current,
            f"Utilisation {driver_name} moyenne {driver:.1f}% >= seuil "
            f"{low_utilization_pct:.0f}% : pas de sur-provisionnement detecte.",
            "medium", cpu, memory,
        )

    if current <= min_capacity:
        return build(
            "none", "Overprovisioned", current,
            f"Utilisation {driver_name} moyenne {driver:.1f}% < seuil "
            f"{low_utilization_pct:.0f}%, mais le service est deja au minimum "
            f"({min_capacity} tache). Reduire davantage exigerait de changer la "
            f"taille de tache, hors du levier de cette regle.",
            "medium", cpu, memory,
        )

    # L'utilisation par tache augmente a mesure que l'on retire des taches :
    # a charge totale constante, util_projetee = util_actuelle * (n / n_cible).
    recommended = current
    for candidate in range(current - 1, min_capacity - 1, -1):
        factor = current / candidate
        if max(cpu * factor, memory * factor) <= safety_ceiling_pct:
            recommended = candidate
        else:
            break

    if recommended == current:
        return build(
            "none", "Overprovisioned", current,
            f"Utilisation {driver_name} moyenne {driver:.1f}% < seuil "
            f"{low_utilization_pct:.0f}%, mais retirer une tache porterait "
            f"l'utilisation projetee au-dela du plafond de securite "
            f"{safety_ceiling_pct:.0f}%.",
            "medium", cpu, memory,
        )

    factor = current / recommended
    projected_cpu = round(cpu * factor, 2)
    projected_memory = round(memory * factor, 2)

    # Confiance : plus la fenetre est longue et la marge large, plus elle est haute.
    margin = safety_ceiling_pct - max(projected_cpu, projected_memory)
    if metrics.window_days >= 14 and margin >= 15:
        confidence = "high"
    elif metrics.window_days >= 7 or margin >= 10:
        confidence = "medium"
    else:
        confidence = "low"

    return build(
        "reduce_task_count", "Overprovisioned", recommended,
        f"Utilisation {driver_name} moyenne {driver:.1f}% sur {metrics.window_days} jours, "
        f"sous le seuil de {low_utilization_pct:.0f}%. Passer de {current} a {recommended} "
        f"tache(s) porterait l'utilisation projetee a {max(projected_cpu, projected_memory):.1f}%, "
        f"sous le plafond de securite de {safety_ceiling_pct:.0f}%.",
        confidence, projected_cpu, projected_memory,
    )
