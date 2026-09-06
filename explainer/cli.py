"""CLI de la couche d'explication : `python -m explainer explain` / `apply`.

Deux commandes volontairement distinctes :
  - `explain` : lecture seule, appelle le LLM, ne touche a rien.
  - `apply`   : exige --apply ET une confirmation humaine tapee au clavier.

Il n'existe aucun chemin qui enchaine automatiquement l'analyse et l'application.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .apply import apply_recommendation
from .client import DEFAULT_MAX_TOKENS, DEFAULT_MODEL, ExplainerError, explain


def _load_report(path: str | None) -> dict:
    """Charge le rapport du module 2 : fichier, stdin, ou analyse a la volee."""
    if path == "-":
        return json.load(sys.stdin)
    if path:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    raise SystemExit(
        "Aucun rapport fourni. Utiliser --report <fichier.json>, --report - (stdin), "
        "ou --sample pour une demonstration."
    )


def _sample_report() -> dict:
    """Rapport genere depuis les metriques d'exemple du module 2."""
    from optimizer.compare import AwsRecommendation, compare
    from optimizer.metrics import load_sample
    from optimizer.rules import evaluate

    metrics = load_sample()
    house = evaluate(metrics)
    aws = AwsRecommendation(
        available=False,
        unavailable_reason="Mode --sample : Compute Optimizer n'est pas interroge.",
    )
    return compare(metrics, house, aws).to_json()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m explainer",
        description=(
            "Explique en langage naturel le rapport de rightsizing du module 2. "
            "L'application eventuelle exige --apply et une confirmation humaine."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_explain = sub.add_parser("explain", help="Explique le rapport (lecture seule)")
    p_explain.add_argument("--report", default=None, help="Rapport JSON du module 2, ou - pour stdin")
    p_explain.add_argument("--sample", action="store_true", help="Utilise le rapport d'exemple")
    p_explain.add_argument("--model", default=DEFAULT_MODEL, help=f"Modele (defaut: {DEFAULT_MODEL})")
    p_explain.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    p_explain.add_argument(
        "--raw-json", action="store_true", help="Joint aussi le JSON brut au prompt"
    )
    p_explain.add_argument("--json", action="store_true", help="Sortie JSON")
    p_explain.add_argument(
        "--print-prompt", action="store_true",
        help="Affiche le prompt sans appeler l'API (aucun cout, aucune cle requise)",
    )

    p_apply = sub.add_parser(
        "apply", help="Applique la recommandation apres confirmation humaine"
    )
    p_apply.add_argument("--report", default=None, help="Rapport JSON du module 2, ou - pour stdin")
    p_apply.add_argument(
        "--apply", action="store_true",
        help="Drapeau obligatoire : sans lui, la commande n'ecrit rien",
    )
    p_apply.add_argument("--region", default="eu-west-2")
    p_apply.add_argument("--profile", default=None, help="Profil AWS")
    return parser


def cmd_explain(args) -> int:
    report = _sample_report() if args.sample else _load_report(args.report)

    if args.print_prompt:
        from .prompt import SYSTEM_PROMPT, build_messages

        print("=== SYSTEM ===")
        print(SYSTEM_PROMPT)
        print("\n=== USER ===")
        print(build_messages(report, include_raw_json=args.raw_json)[0]["content"])
        return 0

    try:
        explanation = explain(
            report,
            model=args.model,
            max_tokens=args.max_tokens,
            include_raw_json=args.raw_json,
        )
    except ExplainerError as exc:
        print(f"Erreur : {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(explanation.to_json(), indent=2, ensure_ascii=False))
    else:
        print(explanation.text)
        print(
            f"\n---\nModele : {explanation.model} "
            f"(entree {explanation.input_tokens} / sortie {explanation.output_tokens} tokens)"
        )
        print("Aucune modification n'a ete appliquee. Pour appliquer : "
              "python -m explainer apply --report <rapport.json> --apply")
    return 0


def cmd_apply(args) -> int:
    if not args.apply:
        print(
            "Le drapeau --apply est obligatoire pour modifier l'infrastructure.\n"
            "Sans lui, cette commande n'ecrit rien. Relancer avec --apply pour "
            "obtenir le recapitulatif et la demande de confirmation.",
            file=sys.stderr,
        )
        return 1

    report = _load_report(args.report)
    decision = apply_recommendation(report, region=args.region, profile=args.profile)
    return 0 if decision.applied else 1


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return {"explain": cmd_explain, "apply": cmd_apply}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
