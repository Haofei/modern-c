// Gate wrappers for selfhost/lexer (mcc2's LEXER). Each representative source is built
// from a local `[N]u8` array (char literals -> bytes) and exposed via `mem.as_bytes`,
// since string literals lower to `*const u8`, not a `[]const u8` a Lexer can consume.
//
// The lexer is stateless across calls and its `Token`s are index-based COPYABLE values,
// so every query RE-LEXES the selected case into a fresh malloc-backed `Vec<Token>` and
// answers from it. The selfhost-lex-test C driver asserts the exact token kinds/counts
// (its `TK_*` ordinals mirror selfhost/lexer.mc's `TokKind`, which mirrors src/token.zig).
import "selfhost/lexer.mc";
import "std/mem.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";

extern "C" fn mc_malloc(n: usize) -> usize;
extern "C" fn mc_free(addr: usize, n: usize) -> void;

// A malloc-backed allocator for the token Vec (same shape as tests/toolchain/vec_user.mc).
struct MallocAlloc {
    count: u32,
}

impl Allocator for MallocAlloc {
    fn alloc(self: *mut MallocAlloc, size: usize, align: usize) -> PAddr {
        if align == 0 { unreachable; }
        self.count = self.count + 1;
        return pa(mc_malloc(size));
    }
    fn free(self: *mut MallocAlloc, addr: PAddr, size: usize) -> void {
        if self.count == 0 { unreachable; }
        mc_free(pa_value(addr), size);
    }
}

// query codes: 0 = token count, 1 = kind ordinal at `arg`, 2 = len at `arg`,
// 3 = line at `arg`, 4 = col at `arg`.
fn answer(s: []const u8, query: u32, arg: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var tl: TokenList = token_list_new(&m);
    lex(s, &tl);
    var out: u32 = 0;
    if query == 0 {
        out = token_count(&tl) as u32;
    } else if query == 1 {
        out = token_kind_at(&tl, arg as usize);
    } else if query == 2 {
        out = token_len_at(&tl, arg as usize) as u32;
    } else if query == 3 {
        out = token_line_at(&tl, arg as usize) as u32;
    } else if query == 4 {
        out = token_col_at(&tl, arg as usize) as u32;
    }
    token_list_free(&tl);
    return out;
}

// The representative sources, one per `case`. Each declares its own byte array so the
// backing storage outlives the `mem.as_bytes` view passed to `answer`.
fn run(case: u32, query: u32, arg: u32) -> u32 {
    if case == 0 {
        // "fn foo" -> kw_fn, identifier, eof
        var b: [6]u8 = .{ 'f', 'n', ' ', 'f', 'o', 'o' };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    } else if case == 1 {
        // ":: -> => == != <= >= && || << >> .. ..." -> the 13 multi-char operators, eof
        var b: [39]u8 = .{
            ':', ':', ' ', '-', '>', ' ', '=', '>', ' ', '=', '=', ' ',
            '!', '=', ' ', '<', '=', ' ', '>', '=', ' ', '&', '&', ' ',
            '|', '|', ' ', '<', '<', ' ', '>', '>', ' ', '.', '.', ' ',
            '.', '.', '.',
        };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    } else if case == 2 {
        // "42 0xFF 1_000" -> integer_literal x3, eof
        var b: [13]u8 = .{ '4', '2', ' ', '0', 'x', 'F', 'F', ' ', '1', '_', '0', '0', '0' };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    } else if case == 3 {
        // "3.14 1e5 2.5E-3 inf nan" -> float_literal x5, eof
        var b: [23]u8 = .{
            '3', '.', '1', '4', ' ', '1', 'e', '5', ' ', '2', '.', '5',
            'E', '-', '3', ' ', 'i', 'n', 'f', ' ', 'n', 'a', 'n',
        };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    } else if case == 4 {
        // "a\nb\t\"c" (a string literal with escapes) -> string_literal, eof
        var b: [11]u8 = .{ '"', 'a', '\\', 'n', 'b', '\\', 't', '\\', '"', 'c', '"' };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    } else if case == 5 {
        // "'x'" -> char_literal, eof
        var b: [3]u8 = .{ '\'', 'x', '\'' };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    } else if case == 6 {
        // "a // c\n b /* c */ c" -> identifier x3, eof (comments skipped, line tracked)
        var b: [19]u8 = .{
            'a', ' ', '/', '/', ' ', 'c', '\n', ' ', 'b', ' ', '/', '*',
            ' ', 'c', ' ', '*', '/', ' ', 'c',
        };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    } else if case == 7 {
        // "_ foo" -> underscore, identifier, eof
        var b: [5]u8 = .{ '_', ' ', 'f', 'o', 'o' };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    } else if case == 8 {
        // single-char punctuation/operators: "(){}[],.:;?#@~^+-*/%&|=<" (24 distinct tokens)
        var b: [24]u8 = .{
            '(', ')', '{', '}', '[', ']', ',', '.', ':', ';', '?', '#',
            '@', '~', '^', '+', '-', '*', '/', '%', '&', '|', '=', '<',
        };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    }
    return 0;
}

// ----- exported gate entry points -----

// Number of tokens (including the trailing eof) for a given case.
export fn lex_count(case: u32) -> u32 {
    return run(case, 0, 0);
}

// Ordinal of the token kind at index `i` in a given case.
export fn lex_kind_at(case: u32, i: u32) -> u32 {
    return run(case, 1, i);
}

// Byte length of the token at index `i`.
export fn lex_len_at(case: u32, i: u32) -> u32 {
    return run(case, 2, i);
}

// 1-based source line of the token at index `i`.
export fn lex_line_at(case: u32, i: u32) -> u32 {
    return run(case, 3, i);
}

// 1-based source column of the token at index `i`.
export fn lex_col_at(case: u32, i: u32) -> u32 {
    return run(case, 4, i);
}
