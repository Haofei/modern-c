// SPEC: section=18.1,D.1
// SPEC: milestone=soundness-use-after-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE

// SOUNDNESS SOURCE OF TRUTH — use-after-move / borrow-escape (T1.2).
//
// This fixture is the committed, self-verifying encoding of the use-after-move channel
// matrix. Each `reject_*` case carries an inline `// EXPECT_ERROR:` that the harness
// mechanically matches against a real diagnostic on the target line; each `accept_*` case
// MUST compile clean (the harness fails the build if any of them emits a compiler-error-coded
// diagnostic without an EXPECT_ERROR). So if a previously-closed channel silently re-opens
// (a reject stops rejecting) OR a legitimate pattern starts being rejected (an accept
// regresses), `zig build test` turns red. The claim is no longer trust-me prose — it is
// enforced by this file.
//
// Two diagnostic shapes appear, both E_USE_AFTER_MOVE:
//   * "use of an alias ... after that value was moved" — the precise stale-alias check, on
//     the READ of a scalar pointer alias laundered out of a tracked move binding.
//   * "cannot move this linear `move` value: a borrow ... stored into memory" — the
//     conservative move-refusal, on the MOVE itself, when the borrow escaped into memory
//     we cannot prove dead. Constant-index and singleton dynamic-index array-element aliases
//     are now precise, so those cases reject at the stale read instead.

move struct T { v: u32 }
struct H { p: *T }
struct Holder { p: *T }        // element type for the nested-aggregate channel
struct ArrayHolder { arr: [1]*T } // non-nameable nested array-literal channel
struct Outer { h: Holder }     // struct-of-struct, for the nested-decl channel
struct Deep { o: Outer }       // struct-of-struct-of-struct, for the triple-nested channel

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
fn mkHolder(p: *T) -> Holder {
    return .{ .p = p };
}
fn chooseReader(p: *T) -> fn(*T) -> u32 {
    let x: u32 = p.v;
    return pk;
}
extern fn rd(p: *u32) -> u32;    // reads through a sub-place borrow
extern fn id(p: *T) -> *T;       // returns the borrow it was given (laundering channel)
fn sink(h: Holder) -> void {       // takes an aggregate by value (call-arg escape channel)
    return;
}
fn sinkOuter(o: Outer) -> void {   // takes a nested aggregate by value
    return;
}
extern fn sinkArr(a: [1]*T) -> void;     // takes an array of borrows by value

// ---------------------------------------------------------------------------
// REJECTED channels — precise stale-alias reads (fire on the READ line)
// ---------------------------------------------------------------------------

// 1. direct scalar alias chain, then use after move
fn reject_direct_alias_chain() -> u32 {
    let t: T = mk();
    let p: *T = &t;
    let q: *T = p;                // alias of an alias of t
    let a: u32 = cn(t);          // t moved
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + pk(q);            // q is a stale alias of moved t
}

// 2. reassignment of an alias local, then use after move
fn reject_reassignment_alias() -> u32 {
    let t: T = mk();
    var p: *T = &t;
    p = &t;                       // p re-points at t
    let a: u32 = cn(t);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + pk(p);
}

// 3. borrow laundered into a STRUCT-LITERAL field, read after move
fn reject_struct_literal_field() -> u32 {
    let t: T = mk();
    let h: H = .{ .p = &t };      // &t escapes into h.p
    let a: u32 = cn(t);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + pk(h.p);          // h.p is a stale alias of moved t
}

// 8. call laundering: `id(p)` may retain the borrow; used after move
fn reject_call_launder_used() -> u32 {
    let t: T = mk();
    let q: *T = id(&t);           // &t laundered through a pointer-returning call
    let a: u32 = cn(t);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + pk(q);
}

// ---------------------------------------------------------------------------
// REJECTED channels — conservative move-refusal (fire on the MOVE line, because the
// borrow escaped into memory we cannot prove dead). The later read is omitted so each
// case has exactly one diagnostic to assert.
// ---------------------------------------------------------------------------

// 4. borrow laundered into an ARRAY-LITERAL element (precise stale-alias path).
// Before the fix, `let arr: [1]*T = .{ &t }` did NOT route the array-literal element
// through the escape-into-memory hook, so the move of t was accepted and a later
// pk(arr[0]) read a dangling borrow — a SILENT use-after-move. The element is now tracked
// as a precise alias slot, symmetric with `arr[0] = &t` (assignment) and `.{ .p = &t }`
// (struct literal).
fn reject_array_literal_element() -> u32 {
    let t: T = mk();
    let arr: [1]*T = .{ &t };     // &t escapes into arr[0] at init
    let a: u32 = cn(t);
    return a + arr[0].v;         // EXPECT_ERROR: E_USE_AFTER_MOVE
}

// 5. borrow stored into a nameable struct-FIELD ASSIGNMENT, read before move, then dead.
// This used to be conservatively rejected at the move; the field alias is now tracked
// precisely, so the move is allowed when h.p is not read afterwards.
fn accept_struct_field_assign_before_move() -> u32 {
    let t: T = mk();
    var h: H = .{ .p = &t };
    h.p = &t;
    let b: u32 = h.p.v;
    return cn(t) + b;
}

// 6. borrow laundered into an array-ELEMENT ASSIGNMENT, then moved
fn reject_array_element_assign() -> u32 {
    let t: T = mk();
    var arr: [1]*T = .{ &t };
    arr[0] = &t;
    let a: u32 = cn(t);
    return a + arr[0].v;         // EXPECT_ERROR: E_USE_AFTER_MOVE
}

// 6b. borrow laundered into a singleton dynamic array-ELEMENT ASSIGNMENT, then read after move.
// A successful dynamic index into `[1]*T` denotes element zero, so the checker can keep this
// precise instead of refusing the move conservatively.
fn reject_dynamic_singleton_array_element_assign(i: usize) -> u32 {
    let t: T = mk();
    var arr: [1]*T = .{ &t };
    arr[i] = &t;
    let a: u32 = cn(t);
    return a + arr[i].v;         // EXPECT_ERROR: E_USE_AFTER_MOVE
}

// 6c. borrow laundered into a multi-element dynamic array-ELEMENT ASSIGNMENT, then read
// after move. The write may have targeted any element, so later element reads consult the
// wildcard arr[*] alias and reject once the referent moves.
fn reject_dynamic_multi_array_element_assign(i: usize) -> u32 {
    let t: T = mk();
    var arr: [2]*T = .{ &t, &t };
    arr[i] = &t;
    let a: u32 = cn(t);
    return a + arr[i].v;         // EXPECT_ERROR: E_USE_AFTER_MOVE
}

fn reject_dynamic_multi_array_element_constant_read(i: usize) -> u32 {
    let t: T = mk();
    var arr: [2]*T = .{ &t, &t };
    arr[i] = &t;
    let a: u32 = cn(t);
    return a + arr[0].v;         // EXPECT_ERROR: E_USE_AFTER_MOVE
}

fn reject_dynamic_multi_array_element_laundered(i: usize) -> u32 {
    let t: T = mk();
    var arr: [2]*T = .{ &t, &t };
    arr[i] = id(&t);
    let a: u32 = cn(t);
    return a + arr[i].v;         // EXPECT_ERROR: E_USE_AFTER_MOVE
}

// 7. subfield borrow `&t.v`, whole value then moved
fn reject_subfield_alias() -> u32 {
    let t: T = mk();
    let p: *u32 = &t.v;           // borrow of a sub-place of t
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let a: u32 = cn(t);
    return a + rd(p);
}

// 9. borrow laundered into a NESTED aggregate literal (array of struct holding &t).
// Constant array element fields are now nameable (`arr[0].p`), so the borrow is tracked
// precisely and rejected at the stale read after `t` moves.
fn reject_nested_aggregate_element() -> u32 {
    let t: T = mk();
    let arr: [1]Holder = .{ .{ .p = &t } };   // &t is tracked precisely as arr[0].p
    let a: u32 = cn(t);                       // t moved
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + arr[0].p.v;
}

// 9a. borrow laundered into a nested array literal. The precise array-element scan recurses
// through array literals too, registering `arr[0][0] -> t` instead of conservatively refusing
// the move just because the borrow was nested under another array literal.
fn reject_nested_array_literal_element() -> u32 {
    let t: T = mk();
    let arr: [1][1]*T = .{ .{ &t } };
    let a: u32 = cn(t);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + arr[0][0].v;
}

// 9b. borrow buried in a struct field whose value is an array literal. The nested place is
// nameable as `h.arr[0]`, so the checker tracks it precisely and rejects the stale read after
// `t` moves instead of conservatively refusing the move.
fn reject_struct_field_array_literal_element() -> u32 {
    let t: T = mk();
    let h: ArrayHolder = .{ .arr = .{ &t } };
    let a: u32 = cn(t);
    return a + h.arr[0].v;        // EXPECT_ERROR: E_USE_AFTER_MOVE
}

// 10. borrow laundered through a ptr-to-int round-trip. `&t as usize` drops the provenance
// the borrow tracker follows; a pointer reconstituted from the integer (`n as *T`) would
// then read moved-out storage. We cannot track the integer, so the cast itself is treated
// as a borrow ESCAPE (narrow trigger: `&<live-move-binding> as <integer>`), and the later
// move of t is refused. (The reconstituted `p`/read are omitted so this case has exactly one
// diagnostic; the escape fires at the move.)
fn reject_ptr_to_int_roundtrip() -> u32 {
    let t: T = mk();
    let n: usize = &t as usize;   // address-of-move-value -> integer: provenance dropped, ESCAPE
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let a: u32 = cn(t);          // moving t refused — its borrow escaped through the integer
    return a + (n as u32);
}

// ---------------------------------------------------------------------------
// UNIFIED aggregate/call-flow channels (T1.3) — a borrow that reaches memory or a
// callee AT ANY NESTING DEPTH is caught. Precise (reject-at-use) where a dotted place
// exists; conservative (reject-at-move) where the borrow is buried in a non-nameable
// place (an array element) or copied into a callee by value.
// ---------------------------------------------------------------------------

// 11. NESTED struct-of-struct decl: `o.h.p = &t`. The precise field-alias scan now recurses
// through nested struct literals, registering the dotted place `o.h.p -> t`, so reading it
// after the move is a stale-alias use-after-move (the precise one-level path used to stop at
// `o.h`, leaving this channel silently open).
fn reject_nested_struct_decl() -> u32 {
    let t: T = mk();
    let o: Outer = .{ .h = .{ .p = &t } };   // &t buried at o.h.p
    let a: u32 = cn(t);                       // t moved
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + pk(o.h.p);                     // o.h.p is a stale alias of moved t
}

// 12. TRIPLE-nested struct-of-struct-of-struct decl: `d.o.h.p = &t`. One level deeper than
// case 11 — the recursive precise scan tracks the place at arbitrary struct-literal depth.
fn reject_triple_nested_struct_decl() -> u32 {
    let t: T = mk();
    let d: Deep = .{ .o = .{ .h = .{ .p = &t } } };
    let a: u32 = cn(t);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + pk(d.o.h.p);
}

// 13. borrow laundered into a CALL ARGUMENT aggregate (`sink(.{ .p = &t })`). The escape scan
// now runs on call args too: a struct literal arg carrying `&t` is copied into the callee, so
// the borrow reaches memory we cannot prove dead and the later move of t is refused. (Before,
// the escape scan ran only on decl/assignment initializers — a borrow in a call arg escaped
// silently.)
fn reject_call_arg_struct() -> u32 {
    let t: T = mk();
    sink(.{ .p = &t });          // &t escapes into the callee
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return cn(t);
}

// 14. borrow laundered into a NESTED aggregate CALL ARGUMENT (`sinkOuter(.{ .h = .{ .p = &t } })`).
// The call-arg escape scan recurses through the nested struct literal — symmetric with the
// nested-decl case but flowing into a callee.
fn reject_call_arg_nested_struct() -> u32 {
    let t: T = mk();
    sinkOuter(.{ .h = .{ .p = &t } });
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return cn(t);
}

// 15. borrow laundered into an ARRAY-LITERAL CALL ARGUMENT (`sinkArr(.{ &t })`). An array-literal
// arg carrying `&t` is copied into the callee; the recursive escape scan marks t escaped.
fn reject_call_arg_array() -> u32 {
    let t: T = mk();
    sinkArr(.{ &t });
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return cn(t);
}

// 16. borrow hidden in a direct CALL RESULT aggregate (`let h = mkHolder(&t)`). The returned
// Holder is stored locally and may carry the `&t` argument borrow in aggregate memory, so the
// later move of t must be refused. A bare scalar call arg (`pk(&t)`) remains transient and is
// covered by the accepted pattern below.
fn reject_call_result_aggregate_decl() -> u32 {
    let t: T = mk();
    let h: Holder = mkHolder(&t);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return cn(t);
}

// 17. same channel through assignment into an existing aggregate variable.
fn reject_call_result_aggregate_assignment() -> u32 {
    let t: T = mk();
    var h: Holder = uninit;
    h = mkHolder(&t);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return cn(t);
}

// ---------------------------------------------------------------------------
// ACCEPTED patterns (must compile clean — these are NOT bugs)
// ---------------------------------------------------------------------------

// plain move, no borrow at all
fn accept_plain_move() -> u32 {
    let t: T = mk();
    return cn(t);
}

// borrow taken, used, and dead BEFORE the move (the legitimate transient-borrow pattern)
fn accept_borrow_use_then_move() -> u32 {
    let t: T = mk();
    let x: u32 = pk(&t);          // borrow used here; nothing escapes into memory
    return cn(t) + x;            // t may be moved — the borrow is dead
}

// whole-value borrow stored in a struct, USED before the move (precise field-alias tracking
// proves h.p dead at the move, so the move is accepted — no over-rejection here)
fn accept_struct_field_used_before_move() -> u32 {
    let t: T = mk();
    let h: H = .{ .p = &t };
    let b: u32 = pk(h.p);         // read BEFORE the move
    return cn(t) + b;            // h.p never read again — t may be moved
}

// laundered-through-a-call pointer, dead before the move
fn accept_call_launder_dead_before_move() -> u32 {
    let t: T = mk();
    let q: *T = id(&t);
    let b: u32 = pk(q);           // used BEFORE the move
    return cn(t) + b;
}

// NESTED whole-value borrow stored in a struct-of-struct, USED before the move. The recursive
// precise field-alias scan proves o.h.p dead at the move, so the move is accepted — the unified
// recursion does NOT over-reject the nested legit pattern (symmetric with the one-level accept).
fn accept_nested_struct_field_used_before_move() -> u32 {
    let t: T = mk();
    let o: Outer = .{ .h = .{ .p = &t } };
    let b: u32 = pk(o.h.p);       // read BEFORE the move
    return cn(t) + b;            // o.h.p never read again — t may be moved
}

// NESTED array-literal element borrow, USED before the move. This proves the recursive
// array-place scan is precise and does not keep rejecting once `arr[0][0]` is dead.
fn accept_nested_array_literal_element_used_before_move() -> u32 {
    let t: T = mk();
    let arr: [1][1]*T = .{ .{ &t } };
    let b: u32 = pk(arr[0][0]);
    return cn(t) + b;
}

// Struct-field array literal element borrow, USED before the move. This is the accepted
// counterpart to `reject_struct_field_array_literal_element`.
fn accept_struct_field_array_literal_element_used_before_move() -> u32 {
    let t: T = mk();
    let h: ArrayHolder = .{ .arr = .{ &t } };
    let b: u32 = pk(h.arr[0]);
    return cn(t) + b;
}

// a transient borrow passed as a BARE call argument (not inside an aggregate), used and dead
// before the move. The call-arg escape scan must NOT fire on a top-level `&t` arg (only on a
// borrow buried in an aggregate copied into the callee), so this transient-borrow idiom compiles.
fn accept_bare_borrow_call_arg() -> u32 {
    let t: T = mk();
    let x: u32 = pk(&t);          // &t is a bare arg — transient, does not escape
    return cn(t) + x;
}

// a direct call that returns a plain function pointer cannot store the `&t` argument in
// aggregate memory. It behaves like the scalar bare-borrow call above, not like mkHolder(&t).
fn accept_fn_pointer_call_result() -> u32 {
    let t: T = mk();
    let reader: fn(*T) -> u32 = chooseReader(&t);
    let x: u32 = reader(&t);
    return cn(t) + x;
}

// passing an aggregate with NO move borrow into a callee: nothing escapes, so the move (of an
// unrelated value) is unaffected. Proves the call-arg scan is scoped to `&<move-binding>`.
fn accept_call_arg_no_borrow() -> u32 {
    let t: T = mk();
    let h: Holder = .{ .p = 0 as *T };
    sink(h);                      // aggregate carries no borrow of t
    return cn(t);
}

// --- narrow-trigger guards: the ptr-to-int escape gate must NOT over-fire ----------------
// These prove the gate is `&<move-binding> as int` ONLY. A general integer->pointer cast,
// `&<non-move-local> as usize`, and integer address arithmetic must all still compile clean.

// integer -> pointer (NO move binding involved): the reverse round-trip is unrestricted.
fn accept_usize_to_ptr_non_move(n: usize) -> u32 {
    let p: *u32 = n as *u32;      // reconstituting a pointer from an integer is allowed
    return rd(p);
}

// address-of a NON-move local cast to an integer: not a `move` borrow, so no escape gate.
fn accept_addr_of_non_move_local() -> usize {
    let x: u32 = 7;
    let n: usize = &x as usize;   // &<non-move-local> as usize — allowed
    return n;
}

// integer address arithmetic / construction (the pervasive MMIO/DMA pattern): allowed.
fn accept_address_arith(base: usize, off: usize) -> *u32 {
    let addr: usize = base + off; // address math on plain integers — never a move borrow
    return addr as *u32;          // and the integer->pointer cast back is unrestricted
}
