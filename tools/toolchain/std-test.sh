#!/usr/bin/env bash
# Standard-library test: compile the MC driver (tests/std/std_host_driver.mc, which
# imports std/{core,bits,math,ascii,fmt,addr}) to a single object with mcc-cc, link it
# against a tiny C harness, and run it.
#
# The whole check battery lives in MC, so there is NO C-side mirroring of any MC struct:
# `U32Decimal` (returned by value from `format_u32`) and `PhysRange` — whose layouts are
# MC's to define and evolve — are accessed directly in the MC driver (`.len`,
# `.digits[i]`, the typed PAddr/VAddr ops). The C harness only sees
# `std_host_test() -> u32` and supplies the trap stubs + `main()`.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: std-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DRIVER="$HERE/tests/std/std_host_driver.mc"
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$DRIVER" -o "$WORK/std.o" >/dev/null

cat >"$WORK/harness.c" <<'EOF'
#include <stdint.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

extern uint32_t std_host_test(void);

int main(void) {
    return (int)std_host_test(); /* 0 = all checks passed; nonzero = first failed check id */
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/harness.c" "$WORK/std.o" -o "$WORK/app"
set +e
"$WORK/app"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "PASS: std-test — std/{core,bits,math,ascii,fmt,addr} exported functions link and compute correctly"
    exit 0
fi
echo "FAIL: std-test — driver returned non-zero (failed check id, rc=$rc)"
exit 1
