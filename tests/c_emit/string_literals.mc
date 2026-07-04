// String literals require a target type (sema rejects targetless ones). They
// lower to a C string literal cast to the target u8-pointer type, or to a
// `[]const u8` fat pointer with the decoded byte length.

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

fn trigraph_hardened() -> *const u8 {
    return "tri??/graph";
}

fn slice_with_nul() -> []const u8 {
    return "A\0B";
}

fn slice_len_with_nul() -> u32 {
    let s: []const u8 = "A\0B";
    return s.len as u32;
}
