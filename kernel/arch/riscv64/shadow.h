// Shared bare-metal M-mode shadow-memory machinery for the KASAN (D2.1) and KMSAN (D2.2)
// runtimes. Both map a managed pool to a per-byte shadow and share the identical M-mode
// bring-up (UART/FINISHER, trap vector, _start). KMSAN is exactly KASAN plus one extra shadow
// state (SHADOW_UNINIT) and an init-tracking store hook; rather than duplicate the scheme
// (and risk it drifting between the two files), the common parts live here and each runtime
// supplies only what differs:
//
//   - SHADOW_TRAP_MSG : the string on_trap prints (e.g. "KASAN-DETECTED").
//   - m_main()        : the demo driver (provided by the including .c file).
//
// Shadow granularity is 1:1 (one shadow byte per pool byte). The classic KASAN scheme is 1:8
// (one shadow byte per eight pool bytes), but 1:8 cannot represent a partially-written 8-byte
// slot: a sub-word store would have to mark the whole slot CLEAN, so a later read of the
// untouched bytes of that slot would NOT trap (a KMSAN false negative). Per-byte shadow tracks
// each byte's state exactly, which is strictly more precise — sub-word stores are now sound,
// and KASAN poison/unpoison/check stay correct (byte-exact rather than slot-rounded).
//
// This header is plain C and is NOT MC-instrumented: its own shadow reads/writes must never
// recurse through mc_ksan_check / mc_ksan_store.
#ifndef MC_RISCV64_SHADOW_H
#define MC_RISCV64_SHADOW_H

#include <stdint.h>
#include <stddef.h>

#ifndef SHADOW_TRAP_MSG
#error "include shadow.h only after #define SHADOW_TRAP_MSG \"...\""
#endif

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void halt(void) { *FINISHER = 0x5555; for (;;) {} }

// ---- shadow state (1:1 — one shadow byte per pool byte) ----
#define POOL_BYTES (64u * 1024u)
#define SHADOW_BYTES (POOL_BYTES) // byte-granular: one shadow byte per pool byte
__attribute__((aligned(64))) static uint8_t pool[POOL_BYTES];
static uint8_t shadow[SHADOW_BYTES];
static uintptr_t shadow_base;   // mem_base for the shadow mapping
static uintptr_t shadow_end;    // mem_base + POOL_BYTES
static int shadow_armed;

#define SHADOW_CLEAN 0x00u   // addressable + (KMSAN) initialized
#define SHADOW_UNINIT 0xAAu  // addressable but never written (KMSAN uninitialized)
#define SHADOW_POISON 0xFFu  // freed / redzone / not-yet-allocated

// Arm the shadow for [base, base+len): every shadow byte set to `fill`. KASAN fills CLEAN
// (everything addressable) and poisons as it runs; KMSAN fills POISON (nothing allocated yet)
// and carves out UNINIT regions in kmsan_alloc.
__attribute__((used)) static void shadow_arm(uintptr_t base, uintptr_t len, uint8_t fill) {
    shadow_base = base;
    shadow_end = base + (len < POOL_BYTES ? len : POOL_BYTES);
    for (size_t i = 0; i < SHADOW_BYTES; ++i) shadow[i] = fill;
    shadow_armed = 1;
}

// Set the shadow to `val` for exactly the bytes [addr, addr+size) that fall inside the armed
// pool. Per-byte, so a sub-word store/poison touches only the bytes it actually covers — no
// rounding out to a slot, hence no false cleaning of adjacent untouched bytes.
static void shadow_set(uintptr_t addr, uintptr_t size, uint8_t val) {
    if (!shadow_armed || size == 0) return;
    uintptr_t lo = addr;
    uintptr_t hi = addr + size; // [lo, hi)
    if (lo < shadow_base) lo = shadow_base;
    if (hi > shadow_end) hi = shadow_end;
    if (lo >= hi) return;
    uintptr_t first = lo - shadow_base;
    uintptr_t last = hi - 1 - shadow_base; // inclusive
    for (uintptr_t i = first; i <= last && i < SHADOW_BYTES; ++i) shadow[i] = val;
}

__attribute__((used)) void mc_ksan_poison(uintptr_t addr, uintptr_t size) {
    shadow_set(addr, size, SHADOW_POISON);
}
__attribute__((used)) void mc_ksan_unpoison(uintptr_t addr, uintptr_t size) {
    shadow_set(addr, size, SHADOW_CLEAN);
}

// The instrumented-access hook the compiler emits before each raw.load/raw.store. Consult the
// shadow byte(s) covering [addr, addr+size); if any is NOT clean (poisoned, or — under KMSAN —
// uninitialized), trap.
__attribute__((used)) void mc_ksan_check(uintptr_t addr, uintptr_t size) {
    if (!shadow_armed || size == 0) return;
    if (addr < shadow_base || addr >= shadow_end) return; // not shadow-tracked memory
    uintptr_t hi = addr + size;
    if (hi > shadow_end) hi = shadow_end;
    uintptr_t first = addr - shadow_base;
    uintptr_t last = hi - 1 - shadow_base;
    for (uintptr_t i = first; i <= last && i < SHADOW_BYTES; ++i) {
        if (shadow[i] != SHADOW_CLEAN) {
            __builtin_trap(); // poisoned/uninit access -> M-mode trap -> SHADOW_TRAP_MSG
        }
    }
}

// M-mode trap vector: any trap here is the mc_ksan_check (or mc_ksan_store) __builtin_trap.
__attribute__((used)) void on_trap(void) { puts_(SHADOW_TRAP_MSG); halt(); }

__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile("call on_trap\n");
}

// m_main is supplied by the including runtime (the demo driver).
void m_main(void);

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call m_main\n"
        "1: j 1b\n");
}

#endif // MC_RISCV64_SHADOW_H
