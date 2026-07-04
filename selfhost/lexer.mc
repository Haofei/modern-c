// selfhost/lexer — mcc2's LEXER, ported from the Zig reference (src/lexer.zig +
// src/token.zig) as Phase 1 of the self-hosting plan (docs/self-host.md (§1)).
//
// It reproduces the Zig lexer's token stream semantics exactly: the same `TokKind`
// set (in the same declaration order, so ordinals match), the same 47-keyword table,
// and the same scanning of identifiers (`inf`/`nan` -> float, `_` -> underscore),
// decimal+hex integers with `_` separators, floats (fraction + `e`/`E` exponent),
// strings/chars (with `\\ \' \" \0 n r t` escapes), line `//` + block `/* */`
// comments, and every multi-char operator.
//
// DESIGN (the self-host stress-test workarounds):
//   * INDEX-BASED tokens — `Token` stores `start`/`len` offsets into the source, not
//     a `[]const u8` slice, so it is a plain COPYABLE value storable in a `Vec<Token>`
//     (MC has no per-token owned slice; storing a borrowed slice per token is fragile).
//   * SOURCE AS A SLICE FIELD — the source `[]const u8` lives in the `Lexer` struct,
//     but every read copies it into a PLAIN LOCAL first (`let s = lx.source;`) before
//     indexing/sub-slicing: the C emitter can recover a slice's source type from a
//     plain local or param, but NOT from a struct-field access directly.
//   * NO value-optionals — `keyword_kind` returns a plain `TokKind` with an
//     `.identifier` fallback instead of `?TokKind` (MC optionals are pointer-only).
//
// Errors are kept minimal: a malformed token becomes an `.invalid` token; callers
// count `.invalid` tokens rather than consulting a diagnostics framework.

import "std/mem.mc";
import "std/ascii.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";
import "std/collections/dynarray.mc";

// The complete token set, in the SAME ORDER as src/token.zig's `Kind` enum so that the
// ordinals match the reference (the gate asserts against them). Declared `open enum ... : u32`
// so `.raw()` can extract the ordinal (closed enums reject both `.raw()` and integer casts).
pub open enum TokKind: u32 {
    eof,
    invalid,
    identifier,
    integer_literal,
    float_literal,
    string_literal,
    char_literal,

    kw_alignof,
    kw_asm,
    kw_assert,
    kw_atomic,
    kw_bool,
    kw_break,
    kw_comptime,
    kw_const,
    kw_continue,
    kw_defer,
    kw_else,
    kw_enum,
    kw_closure,
    kw_err,
    kw_export,
    kw_extern,
    kw_false,
    kw_fn,
    kw_for,
    kw_if,
    kw_let,
    kw_match,
    kw_mut,
    kw_never,
    kw_null,
    kw_ok,
    kw_open,
    kw_overlay,
    kw_packed,
    kw_pub,
    kw_return,
    kw_sat,
    kw_serial,
    kw_sizeof,
    kw_struct,
    kw_switch,
    kw_true,
    kw_type,
    kw_union,
    kw_uninit,
    kw_unsafe,
    kw_unreachable,
    kw_use,
    kw_var,
    kw_void,
    kw_while,
    kw_wrap,

    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    dot,
    colon,
    double_colon,
    semicolon,
    question,
    hash,
    at,
    underscore,

    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    bang,
    equal,
    less,
    greater,

    arrow,
    fat_arrow,
    equal_equal,
    bang_equal,
    less_equal,
    greater_equal,
    amp_amp,
    pipe_pipe,
    shift_left,
    shift_right,
    dot_dot,
    dot_dot_dot,
}

// An index-based token: `start`/`len` are byte offsets into the source (the lexeme is
// `source[start .. start+len]`); `line`/`col` are 1-based at the token's first byte.
struct Token {
    kind: TokKind,
    start: usize,
    len: usize,
    line: usize,
    col: usize,
}

// Scanner state. `source` is borrowed for the lifetime of the lex; `index` is the
// current byte offset; `line`/`col` track position (1-based) for diagnostics.
struct Lexer {
    source: []const u8,
    index: usize,
    line: usize,
    col: usize,
}

// ----- ASCII predicates -----
// `is_digit`/`is_alpha`/`is_whitespace` come from std/ascii; the identifier/hex/
// exponent predicates are built on top (std/ascii has no `is_ident_*`).

fn is_ident_start(c: u8) -> bool {
    return is_alpha(c) || c == '_';
}

fn is_ident_continue(c: u8) -> bool {
    return is_ident_start(c) || is_digit(c);
}

fn is_hex_digit(c: u8) -> bool {
    if is_digit(c) { return true; }
    if c >= 'a' && c <= 'f' { return true; }
    if c >= 'A' && c <= 'F' { return true; }
    return false;
}

fn is_digit_for_base(c: u8, is_hex: bool) -> bool {
    if is_hex { return is_hex_digit(c); }
    return is_digit(c);
}

// True when an `e`/`E` begins a valid exponent: a digit (`e5`) or a sign then a digit (`e+5`).
fn is_exponent_tail(first: u8, second: u8) -> bool {
    if is_digit(first) { return true; }
    if (first == '+' || first == '-') && is_digit(second) { return true; }
    return false;
}

// ----- cursor primitives -----

fn is_at_end(lx: *mut Lexer) -> bool {
    let s: []const u8 = lx.source;
    return lx.index >= s.len;
}

// Byte at absolute offset `i`, or 0 past end (mirrors the Zig peek family).
fn byte_at(lx: *mut Lexer, i: usize) -> u8 {
    let s: []const u8 = lx.source;
    if i >= s.len { return 0; }
    return s[i];
}

fn peek(lx: *mut Lexer) -> u8 {
    return byte_at(lx, lx.index);
}

fn peek_next(lx: *mut Lexer) -> u8 {
    return byte_at(lx, lx.index + 1);
}

fn peek_at(lx: *mut Lexer, ahead: usize) -> u8 {
    return byte_at(lx, lx.index + ahead);
}

// Consume one byte, updating line/col. Precondition: not at end.
fn advance(lx: *mut Lexer) -> void {
    let s: []const u8 = lx.source;
    let c: u8 = s[lx.index];
    lx.index = lx.index + 1;
    if c == '\n' {
        lx.line = lx.line + 1;
        lx.col = 1;
    } else {
        lx.col = lx.col + 1;
    }
}

// If the next byte equals `expected`, consume it and return true.
fn match_ch(lx: *mut Lexer, expected: u8) -> bool {
    if is_at_end(lx) { return false; }
    if peek(lx) != expected { return false; }
    advance(lx);
    return true;
}

fn make(lx: *mut Lexer, kind: TokKind, start_off: usize, start_line: usize, start_col: usize) -> Token {
    return .{ .kind = kind, .start = start_off, .len = lx.index - start_off, .line = start_line, .col = start_col };
}

// Map an identifier lexeme to its keyword kind, or `.identifier` when it is not a keyword.
fn keyword_kind(lex: []const u8) -> TokKind {
    if mem_eql(lex, "alignof") { return .kw_alignof; }
    if mem_eql(lex, "asm") { return .kw_asm; }
    if mem_eql(lex, "assert") { return .kw_assert; }
    if mem_eql(lex, "atomic") { return .kw_atomic; }
    if mem_eql(lex, "bool") { return .kw_bool; }
    if mem_eql(lex, "break") { return .kw_break; }
    if mem_eql(lex, "closure") { return .kw_closure; }
    if mem_eql(lex, "comptime") { return .kw_comptime; }
    if mem_eql(lex, "const") { return .kw_const; }
    if mem_eql(lex, "continue") { return .kw_continue; }
    if mem_eql(lex, "defer") { return .kw_defer; }
    if mem_eql(lex, "else") { return .kw_else; }
    if mem_eql(lex, "enum") { return .kw_enum; }
    if mem_eql(lex, "err") { return .kw_err; }
    if mem_eql(lex, "export") { return .kw_export; }
    if mem_eql(lex, "extern") { return .kw_extern; }
    if mem_eql(lex, "false") { return .kw_false; }
    if mem_eql(lex, "fn") { return .kw_fn; }
    if mem_eql(lex, "for") { return .kw_for; }
    if mem_eql(lex, "if") { return .kw_if; }
    if mem_eql(lex, "let") { return .kw_let; }
    if mem_eql(lex, "match") { return .kw_match; }
    if mem_eql(lex, "mut") { return .kw_mut; }
    if mem_eql(lex, "never") { return .kw_never; }
    if mem_eql(lex, "null") { return .kw_null; }
    if mem_eql(lex, "ok") { return .kw_ok; }
    if mem_eql(lex, "open") { return .kw_open; }
    if mem_eql(lex, "overlay") { return .kw_overlay; }
    if mem_eql(lex, "packed") { return .kw_packed; }
    if mem_eql(lex, "pub") { return .kw_pub; }
    if mem_eql(lex, "return") { return .kw_return; }
    if mem_eql(lex, "sat") { return .kw_sat; }
    if mem_eql(lex, "serial") { return .kw_serial; }
    if mem_eql(lex, "sizeof") { return .kw_sizeof; }
    if mem_eql(lex, "struct") { return .kw_struct; }
    if mem_eql(lex, "switch") { return .kw_switch; }
    if mem_eql(lex, "true") { return .kw_true; }
    if mem_eql(lex, "type") { return .kw_type; }
    if mem_eql(lex, "union") { return .kw_union; }
    if mem_eql(lex, "uninit") { return .kw_uninit; }
    if mem_eql(lex, "unsafe") { return .kw_unsafe; }
    if mem_eql(lex, "unreachable") { return .kw_unreachable; }
    if mem_eql(lex, "use") { return .kw_use; }
    if mem_eql(lex, "var") { return .kw_var; }
    if mem_eql(lex, "void") { return .kw_void; }
    if mem_eql(lex, "while") { return .kw_while; }
    if mem_eql(lex, "wrap") { return .kw_wrap; }
    return .identifier;
}

// Skip runs of whitespace, line comments (`// ... EOL`), and block comments (`/* ... */`).
fn skip_space_and_comments(lx: *mut Lexer) -> void {
    while !is_at_end(lx) {
        let c: u8 = peek(lx);
        if is_whitespace(c) {
            advance(lx);
            continue;
        }
        if c == '/' && peek_next(lx) == '/' {
            while !is_at_end(lx) && peek(lx) != '\n' {
                advance(lx);
            }
            continue;
        }
        if c == '/' && peek_next(lx) == '*' {
            advance(lx);
            advance(lx);
            while !is_at_end(lx) {
                if peek(lx) == '*' && peek_next(lx) == '/' {
                    advance(lx);
                    advance(lx);
                    break;
                }
                advance(lx);
            }
            // (an unterminated block comment is tolerated: the loop drains to EOF)
            continue;
        }
        break;
    }
}

// Consume an escape sequence body (the byte AFTER the backslash). Returns false ONLY on an
// unterminated escape (at EOF); an unrecognized escape is tolerated (consumed, kept valid),
// matching the Zig reporter which errors but returns true.
fn consume_escape(lx: *mut Lexer) -> bool {
    if is_at_end(lx) {
        return false;
    }
    advance(lx); // consume the escaped byte (\\ \' \" \0 n r t, or any other = tolerated)
    return true;
}

fn identifier(lx: *mut Lexer, start_off: usize, start_line: usize, start_col: usize) -> Token {
    while !is_at_end(lx) && is_ident_continue(peek(lx)) {
        advance(lx);
    }
    let s: []const u8 = lx.source;
    let end: usize = lx.index;
    let lexeme: []const u8 = s[start_off..end];
    // `_` alone is the underscore token, not an identifier.
    if mem_eql(lexeme, "_") {
        return make(lx, .underscore, start_off, start_line, start_col);
    }
    // `inf`/`nan` are IEEE float constants, lexed as float literals (see src/lexer.zig).
    if mem_eql(lexeme, "inf") {
        return make(lx, .float_literal, start_off, start_line, start_col);
    }
    if mem_eql(lexeme, "nan") {
        return make(lx, .float_literal, start_off, start_line, start_col);
    }
    let k: TokKind = keyword_kind(lexeme);
    return make(lx, k, start_off, start_line, start_col);
}

// Scan a numeric literal (the leading digit was already consumed). Handles `0x` hex,
// `_` digit separators, a decimal fraction and `e`/`E` exponent (either makes it a float),
// and invalid trailing suffixes. Returns `.integer_literal` or `.float_literal`; a malformed
// literal keeps its numeric kind (matching Zig — the reporter, not the kind, flags the error).
fn integer(lx: *mut Lexer, start_off: usize, start_line: usize, start_col: usize) -> Token {
    let s0: []const u8 = lx.source;
    var is_hex: bool = false;
    if s0[start_off] == '0' && (peek(lx) == 'x' || peek(lx) == 'X') {
        advance(lx);
        is_hex = true;
    }

    // Integer body: digits (for the base) and `_` separators. A `_` immediately before an
    // ident-start byte is NOT a separator (it begins a suffix) and stops the run. The Zig
    // reference additionally tracks malformedness (double `_`, no digits) to report an error;
    // it keeps the numeric KIND regardless, so — with no diagnostics sink — we skip that.
    while !is_at_end(lx) {
        let c: u8 = peek(lx);
        if is_digit_for_base(c, is_hex) {
            advance(lx);
        } else if c == '_' {
            if is_ident_start(peek_next(lx)) { break; }
            advance(lx);
        } else {
            break;
        }
    }

    // A decimal `.` followed by a digit begins a fractional part -> float.
    var is_float: bool = false;
    if !is_hex && !is_at_end(lx) && peek(lx) == '.' && is_digit(peek_next(lx)) {
        is_float = true;
        advance(lx);
        while !is_at_end(lx) {
            let c: u8 = peek(lx);
            if is_digit(c) {
                advance(lx);
            } else if c == '_' {
                if is_ident_start(peek_next(lx)) { break; }
                advance(lx);
            } else {
                break;
            }
        }
    }

    // A decimal `e`/`E` exponent -> float.
    if !is_hex && !is_at_end(lx) && (peek(lx) == 'e' || peek(lx) == 'E') && is_exponent_tail(peek_next(lx), peek_at(lx, 2)) {
        is_float = true;
        advance(lx);
        if peek(lx) == '+' || peek(lx) == '-' {
            advance(lx);
        }
        while !is_at_end(lx) {
            let c: u8 = peek(lx);
            if is_digit(c) {
                advance(lx);
            } else if c == '_' {
                if is_ident_start(peek_next(lx)) { break; }
                advance(lx);
            } else {
                break;
            }
        }
    }

    // A trailing identifier run is an invalid suffix (consumed but kind unchanged in Zig).
    if !is_at_end(lx) && peek(lx) == '_' {
        advance(lx);
        if is_ident_start(peek(lx)) {
            while !is_at_end(lx) && is_ident_continue(peek(lx)) {
                advance(lx);
            }
        }
    } else if !is_at_end(lx) && is_ident_start(peek(lx)) {
        while !is_at_end(lx) && is_ident_continue(peek(lx)) {
            advance(lx);
        }
    }

    if is_float {
        return make(lx, .float_literal, start_off, start_line, start_col);
    }
    return make(lx, .integer_literal, start_off, start_line, start_col);
}

fn string_tok(lx: *mut Lexer, start_off: usize, start_line: usize, start_col: usize) -> Token {
    while !is_at_end(lx) && peek(lx) != '"' {
        if peek(lx) == '\n' {
            return make(lx, .invalid, start_off, start_line, start_col);
        }
        if peek(lx) == '\\' {
            advance(lx);
            if !consume_escape(lx) {
                return make(lx, .invalid, start_off, start_line, start_col);
            }
            continue;
        }
        advance(lx);
    }
    if is_at_end(lx) {
        return make(lx, .invalid, start_off, start_line, start_col);
    }
    advance(lx); // closing quote
    return make(lx, .string_literal, start_off, start_line, start_col);
}

fn char_tok(lx: *mut Lexer, start_off: usize, start_line: usize, start_col: usize) -> Token {
    while !is_at_end(lx) && peek(lx) != '\'' {
        if peek(lx) == '\n' {
            return make(lx, .invalid, start_off, start_line, start_col);
        }
        if peek(lx) == '\\' {
            advance(lx);
            if !consume_escape(lx) {
                return make(lx, .invalid, start_off, start_line, start_col);
            }
            continue;
        }
        advance(lx);
    }
    if is_at_end(lx) {
        return make(lx, .invalid, start_off, start_line, start_col);
    }
    advance(lx); // closing quote
    // A char literal must be exactly one unit; a wrong count keeps `.char_literal` (Zig
    // reports the error but returns `.char_literal`), so no kind change here.
    return make(lx, .char_literal, start_off, start_line, start_col);
}

// Produce the next token, skipping leading whitespace/comments. Returns `.eof` at end.
fn next_token(lx: *mut Lexer) -> Token {
    skip_space_and_comments(lx);
    let start_off: usize = lx.index;
    let start_line: usize = lx.line;
    let start_col: usize = lx.col;
    if is_at_end(lx) {
        return make(lx, .eof, start_off, start_line, start_col);
    }

    let c: u8 = peek(lx);
    advance(lx);

    if is_ident_start(c) {
        return identifier(lx, start_off, start_line, start_col);
    }
    if is_digit(c) {
        return integer(lx, start_off, start_line, start_col);
    }

    if c == '(' { return make(lx, .l_paren, start_off, start_line, start_col); }
    if c == ')' { return make(lx, .r_paren, start_off, start_line, start_col); }
    if c == '{' { return make(lx, .l_brace, start_off, start_line, start_col); }
    if c == '}' { return make(lx, .r_brace, start_off, start_line, start_col); }
    if c == '[' { return make(lx, .l_bracket, start_off, start_line, start_col); }
    if c == ']' { return make(lx, .r_bracket, start_off, start_line, start_col); }
    if c == ',' { return make(lx, .comma, start_off, start_line, start_col); }
    if c == ';' { return make(lx, .semicolon, start_off, start_line, start_col); }
    if c == '?' { return make(lx, .question, start_off, start_line, start_col); }
    if c == '#' { return make(lx, .hash, start_off, start_line, start_col); }
    if c == '@' { return make(lx, .at, start_off, start_line, start_col); }
    if c == '~' { return make(lx, .tilde, start_off, start_line, start_col); }
    if c == '^' { return make(lx, .caret, start_off, start_line, start_col); }
    if c == '+' { return make(lx, .plus, start_off, start_line, start_col); }
    if c == '%' { return make(lx, .percent, start_off, start_line, start_col); }
    if c == '*' { return make(lx, .star, start_off, start_line, start_col); }
    if c == '/' { return make(lx, .slash, start_off, start_line, start_col); }

    if c == ':' {
        if match_ch(lx, ':') { return make(lx, .double_colon, start_off, start_line, start_col); }
        return make(lx, .colon, start_off, start_line, start_col);
    }
    if c == '.' {
        if match_ch(lx, '.') {
            if match_ch(lx, '.') { return make(lx, .dot_dot_dot, start_off, start_line, start_col); }
            return make(lx, .dot_dot, start_off, start_line, start_col);
        }
        return make(lx, .dot, start_off, start_line, start_col);
    }
    if c == '-' {
        if match_ch(lx, '>') { return make(lx, .arrow, start_off, start_line, start_col); }
        return make(lx, .minus, start_off, start_line, start_col);
    }
    if c == '=' {
        if match_ch(lx, '=') { return make(lx, .equal_equal, start_off, start_line, start_col); }
        if match_ch(lx, '>') { return make(lx, .fat_arrow, start_off, start_line, start_col); }
        return make(lx, .equal, start_off, start_line, start_col);
    }
    if c == '!' {
        if match_ch(lx, '=') { return make(lx, .bang_equal, start_off, start_line, start_col); }
        return make(lx, .bang, start_off, start_line, start_col);
    }
    if c == '<' {
        if match_ch(lx, '<') { return make(lx, .shift_left, start_off, start_line, start_col); }
        if match_ch(lx, '=') { return make(lx, .less_equal, start_off, start_line, start_col); }
        return make(lx, .less, start_off, start_line, start_col);
    }
    if c == '>' {
        if match_ch(lx, '>') { return make(lx, .shift_right, start_off, start_line, start_col); }
        if match_ch(lx, '=') { return make(lx, .greater_equal, start_off, start_line, start_col); }
        return make(lx, .greater, start_off, start_line, start_col);
    }
    if c == '&' {
        if match_ch(lx, '&') { return make(lx, .amp_amp, start_off, start_line, start_col); }
        return make(lx, .amp, start_off, start_line, start_col);
    }
    if c == '|' {
        if match_ch(lx, '|') { return make(lx, .pipe_pipe, start_off, start_line, start_col); }
        return make(lx, .pipe, start_off, start_line, start_col);
    }
    if c == '"' {
        return string_tok(lx, start_off, start_line, start_col);
    }
    if c == '\'' {
        return char_tok(lx, start_off, start_line, start_col);
    }

    return make(lx, .invalid, start_off, start_line, start_col);
}

// ----- token storage -----
//
// GAP (self-host ledger): the natural design — a `Vec<Token>` — does NOT lower in the C
// backend. `Vec<T>` reads/writes elements with `raw.load<T>`/`raw.store<T>`, and the C
// emitter only implements those for SCALAR `T` (`rawScalarSuffix` -> UnsupportedCEmission
// for a struct). So a `Vec<Token>` (struct element) is rejected at emit-c time. The
// workaround: store the 5 token fields FLATTENED into a single `Vec<usize>` (5 usize per
// token), wrapped in a `TokenList` that rebuilds the field views on read. The `Token`
// struct still exists as the internal scanner return value; only STORAGE is flattened.

// Number of usize slots per token in the flat backing store.
const TOKEN_STRIDE: usize = 5;

// A growable token store backed by one `Vec<usize>` (see the GAP note above). Layout per
// token: [kind_ordinal, start, len, line, col]. Copyable; free with `token_list_free`.
pub struct TokenList {
    data: Vec<usize>,
}

// A fresh empty token store bound to allocator `a` (borrowed; must outlive the list).
pub fn token_list_new(a: *mut dyn Allocator) -> TokenList {
    return .{ .data = vec_new(usize, a) };
}

// Append one token's 5 fields to the flat store.
fn push_token(tl: *mut TokenList, t: Token) -> void {
    vec_push(usize, &tl.data, t.kind.raw() as usize);
    vec_push(usize, &tl.data, t.start);
    vec_push(usize, &tl.data, t.len);
    vec_push(usize, &tl.data, t.line);
    vec_push(usize, &tl.data, t.col);
}

// Number of tokens stored (including the trailing eof once lexing has run).
pub fn token_count(tl: *TokenList) -> usize {
    return vec_len(usize, &tl.data) / TOKEN_STRIDE;
}

// The kind ordinal of token `i` (matches `TokKind`'s `.raw()` value / src/token.zig order).
pub fn token_kind_at(tl: *TokenList, i: usize) -> u32 {
    return vec_get(usize, &tl.data, i * TOKEN_STRIDE) as u32;
}

// The byte length of token `i` (its lexeme is `source[start .. start+len]`).
pub fn token_len_at(tl: *TokenList, i: usize) -> usize {
    return vec_get(usize, &tl.data, i * TOKEN_STRIDE + 2);
}

// The byte start offset of token `i`.
pub fn token_start_at(tl: *TokenList, i: usize) -> usize {
    return vec_get(usize, &tl.data, i * TOKEN_STRIDE + 1);
}

// The 1-based source line of token `i`.
pub fn token_line_at(tl: *TokenList, i: usize) -> usize {
    return vec_get(usize, &tl.data, i * TOKEN_STRIDE + 3);
}

// The 1-based source column of token `i`.
pub fn token_col_at(tl: *TokenList, i: usize) -> usize {
    return vec_get(usize, &tl.data, i * TOKEN_STRIDE + 4);
}

// Release the backing storage. Call exactly once when done.
pub fn token_list_free(tl: *mut TokenList) -> void {
    vec_free(usize, &tl.data);
}

// Lex `source` into `out`, appending one token per lexical unit and a trailing `.eof`.
// `out` is a caller-owned `TokenList` (the caller supplies the allocator and frees it).
pub fn lex(source: []const u8, out: *mut TokenList) -> void {
    var lx: Lexer = .{ .source = source, .index = 0, .line = 1, .col = 1 };
    while true {
        let t: Token = next_token(&lx);
        push_token(out, t);
        if t.kind == .eof {
            break;
        }
    }
}
