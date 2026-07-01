// Fact-gated MIR optimizer fixture (annex E) — range-fact check elision. Each POSITIVE function
// performs a runtime (non-constant) index or division whose language trap is proven dead by an
// `if`/`while` guard or the loop condition, so under `--optimize` the MIR drops the trap edge.
// Each NEGATIVE function performs one the analysis must NOT prove safe (a too-weak bound, a
// signed divisor that could be `-1`, an address-taken/re-assigned index), so the check — and its
// trap edge — must remain even under `--optimize`. The companion `opt-test.sh` asserts this per
// function against `lower-mir`; `opt-equiv-test.sh` pins the runtime behavior on both backends.

// --- POSITIVES: the guard proves the operation safe, so the check is elided under --optimize. ---

// `if (i < 4)` proves the index in range for a `[4]` array.
fn guarded_index(a: [4]u32, i: usize) -> u32 {
    if (i < 4) { return a[i]; }
    return 0;
}

// The `while (i < 4)` condition holds at the top of every iteration.
fn while_index(a: [4]u32) -> u32 {
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < 4) {
        acc = a[i];
        i = i + 1;
    }
    return acc;
}

// Unsigned divisor proven non-zero: the only checked trap (DivideByZero) is dead.
fn guarded_div(x: u32, d: u32) -> u32 {
    if (d != 0) { return x / d; }
    return 0;
}

// Signed divisor proven POSITIVE: both DivideByZero and the INT_MIN/-1 overflow are dead.
fn guarded_signed_div(x: i32, d: i32) -> i32 {
    if (d > 0) { return x / d; }
    return 0;
}

// --- NEGATIVES: the analysis cannot prove safety, so the check must remain under --optimize. ---

// The guard `i < 8` does not bound the index below the array length 4, so `i` could be 4..7.
fn wrong_bound(a: [4]u32, i: usize) -> u32 {
    if (i < 8) { return a[i]; }
    return 0;
}

// A signed divisor proven only non-zero could still be `-1` (INT_MIN/-1 overflow), so the
// overflow check must stay.
fn signed_div_ne(x: i32, d: i32) -> i32 {
    if (d != 0) { return x / d; }
    return 0;
}

fn set_seven(p: *mut usize) {
    *p = 7;
}

// `i` is address-taken: an opaque call could mutate it through the pointer after the guard, so
// no fact may be formed about it — the bounds check must stay.
fn aliased_index(a: [4]u32) -> u32 {
    var i: usize = 0;
    let p: *mut usize = &i;
    if (i < 4) {
        set_seven(p);
        return a[i];
    }
    return 0;
}

// `i` is re-assigned after the guard, invalidating the fact — the bounds check must stay.
fn mutated_index(a: [4]u32) -> u32 {
    var i: usize = 0;
    if (i < 4) {
        i = 9;
        return a[i];
    }
    return 0;
}
