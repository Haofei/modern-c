// async/await roadmap Phase D step 6 (runtime half): the broker-side CANCELLATION primitive
// kernel/lib/async.mc `async_cancel`, which a dropped still-pending future walks down to so its
// MAX_INFLIGHT slot is RECLAIMED instead of leaked. Single flow — no parking needed: this drives
// the broker directly to prove the slot bookkeeping.
//
// Scenario: fill the whole MAX_INFLIGHT quota (the next submit must fail), cancel one in-flight
// request, then prove (a) a fresh submit now SUCCEEDS — the slot was reclaimed; (b) a completion
// arriving late for the canceled id is a harmless no-op (its op was abandoned); (c) a second
// cancel of the same id is idempotent. Trace `F X R` (filled / canceled / reused). The runtime
// prints ASYNC-CANCEL-OK iff the return is 1.

import "kernel/lib/async.mc";
import "kernel/core/process.mc";
import "kernel/core/console.mc";

global g_procs: ProcTable;
global g_broker: AsyncBroker;

export fn async_cancel_demo(region_base: usize, region_len: usize) -> u32 {
    proc_table_init(&g_procs);
    async_init(&g_broker);

    // Fill the quota: MAX_INFLIGHT (8) successful submits, ids 0..7.
    var i: usize = 0;
    var filled: u32 = 0;
    while i < 8 {
        let id: u64 = async_submit(&g_broker);
        if id != ASYNC_NO_ID { filled = filled + 1; }
        i = i + 1;
    }
    console_putc('F');
    let over: u64 = async_submit(&g_broker);          // quota full -> ASYNC_NO_ID

    // Cancel an in-flight request (id 3): frees its slot and drops the pending op.
    let c_ok: bool = async_cancel(&g_broker, &g_procs, 3);
    console_putc('X');

    // A completion arriving late for the canceled id finds nothing -> no-op (returns false).
    let late: bool = async_complete(&g_broker, &g_procs, 3, 99);

    // A fresh submit now succeeds, REUSING the reclaimed slot (would fail if cancel leaked it).
    let reuse: u64 = async_submit(&g_broker);
    if reuse != ASYNC_NO_ID { console_putc('R'); }

    // A second cancel of id 3 is idempotent (already gone -> false).
    let c_again: bool = async_cancel(&g_broker, &g_procs, 3);

    if filled == 8 && over == ASYNC_NO_ID && c_ok && !late && reuse != ASYNC_NO_ID && !c_again {
        return 1;
    }
    return 0;
}
