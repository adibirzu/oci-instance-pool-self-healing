#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

TF_ROOT="$PROJECT_ROOT/infra/existing_resources"
state_key="${SELF_HEALING_STATE_KEY:-self_healing}"
[[ "$state_key" =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
STATE_DIR="${SELF_HEALING_STATE_ROOT:-$PROJECT_ROOT/.state/terraform}/$state_key"
TF_STATE="$STATE_DIR/terraform.tfstate"
export TF_DATA_DIR="$STATE_DIR/.terraform"
[[ -f "$TF_STATE" ]] || { echo "Self-Healing: Terraform state not found" >&2; exit 2; }

pool_id="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw instance_pool_id)"
lb_id="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw load_balancer_id)"
backend_set="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw backend_set_name)"

pool_state=""
health=""
for _attempt in $(seq 1 80); do
    pool_state="$(oci_cli compute-management instance-pool get \
        --instance-pool-id "$pool_id" --query 'data."lifecycle-state"' --raw-output)"
    health="$(oci_cli lb backend-set-health get \
        --load-balancer-id "$lb_id" --backend-set-name "$backend_set" \
        --query data.status --raw-output)"
    [[ "$pool_state" == "RUNNING" && "$health" == "OK" ]] && break
    sleep 15
done
pool_size="$(oci_cli compute-management instance-pool get --instance-pool-id "$pool_id" --query 'data.size' --raw-output)"

[[ "$pool_state" == "RUNNING" ]] || { echo "Self-Healing: pool is not RUNNING" >&2; exit 1; }
[[ "$health" == "OK" ]] || { echo "Self-Healing: backend set health is $health" >&2; exit 1; }
echo "Self-Healing: verified pool RUNNING with desired size $pool_size and backend health OK"
