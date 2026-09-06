"""Orchestrateur de deploiement : deploie les stacks vague par vague.

Remplace le runbook manuel de 21 etapes (Appendix A du rapport) : l'ordre n'est
plus ecrit a la main, il est deduit du graphe de dependances, et les stacks
d'une meme vague partent en parallele.
"""

from __future__ import annotations

import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

from .dependency_graph import analyze, build_graph, waves
from .stacks import DEFAULT_ENVIRONMENT, DEFAULT_PROJECT, DEFAULT_REGION, StackSpec

# Etats terminaux renvoyes par describe_stacks pendant un create_stack.
SUCCESS_STATES = {"CREATE_COMPLETE", "UPDATE_COMPLETE"}
FAILURE_STATES = {
    "CREATE_FAILED",
    "ROLLBACK_IN_PROGRESS",
    "ROLLBACK_COMPLETE",
    "ROLLBACK_FAILED",
    "DELETE_COMPLETE",
}

POLL_SECONDS = 5
# Fichier d'etat relu par le dashboard Streamlit (module 4).
STATE_FILE = Path(__file__).resolve().parent.parent / ".orchestrator-state.json"


@dataclass
class StackResult:
    key: str
    stack_name: str
    status: str = "PENDING"
    wave: int = 0
    started_at: float | None = None
    finished_at: float | None = None
    duration_seconds: float | None = None
    reason: str | None = None

    @property
    def ok(self) -> bool:
        return self.status in SUCCESS_STATES or self.status == "ALREADY_EXISTS"


@dataclass
class RunState:
    project: str
    environment: str
    region: str
    wave_plan: list[list[str]] = field(default_factory=list)
    stacks: dict[str, StackResult] = field(default_factory=dict)
    started_at: float | None = None
    finished_at: float | None = None
    current_wave: int = 0
    failed: bool = False

    def to_json(self) -> dict:
        payload = asdict(self)
        payload["stacks"] = {k: asdict(v) for k, v in self.stacks.items()}
        payload["updated_at"] = datetime.now(timezone.utc).isoformat()
        payload["elapsed_seconds"] = (
            (self.finished_at or time.time()) - self.started_at if self.started_at else 0.0
        )
        # Le temps sequentiel estime = somme des durees reellement observees.
        # C'est la base de comparaison honnete "sequentiel estime vs parallele reel"
        # citee dans le memoire : meme travail, mais enchaine au lieu d'etre parallelise.
        payload["sequential_estimate_seconds"] = sum(
            s.duration_seconds or 0.0 for s in self.stacks.values()
        )
        return payload


_state_lock = threading.Lock()


def _write_state(state: RunState) -> None:
    with _state_lock:
        STATE_FILE.write_text(json.dumps(state.to_json(), indent=2), encoding="utf-8")


def _list_exports(cfn) -> dict[str, str]:
    """Tous les exports CloudFormation de la region, {nom: valeur}."""
    exports: dict[str, str] = {}
    paginator = cfn.get_paginator("list_exports")
    for page in paginator.paginate():
        for export in page.get("Exports", []):
            exports[export["Name"]] = export["Value"]
    return exports


def _simulated_exports(state: RunState) -> dict[str, str]:
    """Exports factices pour le dry-run (aucun appel AWS)."""
    nodes = analyze(state.project, state.environment)
    return {
        export: f"dry-run-{export}"
        for node in nodes.values()
        for export in node.exports
    }


def build_parameters(
    spec: StackSpec,
    project: str,
    environment: str,
    exports: dict[str, str],
    declared: dict[str, str | None],
) -> list[dict]:
    """Construit les parameter-overrides, en resolvant les exports comme le runbook."""
    values: dict[str, str] = {"ProjectName": project, "Environment": environment}
    values.update({k: v for k, v in spec.parameters.items() if v != ""})

    for param, export_name in spec.parameters_from_exports.items():
        resolved_name = export_name.replace("${ProjectName}", project).replace(
            "${Environment}", environment
        )
        resolved = exports.get(resolved_name)
        if resolved is None:
            raise RuntimeError(
                f"{spec.key}: export {resolved_name} introuvable pour alimenter le "
                f"parametre {param}. La stack qui le produit n'est pas deployee."
            )
        values[param] = resolved

    missing = [name for name, default in declared.items() if default is None and name not in values]
    if missing:
        raise RuntimeError(
            f"{spec.key}: parametre(s) obligatoire(s) sans valeur : {', '.join(missing)}. "
            f"Renseignez la variable d'environnement correspondante (voir orchestrator/README.md)."
        )

    # On ne transmet que les parametres reellement declares par le template.
    return [
        {"ParameterKey": k, "ParameterValue": v} for k, v in values.items() if k in declared
    ]


def deploy_stack(spec: StackSpec, node, state: RunState, session, dry_run: bool = False) -> StackResult:
    """Cree une stack puis attend son etat terminal."""
    result = state.stacks[spec.key]
    result.started_at = time.time()
    result.status = "CREATE_IN_PROGRESS"
    _write_state(state)

    cfn = None if dry_run else session.client("cloudformation", region_name=state.region)

    try:
        # En dry-run on n'appelle pas AWS : les exports attendus sont simules a
        # partir du graphe, ce qui permet de rejouer tout l'enchainement des
        # vagues meme avec l'infrastructure detruite (cas courant sur ce projet,
        # ou tout est supprime entre deux tests pour eviter les couts).
        exports = _simulated_exports(state) if dry_run else _list_exports(cfn)
        parameters = build_parameters(
            spec, state.project, state.environment, exports, node.template_parameters
        )

        if dry_run:
            time.sleep(0.2)
            result.status = "CREATE_COMPLETE"
            result.reason = "dry-run (aucun appel create_stack)"
        else:
            try:
                cfn.create_stack(
                    StackName=result.stack_name,
                    TemplateBody=spec.template_path().read_text(encoding="utf-8"),
                    Parameters=parameters,
                    Capabilities=["CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"],
                    OnFailure="DO_NOTHING",
                    Tags=[
                        {"Key": "Project", "Value": state.project},
                        {"Key": "Environment", "Value": state.environment},
                        {"Key": "ManagedBy", "Value": "orchestrator"},
                    ],
                )
            except ClientError as exc:
                if exc.response["Error"]["Code"] == "AlreadyExistsException":
                    result.status = "ALREADY_EXISTS"
                    result.reason = "stack deja presente, creation ignoree"
                else:
                    raise
            if result.status != "ALREADY_EXISTS":
                result.status = _wait_for_stack(cfn, result.stack_name)
    except Exception as exc:  # noqa: BLE001 - on veut remonter toute erreur proprement
        result.status = "CREATE_FAILED"
        result.reason = str(exc)

    result.finished_at = time.time()
    result.duration_seconds = round(result.finished_at - result.started_at, 1)
    if not result.ok and not result.reason:
        result.reason = _failure_reason(session, state, result.stack_name)
    _write_state(state)
    return result


def _wait_for_stack(cfn, stack_name: str) -> str:
    """Poll describe_stacks jusqu'a un etat terminal."""
    while True:
        try:
            described = cfn.describe_stacks(StackName=stack_name)["Stacks"][0]
        except ClientError as exc:
            return f"CREATE_FAILED ({exc.response['Error']['Code']})"
        status = described["StackStatus"]
        if status in SUCCESS_STATES or status in FAILURE_STATES:
            return status
        time.sleep(POLL_SECONDS)


def _failure_reason(session, state: RunState, stack_name: str) -> str | None:
    """Recupere l'evenement d'echec le plus parlant pour l'afficher a l'utilisateur."""
    try:
        cfn = session.client("cloudformation", region_name=state.region)
        events = cfn.describe_stack_events(StackName=stack_name)["StackEvents"]
    except ClientError:
        return None
    for event in events:
        if event.get("ResourceStatus", "").endswith("FAILED"):
            reason = event.get("ResourceStatusReason", "")
            return f"{event.get('LogicalResourceId')}: {reason}".strip()
    return None


def run_deployment(
    project: str = DEFAULT_PROJECT,
    environment: str = DEFAULT_ENVIRONMENT,
    region: str = DEFAULT_REGION,
    profile: str | None = None,
    dry_run: bool = False,
    only: list[str] | None = None,
    log=print,
) -> RunState:
    """Deploie toutes les stacks, vague par vague, en parallele dans chaque vague."""
    graph = build_graph(project, environment)
    nodes = analyze(project, environment)
    plan = waves(graph)

    if only:
        keep = set(only)
        plan = [[k for k in wave if k in keep] for wave in plan]
        plan = [wave for wave in plan if wave]

    session = boto3.Session(profile_name=profile) if profile else boto3.Session()

    state = RunState(project=project, environment=environment, region=region, wave_plan=plan)
    for index, wave in enumerate(plan, start=1):
        for key in wave:
            state.stacks[key] = StackResult(key=key, stack_name=nodes[key].stack_name, wave=index)
    state.started_at = time.time()
    _write_state(state)

    total = sum(len(w) for w in plan)
    suffix = " [DRY-RUN]" if dry_run else ""
    log(
        f"Deploiement de {total} stacks en {len(plan)} vagues "
        f"({project}-{environment}, region {region}){suffix}"
    )

    for index, wave in enumerate(plan, start=1):
        state.current_wave = index
        _write_state(state)
        log(
            f"\n=== Vague {index}/{len(plan)} : {', '.join(wave)} "
            f"({len(wave)} stack(s) en parallele) ==="
        )

        with ThreadPoolExecutor(max_workers=len(wave)) as pool:
            futures = [
                pool.submit(deploy_stack, nodes[key].spec, nodes[key], state, session, dry_run)
                for key in wave
            ]
            for future in futures:
                future.result()

        failures = [state.stacks[key] for key in wave if not state.stacks[key].ok]
        for key in wave:
            res = state.stacks[key]
            mark = "OK  " if res.ok else "ECHEC"
            log(
                f"  [{mark}] {res.stack_name:34} {res.status:22} "
                f"{res.duration_seconds or 0:>6.1f}s"
            )

        if failures:
            state.failed = True
            state.finished_at = time.time()
            _write_state(state)
            log(f"\nArret : {len(failures)} stack(s) en echec dans la vague {index}.")
            for res in failures:
                log(f"  - {res.stack_name}: {res.status}")
                if res.reason:
                    log(f"    motif: {res.reason}")
            log(
                "Les vagues suivantes ne sont pas lancees "
                "(leurs stacks dependent de celles qui ont echoue)."
            )
            return state

    state.finished_at = time.time()
    _write_state(state)
    _log_timing(state, plan, log)
    return state


def _log_timing(state: RunState, plan: list[list[str]], log) -> None:
    """Trace la comparaison sequentiel estime / parallele reel (chiffre du memoire)."""
    payload = state.to_json()
    parallel = payload["elapsed_seconds"]
    sequential = payload["sequential_estimate_seconds"]
    gain = (1 - parallel / sequential) * 100 if sequential else 0.0

    log("\n=== Bilan ===")
    log(f"  Stacks deployees        : {len(state.stacks)} en {len(plan)} vagues")
    log(f"  Parallele (reel)        : {parallel:.1f}s")
    log(f"  Sequentiel (estime)     : {sequential:.1f}s  [somme des durees par stack]")
    log(f"  Gain                    : {gain:.1f}%")
    log(f"  Etat detaille           : {STATE_FILE.name}")
