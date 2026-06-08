// kernel/arch/riscv64/context — cooperative context switching.
//
// A `Context` holds the callee-saved register set (ra, sp, s0-s11).
// `mc_switch_context` saves the current registers into `old` and loads `new`'s, so
// execution resumes wherever `new` last switched out. A fresh context is primed by
// `mc_thread_init` with an entry point (a function pointer) so the first switch
// into it begins executing the entry on its own stack. Arch-specific: the register
// set and the save/restore asm live in the runtime; the typed surface is here.

struct Context {
    ra: u64,
    sp: u64,
    s0: u64,
    s1: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
}

// Save the current callee-saved registers into `old`, load `new`'s, and resume
// `new`. Returns to this caller when another context later switches back to `old`.
extern fn mc_switch_context(old: *mut Context, new: *Context) -> void;

// Like `mc_switch_context`, but also switch the address space: load `new_satp` into
// `satp` (+ `sfence.vma`) between saving the old registers and loading the new ones,
// so a context switch changes the active page table. Only valid when paging is on
// (S-mode).
extern fn mc_switch_context_vm(old: *mut Context, new: *Context, new_satp: u64) -> void;

// Prime `ctx` so the first switch into it starts running `entry` on the stack
// whose top is `stack_top`. The entry is an ordinary `fn() -> void` value (a
// function pointer) — no raw addresses in the kernel; the runtime sets the initial
// `ra`/`sp` from the typed inputs.
extern fn mc_thread_init(ctx: *mut Context, stack_top: usize, entry: fn() -> void) -> void;
