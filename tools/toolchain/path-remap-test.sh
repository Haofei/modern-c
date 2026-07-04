#!/usr/bin/env bash
# Gate source artifact path remapping for release reproducibility/auditability.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RAW_ROOT="$WORK/raw-root"
SRC_DIR="$RAW_ROOT/project"
mkdir -p "$SRC_DIR"

SRC="$SRC_DIR/main.mc"
cat >"$SRC" <<'MC'
global seed: u32 = 1;

export fn answer() -> u32 {
    return seed + 41;
}
MC

LOGICAL_ROOT="/mc/release-src"
REMAPPED_PATH="$LOGICAL_ROOT/project/main.mc"
C_OUT="$WORK/out.c"
MAP_OUT="$WORK/out.mcmap"
C_STDOUT="$WORK/emit-c.stdout"
MAP_STDOUT="$WORK/emit-map.stdout"

"$MCC" emit-c "$SRC" --remap-prefix="$RAW_ROOT=$LOGICAL_ROOT" -o "$C_OUT" >"$C_STDOUT"
"$MCC" emit-map "$SRC" --remap-prefix="$RAW_ROOT=$LOGICAL_ROOT" -o "$MAP_OUT" >"$MAP_STDOUT"

if [ -s "$C_STDOUT" ] || [ -s "$MAP_STDOUT" ]; then
    echo "FAIL: path-remap-test — -o artifact emission wrote stdout"
    echo "emit-c stdout:"
    cat "$C_STDOUT"
    echo "emit-map stdout:"
    cat "$MAP_STDOUT"
    exit 1
fi

if grep -Fq "$RAW_ROOT" "$C_OUT"; then
    echo "FAIL: path-remap-test — emitted C leaked raw temp source prefix"
    grep -Fn "$RAW_ROOT" "$C_OUT" || true
    exit 1
fi

if grep -Fq "$RAW_ROOT" "$MAP_OUT"; then
    echo "FAIL: path-remap-test — emit-map leaked raw temp source prefix"
    grep -Fn "$RAW_ROOT" "$MAP_OUT" || true
    exit 1
fi

if ! grep -Fq "#line 1 \"$REMAPPED_PATH\"" "$C_OUT"; then
    echo "FAIL: path-remap-test — emitted C did not use remapped #line path"
    grep -Fn '#line' "$C_OUT" || true
    exit 1
fi

if ! grep -Fq "source_path=\"$REMAPPED_PATH\"" "$MAP_OUT"; then
    echo "FAIL: path-remap-test — emit-map did not use remapped source_path metadata"
    grep -Fn 'source_path=' "$MAP_OUT" || true
    exit 1
fi

SIBLING_ROOT="$WORK/raw-root-sibling"
SIBLING_SRC="$SIBLING_ROOT/main.mc"
mkdir -p "$SIBLING_ROOT"
cp "$SRC" "$SIBLING_SRC"
"$MCC" emit-c "$SIBLING_SRC" --remap-prefix="$RAW_ROOT=$LOGICAL_ROOT" >"$WORK/sibling.c"
if grep -Fq "$LOGICAL_ROOT-sibling" "$WORK/sibling.c"; then
    echo "FAIL: path-remap-test — remap-prefix matched a non-boundary sibling prefix"
    grep -Fn "$LOGICAL_ROOT" "$WORK/sibling.c" || true
    exit 1
fi

echo "PASS: path-remap-test — emit-c #line and emit-map source_path remap absolute temp prefixes without leaking raw paths"
