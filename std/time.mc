// MC standard library — `time`: monotonic ticks and delays (section 28.4) for
// reset waits, link-up polling, and DMA timeouts. The tick source and busy-wait
// are platform primitives; the wrap-correct difference and timeout test are pure
// MC over the `counter` arithmetic domain (section 5.5).
//
// The tick source is a free-running hardware counter, so `Ticks` is `counter<u64>`
// (section 5.5), NOT a plain integer or `wrap<u64>`. The counter domain forbids
// ordered comparison and bitwise ops by design and exposes only `delta_mod` — the
// fully-defined modular difference of two samples — because no operation can
// recover real elapsed time from two modular reads once the counter has wrapped
// more than once. This library therefore provides `delta_mod` (the magnitude of
// that difference) and bounded-wait helpers, and deliberately does NOT provide a
// plain `elapsed()` that pretends to recover real time (section 5.5).

type Ticks = counter<u64>;

extern fn mc_read_ticks() -> Ticks;
extern fn mc_udelay(us: u32) -> void;

export fn read_ticks() -> Ticks {
    return mc_read_ticks();
}

// Wrap-correct modular delta between two monotonic reads (section 5.5 `delta_mod`):
// the only fully-defined difference of two counter samples. Returned as a plain
// magnitude (`u64`) so it can be compared against a tick limit — the counter
// domain forbids ordered comparison of the samples themselves, since only the
// difference is meaningful to order. This is sound ONLY when the true interval is
// below the counter's ambiguity window; callers enforce that with a bounded wait
// (`timed_out` / `poll_until`), whose finite `limit` IS that external invariant.
export fn delta_mod(start: Ticks, now: Ticks) -> u64 {
    let diff: wrap<u64> = Ticks.delta_mod(now, start);
    return diff as u64;
}

// Bounded wait: has at least `limit` ticks elapsed since `start`? The finite
// `limit` is the external temporal invariant section 5.5 requires — the caller
// asserts the real interval stays below the counter's ambiguity window, which a
// reset/link-up/DMA timeout does by construction.
export fn timed_out(start: Ticks, now: Ticks, limit: u64) -> bool {
    return delta_mod(start, now) >= limit;
}

// Poll `probe` until it returns true or `timeout` ticks elapse from now; returns
// whether it succeeded before the deadline. Collapses the hand-rolled
// `let start = read_ticks(); while !timed_out(...) { if cond {…} }` spin loop.
// `probe` is a context-free predicate (a non-capturing fn pointer); a probe that
// needs state (e.g. a specific virtqueue) uses a typed wrapper like `vq_wait_used`
// until capturing closures exist.
export fn poll_until(probe: fn() -> bool, timeout: u64) -> bool {
    let start: Ticks = read_ticks();
    while !timed_out(start, read_ticks(), timeout) {
        let hit: bool = probe();
        if hit {
            return true;
        }
    }
    return false;
}

export fn udelay(us: u32) -> void {
    mc_udelay(us);
}

export fn mdelay(ms: u32) -> void {
    mc_udelay(ms * 1000);
}
