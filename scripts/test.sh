#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"

fail_static() { printf 'static check failed: %s\n' "$1" >&2; exit 1; }

static_checks() {
    local script
    while IFS= read -r script; do
        bash -n "${script}" || fail_static "bash -n ${script}"
    done < <(find "${REPO_ROOT}/scripts" -name '*.sh' -type f)

    if grep -R -n "insecure: true" "${REPO_ROOT}/configs" "${REPO_ROOT}/compose" "${REPO_ROOT}/compose.yml"; then
        fail_static "insecure proxy or header trust is present"
    fi
    if grep -R -nE '(trustedIPs|sourceRange|set_real_ip_from|TRUSTED_PROXIES=).*0\.0\.0\.0/0' "${REPO_ROOT}"; then
        fail_static "a wildcard trust range is configured"
    fi
    if grep -R -n --exclude test.sh "install-dockge\|docker rm\|docker network rm" "${REPO_ROOT}/scripts"; then
        fail_static "a destructive Docker command is present"
    fi
    if grep -R -n "bridge-moje\|traefik-moje\|gregor.serveftp.org" "${REPO_ROOT}/compose" "${REPO_ROOT}/configs" "${REPO_ROOT}/.env.example"; then
        fail_static "a foreign project name is present"
    fi
    if grep -nE '^[[:space:]]*- "(5432|6379|9000|3000):' "${REPO_ROOT}/compose/"*.yml; then
        fail_static "an internal service publishes a host port"
    fi
    grep -q '^\.env$' "${REPO_ROOT}/.gitignore" || fail_static ".env is not ignored"
    grep -q '^set_postgres_password$' <(sed -n 's/^PG_PASS=//p' "${REPO_ROOT}/.env.example") \
        || fail_static "PG_PASS example is not a placeholder"
    [[ ! -f "${REPO_ROOT}/.env" ]] || fail_static "a runtime .env is inside the Git checkout"
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/env.sh"
    env_cidr_ok "10.20.0.0/24" || fail_static "CIDR parser rejected 10.20.0.0/24"
    if env_cidr_ok "10.20.0.0/33"; then
        fail_static "CIDR parser accepted prefix 33"
    fi
    if env_cidr_overlaps "10.20.0.0/24" "10.21.0.0/24"; then
        fail_static "disjoint subnets were reported as overlapping"
    fi
    env_cidr_overlaps "10.20.0.0/24" "10.20.0.128/25" || fail_static "nested subnets were reported as disjoint"
    env_path_nested "/data/pg" "/data/pg/subdir" || fail_static "nested paths were not detected"
    if env_path_nested "/data/nextcloud-pg" "/data/metabase-pg"; then
        fail_static "sibling paths were reported as nested"
    fi
    ok "Static checks passed. Containers were not started."
}

case "${1:-}" in
    --static|"")
        static_checks
        ;;
    --help)
        printf '%s\n' "Usage: ./scripts/test.sh --static"
        ;;
    *)
        fail "Unknown option: $1"
        ;;
esac
