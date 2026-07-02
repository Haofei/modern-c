// Differential-coverage fixture (language gap G14: `&base.field` / `&base[i]` where `base`
// reaches storage THROUGH a pointer).
//
// The escape/move analysis over-rejected taking the address of a field/element reached
// through a POINTER (`&p.field`, `&p.arr[i]`). The resulting address points into the
// POINTED-TO storage (caller-owned / heap), NOT this frame's stack slot, so returning it
// does not dangle — it must be accepted. Only the address of an actual LOCAL variable (or a
// by-value local aggregate's field/element) is a real dangling escape and stays rejected.
//
// This fixture proves the accepted forms alias the REAL field: it takes `&e.val` through a
// pointer parameter, `&e.arr[i]` through a pointer parameter, and (the actual self-hosting
// repro) `&p.field` where `p` is a LOCAL holding a pointer copy — then mutates through each
// returned pointer and re-reads the underlying object to confirm the alias.

struct Entry { val: u32, arr: [4]u32 }

// (1) `&e.val` through a pointer PARAMETER: address of a field in pointed-to storage.
fn slot_ptr(e: *mut Entry) -> *mut u32 {
    return &e.val;
}

// (2) `&e.arr[i]` through a pointer PARAMETER: address of an element in pointed-to storage.
fn arr_slot_ptr(e: *mut Entry, i: usize) -> *mut u32 {
    return &e.arr[i];
}

// (3) The self-hosting repro: `&p.val` where `p` is a LOCAL that holds a pointer COPY.
// The lvalue root goes through the pointer `p`, so `&p.val` is `&p->val` — not a local
// stack slot.
fn slot_ptr_via_local(e: *mut Entry) -> *mut u32 {
    let p: *mut Entry = e;
    return &p.val;
}

export fn pointer_field_addr_run() -> u32 {
    var e: Entry = .{ .val = 10, .arr = .{ 1, 2, 3, 4 } };

    // (1) The returned pointer must alias e.val: write through it, read the field back.
    let vp: *mut u32 = slot_ptr(&e);
    vp.* = 77;
    if e.val != 77 { return 0; }

    // (2) The returned pointer must alias e.arr[2]: write through it, read the element back.
    let ap: *mut u32 = arr_slot_ptr(&e, 2);
    ap.* = 88;
    if e.arr[2] != 88 { return 0; }
    if e.arr[0] != 1 { return 0; }   // neighbouring elements untouched

    // (3) The local-pointer-copy path must alias the same field too.
    let lp: *mut u32 = slot_ptr_via_local(&e);
    lp.* = 99;
    if e.val != 99 { return 0; }

    return 1;
}
