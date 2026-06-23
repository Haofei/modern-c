// Bare-metal riscv64 test entry for the async CANCEL broker demo
// (tests/qemu/proc/async_cancel_demo.mc), in PURE MC. `_start`, the context-switch primitives,
// and `mc_halt` come from the shared M-mode bring-up runtime (context_runtime.c, linked beside
// this object). The demo imports kernel/core/console.mc and so DEFINES `console_putc`; to avoid
// a duplicate definition this unit does NOT import console.mc — it uses the raw-UART
// `uputc`/`uputs` from test_report.mc for its own diagnostics.

import "tests/qemu/lib/test_report.mc";

extern fn mc_halt() -> void;

// The async cancel demo: fill the inflight quota, cancel one request, prove its slot is reclaimed
// (a fresh submit succeeds) and a late completion on the canceled id is a no-op. Returns 1 on pass.
extern fn async_cancel_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region (unused by this broker-only demo, but the entry ABI matches the others).
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("async-cancel booting\n");
    let r: u32 = async_cancel_demo((&g_heap_region) as usize, 262144);
    if r == 1 {
        uputs("\nASYNC-CANCEL-OK\n");
    } else {
        uputs("\nASYNC-CANCEL-FAIL\n");
    }
    mc_halt();
}
