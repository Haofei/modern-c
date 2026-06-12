#!/usr/bin/env bash
# Run data-driven host tests with each fixture compiled through the LLVM backend,
# then linked against the existing C host driver.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
shift || true

HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
MANIFEST="$HERE/tools/lib/host-tests.tsv"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"
LINK_FLAGS=()

command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: llvm-host-suite-test (clang not found)"; exit 0; }
command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: llvm-host-suite-test (llc not found)"; exit 0; }
if [ "$(uname -s)" = "Linux" ]; then
    LINK_FLAGS=(-no-pie)
fi

if [ "$#" -gt 0 ]; then
    TESTS=("$@")
else
    TESTS=()
    while IFS=$'\t' read -r name _; do
        case "$name" in
            ""|\#*) continue ;;
        esac
        TESTS+=("$name")
    done <"$MANIFEST"
fi

trap_stubs() {
    cat >"$1" <<'C'
void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }
C
}

field() {
    awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c; exit}' "$MANIFEST"
}

for name in "${TESTS[@]}"; do
    if ! awk -F'\t' -v n="$name" '$1==n{hit=1} END{exit hit?0:3}' "$MANIFEST"; then
        echo "FAIL: llvm-host-suite-test - no row for '$name' in tools/lib/host-tests.tsv"
        exit 1
    fi

    fixture="$(field "$name" 2)"
    mode="$(field "$name" 3)"
    spec="$(field "$name" 4)"
    desc="$(field "$name" 6)"

    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT

    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/$fixture" -o "$WORK/mod.o" >/dev/null

    case "$mode" in
        entry)
            printf '#include <stdint.h>\nextern uint32_t %s(void);\nint main(void){ return %s()==1 ? 0 : 1; }\n' \
                "$spec" "$spec" >"$WORK/driver.c" ;;
        driver)
            cp "$HERE/tools/lib/host-drivers/$name.c" "$WORK/driver.c" ;;
        *)
            echo "FAIL: llvm-host-suite-test - $name has unknown manifest mode '$mode'"
            exit 1 ;;
    esac

    trap_stubs "$WORK/trap_stubs.c"
    "$CLANG" -std=c11 -Wall -Wextra "${LINK_FLAGS[@]}" "$WORK/driver.c" "$WORK/trap_stubs.c" "$WORK/mod.o" -o "$WORK/app"
    if OUT="$("$WORK/app")"; then
        [ -n "$OUT" ] && printf '%s\n' "$OUT"
        echo "PASS: llvm-host-suite-test - $name - $desc"
    else
        echo "FAIL: llvm-host-suite-test - $name driver returned nonzero"
        exit 1
    fi

    rm -rf "$WORK"
    trap - EXIT
done
