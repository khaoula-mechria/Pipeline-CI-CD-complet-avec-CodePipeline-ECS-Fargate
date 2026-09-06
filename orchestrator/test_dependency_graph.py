"""Tests du graphe de dependances (hors ligne, aucun appel AWS).

Lancer : python -m pytest orchestrator/ -v
"""

from __future__ import annotations

import networkx as nx
import pytest

from .dependency_graph import analyze, build_graph, extract_imports, waves
from .stacks import STACKS


@pytest.fixture(scope="module")
def graph() -> nx.DiGraph:
    return build_graph("taskmanager", "dev")


def test_les_12_stacks_sont_presentes(graph):
    assert graph.number_of_nodes() == 12
    assert len(STACKS) == 12


def test_le_graphe_est_acyclique(graph):
    assert nx.is_directed_acyclic_graph(graph)


def test_aucun_import_sans_producteur(graph):
    """Chaque Fn::ImportValue doit correspondre a un Export.Name du repo."""
    orphelins = {
        key: data["unresolved_imports"]
        for key, data in graph.nodes(data=True)
        if data.get("unresolved_imports")
    }
    assert orphelins == {}


def test_codebuild_avant_iam(graph):
    """iam.yaml importe taskmanager-dev-codebuild-arn.

    Une ancienne version du runbook deployait IAM en 2e position et echouait sur
    "No export named taskmanager-dev-codebuild-arn found".
    """
    assert nx.has_path(graph, "codebuild", "iam")
    assert not nx.has_path(graph, "iam", "codebuild")


def test_vpc_avant_alb_malgre_absence_d_importvalue(graph):
    """alb.yaml ne fait aucun Fn::ImportValue : sa dependance au VPC passe par
    ses parametres VpcId / PublicSubnetIds, resolus depuis les exports du VPC.

    Sans l'arete de cablage, alb partirait en vague 1, en parallele du VPC.
    """
    nodes = analyze("taskmanager", "dev")
    assert nodes["alb"].imports == set(), "alb.yaml ne devrait faire aucun ImportValue"
    assert graph.has_edge("vpc", "alb")
    assert graph["vpc"]["alb"]["kinds"] == {"parameter"}

    plan = waves(graph)
    wave_of = {key: i for i, wave in enumerate(plan) for key in wave}
    assert wave_of["vpc"] < wave_of["alb"]


def test_les_commentaires_ne_creent_pas_de_dependance():
    """codebuild.yaml, vpc.yml et pipeline.yml citent "Fn::ImportValue" dans des
    commentaires ou des descriptions : le parseur YAML doit les ignorer.
    """
    nodes = analyze("taskmanager", "dev")
    # vpc.yml mentionne Fn::ImportValue dans un commentaire mais n'importe rien.
    assert nodes["vpc"].imports == set()
    # Le commentaire de codebuild.yaml parle du topic SNS de pipeline.yml ;
    # aucune dependance codebuild -> pipeline ne doit en decouler.
    assert not any("notifications" in imported for imported in nodes["codebuild"].imports)


def test_extract_imports_gere_la_forme_importvalue_du_repo():
    """Forme utilisee partout ici : !ImportValue suivi d'un mapping Fn::Sub."""
    template = {
        "Resources": {
            "S": {
                "Properties": {
                    "Cluster": {"Fn::ImportValue": {"Fn::Sub": "${ProjectName}-${Environment}-x"}}
                }
            }
        }
    }
    assert extract_imports(template, "taskmanager", "dev") == {"taskmanager-dev-x"}


def test_les_vagues_respectent_toutes_les_aretes(graph):
    """Invariant central : une stack ne demarre jamais avant ses dependances."""
    plan = waves(graph)
    wave_of = {key: i for i, wave in enumerate(plan) for key in wave}
    for source, target in graph.edges():
        assert wave_of[source] < wave_of[target], f"{source} doit preceder {target}"


def test_la_parallelisation_est_reelle(graph):
    """Le decoupage doit produire moins de vagues que de stacks."""
    plan = waves(graph)
    assert len(plan) < 12
    assert any(len(wave) > 1 for wave in plan)
