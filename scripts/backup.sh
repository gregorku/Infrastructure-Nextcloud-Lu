#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/env.sh"

print_header "Backup"
check_environment
require_command docker
env_load_runtime
mkdir -p "${BACKUP_LOCAL_DIR}"
chmod 700 "${BACKUP_LOCAL_DIR}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
stage="$(mktemp -d "${BACKUP_LOCAL_DIR}/stage-${stamp}.XXXXXX")"
chmod 700 "${stage}"
cleanup() { rm -rf "${stage}"; }
trap cleanup EXIT

docker exec -u www-data "${NEXTCLOUD_APP_CONTAINER}" php occ maintenance:mode --on
restore_mode() {
    docker exec -u www-data "${NEXTCLOUD_APP_CONTAINER}" php occ maintenance:mode --off || true
}
trap 'restore_mode; cleanup' EXIT

docker exec -e PGPASSWORD="${RUNTIME_ENV[PG_PASS]}" "${POSTGRESQL_CONTAINER}" \
    pg_dump -U "${RUNTIME_ENV[PG_USER]}" -d "${RUNTIME_ENV[PG_DB]}" -Fc \
    > "${stage}/nextcloud.dump"
dump_head="$(od -An -tx1 -N5 "${stage}/nextcloud.dump" | tr -d ' \n')"
[[ "${dump_head}" == "5047444d50" ]] || fail "Database dump does not start with PGDMP. No archive was published."

mkdir -p "${stage}/nextcloud"
for part in config custom_apps themes; do
    if [[ -d "${DATA_DIR}/html/${part}" ]]; then
        cp -a "${DATA_DIR}/html/${part}" "${stage}/nextcloud/${part}"
    fi
done
docker exec -e PGPASSWORD="${RUNTIME_ENV[METABASE_DB_PASSWORD]}" "${METABASE_POSTGRES_CONTAINER}" \
    pg_dump -U "${RUNTIME_ENV[METABASE_DB_USER]}" -d "${RUNTIME_ENV[METABASE_DB_NAME]}" -Fc \
    > "${stage}/metabase.dump"
meta_head="$(od -An -tx1 -N5 "${stage}/metabase.dump" | tr -d ' \n')"
[[ "${meta_head}" == "5047444d50" ]] || fail "Metabase dump does not start with PGDMP. No archive was published."

(
    cd "${stage}"
    sha256sum nextcloud.dump metabase.dump > SHA256SUMS
    tar -cf "${BACKUP_LOCAL_DIR}/${STACK_NAME}-${stamp}.tar" .
)
archive="${BACKUP_LOCAL_DIR}/${STACK_NAME}-${stamp}.tar"
tar -tf "${archive}" >/dev/null
ok "Unencrypted archive written: ${archive}"

if [[ -n "${RUNTIME_ENV[BACKUP_AGE_RECIPIENT]}" ]]; then
    require_command age
    age -r "${RUNTIME_ENV[BACKUP_AGE_RECIPIENT]}" -o "${archive}.age" "${archive}"
    ok "Age archive written. The identity key was not stored."
fi

if command -v restic >/dev/null 2>&1 && [[ -n "${RUNTIME_ENV[RESTIC_REPOSITORY]}" ]]; then
    RESTIC_PASSWORD="${RUNTIME_ENV[RESTIC_PASSWORD]}" restic -r "${RUNTIME_ENV[RESTIC_REPOSITORY]}" snapshots >/dev/null 2>&1 \
        || RESTIC_PASSWORD="${RUNTIME_ENV[RESTIC_PASSWORD]}" restic -r "${RUNTIME_ENV[RESTIC_REPOSITORY]}" init
    RESTIC_PASSWORD="${RUNTIME_ENV[RESTIC_PASSWORD]}" restic -r "${RUNTIME_ENV[RESTIC_REPOSITORY]}" backup \
        "${RUNTIME_ENV[NEXTCLOUD_DATA_HOST_DIR]}"
    ok "Restic snapshot created for Nextcloud user files."
else
    warn "Restic backup was skipped. The tar archive does not replace an off-site copy of user files."
fi

restore_mode
trap cleanup EXIT
print_footer "Backup completed. User files are not inside the tar archive unless restic ran."
