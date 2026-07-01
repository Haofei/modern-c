// selfhost-trait-test fixture: prove P5.10 TRAITS + `*mut dyn` DYNAMIC DISPATCH in mcc2
// (selfhost/parser.mc + sema.mc + emit_c.mc) end to end. The embedded ACCEPT source runs the FULL
// front end (lex -> parse -> sema -> emit) on this mcc2-subset program (the Allocator pattern in
// miniature — a trait with one method, one impl, a `*mut dyn` param, and coercion at the call site):
//
//   trait Counter { fn bump(self: *mut Self, n: u32) -> u32 }
//   struct Acc { total: u32 }
//   impl Counter for Acc {
//       fn bump(self: *mut Acc, n: u32) -> u32 { self.total = self.total + n; return self.total; }
//   }
//   fn drive(c: *mut dyn Counter, n: u32) -> u32 { return c.bump(n); }
//   export fn run() -> u32 { var a: Acc = .{ .total = 0 }; return drive(&a, 5) + drive(&a, 3); }
//
// This exercises the whole trait-object lowering: a `Counter__vtable` fn-pointer typedef, a
// `Counter__dyn` {data,vtable} fat-pointer typedef, the impl method desugared to a free fn
// `Acc__bump` (with `self->total` pointer field access), a `void*`-self thunk `Acc__bump__dyn`, a
// rodata `static const Counter__vtable Acc__Counter__vtable`, the coercion `drive(&a, 5)` ->
// `(Counter__dyn){ .data = (void*)(&(a)), .vtbl = &Acc__Counter__vtable }`, and the dynamic dispatch
// `c.bump(n)` -> `(c).vtbl->bump((c).data, n)`. The gate dumps the emitted C (sema reports zero
// errors), asserts those lowerings, then clang-compiles it with a driver `main` asserting run()==13
// (5 then 8, i.e. Acc.total accumulates across two dispatched calls through the same fat pointer).
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
fn accept_bytes() -> [360]u8 {
    return .{
        116, 114, 97, 105, 116, 32, 67, 111, 117, 110, 116, 101, 114, 32, 123, 32, 102, 110, 32, 98,
        117, 109, 112, 40, 115, 101, 108, 102, 58, 32, 42, 109, 117, 116, 32, 83, 101, 108, 102, 44,
        32, 110, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 125, 10, 115, 116,
        114, 117, 99, 116, 32, 65, 99, 99, 32, 123, 32, 116, 111, 116, 97, 108, 58, 32, 117, 51,
        50, 32, 125, 10, 105, 109, 112, 108, 32, 67, 111, 117, 110, 116, 101, 114, 32, 102, 111, 114,
        32, 65, 99, 99, 32, 123, 32, 102, 110, 32, 98, 117, 109, 112, 40, 115, 101, 108, 102, 58,
        32, 42, 109, 117, 116, 32, 65, 99, 99, 44, 32, 110, 58, 32, 117, 51, 50, 41, 32, 45,
        62, 32, 117, 51, 50, 32, 123, 32, 115, 101, 108, 102, 46, 116, 111, 116, 97, 108, 32, 61,
        32, 115, 101, 108, 102, 46, 116, 111, 116, 97, 108, 32, 43, 32, 110, 59, 32, 114, 101, 116,
        117, 114, 110, 32, 115, 101, 108, 102, 46, 116, 111, 116, 97, 108, 59, 32, 125, 32, 125, 10,
        102, 110, 32, 100, 114, 105, 118, 101, 40, 99, 58, 32, 42, 109, 117, 116, 32, 100, 121, 110,
        32, 67, 111, 117, 110, 116, 101, 114, 44, 32, 110, 58, 32, 117, 51, 50, 41, 32, 45, 62,
        32, 117, 51, 50, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 99, 46, 98, 117, 109, 112,
        40, 110, 41, 59, 32, 125, 10, 101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 114, 117, 110,
        40, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 118, 97, 114, 32, 97, 58, 32, 65,
        99, 99, 32, 61, 32, 46, 123, 32, 46, 116, 111, 116, 97, 108, 32, 61, 32, 48, 32, 125,
        59, 32, 114, 101, 116, 117, 114, 110, 32, 100, 114, 105, 118, 101, 40, 38, 97, 44, 32, 53,
        41, 32, 43, 32, 100, 114, 105, 118, 101, 40, 38, 97, 44, 32, 51, 41, 59, 32, 125, 10,
    };
}

// ----- accept case: emit C bytes -----

// Emitted-C byte length for the accept source.
export fn emit_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [360]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_len(&sb) as u32;
    sb_free(&sb);
    return out;
}

// Emitted-C byte `i` for the accept source.
export fn emit_byte(i: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [360]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_byte(&sb, i as usize) as u32;
    sb_free(&sb);
    return out;
}

// Semantic-error count for the accept source (must be 0).
export fn accept_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [360]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}
