#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"

fail_static() { printf 'static check failed: %s\n' "$1" >&2; exit 1; }

check_metabase_allowlist() {
    local mode="$1" value="$2" label="$3" shown="${2:-<empty>}"
    if [[ "${mode}" == accept ]]; then
        env_metabase_allowlist_ok "${value}" \
            || fail_static "METABASE_IP_ALLOWLIST rejected ${label}: ${shown}"
    elif env_metabase_allowlist_ok "${value}"; then
        fail_static "METABASE_IP_ALLOWLIST accepted ${label}: ${shown}"
    fi
    ok "METABASE_IP_ALLOWLIST ${mode}: ${label}"
}

# Fake value used only to prove the post-deploy path does not print a key.
CROWDSEC_FIXTURE_KEY='FIXTUREKEY0123456789abcd'
CROWDSEC_TEST_ROOT=""
CROWDSEC_OUT=""
CROWDSEC_STATUS=0

crowdsec_static_fail() {
    [[ -n "${CROWDSEC_TEST_ROOT}" ]] && rm -rf "${CROWDSEC_TEST_ROOT}"
    fail_static "$1"
}

crowdsec_key_path() {
    printf '%s\n' "${CROWDSEC_TEST_ROOT}/crowdsec/BOUNCER_KEY_lu-traefik"
}

crowdsec_defaults() {
    crowdsec_container_state() { printf '%s\n' running; }
    crowdsec_wait_lapi() { printf '%s\n' lapi >> "${CROWDSEC_TEST_ROOT}/trace"; return 0; }
    post_deploy_install_collections() { printf '%s\n' collections >> "${CROWDSEC_TEST_ROOT}/trace"; }
    crowdsec_bouncer_registered() { return 1; }
    crowdsec_probe_key_file() { printf '%s\n' probed >> "${CROWDSEC_TEST_ROOT}/trace"; printf '%s\n' 200; }
    crowdsec_delete_bouncer() { printf '%s\n' "$1" >> "${CROWDSEC_TEST_ROOT}/deleted"; }
    crowdsec_add_key_file() { printf '%s\n' add >> "${CROWDSEC_TEST_ROOT}/added"; }
    crowdsec_generate_key() {
        printf '%s\n' generate >> "${CROWDSEC_TEST_ROOT}/generated"
        printf '%s\n' "${CROWDSEC_FIXTURE_KEY}"
    }
    traefik_started_raw() { date -u -d @1 +%Y-%m-%dT%H:%M:%SZ; }
    traefik_restart() { printf '%s\n' restart >> "${CROWDSEC_TEST_ROOT}/restart"; }
    post_deploy_bouncer_key_path() { crowdsec_key_path; }
}

crowdsec_prepare_key() {
    local body="$1"
    local path
    path="$(crowdsec_key_path)"
    mkdir -p "${CROWDSEC_TEST_ROOT}/crowdsec"
    printf '%s\n' "${body}" > "${path}"
    chmod 644 "${path}"
    chmod 755 "${CROWDSEC_TEST_ROOT}/crowdsec"
}

run_crowdsec() {
    local scenario="$1" keep="${2:-}"
    if [[ "${keep}" != keep ]]; then
        rm -f "${CROWDSEC_TEST_ROOT}/trace" "${CROWDSEC_TEST_ROOT}/deleted" \
            "${CROWDSEC_TEST_ROOT}/added" "${CROWDSEC_TEST_ROOT}/generated" \
            "${CROWDSEC_TEST_ROOT}/restart" "${CROWDSEC_TEST_ROOT}/expected"
        rm -rf "${CROWDSEC_TEST_ROOT}/crowdsec" "${CROWDSEC_TEST_ROOT}/direct"
    fi
    set +e
    CROWDSEC_OUT="$("${scenario}" 2>&1)"
    CROWDSEC_STATUS=$?
    set -e
    if printf '%s\n' "${CROWDSEC_OUT}" | grep -F -q "${CROWDSEC_FIXTURE_KEY}"; then
        crowdsec_static_fail "CrowdSec post-deploy printed the API key during ${scenario}"
    fi
}

assert_crowdsec_status() {
    local expected="$1" scenario="$2"
    if [[ "${expected}" == ok && "${CROWDSEC_STATUS}" -ne 0 ]]; then
        crowdsec_static_fail "${scenario} failed: ${CROWDSEC_OUT}"
    fi
    if [[ "${expected}" == fail && "${CROWDSEC_STATUS}" -eq 0 ]]; then
        crowdsec_static_fail "${scenario} was accepted"
    fi
}

assert_crowdsec_file() {
    local name="$1"
    [[ -f "${CROWDSEC_TEST_ROOT}/${name}" ]] || crowdsec_static_fail "missing CrowdSec trace ${name}"
}

assert_crowdsec_absent() {
    local name="$1" label="$2"
    if [[ -e "${CROWDSEC_TEST_ROOT}/${name}" ]]; then
        crowdsec_static_fail "${label}"
    fi
}

check_crowdsec_post_deploy() {
    local got path expected
    CROWDSEC_TEST_ROOT="$(mktemp -d)"
    expect_crowdsec_action() {
        got="$(post_deploy_crowdsec_action "$1" "$2" "${3:-}")"
        [[ "${got}" == "$4" ]] || crowdsec_static_fail "action ${1}/${2}/${3:-<none>} was ${got}"
    }
    expect_crowdsec_action valid yes 200 keep
    expect_crowdsec_action valid no 200 register-existing
    expect_crowdsec_action valid no 403 register-existing
    expect_crowdsec_action valid yes 403 repair-existing
    expect_crowdsec_action valid yes 500 abort-lapi
    expect_crowdsec_action valid yes "" abort-lapi
    expect_crowdsec_action missing yes "" replace-registered
    expect_crowdsec_action missing no "" create-new
    expect_crowdsec_action empty yes "" replace-registered
    expect_crowdsec_action empty no "" create-new
    expect_crowdsec_action invalid yes 200 refuse-invalid
    expect_crowdsec_action invalid no "" refuse-invalid
    ok "CrowdSec actions cover the key and bouncer states"

    post_deploy_key_format_ok "${CROWDSEC_FIXTURE_KEY}" \
        || crowdsec_static_fail "fixture key was rejected"
    if post_deploy_key_format_ok "not a key"; then
        crowdsec_static_fail "invalid key text was accepted"
    fi
    post_deploy_deletable_bouncer "${CROWDSEC_BOUNCER_NAME}" \
        || crowdsec_static_fail "lu-traefik was not deletable"
    if post_deploy_deletable_bouncer "lu-traefik-other"; then
        crowdsec_static_fail "a longer bouncer name was deletable"
    fi
    if post_deploy_deletable_bouncer "traefik"; then
        crowdsec_static_fail "the reference bouncer name was deletable"
    fi
    if crowdsec_delete_bouncer "lu-traefik-other"; then
        crowdsec_static_fail "delete accepted a different bouncer"
    fi
    printf '%s\n' 'name,ip,revoked' 'lu-traefik-other,10.0.0.8,validated' 'x-lu-traefik,10.0.0.9,validated' \
        | post_deploy_raw_has_bouncer "${CROWDSEC_BOUNCER_NAME}" \
        && crowdsec_static_fail "a bouncer prefix matched lu-traefik"
    printf '%s\n' 'name,ip,revoked' 'lu-traefik,10.1.0.2,validated' \
        | post_deploy_raw_has_bouncer "${CROWDSEC_BOUNCER_NAME}" \
        || crowdsec_static_fail "exact bouncer lu-traefik was missed"
    post_deploy_restart_needed 100 100 || crowdsec_static_fail "same-second key change skipped restart"
    post_deploy_restart_needed 100 99 || crowdsec_static_fail "older Traefik skipped restart"
    if post_deploy_restart_needed 100 101; then
        crowdsec_static_fail "newer Traefik would be restarted"
    fi
    ok "CrowdSec name, key format and restart clock are exact"

    if grep -n 'docker exec' "${REPO_ROOT}/scripts/lib/deploy.sh" | grep -F -- '--key'; then
        crowdsec_static_fail "docker exec passes --key on the host command line"
    fi
    if grep -q 'crowdsecurity/sshd' "${REPO_ROOT}/scripts/lib/deploy.sh"; then
        crowdsec_static_fail "post-deploy installs the sshd collection"
    fi
    grep -q 'GET /v1/decisions HTTP/1.0' "${REPO_ROOT}/scripts/lib/deploy.sh" \
        || crowdsec_static_fail "LAPI decision request is missing"
    grep -q 'Host: crowdsec:8080' "${REPO_ROOT}/scripts/lib/deploy.sh" \
        || crowdsec_static_fail "LAPI host is not crowdsec:8080"
    grep -q 'X-Api-Key: %s' "${REPO_ROOT}/scripts/lib/deploy.sh" \
        || crowdsec_static_fail "LAPI key header is missing"
    ok "CrowdSec key is not a host process argument"

    crowdsec_keep_loaded() {
        crowdsec_defaults
        crowdsec_bouncer_registered() { return 0; }
        crowdsec_prepare_key "${CROWDSEC_FIXTURE_KEY}"
        touch -d @5000 "$(crowdsec_key_path)"
        traefik_started_raw() { date -u -d @5001 +%Y-%m-%dT%H:%M:%SZ; }
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_keep_loaded
    assert_crowdsec_status ok "valid registered key"
    assert_crowdsec_absent restart "valid registered key restarted Traefik"
    assert_crowdsec_absent deleted "valid registered key removed a bouncer"
    assert_crowdsec_absent generated "valid registered key generated a new key"
    [[ "$(stat -c '%a' "$(crowdsec_key_path)")" == 600 ]] || crowdsec_static_fail "valid key was not mode 600"
    [[ "$(stat -c '%a' "${CROWDSEC_TEST_ROOT}/crowdsec")" == 700 ]] || crowdsec_static_fail "key directory was not mode 700"
    ok "CrowdSec keeps a valid registered key without restart"

    crowdsec_register_existing() {
        crowdsec_defaults
        crowdsec_bouncer_registered() {
            printf '%s\n' 'name,ip' 'lu-traefik-other,10.0.0.1' 'x-lu-traefik,10.0.0.2' \
                | post_deploy_raw_has_bouncer "${CROWDSEC_BOUNCER_NAME}"
        }
        crowdsec_probe_key_file() { printf '%s\n' 403; }
        crowdsec_prepare_key "${CROWDSEC_FIXTURE_KEY}"
        touch -d @5000 "$(crowdsec_key_path)"
        traefik_started_raw() { date -u -d @5001 +%Y-%m-%dT%H:%M:%SZ; }
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_register_existing
    assert_crowdsec_status ok "register existing key"
    assert_crowdsec_file added
    assert_crowdsec_absent deleted "missing bouncer deleted another name"
    assert_crowdsec_absent generated "existing key was regenerated"
    assert_crowdsec_absent restart "unchanged key restarted a newer Traefik"
    ok "CrowdSec registers a stored key when lu-traefik is absent"

    crowdsec_repair_auth() {
        crowdsec_defaults
        crowdsec_bouncer_registered() { return 0; }
        crowdsec_probe_key_file() { printf '%s\n' 403; }
        crowdsec_prepare_key "${CROWDSEC_FIXTURE_KEY}"
        touch -d @5000 "$(crowdsec_key_path)"
        traefik_started_raw() { date -u -d @5001 +%Y-%m-%dT%H:%M:%SZ; }
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_repair_auth
    assert_crowdsec_status ok "repair registration"
    [[ "$(<"${CROWDSEC_TEST_ROOT}/deleted")" == "${CROWDSEC_BOUNCER_NAME}" ]] \
        || crowdsec_static_fail "repair deleted a bouncer other than lu-traefik"
    assert_crowdsec_file added
    assert_crowdsec_absent generated "repair replaced the stored key"
    assert_crowdsec_absent restart "repair restarted Traefik after an unchanged key"
    ok "CrowdSec repairs only lu-traefik with the stored key"

    crowdsec_replace_registered() {
        crowdsec_defaults
        crowdsec_bouncer_registered() { return 0; }
        crowdsec_prepare_key ""
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_replace_registered
    assert_crowdsec_status ok "empty key with registered bouncer"
    [[ "$(<"${CROWDSEC_TEST_ROOT}/deleted")" == "${CROWDSEC_BOUNCER_NAME}" ]] \
        || crowdsec_static_fail "empty key deleted a bouncer other than lu-traefik"
    assert_crowdsec_file generated
    assert_crowdsec_file restart
    printf '%s\n' "${CROWDSEC_FIXTURE_KEY}" > "${CROWDSEC_TEST_ROOT}/expected"
    cmp -s "${CROWDSEC_TEST_ROOT}/expected" "$(crowdsec_key_path)" \
        || crowdsec_static_fail "stored key does not match the generated key"
    [[ "$(stat -c '%a' "$(crowdsec_key_path)")" == 600 ]] || crowdsec_static_fail "generated key was not mode 600"
    [[ -z "$(find "${CROWDSEC_TEST_ROOT}/crowdsec" -name '.bouncer-key.*' -print)" ]] \
        || crowdsec_static_fail "temporary key file was left behind"
    ok "CrowdSec replaces an empty key and restarts Traefik"

    crowdsec_create_missing() {
        crowdsec_defaults
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_create_missing
    assert_crowdsec_status ok "missing key and bouncer"
    assert_crowdsec_absent deleted "new bouncer deleted an existing name"
    assert_crowdsec_file generated
    assert_crowdsec_file restart
    [[ "$(stat -c '%a' "${CROWDSEC_TEST_ROOT}/crowdsec")" == 700 ]] || crowdsec_static_fail "new key directory was not mode 700"
    ok "CrowdSec creates a key when none is registered"

    crowdsec_invalid_key() {
        crowdsec_defaults
        crowdsec_bouncer_registered() { return 0; }
        crowdsec_prepare_key "not a key"
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_invalid_key
    assert_crowdsec_status fail "invalid key"
    [[ "$(<"$(crowdsec_key_path)")" == "not a key" ]] || crowdsec_static_fail "invalid key file was overwritten"
    assert_crowdsec_absent deleted "invalid key removed a bouncer"
    assert_crowdsec_absent generated "invalid key generated a replacement"
    assert_crowdsec_absent restart "invalid key restarted Traefik"
    ok "CrowdSec leaves an invalid key file unchanged"

    crowdsec_lapi_down() {
        crowdsec_defaults
        crowdsec_wait_lapi() { return 1; }
        crowdsec_bouncer_registered() { return 0; }
        crowdsec_prepare_key ""
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_lapi_down
    assert_crowdsec_status fail "unavailable LAPI"
    [[ "$(<"$(crowdsec_key_path)")" == "" ]] || crowdsec_static_fail "unavailable LAPI replaced the key file"
    assert_crowdsec_absent trace "unavailable LAPI continued past the readiness check"
    assert_crowdsec_absent deleted "unavailable LAPI removed a bouncer"
    assert_crowdsec_absent generated "unavailable LAPI generated a key"
    ok "CrowdSec makes no destructive change when LAPI is down"

    crowdsec_probe_down() {
        crowdsec_defaults
        crowdsec_bouncer_registered() { return 0; }
        crowdsec_probe_key_file() { return 1; }
        crowdsec_prepare_key "${CROWDSEC_FIXTURE_KEY}"
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_probe_down
    assert_crowdsec_status fail "LAPI probe error"
    assert_crowdsec_absent deleted "LAPI probe error removed a bouncer"
    assert_crowdsec_absent generated "LAPI probe error generated a key"
    assert_crowdsec_absent restart "LAPI probe error restarted Traefik"
    ok "CrowdSec makes no destructive change when the key check cannot reach LAPI"

    crowdsec_same_second() {
        crowdsec_defaults
        crowdsec_bouncer_registered() { return 0; }
        crowdsec_prepare_key "${CROWDSEC_FIXTURE_KEY}"
        touch -d @5000 "$(crowdsec_key_path)"
        traefik_started_raw() { date -u -d @5000 +%Y-%m-%dT%H:%M:%SZ; }
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_same_second
    assert_crowdsec_status ok "same-second Traefik start"
    assert_crowdsec_file restart
    ok "CrowdSec repeats restart when the key and Traefik share a second"

    crowdsec_restart_fails() {
        crowdsec_defaults
        crowdsec_bouncer_registered() { return 0; }
        crowdsec_prepare_key "${CROWDSEC_FIXTURE_KEY}"
        touch -d @1000 "$(crowdsec_key_path)"
        traefik_started_raw() { date -u -d @100 +%Y-%m-%dT%H:%M:%SZ; }
        traefik_restart() { printf '%s\n' restart >> "${CROWDSEC_TEST_ROOT}/restart"; return 1; }
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_restart_fails
    assert_crowdsec_status fail "Traefik restart failure"
    crowdsec_restart_retries() {
        crowdsec_defaults
        crowdsec_bouncer_registered() { return 0; }
        traefik_started_raw() { date -u -d @100 +%Y-%m-%dT%H:%M:%SZ; }
        traefik_restart() { printf '%s\n' restart >> "${CROWDSEC_TEST_ROOT}/restart"; }
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_restart_retries keep
    assert_crowdsec_status ok "Traefik restart retry"
    [[ "$(grep -c restart "${CROWDSEC_TEST_ROOT}/restart")" -eq 2 ]] \
        || crowdsec_static_fail "failed Traefik restart was not retried"
    ok "CrowdSec retries a Traefik restart without rewriting the key"

    local old_umask
    old_umask="$(umask)"
    umask 022
    post_deploy_bouncer_key_path() { printf '%s\n' "${CROWDSEC_TEST_ROOT}/direct/BOUNCER_KEY_lu-traefik"; }
    if ! post_deploy_write_bouncer_key "${CROWDSEC_FIXTURE_KEY}"; then
        umask "${old_umask}"
        crowdsec_static_fail "atomic key write failed"
    fi
    [[ "$(stat -c '%a' "${CROWDSEC_TEST_ROOT}/direct")" == 700 ]] || crowdsec_static_fail "direct key directory was not mode 700"
    [[ "$(stat -c '%a' "${CROWDSEC_TEST_ROOT}/direct/BOUNCER_KEY_lu-traefik")" == 600 ]] \
        || crowdsec_static_fail "direct key file was not mode 600"
    [[ "$(stat -c '%u' "${CROWDSEC_TEST_ROOT}/direct/BOUNCER_KEY_lu-traefik")" == "$(id -u)" ]] \
        || crowdsec_static_fail "key file owner is not the deploying user"
    if post_deploy_write_bouncer_key "short"; then
        umask "${old_umask}"
        crowdsec_static_fail "a short key was written"
    fi
    umask "${old_umask}"
    post_deploy_bouncer_key_path() { printf '%s\n' "${BOUNCER_KEY_FILE}"; }
    ok "CrowdSec key write is atomic and mode 600"

    crowdsec_container_missing() {
        crowdsec_defaults
        crowdsec_container_state() { printf '%s\n' missing; }
        crowdsec_prepare_key "${CROWDSEC_FIXTURE_KEY}"
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_container_missing
    assert_crowdsec_status fail "missing CrowdSec container"
    assert_crowdsec_absent trace "missing container contacted LAPI"
    assert_crowdsec_absent deleted "missing container removed a bouncer"
    ok "CrowdSec stops when lu-crowdsec does not exist"

    crowdsec_container_stopped() {
        crowdsec_defaults
        crowdsec_container_state() { printf '%s\n' stopped; }
        crowdsec_prepare_key "${CROWDSEC_FIXTURE_KEY}"
        post_deploy_crowdsec
    }
    run_crowdsec crowdsec_container_stopped
    assert_crowdsec_status fail "stopped CrowdSec container"
    assert_crowdsec_absent deleted "stopped container removed a bouncer"
    assert_crowdsec_absent generated "stopped container generated a key"
    ok "CrowdSec stops when lu-crowdsec is not running"

    rm -rf "${CROWDSEC_TEST_ROOT}"
    CROWDSEC_TEST_ROOT=""
}

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
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/deploy.sh"
    env_is_placeholder "set_metabase_allowlist" \
        || fail_static "METABASE_IP_ALLOWLIST placeholder would be accepted"
    check_metabase_allowlist accept "10.66.0.2/32" "private IPv4 /32"
    check_metabase_allowlist accept "10.66.0.2/32 192.168.50.8/32" "multiple private IPv4 /32"
    check_metabase_allowlist reject "10.66.0.0/24" "prefix /24"
    check_metabase_allowlist reject "10.66.0.0/16" "prefix /16"
    check_metabase_allowlist reject "10.66.0.0/30" "prefix /30"
    check_metabase_allowlist reject "8.8.8.8/32" "public IPv4 /32"
    check_metabase_allowlist reject "0.0.0.0/0" "0.0.0.0/0"
    check_metabase_allowlist reject "set_metabase_allowlist" "placeholder"
    check_metabase_allowlist reject "" "empty value"
    check_metabase_allowlist reject "10.66.0.256/32" "invalid IPv4"
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
    check_crowdsec_post_deploy
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
