// Bare-metal riscv64 M-mode runtime for the variadic-function demo — in PURE MC (no C).
// The all-MC replacement for kernel/arch/riscv64/vararg_runtime.c: it calls the C-ABI
// variadic MC function `sum_args` (tests/qemu/lang/vararg_demo.mc) with several argument
// counts — exactly as C (QuickJS) will call our printf-family shims — verifies the sums,
// and reports on the bare 16550 UART.
//
// MC cannot pass a trailing `...` at a call site, so `sum_args` is declared here with a
// FIXED 10-argument C-ABI prototype (count + nine i64 slots). On the lp64 ABI a variadic
// callee reads its integer varargs from the very same a0.. / stack sequence a fixed call
// fills, so a fixed call passing nine value slots is ABI-identical to the C runtime's
// variadic calls; `count` still controls how many slots `sum_args` actually reads off the
// cursor (the trailing unused slots are ignored), and the nine-slot calls still spill past
// the eight argument registers, exercising the stack-passed-vararg path.
//
// The boot seam (naked `_start` in `.text.start`) and the console (mmio_console over the
// bare 16550) are the shared M-mode template modules.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

const FINISHER: usize = 0x0010_0000;       // SiFive test finisher
const FINISHER_HALT: u32 = 0x5555;         // power-off / end-of-run code

// The MC variadic function under test, bound through a fixed 10-argument C-ABI prototype
// (see file header for why this is ABI-equivalent to a `...` call).
extern fn sum_args(count: i32, a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, i: i64) -> i64;

export fn test_main() -> void {
    put_str("vararg: calling C-ABI variadic MC fn\n");

    var pass: i32 = 1;

    // 10 + 20 + 30 = 60
    if sum_args(3, 10, 20, 30, 0, 0, 0, 0, 0, 0) != 60 { pass = 0; }
    // 1 + 2 + 3 + 4 + 5 = 15 (more varargs than fit-and-spill exercises the cursor's
    // stack-spill portion).
    if sum_args(5, 1, 2, 3, 4, 5, 0, 0, 0, 0) != 15 { pass = 0; }
    // 9 trailing args: forces stack-passed varargs on lp64 (8 arg regs, count is a0).
    if sum_args(9, 1, 2, 3, 4, 5, 6, 7, 8, 9) != 45 { pass = 0; }
    // Zero varargs: the cursor is started and ended without a read.
    if sum_args(0, 0, 0, 0, 0, 0, 0, 0, 0, 0) != 0 { pass = 0; }
    // A negative-summing case to confirm signed i64 slots round-trip.
    if sum_args(2, -100, 40, 0, 0, 0, 0, 0, 0, 0) != -60 { pass = 0; }

    if pass != 0 {
        put_str("VARARG-OK\n");
    } else {
        put_str("VARARG-BAD\n");
    }

    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode. `#[section(".text.start")]` pins
// `_start` there (virt.ld: `*(.text.start)` first, `ENTRY(_start)`). Set the stack and
// call into the kernel; never returns.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
