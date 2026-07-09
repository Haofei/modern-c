// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE

// T1.2 (conservative rejection): a `move` value may not be MOVED while a borrow of it (or
// of one of its subfields/elements) has been stored into memory we cannot prove dead — an
// dynamic/non-nameable storage or a sub-place alias. Nameable aggregate fields,
// constant-index array elements, singleton dynamic-index array elements, and wildcard
// multi-element dynamic array-element aliases are tracked
// precisely, so `h.p = &t`, `arr[0] = &t`, `[1]*T`, and `arr[i]` element aliases
// can be accepted when the stored pointer is not used after the move. The earlier checker tracked
// use-after-move only for direct scalar pointer-local aliases (`let p = &t; ...; use(p)`),
// so a borrow laundered into memory and read after the move leaked silently. Rather than
// chase the later read through untrackable memory, we refuse the move itself when the storage
// is not nameable: the borrow could still be live. This closes the subfield cases while
// allowing precise struct-field and constant-index array-element cases.
//
// The accept cases below confirm the rule does NOT reject the legitimate borrow-use-then-
// move pattern (borrow taken, used, and dead before the move).

move struct T { v: u32 }
struct H { p: *T }

fn mk() -> T {
    return .{ .v = 1 };
}
fn cn(t: T) -> u32 {       // consumes (moves) t
    let v: u32 = t.v;
    unsafe { forget_unchecked(t); }
    return v;
}
fn pk(p: *T) -> u32 {      // reads through a borrow
    return p.v;
}
extern fn use_ptr(p: *T) -> u32;
extern fn id(p: *T) -> *T;       // returns the borrow it was given (laundering channel)

fn holder(p: *T) -> H {
    return .{ .p = p };
}

fn use_holder(h: H) -> u32 {
    return pk(h.p);
}

// --- accepted: borrow stored into a nameable struct FIELD by assignment, read, then dead ---
fn accept_struct_field_assign_before_move() -> u32 {
    let t: T = mk();
    var h: H = .{ .p = &t };
    h.p = &t;                     // borrow of t stored in a tracked field alias (h.p)
    let b: u32 = pk(h.p);         // legitimate read BEFORE the move; h.p is dead afterwards
    let a: u32 = cn(t);
    return a + b;
}

// --- rejected: borrow stored into an ARRAY ELEMENT by assignment, then read after move ---
fn reject_array_elem_assign() -> u32 {
    let t: T = mk();
    var arr: [1]*T = .{ &t };
    arr[0] = &t;                  // borrow of t laundered into memory (arr[0])
    let a: u32 = cn(t);
    return a + pk(arr[0]);        // EXPECT_ERROR: E_USE_AFTER_MOVE
}

// --- rejected: borrow stored into an ARRAY-LITERAL ELEMENT, then read after move ---
// The symmetric counterpart of the element-ASSIGNMENT case above. The array-literal
// initializer `.{ &t }` launders &t into arr[0] just as `arr[0] = &t` does; before the
// precise element-alias fix this path was conservatively rejected at the move. Now the move
// is allowed if arr[0] is dead, and the stale read is rejected if it is used after the move.
fn reject_array_literal_elem() -> u32 {
    let t: T = mk();
    let arr: [1]*T = .{ &t };     // borrow of t laundered into memory (arr[0]) at init
    let a: u32 = cn(t);
    return a + pk(arr[0]);        // EXPECT_ERROR: E_USE_AFTER_MOVE
}

// --- accepted: singleton dynamic array-element assignment, read, then dead ---
fn accept_dynamic_singleton_array_elem_assign_before_move(i: usize) -> u32 {
    let t: T = mk();
    var arr: [1]*T = .{ &t };
    arr[i] = &t;                  // in a singleton array, every successful dynamic index is [0]
    let b: u32 = pk(arr[i]);      // legitimate read BEFORE the move; arr[0] is dead afterwards
    let a: u32 = cn(t);
    return a + b;
}

// --- rejected: singleton dynamic array-element assignment, then read after move ---
fn reject_dynamic_singleton_array_elem_assign() -> u32 {
    let t: T = mk();
    var arr: [1]*T = .{ &t };
    let i: usize = 0;
    arr[i] = &t;
    let a: u32 = cn(t);
    return a + pk(arr[i]);        // EXPECT_ERROR: E_USE_AFTER_MOVE
}

// --- accepted: multi-element dynamic array-element assignment, read, then dead ---
fn accept_dynamic_multi_array_elem_assign_before_move(i: usize) -> u32 {
    let t: T = mk();
    var arr: [2]*T = .{ &t, &t };
    arr[i] = &t;                  // unknown element: tracked as a wildcard arr[*] alias
    let b: u32 = pk(arr[i]);      // legitimate read BEFORE the move
    let a: u32 = cn(t);
    return a + b;
}

// --- rejected: multi-element dynamic array-element assignment, dynamic read after move ---
fn reject_dynamic_multi_array_elem_assign() -> u32 {
    let t: T = mk();
    var arr: [2]*T = .{ &t, &t };
    let i: usize = 0;
    arr[i] = &t;
    let a: u32 = cn(t);
    return a + pk(arr[i]);        // EXPECT_ERROR: E_USE_AFTER_MOVE
}

// --- rejected: multi-element dynamic assignment also poisons later constant element reads ---
fn reject_dynamic_multi_array_elem_constant_read() -> u32 {
    let t: T = mk();
    var arr: [2]*T = .{ &t, &t };
    let i: usize = 0;
    arr[i] = &t;
    let a: u32 = cn(t);
    return a + pk(arr[0]);        // EXPECT_ERROR: E_USE_AFTER_MOVE
}

// --- rejected: laundered multi-element dynamic array-element assignment, read after move ---
fn reject_dynamic_multi_array_elem_laundered() -> u32 {
    let t: T = mk();
    var arr: [2]*T = .{ &t, &t };
    let i: usize = 0;
    arr[i] = id(&t);
    let a: u32 = cn(t);
    return a + pk(arr[i]);        // EXPECT_ERROR: E_USE_AFTER_MOVE
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

// --- rejected: borrow buried in an aggregate literal passed by value to a call ---
fn reject_call_arg_aggregate_literal_escape() -> u32 {
    let t: T = mk();
    let b: u32 = use_holder(.{ .p = &t });
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let a: u32 = cn(t);           // the callee may retain the copied aggregate's pointer field
    return a + b;
}

// --- rejected: captured aggregate call result may store an argument borrow ---
fn reject_captured_aggregate_call_result_escape() -> u32 {
    let t: T = mk();
    let h: H = holder(&t);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let a: u32 = cn(t);           // the returned aggregate may still carry the borrow
    return a + pk(h.p);
}

// (Gap #2) Interprocedural borrow laundering through a CALL RESULT. `id(p)` may return the
// borrow it was given; we cannot see what the callee retains. A pointer-returning call whose
// argument borrows the move binding `t` makes its result `q` a DERIVED ALIAS of `t`. A USE of
// `q` after `t` is moved is then a stale-alias use-after-move. The rule is precise (not an
// eager move-refusal): if `q` is dead before the move, nothing fires — so the legitimate
// "launder, use, then move" pattern below still compiles.

// --- rejected: pointer laundered out through a call, then USED after the move ---
fn reject_call_launder_used_after_move() -> u32 {
    let t: T = mk();
    let p: *T = &t;               // direct alias of t
    let q: *T = id(p);            // a borrow of t laundered out through id's pointer result
    let a: u32 = cn(t);           // t is moved
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + pk(q);             // q is a stale alias of the moved t — rejected
}

// --- rejected: the same, laundering `&t` directly (no intermediate alias) ---
fn reject_call_launder_direct() -> u32 {
    let t: T = mk();
    let q: *T = id(&t);           // &t laundered through the pointer-returning call
    let a: u32 = cn(t);           // t is moved
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + pk(q);             // q is stale — rejected
}

// --- accepted: laundered pointer is DEAD before the move (the legitimate pattern) ---
fn accept_call_launder_dead_before_move() -> u32 {
    let t: T = mk();
    let q: *T = id(&t);           // borrow laundered out
    let b: u32 = pk(q);           // ...but used here, BEFORE the move — q is dead afterwards
    return cn(t) + b;             // t may be moved — the laundered alias is no longer read
}
