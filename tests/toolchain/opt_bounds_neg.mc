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

// An out-of-range constant index into a struct-field array is NOT in bounds, so the member-base
// elision must not fire — the Bounds check (and rejection) must remain.
struct OobFrame {
    slots: [4]u32,
}

#[no_lang_trap]
fn member_oob(f: OobFrame) -> u32 {
    return f.slots[9];
}

// An out-of-range constant slice (`end = 9 > len = 8`) is NOT in bounds, so the const-slice
// elision must not fire — the Bounds check (and rejection) must remain.
global gbuf: [8]u32;

#[no_lang_trap]
fn slice_oob() -> []mut u32 {
    return gbuf[1..9];
}

// A variable slice bound could be out of range — the construction Bounds check must stay.
#[no_lang_trap]
fn slice_var(i: usize) -> []mut u32 {
    return gbuf[1..i];
}
