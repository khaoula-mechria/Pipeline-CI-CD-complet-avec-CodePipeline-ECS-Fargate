"""Tests du garde-fou humain (hors ligne, aucun appel AWS ni LLM).

Lancer : python -m pytest explainer/ -v

Ces tests portent sur la contrainte non negociable du projet : rien ne doit
pouvoir modifier l'infrastructure sans un accord humain explicite.
"""

from __future__ import annotations

import pytest

from .apply import apply_recommendation, check_applicable, confirm
from .prompt import build_messages


def make_report(source="cloudwatch", action="reduce_task_count", current=2, recommended=1):
    return {
        "metrics": {
            "service_name": "taskmanager-dev-service",
            "cluster_name": "taskmanager-dev-cluster",
            "window_days": 14,
            "source": source,
            "cpu": {"average": 11.4, "maximum": 38.2, "datapoints": 4032},
            "memory": {"average": 26.8, "maximum": 41.5, "datapoints": 4032},
            "desired_count": current,
            "task_cpu_units": 256,
            "task_memory_mb": 512,
        },
        "house": {
            "action": action,
            "finding": "Overprovisioned",
            "current_desired_count": current,
            "recommended_desired_count": recommended,
            "monthly_saving_usd": 10.36,
            "confidence": "high",
            "rationale": "Utilisation sous le seuil.",
            "thresholds": {
                "low_utilization_pct": 40.0,
                "safety_ceiling_pct": 70.0,
                "min_capacity": 1,
            },
        },
        "aws": {"available": False, "unavailable_reason": "opt-in requis"},
        "agreement": "aws_indisponible",
        "delta_cost_usd": None,
        "delta_risk": "non comparable",
        "notes": [],
    }


class Recorder:
    """Capture la sortie CLI sans l'afficher."""

    def __init__(self):
        self.lines = []

    def __call__(self, *args):
        self.lines.append(" ".join(str(a) for a in args))

    @property
    def text(self):
        return "\n".join(self.lines)


def test_un_refus_nappelle_pas_aws():
    """Repondre "n" doit stopper avant tout appel boto3."""
    log = Recorder()
    decision = apply_recommendation(
        make_report(), prompt_input=lambda _: "n", log=log
    )
    assert decision.applied is False
    assert "Refuse par l'operateur" in decision.reason


@pytest.mark.parametrize("answer", ["", "non", "N", "peut-etre", "yes please", "1", "oui!"])
def test_toute_reponse_ambigue_vaut_refus(answer):
    """Seuls o/oui/y/yes valent accord ; le reste refuse."""
    assert confirm(prompt_input=lambda _: answer, log=Recorder()) is False


@pytest.mark.parametrize("answer", ["o", "oui", "y", "yes", "  OUI  ", "Y"])
def test_les_accords_explicites_sont_reconnus(answer):
    assert confirm(prompt_input=lambda _: answer, log=Recorder()) is True


def test_une_interruption_vaut_refus():
    """Ctrl+C / EOF ne doit jamais etre interprete comme un accord."""
    def interrupt(_):
        raise KeyboardInterrupt

    assert confirm(prompt_input=interrupt, log=Recorder()) is False


def test_les_donnees_dexemple_ne_peuvent_pas_etre_appliquees():
    """Garde-fou : pas de modification reelle sur des metriques fictives."""
    applicable, reason = check_applicable(make_report(source="sample"))
    assert applicable is False
    assert "EXEMPLE" in reason


def test_rien_a_appliquer_quand_la_regle_ne_propose_rien():
    applicable, reason = check_applicable(make_report(action="none"))
    assert applicable is False
    assert "Aucune action" in reason


def test_une_cible_identique_est_refusee():
    applicable, _ = check_applicable(make_report(current=2, recommended=2))
    assert applicable is False


def test_une_cible_a_zero_tache_est_refusee():
    applicable, reason = check_applicable(make_report(current=2, recommended=0))
    assert applicable is False
    assert "invalide" in reason


def test_le_recapitulatif_precede_la_question():
    """L'operateur doit voir ce qu'il valide avant de repondre."""
    log = Recorder()
    seen = {}

    def prompt_input(question):
        seen["log_avant_question"] = log.text
        seen["question"] = question
        return "n"

    apply_recommendation(make_report(), prompt_input=prompt_input, log=log)

    assert "VALIDATION HUMAINE REQUISE" in seen["log_avant_question"]
    assert "DesiredCount 2 -> 1" in seen["log_avant_question"]
    assert "[o/N]" in seen["question"]


def test_le_risque_de_tache_unique_est_affiche_avant_validation():
    log = Recorder()
    apply_recommendation(make_report(recommended=1), prompt_input=lambda _: "n", log=log)
    assert "redondance" in log.text


def test_le_prompt_llm_ne_demande_aucune_decision():
    """Le LLM explique ; il ne doit pas se voir demander de decider."""
    from .prompt import SYSTEM_PROMPT

    assert "tu ne prends aucune decision" in SYSTEM_PROMPT.lower()
    assert "validera" in SYSTEM_PROMPT.lower()


def test_le_prompt_contient_les_chiffres_du_rapport():
    """Le modele doit recevoir les mesures, pas les inventer."""
    content = build_messages(make_report())[0]["content"]
    assert "11.4%" in content
    assert "taskmanager-dev-service" in content
    assert "Plafond de securite : 70.0%" in content


def test_le_prompt_signale_les_donnees_dexemple():
    content = build_messages(make_report(source="sample"))[0]["content"]
    assert "sample" in content
