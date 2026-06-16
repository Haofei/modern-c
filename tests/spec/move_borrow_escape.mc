// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE

// T1.2 (conservative rejection): a `move` value may not be MOVED while a borrow of it (or
// of one of its subfields/elements) has been stored into memory we cannot prove dead — an
// aggregate field, an array element, or a sub-place alias. The earlier checker tracked
// use-after-move only for direct scalar pointer-local aliases (`let p = &t; ...; use(p)`),
// so a borrow laundered into memory and read after the move leaked silently. Rather than
// chase the later read through untrackable memory, we refuse the move itself: the borrow
// could still be live. This closes the struct-assign / array-element / subfield cases.
//
// The accept cases below confirm the rule does NOT reject the legitimate borrow-use-then-
// move pattern (borrow taken, used, and dead before the move).

move struct T { v: u32 }
struct H { p: *T }

extern fn mk() -> T;
extern fn cn(t: T) -> u32;       // consumes (moves) t
extern fn pk(p: *T) -> u32;      // reads through a borrow
extern fn use_ptr(p: *T) -> u32;

// --- rejected: borrow stored into a struct FIELD by assignment, then the value is moved ---
fn reject_struct_field_assign() -> u32 {
    let t: T = mk();
    var h: H = .{ .p = &t };
    h.p = &t;                     // borrow of t laundered into memory (h.p)
    let b: u32 = pk(h.p);         // a legitimate read of the escaped borrow BEFORE the move
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let a: u32 = cn(t);           // moving t would leave h.p dangling — rejected
    return a + b;
}

// --- rejected: borrow stored into an ARRAY ELEMENT, then the value is moved ---
fn reject_array_elem_assign() -> u32 {
    let t: T = mk();
    var arr: [1]*T = .{ &t };
    arr[0] = &t;                  // borrow of t laundered into memory (arr[0])
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let a: u32 = cn(t);           // moving t would leave arr[0] dangling — rejected
    return a + pk(arr[0]);
}

// --- rejected: alias of a SUBFIELD, whole value then moved ---
fn reject_subfield_alias() -> u32 {
    let t: T = mk();
    let p: *u32 = &t.v;           // borrow of a sub-place of t; not whole-binding-trackable
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let a: u32 = cn(t);           // moving t as a whole would leave p dangling — rejected
    return a + *p;
}

// --- accepted: borrow used, then the value is moved (the legitimate pattern) ---
fn accept_borrow_then_move() -> u32 {
    let t: T = mk();
    let x: u32 = pk(&t);          // borrow taken and used here; nothing escapes into memory
    return cn(t) + x;             // t may be moved — the borrow is dead
}

// --- accepted: subfield/transient borrows used, nothing stored, then the value is moved ---
fn accept_subfield_borrow_used() -> u32 {
    let t: T = mk();
    let x: u32 = use_ptr(&t);     // a transient borrow, not stored anywhere
    let y: u32 = t.v;             // read a field by value (still a borrow of t)
    return cn(t) + x + y;         // t may be moved — no live escaped borrow
}
