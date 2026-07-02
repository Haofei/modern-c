// selfhost_charconst_user — the CHARACTER-LITERAL + MODULE-`const` behavioral unit for
// selfhost-lexself-test. Exercises the two subset features mcc2 gained for compiling its own
// lexer: `'a'`/`'\n'`/`'\\'`/`'0'` char literals (typed `u8`, emitted as C char literals) and
// module-level `const NAME: T = <const-expr>;` (emitted as a file-scope `static const`). A C driver
// (in the gate) links these and asserts the results AT RUNTIME — behavior, not just compilation.

// Module-level consts: a char-valued one (`u8`) and an integer one (`u32`), both used below so the
// emitted `static const` declarations are live (no -Wunused under -Werror).
const NL: u8 = '\n';
const STRIDE: u32 = 5;

// Char-literal comparisons across the escape forms the lexer uses: a letter, an uppercase letter,
// a newline escape, a backslash escape, and a digit char.
export fn classify(c: u8) -> u32 {
    if c == 'a' {
        return 1;
    }
    if c == 'Z' {
        return 2;
    }
    if c == '\n' {
        return 3;
    }
    if c == '\\' {
        return 4;
    }
    if c == '0' {
        return 5;
    }
    return 0;
}

// `const STRIDE` used in arithmetic.
export fn stride_of(n: u32) -> u32 {
    return n * STRIDE;
}

// `const NL` (a char const) read back as a numeric byte value.
export fn newline_code() -> u32 {
    return NL as u32;
}

// A char literal used directly as a returned byte value (not just in a comparison).
export fn tab_byte() -> u8 {
    return '\t';
}
