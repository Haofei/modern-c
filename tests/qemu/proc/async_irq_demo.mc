// async/await roadmap Phase C: IRQ-BACKED completion. A real M-mode TIMER interrupt — not a
// cooperative task — completes an in-flight async request and wakes the parked waiter. This is
// the production-readiness shape: a task awaits, sleeps in `wfi`, and a device/timer interrupt
// resumes it; no steady-state polling.
//
// The waiter submits a request, arms a single timer interrupt, and `async_await_irq` PARKS it
// (enqueue+park under an interrupts-off critical section, then `wfi`). When the timer fires, the
// runtime trap vector calls `async_on_timer` HERE, in interrupt context, which `async_complete`s
// the request and wakes the waiter. The irq-off wait-prepare closes the lost-wake window: even
// if the interrupt fires before the waiter parks, `async_await_irq` sees the slot already ready.
//
// Console trace `W I R`: W (waiter about to await), I (completion ran in INTERRUPT context),
// R (waiter resumed). Result 42 (the value the ISR delivered) proves it round-tripped.

import "kernel/lib/async.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/arch/riscv64/csr.mc";

// UART putc from the shared M-mode bring-up runtime (context_runtime.c).
extern fn putc_(c: u8) -> void;
// Arm a single (one-shot) machine-timer interrupt; defined in async_irq_runtime.mc.
extern fn mc_timer_arm_oneshot() -> void;

global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_pending_id: u64;

// Called from the timer ISR (runtime trap_entry) in INTERRUPT context. Completes the pending
// request and wakes the parked waiter. The completion path (`async_complete`) is now
// `#[irq_context]`-VERIFIED: the whole wake chain (find_slot / wq_wake_one -> ring_pop,
// endpoint_slot_or, proc_unblock -> mask32_clear) is annotated and MIR-checked irq-safe (the
// wake uses the sentinel `endpoint_slot_or`, not the `Result`-returning `endpoint_slot`, since
// `Result` construction is not irq-safe). This demo entry itself stays unannotated only because
// its `putc_('I')` trace is an opaque extern the verifier can't prove (it is a bare MMIO write).
export fn async_on_timer() -> void {
    putc_(73); // 'I' — completion delivered from interrupt context
    let _ok: bool = async_complete(&g_broker, &g_procs, g_pending_id, 42);
}

export fn async_irq_demo(region_base: usize, region_len: usize) -> u32 {
    proc_table_init(&g_procs);   // slot 0 is the running bootstrap = this task
    install_idle(&g_procs);      // wfi when nothing runnable
    async_init(&g_broker);

    g_pending_id = async_submit(&g_broker);
    putc_(87); // 'W'
    mc_timer_arm_oneshot();      // one timer interrupt will complete g_pending_id

    // PARK until the timer interrupt completes the request. Interrupts stay off across the
    // park and the wfi (wait_for_interrupt resumes on the pending timer even with the global
    // enable cleared), so the completion can be neither lost nor idled-through.
    let r: i32 = async_await_irq(&g_broker, &g_procs, g_pending_id,
                                 disable_interrupts_global, enable_interrupts_global,
                                 wait_for_interrupt);
    putc_(82); // 'R'
    return r as u32; // 42 iff the interrupt-delivered completion reached the parked waiter
}
