// SPEC: section=20.2
// SPEC: milestone=irq-atomic-discipline
// SPEC: phase=sema
// SPEC: expect=reject,pass
// SPEC: check=E_SLEEP_IN_ATOMIC,E_IRQ_CONTEXT_CALL

// C2 (IRQ/atomic-context discipline): a function marked `#[irq_context]` (or its
// synonym `#[atomic_context]`) runs in interrupt/atomic context. It may only call
// OTHER `#[irq_context]` functions (or the non-blocking `raw.`/`mmio.`/`atomic.`
// primitives). Calling a `#[may_sleep]` op is E_SLEEP_IN_ATOMIC ("sleeping in
// interrupt"); calling any other (non-irq, non-primitive) function is
// E_IRQ_CONTEXT_CALL — the SAME discipline the MIR verifier enforces, so `mcc check`
// and `mcc verify` agree (this previously diverged: a plain call passed check but
// failed verify).

// A sleepable op: it may block (e.g. acquire a lock or allocate). Unmarked callers
// are unconstrained; only `#[irq_context]` callers are forbidden from calling it.
#[may_sleep]
fn lock_acquire(token: u64) -> u64 {
    return token;
}

// An ordinary op safe to run with interrupts off — itself marked `#[irq_context]`
// so an irq handler may call it (an irq-context callee is the proof it is bounded
// and non-sleeping).
#[irq_context]
fn ack_irq(line: u32) -> u32 {
    return line;
}

// A plain function (NOT irq-context): an irq handler may not call it.
fn ordinary_work(line: u32) -> u32 {
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

// ACCEPTED: a clean IRQ handler that only calls another irq-context op.
#[irq_context]
fn handler_clean(line: u32) -> u32 {
    return ack_irq(line);
}

// REJECTED: an IRQ handler calling a plain (non-irq, non-primitive) function — the
// reconciled rule (matches the MIR verifier's E_IRQ_CONTEXT_CALL).
#[irq_context]
fn handler_calls_plain(line: u32) -> u32 {
    // EXPECT_ERROR: E_IRQ_CONTEXT_CALL
    return ordinary_work(line);
}

// ACCEPTED: an unmarked (sleepable-context) function may freely call the op.
fn worker(token: u64) -> u64 {
    return lock_acquire(token);
}
