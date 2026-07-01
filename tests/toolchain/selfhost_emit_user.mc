// Gate wrapper for selfhost/emit_c (mcc2's Phase-4 C-code emitter). It runs the FULL front end
// (lex -> parse -> emit) on a FIXED MC source snippet and exposes the emitted C bytes so the
// selfhost-emit-test driver can capture them, clang-compile the result with a `main` that calls
// the emitted function, and assert the run — the lex->parse->emit->clang->run round-trip that is
// Phase 4's milestone.
//
// Each representative source is built from a local `[N]u8` array (char literals -> bytes) exposed
// via `mem.as_bytes`, since MC string literals lower to `*const u8`, not the `[]const u8` the
// lexer/parser consumes (gap G12). The emitter is re-run per query into a fresh malloc-backed
// arena (like selfhost_parse_user.mc), and the emitted buffer is answered byte-by-byte.
import "selfhost/emit_c.mc";
import "std/strbuf.mc";
import "std/mem.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";

extern "C" fn mc_malloc(n: usize) -> usize;
extern "C" fn mc_free(addr: usize, n: usize) -> void;

// A malloc-backed allocator for the arena + buffer (same shape as tests/toolchain/vec_user.mc).
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

// query codes: 0 = emitted byte length, 1 = emitted byte at `arg`.
fn answer(s: []const u8, query: u32, arg: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var sb: StrBuf = emit_c_run(s, &m);
    var out: u32 = 0;
    if query == 0 {
        out = sb_len(&sb) as u32;
    } else if query == 1 {
        out = sb_byte(&sb, arg as usize) as u32;
    }
    sb_free(&sb);
    return out;
}

// The representative sources, one per `case`. Each declares its own byte array so the backing
// storage outlives the `mem.as_bytes` view passed to `answer`.
fn run(case: u32, query: u32, arg: u32) -> u32 {
    if case == 0 {
        // export fn add(a: u32, b: u32) -> u32 { return a + b; }
        var b: [54]u8 = .{
            'e', 'x', 'p', 'o', 'r', 't', ' ', 'f', 'n', ' ', 'a', 'd',
            'd', '(', 'a', ':', ' ', 'u', '3', '2', ',', ' ', 'b', ':',
            ' ', 'u', '3', '2', ')', ' ', '-', '>', ' ', 'u', '3', '2',
            ' ', '{', ' ', 'r', 'e', 't', 'u', 'r', 'n', ' ', 'a', ' ',
            '+', ' ', 'b', ';', ' ', '}',
        };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    } else if case == 1 {
        // export fn fact(n: u32) -> u32 {
        //   let r: u32 = 1; let i: u32 = 1;
        //   while i <= n { r = r * i; i = i + 1; }
        //   return r;
        // }
        var b: [114]u8 = .{
            'e', 'x', 'p', 'o', 'r', 't', ' ', 'f', 'n', ' ', 'f', 'a',
            'c', 't', '(', 'n', ':', ' ', 'u', '3', '2', ')', ' ', '-',
            '>', ' ', 'u', '3', '2', ' ', '{', '\n', 'l', 'e', 't', ' ',
            'r', ':', ' ', 'u', '3', '2', ' ', '=', ' ', '1', ';', '\n',
            'l', 'e', 't', ' ', 'i', ':', ' ', 'u', '3', '2', ' ', '=',
            ' ', '1', ';', '\n', 'w', 'h', 'i', 'l', 'e', ' ', 'i', ' ',
            '<', '=', ' ', 'n', ' ', '{', '\n', 'r', ' ', '=', ' ', 'r',
            ' ', '*', ' ', 'i', ';', '\n', 'i', ' ', '=', ' ', 'i', ' ',
            '+', ' ', '1', ';', '\n', '}', '\n', 'r', 'e', 't', 'u', 'r',
            'n', ' ', 'r', ';', '\n', '}',
        };
        let s: []const u8 = mem.as_bytes(&b);
        return answer(s, query, arg);
    }
    return 0;
}

// ----- exported gate entry points -----

// Emitted C byte length for a given case.
export fn emit_len(case: u32) -> u32 {
    return run(case, 0, 0);
}

// Emitted C byte `i` for a given case.
export fn emit_byte(case: u32, i: u32) -> u32 {
    return run(case, 1, i);
}
