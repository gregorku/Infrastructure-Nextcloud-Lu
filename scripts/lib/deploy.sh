#!/usr/bin/env bash

assert_sync_paths() {
    [[ -n "${GIT_DIR}" && -n "${STACK_DIR}" && -n "${DATA_DIR}" ]] || fail "A project path is empty."
    [[ "${GIT_DIR}" == /* && "${STACK_DIR}" == /* && "${DATA_DIR}" == /* ]] || fail "Project paths must be absolute."
    [[ "${GIT_DIR}" != "/" && "${STACK_DIR}" != "/" && "${DATA_DIR}" != "/" ]] || fail "Refusing to use '/'."
    [[ "${GIT_DIR}" != "${STACK_DIR}" ]] || fail "GIT_DIR and STACK_DIR must differ."
    [[ "${STACK_DIR}" == "${STACKS_DIR}/${STACK_NAME}" ]] || fail "STACK_DIR is not under this project's stack name."
    [[ "${DATA_DIR}" != "${STACK_DIR}" && "${BACKUP_LOCAL_DIR}" != "${STACK_DIR}" ]] || fail "Data and backups must stay outside the stack directory."
}

sync_tree() {
    local src="$1" dst="$2"
    mkdir -p "${dst}"
    rsync -a --delete "${src}/" "${dst}/"
}

deploy_sync_stack() {
    print_section "Synchronize stack"
    assert_sync_paths
    mkdir -p "${STACK_DIR}"
    local item src dst
    for item in "${DEPLOY_ITEMS[@]}"; do
        [[ "${item}" != /* && "${item}" != *..* ]] || fail "DEPLOY_ITEMS entry is not safe: ${item}"
        src="${GIT_DIR}/${item}"
        dst="${STACK_DIR}/${item}"
        [[ -e "${src}" ]] || fail "Missing deployment item: ${src}"
        if [[ -d "${src}" ]]; then
            sync_tree "${src}" "${dst}"
        else
            install -Dm644 "${src}" "${dst}"
        fi
        info "Synchronized ${item}"
    done
    ok "Stack files synchronized. Persistent data was not touched."
}

prepare_owned_dir() {
    local path="$1" owner="$2" purpose="$3"
    [[ -d "${path}" ]] || fail "${purpose} directory ${path} does not exist."
    findmnt -T "${path}" >/dev/null 2>&1 || fail "${purpose} directory ${path} is not on a mount."
    local mounted
    mounted="$(findmnt -T "${path}" -n -o TARGET)"
    [[ "${path}" != "${mounted}" ]] || fail "${purpose} directory ${path} is the mountpoint itself. Use a directory inside the disk."
    if [[ -n "$(ls -A "${path}")" ]]; then
        local uid
        uid="$(stat -c '%u' "${path}")"
        [[ "${uid}" == "${owner%%:*}" || "${uid}" == "0" ]] \
            || fail "${purpose} directory ${path} is owned by uid ${uid}. Refusing chown -R."
        return 0
    fi
    chown "${owner}" "${path}"
}

deploy_prepare_storage() {
    print_section "Persistent storage"
    require_mountpoint "${DOCKER_DATA_DIR}"
    mkdir -p \
        "${DATA_DIR}/html" \
        "${DATA_DIR}/state" \
        "${DATA_DIR}/traefik/acme" \
        "${DATA_DIR}/traefik/logs" \
        "${DATA_DIR}/traefik/users" \
        "${DATA_DIR}/traefik/crowdsec" \
        "${DATA_DIR}/crowdsec/data" \
        "${DATA_DIR}/metabase/postgres" \
        "${DATA_DIR}/metabase/data" \
        "${DATA_DIR}/metabase/plugins" \
        "${BACKUP_LOCAL_DIR}" \
        "${STACK_DIR}/runtime/traefik/dynamic"
    chmod 700 "${DATA_DIR}/state" "${BACKUP_LOCAL_DIR}" "${DATA_DIR}/traefik/crowdsec" "${DATA_DIR}/traefik/users"
    if [[ ! -f "${ACME_FILE}" ]]; then
        : > "${ACME_FILE}"
        chmod 600 "${ACME_FILE}"
    fi
    [[ "$(stat -c '%a' "${ACME_FILE}")" == "600" ]] || fail "acme.json must stay mode 600."
    if [[ -z "$(ls -A "${DATA_DIR}/html")" ]]; then
        chown "${NEXTCLOUD_UID_GID}" "${DATA_DIR}/html"
    fi
    prepare_owned_dir "${RUNTIME_ENV[POSTGRESQL_HOST_DIR]}" "${POSTGRESQL_UID_GID}" "Nextcloud PostgreSQL"
    prepare_owned_dir "${RUNTIME_ENV[NEXTCLOUD_DATA_HOST_DIR]}" "${NEXTCLOUD_UID_GID}" "Nextcloud data"
    if [[ -z "$(ls -A "${DATA_DIR}/metabase/postgres")" ]]; then
        chown "${POSTGRESQL_UID_GID}" "${DATA_DIR}/metabase/postgres"
    fi
    ok "Persistent directories are ready."
}

deploy_ensure_one_network() {
    local name="$1" subnet="$2" gateway="$3"
    if docker network inspect "${name}" >/dev/null 2>&1; then
        local existing_subnet existing_gateway
        existing_subnet="$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "${name}")"
        existing_gateway="$(docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "${name}")"
        [[ "${existing_subnet}" == "${subnet}" ]] || fail "Docker network ${name} already uses ${existing_subnet}, not ${subnet}. It was not changed."
        [[ "${existing_gateway}" == "${gateway}" ]] || fail "Docker network ${name} gateway is ${existing_gateway}, not ${gateway}. It was not changed."
        ok "Docker network ${name} already matches ${subnet}."
        return 0
    fi
    local other other_subnet
    while read -r other; do
        [[ -n "${other}" && "${other}" != "${name}" ]] || continue
        other_subnet="$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "${other}" 2>/dev/null || true)"
        [[ -n "${other_subnet}" ]] || continue
        if env_cidr_overlaps "${subnet}" "${other_subnet}"; then
            fail "Refusing to create ${name} ${subnet}: it overlaps existing network ${other} ${other_subnet}."
        fi
    done < <(docker network ls --format '{{.Name}}')
    docker network create --driver bridge --subnet "${subnet}" --gateway "${gateway}" "${name}" >/dev/null
    ok "Docker network ${name} created."
}

deploy_ensure_networks() {
    print_section "Docker networks"
    deploy_ensure_one_network "${NETWORK_PROXY}" "${RUNTIME_ENV[DOCKER_PROXY_SUBNET]}" "${RUNTIME_ENV[DOCKER_PROXY_GATEWAY]}"
    deploy_ensure_one_network "${NETWORK_INTERNAL}" "${RUNTIME_ENV[DOCKER_INTERNAL_SUBNET]}" "${RUNTIME_ENV[DOCKER_INTERNAL_GATEWAY]}"
}

yaml_quote() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

deploy_render_runtime() {
    print_section "Render runtime files"
    local IFS=$' \t\n'
    local dynamic="${STACK_DIR}/runtime/traefik/dynamic"
    mkdir -p "${dynamic}"
    rsync -a --delete "${GIT_DIR}/configs/traefik/dynamic/" "${dynamic}/"

    local redis="${STACK_DIR}/runtime/redis.conf"
    umask 077
    cat > "${redis}" <<EOF
bind 0.0.0.0
protected-mode yes
port 6379
requirepass ${RUNTIME_ENV[REDIS_PASSWORD]}
appendonly no
maxmemory-policy noeviction
EOF
    chmod 600 "${redis}"
    chown "${REDIS_UID_GID}" "${redis}"

    local realip="${STACK_DIR}/runtime/real-ip.conf"
    {
        printf 'real_ip_header X-Forwarded-For;\nreal_ip_recursive on;\n'
        local cidr
        for cidr in ${RUNTIME_ENV[TRUSTED_PROXIES]}; do
            printf 'set_real_ip_from %s;\n' "${cidr}"
        done
    } > "${realip}"

    local allow="${dynamic}/ip-whitelist.yml"
    {
        printf 'http:\n  middlewares:\n    ip-whitelist:\n      ipAllowList:\n        sourceRange:\n'
        local item
        for item in ${RUNTIME_ENV[ADMIN_IP_ALLOWLIST]}; do
            printf '          - "%s"\n' "$(yaml_quote "${item}")"
        done
        printf '    metabase-ip-whitelist:\n      ipAllowList:\n        sourceRange:\n'
        for item in ${RUNTIME_ENV[METABASE_IP_ALLOWLIST]}; do
            printf '          - "%s"\n' "$(yaml_quote "${item}")"
        done
    } > "${allow}"

    local tls_block="        options: default"
    if [[ "${RUNTIME_ENV[TRAEFIK_TLS_MODE]}" == "letsencrypt" ]]; then
        tls_block="        certResolver: letsencrypt"
    fi
    cat > "${dynamic}/nextcloud.yml" <<EOF
http:
  routers:
    nextcloud-lu:
      entryPoints:
        - websecure
      rule: "Host(\`${NEXTCLOUD_DOMAIN}\`)"
      service: nextcloud-lu
      middlewares:
        - nextcloud-chain
      tls:
${tls_block}
  services:
    nextcloud-lu:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: http://nginx:80
EOF

    local traefik_yml="${STACK_DIR}/runtime/traefik/traefik.yml"
    local proxy_web="" proxy_secure="" acme=""
    if [[ "${RUNTIME_ENV[PROXY_PROTOCOL_MODE]}" == "haproxy" ]]; then
        proxy_web=$'    proxyProtocol:\n      trustedIPs:\n'
        proxy_secure=$'    proxyProtocol:\n      trustedIPs:\n'
        local src
        for src in ${RUNTIME_ENV[PROXY_PROTOCOL_TRUSTED_IPS]}; do
            proxy_web+="        - \"$(yaml_quote "${src}")\""$'\n'
            proxy_secure+="        - \"$(yaml_quote "${src}")\""$'\n'
        done
    fi
    if [[ "${RUNTIME_ENV[TRAEFIK_TLS_MODE]}" == "letsencrypt" ]]; then
        acme=$(cat <<EOF
certificatesResolvers:
  letsencrypt:
    acme:
      email: "$(yaml_quote "${RUNTIME_ENV[TRAEFIK_ACME_EMAIL]}")"
      storage: /etc/traefik/acme/acme.json
      httpChallenge:
        entryPoint: web
EOF
)
    fi
    cat > "${traefik_yml}" <<EOF
global:
  checkNewVersion: false
  sendAnonymousUsage: false
api:
  dashboard: true
  insecure: false
ping: {}
entryPoints:
  web:
    address: ":80"
${proxy_web}    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
${proxy_secure}    transport:
      respondingTimeouts:
        readTimeout: 0s
  admin:
    address: ":8443"
  metabase:
    address: ":8444"
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: /etc/traefik/dynamic
    watch: true
experimental:
  plugins:
    crowdsec:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: ${RUNTIME_ENV[CROWDSEC_BOUNCER_PLUGIN]}
log:
  level: INFO
  filePath: /var/log/traefik/traefik.log
accessLog:
  filePath: /var/log/traefik/access.log
${acme}
EOF

    local admin_file="${STACK_DIR}/compose/15-traefik-admin-port.yml"
    if [[ -n "${RUNTIME_ENV[TRAEFIK_ADMIN_PUBLISH]}" ]]; then
        cat > "${admin_file}" <<EOF
services:
  traefik:
    ports:
      - "${RUNTIME_ENV[TRAEFIK_ADMIN_PUBLISH]}"
EOF
    else
        printf 'services: {}\n' > "${admin_file}"
    fi

    if grep -R -n "proxyProtocol:" "${traefik_yml}" >/dev/null 2>&1; then
        grep -q "insecure:" "${traefik_yml}" && grep -A2 "proxyProtocol:" "${traefik_yml}" | grep -q "insecure: true" \
            && fail "Rendered Traefik enables proxyProtocol.insecure."
    fi
    grep -q "0.0.0.0/0" "${traefik_yml}" && fail "Rendered Traefik trusts 0.0.0.0/0."
    grep -q "forwardedHeaders:" "${traefik_yml}" && fail "Rendered Traefik trusts forwarded headers."
    ok "Runtime configuration rendered."
}

deploy_check_dockge() {
    print_section "Dockge"
    require_command docker
    docker inspect "${DOCKGE_CONTAINER}" >/dev/null 2>&1 || fail "Dockge is not present. This project does not install it."
    docker inspect -f '{{.State.Running}}' "${DOCKGE_CONTAINER}" | grep -qx true \
        || fail "Dockge is not running. This project does not start, replace or remove it."
    local dockge_path
    dockge_path="$(docker exec "${DOCKGE_CONTAINER}" printenv DOCKGE_STACKS_DIR)"
    [[ "${dockge_path}" == "${STACKS_DIR}" ]] || fail "Dockge stack path is '${dockge_path}', expected '${STACKS_DIR}'."
    ok "Dockge is using ${STACKS_DIR}. Stack name: ${STACK_NAME}."
}

deploy_assert_version() {
    print_section "Version guard"
    [[ ! -f "${UPGRADE_LOCK_FILE}" ]] || fail "Upgrade lock exists. Finish or roll back before deploy."
    local wanted="${1}"
    if [[ -f "${INSTALLED_VERSION_FILE}" ]]; then
        local installed
        installed="$(tr -d '[:space:]' < "${INSTALLED_VERSION_FILE}")"
        [[ "${installed}" == "${wanted}" ]] || fail "Installed Nextcloud tag is ${installed}. Refusing to start ${wanted}. Run ./scripts/upgrade.sh."
        ok "Installed tag matches ${wanted}."
    else
        info "No installed-version file yet. This deploy will not delete existing Nextcloud data."
    fi
}

deploy_compose() {
    print_section "Compose"
    require_command docker
    docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required and is not installed by this project."
    (
        cd "${STACK_DIR}"
        docker compose --env-file "${ENV_FILE}" config >/dev/null
        docker compose --env-file "${ENV_FILE}" up -d --remove-orphans
    )
    ok "Compose started without removing volumes."
}

deploy_postgres_role() {
    print_section "Nextcloud database role"
    local i
    for i in $(seq 1 30); do
        docker exec "${POSTGRESQL_CONTAINER}" pg_isready -U "${POSTGRES_BOOTSTRAP_USER}" -d "${RUNTIME_ENV[PG_DB]}" >/dev/null 2>&1 && break
        sleep 2
    done
    docker exec "${POSTGRESQL_CONTAINER}" pg_isready -U "${POSTGRES_BOOTSTRAP_USER}" -d "${RUNTIME_ENV[PG_DB]}" >/dev/null 2>&1 \
        || fail "Nextcloud PostgreSQL did not become ready."
    local pass_sql="${RUNTIME_ENV[PG_PASS]//\'/\'\'}"
    local user="${RUNTIME_ENV[PG_USER]}"
    local db="${RUNTIME_ENV[PG_DB]}"
    docker exec -e PGPASSWORD="${RUNTIME_ENV[PG_PASS]}" "${POSTGRESQL_CONTAINER}" \
        psql -v ON_ERROR_STOP=1 -U "${POSTGRES_BOOTSTRAP_USER}" -d postgres \
        -c "SELECT 1 FROM pg_roles WHERE rolname = '${user}'" | grep -q 1 \
        || docker exec -e PGPASSWORD="${RUNTIME_ENV[PG_PASS]}" "${POSTGRESQL_CONTAINER}" \
            psql -v ON_ERROR_STOP=1 -U "${POSTGRES_BOOTSTRAP_USER}" -d postgres \
            -c "CREATE ROLE \"${user}\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${pass_sql}'"
    docker exec -e PGPASSWORD="${RUNTIME_ENV[PG_PASS]}" "${POSTGRESQL_CONTAINER}" \
        psql -v ON_ERROR_STOP=1 -U "${POSTGRES_BOOTSTRAP_USER}" -d postgres \
        -c "ALTER DATABASE \"${db}\" OWNER TO \"${user}\""
    docker exec -e PGPASSWORD="${RUNTIME_ENV[PG_PASS]}" "${POSTGRESQL_CONTAINER}" \
        psql -v ON_ERROR_STOP=1 -U "${POSTGRES_BOOTSTRAP_USER}" -d "${db}" \
        -c "ALTER SCHEMA public OWNER TO \"${user}\""
    ok "Application role is present. The bootstrap superuser was not removed."
}

post_deploy_bouncer_key_path() {
    printf '%s\n' "${BOUNCER_KEY_FILE}"
}

post_deploy_key_format_ok() {
    local key="$1"
    [[ "${#key}" -ge 20 && "${#key}" -le 200 ]] || return 1
    [[ "${key}" =~ ^[A-Za-z0-9+/=_-]+$ ]]
}

post_deploy_key_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

post_deploy_key_file_state() {
    local path="$1" raw trimmed
    [[ -f "${path}" ]] || { printf '%s\n' missing; return 0; }
    raw="$(<"${path}")" || raw=""
    trimmed="$(post_deploy_key_trim "${raw}")"
    if [[ -z "${trimmed}" ]]; then
        printf '%s\n' empty
        return 0
    fi
    if post_deploy_key_format_ok "${trimmed}"; then
        printf '%s\n' valid
    else
        printf '%s\n' invalid
    fi
}

# Restart when Traefik cannot be shown to have started after the key file.
# Equal epochs stay on the restart side: file mtime and StartedAt can share a second.
post_deploy_restart_needed() {
    local file_epoch="$1" started_epoch="$2"
    [[ "${file_epoch}" =~ ^[0-9]+$ && "${started_epoch}" =~ ^[0-9]+$ ]] || return 0
    if (( started_epoch > file_epoch )); then
        return 1
    fi
    return 0
}

post_deploy_raw_has_bouncer() {
    local wanted="$1" line name
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//$'\r'/}"
        [[ -z "${line}" || "${line}" == name,* || "${line}" == Name,* ]] && continue
        name="${line%%,*}"
        [[ "${name}" == "${wanted}" ]] && return 0
    done
    return 1
}

post_deploy_deletable_bouncer() {
    [[ "$1" == "${CROWDSEC_BOUNCER_NAME}" ]]
}

# valid|missing|empty|invalid, yes|no, 200|403|other
post_deploy_crowdsec_action() {
    local key_state="$1" registered="$2" http="${3:-}"
    case "${key_state}" in
        invalid)
            printf '%s\n' refuse-invalid
            ;;
        valid)
            case "${http}" in
                200)
                    if [[ "${registered}" == yes ]]; then
                        printf '%s\n' keep
                    else
                        printf '%s\n' register-existing
                    fi
                    ;;
                403)
                    if [[ "${registered}" == yes ]]; then
                        printf '%s\n' repair-existing
                    else
                        printf '%s\n' register-existing
                    fi
                    ;;
                *)
                    printf '%s\n' abort-lapi
                    ;;
            esac
            ;;
        missing|empty)
            if [[ "${registered}" == yes ]]; then
                printf '%s\n' replace-registered
            else
                printf '%s\n' create-new
            fi
            ;;
        *)
            printf '%s\n' abort-lapi
            ;;
    esac
}

post_deploy_stage_key() {
    local src="$1" dest="$2" raw trimmed old_umask rc
    [[ -f "${src}" ]] || return 1
    raw="$(<"${src}")" || return 1
    trimmed="$(post_deploy_key_trim "${raw}")"
    post_deploy_key_format_ok "${trimmed}" || return 1
    old_umask="$(umask)"
    umask 077
    if ! printf '%s\n' "${trimmed}" > "${dest}"; then
        umask "${old_umask}"
        return 1
    fi
    chmod 600 "${dest}" || rc=1
    umask "${old_umask}"
    [[ "${rc:-0}" -eq 0 ]]
}

post_deploy_write_bouncer_key() {
    local key="$1" path dir tmp old_umask
    post_deploy_key_format_ok "${key}" || return 1
    path="$(post_deploy_bouncer_key_path)"
    dir="${path%/*}"
    mkdir -p "${dir}" || return 1
    chmod 700 "${dir}" || return 1
    old_umask="$(umask)"
    umask 077
    tmp="$(mktemp "${dir}/.bouncer-key.XXXXXX")" || { umask "${old_umask}"; return 1; }
    if ! printf '%s\n' "${key}" > "${tmp}"; then
        rm -f "${tmp}"
        umask "${old_umask}"
        return 1
    fi
    chmod 600 "${tmp}" || { rm -f "${tmp}"; umask "${old_umask}"; return 1; }
    if ! mv -f "${tmp}" "${path}"; then
        rm -f "${tmp}"
        umask "${old_umask}"
        return 1
    fi
    chmod 600 "${path}" || { umask "${old_umask}"; return 1; }
    umask "${old_umask}"
}

post_deploy_store_generated_key() {
    local key=""
    if ! key="$(crowdsec_generate_key)"; then
        return 1
    fi
    post_deploy_key_format_ok "${key}" || return 1
    post_deploy_write_bouncer_key "${key}"
}

crowdsec_container_state() {
    local running
    if ! running="$(docker inspect -f '{{.State.Running}}' "${CROWDSEC_CONTAINER}" 2>/dev/null)"; then
        printf '%s\n' missing
        return 0
    fi
    if [[ "${running}" == true ]]; then
        printf '%s\n' running
    else
        printf '%s\n' stopped
    fi
}

crowdsec_wait_lapi() {
    local attempts="${CROWDSEC_LAPI_ATTEMPTS:-5}" i
    for ((i = 1; i <= attempts; i++)); do
        if docker exec "${CROWDSEC_CONTAINER}" cscli bouncers list -o raw >/dev/null 2>&1; then
            return 0
        fi
        if (( i < attempts )); then
            sleep "${CROWDSEC_LAPI_DELAY:-1}"
        fi
    done
    return 1
}

post_deploy_install_collections() {
    local collection
    for collection in crowdsecurity/linux crowdsecurity/traefik; do
        if docker exec "${CROWDSEC_CONTAINER}" cscli collections inspect "${collection}" >/dev/null 2>&1; then
            ok "Collection already present: ${collection}"
        elif docker exec "${CROWDSEC_CONTAINER}" cscli collections install "${collection}" >/dev/null; then
            ok "Collection installed: ${collection}"
        else
            fail "Unable to install CrowdSec collection ${collection}. No bouncer was changed."
        fi
    done
}

crowdsec_bouncer_registered() {
    local raw
    if ! raw="$(docker exec "${CROWDSEC_CONTAINER}" cscli bouncers list -o raw 2>/dev/null)"; then
        return 2
    fi
    printf '%s\n' "${raw}" | post_deploy_raw_has_bouncer "${CROWDSEC_BOUNCER_NAME}"
}

crowdsec_probe_once() {
    local keyfile="$1" staged status code rc
    staged="$(mktemp)"
    chmod 600 "${staged}"
    if ! post_deploy_stage_key "${keyfile}" "${staged}"; then
        rm -f "${staged}"
        return 1
    fi
    status="$(
        docker exec -i "${CROWDSEC_CONTAINER}" \
            bash -c 'IFS= read -r key || exit 2
[[ -n "${key}" ]] || exit 2
exec 3<>/dev/tcp/crowdsec/8080 || exit 3
printf "GET /v1/decisions HTTP/1.0\r\nHost: crowdsec:8080\r\nX-Api-Key: %s\r\nConnection: close\r\n\r\n" "${key}" >&3
IFS= read -r line <&3 || exit 4
printf "%s\n" "${line}"' < "${staged}"
    )" && rc=0 || rc=$?
    rm -f "${staged}"
    [[ "${rc}" -eq 0 ]] || return 1
    code="$(printf '%s\n' "${status}" | awk 'NR == 1 { print $2 }')"
    code="${code//$'\r'/}"
    [[ "${code}" =~ ^[0-9]{3}$ ]] || return 1
    printf '%s\n' "${code}"
}

crowdsec_probe_key_file() {
    local keyfile="$1" attempts="${CROWDSEC_LAPI_ATTEMPTS:-5}" i code=""
    for ((i = 1; i <= attempts; i++)); do
        if code="$(crowdsec_probe_once "${keyfile}")"; then
            case "${code}" in
                200|403)
                    printf '%s\n' "${code}"
                    return 0
                    ;;
            esac
        else
            code=""
        fi
        if (( i < attempts )); then
            sleep "${CROWDSEC_LAPI_DELAY:-1}"
        fi
    done
    if [[ "${code}" =~ ^[0-9]{3}$ ]]; then
        printf '%s\n' "${code}"
    fi
    return 1
}

crowdsec_add_key_file() {
    local keyfile="$1" staged err
    staged="$(mktemp)"
    err="$(mktemp)"
    chmod 600 "${staged}" "${err}"
    if ! post_deploy_stage_key "${keyfile}" "${staged}"; then
        rm -f "${staged}" "${err}"
        return 1
    fi
    if ! docker exec -i "${CROWDSEC_CONTAINER}" \
        bash -c 'IFS= read -r key || exit 2
[[ -n "${key}" ]] || exit 2
cscli bouncers add "$1" --key "${key}" >/dev/null' \
        bash "${CROWDSEC_BOUNCER_NAME}" < "${staged}" 2>"${err}"; then
        rm -f "${staged}" "${err}"
        return 1
    fi
    rm -f "${staged}" "${err}"
}

crowdsec_generate_key() {
    local err key
    err="$(mktemp)"
    chmod 600 "${err}"
    if ! key="$(docker exec "${CROWDSEC_CONTAINER}" cscli bouncers add "${CROWDSEC_BOUNCER_NAME}" -o raw 2>"${err}")"; then
        rm -f "${err}"
        return 1
    fi
    rm -f "${err}"
    key="$(printf '%s' "${key}" | tr -d '[:space:]')"
    post_deploy_key_format_ok "${key}" || return 1
    printf '%s\n' "${key}"
}

crowdsec_delete_bouncer() {
    local name="$1"
    if ! post_deploy_deletable_bouncer "${name}"; then
        return 1
    fi
    if ! docker exec "${CROWDSEC_CONTAINER}" cscli bouncers delete "${name}" >/dev/null; then
        return 1
    fi
}

traefik_started_raw() {
    docker inspect -f '{{.State.StartedAt}}' "${TRAEFIK_CONTAINER}"
}

traefik_restart() {
    docker restart "${TRAEFIK_CONTAINER}" >/dev/null
}

post_deploy_restart_traefik_if_needed() {
    local path file_epoch started_raw started_epoch
    path="$(post_deploy_bouncer_key_path)"
    [[ -f "${path}" ]] || fail "Bouncer key file is missing, so Traefik was not restarted."
    file_epoch="$(stat -c '%Y' "${path}")"
    if ! started_raw="$(traefik_started_raw)"; then
        fail "Traefik start time is unavailable. The next run will retry the restart."
    fi
    if ! started_epoch="$(date -u -d "${started_raw}" +%s)"; then
        fail "Traefik start time could not be read. The next run will retry the restart."
    fi
    if post_deploy_restart_needed "${file_epoch}" "${started_epoch}"; then
        if ! traefik_restart; then
            fail "Traefik restart failed. The next run will retry the restart."
        fi
        ok "Traefik restarted to load the bouncer key."
    else
        ok "Traefik already started after the bouncer key. It was not restarted."
    fi
}

post_deploy_crowdsec() {
    print_section "CrowdSec bouncer"
    local state path dir key_state registered list_rc http action
    state="$(crowdsec_container_state)"
    case "${state}" in
        running) ;;
        missing) fail "CrowdSec container ${CROWDSEC_CONTAINER} does not exist. No bouncer was changed." ;;
        *) fail "CrowdSec container ${CROWDSEC_CONTAINER} is not running. No bouncer was changed." ;;
    esac
    if ! crowdsec_wait_lapi; then
        fail "CrowdSec LAPI is not ready. No bouncer was changed."
    fi
    post_deploy_install_collections
    path="$(post_deploy_bouncer_key_path)"
    key_state="$(post_deploy_key_file_state "${path}")"
    if [[ "${key_state}" == invalid ]]; then
        fail "Bouncer key file is not empty but its format is not recognized. It was not replaced."
    fi
    dir="${path%/*}"
    mkdir -p "${dir}"
    chmod 700 "${dir}"
    registered=no
    if crowdsec_bouncer_registered; then
        registered=yes
    else
        list_rc=$?
        if [[ "${list_rc}" -eq 2 ]]; then
            fail "CrowdSec LAPI bouncer list failed. No bouncer was changed."
        fi
        registered=no
    fi
    http=""
    if [[ "${key_state}" == valid ]]; then
        if ! http="$(crowdsec_probe_key_file "${path}")"; then
            if [[ "${http}" =~ ^[0-9]{3}$ ]]; then
                fail "CrowdSec LAPI returned status ${http}. No bouncer was changed."
            fi
            fail "CrowdSec LAPI did not answer the key check. No bouncer was changed."
        fi
        if [[ "${http}" != 200 && "${http}" != 403 ]]; then
            fail "CrowdSec LAPI returned status ${http}. No bouncer was changed."
        fi
    fi
    action="$(post_deploy_crowdsec_action "${key_state}" "${registered}" "${http}")"
    case "${action}" in
        refuse-invalid)
            fail "Bouncer key file is not empty but its format is not recognized. It was not replaced."
            ;;
        abort-lapi)
            fail "CrowdSec LAPI did not accept a key check. No bouncer was changed."
            ;;
        keep)
            chmod 600 "${path}"
            ok "Bouncer key already matches LAPI and was not replaced."
            ;;
        register-existing)
            if ! crowdsec_add_key_file "${path}"; then
                fail "Unable to register the existing bouncer key. The key file was not replaced."
            fi
            chmod 600 "${path}"
            ok "Existing bouncer key registered. The key was not logged."
            ;;
        repair-existing)
            if ! crowdsec_delete_bouncer "${CROWDSEC_BOUNCER_NAME}"; then
                fail "Unable to replace bouncer ${CROWDSEC_BOUNCER_NAME}. Other bouncers were not removed and the key file was not replaced."
            fi
            if ! crowdsec_add_key_file "${path}"; then
                fail "Bouncer ${CROWDSEC_BOUNCER_NAME} was removed and the existing key could not be registered again. The key file was not replaced."
            fi
            chmod 600 "${path}"
            ok "Bouncer registration now uses the stored key. The key was not logged."
            ;;
        replace-registered)
            if ! crowdsec_delete_bouncer "${CROWDSEC_BOUNCER_NAME}"; then
                fail "Unable to remove bouncer ${CROWDSEC_BOUNCER_NAME}. No new key was written."
            fi
            if ! post_deploy_store_generated_key; then
                fail "Unable to create a new bouncer key. No partial key was written."
            fi
            ok "New bouncer key stored. The key was not logged."
            ;;
        create-new)
            if ! post_deploy_store_generated_key; then
                fail "Unable to create bouncer ${CROWDSEC_BOUNCER_NAME}. No partial key was written."
            fi
            ok "Bouncer key stored. The key was not logged."
            ;;
        *)
            fail "Unknown CrowdSec bouncer action. No bouncer was changed."
            ;;
    esac
    post_deploy_restart_traefik_if_needed
}

post_deploy_record_version() {
    print_section "Installed version"
    local wanted="$1"
    local status
    status="$(docker exec -u www-data "${NEXTCLOUD_APP_CONTAINER}" php occ status || true)"
    printf '%s\n' "${status}" | grep -Eq 'installed:[[:space:]]*true' || fail "Nextcloud is not installed yet. State was not written."
    printf '%s\n' "${status}" | grep -F -q "version: ${wanted%-fpm}" || info "occ version line does not literally match ${wanted}. Recording the requested tag only if versionstring contains it."
    printf '%s\n' "${status}" | grep -F -q "${wanted%-fpm}" || fail "occ does not report ${wanted}. Installed-version was not written."
    mkdir -p "${NEXTCLOUD_STATE_DIR}"
    printf '%s\n' "${wanted}" > "${INSTALLED_VERSION_FILE}.tmp"
    mv "${INSTALLED_VERSION_FILE}.tmp" "${INSTALLED_VERSION_FILE}"
    ok "Recorded ${wanted}."
}
