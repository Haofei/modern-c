// user/runtime/app_traps — confined-app platform glue, in PURE MC (the all-MC replacement for
// app_traps.c). Provides ONLY the stdio stream DATA symbols that QuickJS's <stdio.h> references
// (stdout/stderr/stdin) — never dereferenced; the all-MC stdio.mc ignores the stream and routes
// output through the SYS_WRITE host hook.
//
// The checked-arithmetic trap edges (mc_trap_*) are intentionally NOT defined here: MC's emit-c
// emits a per-unit `static inline mc_trap_X(){__builtin_trap();}` and emit-llvm a per-object
// `define weak @mc_trap_X(){ llvm.trap }`, so every MC object already self-provides them and calls
// its own copy. The old C file's external weak mc_trap_* were shadowed by those self-stubs (dead),
// so dropping them changes no behavior: a tripped check in a confined U-mode agent still raises a
// trap the kernel catches to reclaim the agent.
export global stdout: usize = 0;
export global stderr: usize = 0;
export global stdin: usize = 0;
