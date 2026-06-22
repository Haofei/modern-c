import "kernel/core/userland.mc";
import "kernel/lib/args.mc";
import "std/addr.mc";
global g_args: Args;
global g_out: [32]u8;
export fn userland_run() -> u32 {
    var pass: u32 = 1;
    args_init(&g_args);
    args_begin(&g_args); args_push_byte(&g_args, 0x68); args_push_byte(&g_args, 0x69); args_end(&g_args); // "hi"
    args_begin(&g_args); args_push_byte(&g_args, 0x79); args_push_byte(&g_args, 0x6F); args_end(&g_args); // "yo"
    let n: usize = util_echo(&g_args, pa((&g_out[0]) as usize), 32);
    if n != 5 { pass = 0; }            // "hi yo"
    if g_out[0] != 0x68 { pass = 0; }  // h
    if g_out[1] != 0x69 { pass = 0; }  // i
    if g_out[2] != 0x20 { pass = 0; }  // space
    if g_out[3] != 0x79 { pass = 0; }  // y
    if g_out[4] != 0x6F { pass = 0; }  // o
    return pass;
}
