// SPEC: section=20.3
// SPEC: milestone=bounded-termination
// SPEC: phase=sema
// SPEC: expect=reject
// SPEC: check=E_UNBOUNDED_LOOP,E_UNBOUNDED_RECURSION

// REJECTED: `while true {}` with no break - the classic interrupt hang.
#[irq_context]
fn spin_forever() -> void {
    // EXPECT_ERROR: E_UNBOUNDED_LOOP
    while true {
    }
}

// REJECTED: a `while` whose counter is never advanced toward the bound.
#[bounded]
fn never_advances(limit: u32) -> u32 {
    var i: u32 = 0;
    // EXPECT_ERROR: E_UNBOUNDED_LOOP
    while i < limit {
        i = i;
    }
    return i;
}

// REJECTED: direct self-recursion from a bounded-context function.
#[irq_context]
fn recurse(n: u32) -> u32 {
    // EXPECT_ERROR: E_UNBOUNDED_RECURSION
    return recurse(n);
}

// REJECTED: a two-node direct-call cycle among bounded functions has no
// statically-proven decreasing metric.
#[bounded]
fn bounded_cycle_a(n: u32) -> u32 {
    return bounded_cycle_b(n);
}

#[bounded]
fn bounded_cycle_b(n: u32) -> u32 {
    // EXPECT_ERROR: E_UNBOUNDED_RECURSION
    return bounded_cycle_a(n);
}

// REJECTED: pure IRQ-context functions are bounded too, so an IRQ-only mutual
// cycle is rejected without weakening IRQ call discipline.
#[irq_context]
fn irq_cycle_a(n: u32) -> u32 {
    return irq_cycle_b(n);
}

#[irq_context]
fn irq_cycle_b(n: u32) -> u32 {
    return irq_cycle_c(n);
}

#[irq_context]
fn irq_cycle_c(n: u32) -> u32 {
    // EXPECT_ERROR: E_UNBOUNDED_RECURSION
    return irq_cycle_a(n);
}
