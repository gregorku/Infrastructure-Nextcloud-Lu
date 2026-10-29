#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/env.sh"

print_header "Check environment"
check_environment
env_load_runtime
if [[ "${RUNTIME_ENV[PROXY_PROTOCOL_MODE]}" == "local" ]]; then
    warn "PROXY protocol is off. Traefik will see the TCP peer, not an internet client."
    warn "Switch PROXY_PROTOCOL_MODE to haproxy only after the VPS source /32 is known."
fi
if [[ "${RUNTIME_ENV[TRAEFIK_TLS_MODE]}" == "letsencrypt" ]]; then
    warn "HTTP-01 will not issue a certificate until public port 80 reaches this Traefik."
fi
if [[ -z "${RUNTIME_ENV[TRAEFIK_ADMIN_PUBLISH]}" ]]; then
    info "Admin entrypoint is not published on the host."
fi
ok "Environment checks passed."
