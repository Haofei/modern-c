global ticks: atomic<u32> = atomic.init(0);

fn load_acquire() -> bool {
    var flag: atomic<bool> = atomic.init(false);
    return flag.load(.acquire);
}

fn store_release(value: bool) -> void {
    var flag: atomic<bool> = atomic.init(false);
    flag.store(value, .release);
}

fn fetch_add_acq_rel(delta: u64) -> u64 {
    var local_ticks: atomic<u64> = atomic.init(0);
    return local_ticks.fetch_add(delta, .acq_rel);
}

fn fetch_sub_release(delta: u32) -> u32 {
    var local_ticks: atomic<u32> = atomic.init(4);
    return local_ticks.fetch_sub(delta, .release);
}

fn relaxed_round_trip(value: bool) -> bool {
    var flag: atomic<bool> = atomic.init(false);
    flag.store(value, .relaxed);
    return flag.load(.relaxed);
}

fn seq_cst_counter(delta: u32) -> u32 {
    var c: atomic<u32> = atomic.init(0);
    return c.fetch_add(delta, .seq_cst);
}

fn isr_tick() -> void {
    ticks.fetch_add(1, .acq_rel);
}

fn read_ticks() -> u32 {
    return ticks.load(.acquire);
}

fn reset_ticks() -> void {
    ticks.store(0, .release);
}
