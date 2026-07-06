// async/await roadmap: the VECTORED DRAIN `async_poll_many` (kernel/lib/async.mc) — harvest many
// completed in-flight requests per wakeup in a single pass over the inflight table, the kernel
// analogue of the broker's SYS_POLL(events, max). Single flow — drives the broker directly.
//
// Scenario: submit 4 requests; complete 3 of them OUT OF ORDER (leave one pending); drain with a
// SMALL max (2) so the drain is capped and RE-ENTERABLE; drain again (harvest the remaining ready
// one); confirm the harvested ids/results are exactly the completed ones, the drained slots are
// freed (a fresh submit reuses one), and the still-pending request is never drained (a final drain
// returns 0). Trace `S D` (submitted / drained); the runtime prints ASYNC-POLLMANY-OK iff 1.

import "kernel/lib/async.mc";
import "kernel/core/process.mc";
import "kernel/core/console.mc";

global g_procs: ProcTable;
global g_broker: AsyncBroker;

export fn async_pollmany_demo(region_base: usize, region_len: usize) -> u32 {
    proc_table_init(&g_procs);
    async_init(&g_broker);

    let a: u64 = async_submit(&g_broker);   // id 0
    let b: u64 = async_submit(&g_broker);   // id 1
    let c: u64 = async_submit(&g_broker);   // id 2  (left PENDING)
    let d: u64 = async_submit(&g_broker);   // id 3
    console_putc('S');

    // Complete 3 OUT OF ORDER; `c` stays pending.
    let r0: bool = async_complete(&g_broker, &g_procs, a, 10);
    let r1: bool = async_complete(&g_broker, &g_procs, d, 40);
    let r2: bool = async_complete(&g_broker, &g_procs, b, 20);

    // Drain capped at 2 -> harvests exactly 2 ready slots, frees them.
    var ev1: AsyncEvents = async_events_empty();
    let n1: usize = async_poll_many(&g_broker, &ev1, 2);

    // Drain again with a generous max -> harvests the remaining 1 ready slot.
    var ev2: AsyncEvents = async_events_empty();
    let n2: usize = async_poll_many(&g_broker, &ev2, 8);
    console_putc('D');

    // Sum results across both drains (order-independent): must be 10 + 40 + 20 = 70.
    var sum: i32 = 0;
    var i: usize = 0;
    while i < n1 { sum = sum + ev1.ev[i].result; i = i + 1; }
    var j: usize = 0;
    while j < n2 { sum = sum + ev2.ev[j].result; j = j + 1; }

    // The 3 drained slots are freed: a fresh submit succeeds (reuses one).
    let reuse: u64 = async_submit(&g_broker);

    // A final drain harvests nothing: `c` is still pending and `reuse` is not ready.
    var ev3: AsyncEvents = async_events_empty();
    let n3: usize = async_poll_many(&g_broker, &ev3, 8);

    if r0 && r1 && r2 && n1 == 2 && n2 == 1 && sum == 70 && reuse != ASYNC_NO_ID && n3 == 0 {
        return 1;
    }
    return 0;
}
