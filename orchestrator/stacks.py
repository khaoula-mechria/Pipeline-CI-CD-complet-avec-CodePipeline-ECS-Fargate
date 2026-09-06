"""Registre des 12 stacks de CE repo.

Volontairement non generique : les noms de stacks, les valeurs de parametres et
le cablage inter-stacks sont ceux du runbook `guideme2.md`. L'orchestrateur ne
pretend pas deployer "n'importe quel projet CloudFormation" ; il automatise
l'ordre de deploiement de ce projet-ci.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = REPO_ROOT / "infrastructure" / "cloudformation"

DEFAULT_PROJECT = os.environ.get("PROJECT_NAME", "taskmanager")
DEFAULT_ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
DEFAULT_REGION = os.environ.get("AWS_REGION", "eu-west-2")


@dataclass(frozen=True)
class StackSpec:
    """Une stack du projet : son template, son nom CFN, ses parametres."""

    key: str
    template: str
    # Suffixe ajoute a "<project>-<environment>-" pour former le nom de stack.
    name_suffix: str
    # Parametres a valeur fixe (repris tels quels du runbook).
    parameters: dict = field(default_factory=dict)
    # Parametres alimentes par un export d'une AUTRE stack.
    # {NomDuParametre: "<export name non resolu>"}
    #
    # C'est le point subtil de ce repo : alb.yaml et ecs-service.yaml ne font
    # AUCUN Fn::ImportValue vers le VPC. Ils declarent VpcId / *SubnetIds en
    # parametres typés, que le runbook resout a la main via
    # `aws cloudformation list-exports` avant de les passer en
    # --parameter-overrides. Cette dependance est donc invisible dans le
    # template : sans ce cablage explicite, le graphe placerait alb en vague 1,
    # en parallele du VPC dont il depend pourtant reellement.
    parameters_from_exports: dict = field(default_factory=dict)

    def stack_name(self, project: str, environment: str) -> str:
        return f"{project}-{environment}-{self.name_suffix}"

    def template_path(self) -> Path:
        return TEMPLATE_DIR / self.template


# Ordre de declaration = ordre du runbook, purement cosmetique :
# l'ordre reel de deploiement est calcule par dependency_graph.py.
STACKS: tuple[StackSpec, ...] = (
    StackSpec("vpc", "vpc.yml", "vpc"),
    StackSpec("secrets", "secrets-manager.yaml", "secrets"),
    StackSpec("ecr", "ecr.yaml", "ecr"),
    StackSpec(
        "codebuild",
        "codebuild.yaml",
        "codebuild",
        parameters={"GitHubRepoUrl": os.environ.get("GITHUB_REPO_URL", "")},
    ),
    StackSpec("iam", "iam.yaml", "iam"),
    StackSpec("ecs-cluster", "ecs-cluster.yaml", "ecs-cluster"),
    StackSpec(
        "alb",
        "alb.yaml",
        "alb",
        parameters={"ContainerPort": "3000", "HealthCheckPath": "/health"},
        parameters_from_exports={
            "VpcId": "${ProjectName}-${Environment}-vpc-id",
            "PublicSubnetIds": "${ProjectName}-${Environment}-public-subnet-ids",
        },
    ),
    StackSpec(
        "taskdef",
        "ecs-task-definition.yaml",
        "taskdef",
        parameters={"ContainerCpu": "256", "ContainerMemory": "512", "ContainerPort": "3000"},
    ),
    StackSpec(
        "ecs-service",
        "ecs-service.yaml",
        "ecs-service",
        parameters={"ContainerPort": "3000", "DesiredCount": "1"},
        parameters_from_exports={
            "VpcId": "${ProjectName}-${Environment}-vpc-id",
            "PrivateSubnetIds": "${ProjectName}-${Environment}-private-subnet-ids",
        },
    ),
    StackSpec(
        "pipeline",
        "pipeline.yml",
        "pipeline",
        parameters={
            "FullRepositoryId": os.environ.get("FULL_REPOSITORY_ID", ""),
            "BranchName": os.environ.get("BRANCH_NAME", "main"),
            "EnableManualApproval": "true",
        },
    ),
    StackSpec(
        "autoscaling",
        "ecs-autoscaling.yaml",
        "autoscaling",
        parameters={"MinCapacity": "1", "MaxCapacity": "2", "TargetCpuUtilization": "70"},
    ),
    StackSpec(
        "observability",
        "observability.yml",
        "observability",
        parameters={"AlarmEmail": os.environ.get("ALARM_EMAIL", "")},
    ),
)

STACKS_BY_KEY = {spec.key: spec for spec in STACKS}


def resolve(value: str, project: str, environment: str) -> str:
    """Resout ${ProjectName} / ${Environment} dans un nom d'export."""
    return value.replace("${ProjectName}", project).replace("${Environment}", environment)
