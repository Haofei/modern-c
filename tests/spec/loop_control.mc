// SPEC: section=8
// SPEC: milestone=loop-control-flow
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_BREAK_OUTSIDE_LOOP,E_CONTINUE_OUTSIDE_LOOP,E_RETURN_TYPE_MISMATCH,E_FOR_BASE_NOT_ARRAY_OR_SLICE,E_UNKNOWN_LOOP_LABEL

extern fn make_u32_slice() -> []const u32;

fn accept_break_in_while(flag: bool) -> void {
    while flag {
        break;
    }
}

fn accept_continue_in_while(flag: bool) -> void {
    while flag {
        continue;
    }
}

fn accept_break_continue_in_for(xs: []const u32) -> void {
    for x in xs {
        continue;
    }

    for y in xs {
        break;
    }
}

fn accept_for_binding_slice_element(xs: []const u32) -> u32 {
    for x in xs {
        return x;
    }
    return 0;
}

fn accept_for_binding_array_element(xs: [4]u32) -> u32 {
    for x in xs {
        return x;
    }
    return 0;
}

fn accept_for_binding_direct_call_slice_element() -> u32 {
    for x in make_u32_slice() {
        return x;
    }
    return 0;
}

fn reject_for_binding_return_type(xs: []const u32, fallback: *mut u8) -> *mut u8 {
    for x in xs {
        // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
        return x;
    }
    return fallback;
}

fn reject_for_binding_direct_call_slice_return_type(fallback: *mut u8) -> *mut u8 {
    for x in make_u32_slice() {
        // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
        return x;
    }
    return fallback;
}

fn reject_for_non_iterable(n: u32) -> void {
    // EXPECT_ERROR: E_FOR_BASE_NOT_ARRAY_OR_SLICE
    for x in n {
        continue;
    }
}

fn reject_break_outside_loop() -> void {
    // EXPECT_ERROR: E_BREAK_OUTSIDE_LOOP
    break;
}

fn reject_continue_outside_loop() -> void {
    // EXPECT_ERROR: E_CONTINUE_OUTSIDE_LOOP
    continue;
}

// G7: a named enclosing loop is a valid `break :L` / `continue :L` target.
fn accept_labeled_break_continue(flag: bool) -> void {
    outer: while flag {
        while flag {
            break :outer;
        }
        while flag {
            continue :outer;
        }
    }
}

// G7: a labeled break to a loop that is not in scope is rejected.
fn reject_unknown_break_label(flag: bool) -> void {
    while flag {
        // EXPECT_ERROR: E_UNKNOWN_LOOP_LABEL
        break :nope;
    }
}

// G7: likewise for a labeled continue naming an unknown loop.
fn reject_unknown_continue_label(flag: bool) -> void {
    outer2: while flag {
        while flag {
            // EXPECT_ERROR: E_UNKNOWN_LOOP_LABEL
            continue :missing;
        }
    }
}
