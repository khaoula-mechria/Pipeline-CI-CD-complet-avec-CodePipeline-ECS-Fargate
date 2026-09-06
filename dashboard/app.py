"""Dashboard local de demonstration.

Trois onglets : deploiement (graphe live), optimisation, explication.

Tourne en local le temps d'une demo. Pas d'authentification, pas de base de
donnees, pas de multi-utilisateur : l'etat est lu en direct depuis AWS (ou
depuis le fichier ecrit par l'orchestrateur) et rien n'est persiste.

Lancement : streamlit run dashboard/app.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import streamlit as st

# Permet `streamlit run dashboard/app.py` depuis la racine du repo.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dashboard.graph_view import STATUS_STYLE, build_dot, classify, progress
from dashboard.live_state import (
    format_duration,
    read_state_file,
    statuses_from_aws,
    statuses_from_file,
    timings,
)
from orchestrator.dependency_graph import build_graph, waves
from orchestrator.stacks import DEFAULT_ENVIRONMENT, DEFAULT_PROJECT, DEFAULT_REGION

REFRESH_SECONDS = 4

st.set_page_config(page_title="Pipeline CI/CD — deploiement & optimisation", layout="wide")


# --------------------------------------------------------------------------
# Graphe du module 1 : construit une seule fois, reutilise tel quel.
# --------------------------------------------------------------------------
@st.cache_resource
def load_graph(project: str, environment: str):
    graph = build_graph(project, environment)
    return graph, waves(graph)


# --------------------------------------------------------------------------
# Barre laterale
# --------------------------------------------------------------------------
with st.sidebar:
    st.header("Configuration")
    project = st.text_input("ProjectName", DEFAULT_PROJECT)
    environment = st.text_input("Environment", DEFAULT_ENVIRONMENT)
    region = st.text_input("Region AWS", DEFAULT_REGION)
    profile = st.text_input("Profil AWS", "", placeholder="AdministratorAccess-...") or None

    source = st.radio(
        "Source de l'etat",
        ["AWS en direct", "Fichier d'orchestrateur"],
        help=(
            "AWS en direct interroge describe_stacks a chaque rafraichissement. "
            "Le fichier est celui ecrit par `python -m orchestrator deploy`."
        ),
    )
    auto_refresh = st.toggle("Rafraichissement auto", value=True)

    st.divider()
    st.caption(
        "Lecture seule, sauf le bouton **Appliquer** de l'onglet Explication, "
        "qui demande une confirmation explicite."
    )

graph, wave_plan = load_graph(project, environment)
stack_names = {key: graph.nodes[key]["stack_name"] for key in graph.nodes}

st.title("Pipeline CI/CD — deploiement et optimisation")
st.caption(
    f"{graph.number_of_nodes()} stacks CloudFormation, "
    f"{graph.number_of_edges()} dependances, {len(wave_plan)} vagues — "
    f"{project}-{environment} / {region}"
)

tab_deploy, tab_optimize, tab_explain = st.tabs(
    ["Deploiement", "Optimisation", "Explication"]
)


# ==========================================================================
# Onglet 1 — Deploiement
# ==========================================================================
def render_deployment() -> None:
    """Graphe colore + chronos. Redessine a chaque poll."""
    state = read_state_file()

    if source == "AWS en direct":
        statuses, error = statuses_from_aws(stack_names, region, profile)
        if error:
            st.warning(
                f"AWS injoignable ({error}). Bascule sur le fichier d'orchestrateur."
            )
            statuses = statuses_from_file(state)
    else:
        statuses = statuses_from_file(state)

    summary = progress(statuses, list(graph.nodes))
    chrono = timings(state)
    frozen = summary["finished"] or summary["failed"]

    columns = st.columns(4)
    columns[0].metric("Stacks terminees", f"{summary['done']}/{summary['total']}")
    columns[1].metric(
        "En cours", summary["counts"]["IN_PROGRESS"],
        delta=f"vague {chrono.get('current_wave', 0)}/{len(wave_plan)}"
        if chrono.get("current_wave") else None,
    )
    columns[2].metric("Temps parallele (reel)", format_duration(chrono["elapsed"]))
    columns[3].metric(
        "Sequentiel (estime)",
        format_duration(chrono["sequential"]) if chrono["sequential"] else "-",
        delta=f"gain {chrono['gain_pct']:.0f}%" if chrono["gain_pct"] is not None else None,
    )

    st.progress(summary["ratio"])

    legend = "  ".join(
        f":gray[{name.lower().replace('_', ' ')}] {count}"
        for name, count in summary["counts"].items()
        if count
    )
    st.caption(
        f"{legend}  —  arete pleine = Fn::ImportValue, "
        f"arete pointillee = parametre alimente par un export, "
        f"arete orange = dependance d'une stack en cours."
    )

    st.graphviz_chart(build_dot(graph, statuses, wave_plan, frozen=frozen), width="stretch")

    if summary["failed"]:
        st.error("Deploiement interrompu : au moins une stack est en echec.")
        for key in graph.nodes:
            if classify(statuses.get(key)) == "FAILED":
                reason = (state or {}).get("stacks", {}).get(key, {}).get("reason")
                st.write(f"- **{stack_names[key]}** — {statuses.get(key)}")
                if reason:
                    st.caption(f"  {reason}")

    elif summary["finished"]:
        st.success("Toutes les stacks sont deployees. Le graphe est fige.")
        final = st.columns(3)
        final[0].metric("Duree totale", format_duration(chrono["elapsed"]))
        final[1].metric("Vagues", f"{len(wave_plan)} au lieu de {summary['total']} etapes")
        final[2].metric(
            "Gain vs sequentiel",
            f"{chrono['gain_pct']:.0f}%" if chrono["gain_pct"] is not None else "-",
        )
        st.session_state["deployment_complete"] = True

    elif not statuses:
        st.info(
            "Aucune stack deployee pour l'instant. Lancer, dans un autre terminal :\n\n"
            "```\npython -m orchestrator deploy --profile <profil> --region "
            f"{region}\n```\n\n"
            "Pour voir l'enchainement sans toucher a AWS : "
            "`python -m orchestrator deploy --dry-run`."
        )


with tab_deploy:
    st.subheader("Graphe de dependances")
    if auto_refresh:
        st.fragment(render_deployment, run_every=REFRESH_SECONDS)()
    else:
        render_deployment()
        if st.button("Rafraichir", key="refresh_deploy"):
            st.rerun()


# ==========================================================================
# Onglet 2 — Optimisation
# ==========================================================================
with tab_optimize:
    st.subheader("Rightsizing du service ECS")

    controls = st.columns([1, 1, 1, 1])
    window_days = controls[0].number_input("Fenetre (jours)", 1, 30, 14)
    low_utilization = controls[1].number_input("Seuil sous-utilisation (%)", 5.0, 90.0, 40.0)
    safety_ceiling = controls[2].number_input("Plafond securite (%)", 20.0, 95.0, 70.0)
    min_datapoints = controls[3].number_input("Datapoints minimum", 1, 500, 12)

    use_sample = st.checkbox(
        "Utiliser les metriques d'exemple (aucun appel AWS)",
        value=False,
        help="Pour demontrer la chaine avec l'infrastructure detruite.",
    )

    if st.button("Analyser", type="primary"):
        from optimizer.compare import AwsRecommendation, compare, fetch_aws_recommendation
        from optimizer.metrics import collect, load_sample
        from optimizer.rules import evaluate

        with st.spinner("Lecture des metriques et appel de Compute Optimizer..."):
            if use_sample:
                metrics = load_sample()
                aws = AwsRecommendation(
                    available=False,
                    unavailable_reason="Mode exemple : Compute Optimizer n'est pas interroge.",
                )
            else:
                metrics = collect(
                    project=project, environment=environment, region=region,
                    profile=profile, window_days=int(window_days),
                )
                aws = fetch_aws_recommendation(metrics.service_arn, region, profile)

            house = evaluate(
                metrics, region=region,
                low_utilization_pct=float(low_utilization),
                safety_ceiling_pct=float(safety_ceiling),
                min_datapoints=int(min_datapoints),
            )
            st.session_state["report"] = compare(metrics, house, aws, region=region).to_json()

    report = st.session_state.get("report")

    if not report:
        st.info("Lancer une analyse pour afficher la comparaison.")
    else:
        metrics, house, aws = report["metrics"], report["house"], report["aws"]

        if metrics.get("source") == "sample":
            st.warning("Metriques d'EXEMPLE : chiffres illustratifs, pas des mesures reelles.")
        if metrics.get("note"):
            st.caption(metrics["note"])

        observed = st.columns(4)
        observed[0].metric("CPU moyen", f"{metrics['cpu']['average']}%"
                           if metrics["cpu"]["average"] is not None else "-")
        observed[1].metric("Memoire moyenne", f"{metrics['memory']['average']}%"
                           if metrics["memory"]["average"] is not None else "-")
        observed[2].metric("Taches", metrics.get("desired_count") or "-")
        observed[3].metric("Datapoints", metrics["cpu"]["datapoints"])

        st.markdown("#### Regle maison vs AWS Compute Optimizer")
        st.dataframe(
            [
                {
                    "Critere": "Levier",
                    "Regle maison": "nombre de taches",
                    "AWS Compute Optimizer": "taille de tache (CPU/memoire)",
                },
                {
                    "Critere": "Verdict",
                    "Regle maison": house.get("finding") or "-",
                    "AWS Compute Optimizer": aws.get("finding") or "indisponible",
                },
                {
                    "Critere": "Recommandation",
                    "Regle maison": f"{house.get('current_desired_count')} -> "
                                    f"{house.get('recommended_desired_count')} tache(s)",
                    "AWS Compute Optimizer": f"{aws.get('recommended_cpu_units') or '-'} CPU / "
                                             f"{aws.get('recommended_memory_mb') or '-'} Mo",
                },
                {
                    "Critere": "Economie mensuelle",
                    "Regle maison": f"${house.get('monthly_saving_usd')}"
                                    if house.get("monthly_saving_usd") is not None else "-",
                    "AWS Compute Optimizer": f"${aws.get('estimated_monthly_saving_usd')}"
                                             if aws.get("estimated_monthly_saving_usd") is not None
                                             else "-",
                },
                {
                    "Critere": "Confiance",
                    "Regle maison": house.get("confidence") or "-",
                    "AWS Compute Optimizer": "n/a (modele AWS)",
                },
            ],
            hide_index=True, width="stretch",
        )

        deltas = st.columns(3)
        deltas[0].metric("Accord", report.get("agreement") or "-")
        deltas[1].metric(
            "Delta cout",
            f"${report['delta_cost_usd']}" if report.get("delta_cost_usd") is not None else "-",
        )
        deltas[2].metric("Delta risque", report.get("delta_risk") or "-")

        st.info(f"**Motif calcule** — {house.get('rationale')}")
        for note in report.get("notes", []):
            st.caption(f"• {note}")


# ==========================================================================
# Onglet 3 — Explication
# ==========================================================================
with tab_explain:
    st.subheader("Explication en langage naturel")
    report = st.session_state.get("report")

    if not report:
        st.info("Lancer d'abord une analyse dans l'onglet Optimisation.")
    else:
        model = st.text_input("Modele", "claude-opus-5")

        if st.button("Expliquer", type="primary"):
            from explainer.client import ExplainerError, explain

            with st.spinner("Appel du modele..."):
                try:
                    st.session_state["explanation"] = explain(report, model=model).text
                except ExplainerError as exc:
                    st.session_state["explanation"] = None
                    st.error(str(exc))

        explanation = st.session_state.get("explanation")
        if explanation:
            with st.chat_message("assistant"):
                st.markdown(explanation)

        # ------------------------------------------------------------------
        # Zone d'application : volontairement isolee du reste de l'onglet.
        # ------------------------------------------------------------------
        st.divider()
        st.markdown("### Appliquer la recommandation")

        from explainer.apply import check_applicable

        applicable, reason = check_applicable(report)

        if not applicable:
            st.info(f"Rien a appliquer. {reason}")
        else:
            house = report["house"]
            st.warning(
                f"**Cette action modifie l'infrastructure AWS reelle.**\n\n"
                f"Service `{report['metrics']['service_name']}` : "
                f"DesiredCount **{house['current_desired_count']} -> "
                f"{house['recommended_desired_count']}**.\n\n"
                f"Economie estimee : ${house.get('monthly_saving_usd')}/mois — "
                f"confiance : {house.get('confidence')}."
            )
            if house.get("recommended_desired_count") == 1:
                st.error(
                    "Passer a une seule tache supprime la redondance multi-AZ : "
                    "toute interruption coupe le service jusqu'au remplacement."
                )

            confirmed = st.checkbox(
                f"Je confirme vouloir passer {report['metrics']['service_name']} a "
                f"{house['recommended_desired_count']} tache(s)."
            )
            typed = st.text_input(
                "Taper APPLIQUER pour debloquer le bouton", placeholder="APPLIQUER"
            )

            ready = confirmed and typed.strip().upper() == "APPLIQUER"
            if st.button("Appliquer maintenant", type="primary", disabled=not ready):
                import boto3

                metrics = report["metrics"]
                try:
                    session = boto3.Session(profile_name=profile) if profile else boto3.Session()
                    session.client("ecs", region_name=region).update_service(
                        cluster=metrics["cluster_name"],
                        service=metrics["service_name"],
                        desiredCount=house["recommended_desired_count"],
                    )
                except Exception as exc:  # noqa: BLE001 - affiche l'erreur telle quelle
                    st.error(f"Echec de l'application : {exc}")
                else:
                    st.success(
                        f"Applique : DesiredCount {house['current_desired_count']} -> "
                        f"{house['recommended_desired_count']} sur {metrics['service_name']}."
                    )
                    st.caption(
                        "Verifier : aws ecs describe-services --cluster "
                        f"{metrics['cluster_name']} --services {metrics['service_name']} "
                        f"--region {region}"
                    )
            if not ready:
                st.caption(
                    "Le bouton reste desactive tant que la case n'est pas cochee "
                    "et que le mot APPLIQUER n'est pas saisi."
                )
