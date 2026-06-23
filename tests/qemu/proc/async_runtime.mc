// Bare-metal riscv64 test entry for the async park/wake broker demo
// (tests/qemu/proc/async_demo.mc), in PURE MC. `_start`, the context-switch primitives, and
// `mc_halt` come from the shared M-mode bring-up runtime (context_runtime.c, linked beside
// this object). The demo imports kernel/core/console.mc and so DEFINES `console_putc`; to
// avoid a duplicate definition this unit does NOT import console.mc — it uses the raw-UART
// `uputc`/`uputs` from test_report.mc for its own diagnostics.

import "tests/qemu/lib/test_report.mc";

extern fn mc_halt() -> void;

// The async demo: two cooperative processes exercise the request-id-keyed park/wake broker;
// returns 42 (= 22 + 20) iff both completions reached the parked/awaited waiter.
extern fn async_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates process stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("async booting\n");
    let r: u32 = async_demo((&g_heap_region) as usize, 262144);
    uputs("\nresult=");
    uputc((48 + ((r / 10) % 10)) as u8); // tens digit
    uputc((48 + (r % 10)) as u8);        // ones digit
    uputc(10); // '\n'
    if r == 42 {
        uputs("ASYNC-OK\n");
    } else {
        uputs("ASYNC-FAIL\n");
    }
    mc_halt();
}
