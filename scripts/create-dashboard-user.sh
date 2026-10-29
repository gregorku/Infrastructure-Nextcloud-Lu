#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' "Usage: ./scripts/create-dashboard-user.sh"
    exit 0
fi
[[ $# -eq 0 ]] || fail "Usage: ./scripts/create-dashboard-user.sh"
print_header "Dashboard BasicAuth"
check_environment
require_command htpasswd
mkdir -p "${DATA_DIR}/traefik/users"
read -rp "Username [admin]: " username
username="${username:-admin}"
[[ "${username}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "Unsupported username."
htpasswd -cB "${HTPASSWD_FILE}" "${username}"
chmod 600 "${HTPASSWD_FILE}"
ok "Credentials stored in ${HTPASSWD_FILE}. The password was not logged."
