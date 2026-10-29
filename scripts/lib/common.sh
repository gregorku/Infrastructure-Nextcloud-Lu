#!/usr/bin/env bash

require_root() {
    [[ "${EUID}" -eq 0 ]] || fail "This script must be run as root inside the Incus container."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

check_environment() {
    require_root
    require_command git
    require_command rsync
    ok "Environment OK."
}

require_mountpoint() {
    local path="$1"
    [[ -d "${path}" ]] || fail "${path} does not exist. This project does not create the Incus disk."
    findmnt -T "${path}" >/dev/null 2>&1 || fail "${path} is not a mount. Refusing to store data on the container root filesystem."
    local target
    target="$(findmnt -T "${path}" -n -o TARGET)"
    [[ "${target}" == "${path}" ]] || fail "${path} is not the mountpoint (findmnt reports ${target})."
}
