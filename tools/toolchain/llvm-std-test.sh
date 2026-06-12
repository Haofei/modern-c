#!/usr/bin/env bash
# LLVM standard-library runtime test: compile representative std modules through
# mcc-llvm-cc, link them against a C driver, and run the exported functions.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: llvm-std-test (clang not found)"; exit 0; }
command -v llc >/dev/null 2>&1 || { echo "SKIP: llvm-std-test (llc not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for mod in core bits math ascii fmt addr; do
    MCC="$MCC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/std/$mod.mc" -o "$WORK/$mod.o" >/dev/null
done

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdbool.h>

void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }

extern uint32_t  clamp_u32(uint32_t, uint32_t, uint32_t);
extern uintptr_t align_up(uintptr_t, uintptr_t);
extern uint32_t  count_ones(uint32_t);
extern bool      is_single_bit(uint32_t);
extern uint32_t  gcd(uint32_t, uint32_t);
extern uint32_t  pow_u32(uint32_t, uint32_t);
extern bool      is_digit(uint8_t);
extern uint8_t   to_upper(uint8_t);
struct U32Decimal { uint8_t digits[10]; uintptr_t len; };
extern struct U32Decimal format_u32(uint32_t);
extern uintptr_t pa(uintptr_t);
extern uintptr_t pa_value(uintptr_t);
extern uintptr_t pa_align_up(uintptr_t, uintptr_t);
struct PhysRange { uintptr_t start; uintptr_t end; };
extern struct PhysRange phys_range(uintptr_t, uintptr_t);
extern bool      pr_contains(struct PhysRange *, uintptr_t);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)

int main(void) {
    CHECK(clamp_u32(10, 0, 4) == 4);
    CHECK(align_up(13, 8) == 16);
    CHECK(count_ones(0xF0u) == 4);
    CHECK(is_single_bit(64));
    CHECK(gcd(48, 36) == 12);
    CHECK(pow_u32(3, 4) == 81);
    CHECK(is_digit('7'));
    CHECK(to_upper('m') == 'M');
    struct U32Decimal n = format_u32(4096);
    CHECK(n.len == 4 && n.digits[0] == '4' && n.digits[3] == '6');
    CHECK(pa_value(pa_align_up(pa(0x2001), 0x1000)) == 0x3000);
    struct PhysRange rg = phys_range(pa(0x1000), 0x2000);
    CHECK(pr_contains(&rg, pa(0x1800)));
    CHECK(!pr_contains(&rg, pa(0x3000)));
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK"/core.o "$WORK"/bits.o "$WORK"/math.o "$WORK"/ascii.o "$WORK"/fmt.o "$WORK"/addr.o -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: llvm-std-test — std/{core,bits,math,ascii,fmt,addr} LLVM objects linked and ran"
    exit 0
fi
echo "FAIL: llvm-std-test — driver returned non-zero (failing CHECK line)"
exit 1
