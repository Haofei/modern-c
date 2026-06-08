// Runtime for the per-process-address-space scheduler. M-mode builds the process
// table + page tables (MC sched_vm_setup), drops to S-mode, activates the kernel
// map, and runs the scheduler — whose context switch (mc_switch_context_vm) loads
// each process's satp. Provides the context-switch primitives (incl. the vm-aware
// one) the scheduler calls.
#include <stdint.h>
#include <stddef.h>

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

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }

typedef struct {
    uint64_t ra, sp, s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
} Context;

// Plain context switch (referenced by proc_yield/proc_exit; unused in this demo).
__attribute__((naked)) void mc_switch_context(Context *old, Context *next) {
    __asm__ volatile(
        "sd ra,0(a0)\n sd sp,8(a0)\n sd s0,16(a0)\n sd s1,24(a0)\n sd s2,32(a0)\n"
        "sd s3,40(a0)\n sd s4,48(a0)\n sd s5,56(a0)\n sd s6,64(a0)\n sd s7,72(a0)\n"
        "sd s8,80(a0)\n sd s9,88(a0)\n sd s10,96(a0)\n sd s11,104(a0)\n"
        "ld ra,0(a1)\n ld sp,8(a1)\n ld s0,16(a1)\n ld s1,24(a1)\n ld s2,32(a1)\n"
        "ld s3,40(a1)\n ld s4,48(a1)\n ld s5,56(a1)\n ld s6,64(a1)\n ld s7,72(a1)\n"
        "ld s8,80(a1)\n ld s9,88(a1)\n ld s10,96(a1)\n ld s11,104(a1)\n ret\n");
}

// Context switch that also swaps the address space (satp in a2).
__attribute__((naked)) void mc_switch_context_vm(Context *old, Context *next, uint64_t new_satp) {
    __asm__ volatile(
        "sd ra,0(a0)\n sd sp,8(a0)\n sd s0,16(a0)\n sd s1,24(a0)\n sd s2,32(a0)\n"
        "sd s3,40(a0)\n sd s4,48(a0)\n sd s5,56(a0)\n sd s6,64(a0)\n sd s7,72(a0)\n"
        "sd s8,80(a0)\n sd s9,88(a0)\n sd s10,96(a0)\n sd s11,104(a0)\n"
        "csrw satp, a2\n sfence.vma\n"
        "ld ra,0(a1)\n ld sp,8(a1)\n ld s0,16(a1)\n ld s1,24(a1)\n ld s2,32(a1)\n"
        "ld s3,40(a1)\n ld s4,48(a1)\n ld s5,56(a1)\n ld s6,64(a1)\n ld s7,72(a1)\n"
        "ld s8,80(a1)\n ld s9,88(a1)\n ld s10,96(a1)\n ld s11,104(a1)\n ret\n");
}

__attribute__((naked)) static void trampoline(void) { __asm__ volatile("jr s0\n"); }
void mc_thread_init(Context *ctx, uintptr_t stack_top, void (*entry)(void)) {
    uint64_t *s = (uint64_t *)ctx;
    for (int i = 0; i < 14; i++) s[i] = 0;
    ctx->ra = (uint64_t)(uintptr_t)&trampoline;
    ctx->s0 = (uint64_t)(uintptr_t)entry;
    ctx->sp = (uint64_t)stack_top;
}

void     sched_vm_setup(uintptr_t region, uintptr_t len);
uint64_t sched_vm_kernel_satp(void);
uint32_t sched_vm_run(void);

__attribute__((aligned(4096))) static uint8_t heap_region[512 * 1024];

__attribute__((used)) void s_main(void) {
    uint64_t ks = sched_vm_kernel_satp();
    __asm__ volatile("csrw satp, %0\n sfence.vma\n" ::"r"(ks) : "memory");
    if (sched_vm_run() == 1) puts_("SCHED-VM-OK\n");
    else puts_("SCHED-VM-BAD\n");
    *FINISHER = 0x5555;
    for (;;) {}
}

__attribute__((used)) void m_main(void) {
    puts_("sched-vm booting (M-mode)\n");
    sched_vm_setup((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("processes + page tables built, dropping to S-mode\n");
    __asm__ volatile(
        "li t0, 0xffff\n csrw medeleg, t0\n csrw mideleg, t0\n"
        "li t0, -1\n csrw pmpaddr0, t0\n li t0, 0x1f\n csrw pmpcfg0, t0\n"
        "li t0, 0x1800\n csrc mstatus, t0\n li t0, 0x800\n csrs mstatus, t0\n"
        "csrw mepc, %0\n mret\n"
        ::"r"(&s_main) : "t0", "memory");
    for (;;) {}
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile("la sp, _stack_top\n call m_main\n 1: j 1b\n");
}
