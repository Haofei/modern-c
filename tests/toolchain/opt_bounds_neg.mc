// Negative companion to opt_bounds.mc: a variable (non-constant) index is NOT provably
// in range, so the optimizer must keep the bounds check and the `#[no_lang_trap]` contract
// must stay rejected even under `--optimize`. Guards against the elision firing too eagerly.

#[no_lang_trap]
fn variable_index(a: [4]u32, i: usize) -> u32 {
    return a[i];
}
