// SPEC: section=24,25
// SPEC: milestone=c-identifier-hygiene
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_RESERVED_C_IDENTIFIER

// C backend output includes standard headers plus MC runtime helpers. Source identifiers
// that would collide with those names are rejected before C emission.

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
type uint32_t = u32;

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
global mc_check_index_usize: u32 = 0;

// EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
fn reject_reserved_param(mc_checked_add_u32: u32) -> u32 {
    return 0;
}

fn reject_reserved_local() -> u32 {
    // EXPECT_ERROR: E_RESERVED_C_IDENTIFIER
    let mc_tmp0: u32 = 1;
    return 0;
}
