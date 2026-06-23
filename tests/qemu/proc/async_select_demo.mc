// select / cancel-the-loser over the real broker: two in-flight requests are RACED; a timer ISR
// completes ONE of them (the winner); the race then CANCELS the loser, reclaiming its MAX_INFLIGHT
// slot. The acceptance is that the broker's active-slot count returns to ZERO — proof that a
// dropped (losing) request leaks nothing. This is the cancellation-dependent agent primitive:
// "race two tool calls, cancel the loser." (Timeout is the same shape — race the operation against
// a deadline request; whichever loses is cancelled.)
//
// Trace `W R`. Result 1 (= all checks) iff: the winner is request a (completed by the ISR), its
// result is 22, exactly ONE completion happened (the loser was cancelled, not completed), and the
// active-slot count is back to 0.

import "kernel/lib/async.mc";
import "kernel/lib/async_future.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/csr.mc";

extern fn putc_(c: u8) -> void;
extern fn mc_timer_arm_oneshot() -> void;

global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_completions: i32 = 0;

// Single-shot timer ISR: complete the first in-flight request (the race winner) and do NOT re-arm.
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

    var fa: ReqFut = req_begin(&g_broker);   // request a (id 0)
    var fb: ReqFut = req_begin(&g_broker);   // request b (id 1)  -> 2 active slots
    var race: ReqRace2 = uninit;
    req_race2_init(&race, &fa, &fb);

    putc_(87); // 'W'
    mc_timer_arm_oneshot();   // delivers ONE completion -> completes request a (first active)
    drive_irq(&race, disable_interrupts_global, enable_interrupts_global, wait_for_interrupt);
    putc_(82); // 'R'

    let w: i32 = req_race2_winner(&race);
    let res: i32 = req_race2_result(&race);
    let active: usize = async_active_count(&g_broker);

    // a won (result 22); b was CANCELLED (only one completion happened); both slots freed -> 0 active.
    if w == 0 && res == 22 && g_completions == 1 && active == 0 {
        return 1;
    }
    return 0;
}
