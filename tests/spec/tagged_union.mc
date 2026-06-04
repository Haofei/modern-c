// SPEC: section=14,22
// SPEC: milestone=tagged-union-declarations
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_DUPLICATE_UNION_CASE,E_REFLECTION_UNKNOWN_TYPE

union Token {
    int: i64,
    ident: []const u8,
    eof,
}

fn accept_union_sizeof() -> usize {
    return sizeof(Token);
}

fn accept_union_alignof() -> usize {
    return alignof(Token);
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
