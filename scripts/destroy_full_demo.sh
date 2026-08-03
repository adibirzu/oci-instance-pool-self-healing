#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

TF_ROOT="$PROJECT_ROOT/infra/full_demo"
STATE_KEY="${SELF_HEALING_DEMO_STATE_KEY:-self-healing-full-demo}"
STATE_DIR="${SELF_HEALING_STATE_ROOT:-$PROJECT_ROOT/.state/terraform}/$STATE_KEY"
TF_STATE="$STATE_DIR/terraform.tfstate"
TFVARS="$STATE_DIR/self_healing-seven.auto.tfvars.json"
DESTROY_PLAN="$STATE_DIR/self_healing-seven-destroy.tfplan"
export TF_DATA_DIR="$STATE_DIR/.terraform"
[[ -f "$TF_STATE" ]] || { echo "Self-Healing seven-service: nothing to destroy"; exit 0; }

terraform -chdir="$TF_ROOT" plan -destroy -input=false \
    -state="$TF_STATE" -var-file="$TFVARS" -out="$DESTROY_PLAN"
if ! is_truthy "${SELF_HEALING_DEMO_DESTROY_APPROVED:-false}"; then
    echo "Self-Healing seven-service: destroy plan saved; set SELF_HEALING_DEMO_DESTROY_APPROVED=true to apply"
    exit 0
fi
terraform -chdir="$TF_ROOT" apply -input=false -auto-approve \
    -state="$TF_STATE" "$DESTROY_PLAN"
echo "Self-Healing seven-service: all Terraform-owned synthetic resources destroyed"
