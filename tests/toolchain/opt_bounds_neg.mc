// Negative companion to opt_bounds.mc: operations the optimizer must NOT prove safe, so the
// check (and the `#[no_lang_trap]` rejection) must remain even under `--optimize`. Guards
// against the elision firing too eagerly.

// A variable (non-constant) index is not provably in range.
#[no_lang_trap]
fn variable_index(a: [4]u32, i: usize) -> u32 {
    return a[i];
}

// A variable divisor could be zero — the DivideByZero check must stay.
#[no_lang_trap]
fn variable_divisor(x: u32, d: u32) -> u32 {
    return x / d;
}

// Signed division by the literal `-1` is exactly the INT_MIN/-1 overflow case, so the
// IntegerOverflow check must stay even though the divisor is a literal.
#[no_lang_trap]
fn signed_div_neg_one(x: i32) -> i32 {
    return x / -1;
}
