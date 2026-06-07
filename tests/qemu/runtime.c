// Minimal bare-metal riscv64 runtime for the QEMU MMIO execution test.
// Sets up a stack, drives the MC-generated `uart_putc` over the 16550 UART,
// then exits QEMU through the SiFive test finisher.
#include <stdint.h>

// `Uart16550` is defined in the MC-generated translation unit; we only pass a
// pointer to it, so an incomplete type is sufficient here.
typedef struct Uart16550 Uart16550;
void uart_putc(volatile Uart16550 *uart, unsigned char ch);

#define UART ((volatile Uart16550 *)0x10000000UL)        // QEMU virt 16550
#define FINISHER ((volatile uint32_t *)0x00100000UL)      // SiFive test device

// External linkage + `used` so the optimizer keeps it: the only reference is
// the `call test_main` in the `_start` inline asm, which -Wunused cannot see.
__attribute__((used)) void test_main(void) {
    const char *msg = "MMIO-OK\n";
    for (const char *p = msg; *p != '\0'; ++p) {
        uart_putc(UART, (unsigned char)*p);
    }
    *FINISHER = 0x5555; // exit QEMU with status 0
    for (;;) {
    }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
