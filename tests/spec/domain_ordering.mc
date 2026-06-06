// SPEC: section=5.2,5.3,5.4,5.5
// SPEC: milestone=arithmetic-domain-ordering
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_ORDERED_ARITH_DOMAIN_OPERAND,E_ARITH_DOMAIN_DIVISION

// Checked integers support ordered comparison.
fn accept_checked_ordering(a: u32, b: u32) -> bool {
    return a < b;
}

// Saturating integers explicitly allow ordering (section 5.3).
fn accept_sat_ordering(a: sat<u8>, b: sat<u8>) -> bool {
    return a >= b;
}

// Equality is allowed on every arithmetic domain.
fn accept_wrap_equality(a: wrap<u32>, b: wrap<u32>) -> bool {
    return a == b;
}

fn accept_serial_equality(a: serial<u32>, b: serial<u32>) -> bool {
    return a != b;
}

fn accept_counter_equality(a: counter<u64>, b: counter<u64>) -> bool {
    return a == b;
}

// Wrapping integers forbid ordered comparison (section 5.2).
fn reject_wrap_ordering(a: wrap<u32>, b: wrap<u32>) -> bool {
    // EXPECT_ERROR: E_ORDERED_ARITH_DOMAIN_OPERAND
    return a < b;
}

// Serial numbers forbid ordinary ordering (section 5.4).
fn reject_serial_ordering(a: serial<u32>, b: serial<u32>) -> bool {
    // EXPECT_ERROR: E_ORDERED_ARITH_DOMAIN_OPERAND
    return a > b;
}

// Free-running counters forbid ordinary ordering (section 5.5).
fn reject_counter_ordering(a: counter<u64>, b: counter<u64>) -> bool {
    // EXPECT_ERROR: E_ORDERED_ARITH_DOMAIN_OPERAND
    return a <= b;
}

// Division and remainder are not defined on arithmetic domains (section 5.2).
fn reject_wrap_division(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    // EXPECT_ERROR: E_ARITH_DOMAIN_DIVISION
    return a / b;
}

fn reject_sat_remainder(a: sat<u16>, b: sat<u16>) -> sat<u16> {
    // EXPECT_ERROR: E_ARITH_DOMAIN_DIVISION
    return a % b;
}
