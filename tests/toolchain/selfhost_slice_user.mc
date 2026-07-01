// Gate wrapper for P5.7 PROPER SLICES (fat pointers) in mcc2 (selfhost/parser.mc + sema.mc +
// emit_c.mc): a slice TYPE `[]const T` lowers to a fat-pointer struct
// `typedef struct mc_slice_const_T { const T* ptr; size_t len; } mc_slice_const_T;` (matching the
// real C backend's `mc_slice_const_u8` naming, src/lower_c_names.zig), so `.len`, element indexing
// `s[i]` -> `s.ptr[i]`, sub-slicing `s[a..b]` (from a slice OR an array base), passing/returning
// slices by value, and the `mem.as_bytes(&arr)` byte-view builtin all work — end to end through
// lex -> parse -> sema -> emit. Two sources, both built from a local `[N]u8` byte array exposed via
// `mem.as_bytes` (the REAL compiler here; mcc2 itself is what the byte source exercises).
//
// The ACCEPT source is EMITTED to C so the driver can clang-compile + run it:
//   fn sumslice(s: []const u32) -> u32 { var i: usize = 0; var acc: u32 = 0; let n: usize = s.len;
//       while i < n { acc = acc + s[i]; i = i + 1; } return acc; }
//   export fn run() -> u32 {
//       var buf: [4]u32 = .{ 1, 2, 3, 4 };
//       let s: []const u32 = buf[0..4];   // ARRAY base sub-slice -> fat pointer
//       let mid: []const u32 = s[1..3];   // SLICE base sub-slice -> fat pointer
//       let a: u32 = sumslice(s); let m: u32 = sumslice(mid); return a + m;   // 10 + 5 = 15
//   }
//   export fn abtest() -> u8 {            // mem.as_bytes(&arr) -> []const u8, then .len + index
//       var b8: [3]u8 = .{ 7, 8, 9 }; let bs: []const u8 = mem.as_bytes(&b8);
//       let n: usize = bs.len; var i: usize = 0; var acc: u8 = 0;
//       while i < n { acc = acc + bs[i]; i = i + 1; } return acc;             // 7+8+9 = 24
//   }
// The REJECT source (a sub-slice of a `[4]u32` array bound to a `[]const u8` — element-type
// mismatch) is only SEMA-checked; its first-error code must be `type_mismatch` (SmErr ordinal 7).
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
fn accept_bytes() -> [562]u8 {
    return .{
        102, 110, 32, 115, 117, 109, 115, 108, 105, 99, 101, 40, 115, 58, 32, 91, 93, 99, 111, 110,
        115, 116, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 118, 97, 114,
        32, 105, 58, 32, 117, 115, 105, 122, 101, 32, 61, 32, 48, 59, 32, 118, 97, 114, 32, 97,
        99, 99, 58, 32, 117, 51, 50, 32, 61, 32, 48, 59, 32, 108, 101, 116, 32, 110, 58, 32,
        117, 115, 105, 122, 101, 32, 61, 32, 115, 46, 108, 101, 110, 59, 32, 119, 104, 105, 108, 101,
        32, 105, 32, 60, 32, 110, 32, 123, 32, 97, 99, 99, 32, 61, 32, 97, 99, 99, 32, 43,
        32, 115, 91, 105, 93, 59, 32, 105, 32, 61, 32, 105, 32, 43, 32, 49, 59, 32, 125, 32,
        114, 101, 116, 117, 114, 110, 32, 97, 99, 99, 59, 32, 125, 32, 101, 120, 112, 111, 114, 116,
        32, 102, 110, 32, 114, 117, 110, 40, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 118,
        97, 114, 32, 98, 117, 102, 58, 32, 91, 52, 93, 117, 51, 50, 32, 61, 32, 46, 123, 32,
        49, 44, 32, 50, 44, 32, 51, 44, 32, 52, 32, 125, 59, 32, 108, 101, 116, 32, 115, 58,
        32, 91, 93, 99, 111, 110, 115, 116, 32, 117, 51, 50, 32, 61, 32, 98, 117, 102, 91, 48,
        46, 46, 52, 93, 59, 32, 108, 101, 116, 32, 109, 105, 100, 58, 32, 91, 93, 99, 111, 110,
        115, 116, 32, 117, 51, 50, 32, 61, 32, 115, 91, 49, 46, 46, 51, 93, 59, 32, 108, 101,
        116, 32, 97, 58, 32, 117, 51, 50, 32, 61, 32, 115, 117, 109, 115, 108, 105, 99, 101, 40,
        115, 41, 59, 32, 108, 101, 116, 32, 109, 58, 32, 117, 51, 50, 32, 61, 32, 115, 117, 109,
        115, 108, 105, 99, 101, 40, 109, 105, 100, 41, 59, 32, 114, 101, 116, 117, 114, 110, 32, 97,
        32, 43, 32, 109, 59, 32, 125, 32, 101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 97, 98,
        116, 101, 115, 116, 40, 41, 32, 45, 62, 32, 117, 56, 32, 123, 32, 118, 97, 114, 32, 98,
        56, 58, 32, 91, 51, 93, 117, 56, 32, 61, 32, 46, 123, 32, 55, 44, 32, 56, 44, 32,
        57, 32, 125, 59, 32, 108, 101, 116, 32, 98, 115, 58, 32, 91, 93, 99, 111, 110, 115, 116,
        32, 117, 56, 32, 61, 32, 109, 101, 109, 46, 97, 115, 95, 98, 121, 116, 101, 115, 40, 38,
        98, 56, 41, 59, 32, 108, 101, 116, 32, 110, 58, 32, 117, 115, 105, 122, 101, 32, 61, 32,
        98, 115, 46, 108, 101, 110, 59, 32, 118, 97, 114, 32, 105, 58, 32, 117, 115, 105, 122, 101,
        32, 61, 32, 48, 59, 32, 118, 97, 114, 32, 97, 99, 99, 58, 32, 117, 56, 32, 61, 32,
        48, 59, 32, 119, 104, 105, 108, 101, 32, 105, 32, 60, 32, 110, 32, 123, 32, 97, 99, 99,
        32, 61, 32, 97, 99, 99, 32, 43, 32, 98, 115, 91, 105, 93, 59, 32, 105, 32, 61, 32,
        105, 32, 43, 32, 49, 59, 32, 125, 32, 114, 101, 116, 117, 114, 110, 32, 97, 99, 99, 59,
        32, 125,
    };
}

// The REJECT source (a `[4]u32` array sub-slice bound to a `[]const u8` -> element-type mismatch):
//   export fn bad() -> u32 { var buf2: [4]u32 = .{ 1, 2, 3, 4 }; let s: []const u8 = buf2[0..4]; return 0; }
fn reject_bytes() -> [104]u8 {
    return .{
        101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 98, 97, 100, 40, 41, 32, 45, 62, 32, 117,
        51, 50, 32, 123, 32, 118, 97, 114, 32, 98, 117, 102, 50, 58, 32, 91, 52, 93, 117, 51,
        50, 32, 61, 32, 46, 123, 32, 49, 44, 32, 50, 44, 32, 51, 44, 32, 52, 32, 125, 59,
        32, 108, 101, 116, 32, 115, 58, 32, 91, 93, 99, 111, 110, 115, 116, 32, 117, 56, 32, 61,
        32, 98, 117, 102, 50, 91, 48, 46, 46, 52, 93, 59, 32, 114, 101, 116, 117, 114, 110, 32,
        48, 59, 32, 125,
    };
}

// ----- accept case: emit C bytes -----

// Emitted-C byte length for the accept source.
export fn emit_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [562]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_len(&sb) as u32;
    sb_free(&sb);
    return out;
}

// Emitted-C byte `i` for the accept source.
export fn emit_byte(i: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [562]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_byte(&sb, i as usize) as u32;
    sb_free(&sb);
    return out;
}

// Semantic-error count for the accept source (must be 0).
export fn accept_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [562]u8 = accept_bytes();
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
    var b: [104]u8 = reject_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}

// First semantic-error code (SmErr ordinal) for the reject source (must be `type_mismatch` = 7).
export fn reject_first_err() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [104]u8 = reject_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_first_err(&st);
    sema_free(&st);
    return out;
}
