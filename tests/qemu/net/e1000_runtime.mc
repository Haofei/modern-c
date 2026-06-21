// Bare-metal riscv64 M-mode test entry for the e1000 NIC PCI-probe demo
// (tests/qemu/net/e1000_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/e1000_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit runs the SAME existing MC demo
// (PCI-enumerate the ECAM bus + find the Intel e1000, vendor 0x8086/dev 0x100E) and
// reports E1000-OK when the NIC is found — writing the bare 16550 UART directly.

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

// The e1000 demo (tests/qemu/net/e1000_demo.mc): PCI-enumerate the ECAM bus and find
// the Intel e1000 NIC. Returns 1 when present.
extern fn e1000_run() -> u32;

export fn test_main() -> void {
    uputs("e1000 probe booting\n");
    if e1000_run() == 1 {
        uputs("E1000-OK\n");
    } else {
        uputs("E1000-ABSENT\n");
    }
    mc_halt();
}
