// Gate wrapper for P5.2 ENUM support in mcc2 (selfhost/parser.mc + sema.mc + emit_c.mc): an
// `open enum` decl with a repr type, `.variant` literals in a typed `var` init and in
// assignments, and `.raw()` on an enum value — end to end through lex -> parse -> sema -> emit.
//
// Two representative sources, both built from a local `[N]u8` byte array (chars -> bytes) exposed
// via `mem.as_bytes` (MC string literals lower to `*const u8`, not the `[]const u8` the pipeline
// consumes — gap G12). The ACCEPT case is EMITTED to C so the driver can clang-compile + run it;
// the REJECT case (a `.variant` literal naming a case that does not exist) is only SEMA-checked,
// and its first-error code must be `unknown_variant` (SmErr ordinal 10).
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
//   open enum Color: u32 { red, green, blue }
//   export fn pick(n: u32) -> u32 {
//     var c: Color = .red;
//     if n == 1 { c = .green; }
//     if n == 2 { c = .blue; }
//     return c.raw();
//   }
fn accept_bytes() -> [163]u8 {
    return .{
        111, 112, 101, 110, 32, 101, 110, 117, 109, 32, 67, 111, 108, 111, 114, 58, 32, 117, 51,
        50, 32, 123, 32, 114, 101, 100, 44, 32, 103, 114, 101, 101, 110, 44, 32, 98, 108, 117,
        101, 32, 125, 32, 101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 112, 105, 99, 107, 40,
        110, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 118, 97,
        114, 32, 99, 58, 32, 67, 111, 108, 111, 114, 32, 61, 32, 46, 114, 101, 100, 59, 32,
        105, 102, 32, 110, 32, 61, 61, 32, 49, 32, 123, 32, 99, 32, 61, 32, 46, 103, 114,
        101, 101, 110, 59, 32, 125, 32, 105, 102, 32, 110, 32, 61, 61, 32, 50, 32, 123, 32,
        99, 32, 61, 32, 46, 98, 108, 117, 101, 59, 32, 125, 32, 114, 101, 116, 117, 114, 110,
        32, 99, 46, 114, 97, 119, 40, 41, 59, 32, 125,
    };
}

// The REJECT source (a `.variant` literal names an absent case `.purple`):
//   open enum Color: u32 { red, green, blue }
//   export fn bad(n: u32) -> u32 { var c: Color = .purple; return c.raw(); }
fn reject_bytes() -> [114]u8 {
    return .{
        111, 112, 101, 110, 32, 101, 110, 117, 109, 32, 67, 111, 108, 111, 114, 58, 32, 117, 51,
        50, 32, 123, 32, 114, 101, 100, 44, 32, 103, 114, 101, 101, 110, 44, 32, 98, 108, 117,
        101, 32, 125, 32, 101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 98, 97, 100, 40, 110,
        58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 118, 97, 114,
        32, 99, 58, 32, 67, 111, 108, 111, 114, 32, 61, 32, 46, 112, 117, 114, 112, 108, 101,
        59, 32, 114, 101, 116, 117, 114, 110, 32, 99, 46, 114, 97, 119, 40, 41, 59, 32, 125,
    };
}

// ----- accept case: emit C bytes -----

// Emitted-C byte length for the accept source.
export fn emit_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [163]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_len(&sb) as u32;
    sb_free(&sb);
    return out;
}

// Emitted-C byte `i` for the accept source.
export fn emit_byte(i: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [163]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_byte(&sb, i as usize) as u32;
    sb_free(&sb);
    return out;
}

// Semantic-error count for the accept source (must be 0).
export fn accept_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [163]u8 = accept_bytes();
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
    var b: [114]u8 = reject_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}

// First semantic-error code (SmErr ordinal) for the reject source (must be `unknown_variant` = 10).
export fn reject_first_err() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [114]u8 = reject_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_first_err(&st);
    sema_free(&st);
    return out;
}
