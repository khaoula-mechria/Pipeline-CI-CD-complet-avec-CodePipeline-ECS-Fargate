"""Construction du prompt a partir du rapport JSON du module 2.

Le LLM sert uniquement a EXPLIQUER une recommandation deja calculee par des
regles deterministes. Il ne decide rien, ne recalcule rien, et n'a aucun acces
a l'infrastructure.
"""

from __future__ import annotations

import json

SYSTEM_PROMPT = """Tu expliques des recommandations de dimensionnement d'infrastructure AWS a une personne qui ne connait ni CloudWatch ni ECS.

Contexte : une application Node.js tourne sur AWS ECS Fargate. Un outil a mesure son utilisation reelle et propose un ajustement. Ton role est d'expliquer POURQUOI cette proposition existe.

Regles :
- Tu expliques une analyse, tu ne prends aucune decision. Ne dis jamais "il faut appliquer" ni "je recommande d'appliquer" : dis ce que l'analyse observe et ce qui en decoule.
- Une personne humaine validera ou refusera. Rappelle-le en une phrase a la fin.
- Explique les termes techniques que tu emploies (une tache, l'utilisation CPU, un seuil).
- N'invente aucun chiffre. Utilise uniquement ceux du rapport. Si une donnee manque, dis qu'elle manque.
- Si le rapport signale des metriques d'exemple, dis-le explicitement des la premiere phrase.
- Signale honnetement les limites : niveau de confiance, risques, et le fait que la regle maison et AWS Compute Optimizer ne regardent pas le meme levier.

Structure ta reponse en quatre parties courtes, avec ces titres exacts :

**Ce qui a ete observe**
Ce que les mesures montrent, en langage simple.

**Pourquoi cette proposition**
Le seuil concerne, atteint ou non, et le raisonnement.

**Ce que ca changerait**
Impact attendu : cout, performance, disponibilite.

**Ce qu'il faut garder en tete**
Niveau de confiance, limites, risques, comparaison avec l'avis d'AWS.

Ecris en francais, environ 300 mots, sans jargon inutile."""


def _summarize(report: dict) -> str:
    """Resume lisible du rapport, pour eviter de noyer le modele dans le JSON brut."""
    metrics = report.get("metrics", {})
    house = report.get("house", {})
    aws = report.get("aws", {})
    cpu = metrics.get("cpu", {})
    memory = metrics.get("memory", {})

    def fmt(value, suffix=""):
        return "inconnu" if value is None else f"{value}{suffix}"

    lines = [
        "MESURES",
        f"- Service : {metrics.get('service_name')} (cluster {metrics.get('cluster_name')})",
        f"- Source des donnees : {metrics.get('source')}",
        f"- Fenetre observee : {metrics.get('window_days')} jours, "
        f"{cpu.get('datapoints', 0)} points de mesure",
        f"- CPU : {fmt(cpu.get('average'), '%')} en moyenne, "
        f"pic a {fmt(cpu.get('maximum'), '%')}",
        f"- Memoire : {fmt(memory.get('average'), '%')} en moyenne, "
        f"pic a {fmt(memory.get('maximum'), '%')}",
        f"- Taches en service : {fmt(metrics.get('desired_count'))} "
        f"(taille : {fmt(metrics.get('task_cpu_units'))} unites CPU / "
        f"{fmt(metrics.get('task_memory_mb'))} Mo)",
    ]
    if metrics.get("note"):
        lines.append(f"- Remarque sur les donnees : {metrics['note']}")

    thresholds = house.get("thresholds", {})
    lines += [
        "",
        "PROPOSITION DE LA REGLE MAISON (levier : nombre de taches)",
        f"- Verdict : {house.get('finding')}",
        f"- Action proposee : {house.get('action')}",
        f"- Nombre de taches : {fmt(house.get('current_desired_count'))} "
        f"-> {fmt(house.get('recommended_desired_count'))}",
        f"- Utilisation projetee apres changement : "
        f"CPU {fmt(house.get('projected_cpu_pct'), '%')}, "
        f"memoire {fmt(house.get('projected_memory_pct'), '%')}",
        f"- Seuil de sous-utilisation : {thresholds.get('low_utilization_pct')}%",
        f"- Plafond de securite : {thresholds.get('safety_ceiling_pct')}%",
        f"- Plancher de taches : {thresholds.get('min_capacity')}",
        f"- Cout mensuel : ${fmt(house.get('monthly_cost_current_usd'))} "
        f"-> ${fmt(house.get('monthly_cost_recommended_usd'))} "
        f"(economie ${fmt(house.get('monthly_saving_usd'))})",
        f"- Niveau de confiance : {house.get('confidence')}",
        f"- Motif calcule : {house.get('rationale')}",
    ]

    lines += ["", "AVIS D'AWS COMPUTE OPTIMIZER (levier : taille de tache)"]
    if aws.get("available"):
        lines += [
            f"- Verdict : {aws.get('finding')}",
            f"- Taille actuelle : {fmt(aws.get('current_cpu_units'))} CPU / "
            f"{fmt(aws.get('current_memory_mb'))} Mo",
            f"- Taille proposee : {fmt(aws.get('recommended_cpu_units'))} CPU / "
            f"{fmt(aws.get('recommended_memory_mb'))} Mo",
            f"- Economie estimee par AWS : ${fmt(aws.get('estimated_monthly_saving_usd'))}",
        ]
    else:
        lines.append(f"- Indisponible : {aws.get('unavailable_reason')}")

    lines += [
        "",
        "COMPARAISON",
        f"- Accord entre les deux : {report.get('agreement')}",
        f"- Ecart de cout : {fmt(report.get('delta_cost_usd'), ' USD/mois')}",
        f"- Ecart de risque : {report.get('delta_risk')}",
    ]
    for note in report.get("notes", []):
        lines.append(f"- Remarque : {note}")

    return "\n".join(lines)


def build_messages(report: dict, include_raw_json: bool = False) -> list[dict]:
    """Messages prets pour l'API Anthropic."""
    content = [
        "Voici le rapport d'analyse a expliquer.",
        "",
        _summarize(report),
    ]
    if include_raw_json:
        content += ["", "Rapport JSON complet :", "```json", json.dumps(report, indent=2, ensure_ascii=False), "```"]

    return [{"role": "user", "content": "\n".join(content)}]
