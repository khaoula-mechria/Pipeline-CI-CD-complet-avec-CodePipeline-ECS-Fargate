"""CLI de l'orchestrateur : `python -m orchestrator <commande>`."""

from __future__ import annotations

import argparse
import json
import sys

from .dependency_graph import analyze, build_graph, sequential_order, waves
from .stacks import DEFAULT_ENVIRONMENT, DEFAULT_PROJECT, DEFAULT_REGION


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--project", default=DEFAULT_PROJECT, help="ProjectName (defaut: taskmanager)")
    parser.add_argument("--environment", default=DEFAULT_ENVIRONMENT, help="Environment (defaut: dev)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m orchestrator",
        description="Deploiement ordonne des 12 stacks CloudFormation du projet.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_graph = sub.add_parser("graph", help="Affiche le graphe de dependances et les vagues")
    _common(p_graph)
    p_graph.add_argument("--json", action="store_true", help="Sortie JSON")
    p_graph.add_argument("--edges", action="store_true", help="Detaille chaque arete")

    p_validate = sub.add_parser(
        "validate", help="Verifie templates, cycles et parametres obligatoires (hors ligne)"
    )
    _common(p_validate)

    p_deploy = sub.add_parser("deploy", help="Deploie les stacks vague par vague")
    _common(p_deploy)
    p_deploy.add_argument("--region", default=DEFAULT_REGION, help="Region AWS (defaut: eu-west-2)")
    p_deploy.add_argument("--profile", default=None, help="Profil AWS (ex: AdministratorAccess-...)")
    p_deploy.add_argument(
        "--dry-run", action="store_true", help="Simule sans appeler create_stack"
    )
    p_deploy.add_argument(
        "--only", nargs="+", metavar="STACK", help="Limite a certaines stacks (par cle)"
    )
    return parser


def cmd_graph(args) -> int:
    graph = build_graph(args.project, args.environment)
    plan = waves(graph)

    if args.json:
        payload = {
            "waves": plan,
            "sequential_order": sequential_order(graph),
            "edges": [
                {
                    "from": u,
                    "to": v,
                    "kinds": sorted(d["kinds"]),
                    "reasons": d["reasons"],
                }
                for u, v, d in graph.edges(data=True)
            ],
        }
        print(json.dumps(payload, indent=2))
        return 0

    print(f"{graph.number_of_nodes()} stacks, {graph.number_of_edges()} dependances, "
          f"{len(plan)} vagues\n")
    for index, wave in enumerate(plan, start=1):
        parallel = " (en parallele)" if len(wave) > 1 else ""
        print(f"  Vague {index}{parallel}")
        for key in wave:
            node = graph.nodes[key]
            deps = sorted(graph.predecessors(key))
            suffix = f"  <- {', '.join(deps)}" if deps else ""
            print(f"    - {key:14} [{node['template']}]{suffix}")

    if args.edges:
        print("\nDependances detaillees :")
        for u, v, d in sorted(graph.edges(data=True)):
            kinds = "/".join(sorted(d["kinds"]))
            print(f"  {u} -> {v}  ({kinds})")
            for reason in d["reasons"]:
                print(f"      {reason}")
    return 0


def cmd_validate(args) -> int:
    graph = build_graph(args.project, args.environment)
    nodes = analyze(args.project, args.environment)
    problems: list[str] = []

    for key, node in nodes.items():
        unresolved = graph.nodes[key].get("unresolved_imports")
        if unresolved:
            problems.append(f"{key}: import(s) sans export producteur : {unresolved}")

        supplied = (
            set(node.spec.parameters)
            | set(node.spec.parameters_from_exports)
            | {"ProjectName", "Environment"}
        )
        for name, default in node.template_parameters.items():
            if default is None and name not in supplied:
                problems.append(f"{key}: parametre obligatoire non fourni : {name}")
        for name, value in node.spec.parameters.items():
            if value == "":
                problems.append(
                    f"{key}: parametre {name} vide "
                    f"(definir la variable d'environnement correspondante)"
                )

    print(f"Templates charges : {len(nodes)}/12")
    print(f"Graphe acyclique  : oui ({graph.number_of_edges()} dependances)")
    print(f"Vagues            : {len(waves(graph))}")

    if problems:
        print(f"\n{len(problems)} point(s) a corriger avant un deploiement reel :")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    print("\nAucun probleme detecte.")
    return 0


def cmd_deploy(args) -> int:
    from .deploy import run_deployment

    state = run_deployment(
        project=args.project,
        environment=args.environment,
        region=args.region,
        profile=args.profile,
        dry_run=args.dry_run,
        only=args.only,
    )
    return 1 if state.failed else 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    handlers = {"graph": cmd_graph, "validate": cmd_validate, "deploy": cmd_deploy}
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
