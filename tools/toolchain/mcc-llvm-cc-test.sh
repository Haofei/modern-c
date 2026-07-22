#!/usr/bin/env bash
# Toolchain test: compile an MC module to an object through the LLVM driver and
# verify the exported symbol is present and linkable.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/lib.mc"
SYM="mc_add3"

CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: mcc-llvm-cc-test (clang not found)"; exit 0; }
command -v llc >/dev/null 2>&1 || { echo "SKIP: mcc-llvm-cc-test (llc not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$SRC" -o "$WORK/lib.o" >/dev/null

if command -v nm >/dev/null 2>&1; then
    if ! nm "$WORK/lib.o" | grep -qE "T $SYM\$|T _$SYM\$"; then
        echo "FAIL: mcc-llvm-cc-test — symbol '$SYM' not defined in object:"
        nm "$WORK/lib.o"
        exit 1
    fi
fi

cat >"$WORK/main.c" <<EOF
#include <stdint.h>
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
extern uint32_t $SYM(uint32_t, uint32_t, uint32_t);
int main(void) { return $SYM(1, 2, 3) == 6 ? 0 : 1; }
EOF
"$CLANG" -std=c11 "$WORK/main.c" "$WORK/lib.o" -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: mcc-llvm-cc-test — MC module compiled through LLVM, linked, and ran ($SYM(1,2,3)==6)"
    exit 0
fi
echo "FAIL: mcc-llvm-cc-test — linked program returned non-zero"
exit 1
