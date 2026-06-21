// Fixture for the uart-driver gate (plan item R6). The OpenSBI S-mode runtime
// passes the DTB physical address (OpenSBI's a1) and boot hartid (a0) as plain
// integers across the C ABI. Here we:
//   1. normalize the firmware device tree into the arch-neutral BootInfo and pull
//      the console base OUT OF THE DEVICE TREE (bootinfo_console_pa) — never a
//      hardcoded constant;
//   2. drive the first-class NS16550 driver (kernel/drivers/uart/ns16550.mc) at
//      that discovered base, LSR-polled.
//
// The C side never sees MC struct layout: it asks for the discovered base via a
// scalar accessor, then drives the UART through stateless per-call ops keyed by
// that base (each rebuilds the cheap Ns16550 handle). This is the string-emit
// idiom — MC can't index a string literal as *const u8, so the C runtime loops
// over its own C string literals calling uart_demo_putc(base, byte).

import "kernel/core/bootinfo.mc";
import "kernel/drivers/uart/ns16550.mc";
import "std/addr.mc";

// Discover the UART MMIO base from the firmware device tree (NOT hardcoded).
export fn uart_demo_discover(dtb: usize, hartid: u64) -> u64 {
    return bootinfo_console_pa(pa(dtb), hartid);
}

// Initialize the 16550 at the discovered base (8N1, FIFOs, polled/no-IRQ).
export fn uart_demo_init(base: u64) -> void {
    var u: Ns16550 = ns16550_at(base as usize);
    ns16550_init(&u);
}

// Emit one byte through the first-class driver (LSR-polled) at the discovered base.
export fn uart_demo_putc(base: u64, c: u8) -> void {
    var u: Ns16550 = ns16550_at(base as usize);
    ns16550_putc(&u, c);
}

// Emit the discovered base as `0x...` through the driver itself.
export fn uart_demo_puthex64(base: u64, v: u64) -> void {
    var u: Ns16550 = ns16550_at(base as usize);
    ns16550_puthex64(&u, v);
}
