// x86-64 cooperative context-switch runtime — the arch primitives the typed surface in
// kernel/arch/x86_64/context.mc declares (mc_switch_context / mc_switch_context_vm /
// mc_thread_init), in real x86-64 assembly. The context-switch asm is position-independent
// and uses only the System V callee-saved set, so it runs identically on a bare-metal x86
// kernel and (for testing) natively on an x86-64 host.
#include <stdint.h>

// Must match `struct Context` in context.mc: rsp, rbx, rbp, r12, r13, r14, r15.
// Offsets: rsp@0 rbx@8 rbp@16 r12@24 r13@32 r14@40 r15@48.
typedef struct {
    uint64_t rsp, rbx, rbp, r12, r13, r14, r15;
} Context;

// System V x86-64: arg0=rdi (old), arg1=rsi (new). Save callee-saved regs + rsp into *old,
// load them from *new, then `ret` — which pops the return address off new's (now current)
// stack and resumes there. Naked: no prologue/epilogue, the asm owns the frame.
__attribute__((naked)) void mc_switch_context(Context *old, Context *next) {
    __asm__ volatile(
        "movq %rbx,  8(%rdi)\n"
        "movq %rbp, 16(%rdi)\n"
        "movq %r12, 24(%rdi)\n"
        "movq %r13, 32(%rdi)\n"
        "movq %r14, 40(%rdi)\n"
        "movq %r15, 48(%rdi)\n"
        "movq %rsp,  0(%rdi)\n"
        "movq  8(%rsi), %rbx\n"
        "movq 16(%rsi), %rbp\n"
        "movq 24(%rsi), %r12\n"
        "movq 32(%rsi), %r13\n"
        "movq 40(%rsi), %r14\n"
        "movq 48(%rsi), %r15\n"
        "movq  0(%rsi), %rsp\n"
        "ret\n");
}

// As mc_switch_context, but load arg2 (rdx) into CR3 between save and restore, switching the
// address space. Defined so anything linking the typed surface resolves the symbol; the
// cooperative tests never call it (CR3 is privileged), the paged kernel does.
__attribute__((naked)) void mc_switch_context_vm(Context *old, Context *next, uint64_t new_cr3) {
    __asm__ volatile(
        "movq %rbx,  8(%rdi)\n"
        "movq %rbp, 16(%rdi)\n"
        "movq %r12, 24(%rdi)\n"
        "movq %r13, 32(%rdi)\n"
        "movq %r14, 40(%rdi)\n"
        "movq %r15, 48(%rdi)\n"
        "movq %rsp,  0(%rdi)\n"
        "movq %rdx, %cr3\n"
        "movq  8(%rsi), %rbx\n"
        "movq 16(%rsi), %rbp\n"
        "movq 24(%rsi), %r12\n"
        "movq 32(%rsi), %r13\n"
        "movq 40(%rsi), %r14\n"
        "movq 48(%rsi), %r15\n"
        "movq  0(%rsi), %rsp\n"
        "ret\n");
}

// A fresh thread's first `ret` lands here, with the real entry held in r12 (a callee-saved
// reg primed by mc_thread_init, restored by mc_switch_context). `call` (not `jmp`) keeps the
// System V 16-byte stack alignment for `entry`. The entry never returns; if it does, spin.
__attribute__((naked)) static void thread_trampoline(void) {
    __asm__ volatile(
        "call *%r12\n"
        "1: jmp 1b\n");
}

// Prime a fresh context: lay the trampoline address at the top of the stack so the first
// `ret` into this context jumps to it, with `entry` in r12. 16-byte align the stack so the
// trampoline's `call entry` leaves entry's stack at the ABI-required (rsp % 16 == 8).
void mc_thread_init(Context *ctx, uintptr_t stack_top, void (*entry)(void)) {
    uintptr_t top = stack_top & ~(uintptr_t)0xF; // 16-byte align
    uint64_t *sp = (uint64_t *)(top - 8);
    *sp = (uint64_t)(uintptr_t)&thread_trampoline; // popped by the first `ret`
    ctx->rsp = (uint64_t)(uintptr_t)sp;
    ctx->r12 = (uint64_t)(uintptr_t)entry; // the trampoline calls this
    ctx->rbx = 0;
    ctx->rbp = 0;
    ctx->r13 = 0;
    ctx->r14 = 0;
    ctx->r15 = 0;
}
