// Atomic locals (§19) lower to the plain payload object operated on with the
// compiler's `__atomic_*` builtins: `atomic.init(v)` becomes the initial value,
// and load/store/fetch_add become __atomic_load_n / __atomic_store_n /
// __atomic_fetch_add with the mapped memory-order constant.

fn load_acquire() -> bool {
    var flag: atomic<bool> = atomic.init(false);
    return flag.load(.acquire);
}

fn store_release(value: bool) -> void {
    var flag: atomic<bool> = atomic.init(false);
    flag.store(value, .release);
}

fn fetch_add_acq_rel(delta: u64) -> u64 {
    var ticks: atomic<u64> = atomic.init(0);
    return ticks.fetch_add(delta, .acq_rel);
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
