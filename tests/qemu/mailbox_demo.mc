import "std/mailbox.mc";
global g_mb: Mailbox<u32, 4>;
export fn mailbox_run() -> u32 {
    var pass: u32 = 1;
    mailbox_init(u32, 4, &g_mb);
    var out: u32 = 0;

    // FIFO across slot reuse: post A,B (slots 0,1); take A; post C (reuses slot 0);
    // the next take must be B (older), NOT C — even though C sits in the lower slot.
    if !mailbox_post(u32, 4, &g_mb, 0xA, 1) { pass = 0; } // slot 0
    if !mailbox_post(u32, 4, &g_mb, 0xB, 1) { pass = 0; } // slot 1
    if !mailbox_take(u32, 4, &g_mb, &out) { pass = 0; }
    if out != 0xA { pass = 0; }                           // oldest first
    if !mailbox_post(u32, 4, &g_mb, 0xC, 1) { pass = 0; } // reuses slot 0
    if !mailbox_take(u32, 4, &g_mb, &out) { pass = 0; }
    if out != 0xB { pass = 0; }                           // B before C (FIFO preserved)
    if !mailbox_take(u32, 4, &g_mb, &out) { pass = 0; }
    if out != 0xC { pass = 0; }
    if mailbox_take(u32, 4, &g_mb, &out) { pass = 0; }    // empty

    // source filtering still returns the oldest from that source
    if !mailbox_post(u32, 4, &g_mb, 10, 1) { pass = 0; }
    if !mailbox_post(u32, 4, &g_mb, 20, 2) { pass = 0; }
    if !mailbox_post(u32, 4, &g_mb, 30, 1) { pass = 0; }
    if !mailbox_take_from(u32, 4, &g_mb, 2, &out) { pass = 0; }
    if out != 20 { pass = 0; }                            // only src-2 message
    if !mailbox_take_from(u32, 4, &g_mb, 1, &out) { pass = 0; }
    if out != 10 { pass = 0; }                            // oldest src-1
    if !mailbox_take(u32, 4, &g_mb, &out) { pass = 0; }
    if out != 30 { pass = 0; }

    // drop policy: fill to capacity, next post rejected
    var i: u32 = 0;
    while i < 4 {
        if !mailbox_post(u32, 4, &g_mb, i, 0) { pass = 0; }
        i = i + 1;
    }
    if !mailbox_is_full(u32, 4, &g_mb) { pass = 0; }
    if mailbox_post(u32, 4, &g_mb, 99, 0) { pass = 0; }
    return pass;
}
