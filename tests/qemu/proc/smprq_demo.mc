import "kernel/core/smprq.mc";
global g_rq: RunQueues;
export fn smprq_run() -> u32 {
    var pass: u32 = 1;
    rq_init(&g_rq);
    // core 0 gets 3 tasks; core 1 idle
    if !rq_push(&g_rq, 0, 100) { pass = 0; }
    if !rq_push(&g_rq, 0, 101) { pass = 0; }
    if !rq_push(&g_rq, 0, 102) { pass = 0; }
    if rq_count(&g_rq, 0) != 3 { pass = 0; }

    switch rq_pop(&g_rq, 1) {                         // core 1 empty -> Empty
        ok(v) => { pass = 0; }
        err(e) => {}
    }
    switch rq_steal(&g_rq, 1) {                       // core 1 steals from core 0
        ok(v) => { if v != 100 { pass = 0; } }       // takes core 0's head (FIFO)
        err(e) => { pass = 0; }
    }
    if rq_count(&g_rq, 0) != 2 { pass = 0; }          // core 0 shrank
    switch rq_pop(&g_rq, 0) {                         // core 0 continues FIFO
        ok(v) => { if v != 101 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    return pass;
}
