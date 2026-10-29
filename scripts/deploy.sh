#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/env.sh"
source "${SCRIPT_DIR}/lib/deploy.sh"

print_header "Deploy Infrastructure-Nextcloud-Lu"
check_environment
require_command docker
deploy_sync_stack
env_load_runtime
deploy_assert_version "${RUNTIME_ENV[NEXTCLOUD_TAG]}"
deploy_prepare_storage
deploy_ensure_networks
deploy_render_runtime
deploy_check_dockge
deploy_compose
deploy_postgres_role
print_footer "Deployment completed. Next: ./scripts/post-deploy.sh"
