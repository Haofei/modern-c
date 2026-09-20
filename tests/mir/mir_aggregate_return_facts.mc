global shared_counter: u32 = 0;
global other_counter: u32 = 0;
extern fn cleanup() -> void;
struct Holder { ptr: *mut u32, tag: u32 }
fn cleanup_holder(holder: *mut Holder) -> void {
    holder.*.tag = 0;
}

fn direct_holder() -> Holder {
    return .{ .ptr = &shared_counter, .tag = 1 };
}

fn direct_holder_after_noise() -> Holder {
    let noise: u32 = shared_counter;
    return .{ .ptr = &shared_counter, .tag = noise };
}

fn local_holder() -> Holder {
    let holder: Holder = .{ .ptr = &shared_counter, .tag = 2 };
    return holder;
}

fn assigned_holder() -> Holder {
    var local: u32 = 3;
    var holder: Holder = .{ .ptr = &local, .tag = 3 };
    holder = .{ .ptr = &shared_counter, .tag = 4 };
    return holder;
}

fn copied_holder() -> Holder {
    let source: Holder = .{ .ptr = &shared_counter, .tag = 5 };
    let holder: Holder = source;
    return holder;
}

fn branched_holder(flag: bool) -> Holder {
    if flag { return .{ .ptr = &shared_counter, .tag = 6 }; } else { return .{ .ptr = &shared_counter, .tag = 7 }; }
}

fn mixed_branched_holder(flag: bool, ptr: *mut u32) -> Holder {
    if flag { return .{ .ptr = &shared_counter, .tag = 8 }; } else { return .{ .ptr = ptr, .tag = 9 }; }
}
fn trailing_holder(choice: u32) -> Holder {
    switch choice {
        0 => { return .{ .ptr = &shared_counter, .tag = 10 }; }
        _ => {}
    }
    return .{ .ptr = &shared_counter, .tag = 11 };
}
fn trailing_updated_holder(choice: u32) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 12 };
    switch choice {
        0 => { return .{ .ptr = &shared_counter, .tag = 13 }; }
        _ => { holder = .{ .ptr = &shared_counter, .tag = 14 }; }
    }
    return holder;
}
fn trailing_field_updated_holder(choice: u32) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 15 };
    switch choice {
        0 => { return .{ .ptr = &shared_counter, .tag = 16 }; }
        _ => { holder.ptr = &shared_counter; }
    }
    return holder;
}
struct ArrayHolder { ptrs: [2]*mut u32 }
fn trailing_array_updated_holder(choice: u32) -> ArrayHolder {
    var holder: ArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
    switch choice {
        0 => { return .{ .ptrs = .{ &shared_counter, &shared_counter } }; }
        _ => { holder.ptrs[0] = &shared_counter; }
    }
    return holder;
}
fn trailing_dynamic_array_updated_holder(choice: u32, index: usize) -> ArrayHolder {
    var holder: ArrayHolder = .{ .ptrs = .{ &shared_counter, &shared_counter } };
    switch choice {
        0 => { return .{ .ptrs = .{ &shared_counter, &shared_counter } }; }
        _ => { holder.ptrs[index] = &shared_counter; }
    }
    return holder;
}
fn trailing_mixed_dynamic_array_updated_holder(choice: u32, index: usize) -> ArrayHolder {
    var holder: ArrayHolder = .{ .ptrs = .{ &shared_counter, &other_counter } };
    switch choice {
        0 => { return .{ .ptrs = .{ &shared_counter, &shared_counter } }; }
        _ => { holder.ptrs[index] = &shared_counter; }
    }
    return holder;
}
fn nested_control_holder(choice: u32, flag: bool) -> Holder {
    switch choice {
        0 => {
            if flag { return .{ .ptr = &shared_counter, .tag = 21 }; }
            return .{ .ptr = &shared_counter, .tag = 22 };
        }
        _ => {}
    }
    return .{ .ptr = &shared_counter, .tag = 23 };
}
fn nested_loop_control_holder(choice: u32, flag: bool) -> Holder {
    switch choice {
        0 => {
            while flag {
                break;
            }
            return .{ .ptr = &shared_counter, .tag = 24 };
        }
        _ => {}
    }
    return .{ .ptr = &shared_counter, .tag = 25 };
}
fn nested_transparent_switch_control_holder(choice: u32, flag: bool) -> Holder {
    switch choice {
        0 => {
            switch flag {
                true => { let ignored: u32 = 0; }
                false => {}
            }
            return .{ .ptr = &shared_counter, .tag = 26 };
        }
        _ => {}
    }
    return .{ .ptr = &shared_counter, .tag = 27 };
}
fn nested_transparent_if_let_control_holder(choice: u32, maybe: ?u32) -> Holder {
    switch choice {
        0 => {
            if let value = maybe {
                let ignored: u32 = value;
            }
            return .{ .ptr = &shared_counter, .tag = 28 };
        }
        _ => {}
    }
    return .{ .ptr = &shared_counter, .tag = 29 };
}
fn nested_call_control_holder(choice: u32) -> Holder {
    switch choice {
        0 => {
            helper();
            return .{ .ptr = &shared_counter, .tag = 30 };
        }
        _ => {}
    }
    return .{ .ptr = &shared_counter, .tag = 31 };
}
fn nested_mutating_join_holder(choice: u32, inner: u32, ptr: *mut u32) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 32 };
    switch choice {
        0 => {
            switch inner {
                0 => { holder.ptr = ptr; }
                _ => {}
            }
        }
        _ => {}
    }
    return holder;
}
fn nested_if_let_control_holder(choice: u32, maybe: ?u32) -> Holder {
    switch choice {
        0 => {
            if let value = maybe {
                return .{ .ptr = &shared_counter, .tag = value };
            }
            return .{ .ptr = &shared_counter, .tag = 32 };
        }
        _ => {}
    }
    return .{ .ptr = &shared_counter, .tag = 33 };
}
fn if_let_control_holder(maybe: ?u32) -> Holder {
    if let value = maybe {
        return .{ .ptr = &shared_counter, .tag = value };
    }
    return .{ .ptr = &shared_counter, .tag = 28 };
}
fn if_let_else_control_holder(maybe: ?u32) -> Holder {
    if let value = maybe {
        return .{ .ptr = &shared_counter, .tag = value };
    } else {
        return .{ .ptr = &shared_counter, .tag = 29 };
    }
}
fn scoped_block_holder() -> Holder {
    {
        let ignored: u32 = shared_counter;
    }
    return .{ .ptr = &shared_counter, .tag = 29 };
}
fn scoped_block_updated_holder() -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 30 };
    {
        holder.ptr = &shared_counter;
    }
    return holder;
}
fn unsafe_block_holder() -> Holder {
    unsafe {
        let ignored: u32 = shared_counter;
    }
    return .{ .ptr = &shared_counter, .tag = 31 };
}
fn unsafe_block_updated_holder() -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 32 };
    unsafe {
        holder.ptr = &shared_counter;
    }
    return holder;
}
fn comptime_block_holder() -> Holder {
    comptime {
        assert(1 + 1 == 2);
    }
    return .{ .ptr = &shared_counter, .tag = 33 };
}
fn assert_prefix_holder(flag: bool) -> Holder {
    assert(flag || !flag);
    return .{ .ptr = &shared_counter, .tag = 34 };
}
fn contract_block_holder() -> Holder {
    var tag: u32 = 35;
    #[unsafe_contract(no_overflow)]
    {
        tag = unchecked.add(tag, 0);
    }
    return .{ .ptr = &shared_counter, .tag = tag };
}
fn contract_block_local_holder() -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 35 };
    var tag: u32 = 36;
    #[unsafe_contract(no_overflow)]
    {
        tag = unchecked.add(tag, 0);
    }
    return holder;
}
fn contract_block_updated_holder() -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 36 };
    #[unsafe_contract(no_overflow)]
    {
        holder.ptr = &shared_counter;
    }
    return holder;
}
fn loop_prefix_holder(flag: bool) -> Holder {
    while flag {
        break;
    }
    return .{ .ptr = &shared_counter, .tag = 37 };
}
fn transparent_while_prefix_holder(flag: bool) -> Holder {
    while flag {
        let ignored: u32 = 0;
    }
    return .{ .ptr = &shared_counter, .tag = 38 };
}
fn continue_for_prefix_holder(values: [2]u32) -> Holder {
    for value in values {
        let ignored: u32 = value;
        continue;
    }
    return .{ .ptr = &shared_counter, .tag = 49 };
}
fn sequential_switch_holder(first: u32, second: u32) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 39 };
    switch first {
        0 => { holder.ptr = &shared_counter; }
        _ => {}
    }
    switch second {
        0 => { holder.ptr = &shared_counter; }
        _ => {}
    }
    return holder;
}
fn triple_switch_holder(first: u32, second: u32, third: u32) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 40 };
    switch first {
        0 => { holder.ptr = &shared_counter; }
        _ => {}
    }
    switch second {
        0 => { holder.ptr = &shared_counter; }
        _ => {}
    }
    switch third {
        0 => { holder.ptr = &shared_counter; }
        _ => {}
    }
    return holder;
}
fn nine_path_switch_holder(first: u32, second: u32) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 41 };
    switch first {
        0 => { holder.ptr = &shared_counter; }
        1 => { holder.ptr = &shared_counter; }
        _ => { holder.ptr = &shared_counter; }
    }
    switch second {
        0 => { holder.ptr = &shared_counter; }
        1 => { holder.ptr = &shared_counter; }
        _ => { holder.ptr = &shared_counter; }
    }
    return holder;
}
fn path_overflow_switch_holder(first: u32, second: u32, third: u32) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 42 };
    switch first {
        0 => { holder.ptr = &shared_counter; }
        1 => { holder.ptr = &shared_counter; }
        _ => { holder.ptr = &shared_counter; }
    }
    switch second {
        0 => { holder.ptr = &shared_counter; }
        1 => { holder.ptr = &shared_counter; }
        _ => { holder.ptr = &shared_counter; }
    }
    switch third {
        0 => { holder.ptr = &shared_counter; }
        1 => { holder.ptr = &shared_counter; }
        _ => { holder.ptr = &shared_counter; }
    }
    return holder;
}
fn if_join_holder(flag: bool) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 43 };
    if flag {
        holder.ptr = &shared_counter;
    }
    return holder;
}
fn all_fallthrough_switch_holder(choice: u32) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 44 };
    switch choice {
        0 => { holder.ptr = &shared_counter; }
        _ => { holder.ptr = &shared_counter; }
    }
    return holder;
}
fn defer_prefix_holder() -> Holder {
    defer cleanup();
    return .{ .ptr = &shared_counter, .tag = 45 };
}
fn local_defer_prefix_holder() -> Holder {
    let holder: Holder = .{ .ptr = &shared_counter, .tag = 45 };
    defer cleanup();
    return holder;
}
fn local_defer_arg_prefix_holder() -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 45 };
    defer cleanup_holder(&holder);
    return holder;
}
fn defer_expr_prefix_holder() -> Holder {
    let cleanup_value: u32 = 0;
    defer cleanup_value;
    return .{ .ptr = &shared_counter, .tag = 46 };
}
fn for_prefix_holder(values: [2]u32) -> Holder {
    for value in values {
        let ignored: u32 = value;
    }
    return .{ .ptr = &shared_counter, .tag = 46 };
}
fn mutating_for_prefix_holder(values: [2]u32) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 47 };
    for value in values {
        holder.tag = value;
    }
    return holder;
}
fn scalar_mutating_for_local_holder(values: [2]u32) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 47 };
    var tag: u32 = 0;
    for value in values {
        tag = value;
    }
    return holder;
}
fn mutating_while_prefix_holder(flag: bool) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 48 };
    while flag {
        holder.tag = 49;
    }
    return holder;
}
fn pointer_mutating_while_prefix_holder(flag: bool) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 48 };
    while flag {
        holder.ptr = &shared_counter;
    }
    return holder;
}
fn mixed_pointer_mutating_while_prefix_holder(flag: bool) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 48 };
    while flag {
        holder.ptr = &other_counter;
    }
    return holder;
}
fn scalar_mutating_while_local_holder(flag: bool) -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 48 };
    var tag: u32 = 0;
    while flag {
        tag = 49;
        break;
    }
    return holder;
}
fn trailing_nested_field_updated_holder(choice: u32) -> Outer {
    var holder: Outer = .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } }, .tag = 17 };
    switch choice {
        0 => { return .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } }, .tag = 18 }; }
        _ => { holder.inner.ptr = &shared_counter; }
    }
    return holder;
}
struct Leaf { ptr: *mut u32 }
struct Middle { leaf: Leaf }
struct DeepOuter { middle: Middle }
fn trailing_deep_nested_field_updated_holder(choice: u32) -> DeepOuter {
    var holder: DeepOuter = .{ .middle = .{ .leaf = .{ .ptr = &shared_counter } } };
    switch choice {
        0 => { return .{ .middle = .{ .leaf = .{ .ptr = &shared_counter } } }; }
        _ => { holder.middle.leaf.ptr = &shared_counter; }
    }
    return holder;
}
fn deref_updated_holder() -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 19 };
    let alias: *mut Holder = &holder;
    alias.*.ptr = &shared_counter;
    return holder;
}

fn helper() -> void {}
fn helper_holder(holder: *mut Holder) -> void {
    holder.*.tag = 0;
}
fn call_before_return() -> Holder {
    let holder: Holder = .{ .ptr = &shared_counter, .tag = 5 };
    helper();
    return holder;
}
fn call_arg_before_return() -> Holder {
    var holder: Holder = .{ .ptr = &shared_counter, .tag = 5 };
    helper_holder(&holder);
    return holder;
}

fn call_before_literal_return() -> Holder {
    helper();
    return .{ .ptr = &shared_counter, .tag = 6 };
}

fn unknown_holder(ptr: *mut u32) -> Holder {
    return .{ .ptr = ptr, .tag = 3 };
}

fn local_only_holder() -> Holder {
    var local: u32 = 4;
    return .{ .ptr = &local, .tag = 4 };
}

export fn exported_holder() -> Holder {
    return .{ .ptr = &shared_counter, .tag = 20 };
}

struct PointerArrayHolder { ptrs: [2]*mut u32 }
fn pointer_array_holder() -> PointerArrayHolder {
    return .{ .ptrs = .{ &shared_counter, &shared_counter } };
}
struct Inner { ptr: *mut u32, ptrs: [2]*mut u32 }
struct Outer { inner: Inner, tag: u32 }
fn nested_holder() -> Outer {
    return .{ .inner = .{ .ptr = &shared_counter, .ptrs = .{ &shared_counter, &shared_counter } }, .tag = 10 };
}
struct Cell { ptr: *mut u32 }
struct CellHolder { cells: [2]Cell }
fn nested_array_holder() -> CellHolder {
    return .{ .cells = .{ .{ .ptr = &shared_counter }, .{ .ptr = &shared_counter } } };
}
struct CellMatrixHolder { groups: [2][2]Cell }
fn cell_matrix_holder() -> CellMatrixHolder {
    return .{ .groups = .{ .{ .{ .ptr = &shared_counter }, .{ .ptr = &shared_counter } }, .{ .{ .ptr = &shared_counter }, .{ .ptr = &shared_counter } } } };
}
struct NestedPointerArrayHolder { ptrs: [2][2]*mut u32 }
fn nested_pointer_array_holder() -> NestedPointerArrayHolder {
    return .{ .ptrs = .{ .{ &shared_counter, &shared_counter }, .{ &shared_counter, &shared_counter } } };
}
