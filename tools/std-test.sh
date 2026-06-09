#!/usr/bin/env bash
# Standard-library test: compile `std/core.mc` to an object with mcc-cc, link it
# against a C driver that exercises the exported functions, and run it.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: std-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for mod in core bits math ascii fmt addr; do
    MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/std/$mod.mc" -o "$WORK/$mod.o" >/dev/null
done

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdbool.h>
// core
extern uint32_t  min_u32(uint32_t, uint32_t);
extern uint32_t  max_u32(uint32_t, uint32_t);
extern uint32_t  clamp_u32(uint32_t, uint32_t, uint32_t);
extern uintptr_t min_usize(uintptr_t, uintptr_t);
extern bool      is_power_of_two(uintptr_t);
extern uintptr_t align_up(uintptr_t, uintptr_t);
extern uintptr_t align_down(uintptr_t, uintptr_t);
// bits
extern uint32_t  count_ones(uint32_t);
extern bool      is_aligned(uintptr_t, uintptr_t);
extern uint32_t  low_mask(uint32_t);
extern bool      is_single_bit(uint32_t);
extern uint32_t  next_power_of_two(uint32_t);
extern uint32_t  trailing_zeros(uint32_t);
extern bool      is_even(uint32_t);
extern bool      is_odd(uint32_t);
// math
extern uint32_t  gcd(uint32_t, uint32_t);
extern uint32_t  lcm(uint32_t, uint32_t);
extern uint32_t  pow_u32(uint32_t, uint32_t);
extern uint32_t  ilog2(uint32_t);
// ascii
extern bool      is_digit(uint8_t);
extern bool      is_alpha(uint8_t);
extern bool      is_whitespace(uint8_t);
extern uint8_t   to_upper(uint8_t);
extern uint8_t   to_lower(uint8_t);
extern uint32_t  digit_value(uint8_t);
// fmt
struct U32Decimal { uint8_t digits[10]; uintptr_t len; };
extern struct U32Decimal format_u32(uint32_t);
extern uint8_t   digit_char(uint32_t);
// addr (the opaque PAddr class lowers to uintptr_t at the C ABI)
extern uintptr_t pa(uintptr_t);
extern uintptr_t pa_value(uintptr_t);
extern uintptr_t pa_offset(uintptr_t, uintptr_t);
extern uintptr_t pa_diff(uintptr_t, uintptr_t);
extern bool      pa_is_aligned(uintptr_t, uintptr_t);
extern uintptr_t pa_align_down(uintptr_t, uintptr_t);
extern uintptr_t pa_align_up(uintptr_t, uintptr_t);
extern bool      pa_lt(uintptr_t, uintptr_t);
extern bool      pa_le(uintptr_t, uintptr_t);
extern bool      pa_eq(uintptr_t, uintptr_t);
struct PhysRange { uintptr_t start; uintptr_t end; };
extern struct PhysRange phys_range(uintptr_t, uintptr_t);
extern uintptr_t pr_len(struct PhysRange *);
extern bool      pr_contains(struct PhysRange *, uintptr_t);
// addr: VAddr ops (same uintptr_t ABI, distinct address class)
extern uintptr_t va(uintptr_t);
extern uintptr_t va_value(uintptr_t);
extern uintptr_t va_offset(uintptr_t, uintptr_t);
extern uintptr_t va_diff(uintptr_t, uintptr_t);
extern bool      va_is_aligned(uintptr_t, uintptr_t);
extern uintptr_t va_align_up(uintptr_t, uintptr_t);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)

int main(void) {
    // core
    CHECK(min_u32(3, 7) == 3);
    CHECK(max_u32(3, 7) == 7);
    CHECK(clamp_u32(10, 0, 4) == 4);
    CHECK(clamp_u32(0, 2, 9) == 2);
    CHECK(min_usize(8, 5) == 5);
    CHECK(is_power_of_two(16));
    CHECK(!is_power_of_two(17));
    CHECK(!is_power_of_two(0));
    CHECK(align_up(5, 8) == 8);
    CHECK(align_up(16, 8) == 16);
    CHECK(align_down(13, 8) == 8);
    // bits
    CHECK(count_ones(7) == 3);
    CHECK(count_ones(255) == 8);
    CHECK(is_aligned(16, 8));
    CHECK(!is_aligned(15, 8));
    CHECK(low_mask(4) == 15);
    CHECK(low_mask(8) == 255);
    CHECK(is_single_bit(8));
    CHECK(!is_single_bit(7));
    CHECK(next_power_of_two(17) == 32);
    CHECK(next_power_of_two(16) == 16);
    CHECK(trailing_zeros(8) == 3);
    CHECK(trailing_zeros(12) == 2);
    CHECK(is_even(4));
    CHECK(is_odd(7));
    // math
    CHECK(gcd(48, 36) == 12);
    CHECK(gcd(17, 5) == 1);
    CHECK(lcm(4, 6) == 12);
    CHECK(pow_u32(2, 10) == 1024);
    CHECK(pow_u32(3, 4) == 81);
    CHECK(ilog2(1024) == 10);
    CHECK(ilog2(1) == 0);
    // ascii
    CHECK(is_digit('5'));
    CHECK(!is_digit('x'));
    CHECK(is_alpha('Q'));
    CHECK(!is_alpha('9'));
    CHECK(is_whitespace(' '));
    CHECK(to_upper('a') == 'A');
    CHECK(to_upper('Z') == 'Z');
    CHECK(to_lower('A') == 'a');
    CHECK(digit_value('7') == 7);
    // fmt
    CHECK(digit_char(4) == '4');
    struct U32Decimal r = format_u32(456);
    CHECK(r.len == 3 && r.digits[0] == '4' && r.digits[1] == '5' && r.digits[2] == '6');
    struct U32Decimal z = format_u32(0);
    CHECK(z.len == 1 && z.digits[0] == '0');
    struct U32Decimal big = format_u32(1000000);
    CHECK(big.len == 7 && big.digits[0] == '1' && big.digits[6] == '0');
    // addr — checked typed physical-address arithmetic
    CHECK(pa_value(pa(0x8000)) == 0x8000);
    CHECK(pa_value(pa_offset(pa(0x1000), 0x40)) == 0x1040);
    CHECK(pa_diff(pa(0x1000), pa(0x1040)) == 0x40);
    CHECK(pa_is_aligned(pa(0x2000), 0x1000));
    CHECK(!pa_is_aligned(pa(0x2001), 0x1000));
    CHECK(pa_value(pa_align_down(pa(0x2345), 0x1000)) == 0x2000);
    CHECK(pa_value(pa_align_up(pa(0x2001), 0x1000)) == 0x3000);
    CHECK(pa_value(pa_align_up(pa(0x2000), 0x1000)) == 0x2000);
    CHECK(pa_lt(pa(1), pa(2)) && !pa_lt(pa(2), pa(2)));
    CHECK(pa_le(pa(2), pa(2)) && pa_eq(pa(5), pa(5)));
    struct PhysRange rg = phys_range(pa(0x1000), 0x2000);
    CHECK(pr_len(&rg) == 0x2000);
    CHECK(pr_contains(&rg, pa(0x1000)));    // start inclusive
    CHECK(pr_contains(&rg, pa(0x1500)));
    CHECK(!pr_contains(&rg, pa(0x3000)));   // end exclusive
    CHECK(!pr_contains(&rg, pa(0x0FFF)));
    // addr — VAddr (virtual) ops, symmetric with PAddr
    CHECK(va_value(va(0x4000)) == 0x4000);
    CHECK(va_value(va_offset(va(0x1000), 0x80)) == 0x1080);
    CHECK(va_diff(va(0x1000), va(0x1200)) == 0x200);
    CHECK(va_is_aligned(va(0x3000), 0x1000) && !va_is_aligned(va(0x3001), 0x1000));
    CHECK(va_value(va_align_up(va(0x2001), 0x1000)) == 0x3000);
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK"/core.o "$WORK"/bits.o "$WORK"/math.o "$WORK"/ascii.o "$WORK"/fmt.o "$WORK"/addr.o -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: std-test — std/{core,bits,math,ascii,fmt,addr} exported functions link and compute correctly"
    exit 0
fi
echo "FAIL: std-test — driver returned non-zero (failing CHECK line)"
exit 1
