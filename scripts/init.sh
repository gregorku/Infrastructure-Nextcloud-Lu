#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/common.sh"

print_header "Infrastructure-Nextcloud-Lu initialization"
check_environment
require_mountpoint "${DOCKER_DATA_DIR}"
mkdir -p "${STACK_DIR}" "${DATA_DIR}" "${BACKUP_LOCAL_DIR}"
source "${SCRIPT_DIR}/lib/deploy.sh"
deploy_sync_stack
print_footer "Initialization completed. Next: ./scripts/update-env.sh"
