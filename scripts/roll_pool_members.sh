#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

TF_ROOT="$PROJECT_ROOT/infra/existing_resources"
state_key="${SELF_HEALING_STATE_KEY:-self_healing}"
[[ "$state_key" =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
STATE_DIR="${SELF_HEALING_STATE_ROOT:-$PROJECT_ROOT/.state/terraform}/$state_key"
TF_STATE="$STATE_DIR/terraform.tfstate"
export TF_DATA_DIR="$STATE_DIR/.terraform"
pool_id="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw instance_pool_id)"
lb_id="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw load_balancer_id)"
backend_set="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw backend_set_name)"
target_configuration_id="$(oci_cli compute-management instance-pool get \
    --instance-pool-id "$pool_id" \
    --query 'data."instance-configuration-id"' --raw-output)"

old_ids=()
roll_all="${SELF_HEALING_ROLL_ALL:-false}"
while IFS= read -r instance_id; do
    [[ -n "$instance_id" ]] && old_ids+=("$instance_id")
done < <(oci_cli compute-management instance-pool list-instances \
    --compartment-id "$OCI_COMPARTMENT_ID" --instance-pool-id "$pool_id" \
    --query data --output json | python3 -c '
import json, sys
roll_all = sys.argv[1].lower() in {"1", "true", "yes"}
target_configuration_id = sys.argv[2]
for member in json.load(sys.stdin):
    backends = member.get("load-balancer-backends") or []
    if (
        roll_all
        and member.get("instance-configuration-id") != target_configuration_id
    ) or (
        backends and backends[0].get("backend-health-status") == "CRITICAL"
    ):
        print(member["id"])
' "$roll_all" "$target_configuration_id")

index=0
if [[ "${#old_ids[@]}" -eq 0 ]]; then
    echo "Self-Healing: no pool members matched the roll criteria"
    exit 0
fi
for instance_id in "${old_ids[@]}"; do
    oci_cli compute-management instance-pool-instance detach \
        --instance-pool-id "$pool_id" --instance-id "$instance_id" \
        --is-auto-terminate true --is-decrement-size false \
        --wait-for-state SUCCEEDED --max-wait-seconds 1200 >/dev/null
    converged=false
    for _attempt in $(seq 1 80); do
        current="$(oci_cli compute-management instance-pool list-instances \
            --compartment-id "$OCI_COMPARTMENT_ID" --instance-pool-id "$pool_id" \
            --query 'data[].id' --raw-output)"
        backend_status="$(oci_cli lb backend-set-health get \
            --load-balancer-id "$lb_id" --backend-set-name "$backend_set" \
            --query data.status --raw-output)"
        pool_status="$(oci_cli compute-management instance-pool get \
            --instance-pool-id "$pool_id" \
            --query 'data."lifecycle-state"' --raw-output)"
        if ! printf '%s' "$current" | grep -q "$instance_id" \
            && [[ "$pool_status" == "RUNNING" ]] \
            && [[ "$backend_status" == "OK" || "$backend_status" == "WARNING" ]]; then
            converged=true
            break
        fi
        sleep 15
    done
    [[ "$converged" == "true" ]] || {
        echo "Self-Healing: rolling replacement failed to converge" >&2
        exit 1
    }
    index=$((index + 1))
done
echo "Self-Healing: rolled ${#old_ids[@]} pool members onto the corrected configuration"
