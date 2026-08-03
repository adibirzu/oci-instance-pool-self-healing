"""Offline end-to-end tests for the operator shell workflows."""

from __future__ import annotations

import json
import os
import stat
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


OCI_STUB = r"""#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
joined = " ".join(args)
if "compute-management instance-pool get" in joined:
    if "data.size" in joined:
        print("2")
    elif "lifecycle-state" in joined:
        print("RUNNING")
    else:
        print(json.dumps({"lifecycle-state":"RUNNING","size":2,"load-balancers":[{"load-balancer-id":"synthetic-lb","backend-set-name":"synthetic-backends"}]}))
elif "lb load-balancer get" in joined:
    print("ACTIVE")
elif "lb backend-set-health get" in joined:
    print("OK")
elif "lb backend-set get" in joined:
    print(json.dumps({"health-checker":{"protocol":"HTTP"}}))
elif "compute-management instance-pool list-instances" in joined:
    print("synthetic-old-instance" if "data[0].id" in joined else '["synthetic-new-instance"]')
elif "instance-agent command create" in joined:
    print("synthetic-command")
elif "instance-agent command-execution get" in joined:
    print("SUCCEEDED")
elif "logging log list" in joined:
    print("3")
else:
    raise SystemExit("unexpected OCI command: " + joined)
"""


TERRAFORM_STUB = r"""#!/usr/bin/env python3
import json, pathlib, sys
args = sys.argv[1:]
if "output" in args:
    name = args[-1]
    values = {
        "instance_pool_id": "synthetic-pool",
        "load_balancer_id": "synthetic-lb",
        "backend_set_name": "synthetic-backends",
        "log_group_id": "synthetic-log-group",
        "instance_pool_ids": {name: "synthetic-pool-" + name for name in ["atlas", "birch", "cedar", "delta", "ember", "fjord", "grove"]},
        "backend_set_names": {name: "synthetic-backends-" + name for name in ["atlas", "birch", "cedar", "delta", "ember", "fjord", "grove"]},
    }
    value = values[name]
    print(json.dumps(value) if "-json" in args else value)
    raise SystemExit
for arg in sys.argv[1:]:
    if arg.startswith("-out="):
        path = pathlib.Path(arg.split("=", 1)[1])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("synthetic reviewed plan")
print("Terraform synthetic command accepted")
"""


def _executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _environment(tmp_path: Path) -> dict[str, str]:
    binary_dir = tmp_path / "bin"
    binary_dir.mkdir()
    _executable(binary_dir / "oci", OCI_STUB)
    _executable(binary_dir / "terraform", TERRAFORM_STUB)
    return {
        **os.environ,
        "PATH": f"{binary_dir}:{os.environ['PATH']}",
        "OCI_CONFIG_PROFILE": "SYNTHETIC",
        "OCI_TENANCY_ID": "synthetic-tenancy",
        "OCI_COMPARTMENT_ID": "synthetic-compartment",
        "OCI_REGION": "synthetic-region",
        "OCI_PRIVATE_SUBNET_ID": "synthetic-private-subnet",
        "SELF_HEALING_EXISTING_INSTANCE_POOL_ID": "synthetic-pool",
        "SELF_HEALING_EXISTING_LOAD_BALANCER_ID": "synthetic-lb",
        "SELF_HEALING_EXISTING_BACKEND_SET_NAME": "synthetic-backends",
        "SELF_HEALING_STATE_ROOT": str(tmp_path / "state"),
        "SELF_HEALING_STATE_KEY": "existing-e2e",
        "SELF_HEALING_DEMO_STATE_KEY": "full-demo-e2e",
    }


def test_existing_resource_validation_and_plan_workflow(tmp_path):
    env = _environment(tmp_path)
    validation = subprocess.run(
        [str(ROOT / "scripts" / "validate_existing_resources.sh")],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    assert "existing topology validated" in validation.stdout
    assert "health is OK" in validation.stdout

    deployment = subprocess.run(
        [str(ROOT / "scripts" / "deploy_existing.sh")],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    assert "reviewed plan saved" in deployment.stdout
    tfvars = tmp_path / "state" / "existing-e2e" / "self_healing.auto.tfvars.json"
    values = json.loads(tfvars.read_text())
    assert values["existing_instance_pool_id"] == "synthetic-pool"
    assert values["existing_load_balancer_id"] == "synthetic-lb"
    assert values["enable_function"] is False

    function_plan = subprocess.run(
        [str(ROOT / "scripts" / "deploy_existing.sh")],
        cwd=ROOT,
        env={
            **env,
            "SELF_HEALING_APPLY_APPROVED": "true",
            "SELF_HEALING_FUNCTION_IMAGE": "synthetic.registry/functions/remediator:test",
        },
        check=True,
        capture_output=True,
        text=True,
    )
    assert "Function plan saved" in function_plan.stdout

    applied = subprocess.run(
        [str(ROOT / "scripts" / "deploy_existing.sh")],
        cwd=ROOT,
        env={
            **env,
            "SELF_HEALING_APPLY_APPROVED": "true",
            "SELF_HEALING_FUNCTION_APPLY_APPROVED": "true",
            "SELF_HEALING_FUNCTION_IMAGE": "synthetic.registry/functions/remediator:test",
        },
        check=True,
        capture_output=True,
        text=True,
    )
    assert "infrastructure and Function applied" in applied.stdout

    state = tmp_path / "state" / "existing-e2e" / "terraform.tfstate"
    state.write_text("{}")
    verification = subprocess.run(
        [str(ROOT / "scripts" / "verify_existing.sh")],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    assert "backend health OK" in verification.stdout

    destruction = subprocess.run(
        [str(ROOT / "scripts" / "destroy_existing.sh")],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    assert "destroy plan saved" in destruction.stdout

    blocked_drill = subprocess.run(
        [str(ROOT / "scripts" / "simulate_existing_failure.sh")],
        cwd=ROOT,
        env={**env, "SELF_HEALING_SIMULATION_APPROVED": "true"},
        capture_output=True,
        text=True,
    )
    assert blocked_drill.returncode == 2
    assert "disabled for non-owned existing pools" in blocked_drill.stderr


def test_full_demo_plan_workflow_is_offline_and_approval_gated(tmp_path):
    env = _environment(tmp_path)
    deployment = subprocess.run(
        [str(ROOT / "scripts" / "deploy_full_demo.sh")],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    assert "reviewed base plan saved" in deployment.stdout
    tfvars = (
        tmp_path / "state" / "full-demo-e2e" / "self_healing-seven.auto.tfvars.json"
    )
    values = json.loads(tfvars.read_text())
    assert len(values["services"]) == 7
    assert values["enable_function"] is False
    assert values["name_prefix"] == "self-healing-demo"

    function_plan = subprocess.run(
        [str(ROOT / "scripts" / "deploy_full_demo.sh")],
        cwd=ROOT,
        env={
            **env,
            "SELF_HEALING_DEMO_APPLY_APPROVED": "true",
            "SELF_HEALING_DEMO_FUNCTION_IMAGE": "synthetic.registry/functions/remediator:test",
        },
        check=True,
        capture_output=True,
        text=True,
    )
    assert "Function plan saved" in function_plan.stdout

    applied = subprocess.run(
        [str(ROOT / "scripts" / "deploy_full_demo.sh")],
        cwd=ROOT,
        env={
            **env,
            "SELF_HEALING_DEMO_APPLY_APPROVED": "true",
            "SELF_HEALING_DEMO_FUNCTION_APPLY_APPROVED": "true",
            "SELF_HEALING_DEMO_FUNCTION_IMAGE": "synthetic.registry/functions/remediator:test",
        },
        check=True,
        capture_output=True,
        text=True,
    )
    assert "complete Terraform-owned test stack applied" in applied.stdout

    state = tmp_path / "state" / "full-demo-e2e" / "terraform.tfstate"
    state.write_text("{}")
    verification = subprocess.run(
        [str(ROOT / "scripts" / "verify_full_demo.sh")],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    assert verification.stdout.count("backend health OK") == 7
    assert "access/error logs active" in verification.stdout

    values["function_mode"] = "remediate"
    tfvars.write_text(json.dumps(values))
    drill = subprocess.run(
        [str(ROOT / "scripts" / "simulate_full_demo_failure.sh")],
        cwd=ROOT,
        env={**env, "SELF_HEALING_DEMO_SIMULATION_APPROVED": "true"},
        check=True,
        capture_output=True,
        text=True,
    )
    assert "replacement converged" in drill.stdout

    destruction = subprocess.run(
        [str(ROOT / "scripts" / "destroy_full_demo.sh")],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    assert "destroy plan saved" in destruction.stdout
