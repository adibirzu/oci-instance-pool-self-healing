#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

TF_ROOT="$PROJECT_ROOT/infra/full_demo"
STATE_KEY="${SELF_HEALING_DEMO_STATE_KEY:-self-healing-full-demo}"
STATE_DIR="${SELF_HEALING_STATE_ROOT:-$PROJECT_ROOT/.state/terraform}/$STATE_KEY"
TF_STATE="$STATE_DIR/terraform.tfstate"
export TF_DATA_DIR="$STATE_DIR/.terraform"
[[ -f "$TF_STATE" ]] || { echo "Self-Healing seven-service: Terraform state not found" >&2; exit 2; }

pool_map="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -json instance_pool_ids)"
backend_map="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -json backend_set_names)"
lb_id="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw load_balancer_id)"
log_group_id="$(terraform -chdir="$TF_ROOT" output -state="$TF_STATE" -raw log_group_id)"
services="$(python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.stdin.read()))))' <<<"$backend_map")"

for service in $services; do
    pool_id="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$service" <<<"$pool_map")"
    backend_set="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$service" <<<"$backend_map")"
    pool_state=""
    health=""
    for _attempt in $(seq 1 80); do
        pool_state="$(oci_cli compute-management instance-pool get \
            --instance-pool-id "$pool_id" --query 'data."lifecycle-state"' --raw-output)"
        health="$(oci_cli lb backend-set-health get --load-balancer-id "$lb_id" \
            --backend-set-name "$backend_set" --query data.status --raw-output)"
        [[ "$pool_state" == "RUNNING" && "$health" == "OK" ]] && break
        sleep 15
    done
    [[ "$pool_state" == "RUNNING" && "$health" == "OK" ]] || {
        echo "Self-Healing seven-service: $service did not converge" >&2
        exit 1
    }
    echo "Self-Healing seven-service: $service pool RUNNING and backend health OK"
done

active_logs="$(oci_cli logging log list --log-group-id "$log_group_id" \
    --query 'length(data[?"is-enabled" == `true`])' --raw-output)"
[[ "$active_logs" == "3" ]] || {
    echo "Self-Healing seven-service: expected three active OCI Logging service logs" >&2
    exit 1
}
echo "Self-Healing seven-service: Function invocation and Load Balancer access/error logs active"
