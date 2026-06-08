// MC standard library — `time`: monotonic ticks and delays (section 28.4) for
// reset waits, link-up polling, and DMA timeouts. The tick source and busy-wait
// are platform primitives; the wrap-correct difference and timeout test are
// pure MC over the `wrap` arithmetic domain (tick counters wrap).

type Ticks = wrap<u64>;

extern fn mc_read_ticks() -> Ticks;
extern fn mc_udelay(us: u32) -> void;

export fn read_ticks() -> Ticks {
    return mc_read_ticks();
}

// Wrap-correct elapsed ticks between two monotonic reads. The wrapping
// subtraction stays in the `wrap` domain; the result is returned as a plain
// magnitude (`u64`) so it can be compared against a limit (the domain forbids
// ordered comparison by design — only the difference is meaningful to order).
export fn elapsed(start: Ticks, now: Ticks) -> u64 {
    let diff: Ticks = now - start;
    return diff as u64;
}

export fn timed_out(start: Ticks, now: Ticks, limit: u64) -> bool {
    return elapsed(start, now) >= limit;
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
