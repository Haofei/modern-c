// Minimal aarch64 (ARM64) bring-up for QEMU 'virt': set a stack, print via the PL011
// UART at 0x09000000, run an MC computation, and report — proving MC code runs on a
// second architecture (the kernel's arch layer is isolated under kernel/arch/<arch>).
#include <stdint.h>
#define PL011 ((volatile uint32_t *)0x09000000UL)
static void putc_(char c) { *PL011 = (uint32_t)(unsigned char)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }

uint32_t arch_compute(uint32_t x); // MC, compiled for aarch64

__attribute__((used)) void cmain(void) {
    puts_("aarch64 booting\n");
    // sum(0..9)=45; *2+1 = 91
    if (arch_compute(10) == 91) puts_("ARM64-OK\n");
    else puts_("ARM64-BAD\n");
    for (;;) {}
}

__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "ldr x1, =_stack_top\n"
        "mov sp, x1\n"
        "bl cmain\n"
        "1: b 1b\n");
}
