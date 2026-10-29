#!/usr/bin/env bash

declare -gA ENV_POLICY

ENV_POLICY[TZ]="user"
ENV_POLICY[COMPOSE_PROJECT_NAME]="framework"
ENV_POLICY[DATA_DIR]="framework"
ENV_POLICY[NEXTCLOUD_HTML_HOST_DIR]="framework"
ENV_POLICY[POSTGRESQL_HOST_DIR]="user"
ENV_POLICY[NEXTCLOUD_DATA_HOST_DIR]="user"
ENV_POLICY[NEXTCLOUD_SOURCE_DATA_DIR]="user"
ENV_POLICY[NEXTCLOUD_DOMAIN]="framework"
ENV_POLICY[NEXTCLOUD_TRUSTED_DOMAINS]="framework"
ENV_POLICY[NEXTCLOUD_IMAGE]="framework"
ENV_POLICY[NEXTCLOUD_TAG]="framework"
ENV_POLICY[POSTGRES_IMAGE]="framework"
ENV_POLICY[REDIS_IMAGE]="framework"
ENV_POLICY[NGINX_IMAGE]="framework"
ENV_POLICY[TRAEFIK_IMAGE]="framework"
ENV_POLICY[CROWDSEC_IMAGE]="framework"
ENV_POLICY[CROWDSEC_BOUNCER_PLUGIN]="framework"
ENV_POLICY[METABASE_IMAGE]="framework"
ENV_POLICY[METABASE_POSTGRES_IMAGE]="framework"
ENV_POLICY[DOCKER_PROXY_SUBNET]="user"
ENV_POLICY[DOCKER_PROXY_GATEWAY]="user"
ENV_POLICY[DOCKER_INTERNAL_SUBNET]="user"
ENV_POLICY[DOCKER_INTERNAL_GATEWAY]="user"
ENV_POLICY[PG_DB]="framework"
ENV_POLICY[PG_USER]="framework"
ENV_POLICY[PG_PASS]="generated"
ENV_POLICY[REDIS_CONFIG_FILE]="framework"
ENV_POLICY[REDIS_PASSWORD]="generated"
ENV_POLICY[NEXTCLOUD_ADMIN_USER]="user"
ENV_POLICY[NEXTCLOUD_ADMIN_PASSWORD]="generated"
ENV_POLICY[TRUSTED_PROXIES]="user"
ENV_POLICY[OVERWRITEPROTOCOL]="framework"
ENV_POLICY[OVERWRITEHOST]="framework"
ENV_POLICY[OVERWRITECLIURL]="framework"
ENV_POLICY[FORWARDED_FOR_HEADERS]="framework"
ENV_POLICY[PROXY_PROTOCOL_MODE]="user"
ENV_POLICY[PROXY_PROTOCOL_TRUSTED_IPS]="user"
ENV_POLICY[TRAEFIK_TLS_MODE]="user"
ENV_POLICY[TRAEFIK_ACME_EMAIL]="user"
ENV_POLICY[TRAEFIK_ADMIN_PUBLISH]="user"
ENV_POLICY[ADMIN_IP_ALLOWLIST]="user"
ENV_POLICY[METABASE_HOST]="user"
ENV_POLICY[METABASE_SITE_URL]="user"
ENV_POLICY[METABASE_DB_NAME]="framework"
ENV_POLICY[METABASE_DB_USER]="framework"
ENV_POLICY[METABASE_DB_PASSWORD]="generated"
ENV_POLICY[PHP_MEMORY_LIMIT]="framework"
ENV_POLICY[PHP_UPLOAD_LIMIT]="framework"
ENV_POLICY[PHP_OPCACHE_MEMORY_CONSUMPTION]="framework"
ENV_POLICY[LOG_MAX_SIZE]="framework"
ENV_POLICY[LOG_MAX_FILES]="framework"
ENV_POLICY[BACKUP_LOCAL_DIR]="framework"
ENV_POLICY[BACKUP_EXTERNAL_DIR]="user"
ENV_POLICY[BACKUP_AGE_RECIPIENT]="user"
ENV_POLICY[RESTIC_REPOSITORY]="user"
ENV_POLICY[RESTIC_PASSWORD]="generated"
ENV_POLICY[RESTIC_KEEP_DAILY]="framework"
ENV_POLICY[RESTIC_KEEP_WEEKLY]="framework"
ENV_POLICY[RESTIC_KEEP_MONTHLY]="framework"
ENV_POLICY[RESTIC_KEEP_YEARLY]="framework"
ENV_POLICY[UPGRADE_MIN_FREE_MB]="framework"
ENV_POLICY[SMTP_HOST]="user"
ENV_POLICY[SMTP_PORT]="user"
ENV_POLICY[SMTP_SECURE]="user"
ENV_POLICY[SMTP_NAME]="user"
ENV_POLICY[SMTP_PASSWORD]="user"
ENV_POLICY[MAIL_FROM_ADDRESS]="user"
ENV_POLICY[MAIL_DOMAIN]="user"

env_is_placeholder() { [[ "$1" == set_* ]]; }
env_is_sensitive() {
    [[ "$1" == *PASSWORD* || "$1" == *SECRET* || "$1" == PG_PASS ]]
}

env_parse_file() {
    local file="$1"
    local array_name="$2"
    local line key value
    [[ -f "${file}" ]] || fail "Missing env file: ${file}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" == *=* ]] || fail "Not a variable assignment: ${line}"
        key="${line%%=*}"
        value="${line#*=}"
        [[ "${key}" =~ ^[A-Z0-9_]+$ ]] || fail "Invalid variable name: ${key}"
        eval "${array_name}[\"${key}\"]=\"\${value}\""
    done < "${file}"
}

env_generate_secret() {
    local bytes="$1" value
    require_command openssl
    value="$(openssl rand -base64 "${bytes}" | tr -d '\n')"
    [[ -n "${value}" ]] || fail "openssl returned an empty secret."
    printf '%s\n' "${value}"
}

env_generate_secret_for() {
    case "$1" in
        PG_PASS|REDIS_PASSWORD|RESTIC_PASSWORD|METABASE_DB_PASSWORD) env_generate_secret 36 ;;
        NEXTCLOUD_ADMIN_PASSWORD) env_generate_secret 24 ;;
        *) fail "No secret generator for $1." ;;
    esac
}

env_ipv4_octets_ok() {
    local ip="$1" octet
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.
    # shellcheck disable=SC2086
    for octet in ${ip}; do
        [[ "$((10#${octet}))" -le 255 ]] || return 1
    done
}

env_ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%s\n' $(( (10#${a} << 24) + (10#${b} << 16) + (10#${c} << 8) + 10#${d} ))
}

env_cidr_ok() {
    local cidr="$1" base prefix
    [[ "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    base="${cidr%/*}"
    prefix="${cidr#*/}"
    env_ipv4_octets_ok "${base}" || return 1
    [[ "$((10#${prefix}))" -le 32 ]] || return 1
}

env_cidr_contains_ip() {
    local cidr="$1" ip="$2" base prefix ip_int base_int mask
    base="${cidr%/*}"; prefix="${cidr#*/}"
    ip_int="$(env_ipv4_to_int "${ip}")"
    base_int="$(env_ipv4_to_int "${base}")"
    if [[ "${prefix}" -eq 0 ]]; then return 0; fi
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    [[ $(( ip_int & mask )) -eq $(( base_int & mask )) ]]
}

env_cidr_is_network_address() {
    local cidr="$1" base prefix base_int mask network
    base="${cidr%/*}"; prefix="${cidr#*/}"
    base_int="$(env_ipv4_to_int "${base}")"
    if [[ "${prefix}" -eq 0 ]]; then
        [[ "${base}" == "0.0.0.0" ]]
        return
    fi
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    network=$(( base_int & mask ))
    [[ "${network}" -eq "${base_int}" ]]
}

env_ip_private() {
    local ip="$1"
    env_cidr_contains_ip "10.0.0.0/8" "${ip}" && return 0
    env_cidr_contains_ip "172.16.0.0/12" "${ip}" && return 0
    env_cidr_contains_ip "192.168.0.0/16" "${ip}" && return 0
    env_cidr_contains_ip "100.64.0.0/10" "${ip}" && return 0
    return 1
}

env_cidr_overlaps() {
    local a="$1" b="$2"
    env_cidr_contains_ip "${a}" "${b%/*}" && return 0
    env_cidr_contains_ip "${b}" "${a%/*}" && return 0
    return 1
}

env_path_ok() {
    local name="$1" value="$2"
    [[ "${value}" == /* ]] || fail "${name} must be an absolute path."
    [[ "${value}" != "/" && "${value}" != *..* ]] || fail "${name} is not a safe path."
}

env_path_nested() {
    local a="$1" b="$2"
    [[ "${a}" == "${b}" || "${a}" == "${b}"/* || "${b}" == "${a}"/* ]]
}

env_validate_subnet_pair() {
    local name="$1" subnet="$2" gateway="$3" prefix
    env_cidr_ok "${subnet}" || fail "${name} subnet is not a CIDR."
    env_cidr_is_network_address "${subnet}" || fail "${name} subnet must be the network address."
    prefix="${subnet#*/}"
    [[ "${prefix}" -ge 16 && "${prefix}" -le 28 ]] || fail "${name} prefix must be between 16 and 28."
    [[ "${subnet}" != "0.0.0.0/0" ]] || fail "${name} must not be 0.0.0.0/0."
    env_ip_private "${subnet%/*}" || fail "${name} must be RFC1918 or CGNAT."
    env_ipv4_octets_ok "${gateway}" || fail "${name} gateway is not an IPv4 address."
    env_cidr_contains_ip "${subnet}" "${gateway}" || fail "${name} gateway is outside its subnet."
    [[ "${gateway}" != "${subnet%/*}" ]] || fail "${name} gateway must not be the network address."
}

env_validate_runtime() {
    local IFS=$' \t\n'
    local -n env_ref=$1
    local key value proxy internal

    [[ "${env_ref[COMPOSE_PROJECT_NAME]}" == "${STACK_NAME}" ]] || fail "COMPOSE_PROJECT_NAME must be ${STACK_NAME}."
    [[ "${env_ref[DATA_DIR]}" == "${DATA_DIR}" ]] || fail "DATA_DIR must be ${DATA_DIR}."
    [[ "${env_ref[NEXTCLOUD_HTML_HOST_DIR]}" == "${DATA_DIR}/html" ]] || fail "NEXTCLOUD_HTML_HOST_DIR must be ${DATA_DIR}/html."
    [[ "${env_ref[BACKUP_LOCAL_DIR]}" == "${BACKUP_LOCAL_DIR}" ]] || fail "BACKUP_LOCAL_DIR must be ${BACKUP_LOCAL_DIR}."
    [[ "${env_ref[NEXTCLOUD_DOMAIN]}" == "${NEXTCLOUD_DOMAIN}" ]] || fail "NEXTCLOUD_DOMAIN must be ${NEXTCLOUD_DOMAIN}."
    [[ "${env_ref[OVERWRITEHOST]}" == "${NEXTCLOUD_DOMAIN}" ]] || fail "OVERWRITEHOST must be ${NEXTCLOUD_DOMAIN}."
    [[ "${env_ref[OVERWRITEPROTOCOL]}" == "https" ]] || fail "OVERWRITEPROTOCOL must be https."
    [[ "${env_ref[OVERWRITECLIURL]}" == "https://${NEXTCLOUD_DOMAIN}" ]] || fail "OVERWRITECLIURL must be https://${NEXTCLOUD_DOMAIN}."
    [[ "${env_ref[NEXTCLOUD_TRUSTED_DOMAINS]}" == *"${NEXTCLOUD_DOMAIN}"* ]] || fail "NEXTCLOUD_TRUSTED_DOMAINS must include ${NEXTCLOUD_DOMAIN}."

    [[ "${env_ref[NEXTCLOUD_TAG]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-fpm$ ]] || fail "NEXTCLOUD_TAG must be an exact X.Y.Z-fpm release."
    [[ "${env_ref[POSTGRES_IMAGE]}" =~ ^docker\.io/library/postgres:18\.[0-9]+$ ]] || fail "POSTGRES_IMAGE must be an exact postgres 18 patch."
    [[ "${env_ref[METABASE_POSTGRES_IMAGE]}" =~ ^docker\.io/library/postgres:17\.[0-9]+$ ]] || fail "METABASE_POSTGRES_IMAGE must be an exact postgres 17 patch."
    [[ "${env_ref[REDIS_IMAGE]}" =~ ^docker\.io/library/redis:[0-9]+\.[0-9]+\.[0-9]+-alpine$ ]] || fail "REDIS_IMAGE must be an exact patch tag."
    [[ "${env_ref[NGINX_IMAGE]}" =~ ^docker\.io/library/nginx:[0-9]+\.[0-9]+\.[0-9]+-alpine$ ]] || fail "NGINX_IMAGE must be an exact patch tag."
    [[ "${env_ref[TRAEFIK_IMAGE]}" == "docker.io/library/traefik:v3.6.22" ]] || fail "TRAEFIK_IMAGE must stay on v3.6.22 until the access-log behaviour is rechecked."
    [[ "${env_ref[CROWDSEC_IMAGE]}" =~ ^docker\.io/crowdsecurity/crowdsec:v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "CROWDSEC_IMAGE must be an exact tag."
    [[ "${env_ref[CROWDSEC_BOUNCER_PLUGIN]}" == "v1.7.0" ]] || fail "CROWDSEC_BOUNCER_PLUGIN must stay on v1.7.0 until its IP handling is rechecked."

    env_validate_subnet_pair "DOCKER_PROXY" "${env_ref[DOCKER_PROXY_SUBNET]}" "${env_ref[DOCKER_PROXY_GATEWAY]}"
    env_validate_subnet_pair "DOCKER_INTERNAL" "${env_ref[DOCKER_INTERNAL_SUBNET]}" "${env_ref[DOCKER_INTERNAL_GATEWAY]}"
    if env_cidr_overlaps "${env_ref[DOCKER_PROXY_SUBNET]}" "${env_ref[DOCKER_INTERNAL_SUBNET]}"; then
        fail "Docker proxy and internal subnets overlap."
    fi

    [[ "${env_ref[TRUSTED_PROXIES]}" != *","* ]] || fail "TRUSTED_PROXIES is space-separated."
    local cidr
    for cidr in ${env_ref[TRUSTED_PROXIES]}; do
        env_cidr_ok "${cidr}" || fail "Invalid TRUSTED_PROXIES CIDR: ${cidr}"
        [[ "${cidr}" != "0.0.0.0/0" ]] || fail "TRUSTED_PROXIES must not be 0.0.0.0/0."
        env_cidr_contains_ip "${env_ref[DOCKER_PROXY_SUBNET]}" "${cidr%/*}" \
            || fail "TRUSTED_PROXIES ${cidr} is outside DOCKER_PROXY_SUBNET. Nextcloud must trust only the Traefik Docker network."
    done

    env_path_ok "POSTGRESQL_HOST_DIR" "${env_ref[POSTGRESQL_HOST_DIR]}"
    env_path_ok "NEXTCLOUD_DATA_HOST_DIR" "${env_ref[NEXTCLOUD_DATA_HOST_DIR]}"
    local pg="${env_ref[POSTGRESQL_HOST_DIR]}"
    local data="${env_ref[NEXTCLOUD_DATA_HOST_DIR]}"
    local metabase_pg="${DATA_DIR}/metabase/postgres"
    env_path_nested "${pg}" "${data}" && fail "Nextcloud PostgreSQL and Nextcloud data directories overlap."
    env_path_nested "${pg}" "${metabase_pg}" && fail "Nextcloud PostgreSQL and Metabase PostgreSQL directories overlap."
    env_path_nested "${data}" "${metabase_pg}" && fail "Nextcloud data and Metabase PostgreSQL directories overlap."
    [[ "${pg}" != "${LEGACY_MARIADB_DIR}" && "${pg}" != "${LEGACY_APP_DIR}" && "${pg}" != "${LEGACY_REDIS_DIR}" && "${pg}" != "${LEGACY_USER_DATA_DIR}" ]] \
        || fail "POSTGRESQL_HOST_DIR points at a legacy Gregor path."
    [[ "${data}" != "${LEGACY_USER_DATA_DIR}" && "${data}" != "${LEGACY_APP_DIR}" ]] \
        || fail "NEXTCLOUD_DATA_HOST_DIR points at a legacy Gregor path."
    case "${pg}" in
        "${DATA_DIR}"|"${DATA_DIR}"/*|"${STACK_DIR}"|"${STACK_DIR}"/*|"${GIT_DIR}"|"${GIT_DIR}"/*|"${BACKUP_LOCAL_DIR}"|"${BACKUP_LOCAL_DIR}"/*)
            fail "POSTGRESQL_HOST_DIR must stay outside this project's Git checkout, stack, HTML tree and backups."
            ;;
    esac

    [[ "${#env_ref[PG_PASS]}" -ge 16 && "${#env_ref[PG_PASS]}" -le 99 ]] || fail "PG_PASS must be 16 to 99 characters."
    [[ "${#env_ref[REDIS_PASSWORD]}" -ge 16 ]] || fail "REDIS_PASSWORD is too short."
    [[ "${#env_ref[NEXTCLOUD_ADMIN_PASSWORD]}" -ge 16 ]] || fail "NEXTCLOUD_ADMIN_PASSWORD is too short."
    [[ "${#env_ref[METABASE_DB_PASSWORD]}" -ge 16 && "${#env_ref[METABASE_DB_PASSWORD]}" -le 99 ]] || fail "METABASE_DB_PASSWORD must be 16 to 99 characters."
    [[ "${#env_ref[RESTIC_PASSWORD]}" -ge 16 ]] || fail "RESTIC_PASSWORD is too short."
    [[ "${env_ref[PG_USER]}" != "${POSTGRES_BOOTSTRAP_USER}" ]] || fail "PG_USER must not be the bootstrap superuser."
    [[ "${env_ref[METABASE_DB_NAME]}" != "${env_ref[PG_DB]}" ]] || fail "Metabase and Nextcloud must not share a database name in configuration."

    case "${env_ref[PROXY_PROTOCOL_MODE]}" in
        local)
            [[ -z "${env_ref[PROXY_PROTOCOL_TRUSTED_IPS]}" ]] \
                || fail "PROXY_PROTOCOL_MODE=local must keep PROXY_PROTOCOL_TRUSTED_IPS empty."
            ;;
        haproxy)
            [[ -n "${env_ref[PROXY_PROTOCOL_TRUSTED_IPS]}" ]] \
                || fail "PROXY_PROTOCOL_MODE=haproxy needs PROXY_PROTOCOL_TRUSTED_IPS."
            [[ "${env_ref[TRAEFIK_TLS_MODE]}" == "letsencrypt" ]] \
                || fail "HAProxy mode requires TRAEFIK_TLS_MODE=letsencrypt."
            local proxy_ip
            for proxy_ip in ${env_ref[PROXY_PROTOCOL_TRUSTED_IPS]}; do
                env_cidr_ok "${proxy_ip}" || fail "Invalid PROXY source: ${proxy_ip}"
                [[ "${proxy_ip}" == */32 ]] || fail "PROXY source ${proxy_ip} must be a /32. A wider range is not a verified HAProxy address."
                [[ "${proxy_ip}" != "0.0.0.0/0" ]] || fail "PROXY protocol must not trust every address."
            done
            ;;
        *)
            fail "PROXY_PROTOCOL_MODE must be local or haproxy."
            ;;
    esac

    case "${env_ref[TRAEFIK_TLS_MODE]}" in
        local) ;;
        letsencrypt)
            [[ "${env_ref[TRAEFIK_ACME_EMAIL]}" == *@*.* ]] || fail "TRAEFIK_ACME_EMAIL is not an email address."
            env_is_placeholder "${env_ref[TRAEFIK_ACME_EMAIL]}" && fail "TRAEFIK_ACME_EMAIL is still a placeholder."
            ;;
        *) fail "TRAEFIK_TLS_MODE must be local or letsencrypt." ;;
    esac

    if [[ -n "${env_ref[TRAEFIK_ADMIN_PUBLISH]}" ]]; then
        [[ "${env_ref[TRAEFIK_ADMIN_PUBLISH]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:8443:8443$ ]] \
            || fail "TRAEFIK_ADMIN_PUBLISH must look like ADDRESS:8443:8443."
        local admin_ip="${env_ref[TRAEFIK_ADMIN_PUBLISH]%%:*}"
        [[ "${admin_ip}" != "0.0.0.0" ]] || fail "The admin entrypoint must not listen on 0.0.0.0."
        env_ip_private "${admin_ip}" || fail "TRAEFIK_ADMIN_PUBLISH must use a private address."
    fi

    [[ -n "${env_ref[ADMIN_IP_ALLOWLIST]}" ]] || fail "ADMIN_IP_ALLOWLIST is empty."
    local allow
    for allow in ${env_ref[ADMIN_IP_ALLOWLIST]}; do
        env_cidr_ok "${allow}" || fail "Invalid ADMIN_IP_ALLOWLIST CIDR: ${allow}"
        [[ "${allow}" != "0.0.0.0/0" ]] || fail "ADMIN_IP_ALLOWLIST must not be 0.0.0.0/0."
        env_ip_private "${allow%/*}" || fail "ADMIN_IP_ALLOWLIST must be a private range."
    done

    [[ "${env_ref[METABASE_HOST]}" != "${NEXTCLOUD_DOMAIN}" ]] || fail "METABASE_HOST must not be the public Nextcloud domain."
    [[ "${env_ref[METABASE_HOST]}" =~ ^[A-Za-z0-9.-]+$ ]] || fail "METABASE_HOST contains unsupported characters."
    [[ "${env_ref[METABASE_SITE_URL]}" == "https://${env_ref[METABASE_HOST]}" || "${env_ref[METABASE_SITE_URL]}" == "https://${env_ref[METABASE_HOST]}/" || "${env_ref[METABASE_SITE_URL]}" =~ ^https://${env_ref[METABASE_HOST]}:[0-9]+/?$ ]] \
        || fail "METABASE_SITE_URL must be https on METABASE_HOST."
    [[ "${env_ref[METABASE_SITE_URL]}" != *"${NEXTCLOUD_DOMAIN}"* ]] || fail "METABASE_SITE_URL must not use the Nextcloud domain."

    [[ -f "${HTPASSWD_FILE}" ]] || fail "Dashboard BasicAuth file is missing. Run ./scripts/create-dashboard-user.sh before deploy."

    if [[ -n "${env_ref[BACKUP_AGE_RECIPIENT]}" ]]; then
        [[ "${env_ref[BACKUP_AGE_RECIPIENT]}" != AGE-SECRET-KEY-* ]] || fail "BACKUP_AGE_RECIPIENT must be a public recipient."
    fi

    if [[ -n "${env_ref[SMTP_HOST]}" ]]; then
        [[ -n "${env_ref[SMTP_NAME]}" && -n "${env_ref[SMTP_PASSWORD]}" && -n "${env_ref[MAIL_FROM_ADDRESS]}" && -n "${env_ref[MAIL_DOMAIN]}" ]] \
            || fail "SMTP_HOST is set, so the other SMTP values are required."
    fi
}

declare -gA RUNTIME_ENV

env_load_runtime() {
    [[ -f "${ENV_FILE}" ]] || fail "Runtime .env is missing. Run ./scripts/update-env.sh."
    env_parse_file "${ENV_FILE}" RUNTIME_ENV
    local key
    for key in "${!ENV_POLICY[@]}"; do
        [[ -v RUNTIME_ENV["${key}"] ]] || fail "Missing variable: ${key}"
        if [[ -z "${RUNTIME_ENV[${key}]}" ]]; then
            case "${key}" in
                NEXTCLOUD_SOURCE_DATA_DIR|PROXY_PROTOCOL_TRUSTED_IPS|TRAEFIK_ADMIN_PUBLISH|BACKUP_EXTERNAL_DIR|BACKUP_AGE_RECIPIENT|SMTP_HOST|SMTP_NAME|SMTP_PASSWORD|MAIL_FROM_ADDRESS|MAIL_DOMAIN)
                    ;;
                *) fail "Empty variable: ${key}" ;;
            esac
        fi
        if env_is_placeholder "${RUNTIME_ENV[${key}]}"; then
            if [[ "${key}" == "TRAEFIK_ACME_EMAIL" ]]; then
                continue
            fi
            fail "Placeholder is not usable: ${key}"
        fi
    done
    env_validate_runtime RUNTIME_ENV
}

env_sync_file() {
    local example="$1" target="$2"
    [[ -f "${example}" ]] || fail "Missing ${example}"
    declare -A CURRENT=()
    if [[ -f "${target}" ]]; then
        env_parse_file "${target}" CURRENT
    fi
    local tmp line key value policy existing
    tmp="$(mktemp "${target}.tmp.XXXXXX")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# || "${line}" != *=* ]]; then
            printf '%s\n' "${line}" >> "${tmp}"
            continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        policy="${ENV_POLICY[${key}]:-user}"
        existing="${CURRENT[${key}]:-}"
        case "${policy}" in
            framework) ;;
            user)
                if [[ -n "${existing}" ]]; then
                    value="${existing}"
                fi
                ;;
            generated)
                if [[ -n "${existing}" ]] && ! env_is_placeholder "${existing}"; then
                    value="${existing}"
                else
                    value="$(env_generate_secret_for "${key}")"
                fi
                ;;
        esac
        printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    done < "${example}"
    chmod 600 "${tmp}"
    if [[ -f "${target}" ]]; then
        cp -a "${target}" "${target}.bak-$(date +%Y%m%d-%H%M%S)"
        chmod 600 "${target}.bak-"* 2>/dev/null || true
    fi
    mv "${tmp}" "${target}"
    chmod 600 "${target}"
}
