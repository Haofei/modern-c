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

    if rq_pop(&g_rq, 1) != 0xFFFFFFFF { pass = 0; } // core 1 empty
    let stolen: u32 = rq_steal(&g_rq, 1);            // core 1 steals from core 0
    if stolen != 100 { pass = 0; }                   // takes core 0's head (FIFO)
    if rq_count(&g_rq, 0) != 2 { pass = 0; }         // core 0 shrank
    if rq_pop(&g_rq, 0) != 101 { pass = 0; }         // core 0 continues FIFO
    return pass;
}
