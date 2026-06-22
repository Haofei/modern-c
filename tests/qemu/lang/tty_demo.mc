import "kernel/lib/tty.mc";
import "std/addr.mc";
global g_tty: Tty;
global g_out: [64]u8;
export fn tty_run() -> u32 {
    var pass: u32 = 1;
    tty_init(&g_tty);
    // type "ab", backspace (erase b), "c", newline -> line "ac"
    tty_input(&g_tty, 0x61); // a
    tty_input(&g_tty, 0x62); // b
    tty_input(&g_tty, 0x08); // backspace
    tty_input(&g_tty, 0x63); // c
    if tty_ready(&g_tty) { pass = 0; } // not ready until newline
    tty_input(&g_tty, 0x0A); // newline
    if !tty_ready(&g_tty) { pass = 0; }
    let n: usize = tty_readline(&g_tty, pa((&g_out[0]) as usize), 64);
    if n != 2 { pass = 0; }
    if g_out[0] != 0x61 { pass = 0; } // 'a'
    if g_out[1] != 0x63 { pass = 0; } // 'c'
    if tty_ready(&g_tty) { pass = 0; } // cleared after read
    return pass;
}
