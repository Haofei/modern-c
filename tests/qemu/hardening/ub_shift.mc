// UB class: shift amount >= bit width, or negative shift count.  MC handling: CHECKED +
// TRAP — `u32 <<` lowers to mc_checked_shl_u32, which traps (mc_trap_InvalidShift) when the
// count is >= the type width and (for the checked domain) traps on value overflow too; the
// signed variant additionally traps on a negative count.  The modular `wrap<u32> <<` lowers
// to mc_wrap_shl_u32, which still traps on count >= width (so the C `a << 32` UB is never
// reached) but wraps the value instead of trapping on overflow.  This fixture shifts only by
// in-range counts; the >= width shift that would trap is shown in the matrix.
fn wshl(a: wrap<u32>, n: wrap<u32>) -> wrap<u32> { return a << n; }

export fn ub_shift_run() -> u32 {
    var pass: u32 = 1;
    let a: u32 = 1;
    if a << 31 != 0x80000000 { pass = 0; }   // count 31 < 32: in range, no trap
    if a << 0 != 1 { pass = 0; }             // count 0: identity
    // wrap<u32> shift: value wraps out, count still bounds-checked (< width).
    let r: wrap<u32> = wshl(0x80000000, 1);  // top bit shifted out -> 0, defined wrap
    let z: wrap<u32> = 0;
    if r == z {} else { pass = 0; }
    return pass;
}
