// Fact-gated MIR optimizer fixture (annex E): const-index bounds-check elision.
// Every function below indexes a fixed array at a non-negative integer-literal position
// strictly less than the array length, so the bounds check provably never traps. Under
// `--optimize` the MIR drops the `Bounds` trap edge and the `#[no_lang_trap]` contract is
// satisfied; without it the check (and trap edge) is kept and the contract is rejected.

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
