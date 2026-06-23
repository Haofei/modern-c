// The capstone: an AGENT written in real `async fn`/`await`, resolving against the real kernel
// completion broker — async-fn-awaiting-async-fn all the way down to broker request leaves, driven
// by `drive_irq` while the task sleeps in `wfi`, plus a timeout that cancels a slow tool call.
//
//   async fn agent(b) {
//       let page = await tool_fetch(b);   // each tool call is itself an async fn awaiting a broker request
//       let cfg  = await tool_read(b);
//       return page + cfg;
//   }
//
// Phase 1 (sequential tool calls): a re-armed timer ISR delivers one real completion per request;
// agent() resolves to 22 + 20 = 42. Phase 2 (timeout): race a slow tool call against a deadline
// request; the deadline fires first, so the slow tool is CANCELLED and the inflight count returns
// to 0. Trace `F R T`. Result 1 iff both phases pass.

import "kernel/lib/async.mc";
import "kernel/lib/async_future.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/csr.mc";

extern fn putc_(c: u8) -> void;
extern fn mc_timer_arm_oneshot() -> void;

global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_completions: i32 = 0;

// A tool call is an async fn that awaits a broker request. Two distinct tools so `agent` composes
// async-fn-awaiting-async-fn (each yields the broker's completion value).
async fn tool_fetch(b: *mut AsyncBroker) -> i32 {
    let r: i32 = await req_begin(b);
    return r;
}
async fn tool_read(b: *mut AsyncBroker) -> i32 {
    let r: i32 = await req_begin(b);
    return r;
}

// The agent: two sequential tool calls over the real broker.
async fn agent(b: *mut AsyncBroker) -> i32 {
    let page: i32 = await tool_fetch(b);
    let cfg: i32 = await tool_read(b);
    return page + cfg;
}

// Re-armed timer ISR: complete the in-flight request (22, then 20, then 7 for later phases) and
// re-arm while anything is in flight. async_complete is IRQ-safe (spec §33.7).
export fn agent_on_timer() -> void {
    let id: u64 = async_first_active_unready(&g_broker);
    if id != ASYNC_NO_ID {
        var v: i32 = 7;
        if g_completions == 0 {
            v = 22;
        }
        if g_completions == 1 {
            v = 20;
        }
        g_completions = g_completions + 1;
        let _ok: bool = async_complete(&g_broker, &g_procs, id, v);
        mc_timer_arm_oneshot();
    }
}

export fn async_agent_demo(region_base: usize, region_len: usize) -> u32 {
    proc_table_init(&g_procs);
    async_init(&g_broker);
    mc_timer_arm_oneshot();

    // ---- Phase 1: the agent's two sequential tool calls resolve over the real broker. ----
    var af: agent__Fut = agent(&g_broker);
    putc_(70); // 'F'
    drive_irq(&af, disable_interrupts_global, enable_interrupts_global, wait_for_interrupt);
    putc_(82); // 'R'
    let result: i32 = agent__Fut_take_result(&af);

    // ---- Phase 2: timeout — race a slow tool call against a deadline; the deadline wins, so the
    // slow tool is cancelled and its slot reclaimed. Submit the deadline FIRST so the ISR (which
    // completes the lowest active id) fires it first. ----
    let before: usize = async_active_count(&g_broker);   // expect 0 after phase 1
    var fdeadline: ReqFut = req_begin(&g_broker);         // the deadline request (completed first)
    var fslow: ReqFut = req_begin(&g_broker);             // the slow tool call (never completes here)
    var race: ReqRace2 = uninit;
    req_race2_init(&race, &fslow, &fdeadline);            // a = slow tool, b = deadline
    mc_timer_arm_oneshot();
    drive_irq(&race, disable_interrupts_global, enable_interrupts_global, wait_for_interrupt);
    putc_(84); // 'T'
    let timed_out: bool = req_race2_winner(&race) == 1;   // the deadline (b) won
    let after: usize = async_active_count(&g_broker);     // both slots freed -> 0

    if result == 42 && before == 0 && timed_out && after == 0 {
        return 1;
    }
    return 0;
}
