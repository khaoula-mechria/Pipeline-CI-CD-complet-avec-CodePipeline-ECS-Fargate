"""Tests de la regle de rightsizing (hors ligne, aucun appel AWS).

Lancer : python -m pytest optimizer/ -v
"""

from __future__ import annotations

import pytest

from .compare import AwsRecommendation, compare
from .metrics import MetricWindow, ServiceMetrics, load_sample
from .rules import evaluate, task_hourly_cost


def make_metrics(cpu_avg, mem_avg, desired=2, datapoints=4032, window_days=14):
    return ServiceMetrics(
        cluster_name="taskmanager-dev-cluster",
        service_name="taskmanager-dev-service",
        window_days=window_days,
        start="2026-08-23T09:00:00+00:00",
        end="2026-09-06T09:00:00+00:00",
        cpu=MetricWindow("CPUUtilization", cpu_avg, cpu_avg, cpu_avg, datapoints),
        memory=MetricWindow("MemoryUtilization", mem_avg, mem_avg, mem_avg, datapoints),
        desired_count=desired,
        running_count=desired,
        task_cpu_units=256,
        task_memory_mb=512,
    )


def test_service_sous_utilise_declenche_une_reduction():
    reco = evaluate(make_metrics(cpu_avg=10.0, mem_avg=20.0, desired=2))
    assert reco.action == "reduce_task_count"
    assert reco.recommended_desired_count == 1
    assert reco.monthly_saving_usd > 0


def test_service_charge_ne_declenche_rien():
    reco = evaluate(make_metrics(cpu_avg=65.0, mem_avg=50.0, desired=2))
    assert reco.action == "none"
    assert reco.finding == "Optimized"


def test_le_plafond_de_securite_bloque_une_reduction_trop_agressive():
    """40% sur 2 taches -> 80% sur 1 tache : au-dessus du plafond de 70%."""
    reco = evaluate(make_metrics(cpu_avg=39.0, mem_avg=39.0, desired=2))
    assert reco.action == "none"
    assert reco.finding == "Overprovisioned"
    assert "plafond de securite" in reco.rationale


def test_pas_de_reduction_sous_la_capacite_minimale():
    reco = evaluate(make_metrics(cpu_avg=5.0, mem_avg=5.0, desired=1), min_capacity=1)
    assert reco.action == "none"
    assert "deja au minimum" in reco.rationale


def test_fenetre_non_representative_refuse_de_conclure():
    reco = evaluate(make_metrics(cpu_avg=5.0, mem_avg=5.0, datapoints=3))
    assert reco.action == "none"
    assert reco.finding == "Unknown"
    assert reco.confidence == "low"


def test_absence_de_metriques_refuse_de_conclure():
    metrics = make_metrics(cpu_avg=None, mem_avg=None)
    metrics.cpu = MetricWindow("CPUUtilization", None, None, None, 0)
    metrics.memory = MetricWindow("MemoryUtilization", None, None, None, 0)
    reco = evaluate(metrics)
    assert reco.action == "none"
    assert reco.finding == "Unknown"


def test_reduction_par_paliers_depuis_4_taches():
    """10% sur 4 taches -> 20% sur 2 -> 40% sur 1 : 1 tache tient sous 70%."""
    reco = evaluate(make_metrics(cpu_avg=10.0, mem_avg=10.0, desired=4))
    assert reco.recommended_desired_count == 1
    assert reco.projected_cpu_pct == pytest.approx(40.0)


def test_cout_horaire_dune_tache_fargate():
    """256 CPU / 512 Mo en eu-west-2."""
    cost = task_hourly_cost(256, 512, "eu-west-2")
    assert cost == pytest.approx(0.25 * 0.04656 + 0.5 * 0.00511)


def test_region_inconnue_ne_chiffre_pas_le_cout():
    assert task_hourly_cost(256, 512, "ap-south-1") is None


def test_le_risque_de_tache_unique_est_signale_meme_sans_avis_aws():
    """Perdre la redondance multi-AZ est un risque propre a la reco maison."""
    metrics = make_metrics(cpu_avg=10.0, mem_avg=20.0, desired=2)
    house = evaluate(metrics)
    aws = AwsRecommendation(available=False, unavailable_reason="opt-in requis")
    result = compare(metrics, house, aws)

    assert result.agreement == "aws_indisponible"
    assert "redondance" in result.delta_risk
    assert any("redondance multi-AZ" in note for note in result.notes)


def test_les_metriques_dexemple_sont_etiquetees():
    """Le mode --sample ne doit jamais passer pour des mesures reelles."""
    metrics = load_sample()
    assert metrics.source == "sample"
    house = evaluate(metrics)
    result = compare(metrics, house, AwsRecommendation(available=False, unavailable_reason="x"))
    assert any("EXEMPLE" in note for note in result.notes)


def test_aucune_recommandation_nest_appliquee_automatiquement():
    """Le module 2 est en lecture seule : il ne renvoie qu'une proposition."""
    reco = evaluate(make_metrics(cpu_avg=10.0, mem_avg=20.0, desired=2))
    assert reco.action in {"reduce_task_count", "none"}
    assert not hasattr(reco, "applied")
