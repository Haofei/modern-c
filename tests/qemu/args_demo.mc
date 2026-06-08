import "kernel/core/args.mc";
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
    return pass;
}
