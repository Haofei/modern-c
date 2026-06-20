// =============================================================================
// MC FEATURE SHOWCASE
// =============================================================================
// One self-verifying program touring the major features of MC (the kernel-profile,
// Zig-like Modern C in this repo). It is an `entry`-mode fixture: `showcase_run()`
// runs every demo and returns 1 iff every result is exactly as expected, so it can
// be compiled and run on BOTH backends (emit-c and emit-llvm) and checked the same
// way. Each section is labelled with the feature it exercises.
//
// Kept self-contained (no imports) and host-runnable: no MMIO volatile loads, no
// inline asm, no paging — just the language itself.

// -----------------------------------------------------------------------------
// 1. Functions, immutable/mutable bindings, checked integer arithmetic
// -----------------------------------------------------------------------------
// Plain `uN`/`iN` are CHECKED integers: overflow traps (it is a bug, not silent
// wraparound). `let` is immutable, `var` is mutable, types can be inferred.
fn add_one(value: u32) -> u32 {
    let base: u32 = value;   // immutable
    var acc: u32 = base;     // mutable
    acc = acc + 1;
    return acc;
}

// -----------------------------------------------------------------------------
// 2. Arithmetic domains: wrap<T>, sat<T>, serial<T>, counter<T>
// -----------------------------------------------------------------------------
// The overflow behaviour is in the TYPE, not the operator.
fn wrap_over(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a + b;            // modular: 0xFFFFFFFF + 1 == 0
}
fn sat_clamp(a: sat<u8>, b: sat<u8>) -> sat<u8> {
    return a + b;            // saturating: 250 + 50 == 255
}

type Seq = serial<u32>;     // sequence numbers with modular ordering
type Tick = counter<u64>;   // free-running monotonic counter

fn seq_before(a: Seq, b: Seq) -> bool {
    return Seq.before(a, b);
}
fn tick_delta(now: Tick, start: Tick) -> wrap<u64> {
    return Tick.delta_mod(now, start);
}

// -----------------------------------------------------------------------------
// 3. Bitwise ops and `packed bits` register-style flags
// -----------------------------------------------------------------------------
packed bits Flags: u8 {
    ready: bool,
    busy: bool,
}

fn set_busy(f: Flags, on: bool) -> Flags {
    var next: Flags = f;
    next.busy = on;          // typed bitfield write
    return next;
}

// -----------------------------------------------------------------------------
// 4. Enums: closed + valued, and `open enum` with `.raw()` / integer cast
// -----------------------------------------------------------------------------
enum Color { Red, Green, Blue }

enum Irq: u8 {
    timer = 32,
    keyboard = 33,
}

open enum DeviceState: u8 {
    idle = 0,
    busy = 1,
    fault = 2,
}

fn irq_code(i: Irq) -> u8 {
    switch i {
        .timer => { return 32; }
        .keyboard => { return 33; }
    }
}

fn state_from(v: u8) -> u8 {
    let s: DeviceState = v as DeviceState;  // open enum accepts any in-range int
    return s.raw();
}

// -----------------------------------------------------------------------------
// 5. Tagged unions + exhaustive `switch` (payload bindings, dotted, wildcard)
// -----------------------------------------------------------------------------
union Token {
    number: u32,
    ident: []mut u8,
    eof,
}

fn token_value(t: Token) -> u32 {
    switch t {
        number(v) => { return v; }
        ident(s) => { return s.len as u32; }
        .eof => { return 0; }
    }
}

// expression-`switch` (arms are values, not blocks)
fn color_rank(c: Color) -> u32 {
    return switch c { .Red => 1, .Green => 2, .Blue => 3 };
}

// -----------------------------------------------------------------------------
// 6. Result<T,E>, `?` propagation, `? else` error remap, `if let`, switch
// -----------------------------------------------------------------------------
enum ParseErr { Empty, TooBig }
enum LayerErr { Failed }

fn parse(x: u32) -> Result<u32, ParseErr> {
    if x == 0 { return err(.Empty); }
    if x > 1000 { return err(.TooBig); }
    return ok(x * 2);
}

fn parse_plus_one(x: u32) -> Result<u32, ParseErr> {
    let v: u32 = parse(x)?;          // `?` propagates the error unchanged
    return ok(v + 1);
}

fn parse_remapped(x: u32) -> Result<u32, LayerErr> {
    let v: u32 = parse(x)? else .Failed;  // remap ParseErr -> LayerErr.Failed
    return ok(v);
}

fn result_or_zero(r: Result<u32, ParseErr>) -> u32 {
    if let ok(v) = r {               // narrow-pattern binding
        return v;
    }
    return 0;
}

// -----------------------------------------------------------------------------
// 7. Structs, generic structs, generic functions
// -----------------------------------------------------------------------------
struct Pair<T> {
    a: T,
    b: T,
}

fn make_pair(comptime T: type, x: T, y: T) -> Pair<T> {
    return .{ .a = x, .b = y };
}

// -----------------------------------------------------------------------------
// 8. `impl` associated functions + a linear `move` resource (opaque)
// -----------------------------------------------------------------------------
// `opaque` makes the field private; `move` makes the value linear — it must be
// consumed exactly once (use-after-consume / forgetting it are compile errors).
opaque move struct Ticket {
    id: u32,
}

impl Ticket {
    fn issue(n: u32) -> Ticket {
        return .{ .id = n };
    }
    fn redeem(t: Ticket) -> u32 {
        let v: u32 = t.id;
        unsafe { forget_unchecked(t); }  // the linear value's single consumption
        return v;
    }
}

// -----------------------------------------------------------------------------
// 9. Traits — Tier 1 static dispatch (`where T: Trait`, monomorphized)
// -----------------------------------------------------------------------------
trait Shape {
    fn area(self: *Self) -> u32;
}

struct Square { side: u32 }
struct Rect { w: u32, h: u32 }

impl Shape for Square {
    fn area(self: *Square) -> u32 { return self.side * self.side; }
}
impl Shape for Rect {
    fn area(self: *Rect) -> u32 { return self.w * self.h; }
}

fn sum_two(comptime T: type, a: *T, b: *T) -> u32 where T: Shape {
    return T.area(a) + T.area(b);    // direct calls after monomorphization
}

// -----------------------------------------------------------------------------
// 10. Traits — Tier 2 dynamic dispatch (`*dyn Trait`, rodata vtable, no heap)
// -----------------------------------------------------------------------------
fn dyn_area(s: *dyn Shape) -> u32 {
    return s.area();                 // vtable->area(data)
}

// -----------------------------------------------------------------------------
// 11. Tuples + destructuring
// -----------------------------------------------------------------------------
fn min_max(x: u32, y: u32) -> (u32, u32) {
    if x < y { return (x, y); }
    return (y, x);
}

// -----------------------------------------------------------------------------
// 12. Arrays, slices, ranges, `for … in`
// -----------------------------------------------------------------------------
fn sum_slice(xs: []mut u32) -> u32 {
    var total: u32 = 0;
    for x in xs {
        total = total + x;
    }
    return total;
}

// -----------------------------------------------------------------------------
// 13. Pointers: `*mut T`, address-of `&`, dereference `.*`
// -----------------------------------------------------------------------------
fn bump(p: *mut u32) -> void {
    p.* = p.* + 1;
}

// -----------------------------------------------------------------------------
// 14. `overlay union` byte views + `bitcast<T>` reinterpretation
// -----------------------------------------------------------------------------
overlay union Word {
    u: u32,
    bytes: [4]u8,
}

fn low_byte(value: u32) -> u8 {
    var w: Word = uninit;
    w.u = value;
    return w.bytes[0];               // little-endian low byte (host)
}

fn float_bits(x: f32) -> u32 {
    return bitcast<u32>(x);          // type-pun via memcpy reinterpret (no UB)
}

// -----------------------------------------------------------------------------
// 15. Secret<T>: constant-time key material (taint can't drive branch/index)
// -----------------------------------------------------------------------------
fn ct_xor(plain: Secret<u8>, key: Secret<u8>) -> Secret<u8> {
    return plain ^ key;              // stays secret
}
fn reveal_byte(s: Secret<u8>) -> u8 {
    unsafe { return reveal(s); }     // the audited declassification escape
}

// -----------------------------------------------------------------------------
// 16. `defer`: scope-exit cleanup (runs in reverse order on the way out)
// -----------------------------------------------------------------------------
global g_defer_log: u32 = 0;

fn defer_inc() -> void { g_defer_log = g_defer_log + 1; }
fn defer_double() -> void { g_defer_log = g_defer_log * 2; }

fn run_with_defer() -> u32 {
    g_defer_log = 0;
    defer defer_inc();    // runs second (reverse order)
    defer defer_double(); // runs first
    return 0;
}

// -----------------------------------------------------------------------------
// 17. Nullability: `?*const T` and `if let` narrowing
// -----------------------------------------------------------------------------
global g_byte: u8 = 7;

fn maybe_byte(present: bool) -> ?*const u8 {
    if present { return &g_byte; }
    return null;
}

fn read_or_zero(present: bool) -> u8 {
    if let p = maybe_byte(present) {  // p : *const u8 inside the block
        return p.*;
    }
    return 0;
}

// -----------------------------------------------------------------------------
// 18. Reflection / comptime: sizeof, alignof, field_offset (folded constants)
// -----------------------------------------------------------------------------
struct Layout {
    a: u32,
    b: u16,
    c: u8,
}

fn layout_probe() -> usize {
    return sizeof(Layout) + alignof(u32) + field_offset(Layout, .b);
}

// -----------------------------------------------------------------------------
// 19. Type aliases
// -----------------------------------------------------------------------------
type Count = u32;

fn count_add(a: Count, b: Count) -> Count {
    return a + b;
}

// =============================================================================
// DRIVER — runs every section and returns 1 iff all results are exactly right.
// =============================================================================
export fn showcase_run() -> u32 {
    var pass: u32 = 1;

    // 1. functions + checked arithmetic
    if add_one(41) != 42 { pass = 0; }

    // 2. arithmetic domains
    let wmax: wrap<u32> = 0xFFFFFFFF;
    let wone: wrap<u32> = 1;
    let wzero: wrap<u32> = 0;
    if (wmax + wone) != wzero { pass = 0; }            // inline wrap binop, compared directly
    if wrap_over(wmax, wone) != wzero { pass = 0; }    // wraps to 0 (call result, direct)
    let s250: sat<u8> = 250;
    let s50: sat<u8> = 50;
    let s255: sat<u8> = 255;
    if (s250 + s50) != s255 { pass = 0; }              // inline sat binop saturates at 255
    let a_seq: Seq = Seq.from(5);     // enter the serial domain explicitly
    let b_seq: Seq = Seq.from(9);
    if !seq_before(a_seq, b_seq) { pass = 0; }
    let now: Tick = Tick.from(100);   // enter the counter domain explicitly
    let start: Tick = Tick.from(60);
    let forty: wrap<u64> = 40;
    if tick_delta(now, start) != forty { pass = 0; }

    // 3. bitwise + packed bits
    let or_bits: u32 = 0xF0 | 0x0F;
    let and_bits: u32 = 0xFF & 0x0F;
    if or_bits != 0xFF { pass = 0; }
    if and_bits != 0x0F { pass = 0; }
    let f0: Flags = .{ .ready = true, .busy = false };
    let f1: Flags = set_busy(f0, true);
    if !f1.busy { pass = 0; }
    if !f1.ready { pass = 0; }

    // 4. enums
    if irq_code(.keyboard) != 33 { pass = 0; }
    if state_from(2) != 2 { pass = 0; }

    // 5. tagged unions + expression switch
    if token_value(number(11)) != 11 { pass = 0; }     // u32 payload
    var abc: [3]u8 = .{ 0x61, 0x62, 0x63 };            // "abc"
    let abc_slice: []mut u8 = abc[0..3];
    if token_value(ident(abc_slice)) != 3 { pass = 0; } // slice payload: s.len
    if token_value(eof()) != 0 { pass = 0; }           // no-payload case
    if color_rank(.Blue) != 3 { pass = 0; }

    // 6. Result / ? / ? else / if let
    if result_or_zero(parse(5)) != 10 { pass = 0; }   // 5*2
    if result_or_zero(parse(0)) != 0 { pass = 0; }    // err -> 0
    switch parse_plus_one(5) {
        ok(v) => { if v != 11 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch parse_remapped(0) {                          // err remapped to LayerErr
        ok(v) => { pass = 0; }
        err(e) => {}
    }

    // 7. generic struct + generic fn
    let p: Pair<u32> = make_pair(u32, 20, 22);
    if (p.a + p.b) != 42 { pass = 0; }

    // 8. associated fns + linear move resource
    let ticket: Ticket = Ticket.issue(7);
    if Ticket.redeem(ticket) != 7 { pass = 0; }

    // 9. traits Tier 1 (static dispatch)
    var sq1: Square = .{ .side = 3 };   // 9
    var sq2: Square = .{ .side = 4 };   // 16
    if sum_two(Square, &sq1, &sq2) != 25 { pass = 0; }
    var r1: Rect = .{ .w = 5, .h = 6 }; // 30
    var r2: Rect = .{ .w = 2, .h = 7 }; // 14
    if sum_two(Rect, &r1, &r2) != 44 { pass = 0; }

    // 10. traits Tier 2 (dynamic dispatch via *dyn)
    var sq3: Square = .{ .side = 5 };
    let shape: *dyn Shape = &sq3;       // checked coercion -> fat pointer
    if dyn_area(shape) != 25 { pass = 0; }

    // 11. tuples + destructuring
    let mm: (u32, u32) = min_max(9, 4);
    let mm_lo: u32 = mm.0;            // positional access
    let mm_hi: u32 = mm.1;
    if mm_lo != 4 { pass = 0; }
    if mm_hi != 9 { pass = 0; }
    let (lo, hi) = min_max(2, 8);     // destructuring bind
    if lo != 2 { pass = 0; }
    if hi != 8 { pass = 0; }

    // 12. arrays + slices + ranges + for-in
    var arr: [4]u32 = .{ 10, 20, 30, 40 };
    var arr_total: u32 = 0;
    for x in arr {                           // for-in over the whole array
        arr_total = arr_total + x;
    }
    if arr_total != 100 { pass = 0; }                  // 10+20+30+40
    let s: []mut u32 = arr[0..3];            // a half-open slice view [0,3)
    if sum_slice(s) != 60 { pass = 0; }                // range [0,3) iterated: 10+20+30

    // 13. pointers
    var n: u32 = 41;
    bump(&n);
    if n != 42 { pass = 0; }

    // 14. overlay union + bitcast
    if low_byte(0x11223344) != 0x44 { pass = 0; }
    if float_bits(1.5) != 0x3FC00000 { pass = 0; }     // IEEE-754 single for 1.5

    // 15. Secret<T> round-trip (plain ^ key ^ key == plain), revealed only at the end
    let key: Secret<u8> = 0x5A;
    let plain: Secret<u8> = 0x0F;
    let cipher: Secret<u8> = ct_xor(plain, key);
    let back: Secret<u8> = ct_xor(cipher, key);
    if reveal_byte(cipher) != 0x55 { pass = 0; }       // 0x0F ^ 0x5A
    if reveal_byte(back) != 0x0F { pass = 0; }

    // 16. defer ordering (reverse): (0*2) then (+1) -> 1
    run_with_defer();
    if g_defer_log != 1 { pass = 0; }

    // 17. nullability + if let
    if read_or_zero(true) != 7 { pass = 0; }
    if read_or_zero(false) != 0 { pass = 0; }

    // 18. reflection / comptime folds
    // sizeof(Layout)=8 (u32 + u16 + u8 + pad), alignof(u32)=4, field_offset(.b)=4 -> 16
    if layout_probe() != 16 { pass = 0; }

    // 19. type aliases
    let c: Count = count_add(40, 2);
    if c != 42 { pass = 0; }

    return pass;
}
