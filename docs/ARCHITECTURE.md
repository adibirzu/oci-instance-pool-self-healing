# Self-Healing — Self-Healing Load-Balanced Instance Pool

Self-Healing deploys an OCI Load Balancer, a private Compute instance pool, CPU
autoscaling, an unhealthy-backend alarm, Notifications, and an OCI Function
that can replace one unhealthy member while preserving the pool's desired size.

The Function defaults to `MODE=observe`. Promotion to `MODE=remediate` should
only occur after the alarm path and backend-to-instance mapping have been
verified. It refuses remediation unless the alarm is FIRING, the pool is
RUNNING, exactly one unhealthy backend maps to one pool member, sufficient
healthy capacity remains, the event is new, and the rolling replacement budget
has not been exhausted.

For a reusable seven-backend example with independent service capacities,
synthetic names, a deterministic local end-to-end simulation, complete Console
instructions, Terraform/code mapping, and privacy controls, see
[Self-Healing Seven-Service Synthetic Topology](SEVEN_SERVICE_USE_CASE.md).

The fully owned test stack is under `infra/full_demo/`. It creates
its VCN, three private subnets, NAT, NSGs, private OCI Load Balancer, seven
listeners and backend sets, seven instance pools and autoscaling policies,
OCIR repository, Function application and seven Functions, seven NoSQL state
tables, Notifications topics and subscriptions, email subscriptions when an
address is supplied, seven alarms, logging, dynamic group, and IAM policy.

```bash
./scripts/deploy_full_demo.sh
# Review the plan, then apply:
SELF_HEALING_DEMO_APPLY_APPROVED=true ./scripts/deploy_full_demo.sh
SELF_HEALING_DEMO_APPLY_APPROVED=true \
SELF_HEALING_DEMO_FUNCTION_APPLY_APPROVED=true ./scripts/deploy_full_demo.sh
./scripts/verify_full_demo.sh
```

The test stack defaults to `MODE=observe`. Use the dedicated failure script
only after explicitly changing the stack to remediation mode and approving the
drill. Destroy uses the same state and a separately reviewed destroy plan.

## Deploy and verify

Run the repository preflight for the target compartment, then:

```bash
./scripts/deploy_existing.sh
SELF_HEALING_APPLY_APPROVED=true ./scripts/deploy_existing.sh
SELF_HEALING_APPLY_APPROVED=true \
SELF_HEALING_FUNCTION_APPLY_APPROVED=true ./scripts/deploy_existing.sh
./scripts/verify_existing.sh
```

If Load Balancer limits prevent a dedicated LB, set
`SELF_HEALING_EXISTING_LOAD_BALANCER_ID` to an explicitly approved non-OKE LB. Self-Healing adds
its own listener and backend set; it does not adopt ownership of the LB.

To integrate with a pool and backend set that are already attached, set all
three non-owning inputs:

```bash
export SELF_HEALING_EXISTING_INSTANCE_POOL_ID="<EXISTING_INSTANCE_POOL_OCID>"
export SELF_HEALING_EXISTING_LOAD_BALANCER_ID="<EXISTING_LOAD_BALANCER_OCID>"
export SELF_HEALING_EXISTING_BACKEND_SET_NAME="<EXISTING_BACKEND_SET_NAME>"
./scripts/validate_existing_resources.sh
```

In this mode Terraform creates only the Self-Healing remediation control path. It does
not import, update, or destroy the existing pool, autoscaling configuration,
load balancer, listener, or backend set. See the complete
[manual existing-resource runbook](MANUAL_EXISTING_RESOURCES.md).

## Controlled failure test

```bash
SELF_HEALING_SIMULATION_APPROVED=true ./scripts/simulate_existing_failure.sh
```

The test uses OCI Run Command to mark one selected application's health endpoint
unhealthy while the VM remains running. It waits for the unhealthy-backend
alarm and remediation Function, and succeeds only after the old member
disappears, the replacement is healthy, and desired size is unchanged. This
matches the instance-pool detach API contract, which requires the member to
remain in the running state.

The demo failure script is intentionally disabled for existing pools because
their application health contract is not owned by Self-Healing. Use the existing
application team's approved running-instance failure method instead.

## Destroy

First create and review the exact destroy plan:

```bash
./scripts/destroy_existing.sh
```

Then apply that saved plan:

```bash
SELF_HEALING_DESTROY_APPROVED=true ./scripts/destroy_existing.sh
```

When an existing LB is reused, Terraform removes only Self-Healing's listener and
backend set; it never destroys the shared LB.

Repository acceptance separates deterministic offline workflow tests from a
target-specific OCI drill. The committed repository contains no tenancy identifiers,
raw live logs, Terraform state, or retained deployment coordinates.
