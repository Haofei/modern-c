// Gate wrapper for P5.6 FIXED `[N]T` ARRAYS in mcc2 (selfhost/parser.mc + sema.mc + emit_c.mc):
// a fixed-size array TYPE `[N]u32`, a positional array-literal initializer `.{ 0, 10, 20, 30 }`,
// element read `a[i]` + write `a[i] = e` — and, proving array-in-generic monomorphization, a
// generic struct with an array field `struct Buf<T> { data: [4]T, len: usize }` instantiated at
// u32 (`[4]T` -> `uint32_t data[4]`) — end to end through lex -> parse -> sema -> emit.
//
// Two sources, both built from a local `[N]u8` byte array (chars -> bytes) exposed via
// `mem.as_bytes` (MC string literals lower to `*const u8`, not the `[]const u8` the pipeline
// consumes — gap G12). The ACCEPT case is EMITTED to C so the driver can clang-compile + run it:
//   export fn asum() -> u32 {
//     var a: [4]u32 = .{ 0, 10, 20, 30 };
//     var i: u32 = 0; var s: u32 = 0;
//     while i < 4 { s = s + a[i]; i = i + 1; }
//     a[0] = 5;
//     return s + a[0];            // (0+10+20+30) + 5 = 65
//   }
//   struct Buf<T> { data: [4]T, len: usize }
//   fn mkbuf(comptime T: type, x: T) -> Buf<T> { var b: Buf<T> = .{ .data = .{ x, x, x, x }, .len = 4 }; return b; }
//   fn first(comptime T: type, b: Buf<T>) -> T { return b.data[0]; }
//   export fn bufsum() -> u32 { var b: Buf<u32> = mkbuf(u32, 7); return first(u32, b) + first(u32, b); }  // 14
// The REJECT case (an array literal whose element count != the target `[4]u32`'s N: `.{ 0, 10, 20 }`)
// is only SEMA-checked, and its first-error code must be `array_length` (SmErr ordinal 15).
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

// The ACCEPT source (see the module header for the readable form).
fn accept_bytes() -> [483]u8 {
    return .{
        101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 97, 115, 117, 109, 40, 41, 32, 45, 62, 32,
        117, 51, 50, 32, 123, 32, 118, 97, 114, 32, 97, 58, 32, 91, 52, 93, 117, 51, 50, 32,
        61, 32, 46, 123, 32, 48, 44, 32, 49, 48, 44, 32, 50, 48, 44, 32, 51, 48, 32, 125,
        59, 32, 118, 97, 114, 32, 105, 58, 32, 117, 51, 50, 32, 61, 32, 48, 59, 32, 118, 97,
        114, 32, 115, 58, 32, 117, 51, 50, 32, 61, 32, 48, 59, 32, 119, 104, 105, 108, 101, 32,
        105, 32, 60, 32, 52, 32, 123, 32, 115, 32, 61, 32, 115, 32, 43, 32, 97, 91, 105, 93,
        59, 32, 105, 32, 61, 32, 105, 32, 43, 32, 49, 59, 32, 125, 32, 97, 91, 48, 93, 32,
        61, 32, 53, 59, 32, 114, 101, 116, 117, 114, 110, 32, 115, 32, 43, 32, 97, 91, 48, 93,
        59, 32, 125, 32, 115, 116, 114, 117, 99, 116, 32, 66, 117, 102, 60, 84, 62, 32, 123, 32,
        100, 97, 116, 97, 58, 32, 91, 52, 93, 84, 44, 32, 108, 101, 110, 58, 32, 117, 115, 105,
        122, 101, 32, 125, 32, 102, 110, 32, 109, 107, 98, 117, 102, 40, 99, 111, 109, 112, 116, 105,
        109, 101, 32, 84, 58, 32, 116, 121, 112, 101, 44, 32, 120, 58, 32, 84, 41, 32, 45, 62,
        32, 66, 117, 102, 60, 84, 62, 32, 123, 32, 118, 97, 114, 32, 98, 58, 32, 66, 117, 102,
        60, 84, 62, 32, 61, 32, 46, 123, 32, 46, 100, 97, 116, 97, 32, 61, 32, 46, 123, 32,
        120, 44, 32, 120, 44, 32, 120, 44, 32, 120, 32, 125, 44, 32, 46, 108, 101, 110, 32, 61,
        32, 52, 32, 125, 59, 32, 114, 101, 116, 117, 114, 110, 32, 98, 59, 32, 125, 32, 102, 110,
        32, 102, 105, 114, 115, 116, 40, 99, 111, 109, 112, 116, 105, 109, 101, 32, 84, 58, 32, 116,
        121, 112, 101, 44, 32, 98, 58, 32, 66, 117, 102, 60, 84, 62, 41, 32, 45, 62, 32, 84,
        32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 98, 46, 100, 97, 116, 97, 91, 48, 93, 59,
        32, 125, 32, 101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 98, 117, 102, 115, 117, 109, 40,
        41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 118, 97, 114, 32, 98, 58, 32, 66, 117,
        102, 60, 117, 51, 50, 62, 32, 61, 32, 109, 107, 98, 117, 102, 40, 117, 51, 50, 44, 32,
        55, 41, 59, 32, 114, 101, 116, 117, 114, 110, 32, 102, 105, 114, 115, 116, 40, 117, 51, 50,
        44, 32, 98, 41, 32, 43, 32, 102, 105, 114, 115, 116, 40, 117, 51, 50, 44, 32, 98, 41,
        59, 32, 125,
    };
}

// The REJECT source (array literal element count 3 != the target `[4]u32`'s N):
//   export fn bad() -> u32 { var a: [4]u32 = .{ 0, 10, 20 }; return a[0]; }
fn reject_bytes() -> [71]u8 {
    return .{
        101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 98, 97, 100, 40, 41, 32, 45, 62, 32, 117,
        51, 50, 32, 123, 32, 118, 97, 114, 32, 97, 58, 32, 91, 52, 93, 117, 51, 50, 32, 61,
        32, 46, 123, 32, 48, 44, 32, 49, 48, 44, 32, 50, 48, 32, 125, 59, 32, 114, 101, 116,
        117, 114, 110, 32, 97, 91, 48, 93, 59, 32, 125,
    };
}

// ----- accept case: emit C bytes -----

// Emitted-C byte length for the accept source.
export fn emit_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [483]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_len(&sb) as u32;
    sb_free(&sb);
    return out;
}

// Emitted-C byte `i` for the accept source.
export fn emit_byte(i: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [483]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_byte(&sb, i as usize) as u32;
    sb_free(&sb);
    return out;
}

// Semantic-error count for the accept source (must be 0).
export fn accept_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [483]u8 = accept_bytes();
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
    var b: [71]u8 = reject_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}

// First semantic-error code (SmErr ordinal) for the reject source (must be `array_length` = 15).
export fn reject_first_err() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [71]u8 = reject_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_first_err(&st);
    sema_free(&st);
    return out;
}
