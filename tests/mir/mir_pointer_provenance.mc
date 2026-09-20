global shared_counter: u32 = 0;
struct Holder { ptr: *mut u32, ptrs: [2]*mut u32 }
struct Inner { ptr: *mut u32, ptrs: [2]*mut u32 }
struct Outer { inner: Inner }

fn direct_pointer_and_array() {
    var local: u32 = 1;
    let p: *mut u32 = &shared_counter;
    var q: *mut u32 = &local;
    let noalias_global: *mut u32 = compiler.assume_noalias_unchecked(&shared_counter, 4);
    var noalias_assigned: *mut u32 = &local;
    noalias_assigned = compiler.assume_noalias_unchecked(&shared_counter, 4);
    let noalias_local: *mut u32 = compiler.assume_noalias_unchecked(&local, 4);
    var ptrs: [2]*mut u32 = .{ &local, &shared_counter };
    let global_alias: *mut u32 = &shared_counter;
    let copied_ptrs: [2]*mut u32 = .{ global_alias, &shared_counter };
    let from_copied_array_literal: *mut u32 = copied_ptrs[0];
    ptrs[0] = &shared_counter;
    let from_global_element: *mut u32 = ptrs[1];
    #[unsafe_contract(noalias)]
    {
        let noalias_from_global_element: *mut u32 = compiler.assume_noalias_unchecked(ptrs[1], 4);
    }
    var assigned_from_global_element: *mut u32 = &local;
    assigned_from_global_element = ptrs[0];
    var holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &shared_counter } };
    holder.ptr = &shared_counter;
    let from_global_field: *mut u32 = holder.ptr;
    holder.ptrs[0] = &shared_counter;
    let from_global_field_element: *mut u32 = holder.ptrs[0];
    let from_literal_field_element: *mut u32 = holder.ptrs[1];
    let copied_holder: Holder = holder;
    let from_copied_field: *mut u32 = copied_holder.ptr;
    let from_copied_field_element: *mut u32 = copied_holder.ptrs[0];
    var assigned_holder: Holder = .{ .ptr = &local, .ptrs = .{ &local, &local } };
    assigned_holder = holder;
    let from_assigned_copy_field: *mut u32 = assigned_holder.ptr;
    let from_assigned_copy_field_element: *mut u32 = assigned_holder.ptrs[0];
    var outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &shared_counter } } };
    outer.inner.ptr = &shared_counter;
    let from_nested_field: *mut u32 = outer.inner.ptr;
    outer.inner.ptrs[0] = &shared_counter;
    let from_nested_field_element: *mut u32 = outer.inner.ptrs[0];
    let copied_outer: Outer = outer;
    let from_copied_nested_field: *mut u32 = copied_outer.inner.ptr;
    let from_copied_nested_field_element: *mut u32 = copied_outer.inner.ptrs[0];
    var assigned_outer: Outer = .{ .inner = .{ .ptr = &local, .ptrs = .{ &local, &local } } };
    assigned_outer = outer;
    let from_assigned_nested_field: *mut u32 = assigned_outer.inner.ptr;
    let from_assigned_nested_field_element: *mut u32 = assigned_outer.inner.ptrs[0];
}
