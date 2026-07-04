// SPEC: section=24,25
// SPEC: milestone=c-identifier-hygiene
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_RESERVED_C_IDENTIFIER

// C backend output includes standard headers plus MC runtime helpers. Source identifiers
// that would collide with those names are rejected before C emission.

extern "C" fn mc_external_runtime_hook(value: u32) -> u32;
extern global mc_external_runtime_data: u32;

#[backend_name("mc_exported_runtime_hook")]
export fn exported_runtime_hook(value: u32) -> u32 {
    return value;
}

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
type size_t = u32;

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
type mc_user_type = u32;

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
global mc_check_index_usize: u32 = 0;

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
global MC_USER_GLOBAL: u32 = 0;

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn mc_user_function() -> u32 {
    return 0;
}

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn MC_USER_FUNCTION() -> u32 {
    return 0;
}

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn mc_tmp0() -> u32 {
    return 0;
}

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn mc_acc0() -> u32 {
    return 0;
}

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn mc_xs0() -> u32 {
    return 0;
}

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn mc_i0() -> u32 {
    return 0;
}

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn mc_a0() -> u32 {
    return 0;
}

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn uint32_t() -> u32 {
    return 0;
}

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn offsetof() -> u32 {
    return 0;
}

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn reject_reserved_param(mc_checked_add_u32: u32) -> u32 {
    return 0;
}

fn reject_reserved_local() -> u32 {
    // EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
    let mc_tmp0: u32 = 1;
    return 0;
}
