// Bare-metal riscv64 M-mode test entry for the least-privilege enforcement demo
// (tests/qemu/proc/privilege_demo.mc) — in PURE MC (no C). The all-MC replacement
// for kernel/arch/riscv64/privilege_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit runs the SAME existing MC demo
// (a forbidden IPC peer is rejected + a kernel call outside the mask is Denied) and
// reports PRIV-OK when the demo returns 1 — writing the bare 16550 UART directly.

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

// The privilege demo (tests/qemu/proc/privilege_demo.mc): a least-privilege IPC
// allow-list + kernel-call gate. Returns 1 when both enforcements held.
extern fn privilege_demo() -> u32;

export fn test_main() -> void {
    uputs("privilege booting\n");
    if privilege_demo() == 1 {
        uputs("PRIV-OK\n");
    } else {
        uputs("PRIV-FAIL\n");
    }
    mc_halt();
}
