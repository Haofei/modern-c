// Bare-metal M-mode KMSAN shadow runtime for the D2.2 uninitialized-heap-use demo.
//
// This EXTENDS the D2.1 ksan shadow (per-byte shadow over the managed pool) to track
// INITIALIZED-ness. The shadow machinery and the M-mode bring-up are shared verbatim with
// ksan_runtime.c via shadow.h — KMSAN is exactly KASAN plus one extra shadow state
// (SHADOW_UNINIT) and the init-tracking store hook below, so the two runtimes cannot drift.
// The shadow byte distinguishes three states:
//
//     SHADOW_CLEAN  (0x00) — addressable AND initialized: a normal valid read.
//     SHADOW_UNINIT (0xAA) — addressable but NEVER WRITTEN since allocation: reading it is
//                            use of uninitialized memory.
//     SHADOW_POISON (0xFF) — freed / redzone / not-yet-allocated; reading it is UAF/OOB.
//
// The MC compiler, under `--checks=msan`, wraps:
//   - every raw.store with  mc_ksan_check(addr,size)  THEN  mc_ksan_store(addr,size)
//   - every raw.load  with  mc_ksan_check(addr,size)
// mc_ksan_store marks exactly the written bytes CLEAN (initialized). mc_ksan_check (in
// shadow.h) traps if any covered shadow byte is NOT CLEAN — i.e. UNINIT (KMSAN) or POISON
// (KASAN). So a load of a freshly-allocated, never-written byte hits UNINIT and traps BEFORE
// the dereference — genuine uninitialized-heap-read detection, the dynamic complement to the
// static S0.1 check.
//
// kmsan_alloc(size) is a trivial bump allocator over `pool`; it marks the returned region
// UNINIT so reading it before writing traps.
//
// This runtime is plain C (NOT MC-instrumented): its own shadow reads/writes must never
// recurse through mc_ksan_check / mc_ksan_store.
#define SHADOW_TRAP_MSG "KMSAN-DETECTED\n"
#include "shadow.h"

// MC entry points (compiled with --checks=msan).
uint32_t kmsan_clean(void);
uint32_t kmsan_uninit(void);

static uintptr_t kmsan_bump;   // next free byte in the bump allocator

// Arm the shadow for [base, base+len). The whole pool starts POISONED (not yet allocated);
// kmsan_alloc carves out UNINIT regions, stores mark them CLEAN.
__attribute__((used)) static void kmsan_arm(uintptr_t base, uintptr_t len) {
    shadow_arm(base, len, SHADOW_POISON);
    kmsan_bump = shadow_base;
}

// Bump-allocate `size` bytes (rounded up to 8) and mark the region UNINIT. The MC demo
// calls this; reading the region before a store traps in mc_ksan_check.
__attribute__((used)) uintptr_t kmsan_alloc(uintptr_t size) {
    uintptr_t aligned = (size + 7u) & ~(uintptr_t)7u;
    if (kmsan_bump + aligned > shadow_end) return 0; // out of pool
    uintptr_t p = kmsan_bump;
    kmsan_bump += aligned;
    shadow_set(p, aligned, SHADOW_UNINIT);
    return p;
}

// KMSAN init-tracking hook the compiler emits AFTER each raw.store: mark exactly the written
// bytes initialized (CLEAN). With per-byte shadow this is byte-exact, so a sub-word store
// cleans ONLY the bytes it actually wrote — the untouched bytes of the surrounding word stay
// UNINIT, and a later read of them still traps (the bug a 1:8 slot-granular clean would mask).
// (Also serves as the strong override of the weak no-op in emitted code.)
__attribute__((used)) void mc_ksan_store(uintptr_t addr, uintptr_t size) {
    shadow_set(addr, size, SHADOW_CLEAN);
}

__attribute__((used)) void m_main(void) {
    __asm__ volatile("csrw mtvec, %0\n" ::"r"((uintptr_t)&trap_vector) : "memory");

    puts_("kmsan demo booting (M-mode)\n");

#if defined(UNINIT_SCENARIO)
    // 2. Uninitialized read: allocate, then read a never-written byte -> UNINIT shadow -> trap.
    kmsan_arm((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("uninit: reading never-written heap memory...\n");
    kmsan_uninit();
    puts_("UNINIT-MISSED\n"); // only reached if the shadow check FAILED to fire
#else
    // 1. Clean path: write-before-read of a fresh allocation -> all CLEAN -> no trap.
    kmsan_arm((uintptr_t)pool, (uintptr_t)sizeof(pool));
    uint32_t ok = kmsan_clean();
    if (ok == 1u) {
        puts_("KMSAN-OK\n"); // every read was of an initialized (written) byte
    } else {
        puts_("KMSAN-BAD\n");
    }
#endif
    halt();
}
