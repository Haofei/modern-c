import "kernel/lib/waitqueue.mc";
import "kernel/core/process.mc";
global g_t: ProcTable;
global g_wq: WaitQueue;
export fn waitqueue_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t); // only the bootstrap (slot 0) exists -> yield has no other target
    wq_init(&g_wq);

    // empty queue: wake_one is a no-op returning false
    if wq_wake_one(&g_wq, &g_t) { pass = 0; }
    if wq_len(&g_wq) != 0 { pass = 0; }

    // the current process blocks on the queue: enqueued + parked (BlockedRecv); with nothing
    // else runnable, the yield is the graceful idle path (returns, no resurrection)
    wq_wait(&g_wq, &g_t);
    if wq_len(&g_wq) != 1 { pass = 0; }
    if proc_state_code(&g_t, 0) != 3 { pass = 0; } // blocked (derived from block reasons)

    // waking the waiter dequeues it and makes it runnable again
    if !wq_wake_one(&g_wq, &g_t) { pass = 0; }
    if wq_len(&g_wq) != 0 { pass = 0; }
    if proc_state_code(&g_t, 0) != 2 { pass = 0; } // unblocked; it is the current (Running) process

    // wake_all path: block again, broadcast wakes it
    wq_wait(&g_wq, &g_t);
    if wq_len(&g_wq) != 1 { pass = 0; }
    wq_wake_all(&g_wq, &g_t);
    if wq_len(&g_wq) != 0 { pass = 0; }
    if proc_state_code(&g_t, 0) != 2 { pass = 0; } // unblocked again (Running, the current process)

    // stale-endpoint skip: a waiter whose slot generation changed (reused) is NOT woken
    let tbl: *mut ProcTable = &g_t;
    wq_wait(&g_wq, &g_t);                          // enqueue the bootstrap's endpoint + block
    if proc_state_code(&g_t, 0) != 3 { pass = 0; } // blocked
    tbl.procs[0].gen = tbl.procs[0].gen + 1;       // simulate the waiter's slot being reused
    if wq_wake_one(&g_wq, &g_t) { pass = 0; }      // stale endpoint -> skipped, nothing woken
    if wq_len(&g_wq) != 0 { pass = 0; }            // the stale entry was drained
    if proc_state_code(&g_t, 0) != 3 { pass = 0; } // still blocked (the stale wake was ignored)
    proc_unblock(&g_t, 0, BLOCK_RECV);             // (clean up)
    return pass;
}
