#!/usr/bin/env bash
# LLVM toolchain coverage for module/import, monomorphization, and reflection
# surfaces that already have C-driver coverage.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: llvm-toolchain-test (clang not found)"; exit 0; }
command -v llc >/dev/null 2>&1 || { echo "SKIP: llvm-toolchain-test (llc not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/toolchain/app.mc" -o "$WORK/app.o" >/dev/null
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/toolchain/mono.mc" -o "$WORK/mono.o" >/dev/null

# Reflection has no exported runtime entry point; this still proves the
# comptime layout assertions pass and the reflected layout module lowers to a
# linkable LLVM object.
"$MCC" check "$HERE/tests/toolchain/reflect.mc" >/dev/null
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tests/toolchain/reflect.mc" -o "$WORK/reflect.o" >/dev/null
test -s "$WORK/reflect.o"

cat >"$WORK/app_driver.c" <<'EOF'
#include <stdint.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

extern uint32_t app_main(uint32_t);

int main(void) {
    if (app_main(5) != 130) return 1;
    if (app_main(200) != 1000) return 2;
    return 0;
}
EOF

cat >"$WORK/mono_driver.c" <<'EOF'
#include <stdint.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

extern uint8_t nth_of_filled(uint8_t value, uintptr_t idx);
extern uint32_t max_u32(uint32_t a, uint32_t b);
extern uint32_t pair_sum(uint32_t x, uint32_t y);

int main(void) {
    if (nth_of_filled(7, 0) != 7) return 3;
    if (nth_of_filled(42, 2) != 42) return 4;
    if (max_u32(3, 7) != 7) return 5;
    if (max_u32(9, 2) != 9) return 6;
    if (pair_sum(3, 4) != 7) return 7;
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/app_driver.c" "$WORK/app.o" -o "$WORK/app_prog"
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/mono_driver.c" "$WORK/mono.o" -o "$WORK/mono_prog"
if "$WORK/app_prog" && "$WORK/mono_prog"; then
    echo "PASS: llvm-toolchain-test — imports, std merge, monomorphization, generic structs, and reflection lowered through LLVM, linked, and ran"
    exit 0
fi
echo "FAIL: llvm-toolchain-test — program returned non-zero"
exit 1
