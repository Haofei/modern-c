// SPEC: section=22
// SPEC: milestone=comptime-parameters
// SPEC: phase=parse,sema,lower-c
// SPEC: expect=pass,compile_error
// SPEC: check=E_COMPTIME_ARG_REQUIRED,E_COMPTIME_TRAP

// Comptime parameters (section 22): a `comptime NAME: T` parameter requires a
// compile-time constant argument, and the callee's comptime assertions are
// re-checked with the parameter bound to that argument — failures surface at
// the call site.

const fn is_power_of_two(x: usize) -> bool {
    return x != 0 && (x & (x - 1)) == 0;
}

fn make_ring(comptime CAP: usize) -> usize {
    comptime {
        assert(is_power_of_two(CAP));
    }
    return CAP;
}

fn double(comptime N: usize) -> usize {
    return N + N;
}

fn accept_power_of_two_capacity() -> usize {
    return make_ring(16);
}

fn accept_plain_comptime_param() -> usize {
    return double(21);
}

fn reject_non_power_of_two_capacity() -> usize {
    // EXPECT_ERROR: E_COMPTIME_TRAP
    return make_ring(17);
}

fn reject_runtime_comptime_argument(n: usize) -> usize {
    // EXPECT_ERROR: E_COMPTIME_ARG_REQUIRED
    return make_ring(n);
}
