// Bare-metal riscv64 test entry for the async vectored-drain demo
// (tests/qemu/proc/async_pollmany_demo.mc), in PURE MC. `_start`, the context-switch primitives,
// and `mc_halt` come from the shared M-mode bring-up runtime (context_runtime.c, linked beside
// this object). The demo imports kernel/core/console.mc and so DEFINES `console_putc`; to avoid a
// duplicate definition this unit does NOT import console.mc — it uses the raw-UART `uputc`/`uputs`
// from test_report.mc for its own diagnostics.

import "tests/qemu/lib/test_report.mc";

extern fn mc_halt() -> void;

// The async vectored-drain demo: submit 4, complete 3 out of order, drain (capped + re-enterable),
// confirm the harvested completions, slot reuse, and that a pending request is never drained.
extern fn async_pollmany_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region (unused by this broker-only demo, but the entry ABI matches the others).
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("async-pollmany booting\n");
    let r: u32 = async_pollmany_demo((&g_heap_region) as usize, 262144);
    if r == 1 {
        uputs("\nASYNC-POLLMANY-OK\n");
    } else {
        uputs("\nASYNC-POLLMANY-FAIL\n");
    }
    mc_halt();
}
