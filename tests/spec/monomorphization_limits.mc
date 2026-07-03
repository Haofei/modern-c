// SPEC: section=22
// SPEC: milestone=monomorphization-limits
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_MONOMORPHIZATION_LIMIT

// Polymorphic recursion through a const-generic value must reject with a bounded
// diagnostic instead of growing specializations until the compiler hangs or OOMs.

fn runaway(comptime N: usize) -> usize {
    var scratch: [N]u8 = uninit;
    scratch[0] = 0;
    // EXPECT_ERROR: E_MONOMORPHIZATION_LIMIT
    return scratch[0] as usize + runaway(N + 1);
}

fn trigger_monomorphization_limit() -> usize {
    return runaway(1);
}
