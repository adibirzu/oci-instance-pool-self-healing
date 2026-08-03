"""End-to-end contracts for the synthetic seven-service Self-Healing topology."""

from __future__ import annotations

import json
import importlib.util
import subprocess
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace


ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "config" / "seven_service.example.json"
SCRIPT = ROOT / "scripts" / "topology.py"
FUNCTION = ROOT / "functions" / "health_remediator" / "func.py"


def run_topology(*args: str) -> dict:
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--config", str(CONFIG), *args],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def load_function():
    fdk = ModuleType("fdk")
    fdk.response = SimpleNamespace(Response=object)
    sys.modules.setdefault("fdk", fdk)
    spec = importlib.util.spec_from_file_location("test_remediator", FUNCTION)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FakeNosql:
    def __init__(self):
        self.rows = {}

    def update_row(self, _table_id, details):
        value = details.value
        key = value["event_key"]
        if details.option == "IF_ABSENT" and key in self.rows:
            import oci

            raise oci.exceptions.ServiceError(
                status=409,
                code="RowAlreadyExists",
                headers={},
                message="synthetic duplicate",
            )
        self.rows[key] = value
        return SimpleNamespace(data=SimpleNamespace(version="synthetic-version"))

    def get_row(self, _table_id, key, consistency):
        assert consistency == "ABSOLUTE"
        return SimpleNamespace(data=SimpleNamespace(value=self.rows.get(key[0], {})))


class FakeLoadBalancer:
    def __init__(self, unhealthy_backend):
        self.unhealthy_backend = unhealthy_backend

    def get_backend_set_health(self, load_balancer_id, backend_set_name):
        assert load_balancer_id == "synthetic-lb"
        assert backend_set_name.startswith("synthetic_")
        return SimpleNamespace(
            data=SimpleNamespace(
                critical_state_backend_names=[self.unhealthy_backend],
                warning_state_backend_names=[],
            )
        )


class FakeCompute:
    def __init__(self, service_id, desired_size):
        self.pool_id = f"synthetic-{service_id}-pool"
        self.desired_size = desired_size
        self.detach_calls = []
        self.members = [
            SimpleNamespace(
                id=f"synthetic-{service_id}-instance-{index}",
                state="RUNNING",
                load_balancer_backends=[
                    SimpleNamespace(
                        backend_name=f"10.42.{desired_size}.{index}:synthetic"
                    )
                ],
            )
            for index in range(desired_size)
        ]

    def get_instance_pool(self, pool_id):
        assert pool_id == self.pool_id
        return SimpleNamespace(data=SimpleNamespace(lifecycle_state="RUNNING"))

    def list_instance_pool_instances(self, compartment_id, instance_pool_id, **_kwargs):
        assert compartment_id == "synthetic-compartment"
        assert instance_pool_id == self.pool_id
        return SimpleNamespace(
            data=self.members,
            next_page=None,
            has_next_page=False,
            status=200,
            headers={},
            request=SimpleNamespace(),
        )

    def detach_instance_pool_instance(self, pool_id, details, opc_retry_token):
        assert pool_id == self.pool_id
        assert details.is_auto_terminate is True
        assert details.is_decrement_size is False
        assert opc_retry_token
        self.detach_calls.append(details.instance_id)
        return SimpleNamespace()


def test_synthetic_fixture_has_seven_independent_services_and_no_real_data():
    topology = json.loads(CONFIG.read_text(encoding="utf-8"))
    services = topology["services"]

    assert topology["topology_name"] == "synthetic-seven-service-lab"
    assert len(services) == 7
    assert len({item["id"] for item in services}) == 7
    assert len({item["backend_set_name"] for item in services}) == 7
    assert topology["deployment_mode"] == "managed-full-stack"
    assert all(item["health_path"] == "/healthz" for item in services)
    assert all(item["capacity"]["min"] >= 2 for item in services)

    rendered = CONFIG.read_text(encoding="utf-8")
    assert "ocid1." not in rendered
    assert "@oracle.com" not in rendered
    assert ".png" not in rendered


def test_validate_returns_a_redacted_topology_summary():
    summary = run_topology("validate")

    assert summary["status"] == "VALID"
    assert summary["service_count"] == 7
    assert summary["load_balancer"]["kind"] == "OCI_LOAD_BALANCER"
    assert summary["load_balancer"]["visibility"] == "private"
    assert summary["notification"]["protocol"] == "EMAIL"
    assert all("pool_id" not in service for service in summary["services"])


def test_plan_maps_every_service_to_one_managed_stack_state():
    plan = run_topology("plan")

    assert plan["status"] == "PLANNED"
    assert len(plan["actions"]) == 7
    assert {action["state_key"] for action in plan["actions"]} == {
        "synthetic-seven-service-lab"
    }
    assert all(action["function_mode"] == "observe" for action in plan["actions"])
    assert all(
        action["ownership_mode"] == "managed-full-stack" for action in plan["actions"]
    )


def test_end_to_end_simulation_replaces_exactly_one_member_per_service():
    report = run_topology("simulate")

    assert report["status"] == "PASS"
    assert report["scenarios"] == 7
    assert report["replacements_requested"] == 7
    assert report["duplicate_actions"] == 0
    for service in report["services"]:
        assert service["alarm"] == "FIRING"
        assert service["lb_removed_unhealthy_backend"] is True
        assert service["function_result"] == "REPLACEMENT_REQUESTED"
        assert service["duplicate_result"] == "IGNORED"
        assert service["desired_size_preserved"] is True
        assert service["replacement_health"] == "OK"


def test_production_function_logic_runs_end_to_end_for_all_synthetic_services(
    monkeypatch,
):
    topology = json.loads(CONFIG.read_text(encoding="utf-8"))
    function = load_function()
    monkeypatch.setattr(function, "MODE", "remediate")
    monkeypatch.setattr(function, "COMPARTMENT_ID", "synthetic-compartment")
    monkeypatch.setattr(function, "LOAD_BALANCER_ID", "synthetic-lb")
    monkeypatch.setattr(function, "STATE_TABLE_ID", "synthetic-state-table")
    monkeypatch.setattr(function, "STATE_TABLE_NAME", "synthetic_state")

    for service in topology["services"]:
        desired = service["capacity"]["initial"]
        compute = FakeCompute(service["id"], desired)
        unhealthy_name = compute.members[0].load_balancer_backends[0].backend_name
        lb = FakeLoadBalancer(unhealthy_name)
        nosql = FakeNosql()
        monkeypatch.setattr(function, "INSTANCE_POOL_ID", compute.pool_id)
        monkeypatch.setattr(function, "BACKEND_SET_NAME", service["backend_set_name"])
        monkeypatch.setattr(
            function,
            "MIN_HEALTHY_BACKENDS",
            service["remediation"]["min_healthy"],
        )
        monkeypatch.setattr(
            function,
            "MAX_REPLACEMENTS_PER_WINDOW",
            service["remediation"]["max_replacements"],
        )
        monkeypatch.setattr(
            function,
            "REPLACEMENT_WINDOW_SECONDS",
            service["remediation"]["window_seconds"],
        )
        event = {
            "type": "FIRING",
            "dedupekey": f"synthetic-{service['id']}-alarm",
            "timestampEpochMillis": "424242",
        }

        first = function.remediate(event, clients=(lb, compute, nosql))
        duplicate = function.remediate(event, clients=(lb, compute, nosql))

        assert first["status"] == "REPLACEMENT_REQUESTED"
        assert duplicate == {
            "status": "IGNORED",
            "reason": "duplicate alarm delivery",
        }
        assert len(compute.detach_calls) == 1
        assert len(compute.members) == desired


def test_destroy_plan_is_scoped_to_the_complete_managed_stack():
    plan = run_topology("destroy-plan")

    assert plan["status"] == "DESTROY_PLANNED"
    assert len(plan["actions"]) == 1
    assert all(
        action["destroys_existing_resources"] is False for action in plan["actions"]
    )
    assert all(
        action["approval_env"] == "SELF_HEALING_DEMO_DESTROY_APPROVED"
        for action in plan["actions"]
    )


def test_manual_use_case_maps_console_code_lifecycle_and_privacy():
    document = (ROOT / "docs" / "SEVEN_SERVICE_USE_CASE.md").read_text(encoding="utf-8")
    for heading in (
        "## Repository artifacts and code mapping",
        "## Run the local simulation",
        "## End-to-end OCI Console procedure",
        "## Terraform and CI/CD workflow",
        "## Destroy and rollback",
        "## Evidence and privacy checklist",
    ):
        assert heading in document
    for marker in (
        "MODE=observe",
        "SELF_HEALING_DEMO_STATE_KEY",
        "SELF_HEALING_DEMO_DESTROY_APPROVED",
        "unhealthyBackendServers",
        "ORACLE_FUNCTIONS",
        "linux/amd64",
    ):
        assert marker in document
    assert "ocid1." not in document
    assert "@oracle.com" not in document
    assert ".png" not in document


def test_managed_full_stack_declares_every_required_oci_resource():
    root = ROOT / "infra" / "full_demo"
    main = (root / "main.tf").read_text(encoding="utf-8")
    variables = (root / "variables.tf").read_text(encoding="utf-8")
    outputs = (root / "outputs.tf").read_text(encoding="utf-8")

    for resource in (
        "oci_core_vcn",
        "oci_core_subnet",
        "oci_core_nat_gateway",
        "oci_core_network_security_group",
        "oci_load_balancer_load_balancer",
        "oci_load_balancer_backend_set",
        "oci_load_balancer_listener",
        "oci_core_instance_configuration",
        "oci_core_instance_pool",
        "oci_autoscaling_auto_scaling_configuration",
        "oci_artifacts_container_repository",
        "oci_functions_application",
        "oci_functions_function",
        "oci_nosql_table",
        "oci_ons_notification_topic",
        "oci_ons_subscription",
        "oci_monitoring_alarm",
        "oci_logging_log_group",
        "oci_logging_log",
        "oci_identity_dynamic_group",
        "oci_identity_policy",
    ):
        assert f'resource "{resource}"' in main
    assert "is_private                 = true" in main
    assert "for_each" in main
    assert 'variable "services"' in variables
    assert 'output "instance_pool_ids"' in outputs


def test_full_stack_persists_function_and_load_balancer_audit_logs():
    main = (ROOT / "infra" / "full_demo" / "main.tf").read_text()
    function = FUNCTION.read_text()
    assert 'service     = "loadbalancer"' in main
    assert 'category    = "access"' in main
    assert 'category    = "error"' in main
    assert "retention_duration = var.log_retention_days" in main
    assert "SERVICE_NAME" in main
    assert '"event_type": "self_healing_decision"' in function
    assert "resource_fingerprint" in function


def test_operator_readme_has_lifecycle_costs_and_sanitized_evidence():
    readme = ROOT / "infra" / "full_demo" / "README.md"
    text = readme.read_text()
    for required in (
        "Architecture",
        "Service capabilities",
        "Deploy",
        "Verify",
        "Failure and replacement drill",
        "Destroy",
        "OCI Logging",
        "Observability BOM",
        "Manual Console implementation",
        "Local evidence",
    ):
        assert required in text
    for image in ("test-suite.png", "demo-failure.png", "demo-recovered.png"):
        assert image in text
    forbidden = ("/Users/", "/private/tmp/")
    assert not any(value.lower() in text.lower() for value in forbidden)


def test_managed_full_stack_has_complete_reviewed_lifecycle_scripts():
    expected = (
        "deploy_full_demo.sh",
        "verify_full_demo.sh",
        "simulate_full_demo_failure.sh",
        "destroy_full_demo.sh",
    )
    for filename in expected:
        text = (ROOT / "scripts" / filename).read_text(encoding="utf-8")
        assert "full_demo" in text
    deploy = (ROOT / "scripts" / expected[0]).read_text(encoding="utf-8")
    destroy = (ROOT / "scripts" / expected[-1]).read_text(encoding="utf-8")
    assert "SELF_HEALING_DEMO_APPLY_APPROVED" in deploy
    assert "linux/amd64" in deploy
    assert "SELF_HEALING_DEMO_DESTROY_APPROVED" in destroy
    assert "plan -destroy" in destroy
    verify = (ROOT / "scripts" / expected[1]).read_text(encoding="utf-8")
    assert "logging log list" in verify
    assert "expected three active OCI Logging service logs" in verify
