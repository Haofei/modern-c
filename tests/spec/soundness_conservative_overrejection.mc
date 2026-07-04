// SPEC: section=18.1,D.1
// SPEC: milestone=soundness-conservative-overrejection
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE

// HONESTY FIXTURE — documented over-rejection inside the conservative envelope.
//
// The use-after-move rule is SOUND but not COMPLETE: for borrows laundered into a
// sub-place (`&t.inner`) or into ARRAY memory (`.{ &t }` / `arr[0] = &t`), we cannot
// prove the borrow dead at the move, so we refuse the move OUTRIGHT — even when the
// borrow is genuinely used BEFORE the move and never read again (a safe program). This
// is a FALSE POSITIVE: a correct program is rejected.
//
// The asymmetry: the WHOLE-VALUE-in-a-struct variant of the same pattern
// (`let h = .{ .p = &t }; pk(h.p); cn(t)`) IS accepted, because struct-literal fields are
// tracked precisely as field-place aliases that we can prove dead. The sub-place and
// array-element variants are not, so they over-reject.
//
// These cases are recorded here as EXPECT_ERROR so the asymmetry is VISIBLE and MONITORED,
// not hidden. If we ever tighten the analysis to accept them (precise sub-place / array
// liveness), this fixture turns red and we update it deliberately — the false positive is
// tracked, not silently load-bearing. See soundness_use_after_move.mc
// `accept_struct_field_used_before_move` for the variant that DOES (correctly) accept.

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

// FALSE POSITIVE #1: subfield borrow `&t.inner`, used BEFORE the move, never read after.
// This program is SAFE (the borrow is dead at the move) but is rejected conservatively.
fn fp_subfield_before() -> u32 {
    let t: Outer = mk_outer();
    let p: *Inner = &t.inner;
    let b: u32 = pkin(p);         // used BEFORE the move — p is dead afterwards
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let a: u32 = cn_outer(t);    // SAFE in principle, but conservatively refused
    return a + b;
}

// FALSE POSITIVE #2: array-literal element borrow, used BEFORE the move, never read after.
// Same shape as the accepted struct-field variant, but array memory is not liveness-tracked,
// so the move is refused. Recorded so the array/struct asymmetry stays visible.
fn fp_array_element_before() -> u32 {
    let t: T = mk();
    let arr: [1]*T = .{ &t };
    let b: u32 = pk(arr[0]);      // used BEFORE the move — arr[0] is dead afterwards
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let a: u32 = cn(t);          // SAFE in principle, but conservatively refused
    return a + b;
}
