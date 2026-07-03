// Gate wrapper for P5.5 GENERICS (monomorphized) in mcc2 (selfhost/parser.mc + sema.mc +
// emit_c.mc): a generic struct decl `struct Box<T> { v: T }`, a generic function
// `fn unbox(comptime T: type, b: Box<T>) -> T`, a generic body that calls a regular helper
// (`box_plus_one<T>` -> `add1`), generic type usages `Box<u32>`/`Box<u64>`, and generic calls
// `unbox(u32, ..)`/`unbox(u64, ..)` — end to end through lex -> parse -> sema -> emit.
//
// Two representative sources, both built from a local `[N]u8` byte array (chars -> bytes) exposed
// via `mem.as_bytes` (MC string literals lower to `*const u8`, not the `[]const u8` the pipeline
// consumes — gap G12). The ACCEPT case is EMITTED to C so the driver can clang-compile + run it: it
// must contain a monomorphic `Box_u32` + `unbox_u32` (and, proving multi-instantiation + dedup, a
// distinct `Box_u64` + `unbox_u64` — while the two `Box<u32>` uses and two `unbox(u32, ..)` calls
// collapse to ONE copy each). The REJECT case (a generic call with the wrong arity: `unbox(u32)`,
// missing the value arg) is only SEMA-checked, and its first-error code must be `arg_count`
// (SmErr ordinal 2).
import "selfhost/emit_c.mc";
import "selfhost/sema.mc";
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

// The ACCEPT source:
//   struct Box<T> { v: T }
//   fn unbox(comptime T: type, b: Box<T>) -> T { return b.v; }
//   fn add1(x: u32) -> u32 { return x + 1; }
//   fn box_plus_one(comptime T: type, b: Box<T>) -> T { return add1(b.v); }
//   export fn run(a: u32, c: u32) -> u32 {
//     var bi: Box<u32> = .{ .v = a };
//     var bj: Box<u32> = .{ .v = c };
//     return unbox(u32, bi) + unbox(u32, bj) + box_plus_one(u32, bi);
//   }
//   export fn run64(a: u64) -> u64 {
//     var b: Box<u64> = .{ .v = a };
//     return unbox(u64, b);
//   }
fn accept_bytes() -> [451]u8 {
    return .{
        115, 116, 114, 117, 99, 116, 32, 66, 111, 120, 60, 84, 62, 32, 123, 32, 118, 58, 32, 84,
        32, 125, 32, 102, 110, 32, 117, 110, 98, 111, 120, 40, 99, 111, 109, 112, 116, 105, 109, 101,
        32, 84, 58, 32, 116, 121, 112, 101, 44, 32, 98, 58, 32, 66, 111, 120, 60, 84, 62, 41,
        32, 45, 62, 32, 84, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 98, 46, 118, 59, 32,
        125, 32, 102, 110, 32, 97, 100, 100, 49, 40, 120, 58, 32, 117, 51, 50, 41, 32, 45, 62,
        32, 117, 51, 50, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 120, 32, 43, 32, 49, 59,
        32, 125, 32, 102, 110, 32, 98, 111, 120, 95, 112, 108, 117, 115, 95, 111, 110, 101, 40, 99,
        111, 109, 112, 116, 105, 109, 101, 32, 84, 58, 32, 116, 121, 112, 101, 44, 32, 98, 58, 32,
        66, 111, 120, 60, 84, 62, 41, 32, 45, 62, 32, 84, 32, 123, 32, 114, 101, 116, 117, 114,
        110, 32, 97, 100, 100, 49, 40, 98, 46, 118, 41, 59, 32, 125, 32, 101, 120, 112, 111, 114,
        116, 32, 102, 110, 32, 114, 117, 110, 40, 97, 58, 32, 117, 51, 50, 44, 32, 99, 58, 32,
        117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 118, 97, 114, 32, 98, 105,
        58, 32, 66, 111, 120, 60, 117, 51, 50, 62, 32, 61, 32, 46, 123, 32, 46, 118, 32, 61,
        32, 97, 32, 125, 59, 32, 118, 97, 114, 32, 98, 106, 58, 32, 66, 111, 120, 60, 117, 51,
        50, 62, 32, 61, 32, 46, 123, 32, 46, 118, 32, 61, 32, 99, 32, 125, 59, 32, 114, 101,
        116, 117, 114, 110, 32, 117, 110, 98, 111, 120, 40, 117, 51, 50, 44, 32, 98, 105, 41, 32,
        43, 32, 117, 110, 98, 111, 120, 40, 117, 51, 50, 44, 32, 98, 106, 41, 32, 43, 32, 98,
        111, 120, 95, 112, 108, 117, 115, 95, 111, 110, 101, 40, 117, 51, 50, 44, 32, 98, 105, 41,
        59, 32, 125, 32, 101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 114, 117, 110, 54, 52, 40,
        97, 58, 32, 117, 54, 52, 41, 32, 45, 62, 32, 117, 54, 52, 32, 123, 32, 118, 97, 114,
        32, 98, 58, 32, 66, 111, 120, 60, 117, 54, 52, 62, 32, 61, 32, 46, 123, 32, 46, 118,
        32, 61, 32, 97, 32, 125, 59, 32, 114, 101, 116, 117, 114, 110, 32, 117, 110, 98, 111, 120,
        40, 117, 54, 52, 44, 32, 98, 41, 59, 32, 125,
    };
}

// The REJECT source (generic call with the wrong arity — missing the value arg):
//   struct Box<T> { v: T }
//   fn unbox(comptime T: type, b: Box<T>) -> T { return b.v; }
//   export fn bad(a: u32) -> u32 { var b: Box<u32> = .{ .v = a }; return unbox(u32); }
fn reject_bytes() -> [164]u8 {
    return .{
        115, 116, 114, 117, 99, 116, 32, 66, 111, 120, 60, 84, 62, 32, 123, 32, 118, 58, 32, 84,
        32, 125, 32, 102, 110, 32, 117, 110, 98, 111, 120, 40, 99, 111, 109, 112, 116, 105, 109,
        101, 32, 84, 58, 32, 116, 121, 112, 101, 44, 32, 98, 58, 32, 66, 111, 120, 60, 84, 62, 41,
        32, 45, 62, 32, 84, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 98, 46, 118, 59, 32,
        125, 32, 101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 98, 97, 100, 40, 97, 58, 32, 117,
        51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 118, 97, 114, 32, 98, 58, 32, 66,
        111, 120, 60, 117, 51, 50, 62, 32, 61, 32, 46, 123, 32, 46, 118, 32, 61, 32, 97, 32, 125,
        59, 32, 114, 101, 116, 117, 114, 110, 32, 117, 110, 98, 111, 120, 40, 117, 51, 50, 41, 59,
        32, 125,
    };
}

// ----- accept case: emit C bytes -----

// Emitted-C byte length for the accept source.
export fn emit_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [451]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_len(&sb) as u32;
    sb_free(&sb);
    return out;
}

// Emitted-C byte `i` for the accept source.
export fn emit_byte(i: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [451]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_byte(&sb, i as usize) as u32;
    sb_free(&sb);
    return out;
}

// Semantic-error count for the accept source (must be 0).
export fn accept_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [451]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}

// ----- reject case: sema diagnostics -----

// Semantic-error count for the reject source (must be >= 1).
export fn reject_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [164]u8 = reject_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}

// First semantic-error code (SmErr ordinal) for the reject source (must be `arg_count` = 2).
export fn reject_first_err() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [164]u8 = reject_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_first_err(&st);
    sema_free(&st);
    return out;
}
