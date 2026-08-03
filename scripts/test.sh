#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

terraform fmt -check -recursive "$ROOT/infra"
for module in existing_resources full_demo; do
    terraform -chdir="$ROOT/infra/$module" init -backend=false -input=false
    terraform -chdir="$ROOT/infra/$module" validate
done

bash -n "$ROOT"/scripts/*.sh
python3 -m pytest -q "$ROOT/tests"
python3 "$ROOT/scripts/topology.py" \
    --config "$ROOT/config/seven_service.example.json" simulate >/dev/null

if rg -n -i --glob '!scripts/test.sh' 'ocid1\.|@oracle\.com|/Users/|/private/tmp/' \
    "$ROOT/README.md" "$ROOT/docs" "$ROOT/config" "$ROOT/demo" "$ROOT/infra" \
    "$ROOT/functions" "$ROOT/scripts"; then
    echo "Privacy scan found a forbidden repository-specific or tenant-specific marker" >&2
    exit 1
fi

echo "All offline end-to-end validation passed; no OCI tenancy was contacted."
