"""Tests du rendu du graphe (hors ligne, sans Streamlit ni AWS).

Lancer : python -m pytest dashboard/ -v
"""

from __future__ import annotations

import pytest

from dashboard.graph_view import (
    EDGE_BLOCKING,
    STATUS_STYLE,
    build_dot,
    classify,
    progress,
)
from orchestrator.dependency_graph import build_graph, waves


@pytest.fixture(scope="module")
def graph():
    return build_graph("taskmanager", "dev")


@pytest.mark.parametrize(
    "status,expected",
    [
        (None, "PENDING"),
        ("", "PENDING"),
        ("CREATE_IN_PROGRESS", "IN_PROGRESS"),
        ("UPDATE_IN_PROGRESS", "IN_PROGRESS"),
        ("CREATE_COMPLETE", "COMPLETE"),
        ("UPDATE_COMPLETE", "COMPLETE"),
        ("CREATE_FAILED", "FAILED"),
        ("ROLLBACK_COMPLETE", "FAILED"),
        ("DELETE_COMPLETE", "FAILED"),
        ("ALREADY_EXISTS", "SKIPPED"),
    ],
)
def test_classification_des_statuts_cloudformation(status, expected):
    """ROLLBACK_COMPLETE se termine par _COMPLETE mais reste un echec."""
    assert classify(status) == expected


def test_le_dot_contient_toutes_les_stacks(graph):
    dot = build_dot(graph, {}, waves(graph))
    for key in graph.nodes:
        assert f'"{key}"' in dot
    assert dot.startswith("digraph")
    assert dot.rstrip().endswith("}")


def test_les_aretes_vers_une_stack_en_cours_sont_mises_en_evidence(graph):
    """C'est ce qui montre visuellement "ce qui debloque la suite"."""
    dot = build_dot(graph, {"iam": "CREATE_IN_PROGRESS"}, waves(graph))
    # codebuild -> iam doit etre en orange.
    lignes = [l for l in dot.splitlines() if '"codebuild" -> "iam"' in l]
    assert lignes and EDGE_BLOCKING in lignes[0]


def test_le_graphe_fige_neteint_la_mise_en_evidence(graph):
    dot = build_dot(graph, {"iam": "CREATE_IN_PROGRESS"}, waves(graph), frozen=True)
    lignes = [l for l in dot.splitlines() if '"codebuild" -> "iam"' in l]
    assert lignes and EDGE_BLOCKING not in lignes[0]


def test_les_aretes_de_cablage_parametre_sont_en_pointilles(graph):
    """vpc -> alb ne vient pas d'un ImportValue : il doit se distinguer."""
    dot = build_dot(graph, {}, waves(graph))
    lignes = [l for l in dot.splitlines() if '"vpc" -> "alb"' in l]
    assert lignes and "style=dashed" in lignes[0]


def test_les_couleurs_de_statut_apparaissent_dans_le_dot(graph):
    statuses = {"vpc": "CREATE_COMPLETE", "alb": "CREATE_FAILED"}
    dot = build_dot(graph, statuses, waves(graph))
    assert STATUS_STYLE["COMPLETE"]["fill"] in dot
    assert STATUS_STYLE["FAILED"]["fill"] in dot


def test_les_vagues_sont_alignees_en_colonnes(graph):
    dot = build_dot(graph, {}, waves(graph))
    assert dot.count("rank=same") == len(waves(graph))


def test_progression_vide(graph):
    summary = progress({}, list(graph.nodes))
    assert summary["done"] == 0
    assert summary["finished"] is False
    assert summary["ratio"] == 0.0


def test_progression_complete(graph):
    statuses = {key: "CREATE_COMPLETE" for key in graph.nodes}
    summary = progress(statuses, list(graph.nodes))
    assert summary["finished"] is True
    assert summary["ratio"] == 1.0
    assert summary["failed"] is False


def test_une_stack_en_echec_est_signalee(graph):
    statuses = {key: "CREATE_COMPLETE" for key in graph.nodes}
    statuses["iam"] = "CREATE_FAILED"
    summary = progress(statuses, list(graph.nodes))
    assert summary["failed"] is True
    assert summary["finished"] is False


def test_une_stack_deja_presente_compte_comme_terminee(graph):
    """ALREADY_EXISTS ne doit pas bloquer la detection de fin de deploiement."""
    statuses = {key: "CREATE_COMPLETE" for key in graph.nodes}
    statuses["vpc"] = "ALREADY_EXISTS"
    summary = progress(statuses, list(graph.nodes))
    assert summary["finished"] is True


def test_les_guillemets_sont_echappes(graph):
    """Un statut exotique ne doit pas casser la syntaxe DOT."""
    dot = build_dot(graph, {"vpc": 'CREATE_FAILED ("boom")'}, waves(graph))
    ligne = [l for l in dot.splitlines() if l.strip().startswith('"vpc" [')][0]
    assert '\\"boom\\"' in ligne


def test_le_dot_produit_est_syntaxiquement_valide(graph):
    """Le DOT est rendu par viz.js cote navigateur : une erreur de syntaxe y
    serait silencieuse. On le fait donc relire par un vrai parseur.
    """
    pydot = pytest.importorskip("pydot")
    statuses = {"iam": "CREATE_IN_PROGRESS", "vpc": 'CREATE_FAILED ("boom")'}
    parsed = pydot.graph_from_dot_data(build_dot(graph, statuses, waves(graph)))
    assert parsed, "le DOT genere n'est pas analysable"

    noeuds = {
        n.get_name().strip('"')
        for n in parsed[0].get_nodes()
        if not n.get_name().startswith(("wave", "node", "edge", "graph"))
    }
    assert set(graph.nodes) <= noeuds
