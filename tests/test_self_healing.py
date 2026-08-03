"""Static contracts for the reusable OCI self-healing implementation."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_complete_lifecycle_scripts_are_present():
    expected = {
        "deploy_existing.sh",
        "verify_existing.sh",
        "validate_existing_resources.sh",
        "simulate_existing_failure.sh",
        "destroy_existing.sh",
        "deploy_full_demo.sh",
        "verify_full_demo.sh",
        "simulate_full_demo_failure.sh",
        "destroy_full_demo.sh",
        "test.sh",
    }
    assert expected <= {path.name for path in (ROOT / "scripts").glob("*.sh")}


def test_function_preserves_pool_size_and_fails_closed():
    handler = (ROOT / "functions" / "health_remediator" / "func.py").read_text()
    for marker in (
        "is_auto_terminate=True",
        "is_decrement_size=False",
        "opc_retry_token",
        "MIN_HEALTHY_BACKENDS",
        "MAX_REPLACEMENTS_PER_WINDOW",
        "dedupekey",
        "REMEDIATION_BLOCKED",
        '"event_type": "self_healing_decision"',
        "resource_fingerprint",
    ):
        assert marker in handler


def test_existing_resource_mode_is_dependency_only():
    root = ROOT / "infra" / "existing_resources"
    variables = (root / "variables.tf").read_text()
    main = (root / "main.tf").read_text()
    deploy = (ROOT / "scripts" / "deploy_existing.sh").read_text()

    for marker in (
        'variable "existing_instance_pool_id"',
        'variable "existing_backend_set_name"',
        "existing_resources_are_complete",
        "local.create_instance_pool ? 1 : 0",
        "local.instance_pool_id",
        "local.backend_set_name",
    ):
        assert marker in variables + main
    assert "validate_existing_resources.sh" in deploy
    assert "refusing to change Terraform state ownership mode" in deploy
    assert "SELF_HEALING_STATE_KEY" in deploy
    assert not (root / "moved.tf").exists()


def test_existing_mode_destroy_is_reviewed_and_state_scoped():
    destroy = (ROOT / "scripts" / "destroy_existing.sh").read_text()
    assert "terraform" in destroy
    assert "plan -destroy" in destroy
    assert "SELF_HEALING_DESTROY_APPROVED" in destroy
    assert "terraform.tfstate" in destroy


def test_manual_existing_resource_runbook_is_complete():
    runbook = (ROOT / "docs" / "MANUAL_EXISTING_RESOURCES.md").read_text()
    for section in (
        "## Supported adoption boundary",
        "## Console procedure",
        "## CLI procedure",
        "## IAM policy",
        "## Validate before remediation",
        "## Rollback and removal",
    ):
        assert section in runbook
    for marker in (
        "<EXISTING_INSTANCE_POOL_OCID>",
        "MODE=observe",
        "./scripts/validate_existing_resources.sh",
        "./scripts/deploy_existing.sh",
        "./scripts/destroy_existing.sh",
    ):
        assert marker in runbook


def test_scripts_use_generic_inputs_and_explicit_approval_gates():
    deploy = (ROOT / "scripts" / "deploy_existing.sh").read_text()
    full = (ROOT / "scripts" / "deploy_full_demo.sh").read_text()
    for marker in (
        "OCI_TENANCY_ID",
        "OCI_COMPARTMENT_ID",
        "OCI_PRIVATE_SUBNET_ID",
        "SELF_HEALING_OPERATIONS_EMAIL",
        "SELF_HEALING_APPLY_APPROVED",
    ):
        assert marker in deploy
    assert "SELF_HEALING_DEMO_APPLY_APPROVED" in full
    assert "SELF_HEALING_FUNCTION_APPLY_APPROVED" in deploy
    assert "SELF_HEALING_DEMO_FUNCTION_APPLY_APPROVED" in full
    assert "linux/amd64" in full


def test_publishable_text_has_no_internal_environment_references():
    forbidden = ("ocid1.", "@oracle.com", "/Users/", "/private/tmp/")
    paths = [
        ROOT / "README.md",
        *ROOT.glob("docs/*.md"),
        *(path for path in ROOT.glob("scripts/*.sh") if path.name != "test.sh"),
    ]
    for path in paths:
        text = path.read_text()
        for marker in forbidden:
            assert marker not in text, f"{marker!r} found in {path}"


def test_all_oci_cli_calls_are_routed_through_the_wrapper():
    common = (ROOT / "scripts" / "common.sh").read_text()
    assert "oci_cli()" in common
    for script in (ROOT / "scripts").glob("*.sh"):
        if script.name == "common.sh":
            continue
        text = script.read_text()
        assert "command oci " not in text


def test_documentation_links_reference_existing_repository_files():
    for path in (
        ROOT / "README.md",
        ROOT / "infra" / "full_demo" / "README.md",
    ):
        text = path.read_text()
        base = path.parent
        for relative in (
            "docs/MANUAL_EXISTING_RESOURCES.md"
            if path == ROOT / "README.md"
            else "../../docs/MANUAL_EXISTING_RESOURCES.md",
            "docs/assets/self_healing/test-suite.png"
            if path == ROOT / "README.md"
            else "../../docs/assets/self_healing/test-suite.png",
        ):
            assert (base / relative).resolve().is_file()
            assert relative in text
