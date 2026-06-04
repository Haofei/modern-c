// SPEC: section=9,10
// SPEC: milestone=raw-many-pointer
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_BITWISE_POINTER_OPERAND,E_NULL_NON_NULL_POINTER

type RawBytes = [*]mut u8;
type RawConstBytes = [*]const u8;

fn accept_raw_many_mut_param(p: [*]mut u8) -> [*]mut u8 {
    let q: [*]mut u8 = p;
    return q;
}

fn accept_raw_many_const_param(p: [*]const u8) -> [*]const u8 {
    let q: [*]const u8 = p;
    return q;
}

fn accept_raw_many_c_void(p: [*]mut c_void) -> [*]mut c_void {
    let q: [*]mut c_void = p;
    return q;
}

fn accept_nullable_raw_many_pointer_null() -> ?[*]mut u8 {
    let p: ?[*]mut u8 = null;
    return p;
}

fn reject_raw_many_bitwise(p: [*]mut u8) -> [*]mut u8 {
    // EXPECT_ERROR: E_BITWISE_POINTER_OPERAND
    return ~p;
}

fn reject_raw_many_pointer_null() -> [*]mut u8 {
    // EXPECT_ERROR: E_NULL_NON_NULL_POINTER
    let p: [*]mut u8 = null;
    return p;
}
