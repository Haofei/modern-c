#!/usr/bin/env bash
# Monomorphization runtime test: compile a module with a type-generic
# (comptime-parameter-driven) function to an object, link it against a C driver,
# and verify the specialized function computes correctly at runtime.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/tests/toolchain/mono.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: mono-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$SRC" -o "$WORK/mono.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint8_t nth_of_filled(uint8_t value, uintptr_t idx);
extern uint32_t max_u32(uint32_t a, uint32_t b);
extern uint32_t pair_sum(uint32_t x, uint32_t y);
// fill(4, value) yields a [4]u8 all == value; nth picks element idx.
// max_u32 wraps a generic function; pair_sum a generic struct Pair<T>.
int main(void) {
    if (nth_of_filled(7, 0) != 7) return 1;
    if (nth_of_filled(7, 3) != 7) return 2;
    if (nth_of_filled(42, 2) != 42) return 3;
    if (max_u32(3, 7) != 7) return 4;
    if (max_u32(9, 2) != 9) return 5;
    if (pair_sum(3, 4) != 7) return 6;
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/mono.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: mono-test — comptime-param-specialized function linked and computed correctly"
    exit 0
fi
echo "FAIL: mono-test — program returned non-zero"
exit 1
