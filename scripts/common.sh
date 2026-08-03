#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_DIR PROJECT_ROOT

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_auth_mode() {
    local requested="${1:-auto}"
    if [[ "$requested" != "auto" ]]; then
        printf '%s\n' "$requested"
    elif [[ -n "${OCI_RESOURCE_PRINCIPAL_VERSION:-}" ]]; then
        printf '%s\n' "resource_principal"
    elif [[ "${OCI_AUTH_MODE:-}" == "instance_principal" ]]; then
        printf '%s\n' "instance_principal"
    elif [[ "${OCI_AUTH_MODE:-}" == "security_token" ]]; then
        printf '%s\n' "security_token"
    else
        printf '%s\n' "api_key"
    fi
}

oci_cli() {
    local auth_mode
    auth_mode="$(resolve_auth_mode "${OCI_AUTH_MODE:-auto}")"
    case "$auth_mode" in
        resource_principal)
            command oci "$@" --auth resource_principal
            ;;
        instance_principal)
            command oci "$@" --auth instance_principal
            ;;
        security_token)
            command oci "$@" --auth security_token --profile "${OCI_CONFIG_PROFILE:-DEFAULT}"
            ;;
        api_key)
            command oci "$@" --profile "${OCI_CONFIG_PROFILE:-DEFAULT}"
            ;;
        *)
            echo "Unsupported OCI_AUTH_MODE: $auth_mode" >&2
            return 2
            ;;
    esac
}
