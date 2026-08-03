"""OCI Function that safely replaces one unhealthy instance-pool member."""

from __future__ import annotations

import hashlib
import io
import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from typing import Any

import oci
from fdk import response


LOG = logging.getLogger()
MODE = os.getenv("MODE", "observe").strip().lower()
MIN_HEALTHY_BACKENDS = int(os.getenv("MIN_HEALTHY_BACKENDS", "1"))
MAX_REPLACEMENTS_PER_WINDOW = int(os.getenv("MAX_REPLACEMENTS_PER_WINDOW", "1"))
REPLACEMENT_WINDOW_SECONDS = int(os.getenv("REPLACEMENT_WINDOW_SECONDS", "900"))
COMPARTMENT_ID = os.getenv("COMPARTMENT_ID", "")
INSTANCE_POOL_ID = os.getenv("INSTANCE_POOL_ID", "")
LOAD_BALANCER_ID = os.getenv("LOAD_BALANCER_ID", "")
BACKEND_SET_NAME = os.getenv("BACKEND_SET_NAME", "")
STATE_TABLE_NAME = os.getenv("STATE_TABLE_NAME", "")
STATE_TABLE_ID = os.getenv("STATE_TABLE_ID", "")
SERVICE_NAME = os.getenv("SERVICE_NAME", "unknown-service")


def _clients() -> tuple[Any, Any, Any]:
    signer = oci.auth.signers.get_resource_principals_signer()
    return (
        oci.load_balancer.LoadBalancerClient({}, signer=signer),
        oci.core.ComputeManagementClient({}, signer=signer),
        oci.nosql.NosqlClient({}, signer=signer),
    )


def _payload(data: io.BytesIO) -> dict[str, Any]:
    raw = data.getvalue() if hasattr(data, "getvalue") else data.read()
    decoded = json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
    if isinstance(decoded, dict) and isinstance(decoded.get("body"), str):
        try:
            body = json.loads(decoded["body"])
            if isinstance(body, dict):
                return body
        except json.JSONDecodeError:
            pass
    return decoded if isinstance(decoded, dict) else {}


def _alarm_state(event: dict[str, Any]) -> str:
    state = str(
        event.get("type")
        or event.get("alarmMetaData", [{}])[0].get("status")
        or event.get("severity")
        or ""
    ).upper()
    return "FIRING" if state in {"FIRING", "OK_TO_FIRING"} else state


def _backend_name(item: Any) -> str:
    return str(getattr(item, "backend_name", "") or "")


def _dedupe(nosql: Any, event: dict[str, Any]) -> bool:
    """Return True only for the first delivery of this alarm occurrence."""
    dedupekey = str(event.get("dedupekey") or event.get("dedupeKey") or "unknown")
    stamp = str(event.get("timestampEpochMillis") or event.get("timestamp") or "0")
    key = f"{dedupekey}:{stamp}"
    expires = int(time.time()) + REPLACEMENT_WINDOW_SECONDS
    details = oci.nosql.models.UpdateRowDetails(
        compartment_id=COMPARTMENT_ID,
        option="IF_ABSENT",
        value={
            "event_key": key,
            "created_epoch": int(time.time()),
            "pool_id": INSTANCE_POOL_ID,
            "backend_name": "",
            "action": "alarm-received",
            "detail": str(expires),
        },
    )
    try:
        result = nosql.update_row(STATE_TABLE_ID, details)
    except oci.exceptions.ServiceError as exc:
        if exc.status == 409:
            return False
        raise
    return bool(getattr(result.data, "version", None))


def _replacement_budget(nosql: Any) -> bool:
    row = nosql.get_row(
        STATE_TABLE_ID,
        ["event_key:replacement-window"],
        consistency="ABSOLUTE",
    ).data
    value = getattr(row, "value", None) or {}
    window_start = int(value.get("created_epoch", 0))
    count = int(value.get("detail", "0"))
    if int(time.time()) - window_start >= REPLACEMENT_WINDOW_SECONDS:
        return True
    return count < MAX_REPLACEMENTS_PER_WINDOW


def _record_replacement(nosql: Any) -> None:
    now = int(time.time())
    row = nosql.get_row(
        STATE_TABLE_ID,
        ["event_key:replacement-window"],
        consistency="ABSOLUTE",
    ).data
    value = getattr(row, "value", None) or {}
    window_start = int(value.get("created_epoch", 0))
    count = int(value.get("detail", "0"))
    if now - window_start >= REPLACEMENT_WINDOW_SECONDS:
        window_start, count = now, 0
    nosql.update_row(
        STATE_TABLE_ID,
        oci.nosql.models.UpdateRowDetails(
            compartment_id=COMPARTMENT_ID,
            value={
                "event_key": "replacement-window",
                "created_epoch": window_start,
                "pool_id": INSTANCE_POOL_ID,
                "backend_name": "",
                "action": "replacement-window",
                "detail": str(count + 1),
            },
        ),
    )


def _pool_members(compute: Any) -> list[Any]:
    result = oci.pagination.list_call_get_all_results(
        compute.list_instance_pool_instances,
        compartment_id=COMPARTMENT_ID,
        instance_pool_id=INSTANCE_POOL_ID,
    )
    return list(result.data or [])


def _select_unhealthy(lb: Any, members: list[Any]) -> tuple[Any | None, int]:
    health = lb.get_backend_set_health(
        load_balancer_id=LOAD_BALANCER_ID,
        backend_set_name=BACKEND_SET_NAME,
    ).data
    unhealthy_names = set(getattr(health, "critical_state_backend_names", []) or [])
    unhealthy_names.update(getattr(health, "warning_state_backend_names", []) or [])
    matches = []
    healthy = 0
    for member in members:
        attachments = getattr(member, "load_balancer_backends", []) or []
        names = {_backend_name(item) for item in attachments}
        if names & unhealthy_names:
            matches.append(member)
        elif names and str(getattr(member, "state", "")).upper() == "RUNNING":
            healthy += 1
    return (matches[0] if len(matches) == 1 else None), healthy


def _result(status: str, reason: str, **extra: Any) -> dict[str, Any]:
    fingerprint_source = f"{INSTANCE_POOL_ID}:{LOAD_BALANCER_ID}:{BACKEND_SET_NAME}"
    audit_record = {
        "event_type": "self_healing_decision",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "service": SERVICE_NAME,
        "status": status,
        "reason": reason,
        "mode": MODE,
        "resource_fingerprint": hashlib.sha256(fingerprint_source.encode()).hexdigest()[
            :16
        ],
    }
    LOG.info(json.dumps(audit_record, sort_keys=True))
    return {"status": status, "reason": reason, **extra}


def remediate(
    event: dict[str, Any], clients: tuple[Any, Any, Any] | None = None
) -> dict[str, Any]:
    if _alarm_state(event) != "FIRING":
        return _result("IGNORED", "alarm is not FIRING")
    if not all(
        (
            COMPARTMENT_ID,
            INSTANCE_POOL_ID,
            LOAD_BALANCER_ID,
            BACKEND_SET_NAME,
            STATE_TABLE_NAME,
            STATE_TABLE_ID,
        )
    ):
        return _result("REMEDIATION_BLOCKED", "required configuration is missing")

    lb, compute, nosql = clients or _clients()
    pool = compute.get_instance_pool(INSTANCE_POOL_ID).data
    pool_state = getattr(pool, "lifecycle_state", None) or getattr(pool, "state", "")
    if str(pool_state).upper() != "RUNNING":
        return _result("REMEDIATION_BLOCKED", "instance pool is not RUNNING")
    if not _dedupe(nosql, event):
        return _result("IGNORED", "duplicate alarm delivery")
    if not _replacement_budget(nosql):
        return _result("REMEDIATION_BLOCKED", "replacement rate guard reached")

    member, healthy = _select_unhealthy(lb, _pool_members(compute))
    if member is None:
        return _result(
            "REMEDIATION_BLOCKED", "expected exactly one unhealthy pool member"
        )
    if healthy < MIN_HEALTHY_BACKENDS:
        return _result("REMEDIATION_BLOCKED", "minimum healthy backend guard")
    if MODE != "remediate":
        return _result("OBSERVED", "MODE is observe; no mutation performed")

    instance_id = getattr(member, "id", "")
    retry_token = str(
        uuid.uuid5(uuid.NAMESPACE_URL, f"{INSTANCE_POOL_ID}:{instance_id}")
    )
    details = oci.core.models.DetachInstancePoolInstanceDetails(
        instance_id=instance_id,
        is_auto_terminate=True,
        is_decrement_size=False,
    )
    # Consume the bounded replacement budget before the mutation so a
    # post-detach bookkeeping failure cannot turn a successful detach into a
    # retryable Function error.
    _record_replacement(nosql)
    compute.detach_instance_pool_instance(
        INSTANCE_POOL_ID,
        details,
        opc_retry_token=retry_token,
    )
    return _result(
        "REPLACEMENT_REQUESTED",
        "unhealthy member detached; pool desired size preserved",
        requested_at=datetime.now(timezone.utc).isoformat(),
    )


def handler(ctx: Any, data: io.BytesIO | None = None):
    try:
        result = remediate(_payload(data or io.BytesIO(b"{}")))
        return response.Response(
            ctx,
            response_data=json.dumps(result),
            headers={"Content-Type": "application/json"},
            status_code=200,
        )
    except Exception as exc:
        LOG.exception("Self-Healing remediation failed")
        reason = type(exc).__name__
        operation = getattr(exc, "operation_name", None)
        code = getattr(exc, "code", None)
        if operation or code:
            reason = ":".join(part for part in (reason, operation, code) if part)
        return response.Response(
            ctx,
            response_data=json.dumps({"status": "ERROR", "reason": reason}),
            headers={"Content-Type": "application/json"},
            status_code=500,
        )
