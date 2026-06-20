// Bare-metal riscv64 runtime for the QuickJS agent bring-up. Provides the platform layer the
// engine + all-MC libc need: the console/syscall hooks (-> UART), the stdio stream objects, FP
// enablement (QuickJS computes on doubles), and the entry that calls the agent's main(). This is
// the platform glue (the analogue of crt0 + the syscall shim), distinct from the all-MC libc.
#include <stdint.h>
#include <stddef.h>

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)

// Console hook used by stdio.mc (printf family), and the write syscall used by the agent.
void mc_console_write(uintptr_t buf, uintptr_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    for (uintptr_t i = 0; i < len; i++) *UART = p[i];
}
long sys_write(unsigned long fd, const void *buf, unsigned long len) {
    (void)fd;
    const uint8_t *p = (const uint8_t *)buf;
    for (unsigned long i = 0; i < len; i++) *UART = p[i];
    return (long)len;
}

// stdio stream objects: QuickJS passes these to fprintf, which (in stdio.mc) ignores the stream.
void *stdout = 0;
void *stderr = 0;
void *stdin = 0;

// Trap stubs for the MC checked-arithmetic edges (heap overflow guard, etc.).
__attribute__((weak)) void mc_trap_IntegerOverflow(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Bounds(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_DivideByZero(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_InvalidShift(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_InvalidRepresentation(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Assert(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_NullUnwrap(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Unreachable(void) { *FINISHER = 0x3333; for (;;) {} }

extern int main(void);

__attribute__((used)) void boot_main(void) {
    mc_console_write((uintptr_t) "qjs: booting agent\n", 19);
    int rc = main();
    if (rc == 0) mc_console_write((uintptr_t) "qjs: agent exited 0\n", 20);
    else mc_console_write((uintptr_t) "qjs: agent exited nonzero\n", 26);
    *FINISHER = 0x5555;
    for (;;) {
    }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "li t0, 0x2000\n"    // mstatus.FS = Initial (enable the FPU; JS numbers are doubles)
        "csrs mstatus, t0\n"
        "call boot_main\n"
        "1: j 1b\n");
}
