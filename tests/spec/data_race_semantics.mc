// SPEC: section=17,I.13
// SPEC: milestone=ordinary-data-races
// SPEC: phase=sema,lower-c,lower-ir
// SPEC: expect=pass,inspect,reject
// SPEC: check=race-tolerant-lowering,no-happens-before,no-c-data-race-ub,race-ir-semantics,race-ir-no-ub

global shared_counter: u32 = 0;

fn local_non_racing_access() -> u32 {
    let local: u32 = 1;
    // EXPECT: lower-c may use normal C load/store because the object is proven local.
    return local + 1;
}

fn possibly_racing_store(x: u32) -> void {
    // EXPECT: ordinary store does not create synchronization.
    // EXPECT: lower-c uses a race-tolerant helper or rejects emission if none exists.
    shared_counter = x;
}

fn possibly_racing_load() -> u32 {
    // EXPECT: ordinary load result is target-defined if racing.
    // EXPECT: no happens-before edge is inferred.
    // EXPECT: optimizer must not assume this access cannot race.
    return shared_counter;
}

fn racing_increment_is_not_atomic() -> void {
    let x = possibly_racing_load();
    possibly_racing_store(x + 1);
    // EXPECT: this is a bug if concurrent, but it is not optimizer-license UB.
}
