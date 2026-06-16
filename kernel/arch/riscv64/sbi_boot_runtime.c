// Boot under OpenSBI — the real RISC-V firmware/bootloader used on physical hardware.
// QEMU's default -bios loads OpenSBI, which initializes the machine and jumps to this
// kernel in S-mode at 0x80200000. We talk to the console + power off through SBI ecalls
// (the real supervisor<->firmware ABI), exactly as on real hardware — not -bios none.
#include <stdint.h>
#include <stddef.h>

// Legacy SBI calls (EID in a7): console putchar = 1, shutdown = 8.
static void sbi_putchar(char c) {
    register long a0 __asm__("a0") = (unsigned char)c;
    register long a7 __asm__("a7") = 1;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
}
static void sbi_puts(const char *s) { for (; *s; ++s) sbi_putchar(*s); }
static void sbi_shutdown(void) {
    register long a7 __asm__("a7") = 8;
    __asm__ volatile("ecall" : : "r"(a7) : "memory");
}

uint32_t arch_compute(uint32_t x); // MC, running in S-mode under OpenSBI

__attribute__((used)) void s_entry(void) {
    sbi_puts("kernel up in S-mode under OpenSBI\n");
    if (arch_compute(10) == 91) sbi_puts("SBI-BOOT-OK\n");
    else sbi_puts("SBI-BOOT-BAD\n");
    sbi_shutdown();
    for (;;) {}
}

// OpenSBI enters here in S-mode (a0=hartid, a1=dtb).
__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call s_entry\n"
        "1: j 1b\n");
}
