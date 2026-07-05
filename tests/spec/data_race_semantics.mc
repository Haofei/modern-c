// SPEC: section=17,I.13
// SPEC: milestone=ordinary-data-races
// SPEC: phase=sema,lower-c,lower-ir
// SPEC: expect=pass,inspect,reject
// SPEC: check=race-tolerant-lowering,no-happens-before,no-c-data-race-ub,race-ir-semantics,race-ir-no-ub

global shared_counter: u32 = 0;

struct SharedPair {
    value: u32,
}

struct PointerHolder {
    ptr: *mut u32,
    tag: u32,
}

struct OuterHolder {
    inner: PointerHolder,
    tag: u32,
}

struct PointerArrayHolder {
    ptrs: [2]*mut u32,
    tag: u32,
}

struct PointerArrayHolder3 {
    ptrs: [3]*mut u32,
    tag: u32,
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

fn aggregate_global_pointer_field_load() -> u32 {
    let holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 1 };
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load through a local aggregate field proven to hold visible global storage.
    return p.*;
}

fn nested_aggregate_global_pointer_field_load() -> u32 {
    let outer: OuterHolder = .{ .inner = .{ .ptr = &shared_counter, .tag = 1 }, .tag = 2 };
    let p: *mut u32 = outer.inner.ptr;
    // EXPECT: lower-llvm emits unordered atomic load through a nested local aggregate field proven to hold visible global storage.
    return p.*;
}

fn aggregate_pointer_alias_global_pointer_field_load() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 12 };
    let hp: *mut PointerHolder = &holder;
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm emits unordered atomic load through a local aggregate pointer alias to a proven pointer field.
    return p.*;
}

fn nested_aggregate_pointer_alias_global_pointer_field_load() -> u32 {
    var outer: OuterHolder = .{ .inner = .{ .ptr = &shared_counter, .tag = 13 }, .tag = 14 };
    let op: *mut OuterHolder = &outer;
    let p: *mut u32 = op.inner.ptr;
    // EXPECT: lower-llvm emits unordered atomic load through a nested local aggregate pointer alias to a proven pointer field.
    return p.*;
}

fn nested_aggregate_assigned_global_pointer_field_load() -> u32 {
    var local: u32 = 13;
    var outer: OuterHolder = .{ .inner = .{ .ptr = &local, .tag = 3 }, .tag = 4 };
    outer.inner.ptr = &shared_counter;
    let p: *mut u32 = outer.inner.ptr;
    // EXPECT: lower-llvm emits unordered atomic load after direct nested aggregate pointer field assignment to visible global storage.
    return p.*;
}

fn aggregate_stack_pointer_field_stays_plain() -> u32 {
    var local: u32 = 9;
    let holder: PointerHolder = .{ .ptr = &local, .tag = 2 };
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps stack-backed aggregate pointer field derefs plain.
    return p.*;
}

fn nested_aggregate_stack_pointer_field_stays_plain() -> u32 {
    var local: u32 = 14;
    let outer: OuterHolder = .{ .inner = .{ .ptr = &local, .tag = 5 }, .tag = 6 };
    let p: *mut u32 = outer.inner.ptr;
    // EXPECT: lower-llvm keeps stack-backed nested aggregate pointer field derefs plain.
    return p.*;
}

fn aggregate_pointer_alias_stack_pointer_field_stays_plain() -> u32 {
    var local: u32 = 19;
    var holder: PointerHolder = .{ .ptr = &local, .tag = 15 };
    let hp: *mut PointerHolder = &holder;
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps stack-backed aggregate pointer field derefs through local aggregate pointer aliases plain.
    return p.*;
}

extern "C" fn external_pointer_holder() -> *mut PointerHolder;

fn aggregate_pointer_alias_field_assignment_clears_direct_field_fact() -> u32 {
    var local: u32 = 27;
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 29 };
    let hp: *mut PointerHolder = &holder;
    hp.ptr = &local;
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps direct aggregate field derefs plain after an alias write replaces global storage with stack storage.
    return p.*;
}

fn aggregate_pointer_alias_field_assignment_clears_alias_field_fact() -> u32 {
    var local: u32 = 28;
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 30 };
    let hp: *mut PointerHolder = &holder;
    hp.ptr = &local;
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps aggregate pointer alias field derefs plain after an alias write replaces global storage with stack storage.
    return p.*;
}

fn aggregate_pointer_alias_field_assignment_establishes_global_fact() -> u32 {
    var local: u32 = 29;
    var holder: PointerHolder = .{ .ptr = &local, .tag = 31 };
    let hp: *mut PointerHolder = &holder;
    hp.ptr = &shared_counter;
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load after an alias field assignment to visible global storage.
    return p.*;
}

fn aggregate_pointer_alias_returned_unknown_stays_plain() -> u32 {
    let hp: *mut PointerHolder = external_pointer_holder();
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps aggregate pointer fields through returned/external aggregate pointers plain.
    return p.*;
}

fn aggregate_pointer_param_field_stays_plain(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps direct aggregate pointer params plain because the pointee storage is ambiguous.
    return p.*;
}

fn aggregate_pointer_alias_reassigned_unknown_stays_plain() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 16 };
    var hp: *mut PointerHolder = &holder;
    hp = external_pointer_holder();
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm clears aggregate pointer alias facts after reassignment to an unknown aggregate pointer.
    return p.*;
}

fn aggregate_pointer_alias_reassigned_unknown_write_does_not_clear_old_field_fact() -> u32 {
    var local: u32 = 30;
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 32 };
    var hp: *mut PointerHolder = &holder;
    hp = external_pointer_holder();
    hp.ptr = &local;
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm does not mutate old local aggregate field facts after an alias is reassigned to unknown storage.
    return p.*;
}

fn aggregate_reassigned_stack_pointer_field_stays_plain() -> u32 {
    var local: u32 = 10;
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 3 };
    holder.ptr = &local;
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps aggregate pointer field derefs plain after reassignment to stack storage.
    return p.*;
}

fn nested_aggregate_reassigned_stack_pointer_field_stays_plain() -> u32 {
    var local: u32 = 15;
    var outer: OuterHolder = .{ .inner = .{ .ptr = &shared_counter, .tag = 7 }, .tag = 8 };
    outer.inner.ptr = &local;
    let p: *mut u32 = outer.inner.ptr;
    // EXPECT: lower-llvm keeps nested aggregate pointer field derefs plain after reassignment to stack storage.
    return p.*;
}

fn aggregate_whole_copy_pointer_field_load() -> u32 {
    let source: PointerHolder = .{ .ptr = &shared_counter, .tag = 4 };
    var local: u32 = 11;
    var holder: PointerHolder = .{ .ptr = &local, .tag = 5 };
    holder = source;
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load after direct local aggregate copy propagates proven pointer-field provenance.
    return p.*;
}

fn aggregate_init_copy_pointer_field_load() -> u32 {
    let source: PointerHolder = .{ .ptr = &shared_counter, .tag = 6 };
    let holder: PointerHolder = source;
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load after direct local aggregate init copy propagates proven pointer-field provenance.
    return p.*;
}

fn aggregate_whole_copy_stack_pointer_field_stays_plain() -> u32 {
    var local: u32 = 12;
    let source: PointerHolder = .{ .ptr = &local, .tag = 7 };
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 8 };
    holder = source;
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps whole-aggregate copies from stack-backed sources plain.
    return p.*;
}

fn returned_pointer_holder() -> PointerHolder {
    return .{ .ptr = &shared_counter, .tag = 9 };
}

fn aggregate_computed_copy_pointer_field_stays_plain() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 10 };
    holder = returned_pointer_holder();
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps computed aggregate assignment plain even when the callee body returns global storage.
    return p.*;
}

export fn exported_global_pointer() -> *mut u32 {
    return &shared_counter;
}

fn aggregate_exported_return_pointer_field_stays_plain() -> u32 {
    let holder: PointerHolder = .{ .ptr = exported_global_pointer(), .tag = 11 };
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps aggregate pointer field derefs plain when the field source is exported-return ambiguity.
    return p.*;
}

fn aggregate_array_global_pointer_element_load() -> u32 {
    let holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 17 };
    let p: *mut u32 = holder.ptrs[0];
    // EXPECT: lower-llvm emits unordered atomic load through a local aggregate array element proven to hold visible global storage.
    return p.*;
}

fn aggregate_array_assigned_global_pointer_element_load() -> u32 {
    var local: u32 = 20;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &local, &local }, .tag = 18 };
    holder.ptrs[0] = &shared_counter;
    let p: *mut u32 = holder.ptrs[0];
    // EXPECT: lower-llvm emits unordered atomic load after direct constant-index aggregate array element assignment to visible global storage.
    return p.*;
}

fn aggregate_array_stack_pointer_element_stays_plain() -> u32 {
    var local: u32 = 21;
    let holder: PointerArrayHolder = .{ .ptrs = .{ &local, &local }, .tag = 19 };
    let p: *mut u32 = holder.ptrs[0];
    // EXPECT: lower-llvm keeps stack-backed aggregate array pointer element derefs plain.
    return p.*;
}

fn aggregate_array_dynamic_index_all_global_pointer_elements_load(index: usize) -> u32 {
    let holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 20 };
    let p: *mut u32 = holder.ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-index aggregate array element when every possible element is proven to hold visible global storage.
    return p.*;
}

fn aggregate_array_dynamic_index_assigned_all_global_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 22;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &local, &local }, .tag = 21 };
    holder.ptrs[0] = &shared_counter;
    holder.ptrs[1] = &shared_counter;
    let p: *mut u32 = holder.ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-index aggregate array element after every constant element is assigned visible global storage.
    return p.*;
}

fn aggregate_array_dynamic_index_partial_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 23;
    let holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &local }, .tag = 22 };
    let p: *mut u32 = holder.ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-index aggregate array element when any possible element is proven to hold visible global storage.
    return p.*;
}

fn aggregate_array_dynamic_index_all_local_pointer_elements_stays_plain(index: usize) -> u32 {
    var local: u32 = 45;
    let holder: PointerArrayHolder = .{ .ptrs = .{ &local, &local }, .tag = 45 };
    let p: *mut u32 = holder.ptrs[index];
    // EXPECT: lower-llvm keeps dynamic-index aggregate array pointer element derefs plain when no possible element is proven to hold visible global storage.
    return p.*;
}

fn aggregate_array_dynamic_assignment_clears_pointer_element_fact(index: usize) -> u32 {
    var local: u32 = 24;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 23 };
    holder.ptrs[index] = &local;
    let dynamic_p: *mut u32 = holder.ptrs[index];
    let constant_p: *mut u32 = holder.ptrs[0];
    // EXPECT: lower-llvm keeps aggregate array pointer element derefs plain after unknown dynamic-index assignment.
    return dynamic_p.* + constant_p.*;
}

fn aggregate_pointer_alias_array_global_pointer_element_load() -> u32 {
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 24 };
    let hp: *mut PointerArrayHolder = &holder;
    let p: *mut u32 = hp.ptrs[0];
    // EXPECT: lower-llvm emits unordered atomic load through a local aggregate pointer alias to a proven array element.
    return p.*;
}

fn aggregate_pointer_alias_array_dynamic_index_all_global_pointer_elements_load(index: usize) -> u32 {
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 25 };
    let hp: *mut PointerArrayHolder = &holder;
    let p: *mut u32 = hp.ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-index aggregate pointer alias array element when every possible element is proven global-backed.
    return p.*;
}

fn aggregate_pointer_alias_array_stack_pointer_element_stays_plain() -> u32 {
    var local: u32 = 25;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &local, &local }, .tag = 26 };
    let hp: *mut PointerArrayHolder = &holder;
    let p: *mut u32 = hp.ptrs[0];
    // EXPECT: lower-llvm keeps stack-backed aggregate pointer alias array element derefs plain.
    return p.*;
}

fn aggregate_pointer_alias_array_dynamic_index_partial_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 26;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &local }, .tag = 27 };
    let hp: *mut PointerArrayHolder = &holder;
    let p: *mut u32 = hp.ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-index aggregate pointer alias array element when any possible element is proven global-backed.
    return p.*;
}

fn aggregate_pointer_alias_array_dynamic_index_all_local_pointer_elements_stays_plain(index: usize) -> u32 {
    var local: u32 = 46;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &local, &local }, .tag = 46 };
    let hp: *mut PointerArrayHolder = &holder;
    let p: *mut u32 = hp.ptrs[index];
    // EXPECT: lower-llvm keeps dynamic-index aggregate pointer alias array element derefs plain when no possible element is proven global-backed.
    return p.*;
}

extern "C" fn external_pointer_array_holder() -> *mut PointerArrayHolder;

fn aggregate_pointer_alias_array_assignment_clears_element_fact() -> u32 {
    var local: u32 = 31;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 33 };
    let hp: *mut PointerArrayHolder = &holder;
    hp.ptrs[0] = &local;
    let p: *mut u32 = holder.ptrs[0];
    // EXPECT: lower-llvm keeps direct aggregate array element derefs plain after an alias write replaces global storage with stack storage.
    return p.*;
}

fn aggregate_pointer_alias_array_dynamic_assignment_clears_all_element_facts(index: usize) -> u32 {
    var local: u32 = 32;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 34 };
    let hp: *mut PointerArrayHolder = &holder;
    hp.ptrs[index] = &local;
    let dynamic_p: *mut u32 = hp.ptrs[index];
    let constant_p: *mut u32 = holder.ptrs[0];
    // EXPECT: lower-llvm keeps aggregate pointer alias array derefs plain after unknown dynamic-index alias assignment.
    return dynamic_p.* + constant_p.*;
}

fn aggregate_pointer_alias_array_assignment_establishes_element_fact() -> u32 {
    var local: u32 = 33;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &local, &local }, .tag = 35 };
    let hp: *mut PointerArrayHolder = &holder;
    hp.ptrs[0] = &shared_counter;
    let p: *mut u32 = hp.ptrs[0];
    // EXPECT: lower-llvm emits unordered atomic load after an alias array element assignment to visible global storage.
    return p.*;
}

fn aggregate_pointer_alias_array_dynamic_index_assigned_all_global_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 34;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &local, &local }, .tag = 36 };
    let hp: *mut PointerArrayHolder = &holder;
    hp.ptrs[0] = &shared_counter;
    hp.ptrs[1] = &shared_counter;
    let p: *mut u32 = hp.ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-index aggregate pointer alias array element after every element is assigned visible global storage.
    return p.*;
}

fn aggregate_pointer_alias_array_dynamic_index_partially_assigned_load(index: usize) -> u32 {
    var local: u32 = 35;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &local, &local }, .tag = 37 };
    let hp: *mut PointerArrayHolder = &holder;
    hp.ptrs[0] = &shared_counter;
    let p: *mut u32 = hp.ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-index aggregate pointer alias array element when one assigned element is proven global-backed.
    return p.*;
}

fn aggregate_pointer_alias_array_returned_unknown_stays_plain() -> u32 {
    let hp: *mut PointerArrayHolder = external_pointer_array_holder();
    let p: *mut u32 = hp.ptrs[0];
    // EXPECT: lower-llvm keeps aggregate pointer alias array elements through returned/external aggregate pointers plain.
    return p.*;
}

fn aggregate_pointer_alias_array_reassigned_unknown_stays_plain() -> u32 {
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 28 };
    var hp: *mut PointerArrayHolder = &holder;
    hp = external_pointer_array_holder();
    let p: *mut u32 = hp.ptrs[0];
    // EXPECT: lower-llvm clears aggregate pointer alias array element facts after reassignment to an unknown aggregate pointer.
    return p.*;
}

fn aggregate_slice_global_pointer_element_load(index: usize) -> u32 {
    let holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 38 };
    let s: []mut *mut u32 = holder.ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a full-range local aggregate pointer-array field slice proven global-backed.
    return p.*;
}

fn aggregate_pointer_alias_slice_global_pointer_element_load(index: usize) -> u32 {
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 39 };
    let hp: *mut PointerArrayHolder = &holder;
    let s: []mut *mut u32 = hp.ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a full-range slice of a proven aggregate pointer alias array field.
    return p.*;
}

fn aggregate_slice_stack_pointer_element_stays_plain(index: usize) -> u32 {
    var local: u32 = 36;
    let holder: PointerArrayHolder = .{ .ptrs = .{ &local, &local }, .tag = 40 };
    let s: []mut *mut u32 = holder.ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps stack-backed aggregate pointer-array field slices plain.
    return p.*;
}

fn aggregate_slice_partial_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 48;
    let holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &local }, .tag = 48 };
    let s: []mut *mut u32 = holder.ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a full-range aggregate pointer-array field slice when any backing element is proven global-backed.
    return p.*;
}

fn aggregate_pointer_alias_slice_partial_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 49;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &local }, .tag = 49 };
    let hp: *mut PointerArrayHolder = &holder;
    let s: []mut *mut u32 = hp.ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a full-range aggregate pointer-alias slice when any backing element is proven global-backed.
    return p.*;
}

fn aggregate_slice_partial_constant_global_element_load() -> u32 {
    var local: u32 = 50;
    let holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &local }, .tag = 50 };
    let s: []mut *mut u32 = holder.ptrs[0..2];
    let p: *mut u32 = s[0];
    // EXPECT: lower-llvm keeps constant-index aggregate slice provenance exact for global-backed elements.
    return p.*;
}

fn aggregate_slice_partial_constant_stack_element_stays_plain() -> u32 {
    var local: u32 = 51;
    let holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &local }, .tag = 51 };
    let s: []mut *mut u32 = holder.ptrs[0..2];
    let p: *mut u32 = s[1];
    // EXPECT: lower-llvm keeps constant-index aggregate slice provenance exact for stack-backed elements.
    return p.*;
}

fn aggregate_slice_partial_range_stays_plain(index: usize) -> u32 {
    let holder: PointerArrayHolder3 = .{ .ptrs = .{ &shared_counter, &shared_counter, &shared_counter }, .tag = 41 };
    let s: []mut *mut u32 = holder.ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps partial aggregate pointer-array field slices plain even when every included element is global-backed.
    return p.*;
}

fn aggregate_slice_backing_array_assignment_clears_fact(index: usize) -> u32 {
    var local: u32 = 37;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 42 };
    let s: []mut *mut u32 = holder.ptrs[0..2];
    holder.ptrs[0] = &local;
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps aggregate pointer-array field slices plain after a backing field element write.
    return p.*;
}

fn aggregate_pointer_alias_slice_backing_assignment_clears_fact(index: usize) -> u32 {
    var local: u32 = 38;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 43 };
    let hp: *mut PointerArrayHolder = &holder;
    let s: []mut *mut u32 = hp.ptrs[0..2];
    hp.ptrs[index] = &local;
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps aggregate pointer-array field slices plain after a backing field element write through a local aggregate pointer alias.
    return p.*;
}

fn aggregate_slice_element_assignment_clears_fact(index: usize) -> u32 {
    var local: u32 = 39;
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 44 };
    let s: []mut *mut u32 = holder.ptrs[0..2];
    s[index] = &local;
    let slice_p: *mut u32 = s[index];
    let field_p: *mut u32 = holder.ptrs[0];
    // EXPECT: lower-llvm keeps both slice and aggregate field derefs plain after a write through the slice.
    return slice_p.* + field_p.*;
}

fn array_global_pointer_element_load() -> u32 {
    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    let p: *mut u32 = ptrs[0];
    // EXPECT: lower-llvm emits unordered atomic load through a local array element proven to hold visible global storage.
    return p.*;
}

fn array_assigned_global_pointer_element_load() -> u32 {
    var local: u32 = 16;
    var ptrs: [2]*mut u32 = .{ &local, &local };
    ptrs[0] = &shared_counter;
    let p: *mut u32 = ptrs[0];
    // EXPECT: lower-llvm emits unordered atomic load after direct constant-index local array element assignment to visible global storage.
    return p.*;
}

fn array_stack_pointer_element_stays_plain() -> u32 {
    var local: u32 = 17;
    let ptrs: [2]*mut u32 = .{ &local, &local };
    let p: *mut u32 = ptrs[0];
    // EXPECT: lower-llvm keeps stack-backed local array pointer element derefs plain.
    return p.*;
}

fn array_dynamic_index_all_global_pointer_elements_load(index: usize) -> u32 {
    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    let p: *mut u32 = ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-index local array element when every possible element is proven to hold visible global storage.
    return p.*;
}

fn array_dynamic_index_assigned_all_global_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 18;
    var ptrs: [2]*mut u32 = .{ &local, &local };
    ptrs[0] = &shared_counter;
    ptrs[1] = &shared_counter;
    let p: *mut u32 = ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-index local array element after every constant element is assigned visible global storage.
    return p.*;
}

fn array_dynamic_index_partial_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 19;
    let ptrs: [2]*mut u32 = .{ &shared_counter, &local };
    let p: *mut u32 = ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-index local array element when any possible element is proven to hold visible global storage.
    return p.*;
}

fn array_dynamic_index_all_local_pointer_elements_stays_plain(index: usize) -> u32 {
    var local: u32 = 47;
    let ptrs: [2]*mut u32 = .{ &local, &local };
    let p: *mut u32 = ptrs[index];
    // EXPECT: lower-llvm keeps dynamic-index local array pointer element derefs plain when no possible element is proven to hold visible global storage.
    return p.*;
}

fn array_dynamic_assignment_clears_pointer_element_fact(index: usize) -> u32 {
    var local: u32 = 20;
    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    ptrs[index] = &local;
    let dynamic_p: *mut u32 = ptrs[index];
    let constant_p: *mut u32 = ptrs[0];
    // EXPECT: lower-llvm keeps local array pointer element derefs plain after unknown dynamic-index assignment.
    return dynamic_p.* + constant_p.*;
}

fn pointer_to_array_dynamic_index_all_global_pointer_elements_load(index: usize) -> u32 {
    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    let pa: *mut [2]*mut u32 = &ptrs;
    let p: *mut u32 = pa.*[index];
    // EXPECT: lower-llvm emits unordered atomic load through a local pointer-to-array when every possible backing element is proven global-backed.
    return p.*;
}

fn pointer_to_array_stack_pointer_elements_stays_plain(index: usize) -> u32 {
    var local: u32 = 21;
    var ptrs: [2]*mut u32 = .{ &local, &local };
    let pa: *mut [2]*mut u32 = &ptrs;
    let p: *mut u32 = pa.*[index];
    // EXPECT: lower-llvm keeps stack-backed local pointer-to-array element derefs plain.
    return p.*;
}

fn pointer_to_array_partial_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 22;
    var ptrs: [2]*mut u32 = .{ &shared_counter, &local };
    let pa: *mut [2]*mut u32 = &ptrs;
    let p: *mut u32 = pa.*[index];
    // EXPECT: lower-llvm emits unordered atomic load through a local pointer-to-array when any possible backing element is proven global-backed.
    return p.*;
}

fn pointer_to_array_reassigned_pointer_stays_plain(index: usize) -> u32 {
    var local: u32 = 23;
    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    var other: [2]*mut u32 = .{ &local, &local };
    var pa: *mut [2]*mut u32 = &ptrs;
    pa = &other;
    let p: *mut u32 = pa.*[index];
    // EXPECT: lower-llvm keeps local pointer-to-array derefs plain after the pointer-to-array local is reassigned.
    return p.*;
}

fn pointer_to_array_backing_array_write_clears_fact(index: usize) -> u32 {
    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    let pa: *mut [2]*mut u32 = &ptrs;
    ptrs[0] = &shared_counter;
    let p: *mut u32 = pa.*[index];
    // EXPECT: lower-llvm keeps local pointer-to-array derefs plain after a direct backing array write.
    return p.*;
}

fn slice_global_pointer_element_load(index: usize) -> u32 {
    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    let s: []mut *mut u32 = ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a local slice proven to cover a global-backed local pointer array.
    return p.*;
}

fn slice_assigned_global_pointer_element_load(index: usize) -> u32 {
    var local: u32 = 21;
    var ptrs: [2]*mut u32 = .{ &local, &local };
    ptrs[0] = &shared_counter;
    ptrs[1] = &shared_counter;
    let s: []mut *mut u32 = ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a local slice after every backing array element is assigned visible global storage.
    return p.*;
}

fn slice_stack_pointer_element_stays_plain(index: usize) -> u32 {
    var local: u32 = 22;
    let ptrs: [2]*mut u32 = .{ &local, &local };
    let s: []mut *mut u32 = ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps stack-backed local pointer slices plain.
    return p.*;
}

fn slice_partial_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 23;
    let ptrs: [2]*mut u32 = .{ &shared_counter, &local };
    let s: []mut *mut u32 = ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a full-range local pointer slice when any backing element is proven global-backed.
    return p.*;
}

fn slice_partial_constant_global_element_load() -> u32 {
    var local: u32 = 29;
    let ptrs: [2]*mut u32 = .{ &shared_counter, &local };
    let s: []mut *mut u32 = ptrs[0..2];
    let p: *mut u32 = s[0];
    // EXPECT: lower-llvm keeps constant-index local slice provenance exact for global-backed elements.
    return p.*;
}

fn slice_partial_constant_stack_element_stays_plain() -> u32 {
    var local: u32 = 30;
    let ptrs: [2]*mut u32 = .{ &shared_counter, &local };
    let s: []mut *mut u32 = ptrs[0..2];
    let p: *mut u32 = s[1];
    // EXPECT: lower-llvm keeps constant-index local slice provenance exact for stack-backed elements.
    return p.*;
}

fn slice_backing_array_assignment_clears_fact(index: usize) -> u32 {
    var local: u32 = 24;
    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    let s: []mut *mut u32 = ptrs[0..2];
    ptrs[0] = &local;
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps local pointer slices plain after a direct backing array write.
    return p.*;
}

fn slice_backing_array_dynamic_assignment_clears_fact(index: usize) -> u32 {
    var local: u32 = 25;
    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    let s: []mut *mut u32 = ptrs[0..2];
    ptrs[index] = &local;
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps local pointer slices plain after a dynamic backing array write.
    return p.*;
}

fn slice_backing_array_whole_assignment_clears_fact(index: usize) -> u32 {
    var local: u32 = 26;
    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    let s: []mut *mut u32 = ptrs[0..2];
    ptrs = .{ &local, &local };
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps local pointer slices plain after a whole backing array assignment.
    return p.*;
}

fn slice_element_assignment_clears_fact(index: usize) -> u32 {
    var local: u32 = 27;
    var ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    let s: []mut *mut u32 = ptrs[0..2];
    s[index] = &local;
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps local pointer slices plain after a write through the slice.
    return p.*;
}

fn slice_reassignment_clears_fact(index: usize) -> u32 {
    var local: u32 = 28;
    let ptrs: [2]*mut u32 = .{ &shared_counter, &shared_counter };
    let other: [2]*mut u32 = .{ &local, &local };
    var s: []mut *mut u32 = ptrs[0..2];
    s = other[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps local pointer slices plain after slice reassignment to unproven storage.
    return p.*;
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
