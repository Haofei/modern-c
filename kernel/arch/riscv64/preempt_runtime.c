// Test entry + timer/trap wiring for the preemptive scheduler demo
// (tests/qemu/preempt_demo.mc). The context-switch primitive, thread priming,
// UART, and `_start` live in context_runtime.c. Here: the CLINT timer, the
// full-frame trap vector that drives preemption, and `test_main`.
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

#define CLINT_MTIME    ((volatile uint64_t *)0x0200BFF8UL)
#define CLINT_MTIMECMP ((volatile uint64_t *)0x02004000UL)
#define TICK_INTERVAL  1000000ULL // ~0.1s at the 10MHz virt timebase
#define MCAUSE_M_TIMER 0x8000000000000007ULL

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

// MC entry points (tests/qemu/preempt_demo.mc).
void timer_preempt(void);
uint32_t preempt_demo(uintptr_t region_base, uintptr_t region_len);

void mc_timer_rearm(void) {
    *CLINT_MTIMECMP = *CLINT_MTIME + TICK_INTERVAL;
}

// Dispatcher invoked by the trap vector once the interrupted frame is saved. Only
// the machine timer is configured; anything else fails closed (halts).
__attribute__((used)) void trap_entry(void) {
    uint64_t mcause;
    __asm__ volatile("csrr %0, mcause" : "=r"(mcause));
    if (mcause == MCAUSE_M_TIMER) {
        timer_preempt(); // counts, rearms, and round-robins (may switch threads)
    } else {
        mc_halt();
    }
}

// M-mode trap vector. A timer interrupt arrives at an arbitrary instruction, so the
// full integer frame is saved before dispatch and restored after (on resume —
// `trap_entry` may switch to another thread and only return when this thread is
// scheduled again).
__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile(
        "addi sp, sp, -256\n"
        "sd ra,  0(sp)\n"  "sd t0,  8(sp)\n"  "sd t1, 16(sp)\n"  "sd t2, 24(sp)\n"
        "sd t3, 32(sp)\n"  "sd t4, 40(sp)\n"  "sd t5, 48(sp)\n"  "sd t6, 56(sp)\n"
        "sd a0, 64(sp)\n"  "sd a1, 72(sp)\n"  "sd a2, 80(sp)\n"  "sd a3, 88(sp)\n"
        "sd a4, 96(sp)\n"  "sd a5,104(sp)\n"  "sd a6,112(sp)\n"  "sd a7,120(sp)\n"
        "sd s0,128(sp)\n"  "sd s1,136(sp)\n"  "sd s2,144(sp)\n"  "sd s3,152(sp)\n"
        "sd s4,160(sp)\n"  "sd s5,168(sp)\n"  "sd s6,176(sp)\n"  "sd s7,184(sp)\n"
        "sd s8,192(sp)\n"  "sd s9,200(sp)\n"  "sd s10,208(sp)\n" "sd s11,216(sp)\n"
        // mepc/mstatus are global CSRs, but a context switch inside trap_entry can
        // resume a *different* thread that is itself mid-trap; save them per-frame
        // and restore before mret so each thread returns to its own PC/state.
        "csrr t0, mepc\n"    "sd t0, 224(sp)\n"
        "csrr t0, mstatus\n" "sd t0, 232(sp)\n"
        "call trap_entry\n"
        "ld t0, 224(sp)\n"   "csrw mepc, t0\n"
        "ld t0, 232(sp)\n"   "csrw mstatus, t0\n"
        "ld ra,  0(sp)\n"  "ld t0,  8(sp)\n"  "ld t1, 16(sp)\n"  "ld t2, 24(sp)\n"
        "ld t3, 32(sp)\n"  "ld t4, 40(sp)\n"  "ld t5, 48(sp)\n"  "ld t6, 56(sp)\n"
        "ld a0, 64(sp)\n"  "ld a1, 72(sp)\n"  "ld a2, 80(sp)\n"  "ld a3, 88(sp)\n"
        "ld a4, 96(sp)\n"  "ld a5,104(sp)\n"  "ld a6,112(sp)\n"  "ld a7,120(sp)\n"
        "ld s0,128(sp)\n"  "ld s1,136(sp)\n"  "ld s2,144(sp)\n"  "ld s3,152(sp)\n"
        "ld s4,160(sp)\n"  "ld s5,168(sp)\n"  "ld s6,176(sp)\n"  "ld s7,184(sp)\n"
        "ld s8,192(sp)\n"  "ld s9,200(sp)\n"  "ld s10,208(sp)\n" "ld s11,216(sp)\n"
        "addi sp, sp, 256\n"
        "mret\n");
}

// Install the trap vector, arm the first tick, and enable machine timer interrupts.
void mc_timer_start(void) {
    __asm__ volatile("csrw mtvec, %0" ::"r"(&trap_vector));
    mc_timer_rearm();
    __asm__ volatile("csrs mie, %0" ::"r"((uintptr_t)(1u << 7)));     // MTIE
    __asm__ volatile("csrs mstatus, %0" ::"r"((uintptr_t)(1u << 3))); // MIE
}

// Backing store for the kernel heap (thread stacks).
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

__attribute__((used)) void test_main(void) {
    puts_("preempt booting\n");
    uint32_t ticks = preempt_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("\nPREEMPT-OK ");
    putc_((char)('0' + ((ticks / 10) % 10)));
    putc_((char)('0' + (ticks % 10)));
    putc_('\n');
    mc_halt();
}
