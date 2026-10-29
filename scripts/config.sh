#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly PROJECT_NAME="Infrastructure-Nextcloud-Lu"
readonly STACK_NAME="infrastructure-nextcloud-lu"

SCRIPT_DIR_RESOLVED="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR_RESOLVED}/.." && pwd)"
readonly GIT_DIR="${REPO_ROOT}"

readonly BASE_DIR="/docker-data"
readonly DATA_DIR="${BASE_DIR}/infrastructure-nextcloud-lu"
readonly DOCKER_DATA_DIR="${BASE_DIR}"
readonly STACKS_DIR="${BASE_DIR}/stacks"
readonly STACK_DIR="${STACKS_DIR}/${STACK_NAME}"
readonly BACKUP_LOCAL_DIR="${BASE_DIR}/backups/${STACK_NAME}"

readonly COMPOSE_FILE="${STACK_DIR}/compose.yml"
readonly ENV_FILE="${STACK_DIR}/.env"
readonly ENV_EXAMPLE_FILE="${GIT_DIR}/.env.example"

readonly DEPLOY_ITEMS=(
    compose.yml
    compose
    configs
    .env.example
)

readonly NETWORK_PROXY="lu-proxy"
readonly NETWORK_INTERNAL="lu-internal"

readonly NEXTCLOUD_DOMAIN="ludek.serveftp.org"

readonly DOCKGE_CONTAINER="dockge"
readonly DOCKGE_PORT="5001"

readonly TRAEFIK_CONTAINER="lu-traefik"
readonly CROWDSEC_CONTAINER="lu-crowdsec"
readonly POSTGRESQL_CONTAINER="lu-postgresql"
readonly REDIS_CONTAINER="lu-redis"
readonly NEXTCLOUD_APP_CONTAINER="lu-nextcloud"
readonly NGINX_CONTAINER="lu-nginx"
readonly NEXTCLOUD_CRON_CONTAINER="lu-cron"
readonly METABASE_CONTAINER="lu-metabase"
readonly METABASE_POSTGRES_CONTAINER="lu-metabase-postgresql"

readonly CROWDSEC_BOUNCER_NAME="lu-traefik"
readonly BOUNCER_KEY_FILE="${DATA_DIR}/traefik/crowdsec/BOUNCER_KEY_lu-traefik"
readonly HTPASSWD_FILE="${DATA_DIR}/traefik/users/dashboard.htpasswd"
readonly ACME_FILE="${DATA_DIR}/traefik/acme/acme.json"

readonly NEXTCLOUD_STATE_DIR="${DATA_DIR}/state"
readonly INSTALLED_VERSION_FILE="${NEXTCLOUD_STATE_DIR}/installed-version"
readonly UPGRADE_LOCK_FILE="${NEXTCLOUD_STATE_DIR}/upgrade.lock"

readonly NEXTCLOUD_UID_GID="33:33"
readonly POSTGRESQL_UID_GID="999:999"
readonly REDIS_UID_GID="999:999"
readonly POSTGRES_BOOTSTRAP_USER="nc_bootstrap"

readonly LEGACY_APP_DIR="/docker/nextcloud/nextcloud_gregor/nextcloud_app"
readonly LEGACY_USER_DATA_DIR="/HDD/data-raid-HDD/Nextcloud-data/data-Gregor"
readonly LEGACY_MARIADB_DIR="/SDD/nvme-1T-btrf/nextcloud_gregor/mariadb/db_data"
readonly LEGACY_REDIS_DIR="/docker/nextcloud/nextcloud_gregor/redis/data"

readonly COLOR_RED="\033[0;31m"
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[1;33m"
readonly COLOR_BLUE="\033[0;34m"
readonly COLOR_RESET="\033[0m"
