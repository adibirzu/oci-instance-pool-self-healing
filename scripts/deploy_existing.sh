#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

TF_ROOT="$PROJECT_ROOT/infra/existing_resources"
state_key="${SELF_HEALING_STATE_KEY:-self_healing}"
[[ "$state_key" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Self-Healing: SELF_HEALING_STATE_KEY contains unsupported characters" >&2
    exit 2
}
STATE_DIR="${SELF_HEALING_STATE_ROOT:-$PROJECT_ROOT/.state/terraform}/$state_key"
TF_STATE="$STATE_DIR/terraform.tfstate"
TF_DATA_DIR="$STATE_DIR/.terraform"
TFVARS="$STATE_DIR/self_healing.auto.tfvars.json"
PLAN_FILE="$STATE_DIR/self_healing.tfplan"
FULL_PLAN_FILE="$STATE_DIR/self_healing-full.tfplan"
FUNCTION_DIR="$PROJECT_ROOT/functions/health_remediator"
export TF_DATA_DIR

required=(
    OCI_TENANCY_ID OCI_REGION OCI_COMPARTMENT_ID OCI_PRIVATE_SUBNET_ID
    SELF_HEALING_EXISTING_INSTANCE_POOL_ID
    SELF_HEALING_EXISTING_LOAD_BALANCER_ID
    SELF_HEALING_EXISTING_BACKEND_SET_NAME
)
for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || { echo "Self-Healing: required variable $name is missing" >&2; exit 2; }
done
"$SCRIPT_DIR/validate_existing_resources.sh"

mkdir -p "$STATE_DIR"
auth_mode="$(resolve_auth_mode "${OCI_AUTH_MODE:-auto}")"
tf_auth_mode="APIKey"
case "$auth_mode" in
    security_token) tf_auth_mode="SecurityToken" ;;
    instance_principal) tf_auth_mode="InstancePrincipal" ;;
    resource_principal) tf_auth_mode="ResourcePrincipal" ;;
esac
export SELF_HEALING_TF_AUTH_MODE="$tf_auth_mode"
python3 - "$TFVARS" "$TF_STATE" <<'PY'
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
state_path = pathlib.Path(sys.argv[2])
previous = {}
if path.exists():
    try:
        previous = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        previous = {}
requested_existing_pool = os.environ.get("SELF_HEALING_EXISTING_INSTANCE_POOL_ID", "")
previous_existing_pool = previous.get("existing_instance_pool_id", "")
if state_path.exists() and bool(requested_existing_pool) != bool(previous_existing_pool):
    raise SystemExit(
        "Self-Healing: refusing to change Terraform state ownership mode; "
        "select a fresh SELF_HEALING_STATE_KEY"
    )
values = {
    "tenancy_ocid": os.environ["OCI_TENANCY_ID"],
    "compartment_id": os.environ["OCI_COMPARTMENT_ID"],
    "region": os.environ["OCI_REGION"],
    "config_file_profile": os.environ.get("OCI_CONFIG_PROFILE", "DEFAULT"),
    "auth_mode": os.environ["SELF_HEALING_TF_AUTH_MODE"],
    "public_subnet_id": os.environ.get("OCI_LOAD_BALANCER_SUBNET_ID", ""),
    "private_subnet_id": os.environ["OCI_PRIVATE_SUBNET_ID"],
    "existing_load_balancer_id": os.environ.get("SELF_HEALING_EXISTING_LOAD_BALANCER_ID", ""),
    "existing_instance_pool_id": requested_existing_pool,
    "existing_backend_set_name": os.environ.get("SELF_HEALING_EXISTING_BACKEND_SET_NAME", ""),
    "name_prefix": os.environ.get("SELF_HEALING_NAME_PREFIX", "oci-self-healing"),
    "backend_port": int(os.environ.get("SELF_HEALING_BACKEND_PORT", "8080")),
    "listener_port": int(os.environ.get("SELF_HEALING_LISTENER_PORT", "80")),
    "pool_initial_size": int(os.environ.get("SELF_HEALING_POOL_INITIAL_SIZE", "2")),
    "pool_min_size": int(os.environ.get("SELF_HEALING_POOL_MIN_SIZE", "2")),
    "pool_max_size": int(os.environ.get("SELF_HEALING_POOL_MAX_SIZE", "3")),
    "autoscaling_cooldown_seconds": int(
        os.environ.get("SELF_HEALING_AUTOSCALING_COOLDOWN_SECONDS", "300")
    ),
    "operations_email": os.environ.get("SELF_HEALING_OPERATIONS_EMAIL", ""),
    "min_healthy_backends": int(os.environ.get("SELF_HEALING_MIN_HEALTHY_BACKENDS", "1")),
    "max_replacements_per_window": int(
        os.environ.get("SELF_HEALING_MAX_REPLACEMENTS_PER_WINDOW", "2")
    ),
    "replacement_window_seconds": int(
        os.environ.get("SELF_HEALING_REPLACEMENT_WINDOW_SECONDS", "1800")
    ),
    "function_mode": os.environ.get(
        "SELF_HEALING_FUNCTION_MODE",
        previous.get("function_mode", "observe"),
    ),
    "enable_function": bool(previous.get("enable_function", False)),
    "function_image": previous.get("function_image", ""),
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(values, stream)
PY
chmod 600 "$TFVARS"

terraform -chdir="$TF_ROOT" init -input=false
terraform -chdir="$TF_ROOT" plan -input=false -out="$PLAN_FILE" \
    -state="$TF_STATE" -var-file="$TFVARS"

if ! is_truthy "${SELF_HEALING_APPLY_APPROVED:-false}"; then
    echo "Self-Healing: reviewed plan saved; set SELF_HEALING_APPLY_APPROVED=true to apply it"
    exit 0
fi

terraform -chdir="$TF_ROOT" apply -input=false -auto-approve \
    -state="$TF_STATE" "$PLAN_FILE"

image_ref="${SELF_HEALING_FUNCTION_IMAGE:-}"
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
    docker_auth_configured="$(python3 - "$registry" <<'PY'
import json, pathlib, sys
try:
    data = json.loads((pathlib.Path.home() / ".docker/config.json").read_text())
except Exception:
    print("false")
    raise SystemExit
auths = data.get("auths") or {}
helpers = data.get("credHelpers") or {}
print(str(sys.argv[1] in auths or sys.argv[1] in helpers).lower())
PY
    )"
    if [[ "$docker_auth_configured" != "true" ]]; then
        user_name="${SELF_HEALING_OCIR_USER_NAME:-}"
        username="${SELF_HEALING_OCIR_USERNAME:-${namespace}/${user_name}}"
        auth_token="${SELF_HEALING_OCIR_AUTH_TOKEN:-${OCIR_AUTH_TOKEN:-${STREAMING_AUTH_TOKEN:-}}}"
        [[ -n "$auth_token" && -n "$user_name" ]] || {
            echo "Self-Healing: OCIR username/auth token is required to deploy the Function" >&2
            exit 2
        }
        printf '%s' "$auth_token" | docker login "$registry" \
            --username "$username" --password-stdin >/dev/null
    else
        echo "Self-Healing: reusing an existing Docker credential for the target OCIR registry"
    fi
    image_ref="${repository}:$(date -u +%Y%m%d%H%M%S)"
    docker buildx build --platform linux/amd64 --push \
        --tag "$image_ref" "$FUNCTION_DIR"
fi

python3 - "$TFVARS" "$image_ref" <<'PY'
import json, sys
path, image = sys.argv[1:3]
with open(path, encoding="utf-8") as stream:
    values = json.load(stream)
values["enable_function"] = True
values["function_image"] = image
with open(path, "w", encoding="utf-8") as stream:
    json.dump(values, stream)
PY
chmod 600 "$TFVARS"
terraform -chdir="$TF_ROOT" plan -input=false -out="$FULL_PLAN_FILE" \
    -state="$TF_STATE" -var-file="$TFVARS"
if ! is_truthy "${SELF_HEALING_FUNCTION_APPLY_APPROVED:-false}"; then
    echo "Self-Healing: Function plan saved; set SELF_HEALING_FUNCTION_APPLY_APPROVED=true to apply it"
    exit 0
fi
terraform -chdir="$TF_ROOT" apply -input=false -auto-approve \
    -state="$TF_STATE" "$FULL_PLAN_FILE"
echo "Self-Healing: complete self-healing infrastructure and Function applied"
