// Bare-metal riscv64 M-mode runtime exercising the MC printf family (user/libc) — in PURE
// MC (no C). The all-MC replacement for kernel/arch/riscv64/stdio_runtime.c: it DEFINES the
// `mc_console_write` hook (which stdio.mc declares `extern fn` and streams formatted output
// through), then checks snprintf output against expected strings across the integer/string/
// char/pointer specifiers, then exercises printf-to-console.
//
// MC cannot pass a trailing `...` at a call site, so snprintf/printf are bound through FIXED
// C-ABI prototypes carrying three i64 slots. On the lp64 ABI every vararg occupies one
// 8-byte integer slot, so the formatter's `va.arg<i32>/<i64>/<u64>/<usize>` reads pick the
// right value out of the same a-register/stack sequence a fixed three-slot call fills; the
// format string controls how many slots are consumed (trailing unused slots are ignored).
// Integer args are sign/zero-extended into their i64 slot; string args pass their address
// in a slot (pointers share the integer register class on lp64), which is exactly the value
// the formatter reads back as a `usize`. Boot seam + console are the shared M-mode template
// modules; linked as a SECOND MC object beside the aggregated libc.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

// The printf family under test, bound through fixed three-slot C-ABI prototypes (see header).
extern fn snprintf(buf: *mut u8, size: usize, fmt: *const u8, a: i64, b: i64, c: i64) -> i32;
extern fn printf(fmt: *const u8, a: i64, b: i64, c: i64) -> i32;

// The console hook the MC formatter calls (stdio.mc: extern fn mc_console_write(buf, len)).
// Streams the rendered bytes straight to the bare 16550 UART.
export fn mc_console_write(buf: usize, len: usize) -> void {
    var i: usize = 0;
    while i < len {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(buf + i)); }
        console_putc(b);
        i = i + 1;
    }
}

global g_buf: [128]u8;
global g_small: [4]u8;

// Compare the NUL-terminated bytes in g_buf against `want`. Returns 1 if equal.
fn buf_eq(want: *const u8) -> i32 {
    let wbase: usize = want as usize;
    var i: usize = 0;
    while true {
        var w: u8 = 0;
        unsafe { w = raw.load<u8>(phys(wbase + i)); }
        let g: u8 = g_buf[i];
        if g != w { return 0; }
        if w == 0 { return 1; }
        i = i + 1;
    }
    return 0;
}

// Address of g_buf as a usize (the snprintf destination), and as a typed pointer.
fn buf_ptr() -> *mut u8 {
    return &g_buf[0];
}

// Render `fmt` (with up to three i64 slots) into g_buf and check it equals `want`. Returns
// 0 on mismatch and emits a diagnostic, mirroring the C runtime's EXPECT macro.
fn expect(want: *const u8, a: i64, b: i64, c: i64, fmt: *const u8) -> i32 {
    snprintf(buf_ptr(), 128, fmt, a, b, c);
    if buf_eq(want) != 0 {
        return 1;
    }
    put_str("  MISMATCH: got '");
    put_str(&g_buf[0]);
    put_str("' want '");
    put_str(want);
    put_str("'\n");
    return 0;
}

// A string literal's address as an i64 slot value (string literals cannot be cast inline;
// bind to a typed pointer first, then ptr -> usize -> i64, all in the integer domain).
fn saddr(s: *const u8) -> i64 {
    return (s as usize) as i64;
}

export fn test_main() -> void {
    put_str("stdio: exercising MC printf family\n");
    var fails: i32 = 0;

    let s_hi: *const u8 = "hi";
    let s_hello: *const u8 = "hello";
    let s_ok: *const u8 = "ok";

    if expect("42", 42, 0, 0, "%d") == 0 { fails = fails + 1; }
    if expect("-7", -7, 0, 0, "%d") == 0 { fails = fails + 1; }
    if expect("00042", 42, 0, 0, "%05d") == 0 { fails = fails + 1; }
    if expect("   42", 42, 0, 0, "%5d") == 0 { fails = fails + 1; }
    if expect("42   |", 42, 0, 0, "%-5d|") == 0 { fails = fails + 1; }
    if expect("+42", 42, 0, 0, "%+d") == 0 { fails = fails + 1; }
    if expect("ff", 255, 0, 0, "%x") == 0 { fails = fails + 1; }
    if expect("0xff", 255, 0, 0, "%#x") == 0 { fails = fails + 1; }
    if expect("FF", 255, 0, 0, "%X") == 0 { fails = fails + 1; }
    if expect("10", 8, 0, 0, "%o") == 0 { fails = fails + 1; }
    if expect("100", 100, 0, 0, "%u") == 0 { fails = fails + 1; }
    if expect("A", 'A' as i64, 0, 0, "%c") == 0 { fails = fails + 1; }
    if expect("hi", saddr(s_hi), 0, 0, "%s") == 0 { fails = fails + 1; }
    if expect("hel", saddr(s_hello), 0, 0, "%.3s") == 0 { fails = fails + 1; }
    if expect("        hi", saddr(s_hi), 0, 0, "%10s") == 0 { fails = fails + 1; }
    if expect("hi        |", saddr(s_hi), 0, 0, "%-10s|") == 0 { fails = fails + 1; }
    if expect("%", 0, 0, 0, "%%") == 0 { fails = fails + 1; }
    if expect("10000000000", 10000000000, 0, 0, "%lld") == 0 { fails = fails + 1; }
    if expect("deadbeef", 0xDEADBEEF, 0, 0, "%llx") == 0 { fails = fails + 1; }
    if expect("4096", 4096, 0, 0, "%zu") == 0 { fails = fails + 1; }
    if expect("x=5,s=ok,h=0x10", 5, saddr(s_ok), 16, "x=%d,s=%s,h=%#x") == 0 { fails = fails + 1; }
    if expect("(null)", 0, 0, 0, "%s") == 0 { fails = fails + 1; }
    if expect("0007", 4, 7, 0, "%.*d") == 0 { fails = fails + 1; }
    if expect("     7", 6, 7, 0, "%*d") == 0 { fails = fails + 1; }

    // truncation: C99 return is the would-be length; buffer is bounded + NUL-terminated.
    let wid: i32 = snprintf(&g_small[0], 4, "%d", 123456, 0, 0);
    if wid != 6 { fails = fails + 1; }            // would have written 6 chars
    // only "123" fits (+ NUL)
    if !(g_small[0] == '1' && g_small[1] == '2' && g_small[2] == '3' && g_small[3] == 0) {
        fails = fails + 1;
    }

    if fails == 0 {
        printf("printf-to-console works: %d+%d=%d\n", 2, 3, 5); // also exercise the console sink
        put_str("STDIO-OK\n");
    } else {
        put_str("STDIO-BAD\n");
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
