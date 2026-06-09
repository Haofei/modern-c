// kernel/arch/x86_64/context — cooperative context switching for x86-64.
//
// The x86-64 sibling of kernel/arch/riscv64/context. A `Context` holds the System V
// callee-saved registers (rbx, rbp, r12-r15) plus the stack pointer; the return address
// lives at the top of the saved stack (popped by `ret`). The save/restore asm and thread
// priming live in the runtime; the typed surface is here, with the same extern contract as
// riscv64 so the portable kernel (process.mc / sched.mc) can target either arch by import.

struct Context {
    rsp: u64, // saved stack pointer (the return address is at [rsp])
    rbx: u64,
    rbp: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
}

// Save the current callee-saved registers + rsp into `old`, load `new`'s, and resume `new`
// (its `ret` returns wherever it last switched out). Returns to this caller when something
// later switches back to `old`.
extern fn mc_switch_context(old: *mut Context, new: *Context) -> void;

// Like mc_switch_context, but also load `new_cr3` into CR3 (the x86 page-table base, the
// analogue of riscv `satp`) between saving and restoring — so a context switch changes the
// active address space. Only valid with paging on in a privileged context.
extern fn mc_switch_context_vm(old: *mut Context, new: *Context, new_cr3: u64) -> void;

// Prime `ctx` so the first switch into it starts running `entry` on the stack whose top is
// `stack_top`. `entry` is an ordinary `fn() -> void`; the runtime sets the initial rsp +
// trampoline so the first `ret` lands in `entry` with a correctly-aligned stack.
extern fn mc_thread_init(ctx: *mut Context, stack_top: usize, entry: fn() -> void) -> void;
