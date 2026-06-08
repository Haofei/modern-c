// SPEC: section=15,22
// SPEC: milestone=function-pointers
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_CALL_ARG_COUNT,E_FN_POINTER_SIGNATURE_MISMATCH

fn add(a: u32, b: u32) -> u32 { return a + b; }
fn negate(a: u32) -> u32 { return 0 - a; }

// A function-pointer parameter (callback) called with the right arity/types.
fn apply(op: fn(u32, u32) -> u32, x: u32, y: u32) -> u32 {
    return op(x, y);
}

// A function name is a function-pointer value matching the parameter's signature.
fn use_callback() -> u32 {
    return apply(add, 3, 4);
}

// A function-pointer struct field (vtable) and a dispatch through it.
struct BinOp {
    combine: fn(u32, u32) -> u32,
}
fn dispatch(o: *BinOp, x: u32, y: u32) -> u32 {
    return o.combine(x, y);
}
fn build_vtable() -> BinOp {
    return .{ .combine = add };
}

fn reject_wrong_arity(op: fn(u32, u32) -> u32) -> u32 {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return op(1);
}

fn reject_wrong_signature_function() -> u32 {
    // EXPECT_ERROR: E_FN_POINTER_SIGNATURE_MISMATCH
    return apply(negate, 1, 2);
}
