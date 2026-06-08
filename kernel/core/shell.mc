// kernel/core/shell — a minimal command interpreter: parse the first word of a command
// line and dispatch a builtin, returning its exit code (true=0, false=1, unknown=127).
// The skeleton of a shell; a full one would fork/exec external programs.

import "std/libc.mc";
import "std/addr.mc";

const SH_NOTFOUND: u32 = 127;

export fn sh_exec(line: PAddr, len: usize) -> u32 {
    // length of the first whitespace-delimited word
    var wlen: usize = 0;
    var scanning: bool = true;
    while scanning {
        if wlen >= len {
            scanning = false;
        } else {
            var c: u8 = 0;
            unsafe {
                c = raw.load<u8>(pa_offset(line, wlen));
            }
            if c == 0x20 {
                scanning = false;
            } else {
                wlen = wlen + 1;
            }
        }
    }
    var tbuf: [4]u8 = .{ 0x74, 0x72, 0x75, 0x65 };       // "true"
    var fbuf: [5]u8 = .{ 0x66, 0x61, 0x6C, 0x73, 0x65 }; // "false"
    if wlen == 4 {
        if mc_memeq(line, pa((&tbuf[0]) as usize), 4) {
            return 0;
        }
    }
    if wlen == 5 {
        if mc_memeq(line, pa((&fbuf[0]) as usize), 5) {
            return 1;
        }
    }
    return SH_NOTFOUND;
}
