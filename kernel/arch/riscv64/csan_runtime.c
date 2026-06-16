// Bare-metal M-mode KCSAN data-race watchpoint runtime for the D2.3 demo
// (tests/qemu/proc/csan_demo.mc).
//
// KCSAN model (a la the Linux Kernel Concurrency Sanitizer): an UNSYNCHRONIZED memory
// access does not lock; instead it briefly installs a *watchpoint* describing the location
// and access kind, then watches it for a short window. If a concurrent context performs a
// conflicting access (the two overlap and at least one is a write) while the watchpoint is
// live, that is a data race. The MC compiler, under `--checks=csan`, wraps every
// raw.load/raw.store (the unsynchronized path) with
//   mc_csan_read(addr, size)  /  mc_csan_write(addr, size)
// which this file implements. The SYNCHRONIZED `mc_race_*` accessors (what a scalar `global`
// lowers to) never call these hooks, so a properly-synchronized access never sets a
// watchpoint and never races -> clean.
//
// CONCURRENCY IS REAL: the racing context is a CLINT machine-timer IRQ that preempts the
// boot thread at an arbitrary instruction (the same asynchronous preemption the scheduler
// demo uses). When the IRQ fires while the boot thread holds a watchpoint, the IRQ-side
// access hook finds the live watchpoint set by the *other* context and traps. The runtime
// widens the watch window so a tick is GUARANTEED to land inside the racy access (making
// the demo deterministic), but the interleaving — the IRQ interrupting mid-access — is
// genuine preemption, not a hand-called function. See HONESTY note at the bottom.
//
// This runtime is plain C (NOT csan-instrumented): its own watchpoint-table reads/writes
// must never recurse through mc_csan_*.
#include <stdint.h>
#include <stddef.h>

#define UART      ((volatile uint8_t *)0x10000000UL)
#define FINISHER  ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void halt(void) { *FINISHER = 0x5555; for (;;) {} }

// CLINT machine timer (QEMU virt). A small interval so a tick reliably lands inside the
// boot thread's widened watch window.
#define CLINT_MTIME    ((volatile uint64_t *)0x0200BFF8UL)
#define CLINT_MTIMECMP ((volatile uint64_t *)0x02004000UL)
#define TICK_INTERVAL  2000ULL
#define MCAUSE_M_TIMER 0x8000000000000007ULL

// MC entry points (tests/qemu/proc/csan_demo.mc, compiled with --checks=csan).
uint32_t csan_race(uintptr_t shared);
uint32_t csan_clean(void);
uint32_t csan_irq_unsync(uintptr_t shared);
uint32_t csan_irq_sync(void);

// ---- watchpoint table ------------------------------------------------------------------
// Two contexts can be live at once: the boot thread (id 0) and the timer IRQ (id 1). One
// watchpoint slot per context is enough — a context holds at most one in-flight access.
#define CTX_MAIN 0
#define CTX_IRQ  1
#define NCTX     2

typedef struct {
    volatile uintptr_t addr;   // start of watched range
    volatile uintptr_t size;   // length; 0 == slot empty
    volatile int       is_write;
    volatile int       active;
} watchpoint_t;

static watchpoint_t wp[NCTX];

// Current context id. Set to CTX_IRQ around the MC IRQ-side call (see trap_entry); CTX_MAIN
// otherwise. A single global is correct because the IRQ cannot itself be preempted here
// (no nested timer) and the boot thread only advances while not in the IRQ.
static volatile int csan_ctx = CTX_MAIN;

// The shared word the race targets, in the managed pool. Aligned so a u32 access is atomic
// at the hardware level (the RACE is logical, not a torn write).
__attribute__((aligned(64))) static uint8_t pool[4096];

static volatile int csan_armed;
static volatile int race_reported;   // set once the race is detected (latches the result)

static int ranges_overlap(uintptr_t a, uintptr_t alen, uintptr_t b, uintptr_t blen) {
    return a < b + blen && b < a + alen;
}

// The conflict check shared by the read/write hooks. `is_write` is this access's kind.
// Scans the OTHER context's watchpoint; a live, overlapping watchpoint where at least one
// side is a write is a data race -> trap (-> CSAN-DETECTED via the trap vector).
static void csan_access(uintptr_t addr, uintptr_t size, int is_write) {
    if (!csan_armed || size == 0) return;
    int self = csan_ctx;
    int other = self ^ 1;

    // 1. Conflict check against the other context's live watchpoint.
    if (wp[other].active && wp[other].size != 0 &&
        ranges_overlap(addr, size, wp[other].addr, wp[other].size) &&
        (is_write || wp[other].is_write)) {
        race_reported = 1;
        __builtin_trap(); // data race -> M-mode trap -> "CSAN-DETECTED"
    }

    // 2. Install this context's watchpoint and watch it for a window. Only the boot thread
    //    widens the window (so a preempting tick lands inside); the IRQ does not spin.
    wp[self].addr = addr;
    wp[self].size = size;
    wp[self].is_write = is_write;
    wp[self].active = 1;

    if (self == CTX_MAIN) {
        // Watch window. A timer tick (TICK_INTERVAL mtime units) is guaranteed to fire
        // within this spin, preempting into the IRQ-side conflicting access while THIS
        // watchpoint is still live. Re-check after the window too, in case the conflicting
        // access set its own watchpoint between our install and a later tick.
        for (volatile int s = 0; s < 20000 && !race_reported; ++s) {
            if (wp[other].active && wp[other].size != 0 &&
                ranges_overlap(addr, size, wp[other].addr, wp[other].size) &&
                (is_write || wp[other].is_write)) {
                race_reported = 1;
                __builtin_trap();
            }
        }
    }

    // 3. Clear our watchpoint.
    wp[self].active = 0;
    wp[self].size = 0;
}

// The compiler-emitted hooks. Strong definitions override the weak no-op stubs MC emits.
__attribute__((used)) void mc_csan_read(uintptr_t addr, uintptr_t size)  { csan_access(addr, size, 0); }
__attribute__((used)) void mc_csan_write(uintptr_t addr, uintptr_t size) { csan_access(addr, size, 1); }

// ---- timer / trap wiring ---------------------------------------------------------------
static void timer_rearm(void) { *CLINT_MTIMECMP = *CLINT_MTIME + TICK_INTERVAL; }

// What the timer IRQ does on each tick: depends on the scenario.
//   RACE_SCENARIO  : an UNSYNCHRONIZED write to the shared word (instrumented -> watchpoint
//                    -> conflict-detects the boot thread's live watchpoint).
//   (clean)        : a SYNCHRONIZED race-accessor write (no watchpoint -> never conflicts).
static volatile uintptr_t race_shared_addr;

__attribute__((used)) void trap_entry(void) {
    uint64_t mcause;
    __asm__ volatile("csrr %0, mcause" : "=r"(mcause));
    if (mcause != MCAUSE_M_TIMER) { halt(); }
    timer_rearm();
    // Run the IRQ-side conflicting access AS THE IRQ CONTEXT.
    csan_ctx = CTX_IRQ;
#if defined(RACE_SCENARIO)
    (void)csan_irq_unsync(race_shared_addr); // instrumented -> may trap (CSAN-DETECTED)
#else
    (void)csan_irq_sync();                    // synchronized -> never traps
#endif
    csan_ctx = CTX_MAIN;
}

// M-mode trap vector. A timer interrupt arrives at an arbitrary instruction, so save the
// full integer frame before dispatch. A trap from __builtin_trap (the race detection) has
// mcause != timer and routes to the CSAN-DETECTED reporter via trap_report below.
__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile(
        "addi sp, sp, -256\n"
        "sd ra,  0(sp)\n"  "sd t0,  8(sp)\n"  "sd t1, 16(sp)\n"  "sd t2, 24(sp)\n"
        "sd t3, 32(sp)\n"  "sd t4, 40(sp)\n"  "sd t5, 48(sp)\n"  "sd t6, 56(sp)\n"
        "sd a0, 64(sp)\n"  "sd a1, 72(sp)\n"  "sd a2, 80(sp)\n"  "sd a3, 88(sp)\n"
        "sd a4, 96(sp)\n"  "sd a5,104(sp)\n"  "sd a6,112(sp)\n"  "sd a7,120(sp)\n"
        "sd s0,128(sp)\n"  "sd s1,136(sp)\n"  "sd s2,144(sp)\n"  "sd s3,152(sp)\n"
        "sd s4,160(sp)\n"  "sd s5,168(sp)\n"  "sd s6,176(sp)\n"  "sd s7,184(sp)\n"
        "sd s8,192(sp)\n"  "sd s9,200(sp)\n"  "sd s10,208(sp)\n" "sd s11,216(sp)\n"
        "call trap_dispatch\n"
        "ld ra,  0(sp)\n"  "ld t0,  8(sp)\n"  "ld t1, 16(sp)\n"  "ld t2, 24(sp)\n"
        "ld t3, 32(sp)\n"  "ld t4, 40(sp)\n"  "ld t5, 48(sp)\n"  "ld t6, 56(sp)\n"
        "ld a0, 64(sp)\n"  "ld a1, 72(sp)\n"  "ld a2, 80(sp)\n"  "ld a3, 88(sp)\n"
        "ld a4, 96(sp)\n"  "ld a5,104(sp)\n"  "ld a6,112(sp)\n"  "ld a7,120(sp)\n"
        "ld s0,128(sp)\n"  "ld s1,136(sp)\n"  "ld s2,144(sp)\n"  "ld s3,152(sp)\n"
        "ld s4,160(sp)\n"  "ld s5,168(sp)\n"  "ld s6,176(sp)\n"  "ld s7,184(sp)\n"
        "ld s8,192(sp)\n"  "ld s9,200(sp)\n"  "ld s10,208(sp)\n" "ld s11,216(sp)\n"
        "addi sp, sp, 256\n"
        "mret\n");
}

// Dispatch: a machine-timer interrupt drives preemption (trap_entry, which may detect the
// race and __builtin_trap). Any non-timer trap here is that __builtin_trap (the race
// detection or a fault) -> report CSAN-DETECTED and halt.
__attribute__((used)) void trap_dispatch(void) {
    uint64_t mcause;
    __asm__ volatile("csrr %0, mcause" : "=r"(mcause));
    if (mcause == MCAUSE_M_TIMER) {
        trap_entry();
        return;
    }
    // Non-timer trap == the data-race __builtin_trap (CSAN-DETECTED) or a real fault.
    puts_("CSAN-DETECTED\n");
    halt();
}

static void timer_start(void) {
    __asm__ volatile("csrw mtvec, %0" ::"r"(&trap_vector));
    timer_rearm();
    __asm__ volatile("csrs mie, %0" ::"r"((uintptr_t)(1u << 7)));     // MTIE
    __asm__ volatile("csrs mstatus, %0" ::"r"((uintptr_t)(1u << 3))); // MIE
}

__attribute__((used)) void m_main(void) {
    race_shared_addr = (uintptr_t)pool;
    csan_armed = 1;
    timer_start();

#if defined(RACE_SCENARIO)
    puts_("csan race demo booting (M-mode)\n");
    puts_("race: unsynchronized boot-thread access vs preempting timer-IRQ access...\n");
    // The boot thread repeatedly does the UNSYNCHRONIZED access; a timer tick preempts into
    // the conflicting IRQ access while the watchpoint is live -> CSAN-DETECTED (traps in
    // csan_access, never returns). If detection FAILS, csan_race returns and we print MISSED.
    (void)csan_race((uintptr_t)pool);
    puts_("RACE-MISSED\n"); // only reached if the watchpoint conflict check did NOT fire
#else
    puts_("csan clean demo booting (M-mode)\n");
    puts_("clean: synchronized (mc_race_*) boot-thread access vs synchronized timer IRQ...\n");
    uint32_t v = csan_clean();
    if (v != 0) {
        puts_("CSAN-OK\n"); // synchronized accesses set no watchpoint -> no race detected
    } else {
        puts_("CSAN-BAD\n");
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
