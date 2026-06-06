// SPEC: section=17,I.13
// SPEC: milestone=ordinary-data-races
// SPEC: phase=sema,lower-c,lower-ir
// SPEC: expect=pass,inspect,reject
// SPEC: check=race-tolerant-lowering,no-happens-before,no-c-data-race-ub,race-ir-semantics,race-ir-no-ub

global shared_counter: u32 = 0;

struct SharedPair {
    value: u32,
}

global shared_pair: SharedPair;
global shared_values: [4]u32;

fn local_non_racing_access() -> u32 {
    var local: u32 = 1;
    local = local + 1;
    // EXPECT: lower-c may use normal C load/store because the object is proven local.
    return local;
}

fn possibly_racing_store(x: u32) -> void {
    // EXPECT: ordinary store does not create synchronization.
    // EXPECT: lower-c emits mc_race_store_u32(&shared_counter, value) or rejects emission if helper support is missing.
    shared_counter = x;
}

fn possibly_racing_load() -> u32 {
    // EXPECT: lower-c emits mc_race_load_u32(&shared_counter) or rejects emission if helper support is missing.
    // EXPECT: ordinary load result is target-defined if racing.
    // EXPECT: racing load may tear according to target width/alignment.
    // EXPECT: no happens-before edge is inferred.
    // EXPECT: optimizer must not assume this access cannot race.
    return shared_counter;
}

fn possibly_racing_field_store(x: u32) -> void {
    // EXPECT: lower-c emits mc_race_store_u32(&shared_pair.value, value) rather than a plain C field store.
    shared_pair.value = x;
}

fn possibly_racing_field_load() -> u32 {
    // EXPECT: lower-c emits mc_race_load_u32(&shared_pair.value) rather than loading the whole aggregate or using a plain C field load.
    return shared_pair.value;
}

fn possibly_racing_array_store(index: usize, value: u32) -> void {
    // EXPECT: lower-c emits mc_race_store_u32(&shared_values[checked_index], value) rather than loading the whole aggregate or using a plain C element store.
    shared_values[index] = value;
}

fn possibly_racing_array_load(index: usize) -> u32 {
    // EXPECT: lower-c emits mc_race_load_u32(&shared_values[checked_index]) rather than loading the whole aggregate or using a plain C element load.
    return shared_values[index];
}

fn racing_increment_is_not_atomic() -> void {
    let x = possibly_racing_load();
    possibly_racing_store(x + 1);
    // EXPECT: this is a bug if concurrent, but it is not optimizer-license UB.
    // EXPECT: the load/store pair is not an atomic read-modify-write.
}
