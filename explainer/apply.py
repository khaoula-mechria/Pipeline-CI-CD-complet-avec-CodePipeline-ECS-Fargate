"""Application d'une recommandation, sous validation humaine explicite.

Regle non negociable du projet : aucune auto-remediation. Rien n'est applique
sans un "o"/"y" tape par un humain, dans la meme logique que le ManualApproval
deja present dans le pipeline CodePipeline.

L'analyse (module 2) et l'explication (module 3) ne declenchent JAMAIS d'ecriture.
Seule la commande `apply`, avec le drapeau --apply, peut modifier ECS.
"""

from __future__ import annotations

from dataclasses import dataclass

import boto3
from botocore.exceptions import BotoCoreError, ClientError

# Reponses acceptees comme un accord explicite (francais et anglais).
CONFIRMATIONS = {"o", "oui", "y", "yes"}


@dataclass
class ApplyDecision:
    """Resultat d'une tentative d'application."""

    applied: bool
    reason: str
    previous_desired_count: int | None = None
    new_desired_count: int | None = None

    def to_json(self) -> dict:
        return {
            "applied": self.applied,
            "reason": self.reason,
            "previous_desired_count": self.previous_desired_count,
            "new_desired_count": self.new_desired_count,
        }


def check_applicable(report: dict) -> tuple[bool, str]:
    """Verifie qu'il y a quelque chose de sur a appliquer. Aucun appel AWS."""
    metrics = report.get("metrics", {})
    house = report.get("house", {})

    if metrics.get("source") == "sample":
        return False, (
            "Le rapport repose sur des metriques d'EXEMPLE (--sample). "
            "Appliquer une modification a partir de donnees fictives est refuse."
        )

    if house.get("action") != "reduce_task_count":
        return False, (
            f"Aucune action a appliquer (action = {house.get('action')!r}, "
            f"verdict = {house.get('finding')!r})."
        )

    current = house.get("current_desired_count")
    recommended = house.get("recommended_desired_count")
    if current is None or recommended is None:
        return False, "Nombre de taches courant ou recommande inconnu."
    if recommended == current:
        return False, "La recommandation est identique a la configuration actuelle."
    if recommended < 1:
        return False, f"Cible invalide ({recommended} tache)."

    return True, f"Passage de {current} a {recommended} tache(s)."


def render_confirmation(report: dict) -> str:
    """Recapitulatif affiche AVANT de demander l'accord humain."""
    metrics = report.get("metrics", {})
    house = report.get("house", {})

    lines = [
        "",
        "  " + "=" * 68,
        "  MODIFICATION D'INFRASTRUCTURE — VALIDATION HUMAINE REQUISE",
        "  " + "=" * 68,
        f"  Service        : {metrics.get('service_name')}",
        f"  Cluster        : {metrics.get('cluster_name')}",
        f"  Changement     : DesiredCount {house.get('current_desired_count')} "
        f"-> {house.get('recommended_desired_count')}",
        f"  Economie       : ${house.get('monthly_saving_usd')} / mois (estimation)",
        f"  Confiance      : {house.get('confidence')}",
        f"  Base de calcul : {metrics.get('window_days')} jours de metriques "
        f"({metrics.get('cpu', {}).get('datapoints', 0)} points)",
    ]

    if house.get("recommended_desired_count") == 1:
        lines += [
            "",
            "  ATTENTION : passer a une seule tache supprime la redondance",
            "  multi-AZ. Toute interruption de cette tache coupe le service",
            "  jusqu'a son remplacement.",
        ]

    lines += [
        "",
        "  Cette action modifie l'infrastructure AWS reelle.",
        "  " + "=" * 68,
    ]
    return "\n".join(lines)


def confirm(prompt_input=input, log=print) -> bool:
    """Demande l'accord humain. Tout ce qui n'est pas o/oui/y/yes vaut refus."""
    try:
        answer = prompt_input("  Appliquer cette modification ? [o/N] ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        log("\n  Interrompu : aucune modification appliquee.")
        return False

    if answer in CONFIRMATIONS:
        return True

    log("  Refuse : aucune modification appliquee.")
    return False


def apply_recommendation(
    report: dict,
    region: str = "eu-west-2",
    profile: str | None = None,
    prompt_input=input,
    log=print,
) -> ApplyDecision:
    """Applique la recommandation apres confirmation humaine explicite."""
    applicable, reason = check_applicable(report)
    if not applicable:
        log(f"  {reason}")
        return ApplyDecision(applied=False, reason=reason)

    log(render_confirmation(report))

    if not confirm(prompt_input=prompt_input, log=log):
        return ApplyDecision(
            applied=False, reason="Refuse par l'operateur (pas de confirmation)."
        )

    metrics = report["metrics"]
    house = report["house"]
    current = house["current_desired_count"]
    target = house["recommended_desired_count"]

    session = boto3.Session(profile_name=profile) if profile else boto3.Session()
    ecs = session.client("ecs", region_name=region)

    try:
        ecs.update_service(
            cluster=metrics["cluster_name"],
            service=metrics["service_name"],
            desiredCount=target,
        )
    except (ClientError, BotoCoreError) as exc:
        message = f"Appel update_service en echec : {exc}"
        log(f"  {message}")
        return ApplyDecision(
            applied=False, reason=message, previous_desired_count=current
        )

    log(f"  Applique : DesiredCount {current} -> {target} sur {metrics['service_name']}.")
    log("  Verifier le deploiement : aws ecs describe-services --cluster "
        f"{metrics['cluster_name']} --services {metrics['service_name']} --region {region}")

    return ApplyDecision(
        applied=True,
        reason=f"Applique apres confirmation humaine : {current} -> {target} tache(s).",
        previous_desired_count=current,
        new_desired_count=target,
    )
