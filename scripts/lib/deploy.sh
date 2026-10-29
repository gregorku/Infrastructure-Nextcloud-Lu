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

    cat > "${dynamic}/metabase.yml" <<EOF
http:
  routers:
    metabase-lu:
      entryPoints:
        - admin
      rule: "Host(\`$(yaml_quote "${RUNTIME_ENV[METABASE_HOST]}")\`)"
      service: metabase-lu
      middlewares:
        - default-chain
      tls:
        options: default
      priority: 10
  services:
    metabase-lu:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: http://metabase:3000
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

post_deploy_crowdsec() {
    print_section "CrowdSec bouncer"
    docker inspect -f '{{.State.Running}}' "${CROWDSEC_CONTAINER}" | grep -qx true || fail "CrowdSec is not running."
    local collection
    for collection in crowdsecurity/linux crowdsecurity/traefik; do
        if docker exec "${CROWDSEC_CONTAINER}" cscli collections inspect "${collection}" >/dev/null 2>&1; then
            ok "Collection already present: ${collection}"
        else
            docker exec "${CROWDSEC_CONTAINER}" cscli collections install "${collection}" >/dev/null
            ok "Collection installed: ${collection}"
        fi
    done
    if [[ -f "${BOUNCER_KEY_FILE}" ]]; then
        ok "Bouncer key already exists and was not replaced."
        return 0
    fi
    local key
    if ! key="$(docker exec "${CROWDSEC_CONTAINER}" cscli bouncers add "${CROWDSEC_BOUNCER_NAME}" -o raw)"; then
        fail "Unable to create bouncer ${CROWDSEC_BOUNCER_NAME}. Existing bouncers were not removed."
    fi
    key="$(printf '%s' "${key}" | tr -d '[:space:]')"
    [[ "${key}" =~ ^[A-Za-z0-9+/=_-]{20,}$ ]] || fail "Bouncer key was not written because its format was not recognized."
    umask 077
    printf '%s\n' "${key}" > "${BOUNCER_KEY_FILE}"
    chmod 600 "${BOUNCER_KEY_FILE}"
    docker restart "${TRAEFIK_CONTAINER}" >/dev/null
    ok "Bouncer key stored and Traefik restarted. The key was not logged."
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
