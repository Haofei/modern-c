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
// Per-access-path verification entry points (empirical coverage audit).
uint32_t ksan_field_store(uintptr_t region, uintptr_t len);
uint32_t ksan_arr_load(uintptr_t region, uintptr_t len);
uint32_t ksan_arr_store(uintptr_t region, uintptr_t len);
uintptr_t ksan_global_address(void);
uint32_t ksan_global_load(void);
uint32_t ksan_global_store(void);
uint32_t ksan_stack_local(void);
uint32_t ksan_outside_pool(uintptr_t region, uintptr_t len);

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
#elif defined(FIELD_STORE_SCENARIO)
    // Pointer struct-field STORE to freed memory. Doc claims MISS (the field-store path has no
    // shadow hook; emitAssignTarget suppresses it). VERIFY: expect this to RETURN (no trap).
    mc_ksan_arm((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("field-store: writing freed node.value (struct-field store)...\n");
    ksan_field_store((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("FIELD-STORE-MISSED\n"); // reached iff the field store was NOT instrumented (expected)
#elif defined(ARR_LOAD_SCENARIO)
    // Array-index LOAD of freed memory (through a struct-field array). VERIFY observed behaviour.
    mc_ksan_arm((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("arr-load: reading freed a.cells[3] (array-index load)...\n");
    ksan_arr_load((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("ARR-LOAD-MISSED\n"); // reached iff the array load was NOT instrumented
#elif defined(ARR_STORE_SCENARIO)
    // Array-index STORE to freed memory. Doc claims MISS. VERIFY: expect this to RETURN.
    mc_ksan_arm((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("arr-store: writing freed a.cells[3] (array-index store)...\n");
    ksan_arr_store((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("ARR-STORE-MISSED\n"); // reached iff the array store was NOT instrumented (expected)
#elif defined(GLOBAL_LOAD_SCENARIO)
    // Scalar GLOBAL load. Doc claims DETECT (the read lowers to mc_race_load_u32, which carries
    // mc_ksan_check). Arm+poison the shadow over &ksan_global, then read it -> must trap.
    {
        uintptr_t g = ksan_global_address();
        mc_ksan_arm(g, (uintptr_t)POOL_BYTES);
        mc_ksan_poison(g, 4u); // poison the 4 bytes of the global
        puts_("global-load: reading poisoned global (mc_race_load)...\n");
        ksan_global_load();
        puts_("GLOBAL-LOAD-MISSED\n"); // reached iff the global load was NOT instrumented
    }
#elif defined(GLOBAL_STORE_SCENARIO)
    // Scalar GLOBAL store. Doc claims DETECT (mc_race_store_u32 carries mc_ksan_check on the
    // ksan profile). Arm+poison &ksan_global, then write it -> must trap.
    {
        uintptr_t g = ksan_global_address();
        mc_ksan_arm(g, (uintptr_t)POOL_BYTES);
        mc_ksan_poison(g, 4u);
        puts_("global-store: writing poisoned global (mc_race_store)...\n");
        ksan_global_store();
        puts_("GLOBAL-STORE-MISSED\n"); // reached iff the global store was NOT instrumented
    }
#elif defined(STACK_LOCAL_SCENARIO)
    // Stack LOCAL access. Doc claims MISS (locals are plain C locals, never hooked, and their
    // addresses are outside any armed pool). VERIFY: expect this to RETURN.
    mc_ksan_arm((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("stack-local: read/write of an uninstrumented stack local...\n");
    ksan_stack_local();
    puts_("STACK-LOCAL-MISSED\n"); // reached iff the local access was NOT instrumented (expected)
#elif defined(OUTSIDE_POOL_SCENARIO)
    // UAF on memory the shadow does NOT cover. Doc claims FAIL-OPEN (mc_ksan_check returns early
    // when addr is outside [shadow_base, shadow_end)). Arm the shadow over a DIFFERENT region
    // (the top half of the pool) than the heap (the bottom half), so the freed-read addr is out
    // of shadow scope and is waved through. VERIFY: expect this to RETURN.
    mc_ksan_arm((uintptr_t)pool + (sizeof(pool) / 2u), (uintptr_t)(sizeof(pool) / 2u));
    puts_("outside-pool: UAF read on memory outside the armed shadow...\n");
    ksan_outside_pool((uintptr_t)pool, (uintptr_t)(sizeof(pool) / 2u));
    puts_("OUTSIDE-POOL-MISSED\n"); // reached iff the access was waved through (expected fail-open)
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
