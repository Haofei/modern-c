// selfhost-cast-test fixture: prove P5.9 `as` CASTS + the `sizeof(T)`/`alignof(T)` builtins in mcc2
// (selfhost/parser.mc + sema.mc + emit_c.mc) end to end. The embedded ACCEPT source runs the FULL
// front end (lex -> parse -> sema -> emit) on this mcc2-subset program:
//
//   fn size2() -> u32 { return sizeof(u32) as u32 * 2; }        // ((uint32_t)(sizeof(uint32_t))) * 2 = 8
//   fn align2() -> u32 { return alignof(u32) as u32; }          // ((uint32_t)(_Alignof(uint32_t)))   = 4
//   fn widen(a: u32) -> u64 { let x: u64 = a as u64; return x; }// widening cast u32 -> u64
//   fn mixed(s_len: u64, b: u32) -> u32 { return s_len as u32 + b; } // narrowing cast enables mixed-width add
//   fn tsize(comptime T: type) -> usize { return sizeof(T); }   // sizeof(T) inside a generic fn
//   export fn probe() -> u32 {
//       let a: usize = tsize(u32);                              // -> tsize_u32() = sizeof(uint32_t) = 4
//       let b: usize = tsize(u64);                              // -> tsize_u64() = sizeof(uint64_t) = 8
//       return size2() + (a as u32) + (b as u32);              // 8 + 4 + 8 = 20
//   }
//
// This exercises: a widening cast (`a as u64`), a narrowing cast enabling mixed-width arithmetic
// (`s_len as u32 + b` — the cross-width pain earlier phases could not express), `sizeof(u32)` and
// `alignof(u32)` used in arithmetic, and (the substitution proof) `sizeof(T)` inside a generic fn
// instantiated at TWO types so `tsize_u32` emits `sizeof(uint32_t)` (4) and `tsize_u64` emits
// `sizeof(uint64_t)` (8). The gate dumps the emitted C (sema reports zero errors), asserts the cast /
// sizeof / _Alignof lowerings, then clang-compiles it with a driver `main` asserting the numbers.
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
fn accept_bytes() -> [449]u8 {
    return .{
        102, 110, 32, 115, 105, 122, 101, 50, 40, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 10,
        32, 32, 32, 32, 114, 101, 116, 117, 114, 110, 32, 115, 105, 122, 101, 111, 102, 40, 117, 51,
        50, 41, 32, 97, 115, 32, 117, 51, 50, 32, 42, 32, 50, 59, 10, 125, 10, 102, 110, 32,
        97, 108, 105, 103, 110, 50, 40, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 10, 32, 32,
        32, 32, 114, 101, 116, 117, 114, 110, 32, 97, 108, 105, 103, 110, 111, 102, 40, 117, 51, 50,
        41, 32, 97, 115, 32, 117, 51, 50, 59, 10, 125, 10, 102, 110, 32, 119, 105, 100, 101, 110,
        40, 97, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 54, 52, 32, 123, 10, 32, 32,
        32, 32, 108, 101, 116, 32, 120, 58, 32, 117, 54, 52, 32, 61, 32, 97, 32, 97, 115, 32,
        117, 54, 52, 59, 10, 32, 32, 32, 32, 114, 101, 116, 117, 114, 110, 32, 120, 59, 10, 125,
        10, 102, 110, 32, 109, 105, 120, 101, 100, 40, 115, 95, 108, 101, 110, 58, 32, 117, 54, 52,
        44, 32, 98, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 10, 32,
        32, 32, 32, 114, 101, 116, 117, 114, 110, 32, 115, 95, 108, 101, 110, 32, 97, 115, 32, 117,
        51, 50, 32, 43, 32, 98, 59, 10, 125, 10, 102, 110, 32, 116, 115, 105, 122, 101, 40, 99,
        111, 109, 112, 116, 105, 109, 101, 32, 84, 58, 32, 116, 121, 112, 101, 41, 32, 45, 62, 32,
        117, 115, 105, 122, 101, 32, 123, 10, 32, 32, 32, 32, 114, 101, 116, 117, 114, 110, 32, 115,
        105, 122, 101, 111, 102, 40, 84, 41, 59, 10, 125, 10, 101, 120, 112, 111, 114, 116, 32, 102,
        110, 32, 112, 114, 111, 98, 101, 40, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 10, 32,
        32, 32, 32, 108, 101, 116, 32, 97, 58, 32, 117, 115, 105, 122, 101, 32, 61, 32, 116, 115,
        105, 122, 101, 40, 117, 51, 50, 41, 59, 10, 32, 32, 32, 32, 108, 101, 116, 32, 98, 58,
        32, 117, 115, 105, 122, 101, 32, 61, 32, 116, 115, 105, 122, 101, 40, 117, 54, 52, 41, 59,
        10, 32, 32, 32, 32, 114, 101, 116, 117, 114, 110, 32, 115, 105, 122, 101, 50, 40, 41, 32,
        43, 32, 40, 97, 32, 97, 115, 32, 117, 51, 50, 41, 32, 43, 32, 40, 98, 32, 97, 115,
        32, 117, 51, 50, 41, 59, 10, 125, 10,
    };
}

// ----- accept case: emit C bytes -----

// Emitted-C byte length for the accept source.
export fn emit_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [449]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_len(&sb) as u32;
    sb_free(&sb);
    return out;
}

// Emitted-C byte `i` for the accept source.
export fn emit_byte(i: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [449]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_byte(&sb, i as usize) as u32;
    sb_free(&sb);
    return out;
}

// Semantic-error count for the accept source (must be 0).
export fn accept_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [449]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}
