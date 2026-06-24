// select / cancel-the-loser over the real broker: two in-flight requests are RACED; a timer ISR
// completes ONE of them (the winner); the race then CANCELS the loser, reclaiming its MAX_INFLIGHT
// slot. The acceptance is that the broker's active-slot count returns to ZERO — proof that a
// dropped (losing) request leaks nothing. This is the cancellation-dependent agent primitive:
// "race two tool calls, cancel the loser." (Timeout is the same shape — race the operation against
// a deadline request; whichever loses is cancelled.)
//
// E1 makes `cancel` a `Future` trait method, so the race can run over TYPE-ERASED `*mut dyn Future`
// (std/task.mc's generic `Race2`) and still cancel its loser through the vtable. This demo exercises
// BOTH races in sequence, each driven by its own one-shot timer completion:
//   PHASE 1 — the GENERIC dyn `Race2` over two `*mut dyn Future` (ReqFut leaves coerced to *dyn).
//             Proof: a winner is decided AND active-slot count returns to 0 (loser cancelled via vtable).
//   PHASE 2 — the concrete `ReqRace2` (kept for its typed-i32-result convenience). Proof: winner a,
//             result 22, exactly one completion, active-slot count back to 0.
//
// Trace `W R`. Result 1 (= all checks) iff both phases pass.

import "kernel/lib/async.mc";
import "kernel/lib/async_future.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/csr.mc";
import "std/task.mc";

extern fn putc_(c: u8) -> void;
extern fn mc_timer_arm_oneshot() -> void;

global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_completions: i32 = 0;

// Single-shot timer ISR: complete the first in-flight request (the race winner) and do NOT re-arm.
// async_complete is IRQ-safe (spec §33.7); #[irq_context] makes the completion path compiler-verified.
#[irq_context]
export fn select_on_timer() -> void {
    let id: u64 = async_first_active_unready(&g_broker);
    if id != ASYNC_NO_ID {
        g_completions = g_completions + 1;
        let _ok: bool = async_complete(&g_broker, &g_procs, id, 22);
    }
}

export fn async_select_demo(region_base: usize, region_len: usize) -> u32 {
    proc_table_init(&g_procs);
    async_init(&g_broker);

    putc_(87); // 'W'

    // ---- PHASE 1: the GENERIC type-erased race (the E1 path) ----
    // Two in-flight requests, raced through `*mut dyn Future`. The timer ISR completes the first
    // active (request a -> winner 0); `Race2::poll` then cancels the type-erased LOSER (b) through
    // the Future vtable, freeing its slot. Acceptance: a winner is decided and active count -> 0.
    g_completions = 0;
    var ga: ReqFut = req_begin(&g_broker);   // id 0
    var gb: ReqFut = req_begin(&g_broker);   // id 1  -> 2 active slots
    var grace: Race2 = uninit;
    race2_init(&grace, &ga, &gb);            // &ReqFut coerces to *mut dyn Future
    mc_timer_arm_oneshot();
    drive_irq(&grace, disable_interrupts_global, enable_interrupts_global, wait_for_interrupt);
    let gw: i32 = race2_winner(&grace);
    let gactive: usize = async_active_count(&g_broker);
    // winner is request a (the first active the ISR completed); exactly one completion happened
    // (the loser was cancelled, not completed); both slots freed -> 0 active.
    let phase1_ok: bool = gw == 0 && g_completions == 1 && gactive == 0;

    // ---- PHASE 2: the concrete ReqRace2 (typed-i32-result convenience, retained) ----
    g_completions = 0;
    var fa: ReqFut = req_begin(&g_broker);   // request a (id 0 again — slots were freed)
    var fb: ReqFut = req_begin(&g_broker);   // request b (id 1)  -> 2 active slots
    var race: ReqRace2 = uninit;
    req_race2_init(&race, &fa, &fb);
    mc_timer_arm_oneshot();   // delivers ONE completion -> completes request a (first active)
    drive_irq(&race, disable_interrupts_global, enable_interrupts_global, wait_for_interrupt);

    let w: i32 = req_race2_winner(&race);
    let res: i32 = req_race2_result(&race);
    let active: usize = async_active_count(&g_broker);
    let phase2_ok: bool = w == 0 && res == 22 && g_completions == 1 && active == 0;

    putc_(82); // 'R'

    if phase1_ok && phase2_ok {
        return 1;
    }
    return 0;
}
