"""Lecture de l'etat de deploiement : AWS en direct, ou fichier d'orchestrateur.

Le dashboard ne persiste rien. Il lit soit CloudFormation via boto3, soit le
fichier `.orchestrator-state.json` ecrit par le module 1.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from orchestrator.deploy import STATE_FILE


def read_state_file(path: Path = STATE_FILE) -> dict | None:
    """Etat ecrit par `python -m orchestrator deploy`, s'il existe."""
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def statuses_from_file(state: dict | None) -> dict[str, str]:
    if not state:
        return {}
    return {key: value.get("status", "") for key, value in state.get("stacks", {}).items()}


def statuses_from_aws(
    stack_names: dict[str, str], region: str, profile: str | None = None
) -> tuple[dict[str, str], str | None]:
    """Statut CloudFormation reel de chaque stack.

    Renvoie (statuts, erreur). Une stack absente est laissee "en attente"
    plutot que signalee en erreur : c'est l'etat normal avant deploiement.
    """
    try:
        session = boto3.Session(profile_name=profile) if profile else boto3.Session()
        cfn = session.client("cloudformation", region_name=region)
    except (BotoCoreError, ClientError) as exc:
        return {}, str(exc)

    statuses: dict[str, str] = {}
    error: str | None = None

    for key, stack_name in stack_names.items():
        try:
            described = cfn.describe_stacks(StackName=stack_name)["Stacks"][0]
            statuses[key] = described["StackStatus"]
        except ClientError as exc:
            code = exc.response["Error"]["Code"]
            message = exc.response["Error"].get("Message", "")
            if code == "ValidationError" and "does not exist" in message:
                continue  # stack pas encore creee
            error = f"{code}: {message}"
            break
        except BotoCoreError as exc:
            error = str(exc)
            break

    return statuses, error


def timings(state: dict | None) -> dict:
    """Chronos : parallele reel vs sequentiel estime."""
    if not state or not state.get("started_at"):
        return {"elapsed": 0.0, "sequential": 0.0, "gain_pct": None, "running": False}

    finished = state.get("finished_at")
    elapsed = (finished or time.time()) - state["started_at"]
    sequential = state.get("sequential_estimate_seconds") or 0.0
    gain = (1 - elapsed / sequential) * 100 if sequential and elapsed else None

    return {
        "elapsed": elapsed,
        "sequential": sequential,
        "gain_pct": gain,
        "running": finished is None,
        "waves": len(state.get("wave_plan") or []),
        "current_wave": state.get("current_wave", 0),
    }


def format_duration(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.0f}s"
    minutes, rest = divmod(int(seconds), 60)
    return f"{minutes}m{rest:02d}s"
