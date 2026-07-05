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

fn consume_indirect_global_param(p: *mut u32) -> u32 {
    // EXPECT: lower-llvm emits unordered atomic load because every local function-pointer alias call passes visible global storage.
    return p.*;
}

fn call_indirect_global_param_alias() -> u32 {
    let f: fn(*mut u32) -> u32 = consume_indirect_global_param;
    return f(&shared_counter);
}

fn consume_alias_copy_param(p: *mut u32) -> u32 {
    // EXPECT: lower-llvm emits unordered atomic load because a local function-pointer alias copy preserves the internal target.
    return p.*;
}

fn call_indirect_alias_copy_param() -> u32 {
    let f: fn(*mut u32) -> u32 = consume_alias_copy_param;
    let g: fn(*mut u32) -> u32 = f;
    return g(&shared_counter);
}

fn consume_indirect_reassigned_param(p: *mut u32) -> u32 {
    // EXPECT: lower-llvm keeps this plain because the local function-pointer alias is reassigned before the indirect call.
    return p.*;
}

fn consume_indirect_reassigned_other_param(p: *mut u32) -> u32 {
    // EXPECT: lower-llvm keeps the reassignment target plain too; reassigned aliases do not prove either target.
    return p.*;
}

fn call_indirect_reassigned_param_alias() -> u32 {
    var f: fn(*mut u32) -> u32 = consume_indirect_reassigned_param;
    f = consume_indirect_reassigned_other_param;
    return f(&shared_counter);
}

fn consume_alias_copy_reassigned_param(p: *mut u32) -> u32 {
    // EXPECT: lower-llvm keeps this plain because the copied local function-pointer alias is reassigned before the indirect call.
    return p.*;
}

fn consume_alias_copy_reassigned_other_param(p: *mut u32) -> u32 {
    // EXPECT: lower-llvm keeps the copied alias reassignment target plain too; reassigned aliases do not prove either target.
    return p.*;
}

fn call_indirect_alias_copy_reassigned_param() -> u32 {
    let f: fn(*mut u32) -> u32 = consume_alias_copy_reassigned_param;
    var g: fn(*mut u32) -> u32 = f;
    g = consume_alias_copy_reassigned_other_param;
    return g(&shared_counter);
}

fn consume_alias_copy_escape_param(p: *mut u32) -> u32 {
    // EXPECT: lower-llvm keeps this plain because a copied local function-pointer alias escapes as a value.
    return p.*;
}

fn escape_scalar_param_callback(f: fn(*mut u32) -> u32) -> void {
    return;
}

fn call_indirect_alias_copy_escape_param() -> u32 {
    let f: fn(*mut u32) -> u32 = consume_alias_copy_escape_param;
    let g: fn(*mut u32) -> u32 = f;
    escape_scalar_param_callback(g);
    return g(&shared_counter);
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
    // EXPECT: lower-llvm keeps uncalled aggregate pointer params plain because the pointee storage is ambiguous.
    return p.*;
}

fn consume_aggregate_global_param(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm emits unordered atomic load because every direct call passes a local aggregate whose pointer field is global-backed.
    return p.*;
}

fn call_aggregate_global_param() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 33 };
    return consume_aggregate_global_param(&holder);
}

fn consume_aggregate_array_global_param(hp: *mut PointerArrayHolder, index: usize) -> u32 {
    let p: *mut u32 = hp.ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load through a proven aggregate pointer param array field.
    return p.*;
}

fn call_aggregate_array_global_param(index: usize) -> u32 {
    var holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 34 };
    return consume_aggregate_array_global_param(&holder, index);
}

fn consume_aggregate_mixed_param(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps aggregate pointer params plain when any direct call passes local-backed pointer fields.
    return p.*;
}

fn call_aggregate_mixed_param_with_global() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 35 };
    return consume_aggregate_mixed_param(&holder);
}

fn call_aggregate_mixed_param_with_local() -> u32 {
    var local: u32 = 31;
    var holder: PointerHolder = .{ .ptr = &local, .tag = 36 };
    return consume_aggregate_mixed_param(&holder);
}

fn consume_aggregate_unknown_address_param(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps aggregate pointer params plain when a direct call passes unknown aggregate storage.
    return p.*;
}

fn call_aggregate_unknown_address_param() -> u32 {
    return consume_aggregate_unknown_address_param(external_pointer_holder());
}

fn consume_indirect_aggregate_alias_param(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm emits unordered atomic load because a local function-pointer alias call passes a local aggregate whose pointer field is global-backed.
    return p.*;
}

fn call_indirect_aggregate_alias_param() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 41 };
    let f: fn(*mut PointerHolder) -> u32 = consume_indirect_aggregate_alias_param;
    return f(&holder);
}

fn consume_aggregate_alias_copy_param(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm emits unordered atomic load because a local aggregate-param function-pointer alias copy preserves the internal target.
    return p.*;
}

fn call_indirect_aggregate_alias_copy_param() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 43 };
    let f: fn(*mut PointerHolder) -> u32 = consume_aggregate_alias_copy_param;
    let g: fn(*mut PointerHolder) -> u32 = f;
    return g(&holder);
}

fn consume_aggregate_alias_copy_escape_param(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps this plain because a copied aggregate-param function-pointer alias escapes as a value.
    return p.*;
}

fn call_indirect_aggregate_alias_copy_escape_param() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 44 };
    let f: fn(*mut PointerHolder) -> u32 = consume_aggregate_alias_copy_escape_param;
    let g: fn(*mut PointerHolder) -> u32 = f;
    escape_aggregate_param_callback(g);
    return g(&holder);
}

fn consume_indirect_aggregate_reassigned_param(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps this plain because the aggregate-param function-pointer alias is reassigned before the indirect call.
    return p.*;
}

fn consume_indirect_aggregate_reassigned_other_param(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps the reassignment target plain too; reassigned aggregate-param aliases do not prove either target.
    return p.*;
}

fn call_indirect_aggregate_reassigned_param() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 42 };
    var f: fn(*mut PointerHolder) -> u32 = consume_indirect_aggregate_reassigned_param;
    f = consume_indirect_aggregate_reassigned_other_param;
    return f(&holder);
}

fn consume_aggregate_indirect_escape_param(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps aggregate pointer params plain when the local function-pointer alias escapes.
    return p.*;
}

fn escape_aggregate_param_callback(f: fn(*mut PointerHolder) -> u32) -> void {
    return;
}

fn call_aggregate_indirect_escape_param_direct() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 39 };
    return consume_aggregate_indirect_escape_param(&holder);
}

fn call_aggregate_indirect_escape_param_indirect() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 40 };
    let f: fn(*mut PointerHolder) -> u32 = consume_aggregate_indirect_escape_param;
    escape_aggregate_param_callback(f);
    return f(&holder);
}

fn consume_aggregate_param_write_clears(hp: *mut PointerHolder) -> u32 {
    hp.ptr = exported_global_pointer();
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm clears aggregate pointer param field facts after writes through the param.
    return p.*;
}

fn call_aggregate_param_write_clears() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 37 };
    return consume_aggregate_param_write_clears(&holder);
}

export fn exported_aggregate_global_param_stays_plain(hp: *mut PointerHolder) -> u32 {
    let p: *mut u32 = hp.ptr;
    // EXPECT: lower-llvm keeps exported aggregate pointer params plain even if direct calls pass global-backed fields.
    return p.*;
}

fn call_exported_aggregate_global_param() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 38 };
    return exported_aggregate_global_param_stays_plain(&holder);
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

fn returned_pointer_holder_via_local() -> PointerHolder {
    let holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 60 };
    return holder;
}

fn returned_pointer_holder_via_assignment() -> PointerHolder {
    var local: u32 = 61;
    var holder: PointerHolder = .{ .ptr = &local, .tag = 61 };
    holder = .{ .ptr = &shared_counter, .tag = 62 };
    return holder;
}

fn returned_pointer_holder_via_if(cond: bool) -> PointerHolder {
    if cond {
        return .{ .ptr = &shared_counter, .tag = 64 };
    }
    return .{ .ptr = &shared_counter, .tag = 65 };
}

fn returned_pointer_holder_via_mixed_if_else(cond: bool, fallback: *mut u32) -> PointerHolder {
    if cond {
        return .{ .ptr = &shared_counter, .tag = 66 };
    } else {
        return .{ .ptr = fallback, .tag = 67 };
    }
}

fn returned_pointer_holder_via_branch_local_if(cond: bool) -> PointerHolder {
    if cond {
        let holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 69 };
        return holder;
    }
    let other: PointerHolder = .{ .ptr = &shared_counter, .tag = 70 };
    return other;
}

fn returned_pointer_holder_via_mixed_branch_local_if(cond: bool) -> PointerHolder {
    if cond {
        let holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 71 };
        return holder;
    }
    var local: u32 = 72;
    let other: PointerHolder = .{ .ptr = &local, .tag = 72 };
    return other;
}

fn returned_pointer_holder_via_switch(choice: u32) -> PointerHolder {
    switch choice {
        0 => {
            return .{ .ptr = &shared_counter, .tag = 73 };
        }
        _ => {
            let holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 74 };
            return holder;
        }
    }
}

fn returned_pointer_holder_via_mixed_switch(choice: u32) -> PointerHolder {
    switch choice {
        0 => {
            return .{ .ptr = &shared_counter, .tag = 75 };
        }
        _ => {
            var local: u32 = 76;
            let holder: PointerHolder = .{ .ptr = &local, .tag = 76 };
            return holder;
        }
    }
}

fn returned_pointer_holder_after_side_effect() -> PointerHolder {
    let noise: u32 = shared_counter;
    return .{ .ptr = &shared_counter, .tag = noise };
}

fn returned_pointer_holder_via_local_after_noise() -> PointerHolder {
    let noise: u32 = shared_counter;
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = noise };
    return holder;
}

fn returned_pointer_holder_via_local_reassigned_stack_after_noise() -> PointerHolder {
    let noise: u32 = shared_counter;
    var local: u32 = 77;
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = noise };
    holder = .{ .ptr = &local, .tag = 77 };
    return holder;
}

fn returned_pointer_holder_after_unknown_call() -> PointerHolder {
    let hp: *mut PointerHolder = external_pointer_holder();
    return .{ .ptr = &shared_counter, .tag = 78 };
}

fn aggregate_computed_copy_pointer_field_load() -> u32 {
    var holder: PointerHolder = .{ .ptr = &shared_counter, .tag = 10 };
    holder = returned_pointer_holder();
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load after aggregate assignment from a summarized internal return.
    return p.*;
}

fn aggregate_return_init_pointer_field_load() -> u32 {
    let holder: PointerHolder = returned_pointer_holder();
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load after aggregate initialization from a summarized internal return.
    return p.*;
}

fn aggregate_return_local_init_pointer_field_load() -> u32 {
    let holder: PointerHolder = returned_pointer_holder_via_local();
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load after aggregate initialization from a summarized internal local return.
    return p.*;
}

fn aggregate_return_local_assignment_pointer_field_load() -> u32 {
    let holder: PointerHolder = returned_pointer_holder_via_assignment();
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load after aggregate initialization from a summarized internal assigned local return.
    return p.*;
}

fn aggregate_return_if_pointer_field_load(cond: bool) -> u32 {
    let holder: PointerHolder = returned_pointer_holder_via_if(cond);
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load when all simple if return paths summarize the field as global-backed.
    return p.*;
}

fn aggregate_return_mixed_if_pointer_field_stays_plain(cond: bool) -> u32 {
    var local: u32 = 68;
    let holder: PointerHolder = returned_pointer_holder_via_mixed_if_else(cond, &local);
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps a returned aggregate field plain when simple if branches have mixed global/unknown provenance.
    return p.*;
}

fn aggregate_return_branch_local_if_pointer_field_load(cond: bool) -> u32 {
    let holder: PointerHolder = returned_pointer_holder_via_branch_local_if(cond);
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load when all simple branch-local aggregate return paths prove the field global-backed.
    return p.*;
}

fn aggregate_return_mixed_branch_local_if_pointer_field_stays_plain(cond: bool) -> u32 {
    let holder: PointerHolder = returned_pointer_holder_via_mixed_branch_local_if(cond);
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps returned branch-local aggregate fields plain when any path is stack-backed.
    return p.*;
}

fn aggregate_return_switch_pointer_field_load(choice: u32) -> u32 {
    let holder: PointerHolder = returned_pointer_holder_via_switch(choice);
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load when all simple switch return arms prove the field global-backed.
    return p.*;
}

fn aggregate_return_mixed_switch_pointer_field_stays_plain(choice: u32) -> u32 {
    let holder: PointerHolder = returned_pointer_holder_via_mixed_switch(choice);
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps returned switch aggregate fields plain when any arm is stack-backed.
    return p.*;
}

fn aggregate_return_prereturn_literal_pointer_field_load() -> u32 {
    let holder: PointerHolder = returned_pointer_holder_after_side_effect();
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load when simple pre-return reads do not affect returned aggregate provenance.
    return p.*;
}

fn aggregate_return_prereturn_local_pointer_field_load() -> u32 {
    let holder: PointerHolder = returned_pointer_holder_via_local_after_noise();
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm emits unordered atomic load when a pre-return local aggregate remains proven global-backed.
    return p.*;
}

fn aggregate_return_prereturn_reassigned_stack_pointer_field_stays_plain() -> u32 {
    let holder: PointerHolder = returned_pointer_holder_via_local_reassigned_stack_after_noise();
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps a returned aggregate field plain when pre-return code overwrites it with stack-backed data.
    return p.*;
}

fn aggregate_return_prereturn_unknown_call_pointer_field_stays_plain() -> u32 {
    let holder: PointerHolder = returned_pointer_holder_after_unknown_call();
    let p: *mut u32 = holder.ptr;
    // EXPECT: lower-llvm keeps returned aggregate fields plain when an unknown pre-return call prevents provenance proof.
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

fn returned_pointer_array_holder() -> PointerArrayHolder {
    return .{ .ptrs = .{ &shared_counter, exported_global_pointer() }, .tag = 16 };
}

fn returned_pointer_array_holder_via_local() -> PointerArrayHolder {
    let holder: PointerArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter }, .tag = 63 };
    return holder;
}

fn aggregate_return_array_dynamic_index_pointer_element_load(index: usize) -> u32 {
    let holder: PointerArrayHolder = returned_pointer_array_holder();
    let p: *mut u32 = holder.ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load for a dynamic read from a returned aggregate array with a summarized global-backed element.
    return p.*;
}

fn aggregate_return_array_local_dynamic_index_pointer_element_load(index: usize) -> u32 {
    let holder: PointerArrayHolder = returned_pointer_array_holder_via_local();
    let p: *mut u32 = holder.ptrs[index];
    // EXPECT: lower-llvm emits unordered atomic load for a dynamic read from a returned local aggregate array with summarized global-backed elements.
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

fn aggregate_slice_partial_range_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 52;
    let holder: PointerArrayHolder3 = .{ .ptrs = .{ &local, &shared_counter, &local }, .tag = 41 };
    let s: []mut *mut u32 = holder.ptrs[0..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a constant partial-range aggregate pointer-array field slice when any included backing element is proven global-backed.
    return p.*;
}

fn aggregate_pointer_alias_slice_partial_range_pointer_elements_load(index: usize) -> u32 {
    var local: u32 = 53;
    var holder: PointerArrayHolder3 = .{ .ptrs = .{ &local, &shared_counter, &local }, .tag = 52 };
    let hp: *mut PointerArrayHolder3 = &holder;
    let s: []mut *mut u32 = hp.ptrs[1..3];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a constant partial-range aggregate pointer-alias slice when any included backing element is proven global-backed.
    return p.*;
}

fn aggregate_slice_partial_range_constant_global_element_load() -> u32 {
    var local: u32 = 54;
    let holder: PointerArrayHolder3 = .{ .ptrs = .{ &local, &shared_counter, &local }, .tag = 53 };
    let s: []mut *mut u32 = holder.ptrs[1..3];
    let p: *mut u32 = s[0];
    // EXPECT: lower-llvm maps constant-index partial aggregate slices to the backing global-backed element.
    return p.*;
}

fn aggregate_slice_partial_range_constant_stack_element_stays_plain() -> u32 {
    var local: u32 = 55;
    let holder: PointerArrayHolder3 = .{ .ptrs = .{ &local, &shared_counter, &local }, .tag = 54 };
    let s: []mut *mut u32 = holder.ptrs[1..3];
    let p: *mut u32 = s[1];
    // EXPECT: lower-llvm maps constant-index partial aggregate slices to the backing stack-backed element.
    return p.*;
}

fn aggregate_slice_partial_range_all_local_stays_plain(index: usize) -> u32 {
    var a: u32 = 56;
    var b: u32 = 57;
    var c: u32 = 58;
    let holder: PointerArrayHolder3 = .{ .ptrs = .{ &a, &b, &c }, .tag = 55 };
    let s: []mut *mut u32 = holder.ptrs[1..3];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps all-local partial aggregate pointer-array field slices plain.
    return p.*;
}

fn aggregate_slice_dynamic_end_pointer_elements_load(index: usize, end: usize) -> u32 {
    var a: u32 = 59;
    var b: u32 = 60;
    let holder: PointerArrayHolder3 = .{ .ptrs = .{ &a, &shared_counter, &b }, .tag = 56 };
    let s: []mut *mut u32 = holder.ptrs[1..end];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a constant-start dynamic-end aggregate pointer-array field slice when any possible backing element is proven global-backed.
    return p.*;
}

fn aggregate_pointer_alias_slice_dynamic_end_pointer_elements_load(index: usize, end: usize) -> u32 {
    var a: u32 = 61;
    var b: u32 = 62;
    var holder: PointerArrayHolder3 = .{ .ptrs = .{ &a, &shared_counter, &b }, .tag = 57 };
    let hp: *mut PointerArrayHolder3 = &holder;
    let s: []mut *mut u32 = hp.ptrs[1..end];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a constant-start dynamic-end aggregate pointer-alias slice when any possible backing element is proven global-backed.
    return p.*;
}

fn aggregate_slice_dynamic_start_pointer_elements_load(start: usize, index: usize) -> u32 {
    var a: u32 = 70;
    var b: u32 = 71;
    let holder: PointerArrayHolder3 = .{ .ptrs = .{ &a, &shared_counter, &b }, .tag = 58 };
    let s: []mut *mut u32 = holder.ptrs[start..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-start aggregate pointer-array field slice when any possible backing element is proven global-backed.
    return p.*;
}

fn aggregate_pointer_alias_slice_fully_dynamic_pointer_elements_load(start: usize, end: usize, index: usize) -> u32 {
    var a: u32 = 72;
    var b: u32 = 73;
    var holder: PointerArrayHolder3 = .{ .ptrs = .{ &a, &b, &shared_counter }, .tag = 59 };
    let hp: *mut PointerArrayHolder3 = &holder;
    let s: []mut *mut u32 = hp.ptrs[start..end];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a fully dynamic aggregate pointer-alias slice when any possible backing element is proven global-backed.
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

fn slice_partial_range_pointer_elements_load(index: usize) -> u32 {
    var a: u32 = 52;
    var b: u32 = 53;
    let ptrs: [3]*mut u32 = .{ &a, &shared_counter, &b };
    let s: []mut *mut u32 = ptrs[1..3];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a constant partial-range local pointer slice when any included backing element is proven global-backed.
    return p.*;
}

fn slice_partial_range_constant_global_element_load() -> u32 {
    var a: u32 = 54;
    var b: u32 = 55;
    let ptrs: [3]*mut u32 = .{ &a, &shared_counter, &b };
    let s: []mut *mut u32 = ptrs[1..3];
    let p: *mut u32 = s[0];
    // EXPECT: lower-llvm maps constant-index partial local slices to the backing global-backed element.
    return p.*;
}

fn slice_partial_range_constant_stack_element_stays_plain() -> u32 {
    var a: u32 = 56;
    var b: u32 = 57;
    let ptrs: [3]*mut u32 = .{ &a, &shared_counter, &b };
    let s: []mut *mut u32 = ptrs[1..3];
    let p: *mut u32 = s[1];
    // EXPECT: lower-llvm maps constant-index partial local slices to the backing stack-backed element.
    return p.*;
}

fn slice_partial_range_all_local_stays_plain(index: usize) -> u32 {
    var a: u32 = 58;
    var b: u32 = 59;
    var c: u32 = 60;
    let ptrs: [3]*mut u32 = .{ &a, &b, &c };
    let s: []mut *mut u32 = ptrs[1..3];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps all-local partial local pointer slices plain.
    return p.*;
}

fn slice_dynamic_end_partial_pointer_elements_load(index: usize, end: usize) -> u32 {
    var a: u32 = 61;
    var b: u32 = 62;
    let ptrs: [3]*mut u32 = .{ &a, &shared_counter, &b };
    let s: []mut *mut u32 = ptrs[1..end];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a constant-start dynamic-end local pointer slice when any possible backing element is proven global-backed.
    return p.*;
}

fn slice_dynamic_end_constant_global_element_load(end: usize) -> u32 {
    var a: u32 = 63;
    var b: u32 = 64;
    let ptrs: [3]*mut u32 = .{ &a, &shared_counter, &b };
    let s: []mut *mut u32 = ptrs[1..end];
    let p: *mut u32 = s[0];
    // EXPECT: lower-llvm maps constant-index dynamic-end local slices to the backing global-backed element.
    return p.*;
}

fn slice_dynamic_end_constant_stack_element_stays_plain(end: usize) -> u32 {
    var a: u32 = 65;
    var b: u32 = 66;
    let ptrs: [3]*mut u32 = .{ &a, &b, &shared_counter };
    let s: []mut *mut u32 = ptrs[1..end];
    let p: *mut u32 = s[0];
    // EXPECT: lower-llvm maps constant-index dynamic-end local slices to the backing stack-backed element.
    return p.*;
}

fn slice_dynamic_end_all_local_stays_plain(index: usize, end: usize) -> u32 {
    var a: u32 = 67;
    var b: u32 = 68;
    var c: u32 = 69;
    let ptrs: [3]*mut u32 = .{ &a, &b, &c };
    let s: []mut *mut u32 = ptrs[1..end];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps all-local constant-start dynamic-end local pointer slices plain.
    return p.*;
}

fn slice_dynamic_start_pointer_elements_load(start: usize, index: usize) -> u32 {
    var a: u32 = 70;
    var b: u32 = 71;
    let ptrs: [3]*mut u32 = .{ &a, &shared_counter, &b };
    let s: []mut *mut u32 = ptrs[start..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a dynamic-start local pointer slice when any possible backing element is proven global-backed.
    return p.*;
}

fn slice_dynamic_start_constant_index_is_conservative(start: usize) -> u32 {
    var a: u32 = 72;
    var b: u32 = 73;
    let ptrs: [3]*mut u32 = .{ &a, &shared_counter, &b };
    let s: []mut *mut u32 = ptrs[start..2];
    let p: *mut u32 = s[0];
    // EXPECT: lower-llvm treats constant-index reads from dynamic-start slices conservatively rather than mapping s[0] exactly to backing index 0.
    return p.*;
}

fn slice_dynamic_start_all_local_stays_plain(start: usize, index: usize) -> u32 {
    var a: u32 = 74;
    var b: u32 = 75;
    var c: u32 = 76;
    let ptrs: [3]*mut u32 = .{ &a, &b, &c };
    let s: []mut *mut u32 = ptrs[start..2];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm keeps all-local dynamic-start local pointer slices plain.
    return p.*;
}

fn slice_fully_dynamic_pointer_elements_load(start: usize, end: usize, index: usize) -> u32 {
    var a: u32 = 77;
    var b: u32 = 78;
    let ptrs: [3]*mut u32 = .{ &a, &b, &shared_counter };
    let s: []mut *mut u32 = ptrs[start..end];
    let p: *mut u32 = s[index];
    // EXPECT: lower-llvm emits unordered atomic load through a fully dynamic local pointer slice when any possible backing element is proven global-backed.
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
