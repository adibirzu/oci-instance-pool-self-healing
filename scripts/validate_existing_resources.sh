#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

required=(
    OCI_COMPARTMENT_ID
    SELF_HEALING_EXISTING_INSTANCE_POOL_ID
    SELF_HEALING_EXISTING_LOAD_BALANCER_ID
    SELF_HEALING_EXISTING_BACKEND_SET_NAME
)
for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || {
        echo "Self-Healing: existing-resource validation needs $name" >&2
        exit 2
    }
done

pool_json="$(mktemp /tmp/self_healing-existing-pool.XXXXXX.json)"
backend_json="$(mktemp /tmp/self_healing-existing-backend.XXXXXX.json)"
trap 'rm -f "$pool_json" "$backend_json"' EXIT
chmod 600 "$pool_json" "$backend_json"

oci_cli compute-management instance-pool get \
    --instance-pool-id "$SELF_HEALING_EXISTING_INSTANCE_POOL_ID" \
    --query data >"$pool_json"
oci_cli lb backend-set get \
    --load-balancer-id "$SELF_HEALING_EXISTING_LOAD_BALANCER_ID" \
    --backend-set-name "$SELF_HEALING_EXISTING_BACKEND_SET_NAME" \
    --query data >"$backend_json"
lb_state="$(oci_cli lb load-balancer get \
    --load-balancer-id "$SELF_HEALING_EXISTING_LOAD_BALANCER_ID" \
    --query 'data."lifecycle-state"' --raw-output)"

python3 - "$pool_json" "$backend_json" "$lb_state" \
    "$SELF_HEALING_EXISTING_LOAD_BALANCER_ID" "$SELF_HEALING_EXISTING_BACKEND_SET_NAME" <<'PY'
import json
import sys

pool_path, backend_path, lb_state, expected_lb, expected_backend = sys.argv[1:]
pool = json.load(open(pool_path, encoding="utf-8"))
backend = json.load(open(backend_path, encoding="utf-8"))
errors = []

if str(pool.get("lifecycle-state", "")).upper() != "RUNNING":
    errors.append("instance pool is not RUNNING")
if int(pool.get("size", 0)) < 2:
    errors.append("instance pool size must be at least 2 for one-member replacement")
if lb_state.upper() != "ACTIVE":
    errors.append("load balancer is not ACTIVE")

attachments = pool.get("load-balancers") or []
matches = [
    item
    for item in attachments
    if item.get("load-balancer-id") == expected_lb
    and item.get("backend-set-name") == expected_backend
]
if len(matches) != 1:
    errors.append("pool must have exactly one matching LB/backend-set attachment")

health = backend.get("health-checker") or {}
if health.get("protocol") not in {"HTTP", "HTTPS", "TCP"}:
    errors.append("backend set has no supported health checker")

if errors:
    for error in errors:
        print(f"Self-Healing: {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    "Self-Healing: existing topology validated: pool RUNNING, LB ACTIVE, "
    "attachment unique, health checker present"
)
PY

health="$(oci_cli lb backend-set-health get \
    --load-balancer-id "$SELF_HEALING_EXISTING_LOAD_BALANCER_ID" \
    --backend-set-name "$SELF_HEALING_EXISTING_BACKEND_SET_NAME" \
    --query data.status --raw-output)"
echo "Self-Healing: current existing backend-set health is $health"
