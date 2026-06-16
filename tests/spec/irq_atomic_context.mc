// SPEC: section=20.2
// SPEC: milestone=irq-atomic-discipline
// SPEC: phase=sema
// SPEC: expect=reject,pass
// SPEC: check=E_SLEEP_IN_ATOMIC

// C2 (IRQ/atomic-context discipline): a function marked `#[irq_context]` (or its
// synonym `#[atomic_context]`) runs in interrupt/atomic context and may not call a
// `#[may_sleep]` op — heap allocation, mutex/lock acquire, scheduler yield. Doing
// so is "scheduling while atomic" / "sleeping in interrupt" and is a compile error.

// A sleepable op: it may block (e.g. acquire a lock or allocate). Unmarked callers
// are unconstrained; only `#[irq_context]` callers are forbidden from calling it.
#[may_sleep]
fn lock_acquire(token: u64) -> u64 {
    return token;
}

// An ordinary op safe to run with interrupts off.
fn ack_irq(line: u32) -> u32 {
    return line;
}

// REJECTED: an IRQ-context handler calling a sleepable op.
#[irq_context]
fn handler_sleeps(token: u64) -> u64 {
    // EXPECT_ERROR: E_SLEEP_IN_ATOMIC
    return lock_acquire(token);
}

// `#[atomic_context]` is a synonym for `#[irq_context]`; same rule applies.
#[atomic_context]
fn atomic_sleeps(token: u64) -> u64 {
    // EXPECT_ERROR: E_SLEEP_IN_ATOMIC
    return lock_acquire(token);
}

// ACCEPTED: a clean IRQ handler that only calls non-sleeping ops.
#[irq_context]
fn handler_clean(line: u32) -> u32 {
    return ack_irq(line);
}

// ACCEPTED: an unmarked (sleepable-context) function may freely call the op.
fn worker(token: u64) -> u64 {
    return lock_acquire(token);
}
