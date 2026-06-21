// Stub definitions of the per-process context-switch primitives, in PURE MC. The
// all-MC replacement for the stubs the C vmspace_runtime.c carried.
//
// kernel/core/process.mc (imported by the vmspace demo) references mc_thread_init /
// mc_switch_context / mc_switch_context_vm through `extern fn` declarations in
// kernel/arch/riscv64/context.mc, for proc_spawn/yield/exit. The vmspace demo only
// uses proc_table_init/proc_set_satp/proc_satp, so those three are never called — but
// the demo object still imports their declarations, so a definition must exist at link
// time. This unit supplies trivial stubs so the image links; real per-process context
// switching is covered by the process test, not this one.
//
// These DEFINE symbols that context.mc declares `extern fn`, so per MC's
// E_DUPLICATE_DECLARATION rule this lives in its own import-free compilation unit. The
// parameters are typed as raw pointers / usize to match the C ABI (every operand is a
// pointer- or word-sized register); the bodies do nothing.

export fn mc_thread_init(ctx: *mut u8, stack_top: usize, entry: usize) -> void {
}

export fn mc_switch_context(old: *mut u8, next: *mut u8) -> void {
}

export fn mc_switch_context_vm(old: *mut u8, next: *mut u8, new_satp: u64) -> void {
}
