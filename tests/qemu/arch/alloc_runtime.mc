// Bare-metal riscv64 M-mode runtime exercising the MC C-ABI allocator (user/libc/alloc.mc)
// the way C (QuickJS) will — malloc/free/calloc/realloc through the standard prototypes —
// in PURE MC (no C). The all-MC replacement for kernel/arch/riscv64/alloc_runtime.c.
//
// Verifies distinct non-overlapping allocations, write/read round-trips, reuse after free,
// calloc zeroing, realloc content preservation, and that overflowing calloc returns NULL
// (must not trap). Returned `*mut u8` blocks are filled/checked through `raw.store`/
// `raw.load` at their address (MC has no raw-pointer indexing), which is the same byte
// access the C runtime's `p[i]` did. Boot seam + console are the shared M-mode template
// modules; linked as a SECOND MC object beside alloc.mc.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

// The MC allocator (object symbols under test).
extern fn malloc(size: usize) -> *mut u8;
extern fn calloc(count: usize, size: usize) -> *mut u8;
extern fn realloc(p: *mut u8, size: usize) -> *mut u8;
extern fn free(p: *mut u8) -> void;

// Fill n bytes at address `base` with seed+i (wrapping).
fn fill(base: usize, n: usize, seed: u8) -> void {
    var i: usize = 0;
    while i < n {
        let v: u8 = (seed as usize + i) as u8;
        unsafe { raw.store<u8>(phys(base + i), v); }
        i = i + 1;
    }
}

// Check n bytes at `base` equal seed+i (wrapping). Returns 1 on match, 0 otherwise.
fn check(base: usize, n: usize, seed: u8) -> i32 {
    var i: usize = 0;
    while i < n {
        let want: u8 = (seed as usize + i) as u8;
        var got: u8 = 0;
        unsafe { got = raw.load<u8>(phys(base + i)); }
        if got != want { return 0; }
        i = i + 1;
    }
    return 1;
}

export fn test_main() -> void {
    put_str("alloc: exercising MC C-ABI allocator\n");
    var pass: i32 = 1;

    // Distinct, writable, non-overlapping allocations.
    let a: *mut u8 = malloc(100);
    let b: *mut u8 = malloc(200);
    let aa: usize = a as usize;
    let ba: usize = b as usize;
    if aa == 0 || ba == 0 || aa == ba { pass = 0; }
    if pass != 0 { fill(aa, 100, 0x11); fill(ba, 200, 0x22); }
    if pass != 0 && (check(aa, 100, 0x11) == 0 || check(ba, 200, 0x22) == 0) { pass = 0; } // no aliasing

    // Reuse after free: freeing a then allocating the same size should succeed and be writable.
    free(a);
    let c: *mut u8 = malloc(100);
    let ca: usize = c as usize;
    if ca == 0 { pass = 0; }
    if pass != 0 { fill(ca, 100, 0x33); if check(ca, 100, 0x33) == 0 { pass = 0; } }
    if pass != 0 && check(ba, 200, 0x22) == 0 { pass = 0; } // b untouched by a's free + c's alloc

    // calloc zeroes.
    let z: *mut u8 = calloc(10, 8); // 80 bytes
    let za: usize = z as usize;
    if za == 0 { pass = 0; }
    if pass != 0 {
        var i: usize = 0;
        while i < 80 {
            var got: u8 = 0;
            unsafe { got = raw.load<u8>(phys(za + i)); }
            if got != 0 { pass = 0; }
            i = i + 1;
        }
    }

    // realloc preserves existing content and grows.
    let r: *mut u8 = malloc(50);
    let ra: usize = r as usize;
    if ra == 0 { pass = 0; }
    if pass != 0 { fill(ra, 50, 0x44); }
    let r2: *mut u8 = realloc(r, 100);
    let r2a: usize = r2 as usize;
    if r2a == 0 { pass = 0; }
    if pass != 0 && check(r2a, 50, 0x44) == 0 { pass = 0; } // first 50 bytes survive the grow

    // calloc overflow returns NULL (must not trap) — reachable from a huge JS typed-array length.
    if (calloc(0xFFFF_FFFF_FFFF_FFFF, 2) as usize) != 0 { pass = 0; }
    let big: usize = 1 << 40;
    if (calloc(big, big) as usize) != 0 { pass = 0; }

    free(b);
    free(c);
    free(z);
    free(r2);

    if pass != 0 {
        put_str("ALLOC-OK\n");
    } else {
        put_str("ALLOC-BAD\n");
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
