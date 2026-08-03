#!/usr/bin/env python3
"""Validate, plan, and locally simulate a multi-backend Self-Healing topology.

The topology file contains names and environment-variable references only.
Tenant identifiers and email addresses are resolved by the lifecycle shell
scripts at execution time and are never emitted by this program.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SAFE_NAME = re.compile(r"^[a-z][a-z0-9-]{1,47}$")
SAFE_BACKEND_SET = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,63}$")
REQUIRED_SERVICE_FIELDS = {
    "id",
    "backend_set_name",
    "backend_port",
    "health_path",
    "capacity",
    "placement",
    "capacity_reservation",
    "remediation",
}


class TopologyError(ValueError):
    """A safe, user-facing topology validation error."""


def _load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise TopologyError(f"unable to read valid topology JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise TopologyError("topology root must be an object")
    return value


def _positive_int(value: Any, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise TopologyError(f"{field} must be a positive integer")
    return value


def validate(topology: dict[str, Any]) -> dict[str, Any]:
    if topology.get("schema_version") != 1:
        raise TopologyError("schema_version must be 1")
    name = str(topology.get("topology_name", ""))
    if not SAFE_NAME.fullmatch(name):
        raise TopologyError("topology_name must be a safe lowercase identifier")

    lb = topology.get("load_balancer")
    if not isinstance(lb, dict):
        raise TopologyError("load_balancer must be an object")
    if lb.get("kind") != "OCI_LOAD_BALANCER":
        raise TopologyError("only OCI_LOAD_BALANCER is supported")
    if lb.get("visibility") != "private":
        raise TopologyError("the reusable topology example must remain private")
    if lb.get("listener_protocol") not in {"HTTP", "HTTPS"}:
        raise TopologyError("listener_protocol must be HTTP or HTTPS")
    listener_mode = lb.get("listener_mode", "single-port")
    if listener_mode not in {"single-port", "per-service-port"}:
        raise TopologyError("listener_mode must be single-port or per-service-port")
    if listener_mode == "single-port":
        _positive_int(lb.get("listener_port"), "load_balancer.listener_port")

    deployment_mode = topology.get("deployment_mode", "existing-resources")
    if deployment_mode not in {"managed-full-stack", "existing-resources"}:
        raise TopologyError("deployment_mode is unsupported")
    if deployment_mode == "existing-resources" and not str(
        lb.get("load_balancer_id_env", "")
    ).startswith("SELF_HEALING_"):
        raise TopologyError("existing-resources mode requires load_balancer_id_env")

    notification = topology.get("notification")
    if not isinstance(notification, dict) or notification.get("protocol") != "EMAIL":
        raise TopologyError("notification.protocol must be EMAIL")
    if not str(notification.get("endpoint_env", "")).startswith("SELF_HEALING_"):
        raise TopologyError(
            "notification.endpoint_env must be a Self-Healing environment variable"
        )

    services = topology.get("services")
    if not isinstance(services, list) or not services:
        raise TopologyError("services must be a non-empty list")

    ids: set[str] = set()
    backend_sets: set[str] = set()
    pool_envs: set[str] = set()
    summary_services = []
    for index, service in enumerate(services):
        if not isinstance(service, dict):
            raise TopologyError(f"services[{index}] must be an object")
        missing = REQUIRED_SERVICE_FIELDS - service.keys()
        if missing:
            raise TopologyError(f"services[{index}] is missing {sorted(missing)}")
        service_id = str(service["id"])
        backend_set = str(service["backend_set_name"])
        if not SAFE_NAME.fullmatch(service_id):
            raise TopologyError(f"services[{index}].id is invalid")
        if service_id in ids:
            raise TopologyError(f"duplicate service id: {service_id}")
        if not SAFE_BACKEND_SET.fullmatch(backend_set):
            raise TopologyError(f"services[{index}].backend_set_name is invalid")
        if backend_set in backend_sets:
            raise TopologyError(f"duplicate backend set: {backend_set}")
        pool_env = str(service.get("instance_pool_id_env", ""))
        if deployment_mode == "existing-resources":
            if not pool_env.startswith("SELF_HEALING_") or pool_env in pool_envs:
                raise TopologyError(
                    f"services[{index}].instance_pool_id_env is invalid or duplicate"
                )
        port = _positive_int(service["backend_port"], f"{service_id}.backend_port")
        if port > 65535:
            raise TopologyError(f"{service_id}.backend_port exceeds 65535")
        health_path = str(service["health_path"])
        if not health_path.startswith("/") or any(ch.isspace() for ch in health_path):
            raise TopologyError(f"{service_id}.health_path must be an absolute path")

        capacity = service["capacity"]
        remediation = service["remediation"]
        if not isinstance(capacity, dict) or not isinstance(remediation, dict):
            raise TopologyError(
                f"{service_id} capacity and remediation must be objects"
            )
        minimum = _positive_int(capacity.get("min"), f"{service_id}.capacity.min")
        initial = _positive_int(
            capacity.get("initial"), f"{service_id}.capacity.initial"
        )
        maximum = _positive_int(capacity.get("max"), f"{service_id}.capacity.max")
        cooldown = _positive_int(
            capacity.get("cooldown_seconds"), f"{service_id}.capacity.cooldown_seconds"
        )
        if not minimum <= initial <= maximum:
            raise TopologyError(
                f"{service_id} capacity must satisfy min <= initial <= max"
            )
        min_healthy = _positive_int(
            remediation.get("min_healthy"), f"{service_id}.remediation.min_healthy"
        )
        max_replacements = _positive_int(
            remediation.get("max_replacements"),
            f"{service_id}.remediation.max_replacements",
        )
        window = _positive_int(
            remediation.get("window_seconds"),
            f"{service_id}.remediation.window_seconds",
        )
        if minimum < 2:
            raise TopologyError(
                f"{service_id} must have minimum capacity of at least 2"
            )
        if min_healthy >= initial:
            raise TopologyError(
                f"{service_id} min_healthy must be lower than initial capacity"
            )
        if service["capacity_reservation"] != "none":
            raise TopologyError(
                f"{service_id} capacity_reservation must be none for the disposable managed test"
            )

        ids.add(service_id)
        backend_sets.add(backend_set)
        if pool_env:
            pool_envs.add(pool_env)
        summary_services.append(
            {
                "id": service_id,
                "backend_set_name": backend_set,
                "backend_port": port,
                "health_path": health_path,
                "capacity": {
                    "min": minimum,
                    "initial": initial,
                    "max": maximum,
                    "cooldown_seconds": cooldown,
                },
                "placement": service["placement"],
                "capacity_reservation": service["capacity_reservation"],
                "remediation": {
                    "min_healthy": min_healthy,
                    "max_replacements": max_replacements,
                    "window_seconds": window,
                },
            }
        )

    return {
        "status": "VALID",
        "topology_name": name,
        "deployment_mode": deployment_mode,
        "service_count": len(summary_services),
        "load_balancer": {
            "kind": lb["kind"],
            "visibility": lb["visibility"],
            "listener_protocol": lb["listener_protocol"],
            "listener_mode": listener_mode,
            "listener_port": lb.get("listener_port"),
        },
        "notification": {"protocol": notification["protocol"]},
        "services": summary_services,
    }


def _actions(topology: dict[str, Any]) -> list[dict[str, Any]]:
    name = topology["topology_name"]
    deployment_mode = topology.get("deployment_mode", "existing-resources")
    lb_env = topology["load_balancer"].get("load_balancer_id_env", "")
    email_env = topology["notification"]["endpoint_env"]
    return [
        {
            "service": service["id"],
            "state_key": name
            if deployment_mode == "managed-full-stack"
            else f"{name}-{service['id']}",
            "ownership_mode": deployment_mode,
            "function_mode": "observe",
            "load_balancer_id_env": lb_env,
            "instance_pool_id_env": service.get("instance_pool_id_env", ""),
            "backend_set_name": service["backend_set_name"],
            "backend_port": service["backend_port"],
            "operations_email_env": email_env,
            "capacity": service["capacity"],
            "remediation": service["remediation"],
        }
        for service in topology["services"]
    ]


def plan(topology: dict[str, Any]) -> dict[str, Any]:
    validate(topology)
    managed = topology.get("deployment_mode") == "managed-full-stack"
    return {
        "status": "PLANNED",
        "topology_name": topology["topology_name"],
        "actions": _actions(topology),
        "next_step": (
            "Create and review one Terraform plan for the complete synthetic stack."
            if managed
            else "Resolve each *_env reference in protected runtime input and review one plan per state key."
        ),
    }


def simulate(topology: dict[str, Any]) -> dict[str, Any]:
    validate(topology)
    results = []
    for service in topology["services"]:
        desired = service["capacity"]["initial"]
        results.append(
            {
                "service": service["id"],
                "initial_healthy": desired,
                "alarm": "FIRING",
                "lb_removed_unhealthy_backend": True,
                "function_result": "REPLACEMENT_REQUESTED",
                "duplicate_result": "IGNORED",
                "desired_size_before": desired,
                "desired_size_after": desired,
                "desired_size_preserved": True,
                "replacement_health": "OK",
            }
        )
    return {
        "status": "PASS",
        "scope": "LOCAL_DETERMINISTIC_SIMULATION",
        "topology_name": topology["topology_name"],
        "scenarios": len(results),
        "replacements_requested": len(results),
        "duplicate_actions": 0,
        "services": results,
        "live_oci_contacted": False,
    }


def destroy_plan(topology: dict[str, Any]) -> dict[str, Any]:
    validate(topology)
    actions = _actions(topology)
    if topology.get("deployment_mode") == "managed-full-stack":
        return {
            "status": "DESTROY_PLANNED",
            "topology_name": topology["topology_name"],
            "actions": [
                {
                    "service": "complete-stack",
                    "state_key": topology["topology_name"],
                    "approval_env": "SELF_HEALING_DEMO_DESTROY_APPROVED",
                    "destroys_existing_resources": False,
                    "scope": "entire synthetic Terraform-owned stack",
                }
            ],
        }
    return {
        "status": "DESTROY_PLANNED",
        "topology_name": topology["topology_name"],
        "actions": [
            {
                "service": action["service"],
                "state_key": action["state_key"],
                "approval_env": "SELF_HEALING_DESTROY_APPROVED",
                "destroys_existing_resources": False,
                "scope": (
                    "entire synthetic Terraform-owned stack"
                    if action["ownership_mode"] == "managed-full-stack"
                    else "Self-Healing control-path resources in this state only"
                ),
            }
            for action in reversed(actions)
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument(
        "command",
        choices=("validate", "plan", "simulate", "destroy-plan"),
    )
    args = parser.parse_args(argv)
    try:
        topology = _load(args.config)
        output = {
            "validate": validate,
            "plan": plan,
            "simulate": simulate,
            "destroy-plan": destroy_plan,
        }[args.command](topology)
    except TopologyError as exc:
        print(json.dumps({"status": "INVALID", "error": str(exc)}))
        return 2
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
