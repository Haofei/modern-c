// E6 — the MULTI-FUTURE cooperative executor `drive_many` end-to-end. THREE independent `async fn`s
// (each awaiting its OWN broker request through a `ReqFut` leaf) are driven CONCURRENTLY by a single
// `drive_many` call, sleeping in `wfi` between ISR-delivered completions. A single-shot M-mode timer,
// re-armed by the ISR, delivers one completion per pass — completing the in-flight requests OUT OF
// ORDER (the last-submitted request first) — so the futures resolve interleaved, not serially.
//
// This is the generalization of `drive_irq` (one future) to N: rather than three sequential
// `drive_irq` calls, ONE executor interleaves all three as their completions arrive. The
// "made-progress -> re-poll-without-idle" gate plus the IRQ-off park discipline are the lost-wakeup
// invariant lifted over N futures.
//
// Trace `W R`. Acceptance (result 1 iff ALL hold):
//   - drive_many returns 3 (every future completed normally; none hit the idle budget / was cancelled);
//   - the three results round-tripped to their futures with the OUT-OF-ORDER ISR schedule
//     (f2=>30, f1=>20, f0=>10 — proving interleaving, not in-submission-order serial draining);
//   - exactly 3 completions fired;
//   - async_active_count == 0 at teardown (ADVERSARIAL to a leaked broker slot — every slot freed).
// A lost wakeup would strand a future: drive_many would exhaust its idle budget and CANCEL it,
// dropping `completed` below 3 and failing — so this gate is adversarial to a lost wakeup too.

import "kernel/lib/async.mc";
import "kernel/lib/async_future.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/csr.mc";
import "std/task.mc";

extern fn putc_(c: u8) -> void;
#[irq_context]
extern fn mc_timer_arm_oneshot() -> void;

global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_completions: i32 = 0;

// Each async fn awaits ONE real broker request and returns its result. Three instances run
// concurrently under drive_many; their child ReqFut leaves hold distinct in-flight ids.
async fn one(b: *mut AsyncBroker) -> i32 {
    let x: i32 = await req_begin(b);
    return x;
}

// Timer ISR. Complete the request currently in flight with the HIGHEST id first (out of order vs
// submission, which created ids 0,1,2), proving the futures resolve interleaved. The completion
// value encodes which id finished (id 0 -> 10, id 1 -> 20, id 2 -> 30) so the demo can verify each
// future got ITS OWN result. Re-arm while work remains. async_complete is IRQ-safe (spec §33.7).
#[irq_context]
export fn multi_on_timer() -> void {
    // Pick the highest-id active-unready request (LIFO vs submission order) -> out-of-order schedule.
    let best: u64 = async_highest_active_unready(&g_broker);
    if best != ASYNC_NO_ID {
        // id 0 -> 10, id 1 -> 20, id 2 -> 30.
        let v: i32 = ((best as i32) + 1) * 10;
        g_completions = g_completions + 1;
        let _ok: bool = async_complete(&g_broker, &g_procs, best, v);
        mc_timer_arm_oneshot();   // re-arm for the next in-flight request
    }
}

export fn async_multi_demo(region_base: usize, region_len: usize) -> u32 {
    proc_table_init(&g_procs);
    async_init(&g_broker);

    // Three independent futures, each submitting its own broker request (ids 0, 1, 2).
    var f0: one__Fut = one(&g_broker);
    var f1: one__Fut = one(&g_broker);
    var f2: one__Fut = one(&g_broker);

    // Build the type-erased fixed set of `*mut dyn Future`. `&one__Fut` coerces to `*mut dyn
    // Future` on push (same coercion as drive_irq(&f, ...) / race2_init).
    var set: FutSet = uninit;
    futset_init(&set);
    let _i0: usize = futset_push(&set, &f0);
    let _i1: usize = futset_push(&set, &f1);
    let _i2: usize = futset_push(&set, &f2);

    putc_(87); // 'W'
    mc_timer_arm_oneshot();   // arm the first completion interrupt
    // Drive all three to completion. max_idle is generous (each completion is one wfi wake);
    // 64 consecutive no-progress idles fail closed (here we expect exactly 3 idles, one per request).
    let completed: usize = drive_many(&set, 64,
        disable_interrupts_global, enable_interrupts_global, wait_for_interrupt);
    putc_(82); // 'R'

    let r0: i32 = one__Fut_take_result(&f0);
    let r1: i32 = one__Fut_take_result(&f1);
    let r2: i32 = one__Fut_take_result(&f2);
    let active: usize = async_active_count(&g_broker);

    // ALL of: every future completed normally; each got its own id-encoded result; exactly 3
    // completions fired; no broker slot leaked.
    if completed == 3 && r0 == 10 && r1 == 20 && r2 == 30 && g_completions == 3 && active == 0 {
        return 1;
    }
    return 0;
}
