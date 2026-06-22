import "kernel/lib/args.mc";
global g_args: Args;
export fn args_run() -> u32 {
    var pass: u32 = 1;
    args_init(&g_args);
    // argv = ["ls", "-l"]
    args_begin(&g_args); args_push_byte(&g_args, 0x6C); args_push_byte(&g_args, 0x73); args_end(&g_args); // "ls"
    args_begin(&g_args); args_push_byte(&g_args, 0x2D); args_push_byte(&g_args, 0x6C); args_end(&g_args); // "-l"
    if args_count(&g_args) != 2 { pass = 0; }
    if args_byte(&g_args, 0, 0) != 0x6C { pass = 0; } // l
    if args_byte(&g_args, 0, 1) != 0x73 { pass = 0; } // s
    if args_byte(&g_args, 1, 0) != 0x2D { pass = 0; } // -
    if args_byte(&g_args, 1, 1) != 0x6C { pass = 0; } // l
    if args_truncated(&g_args) { pass = 0; } // within capacity -> not truncated

    // Overflow: push more than ARG_MAX (8) arguments. argc must clamp at 8, truncated set,
    // and out-of-range indexing must stay in bounds (return 0, not OOB-read).
    args_init(&g_args);
    var n: u32 = 0;
    while n < 20 { // 20 > ARG_MAX
        args_begin(&g_args);
        args_push_byte(&g_args, 0x41); // 'A'
        args_end(&g_args);
        n = n + 1;
    }
    if args_count(&g_args) != 8 { pass = 0; }      // clamped at ARG_MAX, never 20
    if !args_truncated(&g_args) { pass = 0; }      // overflow flagged
    if args_byte(&g_args, 8, 0) != 0 { pass = 0; } // out-of-range -> 0, no OOB read
    if args_len(&g_args, 99) != 0 { pass = 0; }    // out-of-range -> 0

    // Buffer overflow: one giant argument longer than ARG_BUF (128). Bytes drop, the arg
    // is flagged truncated, used never exceeds the buffer.
    args_init(&g_args);
    args_begin(&g_args);
    var b: u32 = 0;
    while b < 300 { // 300 > ARG_BUF
        args_push_byte(&g_args, 0x42); // 'B'
        b = b + 1;
    }
    args_end(&g_args);
    if !args_truncated(&g_args) { pass = 0; } // buffer overflow flagged
    if args_byte(&g_args, 0, 0) != 0x42 { pass = 0; } // first byte still readable
    return pass;
}
