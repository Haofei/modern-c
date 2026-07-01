// Gate wrapper for P5.1 STRUCT support in mcc2 (selfhost/parser.mc + sema.mc + emit_c.mc): a
// struct declaration, a typed `var` local, a struct literal `.{...}` in a typed position, member
// read/write (`p.x`), and a returned field — end to end through lex -> parse -> sema -> emit.
//
// Two representative sources, both built from a local `[N]u8` byte array (chars -> bytes) exposed
// via `mem.as_bytes` (MC string literals lower to `*const u8`, not the `[]const u8` the pipeline
// consumes — gap G12). The ACCEPT case is EMITTED to C so the driver can clang-compile + run it;
// the REJECT case (a struct literal naming a field that does not exist) is only SEMA-checked, and
// its first-error code must be `unknown_field` (SmErr ordinal 8).
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
//   struct Point { x: u32, y: u32 }
//   export fn mk(a: u32, b: u32) -> u32 {
//     var p: Point = .{ .x = a, .y = b };
//     p.x = p.x + 1;
//     return p.x + p.y;
//   }
fn accept_bytes() -> [140]u8 {
    return .{
        115, 116, 114, 117, 99, 116, 32, 80, 111, 105, 110, 116, 32, 123, 32, 120, 58, 32, 117,
        51, 50, 44, 32, 121, 58, 32, 117, 51, 50, 32, 125, 32, 101, 120, 112, 111, 114, 116, 32,
        102, 110, 32, 109, 107, 40, 97, 58, 32, 117, 51, 50, 44, 32, 98, 58, 32, 117, 51, 50, 41,
        32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 118, 97, 114, 32, 112, 58, 32, 80, 111, 105,
        110, 116, 32, 61, 32, 46, 123, 32, 46, 120, 32, 61, 32, 97, 44, 32, 46, 121, 32, 61, 32,
        98, 32, 125, 59, 32, 112, 46, 120, 32, 61, 32, 112, 46, 120, 32, 43, 32, 49, 59, 32, 114,
        101, 116, 117, 114, 110, 32, 112, 46, 120, 32, 43, 32, 112, 46, 121, 59, 32, 125,
    };
}

// The REJECT source (struct literal names an absent field `.z`):
//   struct Point { x: u32, y: u32 }
//   export fn bad(a: u32) -> u32 { var p: Point = .{ .x = a, .z = a }; return p.x; }
fn reject_bytes() -> [112]u8 {
    return .{
        115, 116, 114, 117, 99, 116, 32, 80, 111, 105, 110, 116, 32, 123, 32, 120, 58, 32, 117,
        51, 50, 44, 32, 121, 58, 32, 117, 51, 50, 32, 125, 32, 101, 120, 112, 111, 114, 116, 32,
        102, 110, 32, 98, 97, 100, 40, 97, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50,
        32, 123, 32, 118, 97, 114, 32, 112, 58, 32, 80, 111, 105, 110, 116, 32, 61, 32, 46, 123,
        32, 46, 120, 32, 61, 32, 97, 44, 32, 46, 122, 32, 61, 32, 97, 32, 125, 59, 32, 114, 101,
        116, 117, 114, 110, 32, 112, 46, 120, 59, 32, 125,
    };
}

// ----- accept case: emit C bytes -----

// Emitted-C byte length for the accept source.
export fn emit_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [140]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_len(&sb) as u32;
    sb_free(&sb);
    return out;
}

// Emitted-C byte `i` for the accept source.
export fn emit_byte(i: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [140]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_byte(&sb, i as usize) as u32;
    sb_free(&sb);
    return out;
}

// Semantic-error count for the accept source (must be 0).
export fn accept_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [140]u8 = accept_bytes();
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
    var b: [112]u8 = reject_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}

// First semantic-error code (SmErr ordinal) for the reject source (must be `unknown_field` = 8).
export fn reject_first_err() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [112]u8 = reject_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_first_err(&st);
    sema_free(&st);
    return out;
}
