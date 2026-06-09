// The fuller shell: tokenize a command line into argv and run builtins, checking the
// exit code and (for echo) the captured output.
import "kernel/core/shell.mc";
import "std/addr.mc";

global g_sh: Shell;
global g_line: [32]u8;

// Load a command line into g_line and run it; returns the exit code.
fn run(n: usize) -> u32 {
    sh_run(&g_sh, pa((&g_line[0]) as usize), n);
    return sh_code(&g_sh);
}
fn put(i: usize, b: u8) -> void { g_line[i] = b; }

export fn shell2_run() -> u32 {
    var pass: u32 = 1;
    sh_init(&g_sh);

    // "echo hi yo"
    put(0,0x65); put(1,0x63); put(2,0x68); put(3,0x6F); put(4,0x20); // "echo "
    put(5,0x68); put(6,0x69); put(7,0x20); put(8,0x79); put(9,0x6F); // "hi yo"
    if run(10) != 0 { pass = 0; }
    if sh_out_len(&g_sh) != 5 { pass = 0; }       // "hi yo"
    if sh_out_byte(&g_sh, 0) != 0x68 { pass = 0; }     // h
    if sh_out_byte(&g_sh, 1) != 0x69 { pass = 0; }     // i
    if sh_out_byte(&g_sh, 2) != 0x20 { pass = 0; }     // space
    if sh_out_byte(&g_sh, 3) != 0x79 { pass = 0; }     // y
    if sh_out_byte(&g_sh, 4) != 0x6F { pass = 0; }     // o

    // "true" -> 0, no output
    put(0,0x74); put(1,0x72); put(2,0x75); put(3,0x65);
    if run(4) != 0 { pass = 0; }
    if sh_out_len(&g_sh) != 0 { pass = 0; }

    // "false" -> 1
    put(0,0x66); put(1,0x61); put(2,0x6C); put(3,0x73); put(4,0x65);
    if run(5) != 1 { pass = 0; }

    // "nope" -> 127 (not found)
    put(0,0x6E); put(1,0x6F); put(2,0x70); put(3,0x65);
    if run(4) != 127 { pass = 0; }

    // leading/extra spaces tolerated: "  echo  x"
    put(0,0x20); put(1,0x20); put(2,0x65); put(3,0x63); put(4,0x68); put(5,0x6F);
    put(6,0x20); put(7,0x20); put(8,0x78);
    if run(9) != 0 { pass = 0; }
    if sh_out_len(&g_sh) != 1 { pass = 0; }       // "x"
    if sh_out_byte(&g_sh, 0) != 0x78 { pass = 0; }

    return pass;
}
