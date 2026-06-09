import "kernel/core/liveupdate.mc";
import "std/addr.mc";
global g_buf: [16]u8;
export fn liveupdate_run() -> u32 {
    var pass: u32 = 1;
    // version 1 runs and builds up state
    var v1: ServiceState = .{ .version = 1, .counter = 0, .total = 0 };
    v1.counter = 5;
    v1.total = 100;
    lu_checkpoint(&v1, pa((&g_buf[0]) as usize));

    // live update: install version 2 (fresh code), hand the old state over
    var v2: ServiceState = .{ .version = 0, .counter = 0, .total = 0 };
    lu_restore(&v2, pa((&g_buf[0]) as usize), 2);

    if v2.version != 2 { pass = 0; }   // now running the new code
    if v2.counter != 5 { pass = 0; }   // with the old state preserved
    if v2.total != 100 { pass = 0; }
    return pass;
}
