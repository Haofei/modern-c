#!/usr/bin/env bash
# Installed mcc launcher. All compiler commands, including `mcc build`, exec the
# private compiler so the documented CLI contract has one dispatch path. The
# standalone tools/toolchain/mcc-build.sh helper remains available for direct
# toolchain use, but the installed `mcc` binary does not special-case it.
set -euo pipefail

BIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$(dirname "$BIN_DIR")"
REAL="${MCC_REAL:-$BIN_DIR/mcc-real}"

if [ ! -x "$REAL" ]; then
    echo "mcc: private compiler not found or not executable at $REAL" >&2
    exit 1
fi
exec "$REAL" "$@"
