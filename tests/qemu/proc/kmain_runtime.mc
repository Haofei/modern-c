// Bare-metal riscv64 M-mode boot entry for the integrated kernel demo
// (tests/qemu/proc/kmain_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/kmain_runtime.c: it supplies the physical region the kernel
// carves the heap (and process stacks) from, calls `kmain`, and reports the stage
// bitmask.
//
// The context-switch primitives (mc_switch_context/mc_thread_init, used by the
// process scheduler the demo drives), `_start`, and `mc_halt` come from the shared
// M-mode bring-up runtime (kernel/arch/riscv64/context_runtime.c, linked beside this
// object): `_start` sets the stack and calls `test_main`. This unit declares mc_halt
// `extern fn`, owns the heap region, and reports the stages over the bare 16550 UART
// through mmio_console.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c): stop the
// machine via the SiFive test finisher.
extern fn mc_halt() -> void;

// The integrated kernel entry (tests/qemu/proc/kmain_demo.mc): brings up heap,
// console driver, logger, VFS, scheduler, then runs a session-pool workload over
// the given physical region; returns a bitmask of the stages that succeeded.
extern fn kmain(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel sub-allocates the heap + process stacks from.
// The heap allocator (kernel/core/heap.mc) aligns every allocation internally, so
// the region base need not be page-aligned for correctness.
const HEAP_REGION_LEN: usize = 256 * 1024;
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    put_str("\nkmain boot (integrated kernel)\n");
    let base: usize = (&g_heap_region[0]) as usize;
    let stages: u32 = kmain(base, HEAP_REGION_LEN);
    put_str("\nstages=0x");
    // two hex nibbles of the low byte
    let hi: u32 = (stages >> 4) & 0xF;
    let lo: u32 = stages & 0xF;
    console_putc(hex_nibble(hi));
    console_putc(hex_nibble(lo));
    console_putc(10); // '\n'
    if stages == 0x3F {
        put_str("KERNEL-OK\n"); // 5 subsystems + the session-pool workload
    } else {
        put_str("KERNEL-INCOMPLETE\n");
    }
    mc_halt();
}

// One lowercase hex digit for a nibble 0..15.
fn hex_nibble(n: u32) -> u8 {
    if n < 10 {
        return (48 + n) as u8; // '0'..'9'
    }
    return (87 + n) as u8; // 'a'..'f'  ('a' == 97 == 87 + 10)
}
