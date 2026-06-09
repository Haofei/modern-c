// A global `atomic<T>` (e.g. an interrupt-shared counter) seeds from a static
// `atomic.init(N)` and lowers to a plain scalar accessed via __atomic_* ops, with
// the address taken raw (`&g`) rather than through the relaxed-global wrapper.
global ticks: atomic<u32> = atomic.init(0);

fn isr_tick() -> void {
    ticks.fetch_add(1, .acq_rel);
}

fn read_ticks() -> u32 {
    return ticks.load(.acquire);
}

fn reset_ticks() -> void {
    ticks.store(0, .release);
}
