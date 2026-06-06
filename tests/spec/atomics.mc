// SPEC: section=19,I.13
// SPEC: milestone=atomics
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_ATOMIC_ORDERING,E_ATOMIC_OPERATION,E_CALL_ARG_COUNT,atomics-lowering

fn atomic_load_acquire() -> bool {
    var flag: atomic<bool> = atomic.init(false);
    return flag.load(.acquire);
}

fn atomic_store_release(value: bool) -> void {
    var flag: atomic<bool> = atomic.init(false);
    flag.store(value, .release);
}

fn atomic_fetch_add_acq_rel(delta: u64) -> u64 {
    var ticks: atomic<u64> = atomic.init(0);
    return ticks.fetch_add(delta, .acq_rel);
}

fn atomic_relaxed_load_store(value: bool) -> bool {
    var flag: atomic<bool> = atomic.init(false);
    flag.store(value, .relaxed);
    return flag.load(.relaxed);
}

fn reject_load_release() -> bool {
    var flag: atomic<bool> = atomic.init(false);
    // EXPECT_ERROR: E_ATOMIC_ORDERING
    return flag.load(.release);
}

fn reject_store_acquire(value: bool) -> void {
    var flag: atomic<bool> = atomic.init(false);
    // EXPECT_ERROR: E_ATOMIC_ORDERING
    flag.store(value, .acquire);
}

fn reject_fetch_add_bool() -> bool {
    var flag: atomic<bool> = atomic.init(false);
    // EXPECT_ERROR: E_ATOMIC_OPERATION
    return flag.fetch_add(true, .seq_cst);
}

fn reject_atomic_missing_order() -> bool {
    var flag: atomic<bool> = atomic.init(false);
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return flag.load();
}

fn reject_unknown_atomic_operation(value: bool) -> void {
    var flag: atomic<bool> = atomic.init(false);
    // EXPECT_ERROR: E_ATOMIC_OPERATION
    flag.swap(value, .seq_cst);
}
