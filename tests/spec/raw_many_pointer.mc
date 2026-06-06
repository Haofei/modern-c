// SPEC: section=9,10
// SPEC: milestone=raw-many-pointer
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_BITWISE_POINTER_OPERAND,E_NULL_NON_NULL_POINTER,E_UNSAFE_REQUIRED,E_CALL_ARG_COUNT,E_INDEX_NOT_USIZE

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

fn accept_raw_many_offset(p: [*]mut u8, i: usize) -> [*]mut u8 {
    unsafe {
        return p.offset(i);
    }
}

fn accept_raw_many_offset_deref(p: [*]const u8, i: usize) -> u8 {
    unsafe {
        return p.offset(i).*;
    }
}

fn accept_raw_many_offset_inferred_local(p: [*]mut u8, i: usize) -> [*]mut u8 {
    unsafe {
        let q = p.offset(i);
        return q;
    }
}

fn reject_raw_many_offset_outside_unsafe(p: [*]mut u8, i: usize) -> [*]mut u8 {
    // EXPECT_ERROR: E_UNSAFE_REQUIRED
    return p.offset(i);
}

fn reject_raw_many_deref_outside_unsafe(p: [*]const u8) -> u8 {
    // EXPECT_ERROR: E_UNSAFE_REQUIRED
    return p.*;
}

fn reject_raw_many_offset_assign_through_const(p: [*]const u8, i: usize, value: u8) -> void {
    unsafe {
        // EXPECT_ERROR: E_ASSIGN_THROUGH_CONST_VIEW
        p.offset(i).* = value;
    }
}

fn reject_raw_many_offset_const_address_to_mut(p: [*]const u8, i: usize) -> *mut u8 {
    unsafe {
        // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
        return &p.offset(i).*;
    }
}

fn reject_raw_many_offset_arg_count(p: [*]mut u8) -> [*]mut u8 {
    unsafe {
        // EXPECT_ERROR: E_CALL_ARG_COUNT
        return p.offset();
    }
}

fn reject_raw_many_offset_index_type(p: [*]mut u8, flag: bool) -> [*]mut u8 {
    unsafe {
        // EXPECT_ERROR: E_INDEX_NOT_USIZE
        return p.offset(flag);
    }
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
