// UB class: signed integer overflow.  MC handling: CHECKED + TRAP by default
// (default `i32 +` lowers to mc_checked_add_i32 -> __builtin_add_overflow ->
// mc_trap_IntegerOverflow), and the modular alternative `wrap<u32>` is STATICALLY
// FORBIDDEN on signed types (E_ARITH_DOMAIN_UNSIGNED).  This fixture stays inside the
// defined range so the guard is present but never fires (runnable on both backends,
// UBSan-clean).  The overflowing call that would trap is shown in the matrix, not here.
fn wadd(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> { return a + b; }

export fn ub_signed_overflow_run() -> u32 {
    var pass: u32 = 1;
    // Near INT32_MAX but not overflowing: checked add returns the exact sum.
    let a: i32 = 2147483646;   // INT32_MAX - 1
    let b: i32 = 1;
    if a + b != 2147483647 { pass = 0; }    // == INT32_MAX, no trap
    // Defined modular arithmetic exists for the unsigned domain via wrap<u32>:
    let r: wrap<u32> = wadd(4294967295, 1); // UINT32_MAX + 1 wraps to 0 (plain unsigned +)
    let z: wrap<u32> = 0;
    if r == z {} else { pass = 0; }
    return pass;
}
