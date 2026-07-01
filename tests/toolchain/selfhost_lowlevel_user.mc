// Gate wrapper for P5.8 the LOW-LEVEL LAYER in mcc2 (selfhost/parser.mc + sema.mc + emit_c.mc):
// `unsafe` blocks, the `raw.ptr<T>`/`raw.load<T>`/`raw.store<T>` intrinsics, `extern "C" fn` decls,
// and pointer deref `p.*`. These are the container/memory primitives mcc2's own std deps use
// pervasively (std/collections/dynarray.mc, std/mem.mc, std/strbuf.mc) plus the libc bindings in the
// lexer/main — so they are essential for self-compile.
//
// The ACCEPT source is EMITTED to C so the driver can clang-compile + run it:
//   extern "C" fn mc_scratch() -> usize;
//   export fn probe() -> u32 {
//       let addr: usize = mc_scratch();
//       var out: u32 = 0;
//       unsafe {
//           raw.store<u32>(addr, 7);                     // (*(uint32_t*)(addr) = (7))
//           let v: u32 = raw.load<u32>(addr);            // (*(uint32_t*)(addr))
//           let p: *mut u32 = raw.ptr<u32>(addr);        // (uint32_t*)(addr)
//           p.* = p.* + v;                               // (*(p)) = ((*(p)) + v)  -> 7 + 7
//           out = p.*;
//       }
//       return out;                                      // 14
//   }
// The C the emitter produces is compiled with a driver that provides `mc_scratch` (a static
// buffer), `mc_malloc`/`mc_free`, and a `main` asserting probe() == 14 — proving the round trip of
// an `extern "C"` binding, an `unsafe` block, all three `raw.*` intrinsics, and `p.*` deref end to
// end (lex -> parse -> sema -> emit -> clang -> run).
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
fn accept_bytes() -> [321]u8 {
    return .{
        101, 120, 116, 101, 114, 110, 32, 34, 67, 34, 32, 102, 110, 32, 109, 99, 95, 115, 99, 114,
        97, 116, 99, 104, 40, 41, 32, 45, 62, 32, 117, 115, 105, 122, 101, 59, 10, 101, 120, 112,
        111, 114, 116, 32, 102, 110, 32, 112, 114, 111, 98, 101, 40, 41, 32, 45, 62, 32, 117, 51,
        50, 32, 123, 10, 32, 32, 32, 32, 108, 101, 116, 32, 97, 100, 100, 114, 58, 32, 117, 115,
        105, 122, 101, 32, 61, 32, 109, 99, 95, 115, 99, 114, 97, 116, 99, 104, 40, 41, 59, 10,
        32, 32, 32, 32, 118, 97, 114, 32, 111, 117, 116, 58, 32, 117, 51, 50, 32, 61, 32, 48,
        59, 10, 32, 32, 32, 32, 117, 110, 115, 97, 102, 101, 32, 123, 10, 32, 32, 32, 32, 32,
        32, 32, 32, 114, 97, 119, 46, 115, 116, 111, 114, 101, 60, 117, 51, 50, 62, 40, 97, 100,
        100, 114, 44, 32, 55, 41, 59, 10, 32, 32, 32, 32, 32, 32, 32, 32, 108, 101, 116, 32,
        118, 58, 32, 117, 51, 50, 32, 61, 32, 114, 97, 119, 46, 108, 111, 97, 100, 60, 117, 51,
        50, 62, 40, 97, 100, 100, 114, 41, 59, 10, 32, 32, 32, 32, 32, 32, 32, 32, 108, 101,
        116, 32, 112, 58, 32, 42, 109, 117, 116, 32, 117, 51, 50, 32, 61, 32, 114, 97, 119, 46,
        112, 116, 114, 60, 117, 51, 50, 62, 40, 97, 100, 100, 114, 41, 59, 10, 32, 32, 32, 32,
        32, 32, 32, 32, 112, 46, 42, 32, 61, 32, 112, 46, 42, 32, 43, 32, 118, 59, 10, 32,
        32, 32, 32, 32, 32, 32, 32, 111, 117, 116, 32, 61, 32, 112, 46, 42, 59, 10, 32, 32,
        32, 32, 125, 10, 32, 32, 32, 32, 114, 101, 116, 117, 114, 110, 32, 111, 117, 116, 59, 10,
        125,
    };
}

// ----- accept case: emit C bytes -----

// Emitted-C byte length for the accept source.
export fn emit_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [321]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_len(&sb) as u32;
    sb_free(&sb);
    return out;
}

// Emitted-C byte `i` for the accept source.
export fn emit_byte(i: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [321]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_byte(&sb, i as usize) as u32;
    sb_free(&sb);
    return out;
}

// Semantic-error count for the accept source (must be 0).
export fn accept_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [321]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}
