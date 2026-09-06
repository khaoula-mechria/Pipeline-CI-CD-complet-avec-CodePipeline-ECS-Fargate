"""Recuperation des metriques CloudWatch du service ECS taskmanager.

Scope volontairement limite au service ECS de CE projet
(`<project>-<environment>-service` dans le cluster `<project>-<environment>-cluster`),
pas a un service ECS quelconque.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import boto3
from botocore.exceptions import (
    BotoCoreError,
    ClientError,
    NoCredentialsError,
    TokenRetrievalError,
)

DEFAULT_WINDOW_DAYS = 14
# Une periode de 5 min est la granularite standard des metriques ECS.
DEFAULT_PERIOD_SECONDS = 300

SAMPLE_FILE = Path(__file__).resolve().parent / "sample_metrics.json"


@dataclass
class MetricWindow:
    """Statistiques d'une metrique sur la fenetre observee."""

    name: str
    average: float | None
    maximum: float | None
    p95: float | None
    datapoints: int

    @property
    def has_data(self) -> bool:
        return self.datapoints > 0 and self.average is not None


@dataclass
class ServiceMetrics:
    """Photo du service ECS sur la fenetre demandee."""

    cluster_name: str
    service_name: str
    window_days: int
    start: str
    end: str
    cpu: MetricWindow
    memory: MetricWindow
    desired_count: int | None
    running_count: int | None
    task_cpu_units: int | None
    task_memory_mb: int | None
    service_arn: str | None = None
    source: str = "cloudwatch"
    note: str | None = None

    @property
    def has_data(self) -> bool:
        return self.cpu.has_data and self.memory.has_data

    def to_json(self) -> dict:
        return asdict(self)


def _percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(int(round(fraction * (len(ordered) - 1))), len(ordered) - 1)
    return ordered[index]


def _fetch_metric(
    cloudwatch, metric_name: str, cluster: str, service: str, start, end, period: int
) -> MetricWindow:
    """Une metrique AWS/ECS agregee sur la fenetre."""
    response = cloudwatch.get_metric_statistics(
        Namespace="AWS/ECS",
        MetricName=metric_name,
        Dimensions=[
            {"Name": "ClusterName", "Value": cluster},
            {"Name": "ServiceName", "Value": service},
        ],
        StartTime=start,
        EndTime=end,
        Period=period,
        Statistics=["Average", "Maximum"],
    )
    points = response.get("Datapoints", [])
    averages = [p["Average"] for p in points]
    maximums = [p["Maximum"] for p in points]

    return MetricWindow(
        name=metric_name,
        average=round(sum(averages) / len(averages), 2) if averages else None,
        maximum=round(max(maximums), 2) if maximums else None,
        p95=round(_percentile(averages, 0.95), 2) if averages else None,
        datapoints=len(points),
    )


def _describe_service(ecs, cluster: str, service: str) -> dict:
    try:
        described = ecs.describe_services(cluster=cluster, services=[service])
        services = described.get("services", [])
        return services[0] if services else {}
    except ClientError:
        return {}


def _describe_task_size(ecs, task_definition_arn: str | None) -> tuple[int | None, int | None]:
    """CPU/memoire declares dans la task definition (256 / 512 sur ce projet)."""
    if not task_definition_arn:
        return None, None
    try:
        task_def = ecs.describe_task_definition(taskDefinition=task_definition_arn)
        definition = task_def.get("taskDefinition", {})
        cpu = definition.get("cpu")
        memory = definition.get("memory")
        return (int(cpu) if cpu else None, int(memory) if memory else None)
    except (ClientError, ValueError):
        return None, None


def collect(
    project: str = "taskmanager",
    environment: str = "dev",
    region: str = "eu-west-2",
    profile: str | None = None,
    window_days: int = DEFAULT_WINDOW_DAYS,
    period_seconds: int = DEFAULT_PERIOD_SECONDS,
) -> ServiceMetrics:
    """Interroge CloudWatch + ECS pour le service taskmanager."""
    cluster_name = f"{project}-{environment}-cluster"
    service_name = f"{project}-{environment}-service"

    session = boto3.Session(profile_name=profile) if profile else boto3.Session()
    cloudwatch = session.client("cloudwatch", region_name=region)
    ecs = session.client("ecs", region_name=region)

    end = datetime.now(timezone.utc)
    start = end - timedelta(days=window_days)

    empty = lambda name: MetricWindow(name, None, None, None, 0)  # noqa: E731

    try:
        cpu = _fetch_metric(
            cloudwatch, "CPUUtilization", cluster_name, service_name, start, end, period_seconds
        )
        memory = _fetch_metric(
            cloudwatch, "MemoryUtilization", cluster_name, service_name, start, end, period_seconds
        )
        service = _describe_service(ecs, cluster_name, service_name)
        task_cpu, task_memory = _describe_task_size(ecs, service.get("taskDefinition"))
        access_error = None
    except (ClientError, NoCredentialsError, TokenRetrievalError, BotoCoreError) as exc:
        # Cas courant sur ce projet : session SSO expiree, ou infrastructure
        # detruite entre deux tests. On rend un resultat exploitable plutot
        # qu'une trace d'exception.
        cpu, memory = empty("CPUUtilization"), empty("MemoryUtilization")
        service, task_cpu, task_memory = {}, None, None
        access_error = str(exc)

    metrics = ServiceMetrics(
        cluster_name=cluster_name,
        service_name=service_name,
        window_days=window_days,
        start=start.isoformat(),
        end=end.isoformat(),
        cpu=cpu,
        memory=memory,
        desired_count=service.get("desiredCount"),
        running_count=service.get("runningCount"),
        task_cpu_units=task_cpu,
        task_memory_mb=task_memory,
        service_arn=service.get("serviceArn"),
    )

    if access_error:
        metrics.note = (
            f"AWS inaccessible : {access_error} "
            f"Verifier la session SSO (aws sso login --profile ...) et la region. "
            f"Utiliser --sample pour une demonstration hors ligne."
        )
    elif not metrics.has_data:
        metrics.note = (
            f"Aucun datapoint CloudWatch pour {service_name} sur {window_days} jours. "
            f"Le service est probablement detruit ou vient d'etre cree. "
            f"Utiliser --sample pour une demonstration hors ligne."
        )
    return metrics


def load_sample() -> ServiceMetrics:
    """Jeu de metriques d'exemple, pour demontrer la chaine sans infrastructure.

    Toujours etiquete `source="sample"` : aucune sortie ne doit laisser croire
    qu'il s'agit de mesures reelles.
    """
    payload = json.loads(SAMPLE_FILE.read_text(encoding="utf-8"))
    payload["cpu"] = MetricWindow(**payload["cpu"])
    payload["memory"] = MetricWindow(**payload["memory"])
    return ServiceMetrics(**payload)
