"""CLI du moteur d'optimisation : `python -m optimizer analyze`."""

from __future__ import annotations

import argparse
import json
import sys

from .compare import compare, fetch_aws_recommendation, render_table
from .metrics import DEFAULT_WINDOW_DAYS, collect, load_sample
from .rules import (
    DEFAULT_LOW_UTILIZATION_PCT,
    DEFAULT_MIN_DATAPOINTS,
    DEFAULT_SAFETY_CEILING_PCT,
    evaluate,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m optimizer",
        description=(
            "Analyse le service ECS taskmanager et compare une recommandation de "
            "rightsizing maison a celle d'AWS Compute Optimizer. N'applique rien."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)
    analyze = sub.add_parser("analyze", help="Analyse le service et affiche la comparaison")

    analyze.add_argument("--project", default="taskmanager")
    analyze.add_argument("--environment", default="dev")
    analyze.add_argument("--region", default="eu-west-2")
    analyze.add_argument("--profile", default=None, help="Profil AWS")
    analyze.add_argument(
        "--window-days", type=int, default=DEFAULT_WINDOW_DAYS,
        help=f"Fenetre d'observation (defaut: {DEFAULT_WINDOW_DAYS}; utiliser 1 pour une demo)",
    )
    analyze.add_argument(
        "--low-utilization", type=float, default=DEFAULT_LOW_UTILIZATION_PCT,
        help=f"Seuil de sous-utilisation en %% (defaut: {DEFAULT_LOW_UTILIZATION_PCT})",
    )
    analyze.add_argument(
        "--safety-ceiling", type=float, default=DEFAULT_SAFETY_CEILING_PCT,
        help=f"Plafond d'utilisation projetee en %% (defaut: {DEFAULT_SAFETY_CEILING_PCT})",
    )
    analyze.add_argument(
        "--min-capacity", type=int, default=1,
        help="Nombre de taches plancher (MinCapacity de ecs-autoscaling.yaml)",
    )
    analyze.add_argument(
        "--min-datapoints", type=int, default=DEFAULT_MIN_DATAPOINTS,
        help="Datapoints minimum pour se prononcer",
    )
    analyze.add_argument(
        "--sample", action="store_true",
        help="Utilise des metriques d'exemple (aucun appel AWS), pour une demo hors ligne",
    )
    analyze.add_argument("--json", action="store_true", help="Sortie JSON (entree du module 3)")
    analyze.add_argument("--output", default=None, help="Ecrit le rapport JSON dans un fichier")
    return parser


def run_analysis(args):
    """Chaine complete : metriques -> regle maison -> avis AWS -> comparaison."""
    if args.sample:
        metrics = load_sample()
    else:
        metrics = collect(
            project=args.project,
            environment=args.environment,
            region=args.region,
            profile=args.profile,
            window_days=args.window_days,
        )

    house = evaluate(
        metrics,
        region=args.region,
        low_utilization_pct=args.low_utilization,
        safety_ceiling_pct=args.safety_ceiling,
        min_capacity=args.min_capacity,
        min_datapoints=args.min_datapoints,
    )

    if args.sample:
        from .compare import AwsRecommendation

        aws = AwsRecommendation(
            available=False,
            unavailable_reason=(
                "Mode --sample : Compute Optimizer n'est pas interroge "
                "(aucun appel AWS n'est fait)."
            ),
        )
    else:
        aws = fetch_aws_recommendation(metrics.service_arn, args.region, args.profile)

    return compare(metrics, house, aws, region=args.region)


def cmd_analyze(args) -> int:
    comparison = run_analysis(args)
    payload = comparison.to_json()

    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    else:
        print(render_table(comparison))
        if args.output:
            print(f"\n  Rapport JSON ecrit dans {args.output}")

    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return {"analyze": cmd_analyze}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
