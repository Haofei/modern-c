// SPEC: section=5.2,5.4,5.5,D.1
// SPEC: milestone=mir-ordered-domain-operand
// SPEC: phase=verifier
// SPEC: expect=pass,compile_error
// SPEC: check=E_ORDERED_ARITH_DOMAIN_OPERAND

// Ordered comparison is allowed on sat and checked integers.
fn ok_sat(a: sat<u8>, b: sat<u8>) -> bool {
    return a >= b;
}

fn ok_checked(a: u32, b: u32) -> bool {
    return a < b;
}

// The MIR core verifier (D.1) rejects ordered comparison on wrap/serial/counter,
// mirroring the sema check (sections 5.2, 5.4, 5.5).
fn reject_wrap(a: wrap<u32>, b: wrap<u32>) -> bool {
    // EXPECT_ERROR: E_ORDERED_ARITH_DOMAIN_OPERAND
    return a < b;
}

fn reject_serial(a: serial<u32>, b: serial<u32>) -> bool {
    // EXPECT_ERROR: E_ORDERED_ARITH_DOMAIN_OPERAND
    return a > b;
}

fn reject_counter(a: counter<u64>, b: counter<u64>) -> bool {
    // EXPECT_ERROR: E_ORDERED_ARITH_DOMAIN_OPERAND
    return a <= b;
}
