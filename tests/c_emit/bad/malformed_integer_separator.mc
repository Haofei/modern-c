// EXPECT: E_LEX_INVALID_INTEGER_LITERAL
fn malformed_integer_separator() -> u32 {
    return 1__2;
}
