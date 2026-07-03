#!/usr/bin/env bash
# P0 Stage0/Stage1/Stage2 scaffold for the full-selfhost project.
#
# This currently exercises the existing subset compiler path (`selfhost/main.mc`
# -> mcc2) as a bootstrap smoke. It is not the production MC compiler and this
# script must not be used to claim true self-hosting.
set -euo pipefail

repo_root() {
    local d
    d="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do
        d="$(dirname "$d")"
    done
    printf '%s\n' "$d"
}

HERE="$(repo_root)"
ORACLE_RAW="${1:-${MCC_ORACLE:-zig-out/bin/mcc}}"
CLANG="${CLANG:-clang}"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"

resolve_compiler() {
    case "$1" in
        */*) case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$HERE/$1" ;; esac ;;
        *) printf '%s\n' "$1" ;;
    esac
}

compiler_exists() {
    case "$1" in
        */*) [ -x "$1" ] ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}

ORACLE="$(resolve_compiler "$ORACLE_RAW")"

echo "INFO: full-selfhost-stage - P0 scaffold only; true self-hosting is NOT achieved"
echo "INFO: full-selfhost-stage - using Zig oracle seed: $ORACLE_RAW"

if ! compiler_exists "$ORACLE"; then
    echo "SKIP: full-selfhost-stage (oracle compiler not found: $ORACLE_RAW)"
    exit 0
fi
if ! command -v "$CLANG" >/dev/null 2>&1; then
    echo "SKIP: full-selfhost-stage (clang not found)"
    exit 0
fi
if [ ! -f "$SRC" ]; then
    echo "FAIL: full-selfhost-stage (subset source not found: $SRC)"
    exit 1
fi
if [ ! -f "$RT" ]; then
    echo "FAIL: full-selfhost-stage (mcc2 runtime not found: $RT)"
    exit 1
fi

WORK="$(mktemp -d)"
ROOT="$HERE/.full_selfhost_stage_root_$$.mc"
trap 'rm -rf "$WORK" "$ROOT"' EXIT INT TERM

printf 'import "selfhost/main.mc";\n' > "$ROOT"

link_mcc2() {
    local c_file="$1"
    local out_bin="$2"
    local err_file="$3"

    if ! "$CLANG" -std=gnu11 "$c_file" "$RT" -lm -o "$out_bin" 2> "$err_file"; then
        echo "FAIL: full-selfhost-stage - clang could not link $out_bin"
        sed -n '1,60p' "$err_file"
        exit 1
    fi
}

emit_subset_compiler() {
    local compiler="$1"
    local out_c="$2"
    local out_err="$3"
    local label="$4"

    set +e
    "$compiler" "$ROOT" > "$out_c" 2> "$out_err"
    local rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        echo "FAIL: full-selfhost-stage - $label exited $rc while compiling the subset compiler"
        sed -n '1,80p' "$out_err"
        exit 1
    fi
    if [ -s "$out_err" ]; then
        echo "FAIL: full-selfhost-stage - $label reported diagnostics compiling the subset compiler"
        sed -n '1,80p' "$out_err"
        exit 1
    fi
    if [ ! -s "$out_c" ]; then
        echo "FAIL: full-selfhost-stage - $label emitted empty compiler C"
        exit 1
    fi
    grep -q "mc_main" "$out_c" || {
        echo "FAIL: full-selfhost-stage - $label output lacks mc_main"
        exit 1
    }
}

echo "INFO: full-selfhost-stage - Stage0: Zig oracle builds subset mcc2 seed"
MCC_UNDER_TEST="$ORACLE" MCC="$ORACLE" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/stage0_main.o" --profile=hosted > "$WORK/stage0_build.out" 2> "$WORK/stage0_build.err" || {
    echo "FAIL: full-selfhost-stage - Stage0 seed build failed"
    sed -n '1,80p' "$WORK/stage0_build.err"
    exit 1
}
"$CLANG" "$WORK/stage0_main.o" "$RT" -lm -o "$WORK/stage0-mcc2" 2> "$WORK/stage0_link.err" || {
    echo "FAIL: full-selfhost-stage - Stage0 seed link failed"
    sed -n '1,80p' "$WORK/stage0_link.err"
    exit 1
}
echo "PASS: full-selfhost-stage - Stage0 subset seed built"

echo "INFO: full-selfhost-stage - Stage1: Stage0 subset compiler rebuilds mcc2"
emit_subset_compiler "$WORK/stage0-mcc2" "$WORK/stage1.c" "$WORK/stage1.err" "Stage0"
link_mcc2 "$WORK/stage1.c" "$WORK/stage1-mcc2" "$WORK/stage1_link.err"
echo "PASS: full-selfhost-stage - Stage1 subset compiler built"

echo "INFO: full-selfhost-stage - Stage2: Stage1 subset compiler rebuilds mcc2"
emit_subset_compiler "$WORK/stage1-mcc2" "$WORK/stage2.c" "$WORK/stage2.err" "Stage1"
link_mcc2 "$WORK/stage2.c" "$WORK/stage2-mcc2" "$WORK/stage2_link.err"
echo "PASS: full-selfhost-stage - Stage2 subset compiler built"

if ! cmp -s "$WORK/stage1.c" "$WORK/stage2.c"; then
    echo "FAIL: full-selfhost-stage - Stage1 and Stage2 subset compiler C differ"
    diff -u "$WORK/stage1.c" "$WORK/stage2.c" | sed -n '1,80p'
    exit 1
fi
echo "PASS: full-selfhost-stage - Stage1/Stage2 subset compiler C is byte-identical"

cat > "$WORK/add.mc" <<'EOF'
export fn add(a: u32, b: u32) -> u32 {
    return a + b;
}
EOF
"$WORK/stage2-mcc2" "$WORK/add.mc" > "$WORK/add.c" 2> "$WORK/add.err" || {
    echo "FAIL: full-selfhost-stage - Stage2 subset compiler failed on smoke fixture"
    sed -n '1,80p' "$WORK/add.err"
    exit 1
}
if [ -s "$WORK/add.err" ]; then
    echo "FAIL: full-selfhost-stage - Stage2 subset compiler reported diagnostics on smoke fixture"
    sed -n '1,80p' "$WORK/add.err"
    exit 1
fi
cat > "$WORK/add_driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t add(uint32_t a, uint32_t b);
int main(void) {
    return add(2, 3) == 5 ? 0 : 1;
}
EOF
"$CLANG" -std=gnu11 "$WORK/add.c" "$WORK/add_driver.c" -o "$WORK/add_prog" 2> "$WORK/add_link.err" || {
    echo "FAIL: full-selfhost-stage - clang could not link Stage2 smoke output"
    sed -n '1,80p' "$WORK/add_link.err"
    exit 1
}
if ! "$WORK/add_prog"; then
    echo "FAIL: full-selfhost-stage - Stage2 smoke program returned nonzero"
    exit 1
fi

echo "PASS: full-selfhost-stage - P0 scaffold complete: subset Stage0/Stage1/Stage2 smoke passed; true self-hosting NOT achieved"
