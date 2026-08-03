#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

is_truthy "${SELF_HEALING_DEMO_SIMULATION_APPROVED:-false}" || {
    echo "Self-Healing seven-service: set SELF_HEALING_DEMO_SIMULATION_APPROVED=true" >&2
    exit 2
}
TF_ROOT="$PROJECT_ROOT/infra/full_demo"
STATE_KEY="${SELF_HEALING_DEMO_STATE_KEY:-self-healing-full-demo}"
STATE_DIR="${SELF_HEALING_STATE_ROOT:-$PROJECT_ROOT/.state/terraform}/$STATE_KEY"
TF_STATE="$STATE_DIR/terraform.tfstate"
TFVARS="$STATE_DIR/self_healing-seven.auto.tfvars.json"
export TF_DATA_DIR="$STATE_DIR/.terraform"
service="${SELF_HEALING_DEMO_FAILURE_SERVICE:-atlas}"

python3 - "$TFVARS" "$service" <<'PY'
import json, pathlib, sys
values = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if values.get("function_mode") != "remediate":
    raise SystemExit("Self-Healing seven-service: Function mode must be remediate for replacement drill")
if sys.argv[2] not in values.get("services", {}):
    raise SystemExit("Self-Healing seven-service: unknown synthetic service")
PY
pool_map="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -json instance_pool_ids)"
backend_map="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -json backend_set_names)"
pool_id="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$service" <<<"$pool_map")"
backend_set="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$service" <<<"$backend_map")"
lb_id="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw load_balancer_id)"
instance_id="$(oci_cli compute-management instance-pool list-instances \
    --compartment-id "$OCI_COMPARTMENT_ID" --instance-pool-id "$pool_id" \
    --query 'data[0].id' --raw-output)"
desired_size="$(oci_cli compute-management instance-pool get --instance-pool-id "$pool_id" \
    --query data.size --raw-output)"

payload="$(mktemp /tmp/self_healing-seven-health-failure.XXXXXX.json)"
trap 'rm -f "$payload"' EXIT
python3 - "$payload" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "source": {"sourceType": "TEXT", "text": "set -e\nprintf 'unhealthy\\n' > /opt/self_healing/healthy\n"}
}), encoding="utf-8")
PY
chmod 600 "$payload"
command_id="$(oci_cli instance-agent command create \
    --compartment-id "$OCI_COMPARTMENT_ID" --display-name self_healing-synthetic-health-failure \
    --timeout-in-seconds 120 --target "{\"instanceId\":\"$instance_id\"}" \
    --content "file://$payload" --query data.id --raw-output)"
for _attempt in $(seq 1 36); do
    state="$(oci_cli instance-agent command-execution get --command-id "$command_id" \
        --instance-id "$instance_id" --query 'data."lifecycle-state"' --raw-output)"
    [[ "$state" == "SUCCEEDED" ]] && break
    [[ "$state" =~ ^(FAILED|TIMED_OUT|CANCELED)$ ]] && exit 1
    sleep 5
done
[[ "$state" == "SUCCEEDED" ]] || exit 1

for _attempt in $(seq 1 60); do
    pool_size="$(oci_cli compute-management instance-pool get --instance-pool-id "$pool_id" --query data.size --raw-output)"
    health="$(oci_cli lb backend-set-health get --load-balancer-id "$lb_id" \
        --backend-set-name "$backend_set" --query data.status --raw-output)"
    current_ids="$(oci_cli compute-management instance-pool list-instances \
        --compartment-id "$OCI_COMPARTMENT_ID" --instance-pool-id "$pool_id" \
        --query 'data[].id' --raw-output)"
    if [[ "$pool_size" == "$desired_size" && "$health" == "OK" ]] \
        && ! grep -Fq "$instance_id" <<<"$current_ids"; then
        echo "Self-Healing seven-service: $service replacement converged and desired size was preserved"
        exit 0
    fi
    sleep 15
done
echo "Self-Healing seven-service: replacement did not converge within 15 minutes" >&2
exit 1
