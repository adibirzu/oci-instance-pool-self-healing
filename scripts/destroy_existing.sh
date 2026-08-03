#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

TF_ROOT="$PROJECT_ROOT/infra/existing_resources"
state_key="${SELF_HEALING_STATE_KEY:-self_healing}"
[[ "$state_key" =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
STATE_DIR="${SELF_HEALING_STATE_ROOT:-$PROJECT_ROOT/.state/terraform}/$state_key"
TF_STATE="$STATE_DIR/terraform.tfstate"
TFVARS="$STATE_DIR/self_healing.auto.tfvars.json"
DESTROY_PLAN="$STATE_DIR/self_healing-destroy.tfplan"
export TF_DATA_DIR="$STATE_DIR/.terraform"
[[ -f "$TF_STATE" ]] || { echo "Self-Healing: nothing to destroy"; exit 0; }

# Lifecycle contract: terraform plan -destroy followed by terraform apply.
terraform -chdir="$TF_ROOT" plan -destroy -input=false \
    -state="$TF_STATE" -var-file="$TFVARS" -out="$DESTROY_PLAN"
if ! is_truthy "${SELF_HEALING_DESTROY_APPROVED:-false}"; then
    echo "Self-Healing: destroy plan saved; set SELF_HEALING_DESTROY_APPROVED=true to apply it"
    exit 0
fi
terraform -chdir="$TF_ROOT" apply -input=false -auto-approve \
    -state="$TF_STATE" "$DESTROY_PLAN"
echo "Self-Healing: Terraform-managed resources destroyed"
