// Tier 2 traits (docs/traits-design.md §4,5,7,8): `*dyn Trait` trait objects with
// a compiler-emitted rodata vtable and fat-pointer dispatch — the dynamic-dispatch
// counterpart to the Tier 1 demo's monomorphized direct calls.
//
// `Shape` is object-safe (one borrow-self method). Two impls (Square, Rect) compute
// different areas. We build `*dyn Shape` values via the CHECKED coercion `&x` from
// concrete stack objects (NO heap — the vtable is `static const` rodata), store a
// HETEROGENEOUS array of `*dyn Shape`, and dispatch `s.area()` through the vtable in
// a loop. Each element resolves to a DIFFERENT impl via its own vtable pointer, so a
// wrong dispatch changes the digest. This is a genuine indirect call: the array mixes
// Square and Rect, so the call cannot be devirtualized to a single target.

trait Shape {
    fn area(self: *Self) -> u32;
    fn sides(self: *Self) -> u32;
}

struct Square {
    side: u32,
}

struct Rect {
    w: u32,
    h: u32,
}

impl Shape for Square {
    fn area(self: *Square) -> u32 {
        return self.side * self.side;
    }
    fn sides(self: *Square) -> u32 {
        return 4;
    }
}

impl Shape for Rect {
    fn area(self: *Rect) -> u32 {
        return self.w * self.h;
    }
    fn sides(self: *Rect) -> u32 {
        return 4;
    }
}

// --- Uniform `*T -> *dyn Shape` coercion at NON-let positions (the bug fix) ---
// The coercion + vtable synthesis is ONE typed conversion applied at every
// assignment context. Each of these forms a `*dyn Shape` from a `*T` VALUE
// (a `*Square`/`*Rect` parameter, not `&x` at the same scope), so the vtable is
// synthesized from the static pointee type T. Before the fix these miscompiled
// (invalid IR / uninitialized vtable) — the coercion only ran at let/array.

// `*dyn` formed at a RETURN, from a `*Square` PARAMETER.
fn square_as_dyn(p: *Square) -> *dyn Shape {
    return p;
}

// A struct holding a `*dyn Shape` field, initialized from a `*Rect` parameter
// (the coercion runs at the struct-field init).
struct DynHolder {
    inner: *dyn Shape,
}

fn hold_rect(p: *Rect) -> DynHolder {
    return .{ .inner = p };
}

// Dispatch through a `*dyn Shape` passed as a call ARGUMENT (the coercion forms
// the fat pointer at the call site). Sums both vtable slots so a wrong dispatch
// changes the digest.
fn dispatch_arg(s: *dyn Shape) -> u32 {
    return s.area() + s.sides();
}

export fn dyn_run() -> u32 {
    var sq1: Square = .{ .side = 3 };    // area 9
    var rc1: Rect = .{ .w = 5, .h = 6 }; // area 30
    var sq2: Square = .{ .side = 4 };    // area 16
    var rc2: Rect = .{ .w = 2, .h = 7 }; // area 14

    // The checked coercion: `&x` -> `*dyn Shape` emits {data=&x, vtable=&__vt_Type_Shape}.
    // Safe code cannot fabricate the vtable; only an impl-backed `&x` reaches `*dyn`.
    var shapes: [4]*dyn Shape = .{ &sq1, &rc1, &sq2, &rc2 };

    // Dispatch `s.area()` through the vtable over a HETEROGENEOUS array — each element
    // resolves to a different impl via its own vtable pointer, so the call is a genuine
    // load-through-vtable indirect call (not devirtualizable to one target).
    var sum: u32 = 0;
    var sides_sum: u32 = 0;
    var i: usize = 0;
    while i < 4 {
        let s: *dyn Shape = shapes[i];
        sum = sum + s.area();       // 9 + 30 + 16 + 14 = 69
        sides_sum = sides_sum + s.sides(); // 4 * 4 = 16 (second vtable slot)
        i = i + 1;
    }
    let array_digest: u32 = sum * 1000 + sides_sum; // 69 * 1000 + 16 = 69016

    if sum != 69 {
        return 0;
    }
    if sides_sum != 16 {
        return 0;
    }
    if array_digest != 69016 {
        return 0;
    }

    // --- The fix: `*dyn` formed at RETURN / FIELD / ARG, from a `*T` value ---

    // RETURN: square_as_dyn returns a `*dyn Shape` built from its `*Square` param.
    var sq5: Square = .{ .side = 5 };
    let p5: *Square = &sq5;
    let d_ret: *dyn Shape = square_as_dyn(p5);
    let ret_area: u32 = d_ret.area(); // 25

    // FIELD: hold_rect stores a `*dyn Shape` field initialized from a `*Rect`.
    var rc34: Rect = .{ .w = 3, .h = 4 };
    let p34: *Rect = &rc34;
    let holder: DynHolder = hold_rect(p34);
    let field_area: u32 = holder.inner.area(); // 12

    // ARG: pass a `*Square` value where a `*dyn Shape` is expected (coercion at
    // the call site), dispatching both vtable slots inside the callee.
    var sq6: Square = .{ .side = 6 };
    let p6: *Square = &sq6;
    let arg_result: u32 = dispatch_arg(p6); // area 36 + sides 4 = 40

    if ret_area != 25 {
        return 0;
    }
    if field_area != 12 {
        return 0;
    }
    if arg_result != 40 {
        return 0;
    }

    // Fold the three new paths (return + field + arg) into one digest (kept within
    // u32 so checks=all does not trap), so a miscompile or wrong dispatch on ANY
    // path changes the exact value: 25 * 1000000 + 12 * 1000 + 40 = 25012040.
    let digest: u32 = ret_area * 1000000 + field_area * 1000 + arg_result;
    if digest != 25012040 {
        return 0;
    }
    return 1;
}
