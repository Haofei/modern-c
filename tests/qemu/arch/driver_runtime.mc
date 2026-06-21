// Bare-metal riscv64 M-mode test entry for the driver-framework demo
// (tests/qemu/arch/driver_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/driver_runtime.c: it prints a banner, runs the demo (which
// writes "DRV" through the registered char-device driver), reports the device id,
// and halts.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object): `_start`
// sets the stack and calls `test_main`; `mc_halt` writes the SiFive finisher. This
// unit declares mc_halt `extern fn` and drives the demo exactly as the C did,
// printing over the bare 16550 UART through mmio_console.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c): stop the
// machine via the SiFive test finisher.
extern fn mc_halt() -> void;

// The driver-framework demo (tests/qemu/arch/driver_demo.mc): registers a 16550
// UART as a char device and writes "DRV" through the registry's function-pointer
// vtable, returning the device id.
extern fn driver_demo() -> u32;

export fn test_main() -> void {
    put_str("driver booting\n");
    let id: u32 = driver_demo(); // writes "DRV" through the registered driver
    put_str("\nDRIVER-OK ");
    console_putc((48 + (id % 10)) as u8); // '0' + id%10
    console_putc(10); // '\n'
    mc_halt();
}
