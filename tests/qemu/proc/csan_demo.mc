// QEMU boot demo for KCSAN-style data-race detection (D2.3).
//
// Compiled with `--checks=csan`, so the UNSYNCHRONIZED raw.load/raw.store path is wrapped
// by the compiler with the data-race watchpoint hooks:
//   raw.store<T>(addr, v)  ->  mc_csan_write(addr, sizeof(T)); *addr = v;
//   raw.load<T>(addr)      ->  mc_csan_read(addr, sizeof(T));  ... = *addr;
// The csan watchpoint runtime (kernel/arch/riscv64/csan_runtime.c) implements these: each
// unsynchronized access briefly sets a watchpoint on the shadow for [addr,sizeof(T)) and
// then checks, on a conflicting concurrent access (one of which is a write) from another
// context, whether the watchpoint is still live — a live overlapping watchpoint set by a
// DIFFERENT context is a data race and traps -> CSAN-DETECTED.
//
// The SYNCHRONIZED path is an ordinary scalar `global`, which the compiler lowers to the
// `mc_race_*` relaxed-atomic accessors (NOT the raw path) — these never set a watchpoint,
// so two contexts using the race accessor on the same location never conflict -> CSAN-OK.
//
// The concurrency is a REAL preempting timer IRQ (CLINT machine timer), arriving at an
// arbitrary instruction in the boot thread. The runtime widens the watch window so a tick
// is guaranteed to land inside the racy access (making detection deterministic), but the
// interleaving itself — the IRQ asynchronously interrupting the main thread mid-access — is
// genuine asynchronous preemption, not a hand-called function. See csan_runtime.c.

import "std/addr.mc";

// ---- 1. RACY scenario: the boot thread does an UNSYNCHRONIZED access to a shared word ----
// raw.store/raw.load are instrumented under --checks=csan, so each sets a watchpoint. The
// timer IRQ (csan_irq_unsync) writes the same word, also instrumented; its watchpoint hook
// sees the boot thread's live write-watchpoint -> data race -> trap. Returns only if the
// race was NOT detected (a failure).
export fn csan_race(shared: usize) -> u32 {
    let p: PAddr = pa(shared);
    var seen: u32 = 0;
    var i: u32 = 0;
    // Repeat the unsynchronized access; the watch window holds across the access so a
    // preempting tick lands inside it. The runtime traps on the first detected conflict.
    while i < 1000 {
        unsafe {
            raw.store<u32>(p, i);
            seen = seen + (raw.load<u32>(p) as u32);
        }
        i = i + 1;
    }
    return seen; // unreachable once the race is detected
}

// ---- 2. CLEAN scenario: the boot thread accesses a SYNCHRONIZED shared global ----
// `csan_sync_counter` is a scalar global, lowered to mc_race_load/mc_race_store (relaxed
// atomics, NO watchpoint). The timer IRQ (csan_irq_sync) touches the same global the same
// way. Neither side ever sets a watchpoint, so there is nothing to conflict -> no trap.
global csan_sync_counter: u32 = 0;

export fn csan_clean() -> u32 {
    var i: u32 = 0;
    while i < 1000 {
        csan_sync_counter = csan_sync_counter + 1; // mc_race_load + mc_race_store
        i = i + 1;
    }
    return csan_sync_counter;
}

// ---- IRQ-side conflicting accesses (called from the timer trap handler) ----

// The racy IRQ access: an UNSYNCHRONIZED write to the shared word — instrumented, so its
// mc_csan_write hook detects the boot thread's live watchpoint on the same location.
export fn csan_irq_unsync(shared: usize) -> u32 {
    let p: PAddr = pa(shared);
    unsafe {
        raw.store<u32>(p, 0xDEAD);
    }
    return 0;
}

// The synchronized IRQ access: a race-accessor write to the shared global — no watchpoint,
// so it never conflicts with the boot thread's race-accessor access.
export fn csan_irq_sync() -> u32 {
    csan_sync_counter = csan_sync_counter + 1;
    return csan_sync_counter;
}
