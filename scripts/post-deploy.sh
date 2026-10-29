#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/env.sh"
source "${SCRIPT_DIR}/lib/deploy.sh"

print_header "Post-deploy"
check_environment
require_command docker
env_load_runtime
post_deploy_crowdsec
post_deploy_record_version "${RUNTIME_ENV[NEXTCLOUD_TAG]}"
print_footer "Post-deploy completed."
