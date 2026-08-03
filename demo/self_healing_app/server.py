#!/usr/bin/env python3
"""Tenant-neutral local application for demonstrating backend replacement."""

from __future__ import annotations

import argparse
import json
import os
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SERVICES = ("atlas", "birch", "cedar", "delta", "ember", "fjord", "grove")
STEPS = (
    ("UNHEALTHY", "Load Balancer health check failed"),
    ("DRAINED", "Backend removed from traffic"),
    ("REPLACEMENT_REQUESTED", "Remediation Function preserved desired capacity"),
    ("TERMINATED", "Faulty disposable instance and volumes deleted"),
    ("PROVISIONING", "Instance Pool launched replacement"),
    ("HEALTHY", "Replacement passed /healthz and rejoined"),
)


class DemoState:
    def __init__(self, audit_path: Path, step_delay: float = 0.12):
        self.audit_path, self.step_delay, self.lock = (
            audit_path,
            step_delay,
            threading.Lock(),
        )
        self.services = {
            name: {
                "state": "HEALTHY",
                "generation": 1,
                "desired": 3 if name in {"atlas", "cedar"} else 2,
            }
            for name in SERVICES
        }
        self.events: list[dict[str, object]] = []
        self._record(
            "SYSTEM_READY", "Local synthetic replacement demonstrator ready", "system"
        )

    def _record(self, status: str, message: str, service: str) -> None:
        event = {
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "service": service,
            "status": status,
            "message": message,
        }
        with self.lock:
            self.events.append(event)
            self.events[:] = self.events[-40:]
            self.audit_path.parent.mkdir(parents=True, exist_ok=True)
            with self.audit_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(event, sort_keys=True) + "\n")

    def snapshot(self) -> dict[str, object]:
        with self.lock:
            return {
                "services": {key: dict(value) for key, value in self.services.items()},
                "events": list(reversed(self.events)),
            }

    def fail(self, service: str) -> bool:
        with self.lock:
            if (
                service not in self.services
                or self.services[service]["state"] != "HEALTHY"
            ):
                return False
            self.services[service] = dict(
                self.services[service], state="FAILURE_INJECTED"
            )
        self._record(
            "FAILURE_INJECTED", "Approved application health failure started", service
        )
        threading.Thread(target=self._replace, args=(service,), daemon=True).start()
        return True

    def _replace(self, service: str) -> None:
        for status, message in STEPS:
            time.sleep(self.step_delay)
            with self.lock:
                current = dict(self.services[service])
                if status == "HEALTHY":
                    current["generation"] = int(current["generation"]) + 1
                current["state"] = status
                self.services[service] = current
            self._record(status, message, service)


HTML = """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Self-Healing Backend Demo</title>
<style>:root{--ink:#172033;--muted:#667085;--line:#d9e0ea;--blue:#2457c5;--green:#137a48;--red:#b42318;--bg:#f5f7fb}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px system-ui,-apple-system,sans-serif}.wrap{max-width:1180px;margin:auto;padding:36px}h1{font-size:32px;margin:0 0 8px}.lead{color:var(--muted);margin:0 0 28px}.grid{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:10px}.card,.panel{background:#fff;border:1px solid var(--line);border-radius:12px;box-shadow:0 3px 12px #102a4310}.card{padding:14px;min-width:0}.name{text-transform:capitalize;font-weight:700}.state{font-size:12px;font-weight:800;margin:10px 0;color:var(--green);overflow-wrap:anywhere}.bad{color:var(--red)}button{border:0;border-radius:8px;background:var(--blue);color:white;padding:9px 11px;font-weight:700;cursor:pointer;width:100%}.meta{font-size:12px;color:var(--muted)}.panel{margin-top:20px;padding:20px}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:9px;border-bottom:1px solid var(--line)}th{font-size:12px;color:var(--muted)}code{font-size:12px}.pill{display:inline-block;background:#e8f5ee;color:var(--green);padding:4px 8px;border-radius:999px;font-weight:700}@media(max-width:900px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.wrap{padding:20px}}</style></head>
<body><main class="wrap"><span class="pill">LOCAL SYNTHETIC DEMO</span><h1>Automatic backend replacement</h1><p class="lead">Inject one safe application-health failure and watch the Load Balancer, alarm, Function, and Instance Pool converge.</p><section id="services" class="grid" aria-label="Synthetic backend services"></section><section class="panel"><h2>Audit timeline</h2><table><thead><tr><th>Time (UTC)</th><th>Service</th><th>Status</th><th>Audited event</th></tr></thead><tbody id="events"></tbody></table></section></main>
<script>async function refresh(){const d=await fetch('/api/state').then(r=>r.json());services.innerHTML=Object.entries(d.services).map(([n,s])=>`<article class="card"><div class="name">${n}</div><div class="state ${s.state==='HEALTHY'?'':'bad'}">${s.state}</div><div class="meta">desired ${s.desired} · generation ${s.generation}</div><button data-service="${n}" ${s.state==='HEALTHY'?'':'disabled'}>Fail one instance</button></article>`).join('');events.innerHTML=d.events.map(e=>`<tr><td><code>${e.timestamp}</code></td><td>${e.service}</td><td>${e.status}</td><td>${e.message}</td></tr>`).join('');document.querySelectorAll('button[data-service]').forEach(b=>b.onclick=()=>fetch('/api/fail?service='+b.dataset.service,{method:'POST'}).then(refresh));}refresh();setInterval(refresh,150);</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    state: DemoState

    def _send(self, status: int, payload: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/":
            self._send(HTTPStatus.OK, HTML.encode(), "text/html; charset=utf-8")
        elif path == "/healthz":
            self._send(HTTPStatus.OK, b"healthy\n", "text/plain")
        elif path == "/api/state":
            self._send(
                HTTPStatus.OK,
                json.dumps(self.state.snapshot()).encode(),
                "application/json",
            )
        else:
            self._send(HTTPStatus.NOT_FOUND, b"not found\n", "text/plain")

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        service = parse_qs(parsed.query).get("service", [""])[0]
        if parsed.path != "/api/fail" or not self.state.fail(service):
            self._send(HTTPStatus.CONFLICT, b'{"accepted":false}', "application/json")
            return
        self._send(HTTPStatus.ACCEPTED, b'{"accepted":true}', "application/json")

    def log_message(self, _format: str, *_args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8042)
    parser.add_argument(
        "--audit-path",
        type=Path,
        default=Path(
            os.getenv("DEMO_AUDIT_PATH", "/tmp/self-healing-demo-audit.jsonl")
        ),
    )
    parser.add_argument("--step-delay", type=float, default=0.12)
    args = parser.parse_args()
    Handler.state = DemoState(args.audit_path, args.step_delay)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
