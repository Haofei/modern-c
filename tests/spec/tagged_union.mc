// SPEC: section=14,22
// SPEC: milestone=tagged-union-declarations
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_DUPLICATE_UNION_CASE,E_REFLECTION_UNKNOWN_TYPE,E_UNKNOWN_UNION_CASE,E_UNION_CASE_HAS_NO_PAYLOAD,E_DUPLICATE_SWITCH_CASE,E_SWITCH_MULTI_BINDING_ARM,E_RETURN_TYPE_MISMATCH,E_RETURN_MISSING,E_CALL_ARG_COUNT,E_NO_IMPLICIT_CONVERSION,E_UNKNOWN_FUNCTION,E_COMPTIME_TRAP

union Token {
    int: i64,
    ident: []const u8,
    eof,
}

union Signal {
    ready,
    closed,
}

fn accept_union_sizeof() -> usize {
    return sizeof(Token);
}

fn accept_union_alignof() -> usize {
    return alignof(Token);
}

fn accept_comptime_union_layout_reflection() -> void {
    comptime {
        assert(sizeof(Token) == 24);
        assert(alignof(Token) == 8);
        assert(sizeof(Signal) == 4);
        assert(alignof(Signal) == 4);
    }
}

fn accept_union_payload_binding_type(token: Token) -> i64 {
    switch token {
        int(v) => { return v; },
        ident(s) => { return 0; },
        .eof => { return 0; },
    }
}

fn accept_union_payloadless_tag(token: Token) -> u32 {
    switch token {
        .int => { return 1; },
        .ident => { return 2; },
        .eof => { return 0; },
    }
}

fn accept_union_payload_constructor() -> Token {
    return int(7);
}

fn accept_union_payloadless_constructor() -> Token {
    return eof();
}

union RejectDuplicateUnionCase {
    int: i64,
    // EXPECT_ERROR: E_DUPLICATE_UNION_CASE
    int: u64,
}

fn reject_union_field_reflection() -> usize {
    // EXPECT_ERROR: E_REFLECTION_UNKNOWN_TYPE
    return field_offset<Token>(.int);
}

fn reject_payloadless_union_field_type() -> usize {
    // EXPECT_ERROR: E_UNION_CASE_HAS_NO_PAYLOAD
    return field_type<Token>(.eof);
}

fn reject_comptime_union_layout_reflection() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(sizeof(Token) == 16);
    }
}

fn reject_unknown_union_switch_case(token: Token) -> u32 {
    switch token {
        // EXPECT_ERROR: E_UNKNOWN_UNION_CASE
        .missing => { return 1; },
        .int => { return 2; },
        .ident => { return 3; },
        .eof => { return 0; },
    }
}

fn reject_payloadless_union_case_binding(token: Token) -> u32 {
    switch token {
        int(v) => { return 1; },
        ident(s) => { return 2; },
        // EXPECT_ERROR: E_UNION_CASE_HAS_NO_PAYLOAD
        eof(v) => { return 0; },
    }
}

fn reject_duplicate_union_switch_case(token: Token) -> u32 {
    switch token {
        int(v) => { return 1; },
        // EXPECT_ERROR: E_DUPLICATE_SWITCH_CASE
        .int => { return 2; },
        .ident => { return 3; },
        .eof => { return 0; },
    }
}

fn reject_union_switch_single_binding_mixed_with_tag(token: Token) -> u32 {
    switch token {
        // EXPECT_ERROR: E_SWITCH_MULTI_BINDING_ARM
        int(v), .eof => { return 1; },
    }
    return 0;
}

fn reject_union_switch_case_after_wildcard(token: Token) -> u32 {
    switch token {
        _ => { return 0; },
        // EXPECT_ERROR: E_DUPLICATE_SWITCH_CASE
        .int => { return 1; },
    }
}

fn reject_union_payload_binding_return_type(token: Token) -> u32 {
    switch token {
        int(v) => { return 1; },
        // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
        ident(s) => { return s; },
        .eof => { return 0; },
    }
}

fn reject_union_switch_missing_case_return(token: Token) -> u32 {
    // EXPECT_ERROR: E_RETURN_MISSING
    switch token {
        int(v) => { return 1; },
        ident(s) => { return 2; },
    }
}

fn reject_union_constructor_missing_payload() -> Token {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return int();
}

fn reject_union_constructor_extra_payload() -> Token {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return eof(1);
}

fn reject_union_constructor_payload_type() -> Token {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    return ident(1);
}

fn reject_union_constructor_to_integer() -> u32 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return int(1);
}

fn reject_union_constructor_without_target() -> Token {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let token = int(1);
    return eof();
}

fn reject_unknown_union_constructor_case() -> Token {
    // EXPECT_ERROR: E_UNKNOWN_FUNCTION
    return missing(1);
}
