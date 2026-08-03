"""End-to-end contracts for the tenant-neutral replacement demo app."""

from __future__ import annotations
import importlib.util
import json
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "demo" / "self_healing_app" / "server.py"


def _module():
    spec = importlib.util.spec_from_file_location("self_healing_demo", APP)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def test_demo_replaces_failed_member_and_preserves_capacity():
    module = _module()
    with tempfile.TemporaryDirectory() as directory:
        audit = Path(directory) / "audit.jsonl"
        state = module.DemoState(audit, step_delay=0.001)
        before = state.snapshot()["services"]["atlas"]
        assert state.fail("atlas") is True
        deadline = time.time() + 2
        while time.time() < deadline:
            after = state.snapshot()["services"]["atlas"]
            if after["state"] == "HEALTHY" and after["generation"] == 2:
                break
            time.sleep(0.005)
        assert (
            after["desired"] == before["desired"]
            and after["generation"] == before["generation"] + 1
        )
        statuses = [
            json.loads(line)["status"] for line in audit.read_text().splitlines()
        ]
        assert statuses[-6:] == [status for status, _ in module.STEPS]


def test_demo_artifacts_are_synthetic_and_privacy_safe():
    text = APP.read_text()
    forbidden = ("ocid1.", "@oracle.com", "/Users/", "/private/tmp/")
    assert not any(value.lower() in text.lower() for value in forbidden)
    assert all(
        service in text
        for service in ("atlas", "birch", "cedar", "delta", "ember", "fjord", "grove")
    )
