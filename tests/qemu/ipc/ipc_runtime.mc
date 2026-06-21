// Bare-metal riscv64 test entry for the microkernel IPC demo
// (tests/qemu/ipc/ipc_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/ipc_runtime.c: it supplies the physical region the kernel heap
// carves process stacks from, runs the demo, and reports the round-trip result.
//
// `_start`, the context-switch primitives, and `mc_halt` come from the shared M-mode
// bring-up runtime (kernel/arch/riscv64/context_runtime.c, linked beside this object).
// This unit declares `mc_halt` `extern fn` and drives the demo exactly as the C did.
//
// The IPC demo imports kernel/core/console.mc and so DEFINES `console_putc` in its
// object; to avoid a duplicate `console_putc` definition across the two linked
// objects, this unit does NOT import console.mc/mmio_console.mc — it writes the bare
// 16550 UART directly (the same raw store console.mc performs) for its diagnostics.

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register

// Write one byte to the bare 16550 UART transmit register.
fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

// Write a NUL-terminated string over the bare UART.
fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        uputc(b);
        i = i + 1;
    }
}

// Defined in the shared M-mode bring-up runtime (context_runtime.c): stop the
// machine via the SiFive test finisher.
extern fn mc_halt() -> void;

// The IPC demo (tests/qemu/ipc/ipc_demo.mc): a client and a user-mode service
// round-trip a request/reply through ipc_send/ipc_receive over the physical region
// the kernel heap carves process stacks from; returns 21*2 == 42 on success.
extern fn ipc_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates process stacks from. The heap
// allocator aligns every allocation internally, so the region base need not be
// page-aligned.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("ipc booting\n");
    let r: u32 = ipc_demo((&g_heap_region) as usize, 262144);
    uputs("\nresult=");
    uputc((48 + ((r / 10) % 10)) as u8); // tens digit
    uputc((48 + (r % 10)) as u8);        // ones digit
    uputc(10); // '\n'
    if r == 42 {
        uputs("IPC-OK\n");
    } else {
        uputs("IPC-FAIL\n");
    }
    mc_halt();
}
