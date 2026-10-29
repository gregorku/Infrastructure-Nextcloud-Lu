#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/env.sh"

print_header "Update runtime environment"
check_environment
[[ -d "${STACK_DIR}" ]] || fail "Stack directory is missing. Run ./scripts/init.sh first."
[[ -f "${STACK_DIR}/.env.example" ]] || fail "Stack is missing .env.example. Run ./scripts/init.sh."
env_sync_file "${STACK_DIR}/.env.example" "${ENV_FILE}"
ok "Runtime .env updated. Generated secrets were not printed."
print_footer "Next: replace remaining set_ values, create the dashboard user, then ./scripts/check-env.sh"
