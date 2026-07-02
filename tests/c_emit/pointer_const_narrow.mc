// Differential-coverage fixture (language gap G30: `*mut T` -> `*const T`/`*T` const-narrow).
// Passing a `*mut T` pointer VALUE where an immutable pointer (`*const T` or the bare `*T`)
// is expected is a safe const-narrowing: a `*mut T` and a `*const T` have the IDENTICAL
// representation (a plain pointer), so the coercion is a no-op / plain assignment on BOTH
// backends. This fixture exercises the coercion at every assignment position:
//   1. a call argument (`readx(q)` where q: *mut S, readx takes `*S`);
//   2. a `let` initializer (`let c: *const S = q;`);
//   3. a return (`return q;` from a `-> *const S` function);
//   4. an explicit `as` cast (`q as *const S`).
// The entry folds every observation into a status word; any divergence on EITHER backend
// (or a regression on the const-narrow lowering) makes it return 0.

struct S { x: u32 }

// Takes the bare immutable `*S` (mutability `.none`).
fn readx(p: *S) -> u32 {
    return p.x;
}

// Takes the explicit `*const S` (mutability `.const`).
fn readx_const(p: *const S) -> u32 {
    return p.x;
}

// mut -> const at a RETURN position.
fn as_const(q: *mut S) -> *const S {
    return q;
}

export fn pointer_const_narrow_run() -> u32 {
    var s: S = .{ .x = 7 };
    let q: *mut S = &s;

    // (1) call argument: `*mut S` -> bare `*S` and -> explicit `*const S`.
    if readx(q) != 7 { return 0; }
    if readx_const(q) != 7 { return 0; }

    // (2) let initializer: `*mut S` -> `*const S` and -> bare `*S`.
    let c: *const S = q;
    let d: *S = q;
    if c.x != 7 { return 0; }
    if d.x != 7 { return 0; }

    // (3) return position (through `as_const`), then read the narrowed pointer.
    let e: *const S = as_const(q);
    if e.x != 7 { return 0; }

    // (4) explicit `as` cast: `*mut S as *const S`.
    let f: *const S = q as *const S;
    if readx_const(f) != 7 { return 0; }

    // Mutate through the original `*mut S` and re-observe through a narrowed alias:
    // confirms the const view is the SAME object (identical representation, no copy).
    s.x = 42;
    if readx(q) != 42 { return 0; }
    let g: *const S = q;
    if g.x != 42 { return 0; }

    return 1;
}
