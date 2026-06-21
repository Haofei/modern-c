// Plan item R6 / first-class UART console driver — in PURE MC (no C runtime).
//
// Boot under REAL OpenSBI (QEMU default firmware) in S-mode, PRESERVING OpenSBI's
// a0/a1 (hartid, dtb physaddr). We then:
//   1. ask the arch-neutral BootInfo contract (kernel/core/bootinfo.mc) to discover
//      the UART MMIO base FROM THE DEVICE TREE (bootinfo_console_pa) — never a
//      hardcoded constant;
//   2. drive the first-class NS16550 driver (kernel/drivers/uart/ns16550.mc) at that
//      discovered base: init (8N1 + FIFOs + no-IRQ), then emit the proof bytes
//      LSR-polled through the driver.
//
// The startup banner uses the SBI console putchar (firmware path) ONLY to announce
// we are alive; the PROOF line "UART-DRIVER-OK" and the discovered "UART base=0x..."
// come out THROUGH the FDT-discovered base + LSR-polled driver. That is the gate's
// assertion.

import "kernel/core/bootinfo.mc";
import "kernel/drivers/uart/ns16550.mc";
import "kernel/arch/riscv64/sbi.mc";
import "std/addr.mc";

// Discover the UART MMIO base from the firmware device tree (NOT hardcoded).
fn uart_demo_discover(dtb: usize, hartid: u64) -> u64 {
    return bootinfo_console_pa(pa(dtb), hartid);
}

// Emit a NUL-terminated string literal through the first-class driver, byte by byte
// (LSR-polled). MC can't index a string literal as *const u8, so we walk it through
// raw.load — the same idiom sbi_puts uses for the firmware console.
fn uart_puts(u: *Ns16550, s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(pa(base + i)); }
        if b == 0 {
            break;
        }
        ns16550_putc(u, b);
        i = i + 1;
    }
}

fn s_entry_body(hartid: u64, dtb: u64) -> void {
    sbi_puts("kernel up in S-mode under OpenSBI (NS16550 first-class UART driver)\n");

    // 1. Discover the UART base from the firmware device tree (NOT hardcoded).
    let base: u64 = uart_demo_discover(dtb as usize, hartid);

    if base == 0 {
        // Fail-closed: no UART in the device tree. Report via firmware and stop.
        sbi_puts("UART-DRIVER-BAD (no console node in FDT)\n");
        sbi_shutdown();
        while true {}
    }

    // 2. Bring up the discovered UART and drive the proof bytes through it.
    var u: Ns16550 = ns16550_at(base as usize);
    ns16550_init(&u);
    uart_puts(&u, "UART base=");
    ns16550_puthex64(&u, base);
    ns16550_putc(&u, 10); // '\n'
    uart_puts(&u, "UART-DRIVER-OK\n");

    sbi_shutdown();
    while true {}
}

// OpenSBI enters here in S-mode with a0=hartid, a1=dtb. The naked _start sets the
// stack and tail-calls s_entry WITHOUT clobbering a0/a1, so s_entry receives them.
export fn s_entry(hartid: u64, dtb: u64) -> void {
    s_entry_body(hartid, dtb);
}

#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
