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
// which this file implements: it maps `addr` to its shadow byte(s) and traps (via the
// M-mode trap path -> "KASAN-DETECTED") if any covered byte is poisoned. The MC KASAN heap
// (`heap_new_ksan`) calls mc_ksan_poison on free and mc_ksan_unpoison on alloc. So a read
// of freed memory hits a poisoned shadow byte and traps BEFORE the dereference — genuine
// access-time use-after-free detection, finer than the D2.4 free-time redzone check.
//
// This runtime is plain C (NOT MC-instrumented): its own shadow reads/writes must never
// recurse through mc_ksan_check.
#include <stdint.h>
#include <stddef.h>

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void halt(void) { *FINISHER = 0x5555; for (;;) {} }

// MC entry points (compiled with --checks=ksan).
uint32_t ksan_clean(uintptr_t region, uintptr_t len);
uint32_t ksan_uaf(uintptr_t region, uintptr_t len);
uint32_t ksan_oob(uintptr_t region, uintptr_t len);

// ---- shadow state ----
#define POOL_BYTES (64u * 1024u)
#define SHADOW_BYTES (POOL_BYTES / 8u)
__attribute__((aligned(64))) static uint8_t pool[POOL_BYTES];
static uint8_t shadow[SHADOW_BYTES];
static uintptr_t ksan_base;   // mem_base for the shadow mapping
static uintptr_t ksan_end;    // mem_base + POOL_BYTES
static int ksan_armed;

#define SHADOW_CLEAN 0x00u
#define SHADOW_POISON 0xFFu

// Arm the shadow for [base, base+len): everything addressable (clean) to start. The MC
// heap then poisons freed blocks / redzones as it runs.
__attribute__((used)) void mc_ksan_arm(uintptr_t base, uintptr_t len) {
    ksan_base = base;
    ksan_end = base + (len < POOL_BYTES ? len : POOL_BYTES);
    for (size_t i = 0; i < SHADOW_BYTES; ++i) shadow[i] = SHADOW_CLEAN;
    ksan_armed = 1;
}

// Set the shadow for every 8-byte slot covering [addr, addr+size) to `val`. Out-of-range
// addresses (outside the armed pool) are ignored — those bytes are not shadow-tracked.
static void shadow_set(uintptr_t addr, uintptr_t size, uint8_t val) {
    if (!ksan_armed || size == 0) return;
    uintptr_t lo = addr;
    uintptr_t hi = addr + size; // [lo, hi)
    if (lo < ksan_base) lo = ksan_base;
    if (hi > ksan_end) hi = ksan_end;
    if (lo >= hi) return;
    uintptr_t first = (lo - ksan_base) >> 3;
    uintptr_t last = (hi - 1 - ksan_base) >> 3; // inclusive
    for (uintptr_t i = first; i <= last && i < SHADOW_BYTES; ++i) shadow[i] = val;
}

__attribute__((used)) void mc_ksan_poison(uintptr_t addr, uintptr_t size) {
    shadow_set(addr, size, SHADOW_POISON);
}
__attribute__((used)) void mc_ksan_unpoison(uintptr_t addr, uintptr_t size) {
    shadow_set(addr, size, SHADOW_CLEAN);
}

// The instrumented-access hook the compiler emits before each raw.load/raw.store.
// Consult the shadow byte(s) covering [addr, addr+size); if any is poisoned, trap.
__attribute__((used)) void mc_ksan_check(uintptr_t addr, uintptr_t size) {
    if (!ksan_armed || size == 0) return;
    if (addr < ksan_base || addr >= ksan_end) return; // not shadow-tracked memory
    uintptr_t hi = addr + size;
    if (hi > ksan_end) hi = ksan_end;
    uintptr_t first = (addr - ksan_base) >> 3;
    uintptr_t last = (hi - 1 - ksan_base) >> 3;
    for (uintptr_t i = first; i <= last && i < SHADOW_BYTES; ++i) {
        if (shadow[i] != SHADOW_CLEAN) {
            __builtin_trap(); // poisoned access -> M-mode trap -> KASAN-DETECTED
        }
    }
}

// M-mode trap vector: any trap here is the mc_ksan_check (or other) __builtin_trap.
__attribute__((used)) void on_trap(void) { puts_("KASAN-DETECTED\n"); halt(); }

__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile("call on_trap\n");
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

#if defined(OOB_SCENARIO)
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

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call m_main\n"
        "1: j 1b\n");
}
