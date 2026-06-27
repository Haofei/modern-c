#!/usr/bin/env bash
# Shared shell helpers for MC test scripts.
#
# Keep this file small and bash-3-compatible: macOS still ships an older bash, so
# common test helpers must avoid mapfile/readarray and empty-array expansions under
# `set -u`.

mc_repo_root() {
    local d
    d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
    while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do
        d=$(dirname "$d")
    done
    printf '%s' "$d"
}

mc_host_jobs() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
        return
    fi
    if command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.ncpu 2>/dev/null && return
    fi
    if command -v getconf >/dev/null 2>&1; then
        getconf _NPROCESSORS_ONLN 2>/dev/null && return
    fi
    echo 4
}

mc_link_flags() {
    if [ "$(uname -s)" = "Linux" ]; then
        printf '%s' "-no-pie"
    fi
}

mc_skip() {
    local name="$1"
    local reason="$2"
    echo "SKIP: $name ($reason)"
    exit 0
}

mc_require_cmd() {
    local name="$1"
    local cmd="$2"
    command -v "$cmd" >/dev/null 2>&1 || mc_skip "$name" "$cmd not found"
}

mc_count_lines() {
    local file="$1"
    awk 'END { print NR }' "$file"
}
