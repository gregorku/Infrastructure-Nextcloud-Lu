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
    if grep -R -n --exclude test.sh --exclude-dir .git "ludek.serveftp.org" "${REPO_ROOT}"; then
        fail_static "old domain ludek.serveftp.org is present"
    fi
    grep -q 'readonly NEXTCLOUD_DOMAIN="ludek.serveftp.net"' "${REPO_ROOT}/scripts/config.sh" \
        || fail_static "NEXTCLOUD_DOMAIN is not ludek.serveftp.net"
    grep -q 'server_name ludek.serveftp.net;' "${REPO_ROOT}/configs/nginx/nginx.conf" \
        || fail_static "nginx server_name is not ludek.serveftp.net"
    for key in NEXTCLOUD_DOMAIN NEXTCLOUD_TRUSTED_DOMAINS OVERWRITEHOST; do
        grep -q "^${key}=ludek.serveftp.net$" "${REPO_ROOT}/.env.example" \
            || fail_static "${key} in .env.example is not ludek.serveftp.net"
    done
    grep -q '^OVERWRITECLIURL=https://ludek.serveftp.net$' "${REPO_ROOT}/.env.example" \
        || fail_static "OVERWRITECLIURL in .env.example is not https://ludek.serveftp.net"
    if grep -R -n --exclude test.sh --exclude-dir .git -E 'METABASE_HOST|METABASE_SITE_URL' "${REPO_ROOT}"; then
        fail_static "removed Metabase host variables are present"
    fi
    grep -q '^METABASE_PUBLIC_URL=https://10.100.100.1:9444$' "${REPO_ROOT}/.env.example" \
        || fail_static "METABASE_PUBLIC_URL is not https://10.100.100.1:9444"
    grep -q 'MB_SITE_URL: ${METABASE_PUBLIC_URL:?METABASE_PUBLIC_URL}' "${REPO_ROOT}/compose/30-metabase.yml" \
        || fail_static "Metabase Compose does not use METABASE_PUBLIC_URL"
    grep -q -- '- "80:80"' "${REPO_ROOT}/compose/10-traefik.yml" \
        || fail_static "Traefik port 80 is missing"
    grep -q -- '- "443:443"' "${REPO_ROOT}/compose/10-traefik.yml" \
        || fail_static "Traefik port 443 is missing"
    if grep -nE '8443|8444|0\.0\.0\.0' "${REPO_ROOT}/compose/10-traefik.yml"; then
        fail_static "compose/10-traefik.yml publishes more than ports 80 and 443"
    fi
    grep -q -- '- "192.168.12.233:8444:8444"' "${REPO_ROOT}/compose/16-traefik-metabase-port.yml" \
        || fail_static "Metabase port is not bound to 192.168.12.233:8444"
    if grep -n '0.0.0.0:8444' "${REPO_ROOT}/compose/16-traefik-metabase-port.yml"; then
        fail_static "Metabase port is published on all interfaces"
    fi
    grep -q 'address: ":8444"' "${REPO_ROOT}/scripts/lib/deploy.sh" \
        || fail_static "Traefik metabase entrypoint is missing"
    grep -q 'rule: "PathPrefix(`/`)"' "${REPO_ROOT}/configs/traefik/dynamic/metabase.yml" \
        || fail_static "Metabase router rule is missing"
    grep -q -- '- metabase-ip-whitelist' "${REPO_ROOT}/configs/traefik/dynamic/metabase.yml" \
        || fail_static "Metabase IP allowlist middleware is missing"
    grep -q -- '- auth-basic' "${REPO_ROOT}/configs/traefik/dynamic/metabase.yml" \
        || fail_static "Metabase BasicAuth middleware is missing"
    grep -q 'url: "http://metabase:3000"' "${REPO_ROOT}/configs/traefik/dynamic/metabase.yml" \
        || fail_static "Metabase backend URL is missing"
    if grep -n 'Host(' "${REPO_ROOT}/configs/traefik/dynamic/metabase.yml"; then
        fail_static "Metabase router has a public host rule"
    fi
    grep -q '^METABASE_IP_ALLOWLIST=set_metabase_allowlist$' "${REPO_ROOT}/.env.example" \
        || fail_static "METABASE_IP_ALLOWLIST is not an unset placeholder"
    grep -q 'metabase-ip-whitelist' "${REPO_ROOT}/scripts/lib/deploy.sh" \
        || fail_static "deploy does not render the Metabase IP allowlist"
    if grep -n 'metabase.yml' "${REPO_ROOT}/scripts/lib/deploy.sh"; then
        fail_static "deploy.sh still generates the Metabase router"
    fi
    if grep -R -n --exclude test.sh --exclude-dir .git -E 'authentik|10\.10\.10\.100|outpost\.goauthentik\.io' "${REPO_ROOT}"; then
        fail_static "Authentik configuration is still present"
    fi
    if find "${REPO_ROOT}" -name 'dashboard.htpasswd' -print | grep -q .; then
        fail_static "a htpasswd file is inside the checkout"
    fi
    grep -q 'usersFile: "/etc/traefik/users/dashboard.htpasswd"' "${REPO_ROOT}/configs/traefik/dynamic/middlewares.yml" \
        || fail_static "BasicAuth does not use dashboard.htpasswd"
    grep -q '^dashboard\.htpasswd$' "${REPO_ROOT}/.gitignore" \
        || fail_static "dashboard.htpasswd is not ignored"
    python3 - "${REPO_ROOT}/configs/traefik/dynamic/metabase.yml" "${REPO_ROOT}/configs/traefik/dynamic/dashboard.yml" "${REPO_ROOT}/scripts/lib/deploy.sh" <<'PY' || fail_static "rendered Traefik or Metabase config is invalid"
import pathlib, sys
metabase = pathlib.Path(sys.argv[1]).read_text()
dashboard = pathlib.Path(sys.argv[2]).read_text()
deploy = pathlib.Path(sys.argv[3]).read_text()
if metabase.count("entryPoints:") != 1:
    sys.exit("Metabase file does not have exactly one router")
router = metabase.split("entryPoints:", 1)[1].split("rule:", 1)[0]
if "- metabase" not in router or "- admin" in router:
    sys.exit("Metabase router is not only on entrypoint metabase")
if 'rule: "PathPrefix(`/`)"' not in metabase or "Host(" in metabase:
    sys.exit("Metabase rule is not PathPrefix(/)")
if 'url: "http://metabase:3000"' not in metabase:
    sys.exit("Metabase backend changed")
chain = metabase.split("metabase-chain:", 1)[1]
if "metabase-ip-whitelist" not in chain or "auth-basic" not in chain:
    sys.exit("Metabase chain lost IP allowlist or BasicAuth")
if "entryPoints:\n        - admin" not in dashboard:
    sys.exit("dashboard router left entrypoint admin")
if "metabase" in dashboard:
    sys.exit("dashboard file contains a Metabase router")
marker = 'cat > "${traefik_yml}" <<EOF\n'
body = deploy.split(marker, 1)[1].split("\nEOF", 1)[0]
rendered = (body.replace("${proxy_web}", "").replace("${proxy_secure}", "").replace("${acme}", "").replace("${RUNTIME_ENV[CROWDSEC_BOUNCER_PLUGIN]}", "v1.7.0"))
required = [
    'address: ":80"',
    'address: ":443"',
    'address: ":8443"',
    'address: ":8444"',
    "readTimeout: 0s",
]
for item in required:
    if item not in rendered:
        sys.exit(f"missing {item}")
if "proxyProtocol:" in rendered:
    sys.exit("local render enables proxyProtocol")
if "forwardedHeaders:" in rendered or "insecure: true" in rendered:
    sys.exit("local render trusts forwarded headers or enables insecure mode")
web = rendered.split("websecure:", 1)[0]
if 'address: ":80"' not in web or 'address: ":443"' in web:
    sys.exit("web entrypoint changed")
PY
    if grep -nE '^[[:space:]]*- "(5432|6379|9000|3000):' "${REPO_ROOT}/compose/"*.yml; then
        fail_static "an internal service publishes a host port"
    fi
    grep -q '^\.env$' "${REPO_ROOT}/.gitignore" || fail_static ".env is not ignored"
    grep -q '^set_postgres_password$' <(sed -n 's/^PG_PASS=//p' "${REPO_ROOT}/.env.example") \
        || fail_static "PG_PASS example is not a placeholder"
    [[ ! -f "${REPO_ROOT}/.env" ]] || fail_static "a runtime .env is inside the Git checkout"
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/env.sh"
    env_is_placeholder "set_metabase_allowlist" \
        || fail_static "METABASE_IP_ALLOWLIST placeholder would be accepted"
    grep -q 'env_load_runtime' "${REPO_ROOT}/scripts/deploy.sh" \
        || fail_static "deploy does not validate the environment"
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
