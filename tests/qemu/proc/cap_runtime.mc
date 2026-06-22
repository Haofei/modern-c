// Bare-metal riscv64 M-mode test entry for the capability/driver-server demo
// (tests/qemu/proc/cap_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/cap_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit supplies the physical region the
// kernel heap sub-allocates per-thread stacks from, runs the SAME existing MC demo,
// and reports CAP-OK when the console server reaped both peers — writing the bare
// 16550 UART directly.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The capability demo (tests/qemu/proc/cap_demo.mc): a console driver-as-server holds
// the sole console capability and prints [HI]; the client reaches it only via IPC.
// Returns the number of servers reaped (2 on success).
extern fn cap_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates thread stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("cap booting\n[");
    let reaped: u32 = cap_demo((&g_heap_region) as usize, 262144);
    uputs("]\nreaped=");
    uputc((48 + (reaped % 10)) as u8); // '0' + digit
    uputc(10); // '\n'
    if reaped == 2 {
        uputs("CAP-OK\n");
    } else {
        uputs("CAP-FAIL\n");
    }
    mc_halt();
}
