// A global of a wrap<T>/sat<T> arithmetic domain is stored as its underlying integer, so its
// race-safe load/store must resolve to that integer's scalar helper (mc_race_load_u64), not a
// nonexistent mc_race_*_unknown. Regression for a C-backend codegen bug found by the
// differential program fuzzer: such a global previously emitted uncompilable C while the LLVM
// backend lowered it fine.
type Counter = wrap<u64>;
type Level = sat<u32>;

global g_counter: Counter;
global g_level: Level;
global g_counters: [4]Counter;

export fn bump_counter() -> u64 {
    g_counter = g_counter + Counter.from(1);
    return g_counter as u64;
}

export fn saturate_level() -> u32 {
    g_level = g_level + Level.from(1);
    return g_level as u32;
}

export fn bump_slot(i: usize) -> u64 {
    g_counters[i] = g_counters[i] + Counter.from(1);
    return g_counters[i] as u64;
}
