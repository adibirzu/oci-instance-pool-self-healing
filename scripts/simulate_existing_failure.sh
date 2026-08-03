#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

if ! is_truthy "${SELF_HEALING_SIMULATION_APPROVED:-false}"; then
    echo "Self-Healing: set SELF_HEALING_SIMULATION_APPROVED=true for the controlled health-failure test" >&2
    exit 2
fi

TF_ROOT="$PROJECT_ROOT/infra/existing_resources"
state_key="${SELF_HEALING_STATE_KEY:-self_healing}"
[[ "$state_key" =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
STATE_DIR="${SELF_HEALING_STATE_ROOT:-$PROJECT_ROOT/.state/terraform}/$state_key"
TF_STATE="$STATE_DIR/terraform.tfstate"
export TF_DATA_DIR="$STATE_DIR/.terraform"
tfvars="$STATE_DIR/self_healing.auto.tfvars.json"
if [[ -f "$tfvars" ]] && python3 - "$tfvars" <<'PY'
import json
import sys

values = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if values.get("existing_instance_pool_id") else 1)
PY
then
    echo "Self-Healing: demo fault injection is disabled for non-owned existing pools" >&2
    echo "Self-Healing: use the application team's approved running-instance health drill" >&2
    exit 2
fi
pool_id="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw instance_pool_id)"
lb_id="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw load_balancer_id)"
backend_set="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw backend_set_name)"
instance_id="$(oci_cli compute-management instance-pool list-instances \
    --compartment-id "$OCI_COMPARTMENT_ID" --instance-pool-id "$pool_id" \
    --query 'data[0].id' --raw-output)"
[[ -n "$instance_id" && "$instance_id" != "null" ]] || { echo "Self-Healing: no pool member found" >&2; exit 1; }

command_payload="$(mktemp /tmp/self_healing-health-failure.XXXXXX.json)"
trap 'rm -f "$command_payload"' EXIT
python3 - "$command_payload" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(
        {
            "source": {
                "sourceType": "TEXT",
                "text": "set -e\nprintf 'unhealthy\\n' > /opt/self_healing/healthy\n",
            }
        },
        stream,
    )
PY
chmod 600 "$command_payload"
command_id="$(oci_cli instance-agent command create \
    --compartment-id "$OCI_COMPARTMENT_ID" \
    --display-name self_healing-controlled-health-failure \
    --timeout-in-seconds 120 \
    --target "{\"instanceId\":\"$instance_id\"}" \
    --content "file://$command_payload" \
    --query data.id --raw-output)"
command_state=""
for _attempt in $(seq 1 36); do
    command_state="$(oci_cli instance-agent command-execution get \
        --command-id "$command_id" --instance-id "$instance_id" \
        --query 'data."lifecycle-state"' --raw-output)"
    [[ "$command_state" == "SUCCEEDED" ]] && break
    [[ "$command_state" =~ ^(FAILED|TIMED_OUT|CANCELED)$ ]] && break
    sleep 5
done
[[ "$command_state" == "SUCCEEDED" ]] || {
    echo "Self-Healing: controlled health failure command ended in $command_state" >&2
    exit 1
}
echo "Self-Healing: one running backend was made unhealthy; polling for its replacement"
desired_pool_size="$(oci_cli compute-management instance-pool get \
    --instance-pool-id "$pool_id" --query data.size --raw-output)"
for _attempt in $(seq 1 60); do
    pool_state="$(oci_cli compute-management instance-pool get \
        --instance-pool-id "$pool_id" --query 'data."lifecycle-state"' --raw-output)"
    pool_size="$(oci_cli compute-management instance-pool get \
        --instance-pool-id "$pool_id" --query data.size --raw-output)"
    backend_health="$(oci_cli lb backend-set-health get \
        --load-balancer-id "$lb_id" --backend-set-name "$backend_set" \
        --query data.status --raw-output)"
    current_ids="$(oci_cli compute-management instance-pool list-instances \
        --compartment-id "$OCI_COMPARTMENT_ID" --instance-pool-id "$pool_id" \
        --query 'data[].id' --raw-output)"
    if [[ "$pool_state" == "RUNNING" && "$pool_size" == "$desired_pool_size" \
        && "$backend_health" == "OK" ]] \
        && ! printf '%s' "$current_ids" | grep -q "$instance_id"; then
        echo "Self-Healing: replacement verified and desired pool size preserved"
        exit 0
    fi
    sleep 15
done
echo "Self-Healing: replacement did not converge within 15 minutes" >&2
exit 1
