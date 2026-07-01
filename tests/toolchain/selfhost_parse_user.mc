// Gate wrappers for selfhost/parser (mcc2's PARSER + flat index-arena AST). As with the
// lexer gate, each representative source is built from a local `[N]u8` array (char literals ->
// bytes) exposed via `mem.as_bytes`, since string literals lower to `*const u8`, not a
// `[]const u8` the lexer/parser can consume.
//
// The parser is re-run per query into a fresh malloc-backed arena and answered from it (like
// selfhost_lex_user.mc re-lexes). The selfhost-parse-test C driver walks the flat AST via the
// exposed accessors (kind/lhs/rhs/main_token + the `extra` run array) and asserts node
// kinds/counts, the fn/block/param structure, precedence shape (`a + b * c` nests `*` under
// `+`), and that a malformed input yields err_count > 0. The driver's `NK_*` ordinals mirror
// selfhost/parser.mc's `NodeKind`.
import "selfhost/parser.mc";
import "std/mem.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";

extern "C" fn mc_malloc(n: usize) -> usize;
extern "C" fn mc_free(addr: usize, n: usize) -> void;

// A malloc-backed allocator for the arena (same shape as tests/toolchain/vec_user.mc).
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

// query codes: 0 = node count, 1 = kind at `arg`, 2 = lhs at `arg`, 3 = rhs at `arg`,
// 4 = extra slot at `arg`, 5 = err count, 6 = root node index, 7 = main_token at `arg`.
fn answer(s: []const u8, query: u32, arg: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var p: Parser = parser_run(s, &m);
    var out: u32 = 0;
    if query == 0 {
        out = parser_node_count(&p);
    } else if query == 1 {
        out = parser_kind_at(&p, arg);
    } else if query == 2 {
        out = parser_lhs_at(&p, arg);
    } else if query == 3 {
        out = parser_rhs_at(&p, arg);
    } else if query == 4 {
        out = parser_extra_at(&p, arg);
    } else if query == 5 {
        out = parser_err_count(&p);
    } else if query == 6 {
        out = parser_root(&p);
    } else if query == 7 {
        out = parser_main_token_at(&p, arg);
    }
    parser_free(&p);
    return out;
}

// The representative sources, one per `case`. Each declares its own byte array so the backing
// storage outlives the `mem.as_bytes` view passed to `answer`.
fn run(case: u32, query: u32, arg: u32) -> u32 {
    if case == 0 {
        // A full fn: params + let(binary precedence) + if/else + while + call + return.
        //   export fn f(a: u32, b: u32) -> u32 {
        //   let x = a + b * c;
        //   if x { return x; } else { return b; }
        //   while x { g(a); }
        //   return x;
        //   }
        var b: [123]u8 = .{
            'e', 'x', 'p', 'o', 'r', 't', ' ', 'f', 'n', ' ', 'f', '(',
            'a', ':', ' ', 'u', '3', '2', ',', ' ', 'b', ':', ' ', 'u',
            '3', '2', ')', ' ', '-', '>', ' ', 'u', '3', '2', ' ', '{',
            '\n', 'l', 'e', 't', ' ', 'x', ' ', '=', ' ', 'a', ' ', '+',
            ' ', 'b', ' ', '*', ' ', 'c', ';', '\n', 'i', 'f', ' ', 'x',
            ' ', '{', ' ', 'r', 'e', 't', 'u', 'r', 'n', ' ', 'x', ';',
            ' ', '}', ' ', 'e', 'l', 's', 'e', ' ', '{', ' ', 'r', 'e',
            't', 'u', 'r', 'n', ' ', 'b', ';', ' ', '}', '\n', 'w', 'h',
            'i', 'l', 'e', ' ', 'x', ' ', '{', ' ', 'g', '(', 'a', ')',
            ';', ' ', '}', '\n', 'r', 'e', 't', 'u', 'r', 'n', ' ', 'x',
            ';', '\n', '}',
        };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    } else if case == 1 {
        // Malformed: "fn f(a: u32 { return a }" — missing ')' , '->' return type, and ';'.
        var b: [24]u8 = .{
            'f', 'n', ' ', 'f', '(', 'a', ':', ' ', 'u', '3', '2', ' ',
            '{', ' ', 'r', 'e', 't', 'u', 'r', 'n', ' ', 'a', ' ', '}',
        };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    }
    return 0;
}

// ----- exported gate entry points -----

// Total node count (including the index-0 sentinel) for a given case.
export fn parse_node_count(case: u32) -> u32 {
    return run(case, 0, 0);
}

// NodeKind ordinal of node `i` in a given case.
export fn parse_kind_at(case: u32, i: u32) -> u32 {
    return run(case, 1, i);
}

// `lhs` payload of node `i`.
export fn parse_lhs_at(case: u32, i: u32) -> u32 {
    return run(case, 2, i);
}

// `rhs` payload of node `i`.
export fn parse_rhs_at(case: u32, i: u32) -> u32 {
    return run(case, 3, i);
}

// `extra` array slot `i` (for walking length-prefixed runs).
export fn parse_extra_at(case: u32, i: u32) -> u32 {
    return run(case, 4, i);
}

// Parse error count.
export fn parse_err_count(case: u32) -> u32 {
    return run(case, 5, 0);
}

// Root (module) node index.
export fn parse_root(case: u32) -> u32 {
    return run(case, 6, 0);
}

// `main_token` of node `i` (index into the token stream).
export fn parse_main_token_at(case: u32, i: u32) -> u32 {
    return run(case, 7, i);
}
