// String literals require a target type (sema rejects targetless ones). They
// lower to a C string literal cast to the target u8-pointer type. MC's escape
// set (\\ \' \" \0 \n \r \t) is a subset of C's, so the lexeme emits verbatim.

extern "C" fn puts(s: *const u8) -> i32;

fn pass_literal_arg() -> i32 {
    return puts("hello, world");
}

fn return_literal() -> *const u8 {
    return "constant message";
}

fn typed_local() -> i32 {
    let s: *const u8 = "via local";
    return puts(s);
}

fn with_escapes() -> *const u8 {
    return "tab\tnewline\nquote\"backslash\\done";
}
