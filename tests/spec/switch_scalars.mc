// SPEC: section=11
// SPEC: milestone=scalar-switch
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_DUPLICATE_SWITCH_CASE,E_RETURN_MISSING,E_NO_IMPLICIT_CONVERSION

fn accept_bool_switch_exhaustive(flag: bool) -> u32 {
    switch flag {
        true => { return 1; },
        false => { return 0; },
    }
}

fn accept_bool_switch_wildcard(flag: bool) -> u32 {
    switch flag {
        true => { return 1; },
        _ => { return 0; },
    }
}

fn reject_bool_switch_duplicate_true(flag: bool) -> u32 {
    switch flag {
        true => { return 1; },
        // EXPECT_ERROR: E_DUPLICATE_SWITCH_CASE
        true => { return 2; },
        false => { return 0; },
    }
}

fn reject_bool_switch_missing_false(flag: bool) -> u32 {
    // EXPECT_ERROR: E_RETURN_MISSING
    switch flag {
        true => { return 1; },
    }
}

fn reject_integer_switch_duplicate_literal(n: u32) -> u32 {
    switch n {
        1 => { return 1; },
        // EXPECT_ERROR: E_DUPLICATE_SWITCH_CASE
        1 => { return 2; },
        _ => { return 0; },
    }
}

fn reject_integer_switch_duplicate_canonical_literal(n: u32) -> u32 {
    switch n {
        1 => { return 1; },
        // EXPECT_ERROR: E_DUPLICATE_SWITCH_CASE
        0x1 => { return 2; },
        _ => { return 0; },
    }
}

fn reject_bool_switch_integer_pattern(flag: bool) -> u32 {
    switch flag {
        // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
        1 => { return 1; },
        _ => { return 0; },
    }
}

fn reject_integer_switch_bool_pattern(n: u32) -> u32 {
    switch n {
        // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
        true => { return 1; },
        _ => { return 0; },
    }
}

fn accept_signed_switch_negative_pattern(n: i32) -> u32 {
    switch n {
        -1 => { return 1; },
        0 => { return 2; },
        _ => { return 0; },
    }
}

fn reject_unsigned_switch_negative_pattern(n: u32) -> u32 {
    switch n {
        // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
        -1 => { return 1; },
        _ => { return 0; },
    }
}

fn reject_signed_switch_duplicate_negative_canonical(n: i32) -> u32 {
    switch n {
        -1 => { return 1; },
        // EXPECT_ERROR: E_DUPLICATE_SWITCH_CASE
        -0x1 => { return 2; },
        _ => { return 0; },
    }
}

fn accept_integer_switch_char_pattern(c: u8) -> u32 {
    switch c {
        'A' => { return 1; },
        '\n' => { return 2; },
        _ => { return 0; },
    }
}

fn reject_integer_switch_duplicate_char_canonical(c: u8) -> u32 {
    switch c {
        'A' => { return 1; },
        // EXPECT_ERROR: E_DUPLICATE_SWITCH_CASE
        65 => { return 2; },
        _ => { return 0; },
    }
}

fn reject_bool_switch_char_pattern(flag: bool) -> u32 {
    switch flag {
        // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
        'A' => { return 1; },
        _ => { return 0; },
    }
}
