#!/usr/bin/env bash
# selfhost-bitwise-test: prove mcc2's infix BITWISE (`& | ^`) and SHIFT (`<< >>`) operators and the
# `unreachable;` diverging-terminator statement, end to end through the standalone mcc2 CLI. These
# were 2 of the 3 remaining blockers to compiling std/addr.mc through mcc2 (the parser had no infix
# bitwise/shift ops — `&` was prefix-only — and no `unreachable` statement production).
#
#   Stage BUILD:      mcc-cc.sh selfhost/main.mc -> main.o ; clang link with mcc2_rt.c -> mcc2
#   Stage FUNCTIONAL: `mcc2 selfhost_bitwise_user.mc > out.c` (a source exercising `& | ^ << >>` with
#                     C-like precedence, a PREFIX `&x` address-of alongside INFIX `&`, and a fn using
#                     `unreachable;` in a dead branch), clang-compile out.c + a driver, assert the
#                     bitwise/shift results and that the `unreachable` fn's live branch runs — the
#                     lex -> parse -> sema -> emit -> clang -> run round-trip over the new operators.
#
# A green run proves mcc2 parsed, type-checked and emitted correct-precedence C for infix
# bitwise/shift + `unreachable;` that clang (-Werror) compiled and ran.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/selfhost/main.mc"
RT="$HERE/tools/toolchain/mcc2_rt.c"
FIXTURE="$HERE/tests/toolchain/selfhost_bitwise_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: selfhost-bitwise-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----- Stage BUILD: compile selfhost/main.mc and link the mcc2 CLI -----
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/main.o" --profile=hosted >/dev/null
"$CLANG" "$WORK/main.o" "$RT" -lm -o "$WORK/mcc2"

# ----- Stage FUNCTIONAL: mcc2 bitwise.mc -> out.c -> clang -> run, assert results -----
# (mcc2 needs an ABSOLUTE path for its input on macOS — G29 relative-path/AT_FDCWD gap.)
"$WORK/mcc2" "$FIXTURE" > "$WORK/out.c"
if [ ! -s "$WORK/out.c" ]; then echo "FAIL: selfhost-bitwise-test — mcc2 emitted no C for the bitwise source"; exit 1; fi

echo "----- emitted out.c (infix bitwise/shift + unreachable) -----"
cat "$WORK/out.c"

cat >"$WORK/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

extern uint32_t band(uint32_t a, uint32_t b);
extern uint32_t shl_or(uint32_t x);
extern uint32_t shr_and(uint32_t x);
extern uint32_t tower(uint32_t a, uint32_t b);
extern uint32_t addr_and(uint32_t x);
extern uint32_t clamp_small(uint32_t x);

int main(void) {
    int fails = 0;
    /* a & (b - 1) */
    if (band(6, 4)    != 2)  { printf("FAIL: band(6,4)=%u want 2\n", band(6, 4)); fails++; }
    if (band(255, 16) != 15) { printf("FAIL: band(255,16)=%u want 15\n", band(255, 16)); fails++; }
    /* (x << 2) | 1 */
    if (shl_or(5) != 21) { printf("FAIL: shl_or(5)=%u want 21\n", shl_or(5)); fails++; }
    if (shl_or(0) != 1)  { printf("FAIL: shl_or(0)=%u want 1\n", shl_or(0)); fails++; }
    /* (x >> 2) & 3 */
    if (shr_and(255) != 3) { printf("FAIL: shr_and(255)=%u want 3\n", shr_and(255)); fails++; }
    if (shr_and(16)  != 0) { printf("FAIL: shr_and(16)=%u want 0\n", shr_and(16)); fails++; }
    /* (a & b) | (a ^ (b << 1)) */
    if (tower(6, 3)   != 2)  { printf("FAIL: tower(6,3)=%u want 2\n", tower(6, 3)); fails++; }
    if (tower(12, 10) != 24) { printf("FAIL: tower(12,10)=%u want 24\n", tower(12, 10)); fails++; }
    /* prefix &x, deref, then infix & 3 */
    if (addr_and(255) != 3) { printf("FAIL: addr_and(255)=%u want 3\n", addr_and(255)); fails++; }
    if (addr_and(8)   != 0) { printf("FAIL: addr_and(8)=%u want 0\n", addr_and(8)); fails++; }
    /* live branch (x < 100) returns x|1; the `unreachable;` terminator is never hit */
    if (clamp_small(50) != 51) { printf("FAIL: clamp_small(50)=%u want 51\n", clamp_small(50)); fails++; }
    if (clamp_small(4)  != 5)  { printf("FAIL: clamp_small(4)=%u want 5\n", clamp_small(4)); fails++; }
    if (fails != 0) { printf("FAIL: selfhost-bitwise-test — %d assertion(s) failed\n", fails); return 1; }
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/out.c" "$WORK/main.c" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: selfhost-bitwise-test — mcc2 (parser+sema+emit_c) compiled infix bitwise (& | ^) + shift (<< >>) with C precedence, a prefix &x alongside infix &, and an unreachable; dead branch -> C that clang (-Werror) ran (band/shl_or/shr_and/tower/addr_and/clamp_small all correct)"
    exit 0
fi
echo "FAIL: selfhost-bitwise-test — program returned non-zero"
exit 1
