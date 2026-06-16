// SMP bring-up runtime. On QEMU `virt -bios none`, every hart starts at the kernel
// entry; each reads its mhartid, takes its own stack, and calls hart_main. The boot
// hart (0) waits until all harts have checked in (via the MC shared atomic) and
// reports, then halts the machine.
#include <stdint.h>
#include <stddef.h>

// Freestanding mem* for bare-metal link: heap/Process struct growth made the
// backend emit memset/memcpy for large aggregate init/copy (e.g. heap_new,
// process_demo). Verbatim from kmain_runtime.c; memmove added for safety.
void *memset(void *d, int c, size_t n) {
    uint8_t *p = (uint8_t *)d;
    for (size_t i = 0; i < n; ++i) p[i] = (uint8_t)c;
    return d;
}
void *memcpy(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    for (size_t i = 0; i < n; ++i) dp[i] = sp[i];
    return d;
}
void *memmove(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    if (dp < sp) { for (size_t i = 0; i < n; ++i) dp[i] = sp[i]; }
    else { for (size_t i = n; i > 0; --i) dp[i-1] = sp[i-1]; }
    return d;
}

#define NHARTS 2
#define HSTACK 4096

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)

static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }

// MC entry points (tests/qemu/smp_demo.mc).
uint32_t smp_hart_arrive(void);
uint32_t smp_count(void);

// External linkage + `used`: the only reference is from `_start`'s inline asm, which
// the C front end cannot see, so it must not be dead-stripped.
__attribute__((aligned(16), used)) uint8_t hart_stacks[NHARTS][HSTACK];

__attribute__((used)) void hart_main(uint64_t hartid) {
    smp_hart_arrive(); // atomically count this hart in
    if (hartid == 0) {
        while (smp_count() < NHARTS) {} // wait for every hart to arrive
        puts_("SMP-OK ");
        putc_((char)('0' + (smp_count() % 10)));
        putc_('\n');
        *FINISHER = 0x5555;
    }
    for (;;) { __asm__ volatile("wfi"); }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "csrr a0, mhartid\n"   // a0 = hart id (and the hart_main argument)
        "la   t0, hart_stacks\n"
        "li   t1, 4096\n"      // HSTACK
        "addi t2, a0, 1\n"     // hartid + 1
        "mul  t2, t2, t1\n"    // (hartid + 1) * HSTACK
        "add  sp, t0, t2\n"    // sp = top of this hart's stack
        "call hart_main\n"
        "1: wfi\n"
        "j 1b\n");
}
