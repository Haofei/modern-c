// Bare-metal M-mode KASAN shadow runtime for the D2.1 access-time UAF/OOB demo.
//
// KASAN shadow scheme (classic 1:8): one shadow byte covers eight bytes of the managed
// pool. shadow_index = (addr - mem_base) >> 3; a shadow byte of 0 means the eight bytes
// are addressable, 0xFF means poisoned. (We poison/unpoison at byte granularity by
// touching every covering shadow byte; a partially-poisoned 8-byte word is conservatively
// treated as poisoned, which is correct for trap-on-poison.)
//
// The MC compiler, under `--checks=ksan`, wraps every raw.load/raw.store with
//   mc_ksan_check(addr, size)
// which the shared shadow runtime (shadow.h) implements: it maps `addr` to its shadow
// byte(s) and traps (via the M-mode trap path -> "KASAN-DETECTED") if any covered byte is
// poisoned. The MC KASAN heap (`heap_new_ksan`) calls mc_ksan_poison on free and
// mc_ksan_unpoison on alloc. So a read of freed memory hits a poisoned shadow byte and traps
// BEFORE the dereference — genuine access-time use-after-free detection, finer than the D2.4
// free-time redzone check.
//
// All the shadow machinery and the M-mode bring-up (UART/FINISHER, trap vector, _start) live
// in shadow.h, shared verbatim with the KMSAN runtime (which is KASAN + one extra state). This
// file supplies only the KASAN-specific arm wrapper and the demo driver.
//
// This runtime is plain C (NOT MC-instrumented): its own shadow reads/writes must never
// recurse through mc_ksan_check.
#define SHADOW_TRAP_MSG "KASAN-DETECTED\n"
#include "shadow.h"

// MC entry points (compiled with --checks=ksan).
uint32_t ksan_clean(uintptr_t region, uintptr_t len);
uint32_t ksan_uaf(uintptr_t region, uintptr_t len);
uint32_t ksan_oob(uintptr_t region, uintptr_t len);
uint32_t ksan_field_uaf(uintptr_t region, uintptr_t len);

// Arm the shadow for [base, base+len): everything addressable (clean) to start. The MC heap
// then poisons freed blocks / redzones as it runs.
__attribute__((used)) void mc_ksan_arm(uintptr_t base, uintptr_t len) {
    shadow_arm(base, len, SHADOW_CLEAN);
}

__attribute__((used)) void m_main(void) {
    __asm__ volatile("csrw mtvec, %0\n" ::"r"((uintptr_t)&trap_vector) : "memory");

    puts_("ksan demo booting (M-mode)\n");

    // 1. Clean path: alloc/use-in-bounds/free with the shadow armed -> no trap.
    mc_ksan_arm((uintptr_t)pool, (uintptr_t)sizeof(pool));
    uint32_t ok = ksan_clean((uintptr_t)pool, (uintptr_t)sizeof(pool));
    if (ok == 1u) {
        puts_("KASAN-OK\n"); // clean in-bounds use, nothing poisoned was accessed
    } else {
        puts_("KASAN-BAD\n");
        halt();
    }

#if defined(FIELD_SCENARIO)
    // 4. UAF through a STRUCT FIELD (not raw.load): `node.value` of freed memory traps.
    // This is the new-coverage proof — before field instrumentation this was MISSED.
    mc_ksan_arm((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("field-uaf: reading freed node.value (struct-field load)...\n");
    ksan_field_uaf((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("FIELD-UAF-MISSED\n"); // only reached if the field load was NOT instrumented
#elif defined(OOB_SCENARIO)
    // 3. Out-of-bounds: a read one past the user region (a poisoned redzone byte) traps.
    mc_ksan_arm((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("oob: reading one past allocation...\n");
    ksan_oob((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("OOB-MISSED\n"); // only reached if the shadow check FAILED to fire
#else
    // 2. Use-after-free: a read of freed (poisoned) memory traps at access time.
    mc_ksan_arm((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("uaf: reading freed memory...\n");
    ksan_uaf((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("UAF-MISSED\n"); // only reached if the shadow check FAILED to fire
#endif
    halt();
}
