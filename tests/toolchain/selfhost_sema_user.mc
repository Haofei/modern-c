// Gate wrappers for selfhost/sema (mcc2's SEMANTIC ANALYZER over the Phase-2 flat AST). Each
// representative source is built from a local `[N]u8` byte array (chars -> bytes) exposed via
// `mem.as_bytes`, since string literals lower to `*const u8`, not a `[]const u8` the pipeline can
// consume (gap G12). The full pipeline (lex -> parse -> sema) is re-run per query into a fresh
// malloc-backed arena and answered from it (like selfhost_parse_user.mc re-parses).
//
// The selfhost-sema-test C driver asserts, for one accept case, `sema_err_count == 0`; and for
// each reject case, `sema_err_count >= 1` with the expected `sema_first_err` code (its `SE_*`
// ordinals mirror selfhost/sema.mc's `SmErr`).
import "selfhost/sema.mc";
import "std/mem.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";

extern "C" fn mc_malloc(n: usize) -> usize;
extern "C" fn mc_free(addr: usize, n: usize) -> void;

// A malloc-backed allocator for the arena (same shape as tests/toolchain/selfhost_parse_user.mc).
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

// query codes: 0 = semantic error count, 1 = first-error code, 2 = parse error count.
fn answer(s: []const u8, query: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var st: SmState = sema_check(s, &m);
    var out: u32 = 0;
    if query == 0 {
        out = sema_err_count(&st);
    } else if query == 1 {
        out = sema_first_err(&st);
    } else if query == 2 {
        out = sema_parse_err_count(&st);
    }
    sema_free(&st);
    return out;
}

// The representative sources, one per `case`. Each declares its own byte array so the backing
// storage outlives the `mem.as_bytes` view passed to `answer`.
//   case 0 (ACCEPT): two well-typed fns; `f` calls `add` with matching arity/types.
//   case 1: unknown identifier (`return z;`).
//   case 2: call arg-count mismatch (`g(a, a)` vs 1 param).
//   case 3: call arg type mismatch (`g(a < b)` — bool arg vs u32 param).
//   case 4: non-bool `if` condition (`if a` with `a: u32`).
//   case 5: return-type mismatch (`return a == b;` — bool vs u32 return).
//   case 6: assign to a param (`a = a;` — params are immutable, G20).
//   case 7: duplicate top-level declaration (`fn f` twice; G33).
//   case 8: `if let` payload binding must not leak after the block (G34).
//   case 9: `ok(true)` must not type-check as `Result<u32,u32>` (G35).
fn run(case: u32, query: u32) -> u32 {
    if case == 0 {
        var b0: [146]u8 = .{ 102, 110, 32, 97, 100, 100, 40, 97, 58, 32, 117, 51, 50, 44, 32, 98, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 108, 101, 116, 32, 115, 32, 61, 32, 97, 32, 43, 32, 98, 32, 42, 32, 98, 59, 32, 105, 102, 32, 97, 32, 60, 32, 98, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 98, 59, 32, 125, 32, 114, 101, 116, 117, 114, 110, 32, 115, 59, 32, 125, 32, 102, 110, 32, 102, 40, 97, 58, 32, 117, 51, 50, 44, 32, 98, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 108, 101, 116, 32, 116, 32, 61, 32, 97, 100, 100, 40, 97, 44, 32, 98, 41, 59, 32, 114, 101, 116, 117, 114, 110, 32, 116, 59, 32, 125 };
        let s: []const u8 = mem.as_bytes(&b0);
        return answer(s, query);
    } else if case == 1 {
        var b1: [33]u8 = .{ 102, 110, 32, 102, 40, 97, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 122, 59, 32, 125 };
        let s: []const u8 = mem.as_bytes(&b1);
        return answer(s, query);
    } else if case == 2 {
        var b2: [73]u8 = .{ 102, 110, 32, 103, 40, 97, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 97, 59, 32, 125, 32, 102, 110, 32, 102, 40, 97, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 103, 40, 97, 44, 32, 97, 41, 59, 32, 125 };
        let s: []const u8 = mem.as_bytes(&b2);
        return answer(s, query);
    } else if case == 3 {
        var b3: [82]u8 = .{ 102, 110, 32, 103, 40, 97, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 97, 59, 32, 125, 32, 102, 110, 32, 102, 40, 97, 58, 32, 117, 51, 50, 44, 32, 98, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 103, 40, 97, 32, 60, 32, 98, 41, 59, 32, 125 };
        let s: []const u8 = mem.as_bytes(&b3);
        return answer(s, query);
    } else if case == 4 {
        var b4: [52]u8 = .{ 102, 110, 32, 102, 40, 97, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 105, 102, 32, 97, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 97, 59, 32, 125, 32, 114, 101, 116, 117, 114, 110, 32, 97, 59, 32, 125 };
        let s: []const u8 = mem.as_bytes(&b4);
        return answer(s, query);
    } else if case == 5 {
        var b5: [46]u8 = .{ 102, 110, 32, 102, 40, 97, 58, 32, 117, 51, 50, 44, 32, 98, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 97, 32, 61, 61, 32, 98, 59, 32, 125 };
        let s: []const u8 = mem.as_bytes(&b5);
        return answer(s, query);
    } else if case == 6 {
        var b6: [40]u8 = .{ 102, 110, 32, 102, 40, 97, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 97, 32, 61, 32, 97, 59, 32, 114, 101, 116, 117, 114, 110, 32, 97, 59, 32, 125 };
        let s: []const u8 = mem.as_bytes(&b6);
        return answer(s, query);
    } else if case == 7 {
        var b7: [55]u8 = .{ 102, 110, 32, 102, 40, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 49, 59, 32, 125, 32, 102, 110, 32, 102, 40, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 50, 59, 32, 125 };
        let s: []const u8 = mem.as_bytes(&b7);
        return answer(s, query);
    } else if case == 8 {
        var b8: [133]u8 = .{ 102, 110, 32, 109, 97, 121, 98, 101, 40, 120, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 63, 117, 51, 50, 32, 123, 32, 105, 102, 32, 120, 32, 61, 61, 32, 48, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 110, 117, 108, 108, 59, 32, 125, 32, 114, 101, 116, 117, 114, 110, 32, 120, 59, 32, 125, 32, 102, 110, 32, 102, 40, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 105, 102, 32, 108, 101, 116, 32, 121, 32, 61, 32, 109, 97, 121, 98, 101, 40, 49, 41, 32, 123, 32, 108, 101, 116, 32, 122, 58, 32, 117, 51, 50, 32, 61, 32, 121, 59, 32, 125, 32, 114, 101, 116, 117, 114, 110, 32, 121, 59, 32, 125 };
        let s: []const u8 = mem.as_bytes(&b8);
        return answer(s, query);
    } else if case == 9 {
        var b9: [47]u8 = .{ 102, 110, 32, 102, 40, 41, 32, 45, 62, 32, 82, 101, 115, 117, 108, 116, 60, 117, 51, 50, 44, 32, 117, 51, 50, 62, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 111, 107, 40, 116, 114, 117, 101, 41, 59, 32, 125 };
        let s: []const u8 = mem.as_bytes(&b9);
        return answer(s, query);
    }
    return 0;
}

// ----- exported gate entry points -----

// Semantic error count for a given case.
export fn sema_case_err_count(case: u32) -> u32 {
    return run(case, 0);
}

// First semantic error code (SmErr ordinal) for a given case.
export fn sema_case_first_err(case: u32) -> u32 {
    return run(case, 1);
}

// Parse error count for a given case (should be 0 for all these well-formed inputs).
export fn sema_case_parse_err_count(case: u32) -> u32 {
    return run(case, 2);
}
