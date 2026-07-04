#!/usr/bin/env bash
# Build and smoke-test an installed ReleaseSafe compiler artifact.
set -euo pipefail

ZIG="${ZIG:-zig}"
VERSION="${MCC_RELEASE_SAFE_TEST_VERSION:-0.7.0-test}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PREFIX="$WORK/prefix"
CACHE="$WORK/cache"
GLOBAL_CACHE="$WORK/global-cache"

"$ZIG" build install \
    -Doptimize=ReleaseSafe \
    -Dversion="$VERSION" \
    --prefix "$PREFIX" \
    --cache-dir "$CACHE" \
    --global-cache-dir "$GLOBAL_CACHE" \
    --summary none

test -x "$PREFIX/bin/mcc"
test -x "$PREFIX/bin/mcc-real"

OUT_FILE="$WORK/stdout.txt"
ERR_FILE="$WORK/stderr.txt"
"$PREFIX/bin/mcc" --version >"$OUT_FILE" 2>"$ERR_FILE"
OUT="$(cat "$OUT_FILE")"
if [ "$OUT" != "mcc $VERSION" ]; then
    echo "FAIL: release-safe-install-test - unexpected --version output"
    echo "got: $OUT"
    echo "want: mcc $VERSION"
    exit 1
fi
if [ -s "$ERR_FILE" ]; then
    echo "FAIL: release-safe-install-test - --version wrote stderr"
    cat "$ERR_FILE"
    exit 1
fi

echo "PASS: release-safe-install-test - ReleaseSafe install launches and reports version"
