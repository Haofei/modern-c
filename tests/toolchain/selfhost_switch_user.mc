// Gate wrapper for P5.3 SWITCH-statement support in mcc2 (selfhost/parser.mc + sema.mc +
// emit_c.mc): a `switch EXPR { .variant => { .. }, _ => { .. } }` over an enum subject, with real
// exhaustiveness checking — end to end through lex -> parse -> sema -> emit.
//
// Three representative sources, each built from a local `[N]u8` byte array (chars -> bytes) exposed
// via `mem.as_bytes` (MC string literals lower to `*const u8`, not the `[]const u8` the pipeline
// consumes — gap G12):
//   ACCEPT: an `open enum Op` with a `switch` dispatching over `.add`/`.sub`/`.mul` plus a `_`
//           default. Emitted to C so the driver can clang-compile + run it (ev(0,7,3)==10,
//           ev(1,7,3)==4, ev(2,7,3)==21).
//   REJECT #1 (unknown variant): a `switch` arm names `.div`, absent from `Op` — sema's first-error
//           code must be `unknown_variant` (SmErr ordinal 10).
//   REJECT #2 (nonexhaustive): a CLOSED `enum E { a, b, c }` switched over `.a`/`.b` with NO `_`
//           arm — sema's first-error code must be `nonexhaustive_switch` (SmErr ordinal 12).
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
//   open enum Op: u32 { add, sub, mul }
//   export fn ev(o: u32, a: u32, b: u32) -> u32 {
//     var k: Op = .add;
//     if o == 1 { k = .sub; }
//     if o == 2 { k = .mul; }
//     var r: u32 = 0;
//     switch k {
//       .add => { r = a + b; },
//       .sub => { r = a - b; },
//       .mul => { r = a * b; },
//       _ => { r = 0; }
//     }
//     return r;
//   }
fn accept_bytes() -> [276]u8 {
    return .{
        111, 112, 101, 110, 32, 101, 110, 117, 109, 32, 79, 112, 58, 32, 117, 51, 50, 32, 123,
        32, 97, 100, 100, 44, 32, 115, 117, 98, 44, 32, 109, 117, 108, 32, 125, 32, 101, 120,
        112, 111, 114, 116, 32, 102, 110, 32, 101, 118, 40, 111, 58, 32, 117, 51, 50, 44, 32,
        97, 58, 32, 117, 51, 50, 44, 32, 98, 58, 32, 117, 51, 50, 41, 32, 45, 62, 32,
        117, 51, 50, 32, 123, 32, 118, 97, 114, 32, 107, 58, 32, 79, 112, 32, 61, 32, 46,
        97, 100, 100, 59, 32, 105, 102, 32, 111, 32, 61, 61, 32, 49, 32, 123, 32, 107, 32,
        61, 32, 46, 115, 117, 98, 59, 32, 125, 32, 105, 102, 32, 111, 32, 61, 61, 32, 50,
        32, 123, 32, 107, 32, 61, 32, 46, 109, 117, 108, 59, 32, 125, 32, 118, 97, 114, 32,
        114, 58, 32, 117, 51, 50, 32, 61, 32, 48, 59, 32, 115, 119, 105, 116, 99, 104, 32,
        107, 32, 123, 32, 46, 97, 100, 100, 32, 61, 62, 32, 123, 32, 114, 32, 61, 32, 97,
        32, 43, 32, 98, 59, 32, 125, 44, 32, 46, 115, 117, 98, 32, 61, 62, 32, 123, 32,
        114, 32, 61, 32, 97, 32, 45, 32, 98, 59, 32, 125, 44, 32, 46, 109, 117, 108, 32,
        61, 62, 32, 123, 32, 114, 32, 61, 32, 97, 32, 42, 32, 98, 59, 32, 125, 44, 32,
        95, 32, 61, 62, 32, 123, 32, 114, 32, 61, 32, 48, 59, 32, 125, 32, 125, 32, 114,
        101, 116, 117, 114, 110, 32, 114, 59, 32, 125,
    };
}

// The REJECT #1 source (a `.variant` arm names an absent case `.div`):
//   open enum Op: u32 { add, sub, mul }
//   export fn g(x: u32) -> u32 {
//     var k: Op = .add;
//     switch k { .add => { return 1; }, .div => { return 2; }, _ => { return 0; } }
//     return 0;
//   }
fn unknown_bytes() -> [172]u8 {
    return .{
        111, 112, 101, 110, 32, 101, 110, 117, 109, 32, 79, 112, 58, 32, 117, 51, 50, 32, 123,
        32, 97, 100, 100, 44, 32, 115, 117, 98, 44, 32, 109, 117, 108, 32, 125, 32, 101, 120,
        112, 111, 114, 116, 32, 102, 110, 32, 103, 40, 120, 58, 32, 117, 51, 50, 41, 32, 45,
        62, 32, 117, 51, 50, 32, 123, 32, 118, 97, 114, 32, 107, 58, 32, 79, 112, 32, 61,
        32, 46, 97, 100, 100, 59, 32, 115, 119, 105, 116, 99, 104, 32, 107, 32, 123, 32, 46,
        97, 100, 100, 32, 61, 62, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 49, 59, 32,
        125, 44, 32, 46, 100, 105, 118, 32, 61, 62, 32, 123, 32, 114, 101, 116, 117, 114, 110,
        32, 50, 59, 32, 125, 44, 32, 95, 32, 61, 62, 32, 123, 32, 114, 101, 116, 117, 114,
        110, 32, 48, 59, 32, 125, 32, 125, 32, 114, 101, 116, 117, 114, 110, 32, 48, 59, 32,
        125,
    };
}

// The REJECT #2 source (a CLOSED enum switch missing `.c` with no `_` arm):
//   enum E: u32 { a, b, c }
//   export fn f(x: u32) -> u32 {
//     var k: E = .a;
//     switch k { .a => { return 1; }, .b => { return 2; } }
//     return 0;
//   }
fn nonex_bytes() -> [133]u8 {
    return .{
        101, 110, 117, 109, 32, 69, 58, 32, 117, 51, 50, 32, 123, 32, 97, 44, 32, 98, 44,
        32, 99, 32, 125, 32, 101, 120, 112, 111, 114, 116, 32, 102, 110, 32, 102, 40, 120, 58,
        32, 117, 51, 50, 41, 32, 45, 62, 32, 117, 51, 50, 32, 123, 32, 118, 97, 114, 32,
        107, 58, 32, 69, 32, 61, 32, 46, 97, 59, 32, 115, 119, 105, 116, 99, 104, 32, 107,
        32, 123, 32, 46, 97, 32, 61, 62, 32, 123, 32, 114, 101, 116, 117, 114, 110, 32, 49,
        59, 32, 125, 44, 32, 46, 98, 32, 61, 62, 32, 123, 32, 114, 101, 116, 117, 114, 110,
        32, 50, 59, 32, 125, 32, 125, 32, 114, 101, 116, 117, 114, 110, 32, 48, 59, 32, 125,
    };
}

// ----- accept case: emit C bytes -----

// Emitted-C byte length for the accept source.
export fn emit_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [276]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_len(&sb) as u32;
    sb_free(&sb);
    return out;
}

// Emitted-C byte `i` for the accept source.
export fn emit_byte(i: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [276]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var sb: StrBuf = emit_c_run(s, &m);
    let out: u32 = sb_byte(&sb, i as usize) as u32;
    sb_free(&sb);
    return out;
}

// Semantic-error count for the accept source (must be 0).
export fn accept_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [276]u8 = accept_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}

// ----- reject #1: unknown variant arm -----

// Semantic-error count for the unknown-variant source (must be >= 1).
export fn unknown_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [172]u8 = unknown_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}

// First semantic-error code for the unknown-variant source (must be `unknown_variant` = 10).
export fn unknown_first_err() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [172]u8 = unknown_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_first_err(&st);
    sema_free(&st);
    return out;
}

// ----- reject #2: nonexhaustive closed-enum switch -----

// Semantic-error count for the nonexhaustive source (must be >= 1).
export fn nonex_err_count() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [133]u8 = nonex_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_err_count(&st);
    sema_free(&st);
    return out;
}

// First semantic-error code for the nonexhaustive source (must be `nonexhaustive_switch` = 12).
export fn nonex_first_err() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var b: [133]u8 = nonex_bytes();
    let s: []const u8 = mem.as_bytes(&b);
    var st: SmState = sema_check(s, &m);
    let out: u32 = sema_first_err(&st);
    sema_free(&st);
    return out;
}
