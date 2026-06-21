// Bare-metal riscv64 M-mode test entry for the IPC-completeness demo
// (tests/qemu/ipc/ipc2_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/ipc2_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit supplies the physical region the
// kernel heap sub-allocates per-thread stacks from, runs the SAME existing MC demo
// (multi-slot mailbox + source filter + async notify), and reports IPC2-OK when the
// demo passes — writing the bare 16550 UART directly.

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

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The IPC-completeness demo (tests/qemu/ipc/ipc2_demo.mc): two clients queue
// messages; the server takes B's before A's via the source filter, then drains A's,
// then a non-blocking notify. Returns 1 on success.
extern fn ipc2_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates thread stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("ipc2 booting\n");
    let r: u32 = ipc2_demo((&g_heap_region) as usize, 262144);
    if r == 1 {
        uputs("IPC2-OK\n");
    } else {
        uputs("IPC2-FAIL\n");
    }
    mc_halt();
}
