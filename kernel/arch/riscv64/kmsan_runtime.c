// Bare-metal M-mode KMSAN shadow runtime for the D2.2 uninitialized-heap-use demo.
//
// This EXTENDS the D2.1 ksan shadow (kernel/arch/riscv64/ksan_runtime.c, the classic 1:8
// scheme: one shadow byte covers eight bytes of the managed pool) to track INITIALIZED-ness.
// The shadow byte now distinguishes three states:
//
//     SHADOW_CLEAN  (0x00) — addressable AND initialized: a normal valid read.
//     SHADOW_UNINIT (0xAA) — addressable but NEVER WRITTEN since allocation: reading it is
//                            use of uninitialized memory.
//     SHADOW_POISON (0xFF) — freed / redzone (the D2.1 poison); reading it is UAF/OOB.
//
// The MC compiler, under `--checks=msan`, wraps:
//   - every raw.store with  mc_ksan_check(addr,size)  THEN  mc_ksan_store(addr,size)
//   - every raw.load  with  mc_ksan_check(addr,size)
// mc_ksan_store marks the covered shadow bytes CLEAN (initialized). mc_ksan_check traps if
// any covered shadow byte is NOT CLEAN — i.e. UNINIT (KMSAN) or POISON (KASAN). So a load of
// a freshly-allocated, never-written byte hits UNINIT and traps BEFORE the dereference —
// genuine uninitialized-heap-read detection, the dynamic complement to the static S0.1 check.
//
// kmsan_alloc(size) is a trivial bump allocator over `pool`; it marks the returned region
// UNINIT so reading it before writing traps. (1:8 shadow granularity means the user region
// is rounded out to an 8-byte boundary; the demo allocations are 8-byte multiples.)
//
// This runtime is plain C (NOT MC-instrumented): its own shadow reads/writes must never
// recurse through mc_ksan_check / mc_ksan_store.
#include <stdint.h>
#include <stddef.h>

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void halt(void) { *FINISHER = 0x5555; for (;;) {} }

// MC entry points (compiled with --checks=msan).
uint32_t kmsan_clean(void);
uint32_t kmsan_uninit(void);

// ---- shadow state ----
#define POOL_BYTES (64u * 1024u)
#define SHADOW_BYTES (POOL_BYTES / 8u)
__attribute__((aligned(64))) static uint8_t pool[POOL_BYTES];
static uint8_t shadow[SHADOW_BYTES];
static uintptr_t kmsan_base;   // mem_base for the shadow mapping
static uintptr_t kmsan_end;    // mem_base + POOL_BYTES
static uintptr_t kmsan_bump;   // next free byte in the bump allocator
static int kmsan_armed;

#define SHADOW_CLEAN 0x00u   // addressable + initialized
#define SHADOW_UNINIT 0xAAu  // addressable but never written (uninitialized)
#define SHADOW_POISON 0xFFu  // freed / redzone

// Arm the shadow for [base, base+len). The whole pool starts POISONED (not yet allocated);
// kmsan_alloc carves out UNINIT regions, stores mark them CLEAN.
__attribute__((used)) static void kmsan_arm(uintptr_t base, uintptr_t len) {
    kmsan_base = base;
    kmsan_end = base + (len < POOL_BYTES ? len : POOL_BYTES);
    kmsan_bump = base;
    for (size_t i = 0; i < SHADOW_BYTES; ++i) shadow[i] = SHADOW_POISON;
    kmsan_armed = 1;
}

// Set the shadow for every 8-byte slot covering [addr, addr+size) to `val`. Addresses
// outside the armed pool are ignored.
static void shadow_set(uintptr_t addr, uintptr_t size, uint8_t val) {
    if (!kmsan_armed || size == 0) return;
    uintptr_t lo = addr;
    uintptr_t hi = addr + size; // [lo, hi)
    if (lo < kmsan_base) lo = kmsan_base;
    if (hi > kmsan_end) hi = kmsan_end;
    if (lo >= hi) return;
    uintptr_t first = (lo - kmsan_base) >> 3;
    uintptr_t last = (hi - 1 - kmsan_base) >> 3; // inclusive
    for (uintptr_t i = first; i <= last && i < SHADOW_BYTES; ++i) shadow[i] = val;
}

// Bump-allocate `size` bytes (rounded up to 8) and mark the region UNINIT. The MC demo
// calls this; reading the region before a store traps in mc_ksan_check.
__attribute__((used)) uintptr_t kmsan_alloc(uintptr_t size) {
    uintptr_t aligned = (size + 7u) & ~(uintptr_t)7u;
    if (kmsan_bump + aligned > kmsan_end) return 0; // out of pool
    uintptr_t p = kmsan_bump;
    kmsan_bump += aligned;
    shadow_set(p, aligned, SHADOW_UNINIT);
    return p;
}

// KMSAN init-tracking hook the compiler emits AFTER each raw.store: mark the written bytes
// initialized (CLEAN). (Also serves as the strong override of the weak no-op in emitted code.)
__attribute__((used)) void mc_ksan_store(uintptr_t addr, uintptr_t size) {
    shadow_set(addr, size, SHADOW_CLEAN);
}

// D2.1-compatible poison/unpoison hooks (for a heap_new_ksan heap, if linked). Unused by
// this demo but provided so the same runtime can stand in for the ksan hooks.
__attribute__((used)) void mc_ksan_poison(uintptr_t addr, uintptr_t size) {
    shadow_set(addr, size, SHADOW_POISON);
}
__attribute__((used)) void mc_ksan_unpoison(uintptr_t addr, uintptr_t size) {
    shadow_set(addr, size, SHADOW_CLEAN);
}

// The instrumented-access hook the compiler emits before each raw.load/raw.store. Consult
// the shadow byte(s) covering [addr, addr+size); if any is NOT clean (UNINIT or POISON), trap.
__attribute__((used)) void mc_ksan_check(uintptr_t addr, uintptr_t size) {
    if (!kmsan_armed || size == 0) return;
    if (addr < kmsan_base || addr >= kmsan_end) return; // not shadow-tracked memory
    uintptr_t hi = addr + size;
    if (hi > kmsan_end) hi = kmsan_end;
    uintptr_t first = (addr - kmsan_base) >> 3;
    uintptr_t last = (hi - 1 - kmsan_base) >> 3;
    for (uintptr_t i = first; i <= last && i < SHADOW_BYTES; ++i) {
        if (shadow[i] != SHADOW_CLEAN) {
            __builtin_trap(); // uninit/poisoned access -> M-mode trap -> KMSAN-DETECTED
        }
    }
}

// M-mode trap vector: any trap here is the mc_ksan_check __builtin_trap.
__attribute__((used)) void on_trap(void) { puts_("KMSAN-DETECTED\n"); halt(); }

__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile("call on_trap\n");
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

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call m_main\n"
        "1: j 1b\n");
}
