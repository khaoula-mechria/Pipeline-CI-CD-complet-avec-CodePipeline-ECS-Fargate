"""Construction du graphe de dependances entre les 12 stacks du projet.

Deux types d'aretes, tous deux reels dans ce repo :

1. export/import  : la stack B fait `Fn::ImportValue` sur un `Export.Name`
                    produit par la stack A  ->  A doit exister avant B.
2. cablage parametre : la stack B declare un parametre dont la valeur est lue
                    depuis un export de A via `list-exports` au moment du
                    deploiement (cf. StackSpec.parameters_from_exports).

Le tri topologique par "generations" networkx regroupe ensuite les stacks en
vagues : dans une meme vague, aucune stack ne depend d'une autre, elles peuvent
donc partir en parallele.
"""

from __future__ import annotations

from dataclasses import dataclass

import networkx as nx

from .cfn_yaml import load_template
from .stacks import STACKS, DEFAULT_ENVIRONMENT, DEFAULT_PROJECT, StackSpec, resolve


def _walk(node):
    """Parcourt recursivement toutes les valeurs d'un template charge."""
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from _walk(value)
    elif isinstance(node, list):
        for item in node:
            yield from _walk(item)


def _flatten_sub(value) -> str | None:
    """Extrait la chaine d'un `Fn::Sub` (forme scalaire ou [chaine, vars])."""
    if isinstance(value, str):
        return value
    if isinstance(value, list) and value and isinstance(value[0], str):
        return value[0]
    return None


def extract_exports(template: dict, project: str, environment: str) -> set[str]:
    """Noms d'exports produits par la section Outputs d'un template."""
    exports: set[str] = set()
    for output in (template.get("Outputs") or {}).values():
        if not isinstance(output, dict):
            continue
        name = (output.get("Export") or {}).get("Name")
        if isinstance(name, dict):
            name = _flatten_sub(name.get("Fn::Sub"))
        if isinstance(name, str):
            exports.add(resolve(name, project, environment))
    return exports


def extract_imports(template: dict, project: str, environment: str) -> set[str]:
    """Noms d'exports consommes via Fn::ImportValue n'importe ou dans le template."""
    imports: set[str] = set()
    for node in _walk(template):
        if "Fn::ImportValue" not in node:
            continue
        target = node["Fn::ImportValue"]
        # Forme du repo : !ImportValue suivi de {'Fn::Sub': '${...}-alb-sg-id'}
        if isinstance(target, dict):
            target = _flatten_sub(target.get("Fn::Sub"))
        if isinstance(target, str):
            imports.add(resolve(target, project, environment))
    return imports


@dataclass
class StackNode:
    """Ce que l'on sait d'une stack apres analyse de son template."""

    spec: StackSpec
    stack_name: str
    exports: set[str]
    imports: set[str]
    # {NomParametre: nom d'export resolu}
    parameter_imports: dict[str, str]
    # Parametres declares par le template et leurs valeurs par defaut
    # (None = pas de Default, donc valeur obligatoire au deploiement).
    template_parameters: dict[str, str | None]


def extract_parameters(template: dict) -> dict[str, str | None]:
    """Parametres declares par le template -> leur Default (None si absent)."""
    parameters: dict[str, str | None] = {}
    for name, body in (template.get("Parameters") or {}).items():
        default = body.get("Default") if isinstance(body, dict) else None
        parameters[name] = None if default is None else str(default)
    return parameters


def analyze(project: str = DEFAULT_PROJECT, environment: str = DEFAULT_ENVIRONMENT) -> dict[str, StackNode]:
    """Charge et analyse les 12 templates."""
    nodes: dict[str, StackNode] = {}
    for spec in STACKS:
        template = load_template(spec.template_path())
        nodes[spec.key] = StackNode(
            spec=spec,
            stack_name=spec.stack_name(project, environment),
            exports=extract_exports(template, project, environment),
            imports=extract_imports(template, project, environment),
            parameter_imports={
                param: resolve(export, project, environment)
                for param, export in spec.parameters_from_exports.items()
            },
            template_parameters=extract_parameters(template),
        )
    return nodes


def build_graph(
    project: str = DEFAULT_PROJECT, environment: str = DEFAULT_ENVIRONMENT
) -> nx.DiGraph:
    """Graphe oriente des dependances : arete A -> B = "A avant B"."""
    nodes = analyze(project, environment)

    # Index inverse : nom d'export -> stack qui le produit.
    producer: dict[str, str] = {}
    for key, node in nodes.items():
        for export in node.exports:
            producer[export] = key

    graph = nx.DiGraph()
    for key, node in nodes.items():
        graph.add_node(
            key,
            stack_name=node.stack_name,
            template=node.spec.template,
            spec=node.spec,
            exports=sorted(node.exports),
            imports=sorted(node.imports),
        )

    for key, node in nodes.items():
        # (1) aretes export/import
        for imported in sorted(node.imports):
            source = producer.get(imported)
            if source is None:
                # Import sans producteur connu : ressource externe au repo.
                graph.add_node(key)
                graph.nodes[key].setdefault("unresolved_imports", []).append(imported)
                continue
            if source == key:
                continue
            _add_edge(graph, source, key, "import", imported)

        # (2) aretes de cablage parametre
        for param, imported in sorted(node.parameter_imports.items()):
            source = producer.get(imported)
            if source is None or source == key:
                continue
            _add_edge(graph, source, key, "parameter", f"{param}={imported}")

    if not nx.is_directed_acyclic_graph(graph):
        cycle = nx.find_cycle(graph)
        raise ValueError(f"Cycle de dependances detecte entre stacks : {cycle}")

    return graph


def _add_edge(graph: nx.DiGraph, source: str, target: str, kind: str, label: str) -> None:
    """Ajoute une arete en accumulant les raisons (un couple peut en avoir plusieurs)."""
    if graph.has_edge(source, target):
        graph[source][target]["reasons"].append(label)
        graph[source][target]["kinds"].add(kind)
    else:
        graph.add_edge(source, target, reasons=[label], kinds={kind})


def waves(graph: nx.DiGraph) -> list[list[str]]:
    """Regroupe les stacks en vagues deployables en parallele."""
    return [sorted(generation) for generation in nx.topological_generations(graph)]


def sequential_order(graph: nx.DiGraph) -> list[str]:
    """Ordre sequentiel valide (equivalent du runbook manuel)."""
    return list(nx.lexicographical_topological_sort(graph))
