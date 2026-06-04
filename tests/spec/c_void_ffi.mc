// SPEC: section=24
// SPEC: milestone=c-void-ffi
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_C_VOID_DEREF,E_C_VOID_NO_LAYOUT,E_C_VOID_CONVERSION,E_MC_VOID_POINTER_FFI,E_BITWISE_POINTER_OPERAND,E_CALL_ARG_COUNT

extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;
extern "C" fn takes_c_void(handle: *mut c_void) -> void;
extern "C" fn takes_typed_pointer(ptr: *mut u8) -> void;
extern fn make_typed_pointer() -> *mut u8;
extern fn make_c_void_pointer() -> *mut c_void;
extern fn make_result_typed_pointer() -> Result<*mut u8, Error>;
extern fn make_result_c_void_pointer() -> Result<*mut c_void, Error>;
extern fn make_nullable_typed_pointer() -> ?*mut u8;
extern fn make_nullable_c_void_pointer() -> ?*mut c_void;

fn accept_c_void_ffi(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void {
    // EXPECT: extern C opaque-object pointers are accepted and may cross the FFI boundary.
    return memcpy(dst, src, n);
}

fn reject_c_void_ffi_arg_count(dst: *mut c_void, src: *const c_void) -> *mut c_void {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return memcpy(dst, src);
}

fn accept_c_void_comparison(a: *mut c_void, b: *mut c_void) -> bool {
    // EXPECT: opaque C object pointers may be compared without inspecting layout.
    return a == b;
}

fn reject_c_void_deref(p: *mut c_void) -> u8 {
    // EXPECT_ERROR: E_C_VOID_DEREF
    return *p;
}

fn reject_c_void_deref_by_type(handle: *const c_void) -> u8 {
    // EXPECT_ERROR: E_C_VOID_DEREF
    return *handle;
}

fn reject_c_void_local_deref(src: *const c_void) -> u8 {
    let handle: *const c_void = src;
    // EXPECT_ERROR: E_C_VOID_DEREF
    return *handle;
}

fn reject_c_void_layout() -> usize {
    // EXPECT_ERROR: E_C_VOID_NO_LAYOUT
    return size_of<c_void>();
}

fn reject_c_void_alignment() -> usize {
    // EXPECT_ERROR: E_C_VOID_NO_LAYOUT
    return alignof<c_void>();
}

fn reject_c_void_field(p: *mut c_void) -> usize {
    // EXPECT_ERROR: E_C_VOID_NO_LAYOUT
    return p.field;
}

fn reject_c_void_to_typed_pointer(p: *mut c_void) -> *mut u8 {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    return p as *mut u8;
}

fn reject_typed_pointer_to_c_void(p: *mut u8) -> *mut c_void {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    return p as *mut c_void;
}

fn reject_c_void_to_typed_pointer_initializer(p: *mut c_void) -> *mut u8 {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    let typed: *mut u8 = p;
    return typed;
}

fn reject_typed_pointer_to_c_void_initializer(p: *mut u8) -> *mut c_void {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    let handle: *mut c_void = p;
    return handle;
}

fn reject_c_void_to_typed_pointer_assignment(p: *mut c_void, fallback: *mut u8) -> *mut u8 {
    var typed: *mut u8 = fallback;
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    typed = p;
    return typed;
}

fn reject_typed_pointer_to_c_void_assignment(p: *mut u8, fallback: *mut c_void) -> *mut c_void {
    var handle: *mut c_void = fallback;
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    handle = p;
    return handle;
}

fn reject_typed_pointer_to_c_void_call_arg(p: *mut u8) -> void {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    takes_c_void(p);
}

fn reject_c_void_to_typed_pointer_call_arg(p: *mut c_void) -> void {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    takes_typed_pointer(p);
}

fn reject_c_void_to_typed_pointer_return(p: *mut c_void) -> *mut u8 {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    return p;
}

fn reject_typed_pointer_to_c_void_return(p: *mut u8) -> *mut c_void {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    return p;
}

fn reject_direct_call_c_void_to_typed_pointer_return() -> *mut u8 {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    return make_c_void_pointer();
}

fn reject_direct_call_typed_pointer_to_c_void_return() -> *mut c_void {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    return make_typed_pointer();
}

fn reject_direct_call_typed_pointer_to_c_void_initializer() -> *mut c_void {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    let handle: *mut c_void = make_typed_pointer();
    return handle;
}

fn reject_direct_call_typed_pointer_to_c_void_assignment(fallback: *mut c_void) -> *mut c_void {
    var handle: *mut c_void = fallback;
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    handle = make_typed_pointer();
    return handle;
}

fn reject_direct_call_typed_pointer_to_c_void_call_arg() -> void {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    takes_c_void(make_typed_pointer());
}

fn reject_try_payload_c_void_to_typed_pointer_return() -> *mut u8 {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    return make_result_c_void_pointer()?;
}

fn reject_try_payload_typed_pointer_to_c_void_return() -> *mut c_void {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    return make_result_typed_pointer()?;
}

fn reject_nullable_try_payload_c_void_to_typed_pointer_return() -> *mut u8 {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    return make_nullable_c_void_pointer()?;
}

fn reject_nullable_try_payload_typed_pointer_to_c_void_return() -> *mut c_void {
    // EXPECT_ERROR: E_C_VOID_CONVERSION
    return make_nullable_typed_pointer()?;
}

fn reject_c_void_bitwise(a: *mut c_void, b: *mut c_void) -> *mut c_void {
    // EXPECT_ERROR: E_BITWISE_POINTER_OPERAND
    return a & b;
}

// EXPECT_ERROR: E_MC_VOID_POINTER_FFI
extern "C" fn reject_mut_void_pointer(dst: *mut void) -> void;
