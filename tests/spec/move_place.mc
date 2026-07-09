// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE,E_MOVE_BRANCH_MISMATCH,E_MOVE_LOOP_RESOURCE,E_RESOURCE_LEAK,E_RESOURCE_OVERWRITE

// Place sensitivity (review issue #2): a `move` struct can have its `move` fields moved
// out one at a time. Moving a field poisons that place, so a second move (or a borrow) of
// the same field is use-after-move, and moving the whole aggregate after a field was taken
// is rejected (it would duplicate the field). `forget_unchecked` discards the husk and is
// allowed after a partial move.

move struct Res { v: u32 }
type ResArray = [2]Res;
type SingleResArray = [1]Res;
type NestedResArray = [1]ResArray;
type ResMatrix = [2][1]Res;
type SingleResMatrix = [1][1]Res;
move struct Pair { a: Res, b: Res }
move struct Nest { p: Pair }
move struct ResArrayBox { items: [2]Res }
move struct SingleResArrayBox { items: [1]Res }
move struct ResMatrixBox { items: ResMatrix }
struct ResPtrHolder { p: *Res }
struct NestedResPtrHolder { inner: ResPtrHolder }
const FIRST_INDEX: usize = 0;
const SECOND_INDEX: usize = FIRST_INDEX + 1;

fn mkres(v: u32) -> Res {
    return .{ .v = v };
}
fn mk() -> Pair {
    return .{ .a = mkres(1), .b = mkres(2) };
}
fn mknest() -> Nest {
    return .{ .p = mk() };
}
fn mkbox() -> ResArrayBox {
    return .{ .items = .{ mkres(1), mkres(2) } };
}
fn mksinglebox() -> SingleResArrayBox {
    return .{ .items = .{ mkres(1) } };
}
fn mkmatrixbox() -> ResMatrixBox {
    return .{ .items = .{ .{ mkres(1) }, .{ mkres(2) } } };
}
fn consume(r: Res) -> u32 {
    let v: u32 = r.v;
    unsafe { forget_unchecked(r); }
    return v;
}
fn consume_index(r: Res) -> usize {
    consume(r);
    return 0;
}
fn peek(r: *Res) -> u32 {
    return r.v;
}
fn peek_holder(h: ResPtrHolder) -> u32 {
    return peek(h.p);
}
fn peek_ptr_array(ptrs: [1]*Res) -> u32 {
    return peek(ptrs[0]);
}
fn peek_ptr_slice(ptrs: []mut *Res) -> u32 {
    return peek(ptrs[0]);
}
fn peek_res_array(arr: *ResArray) -> u32 {
    return peek(&arr.*[0]);
}
fn peek_res_matrix(matrix: *ResMatrix) -> u32 {
    return peek(&matrix.*[0][0]);
}
fn id_res(r: *Res) -> *Res {
    return r;
}
extern fn dynamic_index() -> usize;
extern fn external_res_ptr() -> *Res;
fn take_whole(p: Pair) -> u32 {
    let a: Res = p.a;
    let b: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(a) + consume(b);
}

// Accepted: fixed-array elements of `move` resources are tracked as constant-index
// places, so each element can be moved exactly once before the array husk is discarded.
fn accept_move_each_array_element() -> u32 {
    let arr: [2]Res = .{ mkres(1), mkres(2) };
    let x: Res = arr[0];
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: a moved-out array element can be reinitialized before it is moved again.
fn accept_reinitialize_array_element() -> u32 {
    var arr: [2]Res = .{ mkres(1), mkres(2) };
    let x: Res = arr[0];
    let y: u32 = consume(x);
    arr[0] = mkres(y + 1);
    let a: Res = arr[0];
    let b: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(a) + consume(b);
}

// Accepted: a deferred cleanup reserves a constant-index array element place,
// so it is not reported as leaked on the function exit edge.
fn accept_defer_array_element() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer consume(arr[0]);
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(y);
}

// Accepted: a deferred cleanup block reserves the move value it consumes, just
// like a direct `defer consume(r)` expression.
fn accept_defer_block_consumes_root() -> u32 {
    let r: Res = mkres(1);
    defer {
        consume(r);
    };
    return 0;
}

// Accepted: move resources created inside a deferred cleanup block are scoped to
// that cleanup and can be consumed by later cleanup statements.
fn accept_defer_block_local_move_consumed() -> u32 {
    defer {
        let r: Res = mkres(1);
        consume(r);
    };
    return 0;
}

// Accepted: aliases to cleanup-local move resources are ordinary cleanup-local
// borrows, not outer deferred borrows that should block the later cleanup consume.
fn accept_defer_block_cleanup_local_alias_before_consume() -> u32 {
    defer {
        let r: Res = mkres(1);
        let p: *Res = &r;
        peek(p);
        consume(r);
    };
    return 0;
}

// Rejected: cleanup-local aliases are still tracked inside the cleanup block, so
// using one after consuming the cleanup-local referent is stale.
fn reject_defer_block_cleanup_local_alias_after_consume() -> u32 {
    defer {
        let r: Res = mkres(1);
        let p: *Res = &r;
        consume(r);
        peek(p); // EXPECT_ERROR: E_USE_AFTER_MOVE
    };
    return 0;
}

// Accepted: cleanup-local aggregate aliases can be read while their cleanup-local
// referent is still live.
fn accept_defer_block_cleanup_local_aggregate_alias_before_consume() -> u32 {
    defer {
        let r: Res = mkres(1);
        let h: ResPtrHolder = .{ .p = &r };
        peek_holder(h);
        consume(r);
    };
    return 0;
}

// Rejected: cleanup-local struct fields that hold aliases are stale after their
// cleanup-local referent has been consumed.
fn reject_defer_block_cleanup_local_struct_alias_after_consume() -> u32 {
    defer {
        let r: Res = mkres(1);
        let h: ResPtrHolder = .{ .p = &r };
        consume(r);
        peek_holder(h); // EXPECT_ERROR: E_USE_AFTER_MOVE
    };
    return 0;
}

// Rejected: cleanup-local array elements that hold aliases are stale after their
// cleanup-local referent has been consumed.
fn reject_defer_block_cleanup_local_array_alias_after_consume() -> u32 {
    defer {
        let r: Res = mkres(1);
        let ptrs: [1]*Res = .{ &r };
        consume(r);
        peek_ptr_array(ptrs); // EXPECT_ERROR: E_USE_AFTER_MOVE
    };
    return 0;
}

// Rejected: reassigning a cleanup-local scalar alias updates the tracked
// referent, so stale reads follow the reassignment target.
fn reject_defer_block_cleanup_local_scalar_alias_reassignment() -> u32 {
    defer {
        let r: Res = mkres(1);
        let s: Res = mkres(2);
        var p: *Res = &r;
        p = &s;
        consume(s);
        peek(p); // EXPECT_ERROR: E_USE_AFTER_MOVE
        consume(r);
    };
    return 0;
}

// Accepted: reassigning a cleanup-local alias to an untracked pointer clears the
// stale-alias fact instead of leaving a fake cleanup-local move slot behind.
fn accept_defer_block_cleanup_local_scalar_alias_reassigned_unknown() -> u32 {
    defer {
        let r: Res = mkres(1);
        var p: *Res = &r;
        p = external_res_ptr();
        consume(r);
        peek(p);
    };
    return 0;
}

// Rejected: cleanup-local aggregate field assignments also re-derive alias
// referents before later by-value calls read the aggregate.
fn reject_defer_block_cleanup_local_struct_alias_reassignment() -> u32 {
    defer {
        let r: Res = mkres(1);
        let s: Res = mkres(2);
        var h: ResPtrHolder = .{ .p = &r };
        h.p = &s;
        consume(s);
        peek_holder(h); // EXPECT_ERROR: E_USE_AFTER_MOVE
        consume(r);
    };
    return 0;
}

// Rejected: cleanup-local array element assignments also update alias referents.
fn reject_defer_block_cleanup_local_array_alias_reassignment() -> u32 {
    defer {
        let r: Res = mkres(1);
        let s: Res = mkres(2);
        var ptrs: [1]*Res = .{ &r };
        ptrs[0] = &s;
        consume(s);
        peek_ptr_array(ptrs); // EXPECT_ERROR: E_USE_AFTER_MOVE
        consume(r);
    };
    return 0;
}

// Rejected: if cleanup control flow can leave an alias pointing at different
// cleanup-local resources, later use is conservative even if only one resource
// has been consumed.
fn reject_defer_block_branch_divergent_cleanup_local_alias(flag: bool) -> u32 {
    defer {
        let r: Res = mkres(1);
        let s: Res = mkres(2);
        var p: *Res = &r;
        if flag {
            p = &s;
        }
        consume(s);
        peek(p); // EXPECT_ERROR: E_USE_AFTER_MOVE
        consume(r);
    };
    return 0;
}

// Rejected: aggregate alias fields get the same conservative branch join inside
// deferred cleanup blocks.
fn reject_defer_block_branch_divergent_cleanup_local_struct_alias(flag: bool) -> u32 {
    defer {
        let r: Res = mkres(1);
        let s: Res = mkres(2);
        var h: ResPtrHolder = .{ .p = &r };
        if flag {
            h.p = &s;
        }
        consume(s);
        peek_holder(h); // EXPECT_ERROR: E_USE_AFTER_MOVE
        consume(r);
    };
    return 0;
}

// Rejected: move resources created inside a deferred cleanup block must be
// consumed before cleanup exits.
fn reject_defer_block_local_move_leak() -> u32 {
    defer {
        let r: Res = mkres(1); // EXPECT_ERROR: E_RESOURCE_LEAK
    };
    return 0;
}

// Rejected: a deferred expression that only borrows a move value still runs at
// cleanup time, so the value cannot be moved before the defer runs.
fn reject_move_after_deferred_root_borrow() -> u32 {
    let r: Res = mkres(1);
    defer peek(&r);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(r);
}

// Rejected: a deferred cleanup block that borrows a move value keeps the value
// live until cleanup.
fn reject_move_after_deferred_block_borrow() -> u32 {
    let r: Res = mkres(1);
    defer {
        peek(&r);
    };
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(r);
}

// Rejected: deferred aggregate literal arguments can also carry borrows that
// remain live until cleanup.
fn reject_move_after_deferred_struct_literal_borrow() -> u32 {
    let r: Res = mkres(1);
    defer peek_holder(.{ .p = &r });
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(r);
}

// Rejected: deferred array literal arguments are traversed for hidden cleanup
// borrows too.
fn reject_move_after_deferred_array_literal_borrow() -> u32 {
    let r: Res = mkres(1);
    defer peek_ptr_array(.{ &r });
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(r);
}

// Rejected: deferred slice bases are evaluated at cleanup time too, so a
// temporary aggregate base can hide a borrow that must reserve the resource.
fn reject_move_after_deferred_slice_literal_borrow() -> u32 {
    let r: Res = mkres(1);
    defer peek_ptr_slice(.{ &r }[0..1]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(r);
}

// Accepted: slice range bounds are part of deferred expression evaluation, so
// a move consumed by a cleanup bound is reserved instead of leaking at return.
fn accept_deferred_slice_bound_consume() -> []mut u8 {
    var buf: [4]u8 = .{ 0, 1, 2, 3 };
    let r: Res = mkres(1);
    defer buf[consume_index(r)..1];
    return buf[0..1];
}

// Rejected: cleanup ownership cannot depend on which switch arm runs inside a
// deferred cleanup block.
fn reject_defer_block_switch_path_only_consume(flag: bool) -> u32 {
    let r: Res = mkres(1); // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
    defer {
        switch flag {
            true => { consume(r); },
            _ => {},
        }
    };
    return 0;
}

// Rejected: a deferred borrow that exists only in one cleanup switch arm is also
// path-dependent and cannot be ignored.
fn reject_defer_block_switch_path_only_borrow(flag: bool) -> u32 {
    let r: Res = mkres(1); // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
    defer {
        switch flag {
            true => { peek(&r); },
            _ => {},
        }
    };
    unsafe { forget_unchecked(r); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: a deferred consume inside a cleanup loop may run zero or multiple
// times, so it cannot reserve an outer move value precisely.
fn reject_defer_block_loop_consume(flag: bool) -> u32 {
    let r: Res = mkres(1); // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    defer {
        while flag {
            consume(r);
        }
    };
    return 0;
}

// Rejected: a deferred borrow inside a cleanup loop is also path-dependent and
// cannot protect the referent precisely.
fn reject_defer_block_loop_borrow(flag: bool) -> u32 {
    let r: Res = mkres(1); // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    defer {
        while flag {
            peek(&r);
        }
    };
    unsafe { forget_unchecked(r); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: deferred borrows protect subplaces too; moving the whole aggregate
// would invalidate the field borrow before cleanup.
fn reject_whole_after_deferred_field_borrow() -> u32 {
    let p: Pair = mk();
    defer peek(&p.a);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return take_whole(p);
}

// Rejected: deferred borrows of concrete array elements protect the owning
// array from being forgotten before cleanup.
fn reject_whole_after_deferred_array_element_borrow() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer peek(&arr[0]);
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: deferred borrows of dynamic array elements are tracked as wildcard
// places and also protect the owning array before cleanup.
fn reject_whole_after_deferred_dynamic_array_element_borrow(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer peek(&arr[i]);
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: a deferred call through a copied pointer alias keeps the referent
// live until cleanup, so moving the referent first is a use-after-move.
fn reject_move_after_deferred_alias_borrow() -> u32 {
    let r: Res = mkres(1);
    let p: *Res = &r;
    defer peek(p);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(r);
}

// Rejected: deferred borrows through named full aliases to nested wildcard
// places reserve the possible nested element until cleanup.
fn reject_move_after_deferred_full_alias_nested_array_element_borrow(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let p: *Res = &matrix[i][0];
    defer peek(p);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(x);
}

// Rejected: copied full aliases preserve the same nested wildcard deferred
// borrow reservation.
fn reject_move_after_deferred_copied_full_alias_nested_array_element_borrow(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let p: *Res = &matrix[i][0];
    let q: *Res = p;
    defer peek(q);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(x);
}

// Rejected: field-rooted nested wildcard full aliases reserve the same composed
// place when borrowed by a deferred expression.
fn reject_move_after_deferred_full_alias_nested_array_field_element_borrow(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    let p: *Res = &box.items[i][0];
    defer peek(p);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = box.items[0][0];
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(x);
}

// Rejected: cleanup-block locals that hold full aliases also reserve the nested
// wildcard place when the cleanup later borrows through the alias.
fn reject_move_after_defer_block_full_alias_nested_array_element_borrow(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    defer {
        let p: *Res = &matrix[i][0];
        peek(p);
    };
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(x);
}

// Rejected: copied cleanup-block full aliases keep the same nested wildcard
// deferred borrow reservation.
fn reject_move_after_defer_block_copied_full_alias_nested_array_element_borrow(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    defer {
        let p: *Res = &matrix[i][0];
        let q: *Res = p;
        peek(q);
    };
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(x);
}

// Rejected: cleanup-block full aliases also compose through field-rooted nested
// wildcard places.
fn reject_move_after_defer_block_full_alias_nested_array_field_element_borrow(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    defer {
        let p: *Res = &box.items[i][0];
        peek(p);
    };
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = box.items[0][0];
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(x);
}

// Rejected: cleanup-block locals that hold laundered aliases also reserve the
// nested wildcard place when borrowed by the cleanup.
fn reject_move_after_defer_block_laundered_nested_array_element_borrow(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    defer {
        let p: *Res = id_res(&matrix[i][0]);
        peek(p);
    };
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(x);
}

// Rejected: cleanup-block laundered aliases compose through field-rooted nested
// wildcard places too.
fn reject_move_after_defer_block_laundered_nested_array_field_element_borrow(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    defer {
        let p: *Res = id_res(&box.items[i][0]);
        peek(p);
    };
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = box.items[0][0];
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(x);
}

// Rejected: deferred borrows through laundered nested wildcard aliases reserve
// the possible nested element until cleanup.
fn reject_move_after_deferred_laundered_nested_array_element_borrow(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    defer peek(id_res(&matrix[i][0]));
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(x);
}

// Rejected: the same deferred laundered nested wildcard borrow composes through
// move-struct array fields.
fn reject_move_after_deferred_laundered_nested_array_field_element_borrow(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    defer peek(id_res(&box.items[i][0]));
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = box.items[0][0];
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(x);
}

// Rejected: borrow-only statements such as assert must still inspect binary
// operands for stale aliases.
fn reject_assert_binary_stale_alias_after_move() -> u32 {
    let r: Res = mkres(1);
    let p: *Res = &r;
    let y: u32 = consume(r);
    assert(peek(p) != 0); // EXPECT_ERROR: E_USE_AFTER_MOVE
    return y;
}

// Rejected: borrow-only statements must also inspect binary operands for
// moved-out subplaces reached through address-of.
fn reject_assert_binary_moved_field_borrow() -> u32 {
    let p: Pair = mk();
    let a: Res = p.a;
    let y: u32 = consume(a);
    assert(peek(&p.a) != 0); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(p); }
    return y;
}

// Rejected: borrow-only block expressions must inspect their statements for
// stale aliases.
fn reject_assert_block_stale_alias_after_move() -> u32 {
    let r: Res = mkres(1);
    let p: *Res = &r;
    let y: u32 = consume(r);
    assert({
        peek(p) != 0; // EXPECT_ERROR: E_USE_AFTER_MOVE
    });
    return y;
}

// Rejected: moves inside borrow-only block expressions must poison the same
// outer place after the block exits.
fn reject_assert_block_field_move_then_reuse() -> u32 {
    let p: Pair = mk();
    assert({
        let a: Res = p.a;
        let y: u32 = consume(a);
        y != 0;
    });
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = p.a;
    unsafe { forget_unchecked(p); }
    return consume(z);
}

// Rejected: a deferred borrow hidden under an ordinary binary expression still
// runs during cleanup and keeps the value live until then.
fn reject_move_after_deferred_binary_borrow() -> u32 {
    let r: Res = mkres(1);
    defer peek(&r) != 0;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(r);
}

// Rejected: a deferred borrow hidden only on the RHS of a short-circuit cleanup
// expression is path-sensitive and cannot be ignored.
fn reject_deferred_short_circuit_rhs_borrow(flag: bool) -> u32 {
    let r: Res = mkres(1);
    defer flag && (peek(&r) != 0); // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
    unsafe { forget_unchecked(r); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: a deferred consume hidden only on the RHS of a short-circuit cleanup
// expression would leave cleanup ownership path-dependent.
fn reject_deferred_short_circuit_rhs_consume(flag: bool) -> u32 {
    let r: Res = mkres(1);
    defer flag && (consume(r) != 0); // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
    return 0;
}

// Accepted: aliases to fixed arrays of move resources are trackable for local
// constant-index element places.
fn accept_move_array_alias_elements() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[0];
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: nested aliases are still resolved into stable constant-index places.
fn accept_move_nested_array_alias_element() -> u32 {
    let arr: NestedResArray = .{ .{ mkres(1), mkres(2) } };
    let x: Res = arr[0][0];
    let y: Res = arr[0][1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: ordinary internal function parameters that are fixed arrays of move
// resources are tracked as parameter-rooted element places.
fn accept_move_array_param_elements(arr: ResArray) -> u32 {
    let x: Res = arr[0];
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: internal parameter-rooted nested move arrays also produce stable
// element places when the suffix is nameable.
fn accept_move_matrix_param_elements(matrix: ResMatrix) -> u32 {
    let x: Res = matrix[0][0];
    let y: Res = matrix[1][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Accepted: an index local initialized from a constant denotes the same stable
// element place as the literal index.
fn accept_const_index_variable_array_element() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let i: usize = 0;
    let x: Res = arr[i];
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: reassigning a tracked constant-index local to another constant updates
// the stable element place.
fn accept_reassigned_const_index_variable_array_element() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var i: usize = 0;
    i = 1;
    let x: Res = arr[0];
    let y: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: arithmetic over a tracked constant-index local can still fold to a
// stable element place.
fn accept_const_index_variable_arithmetic_array_element() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let i: usize = 0;
    let x: Res = arr[i];
    let y: Res = arr[i + 1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: copied constant-index locals keep their stable element-place fact.
fn accept_copied_const_index_variable_array_element() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let i: usize = 0;
    let j: usize = i + 1;
    let x: Res = arr[i];
    let y: Res = arr[j];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: reassigning from another constant-index local updates the tracked
// stable element place.
fn accept_reassigned_copied_const_index_variable_array_element() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let i: usize = 1;
    var j: usize = 0;
    j = i;
    let x: Res = arr[0];
    let y: Res = arr[j];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: a const-index local remains precise across a branch join when every
// reachable arm leaves it with the same constant value.
fn accept_branch_preserves_matching_const_index(cond: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var i: usize = 0;
    if cond {
        i = 1;
    } else {
        i = 1;
    }
    let x: Res = arr[0];
    let y: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: a const-index local also remains precise across a switch join when
// every reachable arm leaves it with the same constant value.
fn accept_switch_preserves_matching_const_index(cond: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var i: usize = 0;
    switch cond {
        true => {
            i = 1;
        },
        false => {
            i = 1;
        },
    }
    let x: Res = arr[0];
    let y: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: the same switch-join const-index fact is used for move-struct array
// fields, so `box.items[i]` remains a concrete element place after matching arms.
fn accept_switch_preserves_matching_const_index_array_field_element(cond: bool) -> u32 {
    let box: ResArrayBox = mkbox();
    var i: usize = 0;
    switch cond {
        true => {
            i = 1;
        },
        false => {
            i = 1;
        },
    }
    let x: Res = box.items[0];
    let y: Res = box.items[i];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Accepted: matching branch arms preserve symbolic index identity, so `j` can
// reinitialize the same dynamic element previously moved through `i`.
fn accept_branch_preserves_matching_symbolic_index(cond: bool, i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    var j: usize = 0;
    if cond {
        j = i;
    } else {
        j = i + 0;
    }
    let x: Res = arr[i];
    arr[j] = mkres(3);
    let y: Res = arr[0 + i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: matching switch arms preserve symbolic index identity too.
fn accept_switch_preserves_matching_symbolic_index(cond: bool, i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    var j: usize = 0;
    switch cond {
        true => {
            j = i * 1;
        },
        false => {
            j = i / 1;
        },
    }
    let x: Res = arr[i];
    arr[j] = mkres(3);
    let y: Res = arr[i - 0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: matching branch arms preserve equivalent symbolic offset facts.
fn accept_branch_preserves_matching_symbolic_offset_index(cond: bool, i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    var j: usize = 0;
    if cond {
        j = i + 1;
    } else {
        j = 1 + i;
    }
    let x: Res = arr[i + 1];
    arr[j] = mkres(3);
    let y: Res = arr[j];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: switch joins preserve matching symbolic offset facts too.
fn accept_switch_preserves_matching_symbolic_offset_index(cond: bool, i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    var j: usize = 0;
    switch cond {
        true => {
            j = i + 1;
        },
        false => {
            j = 2 + i - 1;
        },
    }
    let x: Res = arr[i + 1];
    arr[j] = mkres(3);
    let y: Res = arr[j];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: branch joins preserve matching canonical linear symbolic facts.
fn accept_branch_preserves_matching_symbolic_linear_index(cond: bool, i: usize, j: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    var k: usize = 0;
    if cond {
        k = i + j + 1;
    } else {
        k = 1 + j + i;
    }
    let x: Res = arr[i + j + 1];
    arr[k] = mkres(3);
    let y: Res = arr[k];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: switch joins preserve matching canonical linear symbolic facts too.
fn accept_switch_preserves_matching_symbolic_linear_index(cond: bool, i: usize, j: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    var k: usize = 0;
    switch cond {
        true => {
            k = i - j + 1;
        },
        false => {
            k = 1 + i - j;
        },
    }
    let x: Res = arr[i - j + 1];
    arr[k] = mkres(3);
    let y: Res = arr[k];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: compile-time constant index expressions also denote stable places.
fn accept_comptime_const_index_array_element() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[FIRST_INDEX];
    let y: Res = arr[SECOND_INDEX];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: an internal function can transfer a fixed array of move resources by
// value as its return value; the caller then owns and tracks the returned array.
fn make_res_array() -> ResArray {
    return .{ mkres(1), mkres(2) };
}
fn make_single_res_array() -> SingleResArray {
    return .{ mkres(1) };
}
fn make_res_matrix() -> ResMatrix {
    return .{ .{ mkres(1) }, .{ mkres(2) } };
}
fn make_single_res_matrix() -> SingleResMatrix {
    return .{ .{ mkres(1) } };
}

fn accept_consume_returned_move_array() -> u32 {
    let arr: ResArray = make_res_array();
    let x: Res = arr[0];
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: a returned move array is not a nameable local place, so a dynamic
// element move cannot be tracked precisely and must fail closed.
fn reject_dynamic_returned_move_array_element(i: usize) -> u32 {
    let x: Res = make_res_array()[i]; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return consume(x);
}

// Rejected: deferred cleanup needs a stable place reservation too; a dynamic
// element of a returned move array has no nameable owner to reserve.
fn reject_defer_dynamic_returned_move_array_element(i: usize) -> u32 {
    defer consume(make_res_array()[i]); // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return 0;
}

// Accepted: a returned singleton move array has no sibling element to leak; any
// in-bounds dynamic index denotes the only element.
fn accept_dynamic_returned_singleton_move_array_element(i: usize) -> u32 {
    let x: Res = make_single_res_array()[i];
    return consume(x);
}

// Accepted: deferred cleanup of a returned singleton element is also precise
// because the temporary contains only the selected element.
fn accept_defer_dynamic_returned_singleton_move_array_element(i: usize) -> u32 {
    defer consume(make_single_res_array()[i]);
    return 0;
}

// Rejected: nested returned move arrays are also non-nameable when indexed
// dynamically through the returned value.
fn reject_dynamic_returned_matrix_element(i: usize) -> u32 {
    let x: Res = make_res_matrix()[i][0]; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return consume(x);
}

// Rejected: a concrete outer index into a returned nested move array still
// leaves the inner dynamic element without a nameable owner place.
fn reject_dynamic_inner_returned_matrix_element(i: usize) -> u32 {
    let x: Res = make_res_matrix()[0][i]; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return consume(x);
}

// Rejected: deferred cleanup of a nested returned move-array element has no
// stable owner place to reserve.
fn reject_defer_dynamic_returned_matrix_element(i: usize) -> u32 {
    defer consume(make_res_matrix()[i][0]); // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return 0;
}

// Rejected: deferred cleanup also cannot reserve an inner dynamic element of a
// concrete outer returned move-array element.
fn reject_defer_dynamic_inner_returned_matrix_element(i: usize) -> u32 {
    defer consume(make_res_matrix()[0][i]); // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return 0;
}

// Accepted: a returned singleton matrix has no untracked outer sibling, and the
// inner singleton dynamic index denotes the only resource.
fn accept_dynamic_inner_returned_singleton_matrix_element(i: usize) -> u32 {
    let x: Res = make_single_res_matrix()[0][i];
    return consume(x);
}

// Accepted: deferred cleanup is precise for the same nested singleton shape.
fn accept_defer_dynamic_inner_returned_singleton_matrix_element(i: usize) -> u32 {
    defer consume(make_single_res_matrix()[0][i]);
    return 0;
}

// Accepted: a returned singleton matrix also has no untracked outer sibling, so
// a dynamic outer index plus concrete inner index denotes the only resource.
fn accept_dynamic_outer_returned_singleton_matrix_element(i: usize) -> u32 {
    let x: Res = make_single_res_matrix()[i][0];
    return consume(x);
}

// Accepted: deferred cleanup is precise for the same dynamic-outer singleton
// returned matrix shape.
fn accept_defer_dynamic_outer_returned_singleton_matrix_element(i: usize) -> u32 {
    defer consume(make_single_res_matrix()[i][0]);
    return 0;
}

// Rejected: a move array literal is also non-nameable, so a dynamic element
// move cannot be represented as a stable local place.
fn reject_dynamic_array_literal_move_element(i: usize) -> u32 {
    let x: Res = .{ mkres(1), mkres(2) }[i]; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return consume(x);
}

// Rejected: deferred cleanup of a dynamic array-literal element has no stable
// owner place to reserve either.
fn reject_defer_dynamic_array_literal_move_element(i: usize) -> u32 {
    defer consume(.{ mkres(1), mkres(2) }[i]); // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return 0;
}

// Accepted: a singleton move array literal has no untracked sibling resource.
fn accept_dynamic_singleton_array_literal_move_element(i: usize) -> u32 {
    let x: Res = .{ mkres(1) }[i];
    return consume(x);
}

// Accepted: the deferred form is precise for the same singleton reason.
fn accept_defer_dynamic_singleton_array_literal_move_element(i: usize) -> u32 {
    defer consume(.{ mkres(1) }[i]);
    return 0;
}

// Rejected: nested move array literals are also non-nameable. A dynamic outer
// index followed by a concrete suffix cannot be represented as a stable place.
fn reject_dynamic_nested_array_literal_move_element(i: usize) -> u32 {
    let x: Res = .{ .{ mkres(1) }, .{ mkres(2) } }[i][0]; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return consume(x);
}

// Accepted: nested singleton literals have no untracked outer or inner sibling.
fn accept_dynamic_inner_nested_singleton_array_literal_move_element(i: usize) -> u32 {
    let x: Res = .{ .{ mkres(1) } }[0][i];
    return consume(x);
}

// Accepted: the deferred singleton nested-literal form is precise too.
fn accept_defer_dynamic_inner_nested_singleton_array_literal_move_element(i: usize) -> u32 {
    defer consume(.{ .{ mkres(1) } }[0][i]);
    return 0;
}

// Accepted: nested singleton array literals also allow a dynamic outer index
// when every dimension contains exactly one possible resource.
fn accept_dynamic_outer_nested_singleton_array_literal_move_element(i: usize) -> u32 {
    let x: Res = .{ .{ mkres(1) } }[i][0];
    return consume(x);
}

// Accepted: deferred cleanup can reserve the same dynamic-outer singleton
// literal element.
fn accept_defer_dynamic_outer_nested_singleton_array_literal_move_element(i: usize) -> u32 {
    defer consume(.{ .{ mkres(1) } }[i][0]);
    return 0;
}

// Rejected: nested literals are still non-nameable when another outer element
// would remain untracked.
fn reject_dynamic_inner_nested_array_literal_move_element(i: usize) -> u32 {
    let x: Res = .{ .{ mkres(1) }, .{ mkres(2) } }[0][i]; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return consume(x);
}

// Rejected: deferred cleanup of a nested dynamic array-literal element also has
// no stable owner place to reserve.
fn reject_defer_dynamic_nested_array_literal_move_element(i: usize) -> u32 {
    defer consume(.{ .{ mkres(1) }, .{ mkres(2) } }[i][0]); // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return 0;
}

// Rejected: deferred cleanup has the same non-nameable-place problem for inner
// dynamic indexes into concrete outer literal elements when another outer
// element would remain untracked.
fn reject_defer_dynamic_inner_nested_array_literal_move_element(i: usize) -> u32 {
    defer consume(.{ .{ mkres(1) }, .{ mkres(2) } }[0][i]); // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return 0;
}

// Accepted: for a singleton fixed array, any in-bounds dynamic index denotes the
// only element, so the checker can use the stable `[0]` place key.
fn accept_dynamic_singleton_array_element(i: usize) -> u32 {
    let arr: SingleResArray = .{ mkres(1) };
    let x: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: a dynamic index into a singleton array still denotes the only
// element, so deferred cleanup can reserve that stable place.
fn accept_defer_dynamic_singleton_array_element(i: usize) -> u32 {
    let arr: SingleResArray = .{ mkres(1) };
    defer consume(arr[i]);
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Accepted: assignment through a dynamic index into a singleton array targets
// the same stable `[0]` place, so a moved-out element can be reinitialized.
fn accept_reinitialize_dynamic_singleton_array_element(i: usize) -> u32 {
    var arr: SingleResArray = .{ mkres(1) };
    let x: Res = arr[i];
    arr[i] = mkres(2);
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: singleton dynamic assignment still observes live-element overwrite
// rules because `arr[i]` is the concrete `arr[0]` place.
fn reject_overwrite_dynamic_singleton_array_element(i: usize) -> u32 {
    var arr: SingleResArray = .{ mkres(1) };
    arr[i] = mkres(2); // EXPECT_ERROR: E_RESOURCE_OVERWRITE
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Accepted: dynamic expressions that are mathematically constant still name a
// concrete element place. `i % 1` is always `0`, so this reinitializes `arr[0]`
// instead of poisoning the whole array through a wildcard place.
fn accept_reinitialize_mod_one_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i % 1];
    arr[0] = mkres(3);
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: a symbolic linear expression that is exactly divisible by the modulo
// divisor also folds to the concrete zero element.
fn accept_reinitialize_symbolic_modulo_zero_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[(i + i) % 2];
    arr[0] = mkres(3);
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: non-exact symbolic modulo does not name a concrete element and
// remains conservatively overlapping with `arr[0]`.
fn reject_non_exact_symbolic_modulo_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i % 2];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: exact symbolic modulo-zero identities compose through move-struct
// array fields, not only direct array roots.
fn accept_reinitialize_symbolic_modulo_zero_array_field_element(i: usize) -> u32 {
    var box: ResArrayBox = mkbox();
    let x: Res = box.items[(i + i) % 2];
    box.items[0] = mkres(3);
    let y: Res = box.items[0];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Accepted: the same concrete-zero identity composes through nested array
// suffixes, so the outer dynamic expression names `matrix[0][0]`.
fn accept_reinitialize_symbolic_modulo_zero_nested_array_element(i: usize) -> u32 {
    var matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[(i + i) % 2][0];
    matrix[0][0] = mkres(3);
    let y: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Rejected: multiplication by zero has the same concrete identity, so a later
// `arr[0]` move overlaps the earlier dynamic-looking move.
fn reject_duplicate_mul_zero_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i * 0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: subtracting the same index identifier is also the concrete element
// `0`, so reinitialization uses the exact element place.
fn accept_reinitialize_sub_self_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i - i];
    arr[0] = mkres(3);
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: grouped same-identifier subtraction still aliases `arr[0]`.
fn reject_duplicate_sub_self_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[(i) - (i)];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: masking with zero has exactly one possible result, so the move
// checker can use the concrete `arr[0]` place.
fn accept_reinitialize_bit_and_zero_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i & 0];
    arr[0] = mkres(3);
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: xor with the same identifier is always zero, so it overlaps a later
// concrete element move.
fn reject_duplicate_xor_self_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i ^ i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: equivalent symbolic expressions also fold to concrete zero for
// subtraction, so `(i + 1) - j` targets `arr[0]` when `j` is the same canonical
// symbolic index.
fn accept_reinitialize_symbolic_subtract_zero_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let j: usize = i + 1;
    let x: Res = arr[(i + 1) - j];
    arr[0] = mkres(3);
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: equivalent symbolic XOR expressions are also exactly zero, so the
// dynamic-looking move overlaps a later concrete `arr[0]` move.
fn reject_duplicate_symbolic_xor_zero_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let j: usize = i + 1;
    let x: Res = arr[(i + 1) ^ j];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: a stable symbolic index into a multi-element array can reinitialize
// the same dynamic place after moving it out.
fn accept_reinitialize_same_symbolic_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    arr[i] = mkres(3);
    let y: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: copied immutable symbolic index facts keep the same dynamic place
// identity, so `j` reinitializes the element moved through `i`.
fn accept_reinitialize_copied_symbolic_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let j: usize = i;
    let x: Res = arr[i];
    arr[j] = mkres(3);
    let y: Res = arr[j];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: identity-preserving arithmetic over a symbolic index keeps the same
// dynamic place identity.
fn accept_reinitialize_symbolic_identity_expr_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    arr[i + 0] = mkres(3);
    let y: Res = arr[0 + i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: copied symbolic facts can also come from identity-preserving index
// expressions, so `j` still names the same dynamic element as `i`.
fn accept_reinitialize_copied_symbolic_identity_expr_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let j: usize = i * 1;
    let x: Res = arr[i];
    arr[j] = mkres(3);
    let y: Res = arr[j / 1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: bounded constant offsets over a symbolic index are canonicalized, so
// equivalent forms such as `i + 1` and `1 + i` name the same dynamic place.
fn accept_reinitialize_symbolic_offset_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i + 1];
    arr[1 + i] = mkres(3);
    let y: Res = arr[i + 1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: copied symbolic offset facts compose with later opposite offsets,
// so `j - 1` is the same dynamic place as `i` when `j` was `i + 1`.
fn accept_reinitialize_copied_symbolic_offset_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let j: usize = i + 1;
    let x: Res = arr[i];
    arr[j - 1] = mkres(3);
    let y: Res = arr[j - 1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: a different symbolic offset may still denote the same array element,
// so it conflicts conservatively with an already-moved symbolic offset place.
fn reject_different_symbolic_offset_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i + 1];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[i + 2];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: commutative symbolic sums with a bounded offset canonicalize to the
// same dynamic place.
fn accept_reinitialize_symbolic_linear_sum_dynamic_multi_array_element(i: usize, j: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i + j + 1];
    arr[j + i + 1] = mkres(3);
    let y: Res = arr[(i + j) + 1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: symbolic subtraction terms also canonicalize when the term order
// and signs describe the same dynamic place.
fn accept_reinitialize_symbolic_linear_difference_dynamic_multi_array_element(i: usize, j: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i - j + 1];
    arr[1 + i - j] = mkres(3);
    let y: Res = arr[i + 1 - j];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: opposite symbolic terms cancel, so `(i + j) - j` names the same
// dynamic place as `i`.
fn accept_reinitialize_symbolic_linear_cancellation_dynamic_multi_array_element(i: usize, j: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    arr[(i + j) - j] = mkres(3);
    let y: Res = arr[j + i - j];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: repeated same-sign symbolic terms remain part of the canonical
// bounded-linear place instead of being rejected as an unsupported coefficient.
fn accept_reinitialize_repeated_symbolic_linear_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i + i];
    arr[(i + i) + 0] = mkres(3);
    let y: Res = arr[i + (0 + i)];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: multiplying a symbolic index by a small constant expands to the same
// bounded-linear place as repeated symbolic addition.
fn accept_reinitialize_symbolic_scaled_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i * 2];
    arr[i + i] = mkres(3);
    let y: Res = arr[2 * i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: copied scaled symbolic expressions compose with later equivalent
// repeated-term forms.
fn accept_reinitialize_copied_symbolic_scaled_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let j: usize = i * 2;
    let x: Res = arr[j];
    arr[i + i] = mkres(3);
    let y: Res = arr[2 * i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: left-shifting a symbolic index by a small constant is the same
// bounded-linear place as multiplying by the corresponding power of two.
fn accept_reinitialize_symbolic_shifted_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i << 1];
    arr[i * 2] = mkres(3);
    let y: Res = arr[i + i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: right-shifting by zero is identity-preserving for symbolic places.
fn accept_reinitialize_symbolic_shift_identity_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i >> 0];
    arr[i] = mkres(3);
    let y: Res = arr[i + 0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: right-shifting an exactly divisible bounded-linear symbolic index
// by a constant power of two reuses the same place as exact division.
fn accept_reinitialize_symbolic_exact_shift_right_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    arr[(i << 1) >> 1] = mkres(3);
    let y: Res = arr[(i + i) >> 1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: non-exact symbolic right shifts stay conservative because the
// checker cannot prove the shifted expression names the previous symbolic
// element place for all runtime indexes.
fn reject_non_exact_symbolic_shift_right_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[(i + i + 1) >> 1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: bitwise identity expressions with zero keep the same symbolic
// dynamic place identity.
fn accept_reinitialize_symbolic_bitwise_identity_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i | 0];
    arr[0 | i] = mkres(3);
    let y: Res = arr[i ^ 0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: copied symbolic facts also survive identity-preserving bitwise
// expressions.
fn accept_reinitialize_copied_symbolic_bitwise_identity_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let j: usize = i ^ 0;
    let x: Res = arr[j];
    arr[0 ^ j] = mkres(3);
    let y: Res = arr[j | 0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: idempotent bitwise expressions over the same canonical symbolic
// index preserve the dynamic place.
fn accept_reinitialize_symbolic_bitwise_idempotent_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i | i];
    arr[i] = mkres(3);
    let y: Res = arr[i & i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: the idempotent rule also works after both sides canonicalize through
// copied symbolic facts.
fn accept_reinitialize_copied_symbolic_bitwise_idempotent_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let j: usize = i + 1;
    let x: Res = arr[j];
    arr[(i + 1) | j] = mkres(3);
    let y: Res = arr[j & (1 + i)];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: exact division of a scaled symbolic expression returns to the same
// bounded-linear place.
fn accept_reinitialize_symbolic_exact_division_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[(i + i) / 2];
    arr[i] = mkres(3);
    let y: Res = arr[(i * 2) / 2];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: copied exactly-divided symbolic expressions compose with the
// original symbolic place.
fn accept_reinitialize_copied_symbolic_exact_division_dynamic_multi_array_element(i: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let j: usize = (i + i) / 2;
    let x: Res = arr[j];
    arr[i] = mkres(3);
    let y: Res = arr[(i * 2) / 2];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: non-exact symbolic division stays outside stable place identity, so
// it conflicts conservatively with the previously moved symbolic element.
fn reject_non_exact_symbolic_division_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[(i + i + i) / 2];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: a different symbolic linear expression may still denote the same
// element as the already-moved place, so it conflicts conservatively.
fn reject_different_symbolic_linear_dynamic_multi_array_element_move(i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i + j];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[i + j + 1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: a different symbolic index may denote the same element as the
// already-moved one, so it cannot be used as a proven reinitialization.
fn reject_reinitialize_different_symbolic_dynamic_multi_array_element(i: usize, j: usize) -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    arr[j] = mkres(3); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: stable symbolic dynamic places compose through move-struct array
// fields, so a moved field element can be reinitialized through the same symbol.
fn accept_reinitialize_symbolic_dynamic_array_field_element(i: usize) -> u32 {
    var box: ResArrayBox = mkbox();
    let x: Res = box.items[i];
    box.items[i + 0] = mkres(3);
    let y: Res = box.items[i];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Rejected: a different symbolic field index may denote the same field element
// that was already moved out.
fn reject_different_symbolic_dynamic_array_field_element_move(i: usize, j: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = box.items[j];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Accepted: bounded symbolic offsets compose through move-struct array fields.
fn accept_reinitialize_symbolic_offset_dynamic_array_field_element(i: usize) -> u32 {
    var box: ResArrayBox = mkbox();
    let x: Res = box.items[i + 1];
    box.items[1 + i] = mkres(3);
    let y: Res = box.items[i + 1];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Rejected: different symbolic offsets through a move-struct array field still
// conflict conservatively.
fn reject_different_symbolic_offset_dynamic_array_field_element_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[i + 1];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = box.items[i + 2];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Accepted: canonical linear symbolic places compose through move-struct array
// fields.
fn accept_reinitialize_symbolic_linear_dynamic_array_field_element(i: usize, j: usize) -> u32 {
    var box: ResArrayBox = mkbox();
    let x: Res = box.items[i + j + 1];
    box.items[j + i + 1] = mkres(3);
    let y: Res = box.items[i + j + 1];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Rejected: different symbolic linear expressions through a move-struct field
// still conflict conservatively.
fn reject_different_symbolic_linear_dynamic_array_field_element_move(i: usize, j: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[i + j];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = box.items[i + j + 1];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Accepted: symbolic dynamic places also compose through nested array suffixes
// when the remaining suffix is nameable.
fn accept_reinitialize_symbolic_dynamic_nested_array_element(i: usize) -> u32 {
    var matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i][0];
    matrix[i + 0][0] = mkres(3);
    let y: Res = matrix[0 + i][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Accepted: bounded symbolic offsets also compose through nested array suffixes.
fn accept_reinitialize_symbolic_offset_dynamic_nested_array_element(i: usize) -> u32 {
    var matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i + 1][0];
    matrix[1 + i][0] = mkres(3);
    let y: Res = matrix[i + 1][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Accepted: canonical linear symbolic places compose through nested array suffixes.
fn accept_reinitialize_symbolic_linear_dynamic_nested_array_element(i: usize, j: usize) -> u32 {
    var matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i + j + 1][0];
    matrix[j + i + 1][0] = mkres(3);
    let y: Res = matrix[i + j + 1][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Rejected: a different symbolic outer index may denote the same nested element.
fn reject_different_symbolic_dynamic_nested_array_element_move(i: usize, j: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = matrix[j][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Rejected: different symbolic offsets through a nested array suffix still
// conflict conservatively.
fn reject_different_symbolic_offset_dynamic_nested_array_element_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i + 1][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = matrix[i + 2][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Accepted: singleton dynamic indexes compose through move-struct array fields,
// so assignment can reinitialize the concrete `box.items[0]` place.
fn accept_reinitialize_dynamic_singleton_array_field_element(i: usize) -> u32 {
    var box: SingleResArrayBox = mksinglebox();
    let x: Res = box.items[i];
    box.items[i] = mkres(2);
    let y: Res = box.items[0];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Rejected: the same field-element path rejects overwriting the live singleton
// element through a dynamic index.
fn reject_overwrite_dynamic_singleton_array_field_element(i: usize) -> u32 {
    var box: SingleResArrayBox = mksinglebox();
    box.items[i] = mkres(2); // EXPECT_ERROR: E_RESOURCE_OVERWRITE
    unsafe { forget_unchecked(box); }
    return 0;
}

// Accepted: constant-index array elements inside a move struct field are tracked as
// places, so a move struct can own a fixed array of move resources by value.
fn accept_move_array_field_elements() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    let y: Res = box.items[1];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Accepted: a moved-out array field element can be reinitialized before it is
// moved again.
fn accept_reinitialize_array_field_element() -> u32 {
    var box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    let y: u32 = consume(x);
    box.items[0] = mkres(y + 1);
    let a: Res = box.items[0];
    let b: Res = box.items[1];
    unsafe { forget_unchecked(box); }
    return consume(a) + consume(b);
}

// Rejected: moving the same array element twice duplicates the resource.
fn reject_duplicate_array_element_move() -> u32 {
    let arr: [2]Res = .{ mkres(1), mkres(2) };
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: after a deferred cleanup reserves an array element, moving that
// same element before the defer runs would duplicate the resource.
fn reject_move_deferred_array_element() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer consume(arr[0]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: duplicate moves through nested array aliases are still the same
// element place.
fn reject_duplicate_nested_array_alias_element_move() -> u32 {
    let arr: NestedResArray = .{ .{ mkres(1), mkres(2) } };
    let x: Res = arr[0][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0][0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: parameter-rooted array element places cannot be moved twice.
fn reject_duplicate_array_param_element_move(arr: ResArray) -> u32 {
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: a constant-index local aliases the same element place as the literal.
fn reject_duplicate_const_index_variable_array_element_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let i: usize = 0;
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: after reassignment, the index local denotes the new stable element.
fn reject_duplicate_reassigned_const_index_variable_array_element_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var i: usize = 0;
    i = 1;
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: arithmetic over a tracked constant-index local aliases the folded
// element place.
fn reject_duplicate_const_index_variable_arithmetic_array_element_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let i: usize = 0;
    let x: Res = arr[i + 1];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: copied constant-index locals alias the folded literal place.
fn reject_duplicate_copied_const_index_variable_array_element_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let i: usize = 0;
    let j: usize = i + 1;
    let x: Res = arr[j];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: reassignment from another constant-index local updates the aliasing
// element place.
fn reject_duplicate_reassigned_copied_const_index_variable_array_element_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let i: usize = 1;
    var j: usize = 0;
    j = i;
    let x: Res = arr[j];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: if different branch paths leave an index local with different
// constants, the joined value is not a stable element place anymore, so the
// later move uses the conservative wildcard element place.
fn accept_branch_divergent_const_index_array_element_move(cond: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var i: usize = 0;
    if cond {
        i = 1;
    }
    let x: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: divergent switch arms likewise clear the stable index fact, so the
// later move uses wildcard element ownership instead of a stale concrete place.
fn accept_switch_divergent_const_index_array_element_move(cond: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var i: usize = 0;
    switch cond {
        true => {
            i = 1;
        },
        false => {},
    }
    let x: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: divergent switch arms clear the stable index fact for move-struct
// array fields too, so the later move is tracked as a wildcard element move.
fn accept_switch_divergent_const_index_array_field_element_move(cond: bool) -> u32 {
    let box: ResArrayBox = mkbox();
    var i: usize = 0;
    switch cond {
        true => {
            i = 1;
        },
        false => {},
    }
    let x: Res = box.items[i];
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Accepted: divergent symbolic branch arms clear the symbolic fact, so the later
// dynamic move uses conservative wildcard element ownership.
fn accept_branch_divergent_symbolic_index_array_element_move(cond: bool, i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var k: usize = i;
    if cond {
        k = j;
    }
    let x: Res = arr[k];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: divergent symbolic switch arms also clear the symbolic fact.
fn accept_switch_divergent_symbolic_index_array_element_move(cond: bool, i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var k: usize = i;
    switch cond {
        true => {
            k = j;
        },
        false => {},
    }
    let x: Res = arr[k];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: a loop may run zero or more times, so an index local changed inside
// the loop cannot remain a stable element-place fact after the loop; the move
// falls back to the wildcard element place.
fn accept_loop_divergent_const_index_array_element_move(cond: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var i: usize = 0;
    while cond {
        i = 1;
    }
    let x: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: `break` reaches the post-loop code, so a const-index fact changed
// before the break cannot remain precise after the loop; the later move uses
// wildcard element ownership.
fn accept_break_divergent_const_index_array_element_move(cond: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var i: usize = 0;
    while cond {
        i = 1;
        break;
    }
    let x: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: `continue` can run before a later condition exit, so a const-index
// fact changed on the continue edge is also unstable after the loop and falls
// back to wildcard element ownership.
fn accept_continue_divergent_const_index_array_element_move(cond: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var i: usize = 0;
    while cond {
        i = 1;
        continue;
    }
    let x: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: if a loop changes a symbolic index fact, the post-loop move falls
// back to wildcard ownership instead of keeping a stale symbolic place.
fn accept_loop_divergent_symbolic_index_array_element_move(cond: bool, i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var k: usize = i;
    while cond {
        k = j;
    }
    let x: Res = arr[k];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: symbolic facts changed before `break` are invalidated before the
// loop rejoins, so the later dynamic move uses wildcard ownership.
fn accept_break_divergent_symbolic_index_array_element_move(cond: bool, i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var k: usize = i;
    while cond {
        k = j;
        break;
    }
    let x: Res = arr[k];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: symbolic facts changed before `continue` are also invalidated before
// later loop exit paths rejoin.
fn accept_continue_divergent_symbolic_index_array_element_move(cond: bool, i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var k: usize = i;
    while cond {
        k = j;
        continue;
    }
    let x: Res = arr[k];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: a folded const expression aliases the same element place as its value.
fn reject_duplicate_comptime_const_index_array_element_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[SECOND_INDEX];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: returning the whole array after one element was moved out would
// duplicate the moved element.
fn reject_return_move_array_after_partial_move() -> ResArray {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[0];
    let v: u32 = consume(x);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return arr;
}

// Rejected: returning from a path after moving only one field would leak the
// remaining aggregate resource on that exit edge.
fn reject_return_after_partial_field_move() -> u32 {
    let p: Pair = mk(); // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = p.a;
    return consume(x);
}

// Rejected: return-edge leak checks also include constant-index array element
// places, not only whole bindings.
fn reject_return_after_array_element_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) }; // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = arr[0];
    return consume(x);
}

// Rejected: return-edge leak checks also include wildcard dynamic array-element
// places, not only concrete element places.
fn reject_return_after_dynamic_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) }; // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = arr[i];
    return consume(x);
}

// Rejected: return-edge leak checks also preserve nested wildcard dynamic array
// places.
fn reject_return_after_dynamic_nested_array_element_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } }; // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = matrix[i][0];
    return consume(x);
}

// Rejected: return-edge leak checks include parameter-rooted array element
// places, not only local array roots.
fn reject_return_after_array_param_element_move(arr: ResArray) -> u32 { // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = arr[0];
    return consume(x);
}

// Rejected: wildcard dynamic parameter-rooted array elements also leak on a
// return edge when the parameter still owns unconsumed resources.
fn reject_return_after_dynamic_array_param_element_move(arr: ResArray, i: usize) -> u32 { // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = arr[i];
    return consume(x);
}

// Rejected: parameter-rooted nested wildcard dynamic elements also leak on a
// return edge.
fn reject_return_after_dynamic_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 { // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = matrix[i][0];
    return consume(x);
}

// Rejected: return-edge leak checks preserve stable symbolic dynamic array places.
fn reject_return_after_symbolic_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) }; // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = arr[i + 0];
    return consume(x);
}

// Rejected: return-edge leak checks also preserve parameter-rooted symbolic
// dynamic array places.
fn reject_return_after_symbolic_array_param_element_move(arr: ResArray, i: usize) -> u32 { // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = arr[0 + i];
    return consume(x);
}

// Rejected: return-edge leak checks preserve nested symbolic parameter-rooted
// places as well.
fn reject_return_after_symbolic_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 { // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = matrix[i * 1][0];
    return consume(x);
}

// Rejected: return-edge leak checks preserve bounded symbolic offset places.
fn reject_return_after_symbolic_offset_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) }; // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = arr[i + 1];
    return consume(x);
}

// Rejected: return-edge leak checks also preserve parameter-rooted bounded
// symbolic offset places.
fn reject_return_after_symbolic_offset_array_param_element_move(arr: ResArray, i: usize) -> u32 { // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = arr[1 + i];
    return consume(x);
}

// Rejected: return-edge leak checks include move-struct array field element
// places as well as local array roots.
fn reject_return_after_array_field_element_move() -> u32 {
    let box: ResArrayBox = mkbox(); // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = box.items[0];
    return consume(x);
}

// Rejected: wildcard dynamic array-field element places also leak on a return
// edge if the containing move struct still owns unconsumed resources.
fn reject_return_after_dynamic_array_field_element_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox(); // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = box.items[i];
    return consume(x);
}

// Rejected: nested wildcard dynamic array-field element places leak on a return
// edge when the containing move struct still owns unconsumed resources.
fn reject_return_after_dynamic_nested_array_field_element_move(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox(); // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = box.items[i][0];
    return consume(x);
}

// Rejected: singleton dynamic array-element moves use the concrete `[0]` place
// on return exits too, so the partially moved array still leaks.
fn reject_return_after_dynamic_singleton_array_element_move(i: usize) -> u32 {
    let arr: SingleResArray = .{ mkres(1) }; // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = arr[i];
    return consume(x);
}

// Rejected: singleton dynamic move-struct array-field elements also leak on a
// return edge through their concrete `items[0]` subplace.
fn reject_return_after_dynamic_singleton_array_field_element_move(i: usize) -> u32 {
    let box: SingleResArrayBox = mksinglebox(); // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = box.items[i];
    return consume(x);
}

// Rejected: borrowing an array element after it was moved out.
fn reject_borrow_after_array_element_move() -> u32 {
    let arr: [2]Res = .{ mkres(1), mkres(2) };
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(&arr[0]);
    unsafe { forget_unchecked(arr); }
    return consume(x) + v;
}

// Rejected: moving the same array field element twice duplicates the resource.
fn reject_duplicate_array_field_element_move() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = box.items[0];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Rejected: borrowing an array field element after it was moved out.
fn reject_borrow_after_array_field_element_move() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(&box.items[0]);
    unsafe { forget_unchecked(box); }
    return consume(x) + v;
}

// Accepted: a dynamic index into a multi-element array is tracked as an
// unknown moved element (`arr[*]`). The array husk can be discarded after the
// moved-out resource is consumed.
fn accept_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: [2]Res = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: after an unknown element move, another dynamic element move could
// duplicate the same resource.
fn reject_duplicate_dynamic_multi_array_element_move(i: usize, j: usize) -> u32 {
    let arr: [2]Res = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[j];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: after a concrete element move, a later unknown dynamic element move
// may select the same moved resource.
fn reject_dynamic_multi_array_element_move_after_constant() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[0];
    let y: Res = arr[dynamic_index()]; // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: the unknown element move also poisons later constant-index element
// moves, because the dynamic index may have selected that element.
fn reject_constant_after_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: [2]Res = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: borrowing any concrete element after an unknown element move could
// read the moved-out element.
fn reject_borrow_after_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: [2]Res = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(&arr[0]);
    unsafe { forget_unchecked(arr); }
    return consume(x) + v;
}

// Rejected: moving the whole array after an unknown element was moved out would
// duplicate the moved element.
fn reject_whole_after_dynamic_multi_array_element_move(i: usize) -> u32 {
    let arr: [2]Res = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: ResArray = arr;
    unsafe { forget_unchecked(y); }
    return consume(x);
}

// Rejected: after an unknown element move, assigning to one concrete element
// cannot prove it is reinitializing the moved slot. It may overwrite a still-live
// resource instead.
fn reject_reinitialize_constant_after_dynamic_multi_array_element_move(i: usize) -> u32 {
    var arr: [2]Res = .{ mkres(1), mkres(2) };
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    arr[0] = mkres(3);
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: assigning through a non-symbolic dynamic index into a live
// multi-element move array would overwrite whichever still-live element the
// index selects.
fn reject_dynamic_multi_array_element_assignment_overwrite() -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    arr[dynamic_index()] = mkres(3); // EXPECT_ERROR: E_RESOURCE_OVERWRITE
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: after a concrete element was moved, assignment through an unknown
// dynamic index might target that moved element or overwrite a different live
// element, so it remains a use-after-move conflict rather than an unsupported
// array operation.
fn reject_dynamic_multi_array_assignment_after_constant_move() -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[0];
    arr[dynamic_index()] = mkres(3); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: a second unknown dynamic assignment after an unknown dynamic move
// might not reinitialize the same element, so the wildcard moved place remains
// poisoned.
fn reject_dynamic_multi_array_assignment_after_wildcard_move() -> u32 {
    var arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[dynamic_index()];
    arr[dynamic_index()] = mkres(3); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: wildcard dynamic moves compose through nested array places. The
// outer dynamic index is tracked as `matrix[*][0]`.
fn accept_dynamic_nested_array_element_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Rejected: after a nested wildcard move, a concrete nested element may be the
// same resource.
fn reject_constant_after_dynamic_nested_array_element_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Rejected: two nested wildcard moves may select the same outer element.
fn reject_duplicate_dynamic_nested_array_element_move(i: usize, j: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = matrix[j][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Rejected: nested wildcard moves also conflict with an already moved concrete
// nested element.
fn reject_dynamic_nested_array_element_move_after_constant() -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[0][0];
    let y: Res = matrix[dynamic_index()][0]; // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Rejected: moving the whole matrix after a nested wildcard move would duplicate
// the unknown moved nested element.
fn reject_whole_after_dynamic_nested_array_element_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let moved: ResMatrix = matrix;
    unsafe { forget_unchecked(moved); }
    return consume(x);
}

// Rejected: after a nested wildcard move, assigning one concrete nested element
// cannot prove it is reinitializing the moved resource.
fn reject_reinitialize_constant_after_dynamic_nested_array_element_move(i: usize) -> u32 {
    var matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    matrix[0][0] = mkres(3);
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Accepted: defer can reserve the same nested wildcard place for lexical
// cleanup.
fn accept_defer_dynamic_nested_array_element(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    defer consume(matrix[i][0]);
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Rejected: after a nested wildcard defer, a concrete nested move may duplicate
// the deferred resource.
fn reject_move_after_defer_dynamic_nested_array_element(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    defer consume(matrix[i][0]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Accepted: wildcard dynamic element moves also work when the array is rooted
// in a move-struct field.
fn accept_dynamic_multi_array_field_element_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[i];
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: after a wildcard move from a move-struct array field, a concrete
// element move could duplicate the resource already taken.
fn reject_constant_after_dynamic_multi_array_field_element_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = box.items[0];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Rejected: field-rooted wildcard moves conflict with an already moved concrete
// field element.
fn reject_dynamic_multi_array_field_element_move_after_constant() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    let y: Res = box.items[dynamic_index()]; // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Rejected: moving the whole move struct after a wildcard element move would
// duplicate the unknown moved element.
fn reject_whole_after_dynamic_multi_array_field_element_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: ResArrayBox = box;
    unsafe { forget_unchecked(y); }
    return consume(x);
}

// Accepted: wildcard dynamic moves also work for internal parameter-rooted
// move arrays.
fn accept_dynamic_multi_array_param_element_move(arr: ResArray, i: usize) -> u32 {
    let x: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: wildcard dynamic moves compose through internal parameter-rooted
// nested array places as well.
fn accept_dynamic_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 {
    let x: Res = matrix[i][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Accepted: parameter-rooted move arrays also support stable symbolic dynamic
// element places.
fn accept_symbolic_multi_array_param_element_move(arr: ResArray, i: usize) -> u32 {
    let x: Res = arr[i + 0];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: moving the same parameter-rooted symbolic element twice duplicates
// the resource.
fn reject_duplicate_symbolic_multi_array_param_element_move(arr: ResArray, i: usize) -> u32 {
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0 + i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: a different symbolic parameter index may denote the same resource.
fn reject_different_symbolic_multi_array_param_element_move(arr: ResArray, i: usize, j: usize) -> u32 {
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[j];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: parameter-rooted symbolic places preserve bounded constant offsets.
fn accept_symbolic_offset_multi_array_param_element_move(arr: ResArray, i: usize) -> u32 {
    let x: Res = arr[i + 1];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: duplicate parameter-rooted symbolic offset places are the same
// tracked resource.
fn reject_duplicate_symbolic_offset_multi_array_param_element_move(arr: ResArray, i: usize) -> u32 {
    let x: Res = arr[i + 1];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[1 + i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: parameter-rooted symbolic places preserve canonical linear terms.
fn accept_symbolic_linear_multi_array_param_element_move(arr: ResArray, i: usize, j: usize) -> u32 {
    let x: Res = arr[i + j + 1];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: duplicate parameter-rooted canonical linear places are the same
// tracked resource.
fn reject_duplicate_symbolic_linear_multi_array_param_element_move(arr: ResArray, i: usize, j: usize) -> u32 {
    let x: Res = arr[i + j + 1];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[1 + j + i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: exact symbolic modulo-zero parameter-rooted indexes fold to the
// concrete element place, matching local arrays.
fn accept_symbolic_modulo_zero_multi_array_param_element_move(arr: ResArray, i: usize) -> u32 {
    let x: Res = arr[(i + i) % 2];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: parameter-rooted nested move arrays also support stable symbolic
// dynamic places when the suffix remains nameable.
fn accept_symbolic_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 {
    let x: Res = matrix[i + 0][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Rejected: moving the same parameter-rooted symbolic nested element twice
// duplicates the resource.
fn reject_duplicate_symbolic_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 {
    let x: Res = matrix[i][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = matrix[i - 0][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Rejected: a different symbolic nested parameter index may denote the same
// resource.
fn reject_different_symbolic_matrix_param_element_move(matrix: ResMatrix, i: usize, j: usize) -> u32 {
    let x: Res = matrix[i][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = matrix[j][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Accepted: parameter-rooted nested symbolic places preserve bounded offsets.
fn accept_symbolic_offset_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 {
    let x: Res = matrix[i + 1][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Rejected: duplicate parameter-rooted nested symbolic offset places are the
// same tracked resource.
fn reject_duplicate_symbolic_offset_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 {
    let x: Res = matrix[i + 1][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = matrix[1 + i][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Accepted: parameter-rooted nested symbolic places preserve canonical linear
// terms.
fn accept_symbolic_linear_matrix_param_element_move(matrix: ResMatrix, i: usize, j: usize) -> u32 {
    let x: Res = matrix[i + j + 1][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Rejected: duplicate parameter-rooted nested canonical linear places are the
// same tracked resource.
fn reject_duplicate_symbolic_linear_matrix_param_element_move(matrix: ResMatrix, i: usize, j: usize) -> u32 {
    let x: Res = matrix[i + j + 1][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = matrix[1 + j + i][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Accepted: exact symbolic modulo-zero also composes through parameter-rooted
// nested array places.
fn accept_symbolic_modulo_zero_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 {
    let x: Res = matrix[(i + i) % 2][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Rejected: a later parameter-rooted concrete move conflicts with the wildcard
// element already taken.
fn reject_constant_after_dynamic_multi_array_param_element_move(arr: ResArray, i: usize) -> u32 {
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: parameter-rooted wildcard moves also conflict with an already moved
// concrete parameter element.
fn reject_dynamic_multi_array_param_element_move_after_constant(arr: ResArray) -> u32 {
    let x: Res = arr[0];
    let y: Res = arr[dynamic_index()]; // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: a later concrete nested parameter element may be the same resource
// as the wildcard element already taken.
fn reject_constant_after_dynamic_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 {
    let x: Res = matrix[i][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Accepted: dynamic-index deferred cleanup reserves an unknown element place
// (`arr[*]`). The array husk is then discarded; no other element may be used.
fn accept_defer_dynamic_multi_array_element(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer consume(arr[i]);
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: after a dynamic defer reserves an unknown element, moving a concrete
// element could duplicate the deferred resource.
fn reject_move_after_defer_dynamic_multi_array_element(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer consume(arr[i]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: moving the whole array after a dynamic defer would also duplicate
// the unknown deferred element.
fn reject_whole_after_defer_dynamic_multi_array_element(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer consume(arr[i]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let moved: ResArray = arr;
    unsafe { forget_unchecked(moved); }
    return 0;
}

// Rejected: if a concrete element is already moved, a later dynamic defer may
// target that same element.
fn reject_defer_dynamic_multi_array_element_after_constant_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    defer consume(arr[i]);
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: defer can reserve a stable symbolic dynamic element place.
fn accept_defer_symbolic_multi_array_element(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer consume(arr[i + 0]);
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: after symbolic defer reserves an element, moving the same symbolic
// element would duplicate the deferred resource.
fn reject_move_after_defer_symbolic_multi_array_element(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer consume(arr[i]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = arr[0 + i];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: defer reserves bounded symbolic offset places using the same place
// identity as later equivalent offset expressions.
fn reject_move_after_defer_symbolic_offset_multi_array_element(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer consume(arr[i + 1]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = arr[1 + i];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: after symbolic defer reserves an element, a different symbolic index
// may still denote the same deferred resource.
fn reject_different_symbolic_after_defer_symbolic_multi_array_element(i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    defer consume(arr[i]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = arr[j];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: dynamic defer also reserves an unknown element place inside a
// move-struct array field.
fn accept_defer_dynamic_multi_array_field_element(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    defer consume(box.items[i]);
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: after a dynamic field-element defer reserves an unknown element,
// moving a concrete element could duplicate the deferred resource.
fn reject_move_after_defer_dynamic_multi_array_field_element(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    defer consume(box.items[i]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = box.items[0];
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: moving the whole move struct after a dynamic field-element defer
// would also duplicate the reserved unknown element.
fn reject_whole_after_defer_dynamic_multi_array_field_element(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    defer consume(box.items[i]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let moved: ResArrayBox = box;
    unsafe { forget_unchecked(moved); }
    return 0;
}

// Rejected: if a concrete field element is already moved, a later dynamic defer
// may target that same element.
fn reject_defer_dynamic_multi_array_field_element_after_constant_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    defer consume(box.items[i]);
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Accepted: deferred cleanup also reserves an unknown nested element place inside
// a move-struct array field.
fn accept_defer_dynamic_nested_array_field_element(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    defer consume(box.items[i][0]);
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: after a nested dynamic field-element defer reserves an unknown
// element, moving a concrete nested element could duplicate the deferred resource.
fn reject_move_after_defer_dynamic_nested_array_field_element(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    defer consume(box.items[i][0]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = box.items[0][0];
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: moving the whole move struct after a nested dynamic field-element
// defer would also duplicate the reserved unknown nested element.
fn reject_whole_after_defer_dynamic_nested_array_field_element(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    defer consume(box.items[i][0]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let moved: ResMatrixBox = box;
    unsafe { forget_unchecked(moved); }
    return 0;
}

// Rejected: if a concrete nested field element is already moved, a later dynamic
// defer may target that same nested element.
fn reject_defer_dynamic_nested_array_field_element_after_constant_move(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    let x: Res = box.items[0][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    defer consume(box.items[i][0]);
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Accepted: defer can reserve symbolic dynamic places through move-struct array
// fields.
fn accept_defer_symbolic_array_field_element(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    defer consume(box.items[i + 0]);
    unsafe { forget_unchecked(box); }
    return 0;
}

// Accepted: internal parameter-rooted move arrays can reserve an unknown
// element with dynamic defer.
fn accept_defer_dynamic_multi_array_param_element(arr: ResArray, i: usize) -> u32 {
    defer consume(arr[i]);
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Accepted: internal parameter-rooted nested move arrays can also reserve an
// unknown nested element with dynamic defer.
fn accept_defer_dynamic_matrix_param_element(matrix: ResMatrix, i: usize) -> u32 {
    defer consume(matrix[i][0]);
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Accepted: parameter-rooted symbolic dynamic places can be reserved by defer.
fn accept_defer_symbolic_multi_array_param_element(arr: ResArray, i: usize) -> u32 {
    defer consume(arr[i + 0]);
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Accepted: nested parameter-rooted symbolic places can also be reserved by
// defer when the suffix remains nameable.
fn accept_defer_symbolic_matrix_param_element(matrix: ResMatrix, i: usize) -> u32 {
    defer consume(matrix[i + 0][0]);
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Rejected: after a parameter-root dynamic defer reserves an unknown element,
// moving a concrete element could duplicate the deferred resource.
fn reject_move_after_defer_dynamic_multi_array_param_element(arr: ResArray, i: usize) -> u32 {
    defer consume(arr[i]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: after a nested parameter-root dynamic defer, moving a concrete nested
// element could duplicate the deferred resource.
fn reject_move_after_defer_dynamic_matrix_param_element(matrix: ResMatrix, i: usize) -> u32 {
    defer consume(matrix[i][0]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let x: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Rejected: moving the whole parameter-root array after a dynamic defer would
// duplicate the reserved unknown element.
fn reject_whole_after_defer_dynamic_multi_array_param_element(arr: ResArray, i: usize) -> u32 {
    defer consume(arr[i]);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let moved: ResArray = arr;
    unsafe { forget_unchecked(moved); }
    return 0;
}

// Rejected: singleton dynamic indexes still identify the same element, so moving
// it twice is a duplicate move.
fn reject_duplicate_dynamic_singleton_array_element_move(i: usize) -> u32 {
    let arr: SingleResArray = .{ mkres(1) };
    let x: Res = arr[i];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: a nested place (n.p.a) moved twice — place tracking is not just one level deep.
fn reject_nested_field_move() -> u32 {
    let n: Nest = mknest();
    let x: Res = n.p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = n.p.a;
    unsafe { forget_unchecked(n); } // discard the rest of the husk so only the dup is reported
    return consume(x) + consume(y);
}

// Accepted: move each field out exactly once, then discard the empty husk.
fn accept_move_each_field() -> u32 {
    let p: Pair = mk();
    let x: Res = p.a;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Rejected: moving the same field twice duplicates the resource.
fn reject_duplicate_field_move() -> u32 {
    let p: Pair = mk();
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = p.a;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Rejected: borrowing a field after it was moved out.
fn reject_borrow_after_field_move() -> u32 {
    let p: Pair = mk();
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(&p.a);
    unsafe { forget_unchecked(p); }
    return consume(x) + v;
}

// Accepted: a full pointer alias to a move field can move that field precisely.
fn accept_move_field_through_full_alias() -> u32 {
    let p: Pair = mk();
    let pa: *Res = &p.a;
    let x: Res = pa.*;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Accepted: a full pointer alias to a constant-index array element can move that
// element precisely.
fn accept_move_array_element_through_full_alias() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p0: *Res = &arr[0];
    let x: Res = p0.*;
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: an immediate full deref of a move field address consumes the same
// tracked field place as a named full alias.
fn accept_move_field_through_immediate_full_deref() -> u32 {
    let p: Pair = mk();
    let x: Res = (&p.a).*;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Accepted: immediate full deref of a constant-index array element address
// consumes that precise element place.
fn accept_move_array_element_through_immediate_full_deref() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = (&arr[0]).*;
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: copying a full pointer alias to a move field preserves the same
// pointee ownership, so moving through the copy moves the field place.
fn accept_move_field_through_copied_full_alias() -> u32 {
    let p: Pair = mk();
    let pa: *Res = &p.a;
    let qa: *Res = pa;
    let x: Res = qa.*;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Accepted: copying a full pointer alias to a constant-index array element
// preserves the same element place.
fn accept_move_array_element_through_copied_full_alias() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p0: *Res = &arr[0];
    let q0: *Res = p0;
    let x: Res = q0.*;
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: a full pointer alias to a dynamic multi-element array index consumes
// an unknown element place (`arr[*]`).
fn accept_move_dynamic_array_element_through_full_alias(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p: *Res = &arr[i];
    let x: Res = p.*;
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Accepted: copied full aliases to dynamic array elements preserve the wildcard
// element place.
fn accept_move_dynamic_array_element_through_copied_full_alias(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p: *Res = &arr[i];
    let q: *Res = p;
    let x: Res = q.*;
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: after moving through a dynamic element alias, a concrete element
// move could duplicate the same resource.
fn reject_constant_after_dynamic_array_element_full_alias_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p: *Res = &arr[i];
    let x: Res = p.*;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: moving the whole array after moving through a dynamic element alias
// would duplicate the unknown element.
fn reject_whole_after_dynamic_array_element_full_alias_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p: *Res = &arr[i];
    let x: Res = p.*;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let moved: ResArray = arr;
    unsafe { forget_unchecked(moved); }
    return consume(x);
}

// Rejected: a dynamic element alias becomes stale after an unknown element move.
fn reject_dynamic_array_element_full_alias_after_dynamic_move(i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p: *Res = &arr[i];
    let x: Res = arr[j];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(p);
    unsafe { forget_unchecked(arr); }
    return consume(x) + v;
}

// Accepted: a full pointer alias to a nested dynamic array element preserves the
// composed wildcard place (`matrix[*][0]`) when moved through the deref.
fn accept_move_nested_dynamic_array_element_through_full_alias(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let p: *Res = &matrix[i][0];
    let x: Res = p.*;
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Accepted: copying that full alias preserves the same nested wildcard place.
fn accept_move_nested_dynamic_array_element_through_copied_full_alias(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let p: *Res = &matrix[i][0];
    let q: *Res = p;
    let x: Res = q.*;
    unsafe { forget_unchecked(matrix); }
    return consume(x);
}

// Rejected: after moving through a nested dynamic element alias, a concrete
// nested element move may duplicate the same resource.
fn reject_constant_after_nested_dynamic_array_element_full_alias_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let p: *Res = &matrix[i][0];
    let x: Res = p.*;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); }
    return consume(x) + consume(y);
}

// Accepted: full pointer aliases also compose through move-struct array fields.
fn accept_move_nested_dynamic_array_field_element_through_full_alias(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    let p: *Res = &box.items[i][0];
    let x: Res = p.*;
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: nested field-rooted wildcard alias moves conflict with concrete
// nested field element moves.
fn reject_constant_after_nested_dynamic_array_field_element_full_alias_move(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    let p: *Res = &box.items[i][0];
    let x: Res = p.*;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = box.items[0][0];
    unsafe { forget_unchecked(box); }
    return consume(x) + consume(y);
}

// Accepted: pointer-returning calls that receive a dynamic array-element borrow
// preserve a wildcard stale-alias referent for reads before the element moves.
fn accept_laundered_dynamic_array_element_alias_before_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p: *Res = id_res(&arr[i]);
    let v: u32 = peek(p);
    unsafe { forget_unchecked(arr); }
    return v;
}

// Rejected: a laundered dynamic element alias is stale after any unknown element
// move from the same array.
fn reject_laundered_dynamic_array_element_alias_after_dynamic_move(i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p: *Res = id_res(&arr[i]);
    let x: Res = arr[j];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(p);
    unsafe { forget_unchecked(arr); }
    return consume(x) + v;
}

// Accepted: pointer-returning calls preserve nested wildcard referents for
// matrix element borrows while the element is still live.
fn accept_laundered_nested_dynamic_array_element_alias_before_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let p: *Res = id_res(&matrix[i][0]);
    let v: u32 = peek(p);
    unsafe { forget_unchecked(matrix); }
    return v;
}

// Rejected: once an unknown nested element moves, a laundered alias to a nested
// wildcard element may be stale.
fn reject_laundered_nested_dynamic_array_element_alias_after_move(i: usize, j: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let p: *Res = id_res(&matrix[i][0]);
    let x: Res = matrix[j][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(p);
    unsafe { forget_unchecked(matrix); }
    return consume(x) + v;
}

// Accepted: the same laundered nested wildcard alias path composes through
// move-struct array fields while the referent is still live.
fn accept_laundered_nested_dynamic_array_field_element_alias_before_move(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    let p: *Res = id_res(&box.items[i][0]);
    let v: u32 = peek(p);
    unsafe { forget_unchecked(box); }
    return v;
}

// Rejected: a laundered nested field-rooted wildcard alias is stale after an
// overlapping nested field element move.
fn reject_laundered_nested_dynamic_array_field_element_alias_after_move(i: usize, j: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    let p: *Res = id_res(&box.items[i][0]);
    let x: Res = box.items[j][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(p);
    unsafe { forget_unchecked(box); }
    return consume(x) + v;
}

// Accepted: a pointer returned from a call that received a subplace borrow can be
// used before that subplace is moved.
fn accept_laundered_subplace_pointer_used_before_move() -> u32 {
    let p: Pair = mk();
    let pa: *Res = id_res(&p.a);
    let v: u32 = peek(pa);
    let x: Res = p.a;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return v + consume(x) + consume(y);
}

// Rejected: moving through a full field alias poisons that field place.
fn reject_field_after_full_alias_move() -> u32 {
    let p: Pair = mk();
    let pa: *Res = &p.a;
    let x: Res = pa.*;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = p.a;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Rejected: moving through a full array-element alias poisons that element place.
fn reject_array_element_after_full_alias_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p0: *Res = &arr[0];
    let x: Res = p0.*;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: moving through a copied full field alias still poisons the original
// field place.
fn reject_field_after_copied_full_alias_move() -> u32 {
    let p: Pair = mk();
    let pa: *Res = &p.a;
    let qa: *Res = pa;
    let x: Res = qa.*;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = p.a;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Rejected: moving through a copied full array-element alias still poisons the
// original element place.
fn reject_array_element_after_copied_full_alias_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p0: *Res = &arr[0];
    let q0: *Res = p0;
    let x: Res = q0.*;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: moving the whole aggregate after a full field-alias move would
// duplicate the moved field.
fn reject_whole_after_full_field_alias_move() -> u32 {
    let p: Pair = mk();
    let pa: *Res = &p.a;
    let x: Res = pa.*;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let r: u32 = take_whole(p);
    return consume(x) + r;
}

// Rejected: moving the whole array after a full element-alias move would
// duplicate the moved element.
fn reject_whole_array_after_full_element_alias_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p0: *Res = &arr[0];
    let x: Res = p0.*;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let moved: ResArray = arr;
    unsafe { forget_unchecked(moved); }
    return consume(x);
}

// Rejected: a pointer-returning call can launder a borrow of a move field. The
// returned pointer is stale after that exact field place is moved.
fn reject_laundered_field_alias_after_move() -> u32 {
    let p: Pair = mk();
    let pa: *Res = id_res(&p.a);
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(pa);
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y) + v;
}

// Rejected: the same laundering rule applies to constant-index array element
// places.
fn reject_laundered_array_element_alias_after_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let p0: *Res = id_res(&arr[0]);
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(p0);
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y) + v;
}

// Rejected: reassignment of an existing alias local re-derives the laundered
// field subplace referent.
fn reject_reassigned_laundered_field_alias_after_move() -> u32 {
    let p: Pair = mk();
    var pa: *Res = &p.b;
    pa = id_res(&p.a);
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(pa);
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y) + v;
}

// Rejected: reassignment also tracks constant-index array element subplaces.
fn reject_reassigned_laundered_array_element_alias_after_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var p0: *Res = &arr[1];
    p0 = id_res(&arr[0]);
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(p0);
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y) + v;
}

// Rejected: reassignment to a direct field subplace alias also re-derives the
// exact referent.
fn reject_reassigned_direct_field_alias_after_move() -> u32 {
    let p: Pair = mk();
    var pa: *Res = id_res(&p.b);
    pa = &p.a;
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(pa);
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y) + v;
}

// Rejected: reassignment to a direct array-element alias also tracks that
// constant-index element.
fn reject_reassigned_direct_array_element_alias_after_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var p0: *Res = id_res(&arr[1]);
    p0 = &arr[0];
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(p0);
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y) + v;
}

// Accepted: after reassignment to a direct subplace alias, moving through the
// alias consumes that exact field rather than the old referent.
fn accept_reassigned_direct_field_alias_move_through() -> u32 {
    let p: Pair = mk();
    var pa: *Res = id_res(&p.b);
    pa = &p.a;
    let x: Res = pa.*;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Accepted: the same reassignment path grants full-deref authority for constant
// array element aliases.
fn accept_reassigned_direct_array_element_alias_move_through() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var p0: *Res = id_res(&arr[1]);
    p0 = &arr[0];
    let x: Res = p0.*;
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Accepted: assignment into previously uninitialized pointer storage still grants
// full-deref authority for a field subplace alias.
fn accept_assigned_uninit_pointer_field_alias_move_through() -> u32 {
    let p: Pair = mk();
    var pa: *Res = uninit;
    pa = &p.a;
    let x: Res = pa.*;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Rejected: assignment into previously uninitialized pointer storage still
// records the precise field referent for stale alias reads.
fn reject_assigned_uninit_pointer_field_alias_after_move() -> u32 {
    let p: Pair = mk();
    var pa: *Res = uninit;
    pa = &p.a;
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(pa);
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y) + v;
}

// Accepted: assignment into previously uninitialized pointer storage preserves
// a constant-index array element as the full pointee.
fn accept_assigned_uninit_pointer_array_element_alias_move_through() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var p0: *Res = uninit;
    p0 = &arr[0];
    let x: Res = p0.*;
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y);
}

// Rejected: the same uninitialized pointer assignment records the precise array
// element for later stale alias reads.
fn reject_assigned_uninit_pointer_array_element_alias_after_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var p0: *Res = uninit;
    p0 = &arr[0];
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(p0);
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y) + v;
}

// Accepted: assignment into previously uninitialized pointer storage also tracks
// laundered field subplace aliases.
fn accept_assigned_uninit_laundered_pointer_field_alias_before_move() -> u32 {
    let p: Pair = mk();
    var pa: *Res = uninit;
    pa = id_res(&p.a);
    let v: u32 = peek(pa);
    let x: Res = p.a;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return v + consume(x) + consume(y);
}

// Rejected: laundered aliases assigned into previously uninitialized pointer
// storage become stale after the exact field moves.
fn reject_assigned_uninit_laundered_pointer_field_alias_after_move() -> u32 {
    let p: Pair = mk();
    var pa: *Res = uninit;
    pa = id_res(&p.a);
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(pa);
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y) + v;
}

// Accepted: dynamic array-element aliases assigned into previously
// uninitialized pointer storage consume the wildcard element place.
fn accept_assigned_uninit_pointer_dynamic_array_element_alias_move_through(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var p: *Res = uninit;
    p = &arr[i];
    let x: Res = p.*;
    unsafe { forget_unchecked(arr); }
    return consume(x);
}

// Rejected: the same dynamic assignment path records the wildcard element
// referent for stale reads after an unknown element move.
fn reject_assigned_uninit_pointer_dynamic_array_element_alias_after_move(i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var p: *Res = uninit;
    p = &arr[i];
    let x: Res = arr[j];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(p);
    unsafe { forget_unchecked(arr); }
    return consume(x) + v;
}

// Rejected: a struct field can also hold a pointer returned from a call that
// laundered a field subplace borrow.
fn reject_laundered_field_alias_in_struct_after_move() -> u32 {
    let p: Pair = mk();
    let h: ResPtrHolder = .{ .p = id_res(&p.a) };
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(h.p);
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y) + v;
}

// Rejected: the struct-field laundering path also preserves constant-index
// array element referents.
fn reject_laundered_array_element_alias_in_struct_after_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let h: ResPtrHolder = .{ .p = id_res(&arr[0]) };
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(h.p);
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y) + v;
}

// Accepted: direct subplace borrows stored in struct fields are also precise
// enough to use before the subplace move.
fn accept_direct_subplace_alias_in_struct_before_move() -> u32 {
    let p: Pair = mk();
    let h: ResPtrHolder = .{ .p = &p.a };
    let v: u32 = peek(h.p);
    let x: Res = p.a;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return v + consume(x) + consume(y);
}

// Rejected: a direct field subplace borrow stored in a struct field is stale
// after that exact field is moved.
fn reject_direct_field_alias_in_struct_after_move() -> u32 {
    let p: Pair = mk();
    let h: ResPtrHolder = .{ .p = &p.a };
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(h.p);
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y) + v;
}

// Rejected: direct constant-index array element borrows stored in struct fields
// get the same precise stale-alias treatment.
fn reject_direct_array_element_alias_in_struct_after_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let h: ResPtrHolder = .{ .p = &arr[0] };
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(h.p);
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y) + v;
}

// Accepted: assigning a laundered subplace alias into a struct field is precise
// enough to allow use before the subplace move.
fn accept_assigned_laundered_struct_field_alias_before_move() -> u32 {
    let p: Pair = mk();
    var h: ResPtrHolder = .{ .p = &p.b };
    h.p = id_res(&p.a);
    let v: u32 = peek(h.p);
    let x: Res = p.a;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return v + consume(x) + consume(y);
}

// Rejected: assigning a pointer returned from a call into a struct field preserves
// the exact field subplace referent for stale-alias checks.
fn reject_assigned_laundered_field_alias_in_struct_after_move() -> u32 {
    let p: Pair = mk();
    var h: ResPtrHolder = .{ .p = &p.b };
    h.p = id_res(&p.a);
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(h.p);
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y) + v;
}

// Rejected: assigned struct-field aliases also preserve constant-index array
// element referents.
fn reject_assigned_laundered_array_element_alias_in_struct_after_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var h: ResPtrHolder = .{ .p = &arr[1] };
    h.p = id_res(&arr[0]);
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(h.p);
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y) + v;
}

// Accepted: direct assignment of a subplace alias into a struct field is precise
// when the field is read before the subplace moves.
fn accept_assigned_direct_subplace_alias_in_struct_before_move() -> u32 {
    let p: Pair = mk();
    var h: ResPtrHolder = .{ .p = &p.b };
    h.p = &p.a;
    let v: u32 = peek(h.p);
    let x: Res = p.a;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return v + consume(x) + consume(y);
}

// Rejected: direct assignment of a field subplace alias into a struct field
// records the exact referent for stale reads.
fn reject_assigned_direct_field_alias_in_struct_after_move() -> u32 {
    let p: Pair = mk();
    var h: ResPtrHolder = .{ .p = &p.b };
    h.p = &p.a;
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(h.p);
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y) + v;
}

// Rejected: direct assignment of a constant-index array element alias into a
// struct field records the exact referent for stale reads.
fn reject_assigned_direct_array_element_alias_in_struct_after_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    var h: ResPtrHolder = .{ .p = &arr[1] };
    h.p = &arr[0];
    let x: Res = arr[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(h.p);
    let y: Res = arr[1];
    unsafe { forget_unchecked(arr); }
    return consume(x) + consume(y) + v;
}

// Accepted: struct fields inside constant-index array literal elements are
// nameable as arr[0].p, so a direct subplace alias can be tracked precisely
// instead of conservatively poisoning the referent at move time.
fn accept_array_struct_element_direct_alias_before_move() -> u32 {
    let r: Res = mkres(1);
    let arr: [1]ResPtrHolder = .{ .{ .p = &r } };
    let v: u32 = peek(arr[0].p);
    let x: Res = r;
    return consume(x) + v;
}

// Rejected: the same array-element struct-field alias becomes stale after the
// exact referent moves.
fn reject_array_struct_element_direct_alias_after_move() -> u32 {
    let r: Res = mkres(1);
    let arr: [1]ResPtrHolder = .{ .{ .p = &r } };
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(arr[0].p);
    return consume(x) + v;
}

// Accepted: pointer-returning calls inside array-element struct fields use the
// same precise referent tracking when the field is read before the move.
fn accept_array_struct_element_laundered_alias_before_move() -> u32 {
    let r: Res = mkres(1);
    let arr: [1]ResPtrHolder = .{ .{ .p = id_res(&r) } };
    let v: u32 = peek(arr[0].p);
    let x: Res = r;
    return consume(x) + v;
}

// Rejected: laundered aliases stored under arr[0].p are also stale after the
// referent moves.
fn reject_array_struct_element_laundered_alias_after_move() -> u32 {
    let r: Res = mkres(1);
    let arr: [1]ResPtrHolder = .{ .{ .p = id_res(&r) } };
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(arr[0].p);
    return consume(x) + v;
}

// Rejected: when every concrete array-literal element field stores the same
// referent, a later dynamic field read is stale after that referent moves.
fn reject_array_struct_literal_alias_dynamic_read_after_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    let arr: [2]ResPtrHolder = .{ .{ .p = &r }, .{ .p = &r } };
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(arr[i].p);
    return consume(x) + v;
}

// Rejected: the same all-elements dynamic-read rule applies to laundered
// aliases recorded by array literal initialization.
fn reject_array_struct_literal_laundered_alias_dynamic_read_after_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    let arr: [2]ResPtrHolder = .{ .{ .p = id_res(&r) }, .{ .p = id_res(&r) } };
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(arr[i].p);
    return consume(x) + v;
}

// Rejected: a dynamic field read is also stale if any concrete element may
// contain the moved referent, even when other elements point elsewhere.
fn reject_array_struct_literal_mixed_alias_dynamic_read_after_one_move(i: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    let arr: [2]ResPtrHolder = .{ .{ .p = &r0 }, .{ .p = &r1 } };
    let x: Res = r0;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(arr[i].p);
    let y: Res = r1;
    return consume(x) + consume(y) + v;
}

// Rejected: dynamic reads from pointer array literals consult concrete element
// aliases when all elements point at the same referent.
fn reject_pointer_array_literal_alias_dynamic_read_after_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    let ptrs: [2]*Res = .{ &r, &r };
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i]);
    return consume(x) + v;
}

// Rejected: laundered concrete pointer array literal elements participate in
// the same dynamic-read stale-alias check.
fn reject_pointer_array_literal_laundered_alias_dynamic_read_after_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    let ptrs: [2]*Res = .{ id_res(&r), id_res(&r) };
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i]);
    return consume(x) + v;
}

// Rejected: a dynamic pointer-array read is unsafe if any possible concrete
// element is already stale, even when another element points elsewhere.
fn reject_pointer_array_literal_mixed_alias_dynamic_read_after_one_move(i: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    let ptrs: [2]*Res = .{ &r0, &r1 };
    let x: Res = r0;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i]);
    let y: Res = r1;
    return consume(x) + consume(y) + v;
}

// Rejected: nested pointer array literal aliases are also consulted for dynamic
// reads when all concrete outer elements contain the same stale inner element.
fn reject_nested_pointer_array_literal_alias_dynamic_read_after_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    let ptrs: [2][1]*Res = .{ .{ &r }, .{ &r } };
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i][0]);
    return consume(x) + v;
}

// Rejected: mixed nested pointer array literals are unsafe when the dynamic
// read could select a stale concrete outer element.
fn reject_nested_pointer_array_literal_mixed_alias_dynamic_read_after_one_move(i: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    let ptrs: [2][1]*Res = .{ .{ &r0 }, .{ &r1 } };
    let x: Res = r0;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i][0]);
    let y: Res = r1;
    return consume(x) + consume(y) + v;
}

// Rejected: two independent dynamic dimensions still range over concrete
// literal slots, so a stale element anywhere in the matrix makes the read unsafe.
fn reject_matrix_pointer_array_literal_dynamic_read_after_move(i: usize, j: usize) -> u32 {
    let r: Res = mkres(1);
    let ptrs: [2][2]*Res = .{ .{ &r, &r }, .{ &r, &r } };
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i][j]);
    return consume(x) + v;
}

// Rejected: mixed matrix literals are also unsafe if any possible selected
// concrete pointer element is already stale.
fn reject_matrix_pointer_array_literal_mixed_dynamic_read_after_one_move(i: usize, j: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    let ptrs: [2][2]*Res = .{ .{ &r0, &r1 }, .{ &r1, &r1 } };
    let x: Res = r0;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i][j]);
    let y: Res = r1;
    return consume(x) + consume(y) + v;
}

// Rejected: matrix struct-field aliases recorded by literal initialization are
// consulted for two-dimensional dynamic field reads.
fn reject_matrix_struct_literal_alias_dynamic_read_after_move(i: usize, j: usize) -> u32 {
    let r: Res = mkres(1);
    let grid: [2][2]ResPtrHolder = .{
        .{ .{ .p = &r }, .{ .p = &r } },
        .{ .{ .p = &r }, .{ .p = &r } },
    };
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(grid[i][j].p);
    return consume(x) + v;
}

// Rejected: mixed matrix struct-field aliases are unsafe if any possible
// concrete field selected by the dynamic indexes is stale.
fn reject_matrix_struct_literal_mixed_alias_dynamic_read_after_one_move(i: usize, j: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    let grid: [2][2]ResPtrHolder = .{
        .{ .{ .p = &r0 }, .{ .p = &r1 } },
        .{ .{ .p = &r1 }, .{ .p = &r1 } },
    };
    let x: Res = r0;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(grid[i][j].p);
    let y: Res = r1;
    return consume(x) + consume(y) + v;
}

// Rejected: if two branch arms assign the same pointer-array slot to different
// move referents, a later read must account for either referent.
fn reject_branch_divergent_pointer_array_alias_referent_after_one_move(cond: bool, i: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    var ptrs: [1]*Res = .{ &r0 };
    if cond {
        ptrs[0] = &r0;
    } else {
        ptrs[0] = &r1;
    }
    let x: Res = r1;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i]);
    let y: Res = r0;
    return consume(x) + consume(y) + v;
}

// Accepted: matching alias referents across branch arms remain precise.
fn accept_branch_matching_pointer_array_alias_referent_before_move(cond: bool, i: usize) -> u32 {
    let r: Res = mkres(1);
    var ptrs: [1]*Res = .{ &r };
    if cond {
        ptrs[0] = &r;
    } else {
        ptrs[0] = &r;
    }
    let v: u32 = peek(ptrs[i]);
    let x: Res = r;
    return consume(x) + v;
}

// Rejected: switch joins have the same divergent alias-referent hazard.
fn reject_switch_divergent_pointer_array_alias_referent_after_one_move(cond: bool, i: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    var ptrs: [1]*Res = .{ &r0 };
    switch cond {
        true => { ptrs[0] = &r0; },
        false => { ptrs[0] = &r1; },
    }
    let x: Res = r1;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i]);
    let y: Res = r0;
    return consume(x) + consume(y) + v;
}

// Rejected: alias referents changed inside a loop cannot stay precise after the
// loop, because the loop may run zero or multiple times.
fn reject_loop_divergent_pointer_array_alias_referent_after_one_move(flag: bool, i: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    var ptrs: [1]*Res = .{ &r0 };
    while flag {
        ptrs[0] = &r1;
    }
    let x: Res = r1;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i]);
    let y: Res = r0;
    return consume(x) + consume(y) + v;
}

// Rejected: break edges also carry divergent alias-referent facts out of loops.
fn reject_break_divergent_pointer_array_alias_referent_after_one_move(flag: bool, i: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    var ptrs: [1]*Res = .{ &r0 };
    while flag {
        ptrs[0] = &r1;
        break;
    }
    let x: Res = r1;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i]);
    let y: Res = r0;
    return consume(x) + consume(y) + v;
}

// Rejected: continue edges invalidate alias precision for the later condition
// exit just like other loop-carried facts.
fn reject_continue_divergent_pointer_array_alias_referent_after_one_move(flag: bool, i: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    var ptrs: [1]*Res = .{ &r0 };
    while flag {
        ptrs[0] = &r1;
        continue;
    }
    let x: Res = r1;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i]);
    let y: Res = r0;
    return consume(x) + consume(y) + v;
}

// Rejected: short-circuit RHS alias changes may or may not execute, so the
// joined alias fact must be conservative before later reads.
fn reject_short_circuit_divergent_pointer_array_alias_referent_after_one_move(flag: bool, i: usize) -> u32 {
    let r0: Res = mkres(1);
    let r1: Res = mkres(2);
    var ptrs: [1]*Res = .{ &r0 };
    if flag && { ptrs[0] = &r1; true; } {
        let n: u32 = 0;
    }
    let x: Res = r1;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(ptrs[i]);
    let y: Res = r0;
    return consume(x) + consume(y) + v;
}

// Accepted: if the RHS leaves the alias referent unchanged, the short-circuit
// join keeps the alias precise.
fn accept_short_circuit_matching_pointer_array_alias_referent_before_move(flag: bool, i: usize) -> u32 {
    let r: Res = mkres(1);
    var ptrs: [1]*Res = .{ &r };
    if flag && { ptrs[0] = &r; true; } {
        let n: u32 = 0;
    }
    let v: u32 = peek(ptrs[i]);
    let x: Res = r;
    return consume(x) + v;
}

// Accepted: assigning a direct subplace alias into a struct field inside a
// constant-index array element is also a nameable place (`arr[0].p`).
fn accept_assigned_array_struct_element_direct_alias_before_move() -> u32 {
    let r: Res = mkres(1);
    var other: Res = mkres(2);
    var arr: [1]ResPtrHolder = .{ .{ .p = &other } };
    arr[0].p = &r;
    let v: u32 = peek(arr[0].p);
    let x: Res = r;
    let y: Res = other;
    return consume(x) + consume(y) + v;
}

// Rejected: the assignment path must preserve the same stale-alias check for
// array-element struct fields as literal initialization.
fn reject_assigned_array_struct_element_direct_alias_after_move() -> u32 {
    let r: Res = mkres(1);
    var other: Res = mkres(2);
    var arr: [1]ResPtrHolder = .{ .{ .p = &other } };
    arr[0].p = &r;
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(arr[0].p);
    let y: Res = other;
    return consume(x) + consume(y) + v;
}

// Accepted: laundered pointer results assigned into array-element struct fields
// are tracked precisely while read before the referent moves.
fn accept_assigned_array_struct_element_laundered_alias_before_move() -> u32 {
    let r: Res = mkres(1);
    var other: Res = mkres(2);
    var arr: [1]ResPtrHolder = .{ .{ .p = &other } };
    arr[0].p = id_res(&r);
    let v: u32 = peek(arr[0].p);
    let x: Res = r;
    let y: Res = other;
    return consume(x) + consume(y) + v;
}

// Rejected: laundered assignments into array-element struct fields become stale
// after the precise referent moves.
fn reject_assigned_array_struct_element_laundered_alias_after_move() -> u32 {
    let r: Res = mkres(1);
    var other: Res = mkres(2);
    var arr: [1]ResPtrHolder = .{ .{ .p = &other } };
    arr[0].p = id_res(&r);
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(arr[0].p);
    let y: Res = other;
    return consume(x) + consume(y) + v;
}

// Accepted: a successful dynamic index into a singleton array denotes `arr[0]`,
// so assigned aliases into `arr[i].p` are precise too.
fn accept_assigned_singleton_dynamic_array_struct_field_alias_before_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    var other: Res = mkres(2);
    var arr: [1]ResPtrHolder = .{ .{ .p = &other } };
    arr[i].p = &r;
    let v: u32 = peek(arr[i].p);
    let x: Res = r;
    let y: Res = other;
    return consume(x) + consume(y) + v;
}

// Rejected: singleton dynamic array-element struct-field aliases become stale
// after their precise referent moves.
fn reject_assigned_singleton_dynamic_array_struct_field_alias_after_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    var other: Res = mkres(2);
    var arr: [1]ResPtrHolder = .{ .{ .p = &other } };
    arr[i].p = &r;
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(arr[i].p);
    let y: Res = other;
    return consume(x) + consume(y) + v;
}

// Accepted: laundered aliases assigned into singleton dynamic array-element
// struct fields are precise while read before the referent moves.
fn accept_assigned_singleton_dynamic_array_struct_field_laundered_alias_before_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    var other: Res = mkres(2);
    var arr: [1]ResPtrHolder = .{ .{ .p = &other } };
    arr[i].p = id_res(&r);
    let v: u32 = peek(arr[i].p);
    let x: Res = r;
    let y: Res = other;
    return consume(x) + consume(y) + v;
}

// Rejected: laundered singleton dynamic array-element struct-field aliases are
// stale after the referent moves.
fn reject_assigned_singleton_dynamic_array_struct_field_laundered_alias_after_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    var other: Res = mkres(2);
    var arr: [1]ResPtrHolder = .{ .{ .p = &other } };
    arr[i].p = id_res(&r);
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(arr[i].p);
    let y: Res = other;
    return consume(x) + consume(y) + v;
}

// Accepted: assigning through a dynamic index into a multi-element array-element
// struct field records a conservative wildcard field alias (`arr[*].p`).
fn accept_assigned_dynamic_multi_array_struct_field_alias_before_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    var arr: [2]ResPtrHolder = .{ .{ .p = &r }, .{ .p = &r } };
    arr[i].p = &r;
    let v: u32 = arr[i].p.v;
    let x: Res = r;
    return consume(x) + v;
}

// Rejected: a wildcard field alias is stale for a later dynamic element-field
// read after the referent moves.
fn reject_assigned_dynamic_multi_array_struct_field_alias_after_move(i: usize, j: usize) -> u32 {
    let r: Res = mkres(1);
    var arr: [2]ResPtrHolder = .{ .{ .p = &r }, .{ .p = &r } };
    arr[i].p = &r;
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = arr[j].p.v;
    return consume(x) + v;
}

// Rejected: wildcard field aliases also poison constant element-field reads,
// because the dynamic assignment may have targeted that element.
fn reject_assigned_dynamic_multi_array_struct_field_alias_constant_read_after_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    var arr: [2]ResPtrHolder = .{ .{ .p = &r }, .{ .p = &r } };
    arr[i].p = &r;
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = arr[0].p.v;
    return consume(x) + v;
}

// Accepted: laundered pointer results assigned into dynamic multi-element
// array-element struct fields use the same wildcard field alias.
fn accept_assigned_dynamic_multi_array_struct_field_laundered_alias_before_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    var arr: [2]ResPtrHolder = .{ .{ .p = &r }, .{ .p = &r } };
    arr[i].p = id_res(&r);
    let v: u32 = arr[i].p.v;
    let x: Res = r;
    return consume(x) + v;
}

// Rejected: laundered wildcard field aliases are stale after the referent moves.
fn reject_assigned_dynamic_multi_array_struct_field_laundered_alias_after_move(i: usize, j: usize) -> u32 {
    let r: Res = mkres(1);
    var arr: [2]ResPtrHolder = .{ .{ .p = &r }, .{ .p = &r } };
    arr[i].p = id_res(&r);
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = arr[j].p.v;
    return consume(x) + v;
}

// Accepted: wildcard aliases also carry nested member paths, so an assignment
// through `arr[i].inner.p` can be read before the referent moves.
fn accept_assigned_dynamic_multi_nested_array_struct_field_alias_before_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    var arr: [2]NestedResPtrHolder = .{ .{ .inner = .{ .p = &r } }, .{ .inner = .{ .p = &r } } };
    arr[i].inner.p = &r;
    let v: u32 = arr[i].inner.p.v;
    let x: Res = r;
    return consume(x) + v;
}

// Rejected: the nested wildcard field alias is stale for any later dynamic
// element read once the referent has moved.
fn reject_assigned_dynamic_multi_nested_array_struct_field_alias_after_move(i: usize, j: usize) -> u32 {
    let r: Res = mkres(1);
    var arr: [2]NestedResPtrHolder = .{ .{ .inner = .{ .p = &r } }, .{ .inner = .{ .p = &r } } };
    arr[i].inner.p = &r;
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = arr[j].inner.p.v;
    return consume(x) + v;
}

// Rejected: nested wildcard field aliases also poison constant element reads,
// because the dynamic assignment may have targeted that element.
fn reject_assigned_dynamic_multi_nested_array_struct_field_alias_constant_read_after_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    var arr: [2]NestedResPtrHolder = .{ .{ .inner = .{ .p = &r } }, .{ .inner = .{ .p = &r } } };
    arr[i].inner.p = &r;
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = arr[0].inner.p.v;
    return consume(x) + v;
}

// Accepted: laundered pointer results assigned through nested wildcard field
// paths use the same stale-alias place.
fn accept_assigned_dynamic_multi_nested_array_struct_field_laundered_alias_before_move(i: usize) -> u32 {
    let r: Res = mkres(1);
    var arr: [2]NestedResPtrHolder = .{ .{ .inner = .{ .p = &r } }, .{ .inner = .{ .p = &r } } };
    arr[i].inner.p = id_res(&r);
    let v: u32 = arr[i].inner.p.v;
    let x: Res = r;
    return consume(x) + v;
}

// Rejected: laundered nested wildcard field aliases become stale after the
// referent moves.
fn reject_assigned_dynamic_multi_nested_array_struct_field_laundered_alias_after_move(i: usize, j: usize) -> u32 {
    let r: Res = mkres(1);
    var arr: [2]NestedResPtrHolder = .{ .{ .inner = .{ .p = &r } }, .{ .inner = .{ .p = &r } } };
    arr[i].inner.p = id_res(&r);
    let x: Res = r;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = arr[j].inner.p.v;
    return consume(x) + v;
}

// Rejected: moving the whole aggregate after a field was already taken.
fn reject_whole_after_partial() -> u32 {
    let p: Pair = mk();
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let r: u32 = take_whole(p);
    return consume(x) + r;
}

// Rejected: moving the whole move struct after one of its array field elements
// was taken would duplicate the moved element.
fn reject_whole_after_array_field_partial() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: ResArrayBox = box;
    unsafe { forget_unchecked(y); }
    return consume(x);
}

// Rejected: moving the whole move struct after a symbolic array-field child
// move would duplicate that symbolic child place.
fn reject_whole_after_symbolic_array_field_partial(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[i + 0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: ResArrayBox = box;
    unsafe { forget_unchecked(y); }
    return consume(x);
}

// Rejected: moving the array field itself after one concrete element was taken
// would duplicate that element.
fn reject_array_field_after_concrete_element_move() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    let moved: ResArray = box.items; // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(moved); }
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: moving the array field itself after an unknown dynamic element was
// taken would duplicate the wildcard-moved element.
fn reject_array_field_after_wildcard_element_move() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[dynamic_index()];
    let moved: ResArray = box.items; // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(moved); }
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: moving the array field itself after a symbolic child move would
// duplicate that symbolic child place.
fn reject_array_field_after_symbolic_element_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[i + 0];
    let moved: ResArray = box.items; // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(moved); }
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: assigning the array field after a concrete child element was moved
// would overwrite a partially moved field.
fn reject_array_field_assignment_after_concrete_element_move() -> u32 {
    var box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    box.items = .{ mkres(3), mkres(4) }; // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: assigning the array field after an unknown dynamic child move has
// the same partial-move conflict.
fn reject_array_field_assignment_after_wildcard_element_move() -> u32 {
    var box: ResArrayBox = mkbox();
    let x: Res = box.items[dynamic_index()];
    box.items = .{ mkres(3), mkres(4) }; // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: assigning the array field after a symbolic child move has the same
// partial-move conflict.
fn reject_array_field_assignment_after_symbolic_element_move(i: usize) -> u32 {
    var box: ResArrayBox = mkbox();
    let x: Res = box.items[i + 0];
    box.items = .{ mkres(3), mkres(4) }; // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: deferring cleanup of the array field after one child was moved would
// reserve a field that already contains a moved-out element.
fn reject_defer_array_field_after_concrete_element_move() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    defer consume(box.items); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: dynamic child moves also poison later deferred cleanup of the whole
// array field.
fn reject_defer_array_field_after_wildcard_element_move() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[dynamic_index()];
    defer consume(box.items); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: symbolic child moves also poison later deferred cleanup of the whole
// array field.
fn reject_defer_array_field_after_symbolic_element_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[i + 0];
    defer consume(box.items); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(box); }
    return consume(x);
}

// Rejected: borrowing the array field after a concrete child element was moved
// would expose a partially moved field as if it were intact.
fn reject_borrow_array_field_after_concrete_element_move() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[0];
    let v: u32 = peek_res_array(&box.items); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(box); }
    return consume(x) + v;
}

// Rejected: borrowing the array field after an unknown dynamic child move has
// the same partial-field conflict.
fn reject_borrow_array_field_after_wildcard_element_move() -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[dynamic_index()];
    let v: u32 = peek_res_array(&box.items); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(box); }
    return consume(x) + v;
}

// Rejected: symbolic child moves also poison later borrows of the whole
// array field.
fn reject_borrow_array_field_after_symbolic_element_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    let x: Res = box.items[i + 0];
    let v: u32 = peek_res_array(&box.items); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(box); }
    return consume(x) + v;
}

// Rejected: borrowing the whole array owner after a child element was moved would
// expose a partially moved root as if every element were still live.
fn reject_borrow_array_root_after_concrete_element_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[0];
    let v: u32 = peek_res_array(&arr); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(arr); }
    return consume(x) + v;
}

// Rejected: symbolic child moves also poison later borrows of the whole
// array root.
fn reject_borrow_array_root_after_symbolic_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i + 0];
    let v: u32 = peek_res_array(&arr); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(arr); }
    return consume(x) + v;
}

// Rejected: moving the whole array root after a symbolic child move would
// duplicate that symbolic child place.
fn reject_whole_array_root_after_symbolic_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    let x: Res = arr[i + 0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let moved: ResArray = arr;
    unsafe { forget_unchecked(moved); }
    return consume(x);
}

// Rejected: nested wildcard child moves also poison later borrows of the whole
// matrix root.
fn reject_borrow_matrix_root_after_wildcard_nested_element_move() -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[dynamic_index()][0];
    let v: u32 = peek_res_matrix(&matrix); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(matrix); }
    return consume(x) + v;
}

// Rejected: moving the whole matrix root after a symbolic nested child move
// would duplicate that symbolic nested child place.
fn reject_whole_matrix_root_after_symbolic_nested_element_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i + 0][0];
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let moved: ResMatrix = matrix;
    unsafe { forget_unchecked(moved); }
    return consume(x);
}

// Rejected: nested symbolic child moves poison later borrows of the whole
// matrix root as well.
fn reject_borrow_matrix_root_after_symbolic_nested_element_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    let x: Res = matrix[i + 0][0];
    let v: u32 = peek_res_matrix(&matrix); // EXPECT_ERROR: E_USE_AFTER_MOVE
    unsafe { forget_unchecked(matrix); }
    return consume(x) + v;
}

// Rejected: one branch moves a field and the other leaves it live, so the joined
// place state is inconsistent even though the root binding itself is live in both.
fn reject_branch_partial_field_move(cond: bool) -> u32 {
    let p: Pair = mk();
    if cond {
        let x: Res = p.a; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        let y: u32 = consume(x);
    }
    unsafe { forget_unchecked(p); }
    return 0;
}

// Rejected: array element place state must also agree across branch joins.
fn reject_branch_array_element_move(cond: bool) -> u32 {
    let arr: [2]Res = .{ mkres(1), mkres(2) };
    if cond {
        let x: Res = arr[0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        let y: u32 = consume(x);
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: parameter-rooted array element place state must also agree across
// branch joins.
fn reject_branch_array_param_element_move(arr: ResArray, cond: bool) -> u32 {
    if cond {
        let x: Res = arr[0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        let y: u32 = consume(x);
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: array field element place state must also agree across branch joins.
fn reject_branch_array_field_element_move(cond: bool) -> u32 {
    let box: ResArrayBox = mkbox();
    if cond {
        let x: Res = box.items[0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        let y: u32 = consume(x);
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: branch joins must preserve wildcard dynamic array-element moves.
fn reject_branch_dynamic_array_element_move(cond: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    if cond {
        let x: Res = arr[i]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        let y: u32 = consume(x);
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: branch joins must preserve nested wildcard dynamic array-element
// moves as the same `matrix[*][0]` place.
fn reject_branch_dynamic_nested_array_element_move(cond: bool, i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    if cond {
        let x: Res = matrix[i][0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        let y: u32 = consume(x);
    }
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Rejected: branch joins must preserve wildcard dynamic parameter-rooted array
// element moves.
fn reject_branch_dynamic_array_param_element_move(arr: ResArray, cond: bool, i: usize) -> u32 {
    if cond {
        let x: Res = arr[i]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        let y: u32 = consume(x);
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: branch joins preserve nested wildcard parameter-rooted array places.
fn reject_branch_dynamic_matrix_param_element_move(matrix: ResMatrix, cond: bool, i: usize) -> u32 {
    if cond {
        let x: Res = matrix[i][0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        let y: u32 = consume(x);
    }
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Rejected: branch joins must also preserve wildcard dynamic array-field
// element moves.
fn reject_branch_dynamic_array_field_element_move(cond: bool, i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    if cond {
        let x: Res = box.items[i]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        let y: u32 = consume(x);
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: switch joins must preserve partial field moves the same way if/else
// joins do. A field moved in one reachable arm cannot be forgotten at the join.
fn reject_switch_partial_field_move(cond: bool) -> u32 {
    let p: Pair = mk();
    switch cond {
        true => {
            let x: Res = p.a; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
            let y: u32 = consume(x);
        },
        false => {},
    }
    unsafe { forget_unchecked(p); }
    return 0;
}

// Rejected: switch joins must also preserve moved array element places.
fn reject_switch_array_element_move(cond: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    switch cond {
        true => {
            let x: Res = arr[0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
            let y: u32 = consume(x);
        },
        false => {},
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: switch joins must preserve parameter-rooted array element moves.
fn reject_switch_array_param_element_move(arr: ResArray, cond: bool) -> u32 {
    switch cond {
        true => {
            let x: Res = arr[0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
            let y: u32 = consume(x);
        },
        false => {},
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: array field element places must agree across switch arm joins too.
fn reject_switch_array_field_element_move(cond: bool) -> u32 {
    let box: ResArrayBox = mkbox();
    switch cond {
        true => {
            let x: Res = box.items[0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
            let y: u32 = consume(x);
        },
        false => {},
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: wildcard dynamic array-element moves must also survive switch arm
// joins. Moving `arr[i]` in only one arm cannot be treated as a whole live array.
fn reject_switch_dynamic_array_element_move(cond: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    switch cond {
        true => {
            let x: Res = arr[i]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
            let y: u32 = consume(x);
        },
        false => {},
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: switch joins must preserve nested wildcard dynamic array-element
// moves too.
fn reject_switch_dynamic_nested_array_element_move(cond: bool, i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    switch cond {
        true => {
            let x: Res = matrix[i][0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
            let y: u32 = consume(x);
        },
        false => {},
    }
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Rejected: wildcard dynamic parameter-rooted array moves must also survive
// switch arm joins.
fn reject_switch_dynamic_array_param_element_move(arr: ResArray, cond: bool, i: usize) -> u32 {
    switch cond {
        true => {
            let x: Res = arr[i]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
            let y: u32 = consume(x);
        },
        false => {},
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: switch joins preserve nested wildcard parameter-rooted array places.
fn reject_switch_dynamic_matrix_param_element_move(matrix: ResMatrix, cond: bool, i: usize) -> u32 {
    switch cond {
        true => {
            let x: Res = matrix[i][0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
            let y: u32 = consume(x);
        },
        false => {},
    }
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Rejected: the same switch join rule applies to wildcard dynamic elements inside
// move-struct array fields.
fn reject_switch_dynamic_array_field_element_move(cond: bool, i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    switch cond {
        true => {
            let x: Res = box.items[i]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
            let y: u32 = consume(x);
        },
        false => {},
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: switch joins also preserve nested wildcard dynamic array elements
// inside move-struct fields.
fn reject_switch_dynamic_nested_array_field_element_move(cond: bool, i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    switch cond {
        true => {
            let x: Res = box.items[i][0]; // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
            let y: u32 = consume(x);
        },
        false => {},
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: the RHS of a short-circuit expression may not move a field unless
// the left side guarantees that path always runs.
fn reject_short_circuit_partial_field_move(flag: bool) -> u32 {
    let p: Pair = mk();
    if flag && consume(p.a) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        return 1;
    }
    return 0;
}

// Rejected: a short-circuit RHS may not move a concrete array element either.
fn reject_short_circuit_array_element_move(flag: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    if flag && consume(arr[0]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: a short-circuit RHS may not move a dynamic array element, because
// the RHS may not run and the post-expression state would be inconsistent.
fn reject_short_circuit_dynamic_array_element_move(flag: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    if flag && consume(arr[i]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: short-circuit RHS joins preserve symbolic dynamic array places.
fn reject_short_circuit_symbolic_array_element_move(flag: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    if flag && consume(arr[i + 0]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: short-circuit RHS joins preserve bounded symbolic offset places.
fn reject_short_circuit_symbolic_offset_array_element_move(flag: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    if flag && consume(arr[i + 1]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: short-circuit RHS joins preserve canonical linear symbolic places.
fn reject_short_circuit_symbolic_linear_array_element_move(flag: bool, i: usize, j: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    if flag && consume(arr[i + j + 1]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: short-circuit RHS joins must preserve nested wildcard dynamic array
// places.
fn reject_short_circuit_dynamic_nested_array_element_move(flag: bool, i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    if flag && consume(matrix[i][0]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: short-circuit RHS joins preserve parameter-rooted array element
// moves as well as local array roots.
fn reject_short_circuit_array_param_element_move(arr: ResArray, flag: bool) -> u32 {
    if flag && consume(arr[0]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: wildcard dynamic parameter-rooted array element moves are also
// preserved on short-circuit RHS edges.
fn reject_short_circuit_dynamic_array_param_element_move(arr: ResArray, flag: bool, i: usize) -> u32 {
    if flag && consume(arr[i]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: short-circuit RHS joins preserve nested wildcard parameter-rooted
// array places.
fn reject_short_circuit_dynamic_matrix_param_element_move(matrix: ResMatrix, flag: bool, i: usize) -> u32 {
    if flag && consume(matrix[i][0]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: short-circuit RHS joins preserve nested symbolic parameter-rooted
// places.
fn reject_short_circuit_symbolic_matrix_param_element_move(matrix: ResMatrix, flag: bool, i: usize) -> u32 {
    if flag && consume(matrix[i + 0][0]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: short-circuit RHS place checks also include move-struct array field
// elements.
fn reject_short_circuit_array_field_element_move(flag: bool) -> u32 {
    let box: ResArrayBox = mkbox();
    if flag && consume(box.items[0]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: dynamic move-struct array field elements are wildcard subplaces on
// short-circuit RHS edges too.
fn reject_short_circuit_dynamic_array_field_element_move(flag: bool, i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    if flag && consume(box.items[i]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: short-circuit RHS joins preserve nested wildcard dynamic array
// elements inside move-struct fields.
fn reject_short_circuit_dynamic_nested_array_field_element_move(flag: bool, i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    if flag && consume(box.items[i][0]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: short-circuit RHS joins also preserve symbolic dynamic places
// through move-struct array fields.
fn reject_short_circuit_symbolic_array_field_element_move(flag: bool, i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    if flag && consume(box.items[i + 0]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: singleton dynamic array indexes still create concrete place changes
// on short-circuit RHS edges.
fn reject_short_circuit_dynamic_singleton_array_element_move(flag: bool, i: usize) -> u32 {
    let arr: SingleResArray = .{ mkres(1) };
    if flag && consume(arr[i]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: the same singleton concrete-place short-circuit rule composes
// through move-struct array fields.
fn reject_short_circuit_dynamic_singleton_array_field_element_move(flag: bool, i: usize) -> u32 {
    let box: SingleResArrayBox = mksinglebox();
    if flag && consume(box.items[i]) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
        return 1;
    }
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: a loop body may run zero or multiple times, so it cannot move an
// outer aggregate field.
fn reject_loop_partial_field_move(flag: bool) -> u32 {
    let p: Pair = mk();
    while flag {
        let x: Res = p.a; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
    }
    return 0;
}

// Rejected: an outer array element cannot be moved inside a loop that may run
// zero or multiple times.
fn reject_loop_array_element_move(flag: bool) -> u32 {
    let arr: [2]Res = .{ mkres(1), mkres(2) };
    while flag {
        let x: Res = arr[0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
    }
    return 0;
}

// Rejected: a `break` exits the loop on this edge, so moving an outer field
// before the break cannot be hidden from the post-loop state.
fn reject_break_after_partial_field_move(flag: bool) -> u32 {
    let p: Pair = mk();
    while flag {
        let x: Res = p.a; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        break;
    }
    unsafe { forget_unchecked(p); }
    return 0;
}

// Rejected: early loop exits also preserve array-element place changes.
fn reject_break_after_array_element_move(flag: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while flag {
        let x: Res = arr[0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        break;
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: early loop exits also preserve wildcard dynamic array-element
// place changes.
fn reject_break_after_dynamic_array_element_move(flag: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while flag {
        let x: Res = arr[i]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        break;
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: early loop exits preserve stable symbolic dynamic array-element
// place changes too.
fn reject_break_after_symbolic_array_element_move(flag: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while flag {
        let x: Res = arr[i + 0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        break;
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: early loop exits preserve bounded symbolic offset places too.
fn reject_break_after_symbolic_offset_array_element_move(flag: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while flag {
        let x: Res = arr[i + 1]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        break;
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: early loop exits also preserve nested wildcard dynamic array places.
fn reject_break_after_dynamic_nested_array_element_move(flag: bool, i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    while flag {
        let x: Res = matrix[i][0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        break;
    }
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Rejected: early loop exits preserve move-struct array field element changes.
fn reject_break_after_array_field_element_move(flag: bool) -> u32 {
    let box: ResArrayBox = mkbox();
    while flag {
        let x: Res = box.items[0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        break;
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: early loop exits also preserve wildcard dynamic array-field element
// changes.
fn reject_break_after_dynamic_array_field_element_move(flag: bool, i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    while flag {
        let x: Res = box.items[i]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        break;
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: early loop exits preserve nested wildcard dynamic array-field
// element changes.
fn reject_break_after_dynamic_nested_array_field_element_move(flag: bool, i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    while flag {
        let x: Res = box.items[i][0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        break;
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: `continue` ends the current iteration, so an outer place cannot be
// consumed only on that edge either.
fn reject_continue_after_partial_field_move(flag: bool) -> u32 {
    let p: Pair = mk();
    while flag {
        let x: Res = p.a; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        continue;
    }
    unsafe { forget_unchecked(p); }
    return 0;
}

// Rejected: `continue` preserves concrete array element changes too.
fn reject_continue_after_array_element_move(flag: bool) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while flag {
        let x: Res = arr[0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        continue;
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: `continue` also preserves wildcard dynamic array element changes.
fn reject_continue_after_dynamic_array_element_move(flag: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while flag {
        let x: Res = arr[i]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        continue;
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: `continue` also preserves stable symbolic dynamic array-element
// place changes.
fn reject_continue_after_symbolic_array_element_move(flag: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while flag {
        let x: Res = arr[0 + i]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        continue;
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: `continue` also preserves bounded symbolic offset places.
fn reject_continue_after_symbolic_offset_array_element_move(flag: bool, i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while flag {
        let x: Res = arr[1 + i]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        continue;
    }
    unsafe { forget_unchecked(arr); }
    return 0;
}

// Rejected: `continue` also preserves nested wildcard dynamic array places.
fn reject_continue_after_dynamic_nested_array_element_move(flag: bool, i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    while flag {
        let x: Res = matrix[i][0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        continue;
    }
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Rejected: loop `break` edges preserve nested wildcard parameter-rooted array
// places too.
fn reject_break_after_dynamic_matrix_param_element_move(matrix: ResMatrix, flag: bool, i: usize) -> u32 {
    while flag {
        let x: Res = matrix[i][0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        break;
    }
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Rejected: loop `continue` edges preserve nested wildcard parameter-rooted
// array places too.
fn reject_continue_after_dynamic_matrix_param_element_move(matrix: ResMatrix, flag: bool, i: usize) -> u32 {
    while flag {
        let x: Res = matrix[i][0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        continue;
    }
    unsafe { forget_unchecked(matrix); }
    return 0;
}

// Rejected: `continue` also preserves move-struct array field element changes.
fn reject_continue_after_array_field_element_move(flag: bool) -> u32 {
    let box: ResArrayBox = mkbox();
    while flag {
        let x: Res = box.items[0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        continue;
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: wildcard dynamic move-struct array field elements are preserved on
// `continue` edges too.
fn reject_continue_after_dynamic_array_field_element_move(flag: bool, i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    while flag {
        let x: Res = box.items[i]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        continue;
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: `continue` edges preserve nested wildcard dynamic array-field
// element changes too.
fn reject_continue_after_dynamic_nested_array_field_element_move(flag: bool, i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    while flag {
        let x: Res = box.items[i][0]; // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
        let y: u32 = consume(x);
        continue;
    }
    unsafe { forget_unchecked(box); }
    return 0;
}

// Rejected: the same place rule applies to a while condition.
fn reject_while_condition_partial_field_move() -> u32 {
    let p: Pair = mk();
    while consume(p.a) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    return 0;
}

// Rejected: while-condition resource changes include concrete array element
// places, not only aggregate fields.
fn reject_while_condition_array_element_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while consume(arr[0]) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: while-condition resource changes also include wildcard dynamic
// array-element places, because the condition may run zero or multiple times.
fn reject_while_condition_dynamic_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while consume(arr[i]) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: while-condition resource changes preserve symbolic dynamic
// array-element places.
fn reject_while_condition_symbolic_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while consume(arr[i * 1]) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: while-condition resource changes preserve bounded symbolic offset
// array-element places.
fn reject_while_condition_symbolic_offset_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    while consume(arr[i + 1]) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: while-condition resource changes also preserve nested wildcard
// dynamic array places.
fn reject_while_condition_dynamic_nested_array_element_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    while consume(matrix[i][0]) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: while-condition resource changes also include parameter-rooted
// concrete array element places.
fn reject_while_condition_array_param_element_move(arr: ResArray) -> u32 {
    while consume(arr[0]) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: wildcard dynamic parameter-rooted array elements use the same
// while-condition place rule.
fn reject_while_condition_dynamic_array_param_element_move(arr: ResArray, i: usize) -> u32 {
    while consume(arr[i]) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    unsafe { forget_unchecked(arr); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: while-condition checks preserve nested wildcard parameter-rooted
// array places too.
fn reject_while_condition_dynamic_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 {
    while consume(matrix[i][0]) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    unsafe { forget_unchecked(matrix); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: concrete array elements inside move-struct fields use the same
// while-condition place rule.
fn reject_while_condition_array_field_element_move() -> u32 {
    let box: ResArrayBox = mkbox();
    while consume(box.items[0]) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: dynamic array elements inside move-struct fields use the same
// wildcard place rule when consumed by a while condition.
fn reject_while_condition_dynamic_array_field_element_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    while consume(box.items[i]) != 0 { // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    }
    unsafe { forget_unchecked(box); } // EXPECT_ERROR: E_USE_AFTER_MOVE
    return 0;
}

// Rejected: moving a field inside a nested lexical block must poison the same
// outer place after the block exits.
fn reject_block_partial_field_move() -> u32 {
    let p: Pair = mk();
    {
        let x: Res = p.a;
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = p.a;
    unsafe { forget_unchecked(p); }
    return consume(z);
}

// Rejected: a partial field move inside a nested block also blocks a later
// whole-aggregate move outside the block.
fn reject_block_whole_after_partial() -> u32 {
    let p: Pair = mk();
    {
        let x: Res = p.a;
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let r: u32 = take_whole(p);
    return r;
}

// Rejected: concrete array-element moves inside a nested block remain visible
// after the block exits.
fn reject_block_array_element_move() -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    {
        let x: Res = arr[0];
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(z);
}

// Rejected: wildcard dynamic array-element moves inside a nested block remain
// visible after the block exits.
fn reject_block_dynamic_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    {
        let x: Res = arr[i];
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(z);
}

// Rejected: symbolic dynamic array-element moves inside a nested block remain
// visible as the same symbolic place after the block exits.
fn reject_block_symbolic_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    {
        let x: Res = arr[i + 0];
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = arr[i];
    unsafe { forget_unchecked(arr); }
    return consume(z);
}

// Rejected: bounded symbolic offset moves inside a nested block remain visible
// as the same offset place after the block exits.
fn reject_block_symbolic_offset_array_element_move(i: usize) -> u32 {
    let arr: ResArray = .{ mkres(1), mkres(2) };
    {
        let x: Res = arr[i + 1];
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = arr[1 + i];
    unsafe { forget_unchecked(arr); }
    return consume(z);
}

// Rejected: nested wildcard dynamic array places moved inside a block remain
// visible after the block exits.
fn reject_block_dynamic_nested_array_element_move(i: usize) -> u32 {
    let matrix: ResMatrix = .{ .{ mkres(1) }, .{ mkres(2) } };
    {
        let x: Res = matrix[i][0];
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); }
    return consume(z);
}

// Rejected: scoped blocks preserve flat wildcard parameter-rooted array places.
fn reject_block_dynamic_array_param_element_move(arr: ResArray, i: usize) -> u32 {
    {
        let x: Res = arr[i];
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = arr[0];
    unsafe { forget_unchecked(arr); }
    return consume(z);
}

// Rejected: scoped blocks preserve nested wildcard parameter-rooted array places.
fn reject_block_dynamic_matrix_param_element_move(matrix: ResMatrix, i: usize) -> u32 {
    {
        let x: Res = matrix[i][0];
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = matrix[0][0];
    unsafe { forget_unchecked(matrix); }
    return consume(z);
}

// Rejected: function-exit leak checks preserve flat wildcard parameter-rooted
// array places after a dynamic element move.
fn reject_return_dynamic_array_param_element_leak(arr: ResArray, i: usize) -> u32 { // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = arr[i];
    return consume(x);
}

// Rejected: function-exit leak checks preserve nested wildcard parameter-rooted
// array places after a dynamic element move.
fn reject_return_dynamic_matrix_param_element_leak(matrix: ResMatrix, i: usize) -> u32 { // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: Res = matrix[i][0];
    return consume(x);
}

// Rejected: concrete array field-element moves inside a nested block also
// poison later concrete element moves.
fn reject_block_array_field_element_move() -> u32 {
    let box: ResArrayBox = mkbox();
    {
        let x: Res = box.items[0];
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = box.items[0];
    unsafe { forget_unchecked(box); }
    return consume(z);
}

// Rejected: wildcard dynamic array field-element moves inside a nested block
// also poison later concrete element moves.
fn reject_block_dynamic_array_field_element_move(i: usize) -> u32 {
    let box: ResArrayBox = mkbox();
    {
        let x: Res = box.items[i];
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = box.items[0];
    unsafe { forget_unchecked(box); }
    return consume(z);
}

// Rejected: nested wildcard dynamic array field-element moves inside a block
// also poison later concrete nested element moves.
fn reject_block_dynamic_nested_array_field_element_move(i: usize) -> u32 {
    let box: ResMatrixBox = mkmatrixbox();
    {
        let x: Res = box.items[i][0];
        let y: u32 = consume(x);
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let z: Res = box.items[0][0];
    unsafe { forget_unchecked(box); }
    return consume(z);
}

// Accepted: a field moved inside a nested block can be reinitialized inside the
// same block, and that fresh field remains live after the block exits.
fn accept_block_reinitialize_moved_field() -> u32 {
    var p: Pair = mk();
    {
        let x: Res = p.a;
        let y: u32 = consume(x);
        p.a = mkres(y + 1);
    }
    let a: Res = p.a;
    let b: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(a) + consume(b);
}
