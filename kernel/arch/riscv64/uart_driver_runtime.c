// Plan item R6 / first-class UART console driver. Boot under OpenSBI (real RISC-V
// firmware) in S-mode, PRESERVING OpenSBI's a0/a1 (hartid, dtb physaddr). We then:
//   1. ask the arch-neutral BootInfo contract (kernel/core/bootinfo.mc) to discover
//      the UART MMIO base FROM THE DEVICE TREE (uart_demo_discover -> bootinfo_console_pa)
//      — never a hardcoded constant;
//   2. drive the first-class NS16550 driver (kernel/drivers/uart/ns16550.mc) at that
//      discovered base: init (8N1 + FIFOs + no-IRQ), then emit the proof bytes
//      LSR-polled through the driver.
//
// The startup banner uses SBI console putchar (firmware path) ONLY to announce we
// are alive; the PROOF line "UART-DRIVER-OK" and the discovered "UART base=0x..."
// come out via uart_demo_putc — i.e. through the FDT-discovered base + LSR-polled
// driver. That is the gate's assertion.
//
// The minimal SBI wrapper is copied here (as in the bootinfo_runtime.c sibling) so
// the M1 boot file stays untouched.
#include <stdint.h>
#include <stddef.h>

static long sbi_ecall(long ext, long fid, long arg0, long arg1) {
    register long a0 __asm__("a0") = arg0;
    register long a1 __asm__("a1") = arg1;
    register long a6 __asm__("a6") = fid;
    register long a7 __asm__("a7") = ext;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a6), "r"(a7) : "memory");
    return a0;
}

// Legacy SBI: console putchar = EID 1, shutdown = EID 8 (fid unused for legacy).
static void sbi_putchar(char c) { sbi_ecall(1, 0, (unsigned char)c, 0); }
static void sbi_puts(const char *s) { for (; *s; ++s) sbi_putchar(*s); }
static void sbi_shutdown(void) { sbi_ecall(8, 0, 0, 0); }

// MC entry points (tests/qemu/arch/uart_driver_demo.mc). dtb is a plain uint64_t
// across the C ABI; the MC side wraps it into a PAddr. The driver is driven through
// stateless per-call ops keyed by the discovered base, so the C side never sees MC
// struct layout.
uint64_t uart_demo_discover(uint64_t dtb, uint64_t hartid);
void     uart_demo_init(uint64_t base);
void     uart_demo_putc(uint64_t base, uint8_t c);
void     uart_demo_puthex64(uint64_t base, uint64_t v);

// Emit a C string literal through the first-class driver, byte by byte. This is
// the string-emit idiom: MC can't index a string literal as *const u8, so the C
// runtime loops over its own literal calling the per-byte driver op.
static void uart_puts(uint64_t base, const char *s) {
    for (; *s; ++s) uart_demo_putc(base, (uint8_t)*s);
}

__attribute__((used)) void s_entry(uint64_t hartid, uint64_t dtb) {
    sbi_puts("kernel up in S-mode under OpenSBI (NS16550 first-class UART driver)\n");

    // 1. Discover the UART base from the firmware device tree (NOT hardcoded).
    uint64_t base = uart_demo_discover(dtb, hartid);

    if (base == 0) {
        // Fail-closed: no UART in the device tree. Report via firmware and stop.
        sbi_puts("UART-DRIVER-BAD (no console node in FDT)\n");
        sbi_shutdown();
        for (;;) {}
    }

    // 2. Bring up the discovered UART and drive the proof bytes through it.
    uart_demo_init(base);
    uart_puts(base, "UART base=");
    uart_demo_puthex64(base, base);
    uart_demo_putc(base, '\n');
    uart_puts(base, "UART-DRIVER-OK\n");

    sbi_shutdown();
    for (;;) {}
}

// OpenSBI enters here in S-mode with a0=hartid, a1=dtb. Set the stack but DO NOT
// clobber a0/a1 before the call, so s_entry receives them as its arguments.
__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call s_entry\n"
        "1: j 1b\n");
}
