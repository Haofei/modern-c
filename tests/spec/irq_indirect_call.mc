// SPEC: section=19.1,D.6
// SPEC: milestone=irq-context-indirect
// SPEC: phase=sema,verifier
// SPEC: expect=pass,reject
// SPEC: check=E_IRQ_CONTEXT_CALL

// C2 reconciliation: an #[irq_context] function calling through a function
// pointer may reach anything — including a #[may_sleep] op — so it is rejected.
// Previously `mcc check` accepted the indirect call while `mcc verify` rejected
// it (a check/verify contradiction reopened after only DIRECT calls were
// reconciled). Now `check` rejects the fn-pointer call too, so the passes agree.

#[irq_context]
extern fn irq_poll() -> void;

fn do_sleep() -> void {}

// ---- allowed: direct call to another irq-context function --------------------

#[irq_context]
fn allow_irq_to_irq() -> void {
    irq_poll();
}

// ---- rejected: indirect call through a local fn pointer ----------------------

#[irq_context]
fn reject_local_fnptr_call() -> void {
    let p: fn() -> void = do_sleep;
    p(); // EXPECT_ERROR: E_IRQ_CONTEXT_CALL
}

// ---- rejected: indirect call through a fn-pointer parameter ------------------

#[irq_context]
fn reject_param_fnptr_call(cb: fn() -> void) -> void {
    cb(); // EXPECT_ERROR: E_IRQ_CONTEXT_CALL
}
