// SPEC: section=G,FFI
// SPEC: milestone=cstr-ffi
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NO_IMPLICIT_CONVERSION,E_UNINIT_REQUIRES_STORAGE,E_LITERAL_REQUIRES_TARGET

extern "C" fn strlen(s: cstr) -> usize;
extern "C" fn returns_cstr() -> cstr;
extern "C" fn takes_ptr(p: *const u8) -> usize;
extern fn takes_slice(s: []const u8) -> usize;

fn accept_cstr_argument() -> usize {
    return strlen("abc");
}

fn accept_cstr_local() -> usize {
    let s: cstr = "abc";
    return strlen(s);
}

fn accept_cstr_return() -> cstr {
    return "abc";
}

fn accept_existing_cstr_value() -> usize {
    let s: cstr = returns_cstr();
    return strlen(s);
}

fn accept_existing_string_literal_pointer_behavior() -> usize {
    let p: *const u8 = "abc";
    return takes_ptr(p);
}

fn accept_existing_string_literal_slice_behavior() -> usize {
    let s: []const u8 = "abc";
    return takes_slice(s);
}

fn reject_pointer_to_cstr() -> usize {
    let p: *const u8 = "abc";
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    return strlen(p);
}

fn reject_slice_to_cstr() -> usize {
    let s: []const u8 = "abc";
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    return strlen(s);
}

fn reject_null_to_cstr() -> usize {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    return strlen(null);
}

fn reject_integer_to_cstr(x: usize) -> usize {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let s: cstr = x;
    return strlen(s);
}

fn reject_uninit_let_cstr() -> usize {
    // EXPECT_ERROR: E_UNINIT_REQUIRES_STORAGE
    let s: cstr = uninit;
    return strlen(s);
}

fn reject_targetless_string_literal() -> void {
    // EXPECT_ERROR: E_LITERAL_REQUIRES_TARGET
    let s = "abc";
}
