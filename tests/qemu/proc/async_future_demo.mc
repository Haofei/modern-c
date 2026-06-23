// Broker-backed async/await end-to-end: a REAL `async fn` whose two `await`s hit the kernel
// completion broker (kernel/lib/async.mc) through the `ReqFut` Future leaf, driven to completion by
// the IRQ-backed executor `drive_irq` (kernel/lib/async_future.mc). A single-shot M-mode timer,
// re-armed by the ISR, delivers one completion per in-flight request: the task sleeps in `wfi`
// until each interrupt completes the request it is awaiting. This is the connection from the
// compiler's async lowering to the real kernel broker — not a mock leaf future.
//
// Trace `W R`: W (future constructed, about to drive), R (driven to completion). Result 42
// (= 22 + 20) proves both awaits resolved against real broker completions delivered from ISR
// context. The generated `two__Fut.poll` only polls `ReqFut`s (never blocks); `drive_irq` is the
// sole park point.

import "kernel/lib/async.mc";
import "kernel/lib/async_future.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/csr.mc";

extern fn putc_(c: u8) -> void;
extern fn mc_timer_arm_oneshot() -> void;

global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_completions: i32 = 0;

// Two real broker awaits in sequence. Lowered to a stackless state machine whose child futures are
// `ReqFut`s over live broker request ids.
async fn two(b: *mut AsyncBroker) -> i32 {
    let x: i32 = await req_begin(b);
    let y: i32 = await req_begin(b);
    return x + y;
}

// Timer ISR (invoked from the runtime trap vector). Complete whichever request is in flight with a
// deterministic result (22 then 20) and RE-ARM for the next await; when nothing is in flight, do
// not re-arm (the future is complete). async_complete is IRQ-safe (spec §33.7).
export fn future_on_timer() -> void {
    let id: u64 = async_first_active_unready(&g_broker);
    if id != ASYNC_NO_ID {
        var v: i32 = 20;
        if g_completions == 0 {
            v = 22;
        }
        g_completions = g_completions + 1;
        let _ok: bool = async_complete(&g_broker, &g_procs, id, v);
        mc_timer_arm_oneshot();   // re-arm for the next in-flight request
    }
}

export fn async_future_demo(region_base: usize, region_len: usize) -> u32 {
    proc_table_init(&g_procs);
    async_init(&g_broker);

    var f: two__Fut = two(&g_broker);   // constructs ReqFut child0 (submits request 0)
    putc_(87); // 'W'
    mc_timer_arm_oneshot();             // arm the first completion interrupt
    drive_irq(&f, disable_interrupts_global, enable_interrupts_global, wait_for_interrupt);
    putc_(82); // 'R'

    return two__Fut_take_result(&f) as u32;   // 42 iff both real broker completions reached the awaits
}
