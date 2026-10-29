#!/usr/bin/env bash

info() { printf '  %b\n' "${COLOR_BLUE:-}*${COLOR_RESET:-} $*"; }
ok() { printf '  %b\n' "${COLOR_GREEN:-}+${COLOR_RESET:-} $*"; }
warn() { printf '  %b\n' "${COLOR_YELLOW:-}!${COLOR_RESET:-} $*" >&2; }
fail() { printf '  %b\n' "${COLOR_RED:-}x${COLOR_RESET:-} $*" >&2; exit 1; }

print_header() {
    printf '\n%s\n%s\n' "$1" "--------------------------------------------------------------------------------"
}

print_section() {
    printf '\n-- %s\n' "$1"
}

print_footer() {
    printf '\n%s\n' "$1"
}
