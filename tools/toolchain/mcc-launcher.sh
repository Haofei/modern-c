#!/usr/bin/env bash
# Installed mcc launcher. Regular compiler commands exec the private compiler;
# `mcc build` is owned by the toolchain layer so src/* stays process-free.
set -euo pipefail

BIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$(dirname "$BIN_DIR")"
REAL="${MCC_REAL:-$BIN_DIR/mcc-real}"

if [ "${1:-}" = "build" ]; then
    shift
    HELPER="${MCC_BUILD_HELPER:-$PREFIX/tools/toolchain/mcc-build.sh}"
    if [ ! -f "$HELPER" ]; then
        echo "mcc: build helper not found at $HELPER" >&2
        exit 1
    fi
    MCC_REAL="$REAL" exec bash "$HELPER" "$@"
fi

if [ ! -x "$REAL" ]; then
    echo "mcc: private compiler not found or not executable at $REAL" >&2
    exit 1
fi
exec "$REAL" "$@"
