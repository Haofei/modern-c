// SPEC: section=2,9
// SPEC: milestone=trivial-local-address-escape
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_LOCAL_ADDRESS_ESCAPE,E_BORROW_ESCAPES_SCOPE

global shared_counter: u32 = 0;
global escape_slot: *mut u32 = &shared_counter;

extern struct Packet {
    value: u32,
}

extern fn make_array() -> [4]u32;

struct Holder {
    slot: *mut u32,
}

struct Row {
    cells: [4]u32,
}

fn sink(p: *mut u32) -> void {
    *p = 0;
}

fn sink_returns(p: *mut u32) -> *mut u32 {
    return p;
}

fn accept_return_parameter_pointer(p: *mut u32) -> *mut u32 {
    return p;
}

fn accept_return_const_parameter_pointer(p: *const u32) -> *const u32 {
    return p;
}

fn accept_return_global_address() -> *mut u32 {
    return &shared_counter;
}

fn accept_return_parameter_pointer_alias(p: *mut u32) -> *mut u32 {
    let q: *mut u32 = p;
    return q;
}

fn accept_return_const_parameter_pointer_alias(p: *const u32) -> *const u32 {
    let q: *const u32 = p;
    return q;
}

fn accept_return_global_address_alias() -> *mut u32 {
    let p: *mut u32 = &shared_counter;
    return p;
}

fn accept_return_slice_element_address(xs: []mut u32, i: usize) -> *mut u32 {
    return &xs[i];
}

// (G14) Taking the address of a field/element reached THROUGH a pointer — `&e.field`,
// `&e.arr[i]` — points into the POINTED-TO storage (caller-owned / heap), NOT this frame's
// stack slot, so returning it does not dangle. The lvalue root goes through a `*`, not a
// local variable; only a plain local (or a by-value local aggregate's field/element) is a
// genuine escape. This holds whether the pointer is a PARAMETER or a LOCAL holding a copy.

fn accept_return_pointer_param_field_address(e: *mut Packet) -> *mut u32 {
    return &e.value;
}

fn accept_return_pointer_param_array_element_address(r: *mut Row, i: usize) -> *mut u32 {
    return &r.cells[i];
}

fn accept_return_local_pointer_field_address(e: *mut Packet) -> *mut u32 {
    let p: *mut Packet = e;
    return &p.value;
}

fn accept_return_local_pointer_array_element_address(r: *mut Row, i: usize) -> *mut u32 {
    let p: *mut Row = r;
    return &p.cells[i];
}

fn accept_cleared_local_pointer_alias(p: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = &x;
    out = p;
    return out;
}

fn accept_cleared_assigned_local_pointer_alias(p: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = p;
    out = &x;
    out = p;
    return out;
}

fn accept_copied_after_cleared_local_pointer_alias(p: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = p;
    out = &x;
    out = p;
    let q: *mut u32 = out;
    return q;
}

fn accept_cleared_local_pointer_with_global() -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = &x;
    out = &shared_counter;
    return out;
}

fn accept_copied_after_cleared_local_pointer_with_global() -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = &x;
    out = &shared_counter;
    let q: *mut u32 = out;
    return q;
}

fn reject_return_var_local_address() -> *mut u32 {
    var x: u32 = 1;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &x;
}

fn reject_return_let_local_address() -> *const u32 {
    let x: u32 = 1;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &x;
}

fn reject_return_grouped_local_address() -> *mut u32 {
    var x: u32 = 1;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &(x);
}

fn reject_return_local_field_address() -> *mut u32 {
    var packet: Packet = uninit;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &packet.value;
}

fn reject_return_local_array_element_address(i: usize) -> *mut u32 {
    var xs: [4]u32 = uninit;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &xs[i];
}

fn reject_return_array_param_element_address(xs: [4]u32, i: usize) -> *mut u32 {
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &xs[i];
}

fn reject_return_call_array_element_address(i: usize) -> *mut u32 {
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &make_array()[i];
}

fn reject_return_local_pointer_to_var() -> *mut u32 {
    var x: u32 = 1;
    let p: *mut u32 = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return p;
}

fn reject_return_local_pointer_to_let() -> *const u32 {
    let x: u32 = 1;
    let p: *const u32 = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return p;
}

fn reject_return_grouped_local_pointer_to_var() -> *mut u32 {
    var x: u32 = 1;
    let p: *mut u32 = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return (p);
}

fn reject_return_copied_local_pointer() -> *mut u32 {
    var x: u32 = 1;
    let p: *mut u32 = &x;
    let q: *mut u32 = p;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return q;
}

fn reject_return_var_pointer_initialized_local_address() -> *mut u32 {
    var x: u32 = 1;
    var p: *mut u32 = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return p;
}

fn reject_return_grouped_var_pointer_initialized_local_address() -> *mut u32 {
    var x: u32 = 1;
    var p: *mut u32 = &(x);
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return (p);
}

fn reject_return_copied_var_pointer_initialized_local_address() -> *mut u32 {
    var x: u32 = 1;
    var p: *mut u32 = &x;
    let q: *mut u32 = p;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return q;
}

fn reject_return_assigned_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = fallback;
    out = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return out;
}

fn reject_return_assigned_grouped_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = fallback;
    (out) = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return out;
}

fn reject_return_assigned_grouped_address_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = fallback;
    out = &(x);
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return (out);
}

fn reject_return_assigned_copied_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    let p: *mut u32 = &x;
    var out: *mut u32 = fallback;
    out = p;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return out;
}

fn reject_return_copied_after_assigned_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = fallback;
    out = &x;
    let q: *mut u32 = out;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return q;
}

fn reject_return_var_copied_after_assigned_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = fallback;
    out = &x;
    var q: *mut u32 = fallback;
    q = out;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return q;
}

// T1.1 — storing a stack borrow OUT through a pointer parameter (the caller-owned
// target outlives this frame): the borrow would dangle once `store` returns.

fn reject_store_local_address_through_out_param(out: *mut *mut u32) -> void {
    var x: u32 = 1;
    // EXPECT_ERROR: E_BORROW_ESCAPES_SCOPE
    *out = &x;
}

fn reject_store_local_address_through_param_field(b: *mut Holder) -> void {
    var x: u32 = 1;
    // EXPECT_ERROR: E_BORROW_ESCAPES_SCOPE
    b.slot = &x;
}

// T1.1 (bug #2) — storing a stack borrow into a GLOBAL pointer. A global outlives
// every frame, so the stored borrow dangles after this function returns. Previously
// accepted (the escape check only knew pointer *parameters* outlive the frame, not
// globals); now rejected via the unified place-root classifier.
fn reject_store_local_address_into_global() -> void {
    var x: u32 = 5;
    // EXPECT_ERROR: E_BORROW_ESCAPES_SCOPE
    escape_slot = &x;
}

// (bug #3) Returning an AGGREGATE that embeds `&local` by value. The aggregate escapes the
// frame, so the laundered stack borrow dangles — even though the return type is a struct/array,
// not a pointer. Previously a false negative (the escape check only fired on pointer returns).

fn reject_return_struct_with_local_address() -> Holder {
    var x: u32 = 5;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return .{ .slot = &x };
}

fn reject_return_array_with_local_address() -> [1]*mut u32 {
    var x: u32 = 5;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return .{ &x };
}

// Returning an aggregate that embeds a PARAMETER or GLOBAL address stays accepted: those
// outlive the frame, so the embedded borrow does not dangle.
fn accept_return_struct_with_param_address(p: *mut u32) -> Holder {
    return .{ .slot = p };
}

fn accept_return_struct_with_global_address() -> Holder {
    return .{ .slot = &shared_counter };
}

// Passing `&local` DOWN to a callee (a call argument, not an assignment target) and
// storing a local address into another *local* pointer stay accepted: neither outlives
// the local's frame, so neither can dangle.

fn accept_pass_local_address_down(out: *mut *mut u32) -> void {
    var x: u32 = 1;
    var p: *mut u32 = &x;
    sink(p);
    *out = sink_returns(p);
}
