// kernel/core/panic — fail closed with diagnostics.
//
// Called for any trap the kernel does not handle. Prints the cause, faulting PC,
// and trap value to the debug console, then halts the machine — so an unexpected
// fault never silently `mret`s (which, for a synchronous fault, would re-execute
// the faulting instruction forever).

import "console.mc";

// Platform primitive: stop the machine (on QEMU, the test finisher). Halting is a
// platform action, like the UART; the diagnostics above it are pure MC.
extern fn mc_halt() -> void;

export fn panic_trap(mcause: u64, mepc: u64, mtval: u64) -> void {
    // "PANIC c=<mcause> p=<mepc> v=<mtval>"
    console_putc('P');
    console_putc('A');
    console_putc('N');
    console_putc('I');
    console_putc('C');
    console_putc(' ');
    console_putc('c');
    console_putc('=');
    console_puthex64(mcause);
    console_putc(' ');
    console_putc('p');
    console_putc('=');
    console_puthex64(mepc);
    console_putc(' ');
    console_putc('v');
    console_putc('=');
    console_puthex64(mtval);
    console_newline();
    mc_halt();
}
