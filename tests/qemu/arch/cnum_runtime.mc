// Bare-metal riscv64 M-mode runtime exercising the MC ctype + integer-parsing core
// (user/libc/cnum.mc) through the standard C prototypes, as QuickJS will — in PURE MC
// (no C). The all-MC replacement for kernel/arch/riscv64/cnum_runtime.c.
//
// cnum's strtol/strtoul take a `char**` endptr (typed `*mut u8` in the MC ABI) and store
// the end address THROUGH it as a usize. We pass the address of an 8-byte global cell as
// that endptr, then read the stored end address back with `raw.load<usize>` and check the
// byte at it — the MC-safe equivalent of the C runtime's `*end != '\0'`. Boot seam +
// console are the shared M-mode template modules; linked as a SECOND MC object beside
// cnum.mc.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

// The MC ctype + integer-parsing core (object symbols under test).
extern fn isdigit(c: i32) -> i32;
extern fn isalpha(c: i32) -> i32;
extern fn isalnum(c: i32) -> i32;
extern fn isspace(c: i32) -> i32;
extern fn isxdigit(c: i32) -> i32;
extern fn isupper(c: i32) -> i32;
extern fn islower(c: i32) -> i32;
extern fn isprint(c: i32) -> i32;
extern fn ispunct(c: i32) -> i32;
extern fn tolower(c: i32) -> i32;
extern fn toupper(c: i32) -> i32;
extern fn abs(v: i32) -> i32;
extern fn strtol(nptr: *const u8, endptr: *mut u8, base: i32) -> i64;
extern fn strtoul(nptr: *const u8, endptr: *mut u8, base: i32) -> u64;
extern fn atoi(nptr: *const u8) -> i32;

// 8-byte cell the parsers store the end address through (a `char**`).
global g_end: [8]u8;

// Load the end address the last strtol/strtoul stored through g_end.
fn end_addr() -> usize {
    let cell: usize = (&g_end[0]) as usize;
    var v: usize = 0;
    unsafe { v = raw.load<usize>(phys(cell)); }
    return v;
}

// Load the byte at address `a` (used to check the char the end pointer lands on).
fn byte_at(a: usize) -> u8 {
    var b: u8 = 0;
    unsafe { b = raw.load<u8>(phys(a)); }
    return b;
}

export fn test_main() -> void {
    put_str("cnum: exercising MC ctype + integer parsing\n");
    var pass: i32 = 1;

    let endp: *mut u8 = &g_end[0];

    // ctype
    if isdigit('5') == 0 { pass = 0; }
    if isdigit('a') != 0 { pass = 0; }
    if isalpha('a') == 0 || isalpha('Z') == 0 || isalpha('5') != 0 { pass = 0; }
    if isalnum('5') == 0 || isalnum('q') == 0 || isalnum('!') != 0 { pass = 0; }
    if isspace(' ') == 0 || isspace('\t') == 0 || isspace('x') != 0 { pass = 0; }
    if isxdigit('F') == 0 || isxdigit('9') == 0 || isxdigit('g') != 0 { pass = 0; }
    if isupper('A') == 0 || isupper('a') != 0 { pass = 0; }
    if isprint(' ') == 0 || isprint('\n') != 0 { pass = 0; }
    if ispunct('!') == 0 || ispunct('a') != 0 { pass = 0; }
    if toupper('a') != 'A' || toupper('Z') != 'Z' { pass = 0; }
    if tolower('Z') != 'z' || tolower('a') != 'a' { pass = 0; }
    if abs(-5) != 5 || abs(7) != 7 { pass = 0; }

    // strtol with endptr
    if strtol("123", endp, 10) != 123 || byte_at(end_addr()) != 0 { pass = 0; }
    if strtol("  -42xyz", endp, 10) != -42 || byte_at(end_addr()) != 'x' { pass = 0; }
    if strtol("0xFF", endp, 16) != 255 || byte_at(end_addr()) != 0 { pass = 0; }
    if strtol("0x1A", endp, 0) != 26 { pass = 0; }
    if strtol("777", endp, 8) != 511 { pass = 0; }      // 0777 octal = 511
    if strtol("0", endp, 10) != 0 || byte_at(end_addr()) != 0 { pass = 0; }
    if atoi("789") != 789 { pass = 0; }

    // strtoul negative wraps modulo 2^64
    if strtoul("-1", endp, 10) != 0xFFFF_FFFF_FFFF_FFFF { pass = 0; }
    if strtoul("4294967296", endp, 10) != 4294967296 { pass = 0; }

    // overflow SATURATES (must not trap) — reachable from untrusted JS numbers
    if strtoul("99999999999999999999999999", endp, 10) != 0xFFFF_FFFF_FFFF_FFFF { pass = 0; }
    if byte_at(end_addr()) != 0 { pass = 0; }           // and consumed the whole number
    if strtol("99999999999999999999999999", endp, 10) != 0x7FFF_FFFF_FFFF_FFFF { pass = 0; }   // LONG_MAX
    if (strtol("-99999999999999999999999999", endp, 10) as u64) != 0x8000_0000_0000_0000 { pass = 0; } // LONG_MIN

    if pass != 0 {
        put_str("CNUM-OK\n");
    } else {
        put_str("CNUM-BAD\n");
    }

    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
