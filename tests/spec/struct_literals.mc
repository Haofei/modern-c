// SPEC: section=12
// SPEC: milestone=struct-literals
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_STRUCT_LITERAL_REQUIRES_TARGET,E_STRUCT_LITERAL_MISSING_FIELD,E_DUPLICATE_STRUCT_LITERAL_FIELD,E_UNKNOWN_STRUCT_FIELD,E_RETURN_TYPE_MISMATCH

struct Pair {
    left: u32,
    right: u32,
}

fn consume_pair(pair: Pair) -> void {
    return;
}

global default_pair: Pair = .{ .left = 1, .right = 2 };

fn accept_local_struct_literal() -> u32 {
    let pair: Pair = .{ .left = 1, .right = 2 };
    return pair.right;
}

fn accept_return_struct_literal() -> Pair {
    return .{ .left = 3, .right = 4 };
}

fn accept_assignment_struct_literal() -> Pair {
    var pair: Pair = uninit;
    pair = .{ .left = 5, .right = 6 };
    return pair;
}

fn accept_call_struct_literal() -> void {
    consume_pair(.{ .left = 7, .right = 8 });
}

fn reject_targetless_struct_literal() -> void {
    // EXPECT_ERROR: E_STRUCT_LITERAL_REQUIRES_TARGET
    let pair = .{ .left = 1, .right = 2 };
}

fn reject_missing_struct_literal_field() -> Pair {
    // EXPECT_ERROR: E_STRUCT_LITERAL_MISSING_FIELD
    return .{ .left = 1 };
}

fn reject_duplicate_struct_literal_field() -> Pair {
    return .{
        .left = 1,
        // EXPECT_ERROR: E_DUPLICATE_STRUCT_LITERAL_FIELD
        .left = 2,
        .right = 3,
    };
}

fn reject_unknown_struct_literal_field() -> Pair {
    return .{
        .left = 1,
        .right = 2,
        // EXPECT_ERROR: E_UNKNOWN_STRUCT_FIELD
        .middle = 3,
    };
}

fn reject_struct_literal_field_type() -> Pair {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return .{ .left = null, .right = 2 };
}
