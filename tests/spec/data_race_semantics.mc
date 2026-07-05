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

fn possibly_racing_pointer_store(x: u32) -> void {
    let gp: *mut u32 = &shared_counter;
    let copy: *mut u32 = gp;
    // EXPECT: lower-llvm emits unordered atomic store through a pointer proven to name global storage.
    copy.* = x;
}

fn possibly_racing_pointer_load() -> u32 {
    let gp: *mut u32 = &shared_counter;
    // EXPECT: lower-llvm emits unordered atomic load through a pointer proven to name global storage.
    return gp.*;
}

fn possibly_racing_direct_address_deref_load() -> u32 {
    // EXPECT: lower-llvm emits unordered atomic load for direct address-of global deref.
    return (&shared_counter).*;
}

fn returned_global_pointer() -> *mut u32 {
    return &shared_counter;
}

fn possibly_racing_returned_pointer_load() -> u32 {
    let gp: *mut u32 = returned_global_pointer();
    // EXPECT: lower-llvm emits unordered atomic load through a pointer returned by a helper proven to return global storage.
    return gp.*;
}

fn consume_global_param(p: *mut u32) -> u32 {
    // EXPECT: lower-llvm emits unordered atomic load because every direct call passes visible global storage.
    return p.*;
}

fn possibly_racing_param_pointer_load() -> u32 {
    return consume_global_param(&shared_counter);
}

fn consume_mixed_param(p: *mut u32) -> u32 {
    // EXPECT: lower-llvm keeps this plain because at least one direct call passes stack storage.
    return p.*;
}

fn call_mixed_param_with_global() -> u32 {
    return consume_mixed_param(&shared_counter);
}

fn call_mixed_param_with_local() -> u32 {
    var local: u32 = 7;
    return consume_mixed_param(&local);
}

fn consume_local_only_param(p: *mut u32) -> u32 {
    // EXPECT: lower-llvm keeps this plain because all direct calls pass stack storage.
    return p.*;
}

fn call_local_only_param() -> u32 {
    var local: u32 = 8;
    return consume_local_only_param(&local);
}

fn local_pointer_deref_stays_plain() -> u32 {
    var local: u32 = 5;
    let lp: *mut u32 = &local;
    lp.* = 6;
    // EXPECT: lower-llvm keeps stack pointer derefs plain.
    return lp.*;
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
