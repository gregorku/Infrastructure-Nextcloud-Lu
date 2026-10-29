#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/env.sh"

archive=""
identity=""
replace=0
confirm=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) archive="$2"; shift 2 ;;
        --identity) identity="$2"; shift 2 ;;
        --replace-data) replace=1; shift ;;
        --confirm) confirm="$2"; shift 2 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[[ -n "${archive}" && "${confirm}" == "${STACK_NAME}" ]] \
    || fail "Usage: ./scripts/restore.sh --archive PATH --confirm ${STACK_NAME} [--identity KEY] [--replace-data]"
[[ -f "${archive}" ]] || fail "Archive does not exist: ${archive}"

print_header "Restore check"
check_environment
env_load_runtime

work="$(mktemp -d)"
chmod 700 "${work}"
cleanup() { rm -rf "${work}"; }
trap cleanup EXIT

source_tar="${archive}"
if [[ "${archive}" == *.age ]]; then
    [[ -n "${identity}" && -f "${identity}" ]] || fail "An age archive needs --identity before any data is changed."
    require_command age
    age -d -i "${identity}" -o "${work}/archive.tar" "${archive}"
    source_tar="${work}/archive.tar"
fi
tar -tf "${source_tar}" | grep -qx "nextcloud.dump"
tar -tf "${source_tar}" | grep -qx "metabase.dump"
tar -xOf "${source_tar}" nextcloud.dump > "${work}/nextcloud.dump"
tar -xOf "${source_tar}" metabase.dump > "${work}/metabase.dump"
next_head="$(od -An -tx1 -N5 "${work}/nextcloud.dump" | tr -d ' \n')"
meta_head="$(od -An -tx1 -N5 "${work}/metabase.dump" | tr -d ' \n')"
[[ "${next_head}" == "5047444d50" && "${meta_head}" == "5047444d50" ]] \
    || fail "A dump is not a PostgreSQL custom archive. Live data was not changed."
if tar -tf "${source_tar}" | grep -qx "SHA256SUMS"; then
    tar -xOf "${source_tar}" SHA256SUMS > "${work}/SHA256SUMS"
    (
        cd "${work}"
        sha256sum -c SHA256SUMS
    )
fi
ok "Archive is readable and both dumps have a PGDMP header."

if [[ "${replace}" -ne 1 ]]; then
    warn "No data was changed. Re-run with --replace-data after this check succeeds."
    exit 2
fi

require_command docker
docker stop "${NEXTCLOUD_APP_CONTAINER}" "${NEXTCLOUD_CRON_CONTAINER}" >/dev/null
docker exec -i -e PGPASSWORD="${RUNTIME_ENV[PG_PASS]}" "${POSTGRESQL_CONTAINER}" \
    pg_restore -U "${RUNTIME_ENV[PG_USER]}" -d "${RUNTIME_ENV[PG_DB]}" --clean --if-exists \
    < "${work}/nextcloud.dump"
docker exec -i -e PGPASSWORD="${RUNTIME_ENV[METABASE_DB_PASSWORD]}" "${METABASE_POSTGRES_CONTAINER}" \
    pg_restore -U "${RUNTIME_ENV[METABASE_DB_USER]}" -d "${RUNTIME_ENV[METABASE_DB_NAME]}" --clean --if-exists \
    < "${work}/metabase.dump"
if tar -tf "${source_tar}" | grep -q '^nextcloud/config/'; then
        tar -C "${work}" -xf "${source_tar}" nextcloud/config
        cp -a "${work}/nextcloud/config/." "${DATA_DIR}/html/config/"
    fi
ok "Database restore finished. Review the application before starting it again."
print_footer "Nextcloud and cron were left stopped."
