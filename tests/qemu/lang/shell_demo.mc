import "kernel/core/shell.mc";
import "std/addr.mc";
global g_line: [16]u8;
fn run_cmd(b0: u8, b1: u8, b2: u8, b3: u8, b4: u8, n: usize) -> u32 {
    g_line[0]=b0; g_line[1]=b1; g_line[2]=b2; g_line[3]=b3; g_line[4]=b4;
    return sh_exec(pa((&g_line[0]) as usize), n);
}
export fn shell_run() -> u32 {
    var pass: u32 = 1;
    if run_cmd(0x74,0x72,0x75,0x65,0,4) != 0 { pass = 0; }   // "true" -> 0
    if run_cmd(0x66,0x61,0x6C,0x73,0x65,5) != 1 { pass = 0; } // "false" -> 1
    if run_cmd(0x6E,0x6F,0x70,0x65,0,4) != 127 { pass = 0; }  // "nope" -> 127
    return pass;
}
