// Bare-metal riscv64 M-mode test entry for the net-server demo
// (tests/qemu/net/net_server_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/net_server_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start` calls
// the `test_main` exported here. This unit supplies the physical region the kernel
// heap sub-allocates per-thread stacks from, runs the SAME existing MC demo (a client
// binds a UDP port, injects a datagram, and receives it back — all over IPC to the net
// server), and reports NET-SERVER-OK on success — writing the bare 16550 UART directly.

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

// The net-server demo (tests/qemu/net/net_server_demo.mc): a client binds a UDP port,
// injects + receives a datagram across the IPC boundary. Returns 1 on success.
extern fn net_server_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates thread stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("net-server booting\n");
    let r: u32 = net_server_demo((&g_heap_region) as usize, 262144);
    if r == 1 {
        uputs("NET-SERVER-OK\n");
    } else {
        uputs("NET-SERVER-FAIL\n");
    }
    mc_halt();
}
