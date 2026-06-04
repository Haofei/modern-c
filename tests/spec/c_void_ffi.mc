// SPEC: section=24
// SPEC: milestone=c-void-ffi
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_C_VOID_DEREF,E_C_VOID_NO_LAYOUT,E_MC_VOID_POINTER_FFI

extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;

fn accept_c_void_ffi(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void {
    // EXPECT: extern C opaque-object pointers are accepted and may cross the FFI boundary.
    return memcpy(dst, src, n);
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

// EXPECT_ERROR: E_MC_VOID_POINTER_FFI
extern "C" fn reject_mut_void_pointer(dst: *mut void) -> void;
