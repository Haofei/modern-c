// Host-native logic test for the MC standard library scalar/bit/math/ascii/fmt/addr
// modules. Driver logic lives entirely in MC so that NO C-side struct mirroring is
// needed: `U32Decimal` (returned by value from `format_u32`) and `PhysRange` (whose
// layouts are MC's to define and evolve) are accessed directly here — `.len`,
// `.digits[i]`, and the typed PAddr/VAddr ops — instead of being hand-mirrored in a C
// driver. The C harness (tools/toolchain/{std,llvm-std}-test.sh) supplies only the
// `mc_trap_*` stubs and a `main()` calling `std_host_test()`.
//
// Returns 0 on success, or a small nonzero id of the first failed check so a failure
// points at the exact assertion.

import "std/core.mc";
import "std/bits.mc";
import "std/math.mc";
import "std/ascii.mc";
import "std/fmt.mc";
import "std/addr.mc";

export fn std_host_test() -> u32 {
    // ----- core -----
    if min_u32(3, 7) != 3 { return 1; }
    if max_u32(3, 7) != 7 { return 2; }
    if clamp_u32(10, 0, 4) != 4 { return 3; }
    if clamp_u32(0, 2, 9) != 2 { return 4; }
    if min_usize(8, 5) != 5 { return 5; }
    if !is_power_of_two(16) { return 6; }
    if is_power_of_two(17) { return 7; }
    if is_power_of_two(0) { return 8; }
    if align_up(5, 8) != 8 { return 9; }
    if align_up(16, 8) != 16 { return 10; }
    if align_down(13, 8) != 8 { return 11; }

    // ----- bits -----
    if count_ones(7) != 3 { return 12; }
    if count_ones(255) != 8 { return 13; }
    if !is_aligned(16, 8) { return 14; }
    if is_aligned(15, 8) { return 15; }
    if low_mask(4) != 15 { return 16; }
    if low_mask(8) != 255 { return 17; }
    if !is_single_bit(8) { return 18; }
    if is_single_bit(7) { return 19; }
    if next_power_of_two(17) != 32 { return 20; }
    if next_power_of_two(16) != 16 { return 21; }
    if trailing_zeros(8) != 3 { return 22; }
    if trailing_zeros(12) != 2 { return 23; }
    if !is_even(4) { return 24; }
    if !is_odd(7) { return 25; }

    // ----- math -----
    if gcd(48, 36) != 12 { return 26; }
    if gcd(17, 5) != 1 { return 27; }
    if lcm(4, 6) != 12 { return 28; }
    if pow_u32(2, 10) != 1024 { return 29; }
    if pow_u32(3, 4) != 81 { return 30; }
    if ilog2(1024) != 10 { return 31; }
    if ilog2(1) != 0 { return 32; }

    // ----- ascii -----
    if !is_digit('5') { return 33; }
    if is_digit('x') { return 34; }
    if !is_alpha('Q') { return 35; }
    if is_alpha('9') { return 36; }
    if !is_whitespace(' ') { return 37; }
    if to_upper('a') != 'A' { return 38; }
    if to_upper('Z') != 'Z' { return 39; }
    if to_lower('A') != 'a' { return 40; }
    if digit_value('7') != 7 { return 41; }

    // ----- fmt -----
    if digit_char(4) != '4' { return 42; }
    let r: U32Decimal = format_u32(456);
    if r.len != 3 { return 43; }
    if r.digits[0] != '4' { return 44; }
    if r.digits[1] != '5' { return 45; }
    if r.digits[2] != '6' { return 46; }
    let z: U32Decimal = format_u32(0);
    if z.len != 1 { return 47; }
    if z.digits[0] != '0' { return 48; }
    let big: U32Decimal = format_u32(1000000);
    if big.len != 7 { return 49; }
    if big.digits[0] != '1' { return 50; }
    if big.digits[6] != '0' { return 51; }

    // ----- addr: checked typed physical-address arithmetic -----
    if pa_value(pa(0x8000)) != 0x8000 { return 52; }
    if pa_value(pa_offset(pa(0x1000), 0x40)) != 0x1040 { return 53; }
    if pa_diff(pa(0x1000), pa(0x1040)) != 0x40 { return 54; }
    if !pa_is_aligned(pa(0x2000), 0x1000) { return 55; }
    if pa_is_aligned(pa(0x2001), 0x1000) { return 56; }
    if pa_value(pa_align_down(pa(0x2345), 0x1000)) != 0x2000 { return 57; }
    if pa_value(pa_align_up(pa(0x2001), 0x1000)) != 0x3000 { return 58; }
    if pa_value(pa_align_up(pa(0x2000), 0x1000)) != 0x2000 { return 59; }
    if !pa_lt(pa(1), pa(2)) { return 60; }
    if pa_lt(pa(2), pa(2)) { return 61; }
    if !pa_le(pa(2), pa(2)) { return 62; }
    if !pa_eq(pa(5), pa(5)) { return 63; }
    var rg: PhysRange = phys_range(pa(0x1000), 0x2000);
    if pr_len(&rg) != 0x2000 { return 64; }
    if !pr_contains(&rg, pa(0x1000)) { return 65; } // start inclusive
    if !pr_contains(&rg, pa(0x1500)) { return 66; }
    if pr_contains(&rg, pa(0x3000)) { return 67; }  // end exclusive
    if pr_contains(&rg, pa(0x0FFF)) { return 68; }

    // ----- addr: VAddr (virtual) ops, symmetric with PAddr -----
    if va_value(va(0x4000)) != 0x4000 { return 69; }
    if va_value(va_offset(va(0x1000), 0x80)) != 0x1080 { return 70; }
    if va_diff(va(0x1000), va(0x1200)) != 0x200 { return 71; }
    if !va_is_aligned(va(0x3000), 0x1000) { return 72; }
    if va_is_aligned(va(0x3001), 0x1000) { return 73; }
    if va_value(va_align_up(va(0x2001), 0x1000)) != 0x3000 { return 74; }

    return 0;
}
