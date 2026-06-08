// Shared bring-up runtime for the context-switch demos: the callee-saved register
// save/restore (arch asm), thread priming, a minimal UART, and the entry path.
// The typed surface (Context, mc_switch_context, mc_thread_init) is declared in
// kernel/arch/riscv64/context.mc; each test provides its own `test_main`.
#include <stdint.h>

#define UART_THR ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)

void putc_(char c) { *UART_THR = (uint8_t)c; }
void puts_(const char *s) { while (*s) putc_(*s++); }
void mc_halt(void) { *FINISHER = 0x5555; for (;;) {} }

// Must match `struct Context` in context.mc: ra, sp, s0..s11 (14 x u64).
typedef struct {
    uint64_t ra, sp;
    uint64_t s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
} Context;

// Save the current callee-saved registers into *old (a0), load *new (a1), return
// into new's saved ra. Naked: no prologue/epilogue touches the frame.
__attribute__((naked)) void mc_switch_context(Context *old, Context *new) {
    __asm__ volatile(
        "sd ra,  0(a0)\n" "sd sp,  8(a0)\n"
        "sd s0, 16(a0)\n" "sd s1, 24(a0)\n" "sd s2, 32(a0)\n" "sd s3, 40(a0)\n"
        "sd s4, 48(a0)\n" "sd s5, 56(a0)\n" "sd s6, 64(a0)\n" "sd s7, 72(a0)\n"
        "sd s8, 80(a0)\n" "sd s9, 88(a0)\n" "sd s10,96(a0)\n" "sd s11,104(a0)\n"
        "ld ra,  0(a1)\n" "ld sp,  8(a1)\n"
        "ld s0, 16(a1)\n" "ld s1, 24(a1)\n" "ld s2, 32(a1)\n" "ld s3, 40(a1)\n"
        "ld s4, 48(a1)\n" "ld s5, 56(a1)\n" "ld s6, 64(a1)\n" "ld s7, 72(a1)\n"
        "ld s8, 80(a1)\n" "ld s9, 88(a1)\n" "ld s10,96(a1)\n" "ld s11,104(a1)\n"
        "ret\n");
}

// As mc_switch_context, but also load new_satp (a2) into satp + sfence.vma between
// saving and restoring — so a context switch can change the address space. Defined
// here so any test linking process.mc resolves the symbol; the cooperative M-mode
// tests never call it (satp is inert in M-mode), the S-mode scheduler demo does.
__attribute__((naked)) void mc_switch_context_vm(Context *old, Context *next, uint64_t new_satp) {
    __asm__ volatile(
        "sd ra,  0(a0)\n" "sd sp,  8(a0)\n"
        "sd s0, 16(a0)\n" "sd s1, 24(a0)\n" "sd s2, 32(a0)\n" "sd s3, 40(a0)\n"
        "sd s4, 48(a0)\n" "sd s5, 56(a0)\n" "sd s6, 64(a0)\n" "sd s7, 72(a0)\n"
        "sd s8, 80(a0)\n" "sd s9, 88(a0)\n" "sd s10,96(a0)\n" "sd s11,104(a0)\n"
        "csrw satp, a2\n" "sfence.vma\n"
        "ld ra,  0(a1)\n" "ld sp,  8(a1)\n"
        "ld s0, 16(a1)\n" "ld s1, 24(a1)\n" "ld s2, 32(a1)\n" "ld s3, 40(a1)\n"
        "ld s4, 48(a1)\n" "ld s5, 56(a1)\n" "ld s6, 64(a1)\n" "ld s7, 72(a1)\n"
        "ld s8, 80(a1)\n" "ld s9, 88(a1)\n" "ld s10,96(a1)\n" "ld s11,104(a1)\n"
        "ret\n");
}

// Trampoline a fresh thread starts on: enable machine interrupts (so the thread is
// preemptible the moment it begins — it was switched in from inside an interrupt
// handler, where MIE was cleared), then jump to the real entry held in s0. The
// entry never returns. Harmless under cooperative use: no timer is armed there, so
// enabling MIE asserts nothing.
__attribute__((naked)) static void thread_trampoline(void) {
    __asm__ volatile(
        "csrsi mstatus, 8\n" // set MIE (bit 3)
        "jr s0\n");
}

// Prime a fresh context: the first switch into it `ret`s to the trampoline (with
// the entry in s0) on the given stack. Callee-saved registers start zeroed.
void mc_thread_init(Context *ctx, uintptr_t stack_top, void (*entry)(void)) {
    uint64_t *slots = (uint64_t *)ctx;
    for (int i = 0; i < 14; i++) slots[i] = 0;
    ctx->ra = (uint64_t)(uintptr_t)&thread_trampoline;
    ctx->s0 = (uint64_t)(uintptr_t)entry;
    ctx->sp = (uint64_t)stack_top;
}

extern void test_main(void);

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
