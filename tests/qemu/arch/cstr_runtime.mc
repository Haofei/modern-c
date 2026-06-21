// Bare-metal riscv64 M-mode runtime exercising the MC mem/string core (user/libc/cstr.mc)
// through the standard C prototypes, as QuickJS will — in PURE MC (no C). The all-MC
// replacement for kernel/arch/riscv64/cstr_runtime.c.
//
// cstr.mc IS the only mem/str libc in the image (linked WITHOUT freestanding.c), so this
// runtime declares its symbols `extern fn` and DRIVES them: memset/memcpy/memcmp,
// strlen/strcmp/strncmp, strchr/memchr, and an overlapping memmove. Pointer results are
// compared in `usize` space (MC has no raw pointer-comparison operator), which is the same
// address arithmetic the C runtime did with `s1 + 2`. Boot seam + console are the shared
// M-mode template modules. Linked as a SECOND MC object alongside cstr.mc.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

// The MC mem/string core (object symbols under test).
extern fn memcpy(dst: *mut u8, src: *const u8, n: usize) -> *mut u8;
extern fn memset(dst: *mut u8, c: i32, n: usize) -> *mut u8;
extern fn memmove(dst: *mut u8, src: *const u8, n: usize) -> *mut u8;
extern fn memcmp(a: *const u8, b: *const u8, n: usize) -> i32;
extern fn memchr(s: *const u8, c: i32, n: usize) -> *mut u8;
extern fn strlen(s: *const u8) -> usize;
extern fn strcmp(a: *const u8, b: *const u8) -> i32;
extern fn strncmp(a: *const u8, b: *const u8, n: usize) -> i32;
extern fn strchr(s: *const u8, c: i32) -> *mut u8;

global g_buf: [64]u8;
global g_buf2: [64]u8;
global g_mv: [8]u8;

export fn test_main() -> void {
    put_str("cstr: exercising MC mem/string core\n");
    var pass: i32 = 1;

    let buf: *mut u8 = &g_buf[0];
    let buf2: *mut u8 = &g_buf2[0];
    // `*const u8` views of the same buffers, taken directly (a `*mut -> *const` cast is
    // representation-sensitive, but taking the address as const is not).
    let bufc: *const u8 = &g_buf[0];
    let buf2c: *const u8 = &g_buf2[0];

    // memset + readback
    memset(buf, 0xAB, 32);
    var i: usize = 0;
    while i < 32 {
        if g_buf[i] != 0xAB { pass = 0; }
        i = i + 1;
    }

    // memcpy + memcmp equal/unequal
    memcpy(buf2, bufc, 32);
    if memcmp(bufc, buf2c, 32) != 0 { pass = 0; }
    g_buf2[10] = 0x00;
    if memcmp(bufc, buf2c, 32) <= 0 { pass = 0; } // buf>buf2 at [10]

    // strlen / strcmp / strncmp
    let s1: *const u8 = "hello";
    let s2: *const u8 = "hello";
    let s3: *const u8 = "help";
    if strlen(s1) != 5 { pass = 0; }
    if strlen("") != 0 { pass = 0; }
    if strcmp(s1, s2) != 0 { pass = 0; }
    if strcmp(s1, s3) >= 0 { pass = 0; }       // "hello" < "help" ('l' < 'p')
    if strncmp(s1, s3, 3) != 0 { pass = 0; }   // "hel" == "hel"
    if strncmp(s1, s3, 4) >= 0 { pass = 0; }

    // strchr / memchr — compare returned addresses in usize space
    let s1a: usize = s1 as usize;
    if (strchr(s1, 'l') as usize) != s1a + 2 { pass = 0; }
    if (strchr(s1, 'z') as usize) != 0 { pass = 0; }
    if (strchr(s1, 0) as usize) != s1a + 5 { pass = 0; }   // matches the terminator
    if (memchr(s1, 'o', 5) as usize) != s1a + 4 { pass = 0; }
    if (memchr(s1, 'z', 5) as usize) != 0 { pass = 0; }

    // memmove with overlap (shift right by 2 within a buffer)
    g_mv[0] = 'A'; g_mv[1] = 'B'; g_mv[2] = 'C'; g_mv[3] = 'D'; g_mv[4] = 0;
    let mvc: *const u8 = &g_mv[0];
    let mv2: *mut u8 = &g_mv[2];
    memmove(mv2, mvc, 4); // region [2..6) becomes A B C D
    if !(g_mv[2] == 'A' && g_mv[3] == 'B' && g_mv[4] == 'C' && g_mv[5] == 'D') { pass = 0; }

    if pass != 0 {
        put_str("CSTR-OK\n");
    } else {
        put_str("CSTR-BAD\n");
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
