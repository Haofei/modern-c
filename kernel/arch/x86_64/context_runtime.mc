// kernel/arch/x86_64/context_runtime — the x86-64 cooperative context-switch primitives the
// typed surface in kernel/arch/x86_64/context.mc declares (mc_switch_context /
// mc_switch_context_vm / mc_thread_init), in PURE MC.
//
// The MC replacement for kernel/arch/x86_64/context_runtime.c. The switch asm is
// position-independent and touches only the System V callee-saved set, so it runs identically
// on a bare-metal x86 kernel and (for the x86-sched-test gate) natively on an x86-64 host.
//
// The two switch primitives and the first-switch trampoline are `#[naked]`: `#[naked]` emits
// no prologue/epilogue, so on entry the arguments are sitting in their System V registers
// (arg0=rdi, arg1=rsi, arg2=rdx) exactly as the caller left them, and the hand-written asm
// owns the entire calling convention (the same contract proven by tests/exec/naked_run_x86_64.mc
// and used by the riscv sibling in tests/qemu/proc/isolation_runtime.mc). `mc_thread_init` is an
// ordinary fn: it primes a fresh Context by raw.store at the struct's byte offsets — the LLVM
// backend does not support `(*ptr).field = x` on a struct field, and raw stores at byte offsets
// are the portable idiom.
//
// Context layout (must match `struct Context` in context.mc):
//   rsp@0  rbx@8  rbp@16  r12@24  r13@32  r14@40  r15@48.

import "kernel/arch/x86_64/context.mc";

// System V x86-64: arg0=rdi (old), arg1=rsi (new). Save the callee-saved regs + rsp into *old,
// load them from *new, then `ret` — which pops the return address off new's (now current) stack
// and resumes there. Naked: no prologue/epilogue, the asm owns the frame.
#[naked]
export fn mc_switch_context(old: *mut Context, new: *Context) -> void {
    asm opaque volatile {
        "movq %rbx,  8(%rdi)\n movq %rbp, 16(%rdi)\n movq %r12, 24(%rdi)\n movq %r13, 32(%rdi)\n movq %r14, 40(%rdi)\n movq %r15, 48(%rdi)\n movq %rsp,  0(%rdi)\n movq  8(%rsi), %rbx\n movq 16(%rsi), %rbp\n movq 24(%rsi), %r12\n movq 32(%rsi), %r13\n movq 40(%rsi), %r14\n movq 48(%rsi), %r15\n movq  0(%rsi), %rsp\n ret"
    }
}

// As mc_switch_context, but load arg2 (rdx) into CR3 between save and restore, switching the
// address space. Defined so anything linking the typed surface resolves the symbol; the
// cooperative tests never call it (CR3 is privileged), the paged kernel does.
#[naked]
export fn mc_switch_context_vm(old: *mut Context, new: *Context, new_cr3: u64) -> void {
    asm opaque volatile {
        "movq %rbx,  8(%rdi)\n movq %rbp, 16(%rdi)\n movq %r12, 24(%rdi)\n movq %r13, 32(%rdi)\n movq %r14, 40(%rdi)\n movq %r15, 48(%rdi)\n movq %rsp,  0(%rdi)\n movq %rdx, %cr3\n movq  8(%rsi), %rbx\n movq 16(%rsi), %rbp\n movq 24(%rsi), %r12\n movq 32(%rsi), %r13\n movq 40(%rsi), %r14\n movq 48(%rsi), %r15\n movq  0(%rsi), %rsp\n ret"
    }
}

// A fresh thread's first `ret` lands here, with the real entry held in r12 (a callee-saved reg
// primed by mc_thread_init, restored by mc_switch_context). `call` (not `jmp`) keeps the System
// V 16-byte stack alignment for `entry`. The entry never returns; if it does, spin.
#[naked]
#[noinline]
fn thread_trampoline() -> void {
    asm opaque volatile {
        "call *%r12\n 1: jmp 1b"
    }
}

// Prime a fresh context: lay the trampoline address at the top of the stack so the first `ret`
// into this context jumps to it, with `entry` in r12. 16-byte align the stack so the
// trampoline's `call entry` leaves entry's stack at the ABI-required (rsp % 16 == 8).
export fn mc_thread_init(ctx: *mut Context, stack_top: usize, entry: fn() -> void) -> void {
    let top: usize = stack_top & 0xFFFFFFFFFFFFFFF0; // 16-byte align
    let sp: usize = top - 8;
    let base: usize = ctx as usize;
    let tramp: usize = (&thread_trampoline) as usize;
    unsafe {
        raw.store<u64>(phys(sp), tramp as u64);                  // popped by the first `ret`
        raw.store<u64>(phys(base + 0), sp as u64);               // rsp
        raw.store<u64>(phys(base + 8), 0);                       // rbx
        raw.store<u64>(phys(base + 16), 0);                      // rbp
        raw.store<u64>(phys(base + 24), entry as usize as u64);  // r12 = the entry the trampoline calls
        raw.store<u64>(phys(base + 32), 0);                      // r13
        raw.store<u64>(phys(base + 40), 0);                      // r14
        raw.store<u64>(phys(base + 48), 0);                      // r15
    }
}
