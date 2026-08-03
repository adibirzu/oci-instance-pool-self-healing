#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

TF_ROOT="$PROJECT_ROOT/infra/full_demo"
CONFIG="${SELF_HEALING_DEMO_CONFIG:-$PROJECT_ROOT/config/seven_service.example.json}"
STATE_KEY="${SELF_HEALING_DEMO_STATE_KEY:-self-healing-full-demo}"
[[ "$STATE_KEY" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Self-Healing seven-service: invalid state key" >&2
    exit 2
}
STATE_DIR="${SELF_HEALING_STATE_ROOT:-$PROJECT_ROOT/.state/terraform}/$STATE_KEY"
TF_STATE="$STATE_DIR/terraform.tfstate"
TFVARS="$STATE_DIR/self_healing-seven.auto.tfvars.json"
BASE_PLAN="$STATE_DIR/self_healing-seven-base.tfplan"
FULL_PLAN="$STATE_DIR/self_healing-seven-full.tfplan"
FUNCTION_DIR="$PROJECT_ROOT/functions/health_remediator"
export TF_DATA_DIR="$STATE_DIR/.terraform"

required=(OCI_TENANCY_ID OCI_REGION OCI_COMPARTMENT_ID)
for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || {
        echo "Self-Healing seven-service: required variable $name is missing" >&2
        exit 2
    }
done
[[ -f "$CONFIG" ]] || { echo "Self-Healing seven-service: topology config not found" >&2; exit 2; }

python3 "$PROJECT_ROOT/scripts/topology.py" --config "$CONFIG" validate >/dev/null
mkdir -p "$STATE_DIR"
auth_mode="$(resolve_auth_mode "${OCI_AUTH_MODE:-auto}")"
tf_auth_mode="APIKey"
case "$auth_mode" in
    security_token) tf_auth_mode="SecurityToken" ;;
    instance_principal) tf_auth_mode="InstancePrincipal" ;;
    resource_principal) tf_auth_mode="ResourcePrincipal" ;;
esac
export SELF_HEALING_DEMO_TF_AUTH_MODE="$tf_auth_mode"

python3 - "$CONFIG" "$TFVARS" <<'PY'
import json
import os
import pathlib
import sys

source = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if source.get("deployment_mode") != "managed-full-stack":
    raise SystemExit("Self-Healing seven-service: config must use managed-full-stack")
services = {}
for item in source["services"]:
    capacity = item["capacity"]
    remediation = item["remediation"]
    services[item["id"]] = {
        "backend_set_name": item["backend_set_name"],
        "backend_port": item["backend_port"],
        "health_path": item["health_path"],
        "min_size": capacity["min"],
        "initial_size": capacity["initial"],
        "max_size": capacity["max"],
        "cooldown_seconds": capacity["cooldown_seconds"],
        "min_healthy": remediation["min_healthy"],
        "max_replacements": remediation["max_replacements"],
        "replacement_window_secs": remediation["window_seconds"],
        "capacity_reservation": item["capacity_reservation"],
    }
path = pathlib.Path(sys.argv[2])
previous = {}
if path.exists():
    try:
        previous = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
values = {
    "tenancy_ocid": os.environ["OCI_TENANCY_ID"],
    "compartment_id": os.environ["OCI_COMPARTMENT_ID"],
    "region": os.environ["OCI_REGION"],
    "config_file_profile": os.environ.get("OCI_CONFIG_PROFILE", "DEFAULT"),
    "auth_mode": os.environ["SELF_HEALING_DEMO_TF_AUTH_MODE"],
    "name_prefix": os.environ.get("SELF_HEALING_DEMO_NAME_PREFIX", "self-healing-demo"),
    "allowed_client_cidr": os.environ.get("SELF_HEALING_DEMO_ALLOWED_CLIENT_CIDR", "10.0.0.0/8"),
    "instance_shape": os.environ.get("SELF_HEALING_DEMO_INSTANCE_SHAPE", "VM.Standard.E5.Flex"),
    "instance_ocpus": int(os.environ.get("SELF_HEALING_DEMO_INSTANCE_OCPUS", "1")),
    "instance_memory_gbs": int(os.environ.get("SELF_HEALING_DEMO_INSTANCE_MEMORY_GBS", "2")),
    "operations_email": os.environ.get("SELF_HEALING_DEMO_OPERATIONS_EMAIL", ""),
    "function_mode": os.environ.get("SELF_HEALING_DEMO_FUNCTION_MODE", "observe"),
    "enable_function": bool(previous.get("enable_function", False)),
    "function_image": previous.get("function_image", ""),
    "services": services,
}
path.write_text(json.dumps(values), encoding="utf-8")
PY
chmod 600 "$TFVARS"

terraform -chdir="$TF_ROOT" init -input=false
terraform -chdir="$TF_ROOT" plan -input=false -state="$TF_STATE" \
    -var-file="$TFVARS" -out="$BASE_PLAN"
if ! is_truthy "${SELF_HEALING_DEMO_APPLY_APPROVED:-false}"; then
    echo "Self-Healing seven-service: reviewed base plan saved; set SELF_HEALING_DEMO_APPLY_APPROVED=true to apply"
    exit 0
fi
terraform -chdir="$TF_ROOT" apply -input=false -auto-approve \
    -state="$TF_STATE" "$BASE_PLAN"

image_ref="${SELF_HEALING_DEMO_FUNCTION_IMAGE:-}"
if [[ -z "$image_ref" ]]; then
    image_ref="$(python3 - "$TFVARS" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream).get("function_image", ""))
PY
)"
fi
if [[ -z "$image_ref" ]]; then
    repository="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw container_repository_path)"
    registry="${repository%%/*}"
    namespace="$(oci_cli os ns get --query data --raw-output)"
    user_name="${SELF_HEALING_OCIR_USER_NAME:-}"
    auth_token="${SELF_HEALING_OCIR_AUTH_TOKEN:-${OCIR_AUTH_TOKEN:-}}"
    [[ -n "$user_name" && -n "$auth_token" ]] || {
        echo "Self-Healing seven-service: OCIR username and auth token are required for the Function image" >&2
        exit 2
    }
    printf '%s' "$auth_token" | docker login "$registry" \
        --username "${namespace}/${user_name}" --password-stdin >/dev/null
    image_ref="${repository}:$(date -u +%Y%m%d%H%M%S)"
    docker buildx build --platform linux/amd64 --push \
        --tag "$image_ref" "$FUNCTION_DIR"
fi

python3 - "$TFVARS" "$image_ref" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
values = json.loads(path.read_text(encoding="utf-8"))
values["enable_function"] = True
values["function_image"] = sys.argv[2]
path.write_text(json.dumps(values), encoding="utf-8")
PY
chmod 600 "$TFVARS"
terraform -chdir="$TF_ROOT" plan -input=false -state="$TF_STATE" \
    -var-file="$TFVARS" -out="$FULL_PLAN"
if ! is_truthy "${SELF_HEALING_DEMO_FUNCTION_APPLY_APPROVED:-false}"; then
    echo "Self-Healing seven-service: Function plan saved; set SELF_HEALING_DEMO_FUNCTION_APPLY_APPROVED=true to apply"
    exit 0
fi
terraform -chdir="$TF_ROOT" apply -input=false -auto-approve \
    -state="$TF_STATE" "$FULL_PLAN"
echo "Self-Healing seven-service: complete Terraform-owned test stack applied"
