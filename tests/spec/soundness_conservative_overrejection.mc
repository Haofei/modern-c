// SPEC: section=18.1,D.1
// SPEC: milestone=soundness-conservative-overrejection
// SPEC: phase=sema
// SPEC: expect=pass
// SPEC: check=conservative-overrejection-retired

// HONESTY FIXTURE — formerly documented over-rejection inside the conservative envelope.
//
// Constant-index, singleton dynamic-index, and wildcard multi-element dynamic-index
// array-element aliases are now tracked
// precisely enough to prove the borrow dead when it is used BEFORE the move and never read
// again. These cases used to be EXPECT_ERROR false positives; keeping them here as accept
// cases prevents that over-rejection from returning.
//
// The asymmetry: the WHOLE-VALUE-in-a-struct variant of the same pattern
// (`let h = .{ .p = &t }; pk(h.p); cn(t)`) IS accepted, and so are constant-index
// array-element variants, including successful dynamic indexes into singleton arrays and
// wildcard-tracked dynamic writes into multi-element arrays.
// Move-typed sub-place aliases (`&t.inner`) are precise too.
//
// Dynamic/non-nameable storage may still need conservative treatment elsewhere; this file
// now guards the nameable and singleton cases that have been moved out of that bucket.

move struct Inner { v: u32 }
move struct Outer { inner: Inner }
move struct T { v: u32 }

fn mk_inner(v: u32) -> Inner {
    return .{ .v = v };
}
fn mk_outer() -> Outer {
    return .{ .inner = mk_inner(1) };
}
fn cn_outer(t: Outer) -> u32 {
    let inner: Inner = t.inner;
    unsafe { forget_unchecked(t); }
    return cn_inner(inner);
}
fn cn_inner(t: Inner) -> u32 {
    let v: u32 = t.v;
    unsafe { forget_unchecked(t); }
    return v;
}
fn pkin(p: *Inner) -> u32 {
    return p.v;
}

fn mk() -> T {
    return .{ .v = 1 };
}
fn cn(t: T) -> u32 {
    let v: u32 = t.v;
    unsafe { forget_unchecked(t); }
    return v;
}
fn pk(p: *T) -> u32 {
    return p.v;
}
extern fn id(p: *T) -> *T;

// Accepted: a move-typed subfield borrow `&t.inner`, used BEFORE the move and never
// read after, is precise enough to prove dead at the move.
fn accept_subfield_before() -> u32 {
    let t: Outer = mk_outer();
    let p: *Inner = &t.inner;
    let b: u32 = pkin(p);         // used BEFORE the move — p is dead afterwards
    let a: u32 = cn_outer(t);
    return a + b;
}

// Accepted: array-literal element borrow, used BEFORE the move, never read after.
fn accept_array_element_before() -> u32 {
    let t: T = mk();
    let arr: [1]*T = .{ &t };
    let b: u32 = pk(arr[0]);      // used BEFORE the move — arr[0] is dead afterwards
    let a: u32 = cn(t);
    return a + b;
}

// Accepted: singleton dynamic array-element assignment, used BEFORE the move, never read after.
fn accept_dynamic_singleton_array_element_before(i: usize) -> u32 {
    let t: T = mk();
    var arr: [1]*T = .{ &t };
    arr[i] = &t;
    let b: u32 = pk(arr[i]);      // successful dynamic index denotes arr[0]
    let a: u32 = cn(t);
    return a + b;
}

// Accepted: multi-element dynamic array-element assignment, used BEFORE the move, never
// read after. The unknown element is tracked as arr[*], so the checker no longer has to
// reject the move eagerly.
fn accept_dynamic_multi_array_element_before(i: usize) -> u32 {
    let t: T = mk();
    var arr: [2]*T = .{ &t, &t };
    arr[i] = &t;
    let b: u32 = pk(arr[i]);
    let a: u32 = cn(t);
    return a + b;
}

// Accepted: the wildcard element slot also tracks laundered pointer-returning calls.
fn accept_dynamic_multi_array_element_laundered_before(i: usize) -> u32 {
    let t: T = mk();
    var arr: [2]*T = .{ &t, &t };
    arr[i] = id(&t);
    let b: u32 = pk(arr[i]);
    let a: u32 = cn(t);
    return a + b;
}
