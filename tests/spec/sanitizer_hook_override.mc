// SPEC: section=D2.1
// SPEC: milestone=sanitizer-hook-override
// SPEC: phase=parse,sema,lower-c,lower-ir
// SPEC: expect=pass
// SPEC: check=sanitizer-hook-override-accept

// A pure-MC sanitizer runtime DEFINES a shadow hook itself (`export fn mc_ksan_check`).
// Normally the compiler emits an UNCONDITIONAL weak no-op `define` of every sanitizer hook
// (mc_ksan_check/mc_ksan_store/mc_csan_read/...) into every translation unit, so a linked
// runtime can override it. But when the MODULE ITSELF provides a definition, the auto weak
// stub must YIELD — emitting both would doubly-define the symbol (C `redefinition` / invalid
// LLVM redefinition). This fixture compiles a module that defines mc_ksan_check in MC and the
// shadow logic as a `global` byte array touched through `raw.load`/`raw.store`; both backends
// must accept it (the auto weak stub for mc_ksan_check is suppressed; the others stay).

global shadow: [256]u8;

// The instrumented-access hook the compiler emits before each raw.load/raw.store. A real
// runtime maps `addr` to its shadow byte and traps on a poisoned one; here we just keep the
// signature/storage so the OVERRIDE compiles cleanly beside the still-emitted other hooks.
export fn mc_ksan_check(addr: usize, size: usize) -> void {
    if size == 0 {
        return;
    }
    let idx: usize = addr & 0xFF;
    var b: u8 = 0;
    unsafe { b = raw.load<u8>(phys((&shadow) as usize + idx)); }
    if b != 0 {
        unreachable;
    }
}

// A second hook the module also defines, to prove the suppression is per-symbol.
export fn mc_ksan_store(addr: usize, size: usize) -> void {
    if size == 0 {
        return;
    }
    let idx: usize = addr & 0xFF;
    unsafe { raw.store<u8>(phys((&shadow) as usize + idx), 0); }
}
