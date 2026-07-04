// SPEC: section=15,22
// SPEC: milestone=function-pointers
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_CALL_ARG_COUNT,E_FN_POINTER_SIGNATURE_MISMATCH

fn add(a: u32, b: u32) -> u32 { return a + b; }
fn negate(a: u32) -> u32 { return 0 - a; }
fn sum2(xs: [2]u32) -> u32 { return xs[0] + xs[1]; }

global default_op: fn(u32, u32) -> u32 = add;
global default_ops: [2]fn(u32, u32) -> u32 = .{ add, add };
global default_sum2: fn([2]u32) -> u32 = sum2;

// A function-pointer parameter (callback) called with the right arity/types.
fn apply(op: fn(u32, u32) -> u32, x: u32, y: u32) -> u32 {
    return op(x, y);
}

// A function name is a function-pointer value matching the parameter's signature.
fn use_callback() -> u32 {
    return apply(add, 3, 4);
}

fn use_global_callback() -> u32 {
    return default_op(3, 4);
}

fn use_global_callback_array() -> u32 {
    return default_ops[0](3, 4);
}

// A function-pointer struct field (vtable) and a dispatch through it.
struct BinOp {
    combine: fn(u32, u32) -> u32,
}

global default_box: BinOp = .{ .combine = add };
global copied_box: BinOp = default_box;
global default_boxes: [2]BinOp = .{ .{ .combine = add }, .{ .combine = add } };

fn dispatch(o: *BinOp, x: u32, y: u32) -> u32 {
    return o.combine(x, y);
}
fn build_vtable() -> BinOp {
    return .{ .combine = add };
}

fn use_global_vtable() -> u32 {
    return default_box.combine(3, 4);
}

fn use_copied_global_vtable() -> u32 {
    return copied_box.combine(3, 4);
}

fn use_global_vtable_array() -> u32 {
    return default_boxes[0].combine(3, 4);
}

fn reject_wrong_arity(op: fn(u32, u32) -> u32) -> u32 {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return op(1);
}

fn reject_wrong_signature_function() -> u32 {
    // EXPECT_ERROR: E_FN_POINTER_SIGNATURE_MISMATCH
    return apply(negate, 1, 2);
}

// EXPECT_ERROR: E_FN_POINTER_SIGNATURE_MISMATCH
global reject_wrong_signature_global: fn(u32, u32) -> u32 = negate;

// EXPECT_ERROR: E_FN_POINTER_SIGNATURE_MISMATCH
global reject_wrong_signature_array_len: fn([3]u32) -> u32 = sum2;

fn reject_wrong_signature_array() -> void {
    let ops: [1]fn(u32, u32) -> u32 = .{
        // EXPECT_ERROR: E_FN_POINTER_SIGNATURE_MISMATCH
        negate,
    };
}

fn reject_wrong_signature_struct_literal() -> BinOp {
    return .{
        // EXPECT_ERROR: E_FN_POINTER_SIGNATURE_MISMATCH
        .combine = negate,
    };
}
