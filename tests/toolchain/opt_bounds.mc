// Fact-gated MIR optimizer fixture (annex E): const-index bounds-check elision and
// divide-by-constant check elision. Every function below performs an operation whose
// language trap provably never fires — a non-negative integer-literal index strictly
// less than the array length, or a division/modulo by a non-zero (and, for a signed
// dividend, non-`-1`) literal divisor. Under `--optimize` the MIR drops the trap edge
// and the `#[no_lang_trap]` contract is satisfied; without it the check (and trap edge)
// is kept and the contract is rejected.

#[no_lang_trap]
fn first(a: [4]u32) -> u32 {
    return a[0];
}

#[no_lang_trap]
fn last(a: [4]u32) -> u32 {
    return a[3];
}

#[no_lang_trap]
fn local_const_index() -> u32 {
    let xs: [3]u32 = .{10, 20, 30};
    return xs[2];
}

// Unsigned division by a non-zero literal: no DivideByZero, no overflow case.
#[no_lang_trap]
fn unsigned_div_const(x: u32) -> u32 {
    return x / 10;
}

// Signed division by a non-zero, non-`-1` literal: no DivideByZero and no INT_MIN/-1
// overflow either, so both checks are dead.
#[no_lang_trap]
fn signed_div_const(x: i32) -> i32 {
    return x / 2;
}

#[no_lang_trap]
fn signed_mod_const(x: i32) -> i32 {
    return x % 7;
}
