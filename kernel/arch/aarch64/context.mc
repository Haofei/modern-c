// kernel/arch/aarch64/context — cooperative context switching for AArch64.
//
// The AArch64 sibling of kernel/arch/riscv64/context (and kernel/arch/x86_64/context).
// A `Context` holds the AAPCS64 callee-saved register set — x19-x28, the frame pointer
// (x29) and link register (x30, the return address) — plus the stack pointer. The
// save/restore asm and thread priming live in the runtime; the typed surface is here,
// with the SAME extern contract as riscv64/x86_64 so the portable kernel
// (process.mc / sched.mc) targets any arch by importing `kernel/arch/active/context.mc`.

struct Context {
    sp: u64,  // saved stack pointer
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    x28: u64,
    fp: u64,  // x29 (frame pointer)
    lr: u64,  // x30 (link register / return address)
}

// Save the current callee-saved registers into `old`, load `new`'s, and resume `new`.
// Returns to this caller when another context later switches back to `old`.
extern fn mc_switch_context(old: *mut Context, new: *Context) -> void;

// Like `mc_switch_context`, but also switch the address space: load `new_ttbr0` into
// `TTBR0_EL1` (the AArch64 user page-table base, the analogue of riscv `satp` / x86 `cr3`)
// with the required TLB maintenance between saving the old registers and loading the new
// ones, so a context switch changes the active page table. Only valid when paging is on.
extern fn mc_switch_context_vm(old: *mut Context, new: *Context, new_ttbr0: u64) -> void;

// Prime `ctx` so the first switch into it starts running `entry` on the stack whose top is
// `stack_top`. The entry is an ordinary `fn() -> void` value (a function pointer); the
// runtime sets the initial `lr`/`sp` from the typed inputs.
extern fn mc_thread_init(ctx: *mut Context, stack_top: usize, entry: fn() -> void) -> void;
