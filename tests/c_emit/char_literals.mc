fn letter() -> u8 {
    return 'A';
}

fn typed_local() -> u8 {
    let c: u8 = 'x';
    return c;
}

fn takes(c: u8) -> u8 {
    return c;
}

fn passes_literal_arg() -> u8 {
    return takes('Z');
}

fn newline() -> u8 {
    return '\n';
}

fn tab() -> u8 {
    return '\t';
}

fn carriage_return() -> u8 {
    return '\r';
}

fn nul() -> u8 {
    return '\0';
}

fn backslash() -> u8 {
    return '\\';
}

fn single_quote() -> u8 {
    return '\'';
}
